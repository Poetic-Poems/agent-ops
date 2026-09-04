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

# entry TS VERDICT [SERVICE] [STARTED] — a ledger line. STARTED, when given,
# is the writing container's own identity (agent-ops#1072); omitted, the line
# predates that field, exactly as every ledger line did before this fix.
entry() {
  local ts="$1" v="$2" svc="${3:-svc}" started="${4:-}"
  if [[ -n "$started" ]]; then
    jq -nc --arg ts "$ts" --arg v "$v" --arg svc "$svc" --argjson started "$started" \
      '{ts:$ts, verdict:$v, service:$svc, started:$started}'
  else
    jq -nc --arg ts "$ts" --arg v "$v" --arg svc "$svc" '{ts:$ts, verdict:$v, service:$svc}'
  fi
}
ago() { date -u -d "-$1" +%Y-%m-%dT%H:%M:%SZ; }   # ago SECONDS-EXPRESSION (e.g. "10 minutes")

STUCK_AFTER=1200        # 20 minutes, an ordinary threshold for the fixtures below
DEFER_STUCK_AFTER=21600 # 6 hours, an ordinary bound for the fixtures below

# --- Not applicable ------------------------------------------------------------

assert_eq "no ledger directory at all reads null" "null" \
  "$(updater_status "$tmp_dir/no-such-dir" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-a" "svc")"

assert_eq "an empty ledger directory reads null" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-a" "svc")"

# --- Rolled ----------------------------------------------------------------

# host-a was allowed to roll 10 minutes ago; host-b (this container) has no
# entries of its own yet — the ordinary post-roll reading.
allowed_at="$(ago '10 minutes')"
entry "$allowed_at" allow > "$ledger/host-a.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
assert_eq "a container with no history of its own, after a peer's allow, reads rolled" \
  "rolled" "$(jq -r '.status' <<<"$out")"
assert_eq "naming when that roll was allowed" \
  "$allowed_at" "$(jq -r '.at' <<<"$out")"

# The newest allow among several retired hostnames wins.
entry "$(ago '2 hours')" allow > "$ledger/host-older.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-c" "svc")"
assert_eq "the most recent allow across every retired hostname is the one reported" \
  "$allowed_at" "$(jq -r '.at' <<<"$out")"
rm -f "$ledger/host-older.jsonl"

# A retired hostname whose last word was "defer", with no allow anywhere,
# gives no evidence of a roll at all.
rm -f "$ledger/host-a.jsonl"
entry "$(ago '5 minutes')" defer > "$ledger/host-a.jsonl"
assert_eq "a foreign defer alone is not evidence of a roll" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-a.jsonl"

# --- Rolled is scoped to our own service (finding: cross-service contamination) --
# The scheduler and the dashboard share a ledger directory but are different
# services. A stuck scheduler that keeps appending fresh "allow" entries every
# poll must not be read by a fresh dashboard container as evidence of its own
# roll — and, symmetrically, a genuine same-service roll must still be found.

scheduler_allowed_at="$(ago '1 minute')"
dashboard_allowed_at="$(ago '3 hours')"
entry "$scheduler_allowed_at" allow "scheduler" > "$ledger/stuck-scheduler.jsonl"
entry "$dashboard_allowed_at" allow "dashboard" > "$ledger/old-dashboard.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "fresh-dashboard" "dashboard")"
assert_eq "a fresh dashboard reads its own service's allow, not a stuck sibling service's newer one" \
  "$dashboard_allowed_at" "$(jq -r '.at' <<<"$out")"
rm -f "$ledger/stuck-scheduler.jsonl" "$ledger/old-dashboard.jsonl"

entry "$(ago '1 minute')" allow "dashboard" > "$ledger/stuck-dashboard.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "fresh-scheduler" "scheduler")"
assert_eq "and a fresh scheduler is not fooled by a stuck dashboard's allow either" \
  "null" "$out"
rm -f "$ledger/stuck-dashboard.jsonl"

