#!/usr/bin/env bash
#
# test/standdown-chain.test.sh — regression tests for the stand-down block's
# chain-on-raced wiring (requirement 39/issue #304), lifted whole out of
# agent-cycle.sh the same way test/finish-then-continue.test.sh lifts the
# cleanup block: extracted rather than restated, so this cannot pass against
# a copy the script has since moved on from.
#
# test/chain.test.sh already exhaustively covers chain_should_continue as a
# pure function; test/finish-then-continue.test.sh covers cleanup()'s own
# chain-spawn decision once chain_eligible is set. This is the third leg: the
# stand-down block's own decision of *when* to set chain_eligible in the
# first place — only for standdown_cause "raced", and only within
# chain_should_continue's ordinary bounds, never for "unreachable" or
# "pre-claimed", and never on --once.
#
# No network and no GitHub. Run directly:
#
#   ./test/standdown-chain.test.sh
#
# Exit status is 0 iff every assertion passed.

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

# --- Extraction ------------------------------------------------------------
extract_block() {
  awk '
    /^if \[\[ -z "\$claimed_json" \]\]; then$/ { on = 1 }
    on                                         { print }
    on && /^fi$/                               { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh"
}
extract_function() {  # extract_function <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh"
}

block="$(extract_block)"
if [[ "$block" != *"standdown_cause_for"* ]]; then
  echo "FAIL - could not extract the stand-down block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
standdown_cause_for_src="$(extract_function standdown_cause_for)"
if [[ "$standdown_cause_for_src" != *"standdown_cause_for()"* ]]; then
  echo "FAIL - could not extract standdown_cause_for from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Assembly ----------------------------------------------------------------
# run_standdown DESC CLAIM_ATTEMPTS CLAIM_UNREACHABLE ONCE CHAIN_COUNT MAX_CHAINED \
#   ORDERED_REPOS_JSON RACE_LOSSES N_CAND
# Runs the extracted block in a subshell (it `exit 0`s on the standard path, so
# a subshell keeps that from ending the test script) and reports the state
# that survived to its EXIT trap — chain_eligible, standdown_cause and
# whether a stand-down event was logged.
run_standdown() {
  # race_losses and n_cand are read by $block below (eval'd, so shellcheck
  # cannot see the use) via the subshell's inherited local variables.
  # shellcheck disable=SC2034
  local desc="$1" attempts="$2" unreachable="$3" once="$4" count="$5" max="$6" \
        repos="$7" race_losses="$8" n_cand="$9" out
  out="$tmp_dir/$(printf '%s' "$desc" | tr -c 'A-Za-z0-9' '-').out"
  (
    set -uo pipefail
    # shellcheck disable=SC2034
    claim_attempts="$attempts" claim_unreachable="$unreachable" ONCE="$once" \
      chain_count="$count" max_chained_cycles="$max" ordered_repos_json="$repos" \
      claimed_json="" chain_eligible=0
    logged_events=""
    # shellcheck disable=SC2317
    log_event() { logged_events="${logged_events}${1};"; }
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/lib/chain.sh"
    eval "$standdown_cause_for_src"
    # standdown_cause is assigned inside $block below (eval'd, so shellcheck
    # cannot see it) before this trap ever fires.
    # shellcheck disable=SC2154
    trap 'printf "chain_eligible=%s standdown_cause=%s logged=%s\n" \
      "$chain_eligible" "${standdown_cause:-}" "$logged_events" > '"$(printf '%q' "$out")"'' EXIT
    eval "$block"
  ) >/dev/null 2>&1
  cat "$out" 2>/dev/null || echo "NO_OUTPUT"
}

one_source='[{"slug":"o/one","sources":["security"]}]'
no_sources='[{"slug":"o/one","sources":[]}]'

# --- pre-claimed: zero attempts, never chains ---------------------------------
out="$(run_standdown pre-claimed-never-chains 0 0 0 1 3 "$one_source" 0 2)"
assert_eq "zero attempts reads standdown_cause=pre-claimed" "1" \
  "$([[ "$out" == *"standdown_cause=pre-claimed"* ]] && echo 1 || echo 0)"
assert_eq "…and never sets chain_eligible, even with room in the lineage" "1" \
  "$([[ "$out" == *"chain_eligible=0"* ]] && echo 1 || echo 0)"
assert_eq "…but the stand-down is still logged" "1" \
  "$([[ "$out" == *"logged=stand-down"* ]] && echo 1 || echo 0)"

# --- unreachable: every attempt was an outage, never chains -------------------
out="$(run_standdown unreachable-never-chains 3 3 0 1 3 "$one_source" 0 3)"
assert_eq "every attempted candidate unreachable reads standdown_cause=unreachable" "1" \
  "$([[ "$out" == *"standdown_cause=unreachable"* ]] && echo 1 || echo 0)"
assert_eq "…and never chains — an outage means nobody could have pushed either" "1" \
  "$([[ "$out" == *"chain_eligible=0"* ]] && echo 1 || echo 0)"

# --- raced: genuine contention, chains when there is room ---------------------
out="$(run_standdown raced-chains-with-room 3 0 0 1 3 "$one_source" 3 3)"
assert_eq "every attempt lost to a peer reads standdown_cause=raced" "1" \
  "$([[ "$out" == *"standdown_cause=raced"* ]] && echo 1 || echo 0)"
assert_eq "…and chains, since the lineage has room and sources remain" "1" \
  "$([[ "$out" == *"chain_eligible=1"* ]] && echo 1 || echo 0)"

# --- raced, but --once: never chains -------------------------------------------
out="$(run_standdown raced-but-once 3 0 1 1 3 "$one_source" 3 3)"
assert_eq "a raced stand-down under --once never chains" "1" \
  "$([[ "$out" == *"chain_eligible=0"* ]] && echo 1 || echo 0)"

# --- raced, but the lineage is at its cap: never chains ------------------------
out="$(run_standdown raced-at-cap 3 0 0 3 3 "$one_source" 3 3)"
assert_eq "a raced stand-down at max_chained_cycles never chains" "1" \
  "$([[ "$out" == *"chain_eligible=0"* ]] && echo 1 || echo 0)"

# --- raced, but no sources remain anywhere: never chains -----------------------
out="$(run_standdown raced-no-sources 3 0 0 1 3 "$no_sources" 3 3)"
assert_eq "a raced stand-down with no sources left anywhere never chains" "1" \
  "$([[ "$out" == *"chain_eligible=0"* ]] && echo 1 || echo 0)"

# --- mixed: some pre-claim-skipped, some genuinely raced — still raced --------
# (claim_attempts counts only the attempted candidates; a mix of skipped and
# held-loss candidates is real contention, not a selection defect.)
out="$(run_standdown mixed-skip-and-raced 2 0 0 1 3 "$one_source" 2 4)"
assert_eq "a mix of pre-claim-skipped and genuinely lost candidates still reads raced" "1" \
  "$([[ "$out" == *"standdown_cause=raced"* ]] && echo 1 || echo 0)"
assert_eq "…and still chains" "1" \
  "$([[ "$out" == *"chain_eligible=1"* ]] && echo 1 || echo 0)"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
