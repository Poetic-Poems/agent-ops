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
# shellcheck source=lib/repo-clone.sh
. "$SCRIPT_DIR/lib/repo-clone.sh"
# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"
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
# shellcheck source=lib/approver-token.sh
. "$SCRIPT_DIR/lib/approver-token.sh"
# shellcheck source=lib/approver.sh
. "$SCRIPT_DIR/lib/approver.sh"
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
# shellcheck source=lib/crash-loop.sh
. "$SCRIPT_DIR/lib/crash-loop.sh"
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
# The Enabler (requirements 35–37). Its model is the most expensive this system
# runs, which is affordable only because the eligibility rule engages it rarely:
# an empty `enabler_model` disables the stage outright.
enabler_model="$(resolve_model_id enabler_model "$(cfg '.enabler_model')")"
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
pr_label="$(cfg '.pr_label')"
# Read here (rather than left to the Co-Ordinator, which puts it in the work
# order's `branch`) because requirement 3c's gatherer needs it: a PR is only
# ours to push to if its head branch is under this prefix. The Landing Gate says
# branches outside it belong to humans.
branch_prefix="$(cfg '.branch_prefix')"
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
none_selected_recheck_hours="$(cfg '.none_selected_recheck_hours')"
candidates_max="$(cfg '.candidates_max')"
# Requirement 4i (agent-ops#641): the largest assembled prompt the Co-Ordinator
# may be handed. Non-numeric or absent reads as 0 — the bound off — because a
# misread here must not be able to trim a cycle's candidates to nothing, which
# is a worse failure than the overflow the bound exists to catch.
coordinator_prompt_max_bytes="$(cfg '.coordinator_prompt_max_bytes')"
[[ "$coordinator_prompt_max_bytes" =~ ^[0-9]+$ ]] || coordinator_prompt_max_bytes=0
max_chained_cycles="$(cfg '.max_chained_cycles')"
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
  local rec resume_at resume_epoch rec_class
  rec="$(current_limit_record)"
  resume_at="$(jq -r '.resume_at // empty' <<<"${rec:-{\}}" 2>/dev/null || true)"
  # TD-PPagop-26081407: `rec` is fleet state read off disk/across nodes by
  # current_limit_record above (test 1 — a peer's flag file or log line can be
  # mid-write); epoch 0 reads as "already expired" (test 2 — indistinguishable
  # from a stand-down that genuinely lapsed), which would silently let the
  # fleet ignore an active cooldown.
  if [[ -n "$resume_at" ]]; then
    resume_epoch="$(date -d "$resume_at" +%s 2>&1)" \
      || { guard_warn "limit_status_report:resume_epoch" "$resume_epoch"; resume_epoch=0; }
  else
    resume_epoch=0
  fi
  if [[ -z "$resume_at" ]] || (( resume_epoch <= $(date +%s) )); then
    printf 'limit:    none in force\n'
    return 0
  fi
  # Same site class as above: `rec` can fail to parse, and "other" is exactly
  # the class a well-formed-but-unset record also reports (test 2).
  rec_class="$(jq -r '.class // "other"' <<<"$rec" 2>&1)" \
    || { guard_warn "limit_status_report:rec_class" "$rec_class"; rec_class=other; }
  printf 'limit:    STANDING DOWN — %s\n' \
    "$(limit_describe "$resume_at" "$rec_class" "$(limit_reset_known "$rec")")"
  return 0
}

# The fleet line of `--status` (issue #379): `toggle_status_report` above
# already covers the node-scoped switch (`switch:`/`record:`), so this adds
# only the fleet one and, where both are in play, says plainly what each of
# --enable and --enable --this-node would leave — the question an operator
# who finds a node down for more than one reason actually has.
#
# The local record's `scope` (requirement 2.3) is what makes that answer
# truthful rather than merely confident. A fleet-wide --disable writes both
# levels, so the node that issued one has a local record it never asked for;
# calling that "its own node-scoped disable" describes a second decision that
# was never taken, and sends the operator looking for whoever made it.
fleet_status_report() {
  local local_disabled=0 local_scope="node" local_state fleet_state
  local_state="$(toggle_state "$state_dir")"
  if [[ "$(jq -r '.state' <<<"$local_state")" == "disabled" ]]; then
    local_disabled=1
    local_scope="$(toggle_scope "$(jq -c '.record // {}' <<<"$local_state")")"
  fi
  fleet_state="$(fleet_disabled_state "$state_repo" "$state_dir")"
  if [[ "$(jq -r '.state' <<<"$fleet_state")" == "disabled" ]]; then
    printf 'fleet:    DISABLED — %s\n' "$(toggle_describe "$(jq -c '.record' <<<"$fleet_state")")"
    if (( local_disabled )) && [[ "$local_scope" == "fleet" ]]; then
      printf '          the local record above mirrors this fleet switch — it is not a second, node-scoped disable; --enable clears both levels and every node resumes\n'
    elif (( local_disabled )); then
      printf '          this node also carries its own node-scoped disable (above) — --enable clears both; --enable --this-node clears only the local record, leaving the fleet switch (and this node) still down\n'
    else
      printf '          this node has no node-scoped disable of its own — --enable clears the fleet switch and every node resumes\n'
    fi
  elif (( local_disabled )) && [[ "$local_scope" == "fleet" ]]; then
    # The orphan (requirement 2.3): --enable run on a *peer* clears the fleet
    # flag but cannot reach this file, so this node alone stays down under a
    # fleet decision that has since been lifted. Naming it is the whole point
    # of the scope tag — otherwise this reads as a node-scoped disable nobody
    # set, and the node waits out a `forever` TTL that no longer applies.
    printf 'fleet:    not set — but the local record above mirrors a fleet switch that has since been cleared (probably by --enable on another node), so this node is standing down alone; --enable clears it\n'
  elif (( local_disabled )); then
    printf 'fleet:    not set — this node stands down on its own node-scoped disable above; --enable --this-node clears it\n'
  else
    printf 'fleet:    not set\n'
  fi
}

# The D18 kill switch (requirement 2.3b) — a separate flag from the fleet
# switch above, so killing merge autonomy never stops cycles running and
# disabling the pipeline never touches this. Reported alongside the other two
# stand-downs because all three answer some version of "why is this pipeline
# behaving the way it is right now".
merge_autonomy_status_report() {
  local ma_state
  ma_state="$(merge_autonomy_kill_state "$state_repo" "$state_dir")"
  # Anything but `enabled` is killed, the same test merge_autonomy_effective_level
  # itself applies — not `== "disabled"`. _toggle_eval also speaks `expired`,
  # and a record carrying an expiry it has passed resolves to `human` there
  # while reading as "not killed" here, which is the one way this report can
  # tell an operator the opposite of what the pipeline is doing.
  if [[ "$(jq -r '.state' <<<"$ma_state")" != "enabled" ]]; then
    # The fail-closed synthesis names itself — `record.kind: "fail-closed"`,
    # written by merge_autonomy_kill_state and nothing else, the same
    # discriminator scripts/doctor.sh branches on (requirement 2.3b, #454).
    # Nobody has necessarily set anything in that state: the node simply
    # cannot confirm the switch is clear, so KILLED here would send the
    # operator hunting a lever-pull that never happened, and
    # --restore-merge-autonomy would not help. Reporting-only — both branches
    # resolve every repo's effective level to human, unchanged.
    if [[ "$(jq -r '.record.kind // ""' <<<"$ma_state")" == "fail-closed" ]]; then
      printf 'merge_autonomy: FAIL-CLOSED — %s\n' "$(jq -r '.record.reason // "state repo unreachable"' <<<"$ma_state")"
      printf '          nobody has necessarily set the switch; check connectivity and state-repo health — --restore-merge-autonomy does not apply\n'
    else
      printf 'merge_autonomy: KILLED — %s\n' "$(toggle_describe "$(jq -c '.record' <<<"$ma_state")")"
      printf '          every repo'"'"'s effective level is human regardless of merge_autonomy; --restore-merge-autonomy clears it\n'
    fi
  else
    printf 'merge_autonomy: not killed — each repo runs at its configured level\n'
  fi
}

