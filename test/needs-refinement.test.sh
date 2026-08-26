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
# `gh issue view <n> -R <slug> --json labels --jq ...` serves the label names
# in $tmp_dir/issue-labels, one per line; $tmp_dir/view-fail makes it fail —
# the read `refinement_label_project` does before it writes has to survive
# without ever recording (agent-ops#651).
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  [[ -f "$d/view-fail" ]] && exit 1
  cat "$d/issue-labels" 2>/dev/null
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
stale_log="$tmp_dir/stale-log.jsonl"
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

# --- agent-ops#687 Part 1: self-healing through $REFINEMENT_LABEL_ENSURE --------
# A failed add is the common case above; here the hook that agent-cycle.sh
# would set (a function resolving REPO+LABEL against the catalogue and
# calling labels_ensure_one) actually creates the label, and the retried add
# lands — the exact case this system used to just fail on.
ensure_calls="$tmp_dir/ensure-calls"
# shellcheck disable=SC2317  # invoked only indirectly, as "$REFINEMENT_LABEL_ENSURE"
fake_ensure() {  # REPO LABEL — "creates" the label by clearing it from missing-labels
  printf '%s %s\n' "$1" "$2" >> "$ensure_calls"
  sed -i "/^$2\$/d" "$tmp_dir/missing-labels" 2>/dev/null || true
}
export REFINEMENT_LABEL_ENSURE=fake_ensure

rm -f "$ensure_calls"
printf 'needs-refinement\n' > "$tmp_dir/missing-labels"
reset_calls
assert_eq "a failed add self-heals through the ensure hook and succeeds" "0" \
  "$(refinement_label_add "o/r" 52 needs-refinement; echo $?)"
assert_eq "  ... through exactly one ensure attempt" "o/r needs-refinement" \
  "$(cat "$ensure_calls")"
assert_eq "  ... and the retried add lands" "add o/r 52 needs-refinement" "$(label_calls)"
rm -f "$tmp_dir/missing-labels"

# A token that genuinely cannot create labels: the ensure hook is tried exactly
# once per (repo, label) per process, not once per projection — a second
# projection (a different issue) of the same pair costs no further ensure
# attempt, so a stuck token is not billed for every issue it fails to label.
# (Called directly, not through $(...): the memoisation lives in an associative
# array in *this* shell, and a command substitution would run it in a subshell
# whose writes to that array never reach back here.)
rm -f "$ensure_calls"
# shellcheck disable=SC2317  # invoked only indirectly, as "$REFINEMENT_LABEL_ENSURE"
fake_ensure_stuck() { printf '%s %s\n' "$1" "$2" >> "$ensure_calls"; }  # never clears the label
export REFINEMENT_LABEL_ENSURE=fake_ensure_stuck
printf 'stuck-label\n' > "$tmp_dir/missing-labels"
reset_calls
refinement_label_add "o/r" 52 stuck-label; rc1=$?
refinement_label_add "o/r" 53 stuck-label; rc2=$?
assert_eq "a genuinely uncreatable label still fails after the retry" "1" "$rc1"
assert_eq "a second projection of the same (repo, label) triggers no further ensure" "1" "$rc2"
assert_eq "  ... exactly one ensure attempt total" "o/r stuck-label" "$(cat "$ensure_calls")"
rm -f "$tmp_dir/missing-labels" "$ensure_calls"
unset REFINEMENT_LABEL_ENSURE
unset -f fake_ensure_stuck

# refinement_label_project's own two add paths flow through refinement_label_add,
# so both self-heal for free: the ordinary "added" success path —
export REFINEMENT_LABEL_ENSURE=fake_ensure
rm -f "$tmp_dir/issue-labels" "$tmp_dir/view-fail" "$ensure_calls"
printf 'project-label\n' > "$tmp_dir/missing-labels"
reset_calls
assert_eq "refinement_label_project's add path self-heals and still reports added" \
  "added" "$(refinement_label_project "o/r" 60 project-label)"
rm -f "$tmp_dir/missing-labels"

