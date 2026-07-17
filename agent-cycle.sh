#!/usr/bin/env bash
#
# agent-cycle.sh — orchestrates one cycle of the autonomous agent pipeline.
# Full specification: docs/BUILD-AUTONOMOUS-IMPLEMENTATION-PROMPT.md. Config: config.json.

set -euo pipefail

# --- PATH: cron's environment is minimal; make sure claude, gh, git, jq resolve. ---
nvm_bin=""
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  . "$HOME/.nvm/nvm.sh" --no-use
  nvm_bin="$(nvm which current 2>/dev/null | xargs -r dirname 2>/dev/null || true)"
fi
path_dirs=(/usr/local/bin /usr/bin /bin "$HOME/.local/bin" "$HOME/.claude/local")
[[ -n "$nvm_bin" ]] && path_dirs+=("$nvm_bin")
PATH="$(IFS=:; echo "${path_dirs[*]}"):$PATH"
export PATH

for bin in claude gh git jq sha256sum; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "agent-cycle: required binary not found on PATH: $bin" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/noop-skip.sh
. "$SCRIPT_DIR/lib/noop-skip.sh"

usage() {
  cat <<'EOF'
usage: agent-cycle.sh [--dry-run] [--once] [--repo <slug>]
       agent-cycle.sh --disable [<reason>] [--for <90m|4h|2d|forever>]
       agent-cycle.sh --enable
       agent-cycle.sh --status

Run one cycle of the autonomous agent pipeline, or manage the switch that
stops cycles from starting (shared with review-cycle.sh).

  --dry-run          Select an item and print the work order; implement nothing.
  --once             One verbose cycle in the foreground.
  --repo <slug>      Restrict selection to one configured repo (testing).
  --disable [reason] Stop future cycles starting. A reason is required — the
                     next person to wonder why nothing is happening is entitled
                     to one. Expires after `disable_default_ttl` unless --for
                     says otherwise.
  --for <duration>   How long --disable lasts: 90m, 4h, 2d, or `forever`.
  --enable           Clear the switch and let cycles run again.
  --status           Report the switch and whether either pipeline is running.

--dry-run and --once bypass the no-op short-circuit (requirement 3b): a human
asking for a cycle wants the Co-Ordinator's answer, not a cached verdict. They
do not bypass the switch — if you disabled the pipeline to edit these files,
running them by hand is the same hazard.
EOF
}

# --- Flags ---
DRY_RUN=0
ONCE=0
REPO_FILTER=""
MANAGE_ACTION=""
DISABLE_REASON=""
DISABLE_FOR=""
set_manage_action() {
  if [[ -n "$MANAGE_ACTION" ]]; then
    echo "agent-cycle: --disable, --enable and --status are mutually exclusive" >&2
    exit 64
  fi
  MANAGE_ACTION="$1"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --once) ONCE=1; shift ;;
    --repo) REPO_FILTER="${2:-}"; shift 2 ;;
    --disable)
      set_manage_action disable; shift
      # A bare `--disable "editing lib/"` reads far better than forcing
      # `--reason`, and the next token can only be a reason if it isn't a flag.
      if [[ $# -gt 0 && "$1" != --* ]]; then DISABLE_REASON="$1"; shift; fi
      ;;
    --enable) set_manage_action enable; shift ;;
    --status) set_manage_action status; shift ;;
    --for) DISABLE_FOR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "agent-cycle: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ -n "$MANAGE_ACTION" ]]; then
  if (( DRY_RUN || ONCE )) || [[ -n "$REPO_FILTER" ]]; then
    echo "agent-cycle: --disable/--enable/--status manage the switch; they do not run a cycle" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" != "disable" && -n "$DISABLE_FOR" ]]; then
    echo "agent-cycle: --for only applies to --disable" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" == "disable" && -z "$DISABLE_REASON" ]]; then
    echo "agent-cycle: --disable needs a reason, e.g. --disable 'editing lib/cycle-state.sh'" >&2
    exit 64
  fi
fi

# --- Config ---
expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}
cfg() { jq -r "$1" "$CONFIG_FILE"; }
cfg_json() { jq -c "$1" "$CONFIG_FILE"; }

