#!/usr/bin/env bash
#
# test/crash-loop-escalate.test.sh — the requirement-2.7 crash-loop wiring in
# lib/enabler.sh that actually files, defers and retires escalations
# (agent-ops#1074), as opposed to test/crash-loop.test.sh's coverage of the
# pure detectors in lib/crash-loop.sh those functions call.
#
# What this guards: the 2026-08-29/30 Ockham outage (agent-ops#1070) showed
# that a *retried* escalation attempt — one a previous cycle already tried
# and failed to file — must never be filed straight off a verdict computed
# before this cycle's own Co-Ordinator has had its chance to prove the run
# over. `crash_loop_escalate_or_defer` is where that distinction is made;
# `crash_loop_refile_pending` (run from `cleanup()`, after every stage this
# cycle might run) is where a deferred attempt is finally re-verified and
# either filed or dropped; `crash_loop_retire_resolved` is the other half —
# closing an already-open escalation once its run has broken.
#
# Everything with a side effect outside the process — `gh`, GitHub issue
# creation — is stubbed. `log_event` is replaced with a tiny recorder so
# assertions can inspect exactly which events these functions emit, without
# needing agent-cycle.sh's own logging plumbing (`$log_file`, `$cycle_id`,
# `$node_name`) along for the ride. `lib/fleet.sh`'s real `fleet_logs` runs
# unstubbed against real temp files, since `crash_loop_refile_pending`'s
# whole point is regathering the union log for real.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/crash-loop-escalate.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/crash-loop.sh
. "$SCRIPT_DIR/lib/crash-loop.sh"
# shellcheck source=lib/rework.sh
. "$SCRIPT_DIR/lib/rework.sh"
# shellcheck source=lib/enabler.sh
. "$SCRIPT_DIR/lib/enabler.sh"

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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR" "${STUB_CREATE_CALLS_FILE:-}"' EXIT

# --- Test doubles ------------------------------------------------------------
# log_event: replaces agent-cycle.sh's real one (which needs $log_file,
# $cycle_id, $node_name) with a recorder assertions can inspect directly.
EVENTS=()
log_event() {
  EVENTS+=("$(jq -nc --arg e "$1" --argjson f "${2:-{\}}" '{event: $e} + $f')")
}
events_of() {  # events_of EVENT_NAME — one JSON object per line
  local e
  for e in "${EVENTS[@]}"; do
    jq -e --arg n "$1" '.event == $n' <<<"$e" >/dev/null 2>&1 && printf '%s\n' "$e"
  done
}

# create_escalation_issue: the real one needs `gh`/network; this stub is
# driven by STUB_CREATE_MODE ("success" or "fail"). Every real call site
# invokes it as `cl_created="$(create_escalation_issue ...)"` — a command
# substitution, which runs in a subshell — so call counting goes through a
# file, not a plain variable: a variable this function set would vanish with
# the subshell the moment the substitution finished.
STUB_CREATE_MODE="success"
STUB_CREATE_CALLS_FILE="$(mktemp)"
stub_create_calls_reset() { : > "$STUB_CREATE_CALLS_FILE"; }
stub_create_calls() { wc -l < "$STUB_CREATE_CALLS_FILE" | tr -d ' '; }
create_escalation_issue() {
  printf 'x\n' >> "$STUB_CREATE_CALLS_FILE"
  if [[ "$STUB_CREATE_MODE" == "success" ]]; then
    printf '999\thttps://github.com/o/r/issues/999'
    return 0
  fi
  return 1
}

# gh: only `gh issue close` is exercised here (crash_loop_retire_resolved).
STUB_GH_CLOSE_MODE="success"
STUB_GH_CLOSE_CALLS=0
STUB_GH_CLOSE_LAST_BODY=""
gh() {
  if [[ "$1" == "issue" && "$2" == "close" ]]; then
    STUB_GH_CLOSE_CALLS=$(( STUB_GH_CLOSE_CALLS + 1 ))
    # --comment is always the last flag this codebase passes it as.
    STUB_GH_CLOSE_LAST_BODY="${*: -1}"
    [[ "$STUB_GH_CLOSE_MODE" == "success" ]]
    return $?
  fi
  return 1
}

# Cycle-scoped globals the functions under test read directly.
cycle_dir="$WORKDIR/cycle"
mkdir -p "$cycle_dir"
crash_loop_repo="o/r"
enabler_escalation_label="enabler-escalation"
crash_loop_after=4
state_dir="$WORKDIR/state"
peers_dir="$WORKDIR/peers"
mkdir -p "$state_dir" "$peers_dir"

fail_at() { jq -nc --arg ts "$1" --arg node "$2" --arg d "$3" '{ts: $ts, node: $node, event: "attempt-failed", stage: "coordinator", detail: $d}'; }
success_at() { jq -nc --arg ts "$1" --arg node "$2" '{ts: $ts, node: $node, event: "stage-end", stage: "coordinator", exit_code: 0}'; }

four_fails="$(fail_at 2026-08-01T10:00:00Z n1 'coordinator exited 126'
  fail_at 2026-08-01T10:15:00Z n1 'coordinator exited 126'
  fail_at 2026-08-01T10:30:00Z n1 'coordinator exited 126'
  fail_at 2026-08-01T10:45:00Z n1 'coordinator exited 126')"
