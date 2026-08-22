#!/usr/bin/env bash
#
# test/register-hygiene.test.sh — regression test for
# scripts/gather-register-hygiene.sh (requirement 3i): the source that notices a
# repository's tech-debt register has stopped agreeing with itself, and hands
# the repair to an ordinary Implementer.
#
# Four behaviours are asserted, and each of them fails silently if broken:
#
#   - **A consistent register contributes `[]`.** This is the answer almost every
#     cycle gets, and getting it wrong the other way files a repair pull request
#     against a file that is fine — every cycle, in three repositories.
#   - **A drifted register contributes exactly one candidate**, whose `ref` is
#     scoped to the register's identity (a digest of the tech-debt tree and
#     policy blob SHAs), whose `problems` array holds one entry per problem
#     line, and whose `body` is the checker's output *verbatim*. The body is
#     the entire brief: every line names an item file and a problem class,
#     and that is what makes the repair mechanical rather than a rewrite.
#   - **A repository with no register contributes `[]`, silently.** Not every
#     repository this fleet touches keeps one; a 404 is a normal answer here, and
#     an error the gatherer prints about is an error somebody investigates.
#   - **An API failure contributes `[]` too — but says so on stderr.** A silent
#     `[]`-on-error is the trap in the Gotchas table: the source simply never
#     fires, no cycle fails, and nothing anywhere says why. Distinguishing "no
#     register" from "no answer" is the whole point of the 404 check, so both
#     directions are asserted.
#
# The gatherer is run for real against a stubbed `gh` and the two fixtures in
# test/fixtures/, so the assertions are about the shipped script rather than a
# copy of its logic. `scripts/td-check.pl` runs for real too — it *is* the
# candidate rule, and a test that stubbed it would assert nothing.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/register-hygiene.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-register-hygiene.sh"
FIXTURES_DIR="$SCRIPT_DIR/test/fixtures"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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

