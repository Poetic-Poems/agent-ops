#!/usr/bin/env bash
#
# test/render-crontab.test.sh — the per-node schedule render (D5).
#
# The properties that matter:
#   - the default minute is a stable hash of NODE_NAME in 1..59 — never 0,
#     which poetic's hourly sync workflow owns, and never different on two
#     renders of the same node;
#   - an explicit CYCLE_MINUTE in 1..59 wins; anything else warns loudly and
#     falls back to the hash — a typo must not silently land a node on 0;
#   - the review minute is (cycle + 29) mod 60, hour 3;
#   - every failure leaves the previous crontab byte-identical: the baked
#     schedule is the fallback, and half a schedule is worse than either.
#
# Run directly: ./test/render-crontab.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER="$SCRIPT_DIR/deploy/docker/render-crontab.sh"
TMPL="$SCRIPT_DIR/deploy/docker/crontab.tmpl"

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
expected_minute() { printf '%s' "$(( 1 + (0x$(printf '%s' "$1" | sha256sum | cut -c1-8) % 59) ))"; }

cycle_line()  { grep -E '^[0-9]+ \* \* \* \*' "$1"; }
review_line() { grep -E '^[0-9]+ 3 \* \* \*' "$1"; }

# --- The hash default ---------------------------------------------------------

out="$tmp_dir/crontab"
printf 'BAKED SENTINEL\n' > "$out"
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" 2>/dev/null
rc=$?
m="$(expected_minute poetic-1)"
r=$(( (m + 29) % 60 ))
assert_eq "a default render exits 0" "0" "$rc"
assert_eq "the hash minute is in 1..59" "1" "$(( m >= 1 && m <= 59 ))"
assert_contains "the cycle line carries the node's hash minute" "$m * * * *  /app/agent-cycle.sh" "$(cycle_line "$out")"
assert_contains "the review line is cycle+29 mod 60, hour 3" "$r 3 * * *  /app/review-cycle.sh" "$(review_line "$out")"
assert_eq "no placeholder survives a render" "0" "$(grep -c '@' "$out")"
assert_contains "the shared-memory lines come through untouched" "state-sync.sh push" "$(cat "$out")"
assert_contains "so does LOGDIR" "LOGDIR=/home/agent" "$(cat "$out")"

out2="$tmp_dir/crontab2"
env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out2" 2>/dev/null
assert_eq "the same node renders the same schedule every time" "0" "$(cmp -s "$out" "$out2"; echo $?)"

# --- An explicit CYCLE_MINUTE ---------------------------------------------------

env NODE_NAME=poetic-1 CYCLE_MINUTE=17 "$RENDER" "$TMPL" "$out" 2>/dev/null
assert_contains "an explicit minute wins" "17 * * * *  /app/agent-cycle.sh" "$(cycle_line "$out")"
assert_contains "and moves the review with it" "46 3 * * *" "$(review_line "$out")"

env NODE_NAME=poetic-1 CYCLE_MINUTE=31 "$RENDER" "$TMPL" "$out" 2>/dev/null
assert_contains "the review minute wraps mod 60" "0 3 * * *" "$(review_line "$out")"

# --- Bad values warn and fall back to the hash ----------------------------------

err="$(env NODE_NAME=poetic-1 CYCLE_MINUTE=0 "$RENDER" "$TMPL" "$out" 2>&1 >/dev/null)"
assert_contains "minute 0 is rejected by name" "poetic's hourly sync" "$err"
assert_contains "and the hash default is used instead" "$m * * * *" "$(cycle_line "$out")"

err="$(env NODE_NAME=poetic-1 CYCLE_MINUTE=banana "$RENDER" "$TMPL" "$out" 2>&1 >/dev/null)"
assert_contains "junk is rejected with a warning" "WARNING" "$err"
assert_contains "junk also falls back to the hash" "$m * * * *" "$(cycle_line "$out")"

# --- Failure leaves the fallback untouched --------------------------------------

printf 'BAKED SENTINEL\n' > "$out"
env NODE_NAME=poetic-1 "$RENDER" "$tmp_dir/no-such-template" "$out" 2>/dev/null
assert_eq "a missing template is an error" "1" "$?"
assert_eq "and the baked file survives byte-identical" "BAKED SENTINEL" "$(cat "$out")"

printf '@CYCLE_MINUTE@ and a stray @MYSTERY@\n' > "$tmp_dir/bad.tmpl"
env NODE_NAME=poetic-1 "$RENDER" "$tmp_dir/bad.tmpl" "$out" 2>/dev/null
assert_eq "an unknown placeholder is an error, not a broken schedule" "1" "$?"
assert_eq "the baked file survives that too" "BAKED SENTINEL" "$(cat "$out")"

# --- The rendered schedule is valid cron, when supercronic is here to ask -------

if command -v supercronic >/dev/null 2>&1; then
  env NODE_NAME=poetic-1 "$RENDER" "$TMPL" "$out" 2>/dev/null
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
