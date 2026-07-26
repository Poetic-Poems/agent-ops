#!/usr/bin/env bash
#
# test/unvoid-label.test.sh — regression test for lib/unvoid-label.sh
# (requirement 34f).
#
# The defect this closes had no code in it at all. Requirement 34c reserves
# clearing a void to a human and gives them one interface: a line appended by
# hand to `state_dir/log.jsonl`. The human is not there — `state_dir` is a
# Docker volume inside a scheduler container, and the maintainer is in a browser
# looking at the pull request. So faced with a void on `TD26072114` they applied
# a label called `unvoided` to PR #92, which was the obvious thing to do
# (labelling a PR `autonomous-agent` already hands it to this pipeline) and
# which nothing read. The item stayed void, the fleet went on standing down
# hourly, and the label sat there looking like the action had been taken. An
# escape hatch nobody can reach is not an escape hatch.
#
# Making the label work is easy. Making it *stop* working is the part this file
# is mostly about, and it is the part a second implementation would get wrong:
# a label is durable and a void is not a single event but a state that can be
# re-entered. Clear on the label alone and the label becomes a standing
# exemption — every future void on that item auto-cleared the cycle it is
# recorded, by an instruction given months earlier about a different verdict,
# with no symptom beyond an item that mysteriously never stays void. So the rule
# is narrow: the item must be void *now*, and the void must predate the label.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/unvoid-label.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/unvoid-label.sh
. "$SCRIPT_DIR/lib/unvoid-label.sh"

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

cleared() { unvoid_clearances "$1" "$2" | jq -r '[.[] | .repo + "|" + .item] | join(",")'; }

# The live state that produced this requirement, to the timestamp: the void on
# TD26072114 recorded by a Co-Ordinator at 16:57Z, and the label the maintainer
# put on PR #92 at 21:40Z.
VOIDS='[
  {"repo": "Poetic-Poems/poetic", "item": "TD26072114", "ts": "2026-07-25T16:57:22Z",
   "detail": "PR #92 work is finished: all merged", "event": "item-void"},
  {"repo": "Poetic-Poems/poetic", "item": "TD26072104", "ts": "2026-07-25T00:59:57Z",
   "detail": "already merged under PR #80", "event": "item-void"},
  {"repo": "Poetic-Poems/poetic-fiddle", "item": "52", "ts": "2026-07-25T08:32:07Z",
   "detail": "superseded", "event": "item-void"}
]'
REQ_92='[{"repo": "Poetic-Poems/poetic", "number": 92,
  "url": "https://github.com/Poetic-Poems/poetic/pull/92", "kind": "pr",
  "labelled_at": "2026-07-25T21:40:28Z", "items": ["TD26072114"]}]'

# --- The case that prompted this ---
assert_eq "the labelled PR's item is cleared" \
  "Poetic-Poems/poetic|TD26072114" "$(cleared "$REQ_92" "$VOIDS")"
assert_eq "  ... carrying the request that authorised it" \
  "https://github.com/Poetic-Poems/poetic/pull/92|2026-07-25T21:40:28Z|2026-07-25T16:57:22Z" \
  "$(unvoid_clearances "$REQ_92" "$VOIDS" | jq -r '.[0] | [.url, .labelled_at, .void_ts] | join("|")')"
assert_eq "  ... and nothing else in the repo" "1" \
  "$(unvoid_clearances "$REQ_92" "$VOIDS" | jq 'length')"

# --- Idempotence, which is what lets the label stay where the human put it ---
# Removing the label would move the PR's `updatedAt`, and for a draft PR that is
# the clock abandoned-drafts measures staleness by — so tidying up after the
# human would delay the very PR they are unsticking. The rule has to be
# self-limiting instead.
assert_eq "a second cycle clears nothing, the void already being gone" \
  "" "$(cleared "$REQ_92" '[]')"

# --- The standing-exemption failure, which is the reason for the ts test ---
LATER_VOID='[{"repo": "Poetic-Poems/poetic", "item": "TD26072114",
  "ts": "2026-07-26T09:00:00Z", "detail": "genuinely done now", "event": "item-void"}]'
