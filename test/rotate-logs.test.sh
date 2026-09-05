#!/usr/bin/env bash
#
# test/rotate-logs.test.sh — regression test for scripts/rotate-logs.sh
# (TD26072501, requirement 2.6).
#
# What matters here:
#
#   what rotates      dashboard.log, state-sync.log, doctor.log,
#                     revert-rate.log, tech-debt-archive.log, cron.log,
#                     review-cron.log and gh-shim/ledger.ndjson (requirement
#                     2.0e), and only once they cross the threshold — a log
#                     still under it is left byte-identical.
#   what never does   log.jsonl, review-log.jsonl and revert-rate.jsonl are
#                     the fleet's memory (the union readers scan them whole);
#                     no size, however large, may rotate them.
#   how generations   a rotation renames the live file to `.1`; a second
#   stack             rotation shifts a stale `.1` to `.2` rather than
#                     clobbering it, and a generation beyond
#                     `log_generations` is dropped, never silently kept
#                     forever.
#   the live file      a fresh, empty file replaces the rotated one
#   never goes missing immediately, so a reader between rotation and the
#                     next append sees an empty file, never a missing one.
#   the one-off        `once-pr4-verify.log` is removed if present, and its
#                     absence is not an error.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/rotate-logs.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROTATE="$SCRIPT_DIR/scripts/rotate-logs.sh"

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

assert_file_absent() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected absent: %s\n' "$desc" "$path"
    failures=$(( failures + 1 ))
  fi
}

