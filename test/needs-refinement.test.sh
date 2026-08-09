#!/usr/bin/env bash
#
# test/needs-refinement.test.sh — regression test for the refinement class:
# lib/refinement.sh plus the two log extracts it depends on in
# lib/cycle-state.sh (requirements 16a, 34e, 34g, 35d, 36b and 3h).
#
# The defect this closes was a silence. An item the Co-Ordinator could not rank
# — no acceptance criteria, no scope bound, or waiting on a decision only the
# human can take — was skipped, and nothing was recorded. The next cycle read it
# and skipped it. So did every cycle after that, for as long as the item
# existed: a per-hour charge for rediscovering the same non-answer, an item with
# no route to ever becoming selectable, and a human who was never told any of it
# was happening. Nothing looked broken.
#
# So the rules below are asserted in both directions throughout, because both
# failures are silent and they cost differently:
#
#   - too shy — a report dropped, a block not recorded, an item over the
#     engagement cap that never comes back — and the item starves exactly as it
#     did before this existed;
#   - too eager — a re-report that resets the Enabler threshold every cycle, a
#     second refinement of an item an expensive model already specified — and
#     the pipeline spends real money going round in a circle, while every event
#     in the log reads like progress.
#
# `gh` is stubbed through REFINEMENT_GH. No test framework is used (none exists
# elsewhere in this repo). Run it directly:
#
#   ./test/needs-refinement.test.sh
#
# Exit status is 0 iff every assertion passed.

# The `eligible` helper below takes its threshold and window as optional
# arguments (`${1:-3}`, `${2:-0}`), so most calls pass none and read as the
# default case — which is the point. shellcheck reads a function that names $1
# and is called bare as a mistake in one direction or the other; here it is
# neither.
# shellcheck disable=SC2119,SC2120

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- The stub ------------------------------------------------------------------
# `gh issue edit <n> -R <slug> --add-label|--remove-label <label>` appends one
# line to $tmp_dir/label-calls and succeeds, unless the label is named in
# $tmp_dir/missing-labels — a repo where the label was never created, which is
# the failure the Script has to survive rather than treat as a lost block.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
# `issue view <n> -R <slug> --json assignees --jq ...` serves the logins in
# $tmp_dir/issue-assignees, one per line; $tmp_dir/view-fail makes it fail —
# the read refinement_assignee_project has to survive without ever recording.
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  [[ -f "$d/view-fail" ]] && exit 1
  cat "$d/issue-assignees" 2>/dev/null
  exit 0
fi
[[ "$1" == "issue" && "$2" == "edit" ]] || exit 1
number="$3"; shift 3
repo=""; action=""; label=""; assignee=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) repo="$2"; shift 2 ;;
    --add-label) action="add"; label="$2"; shift 2 ;;
    --remove-label) action="remove"; label="$2"; shift 2 ;;
    --add-assignee) action="assign"; assignee="$2"; shift 2 ;;
    --remove-assignee) action="unassign"; assignee="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$label" ]]; then
  if [[ -f "$d/missing-labels" ]] && grep -qxF "$label" "$d/missing-labels"; then
    echo "could not add label: '$label' not found" >&2
    exit 1
  fi
  printf '%s %s %s %s\n' "$action" "$repo" "$number" "$label" >> "$d/label-calls"
fi
if [[ -n "$assignee" ]]; then
  if [[ -f "$d/missing-assignees" ]] && grep -qxF "$assignee" "$d/missing-assignees"; then
    echo "could not assign: '$assignee' is not a collaborator" >&2
    exit 1
  fi
  printf '%s %s %s %s\n' "$action" "$repo" "$number" "$assignee" >> "$d/assignee-calls"
fi
STUB
chmod +x "$tmp_dir/gh"
export REFINEMENT_GH="$tmp_dir/gh"

label_calls() { cat "$tmp_dir/label-calls" 2>/dev/null || true; }
reset_calls() { rm -f "$tmp_dir/label-calls"; }
assignee_calls() { cat "$tmp_dir/assignee-calls" 2>/dev/null || true; }
reset_assignee_calls() { rm -f "$tmp_dir/assignee-calls"; }

log="$tmp_dir/log.jsonl"
now="$(date -u -d '2026-07-25T12:00:00Z' +%s)"

# --- Requirement 16a: what a report must carry to be recorded -------------------
# Every field is what somebody downstream reads: `missing` is the Enabler's whole
# brief, `evidence` is what separates a finding from an opinion (the discipline
# requirement 34d imposes on a void, applied here), and `repo`+`item` are the key
# requirement 34 blocks on. A model asked for a field will fill it with
# something, so the empty container has to fail as loudly as the absent one.

good='{"repo": "o/r", "item": "TD26071901", "source": "tech-debt",
       "reason": "no acceptance criteria: \"tidy up the sync script\" names no end state",
       "missing": "a scope bound and acceptance criteria",
       "evidence": "TECH-DEBT.md@main row TD26071901, read in full"}'

out="$(refinement_entry_problem "$good")"; rc=$?
assert_eq "a complete report is recorded" "0" "$rc"
assert_eq "  ... silently" "" "$out"

