#!/usr/bin/env bash
#
# test/repo-entry-build.test.sh — regression test for agent-cycle.sh's
# per-repo entry build (requirement 4g, TD-PPagop-26081406): the inline block
# in the main gather loop that assembles one repo's whole
# findings/review_feedback/abandoned_drafts/merge_conflicts/dequeued/
# register_hygiene/issues/tech_debt bands, plus its slug/default_branch/sources/
# implementation_plan_path, into the single `entry` object folded into
# `ordered_repos_json` — the Co-Ordinator's whole per-repo runtime input.
#
# Each of the eight bands is unbounded past this call — issue threads
# (requirement 3d/#118) and the open tech-debt register (requirement 3t/#310)
# included — and used to ride into jq as eight separate --argjson flags. Past
# MAX_ARG_STRLEN (131072 bytes) the build died at execve, silently dropping
# the repo's whole entry from the Co-Ordinator's input for the cycle.
# Requirement 4g moves all eight onto stdin, one document per line, bound
# positionally with `input as $name` in the order printed — `$sources` alone
# stays in argv, bounded by configuration.
#
# The block is inline, not a function (it runs once per repo inside
# agent-cycle.sh's main gather loop), so it is lifted by its own literal
# start/end lines — the same technique test/pr-claim-exclusion.test.sh's
# `extract_claims_fold` uses for the identical shape one call downstream
# (the `ordered_repos_json` append this entry itself feeds).
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/repo-entry-build.test.sh
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

# --- Lift the block whole out of agent-cycle.sh, by its own literal lines --
entry_build_block="$(awk '
  index($0, "  entry_docs=\"$(printf") == 1 { on = 1 }
  on                                         { print }
  on && index($0, "<<<\"$entry_docs\")\"") > 0 { exit }
' "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ "$entry_build_block" != *'entry_docs'* || "$entry_build_block" != *'human_visibility: []'* ]]; then
  printf 'FAIL - could not extract the per-repo entry build from lib/candidate-gather.sh (moved or reworded?)\n'
  exit 1
fi

run_entry_build() {  # run_entry_build <slug> <default_branch> <sources-json> <ipp>
  #                     <findings> <review_feedback> <abandoned_drafts>
  #                     <merge_conflicts> <dequeued> <register_hygiene> <issues>
  #                     <tech_debt> [issues_excluded]
  # Every one of these is consumed only by the eval'd entry_build_block,
  # invisible to shellcheck, including the `entry` it assigns.
  # shellcheck disable=SC2034
  ( slug="$1" default_branch="$2" sources="$3" implementation_plan_path="$4" \
    findings="$5" review_feedback="$6" abandoned_drafts="$7" merge_conflicts="$8" \
    dequeued="$9" register_hygiene="${10}" issues="${11}" tech_debt="${12}" \
    issues_excluded="${13:-[]}"
    eval "$entry_build_block"
    # shellcheck disable=SC2154
    printf '%s' "$entry" )
}

# --- The ordinary case: every band present, one item apiece -----------------
out="$(run_entry_build "o/r" "main" '["tech-debt"]' "" \
  '[{"source":"security","ref":"dependabot-alert-1"}]' \
  '[{"source":"review-feedback","ref":"pr-1-review-1"}]' \
  '[{"source":"abandoned-drafts","ref":"pr-2-abandoned-aa"}]' \
  '[{"source":"merge-conflicts","ref":"pr-3-conflict-bb"}]' \
  '[{"source":"dequeued","ref":"pr-4-dequeued-dd"}]' \
  '[{"source":"register-hygiene","ref":"register-hygiene-cc"}]' \
  '[{"source":"issues","ref":"11"}]' \
  '[{"source":"tech-debt","ref":"TD1"}]' \
  '[{"number":12,"reason":"assigned"}]')"

assert_eq "slug and default_branch carry through" "o/r main" \
  "$(jq -r '"\(.slug) \(.default_branch)"' <<<"$out")"
