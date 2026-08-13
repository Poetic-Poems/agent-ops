#!/usr/bin/env bash
#
# test/coordinator-retry-fallback.test.sh — regression test for requirement
# 3v (issue #321): a corroboration-rejected `none-selected` verdict gets one
# retry, quoting the Script's own contradiction, and — only if the retry is
# rejected too — a mechanical fallback selection, so a rejected verdict costs
# at most one extra Co-Ordinator engagement, never the cycle.
#
# `run_coordinator_stage_attempt`, `fallback_select_candidate` and
# `coordinator_corroborate_retry_or_fallback` are lifted verbatim out of
# agent-cycle.sh with awk, the same technique test/enabler-verdicts.test.sh
# uses for `maybe_run_enabler` — this cannot pass against a copy the script
# has since moved on from. `unaccounted_items`,
# `log_needs_refinement_items`, `log_voided_items`, `log_unblocked_items` and
# `log_recheck_clean_items` are lifted the same way, real, so the
# corroboration math under test is the genuine accounting rather than a
# paraphrase of it (test/verdict-corroboration.test.sh already covers those
# five in isolation; this file's job is the retry/fallback orchestration
# built on top of them). `run_claude_stage` is stubbed to answer a queued
# sequence of canned verdicts — one per call — so a scenario's first and
# second Co-Ordinator engagement can answer differently, the way a genuine
# retry does.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/coordinator-retry-fallback.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Lift the functions under test verbatim out of agent-cycle.sh ---------
extract_fn() {
  local start_pat="$1" file="$2"
  awk -v start="$start_pat" '
    $0 == start { on = 1 }
    on          { print }
    on && /^}$/ { exit }
  ' "$file"
}

unaccounted_items_fn="$(extract_fn 'unaccounted_items() {  # <recorded-json> <eligible-json> <refinement-policy-json>' "$SCRIPT_DIR/agent-cycle.sh")"
log_unblocked_items_fn="$(extract_fn 'log_unblocked_items() {' "$SCRIPT_DIR/agent-cycle.sh")"
log_recheck_clean_items_fn="$(extract_fn 'log_recheck_clean_items() {' "$SCRIPT_DIR/agent-cycle.sh")"
log_needs_refinement_items_fn="$(extract_fn 'log_needs_refinement_items() {' "$SCRIPT_DIR/agent-cycle.sh")"
log_voided_items_fn="$(extract_fn 'log_voided_items() {' "$SCRIPT_DIR/agent-cycle.sh")"
extract_json_result_fn="$(extract_fn 'extract_json_result() {' "$SCRIPT_DIR/agent-cycle.sh")"
run_coordinator_stage_attempt_fn="$(extract_fn 'run_coordinator_stage_attempt() {  # <attempt-out-file> <prompt> [extra-budget-json]' "$SCRIPT_DIR/agent-cycle.sh")"
fallback_select_candidate_fn="$(extract_fn 'fallback_select_candidate() {  # <ordered-repos-json> <default-model> <refinements-json> <refinement-policy-json>' "$SCRIPT_DIR/agent-cycle.sh")"
coordinator_corroborate_retry_or_fallback_fn="$(extract_fn 'coordinator_corroborate_retry_or_fallback() {' "$SCRIPT_DIR/agent-cycle.sh")"

for pair in \
  "unaccounted_items_fn:\$eligible" \
  "log_unblocked_items_fn:release_refinement_label" \
  "log_recheck_clean_items_fn:recheck-clean" \
  "log_needs_refinement_items_fn:coord_recorded_refinement_json" \
  "log_voided_items_fn:coord_recorded_voided_json" \
  "extract_json_result_fn:awk" \
  "run_coordinator_stage_attempt_fn:coord_attempt_result_json" \
  "fallback_select_candidate_fn:script-fallback" \
  "coordinator_corroborate_retry_or_fallback_fn:unaccounted_json"; do
  name="${pair%%:*}"
  needle="${pair#*:}"
  val="${!name}"
  if [[ "$val" != *"$needle"* ]]; then
    printf 'FAIL - %s could not be extracted from agent-cycle.sh (renamed or moved?)\n' "$name"
    exit 1
  fi
done

eval "$unaccounted_items_fn"
eval "$log_unblocked_items_fn"
eval "$log_recheck_clean_items_fn"
eval "$log_needs_refinement_items_fn"
eval "$log_voided_items_fn"
eval "$extract_json_result_fn"
eval "$run_coordinator_stage_attempt_fn"
eval "$fallback_select_candidate_fn"
eval "$coordinator_corroborate_retry_or_fallback_fn"