if [[ -n "$MANAGE_ACTION" ]]; then
  case "$MANAGE_ACTION" in
    status)
      toggle_status_report "$state_dir" "cycle=$lock_file" "review=$review_lock_file"
      fleet_status_report
      limit_status_report
      merge_autonomy_status_report
      exit 0
      ;;
    disable)
      # toggle_actor, never `${USER:-unknown}`: the record's actor is what
      # tells a reader whose decision this was, and `unknown@<container-id>`
      # is what let a deliberate operator stand-down read as a runaway
      # automatic freeze (#244).
      actor="$(toggle_actor)"
      by="$actor pid $$"
      # Read before writing: a --disable over a live switch is an extension of
      # the operator's earlier decision, and the log should say so rather than
      # presenting it as a fresh stop.
      prior_switch="$(toggle_state "$state_dir")"
      extends="$(jq -c 'select(.state == "disabled") | .record' <<<"$prior_switch" 2>/dev/null || true)"
      if ! disable_spec="$(toggle_resolve_disable_spec "$DISABLE_FOR" "$DISABLE_UNTIL" \
                             "$disable_default_ttl_hours")"; then
        exit 64
      fi
      # What this record *is*, not merely that it exists (requirement 2.3) —
      # written before the record, because the record carries it.
      #
      # This is deliberately not the same question as `disable_scope` below,
      # and the two part company in exactly one case. That one records the
      # operator's *instruction* for the log (issue #426), so a --disable on
      # an installation with no `state_repo` is still `scope: "fleet"`, with
      # `fleet_flag: "unconfigured"` saying why nothing was published. This one
      # answers "is there a fleet flag for this record to mirror?" — and with
      # no state repo there is none, so it is `node`. Tagging it `fleet` would
      # have --status claim a mirror of a switch that cannot exist, and
      # --enable --this-node refuse to clear the only record holding this node
      # down. Under --this-node both agree on `node`, for the same reason.
      record_scope=node
      if (( ! THIS_NODE )) && [[ -n "$state_repo" ]]; then record_scope=fleet; fi
      if ! record="$(toggle_disable "$state_dir" "$DISABLE_REASON" "$disable_spec" \
                       "$disable_default_ttl_hours" "$by" "$actor" manual "$record_scope")"; then
        exit 64
      fi
      printf 'agent-cycle: disabled — %s\n' "$(toggle_describe "$record")"
      # The same record goes up as the fleet switch (requirement 2.3a): with
      # several nodes active, "stop the pipelines" has to mean all of them.
      # Best-effort — the local switch above already holds this node either
      # way, and the operator is told which of the two situations they are in.
      # --this-node opts out of that: the whole point of the flag is a
      # graceful, single-node stand-down that never reaches the fleet flag,
      # so the rest of the fleet is left running rather than warned about.
      #
      # `disable_scope` and `fleet_flag_outcome` are what the operator asked
      # for and what actually happened to it — logged below, once both are
      # known, rather than at the top of this block (issue #426): a process
      # killed mid-fleet-attempt must lose the event rather than log a
      # `disabled` that never says whether the fleet went down too.
      disable_scope="fleet"
      fleet_flag_outcome=""
      if (( THIS_NODE )); then
        disable_scope="node"
        printf 'agent-cycle: node-scoped disable — only %s stands down; the rest of the fleet keeps running\n' "$actor"
      else
        fleet_flag_outcome="$(fleet_flag_write_outcome "$state_repo" disabled "$record" \
          "fleet: disabled by $by — $DISABLE_REASON" "$state_dir")"
        case "$fleet_flag_outcome" in
          ok) printf 'agent-cycle: fleet switch set — every node will stand down\n' ;;
          failed)
            # Retag before warning: no fleet switch was set, so the local
            # record is no longer a mirror of anything — this node genuinely
            # is standing down alone, and a record still claiming `fleet`
            # would have --status and the dashboard describe a fleet
            # stand-down that does not exist. `unconfigured` needs no retag:
            # record_scope was already `node` when there is no state repo.
            toggle_mark_scope "$state_dir" node
            printf 'agent-cycle: WARNING — could not set the fleet switch (state repo unreachable?); only this node is disabled\n' >&2
            ;;
        esac
      fi
      log_event "disabled" "$(jq -nc --argjson r "$record" --argjson x "${extends:-null}" \
        --arg scope "$disable_scope" --arg ff "$fleet_flag_outcome" \
        '{reason: $r.reason, expires_at: $r.expires_at, by: $r.by,
          actor: $r.actor, kind: $r.kind, scope: $scope}
         + (if $x == null then {} else {extends: $x} end)
         + (if $ff == "" then {} else {fleet_flag: $ff} end)')"
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
      # --this-node undoes a --disable --this-node. It must refuse a record
      # tagged `fleet` (requirement 2.3), because clearing that one is never
      # what the operator wanted and can be actively harmful: the mirror is
      # this node's fail-closed hold on itself for exactly the window where
      # the fleet flag cannot be read (state repo unreachable — see
      # lib/toggle.sh's fleet section, which fails *open*), so dropping it
      # while the fleet switch stands is how a node resumes work the fleet was
      # stood down to prevent. Plain --enable is the right command in every
      # case: it clears this record and issues the fleet delete, which is
      # idempotent and treats an already-cleared flag as success.
      if (( THIS_NODE )); then
        enable_state="$(toggle_state "$state_dir")"
        if [[ "$(jq -r '.state' <<<"$enable_state")" == "disabled" ]] \
           && [[ "$(toggle_scope "$(jq -c '.record // {}' <<<"$enable_state")")" == "fleet" ]]; then
          echo "agent-cycle: this node's disable record mirrors a fleet-wide --disable, not a --this-node one; --enable --this-node will not clear it. Use --enable, which clears both levels (harmless if the fleet switch is already clear)." >&2
          exit 64
        fi
      fi
      record="$(toggle_clear "$state_dir")"
      if [[ -n "$record" ]]; then
        printf 'agent-cycle: enabled — cleared the disable set at %s (%s)\n' \
          "$(jq -r '.disabled_at // "?"' <<<"$record")" "$(jq -r '.reason // "?"' <<<"$record")"
      else
        printf 'agent-cycle: already enabled — no switch was set\n'
      fi
      # Clear the fleet switch too — and complain loudly if that fails,
      # because a fleet flag left set keeps every node down after the
      # operator believes they have re-enabled the operation.
      # --this-node opts out: it undoes only this node's own --disable
      # --this-node, and must never clear a fleet switch (or another node's
      # own node-scoped one) it did not set.
      enable_scope="fleet"
      fleet_flag_outcome=""
      if (( THIS_NODE )); then
        enable_scope="node"
        printf 'agent-cycle: node-scoped enable — the fleet switch, if any, is untouched\n'
      elif [[ -n "$state_repo" ]]; then
        fleet_flag_outcome="$(fleet_flag_delete_outcome "$state_repo" "$state_dir" disabled)"
        case "$fleet_flag_outcome" in
          ok|unconfigured) printf 'agent-cycle: fleet switch clear\n' ;;
          failed) printf 'agent-cycle: WARNING — could not clear the fleet switch; every node still stands down. Re-run --enable, or delete fleet/disabled.json in %s by hand.\n' "$state_repo" >&2 ;;
        esac
      else
        fleet_flag_outcome="unconfigured"
      fi
      # Log `enabled` whenever anything was actually cleared — the local
      # record, the fleet flag, or both — not only when the local record was
      # set (issue #426): a node with no local record but a live fleet flag
      # previously left the fleet coming back up absent from the log
      # entirely.
      if [[ -n "$record" || "$fleet_flag_outcome" == "ok" ]]; then
        log_event "enabled" "$(jq -nc --argjson r "${record:-null}" \
          --arg scope "$enable_scope" --arg ff "$fleet_flag_outcome" \
          '{detail: "cleared by hand", was: $r, scope: $scope}
           + (if $ff == "" then {} else {fleet_flag: $ff} end)')"
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
        --arg by "$(toggle_actor)" \
        '{was: (if $w == "" then null else $w end),
          reason: (if $r == "" then "cleared by hand" else $r end),
          by: $by, actor: $by, kind: "manual"}')"

      # Carrier 2: the live flag. Deleting it rather than shortening it,
      # because fleet_limit_publish is extend-only by design (concurrent hits
      # must converge on the latest resume) — a human lifting a stand-down is
      # the one case that legitimately moves it earlier, and delete is the
      # only write that expresses that.
      if [[ -n "$state_repo" ]]; then
        # >/dev/null: fleet_flag_delete now prints which of "deleted"/"absent"
        # it was (issue #426) for callers that log the outcome; this one only
        # ever reads the return code, and the raw word must not leak to the
        # operator's terminal.
        if fleet_flag_delete "$state_repo" "$state_dir" limit >/dev/null; then
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
    kill-merge-autonomy)
      # D18 §6 (requirement 2.3b): a permanent operational control, not
      # scaffolding — inherently fleet-wide, so unlike --disable there is no
      # --this-node form and no local record to write first. With no
      # state_repo configured this is a single-node install and the flag
      # cannot be published anywhere every future read would see it — say so
      # rather than pretend the kill took effect.
      by="$(toggle_actor) pid $$"
      if [[ -z "$state_repo" ]]; then
        echo "agent-cycle: no state_repo configured — --kill-merge-autonomy has nothing to publish to (single-node install; the config's own merge_autonomy already governs)" >&2
        exit 64
      fi
      outcome="$(merge_autonomy_kill_set "$state_repo" "$KILL_MERGE_AUTONOMY_REASON" "$by")"
      case "$outcome" in
        ok) printf 'agent-cycle: merge-autonomy kill switch set — every repo'"'"'s effective level is now human\n' ;;
        *) echo "agent-cycle: WARNING — could not set the merge-autonomy kill switch (state repo unreachable?)" >&2 ;;
      esac
      log_event "merge-autonomy-killed" "$(jq -nc --arg r "$KILL_MERGE_AUTONOMY_REASON" \
        --arg by "$by" --arg actor "$(toggle_actor)" --arg outcome "$outcome" \
        '{reason: $r, by: $by, actor: $actor, kind: "manual", fleet_flag: $outcome}')"
      refresh_dashboard
      exit 0
      ;;
    restore-merge-autonomy)
      if [[ -z "$state_repo" ]]; then
        printf 'agent-cycle: no state_repo configured — the kill switch was never publishable (single-node install)\n'
        exit 0
      fi
      outcome="$(merge_autonomy_kill_clear "$state_repo" "$state_dir")"
      case "$outcome" in
        ok) printf 'agent-cycle: merge-autonomy kill switch cleared — each repo'"'"'s configured level governs again\n' ;;
        unconfigured) printf 'agent-cycle: merge-autonomy kill switch was not set\n' ;;
        *) echo "agent-cycle: WARNING — could not clear the merge-autonomy kill switch; every repo still forced to human. Re-run --restore-merge-autonomy, or delete fleet/merge-autonomy-kill.json in $state_repo by hand." >&2 ;;
      esac
      if [[ "$outcome" == "ok" ]]; then
        log_event "merge-autonomy-restored" "$(jq -nc --arg by "$(toggle_actor)" \
          '{detail: "cleared by hand", by: $by, actor: $by, kind: "manual"}')"
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
  # lib/issue-priority.sh's own cache directory (issue #510): removed here,
  # after the Refiner, since the Refiner's own priority-triage duty is that
  # cache's main consumer.
  issue_priority_cache_cleanup
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
if ! (( DRY_RUN )) && (( crash_loop_after > 0 )) \
    && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" && -s "$union_log" ]]; then
  crash_loop_json="$(crash_loop_verdict "$crash_loop_after" < "$union_log")"
  if [[ -n "$crash_loop_json" ]]; then
    crash_loop_escalate "$crash_loop_json" "crash-loop:coordinator" \
      "Co-Ordinator failures" \
      "Crash loop: the Co-Ordinator is failing fleet-wide" \
      "Start with the newest failing cycle's \`coordinator.out\` under \`state_dir/cycles/\` — a stage the API refused outright records the refusal there, as a \`result\` with \`is_error: true\`, and leaves \`coordinator.out.stderr\` empty (agent-ops#641). Read \`coordinator.out.stderr\` too, for a stage that died rather than being refused; the stage transcripts survive every failure."
  fi

  crash_loop_preselection_json="$(crash_loop_preselection_verdict "$crash_loop_after" < "$union_log")"
  if [[ -n "$crash_loop_preselection_json" ]]; then
    crash_loop_escalate "$crash_loop_preselection_json" "crash-loop:pre-selection" \
      "cycles dying before any stage started" \
      "Crash loop: cycles are dying before any stage starts" \
      "No stage transcript exists for a cycle that dies before any stage begins — start with the newest failing cycle's entry in \`cron.log\` (or \`cron.log.1\` after rotation) under \`state_dir/\`."
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
# Issue #248 acceptance 4 (TD-PPagop-26081405): the fleet's already-logged
# `first-seen` set, read once off the union log snapshotted at 1a1 above —
# every emit_first_seen call below both consults and grows this — and
# whether THIS node's own log had no `first-seen` in it at all when the
# cycle began. Decided once, here, before this cycle writes its own first
# one: an event written mid-cycle must not flip a later call in the same
# cycle from bootstrap to not, which is what checking $log_file fresh at
# each call site would do.
first_seen_known_json="$(first_seen_known_items "$union_log")"
first_seen_bootstrap="$(jq -c '(length == 0)' <<<"$(first_seen_known_items "$log_file")")"
# Review decision on agent-ops#452 concern 1: the `issues-excluded` event
# below logs only on change, and this is the "previous state" each repo's
# freshly gathered set is compared against — read once, here, off the same
# union log snapshot first_seen_known_json above reads, for the same reason:
# an event this cycle logs must not make its own repo's later comparison (if
# the repo were ever visited twice in one cycle) see itself as unchanged.
latest_issues_excluded_json="$(latest_issues_excluded "$union_log")"
repo_order_now="$(date +%s)"
while IFS= read -r slug; do
  # TD-PPagop-26081407: gh api can fail (rate limit, auth, network -- test 1);
  # "main" is a plausible real default branch and 1970-01-01 sorts this repo
  # oldest without saying why (test 2 for both).
  #
  # The shape check after each capture is the sibling of the `claim.sh count`
  # site's `=~ ^[0-9]+$` above, and it closes what `2>&1` opens: swapping
  # `2>/dev/null` for `2>&1` is what makes `detail` useful on failure, but it
  # also merges a *successful* command's stderr into the value. These two are
  # the only converted sites where that matters — every other one feeds jq,
  # date or wc, while `$default_branch` is interpolated straight into the next
  # API path and `$commit_ts` into `.repo_ts`'s ordering sort, both
  # unvalidated. gh 2.97.0 writes nothing to stderr on a successful `api
  # --jq`, so this is a future-proofing check, not a live defect; it reports
  # like any other guard rather than silently substituting, which is the whole
  # point of this item.
  default_branch="$(gh api "repos/$slug" --jq '.default_branch' 2>&1)" \
    || { guard_warn "repo-order:default_branch:$slug" "$default_branch"; default_branch="main"; }
  [[ "$default_branch" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || { guard_warn "repo-order:default_branch-malformed:$slug" "$default_branch"; default_branch="main"; }
  commit_ts="$(gh api "repos/$slug/commits/$default_branch" --jq '.commit.committer.date' 2>&1)" \
    || { guard_warn "repo-order:commit_ts:$slug" "$commit_ts"; commit_ts="1970-01-01T00:00:00Z"; }
  [[ "$commit_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || { guard_warn "repo-order:commit_ts-malformed:$slug" "$commit_ts"; commit_ts="1970-01-01T00:00:00Z"; }
  printf '%s\t%s\t%s\n' "$commit_ts" "$slug" "$default_branch" >> "$cycle_dir/.repo_ts"
done < <(jq -r '.[].slug' <<<"$repos_json")

while IFS=$'\t' read -r _ slug default_branch; do
  sources="$(jq -c --arg s "$slug" '.[] | select(.slug == $s) | .sources' <<<"$repos_json")"
  # Requirement 3o, gathered here — ahead of the four finishing sources below,
  # not after them as before — so their own candidate arrays can be filtered by
  # it: unconditional, regardless of `sources`, because any starting source's
  # item can be claimed.
  repo_claimed_json="$(gather_claimed "$slug")"
  # requirement 4g (TD-PPagop-26081401): $claimed_json is one of the five
  # aggregates requirement 4g names as growing with the fleet's own history —
  # already delivered on stdin — but this repo's own increment,
  # $repo_claimed_json, used to ride in as a second --argjson, past
  # MAX_ARG_STRLEN once enough repos' claims had accumulated into it. Both now
  # arrive as one stdin document. Unguarded — same as before the conversion —
  # because a claims-fold failure here must not be silently swallowed.
  claimed_fold_docs="$(printf '%s\n' "$claimed_json" "$repo_claimed_json")"
  claimed_json="$(jq -nc --arg r "$slug" '
    input as $claimed | input as $items
    | $claimed + ($items | map({repo: $r} + .))
  ' <<<"$claimed_fold_docs")"
  # Requirement 3p/issue #238: the PR numbers a peer already holds a claim on,
  # for this repo. Filtered into the four finishing sources' own arrays below —
  # deterministic code, not something the Co-Ordinator is asked to notice and
  # apply itself, which is exactly the step a Co-Ordinator run "saw" a peer's
  # claim on PR #205 and reasoned past because the item ref didn't match.
  claimed_pr_numbers_json="$(jq -c '[.[] | select(has("pr_number")) | .pr_number]' <<<"$repo_claimed_json")"
  # The claimed item refs themselves, applied below to every pre-fetched
  # source's array through exclude_claimed_items: the same
  # deterministic-code-not-model-judgement decision as the pr_number filter
  # above, extended from the four finishing sources to everything the
  # Script pre-fetches. Every gather script mints a `ref` field that is the
  # exact string a claim on that item is keyed on, so the match needs no
  # re-derivation.
  claimed_item_refs_json="$(jq -c '[.[].item]' <<<"$repo_claimed_json")"
  # Claim exclusion only, in this pass: blocked/void exclusion needs
  # `blocked_json`/`void_json`, which do not exist yet this early in the cycle
  # (they depend on this same loop's `ordered_repos_json` for the work-gone
  # reconciliation passes below) — see "3c/3u. Pre-fetched-band eligibility"
  # further down, which filters every one of these arrays in place, a second
  # time, once they do.
  #
  # Pre-fetch security/code-quality findings only when this repo lists either
  # source, so a repo that opts out of them costs no gh calls. first-seen is
  # emitted on the raw array, split by each finding's own `.source`, before
  # exclusion — findings is the one pre-fetch that mixes two first-seen
  # sources in one gather call.
  findings="[]"
  if jq -e 'any(.[]; . == "security" or . == "code-quality")' <<<"$sources" >/dev/null 2>&1; then
    findings_raw="$(gather_findings "$slug")"
    emit_first_seen "$slug" security "$(jq -c '[.[] | select(.source == "security")]' <<<"$findings_raw")"
    emit_first_seen "$slug" code-quality "$(jq -c '[.[] | select(.source == "code-quality")]' <<<"$findings_raw")"
    findings="$(exclude_claimed_items "$findings_raw" "$claimed_item_refs_json")"
  fi
  review_feedback="[]"
  if jq -e 'any(.[]; . == "review-feedback")' <<<"$sources" >/dev/null 2>&1; then
    review_feedback_raw="$(gather_review_feedback "$slug")"
    emit_first_seen "$slug" review-feedback "$review_feedback_raw"
    review_feedback="$(exclude_claimed_items "$(exclude_claimed_prs "$review_feedback_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  # Unconditional, unlike its neighbours: `abandoned-drafts` is a required
  # member of every repository's `sources` (the schema's `contains` rule;
  # requirement 3e, agent-ops#472) — the only route back to a draft this
  # system raised and then abandoned.
  abandoned_drafts_raw="$(gather_abandoned_drafts "$slug")"
  emit_first_seen "$slug" abandoned-drafts "$abandoned_drafts_raw"
  abandoned_drafts="$(exclude_claimed_items "$(exclude_claimed_prs "$abandoned_drafts_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  merge_conflicts="[]"
  if jq -e 'any(.[]; . == "merge-conflicts")' <<<"$sources" >/dev/null 2>&1; then
    merge_conflicts_raw="$(gather_merge_conflicts "$slug")"
    emit_first_seen "$slug" merge-conflicts "$merge_conflicts_raw"
    merge_conflicts="$(exclude_claimed_items "$(exclude_claimed_prs "$merge_conflicts_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  dequeued="[]"
  if jq -e 'any(.[]; . == "dequeued")' <<<"$sources" >/dev/null 2>&1; then
    dequeued_raw="$(gather_dequeued "$slug")"
    emit_first_seen "$slug" dequeued "$dequeued_raw"
    dequeued="$(exclude_claimed_items "$(exclude_claimed_prs "$dequeued_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
  register_hygiene="[]"
  if jq -e 'any(.[]; . == "register-hygiene")' <<<"$sources" >/dev/null 2>&1; then
    register_hygiene_raw="$(gather_register_hygiene "$slug" "$default_branch" prefetch)"
    emit_first_seen "$slug" register-hygiene "$register_hygiene_raw"
    register_hygiene="$(exclude_claimed_items "$register_hygiene_raw" "$claimed_item_refs_json")"
  fi
  # The issues source is one source at four ranks (`issues:urgent` …
  # `issues:low`, requirement 15e), so any band in `sources` warrants the one
  # fetch — the band is per issue, not per fetch.
  issues="[]"
  issues_excluded="[]"
  if jq -e 'any(.[]; startswith("issues"))' <<<"$sources" >/dev/null 2>&1; then
    issues_raw="$(gather_issues "$slug")"
    emit_first_seen "$slug" issues "$issues_raw"
    issues="$(exclude_claimed_items "$issues_raw" "$claimed_item_refs_json")"
    # Requirement 16.4's deterministic drops (assigned, `blocked`-labelled,
    # unresolved `Blocked-by:`), reported rather than lost the moment
    # scripts/gather-issues.sh applies them (agent-ops#447): a repo with
    # drops leaves an `issues-excluded` event any reader of the shared log —
    # the cycle record, the dashboard's log tail — can see without
    # re-deriving the filter by hand.
    #
    # Logged only when this repo's exclusion set differs from the one most
    # recently logged for it (review decision on agent-ops#452 concern 1):
    # an onset and a release are both changes, so "now empty" logs exactly as
    # "now non-empty" does, and a quiet cycle logs nothing because nothing
    # changed — not because $issues_excluded happens to be empty this time.
    # Fail open on the *previous*-state read: if it cannot be read, log
    # unconditionally rather than risk staying silent — silence is the #447
    # failure class this event exists to remove.
    #
    # The *current* set gets no such leniency (review decision on
    # agent-ops#452 concern 3): `gather_issues_excluded` reports `null`,
    # never `[]`, when the gather failed or degraded — the deterministic
    # filter did not run to completion, so the exclusion set is unknown, not
    # known-empty. Comparing an unknown current set against a known previous
    # one would fabricate a release event on an ordinary `gh` hiccup and, by
    # overwriting the baseline, mask a genuinely stuck exclusion behind a
    # flapping gatherer. A `null` current set therefore skips the
    # comparison, the event and the baseline update entirely — a failed
    # gather is a no-op on the event stream, not a claim about it — while
    # the Co-Ordinator's own runtime input still gets an array: `[]` for
    # "nothing to report", the same reading requirement 3j already gives an
    # empty `candidates`.
    issues_excluded_raw="$(gather_issues_excluded "$slug")"
    if [[ "$issues_excluded_raw" != "null" ]]; then
      issues_excluded="$issues_excluded_raw"
      issues_excluded_changed=1
      if prev_issues_excluded="$(jq -ce --arg r "$slug" '(.[$r] // [])' \
            <<<"$latest_issues_excluded_json" 2>/dev/null)"; then
        if issues_excluded_same="$(jq -nc --argjson prev "$prev_issues_excluded" --argjson cur "$issues_excluded" \
              '($prev | sort_by(.number, .reason)) == ($cur | sort_by(.number, .reason))' 2>/dev/null)" \
            && [[ "$issues_excluded_same" == "true" ]]; then
          issues_excluded_changed=0
        fi
      fi
      if [[ "$issues_excluded_changed" == "1" ]]; then
        log_event "issues-excluded" "$(jq -nc --arg r "$slug" --argjson ex "$issues_excluded" \
          '{repo: $r, count: ($ex | length),
            detail: (($ex | length | tostring) + " issue(s) excluded"
                     + (if ($ex | length) > 0
                        then ": " + ([$ex[] | "#\(.number) (\(.reason))"] | join(", "))
                        else "" end)),
            excluded: $ex}')"
        latest_issues_excluded_json="$(jq -c --arg r "$slug" --argjson ex "$issues_excluded" \
          '.[$r] = $ex' <<<"$latest_issues_excluded_json" 2>/dev/null || printf '%s' "$latest_issues_excluded_json")"
      fi
    fi
  fi
  tech_debt="[]"
  if jq -e 'any(.[]; . == "tech-debt")' <<<"$sources" >/dev/null 2>&1; then
    tech_debt_raw="$(gather_tech_debt "$slug" "$default_branch")"
    emit_first_seen "$slug" tech-debt "$tech_debt_raw"
    tech_debt="$(exclude_claimed_items "$tech_debt_raw" "$claimed_item_refs_json")"
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
  # findings/review_feedback/abandoned_drafts/merge_conflicts/dequeued/
  # register_hygiene/issues/tech_debt are the pre-fetched bands themselves —
  # issue threads (requirement 3d/#118) and the open tech-debt register
  # (requirement 3t/#310) included — each unbounded past this call and each
  # tens of kilobytes alone; $sources is this repo's configured source list,
  # bounded by config, and stays in argv (requirement 4g). The eight bands arrive on
  # stdin, one document per line, bound positionally with `input as $name` in
  # the order printed (TD-PPagop-26081406) — never in argv, where past
  # MAX_ARG_STRLEN this build would silently drop the repo's whole entry.
  entry_docs="$(printf '%s\n' "$findings" "$review_feedback" "$abandoned_drafts" \
    "$merge_conflicts" "$dequeued" "$register_hygiene" "$issues" "$tech_debt")"
  # `issues_excluded` rides in as its own --argjson, not on this stdin
  # stream: unlike the eight bands above, it is bounded by the gatherer's own
  # 100-item page (scripts/gather-issues.sh) and each entry is a bare number
  # and a short reason, tens of bytes at most — nowhere near MAX_ARG_STRLEN.
  entry="$(jq -nc --arg slug "$slug" --arg db "$default_branch" --argjson sources "$sources" \
    --arg ipp "$implementation_plan_path" --argjson ie "$issues_excluded" \
    'input as $findings | input as $rf | input as $ad | input as $mc | input as $dq | input as $rh
     | input as $issues | input as $td
     | {slug: $slug, default_branch: $db, sources: $sources, findings: $findings, review_feedback: $rf, abandoned_drafts: $ad, merge_conflicts: $mc, dequeued: $dq, register_hygiene: $rh, human_visibility: [], issues: $issues, issues_excluded: $ie, tech_debt: $td}
     + (if $ipp == "" then {} else {implementation_plan_path: $ipp} end)' <<<"$entry_docs")"
  # $entry — one repo's whole pre-fetched sources, including issue threads
  # (requirement 3d/#118) and its open tech-debt register (requirement
  # 3t/#310) — is the least bounded value in this loop, and the accumulator it
  # joins only grows every iteration. Both arrive on stdin, one document per
  # line, bound positionally with `input as $name` in the order printed
  # (requirement 4g) — never in argv, where past MAX_ARG_STRLEN this append
  # would silently drop the repo from the Co-Ordinator's whole input.
  ordered_repos_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
    <<<"$ordered_repos_json"$'\n'"$entry")"
  # --- Labels (requirement 6a, agent-ops#687) ---
  # Every repository this cycle gathers data for, not only the one it later
  # selects to work: the Co-Ordinator's block-label projection and the
  # Refiner's own can both reach a repository step 6a below never touches, so
  # ensuring only there left both silently unable to create anything the first
  # time either ran against a fresh repository. Rate-limited by a stamp under
  # `state_dir` (`labels_ensure_interval_hours`, default 24h) so the steady
  # state stays one listing per repository per interval and zero writes.
  gathered_labels_report="$(labels_ensure_stamped "$state_dir" "$CONFIG_FILE" "$SCHEMA_FILE" \
    "$slug" target "$labels_ensure_interval_hours" 2>/dev/null || true)"
  if [[ -n "$gathered_labels_report" ]]; then
    log_event "labels-ensured" "$(jq -nc --arg repo "$slug" --arg report "$gathered_labels_report" '
      {repo: $repo, role: "target"}
      + ($report | split("\n") | map(select(length > 0) | split("\t"))
         | {created: [.[] | select(.[0] == "created") | .[1]],
            failed:  [.[] | select(.[0] == "failed")  | .[1]]})')"
  fi
  # Kept in a separate array, never folded into the entry above: this is the
  # Script's own bookkeeping, and every byte added to `ordered_repos_json` is a
  # byte the Co-Ordinator pays to read. A cost-control feature that grows the
  # prompt it is meant to avoid buying has not saved anything.
  state="$(gather_source_state "$slug" "$default_branch")"
  source_states_json="$(jq -nc 'input as $arr | input as $s | $arr + [$s]' \
    <<<"$source_states_json"$'\n'"$state")"
  # Requirement 34f, gathered here for the repo loop's one `gh` budget but read
  # below, before the skip-lists: a human's instruction to reopen a void has to
  # land *before* the extract the Co-Ordinator is handed, not after it.
  unvoid_requests_json="$(jq -nc 'input as $arr | input as $r | $arr + $r' \
    <<<"$unvoid_requests_json"$'\n'"$(gather_unvoid_requests "$slug")")"
  # Requirement 34g, same reasoning: a human's hand-applied label has to reach
  # the skip-list before the Co-Ordinator is handed it. An empty
  # `needs_refinement_label` disables the projection entirely (README.md), so
  # there is nothing to scan for and no `gh` call to spend.
  if [[ -n "$needs_refinement_label" ]]; then
    hand_flagged_refinements_json="$(jq -nc 'input as $arr | input as $r | $arr + $r' \
      <<<"$hand_flagged_refinements_json"$'\n'"$(gather_hand_flagged_refinements "$slug")")"
  fi
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
unvoid_clearances_n="$(jq 'length' <<<"$unvoid_clearances_json" 2>&1)" \
  || { guard_warn "unvoid_clearances_n" "$unvoid_clearances_n"; unvoid_clearances_n=0; }
if [[ "$unvoid_clearances_n" != "0" ]]; then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
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
#
# Requirement 39f narrows the *new* half, and only that half: an issue still
# carrying the label because this system's own removal silently failed is not
# a human asking for anything, so `label_filter_own_applications` drops it
# before the "not already blocked" test ever sees it. The `cleared` half below
# reads the unfiltered list on purpose — it asks which issues have *lost* the
# label, and an entry filtered out for being our own would read there as a
# label that had gone, unblocking the very item this rule exists to leave
# alone.
if [[ -n "$needs_refinement_label" ]]; then
  refinement_own_actions_json="$(label_own_actions_map "$needs_refinement_label" "$union_log")"
  hand_flagged_not_ours_json="$(label_filter_own_applications "$hand_flagged_refinements_json" \
    "$refinement_own_actions_json" "$union_log_horizon")"
  hand_flag_new_json="$(refinement_hand_flag_new "$hand_flagged_not_ours_json" "$(blocked_items "$union_log")")"
  hand_flag_new_n="$(jq 'length' <<<"$hand_flag_new_json" 2>&1)" \
    || { guard_warn "hand_flag_new_n" "$hand_flag_new_n"; hand_flag_new_n=0; }
  if [[ "$hand_flag_new_n" != "0" ]]; then
    log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
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

  # Requirement 39f's retry: `label_filter_own_applications` above has already
  # proven each entry `label_own_stale_applications` returns here to be our own
  # last action, and the blocked extract it is given here proves the other half
  # — that no block stands behind the label any more. Both tests are needed,
  # and the second is the one that keeps this from undoing requirement 34e: a
  # label the Script applied to an item it blocked one cycle ago is *also* our
  # own last action, and removing that one would strip the live projection of
  # an open block off the issue while the human is still being waited on. What
  # is left after both is exactly the set `release_refinement_label`'s own
  # removal attempt failed on.
  #
  # The extract is read here rather than reused from above so it includes the
  # hand-flag blocks this cycle just wrote (appended to `union_log` in the
  # branch above) — an issue whose label earned a block moments ago is not a
  # stuck one. Best-effort, like every other label write: a second failure
  # costs nothing beyond what the first already did, and the filter above
  # already keeps the label from being misread as a fresh flag on any cycle in
  # between.
  if ! (( DRY_RUN )); then
    hand_flag_stale_json="$(label_own_stale_applications "$hand_flagged_refinements_json" \
      "$refinement_own_actions_json" "$(blocked_items "$union_log")" "$union_log_horizon")"
    while IFS=$'\t' read -r stale_repo stale_number; do
      [[ -n "$stale_repo" && -n "$stale_number" ]] || continue
      if refinement_label_remove "$stale_repo" "$stale_number" "$needs_refinement_label"; then
        log_event "own-label-action" \
          "$(label_own_action_fields "$stale_repo" "$stale_number" "$needs_refinement_label" "remove")"
      else
        log_event "warning" \
          "$(jq -nc --arg d "could not retry removing the $needs_refinement_label label from $stale_repo#$stale_number" \
             '{detail: $d}')"
      fi
    done < <(jq -r '.[] | [(.repo // ""), ((.number // "") | tostring)] | @tsv' \
               <<<"$hand_flag_stale_json" 2>/dev/null || true)
  fi

  hand_flag_cleared_json="$(refinement_hand_flag_cleared "$hand_flagged_refinements_json" "$(blocked_items "$union_log")")"
  hand_flag_cleared_n="$(jq 'length' <<<"$hand_flag_cleared_json" 2>&1)" \
    || { guard_warn "hand_flag_cleared_n" "$hand_flag_cleared_n"; hand_flag_cleared_n=0; }
  if [[ "$hand_flag_cleared_n" != "0" ]]; then
    log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
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

# Requirement 38b's own reconciliation sweep for `blocked`/`blocked:<reason>`
# (agent-ops#651), unconditional — unlike the `needs_refinement_label` block
# above, these two labels are not configurable and carry no hand-flag path, so
# this runs every cycle regardless. Unlike requirement 39f's stale-retry, no
# live GitHub read or own/human attribution heuristic is needed:
# `refinement_blocked_label_stale` already proves an `own-label-action add`
# recorded for the label is ours with nothing but the log, so a
# `release_refinement_label` removal that silently failed at the moment its
# block cleared gets retried here rather than sitting on the issue forever —
# the same permanently-stuck-hold class of failure agent-ops#639 ended for the
# assignment-based mechanism, reopened on the label list if this half were
# skipped.
if ! (( DRY_RUN )); then
  while IFS=$'\t' read -r stale_repo stale_item stale_label; do
    [[ -n "$stale_repo" && -n "$stale_item" && -n "$stale_label" ]] || continue
    if refinement_label_remove "$stale_repo" "$stale_item" "$stale_label"; then
      log_event "own-label-action" \
        "$(label_own_action_fields "$stale_repo" "$stale_item" "$stale_label" "remove")"
    else
      log_event "warning" \
        "$(jq -nc --arg d "could not retry removing the $stale_label label from $stale_repo#$stale_item" \
           '{detail: $d}')"
    fi
  done < <(refinement_blocked_label_stale "$(blocked_items "$union_log")" "$union_log")
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
  reg_map="$(gather_register_status "$reg_slug" "$reg_branch" blocked $reg_ids)"
  register_status_json="$(jq -c --arg s "$reg_slug" --argjson m "$reg_map" '. + {($s): $m}' \
    <<<"$register_status_json" 2>/dev/null || printf '%s' "$register_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
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
  rev_map="$(gather_review_status "$rev_slug" "$rev_branch" blocked $rev_refs)"
  review_status_json="$(jq -c --arg s "$rev_slug" --argjson m "$rev_map" '. + {($s): $m}' \
    <<<"$review_status_json" 2>/dev/null || printf '%s' "$review_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
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
    <<<"$ordered_repos_json" 2>&1)" || { guard_warn "work-gone:plan_entry" "$plan_entry"; plan_entry='{}'; }
  plan_branch="$(jq -r '.default_branch // ""' <<<"$plan_entry" 2>/dev/null || true)"
  plan_path="$(jq -r '.implementation_plan_path // ""' <<<"$plan_entry" 2>/dev/null || true)"
  [[ -n "$plan_branch" && -n "$plan_path" ]] || continue
  # shellcheck disable=SC2086  # $plan_ids is a deliberate word-split id list.
  plan_map="$(gather_plan_status "$plan_slug" "$plan_branch" "$plan_path" blocked $plan_ids)"
  plan_status_json="$(jq -c --arg s "$plan_slug" --argjson m "$plan_map" '. + {($s): $m}' \
    <<<"$plan_status_json" 2>/dev/null || printf '%s' "$plan_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
         <<<"$(work_gone_plan_ids "$open_blocked_now")" 2>/dev/null || true)

work_gone_json="$(work_gone_clearances "$open_blocked_now" "$source_states_json" "$register_status_json" \
                   "$review_status_json" "$plan_status_json")"
work_gone_n="$(jq 'length' <<<"$work_gone_json" 2>&1)" \
  || { guard_warn "work_gone_n" "$work_gone_n"; work_gone_n=0; }
if [[ "$work_gone_n" != "0" ]]; then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
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

# Requirement 34j, applied last of the four reconciliations and for the same
# reason as 34f, 34g and 34i above: it has to land before the extract the
# Co-Ordinator, the Enabler's eligible set and the dashboard are all handed.
# What it clears is a block whose own `Blocked-by:` dependency has resolved —
# read from this cycle's own `issues` candidates, already reshaped once per
# repo above, so no second `gh` read is spent deciding it: an already-blocked
# issue reappearing there this cycle is itself gather-issues.sh's live proof
# that every reference it named is now closed.
issues_by_repo_json="$(jq -c '
  map({key: .slug,
       value: ((.issues // [])
               | map({key: (.number | tostring),
                      value: {body: (.body // ""), comments: (.comments // [])}})
               | from_entries)})
  | from_entries' <<<"$ordered_repos_json" 2>/dev/null || true)"
[[ -n "$issues_by_repo_json" ]] || issues_by_repo_json='{}'

dependency_json="$(dependency_clearances "$open_blocked_now" "$issues_by_repo_json")"
dependency_n="$(jq 'length' <<<"$dependency_json" 2>&1)" \
  || { guard_warn "dependency_n" "$dependency_n"; dependency_n=0; }
if [[ "$dependency_n" != "0" ]]; then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
  while IFS= read -r clearance; do
    [[ -n "$clearance" ]] || continue
    # `by: "dependency-resolved"` distinguishes this from the Co-Ordinator's
    # own `unblocked` (requirement 18), the Enabler's, the label-driven one of
    # requirement 34g, and requirement 34i's `work-gone`; `detail` carries the
    # reference(s) that decided it, so a later reader can audit the clearance
    # without re-deriving it.
    log_event "unblocked" "$(jq -c '{item: .item, repo: .repo, by: "dependency-resolved",
                                      detail: .reason}' <<<"$clearance")"
  done < <(jq -c '.[]' <<<"$dependency_json" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
fi

blocked_json="$(blocked_items "$union_log")"
void_json="$(void_items "$union_log")"

# Requirement 34n's memory, applied the moment the extract exists: every pair
# an earlier cycle already retired (a `void-retired` event on the log — a
# fact, not a state, exactly as `void-object-closed` is) is subtracted here,
# before the 34k sweep, the 34l register pass and 34n's own evidence-gathering
# below ever see the set. Two bounds follow that re-deciding retirement from
# scratch each cycle would not give: the register read below runs only over
# the *unretired* residue, so an id retired once is never asked about again —
# per-cycle GitHub cost proportional to what is still live, not to every void
# ever filed — and the extract stays bounded even on a cycle whose register
# read fails, because this subtraction needs nothing but the log. The
# subtraction is ts-ordered (`subtract_retired_voids`): an item voided afresh
# after its old verdict retired re-enters on the new verdict's own terms.
#
# Neither pass between here and 34n loses anything to the narrowing: 34k's
# closed-object gate already skips every issue- or PR-shaped id a retirement
# could cover (a closed object is what actioned it), and 34l's register repair
# has nothing to do once a row reads `resolved`/`not-debt`, which retirement
# itself required first — narrowing before 34l is what stops a repo whose
# void register ids are all retired paying a register fetch forever. The 34f
# label route is computed further up, from `void_items` directly, so a human's
# `unvoided` still reaches a retired-but-void item.
#
# Gated on the same switch as retirement itself: `0` must restore the full,
# unretired extract — the recorded facts stay on the log, but stop masking —
# so an operator has a kill switch if retirement ever misbehaves, and flipping
# it back re-masks from the log with nothing re-queried.
if (( void_retire_after_days > 0 )); then
  void_json="$(subtract_retired_voids "$void_json" "$(void_retired_items "$union_log")")"
fi

# 34k: act on void. A void already stops the item being selected again
# (requirement 34c), but nothing before this touched the GitHub object it
# names, so an obsolete draft PR or a superseded issue stayed open — visible
# to every human and re-derived void by cycle after cycle (issue #240;
# poetic-fiddle #190/#214 were re-derived void on 7+ separate cycles, never
# closed). Only the two id shapes that name a GitHub object at all — a bare
# issue number, or `pr-<n>-…` — are in scope; a register id, a review ref or
# a plan task id names nothing this can close. `void_object_closed_items`
# excludes whatever a previous cycle already actioned, so this never
# re-checks (and never re-closes) the same item twice, even if a human
# reopens the object directly rather than through `unvoid_label`. The event's
# `stage` travels with each candidate because the sweep's corroboration gate
# keys on it — every writer's `item-void` passes requirement 34d before it is
# logged (issue #243), so all three are eligible, and the gate itself lives in
# close-void-github-items.sh (requirement 34a: one definition, at the point
# of action). Skipped on --dry-run: the sweep closes issues and pull
# requests.
if ! (( DRY_RUN )); then
  void_object_closed_json="$(void_object_closed_items "$union_log")"
  # Both arrays arrive on stdin, one document per line, never in argv
  # (requirement 4g): the void extract and the closed set are unbounded, and
  # on 2026-08-12 the extract crossed MAX_ARG_STRLEN — an `--argjson`
  # delivery here failed into its `|| echo '[]'`, silently disabling the one
  # sweep that retires void state.
  void_close_stdin="$void_json"$'\n'"$void_object_closed_json"
  void_close_candidates_json="$(jq -nc \
    --arg issue_re "$WORK_GONE_ISSUE_RE" --arg pr_re "$WORK_GONE_PR_RE" '
    input as $void | input as $closed
    | ($closed | map(.repo + " " + .item)) as $done
    | [ $void[]
        | select((.repo // "") != "" and (.item // "") != "")
        | select((.item | test($issue_re)) or (.item | test($pr_re)))
        | select((.repo + " " + .item) as $k | ($done | index($k)) == null) ]
  ' <<<"$void_close_stdin" 2>&1)" \
    || { guard_warn "void_close_candidates_json" "$void_close_candidates_json"; void_close_candidates_json='[]'; }
  while IFS= read -r vslug; do
    [[ -n "$vslug" ]] || continue
    repo_candidates_json="$(jq -c --arg r "$vslug" '[ .[] | select(.repo == $r)
      | {item, detail, evidence, stage} ]' <<<"$void_close_candidates_json" 2>&1)" \
      || { guard_warn "void:repo_candidates_json" "$repo_candidates_json"; repo_candidates_json='[]'; }
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        closed) log_event "void-object-closed" \
          "$(jq -c --arg r "$vslug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        deferred|warning) log_event "warning" "$(jq -c --arg r "$vslug" \
          '{detail: ("act-on-void sweep (" + $r + "): " + (del(.repo) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(printf '%s' "$repo_candidates_json" \
               | timeout 120 "$SCRIPT_DIR/scripts/close-void-github-items.sh" "$vslug" "$node_name" "$cycle_id" \
                 2>>"$cycle_dir/void-close-sweep.err" || true)
  done < <(jq -r '[.[].repo] | unique[]' <<<"$void_close_candidates_json" 2>/dev/null || true)
fi

# Register rows, requirement 34l — the other half of acting on a void: a void
# item shaped like a tech-debt register id (issue #240) names a file, not a
# GitHub object, so close-void-github-items.sh above leaves it untouched
# entirely — this instead re-derives that repo's register-hygiene candidate
# with the void evidence folded in (gather-register-hygiene.sh's VOIDED STATUS
# problem class), so the ordinary register-hygiene Implementer flow flips
# the row exactly as it repairs any other frontmatter drift. Only for repos
# that actually have a void register item — everywhere else costs nothing
# beyond the one jq read below. This necessarily re-fetches the register (a
# second read this cycle, alongside the plain one the loop at "3. Repo
# ordering" already took) because that earlier pass runs before void_json
# exists to hand it; the alternative is reordering the cycle around a state
# read this is the only consumer of.
void_register_ids_json="$(work_gone_register_ids "$void_json")"
while IFS= read -r vr_slug; do
  [[ -n "$vr_slug" ]] || continue
  vr_branch="$(jq -r --arg s "$vr_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
    <<<"$ordered_repos_json" 2>/dev/null || true)"
  [[ -n "$vr_branch" ]] || continue
  # The void extract on stdin, never in argv (requirement 4g) — same failure
  # shape as the sweep above: past MAX_ARG_STRLEN this call would fall into
  # its `|| echo '[]'` and the pass would silently find nothing. `ids` stays
  # an --argjson: it is one repo's matching register ids, bounded by the
  # register itself.
  vr_candidates_json="$(jq -c --arg r "$vr_slug" \
    --argjson ids "$(jq -c --arg s "$vr_slug" '.[$s] // []' <<<"$void_register_ids_json")" \
    -n 'input as $void
        | [ $void[] | select(.repo == $r and (.item as $i | $ids | index($i)) != null)
            | {item, detail, evidence} ]' <<<"$void_json" 2>&1)" \
    || { guard_warn "vr_candidates_json" "$vr_candidates_json"; vr_candidates_json='[]'; }
  vr_hygiene_json="$(gather_register_hygiene "$vr_slug" "$vr_branch" void "$vr_candidates_json")"
  # Only ever *adds* to what the first pass found. gather_register_hygiene
  # fails safe to `[]`, and this second read can fail where the first
  # succeeded — a rate limit, a network blip, a branch moved between the two.
  # Overwriting on that answer would delete a genuine register-hygiene
  # candidate the cycle already holds, on no evidence at all; the whole point
  # of this pass is a superset of the first, so an empty result is the one
  # answer it can never mean. `purpose void` is what keeps that reasoning
  # true of the tee files as well as of this variable: the two passes wrote
  # to one filename until requirement 34n's liveness rule started reading it,
  # at which point this pass's failure became a false retirement of the other
  # pass's still-live findings.
  vr_hygiene_n="$(jq 'length' <<<"$vr_hygiene_json" 2>&1)" \
    || { guard_warn "vr_hygiene_n" "$vr_hygiene_n"; vr_hygiene_n=0; }
  [[ "$vr_hygiene_n" != "0" ]] || continue
  ordered_repos_json="$(jq -c --arg r "$vr_slug" --argjson rh "$vr_hygiene_json" \
    'map(if .slug == $r then .register_hygiene = $rh else . end)' \
    <<<"$ordered_repos_json" 2>/dev/null || printf '%s' "$ordered_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -r 'keys[]' <<<"$void_register_ids_json" 2>/dev/null || true)

# Human-visibility hygiene, requirement 38e — the read-back half of
# tech-debt/TD-PPagop-26080801.md's fix: a violation requirement 38c's sweep
# could not self-heal (logged above as a `warning`) is read back out of
# `union_log`, re-verified live by scripts/gather-human-visibility-hygiene.sh
# (a stale or already-resolved one is dropped there, never here), and — where
# one survives — assigned into that repo's own `human_visibility` array. Its
# own source (issue #284's decision 2), never register-hygiene's: a violation
# here means finished work is invisible to the human whose merge everything
# waits on, ranked immediately after `merge-conflicts` (config.schema.json),
# the same "finishing beats starting" class as the four sources around it —
# register-hygiene's cosmetic-repair, last-place rationale does not describe
# it. Assigned, not appended: unlike `register_hygiene` above (which two
# passes can each contribute to — the plain gather and the void
# re-derivation) this array has exactly one writer, so there is nothing a
# plain assignment could clobber. Only for repos whose `sources` actually
# list `human-visibility`, and only for repos this reduction found a
# violation for at all — everywhere else costs nothing beyond the one
# reduction over `union_log` below, already read once each for `blocked_json`
# and `void_json` above.
#
# ...with one addition (agent-ops#646): a repo carrying *unretired
# `human-visibility-<hash>` void residue* is walked too, even with no live
# violation of its own. That is the only case in which the walk's own "found a
# violation for it" test and requirement 34n's liveness rule want opposite
# answers — the rule needs a definite "this repo yields no such ref this
# cycle", and a repo the walk skipped leaves no `.ok` marker to say so, which
# `void_liveness_actioned` reads as ungathered and declines to decide on
# forever. It is exactly the bound the `failed-run` shape's own extra fetch
# takes further down, and it is free: with no violations to re-verify,
# scripts/gather-human-visibility-hygiene.sh makes no `gh` call at all and
# prints `[]` on the empty input, which is the definite answer the rule was
# missing. `hv_finding_n` of `0` then skips the assignment below, so a repo
# added by this clause contributes a marker and nothing else — it can never
# manufacture a candidate.
human_visibility_json="$(human_visibility_violations "$union_log")"
# The reduction's own validity gate, and the reason it is a gate rather than a
# fallback to `[]`: a malformed reduction is not "no violations", it is "no
# answer", and handing `[]` to the gatherer for a repo whose violations we
# failed to read would mint an `.ok` marker over an emptiness we never
# established — the one way the marker could lie. So an unreadable reduction
# walks nothing at all, exactly as it did before agent-ops#646 widened the
# walk, and every human-visibility void simply stays undecided for a cycle.
human_visibility_n="$(jq 'length' <<<"$human_visibility_json" 2>&1)" \
  || { guard_warn "human_visibility_n" "$human_visibility_n"; human_visibility_n=""; }
hv_void_repos_json="$(jq -c --arg re "$VOID_LIVENESS_HUMAN_VISIBILITY_RE" '
  [ .[] | select((.repo // "") != "" and ((.item // "") | test($re))) | .repo ] | unique' \
  <<<"$void_json" 2>&1)" \
  || { guard_warn "hv_void_repos_json" "$hv_void_repos_json"; hv_void_repos_json='[]'; }
[[ -n "$human_visibility_n" ]] || hv_void_repos_json='[]'
while IFS= read -r hv_slug; do
  [[ -n "$hv_slug" ]] || continue
  jq -e --arg r "$hv_slug" \
    'any(.[]; .slug == $r and ((.sources // []) | any(.[]; . == "human-visibility")))' \
    <<<"$ordered_repos_json" >/dev/null 2>&1 || continue
  hv_candidates_json="$(jq -c --arg r "$hv_slug" '[.[] | select(.repo == $r)]' <<<"$human_visibility_json")"
  hv_finding_json="$(gather_human_visibility_hygiene "$hv_slug" "$hv_candidates_json")"
  hv_finding_n="$(jq 'length' <<<"$hv_finding_json" 2>&1)" \
    || { guard_warn "hv_finding_n" "$hv_finding_n"; hv_finding_n=0; }
  [[ "$hv_finding_n" != "0" ]] || continue
  ordered_repos_json="$(jq -c --arg r "$hv_slug" --argjson hv "$hv_finding_json" \
    'map(if .slug == $r then .human_visibility = $hv else . end)' \
    <<<"$ordered_repos_json" 2>/dev/null || printf '%s' "$ordered_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -rn --argjson v "$hv_void_repos_json" \
         'input as $hv | (($hv | map(.repo)) + $v) | unique[]' \
         <<<"$human_visibility_json" 2>/dev/null || true)

# Requirement 34n: retire every void entry that is both fully actioned and
# old enough out of `void_json` before anything else reads it — from here on
# `void_json` *is* the bounded extract, reassigned rather than shadowed under
# a new name so every consumer below (the Refiner's candidate filter, the
# no-op fingerprint, the Co-Ordinator's own input) sees it with nothing to
# remember. This is what stops the extract growing without bound: on
# 2026-08-12 it reached 122 entries and 133,615 bytes — past `MAX_ARG_STRLEN`
# — because nothing before this requirement ever retired an entry once it was
# actioned; the only way one left the set at all was a human's hand-appended
# `unvoided` (issue #309).
#
# The 34k sweep and the 34l register-hygiene pass above saw the extract with
# *recorded* retirements already subtracted (the block where `void_json` is
# first computed), but not the ones this block is about to decide — and
# neither needs those either, being already safe to run against an
# item this rule would go on to retire — 34k's own `void_object_closed_items`
# gate already skips a closed object, and 34l's register-hygiene repair has
# nothing left to do once the row already reads `resolved`/`not-debt`, which
# is exactly the state this rule requires before it will retire a register
# void at all. `unvoid_clearances_json`, computed earlier from `void_items`
# directly, is unaffected for the same reason `void_items` itself is: neither
# this reassignment nor requirement 34c's own semantics change — a void stays
# void forever, on the raw log, for every reader that recomputes it there
# (`open_blocked_items`, `enabler_eligible_items`, `refinements_map`, and the
# monitoring dashboard's own use of `void_items`). Retirement narrows only
# what this one cycle goes on to hand somebody, never what counts as void.
#
# "Actioned" is built from six signals, none of them needing a `gh` call this
# rule does not already budget for:
#
#   - an issue or pull request GitHub itself confirms closed
#     (`void_object_closed_items`, re-read here — a pure function over the
#     union log already in memory, costing nothing);
#   - a tech-debt register row whose own file says `status: resolved` or
#     `status: not-debt` — 34i's own "the work is gone" statuses, read by a
#     further `gather_register_status` call per repo with still-unretired void
#     register ids, alongside the one 34i already makes for that repo's
#     blocked ones — the recorded subtraction above is what keeps that
#     residue, and so this read, bounded;
#   - liveness, for the six shapes the cycle already gathers as structured
#     data each cycle (TD-PPagop-26081303, extended by TD-PPagop-26081409):
#     a `dependabot-alert-<n>`/
#     `code-scanning-alert-<n>`, a `register-hygiene-<hash>`, either
#     merge-conflicts shape (`pr-<n>-conflict-<head-sha>`, which requirement
#     34k deliberately excludes from its own close, and
#     `pr-<n>-superseded-<head-sha>`, which it closes — same gather, so the
#     same test decides both), a `pr-<n>-dequeued-<head-sha>` (requirement 3z,
#     excluded from 34k's close for the same reason as the conflict shape), or
#     a `failed-run-<…>` is
#     actioned once its id is absent from this cycle's own gather for that
#     source, and that gather succeeded (`void_liveness_actioned`,
#     lib/void-liveness.sh) — read off the same tee files the repo loop
#     already wrote for the first four, and one further
#     `gather_workflow_basenames` call per repo with still-unretired
#     `failed-run-` void ids for the fifth; and
#   - a merged pull request, for a project-review ref, or a checked task-list
#     box, for an implementation-plan task id — the same on-demand readers
#     34i already calls for the blocked set (`gather_review_status`,
#     `gather_plan_status`), read here for the void residue
#     (`void_review_plan_actioned`, lib/void-liveness.sh); and
#   - the configuration itself, for the residue none of the four above can
#     reach (`void_config_actioned`, lib/void-liveness.sh; PR #340 review):
#     liveness needs the source's own successful gather, and a source is
#     gathered only for a repo whose `sources` still list it, so a repo that
#     drops `merge-conflicts` — or `security`, or `register-hygiene` — freezes
#     every void of that shape it had already minted, and a repo dropped from
#     the config altogether freezes every shape but the closed-object one.
#     Both are read straight off `all_repos_json`, which costs nothing and is
#     deliberately the *unnarrowed* array: `repos_json` carries `--repo`'s
#     filter, under which every other repo would read as dropped, and
#     `ordered_repos_json`'s own `sources` are rewritten by back-pressure
#     (step 2.2a, further down) to the four finishing sources.
#
# Age-only retirement for the six liveness shapes was considered and
# rejected: a void whose id is *still being gathered* — a still-open alert, a
# register-hygiene finding the register still has, a workflow still failing, a
# PR still conflicted — is doing live suppression work every cycle, and
# retiring it on age alone would re-expose the item to be rediscovered void
# all over again, the exact rediscovery churn requirement 34k exists to stop.
# That objection does not reach the config signal: it needs the item to be
# re-offered, which needs a human to re-add the source or the repo, at which
# point one rediscovery pass is the correct behaviour of a newly-enabled
# source and is bounded by what is still live at that moment.
# A void naming no repo (the hand-appended form requirement 34c allows) never
# matches any of these six signals, so it is left, as it always was, for a
# human to retract.
#
# Each entry this block retires is recorded as a `void-retired` event —
# `{repo, item, void_ts, by}`, a fact rather than a state exactly as
# `void-object-closed` is (requirement 34k) — which is what makes the
# decision durable: the subtraction where `void_json` is first computed reads
# those events back, so a settled id is never re-evidenced or re-decided, and
# the register read here stays proportional to the unretired residue instead
# of growing by one id per void ever retired. The recording is skipped on
# --dry-run, like the 34k sweep itself — it is a durable mark on the log —
# while the in-memory narrowing still applies, so a dry run sees the extract
# a real one would.
#
# All of it is behind the `> 0` gate, because the register read is the whole
# cost of this requirement and `void_retire_after_days` of `0` disables the
# requirement: an installation that has switched retirement off must not go
# on paying for the evidence retirement would have needed.
if (( void_retire_after_days > 0 )); then
  void_register_status_json='{}'
  while IFS=$'\t' read -r vrs_slug vrs_ids; do
    [[ -n "$vrs_slug" && -n "$vrs_ids" ]] || continue
    vrs_branch="$(jq -r --arg s "$vrs_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
      <<<"$ordered_repos_json" 2>/dev/null || true)"
    [[ -n "$vrs_branch" ]] || continue
    # shellcheck disable=SC2086  # $vrs_ids is a deliberate word-split id list.
    vrs_map="$(gather_register_status "$vrs_slug" "$vrs_branch" void $vrs_ids)"
    void_register_status_json="$(jq -c --arg s "$vrs_slug" --argjson m "$vrs_map" '. + {($s): $m}' \
      <<<"$void_register_status_json" 2>/dev/null || printf '%s' "$void_register_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
           <<<"$void_register_ids_json" 2>/dev/null || true)

  # The project-review and implementation-plan residue (TD-PPagop-26081303):
  # requirement 34i's own on-demand readers, over the void set's still-
  # unretired ids of those two shapes — same cost shape as the register read
  # above, `purpose void` so the diagnostic files don't collide with 34i's own
  # blocked-set read of the same repo.
  void_review_status_json='{}'
  while IFS=$'\t' read -r vrv_slug vrv_refs; do
    [[ -n "$vrv_slug" && -n "$vrv_refs" ]] || continue
    vrv_branch="$(jq -r --arg s "$vrv_slug" 'map(select(.slug == $s)) | .[0].default_branch // ""' \
      <<<"$ordered_repos_json" 2>/dev/null || true)"
    [[ -n "$vrv_branch" ]] || continue
    # shellcheck disable=SC2086  # $vrv_refs is a deliberate word-split ref list.
    vrv_map="$(gather_review_status "$vrv_slug" "$vrv_branch" void $vrv_refs)"
    void_review_status_json="$(jq -c --arg s "$vrv_slug" --argjson m "$vrv_map" '. + {($s): $m}' \
      <<<"$void_review_status_json" 2>/dev/null || printf '%s' "$void_review_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
           <<<"$(work_gone_review_refs "$void_json")" 2>/dev/null || true)

  void_plan_status_json='{}'
  while IFS=$'\t' read -r vrp_slug vrp_ids; do
    [[ -n "$vrp_slug" && -n "$vrp_ids" ]] || continue
    vrp_entry="$(jq -c --arg s "$vrp_slug" 'map(select(.slug == $s)) | .[0] // {}' \
      <<<"$ordered_repos_json" 2>&1)" || { guard_warn "void:vrp_entry" "$vrp_entry"; vrp_entry='{}'; }
    vrp_branch="$(jq -r '.default_branch // ""' <<<"$vrp_entry" 2>/dev/null || true)"
    vrp_path="$(jq -r '.implementation_plan_path // ""' <<<"$vrp_entry" 2>/dev/null || true)"
    [[ -n "$vrp_branch" && -n "$vrp_path" ]] || continue
    # shellcheck disable=SC2086  # $vrp_ids is a deliberate word-split id list.
    vrp_map="$(gather_plan_status "$vrp_slug" "$vrp_branch" "$vrp_path" void $vrp_ids)"
    void_plan_status_json="$(jq -c --arg s "$vrp_slug" --argjson m "$vrp_map" '. + {($s): $m}' \
      <<<"$void_plan_status_json" 2>/dev/null || printf '%s' "$void_plan_status_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r 'to_entries[] | .key + "\t" + (.value | join(" "))' \
           <<<"$(work_gone_plan_ids "$void_json")" 2>/dev/null || true)

  # The six liveness shapes (TD-PPagop-26081303, extended by TD-PPagop-26081409
  # for `dequeued` and by agent-ops#646 for `human-visibility`): per repo,
  # whatever gather_findings/gather_register_hygiene/gather_merge_conflicts/
  # gather_dequeued/gather_human_visibility_hygiene
  # already wrote to the cycle dir during the repo loop — the `.ok` marker
  # (this cycle's own read of that source succeeded) and the ids it currently
  # yields — read straight off those tee files, so alert/register-hygiene/
  # merge-conflict/dequeued/human-visibility liveness costs no further `gh`
  # call at all.
  # `failed-run` is the one exception: gather-source-state.sh's own `workflows`
  # digest names
  # each still-failing workflow by id, not by the basename the item id is
  # minted from, so the id -> basename map is fetched here, bounded to the
  # repos that actually carry unretired `failed-run-` void residue (usually
  # none).
  void_failed_run_repos_json="$(jq -r --arg re "$VOID_LIVENESS_FAILED_RUN_RE" '
    [ .[] | select((.repo // "") != "" and ((.item // "") | test($re))) | .repo ] | unique' \
    <<<"$void_json" 2>&1)" \
    || { guard_warn "void_failed_run_repos_json" "$void_failed_run_repos_json"; void_failed_run_repos_json='[]'; }

  void_liveness_gather_json='{}'
  while IFS= read -r vl_slug; do
    [[ -n "$vl_slug" ]] || continue
    vl_safe="${vl_slug//\//_}"

    vl_alert_ok=false; vl_alert_ids='[]'
    if [[ -f "$cycle_dir/findings-$vl_safe.ok" ]]; then
      vl_alert_ok=true
      vl_alert_ids="$(jq -c '[.[].ref]' "$cycle_dir/findings-$vl_safe.json" 2>&1)" \
        || { guard_warn "void-liveness:vl_alert_ids:$vl_safe" "$vl_alert_ids"; vl_alert_ids='[]'; }
    fi

    # The `prefetch` pass's own files, never requirement 34l's `void` pass:
    # that second pass folds the void evidence in (so its array answers a
    # different question) and can fail where the first succeeded, which is
    # why the two carry separate `purpose` prefixes at all.
    vl_rh_ok=false; vl_rh_ids='[]'
    if [[ -f "$cycle_dir/register-hygiene-prefetch-$vl_safe.ok" ]]; then
      vl_rh_ok=true
      vl_rh_ids="$(jq -c '[.[].ref]' "$cycle_dir/register-hygiene-prefetch-$vl_safe.json" 2>&1)" \
        || { guard_warn "void-liveness:vl_rh_ids:$vl_safe" "$vl_rh_ids"; vl_rh_ids='[]'; }
    fi

    vl_mc_ok=false; vl_mc_ids='[]'
    if [[ -f "$cycle_dir/merge-conflicts-$vl_safe.ok" ]]; then
      vl_mc_ok=true
      vl_mc_ids="$(jq -c '[.[].ref]' "$cycle_dir/merge-conflicts-$vl_safe.json" 2>&1)" \
        || { guard_warn "void-liveness:vl_mc_ids:$vl_safe" "$vl_mc_ids"; vl_mc_ids='[]'; }
    fi

    vl_dq_ok=false; vl_dq_ids='[]'
    if [[ -f "$cycle_dir/dequeued-$vl_safe.ok" ]]; then
      vl_dq_ok=true
      vl_dq_ids="$(jq -c '[.[].ref]' "$cycle_dir/dequeued-$vl_safe.json" 2>/dev/null || echo '[]')"
    fi

    # The human-visibility gather's own tee (agent-ops#646). Its array is the
    # candidate objects, so the ids come from `.ref` exactly as the four
    # shapes above take theirs; the walk that writes it is widened, further
    # up, to cover a repo carrying this shape's void residue but no live
    # violation, which is the case that otherwise never produces a marker.
    vl_hv_ok=false; vl_hv_ids='[]'
    if [[ -f "$cycle_dir/human-visibility-hygiene-$vl_safe.ok" ]]; then
      vl_hv_ok=true
      vl_hv_ids="$(jq -c '[.[].ref]' "$cycle_dir/human-visibility-hygiene-$vl_safe.json" 2>&1)" \
        || { guard_warn "void-liveness:vl_hv_ids:$vl_safe" "$vl_hv_ids"; vl_hv_ids='[]'; }
    fi

    vl_fr_ok=false; vl_fr_ids='[]'
    if jq -e --arg r "$vl_slug" 'index($r) != null' <<<"$void_failed_run_repos_json" >/dev/null 2>&1; then
      vl_basenames_json="$(gather_workflow_basenames "$vl_slug")"
      if [[ "$(jq -r '.ok // false' <<<"$vl_basenames_json" 2>/dev/null)" == "true" ]]; then
        vl_state_json="$(jq -c --arg s "$vl_slug" \
          '[.[] | select((.slug // "") == $s and .ok == true)] | first // {}' \
          <<<"$source_states_json" 2>&1)" \
          || { guard_warn "void-liveness:vl_state_json" "$vl_state_json"; vl_state_json='{}'; }
        if [[ "$(jq -r 'has("slug")' <<<"$vl_state_json" 2>/dev/null)" == "true" ]]; then
          vl_fr_ok=true
          vl_fr_ids="$(jq -c --argjson bn "$vl_basenames_json" '
            [ (.workflows // [])[] | select(.c == "failure") | (.w | tostring) as $id
              | ($bn.basenames[$id] // null) | select(. != null) | ("failed-run-" + .) ]' \
            <<<"$vl_state_json" 2>&1)" \
            || { guard_warn "void-liveness:vl_fr_ids" "$vl_fr_ids"; vl_fr_ids='[]'; }
        fi
      fi
    fi

    void_liveness_gather_json="$(jq -c --arg s "$vl_slug" \
      --argjson alert_ok "$vl_alert_ok" --argjson alert_ids "$vl_alert_ids" \
      --argjson rh_ok "$vl_rh_ok" --argjson rh_ids "$vl_rh_ids" \
      --argjson mc_ok "$vl_mc_ok" --argjson mc_ids "$vl_mc_ids" \
      --argjson dq_ok "$vl_dq_ok" --argjson dq_ids "$vl_dq_ids" \
      --argjson hv_ok "$vl_hv_ok" --argjson hv_ids "$vl_hv_ids" \
      --argjson fr_ok "$vl_fr_ok" --argjson fr_ids "$vl_fr_ids" \
      '. + {($s): {alert: {ok: $alert_ok, ids: $alert_ids},
                   "register-hygiene": {ok: $rh_ok, ids: $rh_ids},
                   "merge-conflict": {ok: $mc_ok, ids: $mc_ids},
                   "dequeued": {ok: $dq_ok, ids: $dq_ids},
                   "human-visibility": {ok: $hv_ok, ids: $hv_ids},
                   "failed-run": {ok: $fr_ok, ids: $fr_ids}}}' \
      <<<"$void_liveness_gather_json" 2>/dev/null || printf '%s' "$void_liveness_gather_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r '.[].slug' <<<"$ordered_repos_json" 2>/dev/null || true)

  # The closed set grows with every void ever actioned, so it arrives on
  # stdin, never in argv (requirement 4g), and is intersected with the
  # extract's own pairs before it travels any further: retirement can only
  # drop what is in the extract, so the intersection loses nothing and is
  # what keeps `void_actioned_json` — which does ride an --argjson below —
  # bounded by the unretired residue rather than by history. `by` names the
  # actioned signal, for the `void-retired` event to carry. The liveness,
  # review/plan and config pairs are already bounded the same way — each is
  # computed straight from `void_json`'s own residue, never from history, and
  # each entry is three short fields whatever the entry it was derived from.
  # shellcheck disable=SC2016  # jq's $void/$closed/$reg et al., not the shell's.
  void_actioned_json="$(jq -c -n --argjson reg "$void_register_status_json" \
    --argjson liveness "$(void_liveness_actioned "$void_json" "$void_liveness_gather_json")" \
    --argjson revplan "$(void_review_plan_actioned "$void_json" "$void_review_status_json" "$void_plan_status_json")" \
    --argjson config "$(void_config_actioned "$void_json" "$all_repos_json")" '
    input as $void | input as $closed
    | ($void | map((.repo // "") + "|" + (.item // ""))) as $pairs
    | ($closed
       | map(select((.repo + "|" + .item) as $k | ($pairs | index($k)) != null)
             | {repo, item, by: "object-closed"})) as $closed_here
    | ($reg | to_entries | map(.key as $repo | .value | to_entries[]
       | select((.value | ascii_downcase) == "resolved" or (.value | ascii_downcase) == "not-debt")
       | {repo: $repo, item: .key, by: "register-resolved"})) as $reg_done
    | $closed_here + $reg_done + $liveness + $revplan + $config' \
    <<<"$void_json"$'\n'"$(void_object_closed_items "$union_log")" 2>&1)" \
    || { guard_warn "void_actioned_json:closed-merge" "$void_actioned_json"; void_actioned_json='[]'; }

  void_json_before_retire="$void_json"
  void_json="$(retire_void_items "$void_json" "$void_actioned_json" "$void_retire_after_days" "$now_epoch")"

  if ! (( DRY_RUN )); then
    # Both extracts on stdin (requirement 4g); a retire_void_items failure
    # returns its input verbatim, so before == after and nothing is recorded.
    # shellcheck disable=SC2016  # jq's $before/$after/$actioned et al.
    void_retired_now_json="$(jq -c -n --argjson actioned "$void_actioned_json" '
      input as $before | input as $after
      | ($after | map((.repo // "") + "|" + (.item // ""))) as $kept
      | [ $before[]
          | ((.repo // "") + "|" + (.item // "")) as $k
          | select(($kept | index($k)) == null)
          | {repo, item, void_ts: .ts,
             by: (($actioned | map(select(((.repo // "") + "|" + (.item // "")) == $k))
                   | first | .by) // "actioned")} ]' \
      <<<"$void_json_before_retire"$'\n'"$void_json" 2>&1)" \
      || { guard_warn "void_retired_now_json" "$void_retired_now_json"; void_retired_now_json='[]'; }
    while IFS= read -r void_retired_entry; do
      [[ -n "$void_retired_entry" ]] || continue
      log_event "void-retired" "$void_retired_entry"
    done < <(jq -c '.[]' <<<"$void_retired_now_json" 2>/dev/null || true)
  fi
fi

# Defence in depth alongside requirement 4g's stdin-only delivery (which is
# what actually stops this reaching `MAX_ARG_STRLEN` again — retirement bounds
# the steady state, not any one cycle's worst case): a `warning`, well under
# the 131072-byte cap, if the extract stays large enough after retirement to
# be worth a human's attention.
void_json_bytes="$(printf '%s' "$void_json" | wc -c)"
if (( void_json_bytes > 100000 )); then
  log_event "warning" "$(jq -nc \
    --argjson n "$(v="$(jq 'length' <<<"$void_json" 2>&1)" || { guard_warn "void_json_bytes:n" "$v"; v=0; }; printf '%s' "$v")" --argjson b "$void_json_bytes" \
    '{detail: ("void extract is " + ($b | tostring) + " bytes across " + ($n | tostring)
               + " entries after retirement — approaching the 131072-byte MAX_ARG_STRLEN cap; check void_retire_after_days and whether requirements 34k/34l are actioning items")}')"
fi

# --- 3c/3u. Pre-fetched-band eligibility, decided (requirement 3t, issue ---
# --- #310; extended to every other pre-fetched band by requirement 3u, ---
# --- issue #320) ---
# Deferred from step 3 for the same reason 2.2a's back-pressure decision and
# 3b's no-op fingerprint are deferred from their own numbers: the repo loop
# (section 3) attached each repo's pre-fetched bands, claim-filtered, before
# `blocked_json`/`void_json` existed to filter them further. Now that both
# are final — void_json has had every reconciliation pass and its own
# retirement applied — finish the job for every band the Script hands the
# Co-Ordinator whole: drop any entry this repo's own blocked or void record
# names, exactly as exclude_claimed_items already dropped claimed ones.
# `findings`, `review_feedback`, `abandoned_drafts`, `merge_conflicts`,
# `dequeued`, `register_hygiene`, `human_visibility` and `tech_debt` all get the identical
# second pass `exclude_blocked_or_void_items` first gave `tech_debt` alone
# (issue #310) — there is nothing about that exclusion tech-debt-specific,
# only tech-debt was the band it was first proven on. Every band the repo
# entry carries is in this list but `issues`; a band added to that entry and
# not to this list would keep handing the Co-Ordinator blocked and void
# candidates it has no list left to check them against, which is why
# `test/cycle-state.test.sh` pins the list itself.
#
# `issues` gets its own, narrower pass
# below instead, via `exclude_blocked_or_void_issues`: unlike every other
# band, a blocked issue can carry fresh evidence requirement 18a obliges the
# Co-Ordinator to re-read live, so dropping it here — before that re-read can
# ever happen — would silently retire the mandatory re-check rather than
# apply it (see that function's own comment).
#
# What remains in each band after this block is the Script's own answer to
# "what could the Co-Ordinator actually select from this band" — open,
# unclaimed, unblocked (or, for `issues`, blocked-but-due-a-re-read), not
# void — with no per-item judgement left for it to apply, and no room for a
# verdict like "requires per-item evaluation against blocked/void/claimed
# records" to be true of any of them.
for eligibility_band in findings review_feedback abandoned_drafts merge_conflicts dequeued register_hygiene human_visibility tech_debt; do
  while IFS= read -r eb_slug; do
    [[ -n "$eb_slug" ]] || continue
    eb_current="$(jq -c --arg s "$eb_slug" --arg f "$eligibility_band" \
      'map(select(.slug == $s)) | .[0][$f] // []' <<<"$ordered_repos_json" 2>&1)" \
      || { guard_warn "eb_current:$eb_slug:$eligibility_band" "$eb_current"; eb_current='[]'; }
    eb_filtered="$(exclude_blocked_or_void_items "$eb_current" "$eb_slug" "$blocked_json" "$void_json")"
    ordered_repos_json="$(jq -c --arg r "$eb_slug" --arg f "$eligibility_band" --argjson v "$eb_filtered" \
      'map(if .slug == $r then .[$f] = $v else . end)' \
      <<<"$ordered_repos_json" 2>/dev/null || printf '%s' "$ordered_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
  done < <(jq -r --arg f "$eligibility_band" \
           '[.[] | select(((.[$f] // []) | length) > 0) | .slug] | unique[]' \
           <<<"$ordered_repos_json" 2>/dev/null || true)
done

while IFS= read -r iss_slug; do
  [[ -n "$iss_slug" ]] || continue
  iss_current="$(jq -c --arg s "$iss_slug" 'map(select(.slug == $s)) | .[0].issues // []' \
    <<<"$ordered_repos_json" 2>&1)" \
    || { guard_warn "iss_current:$iss_slug" "$iss_current"; iss_current='[]'; }
  iss_filtered="$(exclude_blocked_or_void_issues "$iss_current" "$iss_slug" "$blocked_json" "$void_json")"
  ordered_repos_json="$(jq -c --arg r "$iss_slug" --argjson iss "$iss_filtered" \
    'map(if .slug == $r then .issues = $iss else . end)' \
    <<<"$ordered_repos_json" 2>/dev/null || printf '%s' "$ordered_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
done < <(jq -r '[.[] | select(((.issues // []) | length) > 0) | .slug] | unique[]' \
         <<<"$ordered_repos_json" 2>/dev/null || true)

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

# Issue #238's third acceptance: a blocked `merge-conflicts`/`dequeued`/
# `abandoned-drafts` item's ref is scoped to the head SHA it was detected at
# (requirements 3e, 3g, 3z) precisely so a later push mints a fresh ref that
# no old block covers — but the old ref itself is never cleared, only
# superseded, so without this filter it would sit `enabler_eligible` forever,
# costing a full engagement every time its recheck clock came round only to be
# voided as stale (as happened to `pr-205-conflict-305ca060016d`, claimed and
# voided three minutes later). This cycle's own fresh
# `merge_conflicts`/`dequeued`/`abandoned_drafts` arrays — already gathered
# into `ordered_repos_json` above — are the current truth for every PR still
# in any of those states; a SHA-scoped ref absent from them has been
# superseded (a newer push), resolved, or requeued, either way stale. Only refs
# shaped `pr-<n>-conflict-<sha>`/`pr-<n>-superseded-<sha>`/
# `pr-<n>-dequeued-<sha>`/`pr-<n>-abandoned-<sha>` are tested — the
# merge-conflicts gather mints the first two (requirement 3g), both scoped to
# the same head SHA, so both go stale the same way, and a refused supersession
# void is recorded blocked under the second (requirement 32a) exactly as a
# refused conflict void is under the first. `pr-<n>-dequeued-<sha>` (the
# gather-dequeued.sh gather, requirement 3z) goes stale the identical way: a
# fresh push (a fix, or anyone else's) or a re-queue mints no *new* ref this
# script would test — it simply stops appearing in `dequeued`, which is what
# "absent from the live set" already means. Every other blocked item kind (a
# tech-debt id, an issue number, a review-feedback round) has no such
# re-detectable "current" state to compare against, and
# `test` on a plain id or number simply never matches the pattern. A jq
# failure leaves the set unfiltered: this is a cost saving, never the
# correctness gate (the Enabler still voids a stale item it does reach).
live_pr_refs_json="$(jq -c \
  '[.[] | .slug as $s | ((.merge_conflicts // []) + (.dequeued // []) + (.abandoned_drafts // []))[] | ($s + "#" + .ref)]' \
  <<<"$ordered_repos_json" 2>/dev/null || true)"
# An *empty* live set and a *failed* derivation of one are opposite facts, and
# only the guard below keeps them apart. Empty-on-success is meaningful — no PR
# is in either state this cycle, so every SHA-scoped ref really is superseded or
# resolved — but a jq failure knows nothing about any PR, and feeding its result
# in as an empty set would mark every eligible conflict/abandoned ref stale and
# drop the lot: maximal filtering, the exact opposite of the unfiltered
# degradation the comment above and requirement 35e both promise. Failure alone
# yields the empty *string* (jq prints nothing to stdout on error, and prints
# `[]` at minimum on success), so testing for it skips the filter outright.
#
# `as $repo`/`as $item` before piping into `$live`: `|` rebinds `.` to its
# right-hand side for everything downstream, `$live` included, so reading
# `.repo`/`.item` *after* `$live |` would read them off the live-refs array
# instead of off the eligible entry — jq has no other way to hold onto the
# outer `.` across a nested pipe.
stale_enabler_refs_json='[]'
[[ -z "$live_pr_refs_json" ]] || { stale_enabler_refs_json="$(jq -c --argjson live "$live_pr_refs_json" '
  [ .[] | (.repo // "") as $repo | (.item // "") as $item
        | select(($item | test("^pr-[0-9]+-(conflict|superseded|dequeued|abandoned)-[0-9a-f]+$"))
                 and (($live | index($repo + "#" + $item)) == null)) ]
  ' <<<"$enabler_eligible_json" 2>&1)" \
  || { guard_warn "stale_enabler_refs_json" "$stale_enabler_refs_json"; stale_enabler_refs_json='[]'; }; }
stale_enabler_refs_n="$(jq 'length' <<<"$stale_enabler_refs_json" 2>&1)" \
  || { guard_warn "stale_enabler_refs_n" "$stale_enabler_refs_n"; stale_enabler_refs_n=0; }
if [[ "$stale_enabler_refs_n" != "0" ]]; then
  # An *object* payload ({skipped: [...]}), never the bare array: log_event's
  # envelope merge can only add objects, and the bare-array form of this exact
  # line is what crash-looped the fleet on 2026-08-13 (issue #361).
  log_event "enabler-stale-refs-skipped" "$(jq -c '{skipped: [.[] | {repo, item}]}' <<<"$stale_enabler_refs_json")"
  enabler_eligible_json="$(jq -c --argjson stale "$stale_enabler_refs_json" '
    ($stale | map((.repo // "") + "#" + (.item // ""))) as $staleset
    | [ .[] | (.repo // "") as $repo | (.item // "") as $item
            | select(($staleset | index($repo + "#" + $item)) == null) ]
    ' <<<"$enabler_eligible_json" 2>/dev/null || printf '%s' "$enabler_eligible_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
fi

# Past this line the exit trap may engage the Enabler: every input it needs now
# exists, so `maybe_run_enabler`'s own guards are all that stand between this
# cycle and an engagement. Before it, an early exit could not have one.
enabler_allowed=1

# --- Refiner-only pre-fetch: project-review and implementation-plan
# (requirement 3y; TD-PPagop-26081307) ---
# `ordered_repos_json` — the Co-Ordinator's own input — never gains these two
# arrays: the Co-Ordinator keeps reading `reviews/…` and the plan document
# live (prompts/coordinator.md's "Project-review recommendations" and
# "implementation-plan" bullets). `refiner_repos_json` is a separate copy,
# augmented per repo only where the read is worth paying for: this installation
# has a Refiner at all (`refiner_model` — `maybe_run_refiner`'s own first guard,
# so with it empty every read here buys an array no engagement can ever spend),
# the repo's own `sources` lists the source *and* `refinement_policy` for it is
# not exempt (nothing would ever read an exempt source's candidates), and for
# `implementation-plan`, only where `implementation_plan_path` is configured
# (the same startup guard that requires it already refused to run otherwise).
refiner_repos_json="$ordered_repos_json"
if [[ -n "$refiner_model" ]]; then
  while IFS=$'\t' read -r rp_slug rp_branch; do
    [[ -n "$rp_slug" ]] || continue
    rp_entry="$(jq -c --arg s "$rp_slug" 'map(select(.slug == $s)) | .[0] // {}' \
      <<<"$ordered_repos_json" 2>&1)" || { guard_warn "refiner:rp_entry" "$rp_entry"; rp_entry='{}'; }
    rp_sources="$(jq -c '.sources // []' <<<"$rp_entry" 2>&1)" \
      || { guard_warn "refiner:rp_sources" "$rp_sources"; rp_sources='[]'; }
    rp_pr='[]'
    if jq -e 'any(.[]; . == "project-review")' <<<"$rp_sources" >/dev/null 2>&1 \
       && [[ "$(refiner_policy_value "project-review" "$refinement_policy_json")" != "exempt" ]]; then
      rp_pr="$(gather_project_review_candidates "$rp_slug" "$rp_branch")"
    fi
    rp_ip='[]'
    rp_path="$(jq -r '.implementation_plan_path // ""' <<<"$rp_entry" 2>/dev/null || true)"
    if jq -e 'any(.[]; . == "implementation-plan")' <<<"$rp_sources" >/dev/null 2>&1 \
       && [[ -n "$rp_path" ]] \
       && [[ "$(refiner_policy_value "implementation-plan" "$refinement_policy_json")" != "exempt" ]]; then
      rp_ip="$(gather_implementation_plan_candidates "$rp_slug" "$rp_branch" "$rp_path")"
    fi
    if [[ "$rp_pr" != "[]" || "$rp_ip" != "[]" ]]; then
      refiner_repos_json="$(jq -c --arg s "$rp_slug" --argjson pr "$rp_pr" --argjson ip "$rp_ip" \
        'map(if .slug == $s then . + {project_review: $pr, implementation_plan: $ip} else . end)' \
        <<<"$refiner_repos_json" 2>/dev/null || printf '%s' "$refiner_repos_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unchanged prior aggregate, not a fabricated empty
    fi
  done < <(jq -r '.[] | .slug + "\t" + .default_branch' <<<"$ordered_repos_json" 2>/dev/null || true)
fi

# --- The Refiner's candidate set (requirement 39a) ---
# Every pre-fetched item this cycle's `refiner_repos_json` carries whose source
# is not `refinement_policy`-exempt, is not already refined, blocked, void, or
# claimed. Computed from the same extracts the Enabler's eligible set just
# used, so a Refiner engagement and an Enabler engagement in the same cycle
# never disagree about what is already spoken for. `refiner_repos_json`
# rather than `ordered_repos_json` only because it carries the two arrays
# above the Co-Ordinator's own input never gains — every other field is the
# same, so nothing else about the candidate rule below needs to know a
# separate array exists.
refiner_candidates_json="$(refiner_candidate_items "$refiner_repos_json" \
  "$refinement_policy_json" "$refinements_json" "$blocked_json" "$void_json" "$claimed_json")"
# issue #511, extended by issue #542: drop this cycle's `triage_only`
# candidates from any repository whose `Priority` field this token cannot
# resolve at all, or which resolves carrying none of the four band names,
# before the engagement cap or any claim — a pre-flight, not a post-hoc
# latch, so field visibility, or a renamed option set, recovering needs no
# operator action. Run unconditionally whenever this installation has a
# Refiner (`refiner_model` set), including under --dry-run, so the
# fingerprint input below never differs between a dry-run and a live cycle
# for no reason. Skipped outright when `refiner_model` is empty — with no
# Refiner to spend an engagement on a triage-only candidate either way, the
# GraphQL read this performs, and any `refiner:` warning it can log, would
# cost every cycle for a stage that never runs (issue #567).
if [[ -n "$refiner_model" ]]; then
  refiner_candidates_json="$(refiner_filter_unbandable_triage "$refiner_candidates_json")"
fi
# Same reasoning as `enabler_allowed` above, for the same kind of exit-trap
# engagement.
refiner_allowed=1

# --- 2.2a Back-pressure, decided (requirement 2.2a) ---
# Deferred from step 2.2 until the sources were gathered. Back-pressure's stated
# purpose is to throttle new work and stop the human gate silting up — and the
# four *finishing* sources do neither: `review-feedback` answers a review the
# human has already written, `merge-conflicts` rebases a ready PR the human is
# waiting to merge, `dequeued` fixes the merge-group checks failure that got a
# ready PR of ours removed from the human's own queue, and `abandoned-drafts`
# carries a stalled draft this system started to completion. All are the
# activity that *un*-silts the gate — indeed an abandoned draft is itself
# occupying one of the very back-pressure slots the cap is counting, and a
# conflicted or dequeued PR is one the human cannot merge to free a slot until
# it is fixed. So when back-pressure trips we do not stand down if
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
# "a conflicted or dequeued PR is one the human cannot merge to free a slot
# until it is fixed" above claims those two already hold a slot requirement
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
  coordinator_fit_overhead_json="$(jq -nc \
    --argjson blocked "$(coordinator_blocked_view "$blocked_json")" \
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
  coordinator_fit_overhead_bytes=$((
    $(printf '%s' "$coordinator_base_prompt" | wc -c)
    + $(printf '%s' "$coordinator_fit_overhead_json" | coordinator_rendered_bytes)
    + coordinator_fit_scaffold_bytes ))
  coordinator_fit_allowance=$(( coordinator_prompt_max_bytes - coordinator_fit_overhead_bytes ))
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
    '{detail: $d}')"
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
        --argjson f "$coordinator_fit_report_json" '{detail: $d} + $f')"
      # Not fitting is the other thing entirely: the identity fields alone have
      # outgrown the allowance, the ladder has nothing left to shed, and the
      # API will refuse the prompt this cycle is about to send. Say so *before*
      # it does, so the union log carries the cause rather than an exit code —
      # the exact gap agent-ops#641 was filed into.
      if ! jq -e '.fits' <<<"$coordinator_fit_report_json" >/dev/null 2>&1; then
        log_event "warning" "$(jq -nc --arg d "$coordinator_fit_detail_text" '{detail: $d}')"
      fi
    fi
  fi
fi
# --- end of requirement 4i's fit ---

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
for (( ci = 0; ci < n_cand; ci++ )); do
  cand="$(jq -c --argjson i "$ci" '.[$i]' <<<"$candidates_json")"
  c_repo="$(jq -r '.repo // ""' <<<"$cand")"
  c_item="$(jq -r '.item // ""' <<<"$cand")"
  c_source="$(jq -r '.source // ""' <<<"$cand")"
  c_db="$(jq -r '.default_branch // "main"' <<<"$cand")"
  c_takeover="$(jq -r '.takeover // false' <<<"$cand")"
  [[ -n "$c_repo" && -n "$c_item" ]] || continue
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
  # a productive chain pays. The other two causes never chain: against an
  # `unreachable` GitHub a fresh cycle buys a second Co-Ordinator engagement
  # and the same empty-handed ending, and after a `pre-claimed` stand-down —
  # a selection defect, not contention — an identical re-run is more likely
  # to repeat the defect than to route around it.
  if [[ "$standdown_cause" == "raced" ]] \
      && ! (( ONCE )) \
      && chain_should_continue "$chain_count" "$max_chained_cycles" "$ordered_repos_json"; then
    chain_eligible=1
  fi
  log_event "stand-down" "$(jq -nc --argjson n "$n_cand" --arg r "$standdown_reason" --arg c "$standdown_cause" \
    --argjson rl "$race_losses" --argjson sk "$claim_skips" \
    '{reason: $r, candidates: $n, cause: $c, race_losses: $rl}
     + (if $sk > 0 then {claim_skips: $sk} else {} end)')"
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
  if [[ "$human_reviewer_state" == "failed" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg a "$enabler_assignee" --arg w "$human_reviewer_who" \
      --arg d "$impl_pr_url is ready with nothing blocking it, but review could not be requested from ${human_reviewer_who:-$enabler_assignee} — it will not appear in their review queue" \
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
