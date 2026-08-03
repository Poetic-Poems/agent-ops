#!/usr/bin/env bash
#
# agent-cycle.sh — orchestrates one cycle of the autonomous agent pipeline.
# Full specification: docs/IMPLEMENTATION-PIPELINE-SPEC.md. Config: config.json.

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
# Exported, and the only variable here that is: a stage's working directory is
# its own ephemeral clone, so a prompt that wants to name a tool this repository
# ships has nothing to name it relative to. A hard-coded `/app` would be right
# for every node as deployed and wrong for every other way this repository is
# run — a maintainer's checkout, the test suite — and a prompt cannot tell which
# it is in. See requirement 24a.
export AGENT_OPS_ROOT="$SCRIPT_DIR"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/noop-skip.sh
. "$SCRIPT_DIR/lib/noop-skip.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/crash-loop.sh
. "$SCRIPT_DIR/lib/crash-loop.sh"
# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"
# shellcheck source=lib/git-identity.sh
. "$SCRIPT_DIR/lib/git-identity.sh"
# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/unvoid-label.sh
. "$SCRIPT_DIR/lib/unvoid-label.sh"
# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/lib/work-gone.sh"
# shellcheck source=lib/refinement.sh
# Sourced after void-guard.sh, which defines the `entry_field_text` it uses.
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/prompt-overrides.sh
. "$SCRIPT_DIR/lib/prompt-overrides.sh"
# shellcheck source=lib/coordinator-brief.sh
. "$SCRIPT_DIR/lib/coordinator-brief.sh"
# shellcheck source=lib/repo-order.sh
. "$SCRIPT_DIR/lib/repo-order.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

usage() {
  cat <<'EOF'
usage: agent-cycle.sh [--dry-run] [--once] [--repo <slug>]
       agent-cycle.sh --disable [<reason>] [--for <90m|4h|2d|forever>]
       agent-cycle.sh --enable
       agent-cycle.sh --clear-limit [<reason>]
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
  --clear-limit      Lift a usage-limit stand-down across the fleet (2.1). Use
                     it once the limit is actually gone — you raised the cap,
                     or the plan rolled over. Unlike --enable this touches no
                     switch: it clears fleet/limit.json and logs a
                     `limit-cleared` event that supersedes the cooldown.
  --status           Report the switch, any usage-limit stand-down, and whether
                     either pipeline is running.

--dry-run and --once bypass the no-op short-circuit (requirement 3b): a human
asking for a cycle wants the Co-Ordinator's answer, not a cached verdict. They
do not bypass the switch — if you disabled the pipeline to edit these files,
running them by hand is the same hazard.

The Enabler (requirement 35) runs at the very end of a cycle, once the
workspace is gone: --dry-run never engages it (a cycle that promises to change
nothing must not claim an item or raise an issue), while --once does — a
supervised engagement is the only way to watch one happen.

Environment:
  AGENT_OPS_ROLE   `active` on the one node that runs unattended cycles;
                   anything else (including unset) makes this a standby, which
                   skips them. --dry-run and --once bypass it; the switch
                   commands work on any node.
EOF
}

# --- Flags ---
DRY_RUN=0
ONCE=0
REPO_FILTER=""
MANAGE_ACTION=""
DISABLE_REASON=""
DISABLE_FOR=""
CLEAR_LIMIT_REASON=""
set_manage_action() {
  if [[ -n "$MANAGE_ACTION" ]]; then
    echo "agent-cycle: --disable, --enable, --clear-limit and --status are mutually exclusive" >&2
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
    --clear-limit)
      set_manage_action clear-limit; shift
      # Optional here, unlike --disable's: a stand-down being lifted is
      # self-explanatory in a way that one being imposed is not.
      if [[ $# -gt 0 && "$1" != --* ]]; then CLEAR_LIMIT_REASON="$1"; shift; fi
      ;;
    --status) set_manage_action status; shift ;;
    --for) DISABLE_FOR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "agent-cycle: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ -n "$MANAGE_ACTION" ]]; then
  if (( DRY_RUN || ONCE )) || [[ -n "$REPO_FILTER" ]]; then
    echo "agent-cycle: --disable/--enable/--clear-limit/--status manage stand-down state; they do not run a cycle" >&2
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

# --- Role guard (requirement 2.4) ---
# Before the config is even read: a standby node must leave no trace of the
# tick beyond the cron log — no cycle directory, no log.jsonl event — so its
# state stays a faithful mirror of the active node's (see scripts/state-sync.sh)
# and its dashboard shows the fleet's work rather than its own idling.
#
# Bypassed by --dry-run and --once (a human asking for a cycle is not an
# unattended one) and by the switch commands, which must stay usable on every
# node. Not bypassed by --repo alone: that flag narrows an otherwise ordinary
# cycle.
if [[ -z "$MANAGE_ACTION" ]] && ! (( DRY_RUN || ONCE )) && ! role_is_active; then
  # The trailing newline is added here because command substitution eats the
  # one role_skip_message prints, and a cron log wants whole lines.
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(role_skip_message agent-cycle)"
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

state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
coordinator_model="$(resolve_model_id coordinator_model "$(cfg '.coordinator_model')")"
implementor_model_default="$(resolve_model_id implementor_model_default "$(cfg '.implementor_model_default')")"
implementor_model_trivial="$(resolve_model_id implementor_model_trivial "$(cfg '.implementor_model_trivial')")"
reviewer_model_default="$(resolve_model_id reviewer_model_default "$(cfg '.reviewer_model_default')")"
# The complexity escalation (requirement 8a): a PR graded `complexity:high` is
# reviewed on this tier. Empty falls back to the default tier, which switches
# the escalation off.
reviewer_model_complex="$(cfg '.reviewer_model_complex // ""')"
[[ "$reviewer_model_complex" == "null" || -z "$reviewer_model_complex" ]] && reviewer_model_complex="$reviewer_model_default"
reviewer_model_complex="$(resolve_model_id reviewer_model_complex "$reviewer_model_complex")"
# The Enabler (requirements 35–37). Its model is the most expensive this system
# runs, which is affordable only because the eligibility rule engages it rarely:
# an empty `enabler_model` disables the stage outright.
enabler_model="$(cfg '.enabler_model // ""')"
[[ "$enabler_model" == "null" ]] && enabler_model=""
enabler_model="$(resolve_model_id enabler_model "$enabler_model")"
timeout_enabler_min="$(cfg '.timeout_enabler // 30')"
enabler_after_coordinator_cycles="$(cfg '.enabler_after_coordinator_cycles // 3')"
# A refinement block (requirements 34e, 35a) ages on its own threshold,
# because unlike an ordinary block it waits on the Enabler and nothing else —
# a human refining the item first, or the Co-Ordinator's cheap re-check
# noticing the condition already cleared. Left unconfigured it inherits
# enabler_after_coordinator_cycles' value, which preserves the shared
# threshold this class had before the two were split apart (TD-PPagop-26072604).
refinement_after_coordinator_cycles="$(cfg '.refinement_after_coordinator_cycles // ""')"
[[ -n "$refinement_after_coordinator_cycles" && "$refinement_after_coordinator_cycles" != "null" ]] \
  || refinement_after_coordinator_cycles="$enabler_after_coordinator_cycles"
enabler_recheck_hours="$(cfg '.enabler_recheck_hours // 72')"
enabler_escalation_label="$(cfg '.enabler_escalation_label // "enabler-escalation"')"
# The assignment is what does the work — it both puts the issue in front of the
# human configured to receive them and excludes it from the `issues` source
# (requirement 16.4), so an escalation can never be selected as work by the
# very pipeline that raised it. That second property depends on the assignee
# actually being set, so an enabled Enabler with no assignee configured is a
# fatal misconfiguration, not a silent skip: an unassigned escalation is one
# the pipeline could go on to pick up as its own work.
enabler_assignee="$(cfg '.enabler_assignee // ""')"
[[ "$enabler_assignee" == "null" ]] && enabler_assignee=""
# Crash-loop escalation (requirement 2.7). `crash_loop_after` is the
# consecutive-failure threshold; 0 or absent turns the check off, so an
# older config runs exactly as before. `crash_loop_repo` is where the
# escalation issue is filed — the pipeline's own repository, because a
# Co-Ordinator that cannot run belongs to no target repo's backlog.
crash_loop_after="$(cfg '.crash_loop_after // 0')"
[[ "$crash_loop_after" =~ ^[0-9]+$ ]] || crash_loop_after=0
crash_loop_repo="$(cfg '.crash_loop_repo // ""')"
[[ "$crash_loop_repo" == "null" ]] && crash_loop_repo=""
if [[ -n "$enabler_model" && -z "$enabler_assignee" ]]; then
  echo "agent-cycle: enabler_model is set but enabler_assignee is not configured — refusing to run with an unassigned escalation target; set enabler_assignee in config.json or clear enabler_model to disable the Enabler" >&2
  exit 1
fi
# The label a human applies on GitHub to ask for a void to be reopened
# (requirement 34f). Only a human can apply it — no stage here ever does — so
# requirement 34c's "only a human may clear a void" is unchanged; what this
# gives them is a way to say it from where they actually are.
unvoid_label="$(cfg '.unvoid_label // "unvoided"')"
# The refinement class (requirements 34e, 35d). The label is a projection onto
# issue-type items and nothing reads it back, so an empty value switches the
# projection off without touching the log mechanism that actually carries the
# state. The cap bounds how much of one engagement the day-one backlog of
# silently-skipped items may take; `0` removes the class from engagements while
# still recording the blocks.
needs_refinement_label="$(cfg '.needs_refinement_label // "needs-refinement"')"
[[ "$needs_refinement_label" == "null" ]] && needs_refinement_label=""
refinement_max_per_engagement="$(cfg '.refinement_max_per_engagement // 3')"
[[ "$refinement_max_per_engagement" =~ ^[0-9]+$ ]] || refinement_max_per_engagement=3
pr_label="$(cfg '.pr_label')"
# Read here (rather than left to the Co-Ordinator, which puts it in the work
# order's `branch`) because requirement 3c's gatherer needs it: a PR is only
# ours to push to if its head branch is under this prefix. The Human Gate says
# branches outside it belong to humans.
branch_prefix="$(cfg '.branch_prefix')"
max_open_agent_prs="$(cfg '.max_open_agent_prs')"
timeout_coordinator_min="$(cfg '.timeout_coordinator')"
timeout_implementor_min="$(cfg '.timeout_implementor')"
timeout_reviewer_min="$(cfg '.timeout_reviewer')"
lock_stale_after_hours="$(cfg '.lock_stale_after')"
limit_cooldown_default_hours="$(cfg '.limit_cooldown_default')"
disable_default_ttl_hours="$(cfg '.disable_default_ttl // 4')"
none_selected_recheck_hours="$(cfg '.none_selected_recheck_hours // 24')"
candidates_max="$(cfg '.candidates_max // 3')"
# How long a draft PR this system raised may sit untouched before it counts as
# abandoned and finishing it becomes selectable work (requirement 3e). Comfortably
# beyond a whole cycle, so a draft merely being worked never qualifies.
abandoned_draft_after_hours="$(cfg '.abandoned_draft_after_hours // 3')"
state_repo="$(cfg '.state_repo // ""')"
[[ "$state_repo" == "null" ]] && state_repo=""
all_repos_json="$(cfg_json '.repos')"
# The implementation-plan source has no path of its own in the prompt or the
# code (issue #77): a repo that lists it must say where its plan document
# lives. A repo that lists the source without configuring the path is a fatal
# misconfiguration, not a silent fallback — the Co-Ordinator would have
# nothing to read — so this fails the same way the enabler_assignee guard
# above does: at startup, before any stage runs.
missing_plan_path="$(jq -r \
  '[.[] | select((.sources // []) | any(. == "implementation-plan")) | select((.implementation_plan_path // "") == "") | .slug] | join(", ")' \
  <<<"$all_repos_json")"
if [[ -n "$missing_plan_path" ]]; then
  echo "agent-cycle: repo(s) [$missing_plan_path] list the implementation-plan source but have no implementation_plan_path configured — set it in config.json's repos entry or drop the source" >&2
  exit 1
fi

# The walk order below (section 3) is derived from each repo's `nice`
# (requirement 3, lib/repo-order.sh) — an optional integer, -19..19, absent
# or null meaning 0. jq's `// 0` fallback the ordering function uses to treat
# an absent key as neutral would just as happily coerce a string or an
# out-of-range number into 0, or into whatever `pow(1.25; -N)` makes of it,
# and hand back an order the operator never asked for with nothing to show it
# happened. That is the same silent misconfiguration the guards above refuse
# to let through, so this one fails the same way: at startup, before any repo
# is touched, naming every offending slug at once.
bad_nice="$(jq -r \
  '[.[] | select(.nice != null)
        | select(((.nice | type) != "number") or ((.nice | floor) != .nice)
                 or (.nice < -19) or (.nice > 19))
        | .slug] | join(", ")' \
  <<<"$all_repos_json")"
if [[ -n "$bad_nice" ]]; then
  echo "agent-cycle: repo(s) [$bad_nice] carry an invalid nice — it must be an integer from -19 to 19 (absent means 0) — fix the repos entry in config.json" >&2
  exit 1
fi

# Per-installation prompt overrides (requirement 4a, lib/prompt-overrides.sh):
# config-pointed files, outside prompts/*.md, appended to (or, for `replace`,
# substituted for) a stage's shipped prompt. Absent entirely, every stage
# assembles byte-identical to today. Validated here, at startup, like every
# other config shape above — and to full depth, not merely "is an object": a
# misspelled stage key, a string where `extend`'s array is meant, or a
# misspelled `extend`/`replace` would each be swallowed by the jq `?`
# tolerance in lib/prompt-overrides.sh and silently serve the shipped bytes
# every cycle — exactly the failure failing loudly here exists to prevent.
# Runtime faults (a well-formed entry whose file is unreadable this cycle)
# stay tolerated in the lib: files legitimately come and go, and an
# unreadable one still moves the fingerprint, where a structural typo moves
# nothing.
prompt_overrides_json="$(cfg_json '.prompt_overrides // {}')"
prompt_overrides_shape_error="$(prompt_overrides_config_error "$prompt_overrides_json")"
if [[ -n "$prompt_overrides_shape_error" ]]; then
  echo "agent-cycle: config.json prompt_overrides: $prompt_overrides_shape_error — see README.md" >&2
  exit 1
fi

mkdir -p "$state_dir" "$state_dir/cycles" "$workspace_root"
log_file="$state_dir/log.jsonl"
lock_file="$state_dir/lock.json"
review_lock_file="$state_dir/review-lock.json"

# The node's name travels in the cycle id and in every event this cycle
# writes: once several nodes run at once, a record that does not say which
# machine produced it cannot be combined with its peers'. Sanitised because
# the id is also a directory name; the pid stays LAST — the dashboard finds
# the running cycle by its "-<pid>" suffix.
node_name="${NODE_NAME:-$(hostname)}"
node_name="${node_name//[^A-Za-z0-9._-]/-}"
cycle_id="$(date -u +%Y%m%dT%H%M%SZ)-$node_name-$$"
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
  jq -nc --arg ts "$ts" --arg cycle "$cycle_id" --arg node "$node_name" --arg event "$event" --argjson fields "$fields" \
    '{ts: $ts, cycle: $cycle, node: $node, event: $event} + $fields' >> "$log_file"
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

# The usage-limit stand-down in force right now (requirement 2.1), as its
# governing record, or empty when there is none. The management commands run
# long before the cycle's union snapshot exists, so they build their own.
current_limit_record() {
  local union
  union="$(fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl \
    | limit_union_record)"
  limit_later_record "$union" "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)"
}

# The `--status` line for that stand-down. Reported alongside the switch
# because they are two answers to one question — "why is nothing happening?"
# — and a status that knew only about the switch is what let a stale limit
# cooldown sit unexplained for a day.
limit_status_report() {
  local rec resume_at
  rec="$(current_limit_record)"
  resume_at="$(jq -r '.resume_at // empty' <<<"${rec:-{\}}" 2>/dev/null || true)"
  if [[ -z "$resume_at" ]] || (( $(date -d "$resume_at" +%s 2>/dev/null || echo 0) <= $(date +%s) )); then
    printf 'limit:    none in force\n'
    return 0
  fi
  printf 'limit:    STANDING DOWN — %s\n' \
    "$(limit_describe "$resume_at" \
        "$(jq -r '.class // "other"' <<<"$rec" 2>/dev/null || echo other)" \
        "$(limit_reset_known "$rec")")"
  return 0
}

