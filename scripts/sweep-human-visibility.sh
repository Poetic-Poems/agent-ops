#!/usr/bin/env bash
#
# scripts/sweep-human-visibility.sh — the periodic, deterministic half of
# agent-ops#242 (requirement 38): for every open, ready pull request this
# system raised, make sure a human whose turn it is has actually been asked,
# and nudge one who has been waiting too long without an answer.
#
# `lib/handoff.sh`'s `confirm_review_requested` and `ensure_human_reviewer`
# already run at the moment a Reviewer or an Enabler hands a pull request off
# (agent-cycle.sh, requirement 38a) — but that only fires on the cycle that
# performs the handoff. A pull request already sitting ready from an earlier
# cycle, or one this feature did not exist for yet, gets no such check unless
# something asks again later. This script is that later ask: run once per
# cycle, fleet-wide, over every such pull request regardless of what stage (if
# any) touched it this cycle — which *is* the periodic audit agent-ops#242
# asks for, made self-healing rather than merely reported: a violation this
# script can fix (a missing review request) it fixes in the same pass, so
# there is never a gap between "detected" and "corrected" for a human to fall
# through. The one exception is a pull request idle well past the point a live
# review request alone is working (requirement 38c) — that gets a nudge
# comment as well, because the poetic-fiddle #170 case (approved, green, and
# ignored for 6.8 days) shows a live request is necessary but was not always
# sufficient.
#
# For one repository, this lists every open, non-draft pull request carrying
# `pr_label` and, for each:
#   1. Re-confirms review from anyone CHANGES_REQUESTED-blocking it
#      (`confirm_review_requested`) — self-healing requirement 31b's own
#      promise for a pull request no Reviewer or Enabler touched this cycle.
#   2. Where nothing is blocking it, ensures a live review request exists at
#      all (`ensure_human_reviewer`) — requirement 38a's guarantee, kept
#      continuously rather than only at the moment of handoff.
#   3. Where the pull request is approved, mergeable and green, and has been
#      since before `human_nudge_idle_hours` ago, posts one nudge comment
#      naming `enabler_assignee` — requirement 38c — unless one is there
#      already (a marker comment makes this idempotent, not time-windowed).
#
# Fails safe throughout: any answer this script cannot get (a listing that
# errors, a pull request whose state cannot be read) is skipped with a
# `warning` action rather than guessed at. Two nodes sweeping the same
# repository at once is safe for the same reason lib/handoff.sh's own
# functions are: a review request or a comment either lands or it does not,
# and re-attempting a already-live one is a no-op both sides read the same way.
#
# Output: one JSON object per action on stdout —
#   {"action":"review-requested","pr_url":…,"reviewers":[…]}
#   {"action":"human-review-requested","pr_url":…,"reviewers":[…]}
#   {"action":"nudged","pr_url":…,"reviewer":…}
#   {"action":"warning","pr_url":…,"detail":…}
# The caller logs them; this script logs nothing itself. Exit 0 unless the
# arguments are unusable.
#
# Usage: sweep-human-visibility.sh <owner/repo> [cycle-id] [node-name]
# cycle-id and node-name stamp the nudge comment's header (requirement 9d,
# lib/pipeline-marker.sh) the same way every other pipeline-authored comment
# is stamped; both default to a placeholder a test or a manual run can ignore.
# Environment: SWEEP_GH overrides `gh` (tests stub it); AGENT_OPS_CONFIG
# overrides the config path, as agent-cycle.sh accepts it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
GH="${SWEEP_GH:-gh}"
HANDOFF_GH="$GH"
export HANDOFF_GH

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

slug="${1:-}"
cycle_id="${2:-sweep}"
node_name="${3:-unknown}"
if [[ -z "$slug" ]]; then
  echo "usage: sweep-human-visibility.sh <owner/repo> [cycle-id] [node-name]" >&2
  exit 64
fi

# config_defaults (issue #197) is the only place a default is written; see
# scripts/sweep-orphan-branches.sh for the same pattern and why.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

pr_label="$(cfg '.pr_label')"
assignee="$(cfg '.enabler_assignee')"
idle_hours="$(cfg '.human_nudge_idle_hours')"
[[ "$idle_hours" =~ ^[0-9]+(\.[0-9]+)?$ ]] || idle_hours=24

warn() { jq -nc --arg u "$1" --arg d "$2" '{action: "warning", pr_url: $u, detail: $d}'; }

# Nothing to request or nudge without someone to name — the same guard
# config_enabler_assignee_ok already enforces at startup when enabler_model is
# set, and the same silent no-op an Enabler disabled outright already is.
[[ -n "$assignee" ]] || exit 0

