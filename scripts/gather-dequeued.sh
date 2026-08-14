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
# Usage: gather-dequeued.sh <owner/repo> <pr-label> <branch-prefix>
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
# human's own branch is exactly what the Human Gate reserves every other
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
#
# A probe that cannot answer (network failure, an unreadable response) is
# never read as "not dequeued" — the one direction `merge_queue_probe`'s own
# contract forbids — so a PR whose probe fails is simply not a candidate this
# cycle, exactly as one gather-merge-conflicts.sh could not read `mergeable`
# for would not be.
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
# ## Why the ref is scoped to the head SHA
#
# Same reasoning as gather-merge-conflicts.sh's own `pr-<n>-conflict-<sha>`
# (see that script's header): an item recorded blocked stays blocked until
# something clears it, so a bare `pr-<n>-dequeued` that an Implementor once
# failed to resolve would still read blocked after a fresh push — including
# the Implementor's own fix — changed the very state the item names. Scoping
# to the head SHA means a fresh push naturally retires the old ref (this
# script simply stops yielding it — the PR's `dequeued_at` now describes a
# head nobody is offering a candidate for) while a re-detected dequeue at the
# *same* head keeps the same ref and stays correctly blocked.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with no
# actionable dequeues contributes `[]`; an API that will not answer
# contributes `[]` too (the source simply does not fire this cycle).
#
# Environment: DEQUEUED_GH overrides `gh` (tests stub it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-dequeued.sh <owner/repo> [pr-label] [branch-prefix]" >&2
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
# never `UNKNOWN`. Heads may be `agent/…` or, for tech-debt items, `td/…`;
# the label filter is the primary "ours" signal either way.
ours="$(jq -c "[.[] | select(.isDraft | not)
                    | select(.mergeable == \"MERGEABLE\")
                    | select((.headRefName | startswith(\"$branch_prefix\"))
                             or (.headRefName | startswith(\"td/\")))]" \
        <<<"$ours_all" 2>/dev/null || echo '[]')"
jq -e 'type == "array"' <<<"$ours" >/dev/null 2>&1 || ours='[]'

out='[]'

emit() {  # <pr-json>
  local pr="$1" number head_sha item cand docs
  local mq_probe mq_queued mq_dequeued_at mq_dequeue_reason
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

  # The originating item, so the Implementor can find the tech-debt entry or
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

# Longest-waiting first: the PR whose dequeue notice has sat unanswered
# longest goes first, matching gather-merge-conflicts.sh's own ordering.
jq -c 'sort_by(.updated_at)' <<<"$out"
