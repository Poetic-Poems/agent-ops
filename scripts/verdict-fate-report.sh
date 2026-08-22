#!/usr/bin/env bash
#
# scripts/verdict-fate-report.sh — D18 Approver-verdict/human-action
# divergence report (agent-ops#573, a WI of umbrella #402).
#
# The record `agent-cycle.sh`'s `run_approver_stage` writes live
# (`approver-verdict`, requirement 33) carries only half the pairing this
# report exists to state — the verdict. This joins that half with each pull
# request's own live GitHub state (whether it merged, who armed it, whether a
# human has posted a `CHANGES_REQUESTED` since the verdict) via
# `lib/verdict-fate.sh`'s pure classifier, and prints, for each configured
# repository, its current D18 level and stage, and — for that repository —
# agreement, divergence and sample size over the report's window, declining
# to state a rate below `--min-sample`. Argless-runnable against config.json.
#
# `scripts/autonomy-stage-report.sh`'s own Stage 1 `divergence` criterion
# calls the same `lib/verdict-fate.sh` functions this script does, rather
# than shelling out here — the two together satisfy agent-ops#571 without
# recomputing the join twice, though a change to the classification logic in
# the library changes both at once, deliberately.
#
# ## "Over a window", and why the default is "since ever"
#
# `--since ISO8601` restricts the pull requests considered to those whose
# latest approver-verdict landed on or after that timestamp; with no
# `--since`, every approver-verdict event the fleet log still holds counts —
# safe because `log.jsonl` is never rotated (requirement 2.6, component 3i),
# so "since ever" is already bounded by however long this installation has
# run, not by a rotation window. A dashboard or a periodic report can still
# pass `--since` to trend a recent slice; the stage-report caller never does,
# since a stage's own exit criterion is about the *whole* record, not a
# recent window of it.

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
# shellcheck source=lib/verdict-fate.sh
. "$SCRIPT_DIR/lib/verdict-fate.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
declare -a REPOS=()
state_dir_override=""
peers_dir_override=""
since=""
min_sample=5

usage() {
  cat <<'EOF'
usage: verdict-fate-report.sh [--config FILE] [--repo OWNER/REPO ...]
                               [--state-dir DIR] [--peers-dir DIR]
                               [--since ISO8601] [--min-sample N]

With no flags, reads the repo list from config.json's `repos[].slug`.
One or more --repo overrides the config-file repo list entirely.
--state-dir/--peers-dir default to config.json's own `state_dir`/
`workspace_root`. --since restricts to pull requests whose latest
approver-verdict landed on or after that timestamp (default: every verdict
the fleet log still holds). --min-sample (default 5) is the smallest
agreement+divergence count a rate is stated for; below it the report says
`insufficient-sample` instead.

Prints, per repository, its D18 `merge_autonomy` level and stage
(agent-ops#402), then agreement/divergence/sample size/rate, followed by a
machine-readable JSON block carrying the same figures — one entry per pull
request the Approver ruled on (agent-ops#573).

Needs `gh` (per-pull-request state and reviews) and network access; changes
nothing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    --state-dir) state_dir_override="$2"; shift 2 ;;
    --peers-dir) peers_dir_override="$2"; shift 2 ;;
    --since) since="$2"; shift 2 ;;
    --min-sample) min_sample="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || { echo "verdict-fate-report: config file not found: $CONFIG_FILE" >&2; exit 1; }
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")" || {
  echo "verdict-fate-report: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 1
}

