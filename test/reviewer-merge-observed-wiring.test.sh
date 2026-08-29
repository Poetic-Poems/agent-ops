#!/usr/bin/env bash
#
# test/reviewer-merge-observed-wiring.test.sh — regression test for the two
# dispatch blocks agent-cycle.sh's Reviewer stage adds for agent-ops#916
# (requirements 31d/32c): a subject pull request that has already merged
# must never reach `pr-ready`, an Approver engagement or a landing attempt,
# whatever the Reviewer's own verdict says.
#
#   - **The stage-start advisory block** (just inside "--- 8. Reviewer stage
#     ---"): a merged `$impl_pr_url` skips the whole Reviewer engagement,
#     reaching `reviewer_merge_observed` at zero stage cost.
#   - **The handoff block** (right after `$rev_status` is parsed, ahead of
#     the ready/blocked branch): a merged `$impl_pr_url` reaches the same
#     completion whether the Reviewer's own verdict is "ready" (never
#     noticed) or "blocked" (noticed and said so); an unreadable merge state
#     on an otherwise-"ready" verdict refuses the handoff instead of running
#     it; anything else — the ordinary "open" case — falls through to the
#     pre-existing ready/blocked branch unchanged.
#
# Both blocks are lifted verbatim out of agent-cycle.sh, the same technique
# test/human-reviewer-handoff-wiring.test.sh already uses: the assertions are
# about the shipped code, not a copy of its logic. `reviewer_merge_observed`,
# `log_reviewer_handback` and `pr_merge_state` are stubbed as recorders —
# each is unit-tested on its own terms elsewhere (test/merge-observed.test.sh,
# test/handoff.test.sh's `confirm_pr_ready` sibling in
# test/pr-merge-state.test.sh) — so this file owns only the thinner question:
# given each shape those three can return, does agent-cycle.sh's own
# dispatch do the right thing with it?
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/reviewer-merge-observed-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file's whole business is assembling scripts whose `$`-expressions must
# reach the assembled file unexpanded; the single-quoted patterns and printf
# templates below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Extraction ---------------------------------------------------------------
# extract_block START_PATTERN MARKER_PATTERN FILE
# Turns on at START_PATTERN, prints every line while on, and stops at the
# first bare "fi" line seen *after* MARKER_PATTERN — which skips any inner
# if/fi pair (this file's own `if [[ -n "$impl_pr_url" ]]; then … fi` guard)
# that closes before the marker is ever reached.
extract_block() {
  local start="$1" marker="$2" file="$3"
  awk -v start="$start" -v marker="$marker" '
    $0 ~ start { on = 1 }
    on { print }
    on && seen && /^fi$/ { exit }
    on && $0 ~ marker { seen = 1 }
  ' "$file"
}

stage_start_block="$(extract_block \
  '^pre_reviewer_merge_state=""; pre_reviewer_merge_sha=""$' \
  'reviewer-stage-start' \
  "$CYCLE")"

merged_block="$(extract_block \
  '^merge_state=""; merge_sha=""$' \
  'reviewer_merge_observed "\$impl_pr_url" "\$merge_sha" "\$rev_status_json" "reviewer"' \
  "$CYCLE")"

failed_ready_block="$(awk '
  /^if \[\[ "\$rev_status" == "ready" && "\$merge_state" == "failed" \]\]; then$/ { on = 1 }
  on { print }
  on && /^fi$/ { exit }
' "$CYCLE")"

for pair in "stage_start:$stage_start_block" "merged:$merged_block" "failed_ready:$failed_ready_block"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL - could not extract the ${pair%%:*} block from agent-cycle.sh — has it moved?" >&2
    exit 1
  fi
done

# --- Assembly -------------------------------------------------------------
# run_block BLOCK PR_URL EXTRA_SEED_LINES
# Runs BLOCK under the same `set -euo pipefail` agent-cycle.sh runs under,
# with `impl_pr_url` seeded and every stub/global EXTRA_SEED_LINES sets
# applied first. `pr_merge_state`, `reviewer_merge_observed` and
# `log_reviewer_handback` all record their calls as one line each in
# $tmp_dir/calls; a real `echo`/`exit 0` inside BLOCK ends the harness itself,
# which run_block treats as an ordinary (successful) exit.
run_block() {
  local block="$1" pr_url="$2" extra="$3" harness="$tmp_dir/harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'impl_pr_url=%q\n' "$pr_url"
    printf '%s\n' "$extra"
    printf '%s\n' 'pr_merge_state() { printf "%s\t%s\n" "pr_merge_state" "$*" >>'"$(printf '%q' "$tmp_dir/calls")"'; printf "%s" "$PR_MERGE_STATE_RESULT"; }'
    printf '%s\n' 'reviewer_merge_observed() { printf "%s\t%s\n" "reviewer_merge_observed" "$*" >>'"$(printf '%q' "$tmp_dir/calls")"'; }'
    printf '%s\n' 'log_reviewer_handback() { printf "%s\t%s\n" "log_reviewer_handback" "$*" >>'"$(printf '%q' "$tmp_dir/calls")"'; }'
    printf '%s\n' "$block"
    printf '%s\n' 'echo "__fell_through__"'
  } > "$harness"
  : > "$tmp_dir/calls"
  bash "$harness" 2>"$tmp_dir/stderr"
}

calls_named() { grep $'^'"$1"$'\t' "$tmp_dir/calls" | cut -f2-; }

URL="https://github.com/Poetic-Poems/agent-ops/pull/916"

# === Stage-start advisory block ================================================

# --- Merged: reviewer_merge_observed fires, no stage ever launches -----------
out="$(PR_MERGE_STATE_RESULT=$'merged\tb48eebf' run_block "$stage_start_block" "$URL" 'true')"
assert_contains "stage-start: a merged subject calls reviewer_merge_observed" \
  "$URL b48eebf {} reviewer-stage-start" "$(calls_named reviewer_merge_observed)"
