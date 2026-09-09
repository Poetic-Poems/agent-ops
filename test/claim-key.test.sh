#!/usr/bin/env bash
#
# test/claim-key.test.sh — regression test for lib/claim-key.sh's `san()`
# (issue #967): `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` each
# build a `claims/<repo>/<key>.json` path in the state repository from the
# same `san()`-encoded shape, and used to do it from two separately typed
# copies of the function. A drift between them would make
# `sweep-orphan-branches.sh`'s registry lookups silently miss a real claim
# and let it delete a branch a peer node still owns — so this pins `san()`'s
# behaviour on every shape the two callers actually pass it: an `owner/repo`
# slug, a claim branch name (which may itself carry a `/`-separated prefix),
# and a tech-debt or record branch name.
#
# Also asserts both callers source the one definition rather than typing
# their own: a `san()` reappearing in either file is exactly the drift this
# item fixed.
#
# No network, no GitHub. Run directly:
#
#   ./test/claim-key.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# shellcheck source=lib/claim-key.sh
. "$SCRIPT_DIR/lib/claim-key.sh"

# --- Every shape sweep-orphan-branches.sh and lib/claim.sh actually pass -----
assert_eq "an owner/repo slug" "Pullwright__agent-ops" "$(san "Pullwright/agent-ops")"
assert_eq "a claim branch, one slash" "agent__42" "$(san "agent/42")"
assert_eq "a claim branch with its random suffix" \
  "agent__42-d208a9231aad" "$(san "agent/42-d208a9231aad")"
assert_eq "a tech-debt claim branch" \
  "td__TD-PPagop-26082411" "$(san "td/TD-PPagop-26082411")"
assert_eq "a td-record branch" \
  "td-record__TD-PPagop-26082411" "$(san "td-record/TD-PPagop-26082411")"
assert_eq "a finishing-source item ref" \
  "pr-350-conflict-d208a92310a1" "$(san "pr-350-conflict-d208a92310a1")"
assert_eq "a value with no slash at all is untouched" "plain" "$(san "plain")"
assert_eq "every slash is replaced, not just the first" \
  "a__b__c" "$(san "a/b/c")"

# --- Both callers source this file rather than typing their own copy --------
assert_eq "lib/claim.sh sources lib/claim-key.sh" "1" \
  "$(grep -c '^\. "\$SCRIPT_DIR/lib/claim-key\.sh"$' "$SCRIPT_DIR/lib/claim.sh")"
assert_eq "lib/claim.sh defines no san() of its own" "0" \
  "$(grep -c '^san()' "$SCRIPT_DIR/lib/claim.sh")"
assert_eq "sweep-orphan-branches.sh sources lib/claim-key.sh" "1" \
  "$(grep -c '^\. "\$SCRIPT_DIR/lib/claim-key\.sh"$' "$SCRIPT_DIR/scripts/sweep-orphan-branches.sh")"
assert_eq "sweep-orphan-branches.sh defines no san() of its own" "0" \
  "$(grep -c '^san()' "$SCRIPT_DIR/scripts/sweep-orphan-branches.sh")"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
