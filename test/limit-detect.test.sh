#!/usr/bin/env bash
#
# test/limit-detect.test.sh — self-contained regression test for
# lib/limit-detect.sh (TD26071401).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/limit-detect.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/test/fixtures"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"

weekly_fixture="$FIXTURES_DIR/weekly-limit.txt"
monthly_fixture="$FIXTURES_DIR/monthly-spend-limit.txt"
weekly_text="$(cat "$weekly_fixture")"
monthly_text="$(cat "$monthly_fixture")"

failures=0

assert_true() {
  local desc="$1"; shift
  if "$@"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_false() {
  local desc="$1"; shift
  if ! "$@"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected %q, got %q)\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (%q did not match /%s/)\n' "$desc" "$actual" "$pattern"
    failures=$(( failures + 1 ))
  fi
}

# --- limit_phrase_in: the two exact record fixtures must both match --------
assert_true  "limit_phrase_in matches the weekly-limit fixture"        limit_phrase_in "$weekly_fixture"
assert_true  "limit_phrase_in matches the monthly-spend-limit fixture" limit_phrase_in "$monthly_fixture"

# --- limit_phrase_in: original terms must still match (no regression) -----
for phrase in 'usage limit exceeded' 'hit the rate limit' 'over the usage cap' 'quota exceeded, try later'; do
  tmp="$(mktemp)"
  printf '%s\n' "$phrase" > "$tmp"
  assert_true "limit_phrase_in still matches legacy phrase '$phrase'" limit_phrase_in "$tmp"
  rm -f "$tmp"
done

# --- limit_phrase_in: unrelated output must not match ----------------------
tmp="$(mktemp)"
printf 'Implemented the feature and opened a pull request.\n' > "$tmp"
assert_false "limit_phrase_in does not match ordinary output" limit_phrase_in "$tmp"
rm -f "$tmp"

# --- limit_class_of --------------------------------------------------------
assert_eq "limit_class_of classifies the weekly fixture"  "weekly"  "$(limit_class_of "$weekly_text")"
assert_eq "limit_class_of classifies the monthly fixture" "monthly" "$(limit_class_of "$monthly_text")"
assert_eq "limit_class_of classifies a generic rate-limit message as other" \
  "other" "$(limit_class_of "rate limit hit, please retry")"

# --- limit_parse_human_reset ------------------------------------------------
# Monthly fixture has no reset clause at all: must fail cleanly.
if reset="$(limit_parse_human_reset "$monthly_text" 2>/dev/null)"; then
  printf 'FAIL - limit_parse_human_reset should fail on the monthly fixture (got %q)\n' "$reset"
  failures=$(( failures + 1 ))
else
  printf 'ok   - limit_parse_human_reset fails cleanly on the monthly fixture\n'
fi

# Weekly fixture: "resets Jul 17, 4am (Pacific/Auckland)" must resolve to a
# concrete UTC instant. Assert on invariants rather than a hardcoded date so
# the test doesn't rot: valid ISO-8601 UTC, the instant is in the future (the
# year-rollover logic guarantees this), and converting it back to
# Pacific/Auckland wall-clock time reproduces "Jul 17 04:00" exactly — this is
# also the regression check for the TZ-handling bug (a naive
# `TZ=... date -d '...' -u ...` in one call silently drops the named zone
# because `-u` overrides TZ during parsing; see the comment in
# lib/limit-detect.sh).
weekly_resume="$(limit_parse_human_reset "$weekly_text")"
assert_match "limit_parse_human_reset returns an ISO-8601 UTC timestamp" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$weekly_resume"

if [[ -n "$weekly_resume" ]]; then
  resume_epoch="$(date -d "$weekly_resume" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  assert_true "limit_parse_human_reset's weekly resume_at is in the future" \
    bash -c "(( $resume_epoch > $now_epoch ))"

  auckland_wall_clock="$(TZ='Pacific/Auckland' date -d "@$resume_epoch" +'%b %d %H:%M')"
  assert_eq "the parsed instant is 04:00 Jul 17 in Pacific/Auckland" \
    "Jul 17 04:00" "$auckland_wall_clock"
fi

