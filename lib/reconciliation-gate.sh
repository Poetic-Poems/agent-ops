#!/usr/bin/env bash
#
# lib/reconciliation-gate.sh — script-side confirmation that every standing
# human comment on a pull request has actually been answered before that pull
# request is taken out of draft (requirement 31c, agent-ops#533).
#
# PR #512: a human requested three changes in a plain PR comment
# (2026-08-16T22:16Z) and flipped the pull request back to draft, saying
# explicitly that the comment-plus-draft-flip *is* the change-request signal
# — a formal `REQUEST_CHANGES` review is unavailable here, because every
# pipeline write and every human comment on this project's own pull requests
# land under the same GitHub account (see lib/pipeline-marker.sh's header),
# and GitHub refuses a review request or a review decision from a pull
# request's own author regardless of who is typing. The next Reviewer engagement
# fixed one of the three points, declared the pull request ready, and never
# mentioned the other two — one of which it directly contradicted, asserting a
# tech-debt record was "correctly left" exactly as the human had just said it
# should not be. `handoff_complete_review`'s existing gates had nothing to say
# about this: CI was green, the closing keyword was intact, and no code-scanning
# alert had ever been introduced. The defect was never in the diff; it was in
# what the Reviewer's own completion comment failed to address.
#
# This file is the fix, following the same shape `lib/closing-keyword-gate.sh`
# already established for a fact GitHub itself can confirm about a pull
# request's own comment history rather than trusting a model's summary of it:
#
#   - the anchor is the pull request's most recent `ready_for_review` timeline
#     event *at or before NOT_AFTER* that was not itself later undone by a
#     `convert_to_draft` event at or before NOT_AFTER — the moment it last
#     left draft, and stayed left, as of the point the round began — falling
#     back to the pull request's own creation time when no such event exists.
#     See `_reconciliation_gate_anchor` for why the bound is not optional in
#     practice, and why an undone flip must be skipped too: without both, the
#     anchor is invalidated by the very flip this gate exists to check, first
#     within the round that flip happened in (agent-ops#533) and then again,
#     one round later, by that same flip once refused and reverted
#     (agent-ops#539);
#   - a "human comment" is any general PR comment (`/issues/<n>/comments`,
#     where `gh pr comment` files them) posted after that anchor, from a
#     non-Bot account that is not a GitHub App acting on someone's behalf
#     (`performed_via_github_app`), whose body does not carry
#     `lib/pipeline-marker.sh`'s `PIPELINE_COMMENT_MARKER_PREFIX` — the same
#     "no marker, not a Bot" rule that tells a human's write apart from the
#     pipeline's own everywhere else in this codebase, because author alone
#     cannot (see that file's header);
#   - it counts as reconciled once some pipeline comment posted since carries
#     a line `<!-- agent-ops:reconciles comment=<id> -->` naming that human
#     comment's own issue-comment id. This is the one new convention
#     requirement 31c's refinement adds, and it sits on the Reviewer's side,
#     not the human's: prompts/reviewer.md's completion comment (step 8)
#     is expected to cite one such line per human comment it has answered,
#     whether by implementing the request or by explicitly contesting it —
#     "cite" rather than "detect", because whether a diff actually answers a
#     human's prose is exactly the judgement a script cannot make; a script can
#     only confirm the citation was made, the same division of labour
#     `lib/closing-keyword-gate.sh` already draws between the model's judgement
#     and the mechanism that checks it acted on it.
#
# Scoped to general PR comments only, not formal reviews or inline review
# comments: the human signal this exists for is a plain comment (PR #512's
# own words), a `REQUEST_CHANGES` review being unavailable to begin with (see
# above), and "issue-comment id" is the id space
# `<!-- agent-ops:reconciles comment=<id> -->` refers to.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (agent-cycle.sh runs under `set -euo pipefail`;
# a test, `set -uo pipefail`) owns those.
#
# Environment:
#   RECONCILIATION_GATE_GH  override `gh` (tests stub it).
#   Reads PIPELINE_COMMENT_MARKER_PREFIX and PIPELINE_RECONCILES_MARKER_PREFIX
#   — source lib/pipeline-marker.sh before this file, or before calling
#   `reconciliation_gate`.