# --- A stub `gh`, so the real gatherer runs offline ------------------------------
#
# It answers the three endpoints the gatherer calls, and reproduces GitHub's
# own shapes exactly. The root-tree listing comes first and is where
# `$STUB_MODE` steers the failure cases: a 404 prints the API's error object
# on *stdout* and gh's one-line summary on stderr, exiting 1 (this is what
# real `gh` does, and the gatherer reads the JSON rather than parsing that
# summary); any other failure prints only the stderr line, with no JSON body
# at all — the network-and-auth shape. On a hit, `$STUB_FORMAT` decides what
# the listing names: `peritem` (a TECH-DEBT.md policy blob plus a tech-debt
# tree) or `none` (no register directory). The tarball endpoint streams
# `$STUB_TARBALL`.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected call: $*" >&2; exit 1; }
case "${2:-}" in
  */git/trees/*)
    case "${STUB_MODE:-hit}" in
      hit)
        case "${STUB_FORMAT:-peritem}" in
          peritem)
            printf '{"tree":[{"path":"TECH-DEBT.md","type":"blob","sha":"%s"},{"path":"tech-debt","type":"tree","sha":"%s"}]}\n' \
              "$STUB_POLICY_SHA" "$STUB_TREE_SHA"
            ;;
          none)
            printf '{"tree":[{"path":"README.md","type":"blob","sha":"%s"}]}\n' \
              "$STUB_BLOB_SHA"
            ;;
        esac
        ;;
      404)
        echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
        ;;
      *)
        echo "gh: error connecting to api.github.com" >&2
        exit 1
        ;;
    esac
    ;;
  */tarball/*)
    cat "$STUB_TARBALL"
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# GitHub's tarballs wrap the tree in a single `<owner>-<repo>-<sha>/` root
# directory; the stub's are built the same way so the gatherer's extraction
# logic is exercised for real.
make_tarball() {
  local fixture="$1" out="$2" staging
  staging="$(mktemp -d)"
  mkdir -p "$staging/Poetic-Poems-poetic-abc1234"
  cp -r "$fixture"/. "$staging/Poetic-Poems-poetic-abc1234/"
  tar -czf "$out" -C "$staging" Poetic-Poems-poetic-abc1234
  rm -rf "$staging"
}

export STUB_BLOB_SHA="413128de0d60d9502bf469348bc70fbbacccf569"
export STUB_POLICY_SHA="9f2c11d34d5f0b6ba7a1c56d2e8f4a0b1c2d3e4f"
export STUB_TREE_SHA="5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f"
export STUB_TARBALL="$tmp_dir/register.tar.gz"
export STUB_MODE=hit
export STUB_FORMAT=peritem

run() {  # [void-json] prints stdout; stderr lands in $tmp_dir/err
  "$GATHER" "Poetic-Poems/poetic" main "${1:-[]}" 2>"$tmp_dir/err"
}

# --- A consistent register is [], a drifted one is exactly one candidate --------
#
# The root tree names a `tech-debt` directory, the register arrives as a
# tarball, and the checker runs against the directory. The drifted fixture
# carries a STALE FIELD, an ID MISMATCH and a BAD SCOPE so a change that
# stops reporting any one problem class fails here rather than quietly
# narrowing what this source can see.
make_tarball "$FIXTURES_DIR/tech-debt-items-consistent" "$STUB_TARBALL"
out="$(run)"; rc=$?
assert_eq "a consistent per-item register contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

make_tarball "$FIXTURES_DIR/tech-debt-items-drifted" "$STUB_TARBALL"
out="$(run)"; rc=$?
assert_eq "a drifted per-item register contributes exactly one candidate" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... and still exits 0" "0" "$rc"

# The per-item ref digests BOTH identity objects — the tech-debt tree and the
# policy blob that declares the scope — so a repair to either half retires it.
expected_ref="register-hygiene-$(printf '%s:%s' "$STUB_TREE_SHA" "$STUB_POLICY_SHA" | sha256sum | cut -c1-12)"
assert_eq "the per-item ref digests the tree and policy SHAs together" \
  "$expected_ref" "$(jq -r '.[0].ref' <<<"$out")"
assert_eq "blob_sha carries the tech-debt tree SHA" \
  "$STUB_TREE_SHA" "$(jq -r '.[0].blob_sha' <<<"$out")"
assert_eq "the url points at the register directory on the default branch" \
  "https://github.com/Poetic-Poems/poetic/tree/main/tech-debt" \
  "$(jq -r '.[0].url' <<<"$out")"
assert_eq "every per-item problem class in the fixture is reported" \
  "STALE FIELD ID MISMATCH BAD SCOPE" \
  "$(jq -r '[.[0].problems[] | .[0:15] | sub(" +$"; "")] | join(" ")' <<<"$out")"

# The body is the checker's report verbatim, naming the directory a human or
# an Implementer would type.
body="$(jq -r '.[0].body' <<<"$out")"
expected_body="$( cd "$tmp_dir" \
                  && rm -rf items && mkdir items \
                  && cp -r "$FIXTURES_DIR/tech-debt-items-drifted"/. items/ \
                  && cd items \
                  && perl "$SCRIPT_DIR/scripts/td-check.pl" tech-debt; true )"
assert_eq "per-item body is td-check.pl's output verbatim" "$expected_body" "$body"

# --- VOIDED STATUS: a void'd register row td-check.pl alone would miss ----------
# (requirement 34l, issue #240). td-check.pl finds the consistent fixture
# clean on its own; a void naming its still-`open` item must still surface a
# candidate.
make_tarball "$FIXTURES_DIR/tech-debt-items-consistent" "$STUB_TARBALL"

out="$(run '[]')"
assert_eq "an empty void list changes nothing: still []" "[]" "$out"

out="$(run '[{"item":"TD-PPtest-26071501","detail":"already fixed by #999","evidence":"see #999"}]')"
assert_eq "a void'd open item becomes exactly one candidate" "1" "$(jq 'length' <<<"$out")"
assert_eq "the problem names the file, the status and the void reason" \
  "VOIDED STATUS  tech-debt/TD-PPtest-26071501.md (status: open; void: already fixed by #999)" \
  "$(jq -r '.[0].problems[0]' <<<"$out")"
assert_eq "the body carries td-check.pl's (empty) report plus the void section" \
  "1" "$([[ "$(jq -r '.[0].body' <<<"$out")" == *"already fixed by #999"* ]] && echo 1 || echo 0)"
assert_eq "the ref is still scoped to register identity alone" \
  "$expected_ref" "$(jq -r '.[0].ref' <<<"$out" 2>/dev/null || true)"

out="$(run '[{"item":"TD-PPtest-26071502","detail":"already resolved"}]')"
assert_eq "a void naming an already-resolved item adds nothing" "[]" "$out"

out="$(run '[{"item":"TD-PPtest-99999999","detail":"no such file"}]')"
assert_eq "a void naming an item with no file on disk adds nothing" "[]" "$out"

# A drifted register (td-check.pl already flags it) plus an unrelated void'd
# item: both problem classes appear together, in one candidate.
make_tarball "$FIXTURES_DIR/tech-debt-items-drifted" "$STUB_TARBALL"
out="$(run '[{"item":"TD-PPtest-26071501","detail":"voided too"}]')"
assert_eq "td-check.pl problems and VOIDED STATUS coexist in one candidate" "1" \
  "$(jq 'length' <<<"$out")"
assert_eq "  ... carrying both problem classes" "true" \
  "$(jq -r '[.[0].problems[] | select(startswith("VOIDED STATUS"))] | length > 0' <<<"$out")"

# --- A repository with no register is a normal, silent [] -----------------------
#
# Not every repository keeps a register in either format — a root tree naming
# neither `TECH-DEBT.md` nor `tech-debt/`, or a repo (or branch) that is gone
# entirely (the 404), must never read as a problem to investigate. The stderr
# assertions are the ones that matter: they are what separate these cases
# from the failure below.
export STUB_FORMAT=none
out="$(run)"; rc=$?
assert_eq "a repository with no register contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... and says nothing on stderr — a missing register is not an error" \
  "" "$(cat "$tmp_dir/err")"
export STUB_FORMAT=peritem

export STUB_MODE=404
out="$(run)"; rc=$?
assert_eq "a repository that is gone (404) contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... and silently — the API body said 404, not error" \
  "" "$(cat "$tmp_dir/err")"

# --- An API failure is [] as well, but a loud one -------------------------------
#
# Same output, deliberately: a source that cannot look this cycle simply does not
# fire, and a cycle is never aborted by one. But the diagnosis reaches stderr,
# where agent-cycle.sh captures it per cycle. A silent []-on-error is the failure
# that already cost the sibling gatherers a debugging round.
export STUB_MODE=error
out="$(run)"; rc=$?
assert_eq "an API failure contributes [] too" "[]" "$out"
assert_eq "  ... and still exits 0" "0" "$rc"
assert_eq "  ... but leaves gh's diagnosis on stderr, unlike the 404" \
  "1" "$( [[ -s "$tmp_dir/err" ]] && echo 1 || echo 0 )"

# --- The gatherer fails safe against the real API too ---------------------------

assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$(PATH="${PATH#"$tmp_dir/bin:"}" "$GATHER" "Poetic-Poems/does-not-exist" main 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

# --- The argv cap (requirement 4g, TD-PPagop-26081503) ---
#
# $problems and $void_problems both grow with the register, and $body is
# rendered from the same set and is the larger of the two — all three used to
# ride into jq as --argjson/--arg. Past MAX_ARG_STRLEN (131072 bytes) the
# merge or the final build died at execve and this repo's whole
# register-hygiene candidate was lost.
#
# Not reached by driving the real script over its own CLI: a real drifted
# register's problem count never approaches the cap. So the merge and the
# final build are each lifted by their own literal lines instead, the same
# technique test/gather-human-visibility-hygiene.test.sh's extract_block
# uses, and driven directly with oversized accumulators.
extract_block() {  # extract_block <start-literal> <end-literal>
  awk -v s="$1" -v e="$2" \
    'index($0, s) == 1 { on = 1 } on { print } on && index($0, e) > 0 { exit }' \
    "$SCRIPT_DIR/scripts/gather-register-hygiene.sh"
}

# shellcheck disable=SC2016  # both single-quoted args are literal source text to match, not meant to expand
merge_line="$(extract_block 'problems="$(jq -nc' 'void_problems")"')"
# shellcheck disable=SC2016  # literal source text, not meant to expand
if [[ "$merge_line" != *'input as $a | input as $b | $a + $b'* ]]; then
  printf 'FAIL - could not extract the problems merge from scripts/gather-register-hygiene.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_merge_line() {  # run_merge_line <problems-json> <void_problems-json>
  # problems/void_problems are consumed only by the eval'd merge_line,
  # invisible to shellcheck.
  # shellcheck disable=SC2034
  ( problems="$1" void_problems="$2"; eval "$merge_line"; printf '%s' "$problems" )
}
big_problems="$(jq -nc '[range(1300) | ("BAD FIELD  tech-debt/TD-PPtest-" + (. | tostring) + ".md pad " + ("x" * 100))]')"
assert_eq "the oversized problems fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_problems" | wc -c) > 131072 ))"
merged="$(run_merge_line "$big_problems" '["VOIDED STATUS  the newest one"]')"
assert_eq "a merge onto an oversized problems array keeps every prior entry" \
  "1301" "$(jq 'length' <<<"$merged")"
assert_eq "  ... plus the void problem just merged in" "1" \
  "$(jq '[.[] | select(. == "VOIDED STATUS  the newest one")] | length' <<<"$merged")"

final_block="$(extract_block 'jq -nc' 'body_json"')"
if [[ "$final_block" != *'source: "register-hygiene"'* ]]; then
  printf 'FAIL - could not extract the final candidate build from scripts/gather-register-hygiene.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
run_final_block() {  # run_final_block <problems-json> <body-raw>
  local body_json
  # body_json is consumed only by the eval'd final_block inside the subshell
  # below (which inherits it), invisible to shellcheck.
  # shellcheck disable=SC2034
  body_json="$(jq -Rs . <<<"$2")"
  # problems/ref/url/dir_sha are consumed only by the eval'd final_block too.
  # shellcheck disable=SC2034
  ( problems="$1" ref="register-hygiene-abc123" \
    url="https://github.com/o/a/tree/main/tech-debt" dir_sha="deadbeef"
    eval "$final_block" )
}
big_problems_final="$(jq -nc '[range(1300) | ("BAD FIELD pad " + ("x" * 100))]')"
oversized_body="$(head -c 140000 < /dev/zero | tr '\0' 'x')"
assert_eq "the oversized register-hygiene body fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#oversized_body} > 131072 ))"
built="$(run_final_block "$big_problems_final" "$oversized_body")"
assert_eq "a problems array and body both past the argv cap still produce the candidate" "1" \
  "$(jq 'length' <<<"$built")"
assert_eq "  ... carrying every one of the 1300 problem lines" \
  "1300" "$(jq '.[0].problems | length' <<<"$built")"
# Compared in bash, not with `jq -r`: an oversized body is what this section
# exists to prove no longer rides through an --arg, but the comparison itself
# must not hit the same cap either.
assert_eq "  ... carrying the whole oversized body, not a truncation" "1" \
  "$([[ "$(jq -r '.[0].body' <<<"$built")" == "$oversized_body" ]] && echo 1 || echo 0)"
assert_eq "  ... with the source, ref and blob_sha intact" \
  "register-hygiene register-hygiene-abc123 deadbeef" \
  "$(jq -r '.[0] | "\(.source) \(.ref) \(.blob_sha)"' <<<"$built")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