# A ledger line predating the `service` field defaults to "unknown", and an
# omitted service argument does too — so old peers still find each other.
legacy_allowed_at="$(ago '20 minutes')"
jq -nc --arg ts "$legacy_allowed_at" '{ts:$ts, verdict:"allow"}' > "$ledger/legacy-host.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "")"
assert_eq "a service-less ledger line and an omitted service argument both default to unknown" \
  "rolled" "$(jq -r '.status' <<<"$out")"
rm -f "$ledger/legacy-host.jsonl"

# --- Deferring ---------------------------------------------------------------

streak_start="$(ago '15 minutes')"
entry "$streak_start" defer > "$ledger/host-b.jsonl"
entry "$(ago '10 minutes')" defer >> "$ledger/host-b.jsonl"
entry "$(ago '5 minutes')"  defer >> "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
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
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
assert_eq "the streak stops at the last allow, not the start of the file" \
  "$streak_start" "$(jq -r '.at' <<<"$out")"
rm -f "$ledger/host-b.jsonl"

# --- Deferring has a bound (finding: an unbounded defer streak) --------------
# A defer streak that has outlasted DEFER_STUCK_AFTER is no longer "a cycle in
# flight" — no lock the hook honours could still be held that long — so it
# reads stuck, distinguished by reason:"defer" from an unresolved allow.

streak_start="$(ago '7 hours')"    # past DEFER_STUCK_AFTER (6h)
{
  entry "$streak_start" defer
  entry "$(ago '10 minutes')" defer
} > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
assert_eq "a defer streak past the bound reads stuck, not an eternal deferring" \
  "stuck" "$(jq -r '.status' <<<"$out")"
assert_eq "distinguished from an unresolved allow by reason" \
  "defer" "$(jq -r '.reason' <<<"$out")"
assert_eq "timed from the start of the streak" "$streak_start" "$(jq -r '.at' <<<"$out")"
rm -f "$ledger/host-b.jsonl"

# The same streak with no usable bound (omitted) never escalates — matching
# the stuck_after threshold's own graceful-degradation contract. The last
# entry stays inside STUCK_AFTER (liveness holds), so this exercises the
# defer_stuck_after gap specifically, not the liveness gate below.
{
  entry "$streak_start" defer
  entry "$(ago '10 minutes')" defer
} > "$ledger/host-b.jsonl"
assert_eq "an unusable defer-stuck-after threshold never escalates deferring to stuck" \
  "deferring" "$(updater_status "$ledger" "$STUCK_AFTER" "" "host-b" "svc" | jq -r '.status')"
rm -f "$ledger/host-b.jsonl"

# --- Liveness first (finding: a stale ledger read as a permanent alarm, agent-ops#1071) --
# A ledger whose newest entry has itself gone older than STUCK_AFTER supports
# no claim about the present, whatever the streak underneath it says — before
# this fix, a lone trailing "allow"/"defer" like these read as an eternal
# stuck badge nothing could ever clear (TD-PPagop-26082913). This is exactly
# the shape all four nodes in agent-ops#1071's fleet table arrived in after a
# multi-hour network outage: one trailing entry, nothing polled since.

entry "$(ago '30 minutes')" allow > "$ledger/host-b.jsonl"
assert_eq "a lone allow older than the threshold, with nothing polled since, reads null" \
  "null" "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-b.jsonl"

entry "$(ago '30 minutes')" defer > "$ledger/host-b.jsonl"
assert_eq "and the same holds for a lone stale defer" \
  "null" "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-b.jsonl"

# Replaying two of the fleet table's own measurements (agent-ops#1071).
entry "$(ago '19699 seconds')" allow > "$ledger/host-b.jsonl"
assert_eq "replaying one of the fleet's own stale allow ledgers reads null, not stuck" \
  "null" "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-b.jsonl"

