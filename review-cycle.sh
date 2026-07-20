#!/usr/bin/env bash
#
# review-cycle.sh — orchestrates one weekly project-review run across the
# configured target repositories. For each repo not skipped by the idempotency
# guard, it clones the repo fresh, stages the vendored project-review skill into
# the clone, runs the Reviewer-Agent (which produces the review reports, updates
# TECH-DEBT.md, and raises one ready-for-review PR), then cleans up.
#
# Full specification: docs/REVIEW-PIPELINE-SPEC.md. Config: config.json (.review).
# This is a sibling of agent-cycle.sh and deliberately reuses its machinery
# (PATH bootstrap, lock discipline, run_claude_stage, result parsing,
# usage-limit detection). Where this script is silent, agent-cycle.sh /
# docs/IMPLEMENTATION-PIPELINE-SPEC.md govern.

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
    echo "review-cycle: required binary not found on PATH: $bin" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
SKILL_SRC="$SCRIPT_DIR/.claude/skills/project-review"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"

# --- Flags ---
DRY_RUN=0
ONCE=0
REPO_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --once) ONCE=1; shift ;;
    --repo) REPO_FILTER="${2:-}"; shift 2 ;;
    --disable|--enable|--status|--for)
      # One switch, one place to set it. Duplicating the management commands
      # here would mean two ways to write the same file and two implementations
      # to keep honest; this pipeline only *honours* the switch.
      echo "review-cycle: the switch is shared and managed by agent-cycle.sh — use: agent-cycle.sh $1" >&2
      exit 64
      ;;
    *) echo "review-cycle: unknown argument: $1" >&2; exit 64 ;;
  esac
done

# --- Role guard (R2b) ---
# The implementation pipeline's requirement 2.4, applied here for the same
# reasons and through the same shared definition: only a node whose
# AGENT_OPS_ROLE is `active` runs an unattended review, and a standby tick
# leaves nothing behind but the cron-log line. Checked before the config is
# read; --dry-run and --once bypass it.
if ! (( DRY_RUN || ONCE )) && ! role_is_active; then
  printf '%s %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(role_skip_message review-cycle)"
  exit 0
fi

# --- Config ---
expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}
cfg() { jq -r "$1" "$CONFIG_FILE"; }
cfg_json() { jq -c "$1" "$CONFIG_FILE"; }

if [[ "$(cfg 'has("review")')" != "true" ]]; then
  echo "review-cycle: config.json has no .review block (see docs/REVIEW-PIPELINE-SPEC.md)" >&2
  exit 1
fi

state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
review_model="$(cfg '.review.model')"
pr_label="$(cfg '.review.pr_label')"
branch_prefix="$(cfg '.review.branch_prefix')"
timeout_review_min="$(cfg '.review.timeout_review')"
lock_stale_after_hours="$(cfg '.review.lock_stale_after')"
min_days_between_reviews="$(cfg '.review.min_days_between_reviews')"
limit_cooldown_default_hours="$(cfg '.limit_cooldown_default')"
review_repos_json="$(cfg_json '.review.repos')"

mkdir -p "$state_dir" "$state_dir/reviews" "$workspace_root"
log_file="$state_dir/log.jsonl"                 # shared stream (limit-hit lives here)
review_log_file="$state_dir/review-log.jsonl"   # this pipeline's own operational stream
lock_file="$state_dir/review-lock.json"         # our own lock, not the cycle's lock.json
impl_lock_file="$state_dir/lock.json"           # the implementation pipeline's lock

review_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
review_date="$(date -u +%Y-%m-%d)"
review_dir="$state_dir/reviews/$review_id"
mkdir -p "$review_dir"

# --- Logging ---
# Operational events go to our own review-log.jsonl (keyed by review id), so the
# dashboard's log.jsonl parser is unaffected and the two pipelines stay separable.
log_event() {
  local event="$1" fields="${2:-{\}}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg review "$review_id" --arg event "$event" --argjson fields "$fields" \
    '{ts: $ts, review: $review, event: $event} + $fields' >> "$review_log_file"
}

# The one shared signal: a usage-limit hit is written to log.jsonl in the exact
# shape agent-cycle.sh's stand-down and the dashboard already read, so a limit
# hit in either pipeline stands both down. A single-line O_APPEND write is
# atomic even if the implementation pipeline appends concurrently.
log_shared_limit_hit() {
  local resume_at="$1" class="$2" needs_human="$3" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg cycle "$review_id" --arg r "$resume_at" --arg c "$class" --argjson h "$needs_human" \
    '{ts: $ts, cycle: $cycle, event: "limit-hit", resume_at: $r, class: $c, needs_human: $h}' >> "$log_file"
}

