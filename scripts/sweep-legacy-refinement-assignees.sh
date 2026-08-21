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
#   - applies `blocked` and `blocked:needs-refinement` to the same issue
#     (`refinement_label_add`) — the pair requirement 38b would have applied
#     instead, had this block been recorded after agent-ops#639 — a no-op if
#     either is already there.
#
# Every step is best-effort and idempotent: safe to run more than once,
# against the same repository or a fresh one, from a terminal or a cron job.
# The matching set can only ever shrink — a block recorded after agent-ops#639
# never carries `needs_refinement_assignee` in the first place
# (`record_needs_refinement_block` never sets it) — so a repeat run against an
# already-swept repository finds nothing and does nothing.
#
# This script does not touch the log itself: `needs_refinement_assignee`
# stays on the historical event forever, which is harmless — nothing else
# reads that field once `refinement_assignee_targets` (the only reader) was
# retired alongside the mechanism it served.
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
  if refinement_label_add "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL"; then
    printf '%s#%s: applied %s\n' "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL"
  else
    echo "sweep-legacy-refinement-assignees: $repo#$number: could not apply the $REFINEMENT_BLOCKED_LABEL label" >&2
  fi
  reason_label="$(refinement_blocked_reason_label "$REFINEMENT_BLOCK_KIND")"
  if [[ -n "$reason_label" ]]; then
    if refinement_label_add "$repo" "$number" "$reason_label"; then
      printf '%s#%s: applied %s\n' "$repo" "$number" "$reason_label"
    else
      echo "sweep-legacy-refinement-assignees: $repo#$number: could not apply the $reason_label label" >&2
    fi
  fi
done < <(jq -r '.[] | [(.item // ""), (.needs_refinement_assignee // "")] | @tsv' <<<"$legacy_json" 2>/dev/null)