state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
coordinator_model="$(cfg '.coordinator_model')"
implementor_model_default="$(cfg '.implementor_model_default')"
implementor_model_trivial="$(cfg '.implementor_model_trivial')"
reviewer_model="$(cfg '.reviewer_model')"
pr_label="$(cfg '.pr_label')"
max_open_agent_prs="$(cfg '.max_open_agent_prs')"
timeout_coordinator_min="$(cfg '.timeout_coordinator')"
timeout_implementor_min="$(cfg '.timeout_implementor')"
timeout_reviewer_min="$(cfg '.timeout_reviewer')"
lock_stale_after_hours="$(cfg '.lock_stale_after')"
limit_cooldown_default_hours="$(cfg '.limit_cooldown_default')"
disable_default_ttl_hours="$(cfg '.disable_default_ttl // 4')"
none_selected_recheck_hours="$(cfg '.none_selected_recheck_hours // 24')"
all_repos_json="$(cfg_json '.repos')"

mkdir -p "$state_dir" "$state_dir/cycles" "$workspace_root"
log_file="$state_dir/log.jsonl"
lock_file="$state_dir/lock.json"
review_lock_file="$state_dir/review-lock.json"

cycle_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
cycle_dir="$state_dir/cycles/$cycle_id"
# A management command runs no stages and writes no transcripts; giving it a
# cycle directory would leave an empty one behind for every --status anyone
# ever ran.
[[ -n "$MANAGE_ACTION" ]] || mkdir -p "$cycle_dir"

# --- Logging ---
log_event() {
  local event="$1" fields="${2:-{\}}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg cycle "$cycle_id" --arg event "$event" --argjson fields "$fields" \
    '{ts: $ts, cycle: $cycle, event: $event} + $fields' >> "$log_file"
}

# --- Management commands (--disable / --enable / --status) ---
# Handled here, before the lock and before any `gh` call: they change no
# pipeline state that the lock protects, and `--status` must stay usable — and
# instant — while a cycle holds the lock, since "is one running right now?" is
# the question it is most often asked.
#
# The switch's transitions are logged like any other state change. An operator
# finding cycles stopped is owed the same evidence trail as one finding them
# failing, and `disabled`/`enabled` events are what let the dashboard say why.
refresh_dashboard() {
  if [[ -x "$SCRIPT_DIR/scripts/publish-dashboard.sh" ]]; then
    timeout 120 "$SCRIPT_DIR/scripts/publish-dashboard.sh" >/dev/null 2>&1 || true
  fi
}

if [[ -n "$MANAGE_ACTION" ]]; then
  case "$MANAGE_ACTION" in
    status)
      toggle_status_report "$state_dir" "cycle=$lock_file" "review=$review_lock_file"
      exit 0
      ;;
    disable)
      by="${USER:-unknown}@$(hostname 2>/dev/null || echo '?') pid $$"
      if ! record="$(toggle_disable "$state_dir" "$DISABLE_REASON" "$DISABLE_FOR" \
                       "$disable_default_ttl_hours" "$by")"; then
        exit 64
      fi
      log_event "disabled" "$(jq -nc --argjson r "$record" \
        '{reason: $r.reason, expires_at: $r.expires_at, by: $r.by}')"
      printf 'agent-cycle: disabled — %s\n' "$(toggle_describe "$record")"
      # Say it plainly rather than leaving it to be discovered: an agent that
      # disables the pipeline to edit these files has not stopped the cycle
      # that is already reading them.
      held="$(toggle_lock_held "$lock_file")"
      [[ -n "$held" ]] && printf 'agent-cycle: WARNING — a cycle is still running (%s); it will finish.\n' "$held"
      held="$(toggle_lock_held "$review_lock_file")"
      [[ -n "$held" ]] && printf 'agent-cycle: WARNING — a review cycle is still running (%s); it will finish.\n' "$held"
      refresh_dashboard
      exit 0
      ;;
    enable)
      record="$(toggle_clear "$state_dir")"
      if [[ -n "$record" ]]; then
        log_event "enabled" "$(jq -nc --argjson r "$record" \
          '{detail: "cleared by hand", was: $r}')"
        printf 'agent-cycle: enabled — cleared the disable set at %s (%s)\n' \
          "$(jq -r '.disabled_at // "?"' <<<"$record")" "$(jq -r '.reason // "?"' <<<"$record")"
      else
        printf 'agent-cycle: already enabled — no switch was set\n'
      fi
      refresh_dashboard
      exit 0
      ;;
  esac
fi

