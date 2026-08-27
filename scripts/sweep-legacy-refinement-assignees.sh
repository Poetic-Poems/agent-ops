#!/usr/bin/env bash
#
# scripts/sweep-legacy-refinement-assignees.sh — undo requirement 38b's old
# bookkeeping mechanism wherever it is still standing (agent-ops#639).
#
# Before agent-ops#639, a Co-Ordinator-recorded (or Refiner-declined, or
# Implementer-escaped) refinement block on an issue got both a label
# (`needs_refinement_label`) *and* an assignment to `enabler_assignee` — the
# assignment was meant to put the block on the human's own Assigned-to-me
# dashboard, but nothing distinguished that bookkeeping assignment from a
# genuine escalation (requirement 36a) or a human's own claim, so a removal
# that failed left an issue silently, permanently assigned. 21 such
# assignments needed clearing by hand on 2026-08-21 alone. Requirement 38b now
# projects `blocked`/`blocked:needs-refinement` labels instead and never
# assigns anything — but every block the old mechanism already recorded still
# carries `needs_refinement_assignee` on its own, already-written
# `attempt-failed` event (nothing rewrites history), so this script is what
# clears the backlog that left behind and keeps clearing it if a repository
# this pipeline has not walked in a while turns out to still have one.
#
# For REPO, reads the shared log (LOG_FILE, or stdin if it is "-" or omitted —
# the same convention `lib/cycle-state.sh`'s own `blocked_items` uses) and,
# for every still-open `needs-refinement`-kind block against that repo whose
# event carries `needs_refinement_assignee`:
#   - removes that assignment from the issue (`refinement_assignee_remove`) —
#     a no-op, not a failure, if it is already gone;
#   - applies `blocked:needs-refinement` to the same issue
#     (`refinement_label_add`, unconditionally — no human reaches for that
#     compound name on their own) and `blocked` (`refinement_label_project`,
#     read-before-write — see below) — the pair requirement 38b would have
#     applied instead, had this block been recorded after agent-ops#639 — a
#     no-op if either is already there.
#
# Every step is best-effort and idempotent: safe to run more than once,
# against the same repository or a fresh one, from a terminal or a cron job.
# The matching set can only ever shrink — a block recorded after agent-ops#639
# never carries `needs_refinement_assignee` in the first place
# (`record_needs_refinement_block` never sets it) — so a repeat run against an
# already-swept repository finds nothing and does nothing.
#
# This script does not touch the log itself: `needs_refinement_assignee`
# stays on the historical event forever, and that is what the release path
# reads it as. For the reason label that reading is enough on its own —
# `refinement_blocked_label_targets` (lib/refinement.sh) treats a block
# carrying `needs_refinement_assignee` and neither `blocked_label` nor
# `blocked_reason_label` as carrying `blocked:needs-refinement`, so that
# label comes off again when the block clears, exactly as a freshly recorded
# block's does — safe because the name is fixed and no human ever applies it
# themselves, so this script can only ever be the one that did.
#
# The generic `blocked` label does not get the same treatment, and that is
# deliberate (agent-ops#651). `blocked` *is* a name a human reaches for on
# their own (`lib/labels.sh`'s own catalogue documents it as their hand-applied
# control), so this script projects it through `refinement_label_project`
# instead of an unconditional add — a pre-existing `blocked` is left exactly
# as found, the same read-before-write guard the fresh path
# (`record_needs_refinement_block`) uses. But this script has nowhere to
# record which of `added`/`present` actually happened — it does not rewrite
# the block's own event, and, unlike the fresh path, has no cycle log of its
# own to append an `own-label-action` to — so a legacy block's `blocked_label`
# field can never be filled the way a fresh block's is.
# `refinement_blocked_label_targets` therefore never treats a legacy block's
# generic `blocked` as this pipeline's to remove, whether this run actually
# added it or found it already there: doing so regardless, the way this once
# read, would let a later block-clearing remove a `blocked` a human applied
# for their own reasons on any issue that also happens to carry a still-open
# pre-agent-ops#639 block — the exact defect `refinement_label_project` exists
# to prevent, reappearing on the one path that cannot prove its own history.
#
# **What the provenance-keyed path does and does not release for a
# legacy-swept issue**, stated plainly: `refinement_blocked_label_targets`
# offers the *reason* label up when the block clears — a legacy block's
# `needs_refinement_assignee`, with neither blocked-label field set, is enough
# to name it — but never the generic `blocked` (this paragraph's over-hold,
# unchanged). And if that reason-label removal silently fails, nothing retries
# it: this script logs no `own-label-action` of its own (it runs outside a
# cycle, with nothing to log to), so `refinement_blocked_label_stale`
# (requirement 38b's log-keyed reconciliation sweep, agent-ops#651), which
# offers up only a label whose logged history says `add`, never sees a
# legacy-swept label's application at all.
#
# Requirement 38b's *live* reconciliation closes that retry gap
# (agent-ops#816, TD-PPagop-26082602): `refinement_blocked_label_orphaned`
# needs no `own-label-action` history and no provenance field, only a live
# GitHub read — a `blocked:<reason>` label is never a human's own, so its
# presence on an open issue with no open block behind it is proof enough on
# its own, and `blocked` rides along whenever that same issue's live labels
# carry both. `lib/candidate-gather.sh`'s per-repo gather loop runs it every
# cycle a repo's `sources` configures the `issues` band, so a pair still
# standing when its block clears comes off within one cycle, whether or not
# this script (or `record_needs_refinement_block`) ever logged a thing about
# it.
#
# What that live read does not reach is the issue whose reason-label removal
# *did* take: the reason label is the whole of what puts an issue in front of
# it, so a legacy-swept issue left carrying a bare `blocked` is invisible to
# it, and `scripts/gather-issues.sh`'s own `blocked`-label filter goes on
# excluding that issue for as long as the label stands. TD-PPagop-26082608
# holds that residue.
#
# Usage: sweep-legacy-refinement-assignees.sh <owner/repo> [log-file]
#
# Prints one line per issue actually touched, `<repo>#<number>: <what>`, to
# stdout; failures (a `gh` call that did not take) go to stderr and do not
# stop the sweep — the next run, or a human, gets another chance at whichever
# issue it was.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"