# — and the read-failure path, which adds best-effort regardless of whether the
# self-heal makes it land, and must still report unrecorded either way (the read
# failed, so nothing here is safe to record, self-heal or not).
printf 'project-label2\n' > "$tmp_dir/missing-labels"
printf x > "$tmp_dir/view-fail"
reset_calls
assert_eq "refinement_label_project's unrecorded path self-heals but still reports unrecorded" \
  "unrecorded" "$(refinement_label_project "o/r" 61 project-label2)"
rm -f "$tmp_dir/view-fail" "$tmp_dir/missing-labels" "$ensure_calls"

unset REFINEMENT_LABEL_ENSURE
unset -f fake_ensure

# --- Requirement 34e: the label comes off when the block clears -----------------
# Removal is driven from the block record, not from config, so the Script can
# only ever remove a label it recorded applying. `blocked_items` is the extract
# it reads, which is what makes the label's lifecycle mirror the block's by
# construction rather than by two pieces of code agreeing.

cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","kind":"needs-refinement","detail":"no acceptance criteria","unblock_condition":"acceptance criteria","needs_refinement_label":"needs-refinement"}
{"ts":"2026-07-22T09:00:01Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD26071901","kind":"needs-refinement","detail":"no scope bound","unblock_condition":"a scope bound"}
{"ts":"2026-07-22T09:00:02Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"77","detail":"needs a repo secret"}
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

# --- Requirement 38b: the same projection, for `blocked`/`blocked:<reason>` ----
# agent-ops#203 was labelled correctly and still invisible: a human's filtered
# issue list has nothing to do with an unfamiliar label. Before agent-ops#639
# this projected an assignment instead; now it projects two further labels,
# mirroring the first label's lifecycle exactly — applied when the block is
# recorded, removed when it clears — read from their own fields so the Script
# never removes a label it did not apply.

assert_eq "the taxonomy names needs-refinement's reason label" \
  "blocked:needs-refinement" "$(refinement_blocked_reason_label needs-refinement)"
assert_eq "a kind with no reason label of its own gets none" "" \
  "$(refinement_blocked_reason_label something-else)"

fields="$(refinement_block_fields "$good" "" blocked "blocked:needs-refinement")"
assert_eq "a block with no blocked-label args records neither" "null null" \
  "$(jq -r '"\(.blocked_label // "null") \(.blocked_reason_label // "null")"' \
     <<<"$(refinement_block_fields "$good")")"
assert_eq "a block given both records which it applied" "blocked blocked:needs-refinement" \
  "$(jq -r '"\(.blocked_label) \(.blocked_reason_label)"' <<<"$fields")"
assert_eq "all three labels are independent fields on the same block" \
  "needs-refinement blocked blocked:needs-refinement" \
  "$(jq -r '"\(.needs_refinement_label) \(.blocked_label) \(.blocked_reason_label)"' \
     <<<"$(refinement_block_fields "$good" needs-refinement blocked "blocked:needs-refinement")")"

reset_calls
assert_eq "applying the blocked label succeeds" "0" \
  "$(refinement_label_add "o/r" 52 "$REFINEMENT_BLOCKED_LABEL"; echo $?)"
assert_eq "  ... and so does the reason label" "0" \
  "$(refinement_label_add "o/r" 52 "$(refinement_blocked_reason_label needs-refinement)"; echo $?)"
assert_eq "  ... through two gh calls" \
  "$(printf 'add o/r 52 blocked\nadd o/r 52 blocked:needs-refinement')" "$(label_calls)"

# --- The `blocked` projection reads before it writes (agent-ops#651) ------------
# `gh issue edit --add-label` is a no-op-success on an issue already carrying
# the label, so `refinement_label_project` reads the issue's labels first: a
# pre-existing `blocked` — a human's own, applied for their own reasons — is
# `present`, untouched and unrecorded, and clearing the block later never
# takes it off. Only a label the projection itself added is `added`, i.e. the
# caller's to record and the clearing's to remove. `blocked:<reason>` keeps
# the unconditional lifecycle tested above: no human reaches for that
# compound name on their own, so it needs no read-before-write.
reset_calls
rm -f "$tmp_dir/issue-labels" "$tmp_dir/view-fail"
assert_eq "an issue with no blocked label yet is labelled and recorded" "added" \
  "$(refinement_label_project "o/r" 52 "$REFINEMENT_BLOCKED_LABEL")"
assert_eq "  ... through one gh edit call" "add o/r 52 blocked" "$(label_calls)"

reset_calls
printf 'blocked\n' >"$tmp_dir/issue-labels"
assert_eq "a pre-existing blocked label is present, not re-added" "present" \
  "$(refinement_label_project "o/r" 52 "$REFINEMENT_BLOCKED_LABEL")"
assert_eq "  ... and nothing is edited at all" "" "$(label_calls)"

reset_calls
printf 'some-other-label\n' >"$tmp_dir/issue-labels"
assert_eq "another label on the issue does not mask the add" "added" \
  "$(refinement_label_project "o/r" 52 "$REFINEMENT_BLOCKED_LABEL")"
assert_eq "  ... which still happens" "add o/r 52 blocked" "$(label_calls)"

reset_calls
rm -f "$tmp_dir/issue-labels"
printf x >"$tmp_dir/view-fail"
assert_eq "an unreadable label list is applied best-effort but never recorded" \
  "unrecorded" "$(refinement_label_project "o/r" 52 "$REFINEMENT_BLOCKED_LABEL")"
assert_eq "  ... the best-effort add still reaches the issue" \
  "add o/r 52 blocked" "$(label_calls)"
rm -f "$tmp_dir/view-fail"

printf 'blocked\n' >"$tmp_dir/missing-labels"
rm -f "$tmp_dir/issue-labels"
assert_eq "a label the repo does not have fails the projection as it fails the add" \
  "failed" "$(refinement_label_project "o/r" 52 "$REFINEMENT_BLOCKED_LABEL")"
rm -f "$tmp_dir/missing-labels"

cat > "$log" <<'EOF'
{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","kind":"needs-refinement","detail":"gated on a decision","unblock_condition":"which packaging approach","needs_refinement_label":"needs-refinement","blocked_label":"blocked","blocked_reason_label":"blocked:needs-refinement"}
{"ts":"2026-07-22T09:00:01Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"TD26071901","kind":"needs-refinement","detail":"no scope bound","unblock_condition":"a scope bound"}
EOF
blocked="$(blocked_items "$log")"
assert_eq "the labelled issue's two blocked labels are both found for removal" \
  "$(printf 'o/r\t52\tblocked\no/r\t52\tblocked:needs-refinement')" \
  "$(refinement_blocked_label_targets "$blocked" 52)"
assert_eq "a refinement block that was never blocked-labelled has nothing to remove" "" \
  "$(refinement_blocked_label_targets "$blocked" TD26071901)"
assert_eq "a repo-scoped clear matches its own repo" \
  "$(printf 'o/r\t52\tblocked\no/r\t52\tblocked:needs-refinement')" \
  "$(refinement_blocked_label_targets "$blocked" 52 "o/r")"
assert_eq "and not another repo's identically-numbered issue" "" \
  "$(refinement_blocked_label_targets "$blocked" 52 "o/other")"

reset_calls
while IFS=$'\t' read -r t_repo t_num t_label; do
  refinement_label_remove "$t_repo" "$t_num" "$t_label"
done < <(refinement_blocked_label_targets "$blocked" 52 "o/r")
assert_eq "clearing the block takes both labels off" \
  "$(printf 'remove o/r 52 blocked\nremove o/r 52 blocked:needs-refinement')" "$(label_calls)"

# --- Requirement 38b's migration: a legacy block's reason label comes off, ---
# --- but its generic `blocked` is never assumed to be the pipeline's own ----
# `scripts/sweep-legacy-refinement-assignees.sh` applies the fixed pair to a
# pre-agent-ops#639 block's issue without rewriting that block's own event, so
# the record says nothing about them. For the reason label — a name no human
# reaches for on their own — reading the record alone is enough: the sweep
# can only ever have applied it, so a block carrying `needs_refinement_assignee`
# and neither blocked-label field yields it regardless. Not so for `blocked`
# itself: it is a human's own, hand-applied control, the sweep projects it
# through the same read-before-write `refinement_label_project` uses, and it
# has no event of its own to record whether a given run found it `added` or
# `present` — so a legacy block never yields the generic `blocked` here at
# all, over-holding it rather than guessing whether it is safe to remove
# (agent-ops#651).
cat > "$log" <<'EOF'
{"ts":"2026-07-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"77","kind":"needs-refinement","detail":"gated on a decision","unblock_condition":"which packaging approach","needs_refinement_label":"needs-refinement","needs_refinement_assignee":"octocat"}
EOF
legacy_blocked="$(blocked_items "$log")"
assert_eq "a legacy block yields only the reason label the sweep applied" \
  "$(printf 'o/r\t77\tblocked:needs-refinement')" \
  "$(refinement_blocked_label_targets "$legacy_blocked" 77 "o/r")"

reset_calls
while IFS=$'\t' read -r t_repo t_num t_label; do
  refinement_label_remove "$t_repo" "$t_num" "$t_label"
done < <(refinement_blocked_label_targets "$legacy_blocked" 77 "o/r")
assert_eq "  ... so clearing a migrated block takes only the reason label off" \
  "remove o/r 77 blocked:needs-refinement" "$(label_calls)"

# --- Requirement 38b's migration: `refinement_assignee_remove` survives ---------
# alone (agent-ops#639) — the one primitive `scripts/sweep-legacy-refinement-
# assignees.sh` needs to undo a legacy block's stale assignment. Nothing here
# adds an assignment any more; this only ever removes one.
reset_assignee_calls
assert_eq "removing a legacy assignment succeeds" "0" \
  "$(refinement_assignee_remove "o/r" 52 octocat; echo $?)"
assert_eq "  ... through one gh call" "unassign o/r 52 octocat" "$(assignee_calls)"

# --- Requirement 38b's reconciliation sweep for a removal that failed -----------
# (agent-ops#651). Unlike `needs_refinement_label`'s stale-retry (requirement
# 39f), no live GitHub read or own/human attribution heuristic is needed here:
# `blocked`/`blocked:<reason>` are never applied except by this pipeline, so
# a logged `own-label-action add` with no later `remove` is proof enough on
# its own — the log alone decides.
cat > "$stale_log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"90","kind":"needs-refinement","detail":"gated","unblock_condition":"x"}
{"ts":"2026-08-01T09:00:01Z","cycle":"c0","event":"own-label-action","repo":"o/r","item":"90","label":"blocked","action":"add"}
{"ts":"2026-08-01T09:00:02Z","cycle":"c0","event":"own-label-action","repo":"o/r","item":"90","label":"blocked:needs-refinement","action":"add"}
{"ts":"2026-08-01T10:00:00Z","cycle":"c1","event":"unblocked","repo":"o/r","item":"90"}
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"91","kind":"needs-refinement","detail":"gated","unblock_condition":"y"}
{"ts":"2026-08-01T09:00:01Z","cycle":"c0","event":"own-label-action","repo":"o/r","item":"91","label":"blocked","action":"add"}
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"92","kind":"needs-refinement","detail":"gated","unblock_condition":"z"}
{"ts":"2026-08-01T09:00:01Z","cycle":"c0","event":"own-label-action","repo":"o/r","item":"92","label":"blocked","action":"add"}
{"ts":"2026-08-01T10:00:00Z","cycle":"c1","event":"unblocked","repo":"o/r","item":"92"}
{"ts":"2026-08-01T10:00:01Z","cycle":"c1","event":"own-label-action","repo":"o/r","item":"92","label":"blocked","action":"remove"}
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/other","item":"90","kind":"needs-refinement","detail":"gated","unblock_condition":"w"}
{"ts":"2026-08-01T09:00:01Z","cycle":"c0","event":"own-label-action","repo":"o/other","item":"90","label":"blocked","action":"add"}
{"ts":"2026-08-01T10:00:00Z","cycle":"c1","event":"unblocked","repo":"o/other","item":"90"}
EOF
stale_blocked="$(blocked_items "$stale_log")"
assert_eq "only item 91's block is still open" "91" \
  "$(jq -r '.[].item' <<<"$stale_blocked" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "a cleared block's un-removed labels are offered for retry, both of them" \
  "$(printf 'o/other\t90\tblocked\no/r\t90\tblocked\no/r\t90\tblocked:needs-refinement')" \
  "$(refinement_blocked_label_stale "$stale_blocked" "$stale_log")"
assert_eq "item 91 is not offered — its block is still open" "0" \
  "$(refinement_blocked_label_stale "$stale_blocked" "$stale_log" | grep -c $'\t91\t')"
assert_eq "item 92 is not offered — its removal already succeeded" "0" \
  "$(refinement_blocked_label_stale "$stale_blocked" "$stale_log" | grep -c $'\t92\t')"

reset_calls
while IFS=$'\t' read -r t_repo t_item t_label; do
  refinement_label_remove "$t_repo" "$t_item" "$t_label"
done < <(refinement_blocked_label_stale "$stale_blocked" "$stale_log")
assert_eq "the retry removes exactly the stale labels, nothing else" \
  "$(printf 'remove o/other 90 blocked\nremove o/r 90 blocked\nremove o/r 90 blocked:needs-refinement')" \
  "$(label_calls)"

# --- Requirement 38b's live reconciliation (agent-ops#816, TD-PPagop-26082602) --
# `refinement_blocked_label_stale` above can only offer a removal its own
# history proves is ours — a logged `own-label-action add` with no later
# `remove`. This cohort has neither: the label was applied by
# `scripts/sweep-legacy-refinement-assignees.sh` (which logs nothing of its
# own) or the block cleared before that logging existed at all, so no `add`
# ever entered the log. `refinement_blocked_label_orphaned` proves it a
# different way — a *live* GitHub read against the currently-open block set —
# so it needs no history.
cat > "$log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"200","kind":"needs-refinement","detail":"gated","unblock_condition":"x"}
EOF
open_blocked_only_200="$(blocked_items "$log")"

# #201: `blocked` + `blocked:needs-refinement` both live on GitHub, no
# own-label-action history at all (the legacy-sweep shape) and no open block —
# orphaned, both labels offered.
live_201_and_202="$(jq -c -n '
  [{number: 201, labels: ["blocked", "blocked:needs-refinement"]},
   {number: 202, labels: ["blocked:needs-refinement"]},
   {number: 200, labels: ["blocked", "blocked:needs-refinement"]}]')"
assert_eq "an orphaned issue with no history yields both labels; one with only the reason label yields one; the still-open block yields nothing" \
  "$(printf 'o/r\t201\tblocked:needs-refinement\no/r\t201\tblocked\no/r\t202\tblocked:needs-refinement')" \
  "$(refinement_blocked_label_orphaned "$open_blocked_only_200" "$live_201_and_202" "o/r")"

assert_eq "AC4: a repo with no live-labelled issues at all is a clean no-op" "" \
  "$(refinement_blocked_label_orphaned "$open_blocked_only_200" '[]' "o/r")"

# Another repo's open block on an identically-numbered item must not shield
# this repo's live-labelled issue: LIVE_JSON is already this repo's own read
# (the caller queries `gh` with `-R`), so only OPEN_BLOCKED_JSON's own
# repo-matching stands between them.
cross_repo_open_200="$(jq -c -n '[{repo: "o/other", item: "200", kind: "needs-refinement"}]')"
assert_eq "another repo's open block on the same-numbered item does not shield it here" \
  "$(printf 'o/r\t200\tblocked:needs-refinement\no/r\t200\tblocked')" \
  "$(refinement_blocked_label_orphaned "$cross_repo_open_200" \
       '[{"number": 200, "labels": ["blocked", "blocked:needs-refinement"]}]' "o/r")"

reset_calls
while IFS=$'\t' read -r t_repo t_item t_label; do
  refinement_label_remove "$t_repo" "$t_item" "$t_label"
done < <(refinement_blocked_label_orphaned "$open_blocked_only_200" "$live_201_and_202" "o/r")
assert_eq "removal takes exactly the orphaned pair and the lone reason label, nothing else" \
  "$(printf 'remove o/r 201 blocked:needs-refinement\nremove o/r 201 blocked\nremove o/r 202 blocked:needs-refinement')" \
  "$(label_calls)"

# AC4, restated as the real steady state: nothing live-labelled at all, on a
# repo with an open block of its own, is a no-op — not merely an unlabelled
# repo.
assert_eq "AC4: idempotent — a second read after the removal already landed offers nothing" "" \
  "$(refinement_blocked_label_orphaned "$open_blocked_only_200" '[{"number": 200, "labels": ["blocked", "blocked:needs-refinement"]}]' "o/r")"

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
  "$(printf '%s\n' '{"ts":"2026-07-22T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"TD1","detail":"x"}' > "$log"
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
assert_contains "  ... saying it escalates instead" "escalates instead of being settled here" "$out"
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

# --- Requirement 36b: refinement_is_disagreement (agent-ops#627) ---------------
# The same "needs-refinement block with refined_before set" shape the thrash
# guard above refuses a second unblocked verdict against, read here without the
# verdict/issue-closed conditions that guard also checks — escalation_
# autonomy's adjudicate-first setting is this predicate's one caller, and it
# decides on the item alone, before any verdict is in hand.
assert_eq "a refined item is a disagreement" "0" \
  "$(refinement_is_disagreement "$refined_entry" >/dev/null; echo $?)"
assert_eq "a fresh (never-refined) item is not" "1" \
  "$(refinement_is_disagreement "$fresh_entry" >/dev/null; echo $?)"
assert_eq "an ordinary (non-refinement) item is not, even with refined_before set" "1" \
  "$(refinement_is_disagreement \
       "$(jq -c '.kind = "" | .refined_before = {"ts": "2026-07-22T11:00:00Z"}' <<<"$refined_entry")" \
       >/dev/null; echo $?)"
assert_eq "reason is irrelevant to this predicate — issue-closed is still a disagreement" "0" \
  "$(refinement_is_disagreement "$(jq -c '.reason = "issue-closed"' <<<"$refined_entry")" \
       >/dev/null; echo $?)"
assert_eq "malformed input is not a disagreement" "1" \
  "$(refinement_is_disagreement 'not json' >/dev/null; echo $?)"

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
# The Implementer's escape hatch (or a further Refiner decline) says a named
# specification did not hold up, so a later Co-Ordinator must not be handed it
# again — but a *later* refinement must still win once someone writes one.
stale_log="$(mktemp)"
cat > "$stale_log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","cycle":"c1","event":"item-refined","repo":"o/r","item":"88","comment_url":"https://github.com/o/r/issues/88#issuecomment-1"}
EOF
assert_eq "before any block, the refinement stands" \
  "https://github.com/o/r/issues/88#issuecomment-1" \
  "$(refinements_map "$stale_log" | jq -r '."o/r"."88".comment_url')"

