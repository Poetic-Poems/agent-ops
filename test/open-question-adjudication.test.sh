#!/usr/bin/env bash
#
# test/open-question-adjudication.test.sh — regression test for the
# escalation/adjudication ladder behind requirement 8f's own landing gate
# (D18, agent-ops#668): `_landing_open_question_resolve`,
# `open_question_pass_available`, `open_question_adjudicated_before`,
# `open_question_escalate` and `run_open_question_adjudication`, all in
# lib/landing.sh.
#
# `test/landing-wiring.test.sh` covers the gate itself (`_landing_stage_
# attempt`'s own dispatch on a hit/clear/unknown label read), with `_landing_
# open_question_resolve` stubbed as a black box — the same relationship that
# file already has with `landing_eligible`. This file is the other half: what
# `_landing_open_question_resolve` itself actually does once called, with
# `run_open_question_adjudication` stubbed as its own black box, mirroring
# exactly how test/enabler-verdicts.test.sh treats `run_enabler_adjudication`
# (a live nested Claude launch has no place in a wiring test) — and, in its
# own section below, `run_open_question_adjudication`'s own internals tested
# directly, with `run_claude_stage` stubbed instead.
#
# Every function here is lifted verbatim out of lib/landing.sh, so the
# assertions are about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/open-question-adjudication.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc and `printf` lines
# below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/lib/landing.sh"
ESCALATION_AUTONOMY="$SCRIPT_DIR/lib/escalation-autonomy.sh"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

extract() {  # <function name> [source file, default $CYCLE]
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "${2:-$CYCLE}"
}

resolve_block="$(extract _landing_open_question_resolve)"
refuse_block="$(extract _landing_refuse)"
pass_available_block="$(extract open_question_pass_available)"
adjudicated_before_block="$(extract open_question_adjudicated_before)"
escalate_block="$(extract open_question_escalate)"
adjudicate_block="$(extract run_open_question_adjudication)"
# The requirement 8f re-filing guard (agent-ops#779) reuses these two pure
# comparators verbatim from lib/escalation-autonomy.sh (they are `approver_
# escalate`'s own guard too — see test/approver.test.sh) rather than
# reimplementing the window/owed logic here.
refile_suppressed_block="$(extract escalation_refile_suppressed "$ESCALATION_AUTONOMY")"
event_logged_since_block="$(extract escalation_event_logged_since "$ESCALATION_AUTONOMY")"

for pair in "resolve_block:_landing_open_question_resolve" "refuse_block:_landing_refuse" \
            "pass_available_block:open_question_pass_available" \
            "adjudicated_before_block:open_question_adjudicated_before" \
            "escalate_block:open_question_escalate" \
            "adjudicate_block:run_open_question_adjudication"; do
  var="${pair%%:*}" name="${pair#*:}"
  if [[ -z "${!var}" ]]; then
    echo "FAIL - could not extract $name from lib/landing.sh — has it moved?" >&2
    exit 1
  fi
done
for pair in "refile_suppressed_block:escalation_refile_suppressed" \
            "event_logged_since_block:escalation_event_logged_since"; do
  var="${pair%%:*}" name="${pair#*:}"
  if [[ -z "${!var}" ]]; then
    echo "FAIL - could not extract $name from lib/escalation-autonomy.sh — has it moved?" >&2
    exit 1
  fi
done

# ============================================================================
# Part A: `_landing_open_question_resolve`, `open_question_pass_available`,
# `open_question_adjudicated_before` and `open_question_escalate` — the
# ladder, with `run_open_question_adjudication` stubbed as a black box.
# ============================================================================

cat >"$tmp_dir/harness_a.sh" <<'HARNESS'
set -euo pipefail

selected_repo="Poetic-Poems/agent-ops"
enabler_escalation_label="agent-escalation"
enabler_assignee="warwickallen"
node_name="test-node"
cycle_id="20260825T000000Z-test-1"
cycle_dir="$T/cycle"
union_log="$T/union.jsonl"
log_file="$T/log.jsonl"
LANDING_OPEN_QUESTION_LABEL="open-question"
DEFAULTED_CONFIG="{\"escalation_autonomy\":\"$LEVEL\"}"
mkdir -p "$cycle_dir"
: >"$union_log"
: >"$log_file"

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

