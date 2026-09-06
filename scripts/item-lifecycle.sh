#!/usr/bin/env bash
#
# scripts/item-lifecycle.sh — print the item-lifecycle record (requirement
# 49, issue #595): one durable record per work item, folded from the union
# event log, ending in an explicit terminal fate. `docs/FLOW-SCHEMA.md`'s
# "Item lifecycle record" section is the field-by-field contract this prints;
# `lib/item-lifecycle.sh`'s `item_lifecycle_fold` is the pure derivation this
# script only wires to the fleet's own log.
#
# Read-only throughout: it opens nothing but the union log (`lib/fleet.sh`'s
# `fleet_logs`) and this repository's own `config.json` (never a target
# repo's), and prints a JSON object to stdout. Never touches the lock, writes
# no event, makes no network call, and is safe to run against a live node at
# any time — the same contract `scripts/pickup-metrics.sh` already keeps, and
# for the same reason.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/item-lifecycle.sh
. "$SCRIPT_DIR/lib/item-lifecycle.sh"

usage() {
  cat <<'EOF'
usage: item-lifecycle.sh [--since <iso8601>] [--state-dir <dir>] [--peers-dir <dir>]

Read-only. Prints the item-lifecycle report as JSON on stdout:

  - `window`: the timestamps the report covers (`from`/`to`), bounded by
    --since and by whatever the union log currently holds — log.jsonl is
    never rotated (scripts/rotate-logs.sh), so the only real bound is how far
    back this pipeline's own logging began, not a retention limit.
  - `totals`: the flow invariant — `entered` (distinct {repo, item} pairs
    with any event), `leaving` (a terminal fate), `in_progress` (blocked or
    open), `unaccounted`, and `balanced` (whether the four sum to `entered`,
    which they always do by construction — see docs/FLOW-SCHEMA.md).
  - `fates`: the count of each of the six terminal/in-progress fates.
  - `unaccounted`: `{repo, item, reason}` for every item the fold could not
    resolve automatically (never dropped).
  - `records`: one record per item — `{repo, item, source, first_seen,
    instants[], fate}` — docs/FLOW-SCHEMA.md documents every field.

  --since       only count events at or after this ISO-8601 timestamp
                (default: the whole log).
  --state-dir   this node's own log directory (default: config.json's
                state_dir)
  --peers-dir   the peers directory fleet_logs reads (default:
                fleet_peers_dir over config.json's workspace_root)

Needs no network access and changes nothing.
EOF
}

since=""
state_dir_override=""
peers_dir_override=""

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --since) since="${2:-}"; shift 2 ;;
    --state-dir) state_dir_override="${2:-}"; shift 2 ;;
    --peers-dir) peers_dir_override="${2:-}"; shift 2 ;;
    *) echo "item-lifecycle: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)" || {
  echo "item-lifecycle: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
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

fleet_logs "$state_dir" "$peers_dir" log.jsonl | item_lifecycle_fold - "$since"