# --- Stubs for every dependency whose own correctness is not this test's job ---
#
# record_needs_refinement_block/void_guard_reason: the bar each guards is
# tested in depth elsewhere (test/tech-debt-eligibility.test.sh,
# test/void-guard.test.sh); here they always accept, so this file's own
# assertions are about *which* items reach them and how many times, not
# about the guards' own judgement.
calls_log=""
record() { printf '%s\n' "$*" >> "$calls_log"; }

log_event() { record "event $1 $2"; }
record_needs_refinement_block() { record "record_needs_refinement_block $(jq -r '.item' <<<"$1")"; return 0; }
void_guard_reason() { record "void_guard_reason $(jq -r '.item' <<<"$1")"; return 0; }
void_entry_evidence() { printf 'stub evidence'; }
item_event_fields() { printf '{}'; }
release_refinement_label() { record "release-refinement-label $1 ${2:-}"; }
stage_watchdog_warning() { printf ''; }
dump_stage_output() { :; }
detect_and_log_limit_hit() { return 1; }
stage_salvage_result() { return 1; }
handle_stage_failure() { record "handle_stage_failure $1 $2"; }
metering_fields() { printf '{"cost_usd":0.05,"duration_ms":1234}'; }
stage_budget_apply() {
  record "stage_budget_apply $1 $2 $3 ${4:-{\}}"
  # shellcheck disable=SC2034  # read only by the eval'd run_coordinator_stage_attempt
  stage_backstop_min=1
  # shellcheck disable=SC2034
  stage_inactivity_min=1
}

# run_claude_stage's stand-in: answers a queued sequence of canned verdicts,
# one per call (STUB_QUEUE_RC_<n>/STUB_QUEUE_JSON_<n>), so a scenario's first
# and second Co-Ordinator engagement can answer differently — the way a
# genuine retry does. Writes the envelope shape extract_json_result parses a
# real transcript's final message out of.
STUB_CALL_N=0
run_claude_stage() {
  local out_file="$5"
  STUB_CALL_N=$(( STUB_CALL_N + 1 ))
  record "run_claude_stage call=$STUB_CALL_N out=$(basename "$out_file")"
  local rc_var="STUB_QUEUE_RC_$STUB_CALL_N" json_var="STUB_QUEUE_JSON_$STUB_CALL_N"
  local rc="${!rc_var:-0}" body="${!json_var:-}"
  if [[ "$rc" == "0" && -n "$body" ]]; then
    jq -nc --arg r "$body" '{result: $r, session_id: "stub-session"}' > "$out_file"
  else
    : > "$out_file"
  fi
  # shellcheck disable=SC2034  # read by the eval'd functions, not visible here
  stage_gaps_json="null"
  # shellcheck disable=SC2034
  stage_kill_reason=""
  return "$rc"
}

# --- Fixed globals every call needs ---------------------------------------
# shellcheck disable=SC2034
coordinator_model="claude-test-model"
# shellcheck disable=SC2034
cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"
# shellcheck disable=SC2034
ONCE=0
# shellcheck disable=SC2034
DRY_RUN=0
# shellcheck disable=SC2034
implementor_model_default="claude-fallback-model"
# shellcheck disable=SC2034
coordinator_prompt="stub base prompt"
# shellcheck disable=SC2034
refinement_policy_json='{}'
# shellcheck disable=SC2034  # read by the eval'd fallback_select_candidate call
refinements_json='{}'
# shellcheck disable=SC2034
noop_fingerprint_value="fp-abc123"

events_named() {  # events_named LOG NAME -> each matching event's JSON payload, one per line
  grep -E "^event $2 " <<<"$1" | sed -E "s/^event $2 //"
}

# eligible: two open tech-debt items this cycle, both unclaimed/unblocked/not void
eligible='[{"repo":"acme/widgets","item":"TD1","source":"tech-debt"},{"repo":"acme/widgets","item":"TD2","source":"tech-debt"}]'

# ordered_repos_json: one repo, a tech-debt band carrying both eligible items
# plus a security finding that outranks them, for the fallback band-order
# assertions below.
repos_with_security='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality","register-hygiene"],
  "findings":[{"source":"security","kind":"dependabot","severity":"high","ref":"dependabot-alert-1","title":"bump foo","package":"foo","url":"https://x/1"}],
  "review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"},
               {"source":"tech-debt","ref":"TD2","id":"TD2","title":"fix TD2","filed":"2026-08-01","url":"https://x/TD2.md","body":"TD2 body"}],
  "register_hygiene":[]}]'
repos_tech_debt_only='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality","register-hygiene"],
  "findings":[],"review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"},
               {"source":"tech-debt","ref":"TD2","id":"TD2","title":"fix TD2","filed":"2026-08-01","url":"https://x/TD2.md","body":"TD2 body"}],
  "register_hygiene":[]}]'

