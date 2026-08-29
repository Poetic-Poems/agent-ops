#!/usr/bin/env bash
#
# test/graphql-drift.test.sh — regression test for
# scripts/check-graphql-drift.sh (acceptance check 1g-ii, TD-PPagop-26082930).
#
# A word about what this file can and cannot be. The item this check resolves
# is that *every GitHub read in this repository is asserted only against a
# `gh` stub this repository writes*, so a field GitHub moves cannot fail a
# test. This file stubs `gh` too — and that is not the same mistake repeated,
# because the two halves of the check live in different places. Whether the
# documents still match GitHub's schema is answered by GitHub, nightly, in
# `.github/workflows/graphql-drift.yml`; no stub can answer it and none here
# pretends to. What is left for a unit test is everything *around* that
# answer, all of which is this repository's own logic and all of which was
# wrong at least once while being written: which files are searched, where a
# document starts and ends, how it is rewritten so a mutation is validated
# without being run, which errors mean drift and which mean the check did not
# happen, and — the two that matter most — that a search finding nothing is
# refused rather than reported as clean, and that an unreadable answer is
# never reported as a clean one.
#
# The first case below runs the real discovery against this repository's own
# tree, so the documents under test are the live ones rather than fixtures:
# it is what would notice a document being added in a form the scanner cannot
# see.
#
# Run directly:
#
#   ./test/graphql-drift.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-graphql-drift.sh"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# --- the stub --------------------------------------------------------------
#
# Records every `query=` it is handed, one per invocation, and answers
# according to $tmp_dir/mode. `ok` is the shape GitHub returns for a document
# whose whole selection set was skipped — `{"data":{}}` and nothing else,
# which is itself worth pinning: a stub answering with data would mean the
# wrapper had not been applied.
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
tmp_dir="$(dirname "$0")"
args=( "$@" )
for (( i = 0; i < ${#args[@]}; i++ )); do
  [[ "${args[$i]}" == -f || "${args[$i]}" == -F ]] || continue
  kv="${args[$((i+1))]:-}"
  case "$kv" in
    query=*) printf '%s\n' "${kv#query=}" >> "$tmp_dir/queries.log" ;;
    *)       printf '%s\n' "$kv" >> "$tmp_dir/vars.log" ;;
  esac
done
printf -- '---\n' >> "$tmp_dir/queries.log"
case "$(cat "$tmp_dir/mode" 2>/dev/null)" in
  drift)
    printf '%s' '{"errors":[{"path":["query","...","repository","mergeQueue","mergeMethod"],"extensions":{"code":"undefinedField","typeName":"MergeQueue","fieldName":"mergeMethod"},"message":"Field '"'"'mergeMethod'"'"' doesn'"'"'t exist on type '"'"'MergeQueue'"'"'"}]}'
    printf 'gh: Field %s doesn%st exist on type %s\n' "'mergeMethod'" "'" "'MergeQueue'" >&2
    exit 1 ;;
  transport)
    printf 'gh: Bad credentials (HTTP 401)\n' >&2
    exit 1 ;;
  ratelimited)
    printf '%s' '{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}'
    printf 'gh: API rate limit exceeded\n' >&2
    exit 1 ;;
  *)
    printf '%s' '{"data":{}}' ;;
esac
STUB
chmod +x "$tmp_dir/gh"
: > "$tmp_dir/queries.log"
: > "$tmp_dir/vars.log"
printf 'ok\n' > "$tmp_dir/mode"

run_check() {  # [<root>] — always with the stub
  GRAPHQL_DRIFT_GH="$tmp_dir/gh" \
  GRAPHQL_DRIFT_ROOT="${1:-$SCRIPT_DIR}" \
    "$CHECK" 2>&1
}

# --- 1. the real tree ------------------------------------------------------
#
# Discovery, extraction and rewriting run against this repository's own
# documents, not fixtures — so a document added in a shape the scanner cannot
# see, or one it cannot rewrite, fails here rather than going unchecked in the
# nightly for as long as nobody looks.

out="$(run_check)"; rc=$?
assert_eq "the repository's own documents all check clean against a stub" "0" "$rc"

checked="$(grep -c '^ok   - ' <<<"$out")"
assert_eq "every document reports its own ok line, and there are at least seven" \
  "yes" "$(if (( checked >= 7 )); then echo yes; else echo "no ($checked)"; fi)"
assert_eq "the run says how many it checked, so silence never reads as coverage" \
  "yes" "$(if grep -q "^$checked of $checked document(s) checked against GitHub's live schema$" <<<"$out"; then echo yes; else echo no; fi)"

for f in lib/issue-priority.sh lib/landing.sh lib/merge-queue.sh \
         prompts/implementer.md prompts/reviewer.md; do
  assert_eq "$f's documents are discovered" \
    "yes" "$(if grep -q "^ok   - $f:" <<<"$out"; then echo yes; else echo no; fi)"
