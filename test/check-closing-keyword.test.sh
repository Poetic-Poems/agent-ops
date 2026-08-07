#!/usr/bin/env bash
#
# test/check-closing-keyword.test.sh — regression test for
# scripts/check-closing-keyword.sh (requirement 25a): the deterministic gate
# that stops "Implements #198" from repeating unnoticed.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/check-closing-keyword.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-closing-keyword.sh"

failures=0

assert_pass() {  # assert_pass DESC BODY
  local desc="$1" body="$2"
  if "$CHECK" "$body" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected exit 0)\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_fail() {  # assert_fail DESC BODY [NEEDLE]
  local desc="$1" body="$2" needle="${3:-}" err
  err="$("$CHECK" "$body" 2>&1 >/dev/null)"
  if "$CHECK" "$body" >/dev/null 2>&1; then
    printf 'FAIL - %s (expected non-zero exit)\n' "$desc"
    failures=$(( failures + 1 ))
    return
  fi
  if [[ -n "$needle" && "$err" != *"$needle"* ]]; then
    printf 'FAIL - %s\n     expected stderr to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$err"
    failures=$(( failures + 1 ))
    return
  fi
  printf 'ok   - %s\n' "$desc"
}

# --- No marker: every non-issue source passes trivially --------------------------
assert_pass "no marker at all" "A tech-debt fix, nothing to close."
assert_pass "prose that merely mentions an issue number, no marker" \
  "See #198 for background."

# --- The regression itself --------------------------------------------------------
assert_fail "prose describing intent is not a closing keyword" \
  "Implements #198.

<!-- agent-ops:closes-issue item=198 -->" \
  "#198"

# --- A real closing keyword passes ------------------------------------------------
assert_pass "Closes #N" "Closes #198.
<!-- agent-ops:closes-issue item=198 -->"
assert_pass "Fixes #N" "This Fixes #7 nicely.
<!-- agent-ops:closes-issue item=7 -->"
assert_pass "Resolves: #N (colon form)" "Resolves: #42
<!-- agent-ops:closes-issue item=42 -->"
assert_pass "case-insensitive keyword" "closes #198
<!-- agent-ops:closes-issue item=198 -->"
assert_pass "past-tense forms (fixed/closed/resolved)" "Fixed #9, closed #9 twice over.
<!-- agent-ops:closes-issue item=9 -->"

# --- The keyword must name the SAME number the marker names -----------------------
assert_fail "a closing keyword for the wrong number does not satisfy the marker" \
  "Closes #199.
<!-- agent-ops:closes-issue item=198 -->" \
  "#198"

# --- Multiple markers are each checked independently -------------------------------
assert_fail "one satisfied marker does not excuse a second, unsatisfied one" \
  "Closes #1.
<!-- agent-ops:closes-issue item=1 -->
<!-- agent-ops:closes-issue item=2 -->" \
  "#2"
assert_pass "two markers, both satisfied" \
  "Closes #1 and Fixes #2.
<!-- agent-ops:closes-issue item=1 -->
<!-- agent-ops:closes-issue item=2 -->"

# --- No PR body at all (defensive) --------------------------------------------------
assert_pass "an empty body has no marker to fail" ""

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
