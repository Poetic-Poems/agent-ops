#!/usr/bin/env bash
#
# scripts/nudge-dependabot-rebase.sh — the write half of Dependabot-conflict
# handling scripts/gather-merge-conflicts.sh's `bot` classification sets up
# (requirement 3s, issue #250): give Dependabot one cycle to rebase its own
# conflicted PR before this system takes it over.
#
# This system never force-pushes a Dependabot branch (the "When `source` is
# `merge-conflicts`" section of prompts/implementor.md explains why: it is
# the bot's own branch, and Dependabot fights back). So the first time a
# Dependabot PR is seen `CONFLICTING`, the only move is to ask the bot itself
# — `@dependabot rebase` — and give it a cycle. Only once that has already
# happened, and the PR is *still* conflicting at the *same* head, does a
# merge-conflicts candidate become a takeover the Co-Ordinator may act on
# (prompts/coordinator.md's "Merge conflicts" section).
#
# Usage: nudge-dependabot-rebase.sh <owner/repo> <cycle-id> <node-name>
# Stdin: the merge-conflicts candidate array
#   scripts/gather-merge-conflicts.sh produces for this repo — `bot`,
#   `rebase_requested` and `superseded_by` already computed on each entry.
# Stdout: {"conflicts": [...], "actions": [...]}
#   conflicts — the same array, minus any `bot` candidate this call just
#     nudged (it carried `bot: true`, `rebase_requested: false` and no
#     `superseded_by`): nothing for the Co-Ordinator to do with those this
#     cycle. The comment this call posts is what makes the *next* read of
#     gather-merge-conflicts.sh report `rebase_requested: true` for that PR
#     and offer it as a takeover candidate instead — one definition of the
#     rule (requirement 34a), computed once by the gatherer and simply acted
#     on here, never re-derived.
#   actions — one entry per candidate this call attempted to nudge:
#     {"number": N, "outcome": "requested"|"failed"}. A caller logs these; this
#     script logs nothing itself.
# Every other candidate (not a bot PR, already nudged, or superseded — the
# Co-Ordinator votes those `void` on its own, never a nudge) passes through
# `conflicts` untouched, with no action recorded. A `failed` outcome leaves
# `rebase_requested` false, so next cycle's gather-merge-conflicts.sh reads
# the same "not yet asked" state and this script retries the same nudge —
# exactly as if this cycle had never reached it.
#
# Fails safe: an unreadable or non-array stdin is treated as `[]` —
# `{"conflicts": [], "actions": []}`. Exit 0 unless the arguments are unusable.
#
# Environment: NUDGE_GH overrides `gh` (tests stub it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GH="${NUDGE_GH:-gh}"

# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/dependabot-bump.sh
. "$SCRIPT_DIR/lib/dependabot-bump.sh"

slug="${1:-}"
cycle_id="${2:-}"
node_name="${3:-}"
if [[ -z "$slug" || -z "$cycle_id" || -z "$node_name" ]]; then
  echo "usage: nudge-dependabot-rebase.sh <owner/repo> <cycle-id> <node-name>" >&2
  exit 64
fi

candidates_json="$(cat)"
jq -e 'type == "array"' <<<"$candidates_json" >/dev/null 2>&1 || candidates_json='[]'

conflicts='[]'
actions='[]'

nudge_body() {  # <marker>
  printf '%s\n\n@dependabot rebase\n\nThis pull request conflicts with its base, and this system does not force-push a bot'"'"'s own branch. Asking Dependabot to rebase itself — if it is still conflicting next cycle, this system will recreate the bump on its own branch and close this one, referencing the replacement.\n\n%s\n%s' \
    "$(pipeline_comment_header script "$node_name")" \
    "$(pipeline_comment_marker "$cycle_id" script)" \
    "$1"
}

while IFS= read -r cand; do
  [[ -n "$cand" ]] || continue
  bot="$(jq -r '.bot // false' <<<"$cand")"
  rebase_requested="$(jq -r '.rebase_requested // false' <<<"$cand")"
  superseded_by="$(jq -r '.superseded_by // empty' <<<"$cand")"

  if [[ "$bot" != "true" || "$rebase_requested" == "true" || -n "$superseded_by" ]]; then
    conflicts="$(jq -c --argjson c "$cand" '. + [$c]' <<<"$conflicts")"
    continue
  fi

  number="$(jq -r '.number' <<<"$cand")"
  pr_url="$(jq -r '.url' <<<"$cand")"
  head_sha12="$(jq -r '.head_sha[0:12]' <<<"$cand")"
  marker="$(dependabot_rebase_marker "$head_sha12")"

  if "$GH" pr comment "$pr_url" --body "$(nudge_body "$marker")" >/dev/null 2>&1; then
    actions="$(jq -c --argjson n "$number" '. + [{number: $n, outcome: "requested"}]' <<<"$actions")"
  else
    actions="$(jq -c --argjson n "$number" '. + [{number: $n, outcome: "failed"}]' <<<"$actions")"
    # Not added to `conflicts`: a failed nudge leaves rebase_requested false,
    # so there is nothing selectable for this candidate this cycle either way
    # — next cycle's gather retries the same nudge.
  fi
done < <(jq -c '.[]' <<<"$candidates_json" 2>/dev/null || true)

jq -nc --argjson conflicts "$conflicts" --argjson actions "$actions" \
  '{conflicts: $conflicts, actions: $actions}'
