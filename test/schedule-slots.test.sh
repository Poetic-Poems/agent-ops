#!/usr/bin/env bash
#
# test/schedule-slots.test.sh — the overrun-slot skip (requirement 11a,
# agent-ops#1287): supercronic will not start a job while the previous run
# of that job is still running, and logs the drop only to a container log
# the fleet never reads. Two things are under test here:
#
#   lib/schedule-slots.sh's `schedule_overrun_slots` — a pure function
#     tested directly against fixture `schedule` blocks: given a cycle's own
#     [start, end] span, does it name exactly the slots that fell strictly
#     inside it, honouring `cycle_interval_minutes`, `excluded_minutes` and
#     `cycle_hours` (including an hour-boundary crossing, and an hour
#     `cycle_hours` excludes entirely)?
#
#   agent-cycle.sh's own cleanup-time call site — the "Overrun-slot skips"
#     block, lifted verbatim out of agent-cycle.sh the same way
#     test/finish-then-continue.test.sh lifts its own block, rather than
#     restated, so this cannot pass against a copy the script has since
#     moved on from: does it log one `cycle-skipped {reason: "overlap",
#     slot_ts, held_by, elapsed_s}` per slot `schedule_overrun_slots`
#     returns, only when `lock_acquired` is `1`, and nothing at all when it
#     is `0` (a stood-down or lock-contention cycle never blocked a firing)?
#
#   lib/manage.sh's `overlap_status_report` — the `--status` line
#     `check-nodes.sh` (external to this repository) already prints
#     `--status` per node and so inherits for free: does it count only this
#     node's own `cycle-skipped {reason: "overlap"}` events, only the last
#     24h of them, ignoring the lock-contention `cycle-skipped` shape that
#     carries no `reason` at all?
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/schedule-slots.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/schedule-slots.sh
. "$SCRIPT_DIR/lib/schedule-slots.sh"

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

# --- schedule_overrun_slots, directly ------------------------------------------

out="$(schedule_overrun_slots "2026-09-08T10:05:00Z" "2026-09-08T10:37:00Z" \
  '{"cycle_hours":"*","cycle_interval_minutes":15,"excluded_minutes":[0]}')"
assert_eq "a cycle spanning two slots names both, in order" \
  "2026-09-08T10:20:00Z
2026-09-08T10:35:00Z" "$out"

out="$(schedule_overrun_slots "2026-09-08T10:05:00Z" "2026-09-08T10:10:00Z" \
  '{"cycle_hours":"*","cycle_interval_minutes":15,"excluded_minutes":[0]}')"
assert_eq "a cycle that ends before its own next slot names none" "" "$out"

out="$(schedule_overrun_slots "2026-09-08T10:50:00Z" "2026-09-08T12:20:00Z" \
  '{"cycle_hours":"9-17","cycle_interval_minutes":30,"excluded_minutes":[0]}')"
assert_eq "a span crossing an hour boundary still finds the next hour's own slot" \
  "2026-09-08T11:50:00Z" "$out"

out="$(schedule_overrun_slots "2026-09-08T08:50:00Z" "2026-09-08T10:20:00Z" \
  '{"cycle_hours":"8,10","cycle_interval_minutes":30,"excluded_minutes":[]}')"
assert_eq "an hour cycle_hours excludes entirely contributes no slot from it" \
  "" "$out"

out="$(schedule_overrun_slots "2026-09-08T23:50:00Z" "2026-09-09T00:55:00Z" \
  '{"cycle_hours":"*","cycle_interval_minutes":15,"excluded_minutes":[]}')"
assert_eq "a span crossing midnight still names the next day's own slot (base minute :50, restarting each hour rather than carrying the interval over)" \
  "2026-09-09T00:50:00Z" "$out"

out="$(schedule_overrun_slots "not-a-timestamp" "2026-09-08T10:37:00Z" \
  '{"cycle_hours":"*","cycle_interval_minutes":15,"excluded_minutes":[]}')"
assert_eq "an unparseable start prints nothing rather than failing" "" "$out"

# --- The cleanup-time call site, extracted -------------------------------------
# From the "Overrun-slot skips" comment through the block's own closing `fi`,
# inclusive — the whole and only span this requirement added to cleanup().
extract_overrun_block() {
  awk '
    /^  # Overrun-slot skips \(requirement 11a, agent-ops#1287\)/ { on = 1 }
    on           { print }
    on && /^  fi$/ { exit }
  ' "$1"
}

block="$(extract_overrun_block "$SCRIPT_DIR/agent-cycle.sh")"
if [[ -z "$block" ]]; then
  echo "FAIL - could not extract the overrun-slot block from agent-cycle.sh — has it moved?" >&2
  failures=$(( failures + 1 ))
fi

