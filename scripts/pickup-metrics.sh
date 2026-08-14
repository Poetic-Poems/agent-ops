#!/usr/bin/env bash
#
# scripts/pickup-metrics.sh — answer issue #248's acceptances 4 and 5 from the
# union event log: median/p90 pickup latency, and no increase in duplicate-
# work incidents, both relative to before finish-then-continue.
#
# Acceptance 5 — duplicate work. The data already exists (TD-PPagop-26080808):
# every claim miss logs `claim-lost` with a `cause`, and `selection` marks a
# won claim, so the measure is contended claim losses per selection — `cause`
# of `held` or `pr-held` (WI-2/#238 renames a PR-keyed `held` loss to
# `pr-held`; counting only `held` would silently undercount after it) — over
# `claim-lost` whose cause is neither, which is an ordinary first-try miss and
# not contention. A `claim-lost` carrying no `cause` at all, from before
# requirement 17a added the field, is excluded rather than guessed at.
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
# Acceptance 4 — pickup latency (TD-PPagop-26081405). agent-cycle.sh's
# `emit_first_seen` logs one `first-seen` per item the first time any node's
# gather ever reports it; this script pairs each with the `selection` that
# later claims the same {repo, item} and reports the gap in seconds. Where two
# nodes raced to log the same item's `first-seen` almost simultaneously (the
# write itself is best-effort, not behind the atomic claim), the earliest of
# the duplicates wins — same first-wins-by-ts reduction as everywhere else
# this log is reduced. An item logged `bootstrap: true` — a node's own first
# cycle ever emitting `first-seen`, where most of what it "first" sees has in
# truth existed for a while — is excluded from the median/p90, since its
# latency measures this node's cold start, not a real pickup; it is still
# counted, separately, so the exclusion is visible rather than a silent drop.
# An item with only one of the pair — first-seen but not yet claimed, or
# claimed but logged before this instrumentation existed — contributes to
# neither the count nor the latency and is reported instead under `coverage`,
# so a low measured count is never mistaken for a low pickup rate.
#
# `cadence_bound_minutes` (`config.json`'s `schedule.cycle_interval_minutes`)
# is not a statistic of the log — it is the floor under every latency this
# script can ever report: a poll-based `first-seen` is only as fresh as the
# gather that logged it, which runs once per cycle, so no interval this script
# computes can be trusted below roughly one cycle's width.
#
# --since bounds first-seen/selection pairing the same way it bounds every
# other count here: an event outside the window is not counted, which means a
# pickup whose `first-seen` predates --since but whose `selection` falls
# inside it is undercounted as `selection_only` rather than paired — the same
# trade every other --since-bounded count in this script already makes, and
# deliberate for the same reason: the alternative is a report whose window
# argument no longer bounds what was actually read.
#
# Read-only throughout: it opens nothing but the union log (`lib/fleet.sh`'s
# `fleet_logs`) and this repository's own `config.json` (never a target
# repo's), and prints a JSON object to stdout. Never touches the lock, writes
# no event, makes no network call, and is safe to run against a live node at
# any time.

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

Read-only. Prints, as JSON on stdout:

  - the count of `selection` events and of contended `claim-lost` events
    (cause `held` or `pr-held`) split into "before"/"after" eras — per node,
    at that node's own first `chained` event — plus each era's ratio
    (contended losses per selection): issue #248 acceptance 5.
  - `pickup_latency`: the count, median and p90 (seconds) of the gap between
    each item's `first-seen` and the `selection` that claimed it, fleet-wide
    (`.fleet`) and per node (`.by_node`, keyed by the claiming node) — plus
    `bootstrap_excluded_count`, paired items left out of those figures
    because their `first-seen` carried `bootstrap: true`: issue #248
    acceptance 4.
  - `coverage`: `paired` (both events seen), `first_seen_only` (seen, not yet
    claimed) and `selection_only` (claimed, but never `first-seen` — e.g.
    predating this instrumentation) item counts.
  - `cadence_bound_minutes`: this repository's own `schedule.cycle_interval_minutes`
    — the noise floor under every latency figure above, since a poll-based
    `first-seen` is only as fresh as the gather that logged it.
  - `window`: the timestamps the report covers.

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

