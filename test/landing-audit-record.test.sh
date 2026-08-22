#!/usr/bin/env bash
#
# test/landing-audit-record.test.sh — the D18 landing audit record
# (requirement 8x, agent-ops#578): one durable `landing-audit-record` event,
# written by `_landing_stage_attempt` (agent-cycle.sh) at the exact moment it
# arms a pull request, and the WI-8 dashboard digest's own consumption of it.
#
# test/landing-wiring.test.sh already proves the *wiring* — that a successful
# arm logs this event alongside `landing-armed`, from the same in-hand facts.
# This file is the deep half issue #578's own acceptance text asks for
# directly: "verifies the record structure and that digest consumption
# works." Two parts:
#
#   Part A  pins every field of the record itself, against `_landing_stage_
#           attempt` lifted verbatim out of agent-cycle.sh (the same
#           extraction technique test/landing-wiring.test.sh already uses) —
#           the pull request's own number and head SHA, the autonomy level
#           and its resolution source, a protected-path hit (paths named,
#           not just a verdict word), and a non-empty adjudication history
#           across a refuse streak.
#   Part B  proves `scripts/publish-dashboard.sh` actually reads the record
#           back: run for real (as test/publish-dashboard.test.sh already
#           does, `--no-github` against a throwaway state dir) over a
#           synthetic `log.jsonl`, one pull request whose `landing-armed`
#           has a matching audit record and one whose does not — the tier
#           and verdict the digest renders come from the record, and the
#           unmatched landing is `anomaly: true`, never a silent null.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/landing-audit-record.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc and `printf` lines
# below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"
PUBLISH="$SCRIPT_DIR/scripts/publish-dashboard.sh"

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

# =============================================================================
# Part A — the record's own shape
# =============================================================================

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$CYCLE"
}

refuse_block="$(extract _landing_refuse)"
stage_block="$(extract _landing_stage_attempt)"
if [[ -z "$stage_block" || "$stage_block" != *"landing-audit-record"* ]]; then
  echo "FAIL - could not extract _landing_stage_attempt from agent-cycle.sh — has it moved, or lost its audit-record write?" >&2
  exit 1
fi

cat >"$tmp_dir/harness.sh" <<'HARNESS'
set -euo pipefail

# shellcheck source=lib/landing.sh
source "$SCRIPT_DIR/lib/landing.sh"
# shellcheck source=lib/merge-queue.sh
source "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/merge-autonomy.sh
source "$SCRIPT_DIR/lib/merge-autonomy.sh"

selected_repo="Poetic-Poems/agent-ops"
selected_source="tech-debt"
state_repo="Poetic-Poems/agent-ops"
state_dir="$T/state"
# Real merge_autonomy_effective_level/merge_autonomy_resolution_source run
# unstubbed here (only merge_autonomy_kill_state, above, is faked) — unlike
# test/landing-wiring.test.sh's own harness, which stubs the level directly
# and so needs no real config at all. Defaults to the top-level key alone,
# so the resolution-source assertions below have a real, unambiguous answer.
DEFAULTED_CONFIG="${CONFIG_JSON:-}"
[[ -n "$DEFAULTED_CONFIG" ]] || DEFAULTED_CONFIG='{"merge_autonomy":"agent-merges-routine"}'
gate_default_branch="main"
pr_label="autonomous-agent"
enabler_escalation_label="agent-escalation"
enabler_assignee="warwickallen"
union_log="$T/union.jsonl"
log_file="$T/state/log.jsonl"
mkdir -p "$state_dir"
: > "$union_log"
: > "$log_file"
# A test that wants prior approver-verdict history writes it here before
# calling run_case/run_case_retry — the same file _landing_stage_attempt
# itself reads (non-retry) or $union_log (retry).
[[ -z "${LOG_SEED_FILE:-}" ]] || cat "$LOG_SEED_FILE" >> "$log_file"
[[ -z "${UNION_SEED_FILE:-}" ]] || cat "$UNION_SEED_FILE" >> "$union_log"

