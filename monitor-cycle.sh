#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016: every backtick inside a single-quoted `printf` format string below is
# literal — deliberate Markdown code-span syntax for the issue bodies and the
# report this script writes, never a shell expansion shellcheck's heuristic
# mistakes it for. The same blanket lib/pager.sh carries, for the same reason:
# the alternative is a per-line directive on every printf that formats
# Markdown.
#
# monitor-cycle.sh — the Pipeline Monitor: one scheduled reading of the
# pipeline's own state, producing a dated report and at most
# `monitor_max_filings_per_run` provenance-stamped filings.
#
# Full specification: docs/MONITOR-PIPELINE-SPEC.md. Config: config.json
# (`monitor_*`, `schedule.monitor_hour`, `prompt_overrides.monitor`).
#
# This is a sibling of agent-cycle.sh and review-cycle.sh, and deliberately
# reuses their machinery (PATH bootstrap, lock discipline, the switch, the
# role guard, run_claude_stage, result parsing, usage-limit detection). Where
# this script is silent, agent-cycle.sh / docs/IMPLEMENTATION-PIPELINE-SPEC.md
# govern.
#
# Three properties are load-bearing and easy to lose in an edit:
#
#   CronJob-shaped. No Docker, no ssh, no host path. Everything this script
#     knows about a host it learns from `host-facts/<node>.json`
#     (docs/HOST-FACTS-SCHEMA.md), which is why a later move of this pipeline
#     into a control plane moves one prompt and one digest builder.
#   The model never reads a primary record. The Script assembles the digest
#     (lib/monitor-digest.sh) and bounds it; the stage reads that and nothing
#     else. A stage handed the 9 MB fleet log would spend a context window on
#     transport and still arrive truncated somewhere arbitrary.
#   The Script files, not the stage. Bounded count, search-first dedup, a
#     provenance line and the #937 veto are mechanical guarantees, and a
#     guarantee a prompt asks for politely is not one. The stage returns
#     findings; every GitHub write below is this script's own.

set -euo pipefail

# --- PATH: cron's environment is minimal; make sure claude, gh, git, jq resolve. ---
# Appended, not prepended, for the reason review-cycle.sh gives at its copy: a
# caller's own shim must win over these fallbacks, or a subprocess reaches a
# real `claude`/`gh` instead of the stub standing in for them
# (TD-PPagop-26080701).
nvm_bin=""
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  . "$HOME/.nvm/nvm.sh" --no-use
  nvm_bin="$(nvm which current 2>/dev/null | xargs -r dirname 2>/dev/null || true)"
fi
path_dirs=(/usr/local/bin /usr/bin /bin "$HOME/.local/bin" "$HOME/.claude/local")
[[ -n "$nvm_bin" ]] && path_dirs+=("$nvm_bin")
PATH="$PATH:$(IFS=:; echo "${path_dirs[*]}")"
export PATH

for bin in claude gh git jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "monitor-cycle: required binary not found on PATH: $bin" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# AGENT_OPS_CONFIG is the test seam, exactly as it is for review-cycle.sh:
# cron and the container invoke this bare and get the config beside the
# script.
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/config-access.sh
. "$SCRIPT_DIR/lib/config-access.sh"
# shellcheck source=lib/log-event.sh
. "$SCRIPT_DIR/lib/log-event.sh"
# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"
# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"
# shellcheck source=lib/stage-budget.sh
. "$SCRIPT_DIR/lib/stage-budget.sh"
# shellcheck source=lib/stage-health.sh
. "$SCRIPT_DIR/lib/stage-health.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/prompt-overrides.sh
. "$SCRIPT_DIR/lib/prompt-overrides.sh"
# shellcheck source=lib/monitor-digest.sh
. "$SCRIPT_DIR/lib/monitor-digest.sh"

# --- Flags ---
DRY_RUN=0
ONCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --once) ONCE=1; shift ;;
    --disable|--enable|--status|--for|--until|--this-node)
      # One switch, one place to set it — review-cycle.sh's own refusal,
      # for the same reason: this pipeline honours the switch and never
      # writes it.
      echo "monitor-cycle: the switch is shared and managed by agent-cycle.sh — use: agent-cycle.sh $1" >&2
      exit 64
      ;;
    *) echo "monitor-cycle: unknown argument: $1" >&2; exit 64 ;;
  esac
done

# --- Role guard (M2b) ---
# Requirement 2.4 of the implementation spec, through the same shared
# definition: only a node whose AGENT_OPS_ROLE is `active` runs an unattended
# monitor pass. `--dry-run` and `--once` bypass it.
if ! (( DRY_RUN || ONCE )) && ! role_is_active; then
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(role_skip_message monitor-cycle)"
  exit 0
fi

# --- Config ---
# The schema gate (requirement 1b), shared with both siblings: config.json is
# validated before any individual key is read from it, and before the lock.
schema_errors="$(config_schema_errors "$CONFIG_FILE" "$SCHEMA_FILE")" && schema_status=0 || schema_status=$?
if ((schema_status == 2)); then
  echo "monitor-cycle: $schema_errors" >&2
  exit 1
elif ((schema_status == 1)); then
  echo "monitor-cycle: config.json does not match config.schema.json:" >&2
  while IFS= read -r line; do echo "monitor-cycle:   $line" >&2; done <<<"$schema_errors"
  exit 1
fi

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")"

state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
# Exported so the `gh` transport shim (requirement 2.0e) finds this node's
# real state_dir/gh-shim/ from every subprocess this run forks.
export PW_GH_STATE_DIR="$state_dir"
state_repo="$(cfg '.state_repo')"
monitor_model_raw="$(cfg '.monitor_model')"
monitor_max_input_bytes="$(cfg '.monitor_max_input_bytes')"
monitor_max_filings="$(cfg '.monitor_max_filings_per_run')"
monitor_tactical_keys_json="$(cfg_json '.monitor_tactical_keys')"
monitor_hour="$(cfg '.schedule.monitor_hour')"
prompt_overrides_json="$(cfg_json '.prompt_overrides')"
limit_cooldown_default_hours="$(cfg '.limit_cooldown_default')"
enabler_assignee="$(cfg '.enabler_assignee')"
enabler_escalation_label="$(cfg '.enabler_escalation_label')"
crash_loop_repo="$(cfg '.crash_loop_repo')"
pager_repo="$(cfg '.pager_repo')"
repos_json="$(cfg_json '.repos')"

# Where an escalation or a decision record is filed. `crash_loop_repo` is the
# installation's declared escalation repository (lib/labels.sh's `escalation`
# role names it); `pager_repo` is the same thing for the pager and is the
# fallback for an installation that configured only that one. Both empty is
# not a fault — it is an installation that has nowhere to file, which the
# report says in as many words rather than this script failing over
# (lib/pager.sh's own empty-`pager_repo` reasoning, applied here).
escalation_repo="$crash_loop_repo"
[[ -n "$escalation_repo" ]] || escalation_repo="$pager_repo"

