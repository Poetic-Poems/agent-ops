#!/usr/bin/env bash
#
# test/crash-loop.test.sh — a fleet-wide crash loop, of either class
# requirement 2.7 detects, is detected once and escalated once (acceptance
# check 5a).
#
# What this guards: a Co-Ordinator failure pins no repo/item, so the blocked →
# Enabler → escalation ladder never sees it, and the cycle still ends 0. On
# 2026-08-01 a deterministic failure shipped in the image (`coordinator exited
# 126`), every node failed identically every hour for ~15 hours, and the
# dashboard showed four healthy idle nodes throughout. `lib/crash-loop.sh` is
# the rung that class now has; these are its properties, each of which fails
# silently if lost:
#
#   identical detail       one timeout plus one unparseable message is noise,
#                          not a loop — mixed details must reset the count
#   any success resets     a fleet that is mostly working is not crash-looping,
#                          however many failures a week accumulates
#   ordering is truth      an "unparseable final message" failure follows its
#                          own stage-end 0; that cycle is one failure, not a
#                          continuation of the run the success just ended
#   escalated once         the same run must not file an issue every hour; a
#                          NEW run with the SAME detail, after the old issue
#                          closed, must file afresh
#
# `crash_loop_preselection_verdict` covers the class the Co-Ordinator check
# above cannot see: a cycle that dies while assembling its own runtime input,
# before `stage-start` for any stage is ever logged, so no `attempt-failed`
# exists for anything to count (TD-PPagop-26081302 — the 2026-08-01 argv-cap
# outage and the 2026-08-12 void-extract one both took this shape). It shares
# the same properties above, grouped by `exit_code` instead of `detail` since
# a pre-selection death carries no detail string, and a completed cycle
# reaching a selection-path stage (`coordinator`, `implementer`, `reviewer`)
# resets it exactly as a success does — reaching selection proves the systemic
# block is not reproducing right now. A cleanup-path stage (`enabler`,
# `refiner`) never resets: those start after a pre-selection death has already
# happened, so counting them as recovery would silence the alarm the moment
# their non-zero-exit guards were relaxed.
#
# No network: all three functions are pure readers of an event stream on
# stdin.
#
# Run directly: ./test/crash-loop.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/crash-loop.sh
. "$SCRIPT_DIR/lib/crash-loop.sh"

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

# Event constructors, so the cases below read as timelines rather than JSON.
fail_at() {  # fail_at TS NODE DETAIL
  jq -nc --arg ts "$1" --arg node "$2" --arg d "$3" \
    '{ts: $ts, node: $node, event: "attempt-failed", stage: "coordinator", detail: $d}'
}
# fail_class_at TS NODE DETAIL CLASS — a refusal carrying its own
# api_refusal_class (issue #1073), the field handle_stage_failure now adds
# when stage_api_refusal_class could classify the refusal.
fail_class_at() {
  jq -nc --arg ts "$1" --arg node "$2" --arg d "$3" --arg c "$4" \
    '{ts: $ts, node: $node, event: "attempt-failed", stage: "coordinator", detail: $d, api_refusal_class: $c}'
}
success_at() {  # success_at TS NODE
  jq -nc --arg ts "$1" --arg node "$2" \
    '{ts: $ts, node: $node, event: "stage-end", stage: "coordinator", exit_code: 0}'
}
escalated_at() {  # escalated_at TS DETAIL [ISSUE_NUMBER]
  jq -nc --arg ts "$1" --arg d "$2" --argjson n "${3:-0}" \
    '{ts: $ts, node: "n1", event: "crash-loop-escalated", stage: "coordinator", detail: $d}
     + (if $n > 0 then {issue_number: $n, issue_url: "https://github.com/o/r/issues/\($n)"} else {} end)'
}
deferred_at() {  # deferred_at TS DETAIL
  jq -nc --arg ts "$1" --arg d "$2" \
    '{ts: $ts, node: "n1", event: "crash-loop-deferred", stage: "coordinator", detail: $d}'
}
retired_at() {  # retired_at TS ISSUE_NUMBER
  jq -nc --arg ts "$1" --argjson n "$2" \
    '{ts: $ts, node: "n1", event: "crash-loop-retired", stage: "coordinator", issue_number: $n}'
}

