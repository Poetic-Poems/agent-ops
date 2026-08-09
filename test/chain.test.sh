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
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/chain.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/chain.sh
. "$SCRIPT_DIR/lib/chain.sh"

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

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