mkdir -p "$state_dir" "$state_dir/monitor" "$workspace_root"
log_file="$state_dir/log.jsonl"                   # shared stream (limit-hit lives here)
monitor_log_file="$state_dir/monitor-log.jsonl"   # this pipeline's own operational stream
lock_file="$state_dir/monitor-lock.json"          # our own lock
impl_lock_file="$state_dir/lock.json"             # the implementation pipeline's lock
review_lock_file="$state_dir/review-lock.json"    # the review pipeline's lock

node_name="${NODE_NAME:-$(hostname)}"
node_name="${node_name//[^A-Za-z0-9._-]/-}"
monitor_id="$(date -u +%Y%m%dT%H%M%SZ)-$node_name-$$"
monitor_date="$(date -u +%Y-%m-%d)"
monitor_hour_now="$(date -u +%H)"
now_epoch="$(date +%s)"
run_dir="$workspace_root/$monitor_id"
report_rel="monitor/$monitor_date/report.md"
report_file="$state_dir/$report_rel"

# --- Logging ---
# Operational events go to this pipeline's own monitor-log.jsonl, keyed by a
# `monitor` id — the third stream, on the same terms review-log.jsonl is the
# second (REVIEW-PIPELINE-SPEC R16): the dashboard's log.jsonl parser is
# unaffected and the three pipelines stay separable. The envelope itself is
# lib/log-event.sh's, shared.
log_event() { log_event_append "$monitor_log_file" monitor "$monitor_id" "$node_name" "$@"; }

# The one shared signal: a usage-limit hit is written to log.jsonl in the
# exact shape both siblings' stand-downs and the dashboard already read, so a
# limit hit in any pipeline stands all three down.
log_shared_limit_hit() {
  local resume_at="$1" class="$2" reset_known="$3" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg cycle "$monitor_id" --arg node "$node_name" \
    --arg r "$resume_at" --arg c "$class" --argjson k "$reset_known" \
    '{ts: $ts, cycle: $cycle, node: $node, event: "limit-hit", resume_at: $r, class: $c, reset_known: $k}' \
    >> "$log_file"
  fleet_limit_publish "$state_repo" "$state_dir" "$resume_at" "$class" "$reset_known" "$node_name" \
    || log_event "warning" "$(jq -nc \
         '{detail: "could not publish fleet/limit.json — peers will pick the cooldown up from the log union instead"}')"
}

detect_and_log_limit_hit() {
  local out_file="$1" text resume_at class reset_known
  if [[ -n "${stage_rate_limit_json:-}" ]] \
     && IFS=$'\t' read -r resume_at class reset_known \
          < <(limit_decide_structured "$stage_rate_limit_json" "$limit_cooldown_default_hours"); then
    log_shared_limit_hit "$resume_at" "$class" "$reset_known"
    return 0
  fi
  limit_phrase_in "$out_file" "$out_file.stderr" || return 1
  text="$(cat "$out_file" "$out_file.stderr" 2>/dev/null || true)"
  IFS=$'\t' read -r resume_at class reset_known < <(limit_decide "$text" "$limit_cooldown_default_hours")
  log_shared_limit_hit "$resume_at" "$class" "$reset_known"
  return 0
}