done

assert_eq "a document in test/ is never checked — a stub sends nothing to GitHub" \
  "yes" "$(if grep -q '^ok   - test/' <<<"$out"; then echo no; else echo yes; fi)"
assert_eq "the checker does not discover the delimiter quoted in its own comments" \
  "yes" "$(if grep -q '^ok   - scripts/check-graphql-drift.sh' <<<"$out"; then echo no; else echo yes; fi)"

# Prose about these documents quotes the delimiter too — this repository's own
# CHANGELOG and spec both do, describing this very check — and prose sends
# nothing. `prompts/` is the exception, asserted above: a prompt file is the
# instruction an agent carries out.
for f in CHANGELOG.md docs/IMPLEMENTATION-PIPELINE-SPEC.md; do
  assert_eq "$f quotes the delimiter as prose and is not checked as a document" \
    "yes" "$(if grep -q "^ok   - $f:" <<<"$out"; then echo no; else echo yes; fi)"
done

sent="$(grep -c '^---$' "$tmp_dir/queries.log")"
assert_eq "gh was called once per document" "$checked" "$sent"
assert_eq "every document reached gh wrapped in the skip fragment" \
  "$checked" "$(grep -c '\.\.\. @skip(if:true) {' "$tmp_dir/queries.log")"

# The two mutations are the reason the wrapper exists at all: a checker that
# ran what it checks would enqueue a pull request and write an issue's
# Priority every night. Assert the wrapper sits between the operation and the
# mutation field, not merely somewhere in the document.
assert_eq "enqueuePullRequest is inside the skipped fragment, never at the top level" \
  "yes" "$(if grep -q 'mutation($id:ID!){ \.\.\. @skip(if:true) {enqueuePullRequest' "$tmp_dir/queries.log"; then echo yes; else echo no; fi)"
assert_eq "no mutation reaches gh with its field still collectable" \
  "0" "$(grep -c 'mutation[^{]*{[[:space:]]*[a-zA-Z]' "$tmp_dir/queries.log")"

assert_eq "a declared Int variable is sent as a number, not a string" \
  "yes" "$(if grep -qx 'number=1' "$tmp_dir/vars.log"; then echo yes; else echo no; fi)"
assert_eq "a declared String/ID variable is sent" \
  "yes" "$(if grep -qx 'owner=x' "$tmp_dir/vars.log"; then echo yes; else echo no; fi)"

# --- fixture trees ---------------------------------------------------------

# A fixture tree is a plain directory, with no git repository in it — which is
# itself part of what these cases pin. Discovery walks the tree rather than an
# index precisely so that it works where this suite runs: inside the node
# image, where `.dockerignore` and `scripts/run-tests.sh` have both dropped
# `.git` before the tests start.
make_repo() {  # <name> — prints the path to a fresh fixture tree
  local d="$tmp_dir/$1"
  mkdir -p "$d/lib"
  printf '%s' "$d"
}

# --- 2. drift is reported, against the file and line that carries it -------

repo="$(make_repo drift)"
cat > "$repo/lib/one.sh" <<'FIX'
#!/usr/bin/env bash
# padding so the document does not start on line 1
one() {
  gh api graphql \
    -f query='query($owner:String!,$repo:String!,$branch:String!){
      repository(owner:$owner,name:$repo){
        mergeQueue(branch:$branch){ id mergeMethod }
      }
    }' \
    -f owner=o -f repo=r -f branch=b
}
FIX
printf 'drift\n' > "$tmp_dir/mode"
out="$(run_check "$repo")"; rc=$?
assert_eq "a moved field fails the run" "1" "$rc"
assert_eq "…annotated with the file and the line the document starts on" \
  "yes" "$(if grep -q '^::error file=lib/one.sh,line=5::' <<<"$out"; then echo yes; else echo no; fi)"
assert_eq "…carrying GitHub's own wording rather than a paraphrase" \
  "yes" "$(if grep -q "Field 'mergeMethod' doesn't exist on type 'MergeQueue'" <<<"$out"; then echo yes; else echo no; fi)"

# --- 3. an unreadable answer is never a clean one --------------------------

printf 'transport\n' > "$tmp_dir/mode"
out="$(run_check "$repo")"; rc=$?
assert_eq "a transport failure exits 2 — unable, not drift and not clean" "2" "$rc"
assert_eq "…and says it could not check, rather than naming a field" \
  "yes" "$(if grep -q 'could not check this document — gh: Bad credentials' <<<"$out"; then echo yes; else echo no; fi)"

