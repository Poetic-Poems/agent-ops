#!/usr/bin/env bash
#
# test/tech-debt-eligibility.test.sh — regression tests for requirement 3t's
# two Script-side pieces (issue #310), both lifted whole out of agent-cycle.sh
# rather than reimplemented, so a change to the real function is what this
# suite exercises:
#
#   - exclude_blocked_or_void_items: the tech_debt array's second exclusion
#     pass, applied once blocked_json/void_json are final — a candidate whose
#     ref is blocked or void for its own repo never reaches the Co-Ordinator,
#     the same deterministic-code decision exclude_claimed_items already makes
#     for claims (requirement 3q).
#   - tech_debt_unaccounted_items: the machine corroboration a `selected:
#     false` verdict is tested against — which eligible tech-debt items were
#     neither reported in needs_refinement nor voided, the evidence a
#     none-selected verdict misdescribing the band leaves behind (the
#     2026-08-10..12 incident this requirement exists for).
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/tech-debt-eligibility.test.sh
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

# --- Lift both functions whole out of agent-cycle.sh -----------------------------
extract_function() {  # extract_function <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh"
}

exclude_blocked_or_void_items_src="$(extract_function exclude_blocked_or_void_items)"
tech_debt_unaccounted_items_src="$(extract_function tech_debt_unaccounted_items)"

if [[ "$exclude_blocked_or_void_items_src" != *"exclude_blocked_or_void_items()"* ]]; then
  printf 'FAIL - could not extract exclude_blocked_or_void_items from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$tech_debt_unaccounted_items_src" != *"tech_debt_unaccounted_items()"* ]]; then
  printf 'FAIL - could not extract tech_debt_unaccounted_items from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi

eval "$exclude_blocked_or_void_items_src"
eval "$tech_debt_unaccounted_items_src"

# =================================================================================
# exclude_blocked_or_void_items
# =================================================================================

cands='[{"ref":"TD1"},{"ref":"TD2"},{"ref":"TD3"}]'
blocked='[{"repo":"org/a","item":"TD1","ts":"2026-08-01T00:00:00Z"}]'
void='[{"repo":"org/a","item":"TD2","ts":"2026-08-01T00:00:00Z"}]'

out="$(exclude_blocked_or_void_items "$cands" "org/a" "$blocked" "$void")"
assert_eq "a blocked item is dropped" "0" "$(jq '[.[] | select(.ref == "TD1")] | length' <<<"$out")"
assert_eq "a void item is dropped" "0" "$(jq '[.[] | select(.ref == "TD2")] | length' <<<"$out")"
assert_eq "an unrelated item survives" "1" "$(jq '[.[] | select(.ref == "TD3")] | length' <<<"$out")"
assert_eq "exactly one candidate remains" "1" "$(jq 'length' <<<"$out")"

assert_eq "the block/void does not apply to a different repo" "3" \
  "$(jq 'length' <<<"$(exclude_blocked_or_void_items "$cands" "org/b" "$blocked" "$void")")"

# A repo-less block/void entry (an old, pre-scoping event) matches every repo —
# the same fallback BLOCKED_ITEMS_JQ and the Co-Ordinator's own reading of
# `blocked`/`void` already give it.
repoless_blocked='[{"item":"TD1"}]'
assert_eq "a repo-less blocked entry matches any repo" "2" \
  "$(jq 'length' <<<"$(exclude_blocked_or_void_items "$cands" "org/z" "$repoless_blocked" '[]')")"

assert_eq "empty blocked/void changes nothing" "3" \
  "$(jq 'length' <<<"$(exclude_blocked_or_void_items "$cands" "org/a" '[]' '[]')")"
assert_eq "malformed blocked/void degrades to unfiltered" "$cands" \
  "$(exclude_blocked_or_void_items "$cands" "org/a" 'not json' 'also not json')"
