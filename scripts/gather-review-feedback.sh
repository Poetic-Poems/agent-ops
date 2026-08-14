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
#     "pr_number": 57,
#     "url": "https://github.com/…/pull/57",
#     "pr_url": "https://github.com/…/pull/57",
#     "title": "fix(blogger-auth): …",
#     "branch": "agent/td26071701-…",
#     "item": "TD26071701",               // the originating item, if inferable
#     "head_sha": "eea6184…",
#     "reviewed_at": "2026-07-17T01:22:54Z",
#     "body": "…every review body and inline comment in this round, verbatim…"
#   }
#
# `pr_number`/`pr_url` duplicate `number`/`url` (the other two finishing
# sources' candidate shapes carry both pairs — see gather-merge-conflicts.sh
# and gather-abandoned-drafts.sh) so that a reader needing "which PR does this
# candidate target?" has one field name that means the same thing in all three
# arrays: the PR-level claim agent-cycle.sh takes alongside the item claim
# (issue #238) reads `pr_number` from here, and `prompts/implementor.md`'s
# review-feedback work order already documented carrying `pr_url` before this
# field existed to satisfy it.
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# Three reasons, and the third is the one that matters:
#   1. Cost, as with gather-findings.sh (requirement 3a): assembling a review
#      round means several calls per PR — reviews, inline comments, general
#      comments, the timeline — and the bodies are long. Paying a model to
#      paginate that is waste.
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
#   - **no review-thread event answers the blocking review.**
#
# That last clause is load-bearing, not a refinement. The agent raises PRs as
# the authenticated user, and GitHub forbids approving or dismissing a review on
# your own PR — so the agent *cannot* clear CHANGES_REQUESTED, and the decision
# stays set even after the fix is pushed. Without the clause, every PR the agent
# fixed would remain a candidate forever: selected, re-fixed, re-selected, on the
# hour, until a human happened to look. The failure would be invisible, because
# each cycle would look like a productive one.
#
# ## Why events, not commit timestamps
#
# This used to compare the blocking review's `submitted_at` against the head
# commit's `committedDate`: newer review means our turn, newer commit means the
# human's. That comparison has a forgeable input. A conflict-resolution
# force-push re-stamps every commit's date to push time, and on PR #205 that
# silently satisfied "commit newer than review" — the branch had a fresh commit
# date from a rebase that never touched the review's actual findings, so the
# round read as answered and the PR dropped out of every selection query while
# the human's CHANGES_REQUESTED sat unanswered. The Enabler caught it hours
# later, by hand.
#
# The fix is to derive "answered" from signals GitHub itself timestamps at the
# moment they happen, none of which a rebase can produce:
#   - a **marked reply from the Implementor** — a review or a general PR
#     comment carrying `lib/pipeline-marker.sh`'s invisible marker with
#     `actor=implementor`, i.e. this system's own answer to the round
#     (`prompts/implementor.md`'s "Answer the review before you finish").
#     `gh pr comment` and `gh pr review --comment` file the same words under
#     different collections, so both are checked, the same way
#     gather-abandoned-drafts.sh already does for its own staleness clock.
#     The marker also carries `actor=script`, `actor=enabler`, `actor=reviewer`
#     or `actor=refiner` for other kinds of pipeline write, and two of those
#     are by definition not answers: `actor=script` records a stage giving up,
#     and `actor=enabler` a stall being diagnosed. On PR #269 exactly those two
#     comments closed the round under the old "any marked reply" rule and the
#     work sat stranded until a human was escalated (agent-ops#278). A legacy
#     marked comment with no `actor=` field does not answer the round either,
#     for the same reason.
#   - a **review-requested event** — the timeline record of
#     `confirm_review_requested` (`lib/handoff.sh`) asking the blocking
#     reviewer to look again, which GitHub stamps at request time regardless of
#     what any commit says.
# A round is answered iff either kind of event happened after the blocking
# review was submitted. Nothing about a force-push can produce either: it
# moves no comment, leaves no review body, and asks no one to re-review.
#
# The extraction and the answered/unanswered decision are
# `lib/handoff.sh`'s `handoff_answer_events` / `handoff_round_answered`
# (requirement 34a): this script passes all three signals — reviews, PR
# comments and the timeline's `review_requested` events — while
# scripts/sweep-human-visibility.sh (requirement 38c) calls the same
# functions with the timeline omitted, so its own re-request cannot read
# back next cycle as an answer to itself (tech-debt/TD-PPagop-26080804.md).
#
# ## Gather every review in the round, not just the blocking one
#
# The substance and the formal signal routinely live in different reviews by
# different accounts, because GitHub will not let the PR's author request
# changes on it. On this project the agent raises the PR as `warwickallen`, that
# account can therefore only leave a COMMENTED review, and the human's second
# account posts the CHANGES_REQUESTED — whose body, in the wild, reads in full:
# "Refer to https://github.com/…#pullrequestreview-4718691960". Gathering only
# the blocking review would hand the Implementor the word "Refer to" and nothing
# to act on. So the body below is every review and inline comment submitted
# since the round began, whoever wrote it.
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
# ## Every `gh api --paginate` read streams; none aggregates inside `--jq`
#
# `--paginate` re-runs the `--jq` filter once per page and prints each page's
# result as its own JSON document — it does not concatenate pages before
# filtering. A filter that builds an aggregate itself (`[.[] | …]`) is
# therefore computed *per page* and disagrees with itself past the endpoint's
# default page size (thirty, for every endpoint this script reads): two or
# more array literals land in the variable instead of one, `jq -e 'type ==
# "array"'` cannot catch it (jq evaluates the filter once per input document
# and exits on the last one's truth, so the guard only establishes "every
# document is an array", never "this is one array"), and `--argjson`
# downstream fails to parse the multi-document value.
#
# So every read below — reviews, issue comments, the timeline, inline PR
# comments — has its `--jq` filter emit one object per matching item, with no
# enclosing `[...]`, and the four resulting streams are slurped into a single
# array afterwards with `jq -s -c '.'`. This is the rule the whole script
# follows, not a per-call detail: the same pattern `_handoff_blocking_
# reviewers` (lib/handoff.sh) and `_sweep_round_answered`
# (scripts/sweep-human-visibility.sh) already use, for the same reason.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo where nothing
# is under review contributes `[]`; an API that will not answer contributes `[]`
# too, and the cycle simply does not see this source (see gather-source-state.sh
# for why the *fingerprint* must not be so relaxed).
#
# Environment: REVIEW_FEEDBACK_GH overrides `gh` (tests stub it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"
GH="${REVIEW_FEEDBACK_GH:-gh}"

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-review-feedback.sh <owner/repo> [pr-label] [branch-prefix]" >&2
  exit 64
