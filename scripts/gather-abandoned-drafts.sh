#!/usr/bin/env bash
#
# gather-abandoned-drafts.sh — pre-fetch a repo's draft pull requests this system
# raised and then abandoned (requirement 3e).
#
# Given a repo slug, print a JSON array of abandoned-draft candidates: open,
# *draft* PRs this system raised whose last **real** activity was at least
# <stale-hours> ago. Each is a nearly-finished piece of work an Implementer stage
# started, claimed with a draft PR, and never carried to `ready` — because the
# stage timed out, hit a usage limit, or died. Finishing one costs less than
# starting fresh and frees the back-pressure slot the stalled PR occupies.
#
# Usage: gather-abandoned-drafts.sh <owner/repo> <pr-label> <branch-prefix> [stale-hours]
#
# Candidate shape:
#   {
#     "source": "abandoned-drafts",
#     "ref": "pr-80-abandoned-1a2b3c4d5e6f", // stable, and scoped to THIS head
#     "number": 80,
#     "pr_number": 80,
#     "url": "https://github.com/…/pull/80",
#     "pr_url": "https://github.com/…/pull/80",
#     "title": "fix(cache): …",
#     "branch": "agent/td26072001-…",
#     "item": "TD26072001",                  // the originating item, if inferable
#     "head_sha": "1a2b3c4d5e6f…",
#     "updated_at": "2026-07-24T03:00:00Z",  // last REAL activity, not GitHub's updatedAt
#     "body": "…the draft PR's own description, the original plan, verbatim…"
#   }
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# Same three reasons as gather-review-feedback.sh (requirement 3c), and the third
# is again the one that matters:
#   1. Cost, as with gather-findings.sh (requirement 3a): the staleness test is a
#      timestamp comparison against the clock, not something worth a model turn.
#   2. The draft PR's own body is the original plan and must reach the Implementer
#      verbatim, not summarised.
#   3. The candidate rule below has to exist in the fingerprint (requirement 3b)
#      regardless, and requirement 34a says a rule two components compute gets one
#      definition. This script is it — and this source is the reason draft
#      staleness is fingerprinted at all (see the note on the clock below).
#
# ## The candidate rule
#
# A PR is a candidate iff all of:
#   - it is open and **is** a draft. A draft is precisely the Implementer's own
#     claim marker (requirement 23): a draft that has been sitting untouched is a
#     claim whose owner never came back. A *ready* PR is finished work waiting on
#     the human and is not ours to touch (that is review-feedback's job).
#   - it carries <pr-label> and its head branch starts with <branch-prefix> (or
#     `td/`, the tech-debt claim branch) — i.e. this system raised it. The Human
#     Gate reserves every other branch for humans; an abandoned draft on a human's
#     branch is the human's to finish, not ours to force-push.
#   - its last **real** activity was at least <stale-hours> ago (TD26072605). A
#     push, a genuine review, or a comment a human (or a peer node acting on a
#     human's behalf) wrote all reset this clock — any of those means somebody is
#     on it. Two things this system itself does must NOT reset it, because when
#     this system touches a PR that is usually evidence the opposite just
#     happened:
#       - a **label edit** — discounted unconditionally. The label set
#         (`complexity:*`, `unvoided`, …) is the pipeline's own bookkeeping
#         surface, never evidence of work in progress; a human who wants a PR
#         looked at sooner has `pr_label` for that.
#       - a **comment this system posted itself** — the Enabler's write, a
#         stage-failure comment, a Reviewer's flag left before handoff. Each is
#         stamped with the invisible marker `lib/pipeline-marker.sh` defines
#         (`PIPELINE_COMMENT_MARKER_PREFIX`), and this script discounts any
#         comment carrying it. A human's comment carries no marker and always
#         counts. Filtering by author cannot make this distinction — every
#         pipeline write happens under the same GitHub account a human also
#         comments as — so the marker, not the author, is the test.
#         The body is what is tested, not the collection it landed in:
#         `gh pr comment` files a write under `comments`, `gh pr review
#         --comment` files the same words under `reviews`, and the Reviewer is
#         told it may use either (`prompts/reviewer.md` step 5), so both are
#         matched against the marker. A human's review — an approval, a
#         change request, an inline note — carries no marker either way.
#     The threshold is `abandoned_draft_after_hours` (4 h), comfortably beyond a
#     whole cycle (120 min Implementer + 60 min Reviewer) so a draft that is
#     merely being worked never qualifies. It was 3 h until #203's interim
#     timeout raises took a worst-case cycle to exactly 180 minutes and left it
#     no margin at all; the two must move together, which is one of the reasons
#     #203 derives such thresholds rather than fixing them. Where the margin
#     does run out, it costs little: candidacy is not selection, and a draft
#     another node is genuinely working is claimed, so a premature candidate
#     loses the claim race (requirement 17a) rather than duplicating the work.
#
# ## Why the clock is "last real activity", not GitHub's `updatedAt`
#
# `updatedAt` moves for anything at all — a push, a comment, a label or a title
# edit — including the pipeline's own housekeeping. Two measurements on
# poetic#92 showed why that is unsafe to trust wholesale: a label edit deferred
# detection by a full `abandoned_draft_after_hours`, and — the sharper case — the
# Enabler's own comment correctly diagnosing the stall reset the clock in the
# same breath it cleared the block, deferring the very recovery it had just
# enabled. So this script computes its own measure instead of reading
# `updatedAt`: the latest of the head commit's `committedDate` and of every
# **non-marker** review's `submittedAt` and comment's `createdAt`. That handles
# both cases at once — a label edit touches none of the three, and a marker
# write is excluded from the other two — without needing to know who authored
# anything.
#
# A marker-carrying comment resets the clock **not at all**, not partially: the
# Enabler's own verdict already lands as an `unblocked`/`still-blocked` event the
# selection rules read directly (requirement 18), so there is no information a
# partial reset here would add.
#
# ## Why staleness must be sampled here, against the clock
#
# This is the one candidate rule in the system that turns on the passage of time
# rather than on an event. Last-real-activity does not change as the hours pass,
# so a draft crossing the threshold moves *nothing* in gather-source-state.sh's
# open-PR digest — the fingerprint (requirement 3b) would sit unchanged across
# exactly the moment work appears, and the no-op short-circuit would skip it
# until the forced recheck. Computing candidacy here, with `date`, and feeding
# the resulting array into the fingerprint verbatim (as agent-cycle.sh does for
# review_feedback) is what makes the transition visible: the array gains an entry
# the cycle the draft goes stale, and that busts the fingerprint. See
# lib/noop-skip.sh.
#
# `gather-source-state.sh`'s own open-PR digest is deliberately unlike this
# script: it keys on GitHub's raw `updated_at` on purpose, to notice *any* change
# on an open PR as a proxy for reads the Co-Ordinator would otherwise perform
# itself (see that script's header). That digest is not this source's candidate
# rule and must keep reading the raw field.
#
# ## Why the ref is scoped to the head SHA
#
# `pr-<n>-abandoned-<head-sha>`, not `pr-<n>-abandoned`. An item recorded blocked
# (requirement 34) stays blocked until something clears it, so a bare
# `pr-<n>-abandoned` that an Implementer once failed on would still be blocked
# after fresh commits landed on the branch — and the new state, which might be
# perfectly finishable, would never be looked at again. Scoping the ref to the
# head SHA means each distinct abandoned state is its own item that no older block
# covers, while a draft abandoned again at the *same* head keeps the same ref and
# stays correctly blocked. Same reasoning as review-feedback's per-round
# `pr-<n>-review-<id>` refs: an unattended system expires items by irrelevance.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with no
# abandoned drafts contributes `[]`; an API that will not answer contributes `[]`
# too (the source simply does not fire this cycle) — but note gather-source-state.sh
# must NOT be so relaxed about the same PRs, for the reason it documents. A PR
# whose real activity cannot be computed (its head commit's date could not be
# read — should never happen, but a malformed API response is not licence to
# guess) is excluded rather than treated as maximally stale: the dangerous
# direction here is stealing live work, not leaving a genuinely stalled draft
# for one more cycle. A PR either of whose nested collections came back at `gh
# pr list`'s 100-item cap is excluded the same way (see the note at the fetch
# below): a capped response may be missing the newest activity, and incomplete
# data is not licence to guess either.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
stale_hours="${4:-3}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-abandoned-drafts.sh <owner/repo> [pr-label] [branch-prefix] [stale-hours]" >&2
  exit 64
