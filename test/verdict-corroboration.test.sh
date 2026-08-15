#!/usr/bin/env bash
#
# test/verdict-corroboration.test.sh — regression tests for the Script-side
# pieces of requirements 3t/3u/3x (issues #310, #320, #322), all lifted whole
# out of agent-cycle.sh rather than reimplemented, so a change to the real
# function is what this suite exercises:
#
#   - exclude_blocked_or_void_items: every pre-fetched band's second exclusion
#     pass, applied once blocked_json/void_json are final — a candidate whose
#     ref is blocked or void for its own repo never reaches the Co-Ordinator,
#     the same deterministic-code decision exclude_claimed_items already makes
#     for claims (requirement 3q).
#   - coordinator_eligible_items: the Script's own answer to "what could the
#     Co-Ordinator actually have selected this cycle", across every band it
#     pre-fetches — the denominator the corroboration below is tested against
#     (requirement 3x). Its three non-obvious bands are the point: `issues` is
#     banded per entry and still carries blocked entries, and
#     `merge_conflicts` carries the one shape the prompt tells the model to
#     skip in silence.
#   - unaccounted_items: the machine corroboration a `selected: false` verdict
#     is tested against — which eligible items were neither reported in
#     needs_refinement under their own source nor voided, the evidence a
#     none-selected verdict misdescribing a band leaves behind (the
#     2026-08-10..12 incident requirement 3t exists for, generalised off the
#     one band it was proven on by requirement 3x).
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
#   ./test/verdict-corroboration.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"

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
unaccounted_items_src="$(extract_function unaccounted_items)"
coordinator_eligible_items_src="$(extract_function coordinator_eligible_items)"

for pair in \
  "exclude_blocked_or_void_items_src:exclude_blocked_or_void_items()" \
  "unaccounted_items_src:unaccounted_items()" \
  "coordinator_eligible_items_src:coordinator_eligible_items()"; do
  name="${pair%%:*}"
  needle="${pair#*:}"
  if [[ "${!name}" != *"$needle"* ]]; then
    printf 'FAIL - could not extract %s from agent-cycle.sh (renamed or moved?)\n' "$needle"
    exit 1
  fi
done

eval "$exclude_blocked_or_void_items_src"
eval "$unaccounted_items_src"
eval "$coordinator_eligible_items_src"

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

# --- The argv cap (requirement 4g) ---
# The blocked and void extracts are the two aggregates that crossed
# MAX_ARG_STRLEN (131072 bytes, the kernel's per-entry argv cap) on 2026-08-12
# — the void extract measured 133615 bytes that day. Delivered via `--argjson`,
# that made this function's jq die at execve and fall into its fail-open
# fallback, passing every candidate through *unfiltered*: blocked and void
# items back in front of the Co-Ordinator, which is exactly the unfiltered band
# requirement 3t exists to remove, restored precisely when the void record is
# largest. Requirement 4g moves the arrays onto stdin; this pins it, with a
# fixture the first assertion proves is genuinely past the cap.
BIG_VOID="$(jq -nc --argjson keep "$void" '
  [range(1300) | {repo: "Poetic-Poems/filler", item: ("TD-fill-" + tostring),
                  ts: "2026-07-01T00:00:00Z", detail: ("pad " + ("x" * 80)),
                  event: "item-void"}] + $keep')"
assert_eq "the oversized void fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$BIG_VOID" | wc -c) > 131072 ))"
assert_eq "a void extract past the argv cap still drops the void item" \
  '["TD1","TD3"]' \
  "$(jq -c 'map(.ref)' <<<"$(exclude_blocked_or_void_items "$cands" "org/a" '[]' "$BIG_VOID")")"

# =================================================================================
# coordinator_eligible_items
# =================================================================================