# Event constructors for the pre-selection class (a cycle that dies before
# any stage starts): a bare cycle-start/cycle-end pair, no stage-start.
cycle_start_at() {  # cycle_start_at TS NODE CYCLE
  jq -nc --arg ts "$1" --arg node "$2" --arg cycle "$3" \
    '{ts: $ts, node: $node, cycle: $cycle, event: "cycle-start"}'
}
cycle_end_at() {  # cycle_end_at TS NODE CYCLE EXIT_CODE
  jq -nc --arg ts "$1" --arg node "$2" --arg cycle "$3" --argjson rc "$4" \
    '{ts: $ts, node: $node, cycle: $cycle, event: "cycle-end", exit_code: $rc}'
}
stage_start_at() {  # stage_start_at TS NODE CYCLE STAGE
  jq -nc --arg ts "$1" --arg node "$2" --arg cycle "$3" --arg stage "$4" \
    '{ts: $ts, node: $node, cycle: $cycle, event: "stage-start", stage: $stage}'
}
died_at() {  # died_at TS NODE CYCLE EXIT_CODE — a full pre-selection death: no stage-start
  cycle_start_at "$1" "$2" "$3"
  cycle_end_at "$1" "$2" "$3" "$4"
}

# --- crash_loop_verdict ---------------------------------------------------------

four_fails="$(fail_at 2026-08-01T10:00:00Z n1 'coordinator exited 126'
  fail_at 2026-08-01T10:15:00Z n2 'coordinator exited 126'
  fail_at 2026-08-01T10:30:00Z n3 'coordinator exited 126'
  fail_at 2026-08-01T10:45:00Z n4 'coordinator exited 126')"

verdict="$(crash_loop_verdict 4 <<<"$four_fails")"
assert_eq "threshold-many identical failures yield a verdict that escalates" \
  '{"stage":"coordinator","detail":"coordinator exited 126","count":4,"first_ts":"2026-08-01T10:00:00Z","last_ts":"2026-08-01T10:45:00Z","nodes":["n1","n2","n3","n4"],"escalate":true}' \
  "$verdict"

assert_eq "one fewer yields nothing" "" \
  "$(head -n3 <<<"$four_fails" | crash_loop_verdict 4)"

assert_eq "a success mid-run resets the count" "" \
  "$(crash_loop_verdict 4 <<<"$(head -n2 <<<"$four_fails"
    success_at 2026-08-01T10:20:00Z n2
    tail -n2 <<<"$four_fails")")"

# The unparseable-final-message shape: stage-end 0 lands first, then the
# failure. The success ends the old run; the failure starts a new one at 1.
unparseable="$(head -n3 <<<"$four_fails"
  success_at 2026-08-01T10:50:00Z n1
  fail_at 2026-08-01T10:51:00Z n1 'unparseable final message')"
assert_eq "a success followed by its own unparseable failure counts one, not five" \
  "" "$(crash_loop_verdict 2 <<<"$unparseable")"
assert_eq "and that single failure seeds the next run" \
  "1" "$(crash_loop_verdict 1 <<<"$unparseable" | jq -r '.count')"

mixed="$(head -n2 <<<"$four_fails"
  fail_at 2026-08-01T10:30:00Z n3 'coordinator timed out'
  fail_at 2026-08-01T10:45:00Z n4 'coordinator timed out')"
assert_eq "a detail change restarts the count at one" "" \
  "$(crash_loop_verdict 3 <<<"$mixed")"
assert_eq "with the newest detail carried, at count two" \
  '["coordinator timed out",2]' \
  "$(crash_loop_verdict 2 <<<"$mixed" | jq -c '[.detail, .count]')"

noise="$(fail_at 2026-08-01T10:05:00Z n1 'implementer exited 1' | jq -c '.stage = "implementer"'
  jq -nc '{ts: "2026-08-01T10:06:00Z", node: "n2", event: "claim-lost", rc: 3}'
  cat <<<"$four_fails")"
assert_eq "item-stage failures and unrelated events never contribute or reset" \
  "4" "$(crash_loop_verdict 4 <<<"$noise" | jq -r '.count')"

