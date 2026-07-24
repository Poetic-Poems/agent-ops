#!/usr/bin/env bash
#
# test/review-feedback.test.sh — regression test for the candidate rule of
# scripts/gather-review-feedback.sh (requirement 3c).
#
# The rule decides *whose turn it is* on a pull request a human has asked for
# changes on, and it has exactly one dangerous direction. The agent raises PRs
# as the account it runs as, and GitHub forbids approving or dismissing a review
# on your own PR — so `reviewDecision` stays CHANGES_REQUESTED even after the
# fix is pushed. Nothing about the PR's own state ever says "answered". The only
# thing that does is the comparison this file tests: latest review vs head
# commit.
#
# Get it wrong and every PR the agent fixes stays a candidate forever: selected,
# re-fixed, re-selected, on the hour, each cycle looking like a productive one
# and each one paying a Sonnet run to redo work already pushed. The pipeline
# would never look broken.
#
# The gatherer's `gh` calls aren't reachable from a unit test, so the rule is
# tested where it lives — as jq over the same shapes the GitHub API returns.
# Keep this in step with the filters in the script.
#
# Run directly:
#
#   ./test/review-feedback.test.sh
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

# --- The PR filter: which PRs are even ours to answer? ---

# The shape `gh pr list --json number,title,headRefName,commits,isDraft,reviewDecision,url,body`
# returns. One of each kind we must accept or reject.
prs='[
  {"number": 57, "isDraft": false, "reviewDecision": "CHANGES_REQUESTED", "headRefName": "agent/td1-fix"},
  {"number": 58, "isDraft": true,  "reviewDecision": "CHANGES_REQUESTED", "headRefName": "agent/td2-fix"},
  {"number": 59, "isDraft": false, "reviewDecision": "APPROVED",          "headRefName": "agent/td3-fix"},
  {"number": 60, "isDraft": false, "reviewDecision": "REVIEW_REQUIRED",   "headRefName": "agent/td4-fix"},
  {"number": 61, "isDraft": false, "reviewDecision": null,                "headRefName": "agent/td5-fix"},
  {"number": 62, "isDraft": false, "reviewDecision": "CHANGES_REQUESTED", "headRefName": "feature/a-humans-branch"}
]'

pr_filter() {
  jq -c '[.[] | select(.isDraft | not)
              | select(.reviewDecision == "CHANGES_REQUESTED")
              | select(.headRefName | startswith("agent/"))
              | .number]' <<<"$prs"
}

assert_eq "only open, ready, agent-branch, changes-requested PRs are candidates" \
  "[57]" "$(pr_filter)"

# Each exclusion, named, so a future edit that drops one fails loudly:
# - #58 draft: a draft PR is the Implementor's own claim marker, not something a
#   human has finished reviewing.
# - #59/#60/#61: nobody has asked for changes.
# - #62: the Human Gate is explicit that branches outside `branch_prefix` belong
#   to humans. An agent force-pushing a colleague's PR because they happened to
#   request changes on it would be a memorable way to discover this rule.
assert_eq "a draft PR is not a review-feedback candidate" \
  "0" "$(jq '[.[] | select(.number == 58) | select(.isDraft | not)] | length' <<<"$prs")"
assert_eq "an approved PR is not a review-feedback candidate" \
  "0" "$(jq '[.[] | select(.number == 59) | select(.reviewDecision == "CHANGES_REQUESTED")] | length' <<<"$prs")"
assert_eq "a human's own branch is never ours to push to" \
  "0" "$(jq '[.[] | select(.number == 62) | select(.headRefName | startswith("agent/"))] | length' <<<"$prs")"

# --- The turn rule: is the feedback unanswered? ---

# submitted_at null = a pending review the human is still drafting; it has not
# been sent and must not count as feedback.
reviews='[
  {"id": 1, "state": "COMMENTED",         "at": "2026-07-17T01:22:24Z", "who": "warwickallen"},
  {"id": 2, "state": "CHANGES_REQUESTED", "at": "2026-07-17T01:22:54Z", "who": "Warwick-Allen"}
]'

fresh_after() {
  jq -c --arg c "$1" '[.[] | select(.at > $c)] | sort_by(.at)' <<<"$reviews"
}

# The live case: PR #57's head commit is 01:07:22, the review 01:22:54.
assert_eq "a review newer than the head commit is unanswered — our turn" \
  "2" "$(fresh_after "2026-07-17T01:07:22Z" | jq 'length')"

# The case that decides whether this feature loops forever. The agent has just
# pushed at 01:30; reviewDecision is *still* CHANGES_REQUESTED and always will
# be until the human re-reviews.
assert_eq "once the agent has pushed, the round is answered — the human's turn" \
  "0" "$(fresh_after "2026-07-17T01:30:00Z" | jq 'length')"

# And a fresh round after that push is our turn again.
reviews_round2="$(jq -c '. + [{"id": 3, "state": "CHANGES_REQUESTED", "at": "2026-07-17T02:00:00Z", "who": "Warwick-Allen"}]' <<<"$reviews")"
assert_eq "a new review after the agent's push reopens it" \
  "1" "$(jq -c --arg c "2026-07-17T01:30:00Z" '[.[] | select(.at > $c)] | length' <<<"$reviews_round2")"

