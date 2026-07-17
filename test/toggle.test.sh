#!/usr/bin/env bash
#
# test/toggle.test.sh — regression test for lib/toggle.sh.
#
# The switch has one job (stop cycles starting) and one way to fail badly: to
# resolve toward "enabled" when it shouldn't, or to stay "disabled" when
# nothing will ever clear it. Both are silent. The assertions below are almost
# all about those two directions rather than about the happy path:
#
#   - an unreadable or half-written record must read as disabled, not enabled;
#   - an unparseable `expires_at` must not expire;
#   - a TTL typo must be an error, not a guess in either direction;
#   - `--enable` on an already-enabled pipeline is a normal outcome and must
#     not return non-zero, because every call site is `x="$(toggle_clear …)"`
#     under `set -e` (the trap in the Gotchas table).
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/toggle.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"

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

state_dir="$tmp_dir/state"
mkdir -p "$state_dir"

# A pinned clock: 2026-07-17T12:00:00Z. Expiry is the feature most worth
# testing and the least testable by waiting.
export TOGGLE_NOW_EPOCH=1784289600

state_of() { jq -r '.state' <<<"$(toggle_state "$state_dir")"; }

# --- No switch ---

assert_eq "no record reads as enabled" "enabled" "$(state_of)"

# The call-site shape, under `set -e`, in a subshell: the absence of a switch is
# the normal case, and a non-zero here would kill every cycle at line one.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/toggle.sh"
  s="$(toggle_state "$state_dir")"
  r="$(toggle_clear "$state_dir")"
  printf '%s%s' "$s" "$r" >/dev/null
  exit 0
) >/dev/null 2>&1
assert_eq "an absent switch does not abort its caller under set -e" "0" "$?"

assert_eq "clearing an unset switch is silent, not an error" "" "$(toggle_clear "$state_dir")"

# --- toggle_parse_ttl ---

assert_eq "a bare number means hours" "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "4" 9)"
assert_eq "hours" "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "4h" 9)"
assert_eq "minutes" "2026-07-17T13:30:00Z" "$(toggle_parse_ttl "90m" 9)"
assert_eq "days" "2026-07-19T12:00:00Z" "$(toggle_parse_ttl "2d" 9)"
assert_eq "an empty spec falls back to the configured default" \
  "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "" 4)"
assert_eq "forever has no expiry" "" "$(toggle_parse_ttl "forever" 4)"
assert_eq "never is a synonym for forever" "" "$(toggle_parse_ttl "never" 4)"

# A typo must not silently become either 4 hours or forever: one resumes the
# pipeline while an agent is still editing, the other never resumes it.
toggle_parse_ttl "4hours" 4 >/dev/null 2>&1
assert_eq "an unparseable duration is an error, not a default" "64" "$?"
toggle_parse_ttl "0" 4 >/dev/null 2>&1
assert_eq "a zero duration is an error, not an indefinite disable" "64" "$?"

# --- Setting and reading the switch ---

record="$(toggle_disable "$state_dir" "editing lib/toggle.sh" "2h" 4 "tester pid 1")"
assert_eq "disable writes the reason" "editing lib/toggle.sh" "$(jq -r '.reason' <<<"$record")"
assert_eq "disable stamps the expiry from the spec" \
  "2026-07-17T14:00:00Z" "$(jq -r '.expires_at' <<<"$record")"
assert_eq "disable records who set it" "tester pid 1" "$(jq -r '.by' <<<"$record")"
assert_eq "a set switch reads as disabled" "disabled" "$(state_of)"

# --- Expiry ---

TOGGLE_NOW_EPOCH=$(( 1784289600 + 7199 ))   # one second before the TTL
assert_eq "a switch one second short of its TTL is still disabled" "disabled" "$(state_of)"
TOGGLE_NOW_EPOCH=$(( 1784289600 + 7200 ))   # exactly at the TTL
assert_eq "a switch at its TTL has expired" "expired" "$(state_of)"
TOGGLE_NOW_EPOCH=1784289600

