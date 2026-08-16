#!/usr/bin/env bash
#
# lib/approver.sh — the Approver stage's own decision primitives (D18 WI-5,
# agent-ops#408; design: docs/reviews/2026-08-14-autonomy-investigation.md
# §5.2/§5.3).
#
# `merge_autonomy` above `human` (lib/merge-autonomy.sh) needs a non-author
# identity to hold review rights, since GitHub refuses self-approval and this
# pipeline authors as its own configured owner — that identity is the
# "Pullwright Approver" GitHub App, whose installation-token minting
# lib/approver-token.sh already provides (D18 WI-4). This file is what turns
# a minted token into an actual judgement: which tier a pull request's
# complexity grade routes to, whether a run of consecutive refusals has
# reached the point a Standard/High engagement must yield to a critical-tier
# adjudication instead, and the two GitHub writes the Script performs on the
# Approver's own verdict — never the model's.
#
# Four tiers, mirroring the owner's own delegation ladder (§5.2):
#   trivial       complexity:low — deterministic, no model call at all. The
#                 grading rubric (docs/IMPLEMENTATION-PIPELINE-SPEC.md
#                 requirement 26a) already forces anything touching
#                 concurrency, security, CI/workflow machinery or shared
#                 library code to grade `high`, never `low` — so the
#                 protected-paths classifier a later work item (WI-7) adds is
#                 a second fence around ground the complexity label already
#                 fences off, not this tier's only guard.
#   standard      complexity:medium — one engagement on `approver_model_default`.
#   high          complexity:high — one engagement on `approver_model_complex`
#                 (falling back to the default tier when unset, the same
#                 escalation-off convention `reviewer_model_complex` uses).
#   adjudication  triggered by refuse-streak, not by complexity — see
#                 `approver_refuse_streak` below — always on
#                 `approver_model_critical` (falling back down the same
#                 chain), regardless of what tier the ordinary grade would
#                 have chosen.
#
# Refuse-wins, structurally: a refusal is posted as a real `REQUEST_CHANGES`
# review from the Approver identity (`approver_post_review`), so GitHub
# itself holds the pull request at `CHANGES_REQUESTED` and the existing
# `review-feedback` source picks it up next cycle exactly as it already picks
# up a human's own `CHANGES_REQUESTED` — no new work source, no new gate. An
# approval is the ordinary `APPROVE` review on the same pull request; the
# Script never merges either way (D18's cardinal rule: the model never holds
# merge rights, and neither does this file — see agent-cycle.sh's own callers
# for why `agent-merges-routine`/`agent-merges-all` land no differently from
# `agent-approves` until a later work item's arming step exists).
#
# The refuse streak is derived from the reviews list itself, read fresh at
# the moment of the decision, the same "ask GitHub, don't keep a private
# count that can drift" discipline `lib/handoff.sh` and `lib/review-gate.sh`
# already apply, and the same move agent-ops#449 made for
# `could_not_request` — a second, independent counter this file might keep
# instead would need its own reconciliation the moment a cycle dies mid-write
# or two nodes touch the same pull request, and the reviews list already
# cannot disagree with itself.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (agent-cycle.sh runs under `set -euo pipefail`;
# a test, `set -uo pipefail`) owns those.
#
# Environment:
#   APPROVER_GH  override `gh` (tests stub it).

# approver_tier_for COMPLEXITY
# Print `trivial`, `standard` or `high` for `low`, `medium` or `high`. Any
# other value — including empty — reads as `standard`, the same
# fail-toward-the-middle-tier caution the resolved `complexity` this reads
# already earned one level up (`reviewer_complexity`'s own raise-never-lower
# resolution): this function trusts its caller handed it an already-resolved
# grade, and only degrades gracefully if it did not.
approver_tier_for() {
  case "${1:-}" in
    low) printf 'trivial' ;;
    high) printf 'high' ;;
    *) printf 'standard' ;;
  esac
}

# approver_model_for_tier TIER MODEL_DEFAULT MODEL_COMPLEX
# Print the model an ordinary (non-adjudication) engagement launches on:
# MODEL_COMPLEX for `high`, MODEL_DEFAULT otherwise. `trivial` never reaches
# this — the caller skips the model call entirely — and adjudication always
# launches on MODEL_CRITICAL directly, so only the two ordinary tiers are
# resolved here.
approver_model_for_tier() {
  local tier="${1:-}" default_m="${2:-}" complex_m="${3:-}"
  if [[ "$tier" == "high" ]]; then
    printf '%s' "$complex_m"
  else
    printf '%s' "$default_m"
  fi
}

