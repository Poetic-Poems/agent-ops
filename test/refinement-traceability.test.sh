#!/usr/bin/env bash
#
# test/refinement-traceability.test.sh — regression test for
# `refinement_traceability_fault` (requirement 17f, agent-ops#626).
#
# Reproduces the #571/#529 join fault: a work order for issue #571 was
# assembled carrying issue #529's own refinement comment content in its
# `acceptance` field instead of #571's own. The Co-Ordinator's response was
# syntactically fine and #571's candidate individually plausible, so nothing
# caught the cross-item swap until the Implementer — handed nothing but the
# mismatched work order — found it incoherent and burned the item's one
# refinement-per-human-touch allowance re-flagging it `needs-refinement`.
#
# `refinement_traceability_fault` closes that gap by re-deriving the item's
# own recorded refinement from `refinements-json` (never from anything the
# candidate itself claims) and confirming it is genuinely present, verbatim,
# in the candidate's own `context`/`acceptance`.
#
# The function is lifted verbatim out of agent-cycle.sh, the way
# test/coordinator-refinements.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/refinement-traceability.test.sh — exit 0 iff all passed.

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

fn_block="$(extract_block '^refinement_traceability_fault\(\) \{' '^\}$' "$AGENT_CYCLE")"
if [[ -z "$fn_block" || "$fn_block" != *'jq'* ]]; then
  echo "FAIL - could not extract refinement_traceability_fault from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
eval "$fn_block"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
GH_CALLS_FILE="$T/gh_calls"
GH_COMMENT_BODY=""
GH_RC=0
# Counted via a file, not a variable: every call site below invokes this
# function through `$( … )`, which forks a subshell — a plain variable
# increment inside `gh` would be lost the moment that subshell exits.
# shellcheck disable=SC2317  # reached only from the lifted refinement_traceability_fault block.
gh() {
  printf 'x' >>"$GH_CALLS_FILE"
  [[ "$GH_RC" == "0" ]] || return "$GH_RC"
  printf '%s' "$GH_COMMENT_BODY"
}
gh_calls() { [[ -f "$GH_CALLS_FILE" ]] && wc -c <"$GH_CALLS_FILE" | tr -d ' ' || printf '0'; }
reset_gh_calls() { rm -f "$GH_CALLS_FILE"; }

# --- The observed instance: #571's work order carrying #529's comment ---------
# refinements-json correctly names #571's own comment (a well-formed ledger
# entry — this reproduces the assembly-time swap, not a corrupted ledger).

refinements='{"o/r": {"571": {"ts": "t", "cycle": "c",
  "comment_url": "https://github.com/o/r/issues/571#issuecomment-5324678525"}}}'

# GH_COMMENT_BODY is #571's *own* refinement comment (what the real
# comment_url actually resolves to). The work order below instead carries
# #529's refinement content in `acceptance` — the observed defect — so it
# must not contain #571's own comment anywhere.
reset_gh_calls
GH_COMMENT_BODY='add a stage_models table to scripts/autonomy-stage-report.sh keyed by node and cycle'
cand_swapped='{"repo":"o/r","item":"571",
  "context":"Issue #571: scripts/autonomy-stage-report.sh\n\nComments:\nunrelated text",
  "acceptance":"stage_models pie charts using shortModel/spendByModel/windowedCostBreakdown/.costgrid"}'
fault_swapped="$(refinement_traceability_fault "$cand_swapped" "$refinements")"
assert_nonempty "the #571/#529 swap is caught: acceptance carries a foreign refinement comment" \
  "$fault_swapped"
assert_eq "exactly one gh api read was needed to catch it" "1" "$(gh_calls)"

# --- The healthy case: the item's own comment really is pasted in -------------

reset_gh_calls
GH_COMMENT_BODY='stage_models pie charts using shortModel/spendByModel/windowedCostBreakdown/.costgrid'
cand_ok='{"repo":"o/r","item":"571",
  "context":"Issue #571: scripts/autonomy-stage-report.sh\n\nComments:\nstage_models pie charts using shortModel/spendByModel/windowedCostBreakdown/.costgrid",
  "acceptance":"add the pie charts described in the comment above"}'
fault_ok="$(refinement_traceability_fault "$cand_ok" "$refinements")"
assert_empty "a work order that really does carry its own refinement comment passes" \
  "$fault_ok"

# The comment may legitimately land in `acceptance` alone (requirement 17b
# says "set acceptance from it") rather than duplicated into `context` too.
reset_gh_calls
cand_ok_acceptance='{"repo":"o/r","item":"571",
  "context":"Issue #571: scripts/autonomy-stage-report.sh",
  "acceptance":"stage_models pie charts using shortModel/spendByModel/windowedCostBreakdown/.costgrid"}'
assert_empty "the comment satisfies the check from acceptance alone, not just context" \
  "$(refinement_traceability_fault "$cand_ok_acceptance" "$refinements")"

# --- A comment_url naming a different issue than the candidate's own item -----
# Cheap enough to catch without any network read at all — a corrupted ledger
# entry, the other candidate locus this item names as plausible.

