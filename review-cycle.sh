#!/usr/bin/env bash
#
# review-cycle.sh — orchestrates one repository-review run across the
# configured target repositories. For each repo not skipped by the idempotency
# guard, it clones the repo fresh, stages the vendored project-review skill into
# the clone, runs the Reviewer-Agent (which produces the review reports, updates
# TECH-DEBT.md, and raises one ready-for-review PR), then cleans up.
#
# Full specification: docs/REVIEW-PIPELINE-SPEC.md. Config: config.json
# (.project_review).
# This is a sibling of agent-cycle.sh and deliberately reuses its machinery
# (PATH bootstrap, lock discipline, run_claude_stage, result parsing,
# usage-limit detection). Where this script is silent, agent-cycle.sh /
# docs/IMPLEMENTATION-PIPELINE-SPEC.md govern.

set -euo pipefail

# --- PATH: cron's environment is minimal; make sure claude, gh, git, jq resolve. ---
# Appended, not prepended: an already-resolvable PATH entry — a caller's own
# shim, e.g. test/toggle.test.sh's offline-e2e stub_bin — must win over these
# fallbacks, or a subprocess of this script silently reaches a real
# `claude`/`gh` instead of the stub standing in for them (TD-PPagop-26080701).
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
    echo "review-cycle: required binary not found on PATH: $bin" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# AGENT_OPS_CONFIG is for tests, as the positional argument is in
# watchtower-pre-update.sh; cron and the container invoke this bare and get the
# config beside the script. A test that drives the real script needs to vary one
# key without editing the shipped file — and without that, adding any key here
# silently reaches into every such test: `project_review.defaults.not_before`
# stood test/review-claim.test.sh down before it reached the claim it was
# asserting on.
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
SKILL_SRC="$SCRIPT_DIR/.claude/skills/project-review"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a refusal
# GitHub will lift in seconds is waited out rather than failing the call. A
# different system from the Claude usage limits above; see lib/github-limit.sh.
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
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"
# shellcheck source=lib/git-identity.sh
. "$SCRIPT_DIR/lib/git-identity.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

# --- Flags ---
DRY_RUN=0
ONCE=0
REPO_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --once) ONCE=1; shift ;;
    --repo) REPO_FILTER="${2:-}"; shift 2 ;;
    --disable|--enable|--status|--for|--until|--this-node)
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
  # The trailing newline is added here because command substitution eats the
  # one role_skip_message prints, and a cron log wants whole lines.
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(role_skip_message review-cycle)"
  exit 0
fi

# --- Config ---
expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# The schema gate (requirement 1b), shared with agent-cycle.sh: config.json is
# validated against config.schema.json before any individual key is read from
# it, and before the lock — a config-shape fault is refused here rather than
# reaching a stage on a default nobody chose.
schema_errors="$(config_schema_errors "$CONFIG_FILE" "$SCHEMA_FILE")" && schema_status=0 || schema_status=$?
if ((schema_status == 2)); then
  echo "review-cycle: $schema_errors" >&2
  exit 1
elif ((schema_status == 1)); then
  echo "review-cycle: config.json does not match config.schema.json:" >&2
  while IFS= read -r line; do echo "review-cycle:   $line" >&2; done <<<"$schema_errors"
  exit 1
fi

# Read against the raw file, deliberately: config_defaults (below) would
# synthesise a `.project_review` object from `not_before`'s own default even
# when the key is entirely absent from config.json, and this is the one check
# that must not be fooled by that (docs/REVIEW-PIPELINE-SPEC.md — the review
# pipeline is optional, and absence must mean absence).
if [[ "$(jq -r 'has("project_review")' "$CONFIG_FILE")" != "true" ]]; then
  echo "review-cycle: config.json has no .project_review block (see docs/REVIEW-PIPELINE-SPEC.md)" >&2
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
# Every per-repository tunable (model, pr_label, branch_prefix,
# min_days_between_reviews, not_before, timeout_review, inactivity_review) is
# resolved once here, against project_review.defaults and each repository's
# own override in project_review.repos — lib/config-schema.sh's
# config_project_review_repos is the one implementation, shared with
# scripts/doctor.sh, so the two scripts cannot resolve the same repository two
# different ways (requirement 342).
project_review_repos_json="$(config_project_review_repos "$DEFAULTED_CONFIG")"
# Requirement 342's resolution rule assumes exactly one entry per repository;
# two entries for the same slug leave no way to say which one's overrides
# apply, so this refuses to start rather than silently letting the later
# entry win (lib/config-schema.sh's config_duplicate_project_review_slugs,
# shared with scripts/doctor.sh's own `fail` so the two can never drift,
# docs/REVIEW-PIPELINE-SPEC.md requirement R1b).
duplicate_review_slugs="$(config_duplicate_project_review_slugs "$project_review_repos_json")"
if [[ -n "$duplicate_review_slugs" ]]; then
  echo "review-cycle: project_review.repos lists [$duplicate_review_slugs] more than once — refusing to start rather than guess which entry's overrides apply" >&2
  exit 1
