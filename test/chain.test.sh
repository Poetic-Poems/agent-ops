#!/usr/bin/env bash
#
# test/chain.test.sh — regression test for lib/chain.sh (finish-then-continue,
# requirement 39).
#
# The two ways this can go wrong are opposite failures, and both are silent
# in production: chaining when it should not (a fleet that never yields the
# lock, or a lineage that outruns max_chained_cycles) or not chaining when it
# should (right back to the one-item-per-cron-firing pickup latency #248
# exists to fix). So the assertions below check the boundary in both
# directions on both inputs — chain_count against max_chained_cycles, and an
# empty `.sources` against a non-empty one — rather than one happy-path case.
#
# Also covers `chain_image_behind` and `chain_write_roll_pending`
# (agent-ops#1096): the cycle-end check that yields a chain a healthy node
# would otherwise take when the running image has fallen behind, and the
# marker it writes so deploy/docker/watchtower-pre-update.sh's own test can
# pick up where this one leaves off. And `chain_clear_landed_roll_pending`
# (agent-ops#1102): the other half, called back at the top of the next cycle
# to shed that marker once it has either done its job or was never earned by
# this node's own current image.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/chain.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/chain.sh
. "$SCRIPT_DIR/lib/chain.sh"

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

assert_continues() {  # assert_continues <desc> <chain_count> <max> <repos_json>
  local desc="$1" cc="$2" max="$3" repos="$4"
  if chain_should_continue "$cc" "$max" "$repos"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected chain_should_continue to succeed (count=%s max=%s)\n' "$desc" "$cc" "$max"
    failures=$(( failures + 1 ))
  fi
}

assert_stops() {  # assert_stops <desc> <chain_count> <max> <repos_json>
  local desc="$1" cc="$2" max="$3" repos="$4"
  if chain_should_continue "$cc" "$max" "$repos"; then
    printf 'FAIL - %s\n     expected chain_should_continue to fail (count=%s max=%s)\n' "$desc" "$cc" "$max"
    failures=$(( failures + 1 ))
  else
    printf 'ok   - %s\n' "$desc"
  fi
}

one_source='[{"slug":"o/one","sources":["tech-debt"]}]'
two_sources='[{"slug":"o/one","sources":["tech-debt","issues"]}]'
no_sources_one_repo='[{"slug":"o/one","sources":[]}]'
no_sources_two_repos='[{"slug":"o/one","sources":[]},{"slug":"o/two","sources":[]}]'
mixed_sources='[{"slug":"o/one","sources":[]},{"slug":"o/two","sources":["security"]}]'

# --- chain_sources_remain ----------------------------------------------------

assert_eq "an empty sources array counts as zero" "0" "$(chain_sources_remain "$no_sources_one_repo")"
assert_eq "zero across every repo is still zero" "0" "$(chain_sources_remain "$no_sources_two_repos")"
assert_eq "one repo's sources are counted" "1" "$(chain_sources_remain "$one_source")"
assert_eq "multiple sources on one repo are all counted" "2" "$(chain_sources_remain "$two_sources")"
assert_eq "sources are summed across every repo, not just the first" "1" "$(chain_sources_remain "$mixed_sources")"
assert_eq "an empty repo list counts as zero" "0" "$(chain_sources_remain "[]")"
assert_eq "malformed JSON fails closed to zero, not an error" "0" "$(chain_sources_remain "not json")"

# --- chain_should_continue: the sources side --------------------------------

assert_continues "sources remaining, well under the cap: chain" "1" "3" "$one_source"
assert_stops "no sources anywhere: never chain, no matter the cap" "1" "3" "$no_sources_two_repos"
assert_stops "no sources anywhere, even with only one repo silent" "1" "3" "$no_sources_one_repo"
assert_continues "one silent repo among several with sources: still chains" "1" "3" "$mixed_sources"

# --- chain_should_continue: the max_chained_cycles boundary -----------------

assert_continues "count 1 of max 3: well under the cap" "1" "3" "$one_source"
assert_continues "count 2 of max 3: still under" "2" "3" "$one_source"
assert_stops "count 3 of max 3: at the cap, stop" "3" "3" "$one_source"
assert_stops "count past the cap: stop" "4" "3" "$one_source"
assert_stops "max_chained_cycles=1 disables chaining outright, even cycle 1" "1" "1" "$one_source"

# --- fails closed on garbage input, never chains on a value that can't be trusted --

assert_stops "a non-numeric chain_count fails closed" "banana" "3" "$one_source"
assert_stops "a non-numeric max_chained_cycles fails closed" "1" "banana" "$one_source"
assert_stops "a negative-looking chain_count fails closed" "-1" "3" "$one_source"

# --- chain_image_behind (requirement 39, agent-ops#1096) --------------------
# A healthy node running long or chained cycles never presents watchtower a
# gap to poll into, so a cycle that is about to chain must check whether the
# image has fallen behind before it does — reusing the heartbeat's own
# image_drift_status verdict, never a second signal.