assert_lacks "  ... and the block itself ends the cycle (no fall-through)" "__fell_through__" "$out"

# --- Open: falls through, nothing fires ---------------------------------------
out="$(PR_MERGE_STATE_RESULT=$'open\t' run_block "$stage_start_block" "$URL" 'true')"
assert_eq "stage-start: an open subject calls reviewer_merge_observed not at all" \
  "" "$(calls_named reviewer_merge_observed)"
assert_contains "  ... and falls through to the rest of the Reviewer stage" \
  "__fell_through__" "$out"

# --- Unreadable: advisory, falls through — the handoff read still guards it --
out="$(PR_MERGE_STATE_RESULT=$'failed\t' run_block "$stage_start_block" "$URL" 'true')"
assert_eq "stage-start: an unreadable state also falls through (advisory only)" \
  "" "$(calls_named reviewer_merge_observed)"
assert_contains "  ... running the stage rather than blocking on it" \
  "__fell_through__" "$out"

# --- No pull request at all: pr_merge_state is never even asked --------------
out="$(PR_MERGE_STATE_RESULT=$'open\t' run_block "$stage_start_block" "" 'true')"
assert_eq "stage-start: an empty impl_pr_url skips the read entirely" \
  "" "$(calls_named pr_merge_state)"

# === Handoff block ==============================================================

# --- Merged, Reviewer said "ready" (never noticed) ----------------------------
out="$(PR_MERGE_STATE_RESULT=$'merged\tb48eebf' run_block "$merged_block" "$URL" 'rev_status="ready"; rev_status_json="{\"status\":\"ready\"}"')"
assert_contains "handoff: a merged subject completes via reviewer_merge_observed (ready verdict)" \
  "$URL b48eebf {\"status\":\"ready\"} reviewer" "$(calls_named reviewer_merge_observed)"
assert_lacks "  ... never reaching the ordinary ready/blocked branch" "__fell_through__" "$out"

# --- Merged, Reviewer said "blocked" naming the merge (noticed) --------------
out="$(PR_MERGE_STATE_RESULT=$'merged\tb48eebf' run_block "$merged_block" "$URL" 'rev_status="blocked"; rev_status_json="{\"status\":\"blocked\",\"reason\":\"merged mid-pass\"}"')"
assert_contains "handoff: a merged subject completes the same way for a blocked verdict too" \
  "$URL b48eebf {\"status\":\"blocked\",\"reason\":\"merged mid-pass\"} reviewer" \
  "$(calls_named reviewer_merge_observed)"
assert_eq "  ... this is a completion, never an attempt-failed handback" \
  "" "$(calls_named log_reviewer_handback)"

# --- Open, Reviewer said "ready": falls through to the ordinary path ---------
out="$(PR_MERGE_STATE_RESULT=$'open\t' run_block "$merged_block" "$URL" 'rev_status="ready"; rev_status_json="{\"status\":\"ready\"}"')"
assert_eq "handoff: an open subject calls reviewer_merge_observed not at all" \
  "" "$(calls_named reviewer_merge_observed)"
assert_contains "  ... and falls through to the ordinary ready/blocked branch" \
  "__fell_through__" "$out"

# --- Open, Reviewer said "blocked" for an unrelated reason: unaffected -------
out="$(PR_MERGE_STATE_RESULT=$'open\t' run_block "$merged_block" "$URL" 'rev_status="blocked"; rev_status_json="{\"status\":\"blocked\",\"reason\":\"lint failing\"}"')"
assert_eq "handoff: an ordinary blocked verdict is untouched by this block" \
  "" "$(calls_named reviewer_merge_observed)"

# --- A Reviewer claiming a merge GitHub denies: falls through as a model error
out="$(PR_MERGE_STATE_RESULT=$'open\t' run_block "$merged_block" "$URL" 'rev_status="blocked"; rev_status_json="{\"status\":\"blocked\",\"reason\":\"the subject merged\"}"')"
assert_eq "handoff: a claimed merge the Script cannot confirm is not a completion" \
  "" "$(calls_named reviewer_merge_observed)"
assert_contains "  ... it falls through to the ordinary attempt-failed handling" \
  "__fell_through__" "$out"

# === Failed-merge-state-on-ready refusal =======================================

# --- Ready, but the merge state could not be read: refuse, never hand off ---
out="$(run_block "$failed_ready_block" "$URL" 'rev_status="ready"; merge_state="failed"')"
assert_contains "handoff: an unreadable merge state on a ready verdict is refused" \
  "could not be confirmed" "$(calls_named log_reviewer_handback)"
assert_eq "  ... naming this pull request" "1" "$(calls_named log_reviewer_handback | grep -c "$URL" || true)"
assert_lacks "  ... and never falls through to the ordinary ready path" "__fell_through__" "$out"

# --- Ready, merge state open: this block has nothing to say ------------------
out="$(run_block "$failed_ready_block" "$URL" 'rev_status="ready"; merge_state="open"')"
assert_eq "handoff: an open merge state on a ready verdict is not refused here" \
  "" "$(calls_named log_reviewer_handback)"
assert_contains "  ... and falls through" "__fell_through__" "$out"

# --- Blocked, merge state failed: this block only ever fires for "ready" ----
out="$(run_block "$failed_ready_block" "$URL" 'rev_status="blocked"; merge_state="failed"')"
assert_eq "handoff: an unreadable merge state on a blocked verdict is left alone here" \
  "" "$(calls_named log_reviewer_handback)"
assert_contains "  ... falling through to the ordinary attempt-failed handling" \
  "__fell_through__" "$out"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
