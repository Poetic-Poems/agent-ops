#!/usr/bin/env bash
#
# agent-cycle.sh — orchestrates one cycle of the autonomous agent pipeline.
# Full specification: docs/IMPLEMENTATION-PIPELINE-SPEC.md. Config: config.json.

set -euo pipefail

# Captured before the flag loop below consumes it with `shift`: finish-then-
# continue (requirement 39) re-launches this same script with the same
# arguments a chained cycle later, and by then "$@" is long gone.
ORIGINAL_ARGV=("$@")

# --- PATH: cron's environment is minimal; make sure claude, gh, git, jq resolve. ---
# Appended, not prepended: an already-resolvable PATH entry — a caller's own
# shim, e.g. test/toggle.test.sh's offline-e2e stub_bin — must win over these
# fallbacks, or a subprocess of this script (the 2.1b usage-limit probe is the
# one that actually does this) silently reaches a real `claude`/`gh` instead
# of the stub standing in for them (TD-PPagop-26080701).
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

for bin in claude gh git jq sha256sum; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "agent-cycle: required binary not found on PATH: $bin" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
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
# GitHub's rate limits, which are a different system from the Claude usage
# limits above. Sourcing this also wraps every `gh` call this script makes —
# see the wrapper's header for what that does and does not cover.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/repo-clone.sh
. "$SCRIPT_DIR/lib/repo-clone.sh"
# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/report-directory.sh
# REPORT_DIRECTORY_DEFAULT (the review pipeline's own ultimate report_directory
# fallback, issue #761): lib/eligibility.sh's prefetch_refiner_sources reads it
# for a repository project_review does not configure at all.
. "$SCRIPT_DIR/lib/report-directory.sh"
# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"
# shellcheck source=lib/rework.sh
. "$SCRIPT_DIR/lib/rework.sh"
# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"
# shellcheck source=lib/stage-budget.sh
. "$SCRIPT_DIR/lib/stage-budget.sh"
# shellcheck source=lib/stage-attempt.sh
# Sourced after stage-run.sh (run_claude_stage) and stage-budget.sh
# (stage_budget_apply), both of which run_coordinator_stage_attempt calls.
. "$SCRIPT_DIR/lib/stage-attempt.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/candidate-select.sh
. "$SCRIPT_DIR/lib/candidate-select.sh"
# shellcheck source=lib/expensive-gather-cache.sh
# Ahead of candidate-gather.sh, which is its only caller (requirement 48).
. "$SCRIPT_DIR/lib/expensive-gather-cache.sh"
# shellcheck source=lib/candidate-gather.sh
. "$SCRIPT_DIR/lib/candidate-gather.sh"
# shellcheck source=lib/eligibility.sh
# After candidate-gather.sh: its four functions run on what gather_ordered_repos
# and compute_skip_lists leave behind, and a reader following the phase order
# should meet them in that order too.
. "$SCRIPT_DIR/lib/eligibility.sh"
# shellcheck source=lib/standdown.sh
# Sourced last among these: run_standdown_checks calls into most of the libs
# above (crash-loop, github-limit, toggle, merge-autonomy, approver-token, …),
# and a function call resolves at run time regardless of source order — this
# position is for a reader, not the interpreter.
. "$SCRIPT_DIR/lib/standdown.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/merge-budget.sh
. "$SCRIPT_DIR/lib/merge-budget.sh"
# shellcheck source=lib/merge-autonomy.sh
. "$SCRIPT_DIR/lib/merge-autonomy.sh"
# shellcheck source=lib/github-app-token.sh
. "$SCRIPT_DIR/lib/github-app-token.sh"
# shellcheck source=lib/approver-token.sh
. "$SCRIPT_DIR/lib/approver-token.sh"
# shellcheck source=lib/approver.sh
. "$SCRIPT_DIR/lib/approver.sh"
# shellcheck source=lib/author-token.sh
. "$SCRIPT_DIR/lib/author-token.sh"
# shellcheck source=lib/forge-auth.sh
# Depends on lib/author-token.sh above; called from run_standdown_checks
# (lib/standdown.sh), ahead of every check that authenticates as this cycle.
. "$SCRIPT_DIR/lib/forge-auth.sh"
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/landing.sh
# Sourced after merge-queue.sh (landing_arm's own queue-detection read) and
# github-limit.sh (github_pr_list_truncated, sourced above already).
. "$SCRIPT_DIR/lib/landing.sh"
# shellcheck source=lib/noop-skip.sh
. "$SCRIPT_DIR/lib/noop-skip.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/manage.sh
# Sourced after toggle.sh, limit-detect.sh, fleet.sh and merge-autonomy.sh —
# the four its own --status reports are built from; like standdown.sh above,
# the position is for a reader, since run_manage_command resolves at run time
# regardless of source order.
. "$SCRIPT_DIR/lib/manage.sh"
# shellcheck source=lib/crash-loop.sh
. "$SCRIPT_DIR/lib/crash-loop.sh"
# shellcheck source=lib/token-expiry.sh
. "$SCRIPT_DIR/lib/token-expiry.sh"
# shellcheck source=lib/stage-health.sh
. "$SCRIPT_DIR/lib/stage-health.sh"
# shellcheck source=lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"
# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"
# shellcheck source=lib/git-identity.sh
. "$SCRIPT_DIR/lib/git-identity.sh"
# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"
# shellcheck source=lib/review-gate.sh
. "$SCRIPT_DIR/lib/review-gate.sh"
# shellcheck source=lib/closing-keyword-gate.sh
. "$SCRIPT_DIR/lib/closing-keyword-gate.sh"
# shellcheck source=lib/reconciliation-gate.sh
. "$SCRIPT_DIR/lib/reconciliation-gate.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/unvoid-label.sh
. "$SCRIPT_DIR/lib/unvoid-label.sh"
# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/lib/work-gone.sh"
# shellcheck source=lib/void-liveness.sh
. "$SCRIPT_DIR/lib/void-liveness.sh"
# shellcheck source=lib/human-visibility-hygiene.sh
. "$SCRIPT_DIR/lib/human-visibility-hygiene.sh"
# shellcheck source=lib/preflight.sh
# Sourced after work-gone.sh, whose work_gone_clearances it wraps.
. "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
# shellcheck source=lib/refinement.sh
# Sourced after void-guard.sh, which defines the `entry_field_text` it uses.
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/enabler.sh
. "$SCRIPT_DIR/lib/enabler.sh"
# shellcheck source=lib/escalation-autonomy.sh
. "$SCRIPT_DIR/lib/escalation-autonomy.sh"
# shellcheck source=lib/issue-priority.sh
. "$SCRIPT_DIR/lib/issue-priority.sh"
# shellcheck source=lib/tech-debt-file.sh
. "$SCRIPT_DIR/lib/tech-debt-file.sh"
# shellcheck source=lib/merge-observed.sh
# Sourced after handoff.sh (whose pr_merge_state it wraps), candidate-select.sh
# (release_pr_claim) and tech-debt-file.sh (techdebt_file_debt/_issue), all of
# which reviewer_merge_observed calls.
. "$SCRIPT_DIR/lib/merge-observed.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"
# shellcheck source=lib/prompt-overrides.sh
. "$SCRIPT_DIR/lib/prompt-overrides.sh"
# shellcheck source=lib/coordinator-brief.sh
. "$SCRIPT_DIR/lib/coordinator-brief.sh"
# shellcheck source=lib/coordinator-input.sh
. "$SCRIPT_DIR/lib/coordinator-input.sh"
# shellcheck source=lib/repo-order.sh
. "$SCRIPT_DIR/lib/repo-order.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/chain.sh
. "$SCRIPT_DIR/lib/chain.sh"
# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/image-drift.sh
. "$SCRIPT_DIR/lib/image-drift.sh"

# lib/refinement.sh's self-heal hook (requirement 6a, agent-ops#687), installed
# here because this is the one file that sources both it and lib/labels.sh: a
# label projection whose add failed retries once through this, and without it
# `refinement_label_add` has nothing to retry through and the self-heal never
# happens at all. Here rather than beside the projections themselves so it is
# in place before `cleanup`'s trap can run the Refiner — that path projects
# `refined_label` on every ending of the cycle, including one that exits before
# the gather loop's own ensure has run.
#
# The catalogue lookup is what makes a label created this way indistinguishable
# from one the eager per-gathered-repository ensure would have made; a name the
# `target` catalogue does not carry falls through to labels_ensure_one's own
# neutral defaults rather than not being created.
refinement_label_ensure_one() {
  local repo="$1" name="$2" c_name c_colour c_description
  while IFS=$'\t' read -r c_name c_colour c_description; do
    [[ "$c_name" == "$name" ]] || continue
    labels_ensure_one "$repo" "$name" "$c_colour" "$c_description" >/dev/null
    return $?
  done < <(labels_catalogue "$CONFIG_FILE" "$SCHEMA_FILE" target)
  labels_ensure_one "$repo" "$name" >/dev/null
}
REFINEMENT_LABEL_ENSURE=refinement_label_ensure_one

usage() {
  cat <<'EOF'
usage: agent-cycle.sh [--dry-run] [--once] [--repo <slug>]
       agent-cycle.sh --disable [<reason>] [--for <90m|4h|2d|forever>] [--until <timestamp>] [--this-node]
       agent-cycle.sh --enable [--this-node]
       agent-cycle.sh --clear-limit [<reason>]
       agent-cycle.sh --kill-merge-autonomy [<reason>]
       agent-cycle.sh --restore-merge-autonomy
       agent-cycle.sh --status

Run one cycle of the autonomous agent pipeline, or manage the switch that
stops cycles from starting (shared with review-cycle.sh).

  --dry-run          Select an item and print the work order; implement nothing.
  --once             One verbose cycle in the foreground.
  --repo <slug>      Restrict selection to one configured repo (testing).
  --disable [reason] Stop future cycles starting. A reason is required — the
                     next person to wonder why nothing is happening is entitled
                     to one. Expires after `disable_default_ttl` unless --for
                     or --until says otherwise.
  --for <duration>   How long --disable lasts: 90m, 4h, 2d, or `forever`.
  --until <timestamp> When --disable lasts until: a GNU `date`-compatible
                     absolute timestamp (e.g. '2026-08-10 18:00', 'tomorrow
                     12:00'), an alternative to --for. With both given, the
                     later of the two deadlines wins and a warning is issued.
  --enable           Clear the switch and let cycles run again.
  --this-node        Modifies --disable or --enable to act on this node alone,
                     never on the fleet switch: `--disable --this-node` writes
                     only this node's own record, and `--enable --this-node`
                     clears only that record, leaving `fleet/disabled.json`
                     untouched either way. Stands this one node down without a
                     container recreate — the rest of the fleet keeps working.
                     Combining it with anything but --disable or --enable is
                     an error. An unmodified --disable also writes a local
                     record, but tags it `scope: "fleet"` to mark it a mirror
                     of the fleet switch rather than a node-scoped stand-down;
                     --enable --this-node refuses to clear one of those, since
                     plain --enable is what undoes a fleet-wide disable.
  --clear-limit      Lift a usage-limit stand-down across the fleet (2.1). Use
                     it once the limit is actually gone — you raised the cap,
                     or the plan rolled over. Unlike --enable this touches no
                     switch: it clears fleet/limit.json and logs a
                     `limit-cleared` event that supersedes the cooldown.
  --kill-merge-autonomy [reason]
                     Force every repo's effective `merge_autonomy` to `human`
                     fleet-wide, immediately, regardless of config.json or any
                     per-repo override — the D18 kill switch (docs/reviews/
                     2026-08-14-autonomy-investigation.md §6). A reason is
                     required, on the same terms as --disable. Reuses the
                     fleet-flag mechanism --disable/--enable share
                     (fleet/merge-autonomy-kill.json) but stops nothing else:
                     cycles keep running normally, only approval and landing
                     are forced back to human.
  --restore-merge-autonomy
                     Clear the kill switch and let each repo's configured
                     `merge_autonomy` level — and any per-repo override —
                     govern again.
  --status           Report the switch — distinguishing a node-scoped disable,
                     a fleet disable, or both, and what clearing each leaves —
                     any usage-limit stand-down, the merge-autonomy kill
                     switch, and whether either pipeline is running.
  --help             Display this help and exit.

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
DISABLE_UNTIL=""
CLEAR_LIMIT_REASON=""
KILL_MERGE_AUTONOMY_REASON=""
THIS_NODE=0
set_manage_action() {
  if [[ -n "$MANAGE_ACTION" ]]; then
    echo "agent-cycle: --disable, --enable, --clear-limit, --kill-merge-autonomy, --restore-merge-autonomy and --status are mutually exclusive" >&2
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
    --kill-merge-autonomy)
      set_manage_action kill-merge-autonomy; shift
      # A reason is required, same as --disable's — the next person to
      # wonder why every repo is stuck at human is entitled to one.
      if [[ $# -gt 0 && "$1" != --* ]]; then KILL_MERGE_AUTONOMY_REASON="$1"; shift; fi
      ;;
    --restore-merge-autonomy) set_manage_action restore-merge-autonomy; shift ;;
    --status) set_manage_action status; shift ;;
    --for) DISABLE_FOR="${2:-}"; shift 2 ;;
    --until) DISABLE_UNTIL="${2:-}"; shift 2 ;;
    --this-node) THIS_NODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "agent-cycle: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ -n "$MANAGE_ACTION" ]]; then
  if (( DRY_RUN || ONCE )) || [[ -n "$REPO_FILTER" ]]; then
    echo "agent-cycle: --disable/--enable/--clear-limit/--kill-merge-autonomy/--restore-merge-autonomy/--status manage stand-down state; they do not run a cycle" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" != "disable" ]] && [[ -n "$DISABLE_FOR" || -n "$DISABLE_UNTIL" ]]; then
    echo "agent-cycle: --for and --until only apply to --disable" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" == "disable" && -z "$DISABLE_REASON" ]]; then
    echo "agent-cycle: --disable needs a reason, e.g. --disable 'editing lib/cycle-state.sh'" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" == "kill-merge-autonomy" && -z "$KILL_MERGE_AUTONOMY_REASON" ]]; then
    echo "agent-cycle: --kill-merge-autonomy needs a reason, e.g. --kill-merge-autonomy 'Approver App misbehaving'" >&2
    exit 64
  fi
fi
if (( THIS_NODE )) && [[ "$MANAGE_ACTION" != "disable" && "$MANAGE_ACTION" != "enable" ]]; then
  echo "agent-cycle: --this-node only modifies --disable or --enable" >&2
  exit 64
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
# The schema gate (requirement 1b): config.schema.json is the single
# statement of config.json's shape, validated here, before any individual key
# is read from it — the same fail-fast position requirement 1a's model-id
# resolution occupies below, and well before the lock. One error per run
# names every offending path at once, so a five-key typo costs one cycle to
# fix, not five.
schema_errors="$(config_schema_errors "$CONFIG_FILE" "$SCHEMA_FILE")" && schema_status=0 || schema_status=$?
if ((schema_status == 2)); then
  echo "agent-cycle: $schema_errors" >&2
  exit 1
elif ((schema_status == 1)); then
  echo "agent-cycle: config.json does not match config.schema.json:" >&2
  while IFS= read -r line; do echo "agent-cycle:   $line" >&2; done <<<"$schema_errors"
  exit 1
fi

# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below, with no `// literal` of its own to drift from the schema's.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }
cfg_json() { jq -c "$1" <<<"$DEFAULTED_CONFIG"; }

state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
# Exported, not merely a local, so every subprocess this cycle forks from
# here on — a `scripts/gather-*`/`scripts/sweep-*` call and, crucially, each
# `claude -p` stage — inherits it: the `gh` transport shim (requirement
# 2.0e, agent-ops#1084) reads this to find state_dir/gh-shim/ from wherever
# it is invoked, including a model-driven `gh …` call this process never sees
# directly.
export PW_GH_STATE_DIR="$state_dir"
coordinator_model="$(resolve_model_id coordinator_model "$(cfg '.coordinator_model')")"
implementer_model_default="$(resolve_model_id implementer_model_default "$(cfg '.implementer_model_default')")"
implementer_model_trivial="$(resolve_model_id implementer_model_trivial "$(cfg '.implementer_model_trivial')")"
reviewer_model_default="$(resolve_model_id reviewer_model_default "$(cfg '.reviewer_model_default')")"
# The complexity escalation (requirement 8a): a PR graded `complexity:high` is
# reviewed on this tier. Empty falls back to the default tier, which switches
# the escalation off.
reviewer_model_complex="$(cfg '.reviewer_model_complex')"
[[ -n "$reviewer_model_complex" ]] || reviewer_model_complex="$reviewer_model_default"
reviewer_model_complex="$(resolve_model_id reviewer_model_complex "$reviewer_model_complex")"
# The Approver (requirement 8b, D18 WI-5). Three tiers on the same
# empty-falls-back-to-the-tier-below chain `reviewer_model_complex` already
# uses, extended one step further for adjudication — `resolve_model_id`
# passes an empty value through unchanged, so `approver_model_default` empty
# stays empty here and disables the whole stage further down (requirement 8b).
approver_model_default="$(resolve_model_id approver_model_default "$(cfg '.approver_model_default')")"
approver_model_complex="$(cfg '.approver_model_complex')"
[[ -n "$approver_model_complex" ]] || approver_model_complex="$approver_model_default"
approver_model_complex="$(resolve_model_id approver_model_complex "$approver_model_complex")"
approver_model_critical="$(cfg '.approver_model_critical')"
[[ -n "$approver_model_critical" ]] || approver_model_critical="$approver_model_complex"
approver_model_critical="$(resolve_model_id approver_model_critical "$approver_model_critical")"
# The restale sweep's own no-progress escalation threshold (requirement 46,
# agent-ops#682) — how long a rebase-only-stale Approver review is retried
# before it is handed to a human instead.
approver_restale_escalate_after_hours="$(cfg '.approver_restale_escalate_after_hours')"
# The Enabler (requirements 35–37). Its model is the most expensive this system
# runs, which is affordable only because the eligibility rule engages it rarely:
# an empty `enabler_model` disables the stage outright.
enabler_model="$(resolve_model_id enabler_model "$(cfg '.enabler_model')")"
# The Enabler's own critical tier (D18 §6, agent-ops#936): both bounded
# passes below `escalate` — `adjudicate-first`'s adjudication and
# `decide-tactical`'s decide — run at this model, on the same
# empty-falls-back-to-the-tier-below pattern `approver_model_critical` uses
# above, rather than at `enabler_model` itself: the Enabler has no second
# tier the way the Approver's three-tier chain does, so this is that tier's
# first appearance.
enabler_model_critical="$(cfg '.enabler_model_critical')"
[[ -n "$enabler_model_critical" ]] || enabler_model_critical="$enabler_model"
enabler_model_critical="$(resolve_model_id enabler_model_critical "$enabler_model_critical")"
enabler_after_coordinator_cycles="$(cfg '.enabler_after_coordinator_cycles')"
# A refinement block (requirements 34e, 35a) ages on its own threshold,
# because unlike an ordinary block it waits on the Enabler and nothing else —
# a human refining the item first, or the Co-Ordinator's cheap re-check
# noticing the condition already cleared. Left unconfigured it inherits
# enabler_after_coordinator_cycles' value, which preserves the shared
# threshold this class had before the two were split apart (TD-PPagop-26072604).
# This inheritance is cross-key, not a schema default (config.schema.json has
# none for this key), so it stays a runtime fallback rather than moving into
# config_defaults.
refinement_after_coordinator_cycles="$(cfg '.refinement_after_coordinator_cycles')"
[[ -n "$refinement_after_coordinator_cycles" && "$refinement_after_coordinator_cycles" != "null" ]] \
  || refinement_after_coordinator_cycles="$enabler_after_coordinator_cycles"
