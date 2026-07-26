#!/usr/bin/env bash
#
# test/watchtower-pre-update.test.sh — the hook that makes an image roll wait.
#
# The properties that matter:
#   - a live implementation cycle defers the roll (exit 75, EX_TEMPFAIL), and
#     so does a live review — either one dying to a roll costs the same;
#   - an idle node exits 0, so a node with nothing running still updates;
#   - a lock past its pipeline's `lock_stale_after` does NOT defer. This is
#     the property that stops one wedged process freezing a node's image for
#     ever: the hook protects exactly what a cycle would have respected, and
#     a cycle would have taken that lock over;
#   - anything the hook cannot read fails *open*, because a node that quietly
#     stops updating is worse than a roll that lands badly once.
#
# Run directly: ./test/watchtower-pre-update.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$SCRIPT_DIR/deploy/docker/watchtower-pre-update.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

state_dir="$tmp_dir/state"
config="$tmp_dir/config.json"
mkdir -p "$state_dir"

jq -n --arg s "$state_dir" \
  '{state_dir: $s, lock_stale_after: 4, review: {lock_stale_after: 6}}' > "$config"

# A process that is alive for the duration of a check but owns nothing else.
sleeper_pid=""
start_sleeper() {
  sleep 300 &
  sleeper_pid=$!
}
stop_sleeper() {
  [[ -n "$sleeper_pid" ]] || return 0
  kill "$sleeper_pid" 2>/dev/null
  wait "$sleeper_pid" 2>/dev/null
  sleeper_pid=""
}

# A pid nothing holds. Searched for rather than guessed: the point of the
# assertion using it is that `kill -0` fails, so the pid must really be free.
dead_pid() {
  local p
  for (( p = $(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768) - 1; p > 300; p-- )); do
    kill -0 "$p" 2>/dev/null || { printf '%s' "$p"; return 0; }
  done
  printf '4194303'
}

write_lock() {  # write_lock FILE PID AGE_HOURS
  local f="$1" pid="$2" age_hours="$3"
  jq -n --argjson pid "$pid" \
        --arg started_at "$(date -u -d "-${age_hours} hours" +%Y-%m-%dT%H:%M:%SZ)" \
        '{pid: $pid, started_at: $started_at}' > "$f"
}

# One run, both answers: `rc` and `out` are read by the assertions below.
rc=0
out=""
run_hook() {
  out="$("$HOOK" "${1:-$config}" 2>&1)"
  rc=$?
}

# --- Idle: nothing to protect -------------------------------------------------

rm -f "$state_dir/lock.json" "$state_dir/review-lock.json"
run_hook
assert_eq "an idle node lets the update through" "0" "$rc"
assert_contains "and says so" "no cycle in flight" "$out"

# --- A live implementation cycle ----------------------------------------------

start_sleeper
write_lock "$state_dir/lock.json" "$sleeper_pid" 0
run_hook
assert_eq "a live cycle defers the roll with EX_TEMPFAIL" "75" "$rc"
assert_contains "naming the pipeline" "implementation cycle is in flight" "$out"
assert_contains "and the pid holding it" "pid $sleeper_pid" "$out"
assert_contains "and what watchtower will do next" "next poll" "$out"
stop_sleeper

# --- A live review ------------------------------------------------------------

rm -f "$state_dir/lock.json"
start_sleeper
write_lock "$state_dir/review-lock.json" "$sleeper_pid" 0
run_hook
assert_eq "a live review defers the roll too" "75" "$rc"
assert_contains "naming that pipeline" "project review is in flight" "$out"
stop_sleeper
rm -f "$state_dir/review-lock.json"

# --- The staleness bound ------------------------------------------------------
# The property that keeps a deferral bounded: past `lock_stale_after` the next
# cycle would take the lock over, so the hook stops protecting it.

start_sleeper
write_lock "$state_dir/lock.json" "$sleeper_pid" 5      # lock_stale_after: 4
run_hook
assert_eq "a live but stale cycle lock does not veto the roll" "0" "$rc"

write_lock "$state_dir/lock.json" "$sleeper_pid" 3
run_hook
assert_eq "the same lock inside the window still does" "75" "$rc"
rm -f "$state_dir/lock.json"

# The review pipeline has its own, longer window (6h), and the hook must read
# each pipeline's own value rather than one shared number.
write_lock "$state_dir/review-lock.json" "$sleeper_pid" 5
run_hook
assert_eq "5h is still fresh for the review's own 6h window" "75" "$rc"
write_lock "$state_dir/review-lock.json" "$sleeper_pid" 7
run_hook
assert_eq "7h is not" "0" "$rc"
rm -f "$state_dir/review-lock.json"
stop_sleeper

# --- A dead pid ---------------------------------------------------------------

write_lock "$state_dir/lock.json" "$(dead_pid)" 0
run_hook
assert_eq "a lock left by a process that is gone does not defer" "0" "$rc"
rm -f "$state_dir/lock.json"

# --- Junk in the lock ---------------------------------------------------------

printf 'not json at all\n' > "$state_dir/lock.json"
run_hook
assert_eq "an unreadable lock file does not defer" "0" "$rc"

jq -n '{started_at: "2026-01-01T00:00:00Z"}' > "$state_dir/lock.json"
run_hook
assert_eq "a lock with no pid does not defer" "0" "$rc"

start_sleeper
jq -n --argjson pid "$sleeper_pid" '{pid: $pid, started_at: "not a date"}' > "$state_dir/lock.json"
run_hook
assert_eq "a lock whose age cannot be read reads as stale, as acquire_lock reads it" "0" "$rc"
stop_sleeper
rm -f "$state_dir/lock.json"

# --- Failing open -------------------------------------------------------------

run_hook "$tmp_dir/no-such-config.json"
assert_eq "an unreadable config allows the update rather than freezing the node" "0" "$rc"
assert_contains "and warns that it did" "WARNING" "$out"

# --- The default config path --------------------------------------------------
# Invoked bare, as watchtower invokes it: it must find the repository's own
# config.json two directories up, without being told where it is.

out="$("$HOOK" 2>&1)"; rc=$?
assert_eq "invoked with no argument it reaches a decision" "0" "$(( rc == 0 || rc == 75 ? 0 : 1 ))"
assert_eq "rather than the fail-open path" "0" "$(grep -c 'cannot read' <<<"$out")"

# --- The label in compose.yaml points at this script --------------------------
# The hook is only ever reached through that label, so a rename that missed it
# would leave a script nothing runs.

compose="$SCRIPT_DIR/deploy/docker/compose.yaml"
assert_contains "compose labels a pre-update hook" \
  "com.centurylinklabs.watchtower.lifecycle.pre-update:" "$(cat "$compose")"
assert_contains "pointing at this script" \
  "/app/deploy/docker/watchtower-pre-update.sh" "$(cat "$compose")"
assert_contains "with lifecycle hooks enabled on watchtower" \
  "WATCHTOWER_LIFECYCLE_HOOKS" "$(cat "$compose")"
assert_eq "and the script is executable, since the label execs it" \
  "1" "$([[ -x "$HOOK" ]] && echo 1 || echo 0)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
