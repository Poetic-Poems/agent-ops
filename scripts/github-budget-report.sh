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
#   - per cycle (agent-ops#1086): the sum of `since_previous.core`/`.graphql`
#     across every readable, non-window-rolled reading a cycle logged — its
#     own whole REST/GraphQL spend, node named alongside since a cycle id
#     belongs to exactly one. This is what requirement 48's own before/after
#     comparison reads: the target is a per-cycle spend low enough that
#     sixteen cycles an hour fit inside one 5,000 bucket with
#     `github_min_core_budget`'s floor to spare;
#   - per node: readings, unreadable readings, and cycles that carry a record;
#   - the `gh` transport shim (requirement 2.0e, agent-ops#1084): every call
#     its own per-call ledger covers, summed by cache outcome — `hit` (a
#     conditional GET served from a `304`), `miss` (a fresh read), `stale`
#     (served last-known-good under a refusal) or `bypass` (a write,
#     `graphql`, or a caller reading its own headers — never cached at all).
#     This is the per-call ledger the previous paragraph's "exact only once …
#     a per-call ledger exists" now names as existing.
#
# ## What the movement is, and is not
#
# The `x-ratelimit-*` headers describe the bucket GitHub enforces, and while
# every node authenticates as one user (D25 unprovisioned) that bucket is the
# user's aggregate: the whole fleet's, the dashboard publisher's and the
# owner's own shell together. A segment's `since_previous` is therefore the
# *bucket's* movement during that segment — an upper bound on what the
# segment itself spent, exact only once identities are per node, or read
# through the shim's own per-identity `budget.json` (lib/gh-shim.sh) rather
# than from `since_previous`. The report says so in its own preamble rather
# than leaving a reader to infer a node's spend from a fleet's.
#
# Reads the fleet's logs the way `scripts/verdict-fate-report.sh` does —
# this node's `state_dir/log.jsonl` plus every peer's mirrored copy — or, given
# log files as arguments, exactly those (the shim's ledger has no such
# argument-file form: given explicit log files there is no `state_dir` to
# find `gh-shim/ledger.ndjson` beside, so that section reads as empty rather
# than erroring). Itself adds no event, makes no network call, and changes
# nothing. Markdown on stdout, followed by a machine-readable JSON block
# carrying the same figures.

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

# resolve_state_and_peers
# Sets RESOLVED_STATE_DIR/RESOLVED_PEERS_DIR from the --state-dir/--peers-dir
# overrides or config.json, or leaves both empty (returning 1) when neither
# is available — never fatal on its own, since some callers (the shim
# ledger) degrade to "nothing read" rather than aborting the report over a
# telemetry source `raw_events`'s own explicit-LOG.jsonl mode has no use for.
RESOLVED_STATE_DIR=""
RESOLVED_PEERS_DIR=""
resolve_state_and_peers() {
  if [[ -n "$state_dir_override" && -n "$peers_dir_override" ]]; then
    RESOLVED_STATE_DIR="$state_dir_override"; RESOLVED_PEERS_DIR="$peers_dir_override"
    return 0
  fi
  [[ -f "$CONFIG_FILE" ]] || return 1
  local defaulted
  defaulted="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")" || return 1
  RESOLVED_STATE_DIR="${state_dir_override:-$(expand_home "$(jq -r '.state_dir' <<<"$defaulted")")}"
  RESOLVED_PEERS_DIR="${peers_dir_override:-$(fleet_peers_dir "$(expand_home "$(jq -r '.workspace_root' <<<"$defaulted")")")}"
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
  resolve_state_and_peers || {
    echo "github-budget-report: config file not found: $CONFIG_FILE" >&2; return 1; }
  fleet_logs "$RESOLVED_STATE_DIR" "$RESOLVED_PEERS_DIR" log.jsonl
}

