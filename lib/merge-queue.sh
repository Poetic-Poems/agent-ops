#!/usr/bin/env bash
#
# lib/merge-queue.sh — GitHub merge-queue awareness (D17, docs/ROADMAP.md;
# agent-ops#374).
#
# A GitHub merge queue makes landing asynchronous: the enqueueing act is
# either the human's own "Merge when ready" click at merge_autonomy: human
# or agent-approves, or `landing_arm`'s own enqueue mutation at
# agent-merges-routine and above (lib/landing.sh) — and the actual merge
# happens minutes later, after the merge group's own checks pass — or never,
# if the queue dequeues the pull request (a checks failure, or its own base
# moving under it). Two things follow that nothing in this repository could
# read before this file existed:
#
#   1. A currently-queued pull request is mid-transaction, whoever enqueued
#      it — it must never be pushed to (a push evicts it from the queue with
#      no further signal) and must never be treated as "nobody has clicked
#      merge yet" (`scripts/sweep-human-visibility.sh`'s idle nudge did,
#      before this file: an enqueued pull request reads `APPROVED`,
#      `MERGEABLE` and green exactly like one nobody has acted on yet).
#   2. A dequeue is otherwise invisible. GitHub does not mark a dequeued
#      pull request in any way that distinguishes it from one that was never
#      queued — no field says "this used to be queued" — so the only signal
#      is the pull request's own timeline.
#
# Neither `isInMergeQueue` nor a merge-queue removal event is exposed by
# `gh pr list`/`gh pr view --json` (checked 2026-08-14 against gh 2.97.0:
# `Unknown JSON field: "isInMergeQueue"`), so this runs a dedicated GraphQL
# query rather than folding into an existing `--json` read. Verified live
# against GitHub's own GraphQL schema (`gh api graphql` introspection) that
# `PullRequest.isInMergeQueue` is a plain non-null boolean, and that
# `RemovedFromMergeQueueEvent` (one of `PullRequestTimelineItemsItemType`'s
# values) carries `createdAt` and `reason` — the two fields this file reads.
#
# Environment: MERGE_QUEUE_GH overrides `gh` (tests stub it).

