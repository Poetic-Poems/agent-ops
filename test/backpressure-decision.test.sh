#!/usr/bin/env bash
#
# test/backpressure-decision.test.sh — regression test for requirement 2.2a's
# decision-site fold-in (agent-ops#459).
#
# Requirement 2.2a's own comment claims a conflicted or dequeued PR already
# holds a slot requirement 2.2's count counts. It does not: 2.2's count is
# taken before this cycle's merge-conflict and dequeued candidates are
# gathered, and neither gatherer's candidate rule reads `reviewDecision` at
# all (scripts/gather-merge-conflicts.sh, scripts/gather-dequeued.sh) — so
# such a PR passes through 2.2's count exactly like an ordinary human-queue
# PR unless it happens to also carry CHANGES_REQUESTED, which for a dequeued
# PR (only reachable after approval) is essentially never. The decision-site
# fold-in folds back in whatever `counted_prs_json` — 2.2's own record of
# which PRs its count held — does not already hold, before the trip is
# (re-)evaluated.
#
# This is not test/backpressure-wiring.test.sh's block: that one covers 2.2's
# own four-part sum. This one covers what happens next, at the decision site
# — a distinct seam with its own way to go wrong: silently under-counting a
# slot a human cannot clear, which opens a gate whose whole purpose is to
# stay shut.
#
# Lifted verbatim out of agent-cycle.sh, the same way
# test/backpressure-wiring.test.sh lifts its own block, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/backpressure-decision.test.sh — exit 0 iff all passed.

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

# --- Extraction ---------------------------------------------------------------

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

fold_block="$(extract_block '^finishing_extra_prs_json=' '^fi$' "$AGENT_CYCLE")"
if [[ -z "$fold_block" ]]; then
  echo "FAIL - could not extract the back-pressure decision fold-in block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ "$fold_block" != *'merge_conflicts'* || "$fold_block" != *'dequeued'* ]]; then
  echo "FAIL - the extracted block does not mention merge_conflicts/dequeued — the anchors have drifted" >&2
  exit 1
fi

# --- Run the lifted block ------------------------------------------------------
#
# Everything below `eval` is invisible to shellcheck, which is the point of
# lifting the block rather than copying it.
run_block() {
  local ordered="$1" counted="$2" adjusted="$3" max="$4" tripped="$5" composition="$6"
  # shellcheck disable=SC2317  # Called from the lifted block, on its failure-guard path.
  guard_warn() { :; }
  # shellcheck disable=SC2034  # Read by the lifted block: this cycle's gathered candidates...
  ordered_repos_json="$ordered"
  # shellcheck disable=SC2034  # ...requirement 2.2's own record of what it counted...
  counted_prs_json="$counted"
  adjusted_open_count="$adjusted"
  # shellcheck disable=SC2034  # ...the cap the fold-in re-checks the trip against...
  max_open_agent_prs="$max"
  backpressure_tripped="$tripped"
  open_composition="$composition"
  eval "$fold_block"
  # shellcheck disable=SC2154  # All four are assigned by the lifted block — they are what it is for.
  printf '%s\n%s\n%s\n%s\n' "$finishing_extra_count" "$adjusted_open_count" "$backpressure_tripped" "$open_composition"
}

read_out() {
  local out="$1" field="$2"
  case "$field" in
    extra) sed -n '1p' <<<"$out" ;;
    adjusted) sed -n '2p' <<<"$out" ;;
    tripped) sed -n '3p' <<<"$out" ;;
    composition) sed -n '4p' <<<"$out" ;;
  esac
}

# --- Nothing waiting: the fold-in is a no-op -----------------------------------

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[],"dequeued":[]}]' \
  '{}' 5 8 0 "1 changes-requested + 0 draft + 0 unraised claim(s) — plus 0 waiting on human (1 raw)")"
