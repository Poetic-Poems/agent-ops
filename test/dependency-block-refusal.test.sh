#!/usr/bin/env bash
#
# test/dependency-block-refusal.test.sh — regression test for issue #566: the
# Co-Ordinator re-applying the Script's own `Blocked-by:` exclusion from stale
# thread prose, five items mislabelled `needs_refinement` in one cycle even
# though the deterministic gate (`scripts/gather-issues.sh`, requirement 3j)
# had already resolved every one of them before the Co-Ordinator ever saw the
# candidate.
#
# `record_needs_refinement_block` — the single recorder every needs_refinement
# report from any stage funnels through (requirement 34e) — is lifted verbatim
# out of `agent-cycle.sh` with awk and eval'd, the same technique
# test/refiner-verdicts.test.sh uses, so the refusal under test is the genuine
# recording path and not a paraphrase of it.
# `dependency_refusal_reason` (lib/dependency-gate.sh) is exercised directly in
# test/dependency-gate.test.sh; this file's job is the integration the unit
# test cannot see: that the real recorder actually calls it, ahead of ever
# writing a block, an `attempt-failed`, a label, or an assignment.
#
# `gh` is stubbed through REFINEMENT_GH, the same shape as
# test/needs-refinement.test.sh and test/refiner-verdicts.test.sh. No test
# framework is used (none exists elsewhere in this repo). Run it directly:
#
#   ./test/dependency-block-refusal.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
# shellcheck source=lib/coordinator-input.sh
. "$SCRIPT_DIR/lib/coordinator-input.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

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

# --- Lift the function under test verbatim -----------------------------------
extract_fn() {
  local start_pat="$1" file="$2"
  awk -v start="$start_pat" '
    $0 == start { on = 1 }
    on          { print }
    on && /^}$/ { exit }
  ' "$file"
}

record_needs_refinement_block_fn="$(extract_fn 'record_needs_refinement_block() {' "$SCRIPT_DIR/lib/candidate-select.sh")"
if [[ "$record_needs_refinement_block_fn" != *"attempt-failed"* ]]; then
  printf 'FAIL - record_needs_refinement_block could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$record_needs_refinement_block_fn" != *"dependency_refusal_reason"* ]]; then
  printf 'FAIL - record_needs_refinement_block no longer calls dependency_refusal_reason (issue #566 fix removed?)\n'
  exit 1
fi
# docs/FLOW-SCHEMA.md, requirement 47, issue #596: the recorder also calls
# lib/rework.sh's rework_refinement_bounce_back_fields, out of this file's
# own scope (test/rework-record.test.sh covers it directly). Stubbed to
# print nothing, the same "does not fire" shape the real function returns
# whenever refinements_json (defined below, always "{}" here) carries no
# prior refinement for the item.
# shellcheck disable=SC2317  # invoked only by the eval'd record_needs_refinement_block
rework_refinement_bounce_back_fields() { :; }
eval "$record_needs_refinement_block_fn"

# --- The gh stub, through lib/refinement.sh's REFINEMENT_GH hook ------------
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1" == "issue" && "$2" == "view" ]]; then
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
[[ -n "$label" ]] && printf '%s %s %s %s\n' "$action" "$repo" "$number" "$label" >> "$d/label-calls"
[[ -n "$assignee" ]] && printf '%s %s %s %s\n' "$action" "$repo" "$number" "$assignee" >> "$d/assignee-calls"
exit 0
STUB
chmod +x "$tmp_dir/gh"
export REFINEMENT_GH="$tmp_dir/gh"
: > "$tmp_dir/issue-assignees"

# --- Fixed globals every call needs ------------------------------------------
# shellcheck disable=SC2034
needs_refinement_label="needs-refinement"
# shellcheck disable=SC2034
enabler_assignee="tester"
# shellcheck disable=SC2034
refined_label=""
# shellcheck disable=SC2034
refinements_json="{}"
# shellcheck disable=SC2034
DRY_RUN=0
# shellcheck disable=SC2034  # read by the eval'd record_needs_refinement_block
blocked_json="[]"

# events_of collects every event this run's stubbed log_event recorded, one
# "name payload" line per call.
events_log=""
# shellcheck disable=SC2317  # called only from the eval'd record_needs_refinement_block
log_event() { events_log+="$1 $2"$'\n'; }

run_block() {  # run_block ENTRY STAGE -> rc on stdout as "rc N", then the event log
  local entry="$1" stage="$2" rc
  events_log=""
  rm -f "$tmp_dir/label-calls" "$tmp_dir/assignee-calls"
  record_needs_refinement_block "$entry" "$stage"
  rc=$?
  printf 'rc %s\n' "$rc"
  printf '%s' "$events_log"
  sed 's/^/gh-label /' "$tmp_dir/label-calls" 2>/dev/null || true
  sed 's/^/gh-assignee /' "$tmp_dir/assignee-calls" 2>/dev/null || true
}