assert_eq "a threshold of 0 is the off switch" "" \
  "$(crash_loop_verdict 0 <<<"$four_fails")"
assert_eq "and so is a non-numeric threshold" "" \
  "$(crash_loop_verdict banana <<<"$four_fails")"
assert_eq "an empty stream yields nothing" "" "$(crash_loop_verdict 1 <<<"")"

torn="$(head -n2 <<<"$four_fails"
  printf '{"ts": "2026-08-01T10:2'
  printf '\n'
  tail -n2 <<<"$four_fails")"
assert_eq "a torn line is skipped, not a reset" \
  "4" "$(crash_loop_verdict 4 <<<"$torn" | jq -r '.count')"

# --- crash_loop_verdict: transient class (issue #1073) ---------------------------
#
# The Ockham outage (2026-08-29/30): the host lost outbound network for four
# hours, and every Co-Ordinator failure recorded the same detail ("api_error")
# with api_error_status 503 — a provider outage, not a deterministic fault.
# `handle_stage_failure` now carries that as `api_refusal_class: "transient"`
# on the event, and a run where every failure counted carries it must not
# escalate — the exact replay #1073 asks for.
sixteen_transient="$(for i in $(seq 1 16); do
    fail_class_at "2026-08-29T22:$(printf '%02d' "$i"):00Z" "n$(( (i % 2) + 1 ))" "api_error" "transient"
  done)"
verdict="$(crash_loop_verdict 4 <<<"$sixteen_transient")"
assert_eq "16 consecutive transient refusals still yield a verdict" \
  "16" "$(jq -r '.count' <<<"$verdict")"
assert_eq "but one that does not escalate" \
  "false" "$(jq -r '.escalate' <<<"$verdict")"

# The 2026-08-21 prompt_too_long outage: a named deterministic reason, class
# `refused`. Grouping across cycles whose own message differs is already
# covered above (detail alone carries the group); this pins that a `refused`
# run — the class requirement 2.7's escalation was built for — still
# escalates exactly as before.
four_refused="$(fail_class_at 2026-08-21T10:00:00Z n1 prompt_too_long refused
  fail_class_at 2026-08-21T10:15:00Z n2 prompt_too_long refused
  fail_class_at 2026-08-21T10:30:00Z n3 prompt_too_long refused
  fail_class_at 2026-08-21T10:45:00Z n4 prompt_too_long refused)"
assert_eq "a refused run still escalates, unchanged" \
  "true" "$(crash_loop_verdict 4 <<<"$four_refused" | jq -r '.escalate')"

# A run mixing a transient failure with an unclassified (or refused) one is
# not proven transient by the member that was, so it escalates — the safe
# default over silently swallowing a real deterministic loop.
mixed_class="$(fail_class_at 2026-08-29T22:00:00Z n1 mixed-detail transient
  fail_class_at 2026-08-29T22:15:00Z n2 mixed-detail refused
  fail_class_at 2026-08-29T22:30:00Z n3 mixed-detail transient
  fail_class_at 2026-08-29T22:45:00Z n4 mixed-detail transient)"
assert_eq "a run with one non-transient member still escalates" \
  "true" "$(crash_loop_verdict 4 <<<"$mixed_class" | jq -r '.escalate')"

# A run with no class information at all (an ordinary crash, a timeout — never
# what stage_api_refusal_class classifies) defaults to escalating, exactly as
# every run did before this field existed.
assert_eq "an unclassified run defaults to escalating" \
  "true" "$(crash_loop_verdict 4 <<<"$four_fails" | jq -r '.escalate')"

# A success still resets a transient run exactly as it resets any other: with
# the success spliced in after the first 2 of 16, only 14 remain after the
# reset, below a threshold of 15.
assert_eq "a success mid-run resets a transient run too" "" \
  "$(crash_loop_verdict 15 <<<"$(head -n2 <<<"$sixteen_transient"
    success_at 2026-08-29T22:05:00Z n2
    tail -n14 <<<"$sixteen_transient")")"

