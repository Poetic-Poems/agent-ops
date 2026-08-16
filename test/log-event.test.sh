#!/usr/bin/env bash
#
# test/log-event.test.sh — regression tests for issue #361: log_event's
# envelope merge is jq's `+`, which cannot add an object and an array, and
# until 2026-08-13 a non-object FIELDS payload therefore killed the whole
# cycle — jq's runtime error is exit 5, `set -e` made it the script's exit,
# and because the one call site that passed an array ran before any stage,
# every node in the fleet crash-looped pre-selection the first time its
# guard fired.
#
# Also regression tests for issue #458: the non-object wrap's own fallback —
# `jq -c '{fields: .}' <<<"$fields" 2>/dev/null || jq -nc --arg f "$fields"
# '{fields: $f}'` — only ran when the first jq call *failed*. A
# whitespace-only (or otherwise empty-under-jq) FIELDS payload made that call
# exit 0 with empty stdout instead, so the `--arg` fallback never fired,
# `fields` was left as the empty string, and the envelope jq's own
# `--argjson fields ""` then errored and — under the append's `|| true` —
# dropped the event with no trace, exactly the vanishing #361 was raised to
# prevent.
#
# The contract pinned here is the logger's, not the call sites': whatever a
# caller passes,
#
#   - a JSON object merges into the envelope exactly as before;
#   - anything else — an array, a bare string, text that is not JSON at all,
#     or text that is empty or reduces to empty under jq's identity filter —
#     is recorded wrapped under `fields` rather than dying or vanishing;
#   - log_event returns 0 in every one of those cases, because a caller
#     running under `set -e` must never lose a cycle to an event record.
#
# Both copies of the function are exercised — agent-cycle.sh's (the cycle
# envelope) and review-cycle.sh's (the review envelope) — each lifted whole
# out of its script rather than reimplemented, so a change to the real
# function is what this suite tests.
#
# No network, no GitHub, no state beyond a temporary log file. Run directly:
#
#   ./test/log-event.test.sh
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

# --- Lift log_event whole out of each script ----------------------------------
# The same extraction shape test/pr-claim-exclusion.test.sh uses: the function
# is delimited by its `log_event() {` line and a `}` back at column 0.
extract_log_event() {  # extract_log_event <script-path>
  awk '
    /^log_event\(\) \{/ { on = 1 }
    on                  { print }
    on && /^}$/         { exit }
  ' "$1"
}

cycle_log_event_src="$(extract_log_event "$SCRIPT_DIR/agent-cycle.sh")"
review_log_event_src="$(extract_log_event "$SCRIPT_DIR/review-cycle.sh")"

if [[ "$cycle_log_event_src" != *'--argjson fields'* ]]; then
  printf 'FAIL - could not extract log_event from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$review_log_event_src" != *'--argjson fields'* ]]; then
  printf 'FAIL - could not extract log_event from review-cycle.sh (renamed or moved?)\n'
  exit 1
fi

# run_log_event <which> <event> [fields] — invoke the real function inside a
# `set -e` subshell (the caller's actual regime) against a fresh log file, then
# print "<rc>\t<lines-appended>\t<last-line-json>" for the assertions below.
run_log_event() {
  local which="$1" event="$2"
  local log="$tmp_dir/$which-$RANDOM.jsonl"
  shift 2
  (
    set -euo pipefail
    # shellcheck disable=SC2034  # read by the eval'd function bodies below.
    cycle_id="test-cycle" node_name="test-node" log_file="$log"
    # shellcheck disable=SC2034
    review_id="test-review" review_log_file="$log"
    if [[ "$which" == cycle ]]; then
      eval "$cycle_log_event_src"
    else
      eval "$review_log_event_src"
    fi
    log_event "$event" "$@"
  )
  local rc=$?
  local n=0 last=""
  [[ -f "$log" ]] && { n="$(wc -l < "$log")"; last="$(tail -n 1 "$log")"; }
  printf '%s\t%s\t%s' "$rc" "${n// /}" "$last"
}