if ! prs="$("$GH" pr list -R "$slug" --state open --label "$pr_label" \
        --json url,isDraft --jq '.[] | select(.isDraft | not) | .url' 2>/dev/null)"; then
  warn "" "could not list $slug's open pull requests — sweeping nothing"
  exit 0
fi

while IFS= read -r pr_url; do
  [[ -n "$pr_url" ]] || continue

  rereview="$(confirm_review_requested "$pr_url")" || true
  rereview_state=""; rereview_who=""
  IFS=$'\t' read -r rereview_state rereview_who <<<"$rereview" || true
  case "$rereview_state" in
    requested)
      jq -nc --arg u "$pr_url" --arg w "$rereview_who" \
        '{action: "review-requested", pr_url: $u, reviewers: ($w | split(","))}'
      ;;
    failed)
      warn "$pr_url" "could not re-request review from ${rereview_who:-the reviewer(s)} still blocking it"
      ;;
  esac

  # Nothing CHANGES_REQUESTED-blocking it is exactly ensure_human_reviewer's
  # domain (requirement 38a) — a first review nobody has given, or an
  # approval nobody has acted on since.
  if [[ "$rereview_state" == "none" ]]; then
    human_state="$(ensure_human_reviewer "$pr_url" "$assignee")" || true
    human_who=""
    IFS=$'\t' read -r human_state human_who <<<"$human_state" || true
    case "$human_state" in
      requested)
        jq -nc --arg u "$pr_url" --arg w "$human_who" \
          '{action: "human-review-requested", pr_url: $u, reviewers: ($w | split(","))}'
        ;;
      failed)
        warn "$pr_url" "could not request review from ${human_who:-$assignee}"
        ;;
    esac
  fi

  # The idle nudge only makes sense once nothing is CHANGES_REQUESTED-blocking
  # the pull request — that state has its own actor (the Implementor,
  # answering the review) and its own clock, not this one's.
  [[ "$rereview_state" == "none" ]] || continue
  awk -v h="$idle_hours" 'BEGIN{exit !(h>0)}' || continue

  if ! pr_json="$("$GH" pr view "$pr_url" \
        --json reviewDecision,mergeable,statusCheckRollup,reviews,comments 2>/dev/null)" \
      || [[ -z "$pr_json" ]]; then
    warn "$pr_url" "could not read the pull request's state — skipping the idle check"
    continue
  fi

  [[ "$(jq -r '.reviewDecision // ""' <<<"$pr_json")" == "APPROVED" ]] || continue
  [[ "$(jq -r '.mergeable // ""' <<<"$pr_json")" == "MERGEABLE" ]] || continue
  # Vacuously "green" on an empty rollup is exactly the wrong answer — that is
  # CI not having run at all, not CI having passed — so an empty rollup is
  # excluded explicitly rather than trusted through `all`.
  jq -e '(.statusCheckRollup // []) as $c
         | ($c | length) > 0
         and ($c | all(.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .state == "SUCCESS"))' \
    <<<"$pr_json" >/dev/null 2>&1 || continue
  jq -e '(.comments // []) | any((.body // "") | test("agent-ops:human-nudge"))' \
    <<<"$pr_json" >/dev/null 2>&1 && continue

  approved_at="$(jq -r '[(.reviews // [])[] | select(.state == "APPROVED") | .submittedAt] | max // empty' \
    <<<"$pr_json" 2>/dev/null)"
  [[ -n "$approved_at" ]] || continue
  approved_epoch="$(date -d "$approved_at" +%s 2>/dev/null || echo 0)"
  (( approved_epoch > 0 )) || continue
  now_epoch="$(date +%s)"
  threshold_seconds="$(awk -v h="$idle_hours" 'BEGIN{printf "%d", h*3600}')"
  (( now_epoch - approved_epoch >= threshold_seconds )) || continue

  body="$(pipeline_comment_header script "$node_name")

This pull request has been approved, mergeable and green for over ${idle_hours}h with nothing further for the pipeline to do — @${assignee}, it is waiting on a merge click.

$(pipeline_comment_marker "$cycle_id" script)
<!-- agent-ops:human-nudge -->"

  if "$GH" pr comment "$pr_url" --body "$body" >/dev/null 2>&1; then
    jq -nc --arg u "$pr_url" --arg a "$assignee" '{action: "nudged", pr_url: $u, reviewer: $a}'
  else
    warn "$pr_url" "could not post the idle nudge comment"
  fi
done <<<"$prs"

exit 0