# raw_ledger_events
# The `gh` transport shim's own per-call ledger (requirement 2.0e,
# agent-ops#1084): this node's `state_dir/gh-shim/ledger.ndjson` plus every
# peer's mirrored copy, read the same fleet-shaped way as `raw_events`'s
# default path. Unlike `raw_events`, never fatal: given explicit LOG.jsonl
# files (LOGS non-empty) there is no state_dir to find a ledger beside, and
# an unreadable config here is no reason to fail a report that already read
# its primary events successfully — both simply mean zero ledger lines,
# reported as such rather than as an error.
raw_ledger_events() {
  [[ ${#LOGS[@]} -eq 0 ]] || return 0
  resolve_state_and_peers || return 0
  fleet_logs "$RESOLVED_STATE_DIR" "$RESOLVED_PEERS_DIR" gh-shim/ledger.ndjson
}

# Damaged lines (NUL runs, a truncated tail) are dropped rather than allowed
# to abort the read: `fromjson?` on each line, then the objects only.
events="$(raw_events | jq -c -R 'fromjson? | select(type == "object")' | jq -s -c --arg since "$since" \
  '[.[] | select(($since == "") or ((.ts // "") >= $since))]' 2>/dev/null)" || exit 1
[[ -n "$events" ]] || events='[]'

ledger_events="$(raw_ledger_events | jq -c -R 'fromjson? | select(type == "object")' | jq -s -c --arg since "$since" \
  '[.[] | select(($since == "") or ((.ts // "") >= $since))]' 2>/dev/null)" || ledger_events='[]'
[[ -n "$ledger_events" ]] || ledger_events='[]'
shim_report="$(jq -c '
  { calls: length,
    hit: (map(select(.cache == "hit")) | length),
    miss: (map(select(.cache == "miss")) | length),
    stale: (map(select(.cache == "stale")) | length),
    bypass: (map(select(.cache == "bypass")) | length) }' <<<"$ledger_events" 2>/dev/null)"
[[ -n "$shim_report" ]] || shim_report='{"calls":0,"hit":0,"miss":0,"stale":0,"bypass":0}'

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
      per_cycle: (
        ($b | map(select(.readable == true and (.since_previous.window_rolled // false) == false
                          and (.since_previous.core | type) == "number"))) as $m
        | ($b | map(.cycle // "?") | unique) as $cycles
        | [ $cycles[] | . as $c
            | ($b | map(select((.cycle // "?") == $c))) as $all
            | ($m | map(select((.cycle // "?") == $c))) as $r
            | { cycle: $c,
                node: ($all | map(.node // "?") | first),
                readings: ($all | length),
                core_spend: ($r | map(.since_previous.core) | add // 0),
                graphql_spend: ($r | map(.since_previous.graphql | select(type == "number")) | add // 0) } ]
        | sort_by(.cycle)),
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
report="$(jq -c --argjson shim "$shim_report" '. + {shim: $shim}' <<<"$report")"

# A null figure is rendered as an em dash *inside jq*, before `@tsv`, never
# after: `read -r` under a tab IFS collapses consecutive tabs, so an empty
# field in the middle of a row would vanish and every column after it would
# shift left — an hour with refusals but no readings printed its refusal
# count under "core peak used" on the first live run (2026-08-30).
def_dash='def dash: if . == null then "—" else . end;'

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
jq -r "$def_dash"' .per_hour[] | [.hour, .readings, .core_peak_used, .core_min_remaining, .graphql_peak_used, .refusals, .budget_standdowns] | map(dash) | @tsv' <<<"$report" \
  | while IFS=$'\t' read -r h r cu cr gu rf sd; do
      printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$h" "$r" "$cu" "$cr" "$gu" "$rf" "$sd"
    done
echo
echo "## Per stage (bucket movement while the stage ran; window rolls excluded)"
echo
echo "| stage | readings | core median | core max | graphql median |"
echo "|---|---:|---:|---:|---:|"
jq -r "$def_dash"' .per_stage[] | [.stage, .readings, .core_movement_median, .core_movement_max, .graphql_movement_median] | map(dash) | @tsv' <<<"$report" \
  | while IFS=$'\t' read -r st r cm cx gm; do
      printf '| %s | %s | %s | %s | %s |\n' "$st" "$r" "$cm" "$cx" "$gm"
    done
echo
echo "## Per cycle (core/graphql spent while that cycle ran; window rolls excluded)"
echo
echo "| cycle | node | readings | core spend | graphql spend |"
echo "|---|---|---:|---:|---:|"
jq -r "$def_dash"' .per_cycle[] | [.cycle, .node, .readings, .core_spend, .graphql_spend] | map(dash) | @tsv' <<<"$report" \
  | while IFS=$'\t' read -r c n r cs gs; do
      printf '| %s | %s | %s | %s | %s |\n' "$c" "$n" "$r" "$cs" "$gs"
    done
echo
echo "## Per node"
echo
echo "| node | readings | unreadable | cycles with a record |"
echo "|---|---:|---:|---:|"
jq -r "$def_dash"' .per_node[] | [.node, .readings, .unreadable, .cycles_with_record] | map(dash) | @tsv' <<<"$report" \
  | while IFS=$'\t' read -r n r u c; do
      printf '| %s | %s | %s | %s |\n' "$n" "$r" "$u" "$c"
    done
echo
echo "## \`gh\` transport shim (requirement 2.0e)"
echo
shim_calls="$(jq -r '.shim.calls' <<<"$report")"
if [[ "$shim_calls" == "0" ]]; then
  echo "No \`gh-shim/ledger.ndjson\` entries in the logs read — nothing to report. The ledger is"
  echo "written by \`lib/gh-shim.sh\` from the first cycle that runs an image carrying it."
else
  echo "Every \`gh\` call the ledger covers, by how the shim answered it: a conditional GET"
  echo "served from a \`304\`, a fresh read, one served last-known-good under a refusal, or a"
  echo "call the shim never caches at all (a write, \`graphql\`, or a caller reading its own"
  echo "headers)."
  echo
  echo "| calls | hit | miss | stale | bypass |"
  echo "|---:|---:|---:|---:|---:|"
  jq -r '.shim | [.calls, .hit, .miss, .stale, .bypass] | @tsv' <<<"$report" \
    | while IFS=$'\t' read -r calls hit miss stale bypass; do
        printf '| %s | %s | %s | %s | %s |\n' "$calls" "$hit" "$miss" "$stale" "$bypass"
      done
fi
echo
echo '```json'
jq '.' <<<"$report"
echo '```'