repo="${1:-}"
log_file="${2:--}"
if [[ -z "$repo" ]]; then
  echo "usage: sweep-legacy-refinement-assignees.sh <owner/repo> [log-file]" >&2
  exit 64
fi

blocked_json="$(blocked_items "$log_file")"

legacy_json="$(jq -c --arg repo "$repo" --arg kind "$REFINEMENT_BLOCK_KIND" '
  [ .[]?
    | select((.kind // "") == $kind)
    | select((.repo // "") == $repo)
    | select((.needs_refinement_assignee // "") != "")
    | select(((.item // "") | tostring) | test("^[0-9]+$")) ]
  | unique_by(.item)' <<<"$blocked_json" 2>/dev/null || printf '[]')"

n="$(jq 'length' <<<"$legacy_json" 2>/dev/null || echo 0)"
if [[ "$n" == "0" ]]; then
  echo "sweep-legacy-refinement-assignees: $repo: nothing to reconcile" >&2
  exit 0
fi

while IFS=$'\t' read -r number assignee; do
  [[ -n "$number" ]] || continue
  if refinement_assignee_remove "$repo" "$number" "$assignee"; then
    printf '%s#%s: removed legacy assignment to %s\n' "$repo" "$number" "$assignee"
  else
    echo "sweep-legacy-refinement-assignees: $repo#$number: could not remove the legacy $assignee assignment" >&2
  fi
  # `blocked` is a human's own, hand-applied control (`lib/labels.sh`'s own
  # catalogue), so this reads before it writes — `refinement_label_project`,
  # the same guard the fresh path (`record_needs_refinement_block`) uses —
  # rather than an unconditional `refinement_label_add`: a pre-existing
  # `blocked` is left exactly as found. Unlike the fresh path, this script has
  # no event of its own to record whether the label was actually `added` or
  # already `present`, so `refinement_blocked_label_targets` never treats a
  # legacy block's generic `blocked` as this pipeline's to remove either way
  # (lib/refinement.sh) — this read stops a needless re-add and a
  # misleading "applied" line, not a later false removal, which the targets
  # change already prevents on its own.
  case "$(refinement_label_project "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL")" in
    added)
      printf '%s#%s: applied %s\n' "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL"
      ;;
    present)
      printf '%s#%s: %s already present — left as is\n' "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL"
      ;;
    unrecorded)
      echo "sweep-legacy-refinement-assignees: $repo#$number: could not read its labels — $REFINEMENT_BLOCKED_LABEL was applied best-effort" >&2
      ;;
    *)
      echo "sweep-legacy-refinement-assignees: $repo#$number: could not apply the $REFINEMENT_BLOCKED_LABEL label" >&2
      ;;
  esac
  reason_label="$(refinement_blocked_reason_label "$REFINEMENT_BLOCK_KIND")"
  if [[ -n "$reason_label" ]]; then
    if refinement_label_add "$repo" "$number" "$reason_label"; then
      printf '%s#%s: applied %s\n' "$repo" "$number" "$reason_label"
    else
      echo "sweep-legacy-refinement-assignees: $repo#$number: could not apply the $reason_label label" >&2
    fi
  fi
done < <(jq -r '.[] | [(.item // ""), (.needs_refinement_assignee // "")] | @tsv' <<<"$legacy_json" 2>/dev/null)