assert_behind() {  # assert_behind <desc> <status_json>
  local desc="$1" status="$2"
  if chain_image_behind "$status"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected chain_image_behind to succeed for: %s\n' "$desc" "$status"
    failures=$(( failures + 1 ))
  fi
}

assert_not_behind() {  # assert_not_behind <desc> <status_json>
  local desc="$1" status="$2"
  if chain_image_behind "$status"; then
    printf 'FAIL - %s\n     expected chain_image_behind to fail for: %s\n' "$desc" "$status"
    failures=$(( failures + 1 ))
  else
    printf 'ok   - %s\n' "$desc"
  fi
}

assert_behind "a 'behind' verdict is behind" '{"status":"behind","registry_commit":"abc","checked_at":"2026-08-30T00:00:00Z"}'
assert_not_behind "a 'current' verdict is not" '{"status":"current","checked_at":"2026-08-30T00:00:00Z"}'
assert_not_behind "an 'unverified' verdict is not — nothing to act on" '{"status":"unverified","reason":"registry unreachable","checked_at":"2026-08-30T00:00:00Z"}'
assert_not_behind "the JSON literal null (a developer checkout) is not" "null"
assert_not_behind "no argument at all defaults closed" ""
assert_not_behind "malformed JSON fails closed" "not json"

# --- chain_write_roll_pending (requirement 39, agent-ops#1096) --------------
# What deploy/docker/watchtower-pre-update.sh reads back to override its
# ordinary in-flight-cycle deferral for exactly the window this cycle
# yielded, and no longer.

tmp_state="$tmp_dir/state"
mkdir -p "$tmp_state"

chain_write_roll_pending "$tmp_state" 15
assert_eq "the marker file is written" "1" \
  "$(test -f "$tmp_state/roll-pending.json" && echo 1 || echo 0)"
marker_until="$(jq -r '.until' "$tmp_state/roll-pending.json")"
assert_eq "'until' is a bare ISO-8601 timestamp" "1" \
  "$([[ "$marker_until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo 1 || echo 0)"

now_epoch="$(date +%s)"
until_epoch="$(date -d "$marker_until" +%s)"
gap=$(( until_epoch - now_epoch ))
assert_eq "'until' is roughly 15 minutes out (within a minute either way)" "1" \
  "$(( gap > 14*60 && gap < 16*60 ? 1 : 0 ))"

chain_write_roll_pending "$tmp_state" "banana"
marker_until="$(jq -r '.until' "$tmp_state/roll-pending.json")"
until_epoch="$(date -d "$marker_until" +%s)"
gap=$(( until_epoch - $(date +%s) ))
assert_eq "a non-numeric minutes argument falls back to the schema default (15)" "1" \
  "$(( gap > 14*60 && gap < 16*60 ? 1 : 0 ))"

rm -rf "$tmp_state"
chain_write_roll_pending "$tmp_state" 5
assert_eq "a missing state_dir is created rather than failing" "1" \
  "$(test -f "$tmp_state/roll-pending.json" && echo 1 || echo 0)"

# --- chain_clear_landed_roll_pending (agent-ops#1102) -----------------------
# The other half of the pair above: called back at the top of the next cycle
# to reacquire the lock, this sheds a marker that has either done its job
# (the roll landed) or was never earned by this node's own current image —
# but only once the verdict genuinely says so, never on a "behind" verdict
# still in force.

chain_write_roll_pending "$tmp_state" 15
chain_clear_landed_roll_pending "$tmp_state" '{"status":"behind","checked_at":"2026-08-30T00:00:00Z"}'
assert_eq "a still-'behind' verdict leaves the marker in place" "1" \
  "$(test -f "$tmp_state/roll-pending.json" && echo 1 || echo 0)"

chain_clear_landed_roll_pending "$tmp_state" '{"status":"current","checked_at":"2026-08-30T00:00:00Z"}'
assert_eq "a 'current' verdict clears a landed marker" "0" \
  "$(test -f "$tmp_state/roll-pending.json" && echo 1 || echo 0)"

chain_write_roll_pending "$tmp_state" 15
chain_clear_landed_roll_pending "$tmp_state" '{"status":"unverified","reason":"registry unreachable","checked_at":"2026-08-30T00:00:00Z"}'
assert_eq "an 'unverified' verdict clears it too — nothing to protect any more" "0" \
  "$(test -f "$tmp_state/roll-pending.json" && echo 1 || echo 0)"

chain_write_roll_pending "$tmp_state" 15
chain_clear_landed_roll_pending "$tmp_state" "null"
assert_eq "the JSON literal null clears it — this node is not running a CI-stamped image at all" "0" \
  "$(test -f "$tmp_state/roll-pending.json" && echo 1 || echo 0)"

chain_write_roll_pending "$tmp_state" 15
chain_clear_landed_roll_pending "$tmp_state" ""
assert_eq "no argument at all defaults to clearing, same as null" "0" \
  "$(test -f "$tmp_state/roll-pending.json" && echo 1 || echo 0)"

rm -f "$tmp_state/roll-pending.json"
chain_clear_landed_roll_pending "$tmp_state" '{"status":"current"}'
assert_eq "no marker to clear is not an error" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