# run_full_scenario DESC ATTEMPT1_JSON ATTEMPT2_RC ATTEMPT2_JSON REPOS_JSON
# Reconstructs the real flow exactly: attempt 1 runs outside the function
# under test (as agent-cycle.sh's own top level does), its four recording
# loops run on its message, and only then — if it reports selected != true —
# is coordinator_corroborate_retry_or_fallback called, which is where the
# retry (call 2) and any fallback selection happen. Sets `fn_rc` to the
# function's own return code (or "n/a" if attempt 1 already selected) and
# prints the accumulated calls log.
run_full_scenario() {
  local desc="$1" attempt1_json="$2" attempt2_rc="$3" attempt2_json="$4" repos_json="$5"
  calls_log="$tmp_dir/calls-$RANDOM.log"
  : > "$calls_log"
  STUB_CALL_N=0
  # Read only by the stubbed run_claude_stage, by name via ${!rc_var}/${!json_var} —
  # invisible to shellcheck, hence one disable per assignment below.
  # shellcheck disable=SC2034
  STUB_QUEUE_RC_1=0
  # shellcheck disable=SC2034
  STUB_QUEUE_JSON_1="$attempt1_json"
  # shellcheck disable=SC2034
  STUB_QUEUE_RC_2="$attempt2_rc"
  # shellcheck disable=SC2034
  STUB_QUEUE_JSON_2="$attempt2_json"
  # shellcheck disable=SC2034  # read only by the eval'd functions
  eligible_items_json="$eligible"
  # shellcheck disable=SC2034
  eligible_items_total="$(jq 'length' <<<"$eligible")"
  # shellcheck disable=SC2034
  ordered_repos_json="$repos_json"

  if ! run_coordinator_stage_attempt "$cycle_dir/attempt1.out" "stub prompt one"; then
    fn_rc="attempt1-failed"
    cat "$calls_log"
    return
  fi
  # shellcheck disable=SC2154  # set by the eval'd run_coordinator_stage_attempt
  work_order_json="$coord_attempt_result_json"
  log_unblocked_items "$work_order_json"
  log_recheck_clean_items "$work_order_json"
  log_voided_items "$work_order_json" "$repos_json"
  log_needs_refinement_items "$work_order_json"

  selected="$(jq -r '.selected' <<<"$work_order_json")"
  if [[ "$selected" != "true" ]]; then
    if coordinator_corroborate_retry_or_fallback; then
      fn_rc=0
    else
      fn_rc=1
    fi
  else
    fn_rc="n/a"
  fi
  cat "$calls_log"
}

# ============================================================================
# fallback_select_candidate: band order and per-source shapes
# ============================================================================
sec_pick="$(fallback_select_candidate "$repos_with_security" "claude-fallback-model")"
assert_eq "security outranks tech-debt in the same repo" "security" "$(jq -r '.source' <<<"$sec_pick")"
assert_eq "security pick names the finding's own ref" "dependabot-alert-1" "$(jq -r '.item' <<<"$sec_pick")"

td_pick="$(fallback_select_candidate "$repos_tech_debt_only" "claude-fallback-model")"
assert_eq "tech-debt is the fallback when no higher band has anything" "tech-debt" "$(jq -r '.source' <<<"$td_pick")"
assert_eq "tech-debt pick is the first eligible ref (id order)" "TD1" "$(jq -r '.item' <<<"$td_pick")"
assert_eq "a mechanical pick names its own model" "claude-fallback-model" "$(jq -r '.model' <<<"$td_pick")"
assert_contains "a mechanical pick's context pastes the item's own body" "TD1 body" "$(jq -r '.context' <<<"$td_pick")"

empty_repos='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality","register-hygiene"],"findings":[],"review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],"tech_debt":[],"register_hygiene":[]}]'
assert_eq "every band empty prints null, not a crash" "null" "$(fallback_select_candidate "$empty_repos" "m")"

takeover_repos='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality","register-hygiene"],"findings":[],"review_feedback":[],
  "merge_conflicts":[{"ref":"pr-9-conflict-abc","pr_number":9,"pr_url":"https://x/pull/9","title":"bump foo","branch":"dependabot/npm/foo","base":"main","body":"bump","bot":true,"rebase_requested":true,"superseded_by":null}],
  "abandoned_drafts":[],"human_visibility":[],"issues":[],"tech_debt":[],"register_hygiene":[]}]'
tk_pick="$(fallback_select_candidate "$takeover_repos" "m")"
assert_eq "a Dependabot takeover candidate carries takeover:true" "true" "$(jq -r '.takeover' <<<"$tk_pick")"
assert_eq "…and omits branch" "null" "$(jq -r '.branch // null' <<<"$tk_pick")"
assert_eq "…but keeps pr_number" "9" "$(jq -r '.pr_number' <<<"$tk_pick")"

