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

assert_pass() {  # assert_pass DESC BODY [BRANCH]
  local desc="$1" body="$2" branch="${3:-}"
  if "$CHECK" "$body" "$branch" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected exit 0)\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_fail() {  # assert_fail DESC BODY [NEEDLE] [BRANCH]
  local desc="$1" body="$2" needle="${3:-}" branch="${4:-}" err
  err="$("$CHECK" "$body" "$branch" 2>&1 >/dev/null)"
  if "$CHECK" "$body" "$branch" >/dev/null 2>&1; then
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

assert_pass "markdown emphasis around the keyword still passes" \
  "**Closes #55**
<!-- agent-ops:closes-issue item=55 -->"

# --- The keyword must be a word of its own, as it is to GitHub ---------------------
assert_fail "a word merely ending in a keyword does not close anything" \
  "This leaves #198 unclosed #198 for now.
<!-- agent-ops:closes-issue item=198 -->" \
  "#198"
assert_fail "\"discloses\" is not \"closes\"" \
  "The report discloses #77 in full.
<!-- agent-ops:closes-issue item=77 -->" \
  "#77"

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

# --- The branch anchor: `agent/<N>` demands presence, not just consistency ---------
# The Script mints `agent/<N>` (a bare issue number) for every work order
# whose item is one — the `issues` and `tech-debt` sources alike, since D15 as
# revised (#869/#875/#879) — and for nothing else, so the branch — which no
# model writes — demands both the marker and the keyword be *present*. Without
# this, an Implementer that forgot the marker passed trivially: the same
# silent prompt-skip the check exists to prevent.
assert_pass "an agent/<N> branch with marker and keyword passes" \
  "Closes #240.
<!-- agent-ops:closes-issue item=240 -->" \
  "agent/240"
assert_fail "an agent/<N> branch with no marker fails, naming the marker" \
  "Closes #240." \
  "closes-issue item=240" \
  "agent/240"
assert_fail "an agent/<N> branch with a marker but no keyword fails, naming the number" \
  "Implements #240.
<!-- agent-ops:closes-issue item=240 -->" \
  "#240" \
  "agent/240"
assert_fail "an agent/<N> branch with an empty body fails both ways" \
  "" \
  "closes-issue item=240" \
  "agent/240"
assert_fail "a forgotten marker still demands the keyword too" \
  "Some prose, no keyword, no marker." \
  "#240" \
  "agent/240"
assert_fail "a satisfied branch anchor does not excuse an unsatisfied second marker" \
  "Closes #240.
<!-- agent-ops:closes-issue item=240 -->
<!-- agent-ops:closes-issue item=2 -->" \
  "#2" \
  "agent/240"
# A tech-debt item is an issue too now, so its `agent/<N>` branch is anchored
# on the same terms — a `td-record` block alone never substitutes for the
# closing keyword the branch demands.
assert_fail "a tech-debt PR's agent/<N> branch demands the keyword too" \
  '<!-- agent-ops:closes-issue item=240 -->

```td-record
issue: 240
```' \
  "#240" \
  "agent/240"
assert_pass "a tech-debt PR carrying Fixes and the marker passes" \
  "Fixes #240.
<!-- agent-ops:closes-issue item=240 -->" \
  "agent/240"

# --- Non-numeric branches demand nothing -------------------------------------------
assert_pass "a non-numeric agent branch (slug shaped) demands nothing" \
  "A fix, nothing to close." "agent/td26072001-cache"
assert_pass "a register-hygiene branch demands nothing" \
  "Register housekeeping." "agent/register-hygiene-abc123"
assert_pass "a td/ claim branch demands nothing" \
  "A tech-debt fix." "td/TD-PPagop-26080101"
assert_pass "a human's branch demands nothing" \
  "Anything at all." "feature/agent/240-lookalike"
assert_pass "no branch argument at all keeps the marker-only behaviour" \
  "No marker here."

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