# --- crash_loop_preselection_verdict ---------------------------------------------
#
# The class `crash_loop_verdict` cannot see: a cycle that dies while
# assembling its own runtime input logs `cycle-start` then `cycle-end` with a
# non-zero exit code, but no `stage-start` for any stage — no Co-Ordinator
# `attempt-failed` exists at all. Grouped by `exit_code`, since there is no
# `detail` string on this path.

four_deaths="$(died_at 2026-08-01T10:00:00Z n1 c1 126
  died_at 2026-08-01T10:15:00Z n2 c2 126
  died_at 2026-08-01T10:30:00Z n3 c3 126
  died_at 2026-08-01T10:45:00Z n4 c4 126)"

verdict="$(crash_loop_preselection_verdict 4 <<<"$four_deaths")"
assert_eq "threshold-many identical pre-selection deaths yield a verdict" \
  '{"stage":"pre-selection","detail":"cycle exited 126 before any stage started","exit_code":126,"count":4,"first_ts":"2026-08-01T10:00:00Z","last_ts":"2026-08-01T10:45:00Z","nodes":["n1","n2","n3","n4"]}' \
  "$verdict"

assert_eq "one fewer yields nothing" "" \
  "$(head -n6 <<<"$four_deaths" | crash_loop_preselection_verdict 4)"

reset_via_stage="$(head -n4 <<<"$four_deaths"
  cycle_start_at 2026-08-01T10:20:00Z n2 c2b
  stage_start_at 2026-08-01T10:21:00Z n2 c2b coordinator
  cycle_end_at 2026-08-01T10:25:00Z n2 c2b 1
  tail -n4 <<<"$four_deaths")"
assert_eq "a completed cycle reaching a stage resets the count, whatever it then exits" \
  "" "$(crash_loop_preselection_verdict 4 <<<"$reset_via_stage")"

reset_via_success="$(head -n4 <<<"$four_deaths"
  died_at 2026-08-01T10:20:00Z n2 c2b 0
  tail -n4 <<<"$four_deaths")"
assert_eq "a clean exit mid-run resets the count" "" \
  "$(crash_loop_preselection_verdict 4 <<<"$reset_via_success")"

# The Enabler and Refiner start from cleanup(), after a pre-selection death
# has already happened — a stage-start from either is evidence the post-mortem
# path ran, not that selection got anywhere. Today their guards keep them off
# dead cycles entirely; if that is ever relaxed, these two cycles are exactly
# what the union would show, and they must count as deaths, not recovery.
cleanup_stage_deaths="$(head -n4 <<<"$four_deaths"
  cycle_start_at 2026-08-01T10:20:00Z n2 c2b
  stage_start_at 2026-08-01T10:21:00Z n2 c2b enabler
  cycle_end_at 2026-08-01T10:25:00Z n2 c2b 126
  cycle_start_at 2026-08-01T10:26:00Z n3 c3b
  stage_start_at 2026-08-01T10:27:00Z n3 c3b refiner
  cycle_end_at 2026-08-01T10:28:00Z n3 c3b 126
  tail -n4 <<<"$four_deaths")"
assert_eq "an Enabler or Refiner stage-start never counts as recovery" \
  "6" "$(crash_loop_preselection_verdict 4 <<<"$cleanup_stage_deaths" | jq -r '.count')"

exit_code_change="$(head -n4 <<<"$four_deaths"
  died_at 2026-08-01T11:00:00Z n3 c5 137
  died_at 2026-08-01T11:15:00Z n4 c6 137)"
assert_eq "an exit-code change restarts the count at one" "" \
  "$(crash_loop_preselection_verdict 3 <<<"$exit_code_change")"
assert_eq "with the newest exit code carried, at count two" \
  '[137,2]' \
  "$(crash_loop_preselection_verdict 2 <<<"$exit_code_change" | jq -c '[.exit_code, .count]')"

with_still_running="$(cat <<<"$four_deaths"
  cycle_start_at 2026-08-01T12:00:00Z n1 c9)"
assert_eq "a cycle with no cycle-end is dropped, not counted either way" \
  "4" "$(crash_loop_preselection_verdict 4 <<<"$with_still_running" | jq -r '.count')"