# _reconciliation_gate_pr_parts PR_URL
# Print `owner/repo<TAB>number`, or return non-zero printing nothing. The same
# shape every other lib/*-gate.sh file computes, duplicated rather than
# depended on so this file sources and tests standalone.
_reconciliation_gate_pr_parts() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  printf '%s/%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# _reconciliation_gate_anchor SLUG NUMBER [NOT_AFTER]
# Print the timestamp comments are read "since": the pull request's most
# recent `ready_for_review` timeline event at or before NOT_AFTER that was
# never subsequently undone by a `convert_to_draft` event, itself at or
# before NOT_AFTER — or, when no such event exists (it had never left draft
# by then, a first round, or every flip on record was later reverted), its
# own creation time. Returns non-zero, printing nothing, only when the
# timeline itself could not be read at all; an empty but readable timeline is
# not a failure, it is the first-round case, and falls through to the
# creation-time read.
#
# ## Why NOT_AFTER exists, and why every real caller passes one
#
# "Most recent `ready_for_review` event" read literally is self-invalidating
# on the one path this gate was written for. `prompts/reviewer.md` step 7 has
# the Reviewer run `gh pr ready` itself, inside its own session; the gate runs
# afterwards, from `handoff_complete_review`, once that session has ended. So
# by the time the timeline is read, the most recent `ready_for_review` event
# is the Reviewer's *own* flip — and every human comment the round was
# supposed to answer, all of which necessarily predate it, falls before the
# anchor and is filtered out. Verified against PR #512's real timeline: the
# gate reported `clean` on exactly the scenario it exists to catch, and
# reported `dirty` on the same fixture with only that one event removed. The
# first-round fallback fails the same way, since the Reviewer's flip is also
# the *first* `ready_for_review` event on a never-yet-ready draft, so the
# creation-time branch stops applying at the same moment.
#
# NOT_AFTER is the round's own start (agent-cycle.sh passes `cycle_started_at`
# at both call sites): every flip this pipeline performs happens after it, and
# every flip that established the state the round inherited happened before
# it. Bounding the search there restores the anchor the requirement actually
# names — the moment the pull request last left draft *as the round found it*
# — without changing the rule for the paths that were already correct: on a
# `review-feedback` pull request, and on the Enabler's `complete_handoff`
# recovery path, no flip happens inside the round at all, so the bound selects
# the same event the unbounded read would have.
#
# ## Why a reverted flip must not win either (agent-ops#539)
#
# Bounding by NOT_AFTER alone is not enough once `handoff_complete_review`
# itself reverts a refused flip (`confirm_pr_draft`, agent-ops#539's fix to
# the bug this comment used to describe as merely "verified against PR #512's
# real timeline" without a second round). The reverted `ready_for_review`
# event is not deleted by that revert — GitHub keeps it on the timeline
# exactly where it was — so on the *next* round, unless it is specifically
# excluded, it is again the most recent `ready_for_review` event at or before
# the new bound, and the gate is fooled by its own refusal one round later:
# the human comment that caused the `dirty` verdict now falls before this
# stale anchor and reads as reconciled. Reproduced against PR #512's ordering
# extended with the revert `confirm_pr_draft` performs: round one is `dirty`
# (correctly), and round two — bounded past the revert — was `clean` before
# this fix and stays `dirty` after it (test/reconciliation-gate.test.sh).
#
# So a `ready_for_review` event only counts as "the pull request last left
# draft" here if no `convert_to_draft` event follows it at or before
# NOT_AFTER — i.e. it was never subsequently undone within the window this
# read is allowed to see. A `convert_to_draft` after NOT_AFTER (still in
# progress, or belonging to a later round) does not count against it, the
# same way a `ready_for_review` after NOT_AFTER already does not.
#
# Empty NOT_AFTER means unbounded, which is the pre-#533-fix behaviour and is
# kept only so a caller that genuinely has no round to bound by (a test
# asserting the raw rule) can ask for it. Passing one is not optional for a
# caller that runs after a flip it performed itself.
_reconciliation_gate_anchor() {
  local slug="$1" number="$2" not_after="${3:-}" gh_bin="${RECONCILIATION_GATE_GH:-gh}"
  local events anchor
  events="$("$gh_bin" api "repos/$slug/issues/$number/timeline" --paginate \
              --jq '.[] | select((.event == "ready_for_review" or .event == "convert_to_draft") and .created_at != null)
                        | {event, at: .created_at}' \
              2>/dev/null)" || return 1
  # jq rather than `sort | tail -n1` for the maximum, so the NOT_AFTER bound
  # and `_reconciliation_gate_comments`' own `.at > $anchor` filter compare
  # these timestamps the same byte-wise way; `sort`'s collation is locale-
  # dependent and jq's is not, and an anchor chosen under one rule then
  # applied under the other is exactly the kind of disagreement this gate
  # must not have.
  #
  # `events` is one JSON object per line (the same shape
  # `_reconciliation_gate_comments` streams in) rather than an aggregate, so
  # a `--paginate` read past one page does not silently disagree with itself
  # — the aggregation below happens once, over every page slurped together.
  anchor="$(jq -s -r --arg cutoff "$not_after" '
      map(select($cutoff == "" or .at <= $cutoff)) as $bounded
      | ($bounded | map(select(.event == "convert_to_draft")) | map(.at)) as $reverted_at
      | ($bounded
         | map(select(.event == "ready_for_review"))
         | map(select(. as $r | ($reverted_at | map(select(. > $r.at)) | length) == 0))
         | map(.at))
      | max // ""' <<<"$events" 2>/dev/null)" || return 1
  if [[ -n "$anchor" ]]; then
    printf '%s' "$anchor"
    return 0
  fi
  "$gh_bin" api "repos/$slug/pulls/$number" --jq '.created_at // empty' 2>/dev/null
}

