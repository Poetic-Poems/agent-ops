#!/usr/bin/env bash
#
# gather-review-feedback.sh — pre-fetch a repo's pull requests that are waiting
# on the agent to address a human's review (requirement 3c).
#
# Given a repo slug, print a JSON array of review-feedback candidates: open,
# non-draft PRs raised by this system whose latest review round asked for
# changes that no commit has answered yet. Each candidate carries the review
# prose verbatim, so the Implementor can act on it without re-querying anything.
#
# Usage: gather-review-feedback.sh <owner/repo> <pr-label> <branch-prefix>
#
# Candidate shape:
#   {
#     "source": "review-feedback",
#     "ref": "pr-57-review-4718691960",   // stable, and scoped to THIS round
#     "number": 57,
#     "url": "https://github.com/…/pull/57",
#     "title": "fix(blogger-auth): …",
#     "branch": "agent/td26071701-…",
#     "item": "TD26071701",               // the originating item, if inferable
#     "head_sha": "eea6184…",
#     "reviewed_at": "2026-07-17T01:22:54Z",
#     "last_commit_at": "2026-07-17T01:07:22Z",
#     "body": "…every review body and inline comment in this round, verbatim…"
#   }
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# Three reasons, and the third is the one that matters:
#   1. Cost, as with gather-findings.sh (requirement 3a): assembling a review
#      round means one call per PR for reviews and another for inline comments,
#      and the bodies are long. Paying a model to paginate that is waste.
#   2. The prose must reach the Implementor *verbatim*. A model summarising a
#      review before handing it on is a lossy telephone game about the exact
#      changes a human asked for.
#   3. The candidate rule below has to exist in the fingerprint (requirement 3b)
#      regardless, and requirement 34a says a rule that two components compute
#      gets one definition. This script is it.
#
# ## The candidate rule
#
# A PR is a candidate iff all of:
#   - it is open and not a draft (a draft is the Implementor's own claim marker,
#     not something a human has finished reviewing);
#   - it carries <pr-label> and its head branch starts with <branch-prefix> —
#     i.e. this system raised it. The Human Gate is explicit that branches
#     outside branch_prefix belong to humans, and an agent force-pushing a
#     colleague's PR because they asked for changes would be a memorable way to
#     learn that;
#   - `reviewDecision` is CHANGES_REQUESTED;
#   - **the latest review is newer than the head commit.**
#
# That last clause is load-bearing, not a refinement. The agent raises PRs as
# the authenticated user, and GitHub forbids approving or dismissing a review on
# your own PR — so the agent *cannot* clear CHANGES_REQUESTED, and the decision
# stays set even after the fix is pushed. Without the clause, every PR the agent
# fixed would remain a candidate forever: selected, re-fixed, re-selected, on the
# hour, until a human happened to look. The failure would be invisible, because
# each cycle would look like a productive one.
#
# Comparing timestamps answers "whose turn is it?": a review newer than the last
# commit means the agent hasn't responded; a commit newer than the review means
# it has, and the ball is with the human. This is the same shape as requirement
# 15's "a later green run supersedes older failures".
#
# ## Why the ref is scoped to the review round
#
# `pr-<n>-review-<review-id>`, not `pr-<n>`. An item that gets recorded blocked
# (requirement 34) stays blocked until something clears it — so a bare `pr-57`
# that the Implementor once failed on would still be blocked when the human
# posted fresh guidance, and their new review would land on a dead item. Scoping
# the ref to the review id means each new round is a new item that no old block
# covers. Same reasoning as the review-dated `review-<date>-R-NN` refs: these
# expire by irrelevance, which is the only expiry an unattended system performs.
#
# ## Every review in the round, not just the blocking one
#
# The substance and the formal signal routinely live in different reviews by
# different accounts, because GitHub will not let the PR's author request
# changes on it. On this project the agent raises the PR as `warwickallen`, that
# account can therefore only leave a COMMENTED review, and the human's second
# account posts the CHANGES_REQUESTED — whose body, in the wild, reads in full:
# "Refer to https://github.com/…#pullrequestreview-4718691960". Gathering only
# the blocking review would hand the Implementor the word "Refer to" and nothing
# to act on. So the body below is every review and inline comment submitted
# after the head commit, whoever wrote it.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo where nothing
# is under review contributes `[]`; an API that will not answer contributes `[]`
# too, and the cycle simply does not see this source (see gather-source-state.sh
# for why the *fingerprint* must not be so relaxed).

set -uo pipefail

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-review-feedback.sh <owner/repo> [pr-label] [branch-prefix]" >&2
  exit 64
fi

