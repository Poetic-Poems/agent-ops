#!/usr/bin/env bash
#
# test/issues-excluded-wiring.test.sh — regression test for the
# agent-cycle.sh half of the `issues-excluded` wiring (requirements 3j and
# 33, agent-ops#447; on-change logging and the shared sidecar-path helper
# from the review decisions on agent-ops#452).
#
# test/issues-prefetch.test.sh and test/dependency-gate.test.sh already cover
# the gatherer side — scripts/gather-issues.sh applying the deterministic
# filter and reporting `{candidates, excluded}` — and
# test/repo-entry-build.test.sh covers `issues_excluded` reaching the
# Co-Ordinator's runtime input. What none of them touch is the wiring
# in between, entirely inside agent-cycle.sh:
#
#   1. **The sidecar round trip.** `gather_issues` writes the exclusion
#      report to a sibling file and `gather_issues_excluded` reads it back;
#      the two used to compute the sidecar's filename independently, so
#      agreement depended on nothing but two literal expressions staying
#      identical. `issues_excluded_sidecar_path` is now the one place that
#      computation happens.
#   2. **The `issues-excluded` event itself** — that `log_event` is actually
#      called, with a payload carrying `repo`, `count`, `excluded` and the
#      `detail` string requirement 33 promises.
#   3. **The on-change semantics** the review decided on agent-ops#452
#      concern 1: log only when a repo's exclusion set differs from the one
#      most recently logged for it, so a healthy steady state does not
#      repeat a byte-identical row every cycle onto a log that is never
#      rotated — but a release from exclusion (the set clearing) is exactly
#      as visible as an onset was.
#   4. **The unknown-skips rule** the review decided on agent-ops#452
#      concern 3: `gather_issues_excluded` reporting `null` — a degraded or
#      failed gather, distinct from a gather that ran and found nothing —
#      must be a no-op on the event stream: no comparison, no event, no
#      baseline update, so a transient `gh` hiccup neither fabricates a
#      release from exclusion nor resets the staleness clock requirement
#      16.4 depends on.
#
# Each function/block under test is lifted whole out of agent-cycle.sh by its
# own literal start/end lines, the same technique test/repo-entry-build.test.sh
# and test/log-event.test.sh use — so a change to the real code is what this
# suite tests, not a reimplementation of it.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/issues-excluded-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Lift the pieces under test whole out of agent-cycle.sh -----------------

# issues_excluded_sidecar_path, gather_issues and gather_issues_excluded: three
# consecutive top-level functions with no braces of their own inside them, so
# the third bare "}" line ends the block.
sidecar_fns_src="$(awk '
  index($0, "issues_excluded_sidecar_path() {") == 1 { on = 1 }
  on { print; if ($0 == "}") { n++; if (n == 3) exit } }
' "$SCRIPT_DIR/lib/candidate-select.sh")"
if [[ "$sidecar_fns_src" != *'issues_excluded_sidecar_path'* \
   || "$sidecar_fns_src" != *'gather_issues_excluded'* ]]; then
  printf 'FAIL - could not extract issues_excluded_sidecar_path/gather_issues/gather_issues_excluded from agent-cycle.sh (moved or reworded?)\n'
  exit 1
fi

# log_event: one top-level function, same extraction test/log-event.test.sh uses.
log_event_src="$(awk '
  index($0, "log_event() {") == 1 { on = 1 }
  on { print; if ($0 == "}") exit }
' "$SCRIPT_DIR/agent-cycle.sh")"
if [[ "$log_event_src" != *'--argjson fields'* ]]; then
  printf 'FAIL - could not extract log_event from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi

# The inline issues-source block in the main gather loop (requirement 3j):
# not a function, so it is lifted by its own literal start/end lines, the same
# technique test/repo-entry-build.test.sh uses for the sibling block one call
# downstream.
issues_block_src="$(awk '
  index($0, "  # The issues source is one source at four ranks") == 1 { on = 1 }
  on && index($0, "  tech_debt=\"[]\"") == 1 { exit }
  on { print }
' "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ "$issues_block_src" != *'issues-excluded'* \
   || "$issues_block_src" != *'latest_issues_excluded_json'* ]]; then
  printf 'FAIL - could not extract the issues-source block from lib/candidate-gather.sh (moved or reworded?)\n'
  exit 1
fi

# =============================================================================
# Part 1: the sidecar round trip
# =============================================================================

cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"
fakebin="$tmp_dir/fakebin/scripts"
mkdir -p "$fakebin"
stub_output="$tmp_dir/gather-issues-stub-output.json"
cat > "$fakebin/gather-issues.sh" <<'STUB'
#!/usr/bin/env bash
cat "$GATHER_ISSUES_STUB_OUTPUT"
STUB
chmod +x "$fakebin/gather-issues.sh"

# run_gather_issues <slug> — invoke the real gather_issues in a subshell
# pointed at the fake gatherer, printing its stdout.
run_gather_issues() {
  (
    SCRIPT_DIR="$tmp_dir/fakebin"
    GATHER_ISSUES_STUB_OUTPUT="$stub_output"
    export GATHER_ISSUES_STUB_OUTPUT
    eval "$sidecar_fns_src"
    gather_issues "$1"
  )
}

run_gather_issues_excluded() {
  (
    eval "$sidecar_fns_src"
    gather_issues_excluded "$1"
  )
}

# A slug shaped like every real one — owner/repo — so the `/`→`_`
# sanitisation the sidecar filename depends on is exercised on both the write
# side (gather_issues) and the read side (gather_issues_excluded).
slug="Poetic-Poems/agent-ops"

jq -nc '{candidates: [{"number": 1}], excluded: [{"number": 125, "reason": "assigned"}]}' \
  > "$stub_output"
candidates_out="$(run_gather_issues "$slug")"
excluded_out="$(run_gather_issues_excluded "$slug")"

assert_eq "round trip: gather_issues still returns the bare candidates array" \
  '[{"number":1}]' "$candidates_out"
assert_eq "round trip: gather_issues_excluded reads back exactly what gather_issues wrote" \
  '[{"number":125,"reason":"assigned"}]' "$excluded_out"

expected_sidecar="$cycle_dir/issues-excluded-Poetic-Poems_agent-ops.json"
assert_eq "round trip: the shared helper computes the same path gather_issues wrote to" \
  "1" "$( [[ -f "$expected_sidecar" ]] && echo 1 || echo 0 )"

# Degrade 1: the gatherer's output is not the {candidates, excluded} object —
# a bare array, the pre-agent-ops#447 shape — so candidates falls back to []
# and excluded falls back to null: this catastrophic shape means "gather
# did not run to completion", not "gathered, nothing excluded" (review
# decision on agent-ops#452 concern 3).
slug2="Poetic-Poems/poetic-fiddle"
jq -nc '[1, 2, 3]' > "$stub_output"
candidates_out2="$(run_gather_issues "$slug2")"
excluded_out2="$(run_gather_issues_excluded "$slug2")"
assert_eq "degrade: a non-object gatherer output falls back to empty candidates" \
  "[]" "$candidates_out2"
assert_eq "degrade: a non-object gatherer output falls back to null (unknown) excluded" \
  "null" "$excluded_out2"

# Degrade 1b: the gatherer ran and reported its own degrade — {candidates:
# [], excluded: null} — which round-trips through the sidecar unchanged.
slug2b="Poetic-Poems/poetic-mobile"
jq -nc '{candidates: [], excluded: null}' > "$stub_output"
candidates_out2b="$(run_gather_issues "$slug2b")"
excluded_out2b="$(run_gather_issues_excluded "$slug2b")"
assert_eq "degrade: the gatherer's own null excluded round-trips as empty candidates" \
  "[]" "$candidates_out2b"
assert_eq "degrade: the gatherer's own null excluded round-trips as null" \
  "null" "$excluded_out2b"

# Degrade 2: a slug gather_issues never ran for at all — no sidecar file —
# reads back as null: the absent-file case cannot arise at the one real call
# site (it always runs right after gather_issues), so it gets the same
# unknown reading rather than a special-cased [].
never_out="$(run_gather_issues_excluded "Poetic-Poems/never-gathered")"
assert_eq "degrade: an absent sidecar reads back as null (unknown) excluded" \
  "null" "$never_out"

# =============================================================================
# Part 2 and 3: the issues-excluded event, and its on-change semantics
# =============================================================================

log_file_path="$tmp_dir/log.jsonl"
map_file_path="$tmp_dir/latest-issues-excluded.json"
: > "$log_file_path"
rm -f "$map_file_path"