fi
# Every configured repository's own resolved model is validated up front, at
# the same fail-fast position the single installation-wide value used to
# occupy (D12, requirement 1a) — a bad model on any one repository must not be
# discovered only after other repositories have already been reviewed. Each
# is validated against its own `model_key` (`project_review.repos[i].model`,
# or `project_review.defaults.model` when the repository does not override
# it), not a generic `project_review.model`, so a resolution error names the
# exact key to fix.
while IFS=$'\t' read -r configured_model_key configured_model; do
  [[ -n "$configured_model" ]] || continue
  resolve_model_id "$configured_model_key" "$configured_model" >/dev/null
done < <(jq -r '[.[] | [.model_key, .model]] | unique | .[] | @tsv' <<<"$project_review_repos_json")
# A stand-down with a date on it (R3.3), read from project_review.defaults
# directly rather than from project_review_repos_json above: this is the
# installation-wide gate, checked once before the lock is even taken, exactly
# as a single value always has been. A repository's own `not_before` override
# — already folded into project_review_repos_json — is checked again per
# repository inside skip_reason (R4) once the cycle is under way, so an
# override can hold one repository off *longer* than this value, but cannot
# escape it while it is in force.
review_not_before="$(cfg '.project_review.defaults.not_before')"
# Both of this stage's caps are derived per (actor, repository, model) from
# the fleet's own record of itself (requirement 4f, shared with the
# implementation pipeline through lib/stage-budget.sh). What is read here is
# only what this installation has explicitly overridden — absent, the
# derivation answers, and with no history the shipped prior does.
lock_stale_configured_hours="$(cfg '.project_review.lock_stale_after // 0')"
# Initialised before anything can exit through a trap, for the reason
# agent-cycle.sh gives at its copy: an unset variable read under `set -u` from
# inside a trap abandons the trap part-way. An empty table resolves to the
# shipped priors.
stage_budget_json='{"cells":{},"actors":{}}'
# Likewise: `acquire_lock` reads this, and is called immediately after the
# derivation sets it, but a function that reads an unset global under `set -u`
# fails at the reader rather than at the writer. Four hours, the value this
# used to be configured to, until the derivation replaces it.
lock_stale_after_sec=14400
limit_cooldown_default_hours="$(cfg '.limit_cooldown_default')"
state_repo="$(cfg '.state_repo')"

mkdir -p "$state_dir" "$state_dir/reviews" "$workspace_root"
log_file="$state_dir/log.jsonl"                 # shared stream (limit-hit lives here)
review_log_file="$state_dir/review-log.jsonl"   # this pipeline's own operational stream
lock_file="$state_dir/review-lock.json"         # our own lock, not the cycle's lock.json
impl_lock_file="$state_dir/lock.json"           # the implementation pipeline's lock

# Node identity, exactly as agent-cycle.sh stamps it: the id carries the
# machine's name (sanitised — it is also a directory name) with the pid last,
# and every event names the node, so multi-node records stay combinable.
node_name="${NODE_NAME:-$(hostname)}"
node_name="${node_name//[^A-Za-z0-9._-]/-}"
review_id="$(date -u +%Y%m%dT%H%M%SZ)-$node_name-$$"
review_date="$(date -u +%Y-%m-%d)"
review_dir="$state_dir/reviews/$review_id"
mkdir -p "$review_dir"

# --- Logging ---
# Operational events go to our own review-log.jsonl (keyed by review id), so the
# dashboard's log.jsonl parser is unaffected and the two pipelines stay separable.
# FIELDS must be a JSON object — the same contract, coercion and `|| true` as
# agent-cycle.sh's log_event, for the same reason: jq's `+` cannot add an
# object and an array, and a payload mistake at one call site must cost that
# event's shape, never the review cycle (issue #361 was the implementation
# pipeline dying exactly this way).
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
  jq -nc --arg ts "$ts" --arg review "$review_id" --arg node "$node_name" --arg event "$event" --argjson fields "$fields" \
    '{ts: $ts, review: $review, node: $node, event: $event} + $fields' >> "$review_log_file" || true
}

# The one shared signal: a usage-limit hit is written to log.jsonl in the exact
# shape agent-cycle.sh's stand-down and the dashboard already read, so a limit
# hit in either pipeline stands both down. A single-line O_APPEND write is
# atomic even if the implementation pipeline appends concurrently.
log_shared_limit_hit() {
  local resume_at="$1" class="$2" reset_known="$3" ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg cycle "$review_id" --arg node "$node_name" --arg r "$resume_at" --arg c "$class" --argjson k "$reset_known" \
    '{ts: $ts, cycle: $cycle, node: $node, event: "limit-hit", resume_at: $r, class: $c, reset_known: $k}' >> "$log_file"
  # And to the fleet flag (extend-only, best-effort), so peers stand down now
  # rather than at their next state-sync fetch — REVIEW-PIPELINE-SPEC R3.
  fleet_limit_publish "$state_repo" "$state_dir" "$resume_at" "$class" "$reset_known" "$node_name" \
    || log_event "warning" "$(jq -nc \
         '{detail: "could not publish fleet/limit.json — peers will pick the cooldown up from the log union instead"}')"
}

