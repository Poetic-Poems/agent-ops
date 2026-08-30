#!/usr/bin/env bash
#
# test/approver-tech-debt-file-wiring.test.sh — regression test for the
# file_debt/file_issue handling `run_approver_stage` adds in agent-cycle.sh
# (agent-ops#631): the Approver's final JSON may carry either field, asking
# the Script to file a tech-debt record (its own small pull request) or a
# plain GitHub issue on its behalf — the Approver itself must never write to
# GitHub or a branch (prompts/approver.md, "What you must never do").
#
# This file complements test/approver-wiring.test.sh (the tier/streak/verdict
# wiring itself, untouched by this feature) and test/tech-debt-file.test.sh
# (lib/tech-debt-file.sh's own filing logic). What this file proves is
# narrower: that `run_approver_stage` calls `techdebt_file_debt`/
# `techdebt_file_issue` with the Approver's own App token and its still-alive
# `clone_dir`, logs the right event on success, and warns instead of silently
# dropping a malformed or failed request — same lift-and-assemble technique
# test/approver-wiring.test.sh uses, with `techdebt_file_debt`/
# `techdebt_file_issue` stubbed as simple recorders rather than wired for
# real.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/approver-tech-debt-file-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc below is deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/lib/approver.sh"

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

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$CYCLE"
}

block="$(extract run_approver_stage)"
post_block="$(extract approver_post_or_warn)"
complexity_block="$(extract approver_stage_complexity)"
if [[ -z "$block" || "$block" != *"file_debt"* || "$block" != *"file_issue"* ]]; then
  echo "FAIL - run_approver_stage no longer mentions file_debt/file_issue (agent-ops#631 wiring removed, or extraction failed)?" >&2
  exit 1
fi
if [[ -z "$post_block" || "$post_block" != *"approver_post_review"* ]]; then
  echo "FAIL - could not extract approver_post_or_warn from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ -z "$complexity_block" || "$complexity_block" != *"reviewer_complexity"* ]]; then
  echo "FAIL - could not extract approver_stage_complexity from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

cat >"$tmp_dir/harness.sh" <<'HARNESS'
set -euo pipefail

. "$SCRIPT_DIR/lib/approver.sh"
. "$SCRIPT_DIR/lib/cycle-state.sh"
# docs/FLOW-SCHEMA.md, requirement 47, issue #596: run_approver_stage's own
# stage-end site calls lib/rework.sh's rework_stage_rerun_maybe. Sourced for
# real (it is pure and cheap) rather than stubbed, so this file keeps
# verifying the shipped wiring rather than a stand-in for it.
. "$SCRIPT_DIR/lib/rework.sh"

selected_repo="Poetic-Poems/agent-ops"
selected_item="631"
state_repo="Poetic-Poems/agent-ops"
state_dir="$T/state"
DEFAULTED_CONFIG='{"pr_label":"custom-agent-label"}'
PROMPTS_DIR="$SCRIPT_DIR/prompts"
prompt_overrides_json='{}'
cycle_dir="$T/cycle"
clone_dir="$T/clone"
cycle_id="20260822T000000Z-test-1"
node_name="test-node"
work_order_json='{"item":"631"}'
impl_status_json='{"status":"complete"}'
rev_status_json='{"status":"ready"}'
stage_backstop_min=30
stage_inactivity_min=10
stage_kill_reason=""
stage_gaps_json='[]'
ONCE=0
approver_model_default="model-default"
approver_model_complex="model-complex"
approver_model_critical="model-critical"
mkdir -p "$cycle_dir" "$clone_dir" "$state_dir"

