#!/usr/bin/env bash
#
# test/preflight.test.sh — regression test for lib/preflight.sh (issue #245):
# the done-check the Script runs on the item a cycle just claimed, before it
# pays for an Implementor engagement.
#
# `preflight_done_reason` is a thin, single-item wrapper around
# `work_gone_clearances` (test/work-gone.test.sh already covers that
# function's own decisions in depth), so what is asserted here is only the
# wrapping: the one-entry blocked list it synthesises, and that a repo/item
# with nothing to say about it decides nothing.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/preflight.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/lib/work-gone.sh"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"

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

states='[{"slug":"o/a","ok":true,
          "issues":[{"n":130}],
          "open_prs":[{"n":9}]}]'

assert_eq "a closed issue is already done" \
  "issue #125 is closed" \
  "$(preflight_done_reason o/a 125 "$states")"
assert_eq "an open issue is not" \
  "" "$(preflight_done_reason o/a 130 "$states")"

assert_eq "a finishing source's already-merged-or-closed PR is already done" \
  "pull request #146 is closed or merged" \
  "$(preflight_done_reason o/a pr-146-review-3312 "$states")"
assert_eq "one still open is not" \
  "" "$(preflight_done_reason o/a pr-9-abandoned-abc123abc123 "$states")"

register='{"o/a":{"TD26072401":"resolved","TD-PPpoet-26072605":"open"}}'
assert_eq "a tech-debt item the register already resolved is already done" \
  "the tech-debt register records it resolved" \
  "$(preflight_done_reason o/a TD26072401 "$states" "$register")"
assert_eq "one still open is not" \
  "" "$(preflight_done_reason o/a TD-PPpoet-26072605 "$states" "$register")"
assert_eq "and neither is a tech-debt item pre-flight never fetched a register row for" \
  "" "$(preflight_done_reason o/a TD26072401 "$states")"

assert_eq "a repo pre-flight has no digest for decides nothing" \
  "" "$(preflight_done_reason o/z 125 "$states")"
assert_eq "a repo whose digest could not be sampled decides nothing" \
  "" "$(preflight_done_reason o/a 125 '[{"slug":"o/a","ok":false}]')"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
