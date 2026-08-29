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
# answer, all of which is this repository's own logic: which files are
# searched, where a document starts and ends, how it is rewritten so a
# mutation is validated without being run, what is sent on the wire, which
# errors mean drift and which mean the check did not happen, and — the ones
# that matter most — that nothing is ever dropped quietly and that an
# unanswered document is never counted as an answered one.
#
# Most of the cases below exist because the first version of this check got
# them wrong, and a code review found each one by reproducing it. They are
# ordered as that review numbered them where it helps.
#
# The first case runs the real discovery against this repository's own tree,
# so the documents under test are the live ones rather than fixtures: it is
# what would notice a document being added in a form the scanner cannot see.
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
assert_yes() { assert_eq "$1" "yes" "$2"; }
saw() { if grep -q -- "$1" <<<"$2"; then echo yes; else echo no; fi; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# --- the stub --------------------------------------------------------------
#
# The request is a JSON body posted with `--input`, not `-f query=…` pairs, so
# the stub records the body rather than the argv. That is worth recording:
# `gh api graphql` lifts every `-f`/`-F` pair but `query` into `variables`, so
# a document declaring a variable named `$query` collided with the reserved
# key carrying the document itself.
#
# `ok` answers `{"data":{}}` and nothing else, which is what GitHub returns
# for a document whose whole selection set was skipped — itself worth pinning,
# since a stub answering with data would mean the wrapper had not been applied.
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
tmp_dir="$(dirname "$0")"
args=( "$@" )
for (( i = 0; i < ${#args[@]}; i++ )); do
  if [[ "${args[$i]}" == "--input" ]]; then
    tr -d '\n' < "${args[$((i+1))]}" >> "$tmp_dir/bodies.log"
    printf '\n' >> "$tmp_dir/bodies.log"
  fi
done
q="'"
case "$(cat "$tmp_dir/mode" 2>/dev/null)" in
  drift)
    printf '%s' "{\"errors\":[{\"extensions\":{\"code\":\"undefinedField\"},\"message\":\"Field ${q}mergeMethod${q} doesn't exist on type ${q}MergeQueue${q}\"}]}"
    printf 'gh: Field %smergeMethod%s does not exist\n' "$q" "$q" >&2
    exit 1 ;;
  transport)
    printf 'gh: Bad credentials (HTTP 401)\n' >&2
    exit 1 ;;
  ratelimited)
    printf '%s' '{"data":null,"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}'
    printf 'gh: API rate limit exceeded\n' >&2
    exit 1 ;;
  mixed)
    printf '%s' "{\"errors\":[{\"type\":\"FORBIDDEN\",\"message\":\"Resource not accessible\"},{\"extensions\":{\"code\":\"undefinedField\"},\"message\":\"Field ${q}mergeMethod${q} doesn't exist on type ${q}MergeQueue${q}\"}]}"
    printf 'gh: two errors\n' >&2
    exit 1 ;;
  multiline)
    printf '%s' '{"errors":[{"extensions":{"code":"parseError"},"message":"Parse error on \"}\" (RCURLY)\n  mergeQueue(branch:$branch){ id\n                              ^"}]}'
    printf 'gh: parse error\n' >&2
    exit 1 ;;
  *)
    printf '%s' '{"data":{}}' ;;
esac
STUB
chmod +x "$tmp_dir/gh"
: > "$tmp_dir/bodies.log"
printf 'ok\n' > "$tmp_dir/mode"

mode() { printf '%s\n' "$1" > "$tmp_dir/mode"; }
run_check() {  # [<root>] [<flag>...] — always with the stub
  local root="${1:-$SCRIPT_DIR}"; shift || true
  : > "$tmp_dir/bodies.log"
  GRAPHQL_DRIFT_GH="$tmp_dir/gh" GRAPHQL_DRIFT_ROOT="$root" "$CHECK" "$@" 2>&1
}

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

# --- 1. the real tree ------------------------------------------------------

out="$(run_check)"; rc=$?
assert_eq "the repository's own documents all check clean against a stub" "0" "$rc"

checked="$(grep -c '^ok   - ' <<<"$out")"
assert_yes "every document reports its own ok line, and there are at least seven" \
  "$(if (( checked >= 7 )); then echo yes; else echo "no ($checked)"; fi)"
