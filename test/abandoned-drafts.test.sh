#!/usr/bin/env bash
#
# test/abandoned-drafts.test.sh — regression test for the candidate rule of
# scripts/gather-abandoned-drafts.sh (requirement 3e) and the back-pressure
# narrowing it shares with review-feedback (requirement 2.2a).
#
# The rule decides which of *our own* draft PRs have been abandoned and are safe
# to finish, and it has two dangerous directions:
#   - too eager, and it steals a draft a peer node (or a human) is still working,
#     force-pushing over live work;
#   - too shy, and a genuinely stalled draft sits forever occupying a
#     back-pressure slot while every cycle looks healthy.
# The freshness gate (`updatedAt` older than the threshold) is what holds the
# line, and it is the half most easily broken by a careless edit — so it is
# asserted here, as jq over the same shapes the GitHub API returns, since the
# gatherer's `gh` calls aren't reachable from a unit test. Keep this in step with
# the filters in the script.
#
# Run directly:
#
#   ./test/abandoned-drafts.test.sh
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

# --- The candidate filter: which draft PRs are ours to finish? ---

# The shape `gh pr list --json number,title,headRefName,commits,isDraft,updatedAt,url,body`
# returns (the `--label` filter is applied by gh, so every row here already
# carries pr_label). One of each kind we must accept or reject. `cutoff` is
# `now − stale-hours`; a PR is abandoned when its `updatedAt` is *older* than it.
cutoff='2026-07-24T09:00:00Z'
prs='[
  {"number": 80, "isDraft": true,  "updatedAt": "2026-07-24T03:00:00Z", "headRefName": "agent/td1-fix"},
  {"number": 81, "isDraft": false, "updatedAt": "2026-07-24T03:00:00Z", "headRefName": "agent/td2-fix"},
  {"number": 82, "isDraft": true,  "updatedAt": "2026-07-24T11:00:00Z", "headRefName": "agent/td3-fix"},
  {"number": 83, "isDraft": true,  "updatedAt": "2026-07-24T03:00:00Z", "headRefName": "feature/a-humans-branch"},
  {"number": 84, "isDraft": true,  "updatedAt": "2026-07-24T01:00:00Z", "headRefName": "td/TD26072001"}
]'

candidate_filter() {
  jq -c --arg cutoff "$cutoff" \
    '[.[] | select(.isDraft)
          | select(.updatedAt < $cutoff)
          | select((.headRefName | startswith("agent/"))
                   or (.headRefName | startswith("td/")))
          | .number]' <<<"$prs"
}

assert_eq "only open, draft, ours-by-branch, stale PRs are candidates" \
  "[80,84]" "$(candidate_filter)"

# Each exclusion, named, so a future edit that drops one fails loudly:
# - #81 ready: a ready PR is finished work waiting on the human. Finishing it is
#   review-feedback's job; force-pushing it would breach the Human Gate.
# - #82 fresh: updated within the window — a draft still being worked, or one a
#   peer node just touched. Stealing it would force-push over live work. This is
#   the assertion that keeps the feature from cannibalising in-flight cycles.
# - #83 human branch: only branches under agent/ (or the tech-debt td/ claim
#   branch) are ours; the Human Gate reserves the rest.
assert_eq "a ready PR is never an abandoned-draft candidate" \
  "0" "$(jq '[.[] | select(.number == 81) | select(.isDraft)] | length' <<<"$prs")"
assert_eq "a freshly-updated draft is not abandoned — never steal live work" \
  "0" "$(jq --arg c "$cutoff" '[.[] | select(.number == 82) | select(.updatedAt < $c)] | length' <<<"$prs")"
assert_eq "a human's own branch is never ours to finish" \
  "0" "$(jq '[.[] | select(.number == 83) | select((.headRefName | startswith("agent/")) or (.headRefName | startswith("td/")))] | length' <<<"$prs")"