# The reason the TTL exists at all: an agent that disables the pipeline and
# then dies leaves this file behind, and nothing else would ever clear it.
assert_eq "an expired switch still carries its record, so the log can say what expired" \
  "editing lib/toggle.sh" \
  "$(TOGGLE_NOW_EPOCH=$(( 1784289600 + 7200 )) toggle_state "$state_dir" | jq -r '.record.reason')"

cleared="$(toggle_clear "$state_dir")"
assert_eq "clearing returns the record it removed" "editing lib/toggle.sh" "$(jq -r '.reason' <<<"$cleared")"
assert_eq "a cleared switch reads as enabled" "enabled" "$(state_of)"

# --- forever ---

toggle_disable "$state_dir" "long maintenance" "forever" 4 "tester" >/dev/null
assert_eq "an indefinite switch stores a null expiry" "null" \
  "$(jq -r '.expires_at' "$(toggle_file "$state_dir")")"
assert_eq "an indefinite switch does not expire, ever" "disabled" \
  "$(TOGGLE_NOW_EPOCH=$(( 1784289600 + 86400 * 365 )) toggle_state "$state_dir" | jq -r '.state')"
toggle_clear "$state_dir" >/dev/null

# --- Everything ambiguous resolves toward disabled ---

# A half-written record. The file exists because something meant to stop the
# pipeline; reading "enabled" out of a truncated write would run the very cycle
# the switch was set to prevent.
printf '{"disabled_at": "2026-07-17T09:00:00Z", "rea' > "$(toggle_file "$state_dir")"
assert_eq "an unreadable record reads as disabled, not enabled" "disabled" "$(state_of)"
assert_eq "an unreadable record still describes itself to the operator" \
  "0" "$([[ -n "$(toggle_describe "$(toggle_state "$state_dir" | jq -c '.record')")" ]] && echo 0 || echo 1)"
rm -f "$(toggle_file "$state_dir")"

# An expiry that doesn't parse has no expiry — it must not be treated as long
# past and cleared on the next tick.
jq -n '{disabled_at: "2026-07-17T09:00:00Z", expires_at: "next tuesday-ish", by: "t", reason: "r"}' \
  > "$(toggle_file "$state_dir")"
assert_eq "an unparseable expiry does not expire the switch" "disabled" "$(state_of)"
rm -f "$(toggle_file "$state_dir")"

# A failed disable must leave no switch: an operator told "that didn't work"
# who is nonetheless disabled has been lied to in the more dangerous direction.
toggle_disable "$state_dir" "reason" "banana" 4 "tester" >/dev/null 2>&1
assert_eq "a disable with an unparseable duration fails" "64" "$?"
assert_eq "a failed disable writes no switch" "enabled" "$(state_of)"

# --- toggle_lock_held ---

lock="$tmp_dir/lock.json"
assert_eq "an absent lock is not held" "" "$(toggle_lock_held "$lock")"
jq -n '{pid: 999999, started_at: "2026-07-17T11:00:00Z"}' > "$lock"
assert_eq "a lock held by a dead pid is not held" "" "$(toggle_lock_held "$lock")"
jq -n --argjson p "$$" '{pid: $p, started_at: "2026-07-17T11:00:00Z"}' > "$lock"
assert_eq "a lock held by a live pid is reported" \
  "held by pid $$ since 2026-07-17T11:00:00Z" "$(toggle_lock_held "$lock")"

# --- toggle_status_report ---

toggle_disable "$state_dir" "editing" "1h" 4 "tester" >/dev/null
report="$(toggle_status_report "$state_dir" "cycle=$lock" "review=$tmp_dir/absent.json")"
assert_eq "status reports the switch" "1" "$(grep -c 'DISABLED' <<<"$report")"
assert_eq "status reports a running pipeline" "1" "$(grep -c 'cycle:.*RUNNING' <<<"$report")"
assert_eq "status reports an idle pipeline" "1" "$(grep -c 'review:.*idle' <<<"$report")"
# Disabling stops the next cycle, not the one already running. An agent that
# doesn't know that disables the pipeline, starts editing, and is puzzled when
# the cycle it thought it stopped fails on its half-written file.
assert_eq "status warns when a cycle is running despite the switch" \
  "1" "$(grep -c 'does not stop one already running' <<<"$report")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