declare -A landing_armed_by_repo=()

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }
merge_autonomy_kill_state() { printf '{"state":"enabled"}'; }
# lib/merge-budget.sh's own freeze read — lib/merge-autonomy.sh calls this
# whenever the configured level ranks above agent-approves (every case here),
# so it needs a real definition; not frozen, matching merge_autonomy_kill_
# state's own "enabled" vocabulary for "clear".
merge_budget_freeze_state() { printf '{"state":"enabled"}'; }
landing_eligible() { printf '%s' "${ELIGIBLE:-eligible}"; }
review_gate_verdict() { printf '%s' "${GATE_WORD:-clean}"; return "${GATE_RC:-0}"; }
approver_token_identity_login() { printf 'pullwright-approver[bot]'; }
landing_approver_standing_review_at() {
  printf '%s\t%s\t%s' "${STANDING:-APPROVED}" "${SUBMITTED_AT:-2026-08-17T10:00:00Z}" \
    "${REVIEW_COMMIT:-sha-approved-head}"
}
_handoff_blocking_reviewers() { return 0; }
landing_protected_path_controls_ok() { printf '%s' "${PP_CTL:-ok}"; }
landing_retry_tier() { printf '%s' "${RETRY_TIER:-critical}"; }
merge_budget_decide() {
  printf '{"decision":"%s","cap":%s,"count":%s,"anomaly":%s,"waiting_backlog":%s}' \
    "${BUDGET:-arm}" "${BUDGET_CAP:-8}" "${BUDGET_COUNT:-3}" "${BUDGET_ANOMALY:-false}" \
    "${BUDGET_BACKLOG:-null}"
}
merge_budget_apply_decision() { :; }
merge_queue_probe() { printf '{"queued":false}'; }
approver_token_get() { printf 'a-minted-token'; }
landing_arm() { printf '%s' "${ARM_METHOD:-enqueued}"; }
landing_protected_paths_hit() {
  [[ "${PP_HIT_RC:-1}" == "0" ]] || return "${PP_HIT_RC:-1}"
  printf '%s' "${PP_HIT_PATHS:-}"
}

HARNESS

{
  printf '%s\n' "$refuse_block"
  printf '%s\n' "$stage_block"
  printf '%s\n' '_landing_stage_attempt "$selected_repo" "$PR_URL" "$COMPLEXITY" "$selected_source" "$gate_default_branch" "${RETRY:-}" "${ALREADY_ARMED:-0}"'
} >>"$tmp_dir/harness.sh"

URL="https://github.com/Poetic-Poems/agent-ops/pull/900"

run_case() {
  : >"$tmp_dir/events"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" PR_URL="$URL" COMPLEXITY="medium" \
    "$@" \
    bash "$tmp_dir/harness.sh" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
  printf '%s' "$?"
}

event_of() { grep -m1 "^$1"$'\t' "$tmp_dir/events" | cut -f2- || true; }

# --- The full record, on an ordinary eligible arm ---------------------------

rc="$(run_case)"
assert_eq "an eligible, fully-cleared PR arms and returns 0" "0" "$rc"
audit="$(event_of landing-audit-record)"
assert_eq "the record names the pull request's own url" \
  "\"$URL\"" "$(jq -c '.pr_url' <<<"$audit")"
assert_eq "  ... and repo" '"Poetic-Poems/agent-ops"' "$(jq -c '.repo' <<<"$audit")"
assert_eq "  ... and number, parsed from the url" "900" "$(jq -c '.number' <<<"$audit")"
assert_eq "  ... and head SHA, the Approver's own standing-review commit_id" \
  '"sha-approved-head"' "$(jq -c '.head_sha' <<<"$audit")"
assert_eq "  ... source and complexity, carried forward unchanged" \
  '"tech-debt"' "$(jq -c '.source' <<<"$audit")"
assert_eq "  ... complexity" '"medium"' "$(jq -c '.complexity' <<<"$audit")"
assert_eq "  ... the effective autonomy level" \
  '"agent-merges-routine"' "$(jq -c '.autonomy.level' <<<"$audit")"
assert_eq "  ... resolved from the top-level key (DEFAULTED_CONFIG names no repo override)" \
  '"top-level-default"' "$(jq -c '.autonomy.source' <<<"$audit")"
assert_eq "  ... a clear protected-path verdict, with no paths named" \
  '"clear"' "$(jq -c '.protected_path.verdict' <<<"$audit")"
assert_eq "  ... and an empty paths array to match" "[]" "$(jq -c '.protected_path.paths' <<<"$audit")"
assert_eq "  ... an empty adjudication history (nothing seeded in log_file)" \
  "[]" "$(jq -c '.approver.history' <<<"$audit")"
assert_eq "  ... and a null approver tier/model/verdict to match" \
  "null" "$(jq -c '.approver.tier' <<<"$audit")"
assert_eq "  ... every gate this attempt cleared, named with its own evidence" \
  '"agent-merges-routine"' "$(jq -c '.gates[] | select(.gate == "autonomy-level") | .verdict' <<<"$audit")"
