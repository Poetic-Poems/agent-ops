#!/usr/bin/env bash
#
# lib/label-marker.sh — the pipeline's own memory of the label actions it has
# taken, the counterpart to `lib/pipeline-marker.sh`'s comment marker (#222)
# for the one write a marker cannot reach: a label carries no hidden text to
# stamp, so an add or a remove leaves nothing on the object itself
# distinguishing this system's own hand from a human's — even though, exactly
# as with a comment, both happen under the one GitHub account this system runs
# as (requirement 9d).
#
# `needs_refinement_label`'s hand-flag path (requirement 34g,
# `refinement_hand_flag_new`) already avoids the obvious version of this bug:
# an issue the Script just labelled is, by construction, already blocked, so
# the "not already blocked" test excludes it without needing to know who
# applied the label. What it cannot catch is the case that test is blind to on
# purpose — a *removal* that silently failed (a rate limit, a permissions
# blip; `refinement_label_remove` already tolerates this, by design, per
# `release_refinement_label`'s own comment) leaves the label sitting on an
# issue whose block has since cleared. The next cycle's hand-flag scan finds
# it labelled, finds no open block, and — without this file — reads that
# exactly like a human asking for one, restarting a block nobody asked for.
# This is that RC4 fleet incident (`docs/reviews/2026-08-07-…`): the pipeline
# unable to tell its own label writes from the human's, each round costing an
# engagement.
#
# The fix is the same shape as the comment marker's, adapted to what a label
# can carry: nothing on the object, so the memory lives in the shared log
# instead. Every add or remove the Script performs is logged as an
# `own-label-action` event; a reader compares GitHub's own record of when the
# label was last applied (`gather-hand-flagged-refinements.sh`'s `labelled_at`)
# against this file's record of when *we* last touched it. If ours is the
# later — or the same — action, the current state is explained without a
# human ever touching the label, and no read-back mechanism may treat it as
# one.
#
# The record is written at the call site (agent-cycle.sh), not inside
# `lib/refinement.sh`'s `refinement_label_add`/`_remove`: those stay pure `gh`
# wrappers, the same "library stays a pure function" boundary
# `stage_budget_overrides` documents for its own config read. This file holds
# only the read-back half — a pure function of the log, like every other
# extract in `lib/cycle-state.sh`.
#
# Sourced by agent-cycle.sh. Sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`.

# label_own_action_fields REPO ITEM LABEL ACTION
# Print the extra fields an `own-label-action` event carries: which item, which
# label, and whether the Script added or removed it. `ACTION` is `add` or
# `remove` — anything else is recorded as given, since a future action this
# file does not yet know about should still be logged rather than dropped.
label_own_action_fields() {
  local repo="$1" item="$2" label="$3" action="$4"
  jq -nc --arg r "$repo" --arg i "$item" --arg l "$label" --arg a "$action" \
    '{repo: $r, item: ($i | tostring), label: $l, action: $a}' 2>/dev/null || printf '{}'
}

# label_own_actions_map LABEL [LOG_FILE]
# Print, as a JSON object keyed `"<repo>|<item>"`, the most recent
# `own-label-action` this system recorded for LABEL against every repo+item
# that has one: `{action, ts}`. Reads LOG_FILE, or stdin if it is omitted or
# "-". Always prints a valid object; an unreadable log yields `{}`, the same
# fail-safe shape as every other extract in `lib/cycle-state.sh`.
label_own_actions_map() {
  local label="$1" src="${2:--}" out=""
  # shellcheck disable=SC2016  # jq's $label/$e, not the shell's.
  local jq_prog='
    [ .[] | select(.event == "own-label-action" and (.label // "") == $label
                   and (.repo // "") != "" and (.item // "") != "") ]
    | sort_by(.ts)
    | reduce .[] as $e ({};
        .[($e.repo) + "|" + (($e.item) | tostring)] =
          {action: ($e.action // ""), ts: ($e.ts // "")})'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc --arg label "$label" "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc --arg label "$label" "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# label_is_own_application OWN_ACTIONS_JSON REPO ITEM LABELLED_AT
# True (exit 0) when the label's current presence on REPO/ITEM is explained by
# this system's own last action rather than a human's: our latest recorded
# action for that repo+item+label was `add`, and GitHub's own record of when
# the label was last applied (LABELLED_AT, from
# `gather-hand-flagged-refinements.sh`) is no later than ours — a human
# touching the label after we did would push LABELLED_AT past our own `ts`.
# Either an empty own record or an empty LABELLED_AT resolves to "not ours" —
# nothing here to disprove human authorship, which is the safe direction: it
# is what every hand-flag read already assumed before this file existed.
label_is_own_application() {
  local own_map="$1" repo="$2" item="$3" labelled_at="$4"
  local key own action ts
  key="$repo|$item"
  own="$(jq -c --arg k "$key" '.[$k] // {}' <<<"$own_map" 2>/dev/null || printf '{}')"
  action="$(jq -r '.action // ""' <<<"$own" 2>/dev/null || true)"
  ts="$(jq -r '.ts // ""' <<<"$own" 2>/dev/null || true)"
  [[ "$action" == "add" ]] || return 1
  [[ -n "$ts" && -n "$labelled_at" ]] || return 1
  [[ ! "$labelled_at" > "$ts" ]]
}
