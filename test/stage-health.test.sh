#!/usr/bin/env bash
#
# test/stage-health.test.sh — lib/stage-health.sh computes, per stage on this
# node, whether its most recent run of attempts is succeeding (issue #662).
#
# What this guards: during the 2026-08-21 incident every stage in every
# node's cycles failed for 10.5 hours, yet `agent-cycle.sh --status` reported
# "cycle: RUNNING", no `check-node-*.sh` complained, and the dashboard stayed
# green — because none of them read `stage-end`'s own `exit_code`. These are
# `stage_health_verdicts`' properties, each of which silently restores that
# blind spot if lost:
#
#   one failure is not a verdict   normal transients exist; only a
#                                  consecutive run reaching THRESHOLD reads
#                                  as `failing`
#   a success resets the streak    consecutive_failures returns to 0, and
#                                  last_detail clears with it — the streak's
#                                  detail is not a permanent scar
#   never-run reads idle, not ok   a stage with no `stage-end` at all (e.g. a
#                                  Reviewer this node has never had a PR for)
#                                  must never look "healthy" the way a stage
#                                  that is actually succeeding does
#   stale success reads idle too   a stage that succeeded once, long ago, and
#                                  has had no work since is "nothing to
#                                  report", not "still fine as of last week"
#   per-stage isolation            one stage's failures never touch another's
#                                  verdict
#
# No network: `stage_health_verdicts` is a pure reader of an event stream on
# stdin, the same idiom lib/crash-loop.sh's own tests already exercise.
#
# Run directly: ./test/stage-health.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/stage-health.sh
. "$SCRIPT_DIR/lib/stage-health.sh"

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
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual: %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# Event constructors, so the cases below read as timelines rather than JSON.
stage_end_at() {  # stage_end_at TS STAGE EXIT_CODE
  jq -nc --arg ts "$1" --arg stage "$2" --argjson rc "$3" \
    '{ts: $ts, node: "n1", event: "stage-end", stage: $stage, exit_code: $rc}'
}
attempt_failed_at() {  # attempt_failed_at TS STAGE DETAIL
  jq -nc --arg ts "$1" --arg stage "$2" --arg d "$3" \
    '{ts: $ts, node: "n1", event: "attempt-failed", stage: $stage, detail: $d}'
}
epoch_of() { jq -nr --arg t "$1" '$t | fromdateiso8601'; }

NOW="2026-08-21T12:00:00Z"
NOW_EPOCH="$(epoch_of "$NOW")"

# --- shape: every stage is always present, even with no events at all ------

empty_verdicts="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"")"
assert_eq "an empty stream still names every known stage" \
  '["approver","approver-adjudicate-open-question","coordinator","enabler","enabler-adjudicate","implementer","refiner","reviewer"]' \
  "$(jq -cS 'keys' <<<"$empty_verdicts")"

# --- the stage list tracks the pipeline's own source, not a snapshot of it --
#
# A stage the Script logs a `stage-end` for but `stage_names` does not name is
# invisible everywhere this feature reports — absent from `--status`, from the
# dashboard panel and from the heartbeat, not even `idle` — which is the exact
# blind spot #662 exists to close, restored for that one stage and silent
# about it. That is not hypothetical: `approver-adjudicate-open-question`
# (#776) landed while this branch was open and was missed until review. So the
# list is asserted against the literals the pipeline's own shell files
# actually log rather than against a copy of itself. #771 split the
# `stage-end` call sites out of agent-cycle.sh into per-stage lib/*.sh
# modules (lib/stage-attempt.sh for coordinator, lib/approver.sh,
# lib/refinement.sh, lib/enabler.sh, lib/landing.sh), so every one of those is
# read alongside agent-cycle.sh itself, which still logs implementer and
# reviewer directly. `workspace` is deliberately not among them: it logs
# `attempt-failed` only, never a `stage-end`, so it would read `idle` for
# ever.
logged_stages="$(grep -ohE 'stage: "[a-z-]+", exit_code' \
    "$SCRIPT_DIR/agent-cycle.sh" "$SCRIPT_DIR"/lib/*.sh \
  | grep -oE '"[a-z-]+"' | tr -d '"' | jq -Rnc '[inputs] | unique' 2>/dev/null \
  || true)"
if [[ -z "$logged_stages" || "$logged_stages" == "[]" ]]; then
  printf 'FAIL - could not read the stage-end literals out of the pipeline'"'"'s source — has the shape moved?\n'
  failures=$(( failures + 1 ))
else
  assert_eq "every stage agent-cycle.sh logs a stage-end for is one this reader names" \
    "$logged_stages" "$(jq -cS 'keys' <<<"$empty_verdicts")"
fi
assert_eq "a stage with no events at all reads idle" \
  "idle" "$(jq -r '.coordinator.verdict' <<<"$empty_verdicts")"
assert_eq "and its last_success is null" \
  "null" "$(jq -c '.coordinator.last_success' <<<"$empty_verdicts")"

# --- one failure does not trigger a verdict ---------------------------------

