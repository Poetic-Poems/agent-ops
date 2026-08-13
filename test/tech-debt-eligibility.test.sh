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
#   - log_needs_refinement_items / log_voided_items: the recording loops whose
#     own collections (`coord_recorded_refinement_json`,
#     `coord_recorded_voided_json`) are what the corroboration is actually fed
#     — what the Script *recorded*, never what the message *claimed*. The
#     asymmetry between the two is the point under test: a needs_refinement
#     entry dropped at requirement 34d's bar records nothing and must not
#     account for its item (or the fingerprint arms on a verdict that never
#     engaged with the band — the freeze, reopened), while a voided entry the
#     guard refuses still accounts, because the refusal itself is recorded as
#     a block.
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

# =================================================================================
# The corroboration is fed what the Script recorded, never what the message
# claimed (PR #314 review). The two recording loops are lifted whole out of
# agent-cycle.sh; their recorders' *bars* are the real ones —
# refinement_entry_problem from lib/refinement.sh is requirement 34d's actual
# five-field test — while the event/label machinery behind them is stubbed out.
# =================================================================================

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"

log_needs_refinement_items_src="$(extract_function log_needs_refinement_items)"
log_voided_items_src="$(extract_function log_voided_items)"
if [[ "$log_needs_refinement_items_src" != *"coord_recorded_refinement_json"* ]]; then
  printf 'FAIL - could not extract log_needs_refinement_items from agent-cycle.sh (renamed, moved, or no longer collecting?)\n'
  exit 1
fi
if [[ "$log_voided_items_src" != *"coord_recorded_voided_json"* ]]; then
  printf 'FAIL - could not extract log_voided_items from agent-cycle.sh (renamed, moved, or no longer collecting?)\n'
  exit 1
fi
eval "$log_needs_refinement_items_src"
eval "$log_voided_items_src"

# The stubs. The recorder keeps requirement 34d's real bar and drops the event
# machinery — which entries it *accepts* is the behaviour under test, and
# the real record_needs_refinement_block accepts exactly those
# refinement_entry_problem passes (its only other refusal, an already-blocked
# item, can never be an eligible item: blocked items were excluded from
# eligibility before the Co-Ordinator ran).
record_needs_refinement_block() { refinement_entry_problem "$1" >/dev/null; }
log_event() { :; }
item_event_fields() { printf '{}'; }
release_refinement_label() { :; }
# The guard refuses TD-REFUSED and passes everything else, standing in for a
# live-evidence rejection (the reviewer's point: not a shape test, so the
# projection could never have pre-applied it).
void_guard_reason() {
  if [[ "$(jq -r '.item // ""' <<<"$1")" == "TD-REFUSED" ]]; then
    printf 'stub: evidence did not corroborate'
    return 1
  fi
  return 0
}

# Assigned inside the eval'd recording loops, which shellcheck cannot see into
# (SC2154); a sentinel rather than `[]`, so the assertions below also prove
# the loops really did reassign them rather than inheriting a plausible value.
coord_recorded_refinement_json='not yet assigned'
coord_recorded_voided_json='not yet assigned'

# --- needs_refinement: only a bar-clearing report is collected ------------------
complete_nr='{"repo":"org/a","item":"TD1","source":"tech-debt","reason":"r","missing":"m","evidence":"e"}'
bare_nr='{"repo":"org/a","item":"TD2","source":"tech-debt","reason":"r"}'
wo_mixed="$(jq -nc --argjson a "$complete_nr" --argjson b "$bare_nr" \
  '{selected: false, needs_refinement: [$a, $b], voided: []}')"

log_needs_refinement_items "$wo_mixed"
assert_eq "a bar-clearing report is collected as recorded" "1" \
  "$(jq 'length' <<<"$coord_recorded_refinement_json")"
assert_eq "  ... and it is the complete one" "TD1" \
  "$(jq -r '.[0].item' <<<"$coord_recorded_refinement_json")"

# The review's exact door: both eligible items reported, one report dropped at
# the bar — the dropped one's item must stay unaccounted, so the fingerprint
# is withheld and the next cycle re-asks instead of standing down.
recorded="$(jq -nc --argjson nr "$coord_recorded_refinement_json" \
  '{needs_refinement: $nr, voided: []}')"
out="$(tech_debt_unaccounted_items "$recorded" "$eligible" '{}')"
assert_eq "a report dropped at requirement 34d's bar does not account for its item" "1" \
  "$(jq 'length' <<<"$out")"
assert_eq "  ... and the dropped report's item is what's left" "TD2" \
  "$(jq -r '.[0].item' <<<"$out")"

log_needs_refinement_items '{"selected": false}'
assert_eq "no reports collects an empty array, not a stale one" "[]" \
  "$coord_recorded_refinement_json"

# --- voided: every disposed entry is collected, whichever way the guard rules --
void_ok='{"repo":"org/a","item":"TD1","reason":"already done","evidence":"e"}'
void_refused='{"repo":"org/a","item":"TD-REFUSED","reason":"already done","evidence":"e"}'
void_no_item='{"repo":"org/a","reason":"already done","evidence":"e"}'
wo_voids="$(jq -nc --argjson a "$void_ok" --argjson b "$void_refused" --argjson c "$void_no_item" \
  '{selected: false, needs_refinement: [], voided: [$a, $b, $c]}')"

log_voided_items "$wo_voids" '[]'
assert_eq "both disposed voided entries are collected — pass and refusal alike" "2" \
  "$(jq 'length' <<<"$coord_recorded_voided_json")"
assert_eq "  ... the refused one included, because its refusal is recorded as a block" "1" \
  "$(jq '[.[] | select(.item == "TD-REFUSED")] | length' <<<"$coord_recorded_voided_json")"
assert_eq "  ... but an entry naming no item, which records nothing, is not" "0" \
  "$(jq '[.[] | select(has("item") | not)] | length' <<<"$coord_recorded_voided_json")"

eligible_voids='[{"repo":"org/a","item":"TD1"},{"repo":"org/a","item":"TD-REFUSED"}]'
recorded="$(jq -nc --argjson v "$coord_recorded_voided_json" \
  '{needs_refinement: [], voided: $v}')"
assert_eq "a refused void still accounts for its item (the block de-eligibles it)" "0" \
  "$(jq 'length' <<<"$(tech_debt_unaccounted_items "$recorded" "$eligible_voids" '{}')")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
