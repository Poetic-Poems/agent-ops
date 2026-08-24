#!/usr/bin/env bash
#
# test/gathered-repo-labels-wiring.test.sh — regression test for the
# per-gathered-repository label ensure agent-cycle.sh's main gather loop runs
# (requirement 6a, agent-ops#687): not whether labels_ensure_stamped itself is
# correct (test/labels.test.sh covers that) but whether the loop calls it with
# the right arguments, for every repository it gathers — not only the one the
# Co-Ordinator later selects — and logs `labels-ensured` only when there is
# something to report. Alongside it, that agent-cycle.sh actually installs the
# `REFINEMENT_LABEL_ENSURE` hook lib/refinement.sh's self-heal retries through,
# which is a wiring question of exactly the same kind: the retry is
# unreachable in the shipped pipeline unless some file sets the variable, and
# lib/refinement.sh's own tests can only prove the retry works when it is set.
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
CANDIDATE_GATHER="$SCRIPT_DIR/lib/candidate-gather.sh"

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
' "$CANDIDATE_GATHER")"
if [[ "$labels_block" != *'labels_ensure_stamped'* || "$labels_block" != *'labels-ensured'* ]]; then
  echo "FAIL - could not extract the gathered-repo label ensure from lib/candidate-gather.sh (moved or reworded?)" >&2
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

# --- The self-heal hook agent-cycle.sh installs (requirement 6a, #687) ------
# lib/refinement.sh calls "$REFINEMENT_LABEL_ENSURE" REPO LABEL when an add
# fails; nothing retries at all unless a caller sets it. Lift both the
# assignment and the function it names, so this pins the wiring rather than the
# intention.
hook_name="$(awk -F= '/^REFINEMENT_LABEL_ENSURE=/ { print $2; exit }' "$AGENT_CYCLE")"
assert_eq "agent-cycle.sh sets REFINEMENT_LABEL_ENSURE" "refinement_label_ensure_one" "$hook_name"

hook_block="$(awk -v fn="$hook_name" '
  $0 == fn "() {" { on = 1 }
  on              { print }
  on && /^\}$/    { exit }
' "$AGENT_CYCLE")"
if [[ -z "$hook_block" ]]; then
  echo "FAIL - agent-cycle.sh names $hook_name but does not define it" >&2
  exit 1
fi

# Stubs: the catalogue carries one label, and labels_ensure_one records argv.
# shellcheck disable=SC2317  # invoked only by the eval'd hook_block
labels_catalogue() { printf 'refined\t0e8a16\tThe Refiner has written this a specification\n'; }
# shellcheck disable=SC2317  # invoked only by the eval'd hook_block
labels_ensure_one() { printf '%s\n' "$*" >> "$call_log"; printf 'created'; }
# Read only by the eval'd hook_block, invisible to shellcheck.
# shellcheck disable=SC2034
CONFIG_FILE=/cfg.json SCHEMA_FILE=/schema.json
eval "$hook_block"

: > "$call_log"
"$hook_name" "o/r" refined
assert_eq "a catalogue label is created with the catalogue's own colour and description" \
  "o/r refined 0e8a16 The Refiner has written this a specification" \
  "$(cat "$call_log")"

: > "$call_log"
"$hook_name" "o/r" some-other-label
assert_eq "a label the catalogue does not carry still gets created, on the neutral defaults" \
  "o/r some-other-label" "$(cat "$call_log")"

echo
if (( failures == 0 )); then
  echo "All gathered-repo-labels-wiring assertions passed."
  exit 0
else
  echo "$failures gathered-repo-labels-wiring assertion(s) FAILED."
  exit 1
fi