one_fail="$(attempt_failed_at 2026-08-21T09:00:00Z coordinator 'coordinator exited 1'
  stage_end_at 2026-08-21T09:00:00Z coordinator 1)"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$one_fail")"
assert_eq "a single failure below threshold reads ok, not failing" \
  "ok" "$(jq -r '.coordinator.verdict' <<<"$verdict")"
assert_eq "its consecutive_failures is 1" \
  "1" "$(jq -r '.coordinator.consecutive_failures' <<<"$verdict")"
assert_eq "last_detail is still recorded, even below the failing threshold" \
  "coordinator exited 1" "$(jq -r '.coordinator.last_detail' <<<"$verdict")"

# --- threshold-many consecutive failures read as failing --------------------

three_fails="$(attempt_failed_at 2026-08-21T09:00:00Z coordinator 'coordinator exited 1'
  stage_end_at 2026-08-21T09:00:00Z coordinator 1
  attempt_failed_at 2026-08-21T10:00:00Z coordinator 'coordinator timed out'
  stage_end_at 2026-08-21T10:00:00Z coordinator 124
  attempt_failed_at 2026-08-21T11:00:00Z coordinator 'coordinator was refused by the API'
  stage_end_at 2026-08-21T11:00:00Z coordinator 1)"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$three_fails")"
assert_eq "three consecutive failures at threshold 3 read failing" \
  "failing" "$(jq -r '.coordinator.verdict' <<<"$verdict")"
assert_eq "consecutive_failures counts all three" \
  "3" "$(jq -r '.coordinator.consecutive_failures' <<<"$verdict")"
assert_eq "last_detail is the most recent failure's own detail" \
  "coordinator was refused by the API" "$(jq -r '.coordinator.last_detail' <<<"$verdict")"
assert_eq "last_success is still null — none of the three succeeded" \
  "null" "$(jq -c '.coordinator.last_success' <<<"$verdict")"

verdict2="$(stage_health_verdicts 2 48 "$NOW_EPOCH" <<<"$three_fails")"
assert_eq "the same stream at threshold 2 also reads failing" \
  "failing" "$(jq -r '.coordinator.verdict' <<<"$verdict2")"

# --- a success resets the streak --------------------------------------------

recovered="$(cat <<<"$three_fails"
  stage_end_at 2026-08-21T11:55:00Z coordinator 0)"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$recovered")"
assert_eq "a success after three failures clears the streak" \
  "ok" "$(jq -r '.coordinator.verdict' <<<"$verdict")"
assert_eq "consecutive_failures returns to 0" \
  "0" "$(jq -r '.coordinator.consecutive_failures' <<<"$verdict")"
assert_eq "last_detail clears with it" \
  "null" "$(jq -c '.coordinator.last_detail' <<<"$verdict")"
assert_eq "last_success is the success's own timestamp" \
  "2026-08-21T11:55:00Z" "$(jq -r '.coordinator.last_success' <<<"$verdict")"

# --- a stale success reads idle, not ok, once nothing has failed since -----

stale_success="$(stage_end_at 2026-01-01T00:00:00Z reviewer 0)"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$stale_success")"
assert_eq "a success from months ago, nothing since, reads idle" \
  "idle" "$(jq -r '.reviewer.verdict' <<<"$verdict")"
assert_eq "but its last_success is preserved, not null" \
  "2026-01-01T00:00:00Z" "$(jq -r '.reviewer.last_success' <<<"$verdict")"

fresh_success="$(stage_end_at 2026-08-21T11:00:00Z reviewer 0)"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$fresh_success")"
assert_eq "a success one hour ago, well inside the idle window, reads ok" \
  "ok" "$(jq -r '.reviewer.verdict' <<<"$verdict")"

# ... but "nothing since" is the whole of what makes a stale success idle. A
# stage whose last success is old *and* which has failed since has had work,
# and it went wrong: calling that "idle" reports "nothing to report" over a
# stage that is actively failing — below THRESHOLD, so not yet `failing`, but
# `ok` at worst, never the grey "no recent work" badge. The failures are also
# what `--status` and the dashboard would otherwise omit entirely from that
# row.
stale_then_failed="$(stage_end_at 2026-01-01T00:00:00Z reviewer 0
  attempt_failed_at 2026-08-21T10:00:00Z reviewer 'reviewer exited 1'
  stage_end_at 2026-08-21T10:00:00Z reviewer 1
  attempt_failed_at 2026-08-21T11:00:00Z reviewer 'reviewer exited 1'
  stage_end_at 2026-08-21T11:00:00Z reviewer 1)"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$stale_then_failed")"
assert_eq "a stale success with failures since is not idle" \
  "ok" "$(jq -r '.reviewer.verdict' <<<"$verdict")"
assert_eq "  ... and those failures are still counted, not hidden by the stale success" \
  "2" "$(jq -r '.reviewer.consecutive_failures' <<<"$verdict")"
assert_eq "  ... reaching THRESHOLD makes it failing, never idle" \
  "failing" "$(jq -r '.reviewer.verdict' \
    <<<"$(stage_health_verdicts 2 48 "$NOW_EPOCH" <<<"$stale_then_failed")")"

