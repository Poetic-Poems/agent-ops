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
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/merge-autonomy.sh
. "$SCRIPT_DIR/lib/merge-autonomy.sh"
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
# shellcheck source=lib/review-gate.sh
. "$SCRIPT_DIR/lib/review-gate.sh"
# shellcheck source=lib/closing-keyword-gate.sh
. "$SCRIPT_DIR/lib/closing-keyword-gate.sh"
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
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"
# shellcheck source=lib/prompt-overrides.sh
. "$SCRIPT_DIR/lib/prompt-overrides.sh"
# shellcheck source=lib/coordinator-brief.sh
. "$SCRIPT_DIR/lib/coordinator-brief.sh"
# shellcheck source=lib/repo-order.sh
. "$SCRIPT_DIR/lib/repo-order.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/chain.sh
. "$SCRIPT_DIR/lib/chain.sh"

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
implementor_model_default="$(resolve_model_id implementor_model_default "$(cfg '.implementor_model_default')")"
implementor_model_trivial="$(resolve_model_id implementor_model_trivial "$(cfg '.implementor_model_trivial')")"
reviewer_model_default="$(resolve_model_id reviewer_model_default "$(cfg '.reviewer_model_default')")"
# The complexity escalation (requirement 8a): a PR graded `complexity:high` is
# reviewed on this tier. Empty falls back to the default tier, which switches
# the escalation off.
reviewer_model_complex="$(cfg '.reviewer_model_complex')"
[[ -n "$reviewer_model_complex" ]] || reviewer_model_complex="$reviewer_model_default"
reviewer_model_complex="$(resolve_model_id reviewer_model_complex "$reviewer_model_complex")"
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
# ours to push to if its head branch is under this prefix. The Human Gate says
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
         '($p[$a] // $p.implementor).backstop')"
  [[ "$stage_inactivity_min" =~ ^[0-9]+$ ]] \
    || stage_inactivity_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" --arg a "$actor" \
         '($p[$a] // $p.implementor).inactivity')"
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
    fields="$(jq -c '{fields: .}' <<<"$fields" 2>/dev/null \
      || jq -nc --arg f "$fields" '{fields: $f}')"
  fi
  jq -nc --arg ts "$ts" --arg cycle "$cycle_id" --arg node "$node_name" --arg event "$event" --argjson fields "$fields" \
    '{ts: $ts, cycle: $cycle, node: $node, event: $event} + $fields' >> "$log_file" || true
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
    printf 'merge_autonomy: KILLED — %s\n' "$(toggle_describe "$(jq -c '.record' <<<"$ma_state")")"
    printf '          every repo'"'"'s effective level is human regardless of merge_autonomy; --restore-merge-autonomy clears it\n'
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

# release_claim have-pr|no-pr|have-pr-pending
#
# Releases the item-keyed claim (branch or file) per the have-pr/no-pr rule
# above, then — unless told to hold off — releases the PR-keyed claim too.
# "have-pr-pending" is the one caller (pr-raised, below) that must not: the
# open PR now stands in for the item-keyed claim, but the PR-keyed exclusion
# claim (issue #238) exists to keep a *peer* off this same PR, and the
# Reviewer stage that runs next still writes to it. Dropping the PR-keyed
# claim here reopened exactly the race issue #238 closed — poetic-2's
# Reviewer was still pushing to PR #353 forty-three minutes after this call
# released it, while ockham-2 claimed and force-pushed a rebase of the same
# PR under a fresh review-feedback ref (issue #360). Every other caller
# already runs at this cycle's true end (a stage failure, a reviewer
# handback, a signal, or the terminal "ready"/void/blocked paths below), so
# it is safe — and necessary — for them to drop both.
release_claim() {  # release_claim have-pr|no-pr|have-pr-pending
  if (( claim_active )); then
    if [[ "$1" == "have-pr" || "$1" == "have-pr-pending" ]]; then
      timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release file "$selected_repo" "$claim_key" \
        >>"$cycle_dir/claim.log" 2>&1 || true
    else
      timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release "$claim_kind" "$selected_repo" "$claim_key" \
        >>"$cycle_dir/claim.log" 2>&1 || true
    fi
    claim_active=0
  fi
  [[ "$1" == "have-pr-pending" ]] && return 0
  release_pr_claim
}

