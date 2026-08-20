#!/usr/bin/env bash
#
# test/escalation-autonomy.test.sh — regression test for
# lib/escalation-autonomy.sh (agent-ops#627).
#
# Narrower than test/merge-autonomy.test.sh's own coverage: there is exactly
# one function here, escalation_autonomy_configured_level — the same
# top-level-default/per-repo-override precedence stage_timeouts and
# merge_autonomy_configured_level both use — and no kill switch to test
# alongside it, per this file's own header on why one is pointless here.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/escalation-autonomy.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/escalation-autonomy.sh
. "$SCRIPT_DIR/lib/escalation-autonomy.sh"

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

# --- escalation_autonomy_configured_level ---

no_key_cfg='{}'
assert_eq "no escalation_autonomy key anywhere defaults to always-escalate" "always-escalate" \
  "$(escalation_autonomy_configured_level "$no_key_cfg" "acme/widgets")"

top_level_cfg='{"escalation_autonomy": "adjudicate-first"}'
assert_eq "the top-level key governs a repo with no override" "adjudicate-first" \
  "$(escalation_autonomy_configured_level "$top_level_cfg" "acme/widgets")"

override_cfg='{"escalation_autonomy": "adjudicate-first", "repos": [
  {"slug": "acme/widgets", "escalation_autonomy": "always-escalate"},
  {"slug": "acme/gizmos"}
]}'
assert_eq "a repo's own override wins over the top-level key" "always-escalate" \
  "$(escalation_autonomy_configured_level "$override_cfg" "acme/widgets")"
assert_eq "a repo with no override of its own falls through to the top-level key" "adjudicate-first" \
  "$(escalation_autonomy_configured_level "$override_cfg" "acme/gizmos")"
assert_eq "a repo absent from repos[] entirely still falls through to the top-level key" "adjudicate-first" \
  "$(escalation_autonomy_configured_level "$override_cfg" "acme/unlisted")"

null_top_level_cfg='{"escalation_autonomy": null}'
assert_eq "an explicit null top-level key reads as always-escalate, not the literal null" "always-escalate" \
  "$(escalation_autonomy_configured_level "$null_top_level_cfg" "acme/widgets")"

null_override_cfg='{"escalation_autonomy": "adjudicate-first", "repos": [
  {"slug": "acme/widgets", "escalation_autonomy": null}
]}'
assert_eq "an explicit null repo override falls through to the top-level key, not the literal null" \
  "adjudicate-first" "$(escalation_autonomy_configured_level "$null_override_cfg" "acme/widgets")"

assert_eq "malformed config falls back to always-escalate" "always-escalate" \
  "$(escalation_autonomy_configured_level 'not json' "acme/widgets")"

echo
if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
