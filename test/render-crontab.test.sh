#!/usr/bin/env bash
#
# test/render-crontab.test.sh — the per-node schedule render (D5).
#
# The properties that matter:
#   - cadence for both pipelines, and bounds for the sync/heartbeat ticks,
#     come from config.json's `schedule` — nothing here is product logic
#     baked into this renderer;
#   - the default minute is a stable hash of NODE_NAME, drawn only from the
#     minutes schedule.excluded_minutes does not rule out — deterministic
#     across renders of the same node, and never one of the excluded set;
#   - an explicit CYCLE_MINUTE not in the excluded set wins; anything else
#     warns loudly and falls back to the hash — a typo must not silently
#     land a node on an excluded minute;
#   - the review minute is (cycle + review_offset_minutes) mod 60, at
#     review_hour;
#   - poetic's own config.json reproduces today's schedule exactly: the
#     hash spread over 1..59 (minute 0 excluded), review 29 minutes past
#     the cycle at hour 3;
#   - every failure leaves the previous crontab byte-identical: the baked
#     schedule is the fallback, and half a schedule is worse than either.
#
# Run directly: ./test/render-crontab.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER="$SCRIPT_DIR/deploy/docker/render-crontab.sh"
TMPL="$SCRIPT_DIR/deploy/docker/crontab.tmpl"
CONFIG="$SCRIPT_DIR/config.json"

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

# The same formula the renderer uses; the test computes its own expectation
# so a silent change to the hash becomes a loud disagreement here.
allowed_minutes() {  # allowed_minutes <excluded-json-array>
  jq -c -n --argjson excluded "$1" '[range(0;60)] - $excluded'
}
expected_minute() {  # expected_minute <node> <excluded-json-array>
  local node="$1" excluded="$2" h dec allowed k idx
  h="$(printf '%s' "$node" | sha256sum | cut -c1-8)"
  dec=$(( 0x$h ))
  allowed="$(allowed_minutes "$excluded")"
  k="$(jq 'length' <<<"$allowed")"
  idx=$(( dec % k ))
  jq -r --argjson i "$idx" '.[$i]' <<<"$allowed"
}

cycle_line()  { grep -E '^[0-9]+ ' "$1" | grep 'agent-cycle.sh'; }
review_line() { grep 'review-cycle.sh' "$1"; }
heartbeat_line() { grep 'publish-dashboard-launcher.sh' "$1"; }
push_line() { grep 'state-sync.sh push' "$1"; }
fetch_line() { grep 'state-sync.sh fetch' "$1"; }
rotate_line() { grep 'rotate-logs.sh' "$1"; }

write_config() {  # write_config <path> <schedule-json>
  jq -n --argjson schedule "$2" '{schedule: $schedule}' > "$1"
}

# --- poetic's own config.json reproduces today's schedule exactly --------------

out="$tmp_dir/crontab"
printf 'BAKED SENTINEL\n' > "$out"
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" "$CONFIG" 2>/dev/null
rc=$?
m="$(expected_minute poetic-1 '[0]')"
r=$(( (m + 29) % 60 ))
assert_eq "a default render exits 0" "0" "$rc"
assert_eq "the hash minute is in 1..59 (0 stays excluded)" "1" "$(( m >= 1 && m <= 59 ))"
assert_contains "the cycle line carries the node's hash minute, hourly" "$m * * * *  /app/agent-cycle.sh" "$(cycle_line "$out")"
assert_contains "the review line is cycle+29 mod 60, hour 3" "$r 3 * * *  /app/review-cycle.sh" "$(review_line "$out")"
assert_contains "the heartbeat is every 5 minutes" "*/5 * * * *  /app/scripts/publish-dashboard-launcher.sh" "$(heartbeat_line "$out")"
assert_contains "state-sync push is every 5 minutes" "*/5 * * * *  /app/scripts/state-sync.sh push" "$(push_line "$out")"
assert_contains "state-sync fetch is every 7 minutes" "*/7 * * * *  /app/scripts/state-sync.sh fetch" "$(fetch_line "$out")"
assert_contains "log rotation is at :19" "19 * * * *  /app/scripts/rotate-logs.sh" "$(rotate_line "$out")"
assert_eq "no placeholder survives a render" "0" "$(grep -c '@' "$out")"