escalation_autonomy_configured_level() { printf '%s\n' "$*" >>"$T/level_args"; printf '%s' "$LEVEL"; }

open_question_pass_available() {
  printf '%s\n' "$*" >>"$T/pass_available_args"
  return "${PASS_AVAILABLE_RC:-0}"
}

run_open_question_adjudication() {
  printf '%s\n' "$*" >>"$T/adjudicate_args"
  printf '%s' "$ADJUDICATION_JSON"
}

landing_open_question_latest() {
  printf '%s\n' "$*" >>"$T/latest_args"
  printf '%s' "${LATEST_JSON:-[]}"
}

landing_open_question_label_release() {
  printf '%s\n' "$*" >>"$T/release_args"
  return "${RELEASE_RC:-0}"
}

open_question_escalate() {
  printf '%s\n' "$*" >>"$T/escalate_calls"
}

gh() {
  printf '%s\n' "$*" >>"$T/gh_calls"
  return 1
}

HARNESS

URL="https://github.com/Poetic-Poems/agent-ops/pull/512"

{
  printf '%s\n' "$refuse_block"
  printf '%s\n' "$resolve_block"
  printf '_landing_open_question_resolve "Poetic-Poems/agent-ops" "%s" "512" ""\n' "$URL"
} >>"$tmp_dir/harness_a.sh"

# run_case_a [KEY=VALUE ...]
run_case_a() {
  : >"$tmp_dir/events"; : >"$tmp_dir/level_args"; : >"$tmp_dir/pass_available_args"
  : >"$tmp_dir/adjudicate_args"; : >"$tmp_dir/latest_args"; : >"$tmp_dir/release_args"
  : >"$tmp_dir/escalate_calls"; : >"$tmp_dir/gh_calls"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" URL="$URL" \
    LEVEL="always-escalate" PASS_AVAILABLE_RC="0" ADJUDICATION_JSON='{}' \
    LATEST_JSON='[]' RELEASE_RC="0" \
    "$@" \
    bash "$tmp_dir/harness_a.sh" >"$tmp_dir/stdout_a" 2>"$tmp_dir/stderr_a"
  printf '%s' "$?"
}

events_a() { cat "$tmp_dir/events"; }
event_of_a() { awk -F'\t' -v e="$1" '$1==e{print $2}' "$tmp_dir/events" | tail -1; }

# --- always-escalate: never adjudicates, always escalates and refuses ------

rc="$(run_case_a LEVEL="always-escalate")"
assert_eq "always-escalate refuses" "1" "$rc"
assert_eq "always-escalate never asks open_question_pass_available" "" "$(cat "$tmp_dir/pass_available_args")"
assert_eq "always-escalate never runs an adjudication pass" "" "$(cat "$tmp_dir/adjudicate_args")"
assert_eq "always-escalate escalates exactly once" "1" "$(wc -l <"$tmp_dir/escalate_calls" | tr -d ' ')"
assert_contains "always-escalate's landing-refused names the item" \
  "open-question:$URL carries an unresolved open question" "$(event_of_a landing-refused)"

# --- adjudicate-first, no pass available: escalates without adjudicating ---

rc="$(run_case_a LEVEL="adjudicate-first" PASS_AVAILABLE_RC="1")"
assert_eq "adjudicate-first with no pass available refuses" "1" "$rc"
assert_eq "... having asked open_question_pass_available" \
  "1" "$(wc -l <"$tmp_dir/pass_available_args" | tr -d ' ')"
assert_eq "... but run no adjudication pass" "" "$(cat "$tmp_dir/adjudicate_args")"
assert_eq "... and still escalates exactly once" "1" "$(wc -l <"$tmp_dir/escalate_calls" | tr -d ' ')"

# --- adjudicate-first, settled: releases the label, posts nothing (no gh
#     stub configured to succeed — see gh() above), and passes ------------

