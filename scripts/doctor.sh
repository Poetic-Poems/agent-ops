#!/usr/bin/env bash
#
# doctor.sh — check an installation end to end, before it runs a cycle.
#
# Everything this system needs to work sits in three places: the
# configuration, the toolchain around it, and the GitHub access it is granted.
# Each fails differently and none of them fails clearly. A misconfigured key is
# silent by construction — an unread key is a default nobody chose; a missing
# tool surfaces an hour later as a stage that died mid-cycle, after the work
# was already claimed; a token missing a scope shows up as an empty work
# source, which looks exactly like a repository with no work in it. The checks
# below are chosen for that: each one is a failure that otherwise costs a
# cycle, or a night, to notice.
#
# Read-only, with two exceptions it declares: it creates the state and
# workspace directories the configuration already names, because being able to
# create them is the thing being checked, and it renders a trial crontab into
# a `mktemp -d` it removes afterwards, to prove the template and the schedule
# in the config actually produce one. Every GitHub call is a GET. Safe to run
# against a live node at any time, including while a cycle holds the lock.
#
# Three verdicts, and a fourth for what it could not reach:
#
#   fail — the pipeline will not work, or will work on something other than
#          what the configuration says. Exit status 1.
#   warn — it will work, but something here will surprise the operator later.
#   skip — the check needs something unavailable right now (the network, an
#          authenticated `gh`, a usable `claude` credential), so it is
#          neither passed nor failed.
#
# Run it after editing config.json, on a new node before its first cycle, and
# whenever a cycle does something the configuration does not explain:
#
#   scripts/doctor.sh                 # this installation
#   scripts/doctor.sh --offline       # everything but GitHub access and the two Claude checks
#   scripts/doctor.sh --config PATH   # a config not yet deployed
#
# Exit: 0 clean (warnings and skips included) · 1 at least one failure ·
#       2 the arguments or the config file itself were unusable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config-schema.sh
source "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/model-id.sh
source "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/labels.sh
source "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/fleet.sh
source "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/version.sh
source "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/stage-budget.sh
source "$SCRIPT_DIR/lib/stage-budget.sh"
# shellcheck source=lib/toggle.sh
source "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/merge-budget.sh
source "$SCRIPT_DIR/lib/merge-budget.sh"
# shellcheck source=lib/merge-autonomy.sh
source "$SCRIPT_DIR/lib/merge-autonomy.sh"
# shellcheck source=lib/approver-token.sh
source "$SCRIPT_DIR/lib/approver-token.sh"

usage() {
  cat >&2 <<'USAGE'
usage: doctor.sh [--config PATH] [--offline] [--quiet]

Check this installation end to end: the configuration against
config.schema.json, the toolchain the pipelines need, the directories they
write to, the rendered crontab, the GitHub access they are granted, the
Claude credentials the stages run as, and whether a stage's event stream
really flushes as it runs on this node.

  --config PATH  Check this file instead of the repository's config.json.
  --offline      Skip every check that needs the network (GitHub access, the
                 Claude credentials, the stream-flushing probe); report them
                 skipped. The probe is the one check here that spends: a
                 single call to the cheapest configured model.
  --quiet        Print only warnings, failures and the summary.

Exit 0 clean, 1 at least one failure, 2 unusable arguments or config.
USAGE
}

config_file="$SCRIPT_DIR/config.json"
schema_file="$SCRIPT_DIR/config.schema.json"
offline=0
quiet=0
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --config)
      [[ $# -ge 2 ]] || { echo "doctor: --config needs a path" >&2; exit 2; }
      config_file="$2"; shift 2 ;;
    --offline) offline=1; shift ;;
    --quiet) quiet=1; shift ;;
    *) echo "doctor: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

fails=0
warns=0
skips=0
pending_section=""

# A section heading is held back until something under it prints, so --quiet
# never leaves a heading with nothing beneath it.
section() { pending_section="$1"; }
show_section() {
  [[ -n "$pending_section" ]] || return 0
  printf '\n%s\n' "$pending_section"
  pending_section=""
}
ok()   { ((quiet)) || { show_section; printf '  [ ok ] %s\n' "$1"; }; }
warn() { warns=$((warns + 1)); show_section; printf '  [warn] %s\n' "$1"; }
fail() { fails=$((fails + 1)); show_section; printf '  [fail] %s\n' "$1"; }
skip() { skips=$((skips + 1)); ((quiet)) || { show_section; printf '  [skip] %s\n' "$1"; }; }

# --- Configuration ---

section "Configuration ($config_file)"

if [[ ! -r "$config_file" ]]; then
  show_section
  printf '  [fail] cannot read %s\n' "$config_file"
  printf '\nUnusable configuration — nothing further can be checked.\n'
  exit 2
fi
if ! jq -e . "$config_file" >/dev/null 2>&1; then
  show_section
  printf '  [fail] %s is not valid JSON\n' "$config_file"
  jq . "$config_file" 2>&1 | sed 's/^/         /'
  printf '\nUnusable configuration — nothing further can be checked.\n'
  exit 2
fi

# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below. It performs no validation of its own — a config that fails the
# schema gate below still merges cleanly, which is what lets every check past
# that point keep running against something rather than stopping at the first
# fault. Its stderr is discarded because the one thing that silences it is an
# unreadable schema, and that is the very condition the schema check below
# reports as a `warn` in this command's own vocabulary; letting jq's raw
# diagnostic out here would print it ahead of the report and outside it.
DEFAULTED_CONFIG="$(config_defaults "$config_file" "$schema_file" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }
cfg_json() { jq -c "$1" <<<"$DEFAULTED_CONFIG"; }

# project_review.repos, each resolved against project_review.defaults
# (requirement 342) — the same lib/config-schema.sh helper review-cycle.sh
# uses, so the two scripts cannot resolve the same repository two different
# ways. `[]` when project_review is absent or malformed.
project_review_repos_json="$(config_project_review_repos "$DEFAULTED_CONFIG")"

schema_errors="$(config_schema_errors "$config_file" "$schema_file")"
case "$?" in
  0) ok "matches config.schema.json" ;;
  1) while IFS= read -r line; do fail "$line"; done <<<"$schema_errors" ;;
  *) warn "$schema_errors — the schema check did not run" ;;
esac

# The rules below are the ones the schema cannot state, because each holds
# between two keys rather than about one. A `fail` here mirrors a startup guard
# in agent-cycle.sh — the cycle would refuse to run; a `warn` is a combination
# that works and then surprises someone.

