#!/usr/bin/env bash
#
# lib/preflight.sh — the done-check the Script runs on the item a cycle just
# claimed, before it pays for an Implementer engagement (issue #245).
#
# `lib/work-gone.sh` already answers "is this item's work gone?" for the
# blocked set, from digests the cycle gathers anyway — an issue closed, a pull
# request closed or merged, a register row resolved or not-debt. A freshly
# claimed candidate is not blocked, but the question is identical, and
# TD-PPpfid-26072801 (re-selected and re-implemented 21 hours after it
# merged) shows it is exactly as live for a fresh claim as for a stalled one:
# the register said `resolved` the whole time, and nothing asked it until the
# Implementer stage did — a full engagement to learn what one `gh` read
# already sitting in the cycle's own gathered state would have said.
#
# `preflight_done_reason` is a one-item call into that same machinery, not a
# second implementation of it: it wraps `work_gone_clearances` around a
# synthetic one-entry blocked list. Pure — it reads nothing itself — so it
# needs no corroboration guard (requirement 34d exists to catch a model's
# fabricated citation; there is no model in this path to fabricate one) and
# is fit to feed `log_item_void` directly: every fact it reports (an issue
# closed, a pull request closed or merged, a register row resolved), once
# true, stays true, which is what makes a terminal void safe on it.
#
# `preflight_defer_reason` is the signal that deliberately does NOT feed a
# void (#279): an open pull request already carrying this claim's own branch,
# read from the cycle's own `source_states_json` (the "stale claim, previous
# cycle's branch/PR already exists" shape a lost-then-recovered claim race
# can produce). It is the one fact in this file that can become false again —
# that pull request may close unmerged tomorrow — and its usual cause is
# narrower still: the digest is sampled before the Co-Ordinator engagement,
# so by claim time the pull request it shows is often already gone, and a
# branch claim is create-only (`lib/claim.sh`), so winning it proves the ref
# did not exist at claim time at all. A void is terminal (requirement 34h:
# never re-examined; only a human clears one), so voiding on a reversible,
# probably-stale fact would retire live items silently. The caller instead
# releases the claim and ends the cycle — the item is free again the next
# cycle, judged against a fresh digest. The check stays, unreachable as it
# nearly is, because it is cheap, pure, and the state it names is one this
# cycle must not work either way.
#
# `preflight_branch_merged_reason` is the other named done-signal — "the
# work-order branch is already merged" — and it is deliberately kept apart
# from the pure functions above: it is impure, one live `gh api compare` call
# against the *target* repository (no local clone needed, so it does not
# conflict with running pre-flight before the workspace clone). It is also
# deliberately never called for an ordinary issues/tech-debt claim: the
# Script creates that branch fresh, at the default branch's own head, as the
# claim itself (see agent-cycle.sh's "Branch" step), so comparing it against
# that same head the moment the claim is won would always read "identical"
# and void every ordinary claim on its first tick. The four sources whose
# branch and PR predate the claim — review-feedback, merge-conflicts,
# dequeued, abandoned-drafts, the ones whose branch this cycle did not just
# create — are the only ones an ancestry check can mean anything for, and
# `preflight_existing_branch_source` is that gate.
#
# `preflight_review_feedback_reason` is a third named done-signal, and the
# reason `work_gone_clearances`'s own PR-shaped clearance is not enough for a
# `pr-<n>-review-<id>` item (issue #1360): that clearance only asks whether
# the pull request itself has left the open-PR digest, never whether the
# *specific* review round this ref names is still the reviewer's standing
# position. A `CHANGES_REQUESTED` review answered and then superseded by an
# `APPROVED` from the same reviewer — including a bot reviewer, whose own
# approval is exactly the case requirement 34a's own `gather-review-
# feedback.sh` comment describes as unreachable any other way — leaves the
# pull request itself open throughout, so `work_gone_clearances` never fires,
# and a claim of the same stale ref (most often replayed from a non-selected
# node's `expensive-gather` cache, requirement 48, which is not re-verified
# before a claim proceeds) would otherwise burn a full Implementer engagement
# on a round that is already closed. Like `preflight_branch_merged_reason`,
# it is impure — one live `gh api` read of the pull request's own reviews —
# and gated to the same `review-feedback` source for the same reason: it
# costs one call, paid once, for the single freshly claimed item, immediately
# before the engagement it would otherwise waste.
#
# Sourced, never executed: this file sets no shell options, because
# agent-cycle.sh runs under `set -euo pipefail`. `preflight_done_reason`
# depends on `work_gone_clearances` (lib/work-gone.sh), sourced first;
# `preflight_review_feedback_reason` likewise depends on `handoff_latest_
# positions` (lib/handoff.sh), also sourced first.