# The open, agent-raised, changes-requested PRs, with their commits so the
# head's SHA and committed date arrive in the same call as everything else.
#
# stderr is shown, not swallowed. A `gh` that rejects a field name — as it did
# for `headRefOid`, which this version of `gh` does not have — otherwise
# degrades to an empty array indistinguishable from "nothing is under review",
# and the source silently never fires. That is the `[]`-on-error trap in the
# Gotchas table, and it cost a debugging round here before this line existed.
prs="$(gh pr list -R "$slug" --state open --label "$pr_label" \
        --json number,title,headRefName,commits,isDraft,reviewDecision,url,body \
        --jq "[.[] | select(.isDraft | not)
                   | select(.reviewDecision == \"CHANGES_REQUESTED\")
                   | select(.headRefName | startswith(\"$branch_prefix\"))]" \
        || true)"
if [[ -z "$prs" ]] || ! jq -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

out='[]'
while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue
  number="$(jq -r '.number' <<<"$pr")"
  head_sha="$(jq -r '.commits[-1].oid // ""' <<<"$pr")"
  # The head commit's date decides whose turn it is (see "The candidate rule").
  last_commit_at="$(jq -r '.commits[-1].committedDate // ""' <<<"$pr")"
  [[ -n "$head_sha" && -n "$last_commit_at" ]] || continue

  # Every review, so the round can be assembled and the newest-review timestamp
  # found. `submitted_at` is null on a pending review; those are drafts nobody
  # has sent and must not count as feedback.
  reviews="$(gh api "repos/$slug/pulls/$number/reviews" --paginate \
              --jq '[.[] | select(.submitted_at != null)
                         | {id, state, at: .submitted_at, who: .user.login, body: (.body // "")}]' \
              2>/dev/null || true)"
  [[ -n "$reviews" ]] && jq -e 'type == "array"' <<<"$reviews" >/dev/null 2>&1 || continue

  # Only reviews *after* the head commit are unaddressed. An older round was
  # answered by the commit that superseded it, and replaying it would ask the
  # Implementor to redo work already in the branch.
  fresh="$(jq -c --arg c "$last_commit_at" '[.[] | select(.at > $c)] | sort_by(.at)' <<<"$reviews")"
  [[ "$(jq 'length' <<<"$fresh")" != "0" ]] || continue

  reviewed_at="$(jq -r '.[-1].at' <<<"$fresh")"
  # The ref is pinned to the round's *blocking* review where there is one, so
  # the item is stable across cycles while the round is open, and new the moment
  # the human opens a fresh round.
  review_id="$(jq -r '[.[] | select(.state == "CHANGES_REQUESTED")] | (last // .[-1]) | .id' <<<"$fresh" 2>/dev/null || true)"
  [[ -n "$review_id" && "$review_id" != "null" ]] || review_id="$(jq -r '.[-1].id' <<<"$fresh")"

  # Inline comments, which carry the file-and-line specifics that a review body
  # often only gestures at. Restricted to this round for the same reason.
  comments="$(gh api "repos/$slug/pulls/$number/comments" --paginate \
               --jq '[.[] | {at: .created_at, who: .user.login,
                             path: .path, line: (.line // .original_line),
                             body: (.body // "")}]' 2>/dev/null || echo '[]')"
  jq -e 'type == "array"' <<<"$comments" >/dev/null 2>&1 || comments='[]'
  fresh_comments="$(jq -c --arg c "$last_commit_at" '[.[] | select(.at > $c)] | sort_by(.at)' <<<"$comments")"

  # The originating item, so the Implementor can find the tech-debt entry or
  # issue this PR came from. Best-effort: a ref in the branch name or PR body.
  # Absence is normal and must not disqualify the candidate — the review text is
  # the brief, not the register entry.
  item="$(jq -r '.body // ""' <<<"$pr" \
          | grep -oiE '\b(TD[0-9]{8}|dependabot-alert-[0-9]+|code-scanning-alert-[0-9]+|review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-?[0-9]+)\b' \
          | head -n1 || true)"

  body="$(jq -r --argjson fr "$fresh" --argjson fc "$fresh_comments" -n '
    ([$fr[] | "── review (\(.state)) by \(.who) at \(.at)\n\(.body)"] +
     [$fc[] | "── inline comment by \(.who) on \(.path):\(.line // "?") at \(.at)\n\(.body)"])
    | join("\n\n")')"

  cand="$(jq -nc \
    --argjson pr "$pr" \
    --arg ref "pr-${number}-review-${review_id}" \
    --arg item "$item" \
    --arg head_sha "$head_sha" \
    --arg reviewed_at "$reviewed_at" \
    --arg last_commit_at "$last_commit_at" \
    --arg body "$body" \
    '{source: "review-feedback",
      ref: $ref,
      number: $pr.number,
      url: $pr.url,
      title: $pr.title,
      branch: $pr.headRefName,
      item: (if $item == "" then null else $item end),
      head_sha: $head_sha,
      reviewed_at: $reviewed_at,
      last_commit_at: $last_commit_at,
      body: $body}')"
  out="$(jq -c --argjson c "$cand" '. + [$c]' <<<"$out")"
done < <(jq -c '.[]' <<<"$prs" 2>/dev/null || true)

# Oldest review first: the PR that has been waiting on us longest goes first.
jq -c 'sort_by(.reviewed_at)' <<<"$out"