if [[ ${#REPOS[@]} -eq 0 ]]; then
  mapfile -t REPOS < <(jq -r '.repos[].slug' <<<"$DEFAULTED_CONFIG")
  [[ ${#REPOS[@]} -gt 0 ]] || { echo "verdict-fate-report: $CONFIG_FILE names no repos" >&2; exit 1; }
fi

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

EVENTS="$(fleet_logs "$state_dir" "$peers_dir" log.jsonl | jq -c -R 'fromjson? // empty' | jq -s -c '.' 2>/dev/null)"
[[ -n "$EVENTS" ]] || EVENTS='[]'
if [[ -n "$since" ]]; then
  EVENTS="$(jq -c --arg since "$since" '[.[] | select((.ts // "") >= $since or .event != "approver-verdict")]' <<<"$EVENTS")"
fi

# --- D18 stage table (agent-ops#402) — level to stage label only -----------
level_stage() {
  case "${1:-human}" in
    human) printf '0' ;;
    agent-approves) printf '1' ;;
    agent-merges-routine) printf '2/3' ;;
    agent-merges-all) printf '4' ;;
    *) printf 'unknown' ;;
  esac
}

# --- Pull-request URL parsing (same shape lib/approver.sh's own
# _approver_pr_parts computes, duplicated for the same stated reason: this
# file sources and runs standalone) ------------------------------------------
_vfr_pr_parts() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  printf '%s/%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# vfr_pr_state_json PR_URL
# {ok, state} — `state` one of `open`/`closed`/`merged` (GitHub's `state`
# plus `merged` folded into one three-value vocabulary), `ok:false` on any
# read failure.
vfr_pr_state_json() {
  local url="$1" parts slug number body rc
  parts="$(_vfr_pr_parts "$url")" || { jq -nc '{ok:false, state:""}'; return 0; }
  IFS=$'\t' read -r slug number <<<"$parts"
  body="$(gh api "repos/$slug/pulls/$number" --jq '{state, merged}' 2>/dev/null)"
  rc=$?
  if (( rc != 0 )) || [[ -z "$body" ]]; then
    jq -nc '{ok:false, state:""}'
    return 0
  fi
  jq -nc --argjson b "$body" '{ok:true, state: (if $b.merged then "merged" else $b.state end)}'
}

# vfr_pr_reviews_json PR_URL
# {ok, reviews} — `reviews` the array `lib/verdict-fate.sh`'s
# `verdict_fate_classify` expects: `{login, state, submitted_at, bot}`, one
# per submitted review. Same REST endpoint and bot rule
# `lib/approver.sh`'s `approver_refuse_streak` already uses.
vfr_pr_reviews_json() {
  local url="$1" parts slug number lines rc
  parts="$(_vfr_pr_parts "$url")" || { jq -nc '{ok:false, reviews:[]}'; return 0; }
  IFS=$'\t' read -r slug number <<<"$parts"
  lines="$(gh api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null)
                      | {login: .user.login, state: .state, submitted_at: .submitted_at,
                         bot: (((.user.type // "User") == "Bot") or (.user.login | endswith("[bot]")))}' \
            2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    jq -nc '{ok:false, reviews:[]}'
    return 0
  fi
  jq -nc --argjson r "$(jq -s -c '.' <<<"$lines" 2>/dev/null || echo '[]')" '{ok:true, reviews:$r}'
}

# --- Per-repository evaluation ----------------------------------------------

evaluate_repo() {
  local slug="$1" level stage entries entry pr_url armed armed_urls
  local state_json reviews_json state ok1 ok2 posted_review classified
  local classified_list='[]' summary

  level="$(merge_autonomy_configured_level "$DEFAULTED_CONFIG" "$slug")"
  stage="$(level_stage "$level")"

  entries="$(verdict_fate_latest_per_pr "$EVENTS" "$slug")"
  armed_urls="$(jq -c --arg slug "$slug" \
    '[.[] | select(.event == "landing-armed" and .repo == $slug) | (.pr_url // "")] | unique' <<<"$EVENTS")"

  local unreadable=0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    pr_url="$(jq -r '.pr_url' <<<"$entry")"
    posted_review="$(jq -r '.posted_review' <<<"$entry")"
    armed="$(jq -r --arg u "$pr_url" 'index($u) != null' <<<"$armed_urls")"
    state_json="$(vfr_pr_state_json "$pr_url")"
    ok1="$(jq -r '.ok' <<<"$state_json")"
    reviews_json="$(vfr_pr_reviews_json "$pr_url")"
    ok2="$(jq -r '.ok' <<<"$reviews_json")"
    if [[ "$ok1" != "true" || "$ok2" != "true" ]]; then
      unreadable=$(( unreadable + 1 ))
      continue
    fi
    state="$(jq -r '.state' <<<"$state_json")"
    classified="$(verdict_fate_classify "$posted_review" "$armed" "$state" \
      "$(jq -c '.reviews' <<<"$reviews_json")" "$(jq -r '.first_approve_ts' <<<"$entry")")"
    classified_list="$(jq -c --argjson e "$entry" --argjson c "$classified" '. + [$e + $c]' <<<"$classified_list")"
  done < <(jq -c '.[]' <<<"$entries")

  summary="$(verdict_fate_summarize "$classified_list" "$min_sample")"
  jq -nc --arg slug "$slug" --arg level "$level" --arg stage "$stage" \
    --argjson entries "$classified_list" --argjson summary "$summary" --argjson unreadable "$unreadable" \
    '{slug:$slug, level:$level, stage:$stage, entries:$entries, summary:$summary, unreadable:$unreadable}'
}

# --- Render ------------------------------------------------------------------

printf '# D18 Approver-Verdict Divergence Report\n\n'
printf 'Source: agent-ops#573. Window: %s. Minimum sample: %s.\n\n' \
  "${since:-every verdict the fleet log still holds}" "$min_sample"

ALL_RESULTS='[]'
for slug in "${REPOS[@]}"; do
  repo_json="$(evaluate_repo "$slug")"
  ALL_RESULTS="$(jq -c --argjson r "$repo_json" '. + [$r]' <<<"$ALL_RESULTS")"

  level="$(jq -r '.level' <<<"$repo_json")"
  stage="$(jq -r '.stage' <<<"$repo_json")"
  printf '## %s\n\n' "$slug"
  printf 'merge_autonomy: **%s** (Stage %s)\n\n' "$level" "$stage"
  jq -r '.summary | "- agreement: \(.agreement)\n- divergence: \(.divergence)\n- pending: \(.pending)\n- sample: \(.sample)\n- rate: \(.rate // "n/a")\n- status: **\(.status)**"' <<<"$repo_json"
  unreadable="$(jq -r '.unreadable' <<<"$repo_json")"
  if [[ "$unreadable" != "0" ]]; then
    printf '\n%s pull request(s) could not be read from GitHub this run and are excluded above.\n' "$unreadable"
  fi
  printf '\n'
done

printf '## Raw data\n\n```json\n'
jq -nc --arg source "agent-ops#573" --argjson repos "$ALL_RESULTS" \
  '{source: $source, repos: $repos}'
printf '\n```\n'