printf '%s\n' '{"ts":"2026-08-01T10:00:00Z","cycle":"c2","event":"attempt-failed","stage":"implementer","kind":"needs-refinement","repo":"o/r","item":"88","reason":"acceptance criteria do not match the body","unblock_condition":"say which of the two behaviours is wanted"}' >> "$stale_log"
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
# above, and whose block has gone, is what the call site hands back to
# `refinement_label_remove` for another attempt — `release_refinement_label`'s
# original removal is what failed to begin with. The blocked extract is the
# second half of that test, and the call site passes it for the reason this
# pair of cases states: while the block is open the label is requirement 34e's
# live projection of it, and retrying the removal would strip the human's only
# signal off an issue the pipeline is still waiting on.
assert_eq "  ... and is exactly the entry the retry composition re-attempts removal on" \
  "$hand_flagged_compact" "$(label_own_stale_applications "$hand_flagged" "$own_map" '[]')"
assert_eq "  ... but not while the block that label projects is still open" "[]" \
  "$(label_own_stale_applications "$hand_flagged" "$own_map" \
       '[{"repo": "o/r", "item": "52", "kind": "needs-refinement"}]')"

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

# #526: at the call site, an own-label-action record from a peer node has not
# necessarily reached this node's union log yet (fleet state-sync runs on a
# periodic cadence, not synchronously), so a label with no own record at all
# is not safely read as a human's the instant it appears — only once it has
# had a grace period to propagate. A candidate labelled inside that window,
# with no own record, is deferred: the composition earns it no fresh block,
# but it must not be retried for removal either, since it was never proven to
# be this system's own write (a genuine, still-unpropagated write must not be
# torn back off the issue by its own writer).
grace_now="2026-08-17T09:00:00Z"
recently_flagged='[{"repo": "o/r", "number": 52, "url": "https://github.com/o/r/issues/52",
                     "label": "needs-refinement", "state": "open",
                     "labelled_at": "2026-08-17T08:45:00Z", "by": "warwick"}]'
