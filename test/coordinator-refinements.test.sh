#!/usr/bin/env bash
#
# test/coordinator-refinements.test.sh — regression test for requirement 4j's
# `coordinator_refinements_view` (agent-ops#643).
#
# `refinements` is a ledger that is never retired. Most of its entries are a
# line — `ts`, `cycle`, a `comment_url` — but an entry for an item type with no
# thread to hold it carries the whole specification in markdown, and by
# 2026-08-21 those had grown to 219175 bytes of a 237339-byte band. That band
# sits in the *unsheddable* half of the Co-Ordinator's input: requirement 4i's
# ladder trims `issues` and `tech_debt` and cannot touch it. The allowance came
# out negative, the ladder was never walked, and the API refused the stage on
# every node of the fleet for eleven consecutive cycles.
#
# The view's rule is candidacy, and it comes from `prompts/coordinator.md`
# rather than from a byte count: a spec has exactly one use there — pasted
# verbatim into the work order of an item being selected — so a spec for an
# item no band offers is prose the model pays to read and can never act on.
# What is asserted here is that the rule is applied to *specs* and to nothing
# else: an entry's presence is what the under-specification check and the
# `refinement_policy` gate read, and losing an entry would change selection.
#
# The function is lifted verbatim out of agent-cycle.sh, the way
# test/coordinator-input-wiring.test.sh lifts its own, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
# ./test/coordinator-refinements.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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
assert_true() { assert_eq "$1" "true" "$2"; }
assert_ok() { assert_eq "$1" "1" "$2"; }

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

view_block="$(extract_block '^coordinator_refinements_view\(\) \{' '^\}$' "$AGENT_CYCLE")"
if [[ -z "$view_block" || "$view_block" != *'jq'* ]]; then
  echo "FAIL - could not extract coordinator_refinements_view from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
eval "$view_block"

# --- Fixtures -----------------------------------------------------------------

# One repo offering three candidates across three bands, and a ledger holding
# six entries for it: two specs for items it offers, two specs for items it
# does not, and two `comment_url` entries.
repos='[
  {"slug": "o/r",
   "issues":     [{"source": "issues",     "ref": "52", "number": 52}],
   "tech_debt":  [{"source": "tech-debt",  "ref": "TD-live", "id": "TD-live"}],
   "review_feedback": [{"source": "review-feedback", "ref": "pr-9-review-1"}]},
  {"slug": "o/other", "tech_debt": [{"source": "tech-debt", "ref": "TD-elsewhere"}]}
]'
refinements='{
  "o/r": {
    "TD-live":      {"ts": "t", "cycle": "c", "spec": "SPEC-KEPT-live"},
    "pr-9-review-1":{"ts": "t", "cycle": "c", "spec": "SPEC-KEPT-review"},
    "TD-gone":      {"ts": "t", "cycle": "c", "spec": "SPEC-DROPPED-gone"},
    "TD-alsogone":  {"ts": "t", "cycle": "c", "spec": "SPEC-DROPPED-alsogone"},
    "52":           {"ts": "t", "cycle": "c", "comment_url": "https://example/52"},
    "61":           {"ts": "t", "cycle": "c", "comment_url": "https://example/61"}
  },
  "o/other": {
    "TD-elsewhere": {"ts": "t", "cycle": "c", "spec": "SPEC-KEPT-otherrepo"}
  }
}'

out="$(coordinator_refinements_view "$refinements" "$repos")"

# --- Specs are kept for candidates and dropped for everything else ------------