for field in repo item reason missing evidence; do
  entry="$(jq -c --arg f "$field" 'del(.[$f])' <<<"$good")"
  out="$(refinement_entry_problem "$entry")"; rc=$?
  assert_eq "a report with no $field is dropped" "1" "$rc"
  assert_eq "  ... with a reason that names what it is short of" \
    "1" "$([[ -n "$out" ]] && echo 1 || echo 0)"
done

assert_eq "an empty string is not a filled-in field" "1" \
  "$(refinement_entry_problem "$(jq -c '.evidence = ""' <<<"$good")" >/dev/null; echo $?)"
assert_eq "whitespace is not either" "1" \
  "$(refinement_entry_problem "$(jq -c '.missing = "   "' <<<"$good")" >/dev/null; echo $?)"
assert_eq "nor is an empty container" "1" \
  "$(refinement_entry_problem "$(jq -c '.evidence = []' <<<"$good")" >/dev/null; echo $?)"
out="$(refinement_entry_problem "$(jq -c 'del(.evidence)' <<<"$good")")"
assert_contains "the evidence refusal says why evidence is the bar" "opinion" "$out"

# --- Requirement 34e: the block the Script writes -------------------------------
# The marker is what every later reader distinguishes this class by, and
# `missing` becomes `unblock_condition` because that is the field a later
# Co-Ordinator (requirement 18) and the Enabler both read to decide whether the
# item has become selectable. Losing that promotion would leave the class
# recorded but unactionable.

fields="$(refinement_block_fields "$good")"
assert_eq "the block is marked as a refinement" "needs-refinement" \
  "$(jq -r '.kind' <<<"$fields")"
assert_eq "and carries missing as the unblock condition" \
  "a scope bound and acceptance criteria" "$(jq -r '.unblock_condition' <<<"$fields")"
assert_eq "and the evidence the report cited" \
  "TECH-DEBT.md@main row TD26071901, read in full" "$(jq -r '.evidence' <<<"$fields")"
assert_eq "and the source it came from" "tech-debt" "$(jq -r '.source' <<<"$fields")"
assert_eq "a block with no label projected records none" "null" \
  "$(jq -r '.needs_refinement_label // "null"' <<<"$fields")"
assert_eq "a block with one records which label it applied" "needs-refinement" \
  "$(jq -r '.needs_refinement_label' <<<"$(refinement_block_fields "$good" needs-refinement)")"

# --- Requirement 34e: the label reaches issues and nothing else -----------------
# The projection can only ever reach the `issues` source; every other item type
# is a register row, a recommendation, a plan task or a finding, with nowhere to
# put a label. Labelling by ref shape alone would be worse than not labelling:
# it would put the pipeline's state on whichever issue happened to share a
# number with a tech-debt id.

issue_entry='{"repo": "o/r", "item": "52", "source": "issues",
              "reason": "the ask is a question, not a task",
              "missing": "acceptance criteria for what a fixed 500 looks like",
              "evidence": "issue 52 body and all four comments"}'

assert_eq "an issue item is labelled" "52" "$(refinement_issue_number "$issue_entry")"
assert_eq "a tech-debt item is not" "" "$(refinement_issue_number "$good")"
assert_eq "nor is a review recommendation" "" \
  "$(refinement_issue_number '{"item": "review-2026-07-21-R-04", "source": "project-review"}')"
assert_eq "nor a finding whose ref merely contains digits" "" \
  "$(refinement_issue_number '{"item": "dependabot-alert-42", "source": "security"}')"
assert_eq "an entry naming no source is judged on the ref's shape" "52" \
  "$(refinement_issue_number '{"item": "52"}')"

reset_calls
assert_eq "applying the label succeeds" "0" \
  "$(refinement_label_add "o/r" 52 needs-refinement; echo $?)"
assert_eq "  ... through one gh call" "add o/r 52 needs-refinement" "$(label_calls)"

# A repo where the label has never been created must still get its block. The
# Script records the failure and carries on; the projection is a courtesy, the
# log is the record.
printf 'needs-refinement\n' >"$tmp_dir/missing-labels"
assert_eq "a label the repo does not have fails rather than silently passing" "1" \
  "$(refinement_label_add "o/r" 52 needs-refinement; echo $?)"
rm -f "$tmp_dir/missing-labels"

# --- Requirement 34e: the label comes off when the block clears -----------------
# Removal is driven from the block record, not from config, so the Script can
# only ever remove a label it recorded applying. `blocked_items` is the extract
# it reads, which is what makes the label's lifecycle mirror the block's by
# construction rather than by two pieces of code agreeing.

cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","kind":"needs-refinement","detail":"no acceptance criteria","unblock_condition":"acceptance criteria","needs_refinement_label":"needs-refinement"}
{"ts":"2026-07-22T09:00:01Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD26071901","kind":"needs-refinement","detail":"no scope bound","unblock_condition":"a scope bound"}
{"ts":"2026-07-22T09:00:02Z","cycle":"c0","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"77","detail":"needs a repo secret"}
EOF
blocked="$(blocked_items "$log")"

assert_eq "the labelled issue is found for removal" \
  "$(printf 'o/r\t52\tneeds-refinement')" \
  "$(refinement_label_targets "$blocked" 52)"
assert_eq "a refinement block that never got a label has nothing to remove" "" \
  "$(refinement_label_targets "$blocked" TD26071901)"
assert_eq "an ordinary block is not touched" "" \
  "$(refinement_label_targets "$blocked" 77)"
assert_eq "a repo-scoped clear matches its own repo" \
  "$(printf 'o/r\t52\tneeds-refinement')" \
  "$(refinement_label_targets "$blocked" 52 "o/r")"
assert_eq "and not another repo's identically-numbered issue" "" \
  "$(refinement_label_targets "$blocked" 52 "o/other")"

reset_calls
while IFS=$'\t' read -r t_repo t_num t_label; do
  refinement_label_remove "$t_repo" "$t_num" "$t_label"
done < <(refinement_label_targets "$blocked" 52 "o/r")
assert_eq "clearing the block takes the label off" "remove o/r 52 needs-refinement" "$(label_calls)"

# An `unblocked` retires the block, so the *next* cycle finds nothing to remove
# — the removal happens on the cycle that clears it, against the extract taken
# before the Co-Ordinator ran, which is the only extract that still holds it.
printf '%s\n' '{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"unblocked","item":"52"}' >> "$log"
assert_eq "once cleared, a later cycle has no label to chase" "" \
  "$(refinement_label_targets "$(blocked_items "$log")" 52)"

# A void does not clear an attempt-failed, so the item is still in the extract
# when the void is recorded — which is exactly why the void path can (and must)
# remove the label from the same targets.
cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","kind":"needs-refinement","detail":"no acceptance criteria","unblock_condition":"acceptance criteria","needs_refinement_label":"needs-refinement"}
{"ts":"2026-07-23T09:00:00Z","cycle":"c4","event":"item-void","stage":"enabler","repo":"o/r","item":"52","detail":"already done on main","evidence":"main@aad1405"}
EOF
assert_eq "a voided item's label is still findable, so it can be taken off" \
  "$(printf 'o/r\t52\tneeds-refinement')" \
  "$(refinement_label_targets "$(blocked_items "$log")" 52 "o/r")"

# --- Requirement 38b: the same projection, for the assignment -------------------
# agent-ops#203 was labelled correctly and still invisible: a human's
# Assigned-to-me dashboard has nothing to do with a label. The assignment
# mirrors the label's lifecycle exactly — applied when the block is recorded,
# removed when it clears — read from its own field so the Script never removes
# an assignment it did not make.

fields="$(refinement_block_fields "$good" "" "octocat")"
assert_eq "a block with no assignee arg records none" "null" \
  "$(jq -r '.needs_refinement_assignee // "null"' <<<"$(refinement_block_fields "$good")")"
assert_eq "a block given one records who it assigned" "octocat" \
  "$(jq -r '.needs_refinement_assignee' <<<"$fields")"
assert_eq "label and assignee are independent fields on the same block" \
  "needs-refinement octocat" \
  "$(jq -r '"\(.needs_refinement_label) \(.needs_refinement_assignee)"' \
     <<<"$(refinement_block_fields "$good" needs-refinement octocat)")"

reset_assignee_calls
assert_eq "assigning the issue succeeds" "0" \
  "$(refinement_assignee_add "o/r" 52 octocat; echo $?)"
assert_eq "  ... through one gh call" "assign o/r 52 octocat" "$(assignee_calls)"

printf 'octocat\n' >"$tmp_dir/missing-assignees"
assert_eq "an assignee who is not a collaborator fails rather than silently passing" "1" \
  "$(refinement_assignee_add "o/r" 52 octocat; echo $?)"
rm -f "$tmp_dir/missing-assignees"

# --- The projection reads before it writes (requirement 38b) --------------------
# `gh issue edit --add-assignee` is a no-op-success on an issue already
# assigned, so `refinement_assignee_project` reads the assignee list first: a
# pre-existing assignment — the human's own, made for their own reasons — is
# `present`, untouched and unrecorded, and clearing the block later never
# takes it off. Only an assignment the projection itself added is `added`,
# i.e. the caller's to record and the clearing's to remove.
reset_assignee_calls
rm -f "$tmp_dir/issue-assignees" "$tmp_dir/view-fail"
assert_eq "an unassigned issue is assigned and recorded" "added" \
  "$(refinement_assignee_project "o/r" 52 octocat)"
assert_eq "  ... through one gh edit call" "assign o/r 52 octocat" "$(assignee_calls)"

reset_assignee_calls
printf 'octocat\n' >"$tmp_dir/issue-assignees"
assert_eq "a pre-existing assignment is present, not re-added" "present" \
  "$(refinement_assignee_project "o/r" 52 octocat)"
assert_eq "  ... and nothing is edited at all" "" "$(assignee_calls)"

reset_assignee_calls
printf 'someone-else\n' >"$tmp_dir/issue-assignees"
assert_eq "someone else's assignment does not mask the add" "added" \
  "$(refinement_assignee_project "o/r" 52 octocat)"
assert_eq "  ... which still happens" "assign o/r 52 octocat" "$(assignee_calls)"

reset_assignee_calls
rm -f "$tmp_dir/issue-assignees"
printf x >"$tmp_dir/view-fail"
assert_eq "an unreadable assignee list is applied best-effort but never recorded" \
  "unrecorded" "$(refinement_assignee_project "o/r" 52 octocat)"
assert_eq "  ... the best-effort add still reaches the issue" \
  "assign o/r 52 octocat" "$(assignee_calls)"
rm -f "$tmp_dir/view-fail"

printf 'octocat\n' >"$tmp_dir/missing-assignees"
rm -f "$tmp_dir/issue-assignees"
assert_eq "a non-collaborator fails the projection as it fails the add" "failed" \
  "$(refinement_assignee_project "o/r" 52 octocat)"
rm -f "$tmp_dir/missing-assignees"

cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","kind":"needs-refinement","detail":"gated on a decision","unblock_condition":"which packaging approach","needs_refinement_label":"needs-refinement","needs_refinement_assignee":"octocat"}
{"ts":"2026-07-22T09:00:01Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD26071901","kind":"needs-refinement","detail":"no scope bound","unblock_condition":"a scope bound"}
EOF
blocked="$(blocked_items "$log")"
assert_eq "the assigned issue is found for removal" \
  "$(printf 'o/r\t52\toctocat')" \
  "$(refinement_assignee_targets "$blocked" 52)"
assert_eq "a refinement block that was never assigned has nothing to remove" "" \
  "$(refinement_assignee_targets "$blocked" TD26071901)"
assert_eq "a repo-scoped clear matches its own repo" \
  "$(printf 'o/r\t52\toctocat')" \
  "$(refinement_assignee_targets "$blocked" 52 "o/r")"
assert_eq "and not another repo's identically-numbered issue" "" \
  "$(refinement_assignee_targets "$blocked" 52 "o/other")"

reset_assignee_calls
while IFS=$'\t' read -r t_repo t_num t_assignee; do
  refinement_assignee_remove "$t_repo" "$t_num" "$t_assignee"
done < <(refinement_assignee_targets "$blocked" 52 "o/r")
assert_eq "clearing the block takes the assignment off" "unassign o/r 52 octocat" "$(assignee_calls)"

# --- Requirement 35a: a refinement block is eligible like any other -------------
# Deliberately unchanged by the marker. The threshold delay is a feature here:
# it gives the human, or the Co-Ordinator's own cheap re-check, several cycles
# to settle the item before the expensive stage is bought.

coord_cycles() {  # <n> [first-hour]
  local n="$1" h="${2:-10}" i
  for (( i = 0; i < n; i++ )); do
    printf '{"ts":"2026-07-22T%02d:05:00Z","cycle":"c%d","event":"stage-end","stage":"coordinator","exit_code":0}\n' \
      "$(( h + i ))" "$(( i + 1 ))"
  done
}
refine_block='{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD26071901","kind":"needs-refinement","detail":"no acceptance criteria","unblock_condition":"a scope bound and acceptance criteria"}'
eligible() { enabler_eligible_items "$log" "${1:-3}" "${2:-0}" '{"o/r":[]}' "$now"; }

printf '%s\n' "$refine_block" > "$log"
coord_cycles 2 >> "$log"
assert_eq "two coordinator cycles is below a threshold of three, refinement or not" "" \
  "$(eligible | jq -r '.[0].reason // ""')"

printf '%s\n' "$refine_block" > "$log"
coord_cycles 3 >> "$log"
assert_eq "a coordinator-stage refinement block crosses the ordinary threshold" "threshold" \
  "$(eligible | jq -r '.[0].reason')"
assert_eq "and the entry carries the class the engagement acts on" "needs-refinement" \
  "$(eligible | jq -r '.[0].kind')"
assert_eq "and the condition promoted from the report's missing" \
  "a scope bound and acceptance criteria" "$(eligible | jq -r '.[0].unblock_condition')"
assert_eq "an ordinary block carries an empty kind" '""' \
  "$(printf '%s\n' '{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"TD1","detail":"x"}' > "$log"
     coord_cycles 3 >> "$log"; eligible | jq -c '.[0].kind')"

