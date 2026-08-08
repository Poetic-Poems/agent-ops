#!/usr/bin/env bash
#
# lib/preflight.sh — the done-check the Script runs on the item a cycle just
# claimed, before it pays for an Implementor engagement (issue #245).
#
# `lib/work-gone.sh` already answers "is this item's work gone?" for the
# blocked set, from digests the cycle gathers anyway — an issue closed, a pull
# request closed or merged, a register row resolved or not-debt. A freshly
# claimed candidate is not blocked, but the question is identical, and
# TD-PPpfid-26072801 (re-selected and re-implemented 21 hours after it
# merged) shows it is exactly as live for a fresh claim as for a stalled one:
# the register said `resolved` the whole time, and nothing asked it until the
# Implementor stage did — a full engagement to learn what one `gh` read
# already sitting in the cycle's own gathered state would have said.
#
# `preflight_done_reason` is a one-item call into that same machinery, not a
# second implementation of it: it wraps `work_gone_clearances` around a
# synthetic one-entry blocked list, then — for every item but a finishing
# source's own `pr-<n>-…`-shaped one, which `work_gone_clearances` just asked
# about — checks the cycle's own
# `source_states_json` for an open pull request already carrying this claim's
# own branch (the "stale claim, previous cycle's branch/PR already exists"
# shape a lost-then-recovered claim race can produce). Both halves are pure —
# they read nothing themselves — so together they need no corroboration guard
# (requirement 34d exists to catch a model's fabricated citation; there is no
# model in either path to fabricate one) and are fit to feed `log_item_void`
# directly.
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
# and void every ordinary claim on its first tick. The three sources whose
# branch and PR predate the claim — review-feedback, merge-conflicts,
# abandoned-drafts, the ones whose branch this cycle did not just create — are
# the only ones an ancestry check can mean anything for, and
# `preflight_existing_branch_source` is that gate.
#
# Sourced, never executed: this file sets no shell options, because
# agent-cycle.sh runs under `set -euo pipefail`. `preflight_done_reason`
# depends on `work_gone_clearances` (lib/work-gone.sh), sourced first.

# The three sources whose branch (and PR) already existed before this cycle's
# claim — the Implementor prompt's own "the branch and the PR exist" sources.
# Space-padded so a plain substring test (below) cannot mistake, say,
# "merge-conflicts" for a source named "conflicts".
PREFLIGHT_EXISTING_BRANCH_SOURCES=" review-feedback merge-conflicts abandoned-drafts "

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
  local repo="$1" item="$2" branch="$3" states="$4" register="${5:-{\}}" blocked reason
  blocked="$(jq -nc --arg r "$repo" --arg i "$item" '[{repo: $r, item: $i}]')"
  reason="$(work_gone_clearances "$blocked" "$states" "$register" '{}' '{}' \
    | jq -r 'if length == 0 then "" else .[0].reason end' 2>/dev/null)"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
    return
  fi
  # A finishing source's item is already the pr-<n>-… shape the clearance
  # check above just asked about; every other item — an issue, a tech-debt
  # id, an alert ref, a review or plan ref — reaches here, and only for those
  # can an already-open PR on this claim's own branch be a stale-claim signal
  # rather than the very PR this cycle is about to raise. All of them are
  # minted a branch by the claim, so all of them can carry the signal.
  # `WORK_GONE_PR_RE` carries a named group written for jq's
  # Oniguruma engine, which POSIX ERE (`grep -E`) cannot compile — `grep -P`
  # is the same convention scripts/close-void-github-items.sh already uses
  # for this constant.
  grep -qP "$WORK_GONE_PR_RE" <<<"$item" && return
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
