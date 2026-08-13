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
# reaching a selection-path stage (`coordinator`, `implementor`, `reviewer`)
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
success_at() {  # success_at TS NODE
  jq -nc --arg ts "$1" --arg node "$2" \
    '{ts: $ts, node: $node, event: "stage-end", stage: "coordinator", exit_code: 0}'
}
escalated_at() {  # escalated_at TS DETAIL
  jq -nc --arg ts "$1" --arg d "$2" \
    '{ts: $ts, node: "n1", event: "crash-loop-escalated", stage: "coordinator", detail: $d}'
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
assert_eq "threshold-many identical failures yield a verdict" \
  '{"stage":"coordinator","detail":"coordinator exited 126","count":4,"first_ts":"2026-08-01T10:00:00Z","last_ts":"2026-08-01T10:45:00Z","nodes":["n1","n2","n3","n4"]}' \
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

noise="$(fail_at 2026-08-01T10:05:00Z n1 'implementor exited 1' | jq -c '.stage = "implementor"'
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

preselection_noise="$(fail_at 2026-08-01T10:05:00Z n1 'implementor exited 1' | jq -c '.stage = "implementor"'
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

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
