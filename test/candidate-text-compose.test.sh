#!/usr/bin/env bash
#
# test/candidate-text-compose.test.sh — regression test for `item_live_entry`
# and `compose_selected_candidate_text` (requirement 17h, agent-ops#769,
# resolving agent-ops#844 option (b)).
#
# The owner decision on #844 chose option (b): the Script composes
# `context`/`acceptance`/`title` for the one item the Co-Ordinator (or the
# mechanical fallback, requirement 3v) selects, rather than trusting a model
# running on the fleet's cheapest tier to paste kilobytes of text its own
# input trimming may already have removed. `compose_selected_candidate_text`
# is where that happens: a live fetch for `issues`/`tech-debt` (the only two
# bands the fit ladder — lib/coordinator-input.sh — ever trims), the
# never-trimmed pre-fetched band entry for every other source the Script
# already gathers as structured data, and nothing at all — a deliberate
# no-op — for the three sources the Co-Ordinator still derives itself live
# (`project-review`, `failed-runs`, `implementation-plan`), which have no
# band entry to compose from in the first place.
#
# The functions are lifted verbatim out of lib/candidate-select.sh, the way
# test/item-text-fabrication.test.sh and test/refinement-traceability.test.sh
# lift their own, so the assertions are about the shipped code rather than a
# copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/candidate-text-compose.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/agent-cycle.sh"
CANDIDATE_SELECT="$SCRIPT_DIR/lib/candidate-select.sh"

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
assert_empty() { assert_eq "$1" "" "$2"; }
assert_nonempty() {
  local desc="$1" actual="$2"
  if [[ -n "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: <non-empty>\n     actual:   <empty>\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:              %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

# _traceability_normalize and refinement_traceability_repair are called
# directly by compose_selected_candidate_text, so both must be lifted too.
for fn in _traceability_normalize refinement_traceability_repair; do
  block="$(extract_block "^${fn}\\(\\) \\{" '^\}$' "$CANDIDATE_SELECT")"
  if [[ -z "$block" ]]; then
    echo "FAIL - could not extract $fn from lib/candidate-select.sh — has it moved?" >&2
    exit 1
  fi
  eval "$block"
done

for fn in item_live_entry compose_selected_candidate_text; do
  block="$(extract_block "^${fn}\\(\\) \\{" '^\}$' "$CANDIDATE_SELECT")"
  if [[ -z "$block" ]]; then
    echo "FAIL - could not extract $fn from lib/candidate-select.sh — has it moved?" >&2
    exit 1
  fi
  eval "$block"
done

for var in CANDIDATE_ENTRY_LOOKUP_JQ CANDIDATE_TEMPLATE_JQ; do
  block="$(extract_block "^${var}='" "^'\$" "$CANDIDATE_SELECT")"
  if [[ -z "$block" ]]; then
    echo "FAIL - could not extract $var from lib/candidate-select.sh — has it moved?" >&2
    exit 1
  fi
  eval "$block"
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

GH_CALLS_FILE="$T/gh_calls"
GH_LIVE_JSON=""
GH_RC=0
# shellcheck disable=SC2317  # reached only from the lifted item_live_entry block.
gh() {
  printf 'x' >>"$GH_CALLS_FILE"
  [[ "$GH_RC" == "0" ]] || return "$GH_RC"
  printf '%s' "$GH_LIVE_JSON"
}
gh_calls() { [[ -f "$GH_CALLS_FILE" ]] && wc -c <"$GH_CALLS_FILE" | tr -d ' ' || printf '0'; }
reset_gh_calls() { rm -f "$GH_CALLS_FILE"; }

GUARD_WARN_CALLS_FILE="$T/guard_warn_calls"
# shellcheck disable=SC2317  # reached only from the lifted compose block.
guard_warn() { printf '%s\t%s\n' "$1" "$2" >>"$GUARD_WARN_CALLS_FILE"; }
guard_warn_calls() { [[ -f "$GUARD_WARN_CALLS_FILE" ]] && wc -l <"$GUARD_WARN_CALLS_FILE" | tr -d ' ' || printf '0'; }
reset_guard_warn_calls() { rm -f "$GUARD_WARN_CALLS_FILE"; }

# --- item_live_entry ----------------------------------------------------------

reset_gh_calls
GH_RC=0
GH_LIVE_JSON='{"title":"Live title","body":"Live body, fetched fresh","comments":[{"author":"alice","created_at":"2026-08-01T00:00:00Z","body":"first comment"}]}'
live_out="$(item_live_entry "o/r" "issues" "42")"
assert_eq "item_live_entry (issues) prints the fetched title" "Live title" "$(jq -r '.title' <<<"$live_out")"
assert_eq "…and body" "Live body, fetched fresh" "$(jq -r '.body' <<<"$live_out")"
assert_eq "…and each comment's author/body" "alice/first comment" \
  "$(jq -r '.comments[0].author + "/" + .comments[0].body' <<<"$live_out")"

live_out_td="$(item_live_entry "o/r" "tech-debt" "42")"
assert_eq "item_live_entry (tech-debt) fetches identically to issues — both are GitHub issues since D15" \
  "$live_out" "$live_out_td"

assert_eq "item_live_entry refuses an unrecognised source" "1" \
  "$(item_live_entry "o/r" "review-feedback" "42" >/dev/null 2>&1; echo $?)"

# --- compose_selected_candidate_text: the three self-derived sources are a --
# --- deliberate no-op, never a fault -----------------------------------------

reset_gh_calls
for src in project-review failed-runs implementation-plan; do
  cand="$(jq -nc --arg s "$src" '{repo:"o/r", item:"R-01", source:$s, context:"model wrote this", acceptance:"model wrote this too"}')"
  compose_selected_candidate_text "$cand" '[]' '{}' >/dev/null
  rc=$?
  assert_eq "compose_selected_candidate_text no-ops for self-derived source $src" "2" "$rc"
done
assert_eq "…and none of them cost a gh call" "0" "$(gh_calls)"

# --- compose_selected_candidate_text: issues, live fetch succeeds -----------

repos='[{"slug":"o/r","issues":[{"number":42,"ref":"42","title":"Trimmed title","body":"…[Script: elided 900 of 1000 bytes to fit the context window — read it whole at https://x]","comments":[]}]}]'
refinements='{}'
cand='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"issues","item":"42","model":"claude-sonnet-5","model_reason":"stub","context":"model-authored, and possibly wrong","acceptance":"model-authored too"}'

reset_gh_calls
GH_RC=0
GH_LIVE_JSON='{"title":"The real, untrimmed title","body":"The real, untrimmed body","comments":[{"author":"bob","created_at":"2026-08-02T00:00:00Z","body":"a real comment"}]}'
out="$(compose_selected_candidate_text "$cand" "$repos" "$refinements")"
rc=$?
assert_eq "compose_selected_candidate_text (issues) succeeds" "0" "$rc"
assert_eq "…exactly one gh call (the live fetch)" "1" "$(gh_calls)"
assert_contains "…context carries the live, untrimmed body" "$(jq -r '.context' <<<"$out")" "The real, untrimmed body"
assert_contains "…and the live comment, attributed" "$(jq -r '.context' <<<"$out")" "bob (2026-08-02T00:00:00Z):
a real comment"
assert_eq "…never the trimmed band entry's elision marker" "" \
  "$(jq -r '.context' <<<"$out" | grep -o 'Script: elided' || true)"
assert_eq "…title is rebuilt from the live read" "Issue #42: The real, untrimmed title" "$(jq -r '.title' <<<"$out")"
assert_eq "…acceptance is the deterministic per-source instruction, not the model's own" \
  "Resolve per the current state of the issue thread above (body and every comment), not just the opening post." \
  "$(jq -r '.acceptance' <<<"$out")"
assert_eq "…every structural field survives unchanged" "o/r main autonomous-agent issues 42 claude-sonnet-5 stub" \
  "$(jq -r '[.repo, .default_branch, .pr_label, .source, .item, .model, .model_reason] | join(" ")' <<<"$out")"

# --- compose_selected_candidate_text: the recorded refinement is spliced in,
# --- unconditionally, generalising #767 rather than checking for it --------

reset_gh_calls
refinements_with_spec='{"o/r":{"42":{"spec":"The Refiner'"'"'s own specification for this item."}}}'
out_spec="$(compose_selected_candidate_text "$cand" "$repos" "$refinements_with_spec")"
assert_contains "the recorded refinement spec is spliced into the freshly composed context" \
  "$(jq -r '.context' <<<"$out_spec")" "The Refiner's own specification for this item."

# --- compose_selected_candidate_text: a failed live fetch is fail-closed ---

reset_gh_calls
GH_RC=1
out_fail="$(compose_selected_candidate_text "$cand" "$repos" "$refinements")"
rc=$?
assert_eq "a failed live fetch is a hard, fail-closed failure — never a fallback to the trimmed entry" "1" "$rc"
assert_empty "…and nothing is printed" "$out_fail"
assert_eq "…and the failure is reported via guard_warn" "1" "$(guard_warn_calls)"

# --- compose_selected_candidate_text: the item is missing from this cycle's
# --- own gather (a stale or nonexistent candidate) --------------------------

reset_gh_calls
GH_RC=0
cand_missing='{"repo":"o/r","source":"issues","item":"999"}'
out_missing="$(compose_selected_candidate_text "$cand_missing" "$repos" "$refinements")"
rc=$?
assert_eq "an item absent from ordered_repos_json fails closed" "1" "$rc"
assert_eq "…without ever attempting a gh call" "0" "$(gh_calls)"

# --- compose_selected_candidate_text: a never-trimmed source (no live fetch
# --- needed) uses the pre-fetched band entry directly -----------------------

repos_rf='[{"slug":"o/r","review_feedback":[{"ref":"pr-57-review-1","title":"pr-57-review-1","body":"A human'"'"'s specific, considered request.","branch":"agent/57","pr_url":"https://github.com/o/r/pull/57","pr_number":57}]}]'
cand_rf='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"review-feedback","item":"pr-57-review-1","model":"claude-sonnet-5","model_reason":"stub","branch":"agent/57","pr_url":"https://github.com/o/r/pull/57","pr_number":57}'

reset_gh_calls
out_rf="$(compose_selected_candidate_text "$cand_rf" "$repos_rf" "$refinements")"
rc=$?
assert_eq "compose_selected_candidate_text (review-feedback) succeeds without any live fetch" "0" "$rc"
assert_eq "…no gh call at all — the band entry is never trimmed" "0" "$(gh_calls)"
assert_eq "…context is the entry's own body, verbatim" "A human's specific, considered request." "$(jq -r '.context' <<<"$out_rf")"
assert_eq "…acceptance is the deterministic per-source instruction" \
  "Address the review feedback above and push to the existing pull request." "$(jq -r '.acceptance' <<<"$out_rf")"
assert_eq "…branch/pr_url/pr_number survive unchanged" "agent/57 https://github.com/o/r/pull/57 57" \
  "$(jq -r '[.branch, .pr_url, (.pr_number|tostring)] | join(" ")' <<<"$out_rf")"

# --- compose_selected_candidate_text: a Dependabot takeover gets its own ----
# --- acceptance, never the ordinary "rebase" instruction (agent-ops#250) ---

repos_mc='[{"slug":"o/r","merge_conflicts":[{"ref":"pr-9-conflict-abc","title":"pr-9-conflict-abc","body":"Bumps foo from 1.0.0 to 1.1.0.","bot":true,"rebase_requested":true,"superseded_by":null,"pr_url":"https://github.com/o/r/pull/9","pr_number":9}]}]'
cand_mc='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"merge-conflicts","item":"pr-9-conflict-abc","model":"claude-sonnet-5","model_reason":"stub","takeover":true,"pr_url":"https://github.com/o/r/pull/9","pr_number":9}'

reset_gh_calls
out_mc="$(compose_selected_candidate_text "$cand_mc" "$repos_mc" "$refinements")"
assert_contains "a Dependabot takeover's acceptance names the replacement pull request, never the ordinary rebase instruction" \
  "$(jq -r '.acceptance' <<<"$out_mc")" "Dependabot's own pull request is closed referencing the replacement"
assert_eq "…and takeover/pr_url/pr_number still survive unchanged" "true https://github.com/o/r/pull/9 9" \
  "$(jq -r '[(.takeover|tostring), .pr_url, (.pr_number|tostring)] | join(" ")' <<<"$out_mc")"

repos_mc_ord='[{"slug":"o/r","merge_conflicts":[{"ref":"pr-57-conflict-def","title":"pr-57-conflict-def","body":"The PR'"'"'s own description.","branch":"agent/57","pr_url":"https://github.com/o/r/pull/57","pr_number":57}]}]'
cand_mc_ord='{"repo":"o/r","default_branch":"main","pr_label":"autonomous-agent","source":"merge-conflicts","item":"pr-57-conflict-def","model":"claude-sonnet-5","model_reason":"stub","branch":"agent/57","pr_url":"https://github.com/o/r/pull/57","pr_number":57}'
out_mc_ord="$(compose_selected_candidate_text "$cand_mc_ord" "$repos_mc_ord" "$refinements")"
assert_eq "an ordinary (non-takeover) merge-conflicts candidate keeps the rebase acceptance" \
  "Rebase the existing pull request onto its base and resolve the conflict." "$(jq -r '.acceptance' <<<"$out_mc_ord")"

# --- The claim loop wires this in before requirement 17f/17g, and folds a --
# --- compose failure into the existing "untraceable" cause ------------------

loop_src="$(extract_block '^  c_composed=0' '^  # Requirement 17g ' "$AGENT_CYCLE")"
if [[ -n "$loop_src" && "$loop_src" == *'compose_selected_candidate_text'* \
      && "$loop_src" == *'cause: "untraceable"'* && "$loop_src" == *'trace_faults=$(( trace_faults + 1 ))'* ]]; then
  printf 'ok   - %s\n' "the claim loop calls compose_selected_candidate_text and folds a compose failure into the untraceable cause"
else
  printf 'FAIL - %s\n' "the claim loop does not wire compose_selected_candidate_text the way this test expects — has it moved or changed shape?"
  failures=$(( failures + 1 ))
fi

fab_block="$(extract_block '^  c_fab_fault=""' '^  # Requirement 17f ' "$AGENT_CYCLE")"
if [[ -n "$fab_block" && "$fab_block" == *'c_composed'* ]]; then
  printf 'ok   - %s\n' "requirement 17g's own fault check is exempted for a requirement 17h compose, same as a fallback pick"
else
  printf 'FAIL - %s\n' "requirement 17g's fault check no longer names c_composed — has the guard moved?"
  failures=$(( failures + 1 ))
fi

trace_block="$(extract_block '^  c_trace_fault=' '^  if \[\[ -n ' "$AGENT_CYCLE")"
if [[ -n "$trace_block" && "$trace_block" == *'c_composed'* ]]; then
  printf 'ok   - %s\n' "requirement 17f's own fault check is exempted for a requirement 17h compose, same as a fallback pick"
else
  printf 'FAIL - %s\n' "requirement 17f's fault check no longer names c_composed — has the guard moved?"
  failures=$(( failures + 1 ))
fi

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) FAILED"
  exit 1
else
  echo "All assertions passed."
  exit 0
fi