no_own_map='{}'
assert_eq "a recently hand-flagged issue with no own record yet earns no block — deferred, not yet attributable" \
  "[]" "$(refinement_hand_flag_new \
           "$(label_filter_own_applications "$recently_flagged" "$no_own_map" "$grace_now")" '[]')"
assert_eq "  ... and is not offered up for a stale-removal retry either" "[]" \
  "$(label_own_stale_applications "$recently_flagged" "$no_own_map" '[]' "$grace_now")"

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

# --- The argv cap (requirement 4g) ------------------------------------------------
# The open blocked set grows with the fleet's history — block entries carry
# their evidence payloads — and both halves of the hand-flag scan take it.
# Delivered via `--argjson`, past MAX_ARG_STRLEN (131072 bytes, the kernel's
# per-entry argv cap) each call failed into its `2>/dev/null || true` and
# printed `[]`: hand-applied refinement flags silently stopped being noticed
# *and* silently stopped being cleared, which between them is the whole of
# requirement 34g. Requirement 4g puts the arrays on stdin; these pin it, with
# fixtures the size assertions prove are genuinely past the cap. The padding
# names a repo and items the fixtures do not, so it can neither block the fresh
# entry nor supply the cleared one.
big_unrelated_blocked="$(jq -nc '[range(3000) | {repo: "o/filler", item: ("TD-fill-" + tostring),
  kind: "", detail: ("pad " + ("x" * 40))}]')"