# ==============================================================================
# (a) The agent-ops#566 incident shape: an issue's thread still carries a
# `Blocked-by: #410` line after #410 closed — present in this cycle's
# issues_by_repo_json, proof the live gate already resolved it — and the
# Co-Ordinator's own entry names #410 as the reason. Refused: no block, no
# label, no assignment, a warning naming the resolved reference.
# ==============================================================================
# shellcheck disable=SC2034  # read by the eval'd record_needs_refinement_block
issues_by_repo_json='{"o/r":{"411":{"body":"Needs #410 first.\n\nBlocked-by: #410","comments":[]}}}'
entry_566='{"repo":"o/r","item":"411","source":"issues","reason":"blocked on #410",
            "missing":"nothing — waiting on #410 to close","evidence":"issue thread: Blocked-by #410, still open"}'
out="$(run_block "$entry_566" "coordinator")"

assert_eq "(a) the #566-shaped entry is refused" "rc 1" "$(grep -m1 '^rc ' <<<"$out")"
assert_eq "(a) no attempt-failed event is written" "0" "$(grep -cE '^attempt-failed ' <<<"$out")"
warning_line="$(grep -E '^warning ' <<<"$out" | head -n1)"
assert_contains "(a) the warning names Co-Ordinator, the item, and refused" \
  "Co-Ordinator needs_refinement entry for o/r 411 refused" "$warning_line"
assert_contains "(a) the warning names the resolved reference" "#410" "$warning_line"
assert_eq "(a) no label reaches gh" "0" "$(grep -cE '^gh-label ' <<<"$out")"
assert_eq "(a) no assignment reaches gh" "0" "$(grep -cE '^gh-assignee ' <<<"$out")"

# ==============================================================================
# (b) The judgement half survives: a genuine under-specification report on
# an item whose thread also carries a resolved dependency, but whose own
# reason/missing/evidence never names it. Recorded exactly as before —
# labelled, assigned, an attempt-failed written.
# ==============================================================================
entry_genuine='{"repo":"o/r","item":"411","source":"issues","reason":"no acceptance criteria",
                "missing":"what counts as a fixed 500?","evidence":"the issue body names no criteria at all"}'
out="$(run_block "$entry_genuine" "coordinator")"

assert_eq "(b) a genuine under-specification report is recorded" "rc 0" "$(grep -m1 '^rc ' <<<"$out")"
assert_eq "(b) exactly one attempt-failed event is written" "1" "$(grep -cE '^attempt-failed ' <<<"$out")"
af_evt="$(grep -E '^attempt-failed ' <<<"$out" | sed -E 's/^attempt-failed //' | head -n1)"
assert_eq "(b) it is marked the refinement kind" "needs-refinement" "$(jq -r '.kind' <<<"$af_evt")"
assert_contains "(b) the label reaches gh" "gh-label add o/r 411 needs-refinement" "$out"

# ==============================================================================
# (c) An item this cycle never gathered (absent from issues_by_repo_json)
# decides nothing here — "unknown is never gone" — so a report naming a
# dependency for it is recorded on the ordinary bar, not refused.
# ==============================================================================
entry_ungathered='{"repo":"o/r","item":"999","source":"issues","reason":"blocked on #1",
                   "missing":"nothing","evidence":"blocked on #1, closed"}'
out="$(run_block "$entry_ungathered" "coordinator")"
assert_eq "(c) an item absent from issues_by_repo_json is not refused on this bar" \
  "rc 0" "$(grep -m1 '^rc ' <<<"$out")"

# ==============================================================================
# (d) A non-issues source citing a dependency-shaped number is never refused
# on this bar either — the convention is documented for issue threads only.
# ==============================================================================
entry_td='{"repo":"o/r","item":"TD1","source":"tech-debt","reason":"blocked on #410",
           "missing":"nothing","evidence":"blocked on #410, closed"}'
out="$(run_block "$entry_td" "coordinator")"
assert_eq "(d) a non-issues source is never refused on this bar" \
  "rc 0" "$(grep -m1 '^rc ' <<<"$out")"

# ==============================================================================
# (e) The malformed-entry bar (requirement 34d) still runs ahead of this one:
# an entry short of a required field is dropped for that reason, not this one.
# ==============================================================================
entry_bare='{"repo":"o/r","item":"411","source":"issues","reason":"blocked on #410"}'
out="$(run_block "$entry_bare" "coordinator")"
assert_eq "(e) a malformed entry is still refused" "rc 1" "$(grep -m1 '^rc ' <<<"$out")"
warning_line="$(grep -E '^warning ' <<<"$out" | head -n1)"
assert_contains "(e) ...on the completeness bar, not the dependency one" \
  "entry dropped" "$warning_line"

echo
if (( failures == 0 )); then
  echo "All dependency-block-refusal assertions passed."
  exit 0
else
  echo "$failures dependency-block-refusal assertion(s) FAILED."
  exit 1
fi
