#!/usr/bin/env bash
#
# scripts/github-budget-report.sh — what the fleet's GitHub API budget did
# (requirement 2.0d, agent-ops#1087): a read-only operator report over the
# `github-budget` events `github_budget_record` (lib/github-limit.sh) logs at
# cycle start, after every model stage and at cycle end.
#
# D25 (docs/ROADMAP.md) accepts that one authoring App shares one rate-limit
# bucket across the fleet "until that budget is *measured* to bind", and
# names a future measurement — not a guess about scale — as the trigger to
# revisit. Until this script nothing measured it: the fleet ran out of REST
# budget in 10 distinct hours of the 48 to 2026-08-30T05Z, and the only record
# was the refusals themselves. This prints, from the fleet's own logs:
#
#   - per hour (UTC): readings taken, the peak `core` used and the minimum
#     `core` remaining any reading saw, the peak `graphql` used, the number of
#     primary-limit refusals that reached `guard-degraded`, and the number of
#     requirement-2.0 stand-downs — the "did it bind" table;
#   - per stage: how far the bucket moved while the stage ran (median and
#     maximum of `since_previous.core`, median of `.graphql`), readings that
#     spanned a window roll excluded;
#   - per node: readings, unreadable readings, and cycles that carry a record.
#
# ## What the movement is, and is not
#
# The `x-ratelimit-*` headers describe the bucket GitHub enforces, and while
# every node authenticates as one user (D25 unprovisioned) that bucket is the
# user's aggregate: the whole fleet's, the dashboard publisher's and the
# owner's own shell together. A segment's `since_previous` is therefore the
# *bucket's* movement during that segment — an upper bound on what the
# segment itself spent, exact only once identities are per node or a per-call
# ledger exists (agent-ops#1084). The report says so in its own preamble
# rather than leaving a reader to infer a node's spend from a fleet's.
#
# Reads the fleet's logs the way `scripts/verdict-fate-report.sh` does —
# this node's `state_dir/log.jsonl` plus every peer's mirrored copy — or, given
# log files as arguments, exactly those. Itself adds no event, makes no
# network call, and changes nothing. Markdown on stdout, followed by a
# machine-readable JSON block carrying the same figures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
state_dir_override=""
peers_dir_override=""
since=""
declare -a LOGS=()

usage() {
  cat <<'USAGE'
usage: github-budget-report.sh [--config FILE] [--state-dir DIR] [--peers-dir DIR]
                               [--since ISO8601] [LOG.jsonl ...]

With no log files, reads this node's `state_dir/log.jsonl` and every peer's
mirrored copy (config.json's `state_dir` and `workspace_root`, or the
--state-dir/--peers-dir overrides). With log files, reads exactly those.
--since keeps only events at or after that timestamp.

Prints, per hour, per stage and per node, what the fleet's GitHub API budget
did — from the `github-budget` events requirement 2.0d records — followed by
a machine-readable JSON block carrying the same figures. Read-only.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --state-dir) state_dir_override="$2"; shift 2 ;;
    --peers-dir) peers_dir_override="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do LOGS+=("$1"); shift; done ;;
    -*) usage >&2; exit 64 ;;
    *) LOGS+=("$1"); shift ;;
  esac
done

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

