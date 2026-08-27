#!/usr/bin/env bash
#
# test/item-text-fabrication.test.sh — regression test for `item_text_fault`
# and `item_text_supply` (requirement 17g, agent-ops#821, shape decided
# agent-ops#830 option (c)).
#
# Reproduces the #815 incident (cycle 20260826T064910Z-poetic-1-186841): a
# Co-Ordinator whose input had been trimmed to fit its model's window
# invented an `acceptance` in full — text requirement 17f's own check never
# catches, because 17f only asks whether the *recorded refinement* is
# present, never whether everything else in the order is real.
# `refinement_traceability_repair` logged the result a success anyway.
#
# `item_text_fault` closes that gap for a candidate whose entry was trimmed
# this cycle: it fetches the item's live full text fresh and faults an
# `acceptance` backtick span that text does not support. It deliberately does
# **not** check `context` — an earlier shape of this check did, and was
# blocked twice in review for faulting the Co-Ordinator's own mandated
# framing prose (TD-PPagop-26082801 tracks the deferred gap against #769).
# `item_text_supply` is `context`'s own answer instead: it appends the live
# text unconditionally so an incomplete `context` still leaves the
# Implementer starting from the whole item, whether or not it was checked.
#
# The functions are lifted verbatim out of lib/candidate-select.sh, the way
# test/refinement-traceability.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/item-text-fabrication.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"
CANDIDATE_SELECT="$SCRIPT_DIR/lib/candidate-select.sh"

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
assert_empty() { assert_eq "$1" "" "$2"; }
assert_nonempty() {
  local desc="$1" actual="$2"
  if [[ -n "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: <non-empty>\n     actual:   <empty>\n' "$desc"
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

# _traceability_normalize is a helper item_text_fault/item_text_supply call
# directly, so it has to be lifted too.
norm_block="$(extract_block '^_traceability_normalize\(\) \{' '^\}$' "$CANDIDATE_SELECT")"
if [[ -z "$norm_block" || "$norm_block" != *'jq'* ]]; then
  echo "FAIL - could not extract _traceability_normalize from lib/candidate-select.sh — has it moved?" >&2
  exit 1
fi
eval "$norm_block"

for fn in item_live_text item_text_fault item_text_supply; do
  block="$(extract_block "^${fn}\\(\\) \\{" '^\}$' "$CANDIDATE_SELECT")"
  if [[ -z "$block" ]]; then
    echo "FAIL - could not extract $fn from lib/candidate-select.sh — has it moved?" >&2
    exit 1
  fi
  eval "$block"
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
GH_CALLS_FILE="$T/gh_calls"
GH_LIVE_TEXT=""
GH_RC=0
# shellcheck disable=SC2317  # reached only from the lifted item_live_text block.
gh() {
  printf 'x' >>"$GH_CALLS_FILE"
  [[ "$GH_RC" == "0" ]] || return "$GH_RC"
  printf '%s' "$GH_LIVE_TEXT"
}
gh_calls() { [[ -f "$GH_CALLS_FILE" ]] && wc -c <"$GH_CALLS_FILE" | tr -d ' ' || printf '0'; }
reset_gh_calls() { rm -f "$GH_CALLS_FILE"; }

GUARD_WARN_CALLS_FILE="$T/guard_warn_calls"
# shellcheck disable=SC2317  # reached only from the lifted item_text_fault block.
guard_warn() { printf '%s\t%s\n' "$1" "$2" >>"$GUARD_WARN_CALLS_FILE"; }
guard_warn_calls() { [[ -f "$GUARD_WARN_CALLS_FILE" ]] && wc -l <"$GUARD_WARN_CALLS_FILE" | tr -d ' ' || printf '0'; }
reset_guard_warn_calls() { rm -f "$GUARD_WARN_CALLS_FILE"; }

trimmed='[{"repo":"o/r","item":"815","source":"issues"}]'
refinements='{}'

# --- Nothing to check: this item was not trimmed this cycle -------------------

reset_gh_calls
cand_untrimmed='{"repo":"o/r","item":"999","source":"issues","context":"anything, however wrong","acceptance":"anything"}'
assert_empty "an untrimmed candidate is not checked" \
  "$(item_text_fault "$cand_untrimmed" "$trimmed" "$refinements")"
assert_eq "…and costs no gh call" "0" "$(gh_calls)"

# --- context is not checked at all (agent-ops#830 option (c)): a paragraph ---
# invented wholesale, with nothing to do with the live item, does not fault
# the candidate on its own — only acceptance's backtick spans are checked.

reset_gh_calls
GH_LIVE_TEXT='Cycle 20260826T064910Z-poetic-1-186841 selected issue #815 for agent-ops, a Medium-priority Medium-complexity tech-debt item, and the Co-Ordinator input was trimmed to fit its model context window.'
cand_context_fabricated='{"repo":"o/r","item":"815","source":"issues",
  "context":"This paragraph describes acceptance criteria that were invented wholesale and never appeared anywhere in the real issue thread at all.",
  "acceptance":"ship it"}'
assert_empty "a wholly invented context paragraph does not fault the candidate — context is not checked" \
  "$(item_text_fault "$cand_context_fabricated" "$trimmed" "$refinements")"
assert_eq "…one gh read was still needed, to fetch the live text acceptance is checked against" "1" "$(gh_calls)"

# --- The #815 incident: a trimmed candidate's acceptance invents a specific ---
# that was never in the live item at all — fabricated, not merely reworded.

reset_gh_calls
# shellcheck disable=SC2016  # the backtick span is fixture JSON text, not a command substitution
cand_fabricated='{"repo":"o/r","item":"815","source":"issues",
  "context":"a short note about issue #815",
  "acceptance":"Add `_verify_stage_claims`, a subsystem this issue never actually names."}'
fault_fab="$(item_text_fault "$cand_fabricated" "$trimmed" "$refinements")"
assert_nonempty "a trimmed candidate's fabricated acceptance span is caught" "$fault_fab"
assert_eq "…exactly one gh read was needed" "1" "$(gh_calls)"

# --- The healthy case: the context paragraph really is the live text ----------

reset_gh_calls
cand_faithful='{"repo":"o/r","item":"815","source":"issues",
  "context":"Cycle 20260826T064910Z-poetic-1-186841 selected issue #815 for agent-ops, a Medium-priority Medium-complexity tech-debt item, and the Co-Ordinator input was trimmed to fit its model context window.",
  "acceptance":"fix the fabrication gap"}'
assert_empty "a context paragraph that really is the live text passes (unchecked, so it could not fault anyway)" \
  "$(item_text_fault "$cand_faithful" "$trimmed" "$refinements")"

# --- Acceptance: a faithful paraphrase in free prose is traceable -------------
# Deliberately weaker than a verbatim bar (agent-ops#821's own scope note):
# acceptance is allowed to be the Co-Ordinator's own synthesis, so only its
# backtick-quoted spans are checked, never its prose.

reset_gh_calls
cand_paraphrase='{"repo":"o/r","item":"815","source":"issues",
  "context":"Cycle 20260826T064910Z-poetic-1-186841 selected issue #815 for agent-ops, a Medium-priority Medium-complexity tech-debt item, and the Co-Ordinator input was trimmed to fit its model context window.",
  "acceptance":"Make sure the fabrication problem described in the issue thread is actually fixed, in whatever words best describe the change."}'