refinements_wrong_issue='{"o/r": {"571": {"ts": "t", "cycle": "c",
  "comment_url": "https://github.com/o/r/issues/529#issuecomment-1"}}}'
reset_gh_calls
fault_structural="$(refinement_traceability_fault "$cand_swapped" "$refinements_wrong_issue")"
assert_nonempty "a comment_url naming a different issue than item is a fault" \
  "$fault_structural"
assert_eq "the structural check needs no gh call at all" "0" "$(gh_calls)"

# --- A spec-carrying refinement (tech-debt, review, plan) ----------------------
# No network call is ever needed here: the spec text is already in
# refinements-json.

refinements_spec='{"o/r": {"TD1": {"ts": "t", "cycle": "c",
  "spec": "the refined specification, verbatim"}}}'
reset_gh_calls
cand_spec_missing='{"repo":"o/r","item":"TD1","context":"the original tech-debt body, nothing more"}'
assert_nonempty "a spec absent from context is a fault" \
  "$(refinement_traceability_fault "$cand_spec_missing" "$refinements_spec")"
assert_eq "the spec check needs no gh call" "0" "$(gh_calls)"

cand_spec_present='{"repo":"o/r","item":"TD1","context":"body\n\nthe refined specification, verbatim"}'
assert_empty "a spec pasted verbatim into context passes" \
  "$(refinement_traceability_fault "$cand_spec_present" "$refinements_spec")"

# --- Nothing to check: no recorded refinement for this item -------------------

reset_gh_calls
assert_empty "an item with no refinements entry at all is not checked" \
  "$(refinement_traceability_fault '{"repo":"o/r","item":"999","context":"anything"}' '{}')"
assert_eq "…and costs no gh call" "0" "$(gh_calls)"

reset_gh_calls
refinements_other_repo='{"o/other": {"571": {"ts": "t", "cycle": "c", "comment_url": "https://github.com/o/other/issues/571#issuecomment-1"}}}'
assert_empty "candidacy is scoped per repo — another repo's entry for the same item number does not apply" \
  "$(refinement_traceability_fault "$cand_swapped" "$refinements_other_repo")"
assert_eq "…and costs no gh call either" "0" "$(gh_calls)"

# --- Fail-open on a network failure --------------------------------------------
# A `gh` outage is a fact about GitHub's availability, not about the work
# order — every other degraded `gh` read in this pipeline fails open the
# same way (see gather-issues.sh's `degrade`), and a check that could not run
# must not read as a candidate that failed it.

reset_gh_calls
GH_RC=1
assert_empty "an unreachable GitHub fails open rather than faulting the candidate" \
  "$(refinement_traceability_fault "$cand_swapped" "$refinements")"
GH_RC=0

# --- Malformed input degrades to no fault, never a crash -----------------------

assert_empty "a malformed refinements document is treated as empty" \
  "$(refinement_traceability_fault "$cand_swapped" 'not json')"
assert_empty "a candidate missing repo/item is skipped" \
  "$(refinement_traceability_fault '{"context":"x"}' "$refinements")"

# --- The Script's own fallback pick is out of scope, and must stay so ---------
# `fallback_select_candidate` (requirement 3v) builds its one candidate in jq
# out of the very band entry it names, so it cannot cross-contaminate — but it
# composes `context` from that entry's own record and never from
# `refinements`, so a spec-refined item picked mechanically fails the verbatim
# check every time. Its candidate list is one candidate long, so faulting it
# would leave the cycle nothing to claim and disarm the only path that keeps
# the fleet moving when the model will not select. Both halves are asserted:
# that the fault is real (so the scoping is load-bearing, not decorative), and
# that the claim loop's own call site is guarded by `selected_by_fallback`.

fb_block="$(extract_block '^fallback_select_candidate\(\) \{' "^\}$" "$AGENT_CYCLE")"
if [[ -z "$fb_block" || "$fb_block" != *'jq'* ]]; then
  echo "FAIL - could not extract fallback_select_candidate from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
eval "$fb_block"

fb_repos='[{"slug": "o/r", "default_branch": "main", "sources": ["tech-debt"],
  "tech_debt": [{"ref": "TD1", "title": "a debt item", "body": "the tech-debt record body as filed"}]}]'
fb_cand="$(fallback_select_candidate "$fb_repos" "a-model" "$refinements_spec" '{"tech-debt": "required"}')"
assert_eq "the fallback really does pick the spec-refined item" "TD1"   "$(jq -r '.item // ""' <<<"$fb_cand")"
assert_nonempty "…and its script-built context does not satisfy the verbatim spec check"   "$(refinement_traceability_fault "$fb_cand" "$refinements_spec")"

claim_loop="$(extract_block '^  c_trace_fault=' '^  if \[\[ -n ' "$AGENT_CYCLE")"
if [[ "$claim_loop" == *'selected_by_fallback'* ]]; then
  printf 'ok   - %s\n' "the claim loop guards the check with selected_by_fallback, so a fallback pick is never faulted"
else
  printf 'FAIL - %s\n' "the claim loop calls refinement_traceability_fault unguarded — a fallback pick would be skipped and the cycle would claim nothing"
  failures=$(( failures + 1 ))