printf 'ratelimited\n' > "$tmp_dir/mode"
out="$(run_check "$repo")"; rc=$?
assert_eq "a GitHub error carrying a \`type\` is unable, not drift" "2" "$rc"
assert_eq "…and names the type, so a rate limit is not mistaken for a schema change" \
  "yes" "$(if grep -q 'RATE_LIMITED: API rate limit exceeded' <<<"$out"; then echo yes; else echo no; fi)"
printf 'ok\n' > "$tmp_dir/mode"

# --- 4. finding nothing is refused, never reported as clean ----------------

repo="$(make_repo empty)"
printf 'nothing here\n' > "$repo/lib/none.sh"
out="$(run_check "$repo")"; rc=$?
assert_eq "a tree with no GraphQL document exits 2, never 0" "2" "$rc"
assert_eq "…saying it refuses to report no drift" \
  "yes" "$(if grep -q 'refusing to report no drift' <<<"$out"; then echo yes; else echo no; fi)"

# --- 5. two documents in one file are both checked -------------------------

repo="$(make_repo two)"
cat > "$repo/lib/two.sh" <<'FIX'
#!/usr/bin/env bash
a() { gh api graphql -f query='query($owner:String!){ viewer{ login } }' -f owner=o; }
b() { gh api graphql -f query='mutation($id:ID!){ enqueuePullRequest(input:{pullRequestId:$id}){ clientMutationId } }' -f id=x; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "both documents in one file are checked" "0" "$rc"
assert_eq "…the first at its own line" \
  "yes" "$(if grep -q '^ok   - lib/two.sh:2$' <<<"$out"; then echo yes; else echo no; fi)"
assert_eq "…and the second at its own, not the first's" \
  "yes" "$(if grep -q '^ok   - lib/two.sh:3$' <<<"$out"; then echo yes; else echo no; fi)"

# --- 6. a variable type the checker cannot fill fails, and says so ---------

repo="$(make_repo unknown-type)"
cat > "$repo/lib/enum.sh" <<'FIX'
#!/usr/bin/env bash
c() { gh api graphql -f query='query($state:PullRequestState!){ viewer{ login } }' -f state=OPEN; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "a variable type with no placeholder fails the run rather than being guessed" "1" "$rc"
assert_eq "…naming the variable and its type, so the fix is obvious" \
  "yes" "$(if grep -q '\$state is declared PullRequestState, a type check-graphql-drift.sh cannot synthesise' <<<"$out"; then echo yes; else echo no; fi)"

# --- 7. a document the rewriter cannot read fails loudly -------------------

repo="$(make_repo unparsable)"
cat > "$repo/lib/broken.sh" <<'FIX'
#!/usr/bin/env bash
d() { gh api graphql -f query='query($owner:String!)' -f owner=o; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "a document with no selection set fails rather than being skipped" "1" "$rc"
assert_eq "…saying plainly that nothing is checking it" \
  "yes" "$(if grep -q 'could not read the shape of this GraphQL document, so nothing is checking it' <<<"$out"; then echo yes; else echo no; fi)"

# --- 8. prose is skipped where a prompt is not ------------------------------

repo="$(make_repo prose)"
mkdir -p "$repo/docs" "$repo/prompts"
printf 'Run `gh api graphql -f query=%s{ viewer{ login } }%s`.\n' "'" "'" > "$repo/docs/how.md"
printf 'Run `gh api graphql -f query=%s{ viewer{ login } }%s`.\n' "'" "'" > "$repo/prompts/x.md"
out="$(run_check "$repo")"; rc=$?
assert_eq "a tree whose only documents are prose and a prompt still checks the prompt" "0" "$rc"
assert_eq "…the prompt is checked" \
  "yes" "$(if grep -q '^ok   - prompts/x.md:1$' <<<"$out"; then echo yes; else echo no; fi)"
assert_eq "…and the doc is not" \
  "yes" "$(if grep -q '^ok   - docs/how.md' <<<"$out"; then echo no; else echo yes; fi)"

# --- 9. an anonymous shorthand query is still wrapped ----------------------

repo="$(make_repo shorthand)"
cat > "$repo/lib/short.sh" <<'FIX'
#!/usr/bin/env bash
e() { gh api graphql -f query='{ viewer{ login } }'; }
FIX
: > "$tmp_dir/queries.log"
out="$(run_check "$repo")"; rc=$?
assert_eq "a shorthand query with no operation keyword is checked" "0" "$rc"
assert_eq "…and is wrapped like any other" \
  "yes" "$(if grep -q '^{ \.\.\. @skip(if:true) { viewer{ login } } }$' "$tmp_dir/queries.log"; then echo yes; else echo no; fi)"

printf '\n%s\n' "$(if (( failures == 0 )); then echo "All assertions passed."; else echo "$failures assertion(s) failed."; fi)"
exit $(( failures > 0 ))