preselection_noise="$(fail_at 2026-08-01T10:05:00Z n1 'implementer exited 1' | jq -c '.stage = "implementer"'
  jq -nc '{ts: "2026-08-01T10:06:00Z", node: "n2", event: "claim-lost", rc: 3}'
  cat <<<"$four_deaths")"
assert_eq "item-stage failures and unrelated events never contribute or reset" \
  "4" "$(crash_loop_preselection_verdict 4 <<<"$preselection_noise" | jq -r '.count')"

assert_eq "a threshold of 0 is the off switch" "" \
  "$(crash_loop_preselection_verdict 0 <<<"$four_deaths")"
assert_eq "and so is a non-numeric threshold" "" \
  "$(crash_loop_preselection_verdict banana <<<"$four_deaths")"
assert_eq "an empty stream yields nothing" "" "$(crash_loop_preselection_verdict 1 <<<"")"

preselection_torn="$(head -n4 <<<"$four_deaths"
  printf '{"ts": "2026-08-01T10:5'
  printf '\n'
  tail -n4 <<<"$four_deaths")"
assert_eq "a torn line is skipped, not a reset" \
  "4" "$(crash_loop_preselection_verdict 4 <<<"$preselection_torn" | jq -r '.count')"

# --- crash_loop_escalated_since -------------------------------------------------

with_escalation="$(cat <<<"$four_fails"
  escalated_at 2026-08-01T11:00:00Z 'coordinator exited 126')"

if crash_loop_escalated_since 2026-08-01T10:00:00Z 'coordinator exited 126' <<<"$with_escalation"; then
  printf 'ok   - an escalation after the run'\''s first failure suppresses re-escalation\n'
else
  printf 'FAIL - an escalation after the run'\''s first failure should suppress re-escalation\n'
  failures=$(( failures + 1 ))
fi

if crash_loop_escalated_since 2026-08-02T00:00:00Z 'coordinator exited 126' <<<"$with_escalation"; then
  printf 'FAIL - an escalation older than a new run'\''s first failure should not suppress it\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - an old escalation does not suppress a fresh loop with the same detail\n'
fi

if crash_loop_escalated_since 2026-08-01T10:00:00Z 'coordinator exited 1' <<<"$with_escalation"; then
  printf 'FAIL - a different detail should never match\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - a different detail never matches\n'
fi

# --- crash_loop_deferred_since (agent-ops#1074) -----------------------------

with_deferral="$(cat <<<"$four_fails"
  deferred_at 2026-08-01T11:00:00Z 'coordinator exited 126')"

if crash_loop_deferred_since 2026-08-01T10:00:00Z 'coordinator exited 126' <<<"$with_deferral"; then
  printf 'ok   - a deferred marker after the run'\''s first failure marks it a retry\n'
else
  printf 'FAIL - a deferred marker after the run'\''s first failure should mark it a retry\n'
  failures=$(( failures + 1 ))
fi

if crash_loop_deferred_since 2026-08-01T10:00:00Z 'coordinator exited 126' <<<"$four_fails"; then
  printf 'FAIL - no deferred marker at all should never look like a retry\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - no deferred marker at all is a fresh verdict, not a retry\n'
fi

if crash_loop_deferred_since 2026-08-02T00:00:00Z 'coordinator exited 126' <<<"$with_deferral"; then
  printf 'FAIL - a deferral older than a new run'\''s first failure should not mark it a retry\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - an old deferral does not mark a fresh loop with the same detail as a retry\n'
fi

# --- crash_loop_reverify (agent-ops#1074) -----------------------------------
#
# The Ockham replay (2026-08-29/30, agent-ops#1070/#1074): 14 consecutive
# same-detail Co-Ordinator failures, each cycle logging a `crash-loop-
# deferred` marker because the forge was unreachable too. The retry cycle
# that finally reaches the network recomputes its verdict *before* its own
# Co-Ordinator attempt runs, so — at that point — the run still reads active:
# re-verifying immediately, from the same stale union log, would refile
# exactly the false alarm #1070 was. Only once that cycle's own Co-Ordinator
# success is folded into the union (as `crash_loop_refile_pending` does from
# `cleanup()`) does re-verifying see the run has broken.
ockham_start_epoch="$(date -u -d '2026-08-29T23:21:19Z' +%s)"
ockham_fails="$(for i in $(seq 0 13); do
    fail_at "$(date -u -d "@$(( ockham_start_epoch + i * 900 ))" +%FT%TZ)" n1 'coordinator refused: api_error'
  done)"