entry "$(ago '52452 seconds')" defer > "$ledger/host-b.jsonl"
assert_eq "and one of its stale defer ledgers reads null too" \
  "null" "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-b.jsonl"

# --- Stuck -------------------------------------------------------------------
# Identity, not just hostname (agent-ops#1072): a trailing "allow" under our
# own hostname file was not necessarily written by the container reading it —
# watchtower clones the hostname forward across a roll, so the same file
# accumulates entries from every generation that has run under that name.
# `updater_status`'s optional sixth argument is this container's own reading
# of that identity (`started`, an opaque value in these fixtures); a line
# supports "stuck, reason: allow" only when its own `started` matches it.

OWN_STARTED=1000000000    # this container's own identity, for the fixtures below
OTHER_STARTED=2000000000  # a different generation's

# Allowed 30 seconds ago, well inside the threshold, and genuinely ours: too
# recent to call either state yet, and never reads as failing while that is
# true.
entry "$(ago '30 seconds')" allow "svc" "$OWN_STARTED" > "$ledger/host-b.jsonl"
assert_eq "an allow inside the grace window is not yet stuck" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED")"
rm -f "$ledger/host-b.jsonl"

# The state this whole check exists for, in the shape it actually arrives in:
# watchtower re-runs the hook on every poll for as long as the container is
# still stale, so the container it allowed and never replaced records one
# `allow` every WATCHTOWER_POLL_INTERVAL (300s), not one in total — every one
# of them genuinely written by this same container (matching `started`).
# Timing the newest entry would measure the age of the last poll — always
# under one interval, so never past a threshold counted in polls — and the
# 2026-08-14 signature would read as nothing at all. The streak's start is
# the age of the condition.
streak_start="$(ago '40 minutes')"
{
  entry "$streak_start" allow "svc" "$OWN_STARTED"
  for m in 35 30 25 20 15 10 5; do entry "$(ago "$m minutes")" allow "svc" "$OWN_STARTED"; done
  entry "$(ago '10 seconds')" allow "svc" "$OWN_STARTED"
} > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED")"
assert_eq "an allow repeated on every poll since is still stuck, not reset by the newest — liveness holds because the newest entry is recent" \
  "stuck" "$(jq -r '.status' <<<"$out")"
assert_eq "timed from the first allow of the run, not the last" \
  "$streak_start" "$(jq -r '.at' <<<"$out")"
assert_eq "and roughly how long ago (within a few seconds of 2400s)" "1" \
  "$(jq -r '(.seconds >= 2395 and .seconds <= 2410) | if . then 1 else 0 end' <<<"$out")"
assert_eq "distinguished from an overlong defer by reason" "allow" "$(jq -r '.reason' <<<"$out")"

# And the run starts where the last non-allow entry left off: a deferral in
# between means watchtower was told to hold off, so the clock starts again
# with the allow that followed it.
#
# The allow's timestamp is read from the clock once and used for both the
# ledger entry and the expectation. Two reads — one when the entry was
# written, one inside the assertion — are a second apart whenever a second
# boundary happens to fall between them, and on 2026-08-30 it did, on CI's
# arm64 leg (expected 07:44:22Z, actual 07:44:21Z), failing the build of a
# merge commit that had passed the merge queue minutes earlier. The same
# race, and the same fix, as `streak_start` above.
run_start="$(ago '25 minutes')"
{
  entry "$(ago '2 hours')" allow "svc" "$OWN_STARTED"
  entry "$(ago '90 minutes')" defer "svc" "$OWN_STARTED"
  entry "$run_start" allow "svc" "$OWN_STARTED"
  entry "$(ago '5 minutes')" allow "svc" "$OWN_STARTED"
} > "$ledger/host-b.jsonl"
assert_eq "a defer in between ends the run, so the clock starts at the allow after it" \
  "$run_start" "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED" | jq -r '.at')"
rm -f "$ledger/host-b.jsonl"

