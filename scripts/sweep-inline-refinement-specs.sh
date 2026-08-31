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
# **Read the union, append to a node's own log.** These are two different files
# and conflating them gets the sweep wrong in both directions. The ledger is
# fleet-wide: on 2026-08-31 one node's own `log.jsonl` held 7 of the 81
# stranded entries and the union held all 81, so reading a single node's log
# sweeps a fraction and silently calls it done. The union, meanwhile, is
# `agent-cycle.sh`'s own `$cycle_dir/.fleet-log.jsonl` — rebuilt every cycle
# and discarded with the cycle directory, so a pointer appended *there* is
# gone before anything reads it, and the payload it was meant to supersede
# stays exactly where it was. So: READ_LOG is whatever names the whole fleet's
# events, and `--append-to` is the durable per-node log the new events must
# land in (`state_dir/log.jsonl`), from which the state repo propagates them
# into every later union. `--append-to` defaults to READ_LOG, which is right
# for a node sweeping its own log and wrong for anything else — the guard
# below refuses the one case where that default is known to be silent
# data loss.
#
# For REPO, reads the shared log (READ_LOG, or stdin if it is "-" or omitted —
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
# Usage: sweep-inline-refinement-specs.sh [--apply] [--append-to LOG]
#          <owner/repo> [read-log]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

apply=0
append_to=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --append-to) append_to="${2:-}"; shift 2 || true ;;
    --) shift; break ;;
    -*) echo "sweep-inline-refinement-specs: unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
repo="${1:-}"
log_file="${2:--}"
if [[ -z "$repo" || "$repo" != */* ]]; then
  echo "usage: sweep-inline-refinement-specs.sh [--apply] [--append-to LOG] <owner/repo> [read-log]" >&2
  exit 2
fi

# The one default that is known to lose data rather than merely be narrow: a
# per-cycle union log is deleted with its cycle directory, so the pointers
# would be written into a file nothing reads again. Named by
# `agent-cycle.sh`'s own `union_log`, so the check is against the artefact
# rather than a guess about the caller's intent.
if [[ -z "$append_to" && "$log_file" == *.fleet-log.jsonl ]]; then
  echo "sweep-inline-refinement-specs: $log_file is a per-cycle union log — it is rebuilt every cycle, so appending the new pointers to it would discard them. Pass --append-to <state_dir>/log.jsonl (the durable per-node log the state repo propagates)." >&2
  exit 2
fi
[[ -n "$append_to" ]] || append_to="$log_file"

if (( apply )) && [[ "$append_to" == "-" || ! -w "$(dirname "$append_to")" ]]; then
  echo "sweep-inline-refinement-specs: --append-to '$append_to' is not a writable file path — the pointers would have nowhere to land" >&2
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

sweep_cycle_id="sweep-inline-refinement-specs"

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

  # Requirement 3f/3e's envelope, not a bare body. Every write this system
  # makes lands under the maintainer's own GitHub account, so author alone
  # cannot tell a human's comment from the pipeline's: the visible header is
  # what tells a human reading the thread who wrote this, and the invisible
  # marker is what tells `scripts/gather-abandoned-drafts.sh` the same thing.
  # A sweep posting 81 unmarked comments would read, to both, as the
  # maintainer suddenly hand-specifying 81 issues.
  #
  # Actor `script`: this is a Script-level maintenance write, not a stage's
  # verdict — no model was engaged to produce this text, it was already in the
  # ledger.
  body="$(printf '%s\n\n%s\n\n%s\n\n%s\n' \
    "$(pipeline_comment_header script "${NODE_NAME:-sweep}")" \
    'This item'"'"'s recorded specification, moved here from the fleet log so the thread carries it (agent-ops#1128). It is the same specification the pipeline has been acting on — nothing about the work has changed, and this comment asks nothing of anyone.' \
    "$spec" \
    "$(pipeline_comment_marker "$sweep_cycle_id" script)")"

  url="$(gh issue comment "$item" --repo "$repo" --body "$body" 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    echo "sweep-inline-refinement-specs: $repo#$item: could not post the comment — left as it was" >&2
    continue
  fi

  # The pointer that supersedes the payload. `by: "sweep"` so a reader can tell
  # this from a Refiner's or an Enabler's own record without cross-referencing
  # timestamps, the same reason requirement 3h's own `by` exists.
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg cycle "$sweep_cycle_id" \
         --arg node "${NODE_NAME:-sweep}" \
         --arg r "$repo" --arg i "$item" --arg u "$url" \
    '{ts: $ts, cycle: $cycle, node: $node, event: "item-refined",
      repo: $r, item: $i, by: "sweep", comment_url: $u}' >> "$append_to"

  echo "sweep-inline-refinement-specs: $repo#$item: posted, ${#spec} bytes now a pointer -> $url"
done <<<"$candidates"

if (( apply )); then
  printf 'sweep-inline-refinement-specs: %s: %d entr(ies), %d bytes moved out of the unsheddable band\n' "$repo" "$n" "$bytes"
else
  printf 'sweep-inline-refinement-specs: %s: %d entr(ies), %d bytes would move — DRY RUN, pass --apply to post\n' "$repo" "$n" "$bytes"
fi
