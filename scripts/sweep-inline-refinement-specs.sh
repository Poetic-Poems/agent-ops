#!/usr/bin/env bash
#
# scripts/sweep-inline-refinement-specs.sh — move a refinement that is stranded
# as an inline `spec` into the thread of the issue it describes, and record the
# pointer that replaces it (agent-ops#1128).
#
# Requirement 4j's ledger holds a refinement as one of two shapes: a
# `comment_url` pointing at the thread where the refinement lives, or — for an
# item with no thread to hold it — the specification itself, several kilobytes
# of markdown. Which one an item takes is settled by whether it has a thread.
# `lib/refinement.sh` used to settle it on the item's *source band* instead,
# and agent-ops#875 had already moved tech-debt onto `pw::type:tech-debt`
# issues: so every tech-debt refinement recorded between those two changes took
# the payload shape even though its item had a perfectly good thread. On
# 2026-08-31 that was 81 entries and 229,399 bytes, sitting in the one band
# requirement 4i's fit ladder cannot shed, with the Co-Ordinator's allowance
# 97,465 bytes negative and 104 of 106 candidates dropped on every node.
#
# The writer is fixed, and nothing rewrites history: those 81 entries keep
# their payloads for as long as their items stay candidates. This script is
# what reaches them — the same role
# `scripts/sweep-legacy-refinement-assignees.sh` plays for agent-ops#639's own
# already-written events.
#
# For REPO, reads the shared log (LOG_FILE, or stdin if it is "-" or omitted —
# the convention `lib/cycle-state.sh`'s own readers use) and, for every
# refinement against that repo that carries a `spec`, carries no `comment_url`,
# and whose item is a GitHub issue number:
#   - posts the spec as one comment on that issue, under a heading naming where
#     it came from, so a human reading the thread sees the same specification
#     the pipeline has been acting on rather than a bare wall of markdown;
#   - appends an `item-refined` event carrying the new comment's URL and no
#     `spec`. `refinements_map` keys on the *latest* event per repo+item, so
#     that one line supersedes the payload without deleting anything: the
#     original event stays exactly where it was written.
#
# It is idempotent by construction: an entry whose latest event carries a
# `comment_url` is not selected, so a second run over the same log does
# nothing.
#
# **A dry run is the default, and posts nothing.** This writes public comments
# to real issues, one per stranded entry, and that is not a thing to do by
# accident or to discover halfway through. Pass `--apply` to actually post.
#
# Usage: sweep-inline-refinement-specs.sh [--apply] <owner/repo> [log-file]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"

apply=0
if [[ "${1:-}" == "--apply" ]]; then
  apply=1
  shift
fi
repo="${1:-}"
log_file="${2:--}"
if [[ -z "$repo" || "$repo" != */* ]]; then
  echo "usage: sweep-inline-refinement-specs.sh [--apply] <owner/repo> [log-file]" >&2
  exit 2
fi

# The selection, as one jq program over `refinements_map`'s own output, so this
# script and the Co-Ordinator's own view are reading the same ledger through
# the same builder rather than two spellings of it.
#
# `^[0-9]+$` is the issue test, and it is the same one `lib/refinement.sh`'s
# `e_number` fallback uses: every issue-backed source keys its items by issue
# number, and no thread-less source does — `TD-PPagop-26081407`,
# `pr-202-abandoned-71f7e8b9e663`.
sweep_candidates() {  # <refinements-json> <repo>  -> {item, spec} lines
  jq -c --arg repo "$2" '
    (.[$repo] // {})
    | to_entries[]
    | select(.value | type == "object")
    | select(.value | has("spec"))
    | select(.value | has("comment_url") | not)
    | select(.key | test("^[0-9]+$"))
    | {item: .key, spec: .value.spec}' <<<"${1:-{\}}" 2>/dev/null || true
}

refinements="$(refinements_map "$log_file")"
candidates="$(sweep_candidates "$refinements" "$repo")"

if [[ -z "$candidates" ]]; then
  echo "sweep-inline-refinement-specs: $repo: nothing stranded — no entry carries a spec without a pointer"
  exit 0
fi

n=0
bytes=0
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  item="$(jq -r '.item' <<<"$entry")"
  spec="$(jq -r '.spec' <<<"$entry")"
  n=$(( n + 1 ))
  bytes=$(( bytes + ${#spec} ))

  if (( ! apply )); then
    printf 'would post %6d bytes to %s#%s\n' "${#spec}" "$repo" "$item"
    continue
  fi

  state="$(gh issue view "$item" --repo "$repo" --json state --jq '.state' 2>/dev/null || true)"
  if [[ "$state" != "OPEN" ]]; then
    echo "sweep-inline-refinement-specs: $repo#$item: not an open issue (state '${state:-unreadable}') — skipped" >&2
    continue
  fi

  body="$(printf '%s\n\n%s\n' \
    '**Recorded specification.** This is the refinement the pipeline has been acting on for this item. It was held only in the fleet log until now; it is posted here so the thread carries it (agent-ops#1128).' \
    "$spec")"

  url="$(gh issue comment "$item" --repo "$repo" --body "$body" 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    echo "sweep-inline-refinement-specs: $repo#$item: could not post the comment — left as it was" >&2
    continue
  fi

  # The pointer that supersedes the payload. `by: "sweep"` so a reader can tell
  # this from a Refiner's or an Enabler's own record without cross-referencing
  # timestamps, the same reason requirement 3h's own `by` exists.
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg cycle "sweep-inline-refinement-specs" \
         --arg node "${NODE_NAME:-sweep}" \
         --arg r "$repo" --arg i "$item" --arg u "$url" \
    '{ts: $ts, cycle: $cycle, node: $node, event: "item-refined",
      repo: $r, item: $i, by: "sweep", comment_url: $u}' >> "$log_file"

  echo "sweep-inline-refinement-specs: $repo#$item: posted, ${#spec} bytes now a pointer -> $url"
done <<<"$candidates"

if (( apply )); then
  printf 'sweep-inline-refinement-specs: %s: %d entr(ies), %d bytes moved out of the unsheddable band\n' "$repo" "$n" "$bytes"
else
  printf 'sweep-inline-refinement-specs: %s: %d entr(ies), %d bytes would move — DRY RUN, pass --apply to post\n' "$repo" "$n" "$bytes"
fi