# --- per-stage isolation -----------------------------------------------------

mixed="$(cat <<<"$three_fails"
  stage_end_at 2026-08-21T11:00:00Z implementer 0)"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$mixed")"
assert_eq "coordinator's failure streak does not touch implementer" \
  "ok" "$(jq -r '.implementer.verdict' <<<"$verdict")"
assert_eq "and implementer never invoked stays idle" \
  "idle" "$(jq -r '.enabler.verdict' <<<"$verdict")"

# --- unrelated events and torn lines are ignored, not counted --------------

noise="$(jq -nc '{ts:"2026-08-21T09:30:00Z", node:"n1", event:"warning", detail:"unrelated"}'
  cat <<<"$three_fails")"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$noise")"
assert_eq "an unrelated event type never contributes to the streak" \
  "3" "$(jq -r '.coordinator.consecutive_failures' <<<"$verdict")"

torn="$(head -n1 <<<"$three_fails"
  printf '{"ts": "2026-08-21T09:3'
  printf '\n'
  tail -n +2 <<<"$three_fails")"
verdict="$(stage_health_verdicts 3 48 "$NOW_EPOCH" <<<"$torn")"
assert_eq "a torn line is skipped, not miscounted" \
  "3" "$(jq -r '.coordinator.consecutive_failures' <<<"$verdict")"

# --- stage_health_write_status: atomic write, doctor.sh's own precedent ----

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
log_file="$scratch/log.jsonl"
printf '%s\n' "$three_fails" > "$log_file"

stage_health_write_status "$scratch" "$log_file" 3 48 "$NOW_EPOCH"
status_file="$scratch/.stage-health.json"
assert_eq "stage_health_write_status writes .stage-health.json" "1" \
  "$( [[ -f "$status_file" ]] && echo 1 || echo 0 )"
assert_eq "the written file's threshold matches what it was called with" \
  "3" "$(jq -r '.threshold' "$status_file")"
assert_eq "and carries the same coordinator verdict just computed directly" \
  "failing" "$(jq -r '.stages.coordinator.verdict' "$status_file")"
assert_contains "computed_at looks like a real UTC instant" \
  "$(jq -r '.computed_at' "$status_file")" "T"

assert_eq "an unwritable state_dir is a silent no-op, not a failure" "0" \
  "$(stage_health_write_status "$scratch/does-not-exist" "$log_file" 3 48 "$NOW_EPOCH"; echo $?)"

# --- stage_health_status_lines: the --status `stages:` block's own body ----

lines="$(stage_health_status_lines "$status_file" "$NOW_EPOCH")"
assert_contains "the failing stage's line names the consecutive count" \
  "$lines" "coordinator failing (3 consecutive"
assert_contains "an idle-never-run stage says so plainly" \
  "$lines" "enabler idle (never run)"

missing_status="$scratch/does-not-exist.json"
assert_contains "a missing status file explains itself rather than printing nothing" \
  "$(stage_health_status_lines "$missing_status" "$NOW_EPOCH")" "no data yet"

# --- stage_health_status_report: the --status wiring itself ----------------
#
# The acceptance bar for #662 is not that the library can render a block, but
# that `agent-cycle.sh --status` prints one — and the two are joined by three
# lines in lib/manage.sh (#771 moved the whole management-command block out of
# agent-cycle.sh) that nothing else exercises: the `stages:` header, and the
# `$state_dir/.stage-health.json` path the reporter reads. A typo in either
# restores the original blind spot in the exact place the issue was filed
# about, while every assertion above still passes. So the block is lifted
# verbatim out of lib/manage.sh (the same `extract` pattern
# test/merge-autonomy.test.sh and test/approver-wiring.test.sh use) rather
# than reimplemented here.

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' \
    "$SCRIPT_DIR/lib/manage.sh"
}
report_block="$(extract stage_health_status_report)"
if [[ -z "$report_block" || "$report_block" != *"stage_health_status_lines"* ]]; then
  printf 'FAIL - could not extract stage_health_status_report from lib/manage.sh — has it moved?\n'
  failures=$(( failures + 1 ))
else
  eval "$report_block"

  # $status_file above was written by stage_health_write_status into
  # $scratch, under the name the reporter looks for, so pointing state_dir at
  # that directory is the same join the shipped --status makes.
  state_dir="$(dirname "$status_file")"
  report="$(stage_health_status_report)"
  assert_eq "the reporter opens with the stages: header --status is specified to print" \
    "stages:" "$(head -1 <<<"$report")"
  assert_contains "  ... over the verdicts written to state_dir/.stage-health.json" \
    "$report" "coordinator failing (3 consecutive"

  # A node that has not completed a cycle since upgrading: the header still
  # prints, so --status never goes quiet on a question it was just asked.
  state_dir="$scratch/no-status-yet"
  mkdir -p "$state_dir"
  report="$(stage_health_status_report)"
  assert_eq "a node with no snapshot yet still prints the header" \
    "stages:" "$(head -1 <<<"$report")"
  assert_contains "  ... and says so rather than printing an empty section" \
    "$report" "no data yet"
fi

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