never_nudged_repos='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality","register-hygiene"],"findings":[],"review_feedback":[],
  "merge_conflicts":[{"ref":"pr-9-conflict-abc","pr_number":9,"pr_url":"https://x/pull/9","title":"bump foo","branch":"dependabot/npm/foo","base":"main","body":"bump","bot":true,"rebase_requested":false,"superseded_by":null}],
  "abandoned_drafts":[],"human_visibility":[],"issues":[],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"}],
  "register_hygiene":[]}]'
nn_pick="$(fallback_select_candidate "$never_nudged_repos" "m")"
assert_eq "a never-nudged Dependabot entry is skipped, not a candidate" "tech-debt" "$(jq -r '.source' <<<"$nn_pick")"

rf_repos='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality","register-hygiene"],"findings":[],
  "review_feedback":[{"ref":"pr-57-review-1","pr_number":57,"pr_url":"https://x/pull/57","title":"fix x","branch":"agent/td1","item":"TD1","body":"review body"}],
  "merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],"tech_debt":[],"register_hygiene":[]}]'
rf_pick="$(fallback_select_candidate "$rf_repos" "m")"
assert_eq "review-feedback carries its own branch verbatim" "agent/td1" "$(jq -r '.branch' <<<"$rf_pick")"
assert_eq "…and its own pr_url" "https://x/pull/57" "$(jq -r '.pr_url' <<<"$rf_pick")"

assert_eq "no internal ranking key leaks onto the winning candidate" "null" \
  "$(jq -r '._rank // null' <<<"$rf_pick")"

# --- refinement_policy binds the mechanical pick as it binds the Co-Ordinator ---
# `required`: an unrefined item from that source is not a candidate at all, so
# a *lower* band wins instead of it — the mechanical path must not be able to
# select what no Co-Ordinator engagement was allowed to rank.
td_and_hygiene='[{"slug":"acme/widgets","default_branch":"main",
  "sources":["security","issues:urgent","review-feedback","merge-conflicts","human-visibility","abandoned-drafts","issues:high","tech-debt","issues:medium","issues:low","code-quality","register-hygiene"],
  "findings":[],"review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],"issues":[],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"}],
  "register_hygiene":[{"source":"register-hygiene","ref":"RH1","body":"stale row","url":"https://x/rh","blob_sha":"abc","problems":["orphan"]}]}]'
refined_td1='{"acme/widgets":{"TD1":{"ts":"2026-08-12T00:00:00Z","cycle":"c1","spec":"do this"}}}'

assert_eq "an unrefined item from a required source is skipped, and a lower band wins" \
  "register-hygiene" \
  "$(jq -r '.source' <<<"$(fallback_select_candidate "$td_and_hygiene" "m" '{}' '{"tech-debt":"required"}')")"
assert_eq "…and a refined one from that same source is selected normally" "tech-debt" \
  "$(jq -r '.source' <<<"$(fallback_select_candidate "$td_and_hygiene" "m" "$refined_td1" '{"tech-debt":"required"}')")"
assert_eq "…while an exempt source (the default) ignores refinement entirely" "tech-debt" \
  "$(jq -r '.source' <<<"$(fallback_select_candidate "$td_and_hygiene" "m" '{}' '{}')")"

# `preferred`: no exclusion, a thumb on the scale — the refined item wins its
# band over an unrefined one that precedes it, and an all-unrefined band is
# still perfectly selectable.
refined_td2='{"acme/widgets":{"TD2":{"ts":"2026-08-12T00:00:00Z","cycle":"c1","spec":"do this"}}}'
assert_eq "a preferred source ranks its refined item ahead of an earlier unrefined one" "TD2" \
  "$(jq -r '.item' <<<"$(fallback_select_candidate "$repos_tech_debt_only" "m" "$refined_td2" '{"tech-debt":"preferred"}')")"
assert_eq "…and with nothing refined, band order still decides" "TD1" \
  "$(jq -r '.item' <<<"$(fallback_select_candidate "$repos_tech_debt_only" "m" '{}' '{"tech-debt":"preferred"}')")"
assert_eq "a required source with nothing refined anywhere leaves no candidate" "null" \
  "$(fallback_select_candidate "$repos_tech_debt_only" "m" '{}' '{"tech-debt":"required"}')"
assert_eq "an unreadable refinements/policy argument degrades to exempt, not to a crash" "tech-debt" \
  "$(jq -r '.source' <<<"$(fallback_select_candidate "$repos_tech_debt_only" "m" 'not json' 'not json')")"

