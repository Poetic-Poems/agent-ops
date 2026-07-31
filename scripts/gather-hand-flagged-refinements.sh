#!/usr/bin/env bash
#
# gather-hand-flagged-refinements.sh — pre-fetch the issues a human has
# labelled directly, asking the pipeline to treat them as too under-specified
# to work on (requirement 34g).
#
# Given a repo slug, print a JSON array of every issue in that repo — open or
# closed — currently carrying <label>, each resolved to who last applied it and
# when.
#
# Usage: gather-hand-flagged-refinements.sh <owner/repo> [label]
#
# Entry shape:
#   {
#     "repo": "Poetic-Poems/poetic",
#     "number": 52,
#     "url": "https://github.com/…/issues/52",
#     "label": "needs-refinement",
#     "state": "open",                       // or "closed"
#     "labelled_at": "2026-07-28T09:00:00Z",  // when the label was last applied
#     "by": "warwick"                         // who applied it, "" if unknown
#   }
#
# ## Why this exists
#
# Requirement 34e projects `needs_refinement_label` onto an issue when the
# Co-Ordinator reports the item as too under-specified to select, and removes
# it once that clears — a one-way mirror of state the log already holds, never
# a second input. That left the one person the whole mechanism serves with
# nothing: a human reading an issue has no `needs_refinement` entry to hand a
# Co-Ordinator and no `state_dir/log.jsonl` to append to from a browser (the
# same gap requirement 34f closes for a void). Applying the label by hand did
# nothing and looked exactly like it had worked.
#
# This script reports what carries the label; `lib/refinement.sh`'s
# `refinement_hand_flag_new` and `refinement_hand_flag_cleared` decide what
# that means — a fresh block for a labelled, open issue with none yet, and an
# `unblocked` for a block *this mechanism created* whose issue has lost the
# label since. Both decisions read `lib/cycle-state.sh`'s `blocked_items`
# extract, not this script's output alone, so a repo this call could not reach
# blocks nothing new and clears nothing already open — the same fail-safe
# shape as every other gatherer here.
#
# `state=all`, not `state=open`: a closed issue that still carries the label
# has not had the flag withdrawn, only closed, and reporting it here is what
# lets the decision layer tell "closed" apart from "label removed" instead of
# treating them as the same signal.
#
# The issue's own number is its item id, exactly as the `issues` work source
# already keys on it — there is no branch, title or body to mine the way
# gather-unvoid-requests.sh must, because an issue naming another item as under-
# specified is not a thing this label means.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with no
# labelled issues, or an API that will not answer, contributes `[]`, and the
# request is seen next cycle instead.

set -uo pipefail

slug="${1:-}"
label="${2:-needs-refinement}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-hand-flagged-refinements.sh <owner/repo> [label]" >&2
  exit 64
fi

# One call for the whole set. `repos/<slug>/issues` returns pull requests too
# when a label happens to sit on one, but this label only ever means something
# on an issue (requirement 34e's own scope), so pull requests are dropped here
# rather than mined the way an `unvoided` request is.
hits="$(gh api --paginate \
          "repos/$slug/issues?labels=$label&state=all&per_page=100" \
          --jq '[.[] | select(has("pull_request") | not)
                      | {number, url: (.html_url // ""), state: (.state // "open")}]' \
        2>/dev/null || true)"
if [[ -z "$hits" ]] || ! jq -e 'type == "array"' <<<"$hits" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

out='[]'
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  number="$(jq -r '.number' <<<"$hit")"
  [[ "$number" =~ ^[0-9]+$ ]] || continue

  # When the label last went on, and who put it there. The timeline is the
  # only place either exists — the issue itself carries the label but not its
  # history — and the *latest* application is the one that counts: a human who
  # removes and re-applies the label is asking again, about everything up to
  # now.
  labelled="$(gh api --paginate "repos/$slug/issues/$number/timeline" \
                --jq "[.[] | select(.event == \"labeled\" and .label.name == \"$label\")]
                      | sort_by(.created_at) | last
                      | {at: (.created_at // \"\"), by: (.actor.login // \"\")}" \
              2>/dev/null || true)"
  # No timeline entry, no request: guessing a timestamp here would defeat the
  # one test (requirement 34g, mirroring 34f) that stops a stale reading of the
  # label reopening or reclosing something it was never aimed at.
  [[ -n "$labelled" ]] || continue
  at="$(jq -r '.at // ""' <<<"$labelled")"
  [[ -n "$at" ]] || continue
  by="$(jq -r '.by // ""' <<<"$labelled")"

  entry="$(jq -nc --argjson hit "$hit" --arg repo "$slug" --arg label "$label" \
    --arg at "$at" --arg by "$by" \
    '{repo: $repo, number: $hit.number, url: $hit.url, label: $label,
      state: $hit.state, labelled_at: $at, by: $by}')"
  out="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$out")"
done < <(jq -c '.[]' <<<"$hits" 2>/dev/null || true)

jq -c 'sort_by(.number)' <<<"$out"
