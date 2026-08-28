#!/usr/bin/env bash
#
# test/fit-trim-block-refusal.test.sh — regression test for issue #683: a
# context-tight Co-Ordinator cycle whose fit ladder (requirement 4i) reached
# its bottom rung mass-flagged its whole visible backlog `needs-refinement` —
# nine items, most of them already refined, in 68 seconds — because "if you
# cannot tell what done would mean, report needs_refinement" and requirement
# 3x's completeness bar are each individually correct and jointly compel
# exactly that outcome once every candidate's body has been trimmed to a
# title-level fragment.
#
# `record_needs_refinement_block` (requirement 34e's fourth refusal) and
# `unaccounted_items`/`coordinator_unassessable_items` (requirement 3x's
# matching exemption) are lifted verbatim out of lib/candidate-select.sh with
# awk and eval'd, the same technique test/dependency-block-refusal.test.sh
# uses, so what is under test is the genuine recording and completeness path,
# not a paraphrase of it. `coordinator_fit_trimmed_items`/
# `coordinator_fit_trim_refusal_reason` (lib/coordinator-input.sh) are
# exercised directly in test/coordinator-input.test.sh; this file's job is
# the integration those unit tests cannot see: that the real recorder and the
# real completeness check actually apply them.
#
# `gh` is stubbed through REFINEMENT_GH, the same shape as
# test/dependency-block-refusal.test.sh. No test framework is used (none
# exists elsewhere in this repo). Run it directly:
#
#   ./test/fit-trim-block-refusal.test.sh
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

# --- Lift the functions under test verbatim -----------------------------------
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
  printf 'FAIL - record_needs_refinement_block could not be found in lib/candidate-select.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$record_needs_refinement_block_fn" != *"coordinator_fit_trim_refusal_reason"* ]]; then
  printf 'FAIL - record_needs_refinement_block no longer calls coordinator_fit_trim_refusal_reason (issue #683 fix removed?)\n'
  exit 1
fi
# docs/FLOW-SCHEMA.md, requirement 47, issue #596: the recorder also calls
# lib/rework.sh's rework_refinement_bounce_back_fields, out of this file's
# own scope (test/rework-record.test.sh covers it directly). Stubbed to
# print nothing, the same "does not fire" shape the real function returns
# whenever refinements_json (defined below, always "{}" here) carries no
# prior refinement for the item.
rework_refinement_bounce_back_fields() { :; }
eval "$record_needs_refinement_block_fn"

extract_pat() {  # extract_pat <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$SCRIPT_DIR/lib/candidate-select.sh"
}
unaccounted_items_fn="$(extract_pat unaccounted_items)"
coordinator_unassessable_items_fn="$(extract_pat coordinator_unassessable_items)"
[[ -n "$unaccounted_items_fn" ]] || { printf 'FAIL - unaccounted_items could not be found\n'; exit 1; }
[[ -n "$coordinator_unassessable_items_fn" ]] || { printf 'FAIL - coordinator_unassessable_items could not be found\n'; exit 1; }
eval "$unaccounted_items_fn"
eval "$coordinator_unassessable_items_fn"

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
repo=""; action=""; label=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) repo="$2"; shift 2 ;;
    --add-label) action="add"; label="$2"; shift 2 ;;
    --remove-label) action="remove"; label="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$label" ]] && printf '%s %s %s %s\n' "$action" "$repo" "$number" "$label" >> "$d/label-calls"
exit 0
STUB
chmod +x "$tmp_dir/gh"
export REFINEMENT_GH="$tmp_dir/gh"
: > "$tmp_dir/issue-assignees"

# --- Fixed globals every call needs ------------------------------------------
# shellcheck disable=SC2034
needs_refinement_label="needs-refinement"
# shellcheck disable=SC2034
refined_label=""
# shellcheck disable=SC2034
refinements_json="{}"
# shellcheck disable=SC2034
DRY_RUN=0
# shellcheck disable=SC2034  # read by the eval'd record_needs_refinement_block
blocked_json="[]"
# shellcheck disable=SC2034
issues_by_repo_json="{}"

events_log=""
# shellcheck disable=SC2317  # called only from the eval'd functions
log_event() { events_log+="$1 $2"$'\n'; }
# shellcheck disable=SC2317  # called from the lifted unaccounted_items/coordinator_unassessable_items on their fail-open paths
guard_warn() { :; }

run_block() {  # run_block ENTRY STAGE -> rc on stdout as "rc N", then the event log
  local entry="$1" stage="$2" rc
  events_log=""
  rm -f "$tmp_dir/label-calls"
  record_needs_refinement_block "$entry" "$stage"
  rc=$?
  printf 'rc %s\n' "$rc"
  printf '%s' "$events_log"
  sed 's/^/gh-label /' "$tmp_dir/label-calls" 2>/dev/null || true
}