assert_empty "a faithful paraphrase in acceptance's free prose is traceable and never flagged" \
  "$(item_text_fault "$cand_paraphrase" "$trimmed" "$refinements")"

# --- Acceptance: an invented backtick-quoted specific is fabrication ----------

reset_gh_calls
# shellcheck disable=SC2016  # the backtick span is fixture JSON text, not a command substitution
cand_invented_span='{"repo":"o/r","item":"815","source":"issues",
  "context":"Cycle 20260826T064910Z-poetic-1-186841 selected issue #815 for agent-ops, a Medium-priority Medium-complexity tech-debt item, and the Co-Ordinator input was trimmed to fit its model context window.",
  "acceptance":"Add a new `refinement_policy_matrix` config key that this issue never actually names."}'
fault_span="$(item_text_fault "$cand_invented_span" "$trimmed" "$refinements")"
assert_nonempty "an invented backtick-quoted specific in acceptance is caught" "$fault_span"
assert_eq "…and the fault names the invented span" "1" \
  "$(grep -c 'refinement_policy_matrix' <<<"$fault_span")"

# --- Acceptance: a backtick span that really is in the live text passes -------

reset_gh_calls
# shellcheck disable=SC2016  # the backtick span is fixture JSON text, not a command substitution
cand_real_span='{"repo":"o/r","item":"815","source":"issues",
  "context":"Cycle 20260826T064910Z-poetic-1-186841 selected issue #815 for agent-ops, a Medium-priority Medium-complexity tech-debt item, and the Co-Ordinator input was trimmed to fit its model context window.",
  "acceptance":"Confirm `20260826T064910Z-poetic-1-186841` is the cycle this fix must be verified against."}'