# run_issues_excluded_cycle <slug> <excluded-json> — run the real inline
# block once, as one repo's pass through the main gather loop would. Stubs
# every collaborator except log_event (the real one, lifted above) and the
# on-change comparison logic under test, which lives in the block itself.
# latest_issues_excluded_json persists across calls via map_file_path, the
# same way it persists across repos within one real cycle.
run_issues_excluded_cycle() {
  local slug_arg="$1" excluded_arg="$2"
  (
    # sources, claimed_item_refs_json, cycle_id, node_name and log_file below
    # are consumed only by the eval'd log_event/issues-source block, invisible
    # to static analysis. DRY_RUN=1 skips requirement 38b's live label
    # reconciliation (agent-ops#816) entirely, which this test has no stub
    # for and has nothing to do with — it is a real agent-cycle.sh global,
    # always set before this block ever runs for real.
    # shellcheck disable=SC2034
    slug="$slug_arg" sources='["issues:high"]' claimed_item_refs_json='[]' \
      cycle_id="test-cycle" node_name="test-node" log_file="$log_file_path" DRY_RUN=1
    latest_issues_excluded_json="$(cat "$map_file_path" 2>/dev/null || printf '{}')"
    [[ -n "$latest_issues_excluded_json" ]] || latest_issues_excluded_json='{}'
    # The four stubs below are likewise invoked only from inside the eval'd
    # block.
    # shellcheck disable=SC2317
    emit_first_seen() { :; }
    # shellcheck disable=SC2317
    exclude_claimed_items() { printf '%s' "$1"; }
    # shellcheck disable=SC2317
    gather_issues() { printf '[]'; }
    # shellcheck disable=SC2317
    gather_issues_excluded() { printf '%s' "$excluded_arg"; }
    eval "$log_event_src"
    eval "$issues_block_src"
    printf '%s' "$latest_issues_excluded_json" > "$map_file_path"
  )
}

lines_before() { wc -l < "$log_file_path" | tr -d ' '; }

# --- 3a: first non-empty set logs -------------------------------------------
before="$(lines_before)"
run_issues_excluded_cycle "o/r" '[{"number":125,"reason":"assigned"}]'
after="$(lines_before)"
assert_eq "first non-empty exclusion set logs exactly one event" \
  "1" "$(( after - before ))"

last_line="$(tail -n 1 "$log_file_path")"
assert_eq "the logged line parses as JSON" "true" \
  "$(jq -e 'type == "object"' <<<"$last_line" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "the logged line carries event == issues-excluded" \
  "issues-excluded" "$(jq -r '.event' <<<"$last_line")"
assert_eq "the logged line carries the repo" \
  "o/r" "$(jq -r '.repo' <<<"$last_line")"
assert_eq "the logged line carries the count" \
  "1" "$(jq -r '.count' <<<"$last_line")"
assert_eq "the logged line carries the excluded array verbatim" \
  '[{"number":125,"reason":"assigned"}]' "$(jq -c '.excluded' <<<"$last_line")"
assert_eq "the logged line's detail renders as requirement 33 promises" \
  "1 issue(s) excluded: #125 (assigned)" "$(jq -r '.detail' <<<"$last_line")"

# --- 3b: an identical set next cycle logs nothing ---------------------------
before="$(lines_before)"
run_issues_excluded_cycle "o/r" '[{"number":125,"reason":"assigned"}]'
after="$(lines_before)"
assert_eq "an unchanged exclusion set logs nothing" "0" "$(( after - before ))"

# ... and a second identical cycle stays quiet too, so "logs nothing" is a
# steady state rather than a one-cycle suppression.
before="$(lines_before)"
run_issues_excluded_cycle "o/r" \
  '[{"number":125,"reason":"assigned"}]'
after="$(lines_before)"
assert_eq "a byte-identical repeat stays quiet on a second confirmation" \
  "0" "$(( after - before ))"

# --- 3c: a changed set logs ---------------------------------------------------
before="$(lines_before)"
run_issues_excluded_cycle "o/r" \
  '[{"number":125,"reason":"assigned"},{"number":140,"reason":"blocked-label"}]'
after="$(lines_before)"
assert_eq "a changed exclusion set logs exactly one event" \
  "1" "$(( after - before ))"
last_line="$(tail -n 1 "$log_file_path")"
assert_eq "the changed set's count reflects the new size" \
  "2" "$(jq -r '.count' <<<"$last_line")"

# ... the same two members in a different array order are the same set, not a
# change: gather-issues.sh imposes no order on `excluded`, so without the
# `sort_by` both sides of the comparison carry, a reordered-but-identical
# report would log a spurious edge every time the order shifted.
before="$(lines_before)"
run_issues_excluded_cycle "o/r" \
  '[{"number":140,"reason":"blocked-label"},{"number":125,"reason":"assigned"}]'
after="$(lines_before)"
assert_eq "the same members in a different order count as unchanged" \
  "0" "$(( after - before ))"

