#!/usr/bin/env bash
#
# publish-dashboard.sh — regenerate the local monitoring dashboard.
#
# Reads the pipeline's on-disk state (log.jsonl, per-cycle transcripts,
# lock.json, cron.log) plus live GitHub data (via gh), and writes a single
# self-contained data file (data.js) next to a copy of the dashboard's
# index.html under <state_dir>/dashboard/. Open that index.html in a browser
# to view the dashboard — no server, no open port, nothing leaves the machine.
#
# Safe to run any time: it only reads the pipeline's state, never writes into
# it, never touches the lock, and cannot disturb a running cycle. Costs
# nothing to run (no model calls). Companion doc: docs/BUILD-DASHBOARD-PROMPT.md.

set -uo pipefail

# --- PATH: cron's environment is minimal; make sure jq, gh, git resolve. -----
path_dirs=(/usr/local/bin /usr/bin /bin "$HOME/.local/bin")
PATH="$(IFS=:; echo "${path_dirs[*]}"):$PATH"
export PATH

for bin in jq gh; do
  command -v "$bin" >/dev/null 2>&1 || { echo "publish-dashboard: missing binary: $bin" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
TEMPLATE="$SCRIPT_DIR/dashboard/index.html"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"

MAX_CYCLES=40        # recent cycles shown in detail (with transcripts)
MAX_LOG_TAIL=300     # recent raw log events surfaced
TRANSCRIPT_CAP=40000 # bytes kept per transcript / stderr
GH_TIMEOUT=15        # seconds per gh call
COST_SCAN_DAYS=60    # how far back to scan transcripts for cost roll-ups

WITH_GITHUB=1
[[ "${1:-}" == "--no-github" ]] && WITH_GITHUB=0

# --- Config ------------------------------------------------------------------
expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
cfg()      { jq -r "$1" "$CONFIG_FILE" 2>/dev/null; }
cfg_json() { jq -c "$1" "$CONFIG_FILE" 2>/dev/null; }

state_dir="$(expand_home "$(cfg '.state_dir')")"
log_file="$state_dir/log.jsonl"
lock_file="$state_dir/lock.json"
cron_log="$state_dir/cron.log"
cycles_dir="$state_dir/cycles"
pr_label="$(cfg '.pr_label')"
max_open_agent_prs="$(cfg '.max_open_agent_prs')"
repos_json="$(cfg_json '.repos')"

out_dir="$state_dir/dashboard"
data_file="$out_dir/data.js"
mkdir -p "$out_dir"

# Large JSON blobs (the cycles array carries full transcripts) are handed to jq
# through files, not argv: a single command-line argument is capped at 128 KB
# (MAX_ARG_STRLEN), which big transcripts blow past. Temp files have no such limit.
work_tmp="$(mktemp -d)"
trap 'rm -rf "$work_tmp"' EXIT

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
now_epoch="$(date +%s)"

# --- Helpers -----------------------------------------------------------------
# Parse each line of the log independently so a half-written trailing line
# (the Script may be appending as we read) never aborts the whole parse.
read_events() { jq -c -R 'fromjson? // empty' "$log_file" 2>/dev/null; }

gh_json() { timeout "$GH_TIMEOUT" gh "$@" 2>/dev/null; }

epoch_of() { date -d "$1" +%s 2>/dev/null || echo 0; }

# Extract the JSON a stage emitted as its final message: try the whole result
# as JSON, else the last fenced ```json block (mirrors agent-cycle.sh).
extract_status_json() {
  local text="$1" block
  if jq empty <<<"$text" >/dev/null 2>&1; then jq -c '.' <<<"$text"; return; fi
  block="$(awk '
    /^```json[[:space:]]*$/ { capture=""; in_block=1; next }
    /^```[[:space:]]*$/      { if (in_block) { last=capture; in_block=0 }; next }
    in_block                 { capture = capture $0 "\n" }
    END { printf "%s", last }' <<<"$text")"
  if [[ -n "$block" ]] && jq empty <<<"$block" >/dev/null 2>&1; then jq -c '.' <<<"$block"; return; fi
  printf 'null'
}

# Does this text look like a usage-limit message the pipeline may not have
# logged as a limit-hit event? `limit_phrase_in` is shared with agent-cycle.sh
# via lib/limit-detect.sh (see TD26071401) so the two can't drift apart again;
# scanning transcripts directly here remains a useful backstop for cycles
# where a limit-hit never got logged for some other reason (e.g. the Script
# crashed before log_event ran, or a cycle predates this detector).
limit_reset_text() {
  grep -hoiE "reset[s]?( at)? [^\"\\]{1,60}" "$@" 2>/dev/null | head -n1
}

# --- Build one stage's JSON for a cycle --------------------------------------
stage_json() {
  local cid="$1" stage="$2"
  local out="$cycles_dir/$cid/$stage.out"
  local err="$cycles_dir/$cid/$stage.out.stderr"
  [[ -f "$out" ]] || { printf 'null'; return; }

  local envelope result status_json err_text limit=false limit_txt=""
  envelope="$(cat "$out" 2>/dev/null)"
  result="$(jq -r '.result // ""' <<<"$envelope" 2>/dev/null)"
  status_json="$(extract_status_json "$result")"
  [[ -f "$err" ]] && err_text="$(head -c "$TRANSCRIPT_CAP" "$err" 2>/dev/null)" || err_text=""

  if limit_phrase_in "$out" "$err"; then limit=true; limit_txt="$(limit_reset_text "$out" "$err")"; fi

  jq -n \
    --argjson env "$(jq -c '{total_cost_usd, duration_ms, num_turns, is_error, stop_reason, terminal_reason, session_id, modelUsage}' <<<"$envelope" 2>/dev/null || echo '{}')" \
    --arg result "$(printf '%s' "$result" | head -c "$TRANSCRIPT_CAP")" \
    --argjson status "$status_json" \
    --arg stderr "$err_text" \
    --argjson limit "$limit" \
    --arg limit_txt "$limit_txt" \
    '{
      ran: true,
      cost_usd: ($env.total_cost_usd // null),
      duration_ms: ($env.duration_ms // null),
      num_turns: ($env.num_turns // null),
      is_error: ($env.is_error // null),
      terminal_reason: ($env.terminal_reason // $env.stop_reason // null),
      model: ($env.modelUsage // {} | keys | (.[0] // null)),
      status: $status,
      result: $result,
      stderr: $stderr,
      limit_hit: $limit,
      limit_text: $limit_txt
    }'
}

# --- Build one cycle's JSON (stages + log-derived outcome) --------------------
cycle_json() {
  local cid="$1"
  local ev coord impl rev
  ev="$(printf '%s\n' "$ALL_EVENTS" | jq -c --arg c "$cid" 'select(.cycle == $c)' 2>/dev/null | jq -sc '.' 2>/dev/null)"
  [[ -z "$ev" || "$ev" == "null" ]] && ev='[]'
  coord="$(stage_json "$cid" coordinator)"
  impl="$(stage_json "$cid" implementor)"
  rev="$(stage_json "$cid" reviewer)"

  jq -n \
    --arg cid "$cid" \
    --argjson ev "$ev" \
    --argjson coord "$coord" --argjson impl "$impl" --argjson rev "$rev" '
    ($ev | sort_by(.ts)) as $e
    | ($e | map(.event)) as $types
    | {
        id: $cid,
        started_at: (([ $e[] | select(.event=="cycle-start") | .ts ] | first) // ($e[0].ts // null)),
        ended_at:   ([ $e[] | select(.event=="cycle-end") | .ts ] | last),
        dry_run:    (($e[] | select(.event=="cycle-start") | .dry_run) // false),
        repo:   ([ $e[] | select(.repo)  | .repo ] | last),
        item:   ([ $e[] | select(.item)  | .item ] | last),
        source: ([ $e[] | select(.event=="selection") | .source ] | last),
        title:  ([ $e[] | select(.event=="selection") | .title ]  | last),
        pr_url: ([ $e[] | select(.pr_url) | .pr_url ] | last),
        reason: ([ $e[] | select(.event=="none-selected" or .event=="stand-down" or .event=="cycle-skipped") | (.reason // .detail) ] | last),
        fail_detail: ([ $e[] | select(.event=="attempt-failed") | ((.stage // "?") + ": " + (.detail // "")) ] | last),
        warning: ([ $e[] | select(.event=="warning") | .detail ] | last),
        outcome: (
          if   ($types | any(. == "pr-ready"))       then "pr-ready"
          elif ($types | any(. == "pr-raised"))      then "pr-raised"
          elif ($types | any(. == "attempt-failed")) then "failed"
          elif ($types | any(. == "none-selected"))  then "none-selected"
          elif ($types | any(. == "stand-down"))     then "stand-down"
          elif ($types | any(. == "cycle-skipped"))  then "skipped"
          elif ($types | any(. == "selection"))      then "selected"
          else "ended" end
        ),
        stages: { coordinator: $coord, implementor: $impl, reviewer: $rev },
        total_cost_usd: ([ $coord, $impl, $rev | .cost_usd // 0 ] | add),
        limit_hit: ([ $coord, $impl, $rev | .limit_hit // false ] | any),
        events: $e
      }'
}

# --- Slurp all events once (shared by cycle_json and summaries) ---------------
ALL_EVENTS="$(read_events)"

# --- Recent cycle ids, newest first ------------------------------------------
mapfile -t cycle_ids < <(
  { ls -1 "$cycles_dir" 2>/dev/null; printf '%s\n' "$ALL_EVENTS" | jq -r '.cycle // empty' 2>/dev/null; } \
    | sort -ru | head -n "$MAX_CYCLES"
)

cycles_arr='[]'
for cid in "${cycle_ids[@]}"; do
  [[ -n "$cid" ]] || continue
  cj="$(cycle_json "$cid" 2>/dev/null)"
  # A cycle mid-flight has partial transcripts; skip anything that didn't parse.
  [[ -n "$cj" ]] && jq -e . <<<"$cj" >/dev/null 2>&1 \
    && cycles_arr="$(jq -c --argjson c "$cj" '. + [$c]' <<<"$cycles_arr")"
done

# --- Status ------------------------------------------------------------------
lock_pid=""; lock_started=""; lock_alive=false
if [[ -f "$lock_file" ]]; then
  lock_pid="$(jq -r '.pid // empty' "$lock_file" 2>/dev/null)"
  lock_started="$(jq -r '.started_at // empty' "$lock_file" 2>/dev/null)"
  [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null && lock_alive=true
fi

# Usage-limit state: prefer a logged limit-hit with a future resume_at; else
# fall back to limit phrasing detected in the most recent cycles' transcripts.
last_limit_hit="$(printf '%s\n' "$ALL_EVENTS" | jq -rsc '[.[]|select(.event=="limit-hit")]|last // {}' 2>/dev/null)"
limit_resume="$(jq -r '.resume_at // empty' <<<"$last_limit_hit" 2>/dev/null)"
limit_needs_human="$(jq -r '.needs_human // false' <<<"$last_limit_hit" 2>/dev/null)"
limit_active=false; limit_note=""
if [[ -n "$limit_resume" ]] && (( $(epoch_of "$limit_resume") > now_epoch )); then
  limit_active=true; limit_note="until $limit_resume (logged)"
  # Spend-cap-style limits carry no reset time and clear only when a human
  # raises the cap — auto-retry cannot fix them, so flag that distinctly
  # rather than letting the banner read like an ordinary timed cooldown.
  [[ "$limit_needs_human" == "true" ]] && limit_note="$limit_note — needs human action (raise the cap)"
fi

# The cycles array can be multi-megabyte (full transcripts); pass it to jq via a
# file from here on. Here-strings/stdin (<<<) are fine — only argv is capped.
cycles_file="$work_tmp/cycles.json"
printf '%s' "$cycles_arr" > "$cycles_file"

if [[ "$limit_active" != "true" ]]; then
  # A limit is "active" only if the most recent cycle that actually launched a
  # stage hit one — otherwise a later successful cycle has cleared it and the
  # banner would be a stale false positive. (Skipped/stand-down cycles launch no
  # stage, so they don't count as recovery either way.)
  lt="$(jq -r '
    [ .[] | select(any(.stages[]?; .ran)) ] | (.[0] // {})
    | if .limit_hit
      then (.stages.implementor.limit_text // .stages.reviewer.limit_text // .stages.coordinator.limit_text // "usage limit reported in transcript")
      else "" end' "$cycles_file" 2>/dev/null)"
  if [[ -n "$lt" ]]; then limit_active=true; limit_note="$lt"; fi
fi

# The switch (requirement 2.3), read through lib/toggle.sh — the same code the
# cycle gates on, so the dashboard cannot disagree with it (requirement 34a).
#
# A disabled pipeline must be impossible to mistake for a quiet one. Without a
# banner, "disabled" and "nothing to do" render identically: no cycles, no PRs,
# no errors. That is how a switch someone set on Tuesday goes unnoticed until
# Friday — and the whole reason acceptance check 8b insists an operator can
# tell "waiting on something" from "there is nothing to do here" at a glance.
switch_state="$(toggle_state "$state_dir")"
switch_disabled=false
[[ "$(jq -r '.state' <<<"$switch_state")" == "disabled" ]] && switch_disabled=true
switch_json="$(jq -nc --argjson d "$switch_disabled" --argjson s "$switch_state" \
  '{disabled: $d,
    reason: ($s.record.reason // ""),
    by: ($s.record.by // ""),
    since: ($s.record.disabled_at // ""),
    expires_at: ($s.record.expires_at // null)}')"

status_json="$(jq -n \
  --argjson alive "$lock_alive" \
  --arg pid "$lock_pid" --arg started "$lock_started" \
  --argjson limit_active "$limit_active" --arg limit_note "$limit_note" \
  --argjson switch "$switch_json" \
  --slurpfile cyc "$cycles_file" '
  ($cyc[0] | map(select(.dry_run|not))) as $real
  | {
      running: $alive,
      lock: (if $pid == "" then null else {pid: ($pid|tonumber), started_at: $started, alive: $alive} end),
      last_cycle: (($real[0] // $cyc[0][0]) | if . == null then null else {id, ended_at, outcome, repo, item, title} end),
      limit: {active: $limit_active, note: $limit_note},
      switch: $switch
    }')"

# --- Counts / roll-ups (scan all recent transcripts for cost) ----------------
day_cut="$(date -u -d "-${COST_SCAN_DAYS} days" +%Y%m%d 2>/dev/null || echo 00000000)"
cost_rows='[]'
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  cid="$(basename "$(dirname "$f")")"; day="${cid:0:8}"
  [[ "$day" > "$day_cut" || "$day" == "$day_cut" ]] || continue
  row="$(jq -c --arg day "$day" '{
    day: $day,
    cost: (.total_cost_usd // 0),
    model: ((.modelUsage // {}) | keys | (.[0] // "unknown"))
  }' "$f" 2>/dev/null)"
  [[ -n "$row" ]] && cost_rows="$(jq -c --argjson r "$row" '. + [$r]' <<<"$cost_rows")"
done < <(find "$cycles_dir" -name '*.out' -type f 2>/dev/null)

today="$(date -u +%Y%m%d)"
counts_json="$(jq -n --slurpfile cyc "$cycles_file" --argjson costs "$cost_rows" --arg today "$today" '
  ($cyc[0]) as $cycles
  | {
    cycles_shown: ($cycles | length),
    failures_shown: ($cycles | map(select(.outcome=="failed")) | length),
    prs_reached_ready: ($cycles | map(select(.outcome=="pr-ready")) | length),
    spend_total_usd: ($costs | map(.cost) | add // 0),
    spend_today_usd: ($costs | map(select(.day==$today) | .cost) | add // 0),
    by_day:   ($costs | group_by(.day)   | map({day: .[0].day, usd: (map(.cost)|add), n: length}) | sort_by(.day)),
    by_model: ($costs | group_by(.model) | map({model: .[0].model, usd: (map(.cost)|add), n: length})
                      | map(select(.model != "unknown" or .usd > 0)) | sort_by(-.usd))
  }')"

# --- Blocked and void items (requirements 34, 34c) ---------------------------
# Both rules live in lib/cycle-state.sh, shared with agent-cycle.sh, so what the
# dashboard calls blocked or void is by construction what the Co-Ordinator is
# told. Only the projection for display is local. They are shown apart because
# they mean opposite things to a human deciding whether to intervene: a blocked
# item is waiting on something, a void item is finished with.
blocked_json="$(printf '%s\n' "$ALL_EVENTS" | blocked_items - | jq -c \
  'map({repo: (.repo // ""), item: .item, ts: .ts, detail: (.detail // ""), stage: (.stage // "")})' 2>/dev/null)"
[[ -z "$blocked_json" ]] && blocked_json='[]'

void_json="$(printf '%s\n' "$ALL_EVENTS" | void_items - | jq -c \
  'map({repo: (.repo // ""), item: .item, ts: .ts, detail: (.detail // ""), stage: (.stage // ""), evidence: (.evidence // "")})' 2>/dev/null)"
[[ -z "$void_json" ]] && void_json='[]'

# --- Log tail ----------------------------------------------------------------
log_tail_json="$(printf '%s\n' "$ALL_EVENTS" | jq -sc --argjson n "$MAX_LOG_TAIL" 'sort_by(.ts) | reverse | .[0:$n]' 2>/dev/null)"
[[ -z "$log_tail_json" ]] && log_tail_json='[]'

# --- cron.log tail -----------------------------------------------------------
cron_tail_json='[]'
[[ -f "$cron_log" ]] && cron_tail_json="$(tail -n 40 "$cron_log" 2>/dev/null | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"

# --- Live GitHub (best-effort) -----------------------------------------------
prs_json='[]'; inputs_json='{}'; gh_ok=false; gh_err=""
if (( WITH_GITHUB )); then
  gh_ok=true
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    prs="$(gh_json pr list -R "$slug" --state open --label "$pr_label" \
             --json number,title,url,isDraft,state,mergeable,mergeStateStatus,headRefName,createdAt,statusCheckRollup)"
    if [[ -z "$prs" ]]; then gh_ok=false; gh_err="pr list failed for $slug"; prs='[]'; fi
    prs_json="$(jq -c --arg slug "$slug" --argjson add "$prs" '
      . + ($add | map({
        repo: $slug, number, title, url, isDraft, state, mergeable, mergeStateStatus, headRefName, createdAt,
        checks: ((.statusCheckRollup // []) | {
          total: length,
          passed:  (map(select((.conclusion // .state) == "SUCCESS")) | length),
          failed:  (map(select((.conclusion // .state) == "FAILURE" or (.conclusion // .state) == "ERROR" or (.conclusion // .state) == "CANCELLED")) | length),
          pending: (map(select((.status // "") == "IN_PROGRESS" or (.status // "") == "QUEUED" or (.status // "") == "PENDING")) | length)
        })
      }))' <<<"$prs_json")"

    db="$(gh_json api "repos/$slug" --jq '.default_branch')"; db="${db:-main}"
    issues="$(gh_json issue list -R "$slug" --state open --limit 30 --json number,title,url,labels,assignees)"; issues="${issues:-[]}"
    runs="$(gh_json run list -R "$slug" --branch "$db" --limit 40 --json workflowName,conclusion,status,event,createdAt,url)"; runs="${runs:-[]}"
    failed_runs="$(jq -c '
      [ .[] | select(.event == "push" or .event == "schedule" or .event == "dynamic") ]
      | group_by(.workflowName) | map(sort_by(.createdAt) | last)
      | map(select(.conclusion == "failure"))' <<<"$runs" 2>/dev/null)"; failed_runs="${failed_runs:-[]}"

    td_raw="$(gh_json api "repos/$slug/contents/TECH-DEBT.md" --jq '.content' | tr -d '\n' | base64 -d 2>/dev/null | grep -iE '^\|.*\b(open|in-progress|resolved)\b' | head -n 40)"
    td_json="$(printf '%s' "$td_raw" | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"

    # Security & code-quality findings, via the same script the pipeline uses,
    # so the dashboard shows the highest-priority work source the Co-Ordinator
    # actually sees. Always valid JSON; degrades to [] on any failure.
    findings="$(timeout "$GH_TIMEOUT" "$SCRIPT_DIR/scripts/gather-findings.sh" "$slug" 2>/dev/null || echo '[]')"
    findings="$(jq -c 'if type == "array" then . else [] end' <<<"$findings" 2>/dev/null || echo '[]')"

    inputs_json="$(jq -c --arg slug "$slug" \
      --argjson issues "$issues" --argjson failed "$failed_runs" --argjson td "$td_json" --argjson findings "$findings" '
      . + {($slug): {issues: $issues, failed_runs: $failed, tech_debt: $td, findings: $findings}}' <<<"$inputs_json")"
  done < <(jq -r '.[].slug' <<<"$repos_json")
fi

github_json="$(jq -n --argjson ok "$gh_ok" --arg err "$gh_err" --arg at "$now_iso" \
  --argjson prs "$prs_json" --argjson inputs "$inputs_json" \
  '{ok: $ok, error: $err, fetched_at: $at, prs: $prs, inputs: $inputs}')"

# --- Assemble ----------------------------------------------------------------
# cycles/github/log_tail can each be large; hand them to jq via files.
printf '%s' "$github_json"   > "$work_tmp/github.json"
printf '%s' "$log_tail_json" > "$work_tmp/logtail.json"
data_json="$(jq -n \
  --arg generated_at "$now_iso" \
  --argjson config "$(jq -c '{repos, coordinator_model, implementor_model_default, implementor_model_trivial, reviewer_model, pr_label, branch_prefix, max_open_agent_prs, timeout_coordinator, timeout_implementor, timeout_reviewer, lock_stale_after, limit_cooldown_default}' "$CONFIG_FILE")" \
  --argjson status "$status_json" \
  --argjson counts "$counts_json" \
  --slurpfile cyc "$cycles_file" \
  --argjson blocked "$blocked_json" \
  --argjson void "$void_json" \
  --slurpfile gh "$work_tmp/github.json" \
  --slurpfile lt "$work_tmp/logtail.json" \
  --argjson cron_tail "$cron_tail_json" \
  --arg max_prs "$max_open_agent_prs" \
  '{generated_at: $generated_at, config: $config, status: $status, counts: $counts,
    cycles: $cyc[0], blocked: $blocked, void: $void, github: $gh[0], log_tail: $lt[0],
    cron_tail: $cron_tail, max_open_agent_prs: ($max_prs|tonumber)}')"

# --- Redact (defensive) & write atomically -----------------------------------
redact() {
  sed -E \
    -e "s#/home/[A-Za-z0-9._-]+#~#g" \
    -e "s#/Users/[A-Za-z0-9._-]+#~#g" \
    -e "s#gh[pousr]_[A-Za-z0-9]{16,}#[REDACTED-TOKEN]#g" \
    -e "s#github_pat_[A-Za-z0-9_]{20,}#[REDACTED-TOKEN]#g" \
    -e "s#sk-(ant-|proj-)?[A-Za-z0-9_-]{16,}#[REDACTED-TOKEN]#g" \
    -e "s#(Bearer|token) [A-Za-z0-9._~+/-]{16,}#\1 [REDACTED-TOKEN]#g"
}

tmp="$(mktemp "$out_dir/.data.XXXXXX.js")"
{
  printf '// Generated by publish-dashboard.sh at %s — do not edit. Regenerated each run.\n' "$now_iso"
  printf 'window.DASHBOARD_DATA = '
  printf '%s' "$data_json" | redact
  printf ';\n'
} > "$tmp"
mv -f "$tmp" "$data_file"

# Refresh the page template alongside the data (source of truth is the repo).
[[ -f "$TEMPLATE" ]] && cp -f "$TEMPLATE" "$out_dir/index.html"

echo "publish-dashboard: wrote $data_file ($(wc -c < "$data_file") bytes); open $out_dir/index.html"
exit 0
