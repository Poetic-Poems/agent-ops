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
#     event — the moment it last left draft — falling back to the pull
#     request's own creation time when it has never left draft before;
#   - a "human comment" is any general PR comment (`/issues/<n>/comments`,
#     where `gh pr comment` files them) posted after that anchor, from a
#     non-Bot account, whose body does not carry
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
#   Reads PIPELINE_COMMENT_MARKER_PREFIX — source lib/pipeline-marker.sh
#   before this file, or before calling `reconciliation_gate`.

# _reconciliation_gate_pr_parts PR_URL
# Print `owner/repo<TAB>number`, or return non-zero printing nothing. The same
# shape every other lib/*-gate.sh file computes, duplicated rather than
# depended on so this file sources and tests standalone.
_reconciliation_gate_pr_parts() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  printf '%s/%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# _reconciliation_gate_anchor SLUG NUMBER
# Print the timestamp comments are read "since": the pull request's most
# recent `ready_for_review` timeline event, or — when it has never left draft
# before, a first round — its own creation time. Returns non-zero, printing
# nothing, only when the timeline itself could not be read at all; an empty
# but readable timeline is not a failure, it is the first-round case, and
# falls through to the creation-time read.
_reconciliation_gate_anchor() {
  local slug="$1" number="$2" gh_bin="${RECONCILIATION_GATE_GH:-gh}" events anchor
  events="$("$gh_bin" api "repos/$slug/issues/$number/timeline" --paginate \
              --jq '.[] | select(.event == "ready_for_review" and .created_at != null) | .created_at' \
              2>/dev/null)" || return 1
  anchor="$(sort <<<"$events" | tail -n1)"
  if [[ -n "$anchor" ]]; then
    printf '%s' "$anchor"
    return 0
  fi
  "$gh_bin" api "repos/$slug/pulls/$number" --jq '.created_at // empty' 2>/dev/null
}

# _reconciliation_gate_comments SLUG NUMBER ANCHOR
# Print a compact JSON array of `{id, body, bot}` for every general PR
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
                          bot: (((.user.type // "User") == "Bot") or (.user.login | endswith("[bot]")))}' \
             2>/dev/null)" || return 1
  jq -s -c --arg anchor "$anchor" '[.[] | select(.at > $anchor)]' <<<"$lines" 2>/dev/null || return 1
}

# reconciliation_gate PR_URL
# Print `clean`, `dirty<TAB>reason`, or `unknown<TAB>reason`. Exit 0 for
# clean or unknown, 1 for dirty — the same shape `lib/closing-keyword-gate.sh`
# reports, so a caller can fold it into the same handoff gate.
#   clean    every non-pipeline (human) comment posted since the pull request
#             last left draft is reconciled — cited by a
#             `<!-- agent-ops:reconciles comment=<id> --> line in some
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
  local url="${1:-}" parts slug number anchor comments marker
  local human reconciled unreconciled

  if [[ -z "$url" ]] || ! parts="$(_reconciliation_gate_pr_parts "$url")"; then
    printf 'dirty\tno pull request URL to check'
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  if ! anchor="$(_reconciliation_gate_anchor "$slug" "$number")"; then
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

  human="$(jq -r --arg marker "$marker" \
    '.[] | select(.bot | not) | select((.body | contains($marker)) | not) | (.id | tostring)' \
    <<<"$comments" 2>/dev/null)"
  if [[ -z "$human" ]]; then
    printf 'clean'
    return 0
  fi

  reconciled="$(jq -r --arg marker "$marker" \
    '[.[] | select(.body | contains($marker)) | .body
          | [scan("agent-ops:reconciles comment=([0-9]+)")] | map(.[0])]
     | flatten | .[]' \
    <<<"$comments" 2>/dev/null)"

  unreconciled="$(comm -23 <(sort -u <<<"$human") <(sort -u <<<"$reconciled"))"
  if [[ -z "$unreconciled" ]]; then
    printf 'clean'
    return 0
  fi

  printf 'dirty\thuman comment(s) posted on %s since it last left draft (%s) carry no <!-- agent-ops:reconciles comment=<id> --> line answering them: comment id(s) %s' \
    "$url" "$anchor" "$(paste -sd', ' <<<"$unreconciled")"
  return 1
}