# --- An object payload merges into the envelope, exactly as before ------------
IFS=$'\t' read -r rc n last <<<"$(run_log_event cycle "stand-down" '{"reason": "testing"}')"
assert_eq "object payload: log_event returns 0" "0" "$rc"
assert_eq "object payload: one event appended" "1" "$n"
assert_eq "object payload: fields merge into the envelope" "testing" \
  "$(jq -r '.reason' <<<"$last")"
assert_eq "object payload: the envelope carries the event name" "stand-down" \
  "$(jq -r '.event' <<<"$last")"

# --- The issue #361 payload: an array must cost the shape, never the cycle ----
stale='[{"repo": "Poetic-Poems/agent-ops", "item": "pr-350-conflict-d208a92310a1"}]'
IFS=$'\t' read -r rc n last <<<"$(run_log_event cycle "enabler-stale-refs-skipped" "$stale")"
assert_eq "array payload: log_event returns 0 under set -e (issue #361)" "0" "$rc"
assert_eq "array payload: the event still lands" "1" "$n"
assert_eq "array payload: recorded wrapped under .fields, not merged" "1" \
  "$(jq -r '.fields | length' <<<"$last")"
assert_eq "array payload: the wrapped record is intact" "pr-350-conflict-d208a92310a1" \
  "$(jq -r '.fields[0].item' <<<"$last")"

# --- A payload that is not JSON at all ----------------------------------------
IFS=$'\t' read -r rc n last <<<"$(run_log_event cycle "warning" 'not json at all')"
assert_eq "non-JSON payload: log_event returns 0" "0" "$rc"
assert_eq "non-JSON payload: recorded as a string under .fields" "not json at all" \
  "$(jq -r '.fields' <<<"$last")"

# --- No payload at all: the bare envelope --------------------------------------
IFS=$'\t' read -r rc n last <<<"$(run_log_event cycle "cycle-end")"
assert_eq "no payload: log_event returns 0" "0" "$rc"
assert_eq "no payload: the bare envelope is the event" "cycle-end" \
  "$(jq -r '.event' <<<"$last")"

# --- Issue #458: a payload that reduces to empty under jq's identity filter ----
# `${2:-{\}}` only rescues a shell-empty/unset $2 (the "no payload" case just
# above), never a non-empty string jq's identity filter reduces to nothing on
# — a single space is the simplest such string, and it is what the repro used.
IFS=$'\t' read -r rc n last <<<"$(run_log_event cycle "warning" ' ')"
assert_eq "whitespace-only payload: log_event returns 0 under set -e (issue #458)" "0" "$rc"
assert_eq "whitespace-only payload: the event still lands" "1" "$n"
assert_eq "whitespace-only payload: recorded wrapped under .fields" " " \
  "$(jq -r '.fields' <<<"$last")"

# --- A JSON null payload: not the empty-output failure mode, so already correct --
IFS=$'\t' read -r rc n last <<<"$(run_log_event cycle "warning" 'null')"
assert_eq "null payload: log_event returns 0" "0" "$rc"
assert_eq "null payload: the event still lands" "1" "$n"
assert_eq "null payload: recorded wrapped under .fields" "null" \
  "$(jq -c '.fields' <<<"$last")"

# --- review-cycle.sh's copy holds the same contract ----------------------------
IFS=$'\t' read -r rc n last <<<"$(run_log_event review "review-end" "$stale")"
assert_eq "review copy, array payload: returns 0 under set -e" "0" "$rc"
assert_eq "review copy, array payload: recorded wrapped under .fields" "1" \
  "$(jq -r '.fields | length' <<<"$last")"
assert_eq "review copy: the envelope is the review one" "test-review" \
  "$(jq -r '.review' <<<"$last")"

IFS=$'\t' read -r rc n last <<<"$(run_log_event review "warning" ' ')"
assert_eq "review copy, whitespace-only payload: returns 0 (issue #458)" "0" "$rc"
assert_eq "review copy, whitespace-only payload: the event still lands" "1" "$n"
assert_eq "review copy, whitespace-only payload: recorded wrapped under .fields" " " \
  "$(jq -r '.fields' <<<"$last")"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