# agent-ops#1081: run_approver_stage now asks merge_autonomy_kill_state
# directly, ahead of merge_autonomy_effective_level, to distinguish a
# fail-closed `human` from a genuinely configured one — see lib/approver.sh's
# own comment at that call site. Stubbed enabled, the same "nothing killed"
# baseline every case in this file already assumes.
merge_autonomy_kill_state() { printf '{"state":"enabled"}'; }
merge_autonomy_effective_level() { printf '%s' "agent-approves"; }
approver_token_credential_present() { return 0; }
approver_token_identity_login() { printf 'pullwright-approver[bot]'; }
approver_refuse_streak() { printf '0'; }
# agent-ops#945: the first call is the pre-engagement gate, the second the
# fresh mint spent on the writes below (both filings and the review post) —
# see test/approver-wiring.test.sh's own copy of this stub for why the count
# lives in a file rather than a shell variable. GATE_TOKEN/WRITE_TOKEN both
# default to "a-minted-token", the constant every assertion in this file
# before agent-ops#945 already relied on.
approver_token_get() {
  local calls
  calls=$(( $(cat "$T/token_calls_count" 2>/dev/null || printf '0') + 1 ))
  printf '%s' "$calls" >"$T/token_calls_count"
  if (( calls == 1 )); then
    printf '%s' "${GATE_TOKEN:-a-minted-token}"
  else
    printf '%s' "${WRITE_TOKEN:-a-minted-token}"
  fi
}
landing_protected_paths_hit() { return 1; }
stage_prompt_text() { printf 'THE APPROVER PROMPT'; }
stage_budget_apply() { :; }
stage_watchdog_warning() { printf ''; }
metering_fields() { printf '{}'; }
dump_stage_output() { :; }
stage_salvage_result() { return 1; }
extract_json_result() { [[ -n "${1// /}" ]] || return 1; jq -c . <<<"$1"; }
gh() { return 0; }
log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }
approver_post_review() {
  printf 'url=%s\tevent=%s\ttoken=%s\n' "$1" "$2" "$4" >>"$T/posts"
  return 0
}
approver_escalate() { printf 'url=%s\n' "$1" >>"$T/escalations"; }
run_claude_stage() {
  jq -nc --arg r "$VERDICT" '{result: $r}' >"$5"
  return 0
}

# techdebt_file_debt/techdebt_file_issue: recorders, following exactly the
# same role test/enabler-tech-debt-file-wiring.test.sh's own stubs play.
techdebt_file_debt() {
  printf 'techdebt_file_debt %s\n' "$*" >>"$T/fd_calls"
  [[ "${FD_RC:-0}" -eq 0 ]] || return 1
  printf 'TD-PPtest-99999902\thttps://github.com/Poetic-Poems/agent-ops/pull/701'
}
techdebt_file_issue() {
  printf 'techdebt_file_issue %s\n' "$*" >>"$T/fi_calls"
  [[ "${FI_RC:-0}" -eq 0 ]] || return 1
  printf '88\thttps://github.com/Poetic-Poems/agent-ops/issues/88'
}
HARNESS

{
  printf '%s\n' "$post_block"
  printf '%s\n' "$complexity_block"
  printf '%s\n' "$block"
  printf 'resolved="$(approver_stage_complexity "$PR_URL" "$COMPLEXITY" 0)"\n'
  printf 'run_approver_stage "$PR_URL" "$resolved"\n'
} >>"$tmp_dir/harness.sh"

URL="https://github.com/Poetic-Poems/agent-ops/pull/463"

