#!/usr/bin/env bash
#
# test/gathered-repo-labels-wiring.test.sh — regression test for the
# per-gathered-repository label ensure agent-cycle.sh's main gather loop runs
# (requirement 6a, agent-ops#687): not whether labels_ensure_stamped itself is
# correct (test/labels.test.sh covers that) but whether the loop calls it with
# the right arguments, for every repository it gathers — not only the one the
# Co-Ordinator later selects — and logs `labels-ensured` only when there is
# something to report.
#
# This is the fix for the gap the issue calls out: the Co-Ordinator's own
# `needs_refinement`/`blocked` projection and the Refiner's `refined_label`
# projection both ran across every repository the cycle gathered data for,
# but the label ensure used to run only for the one repository selected to
# work — so a repository nobody had selected work in yet offered neither
# projection anywhere to land. Wiring this into the gather loop closes that;
# this test is what pins the wiring in place rather than the intent.
#
# The block is lifted verbatim out of agent-cycle.sh, the way
# test/backpressure-wiring.test.sh and test/void-retire-wiring.test.sh lift
# their own, so the assertions are about the shipped code rather than a copy
# of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gathered-repo-labels-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

# --- Lift the block whole out of agent-cycle.sh, by its own literal lines --
labels_block="$(awk '
  /^  gathered_labels_report=/ { on = 1 }
  on                           { print }
  on && /^  fi$/               { exit }
' "$AGENT_CYCLE")"
if [[ "$labels_block" != *'labels_ensure_stamped'* || "$labels_block" != *'labels-ensured'* ]]; then
  echo "FAIL - could not extract the gathered-repo label ensure from agent-cycle.sh (moved or reworded?)" >&2
  exit 1
fi

# --- Stub: labels_ensure_stamped, recording every call's argv --------------
call_log="$(mktemp)"
trap 'rm -f "$call_log"' EXIT
# shellcheck disable=SC2317  # invoked only by the eval'd labels_block
labels_ensure_stamped() { printf '%s\n' "$*" >> "$call_log"; printf '%s' "$stub_report"; }
# shellcheck disable=SC2317  # invoked only by the eval'd labels_block
log_event() { printf 'EVENT %s %s\n' "$1" "$2" >> "$call_log"; }

run_block() {  # <slug> <state_dir> <config_file> <schema_file> <interval> <stub_report>
  (
    # Every one of these is consumed only by the eval'd labels_block,
    # invisible to shellcheck.
    # shellcheck disable=SC2034
    slug="$1" state_dir="$2" CONFIG_FILE="$3" SCHEMA_FILE="$4" \
      labels_ensure_interval_hours="$5" stub_report="$6"
    eval "$labels_block"
  )
}

: > "$call_log"
run_block "o/r" "/state" "/cfg.json" "/schema.json" 24 "created	needs-refinement"
assert_eq "labels_ensure_stamped is called with state_dir, config, schema, the repo, role target and the interval" \
  "/state /cfg.json /schema.json o/r target 24" \
  "$(grep '^/state ' "$call_log")"
assert_eq "a non-empty report logs labels-ensured" "1" \
  "$(grep -c '^EVENT labels-ensured' "$call_log")"
assert_eq "  ... naming the repo and role target" "1" \
  "$(grep '^EVENT labels-ensured' "$call_log" | grep -c '"repo":"o/r".*"role":"target"\|"role":"target".*"repo":"o/r"')"
assert_eq "  ... with the created label named" "1" \
  "$(grep '^EVENT labels-ensured' "$call_log" | grep -c 'needs-refinement')"

: > "$call_log"
run_block "o/other" "/state" "/cfg.json" "/schema.json" 24 ""
assert_eq "a rate-limited (empty) report is called for exactly as any other repository" \
  "/state /cfg.json /schema.json o/other target 24" \
  "$(grep '^/state ' "$call_log")"
assert_eq "  ... but logs nothing at all — the steady state is silent" "0" \
  "$(grep -c '^EVENT' "$call_log")"

: > "$call_log"
run_block "o/second-repo" "/state" "/cfg.json" "/schema.json" 24 "failed	obsolete"
assert_eq "every gathered repository gets its own call — a second, different slug" \
  "/state /cfg.json /schema.json o/second-repo target 24" \
  "$(grep '^/state ' "$call_log")"
assert_eq "  ... and a failed create is logged too, not only created" "1" \
  "$(grep '^EVENT labels-ensured' "$call_log" | grep -c 'obsolete')"

echo
if (( failures == 0 )); then
  echo "All gathered-repo-labels-wiring assertions passed."
  exit 0
else
  echo "$failures gathered-repo-labels-wiring assertion(s) FAILED."
  exit 1
fi