rc="$(run_case_a LEVEL="adjudicate-first" PASS_AVAILABLE_RC="0" \
  ADJUDICATION_JSON='{"verdict":"settled","evidence":"the diff already answers it","answer":"Yes, CODEOWNERS is in scope."}')"
assert_eq "adjudicate-first settled falls through (does not refuse)" "0" "$rc"
assert_contains "... logs open-question-adjudication with verdict settled" \
  '"verdict":"settled"' "$(event_of_a open-question-adjudication)"
assert_contains "... carrying adjudication:true" '"adjudication":true' "$(event_of_a open-question-adjudication)"
assert_eq "... releases the label" "1" "$(wc -l <"$tmp_dir/release_args" | tr -d ' ')"
assert_eq "... escalates nothing" "" "$(cat "$tmp_dir/escalate_calls")"
assert_contains "... attempts to post the answer as a PR comment" \
  "pr comment $URL" "$(cat "$tmp_dir/gh_calls")"

# --- adjudicate-first, settled, but the label could not be released: still
#     falls through (not the pull request's fault) and warns -------------

rc="$(run_case_a LEVEL="adjudicate-first" PASS_AVAILABLE_RC="0" RELEASE_RC="1" \
  ADJUDICATION_JSON='{"verdict":"settled","evidence":"e","answer":""}')"
assert_eq "a settled verdict whose label release failed still falls through" "0" "$rc"
assert_contains "... and logs a warning naming the label" \
  "could not be removed" "$(event_of_a warning)"

# --- adjudicate-first, escalate: escalates with the adjudication's own
#     evidence and refuses ---------------------------------------------

rc="$(run_case_a LEVEL="adjudicate-first" PASS_AVAILABLE_RC="0" \
  ADJUDICATION_JSON='{"verdict":"escalate","evidence":"a human decision is needed"}')"
assert_eq "adjudicate-first escalate refuses" "1" "$rc"
assert_contains "... logs open-question-adjudication with verdict escalate" \
  '"verdict":"escalate"' "$(event_of_a open-question-adjudication)"
assert_eq "... escalates exactly once" "1" "$(wc -l <"$tmp_dir/escalate_calls" | tr -d ' ')"
assert_contains "... naming the adjudication pass could not settle it" \
  "the adjudication pass could not settle" "$(event_of_a landing-refused)"

# --- an unrecognised verdict from the adjudication pass reads as escalate,
#     never as settled — "cannot settle" is not "nothing wrong" ----------

rc="$(run_case_a LEVEL="adjudicate-first" PASS_AVAILABLE_RC="0" \
  ADJUDICATION_JSON='{"verdict":"something-else","evidence":"e"}')"
assert_eq "an unrecognised verdict refuses" "1" "$rc"
assert_contains "... logged as escalate, never settled" \
  '"verdict":"escalate"' "$(event_of_a open-question-adjudication)"

echo

# ============================================================================
# Part B: `open_question_pass_available` and
# `open_question_adjudicated_before`, on their own (a real `gh` stub and a
# real synthetic log, no `_landing_open_question_resolve` wrapper).
# ============================================================================

cat >"$tmp_dir/harness_b.sh" <<'HARNESS'
set -euo pipefail
enabler_escalation_label="agent-escalation"
union_log="$LOG"
log_file="$LOG"
log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }
gh() {
  if [[ "$1" == "issue" && "$2" == "list" ]]; then
    printf '%s' "$CLOSED_ISSUES_JSON"
    return 0
  fi
  return 1
}
HARNESS

{
  printf '%s\n' "$adjudicated_before_block"
  printf '%s\n' "$pass_available_block"
  printf 'open_question_pass_available "%s" "%s" "%s"\n' \
    'Poetic-Poems/agent-ops' "$URL" 'pr-512-open-question'
} >>"$tmp_dir/harness_b.sh"

run_case_b() {
  : >"$tmp_dir/events"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" URL="$URL" LOG="$tmp_dir/log.jsonl" \
    CLOSED_ISSUES_JSON="[]" \
    "$@" \
    bash "$tmp_dir/harness_b.sh" >"$tmp_dir/stdout_b" 2>"$tmp_dir/stderr_b"
  printf '%s' "$?"
}