# --- Requirement 36b: refined_before, derived from the log ----------------------

printf '%s\n' "$refine_block" > "$log"
coord_cycles 3 >> "$log"
assert_eq "an item nobody has refined carries no prior refinement" "null" \
  "$(eligible | jq -c '.[0].refined_before')"

cat >> "$log" <<'EOF'
{"ts":"2026-07-22T10:00:00Z","cycle":"c1","event":"item-refined","repo":"o/r","item":"TD26071901","spec":"first attempt at a spec"}
{"ts":"2026-07-22T11:00:00Z","cycle":"c2","event":"item-refined","repo":"o/r","item":"TD26071901","spec":"the later, better spec"}
EOF
assert_eq "a refined item carries the latest refinement, not the first" \
  "2026-07-22T11:00:00Z|the later, better spec" \
  "$(eligible | jq -r '.[0].refined_before | [.ts, .spec] | join("|")')"

# Keyed on repo+item like everything else: a refinement of one repo's item says
# nothing about the other repo's identically-named one, and treating it as one
# would silence the second item's first refinement.
printf '%s\n' "$refine_block" > "$log"
coord_cycles 3 >> "$log"
printf '%s\n' '{"ts":"2026-07-22T10:00:00Z","cycle":"c1","event":"item-refined","repo":"o/other","item":"TD26071901","spec":"a different repo entirely"}' >> "$log"
assert_eq "another repo's refinement of the same id does not count" "null" \
  "$(eligible | jq -c '.[0].refined_before')"

# --- Requirement 36b: the thrash guard ------------------------------------------
# One refinement per item per human touch. The prompt says so; this is the half
# that holds when the model has convinced itself otherwise, on requirement 34d's
# reasoning.