# Returns 0 (and logs limit-hit to the shared log) if the stage transcript shows
# a usage-limit / spend-cap phrase; 1 otherwise.
detect_and_log_limit_hit() {
  local out_file="$1" text resume_at class needs_human
  limit_phrase_in "$out_file" "$out_file.stderr" || return 1
  text="$(cat "$out_file" "$out_file.stderr" 2>/dev/null || true)"
  IFS=$'\t' read -r resume_at class needs_human < <(limit_decide "$text" "$limit_cooldown_default_hours")
  log_shared_limit_hit "$resume_at" "$class" "$needs_human"
  return 0
}

extract_pr_url() {
  grep -oihE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$1" "$1.stderr" 2>/dev/null | tail -n1 || true
}

# Fallback for a stage that dies before emitting a parseable final message: the
# Reviewer-Agent writes the PR URL to this breadcrumb the moment it opens the
# PR (.git/ is never part of the tracked tree, so it can't leak into the diff).
read_pr_url_breadcrumb() {
  local f="$1/.git/agent-ops-review-pr-url"
  [[ -f "$f" ]] && head -n1 "$f" | tr -d '[:space:]'
}

# Straight-parse the final message, else fall back to the last fenced ```json```
# block (identical to agent-cycle.sh's parser: a model sometimes prepends prose).
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

# --- Cleanup (always runs on exit) ---
lock_acquired=0
clone_dir=""
cleanup() {
  local exit_code=$?
  if [[ -n "$clone_dir" && -d "$clone_dir" ]]; then
    rm -rf "$clone_dir"
  fi
  log_event "review-end" "$(jq -nc --argjson rc "$exit_code" '{exit_code: $rc}')"
  if [[ "$lock_acquired" == "1" ]]; then
    rm -f "$lock_file"
  fi
  # Refresh the local monitoring dashboard. Fully isolated and time-bounded: a
  # failure or slow gh call here must never affect this run's outcome.
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
      echo "review-cycle: refusing to launch a stage outside workspace_root: $dir" >&2
      exit 1
      ;;
  esac
}

# --- Run a headless claude invocation with a wall-clock timeout, killing its
#     whole process group on timeout (identical mechanism to agent-cycle.sh). ---
run_claude_stage() {
  local timeout_sec="$1" model="$2" prompt="$3" out_file="$4" cwd="$5"
  local pid waited=0 rc

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

log_event "review-start" "$(jq -nc --argjson once "$([[ $ONCE == 1 ]] && echo true || echo false)" \
  --argjson dry_run "$([[ $DRY_RUN == 1 ]] && echo true || echo false)" '{once: $once, dry_run: $dry_run}')"

# --- The switch (R2a) ---
# Shared with agent-cycle.sh via lib/toggle.sh and checked before the lock, for
# the same reasons given there. This pipeline honours the switch but never sets
# it: `agent-cycle.sh --disable` is the one way in, so there is one writer and
# one record.
#
# Why a *shared* switch rather than one per pipeline: the hazard the switch
# exists for is an agent editing the agent-ops working tree, and this script
# runs out of that same tree and sources that same lib/. An agent that disabled
# only the implementation pipeline and then started editing lib/limit-detect.sh
# would have left the weekly review free to fire mid-edit and read half of it.
#
# The expired case is left for agent-cycle.sh to clear and log. This pipeline
# runs weekly; letting it clear a switch would mean the event that explains why
# cycles resumed could land days after they did.
review_switch_state="$(toggle_state "$state_dir")"
if [[ "$(jq -r '.state' <<<"$review_switch_state")" == "disabled" ]]; then
  log_event "review-stand-down" "$(jq -nc \
    --arg r "disabled: $(toggle_describe "$(jq -c '.record' <<<"$review_switch_state")")" \
    '{reason: $r}')"
  (( ONCE )) && echo "review-cycle: the pipeline is disabled — agent-cycle.sh --status for detail" >&2
  exit 0
fi

# --- Lock (R2) ---
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
        log_event "review-skipped" "$(jq -nc --arg d "review lock held by pid $pid, age ${age_sec}s" '{detail: $d}')"
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
      log_event "warning" "$(jq -nc --arg d "stale review lock from pid $pid (age ${age_sec}s) taken over" '{detail: $d}')"
    fi
  fi
  jq -n --argjson pid "$$" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pid: $pid, started_at: $started_at}' > "$lock_file"
  lock_acquired=1
}
acquire_lock