# One repo listing every band it has an array for, bar `code-quality` and the
# Medium/Low issue ranks — so the two assertions that matter most (a band whose
# token is absent is not eligible; an issue outside its own listed rank is not
# either) have something to be absent from.
eligible_repos='[{"slug":"org/a","default_branch":"main",
  "sources":["security","review-feedback","merge-conflicts","issues:high","abandoned-drafts",
             "human-visibility","tech-debt","register-hygiene"],
  "findings":[{"source":"security","ref":"dependabot-alert-1"},{"source":"code-quality","ref":"code-scanning-alert-4"}],
  "review_feedback":[{"ref":"pr-1-review-9"}],
  "merge_conflicts":[{"ref":"pr-2-conflict-aa","bot":true,"rebase_requested":false,"superseded_by":null},
                     {"ref":"pr-3-conflict-bb","bot":true,"rebase_requested":false,"superseded_by":"dependabot/npm/foo-2"},
                     {"ref":"pr-4-conflict-cc","bot":true,"rebase_requested":true,"superseded_by":null},
                     {"ref":"pr-5-conflict-dd"}],
  "abandoned_drafts":[{"ref":"pr-6-abandoned-ee"}],
  "human_visibility":[{"ref":"human-visibility-ff"}],
  "register_hygiene":[{"ref":"register-hygiene-gg"}],
  "issues":[{"ref":"11","priority":"High"},{"ref":"12","priority":"Medium"},{"ref":"13","priority":"High"}],
  "tech_debt":[{"ref":"TD1"},{"ref":"TD2"}]}]'

el="$(coordinator_eligible_items "$eligible_repos" '[{"repo":"org/a","item":"13"}]')"
band_of() { jq -c --arg s "$1" '[.[] | select(.source == $s) | .item]' <<<"$el"; }

assert_eq "a security finding is eligible under its own source token" '["dependabot-alert-1"]' "$(band_of security)"
assert_eq "the code-quality half of the same array is not — its token is unlisted" '[]' "$(band_of code-quality)"
assert_eq "review-feedback: presence in the array is the candidate test" '["pr-1-review-9"]' "$(band_of review-feedback)"
assert_eq "abandoned-drafts likewise" '["pr-6-abandoned-ee"]' "$(band_of abandoned-drafts)"
assert_eq "human-visibility likewise" '["human-visibility-ff"]' "$(band_of human-visibility)"
assert_eq "register-hygiene likewise" '["register-hygiene-gg"]' "$(band_of register-hygiene)"
assert_eq "tech-debt likewise, in id order" '["TD1","TD2"]' "$(band_of tech-debt)"

# merge-conflicts is the band with a Script-computable non-candidate in it: a
# never-nudged Dependabot PR is "not a candidate of any kind" per the prompt,
# so demanding an account for it would reject every verdict that correctly
# skipped it. Its superseded sibling is the opposite case — the prompt
# *requires* that one in `voided`, so it stays eligible and owes an account.
assert_eq "merge-conflicts drops the never-nudged Dependabot entry only" \
  '["pr-3-conflict-bb","pr-4-conflict-cc","pr-5-conflict-dd"]' "$(band_of merge-conflicts)"

# issues: banded per entry (requirement 15e), and still carrying blocked
# entries after requirement 3u's own narrower pass — neither of which any
# other band has to reckon with.
assert_eq "an issue outside its own listed rank is not eligible, and a blocked one is not either" \
  '["11"]' "$(band_of issues)"

# A blank `repo` on an old, pre-scoping event matches every repo — the same
# fallback exclude_blocked_or_void_items gives, mirrored here so the two
# passes cannot disagree about which issues the Co-Ordinator was offered.
assert_eq "a repo-less blocked entry suppresses that issue in every repo" '["13"]' \
  "$(jq -c '[.[] | select(.source == "issues") | .item]' \
     <<<"$(coordinator_eligible_items "$eligible_repos" '[{"item":"11"}]')")"

assert_eq "the plain issues token admits every band" '["11","12","13"]' \
  "$(jq -c '[.[] | select(.source == "issues") | .item]' \
     <<<"$(coordinator_eligible_items "$(jq -c 'map(.sources = ["issues"])' <<<"$eligible_repos")" '[]')")"