enabler_model="$(cfg '.enabler_model')"
enabler_assignee="$(cfg '.enabler_assignee')"
if ! config_enabler_assignee_ok "$enabler_model" "$enabler_assignee"; then
  fail "enabler_model is set but enabler_assignee is not — agent-cycle.sh refuses to start rather than raise an escalation that, being unassigned, the pipeline could then select as its own work"
elif [[ -n "$enabler_model" ]]; then
  ok "the Enabler is enabled; its escalations are assigned to @$enabler_assignee"
else
  ok "the Enabler is disabled (enabler_model is empty)"
fi

missing_plan_path="$(config_missing_plan_path_repos "$(cfg_json '.repos // []')")"
if [[ -n "$missing_plan_path" ]]; then
  fail "repo(s) [$missing_plan_path] list the implementation-plan source with no implementation_plan_path — agent-cycle.sh refuses to start, since that source has no path of its own outside the config"
else
  ok "every repo listing implementation-plan names its plan document"
fi

# Requirement 342's resolution rule assumes exactly one project_review.repos
# entry per repository; two entries for the same slug leave no way to say
# which one's overrides apply, so review-cycle.sh refuses to start rather
# than silently letting the later entry win (lib/config-schema.sh's
# config_duplicate_project_review_slugs, docs/REVIEW-PIPELINE-SPEC.md
# requirement R1b).
duplicate_review_slugs="$(config_duplicate_project_review_slugs "$project_review_repos_json")"
if [[ -n "$duplicate_review_slugs" ]]; then
  fail "project_review.repos lists [$duplicate_review_slugs] more than once — review-cycle.sh refuses to start, since requirement 342's resolution rule cannot tell which entry's overrides should apply"
else
  ok "every project_review.repos entry names a distinct repository"
fi