assert_eq "sources carries through as configured" '["tech-debt"]' "$(jq -c '.sources' <<<"$out")"
assert_eq "findings carries through" "dependabot-alert-1" "$(jq -r '.findings[0].ref' <<<"$out")"
assert_eq "review_feedback carries through" "pr-1-review-1" "$(jq -r '.review_feedback[0].ref' <<<"$out")"
assert_eq "abandoned_drafts carries through" "pr-2-abandoned-aa" "$(jq -r '.abandoned_drafts[0].ref' <<<"$out")"
assert_eq "merge_conflicts carries through" "pr-3-conflict-bb" "$(jq -r '.merge_conflicts[0].ref' <<<"$out")"
assert_eq "dequeued carries through" "pr-4-dequeued-dd" "$(jq -r '.dequeued[0].ref' <<<"$out")"
assert_eq "register_hygiene carries through" "register-hygiene-cc" "$(jq -r '.register_hygiene[0].ref' <<<"$out")"
assert_eq "issues carries through" "11" "$(jq -r '.issues[0].ref' <<<"$out")"
assert_eq "issues_excluded carries through" '{"number":12,"reason":"assigned"}' \
  "$(jq -c '.issues_excluded[0]' <<<"$out")"
assert_eq "tech_debt carries through" "TD1" "$(jq -r '.tech_debt[0].ref' <<<"$out")"
assert_eq "human_visibility starts empty — always filled in later" "[]" "$(jq -c '.human_visibility' <<<"$out")"
assert_eq "no implementation_plan_path key when the source isn't configured" "false" \
  "$(jq 'has("implementation_plan_path")' <<<"$out")"

out_ipp="$(run_entry_build "o/r" "main" '["implementation-plan"]' "W10-breach-handling" \
  '[]' '[]' '[]' '[]' '[]' '[]' '[]' '[]')"
assert_eq "implementation_plan_path is added when the source is configured" "W10-breach-handling" \
  "$(jq -r '.implementation_plan_path' <<<"$out_ipp")"

# --- The argv cap (requirement 4g, TD-PPagop-26081406) ---------------------
# One band alone (issues, carrying a whole pre-fetched thread) pushed past
# the cap; the other seven stay small, proving the stdin delivery survives
# regardless of which band is the oversized one.
oversized_body="$(head -c 140000 < /dev/zero | tr '\0' 'x')"
big_issues="$(printf '[{"source": "issues", "ref": "99", "body": "%s"}]' "$oversized_body")"
assert_eq "the oversized issues-band fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#big_issues} > 131072 ))"

out_big="$(run_entry_build "o/r" "main" '["issues"]' "" \
  '[]' '[]' '[]' '[]' '[]' '[]' "$big_issues" '[]')"
assert_eq "an oversized issues band still produces the entry" "o/r" "$(jq -r '.slug' <<<"$out_big")"
# Bash string matching, not grep -F with the oversized string as an
# argument: that would hit the very argv cap this section exists to prove
# the real code no longer does.
out_big_body="$(jq -r '.issues[0].body // ""' <<<"$out_big")"
assert_eq "  ... carrying the issue's full body, not truncated or dropped" \
  "1" "$([[ "$out_big_body" == *"$oversized_body"* ]] && echo 1 || echo 0)"
assert_eq "  ... and every other band still comes through, none dropped" "true" \
  "$(jq '(.findings == []) and (.review_feedback == []) and (.tech_debt == [])' <<<"$out_big")"

