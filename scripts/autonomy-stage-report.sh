#!/usr/bin/env bash
#
# scripts/autonomy-stage-report.sh — D18 rollout-stage evidence report
# (issue #571, a WI of umbrella #402).
#
# Every promotion up the D18 trust ladder is gated on evidence — agent-ops#402
# (2026-08-18 amendment) states each rung's exit criteria — and until this
# script, nothing computed the measured side of that gate: an owner met a
# promotion decision with `scripts/mine-merge-history.sh`'s Stage 0 baseline
# and a memory of the rest. This prints, for each configured repository, its
# `merge_autonomy` level, the rollout stage that level corresponds to, that
# stage's exit criteria, the measured value of each, and a closing verdict —
# `met`, `not-met (criterion: …)` or `insufficient-evidence`. Argless-runnable
# against config.json.
#
# ## Configured, not effective, level
#
# Reads `merge_autonomy_configured_level` (`lib/merge-autonomy.sh`), the same
# choice `scripts/doctor.sh` makes and for the same reason stated in that
# file's own header: a momentary kill-switch trip answers "is autonomy
# running right now", not "how much rollout evidence has this repository
# earned" — the question this report exists to answer. Checking the kill
# switch would also need a network read of the state repo this report has no
# other reason to make.
#
# ## Two stages share one level
#
# Stages 2 and 3 are both `agent-merges-routine` (#402: "Stage 3 … Same
# metrics per repo") — the ladder has no field that tells them apart, only
# which *sources* and *complexity* grades a repository's own
# `merge_autonomy_routine_sources` currently admits, which this report does
# not attempt to classify. Since their exit criteria are identical, a
# repository at that level is reported against "Stage 2/3" once, not twice.
#
# ## What is unavailable, and why that is not zero
#
# Two of the ladder's measures have no detector yet: classifier escapes
# (agent-ops#572, still open) and the Stage 1 divergence between an Approver
# verdict and the human's eventual action (agent-ops#573, still open). Both
# are always reported `unavailable`, never a guessed `0` — a `0` a human could
# mistake for "checked, and clean" is worse than an honest gap (acceptance
# 3). Neither detector is built here; that is each issue's own scope.
#
# ## "Elapsed time at this level" — an event-log proxy, not config history
#
# This repository's own git history would answer "when was this repo's
# `merge_autonomy` last changed" directly, but the deployed image never
# carries `.git` (see `.dockerignore`'s own comment) and this script has to
# run identically there and in a checkout. Instead, "since" is read off the
# fleet event log, which is never rotated (`scripts/rotate-logs.sh` keeps
# `log.jsonl` whole deliberately — the same guarantee `scripts/pickup-
# metrics.sh` leans on for its own first-event-per-node adoption split):
#
#   - `agent-merges-routine`/`agent-merges-all` — the repo's own earliest
#     `landing-armed` event. The Script only ever arms a landing once a
#     repository's level has reached this rung, so the first such event
#     cannot predate promotion.
#   - `agent-approves` — the repo's own earliest `approver-verdict` event
#     (`lib/merge-autonomy.sh`: the Approver stage arms "from the moment
#     [the level] lands and a repository's merge_autonomy rises above
#     human"). `approver-verdict` carries no `repo` field, so the repository
#     is read back off `pr_url`.
#
# A repository with no such event yet reports elapsed time `unavailable`,
# which under-counts (never over-counts) time already accrued — the same
# fail-safe direction requirement 3's "never satisfied from missing data"
# demands, and it is why the `agent-merges-routine`/`-all` landings count and
# the elapsed-time alternative share one proxy: a repo that has landed
# nothing yet cannot yet know its own promotion date from this signal either,
# and the criterion reads `not-met` from the (truthful) zero count rather
# than manufacturing an elapsed figure this script cannot support.
#
# ## Revert-or-follow-up rate vs the Stage 0 baseline
#
# `scripts/mine-merge-history.sh`'s own header says it "satisfies Stage 0";
# the earliest `docs/reviews/*-merge-autonomy-baseline.md` file in the
# repository (sorted by its dated filename) is read as that baseline,
# unavailable if none exists. The current rate is a fresh run of that same
# miner. Both are the same `(reverts + follow_up_fixes) / count` the miner
# already reports; this script does no post-merge classification of its own.
#
# ## Stage table source
#
# The stage numbers, levels and exit-criteria wording below are agent-ops#402
# (2026-08-18 amendment, restated 2026-08-20) — every printed report says so
# again, so a reader never has to take this script's word for the bars
# themselves.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/merge-autonomy.sh
. "$SCRIPT_DIR/lib/merge-autonomy.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
REVIEWS_DIR="$SCRIPT_DIR/docs/reviews"
MINER="$SCRIPT_DIR/scripts/mine-merge-history.sh"
LABEL=""
declare -a REPOS=()
state_dir_override=""
peers_dir_override=""
now_override=""