# --- Stand-down checks (R3) ---
# 3.1 Usage-limit cooldown (shared signal, read from log.jsonl exactly as agent-cycle.sh 2.1).
if [[ -s "$log_file" ]]; then
  resume_at="$(jq -rs '[.[] | select(.event == "limit-hit")] | last | .resume_at // empty' "$log_file" 2>/dev/null || true)"
  if [[ -n "$resume_at" ]]; then
    resume_epoch="$(date -d "$resume_at" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    if (( resume_epoch > now_epoch )); then
      log_event "review-stand-down" "$(jq -nc --arg r "usage-limit cooldown until $resume_at" '{reason: $r}')"
      exit 0
    fi
  fi
fi

# 3.2 Defer to a running implementation cycle: if lock.json is held by a LIVE
#     process, stand down (two heavy claude runs must not overlap on one quota).
if [[ -f "$impl_lock_file" ]]; then
  impl_pid="$(jq -r '.pid // empty' "$impl_lock_file" 2>/dev/null || true)"
  if [[ "$impl_pid" =~ ^[0-9]+$ ]] && kill -0 "$impl_pid" 2>/dev/null; then
    log_event "review-stand-down" "$(jq -nc --arg r "implementation cycle running (pid $impl_pid)" '{reason: $r}')"
    exit 0
  fi
fi

# --- Repo selection (--repo filter) ---
if [[ -n "$REPO_FILTER" ]]; then
  repos_json="$(jq -c --arg f "$REPO_FILTER" '[.[] | select(. == $f or endswith("/" + $f))]' <<<"$review_repos_json")"
  if [[ "$(jq 'length' <<<"$repos_json")" == "0" ]]; then
    echo "review-cycle: --repo '$REPO_FILTER' matches no configured review repo" >&2
    exit 64
  fi
else
  repos_json="$review_repos_json"
fi

# --- Per-repo skip-guard (R4) ---
# Echoes the reason to skip (a non-empty string) or nothing (proceed).
skip_reason() {
  local slug="$1" default_branch="$2" open_prs recent_date days
  open_prs="$(gh pr list -R "$slug" --state open --label "$pr_label" --json number --jq 'length' 2>/dev/null || echo 0)"
  if [[ "$open_prs" =~ ^[0-9]+$ ]] && (( open_prs > 0 )); then
    printf 'an open %s PR already exists' "$pr_label"
    return 0
  fi
  recent_date="$(most_recent_review_date "$slug" "$default_branch")"
  if [[ -n "$recent_date" ]]; then
    days="$(days_since "$recent_date")"
    if [[ "$days" =~ ^[0-9]+$ ]] && (( days < min_days_between_reviews )); then
      printf 'last review (%s) is %s day(s) old (< %s)' "$recent_date" "$days" "$min_days_between_reviews"
      return 0
    fi
  fi
  return 0
}

# Most recent reviews/project-review-YYYY-MM-DD folder on the default branch, as
# a bare YYYY-MM-DD (or empty). 404 (no reviews/ dir) degrades to empty.
most_recent_review_date() {
  local slug="$1" default_branch="$2"
  gh api "repos/$slug/contents/reviews?ref=$default_branch" --jq '.[].name' 2>/dev/null \
    | grep -oE 'project-review-[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | sed 's/^project-review-//' \
    | sort | tail -n1 || true
}

days_since() {
  local date_str="$1" then_epoch now_epoch
  then_epoch="$(date -d "$date_str" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  (( then_epoch == 0 )) && { echo 99999; return; }
  echo $(( (now_epoch - then_epoch) / 86400 ))
}

# Resolve default branch + skip decision for each repo up front.
to_review_json="[]"
while IFS= read -r slug; do
  default_branch="$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || echo "main")"
  reason="$(skip_reason "$slug" "$default_branch")"
  if [[ -n "$reason" ]]; then
    log_event "review-skipped" "$(jq -nc --arg r "$slug" --arg d "$reason" '{repo: $r, detail: $d}')"
    (( ONCE || DRY_RUN )) && echo "skip $slug — $reason"
    continue
  fi
  entry="$(jq -nc --arg slug "$slug" --arg db "$default_branch" '{slug: $slug, default_branch: $db}')"
  to_review_json="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$to_review_json")"
  (( ONCE || DRY_RUN )) && echo "review $slug (base $default_branch)"
done < <(jq -r '.[]' <<<"$repos_json")

if (( DRY_RUN )); then
  jq . <<<"$to_review_json"
  exit 0
fi

