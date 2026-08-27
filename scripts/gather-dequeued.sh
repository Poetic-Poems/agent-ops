#!/usr/bin/env bash
#
# gather-dequeued.sh — pre-fetch a repo's pull requests this system raised
# that GitHub's merge queue removed over a *merge-group* checks failure
# without merging (TD-PPagop-26081409, issue #374, requirement 38f/D17).
#
# A merge queue dequeues a pull request whose own head is green but whose
# speculative merge with whatever sat ahead of it in the queue failed a
# required check — a real defect in the pull request, of exactly the kind
# requirement 3g already fixes autonomously when git surfaces it as a
# textual conflict instead. `scripts/sweep-human-visibility.sh` already
# notices every dequeue and tells a human (requirement 38f) — that notice
# fires for any dequeue reason and is unconditional here, per the design this
# script implements. What nothing did before this file is turn the
# pipeline-actionable half of that — a checks-failure dequeue — into work the
# Co-Ordinator can select: this script is that other half.
#
# Given a repo slug, print a JSON array of candidates: open, *non-draft* PRs
# carrying <pr-label> whose head branch is ours (<branch-prefix> or `td/`),
# which GitHub's merge queue most recently removed for a merge-group checks
# failure and has not since re-queued, and which are not already conflicting
# against their base (that is requirement 3g's own candidate — see "Why this
# source and merge-conflicts never overlap" below).
#
# Usage: gather-dequeued.sh <owner/repo> <pr-label> <branch-prefix> [tech-debt-branch-prefix]
#
# Candidate shape:
#   {
#     "source": "dequeued",
#     "ref": "pr-57-dequeued-1a2b3c4d5e6f", // scoped to THIS head, same
#                                             // reasoning as gather-merge-
#                                             // conflicts.sh's own refs — a
#                                             // fresh push (a fix, or anyone
#                                             // else's) mints a fresh ref
#                                             // that no old block/void covers
#     "number": 57,
#     "pr_number": 57,
#     "url": "https://github.com/…/pull/57",
#     "pr_url": "https://github.com/…/pull/57",
#     "title": "fix(cache): …",
#     "branch": "agent/td26072001-…",
#     "base": "main",
#     "item": "TD26072001",               // the originating item, if inferable
#     "head_sha": "1a2b3c4d5e6f…",
#     "updated_at": "2026-07-24T03:00:00Z",
#     "body": "…the PR's own description, verbatim…",
#     "dequeued_at": "2026-08-14T01:23:45Z",
#     "dequeue_reason": "failed_checks"
#   }
#
# ## The candidate rule
#
# A PR is a candidate iff it is open, **not** a draft, carries <pr-label>,
# its head branch starts with <branch-prefix> (or `td/`, the tech-debt claim
# branch) — i.e. this system raised it, the same "ours" test
# gather-merge-conflicts.sh applies, since force-pushing a fix onto a
# human's own branch is exactly what the Landing Gate reserves every other
# branch against — and:
#
#   - its `mergeable` reads exactly `MERGEABLE` (never `CONFLICTING`, which
#     is requirement 3g's own candidate and must stay that script's alone —
#     see below — and never the transient `UNKNOWN`, for the same reason
#     gather-merge-conflicts.sh never admits it: GitHub computes mergeability
#     asynchronously, and a PR whose base just moved reads `UNKNOWN` for a
#     beat that is not yet a fact this script can act on); and
#   - `lib/merge-queue.sh`'s `merge_queue_probe` reports `queued: false` and
#     a non-null `dequeued_at` — it was removed from the queue and has not
#     been re-queued since; and
#   - `dequeue_reason` reads, case-insensitively, exactly `failed_checks` —
#     the one value confirmed against a real GitHub deployment (a merge-group
#     checks failure; see the Gotchas note below). GitHub documents `reason`
#     as a free-text `String`, not a fixed enum (checked 2026-08-14 against
#     both the GraphQL schema and octokit/webhooks' own JSON Schema for the
#     `pull_request.dequeued` event — neither constrains it), so this is
#     deliberately an allow-list, not a deny-list: TD-PPagop-26081409's own
#     warning is that selecting a *human-initiated* removal would have a
#     cycle push a fix to a branch the human just took back, so an unrecognised
#     or absent reason is never a candidate, on the same "the wrong direction
#     here is unsafe" reasoning gather-merge-conflicts.sh applies to `UNKNOWN`.
#   - **the dequeue has not already been answered** — no marked
#     `actor=implementer` reply on the pull request, in a review body or a
#     general comment, is newer than `dequeued_at`. See "Why the dequeue must
#     still be unanswered" below: this is the clause that stops a fixed
#     dequeue being selected again for ever, and it is load-bearing, not a
#     refinement.
#
# A probe that cannot answer (network failure, an unreadable response) is
# never read as "not dequeued" — the one direction `merge_queue_probe`'s own
# contract forbids — so a PR whose probe fails is simply not a candidate this
# cycle, exactly as one gather-merge-conflicts.sh could not read `mergeable`
# for would not be. The reviews/comments read behind the answered clause fails
# the same way, and for a sharper reason — see that section.
#
# ## Why this source and merge-conflicts never overlap
#
# Acceptance point 6 (TD-PPagop-26081409) requires the two sources stay
# complementary, never overlapping. Requiring `mergeable == "MERGEABLE"` here
# is what guarantees it: a PR that is both dequeued *and* now conflicting
# against a base that moved further since is requirement 3g's candidate (a
# rebase is the fix it needs), not this script's — and gather-merge-
# conflicts.sh's own candidate rule already excludes anything not
# `CONFLICTING`, so the two candidate rules partition on `mergeable` and can
# never both admit the same PR head at once.
#
# ## Why the dequeue must still be unanswered
#
# Every sibling finishing source stops yielding a candidate once the pipeline
# has done its part, because the condition it keys on clears by itself: a
# rebase makes requirement 3g's `mergeable` stop reading `CONFLICTING`; any
# activity resets requirement 3e's `abandoned_draft_after_hours` clock. This
# source has neither. `RemovedFromMergeQueueEvent` is immutable timeline
# history, so `merge_queue_probe` returns the same `dequeued_at` and
# `dequeue_reason` for ever, and `isInMergeQueue` only returns to `true` when a
# *human* clicks "Merge when ready" again — which D17 deliberately reserves to
# them. So after the Implementer diagnoses the merge-group failure and pushes
# its fix, every other clause above still holds, and the only thing that has
# moved is the head SHA. The ref is scoped to that (below), so the fix does not
# retire the old ref, it *replaces* it with one no `blocked`, `void` or
# `claimed` record covers — and the pull request is offered again, at rank
# five, pointed at a merge-group run that is already fixed. Because this array
# feeds the no-op fingerprint verbatim (lib/noop-skip.sh), each replacement
# busts the fingerprint and wakes the pipeline for it.
#
# This is the failure gather-review-feedback.sh's own header calls
# load-bearing, arising here from the same root cause: the agent cannot clear
# the state it is keyed on. That script answers it by requiring the blocking
# review round to be unanswered; requirement 3z answers it the same way, via
# the same predicate — `handoff_round_answered` (lib/handoff.sh), one
# definition for the two callers that must agree on what "answered" means
# (requirement 34a).
#
# Three properties of how it is called here are deliberate:
#
#   - **The round starts at `dequeued_at`, not at the pull request's birth.**
#     Keying on the timestamp rather than on "has any implementer comment"
#     is what keeps the clause exact: a *second* dequeue after the fix stamps a
#     later `dequeued_at` than the answering comment, so the pull request
#     correctly becomes a candidate again. The clause suppresses the
#     re-selection loop without making one fixed dequeue a permanent
#     exclusion.
#   - **`REREQUESTS_JSON` is deliberately not passed.** A review-requested
#     event does not answer a dequeue, and passing the timeline would let
#     sweep-human-visibility.sh's own re-request — posted beside the very
#     requirement 38f notice this source rides alongside — read back next
#     cycle as an answer to itself (tech-debt/TD-PPagop-26080804.md). Only a
#     marked `actor=implementer` reply closes this round.
#   - **A read this cannot make yields no candidate, never "unanswered".**
#     gather-review-feedback.sh defaults an unreadable comments read to `[]`,
#     which reads as `unanswered` and *admits* its candidate; that is safe
#     there and unsafe here, because here `unanswered` is the verdict that
#     creates work. So a failed or non-array read drops the pull request for
#     this cycle, exactly as an unreadable `merge_queue_probe` does, and
#     `unknown` is never collapsed into `unanswered`.
#
# ## Why the ref is scoped to the head SHA
#
# Same reasoning as gather-merge-conflicts.sh's own `pr-<n>-conflict-<sha>`
# (see that script's header): an item recorded blocked stays blocked until
# something clears it, so a bare `pr-<n>-dequeued` that an Implementer once
# failed to resolve would still read blocked after a fresh push — including
# the Implementer's own fix — changed the very state the item names. Scoping
# to the head SHA means a block recorded against one dequeued state does not
# swallow a later, possibly-resolvable one, while a re-detected dequeue at the
# *same* head keeps the same ref and stays correctly blocked.
#
# What it does *not* do is end the pull request's candidacy: a fresh push
# replaces the ref rather than retiring it, which is the answered clause's job
# above. The two are complementary and neither substitutes for the other.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with no
# actionable dequeues contributes `[]`; an API that will not answer
# contributes `[]` too (the source simply does not fire this cycle).
#
# Environment: DEQUEUED_GH overrides `gh` (tests stub it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The marker before handoff: `handoff_answer_events` reads
# `PIPELINE_COMMENT_MARKER_PREFIX` from this file, the same order
# gather-review-feedback.sh sources them in.
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below (including
# the one inside merge_queue_probe, which defaults to the same shadowed name)
# so a refusal GitHub will lift in seconds is waited out rather than
# degrading this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
GH="${DEQUEUED_GH:-gh}"
MERGE_QUEUE_GH="$GH"
export MERGE_QUEUE_GH
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# `handoff_round_answered`, the answered clause's one definition (requirement
# 34a) — see "Why the dequeue must still be unanswered" above.
# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
tech_debt_branch_prefix="${4-td/}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-dequeued.sh <owner/repo> [pr-label] [branch-prefix] [tech-debt-branch-prefix]" >&2
  exit 64
fi

# Same idiom as gather-merge-conflicts.sh's own `warn`: say it, then carry on
# — losing one candidate this cannot assemble is far smaller than losing
# every dequeued PR in the repo over it, so this is not `degrade`'s
# print-`[]`-and-exit shape.
warn() {
  echo "gather-dequeued: $slug: $*" >&2
}

# The open, agent-raised, non-draft PRs, fetched raw — the mergeable filter
# runs afterwards, so the truncation check below counts what GitHub returned
# rather than what the filter kept. Same field set gather-merge-conflicts.sh
# reads its own "ours" listing with, for the same reasons (see that script's
# header on `headRefOid` vs `commits`).
ours_all="$("$GH" pr list -R "$slug" --state open --label "$pr_label" \
        --limit "$GITHUB_PR_LIST_LIMIT" \
        --json number,title,headRefName,headRefOid,baseRefName,isDraft,mergeable,updatedAt,url,body \
        || true)"
jq -e 'type == "array"' <<<"$ours_all" >/dev/null 2>&1 || ours_all='[]'

if github_pr_list_truncated "$(jq 'length' <<<"$ours_all")"; then
  echo "gather-dequeued: $slug: the pull-request listing came back at its ${GITHUB_PR_LIST_LIMIT}-item cap; a dequeued PR beyond it is not offered this cycle" >&2
fi

# `mergeable` selected against `== "MERGEABLE"` exactly — never `CONFLICTING`
# (that PR belongs to gather-merge-conflicts.sh alone, see the header) and
# never `UNKNOWN`. Heads may be `agent/…` or, for tech-debt items,
# `<tech_debt_branch_prefix><ID>`; the label filter is the primary "ours"
# signal either way.
#
# Empty tech_debt_branch_prefix disables the tech-debt namespace: the `or`
# clause is dropped rather than built with an empty startswith(""), which
# would match every head.
td_clause=""
if [[ -n "$tech_debt_branch_prefix" ]]; then
  td_clause=" or (.headRefName | startswith(\"$tech_debt_branch_prefix\"))"
fi
ours="$(jq -c "[.[] | select(.isDraft | not)
                    | select(.mergeable == \"MERGEABLE\")
                    | select((.headRefName | startswith(\"$branch_prefix\"))$td_clause)]" \
        <<<"$ours_all" 2>/dev/null || echo '[]')"
jq -e 'type == "array"' <<<"$ours" >/dev/null 2>&1 || ours='[]'

out='[]'

emit() {  # <pr-json>
  local pr="$1" number head_sha item cand docs
  local mq_probe mq_queued mq_dequeued_at mq_dequeue_reason
  local reviews issue_comments answered
  number="$(jq -r '.number' <<<"$pr")"
  head_sha="$(jq -r '.headRefOid // ""' <<<"$pr")"
  [[ -n "$head_sha" ]] || return 0

  mq_probe="$(merge_queue_probe "$slug" "$number" 2>/dev/null || true)"
  [[ -n "$mq_probe" ]] || return 0
  mq_queued="$(jq -r '.queued' <<<"$mq_probe" 2>/dev/null || true)"
  mq_dequeued_at="$(jq -r '.dequeued_at // ""' <<<"$mq_probe" 2>/dev/null || true)"
  mq_dequeue_reason="$(jq -r '.dequeue_reason // ""' <<<"$mq_probe" 2>/dev/null || true)"
  [[ "$mq_queued" == "false" ]] || return 0
  [[ -n "$mq_dequeued_at" ]] || return 0
  [[ "${mq_dequeue_reason,,}" == "failed_checks" ]] || return 0

  # The answered clause (see "Why the dequeue must still be unanswered"). Read
  # last of the gates, so it costs nothing for the PRs the probe already
  # rejected. Both collections: the Implementer's summary lands via `gh pr
  # comment` (issue comments) but the same marked reply in a review body counts
  # too, and the two file under different endpoints — gather-review-feedback.sh
  # reads both for the same reason.
  #
  # Streamed one object per line and slurped into a single document below:
  # `handoff_round_answered` needs one JSON array per argument, and
  # `--paginate` emits one array *per page*, which its own guards would then
  # have to reject as `unknown` (see that function's note on `jq -e 'type ==
  # "array"'`).
  #
  # Each read's *exit status* is what decides, and it has to be: an empty
  # stream slurps to a perfectly valid `[]`, so a failed read and a pull
  # request nobody has commented on are indistinguishable by their output
  # alone. `[]` would then read as `unanswered` and offer the candidate, which
  # is the one direction this source must not fail in — hence the early return
  # rather than gather-review-feedback.sh's `|| issue_comments='[]'`.
  reviews="$("$GH" api "repos/$slug/pulls/$number/reviews" --paginate \
              --jq '.[] | select(.submitted_at != null)
                        | {at: .submitted_at, body: (.body // "")}' \
              2>/dev/null)" \
    || { warn "could not read pr #$number's reviews; not offering it this cycle"; return 0; }
  reviews="$(jq -s -c '.' <<<"$reviews" 2>/dev/null)" \
    || { warn "could not assemble pr #$number's reviews; not offering it this cycle"; return 0; }
  issue_comments="$("$GH" api "repos/$slug/issues/$number/comments" --paginate \
                      --jq '.[] | {at: .created_at, body: (.body // "")}' \
                      2>/dev/null)" \
    || { warn "could not read pr #$number's comments; not offering it this cycle"; return 0; }
  issue_comments="$(jq -s -c '.' <<<"$issue_comments" 2>/dev/null)" \
    || { warn "could not assemble pr #$number's comments; not offering it this cycle"; return 0; }

  # `unanswered` and nothing else: `unknown` is never collapsed into it, for
  # the same reason the reads above fail closed. REREQUESTS_JSON is
  # deliberately omitted (header, second bullet).
  answered="$(handoff_round_answered "$mq_dequeued_at" "$reviews" "$issue_comments")"
  [[ "$answered" == "unanswered" ]] || {
    [[ "$answered" == "answered" ]] \
      || warn "could not judge whether pr #$number's dequeue was answered; not offering it this cycle"
    return 0
  }

  # The originating item, so the Implementer can find the tech-debt entry or
  # issue this PR came from — best-effort, absence is normal. Same regex
  # gather-merge-conflicts.sh reads its own "ours" candidates with.
  item="$(jq -r '(.headRefName + " " + (.body // ""))' <<<"$pr" \
          | grep -oiE '\b(TD[0-9]{8}|dependabot-alert-[0-9]+|code-scanning-alert-[0-9]+|review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-?[0-9]+)\b' \
          | head -n1 || true)"

  # requirement 4g: $pr carries a whole pull-request body, unbounded by
  # anything in this system, so it travels to jq on stdin — a here-string,
  # not a pipe, so a producer's SIGPIPE under `pipefail` cannot become this
  # call's status.
  cand="$(jq -nc \
    --arg ref "pr-${number}-dequeued-${head_sha:0:12}" \
    --arg item "$item" \
    --arg head_sha "$head_sha" \
    --arg dequeued_at "$mq_dequeued_at" \
    --arg dequeue_reason "$mq_dequeue_reason" \
    'input as $pr | {source: "dequeued",
      ref: $ref,
      number: $pr.number,
      pr_number: $pr.number,
      url: $pr.url,
      pr_url: $pr.url,
      title: $pr.title,
      branch: $pr.headRefName,
      base: $pr.baseRefName,
      item: (if $item == "" then null else $item end),
      head_sha: $head_sha,
      updated_at: $pr.updatedAt,
      body: ($pr.body // ""),
      dequeued_at: $dequeued_at,
      dequeue_reason: $dequeue_reason}' <<<"$pr")" \
    || { warn "candidate assembly failed for pr #$number"; return 0; }

  # Same stdin-doc accumulator gather-merge-conflicts.sh uses, for the same
  # MAX_ARG_STRLEN reason (requirement 4g).
  docs="$(printf '%s\n' "$out" "$cand")"
  out="$(jq -nc '
    input as $out | input as $c
    | $out + [$c]
  ' <<<"$docs" || { warn "array assembly failed at pr #$number"; printf '%s' "$out"; })"
}

while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue
  emit "$pr"
done < <(jq -c '.[]' <<<"$ours" 2>/dev/null || true)

# Longest-waiting first: the PR whose dequeue has sat unanswered longest goes
# first. gather-merge-conflicts.sh orders on `updated_at` because a conflict
# carries no timestamp of its own, but a dequeue does — and here the two are
# not interchangeable. `updatedAt` moves on any comment, *including the
# merge-queue-dequeued notice requirement 38f posts on this very pull request*,
# so ordering on it would let the act of telling the human reset the pull
# request's place in the queue, and a PR dequeued days ago but commented on
# this morning would sort last. `dequeued_at` measures what the ordering
# claims to measure, and after the clause above it is literally the start of
# the unanswered round. `updated_at` breaks ties, keeping the order total for
# two dequeues sharing a timestamp.
jq -c 'sort_by(.dequeued_at, .updated_at)' <<<"$out"
