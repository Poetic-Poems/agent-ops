#!/usr/bin/env bash
#
# lib/handoff.sh — the moment a pull request stops being the pipeline's and
# becomes the human's, made a fact rather than a claim (requirement 31a).
#
# Requirement 31 gives the Reviewer one irreversible action: once CI is green
# and the PR is mergeable, it runs `gh pr ready`. That single call is the whole
# handoff — everything before it is the pipeline talking to itself, and
# everything after it is a human's queue. Requirement 32 then has the Reviewer
# *report* what it did, and the Script logs `pr-ready` from that report.
#
# Those are two different things, and treating the report as the deed is how a
# finished PR disappears. It happened: a Reviewer answered
# `{"status": "ready", "ci": "passing"}` for a PR whose work was complete and
# whose checks were green, never ran `gh pr ready`, and the Script logged
# `pr-ready` and moved on. The PR stayed a draft — invisible to the human, who
# is watching for review requests, and invisible to the log, which recorded a
# successful handoff. Three hours later the abandoned-drafts source (requirement
# 3e) correctly re-detected it as a stalled draft and paid an Implementor and a
# Reviewer to finish work that was already finished, at a fresh head SHA, which
# is a fresh ref no block covers — so it would have done that on the hour,
# indefinitely, each round looking productive.
#
# What makes this class of bug expensive is that no component is in a position
# to notice it. The Reviewer believes it handed off. The Script believes the
# Reviewer. The log agrees with both. Only GitHub disagrees, and nobody asked
# it. So this file asks it: the verdict stays the Reviewer's — it is the only
# actor that has read the diff — but whether the PR left draft is checked
# against the API, and the check is cheap enough (one field on one PR) to make
# unconditionally.
#
# The Script also *completes* a handoff the Reviewer left undone rather than
# failing it. The expensive, model-shaped half of requirement 31 is the
# judgement "this is ready"; `gh pr ready` is mechanism, and the Script can
# perform mechanism deterministically. Failing instead would put a PR the
# Reviewer has certified in front of a human as a problem, which is the outcome
# requirement 32a exists to avoid.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail` and a library that re-sets options silently
# changes its caller.
#
# Environment:
#   HANDOFF_GH  override `gh` (tests stub it).

# _handoff_draft_flag PR_URL
# Print `true` or `false` — GitHub's own answer to whether the PR is a draft.
# Returns non-zero, printing nothing, when the answer could not be had: an
# unreachable API, a deleted PR, an authentication failure, or any reply that is
# not one of the two booleans. The caller must not read "could not ask" as
# "not a draft"; that is the assumption this whole file exists to remove.
_handoff_draft_flag() {
  local url="$1" gh_bin="${HANDOFF_GH:-gh}" flag
  flag="$("$gh_bin" pr view "$url" --json isDraft --jq '.isDraft' 2>/dev/null)" || return 1
  case "$flag" in
    true|false) printf '%s' "$flag" ;;
    *) return 1 ;;
  esac
}

# confirm_pr_ready PR_URL
# Ensure the pull request is genuinely out of draft, and say what that took.
#
# Prints exactly one word:
#   already   the Reviewer performed the handoff itself — the ordinary path,
#             and the only one that costs nothing but the check.
#   flipped   the PR was still a draft; this call ran `gh pr ready` and GitHub
#             now agrees it is not. The work is handed off, but the Reviewer
#             did not do it, which is worth a warning in the log.
#   failed    the PR is still a draft after the attempt, or its state could not
#             be read at all.
#
# Exit status is 0 for `already` and `flipped`, 1 for `failed`, so a caller may
# branch on the status and log the word.
#
# `failed` is deliberately also the answer when the API cannot be reached. The
# alternative — assume the Reviewer was right and log `pr-ready` — is exactly
# the silent strand above, and the cost of being wrong the other way is one
# blocked item that the Enabler re-examines (requirement 32a), not a human
# interruption. Fail towards the state something else will look at.
confirm_pr_ready() {
  local url="${1:-}" gh_bin="${HANDOFF_GH:-gh}" flag

  if [[ -z "$url" ]]; then
    printf 'failed'
    return 1
  fi

  if ! flag="$(_handoff_draft_flag "$url")"; then
    printf 'failed'
    return 1
  fi
  if [[ "$flag" == "false" ]]; then
    printf 'already'
    return 0
  fi

  # The flip's own exit status is not the answer — `gh pr ready` can report
  # success on a PR that stays a draft (and does report failure on races that
  # nonetheless land). Re-reading the flag is the answer, and it doubles as the
  # retry for a first read that was merely unlucky.
  "$gh_bin" pr ready "$url" >/dev/null 2>&1 || true

  if ! flag="$(_handoff_draft_flag "$url")"; then
    printf 'failed'
    return 1
  fi
  if [[ "$flag" == "false" ]]; then
    printf 'flipped'
    return 0
  fi

  printf 'failed'
  return 1
}