fi

# The open, agent-raised, changes-requested PRs, with their head commit so the
# candidate can carry `head_sha`.
#
# `headRefOid` is the head commit's sha directly. This used to ask for the
# whole `commits` collection and read `.commits[-1].oid` off the end of it,
# which cost 30 GraphQL points per call against a repository with three open
# pull requests — `gh` requests `commits(last: 100)` for every one of the
# `--limit` slots and GitHub charges for the nodes asked for, not the ones
# returned. Two gatherers and two nodes paying that on a 15-minute cadence was
# most of the 5,000-point hourly budget, and on 2026-08-12 it ran out
# fleet-wide. The same listing with `headRefOid` in place of `commits` measures
# 1 point. (The comment this replaces said `gh` had no `headRefOid` field; that
# has not been true for some releases.)
#
# stderr is shown, not swallowed. A `gh` that rejects a field name otherwise
# degrades to an empty array indistinguishable from "nothing is under review",
# and the source silently never fires. That is the `[]`-on-error trap in the
# Gotchas table, and it cost a debugging round here before this line existed.
# Heads may be `agent/…` or — for tech-debt items, whose claim branch is the
# human protocol's own `td/<ID>` — `td/…`; the label filter above is the
# primary "ours" signal either way.
all_prs="$("$GH" pr list -R "$slug" --state open --label "$pr_label" \
        --limit "$GITHUB_PR_LIST_LIMIT" \
        --json number,title,headRefName,headRefOid,isDraft,reviewDecision,url,body \
        || true)"
