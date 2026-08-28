#!/usr/bin/env bash
#
# test/updater-health.test.sh — the update mechanism's own verdict (#603).
#
# Drives `updater_status` through every state from fixture ledgers — no
# watchtower, no Docker, no network, exactly the constraints the library
# itself is written under.
#
# Run directly: ./test/updater-health.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/updater-health.sh
. "$SCRIPT_DIR/lib/updater-health.sh"

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

ledger="$tmp_dir/updater-ledger"
mkdir -p "$ledger"

entry() { jq -nc --arg ts "$1" --arg v "$2" '{ts:$ts, verdict:$v}'; }
ago() { date -u -d "-$1" +%Y-%m-%dT%H:%M:%SZ; }   # ago SECONDS-EXPRESSION (e.g. "10 minutes")

STUCK_AFTER=1200   # 20 minutes, an ordinary threshold for the fixtures below

# --- Not applicable ------------------------------------------------------------

assert_eq "no ledger directory at all reads null" "null" \
  "$(updater_status "$tmp_dir/no-such-dir" "$STUCK_AFTER" "host-a")"

assert_eq "an empty ledger directory reads null" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "host-a")"

# --- Rolled ----------------------------------------------------------------

# host-a was allowed to roll 10 minutes ago; host-b (this container) has no
# entries of its own yet — the ordinary post-roll reading.
allowed_at="$(ago '10 minutes')"
entry "$allowed_at" allow > "$ledger/host-a.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
assert_eq "a container with no history of its own, after a peer's allow, reads rolled" \
  "rolled" "$(jq -r '.status' <<<"$out")"
assert_eq "naming when that roll was allowed" \
  "$allowed_at" "$(jq -r '.at' <<<"$out")"

# The newest allow among several retired hostnames wins.
entry "$(ago '2 hours')" allow > "$ledger/host-older.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "host-c")"
assert_eq "the most recent allow across every retired hostname is the one reported" \
  "$allowed_at" "$(jq -r '.at' <<<"$out")"
rm -f "$ledger/host-older.jsonl"

# A retired hostname whose last word was "defer", with no allow anywhere,
# gives no evidence of a roll at all.
rm -f "$ledger/host-a.jsonl"
entry "$(ago '5 minutes')" defer > "$ledger/host-a.jsonl"
assert_eq "a foreign defer alone is not evidence of a roll" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
rm -f "$ledger/host-a.jsonl"

# --- Deferring ---------------------------------------------------------------

streak_start="$(ago '15 minutes')"
entry "$streak_start" defer > "$ledger/host-b.jsonl"
entry "$(ago '10 minutes')" defer >> "$ledger/host-b.jsonl"
entry "$(ago '5 minutes')"  defer >> "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
assert_eq "three consecutive defers read as deferring" "deferring" "$(jq -r '.status' <<<"$out")"
assert_eq "since the earliest of the streak" "$streak_start" "$(jq -r '.at' <<<"$out")"

# An allow earlier in the file ends the streak scan there, not at the file's
# first line.
streak_start="$(ago '20 minutes')"
{
  entry "$(ago '1 hour')"  allow
  entry "$streak_start" defer
  entry "$(ago '10 minutes')" defer
} > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
assert_eq "the streak stops at the last allow, not the start of the file" \
  "$streak_start" "$(jq -r '.at' <<<"$out")"
rm -f "$ledger/host-b.jsonl"

# --- Stuck -------------------------------------------------------------------

# Allowed 30 minutes ago, past the 20-minute threshold, same hostname still
# running: the 2026-08-14 signature.
allowed_at="$(ago '30 minutes')"
entry "$allowed_at" allow > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
assert_eq "an allow this container has outlived past the threshold reads stuck" \
  "stuck" "$(jq -r '.status' <<<"$out")"
assert_eq "naming when it was allowed" "$allowed_at" "$(jq -r '.at' <<<"$out")"
assert_eq "and roughly how long ago (within a few seconds of 1800s)" "1" \
  "$(jq -r '(.seconds >= 1795 and .seconds <= 1810) | if . then 1 else 0 end' <<<"$out")"

# Allowed 30 seconds ago, well inside the threshold: too recent to call
# either state yet, and never reads as failing while that is true.
entry "$(ago '30 seconds')" allow > "$ledger/host-b.jsonl"
assert_eq "an allow inside the grace window is not yet stuck" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
rm -f "$ledger/host-b.jsonl"

# The state this whole check exists for, in the shape it actually arrives in:
# watchtower re-runs the hook on every poll for as long as the container is
# still stale, so the container it allowed and never replaced records one
# `allow` every WATCHTOWER_POLL_INTERVAL (300s), not one in total. Timing the
# newest entry would measure the age of the last poll — always under one
# interval, so never past a threshold counted in polls — and the 2026-08-14
# signature would read as nothing at all. The streak's start is the age of the
# condition.
streak_start="$(ago '40 minutes')"
{
  entry "$streak_start" allow
  for m in 35 30 25 20 15 10 5; do entry "$(ago "$m minutes")" allow; done
  entry "$(ago '10 seconds')" allow
} > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
assert_eq "an allow repeated on every poll since is still stuck, not reset by the newest" \
  "stuck" "$(jq -r '.status' <<<"$out")"
assert_eq "timed from the first allow of the run, not the last" \
  "$streak_start" "$(jq -r '.at' <<<"$out")"

# And the run starts where the last non-allow entry left off: a deferral in
# between means watchtower was told to hold off, so the clock starts again
# with the allow that followed it.
{
  entry "$(ago '2 hours')" allow
  entry "$(ago '90 minutes')" defer
  entry "$(ago '25 minutes')" allow
  entry "$(ago '5 minutes')" allow
} > "$ledger/host-b.jsonl"
assert_eq "a defer in between ends the run, so the clock starts at the allow after it" \
  "$(ago '25 minutes')" "$(updater_status "$ledger" "$STUCK_AFTER" "host-b" | jq -r '.at')"
rm -f "$ledger/host-b.jsonl"

# --- An unusable threshold is a question this library will not answer --------
# The number is the caller's (config.json's `updater_stuck_after_minutes`),
# and a value that is not a whole number of seconds supports neither verdict,
# so it reads null rather than defaulting to one this file has no business
# choosing — an omitted argument included, which must never read as "0
# seconds, therefore stuck".
entry "$(ago '40 minutes')" allow > "$ledger/host-b.jsonl"
assert_eq "an omitted threshold reads null, never instantly stuck" "null" \
  "$(updater_status "$ledger" "" "host-b")"
assert_eq "and a non-numeric one reads null too" "null" \
  "$(updater_status "$ledger" "twenty" "host-b")"
assert_eq "while the same ledger with a usable threshold still reads stuck" "stuck" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "host-b" | jq -r '.status')"
rm -f "$ledger/host-b.jsonl"

# --- Malformed data never crashes and never asserts more than it can support --

printf 'not json at all\n' > "$ledger/host-b.jsonl"
assert_eq "an unreadable last line reads null rather than a guess" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
rm -f "$ledger/host-b.jsonl"

jq -nc '{ts:"", verdict:"allow"}' > "$ledger/host-b.jsonl"
assert_eq "an entry with no usable timestamp reads null rather than asserting stuck" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "host-b")"
rm -f "$ledger/host-b.jsonl"

# --- Never a non-zero exit ----------------------------------------------------

set -e
updater_status "$ledger" "$STUCK_AFTER" "host-b" >/dev/null
updater_status "$tmp_dir/does-not-exist" "$STUCK_AFTER" "host-b" >/dev/null
set +e

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