refined_entry='{"repo": "o/r", "item": "TD26071901", "kind": "needs-refinement",
                "reason": "threshold",
                "refined_before": {"ts": "2026-07-22T11:00:00Z", "cycle": "c2", "spec": "the spec"}}'
fresh_entry='{"repo": "o/r", "item": "TD26071901", "kind": "needs-refinement",
              "reason": "threshold", "refined_before": null}'
ordinary_entry='{"repo": "o/r", "item": "TD1", "kind": "", "reason": "threshold",
                 "refined_before": null}'
unblock='{"verdict": "unblocked", "refined_spec": "a second, competing spec"}'

assert_eq "a first refinement stands" "0" \
  "$(refinement_second_pass_refused "$fresh_entry" "$unblock" >/dev/null; echo $?)"
out="$(refinement_second_pass_refused "$refined_entry" "$unblock")"; rc=$?
assert_eq "a second refinement is refused" "1" "$rc"
assert_contains "  ... saying a human settles it" "only a human can settle" "$out"
assert_eq "an escalate verdict on the same item is not touched" "0" \
  "$(refinement_second_pass_refused "$refined_entry" '{"verdict": "escalate"}' >/dev/null; echo $?)"
assert_eq "nor a still-blocked one" "0" \
  "$(refinement_second_pass_refused "$refined_entry" '{"verdict": "still-blocked"}' >/dev/null; echo $?)"
assert_eq "an ordinary block that happens to have been refined once is unaffected" "0" \
  "$(refinement_second_pass_refused \
       "$(jq -c '.kind = "" | .refined_before = {"ts": "2026-07-22T11:00:00Z"}' <<<"$refined_entry")" \
       "$unblock" >/dev/null; echo $?)"
assert_eq "an ordinary item is never in scope" "0" \
  "$(refinement_second_pass_refused "$ordinary_entry" "$unblock" >/dev/null; echo $?)"

# The exception that makes "per human touch" checkable: `issue-closed` exists
# only because a human acted on an escalation about this very item, so the
# refinement it authorises is the first since they did. Without this the loop
# would deadlock — the escalation would be answered and the answer never used.
assert_eq "a refinement built from a human's answers is allowed" "0" \
  "$(refinement_second_pass_refused "$(jq -c '.reason = "issue-closed"' <<<"$refined_entry")" \
       "$unblock" >/dev/null; echo $?)"
assert_eq "but a recheck is not a human touch" "1" \
  "$(refinement_second_pass_refused "$(jq -c '.reason = "recheck"' <<<"$refined_entry")" \
       "$unblock" >/dev/null; echo $?)"

# --- Requirement 36b: what an unblocked refinement records ----------------------
# Two shapes, because the refinement has to land where a future Co-Ordinator
# reads: a comment for an issue (which it pastes with the rest of the thread),
# the spec itself for everything else. Neither is the failure worth naming.

assert_eq "a non-issue refinement records the spec" '{"spec":"the refined spec"}' \
  "$(refinement_record_fields '{"verdict": "unblocked", "refined_spec": "the refined spec"}')"
assert_eq "an issue refinement records the comment it was posted as" \
  '{"comment_url":"https://github.com/o/r/issues/52#issuecomment-1"}' \
  "$(refinement_record_fields '{"verdict": "unblocked",
       "comments_posted": ["https://github.com/o/r/issues/52#issuecomment-1"]}')"
assert_eq "an unblock carrying neither records nothing at all" "" \
  "$(refinement_record_fields '{"verdict": "unblocked", "reason": "looks fine to me now"}')"
assert_eq "an empty spec is not a refinement" "" \
  "$(refinement_record_fields '{"verdict": "unblocked", "refined_spec": "", "comments_posted": []}')"

# --- Requirements 3h: the refinement reaches the next Co-Ordinator ---------------

cat > "$log" <<'EOF'
{"ts":"2026-07-22T10:00:00Z","cycle":"c1","event":"item-refined","repo":"o/r","item":"TD26071901","spec":"first attempt"}
{"ts":"2026-07-22T11:00:00Z","cycle":"c2","event":"item-refined","repo":"o/r","item":"TD26071901","spec":"the current spec"}
{"ts":"2026-07-22T11:30:00Z","cycle":"c2","event":"item-refined","repo":"o/r","item":"52","comment_url":"https://github.com/o/r/issues/52#issuecomment-1"}
{"ts":"2026-07-22T12:00:00Z","cycle":"c3","event":"item-refined","repo":"o/other","item":"TD26071901","spec":"the other repo's"}
EOF
map="$(refinements_map "$log")"
assert_eq "the latest refinement wins" "the current spec" \
  "$(jq -r '."o/r".TD26071901.spec' <<<"$map")"
assert_eq "an issue's refinement is carried as a pointer into its thread" \
  "https://github.com/o/r/issues/52#issuecomment-1" \
  "$(jq -r '."o/r"."52".comment_url' <<<"$map")"
assert_eq "and it carries no spec, because the thread holds the words" "null" \
  "$(jq -r '."o/r"."52".spec // "null"' <<<"$map")"
assert_eq "the map is keyed by repo as well as item" "the other repo's" \
  "$(jq -r '."o/other".TD26071901.spec' <<<"$map")"