verdict="$(crash_loop_verdict 4 <<<"$four_fails")"

# --- crash_loop_escalate: return code carries filing outcome ---------------

union_log="$WORKDIR/union-empty.jsonl"
: > "$union_log"
STUB_CREATE_MODE="success"; stub_create_calls_reset; EVENTS=()
if crash_loop_escalate "$verdict" "crash-loop:coordinator" "failures" "title" "evidence"; then
  printf 'ok   - a successful filing returns success\n'
else
  printf 'FAIL - a successful filing should return success\n'; failures=$(( failures + 1 ))
fi
assert_eq "a successful filing logs crash-loop-escalated" "1" "$(events_of crash-loop-escalated | wc -l | tr -d ' ')"
assert_eq "a successful filing logs no crash-loop-deferred" "0" "$(events_of crash-loop-deferred | wc -l | tr -d ' ')"

STUB_CREATE_MODE="fail"; stub_create_calls_reset; EVENTS=()
if crash_loop_escalate "$verdict" "crash-loop:coordinator" "failures" "title" "evidence"; then
  printf 'FAIL - a failed filing should return failure\n'; failures=$(( failures + 1 ))
else
  printf 'ok   - a failed filing returns failure\n'
fi
assert_eq "a failed filing logs crash-loop-deferred, structured with the run's own detail" \
  "coordinator exited 126" "$(events_of crash-loop-deferred | jq -r '.detail')"
assert_eq "a failed filing carries the run's own first_ts" \
  "$(jq -r '.first_ts' <<<"$verdict")" "$(events_of crash-loop-deferred | jq -r '.first_ts')"

# --- crash_loop_escalate_or_defer: fresh vs. retry --------------------------

union_log="$WORKDIR/union-fresh.jsonl"
printf '%s\n' "$four_fails" > "$union_log"
STUB_CREATE_MODE="success"; stub_create_calls_reset; EVENTS=(); crash_loop_pending_refile=()
crash_loop_escalate_or_defer "$verdict" "crash-loop:coordinator" "failures" "title" "evidence"
assert_eq "a fresh verdict files immediately (create_escalation_issue called)" "1" "$(stub_create_calls)"
assert_eq "a fresh, successfully-filed verdict queues nothing for later" "0" "${#crash_loop_pending_refile[@]}"

union_log="$WORKDIR/union-fresh2.jsonl"
printf '%s\n' "$four_fails" > "$union_log"
STUB_CREATE_MODE="fail"; stub_create_calls_reset; EVENTS=(); crash_loop_pending_refile=()
crash_loop_escalate_or_defer "$verdict" "crash-loop:coordinator" "failures" "title" "evidence"
assert_eq "a fresh verdict that fails to file still attempted immediately" "1" "$(stub_create_calls)"
assert_eq "and is queued for a same-cycle late recheck rather than waiting a full cycle" \
  "1" "${#crash_loop_pending_refile[@]}"

deferred_marker="$(jq -nc --arg ts "$(jq -r '.first_ts' <<<"$verdict")" --arg d "$(jq -r '.detail' <<<"$verdict")" \
  '{ts: ($ts), node: "n1", event: "crash-loop-deferred", stage: "coordinator", detail: $d}')"
union_log="$WORKDIR/union-retry.jsonl"
printf '%s\n%s\n' "$four_fails" "$deferred_marker" > "$union_log"
STUB_CREATE_MODE="success"; stub_create_calls_reset; EVENTS=(); crash_loop_pending_refile=()
crash_loop_escalate_or_defer "$verdict" "crash-loop:coordinator" "failures" "title" "evidence"
assert_eq "a retried run (a prior crash-loop-deferred exists) is never filed at this early point" \
  "0" "$(stub_create_calls)"
assert_eq "and is queued for the late recheck instead" "1" "${#crash_loop_pending_refile[@]}"

escalated_marker="$(jq -nc --arg ts "$(jq -r '.first_ts' <<<"$verdict")" --arg d "$(jq -r '.detail' <<<"$verdict")" \
  '{ts: ($ts), node: "n1", event: "crash-loop-escalated", stage: "coordinator", detail: $d}')"
union_log="$WORKDIR/union-already.jsonl"
printf '%s\n%s\n' "$four_fails" "$escalated_marker" > "$union_log"
STUB_CREATE_MODE="success"; stub_create_calls_reset; EVENTS=(); crash_loop_pending_refile=()
crash_loop_escalate_or_defer "$verdict" "crash-loop:coordinator" "failures" "title" "evidence"
assert_eq "an already-escalated run is never re-filed or re-queued" "0" "$(stub_create_calls)"
assert_eq "and queues nothing for later either" "0" "${#crash_loop_pending_refile[@]}"