# --- limit_decide: the full resume_at/class/needs_human decision ----------
# Weekly: reset time is parseable, so resume_at must match the direct parse,
# class is weekly, and it does NOT need a human (auto stand-down is enough).
IFS=$'\t' read -r d_resume d_class d_needs_human < <(limit_decide "$weekly_text" 3)
assert_eq "limit_decide resume_at for weekly matches limit_parse_human_reset" "$weekly_resume" "$d_resume"
assert_eq "limit_decide class for weekly fixture" "weekly" "$d_class"
assert_eq "limit_decide needs_human is false for weekly fixture" "false" "$d_needs_human"

# Monthly: no reset time at all, so it must still log a limit-hit (non-empty
# resume_at) with a long fallback cooldown and a needs-human flag, since
# auto-retry cannot clear a spend cap.
IFS=$'\t' read -r d_resume d_class d_needs_human < <(limit_decide "$monthly_text" 3)
assert_eq "limit_decide class for monthly fixture" "monthly" "$d_class"
assert_eq "limit_decide needs_human is true for monthly fixture" "true" "$d_needs_human"
if [[ -n "$d_resume" ]]; then
  d_resume_epoch="$(date -d "$d_resume" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  delta_hours=$(( (d_resume_epoch - now_epoch) / 3600 ))
  assert_true "limit_decide's monthly fallback is a long cooldown (>12h), not the 3h default" \
    bash -c "(( $delta_hours > 12 ))"
else
  printf 'FAIL - limit_decide produced no resume_at for the monthly fixture\n'
  failures=$(( failures + 1 ))
fi

# Generic/other phrasing with no timestamp: preserve the original behaviour
# of falling back to the short default cooldown, and no needs-human flag.
IFS=$'\t' read -r d_resume d_class d_needs_human < <(limit_decide "rate limit hit, please retry" 3)
assert_eq "limit_decide class for a generic rate-limit message" "other" "$d_class"
assert_eq "limit_decide needs_human is false for a generic rate-limit message" "false" "$d_needs_human"
if [[ -n "$d_resume" ]]; then
  d_resume_epoch="$(date -d "$d_resume" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  delta_seconds=$(( d_resume_epoch - now_epoch ))
  # Allow a couple of minutes' slack for the time this test itself takes to run.
  assert_true "limit_decide's generic fallback honours the passed-in default cooldown (~3h)" \
    bash -c "(( $delta_seconds > (3 * 3600 - 120) && $delta_seconds < (3 * 3600 + 120) ))"
else
  printf 'FAIL - limit_decide produced no resume_at for the generic fixture\n'
  failures=$(( failures + 1 ))
fi

# --- Regression guard: must not abort under `set -e -o pipefail` ----------
# agent-cycle.sh runs with `set -euo pipefail`. Several helpers above build a
# result via `grep ... | head -n1` inside a plain assignment; under
# `pipefail`, grep finding nothing (the common case — most limit messages
# carry neither an ISO timestamp nor a weekly reset clause) makes that
# pipeline exit non-zero, which aborts the whole script under `-e` unless the
# assignment ends in `|| true`. This bit exactly once already (limit_decide's
# ISO-timestamp grep and limit_parse_human_reset's clause grep both lacked
# it), so exercise every public function in exactly that caller context,
# with input that guarantees each internal grep comes up empty.
strict_probe="$(bash -euo pipefail -c '
  source "'"$SCRIPT_DIR"'/lib/limit-detect.sh"
  limit_phrase_in "'"$monthly_fixture"'" /nonexistent || true
  limit_class_of "no timestamp, no weekly or monthly word here" >/dev/null
  limit_parse_human_reset "no reset clause in this text at all" 2>/dev/null || true
  limit_decide "no timestamp, no reset clause, no weekly or monthly word" 3 >/dev/null
  echo STRICT_MODE_SURVIVED
' 2>&1)"
assert_eq "every limit-detect helper survives set -e -o pipefail with a non-matching input" \
  "STRICT_MODE_SURVIVED" "$(tail -n1 <<<"$strict_probe")"
if [[ "$(tail -n1 <<<"$strict_probe")" != "STRICT_MODE_SURVIVED" ]]; then
  printf '%s\n' "$strict_probe"
fi

echo
if (( failures == 0 )); then
  echo "All limit-detect assertions passed."
  exit 0
else
  echo "$failures limit-detect assertion(s) FAILED."
  exit 1
fi
