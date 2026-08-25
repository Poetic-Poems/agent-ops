#!/usr/bin/env bash
#
# publish-revert-rate.sh — D18 issue #579 (a WI of umbrella #402): run the
# merged-PR miner on a cadence and publish the revert-or-follow-up rate
# against the recorded Stage 0 baseline.
#
# scripts/mine-merge-history.sh computed the Stage 0 baseline once, by hand,
# in docs/reviews/2026-08-15-merge-autonomy-baseline.md, and has not run
# since — Stage 2's exit criterion ("revert rate ≤ baseline") is continuous,
# and measuring it only when someone remembers to means a regression is
# discovered by a promotion review rather than when it actually happens. This
# script is meant to run once a day, from its own crontab line
# (deploy/docker/crontab.tmpl, schedule.revert_rate_hour/
# revert_rate_offset_minutes), and needs no human to invoke it.
#
# ## Three numbers, not one
#
# Per repository, this publishes:
#
#   rolling      The day-of operational signal: every merged, labelled pull
#                request in the last `--window-days` (14 by default) whose
#                own 48-hour post-merge observation window has fully
#                elapsed — i.e. excluding anything merged in the last 48
#                hours, whose outcome cannot be known yet — with a floor of
#                `--min-samples` (10) before a rate is reported at all
#                (rather than a rate an operator would over-read from three
#                pull requests).
#   cumulative   Every merged, labelled pull request since the baseline was
#                recorded (config.json's `revert_rate_baseline.generated`),
#                unfiltered. This is what Stage 2's own exit criterion reads
#                — an all-population aggregate compared against the
#                all-population baseline it was measured the same way.
#   baseline     The stored Stage 0 figures themselves, copied once into
#                config.json rather than re-derived (revert_rate_baseline;
#                see config.schema.json) — never recomputed by scanning
#                docs/reviews/ at runtime the way
#                scripts/autonomy-stage-report.sh (issue #571, out of this
#                item's scope) still does for its own one-off comparison.
#
# `above_baseline` compares cumulative against baseline, since those two are
# measured the same way (both all-population); the rolling figure exists for
# a human watching the dashboard, not for that comparison.
#
# ## Why two mining passes ("since" subtraction), not one, for the rolling figure
#
# scripts/mine-merge-history.sh's aggregate output has no way to filter an
# already-mined population further, so "everything in the last 14 days
# except the last 48 hours" is computed as two separate `--since`-bounded
# mining passes — 14 days ago, and 48 hours ago — with the rolling figure the
# arithmetic difference (count, reverts, follow-up-fixes each subtracted
# independently).
#
# This is exact, not approximate, despite each pass computing its own
# post-merge outcomes against only its own mined population (the file-overlap
# half of that detection only ever checks other pull requests *in the same
# mined population* — see that script's own header): any pull request
# outcome-classified as a revert or follow-up of a pull request P must have
# merged strictly after P and no later than P's own merge instant + 48h. When
# P itself merged within the last 48 hours, that partner's own merge instant
# is therefore also within the last 48 hours (later than P, which is already
# >= now-48h, and no later than now, since nothing merges in the future) — so
# every partner a fully-fledged 14-day mining pass could find for such a P is
# already present in the 48-hour-only pass too, and the two passes agree on
# P's classification. Subtracting the 48-hour pass's counts from the 14-day
# pass's therefore removes exactly — never partially — the still-unsettled
# population, leaving only pull requests whose full 48-hour observation
# window has already elapsed.
#
# ## GitHub API quota
#
# Every mining pass shells out to scripts/mine-merge-history.sh, which reads
# GitHub through lib/github-limit.sh's `gh` wrapper — the fleet-wide rate
# limit is waited out there, and a transient network failure is retried
# there too (gh_retry, three attempts). Nothing here re-implements either: a
# repository whose mining pass still fails after those retries logs why on
# stderr and is skipped for this run (no row written for it), which surfaces
# as a stale (or absent) entry in revert-rate.jsonl and, downstream, the
# dashboard panel — never a fabricated rate. The crontab line's own `|| true`
# means a partial run (some repositories skipped) never reads as a crashed
# script in `cron.log`.
#
# The cumulative-since-baseline pass is the one pass whose --since bound
# isn't a fixed offset from "now": naively, it would mine the population
# since the fixed baseline date afresh on every run, an unbounded cost that
# only grows as the baseline recedes into the past. Instead, each repo's
# *settled* portion (>48h post-merge, whose outcome cannot change again — see
# "Post-merge outcome" in scripts/mine-merge-history.sh's own header) is
# cached in `<state_dir>/revert-rate-cumulative-state.json` and rolled
# forward: a run mines only the delta since the previous run's own settled
# boundary, subtracts out the still-unsettled tail (reusing the `recent_stats`
# pass already mined for the rolling figure — no extra API cost there), and
# adds the remainder to the cached settled aggregate. A repo with no usable
# cached state (new to this node, or the configured baseline has moved) falls
# back to one full baseline-bound pass — the only place this pass is still
# unbounded, and only once per repo per node. TD-PPagop-26082204 tracks this.
#
# Usage:
#   scripts/publish-revert-rate.sh [--config FILE] [--repo OWNER/REPO ...]
#                                   [--label LABEL] [--state-dir DIR]
#                                   [--window-days N] [--min-samples N]
#                                   [--now ISO8601]
#
# With no flags, reads the repo list from config.json's `repos[].slug`, the
# pull-request label from `pr_label`, and the baseline from
# `revert_rate_baseline` (all next to this script). Appends one JSON line per
# repository to `<state_dir>/revert-rate.jsonl` — envelope shape `{ts, node,
# event, repo, ...}`, the same as `log.jsonl` (lib/fleet.sh's `fleet_logs`
# unions it fleet-wide the identical way). A repository absent from
# `revert_rate_baseline.repos` still gets its rolling figure; its cumulative
# and baseline blocks read `null` throughout rather than failing the run.
# The cumulative-since-baseline pass also maintains this node's own
# `<state_dir>/revert-rate-cumulative-state.json`, one settled-aggregate
# cache per repository (see "GitHub API quota" above) — local memoisation,
# not published output.
#
# Exit status: 0 iff every configured repository's rolling figure was
# published; 1 if any repository's mining passes failed (its row is still
# skipped, not fabricated) — the same "loud, not silent" posture
# scripts/mine-merge-history.sh itself takes on an unreadable repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
MINER="$SCRIPT_DIR/scripts/mine-merge-history.sh"
LABEL=""
declare -a REPOS=()
state_dir_override=""
window_days=14
min_samples=10
now_override=""