assert_eq "  ... the eligibility gate" \
  '"eligible"' "$(jq -c '.gates[] | select(.gate == "eligibility") | .verdict' <<<"$audit")"
assert_eq "  ... the review gate" \
  '"clean"' "$(jq -c '.gates[] | select(.gate == "review-gate") | .verdict' <<<"$audit")"
assert_eq "  ... the Approver's own standing review" \
  '"APPROVED"' "$(jq -c '.gates[] | select(.gate == "approver-standing-review") | .verdict' <<<"$audit")"
assert_eq "  ... and the merge-queue probe" \
  '"clear"' "$(jq -c '.gates[] | select(.gate == "merge-queue") | .verdict' <<<"$audit")"
assert_eq "  ... the budget object gate 5 already computed, not discarded" \
  '"arm"' "$(jq -c '.budget.decision' <<<"$audit")"
assert_eq "  ... including its own cap" "8" "$(jq -c '.budget.cap' <<<"$audit")"
assert_eq "  ... and the same mechanism landing-armed itself names" \
  '"enqueued"' "$(jq -c '.mechanism' <<<"$audit")"
assert_eq "  ... carrying no retry field on an ordinary (non-retry) arm" \
  "null" "$(jq -c '.retry // null' <<<"$audit")"

# --- A protected-path hit: the verdict and the paths, not just the word -----

rc="$(run_case PP_HIT_RC="0" PP_HIT_PATHS=$'lib/landing.sh\nprompts/approver.md')"
assert_eq "a protected-path hit still arms (below agent-merges-all it would not, but the eligibility gate is stubbed \"eligible\" here — this case is about the audit record's own re-read, not gate 2)" \
  "0" "$rc"
audit="$(event_of landing-audit-record)"
assert_eq "the protected-path verdict is hit" '"hit"' "$(jq -c '.protected_path.verdict' <<<"$audit")"
assert_eq "  ... naming every protected path it hit, not merely that one was hit" \
  '["lib/landing.sh","prompts/approver.md"]' "$(jq -c '.protected_path.paths' <<<"$audit")"

# --- An unreadable protected-path re-read is "unknown", never a silent clear ---

rc="$(run_case PP_HIT_RC="2")"
assert_eq "an unreadable changed-file list still arms (the arm itself already cleared gate 2)" "0" "$rc"
audit="$(event_of landing-audit-record)"
assert_eq "the protected-path verdict is unknown, never read as clear" \
  '"unknown"' "$(jq -c '.protected_path.verdict' <<<"$audit")"

# --- Adjudication history: every approver-verdict for this pull request, ---
# --- not only the one that authorised this landing -------------------------

cat >"$tmp_dir/log-seed.jsonl" <<EOF
{"ts":"2026-08-20T09:00:00Z","event":"approver-verdict","pr_url":"$URL","repo":"Poetic-Poems/agent-ops","tier":"complex","model":"claude-sonnet-5","verdict":"refuse","refuse_streak":1,"adjudication":false,"posted":true}
{"ts":"2026-08-21T09:00:00Z","event":"approver-verdict","pr_url":"$URL","repo":"Poetic-Poems/agent-ops","tier":"critical","model":"claude-opus-5","verdict":"land","refuse_streak":2,"adjudication":true,"posted":true}
EOF
rc="$(run_case LOG_SEED_FILE="$tmp_dir/log-seed.jsonl")"
assert_eq "a pull request with prior refusals still arms and returns 0" "0" "$rc"
audit="$(event_of landing-audit-record)"
assert_eq "the adjudication history carries every prior approver-verdict for this pull request" \
  "2" "$(jq -c '.approver.history | length' <<<"$audit")"
assert_eq "  ... oldest first" '"refuse"' "$(jq -c '.approver.history[0].verdict' <<<"$audit")"
assert_eq "  ... then the round that finally approved it" \
  '"land"' "$(jq -c '.approver.history[1].verdict' <<<"$audit")"
assert_eq "  ... and the record's own approver object is the newest entry, not the oldest" \
  '"critical"' "$(jq -c '.approver.tier' <<<"$audit")"
assert_eq "  ... its own model too" '"claude-opus-5"' "$(jq -c '.approver.model' <<<"$audit")"
assert_eq "  ... and its adjudication flag" "true" "$(jq -c '.approver.adjudication' <<<"$audit")"

# --- A retry arm reads history from $union_log, not $log_file --------------