# --- Identity: a rolled container must not read its own creation as proof it
# never rolled (finding: the residual identity defect, agent-ops#1072) ------
# Matching filename (this container's own hostname file), a *different*
# start time on the trailing allow, recent enough to be live: exactly the
# shape measured across the fleet on 2026-08-30 — the roll that produced this
# container, misread by the old hostname-only check as this container's own
# proof it never rolled.

other_allowed_at="$(ago '11 seconds')"
entry "$other_allowed_at" allow "svc" "$OTHER_STARTED" > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED")"
assert_eq "a roll's own allow, under the hostname it handed forward, reads rolled" \
  "rolled" "$(jq -r '.status' <<<"$out")"
assert_eq "naming when that roll was allowed" \
  "$other_allowed_at" "$(jq -r '.at' <<<"$out")"
rm -f "$ledger/host-b.jsonl"

# A container that genuinely never rolled — same start time on the trailing
# allow, entries still arriving — still reads stuck: the identity fix must
# not turn a real alarm into a permanent "rolled" reading.
streak_start="$(ago '40 minutes')"
{
  entry "$streak_start" allow "svc" "$OWN_STARTED"
  entry "$(ago '10 seconds')" allow "svc" "$OWN_STARTED"
} > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED")"
assert_eq "a container that genuinely never rolled still reads stuck" \
  "stuck" "$(jq -r '.status' <<<"$out")"
rm -f "$ledger/host-b.jsonl"

# The residual false positive the liveness fix (agent-ops#1071) cannot reach
# on its own: a container watchtower rolls repeatedly inside STUCK_AFTER,
# each replacement appending its own genuine "allow" under the one hostname
# it inherits. Without a `started`-bounded streak scan, this would read as
# one continuous streak spanning several *successful* rolls.
{
  entry "$(ago '25 minutes')" allow "svc" "$OTHER_STARTED"   # an earlier generation's own allow
  entry "$(ago '9 minutes')"  allow "svc" "$OWN_STARTED"     # this container's own allow, written shortly after the roll that produced it
  entry "$(ago '10 seconds')" allow "svc" "$OWN_STARTED"     # this container, still running fine
} > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED")"
assert_eq "several successful rolls inside the window read as fine, not one spanning stuck streak" \
  "null" "$(jq -r '.status' <<<"$out")"
rm -f "$ledger/host-b.jsonl"

# Entries with no start-time field support no identity verdict and never
# produce stuck on a hostname match alone (agent-ops#1072) — the shape every
# ledger line had before this fix, retired within the 48h trim.
streak_start="$(ago '40 minutes')"
{
  entry "$streak_start" allow    # no started field at all
  entry "$(ago '10 seconds')" allow
} > "$ledger/host-b.jsonl"
assert_eq "a legacy allow streak with no start-time field never reads stuck" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED" | jq -r '.status')"
rm -f "$ledger/host-b.jsonl"

# And the same holds when this container cannot establish its own identity
# either — `_updater_health_own_started` failing, as it does when
# `/proc/1/stat` is unreadable — modelled by shadowing it for one call.
entry "$(ago '10 seconds')" allow "svc" "$OWN_STARTED" > "$ledger/host-b.jsonl"
_updater_health_own_started() { :; }
assert_eq "an own identity this container cannot establish never asserts stuck either" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "" | jq -r '.status')"
# shellcheck source=lib/updater-health.sh
. "$SCRIPT_DIR/lib/updater-health.sh"   # restore the real definition
rm -f "$ledger/host-b.jsonl"

# --- A corrupt line mid-streak is skipped, not treated as ending the run -----
# A single transient bad line must not truncate a genuine allow streak: it
# supports neither "same verdict" nor "different verdict", so the scan passes
# over it rather than stopping there.
streak_start="$(ago '2 hours')"
{
  entry "$streak_start" allow "svc" "$OWN_STARTED"
  entry "$(ago '110 minutes')" allow "svc" "$OWN_STARTED"
  printf 'not json at all\n'
  entry "$(ago '90 minutes')" allow "svc" "$OWN_STARTED"
  entry "$(ago '10 minutes')" allow "svc" "$OWN_STARTED"
} > "$ledger/host-b.jsonl"
out="$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED")"
assert_eq "a corrupt line mid-streak is skipped, not read as a verdict change" \
  "stuck" "$(jq -r '.status' <<<"$out")"