usage() {
  cat <<'EOF'
usage: publish-revert-rate.sh [--config FILE] [--repo OWNER/REPO ...]
                               [--label LABEL] [--state-dir DIR]
                               [--window-days N] [--min-samples N]
                               [--now ISO8601]

With no flags, reads the repo list from config.json's `repos[].slug`, the
pull-request label from `pr_label`, and the baseline from
`revert_rate_baseline` (all next to this script). Appends one JSON line per
repository to <state_dir>/revert-rate.jsonl. --window-days (14) and
--min-samples (10) bound the rolling-window figure; --now fixes "now" for a
reproducible test run.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --state-dir) state_dir_override="$2"; shift 2 ;;
    --window-days) window_days="$2"; shift 2 ;;
    --min-samples) min_samples="$2"; shift 2 ;;
    --now) now_override="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

if ! [[ "$window_days" =~ ^[0-9]+$ ]] || (( window_days < 1 )); then
  echo "publish-revert-rate: --window-days must be a positive integer" >&2; exit 64
fi
if ! [[ "$min_samples" =~ ^[0-9]+$ ]]; then
  echo "publish-revert-rate: --min-samples must be a non-negative integer" >&2; exit 64
fi

[[ -f "$CONFIG_FILE" ]] || { echo "publish-revert-rate: config file not found: $CONFIG_FILE" >&2; exit 1; }
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")" || {
  echo "publish-revert-rate: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 1
}