# run_case VERDICT_JSON [FD_RC] [FI_RC] [KEY=VALUE ...]
run_case() {
  local verdict="$1" fd_rc="${2:-0}" fi_rc="${3:-0}"
  local extra=()
  (( $# > 3 )) && extra=("${@:4}")
  : >"$tmp_dir/events"; : >"$tmp_dir/posts"; : >"$tmp_dir/escalations"
  : >"$tmp_dir/fd_calls"; : >"$tmp_dir/fi_calls"
  rm -f "$tmp_dir/token_calls_count"
  rm -rf "${tmp_dir:?}/cycle" "${tmp_dir:?}/clone" "${tmp_dir:?}/state"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" PR_URL="$URL" COMPLEXITY="medium" \
    VERDICT="$verdict" FD_RC="$fd_rc" FI_RC="$fi_rc" \
    "${extra[@]}" \
    bash "$tmp_dir/harness.sh" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
  printf '%s' "$?"
}

fd_calls() { cat "$tmp_dir/fd_calls" 2>/dev/null || true; }
fi_calls() { cat "$tmp_dir/fi_calls" 2>/dev/null || true; }
count() { local f="$tmp_dir/$1"; [[ -s "$f" ]] && wc -l <"$f" | tr -d ' ' || printf '0'; }
warnings() { grep $'^warning\t' "$tmp_dir/events" 2>/dev/null | cut -f2- || true; }

# --- file_debt: success (carries default_fix) ------------------------------
verdict='{"verdict":"approve","reasons":["fine"],"file_debt":{"title":"A gap the Approver noticed","body":"The body.","default_fix":"Do the smaller fix"}}'
rc="$(run_case "$verdict")"
assert_eq "file_debt success: stage still returns 0" "0" "$rc"
assert_eq "  ... techdebt_file_debt called once" "1" "$(count fd_calls)"
assert_contains "  ... with the repo" "Poetic-Poems/agent-ops" "$(fd_calls)"
assert_contains "  ... the title and body" "A gap the Approver noticed The body." "$(fd_calls)"
assert_contains "  ... and the Approver's own App token, not the ordinary login" \
  "a-minted-token" "$(fd_calls)"
# TD-PPagop-26082426: this stage never otherwise resolves config, so the
# fleet's `pr_label` must be read from DEFAULTED_CONFIG and threaded through
# rather than left for techdebt_file_debt's own fallback -- proven by using a
# label here that does not match that fallback.
assert_contains "  ... and the configured pr_label, not the bare fallback" \
  "custom-agent-label" "$(fd_calls)"
# agent-ops#938: default_fix/owner_decision reach the call, in that order,
# past pr_label.
assert_contains "  ... and default_fix/owner_decision past pr_label" \
  "custom-agent-label Do the smaller fix false" "$(fd_calls)"
assert_contains "  ... a tech-debt-filed event, crediting the approver" \
  '"by":"approver"' "$(grep '^tech-debt-filed' "$tmp_dir/events" || true)"
assert_eq "  ... no warning" "0" "$(warnings | grep -c .)"

# --- file_debt: owner_decision true, no default_fix -> no "malformed" -----
#     warning (owner_decision alone is enough)
verdict='{"verdict":"approve","reasons":["fine"],"file_debt":{"title":"An owner call","body":"The body.","owner_decision":true}}'
run_case "$verdict" >/dev/null
assert_contains "file_debt owner_decision: passed through as \"true\"" \
  "custom-agent-label  true" "$(fd_calls)"
assert_eq "  ... no warning" "0" "$(warnings | grep -c .)"

# --- file_debt: neither default_fix nor owner_decision -> malformed, filed -
#     anyway, and the refusal is counted as a warning (agent-ops#938)
verdict='{"verdict":"approve","reasons":["fine"],"file_debt":{"title":"No stated default","body":"B."}}'
run_case "$verdict" >/dev/null
assert_eq "file_debt malformed default: still files" "1" "$(count fd_calls)"
assert_contains "  ... still logs tech-debt-filed" '"by":"approver"' \
  "$(grep '^tech-debt-filed' "$tmp_dir/events" || true)"
assert_contains "  ... AND a warning naming the missing default" \
  "no default_fix and no owner_decision" "$(warnings)"

# --- file_debt: missing title/body -> warning, no call --------------------
verdict='{"verdict":"approve","reasons":["fine"],"file_debt":{"title":"","body":""}}'
run_case "$verdict" >/dev/null
assert_eq "file_debt missing fields: no call made" "0" "$(count fd_calls)"
assert_eq "  ... a warning was logged" "1" "$(warnings | grep -c .)"

# --- file_debt: the call itself fails -> warning ---------------------------
verdict='{"verdict":"approve","reasons":["fine"],"file_debt":{"title":"T","body":"B","default_fix":"D"}}'
run_case "$verdict" 1 >/dev/null
assert_eq "file_debt call fails: still attempted" "1" "$(count fd_calls)"
assert_eq "  ... no tech-debt-filed event" "0" "$(grep -c '^tech-debt-filed' "$tmp_dir/events" || true)"
assert_eq "  ... a warning was logged instead" "1" "$(warnings | grep -c .)"

# --- file_issue: success (carries default_fix) ------------------------------
verdict='{"verdict":"refuse","reasons":["needs a fix"],"file_issue":{"title":"A question","body":"Body of it.","default_fix":"Answer it this way"}}'
run_case "$verdict" >/dev/null
assert_eq "file_issue success: techdebt_file_issue called once" "1" "$(count fi_calls)"
assert_contains "  ... with the pull request's own URL as the item ref" "$URL" "$(fi_calls)"
assert_contains "  ... and the Approver's own App token" "a-minted-token" "$(fi_calls)"
assert_contains "  ... and default_fix/owner_decision past the token" \
  "a-minted-token Answer it this way false" "$(fi_calls)"
assert_contains "  ... an issue-filed event, crediting the approver" \
  '"by":"approver"' "$(grep '^issue-filed' "$tmp_dir/events" || true)"
assert_eq "  ... no warning" "0" "$(warnings | grep -c .)"

# --- file_issue: neither field -> malformed, filed anyway, warning ---------
verdict='{"verdict":"refuse","reasons":["needs a fix"],"file_issue":{"title":"No stated default","body":"Body."}}'
run_case "$verdict" >/dev/null
assert_eq "file_issue malformed default: still files" "1" "$(count fi_calls)"
assert_contains "  ... still logs issue-filed" '"by":"approver"' \
  "$(grep '^issue-filed' "$tmp_dir/events" || true)"
assert_contains "  ... AND a warning naming the missing default" \
  "no default_fix and no owner_decision" "$(warnings)"

# --- file_issue: missing body -> warning, no call --------------------------
verdict='{"verdict":"approve","reasons":["fine"],"file_issue":{"title":"Q","body":""}}'
run_case "$verdict" >/dev/null
assert_eq "file_issue missing body: no call made" "0" "$(count fi_calls)"
assert_eq "  ... a warning was logged" "1" "$(warnings | grep -c .)"

# --- Neither field set -> no filing calls, no extra warnings ---------------
verdict='{"verdict":"approve","reasons":["fine"]}'
run_case "$verdict" >/dev/null
assert_eq "neither field: no techdebt_file_debt call" "0" "$(count fd_calls)"
assert_eq "  ... no techdebt_file_issue call" "0" "$(count fi_calls)"
assert_eq "  ... no warning" "0" "$(warnings | grep -c .)"

# --- Orthogonal to verdict: a `refuse` verdict still files -----------------
verdict='{"verdict":"refuse","reasons":["a real defect"],"file_debt":{"title":"T2","body":"B2","default_fix":"D2"}}'
run_case "$verdict" >/dev/null
assert_contains "refuse verdict still posts REQUEST_CHANGES" "event=REQUEST_CHANGES" "$(cat "$tmp_dir/posts")"
assert_eq "  ... and file_debt still files, independent of the verdict" "1" "$(count fd_calls)"

# --- Both filings, and the review post, spend the post-engagement mint, ----
# --- never the pre-engagement gate token (agent-ops#945) --------------------
verdict='{"verdict":"approve","reasons":["fine"],"file_debt":{"title":"T3","body":"B3"},"file_issue":{"title":"Q3","body":"B3"}}'
run_case "$verdict" 0 0 GATE_TOKEN=stage-entry-token WRITE_TOKEN=fresh-write-token >/dev/null
assert_contains "techdebt_file_debt spends the fresh, post-engagement token" \
  "fresh-write-token" "$(fd_calls)"
assert_eq "  ... never the pre-engagement gate token" "0" \
  "$(grep -c 'stage-entry-token' "$tmp_dir/fd_calls")"
assert_contains "techdebt_file_issue spends the same fresh token" \
  "fresh-write-token" "$(fi_calls)"
assert_eq "  ... never the pre-engagement gate token" "0" \
  "$(grep -c 'stage-entry-token' "$tmp_dir/fi_calls")"
assert_contains "the review post itself spends the same fresh token too" \
  "token=fresh-write-token" "$(cat "$tmp_dir/posts")"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