# Back-pressure (requirement 2.2a) narrows `sources` to lib/handoff.sh's four
# finishing bands (sourced above, issue #431) and empties `issues`/`tech_debt`,
# but leaves `findings`, `register_hygiene` and `human_visibility` populated.
# Reading the list rather than the arrays is what stops a restricted cycle
# owing an account of bands it was forbidden to select from. `eligible_repos`'s
# own `sources` only carries three of the four finishing bands (no
# `dequeued`), so that is all the narrowing below leaves behind.
bp_repos="$(jq -c 'map(.issues = [] | .tech_debt = [])' \
  <<<"$(handoff_narrow_repos_to_finishing_sources "$eligible_repos")")"
assert_eq "back-pressure's narrowed sources list bounds eligibility" \
  '["abandoned-drafts","merge-conflicts","review-feedback"]' \
  "$(jq -c '[.[].source] | unique' <<<"$(coordinator_eligible_items "$bp_repos" '[]')")"

assert_eq "a repo listing no sources at all offers nothing" "0" \
  "$(jq 'length' <<<"$(coordinator_eligible_items "$(jq -c 'map(.sources = [])' <<<"$eligible_repos")" '[]')")"
assert_eq "an entry with no ref is dropped, not emitted with an empty item" "0" \
  "$(jq 'length' <<<"$(coordinator_eligible_items '[{"slug":"org/a","sources":["tech-debt"],"tech_debt":[{"title":"no ref"}]}]' '[]')")"
assert_eq "malformed repos JSON degrades to []" "[]" "$(coordinator_eligible_items 'not json' '[]')"
assert_eq "malformed blocked JSON degrades to filtering nothing, not everything" "1" \
  "$(jq 'length' <<<"$(coordinator_eligible_items '[{"slug":"org/a","sources":["issues"],"issues":[{"ref":"11"}]}]' 'not json')")"

# =================================================================================
# unaccounted_items
# =================================================================================

eligible='[{"repo":"org/a","item":"TD1","source":"tech-debt"},{"repo":"org/a","item":"TD2","source":"tech-debt"}]'

# The exact shape of the incident: nothing selected, nothing reported, nothing
# voided — every eligible item is unaccounted for.
wo_silent='{"selected": false, "reason": "requires per-item evaluation", "needs_refinement": [], "voided": []}'
out="$(unaccounted_items "$wo_silent" "$eligible" '{}')"
assert_eq "a verdict that reports nothing leaves every eligible item unaccounted" "2" \
  "$(jq 'length' <<<"$out")"

# One properly reported, one still silently dropped.
wo_partial='{"selected": false, "reason": "one under-specified", "needs_refinement": [{"repo": "org/a", "item": "TD1", "source": "tech-debt"}], "voided": []}'
out="$(unaccounted_items "$wo_partial" "$eligible" '{}')"
assert_eq "a reported item is accounted for" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... and the unreported one is what's left" "TD2" "$(jq -r '.[0].item' <<<"$out")"

# needs_refinement from a different source does not account for a tech-debt item.
wo_wrong_source='{"selected": false, "needs_refinement": [{"repo": "org/a", "item": "TD1", "source": "issues"}], "voided": []}'
out="$(unaccounted_items "$wo_wrong_source" "$eligible" '{}')"
assert_eq "a report for a different source does not account for a tech-debt item" "2" \
  "$(jq 'length' <<<"$out")"

# A report for the right item in the right band of a *different repo* is not an
# account either: requirement 20 keys everything on repo+item, and issue
# numbers collide across repos constantly.
wo_wrong_repo='{"selected": false, "needs_refinement": [{"repo": "org/b", "item": "TD1", "source": "tech-debt"}], "voided": []}'
assert_eq "a report against another repo does not account for this repo's item" "2" \
  "$(jq 'length' <<<"$(unaccounted_items "$wo_wrong_repo" "$eligible" '{}')")"

# Voiding accounts for an item exactly like reporting it.
wo_voided='{"selected": false, "needs_refinement": [], "voided": [{"repo": "org/a", "item": "TD1"}]}'
out="$(unaccounted_items "$wo_voided" "$eligible" '{}')"
assert_eq "a voided item is accounted for" "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... and the untouched one is what's left" "TD2" "$(jq -r '.[0].item' <<<"$out")"

