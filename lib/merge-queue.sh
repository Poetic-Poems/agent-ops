#!/usr/bin/env bash
#
# lib/merge-queue.sh — GitHub merge-queue awareness (D17, docs/ROADMAP.md;
# agent-ops#374).
#
# A GitHub merge queue makes landing asynchronous: the human act is
# enqueueing ("Merge when ready"), and the actual merge happens minutes
# later, after the merge group's own checks pass — or never, if the queue
# dequeues the pull request (a checks failure, or its own base moving under
# it). Two things follow that nothing in this repository could read before
# this file existed:
#
#   1. A currently-queued pull request is the human's, mid-transaction — it
#      must never be pushed to (a push evicts it from the queue with no
#      further signal) and must never be treated as "nobody has clicked
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
# time GitHub removed this pull request from the queue — null if it was
# never queued, or was queued and later merged with no removal in between.
#
# Prints nothing and returns non-zero if the read fails for any reason (bad
# arguments, `gh` erroring, an unparsable response). Callers must treat that
# as *unknown*, never as "definitely not queued" — the one direction that
# would be unsafe, since it is exactly the state a push-eviction guard exists
# to catch.
merge_queue_probe() {
  local slug="$1" number="${2:-}" gh_bin="${MERGE_QUEUE_GH:-gh}"
  local owner="${slug%%/*}" repo="${slug#*/}"
  local out
  [[ -n "$owner" && -n "$repo" && "$owner" != "$repo" ]] || return 1
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