cat >"$tmp_dir/union-seed.jsonl" <<EOF
{"ts":"2026-08-18T09:00:00Z","event":"approver-verdict","pr_url":"$URL","repo":"Poetic-Poems/agent-ops","tier":"critical","model":"claude-sonnet-5","verdict":"approve","refuse_streak":0,"adjudication":false,"posted":true}
EOF
rc="$(run_case RETRY="retry" UNION_SEED_FILE="$tmp_dir/union-seed.jsonl")"
assert_eq "a retry attempt still arms and returns 0" "0" "$rc"
audit="$(event_of landing-audit-record)"
assert_eq "the retry's own audit record carries retry:true" "true" "$(jq -c '.retry' <<<"$audit")"
assert_eq "  ... and reads adjudication history from union_log, the retry's own fleet-log source" \
  "1" "$(jq -c '.approver.history | length' <<<"$audit")"
assert_eq "  ... naming the approving round's own model" \
  '"claude-sonnet-5"' "$(jq -c '.approver.model' <<<"$audit")"

# =============================================================================
# Part B — the WI-8 digest actually consumes the record
# =============================================================================
# Runs scripts/publish-dashboard.sh for real, `--no-github`, over a synthetic
# log.jsonl — the same harness style test/publish-dashboard.test.sh already
# uses — so this is a genuine round-trip through the shipped digest-assembly
# jq, not a copy of its logic.

home_dir="$tmp_dir/home"
mkdir -p "$home_dir/.local/state/poetic-agents/cycles"

pr1="https://github.com/Poetic-Poems/agent-ops/pull/901"
pr2="https://github.com/Poetic-Poems/agent-ops/pull/902"
{
  printf '{"ts":"2026-08-22T01:00:00Z","cycle":"c1","node":"node-1","event":"landing-audit-record","pr_url":"%s","repo":"Poetic-Poems/agent-ops","number":901,"head_sha":"sha1","source":"tech-debt","complexity":"medium","autonomy":{"level":"agent-merges-routine","source":"top-level-default"},"protected_path":{"verdict":"clear","paths":[]},"approver":{"tier":"complex","model":"claude-sonnet-5","verdict":"approve","adjudication":false,"history":[]},"gates":[],"budget":{"decision":"arm","cap":8,"count":1,"anomaly":false,"waiting_backlog":null},"mechanism":"enqueued"}\n' "$pr1"
  printf '{"ts":"2026-08-22T01:00:01Z","cycle":"c1","node":"node-1","event":"landing-armed","pr_url":"%s","repo":"Poetic-Poems/agent-ops","source":"tech-debt","complexity":"medium","method":"enqueued"}\n' "$pr1"
  printf '{"ts":"2026-08-22T02:00:00Z","cycle":"c2","node":"node-1","event":"landing-armed","pr_url":"%s","repo":"Poetic-Poems/agent-ops","source":"register-hygiene","complexity":"low","method":"auto-merge"}\n' "$pr2"
} > "$home_dir/.local/state/poetic-agents/log.jsonl"

env HOME="$home_dir" "$PUBLISH" --no-github >/dev/null 2>&1
rc=$?
assert_eq "a publish over a mixed matched/unmatched landing pair exits 0" "0" "$rc"

data="$(tail -n +2 "$home_dir/.local/state/poetic-agents/dashboard/data.js" \
  | sed -e '1s/^window\.DASHBOARD_DATA = //' -e '$ s/;$//')"
jq -e . <<<"$data" >/dev/null 2>&1
assert_eq "data.js payload is valid JSON" "0" "$?"

landings="$(jq -c '.landings' <<<"$data")"
row1="$(jq -c --arg u "$pr1" '.armed[] | select(.pr_url == $u)' <<<"$landings")"
row2="$(jq -c --arg u "$pr2" '.armed[] | select(.pr_url == $u)' <<<"$landings")"

assert_eq "the landing with a matching audit record renders its own tier" \
  '"complex"' "$(jq -c '.tier' <<<"$row1")"
assert_eq "  ... and verdict" '"approve"' "$(jq -c '.verdict' <<<"$row1")"
assert_eq "  ... and is not an anomaly" "false" "$(jq -c '.anomaly' <<<"$row1")"

assert_eq "the landing with no matching audit record carries a null tier" \
  "null" "$(jq -c '.tier' <<<"$row2")"
assert_eq "  ... a null verdict" "null" "$(jq -c '.verdict' <<<"$row2")"
assert_eq "  ... and is reported as an anomaly, never a silent null" \
  "true" "$(jq -c '.anomaly' <<<"$row2")"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "All assertions passed"