# --- `sources` bounds the mechanical pick exactly as it bounds the model ----
# Requirement 3x. Before it, the gate could only fire over `tech_debt`, which
# requirement 2.2a's back-pressure *empties*, so this path was unreachable on
# a restricted cycle; a gate that also counts the finishing sources makes it
# reachable, and a fallback reading only the arrays would answer it by
# starting fresh work through a full human gate — the one thing back-pressure
# exists to stop.
bp_repos="$(jq -c 'map(.sources = ["review-feedback","merge-conflicts","abandoned-drafts"]
                      | .issues = [] | .tech_debt = [])' <<<"$repos_with_security")"
assert_eq "a band narrowed out of sources is not a band the fallback may pick from" "null" \
  "$(fallback_select_candidate "$bp_repos" "m")"
assert_eq "…and the same repo with the token restored picks it again" "security" \
  "$(jq -r '.source' <<<"$(fallback_select_candidate "$repos_with_security" "m")")"

# An issue is banded per entry, so its *rank token* gates it, not the plain
# `issues` one — a repo configured `issues:high` alone was never offered its
# Medium issues, and the mechanical pick must not offer them either.
issue_repos='[{"slug":"acme/widgets","default_branch":"main","sources":["issues:high","tech-debt"],
  "findings":[],"review_feedback":[],"merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],
  "issues":[{"source":"issues","ref":"12","number":12,"priority":"Medium","title":"medium one","body":"b","comments":[]},
            {"source":"issues","ref":"11","number":11,"priority":"High","title":"high one","body":"b","comments":[]}],
  "tech_debt":[{"source":"tech-debt","ref":"TD1","id":"TD1","title":"fix TD1","filed":"2026-08-01","url":"https://x/TD1.md","body":"TD1 body"}],
  "register_hygiene":[]}]'
assert_eq "only the listed issue rank is reachable — High outranks tech-debt" "11" \
  "$(jq -r '.item' <<<"$(fallback_select_candidate "$issue_repos" "m")")"
assert_eq "…and the unlisted Medium rank never wins, even with tech-debt gone" "null" \
  "$(fallback_select_candidate "$(jq -c 'map(.issues = [.issues[] | select(.priority == "Medium")] | .tech_debt = [])' <<<"$issue_repos")" "m")"

# ============================================================================
# run_coordinator_stage_attempt: launch, parse, and retry-tagging mechanics
# ============================================================================
calls_log="$tmp_dir/calls-attempt.log"
: > "$calls_log"
STUB_CALL_N=0
STUB_QUEUE_RC_1=0
STUB_QUEUE_JSON_1='{"selected":false,"reason":"nothing here"}'
run_coordinator_stage_attempt "$cycle_dir/a1.out" "prompt one"
assert_eq "a plain attempt's stage-start carries no retry tag" "0" \
  "$(grep -cE 'stage_budget_apply coordinator \* claude-test-model \{"retry":true\}' "$calls_log")"
assert_eq "a plain attempt's stage-end is stage:coordinator, no retry field" "1" \
  "$(events_named "$(cat "$calls_log")" stage-end | jq -s '[.[] | select(.retry == null)] | length')"

: > "$calls_log"
STUB_CALL_N=0
STUB_QUEUE_RC_1=0
STUB_QUEUE_JSON_1='{"selected":true}'
run_coordinator_stage_attempt "$cycle_dir/a2.out" "prompt two" '{"retry": true}'
assert_contains "a retry's stage_budget_apply carries the retry tag" \
  'stage_budget_apply coordinator * claude-test-model {"retry": true}' "$(cat "$calls_log")"
se_evt="$(events_named "$(cat "$calls_log")" stage-end | head -n1)"
assert_eq "a retry's stage-end carries retry:true" "true" "$(jq -r '.retry' <<<"$se_evt")"
assert_eq "…and this attempt's own cost fields" "0.05" "$(jq -r '.cost_usd' <<<"$se_evt")"

: > "$calls_log"
STUB_CALL_N=0
STUB_QUEUE_RC_1=1
if run_coordinator_stage_attempt "$cycle_dir/a3.out" "prompt three"; then
  fn_rc=0
else
  fn_rc=1
fi
assert_eq "a launch failure returns non-zero" "1" "$fn_rc"
assert_contains "…and calls handle_stage_failure" "handle_stage_failure coordinator 1" "$(cat "$calls_log")"

: > "$calls_log"
STUB_CALL_N=0
# shellcheck disable=SC2034  # read only by the stubbed run_claude_stage
STUB_QUEUE_RC_1=0
# shellcheck disable=SC2034
STUB_QUEUE_JSON_1=""
if run_coordinator_stage_attempt "$cycle_dir/a4.out" "prompt four"; then
  fn_rc=0
else
  fn_rc=1
fi
assert_eq "an unparseable message returns non-zero" "1" "$fn_rc"
assert_contains "…and logs attempt-failed naming it" "unparseable final message" "$(cat "$calls_log")"