# _reconciliation_gate_comments SLUG NUMBER ANCHOR
# Print a compact JSON array of `{id, at, body, bot}` for every general PR
# comment (`/issues/<number>/comments`, where `gh pr comment` files them)
# whose `created_at` is strictly after ANCHOR. `id` is the issue-comment id
# the `<!-- agent-ops:reconciles comment=<id> -->` convention refers to.
# Returns non-zero, printing nothing, when the API could not be asked at all.
#
# Every comment is streamed one object per line first — `gh api --jq` has no
# way to bind an `--arg` of its own into the filter it runs, unlike a local
# `jq` call — and the ANCHOR filter is applied afterwards, over the slurped
# array, the same split every `gh api --paginate` read in this codebase uses
# (see scripts/gather-review-feedback.sh's own header for why streaming
# rather than aggregating inside `--jq` matters past one page).
_reconciliation_gate_comments() {
  local slug="$1" number="$2" anchor="$3" gh_bin="${RECONCILIATION_GATE_GH:-gh}" lines
  lines="$("$gh_bin" api "repos/$slug/issues/$number/comments" --paginate \
             --jq '.[] | {id, at: .created_at, body: (.body // ""),
                          bot: (((.user.type // "User") == "Bot")
                                or (.user.login | endswith("[bot]"))
                                or (.performed_via_github_app != null))}' \
             2>/dev/null)" || return 1
  jq -s -c --arg anchor "$anchor" '[.[] | select(.at > $anchor)]' <<<"$lines" 2>/dev/null || return 1
}

# reconciliation_gate PR_URL [NOT_AFTER]
# Print `clean`, `dirty<TAB>reason`, or `unknown<TAB>reason`. Exit 0 for
# clean or unknown, 1 for dirty — the same shape `lib/closing-keyword-gate.sh`
# reports, so a caller can fold it into the same handoff gate. NOT_AFTER
# bounds which `ready_for_review` event is taken as the anchor; every caller
# that runs after a flip of its own must pass its round's start time, or the
# anchor is the flip it is checking (see `_reconciliation_gate_anchor`).
#   clean    every non-pipeline (human) comment posted since the pull request
#             last left draft is reconciled — cited by a
#             `<!-- agent-ops:reconciles comment=<id> -->` line in some
#             pipeline comment since — or there were none.
#   dirty    at least one human comment posted since then carries no such
#             citation: a requested change silently dropped rather than
#             implemented or contested.
#   unknown  the question could not be put: the timeline, the creation time,
#             or the comment list could not be read. See the header for why
#             that does not itself refuse the handoff (the same "could not
#             ask is not a failure" contract `lib/closing-keyword-gate.sh`
#             already keeps).
reconciliation_gate() {
  local url="${1:-}" not_after="${2:-}" parts slug number anchor comments marker rprefix
  local human reconciled unreconciled named

  if [[ -z "$url" ]] || ! parts="$(_reconciliation_gate_pr_parts "$url")"; then
    printf 'dirty\tno pull request URL to check'
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  if ! anchor="$(_reconciliation_gate_anchor "$slug" "$number" "$not_after")"; then
    printf 'unknown\tcould not read %s'\''s timeline to find when it last left draft' "$url"
    return 0
  fi
  if [[ -z "$anchor" ]]; then
    printf 'unknown\tcould not establish when %s last left draft — no ready_for_review event and no readable creation time' "$url"
    return 0
  fi

  if ! comments="$(_reconciliation_gate_comments "$slug" "$number" "$anchor")" \
     || ! jq -e 'type == "array"' <<<"$comments" >/dev/null 2>&1; then
    printf 'unknown\tcould not read %s'\''s comments posted since %s' "$url" "$anchor"
    return 0
  fi

  marker="${PIPELINE_COMMENT_MARKER_PREFIX:-<!-- agent-ops:pipeline-comment}"
  rprefix="${PIPELINE_RECONCILES_MARKER_PREFIX:-<!-- agent-ops:reconciles}"

  human="$(jq -r --arg marker "$marker" \
    '.[] | select(.bot | not) | select((.body | contains($marker)) | not) | (.id | tostring)' \
    <<<"$comments" 2>/dev/null)"
  if [[ -z "$human" ]]; then
    printf 'clean'
    return 0
  fi

  reconciled="$(jq -r --arg marker "$marker" --arg rx "${rprefix#<!-- } comment=([0-9]+)" \
    '[.[] | select(.body | contains($marker)) | .body
          | [scan($rx)] | map(.[0])]
     | flatten | .[]' \
    <<<"$comments" 2>/dev/null)"

  unreconciled="$(comm -23 <(sort -u <<<"$human") <(sort -u <<<"$reconciled"))"
  if [[ -z "$unreconciled" ]]; then
    printf 'clean'
    return 0
  fi

  # Named as permalinks, not as bare ids or a count. This string is the whole
  # of what reaches the requirement 32a handback and, through it, the next
  # round's Reviewer: it has to be enough to *act* on, or a fail-closed gate
  # becomes a loop that refuses the same pull request every hour without ever
  # saying which comment to answer. The `#issuecomment-<id>` fragment carries
  # the id the citation itself needs, so one form serves both the human
  # reading the handback and the Reviewer writing the reply.
  named="$(while IFS= read -r id; do
             [[ -n "$id" ]] && printf '%s#issuecomment-%s\n' "$url" "$id"
           done <<<"$unreconciled")"

  printf 'dirty\thuman comment(s) posted on %s since it last left draft (%s) carry no %s comment=<id> --> line answering them: %s' \
    "$url" "$anchor" "$rprefix" "$(paste -sd', ' <<<"$named")"
  return 1
}