assert_eq "and records when it was written, for the fingerprint" "2026-07-22T11:00:00Z" \
  "$(jq -r '."o/r".TD26071901.ts' <<<"$map")"

# A refined specification of work that does not exist would arrive in the
# Co-Ordinator's input arguing, in the pipeline's own voice, for an item
# requirement 34c says must never be selected again.
printf '%s\n' '{"ts":"2026-07-23T09:00:00Z","cycle":"c5","event":"item-void","stage":"enabler","repo":"o/r","item":"TD26071901","detail":"already done","evidence":"main@aad1405"}' >> "$log"
assert_eq "a void item's refinement is withheld" "null" \
  "$(refinements_map "$log" | jq -r '."o/r".TD26071901 // "null"')"
assert_eq "and the others are untouched" \
  "https://github.com/o/r/issues/52#issuecomment-1" \
  "$(refinements_map "$log" | jq -r '."o/r"."52".comment_url')"
printf '%s\n' '{"ts":"2026-07-24T09:00:00Z","cycle":"manual","event":"unvoided","item":"TD26071901"}' >> "$log"
assert_eq "a human unvoiding it hands the refinement back" "the current spec" \
  "$(refinements_map "$log" | jq -r '."o/r".TD26071901.spec')"

assert_eq "a missing log yields no refinements" "{}" "$(refinements_map "$tmp_dir/nonexistent.jsonl")"
printf '%s' '{"ts":"2026-07-22T10:00:00Z","event":"item-ref' >> "$log"
assert_eq "a malformed trailing line does not lose the map" "the current spec" \
  "$(refinements_map "$log" | jq -r '."o/r".TD26071901.spec')"

# --- Requirement 39d: a fresher needs-refinement block shadows a refinement ------
# The Implementor's escape hatch (or a further Refiner decline) says a named
# specification did not hold up, so a later Co-Ordinator must not be handed it
# again — but a *later* refinement must still win once someone writes one.
stale_log="$(mktemp)"
cat > "$stale_log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","cycle":"c1","event":"item-refined","repo":"o/r","item":"88","comment_url":"https://github.com/o/r/issues/88#issuecomment-1"}
EOF
assert_eq "before any block, the refinement stands" \
  "https://github.com/o/r/issues/88#issuecomment-1" \
  "$(refinements_map "$stale_log" | jq -r '."o/r"."88".comment_url')"

printf '%s\n' '{"ts":"2026-08-01T10:00:00Z","cycle":"c2","event":"attempt-failed","stage":"implementor","kind":"needs-refinement","repo":"o/r","item":"88","reason":"acceptance criteria do not match the body","unblock_condition":"say which of the two behaviours is wanted"}' >> "$stale_log"
assert_eq "a fresher needs-refinement block shadows the refinement" "null" \
  "$(refinements_map "$stale_log" | jq -r '."o/r"."88" // "null"')"

printf '%s\n' '{"ts":"2026-08-01T11:00:00Z","cycle":"c3","event":"item-refined","repo":"o/r","item":"88","comment_url":"https://github.com/o/r/issues/88#issuecomment-2"}' >> "$stale_log"
assert_eq "a later refinement clears the shadow and wins" \
  "https://github.com/o/r/issues/88#issuecomment-2" \
  "$(refinements_map "$stale_log" | jq -r '."o/r"."88".comment_url')"

printf '%s\n' '{"ts":"2026-08-01T08:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","kind":"needs-refinement","repo":"o/r","item":"77","reason":"vague","unblock_condition":"…"}' >> "$stale_log"
printf '%s\n' '{"ts":"2026-08-01T09:00:00Z","cycle":"c1","event":"item-refined","repo":"o/r","item":"77","spec":"written after the block"}' >> "$stale_log"
assert_eq "a refinement written after an older block is not shadowed by it" \
  "written after the block" \
  "$(refinements_map "$stale_log" | jq -r '."o/r"."77".spec')"
rm -f "$stale_log"

# --- Requirement 35d: the per-engagement cap -------------------------------------
# The asymmetry is the point: the backlog of items silently skipped before this
# existed is unbounded and none of it is urgent, while the ordinary blocked
# queue holds the pull request nobody can see (requirement 32a).

engagement='[
  {"repo": "o/r", "item": "TD1", "kind": "", "blocked_ts": "2026-07-20T09:00:00Z"},
  {"repo": "o/r", "item": "R1", "kind": "needs-refinement", "blocked_ts": "2026-07-22T09:00:00Z"},
  {"repo": "o/r", "item": "R2", "kind": "needs-refinement", "blocked_ts": "2026-07-21T09:00:00Z"},
  {"repo": "o/r", "item": "TD2", "kind": "", "blocked_ts": "2026-07-23T09:00:00Z"},
  {"repo": "o/r", "item": "R3", "kind": "needs-refinement", "blocked_ts": "2026-07-19T09:00:00Z"}
]'
items_in() { jq -r '[.[].item] | join(",")' <<<"$1"; }

assert_eq "a cap above the backlog keeps everything, in the order given" \
  "TD1,R1,R2,TD2,R3" "$(items_in "$(refinement_engagement_set "$engagement" 5)")"
assert_eq "a cap of two keeps both ordinary items and the two oldest blocks" \
  "TD1,R2,TD2,R3" "$(items_in "$(refinement_engagement_set "$engagement" 2)")"
