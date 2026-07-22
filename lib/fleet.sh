#!/usr/bin/env bash
#
# lib/fleet.sh — where the fleet's shared memory lands on disk, and the union
# read over it. Sourced by both pipelines and scripts/state-sync.sh so the
# path convention exists in exactly one place.

# Peers' state trees, one directory per node, materialised by
# `state-sync.sh fetch` from the state repository's nodes/* branches.
fleet_peers_dir() {  # <workspace_root>
  printf '%s/.agent-ops-peers' "$1"
}

# The fleet's event stream: this node's own log followed by every peer's,
# sorted into time order (each line begins {"ts":"…", so a plain byte sort is
# a time sort). The consumers that reduce by most-recent-event-wins — the
# blocked and void extractions (requirement 34/34c), the no-op fingerprint
# (3b), the usage-limit cooldown (2.1) — need the order, not the provenance;
# requirement 33 stamps `node` on every event for anything that does. The
# union is advisory speed — a lesson one node learned sparing the rest — and
# the claims of requirement 17a are the lock underneath it.
fleet_logs() {  # <state_dir> <peers_dir> [log-basename]
  local state_dir="$1" peers="$2" name="${3:-log.jsonl}" f
  {
    [[ -f "$state_dir/$name" ]] && cat "$state_dir/$name"
    for f in "$peers"/*/"$name"; do
      [[ -f "$f" ]] && cat "$f"
    done
  } 2>/dev/null | sort
  return 0
}