assert_eq "a candidate with no ref is dropped, not crashed on" "0" \
  "$(jq 'length' <<<"$(exclude_blocked_or_void_items '[{"title":"no ref"}]' "org/a" '[]' '[]')")"

# =================================================================================
# tech_debt_unaccounted_items
# =================================================================================

eligible='[{"repo":"org/a","item":"TD1"},{"repo":"org/a","item":"TD2"}]'

# The exact shape of the incident: nothing selected, nothing reported, nothing
# voided — every eligible item is unaccounted for.
wo_silent='{"selected": false, "reason": "requires per-item evaluation", "needs_refinement": [], "voided": []}'
out="$(tech_debt_unaccounted_items "$wo_silent" "$eligible" '{}')"
assert_eq "a verdict that reports nothing leaves every eligible item unaccounted" "2" \
  "$(jq 'length' <<<"$out")"

# One properly reported, one still silently dropped.
wo_partial='{"selected": false, "reason": "one under-specified", "needs_refinement": [{"repo": "org/a", "item": "TD1", "source": "tech-debt"}], "voided": []}'
out="$(tech_debt_unaccounted_items "$wo_partial" "$eligible" '{}')"
assert_eq "a reported item is accounted for" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... and the unreported one is what's left" "TD2" "$(jq -r '.[0].item' <<<"$out")"

# needs_refinement from a different source does not account for a tech-debt item.
wo_wrong_source='{"selected": false, "needs_refinement": [{"repo": "org/a", "item": "TD1", "source": "issues"}], "voided": []}'
out="$(tech_debt_unaccounted_items "$wo_wrong_source" "$eligible" '{}')"
assert_eq "a report for a different source does not account for a tech-debt item" "2" \
  "$(jq 'length' <<<"$out")"

# Voiding accounts for an item exactly like reporting it.
wo_voided='{"selected": false, "needs_refinement": [], "voided": [{"repo": "org/a", "item": "TD1"}]}'
out="$(tech_debt_unaccounted_items "$wo_voided" "$eligible" '{}')"
assert_eq "a voided item is accounted for" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... and the untouched one is what's left" "TD2" "$(jq -r '.[0].item' <<<"$out")"

# Both reported and voided: nothing left unaccounted.
wo_both='{"selected": false, "needs_refinement": [{"repo": "org/a", "item": "TD1", "source": "tech-debt"}], "voided": [{"repo": "org/a", "item": "TD2"}]}'
assert_eq "every eligible item accounted for leaves nothing unaccounted" "0" \
  "$(jq 'length' <<<"$(tech_debt_unaccounted_items "$wo_both" "$eligible" '{}')")"

# refinement_policy.tech-debt == "required" is the one legitimate silent skip:
# nothing is ever unaccounted under it, however loud the silence.
policy_required='{"tech-debt": "required"}'
assert_eq "a required refinement policy exempts every eligible item" "0" \
  "$(jq 'length' <<<"$(tech_debt_unaccounted_items "$wo_silent" "$eligible" "$policy_required")")"
# "preferred" and "exempt" are not the silent-skip policy — only "required" is.
policy_preferred='{"tech-debt": "preferred"}'
assert_eq "a preferred refinement policy does not exempt anything" "2" \
  "$(jq 'length' <<<"$(tech_debt_unaccounted_items "$wo_silent" "$eligible" "$policy_preferred")")"

# An empty eligible set has nothing to be unaccounted.
assert_eq "an empty eligible set is never unaccounted" "0" \
  "$(jq 'length' <<<"$(tech_debt_unaccounted_items "$wo_silent" '[]' '{}')")"

# Malformed input degrades to [] (no false positive), not a crash.
assert_eq "malformed eligible JSON degrades to []" "[]" \
  "$(tech_debt_unaccounted_items "$wo_silent" "not json" '{}')"
assert_eq "malformed policy JSON degrades to treating the policy as absent" "2" \
  "$(jq 'length' <<<"$(tech_debt_unaccounted_items "$wo_silent" "$eligible" "not json")")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