usage() {
  cat <<'EOF'
usage: autonomy-stage-report.sh [--config FILE] [--repo OWNER/REPO ...]
                                 [--label LABEL] [--reviews-dir DIR]
                                 [--state-dir DIR] [--peers-dir DIR]
                                 [--now ISO8601]

With no flags, reads the repo list from config.json's `repos[].slug` and the
pull-request label from `pr_label` (both next to this script). One or more
--repo overrides the config-file repo list entirely. --state-dir/--peers-dir
default to config.json's own `state_dir`/`workspace_root`; --now defaults to
the current UTC time and exists so a test run can fix "elapsed since" against
a fixed clock.

Prints a per-repository Markdown report — the repo's `merge_autonomy` level,
the D18 rollout stage (agent-ops#402) it corresponds to, that stage's exit
criteria, the measured value of each, and a closing verdict — followed by a
machine-readable JSON block carrying the same figures.

Needs `gh` (for the merged-PR record) and network access; changes nothing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --reviews-dir) REVIEWS_DIR="$2"; shift 2 ;;
    --state-dir) state_dir_override="$2"; shift 2 ;;
    --peers-dir) peers_dir_override="$2"; shift 2 ;;
    --now) now_override="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || { echo "autonomy-stage-report: config file not found: $CONFIG_FILE" >&2; exit 1; }
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")" || {
  echo "autonomy-stage-report: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 1
}
RAW_CONFIG="$(cat "$CONFIG_FILE")" || exit 1