if [[ -n "$MANAGE_ACTION" ]]; then
  case "$MANAGE_ACTION" in
    status)
      toggle_status_report "$state_dir" "cycle=$lock_file" "review=$review_lock_file"
      limit_status_report
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
      # The same record goes up as the fleet switch (requirement 2.3a): with
      # several nodes active, "stop the pipelines" has to mean all of them.
      # Best-effort — the local switch above already holds this node either
      # way, and the operator is told which of the two situations they are in.
      if [[ -n "$state_repo" ]]; then
        if fleet_flag_write "$state_repo" disabled "$record" \
             "fleet: disabled by $by — $DISABLE_REASON"; then
          printf 'agent-cycle: fleet switch set — every node will stand down\n'
        else
          printf 'agent-cycle: WARNING — could not set the fleet switch (state repo unreachable?); only this node is disabled\n' >&2
        fi
      fi
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
      # Clear the fleet switch too — and complain loudly if that fails,
      # because a fleet flag left set keeps every node down after the
      # operator believes they have re-enabled the operation.
      if [[ -n "$state_repo" ]]; then
        if fleet_flag_delete "$state_repo" "$state_dir" disabled; then
          printf 'agent-cycle: fleet switch clear\n'
        else
          printf 'agent-cycle: WARNING — could not clear the fleet switch; every node still stands down. Re-run --enable, or delete fleet/disabled.json in %s by hand.\n' "$state_repo" >&2
        fi
      fi
      refresh_dashboard
      exit 0
      ;;
    clear-limit)
      # Both carriers of requirement 2.1, because the stand-down lifts only
      # when the later of the two says so. Clearing one alone reads as
      # success and changes nothing — the failure this command exists to end.
      governing="$(current_limit_record)"
      was="$(jq -r '.resume_at // empty' <<<"${governing:-{\}}" 2>/dev/null || true)"

      # Carrier 1: the log union. A `limit-cleared` event dated now outranks
      # every earlier limit-hit, on this node immediately and on its peers at
      # their next state-sync fetch.
      log_event "limit-cleared" "$(jq -nc --arg w "$was" --arg r "$CLEAR_LIMIT_REASON" \
        --arg by "${USER:-unknown}@$(hostname 2>/dev/null || echo '?')" \
        '{was: (if $w == "" then null else $w end),
          reason: (if $r == "" then "cleared by hand" else $r end),
          by: $by}')"

      # Carrier 2: the live flag. Deleting it rather than shortening it,
      # because fleet_limit_publish is extend-only by design (concurrent hits
      # must converge on the latest resume) — a human lifting a stand-down is
      # the one case that legitimately moves it earlier, and delete is the
      # only write that expresses that.
      if [[ -n "$state_repo" ]]; then
        if fleet_flag_delete "$state_repo" "$state_dir" limit; then
          printf 'agent-cycle: fleet usage-limit flag clear\n'
        else
          printf 'agent-cycle: WARNING — could not clear fleet/limit.json; peers reading it live still stand down. Re-run --clear-limit, or delete fleet/limit.json in %s by hand.\n' "$state_repo" >&2
        fi
      fi

      if [[ -n "$was" ]]; then
        printf 'agent-cycle: usage-limit stand-down lifted (resume_at was %s)\n' "$was"
      else
        printf 'agent-cycle: no usage-limit stand-down was in force\n'
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
# The branch this cycle claimed, alongside them because it answers a question
# the other two cannot: *which pull request is this*. The Script computed it
# and pushed it before any stage ran (requirement 17a), so it is the one handle
# on a stranded attempt that survives a stage contributing nothing — which is
# what requirement 9's last fallback is built on.
selected_branch=""

log_attempt_failed() {
  local stage="$1" detail="$2" extra="${3:-{\}}"
  log_event "attempt-failed" \
    "$(item_event_fields "$stage" "$detail" "$selected_repo" "$selected_item" "$extra")"
}

# --- The claim this cycle holds (requirement 17a) ---
# Set by the claim loop after selection; released on every path that ends the
# cycle without an open PR. "have-pr" keeps the branch (the PR supersedes the
# claim — its head must survive) and drops only the registry entry; "no-pr"
# releases fully, and lib/claim.sh deletes a claim branch only if it is
# exactly where the claim left it — pushed work is never deleted.
claim_active=0
claim_kind=""
claim_key=""

# Zero means unbounded (GNU timeout treats a duration of 0 as "no timeout"),
# which is every ordinary release. The signal handler (requirement 9c) sets a
# small bound instead: it runs on borrowed time — a lock takeover KILLs what
# has not exited within its grace — and a release the network stalls must not
# cost the exit record. A claim the release never reached is retired by the
# gc within `claim_ttl_hours` anyway.
claim_release_timeout=0

release_claim() {  # release_claim have-pr|no-pr
  (( claim_active )) || return 0
  if [[ "$1" == "have-pr" ]]; then
    timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release file "$selected_repo" "$claim_key" \
      >>"$cycle_dir/claim.log" 2>&1 || true
  else
    timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release "$claim_kind" "$selected_repo" "$claim_key" \
      >>"$cycle_dir/claim.log" 2>&1 || true
  fi
  claim_active=0
}

# The claim/working branch is derived here, deterministically, never by the
# model: two nodes must compute the same name for the same item or the lock
# locks nothing. Tech-debt takes the human protocol's own `td/<ID>` — agents
# and humans then contend on the same ref and git arbitrates; everything else
# is `agent/<item-ref>`.
claim_branch_for() {  # <source> <item>
  local source="$1" item="$2"
  case "$source" in
    tech-debt) printf 'td/%s' "$item" ;;
    *)         printf 'agent/%s' "${item//[^A-Za-z0-9._-]/-}" ;;
  esac
}

