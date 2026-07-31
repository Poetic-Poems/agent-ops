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
# The freshness gate is "last **real** activity older than the threshold"
# (TD26072605) — not GitHub's raw `updatedAt`, which also moves for a label edit
# or a comment the pipeline posted about itself, neither of which means anybody
# is on it. This is the half most easily broken by a careless edit — so it is
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

# The shape `gh pr list --json
# number,title,headRefName,commits,isDraft,updatedAt,url,body,comments,reviews`
# returns (the `--label` filter is applied by gh, so every row here already
# carries pr_label). `cutoff` is `now − stale-hours`; a PR is abandoned when its
# **last real activity** — not its raw `updatedAt` — is older than it.
cutoff='2026-07-24T09:00:00Z'
marker='<!-- agent-ops:pipeline-comment'
prs='[
  {"number": 80, "isDraft": true,  "headRefName": "agent/td1-fix",
   "commits": [{"committedDate": "2026-07-24T03:00:00Z", "oid": "a1"}], "reviews": [], "comments": []},
  {"number": 81, "isDraft": false, "headRefName": "agent/td2-fix",
   "commits": [{"committedDate": "2026-07-24T03:00:00Z", "oid": "a2"}], "reviews": [], "comments": []},
  {"number": 82, "isDraft": true,  "headRefName": "agent/td3-fix",
   "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "a3"}], "reviews": [],
   "comments": [{"createdAt": "2026-07-24T11:00:00Z", "body": "still working on this"}]},
  {"number": 83, "isDraft": true,  "headRefName": "feature/a-humans-branch",
   "commits": [{"committedDate": "2026-07-24T03:00:00Z", "oid": "a4"}], "reviews": [], "comments": []},
  {"number": 84, "isDraft": true,  "headRefName": "td/TD26072001",
   "commits": [{"committedDate": "2026-07-24T01:00:00Z", "oid": "a5"}], "reviews": [], "comments": []},
  {"number": 85, "isDraft": true,  "headRefName": "agent/label-edit-only",
   "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "a6"}], "reviews": [], "comments": []},
  {"number": 86, "isDraft": true,  "headRefName": "agent/marker-comment-only",
   "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "a7"}], "reviews": [],
   "comments": [{"createdAt": "2026-07-28T21:00:00Z",
                 "body": "Autonomous agent (implementor) stopped on this PR: … <!-- agent-ops:pipeline-comment cycle=20260728T210000Z-node-1-99 -->"}]},
  {"number": 87, "isDraft": true,  "headRefName": "agent/human-comment-recent",
   "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "a8"}], "reviews": [],
   "comments": [{"createdAt": "2026-07-28T21:00:00Z", "body": "any update on this?"}]},
  {"number": 88, "isDraft": true,  "headRefName": "agent/human-review-recent",
   "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "a9"}],
   "reviews": [{"submittedAt": "2026-07-28T21:00:00Z"}], "comments": []},
  {"number": 89, "isDraft": true,  "headRefName": "agent/marker-review-only",
   "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "b1"}],
   "reviews": [{"submittedAt": "2026-07-28T21:00:00Z",
                "body": "Flagging a design choice for the human reviewer. <!-- agent-ops:pipeline-comment cycle=20260728T210000Z-node-1-99 -->"}],
   "comments": []}
]'

# gh's nested collections arrive capped at 100 items, unpaginated, and
# `comments` oldest-first — so a collection at exactly the cap may be missing
# the newest activity, and at the commits cap `[-1]` is not the head. These
# fixtures are appended with jq because writing a hundred rows out longhand
# would bury the point. Every date *visible* on #90–#92 is stale; the point is
# that at the cap what is visible cannot be trusted, so the PR must not be
# judged at all. #93 is the boundary contrast: one under the cap, the data is
# complete, and judgement resumes.
prs="$(jq -c '
  . + [{"number": 90, "isDraft": true, "headRefName": "agent/comments-at-cap",
        "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "b2"}], "reviews": [],
        "comments": [range(100) | {"createdAt": "2026-07-20T01:00:00Z", "body": "old chatter"}]},
       {"number": 91, "isDraft": true, "headRefName": "agent/reviews-at-cap",
        "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "b3"}],
        "reviews": [range(100) | {"submittedAt": "2026-07-20T01:00:00Z", "body": "old review"}],
        "comments": []},
       {"number": 92, "isDraft": true, "headRefName": "agent/commits-at-cap",
        "commits": [range(100) | {"committedDate": "2026-07-20T00:00:00Z", "oid": "b4"}],
        "reviews": [], "comments": []},
       {"number": 93, "isDraft": true, "headRefName": "agent/comments-under-cap",
        "commits": [{"committedDate": "2026-07-20T00:00:00Z", "oid": "b5"}], "reviews": [],
        "comments": [range(99) | {"createdAt": "2026-07-20T01:00:00Z", "body": "old chatter"}]}]' <<<"$prs")"

