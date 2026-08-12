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

# --- limit_decide: the full resume_at/class/reset_known decision ----------
# Weekly: reset time is parseable, so resume_at must match the direct parse,
# class is weekly, and reset_known records that the time came from the message.
IFS=$'\t' read -r d_resume d_class d_reset_known < <(limit_decide "$weekly_text" 3)
assert_eq "limit_decide resume_at for weekly matches limit_parse_human_reset" "$weekly_resume" "$d_resume"
assert_eq "limit_decide class for weekly fixture" "weekly" "$d_class"
assert_eq "limit_decide reset_known is true for weekly fixture" "true" "$d_reset_known"

# Monthly: no reset time at all, so it must still log a limit-hit (non-empty
# resume_at) with a long fallback cooldown, and must mark the reset UNKNOWN —
# resume_at there is this system's own retry interval, not a stated reset. The
# earlier `needs_human` flag claimed more than the detector knows: a spend cap
# also clears by itself at the plan's rollover.
IFS=$'\t' read -r d_resume d_class d_reset_known < <(limit_decide "$monthly_text" 3)
assert_eq "limit_decide class for monthly fixture" "monthly" "$d_class"
assert_eq "limit_decide reset_known is false for monthly fixture" "false" "$d_reset_known"
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
# of falling back to the short default cooldown. The reset is unknown here
# too — the cooldown is a guess, it is just a shorter one.
IFS=$'\t' read -r d_resume d_class d_reset_known < <(limit_decide "rate limit hit, please retry" 3)
assert_eq "limit_decide class for a generic rate-limit message" "other" "$d_class"
assert_eq "limit_decide reset_known is false for a generic rate-limit message" "false" "$d_reset_known"
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

# --- limit_union_record: the reduction the stand-down and dashboard share --
# Time-ordered, most-recent-wins, over both limit events.
union_hits="$(printf '%s\n' \
  '{"ts":"2026-01-01T00:00:00Z","event":"limit-hit","resume_at":"2030-01-01T00:00:00Z","class":"weekly","reset_known":true}' \
  '{"ts":"2026-01-01T01:00:00Z","event":"cycle-end","exit_code":0}' \
  '{"ts":"2026-01-01T02:00:00Z","event":"limit-hit","resume_at":"2031-01-01T00:00:00Z","class":"monthly","reset_known":false}')"
assert_eq "limit_union_record returns the most recent limit-hit" \
  "2031-01-01T00:00:00Z" "$(limit_union_record <<<"$union_hits" | jq -r '.resume_at')"

