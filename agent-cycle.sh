#!/usr/bin/env bash
#
# agent-cycle.sh — orchestrates one cycle of the autonomous agent pipeline.
# Full specification: docs/BUILD-PROMPT.md. Config: config.json.

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

for bin in claude gh git jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "agent-cycle: required binary not found on PATH: $bin" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
PROMPTS_DIR="$SCRIPT_DIR/prompts"

# --- Flags ---
DRY_RUN=0
ONCE=0
REPO_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --once) ONCE=1; shift ;;
    --repo) REPO_FILTER="${2:-}"; shift 2 ;;
    *) echo "agent-cycle: unknown argument: $1" >&2; exit 64 ;;
  esac
done

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
all_repos_json="$(cfg_json '.repos')"

mkdir -p "$state_dir" "$state_dir/cycles" "$workspace_root"
log_file="$state_dir/log.jsonl"
lock_file="$state_dir/lock.json"

cycle_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
cycle_dir="$state_dir/cycles/$cycle_id"
mkdir -p "$cycle_dir"

# --- Logging ---
log_event() {
  local event="$1" fields="${2:-{\}}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg cycle "$cycle_id" --arg event "$event" --argjson fields "$fields" \
    '{ts: $ts, cycle: $cycle, event: $event} + $fields' >> "$log_file"
}

log_unblocked_items() {
  local wo="$1" item
  while IFS= read -r item; do
    [[ -n "$item" ]] && log_event "unblocked" "$(jq -nc --arg i "$item" '{item: $i}')"
  done < <(jq -r '.unblocked[]? // empty' <<<"$wo")
}

detect_and_log_limit_hit() {
  local out_file="$1" resume_at
  if ! grep -qihE 'usage limit|rate limit|usage cap|quota exceeded' "$out_file" "$out_file.stderr" 2>/dev/null; then
    return 1
  fi
  resume_at="$(grep -oihE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z' "$out_file" "$out_file.stderr" 2>/dev/null | head -n1 || true)"
  if [[ -z "$resume_at" ]]; then
    resume_at="$(date -u -d "+${limit_cooldown_default_hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
  fi
  log_event "limit-hit" "$(jq -nc --arg r "$resume_at" '{resume_at: $r}')"
}

extract_pr_url() {
  grep -oihE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$1" "$1.stderr" 2>/dev/null | tail -n1 || true
}

# Fallback for when a stage exits without ever producing a final message (so
# there's nothing to grep or parse): the Implementor writes the PR URL to a
# breadcrumb under .git/ the moment it opens the draft PR, precisely so a
# stranded attempt can still be found and flagged instead of going silent.
read_pr_url_breadcrumb() {
  local f="$1/.git/agent-ops-pr-url"
  [[ -f "$f" ]] && head -n1 "$f" | tr -d '[:space:]'
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
  log_event "attempt-failed" "$(jq -nc --arg d "$detail" --arg s "$stage" '{stage: $s, detail: $d}')"
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
while IFS= read -r slug; do
  default_branch="$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || echo "main")"
  commit_ts="$(gh api "repos/$slug/commits/$default_branch" --jq '.commit.committer.date' 2>/dev/null || echo "1970-01-01T00:00:00Z")"
  printf '%s\t%s\t%s\n' "$commit_ts" "$slug" "$default_branch" >> "$cycle_dir/.repo_ts"
done < <(jq -r '.[].slug' <<<"$repos_json")

while IFS=$'\t' read -r _ slug default_branch; do
  sources="$(jq -c --arg s "$slug" '.[] | select(.slug == $s) | .sources' <<<"$repos_json")"
  entry="$(jq -nc --arg slug "$slug" --arg db "$default_branch" --argjson sources "$sources" \
    '{slug: $slug, default_branch: $db, sources: $sources}')"
  ordered_repos_json="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$ordered_repos_json")"
done < <(sort "$cycle_dir/.repo_ts")
rm -f "$cycle_dir/.repo_ts"

# --- Blocked-item extract (requirement 32: blocked iff most recent
#     attempt-failed/unblocked event for that repo+item is attempt-failed) ---
blocked_json="[]"
if [[ -s "$log_file" ]]; then
  blocked_json="$(jq -sc '
    [.[] | select(.event == "attempt-failed" or .event == "unblocked")]
    | group_by((.repo // "") + "|" + (.item // ""))
    | map(sort_by(.ts) | last)
    | map(select(.event == "attempt-failed"))
  ' "$log_file")"
fi

coordinator_input="$(jq -nc \
  --argjson repos "$ordered_repos_json" \
  --argjson blocked "$blocked_json" \
  --arg model_default "$implementor_model_default" \
  --arg model_trivial "$implementor_model_trivial" \
  '{repos: $repos, blocked: $blocked, models: {default: $model_default, trivial: $model_trivial}}')"

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

# --- 5. Nothing selected ---
selected="$(jq -r '.selected' <<<"$work_order_json")"
if [[ "$selected" != "true" ]]; then
  reason="$(jq -r '.reason // "no reason given"' <<<"$work_order_json")"
  log_event "none-selected" "$(jq -nc --arg r "$reason" '{reason: $r}')"
  exit 0
fi

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

if (( impl_rc != 0 )) || [[ -z "$impl_status_json" ]] || [[ "$(jq -r '.status // empty' <<<"$impl_status_json")" != "complete" ]]; then
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