# Requirement 3o: the fleet's active claims for one repo, deterministic claim
# visibility for the Co-Ordinator's own exclusion (issue #175) instead of a
# per-candidate live check the model performs unevenly. Two independent
# sources, unioned and deduped by item: `lib/claim.sh claims`, the registry
# already age-filtered to `claim_ttl_hours` — the only source for a file claim,
# since the three finishing sources have no branch — and `lib/claim.sh
# branches`, a live scan that still catches a claim the registry missed
# (`state_repo` unset, or a failed best-effort write). By the time this runs,
# step 2.1a's claim GC has already swept anything past the TTL, so a live
# branch found here is either still fresh or has real work pushed to it, and
# either way belongs in the list — no separate TTL check is needed for it.
#
# A branch-derived item is recovered by stripping `td/` or `branch_prefix`
# from the branch name, the exact inverse of claim_branch_for above. That
# recovery is exact for every item this system ever mints such a branch for —
# an issue number, an alert ref, a register-hygiene or project-review ref —
# none of which contain a character claim_branch_for's sanitiser would have
# touched, so there is nothing lossy to recover from in practice.
gather_claimed() {  # <target-slug> -> JSON array of {item, age_hours}
  local slug="$1" safe registry_out branches_out
  safe="${slug//\//_}"
  registry_out="$("$SCRIPT_DIR/lib/claim.sh" claims "$slug" 2>"$cycle_dir/claims-$safe.err" || true)"
  jq -e 'type == "array"' <<<"$registry_out" >/dev/null 2>&1 || registry_out='[]'
  branches_out="$("$SCRIPT_DIR/lib/claim.sh" branches "$slug" 2>"$cycle_dir/claim-branches-$safe.err" || true)"
  jq -e 'type == "array"' <<<"$branches_out" >/dev/null 2>&1 || branches_out='[]'
  jq -c -n --arg tp 'td/' --arg ap "$branch_prefix" --argjson reg "$registry_out" --argjson br "$branches_out" '
    ( [ $reg[] | {item, age_hours} ] ) as $from_registry
    | ( [ $br[]
          | (if startswith($tp) then .[($tp | length):]
             elif ($ap != "" and startswith($ap)) then .[($ap | length):]
             else empty end)
          | select(. != "")
          | {item: ., age_hours: null} ] ) as $from_branches
    | ($from_registry + $from_branches)
    | group_by(.item)
    | map({item: .[0].item, age_hours: (([.[].age_hours | select(. != null)] | first) // null)})
  ' 2>/dev/null || echo '[]'
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
    [[ -n "$item" ]] || continue
    log_event "unblocked" "$(jq -nc --arg i "$item" '{item: $i}')"
    release_refinement_label "$item"
  done < <(jq -r '.unblocked[]? // empty' <<<"$wo")
}

# Requirement 18a: the Co-Ordinator re-read a blocked GitHub issue whose
# thread had moved and judged the recorded blocker still holds. Unlike
# `unblocked`, this clears nothing — the item stays blocked — it only leaves a
# marker (`recheck_clean_ts`, via lib/cycle-state.sh's `blocked_items`) so a
# later cycle does not re-read the same still-unchanged thread again.
# Entries are `{item, repo}` (requirement 20); a bare id is tolerated and
# logged without `repo`, which the extract folds into every same-numbered
# blocked item — the degraded fallback requirement 33 describes.
log_recheck_clean_items() {
  local wo="$1" entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    log_event "recheck-clean" "$entry"
  done < <(jq -c '
    .recheck_clean[]?
    | if type == "object" then
        {item: (.item // "" | tostring)}
        + (if (.repo // "") != "" then {repo: .repo} else {} end)
      else {item: tostring} end
    | select(.item != "")' <<<"$wo")
}

# --- The refinement class (requirements 16a, 34e) ---------------------------
# An item nobody has specified well enough to work on is blocked by that fact,
# and the Co-Ordinator is the actor that discovers it — while walking candidates
# it was going to walk anyway. It reports; the Script records. That division is
# requirement 36's, and it is what makes the record real: an issue or a label the
# Script did not write is one no later cycle can match against its own log.
#
# The label is a projection of the block onto the one item type that can carry
# one, and it is applied *before* the event is written so the event can record
# whether it took. A label recorded on the block is a label a later cycle knows
# to remove; a label assumed from config is one it might try to remove from an
# issue that never had it, or leave on an issue after the key changed.

# release_refinement_label ITEM [REPO]
# Take the projected label off the issue behind ITEM, if this item's refinement
# block put one there. Called wherever a block clears — the Co-Ordinator's own
# re-check, an Enabler `unblocked`, and a `void` from either — because the
# label's lifecycle mirrors the block's and nothing else would ever take it off.
#
# Reads the blocked extract this cycle computed *before* the Co-Ordinator ran,
# which is the correct one: the block being cleared is by definition one that was
# open when the cycle started. Best-effort throughout — a stale label is a
# cosmetic fault on an issue, and no reason to disturb a cycle recording state.
release_refinement_label() {
  local item="$1" repo="${2:-}" t_repo t_num t_label
  [[ -n "$item" ]] || return 0
  # A dry run changes nothing in any repository (requirement 12). It still logs
  # the verdicts on this path, as it always has, but a label is an outward act.
  # Written as an `if` rather than `(( DRY_RUN )) && return 0`, whose status
  # would be the function's on the common path — the errexit trap in the
  # Gotchas table, one call site away from a caller that runs under `set -e`.
  if (( DRY_RUN )); then return 0; fi
  while IFS=$'\t' read -r t_repo t_num t_label; do
    [[ -n "$t_repo" && -n "$t_num" && -n "$t_label" ]] || continue
    refinement_label_remove "$t_repo" "$t_num" "$t_label" || log_event "warning" \
      "$(jq -nc --arg d "could not remove the $t_label label from $t_repo#$t_num — the block is cleared regardless" \
         '{detail: $d}')"
  done < <(refinement_label_targets "${blocked_json:-[]}" "$item" "$repo")
}

# log_needs_refinement_items WORK_ORDER
# Record the Co-Ordinator's `needs_refinement` reports as coordinator-stage
# blocks (requirement 34e).
#
# Two entries are dropped rather than recorded, each with a warning, and both
# refusals are the Script's job rather than the prompt's:
#
#   - a malformed entry, on requirement 34d's discipline. The fields are what the
#     Enabler starts from; an entry without them starves the very stage this
#     path exists to reach.
#   - a re-report of an item that is *already* blocked. Requirement 34 keys a
#     block on repo+item and requirement 35a measures the Enabler threshold from
#     the latest one, so a Co-Ordinator that re-reported the same item every
#     cycle would push that clock forward hourly and the item would never become
#     eligible — the same silent starvation this whole path exists to end, with
#     an event trail that looks like progress. The prompt tells it not to
#     (exclusion 1 means it never re-evaluates a blocked item anyway); this is
#     what makes the telling unnecessary.
log_needs_refinement_items() {
  local wo="$1" entry repo item reason problem label number
  while IFS= read -r entry; do
    if ! problem="$(refinement_entry_problem "$entry")"; then
      log_event "warning" "$(jq -nc --arg d "co-ordinator needs_refinement entry dropped — it $problem" \
        '{detail: $d}')"
      continue
    fi
    repo="$(jq -r '.repo // ""' <<<"$entry")"
    item="$(jq -r '.item // ""' <<<"$entry")"
    reason="$(jq -r '.reason // "no reason given"' <<<"$entry")"

    if jq -e --arg r "$repo" --arg i "$item" \
         'any(.[]?; (.repo // "") == $r and ((.item // "") | tostring) == $i)' \
         <<<"${blocked_json:-[]}" >/dev/null 2>&1; then
      log_event "warning" "$(jq -nc \
        --arg d "co-ordinator reported $repo $item as needing refinement, but it is already blocked — left as it is so the Enabler threshold keeps running" \
        '{detail: $d}')"
      continue
    fi

    # No label on a dry run, and — because the event records what was actually
    # applied — no label recorded either, so nothing later tries to remove one
    # that was never there.
    label=""
    if [[ -n "$needs_refinement_label" ]] && ! (( DRY_RUN )); then
      number="$(refinement_issue_number "$entry")"
      if [[ -n "$number" ]]; then
        if refinement_label_add "$repo" "$number" "$needs_refinement_label"; then
          label="$needs_refinement_label"
        else
          log_event "warning" "$(jq -nc \
            --arg d "could not apply the $needs_refinement_label label to $repo#$number (does it exist in that repo?) — the block is recorded either way" \
            '{detail: $d}')"
        fi
      fi
    fi

    log_event "attempt-failed" "$(item_event_fields "coordinator" "$reason" "$repo" "$item" \
      "$(refinement_block_fields "$entry" "$label")")"
  done < <(jq -c '.needs_refinement[]? // empty' <<<"$wo" 2>/dev/null || true)
}

# The Co-Ordinator may void a candidate it can see conclusively is already done,
# rather than paying an Implementor cycle to reach the same verdict. Entries are
# objects (item/repo/reason/evidence), unlike `unblocked`'s bare ids, because a
# void is terminal and worth recording precisely; an entry naming no item is
# ignored.
#
# Requirement 34d: it is corroborated before it is made permanent. The
# Co-Ordinator is the one void author that never reads the tree — it sees a JSON
# digest of candidates and nothing else — so an assertion it makes about the
# default branch is checked against the facts the same cycle gathered, against
# a resolvable `evidence` citation fetched from the repository itself, and
# against requirement 34c's long-standing demand for evidence being present at
# all. An entry the guard refuses is recorded `blocked` instead: the
# Co-Ordinator still skips the item, so nothing churns, but the record is
# clearable and Enabler-eligible (requirement 35a), so an actor that can read
# the tree gets to adjudicate rather than the item disappearing on an unchecked
# claim. See lib/void-guard.sh for what the guard tests and why it is not a
# prompt instruction.
log_voided_items() {
  local wo="$1" repos="${2:-[]}" entry item repo reason refusal
  while IFS= read -r entry; do
    item="$(jq -r '.item // ""' <<<"$entry")"
    [[ -n "$item" ]] || continue
    repo="$(jq -r '.repo // ""' <<<"$entry")"
    reason="$(jq -r '.reason // "no reason given"' <<<"$entry")"

    if refusal="$(void_guard_reason "$entry" "$repos")"; then
      log_event "item-void" "$(item_event_fields "coordinator" "$reason" "$repo" "$item" \
        "$(jq -nc --arg e "$(void_entry_evidence "$entry")" '{evidence: $e}')")"
      # An item with no work needs no refinement either: the label goes, on the
      # same rule that takes it off an unblocked item (requirement 34e).
      release_refinement_label "$item" "$repo"
      continue
    fi

    # Two events, deliberately. The `warning` is what a human scanning the
    # dashboard sees — an agent tried to make something permanent and was wrong,
    # which is worth knowing even though the cycle recovered. The
    # `attempt-failed` is the state: it blocks the item on repo+item exactly as
    # any other failed attempt does (requirement 34), which is what puts it in
    # front of the Enabler.
    log_event "warning" "$(jq -nc \
      --arg d "co-ordinator void refused for ${repo:-<no repo>} $item — $refusal; recorded blocked instead" \
      '{detail: $d}')"
    log_event "attempt-failed" "$(item_event_fields "coordinator" \
      "void refused ($refusal). The Co-Ordinator's stated reason was: $reason" "$repo" "$item" \
      "$(jq -nc --arg c "Establish from the repository itself whether this item describes any remaining work." \
        '{unblock_condition: $c}')")"
  done < <(jq -c '.voided[]? // empty' <<<"$wo" 2>/dev/null || true)
}

detect_and_log_limit_hit() {
  local out_file="$1" text resume_at class reset_known
  limit_phrase_in "$out_file" "$out_file.stderr" || return 1
  # Remembered for the rest of the cycle, because the Enabler runs from the exit
  # trap — after this point on every path — and engaging the fleet's most
  # expensive model moments after any stage hit a limit would simply re-hit it
  # (requirement 35's guards).
  limit_hit_this_cycle=1
  text="$(cat "$out_file" "$out_file.stderr" 2>/dev/null || true)"
  IFS=$'\t' read -r resume_at class reset_known < <(limit_decide "$text" "$limit_cooldown_default_hours")
  log_event "limit-hit" "$(jq -nc --arg r "$resume_at" --arg c "$class" --argjson k "$reset_known" \
    '{resume_at: $r, class: $c, reset_known: $k}')"
  # Tell the fleet now, not a fetch interval from now: publish the stand-down
  # as fleet/limit.json (extend-only; requirement 2.1). Best-effort — the
  # limit-hit event above is already in this node's log, and the union carries
  # it to every peer on their next fetch regardless.
  fleet_limit_publish "$state_repo" "$state_dir" "$resume_at" "$class" "$reset_known" "$node_name" \
    || log_event "warning" "$(jq -nc \
         '{detail: "could not publish fleet/limit.json — peers will pick the cooldown up from the log union instead"}')"
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
# Pre-fetch the PRs waiting on us to answer a human's review (requirement 3c).
# Same rationale as gather_findings, plus one specific to this source: the
# review prose must reach the Implementor verbatim, and the candidate rule
# ("is it our turn?") has to exist for the fingerprint anyway, so it gets one
# definition and both consumers read it (requirement 34a).
gather_review_feedback() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-review-feedback.sh" "$slug" "$pr_label" "$branch_prefix" \
        2>"$cycle_dir/review-feedback-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/review-feedback-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the draft PRs this system raised and then abandoned (requirement 3e).
# Same rationale as gather_review_feedback, plus the one specific to this source:
# its candidacy turns on the clock (a draft crossing the staleness threshold), so
# the array must be computed here and fed to the fingerprint verbatim for the
# no-op short-circuit to notice the transition (see scripts/gather-abandoned-drafts.sh
# and lib/noop-skip.sh).
gather_abandoned_drafts() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-abandoned-drafts.sh" "$slug" "$pr_label" "$branch_prefix" "$abandoned_draft_after_hours" \
        2>"$cycle_dir/abandoned-drafts-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/abandoned-drafts-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the ready-but-conflicted PRs this system raised (requirement 3g).
# Same rationale as gather_abandoned_drafts: its candidacy turns on a transition
# the open-PR digest does not carry (a PR flips to CONFLICTING a cycle after its
# base moved, as GitHub recomputes mergeability asynchronously), so the array
# must be computed here and fed to the fingerprint verbatim for the no-op
# short-circuit to notice it (see scripts/gather-merge-conflicts.sh and
# lib/noop-skip.sh).
gather_merge_conflicts() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-merge-conflicts.sh" "$slug" "$pr_label" "$branch_prefix" \
        2>"$cycle_dir/merge-conflicts-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/merge-conflicts-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the repo's TECH-DEBT.md when it disagrees with itself (requirement
# 3i). Unlike the three above this one's candidacy is a pure function of one
# file's content, so the repo's head SHA would already wake the cycle that
# introduced the drift; the array is fed to the fingerprint verbatim anyway, for
# uniformity with its siblings and because editing scripts/td-check.pl changes
# candidacy with no commit to the target repo at all (see
# scripts/gather-register-hygiene.sh and lib/noop-skip.sh).
gather_register_hygiene() {
  local slug="$1" branch="$2" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-register-hygiene.sh" "$slug" "$branch" \
        2>"$cycle_dir/register-hygiene-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/register-hygiene-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the repo's open issues, whole threads included (requirement 3j) —
# the deterministic exclusions (assigned, labelled `blocked`, pull requests)
# already applied, the judgement ones left to the Co-Ordinator. This source
# used to be the Co-Ordinator's own `gh` read, and a cycle was observed
# skipping the entire walk on a "the input carries no issues" misreading; the
# array makes the candidate set an input rather than an errand (see
# scripts/gather-issues.sh for the incident and the contract).
gather_issues() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-issues.sh" "$slug" \
        2>"$cycle_dir/issues-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/issues-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the voids a human has asked, on GitHub, to be reopened
# (requirement 34f). Unlike every other gatherer this is not a work source: it
# produces no candidates, it edits the skip-list the Co-Ordinator is about to be
# handed. It runs for every repo regardless of that repo's `sources`, because a
# void can be pinned on any item in any repo and a human's instruction to reopen
# one is not a kind of work anybody opted into.
gather_unvoid_requests() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-unvoid-requests.sh" "$slug" "$unvoid_label" \
        2>"$cycle_dir/unvoid-requests-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/unvoid-requests-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the issues a human has labelled directly, asking the pipeline to
# treat them as too under-specified to select (requirement 34g). Like
# gather_unvoid_requests, this is not a work source and runs for every repo
# regardless of `sources`: the label only ever means something on an issue, but
# it is not one of the `issues` source's own candidates, and a repo that opted
# out of `issues` as work can still have a human flagging one by hand.
gather_hand_flagged_refinements() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-hand-flagged-refinements.sh" "$slug" "$needs_refinement_label" \
        2>"$cycle_dir/hand-flagged-refinements-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/hand-flagged-refinements-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

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

# What the register says about specific blocked items (requirement 34i). Unlike
# every gatherer above it, this is not called in the repo walk and not called
# per repo: the ids come from the blocked extract, so it runs only for a repo
# that has blocked register items — which is usually none of them, at no cost.
# An unreadable answer is `{}`, and `{}` clears nothing.
gather_register_status() {
  local slug="$1" branch="$2" out safe
  shift 2
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-register-status.sh" "$slug" "$branch" "$@" \
        2>"$cycle_dir/register-status-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/register-status-$safe.json"
    printf '%s' "$out"
  else
    printf '{}'
  fi
}

# What a merged pull request says about specific blocked project-review refs
# (requirement 34i). Same shape and same reason as gather_register_status
# above: called only for a repo with blocked project-review items, at no cost
# otherwise.
gather_review_status() {
  local slug="$1" branch="$2" out safe
  shift 2
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-review-status.sh" "$slug" "$branch" "$@" \
        2>"$cycle_dir/review-status-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/review-status-$safe.json"
    printf '%s' "$out"
  else
    printf '{}'
  fi
}

# What the implementation-plan document's own checkboxes say about specific
# blocked plan-task ids (requirement 34i). Same shape and same reason as
# gather_register_status above.
gather_plan_status() {
  local slug="$1" branch="$2" path="$3" out safe
  shift 3
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-plan-status.sh" "$slug" "$branch" "$path" "$@" \
        2>"$cycle_dir/plan-status-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/plan-status-$safe.json"
    printf '%s' "$out"
  else
    printf '{}'
  fi
}

# Stage prompts require the final message to be pure JSON, but a model will
# sometimes prepend analysis prose anyway and put the real object in a
# trailing fenced ```json block — or leave it bare after the prose. Try a
# straight parse first; then the last fenced block; then the earliest line
# opening a brace whose text from there to the end of the message parses as
# exactly one JSON value.
#
# The third salvage earns its place by what its absence cost. On 2026-08-03
# an Enabler engagement examined three refinement items, reached a correct
# `escalate` verdict on each and drafted every escalation issue — then ended
# with a summary paragraph, a blank line, and the verdict object, bare. The
# fence fallback could not touch it (the prompts *forbid* the fence, so the
# one deviation this function could rescue was the one the prompts rule
# out), the engagement was discarded whole under requirement 37, and the
# items sat behind its never-released claims for the rest of claim_ttl_hours
# — six further hours — waiting for a retry that could only re-derive what
# the discarded message already said. Prose-then-bare-object is the shape
# models actually produce when they slip; it must not be the one fatal case.
#
# It is deliberately a *suffix* parse: only an object that runs to the end
# of the message is taken, and an object with trailing prose still fails,
# because "which of these is the verdict" is not a question this function
# should answer. `jq -es 'length == 1'` is the single-value check — `jq
# empty` accepts a stream of several values, and a salvage should never be
# looser than the straight parse it backs up.
#
# scripts/publish-dashboard.sh's `extract_status` is a jq port of this
# algorithm and review-cycle.sh carries a bash copy; the three move together
# (docs/DASHBOARD-SPEC.md), and test/extract-json-result.test.sh holds them
# to it.
#
# An empty-or-whitespace-only $text is checked explicitly and fails outright
# (TD26072802, for symmetry with publish-dashboard.sh's extract_status,
# which shares this algorithm per DASHBOARD-SPEC.md): `jq empty` on
# whitespace input succeeds trivially with no output, so without this check
# the function would return 0 — success — while printing nothing. Every call
# site already treats empty output as failure regardless of the exit code, so
# this changes no observable behaviour; it just stops the exit code lying
# about what happened.
extract_json_result() {
  local text="$1" block line_no suffix
  [[ "$text" =~ ^[[:space:]]*$ ]] && return 1
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
  while IFS=: read -r line_no _; do
    suffix="$(tail -n "+$line_no" <<<"$text")"
    if jq -es 'length == 1' <<<"$suffix" >/dev/null 2>&1; then
      jq -c '.' <<<"$suffix"
      return 0
    fi
  done < <(grep -n '^[[:space:]]*{' <<<"$text" || true)
  return 1
}

dump_stage_output() {
  local out_file="$1"
  cat "$out_file"
  [[ -s "$out_file.stderr" ]] && cat "$out_file.stderr" >&2
  # An empty stderr file must not become this function's return value: the
  # call sites are `(( ONCE )) && dump_stage_output …`, and the command after
  # a final `&&` is exactly where `set -e` applies — a stage whose stderr was
  # empty killed a --once cycle here, after the stage ended and before its
  # failure handling (limit detection, attempt-failed, claim release) ran.
  return 0
}

handle_stage_failure() {
  local stage="$1" rc="$2" out_file="$3" pr_url="${4:-}" detail
  if [[ "$rc" == "124" ]]; then
    detail="$stage timed out"
  else
    detail="$stage exited $rc"
  fi
  detect_and_log_limit_hit "$out_file" || true
  # The PR travels on the event (requirement 32a) so the Enabler can open it
  # without re-deriving it from the item id — for a finishing source the item
  # may not name the PR at all.
  log_attempt_failed "$stage" "$detail" \
    "$(jq -nc --arg u "$pr_url" 'if $u == "" then {} else {pr_url: $u} end')"
  if [[ -n "$pr_url" ]]; then
    gh pr comment "$pr_url" --body "Autonomous agent ($stage) stopped on this PR: $detail. Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed.

$(pipeline_comment_marker "$cycle_id")" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
}

# A Reviewer verdict that did not end in a pull request the human can see
# (requirement 32a): `needs-human`/`blocked`, an unparseable status, or a
# `ready` the handoff could not be made true.
#
# It is recorded exactly as any other failed attempt — an `attempt-failed`
# against repo+item, which is what requirement 34 reads as blocked and
# requirement 35a reads as Enabler-eligible. That single choice is what keeps
# the promise the pipeline makes to its human: a pull request that is not ready
# for review is the pipeline's problem until an Enabler says otherwise, and the
# Enabler says otherwise by opening an escalation issue, not by leaving a draft
# where somebody might notice it.
#
# Deliberately silent on the PR itself. The Reviewer has already left its
# concerns there in its own words (requirement 30), which is the record the
# Enabler reads; a second comment from the Script would say nothing new. It
# would not distort the abandoned-drafts clock — a comment this system posts
# carries the marker that keeps it out of that measure (requirement 3e) — but
# "nothing new to say" is reason enough not to post it.
log_reviewer_handback() {
  local detail="$1" pr_url="${2:-}" unblock_condition="${3:-}"
  log_attempt_failed "reviewer" "$detail" \
    "$(jq -nc --arg u "$pr_url" --arg c "$unblock_condition" \
       '(if $u == "" then {} else {pr_url: $u} end)
        + (if $c == "" then {} else {unblock_condition: $c} end)')"
  if [[ -n "$pr_url" ]]; then
    release_claim have-pr
  else
    release_claim no-pr
  fi
}

# --- The Enabler's state for this cycle (requirements 35, 37) ---
# All three are read from the exit trap, so they are initialised here — before
# anything can exit — and only ever move in the safe direction. `enabler_allowed`
# is set once the gatherers have finished, so no early exit (a standby node, the
# switch, a usage-limit cooldown, a lost lock) can engage a stage on inputs it
# never computed.
enabler_allowed=0
enabler_eligible_json='[]'
limit_hit_this_cycle=0

# --- Cleanup (always runs on exit) ---
lock_acquired=0
clone_dir=""
cleanup() {
  local exit_code=$?
  # A signal landing mid-cleanup must not re-enter the handler over a cycle
  # that is already writing its record (requirement 9c).
  trap '' TERM INT HUP
  if [[ -n "$clone_dir" && -d "$clone_dir" ]]; then
    rm -rf "$clone_dir"
  fi
  # The Enabler (requirement 35): here, and only here. This is the one place
  # every ending of a cycle passes through — nine of them exit 0 — so a single
  # call site covers them all, where calls at each exit point would be nine
  # chances to forget one. It runs after the workspace is deleted (it needs no
  # clone) and before `cycle-end`, so its events belong to the cycle that
  # produced them and travel on the state-sync push below. Contained by
  # requirement 37: whatever happens inside, this cycle's exit code is the one
  # computed above.
  maybe_run_enabler "$exit_code" || true
  log_event "cycle-end" "$(jq -nc --argjson rc "$exit_code" '{exit_code: $rc}')"
  if [[ "$lock_acquired" == "1" ]]; then
    rm -f "$lock_file"
  fi
  # Publish this node's state to the fleet (requirement 2.5) — its own
  # `nodes/<NODE_NAME>` branch, so there is nothing another node's push could
  # overwrite and nothing to gate. Here at the end so the cycle's record is
  # complete once `cycle-end` is logged; the every-few-minutes crontab push
  # keeps the heartbeat fresh in between. Isolated like the dashboard refresh
  # below: a sync failure is a replication problem, never a cycle outcome.
  timeout 300 "$SCRIPT_DIR/scripts/state-sync.sh" push || true
  # Refresh the local monitoring dashboard. Fully isolated: a failure or a slow
  # gh call here must never affect the cycle's outcome or exit code.
  if [[ -x "$SCRIPT_DIR/scripts/publish-dashboard.sh" ]]; then
    timeout 120 "$SCRIPT_DIR/scripts/publish-dashboard.sh" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# --- Signals (requirement 9c) ---
# The kills that reach this script are real and routine: a peer taking over a
# stale lock TERMs this cycle's whole process group (requirement 1), an
# operator stops a container, a `--once` run is interrupted at the terminal.
# Untrapped, any of them ends bash between one statement and the next: no
# `attempt-failed`, no `cycle-end`, no claim release, no PR comment — and the
# stage's own process group, which `set -m` detached from ours precisely so a
# timeout could kill it whole, is beyond every one of those signals, so the
# model runs on for work whose cycle is already dead.
#
# The handler's order is its design. The stage is stopped first, with KILL
# rather than TERM: the signaller's patience is unknown and may be two
# seconds, and a stage whose cycle is dead has nothing left to negotiate.
# The event lands second — one local file append, the thing that must
# survive, and what makes the death visible to requirement 34's blocked
# extract instead of silent. The claim release runs last and time-bounded
# (see `claim_release_timeout`): releasing now beats waiting out the gc's
# `claim_ttl_hours`, but not at the price of the record. Exiting through
# `exit` hands 128+n to the EXIT trap, so `cycle-end` reports the truth and
# `maybe_run_enabler`'s cycle_rc guard skips the Enabler unasked.
#
# `stage_pid`/`stage_name` are advertised by `run_claude_stage` while a stage
# is in flight and empty otherwise, so the handler never blames a stage that
# had already ended cleanly.
stage_pid=""
stage_name=""
on_signal() {  # on_signal NAME NUM
  local name="$1" num="$2" pr_url="" actor
  trap '' TERM INT HUP
  if [[ -n "$stage_pid" ]] && kill -0 "$stage_pid" 2>/dev/null; then
    kill -KILL "-$stage_pid" 2>/dev/null || true
  fi
  # A stranded Implementor may have opened its draft PR without ever
  # reporting it; the breadcrumb is the same fallback requirement 9 gives the
  # ordinary failure path, and it must be read before the EXIT trap deletes
  # the clone it lives in.
  #
  # The breadcrumb and nothing else: `pr_url_for_branch`, requirement 9's more
  # reliable fallback, is a network call, and this handler runs on borrowed
  # time — the peer that TERMed us KILLs what has not exited within its grace,
  # which may be two seconds. The event below is the thing that must survive,
  # and a stalled API call ahead of it would trade the record for the URL. A
  # local file read cannot stall; that is the whole reason this line is the
  # one that stayed.
  if [[ -n "$clone_dir" ]]; then
    pr_url="$(read_pr_url_breadcrumb "$clone_dir")"
  fi
  actor="${stage_name:-cycle}"
  log_attempt_failed "$actor" "$actor terminated by SIG$name" \
    "$(jq -nc --arg u "$pr_url" 'if $u == "" then {} else {pr_url: $u} end')"
  claim_release_timeout=8
  if [[ -n "$pr_url" ]]; then
    release_claim have-pr
  else
    release_claim no-pr
  fi
  exit "$(( 128 + num ))"
}
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2'  INT
trap 'on_signal HUP 1'  HUP

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
  local stage="$1" timeout_sec="$2" model="$3" prompt="$4" out_file="$5" cwd="$6"
  local pid waited=0 rc

  # stdout (the JSON envelope) and stderr (diagnostics) are kept in separate
  # files — merging them would let stray stderr output break the JSON parse
  # of the final result.
  #
  # The prompt goes in on stdin, never as an argument (requirement 4c). Linux
  # caps a *single* argv entry at MAX_ARG_STRLEN — 32 pages, 131072 bytes,
  # fixed at compile time and unaffected by `ulimit`, so `getconf ARG_MAX`'s
  # far larger total is no guide to it. An assembled stage prompt is already
  # the same order of magnitude and grows with every prompt edit, so passing
  # it as `claude -p "$prompt"` puts the pipeline one paragraph away from an
  # exec that fails with E2BIG before the model is ever reached. A here-string
  # (rather than a pipe) keeps the invocation a single process whose status is
  # the stage's own: under `pipefail` a `printf | claude` would report
  # printf's SIGPIPE, 141, whenever a stage exited without draining stdin.
  set -m
  ( cd "$cwd" && claude -p --model "$model" --dangerously-skip-permissions --output-format json <<<"$prompt" ) \
    >"$out_file" 2>"$out_file.stderr" &
  pid=$!
  set +m
  # Advertised for the signal handler (requirement 9c): the job's own process
  # group is beyond any signal sent to ours, so a handler that does not know
  # this pid cannot stop the model this cycle is paying for.
  stage_pid="$pid"
  stage_name="$stage"

  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= timeout_sec )); then
      kill -TERM "-$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      stage_pid=""
      stage_name=""
      return 124
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done

  wait "$pid"
  rc=$?
  stage_pid=""
  stage_name=""
  return "$rc"
}

# --- The Enabler (requirements 35–37) ---------------------------------------
# The pipeline's escalation path: a high-tier model, engaged rarely, that
# re-examines items recorded as blocked which the pipeline has not managed to
# unstick by itself — and, for the ones that genuinely need a human, composes a
# GitHub issue the Script then files, assigned, saying exactly what to do.
#
# Everything below is best-effort by construction, because it runs from the exit
# trap (see `cleanup`). A non-zero status escaping any of it would abandon the
# trap part-way and cost the cycle its `cycle-end` event, its lock release and
# its state-sync push — the Enabler failing must never look like the cycle
# failing (requirement 37). So every substitution is guarded, every `gh` call
# tolerates failure, and the whole thing is invoked as `… || true`.

# enabler_claim_key ENTRY
# The fleet's dedup key for one eligible item (requirement 35c): the repo, the
# item, and the epoch of the block it was minted from — plus `__verify<n>` when
# this engagement is verifying a closed escalation, which needs a fresh key
# because the earlier examination's claim is still in the registry.
#
# Derived here, never chosen by a model: two nodes must compute the same key for
# the same item or the claim locks nothing. Keying on the block's timestamp is
# what lets a re-blocked item be examined again while the tombstone of its last
# examination stands.
enabler_claim_key() {
  local entry="$1" repo item ts issue epoch key
  repo="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
  item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
  ts="$(jq -r '.blocked_ts // ""' <<<"$entry" 2>/dev/null || true)"
  issue="$(jq -r 'if (.reason // "") == "issue-closed"
                  then ((.escalation.issue_number // "") | tostring) else "" end' \
             <<<"$entry" 2>/dev/null || true)"
  epoch="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
  key="${repo//[^A-Za-z0-9._-]/-}__${item//[^A-Za-z0-9._-]/-}__$epoch"
  [[ -n "$issue" && "$issue" != "null" ]] && key="${key}__verify${issue}"
  printf '%s' "$key"
}

# create_escalation_issue REPO ITEM LABEL TITLE BODY_FILE
# File one escalation issue, printing "<number>\t<url>"; print nothing and
# return 1 if it could not be filed. Three behaviours, in order:
#
#   - A duplicate guard. An open issue carrying the escalation label whose body
#     already quotes this item's reference *is* the escalation — return it
#     rather than filing a second one at the same human. The item ref in the
#     issue footer (prompts/enabler.md) is what makes this findable, and the
#     body check is what stops a bare number matching an unrelated escalation.
#   - The create carries the label *and* the assignee. The assignee is the
#     load-bearing half: assignment is what excludes an issue from the `issues`
#     work source (requirement 16.4), so the pipeline can never select its own
#     request for help as work. The label is for the human's filter and the
#     guard above.
#   - One retry without the label, because a repo where the label has not been
#     created yet must still get its issue. Losing the label costs a filter;
#     losing the issue costs the escalation.
create_escalation_issue() {
  local repo="$1" item="$2" label="$3" title="$4" body_file="$5"
  local existing raw url number
  existing="$(gh issue list -R "$repo" --label "$label" --state open --search "$item" \
                --json number,url,body 2>/dev/null \
              | jq -r --arg it "$item" \
                  'map(select(((.body // "") | contains($it)))) | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi
  raw="$(gh issue create -R "$repo" --title "$title" --body-file "$body_file" \
           --assignee "$enabler_assignee" --label "$label" \
           2>>"$cycle_dir/enabler-issue.err" || true)"
  if [[ -z "$raw" ]]; then
    raw="$(gh issue create -R "$repo" --title "$title" --body-file "$body_file" \
             --assignee "$enabler_assignee" \
             2>>"$cycle_dir/enabler-issue.err" || true)"
  fi
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  [[ -n "$url" ]] || return 1
  number="${url##*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$number" "$url"
}

# maybe_run_enabler CYCLE_EXIT_CODE
# Engage the Enabler if this cycle should, and translate its verdicts into log
# events and issues. Always returns without disturbing the cycle's outcome.
maybe_run_enabler() {
  local cycle_rc="${1:-1}"
  local claimed_json='[]' engagement_json='[]' n_eligible=0 n_claimed=0 n_out=0 i j
  local entry repo item key live_resume live_epoch input prompt out rc=0 result parsed detail
  local ex e_repo e_item verdict e_reason claimed_entry blocked_ts outcome extra
  local e_pr_url e_handoff e_refusal e_refined
  local issue_title issue_body_file created number url missing

  # --- Guards (requirement 35). Every one of them declining is normal. ---
  # The lock is the log's single-writer guarantee, and this stage writes events.
  (( lock_acquired )) || return 0
  # Set only once the gatherers finished, so no early exit — a standby node, the
  # switch, a cooldown, a skipped cycle that never sampled — can engage a stage
  # on inputs that were never computed.
  (( enabler_allowed )) || return 0
  # A dry run claims nothing and writes nothing, here as everywhere.
  (( DRY_RUN )) && return 0
  # A cycle that ended badly is not the moment to spend the expensive model: the
  # failure itself is the thing to look at, and the item will still be blocked
  # next cycle.
  [[ "$cycle_rc" == "0" ]] || return 0
  (( limit_hit_this_cycle )) && return 0
  [[ -n "$enabler_model" ]] || return 0
  [[ "$timeout_enabler_min" =~ ^[0-9]+$ ]] || return 0
  [[ -f "$PROMPTS_DIR/enabler.md" ]] || return 0

  # Requirement 35d: the refinement class is capped per engagement, ordinary
  # blocked items are not. Applied before the claims, so a capped-out item is
  # left unclaimed and waits — a claim taken and not examined would be a
  # tombstone standing for `claim_ttl_hours` over an item nobody looked at.
  engagement_json="$(refinement_engagement_set "$enabler_eligible_json" "$refinement_max_per_engagement")"
  n_eligible="$(jq 'length' <<<"$engagement_json" 2>/dev/null || echo 0)"
  [[ "$n_eligible" =~ ^[0-9]+$ ]] || n_eligible=0
  (( n_eligible > 0 )) || return 0

  # The fleet limit file, read live rather than from the union snapshot taken at
  # the start of the cycle (requirement 2.1's second carrier): a limit a peer hit
  # while this cycle was working is exactly the news that should stop the most
  # expensive stage in the system from starting.
  live_resume="$(fleet_limit_resume_at "$state_repo" "$state_dir" 2>/dev/null || true)"
  if [[ -n "$live_resume" ]]; then
    live_epoch="$(date -d "$live_resume" +%s 2>/dev/null || echo 0)"
    (( live_epoch > $(date +%s) )) && return 0
  fi

  # --- Claim each item (requirement 35c) ---
  # A per-item file claim under the pseudo-slug `enabler`, deterministic across
  # nodes so exactly one engages, and **never released**: the claim is a
  # tombstone. `lib/claim.sh gc` sweeping it at `claim_ttl_hours` is what lets a
  # failed engagement be retried, and is the only thing that does.
  for (( i = 0; i < n_eligible; i++ )); do
    entry="$(jq -c --argjson i "$i" '.[$i]' <<<"$engagement_json" 2>/dev/null || true)"
    [[ -n "$entry" ]] || continue
    repo="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
    item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
    [[ -n "$repo" && -n "$item" ]] || continue
    key="$(enabler_claim_key "$entry")"
    [[ -n "$key" ]] || continue
    if CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$item" CLAIM_SOURCE="enabler" \
         "$SCRIPT_DIR/lib/claim.sh" claim file enabler "$key" \
         >>"$cycle_dir/claim.log" 2>&1; then
      claimed_json="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$claimed_json" 2>/dev/null \
        || printf '%s' "$claimed_json")"
    fi
  done
  n_claimed="$(jq 'length' <<<"$claimed_json" 2>/dev/null || echo 0)"
  [[ "$n_claimed" =~ ^[0-9]+$ ]] || n_claimed=0
  # Every eligible item already claimed is the ordinary quiet case — this node
  # examined them last cycle, or a peer is examining them now — and is silent on
  # purpose: a warning here would fire every cycle until the tombstones expire.
  (( n_claimed > 0 )) || return 0

  # --- One engagement over every claimed item ---
  # Batched deliberately: the reading is per-item but the session overhead is
  # not, and the items in front of it are few by construction.
  # `$lbl`, not `$label`: `label` is a jq keyword, and a jq program that fails to
  # compile here would leave the runtime input empty — which the guard below turns
  # into a silently skipped engagement.
  input="$(jq -nc --argjson items "$claimed_json" --arg lbl "$enabler_escalation_label" \
    --arg assignee "$enabler_assignee" --arg cycle "$cycle_id" --arg node "$node_name" \
    '{items: $items, escalation_label: $lbl, assignee: $assignee, cycle: $cycle, node: $node}' \
    2>/dev/null || true)"
  [[ -n "$input" ]] || return 0

  prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" enabler "$prompt_overrides_json")

## Runtime input for this engagement

\`\`\`json
$(jq . <<<"$input")
\`\`\`
"
  out="$cycle_dir/enabler.out"
  log_event "stage-start" '{"stage": "enabler"}'
  if run_claude_stage enabler "$(( timeout_enabler_min * 60 ))" "$enabler_model" "$prompt" "$out" "$cycle_dir"; then
    rc=0
  else
    rc=$?
  fi
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --argjson m "$(metering_fields "$enabler_model" "$out")" \
    '{stage: "enabler", exit_code: $rc} + $m')"
  (( ONCE )) && dump_stage_output "$out"

  result="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$result" 2>/dev/null || true)"
  if (( rc != 0 )) || [[ -z "$parsed" ]]; then
    # A timeout or unparseable output changes nothing: no verdict was reached, so
    # no state event is written and the claims stand until gc allows a retry. The
    # cycle's own outcome is untouched (requirement 37); a usage-limit phrase in
    # the transcript still goes down the ordinary cooldown path, because that
    # applies to the whole fleet and not just to this stage.
    if (( rc == 124 )); then
      detail="enabler timed out"
    elif (( rc != 0 )); then
      detail="enabler exited $rc"
    else
      detail="enabler returned an unparseable final message"
    fi
    detect_and_log_limit_hit "$out" || true
    log_event "warning" "$(jq -nc --arg d "$detail — no verdicts recorded; the claims stand until gc lets a later cycle retry" \
      '{detail: $d}')"
    return 0
  fi

  # --- Verdicts (requirement 36a) ---
  n_out="$(jq '(.examined // []) | length' <<<"$parsed" 2>/dev/null || echo 0)"
  [[ "$n_out" =~ ^[0-9]+$ ]] || n_out=0
  for (( j = 0; j < n_out; j++ )); do
    ex="$(jq -c --argjson j "$j" '(.examined // [])[$j]' <<<"$parsed" 2>/dev/null || true)"
    [[ -n "$ex" ]] || continue
    e_repo="$(jq -r '.repo // ""' <<<"$ex" 2>/dev/null || true)"
    e_item="$(jq -r '.item // ""' <<<"$ex" 2>/dev/null || true)"
    verdict="$(jq -r '.verdict // ""' <<<"$ex" 2>/dev/null || true)"
    e_reason="$(jq -r '.reason // "no reason given"' <<<"$ex" 2>/dev/null || true)"
    # Only items this cycle actually claimed are actionable. The model cannot
    # introduce work of its own, and an item a peer holds is the peer's to
    # answer — acting on either would write state nobody arbitrated.
    claimed_entry="$(jq -c --arg r "$e_repo" --arg i "$e_item" \
      'map(select((.repo // "") == $r and (.item // "") == $i)) | first // empty' \
      <<<"$claimed_json" 2>/dev/null || true)"
    if [[ -z "$claimed_entry" ]]; then
      log_event "warning" "$(jq -nc \
        --arg d "enabler: a verdict for an item this cycle did not claim ($e_repo $e_item) — ignored" \
        '{detail: $d}')"
      continue
    fi
    blocked_ts="$(jq -r '.blocked_ts // ""' <<<"$claimed_entry" 2>/dev/null || true)"
    outcome="$verdict"
    extra='{}'
    case "$verdict" in
      unblocked)
        # The thrash guard (requirement 36b), mechanical for the reason
        # requirement 34d's guard is: "do not do this" is already in the prompt,
        # and the model that would do it anyway is one that has convinced itself.
        # Refusing costs a cycle of waiting on an item that is already waiting;
        # accepting costs a loop in which two models re-specify each other's work
        # and no human is ever asked. The examined event is still written, so the
        # item is not re-examined until the recheck window — by which time
        # `refined_before` is still set and the answer is an escalation.
        if ! e_refusal="$(refinement_second_pass_refused "$claimed_entry" "$ex")"; then
          log_event "warning" "$(jq -nc \
            --arg d "enabler: second refinement of $e_repo $e_item refused — $e_refusal; the item stays blocked" \
            '{detail: $d}')"
          outcome="refinement-refused"
          extra="$(jq -nc --arg c "A human decides whether this item's specification is adequate; the Enabler has already refined it once." \
            '{unblock_condition: $c}')"
        else
          # The item becomes selectable again next cycle. `by` names the Enabler
          # so a reader can tell this from the Co-Ordinator's own cheap re-checks
          # (requirement 18) without cross-referencing timestamps.
          log_event "unblocked" "$(jq -nc --arg i "$e_item" --arg r "$e_repo" --arg reason "$e_reason" \
            '{item: $i, repo: $r, by: "enabler", reason: $reason}')"
          # Requirement 36b: an unblocked refinement item carries the refinement
          # itself, and this is where it is made durable — as the comment URL a
          # future Co-Ordinator will read in the issue's thread, or as the spec
          # text for the item types that have no thread to read (requirement 3h).
          # An unblock with neither is the failure worth naming: the block clears
          # and the item returns to the pool exactly as under-specified as it was.
          if [[ "$(jq -r '.kind // ""' <<<"$claimed_entry" 2>/dev/null || true)" == "$REFINEMENT_BLOCK_KIND" ]]; then
            e_refined="$(refinement_record_fields "$ex")"
            if [[ -n "$e_refined" ]]; then
              log_event "item-refined" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
                --argjson x "$e_refined" '{repo: $r, item: $i} + $x')"
            else
              log_event "warning" "$(jq -nc \
                --arg d "enabler: unblocked $e_repo $e_item as refined but returned neither a refined_spec nor a comment — nothing was recorded for the next Co-Ordinator to read" \
                '{detail: $d}')"
            fi
            release_refinement_label "$e_item" "$e_repo"
          fi
          # Requirement 32b: the one block the Enabler can clear by act rather
          # than by verdict — a finished pull request that never left draft. It
          # decides; the Script performs the flip, for the same reason the Script
          # and not the Enabler files an escalation issue (requirement 36): one
          # writer of the pipeline's outward acts. The handoff itself is
          # lib/handoff.sh's, so this path and the Reviewer's cannot drift
          # (requirement 34a).
          e_pr_url="$(jq -r '.pr_url // ""' <<<"$claimed_entry" 2>/dev/null || true)"
          if [[ "$(jq -r '.complete_handoff // false' <<<"$ex" 2>/dev/null || true)" == "true" \
                && -n "$e_pr_url" ]]; then
            e_handoff="$(confirm_pr_ready "$e_pr_url")" || true
            case "$e_handoff" in
              already|flipped)
                # Requirement 31b on the recovery path too. `already` is the
                # answer for a review round that stalled at the Reviewer and the
                # Enabler has now cleared: the PR never was a draft, so the flip
                # settles nothing and the human is still not being asked. Both
                # handoff paths run both halves, or they drift (requirement 34a).
                e_rereview="$(confirm_review_requested "$e_pr_url")" || true
                e_rereview_state=""; e_rereview_who=""
                IFS=$'\t' read -r e_rereview_state e_rereview_who <<<"$e_rereview" || true
                if [[ "$e_rereview_state" == "failed" ]]; then
                  log_event "warning" "$(jq -nc --arg u "$e_pr_url" \
                    --arg d "enabler completed the handoff on $e_pr_url, but review could not be re-requested from ${e_rereview_who:-the reviewer} — they will not see it in their review queue" \
                    '{detail: $d, pr_url: $u}')"
                fi
                log_event "pr-ready" "$(jq -nc --arg u "$e_pr_url" --arg h "$e_handoff" \
                  --arg rr "$e_rereview_state" --arg w "$e_rereview_who" \
                  '{pr_url: $u, handoff: "enabler", state: $h}
                   + (if $rr == "" or $rr == "none" then {} else {review_requested: $rr} end)
                   + (if $w == "" then {} else {reviewers: ($w | split(","))} end)')"
                ;;
              *)
                log_event "warning" "$(jq -nc --arg u "$e_pr_url" \
                  --arg d "enabler asked for the handoff on $e_pr_url to be completed, but it is still a draft" \
                  '{detail: $d, pr_url: $u}')"
                ;;
            esac
            extra="$(jq -nc --arg h "$e_handoff" '{complete_handoff: $h}')"
          fi
        fi
        ;;
      void)
        # Requirement 9b: "the work is already done" is a void, never an unblock.
        log_event "item-void" "$(item_event_fields "enabler" "$e_reason" "$e_repo" "$e_item" \
          "$(jq -c '{evidence: (.evidence // "")}' <<<"$ex" 2>/dev/null || echo '{}')")"
        release_refinement_label "$e_item" "$e_repo"
        ;;
      still-blocked)
        # Nothing extra to record: the block stands, and the refreshed condition
        # travels on the examined event below, which is what a later engagement
        # and the dashboard read.
        extra="$(jq -c '{unblock_condition: (.unblock_condition // "")}' <<<"$ex" 2>/dev/null || echo '{}')"
        ;;
      escalate)
        issue_title="$(jq -r '.issue.title // ""' <<<"$ex" 2>/dev/null || true)"
        issue_body_file="$cycle_dir/enabler-issue-$j.md"
        jq -r '.issue.body // ""' <<<"$ex" > "$issue_body_file" 2>/dev/null || true
        if [[ -z "$issue_title" || ! -s "$issue_body_file" ]]; then
          log_event "warning" "$(jq -nc \
            --arg d "enabler: escalate verdict for $e_repo $e_item carried no issue title or body — nothing filed" \
            '{detail: $d}')"
          outcome="escalation-failed"
        elif created="$(create_escalation_issue "$e_repo" "$e_item" "$enabler_escalation_label" \
                          "$issue_title" "$issue_body_file")" && [[ -n "$created" ]]; then
          IFS=$'\t' read -r number url <<<"$created"
          log_event "escalated" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
            --argjson n "$number" --arg u "$url" --arg b "$blocked_ts" \
            '{repo: $r, item: $i, issue_number: $n, issue_url: $u, blocked_ts: $b}')"
        else
          # The examined event records `escalation-failed`, which requirement 35a
          # deliberately does not count as an examination: the item stays at the
          # threshold and is retried once its claim expires.
          log_event "warning" "$(jq -nc \
            --arg d "enabler: could not file the escalation issue for $e_repo $e_item (see enabler-issue.err) — retried after the claim TTL" \
            '{detail: $d}')"
          outcome="escalation-failed"
        fi
        ;;
      *)
        log_event "warning" "$(jq -nc \
          --arg d "enabler: unrecognised verdict '$verdict' for $e_repo $e_item — recorded, acted on in no way" \
          '{detail: $d}')"
        outcome="unknown-verdict"
        ;;
    esac
    # Written for every verdict, including the ones that changed nothing: this
    # marker is what stops the same item being re-examined next cycle, and what
    # the recheck window is measured from (requirement 35a).
    log_event "enabler-examined" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
      --arg b "$blocked_ts" --arg o "$outcome" --arg d "$e_reason" --argjson x "$extra" \
      '{repo: $r, item: $i, blocked_ts: $b, outcome: $o, detail: $d} + $x')"
  done

  # A claimed item the model never mentioned keeps its claim and stays blocked,
  # so gc is what eventually retries it. Named in a warning rather than dropped
  # silently: a stage that routinely omits items is a prompt problem, and the log
  # is the only place that would ever become visible.
  while IFS= read -r missing; do
    [[ -n "$missing" ]] || continue
    log_event "warning" "$(jq -nc \
      --arg d "enabler: no verdict for claimed item $missing — left blocked until the claim TTL lets a later cycle retry" \
      '{detail: $d}')"
  done < <(jq -r --argjson p "$parsed" '
      (($p.examined // []) | map(((.repo // "") + " " + (.item // "")))) as $seen
      | .[] | ((.repo // "") + " " + (.item // ""))
      | select(. as $k | $seen | index($k) | not)' <<<"$claimed_json" 2>/dev/null || true)
  return 0
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

# --- 0a. The fleet switch (requirement 2.3a) ---
# The same switch, one level up: fleet/disabled.json on the state repository's
# main. Local first because it is free; this one costs a single contents read
# — still before the lock, still before anything that spends. Absent means
# enabled; unreachable falls back to the last fetched copy, and to enabled
# with none — safe, because a node that charges ahead blind meets per-item
# claims that fail closed (requirement 17a).
#
# An expired fleet disable is cleared by whichever node sees it first: the
# delete is sha-guarded and idempotent, so a lost race just means a peer got
# there — there is no singleton chore here (requirement 2.5).
fleet_switch_state="$(fleet_disabled_state "$state_repo" "$state_dir")"
case "$(jq -r '.state' <<<"$fleet_switch_state")" in
  expired)
    fleet_flag_delete "$state_repo" "$state_dir" disabled || true
    log_event "enabled" "$(jq -nc \
      --argjson r "$(jq -c '.record' <<<"$fleet_switch_state")" \
      '{detail: "fleet disable expired", was: $r}')"
    ;;
  disabled)
    log_event "stand-down" "$(jq -nc \
      --arg r "fleet switch: $(toggle_describe "$(jq -c '.record' <<<"$fleet_switch_state")")" \
      '{reason: $r}')"
    (( ONCE )) && echo "agent-cycle: the fleet switch is set — agent-cycle.sh --enable clears it everywhere" >&2
    exit 0
    ;;
esac

# --- 1. Lock ---
acquire_lock() {
  if [[ -f "$lock_file" ]]; then
    local pid started_at host
    pid="$(jq -r '.pid // empty' "$lock_file" 2>/dev/null || true)"
    started_at="$(jq -r '.started_at // empty' "$lock_file" 2>/dev/null || true)"
    host="$(jq -r '.host // empty' "$lock_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      local started_epoch now_epoch age_sec pgid
      started_epoch="$(date -d "$started_at" +%s 2>/dev/null || echo 0)"
      now_epoch="$(date +%s)"
      age_sec=$(( now_epoch - started_epoch ))
      if [[ -n "$host" && "$host" != "${HOSTNAME:-}" ]]; then
        # A pid is only meaningful in the PID namespace that minted it. This
        # lock's `host` names a different container, so its incarnation is
        # gone by construction — take it over without asking `kill -0`,
        # which would be answering about an unrelated process in ours (#130
        # fixed the same confusion in the watchtower hook).
        log_event "warning" "$(jq -nc --arg d "foreign lock from pid $pid on host $host (age ${age_sec}s) taken over" '{detail: $d}')"
      else
        local stale_after_sec
        stale_after_sec=$(( lock_stale_after_hours * 3600 ))
        if kill -0 "$pid" 2>/dev/null && (( age_sec < stale_after_sec )); then
          log_event "cycle-skipped" "$(jq -nc --arg d "lock held by pid $pid, age ${age_sec}s" '{detail: $d}')"
          exit 0
        fi
        if kill -0 "$pid" 2>/dev/null; then
          pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
          if [[ -n "$pgid" ]]; then
            # TERM first, so the doomed cycle's own handler (requirement 9c)
            # can log its `attempt-failed` and release its claim; KILL only
            # after a grace sized to that handler's worst case — one
            # process-group kill, one log append, one 8-second-bounded claim
            # release. Polled rather than slept: a cycle that records and
            # exits in one second costs one second.
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
        log_event "warning" "$(jq -nc --arg d "stale lock from pid $pid (age ${age_sec}s) taken over" '{detail: $d}')"
      fi
    fi
  fi
  # `host` names the container (PID namespace) the pid is meaningful in: the
  # dashboard shares this lock through the state volume, and its copy of
  # watchtower's pre-update hook must know it cannot `kill -0` our pid (#130).
  jq -n --argjson pid "$$" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "${HOSTNAME:-}" \
    '{pid: $pid, started_at: $started_at, host: $host}' > "$lock_file"
  lock_acquired=1
}
acquire_lock

# --- 1a. The fleet's memory (requirement 2.5) ---
# `lock.json` keeps two cycles apart on one node; per-item claims (requirement
# 17a) keep two *nodes* off the same work. Nothing arbitrates "the" active
# node any more — what the fleet shares instead is memory: the union of every
# node's event log, materialised by `state-sync.sh fetch` into the peers
# directory. Snapshotted here, once, so every reader below (the usage-limit
# cooldown, the blocked and void extractions, the no-op fingerprint) sees one
# consistent stream — a lesson any node learned spares the whole fleet.
peers_dir="$(fleet_peers_dir "$workspace_root")"
union_log="$cycle_dir/.fleet-log.jsonl"
fleet_logs "$state_dir" "$peers_dir" log.jsonl > "$union_log" || true

# --- 1b. Crash-loop escalation (requirement 2.7) ---
# A Co-Ordinator failure pins no repo/item — nothing is blocked, so the whole
# blocked → Enabler → escalation ladder that covers item failures never sees
# it — and the cycle still ends 0, so the dashboard shows a healthy idle
# fleet. When the failure is deterministic and ships in the image (the
# 2026-08-01 argv-cap outage: `coordinator exited 126`, every node, every
# hour, ~15 hours), the record and the reality diverge completely. So the one
# signal that class does leave — the same failure, verbatim, over and over
# with no success anywhere in the fleet — is read here, from the same union
# every other fleet-wide judgement uses, and escalated the same way the
# Enabler escalates: an issue at the human, deduplicated, assigned so the
# pipeline can never select its own SOS as work. Before the stand-down
# checks, so a fleet that is also standing down (a limit, the switch) still
# raises the alarm; after the union snapshot, because the loop is a property
# of the fleet's memory, not this node's. The cycle then proceeds normally —
# detection must never suppress the recovery attempt that might end the loop.
if ! (( DRY_RUN )) && (( crash_loop_after > 0 )) \
    && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" && -s "$union_log" ]]; then
  crash_loop_json="$(crash_loop_verdict "$crash_loop_after" < "$union_log")"
  if [[ -n "$crash_loop_json" ]]; then
    cl_detail="$(jq -r '.detail // ""' <<<"$crash_loop_json")"
    cl_first_ts="$(jq -r '.first_ts // ""' <<<"$crash_loop_json")"
    if ! crash_loop_escalated_since "$cl_first_ts" "$cl_detail" < "$union_log"; then
      cl_body="$cycle_dir/crash-loop-issue.md"
      {
        printf '## What the fleet log shows\n\n'
        jq -r '"- **\(.count) consecutive Co-Ordinator failures**, every one `\(.detail)`\n- first at `\(.first_ts)`, still failing at `\(.last_ts)`\n- nodes affected: \(.nodes | join(", "))"' \
          <<<"$crash_loop_json"
        cat <<'CRASH_LOOP_BODY'

No Co-Ordinator has succeeded anywhere in the fleet since the first of these.
A failure this uniform is almost certainly deterministic — something that ships
in the image or the config, not a transient — so no amount of retrying will
clear it, and until it clears the fleet selects no work at all.

Start with the newest failing cycle's `coordinator.out.stderr` under
`state_dir/cycles/`; the stage transcripts survive every failure.

---
Filed automatically by agent-cycle.sh (requirement 2.7).
ref: crash-loop:coordinator
CRASH_LOOP_BODY
      } > "$cl_body"
      if cl_created="$(create_escalation_issue "$crash_loop_repo" "crash-loop:coordinator" \
            "$enabler_escalation_label" \
            "Crash loop: the Co-Ordinator is failing fleet-wide ($cl_detail)" \
            "$cl_body")" && [[ -n "$cl_created" ]]; then
        log_event "crash-loop-escalated" "$(jq -c \
          --argjson n "${cl_created%%$'\t'*}" --arg u "${cl_created#*$'\t'}" \
          '. + {issue_number: $n, issue_url: $u}' <<<"$crash_loop_json")"
      else
        log_event "warning" "$(jq -nc --arg d "crash loop detected ($cl_detail) but the escalation issue could not be filed — will retry next cycle" '{detail: $d}')"
      fi
    fi
  fi
fi

# --- 2. Stand-down checks ---
# 2.1 Usage-limit cooldown (fleet-wide: every node shares one Claude account,
# so a limit any node hit stands this one down too). Two carriers of the same
# signal, and the later resume wins: the log union is as fresh as the last
# state-sync fetch, while fleet/limit.json is read live — it is what lets a
# limit one node hit a minute ago stop this cycle now, not a fetch interval
# from now. Either carrier can be retired early — automatically by the probe
# of 2.1b below when the resume time is this system's own guess, or by hand
# with `--clear-limit` (2.1) — and both retirements work the same way: the
# union's reduction honours a `limit-cleared` event, and the flag is deleted
# outright.
#
# Both records are carried whole rather than reduced to a timestamp, so the
# logged reason can say whether `resume_at` is a stated reset or this system's
# own guess. Reporting a guess as a deadline is what let a stale stand-down
# outlive the limit that caused it and go unquestioned.
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
now_epoch="$(date +%s)"
if (( resume_epoch > now_epoch )); then
  governing_class="$(jq -r '.class // "other"' <<<"$governing" 2>/dev/null || echo other)"
  governing_known="$(limit_reset_known "$governing")"
  standing=1
  probe_note=""
  # 2.1b The estimated stand-down probes its own exit. When `reset_known` is
  # false, `resume_at` is this system's invented time and carries no
  # information about the limit — and the observed spend-cap message is
  # emitted equally when a 5-hour session window meets an exhausted cap,
  # which clears at the session rollover, most of a day before the invented
  # time (it did, on 2026-07-28: both hits cleared within the hour; the fleet
  # would have slept 24). So instead of sleeping on a guess, spend one
  # minimal invocation of the cheapest model asking the only authority there
  # is. The economics run the right way round on both sides: a limited
  # account answers the probe with the limit message at no token cost, and an
  # unlimited one answers for a fraction of a cent, once — the first clear
  # verdict retires the stand-down for the whole fleet, and the gate stops
  # firing. A *stated* reset is never probed: the message named the time, and
  # asking earlier is the one spend that buys nothing. Nor does --dry-run
  # probe: a cycle that promises to change nothing must not write
  # `limit-cleared`, and a probe whose verdict it would have to ignore is
  # pure cost.
  if [[ "$governing_known" != "true" ]] && ! (( DRY_RUN )); then
    probe_out="$cycle_dir/limit-probe.out"
    run_claude_stage limit-probe 180 "$implementor_model_trivial" \
      "Reply with the single word: ok" "$probe_out" "$cycle_dir" || true
    probe_verdict="$(limit_probe_verdict "$(cat "$probe_out" 2>/dev/null || true)" \
      "$(cat "$probe_out.stderr" 2>/dev/null || true)")"
    case "$probe_verdict" in
      clear)
        # The same two carriers --clear-limit retires, for the same reason it
        # retires both: the stand-down lifts only when the later of the two
        # says so. The `limit-cleared` event outranks every earlier hit in
        # the union's reduction; the flag is deleted because
        # fleet_limit_publish is extend-only and delete is the one write that
        # legitimately moves a resume earlier.
        log_event "limit-cleared" "$(jq -nc --arg w "$resume_at" \
          --arg by "auto-probe@$node_name" \
          '{was: $w, reason: "probe answered: the limit behind this estimated stand-down is gone", by: $by}')"
        if [[ -n "$state_repo" ]]; then
          fleet_flag_delete "$state_repo" "$state_dir" limit || log_event "warning" \
            '{"detail": "could not clear fleet/limit.json after a clear probe — peers reading it live stand down until their own probes answer"}'
        fi
        standing=0
        ;;
      limited)
        # The probe just observed the limit live, which is worth recording
        # for two reasons: the Enabler must not be engaged from the exit trap
        # moments after a limit was re-confirmed (requirement 35's guards),
        # and the probe's transcript may state what the original message did
        # not — a parseable reset upgrades `reset_known` to true and stops
        # the probing until a time that is finally real.
        detect_and_log_limit_hit "$probe_out" || true
        probe_note=" (probe: still limited)"
        ;;
      *)
        probe_note=" (probe: inconclusive)"
        ;;
    esac
  fi
  if (( standing )); then
    log_event "stand-down" "$(jq -nc --arg r "usage-limit cooldown $(limit_describe "$resume_at" \
      "$governing_class" "$governing_known")$probe_note" '{reason: $r}')"
    exit 0
  fi
fi

# 2.1a Claim GC — sweep registry entries older than claim_ttl_hours (17a).
# Every node runs it, because it needs no coordination: a registry delete is
# sha-guarded, and a claim branch is deleted only if it is unmoved AND has no
# PR, so the worst race outcome is a no-op. Runs before 2.2 so the count
# there does not include entries this sweep just retired. Skipped on
# --dry-run: a cycle that promises to change nothing must not delete refs.
if ! (( DRY_RUN )); then
  "$SCRIPT_DIR/lib/claim.sh" gc >>"$cycle_dir/claim.log" 2>&1 || true
fi

# 2.1b Orphan-branch sweep (requirement 17b) — the state the gc above leaves
# behind on purpose. Retiring a moved branch's registry entry while keeping
# its ref is right for the work (pushed commits are never deleted) and wrong
# for the item: with no PR, nothing ever finds those commits again, every
# later claim 422s against the live ref, and the Co-Ordinator's exclusion
# reads it as "claimed, skip" — the item is wedged and nothing has said so.
# The sweep turns each provable orphan back into a state the pipeline already
# handles: a draft PR the abandoned-drafts source recovers, or (for a ref
# with nothing on it) no ref at all. Every node runs it, like the gc and for
# the same reason: GitHub rejects a second PR for the same head and a second
# ref delete is a no-op, so the worst race outcome is a warning. Fleet-wide
# like the gc, regardless of --repo. Skipped on --dry-run: the sweep opens
# PRs and deletes refs.
if ! (( DRY_RUN )); then
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        recovered) log_event "orphan-branch-recovered" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        released)  log_event "orphan-branch-released" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        deferred|warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("orphan-branch sweep (" + $r + "): " + (del(.repo) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-orphan-branches.sh" "$sweep_slug" \
               2>>"$cycle_dir/orphan-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 2.2 Back-pressure — across ALL configured repos, regardless of --repo.
#
# The stand-down is *deferred* rather than taken here (requirement 2.2a). Back-
# pressure throttles starting new work, and until the sources are gathered we do
# not know whether the only candidate is review-feedback — which finishes work
# already in the human's queue instead of adding to it. Standing down here would
# deadlock the pipeline exactly when it is most stuck: max_open_agent_prs PRs
# all waiting on the agent, and the one source that could clear them never
# reached. The cost of deferring is the handful of `gh` calls in step 3.
# The count is taken in three parts — ready PRs, draft PRs, live claims —
# because the trip decision needs only the sum, but the logged reason states
# the split: a ready PR is the human's queue, a draft is work in flight (the
# Implementor's own claim marker, requirement 23), and which of them filled
# the gate is what a cap-tuning decision needs to know. Recording it here
# costs nothing; reconstructing it later means cycle-record archaeology.
ready_count=0
draft_count=0
while IFS= read -r slug; do
  counts="$(gh pr list -R "$slug" --state open --label "$pr_label" --json isDraft \
    --jq '[([.[] | select(.isDraft | not)] | length), ([.[] | select(.isDraft)] | length)] | @tsv' 2>/dev/null)" || counts=''
  IFS=$'\t' read -r n_ready n_draft <<<"$counts"
  [[ "$n_ready" =~ ^[0-9]+$ ]] || n_ready=0
  [[ "$n_draft" =~ ^[0-9]+$ ]] || n_draft=0
  ready_count=$(( ready_count + n_ready ))
  draft_count=$(( draft_count + n_draft ))
done < <(jq -r '.[].slug' <<<"$all_repos_json")

# Live claims count toward the cap too: a claim is work in flight that has
# not yet surfaced as a PR (its registry entry is dropped the moment the PR
# exists), and N nodes counting only PRs would collectively overshoot by the
# work each other had claimed but not yet raised. Still approximate — two
# nodes can pass this check simultaneously — with a stated bound of
# max_open_agent_prs + (nodes - 1), transient.
claim_count=0
while IFS= read -r slug; do
  n="$("$SCRIPT_DIR/lib/claim.sh" count "$slug" 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  claim_count=$(( claim_count + n ))
done < <(jq -r '.[].slug' <<<"$all_repos_json")

open_count=$(( ready_count + draft_count + claim_count ))
open_composition="$ready_count ready + $draft_count draft + $claim_count unraised claim(s)"

backpressure_tripped=0
if (( open_count >= max_open_agent_prs )); then
  backpressure_tripped=1
fi

# --- 2b. Git identity ---
# After every stand-down check above (switch, fleet switch, usage-limit) and
# before the first repo this cycle might actually touch: none of those
# earlier exits commit anything and must not be blocked on an identity they
# never use, but everything from here on can. See lib/git-identity.sh.
require_git_identity agent-cycle

# --- 3. Repo ordering (most overdue first: staleness age weighted by each repo's nice — lib/repo-order.sh; identical to least-recent-first when no nice is set) ---
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
unvoid_requests_json="[]"
hand_flagged_refinements_json="[]"
claimed_json="[]"
repo_order_now="$(date +%s)"
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
  review_feedback="[]"
  if jq -e 'any(.[]; . == "review-feedback")' <<<"$sources" >/dev/null 2>&1; then
    review_feedback="$(gather_review_feedback "$slug")"
  fi
  abandoned_drafts="[]"
  if jq -e 'any(.[]; . == "abandoned-drafts")' <<<"$sources" >/dev/null 2>&1; then
    abandoned_drafts="$(gather_abandoned_drafts "$slug")"
  fi
  merge_conflicts="[]"
  if jq -e 'any(.[]; . == "merge-conflicts")' <<<"$sources" >/dev/null 2>&1; then
    merge_conflicts="$(gather_merge_conflicts "$slug")"
  fi
  register_hygiene="[]"
  if jq -e 'any(.[]; . == "register-hygiene")' <<<"$sources" >/dev/null 2>&1; then
    register_hygiene="$(gather_register_hygiene "$slug" "$default_branch")"
  fi
  # The issues source is one source at four ranks (`issues:urgent` …
  # `issues:low`, requirement 15e), so any band in `sources` warrants the one
  # fetch — the band is per issue, not per fetch.
  issues="[]"
  if jq -e 'any(.[]; startswith("issues"))' <<<"$sources" >/dev/null 2>&1; then
    issues="$(gather_issues "$slug")"
  fi
  # The implementation-plan source's path is per-repo config, never a path
  # fixed in the prompt (issue #77): echo it into the runtime-input entry only
  # when the repo actually lists the source, so the Co-Ordinator reads it from
  # its own input rather than a repo it happens to know about. The startup
  # guard above already refused to run if this were missing.
  implementation_plan_path=""
  if jq -e 'any(.[]; . == "implementation-plan")' <<<"$sources" >/dev/null 2>&1; then
    implementation_plan_path="$(jq -r --arg s "$slug" \
      '.[] | select(.slug == $s) | .implementation_plan_path // ""' <<<"$repos_json")"
  fi
  entry="$(jq -nc --arg slug "$slug" --arg db "$default_branch" --argjson sources "$sources" \
    --argjson findings "$findings" --argjson rf "$review_feedback" --argjson ad "$abandoned_drafts" \
    --argjson mc "$merge_conflicts" --argjson rh "$register_hygiene" --argjson issues "$issues" \
    --arg ipp "$implementation_plan_path" \
    '{slug: $slug, default_branch: $db, sources: $sources, findings: $findings, review_feedback: $rf, abandoned_drafts: $ad, merge_conflicts: $mc, register_hygiene: $rh, issues: $issues}
     + (if $ipp == "" then {} else {implementation_plan_path: $ipp} end)')"
  ordered_repos_json="$(jq -c --argjson e "$entry" '. + [$e]' <<<"$ordered_repos_json")"
  # Kept in a separate array, never folded into the entry above: this is the
  # Script's own bookkeeping, and every byte added to `ordered_repos_json` is a
  # byte the Co-Ordinator pays to read. A cost-control feature that grows the
  # prompt it is meant to avoid buying has not saved anything.
  state="$(gather_source_state "$slug" "$default_branch")"
  source_states_json="$(jq -c --argjson s "$state" '. + [$s]' <<<"$source_states_json")"
  # Requirement 34f, gathered here for the repo loop's one `gh` budget but read
  # below, before the skip-lists: a human's instruction to reopen a void has to
  # land *before* the extract the Co-Ordinator is handed, not after it.
  unvoid_requests_json="$(jq -c --argjson r "$(gather_unvoid_requests "$slug")" '. + $r' \
    <<<"$unvoid_requests_json")"
  # Requirement 34g, same reasoning: a human's hand-applied label has to reach
  # the skip-list before the Co-Ordinator is handed it. An empty
  # `needs_refinement_label` disables the projection entirely (README.md), so
  # there is nothing to scan for and no `gh` call to spend.
  if [[ -n "$needs_refinement_label" ]]; then
    hand_flagged_refinements_json="$(jq -c --argjson r "$(gather_hand_flagged_refinements "$slug")" '. + $r' \
      <<<"$hand_flagged_refinements_json")"
  fi
  # Requirement 3o, gathered here for the repo loop's one pass but a top-level
  # array in the Co-Ordinator's input (like `blocked` and `void`), never
  # folded into `entry`: unconditional, regardless of `sources`, because any
  # starting source's item can be claimed.
  claimed_json="$(jq -c --arg r "$slug" --argjson items "$(gather_claimed "$slug")" \
    '. + ($items | map({repo: $r} + .))' <<<"$claimed_json")"
done < <(repo_order_by_effective_age "$repo_order_now" "$repos_json" < "$cycle_dir/.repo_ts")
rm -f "$cycle_dir/.repo_ts"

# --- Skip-list extracts (requirement 34: blocked iff the most recent
#     attempt-failed/unblocked event for that repo+item is attempt-failed;
#     requirement 34c: void iff the most recent item-void/unvoided event for it
#     is item-void). Two lists, not one, because the Co-Ordinator may clear the
#     first and may never clear the second. ---
#
# Read here — above the back-pressure decision below, not after it — because the
# Enabler's eligible set is derived from these two lists (requirement 35a) and
# back-pressure can end the cycle. A fleet wedged at `max_open_agent_prs` is
# exactly when getting something unblocked matters most, and the Enabler opens
# no PRs, so it must not be what back-pressure silences.
# Requirement 34f, applied first: a human labelled an issue or pull request on
# GitHub asking for a void to be reopened. The `unvoided` events go in here —
# above the extract that reads them — because a clearance landing after
# `void_json` was computed would be a cycle late, and a cycle late for this
# source means the human watches nothing happen and concludes, a second time,
# that the label does not work.
#
# The new lines are appended to the union snapshot as well as to the log. That
# snapshot was taken once at the top of the cycle (requirement 2.5) so every
# reader below sees one consistent stream; rebuilding it here would pull in
# whatever peers had written since, which is the inconsistency it exists to
# prevent, so the exact lines this cycle just wrote are what gets added and
# nothing else.
unvoid_clearances_json="$(unvoid_clearances "$unvoid_requests_json" "$(void_items "$union_log")")"
if [[ "$(jq 'length' <<<"$unvoid_clearances_json" 2>/dev/null || echo 0)" != "0" ]]; then
  log_lines_before="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
  while IFS= read -r clearance; do
    [[ -n "$clearance" ]] || continue
    # `by: "label"` distinguishes this from the Enabler's unblocks and from a
    # line a human appended by hand; the request's URL and the void's own
    # timestamp are what let a later reader see which verdict was reopened and
    # on whose authority, without going back to GitHub.
    log_event "unvoided" "$(jq -c '{item: .item, repo: .repo, by: "label",
                                    request_url: .url, labelled_at: .labelled_at,
                                    cleared_void_ts: .void_ts}' <<<"$clearance")"
  done < <(jq -c '.[]' <<<"$unvoid_clearances_json" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
fi

# Requirement 34g, applied next and for the same reason as 34f above: a human
# labelled an issue directly, asking the pipeline to treat it as too
# under-specified to select, and that has to land before `blocked_json` is
# read below — a cycle late here is a human watching nothing happen and
# concluding, the same way they would for an unread `unvoided`, that the label
# does not work.
#
# New blocks first, against `blocked_items` as it stands after the unvoid
# clearances above (an item a void just reopened has no other block to
# collide with); then, against the extract as it stands after those new
# blocks, which hand-flagged blocks this mechanism created have lost their
# label since — the `unblocked` half of the same requirement.
if [[ -n "$needs_refinement_label" ]]; then
  hand_flag_new_json="$(refinement_hand_flag_new "$hand_flagged_refinements_json" "$(blocked_items "$union_log")")"
  if [[ "$(jq 'length' <<<"$hand_flag_new_json" 2>/dev/null || echo 0)" != "0" ]]; then
    log_lines_before="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
    while IFS= read -r flag; do
      [[ -n "$flag" ]] || continue
      log_event "attempt-failed" "$(item_event_fields "coordinator" \
        "$(jq -r '"hand-applied the " + .label + " label" + (if (.by // "") == "" then "" else " (by " + .by + ")" end)' <<<"$flag")" \
        "$(jq -r '.repo' <<<"$flag")" "$(jq -r '.number' <<<"$flag")" \
        "$(refinement_hand_flag_fields "$(jq -r '.repo' <<<"$flag")" "$(jq -r '.number' <<<"$flag")" \
             "$(jq -r '.label' <<<"$flag")" "$(jq -r '.by // ""' <<<"$flag")" \
             "$(jq -r '.labelled_at // ""' <<<"$flag")" "$(jq -r '.url // ""' <<<"$flag")")")"
    done < <(jq -c '.[]' <<<"$hand_flag_new_json" 2>/dev/null || true)
    tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
  fi

  hand_flag_cleared_json="$(refinement_hand_flag_cleared "$hand_flagged_refinements_json" "$(blocked_items "$union_log")")"
  if [[ "$(jq 'length' <<<"$hand_flag_cleared_json" 2>/dev/null || echo 0)" != "0" ]]; then
    log_lines_before="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
    while IFS= read -r cleared; do
      [[ -n "$cleared" ]] || continue
      # `by: "label-removed"` distinguishes this from the Co-Ordinator's own
      # `unblocked` (requirement 18) and the Enabler's — the same trail
      # `unvoided`'s `by: "label"` leaves for a void reopened the same way.
      log_event "unblocked" "$(jq -c '{item: .item, repo: .repo, by: "label-removed"}' <<<"$cleared")"
    done < <(jq -c '.[]' <<<"$hand_flag_cleared_json" 2>/dev/null || true)
    tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
  fi
fi

# Requirement 34i, applied last of the three reconciliations, and for the same
# reason as 34f and 34g above: it has to land before the extract the
# Co-Ordinator, the Enabler's eligible set and the dashboard are all handed.
# What it clears is the block whose *work* has gone — the issue closed, the
# pull request merged, the register entry flipped to `resolved` — none of which
# emits an event, and none of which any other reader of the log can see. The
# Co-Ordinator never revisits such an item (a finished item is offered by no
# source, so it never reaches the candidates), which leaves only the Enabler's
# recheck, a full engagement `enabler_recheck_hours` later to learn what one
# read of state already on disk says now.
#
# Against the *open* blocked set (requirement 34h): a void item needs no
# unblocking, and an `unblocked` written against a void would put a clear in the
# log for no reason at all.
open_blocked_now="$(open_blocked_items "$union_log")"
# The register read, for the repos that have blocked register items and no
# others — usually none, and then it costs nothing. `ordered_repos_json` is what
# names each repo's default branch; a repo this cycle did not walk has no entry
# there and is asked nothing, which is the same "unknown decides nothing" the
# source-state digest's `ok` gives the other two classes.
register_status_json='{}'
while IFS=$'\t' read -r reg_slug reg_ids; do
  [[ -n "$reg_slug" && -n "$reg_ids" ]] || continue
  reg_branch="$(jq -r --arg s "$reg_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
    <<<"$ordered_repos_json" 2>/dev/null || true)"
  [[ -n "$reg_branch" ]] || continue
  # shellcheck disable=SC2086  # $reg_ids is a deliberate word-split id list.
  reg_map="$(gather_register_status "$reg_slug" "$reg_branch" $reg_ids)"
  register_status_json="$(jq -c --arg s "$reg_slug" --argjson m "$reg_map" '. + {($s): $m}' \
    <<<"$register_status_json" 2>/dev/null || printf '%s' "$register_status_json")"
done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
         <<<"$(work_gone_register_ids "$open_blocked_now")" 2>/dev/null || true)

# The project-review read, for the repos that have blocked project-review
# items and no others — same cost shape as the register read above.
review_status_json='{}'
while IFS=$'\t' read -r rev_slug rev_refs; do
  [[ -n "$rev_slug" && -n "$rev_refs" ]] || continue
  rev_branch="$(jq -r --arg s "$rev_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
    <<<"$ordered_repos_json" 2>/dev/null || true)"
  [[ -n "$rev_branch" ]] || continue
  # shellcheck disable=SC2086  # $rev_refs is a deliberate word-split ref list.
  rev_map="$(gather_review_status "$rev_slug" "$rev_branch" $rev_refs)"
  review_status_json="$(jq -c --arg s "$rev_slug" --argjson m "$rev_map" '. + {($s): $m}' \
    <<<"$review_status_json" 2>/dev/null || printf '%s' "$review_status_json")"
done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
         <<<"$(work_gone_review_refs "$open_blocked_now")" 2>/dev/null || true)

# The plan read, for the repos that have blocked plan-task items *and* an
# `implementation_plan_path` configured — a repo without one has nowhere for
# this to read, so it is asked nothing (the same "unknown decides nothing" as
# every other class here).
plan_status_json='{}'
while IFS=$'\t' read -r plan_slug plan_ids; do
  [[ -n "$plan_slug" && -n "$plan_ids" ]] || continue
  plan_entry="$(jq -c --arg s "$plan_slug" 'map(select(.slug == $s)) | .[0] // {}' \
    <<<"$ordered_repos_json" 2>/dev/null || echo '{}')"
  plan_branch="$(jq -r '.default_branch // ""' <<<"$plan_entry" 2>/dev/null || true)"
  plan_path="$(jq -r '.implementation_plan_path // ""' <<<"$plan_entry" 2>/dev/null || true)"
  [[ -n "$plan_branch" && -n "$plan_path" ]] || continue
  # shellcheck disable=SC2086  # $plan_ids is a deliberate word-split id list.
  plan_map="$(gather_plan_status "$plan_slug" "$plan_branch" "$plan_path" $plan_ids)"
  plan_status_json="$(jq -c --arg s "$plan_slug" --argjson m "$plan_map" '. + {($s): $m}' \
    <<<"$plan_status_json" 2>/dev/null || printf '%s' "$plan_status_json")"
done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
         <<<"$(work_gone_plan_ids "$open_blocked_now")" 2>/dev/null || true)

work_gone_json="$(work_gone_clearances "$open_blocked_now" "$source_states_json" "$register_status_json" \
                   "$review_status_json" "$plan_status_json")"
if [[ "$(jq 'length' <<<"$work_gone_json" 2>/dev/null || echo 0)" != "0" ]]; then
  log_lines_before="$(wc -l < "$log_file" 2>/dev/null || echo 0)"
  while IFS= read -r clearance; do
    [[ -n "$clearance" ]] || continue
    # `by: "work-gone"` distinguishes this from the Co-Ordinator's own
    # `unblocked` (requirement 18), the Enabler's, and the label-driven one of
    # requirement 34g; `detail` carries the fact that decided it, so a later
    # reader can audit the clearance without re-deriving it.
    log_event "unblocked" "$(jq -c '{item: .item, repo: .repo, by: "work-gone",
                                     detail: .reason}' <<<"$clearance")"
  done < <(jq -c '.[]' <<<"$work_gone_json" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
fi

blocked_json="$(blocked_items "$union_log")"
void_json="$(void_items "$union_log")"
# The third extract (requirement 3h): what a previous Enabler engagement
# specified for an item nobody had specified well enough to work on. For an
# issue the refinement is a comment and travels in the thread the Co-Ordinator
# already pastes; for every other item type this map is the only place it
# exists, and without it the refinement would be written, the item unblocked,
# and the next work order composed as if nothing had been settled.
refinements_json="$(refinements_map "$union_log")"

# --- The Enabler's eligible set (requirements 35a, 35b) ---
# Which repos' open issues this cycle can see, taken from the source-state
# digests of the repos that sampled cleanly. It is how "is that escalation issue
# still open?" gets answered without a `gh` call per escalation — the digest was
# fetched for the fingerprint anyway. A repo absent from it is one this cycle did
# not read cleanly, or did not look at (`--repo`), and its escalations are
# treated as possibly still open.
open_issues_json="$(jq -c '[.[] | select(.ok == true)
                            | {key: .slug, value: [(.issues // [])[] | .n]}]
                           | from_entries' <<<"$source_states_json" 2>/dev/null || true)"
[[ -n "$open_issues_json" ]] || open_issues_json='{}'

enabler_eligible_json="$(enabler_eligible_items "$union_log" \
  "$enabler_after_coordinator_cycles" "$enabler_recheck_hours" "$open_issues_json" \
  "" "$refinement_after_coordinator_cycles")"
# Past this line the exit trap may engage the Enabler: every input it needs now
# exists, so `maybe_run_enabler`'s own guards are all that stand between this
# cycle and an engagement. Before it, an early exit could not have one.
enabler_allowed=1

# --- 2.2a Back-pressure, decided (requirement 2.2a) ---
# Deferred from step 2.2 until the sources were gathered. Back-pressure's stated
# purpose is to throttle new work and stop the human gate silting up — and the
# three *finishing* sources do neither: `review-feedback` answers a review the
# human has already written, `merge-conflicts` rebases a ready PR the human is
# waiting to merge, and `abandoned-drafts` carries a stalled draft this system
# started to completion. All are the activity that *un*-silts the gate — indeed
# an abandoned draft is itself occupying one of the very back-pressure slots the
# cap is counting, and a conflicted PR is one the human cannot merge to free a
# slot until it is rebased. So when back-pressure trips we do not stand down if
# any has work waiting; we restrict every repo's source list to those three.
#
# No new prompt machinery is needed for that, and deliberately so: the
# Co-Ordinator is already told the runtime input's `sources` are authoritative
# over its own table (requirement 15). Narrowing the list is therefore an
# instruction it already knows how to obey, and the restriction cannot be
# reasoned around — a source it cannot see is a source it cannot select.
# The system still cannot open a new PR while the gate is full; it can only
# finish what is already in it.
if (( backpressure_tripped )); then
  finishing_waiting="$(jq '[.[].review_feedback[]?, .[].merge_conflicts[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered_repos_json")"
  if (( finishing_waiting == 0 )); then
    log_event "stand-down" "$(jq -nc \
      --arg r "back-pressure: $open_count open agent PRs >= $max_open_agent_prs ($open_composition), and no review feedback, merge conflict, or abandoned draft is waiting to be finished" \
      '{reason: $r}')"
    exit 0
  fi
  # `issues` is emptied along with the narrowing, not merely left unwalked:
  # it is the one array that carries whole threads, and a restricted cycle
  # paying the Co-Ordinator to read candidates it is forbidden to pick is the
  # exact spend back-pressure exists to stop. The other non-finishing arrays
  # are compact enough that stripping them buys nothing.
  ordered_repos_json="$(jq -c '[.[] | .sources = (.sources | map(select(. == "review-feedback" or . == "merge-conflicts" or . == "abandoned-drafts")))
                                    | .issues = []]' \
    <<<"$ordered_repos_json")"
  log_event "warning" "$(jq -nc \
    --arg d "back-pressure: $open_count open agent PRs >= $max_open_agent_prs ($open_composition) — restricted to finishing sources ($finishing_waiting PR(s) awaiting review-feedback, merge-conflict, or abandoned-draft completion)" \
    '{detail: $d}')"
fi

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
# — or a configured prompt_overrides.coordinator fragment (requirement
# 4a) — would do nothing until an unrelated commit happened to land somewhere.
#
# `repo_nice` belongs in this same object for the same reason, though what it
# guards against is the ordering feature (requirement 3, lib/repo-order.sh)
# rather than a source: repo *order* is deliberately normalised out of the
# fingerprint — `sort_by(.slug)` in lib/noop-skip.sh's canon, asserted by
# test/noop-skip.test.sh — because the walk order was never itself an input
# to what the Co-Ordinator may select, only to which candidate it reaches
# first. An edit to a repo's `nice` changes only that order, so without this
# key such an edit would move nothing: the exact silent-stall shape the rest
# of this block already describes, just reached from the ordering side
# instead of a missing source. Only non-zero entries are carried, and the key
# is omitted entirely when the map is empty — repo_nice_selection_config
# (lib/repo-order.sh) returns `{repo_nice: …}` or a bare `{}` accordingly —
# so a config with no `nice` set anywhere fingerprints byte-identical to how
# it did before this feature shipped: no fleet-wide spurious wake the day
# this lands.
repo_nice_json="$(repo_nice_selection_config "$all_repos_json")"
selection_config_json="$(jq -nc \
  --arg cm "$coordinator_model" \
  --arg md "$implementor_model_default" \
  --arg mt "$implementor_model_trivial" \
  --argjson cmax "$candidates_max" \
  --argjson nice "$repo_nice_json" \
  '{coordinator_model: $cm, models: {default: $md, trivial: $mt}, candidates_max: $cmax}
   + $nice')"
coordinator_prompt_sha="$(stage_prompt_sha "$PROMPTS_DIR" "$state_dir" coordinator "$prompt_overrides_json")"
# The repo/work-sources table prompts/coordinator.md used to hand-maintain is
# generated from config.json instead (requirement 4b), from the plain
# configured repo list (`all_repos_json`), never the cycle's back-pressure-
# restricted `ordered_repos_json` — so it always shows each repo's full
# configured priority regardless of this cycle's restrictions (see "--- 4.
# Co-Ordinator stage ---" below, which substitutes this same value into the
# prompt). Computed here, ahead of the fingerprint, and hashed verbatim:
# `ordered_repos_json`'s `sources` is *not* a substitute for it, because
# back-pressure (requirement 2.2a) narrows that array's `sources` to the three
# finishing sources for a repo with work waiting, while this table — and the
# prompt text the Co-Ordinator actually reads — still shows that repo's full
# configured list regardless. Without hashing the table itself, a config edit
# to a non-finishing source during a back-pressure cycle would change the
# assembled prompt while leaving the fingerprint's `repos[].sources`
# unchanged — the exact silent-stall shape this rule exists to prevent.
coordinator_sources_table="$(coordinator_work_sources_table "$all_repos_json")"

# The Enabler's three inputs join the fingerprint for the same reason (requirement
# 35b). Its eligible set is the third array whose candidacy turns on something no
# repo signal carries — an item becomes eligible when the fleet has run its third
# Co-Ordinator since the block, which moves no commit, issue, alert or PR — so
# without it the escalation path would come due during a quiet week and wait for
# the forced recheck to be noticed. The set empties again once the engagement's
# examined markers land, which is what lets the fleet go back to skipping.
enabler_config_json="$(jq -nc \
  --arg m "$enabler_model" \
  --arg n "$enabler_after_coordinator_cycles" \
  --arg rn "$refinement_after_coordinator_cycles" \
  --arg rh "$enabler_recheck_hours" \
  --arg lbl "$enabler_escalation_label" \
  --arg rmax "$refinement_max_per_engagement" \
  '{enabler_model: $m, after_coordinator_cycles: $n, refinement_after_coordinator_cycles: $rn,
    recheck_hours: $rh, escalation_label: $lbl, refinement_max_per_engagement: $rmax}')"
# Absent rather than fatal when the prompt is missing: a missing Enabler prompt
# is a stage that does not run (see `maybe_run_enabler`), not a cycle that dies.
# Covers a configured prompt_overrides.enabler fragment too (requirement 4a),
# the same as the Co-Ordinator's hash above.
enabler_prompt_sha=""
[[ -f "$PROMPTS_DIR/enabler.md" ]] \
  && enabler_prompt_sha="$(stage_prompt_sha "$PROMPTS_DIR" "$state_dir" enabler "$prompt_overrides_json")"

noop_input="$(jq -nc \
  --argjson repos "$ordered_repos_json" \
  --argjson states "$source_states_json" \
  --argjson blocked "$blocked_json" \
  --argjson void "$void_json" \
  --argjson refinements "$refinements_json" \
  --argjson claimed "$claimed_json" \
  --argjson eligible "$enabler_eligible_json" \
  --argjson sc "$selection_config_json" \
  --argjson ec "$enabler_config_json" \
  --arg psha "$coordinator_prompt_sha" \
  --arg esha "$enabler_prompt_sha" \
  --arg wst "$coordinator_sources_table" \
  '{
     repos: [ $repos[] as $r
              | $r + { state: ((first($states[]? | select(.slug == $r.slug))) // {ok: false}) } ],
     blocked: $blocked,
     void: $void,
     refinements: $refinements,
     claimed: $claimed,
     enabler_eligible: $eligible,
     selection_config: $sc,
     coordinator_prompt_sha: $psha,
     enabler_config: $ec,
     enabler_prompt_sha: $esha,
     coordinator_work_sources_table: $wst
   }')"
noop_fingerprint_value="$(noop_fingerprint <<<"$noop_input")"

# Computed even when the skip is bypassed, because it is also what a
# `none-selected` records for the *next* cycle to compare against. A --once run
# that finds nothing to do should still spare the following cron tick the same
# question.
noop_skip=""
if [[ -n "$noop_fingerprint_value" ]] && ! (( DRY_RUN || ONCE )); then
  noop_skip="$(noop_skip_reason "$noop_fingerprint_value" "$union_log" "$none_selected_recheck_hours")"
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
  --argjson refinements "$refinements_json" \
  --argjson claimed "$claimed_json" \
  --arg model_default "$implementor_model_default" \
  --arg model_trivial "$implementor_model_trivial" \
  --argjson cmax "$candidates_max" \
  '{repos: $repos, blocked: $blocked, void: $void, refinements: $refinements, claimed: $claimed,
    models: {default: $model_default, trivial: $model_trivial},
    candidates_max: $cmax}')"

# --- 4. Co-Ordinator stage ---
# `coordinator_sources_table` (computed above, ahead of the no-op fingerprint
# so its bytes join it) is substituted for the @@WORK_SOURCES_TABLE@@ marker
# the base prompt carries in its place.
coordinator_base_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" coordinator "$prompt_overrides_json")"
coordinator_base_prompt="${coordinator_base_prompt//@@WORK_SOURCES_TABLE@@/$coordinator_sources_table}"
coordinator_prompt="$coordinator_base_prompt

## Runtime input for this cycle

\`\`\`json
$(jq . <<<"$coordinator_input")
\`\`\`
"
coordinator_out="$cycle_dir/coordinator.out"

log_event "stage-start" '{"stage": "coordinator"}'
if run_claude_stage coordinator "$(( timeout_coordinator_min * 60 ))" "$coordinator_model" "$coordinator_prompt" "$coordinator_out" "$cycle_dir"; then
  coord_rc=0
else
  coord_rc=$?
fi
log_event "stage-end" "$(jq -nc --argjson rc "$coord_rc" --argjson m "$(metering_fields "$coordinator_model" "$coordinator_out")" \
  '{stage: "coordinator", exit_code: $rc} + $m')"
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
log_recheck_clean_items "$work_order_json"
# The repos the Co-Ordinator was given, verbatim: the void guard (requirement
# 34d) tests a verdict against the same candidates that produced it, so it can
# never refuse a void over something the Co-Ordinator could not have seen.
log_voided_items "$work_order_json" "$ordered_repos_json"
# Requirement 16a's reports, recorded after the two clearing paths above so an
# item this cycle unblocked or voided is not immediately re-blocked by a report
# in the same message.
log_needs_refinement_items "$work_order_json"

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

# --- 5b. Candidates, and the claim (requirement 17a) ---
# The Co-Ordinator returns a ranked candidate list; the former single-selection
# shape is accepted for one release as a one-candidate list. The claim itself
# is taken by the Script, never the model: keys are derived deterministically
# (two nodes must compute the same name for the same item), the write is
# create-only so GitHub arbitrates the race, and a lost race just moves down
# the ranking instead of costing the cycle.
if jq -e '.candidates | type == "array"' <<<"$work_order_json" >/dev/null 2>&1; then
  candidates_json="$(jq -c '.candidates' <<<"$work_order_json")"
else
  candidates_json="$(jq -c '[del(.selected, .unblocked, .recheck_clean, .voided)]' <<<"$work_order_json")"
fi

if (( DRY_RUN )); then
  # A dry run claims nothing: record the top of the ranking and stop.
  log_event "selection" "$(jq -c '.[0] | {repo, item, source, model, title}' <<<"$candidates_json")"
  exit 0
fi

claimed_json=""
n_cand="$(jq 'length' <<<"$candidates_json")"
claim_attempts=0
claim_unreachable=0
for (( ci = 0; ci < n_cand; ci++ )); do
  cand="$(jq -c --argjson i "$ci" '.[$i]' <<<"$candidates_json")"
  c_repo="$(jq -r '.repo // ""' <<<"$cand")"
  c_item="$(jq -r '.item // ""' <<<"$cand")"
  c_source="$(jq -r '.source // ""' <<<"$cand")"
  c_db="$(jq -r '.default_branch // "main"' <<<"$cand")"
  [[ -n "$c_repo" && -n "$c_item" ]] || continue
  claim_attempts=$(( claim_attempts + 1 ))
  claim_rc=0
  if [[ "$c_source" == "review-feedback" || "$c_source" == "abandoned-drafts" || "$c_source" == "merge-conflicts" ]]; then
    # No new branch to create — the PR already exists (a human's review round for
    # review-feedback, this system's own stalled draft for abandoned-drafts, a
    # ready-but-conflicted PR of ours for merge-conflicts). The lock is a
    # create-only registry file keyed on the item ref, not a branch create that
    # would 422 against the branch already there.
    claim_kind="file"; claim_key="$c_item"
    c_branch="$(jq -r '.branch // ""' <<<"$cand")"
    CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$c_item" CLAIM_SOURCE="$c_source" \
      "$SCRIPT_DIR/lib/claim.sh" claim file "$c_repo" "$c_item" \
      >>"$cycle_dir/claim.log" 2>&1 || claim_rc=$?
  else
    c_branch="$(claim_branch_for "$c_source" "$c_item")"
    claim_kind="branch"; claim_key="$c_branch"
    CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$c_item" CLAIM_SOURCE="$c_source" \
      "$SCRIPT_DIR/lib/claim.sh" claim branch "$c_repo" "$c_branch" "$c_db" \
      >>"$cycle_dir/claim.log" 2>&1 || claim_rc=$?
  fi
  if (( claim_rc == 0 )); then
    claim_active=1
    claimed_json="$(jq -c --arg b "$c_branch" '. + {branch: $b}' <<<"$cand")"
    break
  fi
  # 3 = a peer holds it (healthy contention: the work is being done, just not
  # by this node) — 1 = GitHub was unreachable (fail-closed: this node could
  # not have pushed the work either, but no work is being done by anyone).
  # Opposite operational conditions, so `cause` tells them apart instead of
  # the event wearing one reason for both.
  case "$claim_rc" in
    3) claim_cause="held" ;;
    1) claim_cause="unreachable"; claim_unreachable=$(( claim_unreachable + 1 )) ;;
    *) claim_cause="$claim_rc" ;;
  esac
  log_event "claim-lost" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg b "$c_branch" \
    --argjson rc "$claim_rc" --arg cause "$claim_cause" \
    '{repo: $r, item: $i, branch: $b, rc: $rc, cause: $cause}')"
done

if [[ -z "$claimed_json" ]]; then
  if (( claim_attempts > 0 && claim_unreachable == claim_attempts )); then
    standdown_reason="GitHub could not be reached for any candidate — this is an outage, not contention"
  else
    standdown_reason="every candidate is already claimed elsewhere"
  fi
  log_event "stand-down" "$(jq -nc --argjson n "$n_cand" --arg r "$standdown_reason" \
    '{reason: $r, candidates: $n}')"
  exit 0
fi

work_order_json="$claimed_json"
selected_repo="$(jq -r '.repo // ""' <<<"$work_order_json")"
selected_item="$(jq -r '.item // ""' <<<"$work_order_json")"
selected_branch="$(jq -r '.branch // ""' <<<"$work_order_json")"
log_event "selection" "$(jq -c '{repo, item, source, model, title, branch}' <<<"$work_order_json")"

# --- 6. Workspace ---
repo_slug="$(jq -r '.repo' <<<"$work_order_json")"
impl_model="$(jq -r '.model' <<<"$work_order_json")"

clone_dir="$workspace_root/$cycle_id"
assert_in_workspace "$clone_dir"
if ! gh repo clone "$repo_slug" "$clone_dir" -- --quiet 2>"$cycle_dir/clone.err"; then
  log_event "attempt-failed" "$(jq -nc --arg d "$(cat "$cycle_dir/clone.err")" '{stage: "workspace", detail: $d}')"
  # The claim was taken before the clone; a cycle that ends here must not
  # keep holding the item (requirement 17a's release rules).
  release_claim no-pr
  exit 0
fi

# --- 7. Implementor stage ---
implementor_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" implementor "$prompt_overrides_json")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`
"
impl_out="$cycle_dir/implementor.out"

log_event "stage-start" '{"stage": "implementor"}'
if run_claude_stage implementor "$(( timeout_implementor_min * 60 ))" "$impl_model" "$implementor_prompt" "$impl_out" "$clone_dir"; then
  impl_rc=0
else
  impl_rc=$?
fi
log_event "stage-end" "$(jq -nc --argjson rc "$impl_rc" --argjson m "$(metering_fields "$impl_model" "$impl_out")" \
  '{stage: "implementor", exit_code: $rc} + $m')"
(( ONCE )) && dump_stage_output "$impl_out"

impl_result="$(jq -r '.result // empty' "$impl_out" 2>/dev/null || true)"
impl_status_json="$(extract_json_result "$impl_result" 2>/dev/null || true)"
# Requirement 9's fallback chain, cheapest first and least dependent on the
# stage last. The first three all read something the Implementor had to do:
# report the URL, print it where it could be grepped, write the breadcrumb.
# That is fine for the failures they were written for and useless for the one
# that matters most — a stage that emitted no parseable final message is a
# stage that may have skipped every step after opening the PR — so the chain
# ends by asking GitHub about the branch the Script itself pushed, which needs
# nothing from the model at all. Not free (one API call), so it runs last and
# only when the item is otherwise unnameable.
#
# This one variable is the whole downstream supply: `pr-raised`, the Reviewer
# stage, the Reviewer's hand-back, the `blocked`/`void` verdict paths and both
# `handle_stage_failure` calls read it, so the fallback belongs here rather
# than in any of them (requirement 34a).
impl_pr_url="$(jq -r '.pr_url // empty' <<<"$impl_status_json" 2>/dev/null || true)"
[[ -z "$impl_pr_url" ]] && impl_pr_url="$(extract_pr_url "$impl_out")"
[[ -z "$impl_pr_url" ]] && impl_pr_url="$(read_pr_url_breadcrumb "$clone_dir")"
[[ -z "$impl_pr_url" ]] && impl_pr_url="$(pr_url_for_branch "$selected_repo" "$selected_branch")"

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
  # A void item has no work, so its claim must not outlive the verdict — the
  # branch (if untouched) and the registry entry both go.
  release_claim no-pr
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
    "$(jq -c --arg u "$impl_pr_url" \
       '{unblock_condition: (.unblock_condition // "")}
        + (if $u == "" then {} else {pr_url: $u} end)' <<<"$impl_status_json")"
  if [[ -n "$impl_pr_url" ]]; then
    gh pr comment "$impl_pr_url" --body "Autonomous agent (implementor) stopped on this PR: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json") Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed.

$(pipeline_comment_marker "$cycle_id")" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
  exit 0
fi

if (( impl_rc != 0 )) || [[ -z "$impl_status_json" ]] || [[ "$impl_status" != "complete" ]]; then
  handle_stage_failure "implementor" "$impl_rc" "$impl_out" "$impl_pr_url"
  exit 0
fi

if [[ -n "$impl_pr_url" ]]; then
  log_event "pr-raised" "$(jq -nc --arg u "$impl_pr_url" --arg r "$repo_slug" '{pr_url: $u, repo: $r}')"
  # The open PR is now the visible claim; the registry entry has done its job
  # (and back-pressure counts the PR from here on, not the claim).
  release_claim have-pr
fi

# --- 8. Reviewer stage ---
# Requirement 8a: the reviewer tier follows the item's complexity — the
# highest of the Implementor's ex-post grade (its summary's `complexity`) and
# the PR's raise-never-lower `complexity:*` label, falling back to the
# Co-Ordinator's own classification when neither says anything: a
# trivial-tier work order needs no self-grade to be `low`. The label read is
# best-effort; an unreadable label contributes nothing and the choice
# degrades to the default tier.
impl_complexity="$(jq -r '.complexity // empty' <<<"$impl_status_json" 2>/dev/null || true)"
label_grades=()
if [[ -n "$impl_pr_url" ]]; then
  mapfile -t label_grades < <(gh pr view "$impl_pr_url" --json labels \
    --jq '.labels[].name | select(startswith("complexity:")) | sub("^complexity:"; "")' 2>/dev/null || true)
fi
impl_trivial=0
[[ "$impl_model" == "$implementor_model_trivial" ]] && impl_trivial=1
rev_complexity="$(reviewer_complexity "$impl_complexity" "$impl_trivial" ${label_grades[@]+"${label_grades[@]}"})"
rev_model="$reviewer_model_default"
[[ "$rev_complexity" == "high" ]] && rev_model="$reviewer_model_complex"

reviewer_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" reviewer "$prompt_overrides_json")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`

## Implementor summary

\`\`\`json
$(jq . <<<"$impl_status_json")
\`\`\`

## Cycle

$cycle_id
"
rev_out="$cycle_dir/reviewer.out"

log_event "stage-start" "$(jq -nc --arg c "$rev_complexity" --arg m "$rev_model" \
  '{stage: "reviewer", complexity: $c, model: $m}')"
if run_claude_stage reviewer "$(( timeout_reviewer_min * 60 ))" "$rev_model" "$reviewer_prompt" "$rev_out" "$clone_dir"; then
  rev_rc=0
else
  rev_rc=$?
fi
log_event "stage-end" "$(jq -nc --argjson rc "$rev_rc" --argjson m "$(metering_fields "$rev_model" "$rev_out")" \
  '{stage: "reviewer", exit_code: $rc} + $m')"
(( ONCE )) && dump_stage_output "$rev_out"

rev_result="$(jq -r '.result // empty' "$rev_out" 2>/dev/null || true)"
rev_status_json="$(extract_json_result "$rev_result" 2>/dev/null || true)"

if (( rev_rc != 0 )) || [[ -z "$rev_status_json" ]]; then
  handle_stage_failure "reviewer" "$rev_rc" "$rev_out" "$impl_pr_url"
  exit 0
fi

rev_status="$(jq -r '.status // empty' <<<"$rev_status_json")"
if [[ "$rev_status" == "ready" ]]; then
  # Requirement 31a: the verdict is the Reviewer's — it is the only actor that
  # read the diff — but the handoff is a fact about the PR, and asking GitHub
  # costs one field. `pr-ready` now means the PR is not a draft, not that
  # somebody said so; `handoff` records which of them made it true.
  handoff_result="$(confirm_pr_ready "$impl_pr_url")" || true
  case "$handoff_result" in
    already)
      handoff_by="reviewer"
      ;;
    flipped)
      handoff_by="script"
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" \
        --arg d "reviewer reported ready but left $impl_pr_url a draft; the Script completed the handoff" \
        '{detail: $d, pr_url: $u}')"
      ;;
    *)
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url is still a draft and the handoff could not be completed" \
        "$impl_pr_url" "Confirm the pull request is out of draft with CI green."
      exit 0
      ;;
  esac

  # Requirement 31b: the draft flip above is the whole handoff exactly once per
  # pull request. On every later round — a review the Implementor has just
  # answered, most of all — the PR never left ready, `confirm_pr_ready`
  # truthfully answers `already`, and nothing has put the PR back in front of
  # the human: their review request was consumed when they submitted the review,
  # and the author cannot clear `CHANGES_REQUESTED`. So the second half of the
  # handoff is asked of GitHub too, on the same terms and for the same reason
  # requirement 31a asks about the draft flag.
  #
  # Unconditional, not gated on `source == "review-feedback"`: the question
  # ("does a human's review block this PR, and have they been asked to look
  # again?") is answerable from the PR itself, costs one API call to answer `no`
  # on a first-round PR, and gating it on the Co-Ordinator's classification
  # would make a mislabelled source a silently unnotified human.
  #
  # Both `|| true`s are the shape every `confirm_*` call site carries: this runs
  # under `errexit` at the point the cycle reports its outcome, and a non-zero
  # return escaping from either the check or the `read` that splits its answer
  # would abort the cycle exactly where it is recording what it did.
  rereview_result="$(confirm_review_requested "$impl_pr_url")" || true
  rereview_state=""; rereview_who=""
  IFS=$'\t' read -r rereview_state rereview_who <<<"$rereview_result" || true
  if [[ "$rereview_state" == "failed" ]]; then
    # A warning, never a handback: the pull request is finished, green and
    # visible, and only the notification is missing (see lib/handoff.sh).
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg w "$rereview_who" \
      --arg d "changes requested on $impl_pr_url are answered, but review could not be re-requested from ${rereview_who:-the reviewer} — they will not see it in their review queue" \
      '{detail: $d, pr_url: $u} + (if $w == "" then {} else {reviewers: ($w | split(","))} end)')"
  fi
  log_event "pr-ready" "$(jq -nc --arg u "$impl_pr_url" --arg h "$handoff_by" \
    --arg rr "$rereview_state" --arg w "$rereview_who" \
    '{pr_url: $u, handoff: $h}
     + (if $rr == "" or $rr == "none" then {} else {review_requested: $rr} end)
     + (if $w == "" then {} else {reviewers: ($w | split(","))} end)')"
else
  # Requirement 32a: a Reviewer that cannot hand off hands *back*, not out. The
  # verdict names a real impediment on a real PR, which is a blocked item —
  # the Enabler's input — and never, by itself, a summons to a human.
  log_reviewer_handback \
    "reviewer verdict '${rev_status:-unparseable}': $(jq -r '.reason // .ci // "no detail given"' <<<"$rev_status_json")" \
    "$impl_pr_url" "Resolve what the Reviewer left on the pull request, or escalate it."
fi

echo "$impl_pr_url"