out2="$tmp_dir/crontab2"
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out2" "$CONFIG" 2>/dev/null
assert_eq "the same node renders the same schedule every time" "0" "$(cmp -s "$out" "$out2"; echo $?)"

# --- An explicit CYCLE_MINUTE ---------------------------------------------------

env NODE_NAME=poetic-1 CYCLE_MINUTE=17 "$RENDER" "$TMPL" "$out" "$CONFIG" 2>/dev/null
assert_contains "an explicit minute wins" "17 * * * *  /app/agent-cycle.sh" "$(cycle_line "$out")"
assert_contains "and moves the review with it" "46 3 * * *" "$(review_line "$out")"

env NODE_NAME=poetic-1 CYCLE_MINUTE=31 "$RENDER" "$TMPL" "$out" "$CONFIG" 2>/dev/null
assert_contains "the review minute wraps mod 60" "0 3 * * *" "$(review_line "$out")"

# --- Bad values warn and fall back to the hash ----------------------------------

err="$(env NODE_NAME=poetic-1 CYCLE_MINUTE=0 "$RENDER" "$TMPL" "$out" "$CONFIG" 2>&1 >/dev/null)"
assert_contains "an excluded minute is rejected, naming the config it came from" "schedule.excluded_minutes" "$err"
assert_contains "and the hash default is used instead" "$m * * * *" "$(cycle_line "$out")"

err="$(env NODE_NAME=poetic-1 CYCLE_MINUTE=banana "$RENDER" "$TMPL" "$out" "$CONFIG" 2>&1 >/dev/null)"
assert_contains "junk is rejected with a warning" "WARNING" "$err"
assert_contains "junk also falls back to the hash" "$m * * * *" "$(cycle_line "$out")"

# --- Excluded minutes, cadence and bounds are configuration, not baked in -------

custom_cfg="$tmp_dir/custom-config.json"
write_config "$custom_cfg" '{
  "cycle_hours": "*/2",
  "excluded_minutes": [0, 30, 45],
  "excluded_minutes_reason": "test fixture",
  "review_hour": 4,
  "review_offset_minutes": 10,
  "heartbeat_minutes": 2,
  "state_sync_push_minutes": 3,
  "state_sync_fetch_minutes": 11,
  "log_rotation_minute": 50
}'
cm="$(expected_minute poetic-1 '[0,30,45]')"
cr=$(( (cm + 10) % 60 ))
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" "$custom_cfg" 2>/dev/null
assert_eq "a custom config still renders cleanly" "0" "$?"
assert_contains "the hash never lands on a configured excluded minute" "$cm */2 * * *  /app/agent-cycle.sh" "$(cycle_line "$out")"
assert_contains "the review hour and offset come from config" "$cr 4 * * *  /app/review-cycle.sh" "$(review_line "$out")"
assert_contains "the heartbeat cadence comes from config" "*/2 * * * *  /app/scripts/publish-dashboard-launcher.sh" "$(heartbeat_line "$out")"
assert_contains "the state-sync push cadence comes from config" "*/3 * * * *  /app/scripts/state-sync.sh push" "$(push_line "$out")"
assert_contains "the state-sync fetch cadence comes from config" "*/11 * * * *  /app/scripts/state-sync.sh fetch" "$(fetch_line "$out")"
assert_contains "the log-rotation minute comes from config" "50 * * * *  /app/scripts/rotate-logs.sh" "$(rotate_line "$out")"

