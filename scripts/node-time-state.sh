#!/usr/bin/env bash
#
# scripts/node-time-state.sh — print the node time-state record (D21 of
# docs/ROADMAP.md, issue #597): every node-second in a window classified into
# exactly one of six states — producing, overhead, externally-blocked,
# idle-with-demand, idle-without-demand, down — with idle-with-demand split
# by cause. `docs/FLOW-SCHEMA.md`'s "Node time-state record" section is the
# field-by-field contract this prints; `lib/node-time-state.sh`'s
# `node_time_state_fold` is the pure derivation this script only wires to the
# fleet's own logs.
#
# Reads the union of *both* pipelines' logs — `log.jsonl` (agent-cycle.sh)
# and `review-log.jsonl` (review-cycle.sh) — because both emit `node-state`
# transitions and a node can run either (or, briefly, both) at once; folding
# only one would read that node as `down` while the other pipeline was
# actually running on it.
#
# Read-only throughout: it opens nothing but the two union logs
# (`lib/fleet.sh`'s `fleet_logs`, called once per basename) and this
# repository's own `config.json` (never a target repo's), and prints a JSON
# object to stdout. Never touches the lock, writes no event, makes no
# network call, and is safe to run against a live node at any time — the
# same contract `scripts/pickup-metrics.sh` and `scripts/item-lifecycle.sh`
# already keep.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/node-time-state.sh
. "$SCRIPT_DIR/lib/node-time-state.sh"

usage() {
  cat <<'EOF'
usage: node-time-state.sh [--since <iso8601>] [--until <iso8601>] [--state-dir <dir>] [--peers-dir <dir>]

Read-only. Prints the node time-state report as JSON on stdout:

  - `window`: the timestamps this run actually read (`from`/`to`/`seconds`),
    bounded by --since/--until and by whatever the union logs currently
    hold — log.jsonl is never rotated (scripts/rotate-logs.sh), so the only
    real bound is how far back `node-state` events started being emitted,
    not a retention limit.
  - `nodes`: every node name this run found a `node-state` event for.
  - `totals`: seconds by state — `producing`, `overhead`,
    `externally-blocked`, `idle-with-demand`, `idle-without-demand`, `down`
    — plus `unaccounted` for a `node-state` event whose own `state` this
    fold does not recognise.
  - `expected_total_seconds`/`balanced`: the invariant — node-count x window
    seconds — computed and printed rather than merely asserted in prose.
  - `idle_with_demand_by_cause`: `idle-with-demand` seconds split by the
    four causes D21 names (`awaiting-tick`, `back-pressure`,
    `peer-claimed`, `coordinator-declined`), plus `unspecified` for one
    whose own `cause` this fold does not recognise.
  - `by_node`: the same breakdown, per node.
  - `skipped_events`: `node-state` events missing `node`, `ts` or `state` —
    excluded from every count above, since none can be placed on a
    timeline at all.

  --since       only count `node-state` events at or after this ISO-8601
                timestamp (default: the whole log).
  --until       only count `node-state` events at or before this ISO-8601
                timestamp (default: the whole log).
  --state-dir   this node's own log directory (default: config.json's
                state_dir)
  --peers-dir   the peers directory fleet_logs reads (default:
                fleet_peers_dir over config.json's workspace_root)

Needs no network access and changes nothing.
EOF
}

since=""
until_ts=""
state_dir_override=""
peers_dir_override=""

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --since) since="${2:-}"; shift 2 ;;
    --until) until_ts="${2:-}"; shift 2 ;;
    --state-dir) state_dir_override="${2:-}"; shift 2 ;;
    --peers-dir) peers_dir_override="${2:-}"; shift 2 ;;
    *) echo "node-time-state: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)" || {
  echo "node-time-state: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 2
}
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(cfg '.state_dir')")"
fi

if [[ -n "$peers_dir_override" ]]; then
  peers_dir="$peers_dir_override"
else
  peers_dir="$(fleet_peers_dir "$(expand_home "$(cfg '.workspace_root')")")"
fi

{
  fleet_logs "$state_dir" "$peers_dir" log.jsonl
  fleet_logs "$state_dir" "$peers_dir" review-log.jsonl
} | node_time_state_fold - "$since" "$until_ts"