# The whole point of the new event: a limit-cleared written afterwards retires
# the stand-down. Without it nothing could ever lift one, because the check
# runs before any stage and no cycle could reach a success to clear it.
union_cleared="$union_hits
{\"ts\":\"2026-01-01T03:00:00Z\",\"event\":\"limit-cleared\",\"was\":\"2031-01-01T00:00:00Z\"}"
assert_eq "a later limit-cleared supersedes the limit-hit" \
  "" "$(limit_union_record <<<"$union_cleared")"

# ...and a limit hit *after* a clear stands the fleet down again.
union_recleared="$union_cleared
{\"ts\":\"2026-01-01T04:00:00Z\",\"event\":\"limit-hit\",\"resume_at\":\"2032-01-01T00:00:00Z\",\"class\":\"weekly\",\"reset_known\":true}"
assert_eq "a limit-hit after a limit-cleared stands down again" \
  "2032-01-01T00:00:00Z" "$(limit_union_record <<<"$union_recleared" | jq -r '.resume_at')"

assert_eq "limit_union_record is empty for a stream with no limit events" \
  "" "$(limit_union_record <<<'{"ts":"2026-01-01T00:00:00Z","event":"cycle-end"}')"

# --- limit_standdown_since: the start of the current freeze (#244) ---------
# The escalation of requirement 2 ages a freeze from its first hit, not its
# latest extension — a freeze that keeps re-confirming itself must not keep
# resetting the clock that decides when a human hears about it.
assert_eq "limit_standdown_since names the first hit of an unbroken freeze" \
  "2026-01-01T00:00:00Z" "$(limit_standdown_since <<<"$union_hits")"
assert_eq "a limit-cleared ends the freeze: nothing to age" \
  "" "$(limit_standdown_since <<<"$union_cleared")"
assert_eq "a hit after a clear starts a new freeze at its own ts, not the old one's" \
  "2026-01-01T04:00:00Z" "$(limit_standdown_since <<<"$union_recleared")"
assert_eq "limit_standdown_since is empty for a stream with no limit events" \
  "" "$(limit_standdown_since <<<'{"ts":"2026-01-01T00:00:00Z","event":"cycle-end"}')"

# --- limit_later_record: requirement 2.1's "later resume wins" -------------
rec_early='{"resume_at":"2030-01-01T00:00:00Z","class":"weekly","reset_known":true}'
rec_late='{"resume_at":"2031-01-01T00:00:00Z","class":"monthly","reset_known":false}'
assert_eq "limit_later_record picks the later resume, whatever the argument order" \
  "2031-01-01T00:00:00Z" "$(limit_later_record "$rec_late" "$rec_early" | jq -r '.resume_at')"
assert_eq "limit_later_record picks the later resume (reversed)" \
  "2031-01-01T00:00:00Z" "$(limit_later_record "$rec_early" "$rec_late" | jq -r '.resume_at')"
assert_eq "limit_later_record skips a carrier that is clear" \
  "2030-01-01T00:00:00Z" "$(limit_later_record "" "$rec_early" | jq -r '.resume_at')"
assert_eq "limit_later_record is empty when every carrier is clear" \
  "" "$(limit_later_record "" "")"

# --- limit_reset_known: the field, and the superseded one ------------------
assert_eq "limit_reset_known reads reset_known when present" \
  "false" "$(limit_reset_known '{"reset_known":false}')"
# A peer still running the previous release publishes needs_human, whose sense
# is inverted; reading it wrong would call an invented time authoritative.
assert_eq "limit_reset_known inverts a legacy needs_human:true" \
  "false" "$(limit_reset_known '{"needs_human":true}')"
assert_eq "limit_reset_known inverts a legacy needs_human:false" \
  "true" "$(limit_reset_known '{"needs_human":false}')"

# --- limit_describe: what the operator is actually told --------------------
known_note="$(limit_describe "2030-01-01T00:00:00Z" weekly true)"
assert_eq "a stated reset is described as a deadline" \
  "until 2030-01-01T00:00:00Z" "$known_note"

# The correction this change exists for: an unstated reset must not be
# presented as a deadline, and must name BOTH ways out — waiting for the
# rollover (no human) and raising the cap (a human, only if sooner is wanted).
#
# Checked in-process rather than through `bash -c`: the note contains an
# apostrophe ("the plan's rollover"), which no amount of quoting survives
# being interpolated into a child shell's `[[ ]]`.
contains() { if [[ "$1" == *"$2"* ]]; then echo yes; else echo no; fi; }
guess_note="$(limit_describe "2030-01-01T00:00:00Z" monthly false)"
assert_eq "an unstated reset is marked as an estimate" \
  "yes" "$(contains "$guess_note" "estimated")"
assert_eq "an unstated reset is not presented as a deadline" \
  "no" "$(contains "$guess_note" "until ")"
assert_eq "an unstated reset says it clears at the rollover on its own" \
  "yes" "$(contains "$guess_note" "rollover")"
assert_eq "an unstated reset offers --clear-limit as the way to resume sooner" \
  "yes" "$(contains "$guess_note" "--clear-limit")"
assert_eq "no limit is ever described as needing a human before it can clear" \
  "no" "$(contains "$guess_note" "needs human")"
assert_eq "an unstated reset says the hourly probe is watching for the lift" \
  "yes" "$(contains "$guess_note" "probe")"

# --- limit_probe_verdict: the three answers a probe can give ---------------
# The envelope fixtures are canned transcripts of the two real probe shapes
# observed on 2026-07-28: a clean answer, and a 429 whose limit message
# arrives *inside* a well-formed envelope's `result` — the case the
# phrase-first ordering exists for, because that envelope parses perfectly
# and only `is_error` and the phrase say what it actually is.
clear_envelope="$(cat "$FIXTURES_DIR/probe-clear-envelope.txt")"
limited_envelope="$(cat "$FIXTURES_DIR/probe-limited-envelope.txt")"

assert_eq "a clean envelope with a result is clear" \
  "clear" "$(limit_probe_verdict "$clear_envelope")"
assert_eq "a well-formed envelope carrying the limit message is limited, never clear" \
  "limited" "$(limit_probe_verdict "$limited_envelope")"
assert_eq "a raw limit message with no envelope at all is limited" \
  "limited" "$(limit_probe_verdict "$monthly_text")"
assert_eq "the limit phrase on stderr outweighs a clean envelope on stdout" \
  "limited" "$(limit_probe_verdict "$clear_envelope" "$monthly_text")"
assert_eq "an empty transcript is inconclusive" \
  "inconclusive" "$(limit_probe_verdict "" "")"
assert_eq "stderr diagnostics alone are inconclusive, never clear" \
  "inconclusive" "$(limit_probe_verdict "" "connect: connection refused")"
assert_eq "a failed envelope with no limit phrase is inconclusive" \
  "inconclusive" "$(limit_probe_verdict '{"is_error":true,"result":"upstream connect error"}')"
assert_eq "a clean envelope with an empty result is inconclusive" \
  "inconclusive" "$(limit_probe_verdict '{"is_error":false,"result":""}')"

# --- limit_decide_structured: the runner's own record, not its prose -------
# The better source wherever it exists, for a reason worth pinning down: a
# stated `resetsAt` makes the stand-down a fact rather than an estimate, and
# an estimated stand-down costs the fleet a usage probe every cycle until it
# clears. So `reset_known` must come back `true` here where the prose path
# would usually have to guess.
assert_eq "a structured record with a reset time yields that exact time, known" \
  "$(date -u -d @1786086000 +%Y-%m-%dT%H:%M:%SZ)	other	true" \
  "$(limit_decide_structured '{"status":"rejected","resetsAt":1786086000,"rateLimitType":"five_hour"}' 3)"

# The class exists only to choose a fallback cooldown, so it follows what that
# fallback is for — the long weekly kind — not what the limit is called.
assert_eq "a seven-day limit is the weekly class" "weekly" \
  "$(limit_decide_structured '{"status":"rejected","rateLimitType":"seven_day_opus"}' 3 | cut -f2)"
assert_eq "…and with no stated reset falls back to the long cooldown, unknown" \
  "false" \
  "$(limit_decide_structured '{"status":"rejected","rateLimitType":"seven_day_opus"}' 3 | cut -f3)"
assert_eq "a five-hour limit is not the weekly class" "other" \
  "$(limit_decide_structured '{"status":"rejected","rateLimitType":"five_hour"}' 3 | cut -f2)"

# Nothing usable must be a refusal to answer, not a fabricated stand-down: the
# caller falls back to the phrase matcher, which is what has always handled
# this.
for junk in '' 'not json at all' '[]' 'null'; do
  if limit_decide_structured "$junk" 3 >/dev/null 2>&1; then
    printf 'FAIL - limit_decide_structured answered for unusable input: %s\n' "${junk:-<empty>}"
    failures=$(( failures + 1 ))
  else
    printf 'ok   - unusable input (%s) is declined rather than guessed at\n' "${junk:-<empty>}"
  fi
done

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
  limit_decide_structured "{}" 3 >/dev/null
  limit_decide_structured "not json at all" 3 >/dev/null || true
  limit_probe_verdict "" "" >/dev/null
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
