#!/usr/bin/env bash
#
# test/pr-label-claim-stamp.test.sh — regression test for agent-ops#956: the
# claim loop's winning-candidate stamp must write `pr_label` from the Script's
# own configured value, unconditionally, the same way it already writes
# `branch` — never trusting the Co-Ordinator's copy of the runtime input or
# `fallback_select_candidate`'s own composition to be present or correct.
#
# Before this fix, a claimed work order carried whatever `pr_label` (if any)
# the candidate already had, so a Co-Ordinator that omitted or mistyped the
# field raised a pull request no gatherer (`gather-review-feedback.sh`,
# `gather-abandoned-drafts.sh`, `gather-merge-conflicts.sh`,
# `gather-dequeued.sh`, `gather-human-visibility-hygiene.sh`,
# `scripts/sweep-closed-issues.sh`, `lib/merge-budget.sh`) could ever find
# again.
#
# The stamp lives inline in agent-cycle.sh's claim loop, not as a standalone
# function, so this test lifts the exact block whole (the same
# extract-and-eval approach test/item-text-fabrication.test.sh and
# test/refinement-traceability.test.sh use for their own inline blocks) and
# runs it for real, rather than merely grepping for the expected jq
# invocation.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/pr-label-claim-stamp.test.sh — exit 0 iff all passed.

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

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

# The claim loop's winning-candidate stamp: `if (( claim_rc == 0 )); then …
# claimed_json=… ; break; fi`. Lifted whole so the assertions below are about
# the shipped code, not a copy of its logic.
stamp_block="$(extract_block '^  if \(\( claim_rc == 0 \)\); then$' '^  fi$' "$AGENT_CYCLE")"
if [[ -z "$stamp_block" || "$stamp_block" != *'claimed_json='* ]]; then
  echo "FAIL - could not extract the claim loop's winning-candidate stamp from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if [[ "$stamp_block" != *'pr_label'* ]]; then
  echo "FAIL - the extracted stamp block never mentions pr_label — has the fix regressed or moved?" >&2
  exit 1
fi

# Run the lifted block for real, inside a one-shot loop so its own `break`
# behaves exactly as it does in the real claim loop.
run_stamp() {
  # shellcheck disable=SC2034  # read only by the eval'd stamp_block below
  claim_rc="$1"
  # shellcheck disable=SC2034  # read only by the eval'd stamp_block below
  c_branch="$2"
  # shellcheck disable=SC2034  # read only by the eval'd stamp_block below
  c_pr_key="$3"
  # shellcheck disable=SC2034  # read only by the eval'd stamp_block below
  cand="$4"
  # shellcheck disable=SC2034  # read only by the eval'd stamp_block below
  pr_label="$5"
  claim_active=0
  # shellcheck disable=SC2034  # set only by the eval'd stamp_block below
  claim_pr_key=""
  claimed_json=""
  # shellcheck disable=SC2043  # a one-shot loop so the block's own `break` behaves as it does live
  for _once in 1; do
    eval "$stamp_block"
  done
}

configured_label="autonomous-agent"

# --- A candidate with no pr_label at all gets the configured value ------------

run_stamp 0 "agent/956" "" '{"repo":"o/r","item":"956","source":"tech-debt"}' "$configured_label"
assert_eq "a candidate omitting pr_label is stamped with the configured value" \
  "$configured_label" "$(jq -r '.pr_label' <<<"$claimed_json")"
assert_eq "…and branch is still stamped alongside it" \
  "agent/956" "$(jq -r '.branch' <<<"$claimed_json")"
assert_eq "…and claim_active is set, same as before this change" "1" "$claim_active"

# --- A candidate carrying a wrong/stale pr_label is overridden, not trusted ---

run_stamp 0 "agent/956" "" '{"repo":"o/r","item":"956","source":"tech-debt","pr_label":"totally-wrong"}' "$configured_label"
assert_eq "a candidate carrying the wrong pr_label is overridden by the configured value" \
  "$configured_label" "$(jq -r '.pr_label' <<<"$claimed_json")"

# --- A candidate that happens to already carry the correct value is unaffected

run_stamp 0 "agent/956" "" "$(jq -nc --arg pl "$configured_label" '{repo:"o/r",item:"956",source:"tech-debt",pr_label:$pl}')" "$configured_label"
assert_eq "a candidate already carrying the configured value keeps it" \
  "$configured_label" "$(jq -r '.pr_label' <<<"$claimed_json")"

# --- A losing claim (claim_rc != 0) never runs the stamp at all ---------------

run_stamp 3 "agent/956" "" '{"repo":"o/r","item":"956","source":"tech-debt"}' "$configured_label"
assert_eq "a lost claim leaves claimed_json empty — the stamp never fires" \
  "" "$claimed_json"

printf '\n%s\n' "$( (( failures == 0 )) && echo "All assertions passed." || echo "$failures assertion(s) failed." )"
exit $(( failures > 0 ))
