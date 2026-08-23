#!/usr/bin/env bash
#
# test/review-repo-labels-wiring.test.sh — regression test for the
# per-repository label ensure review-cycle.sh's review_one function runs
# (requirement R5.0b, agent-ops#685): not whether labels_ensure_role itself is
# correct (test/labels.test.sh covers that) but whether review_one calls it
# with the right arguments and logs `labels-ensured` only when there is
# something to report. Also verifies that it calls the plain, unstamped
# `labels_ensure_role` and not `labels_ensure_stamped` — a one-line distinction
# that matters but is otherwise guarded only by a comment.
#
# The block is lifted verbatim out of review-cycle.sh, the way
# test/gathered-repo-labels-wiring.test.sh and test/backpressure-wiring.test.sh
# lift their own, so the assertions are about the shipped code rather than a
# copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/review-repo-labels-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW_CYCLE="$SCRIPT_DIR/review-cycle.sh"

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

# --- Lift the labels block whole out of review_one in review-cycle.sh -------
labels_block="$(awk '
  /^  local labels_report$/ { on = 1 }
  on                        { print }
  on && /^  fi$/            { exit }
' "$REVIEW_CYCLE")"
if [[ "$labels_block" != *'labels_ensure_role'* || "$labels_block" != *'labels-ensured'* ]]; then
  echo "FAIL - could not extract the review-one label ensure from review-cycle.sh (moved or reworded?)" >&2
  exit 1
fi

# --- Stub: labels_ensure_role and labels_ensure_stamped, fail if wrong one called ---
call_log="$(mktemp)"
trap 'rm -f "$call_log"' EXIT
# shellcheck disable=SC2317  # invoked only by the eval'd labels_block
labels_ensure_role() { printf '%s\n' "$*" >> "$call_log"; printf '%s' "$stub_report"; }
# shellcheck disable=SC2317  # invoked only by the eval'd labels_block
labels_ensure_stamped() { echo "FAIL: labels_ensure_stamped was called; review_one must call labels_ensure_role instead" >> "$call_log"; return 1; }
# shellcheck disable=SC2317  # invoked only by the eval'd labels_block
log_event() { printf 'EVENT %s %s\n' "$1" "$2" >> "$call_log"; }

run_block() {  # <slug> <pr_label> <stub_report>
  (
    # Every one of these is consumed only by the eval'd labels_block,
    # invisible to shellcheck.
    # shellcheck disable=SC2034
    CONFIG_FILE="/cfg.json" SCHEMA_FILE="/schema.json" \
      slug="$1" pr_label="$2" stub_report="$3"
    eval "$labels_block"
  )
}

: > "$call_log"
run_block "o/r" "autonomous-agent" "created	autonomous-agent"
assert_eq "labels_ensure_role is called with config, schema, the repo, review role, and pr_label" \
  "/cfg.json /schema.json o/r review autonomous-agent" \
  "$(grep '^/cfg.json ' "$call_log")"
assert_eq "a non-empty report logs labels-ensured" "1" \
  "$(grep -c '^EVENT labels-ensured' "$call_log")"
assert_eq "  ... naming the repo and review role" "1" \
  "$(grep '^EVENT labels-ensured' "$call_log" | grep -c '"repo":"o/r".*"role":"review"\|"role":"review".*"repo":"o/r"')"
assert_eq "  ... with the created label named" "1" \
  "$(grep '^EVENT labels-ensured' "$call_log" | grep -c 'autonomous-agent')"

: > "$call_log"
run_block "o/other" "autonomous-agent" ""
assert_eq "a rate-limited (empty) report is called for exactly as any other repository" \
  "/cfg.json /schema.json o/other review autonomous-agent" \
  "$(grep '^/cfg.json ' "$call_log")"
assert_eq "  ... but logs nothing at all — the steady state is silent" "0" \
  "$(grep -c '^EVENT' "$call_log")"

: > "$call_log"
run_block "o/second-repo" "autonomous-agent" "failed	autonomous-agent"
assert_eq "every repository gets its own call — a second, different slug" \
  "/cfg.json /schema.json o/second-repo review autonomous-agent" \
  "$(grep '^/cfg.json ' "$call_log")"
assert_eq "  ... and a failed create is logged too, not only created" "1" \
  "$(grep '^EVENT labels-ensured' "$call_log" | grep -c 'autonomous-agent')"

echo
if (( failures == 0 )); then
  echo "All review-repo-labels-wiring assertions passed."
  exit 0
else
  echo "$failures review-repo-labels-wiring assertion(s) FAILED."
  exit 1
fi