assert_eq "a void recorded after the label stands" "" "$(cleared "$REQ_92" "$LATER_VOID")"
assert_eq "a void recorded at the same instant as the label stands" "" \
  "$(cleared "$REQ_92" '[{"repo": "Poetic-Poems/poetic", "item": "TD26072114",
     "ts": "2026-07-25T21:40:28Z", "detail": "x", "event": "item-void"}]')"

# --- Scope ---
assert_eq "a label naming an item that was never void clears nothing" "" \
  "$(cleared '[{"repo": "Poetic-Poems/poetic", "number": 7, "url": "u", "kind": "pr",
     "labelled_at": "2026-07-25T21:40:28Z", "items": ["TD99999999"]}]' "$VOIDS")"

# An item id is unique only within its repo, so a label in one repo must not
# reopen the other's identically-named item — the same keying requirement 34c
# imposes on the extract itself.
assert_eq "a request cannot clear another repo's identically-named item" "" \
  "$(cleared '[{"repo": "Poetic-Poems/poetic-fiddle", "number": 9, "url": "u", "kind": "pr",
     "labelled_at": "2026-07-25T21:40:28Z", "items": ["TD26072114"]}]' "$VOIDS")"

# A void carrying no repo is void everywhere (requirement 34c), so a request
# from any repo may clear it — the mirror of the clearing rule, not an exception
# to it.
assert_eq "a repo-less void is clearable from any repo" \
  "Poetic-Poems/poetic-fiddle|TDX" \
  "$(cleared '[{"repo": "Poetic-Poems/poetic-fiddle", "number": 9, "url": "u", "kind": "pr",
     "labelled_at": "2026-07-25T21:40:28Z", "items": ["TDX"]}]' \
    '[{"item": "TDX", "ts": "2026-07-01T00:00:00Z", "detail": "x", "event": "item-void"}]')"

# --- Several items, several requests ---
# A PR may legitimately name two items, and the gatherer reports all of them
# rather than picking one; the ones that are void get cleared and the rest are
# silently nothing.
assert_eq "a request naming several items clears the void ones only" \
  "Poetic-Poems/poetic|TD26072104,Poetic-Poems/poetic|TD26072114" \
  "$(cleared '[{"repo": "Poetic-Poems/poetic", "number": 92, "url": "u", "kind": "pr",
     "labelled_at": "2026-07-25T21:40:28Z",
     "items": ["TD26072114", "TD26072104", "TD00000000"]}]' "$VOIDS" \
   | tr ',' '\n' | sort | paste -sd, -)"

assert_eq "two requests naming the same item yield one clearance" "1" \
  "$(unvoid_clearances '[{"repo": "Poetic-Poems/poetic", "number": 92, "url": "a", "kind": "pr",
     "labelled_at": "2026-07-25T21:40:28Z", "items": ["TD26072114"]},
     {"repo": "Poetic-Poems/poetic", "number": 93, "url": "b", "kind": "issue",
     "labelled_at": "2026-07-25T22:00:00Z", "items": ["TD26072114"]}]' "$VOIDS" | jq 'length')"

# --- Nothing, and nonsense ---
assert_eq "no requests, no clearances" "[]" "$(unvoid_clearances '[]' "$VOIDS")"
assert_eq "no voids, no clearances" "[]" "$(unvoid_clearances "$REQ_92" '[]')"
assert_eq "a request with no items clears nothing" "[]" \
  "$(unvoid_clearances '[{"repo": "r", "labelled_at": "2026-07-25T21:40:28Z"}]' "$VOIDS")"

# The caller is a cycle under `set -euo pipefail`, at the point it is about to
# record state. Malformed input must yield an empty array, not a dead cycle.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/unvoid-label.sh"
  [[ "$(unvoid_clearances 'not json' 'also not json')" == "[]" ]] || exit 9
  [[ "$(unvoid_clearances)" == "[]" ]] || exit 8
  exit 0
) >/dev/null 2>&1
assert_eq "the real call-site shape survives set -e and bad input" "0" "$?"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