assert_empty "a backtick span that really is in the live text passes" \
  "$(item_text_fault "$cand_real_span" "$trimmed" "$refinements")"

# --- A recorded refinement spec is also a legitimate source -------------------

reset_gh_calls
# shellcheck disable=SC2016  # the backtick span is fixture JSON text, not a command substitution
refinements_spec='{"o/r": {"815": {"ts": "t", "cycle": "c", "spec": "acceptance criteria written by the Refiner, verbatim, naming a `refinement_traceability_repair` change"}}}'
# shellcheck disable=SC2016  # the backtick span is fixture JSON text, not a command substitution
cand_from_spec='{"repo":"o/r","item":"815","source":"issues",
  "context":"Cycle 20260826T064910Z-poetic-1-186841 selected issue #815 for agent-ops, a Medium-priority Medium-complexity tech-debt item, and the Co-Ordinator input was trimmed to fit its model context window.",
  "acceptance":"Deliver `refinement_traceability_repair` exactly as the spec written by the Refiner describes."}'
assert_empty "content sourced from the recorded refinement spec (not the live text) also passes" \
  "$(item_text_fault "$cand_from_spec" "$trimmed" "$refinements_spec")"

# --- Never repaired: a fabrication fault survives even when item_text_supply --
# would otherwise happily append the live text alongside it.

reset_gh_calls
supplied="$(item_text_supply "$cand_fabricated" "$trimmed")"
assert_nonempty "item_text_supply still appends the live text" "$supplied"
still_faults="$(item_text_fault "$supplied" "$trimmed" "$refinements")"
assert_nonempty "…but the fabricated acceptance span is still there, so the candidate still faults — appending real text never repairs a false one" \
  "$still_faults"

# --- item_text_supply runs regardless of context, even a fabricated one -------
# Completeness (item_text_supply) is unconditional and separate from the
# acceptance-only fault check — a fabricated context is not gated, but it is
# still supplemented with the live text.

reset_gh_calls
supplied_context_fabricated="$(item_text_supply "$cand_context_fabricated" "$trimmed")"
assert_nonempty "item_text_supply appends the live text even to a candidate with a fabricated context" \
  "$supplied_context_fabricated"
assert_eq "…the live text landing in context, verbatim" "1" \
  "$(jq -r --arg b "$GH_LIVE_TEXT" 'if (.context | contains($b)) then 1 else 0 end' <<<"$supplied_context_fabricated")"

# --- item_text_supply: skip when context already carries the live text -------

reset_gh_calls
assert_empty "item_text_supply is a no-op when context already carries the live text in full" \
  "$(item_text_supply "$cand_faithful" "$trimmed")"

# --- item_text_supply: skip when this item was not trimmed --------------------

reset_gh_calls
assert_empty "item_text_supply does nothing for an untrimmed candidate" \
  "$(item_text_supply "$cand_untrimmed" "$trimmed")"
assert_eq "…and costs no gh call" "0" "$(gh_calls)"

# --- item_text_supply: the live text actually lands in context ----------------

reset_gh_calls
cand_incomplete='{"repo":"o/r","item":"815","source":"issues",
  "context":"a short, honest, but incomplete note about issue #815",
  "acceptance":"see the issue"}'
supplied_incomplete="$(item_text_supply "$cand_incomplete" "$trimmed")"
assert_nonempty "an honestly incomplete candidate is supplied the live text" "$supplied_incomplete"
assert_eq "…the live text landing in context, verbatim" "1" \
  "$(jq -r --arg b "$GH_LIVE_TEXT" 'if (.context | contains($b)) then 1 else 0 end' <<<"$supplied_incomplete")"