# The four sources whose branch (and PR) already existed before this cycle's
# claim — the Implementer prompt's own "the branch and the PR exist" sources.
# Space-padded so a plain substring test (below) cannot mistake, say,
# "merge-conflicts" for a source named "conflicts".
PREFLIGHT_EXISTING_BRANCH_SOURCES=" review-feedback merge-conflicts dequeued abandoned-drafts "

# preflight_existing_branch_source SOURCE — true iff SOURCE's branch predates
# the claim, the only shape `preflight_branch_merged_reason` can answer for.
preflight_existing_branch_source() {
  [[ "$PREFLIGHT_EXISTING_BRANCH_SOURCES" == *" $1 "* ]]
}

# preflight_done_reason REPO ITEM BRANCH STATES_JSON [REGISTER_JSON]
#
# Print the reason the item is already done, or nothing when it is not (or
# cannot be told). REPO/ITEM/BRANCH are the just-claimed candidate's own
# fields; STATES_JSON is the cycle's `source_states_json` (already gathered
# for every repo it walked, well before the claim); REGISTER_JSON is `{}`
# unless the item is register-shaped, in which case the caller has fetched
# its one row fresh (the freshly claimed item was never a member of the
# blocked set that `register_status_json` is otherwise scoped to).
preflight_done_reason() {
  local repo="$1" item="$2" branch="$3" states="$4" register="${5:-{\}}" blocked
  blocked="$(jq -nc --arg r "$repo" --arg i "$item" '[{repo: $r, item: $i}]')"
  work_gone_clearances "$blocked" "$states" "$register" '{}' '{}' \
    | jq -r 'if length == 0 then "" else .[0].reason end' 2>/dev/null
}

# preflight_defer_reason REPO ITEM BRANCH STATES_JSON
#
# Print the reason the claim should be deferred — released and left for a
# later cycle, never voided (see the header) — or nothing. A finishing
# source's item is already the pr-<n>-… shape `work_gone_clearances` asked
# about; every other item — an issue, a tech-debt id, an alert ref, a review
# or plan ref — reaches the open-PR check, and only for those can an
# already-open PR on this claim's own branch be a stale-claim signal rather
# than the very PR this cycle is about to raise. All of them are minted a
# branch by the claim, so all of them can carry the signal.
preflight_defer_reason() {
  local repo="$1" item="$2" branch="$3" states="$4"
  # `WORK_GONE_PR_RE` carries a named group written for jq's
  # Oniguruma engine, which POSIX ERE (`grep -E`) cannot compile — `grep -P`
  # is the same convention scripts/close-void-github-items.sh already uses
  # for this constant.
  grep -qP "$WORK_GONE_PR_RE" <<<"$item" && return 0
  preflight_open_pr_reason "$repo" "$branch" "$states"
}