: >"$tmp_dir/log.jsonl"
rc="$(run_case_b)"
assert_eq "no prior adjudication, no closed issue: a pass is available" "0" "$rc"

cat >"$tmp_dir/log.jsonl" <<EOF
{"ts":"2026-08-20T00:00:00Z","event":"open-question-raised","pr_url":"$URL"}
{"ts":"2026-08-20T01:00:00Z","event":"open-question-adjudication","pr_url":"$URL","verdict":"escalate"}
EOF
rc="$(run_case_b)"
assert_eq "an adjudication already on the log since the last raise: no pass" "1" "$rc"
assert_contains "... logs why" "already spent its one adjudication pass" "$(awk -F'\t' '$1=="warning"{print $2}' "$tmp_dir/events" | tail -1)"

rc="$(run_case_b CLOSED_ISSUES_JSON='[{"body":"Item: `pr-512-open-question` · pull request '"$URL"'"}]')"
assert_eq "a closed escalation issue for this item: a pass is available again" "0" "$rc"

cat >"$tmp_dir/log.jsonl" <<EOF
{"ts":"2026-08-20T00:00:00Z","event":"open-question-adjudication","pr_url":"$URL","verdict":"escalate"}
{"ts":"2026-08-21T00:00:00Z","event":"open-question-raised","pr_url":"$URL"}
EOF
rc="$(run_case_b)"
assert_eq "an adjudication event that predates the latest raise does not count" "0" "$rc"

echo

# ============================================================================
# Part C: `run_open_question_adjudication` itself — the prompt launch, model
# choice and verdict parsing — with `run_claude_stage` stubbed instead of the
# whole ladder above it.
# ============================================================================

cat >"$tmp_dir/harness_c.sh" <<'HARNESS'
set -euo pipefail
PROMPTS_DIR="${PROMPTS_DIR_OVERRIDE:-$SCRIPT_DIR/prompts}"
state_dir="$T/state"
cycle_dir="$T/cycle"
union_log="$T/union.jsonl"
log_file="$T/log.jsonl"
stage_backstop_min=30
stage_inactivity_min=10
stage_kill_reason=""
stage_gaps_json='[]'
approver_model_critical="${MODEL_CRITICAL-claude-fable-5}"
mkdir -p "$state_dir" "$cycle_dir"
: >"$union_log"; : >"$log_file"

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }
# docs/FLOW-SCHEMA.md, requirement 47, issue #596: run_open_question_
# adjudication's own stage-end site calls lib/rework.sh's rework_stage_
# rerun_maybe — out of this file's own scope (test/rework-record.test.sh
# covers it directly). Stubbed to a no-op, the same "does not fire" shape
# the real function takes whenever stage_kill_reason (set above) is empty.
rework_stage_rerun_maybe() { :; }
# docs/FLOW-SCHEMA.md, requirement 50, issue #597: the same stage-end site
# also calls lib/node-time-state.sh's log_node_state_transition — out of
# this file's own scope (test/node-time-state.test.sh covers it directly).
log_node_state_transition() { :; }
landing_open_question_latest() { printf '%s' '[{"question":"is CODEOWNERS in scope?"}]'; }
stage_prompt_text() { printf '%s\n' "$3" >>"$T/prompt_actor_args"; printf 'THE PROMPT'; }
stage_budget_apply() { :; }
metering_fields() { printf '{}'; }
extract_json_result() { [[ -n "${1// /}" ]] || return 1; jq -c . <<<"$1"; }

run_claude_stage() {
  printf '%s\n' "$3" >>"$T/launches"
  if [[ "${STAGE_RC:-0}" != "0" ]]; then
    return "$STAGE_RC"
  fi
  if [[ -n "${RESULT_JSON:-}" ]]; then
    jq -nc --arg r "$RESULT_JSON" '{result: $r}' >"$5"
  else
    : >"$5"
  fi
  return 0
}

HARNESS

{
  printf '%s\n' "$adjudicate_block"
  printf 'run_open_question_adjudication "%s" "%s" "%s"\n' 'Poetic-Poems/agent-ops' "$URL" '512'
} >>"$tmp_dir/harness_c.sh"