if [[ ${#REPOS[@]} -eq 0 ]]; then
  mapfile -t REPOS < <(jq -r '.repos[].slug' <<<"$DEFAULTED_CONFIG")
  [[ ${#REPOS[@]} -gt 0 ]] || { echo "autonomy-stage-report: $CONFIG_FILE names no repos" >&2; exit 1; }
fi
[[ -n "$LABEL" ]] || LABEL="$(jq -r '.pr_label // "autonomous-agent"' <<<"$DEFAULTED_CONFIG")"

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(jq -r '.state_dir' <<<"$DEFAULTED_CONFIG")")"
fi
if [[ -n "$peers_dir_override" ]]; then
  peers_dir="$peers_dir_override"
else
  peers_dir="$(fleet_peers_dir "$(expand_home "$(jq -r '.workspace_root' <<<"$DEFAULTED_CONFIG")")")"
fi
now_iso="${now_override:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

EVENTS="$(fleet_logs "$state_dir" "$peers_dir" log.jsonl | jq -c -R 'fromjson? // empty' | jq -s -c '.' 2>/dev/null)"
[[ -n "$EVENTS" ]] || EVENTS='[]'

# --- The Stage 0 baseline: the earliest dated baseline file on disk --------
baseline_file="$(find "$REVIEWS_DIR" -maxdepth 1 -name '*-merge-autonomy-baseline.md' 2>/dev/null | sort | head -1)"
BASELINE_JSON='{}'
if [[ -n "$baseline_file" ]]; then
  BASELINE_JSON="$(awk '/```json/{f=1;next} /```/{f=0} f' "$baseline_file" | jq -c '.' 2>/dev/null)"
  [[ -n "$BASELINE_JSON" ]] && jq -e 'type == "object"' <<<"$BASELINE_JSON" >/dev/null 2>&1 || BASELINE_JSON='{}'
fi

# --- The D18 stage table (agent-ops#402, 2026-08-18 amendment) -------------
STAGE_TABLE='[
  {"level":"human","stage":"0",
   "criteria":[{"id":"baseline_recorded","desc":"a Stage 0 baseline is recorded"},
               {"id":"d18_on_main","desc":"D18 (the merge_autonomy key) is on main"}]},
  {"level":"agent-approves","stage":"1",
   "criteria":[{"id":"agent_approved_prs","desc":"≥15 agent-approved pull requests","threshold":15},
               {"id":"divergence","desc":"zero divergence between Approver verdict and human action"}]},
  {"level":"agent-merges-routine","stage":"2/3",
   "criteria":[{"id":"autonomous_landings","desc":"≥15 autonomous merges or 2 weeks elapsed","threshold":15,"elapsed_days":14},
               {"id":"classifier_escapes","desc":"zero classifier escapes"},
               {"id":"revert_rate","desc":"revert-or-follow-up rate ≤ the Stage 0 baseline"}]},
  {"level":"agent-merges-all","stage":"4",
   "criteria":[{"id":"human_merges","desc":"zero human merges in 14 days","window_days":14},
               {"id":"revert_rate","desc":"revert-or-follow-up rate ≤ the Stage 0 baseline"}]}
]'

# --- Small helpers -----------------------------------------------------------

# elapsed_days SINCE_ISO
# Days between SINCE_ISO and $now_iso, one decimal place; empty if SINCE_ISO
# is empty.
elapsed_days() {
  local since="$1"
  [[ -n "$since" ]] || return 0
  jq -nr --arg now "$now_iso" --arg since "$since" \
    '(((($now | fromdateiso8601) - ($since | fromdateiso8601)) / 86400) * 10 | round) / 10'
}

# since_landing_armed SLUG
# The repo's own earliest `landing-armed` timestamp, or empty.
since_landing_armed() {
  local slug="$1"
  jq -r --arg slug "$slug" \
    '[.[] | select(.event == "landing-armed" and .repo == $slug) | .ts] | sort | first // empty' \
    <<<"$EVENTS"
}

# --- Merged-PR record (GitHub), for the landing joins -----------------------

# merged_prs_json SLUG
# {ok, prs: [{number, merged_at, url}, ...]} for every merged, LABEL-carrying
# pull request in SLUG. One `gh` call; `ok:false` on any failure, distinct
# from a genuinely empty `prs`.
merged_prs_json() {
  local slug="$1" listing rc
  listing="$(gh api --paginate "repos/$slug/issues?labels=$LABEL&state=closed&per_page=100" \
    --jq '.[] | select(.pull_request != null) | select(.pull_request.merged_at != null)
              | {number, merged_at: .pull_request.merged_at, url: .pull_request.html_url}' 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    jq -nc '{ok:false, prs:[]}'
    return 0
  fi
  jq -nc --argjson prs "$(jq -s -c '.' <<<"$listing" 2>/dev/null || echo '[]')" '{ok:true, prs:$prs}'
}

# --- Per-criterion evaluators ------------------------------------------------
# Each prints one JSON object: {id, desc, status, measured} — status is
# "met", "not-met" or "unavailable". Never "met" without a measured value
# behind it (acceptance 3).

crit_baseline_recorded() {
  local desc="$1" status measured
  if [[ -n "$baseline_file" ]]; then
    status="met"; measured="recorded: $(basename "$baseline_file")"
  else
    status="not-met"; measured="no docs/reviews/*-merge-autonomy-baseline.md found"
  fi
  jq -nc --arg id "baseline_recorded" --arg desc "$desc" --arg status "$status" --arg measured "$measured" \
    '{id:$id, desc:$desc, status:$status, measured:$measured}'
}

crit_d18_on_main() {
  local desc="$1" status measured
  if jq -e '(has("merge_autonomy")) or ([(.repos // [])[] | select(has("merge_autonomy"))] | length > 0)' \
      <<<"$RAW_CONFIG" >/dev/null 2>&1; then
    status="met"; measured="merge_autonomy is configured"
  else
    status="not-met"; measured="merge_autonomy is not set anywhere in config.json"
  fi
  jq -nc --arg id "d18_on_main" --arg desc "$desc" --arg status "$status" --arg measured "$measured" \
    '{id:$id, desc:$desc, status:$status, measured:$measured}'
}

crit_agent_approved_prs() {
  local slug="$1" desc="$2" threshold="$3" count status measured
  # `pr_url` is matched by exact prefix, not substring: `contains` would
  # wrongly credit "Poetic-Poems/poetic" with every
  # "Poetic-Poems/poetic-fiddle" pull request too.
  count="$(jq -r --arg prefix "https://github.com/${slug,,}/pull/" \
    '[.[] | select(.event == "approver-verdict")
          | select(((.pr_url // "") | ascii_downcase) | startswith($prefix))
          | select(.verdict == "approve" or .verdict == "land")
          | (.pr_url // "")] | unique | length' <<<"$EVENTS")"
  if (( count >= threshold )); then status="met"; else status="not-met"; fi
  measured="$count agent-approved pull request(s) (need ≥$threshold)"
  jq -nc --arg id "agent_approved_prs" --arg desc "$desc" --arg status "$status" --arg measured "$measured" \
    '{id:$id, desc:$desc, status:$status, measured:$measured}'
}

crit_unavailable() {  # <id> <desc> <reason>
  local id="$1" desc="$2" reason="$3"
  jq -nc --arg id "$id" --arg desc "$desc" --arg reason "$reason" \
    '{id:$id, desc:$desc, status:"unavailable", measured:$reason}'
}

crit_autonomous_landings() {
  local slug="$1" desc="$2" threshold="$3" elapsed_threshold="$4"
  local since count elapsed status measured
  since="$(since_landing_armed "$slug")"
  local merged ok
  merged="$(merged_prs_json "$slug")"
  ok="$(jq -r '.ok' <<<"$merged")"
  if [[ "$ok" != "true" ]]; then
    crit_unavailable "autonomous_landings" "$desc" "the merged-pull-request record could not be read from GitHub"
    return 0
  fi
  local armed_urls
  armed_urls="$(jq -c --arg slug "$slug" \
    '[.[] | select(.event == "landing-armed" and .repo == $slug) | (.pr_url // "")] | unique' <<<"$EVENTS")"
  count="$(jq -nr --argjson merged "$merged" --argjson armed "$armed_urls" \
    '($armed | map(select(. != ""))) as $a
     | [$merged.prs[] | select(.url as $u | $a | index($u))] | length')"
  if [[ -n "$since" ]]; then
    elapsed="$(elapsed_days "$since")"
  else
    elapsed=""
  fi
  if (( count >= threshold )); then
    status="met"
  elif [[ -n "$elapsed" ]] && [[ "$(jq -n --argjson e "$elapsed" --argjson t "$elapsed_threshold" '$e >= $t')" == "true" ]]; then
    status="met"
  else
    status="not-met"
  fi
  if [[ -n "$elapsed" ]]; then
    measured="$count autonomous landing(s) since $since (${elapsed}d ago); need ≥$threshold or ≥${elapsed_threshold}d"
  else
    measured="$count autonomous landing(s); no landing-armed event yet, so elapsed time cannot be measured (need ≥$threshold or ≥${elapsed_threshold}d)"
  fi
  jq -nc --arg id "autonomous_landings" --arg desc "$desc" --arg status "$status" --arg measured "$measured" \
    '{id:$id, desc:$desc, status:$status, measured:$measured}'
}

crit_revert_rate() {
  local slug="$1" desc="$2"
  local baseline_stats baseline_count baseline_rate
  baseline_stats="$(jq -c --arg slug "$slug" '.repos[$slug].post_merge // empty' <<<"$BASELINE_JSON" 2>/dev/null)"
  if [[ -z "$baseline_stats" ]]; then
    crit_unavailable "revert_rate" "$desc" "no Stage 0 baseline recorded for $slug"
    return 0
  fi
  baseline_count="$(jq -r '(.reverts // 0) + (.follow_up_fixes // 0) + (.clean // 0)' <<<"$baseline_stats")"
  if [[ "$baseline_count" == "0" ]]; then
    crit_unavailable "revert_rate" "$desc" "the Stage 0 baseline for $slug carries no merged pull requests"
    return 0
  fi
  baseline_rate="$(jq -r '(((.reverts // 0) + (.follow_up_fixes // 0)) / (((.reverts // 0) + (.follow_up_fixes // 0) + (.clean // 0))) * 1000 | round) / 1000' <<<"$baseline_stats")"

  local miner_tmp current_file current_json current_stats current_count current_rate status measured
  miner_tmp="$(mktemp -d)"
  if ! current_file="$("$MINER" --repo "$slug" --label "$LABEL" --out-dir "$miner_tmp" 2>/dev/null)" || [[ ! -f "$current_file" ]]; then
    rm -rf "$miner_tmp"
    crit_unavailable "revert_rate" "$desc" "scripts/mine-merge-history.sh could not compute a current rate for $slug"
    return 0
  fi
  current_json="$(awk '/```json/{f=1;next} /```/{f=0} f' "$current_file" | jq -c '.' 2>/dev/null)"
  rm -rf "$miner_tmp"
  current_stats="$(jq -c --arg slug "$slug" '.repos[$slug].post_merge // empty' <<<"$current_json" 2>/dev/null)"
  if [[ -z "$current_stats" ]]; then
    crit_unavailable "revert_rate" "$desc" "scripts/mine-merge-history.sh returned no data for $slug"
    return 0
  fi
  current_count="$(jq -r '(.reverts // 0) + (.follow_up_fixes // 0) + (.clean // 0)' <<<"$current_stats")"
  if [[ "$current_count" == "0" ]]; then
    crit_unavailable "revert_rate" "$desc" "$slug has no merged pull requests to measure a current rate from"
    return 0
  fi
  current_rate="$(jq -r '(((.reverts // 0) + (.follow_up_fixes // 0)) / (((.reverts // 0) + (.follow_up_fixes // 0) + (.clean // 0))) * 1000 | round) / 1000' <<<"$current_stats")"

  if [[ "$(jq -n --argjson c "$current_rate" --argjson b "$baseline_rate" '$c <= $b')" == "true" ]]; then
    status="met"
  else
    status="not-met"
  fi
  measured="current $current_rate vs Stage 0 baseline $baseline_rate"
  jq -nc --arg id "revert_rate" --arg desc "$desc" --arg status "$status" --arg measured "$measured" \
    '{id:$id, desc:$desc, status:$status, measured:$measured}'
}

crit_human_merges() {
  local slug="$1" desc="$2" window_days="$3"
  local since_ts merged ok armed_urls count status measured
  since_ts="$(jq -nr --arg now "$now_iso" --argjson d "$window_days" \
    '($now | fromdateiso8601) - ($d * 86400) | todateiso8601')"
  merged="$(merged_prs_json "$slug")"
  ok="$(jq -r '.ok' <<<"$merged")"
  if [[ "$ok" != "true" ]]; then
    crit_unavailable "human_merges" "$desc" "the merged-pull-request record could not be read from GitHub"
    return 0
  fi
  armed_urls="$(jq -c --arg slug "$slug" \
    '[.[] | select(.event == "landing-armed" and .repo == $slug) | (.pr_url // "")] | unique' <<<"$EVENTS")"
  count="$(jq -nr --argjson merged "$merged" --argjson armed "$armed_urls" --arg since "$since_ts" \
    '($armed | map(select(. != ""))) as $a
     | [$merged.prs[] | select(.merged_at >= $since) | select(.url as $u | ($a | index($u)) | not)] | length')"
  if (( count == 0 )); then status="met"; else status="not-met"; fi
  measured="$count human-merged pull request(s) in the last ${window_days}d"
  jq -nc --arg id "human_merges" --arg desc "$desc" --arg status "$status" --arg measured "$measured" \
    '{id:$id, desc:$desc, status:$status, measured:$measured}'
}

# --- Per-repository evaluation ----------------------------------------------

evaluate_repo() {
  local slug="$1" level stage_entry stage criteria_ids results='[]' c cid desc threshold elapsed_thr window_days
  level="$(merge_autonomy_configured_level "$DEFAULTED_CONFIG" "$slug")"
  stage_entry="$(jq -c --arg lvl "$level" '.[] | select(.level == $lvl)' <<<"$STAGE_TABLE")"
  if [[ -z "$stage_entry" ]]; then
    printf '%s\n' "$(jq -nc --arg slug "$slug" --arg level "$level" \
      '{slug:$slug, level:$level, stage:null, criteria:[], verdict:"insufficient-evidence: unrecognised level"}')"
    return 0
  fi
  stage="$(jq -r '.stage' <<<"$stage_entry")"

  while IFS= read -r c; do
    cid="$(jq -r '.id' <<<"$c")"
    desc="$(jq -r '.desc' <<<"$c")"
    case "$cid" in
      baseline_recorded) results="$(jq -c --argjson r "$(crit_baseline_recorded "$desc")" '. + [$r]' <<<"$results")" ;;
      d18_on_main) results="$(jq -c --argjson r "$(crit_d18_on_main "$desc")" '. + [$r]' <<<"$results")" ;;
      agent_approved_prs)
        threshold="$(jq -r '.threshold' <<<"$c")"
        results="$(jq -c --argjson r "$(crit_agent_approved_prs "$slug" "$desc" "$threshold")" '. + [$r]' <<<"$results")"
        ;;
      divergence)
        results="$(jq -c --argjson r "$(crit_unavailable "divergence" "$desc" "no App-verdict/human-action divergence tracker yet (agent-ops#573)")" '. + [$r]' <<<"$results")"
        ;;
      autonomous_landings)
        threshold="$(jq -r '.threshold' <<<"$c")"; elapsed_thr="$(jq -r '.elapsed_days' <<<"$c")"
        results="$(jq -c --argjson r "$(crit_autonomous_landings "$slug" "$desc" "$threshold" "$elapsed_thr")" '. + [$r]' <<<"$results")"
        ;;
      classifier_escapes)
        results="$(jq -c --argjson r "$(crit_unavailable "classifier_escapes" "$desc" "no classifier-escape detector yet (agent-ops#572)")" '. + [$r]' <<<"$results")"
        ;;
      revert_rate)
        results="$(jq -c --argjson r "$(crit_revert_rate "$slug" "$desc")" '. + [$r]' <<<"$results")"
        ;;
      human_merges)
        window_days="$(jq -r '.window_days' <<<"$c")"
        results="$(jq -c --argjson r "$(crit_human_merges "$slug" "$desc" "$window_days")" '. + [$r]' <<<"$results")"
        ;;
      *)
        results="$(jq -c --argjson r "$(crit_unavailable "$cid" "$desc" "no evaluator for this criterion")" '. + [$r]' <<<"$results")"
        ;;
    esac
  done < <(jq -c '.criteria[]' <<<"$stage_entry")

  local verdict not_met
  not_met="$(jq -r '[.[] | select(.status == "not-met") | .id] | join(", ")' <<<"$results")"
  if [[ -n "$not_met" ]]; then
    verdict="not-met (criterion: $not_met)"
  elif jq -e 'any(.[]; .status == "unavailable")' <<<"$results" >/dev/null 2>&1; then
    verdict="insufficient-evidence"
  else
    verdict="met"
  fi

  jq -nc --arg slug "$slug" --arg level "$level" --arg stage "$stage" --argjson criteria "$results" --arg verdict "$verdict" \
    '{slug:$slug, level:$level, stage:$stage, criteria:$criteria, verdict:$verdict}'
}