# Returns 0 (and logs limit-hit to the shared log) if the stage transcript shows
# a usage-limit / spend-cap phrase; 1 otherwise.
detect_and_log_limit_hit() {
  local out_file="$1" text resume_at class reset_known
  # The structured record first, on the same reasoning agent-cycle.sh gives at
  # its copy of this: it states a real reset time, and it is the only source
  # that exists at all for a stage stopped the moment the account refused —
  # such a stage never wrote a final message for the phrase matcher to read.
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

# Straight-parse the final message, else the last fenced ``` block regardless
# of its info string, else the earliest brace-opening line whose suffix parses
# as exactly one JSON value (identical to agent-cycle.sh's parser, where the
# full design note lives: a model sometimes prepends prose, and the object it
# then leaves bare at the end — or fences without a `json` tag — must not be
# the one fatal shape). test/extract-json-result.test.sh holds the two copies
# and scripts/publish-dashboard.sh's jq port to the same algorithm.
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

dump_stage_output() {
  local out_file="$1"
  cat "$out_file"
  [[ -s "$out_file.stderr" ]] && cat "$out_file.stderr" >&2
  # See agent-cycle.sh's dump_stage_output: an empty stderr file must not
  # become the return value that a `(( ONCE )) && …` call site hands set -e.
  return 0
}

# --- Cleanup (always runs on exit) ---
lock_acquired=0
clone_dir=""
cleanup() {
  local exit_code=$?
  # A signal landing mid-cleanup must not re-enter the handler over a run
  # that is already writing its record (R7a).
  trap '' TERM INT HUP
  if [[ -n "$clone_dir" && -d "$clone_dir" ]]; then
    rm -rf "$clone_dir"
  fi
  log_event "review-end" "$(jq -nc --argjson rc "$exit_code" '{exit_code: $rc}')"
  if [[ "$lock_acquired" == "1" ]]; then
    rm -f "$lock_file"
  fi
  # Publish this node's state to the fleet, once the review is fully recorded
  # (R2c) — its own `nodes/<NODE_NAME>` branch, so there is nothing another
  # node's push could overwrite and nothing to gate.
  timeout 300 "$SCRIPT_DIR/scripts/state-sync.sh" push || true
  # Refresh the local monitoring dashboard. Fully isolated and time-bounded: a
  # failure or slow gh call here must never affect this run's outcome.
  if [[ -x "$SCRIPT_DIR/scripts/publish-dashboard.sh" ]]; then
    timeout 120 "$SCRIPT_DIR/scripts/publish-dashboard.sh" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# --- Signals (R7a; the implementation spec's requirement 9c sets out the
#     rationale at length) ---
# A stale-lock takeover TERMs this run's whole process group, an operator
# stops a container, a `--once` run is interrupted at the terminal. Untrapped,
# any of them ends bash with no `review-attempt-failed`, no `review-end`, no
# claim release — and the Reviewer-Agent's own process group, which `set -m`
# detached from ours, reviewing on for a run that is already dead.
#
# Same order as agent-cycle.sh's handler, for the same reasons: stop the stage
# (KILL — the signaller's patience is unknown), land the event (a local file
# append), release the claim time-bounded, and exit through `exit` so
# `review-end` reports 128+n.
stage_pid=""
stage_name=""
signal_claim_slug=""
signal_claim_branch=""
signal_claim_safe=""
on_signal() {  # on_signal NAME NUM
  local name="$1" num="$2" actor
  trap '' TERM INT HUP
  if [[ -n "$stage_pid" ]] && kill -0 "$stage_pid" 2>/dev/null; then
    kill -KILL "-$stage_pid" 2>/dev/null || true
  fi
  actor="${stage_name:-cycle}"
  log_event "review-attempt-failed" "$(jq -nc \
    --arg r "$signal_claim_slug" --arg s "$actor" \
    --arg d "$actor terminated by SIG$name" \
    '(if $r == "" then {} else {repo: $r} end) + {stage: $s, detail: $d}')"
  if [[ -n "$signal_claim_branch" ]]; then
    # no-pr is safe even when the model had already raised its PR:
    # lib/claim.sh keeps the ref whenever it has moved or an open PR uses it.
    claim_release_timeout=8
    release_review_claim "$signal_claim_slug" "$signal_claim_branch" "$signal_claim_safe" no-pr
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
      echo "review-cycle: refusing to launch a stage outside workspace_root: $dir" >&2
      exit 1
      ;;
  esac
}

# `run_claude_stage` — the stage launcher, its wall-clock cap and its
# process-group kill — comes from lib/stage-run.sh, sourced at the top of this
# script. It used to be a second copy of agent-cycle.sh's, kept in step by
# hand; R7b is the requirement that there is now one of it. This pipeline's
# prompt is far short of the argv cap that copy existed to dodge, which is
# exactly why sharing matters: the smaller prompt is the one that would sit
# broken longest before anyone noticed.

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
# would have left the review pipeline free to fire mid-edit and read half of it.
#
# The expired case is left for agent-cycle.sh to clear and log. This pipeline
# runs on its own configured cadence
# (`project_review.defaults.min_days_between_reviews`); letting it clear a
# switch would mean the event that explains why cycles resumed could land
# days after they did.
review_switch_state="$(toggle_state "$state_dir")"
if [[ "$(jq -r '.state' <<<"$review_switch_state")" == "disabled" ]]; then
  log_event "review-stand-down" "$(jq -nc \
    --arg r "disabled: $(toggle_describe "$(jq -c '.record' <<<"$review_switch_state")")" \
    '{reason: $r}')"
  (( ONCE )) && echo "review-cycle: the pipeline is disabled — agent-cycle.sh --status for detail" >&2
  exit 0
fi

# The fleet switch (requirement 2.3a), honoured on the same terms: this
# pipeline stands down for it but never sets or clears it — an expired fleet
# flag, like an expired local one, is agent-cycle.sh's to clear and log.
fleet_review_switch="$(fleet_disabled_state "$state_repo" "$state_dir")"
if [[ "$(jq -r '.state' <<<"$fleet_review_switch")" == "disabled" ]]; then
  log_event "review-stand-down" "$(jq -nc \
    --arg r "fleet switch: $(toggle_describe "$(jq -c '.record' <<<"$fleet_review_switch")")" \
    '{reason: $r}')"
  (( ONCE )) && echo "review-cycle: the fleet switch is set — agent-cycle.sh --enable clears it everywhere" >&2
  exit 0
fi

# --- The dated stand-down (R3.3) ---
# `project_review.defaults.not_before` holds a timestamp before which no
# review may start. It exists for the case the switch above cannot express:
# the operator wants the review pipeline held off until a date, and wants the
# implementation pipeline to carry on meanwhile. The switch is deliberately
# shared between both pipelines (see its comment), so reaching for it here
# would stop the cycles too — a far bigger stand-down than "not this week's
# review".
#
# Checked before the lock, like the switches, and for the same reason: a review
# that must not start should not take a lock, however briefly, that a roll would
# then defer for. This is the installation-wide value only — a repository's own
# `not_before` override (requirement 342) is resolved separately, per
# repository, into project_review_repos_json above, and is checked again
# inside skip_reason (R4) once the cycle is under way; that lets an override
# hold one repository off *longer* than this value, but not escape it while it
# is in force.
#
# Self-expiring by construction, which is the whole point of a timestamp over a
# raised `min_days_between_reviews`: the latter has to be put back by hand, and
# a cadence quietly left throttled is the kind of thing nobody notices for
# weeks. An unparseable value stands the pipeline down rather than running
# through it — the operator plainly meant to hold reviews off, and guessing
# otherwise spends the quota they were protecting.
if [[ -n "$review_not_before" ]]; then
  not_before_epoch="$(date -d "$review_not_before" +%s 2>/dev/null || echo "")"
  now_epoch="$(date +%s)"
  if [[ -z "$not_before_epoch" ]]; then
    log_event "review-stand-down" "$(jq -nc --arg r \
      "project_review.defaults.not_before is set to an unparseable value ($review_not_before) — standing down rather than guessing" \
      '{reason: $r}')"
    (( ONCE )) && echo "review-cycle: project_review.defaults.not_before ($review_not_before) is not a date this system can parse" >&2
    exit 0
  fi
  if (( now_epoch < not_before_epoch )); then
    log_event "review-stand-down" "$(jq -nc --arg r "project_review.defaults.not_before: no review before $review_not_before" \
      --arg nb "$review_not_before" '{reason: $r, not_before: $nb}')"
    (( ONCE )) && echo "review-cycle: standing down until $review_not_before (project_review.defaults.not_before)" >&2
    exit 0
  fi
fi

# --- The dated stand-down, tier two: every configured repo held (R3.3) ---
# The check above reads only `project_review.defaults.not_before` — the
# installation-wide gate a repository with no override inherits. A
# repository can also be held individually, on its own `not_before` override
# (requirement 342), already resolved into project_review_repos_json above.
# When `defaults.not_before` itself does not trip the check above — absent,
# or already past — but *every* configured repository is still individually
# held (each one's own resolved not_before, override or inherited default,
# is future or unparseable), there is nothing this run could review, and
# taking the lock only to have R4's skip-guard skip every repository once the
# cycle is under way would hold it for nothing. Vacuous only in the direction
# that cannot false-positive: no repository configured at all means nothing
# for this gate to ever hold back, not that everything is held, so it does
# not stand the run down on an empty project_review.repos.
if [[ "$(jq 'length' <<<"$project_review_repos_json")" != "0" ]]; then
  now_epoch="$(date +%s)"
  all_repos_held=1
  while IFS= read -r held_not_before; do
    if [[ -z "$held_not_before" ]]; then
      all_repos_held=0
      break
    fi
    held_epoch="$(date -d "$held_not_before" +%s 2>/dev/null || echo "")"
    if [[ -n "$held_epoch" ]] && (( now_epoch >= held_epoch )); then
      all_repos_held=0
      break
    fi
  done < <(jq -r '.[].not_before' <<<"$project_review_repos_json")
  if (( all_repos_held )); then
    log_event "review-stand-down" "$(jq -nc --argjson repos \
      "$(jq -c '[.[] | {slug, not_before}]' <<<"$project_review_repos_json")" \
      '{reason: "every configured repository'"'"'s own not_before holds it off (requirement 342)", repos: $repos}')"
    (( ONCE )) && echo "review-cycle: standing down — every configured repository's own not_before (requirement 342) holds it off" >&2
    exit 0
  fi
fi

# --- Lock (R2) ---
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
        log_event "warning" "$(jq -nc --arg d "foreign review lock from pid $pid on host $host (age ${age_sec}s) taken over" '{detail: $d}')"
      else
        local stale_after_sec
        stale_after_sec="$lock_stale_after_sec"
        if kill -0 "$pid" 2>/dev/null && (( age_sec < stale_after_sec )); then
          log_event "review-skipped" "$(jq -nc --arg d "review lock held by pid $pid, age ${age_sec}s" '{detail: $d}')"
          exit 0
        fi
        if kill -0 "$pid" 2>/dev/null; then
          pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
          if [[ -n "$pgid" ]]; then
            # TERM first, so the doomed run's own handler (R7a; implementation
            # spec requirement 9c) can log its record and release its claim;
            # KILL only after a grace sized to that handler's worst case.
            # Polled rather than slept: a run that records and exits in one
            # second costs one second.
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
        log_event "warning" "$(jq -nc --arg d "stale review lock from pid $pid (age ${age_sec}s) taken over" '{detail: $d}')"
      fi
    fi
  fi
  # `host` names the container (PID namespace) the pid is meaningful in — see
  # agent-cycle.sh's acquire_lock and issue #130.
  jq -n --argjson pid "$$" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "${HOSTNAME:-}" \
    '{pid: $pid, started_at: $started_at, host: $host}' > "$lock_file"
  lock_acquired=1
}
# --- The fleet's memory (R2c) ---
# No lease: per-item claims (IMPLEMENTATION-PIPELINE-SPEC requirement 17a)
# keep nodes off each other's work. What the review shares with the fleet is
# the event stream — the union of every node's shared log, snapshotted once
# here so the usage-limit checks below see a limit *any* node hit (they all
# spend one Claude account).
#
# Taken before the lock, as agent-cycle.sh does and for the same reason: this
# pipeline's lock threshold is derived from the stage budgets, which are
# derived from this stream (requirement 4f).
peers_dir="$(fleet_peers_dir "$workspace_root")"
union_log="$review_dir/.fleet-log.jsonl"
fleet_logs "$state_dir" "$peers_dir" log.jsonl > "$union_log" || true

