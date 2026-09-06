#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# SC2016: the fixed-string boundaries `extract` matches against are jq/bash
# source text, deliberately single-quoted so nothing in them expands here.
# SC2034: every variable set before `eval "$reviewer_block"`/`"$enabler_block"`
# is read only by that eval'd body, not visible to shellcheck the way
# lib/merge-observed.sh's own header already explains for the same shape.
#
# test/checks-green-join-key.test.sh — regression test for the item-lifecycle
# record's own "checks green" instant (requirement 49, issue #595) and the
# join key added alongside it to `review-gate-checks-read`, at both of the
# two call sites that share `handoff_complete_review`'s gate: the Reviewer's
# own handoff (agent-cycle.sh) and the Enabler's `complete_handoff` recovery
# path (lib/enabler.sh).
#
# Both snippets are lifted verbatim, the same technique
# test/landing-wiring.test.sh and its siblings use, so the assertions are
# about the shipped code rather than a copy of its logic. Each is a compact,
# self-contained pair of statements needing nothing beyond
# `$gate_word`/`$gate_checks_unreadable` (or their `e_` equivalents),
# `$selected_repo`/`$selected_item` (or `$e_repo`/`$e_item`), and `log_event`.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/checks-green-join-key.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# extract START_SUBSTRING END_SUBSTRING FILE
# Fixed-string (not regex) line-range extraction — simpler and less brittle
# than escaping jq's own punctuation for awk's regex engine, which is all
# either boundary line here is made of.
extract() {
  awk -v start="$1" -v end="$2" '
    index($0, start) { on = 1 }
    on { print }
    on && index($0, end) { exit }
  ' "$3"
}

events_file="$(mktemp)"
trap 'rm -f "$events_file"' EXIT
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$events_file"; }
event_of() { grep -m1 "^$1"$'\t' "$events_file" | cut -f2- || true; }

# --- The Reviewer's own handoff (agent-cycle.sh) -------------------------------

reviewer_block="$(extract 'gate_word="$(jq -r' \
  '{ok: $ok} + (if $r == ""' "$SCRIPT_DIR/agent-cycle.sh")"
if [[ -z "$reviewer_block" || "$reviewer_block" != *"checks-green"* ]]; then
  echo "FAIL - could not extract the Reviewer's checks-green/review-gate-checks-read snippet — has it moved?" >&2
  exit 1
fi

run_reviewer() {  # <gate_word> <gate_checks_unreadable>
  : > "$events_file"
  ( impl_pr_url="https://github.com/acme/widgets/pull/1"
    selected_repo="acme/widgets"
    selected_item="1"
    review_json="$(jq -nc --arg w "$1" --argjson cu "$2" '{gate: {word: $w, checks_unreadable: $cu}}')"
    eval "$reviewer_block" )
}

run_reviewer clean false
assert_eq "a clean gate word logs checks-green" \
  '{"pr_url":"https://github.com/acme/widgets/pull/1","repo":"acme/widgets","item":"1"}' \
  "$(event_of checks-green)"
assert_eq "  ... and review-gate-checks-read carries the same join key" \
  '{"ok":true,"repo":"acme/widgets","item":"1"}' "$(event_of review-gate-checks-read)"

run_reviewer dirty false
assert_eq "a dirty gate word logs no checks-green" "" "$(event_of checks-green)"
assert_eq "  ... but review-gate-checks-read still carries the join key" \
  '{"ok":true,"repo":"acme/widgets","item":"1"}' "$(event_of review-gate-checks-read)"

run_reviewer unknown true
assert_eq "an unreadable required-check list logs no checks-green" "" "$(event_of checks-green)"
assert_eq "  ... and review-gate-checks-read reads ok:false, still with the join key" \
  '{"ok":false,"repo":"acme/widgets","item":"1"}' "$(event_of review-gate-checks-read)"

# --- The Enabler's own complete_handoff recovery path (lib/enabler.sh) ---------

enabler_block="$(extract 'e_gate_word="$(jq -r' \
  '{ok: $ok} + (if $r == ""' "$SCRIPT_DIR/lib/enabler.sh")"
if [[ -z "$enabler_block" || "$enabler_block" != *"checks-green"* ]]; then
  echo "FAIL - could not extract the Enabler's checks-green/review-gate-checks-read snippet — has it moved?" >&2
  exit 1
fi

run_enabler() {  # <gate_word> <gate_checks_unreadable>
  : > "$events_file"
  ( e_pr_url="https://github.com/acme/widgets/pull/2"
    e_repo="acme/widgets"
    e_item="2"
    e_review_json="$(jq -nc --arg w "$1" --argjson cu "$2" '{gate: {word: $w, checks_unreadable: $cu}}')"
    eval "$enabler_block" )
}

run_enabler clean false
assert_eq "enabler recovery: a clean gate word logs checks-green" \
  '{"pr_url":"https://github.com/acme/widgets/pull/2","repo":"acme/widgets","item":"2"}' \
  "$(event_of checks-green)"
assert_eq "  ... and review-gate-checks-read carries the same join key" \
  '{"ok":true,"repo":"acme/widgets","item":"2"}' "$(event_of review-gate-checks-read)"

run_enabler dirty false
assert_eq "enabler recovery: a dirty gate word logs no checks-green" "" "$(event_of checks-green)"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