# --- The round's ref ---
#
# Scoped to the blocking review's id, not the PR. An item recorded blocked
# (requirement 34) stays blocked until something clears it, so a bare `pr-57`
# that the Implementor once failed on would still be blocked when the human
# posted fresh guidance — and their new review would land on a dead item. A
# per-round ref means each round is a new item no old block covers, the same
# reasoning as the review-dated `review-<date>-R-NN` refs.
ref_of() {
  local fresh="$1" id
  id="$(jq -r '[.[] | select(.state == "CHANGES_REQUESTED")] | (last // .[-1]) | .id' <<<"$fresh")"
  [[ -n "$id" && "$id" != "null" ]] || id="$(jq -r '.[-1].id' <<<"$fresh")"
  printf 'pr-57-review-%s' "$id"
}
assert_eq "the ref pins to the blocking review, not the chattiest one" \
  "pr-57-review-2" "$(ref_of "$(fresh_after "2026-07-17T01:07:22Z")")"
assert_eq "a second round yields a different ref, so an old block cannot cover it" \
  "pr-57-review-3" "$(ref_of "$(jq -c --arg c "2026-07-17T01:30:00Z" '[.[] | select(.at > $c)]' <<<"$reviews_round2")")"

# A round with no formal CHANGES_REQUESTED still refs its last review rather
# than producing `pr-57-review-null`, which would collide across rounds and
# silently merge two items into one.
assert_eq "a round with no blocking review still gets a real ref" \
  "pr-57-review-1" "$(ref_of '[{"id": 1, "state": "COMMENTED", "at": "2026-07-17T01:22:24Z"}]')"

# --- The body: every review in the round, whoever wrote it ---
#
# The substance and the formal signal routinely live in different reviews by
# different accounts, because GitHub will not let a PR's author request changes
# on it. In the wild here: `warwickallen` (the agent's own account, so
# COMMENTED is all it can leave) wrote 6.5 KB of specific findings, and the
# human's second account posted the CHANGES_REQUESTED whose body reads, in full,
# "Refer to <link>". Gathering only the blocking review hands the Implementor
# the word "Refer to" and nothing to act on.
round='[
  {"id": 1, "state": "COMMENTED", "at": "2026-07-17T01:22:24Z", "who": "warwickallen", "body": "the gitignore gap is the one I would block on"},
  {"id": 2, "state": "CHANGES_REQUESTED", "at": "2026-07-17T01:22:54Z", "who": "Warwick-Allen", "body": "Refer to https://github.com/…#pullrequestreview-4718691960"}
]'
body="$(jq -r --argjson fr "$round" --argjson fc '[]' -n '
  ([$fr[] | "── review (\(.state)) by \(.who) at \(.at)\n\(.body)"] +
   [$fc[] | "── inline comment by \(.who) on \(.path):\(.line // "?") at \(.at)\n\(.body)"])
  | join("\n\n")')"
assert_eq "the body carries the substantive COMMENTED review, not just the blocking one" \
  "1" "$(grep -c 'gitignore gap' <<<"$body")"
assert_eq "the body carries the blocking review too" \
  "1" "$(grep -c 'Refer to' <<<"$body")"

# --- Back-pressure restriction (requirement 2.2a) ---
#
# The narrowing agent-cycle.sh applies when back-pressure trips and review
# feedback is waiting. Tested here rather than live because reaching the branch
# needs max_open_agent_prs exceeded *and* an unanswered review round at the same
# moment — a state that exists only when the pipeline is genuinely stuck, which
# is exactly when nobody wants to be finding out whether this works.
#
# The narrowing is what stops the deadlock: with every agent PR sent back for
# changes, the plain check would stand the cycle down before the Co-Ordinator
# ran, so the one source that could clear them is never reached and the pipeline
# dies silently. Restricting the source list rather than adding a mode flag
# means the Co-Ordinator cannot select anything else — it is told the runtime
# input's `sources` are authoritative, and a source it cannot see is a source it
# cannot pick.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "tech-debt", "issues"], "review_feedback": [{"ref": "pr-57-review-2"}]},
  {"slug": "o/two", "sources": ["security", "review-feedback", "issues"], "review_feedback": []}
]'
# Narrowing is to the three *finishing* sources (review-feedback, merge-conflicts
# and abandoned-drafts); this fixture only carries review-feedback, so the result
# is review-feedback alone. Kept in step with agent-cycle.sh's filter (requirement
# 2.2a); the merge-conflicts and abandoned-drafts sides are exercised in their own
# tests.
restrict() { jq -c '[.[] | .sources = (.sources | map(select(. == "review-feedback" or . == "merge-conflicts" or . == "abandoned-drafts")))]' <<<"$ordered"; }

assert_eq "restriction leaves only review-feedback selectable" \
  '["review-feedback"] ["review-feedback"]' \
  "$(restrict | jq -r '[.[] | (.sources | tojson)] | join(" ")')"
assert_eq "security is narrowed away too — a full gate means finish, don't start" \
  "0" "$(restrict | jq '[.[].sources[] | select(. == "security")] | length')"
assert_eq "the repos themselves survive the narrowing" \
  "2" "$(restrict | jq 'length')"
assert_eq "the waiting candidates are still attached for the Co-Ordinator to read" \
  "1" "$(restrict | jq '[.[].review_feedback[]?] | length')"

# The count that decides stand-down vs restrict.
assert_eq "candidates across all repos are counted, not just the first" \
  "1" "$(jq '[.[].review_feedback[]?] | length' <<<"$ordered")"
assert_eq "with nothing waiting, the count is 0 and the cycle stands down as before" \
  "0" "$(jq '[.[] | .review_feedback = []] | [.[].review_feedback[]?] | length' <<<"$ordered")"

# --- The gatherer itself fails safe ---

assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$("$SCRIPT_DIR/scripts/gather-review-feedback.sh" "Poetic-Poems/does-not-exist" autonomous-agent 'agent/' 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