# `voided` carries no source (requirement 34c's shape), so it accounts for its
# repo+item in whichever band that item was eligible in.
mixed_eligible='[{"repo":"org/a","item":"11","source":"issues"},
                 {"repo":"org/a","item":"pr-3-conflict-bb","source":"merge-conflicts"},
                 {"repo":"org/a","item":"TD1","source":"tech-debt"}]'
wo_mixed_bands='{"selected": false,
  "needs_refinement": [{"repo": "org/a", "item": "11", "source": "issues"},
                       {"repo": "org/a", "item": "TD1", "source": "tech-debt"}],
  "voided": [{"repo": "org/a", "item": "pr-3-conflict-bb"}]}'
assert_eq "one verdict accounts for three different bands at once" "0" \
  "$(jq 'length' <<<"$(unaccounted_items "$wo_mixed_bands" "$mixed_eligible" '{}')")"

# The band survives onto the output, which is what lets the caller tag the
# rejection with it (requirement 3x) instead of reporting a bare count.
out="$(unaccounted_items '{}' "$mixed_eligible" '{}')"
assert_eq "every unaccounted entry carries the band it was eligible in" \
  '["issues","merge-conflicts","tech-debt"]' "$(jq -c '[.[].source] | sort' <<<"$out")"

# Both reported and voided: nothing left unaccounted.
wo_both='{"selected": false, "needs_refinement": [{"repo": "org/a", "item": "TD1", "source": "tech-debt"}], "voided": [{"repo": "org/a", "item": "TD2"}]}'
assert_eq "every eligible item accounted for leaves nothing unaccounted" "0" \
  "$(jq 'length' <<<"$(unaccounted_items "$wo_both" "$eligible" '{}')")"

# refinement_policy[<source>] == "required" is the one legitimate silent skip:
# nothing is ever unaccounted in that band, however loud the silence — and it
# is applied per entry's own source, so it exempts that band and no other.
policy_required='{"tech-debt": "required"}'
assert_eq "a required refinement policy exempts every eligible item in its band" "0" \
  "$(jq 'length' <<<"$(unaccounted_items "$wo_silent" "$eligible" "$policy_required")")"
assert_eq "  ... and only its band" '["issues","merge-conflicts"]' \
  "$(jq -c '[.[].source] | sort' <<<"$(unaccounted_items '{}' "$mixed_eligible" "$policy_required")")"
# "preferred" and "exempt" are not the silent-skip policy — only "required" is.
policy_preferred='{"tech-debt": "preferred"}'
assert_eq "a preferred refinement policy does not exempt anything" "2" \
  "$(jq 'length' <<<"$(unaccounted_items "$wo_silent" "$eligible" "$policy_preferred")")"

# An empty eligible set has nothing to be unaccounted.
assert_eq "an empty eligible set is never unaccounted" "0" \
  "$(jq 'length' <<<"$(unaccounted_items "$wo_silent" '[]' '{}')")"

# Malformed input degrades to [] (no false positive), not a crash.
assert_eq "malformed eligible JSON degrades to []" "[]" \
  "$(unaccounted_items "$wo_silent" "not json" '{}')"
assert_eq "malformed policy JSON degrades to treating the policy as absent" "2" \
  "$(jq 'length' <<<"$(unaccounted_items "$wo_silent" "$eligible" "not json")")"

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
out="$(unaccounted_items "$recorded" "$eligible" '{}')"
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

eligible_voids='[{"repo":"org/a","item":"TD1","source":"tech-debt"},{"repo":"org/a","item":"TD-REFUSED","source":"tech-debt"}]'
recorded="$(jq -nc --argjson v "$coord_recorded_voided_json" \
  '{needs_refinement: [], voided: $v}')"
assert_eq "a refused void still accounts for its item (the block de-eligibles it)" "0" \
  "$(jq 'length' <<<"$(unaccounted_items "$recorded" "$eligible_voids" '{}')")"