run_case_c() {
  : >"$tmp_dir/events"; : >"$tmp_dir/launches"; : >"$tmp_dir/prompt_actor_args"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" URL="$URL" SCRIPT_DIR="$SCRIPT_DIR" \
    STAGE_RC="0" RESULT_JSON='{"verdict":"settled","evidence":"e","answer":"a"}' \
    "$@" \
    bash "$tmp_dir/harness_c.sh" 2>"$tmp_dir/stderr_c"
}

out="$(run_case_c)"
assert_eq "builds its prompt as its own distinct actor, never approver or enabler-adjudicate" \
  "approver-adjudicate-open-question" "$(cat "$tmp_dir/prompt_actor_args")"
assert_eq "launches at approver_model_critical, never enabler_model or a Standard tier" \
  "claude-fable-5" "$(cat "$tmp_dir/launches")"
assert_eq "a settled verdict passes through with its answer" \
  '{"verdict":"settled","evidence":"e","answer":"a"}' "$out"

out="$(run_case_c MODEL_CRITICAL="")"
assert_eq "no approver_model_critical configured escalates without launching anything" \
  '{"verdict":"escalate","evidence":"no approver_model_critical is configured to adjudicate this question"}' "$out"
assert_eq "... and launches nothing" "" "$(cat "$tmp_dir/launches")"

out="$(run_case_c PROMPTS_DIR_OVERRIDE="$tmp_dir/no-prompts-here")"
assert_eq "a missing prompt file escalates without launching anything" \
  '{"verdict":"escalate","evidence":"no prompts/approver-adjudicate-open-question.md in this installation"}' "$out"
assert_eq "... and launches nothing" "" "$(cat "$tmp_dir/launches")"

out="$(run_case_c STAGE_RC="1" RESULT_JSON="")"
assert_eq "a stage failure escalates" \
  '{"verdict":"escalate","evidence":"the adjudication engagement returned no parseable verdict"}' "$out"

out="$(run_case_c STAGE_RC="124" RESULT_JSON="")"
assert_eq "a timeout escalates with its own evidence" \
  '{"verdict":"escalate","evidence":"the adjudication engagement timed out"}' "$out"

out="$(run_case_c RESULT_JSON='not json at all')"
assert_eq "an unparseable result escalates" \
  '{"verdict":"escalate","evidence":"the adjudication engagement returned no parseable verdict"}' "$out"

out="$(run_case_c RESULT_JSON='{"verdict":"land","evidence":"e"}')"
assert_eq "requirement 8c's own land/refuse/escalate vocabulary is not read as settled" \
  '{"verdict":"escalate","evidence":"e"}' "$out"

echo

# ============================================================================
# Part D: `open_question_escalate` itself — the issue body it composes and
# `create_escalation_issue`'s dedup key.
# ============================================================================

cat >"$tmp_dir/harness_d.sh" <<'HARNESS'
set -euo pipefail
enabler_escalation_label="agent-escalation"
# lib/landing.sh's own fixed label, which the issue body names so the human
# is told what actually releases the gate (only removing it, or a `settled`
# adjudication, does — closing the issue does not).
LANDING_OPEN_QUESTION_LABEL="open-question"
cycle_id="20260825T000000Z-test-1"
node_name="test-node"
cycle_dir="$T/cycle"
union_log="$T/union.jsonl"
log_file="$T/log.jsonl"
escalation_refile_after_hours="${WINDOW_HOURS:-24}"
mkdir -p "$cycle_dir"
: >"$union_log"
: >"$log_file"
[[ -n "${UNION_LOG_SEED:-}" ]] && printf '%s\n' "$UNION_LOG_SEED" >>"$union_log"

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

# escalation_recent_close (lib/enabler.sh) is a live GitHub read — stubbed
# here as a black box, the same relationship this harness already has with
# create_escalation_issue. RECENT_CLOSE, when set, is
# "<number>\t<url>\t<closedAt>"; unset/empty means no recent close.
escalation_recent_close() {
  printf '%s\n' "$*" >>"$T/recent_close_args"
  [[ -n "${RECENT_CLOSE:-}" ]] && printf '%s' "$RECENT_CLOSE"
  return 0
}