assert_eq "…without disturbing what the order already said" "1" \
  "$(jq -r 'if (.context | contains("a short, honest, but incomplete note")) and (.acceptance == "see the issue") then 1 else 0 end' <<<"$supplied_incomplete")"
assert_empty "…and the supplied candidate now passes the fault check" \
  "$(item_text_fault "$supplied_incomplete" "$trimmed" "$refinements")"

# --- Fail-closed on a network failure, and the failure is seen ----------------
# Same reasoning TD-PPagop-26082307 already established for requirement 17f:
# this check exists to confirm the live text really backs the work order, so
# a read it cannot complete must not read as a pass.

reset_gh_calls
reset_guard_warn_calls
GH_RC=1
fault_unreachable="$(item_text_fault "$cand_faithful" "$trimmed" "$refinements")"
assert_nonempty "an unreachable GitHub faults the candidate instead of passing it" "$fault_unreachable"
assert_eq "…and the failed read is reported via guard_warn" "1" "$(guard_warn_calls)"
GH_RC=0

reset_gh_calls
assert_empty "item_text_supply fails open (no supply, no crash) on the same unreachable read" \
  "$(GH_RC=1 item_text_supply "$cand_incomplete" "$trimmed")"

# --- Malformed/missing input degrades to no fault, never a crash --------------

assert_empty "a malformed trimmed-items document is treated as empty (nothing trimmed)" \
  "$(item_text_fault "$cand_fabricated" 'not json' "$refinements")"
assert_empty "a candidate missing repo/item is skipped" \
  "$(item_text_fault '{"context":"x"}' "$trimmed" "$refinements")"

# --- The claim loop wiring ------------------------------------------------------

loop_src="$(extract_block '^  c_fab_fault=""' '^  # Requirement 17f ' "$AGENT_CYCLE")"
# shellcheck disable=SC2016  # the literal source text is what is being matched
if [[ -n "$loop_src" && "$loop_src" == *'item_text_fault'* && "$loop_src" == *'selected_by_fallback'* \
      && "$loop_src" == *'cause: "fabricated"'* && "$loop_src" == *'fab_faults=$(( fab_faults + 1 ))'* ]]; then
  printf 'ok   - %s\n' "the claim loop checks item_text_fault before requirement 17f, guards it with selected_by_fallback, and counts fab_faults with cause \"fabricated\""
else
  printf 'FAIL - %s\n' "the claim loop does not wire item_text_fault the way this test expects — has it moved or changed shape?"
  failures=$(( failures + 1 ))
fi

if grep -q 'item_text_supply' "$AGENT_CYCLE"; then
  printf 'ok   - %s\n' "the claim loop calls item_text_supply after the traceability checks pass"
else
  printf 'FAIL - %s\n' "the claim loop never calls item_text_supply"
  failures=$(( failures + 1 ))
fi

if grep -q 'standdown_cause="fabricated"' "$AGENT_CYCLE"; then
  printf 'ok   - %s\n' "a fabrication stand-down has its own cause, distinct from untraceable and raced"
else
  printf 'FAIL - %s\n' "a cycle whose candidates all failed the fabrication check has no dedicated stand-down cause"
  failures=$(( failures + 1 ))
fi

# --- Requirement 17g's fault is never handed to refinement_traceability_repair,
# unlike requirement 17f's own — the claim loop must `continue` on a fabrication
# fault before it ever reaches the repair call.

fab_check_src="$(extract_block '^  c_fab_fault=""' '^  fi$' "$AGENT_CYCLE")"
if [[ "$fab_check_src" == *'continue'* && "$fab_check_src" != *'refinement_traceability_repair'* ]]; then
  printf 'ok   - %s\n' "a fabrication fault skips the candidate directly — it is never handed to the refinement repair"
else
  printf 'FAIL - %s\n' "a fabrication fault does not cleanly skip before the refinement repair runs"
  failures=$(( failures + 1 ))
fi

printf '\n%s\n' "$( (( failures == 0 )) && echo "All assertions passed." || echo "$failures assertion(s) failed." )"
exit $(( failures > 0 ))
