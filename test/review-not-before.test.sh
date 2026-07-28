#!/usr/bin/env bash
#
# test/review-not-before.test.sh — `review.not_before` holds the weekly review
# off until a date, and nothing else off at all.
#
# The requirement it serves (R3.3) is one the switch cannot express. `--disable`
# is deliberately shared between both pipelines, so using it to hold a review
# back would stop the implementation cycles for the same window — and the case
# this exists for is precisely "no reviews until Thursday, but keep working".
#
# Four behaviours, and the last two are the ones that would fail quietly:
#
#   in force      a timestamp in the future stands the review down, and says so
#                 in the log with the date attached, so an operator reading
#                 `review-stand-down` can tell this apart from a switch
#   expired       a timestamp in the past is inert — the whole point of a
#                 timestamp over a raised `min_days_between_reviews` is that it
#                 needs no undoing, and a stand-down that outlived its date
#                 would be the throttle-left-on failure wearing a new hat
#   absent        no key, or an empty one, is not a stand-down. The key is
#                 optional and most nodes will never set it
#   unparseable   stands down rather than running. The operator plainly meant
#                 to hold reviews off; running through a value we could not
#                 read would spend exactly the quota they were protecting
#
# Each case runs the real `review-cycle.sh` against a shim node: a directory of
# symlinks back into the tree with its own `config.json`, which works because
# the script takes SCRIPT_DIR from its own path and reads config from there.
# `review.repos` is emptied so a run that is *not* stood down still finishes
# without reaching for the network.
#
# No network. Run directly: ./test/review-not-before.test.sh — exit 0 iff all
# passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# A shim node: symlinks back into the tree, plus a config of its own. `$1` is a
# jq filter applied to the real config, so each case states only its difference
# and every other required key stays in step with the shipped file.
make_node() {  # make_node <name> <jq-filter> -> prints its directory
  # Separate statements on purpose: `local a=… b="$a"` expands every argument
  # before assigning any, so the second would read an unset `a` under `set -u`.
  local name="$1" filter="$2"
  local dir="$tmp_dir/$name"
  mkdir -p "$dir" "$dir/home"
  local item
  for item in lib prompts scripts .claude review-cycle.sh agent-cycle.sh; do
    [[ -e "$SCRIPT_DIR/$item" ]] && ln -s "$SCRIPT_DIR/$item" "$dir/$item"
  done
  jq "$filter" "$SCRIPT_DIR/config.json" > "$dir/config.json"
  printf '%s' "$dir"
}

# Prints stdout+stderr and leaves the exit status in RC. A stand-down must end
# 0: supercronic reports a non-zero tick as a failed job, so a pipeline that
# held itself back correctly would page as though it had broken — the same
# shape of bug as the dashboard launcher's exit status (publish-dashboard).
RC=0
run_review() {  # run_review <dir> -> prints stdout+stderr, sets RC
  local dir="$1" out
  out="$(env HOME="$dir/home" AGENT_OPS_ROLE=active \
    timeout 60 "$dir/review-cycle.sh" --once 2>&1)"
  RC=$?
  printf '%s' "$out"
}

events_of() {  # events_of <dir> -> the review log, one JSON object per line
  cat "$1/home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null || true
}

stand_down_reason() {  # stand_down_reason <dir>
  events_of "$1" | jq -r 'select(.event == "review-stand-down") | .reason' 2>/dev/null || true
}

# `repos: []` keeps a non-stood-down run offline; `state_repo: ""` keeps the
# fleet switch from reaching for one.
BASE='.review.repos = [] | .state_repo = ""'

# --- In force --------------------------------------------------------------------
d="$(make_node in-force "$BASE | .review.not_before = \"2099-01-01T00:00:00Z\"")"
out="$(run_review "$d")"
assert_contains "a future not_before stands the review down" \
  "standing down until 2099-01-01T00:00:00Z" "$out"
assert_contains "and the log says which rule did it" \
  "review.not_before: no review before 2099-01-01T00:00:00Z" "$(stand_down_reason "$d")"
assert_eq "with the date on the event, for the dashboard to read" "2099-01-01T00:00:00Z" \
  "$(events_of "$d" | jq -r 'select(.event == "review-stand-down") | .not_before' 2>/dev/null)"
assert_eq "and the tick still ends 0, so cron does not call it a failure" "0" "$RC"

# --- Expired ---------------------------------------------------------------------
# The property that distinguishes this from raising min_days_between_reviews:
# nothing has to be put back by hand once the date passes.
d="$(make_node expired "$BASE | .review.not_before = \"2000-01-01T00:00:00Z\"")"
out="$(run_review "$d")"
assert_lacks "a past not_before does not stand the review down" "standing down until" "$out"
assert_lacks "and leaves no stand-down of its own in the log" \
  "review.not_before" "$(stand_down_reason "$d")"

# --- Absent ----------------------------------------------------------------------
d="$(make_node absent "$BASE | del(.review.not_before)")"
out="$(run_review "$d")"
assert_lacks "an absent key is not a stand-down" "standing down until" "$out"
assert_lacks "nor is it reported as one" "review.not_before" "$(stand_down_reason "$d")"

d="$(make_node empty "$BASE | .review.not_before = \"\"")"
out="$(run_review "$d")"
assert_lacks "and neither is an empty one" "standing down until" "$out"

# --- Unparseable -----------------------------------------------------------------
# Fails towards the operator's evident intent, not through it.
d="$(make_node unparseable "$BASE | .review.not_before = \"next Thursday-ish\"")"
out="$(run_review "$d")"
assert_contains "an unparseable not_before stands down rather than running" \
  "not a date this system can parse" "$out"
assert_contains "and the log names the value, so it can be corrected" \
  "next Thursday-ish" "$(stand_down_reason "$d")"
assert_eq "and this one ends 0 too — a bad value is not a crash" "0" "$RC"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
