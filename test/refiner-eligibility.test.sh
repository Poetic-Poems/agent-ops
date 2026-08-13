#!/usr/bin/env bash
#
# test/refiner-eligibility.test.sh — regression test for the Refiner's
# candidate set and engagement cap (`refiner_candidate_items`,
# `refiner_policy_value` and `refiner_engagement_set` in lib/refinement.sh,
# requirements 39a and 39b).
#
# The candidate rule decides which pre-fetched items the Refiner spends a
# cheap-model pass on, and getting it wrong in either direction has a real
# cost: too permissive and the Refiner re-writes a specification an Enabler or
# a human already settled, wasting the engagement and risking the thrash the
# design note in lib/refinement.sh explicitly declines to invite; too strict
# and an item that genuinely needs a specification never gets one, silently.
# Every exclusion below is asserted on both sides of itself.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/refiner-eligibility.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"

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

# --- refiner_policy_value ---------------------------------------------------

assert_eq "a named source reads its configured policy" "required" \
  "$(refiner_policy_value issues '{"issues": "required"}')"
assert_eq "an unnamed source defaults to exempt" "exempt" \
  "$(refiner_policy_value tech-debt '{"issues": "required"}')"
assert_eq "an empty policy object defaults everything to exempt" "exempt" \
  "$(refiner_policy_value issues '{}')"
assert_eq "an unreadable policy object defaults to exempt" "exempt" \
  "$(refiner_policy_value issues 'not json')"

# --- refiner_candidate_items -------------------------------------------------

repos='[
  {"slug": "o/r",
   "issues": [
     {"source": "issues", "ref": "5", "title": "unrefined issue"},
     {"source": "issues", "ref": "6", "title": "already refined"},
     {"source": "issues", "ref": "7", "title": "already blocked"},
     {"source": "issues", "ref": "8", "title": "voided"},
     {"source": "issues", "ref": "9", "title": "claimed by an Implementor"}
   ],
   "merge_conflicts": [
     {"source": "merge-conflicts", "ref": "pr-1-conflict-abc", "title": "exempt by default"}
   ],
   "register_hygiene": [
     {"source": "register-hygiene", "ref": "register-hygiene-abc", "title": "opted in"}
   ],
   "tech_debt": [
     {"source": "tech-debt", "ref": "TD-PPagop-1", "title": "opted in"}
   ]}
]'
policy='{"issues": "preferred", "register-hygiene": "required", "tech-debt": "required"}'
refinements='{"o/r": {"6": {"ts": "2026-08-01T00:00:00Z", "comment_url": "https://x/6"}}}'
blocked='[{"repo": "o/r", "item": "7"}]'
void='[{"repo": "o/r", "item": "8"}]'
claimed='[{"repo": "o/r", "item": "9"}]'

candidates="$(refiner_candidate_items "$repos" "$policy" "$refinements" "$blocked" "$void" "$claimed")"

assert_eq "an unrefined, unblocked, unclaimed issue is a candidate" "yes" \
  "$(jq -r 'any(.[]; .repo == "o/r" and .item == "5") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "an already-refined issue is not a candidate" "no" \
  "$(jq -r 'any(.[]; .item == "6") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "an already-blocked issue is not a candidate" "no" \
  "$(jq -r 'any(.[]; .item == "7") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "a void issue is not a candidate" "no" \
  "$(jq -r 'any(.[]; .item == "8") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "a claimed issue is not a candidate" "no" \
  "$(jq -r 'any(.[]; .item == "9") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "a merge conflict, exempt by default, is not a candidate" "no" \
  "$(jq -r 'any(.[]; .source == "merge-conflicts") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "a register-hygiene item, opted into required, is a candidate" "yes" \
  "$(jq -r 'any(.[]; .source == "register-hygiene") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "a tech-debt item, opted into required, is a candidate" "yes" \
  "$(jq -r 'any(.[]; .source == "tech-debt") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "exactly three candidates survive" "3" "$(jq 'length' <<<"$candidates")"
assert_eq "the candidate carries the gatherer's own entry verbatim" "unrefined issue" \
  "$(jq -r '.[] | select(.item == "5") | .entry.title' <<<"$candidates")"

assert_eq "an empty repos array yields no candidates" "[]" \
  "$(refiner_candidate_items '[]' "$policy" "$refinements" "$blocked" "$void" "$claimed")"
assert_eq "unreadable inputs yield an empty array rather than failing" "[]" \
  "$(refiner_candidate_items 'garbage' 'garbage' 'garbage' 'garbage' 'garbage' 'garbage')"

# project-review and implementation-plan are never reachable here, whatever
# their policy says — the Script does not pre-fetch either as an array.
repos_with_pr='[{"slug": "o/r", "issues": []}]'
policy_pr='{"project-review": "required", "implementation-plan": "required"}'
assert_eq "a project-review/implementation-plan policy finds nothing to gather — there is no array for either" "[]" \
  "$(refiner_candidate_items "$repos_with_pr" "$policy_pr" '{}' '[]' '[]' '[]')"

# --- refiner_engagement_set ---------------------------------------------------

three='[{"repo": "o/r", "source": "issues", "item": "9"},
        {"repo": "o/r", "source": "issues", "item": "5"},
        {"repo": "o/other", "source": "issues", "item": "1"}]'
assert_eq "a cap above the count keeps everything, sorted deterministically" \
  '["o/other 1","o/r 5","o/r 9"]' \
  "$(refiner_engagement_set "$three" 10 | jq -c '[.[] | "\(.repo) \(.item)"]')"
assert_eq "a cap of one keeps only the first in sorted order" '["o/other 1"]' \
  "$(refiner_engagement_set "$three" 1 | jq -c '[.[] | "\(.repo) \(.item)"]')"
assert_eq "a cap of zero removes the class entirely" "[]" "$(refiner_engagement_set "$three" 0)"
assert_eq "an unreadable cap spends nothing" "[]" "$(refiner_engagement_set "$three" "not-a-number")"
assert_eq "the same input, capped twice, is deterministic" \
  "$(refiner_engagement_set "$three" 2)" "$(refiner_engagement_set "$three" 2)"

# The call-site shape under `set -e`: computed inside a cycle that must
# survive whatever this cycle's gathered sources contain.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/void-guard.sh"
  . "$SCRIPT_DIR/lib/refinement.sh"
  a="$(refiner_candidate_items '[' '{' '{' '[' '[' '[')"
  b="$(refiner_engagement_set 'not an array' 'nope')"
  c="$(refiner_policy_value '' '')"
  printf '%s%s%s' "$a" "$b" "$c" >/dev/null
  exit 0
) >/dev/null 2>&1
assert_eq "malformed input never aborts the caller under set -e" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