ockham_first_ts="2026-08-29T23:21:19Z"
ockham_verdict="$(crash_loop_verdict 4 <<<"$ockham_fails")"
assert_eq "the Ockham run's own verdict names its first failure" \
  "$ockham_first_ts" "$(jq -r '.first_ts' <<<"$ockham_verdict")"

assert_eq "re-verified against the same (pre-recovery) log, the run still reads active" \
  "$ockham_verdict" "$(crash_loop_reverify "$ockham_verdict" 4 <<<"$ockham_fails")"

ockham_with_recovery="$(cat <<<"$ockham_fails"
  success_at 2026-08-30T02:21:30Z n1)"
assert_eq "replaying the Ockham sequence through to its own cycle's recovery: no escalation" \
  "" "$(crash_loop_reverify "$ockham_verdict" 4 <<<"$ockham_with_recovery")"

ockham_still_failing="$(cat <<<"$ockham_fails"
  fail_at 2026-08-30T02:11:10Z n1 'coordinator refused: api_error')"
assert_eq "re-verified with one more matching failure and no success, still the same active run" \
  "coordinator refused: api_error" \
  "$(crash_loop_reverify "$ockham_verdict" 4 <<<"$ockham_still_failing" | jq -r '.detail')"

new_run_same_detail="$(cat <<<"$ockham_fails"
  success_at 2026-08-30T03:00:00Z n1
  fail_at 2026-08-30T03:15:00Z n1 'coordinator refused: api_error'
  fail_at 2026-08-30T03:30:00Z n1 'coordinator refused: api_error'
  fail_at 2026-08-30T03:45:00Z n1 'coordinator refused: api_error'
  fail_at 2026-08-30T04:00:00Z n1 'coordinator refused: api_error')"
assert_eq "a fresh run with the old run's detail is not mistaken for the old run surviving" \
  "" "$(crash_loop_reverify "$ockham_verdict" 4 <<<"$new_run_same_detail")"

assert_eq "an unrecognised stage never claims a run active" \
  "" "$(crash_loop_reverify '{"stage":"bogus","detail":"x","first_ts":"2026-08-01T00:00:00Z"}' 4 <<<"$ockham_fails")"

preselection_verdict="$(crash_loop_preselection_verdict 4 <<<"$four_deaths")"
assert_eq "crash_loop_reverify dispatches pre-selection verdicts too (in scope for free)" \
  "$preselection_verdict" "$(crash_loop_reverify "$preselection_verdict" 4 <<<"$four_deaths")"
assert_eq "and sees a pre-selection run broken by a selection-stage reset" \
  "" "$(crash_loop_reverify "$preselection_verdict" 4 <<<"$reset_via_stage")"

# --- crash_loop_last_success_since (agent-ops#1074) -------------------------

with_late_success="$(cat <<<"$four_fails"
  success_at 2026-08-01T12:00:00Z n2)"
assert_eq "names the clearing success's own timestamp" \
  "2026-08-01T12:00:00Z" "$(crash_loop_last_success_since coordinator 2026-08-01T10:00:00Z <<<"$with_late_success")"
assert_eq "nothing printed when no success exists at or after first_ts" \
  "" "$(crash_loop_last_success_since coordinator 2026-08-01T10:00:00Z <<<"$four_fails")"

# --- crash_loop_open_escalations (agent-ops#1074) ---------------------------

open_and_retired="$(cat <<<"$four_fails"
  escalated_at 2026-08-01T11:00:00Z 'coordinator exited 126' 501
  escalated_at 2026-08-05T11:00:00Z 'coordinator timed out' 502
  retired_at 2026-08-06T00:00:00Z 502)"
assert_eq "only the still-open escalation is printed" \
  "501" "$(crash_loop_open_escalations <<<"$open_and_retired" | jq -r '.issue_number')"

assert_eq "no crash-loop-escalated events at all yields nothing" \
  "" "$(crash_loop_open_escalations <<<"$four_fails")"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
