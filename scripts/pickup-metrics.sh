#!/usr/bin/env bash
#
# scripts/pickup-metrics.sh — answer issue #248's acceptance 5 from the union
# event log: no increase in duplicate-work incidents relative to before
# finish-then-continue.
#
# The data already exists (TD-PPagop-26080808): every claim miss logs
# `claim-lost` with a `cause`, and `selection` marks a won claim, so the
# measure is contended claim losses per selection — `cause` of `held` or
# `pr-held` (WI-2/#238 renames a PR-keyed `held` loss to `pr-held`; counting
# only `held` would silently undercount after it) — over `claim-lost` whose
# cause is neither, which is an ordinary first-try miss and not contention.
# A `claim-lost` carrying no `cause` at all, from before requirement 17a
# added the field, is excluded rather than guessed at.
#
# The before/after split is **per node, at that node's own first `chained`
# event**, not at #268's merge timestamp: watchtower rolls an image out to
# each node at its own real time, so only a node's own evidence that it
# actually exercised finish-then-continue marks when its own contention
# picture could have changed. A node with no `chained` event at all — in the
# log, or before --since narrowed what this run can see — is entirely
# "before": it has not been seen to adopt the change. The first-chained
# lookup itself is never bounded by --since, since adoption can predate the
# window a report asks about; only the counted events and the reported
# window are.
#
# Read-only throughout: it opens nothing but the union log (`lib/fleet.sh`'s
# `fleet_logs`) and prints a JSON object to stdout. Never touches the lock,
# writes no event, and is safe to run against a live node at any time.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"

usage() {
  cat <<'EOF'
usage: pickup-metrics.sh [--since <iso8601>] [--state-dir <dir>] [--peers-dir <dir>]

Read-only. Prints, as JSON on stdout, the count of `selection` events and of
contended `claim-lost` events (cause `held` or `pr-held`) split into
"before"/"after" eras — per node, at that node's own first `chained` event —
plus each era's ratio (contended losses per selection) and the window of
timestamps the report covers.

  --since       only count events at or after this ISO-8601 timestamp
                (default: the whole log). Does not affect which `chained`
                event counts as a node's first — adoption can predate the
                window a report asks about.
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
    *) echo "pickup-metrics: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

if [[ -z "$state_dir_override" || -z "$peers_dir_override" ]]; then
  DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)" || {
    echo "pickup-metrics: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
    exit 2
  }
fi
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

fleet_logs "$state_dir" "$peers_dir" log.jsonl \
  | jq -c -R 'fromjson? // empty' \
  | jq -s --arg since "$since" '
      def era($fc; $node; $ts):
        if $fc[$node] and $ts >= $fc[$node] then "after" else "before" end;
      def ratio($c; $s): (if $s == 0 then null else ($c / $s) end);

      map(select(type == "object")) as $all
      | ($all
         | map(select(.event == "chained" and (.node // "") != ""))
         | group_by(.node)
         | map({key: .[0].node, value: (map(.ts) | min)})
         | from_entries
        ) as $first_chained
      | ($all | map(select($since == "" or .ts >= $since))) as $ev
      | ($ev | map(.ts) | sort) as $ts
      | ($ev
         | map(select(.event == "selection" and (.node // "") != ""))
         | map(era($first_chained; .node; .ts))
        ) as $sel_eras
      | ($ev
         | map(select(.event == "claim-lost"
             and (.node // "") != ""
             and (.cause == "held" or .cause == "pr-held")))
         | map(era($first_chained; .node; .ts))
        ) as $cont_eras
      | (reduce $sel_eras[]  as $e ({before: 0, after: 0}; .[$e] += 1)) as $sel
      | (reduce $cont_eras[] as $e ({before: 0, after: 0}; .[$e] += 1)) as $cont
      | {
          since: (if $since == "" then null else $since end),
          window: {
            from: (if ($ts | length) == 0 then null else $ts[0] end),
            to:   (if ($ts | length) == 0 then null else $ts[-1] end)
          },
          before: {
            selections: $sel.before,
            contended_losses: $cont.before,
            ratio: ratio($cont.before; $sel.before)
          },
          after: {
            selections: $sel.after,
            contended_losses: $cont.after,
            ratio: ratio($cont.after; $sel.after)
          }
        }
    '