assert_eq "the oversized blocked fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_unrelated_blocked" | wc -c) > 131072 ))"
assert_eq "a blocked extract past the argv cap still earns the fresh hand-flag entry" \
  "$hand_flagged_compact" "$(refinement_hand_flag_new "$hand_flagged" "$big_unrelated_blocked")"

big_hand_flagged_blocked="$(jq -nc --argjson keep "$hand_flagged_block" \
  '[range(3000) | {repo: "o/filler", item: ("TD-fill-" + tostring),
    kind: "", detail: ("pad " + ("x" * 40))}] + $keep')"
assert_eq "the oversized hand-flagged blocked fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_hand_flagged_blocked" | wc -c) > 131072 ))"
assert_eq "a blocked extract past the argv cap still clears the hand-flagged block" \
  '[{"repo":"o/r","item":"52"}]' \
  "$(refinement_hand_flag_cleared '[]' "$big_hand_flagged_blocked")"

# --- scripts/gather-hand-flagged-refinements.sh's own accumulator fold (TD-PPagop-26081401) --
# $out grows with every hand-flagged issue a repo has ever carried the label
# on — unbounded by anything in this script, the same "merely growing"
# shape scripts/gather-tech-debt.sh's per-item append had before
# TD-PPagop-26081301 converted it. Lifted verbatim (inline loop body, not a
# function — same extraction shape test/finish-then-continue.test.sh already
# uses), and eval'd with an $out already past MAX_ARG_STRLEN to prove the
# fold survives an accumulator this large.
extract_hand_flag_fold() {
  awk '
    /^  out="\$\(jq -nc .input as \$arr/ { on = 1 }
    on                                    { print }
    on && /^    \|\| \{ warn .*; \}\)"$/  { exit }
  ' "$SCRIPT_DIR/scripts/gather-hand-flagged-refinements.sh"
}
hand_flag_fold_block="$(extract_hand_flag_fold)"
if [[ "$hand_flag_fold_block" != *"input as \$arr"* ]]; then
  echo "FAIL - could not extract the hand-flag fold from gather-hand-flagged-refinements.sh — has it moved?" >&2
  exit 1