fi

# The staleness cutoff, computed once against the clock: a PR whose last real
# activity is older than this has been untouched for at least stale_hours. An
# unparseable threshold is a bug in the caller, not grounds to hand back a wrong
# answer, so fail safe to an empty list rather than treating every draft as
# abandoned.
if ! [[ "$stale_hours" =~ ^[0-9]+$ ]]; then
  printf '[]'
  exit 0
fi
cutoff="$(date -u -d "${stale_hours} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
if [[ -z "$cutoff" ]]; then
  printf '[]'
  exit 0
fi

# Every open, agent-raised draft PR under our branch prefix, with the reviews
# and comments needed to compute last-real-activity ourselves — the raw
# `updatedAt` cannot be trusted as a pre-filter here (a label edit or a marker
# comment can hold it recent while the PR is genuinely stalled), so every
# candidate PR's full activity has to be fetched and judged, not just the ones
# `updatedAt` already flags as stale. stderr is shown, not swallowed: a `gh`
# that rejects a field name otherwise degrades to an empty array
# indistinguishable from "no abandoned drafts", and the source silently never
# fires — the `[]`-on-error trap in the Gotchas table that cost
# gather-review-feedback.sh a debugging round.
# Heads may be `agent/…` or — for tech-debt items, whose claim branch is the
# human protocol's own `td/<ID>` — `td/…`; the label filter is the primary
# "ours" signal either way.
#
# `headRefOid`, not the whole `commits` collection. Asking for `commits` cost
# 31 GraphQL points per call against a repository with three open pull requests
# — `gh` requests `commits(last: 100)` for each of the `--limit` slots and
# GitHub charges for nodes asked for, not nodes returned — and two gatherers on
# two nodes paying it every 15 minutes was most of the 5,000-point hourly
# budget the fleet exhausted on 2026-08-12. The same listing with `headRefOid`
# measures 1 point. The head commit's *date*, which the staleness clock below
# needs and a sha alone does not give, is fetched per candidate from REST
# instead — one core request each, against a budget that has thousands spare.
all_prs="$(gh pr list -R "$slug" --state open --label "$pr_label" \
        --limit "$GITHUB_PR_LIST_LIMIT" \
        --json number,title,headRefName,headRefOid,isDraft,updatedAt,url,body,comments,reviews \
        || true)"
