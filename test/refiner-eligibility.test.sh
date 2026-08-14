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
   ],
   "project_review": [
     {"source": "project-review", "ref": "review-2026-08-10-R-01", "title": "opted in"}
   ],
   "implementation_plan": [
     {"source": "implementation-plan", "ref": "W10-breach-handling", "title": "opted in"}
   ]}
]'
policy='{"issues": "preferred", "register-hygiene": "required", "tech-debt": "required",
         "project-review": "required", "implementation-plan": "required"}'
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
assert_eq "a project-review item, opted into required, is a candidate" "yes" \
  "$(jq -r 'any(.[]; .source == "project-review") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "an implementation-plan item, opted into required, is a candidate" "yes" \
  "$(jq -r 'any(.[]; .source == "implementation-plan") | if . then "yes" else "no" end' <<<"$candidates")"
assert_eq "exactly five candidates survive" "5" "$(jq 'length' <<<"$candidates")"
assert_eq "the candidate carries the gatherer's own entry verbatim" "unrefined issue" \
  "$(jq -r '.[] | select(.item == "5") | .entry.title' <<<"$candidates")"

assert_eq "an empty repos array yields no candidates" "[]" \
  "$(refiner_candidate_items '[]' "$policy" "$refinements" "$blocked" "$void" "$claimed")"
assert_eq "unreadable inputs yield an empty array rather than failing" "[]" \
  "$(refiner_candidate_items 'garbage' 'garbage' 'garbage' 'garbage' 'garbage' 'garbage')"

# --- The argv cap (requirement 4g, TD-PPagop-26081406) ---
#
# $refinements, $blocked, $void and $claimed are four of the five aggregates
# requirement 4g names by name as growing with the fleet's whole history;
# $repos already arrived on stdin (TD-PPagop-26081301). Delivered via
# --argjson, any one of them past MAX_ARG_STRLEN (131072 bytes) made this
# call fail into its own `|| printf '[]'`, and the Refiner silently found no
# candidates at all — the whole point of the function defeated exactly when
# the fleet's history is largest. Requirement 4g moves all five onto stdin
# together; this pins it with a $void extract past the cap, the same
# aggregate that actually crossed it on 2026-08-12
# (test/verdict-corroboration.test.sh's own BIG_VOID).
big_void="$(jq -nc --argjson keep "$void" \
  '[range(1300) | {repo: "o/r", item: ("TD-fill-" + (. | tostring)),
                   ts: "2026-07-01T00:00:00Z", detail: ("pad " + ("x" * 100)),
                   event: "item-void"}] + $keep')"
assert_eq "the oversized void fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_void" | wc -c) > 131072 ))"

candidates_big_void="$(refiner_candidate_items "$repos" "$policy" "$refinements" "$blocked" "$big_void" "$claimed")"
assert_eq "a void extract past the argv cap still excludes the voided item" "no" \
  "$(jq -r 'any(.[]; .item == "8") | if . then "yes" else "no" end' <<<"$candidates_big_void")"
assert_eq "  ... while every other candidate still comes through unaffected" "5" \
  "$(jq 'length' <<<"$candidates_big_void")"

# project-review and implementation-plan are only reachable when the
# Refiner-only repos array agent-cycle.sh builds actually carries them — a
# repo with neither array present (the ordinary shape of the Co-Ordinator's
# own `ordered_repos_json`) still finds nothing to gather, whatever the
# policy says.
repos_with_pr='[{"slug": "o/r", "issues": []}]'
policy_pr='{"project-review": "required", "implementation-plan": "required"}'
assert_eq "a project-review/implementation-plan policy finds nothing without the arrays present" "[]" \
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