# --- The argv cap (requirement 4g, TD-PPagop-26081406) ---
#
# coord_recorded_refinement_json/coord_recorded_voided_json grow by one
# accepted entry per call and are what log_needs_refinement_items/
# log_voided_items fold the newest entry into — both used to ride into jq as
# a second --argjson alongside the growing accumulator itself (delivered on
# stdin already). Past MAX_ARG_STRLEN (131072 bytes) that fold died at
# execve, silently losing every report/void recorded so far — the accumulator
# reset to whatever the last successful append produced, not what the cycle
# actually recorded. Requirement 4g moves the new entry onto stdin too.
#
# Both functions reset their accumulator to `[]` at the top of every call
# (proved above: "no reports collects an empty array, not a stale one"), so
# an oversized accumulator can only be reached within a *single* call's own
# needs_refinement/voided array — not by seeding the variable and calling
# again. Driving that many real entries through the whole recording loop
# (event logging, the requirement 34d bar, the fold) is what made an earlier
# attempt at this section, in test/coordinator-retry-fallback.test.sh, run
# for minutes: each fold re-serialises the whole accumulator, so the total
# cost is quadratic in entry count. That file's own section pins the
# downstream build cheaply, by assigning the accumulator directly rather
# than re-deriving it; this one instead lifts the fold line itself — the
# same one-line pattern this file already runs for real above, now isolated
# — and proves it survives an already-oversized accumulator in one call, the
# same technique test/pr-claim-exclusion.test.sh's `extract_claims_fold` uses
# for the identical shape.
extract_fold_line() {  # extract_fold_line <accumulator-var-name>
  awk -v v="$1" 'index($0, v "=\"$(jq -nc") > 0 { print; getline; print; exit }' \
    "$SCRIPT_DIR/agent-cycle.sh"
}
refinement_fold_line="$(extract_fold_line coord_recorded_refinement_json)"
voided_fold_line="$(extract_fold_line coord_recorded_voided_json)"
if [[ "$refinement_fold_line" != *'coord_recorded_refinement_json'* ]]; then
  printf 'FAIL - could not extract the recorded-refinement fold from agent-cycle.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi
if [[ "$voided_fold_line" != *'coord_recorded_voided_json'* ]]; then
  printf 'FAIL - could not extract the recorded-voided fold from agent-cycle.sh (moved or reworded?)\n'
  failures=$(( failures + 1 ))
fi

big_seed="$(jq -nc '[range(1900) | {repo: "org/a", item: ("TD-fill-" + (. | tostring)),
  reason: "r", missing: "m", evidence: "e"}]')"
assert_eq "the oversized seed fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_seed" | wc -c) > 131072 ))"
entry='{"repo":"org/a","item":"TD1","source":"tech-debt","reason":"r","missing":"m","evidence":"e"}'

run_fold() {  # run_fold <fold-line> <var-name> <seed-json>
  # entry is consumed only by the eval'd fold line, invisible to shellcheck.
  # shellcheck disable=SC2034
  ( declare "$2=$3"; eval "$1"; printf '%s' "${!2}" )
}
folded_refinement="$(run_fold "$refinement_fold_line" coord_recorded_refinement_json "$big_seed")"
assert_eq "a fold onto an oversized recorded-refinement accumulator keeps every prior entry" \
  "1901" "$(jq 'length' <<<"$folded_refinement" 2>/dev/null || echo 0)"
assert_eq "  ... plus the newly-folded one" "1" \
  "$(jq '[.[] | select(.item == "TD1")] | length' <<<"$folded_refinement" 2>/dev/null || echo 0)"

folded_voided="$(run_fold "$voided_fold_line" coord_recorded_voided_json "$big_seed")"
assert_eq "a fold onto an oversized recorded-voided accumulator keeps every prior entry" \
  "1901" "$(jq 'length' <<<"$folded_voided" 2>/dev/null || echo 0)"
assert_eq "  ... plus the newly-folded one" "1" \
  "$(jq '[.[] | select(.item == "TD1")] | length' <<<"$folded_voided" 2>/dev/null || echo 0)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