assert_eq "a cap of one keeps the oldest refinement only" \
  "TD1,TD2,R3" "$(items_in "$(refinement_engagement_set "$engagement" 1)")"
assert_eq "a cap of zero removes the class and leaves ordinary items alone" \
  "TD1,TD2" "$(items_in "$(refinement_engagement_set "$engagement" 0)")"
assert_eq "an unreadable cap spends nothing" \
  "TD1,TD2" "$(items_in "$(refinement_engagement_set "$engagement" "three")")"
assert_eq "an engagement of only ordinary items is unaffected by the cap" \
  "TD1,TD2" \
  "$(items_in "$(refinement_engagement_set "$(jq -c '[.[] | select(.kind == "")]' <<<"$engagement")" 0)")"
assert_eq "an empty eligible set stays empty" "[]" "$(refinement_engagement_set '[]' 3)"

# --- Requirement 34g: a human's own hand-applied label is read back --------------
# Requirement 34e's projection is one-way for the block the Script itself
# creates from a Co-Ordinator's report — nothing reads that label back. This is
# the narrower, second report: a human applying the label directly, which the
# Script scans for during source gathering and turns into the same kind of
# block, marked so its later removal is distinguishable from anything else that
# might touch the label.

hand_flagged='[{"repo": "o/r", "number": 52, "url": "https://github.com/o/r/issues/52",
                "label": "needs-refinement", "state": "open",
                "labelled_at": "2026-07-28T09:00:00Z", "by": "warwick"}]'
hand_flagged_compact="$(jq -c . <<<"$hand_flagged")"

assert_eq "a labelled, open, unblocked issue earns a fresh entry" \
  "$hand_flagged_compact" "$(refinement_hand_flag_new "$hand_flagged" '[]')"
assert_eq "an already-blocked item earns no duplicate, refinement or not" "[]" \
  "$(refinement_hand_flag_new "$hand_flagged" \
       '[{"repo": "o/r", "item": "52", "kind": ""}]')"
assert_eq "  ... including one already blocked as a refinement itself" "[]" \
  "$(refinement_hand_flag_new "$hand_flagged" \
       '[{"repo": "o/r", "item": "52", "kind": "needs-refinement"}]')"
assert_eq "a closed issue earns nothing, even freshly labelled" "[]" \
  "$(refinement_hand_flag_new "$(jq -c '.[0].state = "closed"' <<<"$hand_flagged")" '[]')"
assert_eq "another repo's identically-numbered issue is untouched by this one's block" \
  "$hand_flagged_compact" "$(refinement_hand_flag_new "$hand_flagged" \
       '[{"repo": "o/other", "item": "52", "kind": ""}]')"

# Requirement 39f: the scan the Script actually runs is the composition of
# `label_filter_own_applications` and `refinement_hand_flag_new`, in that
# order. The case it exists for is a block that cleared correctly but whose
# label removal silently failed: the label is still present, no block is open,
# and without the filter that reads exactly like a human asking for one.
own_log="$tmp_dir/own-label-actions.jsonl"
printf '%s\n' '{"ts":"2026-07-28T09:00:01Z","event":"own-label-action","repo":"o/r","item":"52","label":"needs-refinement","action":"add"}' > "$own_log"
own_map="$(label_own_actions_map "needs-refinement" "$own_log")"
assert_eq "a stuck label from our own failed removal manufactures no fresh block" "[]" \
  "$(refinement_hand_flag_new "$(label_filter_own_applications "$hand_flagged" "$own_map")" '[]')"

# The retry half of requirement 39f: exactly the entry the filter dropped
# above is what the call site hands back to `refinement_label_remove` for
# another attempt — `release_refinement_label`'s original removal is what
# failed to begin with.
assert_eq "  ... and is exactly the entry the retry composition re-attempts removal on" \
  "$hand_flagged_compact" "$(label_own_stale_applications "$hand_flagged" "$own_map")"

# ... but the same issue flagged by a human *after* our own last action is a
# genuine request, and must still earn its block — and must never be retried,
# since it is not this system's own write to retry.
human_map="$(label_own_actions_map "needs-refinement" /dev/null)"
assert_eq "an unrecorded label is still read as the human's own flag" \
  "$hand_flagged_compact" \
  "$(refinement_hand_flag_new "$(label_filter_own_applications "$hand_flagged" "$human_map")" '[]')"
assert_eq "  ... and nothing here is ours to retry removing" "[]" \
  "$(label_own_stale_applications "$hand_flagged" "$human_map")"
printf '%s\n' '{"ts":"2026-07-20T09:00:00Z","event":"own-label-action","repo":"o/r","item":"52","label":"needs-refinement","action":"add"}' > "$own_log"
assert_eq "a human re-applying the label after us still earns a block" \
  "$hand_flagged_compact" \
  "$(refinement_hand_flag_new \
       "$(label_filter_own_applications "$hand_flagged" \
            "$(label_own_actions_map "needs-refinement" "$own_log")")" '[]')"
assert_eq "  ... and again nothing here is ours to retry removing" "[]" \
  "$(label_own_stale_applications "$hand_flagged" "$(label_own_actions_map "needs-refinement" "$own_log")")"