raw_events() {
  if [[ ${#LOGS[@]} -gt 0 ]]; then
    local f
    for f in "${LOGS[@]}"; do
      [[ -f "$f" ]] || { echo "github-budget-report: no such log: $f" >&2; return 1; }
      cat "$f"
    done
    return 0
  fi
  local state_dir peers_dir
  if [[ -n "$state_dir_override" && -n "$peers_dir_override" ]]; then
    state_dir="$state_dir_override"; peers_dir="$peers_dir_override"
  else
    [[ -f "$CONFIG_FILE" ]] || { echo "github-budget-report: config file not found: $CONFIG_FILE" >&2; return 1; }
    local defaulted
    defaulted="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")" || {
      echo "github-budget-report: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2; return 1; }
    state_dir="${state_dir_override:-$(expand_home "$(jq -r '.state_dir' <<<"$defaulted")")}"
    peers_dir="${peers_dir_override:-$(fleet_peers_dir "$(expand_home "$(jq -r '.workspace_root' <<<"$defaulted")")")}"
  fi
  fleet_logs "$state_dir" "$peers_dir" log.jsonl
}

# Damaged lines (NUL runs, a truncated tail) are dropped rather than allowed
# to abort the read: `fromjson?` on each line, then the objects only.
events="$(raw_events | jq -c -R 'fromjson? | select(type == "object")' | jq -s -c --arg since "$since" \
  '[.[] | select(($since == "") or ((.ts // "") >= $since))]' 2>/dev/null)" || exit 1
[[ -n "$events" ]] || events='[]'

report="$(jq -c '
  def median: if length == 0 then null else (sort | .[(length / 2) | floor]) end;
  def hour: (.ts // "")[0:13];
  def is_refusal: (.event == "guard-degraded")
    and ((.detail // "") | tostring | test("rate limit (already )?exceeded"; "i"));
  def is_budget_standdown: (.event == "stand-down") and (has("github_resource"));
  (map(select(.event == "github-budget"))) as $b
  | (map(select(is_refusal))) as $ref
  | (map(select(is_budget_standdown))) as $sd
  | {
      readings: ($b | length),
      readable: ($b | map(select(.readable == true)) | length),
      first_ts: ($b | map(.ts) | min),
      last_ts: ($b | map(.ts) | max),
      per_hour: (
        ([$b[], $ref[], $sd[]] | map(hour) | unique) as $hours
        | [ $hours[] | . as $h
            | ($b | map(select(hour == $h and .readable == true))) as $r
            | { hour: $h,
                readings: ($b | map(select(hour == $h)) | length),
                core_peak_used: ($r | map(.core.used | select(type == "number")) | max),
                core_min_remaining: ($r | map(.core.remaining | select(type == "number")) | min),
                graphql_peak_used: ($r | map(.graphql.used | select(type == "number")) | max),
                refusals: ($ref | map(select(hour == $h)) | length),
                budget_standdowns: ($sd | map(select(hour == $h)) | length) } ]),
      per_stage: (
        ($b | map(select(.phase == "stage" and .readable == true and (.since_previous.window_rolled // false) == false))) as $s
        | ($s | map(.stage) | unique) as $stages
        | [ $stages[] | . as $st
            | ($s | map(select(.stage == $st))) as $r
            | { stage: $st,
                readings: ($r | length),
                core_movement_median: ($r | map(.since_previous.core | select(type == "number")) | median),
                core_movement_max: ($r | map(.since_previous.core | select(type == "number")) | max),
                graphql_movement_median: ($r | map(.since_previous.graphql | select(type == "number")) | median) } ]),
      per_node: (
        ($b | map(.node // "?") | unique) as $nodes
        | [ $nodes[] | . as $n
            | ($b | map(select((.node // "?") == $n))) as $r
            | { node: $n,
                readings: ($r | length),
                unreadable: ($r | map(select(.readable != true)) | length),
                cycles_with_record: ($r | map(.cycle) | unique | length) } ]),
      refusals: ($ref | length),
      budget_standdowns: ($sd | length)
    }' <<<"$events")"

cell() { local v="${1:-}"; if [[ -z "$v" || "$v" == "null" ]]; then printf '—'; else printf '%s' "$v"; fi; }

echo "# GitHub API budget report"
echo
readings="$(jq -r '.readings' <<<"$report")"
if [[ "$readings" == "0" ]]; then
  echo "No \`github-budget\` events in the logs read — nothing to report. The events are"
  echo "written by \`github_budget_record\` (requirement 2.0d) from the first cycle that runs"
  echo "a build carrying it."
else
  jq -r '"\(.readable) readable reading(s) of \(.readings), from \(.first_ts // "?") to \(.last_ts // "?"); \(.refusals) primary-limit refusal(s) reached guard-degraded and requirement 2.0 stood a cycle down \(.budget_standdowns) time(s)."' <<<"$report"
fi
echo
echo "Every figure is the *bucket's*: while every node authenticates as one user (D25"
echo "unprovisioned) the \`x-ratelimit-*\` headers describe the user's aggregate — the"
echo "fleet, the dashboard publisher and the owner's shell together — so a segment's"
echo "movement is an upper bound on what that segment itself spent."
echo
echo "## Per hour (UTC)"
echo
echo "| hour | readings | core peak used | core min remaining | graphql peak used | refusals | budget stand-downs |"
echo "|---|---:|---:|---:|---:|---:|---:|"
jq -r '.per_hour[] | [.hour, .readings, .core_peak_used, .core_min_remaining, .graphql_peak_used, .refusals, .budget_standdowns] | @tsv' <<<"$report" \
  | while IFS=$'\t' read -r h r cu cr gu rf sd; do
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$h" "$(cell "$r")" "$(cell "$cu")" "$(cell "$cr")" "$(cell "$gu")" "$(cell "$rf")" "$(cell "$sd")"
    done
echo
echo "## Per stage (bucket movement while the stage ran; window rolls excluded)"
echo
echo "| stage | readings | core median | core max | graphql median |"
echo "|---|---:|---:|---:|---:|"
jq -r '.per_stage[] | [.stage, .readings, .core_movement_median, .core_movement_max, .graphql_movement_median] | @tsv' <<<"$report" \
  | while IFS=$'\t' read -r st r cm cx gm; do
      printf '| %s | %s | %s | %s | %s |\n' "$st" "$(cell "$r")" "$(cell "$cm")" "$(cell "$cx")" "$(cell "$gm")"
    done
echo
echo "## Per node"
echo
echo "| node | readings | unreadable | cycles with a record |"
echo "|---|---:|---:|---:|"
jq -r '.per_node[] | [.node, .readings, .unreadable, .cycles_with_record] | @tsv' <<<"$report" \
  | while IFS=$'\t' read -r n r u c; do
      printf '| %s | %s | %s | %s |\n' "$n" "$(cell "$r")" "$(cell "$u")" "$(cell "$c")"
    done
echo
echo '```json'
jq '.' <<<"$report"
echo '```'