err="$(env NODE_NAME=poetic-1 CYCLE_MINUTE=30 "$RENDER" "$TMPL" "$out" "$custom_cfg" 2>&1 >/dev/null)"
assert_contains "a config-excluded minute is rejected too" "WARNING" "$err"
assert_contains "falling back to that config's own hash" "$cm */2 * * *" "$(cycle_line "$out")"

# --- No `schedule` block at all still renders every documented default
#     (config.schema.json's `schedule.*` defaults, via config_defaults) -------

no_schedule_cfg="$tmp_dir/no-schedule-config.json"
printf '{}\n' > "$no_schedule_cfg"
nm="$(expected_minute poetic-1 '[]')"
nr=$(( (nm + 29) % 60 ))
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" "$no_schedule_cfg" 2>/dev/null
assert_eq "a config with no schedule block at all still renders" "0" "$?"
assert_contains "the cycle hour defaults to every hour" "* * * *  /app/agent-cycle.sh" "$(cycle_line "$out")"
assert_contains "the review hour and offset default to 3 and 29" "$nr 3 * * *  /app/review-cycle.sh" "$(review_line "$out")"
assert_contains "the heartbeat defaults to every 5 minutes" "*/5 * * * *  /app/scripts/publish-dashboard-launcher.sh" "$(heartbeat_line "$out")"
assert_contains "state-sync push defaults to every 5 minutes" "*/5 * * * *  /app/scripts/state-sync.sh push" "$(push_line "$out")"
assert_contains "state-sync fetch defaults to every 7 minutes" "*/7 * * * *  /app/scripts/state-sync.sh fetch" "$(fetch_line "$out")"
assert_contains "log rotation defaults to :19" "19 * * * *  /app/scripts/rotate-logs.sh" "$(rotate_line "$out")"

# --- A misconfigured excluded_minutes is an error, not a silent no-op ----------

bad_cfg="$tmp_dir/bad-excluded.json"
write_config "$bad_cfg" '{"excluded_minutes": 0}'
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" "$bad_cfg" 2>/dev/null
assert_eq "excluded_minutes must be an array, not a bare number" "1" "$?"

all_excluded_cfg="$tmp_dir/all-excluded.json"
write_config "$all_excluded_cfg" "{\"excluded_minutes\": $(jq -c -n '[range(0;60)]')}"
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" "$all_excluded_cfg" 2>/dev/null
assert_eq "excluding every minute is an error, not an infinite search" "1" "$?"

# --- A missing config is an error, same as a missing template -------------------

printf 'BAKED SENTINEL\n' > "$out"
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" "$tmp_dir/no-such-config.json" 2>/dev/null
assert_eq "a missing config is an error" "1" "$?"
assert_eq "and the baked file survives byte-identical" "BAKED SENTINEL" "$(cat "$out")"

# --- Failure leaves the fallback untouched --------------------------------------

printf 'BAKED SENTINEL\n' > "$out"
env NODE_NAME=poetic-1 "$RENDER" "$tmp_dir/no-such-template" "$out" "$CONFIG" 2>/dev/null
assert_eq "a missing template is an error" "1" "$?"
assert_eq "and the baked file survives byte-identical" "BAKED SENTINEL" "$(cat "$out")"

printf '@CYCLE_MINUTE@ and a stray @MYSTERY@\n' > "$tmp_dir/bad.tmpl"
env NODE_NAME=poetic-1 "$RENDER" "$tmp_dir/bad.tmpl" "$out" "$CONFIG" 2>/dev/null
assert_eq "an unknown placeholder is an error, not a broken schedule" "1" "$?"
assert_eq "the baked file survives that too" "BAKED SENTINEL" "$(cat "$out")"

# --- The rendered schedule is valid cron, when supercronic is here to ask -------

if command -v supercronic >/dev/null 2>&1; then
  env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" "$CONFIG" 2>/dev/null
  supercronic -test "$out" >/dev/null 2>&1
  assert_eq "supercronic accepts the rendered schedule" "0" "$?"
else
  printf 'ok   - supercronic not installed here; CI validates the rendered schedule in-image\n'
fi

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