fi

# --- The repair half (issue #767) --------------------------------------------
# The check above asks whether the *model* copied the refinement across. In
# production it answered "no" 92 times across 20 issues and "yes" never, while
# the Script held the text the whole time. `refinement_traceability_repair`
# supplies it instead, which makes traceability true by construction. What
# these pin is the one thing that must not follow from that: the corrupt-
# ledger fault is still never repaired.

repair_block="$(extract_block '^refinement_traceability_repair\(\) \{' '^\}$' "$AGENT_CYCLE")"
if [[ -z "$repair_block" || "$repair_block" != *'jq'* ]]; then
  echo "FAIL - could not extract refinement_traceability_repair from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
eval "$repair_block"

# 1. The production case: a comment refinement the work order does not carry.
reset_gh_calls
GH_COMMENT_BODY='the refinement the Refiner wrote, in full, as a human would read it'
cand_missing='{"repo":"o/r","item":"571",
  "context":"Issue #571: a title\n\nComments:\nsomething else entirely",
  "acceptance":"resolve it"}'
repaired="$(refinement_traceability_repair "$cand_missing" "$refinements")"
assert_nonempty "a work order missing its refinement comment is repaired" "$repaired"
assert_eq "…and the repaired order then passes the check it just failed" "" \
  "$(refinement_traceability_fault "$repaired" "$refinements")"
assert_eq "…the comment landing in context, verbatim" "1" \
  "$(jq -r --arg b "$GH_COMMENT_BODY" 'if (.context | contains($b)) then 1 else 0 end' <<<"$repaired")"
assert_eq "…without disturbing what the order already said" "1" \
  "$(jq -r 'if (.context | contains("something else entirely")) and (.acceptance == "resolve it") then 1 else 0 end' <<<"$repaired")"

# 2. The corrupt-ledger case must NOT be repaired: the comment_url names a
#    different issue than the item it is filed under, so appending it would
#    write another issue's refinement into this one's order — precisely the
#    #626 defect. The fault stands and the caller skips.
reset_gh_calls
GH_COMMENT_BODY='a refinement belonging to some other issue'
assert_eq "a comment_url naming another issue is never repaired" "" \
  "$(refinement_traceability_repair "$cand_swapped" "$refinements_wrong_issue")"
assert_eq "…and no fetch is even attempted for it" "0" "$(gh_calls)"

# 3. A spec refinement absent from context is repaired the same way.
reset_gh_calls
cand_spec_bare='{"repo":"o/r","item":"TD1","context":"the tech-debt record body as filed","acceptance":"fix it"}'
repaired_spec="$(refinement_traceability_repair "$cand_spec_bare" "$refinements_spec")"
assert_nonempty "a work order missing its recorded spec is repaired" "$repaired_spec"
assert_eq "…and then passes" "" "$(refinement_traceability_fault "$repaired_spec" "$refinements_spec")"

# 4. An order that already carries its refinement is left completely alone —
#    the repair must never churn a candidate that was fine.
reset_gh_calls
GH_COMMENT_BODY='already pasted in full'
cand_already='{"repo":"o/r","item":"571","context":"Issue #571\n\nComments:\nalready pasted in full","acceptance":""}'
assert_eq "a compliant work order is not repaired" "" \
  "$(refinement_traceability_repair "$cand_already" "$refinements")"

# 5. An unreadable refinement leaves the candidate untouched, failing in the
#    same direction the check already fails.
reset_gh_calls
GH_RC=1
GH_COMMENT_BODY=''
assert_eq "an unreadable refinement comment is not repaired" "" \
  "$(refinement_traceability_repair "$cand_missing" "$refinements")"
GH_RC=0

# 6. The claim loop must actually attempt the repair before skipping, and must
#    count what it could not rescue separately — a cycle that dropped every
#    candidate on traceability reported `raced` for 15 hours because this
#    counter did not exist (issue #767).
loop_src="$(sed -n '/^  c_trace_fault=""/,/^  if candidate_preclaimed /p' "$AGENT_CYCLE")"
# shellcheck disable=SC2016  # the literal source text is what is being matched
if [[ "$loop_src" == *'refinement_traceability_repair'* && "$loop_src" == *'trace_faults=$(( trace_faults + 1 ))'* ]]; then
  printf 'ok   - %s\n' "the claim loop repairs before skipping, and counts an unrescued fault as its own kind"
else
  printf 'FAIL - %s\n' "the claim loop does not attempt a repair, or does not count trace faults separately"
  failures=$(( failures + 1 ))
fi
if grep -q 'standdown_cause="untraceable"' "$AGENT_CYCLE"; then
  printf 'ok   - %s\n' "a traceability stand-down has its own cause, and is never reported as raced"
else
  printf 'FAIL - %s\n' "a cycle whose candidates all failed traceability still falls through to the raced reason"
  failures=$(( failures + 1 ))
fi

printf '\n%s\n' "$( (( failures == 0 )) && echo "All assertions passed." || echo "$failures assertion(s) failed." )"
exit $(( failures > 0 ))
