#!/usr/bin/env bash
#
# test/register-hygiene.test.sh — regression test for
# scripts/gather-register-hygiene.sh (requirement 3i): the source that notices a
# repository's TECH-DEBT.md has stopped agreeing with itself, and hands the
# repair to an ordinary Implementor.
#
# Four behaviours are asserted, and each of them fails silently if broken:
#
#   - **A consistent register contributes `[]`.** This is the answer almost every
#     cycle gets, and getting it wrong the other way files a repair pull request
#     against a file that is fine — hourly, in three repositories.
#   - **A drifted register contributes exactly one candidate**, whose `ref` is
#     scoped to the blob SHA, whose `problems` array holds one entry per problem
#     line, and whose `body` is the checker's output *verbatim*. The body is the
#     entire brief: every line names an id, a problem class and a line number,
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
# It answers the one endpoint the gatherer calls, in whichever of the three ways
# `$STUB_MODE` asks for, and reproduces GitHub's own shapes exactly: a hit is
# base64 `content` plus the blob `sha`; a 404 prints the API's error object on
# *stdout* and gh's one-line summary on stderr, exiting 1 (this is what real `gh`
# does, and the gatherer reads the JSON rather than parsing that summary); any
# other failure prints only the stderr line, with no JSON body at all — the
# network-and-auth shape.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" && "${2:-}" == */contents/TECH-DEBT.md ]] \
  || { echo "stub gh: unexpected call: $*" >&2; exit 1; }
case "${STUB_MODE:-hit}" in
  hit)
    printf '{"sha":"%s","encoding":"base64","content":"%s"}\n' \
      "$STUB_BLOB_SHA" "$(base64 -w0 <"$STUB_FILE")"
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
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

export STUB_BLOB_SHA="413128de0d60d9502bf469348bc70fbbacccf569"
export STUB_FILE="$FIXTURES_DIR/tech-debt-consistent.md"
export STUB_MODE=hit

run() {  # prints stdout; stderr lands in $tmp_dir/err
  "$GATHER" "Poetic-Poems/poetic" main 2>"$tmp_dir/err"
}

# --- A consistent register is not a candidate -----------------------------------

out="$(run)"; rc=$?
assert_eq "a consistent register contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# --- A drifted register is exactly one candidate --------------------------------
#
# One candidate, never one per problem: the file is either consistent or it is
# not, and either way the repair is a single pull request. The fixture carries a
# STALE BODY, a MISSING BODY and a NO LEDGER ROW so a change that stops
# reporting any one class fails here rather than quietly narrowing what this
# source can see.
export STUB_FILE="$FIXTURES_DIR/tech-debt-drifted.md"
out="$(run)"; rc=$?
assert_eq "a drifted register contributes exactly one candidate" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... and still exits 0 — this source never aborts a cycle" "0" "$rc"
assert_eq "the candidate names its source" \
  "register-hygiene" "$(jq -r '.[0].source' <<<"$out")"

# The ref is scoped to the register's blob SHA, not left bare. An item recorded
# blocked (requirement 34) stays blocked until something clears it, so a bare
# `register-hygiene` that an Implementor once failed to repair would still be
# blocked after the file had moved on. Scoping to the blob means a repair retires
# the ref, drift re-detected against an unchanged file keeps it, and a commit
# elsewhere in the repository leaves it — and so the item — untouched.
assert_eq "the ref pins to the first 12 chars of the blob SHA" \
  "register-hygiene-413128de0d60" "$(jq -r '.[0].ref' <<<"$out")"
assert_eq "the full blob SHA is carried too" \
  "$STUB_BLOB_SHA" "$(jq -r '.[0].blob_sha' <<<"$out")"
assert_eq "the url points at the register on the default branch" \
  "https://github.com/Poetic-Poems/poetic/blob/main/TECH-DEBT.md" \
  "$(jq -r '.[0].url' <<<"$out")"

# One string per problem line, each stripped of the report's indentation, in the
# checker's own order. The Co-Ordinator prices the item from this without
# parsing prose.
assert_eq "problems holds one entry per problem line" \
  "3" "$(jq '.[0].problems | length' <<<"$out")"
assert_eq "every problem class in the fixture is reported" \
  "STALE BODY MISSING BODY NO LEDGER ROW" \
  "$(jq -r '[.[0].problems[] | .[0:14] | sub(" +$"; "")] | join(" ")' <<<"$out")"
assert_eq "problem lines name their item" \
  "TD26071501 TD26071503 TD26071599" \
  "$(jq -r '[.[0].problems[] | capture("(?<id>TD[0-9]+)").id] | join(" ")' <<<"$out")"
assert_eq "problem lines are not indented — the report's leading spaces are stripped" \
  "0" "$(jq '[.[0].problems[] | select(startswith(" "))] | length' <<<"$out")"

# The body is the whole report, verbatim — summary line, status tally and every
# problem. It is what the work order pastes as the brief, so an assertion that it
# survives the round trip intact is an assertion about the Implementor's input.
body="$(jq -r '.[0].body' <<<"$out")"
expected_body="$( cd "$tmp_dir" \
                  && cp "$FIXTURES_DIR/tech-debt-drifted.md" TECH-DEBT.md \
                  && perl "$SCRIPT_DIR/scripts/td-check.pl" TECH-DEBT.md; true )"
assert_eq "body is td-check.pl's output verbatim" "$expected_body" "$body"
assert_eq "  ... and names the file as TECH-DEBT.md, not a scratch path" \
  "1" "$(grep -c '^TECH-DEBT\.md: ' <<<"$body")"

# --- A repository with no register is a normal, silent [] -----------------------
#
# Not every repository keeps a TECH-DEBT.md, and a 404 must never read as a
# problem to investigate. The stderr assertion is the one that matters: it is
# what separates this case from the one below.
export STUB_MODE=404
out="$(run)"; rc=$?
assert_eq "a repository with no register contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... and says nothing on stderr — a missing register is not an error" \
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

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