assert_eq "no merge-conflict/dequeued candidates: nothing added" "0" "$(read_out "$out" extra)"
assert_eq "…adjusted_open_count is untouched" "5" "$(read_out "$out" adjusted)"
assert_eq "…and the composition line is untouched" \
  "1 changes-requested + 0 draft + 0 unraised claim(s) — plus 0 waiting on human (1 raw)" "$(read_out "$out" composition)"
assert_eq "…and a cycle that had not tripped still has not" "0" "$(read_out "$out" tripped)"

# --- A conflicted PR already counted (it happened to be CHANGES_REQUESTED) ----

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[{"number":57}],"dequeued":[]}]' \
  '{"Poetic-Poems/agent-ops":[57]}' 5 8 0 "composition")"
assert_eq "a conflicted PR requirement 2.2's own count already held is not added again" "0" "$(read_out "$out" extra)"
assert_eq "…adjusted_open_count stays put" "5" "$(read_out "$out" adjusted)"

# --- A conflicted PR requirement 2.2's count did not hold ----------------------

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[{"number":57}],"dequeued":[]}]' \
  '{}' 5 8 0 "1 changes-requested + 0 draft + 0 unraised claim(s) — plus 4 waiting on human (5 raw)")"
assert_eq "a conflicted PR not already counted is folded in" "1" "$(read_out "$out" extra)"
assert_eq "…and adjusted_open_count grows by it" "6" "$(read_out "$out" adjusted)"
assert_eq "…without yet reaching the cap, the gate stays open" "0" "$(read_out "$out" tripped)"
assert_eq "…and the composition states what was added" \
  "1 changes-requested + 0 draft + 0 unraised claim(s) — plus 4 waiting on human (5 raw) + 1 merge-conflict/dequeued PR(s) occupying a slot the changes-requested count above did not" \
  "$(read_out "$out" composition)"

# --- The fold-in alone tips the trip -------------------------------------------

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[{"number":57}],"dequeued":[]}]' \
  '{}' 7 8 0 "composition")"
assert_eq "a fold-in that reaches the cap trips a gate 2.2 alone had not" "1" "$(read_out "$out" tripped)"

# --- A dequeued PR, same rule -------------------------------------------------

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[],"dequeued":[{"number":99}]}]' \
  '{}' 7 8 0 "composition")"
assert_eq "a dequeued PR not already counted trips the gate the same way" "1" "$(read_out "$out" tripped)"
assert_eq "…because it too is folded in" "1" "$(read_out "$out" extra)"

# --- The same PR in both arrays counts once -----------------------------------

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[{"number":57}],"dequeued":[{"number":57}]}]' \
  '{}' 5 8 0 "composition")"
assert_eq "the same PR number is not double-counted across merge_conflicts and dequeued" "1" "$(read_out "$out" extra)"

# --- Two repos, each contributing --------------------------------------------

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[{"number":57}],"dequeued":[]},
                    {"slug":"Poetic-Poems/poetic","merge_conflicts":[],"dequeued":[{"number":12}]}]' \
  '{}' 5 8 0 "composition")"
assert_eq "each repo's own candidates are folded in" "2" "$(read_out "$out" extra)"

# --- A PR number shared by two repos is not conflated -------------------------

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[{"number":57}],"dequeued":[]},
                    {"slug":"Poetic-Poems/poetic","merge_conflicts":[{"number":57}],"dequeued":[]}]' \
  '{"Poetic-Poems/agent-ops":[57]}' 5 8 0 "composition")"
assert_eq "the counted set is scoped per repo, not by PR number alone" "1" "$(read_out "$out" extra)"

# --- Already tripped, nothing new to fold in ----------------------------------

out="$(run_block '[{"slug":"Poetic-Poems/agent-ops","merge_conflicts":[],"dequeued":[]}]' \
  '{}' 9 8 1 "composition")"
assert_eq "an already-tripped gate with nothing to fold in stays tripped" "1" "$(read_out "$out" tripped)"
assert_eq "…and the composition is left alone" "composition" "$(read_out "$out" composition)"

# --- Report -------------------------------------------------------------------

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