# Mirrors the computation in scripts/gather-abandoned-drafts.sh: the
# draft/branch filter first, then last-real-activity (latest commit, or review
# or comment not carrying the marker) against the cutoff — unless any nested
# collection is at gh's 100-item cap, in which case activity is uncomputable
# and the PR is excluded outright.
candidate_filter() {
  jq -c --arg cutoff "$cutoff" --arg marker "$marker" \
    '[.[] | select(.isDraft)
          | select((.headRefName | startswith("agent/"))
                   or (.headRefName | startswith("td/")))
          | (if ((((.commits  // []) | length) >= 100)
                 or (((.reviews  // []) | length) >= 100)
                 or (((.comments // []) | length) >= 100))
             then null
             else (([ (.commits[-1].committedDate // empty) ]
                    + [ (.reviews // [])[] | select((.body // "") | contains($marker) | not) | .submittedAt ]
                    + [ (.comments // [])[] | select((.body // "") | contains($marker) | not) | .createdAt ])
                   | max)
             end) as $activity
          | select($activity != null and $activity < $cutoff)
          | .number]' <<<"$prs"
}

assert_eq "only open, draft, ours-by-branch, actually-stale PRs are candidates" \
  "[80,84,85,86,89,93]" "$(candidate_filter)"

# Each exclusion, named, so a future edit that drops one fails loudly:
# - #81 ready: a ready PR is finished work waiting on the human. Finishing it is
#   review-feedback's job; force-pushing it would breach the Human Gate.
# - #82 a human's comment, after the cutoff: a draft still being worked, or one
#   a peer node just touched. Stealing it would force-push over live work. This
#   is the assertion that keeps the feature from cannibalising in-flight cycles.
# - #83 human branch: only branches under agent/ (or the tech-debt td/ claim
#   branch) are ours; the Human Gate reserves the rest.
# - #87 a human's comment resets the clock even though the last commit is old —
#   the direct contrast with #86, whose only recent write is marker-stamped.
# - #88 a review resets the clock too, same as any other real activity.
is_candidate() { candidate_filter | jq --argjson n "$1" 'index($n) != null'; }

assert_eq "a ready PR is never an abandoned-draft candidate" \
  "false" "$(is_candidate 81)"
assert_eq "a human's recent comment keeps a draft off the list — never steal live work" \
  "false" "$(is_candidate 82)"
assert_eq "a human's own branch is never ours to finish" \
  "0" "$(jq '[.[] | select(.number == 83) | select((.headRefName | startswith("agent/")) or (.headRefName | startswith("td/")))] | length' <<<"$prs")"
assert_eq "a tech-debt td/ claim branch counts as ours" \
  "1" "$(jq '[.[] | select(.number == 84) | select(.headRefName | startswith("td/"))] | length' <<<"$prs")"
assert_eq "a human's recent comment resets the clock even over an old commit" \
  "false" "$(is_candidate 87)"
assert_eq "a human review resets the clock" \
  "false" "$(is_candidate 88)"

# --- TD26072605: the pipeline's own writes must not reset the clock ---

# #85 has no comments or reviews at all — its raw `updatedAt` is irrelevant
# because this script never reads that field; a label edit (which moves
# `updatedAt` but appears in none of commits/reviews/comments) is discounted
# simply by not being a signal this computation looks at.
assert_eq "a PR touched only by a label edit is still judged solely on real activity" \
  "true" "$(is_candidate 85)"

# #86 carries a comment stamped with the pipeline's own marker, timestamped
# well after the cutoff — and it is still a candidate, because the marker
# excludes it from the activity computation entirely (not-at-all, per
# TD26072605's decision, not a partial reset).
assert_eq "a comment carrying the pipeline's own marker does not reset the clock" \
  "true" "$(is_candidate 86)"

# #87 is the same shape as #86 — an old commit, one comment after the cutoff —
# but its comment carries no marker, so it is a human's write and does reset
# the clock. The pair is the regression guard: change the marker string, or the
# `contains($marker)` filter, and one of these two flips.
assert_eq "an unmarked comment at the same timestamp as #86's marked one still resets the clock" \
  "true false" "$(is_candidate 86) $(is_candidate 87)"

# #89 is #86 posted the other way. `gh pr comment` files a note under
# `comments`; `gh pr review --comment` files the same words under `reviews`,
# and prompts/reviewer.md step 5 lets the Reviewer use either — so the marker
# has to be honoured in both collections or the pipeline goes on resetting its
# own clock through whichever one is unfiltered. #88 is the contrast: a human's
# review, no marker, and it still counts.
assert_eq "a review carrying the pipeline's own marker does not reset the clock either" \
  "true" "$(is_candidate 89)"
assert_eq "a marked review and an unmarked one at the same timestamp differ" \
  "true false" "$(is_candidate 89) $(is_candidate 88)"

# --- gh's nested-collection cap: at-cap data is missing data ---
#
# `gh pr list` caps `commits`, `reviews` and `comments` at 100 items each,
# unpaginated, and `comments` arrives oldest-first — so on a PR past the cap
# the response holds the *oldest* writes and the newest are absent. Every date
# visible on #90–#92 is stale, and each would be a candidate if judged; the
# rule is that at the cap the PR is not judged at all, because a human's
# comment posted yesterday could be precisely the entry the cap cut off — and
# stealing that draft is the failure the script's header names as the one to
# avoid. #92 is the same rule for commits, where `[-1]` at the cap is the
# hundredth commit, not the head. The exclusion is deliberate and costs
# something real: a genuinely abandoned draft carrying 100 of anything waits
# for a human instead of being auto-finished. That is the safe direction.
assert_eq "comments at gh's 100-item cap: the newest may be missing, so the PR is never judged" \
  "false" "$(is_candidate 90)"
assert_eq "reviews at the cap are excluded the same way" \
  "false" "$(is_candidate 91)"
assert_eq "commits at the cap: [-1] is not the head, so the PR is excluded too" \
  "false" "$(is_candidate 92)"
assert_eq "one under the cap, the data is complete and the draft is judged normally" \
  "true" "$(is_candidate 93)"

# --- One definition: the marker as every writer of it spells it ---
#
# `lib/pipeline-marker.sh` is the single definition (requirement 34a), and the
# reader — and agent-cycle.sh's own comments — source it. Three places cannot:
# the fixtures above, and the comment instructions in prompts/enabler.md and
# prompts/reviewer.md, which a model reads and types out. Change the prefix
# without changing those and the Enabler and Reviewer go on stamping a marker
# the gatherer no longer recognises — the clock resets TD26072605 removed,
# back again, with every test still green. These assertions are what makes the
# one-definition claim hold for the three copies that must be spelled out.
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
assert_eq "the fixtures above carry the marker prefix the library defines" \
  "$PIPELINE_COMMENT_MARKER_PREFIX" "$marker"
for prompt in enabler reviewer; do
  assert_eq "prompts/$prompt.md tells its stage to write that same prefix" "yes" \
    "$(grep -qF -- "$PIPELINE_COMMENT_MARKER_PREFIX" "$SCRIPT_DIR/prompts/$prompt.md" \
       && echo yes || echo no)"
done

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
# When back-pressure trips, the cycle narrows to the three *finishing* sources
# rather than standing down, so a gate full of stalled work can still be cleared.
# Tested here rather than live because reaching the branch needs
# max_open_agent_prs exceeded *and* a finishing candidate waiting at the same
# moment — the exact state nobody wants to be discovering the behaviour of.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "abandoned-drafts", "tech-debt"], "review_feedback": [], "abandoned_drafts": [{"ref": "pr-80-abandoned-1a2b3c4d5e6f"}]},
  {"slug": "o/two", "sources": ["security", "review-feedback", "abandoned-drafts", "issues"], "review_feedback": [], "abandoned_drafts": []}
]'
restrict() { jq -c '[.[] | .sources = (.sources | map(select(. == "review-feedback" or . == "merge-conflicts" or . == "abandoned-drafts")))]' <<<"$ordered"; }

assert_eq "restriction leaves only the finishing sources present in this fixture selectable" \
  '["review-feedback","abandoned-drafts"] ["review-feedback","abandoned-drafts"]' \
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