# Identical to review-cycle.sh's and agent-cycle.sh's parser; the full design
# note lives at agent-cycle.sh's copy and test/extract-json-result.test.sh
# holds all of them against each other.
extract_json_result() {
  local text="$1" block line_no suffix
  if jq empty <<<"$text" >/dev/null 2>&1; then
    jq -c '.' <<<"$text"
    return 0
  fi
  block="$(awk '
    /^```[A-Za-z0-9_-]*[[:space:]]*$/ {
      if (in_block) { last=capture; in_block=0 } else { capture=""; in_block=1 }
      next
    }
    in_block { capture = capture $0 "\n" }
    END { printf "%s", last }
  ' <<<"$text")"
  if [[ -n "$block" ]] && jq empty <<<"$block" >/dev/null 2>&1; then
    jq -c '.' <<<"$block"
    return 0
  fi
  while IFS=: read -r line_no _; do
    suffix="$(tail -n "+$line_no" <<<"$text")"
    if jq -es 'length == 1' <<<"$suffix" >/dev/null 2>&1; then
      jq -c '.' <<<"$suffix"
      return 0
    fi
  done < <(grep -n '^[[:space:]]*{' <<<"$text" || true)
  return 1
}

# --- Peer-pipeline detection ------------------------------------------------
# Is agent-cycle.sh or review-cycle.sh holding this node right now? Same
# definition review-cycle.sh's `impl_cycle_running` carries, and the same
# "err toward not-running" reasoning: a lock whose pid is gone fails `kill -0`
# and reads as not-running, which is the only direction that matters.
peer_pipeline_running() {  # peer_pipeline_running <lock-file> -> prints the pid
  local f="$1" pid
  [[ -f "$f" ]] || return 1
  pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# --- Cleanup (always runs on exit) ---
lock_acquired=0
stage_health_recorded=0
cleanup() {
  local exit_code=$?
  trap '' TERM INT HUP
  [[ -d "$run_dir" ]] && rm -rf "$run_dir"
  # The stage-health verdict for this pipeline (M17), written from day one
  # rather than left for a later issue the way the review pipeline's was
  # (agent-ops#996). Merged into `.stage-health.json` rather than written over
  # it: `stage_health_write_status`'s own STAGE_NAMES parameter narrows the
  # computation to `monitor` and its merge leaves every implementation stage's
  # entry exactly as agent-cycle.sh last wrote it.
  #
  # Guarded on `stage_health_recorded`, deliberately: a tick that stood down
  # before the stage ran has nothing new to say, and recomputing the same
  # verdict on every hourly firing would rewrite the file — and republish the
  # heartbeat it is folded into — for no change at all.
  if (( stage_health_recorded )); then
    stage_health_write_status "$state_dir" "$monitor_log_file" "" "" "" '["monitor"]' || true
  fi
  log_event "monitor-end" "$(jq -nc --argjson rc "$exit_code" '{exit_code: $rc}')"
  if [[ "$lock_acquired" == "1" ]]; then
    rm -f "$lock_file"
  fi
  # Publish this node's state once the run is fully recorded, on the same
  # terms review-cycle.sh's own cleanup does.
  timeout 300 "$SCRIPT_DIR/scripts/state-sync.sh" push || true
  exit "$exit_code"
}
trap cleanup EXIT

# --- Signals (M8a; the implementation spec's requirement 9c reasons at length) ---
stage_pid=""
stage_name=""
on_signal() {  # on_signal NAME NUM
  local name="$1" num="$2" actor
  trap '' TERM INT HUP
  if [[ -n "$stage_pid" ]] && kill -0 "$stage_pid" 2>/dev/null; then
    kill -KILL "-$stage_pid" 2>/dev/null || true
  fi
  actor="${stage_name:-cycle}"
  log_event "attempt-failed" "$(jq -nc --arg s "$actor" --arg d "$actor terminated by SIG$name" \
    '{stage: $s, detail: $d}')"
  exit "$(( 128 + num ))"
}
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2'  INT
trap 'on_signal HUP 1'  HUP

# --- Workspace safety assertion (requirement 6) ---
# The Monitor clones nothing, but its stage still needs a working directory,
# and the one rule that must hold of it is the same: never launch a stage
# outside workspace_root.
assert_in_workspace() {
  local dir="$1"
  case "$dir" in
    "$workspace_root"/*) return 0 ;;
    *)
      echo "monitor-cycle: refusing to launch a stage outside workspace_root: $dir" >&2
      exit 1
      ;;
  esac
}

log_event "monitor-start" "$(jq -nc \
  --argjson once "$([[ $ONCE == 1 ]] && echo true || echo false)" \
  --argjson dry_run "$([[ $DRY_RUN == 1 ]] && echo true || echo false)" \
  '{once: $once, dry_run: $dry_run}')"

# --- The switch (M2a) ---
# Shared with both siblings via lib/toggle.sh and checked before the lock, for
# the reasons review-cycle.sh gives at length: the hazard the switch exists
# for is an agent editing this working tree, and this script runs out of it.
# A `drain` stands this pipeline down exactly as a plain stop does — the
# Monitor opens no pull request, so it has nothing for a drain to finish.
monitor_switch_state="$(toggle_state "$state_dir")"
if [[ "$(jq -r '.state' <<<"$monitor_switch_state")" == "disabled" ]]; then
  monitor_switch_record="$(jq -c '.record' <<<"$monitor_switch_state")"
  log_event "monitor-stand-down" "$(jq -nc \
    --arg r "$(toggle_mode "$monitor_switch_record") mode: $(toggle_describe "$monitor_switch_record")" \
    '{reason: $r, cause: "disabled-node"}')"
  (( ONCE )) && echo "monitor-cycle: the pipeline is disabled or draining — agent-cycle.sh --status for detail" >&2
  exit 0
fi

fleet_monitor_switch="$(fleet_disabled_state "$state_repo" "$state_dir")"
if [[ "$(jq -r '.state' <<<"$fleet_monitor_switch")" == "disabled" ]]; then
  fleet_monitor_switch_record="$(jq -c '.record' <<<"$fleet_monitor_switch")"
  log_event "monitor-stand-down" "$(jq -nc \
    --arg r "fleet switch, $(toggle_mode "$fleet_monitor_switch_record") mode: $(toggle_describe "$fleet_monitor_switch_record")" \
    '{reason: $r, cause: "disabled-fleet"}')"
  (( ONCE )) && echo "monitor-cycle: the fleet switch is set (disabled or draining) — agent-cycle.sh --enable clears it everywhere" >&2
  exit 0
fi

# --- The off switch (M9) ---
# An empty `monitor_model` disables this pipeline outright, the same way an
# empty `enabler_model` disables that stage. Checked before the lock: a
# pipeline switched off must not take one, however briefly.
if [[ -z "$monitor_model_raw" ]]; then
  log_event "monitor-stand-down" "$(jq -nc \
    '{reason: "monitor_model is empty — the Pipeline Monitor is switched off", cause: "disabled-config"}')"
  (( ONCE )) && echo "monitor-cycle: monitor_model is empty — the Pipeline Monitor is switched off" >&2
  exit 0
fi
monitor_model="$(resolve_model_id monitor_model "$monitor_model_raw")"

# --- The fleet's memory ---
# The union of every node's shared log, snapshotted once here: the usage-limit
# checks below need a limit *any* node hit (they all spend one Claude
# account), the digest is built from it, and the stage budgets are derived
# from it. Taken before the lock, as both siblings do and for the same reason.
peers_dir="$(fleet_peers_dir "$workspace_root")"
mkdir -p "$run_dir"
union_log="$run_dir/.fleet-log.jsonl"
monitor_union_log="$run_dir/.fleet-monitor-log.jsonl"
fleet_logs "$state_dir" "$peers_dir" log.jsonl > "$union_log" || true
fleet_repair_log "$union_log" "$node_name"
fleet_logs "$state_dir" "$peers_dir" monitor-log.jsonl > "$monitor_union_log" || true
fleet_repair_log "$monitor_union_log" "$node_name"

# What the Monitor stage is allowed this run (requirement 4f), derived from
# the fleet's own record of itself exactly as both siblings' stages are. The
# monitor stream is concatenated onto the shared one before the observations
# are taken, because this pipeline's own `stage-end` events live there — a
# derivation reading only log.jsonl would see no monitor run ever and hold
# this stage at its shipped prior for ever.
stage_budget_json='{"cells":{},"actors":{}}'
stage_budget_settings_json="$(stage_budget_settings "$(cat "$CONFIG_FILE" 2>/dev/null || printf '{}')")"
stage_budget_json="$(stage_budget_table \
  "$(cat "$union_log" "$monitor_union_log" 2>/dev/null | stage_budget_observations)" \
  "$stage_budget_settings_json")"
monitor_budget="$(stage_budget_resolve "$stage_budget_json" monitor '*' "$monitor_model" '{}')"
monitor_backstop_min="$(jq -r '.backstop_min' <<<"$monitor_budget" 2>/dev/null || printf '')"
monitor_inactivity_min="$(jq -r '.inactivity_min' <<<"$monitor_budget" 2>/dev/null || printf '')"
[[ "$monitor_backstop_min" =~ ^[0-9]+$ ]] \
  || monitor_backstop_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" '$p["monitor"].backstop')"
[[ "$monitor_inactivity_min" =~ ^[0-9]+$ ]] \
  || monitor_inactivity_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" '$p["monitor"].inactivity')"
# The lock is held for one stage plus its filings, so it is sized from that
# one stage's own backstop with the same half-hour of headroom review-cycle.sh
# allows its own derivation.
lock_stale_after_sec=$(( (monitor_backstop_min + 30) * 60 ))

# --- Lock (M2) ---
acquire_lock() {
  if [[ -f "$lock_file" ]]; then
    local pid started_at host
    pid="$(jq -r '.pid // empty' "$lock_file" 2>/dev/null || true)"
    started_at="$(jq -r '.started_at // empty' "$lock_file" 2>/dev/null || true)"
    host="$(jq -r '.host // empty' "$lock_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      local started_epoch lock_now_epoch age_sec pgid
      started_epoch="$(date -d "$started_at" +%s 2>/dev/null || echo 0)"
      lock_now_epoch="$(date +%s)"
      age_sec=$(( lock_now_epoch - started_epoch ))
      if [[ -n "$host" && "$host" != "${HOSTNAME:-}" ]]; then
        # A pid is only meaningful in the PID namespace that minted it (#130).
        log_event "warning" "$(jq -nc --arg d "foreign monitor lock from pid $pid on host $host (age ${age_sec}s) taken over" '{detail: $d}')"
      else
        if kill -0 "$pid" 2>/dev/null && (( age_sec < lock_stale_after_sec )); then
          log_event "monitor-skipped" "$(jq -nc --arg d "monitor lock held by pid $pid, age ${age_sec}s" '{detail: $d}')"
          exit 0
        fi
        if kill -0 "$pid" 2>/dev/null; then
          pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
          if [[ -n "$pgid" ]]; then
            kill -TERM "-$pgid" 2>/dev/null || true
            local grace_waited=0
            while (( grace_waited < 20 )) && kill -0 "$pid" 2>/dev/null; do
              sleep 1
              grace_waited=$(( grace_waited + 1 ))
            done
            if kill -0 "$pid" 2>/dev/null; then
              kill -KILL "-$pgid" 2>/dev/null || true
            fi
          fi
        fi
        log_event "warning" "$(jq -nc --arg d "stale monitor lock from pid $pid (age ${age_sec}s) taken over" '{detail: $d}')"
      fi
    fi
  fi
  jq -n --argjson pid "$$" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "${HOSTNAME:-}" \
    '{pid: $pid, started_at: $started_at, host: $host}' > "$lock_file"
  lock_acquired=1
}
acquire_lock

# --- Stand-down checks (M3) ---
# 3.1 Usage-limit cooldown, exactly as agent-cycle.sh 2.1 and review-cycle.sh
#     R3.1: the log union (as fresh as the last fetch) and fleet/limit.json
#     (read live), later resume wins.
union_record=""
if [[ -s "$union_log" ]]; then
  union_record="$(limit_union_record < "$union_log")"
fi
governing="$(limit_later_record "$union_record" "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)")"
[[ -n "$governing" ]] || governing='{}'
resume_at="$(jq -r '.resume_at // empty' <<<"$governing" 2>/dev/null || true)"
resume_epoch=0
if [[ -n "$resume_at" ]]; then
  resume_epoch="$(date -d "$resume_at" +%s 2>/dev/null || echo 0)"
fi
if (( resume_epoch > $(date +%s) )); then
  log_event "monitor-stand-down" "$(jq -nc --arg r "usage-limit cooldown $(limit_describe "$resume_at" \
    "$(jq -r '.class // "other"' <<<"$governing" 2>/dev/null || echo other)" \
    "$(limit_reset_known "$governing")")" '{reason: $r, cause: "usage-limit"}')"
  exit 0
fi

# 3.2 Defer to a live implementation or review cycle (REVIEW-PIPELINE-SPEC
#     R3.2's pattern, widened by one lock). Three heavy `claude` runs must not
#     overlap on one quota, and the Monitor is the one of the three that can
#     always wait: its own trigger is an hourly tick, so deferring costs an
#     hour, while deferring a cycle costs the item it had already claimed.
#     Widened rather than copied, because the reason R3.2 gives — "two heavy
#     claude runs must not overlap" — applies to the review cycle identically,
#     and the review pipeline is the longer-running of the two.
peer_pid=""
peer_which=""
if peer_pid="$(peer_pipeline_running "$impl_lock_file")"; then
  peer_which="implementation cycle"
elif peer_pid="$(peer_pipeline_running "$review_lock_file")"; then
  peer_which="review cycle"
fi
if [[ -n "$peer_which" ]]; then
  log_event "monitor-stand-down" "$(jq -nc --arg r "$peer_which running (pid $peer_pid)" \
    '{reason: $r, cause: "peer-pipeline-busy"}')"
  exit 0
fi

# --- Is this tick due? (M4) ---
# The crontab line is hourly; this is what makes the cadence
# `schedule.monitor_hour` daily plus one run within the hour after a page
# fires. supercronic has no way to express "at 05:00, and also whenever X",
# and a second crontab line could not see X either — so the schedule is one
# hourly firing and the decision lives here, in the one place that can read
# the fleet's own log.
#
# Two independent triggers, whichever fires first:
#
#   daily   this tick's UTC hour is `schedule.monitor_hour` and no monitor
#           report has been written for today's UTC date anywhere in the
#           fleet. "Anywhere in the fleet" rather than "on this node" is what
#           makes the daily run one run rather than one per active node.
#   pager   the newest `pager-fired` in the union log is newer than the newest
#           monitor report. This is "within the hour after any pager-fired
#           event" as an hourly tick can express it — and it is self-limiting,
#           because writing the report advances the comparison past the event
#           that triggered it.
#
# `--once` bypasses both: an operator asking for a run now is the trigger.
last_report_ts="$(jq -r -R -n '
  [ inputs | select(length > 0) | (fromjson? // empty)
    | select(type == "object") | select(.event == "monitor-report-written")
    | .ts // empty ] | sort | last // ""' "$monitor_union_log" 2>/dev/null || true)"
report_written_today="$(jq -r -R -n --arg d "$monitor_date" '
  [ inputs | select(length > 0) | (fromjson? // empty)
    | select(type == "object") | select(.event == "monitor-report-written")
    | select((.date // "") == $d) ] | length' "$monitor_union_log" 2>/dev/null || printf 0)"
[[ "$report_written_today" =~ ^[0-9]+$ ]] || report_written_today=0
last_pager_fired_ts="$(jq -r -R -n '
  [ inputs | select(length > 0) | (fromjson? // empty)
    | select(type == "object") | select(.event == "pager-fired")
    | .ts // empty ] | sort | last // ""' "$union_log" 2>/dev/null || true)"

monitor_trigger=""
if (( ONCE || DRY_RUN )); then
  monitor_trigger="requested"
elif (( 10#$monitor_hour_now == monitor_hour )) && (( report_written_today == 0 )); then
  monitor_trigger="daily"
elif [[ -n "$last_pager_fired_ts" ]] && [[ "$last_pager_fired_ts" > "$last_report_ts" ]]; then
  monitor_trigger="pager"
fi

if [[ -z "$monitor_trigger" ]]; then
  log_event "monitor-stand-down" "$(jq -nc --arg h "$monitor_hour" --arg lr "$last_report_ts" \
    '{reason: ("not due — the daily slot is hour " + $h + " UTC and no pager has fired since the last report"),
      cause: "not-due", monitor_hour: $h, last_report_ts: $lr}')"
  exit 0
fi

# --- Claim this slot fleet-wide (M5) ---
# Several active nodes fire this hourly line, and every one of them reaches
# the same verdict about the same slot. Without a claim they would all run,
# all spend a model, and all file the same findings — the dedup below would
# keep the duplicates off GitHub, but only after the money was spent. One
# create-only file claim through lib/claim.sh settles it, on the same
# pseudo-slug pattern lib/pager.sh uses for its own per-window evaluation and
# the Enabler for its per-item engagement: the claims live under
# `claims/monitor/`, where no target repository's can collide with them.
#
# `state_repo` unset is single-node operation and a file claim is vacuously
# won (lib/claim.sh), which is exactly right: one node cannot race itself.
#
# The slot key carries the hour for a pager-triggered run and only the date
# for the daily one, so the day's scheduled run is claimed once however many
# ticks reach it, while two pages firing in two different hours each get their
# own run.
case "$monitor_trigger" in
  daily) slot_key="$monitor_date" ;;
  *)     slot_key="${monitor_date}T${monitor_hour_now}" ;;
esac
claim_rc=0
if ! (( DRY_RUN )); then
  CLAIM_NODE="$node_name" CLAIM_CYCLE="$monitor_id" \
    CLAIM_ITEM="monitor-$slot_key" CLAIM_SOURCE="monitor" \
    "$SCRIPT_DIR/lib/claim.sh" claim file monitor "$slot_key" \
    >>"$run_dir/claim.log" 2>&1 || claim_rc=$?
  if (( claim_rc == 3 )); then
    log_event "monitor-skipped" "$(jq -nc --arg s "$slot_key" \
      '{detail: ("slot " + $s + " is already claimed by another node"), slot: $s}')"
    exit 0
  elif (( claim_rc != 0 )); then
    # Fail closed, for lib/claim.sh's own reason: a node that could not claim
    # could not have filed the findings either.
    log_event "monitor-skipped" "$(jq -nc --arg s "$slot_key" \
      '{detail: ("could not claim slot " + $s + " — standing down, fail closed"), slot: $s}')"
    exit 0
  fi
fi

# --- Gather what only the forge can answer (M6) ---
# Four listings, once a day. Each degrades to `[]` rather than failing: a
# monitor run against an unreachable forge still has the whole of the fleet's
# own records to read, and a report that says "the forge was unreadable" is
# worth more than no report.
gh_json_or_empty() {  # gh_json_or_empty <gh args...>
  local out
  out="$(gh "$@" 2>/dev/null || true)"
  jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || out='[]'
  printf '%s' "$out"
}

since_iso="$(monitor_digest_since "$now_epoch" 24)"
open_pages_json='[]'
if [[ -n "$pager_repo" ]]; then
  open_pages_json="$(gh_json_or_empty issue list -R "$pager_repo" --label "pw::pager" \
    --state open --limit 100 --json number,url,title,body,createdAt,assignees,comments)"
fi
forge_prs_json='[]'
forge_issues_json='[]'
forge_escalations_json='[]'
if [[ -n "$escalation_repo" ]]; then
  forge_prs_json="$(gh_json_or_empty pr list -R "$escalation_repo" --state all --limit 100 \
    --search "created:>=$since_iso" --json number,url,title,state,createdAt,labels)"
  forge_issues_json="$(gh_json_or_empty issue list -R "$escalation_repo" --state all --limit 100 \
    --search "created:>=$since_iso" --json number,url,title,state,createdAt,labels)"
  forge_escalations_json="$(gh_json_or_empty issue list -R "$escalation_repo" \
    --label "$enabler_escalation_label" --state all --limit 100 \
    --search "created:>=$since_iso" --json number,url,title,state,createdAt,labels)"
fi

# Every repository this run may file into: the configured targets plus the
# escalation repository. A finding naming anything else is refused rather than
# filed — a monitor that could open an issue in an arbitrary repository is a
# monitor whose blast radius is the whole forge.
filing_repos_json="$(jq -nc --argjson r "$repos_json" --arg e "$escalation_repo" \
  '([ $r[]? | .slug ] + (if $e == "" then [] else [$e] end)) | unique')"

# What previous monitor runs already filed and nobody has closed: one listing
# per repository, matched on the `monitor-finding-key:` marker every filing
# carries in its body. This is the search-first half of M13 — the dedup is
# performed here, mechanically, not asked of the stage.
open_findings_json='[]'
while IFS= read -r filing_repo; do
  [[ -n "$filing_repo" ]] || continue
  repo_findings="$(gh_json_or_empty issue list -R "$filing_repo" --state open --limit 200 \
    --search "monitor-finding-key in:body" --json number,url,title,body)"
  open_findings_json="$(jq -nc --argjson a "$open_findings_json" --argjson b "$repo_findings" \
    --arg repo "$filing_repo" '
    $a + ([ $b[]
            | . as $issue
            | ([ (.body // "") | scan("monitor-finding-key: ([a-z0-9][a-z0-9-]*)") | .[0] ] | unique)[]
            | {key: ., repo: $repo, number: $issue.number, url: $issue.url, title: $issue.title} ])' \
    2>/dev/null || printf '%s' "$open_findings_json")"
done < <(jq -r '.[]' <<<"$filing_repos_json")

# --- Build the digest (M6/M7) ---
digest_json="$(monitor_digest_build \
  "$(jq -nc --arg f "$since_iso" --arg t "$(date -u -d "@$now_epoch" +%Y-%m-%dT%H:%M:%SZ)" \
     --arg n "$node_name" '{from: $f, to: $t, hours: 24, node: $n}')" \
  "$(monitor_digest_events "$union_log" "$since_iso" 3)" \
  "$(monitor_digest_pager "$union_log" "$since_iso" "$open_pages_json")" \
  "$(monitor_digest_nodes "$node_name" "$state_dir" "$peers_dir")" \
  "$(monitor_digest_work "$union_log" "$since_iso")" \
  "$(monitor_digest_forge "$forge_prs_json" "$forge_issues_json" "$forge_escalations_json")" \
  "$(monitor_digest_gotchas "$SCRIPT_DIR/docs/IMPLEMENTATION-PIPELINE-SPEC.md" \
       "$SCRIPT_DIR/docs/REVIEW-PIPELINE-SPEC.md" "$SCRIPT_DIR/docs/MONITOR-PIPELINE-SPEC.md" \
       "$SCRIPT_DIR/docs/DASHBOARD-SPEC.md")")"

digest_file="$run_dir/digest.md"
IFS=$'\t' read -r digest_rung digest_bytes \
  < <(monitor_digest_render "$digest_json" "$monitor_max_input_bytes" "$digest_file")
log_event "monitor-digest-built" "$(jq -nc --argjson rung "$digest_rung" --argjson bytes "$digest_bytes" \
  --arg trigger "$monitor_trigger" --arg since "$since_iso" \
  --argjson pages "$(jq 'length' <<<"$open_pages_json")" \
  --argjson open_findings "$(jq 'length' <<<"$open_findings_json")" \
  '{rung: $rung, bytes: $bytes, trigger: $trigger, since: $since,
    open_pages: $pages, open_findings: $open_findings}')"

if (( DRY_RUN )); then
  cat "$digest_file"
  exit 0
fi

# --- The Monitor stage (M10) ---
monitor_input_json="$(jq -nc \
  --arg date "$monitor_date" --arg node "$node_name" --arg id "$monitor_id" \
  --arg trigger "$monitor_trigger" --arg report "$report_rel" \
  --argjson budget "$monitor_max_filings" \
  --argjson tactical "$monitor_tactical_keys_json" \
  --argjson repos "$filing_repos_json" \
  --arg escalation_repo "$escalation_repo" \
  --arg pager_repo "$pager_repo" \
  --argjson open_findings "$open_findings_json" \
  '{monitor_date: $date, node: $node, monitor_id: $id, trigger: $trigger,
    report_path: $report, max_filings: $budget, tactical_keys: $tactical,
    filing_repositories: $repos, escalation_repository: $escalation_repo,
    pager_repository: $pager_repo, open_findings: $open_findings}')"

monitor_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" monitor "$prompt_overrides_json")

## Runtime input for this run

\`\`\`json
$(jq . <<<"$monitor_input_json")
\`\`\`

## The digest

$(cat "$digest_file")
"

out_file="$run_dir/monitor.out"
assert_in_workspace "$run_dir"
log_event "monitor-stage-start" "$(jq -nc --arg m "$monitor_model" \
  --argjson b "$monitor_budget" \
  --argjson bs "$monitor_backstop_min" --argjson is "$monitor_inactivity_min" \
  --argjson digest_bytes "$digest_bytes" --argjson digest_rung "$digest_rung" \
  '{model: $m} + (if ($b | type) == "object" then $b else {} end)
   + {backstop_min: $bs, inactivity_min: $is, digest_bytes: $digest_bytes, digest_rung: $digest_rung}')"
if run_claude_stage monitor "$(( monitor_backstop_min * 60 ))" "$monitor_model" \
     "$monitor_prompt" "$out_file" "$run_dir" "$(( monitor_inactivity_min * 60 ))"; then
  monitor_rc=0
else
  monitor_rc=$?
fi
# `stage-end`, with `stage: "monitor"` — the event name and field
# `lib/stage-health.sh` already reads, so this pipeline's verdict needs no
# second reader (M17).
log_event "stage-end" "$(jq -nc --argjson rc "$monitor_rc" --arg kr "$stage_kill_reason" \
  --argjson m "$(metering_fields "$monitor_model" "$out_file" "$stage_gaps_json")" \
  '{stage: "monitor", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
stage_health_recorded=1
watchdog_warning="$(stage_watchdog_warning monitor || true)"
if [[ -n "$watchdog_warning" ]]; then
  log_event "warning" "$watchdog_warning"
fi
if (( ONCE )); then
  cat "$out_file"
  # `if`, not a trailing `&&`: an empty stderr file is the common case, and a
  # trailing `&&` whose test fails leaves a non-zero status at exactly the
  # place `set -e` acts on — the trap review-cycle.sh's own dump_stage_output
  # comment records paying for once.
  if [[ -s "$out_file.stderr" ]]; then
    cat "$out_file.stderr" >&2
  fi
fi

detect_and_log_limit_hit "$out_file" || true

result_text="$(jq -r '.result // empty' "$out_file" 2>/dev/null || true)"
result_json="$(extract_json_result "$result_text" 2>/dev/null || true)"

if (( monitor_rc != 0 )) || [[ -z "$result_json" ]] \
   || [[ "$(jq -r '.status // empty' <<<"$result_json")" != "complete" ]]; then
  if (( monitor_rc == 124 )); then detail="the Monitor timed out"
  elif (( monitor_rc != 0 )); then detail="the Monitor exited $monitor_rc"
  else detail="the Monitor returned no usable completion"; fi
  log_event "attempt-failed" "$(jq -nc --arg d "$detail" '{stage: "monitor", detail: $d}')"
  exit 0
fi

# --- Filing (M11-M14) --------------------------------------------------------
# Everything below is the Script's own write. The stage returned findings; it
# was told to write nothing, and it holds no instruction that would let it.

# The provenance line every filing carries, and the citation the report uses
# for the same finding — one form, spelled once (requirement 34a's rule
# applied to a two-writer string). `M-<nn>` numbers within the day rather than
# within the run, so a pager-triggered second run cannot reuse the morning's
# numbers on a different finding.
monitor_provenance() {  # monitor_provenance <index>
  printf 'Monitor: monitor/%s M-%02d' "$monitor_date" "$1"
}

# monitor_claim_index — take the next `M-<nn>` for this day.
#
# Called only where a number is about to be written into an issue body, never
# on every stated finding, so a citation and a filing are one-to-one: no
# `M-<nn>` ever names a row that no issue carries. A ledger row with no number
# renders `—` and is identified by its finding key instead, which is what the
# dedup and the next run both read anyway. The one gap this can leave is a
# number claimed for a create the forge then refused; that is a number spent
# on an attempt, and the row records it as `failed`.
monitor_claim_index() { finding_index=$(( finding_index + 1 )); }

# The highest M-<nn> the day's report already carries, so this run's first
# finding continues from it. A fresh day (no report file) starts at zero.
finding_index=0
if [[ -s "$report_file" ]]; then
  finding_index="$(grep -oE "Monitor: monitor/$monitor_date M-[0-9]+" "$report_file" 2>/dev/null \
    | grep -oE '[0-9]+$' | sort -n | tail -n1 || true)"
  [[ "$finding_index" =~ ^[0-9]+$ ]] || finding_index=0
  finding_index=$(( 10#$finding_index ))
fi

findings_json="$(jq -c '[.findings // [] | .[]]' <<<"$result_json" 2>/dev/null || printf '[]')"
triage_json="$(jq -c '[.page_triage // [] | .[]]' <<<"$result_json" 2>/dev/null || printf '[]')"
report_markdown="$(jq -r '.report_markdown // ""' <<<"$result_json" 2>/dev/null || true)"

filed_count=0
ledger_file="$run_dir/ledger.jsonl"
: > "$ledger_file"

# monitor_ledger OUTCOME FINDING_JSON INDEX NUMBER URL DETAIL
monitor_ledger() {
  jq -nc --arg outcome "$1" --argjson f "$2" --argjson idx "$3" \
    --arg number "$4" --arg url "$5" --arg detail "$6" \
    '{outcome: $outcome, index: $idx, key: ($f.key // ""), class: ($f.class // ""),
      title: ($f.title // ""), repo: ($f.repo // ""), config_key: ($f.config_key // ""),
      number: (if $number == "" then null else ($number | tonumber) end),
      url: (if $url == "" then null else $url end), detail: $detail}' >> "$ledger_file"
}

# monitor_open_finding KEY -> "<number>\t<url>" for an already-open filing
# carrying KEY, or nothing. The search-first dedup of M13, answered from the
# listing taken before the stage ran rather than from a fresh call per
# finding: one read per repository, not one per finding.
monitor_open_finding() {
  jq -r --arg k "$1" 'map(select(.key == $k)) | first
                      | if . == null then empty else "\(.number)\t\(.url)" end' \
    <<<"$open_findings_json" 2>/dev/null || true
}

# monitor_create_issue REPO TITLE BODY_FILE LABEL ASSIGNEE -> "<number>\t<url>"
# One create, with the retry-without-label lib/pager.sh's own
# `_pager_create_issue` performs and for the same reason: a repository whose
# label catalogue has not been ensured yet must still get its issue.
monitor_create_issue() {
  local repo="$1" title="$2" body_file="$3" label="$4" assignee="$5" raw url number
  local -a args=(issue create -R "$repo" --title "$title" --body-file "$body_file")
  [[ -n "$assignee" ]] && args+=(--assignee "$assignee")
  raw="$(gh "${args[@]}" --label "$label" 2>/dev/null || true)"
  [[ -n "$raw" ]] || raw="$(gh "${args[@]}" 2>/dev/null || true)"
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  [[ -n "$url" ]] || return 1
  number="${url##*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$number" "$url"
}

while IFS= read -r finding; do
  [[ -n "$finding" ]] || continue
  f_key="$(jq -r '.key // ""' <<<"$finding")"
  f_class="$(jq -r '.class // ""' <<<"$finding")"
  f_title="$(jq -r '.title // ""' <<<"$finding")"
  f_body="$(jq -r '.body // ""' <<<"$finding")"
  f_repo="$(jq -r '.repo // ""' <<<"$finding")"
  f_config_key="$(jq -r '.config_key // ""' <<<"$finding")"
  f_options="$(jq -r '.options // ""' <<<"$finding")"

  # A key is what the dedup and the provenance both hang on, so a malformed
  # one is refused rather than normalised: a run that quietly rewrote a key
  # would file a second issue against the first run's finding.
  if [[ ! "$f_key" =~ ^[a-z0-9][a-z0-9-]{2,63}$ ]] || [[ -z "$f_title" ]]; then
    monitor_ledger refused "$finding" 0 "" "" "the finding carries no usable finding_key or title"
    continue
  fi

  # Already open from an earlier run: nothing is filed, and the report cites
  # the issue that is already carrying it (M13). No `M-<nn>` is spent on it —
  # see `monitor_claim_index` below.
  existing="$(monitor_open_finding "$f_key")"
  if [[ -n "$existing" ]]; then
    monitor_ledger already-open "$finding" 0 \
      "${existing%%$'\t'*}" "${existing#*$'\t'}" "an open issue already carries this finding key"
    continue
  fi

  case "$f_class" in
    tactical)
      # Always a proposal in the report; a filing only for a key the owner has
      # delegated (M14). The default is an empty list, so a fresh installation
      # proposes every lever and moves none.
      if [[ -z "$f_config_key" ]] \
         || ! jq -e --arg k "$f_config_key" 'index($k) != null' <<<"$monitor_tactical_keys_json" >/dev/null 2>&1; then
        monitor_ledger proposed "$finding" 0 "" "" \
          "tactical: $f_config_key is not in monitor_tactical_keys, so this is proposed in the report only"
        continue
      fi
      ;;
    mechanical|strategic) ;;
    *)
      monitor_ledger refused "$finding" 0 "" "" \
        "unknown finding class: $f_class"
      continue
      ;;
  esac

  if (( monitor_max_filings > 0 )) && (( filed_count >= monitor_max_filings )); then
    monitor_ledger deferred "$finding" 0 "" "" \
      "the run's filing budget (monitor_max_filings_per_run=$monitor_max_filings) was already spent"
    continue
  fi
  if (( monitor_max_filings == 0 )); then
    monitor_ledger deferred "$finding" 0 "" "" \
      "monitor_max_filings_per_run is 0 — this run files nothing and reports everything"
    continue
  fi

  created=""
  case "$f_class" in
    mechanical)
      if ! jq -e --arg r "$f_repo" 'index($r) != null' <<<"$filing_repos_json" >/dev/null 2>&1; then
        monitor_ledger refused "$finding" 0 "" "" \
          "mechanical: $f_repo is not a repository this installation configures"
        continue
      fi
      monitor_claim_index
      body_file="$run_dir/finding-$finding_index.md"
      {
        printf '%s\n\n' "$f_body"
        printf -- '---\n%s\nmonitor-finding-key: %s\n' "$(monitor_provenance "$finding_index")" "$f_key"
      } > "$body_file"
      labels_ensure_role "$CONFIG_FILE" "$SCHEMA_FILE" "$f_repo" target >/dev/null 2>&1 || true
      created="$(monitor_create_issue "$f_repo" "$f_title" "$body_file" "pw::type:tech-debt" "" || true)"
      ;;
    tactical)
      if [[ -z "$escalation_repo" ]]; then
        monitor_ledger proposed "$finding" 0 "" "" \
          "tactical: no crash_loop_repo or pager_repo is configured, so there is nowhere to record the decision"
        continue
      fi
      monitor_claim_index
      body_file="$run_dir/finding-$finding_index.md"
      # The decide-tactical seam's own durable record: filed, then closed
      # immediately, exactly as lib/enabler.sh's `create_decision_log_issue`
      # and lib/pager.sh's `config-lever` class do. Reopening it is the veto
      # `scripts/sweep-decision-vetoes.sh` sweeps for (#937).
      {
        printf '## Tactical decision: `%s`\n\n%s\n\n' "$f_config_key" "$f_body"
        printf 'Reopening this issue vetoes the decision (#937).\n\n'
        printf 'This record states a decision; it changes no configuration. `config.json` reaches a\n'
        printf 'node only as a versioned change (ROADMAP D16), and the Pipeline Monitor never edits it.\n\n'
        printf -- '---\n%s\nmonitor-finding-key: %s\nreason_key=monitor-%s\n' \
          "$(monitor_provenance "$finding_index")" "$f_key" "$f_key"
      } > "$body_file"
      labels_ensure_role "$CONFIG_FILE" "$SCHEMA_FILE" "$escalation_repo" escalation >/dev/null 2>&1 || true
      created="$(monitor_create_issue "$escalation_repo" "Monitor decision: $f_title" \
        "$body_file" "pw::decision" "" || true)"
      if [[ -n "$created" ]]; then
        gh issue close "${created%%$'\t'*}" -R "$escalation_repo" >/dev/null 2>&1 || true
      fi
      ;;
    strategic)
      if [[ -z "$escalation_repo" ]]; then
        monitor_ledger proposed "$finding" 0 "" "" \
          "strategic: no crash_loop_repo or pager_repo is configured, so there is nowhere to escalate to"
        continue
      fi
      monitor_claim_index
      body_file="$run_dir/finding-$finding_index.md"
      {
        printf '%s\n\n' "$f_body"
        printf '## Options\n\n%s\n\n' "${f_options:-_the Monitor stated no options; treat this as a question, not a proposal._}"
        printf -- '---\n%s\nmonitor-finding-key: %s\n' "$(monitor_provenance "$finding_index")" "$f_key"
      } > "$body_file"
      labels_ensure_role "$CONFIG_FILE" "$SCHEMA_FILE" "$escalation_repo" escalation >/dev/null 2>&1 || true
      created="$(monitor_create_issue "$escalation_repo" "$f_title" "$body_file" \
        "$enabler_escalation_label" "$enabler_assignee" || true)"
      ;;
  esac

  if [[ -n "$created" ]]; then
    filed_count=$(( filed_count + 1 ))
    monitor_ledger filed "$finding" "$finding_index" \
      "${created%%$'\t'*}" "${created#*$'\t'}" "filed as a $f_class finding"
    # Kept in the run's own open-findings view so a second finding in the same
    # run carrying the same key dedups against this one rather than filing
    # twice.
    open_findings_json="$(jq -nc --argjson a "$open_findings_json" --arg k "$f_key" \
      --arg repo "${f_repo:-$escalation_repo}" --argjson n "${created%%$'\t'*}" \
      --arg u "${created#*$'\t'}" --arg t "$f_title" \
      '$a + [{key: $k, repo: $repo, number: $n, url: $u, title: $t}]')"
  else
    monitor_ledger failed "$finding" "$finding_index" "" "" \
      "the filing could not be created on the forge"
  fi
done < <(jq -c '.[]' <<<"$findings_json")

# --- Pages triage (M15) ------------------------------------------------------
# The Monitor is the consumer of pager pages: every open `pw::pager` issue in
# the digest gets a triage verdict in the report, and a mechanical one also
# gets one comment linking the issue that will fix it.
#
# The Monitor never closes a page. The pager's lifecycle is event-sourced and
# transition-only (lib/pager.sh): a key's state is derived purely from the
# latest `pager-candidate`/`pager-fired`/`pager-cleared` event, and the issue
# is a mirror of that log rather than the other way round. A close performed
# here would leave the log still saying `fired`, so the key could never clear
# and could never fire again — and `page-outlived-item`, the invariant that
# retires a page whose own linked item has gone, would have nothing left to
# do. Closing is `pager_close`'s, and only `pager_close`'s.
triage_ledger_file="$run_dir/triage.jsonl"
: > "$triage_ledger_file"
while IFS= read -r triage; do
  [[ -n "$triage" ]] || continue
  t_number="$(jq -r '.issue // .number // ""' <<<"$triage")"
  t_verdict="$(jq -r '.verdict // ""' <<<"$triage")"
  t_key="$(jq -r '.finding_key // ""' <<<"$triage")"
  t_note="$(jq -r '.note // ""' <<<"$triage")"
  t_commented=false
  if [[ "$t_verdict" == "mechanical" && -n "$t_key" && -n "$t_number" && -n "$pager_repo" ]]; then
    linked="$(monitor_open_finding "$t_key")"
    if [[ -n "$linked" ]]; then
      # One comment per page per finding, ever: the marker below is what a
      # later run matches on, read from the `comments` this run already
      # fetched with the page rather than from a fresh call.
      already="$(jq -r --argjson n "$t_number" --arg k "$t_key" '
        map(select((.number // 0) == $n))
        | [ .[] | (.comments // [])[] | select(((.body // "") | contains("monitor-finding-key: " + $k))) ]
        | length' <<<"$open_pages_json" 2>/dev/null || printf 0)"
      [[ "$already" =~ ^[0-9]+$ ]] || already=0
      if (( already == 0 )); then
        if gh issue comment "$t_number" -R "$pager_repo" --body "$(pipeline_comment_header monitor "$node_name")

Triaged as **mechanical**: ${t_note:-a defect with a knowable fix}. The fix is tracked at ${linked#*$'\t'}.

This page stays open. Its own lifecycle is the pager's — it retires when the fact behind it clears (\`pager-cleared\`), or when \`page-outlived-item\` finds the item it names gone.

Monitor: monitor/$monitor_date
monitor-finding-key: $t_key

$(pipeline_comment_marker "$monitor_id" monitor)" >/dev/null 2>&1; then
          t_commented=true
        fi
      fi
    fi
  fi
  jq -nc --arg n "$t_number" --arg v "$t_verdict" --arg k "$t_key" --arg note "$t_note" \
    --argjson c "$t_commented" \
    '{number: (if $n == "" then null else ($n | tonumber) end), verdict: $v,
      finding_key: $k, note: $note, commented: $c}' >> "$triage_ledger_file"
done < <(jq -c '.[]' <<<"$triage_json")

# --- The report (M16) --------------------------------------------------------
# The day's report is one file, appended to: a pager-triggered second run adds
# its own section rather than overwriting the morning's, and the finding
# numbers continue across both, which is what lets `Monitor: monitor/<date>
# M-<nn>` identify one finding uniquely inside a day.
mkdir -p "$(dirname "$report_file")"
if [[ ! -s "$report_file" ]]; then
  printf '# Monitor report — %s\n' "$monitor_date" > "$report_file"
fi
{
  printf '\n## Run `%s` — %s trigger, node `%s`\n\n' "$monitor_id" "$monitor_trigger" "$node_name"
  printf '%s\n' "$report_markdown"
  printf '\n### Filings this run\n\n'
  if [[ -s "$ledger_file" ]]; then
    # The first column is the whole provenance line, not a bare `M-nn`, for
    # two reasons that happen to be the same reason: it is the string a reader
    # greps issue bodies for, and it is the string `finding_index` above reads
    # back to continue the day's numbering across a second run. One form,
    # written once and read once (requirement 34a's rule applied to a string
    # with two consumers) — a short form here would need the derivation to
    # know about this table's own layout.
    printf '| Finding | Class | Key | Outcome | Where |\n|---|---|---|---|---|\n'
    # Index 0 is the one row with no citation to print: a finding refused
    # before it was numbered, because its key was unusable. `M-00` there would
    # read as a citation a reader could grep for and never find.
    jq -r --arg d "$monitor_date" '
      "| \(if .index == 0 then "—" else "`Monitor: monitor/\($d) M-\(.index | tostring | if length < 2 then "0" + . else . end)`" end) "
      + "| \(.class) | `\(.key)` | \(.outcome) — \(.detail) "
      + "| \(if .url then .url else "—" end) |"' "$ledger_file"
  else
    printf '_This run stated no findings._\n'
  fi
  printf '\n### Pages triaged this run\n\n'
  if [[ -s "$triage_ledger_file" ]]; then
    printf '| Page | Verdict | Finding | Commented |\n|---|---|---|---|\n'
    jq -r '"| #\(.number // "?") | \(.verdict) | `\(.finding_key)` | \(.commented) |"' \
      "$triage_ledger_file"
  else
    printf '_No open page was in this run'"'"'s digest._\n'
  fi
  printf '\n_Digest: %s bytes at drop rung %s, window from `%s`._\n' \
    "$digest_bytes" "$digest_rung" "$since_iso"
} >> "$report_file"

log_event "monitor-report-written" "$(jq -nc --arg d "$monitor_date" --arg p "$report_rel" \
  --arg trigger "$monitor_trigger" \
  --argjson filed "$filed_count" \
  --argjson stated "$(jq 'length' <<<"$findings_json")" \
  --argjson ledger "$(jq -sc '.' "$ledger_file" 2>/dev/null || printf '[]')" \
  --argjson triage "$(jq -sc '.' "$triage_ledger_file" 2>/dev/null || printf '[]')" \
  '{date: $d, path: $p, trigger: $trigger, findings_stated: $stated, findings_filed: $filed,
    ledger: $ledger, page_triage: $triage}')"

# No `exit 0` here, deliberately: the script ending is the same exit 0, and a
# trailing top-level `exit` makes shellcheck treat everything the EXIT and
# signal traps invoke as unreachable (28 × SC2317 on `cleanup` and
# `on_signal`), which is exactly backwards — those are the two functions most
# certain to run.
if (( ONCE )); then
  echo "monitor-cycle: wrote $report_file ($filed_count filed of $(jq 'length' <<<"$findings_json") stated)"
fi