# --- Per-repo review (R5), sequential ---
review_one() {
  local slug="$1" default_branch="$2"
  local safe branch out_file result status_json pr_url rc

  safe="${slug//\//_}"
  clone_dir="$workspace_root/${review_id}-${safe}"
  assert_in_workspace "$clone_dir"
  if ! gh repo clone "$slug" "$clone_dir" -- --quiet 2>"$review_dir/clone-$safe.err"; then
    log_event "review-attempt-failed" "$(jq -nc --arg r "$slug" --arg d "$(cat "$review_dir/clone-$safe.err")" '{repo: $r, stage: "workspace", detail: $d}')"
    rm -rf "$clone_dir"; clone_dir=""
    return 0
  fi

  # Stage the vendored skill into the clone, and git-exclude it so the agent can
  # never commit the injected tooling (R5b).
  mkdir -p "$clone_dir/.claude/skills"
  cp -r "$SKILL_SRC" "$clone_dir/.claude/skills/project-review"
  printf '/.claude/skills/project-review/\n' >> "$clone_dir/.git/info/exclude"

  branch="${branch_prefix}${review_date}"
  local reviewer_input
  reviewer_input="$(jq -nc --arg repo "$slug" --arg db "$default_branch" --arg date "$review_date" \
    --arg branch "$branch" --arg label "$pr_label" \
    '{repo: $repo, default_branch: $db, review_date: $date, branch: $branch, pr_label: $label}')"
  local reviewer_prompt
  reviewer_prompt="$(cat "$PROMPTS_DIR/project-reviewer.md")

## Runtime input for this review

\`\`\`json
$(jq . <<<"$reviewer_input")
\`\`\`
"
  out_file="$review_dir/reviewer-$safe.out"

  log_event "review-stage-start" "$(jq -nc --arg r "$slug" --arg m "$review_model" '{repo: $r, model: $m}')"
  if run_claude_stage "$(( timeout_review_min * 60 ))" "$review_model" "$reviewer_prompt" "$out_file" "$clone_dir"; then
    rc=0
  else
    rc=$?
  fi
  log_event "review-stage-end" "$(jq -nc --arg r "$slug" --argjson rc "$rc" '{repo: $r, exit_code: $rc}')"
  (( ONCE )) && dump_stage_output "$out_file"

  detect_and_log_limit_hit "$out_file" || true

  result="$(jq -r '.result // empty' "$out_file" 2>/dev/null || true)"
  status_json="$(extract_json_result "$result" 2>/dev/null || true)"
  pr_url="$(jq -r '.pr_url // empty' <<<"$status_json" 2>/dev/null || true)"
  [[ -z "$pr_url" ]] && pr_url="$(extract_pr_url "$out_file")"
  [[ -z "$pr_url" ]] && pr_url="$(read_pr_url_breadcrumb "$clone_dir")"

  if (( rc != 0 )) || [[ -z "$status_json" ]] || [[ "$(jq -r '.status // empty' <<<"$status_json")" != "complete" ]]; then
    local detail
    if (( rc == 124 )); then detail="reviewer timed out"
    elif (( rc != 0 )); then detail="reviewer exited $rc"
    else detail="reviewer returned no usable completion"; fi
    log_event "review-attempt-failed" "$(jq -nc --arg r "$slug" --arg d "$detail" '{repo: $r, stage: "reviewer", detail: $d}')"
    if [[ -n "$pr_url" ]]; then
      gh pr comment "$pr_url" --body "Autonomous project-review agent abandoned this PR: $detail. Left for human review." >/dev/null 2>&1 || true
    fi
    rm -rf "$clone_dir"; clone_dir=""
    return 0
  fi

  log_event "review-pr-raised" "$(jq -nc --arg r "$slug" --arg u "$pr_url" '{repo: $r, pr_url: $u}')"
  [[ -n "$pr_url" ]] && echo "$pr_url"
  rm -rf "$clone_dir"; clone_dir=""
  return 0
}

while IFS= read -r entry; do
  slug="$(jq -r '.slug' <<<"$entry")"
  default_branch="$(jq -r '.default_branch' <<<"$entry")"

  # Re-check the shared usage-limit signal between repos: a limit hit while
  # reviewing the first repo must stop us before launching the second (R6).
  if [[ -s "$log_file" ]]; then
    resume_at="$(jq -rs '[.[] | select(.event == "limit-hit")] | last | .resume_at // empty' "$log_file" 2>/dev/null || true)"
    if [[ -n "$resume_at" ]]; then
      resume_epoch="$(date -d "$resume_at" +%s 2>/dev/null || echo 0)"
      if (( resume_epoch > $(date +%s) )); then
        log_event "review-stand-down" "$(jq -nc --arg r "usage-limit cooldown until $resume_at" '{reason: $r}')"
        break
      fi
    fi
  fi

  review_one "$slug" "$default_branch"
done < <(jq -c '.[]' <<<"$to_review_json")