create_escalation_issue() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$T/create_args"
  cat "$5" >"$T/body.md"
  [[ "${CREATE_RC:-0}" == "0" ]] || return 1
  printf '42\thttps://github.com/Poetic-Poems/agent-ops/issues/42'
}
HARNESS

{
  printf '%s\n' "$refile_suppressed_block"
  printf '%s\n' "$event_logged_since_block"
  printf '%s\n' "$escalate_block"
  printf 'open_question_escalate "Poetic-Poems/agent-ops" "%s" "pr-512-open-question" "$QUESTIONS_JSON" "${ADJUDICATION_JSON:-}"\n' \
    'https://github.com/Poetic-Poems/agent-ops/pull/512'
} >>"$tmp_dir/harness_d.sh"

run_case_d() {
  : >"$tmp_dir/events"; : >"$tmp_dir/create_args"; : >"$tmp_dir/recent_close_args"; rm -f "$tmp_dir/body.md"
  env -i PATH="$PATH" HOME="$HOME" T="$tmp_dir" \
    CREATE_RC="0" \
    "$@" \
    bash "$tmp_dir/harness_d.sh" >/dev/null 2>"$tmp_dir/stderr_d"
}

QUESTIONS='[{"question":"Is CODEOWNERS in scope?","why_this_actor_cannot_settle_it":"scope judgement call","comment_url":"https://github.com/x/y/pull/1#issuecomment-1"}]'

run_case_d QUESTIONS_JSON="$QUESTIONS"
assert_contains "escalates against the item's own repo, item ref and label" \
  $'Poetic-Poems/agent-ops\tpr-512-open-question\tagent-escalation' "$(cat "$tmp_dir/create_args")"
assert_contains "the issue body names the question" \
  "Is CODEOWNERS in scope?" "$(cat "$tmp_dir/body.md")"
assert_contains "... and why the Reviewer could not settle it" \
  "scope judgement call" "$(cat "$tmp_dir/body.md")"
assert_contains "... and the pull request's own footer, distinct from pr-<n>-approver-adjudication" \
  "pr-512-open-question" "$(cat "$tmp_dir/body.md")"
assert_contains "... and tells the human that removing the label is what releases the gate" \
  "remove the \`open-question\` label" "$(cat "$tmp_dir/body.md")"
assert_contains "... never that closing the issue alone clears it" \
  "Closing this issue alone does not clear it" "$(cat "$tmp_dir/body.md")"
assert_contains "logs open-question-escalated with the issue number and url" \
  '"issue_number":42' "$(awk -F'\t' '$1=="open-question-escalated"{print $2}' "$tmp_dir/events")"

run_case_d QUESTIONS_JSON="$QUESTIONS" ADJUDICATION_JSON='{"verdict":"escalate","evidence":"could not settle it"}'
assert_contains "an adjudication attempt is quoted in the issue body" \
  "Adjudication attempted" "$(cat "$tmp_dir/body.md")"
assert_contains "... including its own evidence" \
  "could not settle it" "$(cat "$tmp_dir/body.md")"

run_case_d QUESTIONS_JSON="$QUESTIONS" CREATE_RC="1"
assert_eq "a failed filing logs a warning, never open-question-escalated" \
  "" "$(awk -F'\t' '$1=="open-question-escalated"{print $2}' "$tmp_dir/events")"
assert_contains "... naming the pull request" \
  "the escalation issue could not be filed" \
  "$(awk -F'\t' '$1=="warning"{print $2}' "$tmp_dir/events")"

# --- the requirement 8f re-filing guard (agent-ops#779, decided on #784) ----

recent_1h_ago="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
recent_25h_ago="$(date -u -d '-25 hours' +%Y-%m-%dT%H:%M:%SZ)"
PRIOR_ISSUE=$'41\thttps://github.com/Poetic-Poems/agent-ops/issues/41\t'"$recent_1h_ago"
PRIOR_ISSUE_LAPSED=$'41\thttps://github.com/Poetic-Poems/agent-ops/issues/41\t'"$recent_25h_ago"