# The PR-keyed claim's own release, split out so it can be deferred past the
# item-keyed claim's (issue #360) and still be reachable — idempotently, on
# whichever path this cycle actually ends on — from every one of them.
# Independent of claim_active by design (see above): a caller that already
# released the item-keyed claim via "have-pr-pending" has claim_active=0 by
# the time this runs, and must not skip the PR-keyed release on that account.
# `cleanup` (the EXIT trap) calls it too, as the backstop for the one ending
# no handler reaches — an unhandled errexit abort after `pr-raised` — which
# is why the empty-key guard below must stay the first line: on every handled
# path the trap's call finds claim_pr_key already cleared and does nothing.
release_pr_claim() {
  [[ -n "$claim_pr_key" ]] || return 0
  timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release file "$selected_repo" "$claim_pr_key" \
    >>"$cycle_dir/claim.log" 2>&1 || true
  claim_pr_key=""
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
# since the four finishing sources have no branch — and `lib/claim.sh
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
#
# `pr_number` (issue #238) rides along wherever the registry knows one — a
# finishing-source claim's item-keyed entry and its PR-keyed sibling both
# record it, so it survives the dedup below regardless of which of the two
# entries `group_by` happens to read it from. Omitted, not `null`, when
# nothing in the group carries one: an ordinary tech-debt or issue claim
# targets no PR at all, and the field's *absence* is what the repo-loop's
# PR-level exclusion (below) and requirement 16's exclusion 3 test for.
gather_claimed() {  # <target-slug> -> JSON array of {item, age_hours, pr_number?}
  local slug="$1" safe registry_out branches_out out
  safe="${slug//\//_}"
  registry_out="$("$SCRIPT_DIR/lib/claim.sh" claims "$slug" 2>"$cycle_dir/claims-$safe.err" || true)"
  jq -e 'type == "array"' <<<"$registry_out" >/dev/null 2>&1 || registry_out='[]'
  branches_out="$("$SCRIPT_DIR/lib/claim.sh" branches "$slug" 2>"$cycle_dir/claim-branches-$safe.err" || true)"
  jq -e 'type == "array"' <<<"$branches_out" >/dev/null 2>&1 || branches_out='[]'
  # TD-PPagop-26081407: $registry_out/$branches_out still ride in as
  # --argjson (unconverted by requirement 4g — the fleet's active claims for
  # one repo, growing with claim volume) and can hit MAX_ARG_STRLEN (test 1);
  # `[]` here reads exactly like "this repo genuinely has no claims" (test 2),
  # which the caller uses to decide whether a candidate is already claimed.
  out="$(jq -c -n --arg tp 'td/' --arg ap "$branch_prefix" --argjson reg "$registry_out" --argjson br "$branches_out" '
    ( [ $reg[] | {item, age_hours, pr_number: (.pr_number // null)} ] ) as $from_registry
    | ( [ $br[]
          | (if startswith($tp) then .[($tp | length):]
             elif ($ap != "" and startswith($ap)) then .[($ap | length):]
             else empty end)
          | select(. != "")
          | {item: ., age_hours: null, pr_number: null} ] ) as $from_branches
    | ($from_registry + $from_branches)
    | group_by(.item)
    | map(
        (.[0].item) as $item
        | (([.[].age_hours | select(. != null)] | first) // null) as $age
        | (([.[].pr_number | select(. != null)] | first) // null) as $pr
        | {item: $item, age_hours: $age} + (if $pr == null then {} else {pr_number: $pr} end)
      )
  ' 2>&1)" || { guard_warn "gather_claimed:$slug" "$out"; out='[]'; }
  printf '%s' "$out"
}

# Requirement 3p/issue #238: drop any of a finishing source's own candidates
# whose `pr_number` is one a peer already holds a claim on — under whatever
# item ref that peer claimed it, which need not be (and after a fresh review
# round or a moved head, usually isn't) this cycle's own ref for the same PR.
# This is what makes the Co-Ordinator's exclusion deterministic code instead of
# a comparison it has to remember to make per candidate: a PR already excluded
# here never reaches its runtime input, so there is nothing left for it to
# reason past. Malformed input degrades to passing the array through
# unfiltered — this is a visibility layer over the atomic PR-level claim taken
# in the selection loop below, never itself the exclusion's hard gate.
#
# Both arrays arrive on stdin, one JSON document per line, bound positionally
# in the order printed (requirement 4g) — never in argv: the claims array
# grows with the fleet's live claim count, and past MAX_ARG_STRLEN an
# `--argjson` delivery would fail into the fail-open fallback below and pass
# every candidate through unfiltered, reopening exactly the claimed-work
# proposals #305 closed.
exclude_claimed_prs() {  # <candidates-json> <claimed-pr-numbers-json>
  local candidates="$1" claimed_prs="${2:-[]}" docs
  jq -e 'type == "array"' <<<"$claimed_prs" >/dev/null 2>&1 || claimed_prs='[]'
  docs="$(printf '%s\n' "$candidates" "$claimed_prs")"
  # TD-PPagop-26081407: the `|| printf` below passes test 2 — it falls back to
  # the pre-filter $candidates, a value the caller already accepted, not a
  # fabricated empty.
  jq -nc '
    input as $candidates | input as $claimed
    | [ $candidates[] | select(((.pr_number // null) as $p | $p == null or ($claimed | index($p)) == null))]' \
    <<<"$docs" 2>/dev/null || printf '%s' "$candidates"
}

# The item-ref sibling of exclude_claimed_prs above, and the same design
# decision extended to every pre-fetched source: drop any candidate whose
# `ref` — the item ref every gather script mints (requirement 3o) and the
# string a claim is keyed on — is one the fleet already holds. Exclusion 3 in
# prompts/coordinator.md asks the model to skip claimed items, and on
# 2026-08-09 a Co-Ordinator read four issues as "claimed in the live
# branches", reasoned that claimed items still make good alternates, and
# ranked three of them — every claim lost, the cycle forfeited. An item
# filtered out here never reaches the runtime input, so there is nothing
# left to reason past. Malformed input degrades to passing the array through
# unfiltered, exactly as exclude_claimed_prs does and for the same reason:
# this is a visibility layer over the atomic claim, never the hard gate.
#
# Both arrays arrive on stdin, one JSON document per line, bound positionally
# in the order printed (requirement 4g) — never in argv, for the same reason
# and on the same fail-open terms as exclude_claimed_prs above.
exclude_claimed_items() {  # <candidates-json> <claimed-item-refs-json>
  local candidates="$1" claimed_items="${2:-[]}" docs
  jq -e 'type == "array"' <<<"$claimed_items" >/dev/null 2>&1 || claimed_items='[]'
  docs="$(printf '%s\n' "$candidates" "$claimed_items")"
  # TD-PPagop-26081407: the `|| printf` below passes test 2 — it falls back to
  # the pre-filter $candidates, a value the caller already accepted, not a
  # fabricated empty.
  jq -nc '
    input as $candidates | input as $claimed
    | [ $candidates[] | select(((.ref // null) as $r | $r == null or ($claimed | index($r)) == null))]' \
    <<<"$docs" 2>/dev/null || printf '%s' "$candidates"
}

# Issue #248 acceptance 4 (TD-PPagop-26081405): log one `first-seen` per item
# the very first time any node's gather ever reports it, so a later report can
# subtract it from the `selection` that eventually claims it. Called on each
# pre-fetched source's RAW candidate array — ahead of exclude_claimed_items and
# the blocked/void pass further down — so an item claimed, blocked or voided
# the same cycle it first appears still gets one (acceptance 3): those
# exclusions only ever narrow what the Co-Ordinator is shown, never what this
# fleet has seen.
#
# $first_seen_known_json (seeded from first_seen_known_items over the union
# log, lib/cycle-state.sh) is the running "already logged" set, updated here so
# a later source's own candidates this same cycle see this call's new items
# too — a `register-hygiene` id first-seen alongside a `tech-debt` one in the
# same cycle must not both fire twice. Like every aggregate requirement 4g
# names, it can grow with the fleet's whole history, so it travels to jq on
# stdin, never as an --argjson; on malformed input it is left exactly as it
# was, which only ever costs a retry next cycle, never a lost or duplicated
# event. $first_seen_bootstrap is one small flag, decided once at the top of
# the cycle, and cheap enough to pass with --argjson like any config-sized
# value.
emit_first_seen() {  # <repo> <source> <candidates-json>
  local repo="$1" source="$2" candidates="$3" docs result new_refs ref
  docs="$(printf '%s\n' "$first_seen_known_json" "$candidates")"
  result="$(jq -nc --arg r "$repo" '
    input as $known | input as $cands
    | ($known | map(select(.repo == $r)) | map(.item)) as $seen
    | ([$cands[].ref // empty | select(. != "")] | unique
       | map(select(. as $ref | ($seen | index($ref)) == null))) as $new
    | {new: $new, known: ($known + ($new | map({repo: $r, item: .})))}
  ' <<<"$docs" 2>/dev/null || echo '{"new":[],"known":null}')"
  new_refs="$(jq -c '.new' <<<"$result" 2>/dev/null || echo '[]')"
  if jq -e '.known != null' <<<"$result" >/dev/null 2>&1; then
    first_seen_known_json="$(jq -c '.known' <<<"$result")"
  fi
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    log_event "first-seen" "$(jq -nc --arg r "$repo" --arg i "$ref" --arg s "$source" --argjson b "$first_seen_bootstrap" \
      '{repo: $r, item: $i, source: $s, basis: "poll", bootstrap: $b}')"
  done < <(jq -r '.[]' <<<"$new_refs" 2>/dev/null || true)
}

# Requirement 3t/issue #310: drop any candidate whose `ref` is recorded
# blocked or void for THIS_REPO in the fleet's shared log — the same
# deterministic-code-not-model-judgement decision exclude_claimed_items above
# makes for claims, applied to the two other exclusions requirement 16's
# exclusion 1 asks the Co-Ordinator to apply by eye. Unlike `issues`
# (requirement 3j), which deliberately leaves blocked items in the array
# because requirement 18a's re-check needs the live thread to decide whether
# fresh evidence unblocks one, a tech-debt item has no such re-check: a block
# whose underlying work has actually landed is already cleared before this
# runs, by requirement 34i's work-gone reconciliation reading the very same
# register this array was drawn from — so nothing here is ever filtered out
# only to need putting back a moment later. Scoped to the repo the block/void
# was recorded against, matching BLOCKED_ITEMS_JQ's own repo-or-blank match:
# a blank `repo` (an old, pre-scoping event) still matches every repo, exactly
# as the Co-Ordinator's own reading of `blocked`/`void` always has. Malformed
# input degrades to passing the array through unfiltered, on the same fail-open
# terms as exclude_claimed_items.
#
# All three arrays arrive on stdin, one JSON document per line, bound
# positionally in the order printed (requirement 4g) — never in argv. Two of
# them are the very aggregates that crossed MAX_ARG_STRLEN on 2026-08-12: the
# void extract measured 133615 bytes that day, and the blocked extract already
# carries its entries' evidence payloads. Past the cap an `--argjson` delivery
# here would fail into the fail-open fallback below and pass every candidate
# through unfiltered — silently restoring the unfiltered band this requirement
# exists to remove, and doing it precisely when the void record is at its
# largest and its "heavily voided" misreading most tempting. A here-string
# rather than a pipe, for requirement 4c's reason: under `pipefail` a
# producer's SIGPIPE must not become this call's status.
exclude_blocked_or_void_items() {  # <candidates-json> <repo> <blocked-json> <void-json>
  local candidates="$1" repo="$2" blocked="${3:-[]}" void="${4:-[]}" docs
  jq -e 'type == "array"' <<<"$blocked" >/dev/null 2>&1 || blocked='[]'
  jq -e 'type == "array"' <<<"$void" >/dev/null 2>&1 || void='[]'
  docs="$(printf '%s\n' "$candidates" "$blocked" "$void")"
  # TD-PPagop-26081407: the `|| printf` below passes test 2 — it falls back to
  # the pre-filter $candidates, a value the caller already accepted, not a
  # fabricated empty.
  jq -nc --arg repo "$repo" '
    input as $candidates | input as $blocked | input as $void
    | [ $candidates[] | select(((.ref // null) as $r
                     | $r != null
                       and ($blocked | any(((.item // "") | tostring) == $r
                                           and ((.repo // "") == "" or (.repo // "") == $repo))) == false
                       and ($void | any(((.item // "") | tostring) == $r
                                        and ((.repo // "") == "" or (.repo // "") == $repo))) == false)) ]
  ' <<<"$docs" 2>/dev/null || printf '%s' "$candidates"
}

# Requirement 3u/issue #320: the fields of a `blocked` entry
# "Re-checking blocked items" and "A blocked issue with fresh evidence must be
# re-read" (prompts/coordinator.md) actually read — `item`, `ts`, `detail`,
# and `repo`/`recheck_clean_ts` where present — and nothing else. Every
# pre-fetched band but `issues` has already had its own blocked entries
# excluded before the Co-Ordinator ever sees the candidate (the loop that
# calls exclude_blocked_or_void_items/exclude_blocked_or_void_issues, below),
# so what remains of `blocked`'s purpose in the Co-Ordinator's own input is
# `issues`' live re-check duty and the exclusion-1 check on the three sources
# it still derives itself — neither reads `stage`, `cycle`, `event`, or an
# Implementor's `unblock_condition`, so there is nothing lost by leaving them
# off a list the model pays token cost to read every cycle. Malformed input
# degrades to the untrimmed array, on the same fail-open terms as
# exclude_blocked_or_void_items: a parse failure here must not silently empty
# the Co-Ordinator's only remaining view of blocked state.
coordinator_blocked_view() {  # <blocked-json>
  jq -c \
    '[.[] | {item, ts, detail}
            + (if has("repo") then {repo} else {} end)
            + (if has("recheck_clean_ts") then {recheck_clean_ts} else {} end)]' \
    <<<"$1" 2>/dev/null || printf '%s' "$1" # TD-PPagop-26081407: passes test 2 -- falls back to the unfiltered $1, a value the caller already accepted
}

# Requirement 3u/issue #320: the same deterministic-code-not-model-judgement
# exclusion as exclude_blocked_or_void_items above, purpose-built for the one
# pre-fetched band that function cannot be reused for as-is. Requirement 3t
# left `issues` out of the blanket exclusion on purpose — requirement 18a
# obliges the Co-Ordinator to re-read a blocked issue's live thread when its
# `updated_at` carries evidence posted after the block was last confirmed
# current, and a candidate dropped before the Co-Ordinator ever saw it cannot
# be re-read. Dropping every blocked issue here, the way `tech_debt` and every
# other band now are (see the loop below), would silently retire that
# mandatory re-check — precisely the live judgement 18a exists to keep in
# front of a human-in-the-loop model, not remove it.
#
# So this drops only what the prompt's own "Re-checking blocked items" and "A
# blocked issue with fresh evidence must be re-read" sections already tell the
# Co-Ordinator to skip *without* a re-read: an issue whose `updated_at` is no
# newer than the later of the block's own `ts` and its newest
# `recheck_clean_ts` (requirement 18a's own threshold, mirrored verbatim —
# `test/cycle-state.test.sh`'s `needs_mandatory_reread` pins the same
# comparison against the same field). That is exactly the "skip it on the
# marker alone, no re-read needed" case the prompt already states is
# mechanical, so removing it from the Co-Ordinator's judgement removes no
# judgement at all. A blocked issue whose `updated_at` *is* newer survives
# this filter and reaches the Co-Ordinator exactly as before, for the live
# re-read only it can perform. Void issues are dropped unconditionally, like
# every other band: unlike a block, a void has no re-check to preserve
# (requirement 34c — only a human's `unvoided` ever reopens one).
#
# Malformed input degrades to passing the array through unfiltered, and a
# candidate missing `ref` is dropped rather than crashed on — the same
# fail-open terms as exclude_blocked_or_void_items. Both extracts arrive on
# stdin, never in argv, for requirement 4g's reason (see
# exclude_blocked_or_void_items's own comment): this function shares that
# call's oversized-void exposure exactly.
exclude_blocked_or_void_issues() {  # <candidates-json> <repo> <blocked-json> <void-json>
  local candidates="$1" repo="$2" blocked="${3:-[]}" void="${4:-[]}" docs
  jq -e 'type == "array"' <<<"$blocked" >/dev/null 2>&1 || blocked='[]'
  jq -e 'type == "array"' <<<"$void" >/dev/null 2>&1 || void='[]'
  docs="$(printf '%s\n' "$candidates" "$blocked" "$void")"
  # TD-PPagop-26081407: the `|| printf` below passes test 2 — it falls back to
  # the pre-filter $candidates, a value the caller already accepted, not a
  # fabricated empty.
  jq -nc --arg repo "$repo" '
    def in_repo($e): ($e.repo // "") == "" or ($e.repo // "") == $repo;
    input as $candidates | input as $blocked | input as $void
    | [ $candidates[] | . as $c | (($c.ref // null) as $r
        | select($r != null)
        | select(($void | any(((.item // "") | tostring) == $r and in_repo(.))) == false)
        | ([ $blocked[] | select(((.item // "") | tostring) == $r and in_repo(.)) ]) as $matches
        | select(
            ($matches | length) == 0
            or (
              ($matches | map([(.ts // empty), (.recheck_clean_ts // empty)]) | flatten) as $thresholds
              | (($thresholds | max) // "") as $threshold
              | (($c.updated_at // "") > $threshold)
            )
          )
        | $c) ]
  ' <<<"$docs" 2>/dev/null || printf '%s' "$candidates"
}

# Requirement 3x's machine corroboration (issue #322) — requirement 3t's own
# (issue #310), generalised off the one band it was proven on: which of this
# cycle's eligible items (ELIGIBLE_JSON, `{repo, item, source}` entries,
# `coordinator_eligible_items`' own output across every pre-fetched band) a
# `selected: false` verdict left completely unaccounted for. A bar-clearing
# item may be declined without being selected only two ways: reported in
# `needs_refinement` under that item's own source, or voided this same cycle —
# the same two the prompt's own "Reporting an under-specified item" and "Void
# items" sections give every source. `refinement_policy[<source>] ==
# "required"` is a third, legitimate silent skip (requirement 39a: an
# unrefined item there is never selectable, so the Co-Ordinator owes it no
# report), which is why an eligible entry from such a source is dropped here
# rather than flagged as unaccounted.
#
# The band is carried on the entry rather than passed as an argument, so one
# call corroborates the whole verdict at once and the per-source policy, the
# per-source `needs_refinement` match and the per-band tally all fall out of
# the same pass. That is deliberately not six copies of one rule: the *only*
# thing that varies by band is which items are eligible, and that is
# `coordinator_eligible_items`' job, not this one's.
#
# RECORDED_JSON is what the Script *recorded* from the Co-Ordinator's message
# — `log_needs_refinement_items`' and `log_voided_items`' own collections —
# never the message's `needs_refinement`/`voided` arrays verbatim, and that
# property is preserved band by band rather than re-argued per band. The
# difference is the whole point: `record_needs_refinement_block` drops an
# entry that fails requirement 34d's five-field bar with nothing but a
# warning, so a claimed-but-dropped report leaves its item open, unclaimed
# and eligible — and had it still counted as accounting for that item, the
# corroboration would have been satisfied, the fingerprint armed, and the
# next cycle's byte-identical inputs would have stood the fleet down on a
# verdict that never engaged with the band: issue #310's freeze, reopened
# through a narrow door (every eligible item reported, every report
# malformed — precisely the fields a small model omits). A `voided` entry, by
# contrast, is counted whichever way the void guard rules, because both
# outcomes are recorded state: a pass writes the void, a refusal writes a
# block (requirement 34d), and either removes the item from the next cycle's
# eligible set — so the two arrays are hardened by the one rule "count what
# was recorded", not by two different shape tests.
#
# Any entry this prints is evidence the Co-Ordinator's verdict did not
# actually engage with the band it is declining — exactly the shape of the
# incident this requirement exists for (issue #310), where the stated reason
# ("requires per-item evaluation…", "heavily voided or blocked") was
# demonstrably false against data the Script itself had already filtered.
# Malformed input degrades to `[]` — silence, not a false positive — on the
# same fail-open terms as exclude_claimed_items and
# exclude_blocked_or_void_items above.
unaccounted_items() {  # <recorded-json> <eligible-json> <refinement-policy-json>
  local recorded="$1" eligible="${2:-[]}" policy="${3:-{\}}" docs
  jq -e 'type == "array"' <<<"$eligible" >/dev/null 2>&1 || eligible='[]'
  jq -e 'type == "object"' <<<"$policy" >/dev/null 2>&1 || policy='{}'
  # Keyed on joined strings through two lookup maps rather than on jq's own
  # array/object equality: `index` given an array argument searches for a
  # *subsequence*, not an element, so the obvious `[$repo,$item] | index` form
  # matches things it should not. `\u0000` cannot occur in a repo slug or an
  # item ref minted by any gatherer here, so the join is unambiguous.
  #
  # requirement 4g (TD-PPagop-26081401): $eligible is the Script's own
  # pre-fetched-band denominator (requirement 3x) and grows with every
  # eligible item across every band and repo this cycle -- unbounded past
  # this call, and it is what the four verdict-contradiction logging sites
  # downstream (site 3 of TD-PPagop-26081401) filter into
  # $unaccounted_json/$unaccounted_retry_json. Leaving this call on argv
  # would fail it first, silently, into this same function's own fail-open
  # [] -- an oversized eligible set would then read as "everything is
  # accounted for" rather than the argv failure it actually is, exactly the
  # silent-degradation failure mode requirement 4g exists to remove.
  # $recorded travels alongside it on the same stdin document.
  docs="$(printf '%s\n' "$recorded" "$eligible")"
  # TD-PPagop-26081407: this is the guard the 2026-08-14 outage actually went
  # through -- an execve failure here read as "everything is accounted for"
  # and the Script corroborated a none-selected verdict silently. requirement
  # 4g's stdin move above already closed off that specific delivery path
  # (test 1 mostly does not apply any more), but a caller reading [] still
  # cannot tell a clean zero from any other jq failure (test 2 always fails),
  # so this reports regardless of cause.
  local out
  out="$(jq -nc --argjson policy "$policy" '
    input as $recorded | input as $eligible
    | def ikey: ((.repo // "") + "\u0000" + ((.item // "") | tostring));
      def skey: (ikey + "\u0000" + (.source // ""));
      (($recorded.needs_refinement // []) | map({key: skey, value: true}) | from_entries) as $reported
      | (($recorded.voided // []) | map({key: ikey, value: true}) | from_entries) as $disposed
      | [ $eligible[]
          | select((($policy[(.source // "")] // "exempt") != "required")
                   and (($reported[skey] // false) | not)
                   and (($disposed[ikey] // false) | not)) ]
    ' <<<"$docs" 2>&1)" || { guard_warn "unaccounted_items" "$out"; out='[]'; }
  printf '%s' "$out"
}

# Requirement 3x (issue #322): the Script's own answer to "what could the
# Co-Ordinator actually have selected this cycle", across every band it hands
# over pre-fetched — `{repo, item, source}` per entry, `source` the same token
# the repo's `sources` list, a `needs_refinement` entry and
# `refinement_policy` all use. It is the denominator `unaccounted_items`
# above tests a `selected: false` verdict against, and the reason that
# function needs no per-band special-casing of its own.
#
# Read *after* requirement 2.2a's back-pressure decision, for the reason
# requirement 3t's tech-debt-only predecessor was: a restricted cycle narrows
# every repo's `sources` to the four finishing ones, and a verdict is owed no
# account of a band this cycle forbade it to select from. Which is also why
# each band is gated on the repo's own `sources` here rather than on the array
# merely being non-empty: back-pressure narrows the list without emptying
# `findings`, `register_hygiene` or `human_visibility`, so the list is the
# authority on what was selectable and the array is not.
#
# Three bands need more than "every entry in the array":
#
#   - `issues` is one source at four ranks (requirement 15e), so an issue is
#     eligible only if its own `Priority` band's token is listed — a repo
#     configured `issues:high` alone was never offered its Medium issues.
#   - `issues` also still carries blocked entries after requirement 3u's own
#     pass: `exclude_blocked_or_void_issues` deliberately keeps the ones whose
#     thread has moved, because requirement 18a obliges a live re-read only the
#     Co-Ordinator can perform. A blocked issue is not selectable until that
#     re-read unblocks it, so counting it here would demand an account for an
#     item the Script did not offer. They are dropped on exactly
#     `exclude_blocked_or_void_items`' matching rule, blank `repo` included.
#   - `merge_conflicts` carries the one entry shape the prompt tells the
#     Co-Ordinator to skip in silence: a Dependabot PR this system has not yet
#     asked to rebase (`bot`, no `rebase_requested`, not superseded) is "not a
#     candidate of any kind" there, so it is not one here either. Its
#     superseded sibling *is* eligible — the prompt requires that one in
#     `voided`, which is an account.
#
# Every other band is exactly "an entry's presence in this array is the
# candidate test", which is the prompt's own words for all six of them. A jq
# failure yields `[]` — no corroboration rather than a false one — on the same
# fail-open terms as every exclusion above.
coordinator_eligible_items() {  # <ordered-repos-json> <blocked-json>
  local repos="${1:-[]}" blocked="${2:-[]}" out
  jq -e 'type == "array"' <<<"$repos" >/dev/null 2>&1 || repos='[]'
  jq -e 'type == "array"' <<<"$blocked" >/dev/null 2>&1 || blocked='[]'
  # TD-PPagop-26081407: like unaccounted_items, this is the Co-Ordinator's own
  # eligible-set denominator (requirement 3x) -- a jq failure here reading as
  # `[]` would silently tell the fleet nothing was ever selectable.
  out="$(printf '%s\n%s\n' "$repos" "$blocked" | jq -nc '
    def listed($srcs; $s): (($srcs // []) | index($s)) != null;
    def band($r; $srcs; $arr; $src):
      if (listed($srcs; $src) | not) then empty
      else ($arr // [])[]
           | {repo: $r, item: ((.ref // "") | tostring), source: $src}
           | select(.item != "")
      end;
    input as $repos | input as $blocked
    | ([ $blocked[]? | {key: ((.repo // "") + "\u0000" + ((.item // "") | tostring)), value: true} ]
       | from_entries) as $blocked_here
    | ([ $blocked[]? | select((.repo // "") == "")
                     | {key: ((.item // "") | tostring), value: true} ]
       | from_entries) as $blocked_anywhere
    | [ $repos[]
        | . as $e | (.slug // "") as $r | (.sources // []) as $srcs
        | ( band($r; $srcs; [($e.findings // [])[] | select((.source // "") == "security")]; "security"),
            band($r; $srcs; [($e.findings // [])[] | select((.source // "") == "code-quality")]; "code-quality"),
            band($r; $srcs; $e.review_feedback; "review-feedback"),
            band($r; $srcs;
                 [($e.merge_conflicts // [])[]
                  | select(((.bot // false) | not)
                           or (.rebase_requested // false)
                           or ((.superseded_by // null) != null))];
                 "merge-conflicts"),
            band($r; $srcs; $e.dequeued; "dequeued"),
            band($r; $srcs; $e.abandoned_drafts; "abandoned-drafts"),
            band($r; $srcs; $e.human_visibility; "human-visibility"),
            band($r; $srcs; $e.register_hygiene; "register-hygiene"),
            band($r; $srcs; $e.tech_debt; "tech-debt"),
            ( ($e.issues // [])[]
              | (((.priority // "Medium") | tostring | ascii_downcase)) as $pband
              | select(listed($srcs; "issues") or listed($srcs; "issues:" + $pband))
              | {repo: $r, item: ((.ref // "") | tostring), source: "issues"}
              | select(.item != "")
              | select((($blocked_here[(.repo + "\u0000" + .item)] // false) | not)
                       and (($blocked_anywhere[.item] // false) | not)) ) ) ]
    ' 2>&1)" || { guard_warn "coordinator_eligible_items" "$out"; out='[]'; }
  printf '%s' "$out"
}

# Whether a candidate the Co-Ordinator returned is one this same cycle's own
# gather already saw claimed (requirement 17a). The claim attempt below would
# lose anyway — GitHub still arbitrates — but a loss that was knowable from
# data already in hand is not contention, it is the Co-Ordinator proposing
# claimed work, and counting it as a race loss would both misread the
# dashboard's contention signal and spend claim API calls on a foregone
# conclusion. Matched on the raw item ref and on its branch-sanitised form,
# because a claim branch's name (claim_branch_for) flattens characters the
# ref may carry and gather_claimed derives items back off branch names.
candidate_preclaimed() {  # <repo> <item> <claims-at-gather-json> -> 0 iff already claimed at gather
  local repo="$1" item="$2" claims="$3" sanitised
  sanitised="${item//[^A-Za-z0-9._-]/-}"
  # Exactly 0 or 1, whatever jq's own exit code says: malformed claims JSON
  # must read as "not pre-claimed" (fail open — the atomic claim below stays
  # the gate), never as a distinct status a caller could misread.
  jq -e --arg r "$repo" --arg i "$item" --arg s "$sanitised" \
    'any(.[]; .repo == $r and (.item == $i or .item == $s))' <<<"$claims" >/dev/null 2>&1 \
    || return 1
}

# Requirement 17a/issue #238: which PR a finishing-source candidate targets, for
# the PR-keyed claim below to key on. The candidate's own `pr_number` when it
# carries a usable one — prompts/coordinator.md requires it on all four
# finishing sources' work orders — and otherwise the number the *item ref*
# itself embeds, because all four gather scripts mint their refs with it in
# them by construction (`pr-<n>-review-<id>`, `pr-<n>-conflict-<sha>`,
# `pr-<n>-dequeued-<sha>`, `pr-<n>-abandoned-<sha>`; requirements 3c, 3e, 3z,
# 3g). The fallback is the whole point: this claim is the hard gate that
# excludes a peer fleet-wide, and a gate that engages only when the model
# remembered to copy a field is not one — a single omitted `pr_number` would
# silently reopen the three-nodes-on-PR-#205 failure this exists to close.
# Empty only when neither source yields a number, which for these four
# sources cannot happen without a malformed ref.
pr_number_for_candidate() {  # <candidate-json> <item-ref>
  local n
  n="$(jq -r '.pr_number // empty' <<<"$1" 2>/dev/null || true)"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    printf '%s' "$n"
  elif [[ "$2" =~ ^pr-([0-9]+)- ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
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
# Take the projected label, and the projected assignment (requirement 38b),
# off the issue behind ITEM, if this item's refinement block put them there.
# Called wherever a block clears — the Co-Ordinator's own re-check, an Enabler
# `unblocked`, and a `void` from either — because the label's and the
# assignment's lifecycles mirror the block's and nothing else would ever take
# them off.
#
# Reads the blocked extract this cycle computed *before* the Co-Ordinator ran,
# which is the correct one: the block being cleared is by definition one that was
# open when the cycle started. Best-effort throughout — a stale label or
# assignment is a cosmetic fault on an issue, and no reason to disturb a cycle
# recording state.
release_refinement_label() {
  local item="$1" repo="${2:-}" t_repo t_num t_label t_assignee
  [[ -n "$item" ]] || return 0
  # A dry run changes nothing in any repository (requirement 12). It still logs
  # the verdicts on this path, as it always has, but a label is an outward act.
  # Written as an `if` rather than `(( DRY_RUN )) && return 0`, whose status
  # would be the function's on the common path — the errexit trap in the
  # Gotchas table, one call site away from a caller that runs under `set -e`.
  if (( DRY_RUN )); then return 0; fi
  while IFS=$'\t' read -r t_repo t_num t_label; do
    [[ -n "$t_repo" && -n "$t_num" && -n "$t_label" ]] || continue
    if refinement_label_remove "$t_repo" "$t_num" "$t_label"; then
      log_event "own-label-action" "$(label_own_action_fields "$t_repo" "$t_num" "$t_label" "remove")"
    else
      log_event "warning" \
        "$(jq -nc --arg d "could not remove the $t_label label from $t_repo#$t_num — the block is cleared regardless" \
           '{detail: $d}')"
    fi
  done < <(refinement_label_targets "${blocked_json:-[]}" "$item" "$repo")
  while IFS=$'\t' read -r t_repo t_num t_assignee; do
    [[ -n "$t_repo" && -n "$t_num" && -n "$t_assignee" ]] || continue
    refinement_assignee_remove "$t_repo" "$t_num" "$t_assignee" || log_event "warning" \
      "$(jq -nc --arg d "could not unassign $t_assignee from $t_repo#$t_num — the block is cleared regardless" \
         '{detail: $d}')"
  done < <(refinement_assignee_targets "${blocked_json:-[]}" "$item" "$repo")
}

# record_needs_refinement_block ENTRY STAGE
# Record one needs_refinement-shaped ENTRY (`{repo, item, source, reason,
# missing, evidence}`) as a block attributed to STAGE (requirement 34e).
# Returns 1 and records nothing but a `warning` when ENTRY fails requirement
# 34d's completeness bar or the item is already blocked.
#
# The single recorder for every stage that can report this class of block —
# the Co-Ordinator (requirement 16a), the Implementor's escape hatch
# (requirement 9f), and the Refiner's own decline (requirement 39d). One
# definition (requirement 34a): three reporters, one recorder, so the label,
# the assignment and the block's shape can never drift between them.
#
# Two entries are dropped rather than recorded, each with a warning, and both
# refusals are the Script's job rather than the reporting stage's:
#
#   - a malformed entry, on requirement 34d's discipline. The fields are what the
#     Enabler starts from; an entry without them starves the very stage this
#     path exists to reach.
#   - a re-report of an item that is *already* blocked. Requirement 34 keys a
#     block on repo+item and requirement 35a measures the Enabler threshold from
#     the latest one, so re-reporting the same item every cycle would push that
#     clock forward hourly and the item would never become eligible — the same
#     silent starvation this whole path exists to end, with an event trail that
#     looks like progress.
record_needs_refinement_block() {
  local entry="$1" stage="$2" repo item reason problem label assignee number who
  who="$(pipeline_actor_label "$stage")"
  if ! problem="$(refinement_entry_problem "$entry")"; then
    log_event "warning" "$(jq -nc --arg d "$who needs_refinement entry dropped — it $problem" \
      '{detail: $d}')"
    return 1
  fi
  repo="$(jq -r '.repo // ""' <<<"$entry")"
  item="$(jq -r '.item // ""' <<<"$entry")"
  reason="$(jq -r '.reason // "no reason given"' <<<"$entry")"

  if jq -e --arg r "$repo" --arg i "$item" \
       'any(.[]?; (.repo // "") == $r and ((.item // "") | tostring) == $i)' \
       <<<"${blocked_json:-[]}" >/dev/null 2>&1; then
    log_event "warning" "$(jq -nc \
      --arg d "$who reported $repo $item as needing refinement, but it is already blocked — left as it is so the Enabler threshold keeps running" \
      '{detail: $d}')"
    return 1
  fi

  # No label or assignment on a dry run, and — because the event records what
  # was actually applied — neither recorded either, so nothing later tries to
  # remove something that was never there.
  label=""
  assignee=""
  if ! (( DRY_RUN )); then
    number="$(refinement_issue_number "$entry")"
    if [[ -n "$number" ]]; then
      if [[ -n "$needs_refinement_label" ]]; then
        if refinement_label_add "$repo" "$number" "$needs_refinement_label"; then
          label="$needs_refinement_label"
          log_event "own-label-action" \
            "$(label_own_action_fields "$repo" "$number" "$needs_refinement_label" "add")"
        else
          log_event "warning" "$(jq -nc \
            --arg d "could not apply the $needs_refinement_label label to $repo#$number (does it exist in that repo?) — the block is recorded either way" \
            '{detail: $d}')"
        fi
      fi
      # Requirement 38b: the same projection the label gets, so a block gated
      # on a decision the human has not made reaches the human's own
      # Assigned-to-me dashboard the moment it is recorded, rather than
      # waiting for the Enabler's own, much later, escalation. Through
      # `refinement_assignee_project`, not `refinement_assignee_add`: an
      # assignment the human made themselves before the block existed is
      # recorded by neither, so clearing the block never removes it.
      if [[ -n "$enabler_assignee" ]]; then
        case "$(refinement_assignee_project "$repo" "$number" "$enabler_assignee")" in
          added) assignee="$enabler_assignee" ;;
          present) ;;
          unrecorded)
            log_event "warning" "$(jq -nc \
              --arg d "could not read $repo#$number's assignees — $enabler_assignee was assigned best-effort but not recorded on the block, so clearing it will not unassign them" \
              '{detail: $d}')"
            ;;
          *)
            log_event "warning" "$(jq -nc \
              --arg d "could not assign $enabler_assignee to $repo#$number — the block is recorded either way" \
              '{detail: $d}')"
            ;;
        esac
      fi
      # Requirement 39d: a fresher block supersedes an existing refinement, so
      # a `refined_label` a prior Refiner engagement left must come off too —
      # the same consistency `release_refinement_label` keeps for the negative
      # label, mirrored here for the positive one.
      if [[ -n "$refined_label" ]] && [[ -n "$number" ]] && jq -e --arg r "$repo" --arg i "$item" \
           '(.[$r][$i] // null) != null' <<<"${refinements_json:-{\}}" >/dev/null 2>&1; then
        if refinement_label_remove "$repo" "$number" "$refined_label"; then
          log_event "own-label-action" \
            "$(label_own_action_fields "$repo" "$number" "$refined_label" "remove")"
        else
          log_event "warning" "$(jq -nc \
            --arg d "could not remove the $refined_label label from $repo#$number — the fresher block is recorded regardless" \
            '{detail: $d}')"
        fi
      fi
    fi
  fi

  log_event "attempt-failed" "$(item_event_fields "$stage" "$reason" "$repo" "$item" \
    "$(refinement_block_fields "$entry" "$label" "$assignee")")"
  return 0
}

# log_needs_refinement_items WORK_ORDER
# Record every one of the Co-Ordinator's `needs_refinement` reports via
# `record_needs_refinement_block`, attributed to `stage: "coordinator"`.
#
# Collects the entries the recorder actually accepted into
# `coord_recorded_refinement_json` for requirement 3t's corroboration, which
# must count what was recorded and never what was claimed: an entry dropped
# at requirement 34d's bar records nothing, so its item stays eligible, and
# letting it account for that item anyway would arm the no-op fingerprint on
# a verdict that never engaged with the band (see
# unaccounted_items). The already-blocked refusal also lands here
# uncounted, harmlessly — a blocked item was never in the eligible set to
# need accounting for.
log_needs_refinement_items() {
  local wo="$1" entry
  coord_recorded_refinement_json="[]"
  while IFS= read -r entry; do
    if record_needs_refinement_block "$entry" "coordinator"; then
      # $entry and the accumulator both arrive on stdin, one document per
      # line, bound positionally with `input as $name` in the order printed
      # (requirement 4g) — never in argv: this accumulator grows with the
      # cycle's whole needs_refinement band, and its builder failing silently
      # fail-opens unaccounted_items to [] (TD-PPagop-26081406).
      coord_recorded_refinement_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
        <<<"$coord_recorded_refinement_json"$'\n'"$entry")"
    fi
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
#
# Collects every entry it disposed of into `coord_recorded_voided_json` for
# requirement 3t's corroboration — and "disposed of" deliberately includes a
# refusal, unlike log_needs_refinement_items' collection just above, because
# here both outcomes write state: a pass records the void, a refusal records
# a block, and either takes the item out of the next cycle's eligible set. An
# entry naming no item is the one thing that records nothing, and it is the
# one thing not collected.
log_voided_items() {
  local wo="$1" repos="${2:-[]}" entry item repo reason refusal
  coord_recorded_voided_json="[]"
  while IFS= read -r entry; do
    item="$(jq -r '.item // ""' <<<"$entry")"
    [[ -n "$item" ]] || continue
    repo="$(jq -r '.repo // ""' <<<"$entry")"
    reason="$(jq -r '.reason // "no reason given"' <<<"$entry")"
    # $entry and the accumulator both arrive on stdin, one document per
    # line, bound positionally with `input as $name` in the order printed
    # (requirement 4g) — never in argv: see log_needs_refinement_items above
    # for why this accumulator's builder failing silently matters
    # (TD-PPagop-26081406).
    coord_recorded_voided_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
      <<<"$coord_recorded_voided_json"$'\n'"$entry")"

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
  local out_file="$1" text resume_at class reset_known evidence=""
  # Two sources, and the structured one comes first because it is better
  # evidence, not merely earlier: the stream's own `rate_limit_info` carries
  # an epoch reset time, so the stand-down is a fact rather than the estimate
  # a prose parse has to settle for — and an estimated stand-down costs the
  # fleet a probe every cycle until it clears (requirement 2.1b). It also
  # exists on a path the prose parse cannot reach at all: a stage stopped the
  # moment the account refused never wrote a final message for the phrase
  # matcher to read.
  if [[ -n "${stage_rate_limit_json:-}" ]] \
     && IFS=$'\t' read -r resume_at class reset_known \
          < <(limit_decide_structured "$stage_rate_limit_json" "$limit_cooldown_default_hours"); then
    limit_hit_this_cycle=1
    evidence="$stage_rate_limit_json"
  else
    limit_phrase_in "$out_file" "$out_file.stderr" || return 1
    # Remembered for the rest of the cycle, because the Enabler runs from the exit
    # trap — after this point on every path — and engaging the fleet's most
    # expensive model moments after any stage hit a limit would simply re-hit it
    # (requirement 35's guards).
    limit_hit_this_cycle=1
    text="$(cat "$out_file" "$out_file.stderr" 2>/dev/null || true)"
    IFS=$'\t' read -r resume_at class reset_known < <(limit_decide "$text" "$limit_cooldown_default_hours")
    evidence="$(grep -ihE "$LIMIT_PHRASE_REGEX" "$out_file" "$out_file.stderr" 2>/dev/null | head -n1 || true)"
  fi
  # The API's own words, bounded: what the detector actually saw is what
  # distinguishes an automatic stand-down from an assertion, and is what a
  # later extension must bring fresh (requirement 2; #244).
  evidence="${evidence:0:400}"
  log_event "limit-hit" "$(jq -nc --arg r "$resume_at" --arg c "$class" --argjson k "$reset_known" \
    --arg n "$node_name" --arg e "$evidence" \
    '{resume_at: $r, class: $c, reset_known: $k, kind: "auto", actor: $n,
      evidence: (if $e == "" then null else $e end)}')"
  # Tell the fleet now, not a fetch interval from now: publish the stand-down
  # as fleet/limit.json (extend-only; requirement 2.1). Best-effort — the
  # limit-hit event above is already in this node's log, and the union carries
  # it to every peer on their next fetch regardless.
  fleet_limit_publish "$state_repo" "$state_dir" "$resume_at" "$class" "$reset_known" "$node_name" "$evidence" \
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
#
# Also records whether this cycle's own read succeeded, for requirement 34n's
# liveness retirement (TD-PPagop-26081303): a `findings-$safe.ok` marker,
# written iff gather-findings.sh's own contract says so (exit 0 — a disabled
# feature or a legitimately empty answer; exit 1 on a real failure). The void-
# liveness pass, further down this cycle, reads the marker and the tee'd
# `.json` array together — `ok` decides whether the array may be trusted as
# "every alert still open", never whether it is non-empty.
gather_findings() {
  local slug="$1" out safe rc
  safe="${slug//\//_}"
  if out="$("$SCRIPT_DIR/scripts/gather-findings.sh" "$slug" 2>"$cycle_dir/findings-$safe.err")"; then
    rc=0
  else
    rc=$?
  fi
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/findings-$safe.json"
    printf '%s' "$out"
    # The marker requires *both* halves: a zero exit and a tee file the
    # liveness pass can actually read. gather-findings.sh exits 0 on paths
    # that can still leave stdout unusable (its final `jq -n` failing prints
    # nothing yet falls through to `exit 0`), and a marker written without
    # the `.json` beside it reads downstream as "gathered, found nothing" —
    # the one sentence this marker exists to stop the cycle saying.
    (( rc == 0 )) && : > "$cycle_dir/findings-$safe.ok"
  else
    printf '[]'
  fi
  return 0
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

# Pre-fetch the ready-but-conflicted PRs this system raised (requirement 3g),
# plus Dependabot's own conflicted PRs (requirement 3s, issue #250). Same
# rationale as gather_abandoned_drafts: its candidacy turns on a transition
# the open-PR digest does not carry (a PR flips to CONFLICTING a cycle after its
# base moved, as GitHub recomputes mergeability asynchronously), so the array
# must be computed here and fed to the fingerprint verbatim for the no-op
# short-circuit to notice it (see scripts/gather-merge-conflicts.sh and
# lib/noop-skip.sh). A `bot` candidate gets one more step before either of
# those: scripts/nudge-dependabot-rebase.sh, which posts a first `@dependabot
# rebase` request and drops that candidate from the array this cycle — see
# the comment inside the function below.
gather_merge_conflicts() {
  local slug="$1" out safe nudge_result
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-merge-conflicts.sh" "$slug" "$pr_label" "$branch_prefix" \
        2>"$cycle_dir/merge-conflicts-$safe.err" || true)"
  # Requirement 34n's liveness retirement (TD-PPagop-26081303): a
  # `merge-conflicts-$safe.ok` marker, written iff this cycle's own read
  # produced a valid array and said nothing on stderr. gather-merge-
  # conflicts.sh always exits 0 by design (its output feeds the Co-Ordinator,
  # and a source that cannot look must simply not fire rather than abort the
  # cycle), so stderr is the only signal a real `gh` failure leaves — the same
  # distinction scripts/gather-register-hygiene.sh draws between "empty
  # because there is nothing" and "empty because it could not look".
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 \
     && [[ ! -s "$cycle_dir/merge-conflicts-$safe.err" ]]; then
    : > "$cycle_dir/merge-conflicts-$safe.ok"
  fi
  if [[ -z "$out" ]] || ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '[]'
    return
  fi

  # The nudge-then-takeover half of Dependabot-conflict handling (requirement
  # 3s, issue #250): a `bot` candidate this script has never yet asked to
  # rebase gets that ask now — a real write, so `--dry-run` skips it, exactly
  # like every other sweep in this cycle. Whatever it drops from the array
  # (the candidate it just nudged) is dropped from *both* what is stored below
  # for the fingerprint and what reaches the Co-Ordinator: the first sighting
  # of a conflict and the first nudge for it happen in the same cycle, so
  # there is genuinely nothing selectable yet, and the fingerprint should read
  # that the same way the Co-Ordinator does. The transition still surfaces —
  # next cycle's gather-merge-conflicts.sh reports `rebase_requested: true`
  # for the same head, a different array shape from this cycle's, which busts
  # the fingerprint on its own.
  if (( DRY_RUN )); then
    printf '%s\n' "$out" > "$cycle_dir/merge-conflicts-$safe.json"
    printf '%s' "$out"
    return
  fi

  nudge_result="$(printf '%s' "$out" \
      | "$SCRIPT_DIR/scripts/nudge-dependabot-rebase.sh" "$slug" "$cycle_id" "$node_name" \
        2>"$cycle_dir/dependabot-nudge-$safe.err" || true)"
  if [[ -z "$nudge_result" ]] || ! jq -e 'type == "object"' <<<"$nudge_result" >/dev/null 2>&1; then
    # The nudge step failing is not this array's failure — fall back to the
    # gatherer's own output rather than losing every candidate in this repo
    # (including our own, non-bot ones) over one broken write step. Still
    # drop any bot candidate that has never been nudged (`bot: true`,
    # `rebase_requested: false`, no `superseded_by`) — the same predicate
    # nudge-dependabot-rebase.sh itself applies — so a broken nudge step
    # cannot hand the Co-Ordinator's ordinary-case catch-all an un-nudged
    # bot branch to force-push (requirement 3s). A wholly-broken nudge step
    # reaches no other log: it returns before the per-candidate loop below,
    # so without this, a permanently broken step would silently skip every
    # conflicted Dependabot PR, every cycle, forever (requirement 3s).
    log_event "warning" "$(jq -cn --arg r "$slug" \
      '{detail: ("nudge-dependabot-rebase.sh produced no usable result for " + $r + " — falling back to the gatherer'"'"'s own read")}')"
    # `out` is only validated as `type == "array"` above, not that its elements
    # are objects — `.bot` on a non-object element is a `jq` error under
    # `set -euo pipefail`, and this is the one path where a malformed-but-array
    # gatherer output meets an already-broken nudge step. Degrade to an empty
    # array rather than aborting the cycle over it (requirement 3s).
    if ! out="$(jq -c '[.[] | select(
        ((.bot // false) == true)
        and ((.rebase_requested // false) == false)
        and ((.superseded_by // null) == null)
        | not)]' <<<"$out" 2>"$cycle_dir/merge-conflicts-filter-$safe.err")"; then
      log_event "warning" "$(jq -cn --arg r "$slug" \
        '{detail: ("could not filter un-nudged Dependabot candidates for " + $r + " — malformed gatherer output; dropping all candidates for this repo this cycle")}')"
      out='[]'
    fi
    printf '%s\n' "$out" > "$cycle_dir/merge-conflicts-$safe.json"
    printf '%s' "$out"
    return
  fi

  while IFS= read -r nudge_action; do
    [[ -n "$nudge_action" ]] || continue
    if [[ "$(jq -r '.outcome // ""' <<<"$nudge_action")" == "requested" ]]; then
      log_event "dependabot-rebase-requested" \
        "$(jq -c --arg r "$slug" '{repo: $r} + del(.outcome)' <<<"$nudge_action")"
    else
      log_event "warning" "$(jq -c --arg r "$slug" \
        '{detail: ("could not post @dependabot rebase on " + $r + " #" + (.number | tostring))}' \
        <<<"$nudge_action")"
    fi
  done < <(jq -c '.actions[]?' <<<"$nudge_result" 2>/dev/null || true)

  out="$(jq -c '.conflicts' <<<"$nudge_result")"
  printf '%s\n' "$out" > "$cycle_dir/merge-conflicts-$safe.json"
  printf '%s' "$out"
}

# Pre-fetch the ready PRs this system raised that GitHub's merge queue
# dequeued over a merge-group checks failure (TD-PPagop-26081409, requirement
# 3z). Same rationale as gather_merge_conflicts: a dequeue is a transition the
# open-PR digest cannot see at all (no commit lands, `updatedAt` barely
# moves), so the array is computed here and fed to the fingerprint verbatim
# for the no-op short-circuit to notice it (see scripts/gather-dequeued.sh and
# lib/noop-skip.sh). No nudge-then-takeover step exists for this source — no
# bot is involved — so unlike gather_merge_conflicts this is a direct pass
# through to the gatherer script.
gather_dequeued() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-dequeued.sh" "$slug" "$pr_label" "$branch_prefix" \
        2>"$cycle_dir/dequeued-$safe.err" || true)"
  # Requirement 34n's liveness retirement, same marker discipline as
  # `merge-conflicts-$safe.ok`: written iff this cycle's own read produced a
  # valid array and said nothing on stderr.
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 \
     && [[ ! -s "$cycle_dir/dequeued-$safe.err" ]]; then
    : > "$cycle_dir/dequeued-$safe.ok"
  fi
  if [[ -z "$out" ]] || ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '[]'
    return
  fi
  printf '%s\n' "$out" > "$cycle_dir/dequeued-$safe.json"
  printf '%s' "$out"
}

# Pre-fetch the repo's TECH-DEBT.md when it disagrees with itself (requirement
# 3i). Unlike the three above this one's candidacy is a pure function of one
# file's content, so the repo's head SHA would already wake the cycle that
# introduced the drift; the array is fed to the fingerprint verbatim anyway, for
# uniformity with its siblings and because editing scripts/td-check.pl changes
# candidacy with no commit to the target repo at all (see
# scripts/gather-register-hygiene.sh and lib/noop-skip.sh).
#
# PURPOSE, like gather_review_status's own, names the asking pass — `prefetch`
# (this repo walk) or `void` (requirement 34l's void re-derivation below) —
# and lands in the diagnostic filenames. Unlike its siblings this function has
# *two* callers per cycle for the same repo, and before they were separated
# the second one's tee silently overwrote the first's: gather-register-
# hygiene.sh prints `[]` on stdout for every failure path (a rate limit, a
# network blip, a branch moved between the two — the exact cases the void pass
# below names), which is a valid array, so a failed second read replaced a
# successful first read's array with an empty one while the `.ok` marker that
# read had already written stayed put. The liveness pass then read
# marker-present plus no ids as "gathered, found nothing" and retired every
# still-live `register-hygiene-<hash>` void in the repo — a retirement caused
# by a failed read, which is the one thing the marker exists to prevent.
gather_register_hygiene() {
  local slug="$1" branch="$2" purpose="$3" void="${4:-[]}" out safe
  safe="$purpose-${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-register-hygiene.sh" "$slug" "$branch" "$void" \
        2>"$cycle_dir/register-hygiene-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/register-hygiene-$safe.json"
    printf '%s' "$out"
    # Requirement 34n's liveness retirement (TD-PPagop-26081303): a
    # `register-hygiene-$safe.ok` marker, written iff this read said nothing
    # on stderr. gather-register-hygiene.sh always exits 0 by design (a real
    # API failure is deliberately as silent, on stdout, as "no register" —
    # see its own header — with the diagnosis reaching only stderr), so
    # stderr emptiness is the one signal a real failure leaves. Written as a
    # full `if`, not a `&&` list: this is the last command in the function,
    # and a bare `&&` whose test fails would return 1 from the function
    # itself — which under `set -e` aborts the whole cycle at the plain
    # assignment the void-register-hygiene pass below makes.
    if [[ ! -s "$cycle_dir/register-hygiene-$safe.err" ]]; then
      : > "$cycle_dir/register-hygiene-$safe.ok"
    fi
  else
    printf '[]'
  fi
}

# Pre-fetch this repo's still-live human-visibility violations (requirement
# 38e) — its own source, `human-visibility` (issue #284's decision 2), never
# `gather_register_hygiene`'s: a violation is a fact about GitHub's live
# pull-request state, unrelated to the register content that source reasons
# about, so the two never share a candidate or a ref (see
# scripts/gather-human-visibility-hygiene.sh). `violations` is the fleet-wide
# array `human_visibility_violations` produced from the union log; the script
# itself filters to this repo's slice.
gather_human_visibility_hygiene() {
  local slug="$1" violations="${2:-[]}" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-human-visibility-hygiene.sh" "$slug" "$violations" "$pr_label" \
        2>"$cycle_dir/human-visibility-hygiene-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/human-visibility-hygiene-$safe.json"
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

# Pre-fetch the repo's open tech-debt register items (requirement 3t, issue
# #310) — the same move issues, findings, review-feedback, merge-conflicts,
# abandoned-drafts and register-hygiene already got: a source the model could
# silently misdescribe or decline to re-derive becomes an input instead of an
# errand. Claimed-item exclusion is applied by the caller via
# exclude_claimed_items, like every other pre-fetched array; blocked/void
# exclusion is applied by a second pass once blocked_json/void_json exist (see
# "3c/3u. Pre-fetched-band eligibility" below) — this function only ever
# returns the raw open set.
gather_tech_debt() {
  local slug="$1" branch="$2" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-tech-debt.sh" "$slug" "$branch" \
        2>"$cycle_dir/tech-debt-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/tech-debt-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the most recent weekly review's recommendations, for the Refiner
# only (requirement 3y; TD-PPagop-26081307) — never folded into
# `ordered_repos_json`, the Co-Ordinator's own input, which still reads
# `reviews/…` live (prompts/coordinator.md's "Project-review
# recommendations"). Called only for a repo whose `refinement_policy` for
# `project-review` is not exempt, the same "pay nothing unless it's wanted"
# rule tech_debt's own pre-fetch already follows for its `sources` gate.
gather_project_review_candidates() {
  local slug="$1" branch="$2" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-project-review.sh" "$slug" "$branch" \
        2>"$cycle_dir/project-review-candidates-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/project-review-candidates-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the open tasks in a repo's implementation-plan document, for the
# Refiner only (requirement 3y; TD-PPagop-26081307) — same "Refiner-only,
# never folded into ordered_repos_json" reasoning as
# gather_project_review_candidates above. Called only for a repo whose
# `refinement_policy` for `implementation-plan` is not exempt and that
# configures an `implementation_plan_path` — a repo with neither pays
# nothing here.
gather_implementation_plan_candidates() {
  local slug="$1" branch="$2" path="$3" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-implementation-plan.sh" "$slug" "$branch" "$path" \
        2>"$cycle_dir/implementation-plan-candidates-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/implementation-plan-candidates-$safe.json"
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
#
# PURPOSE names the asking pass — `blocked` (requirement 34i), `void`
# (requirement 34n) or `selected` (the pre-flight read) — and lands in the
# diagnostic filenames, because three passes can ask about the same repo in
# one cycle and a shared name means the last writer silently discards the
# other two's evidence.
gather_register_status() {
  local slug="$1" branch="$2" purpose="$3" out safe
  shift 3
  safe="$purpose-${slug//\//_}"
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
#
# PURPOSE, like gather_register_status's own, names the asking pass —
# `blocked` (requirement 34i) or `void` (requirement 34n's liveness
# retirement, TD-PPagop-26081303) — and lands in the diagnostic filenames, so
# the two passes this cycle can make against the same repo don't silently
# discard each other's evidence.
gather_review_status() {
  local slug="$1" branch="$2" purpose="$3" out safe
  shift 3
  safe="$purpose-${slug//\//_}"
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
# gather_register_status above, including PURPOSE.
gather_plan_status() {
  local slug="$1" branch="$2" path="$3" purpose="$4" out safe
  shift 4
  safe="$purpose-${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-plan-status.sh" "$slug" "$branch" "$path" "$@" \
        2>"$cycle_dir/plan-status-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/plan-status-$safe.json"
    printf '%s' "$out"
  else
    printf '{}'
  fi
}

# Which basename requirement 19's `failed-runs` item id names each workflow id
# (requirement 34n's liveness retirement, TD-PPagop-26081303) —
# scripts/gather-workflow-basenames.sh's own `{ok, basenames}`, called only
# for a repo with still-unretired `failed-run-` void entries: a fleet with
# none spends nothing here.
gather_workflow_basenames() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-workflow-basenames.sh" "$slug" \
        2>"$cycle_dir/workflow-basenames-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/workflow-basenames-$safe.json"
    printf '%s' "$out"
  else
    printf '{"ok":false,"basenames":{}}'
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
# The fenced-block fallback matches a closing ``` regardless of what info
# string the *opening* fence carried, or whether it carried one at all
# (issue #237): the state machine toggles solely on "is this a fence line",
# not on the literal text `json` following it. A verdict a model fences
# bare — ``` … ``` with no language tag — is not an ambiguous case; only a
# straight parse or a suffix match, not the fence's tag, was ever what told
# a verdict apart from prose. Before this, poetic-2's completed conflict
# resolution of PR #205 (2026-08-07T04:40Z) was discarded for exactly this
# reason — a bare fence the parser could not see — erasing pipeline memory
# that the conflict was fixed and triggering a three-node duplicate-work
# cascade on the same PR.
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

# A salvage resume is a single short turn — "state the verdict you already
# reached, nothing else" — so it earns none of the adaptive budgeting a real
# stage's own caps get from lib/stage-budget.sh (requirement 4e): a fixed,
# conservative bound is safer than one that could grow to a whole stage's own
# backstop over time. Five minutes is generous for a turn with no tool calls;
# the ninety-second watchdog catches a resume that never starts producing at
# all.
stage_salvage_backstop_sec=300
stage_salvage_inactivity_sec=90

# stage_salvage_result STAGE OUT_FILE MODEL CWD
# The bounded rescue of requirement 37's discard rule (issue #237): before an
# engagement whose final message failed extract_json_result is discarded
# whole, resume the exact session that produced it — not a fresh one, which
# would pay to re-derive work already done — with nothing but "return the
# verdict object". Prints the recovered JSON on stdout and returns 0 when
# that resume's own final message parses; returns 1 and prints nothing
# otherwise, including when the original run left no `session_id` to resume
# (a killed run's stream can end before the CLI's init event ever landed).
#
# Deliberately silent about *why* the first attempt failed — a timeout, a
# crash, an unparseable message are all the same fact from here: the session
# is worth one more ask before its work is written off. The caller decides
# what "worth trying" means for its own stage (an Enabler with a `rc != 0`
# has no living session to resume in the first place, since the process that
# would hold one is the one that never exited).
stage_salvage_result() {
  local stage="$1" out_file="$2" model="$3" cwd="$4"
  local session_id salvage_out salvage_rc salvage_result parsed
  # run_claude_stage sets its caller-visible globals for whichever run is
  # most recent; the original run's metering is already logged by the time
  # this is called, but detect_and_log_limit_hit is not — it reads
  # $stage_rate_limit_json at the call sites' own discretion, later, against
  # $out_file. Left alone, a salvage attempt would overwrite it with the
  # resume's own (almost always empty) limit info before that read happens.
  # Saving and restoring here keeps this function's globals side effect
  # entirely local, which is what every caller of it is entitled to assume.
  local saved_gaps="$stage_gaps_json" saved_kill="$stage_kill_reason" \
        saved_limit="$stage_rate_limit_json"
  session_id="$(jq -r '.session_id // empty' "$out_file" 2>/dev/null || true)"
  if [[ -z "$session_id" ]]; then
    stage_gaps_json="$saved_gaps"; stage_kill_reason="$saved_kill"; stage_rate_limit_json="$saved_limit"
    return 1
  fi
  salvage_out="${out_file%.out}.salvage.out"
  log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "attempted"}')"
  if run_claude_stage "$stage-salvage" "$stage_salvage_backstop_sec" "$model" \
       "Return only the verdict JSON object, nothing else." \
       "$salvage_out" "$cwd" "$stage_salvage_inactivity_sec" "$session_id"; then
    salvage_rc=0
  else
    salvage_rc=$?
  fi
  stage_gaps_json="$saved_gaps"; stage_kill_reason="$saved_kill"; stage_rate_limit_json="$saved_limit"
  if (( salvage_rc != 0 )); then
    log_event "salvage" "$(jq -nc --arg s "$stage" --argjson rc "$salvage_rc" \
      '{stage: $s, outcome: "failed", exit_code: $rc}')"
    return 1
  fi
  salvage_result="$(jq -r '.result // empty' "$salvage_out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$salvage_result" 2>/dev/null || true)"
  if [[ -z "$parsed" ]]; then
    log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "failed"}')"
    return 1
  fi
  log_event "salvage" "$(jq -nc --arg s "$stage" '{stage: $s, outcome: "recovered"}')"
  printf '%s' "$parsed"
  return 0
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
  # 124 is now both caps, and they are not the same news to whoever reads this
  # next — the Enabler, or a human asking why an item is blocked. "Ran to its
  # wall-clock cap while still working" argues for a longer cap; "produced
  # nothing at all for ten minutes" argues for looking at what it was waiting
  # on. So the reason is stated rather than left to be inferred from an exit
  # code that cannot carry it.
  if [[ "$rc" == "124" && "$stage_kill_reason" == "inactivity" ]]; then
    detail="$stage produced no output at all for its inactivity threshold and was stopped as wedged"
  elif [[ "$rc" == "124" && "$stage_kill_reason" == "rate-limit" ]]; then
    detail="$stage was stopped the moment the account reported a usage limit — nothing it did after that could have succeeded"
  elif [[ "$rc" == "124" ]]; then
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
    gh pr comment "$pr_url" --body "$(pipeline_comment_header script "$node_name")

The $(pipeline_actor_label "$stage") stopped on this PR: $detail. Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
}

# Requirement 3v (issue #321): one Co-Ordinator engagement, launched, parsed,
# and its own failure paths handled — factored out of the "4. Co-Ordinator
# stage" flow below so the corroboration retry can call it a second time
# without duplicating the launch/parse/salvage machinery. Sets
# `coord_attempt_result_json` to the parsed work order on success (empty on
# any failure — a launch failure, an unparseable final message even after
# salvage) and `coord_attempt_metering_json` to this attempt's own cost/time
# fields (lib/metering.sh) every time, success or failure, so a caller can
# report what the attempt cost regardless of its outcome. Returns 1 on any
# failure, after this attempt's own `attempt-failed`/`stage-end` logging and
# (for a launch failure) `handle_stage_failure`'s claim release — the same
# handling the single inline attempt used to do for itself, run here for
# either attempt.
#
# `extra` (default `{}`) is spliced into both `stage_budget_apply`'s own
# `stage-start` event and this attempt's `stage-end`/`attempt-failed` events,
# so the first (and by far the common) attempt is untouched — no argument,
# `{}` merges to nothing — while the retry tags every event it produces
# `{"retry": true}`, letting a reader (or requirement 3v's own corroboration
# events, below) tell which attempt paid for what without cross-referencing
# `stage-start` timestamps by hand.
run_coordinator_stage_attempt() {  # <attempt-out-file> <prompt> [extra-budget-json]
  local out_file="$1" prompt="$2" extra="${3:-{\}}" rc=0 watchdog_warning result
  jq -e 'type == "object"' <<<"$extra" >/dev/null 2>&1 || extra='{}'

  stage_budget_apply coordinator "*" "$coordinator_model" "$extra"
  if run_claude_stage coordinator "$(( stage_backstop_min * 60 ))" "$coordinator_model" "$prompt" "$out_file" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  coord_attempt_metering_json="$(metering_fields "$coordinator_model" "$out_file" "$stage_gaps_json")"
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" \
    --argjson m "$coord_attempt_metering_json" --argjson e "$extra" \
    '{stage: "coordinator", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m + $e')"
  # `if`, not `&&` — see the identical comment at the original call site below.
  watchdog_warning="$(stage_watchdog_warning coordinator || true)"
  if [[ -n "$watchdog_warning" ]]; then
    log_event "warning" "$watchdog_warning"
  fi
  (( ONCE )) && dump_stage_output "$out_file"

  if (( rc != 0 )); then
    handle_stage_failure "coordinator" "$rc" "$out_file" ""
    coord_attempt_result_json=""
    return 1
  fi

  result="$(jq -r '.result // empty' "$out_file" 2>/dev/null || true)"
  coord_attempt_result_json="$(extract_json_result "$result" 2>/dev/null || true)"
  if [[ -z "$coord_attempt_result_json" ]]; then
    coord_attempt_result_json="$(stage_salvage_result coordinator "$out_file" "$coordinator_model" "$cycle_dir" || true)"
  fi
  if [[ -z "$coord_attempt_result_json" ]]; then
    detect_and_log_limit_hit "$out_file" || true
    log_event "attempt-failed" "$(jq -nc --argjson e "$extra" \
      '{stage: "coordinator", detail: "unparseable final message"} + $e')"
    return 1
  fi
  return 0
}

# Requirement 3v (issue #321): the mechanical last resort once a `none-selected`
# verdict has failed corroboration twice in the same cycle (the original
# engagement and its one retry — see "5. Nothing selected" below). At that
# point liveness must stop depending on the model getting it right at all, so
# the Script itself picks: the highest-priority non-empty source band, its
# first item in repo order, with no per-item judgement applied.
#
# The band order approximates `prompts/coordinator.md`'s own "Selection
# algorithm" — the five cross-repo overrides (security, urgent issues,
# review-feedback, merge-conflicts, abandoned-drafts) ahead of the residual
# bands (human-visibility, high issues, tech-debt, medium issues, low issues,
# code-quality, register-hygiene) — restricted to the bands the Script has a
# pre-fetched array for. Approximates, not mirrors, in two respects a
# mechanical pick can afford: the walk is band-major across the whole fleet
# rather than the Co-Ordinator's repo-then-source walk. `failed-runs`,
# `implementation-plan` and
# `project-review` have no pre-fetched array — enumerating their candidates means a live `gh`
# read or a tree fetch the Co-Ordinator does for itself, which this mechanical
# fallback does not perform — so those three ranks are skipped rather than
# approximated. This is a known, deliberate narrowing: this path exists to
# keep the fleet selecting *something* once the model has twice failed to
# corroborate a `none-selected` against the bands requirement 3x's gate does
# check, so those three sitting
# unreached by fallback costs nothing on the failure mode this exists for —
# `eligible_items_json` is non-empty exactly when the gate can reject a
# verdict at all, and every band it counts has a rank below, so there is
# always something to fall to.
#
# It reads each repo's configured `sources` list as well as its pre-fetched
# arrays, and that is load-bearing rather than tidiness (requirement 3x): the
# arrays alone stopped being the authority on what a cycle may select once
# requirement 2.2a's back-pressure began narrowing the *list* while leaving
# `findings`, `register_hygiene` and `human_visibility` populated. Before 3x
# the point could not arise — back-pressure emptied `tech_debt`, so the
# tech-debt-only gate could never reject during a restricted cycle and this
# function was never reached — but a gate that now counts the finishing
# sources can, and a fallback blind to `sources` would answer it by starting
# fresh work through a full human gate. The one place the list is coarser
# than the array is `findings`, whose two kinds are separate source tokens
# (`security`, `code-quality`) and are matched as such here.
#
# The one band the gate counts that this walk can still decline is a
# superseded Dependabot merge-conflict entry: the prompt requires it in
# `voided` (so it is eligible, and owed an account) but it is not selectable
# work, so `mc_cands` skips it exactly as the prompt does. A cycle whose only
# unaccounted item is one of those reaches the empty-pick branch below, which
# stands down rather than assuming the guarantee.
#
# Each candidate is built straight from its own pre-fetched entry — the same
# fields the Co-Ordinator's own contract in `prompts/coordinator.md`'s
# "Output" section requires (`item`, `branch`/`pr_url`/`pr_number` for the
# four finishing sources, the Dependabot `takeover` shape for
# merge-conflicts) — with `context` a verbatim paste of the entry's own body
# text and `acceptance` a generic instruction naming the source's standard
# procedure, since there is no model here to compose a bespoke one.
# `model`/`model_reason` are supplied by the caller (ordinarily
# `implementor_model_default`) since a mechanical pick makes no model
# judgement to report — cheap to spot on the eventual Implementor work order,
# rather than silently reusing whatever the last attempt happened to prefer.
#
# `refinement_policy` (requirement 39a) binds this path exactly as it binds
# the Co-Ordinator, and for the same reason: a `"required"` source's unrefined
# item is not a lower-ranked candidate, it is one nobody has written a
# specification for yet, and handing it to an Implementor under a generic
# `acceptance` string is precisely the outcome that policy exists to prevent.
# A mechanical picker that ignored it could select what no Co-Ordinator
# engagement was allowed to. So an unrefined item from a `"required"` source
# is dropped here (`mk` yields nothing for it), and a `"preferred"` source's
# refined items are ranked ahead of its unrefined ones within their band —
# the same thumb on the scale `prompts/coordinator.md`'s "Per-source
# refinement policy" section describes, applied by a stable sort so the band's
# own order still decides everything else. `"exempt"` sources, which is every
# source an installation has not opted in, are unaffected.
#
# This costs the guarantee above nothing, band by band: `unaccounted_items`
# drops an eligible entry whose own source is `"required"` before it can ever
# make the gate reject, so a band that could send the cycle here is by
# construction a band this exclusion does not empty.
#
# Prints the single winning candidate object, or `null` if every reachable
# band was empty (never observed in practice, per the guarantee above, but
# handled rather than assumed).
fallback_select_candidate() {  # <ordered-repos-json> <default-model> <refinements-json> <refinement-policy-json>
  local repos="$1" model="$2" refinements="${3:-{\}}" policy="${4:-{\}}"
  jq -e 'type == "object"' <<<"$refinements" >/dev/null 2>&1 || refinements='{}'
  jq -e 'type == "object"' <<<"$policy" >/dev/null 2>&1 || policy='{}'
  jq -c --arg model "$model" --argjson refinements "$refinements" --argjson policy "$policy" \
    --arg model_reason "script-fallback: deterministic band-priority pick after two rejected corroboration verdicts; no model judgement applied" '
    def policy_of($src): (($policy // {})[$src] // "exempt");
    def is_refined($r; $item): ((($refinements // {})[$r] // {})[($item | tostring)] // null) != null;
    # Requirement 3x: the repo entry keeps its own `sources` list, and a band
    # this cycle narrowed away (back-pressure, or a repo that never listed the
    # source) is not a band a mechanical pick may reach into. Applied to the
    # repo, before its array is walked, so it costs one test per repo per band
    # rather than one per candidate.
    def lists($src): (((.sources // []) | index($src)) != null);
    # An issue is banded per entry (requirement 15e), so its rank token is
    # too: `issues` alone means every band, `issues:high` means only that one.
    def lists_issue_band($p): (lists("issues") or lists("issues:" + ($p | ascii_downcase)));

    # `_rank` is stripped from the winner below; it exists only to order the
    # band of a "preferred" source, and is 0 under every other policy so those
    # bands keep the order they are built in.
    def mk($r; $db; $src; $item; $title; $ctx; $acc; $extra):
      if policy_of($src) == "required" and (is_refined($r; $item) | not) then empty
      else
        {repo: $r, default_branch: $db, source: $src, item: $item, title: $title,
         model: $model, model_reason: $model_reason, context: $ctx, acceptance: $acc,
         _rank: (if policy_of($src) == "preferred" and (is_refined($r; $item) | not)
                 then 1 else 0 end)} + $extra
      end;

    def issue_ctx: "Issue #" + (.number | tostring) + ": " + (.title // "") + "\n\n"
      + (.body // "") + "\n\nComments:\n"
      + ([(.comments // [])[] | (.author // "") + " (" + (.created_at // "") + "):\n" + (.body // "")] | join("\n\n"));

    def sec_cands: [.[] | select(lists("security")) | .slug as $r | .default_branch as $db | (.findings // [])[] | select(.source == "security")
      | mk($r; $db; "security"; .ref; .title;
          ("Security finding (script-fallback selection).\nkind: " + (.kind // "") + "\nseverity: " + (.severity // "")
           + "\npackage: " + (.package // "") + "\nrule: " + (.rule // "") + "\nlocation: " + (.location // "")
           + "\nurl: " + (.url // "") + "\ntitle: " + (.title // ""));
          "Resolve the finding per its own record above, following this repo'"'"'s standard security-finding handling.";
          {})];

    def issue_band($p): [.[] | select(lists_issue_band($p)) | .slug as $r | .default_branch as $db | (.issues // [])[]
      | select((.priority // "Medium") == $p)
      | mk($r; $db; "issues"; ((.ref // (.number | tostring))); .title; issue_ctx;
          "Resolve per the current state of the issue thread above (body and every comment), not just the opening post.";
          {})];

    def rf_cands: [.[] | select(lists("review-feedback")) | .slug as $r | .default_branch as $db | (.review_feedback // [])[]
      | mk($r; $db; "review-feedback"; .ref; .title; (.body // "");
          "Address the review feedback above and push to the existing pull request.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number})];

    def mc_cands: [.[] | select(lists("merge-conflicts")) | .slug as $r | .default_branch as $db | (.merge_conflicts // [])[]
      | select((.superseded_by // null) == null)
      | select(((.bot // false) | not) or (.rebase_requested // false))
      | (((.bot // false) and (.rebase_requested // false)) as $takeover
         | mk($r; $db; "merge-conflicts"; .ref; .title; (.body // "");
             "Rebase the existing pull request onto its base and resolve the conflict.";
             ({pr_url: .pr_url, pr_number: .pr_number} + (if $takeover then {takeover: true} else {branch: .branch} end))))];

    def dq_cands: [.[] | select(lists("dequeued")) | .slug as $r | .default_branch as $db | (.dequeued // [])[]
      | mk($r; $db; "dequeued"; .ref; .title; (.body // "");
          "Diagnose and fix the merge-group checks failure that got this pull request dequeued, then push to the existing branch.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number, base: .base})];

    def ad_cands: [.[] | select(lists("abandoned-drafts")) | .slug as $r | .default_branch as $db | (.abandoned_drafts // [])[]
      | mk($r; $db; "abandoned-drafts"; .ref; .title; (.body // "");
          "Finish the existing draft pull request to the item'"'"'s own acceptance.";
          {branch: .branch, pr_url: .pr_url, pr_number: .pr_number})];

    def hv_cands: [.[] | select(lists("human-visibility")) | .slug as $r | .default_branch as $db | (.human_visibility // [])[]
      | mk($r; $db; "human-visibility"; .ref; ("human-visibility: " + .ref);
          ((.body // "") + "\n\nurl: " + (.url // ""));
          "Diagnose and fix the named human-visibility failure per its own record above; report blocked if the cause is outside this repository.";
          {})];

    def td_cands: [.[] | select(lists("tech-debt")) | .slug as $r | .default_branch as $db | (.tech_debt // [])[]
      | mk($r; $db; "tech-debt"; .ref; .title; (.body // "");
          "Resolve per the tech-debt record verbatim above; standard tech-debt closing procedure applies.";
          {})];

    def cq_cands: [.[] | select(lists("code-quality")) | .slug as $r | .default_branch as $db | (.findings // [])[] | select(.source == "code-quality")
      | mk($r; $db; "code-quality"; .ref; .title;
          ("Code-quality finding (script-fallback selection).\nkind: " + (.kind // "") + "\nrule: " + (.rule // "")
           + "\nlocation: " + (.location // "") + "\nurl: " + (.url // "") + "\ntitle: " + (.title // ""));
          "Resolve the finding per its own record above, following this repo'"'"'s standard code-quality handling.";
          {})];

    def rh_cands: [.[] | select(lists("register-hygiene")) | .slug as $r | .default_branch as $db | (.register_hygiene // [])[]
      | mk($r; $db; "register-hygiene"; .ref; ("register-hygiene: " + .ref);
          ((.body // "") + "\n\nurl: " + (.url // "") + "\nblob_sha: " + (.blob_sha // "")
           + "\nproblems: " + ((.problems // []) | join("; ")));
          "Repair only the flagged register inconsistencies per TECH-DEBT.md'"'"'s claiming/filing discipline; touch nothing else.";
          {})];

    [ sec_cands, issue_band("Urgent"), rf_cands, mc_cands, dq_cands, ad_cands, hv_cands,
      issue_band("High"), td_cands, issue_band("Medium"), issue_band("Low"), cq_cands, rh_cands ]
    | map(select(length > 0))
    | if length > 0 then (.[0] | sort_by(._rank) | .[0] | del(._rank)) else null end
  ' <<<"$repos"
}

# Requirement 3v (issue #321): the Co-Ordinator's own `selected: false`
# verdict, corroborated, retried, and — as a last resort — mechanically
# resolved, all in one call. Called only when the first attempt's own
# `work_order_json` reports `selected != true` (the caller's "5. Nothing
# selected" guard); reads and writes that same global, along with `selected`,
# `reason`, `candidates_json` and `selected_by_fallback`, exactly the way the
# top-level flow that used to hold this logic inline did — factored out
# purely so it can `return` instead of `exit`, which is what makes it
# testable (`extract_fn`-and-`eval`, the technique `maybe_run_enabler` already
# established) and what lets its caller decide whether standing down means
# ending the process or falling through to "5b. Candidates, and the claim"
# with a work order now ready to claim.
#
# Returns 0 when `work_order_json`/`candidates_json` are ready for 5b (a
# retry that selected, or a fallback pick); returns 1 when the caller should
# `exit 0` immediately — every event this needs logged (`none-selected`,
# `warning`, `corroboration`, and any failed-attempt handling
# `run_coordinator_stage_attempt` already did for a launch failure) has
# already been written by the time it returns 1.
coordinator_corroborate_retry_or_fallback() {
  reason="$(jq -r '.reason // "no reason given"' <<<"$work_order_json")"

  # --- 5a. Verdict corroboration (requirements 3t/3x, issues #310, #322) ---
  # See unaccounted_items' own comment above for the rule, and
  # coordinator_eligible_items' for what "eligible" means per band; only worth
  # computing at all when the Script found something eligible to check the
  # verdict against. Fed the recording loops' own collections (steps above),
  # never $work_order_json's arrays verbatim: the account is what the Script
  # put on the record, not what the message claimed to.
  unaccounted_json="[]"
  if (( eligible_items_total > 0 )); then
    # $nr/$v are the recording loops' own collections and grow with the
    # cycle's whole needs_refinement/voided bands — unbounded past this call,
    # never argv (requirement 4g, TD-PPagop-26081406): both arrive on stdin,
    # bound positionally with `input as $name` in the order printed.
    unaccounted_json="$(unaccounted_items \
      "$(jq -nc 'input as $nr | input as $v | {needs_refinement: $nr, voided: $v}' \
          <<<"${coord_recorded_refinement_json:-[]}"$'\n'"${coord_recorded_voided_json:-[]}")" \
      "$eligible_items_json" "$refinement_policy_json")"
  fi
  unaccounted_n="$(jq 'length' <<<"$unaccounted_json" 2>&1)" \
    || { guard_warn "unaccounted_n" "$unaccounted_n"; unaccounted_n=0; }
  # Requirement 3x's band tag: the same rejection, split by the band it was
  # rejected over, so a fleet reading requirement 3w's rate can tell "the
  # model keeps confabulating the issues band away" from "it keeps forgetting
  # to void superseded Dependabot conflicts" without re-deriving either from
  # the `unaccounted` refs. One `corroboration` per verdict still, never one
  # per band: the rate's unit is the verdict (requirement 3w), and a
  # per-band event would inflate its denominator by however many bands a
  # cycle happened to have work in.
  unaccounted_bands_json="$(jq -c 'group_by(.source)
    | map({key: (.[0].source // ""), value: length}) | from_entries' \
    <<<"$unaccounted_json" 2>&1)" \
    || { guard_warn "unaccounted_bands_json" "$unaccounted_bands_json"; unaccounted_bands_json='{}'; }

  # Requirement 3w (issue #319): what every verdict this cycle records owes
  # the rate. Requirement 3v's `corroboration` events already carry the
  # Script's own `eligible_total`, which is the denominator; what neither they
  # nor `none-selected` carried is *which model produced the verdict*, and
  # without that the fleet cannot tell a rate that would justify changing
  # `coordinator_model` from one that would not. The only other record of this
  # cycle's Co-Ordinator model is its `stage-end` metering — a per-verdict
  # join for any reader — or its transcript, which is retained on an entirely
  # different schedule from the log.
  #
  # `coordinator_model` is the id the stage was *invoked* with, not a key of
  # the envelope's `modelUsage` map, for the reason lib/metering.sh gives for
  # making the same choice: the invocation id is the thing an operator sets
  # and the thing `stage-end` already records, while `modelUsage` names
  # whatever the session actually reached for — including a subagent's model —
  # so keying on it would split one setting's rate across several labels and
  # disagree with every other record of the same run. Both attempts run under
  # the same id (`run_coordinator_stage_attempt` above), so the retry's own
  # verdict is attributed to the same model that produced the first.
  coord_model_json="$(jq -nc --arg m "$coordinator_model" '{coordinator_model: $m}')"

  # The fingerprint recorded here is the one taken *before* the Co-Ordinator
  # ran, which is the only correct choice. Anything that changed while it was
  # working is, by definition, something it may not have seen — so it must be
  # allowed to change the fingerprint and buy the next cycle a fresh look. A
  # fingerprint taken now would absorb that change and skip on it.
  #
  # An empty fingerprint is omitted, not stored: the next cycle must find no
  # fingerprint here rather than an empty one it might match against an equally
  # empty sample of its own (see gather-source-state.sh). A verdict this cycle
  # found to contradict the Script's own eligible count, in any band, is
  # omitted the same way and for the same reason a failed sample is unfingerprintable
  # (requirement 3b's "a sample that failed is not a sample"): a wrong
  # `none-selected` cemented into the fingerprint would freeze the fleet on
  # that wrong answer until `none_selected_recheck_hours` forced a recheck —
  # which is exactly what held the whole fleet down for a full day on
  # 2026-08-11. Rejecting the fingerprint here instead means the very next
  # cycle asks again, unconditionally.
  if (( unaccounted_n == 0 )); then
    if (( eligible_items_total > 0 )); then
      log_event "corroboration" "$(jq -nc --argjson a 1 --arg v "accepted" --argjson total "$eligible_items_total" \
        --argjson m "$coord_model_json" '{attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: 0} + $m')"
    fi
    # `eligible_total` rides the `none-selected` too, and on every branch
    # below (requirement 3w): a cycle whose bands were genuinely empty logs no
    # `corroboration` at all, so without the figure here a reader cannot tell
    # "nothing was eligible" — which is a clean verdict with no rate to be
    # part of — from an event written before any of this existed.
    log_event "none-selected" "$(jq -nc --arg r "$reason" --arg f "$noop_fingerprint_value" \
      --argjson total "$eligible_items_total" --argjson m "$coord_model_json" \
      '{reason: $r} + (if $f == "" then {} else {fingerprint: $f} end) + {eligible_total: $total} + $m')"
    return 1
  fi

  # requirement 4g (TD-PPagop-26081401): $unaccounted_json is the unaccounted
  # eligible items carried whole out of the pre-fetched bands, unbounded past
  # this jq call, so it arrives on stdin — the only unbounded value at each
  # call site, everything else (n, total, bands, reason, model fields) stays
  # bounded by configuration and travels as --arg/--argjson as before.
  log_event "warning" "$(jq -nc --argjson n "$unaccounted_n" --argjson total "$eligible_items_total" \
    --argjson bands "$unaccounted_bands_json" --arg r "$reason" \
    'input as $items | {detail: ("verdict contradiction: the Script found " + ($total | tostring)
               + " eligible item(s) across the pre-fetched bands (unclaimed, unblocked, not void), but "
               + ($n | tostring)
               + " of them — " + (($bands | to_entries | map(.key + " " + (.value | tostring)) | join(", ")))
               + " — were neither selected, covered by a needs_refinement report the Script"
               + " recorded under that item'"'"'s own source, nor by a voided entry it disposed of this cycle"
               + " — the Co-Ordinator'"'"'s stated reason (\"" + $r + "\") does not account for them"),
      eligible_total: $total, bands: $bands, unaccounted: $items}' <<<"$unaccounted_json")"
  log_event "corroboration" "$(jq -nc --argjson a 1 --arg v "rejected" --argjson total "$eligible_items_total" \
    --argjson n "$unaccounted_n" --arg r "$reason" \
    --argjson bands "$unaccounted_bands_json" --argjson m "$coord_model_json" \
    'input as $items | {attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: $n, bands: $bands, unaccounted: $items, reason: $r} + $m' <<<"$unaccounted_json")"

  # --- 5a-retry. One re-prompt, quoting the contradiction (requirement 3v, issue #321) ---
  # A confabulated `none-selected` costs the Script nothing to detect (above),
  # but until now it still cost the whole cycle: the fingerprint stays
  # unarmed (so the *next* cycle asks again unconditionally — #314's fix for
  # #310's day-long freeze), but this cycle itself still stood down. If the
  # model's confabulation is persistent rather than a one-off — #310 showed
  # the same wrong verdict recurring across cycles and nodes — the fleet
  # degrades into a warning-per-cycle loop with zero selections: visible on
  # the log, but liveness still depends entirely on the model eventually
  # getting it right. This retry, and the fallback selection below when it
  # too fails corroboration, are what stop that dependency: a rejected
  # verdict now costs at most one extra Co-Ordinator engagement, never the
  # cycle.
  #
  # Same model, same base prompt, plus an addendum stating the Script's own
  # arithmetic and naming exactly which eligible items the first verdict left
  # unaccounted — the contradiction itself, not a generic "try again", on the
  # theory that the failure mode is pattern-matching against a band
  # description rather than reading it, and a pointed, specific contradiction
  # is what breaks that pattern. One retry only: the retry's own verdict,
  # corroborated or not, is never itself retried.
  coord_recorded_refinement_json_1="${coord_recorded_refinement_json:-[]}"
  coord_recorded_voided_json_1="${coord_recorded_voided_json:-[]}"
  # Grouped by band, and each ref given with its repo and its source token,
  # because the addendum's whole theory is specificity: the retry has to know
  # which array a given ref belongs to before it can issue a per-item verdict
  # for it, and `needs_refinement` is only an account when its `source`
  # matches the band the item was eligible in (unaccounted_items above).
  unaccounted_refs="$(jq -r 'group_by(.source)
    | map("- `" + (.[0].source // "") + "`: "
          + ([.[] | ((.repo // "") + " " + (.item // ""))] | join(", ")))
    | join("\n")' <<<"$unaccounted_json" 2>/dev/null || printf '(unavailable)')" # TD-PPagop-26081407: passes test 2 -- "(unavailable)" is not English text a real band summary could ever produce, so a reader can never mistake it for content
  coordinator_retry_prompt="$coordinator_prompt

## Corroboration retry — your previous verdict this cycle was rejected

Your final message a moment ago in this same cycle reported \`\"selected\": false\`
with reason: \"$reason\"

The Script independently counts $eligible_items_total eligible item(s) across
the bands it pre-fetched for you this cycle (unclaimed, unblocked, not void,
and listed in that repo's own \`sources\`). Your verdict accounted for only
$(( eligible_items_total - unaccounted_n )) of them, via \`needs_refinement\`
(under the item's own \`source\`) or \`voided\`. The remaining $unaccounted_n
item(s) were neither selected, reported, nor voided, and are still unaccounted
for, by band:

$unaccounted_refs

This is your one retry for this cycle. Issue a per-item verdict for every item
named above — add it to \`needs_refinement\` (with all five required fields, and
\`source\` set to the band it is listed under above) or to \`voided\` (with
\`evidence\`) — or select one of them, or any other eligible candidate, in
\`candidates\`. Send your entire final message exactly as before: one JSON
object, nothing else.
"
  coordinator_retry_out="$cycle_dir/coordinator-retry.out"
  if ! run_coordinator_stage_attempt "$coordinator_retry_out" "$coordinator_retry_prompt" '{"retry": true}'; then
    # The retry engagement itself failed to launch or never produced a
    # parseable message — run_coordinator_stage_attempt already logged
    # attempt-failed/handle_stage_failure for it. That is a different failure
    # mode from a rendered-but-uncorroborated verdict (network, rate limit, a
    # wedged session), so it does not reach fallback selection below — the
    # ordinary attempt-failed handling already in place is this cycle's
    # answer, same as it would be for the first attempt.
    return 1
  fi
  retry_work_order_json="$coord_attempt_result_json"
  retry_metering_json="$coord_attempt_metering_json"

  log_unblocked_items "$retry_work_order_json"
  log_recheck_clean_items "$retry_work_order_json"
  # Restricted to exactly the items the retry addendum named unaccounted: the
  # retry received the full runtime input again, so a `needs_refinement`/
  # `voided` entry it repeats for something the first attempt already
  # accounted for is not new information, and processing it again would
  # double the void-guard check, the refinement label, and any GitHub comment
  # either one posts. An item outside `unaccounted_json` was never asked
  # about, so an entry naming one is dropped the same way. Matched on the ref
  # alone, not on repo+item+source as the corroboration itself is: this filter
  # decides what gets *processed*, and a report the retry mis-attributes to
  # the wrong source is still a report about an item the addendum asked about
  # — recording it is right even though it will not account for anything.
  # requirement 4g (TD-PPagop-26081401): $unaccounted_json is the same
  # unbounded aggregate site 3's log_event calls above deliver on stdin — a
  # fifth consumer in this same function, previously still riding in as an
  # --argjson. Unguarded, so past MAX_ARG_STRLEN this used to die the whole
  # cycle under set -e rather than degrade. On a jq failure here, falling
  # back to the unfiltered retry_work_order_json costs at most some
  # redundant void-guard/refinement-label processing for an item attempt 1
  # already accounted for — never the silent loss a fallback to "nothing
  # filtered" would risk.
  retry_filter_docs="$(printf '%s\n' "$retry_work_order_json" "$unaccounted_json")"
  retry_work_order_filtered_json="$(jq -nc '
    input as $wo | input as $unaccounted
    | ($unaccounted | map(.item | tostring)) as $u
    | $wo + {
        needs_refinement: (($wo.needs_refinement // []) | map(select((.item | tostring) as $i | $u | index($i) != null))),
        voided: (($wo.voided // []) | map(select((.item | tostring) as $i | $u | index($i) != null)))
      }
    ' <<<"$retry_filter_docs" 2>/dev/null || printf '%s' "$retry_work_order_json")" # TD-PPagop-26081407: passes test 2 -- falls back to the unfiltered work order, a value the caller already accepted, not a fabricated empty
  log_voided_items "$retry_work_order_filtered_json" "$ordered_repos_json"
  log_needs_refinement_items "$retry_work_order_filtered_json"

  retry_selected="$(jq -r '.selected' <<<"$retry_work_order_json")"
  retry_reason="$(jq -r '.reason // "no reason given"' <<<"$retry_work_order_json")"
  # Both grow with the cycle's whole recorded band across both attempts —
  # unbounded past this call, never argv (requirement 4g, TD-PPagop-26081406):
  # each pair arrives on stdin, bound positionally with `input as $name` in
  # the order printed.
  recorded_refinement_all_json="$(jq -nc 'input as $a | input as $b | $a + $b' \
    <<<"$coord_recorded_refinement_json_1"$'\n'"${coord_recorded_refinement_json:-[]}")"
  recorded_voided_all_json="$(jq -nc 'input as $a | input as $b | $a + $b' \
    <<<"$coord_recorded_voided_json_1"$'\n'"${coord_recorded_voided_json:-[]}")"

  if [[ "$retry_selected" == "true" ]]; then
    # `eligible_total` here too (requirement 3w): this verdict is one the
    # retry got right, and a denominator that counted only the verdicts still
    # phrased as `none-selected` would credit the recovery to nobody and
    # overstate every model that ever recovers this way.
    log_event "corroboration" "$(jq -nc --argjson a 2 --arg v "accepted-by-selection" --argjson m "$retry_metering_json" \
      --argjson total "$eligible_items_total" --argjson cm "$coord_model_json" \
      '{attempt: $a, verdict: $v, eligible_total: $total} + $m + $cm')"
    # The retry's own work order — an ordinary model selection, no different
    # from one the first attempt could have made — is what the caller feeds
    # "5b. Candidates, and the claim" once this returns 0.
    work_order_json="$retry_work_order_json"
    selected="true"
    return 0
  fi

  # $nr/$v are the same unbounded recorded-band aggregates as the first
  # attempt's build above — stdin, never argv (requirement 4g,
  # TD-PPagop-26081406).
  unaccounted_retry_json="$(unaccounted_items \
    "$(jq -nc 'input as $nr | input as $v | {needs_refinement: $nr, voided: $v}' \
        <<<"$recorded_refinement_all_json"$'\n'"$recorded_voided_all_json")" \
    "$eligible_items_json" "$refinement_policy_json")"
  unaccounted_retry_n="$(jq 'length' <<<"$unaccounted_retry_json" 2>&1)" \
    || { guard_warn "unaccounted_retry_n" "$unaccounted_retry_n"; unaccounted_retry_n=0; }
  unaccounted_retry_bands_json="$(jq -c 'group_by(.source)
    | map({key: (.[0].source // ""), value: length}) | from_entries' \
    <<<"$unaccounted_retry_json" 2>&1)" \
    || { guard_warn "unaccounted_retry_bands_json" "$unaccounted_retry_bands_json"; unaccounted_retry_bands_json='{}'; }

  if (( unaccounted_retry_n == 0 )); then
    log_event "corroboration" "$(jq -nc --argjson a 2 --arg v "accepted" --argjson total "$eligible_items_total" \
      --argjson m "$retry_metering_json" --argjson cm "$coord_model_json" \
      '{attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: 0} + $m + $cm')"
    log_event "none-selected" "$(jq -nc --arg r "$retry_reason" --arg f "$noop_fingerprint_value" \
      --argjson total "$eligible_items_total" --argjson m "$coord_model_json" \
      '{reason: $r} + (if $f == "" then {} else {fingerprint: $f} end) + {eligible_total: $total} + $m')"
    return 1
  fi

  # requirement 4g (TD-PPagop-26081401): $unaccounted_retry_json is the same
  # shape as $unaccounted_json above, and just as unbounded, so it too
  # arrives on stdin rather than as an --argjson.
  log_event "warning" "$(jq -nc --argjson n "$unaccounted_retry_n" --argjson total "$eligible_items_total" \
    --argjson bands "$unaccounted_retry_bands_json" --arg r "$retry_reason" \
    'input as $items | {detail: ("verdict contradiction (retry): the Script found " + ($total | tostring)
               + " eligible item(s) across the pre-fetched bands, but " + ($n | tostring)
               + " — " + (($bands | to_entries | map(.key + " " + (.value | tostring)) | join(", ")))
               + " — remain unaccounted for after the one retry this cycle allows"
               + " — the Co-Ordinator'"'"'s retried reason (\"" + $r + "\") does not account for them"),
      eligible_total: $total, bands: $bands, unaccounted: $items}' <<<"$unaccounted_retry_json")"
  log_event "corroboration" "$(jq -nc --argjson a 2 --arg v "rejected" --argjson total "$eligible_items_total" \
    --argjson n "$unaccounted_retry_n" --arg r "$retry_reason" \
    --argjson bands "$unaccounted_retry_bands_json" \
    --argjson m "$retry_metering_json" --argjson cm "$coord_model_json" \
    'input as $items | {attempt: $a, verdict: $v, eligible_total: $total, unaccounted_total: $n, bands: $bands, unaccounted: $items, reason: $r} + $m + $cm' <<<"$unaccounted_retry_json")"

  # --- 5a-fallback. Deterministic selection (requirement 3v, issue #321) ---
  # Both engagements this cycle failed to corroborate a `none-selected`
  # against bands the Script itself can already see are
  # non-empty (`eligible_items_total > 0` is what let the gate reject a
  # verdict at all). Liveness now stops depending on the model: the Script
  # picks mechanically, through the same create-only claim race any
  # model-ranked candidate goes through (requirement 17a, in the caller) — a
  # possibly-suboptimal pick is strictly better than a frozen fleet.
  #
  # The twice-rejected verdict is fully on the record by this point — two
  # `warning`s and two `corroboration` events, the second carrying the
  # retry's own `reason` — so it is deliberately *not* also written as a
  # `none-selected` before the pick is attempted. `none-selected` names a
  # cycle's outcome, not a verdict: every other reader treats it that way,
  # from requirement 3b's fingerprint to the dashboard's own outcome ladder
  # (`scripts/publish-dashboard.sh`, where it outranks both `selection` and
  # `stand-down`), so a cycle that logged one *and* went on to select would
  # render as "Nothing selected" — reporting the recovery as the failure it
  # recovered from, and undercounting fallback picks for issue #319's
  # metrics. It is logged below instead, on the one branch where the cycle
  # really does select nothing.
  fallback_candidate_json="$(fallback_select_candidate "$ordered_repos_json" \
    "$implementor_model_default" "$refinements_json" "$refinement_policy_json")"
  if [[ -z "$fallback_candidate_json" || "$fallback_candidate_json" == "null" ]]; then
    # Not observed in practice (see fallback_select_candidate's own comment
    # for the guarantee this would defy), but fail closed rather than assume
    # it away: nothing to claim, so stand down exactly as an ordinary
    # corroboration rejection would — including requirement 3t's un-armed
    # fingerprint, which a rejected verdict is denied however the cycle ends.
    # `td_verdict_rejected` keeps its name though the gate is no longer
    # tech-debt-only (requirement 3x): it is what every reader of this event
    # already keys on — `scripts/publish-dashboard.sh`'s verdict-quality
    # aggregate, and every such event already in the retained log — and a
    # rename would silently zero the rejection count for the history it can
    # still see. `bands` carries what the name no longer says.
    log_event "none-selected" "$(jq -nc --arg r "$retry_reason" \
      --argjson total "$eligible_items_total" --argjson bands "$unaccounted_retry_bands_json" \
      --argjson m "$coord_model_json" \
      '{reason: $r, td_verdict_rejected: true, retried: true, eligible_total: $total, bands: $bands} + $m')"
    return 1
  fi
  candidates_json="$(jq -c '[.]' <<<"$fallback_candidate_json")"
  selected_by_fallback=1
  selected="true"
  work_order_json="$fallback_candidate_json"
  return 0
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
# The Refiner's own state (requirement 39), same reasoning and same guard.
refiner_allowed=0
refiner_candidates_json='[]'
limit_hit_this_cycle=0

# --- Cleanup (always runs on exit) ---
lock_acquired=0
clone_dir=""
# Finish-then-continue (requirement 39): set true only once this cycle has
# won a claim and is about to run the Implementor. Initialised here, ahead
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

# `run_claude_stage` — the stage launcher, its wall-clock cap and its
# process-group kill — lives in lib/stage-run.sh, sourced at the top of this
# script alongside every other shared rule. It is shared with review-cycle.sh
# rather than copied into it (requirement 4d).

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
  epoch="$(date -d "$ts" +%s 2>&1)" || { guard_warn "blocked-item-epoch" "$epoch"; epoch=0; }
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
  # Only on the path that actually creates: an escalation repo is often not one
  # the cycle otherwise touches (`crash_loop_repo` by construction is not), so
  # its label has nowhere else to be ensured. Costs nothing on the duplicate
  # path above, which is the common one. The retry-without-label below stays
  # regardless — this makes the label likely, not certain, and an escalation
  # must be raised either way.
  labels_ensure_role "$CONFIG_FILE" "$SCHEMA_FILE" "$repo" escalation >/dev/null 2>&1 || true
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

# crash_loop_escalate VERDICT_JSON ITEM_REF KIND_LABEL TITLE_PREFIX EVIDENCE_LINE
# Shared by both requirement-2.7 crash-loop classes: same dedup
# (`crash_loop_escalated_since`), same label, same load-bearing assignee, same
# `crash-loop-escalated` event shape — only the wording, the item ref that
# keys `create_escalation_issue`'s open-issue dedup, and where a human should
# start reading differ between them. KIND_LABEL is the plural noun phrase for
# "N consecutive KIND_LABEL"; EVIDENCE_LINE is a prose line naming what to
# read first.
crash_loop_escalate() {
  local verdict_json="$1" item_ref="$2" kind_label="$3" title_prefix="$4" evidence_line="$5"
  local cl_detail cl_first_ts cl_body cl_created
  cl_detail="$(jq -r '.detail // ""' <<<"$verdict_json")"
  cl_first_ts="$(jq -r '.first_ts // ""' <<<"$verdict_json")"
  if crash_loop_escalated_since "$cl_first_ts" "$cl_detail" < "$union_log"; then
    return 0
  fi
  cl_body="$cycle_dir/crash-loop-issue-${item_ref#crash-loop:}.md"
  {
    printf '## What the fleet log shows\n\n'
    jq -r --arg k "$kind_label" \
      '"- **\(.count) consecutive \($k)**, every one `\(.detail)`\n- first at `\(.first_ts)`, still failing at `\(.last_ts)`\n- nodes affected: \(.nodes | join(", "))"' \
      <<<"$verdict_json"
    cat <<CRASH_LOOP_BODY

No recovery — a success, or (for a pre-selection death) a cycle reaching a
selection stage — has happened anywhere in the fleet since the first of these.
A failure this uniform is almost certainly deterministic — something that
ships in the image or the config, not a transient — so no amount of retrying
will clear it, and until it clears the fleet selects no work at all.

$evidence_line

---
Filed automatically by agent-cycle.sh (requirement 2.7).
ref: $item_ref
CRASH_LOOP_BODY
  } > "$cl_body"
  if cl_created="$(create_escalation_issue "$crash_loop_repo" "$item_ref" \
        "$enabler_escalation_label" \
        "$title_prefix ($cl_detail)" \
        "$cl_body")" && [[ -n "$cl_created" ]]; then
    log_event "crash-loop-escalated" "$(jq -c \
      --argjson n "${cl_created%%$'\t'*}" --arg u "${cl_created#*$'\t'}" \
      '. + {issue_number: $n, issue_url: $u}' <<<"$verdict_json")"
  else
    log_event "warning" "$(jq -nc --arg d "crash loop detected ($cl_detail) but the escalation issue could not be filed — will retry next cycle" '{detail: $d}')"
  fi
}

# maybe_run_enabler CYCLE_EXIT_CODE
# Engage the Enabler if this cycle should, and translate its verdicts into log
# events and issues. Always returns without disturbing the cycle's outcome.
maybe_run_enabler() {
  local cycle_rc="${1:-1}"
  local claimed_json='[]' engagement_json='[]' n_eligible=0 n_claimed=0 n_out=0 i j
  local entry repo item key live_resume live_epoch input prompt out rc=0 result parsed detail
  local items_named_json
  local ex e_repo e_item verdict e_reason claimed_entry blocked_ts outcome extra e_evidence_field
  local e_void_entry e_void_refusal
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
  [[ -f "$PROMPTS_DIR/enabler.md" ]] || return 0

  # Requirement 35d: the refinement class is capped per engagement, ordinary
  # blocked items are not. Applied before the claims, so a capped-out item is
  # left unclaimed and waits — a claim taken and not examined would be a
  # tombstone standing for `claim_ttl_hours` over an item nobody looked at.
  engagement_json="$(refinement_engagement_set "$enabler_eligible_json" "$refinement_max_per_engagement")"
  n_eligible="$(jq 'length' <<<"$engagement_json" 2>&1)" \
    || { guard_warn "enabler:n_eligible" "$n_eligible"; n_eligible=0; }
  [[ "$n_eligible" =~ ^[0-9]+$ ]] || n_eligible=0
  (( n_eligible > 0 )) || return 0

  # The fleet limit file, read live rather than from the union snapshot taken at
  # the start of the cycle (requirement 2.1's second carrier): a limit a peer hit
  # while this cycle was working is exactly the news that should stop the most
  # expensive stage in the system from starting.
  live_resume="$(fleet_limit_resume_at "$state_repo" "$state_dir" 2>/dev/null || true)"
  if [[ -n "$live_resume" ]]; then
    live_epoch="$(date -d "$live_resume" +%s 2>&1)" \
      || { guard_warn "live_epoch" "$live_epoch"; live_epoch=0; }
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
      # requirement 4g (TD-PPagop-26081401): $claimed_json grows by one
      # blocked entry, evidence payload included, per Enabler claim this
      # cycle — unbounded past this call, so $entry joins it on stdin
      # rather than riding in as a second --argjson.
      # TD-PPagop-26081407: passes test 1 -- $claimed_json and $entry are
      # concatenated in-memory immediately above; the trivial append script
      # cannot fail independently of the concatenation itself.
      claimed_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
        <<<"$claimed_json"$'\n'"$entry" 2>/dev/null || printf '%s' "$claimed_json")"
    fi
  done
  n_claimed="$(jq 'length' <<<"$claimed_json" 2>&1)" \
    || { guard_warn "n_claimed" "$n_claimed"; n_claimed=0; }
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
  # The claimed items arrive on stdin, bound with `input as $items`
  # (requirement 4g) — never in argv. Only the refinement class is capped per
  # engagement (see the claim loop above); ordinary blocked items are not, and
  # each carries its block's evidence payload, so past MAX_ARG_STRLEN this
  # build would fail into the guard below and skip the engagement silently —
  # disabling the very stage that retires blocked state.
  input="$(jq -nc --arg lbl "$enabler_escalation_label" \
    --arg assignee "$enabler_assignee" --arg cycle "$cycle_id" --arg node "$node_name" \
    'input as $items
     | {items: $items, escalation_label: $lbl, assignee: $assignee, cycle: $cycle, node: $node}' \
    <<<"$claimed_json" 2>/dev/null || true)"
  [[ -n "$input" ]] || return 0

  prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" enabler "$prompt_overrides_json")

## Runtime input for this engagement

\`\`\`json
$(jq . <<<"$input")
\`\`\`
"
  out="$cycle_dir/enabler.out"
  # The Enabler spans repositories by construction, so its cell is keyed `*`
  # (requirement 4f) — there is no repository this engagement belongs to.
  stage_budget_apply enabler "*" "$enabler_model"
  if run_claude_stage enabler "$(( stage_backstop_min * 60 ))" "$enabler_model" "$prompt" "$out" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$enabler_model" "$out" "$stage_gaps_json")" \
    '{stage: "enabler", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
  # `if`, not `&&`: an empty warning is the common case, and a trailing
  # `&&` whose test fails is a non-zero status at exactly the place
  # `set -e` acts on — the same trap that cost a --once cycle its
  # failure handling at dump_stage_output.
  watchdog_warning="$(stage_watchdog_warning enabler || true)"
  if [[ -n "$watchdog_warning" ]]; then
    log_event "warning" "$watchdog_warning"
  fi
  (( ONCE )) && dump_stage_output "$out"

  result="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$result" 2>/dev/null || true)"
  # A process that exited cleanly but left an unparseable final message has a
  # living session behind it worth one more ask (issue #237); a timeout or a
  # non-zero exit does not, since nothing held the session open to resume.
  if (( rc == 0 )) && [[ -z "$parsed" ]]; then
    parsed="$(stage_salvage_result enabler "$out" "$enabler_model" "$cycle_dir" || true)"
  fi
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
    items_named_json="$(jq -c '[.[] | {repo: (.repo // ""), item: (.item // "")}]' <<<"$claimed_json" 2>&1)" \
      || { guard_warn "items_named_json" "$items_named_json"; items_named_json='[]'; }
    # requirement 4g (TD-PPagop-26081401): trimmed to {repo, item} per entry,
    # the most bounded aggregate on TD-PPagop-26081401's list, but it still
    # grows with the number of items this engagement claimed, so it arrives
    # on stdin rather than as a second --argjson.
    log_event "warning" "$(jq -nc --arg d "$detail — no verdicts recorded; the claims stand until gc lets a later cycle retry" \
      'input as $items | {detail: $d, items: $items}' <<<"$items_named_json")"
    # The tombstone (requirement 35c) stays a tombstone — releasing it outright
    # would let the next cycle re-engage the same still-unchanged items at
    # Opus prices with nothing new to show for it. Backdating each entry's
    # `ts` past `claim_ttl_hours` is the middle ground requirement 37 asks
    # for: `lib/claim.sh gc` retires it on its very next sweep — this cycle's
    # own 2.1a, an hour away rather than up to `claim_ttl_hours` — instead of
    # leaving a lost engagement's items frozen for the tombstone's full life.
    for (( i = 0; i < n_claimed; i++ )); do
      entry="$(jq -c --argjson i "$i" '.[$i]' <<<"$claimed_json" 2>/dev/null || true)"
      [[ -n "$entry" ]] || continue
      key="$(enabler_claim_key "$entry")"
      [[ -n "$key" ]] || continue
      "$SCRIPT_DIR/lib/claim.sh" expire enabler "$key" >>"$cycle_dir/claim.log" 2>&1 || true
    done
    return 0
  fi

  # --- Verdicts (requirement 36a) ---
  n_out="$(jq '(.examined // []) | length' <<<"$parsed" 2>&1)" \
    || { guard_warn "n_out" "$n_out"; n_out=0; }
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

                # Requirement 38, same as the Reviewer's own handoff site
                # above — this path exists precisely so the two cannot drift.
                e_human_reviewer_state=""
                e_human_reviewer_who=""
                if [[ "$e_rereview_state" == "none" && -n "$enabler_assignee" ]]; then
                  e_human_reviewer_result="$(ensure_human_reviewer "$e_pr_url" "$enabler_assignee")" || true
                  IFS=$'\t' read -r e_human_reviewer_state e_human_reviewer_who <<<"$e_human_reviewer_result" || true
                  if [[ "$e_human_reviewer_state" == "failed" ]]; then
                    log_event "warning" "$(jq -nc --arg u "$e_pr_url" --arg a "$enabler_assignee" --arg w "$e_human_reviewer_who" \
                      --arg d "enabler completed the handoff on $e_pr_url, but review could not be requested from ${e_human_reviewer_who:-$enabler_assignee} — it will not appear in their review queue" \
                      '{detail: $d, pr_url: $u} + (if $w == "" then {reviewers: [$a]} else {reviewers: ($w | split(","))} end)')"
                  fi
                fi

                log_event "pr-ready" "$(jq -nc --arg u "$e_pr_url" --arg h "$e_handoff" \
                  --arg rr "$e_rereview_state" --arg w "$e_rereview_who" \
                  --arg hr "$e_human_reviewer_state" --arg ha "$enabler_assignee" \
                  '{pr_url: $u, handoff: "enabler", state: $h}
                   + (if $rr == "" or $rr == "none" then {} else {review_requested: $rr} end)
                   + (if $w == "" then {} else {reviewers: ($w | split(","))} end)
                   + (if $hr == "" or $hr == "skip" then {}
                      else {human_review_requested: $hr, human_reviewer: $ha} end)')"
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
        # Requirement 34d, extended by issue #243 from the Co-Ordinator alone to
        # every stage: the Enabler reads the issue and the PR (requirement 35),
        # but reading more does not stop a model citing the wrong artefact
        # inside it — see lib/void-guard.sh's own note on issue #243. `repos`
        # is passed as `[]`: the Enabler gathers no per-cycle candidate list, so
        # `void_guard_reason`'s PR-diff check (Co-Ordinator only) simply has
        # nothing to test against; the citation check needs nothing from it.
        e_void_entry="$(jq -nc --arg r "$e_repo" --arg i "$e_item" --arg reason "$e_reason" \
          --argjson x "$ex" '{repo: $r, item: $i, reason: $reason, evidence: ($x.evidence // "")}')"
        if e_void_refusal="$(void_guard_reason "$e_void_entry" '[]')"; then
          # TD-PPagop-26081407: $ex is an agent stage's own parsed verdict
          # (test 1 -- external, can be malformed) and {} reads exactly like
          # "no evidence given" (test 2).
          e_evidence_field="$(jq -c '{evidence: (.evidence // "")}' <<<"$ex" 2>&1)" \
            || { guard_warn "enabler:item-void-evidence" "$e_evidence_field"; e_evidence_field='{}'; }
          log_event "item-void" "$(item_event_fields "enabler" "$e_reason" "$e_repo" "$e_item" \
            "$e_evidence_field")"
          release_refinement_label "$e_item" "$e_repo"
        else
          log_event "warning" "$(jq -nc \
            --arg d "enabler void refused for ${e_repo:-<no repo>} $e_item — $e_void_refusal; recorded blocked instead" \
            '{detail: $d}')"
          log_event "attempt-failed" "$(item_event_fields "enabler" \
            "void refused ($e_void_refusal). The Enabler's stated reason was: $e_reason" "$e_repo" "$e_item" \
            "$(jq -nc --arg c "Establish from the repository itself whether this item describes any remaining work." \
              '{unblock_condition: $c}')")"
          outcome="void-refused"
        fi
        ;;
      still-blocked)
        # Nothing extra to record: the block stands, and the refreshed condition
        # travels on the examined event below, which is what a later engagement
        # and the dashboard read.
        # TD-PPagop-26081407: same rationale as the item-void evidence field
        # above -- $ex is agent-produced (test 1) and {} reads as "no
        # condition given" (test 2).
        extra="$(jq -c '{unblock_condition: (.unblock_condition // "")}' <<<"$ex" 2>&1)" \
          || { guard_warn "enabler:still-blocked-extra" "$extra"; extra='{}'; }
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

# refiner_claim_key REPO SOURCE ITEM
# The fleet's dedup key for one Refiner candidate: stable across cycles for the
# same item, unlike `enabler_claim_key`'s block-timestamp-scoped key, because
# there is no block here to re-mint a fresh one from — an item stops being a
# candidate the moment it is refined or blocked, which is what lets a claim
# stay stable without ever locking out a legitimately fresh occurrence.
refiner_claim_key() {
  local repo="$1" source="$2" item="$3"
  printf '%s__%s__%s' "${repo//[^A-Za-z0-9._-]/-}" "${source//[^A-Za-z0-9._-]/-}" \
    "${item//[^A-Za-z0-9._-]/-}"
}

# maybe_run_refiner CYCLE_EXIT_CODE
# Engage the Refiner if this cycle should, and translate its verdicts into log
# events, labels and issue comments. Always returns without disturbing the
# cycle's outcome — the same contract as `maybe_run_enabler`, and for the same
# reason: this runs from the exit trap, after the cycle's own result is
# already decided.
#
# Deliberately narrower than the Enabler: no escalation, no void, no handoff.
# The Refiner has exactly two things to say about an item — `refined` (it
# wrote a specification) or `needs-refinement` (it could not, and that decline
# is recorded through the same `record_needs_refinement_block` a Co-Ordinator's
# own report uses (requirement 39d)) — so there is no verdict here that needs
# a third power.
maybe_run_refiner() {
  local cycle_rc="${1:-1}"
  local engagement_json='[]' claimed_json='[]' n_eligible=0 n_claimed=0
  local entry repo source item key live_resume live_epoch input prompt out rc=0 result parsed detail
  local items_named_json
  local ex e_repo e_item verdict e_reason claimed_entry e_source outcome extra
  local e_synthetic e_block_ok e_refined_fields e_number

  # --- Guards, mirroring requirement 35's for the Enabler ---
  (( lock_acquired )) || return 0
  (( refiner_allowed )) || return 0
  (( DRY_RUN )) && return 0
  [[ "$cycle_rc" == "0" ]] || return 0
  (( limit_hit_this_cycle )) && return 0
  [[ -n "$refiner_model" ]] || return 0
  [[ -f "$PROMPTS_DIR/refiner.md" ]] || return 0

  # Requirement 39b: capped and deterministic, same reasoning as requirement
  # 35d's cap on the Enabler's refinement class.
  engagement_json="$(refiner_engagement_set "$refiner_candidates_json" "$refiner_max_per_engagement")"
  n_eligible="$(jq 'length' <<<"$engagement_json" 2>&1)" \
    || { guard_warn "refiner:n_eligible" "$n_eligible"; n_eligible=0; }
  [[ "$n_eligible" =~ ^[0-9]+$ ]] || n_eligible=0
  (( n_eligible > 0 )) || return 0

  live_resume="$(fleet_limit_resume_at "$state_repo" "$state_dir" 2>/dev/null || true)"
  if [[ -n "$live_resume" ]]; then
    live_epoch="$(date -d "$live_resume" +%s 2>&1)" \
      || { guard_warn "live_epoch" "$live_epoch"; live_epoch=0; }
    (( live_epoch > $(date +%s) )) && return 0
  fi

  # --- Claim each item, under the pseudo-slug `refiner` ---
  for (( i = 0; i < n_eligible; i++ )); do
    entry="$(jq -c --argjson i "$i" '.[$i]' <<<"$engagement_json" 2>/dev/null || true)"
    [[ -n "$entry" ]] || continue
    repo="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
    source="$(jq -r '.source // ""' <<<"$entry" 2>/dev/null || true)"
    item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
    [[ -n "$repo" && -n "$source" && -n "$item" ]] || continue
    key="$(refiner_claim_key "$repo" "$source" "$item")"
    [[ -n "$key" ]] || continue
    if CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$item" CLAIM_SOURCE="refiner" \
         "$SCRIPT_DIR/lib/claim.sh" claim file refiner "$key" \
         >>"$cycle_dir/claim.log" 2>&1; then
      # requirement 4g (TD-PPagop-26081401): same conversion as the
      # Enabler's own claim accumulator above — $entry joins $claimed_json
      # on stdin rather than riding in as a second --argjson.
      # TD-PPagop-26081407: passes test 1 -- $claimed_json and $entry are
      # concatenated in-memory immediately above; the trivial append script
      # cannot fail independently of the concatenation itself.
      claimed_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
        <<<"$claimed_json"$'\n'"$entry" 2>/dev/null || printf '%s' "$claimed_json")"
    fi
  done
  n_claimed="$(jq 'length' <<<"$claimed_json" 2>&1)" \
    || { guard_warn "n_claimed" "$n_claimed"; n_claimed=0; }
  [[ "$n_claimed" =~ ^[0-9]+$ ]] || n_claimed=0
  (( n_claimed > 0 )) || return 0

  # --- One engagement over every claimed item ---
  # The claimed items arrive on stdin, bound with `input as $items`
  # (requirement 4g) — never in argv, on the same terms as the Enabler's build
  # above: past MAX_ARG_STRLEN this would fail into the guard below and skip
  # the engagement silently.
  input="$(jq -nc --arg lbl "$refined_label" \
    --arg cycle "$cycle_id" --arg node "$node_name" \
    'input as $items
     | {items: $items, refined_label: $lbl, cycle: $cycle, node: $node}' \
    <<<"$claimed_json" 2>/dev/null || true)"
  [[ -n "$input" ]] || return 0

  prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" refiner "$prompt_overrides_json")

## Runtime input for this engagement

\`\`\`json
$(jq . <<<"$input")
\`\`\`
"
  out="$cycle_dir/refiner.out"
  # The Refiner spans repositories by construction, so its cell is keyed `*`
  # (requirement 4f), the same as the Enabler's.
  stage_budget_apply refiner "*" "$refiner_model"
  if run_claude_stage refiner "$(( stage_backstop_min * 60 ))" "$refiner_model" "$prompt" "$out" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$refiner_model" "$out" "$stage_gaps_json")" \
    '{stage: "refiner", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
  watchdog_warning="$(stage_watchdog_warning refiner || true)"
  if [[ -n "$watchdog_warning" ]]; then
    log_event "warning" "$watchdog_warning"
  fi
  (( ONCE )) && dump_stage_output "$out"

  result="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$result" 2>/dev/null || true)"
  if (( rc == 0 )) && [[ -z "$parsed" ]]; then
    parsed="$(stage_salvage_result refiner "$out" "$refiner_model" "$cycle_dir" || true)"
  fi
  if (( rc != 0 )) || [[ -z "$parsed" ]]; then
    if (( rc == 124 )); then
      detail="refiner timed out"
    elif (( rc != 0 )); then
      detail="refiner exited $rc"
    else
      detail="refiner returned an unparseable final message"
    fi
    detect_and_log_limit_hit "$out" || true
    items_named_json="$(jq -c '[.[] | {repo: (.repo // ""), item: (.item // "")}]' <<<"$claimed_json" 2>&1)" \
      || { guard_warn "items_named_json" "$items_named_json"; items_named_json='[]'; }
    # requirement 4g (TD-PPagop-26081401): same conversion as the Enabler's
    # own unparseable-verdict warning above — $items_named_json arrives on
    # stdin rather than as a second --argjson.
    log_event "warning" "$(jq -nc --arg d "$detail — no verdicts recorded; the claims stand until gc lets a later cycle retry" \
      'input as $items | {detail: $d, items: $items}' <<<"$items_named_json")"
    for (( i = 0; i < n_claimed; i++ )); do
      entry="$(jq -c --argjson i "$i" '.[$i]' <<<"$claimed_json" 2>/dev/null || true)"
      [[ -n "$entry" ]] || continue
      repo="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
      source="$(jq -r '.source // ""' <<<"$entry" 2>/dev/null || true)"
      item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
      key="$(refiner_claim_key "$repo" "$source" "$item")"
      [[ -n "$key" ]] || continue
      "$SCRIPT_DIR/lib/claim.sh" expire refiner "$key" >>"$cycle_dir/claim.log" 2>&1 || true
    done
    return 0
  fi

  # --- Verdict loop (requirement 39c/39d) ---
  while IFS= read -r ex; do
    [[ -n "$ex" ]] || continue
    e_repo="$(jq -r '.repo // ""' <<<"$ex")"
    e_item="$(jq -r '.item // ""' <<<"$ex")"
    verdict="$(jq -r '.verdict // ""' <<<"$ex")"
    e_reason="$(jq -r '.reason // "no reason given"' <<<"$ex")"

    claimed_entry="$(jq -c --arg r "$e_repo" --arg i "$e_item" \
      'map(select((.repo // "") == $r and ((.item // "") | tostring) == $i)) | first // empty' \
      <<<"$claimed_json" 2>/dev/null || true)"
    if [[ -z "$claimed_entry" ]]; then
      log_event "warning" "$(jq -nc --arg d "refiner: a verdict for an item this cycle did not claim ($e_repo $e_item) — ignored" \
        '{detail: $d}')"
      continue
    fi
    e_source="$(jq -r '.source // ""' <<<"$claimed_entry")"
    outcome="$verdict"
    extra='{}'

    case "$verdict" in
      refined)
        e_refined_fields="$(refinement_record_fields "$ex")"
        e_number=""
        if [[ "$e_source" == "issues" ]]; then
          e_number="$e_item"
          if [[ -z "$(jq -r '.comment_url // ""' <<<"$e_refined_fields")" ]]; then
            log_event "warning" "$(jq -nc --arg d "refiner: refined $e_repo#$e_item carries no comment — nothing was posted for the Co-Ordinator to find; not recorded as refined" \
              '{detail: $d}')"
            outcome="refined-uncorroborated"
          fi
        elif [[ -z "$(jq -r '.spec // ""' <<<"$e_refined_fields")" ]]; then
          log_event "warning" "$(jq -nc --arg d "refiner: refined $e_repo $e_item carries no spec — there is nowhere else this item type's specification lives; not recorded as refined" \
            '{detail: $d}')"
          outcome="refined-uncorroborated"
        fi
        if [[ "$outcome" == "refined" ]]; then
          log_event "item-refined" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" --arg by "refiner" \
            --argjson x "$e_refined_fields" '{repo: $r, item: $i, by: $by} + $x')"
          if [[ -n "$e_number" && -n "$refined_label" ]] && ! (( DRY_RUN )); then
            if refinement_label_add "$e_repo" "$e_number" "$refined_label"; then
              log_event "own-label-action" \
                "$(label_own_action_fields "$e_repo" "$e_number" "$refined_label" "add")"
            else
              log_event "warning" "$(jq -nc \
                --arg d "could not apply the $refined_label label to $e_repo#$e_number (does it exist in that repo?) — the refinement is recorded either way" \
                '{detail: $d}')"
            fi
          fi
        fi
        ;;
      needs-refinement)
        e_synthetic="$(jq -nc --arg r "$e_repo" --arg i "$e_item" --arg s "$e_source" \
          --arg reason "$e_reason" \
          --arg missing "$(jq -r '.missing // ""' <<<"$ex")" \
          --arg evidence "$(jq -r '.evidence // ""' <<<"$ex")" \
          '{repo: $r, item: $i, source: $s, reason: $reason, missing: $missing, evidence: $evidence}')"
        if record_needs_refinement_block "$e_synthetic" "refiner"; then
          e_block_ok=1
        else
          e_block_ok=0
          outcome="needs-refinement-refused"
        fi
        extra="$(jq -nc --argjson ok "$e_block_ok" '{recorded: $ok}')"
        ;;
      *)
        outcome="unknown-verdict"
        log_event "warning" "$(jq -nc --arg d "refiner: unrecognised verdict '$verdict' for $e_repo $e_item — recorded, acted on in no way" \
          '{detail: $d}')"
        ;;
    esac

    log_event "refiner-examined" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" --arg s "$e_source" \
      --arg o "$outcome" --arg d "$e_reason" --argjson x "$extra" \
      '{repo: $r, item: $i, source: $s, outcome: $o, detail: $d} + $x')"
  done < <(jq -c '.refined[]? // empty' <<<"$parsed" 2>/dev/null || true)

  # A claimed item the model never mentioned keeps its claim, exactly as the
  # Enabler's equivalent does, so gc is what eventually retries it.
  while IFS= read -r detail; do
    [[ -n "$detail" ]] || continue
    log_event "warning" "$(jq -nc \
      --arg d "refiner: no verdict for claimed item $detail — left unrefined until the claim TTL lets a later cycle retry" \
      '{detail: $d}')"
  done < <(jq -r --argjson p "$parsed" '
      (($p.refined // []) | map(((.repo // "") + " " + (.item // "")))) as $seen
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
      "Start with the newest failing cycle's \`coordinator.out.stderr\` under \`state_dir/cycles/\`; the stage transcripts survive every failure."
  fi

  crash_loop_preselection_json="$(crash_loop_preselection_verdict "$crash_loop_after" < "$union_log")"
  if [[ -n "$crash_loop_preselection_json" ]]; then
    crash_loop_escalate "$crash_loop_preselection_json" "crash-loop:pre-selection" \
      "cycles dying before any stage started" \
      "Crash loop: cycles are dying before any stage starts" \
      "No stage transcript exists for a cycle that dies before any stage begins — start with the newest failing cycle's entry in \`cron.log\` (or \`cron.log.1\` after rotation) under \`state_dir/\`."
  fi
fi

# --- 2. Stand-down checks ---
# 2.0 GitHub API budget (requirement 2.0). First of the stand-down checks
# because it is the only free one: `GET /rate_limit` is exempt from the limits
# it reports, so asking costs nothing, and every check below it — the
# usage-limit probe most of all — can spend real money.
#
# What this prevents is not the failed `gh` call. It is the cycle of
# 2026-08-12T20:52Z, which read a rate-limited GitHub as a quiet one: every
# gatherer degraded to `[]`, the Co-Ordinator engaged on that digest and chose
# an item, the claim was taken, and the cycle then died at the clone with
# `GraphQL: API rate limit already exceeded`. All of that is downstream of a
# question GitHub would have answered for free before the first token was
# spent.
#
# `unknown` — the meter itself unreadable — is deliberately not a stand-down.
# It is no evidence about the budget, and a node that cannot reach
# `/rate_limit` could not have run a cycle anyway; the failure it does have
# will be reported by whatever call meets it. Standing down here would invent
# a way for a network blip to look like an exhausted account.
if (( github_min_core_budget > 0 || github_min_graphql_budget > 0 )); then
  IFS=$'\t' read -r gh_budget_verdict gh_budget_resource gh_budget_remaining gh_budget_reset_at \
    < <(github_limit_verdict "$(github_limit_snapshot || true)" \
          "$github_min_core_budget" "$github_min_graphql_budget")
  if [[ "$gh_budget_verdict" == "exhausted" ]]; then
    if [[ "$gh_budget_resource" == "core" ]]; then
      gh_budget_floor="$github_min_core_budget"
    else
      gh_budget_floor="$github_min_graphql_budget"
    fi
    log_event "stand-down" "$(jq -nc --arg r "$(github_limit_describe \
      "$gh_budget_resource" "$gh_budget_remaining" "$gh_budget_floor" "$gh_budget_reset_at")" \
      --arg res "$gh_budget_resource" --arg rem "$gh_budget_remaining" \
      --arg until "$gh_budget_reset_at" \
      '{reason: $r, github_resource: $res, github_remaining: $rem, resume_at: $until}')"
    exit 0
  fi
fi

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
  # TD-PPagop-26081407: `governing` is fleet state read across nodes above
  # (test 1); epoch 0 reads as "already expired" (test 2) -- the gate this
  # feeds decides whether the whole fleet stands down for an active limit.
  resume_epoch="$(date -d "$resume_at" +%s 2>&1)" \
    || { guard_warn "cycle:resume_epoch" "$resume_epoch"; resume_epoch=0; }
fi
now_epoch="$(date +%s)"
if (( resume_epoch > now_epoch )); then
  governing_class="$(jq -r '.class // "other"' <<<"$governing" 2>&1)" \
    || { guard_warn "cycle:governing_class" "$governing_class"; governing_class=other; }
  governing_known="$(limit_reset_known "$governing")"
  # Absent means auto: every record this system writes is a detector's, and
  # says so; `manual` only ever enters by an operator's hand. The distinction
  # is load-bearing in both directions (requirement 2; #244) — an automatic
  # stand-down may be probed and cleared early, a manual one must never be.
  governing_kind="$(jq -r '.kind // "auto"' <<<"$governing" 2>&1)" \
    || { guard_warn "cycle:governing_kind" "$governing_kind"; governing_kind=auto; }
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
  # pure cost. And a *manual* record is never probed at all: it is an
  # operator's decision, not a detector's inference, and no probe verdict is
  # evidence about whether the human still means it (#244).
  if [[ "$governing_kind" != "manual" && "$governing_known" != "true" ]] && ! (( DRY_RUN )); then
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
          --arg by "auto-probe@$node_name" --arg n "$node_name" \
          '{was: $w, reason: "probe answered: the limit behind this estimated stand-down is gone", by: $by, actor: $n, kind: "auto"}')"
        if [[ -n "$state_repo" ]]; then
          # >/dev/null: fleet_flag_delete now prints which of "deleted"/
          # "absent" it was (issue #426); this site only reads the return
          # code, and the raw word must not leak into the cycle's own stdout.
          fleet_flag_delete "$state_repo" "$state_dir" limit >/dev/null || log_event "warning" \
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
    if [[ "$governing_kind" == "manual" ]]; then
      # An operator's stand-down explains itself and is honoured as written:
      # no probe ran above, nothing here clears it, and it ends at its own
      # resume_at or when the human runs --clear-limit (#244).
      governing_actor="$(jq -r '.actor // .node // "?"' <<<"$governing" 2>&1)" \
        || { guard_warn "cycle:governing_actor" "$governing_actor"; governing_actor='?'; }
      standdown_reason="manual stand-down until $resume_at, set by $governing_actor — never probed or auto-cleared; 'agent-cycle.sh --clear-limit' lifts it early"
    else
      standdown_reason="usage-limit cooldown $(limit_describe "$resume_at" \
        "$governing_class" "$governing_known")$probe_note"
      # #244: a long-running *automatic* fleet-wide freeze is put in front of
      # a human — the operator did not choose it, so nobody is watching it —
      # while a manual stand-down never pages the person who set it. Aged
      # from the start of the current freeze (limit_standdown_since), not
      # from its latest extension, and raised once per freeze: the
      # `limit-freeze-escalated` event in the union is the memory, and
      # create_escalation_issue's open-issue guard catches the cross-node
      # race the union has not yet carried.
      if (( limit_escalate_after_hours > 0 )) && ! (( DRY_RUN )) \
         && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]]; then
        freeze_since="$(limit_standdown_since < "$union_log")"
        freeze_epoch="$(date -d "$freeze_since" +%s 2>&1)" \
          || { guard_warn "freeze_epoch" "$freeze_epoch"; freeze_epoch=0; }
        freeze_done="$(jq -c --arg s "$freeze_since" \
          'select(.event == "limit-freeze-escalated" and .since == $s)' \
          "$union_log" 2>/dev/null | head -n1 || true)"
        if [[ -z "$freeze_done" ]] && (( freeze_epoch > 0 )) \
           && (( now_epoch - freeze_epoch >= limit_escalate_after_hours * 3600 )); then
          freeze_body="$cycle_dir/limit-freeze-issue.md"
          # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
          {
            printf '## The fleet has been standing down automatically since %s\n\n' "$freeze_since"
            printf 'Every cycle since then has stood down on an automatic usage-limit record, and the freeze has now outlived `limit_escalate_after_hours` (%s h). The governing record:\n\n' "$limit_escalate_after_hours"
            printf '```json\n%s\n```\n\n' "$governing"
            printf 'If the limit is real, nothing is needed — the stand-down ends at its own resume time, and each cycle keeps probing an estimated one. If it has lapsed or was misread, `agent-cycle.sh --clear-limit <reason>` lifts it fleet-wide.\n\n'
            printf -- '---\nItem: `usage-limit-freeze:%s` · raised by the Script · cycle `%s` · node `%s`\n' \
              "$freeze_since" "$cycle_id" "$node_name"
          } > "$freeze_body"
          if freeze_created="$(create_escalation_issue "$crash_loop_repo" \
               "usage-limit-freeze:$freeze_since" "$enabler_escalation_label" \
               "Usage-limit freeze: the fleet has stood down automatically since $freeze_since" \
               "$freeze_body")" && [[ -n "$freeze_created" ]]; then
            log_event "limit-freeze-escalated" "$(jq -nc \
              --argjson n "${freeze_created%%$'\t'*}" --arg u "${freeze_created#*$'\t'}" \
              --arg s "$freeze_since" '{issue_number: $n, issue_url: $u, since: $s}')"
          else
            log_event "warning" "$(jq -nc \
              --arg d "automatic usage-limit freeze since $freeze_since exceeds ${limit_escalate_after_hours}h but the escalation issue could not be filed — will retry next cycle" \
              '{detail: $d}')"
          fi
        fi
      fi
    fi
    log_event "stand-down" "$(jq -nc --arg r "$standdown_reason" '{reason: $r}')"
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

# 2.1c Post-merge closing-keyword sweep (requirement 17c) — the backstop for
# requirement 25a's CI check: a merged, `pr_label`-labelled pull request that
# named an issue (the `agent-ops:closes-issue` marker, requirement 23b) but
# never carried a real closing keyword leaves that issue open forever, to be
# re-selected and re-voided by every cycle that reaches it (issue #240; PR
# #206's "Implements #198" kept #198 open three days after its own fix
# merged). Cheap and bounded — scripts/sweep-closed-issues.sh examines only
# the most recently updated merged PRs per repo — and idempotent by
# construction: it only ever acts on an issue GitHub itself still reports
# open. Fleet-wide like 2.1a/2.1b, regardless of --repo. Skipped on
# --dry-run: the sweep closes issues.
if ! (( DRY_RUN )); then
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        closed) log_event "issue-closed-post-merge" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        deferred|warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("closed-issue sweep (" + $r + "): " + (del(.repo) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-closed-issues.sh" "$sweep_slug" "$node_name" "$cycle_id" \
               2>>"$cycle_dir/closed-issue-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 2.1d Human-visibility sweep (requirement 38) — the periodic half of the same
# guarantee requirement 38a keeps at the moment of handoff: every open, ready
# pull request this system raised gets a live review request whether or not
# any stage touched it this cycle, and an approved, mergeable, green one idle
# past `human_nudge_idle_hours` gets one nudge comment. Fleet-wide like the
# sweeps above and for the same reason — a review request or a comment either
# lands or it does not, so two nodes sweeping at once cost nothing but a
# redundant read. Skipped on --dry-run: the sweep requests reviews and posts
# comments.
#
# Its actions get their own event names rather than borrowing `pr-ready`, for
# the same reason 2.1b's do: the Publisher's outcome ladder reads `pr-ready` as
# "this cycle got a pull request to ready" and ranks it above every other
# reading, so a sweep that re-asked for a review on some other repo's
# long-since-ready pull request would rewrite the outcome of a cycle that stood
# down or selected nothing.
#
# Its `warning` events are appended into `union_log` the moment the sweep
# finishes (below), the same technique requirement 34j's own reconciliation
# uses to see its own cycle's freshly-logged events: `human_visibility_json`,
# computed later this cycle from `union_log` (requirement 38e), must see a
# violation this very sweep just found, not only one a previous cycle logged —
# otherwise the register-hygiene pre-fetch a few hundred lines below would
# never catch what its own cycle's sweep just discovered, and the violation
# would sit one full cycle behind its own detection for no reason.
if ! (( DRY_RUN )); then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        human-review-requested) log_event "human-review-requested" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        nudged) log_event "human-nudged" "$(jq -c --arg r "$sweep_slug" \
          '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        dequeue-notice) log_event "human-dequeue-notice" "$(jq -c --arg r "$sweep_slug" \
          '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("human-visibility sweep (" + $r + "): " + (del(.action) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-human-visibility.sh" "$sweep_slug" "$cycle_id" "$node_name" \
               2>>"$cycle_dir/human-visibility-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
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
#
# A ready PR only counts toward the trip when the pipeline itself has a next
# action on it — `reviewDecision == CHANGES_REQUESTED`, the same "whose turn
# is it" rule requirement 3c's review-feedback candidate filter uses
# (scripts/gather-review-feedback.sh), so the two definitions cannot disagree.
# A ready PR that is approved, or awaiting a first or re-review with nothing
# currently `CHANGES_REQUESTED`-blocking it, is sitting in the human's queue —
# the pipeline cannot shrink that by declining to open new work, so counting
# it against the cap only back-pressures the fleet for a queue it has no lever
# to drain (agent-ops#246).
#
# The count is taken in four parts — ready PRs awaiting a human, ready PRs
# awaiting the pipeline, draft PRs, live claims — because the trip decision
# needs only the human-queue-excluded sum, but the logged reason states the
# full split: a human-queue PR could fill the raw total without ever counting
# against the cap; a pipeline-turn ready PR is the human's queue answered and
# now the agent's to act on; a draft is work in flight (the Implementor's own
# claim marker, requirement 23); an unraised claim is a registry entry whose
# PR does not yet exist. Which of them filled the gate is what a cap-tuning
# decision needs to know. Recording it here costs nothing; reconstructing it
# later means cycle-record archaeology.
#
# The listing's page size is stated (`GITHUB_PR_LIST_LIMIT`, lib/github-limit.sh)
# rather than left to `gh`'s undeclared default of 30, and a response that came
# back at it is treated as a trip. This is the one place in the pipeline where
# a truncated listing is actively dangerous: `gh` gives no signal that it
# capped, so the counts below would simply be low, and low counts open a gate
# whose whole purpose is to stay shut. Note that the raw listing is not bounded
# by `max_open_agent_prs` — a pull request waiting in the human's merge queue
# carries `pr_label` and is deliberately excluded from the sum — so a repo can
# genuinely hold more open labelled PRs than the cap, and the cap is no
# guarantee the page was big enough.
#
# Live claims count toward the cap too: a claim is work in flight that has
# not yet surfaced as a PR, and N nodes counting only PRs would collectively
# overshoot by the work each other had claimed but not yet raised. Still
# approximate — two nodes can pass this check simultaneously — with a stated
# bound of max_open_agent_prs + (nodes - 1), transient.
#
# "Not yet surfaced as a PR" is the whole of it, and it is why each repo's
# claims are counted *here*, inside the same iteration as its own PR listing,
# rather than in a second loop of their own: `claim.sh count` is told which of
# this repo's pull requests the sum above already holds, and drops any claim
# that merely names one of them. Two claim shapes name a PR. The PR-keyed
# `pr-<n>` exclusion entry (issue #238) is held past its PR's own raising
# (issue #360) and `claim.sh` drops it unconditionally; the item claim beside
# it carries the `pr-<n>-<kind>-<scope>` ref the four finishing sources use,
# and until now it was counted — a claimed abandoned draft was its own draft
# PR *plus* its own claim, two against a cap it occupies once. Only the PRs
# actually inside the sum are passed, so a conflicted or dequeued PR sitting
# in the human's queue — excluded from the sum by the rule above — keeps
# counting through its claim, which is then the only record of it in flight.
ready_count=0
human_queue_count=0
draft_count=0
claim_count=0
listing_truncated=0
# Per-repo set of PR numbers this count already holds — its drafts and its
# CHANGES_REQUESTED-ready PRs, the same rule `counted_prs` below applies one
# repo at a time. An object keyed by slug, each value a JSON array of PR
# numbers. Requirement 2.2a's decision site reads this back to tell which of
# a repo's merge-conflict/dequeued candidates (gathered later, in step 3, so
# they cannot be folded in above) this count already counted and which it did
# not.
counted_prs_json='{}'
while IFS= read -r slug; do
  prs_json="$(gh pr list -R "$slug" --state open --label "$pr_label" \
    --limit "$GITHUB_PR_LIST_LIMIT" --json number,isDraft,reviewDecision 2>/dev/null)" || prs_json=''
  [[ -n "$prs_json" ]] || prs_json='[]'
  counts="$(jq -r '[([.[] | select(.isDraft | not)] | length),
           ([.[] | select(.isDraft | not) | select(.reviewDecision != "CHANGES_REQUESTED")] | length),
           ([.[] | select(.isDraft)] | length),
           length] | @tsv' <<<"$prs_json" 2>/dev/null)" || counts=''
  IFS=$'\t' read -r n_ready n_human n_draft n_total <<<"$counts"
  [[ "$n_ready" =~ ^[0-9]+$ ]] || n_ready=0
  [[ "$n_human" =~ ^[0-9]+$ ]] || n_human=0
  [[ "$n_draft" =~ ^[0-9]+$ ]] || n_draft=0
  [[ "$n_total" =~ ^[0-9]+$ ]] || n_total=0
  if github_pr_list_truncated "$n_total"; then
    listing_truncated=1
    log_event "warning" "$(jq -nc --arg r "$slug" --arg l "$GITHUB_PR_LIST_LIMIT" --arg d \
      "back-pressure: $slug's open labelled pull requests came back at the ${GITHUB_PR_LIST_LIMIT}-item listing cap, so the count below is a floor, not a total; treating back-pressure as tripped rather than counting a truncated page" \
      '{repo: $r, limit: $l, detail: $d}')"
  fi
  ready_count=$(( ready_count + n_ready ))
  human_queue_count=$(( human_queue_count + n_human ))
  draft_count=$(( draft_count + n_draft ))
  # The pull requests this repo just contributed to the trip: its drafts, and
  # its ready ones the pipeline still owes a change. Bounded by
  # GITHUB_PR_LIST_LIMIT, so it may ride argv (requirement 4g). An unreadable
  # listing leaves it empty, which counts every claim — the fail-closed
  # reading, matching the zeroed counts above.
  counted_prs_array="$(jq -c '[.[] | select(.isDraft or .reviewDecision == "CHANGES_REQUESTED") | .number]' \
    <<<"$prs_json" 2>/dev/null)" || counted_prs_array='[]'
  [[ -n "$counted_prs_array" ]] || counted_prs_array='[]'
  counted_prs="$(jq -r 'join(",")' <<<"$counted_prs_array" 2>/dev/null)" || counted_prs=''
  counted_prs_json="$(jq -c --arg s "$slug" --argjson ns "$counted_prs_array" \
    '. + {($s): $ns}' <<<"$counted_prs_json" 2>/dev/null)" || counted_prs_json='{}'
  n="$("$SCRIPT_DIR/lib/claim.sh" count "$slug" "$counted_prs" 2>&1)" \
    || { guard_warn "claim-count:$slug" "$n"; n=0; }
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  claim_count=$(( claim_count + n ))
done < <(jq -r '.[].slug' <<<"$all_repos_json")

pipeline_ready_count=$(( ready_count - human_queue_count ))
raw_open_count=$(( ready_count + draft_count + claim_count ))
adjusted_open_count=$(( pipeline_ready_count + draft_count + claim_count ))
open_composition="$pipeline_ready_count changes-requested + $draft_count draft + $claim_count unraised claim(s) — plus $human_queue_count waiting on human ($raw_open_count raw)"

backpressure_tripped=0
if (( adjusted_open_count >= max_open_agent_prs )); then
  backpressure_tripped=1
fi
# A truncated listing trips the gate on its own, whatever the visible sum came
# to: the counts are a floor and the real total is unknown, and of the two ways
# to be wrong — deferring a cycle that could have run, or opening work past a
# cap that was already full — only the first is recoverable next cycle.
if (( listing_truncated )); then
  backpressure_tripped=1
  open_composition="$open_composition — at least one repo's listing was truncated, so these are floors"
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
  abandoned_drafts="[]"
  if jq -e 'any(.[]; . == "abandoned-drafts")' <<<"$sources" >/dev/null 2>&1; then
    abandoned_drafts_raw="$(gather_abandoned_drafts "$slug")"
    emit_first_seen "$slug" abandoned-drafts "$abandoned_drafts_raw"
    abandoned_drafts="$(exclude_claimed_items "$(exclude_claimed_prs "$abandoned_drafts_raw" "$claimed_pr_numbers_json")" "$claimed_item_refs_json")"
  fi
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
  if jq -e 'any(.[]; startswith("issues"))' <<<"$sources" >/dev/null 2>&1; then
    issues_raw="$(gather_issues "$slug")"
    emit_first_seen "$slug" issues "$issues_raw"
    issues="$(exclude_claimed_items "$issues_raw" "$claimed_item_refs_json")"
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
  entry="$(jq -nc --arg slug "$slug" --arg db "$default_branch" --argjson sources "$sources" \
    --arg ipp "$implementation_plan_path" \
    'input as $findings | input as $rf | input as $ad | input as $mc | input as $dq | input as $rh
     | input as $issues | input as $td
     | {slug: $slug, default_branch: $db, sources: $sources, findings: $findings, review_feedback: $rf, abandoned_drafts: $ad, merge_conflicts: $mc, dequeued: $dq, register_hygiene: $rh, human_visibility: [], issues: $issues, tech_debt: $td}
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
    "$refinement_own_actions_json")"
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
      "$refinement_own_actions_json" "$(blocked_items "$union_log")")"
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
# problem class), so the ordinary register-hygiene Implementor flow flips
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
human_visibility_json="$(human_visibility_violations "$union_log")"
human_visibility_n="$(jq 'length' <<<"$human_visibility_json" 2>&1)" \
  || { guard_warn "human_visibility_n" "$human_visibility_n"; human_visibility_n=0; }
if [[ "$human_visibility_n" != "0" ]]; then
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
  done < <(jq -r '[.[].repo] | unique[]' <<<"$human_visibility_json" 2>/dev/null || true)
fi

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
#   - liveness, for the five shapes the cycle already gathers as structured
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
# Age-only retirement for the five liveness shapes was considered and
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

  # The five liveness shapes (TD-PPagop-26081303, extended by TD-PPagop-26081409
  # for `dequeued`): per repo, whatever
  # gather_findings/gather_register_hygiene/gather_merge_conflicts/gather_dequeued
  # already wrote to the cycle dir during the repo loop — the `.ok` marker
  # (this cycle's own read of that source succeeded) and the ids it currently
  # yields — read straight off those tee files, so alert/register-hygiene/
  # merge-conflict/dequeued liveness costs no further `gh` call at all.
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
      --argjson fr_ok "$vl_fr_ok" --argjson fr_ids "$vl_fr_ids" \
      '. + {($s): {alert: {ok: $alert_ok, ids: $alert_ids},
                   "register-hygiene": {ok: $rh_ok, ids: $rh_ids},
                   "merge-conflict": {ok: $mc_ok, ids: $mc_ids},
                   "dequeued": {ok: $dq_ok, ids: $dq_ids},
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
  "$ordered_repos_json" "$coordinator_blocked_json" "$refinements_json" "$claimed_json")"
coordinator_input="$(jq -nc \
  --arg model_default "$implementor_model_default" \
  --arg model_trivial "$implementor_model_trivial" \
  --argjson cmax "$candidates_max" \
  --argjson policies "$refinement_policy_json" \
  'input as $repos | input as $blocked | input as $refinements | input as $claimed
   | {repos: $repos, blocked: $blocked, refinements: $refinements, claimed: $claimed,
      models: {default: $model_default, trivial: $model_trivial},
      candidates_max: $cmax, refinement_policy: $policies}' <<<"$coordinator_stdin")"

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

# The Co-Ordinator runs *before* selection, so it has no repository either
# and is keyed `*` for the same reason as the Enabler (requirement 4f).
selected_by_fallback=0
if ! run_coordinator_stage_attempt "$coordinator_out" "$coordinator_prompt"; then
  exit 0
fi
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
for (( ci = 0; ci < n_cand; ci++ )); do
  cand="$(jq -c --argjson i "$ci" '.[$i]' <<<"$candidates_json")"
  c_repo="$(jq -r '.repo // ""' <<<"$cand")"
  c_item="$(jq -r '.item // ""' <<<"$cand")"
  c_source="$(jq -r '.source // ""' <<<"$cand")"
  c_db="$(jq -r '.default_branch // "main"' <<<"$cand")"
  c_takeover="$(jq -r '.takeover // false' <<<"$cand")"
  [[ -n "$c_repo" && -n "$c_item" ]] || continue
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
# Deterministic, no LLM, run before the clone and the Implementor engagement
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
# Here, rather than at startup for every configured repo: the cycle works one
# repository, so this is one listing and — after the first cycle against a
# repository — no writes at all. It precedes the Implementor because that stage
# is what raises the pull request `pr_label` has to exist for; `gh pr create
# --label` on a label that is not there fails the create outright, which would
# cost the whole cycle's work.
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

# --- 7. Implementor stage ---
implementor_prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" implementor "$prompt_overrides_json")

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`

## Cycle

$cycle_id

## Node

$node_name
"
impl_out="$cycle_dir/implementor.out"

stage_budget_apply implementor "$selected_repo" "$impl_model"
if run_claude_stage implementor "$(( stage_backstop_min * 60 ))" "$impl_model" "$implementor_prompt" "$impl_out" "$clone_dir" "$(( stage_inactivity_min * 60 ))"; then
  impl_rc=0
else
  impl_rc=$?
fi
log_event "stage-end" "$(jq -nc --argjson rc "$impl_rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$impl_model" "$impl_out" "$stage_gaps_json")" \
  '{stage: "implementor", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
# `if`, not `&&`: an empty warning is the common case, and a trailing
# `&&` whose test fails is a non-zero status at exactly the place
# `set -e` acts on — the same trap that cost a --once cycle its
# failure handling at dump_stage_output.
watchdog_warning="$(stage_watchdog_warning implementor || true)"
if [[ -n "$watchdog_warning" ]]; then
  log_event "warning" "$watchdog_warning"
fi
(( ONCE )) && dump_stage_output "$impl_out"

impl_result="$(jq -r '.result // empty' "$impl_out" 2>/dev/null || true)"
impl_status_json="$(extract_json_result "$impl_result" 2>/dev/null || true)"
if (( impl_rc == 0 )) && [[ -z "$impl_status_json" ]]; then
  impl_status_json="$(stage_salvage_result implementor "$impl_out" "$impl_model" "$clone_dir" || true)"
fi
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
  # Requirement 34d, extended by issue #243 from the Co-Ordinator alone to
  # every stage: the Implementor reads the tree itself (requirement 27b), but
  # that does not stop a model citing the wrong artefact from it — see
  # lib/void-guard.sh's own note on issue #243. `repos` is passed as `[]`: the
  # Implementor gathers no per-cycle candidate list, so `void_guard_reason`'s
  # PR-diff check (Co-Ordinator only) simply has nothing to test against; the
  # citation check needs nothing from it.
  impl_void_entry="$(jq -nc --arg r "$selected_repo" --arg i "$selected_item" \
    --arg reason "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    --argjson x "$impl_status_json" '{repo: $r, item: $i, reason: $reason, evidence: ($x.evidence // "")}')"
  if impl_void_refusal="$(void_guard_reason "$impl_void_entry" '[]')"; then
    log_item_void "implementor" \
      "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
      "$(jq -c '{evidence: (.evidence // "")}' <<<"$impl_status_json")"
  else
    log_event "warning" "$(jq -nc \
      --arg d "implementor void refused for ${selected_repo:-<no repo>} $selected_item — $impl_void_refusal; recorded blocked instead" \
      '{detail: $d}')"
    log_attempt_failed "implementor" \
      "void refused ($impl_void_refusal). The Implementor's stated reason was: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
      "$(jq -nc --arg c "Establish from the repository itself whether this item describes any remaining work." \
        '{unblock_condition: $c}')"
  fi
  # A void item has no work, so its claim must not outlive the verdict — the
  # branch (if untouched) and the registry entry both go. A refused void is
  # recorded blocked instead, but the claim releases the same way either way:
  # the Implementor found no PR to raise for this item.
  release_claim no-pr
  exit 0
fi

# The escape hatch (requirement 9f): the Implementor started this item and
# found the specification it was handed insufficient — not "something in the
# world is wrong" (that is `blocked`), but "the brief itself does not say
# enough to build against". Recorded through the same
# `record_needs_refinement_block` a Co-Ordinator's own `needs_refinement`
# report uses, attributed to `stage: "implementor"` — which also clears any
# `refined` mark the item was carrying, since a refinement that led to this is
# exactly the one requirement 39d says must not stand unexamined.
if (( impl_rc == 0 )) && [[ "$impl_status" == "needs-refinement" ]]; then
  impl_nr_entry="$(jq -nc --arg r "$selected_repo" --arg i "$selected_item" --arg s "$selected_source" \
    --arg reason "$(jq -r '.reason // "no reason given"' <<<"$impl_status_json")" \
    --arg missing "$(jq -r '.missing // ""' <<<"$impl_status_json")" \
    --arg evidence "$(jq -r '.evidence // ""' <<<"$impl_status_json")" \
    '{repo: $r, item: $i, source: $s, reason: $reason, missing: $missing, evidence: $evidence}')"
  record_needs_refinement_block "$impl_nr_entry" "implementor" || true
  # No PR exists yet on this path — the Implementor stops before step 2's
  # claim, exactly like `blocked` without one — so the branch releases with it.
  if [[ -n "$impl_pr_url" ]]; then
    gh pr comment "$impl_pr_url" --body "$(pipeline_comment_header script "$node_name")

The Implementor found this item's specification insufficient: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json") Recorded as needing refinement; the pipeline's Refiner will look at it again.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
    release_claim have-pr
  else
    release_claim no-pr
  fi
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
    gh pr comment "$impl_pr_url" --body "$(pipeline_comment_header script "$node_name")

The Implementor stopped on this PR: $(jq -r '.reason // "no reason given"' <<<"$impl_status_json") Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed.

$(pipeline_comment_marker "$cycle_id" script)" >/dev/null 2>&1 || true
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

# Requirement 25a's finding from the Implementor-side gate below, empty when
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

## Implementor summary

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
  # Requirement 31c (agent-ops#249): a Reviewer's "ready" is a model reading a
  # check list, exactly the judgement that missed poetic-fiddle #216's CodeQL
  # alert hidden inside an otherwise-green list. Before any handoff mechanism
  # runs, ask GitHub directly, the same "confirm, don't trust" shape requirement
  # 31a already applies to the draft flag itself.
  gate_default_branch="$(jq -r '.default_branch // "main"' <<<"$work_order_json")"
  # Captured, not discarded with `|| true`: `review_gate_verdict` exits
  # non-zero for a `dirty` verdict *and* for the specific `unknown` that means
  # its required-check list could not be read at all (TD-PPagop-26081305) —
  # that one still refuses the handoff, unlike the alerts/closing-keyword
  # `unknown`s below, so the caller must tell the two apart by exit status,
  # not by the word alone (see lib/review-gate.sh's own header).
  if gate_result="$(review_gate_verdict "$impl_pr_url" "$gate_default_branch")"; then
    gate_rc=0
  else
    gate_rc=$?
  fi
  gate_word=""; gate_reason=""
  IFS=$'\t' read -r gate_word gate_reason <<<"$gate_result" || true
  # TD-PPagop-26081404: bookkeeping for `review_gate_unknown_streak_verdict`,
  # logged unconditionally — regardless of which branch below is taken, or
  # none of them — so a run of consecutive failures can be told apart from
  # ordinary noise. Exit status 2 is `review_gate_verdict`'s
  # required-checks-read-failed signal, deliberately read instead of the
  # word: a genuinely dirty alert outranks an unreadable check list for the
  # word and the handback below, so the word alone would record `{ok: true}`
  # for an evaluation whose required-checks read failed outright — falsely
  # resetting the very streak this event exists to count. Anything but exit 2
  # — `clean`, a `dirty` earned with the check list read, the non-blocking
  # alerts `unknown` — proves the required-checks read itself succeeded, and
  # resets the streak exactly the way a Co-Ordinator success resets
  # `crash_loop_verdict` (lib/crash-loop.sh).
  gate_checks_ok=true
  [[ "$gate_rc" -eq 2 ]] && gate_checks_ok=false
  log_event "review-gate-checks-read" "$(jq -nc --argjson ok "$gate_checks_ok" '{ok: $ok}')"
  if [[ "$gate_word" == "dirty" ]]; then
    log_reviewer_handback \
      "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $gate_reason" \
      "$impl_pr_url" "Get every required check green and clear the named security-severity code-scanning alert, then let the Reviewer re-examine it."
    exit 0
  fi
  if [[ "$gate_word" == "unknown" && "$gate_rc" -ne 0 ]]; then
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
    # not once per item past the threshold: `review_gate_degraded_since` is
    # the same already-escalated dedup `crash_loop_escalated_since` gives
    # requirement 2.7's crash loop, keyed on the run's own `first_ts`, so an
    # already-escalated run logs nothing further here (the bookkeeping event
    # above still records the failure, and the handback below still refuses
    # the handoff) until a successful read starts a new streak.
    streak_json="$(review_gate_unknown_streak_verdict "$review_gate_unknown_streak_after" "$node_name" < "$log_file")"
    if [[ -z "$streak_json" ]]; then
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$gate_reason" \
        '{detail: ("this node could not read " + $u + "'\''s required checks, so the handoff was refused rather than trusted on an unread check list: " + $d), pr_url: $u}')"
    elif ! review_gate_degraded_since "$(jq -r '.first_ts // ""' <<<"$streak_json")" "$node_name" < "$log_file"; then
      log_event "review-gate-checks-degraded" "$streak_json"
      streak_count="$(jq -r '.count // "?"' <<<"$streak_json")"
      echo "agent-cycle: WARNING — node $node_name has failed to read required checks $streak_count times in a row (review-gate); see log.jsonl event review-gate-checks-degraded" >&2
    fi
    log_reviewer_handback \
      "the Reviewer reported ready, but $impl_pr_url's required checks could not be confirmed: $gate_reason" \
      "$impl_pr_url" "Retry once a node can read GitHub's required-checks API for this pull request — nothing found here implicates the pull request itself."
    exit 0
  fi

  # Requirement 25a, asked again here for the same reason requirement 31c
  # asks the checks-and-alerts gate again at this point rather than trusting
  # the Implementor-side pass above still holds: the PR body can change
  # between the two handoffs (a pushed fix, an edited description), and this
  # is the last point before a human ever sees it. Every target repository
  # gets the same deterministic gate agent-ops's own CI workflow gives it
  # (TD-PPagop-26080803). This is the layer that actually gates: the earlier
  # call only tells the Reviewer, so a Reviewer that ignored it stops here.
  ck_result="$(closing_keyword_gate "$impl_pr_url")" || true
  ck_word=""; ck_reason=""
  IFS=$'\t' read -r ck_word ck_reason <<<"$ck_result" || true
  if [[ "$ck_word" == "dirty" ]]; then
    log_reviewer_handback \
      "the Reviewer reported ready, but $impl_pr_url is not safe to hand off: $ck_reason" \
      "$impl_pr_url" "Add the missing closing keyword (Closes/Fixes/Resolves #N) for the issue this PR claims to close, then let the Reviewer re-examine it."
    exit 0
  fi
  # `unknown` is "the question could not be put" — a degraded `gh` on this
  # node, not a fault in this pull request — so it warns rather than blocks,
  # the same way an unreadable alert list does just below. A node degraded
  # enough for this to matter does not get past `review_gate_verdict` above in
  # any case: it already refused the handoff, with its own warning, the
  # moment its required-check list came back unreadable rather than merely
  # unable to confirm an alert or a keyword.
  if [[ "$ck_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$ck_reason" \
      '{detail: ("could not confirm " + $u + " carries its closing keyword: " + $d), pr_url: $u}')"
  fi

  if [[ "$gate_word" == "unknown" ]]; then
    log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg d "$gate_reason" \
      '{detail: ("could not confirm " + $u + " carries no new security-severity code-scanning alert: " + $d), pr_url: $u}')"
  fi

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

  # Requirement 38: nothing's `CHANGES_REQUESTED` above means there is no
  # blocking reviewer to re-request from — but the pull request may still be
  # exactly where a human needs to look (a first review, or an approval
  # nobody has acted on). `ensure_human_reviewer` asks GitHub the same way
  # `confirm_review_requested` did, targeted at `enabler_assignee` instead of
  # a blocking reviewer set.
  human_reviewer_state=""
  human_reviewer_who=""
  if [[ "$rereview_state" == "none" && -n "$enabler_assignee" ]]; then
    human_reviewer_result="$(ensure_human_reviewer "$impl_pr_url" "$enabler_assignee")" || true
    IFS=$'\t' read -r human_reviewer_state human_reviewer_who <<<"$human_reviewer_result" || true
    if [[ "$human_reviewer_state" == "failed" ]]; then
      log_event "warning" "$(jq -nc --arg u "$impl_pr_url" --arg a "$enabler_assignee" --arg w "$human_reviewer_who" \
        --arg d "$impl_pr_url is ready with nothing blocking it, but review could not be requested from ${human_reviewer_who:-$enabler_assignee} — it will not appear in their review queue" \
        '{detail: $d, pr_url: $u} + (if $w == "" then {reviewers: [$a]} else {reviewers: ($w | split(","))} end)')"
    fi
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
else
  # Requirement 32a: a Reviewer that cannot hand off hands *back*, not out. The
  # verdict names a real impediment on a real PR, which is a blocked item —
  # the Enabler's input — and never, by itself, a summons to a human.
  log_reviewer_handback \
    "reviewer verdict '${rev_status:-unparseable}': $(jq -r '.reason // .ci // "no detail given"' <<<"$rev_status_json")" \
    "$impl_pr_url" "Resolve what the Reviewer left on the pull request, or escalate it."
fi

echo "$impl_pr_url"