# Each node is a HOME: config.json's state_dir is ~-relative, so a throwaway
# home is a throwaway state dir.
new_home() {  # new_home <name> -> prints its state_dir
  local home="$tmp_dir/$1" dir
  dir="$home/.local/state/poetic-agents"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

# A file of exactly <bytes> bytes, filled with newline-terminated filler so a
# `tail` over it behaves like a real log.
make_log() {  # make_log <path> <bytes>
  local path="$1" bytes="$2"
  yes 'line' | head -c "$bytes" > "$path"
}

run_rotate() {  # run_rotate <state_dir> [env assignments…]
  local dir="$1"; shift
  local home
  home="$(dirname "$(dirname "$(dirname "$dir")")")"
  env HOME="$home" "$@" "$ROTATE" >/dev/null 2>&1
}

# --- A log under the threshold is left alone -------------------------------
d="$(new_home under)"
make_log "$d/dashboard.log" 100
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "rotate-logs exits 0" "0" "$?"
assert_eq "a log under the threshold keeps its size" "100" "$(stat -c%s "$d/dashboard.log" 2>/dev/null || stat -f%z "$d/dashboard.log")"
assert_file_absent "and gets no .1" "$d/dashboard.log.1"

# --- A log over the threshold rotates, and the live file reappears empty ---
d="$(new_home over)"
make_log "$d/cron.log" 2000
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "the oversized log is renamed to .1" "2000" "$(stat -c%s "$d/cron.log.1" 2>/dev/null || stat -f%z "$d/cron.log.1")"
assert_eq "the live file reappears immediately, empty" "0" "$(stat -c%s "$d/cron.log" 2>/dev/null || stat -f%z "$d/cron.log")"

# --- the gh-shim ledger rotates too, nested path included (requirement 2.0e) -
d="$(new_home ghshim)"
mkdir -p "$d/gh-shim"
make_log "$d/gh-shim/ledger.ndjson" 2000
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "the oversized ledger is renamed to .1" "2000" "$(stat -c%s "$d/gh-shim/ledger.ndjson.1" 2>/dev/null || stat -f%z "$d/gh-shim/ledger.ndjson.1")"
assert_eq "and the live file reappears immediately, empty" "0" "$(stat -c%s "$d/gh-shim/ledger.ndjson" 2>/dev/null || stat -f%z "$d/gh-shim/ledger.ndjson")"

d="$(new_home ghshim_absent)"
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "rotate-logs exits 0 when no node has ever used the shim" "0" "$?"

# --- doctor.log rotates like every other diagnostic log (agent-ops#543) ----
d="$(new_home doctor)"
make_log "$d/doctor.log" 2000
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "the oversized doctor.log is renamed to .1" "2000" "$(stat -c%s "$d/doctor.log.1" 2>/dev/null || stat -f%z "$d/doctor.log.1")"
assert_eq "and the live file reappears immediately, empty" "0" "$(stat -c%s "$d/doctor.log" 2>/dev/null || stat -f%z "$d/doctor.log")"

# --- revert-rate.log rotates like every other diagnostic log (agent-ops#579) -
d="$(new_home revertrate)"
make_log "$d/revert-rate.log" 2000
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "the oversized revert-rate.log is renamed to .1" "2000" "$(stat -c%s "$d/revert-rate.log.1" 2>/dev/null || stat -f%z "$d/revert-rate.log.1")"
assert_eq "  ... and the live file reappears immediately, empty" "0" "$(stat -c%s "$d/revert-rate.log" 2>/dev/null || stat -f%z "$d/revert-rate.log")"

# --- tech-debt-archive.log rotates like every other diagnostic log (agent-ops#878) -

make_log "$d/tech-debt-archive.log" 2000
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "the oversized tech-debt-archive.log is renamed to .1" "2000" "$(stat -c%s "$d/tech-debt-archive.log.1" 2>/dev/null || stat -f%z "$d/tech-debt-archive.log.1")"
assert_eq "  ... and the live file reappears immediately, empty" "0" "$(stat -c%s "$d/tech-debt-archive.log" 2>/dev/null || stat -f%z "$d/tech-debt-archive.log")"

# --- A second rotation shifts .1 to .2, dropping what falls off the end ----
d="$(new_home stack)"
make_log "$d/dashboard.log" 2000
printf 'first generation\n' > "$d/dashboard.log.1"
printf 'doomed generation\n' > "$d/dashboard.log.2"
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=2
assert_eq "the stale .1 shifts to .2" "first generation" "$(cat "$d/dashboard.log.2")"
assert_eq "the newly rotated file becomes .1" "2000" "$(stat -c%s "$d/dashboard.log.1" 2>/dev/null || stat -f%z "$d/dashboard.log.1")"
assert_file_absent "and .3 never appears (log_generations=2)" "$d/dashboard.log.3"

# --- log.jsonl, review-log.jsonl and revert-rate.jsonl are never rotated ---
d="$(new_home memory)"
make_log "$d/log.jsonl" 5000
make_log "$d/review-log.jsonl" 5000
make_log "$d/revert-rate.jsonl" 5000
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "log.jsonl keeps its full size" "5000" "$(stat -c%s "$d/log.jsonl" 2>/dev/null || stat -f%z "$d/log.jsonl")"
assert_eq "review-log.jsonl keeps its full size" "5000" "$(stat -c%s "$d/review-log.jsonl" 2>/dev/null || stat -f%z "$d/review-log.jsonl")"
assert_eq "revert-rate.jsonl keeps its full size" "5000" "$(stat -c%s "$d/revert-rate.jsonl" 2>/dev/null || stat -f%z "$d/revert-rate.jsonl")"
assert_file_absent "log.jsonl gets no .1" "$d/log.jsonl.1"
assert_file_absent "review-log.jsonl gets no .1" "$d/review-log.jsonl.1"
assert_file_absent "revert-rate.jsonl gets no .1" "$d/revert-rate.jsonl.1"

# --- The one-off cleanup ----------------------------------------------------
d="$(new_home oneoff)"
: > "$d/once-pr4-verify.log"
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_file_absent "once-pr4-verify.log is removed" "$d/once-pr4-verify.log"

d="$(new_home nooneoff)"
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "its absence is not an error" "0" "$?"

# --- Missing logs are a silent no-op, not a failure -------------------------
d="$(new_home empty)"
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=3
assert_eq "a state_dir with nothing to rotate still exits 0" "0" "$?"

# --- A nonsense generation count floors at one ------------------------------
d="$(new_home floor)"
make_log "$d/state-sync.log" 2000
run_rotate "$d" ROTATE_LOGS_RETAINED_BYTES=1000 ROTATE_LOGS_GENERATIONS=0
assert_eq "log_generations=0 still keeps one generation" "2000" "$(stat -c%s "$d/state-sync.log.1" 2>/dev/null || stat -f%z "$d/state-sync.log.1")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