# ==============================================================================
# (a) The agent-ops#683 incident shape: the fit ladder's bottom rung trimmed
# every candidate's body, and the Co-Ordinator dutifully reported every one of
# them needs_refinement, exactly as its own prompt tells it to. Refused: no
# block, no label, a warning naming the item and the rung.
# ==============================================================================
# shellcheck disable=SC2034  # read by the eval'd record_needs_refinement_block
coordinator_fit_trimmed_json='[{"repo":"o/r","item":"11","source":"issues"},{"repo":"o/r","item":"12","source":"issues"}]'
# shellcheck disable=SC2034
coordinator_fit_rung=8
entry_683='{"repo":"o/r","item":"11","source":"issues","reason":"cannot tell what done means",
            "missing":"the trimmed body gives no acceptance criteria","evidence":"the elided extract"}'
out="$(run_block "$entry_683" "coordinator")"

assert_eq "(a) the #683-shaped entry is refused" "rc 1" "$(grep -m1 '^rc ' <<<"$out")"
assert_eq "(a) no attempt-failed event is written" "0" "$(grep -cE '^attempt-failed ' <<<"$out")"
warning_line="$(grep -E '^warning ' <<<"$out" | head -n1)"
assert_contains "(a) the warning names Co-Ordinator, the item, and refused" \
  "Co-Ordinator needs_refinement entry for o/r 11 refused" "$warning_line"
assert_contains "(a) the warning names the rung" "rung 8" "$warning_line"
assert_eq "(a) no label reaches gh" "0" "$(grep -cE '^gh-label ' <<<"$out")"

# ==============================================================================
# (b) A genuine report against an item this cycle's fit never touched is
# recorded exactly as before — labelled, an attempt-failed written.
# ==============================================================================
entry_genuine='{"repo":"o/r","item":"99","source":"issues","reason":"no acceptance criteria",
                "missing":"what counts as fixed?","evidence":"the issue body names no criteria at all"}'
out="$(run_block "$entry_genuine" "coordinator")"

assert_eq "(b) an untrimmed item's report is recorded" "rc 0" "$(grep -m1 '^rc ' <<<"$out")"
assert_eq "(b) exactly one attempt-failed event is written" "1" "$(grep -cE '^attempt-failed ' <<<"$out")"
assert_contains "(b) the label reaches gh" "gh-label add o/r 99 needs-refinement" "$out"

# ==============================================================================
# (c) The refusal is scoped to the Co-Ordinator: a Refiner or Implementer
# report against the same repo+item is not refused on this bar, because
# neither of them read this cycle's fit-ladder-trimmed Co-Ordinator input —
# they read the repository live.
# ==============================================================================
entry_refiner='{"repo":"o/r","item":"11","source":"issues","reason":"genuinely under-specified",
                "missing":"a live read still found nothing","evidence":"gh issue view --comments"}'
out="$(run_block "$entry_refiner" "refiner")"
assert_eq "(c) a Refiner report against the same item is not refused on this bar" \
  "rc 0" "$(grep -m1 '^rc ' <<<"$out")"

out="$(run_block "$entry_refiner" "implementer")"
assert_eq "(c) ...nor is an Implementer's" "rc 0" "$(grep -m1 '^rc ' <<<"$out")"

# ==============================================================================
# (d) The malformed-entry bar (requirement 34d) still runs ahead of this one:
# an entry short of a required field is dropped for that reason, not this one.
# ==============================================================================
entry_bare='{"repo":"o/r","item":"11","source":"issues","reason":"x"}'
out="$(run_block "$entry_bare" "coordinator")"
assert_eq "(d) a malformed entry is still refused" "rc 1" "$(grep -m1 '^rc ' <<<"$out")"
warning_line="$(grep -E '^warning ' <<<"$out" | head -n1)"
assert_contains "(d) ...on the completeness bar, not the fit-trim one" \
  "entry dropped" "$warning_line"

# ==============================================================================
# (e) requirement 3x's own half: with nothing recorded for either trimmed
# item (both refused in (a) and its twin below) and nothing else claimed,
# `unaccounted_items` must not flag them either, or the refusal above would
# just relocate the mass-flag into a "verdict contradiction" retry loop over
# the same trimmed input. This is the acceptance test for the bottom-rung
# scenario end to end: a coordinator that reported "selected: false" over a
# fully-trimmed cycle is accepted, and the trimmed items are logged as
# unassessable rather than forced into a block.
# ==============================================================================
eligible='[{"repo":"o/r","item":"11","source":"issues"},{"repo":"o/r","item":"12","source":"issues"}]'
recorded_none='{"needs_refinement": [], "voided": []}'
unaccounted="$(unaccounted_items "$recorded_none" "$eligible" '{}' "$coordinator_fit_trimmed_json")"
assert_eq "(e) a fully-trimmed cycle's 'selected: false' leaves nothing unaccounted" \
  "0" "$(jq 'length' <<<"$unaccounted")"
unassessable="$(coordinator_unassessable_items "$eligible" "$coordinator_fit_trimmed_json")"
assert_eq "(e) both trimmed eligible items are logged as unassessable instead" \
  "2" "$(jq 'length' <<<"$unassessable")"

echo
if (( failures == 0 )); then
  echo "All fit-trim-block-refusal assertions passed."
  exit 0
else
  echo "$failures fit-trim-block-refusal assertion(s) FAILED."
  exit 1
fi