assert_true "a spec is kept for an item the tech_debt band offers" \
  "$(jq -e '."o/r"."TD-live".spec == "SPEC-KEPT-live"' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "a spec is kept for an item the review_feedback band offers" \
  "$(jq -e '."o/r"."pr-9-review-1".spec == "SPEC-KEPT-review"' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "a spec is dropped for an item no band offers" \
  "$(jq -e '."o/r"."TD-gone" | has("spec") | not' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "…and for the second such item too, not just the first" \
  "$(jq -e '."o/r"."TD-alsogone" | has("spec") | not' <<<"$out" >/dev/null && echo true || echo false)"

# Candidacy is per repo, not fleet-wide: an id offered by one repo must not
# rescue the same id in another, and a repo's own candidates must be found.
assert_true "candidacy is scoped per repo, and the other repo's own spec is kept" \
  "$(jq -e '."o/other"."TD-elsewhere".spec == "SPEC-KEPT-otherrepo"' <<<"$out" >/dev/null && echo true || echo false)"
cross="$(coordinator_refinements_view "$refinements" '[{"slug": "o/other", "tech_debt": [{"ref": "TD-gone"}]}]')"
assert_true "an id offered only by another repo does not keep this repo's spec" \
  "$(jq -e '."o/r"."TD-gone" | has("spec") | not' <<<"$cross" >/dev/null && echo true || echo false)"

# --- Nothing but the spec is ever removed ------------------------------------

assert_eq "every entry survives, candidate or not" \
  "$(jq '[to_entries[] | (.value | to_entries[])] | length' <<<"$refinements")" \
  "$(jq '[to_entries[] | (.value | to_entries[])] | length' <<<"$out")"
assert_eq "every repo key survives" \
  "$(jq -S 'keys' <<<"$refinements")" "$(jq -S 'keys' <<<"$out")"
assert_true "ts and cycle survive on an entry whose spec was dropped" \
  "$(jq -e '."o/r"."TD-gone" | .ts == "t" and .cycle == "c"' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "a comment_url entry is untouched — it is a pointer, not a payload" \
  "$(jq -e '."o/r"."52".comment_url == "https://example/52"' <<<"$out" >/dev/null && echo true || echo false)"
assert_true "…including one for an item no band offers" \
  "$(jq -e '."o/r"."61".comment_url == "https://example/61"' <<<"$out" >/dev/null && echo true || echo false)"

# --- It is worth having: the band actually shrinks ---------------------------

assert_ok "the view is smaller than the ledger it trims" \
  "$(( $(printf '%s' "$out" | wc -c) < $(printf '%s' "$refinements" | wc -c) ))"
assert_true "no dropped spec's text survives anywhere in the output" \
  "$(grep -qF 'SPEC-DROPPED' <<<"$out" && echo false || echo true)"

# --- Degradation is toward the untrimmed ledger, never toward an empty one ----
# The same fail-open direction as `coordinator_blocked_view` and requirement
# 4i's own guards: a view that emptied this band on malformed input would
# silently un-refine every item in the fleet, which is worse than the overflow
# it exists to prevent.

assert_eq "a malformed repos document leaves the ledger untouched" \
  "$(jq -S . <<<"$refinements")" "$(jq -S . <<<"$(coordinator_refinements_view "$refinements" 'not json')")"
assert_eq "a repos document of the wrong type leaves the ledger untouched" \
  "$(jq -S . <<<"$refinements")" "$(jq -S . <<<"$(coordinator_refinements_view "$refinements" '{"slug": "o/r"}')")"
assert_eq "a malformed ledger is handed back as it arrived" \
  "not json" "$(coordinator_refinements_view 'not json' "$repos")"
assert_eq "an empty ledger stays empty rather than becoming an error" \
  "{}" "$(coordinator_refinements_view '{}' "$repos")"
assert_eq "an absent repos document drops every spec rather than crashing" \
  "0" "$(coordinator_refinements_view "$refinements" '[]' | jq '[to_entries[] | (.value | to_entries[]) | select(.value | has("spec"))] | length')"

# --- Requirement 4g: neither document may reach jq in argv --------------------
# Both are unbounded fleet-state aggregates, and this map is the one that
# actually crossed MAX_ARG_STRLEN on the outage. An `--argjson` here would
# trade the API refusal this function exists to prevent for the execve death
# requirement 4g exists to prevent.

assert_true "the view binds neither document with --argjson" \
  "$(grep -qE 'argjson' <<<"$view_block" && echo false || echo true)"

big="$( { printf '{"o/r": {"TD-gone": {"ts": "t", "cycle": "c", "spec": "'
          head -c 200000 /dev/zero | tr '\0' 'S'
          printf '"}}}'; } )"
assert_ok "the oversized fixture really is past MAX_ARG_STRLEN" \
  "$(( $(printf '%s' "$big" | wc -c) > 131072 ))"
assert_eq "a ledger past MAX_ARG_STRLEN is trimmed rather than dying at execve" \
  "0" "$(coordinator_refinements_view "$big" "$repos" | jq '[to_entries[] | (.value | to_entries[]) | select(.value | has("spec"))] | length')"

printf '\n%s\n' "$( (( failures == 0 )) && echo "All assertions passed." || echo "$failures assertion(s) failed." )"
exit $(( failures > 0 ))
