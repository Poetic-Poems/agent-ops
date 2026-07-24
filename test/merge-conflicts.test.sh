#!/usr/bin/env bash
#
# test/merge-conflicts.test.sh — regression test for the candidate rule of
# scripts/gather-merge-conflicts.sh (requirement 3g) and the back-pressure
# narrowing it shares with review-feedback and abandoned-drafts (requirement 2.2a).
#
# The rule decides which of *our own* ready PRs are conflicted and safe to rebase,
# and it has two dangerous directions:
#   - too eager, and it force-pushes a rebase onto a PR that does not really
#     conflict (mergeability is computed asynchronously, so a PR whose base just
#     moved reads `UNKNOWN` for a beat), or onto a human's branch;
#   - too shy, and a genuinely conflicted PR a human is waiting to merge sits
#     forever occupying a back-pressure slot while every cycle looks healthy.
# The `CONFLICTING`-not-`UNKNOWN` gate and the non-draft/ours-by-branch filters are
# what hold the line; they are asserted here as jq over the same shapes the GitHub
# API returns, since the gatherer's `gh` calls aren't reachable from a unit test.
# Keep this in step with the filters in the script.
#
# Run directly:
#
#   ./test/merge-conflicts.test.sh
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

# --- The candidate filter: which ready PRs are ours to rebase? ---

# The shape `gh pr list --json number,title,headRefName,baseRefName,commits,isDraft,mergeable,updatedAt,url,body`
# returns (the `--label` filter is applied by gh, so every row here already
# carries pr_label). One of each kind we must accept or reject. A PR is a
# candidate when it is open, *not* a draft, `mergeable` is exactly `CONFLICTING`,
# and its head is on a branch we own.
prs='[
  {"number": 90, "isDraft": false, "mergeable": "CONFLICTING", "headRefName": "agent/td1-fix"},
  {"number": 91, "isDraft": true,  "mergeable": "CONFLICTING", "headRefName": "agent/td2-fix"},
  {"number": 92, "isDraft": false, "mergeable": "MERGEABLE",   "headRefName": "agent/td3-fix"},
  {"number": 93, "isDraft": false, "mergeable": "UNKNOWN",     "headRefName": "agent/td4-fix"},
  {"number": 94, "isDraft": false, "mergeable": "CONFLICTING", "headRefName": "feature/a-humans-branch"},
  {"number": 95, "isDraft": false, "mergeable": "CONFLICTING", "headRefName": "td/TD26072001"}
]'

candidate_filter() {
  jq -c '[.[] | select(.isDraft | not)
              | select(.mergeable == "CONFLICTING")
              | select((.headRefName | startswith("agent/"))
                       or (.headRefName | startswith("td/")))
              | .number]' <<<"$prs"
}

assert_eq "only open, non-draft, CONFLICTING, ours-by-branch PRs are candidates" \
  "[90,95]" "$(candidate_filter)"

# Each exclusion, named, so a future edit that drops one fails loudly:
# - #91 draft: a draft is the Implementor's own claim marker; a draft's conflict
#   is abandoned-drafts' to resolve once the draft goes stale, never here.
# - #92 mergeable: no conflict — nothing to do. Rebasing it would be churn.
# - #93 UNKNOWN: mergeability is computed asynchronously, so a PR whose base just
#   moved reads UNKNOWN for a beat. Treating that as a conflict would send the
#   Implementor to rebase a PR that may not conflict. This is the assertion that
#   keeps the feature from acting on a guess.
# - #94 human branch: only branches under agent/ (or the tech-debt td/ claim
#   branch) are ours; the Human Gate reserves the rest — force-pushing a rebase
#   onto a human's PR would breach it.
assert_eq "a draft PR is never a merge-conflicts candidate" \
  "0" "$(jq '[.[] | select(.number == 91) | select(.isDraft | not)] | length' <<<"$prs")"
assert_eq "a mergeable PR is never a merge-conflicts candidate" \
  "0" "$(jq '[.[] | select(.number == 92) | select(.mergeable == "CONFLICTING")] | length' <<<"$prs")"