# ============================================================================
# coordinator_corroborate_retry_or_fallback: the full retry/fallback orchestration
# ============================================================================

# --- Retry succeeds: attempt 1 rejected, attempt 2 selects -----------------
attempt1='{"selected":false,"reason":"nothing here","needs_refinement":[
  {"repo":"acme/widgets","item":"TD1","source":"tech-debt","reason":"r","missing":"m","evidence":"e"}]}'
attempt2='{"selected":true,"candidates":[{"repo":"acme/widgets","default_branch":"main","source":"tech-debt","item":"TD2","title":"fix TD2","model":"m","model_reason":"mr","context":"c","acceptance":"a"}]}'
# Not `calls="$(run_full_scenario ...)"`: command substitution runs the
# function in a subshell, so its global assignments (fn_rc, work_order_json,
# selected, ...) would never reach this shell — only its stdout would.
# Redirecting to a file instead runs it here, in this shell, for real.
run_full_scenario "retry succeeds" "$attempt1" 0 "$attempt2" "$repos_tech_debt_only" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"

assert_eq "retry succeeds: two run_claude_stage calls" "2" \
  "$(grep -cE '^run_claude_stage call=' <<<"$calls")"
assert_eq "retry succeeds: function returns 0 (ready for 5b)" "0" "$fn_rc"
assert_eq "retry succeeds: work_order_json becomes the retry's own" "TD2" \
  "$(jq -r '.candidates[0].item' <<<"$work_order_json")"
assert_eq "retry succeeds: selected is now true" "true" "$selected"
c1="$(events_named "$calls" corroboration | sed -n '1p')"
c2="$(events_named "$calls" corroboration | sed -n '2p')"
assert_eq "retry succeeds: attempt 1's corroboration is rejected" "rejected" "$(jq -r '.verdict' <<<"$c1")"
assert_eq "retry succeeds: attempt 2's corroboration is accepted-by-selection" "accepted-by-selection" "$(jq -r '.verdict' <<<"$c2")"
assert_eq "retry succeeds: attempt 2's corroboration carries this retry's own cost" "0.05" "$(jq -r '.cost_usd' <<<"$c2")"
assert_eq "retry succeeds: no none-selected event at all" "0" \
  "$(grep -cE '^event none-selected ' <<<"$calls")"

# --- Retry corroborates cleanly: attempt 1 rejected, attempt 2 fully accounts ---
attempt2_clean='{"selected":false,"reason":"still nothing, refined the rest","needs_refinement":[
  {"repo":"acme/widgets","item":"TD2","source":"tech-debt","reason":"r","missing":"m","evidence":"e"}]}'
run_full_scenario "retry corroborates" "$attempt1" 0 "$attempt2_clean" "$repos_tech_debt_only" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"

assert_eq "retry corroborates: function returns 1 (caller should exit)" "1" "$fn_rc"
assert_eq "retry corroborates: two corroboration events" "2" \
  "$(grep -cE '^event corroboration ' <<<"$calls")"
c1="$(events_named "$calls" corroboration | sed -n '1p')"
c2="$(events_named "$calls" corroboration | sed -n '2p')"
assert_eq "retry corroborates: attempt 1 rejected" "rejected" "$(jq -r '.verdict' <<<"$c1")"
assert_eq "retry corroborates: attempt 2 accepted" "accepted" "$(jq -r '.verdict' <<<"$c2")"
assert_eq "retry corroborates: exactly one none-selected" "1" \
  "$(grep -cE '^event none-selected ' <<<"$calls")"
ns_evt="$(events_named "$calls" none-selected | head -n1)"
assert_eq "retry corroborates: none-selected carries the retry's own reason" \
  "still nothing, refined the rest" "$(jq -r '.reason' <<<"$ns_evt")"
assert_eq "retry corroborates: none-selected carries the fingerprint" "fp-abc123" "$(jq -r '.fingerprint' <<<"$ns_evt")"

# --- Fallback fires: both attempts rejected ---------------------------------
attempt2_stillrejected='{"selected":false,"reason":"retried and still nothing"}'
run_full_scenario "fallback fires" "$attempt1" 0 "$attempt2_stillrejected" "$repos_tech_debt_only" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"

assert_eq "fallback fires: function returns 0 (ready for 5b)" "0" "$fn_rc"
assert_eq "fallback fires: two warning events (one per rejected attempt)" "2" \
  "$(grep -cE '^event warning ' <<<"$calls")"
assert_eq "fallback fires: two corroboration events, both rejected" "2" \
  "$(events_named "$calls" corroboration | jq -s '[.[] | select(.verdict == "rejected")] | length')"