if [[ ${#REPOS[@]} -eq 0 ]]; then
  mapfile -t REPOS < <(jq -r '.repos[].slug' <<<"$DEFAULTED_CONFIG")
  [[ ${#REPOS[@]} -gt 0 ]] || { echo "publish-revert-rate: $CONFIG_FILE names no repos" >&2; exit 1; }
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
mkdir -p "$state_dir"
out_file="$state_dir/revert-rate.jsonl"
cum_state_file="$state_dir/revert-rate-cumulative-state.json"
[[ -s "$cum_state_file" ]] || printf '{}' > "$cum_state_file"

now_iso="${now_override:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
jq -n --arg n "$now_iso" '$n | fromdateiso8601' >/dev/null 2>&1 \
  || { echo "publish-revert-rate: --now is not a valid ISO 8601 instant: $now_iso" >&2; exit 64; }

since_window="$(jq -nr --arg now "$now_iso" --argjson d "$window_days" \
  '($now | fromdateiso8601) - ($d * 86400) | todateiso8601')"
since_recent="$(jq -nr --arg now "$now_iso" '($now | fromdateiso8601) - 172800 | todateiso8601')"

# The same node-name convention agent-cycle.sh's own log_event uses: sanitised
# because it lands in a JSON field meant to be grep-friendly, not because
# anything here uses it as a path.
node_name="${NODE_NAME:-$(hostname)}"
node_name="${node_name//[^A-Za-z0-9._-]/-}"

BASELINE_JSON="$(jq -c '.revert_rate_baseline // {}' <<<"$DEFAULTED_CONFIG")"
baseline_generated="$(jq -r '.generated // empty' <<<"$BASELINE_JSON")"
baseline_since=""
[[ -z "$baseline_generated" ]] || baseline_since="${baseline_generated}T00:00:00Z"

# mine_window SLUG SINCE — prints the miner's raw-JSON stats object for SLUG
# at that --since bound (`{count, post_merge: {reverts, follow_up_fixes,
# ...}, ...}`), or nothing and a non-zero return on any failure: an unreadable
# repository, a malformed report, or a since bound the repo's baseline never
# reached.
mine_window() {
  local slug="$1" since="$2"
  local tmp file rc raw
  tmp="$(mktemp -d)" || return 1
  file="$("$MINER" --repo "$slug" --label "$LABEL" --out-dir "$tmp" --since "$since")"
  rc=$?
  if (( rc != 0 )) || [[ ! -f "$file" ]]; then
    rm -rf "$tmp"
    return 1
  fi
  raw="$(awk '/```json/{f=1;next}/```/{f=0}f' "$file" | jq -c --arg slug "$slug" '.repos[$slug] // empty' 2>/dev/null)"
  rm -rf "$tmp"
  [[ -n "$raw" ]] || return 1
  printf '%s' "$raw"
}

# stat_add/stat_sub A_JSON B_JSON — the three fields the cumulative-since-
# baseline rolling-forward logic below combines, added or subtracted
# component-wise. Both take (and produce) the same `{count, post_merge:
# {reverts, follow_up_fixes}}` shape mine_window's raw output carries (extra
# fields, if any, are dropped).
stat_add() {
  jq -nc --argjson a "$1" --argjson b "$2" \
    '{count: ($a.count + $b.count),
      post_merge: {reverts: ($a.post_merge.reverts + $b.post_merge.reverts),
                   follow_up_fixes: ($a.post_merge.follow_up_fixes + $b.post_merge.follow_up_fixes)}}'
}
stat_sub() {
  jq -nc --argjson a "$1" --argjson b "$2" \
    '{count: ($a.count - $b.count),
      post_merge: {reverts: ($a.post_merge.reverts - $b.post_merge.reverts),
                   follow_up_fixes: ($a.post_merge.follow_up_fixes - $b.post_merge.follow_up_fixes)}}'
}

# cum_state_get SLUG — prints SLUG's cached {settled_aggregate, settled_until,
# baseline_since} entry, or "null" if this node has none yet.
cum_state_get() {
  jq -c --arg slug "$1" '.[$slug] // null' "$cum_state_file"
}

# cum_state_put SLUG ENTRY_JSON — persists SLUG's entry, replacing any prior
# one for that repo; other repos' entries are untouched.
cum_state_put() {
  local slug="$1" entry="$2" tmp
  tmp="$(mktemp)" || return 1
  jq -c --arg slug "$slug" --argjson entry "$entry" '.[$slug] = $entry' "$cum_state_file" > "$tmp" \
    && mv "$tmp" "$cum_state_file"
}

# shellcheck disable=SC2016  # jq's own $w/$r/$cum/$base/etc, not the shell's.
RATE_JQ='
def rate3($n; $x): if $n == 0 then null else (($x / $n) * 1000 | round) / 1000 end;
($w.count) as $wc | ($w.post_merge.reverts) as $wrv | ($w.post_merge.follow_up_fixes) as $wfu
| ($r.count) as $rc | ($r.post_merge.reverts) as $rrv | ($r.post_merge.follow_up_fixes) as $rfu
| ($wc - $rc) as $rn | ($wrv - $rrv) as $rrev | ($wfu - $rfu) as $rfollow
| {
    ts: $ts, node: $node, event: "revert-rate", repo: $repo, window_days: $window_days,
    rolling: {
      since: $since_window, excludes_merged_after: $since_recent, min_samples: $min_samples,
      n: $rn, reverts: $rrev, follow_up_fixes: $rfollow,
      insufficient_samples: ($rn < $min_samples),
      rate: (if $rn < $min_samples then null else rate3($rn; $rrev + $rfollow) end)
    },
    cumulative: (
      if $cum == null then {since: (if $baseline_since == "" then null else $baseline_since end),
                             n: null, reverts: null, follow_up_fixes: null, rate: null}
      else {since: $baseline_since, n: $cum.count, reverts: $cum.post_merge.reverts,
            follow_up_fixes: $cum.post_merge.follow_up_fixes,
            rate: rate3($cum.count; $cum.post_merge.reverts + $cum.post_merge.follow_up_fixes)}
      end
    ),
    baseline: (
      if $base == null then {generated: null, n: null, reverts: null, follow_up_fixes: null, rate: null}
      else {generated: $baseline_generated, n: $base.count, reverts: $base.reverts,
            follow_up_fixes: $base.follow_up_fixes,
            rate: rate3($base.count; $base.reverts + $base.follow_up_fixes)}
      end
    )
  }
| . + {above_baseline: (if .cumulative.rate == null or .baseline.rate == null
                         then null else (.cumulative.rate > .baseline.rate) end)}
'

rc=0
for slug in "${REPOS[@]}"; do
  echo "publish-revert-rate: mining $slug ..." >&2
  window_stats="$(mine_window "$slug" "$since_window")" || {
    echo "publish-revert-rate: $slug: rolling-window mining pass failed; skipping this repo" >&2
    rc=1; continue
  }
  recent_stats="$(mine_window "$slug" "$since_recent")" || {
    echo "publish-revert-rate: $slug: last-48h mining pass failed; skipping this repo" >&2
    rc=1; continue
  }

  cum_stats='null'
  if [[ -n "$baseline_since" ]]; then
    cum_entry="$(cum_state_get "$slug")"
    if [[ "$cum_entry" != "null" ]] \
       && [[ "$(jq -r '.baseline_since' <<<"$cum_entry")" == "$baseline_since" ]]; then
      # Usable cache: mine only the delta since the previous run's own
      # settled boundary, subtract out the still-unsettled tail (recent_stats,
      # already mined above for the rolling figure), and roll the remainder
      # into the cached settled aggregate — the same "since subtraction" exact-
      # not-approximate argument the rolling figure's own header explains,
      # here with the previous settled_until/since_recent pair standing in for
      # the rolling window's 14-day/48-hour pair.
      prev_settled_until="$(jq -r '.settled_until' <<<"$cum_entry")"
      prev_settled_aggregate="$(jq -c '.settled_aggregate' <<<"$cum_entry")"
      if delta_stats="$(mine_window "$slug" "$prev_settled_until")"; then
        newly_settled="$(stat_sub "$delta_stats" "$recent_stats")"
        new_settled_aggregate="$(stat_add "$prev_settled_aggregate" "$newly_settled")"
        cum_stats="$(stat_add "$new_settled_aggregate" "$recent_stats")"
        cum_state_put "$slug" "$(jq -nc --argjson agg "$new_settled_aggregate" \
          --arg su "$since_recent" --arg bs "$baseline_since" \
          '{settled_aggregate: $agg, settled_until: $su, baseline_since: $bs}')"
      else
        echo "publish-revert-rate: $slug: cumulative-since-baseline delta mining pass failed; cumulative reads unavailable for this run" >&2
      fi
    else
      # No usable cache — new to this node, or the configured baseline has
      # moved. One full baseline-bound pass, same as every run used to do;
      # this seeds the cache so the next run can roll forward instead.
      if cum_full="$(mine_window "$slug" "$baseline_since")"; then
        settled_aggregate="$(stat_sub "$cum_full" "$recent_stats")"
        cum_stats="$cum_full"
        cum_state_put "$slug" "$(jq -nc --argjson agg "$settled_aggregate" \
          --arg su "$since_recent" --arg bs "$baseline_since" \
          '{settled_aggregate: $agg, settled_until: $su, baseline_since: $bs}')"
      else
        echo "publish-revert-rate: $slug: cumulative-since-baseline mining pass failed; cumulative reads unavailable for this run" >&2
      fi
    fi
  fi

  base_entry="$(jq -c --arg slug "$slug" '(.repos // [])[] | select(.slug == $slug)' <<<"$BASELINE_JSON" 2>/dev/null)"
  [[ -n "$base_entry" ]] || base_entry='null'

  row="$(jq -nc \
    --arg ts "$now_iso" --arg node "$node_name" --arg repo "$slug" \
    --argjson window_days "$window_days" --argjson min_samples "$min_samples" \
    --arg since_window "$since_window" --arg since_recent "$since_recent" \
    --argjson w "$window_stats" --argjson r "$recent_stats" \
    --argjson cum "$cum_stats" \
    --arg baseline_since "$baseline_since" --arg baseline_generated "$baseline_generated" \
    --argjson base "$base_entry" \
    "$RATE_JQ")" || {
    echo "publish-revert-rate: $slug: row assembly failed; skipping this repo" >&2
    rc=1; continue
  }
  printf '%s\n' "$row" >> "$out_file"
done

exit "$rc"
