#!/usr/bin/env bash
#
# test/fleet-publication.test.sh — the one publication verdict a peer's row
# and a node's own row are both judged by (`lib/fleet.sh`'s `fleet_ts_field`
# and `fleet_publication_status`, requirement 2.5's "Publication freshness",
# agent-ops#602).
#
# What this guards: both functions are read by two consumers that must never
# disagree — `scripts/publish-dashboard.sh`'s fleet strip and
# `scripts/doctor.sh`'s own check — and each consumer's tests exercise them
# only through a whole publish or a whole doctor run, where a misread degrades
# quietly into "unknown" rather than failing anything. The properties below are
# the ones that go silent if lost:
#
#   the shape is not the contract   a timestamp must be readable whatever
#                                   shape the file holding it takes — `ts`
#                                   first (the fast path, no fork), `ts`
#                                   mid-object (a peer's heartbeat), or
#                                   pretty-printed across lines (a
#                                   hand-edited file). Reading only the first
#                                   line answers `{` for the last of those,
#                                   which reads as "no publication ever" and
#                                   reports a healthy node stale on the page
#                                   whose whole job is to be believed about
#                                   staleness.
#   unknown is not stale            a timestamp that has never been read back
#                                   is its own verdict, distinct from one that
#                                   has aged out: doctor.sh warns on the first
#                                   and fails on the second.
#   a future ts is not negative     clocks disagree; an age below zero is
#                                   clamped rather than propagated into
#                                   arithmetic downstream.
#
# No network, no config, no clock of its own: `fleet_publication_status` takes
# `now` as an argument precisely so this can be asserted exactly.
#
# Run directly: ./test/fleet-publication.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"

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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- fleet_ts_field: the read, whatever shape the file takes ----------------

# The self cache as `state-sync.sh`'s `do_fetch` writes it (`jq -nc '{ts:
# $ts}'`): the fast path, matched by prefix with no jq fork at all.
printf '{"ts":"2026-09-06T10:00:00Z"}\n' > "$tmp/published.json"
assert_eq "the self cache's own shape reads through the no-fork fast path" \
  "2026-09-06T10:00:00Z" "$(fleet_ts_field "$tmp/published.json")"

# The same shape without the trailing newline `jq -nc` always writes — a
# fixture built by a bare `printf`, which `read` reports failure on even
# though the whole line is there.
printf '{"ts":"2026-09-06T10:00:00Z"}' > "$tmp/no-newline.json"
assert_eq "a file with no trailing newline reads the same" \
  "2026-09-06T10:00:00Z" "$(fleet_ts_field "$tmp/no-newline.json")"

# A peer's heartbeat, as `state-sync.sh`'s push writes it: `ts` is mid-object,
# so the prefix match cannot fire and the jq fallback answers.
printf '{"node":"peer1","role":"active","ts":"2026-09-06T09:30:00Z","last_cycle":null}\n' \
  > "$tmp/heartbeat.json"
assert_eq "a peer's heartbeat reads its ts from mid-object" \
  "2026-09-06T09:30:00Z" "$(fleet_ts_field "$tmp/heartbeat.json")"

# Pretty-printed: the first line is `{` alone, so a fallback reading only that
# line would answer nothing and the node would report as never having
# published. The fork is spent either way, so the fallback parses the file.
jq -n '{node: "peer1", ts: "2026-09-06T08:15:00Z"}' > "$tmp/pretty.json"
assert_eq "a pretty-printed file reads its ts, not the first line's worth of it" \
  "2026-09-06T08:15:00Z" "$(fleet_ts_field "$tmp/pretty.json")"

assert_eq "a file that does not exist reads as nothing" \
  "" "$(fleet_ts_field "$tmp/absent.json")"
: > "$tmp/empty.json"
assert_eq "an empty file reads as nothing" "" "$(fleet_ts_field "$tmp/empty.json")"
printf 'not json at all\n' > "$tmp/garbage.json"
assert_eq "a file that is not JSON reads as nothing rather than erroring" \
  "" "$(fleet_ts_field "$tmp/garbage.json")"
printf '{"node":"peer1","role":"active"}\n' > "$tmp/no-ts.json"
assert_eq "valid JSON carrying no ts reads as nothing" \
  "" "$(fleet_ts_field "$tmp/no-ts.json")"

# --- fleet_publication_status: the verdict ----------------------------------

now="$(date -u -d '2026-09-06T12:00:00Z' +%s)"
v() { jq -r "$2" <<<"$1"; }

fresh="$(fleet_publication_status "2026-09-06T11:55:00Z" 1800 "$now")"
assert_eq "a publication five minutes old is fresh" "fresh" "$(v "$fresh" .verdict)"
assert_eq "  ... carrying its own age in seconds" "300" "$(v "$fresh" .age_s)"
assert_eq "  ... and the timestamp it was judged on" \
  "2026-09-06T11:55:00Z" "$(v "$fresh" .ts)"

stale="$(fleet_publication_status "2026-09-06T11:00:00Z" 1800 "$now")"
assert_eq "a publication an hour old is stale against a 30-minute threshold" \
  "stale" "$(v "$stale" .verdict)"
assert_eq "  ... with the age that made it so" "3600" "$(v "$stale" .age_s)"

# The boundary is exclusive: exactly the threshold is still fresh, one second
# past it is not — the same reading `doctor.sh`'s "over the threshold" wording
# and the dashboard's "more than N minutes" both make.
assert_eq "exactly the threshold is still fresh" "fresh" \
  "$(v "$(fleet_publication_status "2026-09-06T11:30:00Z" 1800 "$now")" .verdict)"
assert_eq "one second past it is stale" "stale" \
  "$(v "$(fleet_publication_status "2026-09-06T11:29:59Z" 1800 "$now")" .verdict)"

# The threshold is the caller's (`node_stale_after_minutes`), not a constant:
# the same timestamp reads either way depending on what it is held against.
assert_eq "a tighter configured threshold makes the same publication stale" \
  "stale" "$(v "$(fleet_publication_status "2026-09-06T11:55:00Z" 60 "$now")" .verdict)"

unknown="$(fleet_publication_status "" 1800 "$now")"
assert_eq "no timestamp at all is unknown, never stale" "unknown" "$(v "$unknown" .verdict)"
assert_eq "  ... with no timestamp to report" "null" "$(v "$unknown" .ts)"
assert_eq "  ... nor an age" "null" "$(v "$unknown" .age_s)"
assert_eq "a timestamp that does not parse is unknown too" "unknown" \
  "$(v "$(fleet_publication_status "not-a-date" 1800 "$now")" .verdict)"

future="$(fleet_publication_status "2026-09-06T12:30:00Z" 1800 "$now")"
assert_eq "a publication stamped in the future is fresh, not negative" \
  "fresh" "$(v "$future" .verdict)"
assert_eq "  ... with its age clamped to zero" "0" "$(v "$future" .age_s)"

# Every caller runs under `set -euo pipefail`; a verdict computed in a command
# substitution must not take the script down with it on the non-stale path,
# where the arithmetic test that chooses the verdict is itself false.
assert_eq "the function survives set -e on every path" "survived" \
  "$(bash -c 'set -euo pipefail
    . "$1/lib/fleet.sh"
    fleet_publication_status "2026-09-06T11:55:00Z" 1800 "$2" >/dev/null
    fleet_publication_status "" 1800 "$2" >/dev/null
    fleet_ts_field "$3" >/dev/null
    printf survived' _ "$SCRIPT_DIR" "$now" "$tmp/garbage.json")"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