# The repo and item this cycle selected, once the Co-Ordinator has picked one.
# Requirement 33 puts `repo`/`item` on an event where applicable, and the
# requirement 34 blocked extract groups attempt-failed events by repo+item — so
# an event raised after selection that omits them can never block the item it
# failed on, and the same item is free to be re-selected next cycle.
selected_repo=""
selected_item=""

log_attempt_failed() {
  local stage="$1" detail="$2" extra="${3:-{\}}"
  log_event "attempt-failed" \
    "$(item_event_fields "$stage" "$detail" "$selected_repo" "$selected_item" "$extra")"
}

# Requirement 34c: an item whose premise is false is void, not blocked. It goes
# to a different event with a different clearing rule, because the Co-Ordinator
# is told to clear blockers that have gone away — and "the work is already done"
# reads to it as a blocker that has gone away, when it is in fact the reason the
# item must never be selected again.
log_item_void() {
  local stage="$1" detail="$2" extra="${3:-{\}}"
  log_event "item-void" \
    "$(item_event_fields "$stage" "$detail" "$selected_repo" "$selected_item" "$extra")"
}

log_unblocked_items() {
  local wo="$1" item
  while IFS= read -r item; do
    [[ -n "$item" ]] && log_event "unblocked" "$(jq -nc --arg i "$item" '{item: $i}')"
  done < <(jq -r '.unblocked[]? // empty' <<<"$wo")
}

# The Co-Ordinator may void a candidate it can see conclusively is already done,
# rather than paying an Implementor cycle to reach the same verdict. Entries are
# objects (item/repo/reason), unlike `unblocked`'s bare ids, because a void is
# terminal and worth recording precisely; an entry naming no item is ignored.
log_voided_items() {
  local wo="$1" entry item
  while IFS= read -r entry; do
    item="$(jq -r '.item // ""' <<<"$entry")"
    [[ -n "$item" ]] || continue
    log_event "item-void" "$(item_event_fields "coordinator" \
      "$(jq -r '.reason // "no reason given"' <<<"$entry")" \
      "$(jq -r '.repo // ""' <<<"$entry")" "$item")"
  done < <(jq -c '.voided[]? // empty' <<<"$wo" 2>/dev/null || true)
}

detect_and_log_limit_hit() {
  local out_file="$1" text resume_at class needs_human
  limit_phrase_in "$out_file" "$out_file.stderr" || return 1
  text="$(cat "$out_file" "$out_file.stderr" 2>/dev/null || true)"
  IFS=$'\t' read -r resume_at class needs_human < <(limit_decide "$text" "$limit_cooldown_default_hours")
  log_event "limit-hit" "$(jq -nc --arg r "$resume_at" --arg c "$class" --argjson h "$needs_human" \
    '{resume_at: $r, class: $c, needs_human: $h}')"
}

extract_pr_url() {
  grep -oihE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$1" "$1.stderr" 2>/dev/null | tail -n1 || true
}

# Deterministically pre-fetch a repo's open Dependabot and code-scanning
# findings (requirement 3a) so the Co-Ordinator reads them instead of spending
# model tokens paginating those APIs itself. gather-findings.sh always prints
# valid JSON and never fails a cycle; this guards its output anyway and
# degrades to an empty array, teeing the result into the cycle dir for
# debugging.
gather_findings() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-findings.sh" "$slug" 2>"$cycle_dir/findings-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/findings-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Sample the change-detection signals the no-op short-circuit (requirement 3b)
# fingerprints. Unlike gather_findings, this output is never shown to the
# Co-Ordinator — it is a proxy for the reads the Co-Ordinator performs itself —
# so a degraded result must be marked, not silently accepted: an unusable
# sample yields `{"ok": false}` here and the cycle simply declines to
# fingerprint, which costs one Co-Ordinator run and never a missed one.
gather_source_state() {
  local slug="$1" branch="$2" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-source-state.sh" "$slug" "$branch" \
        2>"$cycle_dir/source-state-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object" and has("ok")' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/source-state-$safe.json"
    printf '%s' "$out"
  else
    jq -nc --arg s "$slug" '{slug: $s, ok: false}'
  fi
}