fi
# An awk that never meets its terminator runs to end of file and hands the
# eval below the rest of the script, which can still pass every assertion
# under it — the quiet way this pin would stop pinning anything.
assert_eq "the extracted block is the fold alone, not the rest of the file" "1" \
  "$(( $(printf '%s\n' "$hand_flag_fold_block" | wc -l) <= 4 ))"
# `warn` and `number` are the script's, stubbed here because the block is
# lifted out of its loop: `warn` so the failure path can be observed at all,
# `number` because the message names the issue that dropped out.
run_hand_flag_fold() {  # <out-json> <entry-json>
  (
    # shellcheck disable=SC2317  # reached only from the eval'd block below.
    warn() { echo "gather-hand-flagged-refinements: o/r: $*" >&2; }
    number=4242 out="$1" entry="$2"
    eval "$hand_flag_fold_block"
    printf '%s' "$out"
  )
}
big_hand_flag_out="$(jq -nc '[range(3000) | {repo: "o/r", number: ., url: ("https://x/" + (. | tostring)),
  label: "needs-refinement", state: "open", labelled_at: "2026-08-01T00:00:00Z", by: "warwick"}]')"
assert_eq "the oversized hand-flag accumulator fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_hand_flag_out" | wc -c) > 131072 ))"
new_hand_flag_entry='{"repo":"o/r","number":9999,"url":"https://x/9999","label":"needs-refinement","state":"open","labelled_at":"2026-08-14T00:00:00Z","by":"warwick"}'
folded_hand_flags="$(run_hand_flag_fold "$big_hand_flag_out" "$new_hand_flag_entry")"
assert_eq "the fold past the argv cap still carries every already-accumulated entry" \
  "3001" "$(jq 'length' <<<"$folded_hand_flags")"
assert_eq "  ... plus the new entry" "1" \
  "$(jq '[.[] | select(.number == 9999)] | length' <<<"$folded_hand_flags")"

# The fold fails open per issue, which is right — losing every other
# hand-flagged issue to report one would be worse. What it must not do is fail
# open *silently*: a human's own label is a request made by hand (requirement
# 34g), and the reference conversion this one follows,
# scripts/gather-tech-debt.sh's `|| degrade "array assembly failed at …"`,
# is loud for that reason. An unparseable entry is the reachable way to make
# this jq fail on demand; the argv cap it replaced is the one that mattered.
hand_flag_fold_err="$(run_hand_flag_fold '[]' 'not json' 2>&1 >/dev/null)"
assert_contains "a fold that fails says which issue dropped out, on stderr" \
  "array assembly failed at issue #4242" "$hand_flag_fold_err"
assert_eq "and does not swallow jq's own reason for failing" "0" \
  "$(grep -c '2>/dev/null' <<<"$hand_flag_fold_block")"
assert_eq "  ... while still returning the accumulator it already had" "[]" \
  "$(run_hand_flag_fold '[]' 'not json' 2>/dev/null)"

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
  refinement_blocked_label_orphaned 'not json' 'not json' "o/r" >/dev/null
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
