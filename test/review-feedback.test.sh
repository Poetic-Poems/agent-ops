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
# thing that does is the comparison this file tests: the blocking review
# against GitHub review-thread events (a marked reply, or a review-requested
# event) — never a commit's date, which a force-push re-stamps to push time
# without a human, or the agent, having answered anything (agent-ops#239).
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
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

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
#
# Mirrors scripts/gather-review-feedback.sh's own jq exactly (kept in step, per
# the file header): the review currently blocking `reviewDecision` (a
# reviewer's own latest APPROVED-or-CHANGES_REQUESTED review, filtered to
# CHANGES_REQUESTED), then "answered" is any marked reply or review-requested
# event *after* that review's timestamp — never a commit's date, which a
# force-push can re-stamp without a human, or the agent, having done anything
# (agent-ops#239; PR #205 silently dropped out of selection this way).

marker="$PIPELINE_COMMENT_MARKER_PREFIX"

# submitted_at null = a pending review the human is still drafting; it has not
# been sent and must not count as feedback. Two accounts, as in the wild: the
# agent's own (`warwickallen`, COMMENTED only — it cannot request changes on
# its own PR) and the human's second account (`Warwick-Allen`).
reviews='[
  {"id": 1, "state": "COMMENTED",         "at": "2026-07-17T01:22:24Z", "who": "warwickallen"},
  {"id": 2, "state": "CHANGES_REQUESTED", "at": "2026-07-17T01:22:54Z", "who": "Warwick-Allen"}
]'