assert_yes "the run says how many of how many it answered" \
  "$(saw "^$checked of $checked document(s) checked against GitHub's live schema$" "$out")"

for f in lib/issue-priority.sh lib/landing.sh lib/merge-queue.sh \
         prompts/implementer.md prompts/reviewer.md; do
  assert_yes "$f's documents are discovered" "$(saw "^ok   - $f:" "$out")"
done

# Each exclusion is asserted in two halves: that the file really does carry
# the delimiter, and that it was still not checked. Without the first half
# these pass for free the day the file stops mentioning it, and an assertion
# that has quietly stopped testing anything is this whole item in miniature.
assert_excluded() {  # <path> <why>
  assert_yes "$1 carries the delimiter" \
    "$(if grep -qF -e "-f query='" "$SCRIPT_DIR/$1" >/dev/null 2>&1; then echo yes; else echo no; fi)"
  assert_yes "…and is not checked as a document — $2" \
    "$(if grep -q "^ok   - $1" <<<"$out"; then echo no; else echo yes; fi)"
}
assert_excluded test/graphql-drift.test.sh "a stub sends nothing to GitHub"
assert_excluded scripts/check-graphql-drift.sh "it quotes the delimiter in its own commentary"
assert_excluded CHANGELOG.md "prose about these documents is not one of them"
assert_excluded docs/IMPLEMENTATION-PIPELINE-SPEC.md "so is the spec describing this very check"

sent="$(wc -l < "$tmp_dir/bodies.log")"
assert_eq "gh was called once per document" "$checked" "$sent"
assert_eq "every request carried the document under .query and an object of variables" \
  "$checked" "$(jq -s '[.[] | select((.query | type) == "string" and (.variables | type) == "object")] | length' "$tmp_dir/bodies.log")"