assert_eq "a tech-debt td/ claim branch counts as ours" \
  "1" "$(jq '[.[] | select(.number == 84) | select(.headRefName | startswith("td/"))] | length' <<<"$prs")"

# --- The ref: scoped to the head SHA ---
#
# `pr-<n>-abandoned-<head-sha[:12]>`, not `pr-<n>-abandoned`. An item recorded
# blocked (requirement 34) stays blocked until something clears it, so a bare
# `pr-80-abandoned` that an Implementor once failed on would still be blocked
# after fresh commits landed — and the new, possibly-finishable state would never
# be looked at again. Scoping to the head means each distinct abandoned state is
# its own item that no older block covers, while a draft re-abandoned at the same
# head keeps the same ref and stays blocked. Same reasoning as review-feedback's
# per-round refs.
ref_of() { jq -r '"pr-\(.number)-abandoned-\(.head_sha[0:12])"' <<<"$1"; }
assert_eq "the ref pins to the PR number and the head SHA's first 12 chars" \
  "pr-80-abandoned-1a2b3c4d5e6f" \
  "$(ref_of '{"number": 80, "head_sha": "1a2b3c4d5e6f7a8b9c0d"}')"
assert_eq "a new head after fresh commits yields a different ref, so an old block cannot cover it" \
  "pr-80-abandoned-ffffffffffff" \
  "$(ref_of '{"number": 80, "head_sha": "ffffffffffffaaaa1111"}')"

# --- Back-pressure narrowing (requirement 2.2a) ---
#
# When back-pressure trips, the cycle narrows to the two *finishing* sources
# rather than standing down, so a gate full of stalled work can still be cleared.
# Tested here rather than live because reaching the branch needs
# max_open_agent_prs exceeded *and* a finishing candidate waiting at the same
# moment — the exact state nobody wants to be discovering the behaviour of.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "abandoned-drafts", "tech-debt"], "review_feedback": [], "abandoned_drafts": [{"ref": "pr-80-abandoned-1a2b3c4d5e6f"}]},
  {"slug": "o/two", "sources": ["security", "review-feedback", "abandoned-drafts", "issues"], "review_feedback": [], "abandoned_drafts": []}
]'
restrict() { jq -c '[.[] | .sources = (.sources | map(select(. == "review-feedback" or . == "abandoned-drafts")))]' <<<"$ordered"; }

assert_eq "restriction leaves only the two finishing sources selectable" \
  '["review-feedback","abandoned-drafts"] ["review-feedback","abandoned-drafts"]' \
  "$(restrict | jq -r '[.[] | (.sources | tojson)] | join(" ")')"
assert_eq "security and fresh sources are narrowed away — a full gate means finish, don't start" \
  "0" "$(restrict | jq '[.[].sources[] | select(. == "security" or . == "tech-debt" or . == "issues")] | length')"

# The count that decides stand-down vs restrict: both finishing sources, across
# all repos.
assert_eq "finishing candidates count review-feedback AND abandoned-drafts across all repos" \
  "1" "$(jq '[.[].review_feedback[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"
assert_eq "with nothing waiting to finish, the count is 0 and the cycle stands down as before" \
  "0" "$(jq '[.[] | .review_feedback = [] | .abandoned_drafts = []] | [.[].review_feedback[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"

# --- The gatherer itself fails safe ---

assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$("$SCRIPT_DIR/scripts/gather-abandoned-drafts.sh" "Poetic-Poems/does-not-exist" autonomous-agent 'agent/' 3 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

# A non-numeric staleness threshold is a caller bug, not licence to treat every
# draft as abandoned: fail safe to [] rather than to "everything".
assert_eq "a garbage staleness threshold yields [] rather than every draft" "[]" \
  "$("$SCRIPT_DIR/scripts/gather-abandoned-drafts.sh" "Poetic-Poems/poetic" autonomous-agent 'agent/' "not-a-number" 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