# A cycle that recovers mechanically selected something, so it logs no
# none-selected at all: that event names the cycle's outcome (requirement 3b's
# fingerprint and the dashboard's outcome precedence both read it that way),
# and the rejected verdict itself is already on the record twice over, in the
# warning and the corroboration event.
assert_eq "fallback fires: no none-selected event — the cycle selected something" "0" \
  "$(grep -cE '^event none-selected ' <<<"$calls")"
assert_eq "fallback fires: the second corroboration still carries the rejected verdict's reason" \
  "retried and still nothing" \
  "$(events_named "$calls" corroboration | sed -n '2p' | jq -r '.reason')"
assert_eq "fallback fires: work_order_json is the mechanical pick (TD1, id order)" "TD1" \
  "$(jq -r '.item' <<<"$work_order_json")"
# shellcheck disable=SC2154  # set by the eval'd coordinator_corroborate_retry_or_fallback
assert_eq "fallback fires: selected_by_fallback is armed" "1" "$selected_by_fallback"
# shellcheck disable=SC2154
assert_eq "fallback fires: candidates_json is a one-candidate array of the pick" "1" \
  "$(jq 'length' <<<"$candidates_json")"

# --- Fallback finds nothing: the one branch that still logs none-selected ---
# Contrived — `eligible_items_total > 0` with every band empty defies
# the guarantee fallback_select_candidate's own comment rests on — but the code
# fails closed rather than assuming it away, and this is the branch that does.
run_full_scenario "fallback finds nothing" "$attempt1" 0 "$attempt2_stillrejected" "$empty_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"

assert_eq "fallback finds nothing: function returns 1 (caller should exit)" "1" "$fn_rc"
assert_eq "fallback finds nothing: exactly one none-selected" "1" \
  "$(grep -cE '^event none-selected ' <<<"$calls")"
ns_evt="$(events_named "$calls" none-selected | head -n1)"
assert_eq "fallback finds nothing: …carrying retried:true" "true" "$(jq -r '.retried' <<<"$ns_evt")"
assert_eq "fallback finds nothing: …and td_verdict_rejected:true" "true" \
  "$(jq -r '.td_verdict_rejected' <<<"$ns_evt")"
assert_eq "fallback finds nothing: …and no fingerprint, so the next cycle asks again" "null" \
  "$(jq -r '.fingerprint // null' <<<"$ns_evt")"

# --- A retry launch failure does not reach fallback -------------------------
run_full_scenario "retry launch fails" "$attempt1" 1 "" "$repos_tech_debt_only" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"

assert_eq "retry launch fails: function returns 1" "1" "$fn_rc"
assert_contains "retry launch fails: handle_stage_failure was called for the retry" \
  "handle_stage_failure coordinator 1" "$calls"
assert_eq "retry launch fails: only one corroboration event (attempt 1's own)" "1" \
  "$(grep -cE '^event corroboration ' <<<"$calls")"
assert_eq "retry launch fails: fallback_select_candidate is never reached" "0" \
  "$(jq -r '.item' <<<"${work_order_json:-null}" 2>/dev/null | grep -c '^TD1$' || true)"

# --- The retry's recording is scoped to what it was asked about ------------
# attempt 1 accounts for TD1 only (via needs_refinement); the retry repeats
# that same entry (already accounted, must not be re-recorded) and adds a
# fresh voided entry for TD2 (the one item the addendum actually named
# unaccounted).
attempt2_repeat='{"selected":false,"reason":"retried","needs_refinement":[
  {"repo":"acme/widgets","item":"TD1","source":"tech-debt","reason":"r","missing":"m","evidence":"e"}],
  "voided":[{"repo":"acme/widgets","item":"TD2","reason":"already done","evidence":"the PR merged"}]}'
run_full_scenario "scoped recording" "$attempt1" 0 "$attempt2_repeat" "$repos_tech_debt_only" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"

# TD1 is accounted for by attempt 1's own needs_refinement report, so the
# retry addendum names only TD2 unaccounted; the retry's repeated TD1 entry
# must be filtered out of its own (second) pass rather than reaching
# record_needs_refinement_block a second time — asserted by total call count
# across both attempts, since attempt 1's own legitimate call is also in the log.
assert_eq "scoped recording: TD1's record call happened exactly once total (attempt 1 only, not doubled by the retry)" "1" \
  "$(grep -cE '^record_needs_refinement_block TD1$' <<<"$calls")"
assert_eq "scoped recording: TD2's void guard is called exactly once (the retry's new entry)" "1" \
  "$(grep -cE '^void_guard_reason TD2$' <<<"$calls")"
assert_eq "scoped recording: this fully accounts for the band — retry accepted" "1" \
  "$(events_named "$calls" corroboration | jq -s '[.[] | select(.attempt == 2 and .verdict == "accepted")] | length')"