assert_eq "every document reached gh wrapped in the skip fragment" \
  "$checked" "$(jq -rs '[.[] | select(.query | test("\\.\\.\\. @skip\\(if:true\\) \\{"))] | length' "$tmp_dir/bodies.log")"

# The two mutations are the reason the wrapper exists at all: a checker that
# ran what it checks would enqueue a pull request and write an issue's
# Priority every night.
assert_eq "enqueuePullRequest is inside the skipped fragment, never at the top level" \
  "1" "$(jq -rs '[.[] | select(.query | test("mutation\\(\\$id:ID!\\)\\{ \\.\\.\\. @skip\\(if:true\\) \\{enqueuePullRequest"))] | length' "$tmp_dir/bodies.log")"
assert_eq "no mutation reaches gh with its field still collectable" \
  "0" "$(jq -rs '[.[] | select(.query | test("mutation[^{]*\\{[[:space:]]*[a-zA-Z]"))] | length' "$tmp_dir/bodies.log")"

assert_eq "a declared Int variable is sent as a JSON number, not a string" \
  "0" "$(jq -s '[.[] | .variables.number? | select(. != null) | select(type != "number")] | length' "$tmp_dir/bodies.log")"

# --- 2. a variable named $query does not overwrite the document (review 1) --

repo="$(make_repo reserved)"
cat > "$repo/lib/search.sh" <<'FIX'
#!/usr/bin/env bash
s() {
  gh api graphql \
    -f query='query($query:String!,$n:Int!){ search(query:$query, type:ISSUE, first:$n){ issueCount } }' \
    -f query=x -F n=1
}
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "a document declaring \$query is checked, not collided with" "0" "$rc"
assert_eq "…the document still reaches gh intact under .query" "true" \
  "$(jq -rs '.[0].query | contains("search(query:$query, type:ISSUE, first:$n)")' "$tmp_dir/bodies.log")"
assert_eq "…and its own \$query placeholder rides in .variables" \
  "x" "$(jq -rs '.[0].variables.query' "$tmp_dir/bodies.log")"

# --- 3. an unterminated document is reported, never dropped (review 2) -----

repo="$(make_repo unterminated)"
cat > "$repo/lib/good.sh" <<'FIX'
#!/usr/bin/env bash
g() { gh api graphql -f query='{ viewer{ login } }'; }
FIX
printf '#!/usr/bin/env bash\nb() { gh api graphql -f query=%squery{ viewer{ login } }\xe2\x80\x99; }\n' "'" > "$repo/lib/bad.sh"
out="$(run_check "$repo")"; rc=$?
assert_eq "a document that never closes fails the run" "2" "$rc"
assert_yes "…annotated at the line it opens on" \
  "$(saw '^::error file=lib/bad.sh,line=2::a GraphQL document opens here and is never closed' "$out")"
assert_yes "…while the valid document beside it is still checked" "$(saw '^ok   - lib/good.sh:2$' "$out")"
assert_yes "…and the summary counts only what was extracted" \
  "$(saw "^1 of 1 document(s) checked" "$out")"

# --- 4. prose about the form does not swallow the real query (review 2) ----

repo="$(make_repo prose-open)"
mkdir -p "$repo/prompts"
# shellcheck disable=SC2016  # a Markdown code span, which is the whole point of the case.
{ printf 'Use the `-f query=%s` form when you probe the queue.\n' "'"
  printf '\n'
  printf 'gh api graphql -f query=%s{ viewer{ login } }%s\n' "'" "'"
} > "$repo/prompts/p.md"
out="$(run_check "$repo")"; rc=$?
assert_eq "a prompt that describes the form and then uses it checks cleanly" "0" "$rc"
assert_yes "…the real query is the one checked, at its own line" "$(saw '^ok   - prompts/p.md:3$' "$out")"
assert_yes "…and the prose is not read as a document" \
  "$(if grep -q 'could not read the shape' <<<"$out"; then echo no; else echo yes; fi)"
assert_eq "…exactly one document, not one document and one garbage one" \
  "1" "$(wc -l < "$tmp_dir/bodies.log")"

# --- 5. `checked` counts answers, not attempts (review 3) ------------------

repo="$(make_repo counted)"
cat > "$repo/lib/two.sh" <<'FIX'
#!/usr/bin/env bash
a() { gh api graphql -f query='{ viewer{ login } }'; }
b() { gh api graphql -f query='{ viewer{ id } }'; }
FIX
mode transport
out="$(run_check "$repo")"; rc=$?
assert_eq "every call failing on credentials exits 2" "2" "$rc"
assert_yes "…and the summary says nothing was answered, not that both were" \
  "$(saw '^0 of 2 document(s) checked' "$out")"

# --- 6. drift never masks a document that was not checked (review 4) -------

repo="$(make_repo precedence)"
cat > "$repo/lib/mix.sh" <<'FIX'
#!/usr/bin/env bash
a() { gh api graphql -f query='query($owner:String!)'; }
b() { gh api graphql -f query='{ viewer{ login } }'; }
FIX
mode ratelimited
out="$(run_check "$repo")"; rc=$?
assert_eq "an unreadable document plus an unanswered one exits 2, not 1" "2" "$rc"
assert_yes "…the unreadable one is still reported" "$(saw 'could not read the shape' "$out")"
assert_yes "…and so is the one that could not be checked" "$(saw 'could not check this document' "$out")"
mode ok

# --- 7. a call site in an unrecognised form is not silently uncovered ------
#        (review 6)

repo="$(make_repo spelling)"
cat > "$repo/lib/good.sh" <<'FIX'
#!/usr/bin/env bash
g() { gh api graphql -f query='{ viewer{ login } }'; }
FIX
cat > "$repo/lib/other.sh" <<'FIX'
#!/usr/bin/env bash
o() { gh api graphql -f query="{ viewer{ id } }"; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "a file that calls api graphql and yields no document fails the run" "2" "$rc"
assert_yes "…naming the file and what discovery recognises" \
  "$(saw '^::error file=lib/other.sh::this file calls api graphql but no GraphQL document' "$out")"
assert_yes "…while the recognised call beside it is still checked" "$(saw '^ok   - lib/good.sh:2$' "$out")"

# --- 8. a variable type with no placeholder names its line (review 7) ------

repo="$(make_repo unknown-type)"
cat > "$repo/lib/enum.sh" <<'FIX'
#!/usr/bin/env bash
# padding
c() { gh api graphql -f query='query($state:PullRequestState!){ viewer{ login } }' -f state=OPEN; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "a variable type with no placeholder fails rather than being guessed" "1" "$rc"
# shellcheck disable=SC2016  # the message names GraphQL's $state, matched literally.
assert_yes "…annotated with the line, like every sibling annotation" \
  "$(saw '^::error file=lib/enum.sh,line=3::\$state is declared PullRequestState' "$out")"
assert_yes "…and says plainly that nothing is checking it" "$(saw 'nothing is checking this document' "$out")"

# --- 9. the three shape diagnoses stay distinct (review 8) -----------------

repo="$(make_repo shapes)"
cat > "$repo/lib/shapes.sh" <<'FIX'
#!/usr/bin/env bash
a() { gh api graphql -f query='query($owner:String!'; }
b() { gh api graphql -f query='query($owner:String!)'; }
c() { gh api graphql -f query='query{ viewer{ login }'; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "three malformed documents fail the run" "1" "$rc"
assert_yes "…the unclosed variable definitions say so" "$(saw 'its variable definitions never close' "$out")"
assert_yes "…the missing selection set says so" "$(saw 'it has no selection set' "$out")"
assert_yes "…the unclosed selection set says so" "$(saw 'its selection set never closes' "$out")"

# --- 10. --help prints the whole exit-code contract (review 9) -------------

help_out="$("$CHECK" --help 2>&1)"
assert_yes "--help reaches the exit-1 contract" "$(saw '^Exit 1: at least one document is wrong' "$help_out")"
assert_yes "--help reaches the exit-2 contract" "$(saw '^Exit 2: at least one document was not checked' "$help_out")"
assert_yes "--help reaches the last line of it" "$(saw 'Unable is never reported as clean' "$help_out")"

# --- 11. the summary can show a gap between found and answered (review 10) -

repo="$(make_repo gap)"
cat > "$repo/lib/gap.sh" <<'FIX'
#!/usr/bin/env bash
a() { gh api graphql -f query='query($owner:String!)'; }
b() { gh api graphql -f query='{ viewer{ login } }'; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "one readable and one not exits 1" "1" "$rc"
assert_yes "…and the summary shows the gap rather than claiming full coverage" \
  "$(saw '^1 of 2 document(s) checked' "$out")"

# --- 12. a typed error does not discard drift beside it (review 11) --------

repo="$(make_repo mixed)"
cat > "$repo/lib/one.sh" <<'FIX'
#!/usr/bin/env bash
a() { gh api graphql -f query='{ viewer{ login } }'; }
FIX
mode mixed
out="$(run_check "$repo")"; rc=$?
assert_eq "a response carrying both a typed error and drift exits 2" "2" "$rc"
assert_yes "…the drift is still printed rather than discarded" \
  "$(saw "Field 'mergeMethod' doesn't exist on type 'MergeQueue'" "$out")"
assert_yes "…and the typed error is reported as unable, naming its type" \
  "$(saw 'could not check this document — FORBIDDEN: Resource not accessible' "$out")"
assert_eq "…and neither counts as an answered document" \
  "yes" "$(saw '^0 of 1 document(s) checked' "$out")"

# --- 13. a multi-line message stays one annotation (review 12) -------------

mode multiline
out="$(run_check "$repo")"; rc=$?
assert_eq "a multi-line GraphQL message still fails the run" "1" "$rc"
assert_eq "…as exactly one ::error line" "1" "$(grep -c '^::error' <<<"$out")"
assert_yes "…carrying the whole message on that one line" \
  "$(saw 'Parse error on .}. (RCURLY) mergeQueue(branch:.branch){ id .' "$out")"
mode ok

# --- 14. --list lists, and never returns a verdict (review 14) -------------

repo="$(make_repo listing)"
cat > "$repo/lib/broken.sh" <<'FIX'
#!/usr/bin/env bash
a() { gh api graphql -f query='query($owner:String!)'; }
FIX
out="$(run_check "$repo" --list)"; rc=$?
assert_eq "--list over a tree whose only document is malformed exits 0" "0" "$rc"
assert_yes "…and still lists it, rather than printing nothing" "$(saw '^lib/broken.sh:2\s' "$out")"
assert_eq "…without calling gh at all" "0" "$(wc -l < "$tmp_dir/bodies.log")"

repo="$(make_repo listing-unterminated)"
printf '#!/usr/bin/env bash\nb() { gh api graphql -f query=%squery{ viewer{ login } }\xe2\x80\x99; }\n' "'" > "$repo/lib/bad.sh"
out="$(run_check "$repo" --list)"; rc=$?
assert_eq "--list marks an unterminated document instead of failing" "2" "$rc"
assert_yes "…naming it as unclosed" "$(saw 'a document opens here and is never closed' "$out")"

repo="$(make_repo listing-empty)"
printf 'nothing here\n' > "$repo/lib/none.sh"
out="$(run_check "$repo" --list)"; rc=$?
assert_eq "--list over a tree with no document exits 2, never 0" "2" "$rc"

# --- 15. finding nothing is refused, never reported as clean ---------------

repo="$(make_repo empty)"
printf 'nothing here\n' > "$repo/lib/none.sh"
out="$(run_check "$repo")"; rc=$?
assert_eq "a tree with no GraphQL document exits 2, never 0" "2" "$rc"
assert_yes "…saying it refuses to report no drift" "$(saw 'refusing to report no drift' "$out")"

# --- 16. drift is reported against the file and line that carries it -------

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
mode drift
out="$(run_check "$repo")"; rc=$?
assert_eq "a moved field fails the run" "1" "$rc"
assert_yes "…annotated with the file and the line the document starts on" \
  "$(saw '^::error file=lib/one.sh,line=5::' "$out")"
assert_yes "…carrying GitHub's own wording rather than a paraphrase" \
  "$(saw "Field 'mergeMethod' doesn't exist on type 'MergeQueue'" "$out")"
assert_yes "…and counted as answered, because GitHub did answer" \
  "$(saw '^1 of 1 document(s) checked' "$out")"
mode ok

# --- 17. prose is skipped where a prompt is not ----------------------------

repo="$(make_repo prose)"
mkdir -p "$repo/docs" "$repo/prompts"
printf 'Run: gh api graphql -f query=%s{ viewer{ login } }%s\n' "'" "'" > "$repo/docs/how.md"
printf 'Run: gh api graphql -f query=%s{ viewer{ login } }%s\n' "'" "'" > "$repo/prompts/x.md"
out="$(run_check "$repo")"; rc=$?
assert_eq "a tree whose only documents are prose and a prompt still checks the prompt" "0" "$rc"
assert_yes "…the prompt is checked" "$(saw '^ok   - prompts/x.md:1$' "$out")"
assert_yes "…and the doc is not" \
  "$(if grep -q '^ok   - docs/how.md' <<<"$out"; then echo no; else echo yes; fi)"

# --- 18. two documents in one file are each found at their own line --------

repo="$(make_repo two)"
cat > "$repo/lib/two.sh" <<'FIX'
#!/usr/bin/env bash
a() { gh api graphql -f query='query($owner:String!){ viewer{ login } }' -f owner=o; }
b() { gh api graphql -f query='mutation($id:ID!){ enqueuePullRequest(input:{pullRequestId:$id}){ clientMutationId } }' -f id=x; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "both documents in one file are checked" "0" "$rc"
assert_yes "…the first at its own line" "$(saw '^ok   - lib/two.sh:2$' "$out")"
assert_yes "…and the second at its own, not the first's" "$(saw '^ok   - lib/two.sh:3$' "$out")"

# --- 19. an anonymous shorthand query is wrapped like any other ------------

repo="$(make_repo shorthand)"
cat > "$repo/lib/short.sh" <<'FIX'
#!/usr/bin/env bash
e() { gh api graphql -f query='{ viewer{ login } }'; }
FIX
out="$(run_check "$repo")"; rc=$?
assert_eq "a shorthand query with no operation keyword is checked" "0" "$rc"
assert_eq "…and is wrapped like any other" \
  "{ ... @skip(if:true) { viewer{ login } } }" "$(jq -rs '.[0].query' "$tmp_dir/bodies.log")"

printf '\n%s\n' "$(if (( failures == 0 )); then echo "All assertions passed."; else echo "$failures assertion(s) failed."; fi)"
exit $(( failures > 0 ))