# Stage prompts require the final message to be pure JSON, but a model will
# sometimes prepend analysis prose anyway and put the real object in a
# trailing fenced ```json block. Try a straight parse first; fall back to the
# last such fenced block before giving up.
extract_json_result() {
  local text="$1" block
  if jq empty <<<"$text" >/dev/null 2>&1; then
    jq -c '.' <<<"$text"
    return 0
  fi
  block="$(awk '
    /^```json[[:space:]]*$/ { capture=""; in_block=1; next }
    /^```[[:space:]]*$/ { if (in_block) { last=capture; in_block=0 }; next }
    in_block { capture = capture $0 "\n" }
    END { printf "%s", last }
  ' <<<"$text")"
  if [[ -n "$block" ]] && jq empty <<<"$block" >/dev/null 2>&1; then
    jq -c '.' <<<"$block"
    return 0
  fi
  return 1
}

dump_stage_output() {
  local out_file="$1"
  cat "$out_file"
  [[ -s "$out_file.stderr" ]] && cat "$out_file.stderr" >&2
}

handle_stage_failure() {
  local stage="$1" rc="$2" out_file="$3" pr_url="${4:-}" detail
  if [[ "$rc" == "124" ]]; then
    detail="$stage timed out"
  else
    detail="$stage exited $rc"
  fi
  detect_and_log_limit_hit "$out_file" || true
  log_attempt_failed "$stage" "$detail"
  if [[ -n "$pr_url" ]]; then
    gh pr comment "$pr_url" --body "Autonomous agent ($stage) abandoned this PR: $detail. Left for human review." >/dev/null 2>&1 || true
  fi
}