# D18 (docs/reviews/2026-08-14-autonomy-investigation.md §5.3, requirement
# 2.3b): any merge_autonomy level above `human` needs a non-author identity —
# the Approver GitHub App — able to hold review and merge rights, since
# GitHub refuses self-approval and this pipeline authors as its own
# configured owner. At this stage (WI-2) the App itself does not exist yet
# (WI-3/WI-4), so the only fact worth failing on now is the pairing: a level
# configured above human with no approver_app_id recorded is a configuration
# nobody can act on. Checked against every configured *source* of a level —
# the top-level key and each repo's own override — not the level each repo
# is effectively governed by, so an override that quietly inherits an invalid
# top-level value is still caught even where every repo happens to override
# it away today.
approver_app_id="$(cfg '.approver_app_id // ""')"
# D18 WI-5 (agent-ops#408): the Approver stage itself reads `approver_model_default`
# empty as "disabled" and simply skips (no App review, no blocked pull
# request — see lib/approver.sh's own header) rather than failing anything at
# runtime, the same graceful-degrade `enabler_model` empty already gets. But a
# level above `human` configured with no Approver model at all is the same
# nobody-can-act-on-it configuration `approver_app_id`'s own check exists to
# catch, so it is checked here too, at startup, where an operator will
# actually see it — not discovered later as a run of silent warnings.
approver_model_default_cfg="$(cfg '.approver_model_default // ""')"
merge_autonomy_sources="$(jq -r '
  [{label: "merge_autonomy", level: (.merge_autonomy // "human")}]
  + [(.repos // [])[] | select(has("merge_autonomy"))
     | {label: (.slug + "'"'"'s merge_autonomy override"), level: .merge_autonomy}]
  | .[] | [.label, .level] | @tsv' <<<"$DEFAULTED_CONFIG" 2>/dev/null || true)"
ma_above_human=0
if [[ -n "$merge_autonomy_sources" ]]; then
  while IFS=$'\t' read -r ma_label ma_level; do
    [[ -n "$ma_label" ]] || continue
    if [[ "$ma_level" != "human" ]]; then
      ma_above_human=1
    fi
    if [[ "$ma_level" != "human" && -z "$approver_app_id" ]]; then
      fail "$ma_label is \"$ma_level\" with no approver_app_id configured — every level above human needs the Approver identity to hold review and merge rights (D18)"
    elif [[ "$ma_level" != "human" && -z "$approver_model_default_cfg" ]]; then
      fail "$ma_label is \"$ma_level\" with no approver_model_default configured — the Approver stage disables itself when it is empty, so no level above human would ever gain an App review (D18 WI-5)"
    else
      ok "$ma_label is \"$ma_level\""
    fi
  done <<<"$merge_autonomy_sources"
fi

# The token wrapper (lib/approver-token.sh, requirement 14b) reads
# PULLWRIGHT_APPROVER_APP_ID from the environment; approver_app_id above is
# the operator's declaration in config.json. Nothing else reconciles the two,
# so doctor does. A set env id differing from a set config id is a fail, not
# a warn: the wrapper would mint against an App the configuration does not
# name and this run did not bless, every consumer of the mismatch is silent,
# and "works, minting as the wrong identity" is the outcome D18 exists to
# prevent. A credential absent from this environment is a warn, and only
# while some configured level is above human: the wrapper fails closed (exit
# 2, gate unreadable) and the Approver stage (D18 WI-5, lib/approver.sh)
# simply skips this pull request's App review rather than blocking it — the
# human still merges regardless, so the pipeline still works exactly as it
# did at `human` — but the operator who raised the level is waiting on
# approvals that will never come, which is exactly the surprise-later shape
# a warn is for.
env_app_id="${PULLWRIGHT_APPROVER_APP_ID:-}"
if [[ -n "$env_app_id" && -n "$approver_app_id" && "$env_app_id" != "$approver_app_id" ]]; then
  fail "PULLWRIGHT_APPROVER_APP_ID is \"$env_app_id\" but approver_app_id is \"$approver_app_id\" — the token wrapper mints against the environment's App, not the configured one, and nothing else reports the divergence (D18, requirement 14b)"
elif [[ -n "$env_app_id" && -z "$approver_app_id" ]]; then
  warn "PULLWRIGHT_APPROVER_APP_ID is set but approver_app_id is empty — the Approver credential is wired into this environment without being declared in config.json, so nothing validates the identity it mints as"
elif [[ -n "$env_app_id" ]]; then
  ok "PULLWRIGHT_APPROVER_APP_ID matches approver_app_id"
fi
if (( ma_above_human )); then
  if approver_token_credential_present; then
    ok "the Approver's runtime credential is present and its key is readable"
  else
    warn "merge_autonomy is above human but the Approver's runtime credential is not present in this environment — PULLWRIGHT_APPROVER_APP_ID, PULLWRIGHT_APPROVER_INSTALLATION_ID and PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH (readable) must all be set where the cycle runs, or approver_token_get reports the gate unreadable and no approval is ever minted"
  fi
fi

# D18 §5.4 (requirement 2.3c): merge_budget_per_day, reported per configured
# source the same way merge_autonomy is above — the top-level key and each
# repo's own override — since the schema alone cannot say whether a value
# looks sane relative to a repository's own trust level.
merge_budget_sources="$(jq -r '
  [{label: "merge_budget_per_day", cap: (.merge_budget_per_day // 8)}]
  + [(.repos // [])[] | select(has("merge_budget_per_day"))
     | {label: (.slug + "'"'"'s merge_budget_per_day override"), cap: .merge_budget_per_day}]
  | .[] | [.label, (.cap | tostring)] | @tsv' <<<"$DEFAULTED_CONFIG" 2>/dev/null || true)"
if [[ -n "$merge_budget_sources" ]]; then
  while IFS=$'\t' read -r mb_label mb_cap; do
    [[ -n "$mb_label" ]] || continue
    ok "$mb_label is $mb_cap$([[ "$mb_cap" == "0" ]] && printf ' (unlimited)')"
  done <<<"$merge_budget_sources"
fi
# A repository whose effective landing rate would be unbounded (cap 0) while
# also trusted at agent-merges-routine or above is not wrong today — nothing
# arms automatic landing yet (requirement 2.3c) — but it is worth surfacing
# now: the pairing only starts to matter once a later work item arms it, and
# an operator is better told before that day than on it. Judged against the
# *configured* level, not the kill-switch/freeze-adjusted effective one, for
# the same reason the merge_autonomy pairing check above is.
while IFS= read -r mb_slug; do
  [[ -n "$mb_slug" ]] || continue
  mb_level="$(merge_autonomy_configured_level "$DEFAULTED_CONFIG" "$mb_slug")"
  mb_rank="$(merge_autonomy_rank "$mb_level" 2>/dev/null || printf 0)"
  mb_routine_rank="$(merge_autonomy_rank agent-merges-routine)"
  mb_cap="$(merge_budget_effective_cap "$DEFAULTED_CONFIG" "$mb_slug")"
  if (( mb_rank >= mb_routine_rank )) && [[ "$mb_cap" == "0" ]]; then
    warn "$mb_slug's merge_autonomy is \"$mb_level\" with merge_budget_per_day unlimited (0) — no cap will bound its landing rate once a later work item arms automatic landing"
  fi
done < <(cfg '.repos[]?.slug // empty')

# `blocked` excludes an issue from the issues source, so projecting it onto an
# item would leave that item permanently unselectable — a value no issue-side
# label key may take.
for key in enabler_escalation_label needs_refinement_label refined_label unvoid_label; do
  if [[ "$(cfg ".$key")" == "blocked" ]]; then
    fail "$key is \"blocked\", which excludes an issue from the issues source — an item carrying it could never be selected again"
  fi
done

# `obsolete` is the other reserved name: lib/void-guard.sh reads it as a
# human's own corroboration for closing a still-open, still-diff-carrying
# draft pull request (requirement 34k), so a configured label carrying that
# name would have a pipeline stage apply the corroboration itself — pr_label
# alone is projected onto every draft the Implementor raises. Case-insensitive,
# as the guard reads labels.
for key in pr_label enabler_escalation_label needs_refinement_label refined_label unvoid_label; do
  label_name="$(cfg ".$key // \"\"")"
  if [[ "${label_name,,}" == "obsolete" ]]; then
    fail "$key is \"$label_name\" — the obsolete label is a human's own corroboration for closing a draft pull request (requirement 34k), and a stage projecting it as a configured label would corroborate the pipeline's own voids"
  fi
done

# project_review's pr_label is resolved per repository (requirement 342), so
# every distinct value in force — project_review.defaults.pr_label, plus any
# repository's own override — is checked here rather than one global key.
while IFS= read -r review_label; do
  [[ -n "$review_label" ]] || continue
  if [[ "${review_label,,}" == "obsolete" ]]; then
    fail "project_review pr_label is \"$review_label\" — the obsolete label is a human's own corroboration for closing a draft pull request (requirement 34k), and a stage projecting it as a configured label would corroborate the pipeline's own voids"
  fi
done < <(jq -r '[(.project_review.defaults.pr_label // ""),
                 ((.project_review.repos // [])[] | .pr_label // empty)]
                | unique | .[]' <<<"$DEFAULTED_CONFIG" 2>/dev/null)

excluded_count="$(cfg_json '.schedule.excluded_minutes' \
  | jq 'map(select(type == "number" and . >= 0 and . <= 59)) | unique | length')"
if ((excluded_count >= 60)); then
  fail "schedule.excluded_minutes excludes every minute of the hour — deploy/docker/render-crontab.sh has no minute left to choose"
elif ((excluded_count > 0)); then
  ok "schedule.excluded_minutes leaves $((60 - excluded_count)) minute(s) for this node's cycle"
fi

# Checked per configured repository, since project_review's pr_label is
# resolved per repository (requirement 342) and may no longer be the same
# value everywhere.
while IFS=$'\t' read -r review_slug review_label; do
  [[ -n "$review_slug" ]] || continue
  if [[ "$review_label" == "$(cfg '.pr_label // ""')" ]]; then
    warn "$review_slug's project_review pr_label ($review_label) equals pr_label — its review pull requests would count against max_open_agent_prs and be indistinguishable from implementation ones"
  fi
done < <(jq -r '.[] | [.slug, (.pr_label // "")] | @tsv' <<<"$project_review_repos_json")

# cycles_retained and state_local_cycles_retained both carry real schema
# defaults (200, 1000); the `0` here is pure arithmetic safety against a
# config that failed validation above and reached here with a non-numeric
# value, not a restatement of either default.
read -r cycles_retained local_retained < <(jq -r '
  def num($v): if ($v | type) == "number" then ($v | floor) else 0 end;
  [num(.cycles_retained), num(.state_local_cycles_retained)] | @tsv' <<<"$DEFAULTED_CONFIG")
if ((local_retained < cycles_retained)); then
  warn "state_local_cycles_retained ($local_retained) is below cycles_retained ($cycles_retained) — the replicated mirror would hold a longer history than the node that writes it"
fi

if [[ "$(cfg '.crash_loop_after')" != "0" && -z "$(cfg '.crash_loop_repo')" ]]; then
  warn "crash_loop_after is set but crash_loop_repo is empty, which disables both checks anyway — a fleet-wide crash loop would surface nowhere"
fi

# --- Models ---

section "Models"

while IFS=$'\t' read -r key value; do
  [[ -n "$key" ]] || continue
  if resolved="$(resolve_model_id "$key" "$value" 2>&1)"; then
    ok "$key → $resolved"
  else
    fail "$resolved"
  fi
done < <(jq -r '
  [ {k: "coordinator_model",          v: .coordinator_model},
    {k: "implementor_model_default",  v: .implementor_model_default},
    {k: "implementor_model_trivial",  v: .implementor_model_trivial},
    {k: "reviewer_model_default",     v: .reviewer_model_default},
    {k: "reviewer_model_complex",     v: .reviewer_model_complex},
    {k: "approver_model_default",     v: .approver_model_default},
    {k: "approver_model_complex",     v: .approver_model_complex},
    {k: "approver_model_critical",    v: .approver_model_critical},
    {k: "enabler_model",              v: .enabler_model},
    {k: "project_review.defaults.model", v: .project_review.defaults.model}
  ]
  + [ (.project_review.repos // [])[] | select(has("model"))
      | {k: (.slug + "'"'"'s project_review.model override"), v: .model} ]
  | .[] | select((.v // "") != "") | [.k, .v] | @tsv' "$config_file")

# --- Prompts ---

section "Prompts"

state_dir="$(cfg '.state_dir')"
[[ "$state_dir" == "~"* ]] && state_dir="$HOME${state_dir:1}"

missing_prompt=0
for prompt in coordinator implementor reviewer approver enabler project-reviewer; do
  if [[ ! -r "$SCRIPT_DIR/prompts/$prompt.md" ]]; then
    fail "prompts/$prompt.md is missing or unreadable"
    missing_prompt=1
  fi
done
((missing_prompt)) || ok "every shipped prompt is present"

# A configured override path that does not resolve is tolerated at runtime —
# files legitimately come and go — which is exactly why it is worth naming
# here: the stage quietly runs on the shipped prompt instead.
while IFS=$'\t' read -r stage mode path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    "~"*) resolved_path="$HOME${path:1}" ;;
    /*) resolved_path="$path" ;;
    *) resolved_path="$state_dir/$path" ;;
  esac
  if [[ -r "$resolved_path" ]]; then
    ok "prompt_overrides.$stage.$mode → $resolved_path"
  else
    warn "prompt_overrides.$stage.$mode names $resolved_path, which is not readable — the $stage stage runs on the shipped prompt and says nothing about it"
  fi
done < <(cfg_json '.prompt_overrides' | jq -r '
  to_entries[]
  | .key as $stage
  | ((.value.extend // [])[] | [$stage, "extend", .] | @tsv),
    (select((.value.replace // "") != "") | [$stage, "replace", .value.replace] | @tsv)')

# --- Toolchain ---

section "Toolchain"

# The pipelines' hard requirements, as deploy/docker/Dockerfile installs them.
# Without any one of these a cycle dies part-way through, having already
# claimed its work — which is the expensive way to discover it.
for tool in bash jq git curl perl python3 rsync flock timeout; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool — $(command -v "$tool")"
  else
    fail "$tool is not on PATH; the pipelines need it"
  fi
done
if command -v gh >/dev/null 2>&1; then
  ok "gh — $(gh --version 2>/dev/null | head -1)"
else
  fail "gh is not on PATH; every work source and every pull request goes through it"
fi
if command -v claude >/dev/null 2>&1; then
  ok "claude — $(claude --version 2>/dev/null | head -1)"
else
  fail "claude is not on PATH; it is the execution substrate for every stage"
fi
if command -v shellcheck >/dev/null 2>&1; then
  ok "shellcheck — $(shellcheck --version 2>/dev/null | awk '/^version:/ {print $2}')"
else
  warn "shellcheck is not on PATH — an Implementor working on shell cannot lint before it pushes"
fi

# --- Directories ---

section "Directories"

workspace_root="$(cfg '.workspace_root')"
[[ "$workspace_root" == "~"* ]] && workspace_root="$HOME${workspace_root:1}"
for entry in "state_dir=$state_dir" "workspace_root=$workspace_root"; do
  key="${entry%%=*}"
  dir="${entry#*=}"
  if [[ -z "$dir" || "$dir" == "null" ]]; then
    fail "$key is not set"
  elif mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    avail_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 {print $4}')"
    if [[ "$avail_kb" =~ ^[0-9]+$ ]] && ((avail_kb < 2 * 1024 * 1024)); then
      warn "$key ($dir) is writable but has only $((avail_kb / 1024)) MiB free — a cycle clones every repository it touches"
    else
      ok "$key ($dir) is writable"
    fi
  else
    fail "$key ($dir) cannot be created or is not writable"
  fi
done

# --- Crontab ---

section "Stage budgets"

# --- The stage budgets, and the lock derived from them (requirement 4f) --------
# This check used to be an assertion — that `lock_stale_after` exceeded the sum
# of four fixed stage timeouts — and it was warned about, adjusted by hand and
# warned about again three times in two days while those timeouts were being
# raised. The invariant is now inverted: the lock threshold is *derived* from
# the backstops in force plus slack, so it cannot be outrun, and what is left
# to report is what those numbers currently are and where each came from.
#
# Reported rather than merely computed, because that is the whole bargain of a
# self-tuning value: it is allowed to move on its own precisely because it can
# always be asked what it is and why.
config_json="$(cat "$config_file" 2>/dev/null || printf '{}')"
budget_table="$(stage_budget_table \
  "$(fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl \
     | stage_budget_observations 2>/dev/null || printf '[]')" \
  "$(stage_budget_settings "$config_json")" \
  2>/dev/null || printf '{"cells":{},"actors":{}}')"

lock_stale_sec="$(stage_budget_lock_seconds "$budget_table" \
  "$(stage_budget_all_overrides "$config_json")" \
  30 "$(jq -r '.lock_stale_after // 0' "$config_file" 2>/dev/null || printf 0)")"
ok "the cycle lock is derived at $(( lock_stale_sec / 60 )) min, from the backstops in force plus 30 min slack"

cell_count="$(jq -r '(.cells // {}) | length' <<<"$budget_table" 2>/dev/null || printf 0)"
if [[ "$cell_count" =~ ^[0-9]+$ ]] && (( cell_count > 0 )); then
  while IFS=$'\t' read -r cell backstop inactivity basis n; do
    [[ -n "$cell" ]] || continue
    ok "$cell: backstop ${backstop} min, watchdog ${inactivity} min (${basis}, n=${n})"
  done < <(jq -r '(.cells // {}) | to_entries | sort_by(.key)[]
                  | [.key, (.value.backstop_min|tostring), (.value.inactivity_min|tostring),
                     .value.basis, (.value.n|tostring)] | @tsv' <<<"$budget_table" 2>/dev/null || true)
else
  ok "no stage history yet — every stage runs on its shipped prior, which is what a first cycle should do"
fi

# A configured cap is an override that outranks the derivation for as long as
# it is there, which is easy to set once and then forget about entirely —
# at any of requirement 4f's three precedence levels: the ten top-level
# `timeout_<actor>` / `inactivity_<actor>` keys (five actors, including the
# Refiner), and every repository's own `stage_timeouts` / `stage_inactivity`
# entry, named by that repository's slug so the warning says which entry to
# edit.
while IFS= read -r overridden; do
  [[ -n "$overridden" ]] || continue
  warn "$overridden is set, which pins that cap and turns off its self-tuning — remove it unless you mean to"
done < <(jq -r '
  [ "timeout_coordinator", "timeout_implementor", "timeout_reviewer",
    "timeout_enabler", "timeout_refiner", "inactivity_coordinator",
    "inactivity_implementor", "inactivity_reviewer", "inactivity_enabler",
    "inactivity_refiner" ]
  | map(select(. as $k | ($ARGS.named.cfg[$k] | type) == "number"))[],
  ( ($ARGS.named.cfg.repos // [])[] as $r
    | ["stage_timeouts", "stage_inactivity"][] as $field
    | (($r[$field] // {}) | keys[]) as $actor
    | ($r.slug + "'"'"'s " + $field + "." + $actor) )' \
              --argjson cfg "$config_json" -n 2>/dev/null || true)
section "Crontab"

render_script="$SCRIPT_DIR/deploy/docker/render-crontab.sh"
tmpl_file="$SCRIPT_DIR/deploy/docker/crontab.tmpl"
if [[ ! -r "$tmpl_file" ]]; then
  skip "deploy/docker/crontab.tmpl is missing — cannot render the schedule"
else
  crontab_tmp_dir="$(mktemp -d)"
  node_name="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"
  if render_out="$(NODE_NAME="$node_name" "$render_script" "$tmpl_file" "$crontab_tmp_dir/crontab" "$config_file" 2>&1)"; then
    render_summary="${render_out##*$'\n'}"
    render_summary="${render_summary#*: }"
    if [[ -n "${CYCLE_MINUTE:-}" && "$render_out" != *"is not an allowed minute"* ]]; then
      minute_note="cycle minute set explicitly by CYCLE_MINUTE=$CYCLE_MINUTE"
    else
      minute_note="cycle minute hashed from node name $node_name"
    fi
    heartbeat_minutes="$(cfg '.schedule.heartbeat_minutes')"
    ok "${render_summary} — heartbeat every ${heartbeat_minutes} min ($minute_note)"
    push_minutes="$(cfg '.schedule.state_sync_push_minutes')"
    fetch_minutes="$(cfg '.schedule.state_sync_fetch_minutes')"
    rotation_minute="$(cfg '.schedule.log_rotation_minute')"
    ok "background timers — state sync push every ${push_minutes} min, fetch every ${fetch_minutes} min, log rotation at :${rotation_minute}"
  else
    fail "deploy/docker/render-crontab.sh failed against $config_file: ${render_out:-no output}"
  fi
  rm -rf "$crontab_tmp_dir"
fi

# --- Repository priority ---

section "Repository priority"

# Silent when every repo sits at nice 0 — this is a report of what the config
# already asks for (lib/repo-order.sh's `effective_age = age × 1.25^(-nice)`),
# not a check with a right answer, so there is nothing to warn or fail on.
while IFS=$'\t' read -r slug nice weight; do
  [[ -n "$slug" ]] || continue
  if [[ "$nice" == -* ]]; then
    ok "$slug: nice $nice — effective age ×$weight, earlier attention"
  else
    ok "$slug: nice $nice — effective age ×$weight, later attention"
  fi
done < <(jq -r '
  (.repos // [])[]
  | select((.nice // 0) != 0)
  | (.nice // 0) as $n
  | [.slug, ($n | tostring), (pow(1.25; -$n) * 100 | round / 100 | tostring)]
  | @tsv
' "$config_file")

# --- GitHub ---

section "GitHub"

gh_ready=0
if ((offline)); then
  skip "every GitHub check (--offline)"
elif ! command -v gh >/dev/null 2>&1; then
  skip "every GitHub check (gh is not installed)"
elif ! gh auth status >/dev/null 2>&1; then
  fail "gh is not authenticated — run 'gh auth login' or set GH_TOKEN; every work source reads through it"
else
  gh_ready=1
  ok "gh is authenticated as $(gh api user --jq .login 2>/dev/null || echo '(login unavailable)')"
fi

if ((gh_ready)); then
  # What each repository should carry comes from lib/labels.sh's catalogue —
  # the same list the cycle creates from — so this cannot report a different
  # set from the one the pipeline actually maintains (requirement 6a).
  # Fetched once per repository rather than once per label: the pipeline wants
  # several, and a repository is either reachable or it is not.
  #
  # A missing label is a warning rather than a failure because the next cycle
  # to work that repository creates it. What is worth saying is that it has not
  # happened yet: on a fresh installation that is simply "no cycle has run
  # here", and on an established one it means the token cannot create labels,
  # which nothing else would tell you.
  # REVIEW_PR_LABEL (optional) is this repository's own resolved
  # project_review pr_label (requirement 342) — only ROLE "review" needs it;
  # see lib/labels.sh's labels_catalogue for why it can no longer be derived
  # from the config alone.
  check_repo_labels() {
    local slug="$1" role="$2" review_pr_label="${3:-}" repo_labels label
    if ! repo_labels="$(gh api "repos/$slug/labels" --paginate --jq '.[].name' 2>/dev/null)"; then
      return 1
    fi
    while IFS=$'\t' read -r label _ _; do
      [[ -n "$label" ]] || continue
      grep -qixF -- "$label" <<<"$repo_labels" \
        || warn "$slug has no \"$label\" label — the next cycle that works this repo creates it (lib/labels.sh); if it is still absent after one has run, this token may not create labels"
    done < <(labels_catalogue "$config_file" "$schema_file" "$role" "$review_pr_label")
    return 0
  }

  # Write access is a separate call from the label read above: a token can
  # list a repository's labels while unable to push to it (fine-grained PATs
  # commonly split read and write this way), and that gap is exactly what
  # costs a cycle its work — it claims an item, implements it, and only then
  # discovers the push fails. `.permissions` is present only on requests
  # `gh` makes as an authenticated user, so an absent field is a fact about
  # what the API told this token, not evidence the token lacks push access —
  # hence `skip`, never `fail`, when it is missing.
  #
  # One helper for every repository's write-access verdict — target, review
  # and state_repo alike — so the three call sites cannot drift apart on what
  # counts as ok/fail/skip, the way a hand-rolled state_repo check once did:
  # its own `push == false || push == null` collapsed both into `fail`,
  # reporting a token that merely can't be asked as one that can't push.
  check_repo_access() {
    local slug="$1" ok_msg="${2:-is writable — the token can push claim branches}" \
          fail_msg="${3:-is readable but not writable with this token — a cycle would claim work here and lose it at push}" \
          unreachable_msg="${4:-is unreachable with this token — cannot confirm write access}" \
          json push archived
    if ! json="$(gh api "repos/$slug" --jq '{push: .permissions.push, archived: (.archived // false)}' 2>/dev/null)"; then
      fail "$slug $unreachable_msg"
      return
    fi
    archived="$(jq -r '.archived' <<<"$json" 2>/dev/null)"
    push="$(jq -r '.push' <<<"$json" 2>/dev/null)"
    if [[ "$archived" == "true" ]]; then
      fail "$slug is archived — no branch can be pushed to it, whatever the token's permissions"
    elif [[ "$push" == "true" ]]; then
      ok "$slug $ok_msg"
    elif [[ "$push" == "false" ]]; then
      fail "$slug $fail_msg"
    else
      skip "$slug's write permission is not visible to this token (no .permissions field) — cannot confirm push access"
    fi
  }

  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    if check_repo_labels "$slug" target; then
      ok "$slug is readable"
    else
      fail "$slug is unreachable with this token — a repository the pipeline cannot read is a work source that silently reports no work"
    fi
    check_repo_access "$slug"
  done < <(cfg '.repos[]?.slug // empty')

  # requirement 38's ruleset dependency (agent-ops#391): GitHub computes
  # `reviewDecision` against the base branch's *required* approving review
  # count, and where a repository's own ruleset sets that to 0, the field
  # never becomes `APPROVED` however many humans approve — reviewDecision
  # stayed empty on every agent-ops pull request regardless of approvals,
  # while poetic and poetic-fiddle (both requiring 1) behaved as expected.
  # `_handoff_pr_approved` (lib/handoff.sh) derives requirement 38c's own
  # "approved" verdict from the reviews list instead, so the nudge no longer
  # depends on this setting — but it cost a cross-repo investigation to find
  # in the first place, purely because nothing reported it. One read per
  # repository (plus one per candidate ruleset, the same shape the
  # closing-keyword check below already uses) turns it into a fact reported
  # here rather than rediscovered the same way again.
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    if ! ruleset_repo_json="$(gh api "repos/$slug/rulesets" 2>/dev/null)"; then
      skip "$slug's default-branch ruleset — repos/$slug/rulesets is not reachable with this token"
      continue
    fi
    required_count="" found_pr_rule=0 require_code_owner=0
    while IFS= read -r ruleset_id; do
      [[ -n "$ruleset_id" ]] || continue
      ruleset_detail="$(gh api "repos/$slug/rulesets/$ruleset_id" 2>/dev/null)" || continue
      [[ "$(jq -r '(.conditions.ref_name.include // []) | any(. == "~DEFAULT_BRANCH")' <<<"$ruleset_detail" 2>/dev/null)" == "true" ]] \
        || continue
      count="$(jq -r '[.rules[]? | select(.type == "pull_request")
                       | .parameters.required_approving_review_count] | max // empty' \
                <<<"$ruleset_detail" 2>/dev/null)"
      # A count this cannot do arithmetic on is no count at all: `max` of an
      # empty list is `null`, dropped by `// empty` above, and anything else
      # non-numeric would silently evaluate as `0` in the comparison below —
      # the one value that changes the verdict.
      [[ "$count" =~ ^[0-9]+$ ]] || continue
      # The *strictest* applicable rule wins, not the last one the API
      # happened to return. Where two active rulesets both target the default
      # branch and both carry a `pull_request` rule, GitHub enforces the
      # higher `required_approving_review_count`, so reporting whichever came
      # last could `warn` "reviewDecision never becomes APPROVED here" about a
      # repository where a second ruleset requires 1 and it does. Every target
      # repository has exactly one such ruleset today — agent-ops's second
      # active branch ruleset (the agent-ops#261 nudge-test vehicle) targets
      # `refs/heads/nudge-test/base`, not `~DEFAULT_BRANCH`, and is excluded
      # above — so this is correctness in general rather than a live fix.
      if [[ -z "$required_count" ]] || (( count > required_count )); then
        required_count="$count"
      fi
      found_pr_rule=1
      # D18 §5.3: `agent-merges-routine` and above retires code-owner review
      # (an App cannot satisfy it, and keeping it would re-summon the human
      # review the level exists to retire) — read in the same pass as the
      # count above, since it comes off the same `pull_request` rule and a
      # second walk of the same rulesets would double the API calls for no
      # new information. Any active rule on the default branch still
      # requiring it is enough; GitHub enforces the union of active rules,
      # not just the strictest one on this particular parameter.
      [[ "$(jq -r '[.rules[]? | select(.type == "pull_request")
                    | .parameters.require_code_owner_review] | any' \
                <<<"$ruleset_detail" 2>/dev/null)" == "true" ]] && require_code_owner=1
    done < <(jq -r '.[] | select(.target == "branch" and .enforcement == "active") | .id' \
              <<<"$ruleset_repo_json" 2>/dev/null)
    if ((! found_pr_rule)); then
      skip "$slug's default branch has no active ruleset requiring approving reviews — cannot report requirement 38's dependency (branch protection set outside a ruleset is not read here)"
    elif [[ "$required_count" == "0" ]]; then
      warn "$slug's default-branch ruleset requires 0 approving reviews — reviewDecision never becomes APPROVED here, however many humans approve (agent-ops#391); requirement 38c derives approval from the reviews list instead, so this is informational, not a requirement 38 fault"
    else
      ok "$slug's default-branch ruleset requires $required_count approving review(s) — reviewDecision reaches APPROVED normally"
    fi

    # D18 §5.3 (requirement 2.3b): at `agent-merges-routine` or above the
    # Approver App is meant to be the one identity clearing the pull_request
    # rule — an App cannot satisfy a code-owner requirement, so a ruleset
    # still demanding one would strand every pull request at that level
    # regardless of what the App itself does. Judged against this
    # repository's own *configured* level (top-level key, or its own
    # override) rather than the kill-switch-adjusted effective one: a switch
    # that is merely standing the ladder down today must not hide a
    # combination that breaks the moment someone clears it. At or above the
    # routine tier the pairing reports both ways — the `ok` is the only
    # positive evidence the ruleset was actually read at the one level where
    # that matters; below it the check stays silent rather than narrate a
    # pairing that does not apply to an operator at `human`.
    if ((found_pr_rule)); then
      ma_level="$(merge_autonomy_configured_level "$DEFAULTED_CONFIG" "$slug")"
      ma_rank="$(merge_autonomy_rank "$ma_level" 2>/dev/null || printf 0)"
      routine_rank="$(merge_autonomy_rank agent-merges-routine)"
      if [[ "$ma_rank" =~ ^[0-9]+$ ]] && (( ma_rank >= routine_rank )); then
        if ((require_code_owner)); then
          fail "$slug's merge_autonomy is \"$ma_level\" but its default-branch ruleset still requires code-owner review — the Approver App cannot satisfy that, and no pull request at this level would ever clear the gate (D18 §5.3)"
        else
          ok "$slug's merge_autonomy is \"$ma_level\" and its default-branch ruleset requires no code-owner review — the Approver App can clear the pull_request rule (D18 §5.3)"
        fi
      fi
    fi
  done < <(cfg '.repos[]?.slug // empty')

  while IFS=$'\t' read -r slug review_label; do
    [[ -n "$slug" ]] || continue
    check_repo_labels "$slug" review "$review_label" \
      || fail "project_review.repos names $slug, which is unreachable with this token"
    check_repo_access "$slug"
  done < <(jq -r '.[] | [.slug, (.pr_label // "")] | @tsv' <<<"$project_review_repos_json")

  state_repo="$(cfg '.state_repo')"
  if [[ -z "$state_repo" ]]; then
    ok "no state_repo configured — single-node operation, every state-sync mode is a no-op"
  else
    check_repo_access "$state_repo" \
      "is readable and writable — the fleet's shared state can replicate" \
      "is readable but not writable with this token — this node could fetch fleet state and never publish its own" \
      "is unreachable with this token — claims, fleet flags and the shared log would not replicate"
  fi

  # The D18 kill switch (requirement 2.3b) — a fleet flag, so reading it costs
  # a network call and belongs here rather than the offline Configuration
  # section above.
  ma_kill_json="$(merge_autonomy_kill_state "$state_repo" "$state_dir")"
  ma_kill_state="$(jq -r '.state' <<<"$ma_kill_json" 2>/dev/null)"
  # `!= enabled`, not `== disabled`: the same test merge_autonomy_effective_level
  # applies, so this report cannot say "not set" about a flag that is in fact
  # forcing every repo to human (an expired record reads as neither word).
  #
  # A real kill and a fail-closed synthesis both read "disabled" here, and an
  # operator needs to tell them apart (TD-PPagop-26081602). The synthesis is
  # what identifies itself — `kind: "fail-closed"`, which
  # merge_autonomy_kill_state writes and nothing else does — rather than the
  # real kill being recognised by `kind: "manual"`: a flag file an operator
  # set by hand through GitHub's web editor, and one that arrived garbled
  # (which merge_autonomy_kill_state reads as set, deliberately), are both
  # genuine kills carrying no `kind` at all, and reporting either of those as
  # "could not be confirmed clear … until a fetch succeeds" would send its
  # reader hunting a state-repo outage that is not happening — and withhold
  # the one command that clears the switch they actually have.
  if [[ "$ma_kill_state" == "enabled" ]]; then
    ok "the merge-autonomy kill switch is not set — merge_autonomy governs as configured"
  elif [[ "$(jq -r '.record.kind // ""' <<<"$ma_kill_json" 2>/dev/null)" == "fail-closed" ]]; then
    warn "the merge-autonomy kill switch could not be confirmed clear — $(jq -r '.record.reason // "state repo unreachable"' <<<"$ma_kill_json" 2>/dev/null) — every repo's effective level is forced to human until a fetch succeeds"
  else
    warn "the merge-autonomy kill switch is SET — every repo's effective level is forced to human regardless of merge_autonomy; agent-cycle.sh --restore-merge-autonomy clears it"
  fi

  if [[ -n "$enabler_assignee" ]]; then
    if gh api "users/$enabler_assignee" --jq .login >/dev/null 2>&1; then
      ok "enabler_assignee @$enabler_assignee is a GitHub account"
    else
      fail "enabler_assignee @$enabler_assignee is not a GitHub account — its escalations would be raised unassigned, and the pipeline could then select them as work"
    fi
  fi

  # closing-keyword.yml (requirement 25a) goes red on a non-conforming PR,
  # but only this repository's own branch ruleset — a setting outside any
  # file here — turns that red into a blocked merge. A ruleset drifting back
  # to report-only is invisible to every file this repository carries, which
  # is exactly the gap PR #256's review fell into (issue #240): the workflow
  # existed and was green, and the ruleset silently did not require it.
  # TD-PPagop-26080802, replacing acceptance check 8m's manual `gh api` read.
  self_repo="$(jq -r '.repo // empty' <<<"$(agent_ops_version "$SCRIPT_DIR")" 2>/dev/null)"
  if [[ -z "$self_repo" ]]; then
    skip "closing-keyword ruleset enforcement — cannot determine this repository's own slug (no build-info.json, no git remote)"
  elif ! rulesets_json="$(gh api "repos/$self_repo/rulesets" 2>/dev/null)"; then
    skip "closing-keyword ruleset enforcement — repos/$self_repo/rulesets is not reachable with this token"
  else
    found_default_ruleset=0
    while IFS= read -r ruleset_id; do
      [[ -n "$ruleset_id" ]] || continue
      ruleset_detail="$(gh api "repos/$self_repo/rulesets/$ruleset_id" 2>/dev/null)" || continue
      [[ "$(jq -r '(.conditions.ref_name.include // []) | any(. == "~DEFAULT_BRANCH")' <<<"$ruleset_detail" 2>/dev/null)" == "true" ]] \
        || continue
      found_default_ruleset=1
      ruleset_name="$(jq -r '.name' <<<"$ruleset_detail")"
      required_entry="$(jq -c '[.rules[]? | select(.type == "required_status_checks")
                                | .parameters.required_status_checks[]?
                                | select(.context == "closing-keyword")] | .[0] // empty' <<<"$ruleset_detail" 2>/dev/null)"
      if [[ -z "$required_entry" ]]; then
        warn "$self_repo's \"$ruleset_name\" branch ruleset does not require \"closing-keyword\" — the check reports without blocking the merge, the exact gap requirement 25a exists to close (issue #240)"
      elif [[ "$(jq -r '.integration_id' <<<"$required_entry")" != "15368" ]]; then
        warn "$self_repo's \"$ruleset_name\" branch ruleset requires \"closing-keyword\" without pinning integration_id 15368 — any GitHub App reporting a check of that name could satisfy it"
      else
        ok "$self_repo's \"$ruleset_name\" branch ruleset requires \"closing-keyword\", pinned to integration_id 15368 (requirement 25a)"
      fi
    done < <(jq -r '.[] | select(.target == "branch" and .enforcement == "active") | .id' <<<"$rulesets_json" 2>/dev/null)
    ((found_default_ruleset)) || warn "$self_repo has no active branch ruleset targeting the default branch — closing-keyword (requirement 25a) is not enforced by any ruleset"
  fi
fi

# --- Claude ---

section "Claude"

if ((offline)); then
  skip "Claude credentials (--offline)"
elif ! command -v claude >/dev/null 2>&1; then
  skip "Claude credentials (claude is not installed)"
elif ! claude_auth_json="$(timeout 15 claude auth status --json 2>/dev/null)"; then
  # An older CLI with no `auth` subcommand, or one that hangs and hits the
  # timeout above, exits non-zero here rather than printing anything this
  # can trust — a version gap, not a finding about this token.
  skip "claude auth status did not succeed — cannot verify credentials"
elif ! logged_in="$(jq -r '.loggedIn' <<<"$claude_auth_json" 2>/dev/null)"; then
  # -r without -e: `false` is a legitimate answer this check must tell apart
  # from a parse failure, and -e would treat both alike (its exit status
  # reflects the output *value*, not whether parsing succeeded).
  skip "claude auth status printed something other than the expected JSON — cannot verify credentials"
elif [[ "$logged_in" == "true" ]]; then
  ok "claude is authenticated ($(jq -r '.authMethod // "method unknown"' <<<"$claude_auth_json"), $(jq -r '.subscriptionType // .apiProvider // "provider unknown"' <<<"$claude_auth_json"))"
else
  fail "claude is not authenticated — every stage launches through it and would fail at the first invocation"
fi

# --- The stream really streams, on this node -----------------------------------
# The liveness watchdog (requirement 4e) reads one thing: whether the stage's
# stream file has grown lately. That is only a liveness signal if the runtime
# writes as it goes. If it buffers stdout when the destination is not a tty —
# and the evidence for this design was gathered on one machine and one CLI
# version, so another may differ — the file stays empty until the run ends and
# the watchdog kills every healthy stage at its threshold. There is no partial
# version of that failure: streaming either works on this node or the pipeline
# stops working on this node. So it is checked here, on this node, with a real
# invocation, rather than reasoned about.
#
# The cost is one call to the cheapest configured model with a one-word
# prompt — the same spend requirement 1b's usage-limit probe makes, for the
# same reason: some questions can only be answered by asking. `doctor.sh` is
# operator-invoked rather than per-cycle, and `--offline` skips it.
if ((offline)); then
  skip "stream flushing (--offline; the check costs one minimal model call)"
elif ! command -v claude >/dev/null 2>&1; then
  skip "stream flushing (claude is not installed)"
elif [[ "${logged_in:-}" != "true" ]]; then
  skip "stream flushing (needs a working credential)"
else
  flush_dir="$(mktemp -d)"
  flush_stream="$flush_dir/probe.stream.jsonl"
  claude -p --model "$(cfg '.implementor_model_trivial // "claude-haiku-4-5-20251001"')" \
    --dangerously-skip-permissions --output-format stream-json --verbose \
    <<<"Reply with the single word: ok" >"$flush_stream" 2>"$flush_dir/err" &
  flush_pid=$!
  # Sampled while the invocation is still running, which is the only way to
  # tell "wrote as it went" from "wrote everything at the end" — a finished
  # run looks identical either way.
  flush_seen=0
  flush_waited=0
  while kill -0 "$flush_pid" 2>/dev/null && (( flush_waited < 120 )); do
    if [[ -s "$flush_stream" ]]; then flush_seen=1; break; fi
    sleep 1
    flush_waited=$(( flush_waited + 1 ))
  done
  wait "$flush_pid" 2>/dev/null || true

  if (( flush_seen )); then
    ok "the stage stream flushes as it runs — the liveness watchdog has a signal to read"
  elif [[ ! -s "$flush_stream" ]]; then
    skip "stream flushing: the probe produced nothing at all, so it proves nothing about buffering ($(head -c 160 "$flush_dir/err" 2>/dev/null | tr '\n' ' ' || true))"
  else
    fail "the stage stream arrived only once the invocation had ended — stdout is buffered on this node, so the liveness watchdog would see no progress and kill every healthy stage at its inactivity threshold. Set the inactivity_* keys to 0 to disable the watchdog until this is fixed."
  fi
  rm -rf "$flush_dir"
fi

# --- Summary ---

printf '\n'
if ((fails)); then
  printf '%d failure(s), %d warning(s), %d skipped.\n' "$fails" "$warns" "$skips"
  exit 1
fi
printf 'No failures. %d warning(s), %d skipped.\n' "$warns" "$skips"
exit 0