# Always read, not only when a dir is left to default: cadence_bound_minutes
# below comes from this repository's own config.json regardless of whether
# --state-dir/--peers-dir pointed this run at some other node's logs.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)" || {
  echo "pickup-metrics: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
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

cadence_bound_minutes="$(cfg '.schedule.cycle_interval_minutes')"
[[ "$cadence_bound_minutes" =~ ^[0-9]+$ ]] || cadence_bound_minutes=null

fleet_logs "$state_dir" "$peers_dir" log.jsonl \
  | jq -c -R 'fromjson? // empty' \
  | jq -s --arg since "$since" --argjson cadence "$cadence_bound_minutes" '
      def era($fc; $node; $ts):
        if $fc[$node] and $ts >= $fc[$node] then "after" else "before" end;
      def ratio($c; $s): (if $s == 0 then null else ($c / $s) end);
      # Linear-interpolation percentile over a numeric array, null on empty —
      # same "null rather than a divide-by-zero guess" convention as ratio.
      def percentile($p; $arr):
        ($arr | sort) as $s
        | ($s | length) as $n
        | if $n == 0 then null
          else
            (($n - 1) * $p) as $idx
            | ($idx | floor) as $lo
            | ($idx | ceil) as $hi
            | if $lo == $hi then $s[$lo]
              else $s[$lo] + ($idx - $lo) * ($s[$hi] - $s[$lo])
              end
          end;
      def latency_stats($arr):
        {count: ($arr | length), median_seconds: percentile(0.5; $arr), p90_seconds: percentile(0.9; $arr)};
      # first-wins: the earliest-ts record for each {repo, item} pair — the
      # same "|"-joined grouping key the extracts in lib/cycle-state.sh use.
      def first_per_key:
        group_by(.repo + "|" + .item) | map(sort_by(.ts) | first);

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

      | ($ev | map(select(.event == "first-seen" and (.repo // "") != "" and (.item // "") != ""))
           | first_per_key) as $fs_list
      | ($ev | map(select(.event == "selection" and (.repo // "") != "" and (.item // "") != ""))
           | first_per_key) as $sel_list
      | ($fs_list  | map({key: (.repo + "|" + .item), value: .}) | from_entries) as $fs_by_key
      | ($sel_list | map({key: (.repo + "|" + .item), value: .}) | from_entries) as $sel_by_key
      | ($fs_list  | map(.repo + "|" + .item)) as $fs_keys
      | ($sel_list | map(.repo + "|" + .item)) as $sel_keys
      | ([$fs_keys[]  | select(. as $k | $sel_by_key | has($k))])         as $paired_keys
      | ([$fs_keys[]  | select(. as $k | ($sel_by_key | has($k)) | not)]) as $fs_only_keys
      | ([$sel_keys[] | select(. as $k | ($fs_by_key  | has($k)) | not)]) as $sel_only_keys
      | ($paired_keys | map(
           $fs_by_key[.] as $fs | $sel_by_key[.] as $sel
           | {node: $sel.node, bootstrap: ($fs.bootstrap // false),
              latency_seconds: (($sel.ts | fromdateiso8601) - ($fs.ts | fromdateiso8601))}
         )) as $paired
      | ($paired | map(select(.bootstrap | not))) as $measured
      | ($paired | map(select(.bootstrap)) | length) as $bootstrap_excluded_count
      | ($measured | group_by(.node)
           | map({key: .[0].node, value: (map(.latency_seconds) | latency_stats(.))})
           | from_entries) as $by_node

      | {
          since: (if $since == "" then null else $since end),
          window: {
            from: (if ($ts | length) == 0 then null else $ts[0] end),
            to:   (if ($ts | length) == 0 then null else $ts[-1] end)
          },
          cadence_bound_minutes: $cadence,
          before: {
            selections: $sel.before,
            contended_losses: $cont.before,
            ratio: ratio($cont.before; $sel.before)
          },
          after: {
            selections: $sel.after,
            contended_losses: $cont.after,
            ratio: ratio($cont.after; $sel.after)
          },
          coverage: {
            paired: ($paired_keys | length),
            first_seen_only: ($fs_only_keys | length),
            selection_only: ($sel_only_keys | length)
          },
          pickup_latency: {
            bootstrap_excluded_count: $bootstrap_excluded_count,
            fleet: ($measured | map(.latency_seconds) | latency_stats(.)),
            by_node: $by_node
          }
        }
    '
