#!/usr/bin/env bash
#
# test/closing-keyword-gate.test.sh — regression test for
# lib/closing-keyword-gate.sh (requirement 25a, TD-PPagop-26080803): the
# pipeline-side gate that enforces the closing-keyword rule for every target
# repository, not only the one carrying the CI workflow.
#
# `gh` is stubbed through CLOSING_KEYWORD_GATE_GH, the same convention
# test/review-gate.test.sh's stub uses. The checker itself is exercised
# end to end against the real scripts/check-closing-keyword.sh — this test
# is about the gate's own plumbing (does it read the right PR fields, does
# it report `clean`/`dirty<TAB>reason` correctly), not a re-test of the
# checker's own rules (test/check-closing-keyword.test.sh already covers
# those).
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/closing-keyword-gate.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/closing-keyword-gate.sh
. "$SCRIPT_DIR/lib/closing-keyword-gate.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

URL="https://github.com/Poetic-Poems/poetic-fiddle/pull/198"

# --- The stub gh --------------------------------------------------------------
# State lives in files:
#   $tmp_dir/pr.json   the `pr view --json body,headRefName` payload;
#                       "ERROR" makes the call fail (unreadable PR).
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr view" ]]; then
  content="$(cat "$d/pr.json" 2>/dev/null || echo '{}')"
  [[ "$content" == "ERROR" ]] && { echo "could not resolve pull request" >&2; exit 1; }
  printf '%s' "$content"
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/gh"
export CLOSING_KEYWORD_GATE_GH="$tmp_dir/gh"

set_pr() { printf '%s' "$1" >"$tmp_dir/pr.json"; }

# --- clean cases -------------------------------------------------------------

set_pr '{"body": "A tech-debt fix, nothing to close.", "headRefName": "td/TD-PPagop-26080803"}'
out="$(closing_keyword_gate "$URL")"; rc=$?
assert_eq "no marker, non-numeric branch: clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

set_pr '{"body": "Closes #198.\n<!-- agent-ops:closes-issue item=198 -->", "headRefName": "agent/198"}'
out="$(closing_keyword_gate "$URL")"; rc=$?
assert_eq "marker with a real closing keyword: clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# --- the regression itself: prose describing intent is not a keyword --------

set_pr '{"body": "Implements #198.\n<!-- agent-ops:closes-issue item=198 -->", "headRefName": "agent/198"}'
out="$(closing_keyword_gate "$URL")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "prose-only marker is dirty" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the missing issue" "#198" "$out"

# --- the branch anchor: agent/<N> demands the marker even if absent ---------

set_pr '{"body": "A plain PR body.", "headRefName": "agent/199"}'
out="$(closing_keyword_gate "$URL")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "agent/<N> branch with no marker is dirty" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the missing marker" "agent-ops:closes-issue item=199" "$out"

# --- gh itself failing to resolve the PR -------------------------------------

set_pr 'ERROR'
out="$(closing_keyword_gate "$URL")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "an unreadable pull request is dirty" "dirty" "${out%%$'\t'*}"

# --- an empty URL is dirty, not a crash --------------------------------------

out="$(closing_keyword_gate "")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "no URL at all is dirty" "dirty" "${out%%$'\t'*}"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