assert_eq "an UNKNOWN-mergeability PR is not a candidate — never rebase on a guess" \
  "0" "$(jq '[.[] | select(.number == 93) | select(.mergeable == "CONFLICTING")] | length' <<<"$prs")"
assert_eq "a human's own branch is never ours to rebase" \
  "0" "$(jq '[.[] | select(.number == 94) | select((.headRefName | startswith("agent/")) or (.headRefName | startswith("td/")))] | length' <<<"$prs")"
assert_eq "a tech-debt td/ claim branch counts as ours" \
  "1" "$(jq '[.[] | select(.number == 95) | select(.headRefName | startswith("td/"))] | length' <<<"$prs")"

# --- The ref: scoped to the head SHA ---
#
# `pr-<n>-conflict-<head-sha[:12]>`, not `pr-<n>-conflict`. An item recorded
# blocked (requirement 34) stays blocked until something clears it, so a bare
# `pr-90-conflict` that an Implementor once failed to resolve would still be
# blocked after fresh commits landed — and the new, possibly-resolvable state
# would never be looked at again. Scoping to the head means each distinct
# conflicted state is its own item that no older block covers, while a resolution
# (which moves the head) retires the ref and a conflict re-detected at the same
# head keeps it. Same reasoning as abandoned-drafts' per-head refs.
ref_of() { jq -r '"pr-\(.number)-conflict-\(.head_sha[0:12])"' <<<"$1"; }
assert_eq "the ref pins to the PR number and the head SHA's first 12 chars" \
  "pr-90-conflict-1a2b3c4d5e6f" \
  "$(ref_of '{"number": 90, "head_sha": "1a2b3c4d5e6f7a8b9c0d"}')"
assert_eq "a new head after a resolution yields a different ref, so an old block cannot cover it" \
  "pr-90-conflict-ffffffffffff" \
  "$(ref_of '{"number": 90, "head_sha": "ffffffffffffaaaa1111"}')"

# --- Back-pressure narrowing (requirement 2.2a) ---
#
# When back-pressure trips, the cycle narrows to the three *finishing* sources
# rather than standing down, so a gate full of stalled work can still be cleared.
# Tested here rather than live because reaching the branch needs
# max_open_agent_prs exceeded *and* a finishing candidate waiting at the same
# moment — the exact state nobody wants to be discovering the behaviour of.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "merge-conflicts", "abandoned-drafts", "tech-debt"], "review_feedback": [], "merge_conflicts": [{"ref": "pr-90-conflict-1a2b3c4d5e6f"}], "abandoned_drafts": []},
  {"slug": "o/two", "sources": ["security", "review-feedback", "merge-conflicts", "abandoned-drafts", "issues"], "review_feedback": [], "merge_conflicts": [], "abandoned_drafts": []}
]'
restrict() { jq -c '[.[] | .sources = (.sources | map(select(. == "review-feedback" or . == "merge-conflicts" or . == "abandoned-drafts")))]' <<<"$ordered"; }

assert_eq "restriction leaves only the three finishing sources selectable" \
  '["review-feedback","merge-conflicts","abandoned-drafts"] ["review-feedback","merge-conflicts","abandoned-drafts"]' \
  "$(restrict | jq -r '[.[] | (.sources | tojson)] | join(" ")')"
assert_eq "security and fresh sources are narrowed away — a full gate means finish, don't start" \
  "0" "$(restrict | jq '[.[].sources[] | select(. == "security" or . == "tech-debt" or . == "issues")] | length')"

# The count that decides stand-down vs restrict: all three finishing sources,
# across all repos.
assert_eq "finishing candidates count review-feedback, merge-conflicts AND abandoned-drafts across all repos" \
  "1" "$(jq '[.[].review_feedback[]?, .[].merge_conflicts[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"
assert_eq "with nothing waiting to finish, the count is 0 and the cycle stands down as before" \
  "0" "$(jq '[.[] | .review_feedback = [] | .merge_conflicts = [] | .abandoned_drafts = []] | [.[].review_feedback[]?, .[].merge_conflicts[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"

# --- The gatherer itself fails safe ---

assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$("$SCRIPT_DIR/scripts/gather-merge-conflicts.sh" "Poetic-Poems/does-not-exist" autonomous-agent 'agent/' 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