# merge_queue_probe SLUG NUMBER
# Print a JSON object {"queued": true|false, "dequeued_at": <ISO8601>|null,
# "dequeue_reason": <string>|null} for pull request NUMBER in SLUG
# ("owner/repo"). `dequeued_at`/`dequeue_reason` describe the most recent
# time GitHub removed this pull request from the queue — null only if it was
# never queued at all. A *successful* merge is itself a removal, carrying
# `reason: "merged"` (verified live, 2026-08-14, across the merged pull
# requests of renovatebot/renovate), so a pull request that landed through
# the queue reports that merge here rather than null, and it is the value
# `last` returns for it — an earlier, more informative removal on the same
# pull request (renovatebot/renovate#45218: `["manual", "merged"]`) is
# shadowed by it. That costs this repository's callers nothing, all of which
# read open pull requests only, and `merge_queue_dequeue_actionable` below
# classifies `"merged"` as nothing to act on regardless.
#
# Prints nothing and returns non-zero if the read fails for any reason (bad
# arguments, `gh` erroring, an unparsable response). Callers must treat that
# as *unknown*, never as "definitely not queued" — the one direction that
# would be unsafe, since it is exactly the state a push-eviction guard exists
# to catch.
merge_queue_probe() {
  local slug="$1" number="${2:-}" gh_bin="${MERGE_QUEUE_GH:-gh}"
  local out
  # Exactly one `/`, with something either side — "owner/repo" and nothing
  # else. Tested rather than inferred from the split below: `${slug%%/*}` and
  # `${slug#*/}` both return the whole string when there is no `/` at all, so
  # a bare "owner" would otherwise reach `gh` as owner=owner, repo=owner.
  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
  local owner="${slug%%/*}" repo="${slug#*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1

  # shellcheck disable=SC2016  # GraphQL's own $owner/$repo/$number variables, not the shell's.
  out="$("$gh_bin" api graphql \
    -f query='query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$number){
          isInMergeQueue
          timelineItems(last:5, itemTypes:[REMOVED_FROM_MERGE_QUEUE_EVENT]){
            nodes{ ... on RemovedFromMergeQueueEvent { createdAt reason } }
          }
        }
      }
    }' \
    -f owner="$owner" -f repo="$repo" -F number="$number" \
    --jq '.data.repository.pullRequest as $pr
          | ($pr.timelineItems.nodes | last) as $last
          | {queued: $pr.isInMergeQueue,
             dequeued_at: ($last.createdAt // null),
             dequeue_reason: ($last.reason // null)}' \
    2>/dev/null)" || return 1
  # A GraphQL-level error (bad credentials, an unresolvable PR) makes `gh`
  # exit non-zero, caught above — but belt and braces: only ever hand a
  # caller a document that actually parses as the shape this promises. A
  # `repository`/`pullRequest` that resolved to null (a malformed query, an
  # org rename mid-flight) survives the filter above as `{"queued": null,
  # …}` — a present key with the one value a caller must never mistake for a
  # real answer — so the type is checked, not merely the key's presence.
  jq -e '.queued | type == "boolean"' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# merge_queue_for_branch SLUG BRANCH
# Print the `mergeQueue(branch:)` GraphQL object for BRANCH in SLUG — the
# literal string `null` when that branch carries no active merge queue,
# or a compact JSON object carrying the queue's own `id` when it does.
# Returns non-zero, printing nothing, when the read fails for any
# reason (bad arguments, `gh` erroring, an unparsable response) — the same
# "prints nothing on failure" contract `merge_queue_probe` follows, so a
# caller can tell "definitely no queue" (the string `null`) apart from
# "could not find out" (empty output, non-zero exit) without a second
# check.
#
# This is D18 WI-7's own queue-detection read (`lib/landing.sh`'s
# `landing_arm`, agent-ops#410, docs/reviews/2026-08-14-autonomy-investigation.md
# §5.1): whether to enqueue a pull request or fall back to
# `gh pr merge --auto --squash` depends on the *base branch's* own queue,
# not the pull request's queued state (`merge_queue_probe` answers that
# different question). Verified live, 2026-08-29, against
# `Poetic-Poems/agent-ops`'s own `main`: `mergeQueue(branch:"main")` →
# `{id: "MQ_kwDOTWpCsc4AA8Qo"}`, confirming the field resolves for a real
# installation and the shape below is what it actually returns. Kept in
# this file rather than in `lib/landing.sh` — "one file owns every
# merge-queue GraphQL read" is this file's own header, and a second query
# here would be the same detector drift TD26071401 recorded for
# `lib/limit-detect.sh`.
#
# The selection set is deliberately `id` alone, and stays that way unless a
# caller actually consumes what is added to it. It once also asked for
# `mergeMethod` and `mergingStrategy`, which GitHub moved off `MergeQueue`
# onto `MergeQueue.configuration` (a `MergeQueueConfiguration`) between
# 2026-08-16 and 2026-08-23. GraphQL rejects the *whole* document for one
# unknown field, so those two — decoration, read by no caller here or in
# `scripts/doctor.sh`, which take only this function's exit status and its
# `null`-versus-object answer — took the entire query down with them, and
# `landing_arm` refused every arming attempt from 2026-08-23 onwards with
# its gate-4 wording ("could not read the base branch's merge-queue
# state"): the fleet's first autonomous landing, and D18 Stage 1's own exit
# evidence (agent-ops#677), waited on two fields nobody read. Every `gh`
# mock under `test/` answered with the pre-move shape, so no test could
# fail. If a caller ever does need the queue's configuration, ask for it
# under `configuration { … }` and consume it; never re-add a field this
# function does not hand back to somebody.
merge_queue_for_branch() {
  local slug="$1" branch="${2:-}" gh_bin="${MERGE_QUEUE_GH:-gh}"
  local out
  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
  local owner="${slug%%/*}" repo="${slug#*/}"
  [[ -n "$branch" ]] || return 1

  # shellcheck disable=SC2016  # GraphQL's own $owner/$repo/$branch variables, not the shell's.
  out="$("$gh_bin" api graphql \
    -f query='query($owner:String!,$repo:String!,$branch:String!){
      repository(owner:$owner,name:$repo){
        mergeQueue(branch:$branch){ id }
      }
    }' \
    -f owner="$owner" -f repo="$repo" -f branch="$branch" \
    2>/dev/null)" || return 1
  # `gh`'s own `--jq` is deliberately not used to reach the field, and must
  # not be reintroduced. It *raw*-prints, so a filter yielding a JSON `null`
  # emits an empty line rather than the four characters `null` — and a null
  # is not an edge case here, it is the commonest answer this function
  # exists to give ("that branch runs no merge queue"). Through `--jq` it
  # arrived indistinguishable from "gh printed nothing at all", leaving the
  # emptiness to be settled by a `jq -e` on empty input, which exits 0 on
  # jq 1.6 and 4 on jq 1.7 — the same version split `landing_eligible`
  # documents at each of its own membership tests. So on the image's jq 1.7
  # a repository with no merge queue read as *unreadable*, and
  # `landing_arm` refused it (exit 4) instead of taking the `gh pr merge
  # --auto --squash` fallback that whole branch of the code exists for;
  # on a jq 1.6 host it read as an active queue and would have tried to
  # enqueue into a queue that is not there. Reading the envelope whole and
  # extracting it here keeps a null the literal `null` the contract above
  # promises, identically on either jq.
  #
  # `.data.repository` is checked rather than indexed straight through:
  # jq yields `null` for a field of a null parent, so a repository the
  # token cannot see would otherwise arrive as the same confident "no
  # queue" as a repository that genuinely has none. GitHub answers that
  # case with an `errors` array `gh` already exits non-zero on; this is the
  # belt to that braces, not a substitute for it.
  out="$(jq -c 'if .data.repository == null then error("no repository")
                else .data.repository.mergeQueue end' <<<"$out" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  # Belt and braces, matching `merge_queue_probe`'s own type check: only
  # ever hand a caller a document that actually parses as the shape this
  # promises — `null` (no queue) or an object carrying `id`.
  jq -e 'type == "null" or (type == "object" and has("id"))' <<<"$out" >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# merge_queue_dequeue_actionable REASON
# True (exit 0) if a removal carrying `dequeue_reason` REASON is one the
# pipeline should surface to a human — a merge-group checks failure, or any
# other automatic cause that left the pull request unlanded. False for the
# two reasons that are nobody's defect (agent-ops#394,
# tech-debt/TD-PPagop-26081409.md):
#
#   - "manual" — the maintainer took their own entry back, via the API or
#     the merge queue's own UI. They caused it, so they already know.
#   - "merged" — the removal *is* the pull request landing, the happy path
#     and in practice the commonest value of the field. No caller here can
#     see one today (all read open pull requests only, and this reason
#     accompanies a closed one), but a classification three sites are meant
#     to share must not call a successful merge something to act on.
#
# Verified live (2026-08-14, `gh api graphql` against public repositories
# with an active merge queue): "manual" (renovatebot/renovate#45218),
# "merged" (every merged renovatebot/renovate pull request carries one),
# "failed_checks" (renovatebot/renovate#45223) and "merge_conflict"
# (PyO3/pyo3#6276). GitHub documents no enum for the field (it is a plain
# `String`), so an empty or otherwise unrecognised REASON is treated as
# actionable: withholding the one notice a human gets for a defect they did
# not cause is the worse mistake, the mirror image of `merge_queue_probe`'s
# own "unknown means possibly queued" rule. Shared so
# `scripts/sweep-human-visibility.sh`'s own notice and the dashboard's
# dequeue surface (agent-ops#375) read off the same decision, and so
# `agent-cycle.sh`'s own landing-gate 6 (`_landing_stage_attempt`, PR #557
# review round 2 of TD-PPagop-26081701) can tell a maintainer's own
# deliberate removal — never this stage's to reverse — apart from any other
# reason in its refusal wording, without re-deciding the classification
# itself.
merge_queue_dequeue_actionable() {
  case "${1:-}" in
    manual|merged) return 1 ;;
    *) return 0 ;;
  esac
}