# --- Cleanup (always runs on exit) ---
lock_acquired=0
clone_dir=""
cleanup() {
  local exit_code=$?
  if [[ -n "$clone_dir" && -d "$clone_dir" ]]; then
    rm -rf "$clone_dir"
  fi
  log_event "cycle-end" "$(jq -nc --argjson rc "$exit_code" '{exit_code: $rc}')"
  if [[ "$lock_acquired" == "1" ]]; then
    rm -f "$lock_file"
  fi
  # Refresh the local monitoring dashboard. Fully isolated: a failure or a slow
  # gh call here must never affect the cycle's outcome or exit code.
  if [[ -x "$SCRIPT_DIR/scripts/publish-dashboard.sh" ]]; then
    timeout 120 "$SCRIPT_DIR/scripts/publish-dashboard.sh" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# --- Workspace safety assertion (requirement 6) ---
assert_in_workspace() {
  local dir="$1"
  case "$dir" in
    "$workspace_root"/*) return 0 ;;
    *)
      echo "agent-cycle: refusing to launch a stage outside workspace_root: $dir" >&2
      exit 1
      ;;
  esac
}

# --- Run a headless claude invocation with a wall-clock timeout, killing its
#     whole process group on timeout. `set -m` gives the backgrounded job its
#     own process group so `kill -TERM -$pid` reaches every descendant. ---
run_claude_stage() {
  local timeout_sec="$1" model="$2" prompt="$3" out_file="$4" cwd="$5"
  local pid waited=0 rc

  # stdout (the JSON envelope) and stderr (diagnostics) are kept in separate
  # files — merging them would let stray stderr output break the JSON parse
  # of the final result.
  set -m
  ( cd "$cwd" && claude -p "$prompt" --model "$model" --dangerously-skip-permissions --output-format json ) \
    >"$out_file" 2>"$out_file.stderr" &
  pid=$!
  set +m

  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= timeout_sec )); then
      kill -TERM "-$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done

  wait "$pid"
  rc=$?
  return "$rc"
}

log_event "cycle-start" "$(jq -nc --argjson once "$([[ $ONCE == 1 ]] && echo true || echo false)" \
  --argjson dry_run "$([[ $DRY_RUN == 1 ]] && echo true || echo false)" '{once: $once, dry_run: $dry_run}')"

# --- 0. The switch (requirement 2.3) ---
# Checked before the lock and before any `gh` call, because a disabled pipeline
# should cost nothing at all — and because taking a lock a disabled cycle will
# immediately drop only widens the window in which a real cycle sees it held.
#
# An expired switch is cleared here rather than ignored, and the clearing is
# logged: cycles resuming is a state change, and an operator should be able to
# find out from the log why they resumed without knowing to look for a file
# that is, by then, gone. Deliberately not gated on --once or --dry-run — the
# switch means "these files are being edited, do not run them", which is no
# less true when a human is the one running them.
switch_state="$(toggle_state "$state_dir")"
case "$(jq -r '.state' <<<"$switch_state")" in
  expired)
    expired_record="$(jq -c '.record' <<<"$switch_state")"
    toggle_clear "$state_dir" >/dev/null
    log_event "enabled" "$(jq -nc --argjson r "$expired_record" \
      '{detail: "disable expired", was: $r}')"
    ;;
  disabled)
    log_event "stand-down" "$(jq -nc \
      --arg r "disabled: $(toggle_describe "$(jq -c '.record' <<<"$switch_state")")" \
      '{reason: $r}')"
    (( ONCE )) && echo "agent-cycle: the pipeline is disabled — run --status for detail, --enable to resume" >&2
    exit 0
    ;;
esac

# --- 1. Lock ---
acquire_lock() {
  if [[ -f "$lock_file" ]]; then
    local pid started_at
    pid="$(jq -r '.pid // empty' "$lock_file" 2>/dev/null || true)"
    started_at="$(jq -r '.started_at // empty' "$lock_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      local started_epoch now_epoch age_sec stale_after_sec pgid
      started_epoch="$(date -d "$started_at" +%s 2>/dev/null || echo 0)"
      now_epoch="$(date +%s)"
      age_sec=$(( now_epoch - started_epoch ))
      stale_after_sec=$(( lock_stale_after_hours * 3600 ))
      if kill -0 "$pid" 2>/dev/null && (( age_sec < stale_after_sec )); then
        log_event "cycle-skipped" "$(jq -nc --arg d "lock held by pid $pid, age ${age_sec}s" '{detail: $d}')"
        exit 0
      fi
      if kill -0 "$pid" 2>/dev/null; then
        pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
        if [[ -n "$pgid" ]]; then
          kill -TERM "-$pgid" 2>/dev/null || true
          sleep 2
          kill -KILL "-$pgid" 2>/dev/null || true
        fi
      fi
      log_event "warning" "$(jq -nc --arg d "stale lock from pid $pid (age ${age_sec}s) taken over" '{detail: $d}')"
    fi
  fi
  jq -n --argjson pid "$$" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pid: $pid, started_at: $started_at}' > "$lock_file"
  lock_acquired=1
}
acquire_lock

# --- 2. Stand-down checks ---
# 2.1 Usage-limit cooldown
if [[ -s "$log_file" ]]; then
  resume_at="$(jq -rs '[.[] | select(.event == "limit-hit")] | last | .resume_at // empty' "$log_file" 2>/dev/null || true)"
  if [[ -n "$resume_at" ]]; then
    resume_epoch="$(date -d "$resume_at" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    if (( resume_epoch > now_epoch )); then
      log_event "stand-down" "$(jq -nc --arg r "usage-limit cooldown until $resume_at" '{reason: $r}')"
      exit 0
    fi
  fi
fi

# 2.2 Back-pressure — across ALL configured repos, regardless of --repo.
open_count=0
while IFS= read -r slug; do
  n="$(gh pr list -R "$slug" --state open --label "$pr_label" --json number --jq 'length' 2>/dev/null || echo 0)"
  open_count=$(( open_count + n ))
done < <(jq -r '.[].slug' <<<"$all_repos_json")

if (( open_count >= max_open_agent_prs )); then
  log_event "stand-down" "$(jq -nc --arg r "back-pressure: $open_count open agent PRs >= $max_open_agent_prs" '{reason: $r}')"
  exit 0
fi

# --- 3. Repo ordering (least recently updated default branch first) ---
if [[ -n "$REPO_FILTER" ]]; then
  repos_json="$(jq -c --arg f "$REPO_FILTER" '[.[] | select(.slug == $f or (.slug | endswith("/" + $f)))]' <<<"$all_repos_json")"
  if [[ "$(jq 'length' <<<"$repos_json")" == "0" ]]; then
    echo "agent-cycle: --repo '$REPO_FILTER' matches no configured repo" >&2
    exit 64
  fi
else
  repos_json="$all_repos_json"
fi

ordered_repos_json="[]"
source_states_json="[]"
while IFS= read -r slug; do
  default_branch="$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || echo "main")"
  commit_ts="$(gh api "repos/$slug/commits/$default_branch" --jq '.commit.committer.date' 2>/dev/null || echo "1970-01-01T00:00:00Z")"
  printf '%s\t%s\t%s\n' "$commit_ts" "$slug" "$default_branch" >> "$cycle_dir/.repo_ts"
done < <(jq -r '.[].slug' <<<"$repos_json")

while IFS=$'\t' read -r _ slug default_branch; do
  sources="$(jq -c --arg s "$slug" '.[] | select(.slug == $s) | .sources' <<<"$repos_json")"
  # Pre-fetch security/code-quality findings only when this repo lists either
  # source, so a repo that opts out of them costs no gh calls.
  findings="[]"
  if jq -e 'any(.[]; . == "security" or . == "code-quality")' <<<"$sources" >/dev/null 2>&1; then
    findings="$(gather_findings "$slug")"
  fi
  entry="$(jq -nc --arg slug "$slug" --arg db "$default_branch" --argjson sources "$sources" --argjson findings "$findings" \
    '{slug: $slug, default_branch: $db, sources: $sources, findings: $findings}')"
  ordered_repos_json="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$ordered_repos_json")"
  # Kept in a separate array, never folded into the entry above: this is the
  # Script's own bookkeeping, and every byte added to `ordered_repos_json` is a
  # byte the Co-Ordinator pays to read. A cost-control feature that grows the
  # prompt it is meant to avoid buying has not saved anything.
  state="$(gather_source_state "$slug" "$default_branch")"
  source_states_json="$(jq -c --argjson s "$state" '. + [$s]' <<<"$source_states_json")"
done < <(sort "$cycle_dir/.repo_ts")
rm -f "$cycle_dir/.repo_ts"

# --- Skip-list extracts (requirement 34: blocked iff the most recent
#     attempt-failed/unblocked event for that repo+item is attempt-failed;
#     requirement 34c: void iff the most recent item-void/unvoided event for it
#     is item-void). Two lists, not one, because the Co-Ordinator may clear the
#     first and may never clear the second. ---
blocked_json="$(blocked_items "$log_file")"
void_json="$(void_items "$log_file")"

# --- 3b. No-op short-circuit (requirement 3b) ---
# The Co-Ordinator costs the same to tell us "nothing to do" as it does to
# select work. On a quiet week that is 24 identical answers a day. If every
# input to its verdict is byte-identical to the last time it declined, the
# verdict is already known and buying it again buys nothing.
#
# The fingerprint must cover *every* input — see lib/noop-skip.sh for the map
# of source to signal, and for why a gap here is a silent stall rather than a
# visible bug. Two of them are not repo state at all and are the easiest to
# leave out: the config that decides which repos and sources exist, and the
# prompt that holds the selection rules. Without them, editing coordinator.md
# would do nothing until an unrelated commit happened to land somewhere.
selection_config_json="$(jq -nc \
  --arg cm "$coordinator_model" \
  --arg md "$implementor_model_default" \
  --arg mt "$implementor_model_trivial" \
  '{coordinator_model: $cm, models: {default: $md, trivial: $mt}}')"
coordinator_prompt_sha="$(sha256sum "$PROMPTS_DIR/coordinator.md" | cut -d' ' -f1)"

noop_input="$(jq -nc \
  --argjson repos "$ordered_repos_json" \
  --argjson states "$source_states_json" \
  --argjson blocked "$blocked_json" \
  --argjson void "$void_json" \
  --argjson sc "$selection_config_json" \
  --arg psha "$coordinator_prompt_sha" \
  '{
     repos: [ $repos[] as $r
              | $r + { state: ((first($states[]? | select(.slug == $r.slug))) // {ok: false}) } ],
     blocked: $blocked,
     void: $void,
     selection_config: $sc,
     coordinator_prompt_sha: $psha
   }')"
noop_fingerprint_value="$(noop_fingerprint <<<"$noop_input")"

# Computed even when the skip is bypassed, because it is also what a
# `none-selected` records for the *next* cycle to compare against. A --once run
# that finds nothing to do should still spare the following cron tick the same
# question.
noop_skip=""
if [[ -n "$noop_fingerprint_value" ]] && ! (( DRY_RUN || ONCE )); then
  noop_skip="$(noop_skip_reason "$noop_fingerprint_value" "$log_file" "$none_selected_recheck_hours")"
fi
if [[ -n "$noop_skip" ]]; then
  log_event "stand-down" "$(jq -nc --arg r "$noop_skip" --arg f "$noop_fingerprint_value" \
    '{reason: $r, fingerprint: $f}')"
  exit 0
fi

coordinator_input="$(jq -nc \
  --argjson repos "$ordered_repos_json" \
  --argjson blocked "$blocked_json" \
  --argjson void "$void_json" \
  --arg model_default "$implementor_model_default" \
  --arg model_trivial "$implementor_model_trivial" \
  '{repos: $repos, blocked: $blocked, void: $void, models: {default: $model_default, trivial: $model_trivial}}')"

# --- 4. Co-Ordinator stage ---
coordinator_prompt="$(cat "$PROMPTS_DIR/coordinator.md")

## Runtime input for this cycle

\`\`\`json
$(jq . <<<"$coordinator_input")
\`\`\`
"
coordinator_out="$cycle_dir/coordinator.out"

log_event "stage-start" '{"stage": "coordinator"}'
if run_claude_stage "$(( timeout_coordinator_min * 60 ))" "$coordinator_model" "$coordinator_prompt" "$coordinator_out" "$cycle_dir"; then
  coord_rc=0
else
  coord_rc=$?
fi
log_event "stage-end" "$(jq -nc --argjson rc "$coord_rc" '{stage: "coordinator", exit_code: $rc}')"
(( ONCE )) && dump_stage_output "$coordinator_out"

if (( coord_rc != 0 )); then
  handle_stage_failure "coordinator" "$coord_rc" "$coordinator_out" ""
  exit 0
fi

coord_result="$(jq -r '.result // empty' "$coordinator_out" 2>/dev/null || true)"
work_order_json="$(extract_json_result "$coord_result" 2>/dev/null || true)"

if [[ -z "$work_order_json" ]]; then
  detect_and_log_limit_hit "$coordinator_out" || true
  log_event "attempt-failed" '{"stage": "coordinator", "detail": "unparseable final message"}'
  exit 0
fi

if (( DRY_RUN )); then
  jq . <<<"$work_order_json"
fi

log_unblocked_items "$work_order_json"
log_voided_items "$work_order_json"

# --- 5. Nothing selected ---
selected="$(jq -r '.selected' <<<"$work_order_json")"
if [[ "$selected" != "true" ]]; then
  reason="$(jq -r '.reason // "no reason given"' <<<"$work_order_json")"
  # The fingerprint recorded here is the one taken *before* the Co-Ordinator
  # ran, which is the only correct choice. Anything that changed while it was
  # working is, by definition, something it may not have seen — so it must be
  # allowed to change the fingerprint and buy the next cycle a fresh look. A
  # fingerprint taken now would absorb that change and skip on it.
  #
  # An empty fingerprint is omitted, not stored: the next cycle must find no
  # fingerprint here rather than an empty one it might match against an equally
  # empty sample of its own (see gather-source-state.sh).
  log_event "none-selected" "$(jq -nc --arg r "$reason" --arg f "$noop_fingerprint_value" \
    '{reason: $r} + (if $f == "" then {} else {fingerprint: $f} end)')"
  exit 0
fi

selected_repo="$(jq -r '.repo // ""' <<<"$work_order_json")"
selected_item="$(jq -r '.item // ""' <<<"$work_order_json")"
log_event "selection" "$(jq -c '{repo, item, source, model, title}' <<<"$work_order_json")"

if (( DRY_RUN )); then
  exit 0
fi

# --- 6. Workspace ---
repo_slug="$(jq -r '.repo' <<<"$work_order_json")"
impl_model="$(jq -r '.model' <<<"$work_order_json")"

clone_dir="$workspace_root/$cycle_id"
assert_in_workspace "$clone_dir"
if ! gh repo clone "$repo_slug" "$clone_dir" -- --quiet 2>"$cycle_dir/clone.err"; then
  log_event "attempt-failed" "$(jq -nc --arg d "$(cat "$cycle_dir/clone.err")" '{stage: "workspace", detail: $d}')"
  exit 0
fi

# --- 7. Implementor stage ---
implementor_prompt="$(cat "$PROMPTS_DIR/implementor.md")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`
"
impl_out="$cycle_dir/implementor.out"

log_event "stage-start" '{"stage": "implementor"}'
if run_claude_stage "$(( timeout_implementor_min * 60 ))" "$impl_model" "$implementor_prompt" "$impl_out" "$clone_dir"; then
  impl_rc=0
else
  impl_rc=$?
fi
log_event "stage-end" "$(jq -nc --argjson rc "$impl_rc" '{stage: "implementor", exit_code: $rc}')"
(( ONCE )) && dump_stage_output "$impl_out"

impl_result="$(jq -r '.result // empty' "$impl_out" 2>/dev/null || true)"
impl_status_json="$(extract_json_result "$impl_result" 2>/dev/null || true)"
impl_pr_url="$(jq -r '.pr_url // empty' <<<"$impl_status_json" 2>/dev/null || true)"
[[ -z "$impl_pr_url" ]] && impl_pr_url="$(extract_pr_url "$impl_out")"
[[ -z "$impl_pr_url" ]] && impl_pr_url="$(read_pr_url_breadcrumb "$clone_dir")"

impl_status="$(jq -r '.status // empty' <<<"$impl_status_json" 2>/dev/null || true)"

# A reported `void` is the Implementor saying the work order describes no work —
# the item is already done on default_branch, or its premise is otherwise false.
# It is terminal (requirement 34c): no agent may clear it, because the only
# evidence that would ever arrive ("it's already done") is the reason it is void
# in the first place. Recording this as `blocked` instead is what let an
# already-done recommendation be unblocked by the next Co-Ordinator and
# re-selected indefinitely.
if (( impl_rc == 0 )) && [[ "$impl_status" == "void" ]]; then
  log_item_void "implementor" \
    "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    "$(jq -c '{evidence: (.evidence // "")}' <<<"$impl_status_json")"
  exit 0
fi

# A reported `blocked` is a verdict, not a stage failure: the Implementor ran to
# completion and found real work it cannot proceed with yet. Record it against
# the item, carrying the model's own reason and unblock_condition so a later
# Co-Ordinator can judge whether the impediment has since gone (requirement 34),
# rather than re-selecting the item and paying for the same discovery every
# cycle.
if (( impl_rc == 0 )) && [[ "$impl_status" == "blocked" ]]; then
  log_attempt_failed "implementor" \
    "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    "$(jq -c '{unblock_condition: (.unblock_condition // "")}' <<<"$impl_status_json")"
  if [[ -n "$impl_pr_url" ]]; then
    gh pr comment "$impl_pr_url" --body "Autonomous agent (implementor) stopped on this PR: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json") Left for human review." >/dev/null 2>&1 || true
  fi
  exit 0
fi

if (( impl_rc != 0 )) || [[ -z "$impl_status_json" ]] || [[ "$impl_status" != "complete" ]]; then
  handle_stage_failure "implementor" "$impl_rc" "$impl_out" "$impl_pr_url"
  exit 0
fi

[[ -n "$impl_pr_url" ]] && log_event "pr-raised" "$(jq -nc --arg u "$impl_pr_url" --arg r "$repo_slug" '{pr_url: $u, repo: $r}')"

# --- 8. Reviewer stage ---
reviewer_prompt="$(cat "$PROMPTS_DIR/reviewer.md")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`

## Implementor summary

\`\`\`json
$(jq . <<<"$impl_status_json")
\`\`\`
"
rev_out="$cycle_dir/reviewer.out"

log_event "stage-start" '{"stage": "reviewer"}'
if run_claude_stage "$(( timeout_reviewer_min * 60 ))" "$reviewer_model" "$reviewer_prompt" "$rev_out" "$clone_dir"; then
  rev_rc=0
else
  rev_rc=$?
fi
log_event "stage-end" "$(jq -nc --argjson rc "$rev_rc" '{stage: "reviewer", exit_code: $rc}')"
(( ONCE )) && dump_stage_output "$rev_out"

rev_result="$(jq -r '.result // empty' "$rev_out" 2>/dev/null || true)"
rev_status_json="$(extract_json_result "$rev_result" 2>/dev/null || true)"

if (( rev_rc != 0 )) || [[ -z "$rev_status_json" ]]; then
  handle_stage_failure "reviewer" "$rev_rc" "$rev_out" "$impl_pr_url"
  exit 0
fi

rev_status="$(jq -r '.status // empty' <<<"$rev_status_json")"
if [[ "$rev_status" == "ready" ]]; then
  log_event "pr-ready" "$(jq -nc --arg u "$impl_pr_url" '{pr_url: $u}')"
else
  log_event "stage-end" "$(jq -nc --arg s "$rev_status" '{stage: "reviewer", detail: $s}')"
fi

echo "$impl_pr_url"