assert_eq "the streak still starts at the genuinely first allow, past the corrupt line" \
  "$streak_start" "$(jq -r '.at' <<<"$out")"
rm -f "$ledger/host-b.jsonl"

# --- An unusable threshold is a question this library will not answer --------
# The number is the caller's (config.json's `updater_stuck_after_minutes`),
# and a value that is not a whole number of seconds supports neither verdict,
# so it reads null rather than defaulting to one this file has no business
# choosing — an omitted argument included, which must never read as "0
# seconds, therefore stuck". Two entries, not one, so the usable-threshold
# assertion below exercises a genuinely live, genuinely stuck streak rather
# than a lone stale entry, which reads null regardless (see "Liveness first"
# above) and would prove nothing about this threshold specifically.
{
  entry "$(ago '40 minutes')" allow "svc" "$OWN_STARTED"
  entry "$(ago '5 minutes')" allow "svc" "$OWN_STARTED"
} > "$ledger/host-b.jsonl"
assert_eq "an omitted threshold reads null, never instantly stuck" "null" \
  "$(updater_status "$ledger" "" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED")"
assert_eq "and a non-numeric one reads null too" "null" \
  "$(updater_status "$ledger" "twenty" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED")"
assert_eq "while the same ledger with a usable threshold still reads stuck" "stuck" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" "$OWN_STARTED" | jq -r '.status')"
rm -f "$ledger/host-b.jsonl"

# --- Malformed data never crashes and never asserts more than it can support --

printf 'not json at all\n' > "$ledger/host-b.jsonl"
assert_eq "an unreadable last line reads null rather than a guess" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-b.jsonl"

jq -nc '{ts:"", verdict:"allow"}' > "$ledger/host-b.jsonl"
assert_eq "an entry with no usable timestamp reads null rather than asserting stuck" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-b.jsonl"

# A non-empty but unparseable timestamp must fail the same way as an empty
# one — never as epoch 0, which would read as impossibly old and pin this
# container to a permanent stuck/deferring badge nothing could ever clear.
jq -nc '{ts:"not-a-date", verdict:"allow"}' > "$ledger/host-b.jsonl"
assert_eq "a garbage timestamp reads null, never a permanent stuck badge" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-b.jsonl"

jq -nc '{ts:"not-a-date", verdict:"defer"}' > "$ledger/host-b.jsonl"
assert_eq "and the same holds on the defer branch" "null" \
  "$(updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc")"
rm -f "$ledger/host-b.jsonl"

# --- An empty hostname reads the same way the writer's own fallback does ----
# deploy/docker/watchtower-pre-update.sh writes ${HOSTNAME:-unknown}.jsonl;
# an empty hostname argument, with $HOSTNAME itself also unset, must resolve
# the same "unknown" name back, not read as unanswerable. Run in a subshell
# with $HOSTNAME unset — bash otherwise auto-populates it to this machine's
# real name, which would mask exactly the case this asserts.
entry "$(ago '10 minutes')" allow > "$ledger/unknown.jsonl"
assert_eq "an empty hostname argument falls back to 'unknown', matching the writer" \
  "null" "$(unset HOSTNAME; updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "" "svc" | jq -r '.status')"
rm -f "$ledger/unknown.jsonl"

# --- Never a non-zero exit ----------------------------------------------------

set -e
updater_status "$ledger" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" >/dev/null
updater_status "$tmp_dir/does-not-exist" "$STUCK_AFTER" "$DEFER_STUCK_AFTER" "host-b" "svc" >/dev/null
set +e

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