if [[ -z "$all_prs" ]] || ! jq -e 'type == "array"' <<<"$all_prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

# A listing at the cap may be missing entries (lib/github-limit.sh). Here that
# can only lose a candidate — a pull request whose review round simply is not
# offered this cycle — so it is said out loud and the run continues, unlike the
# back-pressure gate, where the same truncation would let work through.
if github_pr_list_truncated "$(jq 'length' <<<"$all_prs")"; then
  echo "gather-review-feedback: $slug: the pull-request listing came back at its ${GITHUB_PR_LIST_LIMIT}-item cap; a review round beyond it is not offered this cycle" >&2
fi

prs="$(jq -c "[.[] | select(.isDraft | not)
                   | select(.reviewDecision == \"CHANGES_REQUESTED\")
                   | select((.headRefName | startswith(\"$branch_prefix\"))
                            or (.headRefName | startswith(\"td/\")))]" <<<"$all_prs" 2>/dev/null || true)"
if [[ -z "$prs" ]] || ! jq -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

out='[]'
while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue
  number="$(jq -r '.number' <<<"$pr")"
  head_sha="$(jq -r '.headRefOid // ""' <<<"$pr")"
  [[ -n "$head_sha" ]] || continue

  # Every review, so the round can be assembled and the blocking review found.
  # `submitted_at` is null on a pending review; those are drafts nobody has
  # sent and must not count as feedback. One object per line — see "Every
  # `gh api --paginate` read streams" above — slurped into one array below.
  reviews="$("$GH" api "repos/$slug/pulls/$number/reviews" --paginate \
              --jq '.[] | select(.submitted_at != null)
                        | {id, state, at: .submitted_at, who: .user.login, body: (.body // "")}' \
              2>/dev/null || true)"
  reviews="$(jq -s -c '.' <<<"$reviews" 2>/dev/null)"
  if [[ -z "$reviews" ]] || ! jq -e 'type == "array"' <<<"$reviews" >/dev/null 2>&1; then
    continue
  fi

  # The review currently blocking `reviewDecision`: the most recent
  # CHANGES_REQUESTED review among each reviewer's own most recent
  # APPROVED-or-CHANGES_REQUESTED review — the same "standing position per
  # reviewer" computation as lib/handoff.sh's `_handoff_blocking_reviewers`,
  # minus — deliberately — its bot filter (requirement 34a). Candidate
  # selection keys off GitHub's `reviewDecision`, which counts bot reviews,
  # and the marked reply this round produces is the only event that can ever
  # answer a bot's CHANGES_REQUESTED: the pipeline cannot dismiss a review on
  # its own PR, and handoff never re-requests a bot. Bots are excluded from
  # re-request, not from feedback — their findings still reach the
  # Implementor; nobody is ever pinged over them. A COMMENTED review never
  # changes anyone's standing position, so it is filtered out *before*
  # picking each reviewer's latest, not after — a reviewer who requested
  # changes and then merely commented is still blocking.
  blocking="$(jq -c '
    ([.[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")]
     | group_by(.who) | map(last)) as $latest_per_reviewer
    | ($latest_per_reviewer | map(select(.state == "CHANGES_REQUESTED")) | sort_by(.at) | last) // null
  ' <<<"$reviews")"
  [[ "$blocking" != "null" ]] || continue
  blocking_at="$(jq -r '.at' <<<"$blocking")"

  # General PR conversation comments, where the Implementor's own reply lands
  # (`gh pr comment`) carrying `lib/pipeline-marker.sh`'s invisible marker.
  # Streamed one object per line, slurped below (see the header note).
  issue_comments="$("$GH" api "repos/$slug/issues/$number/comments" --paginate \
                      --jq '.[] | {at: .created_at, body: (.body // "")}' \
                      2>/dev/null || true)"
  issue_comments="$(jq -s -c '.' <<<"$issue_comments" 2>/dev/null)" || issue_comments='[]'
  jq -e 'type == "array"' <<<"$issue_comments" >/dev/null 2>&1 || issue_comments='[]'

  # Review-requested timeline events: GitHub's own record of
  # `confirm_review_requested` (lib/handoff.sh) asking a reviewer to look
  # again, stamped by GitHub at request time — nothing a rebase can produce.
  # Streamed one object per line, slurped below (see the header note).
  rerequests="$("$GH" api "repos/$slug/issues/$number/timeline" --paginate \
                 --jq '.[] | select(.event == "review_requested" and .created_at != null)
                           | {at: .created_at}' \
                 2>/dev/null || true)"
  rerequests="$(jq -s -c '.' <<<"$rerequests" 2>/dev/null)" || rerequests='[]'
  jq -e 'type == "array"' <<<"$rerequests" >/dev/null 2>&1 || rerequests='[]'

  # Every answer event in the PR's life, oldest first: a marked review or
  # general comment whose marker's `actor=` field is `implementor`, or a
  # review-requested event (`handoff_answer_events`, lib/handoff.sh —
  # requirement 34a's one definition). Two different timestamps are read off
  # this one list below — whether the *blocking* round has been answered,
  # and where the *previous* round left off.
  #
  # `actor=implementor -->` is the exact tail `pipeline_comment_marker`
  # (lib/pipeline-marker.sh) prints for that actor — the actor token is
  # always the marker's last field, immediately followed by ` -->` — so a
  # substring match is precise with no regex needed. Any other actor
  # (`script`, `enabler`, `reviewer`, `refiner`) or a legacy marker with no
  # `actor=` field at all does not match and must not close the round.
  answer_events="$(handoff_answer_events "$reviews" "$issue_comments" "$rerequests")"

  # Answered iff an answer event happened after the blocking review was
  # submitted (`handoff_round_answered`, lib/handoff.sh). This is the whole
  # fix: the old comparison used the head commit's `committedDate`, which a
  # force-push re-stamps to push time with no review of its own having
  # happened; these events are stamped by GitHub itself at the moment this
  # system (or a human) actually acted. `reviews` and `issue_comments` are
  # already-validated arrays by this point (checked above); `rerequests` was
  # defaulted to `[]` on a bad response, so this never reads `unknown` here.
  [[ "$(handoff_round_answered "$blocking_at" "$reviews" "$issue_comments" "$rerequests")" == "unanswered" ]] || continue

  # Where the previous round's answer left off — the start of the round now
  # open — so the body carries everything since, including a COMMENTED review
  # submitted moments before the blocking one (the "Refer to" case above), not
  # just entries after the blocking review's own timestamp.
  round_start="$(jq -r --arg c "$blocking_at" \
    '[.[] | select(. < $c)] | if length == 0 then "" else last end' <<<"$answer_events")"

  fresh="$(jq -c --arg c "$round_start" '[.[] | select(.at > $c)] | sort_by(.at)' <<<"$reviews")"
  [[ "$(jq 'length' <<<"$fresh")" != "0" ]] || continue

  reviewed_at="$(jq -r '.[-1].at' <<<"$fresh")"
  # The ref is pinned to the round's *blocking* review, so the item is stable
  # across cycles while the round is open, and new the moment the human opens
  # a fresh round.
  review_id="$(jq -r '.id' <<<"$blocking")"

  # Inline comments, which carry the file-and-line specifics that a review body
  # often only gestures at. Restricted to this round for the same reason.
  # Streamed one object per line, slurped below (see the header note).
  comments="$("$GH" api "repos/$slug/pulls/$number/comments" --paginate \
               --jq '.[] | {at: .created_at, who: .user.login,
                            path: .path, line: (.line // .original_line),
                            body: (.body // "")}' 2>/dev/null || true)"
  comments="$(jq -s -c '.' <<<"$comments" 2>/dev/null)" || comments='[]'
  jq -e 'type == "array"' <<<"$comments" >/dev/null 2>&1 || comments='[]'
  fresh_comments="$(jq -c --arg c "$round_start" '[.[] | select(.at > $c)] | sort_by(.at)' <<<"$comments")"

  # The originating item, so the Implementor can find the tech-debt entry or
  # issue this PR came from. Best-effort: a ref in the branch name or PR body.
  # Absence is normal and must not disqualify the candidate — the review text is
  # the brief, not the register entry.
  item="$(jq -r '.body // ""' <<<"$pr" \
          | grep -oiE '\b(TD[0-9]{8}|dependabot-alert-[0-9]+|code-scanning-alert-[0-9]+|review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-?[0-9]+)\b' \
          | head -n1 || true)"

  # $fresh/$fresh_comments are every fresh review and inline comment on the
  # PR, verbatim — genuinely unbounded, not merely growing (requirement 4g,
  # TD-PPagop-26081406). Delivered on stdin, bound positionally with `input
  # as $name` in the order printed.
  #
  # The result stays JSON-encoded (no `-r`) rather than becoming a raw string,
  # because the only consumer is the candidate build below and it must receive
  # it on stdin too: this assembly is the concatenation of the very arrays
  # just taken out of argv, so an `--arg body` there would put every one of
  # those bytes straight back into a single argv element and leave the
  # MAX_ARG_STRLEN threshold exactly where it was. An empty result — the
  # assembly itself having failed — becomes the empty JSON string, so a
  # candidate with no readable review text is still emitted, as it was before
  # requirement 4g reached this site, rather than being dropped.
  body_json="$(jq -cn 'input as $fr | input as $fc |
    ([$fr[] | "── review (\(.state)) by \(.who) at \(.at)\n\(.body)"] +
     [$fc[] | "── inline comment by \(.who) on \(.path):\(.line // "?") at \(.at)\n\(.body)"])
    | join("\n\n")' <<<"$fresh"$'\n'"$fresh_comments")"
  [[ -n "$body_json" ]] || body_json='""'

  # $pr is the whole pull-request object, including its body, and $body_json
  # the assembled review text — both unbounded past this call (requirement 4g,
  # TD-PPagop-26081406). Delivered on stdin, bound positionally with `input as
  # $name` in the order printed.
  cand="$(jq -nc \
    --arg ref "pr-${number}-review-${review_id}" \
    --arg item "$item" \
    --arg head_sha "$head_sha" \
    --arg reviewed_at "$reviewed_at" \
    'input as $pr | input as $body | {source: "review-feedback",
      ref: $ref,
      number: $pr.number,
      pr_number: $pr.number,
      url: $pr.url,
      pr_url: $pr.url,
      title: $pr.title,
      branch: $pr.headRefName,
      item: (if $item == "" then null else $item end),
      head_sha: $head_sha,
      reviewed_at: $reviewed_at,
      body: $body}' <<<"$pr"$'\n'"$body_json")" || {
    echo "gather-review-feedback: $slug pr-${number}-review-${review_id}: candidate assembly failed; skipped" >&2
    continue
  }
  # $cand and the accumulator both arrive on stdin, one document per line,
  # bound positionally with `input as $name` in the order printed
  # (requirement 4g, TD-PPagop-26081406) — never in argv: a single candidate
  # past MAX_ARG_STRLEN must not degrade this repo's whole review_feedback
  # array to `[]`. Fails open, and loudly: `$out` inside the substitution is
  # still the pre-assignment value, so a failed append keeps every candidate
  # already collected and only drops this one.
  out="$(jq -nc 'input as $arr | input as $c | $arr + [$c]' <<<"$out"$'\n'"$cand" || {
    echo "gather-review-feedback: $slug pr-${number}-review-${review_id}: array assembly failed; candidate dropped" >&2
    printf '%s' "$out"
  })"
done < <(jq -c '.[]' <<<"$prs" 2>/dev/null || true)

# Oldest review first: the PR that has been waiting on us longest goes first.
jq -c 'sort_by(.reviewed_at)' <<<"$out"