# What the Reviewer-Agent is allowed this run (requirement 4f), and — derived
# from it — how long this pipeline's own lock may be held. The review lock has
# always been the longer of the two, because a full review is long; now it is
# longer *by derivation* rather than by a number someone chose.
stage_budget_settings_json="$(stage_budget_settings "$(cat "$CONFIG_FILE" 2>/dev/null || printf '{}')")"
stage_budget_json="$(stage_budget_table \
  "$(stage_budget_observations < "$union_log")" "$stage_budget_settings_json")"
# The lock is shared by every repository this run might touch, so its
# derivation takes the *widest* override configured across all of them — the
# per-repository override used for a single repository's own stage_budget_resolve
# call (inside review_one, below) is resolved separately, from that
# repository's own entry in project_review_repos_json.
lock_budget_overrides="$(jq -nc --argjson repos "$project_review_repos_json" '
  { backstop:    ([$repos[] | .timeout_review    | select(. != null)] | if length > 0 then max else null end),
    inactivity:  ([$repos[] | .inactivity_review | select(. != null)] | if length > 0 then max else null end) }')"
lock_stale_after_sec="$(jq -nr --argjson t "$stage_budget_json" \
  --argjson o "$lock_budget_overrides" --argjson priors "$STAGE_BUDGET_PRIORS" \
  --argjson configured "$lock_stale_configured_hours" \
  --argjson repos "$project_review_repos_json" '
    ([ ($priors["project-reviewer"].backstop // 0),
       ($o.backstop // empty),
       ((($t.cells // {}) | to_entries[]
         | select(.value.actor == "project-reviewer") | .value.backstop_min) // empty) ]
     | map(select(type == "number")) | max) as $cap
    # Every configured repository could be reviewed back to back inside one
    # lock, which is why this multiplies the widest single cap by their count
    # rather than taking it as given — floored at one, so a single-repository
    # installation is unaffected.
    | ([($repos | length), 1] | max) as $repo_count
    | ((($cap * $repo_count) + 30) * 60) as $derived
    | ([$derived, ($configured * 3600)] | max | ceil)' 2>/dev/null || printf 21600)"

# Reclaim the workspaces of runs that never cleaned up (agent-ops#605), on the
# same terms and for the same reason as agent-cycle.sh's own call: the review
# cycle clones into the same `workspace_root` and loses its clones to a kill
# in exactly the same way. Its window is its own — the review lock is derived
# from the Reviewer's budget times the repository count, which is wider than a
# cycle's — and both are floored at 24 h, so whichever of the two pipelines
# runs first cannot reap a workspace the other is still working in.
workspace_reap_json="$(workspace_reap_summary "$workspace_root" \
  "$(workspace_reap_window "$lock_stale_after_sec")" || printf '{"reaped":0}')"
if [[ "$(jq -r '.reaped // 0' <<<"$workspace_reap_json" 2>/dev/null || printf 0)" != "0" ]]; then
  log_event "workspaces-reaped" "$workspace_reap_json"
fi

acquire_lock

# --- Stand-down checks (R3) ---
# 3.1 Usage-limit cooldown, exactly as agent-cycle.sh 2.1: the log union (as
# fresh as the last fetch) and fleet/limit.json (read live), later resume wins.
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
  log_event "review-stand-down" "$(jq -nc --arg r "usage-limit cooldown $(limit_describe "$resume_at" \
    "$(jq -r '.class // "other"' <<<"$governing" 2>/dev/null || echo other)" \
    "$(limit_reset_known "$governing")")" '{reason: $r}')"
  exit 0
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
  repos_json="$(jq -c --arg f "$REPO_FILTER" \
    '[.[] | select(.slug == $f or (.slug | endswith("/" + $f)))]' <<<"$project_review_repos_json")"
  if [[ "$(jq 'length' <<<"$repos_json")" == "0" ]]; then
    echo "review-cycle: --repo '$REPO_FILTER' matches no configured review repo" >&2
    exit 64
  fi
else
  repos_json="$project_review_repos_json"
fi

# --- Per-repo skip-guard (R4) ---
# Echoes the reason to skip (a non-empty string) or nothing (proceed). Every
# tunable this reads is that repository's own resolved value — its override in
# project_review.repos, or project_review.defaults otherwise (requirement 342)
# — passed in rather than read off a global, since none of them is
# installation-wide any more.
skip_reason() {
  local slug="$1" default_branch="$2" pr_label="$3" min_days="$4" not_before="$5" \
        open_prs recent_date days not_before_epoch now_epoch
  # A repository's own `not_before` (its override, or project_review.defaults'
  # own value — the same one already checked once, cycle-wide, before the lock
  # above) is checked again here so an override can hold this one repository
  # off for longer than the installation-wide value.
  if [[ -n "$not_before" ]]; then
    not_before_epoch="$(date -d "$not_before" +%s 2>/dev/null || echo "")"
    now_epoch="$(date +%s)"
    if [[ -z "$not_before_epoch" ]]; then
      printf 'not_before is set to an unparseable value (%s) — standing down rather than guessing' "$not_before"
      return 0
    fi
    if (( now_epoch < not_before_epoch )); then
      printf 'not_before: no review before %s' "$not_before"
      return 0
    fi
  fi
  # `--limit 1`, because the test below is "is there one?", not "how many?".
  # Left unstated, `gh` asks for 30 and GitHub bills for the slots requested
  # rather than the rows returned (lib/github-limit.sh). Truncation is not a
  # risk in either form here — a listing capped at any positive number still
  # answers this question correctly — so the smallest listing that can answer
  # it is the right one.
  open_prs="$(gh pr list -R "$slug" --state open --label "$pr_label" --limit 1 --json number --jq 'length' 2>/dev/null || echo 0)"
  if [[ "$open_prs" =~ ^[0-9]+$ ]] && (( open_prs > 0 )); then
    printf 'an open %s PR already exists' "$pr_label"
    return 0
  fi
  recent_date="$(most_recent_review_date "$slug" "$default_branch")"
  if [[ -n "$recent_date" ]]; then
    days="$(days_since "$recent_date")"
    if [[ "$days" =~ ^[0-9]+$ ]] && (( days < min_days )); then
      printf 'last review (%s) is %s day(s) old (< %s)' "$recent_date" "$days" "$min_days"
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

# Resolve default branch + skip decision for each repo up front. `entry`
# already carries this repository's own resolved model, pr_label,
# branch_prefix, min_days_between_reviews, not_before, timeout_review and
# inactivity_review (project_review_repos_json above) — review_one reads them
# straight off `to_review_json` rather than re-deriving anything.
to_review_json="[]"
while IFS= read -r entry; do
  slug="$(jq -r '.slug' <<<"$entry")"
  entry_pr_label="$(jq -r '.pr_label' <<<"$entry")"
  entry_min_days="$(jq -r '.min_days_between_reviews' <<<"$entry")"
  entry_not_before="$(jq -r '.not_before // ""' <<<"$entry")"
  default_branch="$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null || echo "main")"
  reason="$(skip_reason "$slug" "$default_branch" "$entry_pr_label" "$entry_min_days" "$entry_not_before")"
  if [[ -n "$reason" ]]; then
    log_event "review-skipped" "$(jq -nc --arg r "$slug" --arg d "$reason" '{repo: $r, detail: $d}')"
    (( ONCE || DRY_RUN )) && echo "skip $slug — $reason"
    continue
  fi
  full_entry="$(jq -c --arg db "$default_branch" '. + {default_branch: $db}' <<<"$entry")"
  to_review_json="$(jq -c --argjson e "$full_entry" '. + [$e]' <<<"$to_review_json")"
  (( ONCE || DRY_RUN )) && echo "review $slug (base $default_branch)"
done < <(jq -c '.[]' <<<"$repos_json")

if (( DRY_RUN )); then
  jq . <<<"$to_review_json"
  exit 0
fi

# --- Per-repo review (R5), sequential ---

# release_review_claim <slug> <branch> <safe> no-pr|have-pr
# Mirrors agent-cycle.sh's release hooks (implementation spec 17a): "have-pr"
# drops only the registry entry — the PR supersedes the claim and the branch
# is its head; "no-pr" releases fully, and lib/claim.sh deletes the ref only
# if it still points where the claim left it AND no open PR uses it, so a
# review the model pushed before failing is never deleted.
#
# `claim_release_timeout` follows agent-cycle.sh's convention: 0 (unbounded)
# for every ordinary release, a small bound when the signal handler (R7a) is
# the caller and runs on borrowed time. Clearing the signal globals here, in
# the one funnel every release passes through, is what keeps the handler from
# releasing a claim this run had already let go.
claim_release_timeout=0
release_review_claim() {
  local slug="$1" branch="$2" safe="$3" mode="$4"
  if [[ "$mode" == "have-pr" ]]; then
    timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release file "$slug" "$branch" \
      >>"$review_dir/claim-$safe.log" 2>&1 || true
  else
    timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release branch "$slug" "$branch" \
      >>"$review_dir/claim-$safe.log" 2>&1 || true
  fi
  signal_claim_slug=""
  signal_claim_branch=""
  signal_claim_safe=""
}

review_one() {
  local entry="$1"
  local slug default_branch model pr_label branch_prefix
  slug="$(jq -r '.slug' <<<"$entry")"
  default_branch="$(jq -r '.default_branch' <<<"$entry")"
  # This repository's own resolved settings (requirement 342) — its override
  # in project_review.repos, or project_review.defaults otherwise. Already
  # validated (the model-id sweep before the lock, above), so this is a
  # straight re-derivation rather than a fresh check.
  model="$(resolve_model_id "$(jq -r '.model_key' <<<"$entry")" "$(jq -r '.model' <<<"$entry")")"
  pr_label="$(jq -r '.pr_label' <<<"$entry")"
  branch_prefix="$(jq -r '.branch_prefix' <<<"$entry")"

  local safe branch out_file result status_json pr_url rc claim_rc

  safe="${slug//\//_}"
  branch="${branch_prefix}${review_date}"

  # --- Claim the review branch first (R5c; implementation spec 17a) ---
  # `review/<date>` is a date-only name: with several nodes active, every one
  # of them computes the same name on the same day, and without a claim the
  # loser finds out only after spending a full model review — at push time.
  # One create-ref through lib/claim.sh makes the ref itself the lock (GitHub
  # 422s a second create even at the same SHA) and records the registry entry
  # that back-pressure, the dashboard and gc read. Losing the race and being
  # unable to reach GitHub both end this repo's review here, fail closed: a
  # node that could not claim could not have pushed a review either.
  claim_rc=0
  CLAIM_NODE="$node_name" CLAIM_CYCLE="$review_id" \
    CLAIM_ITEM="project-review-$review_date" CLAIM_SOURCE="project-review" \
    "$SCRIPT_DIR/lib/claim.sh" claim branch "$slug" "$branch" "$default_branch" \
    >>"$review_dir/claim-$safe.log" 2>&1 || claim_rc=$?
  if (( claim_rc == 3 )); then
    log_event "review-skipped" "$(jq -nc --arg r "$slug" --arg b "$branch" \
      '{repo: $r, detail: ("review branch " + $b + " is already claimed by another node")}')"
    return 0
  elif (( claim_rc != 0 )); then
    log_event "review-skipped" "$(jq -nc --arg r "$slug" --arg b "$branch" \
      '{repo: $r, detail: ("could not claim " + $b + " — standing this repo down, fail closed")}')"
    return 0
  fi

  # From here until this repo's release, the claim is what a signal must not
  # strand (R7a): the handler releases exactly what these name.
  signal_claim_slug="$slug"
  signal_claim_branch="$branch"
  signal_claim_safe="$safe"

  # The claim succeeded, so this repo is about to be cloned and reviewed —
  # the first point in this cycle that can actually commit. Every earlier
  # return above (role, switch, usage-limit, lost or failed claim) commits
  # nothing and must not be blocked on an identity it never uses. See
  # lib/git-identity.sh.
  require_git_identity review-cycle

  # The review pull request carries this repository's own resolved pr_label,
  # and `gh pr create --label` on a label that is not there fails the create —
  # after a review that costs up to timeout_review minutes. Ensured here, at
  # the same point as the identity above and for the same reason: this repo is
  # now certainly going to be worked (R4's skip-guard and the claim are both
  # behind us), so nothing is spent on a repo this cycle will not touch.
  # Unconditional and unstamped — the same shape as agent-cycle.sh's own
  # step 6a listing for its selected repository (requirement 6a,
  # agent-ops#687), and for the same reason: a repository is selected for
  # review at most once per min_days_between_reviews days, which in every
  # configuration this pipeline ships with is longer than
  # labels_ensure_interval_hours, so a rate-limited stamp here would always
  # have gone stale between one review and the next and never actually save a
  # listing — while opening a real gap in a configuration where it has not,
  # letting a pr_label deleted after the stamp cost a whole review before
  # `gh pr create --label` finally noticed. See lib/labels.sh; never fatal.
  local labels_report
  labels_report="$(labels_ensure_role "$CONFIG_FILE" "$SCHEMA_FILE" \
    "$slug" review "$pr_label" 2>/dev/null || true)"
  if [[ -n "$labels_report" ]]; then
    log_event "labels-ensured" "$(jq -nc --arg repo "$slug" --arg report "$labels_report" '
      {repo: $repo, role: "review"}
      + ($report | split("\n") | map(select(length > 0) | split("\t"))
         | {created: [.[] | select(.[0] == "created") | .[1]],
            failed:  [.[] | select(.[0] == "failed")  | .[1]]})')"
  fi

  clone_dir="$workspace_root/${review_id}-${safe}"
  assert_in_workspace "$clone_dir"
  # `clone_repo` (lib/repo-clone.sh), shared with agent-cycle.sh's workspace
  # step: `git clone`, because `gh repo clone` resolves the repository through
  # a billed GraphQL query first and git's transport is not rate-limited.
  if ! clone_repo "$slug" "$clone_dir" 2>"$review_dir/clone-$safe.err"; then
    log_event "review-attempt-failed" "$(jq -nc --arg r "$slug" --arg d "$(cat "$review_dir/clone-$safe.err")" '{repo: $r, stage: "workspace", detail: $d}')"
    release_review_claim "$slug" "$branch" "$safe" no-pr
    rm -rf "$clone_dir"; clone_dir=""
    return 0
  fi

  # Stage the vendored skill into the clone, and git-exclude it so the agent can
  # never commit the injected tooling (R5b).
  mkdir -p "$clone_dir/.claude/skills"
  cp -r "$SKILL_SRC" "$clone_dir/.claude/skills/project-review"
  printf '/.claude/skills/project-review/\n' >> "$clone_dir/.git/info/exclude"

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

  # This repository's own timeout_review/inactivity_review override (its own,
  # or project_review.defaults' — already folded into $entry) — distinct from
  # lock_budget_overrides above, which took the widest across every configured
  # repository purely to size the shared lock.
  local review_budget_overrides review_budget review_backstop_min review_inactivity_min
  review_budget_overrides="$(jq -c '{backstop: .timeout_review, inactivity: .inactivity_review}' <<<"$entry")"
  review_budget="$(stage_budget_resolve "$stage_budget_json" project-reviewer "$slug" \
    "$model" "$review_budget_overrides")"
  review_backstop_min="$(jq -r '.backstop_min' <<<"$review_budget" 2>/dev/null || printf '')"
  review_inactivity_min="$(jq -r '.inactivity_min' <<<"$review_budget" 2>/dev/null || printf '')"
  [[ "$review_backstop_min" =~ ^[0-9]+$ ]] \
    || review_backstop_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" '$p["project-reviewer"].backstop')"
  [[ "$review_inactivity_min" =~ ^[0-9]+$ ]] \
    || review_inactivity_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" '$p["project-reviewer"].inactivity')"
  # Announced on the event, not merely applied: a self-tuning number that
  # cannot be traced is a mystery number (requirement 4f).
  log_event "review-stage-start" "$(jq -nc --arg r "$slug" --arg m "$model" \
    --argjson b "$review_budget" \
    --argjson bs "$review_backstop_min" --argjson is "$review_inactivity_min" \
    '{repo: $r, model: $m}
     + (if ($b | type) == "object" then $b else {} end)
     + {backstop_min: $bs, inactivity_min: $is}')"
  if run_claude_stage reviewer "$(( review_backstop_min * 60 ))" "$model" "$reviewer_prompt" "$out_file" "$clone_dir" "$(( review_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  log_event "review-stage-end" "$(jq -nc --arg r "$slug" --argjson rc "$rc" --arg kr "$stage_kill_reason" \
    --argjson m "$(metering_fields "$model" "$out_file" "$stage_gaps_json")" '{repo: $r, exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
  # `if`, not `&&`: an empty warning is the common case, and a trailing
  # `&&` whose test fails is a non-zero status at exactly the place
  # `set -e` acts on — the same trap that cost a --once cycle its
  # failure handling at dump_stage_output.
  watchdog_warning="$(stage_watchdog_warning reviewer || true)"
  if [[ -n "$watchdog_warning" ]]; then
    log_event "warning" "$watchdog_warning"
  fi
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
      gh pr comment "$pr_url" --body "$(pipeline_comment_header review-script "$node_name")

The review agent abandoned this PR: $detail. Left for human review.

$(pipeline_comment_marker "$review_id" review-script)" >/dev/null 2>&1 || true
    fi
    # no-pr is safe even when an abandoned PR exists: lib/claim.sh keeps the
    # ref whenever it has moved or an open PR uses it, and drops the registry
    # entry either way.
    release_review_claim "$slug" "$branch" "$safe" no-pr
    rm -rf "$clone_dir"; clone_dir=""
    return 0
  fi

  log_event "review-pr-raised" "$(jq -nc --arg r "$slug" --arg u "$pr_url" '{repo: $r, pr_url: $u}')"
  release_review_claim "$slug" "$branch" "$safe" have-pr
  [[ -n "$pr_url" ]] && echo "$pr_url"
  rm -rf "$clone_dir"; clone_dir=""
  return 0
}

while IFS= read -r entry; do
  # Re-check the shared usage-limit signal between repos: a limit hit while
  # reviewing the first repo must stop us before launching the second (R6).
  # The union is re-snapshotted here — this node's own hit lands in its log
  # immediately — and fleet/limit.json is re-read live, which is how a hit a
  # *peer* took during our first review reaches us before their branch does.
  fleet_logs "$state_dir" "$peers_dir" log.jsonl > "$union_log" || true
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
    log_event "review-stand-down" "$(jq -nc --arg r "usage-limit cooldown $(limit_describe "$resume_at" \
      "$(jq -r '.class // "other"' <<<"$governing" 2>/dev/null || echo other)" \
      "$(limit_reset_known "$governing")")" '{reason: $r}')"
    break
  fi

  review_one "$entry"
done < <(jq -c '.[]' <<<"$to_review_json")