# preflight_open_pr_reason REPO BRANCH STATES_JSON — an open pull request
# already carrying BRANCH, read from the cycle's own pre-claim digest. Pure:
# it asks nothing of GitHub itself, only of the `open_prs` digest
# `scripts/gather-source-state.sh` already sampled.
#
# Always succeeds, printing nothing for input it cannot read — the same
# discipline `work_gone_clearances` states for itself and for the same reason:
# its caller is a mid-cycle `set -e` command substitution, so a malformed
# digest must cost a done-signal, never the cycle.
preflight_open_pr_reason() {
  local repo="$1" branch="$2" states="$3"
  [[ -n "$branch" ]] || return 0
  jq -r --arg s "$repo" --arg b "$branch" '
    ([ .[] | select((.slug // "") == $s and .ok == true) ] | first) as $st
    | if $st == null then ""
      elif ([ ($st.open_prs // [])[] | select((.h // "") == $b) ] | length) > 0
      then "an open pull request already carries branch \($b)"
      else "" end' <<<"$states" 2>/dev/null || true
}

# preflight_branch_merged_reason SLUG DEFAULT_BRANCH BRANCH — the work-order
# branch is already merged into DEFAULT_BRANCH (the draft's work landed on
# the default branch some other way while it sat). One live `gh api compare`
# call against SLUG, never a local clone — see the header for why this is
# gated to `preflight_existing_branch_source` sources only.
#
# Environment: PREFLIGHT_GH overrides `gh` (tests stub it).
#
# Always prints nothing rather than fail: an unreadable comparison decides
# nothing, the same direction every other signal here already fails safe in.
preflight_branch_merged_reason() {
  local slug="$1" default_branch="$2" branch="$3" gh="${PREFLIGHT_GH:-gh}" status
  [[ -n "$slug" && -n "$default_branch" && -n "$branch" ]] || return 0
  status="$("$gh" api "repos/$slug/compare/$default_branch...$branch" --jq '.status' 2>/dev/null)" || return 0
  case "$status" in
    identical|behind) printf 'the branch is already merged into %s' "$default_branch" ;;
  esac
}

# `pr-<n>-review-<id>`: `gather-review-feedback.sh`'s own review-feedback ref
# shape, narrower than `lib/work-gone.sh`'s `WORK_GONE_PR_RE` (which matches
# every `pr-<n>-…` shape alike) because this one additionally names the
# specific review the ref was minted for.
PREFLIGHT_REVIEW_FEEDBACK_ITEM_RE='^pr-([0-9]+)-review-([0-9]+)$'

# preflight_review_feedback_reason SLUG ITEM — the review-feedback item's own
# blocking review has been superseded: re-fetch the pull request's reviews and
# recompute "the review currently blocking" via `lib/handoff.sh`'s
# `handoff_latest_positions` exactly as `gather-review-feedback.sh` does when
# deciding whether to offer the candidate at all (requirement 34a's one
# shared definition, called here without a bot filter, same as there — see
# that function's own comment on why a bot's `APPROVED` must count here).
# ITEM is the claimed item's own ref; anything not shaped like
# `pr-<n>-review-<id>` decides nothing.
#
# Depends on `lib/handoff.sh` being sourced first, same as `preflight_done_
# reason` depends on `lib/work-gone.sh` (see this file's own header) — true
# of every real caller (agent-cycle.sh sources handoff.sh well before this
# file) and of test/preflight.test.sh, which sources it for the same reason.
#
# Environment: PREFLIGHT_GH overrides `gh` (tests stub it).
#
# Always prints nothing rather than fail: an unreadable read, or a ref this
# function cannot parse, decides nothing — the same direction every other
# signal here already fails safe in.
preflight_review_feedback_reason() {
  local slug="$1" item="$2" gh="${PREFLIGHT_GH:-gh}" number review_id reviews latest_per_reviewer
  [[ -n "$slug" && -n "$item" ]] || return 0
  [[ "$item" =~ $PREFLIGHT_REVIEW_FEEDBACK_ITEM_RE ]] || return 0
  number="${BASH_REMATCH[1]}"
  review_id="${BASH_REMATCH[2]}"

  reviews="$("$gh" api "repos/$slug/pulls/$number/reviews" --paginate \
              --jq '.[] | select(.submitted_at != null)
                        | {id, state, at: .submitted_at, who: .user.login}' \
              2>/dev/null)" || return 0
  reviews="$(jq -s -c '.' <<<"$reviews" 2>/dev/null)" || return 0
  jq -e 'type == "array"' <<<"$reviews" >/dev/null 2>&1 || return 0

  latest_per_reviewer="$(handoff_latest_positions "$reviews" "who")" || return 0

  jq -r --arg rid "$review_id" '
    (map(select(.state == "CHANGES_REQUESTED")) | sort_by(.at) | last) as $blocking
    | if $blocking == null then "the review no longer blocks the pull request"
      elif ($blocking.id | tostring) != $rid
      then "the review no longer blocks the pull request"
      else "" end' <<<"$latest_per_reviewer" 2>/dev/null || true
}