# --- 3d: a cleared set logs too, with count 0 -------------------------------
before="$(lines_before)"
run_issues_excluded_cycle "o/r" '[]'
after="$(lines_before)"
assert_eq "a cleared exclusion set (a release) logs exactly one event" \
  "1" "$(( after - before ))"
last_line="$(tail -n 1 "$log_file_path")"
assert_eq "the cleared set logs with count 0" \
  "0" "$(jq -r '.count' <<<"$last_line")"
assert_eq "the cleared set logs with an empty excluded array" \
  "[]" "$(jq -c '.excluded' <<<"$last_line")"
assert_eq "the cleared set's detail has no dangling colon" \
  "0 issue(s) excluded" "$(jq -r '.detail' <<<"$last_line")"

# ... and staying cleared next cycle logs nothing further.
before="$(lines_before)"
run_issues_excluded_cycle "o/r" '[]'
after="$(lines_before)"
assert_eq "an exclusion set that stays cleared logs nothing further" \
  "0" "$(( after - before ))"

# --- A second repo is tracked independently ---------------------------------
before="$(lines_before)"
run_issues_excluded_cycle "o/other" '[{"number":9,"reason":"blocked-label"}]'
after="$(lines_before)"
assert_eq "a different repo's first non-empty set logs independently of o/r's state" \
  "1" "$(( after - before ))"

# --- Fail-open: an unreadable previous-state map logs unconditionally ------
printf 'not valid json' > "$map_file_path"
before="$(lines_before)"
run_issues_excluded_cycle "o/r" '[]'
after="$(lines_before)"
assert_eq "a corrupt previous-state map fails open (logs, does not stay silent)" \
  "1" "$(( after - before ))"

# =============================================================================
# Part 4: the unknown-skips rule (review decision on agent-ops#452 concern 3)
# =============================================================================
#
# `gather_issues_excluded` reporting `null` means the gather failed or
# degraded — the current exclusion set is unknown, not known-empty — and
# must be a no-op on the event stream: no comparison, no event, no baseline
# update. Asserting a release from exclusion on an ordinary `gh` hiccup would
# be a falsehood a healthy empty set never is, and overwriting the baseline
# would let a flapping gatherer erase the staleness signal requirement 16.4
# depends on.
printf '{}' > "$map_file_path"

# Establish a non-empty baseline for a fresh repo.
before="$(lines_before)"
run_issues_excluded_cycle "o/degrade" '[{"number":77,"reason":"assigned"}]'
after="$(lines_before)"
assert_eq "unknown-skips: establishing a baseline logs exactly one event" \
  "1" "$(( after - before ))"

# A degraded gather (`null`) leaves both the log and the baseline untouched.
before="$(lines_before)"
run_issues_excluded_cycle "o/degrade" 'null'
after="$(lines_before)"
assert_eq "unknown-skips: a degraded gather (null) logs nothing" \
  "0" "$(( after - before ))"
baseline_after_degrade="$(jq -c '.["o/degrade"]' "$map_file_path")"
assert_eq "unknown-skips: a degraded gather leaves the baseline untouched" \
  '[{"number":77,"reason":"assigned"}]' "$baseline_after_degrade"

# A recovered gather reporting the same real set logs nothing — the
# baseline survived the degraded cycle in between.
before="$(lines_before)"
run_issues_excluded_cycle "o/degrade" '[{"number":77,"reason":"assigned"}]'
after="$(lines_before)"
assert_eq "unknown-skips: a recovered gather reporting the unchanged set logs nothing" \
  "0" "$(( after - before ))"

# A recovered gather reporting a genuinely changed set logs the real edge —
# the degraded cycle in between did not mask it.
before="$(lines_before)"
run_issues_excluded_cycle "o/degrade" \
  '[{"number":77,"reason":"assigned"},{"number":88,"reason":"blocked-label"}]'
after="$(lines_before)"
assert_eq "unknown-skips: a recovered gather reporting a changed set logs exactly one event" \
  "1" "$(( after - before ))"
last_line="$(tail -n 1 "$log_file_path")"
assert_eq "unknown-skips: the changed set's count reflects the new size" \
  "2" "$(jq -r '.count' <<<"$last_line")"

# A degraded gather on a repo whose baseline was already empty stays quiet
# too, and does not spuriously create a map entry.
before="$(lines_before)"
run_issues_excluded_cycle "o/never-excluded" 'null'
after="$(lines_before)"
assert_eq "unknown-skips: a degraded gather with no prior baseline logs nothing" \
  "0" "$(( after - before ))"
assert_eq "unknown-skips: ... and adds no baseline entry" \
  "null" "$(jq -c '.["o/never-excluded"] // null' "$map_file_path")"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