# --- The expensive-gather cache save (requirement 4g/48, agent-ops#1107) ----
# lib/candidate-gather.sh's fresh branch folds the same nine bands (the eight
# above, plus issues_excluded) into expensive_gather_cache_save's own third
# argument. Before agent-ops#1107 this went through `jq --argjson`, nine
# flags in argv — the exact shape this file's own entry-build assertions
# above already rule out for the entry build itself — and agent-ops's own
# tech_debt_raw band (421,622 bytes) died at `execve` inside `$(…)` silently,
# leaving a 0-byte cache file two cycles in three. Lifted the same way as
# entry_build_block above, by its own literal start/end lines; the cache
# functions themselves are sourced for real from lib/expensive-gather-
# cache.sh and log_event lifted from agent-cycle.sh — the same extraction
# test/expensive-gather-cache.test.sh and test/first-seen-emission.test.sh
# both use — so these assertions exercise the shipped save/load, not a
# description of them.
cache_build_block="$(awk '
  index($0, "  expensive_gather_fresh=1") == 1 { on = 1 }
  on                                             { print }
  on && index($0, "could not persist the expensive-gather cache") > 0 { exit }
' "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ "$cache_build_block" != *'expensive_gather_cache_docs'* \
   || "$cache_build_block" != *'expensive_gather_cache_save'* ]]; then
  printf 'FAIL - could not extract the expensive-gather cache build from lib/candidate-gather.sh (moved or reworded?)\n'
  exit 1
fi

log_event_src="$(awk '
  $0 ~ /^log_event\(\) \{/ { on = 1 }
  on                        { print }
  on && /^}$/               { exit }
' "$SCRIPT_DIR/agent-cycle.sh")"
if [[ "$log_event_src" != *"log_event()"* ]]; then
  printf 'FAIL - could not extract log_event from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
eval "$log_event_src"

# shellcheck source=lib/expensive-gather-cache.sh
. "$SCRIPT_DIR/lib/expensive-gather-cache.sh"

run_cache_build() {  # run_cache_build <state_dir> <slug> <findings_raw>
                      #   <review_feedback_raw> <abandoned_drafts_raw>
                      #   <merge_conflicts_raw> <dequeued_raw> <register_hygiene_raw>
                      #   <issues_raw> <issues_excluded_raw> <tech_debt_raw>
  # Every one of these is consumed only by the eval'd cache_build_block,
  # invisible to shellcheck — including expensive_gather_fresh and
  # expensive_gather_as_of, which the block itself assigns.
  # shellcheck disable=SC2034
  ( state_dir="$1" slug="$2" findings_raw="$3" review_feedback_raw="$4" \
    abandoned_drafts_raw="$5" merge_conflicts_raw="$6" dequeued_raw="$7" \
    register_hygiene_raw="$8" issues_raw="$9" issues_excluded_raw="${10}" \
    tech_debt_raw="${11}" cycle_id="test-cycle" node_name="node-a" \
    log_file="$1/cache-build.log.jsonl"
    eval "$cache_build_block" )
}

cache_state="$(mktemp -d)"
trap 'rm -rf "$cache_state"' EXIT

oversized_td_body="$(head -c 140000 < /dev/zero | tr '\0' 'x')"
big_tech_debt="$(printf '[{"source": "tech-debt", "ref": "TD1", "body": "%s"}]' "$oversized_td_body")"
assert_eq "the oversized tech-debt fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#big_tech_debt} > 131072 ))"

run_cache_build "$cache_state" "o/cache-repo" '[]' '[]' '[]' '[]' '[]' '[]' '[]' 'null' "$big_tech_debt"

assert_eq "the cache build leaves a non-empty cache file, not the 0-byte pre-#1107 failure mode" \
  "1" "$([[ -s "$cache_state/expensive-gather/o_cache-repo.json" ]] && echo 1 || echo 0)"

cache_loaded="$(expensive_gather_cache_load "$cache_state" "o/cache-repo")"
assert_eq "the cache round-trips an oversized tech-debt band intact, not truncated or dropped" "1" \
  "$([[ "$(jq -r '.tech_debt_raw[0].body // ""' <<<"$cache_loaded")" == "$oversized_td_body" ]] && echo 1 || echo 0)"
assert_eq "  ... and every other band still comes through, none dropped" "true" \
  "$(jq '(.findings_raw == []) and (.review_feedback_raw == []) and (.issues_excluded_raw == null)' <<<"$cache_loaded")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