enabler_recheck_hours="$(cfg '.enabler_recheck_hours')"
labels_ensure_interval_hours="$(cfg '.labels_ensure_interval_hours')"
enabler_escalation_label="$(cfg '.enabler_escalation_label')"
# The assignment is what does the work — it both puts the issue in front of the
# human configured to receive them and excludes it from the `issues` source
# (requirement 16.4), so an escalation can never be selected as work by the
# very pipeline that raised it. That second property depends on the assignee
# actually being set, so an enabled Enabler with no assignee configured is a
# fatal misconfiguration, not a silent skip: an unassigned escalation is one
# the pipeline could go on to pick up as its own work.
enabler_assignee="$(cfg '.enabler_assignee')"
# Crash-loop escalation (requirement 2.7). `crash_loop_after` is the
# consecutive-failure threshold; 0 or absent turns the check off, so an
# older config runs exactly as before. `crash_loop_repo` is where the
# escalation issue is filed — the pipeline's own repository, because a
# Co-Ordinator that cannot run belongs to no target repo's backlog.
crash_loop_after="$(cfg '.crash_loop_after')"
[[ "$crash_loop_after" =~ ^[0-9]+$ ]] || crash_loop_after=0
crash_loop_repo="$(cfg '.crash_loop_repo')"
# Deferred crash-loop escalations this cycle's step-1b block could not file
# safely (agent-ops#1074): populated by `crash_loop_escalate_or_defer`,
# drained by `crash_loop_refile_pending` from `cleanup()`, once this cycle's
# own Co-Ordinator attempt (if any) has had its chance to prove the run over.
crash_loop_pending_refile=()
# The out-of-band fallback create_escalation_issue POSTs to when it cannot
# file (requirement 2m, TD-PPagop-26082304) — fleet-wide like every other key
# in config.json, which ships in the image, and credential-independent of
# GH_TOKEN by construction. Empty (the default) means this installation has
# none configured, and escalation_webhook_notify is a no-op throughout the
# cycle. A set value is still inert on a node whose EGRESS_EXTRA_ALLOW does
# not name the webhook's host: the POST leaves through the same default-deny
# egress fence every other outbound call does (D24).
escalation_webhook_url="$(cfg '.escalation_webhook_url')"
# TD-PPagop-26081404: how many consecutive times, on this one node, the
# required-checks read at the ready-gate (requirement 31c) must come back
# `unknown` before its per-item node-level `warning` is replaced by one
# louder escalation event naming the streak — see the ready-gate block below
# and `review_gate_unknown_streak_verdict` (lib/review-gate.sh). Deliberately
# not `crash_loop_after`: that threshold governs a different escalation
# (fleet-wide, issue-filing) with its own semantics, and reusing its config
# key would let a tuning change for one silently retune the other. A fixed
# constant rather than its own config key, since the fix this exists for is
# "notice a repeating pattern sooner", not something an installation needs to
# tune per repo.
review_gate_unknown_streak_after=3
if ! config_enabler_assignee_ok "$enabler_model" "$enabler_assignee"; then
  echo "agent-cycle: enabler_model is set but enabler_assignee is not configured — refusing to run with an unassigned escalation target; set enabler_assignee in config.json or clear enabler_model to disable the Enabler" >&2
  exit 1
fi
# The label a human applies on GitHub to ask for a void to be reopened
# (requirement 34f). Only a human can apply it — no stage here ever does — so
# requirement 34c's "only a human may clear a void" is unchanged; what this
# gives them is a way to say it from where they actually are.
unvoid_label="$(cfg '.unvoid_label')"
# How old a fully-actioned void must be before it is dropped from the extract
# (requirement 34n). `0` disables retirement, which is also what an
# unparseable value falls back to — never retiring is the safe direction, an
# unbounded extract being the cost this requirement exists to bound rather
# than a correctness risk on its own.
void_retire_after_days="$(cfg '.void_retire_after_days')"
[[ "$void_retire_after_days" =~ ^[0-9]+$ ]] || void_retire_after_days=0
# The refinement class (requirements 34e, 35d). The label is a projection onto
# issue-type items and nothing reads it back, so an empty value switches the
# projection off without touching the log mechanism that actually carries the
# state. The cap bounds how much of one engagement the day-one backlog of
# silently-skipped items may take; `0` removes the class from engagements while
# still recording the blocks.
needs_refinement_label="$(cfg '.needs_refinement_label')"
refinement_max_per_engagement="$(cfg '.refinement_max_per_engagement')"
[[ "$refinement_max_per_engagement" =~ ^[0-9]+$ ]] || refinement_max_per_engagement=3
# The per-reason bound's own cap (D18 §5, agent-ops#936): how many
# decide-tactical passes `escalation_autonomy_decide_pass_available` (lib/
# enabler.sh) allows for one item in total, whatever their reason — the
# backstop that turns "a fresh reason always gets a fresh pass" into a
# bounded total rather than an unbounded one. A human touch (eligibility
# `reason: "issue-closed"`) short-circuits the check for that cycle, granting
# one further pass, but does not reset the count.
escalation_adjudication_max_passes="$(cfg '.escalation_adjudication_max_passes')"
[[ "$escalation_adjudication_max_passes" =~ ^[0-9]+$ ]] || escalation_adjudication_max_passes=3
# The Refiner (requirement 39): the positive counterpart of the refinement
# class above. `refined_label` is a projection too, never read back — there is
# no hand-applied form of it, unlike `needs_refinement_label` — and empty
# switches it off without touching the `item-refined` record the Co-Ordinator
# actually reads (requirement 3h). `refinement_policy` is per-source and read
# by both the Refiner (which sources it may spend an engagement on) and the
# Co-Ordinator (which sources it must not select unrefined); an unreadable
# object is treated as empty, which is "every source exempt" — the same "not a
# licence to spend" default every threshold here falls back to.
refiner_model="$(resolve_model_id refiner_model "$(cfg '.refiner_model')")"
refined_label="$(cfg '.refined_label')"
refiner_max_per_engagement="$(cfg '.refiner_max_per_engagement')"
[[ "$refiner_max_per_engagement" =~ ^[0-9]+$ ]] || refiner_max_per_engagement=5
refinement_policy_json="$(cfg_json '.refinement_policy')"
jq -e 'type == "object"' <<<"$refinement_policy_json" >/dev/null 2>&1 || refinement_policy_json='{}'
# Requirement 1c (agent-ops#822): a source resolved to "required" is never
# selected unrefined (prompts/coordinator.md's "Per-source refinement
# policy"), so with no Refiner ever engaging to refine one (requirement 39's
# own gate on refiner_model being set), its items would wait forever — the
# same pairing shape as the enabler_assignee guard above, shared with
# scripts/doctor.sh through the same lib/config-schema.sh function.
required_sources_without_refiner="$(config_required_refinement_sources_without_refiner \
  "$refinement_policy_json" "$refiner_model")"
if [[ -n "$required_sources_without_refiner" ]]; then
  echo "agent-cycle: refinement_policy requires [$required_sources_without_refiner] but refiner_model is empty — refusing to start rather than let a source's unrefined items wait forever with nothing ever refining one" >&2
  exit 1
fi
# Requirement 1c, "the floor" (agent-ops#822): refiner_model and enabler_model
# are the two stages that can author a work order's context/acceptance
# directly (requirements 39 and 36b); either ranking below an implementer
# tier it might write for is exactly the failure #815 (fixed by #819) and
# #821 both trace to. Shared with scripts/doctor.sh through the same
# lib/config-schema.sh function, so the Script's refusal and doctor's `fail`
# can never drift.
tier_violations="$(config_model_tier_floor_violations "$refiner_model" "$enabler_model" \
  "$implementer_model_default" "$implementer_model_trivial")"
if [[ -n "$tier_violations" ]]; then
  while IFS=$'\t' read -r author_key floor_key author_id floor_id; do
    [[ -n "$author_key" ]] || continue
    echo "agent-cycle: $author_key ($author_id) ranks below $floor_key ($floor_id) on the fleet's model-tier ladder (lib/model-id.sh's MODEL_TIER_RANK) — refusing to start rather than let it author a specification for a more capable Implementer (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 1c)" >&2
  done <<<"$tier_violations"
  exit 1
fi
pr_label="$(cfg '.pr_label')"
# Read here (rather than left to the Co-Ordinator, which puts it in the work
# order's `branch`) because requirement 3c's gatherer needs it: a PR is only
# ours to push to if its head branch is under this prefix. The Landing Gate says
# branches outside it belong to humans.
branch_prefix="$(cfg '.branch_prefix')"
# Same rationale as branch_prefix, for the human tech-debt-claim protocol's
# own namespace (TECH-DEBT.md): empty disables it, so a repository that does
# not follow that convention sees only branch_prefix.
tech_debt_branch_prefix="$(cfg '.tech_debt_branch_prefix')"
max_open_agent_prs="$(cfg '.max_open_agent_prs')"
# Every stage cap — the wall-clock backstop and the liveness watchdog alike —
# is now derived per (actor, repository, model) from the fleet's own record of
# itself (requirement 4f, lib/stage-budget.sh). What is read from the
# configuration here is only what an installation has explicitly overridden;
# absent, the derivation answers, and with no history at all the shipped prior
# does. Nothing in this file carries a default for them any more, which is the
# point: a self-tuning value that a config key silently outranks would never
# tune at all.
#
# `lock_stale_after` becomes a *floor* on a derived value rather than an
# assertion checked against fixed caps (requirement 4f). Absent is normal.
lock_stale_configured_hours="$(cfg '.lock_stale_after // 0')"

# How much room the derived lock leaves beyond the summed backstops. Half an
# hour covers everything a cycle does outside its stages — the pre-fetches,
# the claim traffic, the clone and its deletion — with margin, and erring long
# here is close to free: a dead holder is taken over on its pid rather than on
# its age, so this bounds only how long a live but hung cycle may hold on.
LOCK_SLACK_MIN=30

# Initialised here, not at the derivation below, because the EXIT trap is armed
# long before that: a cycle that stands down or finds the lock held still runs
# `cleanup`, and an unset variable read from inside a trap under `set -u` would
# abandon the trap part-way — costing the cycle its `cycle-end` event, its lock
# release and its state-sync push. An empty table is a valid answer that
# resolves to the shipped priors.
stage_budget_json='{"cells":{},"actors":{}}'
# Likewise: `acquire_lock` reads this, and is called immediately after the
# derivation sets it, but a function that reads an unset global under `set -u`
# fails at the reader rather than at the writer. Four hours, the value this
# used to be configured to, until the derivation replaces it.
lock_stale_after_sec=14400