# --- Render ------------------------------------------------------------------

printf '# D18 Autonomy Stage Report — %s\n\n' "$now_iso"
printf 'Stage table source: agent-ops#402 (2026-08-18 amendment). Baseline: %s\n\n' \
  "${baseline_file:-none recorded}"

ALL_RESULTS='[]'
for slug in "${REPOS[@]}"; do
  repo_json="$(evaluate_repo "$slug")"
  ALL_RESULTS="$(jq -c --argjson r "$repo_json" '. + [$r]' <<<"$ALL_RESULTS")"

  level="$(jq -r '.level' <<<"$repo_json")"
  stage="$(jq -r '.stage' <<<"$repo_json")"
  verdict="$(jq -r '.verdict' <<<"$repo_json")"
  printf '## %s\n\n' "$slug"
  printf 'merge_autonomy: **%s** (Stage %s)\n\n' "$level" "$stage"
  jq -r '.criteria[] | "- \(.id): \(.measured) — **\(.status)**"' <<<"$repo_json"
  printf '\nVerdict: **%s**\n\n' "$verdict"
done

printf '## Raw data\n\n```json\n'
jq -nc --arg generated "$now_iso" --arg stage_table_source "agent-ops#402" --argjson repos "$ALL_RESULTS" \
  '{generated_at: $generated, stage_table_source: $stage_table_source, repos: $repos}'
printf '\n```\n'