# closed 1h ago, 24h window, no adjudication pass this round: suppressed —
# no create call, no open-question-escalated, a warning naming the prior issue.
run_case_d QUESTIONS_JSON="$QUESTIONS" RECENT_CLOSE="$PRIOR_ISSUE"
assert_eq "within the window, no owed re-escalation: files nothing" "" "$(cat "$tmp_dir/create_args")"
assert_eq "... and logs no open-question-escalated" "" \
  "$(awk -F'\t' '$1=="open-question-escalated"{print $2}' "$tmp_dir/events")"
assert_contains "... its warning names the prior issue" \
  "https://github.com/Poetic-Poems/agent-ops/issues/41" \
  "$(awk -F'\t' '$1=="warning"{print $2}' "$tmp_dir/events")"

# closed 1h ago, an adjudication pass ran this round, and no
# open-question-escalated logged for this pull request since that close: the
# one owed re-escalation always files, window or not, and the body says why
# it's back.
run_case_d QUESTIONS_JSON="$QUESTIONS" RECENT_CLOSE="$PRIOR_ISSUE" \
  ADJUDICATION_JSON='{"verdict":"escalate","evidence":"could not settle it"}'
assert_contains "the owed re-escalation still files" \
  $'Poetic-Poems/agent-ops\tpr-512-open-question\tagent-escalation' "$(cat "$tmp_dir/create_args")"
assert_contains "... naming the prior issue" \
  "https://github.com/Poetic-Poems/agent-ops/issues/41" "$(cat "$tmp_dir/body.md")"
assert_contains "... under a \"Why this is back\" section" \
  "Why this is back" "$(cat "$tmp_dir/body.md")"
assert_contains "... naming removing the label as the releasing act, not the closed issue" \
  "is what releases it" "$(cat "$tmp_dir/body.md")"

# same as above, but this close's one owed re-escalation was already spent
# earlier the same round (an open-question-escalated event already on the
# log at or after the close): back under the ordinary window, suppressed.
seeded_event="$(jq -nc --arg u 'https://github.com/Poetic-Poems/agent-ops/pull/512' --arg t "$recent_1h_ago" \
  '{ts: $t, event: "open-question-escalated", pr_url: $u, issue_number: 41,
    issue_url: "https://github.com/Poetic-Poems/agent-ops/issues/41"}')"
run_case_d QUESTIONS_JSON="$QUESTIONS" RECENT_CLOSE="$PRIOR_ISSUE" \
  ADJUDICATION_JSON='{"verdict":"escalate","evidence":"could not settle it"}' \
  UNION_LOG_SEED="$seeded_event"
assert_eq "the owed re-escalation, once already spent, is suppressed like any other" \
  "" "$(cat "$tmp_dir/create_args")"

# the most recent close is older than the window: no owed re-escalation is
# even needed — it just files normally, with the same "why it's back" body.
run_case_d QUESTIONS_JSON="$QUESTIONS" RECENT_CLOSE="$PRIOR_ISSUE_LAPSED"
assert_contains "a close older than the window files normally" \
  $'Poetic-Poems/agent-ops\tpr-512-open-question\tagent-escalation' "$(cat "$tmp_dir/create_args")"
assert_contains "... and still explains why it's back" \
  "Why this is back" "$(cat "$tmp_dir/body.md")"

# escalation_refile_after_hours: 0 is the explicit off switch — every
# refusing round files, exactly as before this guard existed, however recent
# the close and however many were already filed this round.
run_case_d QUESTIONS_JSON="$QUESTIONS" RECENT_CLOSE="$PRIOR_ISSUE" WINDOW_HOURS="0"
assert_contains "a window of 0 always files" \
  $'Poetic-Poems/agent-ops\tpr-512-open-question\tagent-escalation' "$(cat "$tmp_dir/create_args")"

# no recent close at all: unchanged from before this guard existed — no
# "why it's back" section, ordinary filing.
run_case_d QUESTIONS_JSON="$QUESTIONS"
assert_not_contains "no recent close: no 'why it's back' section" \
  "Why this is back" "$(cat "$tmp_dir/body.md")"

echo

if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