# ============================================================================
# The gate is no longer tech-debt-only (requirement 3x, issue #322)
# ============================================================================
# The failure #322 was filed for: a `none-selected` over a non-empty `issues`
# array. Before this requirement `eligible_tech_debt_total` was 0 here — the
# tech-debt band really is empty — so the verdict was accepted un-corroborated
# and the fingerprint armed on it, exactly as #310's freeze did one band over.
issues_repos='[{"slug":"acme/widgets","default_branch":"main","sources":["issues:high","review-feedback"],
  "findings":[],
  "review_feedback":[{"source":"review-feedback","ref":"pr-57-review-1","pr_number":57,"pr_url":"https://x/pull/57","title":"fix x","branch":"agent/x","body":"review body"}],
  "merge_conflicts":[],"abandoned_drafts":[],"human_visibility":[],
  "issues":[{"source":"issues","ref":"11","number":11,"priority":"High","title":"an issue","body":"b","comments":[]}],
  "tech_debt":[],"register_hygiene":[]}]'
mixed_eligible='[{"repo":"acme/widgets","item":"11","source":"issues"},
                 {"repo":"acme/widgets","item":"pr-57-review-1","source":"review-feedback"}]'

# `eligible` is what run_full_scenario copies into the globals, so point it at
# the two-band set for these scenarios and restore nothing — this is the last
# section in the file.
eligible="$mixed_eligible"

silent_over_issues='{"selected":false,"reason":"no candidates in any source"}'
run_full_scenario "issues band confabulated away" "$silent_over_issues" 0 "$silent_over_issues" "$issues_repos" \
  > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"

c1="$(events_named "$calls" corroboration | sed -n '1p')"
assert_eq "a silent verdict over a non-empty issues band is rejected" "rejected" "$(jq -r '.verdict' <<<"$c1")"
assert_eq "…counting both bands in eligible_total" "2" "$(jq -r '.eligible_total' <<<"$c1")"
assert_eq "…and tagging the rejection with each band's own share" '{"issues":1,"review-feedback":1}' \
  "$(jq -c '.bands' <<<"$c1")"
assert_eq "…with every unaccounted ref carrying its band" '["issues","review-feedback"]' \
  "$(jq -c '[.unaccounted[].source] | sort' <<<"$c1")"
w1="$(events_named "$calls" warning | sed -n '1p')"
assert_eq "the sibling warning carries the same band tally" '{"issues":1,"review-feedback":1}' \
  "$(jq -c '.bands' <<<"$w1")"
assert_contains "…and its detail names the bands rather than just a count" \
  "issues 1, review-feedback 1" "$(jq -r '.detail' <<<"$w1")"
assert_eq "twice rejected, so the fallback picks the highest reachable band" "review-feedback" \
  "$(jq -r '.source' <<<"$work_order_json")"

# A report under the wrong `source` is not an account: the same ref, filed
# against the wrong band, leaves the band it was actually eligible in exactly
# as unaccounted as silence would.
wrong_band='{"selected":false,"reason":"reported","needs_refinement":[
  {"repo":"acme/widgets","item":"11","source":"tech-debt","reason":"r","missing":"m","evidence":"e"},
  {"repo":"acme/widgets","item":"pr-57-review-1","source":"review-feedback","reason":"r","missing":"m","evidence":"e"}]}'
run_full_scenario "wrong band" "$wrong_band" 0 "$silent_over_issues" "$issues_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
c1="$(events_named "$calls" corroboration | sed -n '1p')"
assert_eq "a report filed under the wrong source accounts for nothing" '{"issues":1}' \
  "$(jq -c '.bands' <<<"$c1")"

# Every band accounted for, across two different arrays and by two different
# routes — the clean stand-down, fingerprint armed.
accounted='{"selected":false,"reason":"all reported",
  "needs_refinement":[{"repo":"acme/widgets","item":"11","source":"issues","reason":"r","missing":"m","evidence":"e"}],
  "voided":[{"repo":"acme/widgets","item":"pr-57-review-1","reason":"already answered","evidence":"e"}]}'
run_full_scenario "every band accounted" "$accounted" 0 "" "$issues_repos" > "$tmp_dir/scenario.out"
calls="$(cat "$tmp_dir/scenario.out")"
assert_eq "a per-item verdict in each band is corroborated on the first attempt" "1" \
  "$(events_named "$calls" corroboration | jq -s '[.[] | select(.attempt == 1 and .verdict == "accepted")] | length')"
assert_eq "…so no retry is bought" "1" "$(grep -cE '^run_claude_stage call=' <<<"$calls")"
assert_eq "…and the none-selected carries the fingerprint" "fp-abc123" \
  "$(events_named "$calls" none-selected | head -n1 | jq -r '.fingerprint')"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