# stage_budget_overrides ACTOR [REPO]
# What the configuration says about this actor, as `{backstop, inactivity}` —
# either a number or null. The first two levels of requirement 4f's
# precedence, most specific first: a `stage_timeouts`/`stage_inactivity` entry
# on the repository being worked, then the plain `timeout_<actor>` /
# `inactivity_<actor>` key. Null means the configuration is silent and the
# derivation answers.
#
# Read here rather than in lib/stage-budget.sh because the configuration is
# this script's to know; the library stays a pure function of the log.
stage_budget_overrides() {
  local actor="$1" repo="${2:-}" out
  # TD-PPagop-26081407: reads CONFIG_FILE straight off disk (test 1 — a
  # config a human is mid-edit, or a bad merge, can be unparseable at this
  # exact moment) and `{}` — "no overrides configured" — is the fallback a
  # healthy read of an unconfigured file gives too (test 2), so a failure
  # here is invisible without a report.
  out="$(jq -nc --slurpfile c "$CONFIG_FILE" --arg a "$actor" --arg r "$repo" '
    ($c[0] // {}) as $cfg
    | (($cfg.repos // []) | map(select(.slug == $r)) | first // {}) as $repo_cfg
    | {
        backstop: (($repo_cfg.stage_timeouts // {})[$a] // $cfg["timeout_" + $a] // null),
        inactivity: (($repo_cfg.stage_inactivity // {})[$a] // $cfg["inactivity_" + $a] // null)
      }' 2>&1)" || { guard_warn "stage_budget_overrides" "$out"; out='{}'; }
  printf '%s' "$out"
}

# stage_budget_apply ACTOR REPO MODEL
# Resolve this launch's two caps, announce them on the stage-start event, and
# leave them in `stage_backstop_min` / `stage_inactivity_min` for the launch.
#
# Announced rather than merely used: a self-tuning number that cannot be
# traced is a mystery number, and `stage-start` is where a reader looking at
# this stage will already be. The event carries where the value came from
# (`config`, `cell`, `pooled` or `prior`) and, when it came from the
# derivation, whether the cell had enough of its own evidence to speak for
# itself or is still sitting on the pooled estimate.
stage_budget_apply() {
  local actor="$1" repo="${2:-*}" model="${3:-*}" extra="${4:-{\}}" budget
  budget="$(stage_budget_resolve "$stage_budget_json" "$actor" "$repo" "$model" \
    "$(stage_budget_overrides "$actor" "$repo")")"
  # TD-PPagop-26081407: passes triage test 2 — a failure here yields empty
  # string, and the very next block treats anything that is not `^[0-9]+$`
  # (empty string included) as unresolved and recomputes it from
  # STAGE_BUDGET_PRIORS, so this fallback can never reach a caller unvetted.
  stage_backstop_min="$(jq -r '.backstop_min' <<<"$budget" 2>/dev/null || printf '')"
  stage_inactivity_min="$(jq -r '.inactivity_min' <<<"$budget" 2>/dev/null || printf '')"
  # A derivation that produced nothing readable must not stop a cycle: fall
  # back to the shipped prior for this actor, which is what a fresh
  # installation runs on anyway.
  [[ "$stage_backstop_min" =~ ^[0-9]+$ ]] \
    || stage_backstop_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" --arg a "$actor" \
         '($p[$a] // $p.implementer).backstop')"
  [[ "$stage_inactivity_min" =~ ^[0-9]+$ ]] \
    || stage_inactivity_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" --arg a "$actor" \
         '($p[$a] // $p.implementer).inactivity')"
  log_event "stage-start" "$(jq -nc --arg s "$actor" --arg m "$model" \
    --argjson e "$extra" \
    --argjson b "$(jq -nc --argjson x "$budget" \
      --argjson bs "$stage_backstop_min" --argjson is "$stage_inactivity_min" \
      'if ($x | type) == "object" then $x else {} end
       + {backstop_min: $bs, inactivity_min: $is}')" \
    '{stage: $s, model: $m} + (if ($e | type) == "object" then $e else {} end) + $b')"
}
limit_cooldown_default_hours="$(cfg '.limit_cooldown_default')"
disable_default_ttl_hours="$(cfg '.disable_default_ttl')"
# How long an automatic fleet-wide stand-down may run before it is put in
# front of a human (requirement 2; #244). 0 turns the escalation off, the same
# convention as crash_loop_after. Manual stand-downs never escalate — the
# person who set one does not need to be paged about their own decision.
limit_escalate_after_hours="$(cfg '.limit_escalate_after_hours')"
[[ "$limit_escalate_after_hours" =~ ^[0-9]+$ ]] || limit_escalate_after_hours=24
# The GitHub API budget a cycle must find before it is worth starting one
# (requirement 2.0). Two floors because GitHub meters two pools separately and
# either can be the binding one — on 2026-08-12 the fleet exhausted `graphql`
# while `core` still had 96% of its hour left. Either set to 0 turns that
# resource's floor off; both at 0 turns the check off entirely.
github_min_core_budget="$(cfg '.github_min_core_budget')"
[[ "$github_min_core_budget" =~ ^[0-9]+$ ]] || github_min_core_budget=0
github_min_graphql_budget="$(cfg '.github_min_graphql_budget')"
[[ "$github_min_graphql_budget" =~ ^[0-9]+$ ]] || github_min_graphql_budget=0
# How long lib/github-limit.sh's `gh` wrapper may wait out a single refusal,
# and how long this whole process may spend waiting across all of them. Read
# here and exported so the gatherers and sweeps this cycle launches are
# governed by the installation's number rather than the library's default.
GITHUB_LIMIT_MAX_WAIT_SECONDS="$(cfg '.github_retry_max_wait_seconds')"
[[ "$GITHUB_LIMIT_MAX_WAIT_SECONDS" =~ ^[0-9]+$ ]] || GITHUB_LIMIT_MAX_WAIT_SECONDS=60
GITHUB_LIMIT_TOTAL_WAIT_SECONDS=$(( GITHUB_LIMIT_MAX_WAIT_SECONDS * 2 ))
export GITHUB_LIMIT_MAX_WAIT_SECONDS GITHUB_LIMIT_TOTAL_WAIT_SECONDS
# The free-space floor on workspace_root a cycle must clear before it is worth
# starting one (requirement 2.0c, agent-ops#756): a cycle that starts anyway
# clones into whatever room is actually left, and a clone or push truncated
# mid-write is what disabled `git gc` on the ockham laptop (#604) and left it
# 4.2 GB of orphaned clones (#605). `0` turns the check off.
min_free_workspace_bytes="$(cfg '.min_free_workspace_bytes')"
[[ "$min_free_workspace_bytes" =~ ^[0-9]+$ ]] || min_free_workspace_bytes=0
none_selected_recheck_hours="$(cfg '.none_selected_recheck_hours')"
candidates_max="$(cfg '.candidates_max')"
# Requirement 4i (agent-ops#641): the largest assembled prompt the Co-Ordinator
# may be handed. Non-numeric or absent reads as 0 — the bound off — because a
# misread here must not be able to trim a cycle's candidates to nothing, which
# is a worse failure than the overflow the bound exists to catch.
coordinator_prompt_max_bytes="$(cfg '.coordinator_prompt_max_bytes')"
[[ "$coordinator_prompt_max_bytes" =~ ^[0-9]+$ ]] || coordinator_prompt_max_bytes=0
max_chained_cycles="$(cfg '.max_chained_cycles')"
# How far apart this node's own cron firings are (requirement 39,
# agent-ops#1096): the width of the window a `roll-pending` marker needs to
# span so a healthy node that declines to chain on a pending image roll still
# gets watchtower a real gap to poll into, rather than the sub-second one a
# chained cycle's own lock hand-off leaves. Not derived from `cycle_hours`/
# `excluded_minutes` the way `lock_stale_after` and its siblings are
# (requirement 1d) — this bounds one cycle's own deferral, not a span of
# fleet history, and the plain interval is the right width for that.
cycle_interval_minutes="$(cfg '.schedule.cycle_interval_minutes')"
[[ "$cycle_interval_minutes" =~ ^[0-9]+$ ]] || cycle_interval_minutes=15
# How long a draft PR this system raised may sit untouched before it counts as
# abandoned and finishing it becomes selectable work (requirement 3e). Comfortably
# beyond a whole cycle, so a draft merely being worked never qualifies.
abandoned_draft_after_hours="$(cfg '.abandoned_draft_after_hours')"
state_repo="$(cfg '.state_repo')"
all_repos_json="$(cfg_json '.repos')"
# The implementation-plan source has no path of its own in the prompt or the
# code (issue #77): a repo that lists it must say where its plan document
# lives. A repo that lists the source without configuring the path is a fatal
# misconfiguration, not a silent fallback — the Co-Ordinator would have
# nothing to read — so this fails the same way the enabler_assignee guard
# above does: at startup, before any stage runs. This rule holds *between*
# `sources` and `implementation_plan_path`, which is outside what the schema
# gate above can state about either key alone, so it stays here — shared with
# `scripts/doctor.sh` via `config_missing_plan_path_repos` (requirement 1b).
missing_plan_path="$(config_missing_plan_path_repos "$all_repos_json")"
if [[ -n "$missing_plan_path" ]]; then
  echo "agent-cycle: repo(s) [$missing_plan_path] list the implementation-plan source but have no implementation_plan_path configured — set it in config.json's repos entry or drop the source" >&2
  exit 1
fi

# Per-installation prompt overrides (requirement 4a, lib/prompt-overrides.sh):
# config-pointed files, outside prompts/*.md, appended to (or, for `replace`,
# substituted for) a stage's shipped prompt. Absent entirely, every stage
# assembles byte-identical to today. Its shape is enforced by the schema gate
# above; what remains tolerated here is a *runtime* fault only — a
# well-formed entry whose file is unreadable this cycle stays tolerated in the
# lib, since files legitimately come and go, and an unreadable one still
# moves the fingerprint, where a structural typo would not have.
prompt_overrides_json="$(cfg_json '.prompt_overrides')"

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
# The same instant in the format GitHub's own API returns, so it can be
# compared against a timeline event's `created_at` without reformatting. It is
# the bound `handoff_complete_review` hands `reconciliation_gate` (requirement
# 31c, agent-ops#533): "when this pull request last left draft" has to mean
# "as this round found it", and every draft flip this cycle performs — the
# Reviewer's own `gh pr ready` at its step 7, most of all — happens after this
# line. The cycle id's own leading token is the same instant, but in a
# different format and welded to the node name and pid, so it is minted
# separately rather than parsed back out.
cycle_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cycle_dir="$state_dir/cycles/$cycle_id"
# A management command runs no stages and writes no transcripts; giving it a
# cycle directory would leave an empty one behind for every --status anyone
# ever ran.
[[ -n "$MANAGE_ACTION" ]] || mkdir -p "$cycle_dir"

# --- Logging ---
# FIELDS must be a JSON object: the envelope merge below is jq's `+`, and jq
# cannot add an object and an array — it raises a runtime error, exit 5, and
# under `set -e` that was the whole cycle's exit. Not hypothetical: the one
# call site that passed an array (`enabler-stale-refs-skipped`, a guard that
# had never fired) took every node down in a pre-selection crash loop the
# first time it did (issue #361). So the logger holds the contract itself
# rather than trusting 168 call sites to: a non-object payload is recorded
# wrapped under `fields` — the event still lands, readable, rather than
# vanishing — and the append is `|| true` because recording an event is never
# worth a cycle. stderr stays unredirected on the final jq for the same
# reason the wrap exists: if this still fails somehow, cron.log should show
# it, not swallow it.
log_event() {
  local event="$1" fields="${2:-{\}}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! jq -e 'type == "object"' <<<"$fields" >/dev/null 2>&1; then
    local wrapped
    wrapped="$(jq -c '{fields: .}' <<<"$fields" 2>/dev/null)" || true
    [[ -n "$wrapped" ]] || wrapped="$(jq -nc --arg f "$fields" '{fields: $f}')"
    fields="$wrapped"
  fi
  jq -nc --arg ts "$ts" --arg cycle "$cycle_id" --arg node "$node_name" --arg event "$event" --argjson fields "$fields" \
    '{ts: $ts, cycle: $cycle, node: $node, event: $event} + $fields' >> "$log_file" || true
}

# void_obsolete_ctx_json REPO_SLUG [FLAGS_JSON]
# What every `void_guard_reason` call site (the Co-Ordinator, the Enabler, the
# Implementer) hands it as CTX_JSON, so the machine `obsolete` alternative
# (design doc §5.5, issue #413, WI-10) has what it needs without lib/void-
# guard.sh ever touching config, the kill switch, or the log itself — that
# file stays self-contained and stubbable with `gh` alone, exactly as its own
# tests rely on.
#
# FLAGS_JSON is optional: a caller that already holds the current
# `draft_obsolete_flags` result — `log_voided_items` below computes it once
# per invocation and hands it to every entry in its loop — passes it straight
# through, skipping the two full union-log `jq` scans a fresh call would
# otherwise pay per entry. Every other call site is single-shot per cycle
# (issue #508) and omits it, letting this function compute it itself exactly
# as it always has.
#
# `${union_log:-$log_file}` rather than `$union_log` outright: this is called
# from functions the Script may invoke before the fleet-wide union log is
# built partway through a cycle (`union_log="$cycle_dir/.fleet-log.jsonl"`,
# set once, well after this function is first defined) — falling back to this
# node's own local log costs only *this node's* peers' flags being briefly
# invisible to a void decided that early, never a crash under `set -u`. A
# `draft-obsolete-flagged` event is a fact, never retracted (lib/cycle-
# state.sh's `draft_obsolete_flags`), so a flag missed this way is not lost —
# it is simply not yet in whichever log this call happened to read. The same
# reasoning is why the level read below is never hoisted alongside it, even
# for the looped caller: it gates the *permissive* machine-`obsolete` path, so
# it stays live, per entry (verdict recorded on #501; do not revisit without a
# human decision).
void_obsolete_ctx_json() {
  local slug="$1" flags_json="${2:-}" level
  level="$(merge_autonomy_effective_level "$DEFAULTED_CONFIG" "$slug" "$state_repo" "$state_dir" 2>/dev/null || true)"
  [[ -n "$flags_json" ]] || flags_json="$(draft_obsolete_flags "${union_log:-$log_file}")"
  jq -nc --arg lvl "$level" --arg cycle "$cycle_id" --argjson now "$(date -u +%s)" --argjson flags "$flags_json" \
    '{merge_autonomy_level: $lvl, cycle: $cycle, now_epoch: $now, flags: $flags}'
}

# TD-PPagop-26081407: a guarded call site (`cmd 2>&1) || { guard_warn ...;
# var=fallback; }`) that falls back to a literal on failure without saying so
# is indistinguishable from a genuinely empty/zero answer downstream — the
# defect the union log's `guard-degraded` event exists to remove. Every
# converted site captures the failed command's own stdout+stderr (its `2>&1`
# replaces the old `2>/dev/null`) and passes it here as `detail`; the fallback
# itself is never touched, only reported. Kept to one line per call site on
# purpose — 67 near-identical `jq -nc '{...}'` wrappers would be their own
# noise.
#
# The report is bounded on both axes, because its destination is the
# fleet-replicated union log — the unbounded input requirements 4c and 4g
# exist because of. A guard that fails *persistently* (a `date` parse of a
# field that is simply always absent, a `gh` outage across the repo loop)
# would otherwise write one event per occurrence per cycle per node: the
# first GUARD_WARN_SITE_MAX occurrences of each site label are reported, the
# last of them marked `final` so a reader knows the site may have kept
# failing unreported, and `detail` — a failed command's own output, which for
# a `gh api` body has no bound at all — is capped to its leading 500 bytes,
# where the cause is. A site label carrying a loop variable
# (`claim-count:<slug>`) still reports per slug; the cap is on repeats of one
# label, not on distinct sites. The tally is a shell variable, so a guard
# raised inside a command substitution counts only within it — those sites
# report unbounded within one cycle as before, which is the conservative
# direction to fail in for a cap whose only job is to stop noise.
#
# On a management command the report goes to stderr instead. --status runs
# before the lock and deliberately creates no cycle directory (see the
# comment above `mkdir -p "$cycle_dir"`) so that a read-only query leaves
# nothing behind; its `cycle_id` names a cycle that never ran, and stamping
# the fleet's shared log with one would be a record of a failed read during
# somebody's query, not of pipeline state. --disable/--enable do write to the
# log from this path, but they record a state change a human asked for.
# Nothing is lost: every fleet-state read a management command guards is read
# again by real cycles, which report it under a cycle id that resolves — and
# stderr is where the human who typed the command is already looking.
guard_warn() {  # guard_warn <site-label> <captured-stdout+stderr>
  local max="${GUARD_WARN_SITE_MAX:-3}" n detail="${2:0:500}"
  # `declare -p`, not `${guard_warn_counts+x}`: the latter tests element 0, so
  # an associative array that exists but is still empty reads as unset and the
  # tally would reset on every call.
  declare -p guard_warn_counts >/dev/null 2>&1 || declare -gA guard_warn_counts=()
  n=$(( ${guard_warn_counts["$1"]:-0} + 1 ))
  guard_warn_counts["$1"]=$n
  (( n <= max )) || return 0
  if [[ -n "${MANAGE_ACTION:-}" ]]; then
    printf 'agent-cycle: guard-degraded: %s: %s\n' "$1" "$detail" >&2
    return 0
  fi
  log_event "guard-degraded" "$(jq -nc --arg s "$1" --arg d "$detail" \
    --argjson n "$n" --argjson m "$max" \
    '{site: $s, detail: $d, n: $n} + (if $n >= $m then {final: true} else {} end)')"
}

# --- Management commands (--disable / --enable / --status) ---
# Handled here, before the lock and before any `gh` call: they change no
# pipeline state that the lock protects, and `--status` must stay usable — and
# instant — while a cycle holds the lock, since "is one running right now?" is
# the question it is most often asked. `lib/manage.sh` (#771) carries the
# whole of it — the five report helpers and the action handling — and returns
# at once when no management action was asked for; every action it does handle
# exits the process, so nothing below here is reachable from one.
run_manage_command

# The repo and item this cycle selected, once the Co-Ordinator has picked one.
# Requirement 33 puts `repo`/`item` on an event where applicable, and the
# requirement 34 blocked extract groups attempt-failed events by repo+item — so
# an event raised after selection that omits them can never block the item it
# failed on, and the same item is free to be re-selected next cycle.
selected_repo=""
selected_item=""
selected_source=""
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
# The second, PR-keyed file claim (issue #238) a finishing-source win also
# holds — empty for every other source, and for a finishing source whose PR
# number neither its candidate nor its item ref yielded. Always a `file` claim
# (there is no PR-keyed branch), so its release never touches a ref. Tracked
# independently of claim_active (below): the item-keyed claim and this one are
# released on different schedules (issue #360), so a flag that zeroed both at
# once could not represent "item claim gone, PR-keyed claim still held".
claim_pr_key=""

# Zero means unbounded (GNU timeout treats a duration of 0 as "no timeout"),
# which is every ordinary release. The signal handler (requirement 9c) and
# cleanup's backstop release set a small bound instead: the handler runs on
# borrowed time — a lock takeover KILLs what has not exited within its grace —
# and the EXIT trap carries the cycle's record, so in both a release the
# network stalls must not cost the exit record. A claim the release never
# reached is retired by the gc within `claim_ttl_hours` anyway.
claim_release_timeout=0

# --- The Enabler's state for this cycle (requirements 35, 37) ---
# All three are read from the exit trap, so they are initialised here — before
# anything can exit — and only ever move in the safe direction. `enabler_allowed`
# is set once the gatherers have finished, so no early exit (a standby node, the
# switch, a usage-limit cooldown, a lost lock) can engage a stage on inputs it
# never computed.
enabler_allowed=0
enabler_eligible_json='[]'
# The Refiner's own state (requirement 39), same reasoning and same guard.
refiner_allowed=0
refiner_candidates_json='[]'
limit_hit_this_cycle=0

# `landing_armed_by_repo` (PR #557 review round 2 of TD-PPagop-26081701) is
# this cycle's own running tally of how many pull requests each repository
# has already been armed for so far, keyed by slug because
# `merge_budget_decide`'s cap is per repository. Shared by the two call
# sites of `_landing_stage_attempt` that can both run in one cycle process —
# the 2.1e landing-retry sweep (`_landing_retry_sweep_repo`, below) and this
# round's own arming step (`run_landing_stage`, gate 0) — so a live
# `merge_budget_decide` read at either one discounts arms the other already
# made this same cycle, not only its own. Declared here, ahead of both, so
# neither reads an unset array under `set -u`; only ever grows within a
# cycle, and this process exits before the next one, so it needs no reset.
declare -A landing_armed_by_repo=()

# --- Cleanup (always runs on exit) ---
lock_acquired=0
clone_dir=""
# Finish-then-continue (requirement 39): set true only once this cycle has
# won a claim and is about to run the Implementer. Initialised here, ahead
# of the trap, for the same reason lock_acquired is: a cycle that stands
# down or fails before ever reaching that point still runs cleanup, and an
# unset variable read under `set -u` inside a trap would abort it part-way.
#
# chain_count is this cycle's own place in its lineage, 1 for the cron-fired
# original — AGENT_CYCLE_CHAIN_COUNT is how a chained child learns it is not
# the original; garbage or absent both mean "the original".
chain_eligible=0
chain_count="${AGENT_CYCLE_CHAIN_COUNT:-1}"
[[ "$chain_count" =~ ^[0-9]+$ && "$chain_count" -ge 1 ]] || chain_count=1
cleanup() {
  local exit_code=$?
  # A signal landing mid-cleanup must not re-enter the handler over a cycle
  # that is already writing its record (requirement 9c).
  trap '' TERM INT HUP
  # The PR-keyed claim's backstop (issue #360). Every handled ending has
  # already released it by the time this trap runs — the terminal handoff, a
  # handback, a stage failure, a signal — and then this is a no-op on an
  # empty claim_pr_key. What it catches is the one ending no handler sees:
  # an unhandled errexit abort between `pr-raised` and the Reviewer's
  # terminal path, which would otherwise strand `claims/<repo>/pr-<n>.json`
  # until the gc's `claim_ttl_hours` — hours in which the PR this cycle
  # abandoned mid-Reviewer, the very PR that just lost its Reviewer and most
  # needs picking up, is invisible to every peer's finishing sources.
  # Time-bounded like the signal handler's release and for the same reason:
  # this trap carries `cycle-end`, the lock release and the clone deletion,
  # and a release the network stalls must not cost the record.
  claim_release_timeout=8
  release_pr_claim
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
  # The Refiner (requirement 39): same one call site, same reasoning, run
  # after the Enabler so a fleet-limit hit the Enabler's own engagement
  # triggers this cycle is still visible to the live check below.
  maybe_run_refiner "$exit_code" || true
  # Deferred crash-loop escalations (requirement 2.7, agent-ops#1074): after
  # the Enabler and the Refiner, same reasoning as both — and after every
  # stage this cycle might have run, coordinator included, which is the
  # whole point: `crash_loop_refile_pending` re-gathers the union log fresh
  # here, so a Co-Ordinator success this very cycle logged already shows.
  crash_loop_refile_pending || true
  # lib/issue-priority.sh's own cache directory (issue #510): removed here,
  # after the Refiner, since the Refiner's own priority-triage duty is that
  # cache's main consumer.
  issue_priority_cache_cleanup
  # The closing GitHub budget reading (requirement 2.0d): after the Enabler
  # and the Refiner so their own calls fall inside it, before `cycle-end` so
  # it travels with this cycle. Only for a cycle that took the opening
  # reading — an ending that never read GitHub (the switch, requirement 2.3)
  # must not start now. Two points; never fatal.
  if [[ "${GITHUB_BUDGET_CYCLE_OPEN:-0}" == "1" ]]; then
    github_budget_record cycle-end || true
  fi
  log_event "cycle-end" "$(jq -nc --argjson rc "$exit_code" '{exit_code: $rc}')"
  if [[ "$lock_acquired" == "1" ]]; then
    rm -f "$lock_file"
  fi
  # Per-stage health snapshot (issue #662, lib/stage-health.sh): recomputed
  # from this node's own $log_file — which already carries every stage-end
  # and attempt-failed event this cycle logged — and written before the
  # state-sync push below, so that push's own heartbeat (requirement 2.5)
  # carries this cycle's fresh verdict rather than the previous one's.
  # Best-effort like the dashboard refresh beside it: never affects this
  # cycle's own exit code.
  stage_health_write_status "$state_dir" "$log_file" || true
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
  # Yield to a pending image roll (requirement 39, agent-ops#1096): a node
  # running long or chained cycles never presents watchtower's
  # deploy/docker/watchtower-pre-update.sh a gap to poll into, so a healthy,
  # merely-busy node could stay behind the registry's newest image
  # indefinitely — the bound `lock_stale_after` gives a wedged cycle never
  # applied to one that is simply busy. Only worth asking when there is a
  # chain to give up: a cycle already not chaining, or one that failed
  # outright, has nothing here to yield. Reads the same `image_drift_status`
  # verdict the heartbeat's `image` field publishes (requirement 2.5) — no
  # second signal — through the identical cache file the state-sync push just
  # above refreshed, so this costs no second registry round trip.
  if (( chain_eligible )) && (( exit_code == 0 )); then
    local image_status_json=""
    image_status_json="$(image_drift_status "$(agent_ops_version "$SCRIPT_DIR")" \
      "$state_dir/.image-drift-cache.json" 2>/dev/null || echo null)"
    if chain_image_behind "$image_status_json"; then
      chain_eligible=0
      chain_write_roll_pending "$state_dir" "$cycle_interval_minutes"
      log_event "roll-pending" "$(jq -nc --argjson image "$image_status_json" \
        --argjson minutes "$cycle_interval_minutes" \
        '{image: $image, minutes: $minutes}')"
    fi
  fi
  # Finish-then-continue (requirement 39), last of all: a chained cycle is a
  # brand-new process with its own cycle id, its own lock acquisition and its
  # own full cleanup, so it must not start until this one has released
  # everything above — the lock first of all, or it would just log
  # `cycle-skipped` and exit. Gated on `exit_code == 0` too: `chain_eligible`
  # is decided in the claim section (requirement 17a) — at a won claim, or at
  # a raced stand-down whose fresh look is the whole point (requirement 39) —
  # and nothing past that point may turn a real success into a chain off of a
  # genuine failure. Detached
  # with input from /dev/null and both streams appended to the same cron.log
  # a cron-fired cycle already writes to, then disowned: this process is
  # about to exit, and nothing here should wait for — or die with — the
  # child.
  #
  # Spawned through a subshell that restores the default dispositions first,
  # which is not decoration: an *ignored* signal is inherited across both fork
  # and exec, and a shell that starts with a signal already ignored can never
  # take it back — `trap ... TERM` in the child is silently a no-op for the
  # rest of its life. The `trap '' TERM INT HUP` at the top of this function
  # is exactly such an ignore, so a child forked from here would run the whole
  # of the next cycle deaf to every signal requirement 9c's handler exists to
  # catch, and requirement 1's stale-lock takeover would find its TERM ignored
  # and reach the item only through the KILL that follows — no `attempt-failed`,
  # no `cycle-end`, no claim released. EXIT is reset alongside them so a failed
  # `exec` cannot re-enter this same handler in the subshell.
  if (( chain_eligible )) && (( exit_code == 0 )); then
    log_event "chained" "$(jq -nc --argjson n "$(( chain_count + 1 ))" --argjson m "$max_chained_cycles" \
      '{depth: $n, max_chained_cycles: $m}')"
    (
      trap - TERM INT HUP EXIT
      AGENT_CYCLE_CHAIN_COUNT=$(( chain_count + 1 )) exec "$SCRIPT_DIR/agent-cycle.sh" "${ORIGINAL_ARGV[@]}"
    ) </dev/null >>"$state_dir/cron.log" 2>&1 &
    disown 2>/dev/null || true
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
  # A stranded Implementer may have opened its draft PR without ever
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
      '{detail: "disable expired", was: $r, scope: "node"}')"
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
    # fleet_flag_delete's own outcome used to be discarded (`|| true`) — this
    # fleet-level expiry could win the delete, lose it to a peer's own race
    # (fine, requirement 2.5), or fail outright, and the log could not tell
    # those apart (issue #426). fleet_flag_delete_outcome folds this site into
    # the same ok/failed/unconfigured vocabulary the `--enable` path uses.
    fleet_expiry_flag_outcome="$(fleet_flag_delete_outcome "$state_repo" "$state_dir" disabled)"
    log_event "enabled" "$(jq -nc \
      --argjson r "$(jq -c '.record' <<<"$fleet_switch_state")" \
      --arg ff "$fleet_expiry_flag_outcome" \
      '{detail: "fleet disable expired", was: $r, scope: "fleet", fleet_flag: $ff}')"
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
      started_epoch="$(date -d "$started_at" +%s 2>&1)" \
        || { guard_warn "stale-lock:started_epoch" "$started_epoch"; started_epoch=0; }
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
        stale_after_sec="$lock_stale_after_sec"
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
# --- 1a. The fleet's memory (requirement 2.5) ---
# `lock.json` keeps two cycles apart on one node; per-item claims (requirement
# 17a) keep two *nodes* off the same work. Nothing arbitrates "the" active
# node any more — what the fleet shares instead is memory: the union of every
# node's event log, materialised by `state-sync.sh fetch` into the peers
# directory. Snapshotted here, once, so every reader below (the usage-limit
# cooldown, the blocked and void extractions, the no-op fingerprint) sees one
# consistent stream — a lesson any node learned spares the whole fleet.
#
# Taken before the lock rather than after it, which it was until the stage
# budgets came to be derived from it (requirement 4f): `lock_stale_after` is
# now one of the things derived, and `acquire_lock` needs it. A snapshot taken
# a few milliseconds earlier is the same snapshot — peers change only when
# `state-sync.sh fetch` runs — and the cost to a cycle that then finds the
# lock held is one read of a file it would have read anyway.
peers_dir="$(fleet_peers_dir "$workspace_root")"
union_log="$cycle_dir/.fleet-log.jsonl"
fleet_logs "$state_dir" "$peers_dir" log.jsonl > "$union_log" || true
# The snapshot's own horizon (requirement 39f, #670): the newest `.ts` the
# union above reaches, not wall clock — in practice this cycle's own
# `cycle-start` event, already in this node's log by the time `fleet_logs`
# unions it in, unless a peer's fetched log carries something newer. The
# own-label grace window has to be measured against that, or a long cycle
# reads a peer's label write, already inside the snapshot, as older than it
# is by the cycle's own runtime. Captured here, immediately after the
# snapshot and before this cycle's own log lines are appended into
# `$union_log` (three
# such appends stand between here and the requirement-39f read-back below,
# and more after it): an append reordered ahead of this point would make the
# horizon track wall clock again through this node's own fresh events, and
# the fix would evaporate. `test/label-marker-horizon-wiring.test.sh` pins
# that ordering, and pins both read-back calls below being handed the result.
union_log_horizon="$(log_latest_ts "$union_log")"

# --- 1a1. What each stage is allowed this cycle (requirement 4f) ---
# Derived, not stored and not configured: one fold over the union above gives
# every node the same two numbers per (actor, repository, model) with nothing
# to synchronise. See lib/stage-budget.sh for why the watchdog threshold is
# estimated and the backstop controlled, and why each moves the way it does.
stage_budget_config="$(cat "$CONFIG_FILE" 2>&1)" \
  || { guard_warn "stage_budget_config" "$stage_budget_config"; stage_budget_config='{}'; }
stage_budget_settings_json="$(stage_budget_settings "$stage_budget_config")"
stage_budget_json="$(stage_budget_table \
  "$(stage_budget_observations < "$union_log")" "$stage_budget_settings_json")"

# The cycle lock has to outlast a cycle that runs every stage to its limits,
# and those limits now move — so it is derived from them plus slack rather
# than asserted against them by hand (requirement 4f). A configured
# `lock_stale_after` is a floor, never a ceiling.
lock_stale_after_sec="$(stage_budget_lock_seconds "$stage_budget_json" \
  "$(stage_budget_all_overrides "$stage_budget_config")" "$LOCK_SLACK_MIN" "$lock_stale_configured_hours")"

# --- 1a2. Reclaim the workspaces of cycles that never cleaned up (#605) ---
# Here because this is the first point at which the lock window exists, and
# comfortably before the clone that will need the room. Before the lock rather
# than after it, and before every stand-down: a node standing down for a
# fleet limit is a node with hours of nothing to do and, quite possibly, a
# full disk — the one moment housekeeping matters most is the one where the
# cycle does no other work. It runs at most once per cycle interval per node
# either way.
#
# `|| true` and a lib that swallows its own failures: reclaiming disk must
# never be the reason a cycle does not run. The event is written only when
# something was actually reclaimed — an ordinary cycle on a healthy node reaps
# nothing, and a `workspaces-reaped` line every cycle would say nothing while
# burying the ones that mean something.
workspace_reap_json="$(workspace_reap_summary "$workspace_root" \
  "$(workspace_reap_window "$lock_stale_after_sec")" || printf '{"reaped":0}')"
if [[ "$(jq -r '.reaped // 0' <<<"$workspace_reap_json" 2>/dev/null || printf 0)" != "0" ]]; then
  log_event "workspaces-reaped" "$workspace_reap_json"
fi

acquire_lock

# Shed a landed roll-pending marker before this cycle's own stages run
# (requirement 39c amendment, agent-ops#1102): the marker a prior cycle's
# cleanup() wrote is honoured on a fixed clock, not "until the next cycle
# would have started", so a cycle that reacquires the lock (as this one just
# did) before that clock runs out would otherwise spend its own run
# underneath a marker that still tells watchtower-pre-update.sh to override
# this very lock. Re-acquiring the lock is itself the proof the gap the
# marker described has ended, so clear it once the image is no longer
# "behind" — the only case a cycle boundary can act on either way (see
# lib/chain.sh's chain_image_behind). Reads the same cache-backed round trip
# the state-sync heartbeat already keeps warm (`IMAGE_DRIFT_TTL`), so this
# costs a network call only when that cache was already due to refresh.
if [[ -f "$state_dir/roll-pending.json" ]]; then
  chain_clear_landed_roll_pending "$state_dir" \
    "$(image_drift_status "$(agent_ops_version "$SCRIPT_DIR")" \
      "$state_dir/.image-drift-cache.json" 2>/dev/null || echo null)"
fi

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
#
# Two classes share this block, through the one `crash_loop_escalate` path:
# a Co-Ordinator that runs and fails identically (`crash_loop_verdict`), and
# a cycle that dies before any stage — Co-Ordinator included — ever starts
# (`crash_loop_preselection_verdict`, TD-PPagop-26081302). The second exists
# because the first is blind to exactly the shape both real outages took:
# `execve` failing on an oversized argv kills the cycle before `stage-start`
# for any stage is ever logged, so no `attempt-failed` exists for
# `crash_loop_verdict` to count. Each class keys its own item ref, so either
# can escalate independently of the other.
#
# `crash_loop_verdict`'s own run can additionally be *transient* (issue
# #1073): every failure it counted was the API being unreachable — a 5xx, a
# dropped connection — not the API refusing a request it considered. On
# 2026-08-29/30 the Ockham host lost outbound network for four hours and this
# block escalated it as "almost certainly deterministic … no amount of
# retrying will clear it" (#1070), which was false on the escalation's own
# evidence and cleared itself the moment the network returned. `escalate`
# (set by `crash_loop_verdict` itself, from each failure's own
# `api_refusal_class`) is what tells the two apart here: `false` means every
# failure in the run was `transient`, so this is a node/fleet connectivity
# fact, not a deterministic fault, and it is logged for the dashboard's node
# card instead of raised as an issue asserting a cause it cannot support.
# `crash_loop_preselection_verdict` carries no such class — an `execve`
# failure is never a network refusal — so its run always escalates exactly as
# it always has.
#
# A verdict here is always computed from the union log as it stood before
# this cycle's own Co-Ordinator attempt (if any) — this point in the script
# runs first, deliberately (the alarm must fire even on a cycle that stands
# down before reaching the Co-Ordinator at all). That makes a *first* attempt
# at filing this exact run reliable — nothing has looked at it before — but
# not a *retried* one: `crash_loop_escalate_or_defer` (lib/enabler.sh) files
# a verdict never before attempted immediately, exactly as `crash_loop_
# escalate` always has, but queues a deferred retry — or a fresh attempt that
# itself failed to file — for `crash_loop_refile_pending` to re-verify from
# `cleanup()`, once this cycle's own Co-Ordinator has had its chance to prove
# the run over (agent-ops#1074). Filing every retry here regardless of
# staleness is exactly what turned the 2026-08-29/30 Ockham outage's last
# hour into a false alarm (#1070): the escalation and the Co-Ordinator
# success that refuted it landed in the same cycle, the escalation first only
# because this block runs before the Co-Ordinator does. `crash_loop_retire_
# resolved` closes the other side of the same gap: an already-open Co-
# Ordinator-class escalation whose run has broken since, on any later cycle's
# ordinary union snapshot — no same-cycle race to lose, so no need to wait
# for `cleanup()`.
#
# Retirement runs FIRST, before either `crash_loop_escalate_or_defer` call
# below (agent-ops#1134 review). `create_escalation_issue`'s own open-issue
# dedup is a live `gh issue list` query, not a read of this cycle's
# `$union_log` — so if a resolved run's issue is still open when a *new*,
# same-detail run re-crosses `crash_loop_after` later in this same block,
# `create_escalation_issue` finds that still-open issue and rebinds it to the
# new run instead of filing a fresh one, and this retirement step then closes
# it out from under that live run on the strength of a `$union_log` snapshot
# that predates the rebind. Running retirement first closes the resolved
# run's issue before the new run's own filing attempt can see it, so that
# attempt's `gh issue list` no longer finds anything to reuse and opens a
# fresh issue instead — the new run gets its own alarm rather than inheriting
# one already closed for the old.
if ! (( DRY_RUN )) && (( crash_loop_after > 0 )) \
    && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" && -s "$union_log" ]]; then
  # Retirement (agent-ops#1074): independent of whether either class fires a
  # verdict this cycle — an open escalation from a run that broke cycles ago
  # is exactly what this closes, whatever this cycle's own union log shows
  # right now.
  crash_loop_retire_resolved

  crash_loop_json="$(crash_loop_verdict "$crash_loop_after" < "$union_log")"
  if [[ -n "$crash_loop_json" ]]; then
    if [[ "$(jq -r '.escalate' <<<"$crash_loop_json")" == "true" ]]; then
      crash_loop_escalate_or_defer "$crash_loop_json" "crash-loop:coordinator" \
        "Co-Ordinator failures" \
        "Crash loop: the Co-Ordinator is failing fleet-wide" \
        "Start with the newest failing cycle's \`coordinator.out\` under \`state_dir/cycles/\` — a stage the API refused outright records the refusal there, as a \`result\` with \`is_error: true\`, and leaves \`coordinator.out.stderr\` empty (agent-ops#641). Read \`coordinator.out.stderr\` too, for a stage that died rather than being refused; the stage transcripts survive every failure."
    else
      log_event "provider-unreachable" "$crash_loop_json"
    fi
  fi

  crash_loop_preselection_json="$(crash_loop_preselection_verdict "$crash_loop_after" < "$union_log")"
  if [[ -n "$crash_loop_preselection_json" ]]; then
    crash_loop_escalate_or_defer "$crash_loop_preselection_json" "crash-loop:pre-selection" \
      "cycles dying before any stage started" \
      "Crash loop: cycles are dying before any stage starts" \
      "No stage transcript exists for a cycle that dies before any stage begins — start with the newest failing cycle's entry in \`cron.log\` (or \`cron.log.1\` after rotation) under \`state_dir/\`."
  fi
fi

# 1c. Token-expiry escalation (agent-ops#694). GitHub states a fine-grained
# PAT's own expiry on every API response it authenticates
# (`GitHub-Authentication-Token-Expiration`); on 2026-08-22 that date went
# unread until it arrived, and every node lost GitHub at once, misdiagnosed
# as an outage (agent-ops#691) for hours before an operator noticed. This is
# the warning before that cliff, 2.0b above is the fallback for having
# missed it.
#
# Free: reads this node's own `state_dir/.doctor-status.json` — the hourly
# `doctor.sh --unattended` pass's own artefact (requirement 2.6a) — rather
# than making a GitHub call of its own. `doctor.sh` is read-only by its own
# declared contract, so the header read lives there and the escalation
# (a write — `gh issue create`) lives here instead, the same split
# `.doctor-status.json`'s fails/warns already use with the dashboard.
#
# Escalated the same fleet-scoped, deduplicated route 1b's crash loop and
# 2.0b's auth failure already use — `create_escalation_issue` in
# `crash_loop_repo`, labelled `enabler_escalation_label`, assigned
# `enabler_assignee` — never `escalation_autonomy` (D18, agent-ops#627):
# that ladder decides whether one specific escalation, an Enabler
# refinement-disagreement (requirement 36b), is adjudicated once before
# reaching a human, and there is no disagreement to adjudicate here, only a
# date comparison — the same reasoning 2.0b's own block gives for the
# identical choice.
#
# Deduplicated on the expiry timestamp itself (`token_expiry_escalated_for`,
# lib/token-expiry.sh), not merely "is there an open issue right now": a
# human closing the issue without rotating the token must not reopen the
# gate every cycle until they do — it reopens only once the token is
# actually rotated, which is exactly when the expiry timestamp changes.
# Before the stand-down checks, like 1b, so a fleet that is also standing
# down still raises the alarm; the cycle then proceeds normally regardless,
# since a token that has not yet expired blocks nothing this cycle needs.
#
# Every read below falls back rather than propagating `jq`'s own exit status:
# this file runs under `set -e`, `.doctor-status.json` is not this script's
# own artefact, and a shape `jq` refuses to index (a `token_expiry` that is
# valid JSON but not an object, say) would otherwise kill the cycle here —
# before any stage starts, which is exactly requirement 2.7's pre-selection
# crash-loop class. No warning is worth costing the cycle that carries it.
doctor_status_json="$(jq -c '.' "$state_dir/.doctor-status.json" 2>/dev/null || echo null)"
token_expiry_days="$(jq -r '.token_expiry.days_remaining // empty' <<<"$doctor_status_json" 2>/dev/null || true)"
token_expiry_expires_at="$(jq -r '.token_expiry.expires_at // empty' <<<"$doctor_status_json" 2>/dev/null || true)"
if [[ "$token_expiry_days" =~ ^[0-9]+$ ]] && [[ -n "$token_expiry_expires_at" ]] \
    && (( token_expiry_days < TOKEN_EXPIRY_WARN_DAYS )); then
  if ! (( DRY_RUN )) && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]] \
      && ! token_expiry_escalated_for "$node_name" "$token_expiry_expires_at" < "$union_log"; then
    token_expiry_body="$cycle_dir/token-expiry-issue.md"
    # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
    {
      printf '## This node'"'"'s fine-grained PAT is expiring soon\n\n'
      printf -- '- node: `%s`\n- expires: `%s`\n- days remaining: **%s**\n\n' \
        "$node_name" "$token_expiry_expires_at" "$token_expiry_days"
      printf 'GitHub states this on every authenticated API response; `doctor.sh --unattended` reads it hourly. Rotate this node'"'"'s `GH_TOKEN` before it expires — agent-ops#691 is what happens if it is not: every pipeline stands down at once, misread as an outage.\n\n'
      printf -- '---\nItem: `token-expiry:%s:%s` · raised by the Script · node `%s`\n' \
        "$node_name" "$token_expiry_expires_at" "$node_name"
    } > "$token_expiry_body"
    if token_expiry_created="$(create_escalation_issue "$crash_loop_repo" \
         "token-expiry:$node_name:$token_expiry_expires_at" \
         "$enabler_escalation_label" \
         "GitHub PAT on node $node_name expires in ${token_expiry_days}d ($token_expiry_expires_at)" \
         "$token_expiry_body")" && [[ -n "$token_expiry_created" ]]; then
      log_event "token-expiry-escalated" "$(jq -nc \
        --arg e "$token_expiry_expires_at" --argjson d "$token_expiry_days" \
        --argjson n "${token_expiry_created%%$'\t'*}" --arg u "${token_expiry_created#*$'\t'}" \
        '{expires_at: $e, days_remaining: $d, issue_number: $n, issue_url: $u}')"
    else
      log_event "warning" "$(jq -nc \
        --arg d "this node's GitHub PAT expires in ${token_expiry_days}d but the escalation issue could not be filed — will retry next cycle" \
        '{detail: $d}')"
    fi
  fi
fi

run_standdown_checks
# --- 2b. Git identity ---
# After every stand-down check above (switch, fleet switch, usage-limit) and
# before the first repo this cycle might actually touch: none of those
# earlier exits commit anything and must not be blocked on an identity they
# never use, but everything from here on can. See lib/git-identity.sh.
require_git_identity agent-cycle

# --- 3. Repo ordering (most overdue first: staleness age weighted by each repo's nice — lib/repo-order.sh; identical to least-recent-first when no nice is set) ---
gather_ordered_repos
compute_skip_lists

# --- 3c/3u, 35a/35b, 3y, 39a. What this cycle is allowed to act on ---
# The band eligibility the blocked/void skip-lists decide, the Enabler's
# eligible set, the Refiner's own two pre-fetched sources and the Refiner's
# candidate set — one seam, `lib/eligibility.sh` (#771), because the four
# answer one question between them over the same inputs, and in an order that
# matters: both stage sets are computed from the extracts the band pass has
# just settled, so a Refiner and an Enabler engagement in the same cycle can
# never disagree about what is already spoken for. Each ends where it did
# inline, `enabler_allowed`/`refiner_allowed` included.
compute_band_eligibility
compute_enabler_eligible_set
prefetch_refiner_sources
compute_refiner_candidates

# --- 2.2a Back-pressure, decided (requirement 2.2a) ---
# Deferred from step 2.2 until the sources were gathered. Back-pressure's stated
# purpose is to throttle new work and stop the landing gate silting up — and the
# four *finishing* sources do neither: `review-feedback` answers a review the
# human has already written, `merge-conflicts` rebases a ready PR that is
# waiting to land, `dequeued` fixes the merge-group checks failure that got a
# ready PR of ours removed from the merge queue, and `abandoned-drafts`
# carries a stalled draft this system started to completion. All are the
# activity that *un*-silts the gate — indeed an abandoned draft is itself
# occupying one of the very back-pressure slots the cap is counting, and a
# conflicted or dequeued PR is one nothing can land to free a slot until it
# is fixed. So when back-pressure trips we do not stand down if
# any has work waiting; we restrict every repo's source list to those four.
#
# No new prompt machinery is needed for that, and deliberately so: the
# Co-Ordinator is already told the runtime input's `sources` are authoritative
# over its own table (requirement 15). Narrowing the list is therefore an
# instruction it already knows how to obey, and the restriction cannot be
# reasoned around — a source it cannot see is a source it cannot select.
# The system still cannot open a new PR while the gate is full; it can only
# finish what is already in it.
#
# "a conflicted or dequeued PR is one nothing can land to free a slot until
# it is fixed" above claims those two already hold a slot requirement
# 2.2's own count counts — but that count was taken before this cycle's
# merge-conflict and dequeued candidates were gathered (they arrive only
# once ordered_repos_json's sources are populated, in step 3), and neither
# gatherer's candidate rule reads `reviewDecision` at all
# (scripts/gather-merge-conflicts.sh, scripts/gather-dequeued.sh) — so a
# conflicted or dequeued PR that is not *also* `CHANGES_REQUESTED` passed
# through 2.2's count exactly like an ordinary human-queue PR. For `dequeued`
# it is not even a coincidence: a PR only reaches the merge queue after
# approval, so its `reviewDecision` is `APPROVED` by construction. Fold in,
# here, whatever `counted_prs_json` — 2.2's own record of which PRs its count
# held — does not already hold, so the trip decision made at this site
# actually reflects every slot that source occupies, not just the ones that
# happened to also be `CHANGES_REQUESTED`. `ordered_repos_json` already
# carries this cycle's `merge_conflicts`/`dequeued` candidates (gathered
# above, in step 3) whether or not back-pressure ends up tripped, so this
# runs unconditionally rather than only inside the `if` below.
# shellcheck disable=SC2154  # counted_prs_json: run_standdown_checks (lib/standdown.sh) assigns it.
finishing_extra_prs_json="$(jq -c --argjson counted "$counted_prs_json" '
    [.[] | . as $repo | (($repo.merge_conflicts // [])[], ($repo.dequeued // [])[]) | {slug: $repo.slug, number}]
    | unique_by([.slug, .number])
    | map(select(.number as $n | ($counted[.slug] // []) | index($n) | not))
  ' <<<"$ordered_repos_json" 2>&1)" \
  || { guard_warn "backpressure:finishing_extra_prs" "$finishing_extra_prs_json"; finishing_extra_prs_json='[]'; }
finishing_extra_count="$(jq 'length' <<<"$finishing_extra_prs_json" 2>/dev/null)" || finishing_extra_count=0
[[ "$finishing_extra_count" =~ ^[0-9]+$ ]] || finishing_extra_count=0
if (( finishing_extra_count > 0 )); then
  adjusted_open_count=$(( adjusted_open_count + finishing_extra_count ))
  open_composition="$open_composition + $finishing_extra_count merge-conflict/dequeued PR(s) occupying a slot the changes-requested count above did not"
  if (( adjusted_open_count >= max_open_agent_prs )); then
    backpressure_tripped=1
  fi
fi

if (( backpressure_tripped )); then
  finishing_waiting="$(jq '[.[].review_feedback[]?, .[].merge_conflicts[]?, .[].dequeued[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered_repos_json")"
  if (( finishing_waiting == 0 )); then
    log_event "stand-down" "$(jq -nc \
      --arg r "back-pressure: $adjusted_open_count open agent PRs with a pipeline-side next action >= $max_open_agent_prs ($open_composition), and no review feedback, merge conflict, dequeued pull request, or abandoned draft is waiting to be finished" \
      '{reason: $r}')"
    exit 0
  fi
  # `issues` and `tech_debt` are emptied along with the narrowing, not merely
  # left unwalked: they are the two arrays that carry a whole document each —
  # an issue's entire thread, a tech-debt item's entire file (requirement 3t) —
  # and a restricted cycle paying the Co-Ordinator to read candidates it is
  # forbidden to pick is the exact spend back-pressure exists to stop. The
  # other non-finishing arrays are compact enough that stripping them buys
  # nothing.
  #
  # Emptying `tech_debt` is also what keeps requirements 3t/3x's corroboration
  # honest, which is why `eligible_items_json` is computed below this and
  # not back at "3c/3u. Pre-fetched-band eligibility": a back-pressured cycle
  # forbids the tech-debt and issues sources outright, so its `selected: false`
  # owes no account of either, and measuring eligibility before the narrowing
  # would report every eligible item as unaccounted — a false contradiction every
  # restricted cycle, and one that would strip the no-op fingerprint exactly
  # when the gate is fullest. The narrowing of `sources` just below does the
  # same job for the bands this block leaves populated (`findings`,
  # `register_hygiene`, `human_visibility`): `coordinator_eligible_items` reads
  # the list, not the array.
  ordered_repos_json="$(handoff_narrow_repos_to_finishing_sources "$ordered_repos_json")"
  ordered_repos_json="$(jq -c '[.[] | .issues = [] | .tech_debt = []]' <<<"$ordered_repos_json")"
  log_event "warning" "$(jq -nc \
    --arg d "back-pressure: $adjusted_open_count open agent PRs with a pipeline-side next action >= $max_open_agent_prs ($open_composition) — restricted to finishing sources ($finishing_waiting PR(s) awaiting review-feedback, merge-conflict, dequeued, or abandoned-draft completion)" \
    '{detail: $d}')"
fi

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

# --- 3ac. The Co-Ordinator's prompt, fitted to its model's context window
#          (requirement 4i, agent-ops#641) ---
# The base prompt, rendered here rather than at "--- 4. Co-Ordinator stage ---"
# below, because the fit immediately after it cannot decide what the runtime
# input may spend until it knows what the prompt text has already spent. The
# substitution is the same one it has always been; only its position moved.
coordinator_base_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" coordinator "$prompt_overrides_json")"
coordinator_base_prompt="${coordinator_base_prompt//@@WORK_SOURCES_TABLE@@/$coordinator_sources_table}"

# On 2026-08-21 this Script assembled a Co-Ordinator prompt of ~226580 tokens
# against its model's 200000-token window, and the API refused it — four
# cycles running, every node, `coordinator exited 1`. Nothing had broken: the
# `issues` band had simply grown, one comment at a time, from ~212999 tokens
# three cycles earlier. Requirement 4g's own text had already named this
# shape — moving the aggregates off argv "raised the ceiling; it did not stop
# the set from still climbing toward whatever ceiling came next" — and this is
# the next ceiling, measured at last.
#
# The allowance handed to `coordinator_fit_bands` is what the configured
# maximum has left after everything the fit cannot shed, each term measured
# rather than assumed:
#
#   - the rendered base prompt, which is over 100 KB on its own;
#   - the fenced scaffolding the runtime input is wrapped in;
#   - the rest of the input document — `blocked`, `refinements`, `claimed`,
#     the model names and the refinement policy — assembled here from the very
#     same values "4. Co-Ordinator stage" will assemble the real one from, with
#     an empty `repos`, so what is subtracted is exactly what will be spent.
#
# Deriving the overhead against the *unfitted* array would be the tempting
# shortcut and is not what happens: the two differ by the indentation of the
# lines the fit removes, and an overhead measured on the fatter array would
# quietly narrow the allowance as the fit worked. Measuring it against an empty
# `repos` makes it independent of the rung, which is what lets the ladder's own
# measurements be trusted.
#
# Placed here, after back-pressure and before `coordinator_eligible_items`
# below, for the reason that block states of its own emptying of these same two
# bands: the eligible set must be what the Co-Ordinator is actually given, or
# requirement 3x's corroboration would demand an account of an entry the
# Script never offered.
# Initialised ahead of the guard because `set -u` is in force and the second
# `if` below reads it whichever way the first one went.
coordinator_fit_allowance=0
# Same reason, and the same `set -u` constraint, but initialised to a real
# empty-object value rather than left unset: the exemption-set gate far below
# (`coordinator_fit_trimmed_json`'s own `if`) has to read this whichever way
# the fit ran, and a bash parameter-expansion default of a bare pair of braces
# cannot stand in for that safely — `${parameter:-word}` closes on the *first*
# unquoted closing brace, so a bare-braces default reads as an open brace with
# a stray closing brace appended, and on every path where this variable
# actually was assigned a real fit report, that stray brace corrupted it into
# invalid JSON the gate silently read as "fit did not run" (agent-ops#933).
# Initialising here removes the default (and the trap) entirely: every reader
# below can use the value unconditionally.
coordinator_fit_report_json='{}'

# The Co-Ordinator's view of `refinements` (requirement 4j/issue #643),
# computed once, here, and spent unchanged by both the overhead measurement
# below and the input assembly under "--- 4. Co-Ordinator stage ---".
# `blocked` can afford to call its own view at both places because
# `coordinator_blocked_view` reads nothing but the array it trims; this one is
# scoped against `ordered_repos_json`, which the fit below reassigns, so
# calling it twice would measure the overhead against the unfitted candidate
# set and spend it against the fitted one — an error in the safe direction and
# still a measurement that is not of the thing it claims to be. Scoped against
# the unfitted array on purpose, for the same reason the overhead is measured
# against an empty `repos`: the fit only ever removes candidates, so this stays
# independent of the rung, and a spec kept for a candidate the ladder later
# sheds is a handful of bytes already accounted for.
#
# Unconditional, outside the bound's own guard: `coordinator_prompt_max_bytes`
# of `0` switches off the *fit*, not the Co-Ordinator's input document, and the
# assembly below reads this variable on every path.
coordinator_refinements_json="$(coordinator_refinements_view "$refinements_json" "$ordered_repos_json")"
if (( coordinator_prompt_max_bytes > 0 )); then
  coordinator_fit_blocked_json="$(coordinator_blocked_view "$blocked_json")"
  coordinator_fit_overhead_json="$(jq -nc \
    --argjson blocked "$coordinator_fit_blocked_json" \
    --arg model_default "$implementer_model_default" \
    --arg model_trivial "$implementer_model_trivial" \
    --arg label "$pr_label" \
    --argjson cmax "$candidates_max" \
    --argjson policies "$refinement_policy_json" \
    'input as $refinements | input as $claimed
     | {repos: [], blocked: $blocked, refinements: $refinements, claimed: $claimed,
        models: {default: $model_default, trivial: $model_trivial}, pr_label: $label,
        candidates_max: $cmax, refinement_policy: $policies}' \
    <<<"$coordinator_refinements_json"$'\n'"$claimed_json" 2>/dev/null)" \
    || coordinator_fit_overhead_json='{"repos":[]}'
  # The wrapper "4. Co-Ordinator stage" puts around the rendered input: a blank
  # line, the heading, the two fence lines and the trailing newline. Counted
  # rather than estimated so the arithmetic below has no unmeasured term in it.
  coordinator_fit_scaffold_bytes="$(printf '%s' '

## Runtime input for this cycle

```json
```
' | wc -c)"
  # Requirement 4i's own terms (issue #645): the same four values already
  # folded into `coordinator_fit_overhead_json` above, read individually
  # through the one rendering function this block already has
  # (`coordinator_rendered_bytes`), so a refusal's log line names which band
  # was actually big rather than only the combined total.
  coordinator_fit_prompt_bytes="$(printf '%s' "$coordinator_base_prompt" | wc -c)"
  coordinator_fit_blocked_bytes="$(coordinator_rendered_bytes <<<"$coordinator_fit_blocked_json")"
  coordinator_fit_refinements_bytes="$(coordinator_rendered_bytes <<<"$coordinator_refinements_json")"
  coordinator_fit_claimed_bytes="$(coordinator_rendered_bytes <<<"$claimed_json")"
  coordinator_fit_overhead_bytes=$((
    coordinator_fit_prompt_bytes
    + $(printf '%s' "$coordinator_fit_overhead_json" | coordinator_rendered_bytes)
    + coordinator_fit_scaffold_bytes ))
  # The remainder, not a fifth independent measurement: the fence wrapper, the
  # small and static scaffold fields (`models`, `pr_label`, `candidates_max`,
  # `refinement_policy`) and the JSON structure `coordinator_fit_overhead_json`
  # itself adds are not worth a byte count each, so this term is whatever is
  # left once the four measured bands are subtracted from the total — which
  # keeps the breakdown summing to `coordinator_fit_overhead_bytes` exactly.
  coordinator_fit_scaffold_term_bytes=$((
    coordinator_fit_overhead_bytes
    - coordinator_fit_prompt_bytes
    - coordinator_fit_blocked_bytes
    - coordinator_fit_refinements_bytes
    - coordinator_fit_claimed_bytes ))
  coordinator_fit_allowance=$(( coordinator_prompt_max_bytes - coordinator_fit_overhead_bytes ))
  coordinator_fit_terms_json="$(jq -nc \
    --argjson prompt "$coordinator_fit_prompt_bytes" \
    --argjson blocked "$coordinator_fit_blocked_bytes" \
    --argjson refinements "$coordinator_fit_refinements_bytes" \
    --argjson claimed "$coordinator_fit_claimed_bytes" \
    --argjson scaffold "$coordinator_fit_scaffold_term_bytes" \
    '{terms: {prompt: $prompt, blocked: $blocked, refinements: $refinements,
              claimed: $claimed, scaffold: $scaffold}}')"
fi
# An allowance that came out at or below zero is *not* the same fact as the
# bound being switched off, and must not go through the same door: the prompt
# text and the unsheddable half of the input have between them already spent
# the whole maximum, so no rung of the ladder can make this cycle's prompt fit
# — the remedy is a smaller unsheddable half (issue #643's own fix, the
# refinements view above) or a larger `coordinator_prompt_max_bytes`.
#
# What this case must *not* do is what it did between agent-ops#642 and #643:
# warn, fall past the fit entirely, and send the array whole. "The prompt is
# already too long" is the one circumstance in which shedding nothing is the
# worst available answer — on 2026-08-21 it put a 350,052-byte issues extract
# into a prompt that was over the window without it, and the API refused the
# stage on every node of the fleet for eight hours. A hopeless budget is still
# a budget: the ladder is walked to its last rung, the array comes back as
# small as it can be built, and the prompt goes out with the best chance the
# Script can give it rather than the worst.
#
# 1, not 0: `coordinator_fit_bands` reads a budget of 0 or less as "bound off"
# and hands the array back unchanged, which is precisely the behaviour this
# block exists to avoid. A budget of 1 fails every rung — prose first, then
# entry caps — and lands in that function's final branch, which returns the
# smallest array the ladder can build together with `fits: false`. The warning
# below still tells the operator the whole truth; the clamp just stops the
# cycle from making it worse on the way out.
if (( coordinator_prompt_max_bytes > 0 && coordinator_fit_allowance <= 0 )); then
  log_event "warning" "$(jq -nc \
    --arg d "the Co-Ordinator's prompt text and unsheddable input ($coordinator_fit_overhead_bytes bytes) already meet or exceed coordinator_prompt_max_bytes ($coordinator_prompt_max_bytes) — no runtime-input fit can make this cycle's prompt fit; shedding the candidate bands to the ladder's last rung anyway, and the API may still refuse it" \
    --argjson terms "$coordinator_fit_terms_json" \
    '{detail: $d} + $terms')"
  coordinator_fit_allowance=1
fi
if (( coordinator_prompt_max_bytes > 0 )); then
  coordinator_fit_json="$(coordinator_fit_bands "$coordinator_fit_allowance" <<<"$ordered_repos_json" 2>&1)" \
    || { guard_warn "coordinator_fit" "$coordinator_fit_json"; coordinator_fit_json=""; }
  if [[ -n "$coordinator_fit_json" ]] && jq -e '.repos | type == "array"' <<<"$coordinator_fit_json" >/dev/null 2>&1; then
    ordered_repos_json="$(jq -c '.repos' <<<"$coordinator_fit_json")"
    coordinator_fit_report_json="$(jq -c '.fit' <<<"$coordinator_fit_json")"
    coordinator_fit_detail_text="$(coordinator_fit_detail "$coordinator_fit_report_json")"
    if [[ -n "$coordinator_fit_detail_text" ]]; then
      # An informational record, not a warning: a fleet whose backlog has
      # outgrown the window will trim on every cycle from here on, and a
      # standing `warning` for the ordinary case is how a log stops being read.
      log_event "coordinator-input-fitted" "$(jq -nc --arg d "$coordinator_fit_detail_text" \
        --argjson f "$coordinator_fit_report_json" --argjson terms "$coordinator_fit_terms_json" \
        '{detail: $d} + $f + $terms')"
      # Not fitting is the other thing entirely: the identity fields alone have
      # outgrown the allowance, the ladder has nothing left to shed, and the
      # API will refuse the prompt this cycle is about to send. Say so *before*
      # it does, so the union log carries the cause rather than an exit code —
      # the exact gap agent-ops#641 was filed into.
      if ! jq -e '.fits' <<<"$coordinator_fit_report_json" >/dev/null 2>&1; then
        log_event "warning" "$(jq -nc --arg d "$coordinator_fit_detail_text" \
          --argjson terms "$coordinator_fit_terms_json" '{detail: $d} + $terms')"
      fi
    fi
  fi
fi
# --- end of requirement 4i's fit ---

# The fit's own exemption set for requirement 34e's fourth refusal and
# requirement 3x's matching completeness exception (agent-ops#683): which
# issues/tech-debt candidates this cycle's fit actually trimmed, `{repo,
# item, source}` per entry, on the same shape `coordinator_eligible_items`
# below produces. Read straight off `ordered_repos_json` as the fit above
# left it — never the pre-fit array, which carries none of the markers
# `coordinator_fit_trimmed_items` looks for — and only when the fit actually
# ran: an untouched array has nothing to find, and asking would cost a jq
# pass for an empty answer on every ordinary cycle.
coordinator_fit_trimmed_json="[]"
coordinator_fit_rung=0
if jq -e '.applied == true' <<<"$coordinator_fit_report_json" >/dev/null 2>&1; then
  coordinator_fit_trimmed_json="$(coordinator_fit_trimmed_items <<<"$ordered_repos_json")"
  coordinator_fit_rung="$(jq -r '.rung // 0' <<<"$coordinator_fit_report_json" 2>/dev/null || echo 0)"
fi

# The Script's own count of what *every* pre-fetched band could actually offer
# this cycle, and which repo+item+source triples make it up — the
# machine-corroboration baseline "5a. Verdict corroboration" below tests the
# Co-Ordinator's verdict against (requirement 3x, issue #322; requirement 3t
# measured only `tech_debt` here), and which requirement 3b's fingerprint
# hashes as part of each band's own array regardless. Taken here rather than at
# "3c/3u. Pre-fetched-band eligibility" so that it reads what the Co-Ordinator
# is actually about to be given: back-pressure just above empties `issues` and
# `tech_debt` and narrows every repo's `sources` to the four finishing ones,
# and an eligible set counted before that would hold items this cycle forbids
# it to select (see that block's own comment, and
# `coordinator_eligible_items`').
eligible_items_json="$(coordinator_eligible_items "$ordered_repos_json" "$blocked_json")"
eligible_items_total="$(jq 'length' <<<"$eligible_items_json" 2>&1)" \
  || { guard_warn "eligible_items_total" "$eligible_items_total"; eligible_items_total=0; }

# The count behind requirement 3x's trimmed exemption (agent-ops#683): how
# many of this cycle's eligible candidates the fit above actually trimmed —
# the ones `unaccounted_items` below no longer demands a `needs_refinement`/
# `voided` account for. Logged once per cycle whatever the Co-Ordinator went
# on to decide, because it is a fact about this cycle's input rather than
# about the verdict — and only where there is a count to log, so the ordinary
# cycle, whose fit trimmed nothing, carries no such record.
coordinator_unassessable_json="$(coordinator_unassessable_items "$eligible_items_json" "$coordinator_fit_trimmed_json")"
coordinator_unassessable_total="$(jq 'length' <<<"$coordinator_unassessable_json" 2>&1)" \
  || { guard_warn "coordinator_unassessable_total" "$coordinator_unassessable_total"; coordinator_unassessable_total=0; }
if (( coordinator_unassessable_total > 0 )); then
  log_event "coordinator-input-fit-unassessable" "$(jq -nc \
    --argjson n "$coordinator_unassessable_total" --argjson rung "$coordinator_fit_rung" \
    --arg d "the fit ladder trimmed $coordinator_unassessable_total of this cycle's eligible candidate(s) (rung $coordinator_fit_rung) — requirement 34e refuses a needs_refinement report against any of them, and requirement 3x's completeness check asks for none either" \
    '{detail: $d, unassessable_total: $n, rung: $rung}')"
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
  --arg md "$implementer_model_default" \
  --arg mt "$implementer_model_trivial" \
  --argjson cmax "$candidates_max" \
  --argjson nice "$repo_nice_json" \
  '{coordinator_model: $cm, models: {default: $md, trivial: $mt}, candidates_max: $cmax}
   + $nice')"
coordinator_prompt_sha="$(stage_prompt_sha "$PROMPTS_DIR" "$state_dir" coordinator "$prompt_overrides_json")"
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

# The Refiner's own inputs join the fingerprint for the same reason (requirement
# 39b): its candidate set turns on the same `refinements`/`blocked`/`void`
# state the fingerprint already carries, but a `refinement_policy` edit moves
# none of those and must still bust the no-op short-circuit on its own.
refiner_config_json="$(jq -nc \
  --arg m "$refiner_model" --arg lbl "$refined_label" --arg rmax "$refiner_max_per_engagement" \
  --argjson policy "$refinement_policy_json" \
  '{refiner_model: $m, refined_label: $lbl, refiner_max_per_engagement: $rmax, refinement_policy: $policy}')"
refiner_prompt_sha=""
[[ -f "$PROMPTS_DIR/refiner.md" ]] \
  && refiner_prompt_sha="$(stage_prompt_sha "$PROMPTS_DIR" "$state_dir" refiner "$prompt_overrides_json")"

# The eight fleet-state arrays arrive on stdin, one JSON document per line,
# bound positionally below in the order printed — never in argv (requirement
# 4g). Each `--argjson` value is a single argv entry capped at MAX_ARG_STRLEN
# (131072 bytes), and on 2026-08-12 the void extract alone crossed it: this
# unguarded call then died at execve with `Argument list too long`, exit 126,
# on every cycle of every node, before the Co-Ordinator ran — and without an
# `attempt-failed` for requirement 2.7's crash-loop ladder to count. Only
# values bounded by configuration stay in argv. A here-string rather than a
# pipe, for requirement 4c's reason: under `pipefail` a producer's SIGPIPE
# must not become this assignment's status.
noop_stdin="$(printf '%s\n' \
  "$ordered_repos_json" "$source_states_json" "$blocked_json" "$void_json" \
  "$refinements_json" "$claimed_json" "$enabler_eligible_json" "$refiner_candidates_json")"
noop_input="$(jq -nc \
  --argjson sc "$selection_config_json" \
  --argjson ec "$enabler_config_json" \
  --arg psha "$coordinator_prompt_sha" \
  --arg esha "$enabler_prompt_sha" \
  --arg wst "$coordinator_sources_table" \
  --argjson rc "$refiner_config_json" \
  --arg rsha "$refiner_prompt_sha" \
  'input as $repos | input as $states | input as $blocked | input as $void
   | input as $refinements | input as $claimed | input as $eligible | input as $rcand
   | {
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
     coordinator_work_sources_table: $wst,
     refiner_candidates: $rcand,
     refiner_config: $rc,
     refiner_prompt_sha: $rsha
   }' <<<"$noop_stdin")"
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

# Requirement 3u/issue #320: `void` is never sent to the Co-Ordinator at all.
# Every band the Script pre-fetches whole is already void-filtered before this
# point (the loop above), and the three sources the Co-Ordinator still derives
# itself — project-review, failed-runs, implementation-plan — have no
# pre-fetched array for the Script to filter, exactly as before this change;
# what has stopped is handing the model a raw list to apply that same
# judgement to by eye. "Voiding an item yourself" (prompts/coordinator.md) is
# unaffected: the model can still report a fresh `voided` entry from evidence
# it read this cycle, and the Script's own void corroboration (requirement
# 34d) validates it independently, with no existing list to compare against.
# `void_json` still joins the no-op fingerprint above unchanged — a fresh void
# state must still buy the next cycle a fresh look even though the model
# itself never reads it.
#
# `blocked` stays, but trimmed by coordinator_blocked_view (above) to the
# fields "Re-checking blocked items" and "A blocked issue with fresh evidence
# must be re-read" actually read. Every other pre-fetched band's own blocked
# entries never reach the Co-Ordinator either (the loop above already
# excluded them), so what remains of this list's purpose is `issues`' live
# re-check duty and the three Co-Ordinator-derived sources' own exclusion-1
# check.
coordinator_blocked_json="$(coordinator_blocked_view "$blocked_json")"

# The four fleet-state arrays on stdin, never in argv (requirement 4g) — the
# same delivery, order coupling and here-string reasoning as the no-op
# fingerprint's build above.
coordinator_stdin="$(printf '%s\n' \
  "$ordered_repos_json" "$coordinator_blocked_json" "$coordinator_refinements_json" "$claimed_json")"
coordinator_input="$(jq -nc \
  --arg model_default "$implementer_model_default" \
  --arg model_trivial "$implementer_model_trivial" \
  --arg label "$pr_label" \
  --argjson cmax "$candidates_max" \
  --argjson policies "$refinement_policy_json" \
  'input as $repos | input as $blocked | input as $refinements | input as $claimed
   | {repos: $repos, blocked: $blocked, refinements: $refinements, claimed: $claimed,
      models: {default: $model_default, trivial: $model_trivial}, pr_label: $label,
      candidates_max: $cmax, refinement_policy: $policies}' <<<"$coordinator_stdin")"

# --- 4. Co-Ordinator stage ---
# `coordinator_base_prompt` is rendered further up, ahead of requirement 4i's
# fit, because that fit has to know how many of the window's bytes the prompt
# text itself has already spent before it can decide what the runtime input may
# have.
coordinator_prompt="$coordinator_base_prompt

## Runtime input for this cycle

\`\`\`json
$(jq . <<<"$coordinator_input")
\`\`\`
"
coordinator_out="$cycle_dir/coordinator.out"

# The Co-Ordinator runs *before* selection, so it has no repository either
# and is keyed `*` for the same reason as the Enabler (requirement 4f).
selected_by_fallback=0
if ! run_coordinator_stage_attempt "$coordinator_out" "$coordinator_prompt"; then
  exit 0
fi
# shellcheck disable=SC2154  # coord_attempt_result_json: run_coordinator_stage_attempt (lib/stage-attempt.sh) assigns it.
work_order_json="$coord_attempt_result_json"

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
  if ! coordinator_corroborate_retry_or_fallback; then
    exit 0
  fi
fi

# --- 5b. Candidates, and the claim (requirement 17a) ---
# The Co-Ordinator returns a ranked candidate list; the former single-selection
# shape is accepted for one release as a one-candidate list. The claim itself
# is taken by the Script, never the model: keys are derived deterministically
# (two nodes must compute the same name for the same item), the write is
# create-only so GitHub arbitrates the race, and a lost race just moves down
# the ranking instead of costing the cycle.
#
# A fallback selection (requirement 3v, issue #321) has already built its own
# one-candidate `candidates_json` above — `fallback_select_candidate`'s output
# is a single candidate object, not a work order with its own `.candidates`
# array, so it must not be re-derived here the way a real work order's is.
if (( selected_by_fallback )); then
  :
elif jq -e '.candidates | type == "array"' <<<"$work_order_json" >/dev/null 2>&1; then
  candidates_json="$(jq -c '.candidates' <<<"$work_order_json")"
else
  candidates_json="$(jq -c '[del(.selected, .unblocked, .recheck_clean, .voided)]' <<<"$work_order_json")"
fi

if (( DRY_RUN )); then
  # A dry run claims nothing: record the top of the ranking and stop.
  log_event "selection" "$(jq -c --argjson fb "$selected_by_fallback" \
    '.[0] | {repo, item, source, model, title} + (if $fb == 1 then {selected_by: "script-fallback"} else {} end)' \
    <<<"$candidates_json")"
  exit 0
fi

# The gather-time claims, snapshotted before `claimed_json` is reused just
# below as the claim loop's winner slot: the loop's pre-claim check reads
# what this cycle's own gather saw, and reading it out of a variable about
# to be overwritten would silently compare against nothing.
claims_at_gather_json="$claimed_json"
claimed_json=""
n_cand="$(jq 'length' <<<"$candidates_json")"
claim_attempts=0
claim_unreachable=0
# race_losses (requirement 17d): how many candidates this cycle lost to a
# peer genuinely holding the item (cause "held" — healthy contention, not an
# outage), distinct from `claim_unreachable`. Carried on both the eventual
# `selection` (only when it recovered from a loss — issue #245) and the
# all-claimed `stand-down` below, so a rising rate is visible without
# cross-referencing `claim-lost` events by hand — the observability
# finish-then-continue and the faster cadence both raise the concurrent-claim
# frequency for (#248).
race_losses=0
# claim_skips: candidates dropped without an attempt because this cycle's own
# gather already saw them claimed (candidate_preclaimed above). Deliberately
# not folded into race_losses: a loss knowable from data in hand is the
# Co-Ordinator proposing claimed work — a selection defect — where a race
# loss is healthy contention, and the dashboard's `↻ raced` badge must keep
# meaning only the second.
claim_skips=0
# trace_faults: candidates dropped by requirement 17f that the repair above
# could not rescue. Counted separately from both of the above for the reason
# issue #767 exists: without it, a cycle whose every candidate failed
# traceability left `claim_attempts` and `claim_skips` at zero and fell
# through the reason ladder below to `raced` — reporting healthy contention,
# with `race_losses: 0` and not one `claim-lost` event to its name, for 15
# hours. A stand-down that names the wrong cause is worse than one that names
# none: it sends the reader after a claim problem that was never there.
trace_faults=0
# fab_faults: candidates dropped by requirement 17g (issue #821) — a trimmed
# candidate whose acceptance names a specific detail the live item text does
# not support. Counted apart from trace_faults for the same reason issue
# #767 already split trace_faults from race_losses: a fabrication is never
# repaired (unlike a missing refinement), so a cycle that loses every
# candidate this way must not fall through to `raced` or get folded into
# `untraceable` — either would send the reader after the wrong defect.
fab_faults=0
for (( ci = 0; ci < n_cand; ci++ )); do
  cand="$(jq -c --argjson i "$ci" '.[$i]' <<<"$candidates_json")"
  c_repo="$(jq -r '.repo // ""' <<<"$cand")"
  c_item="$(jq -r '.item // ""' <<<"$cand")"
  c_source="$(jq -r '.source // ""' <<<"$cand")"
  c_db="$(jq -r '.default_branch // "main"' <<<"$cand")"
  c_takeover="$(jq -r '.takeover // false' <<<"$cand")"
  [[ -n "$c_repo" && -n "$c_item" ]] || continue
  # Requirement 17g (issue #821): checked before requirement 17f below, and
  # before the pre-claimed check further down — cheaper and unrelated to
  # either. Guarded by `selected_by_fallback` for the same reason 17f's own
  # check is: a fallback pick's `context` is Script-built from the entry's
  # own record (lib/stage-attempt.sh's `fallback_select_candidate`), never
  # from prose a model wrote, so it cannot fabricate anything and this would
  # only ever cost a wasted `gh` read there.
  c_fab_fault=""
  (( selected_by_fallback )) \
    || c_fab_fault="$(item_text_fault "$cand" "$coordinator_fit_trimmed_json" "$refinements_json")"
  if [[ -n "$c_fab_fault" ]]; then
    # Never repaired (requirement 17g): appending the real text alongside a
    # false one does not make the false one true, so unlike requirement 17f's
    # own fault this is always a hard skip.
    fab_faults=$(( fab_faults + 1 ))
    log_event "claim-skipped" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" --arg d "$c_fab_fault" \
      '{repo: $r, item: $i, source: $s, cause: "fabricated", detail: $d}')"
    continue
  fi
  # Requirement 17f (issue #626): checked before the pre-claimed check below,
  # cheaper and unrelated to it — a candidate that fails traceability is
  # never safe to hand to an Implementer regardless of whether it is also
  # already claimed elsewhere.
  #
  # Scoped to a model-composed work order, which is the only kind that can
  # carry another item's refinement at all: a fallback pick (requirement 3v)
  # is built by `fallback_select_candidate` out of the very band entry it
  # names, in jq, so a cross-item swap is not a shape it can take. It also
  # composes `context` from that entry's own record and never from
  # `refinements`, so a spec-refined item picked mechanically would fail the
  # verbatim check every single time — and, the fallback's own candidate list
  # being one candidate long, faulting it would leave the cycle with nothing
  # to claim, disarming the one path that exists to keep the fleet moving
  # when the model will not select.
  c_trace_fault=""
  c_repaired=""
  (( selected_by_fallback )) \
    || c_trace_fault="$(refinement_traceability_fault "$cand" "$refinements_json")"
  if [[ -n "$c_trace_fault" ]]; then
    # Supply the refinement rather than discard the work (issue #767). The
    # Script is holding the text while it asks whether the model copied it,
    # so the honest move is to write it in and let the item through — 17b/20
    # require the work order to *carry* the refinement, not the model to have
    # been the one who carried it. `refinement_traceability_repair` declines
    # the one fault where appending is unsafe (a `comment_url` naming a
    # different issue: corrupt ledger, and the very cross-item swap #626 is
    # about), so a fault that survives the repair is still a hard skip.
    c_repaired="$(refinement_traceability_repair "$cand" "$refinements_json")"
    if [[ -n "$c_repaired" ]] \
       && [[ -z "$(refinement_traceability_fault "$c_repaired" "$refinements_json")" ]]; then
      cand="$c_repaired"
      log_event "work-order-repaired" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" --arg d "$c_trace_fault" \
        '{repo: $r, item: $i, source: $s, cause: "untraceable", detail: $d}')"
      c_trace_fault=""
    fi
  fi
  if [[ -n "$c_trace_fault" ]]; then
    trace_faults=$(( trace_faults + 1 ))
    log_event "claim-skipped" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" --arg d "$c_trace_fault" \
      '{repo: $r, item: $i, source: $s, cause: "untraceable", detail: $d}')"
    continue
  fi
  # Requirement 17g's other half: a trimmed candidate that cleared
  # item_text_fault above wrote nothing false, but may still have written
  # something incomplete. Supply the live text itself so the Implementer
  # never starts from less than the item actually says — a no-op
  # (prints nothing) when context already carries it in full.
  if (( ! selected_by_fallback )); then
    c_supplied="$(item_text_supply "$cand" "$coordinator_fit_trimmed_json")"
    if [[ -n "$c_supplied" ]]; then
      cand="$c_supplied"
      log_event "work-order-repaired" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" \
        '{repo: $r, item: $i, source: $s, cause: "trimmed"}')"
    fi
  fi
  if candidate_preclaimed "$c_repo" "$c_item" "$claims_at_gather_json"; then
    claim_skips=$(( claim_skips + 1 ))
    log_event "claim-skipped" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg s "$c_source" \
      '{repo: $r, item: $i, source: $s, cause: "pre-claimed"}')"
    continue
  fi
  claim_attempts=$(( claim_attempts + 1 ))
  claim_rc=0
  pr_claim_lost=0
  c_pr_key=""
  if [[ "$c_source" == "review-feedback" || "$c_source" == "abandoned-drafts" \
        || "$c_source" == "dequeued" \
        || ( "$c_source" == "merge-conflicts" && "$c_takeover" != "true" ) ]]; then
    # No new branch to create — the PR already exists (a human's review round for
    # review-feedback, this system's own stalled draft for abandoned-drafts, a
    # ready-but-conflicted PR of ours for merge-conflicts, a checks-failure-
    # dequeued PR of ours for dequeued). The lock is a
    # create-only registry file keyed on the item ref, not a branch create that
    # would 422 against the branch already there.
    #
    # A `merge-conflicts` candidate carrying `takeover: true` (requirement 3s,
    # issue #250) is the one exception: it names Dependabot's PR, not one of
    # ours, and taking it over means a genuinely new PR on a genuinely new
    # branch — the ordinary branch-claim path below, same as any fresh item.
    claim_kind="file"; claim_key="$c_item"
    c_branch="$(jq -r '.branch // ""' <<<"$cand")"
    c_pr_number="$(pr_number_for_candidate "$cand" "$c_item")"
    CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$c_item" CLAIM_SOURCE="$c_source" \
      CLAIM_PR_NUMBER="$c_pr_number" \
      "$SCRIPT_DIR/lib/claim.sh" claim file "$c_repo" "$c_item" \
      >>"$cycle_dir/claim.log" 2>&1 || claim_rc=$?
    if (( claim_rc == 0 )) && [[ -n "$c_pr_number" ]]; then
      # Issue #238: the item claim just won is scoped to this round/head SHA
      # (requirements 3c/3e/3g), so it excludes nothing about a peer working the
      # *same PR* under a different item ref — which is exactly how PR #205 was
      # worked by three nodes at once. A second, PR-keyed file claim taken here,
      # alongside it, is what actually excludes fleet-wide: GitHub arbitrates it
      # the same create-only way. Losing it means a peer holds this PR already
      # (under whatever ref won there); nothing was pushed under the item claim
      # yet, so release it and fall through to the next candidate exactly as a
      # lost item claim would — carrying this claim's *own* rc outward, not a
      # flattened 3, so that an unreachable GitHub here still reads as rc 1 and
      # still counts toward the outage stand-down below rather than being
      # miscounted as a fleet politely yielding to itself.
      c_pr_key="pr-${c_pr_number}"
      pr_claim_rc=0
      CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$c_item" CLAIM_SOURCE="$c_source" \
        CLAIM_PR_NUMBER="$c_pr_number" \
        "$SCRIPT_DIR/lib/claim.sh" claim file "$c_repo" "$c_pr_key" \
        >>"$cycle_dir/claim.log" 2>&1 || pr_claim_rc=$?
      if (( pr_claim_rc != 0 )); then
        timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release file "$c_repo" "$c_item" \
          >>"$cycle_dir/claim.log" 2>&1 || true
        claim_rc=$pr_claim_rc
        pr_claim_lost=1
      fi
    fi
  else
    c_branch="$(claim_branch_for "$c_source" "$c_item")"
    claim_kind="branch"; claim_key="$c_branch"
    CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$c_item" CLAIM_SOURCE="$c_source" \
      "$SCRIPT_DIR/lib/claim.sh" claim branch "$c_repo" "$c_branch" "$c_db" \
      >>"$cycle_dir/claim.log" 2>&1 || claim_rc=$?
  fi
  if (( claim_rc == 0 )); then
    claim_active=1
    claim_pr_key="$c_pr_key"
    claimed_json="$(jq -c --arg b "$c_branch" '. + {branch: $b}' <<<"$cand")"
    break
  fi
  # 3 = a peer holds it (healthy contention: the work is being done, just not
  # by this node) — 1 = GitHub was unreachable (fail-closed: this node could
  # not have pushed the work either, but no work is being done by anyone).
  # Opposite operational conditions, so `cause` tells them apart instead of
  # the event wearing one reason for both. `pr-held` is the same healthy
  # contention as `held`, distinguished only so a reader can tell the two
  # claims apart: this candidate's own item claim won, but a peer already
  # holds the PR it targets under a different item ref. It renames `held`
  # alone — an `unreachable` PR-keyed claim is still an outage and must still
  # be counted as one, or a fleet-wide outage during the second claim would
  # stand down reporting contention that never happened.
  case "$claim_rc" in
    3) claim_cause="held"; race_losses=$(( race_losses + 1 )) ;;
    1) claim_cause="unreachable"; claim_unreachable=$(( claim_unreachable + 1 )) ;;
    *) claim_cause="$claim_rc" ;;
  esac
  if (( pr_claim_lost )) && [[ "$claim_cause" == "held" ]]; then
    claim_cause="pr-held"
  fi
  log_event "claim-lost" "$(jq -nc --arg r "$c_repo" --arg i "$c_item" --arg b "$c_branch" \
    --argjson rc "$claim_rc" --arg cause "$claim_cause" --arg pr "$c_pr_key" \
    '{repo: $r, item: $i, branch: $b, rc: $rc, cause: $cause} + (if $pr == "" then {} else {pr_claim_key: $pr} end)')"
  # claim-race-duplicate (docs/FLOW-SCHEMA.md, D23): only `held`/`pr-held` —
  # healthy contention, a peer genuinely already working this item — is a
  # repetition; `unreachable` is an outage and any other cause is a selection
  # defect, neither of which is "work duplicated by a race". The same
  # distinction scripts/pickup-metrics.sh's own header draws and reuses
  # (issue #596's own instruction: reuse that rule, do not restate it
  # differently).
  rework_claim_race_json="$(rework_claim_race_duplicate_fields "$claim_cause" "$claim_rc" "$c_repo" "$c_item")"
  [[ -n "$rework_claim_race_json" ]] && log_event "rework" "$rework_claim_race_json"
done

if [[ -z "$claimed_json" ]]; then
  # Same test as the reason text below, structured: a fleet-wide dashboard
  # reader (or any other consumer) needs "why did this cycle stand down?"
  # without re-parsing prose (issue #245). `raced` means every candidate was
  # lost to healthy contention (at least one `held`); `unreachable` means
  # GitHub itself could not be reached for any of them — an outage, not the
  # fleet politely yielding to itself; `pre-claimed` means nothing was ever
  # attempted, because every candidate was one this cycle's own gather had
  # already seen claimed — not contention at all, but the Co-Ordinator
  # proposing claimed work past both the deterministic filters and its own
  # exclusion 3, which is a selection defect worth its own name.
  if (( claim_attempts > 0 && claim_unreachable == claim_attempts )); then
    standdown_reason="GitHub could not be reached for any candidate — this is an outage, not contention"
    standdown_cause="unreachable"
  elif (( claim_attempts == 0 && claim_skips > 0 )); then
    standdown_reason="every candidate was already claimed before this cycle's Co-Ordinator ran — skipped without an attempt"
    standdown_cause="pre-claimed"
  elif (( claim_attempts == 0 && fab_faults > 0 )); then
    # Requirement 17g (issue #821): every candidate's acceptance named a
    # specific detail its own trimmed, live-checked item text does not
    # support, and — unlike requirement 17f's own fault — that is never
    # repaired. Named apart from `untraceable` so a reader can tell a
    # copying failure from an invention.
    standdown_reason="every candidate failed the trimmed-item fabrication check — no claim was attempted"
    standdown_cause="fabricated"
  elif (( claim_attempts == 0 && trace_faults > 0 )); then
    # Requirement 17f dropped every candidate and the repair could not rescue
    # one (issue #767). Nothing was claimed, nothing was raced, and nothing
    # about the fleet is busy — this is a defect in the work orders reaching
    # the gate, and it is named as one so no reader mistakes it for
    # contention again.
    standdown_reason="every candidate failed the refinement traceability check — no claim was attempted"
    standdown_cause="untraceable"
  else
    standdown_reason="every candidate is already claimed elsewhere"
    standdown_cause="raced"
  fi
  # A raced stand-down chains (requirement 39): a cycle that lost every
  # attempted claim to peers has spent its Co-Ordinator learning the fleet
  # is busy, not that the fleet is done — `ordered_repos_json` still says
  # sources remain, and the winners' claims are visible to a fresh gather
  # now in a way they were not when this cycle gathered, so the chained
  # cycle's own deterministic filters route it to the next-best item
  # instead of the same fight. The same bounded price (`max_chained_cycles`)
  # a productive chain pays. The other four causes never chain: against an
  # `unreachable` GitHub a fresh cycle buys a second Co-Ordinator engagement
  # and the same empty-handed ending; after a `pre-claimed` stand-down — a
  # selection defect, not contention — an identical re-run is more likely to
  # repeat the defect than to route around it; and an `untraceable` or
  # `fabricated` stand-down is the Script's own construction-time check
  # refusing to hand a candidate on — no peer's claim or absence explains
  # either fault, so a fresh cycle would spend its chain budget re-composing
  # the same broken work order rather than routing around a peer.
  if [[ "$standdown_cause" == "raced" ]] \
      && ! (( ONCE )) \
      && chain_should_continue "$chain_count" "$max_chained_cycles" "$ordered_repos_json"; then
    chain_eligible=1
  fi
  log_event "stand-down" "$(jq -nc --argjson n "$n_cand" --arg r "$standdown_reason" --arg c "$standdown_cause" \
    --argjson rl "$race_losses" --argjson sk "$claim_skips" \
    --argjson tf "$trace_faults" --argjson ff "$fab_faults" \
    '{reason: $r, candidates: $n, cause: $c, race_losses: $rl}
     + (if $sk > 0 then {claim_skips: $sk} else {} end)
     + (if $tf > 0 then {trace_faults: $tf} else {} end)
     + (if $ff > 0 then {fab_faults: $ff} else {} end)')"
  exit 0
fi

work_order_json="$claimed_json"
selected_repo="$(jq -r '.repo // ""' <<<"$work_order_json")"
selected_item="$(jq -r '.item // ""' <<<"$work_order_json")"
selected_source="$(jq -r '.source // ""' <<<"$work_order_json")"
selected_branch="$(jq -r '.branch // ""' <<<"$work_order_json")"
selected_source="$(jq -r '.source // ""' <<<"$work_order_json")"
selected_default_branch="$(jq -r '.default_branch // "main"' <<<"$work_order_json")"
# `race_losses` is present only when this selection recovered from at least
# one lost claim (issue #245) — an ordinary first-try selection, still the
# overwhelming majority, carries nothing new on this event. `selected_by`
# (requirement 3v, issue #321) is present only for a mechanical fallback pick,
# so the dashboard and the verdict-quality metrics can tell model picks from
# fallback picks apart without cross-referencing the corroboration events.
log_event "selection" "$(jq -c --argjson n "$race_losses" --argjson fb "$selected_by_fallback" \
  '{repo, item, source, model, title, branch} + (if $n > 0 then {race_losses: $n} else {} end)
   + (if $fb == 1 then {selected_by: "script-fallback"} else {} end)' \
  <<<"$work_order_json")"

# Rework record (docs/FLOW-SCHEMA.md, D23, issue #596): three of the nine
# classes are detected the moment a finishing source is selected — the
# candidate itself (gather-review-feedback.sh, gather-merge-conflicts.sh,
# gather-abandoned-drafts.sh) is the detector, and selection is this cycle's
# own commitment to reworking it, tied to {repo, item, pr_url}.
# `rework_selection_fields` prints nothing for any other source.
rework_selection_fields_json="$(rework_selection_fields "$work_order_json")"
[[ -n "$rework_selection_fields_json" ]] && log_event "rework" "$rework_selection_fields_json"

# Finish-then-continue (requirement 39): a claim just won is real work, and
# `ordered_repos_json` — gathered once, ahead of the Co-Ordinator, and
# untouched since — is cheap evidence of whether more might be waiting
# (lib/chain.sh). `--once` is a human or a test asking for exactly one
# cycle, not an unattended tick, so it never chains regardless. The next
# chained cycle runs its own Co-Ordinator, with its own fresh gather and its
# own no-op fingerprint, so this is only ever a cheap "was it worth asking
# again", never a prediction of what that cycle will find. Set before the
# pre-flight check below so that even a cycle that voids out here — real
# work, just none of it left to do — still chains rather than wasting the
# rest of its tick.
if ! (( ONCE )) && chain_should_continue "$chain_count" "$max_chained_cycles" "$ordered_repos_json"; then
  chain_eligible=1
fi

# --- 5c. Pre-flight already-done check (issue #245) ---
# Deterministic, no LLM, run before the clone and the Implementer engagement
# either one is paid for: ask whether the item this cycle just claimed is
# already done — its register row resolved, its issue closed, its
# work-order branch already merged, or (for a finishing source, whose item is
# the `pr-<n>-…` shape `lib/work-gone.sh` recognises) its pull request
# already closed or merged — and, separately, whether it should be *deferred*
# because an open PR already carries the just-claimed branch (a non-terminal
# signal; see below).
# `source_states_json` already carries every repo this cycle walked, gathered
# well before the claim, which is all an issue, a finishing source's PR or the
# stale-open-PR check needs; a tech-debt item additionally needs its own
# fresh register read, because a freshly claimed item was never a member of
# the blocked set `register_status_json` is scoped to.
preflight_register_json='{}'
if [[ "$selected_source" == "tech-debt" ]]; then
  preflight_register_json="$(jq -nc --arg s "$selected_repo" \
    --argjson m "$(gather_register_status "$selected_repo" "$selected_default_branch" selected "$selected_item")" \
    '{($s): $m}')"
fi
preflight_reason="$(preflight_done_reason "$selected_repo" "$selected_item" "$selected_branch" \
  "$source_states_json" "$preflight_register_json")"
# The ancestry check is the one live `gh` call in this section (lib/preflight.sh's
# header explains why it is gated to the four sources whose branch predates the
# claim), so it only runs when the cheaper, pure checks above found nothing.
if [[ -z "$preflight_reason" ]] && preflight_existing_branch_source "$selected_source"; then
  preflight_reason="$(preflight_branch_merged_reason "$selected_repo" "$selected_default_branch" "$selected_branch")"
fi
if [[ -n "$preflight_reason" ]]; then
  log_item_void "preflight" "$preflight_reason" \
    "$(jq -nc --arg e "$preflight_reason" '{evidence: $e}')"
  release_claim no-pr
  exit 0
fi
# The stale-open-PR signal defers rather than voids (requirement 34m; #279):
# it is the one pre-flight fact that can become false again — that pull
# request may close unmerged tomorrow — and its usual cause is the digest's
# own staleness, sampled before the Co-Ordinator engagement. A void is
# terminal (requirement 34h), so the claim is released and the item left for
# a later cycle's fresh digest instead.
preflight_defer="$(preflight_defer_reason "$selected_repo" "$selected_item" "$selected_branch" \
  "$source_states_json")"
if [[ -n "$preflight_defer" ]]; then
  log_event "warning" "$(jq -nc \
    --arg d "pre-flight deferred $selected_repo $selected_item — $preflight_defer; claim released, the item is re-judged against a fresh digest next cycle" \
    '{detail: $d}')"
  release_claim no-pr
  exit 0
fi

# --- 6. Workspace ---
repo_slug="$(jq -r '.repo' <<<"$work_order_json")"
impl_model="$(jq -r '.model' <<<"$work_order_json")"

clone_dir="$workspace_root/$cycle_id"
assert_in_workspace "$clone_dir"
# `clone_repo` (lib/repo-clone.sh) — `git clone`, not `gh repo clone`, because
# `gh` resolves the repository through a GraphQL query that is billed against
# the API budget, and this is the last step before the cycle's expensive stage.
# That file holds the full reasoning and the `CLONE_GIT` test seam; both
# pipelines clone through it so they cannot diverge.
if ! clone_repo "$repo_slug" "$clone_dir" 2>"$cycle_dir/clone.err"; then
  log_event "attempt-failed" "$(jq -nc --arg d "$(cat "$cycle_dir/clone.err")" '{stage: "workspace", detail: $d}')"
  # The claim was taken before the clone; a cycle that ends here must not
  # keep holding the item (requirement 17a's release rules).
  release_claim no-pr
  exit 0
fi

# --- 6a. Labels (requirement 6a) ---
# The gather loop above ("Labels (requirement 6a, agent-ops#687)") already
# ensured $repo_slug's `target` catalogue this cycle, but only if its stamp
# had gone stale — a fresh stamp skips the listing there entirely, and a
# fresh stamp only guarantees the label existed at the *last* listing, not
# now. A stamp this fresh is exactly the state in which nothing else is
# still looking, so `pr_label` deleted since then would go unnoticed for up
# to `labels_ensure_interval_hours` (24h default) — and the Implementer is
# one `gh pr create --label` away from losing its whole run to that gap. So
# the selected repository still gets its own unconditional, unstamped
# listing here, immediately before the stage that needs the label to
# exist — one extra listing per cycle, the same cost main paid before
# agent-ops#687, for the one repository where a miss is most expensive.
ensure_labels_for() {
  local slug="$1" role="$2" report
  report="$(labels_ensure_role "$CONFIG_FILE" "$SCHEMA_FILE" "$slug" "$role" 2>/dev/null || true)"
  [[ -n "$report" ]] || return 0
  log_event "labels-ensured" "$(jq -nc --arg repo "$slug" --arg role "$role" \
    --arg report "$report" '
    {repo: $repo, role: $role}
    + ($report | split("\n") | map(select(length > 0) | split("\t"))
       | {created: [.[] | select(.[0] == "created") | .[1]],
          failed:  [.[] | select(.[0] == "failed")  | .[1]]})')"
}
ensure_labels_for "$repo_slug" target

# --- 7. Implementer stage ---
implementer_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" implementer "$prompt_overrides_json")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`

## Cycle

$cycle_id

## Node

$node_name
"
impl_out="$cycle_dir/implementer.out"

stage_budget_apply implementer "$selected_repo" "$impl_model"
if run_claude_stage implementer "$(( stage_backstop_min * 60 ))" "$impl_model" "$implementer_prompt" "$impl_out" "$clone_dir" "$(( stage_inactivity_min * 60 ))"; then
  impl_rc=0
else
  impl_rc=$?
fi
# shellcheck disable=SC2154  # stage_kill_reason/stage_gaps_json: run_claude_stage (lib/stage-run.sh) assigns both.
log_event "stage-end" "$(jq -nc --argjson rc "$impl_rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$impl_model" "$impl_out" "$stage_gaps_json")" \
  '{stage: "implementer", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
rework_stage_rerun_maybe "implementer" "$stage_kill_reason" "$selected_repo" "$selected_item"
# `if`, not `&&`: an empty warning is the common case, and a trailing
# `&&` whose test fails is a non-zero status at exactly the place
# `set -e` acts on — the same trap that cost a --once cycle its
# failure handling at dump_stage_output.
watchdog_warning="$(stage_watchdog_warning implementer || true)"
if [[ -n "$watchdog_warning" ]]; then
  log_event "warning" "$watchdog_warning"
fi
(( ONCE )) && dump_stage_output "$impl_out"

impl_result="$(jq -r '.result // empty' "$impl_out" 2>/dev/null || true)"
impl_status_json="$(extract_json_result "$impl_result" 2>/dev/null || true)"
if (( impl_rc == 0 )) && [[ -z "$impl_status_json" ]]; then
  impl_status_json="$(stage_salvage_result implementer "$impl_out" "$impl_model" "$clone_dir" || true)"
fi
# Requirement 9's fallback chain, cheapest first and least dependent on the
# stage last. The first three all read something the Implementer had to do:
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

# A reported `void` is the Implementer saying the work order describes no work —
# the item is already done on default_branch, or its premise is otherwise false.
# It is terminal (requirement 34c): no agent may clear it, because the only
# evidence that would ever arrive ("it's already done") is the reason it is void
# in the first place. Recording this as `blocked` instead is what let an
# already-done recommendation be unblocked by the next Co-Ordinator and
# re-selected indefinitely.
if (( impl_rc == 0 )) && [[ "$impl_status" == "void" ]]; then
  # Requirement 34d, extended by issue #243 from the Co-Ordinator alone to
  # every stage: the Implementer reads the tree itself (requirement 27b), but
  # that does not stop a model citing the wrong artefact from it — see
  # lib/void-guard.sh's own note on issue #243. `repos` is passed as `[]`: the
  # Implementer gathers no per-cycle candidate list, so `void_guard_reason`'s
  # PR-diff check (Co-Ordinator only) simply has nothing to test against; the
  # citation check needs nothing from it.
  impl_void_entry="$(jq -nc --arg r "$selected_repo" --arg i "$selected_item" \
    --arg reason "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    --argjson x "$impl_status_json" '{repo: $r, item: $i, reason: $reason, evidence: ($x.evidence // "")}')"
  if impl_void_refusal="$(void_guard_reason "$impl_void_entry" '[]' "$(void_obsolete_ctx_json "$selected_repo")")"; then
    log_item_void "implementer" \
      "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
      "$(jq -c '{evidence: (.evidence // "")}' <<<"$impl_status_json")"
  else
    log_event "warning" "$(jq -nc \
      --arg d "implementer void refused for ${selected_repo:-<no repo>} $selected_item — $impl_void_refusal; recorded blocked instead" \
      '{detail: $d}')"
    log_attempt_failed "implementer" \
      "void refused ($impl_void_refusal). The Implementer's stated reason was: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
      "$(jq -nc --arg c "Establish from the repository itself whether this item describes any remaining work." \
        '{unblock_condition: $c}')"
  fi
  # A void item has no work, so its claim must not outlive the verdict — the
  # branch (if untouched) and the registry entry both go. A refused void is
  # recorded blocked instead, but the claim releases the same way either way:
  # the Implementer found no PR to raise for this item.
  release_claim no-pr
  exit 0
fi

# The escape hatch (requirement 9f): the Implementer started this item and
# found the specification it was handed insufficient — not "something in the
# world is wrong" (that is `blocked`), but "the brief itself does not say
# enough to build against". Recorded through the same
# `record_needs_refinement_block` a Co-Ordinator's own `needs_refinement`
# report uses, attributed to `stage: "implementer"` — which also clears any
# `refined` mark the item was carrying, since a refinement that led to this is
# exactly the one requirement 39d says must not stand unexamined.
if (( impl_rc == 0 )) && [[ "$impl_status" == "needs-refinement" ]]; then
  impl_nr_entry="$(jq -nc --arg r "$selected_repo" --arg i "$selected_item" --arg s "$selected_source" \
    --arg reason "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    --arg missing "$(jq -r '.missing // ""' <<<"$impl_status_json")" \
    --arg evidence "$(jq -r '.evidence // ""' <<<"$impl_status_json")" \
    '{repo: $r, item: $i, source: $s, reason: $reason, missing: $missing, evidence: $evidence}')"
  record_needs_refinement_block "$impl_nr_entry" "implementer" || true
  # No PR exists yet on this path — the Implementer stops before step 2's
  # claim, exactly like `blocked` without one — so the branch releases with it.
  if [[ -n "$impl_pr_url" ]]; then
    gh pr comment "$impl_pr_url" --body "$(pipeline_comment_header script "$node_name")

The Implementer found this item's specification insufficient: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json") Recorded as needing refinement; the pipeline's Refiner will look at it again.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
  exit 0
fi

# A reported `blocked` is a verdict, not a stage failure: the Implementer ran to
# completion and found real work it cannot proceed with yet. Record it against
# the item, carrying the model's own reason and unblock_condition so a later
# Co-Ordinator can judge whether the impediment has since gone (requirement 34),
# rather than re-selecting the item and paying for the same discovery every
# cycle.
if (( impl_rc == 0 )) && [[ "$impl_status" == "blocked" ]]; then
  log_attempt_failed "implementer" \
    "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    "$(jq -c --arg u "$impl_pr_url" \
       '{unblock_condition: (.unblock_condition // "")}
        + (if $u == "" then {} else {pr_url: $u} end)' <<<"$impl_status_json")"
  if [[ -n "$impl_pr_url" ]]; then
    gh pr comment "$impl_pr_url" --body "$(pipeline_comment_header script "$node_name")

The Implementer stopped on this PR: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json") Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
  exit 0
fi

if (( impl_rc != 0 )) || [[ -z "$impl_status_json" ]] || [[ "$impl_status" != "complete" ]]; then
  handle_stage_failure "implementer" "$impl_rc" "$impl_out" "$impl_pr_url"
  exit 0
fi

# Requirement 25a's finding from the Implementer-side gate below, empty when
# it found nothing — handed to the Reviewer as a `## Script findings` section
# rather than acted on here. Declared before the gate can set it, since the
# prompt that reads it is built unconditionally under `set -u`.
closing_keyword_finding=""

if [[ -n "$impl_pr_url" ]]; then
  log_event "pr-raised" "$(jq -nc --arg u "$impl_pr_url" --arg r "$repo_slug" '{pr_url: $u, repo: $r}')"
  # The open PR is now the visible claim for the item-keyed entry; back-pressure
  # counts the PR from here on, not that entry (lib/claim.sh count excludes the
  # PR-keyed entry below from its own count for the same reason). The PR-keyed
  # exclusion claim (issue #238) is deliberately *not* dropped here — the
  # Reviewer stage below still has to write to this PR, and a peer must stay
  # excluded from it until this cycle actually ends (issue #360).
  release_claim have-pr-pending

  # Requirement 25a: `.github/workflows/closing-keyword.yml` guards this
  # repository alone — a workflow file protects the repository that ships
  # it, and only agent-ops does. Run the same deterministic check here,
  # against the PR the Script already has the URL for, so an issue-sourced
  # pull request in poetic or poetic-fiddle — which carry no such workflow —
  # cannot slip through on prompt instruction alone either
  # (TD-PPagop-26080803, the same silent-skip shape issue #240 was filed
  # over).
  #
  # A dirty verdict here is review feedback, not a refusal. What it finds is
  # a pull-request *body* edit — the exact class of defect the Reviewer's own
  # step 4 fixes and pushes within the same cycle, and nothing about the diff
  # it is about to read. Refusing the handoff would turn a self-healing case
  # into an item recorded `attempt-failed` and blocked pending an Enabler
  # engagement, and buy no safety: the same gate is asked again at the
  # Reviewer's `ready` handoff, which is the only way a pull request reaches
  # a human or a merge. What this call buys is that the Reviewer *knows* —
  # it cannot see the later gate's verdict from inside its own session
  # (prompts/reviewer.md step 7 says so), so unwarned it would hand off and
  # be handed back, spending the review either way and losing the item too.
  ck_result="$(closing_keyword_gate "$impl_pr_url")" || true
  ck_word=""; ck_reason=""
  IFS=$'\t' read -r ck_word ck_reason <<<"$ck_result" || true
  case "$ck_word" in
    dirty)
      closing_keyword_finding="$ck_reason"
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$ck_reason" \
        '{detail: ($u + " fails the closing-keyword check as raised: " + $d + " — handed to the Reviewer to fix"), pr_url: $u}')"
      ;;
    unknown)
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$ck_reason" \
        '{detail: ("could not check whether " + $u + " carries its closing keyword: " + $d), pr_url: $u}')"
      ;;
  esac
fi

# --- 8. Reviewer stage ---
# Requirement (agent-ops#916, escalation #922, decision 3): a cheap, advisory
# read ahead of a whole Reviewer engagement — has $impl_pr_url already merged
# in the gap between the Implementer's own handoff and here? Merged is acted
# on immediately, the same completion the handoff-time read below reaches for
# a merge caught mid-Reviewer-pass, without spending the stage on a pull
# request no longer there to review. Unreadable just runs the stage as
# normal: nothing here is the last word, since the fail-closed read ahead of
# `confirm_pr_ready` still guards whatever this stage produces.
pre_reviewer_merge_state=""; pre_reviewer_merge_sha=""
if [[ -n "$impl_pr_url" ]]; then
  pre_reviewer_merge_result="$(pr_merge_state "$impl_pr_url")" || true
  IFS=$'\t' read -r pre_reviewer_merge_state pre_reviewer_merge_sha <<<"$pre_reviewer_merge_result"
fi
if [[ "$pre_reviewer_merge_state" == "merged" ]]; then
  reviewer_merge_observed "$impl_pr_url" "$pre_reviewer_merge_sha" '{}' "reviewer-stage-start"
  echo "$impl_pr_url"
  exit 0
fi

# Requirement 8a: the reviewer tier follows the item's complexity — the
# highest of the Implementer's ex-post grade (its summary's `complexity`) and
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
[[ "$impl_model" == "$implementer_model_trivial" ]] && impl_trivial=1
rev_complexity="$(reviewer_complexity "$impl_complexity" "$impl_trivial" ${label_grades[@]+"${label_grades[@]}"})"
rev_model="$reviewer_model_default"
[[ "$rev_complexity" == "high" ]] && rev_model="$reviewer_model_complex"

# The `## Script findings` section, present only when a script-side check has
# something the Reviewer needs to act on — carrying its own leading newline so
# an empty one leaves the surrounding sections spaced exactly as before.
script_findings_section=""
if [[ -n "$closing_keyword_finding" ]]; then
  script_findings_section="
## Script findings

- **Closing keyword (requirement 25a):** $closing_keyword_finding
"
fi

reviewer_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" reviewer "$prompt_overrides_json")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`

## Implementer summary

\`\`\`json
$(jq . <<<"$impl_status_json")
\`\`\`
$script_findings_section
## Cycle

$cycle_id

## Node

$node_name
"
rev_out="$cycle_dir/reviewer.out"

stage_budget_apply reviewer "$selected_repo" "$rev_model" \
  "$(jq -nc --arg c "$rev_complexity" '{complexity: $c}')"
if run_claude_stage reviewer "$(( stage_backstop_min * 60 ))" "$rev_model" "$reviewer_prompt" "$rev_out" "$clone_dir" "$(( stage_inactivity_min * 60 ))"; then
  rev_rc=0
else
  rev_rc=$?
fi
# shellcheck disable=SC2154  # stage_kill_reason/stage_gaps_json: run_claude_stage (lib/stage-run.sh) assigns both.
log_event "stage-end" "$(jq -nc --argjson rc "$rev_rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$rev_model" "$rev_out" "$stage_gaps_json")" \
  '{stage: "reviewer", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
rework_stage_rerun_maybe "reviewer" "$stage_kill_reason" "$selected_repo" "$selected_item" "$impl_pr_url"
# `if`, not `&&`: an empty warning is the common case, and a trailing
# `&&` whose test fails is a non-zero status at exactly the place
# `set -e` acts on — the same trap that cost a --once cycle its
# failure handling at dump_stage_output.
watchdog_warning="$(stage_watchdog_warning reviewer || true)"
if [[ -n "$watchdog_warning" ]]; then
  log_event "warning" "$watchdog_warning"
fi
(( ONCE )) && dump_stage_output "$rev_out"

rev_result="$(jq -r '.result // empty' "$rev_out" 2>/dev/null || true)"
rev_status_json="$(extract_json_result "$rev_result" 2>/dev/null || true)"
if (( rev_rc == 0 )) && [[ -z "$rev_status_json" ]]; then
  rev_status_json="$(stage_salvage_result reviewer "$rev_out" "$rev_model" "$clone_dir" || true)"
fi

if (( rev_rc != 0 )) || [[ -z "$rev_status_json" ]]; then
  handle_stage_failure "reviewer" "$rev_rc" "$rev_out" "$impl_pr_url"
  exit 0
fi

rev_status="$(jq -r '.status // empty' <<<"$rev_status_json")"

# Requirement (agent-ops#916, escalation #922, decisions 2 and 3): the
# handoff's own fail-closed read of whether $impl_pr_url has already
# merged — ahead of confirm_pr_ready's isDraft read inside
# handoff_complete_review below, and decisive over the Reviewer verdict's own
# word, which is why this runs before branching on $rev_status at all. A
# confirmed merge is a completion whether the Reviewer never noticed
# ("ready") or noticed and said so ("blocked", naming the merge) — neither
# reaches pr-ready, an Approver engagement or a landing attempt. A Reviewer
# claiming a merge GitHub denies is a model error and falls through to the
# ordinary attempt-failed handling below unchanged, since merge_state is
# "open" (or "failed") in that case, not "merged".
merge_state=""; merge_sha=""
if [[ -n "$impl_pr_url" ]]; then
  merge_result="$(pr_merge_state "$impl_pr_url")" || true
  IFS=$'\t' read -r merge_state merge_sha <<<"$merge_result"
fi

if [[ "$merge_state" == "merged" ]]; then
  reviewer_merge_observed "$impl_pr_url" "$merge_sha" "$rev_status_json" "reviewer"
  echo "$impl_pr_url"
  exit 0
fi

if [[ "$rev_status" == "ready" && "$merge_state" == "failed" ]]; then
  # Fail-closed exactly as `confirm_pr_ready` already is (see
  # `pr_merge_state`'s own header): "could not tell whether this merged"
  # must never read as "safe to hand off" — this is the last check before an
  # irreversible act (the draft flip, the Approver, landing), and nothing
  # downstream re-asks it.
  log_reviewer_handback \
    "the Reviewer reported ready, but whether $impl_pr_url has already merged could not be confirmed" \
    "$impl_pr_url" "Retry once a node can read GitHub's pull-request state for this pull request."
  exit 0
fi

if [[ "$rev_status" == "ready" ]]; then
  # Requirement 31c (agent-ops#249) and 32b (agent-ops#440): a Reviewer's
  # "ready" is a model reading a check list, exactly the judgement that
  # missed poetic-fiddle #216's CodeQL alert hidden inside an otherwise-green
  # list. Before any handoff mechanism runs, ask GitHub directly, the same
  # "confirm, don't trust" shape requirement 31a already applies to the draft
  # flag itself — `handoff_complete_review` (lib/handoff.sh) is the one
  # gate-and-flip implementation this call site shares with the Enabler's
  # `complete_handoff` recovery path below, so neither can hand a pull
  # request to a human without running the same checks the other does.
  gate_default_branch="$(jq -r '.default_branch // "main"' <<<"$work_order_json")"
  review_json="$(handoff_complete_review "$impl_pr_url" "$gate_default_branch" "$enabler_assignee" "$cycle_started_at")"
  gate_word="$(jq -r '.gate.word // ""' <<<"$review_json")"
  gate_reason="$(jq -r '.gate.reason // ""' <<<"$review_json")"
  gate_checks_unreadable="$(jq -r '.gate.checks_unreadable // false' <<<"$review_json")"
  ck_word="$(jq -r '.closing_keyword.word // ""' <<<"$review_json")"
  ck_reason="$(jq -r '.closing_keyword.reason // ""' <<<"$review_json")"
  rc_word="$(jq -r '.reconciliation.word // ""' <<<"$review_json")"
  rc_reason="$(jq -r '.reconciliation.reason // ""' <<<"$review_json")"
  rc_revert="$(jq -r '.revert // ""' <<<"$review_json")"
  review_safe="$(jq -r '.safe // false' <<<"$review_json")"

  # TD-PPagop-26081404: bookkeeping for `review_gate_unknown_streak_verdict`,
  # logged unconditionally — regardless of which branch below is taken, or
  # none of them — so a run of consecutive failures can be told apart from
  # ordinary noise. `gate.checks_unreadable`, not the word alone: a genuinely
  # dirty alert outranks an unreadable check list for the word and the
  # handback below (see `handoff_complete_review`'s own header), so the word
  # alone would record `{ok: true}` for an evaluation whose required-checks
  # read failed outright — falsely resetting the very streak this event
  # exists to count.
  gate_checks_ok=true
  [[ "$gate_checks_unreadable" == "true" ]] && gate_checks_ok=false
  log_event "review-gate-checks-read" "$(jq -nc --argjson ok "$gate_checks_ok" '{ok: $ok}')"
  # check-failure (docs/FLOW-SCHEMA.md, D23, issue #596's own detector
  # naming): `ok: false` here is this per-attempt read failing — the same
  # node/API fact `review_gate_unknown_streak_verdict` counts a run of
  # (`gate_checks_unreadable`, `handoff_complete_review`'s exit 2). The
  # *escalation* of a run of these, `review-gate-checks-degraded`, is
  # deliberately never counted here too: it is a summary of repetitions
  # already recorded at their own per-attempt site, not a fresh one.
  rework_check_failure_json="$(rework_check_failure_fields "$gate_checks_ok" "$gate_reason" \
    "$selected_repo" "$selected_item" "$impl_pr_url")"
  [[ -n "$rework_check_failure_json" ]] && log_event "rework" "$rework_check_failure_json"

  if [[ "$review_safe" != "true" ]]; then
    if [[ "$gate_word" == "dirty" ]]; then
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $gate_reason" \
        "$impl_pr_url" "Get every required check green and clear the named security-severity code-scanning alert, then let the Reviewer re-examine it."
      exit 0
    fi
    if [[ "$gate_checks_unreadable" == "true" ]]; then
      # A node fact, not a pull-request fact — logged as its own warning so a
      # `gh` degraded on this node is visible as a pattern across items rather
      # than only as N pull-request-shaped handbacks naming nothing to fix. The
      # handback itself still runs: an unread required-check list is refused
      # exactly like a genuinely failing one, and its unblock_condition names
      # the node-level cause rather than telling the Enabler to inspect a pull
      # request that may already be fine.
      #
      # TD-PPagop-26081404: `gh` degraded enough to fail this read is rarely
      # wrong once — a node past a rate limit, or fighting a transient auth
      # problem, is typically wrong for several consecutive items, and each one
      # earning its own warning buries the pattern a human would actually act
      # on. Once this node's own log shows `review_gate_unknown_streak_after`
      # of these in a row, one louder escalation event replaces the per-item
      # warning instead of piling another one on top of it — once per streak,
      # not once per item past the threshold: `review_gate_degraded_since`,
      # inside `review_gate_escalate_unreadable_streak` (TD-PPagop-26081603),
      # is the same already-escalated dedup `crash_loop_escalated_since` gives
      # requirement 2.7's crash loop, keyed on the run's own `first_ts`, so an
      # already-escalated run logs nothing further here (the bookkeeping event
      # above still records the failure, and the handback below still refuses
      # the handoff) until a successful read starts a new streak.
      streak_json="$(review_gate_escalate_unreadable_streak)"
      if [[ -z "$streak_json" ]]; then
        log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$gate_reason" \
          '{detail: ("this node could not read " + $u + "'\''s required checks, so the handoff was refused rather than trusted on an unread check list: " + $d), pr_url: $u}')"
      fi
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url's required checks could not be confirmed: $gate_reason" \
        "$impl_pr_url" "Retry once a node can read GitHub's required-checks API for this pull request — nothing found here implicates the pull request itself."
      exit 0
    fi
    if [[ "$ck_word" == "dirty" ]]; then
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $ck_reason" \
        "$impl_pr_url" "Add the missing closing keyword (Closes/Fixes/Resolves #N) for the issue this PR claims to close, then let the Reviewer re-examine it."
      exit 0
    fi
    if [[ "$rc_word" == "dirty" ]]; then
      # Requirement 31c's reconciliation gate (agent-ops#533): a human posted
      # a general PR comment since this pull request last left draft, and no
      # pipeline comment since cites a `<!-- agent-ops:reconciles
      # comment=<id> -->` line naming it — a requested change silently
      # dropped rather than implemented or contested (PR #512).
      #
      # human-change-request (docs/FLOW-SCHEMA.md, D23, issue #596): this is
      # the class #533 used to leave undetected entirely (a plain PR comment
      # is invisible to the review gate) — now caught here, at this same
      # refusal, and given its own machine-legible class rather than living
      # only in the `attempt-failed` `detail` string `log_reviewer_handback`
      # writes below. Attributed to the Reviewer: this refusal fires at its
      # own handoff, the one place this class is detected today.
      log_event "rework" "$(rework_human_change_request_fields "$rc_reason" \
        "$selected_repo" "$selected_item" "$impl_pr_url")"
      #
      # agent-ops#539: `handoff_complete_review` does not merely refuse this
      # handoff any more — it also reverts the pull request to draft
      # (`confirm_pr_draft`), because leaving it exactly as the Reviewer's
      # own step-7 `gh pr ready` had just left it is what let that same flip
      # survive to become the next round's reconciliation anchor and disarm
      # this gate one round later (see `_reconciliation_gate_anchor`'s
      # header). `revert` carries what that call found; `failed` is worth its
      # own warning, since a human could otherwise merge a
      # `CHANGES_REQUESTED` pull request that GitHub still shows as ready.
      if [[ "$rc_revert" == "failed" ]]; then
        log_event "warning" "$(jq -nc --arg u "$impl_pr_url" \
          --arg d "$impl_pr_url carries an unreconciled human comment and could not be converted back to draft — it remains ready, and a human could merge it with the comment still unanswered" \
          '{detail: $d, pr_url: $u}')"
      fi
      log_reviewer_handback \
        "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $rc_reason" \
        "$impl_pr_url" "Answer every unreconciled human comment on the pull request — implement it or explicitly contest it in the completion comment — citing each with its own <!-- agent-ops:reconciles comment=<id> --> line, then let the Reviewer re-examine it."
      exit 0
    fi
    # The gates were clean and the flip itself did not take.
    log_reviewer_handback \
      "the Reviewer reported ready, but $impl_pr_url is still a draft and the handoff could not be completed" \
      "$impl_pr_url" "Confirm the pull request is out of draft with CI green."
    exit 0
  fi

  # `unknown` is "the question could not be put" — a degraded `gh` on this
  # node, not a fault in this pull request — so it warns rather than blocks,
  # the same way an unreadable alert list does just below. A node degraded
  # enough for this to matter does not get past `handoff_complete_review`
  # above in any case: it already refused the handoff, with its own warning,
  # the moment its required-check list came back unreadable rather than
  # merely unable to confirm an alert or a keyword.
  if [[ "$ck_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$ck_reason" \
      '{detail: ("could not confirm " + $u + " carries its closing keyword: " + $d), pr_url: $u}')"
  fi

  if [[ "$rc_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$rc_reason" \
      '{detail: ("could not confirm every human comment on " + $u + " since it last left draft is reconciled: " + $d), pr_url: $u}')"
  fi

  if [[ "$gate_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$gate_reason" \
      '{detail: ("could not confirm " + $u + " carries no new security-severity code-scanning alert: " + $d), pr_url: $u}')"
  fi

  # Requirement 31a: the verdict is the Reviewer's — it is the only actor that
  # read the diff — but the handoff is a fact about the PR, and asking GitHub
  # costs one field. `pr-ready` now means the PR is not a draft, not that
  # somebody said so; `handoff` records which of them made it true.
  handoff_result="$(jq -r '.handoff // ""' <<<"$review_json")"
  # `safe: true` already guarantees one of the two arms below — the flip word
  # is the last thing `handoff_complete_review` checks before it says so — so
  # the case needs no `*)` arm refusing the handoff; the refusal for a flip
  # that did not take is the `review_safe != "true"` block above. The default
  # is still set, because the one place an unmatched word could surface is
  # `pr-ready` below, and an unset variable under `errexit`/`nounset` would
  # abort the cycle at exactly the point it records what it did.
  handoff_by="script"
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
  esac

  # Requirement 31b: the draft flip above is the whole handoff exactly once per
  # pull request. On every later round — a review the Implementer has just
  # answered, most of all — the PR never left ready, `confirm_pr_ready`
  # truthfully answers `already`, and nothing has put the PR back in front of
  # the human: their review request was consumed when they submitted the review,
  # and the author cannot clear `CHANGES_REQUESTED`. So the second half of the
  # handoff is asked of GitHub too, on the same terms and for the same reason
  # requirement 31a asks about the draft flag — inside `handoff_complete_review`
  # itself now, unconditionally, not gated on `source == "review-feedback"`: the
  # question ("does a human's review block this PR, and have they been asked to
  # look again?") is answerable from the PR itself, costs one API call to
  # answer `no` on a first-round PR, and gating it on the Co-Ordinator's
  # classification would make a mislabelled source a silently unnotified human.
  rereview_state="$(jq -r '.rereview.state // ""' <<<"$review_json")"
  rereview_who="$(jq -r '.rereview.who // ""' <<<"$review_json")"
  if [[ "$rereview_state" == "failed" ]]; then
    # A warning, never a handback: the pull request is finished, green and
    # visible, and only the notification is missing (see lib/handoff.sh).
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg w "$rereview_who" \
      --arg d "changes requested on $impl_pr_url are answered, but review could not be re-requested from ${rereview_who:-the reviewer} — they will not see it in their review queue" \
      '{detail: $d, pr_url: $u} + (if $w == "" then {} else {reviewers: ($w | split(","))} end)')"
  fi

  # Requirement 38: nothing's `CHANGES_REQUESTED` above means there is no
  # blocking reviewer to re-request from — but the pull request may still be
  # exactly where a human needs to look (a first review, or an approval
  # nobody has acted on). `handoff_complete_review` asks GitHub the same way,
  # targeted at `enabler_assignee` instead of a blocking reviewer set.
  human_reviewer_state="$(jq -r '.human_reviewer.state // ""' <<<"$review_json")"
  human_reviewer_who="$(jq -r '.human_reviewer.who // ""' <<<"$review_json")"
  if [[ "$human_reviewer_state" == "failed" || "$human_reviewer_state" == "failed-rate-limited" ]]; then
    # agent-ops#1082: `ensure_human_reviewer` (lib/handoff.sh) tells a rate-limit
    # refusal apart from any other read failure at this call site — an operator
    # reading this warning needs to know whether nobody was notified because the
    # shared REST budget was gone, or because something else genuinely failed.
    rate_note=""
    [[ "$human_reviewer_state" == "failed-rate-limited" ]] \
      && rate_note=" — GitHub's REST rate limit refused the read"
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg a "$enabler_assignee" --arg w "$human_reviewer_who" \
      --arg d "$impl_pr_url is ready with nothing blocking it, but review could not be requested from ${human_reviewer_who:-$enabler_assignee} — it will not appear in their review queue$rate_note" \
      '{detail: $d, pr_url: $u} + (if $w == "" then {reviewers: [$a]} else {reviewers: ($w | split(","))} end)')"
  fi

  log_event "pr-ready" "$(jq -nc --arg u "$impl_pr_url" --arg h "$handoff_by" \
    --arg rr "$rereview_state" --arg w "$rereview_who" \
    --arg hr "$human_reviewer_state" --arg ha "$enabler_assignee" \
    '{pr_url: $u, handoff: $h}
     + (if $rr == "" or $rr == "none" then {} else {review_requested: $rr} end)
     + (if $w == "" then {} else {reviewers: ($w | split(","))} end)
     + (if $hr == "" or $hr == "skip" then {}
        else {human_review_requested: $hr, human_reviewer: $ha} end)')"
  # The cycle's last write to this PR (issue #360) — the PR-keyed exclusion
  # claim pr-raised left standing above is released only now, at the actual
  # handoff, not back when the item-keyed claim was.
  release_pr_claim

  # --- 8f. Open-question signal (D18, agent-ops#668) ---
  # `open_questions` is additive to a `ready` verdict, never a substitute for
  # it — the handoff above has already happened regardless of what follows
  # here. Projected as a label (requirement 8f's own landing gate,
  # `_landing_stage_attempt`, and the 2.1e retry sweep both read it with no
  # log join) and logged as its own event so the escalation/adjudication
  # path that gate drives has the question's own words to work from, not
  # only the label's bare presence. A later Reviewer round raising a further
  # question while an earlier one still stands is additive too: the label
  # projects as `present` and the new question still gets its own event, but
  # the pull request was already held and stays held.
  oq_json="$(jq -c '[.open_questions[]? | select(type == "object")]' <<<"$rev_status_json" 2>/dev/null)"
  [[ -n "$oq_json" && "$oq_json" != "null" ]] || oq_json='[]'
  if [[ "$(jq 'length' <<<"$oq_json" 2>/dev/null || echo 0)" != "0" ]]; then
    if [[ "$impl_pr_url" =~ /pull/([0-9]+)$ ]]; then
      oq_number="${BASH_REMATCH[1]}"
      # `landing_open_question_label_project` documents exit 1 for its own
      # `unrecorded` and `failed` words (lib/landing.sh) as ordinary outcomes,
      # never a fault — under this script's `set -euo pipefail`, an unguarded
      # `var=$(cmd)` takes that exit status and would abort the cycle before
      # the Approver or landing stage ever ran (agent-ops#889). `|| true` on
      # both calls keeps the captured word regardless of which one printed.
      oq_proj="$(landing_open_question_label_project "$selected_repo" "$oq_number")" || true
      if [[ "$oq_proj" == "failed" ]]; then
        # Self-heal, once: the common cause is a repository this pipeline has
        # not created the label in yet, the same gap
        # `refinement_label_add`'s own retry (agent-ops#687) exists to close.
        refinement_label_ensure_one "$selected_repo" "$LANDING_OPEN_QUESTION_LABEL" >/dev/null 2>&1 || true
        oq_proj="$(landing_open_question_label_project "$selected_repo" "$oq_number")" || true
      fi
      log_event "open-question-raised" "$(jq -nc --arg u "$impl_pr_url" --arg r "$selected_repo" \
        --arg proj "$oq_proj" --argjson qs "$oq_json" \
        '{pr_url: $u, repo: $r, label_projection: $proj, questions: $qs}')"
      if [[ "$oq_proj" != "added" && "$oq_proj" != "present" ]]; then
        log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg l "$LANDING_OPEN_QUESTION_LABEL" \
          --arg d "$impl_pr_url carries an open question but the $LANDING_OPEN_QUESTION_LABEL label could not be confirmed on it (projection: $oq_proj) — the landing gate cannot hold it on this label alone until a later read succeeds" \
          '{detail: $d, pr_url: $u, label: $l}')"
      fi
    else
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" \
        --arg d "$impl_pr_url carries an open question but no pull request number could be parsed from its URL — the open-question label was not projected" \
        '{detail: $d, pr_url: $u}')"
    fi
  fi

  # --- 8b. Approver stage (D18 WI-5) ---
  # After every existing gate has passed and the handoff itself is complete —
  # review_gate_verdict, the closing-keyword gate, confirm_pr_ready,
  # confirm_review_requested, ensure_human_reviewer, the pr-ready log and the
  # claim release, all above — the tiered Approver gets one independent look,
  # for every repository whose merge_autonomy is above `human`. Placed last
  # and gating nothing above it: a refusal is a GitHub review sitting on an
  # already-ready pull request, not a reason to withhold the pr-ready log or
  # the claim release, exactly as a human's own CHANGES_REQUESTED never
  # withheld either of those — so this runs after both, never before.
  #
  # The tier is resolved now, not from `rev_complexity` as computed for the
  # Reviewer at requirement 8a: the Reviewer stage that just ran may have
  # corrected the PR's `complexity:*` label (prompts/reviewer.md step 4), and
  # that correction must reach this same round's Approver, not just the next
  # one (agent-ops#470).
  approver_complexity="$(approver_stage_complexity "$impl_pr_url" "$rev_complexity" "$impl_trivial")"
  run_approver_stage "$impl_pr_url" "$approver_complexity"

  # --- 8d. Landing arming step (D18 WI-7) ---
  # Immediately after the Approver, and gating nothing above it for the same
  # reason 8b gates nothing above it: an arm or a refusal is a fact about
  # this pull request's landing, never a reason to withhold the pr-ready log,
  # the claim release, or the Approver's own review. See run_landing_stage's
  # own header for the seven gates it re-reads fresh before arming anything.
  run_landing_stage "$impl_pr_url" "$approver_complexity"
else
  # Requirement 32a: a Reviewer that cannot hand off hands *back*, not out. The
  # verdict names a real impediment on a real PR, which is a blocked item —
  # the Enabler's input — and never, by itself, a summons to a human.
  log_reviewer_handback \
    "reviewer verdict '${rev_status:-unparseable}': $(jq -r '.reason // .ci // "no detail given"' <<<"$rev_status_json")" \
    "$impl_pr_url" "Resolve what the Reviewer left on the pull request, or escalate it."
fi

echo "$impl_pr_url"