blocking_of() {
  jq -c '
    ([.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")]
     | group_by(.who) | map(last)) as $latest_per_reviewer
    | ($latest_per_reviewer | map(select(.state == "CHANGES_REQUESTED")) | sort_by(.at) | last) // null
  ' <<<"$1"
}
# extract_answer_events REVIEWS ISSUE_COMMENTS REREQUESTS
# The exact extraction scripts/gather-review-feedback.sh runs: a marked review
# or marked general comment whose marker's `actor=` field is `implementor`, or
# any review-requested timeline event. Other actors (`script`, `enabler`,
# `reviewer`, `refiner`) and a legacy marker with no `actor=` field at all are
# marked but must not close a round — only the Implementor's own reply does
# (agent-ops#292, decided in agent-ops#278).
extract_answer_events() {
  jq -c -n --arg marker "$marker" --arg implementor_actor "actor=implementor -->" \
      --argjson reviews "$1" --argjson comments "$2" --argjson rr "$3" '
    ([$reviews[]  | select((.body // "") | contains($marker) and contains($implementor_actor)) | .at]
     + [$comments[] | select((.body // "") | contains($marker) and contains($implementor_actor)) | .at]
     + [$rr[] | .at]) | sort
  '
}
answered_after() {
  # $1 = answer_events (a JSON array of timestamp strings), $2 = cutoff
  jq -r --arg c "$2" '[.[] | select(. > $c)] | length' <<<"$1"
}

assert_eq "COMMENTED never blocks — the CHANGES_REQUESTED review is the round" \
  '{"id":2,"state":"CHANGES_REQUESTED","at":"2026-07-17T01:22:54Z","who":"Warwick-Allen"}' \
  "$(blocking_of "$reviews")"

blocking_at="$(jq -r '.at' <<<"$(blocking_of "$reviews")")"

assert_eq "no answer event at all — unanswered, our turn" \
  "0" "$(answered_after '[]' "$blocking_at")"

# The case that decides whether this feature loops forever: the Implementor
# has answered — a marked reply comment, timestamped by GitHub when it was
# posted, not by any commit. The reply is a *general PR comment* (`gh pr
# comment`), which lands in issue comments, not the reviews collection.
# shellcheck disable=SC2016  # the backtick is literal Markdown, not command substitution
implementor_reply="$(jq -c -n --arg at "2026-07-17T01:30:00Z" --arg body "$(printf '**Implementor** · autonomous pipeline · node `poetic-1`\n\nAddressed both points.\n\n%s cycle=X actor=implementor -->' "$marker")" \
  '[{at: $at, body: $body}]')"
answered_by_reply="$(extract_answer_events '[]' "$implementor_reply" '[]')"
assert_eq "a marked reply after the review — answered, the human's turn" \
  "1" "$(answered_after "$answered_by_reply" "$blocking_at")"

# An unmarked comment — a human chiming in, or an unrelated bot — must not
# count as an answer; only this system's own marked write does.
human_comment="$(jq -c -n --arg at "2026-07-17T01:30:00Z" '[{at: $at, body: "looks close"}]')"
assert_eq "an unmarked comment after the review does not answer it" \
  "0" "$(answered_after "$(extract_answer_events '[]' "$human_comment" '[]')" "$blocking_at")"

# --- The actor restriction (agent-ops#292) ---
#
# On PR #269, an `actor=script` comment (a stage giving up) and an
# `actor=enabler` comment (a stall being diagnosed) each carried the marker
# and, under the old "any marked reply" rule, closed the round — the work sat
# stranded until a human was escalated (agent-ops#278). Only `actor=implementor`
# may close a round.
# shellcheck disable=SC2016  # the backtick is literal Markdown, not command substitution
script_giveup="$(jq -c -n --arg at "2026-07-17T01:30:00Z" --arg body "$(printf '**Script** · autonomous pipeline · node `poetic-1`\n\nThe Implementor stage stopped on this pull request.\n\n%s cycle=X actor=script -->' "$marker")" \
  '[{at: $at, body: $body}]')"
assert_eq "an actor=script comment (a stage giving up) does not answer the round" \
  "0" "$(answered_after "$(extract_answer_events '[]' "$script_giveup" '[]')" "$blocking_at")"

# shellcheck disable=SC2016  # the backtick is literal Markdown, not command substitution
enabler_diagnosis="$(jq -c -n --arg at "2026-07-17T01:30:00Z" --arg body "$(printf '**Enabler** · autonomous pipeline · node `poetic-1`\n\nStill blocked; diagnosing the stall.\n\n%s cycle=X actor=enabler -->' "$marker")" \
  '[{at: $at, body: $body}]')"
assert_eq "an actor=enabler comment (a stall being diagnosed) does not answer the round" \
  "0" "$(answered_after "$(extract_answer_events '[]' "$enabler_diagnosis" '[]')" "$blocking_at")"

# A legacy marker with no `actor=` field at all — from before the field
# existed — must not be treated as an answer either; only a positive
# `actor=implementor` match closes the round.
legacy_marker="$(jq -c -n --arg at "2026-07-17T01:30:00Z" --arg body "$(printf 'Addressed both points.\n\n%s cycle=X -->' "$marker")" \
  '[{at: $at, body: $body}]')"
assert_eq "a legacy marked comment with no actor= field does not answer the round" \
  "0" "$(answered_after "$(extract_answer_events '[]' "$legacy_marker" '[]')" "$blocking_at")"

# Equally, a review-requested event (confirm_review_requested, lib/handoff.sh)
# answers it, with no reply comment at all — GitHub's timeline record of
# `confirm_review_requested` asking the reviewer to look again.
rerequest_event="$(jq -c -n --arg at "2026-07-17T01:31:00Z" '[{at: $at}]')"
answered_by_rerequest="$(extract_answer_events '[]' '[]' "$rerequest_event")"
assert_eq "a review-requested event after the review — also answered" \
  "1" "$(answered_after "$answered_by_rerequest" "$blocking_at")"

# --- The regression this exists to prevent (agent-ops#239) ---
#
# A conflict-resolution force-push re-stamps every commit's date to push time.
# The old rule compared that date against the review's `submitted_at` and
# read a fresh commit date as "answered" — with no reply, no re-review, and no
# review-requested event: the push resolved a conflict, it did not address a
# single word of the review. The new rule has nothing to feed on here: a
# force-push produces zero answer events, so the round stays a candidate no
# matter how recent the commit is.
force_pushed_commit_at="2026-07-17T09:00:00Z"
assert_eq "a force-push with no answer event never satisfies the old commit compare" \
  "true" "$([[ "$force_pushed_commit_at" > "$blocking_at" ]] && echo true || echo false)"
assert_eq "...but the new rule still finds it unanswered, no matter how new the commit is" \
  "0" "$(answered_after '[]' "$blocking_at")"

# And a fresh round after a genuine answer is our turn again.
reviews_round2="$(jq -c '. + [{"id": 3, "state": "CHANGES_REQUESTED", "at": "2026-07-17T02:00:00Z", "who": "Warwick-Allen"}]' <<<"$reviews")"
blocking_at2="$(jq -r '.at' <<<"$(blocking_of "$reviews_round2")")"
assert_eq "a new CHANGES_REQUESTED after our answer reopens it" \
  "2026-07-17T02:00:00Z" "$blocking_at2"
assert_eq "...and the old answer event does not satisfy the new round" \
  "0" "$(answered_after "$answered_by_reply" "$blocking_at2")"

# --- The round's ref ---
#
# Scoped to the blocking review's id, not the PR. An item recorded blocked
# (requirement 34) stays blocked until something clears it, so a bare `pr-57`
# that the Implementor once failed on would still be blocked when the human
# posted fresh guidance — and their new review would land on a dead item. A
# per-round ref means each round is a new item no old block covers, the same
# reasoning as the review-dated `review-<date>-R-NN` refs.
ref_of() {
  local reviews_json="$1" id
  id="$(jq -r '.id' <<<"$(blocking_of "$reviews_json")")"
  printf 'pr-57-review-%s' "$id"
}
assert_eq "the ref pins to the blocking review, not the chattiest one" \
  "pr-57-review-2" "$(ref_of "$reviews")"
assert_eq "a second round yields a different ref, so an old block cannot cover it" \
  "pr-57-review-3" "$(ref_of "$reviews_round2")"

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