# run_block LOCK_ACQUIRED CYCLE_STARTED_AT NOW_ISO SCHEDULE_JSON
# Assembles and runs a standalone script around the extracted block: a `date`
# override so "now" is the fixture's NOW_ISO/its epoch rather than the real
# wall clock (the block calls plain `date -u +%Y-%m-%dT...`/`+%s` for "now",
# and `date -u -d "<iso>" +%s` to parse both `cycle_started_at` and each
# `slot_ts` — the override only fixes the former; `-d` still parses for
# real, via `command date`, so it exercises the same parsing the real
# cleanup() does), and a recording `log_event`. Prints one
# "EVENT <name> <fields-json>" line per call.
run_block() {
  local lock_acquired="$1" cycle_started_at="$2" now_iso="$3" schedule_json="$4"
  local script="$tmp_dir/run-$$-$RANDOM.sh"
  {
    printf '#!/usr/bin/env bash\nset -uo pipefail\n'
    printf 'date() {\n'
    printf '  if [[ "$*" == "-u +%%Y-%%m-%%dT%%H:%%M:%%SZ" ]]; then printf %%s %q\n' "$now_iso"
    printf '  elif [[ "$*" == "-u +%%s" ]]; then printf %%s %q\n' \
      "$(command date -u -d "$now_iso" +%s)"
    printf '  else command date "$@"\n'
    printf '  fi\n}\n'
    printf 'log_event() { printf "EVENT %%s %%s\\n" "$1" "$2"; }\n'
    printf 'lock_acquired=%q\n' "$lock_acquired"
    printf 'cycle_started_at=%q\n' "$cycle_started_at"
    printf 'cycle_id=%q\n' "test-cycle-fixture"
    printf 'schedule_json=%q\n' "$schedule_json"
    printf '. %q\n' "$SCRIPT_DIR/lib/schedule-slots.sh"
    printf '%s\n' "$block"
  } > "$script"
  bash "$script" 2>/dev/null
}

out="$(run_block 1 "2026-09-08T10:05:00Z" "2026-09-08T10:37:00Z" \
  '{"cycle_hours":"*","cycle_interval_minutes":15,"excluded_minutes":[0]}')"
assert_eq "a cycle spanning two slots logs exactly two cycle-skipped events" \
  "2" "$(grep -c '^EVENT cycle-skipped ' <<<"$out")"
assert_eq "the first event names the earlier slot, reason overlap, this cycle's own id" \
  '{"reason":"overlap","slot_ts":"2026-09-08T10:20:00Z","held_by":"test-cycle-fixture","elapsed_s":900}' \
  "$(grep '^EVENT cycle-skipped ' <<<"$out" | sed -n '1p' | cut -d' ' -f3-)"
assert_eq "the second event names the later slot, with elapsed_s measured from cycle start" \
  '{"reason":"overlap","slot_ts":"2026-09-08T10:35:00Z","held_by":"test-cycle-fixture","elapsed_s":1800}' \
  "$(grep '^EVENT cycle-skipped ' <<<"$out" | sed -n '2p' | cut -d' ' -f3-)"

out="$(run_block 1 "2026-09-08T10:05:00Z" "2026-09-08T10:10:00Z" \
  '{"cycle_hours":"*","cycle_interval_minutes":15,"excluded_minutes":[0]}')"
assert_eq "a cycle that overlaps no slot logs nothing" "" "$out"

out="$(run_block 0 "2026-09-08T10:05:00Z" "2026-09-08T10:37:00Z" \
  '{"cycle_hours":"*","cycle_interval_minutes":15,"excluded_minutes":[0]}')"
assert_eq "a cycle that never acquired the lock logs nothing, however long it stood down for" \
  "" "$out"

# --- lib/manage.sh's overlap_status_report -------------------------------------

# shellcheck source=lib/manage.sh
. "$SCRIPT_DIR/lib/manage.sh"

fixture_log="$tmp_dir/overlap-status-log.jsonl"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
three_days_ago_iso="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
{
  printf '{"ts":"%s","event":"cycle-skipped","reason":"overlap","slot_ts":"a"}\n' "$now_iso"
  printf '{"ts":"%s","event":"cycle-skipped","reason":"overlap","slot_ts":"b"}\n' "$now_iso"
  # A lock-contention cycle-skipped (requirement 1's own case) carries no
  # `reason` at all — must not be mistaken for an overlap drop.
  printf '{"ts":"%s","event":"cycle-skipped","detail":"lock held by pid 1, age 5s"}\n' "$now_iso"
  # Outside the 24h window entirely: must not be counted.
  printf '{"ts":"%s","event":"cycle-skipped","reason":"overlap","slot_ts":"c"}\n' "$three_days_ago_iso"
} > "$fixture_log"
log_file="$fixture_log"
assert_eq "counts only this window's own overlap-reasoned cycle-skipped events" \
  "overrun:  2 firing(s) overrun in the last 24h" "$(overlap_status_report)"

log_file="$tmp_dir/empty-log.jsonl"
: > "$log_file"
assert_eq "an empty log reads a plain zero, not an error" \
  "overrun:  0 firing(s) overrun in the last 24h" "$(overlap_status_report)"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
