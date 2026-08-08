#!/usr/bin/env bash
#
# lib/chain.sh — finish-then-continue (requirement 39): whether a cycle that
# just won a claim should chain another selection cycle immediately, instead
# of waiting for the next cron firing.
#
# Sourced by agent-cycle.sh only; split out so the "is it worth chaining"
# question is a pure function of what the cycle already gathered, the same
# way lib/noop-skip.sh keeps "is it worth asking the Co-Ordinator again" pure
# and separately testable. Neither function predicts what a chained cycle
# will actually find — its own Co-Ordinator, its own fresh gather and its own
# no-op fingerprint answer that — this only decides whether asking again is
# cheap enough to be worth it.

# chain_sources_remain ORDERED_REPOS_JSON
# Print the total count of configured, non-excluded sources across every
# repo in the cycle's already-gathered `ordered_repos_json` (requirement
# 2.2a's back-pressure narrowing already applied). Zero means nothing is
# left for even a fresh Co-Ordinator to look at — back-pressure emptied
# every repo's `.sources`, the one shape that can happen this late, since a
# cycle reaching a won claim already passed every earlier stand-down.
#
# Deliberately not a prediction of *how much* work remains: `.sources` is a
# list of enabled categories, not a list of items, and staying that coarse is
# what keeps this cheap — the sources were already gathered this cycle, nothing
# further is fetched to answer this question.
chain_sources_remain() {
  local repos_json="$1" n
  n="$(jq '[.[].sources | length] | add // 0' <<<"$repos_json" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%d' "$n"
}

# chain_should_continue CHAIN_COUNT MAX_CHAINED_CYCLES ORDERED_REPOS_JSON
# Exit 0 (chain another cycle) iff this cycle's own place in its lineage
# (CHAIN_COUNT, 1 for the cron-fired original) is still under
# MAX_CHAINED_CYCLES *and* chain_sources_remain is non-zero. Exit 1
# otherwise — including on a non-numeric CHAIN_COUNT/MAX_CHAINED_CYCLES,
# which fails closed rather than chaining on a value that could not be
# trusted.
chain_should_continue() {
  local chain_count="$1" max="$2" repos_json="$3"
  [[ "$chain_count" =~ ^[0-9]+$ ]] || return 1
  [[ "$max" =~ ^[0-9]+$ ]] || return 1
  (( chain_count < max )) || return 1
  (( $(chain_sources_remain "$repos_json") > 0 ))
}
