#!/usr/bin/env bash
#
# lib/unvoid-label.sh — which of the labelled requests actually reopen a void
# (requirement 34f).
#
# `scripts/gather-unvoid-requests.sh` reports what carries the label. This
# decides what that means, and it is deliberately the narrower of the two: a
# request clears a void only when
#
#   1. the item is void **now** — a label naming something that was never void,
#      or has already been reopened, changes nothing and logs nothing; and
#   2. the void was recorded **before** the label was applied.
#
# The second test is the one worth defending. Without it the label becomes a
# standing exemption: it sits on the pull request for ever, and every future
# void on that item is auto-cleared the cycle it is recorded, by a human
# instruction given months earlier about a different verdict. That is a worse
# failure than the one requirement 34f fixes, because it has no symptom — the
# item simply never stays void, and nothing in the log says why. With the test,
# a label authorises reopening exactly what it could have been aimed at, and a
# fresh void stands on its own.
#
# Together the two tests make the source idempotent without touching the label,
# which is what lets the label stay where the human put it: a self-limiting rule
# needs no cleanup, and label edits are this system writing to its own
# bookkeeping surface — the abandoned-drafts source discounts them for exactly
# that reason (requirement 3e) — so the only thing removal could achieve is
# churn on the pull request a human is trying to unstick.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`.

# unvoid_clearances REQUESTS_JSON VOID_JSON
# Print, as a JSON array, one entry per (item, void) pair a request actually
# clears — the input to the `unvoided` events the Script writes:
#
#   {"repo": "…", "item": "…", "labelled_at": "…", "url": "…",
#    "number": 92, "void_ts": "…", "void_reason": "…"}
#
# Repo matching mirrors requirement 34c's own rule for the void extract: a void
# carrying no repo is in every repo, so a request in any repo may clear it.
# Requests always carry a repo (they came from one), so nothing here can clear
# an item in a repo the human was not looking at.
#
# Always prints a valid array. Malformed input yields `[]` rather than a
# non-zero status, because the caller is a cycle under `set -e` that is about to
# record state, and a torn request must not be what stops it.
unvoid_clearances() {
  local requests="${1:-[]}" voids="${2:-[]}" out docs
  # Both arrays arrive on stdin, one document per line, never in argv
  # (requirement 4g): the void extract is unbounded, and past MAX_ARG_STRLEN
  # an `--argjson` delivery makes this call fail into its `|| true` — the
  # label silently stops working fleet-wide, which is this file's own
  # "escape hatch nobody can reach" defect all over again.
  docs="$requests"$'\n'"$voids"
  out="$(jq -nc '
    input as $reqs | input as $voids |
    [ $reqs[]
      | . as $r
      | ($r.items // [])[]
      | . as $item
      | ($voids[]
         | select(.item == $item)
         | select(((.repo // "") == "") or ((.repo // "") == ($r.repo // "")))
         # Strictly after: a void recorded at the same second as the label is
         # not something the human can have been reacting to.
         | select((.ts // "") < ($r.labelled_at // ""))
         | {repo: ($r.repo // ""), item: $item,
            labelled_at: ($r.labelled_at // ""), url: ($r.url // ""),
            number: ($r.number // null),
            void_ts: (.ts // ""), void_reason: (.detail // "")})
    ]
    | unique_by(.repo + "|" + .item)' <<<"$docs" 2>/dev/null || true)"
  [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || out='[]'
  printf '%s' "$out"
}