if [[ -z "$all_prs" ]] || ! jq -e 'type == "array"' <<<"$all_prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

# A listing at the cap may be missing entries (lib/github-limit.sh). Here the
# loss is a draft that is simply not offered for recovery this cycle, which is
# the same safe direction as every other exclusion in this file — so it is said
# out loud and the run continues.
if github_pr_list_truncated "$(jq 'length' <<<"$all_prs")"; then
  echo "gather-abandoned-drafts: $slug: the pull-request listing came back at its ${GITHUB_PR_LIST_LIMIT}-item cap; a draft beyond it is not offered this cycle" >&2
fi

prs="$(jq -c "[.[] | select(.isDraft)
                   | select((.headRefName | startswith(\"$branch_prefix\"))
                            or (.headRefName | startswith(\"td/\")))]" <<<"$all_prs" 2>/dev/null || true)"
if [[ -z "$prs" ]] || ! jq -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

# `gh pr list` does not paginate the nested collections this computation reads:
# `reviews` and `comments` each arrive capped at 100 items (`GH_DEBUG=api`
# shows `comments(first: 100)`; only `gh pr view` special-cases comment
# pagination), and `comments` is served oldest-first — so a collection at the
# cap may be missing the *newest* entries. Last-real-activity computed from
# such a response would be an old date wearing a current one's face — exactly
# the misread the header names as the dangerous direction, an actively-discussed
# draft judged abandoned. So each PR is flagged `at_cap` here, and the
# computation below treats a flagged PR's activity as uncomputable: excluded
# this cycle, like the missing-commit case, never judged on data known to be
# incomplete. Said out loud on stderr because the exclusion also defers a PR
# that may be genuinely abandoned — and 100 of anything on one of this system's
# own drafts is an anomaly worth a human's eye anyway (requirement 3e).
#
# `commits` used to be checked here too, because at its cap `.commits[-1]` was
# the hundredth commit rather than the head. `headRefOid` is the head whatever
# the branch's length, so that clause has no counterpart and is not missing.
prs="$(jq -c '[.[] | . + {at_cap: ((((.reviews  // []) | length) >= 100)
                                or (((.comments // []) | length) >= 100))}]' \
        <<<"$prs" 2>/dev/null || true)"
if [[ -z "$prs" ]] || ! jq -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi
capped="$(jq -r '[.[] | select(.at_cap) | "#\(.number)"] | join(" ")' <<<"$prs" 2>/dev/null || true)"
if [[ -n "$capped" ]]; then
  echo "gather-abandoned-drafts: $slug $capped: a nested collection is at gh's 100-item cap, so last real activity cannot be computed; excluded this cycle" >&2
fi

# The head commit's `committedDate`, one REST call per draft still in the
# running. GraphQL's `Commit.committedDate` is REST's `.commit.committer.date`
# — the committer's timestamp, which is what a force-push re-stamps and what
# the clock below has always read; `.commit.author.date` is the other one and
# would be the wrong field.
#
# A PR whose head commit cannot be read gets a null, and the computation below
# drops it exactly as it drops an `at_cap` one. That guard is load-bearing and
# not a formality: without it a failed fetch would leave the PR's activity to
# be decided by its reviews and comments alone, so a draft a human pushed to
# five minutes ago — but never commented on — would read as untouched since its
# last review and be handed to an Implementer to force-push over. Skipped
# entirely for `at_cap` PRs, which are excluded regardless, so a truncated
# response costs no calls.
head_dates='{}'
while IFS= read -r pr_number; do
  [[ -n "$pr_number" ]] || continue
  pr_sha="$(jq -r --argjson n "$pr_number" '.[] | select(.number == $n) | .headRefOid // ""' <<<"$prs")"
  [[ -n "$pr_sha" ]] || continue
  committed_at="$(gh api "repos/$slug/commits/$pr_sha" --jq '.commit.committer.date // empty' 2>/dev/null || true)"
  [[ -n "$committed_at" ]] || continue
  head_dates="$(jq -c --arg k "$pr_number" --arg v "$committed_at" '. + {($k): $v}' <<<"$head_dates")"
done < <(jq -r '.[] | select(.at_cap | not) | .number' <<<"$prs" 2>/dev/null || true)
prs="$(jq -c --argjson dates "$head_dates" \
  '[.[] | . + {head_committed_at: ($dates[(.number | tostring)] // null)}]' <<<"$prs" 2>/dev/null || true)"
if [[ -z "$prs" ]] || ! jq -e 'type == "array"' <<<"$prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi
undated="$(jq -r '[.[] | select((.at_cap | not) and .head_committed_at == null) | "#\(.number)"] | join(" ")' <<<"$prs" 2>/dev/null || true)"
if [[ -n "$undated" ]]; then
  echo "gather-abandoned-drafts: $slug $undated: the head commit's date could not be read, so last real activity cannot be computed; excluded this cycle" >&2
fi

# Last-real-activity, then the cutoff: the latest of the head commit's
# `committedDate`, every review's `submittedAt` and every comment's
# `createdAt`, *excepting* any review or comment whose body carries our own
# marker. Both collections are filtered, not just `comments`: `gh pr comment`
# and `gh pr review --comment` are two ways of writing the same note and the
# Reviewer may use either, so a marker that only worked in one of them would
# leave the pipeline resetting its own clock through the other. A PR with no
# computable activity — no readable head-commit date, or flagged `at_cap`
# above — is dropped rather than treated as infinitely stale, and the explicit
# `!= null` guards below are what do the dropping — do not remove either as
# redundant. jq sorts `null` *below* every string, so a null activity satisfies
# `$activity < $cutoff` on its own: without the guard a malformed API response
# would make the PR look maximally stale and this source would hand a human's
# live work to an Implementer to force-push over.
prs="$(jq -c --arg cutoff "$cutoff" --arg marker "$PIPELINE_COMMENT_MARKER_PREFIX" '
  [.[]
   | (if .at_cap or .head_committed_at == null then null
      else (([ .head_committed_at ]
             + [ (.reviews // [])[] | select((.body // "") | contains($marker) | not) | .submittedAt ]
             + [ (.comments // [])[] | select((.body // "") | contains($marker) | not) | .createdAt ])
            | max)
      end) as $activity
   | select($activity != null and $activity < $cutoff)
   | . + {real_activity: $activity}]' <<<"$prs" 2>/dev/null || true)"
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

  # The originating item, so the Implementer can find the tech-debt entry, issue,
  # or finding this PR came from. Best-effort: a ref in the branch name or body.
  # Absence is normal and must not disqualify the candidate — the PR body and its
  # diff are the brief, not the register entry.
  item="$(jq -r '(.headRefName + " " + (.body // ""))' <<<"$pr" \
          | grep -oiE '\b(TD[0-9]{8}|dependabot-alert-[0-9]+|code-scanning-alert-[0-9]+|review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-?[0-9]+)\b' \
          | head -n1 || true)"

  # $pr is the whole pull-request object, including its body — unbounded past
  # this call (requirement 4g, TD-PPagop-26081406). Delivered on stdin, not
  # argv. Fails open, and loudly: a candidate this build cannot parse is
  # skipped rather than aborting the whole gather, and says which one on
  # stderr.
  cand="$(jq -nc \
    --arg ref "pr-${number}-abandoned-${head_sha:0:12}" \
    --arg item "$item" \
    --arg head_sha "$head_sha" \
    'input as $pr | {source: "abandoned-drafts",
      ref: $ref,
      number: $pr.number,
      pr_number: $pr.number,
      url: $pr.url,
      pr_url: $pr.url,
      title: $pr.title,
      branch: $pr.headRefName,
      item: (if $item == "" then null else $item end),
      head_sha: $head_sha,
      updated_at: $pr.real_activity,
      body: ($pr.body // "")}' <<<"$pr")" || {
    echo "gather-abandoned-drafts: $slug pr-${number}-abandoned-${head_sha:0:12}: candidate assembly failed; skipped" >&2
    continue
  }
  # $cand and the accumulator both arrive on stdin, one document per line,
  # bound positionally with `input as $name` in the order printed
  # (requirement 4g, TD-PPagop-26081406) — never in argv: a single candidate
  # past MAX_ARG_STRLEN must not degrade this repo's whole abandoned_drafts
  # array to `[]`. `$out` inside the substitution is still the
  # pre-assignment value, so a failed append keeps every candidate already
  # collected and only drops this one.
  out="$(jq -nc 'input as $arr | input as $c | $arr + [$c]' <<<"$out"$'\n'"$cand" || {
    echo "gather-abandoned-drafts: $slug pr-${number}-abandoned-${head_sha:0:12}: array assembly failed; candidate dropped" >&2
    printf '%s' "$out"
  })"
done < <(jq -c '.[]' <<<"$prs" 2>/dev/null || true)

# Longest-abandoned first: the draft that has been untouched longest goes first,
# so the most-stalled work (and the back-pressure slot it holds) clears soonest.
jq -c 'sort_by(.updated_at)' <<<"$out"