printf '%s\n' '{"ts":"2026-07-28T09:00:01Z","event":"own-label-action","repo":"o/r","item":"52","label":"needs-refinement","action":"remove"}' >> "$own_log"
assert_eq "a label still present after a *recorded* removal is not ours to explain" \
  "$hand_flagged_compact" \
  "$(refinement_hand_flag_new \
       "$(label_filter_own_applications "$hand_flagged" \
            "$(label_own_actions_map "needs-refinement" "$own_log")")" '[]')"
assert_eq "  ... nor ours to retry removing — our last recorded action was the removal itself" "[]" \
  "$(label_own_stale_applications "$hand_flagged" "$(label_own_actions_map "needs-refinement" "$own_log")")"

# The `cleared` half must never see the filtered list: it asks which issues
# have *lost* the label, so an entry dropped for being our own would read
# there as a label that had gone and unblock the item.
printf '%s\n' '{"ts":"2026-07-28T09:00:01Z","event":"own-label-action","repo":"o/r","item":"52","label":"needs-refinement","action":"add"}' > "$own_log"
assert_eq "the unfiltered list keeps a hand-flagged block standing" "[]" \
  "$(refinement_hand_flag_cleared "$hand_flagged" \
       '[{"repo": "o/r", "item": "52", "kind": "needs-refinement", "hand_flagged": true}]')"

fields="$(refinement_hand_flag_fields "o/r" 52 needs-refinement warwick \
  "2026-07-28T09:00:00Z" "https://github.com/o/r/issues/52")"
assert_eq "a hand-flagged block is marked as a refinement" "needs-refinement" \
  "$(jq -r '.kind' <<<"$fields")"
assert_eq "and carries no unblock condition — a label says nothing was missing" \
  "" "$(jq -r '.unblock_condition' <<<"$fields")"
assert_eq "and is traceable to a human, not the Script's own projection" "true" \
  "$(jq -r '.hand_flagged' <<<"$fields")"
assert_eq "and records which label, so the ordinary lifecycle can remove it" \
  "needs-refinement" "$(jq -r '.needs_refinement_label' <<<"$fields")"
assert_eq "and who applied it" "warwick" "$(jq -r '.hand_flagged_by' <<<"$fields")"
assert_eq "an anonymous flag records no author rather than a placeholder" "null" \
  "$(jq -r '.hand_flagged_by // "null"' <<<"$(refinement_hand_flag_fields "o/r" 52 needs-refinement)")"

hand_flagged_block='[{"repo": "o/r", "item": "52", "kind": "needs-refinement",
                       "needs_refinement_label": "needs-refinement", "hand_flagged": true}]'
script_block='[{"repo": "o/r", "item": "52", "kind": "needs-refinement",
                "needs_refinement_label": "needs-refinement"}]'

assert_eq "a hand-flagged block whose label is gone is cleared" \
  '[{"repo":"o/r","item":"52"}]' "$(refinement_hand_flag_cleared '[]' "$hand_flagged_block")"
assert_eq "  ... including when the issue is simply gone from the fetch" \
  '[{"repo":"o/r","item":"52"}]' \
  "$(refinement_hand_flag_cleared '[{"repo": "o/other", "number": 52}]' "$hand_flagged_block")"
assert_eq "still-labelled, even if closed, is not a removal" "[]" \
  "$(refinement_hand_flag_cleared '[{"repo": "o/r", "number": 52, "state": "closed"}]' "$hand_flagged_block")"
assert_eq "a block the Script itself projected the label onto is never cleared this way" \
  "[]" "$(refinement_hand_flag_cleared '[]' "$script_block")"
assert_eq "an ordinary block carrying no refinement kind is untouched regardless" "[]" \
  "$(refinement_hand_flag_cleared '[]' \
       '[{"repo": "o/r", "item": "52", "kind": "", "hand_flagged": true}]')"

# --- Robustness at the call sites -------------------------------------------------
# agent-cycle.sh calls all of this from a cycle running under `set -euo pipefail`,
# and the verdict half of it from inside the exit trap, where an unguarded
# non-zero status costs the cycle its `cycle-end` event, its lock release and its
# state-sync push (requirement 37).
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/cycle-state.sh"
  . "$SCRIPT_DIR/lib/void-guard.sh"
  . "$SCRIPT_DIR/lib/refinement.sh"
  REFINEMENT_GH="/nonexistent/gh"
  if problem="$(refinement_entry_problem '{"item": "X"}')"; then exit 7; fi
  [[ -n "$problem" ]] || exit 6
  refinement_block_fields 'not json' >/dev/null
  refinement_label_targets 'not json' "X" >/dev/null
  refinement_engagement_set 'not json' 3 >/dev/null
  refinement_record_fields 'not json' >/dev/null
  refinements_map "/nonexistent/log.jsonl" >/dev/null
  if refinement_second_pass_refused 'not json' 'not json'; then :; fi
  refinement_label_remove "o/r" 52 needs-refinement || true
  refinement_hand_flag_new 'not json' 'not json' >/dev/null
  refinement_hand_flag_fields "o/r" 52 needs-refinement >/dev/null
  refinement_hand_flag_cleared 'not json' 'not json' >/dev/null
  exit 0
) >/dev/null 2>&1
assert_eq "the real call-site shapes survive set -e and unparseable input" "0" "$?"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