# _approver_pr_parts PR_URL
# Print `owner/repo<TAB>number`, or return non-zero printing nothing. The
# same shape lib/handoff.sh's and lib/review-gate.sh's own private helpers
# compute, duplicated rather than depended on so this file sources and tests
# standalone, matching their own stated reason for the same duplication.
_approver_pr_parts() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  printf '%s/%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# approver_refuse_streak PR_URL LOGIN
# Print how many `CHANGES_REQUESTED` reviews LOGIN has most recently
# submitted on PR_URL, counting back from the newest and stopping at the
# first `APPROVED` review from the same login (or the list's start) — the
# number of refuse cycles in a row, right now. Prints `0` when LOGIN is empty
# or has never reviewed this pull request, or when its most recent review
# approved. `COMMENTED`/`DISMISSED` reviews from LOGIN neither extend nor
# reset the streak — they carry no standing verdict.
#
# Returns non-zero, printing nothing, when the reviews list could not be read
# at all — the caller must not read that as `0`, the same "could not ask"
# convention every other reader in this codebase's review-state readers
# (lib/handoff.sh's `_handoff_*` family) follows.
approver_refuse_streak() {
  local url="${1:-}" login="${2:-}" gh_bin="${APPROVER_GH:-gh}"
  local parts slug number lines

  if [[ -z "$login" ]]; then
    printf '0'
    return 0
  fi
  if [[ -z "$url" ]] || ! parts="$(_approver_pr_parts "$url")"; then
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  # One JSON object per line, not one array per page — `--paginate`
  # concatenates a separate document per page, so an aggregate computed
  # inside `--jq` would be computed per page and silently disagree with
  # itself past thirty reviews (the same trap `_handoff_latest_reviews`'s own
  # header documents). The aggregation happens below, over every page at once.
  #
  # The login filter runs in the second jq call, not here: `gh api --jq`
  # takes one query string and nothing else — it has no `--arg` of its own to
  # parameterise that query with, so a login can only be woven in by string
  # interpolation (fragile the moment a login carries a character jq's
  # string-literal syntax cares about) or, as here, left for a real `jq`
  # invocation downstream that has genuine `--arg` support.
  lines="$("$gh_bin" api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null)
                      | {login: .user.login, at: .submitted_at, state: .state}' \
            2>/dev/null)" || return 1

  jq -s -r --arg l "$login" '
    map(select(.login == $l))
    | sort_by(.at) | reverse
    | reduce .[] as $r ({stopped: false, count: 0};
        if .stopped then .
        elif $r.state == "CHANGES_REQUESTED" then {stopped: false, count: (.count + 1)}
        elif $r.state == "APPROVED" then {stopped: true, count: .count}
        else . end)
    | .count
  ' <<<"$lines" 2>/dev/null || return 1
}

# approver_post_review PR_URL EVENT BODY TOKEN
# POST a review to PR_URL from the Approver identity, authenticated with
# TOKEN (an installation token from `approver_token_get`, never the owner's
# own PAT — the whole reason a separate identity exists). EVENT is `APPROVE`
# or `REQUEST_CHANGES`. Prints nothing; returns 0 only on a real 2xx from
# GitHub, non-zero otherwise — the caller must not read a failure as a posted
# review.
#
# `GH_TOKEN` is set only for this one invocation (a leading assignment on the
# command, not `export`), so the override cannot leak into any later `gh`
# call this process makes under the owner's own login.
approver_post_review() {
  local url="${1:-}" event="${2:-}" body="${3:-}" token="${4:-}" gh_bin="${APPROVER_GH:-gh}"
  local parts slug number

  [[ -n "$token" && -n "$event" ]] || return 1
  if [[ -z "$url" ]] || ! parts="$(_approver_pr_parts "$url")"; then
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  GH_TOKEN="$token" "$gh_bin" api -X POST "repos/$slug/pulls/$number/reviews" \
    -f "event=$event" -f "body=$body" >/dev/null 2>&1
}

# approver_prior_refusal_bodies PR_URL LOGIN
# Print LOGIN's own `REQUEST_CHANGES` review bodies on PR_URL, oldest first,
# each preceded by its submission timestamp — what an adjudication engagement
# reads to judge whether a refusal's own reasons were ever actually answered.
#
# Never fails: prints nothing when LOGIN has none, or the list could not be
# read. Adjudication only ever runs once `approver_refuse_streak` has already
# established the streak that triggers it, so an unreadable list here costs
# missing context in the prompt, not a wrong decision about whether to run.
approver_prior_refusal_bodies() {
  local url="${1:-}" login="${2:-}" gh_bin="${APPROVER_GH:-gh}" parts slug number lines
  [[ -n "$url" && -n "$login" ]] || return 0
  parts="$(_approver_pr_parts "$url")" || return 0
  IFS=$'\t' read -r slug number <<<"$parts"
  # Same split as approver_refuse_streak: `gh api --jq` has no `--arg` of its
  # own, so the login filter runs in the second, genuine `jq` call below.
  lines="$("$gh_bin" api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null and .state == "CHANGES_REQUESTED")
                      | {login: .user.login, at: .submitted_at, body: (.body // "")}' \
            2>/dev/null)" || return 0
  jq -s -r --arg l "$login" '
    map(select(.login == $l))
    | sort_by(.at)[]
    | "### " + .at + "\n\n" + .body
  ' <<<"$lines" 2>/dev/null || return 0
}