# --- crash_loop_refile_pending: the Ockham replay, end to end --------------
#
# `crash_loop_escalate`'s own dedup still reads the step-1b `$union_log`, not
# the fresh regather `crash_loop_refile_pending` builds for `crash_loop_
# reverify` — a plain, never-escalated file, so it never confuses this
# section's own filing attempts with the dedup coverage the earlier sections
# already exercised.
union_log="$WORKDIR/union-refile.jsonl"
printf '%s\n' "$four_fails" > "$union_log"
#
# The retry cycle's own step 1b queued this verdict (network was back enough
# to detect the run, not yet proven enough to know the Co-Ordinator would
# succeed). Its own Co-Ordinator attempt then runs and succeeds, logged to
# this node's own $state_dir/log.jsonl exactly as `log_event` would — and
# `crash_loop_refile_pending` must see that when it regathers, not the stale
# snapshot `union_log` still holds.
printf '%s\n' "$four_fails" > "$state_dir/log.jsonl"
crash_loop_pending_refile=("$(jq -nc --arg ref "crash-loop:coordinator" --arg kl "failures" \
  --arg tp "title" --arg ev "evidence" --argjson v "$verdict" \
  '{item_ref: $ref, kind_label: $kl, title_prefix: $tp, evidence_line: $ev, verdict: $v}')")
success_at 2026-08-30T02:21:30Z n1 >> "$state_dir/log.jsonl"
STUB_CREATE_MODE="success"; stub_create_calls_reset; EVENTS=()
crash_loop_refile_pending
assert_eq "a run broken by this cycle's own now-logged success is never filed" "0" "$(stub_create_calls)"
assert_eq "and the drop is recorded, naming the run's own detail" \
  "coordinator exited 126" "$(events_of crash-loop-dropped | jq -r '.detail')"
assert_eq "replaying the Ockham sequence end to end files no escalation" \
  "0" "$(events_of crash-loop-escalated | wc -l | tr -d ' ')"

# The counterfactual: no success landed. The same queued retry, re-verified,
# is still active and gets filed now.
printf '%s\n' "$four_fails" > "$state_dir/log.jsonl"
crash_loop_pending_refile=("$(jq -nc --arg ref "crash-loop:coordinator" --arg kl "failures" \
  --arg tp "title" --arg ev "evidence" --argjson v "$verdict" \
  '{item_ref: $ref, kind_label: $kl, title_prefix: $tp, evidence_line: $ev, verdict: $v}')")
STUB_CREATE_MODE="success"; stub_create_calls_reset; EVENTS=()
crash_loop_refile_pending
assert_eq "a still-active retry is filed at the late recheck" "1" "$(stub_create_calls)"
assert_eq "and logged the same as any other escalation" "1" "$(events_of crash-loop-escalated | wc -l | tr -d ' ')"

# An unreadable/empty regather must never read as recovery.
crash_loop_pending_refile=("$(jq -nc --arg ref "crash-loop:coordinator" --arg kl "failures" \
  --arg tp "title" --arg ev "evidence" --argjson v "$verdict" \
  '{item_ref: $ref, kind_label: $kl, title_prefix: $tp, evidence_line: $ev, verdict: $v}')")
: > "$state_dir/log.jsonl"
rm -f "$peers_dir"/*/log.jsonl 2>/dev/null || true
STUB_CREATE_MODE="success"; stub_create_calls_reset; EVENTS=()
crash_loop_refile_pending
assert_eq "an unreadable/empty regather files anyway rather than silently dropping" \
  "1" "$(stub_create_calls)"

# --- crash_loop_retire_resolved ---------------------------------------------

union_log="$WORKDIR/union-retire.jsonl"
cat <<<"$four_fails" > "$union_log"
escalated_marker_501="$(jq -nc --arg ts "$(jq -r '.first_ts' <<<"$verdict")" --arg d "$(jq -r '.detail' <<<"$verdict")" \
  '{ts: $ts, node: "n1", event: "crash-loop-escalated", stage: "coordinator", detail: $d, first_ts: $ts, issue_number: 501, issue_url: "https://github.com/o/r/issues/501"}')"
printf '%s\n' "$escalated_marker_501" >> "$union_log"
success_at 2026-08-01T12:00:00Z n2 >> "$union_log"
STUB_GH_CLOSE_MODE="success"; STUB_GH_CLOSE_CALLS=0; EVENTS=()
crash_loop_retire_resolved
assert_eq "an open escalation whose run has broken is closed" "1" "$STUB_GH_CLOSE_CALLS"
assert_eq "the close comment names the success that cleared it" "1" \
  "$(grep -c '2026-08-01T12:00:00Z' <<<"$STUB_GH_CLOSE_LAST_BODY")"
assert_eq "retirement is logged" "1" "$(events_of crash-loop-retired | wc -l | tr -d ' ')"

union_log="$WORKDIR/union-still-open.jsonl"
cat <<<"$four_fails" > "$union_log"
printf '%s\n' "$escalated_marker_501" >> "$union_log"
STUB_GH_CLOSE_MODE="success"; STUB_GH_CLOSE_CALLS=0; EVENTS=()
crash_loop_retire_resolved
assert_eq "an open escalation whose run is still active is never closed" "0" "$STUB_GH_CLOSE_CALLS"
assert_eq "and nothing is logged for it" "0" "$(events_of crash-loop-retired | wc -l | tr -d ' ')"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
