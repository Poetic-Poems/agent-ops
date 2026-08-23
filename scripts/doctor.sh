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
#   scripts/doctor.sh --unattended    # the full GitHub section, none of the model spend
#   scripts/doctor.sh --config PATH   # a config not yet deployed
#
# --unattended is what deploy/docker/crontab.tmpl's own hourly line runs,
# unprompted: the GitHub section (issue_priority_options_complete above all —
# agent-ops#543) is the one place configuration drift shows up only against a
# live repository, so an operator who never happens to run this by hand would
# otherwise never see it. Skips only the two checks --offline also skips for
# being network-gated, but for a different reason (see usage()); the GitHub
# section itself stays in full, since every call there is a GET. When it
# reaches the end of a run it writes state_dir/.doctor-status.json for
# scripts/publish-dashboard.sh to surface — the one write this mode adds to
# the "read-only, with two exceptions" rule above.
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
# shellcheck source=lib/escalation-autonomy.sh
source "$SCRIPT_DIR/lib/escalation-autonomy.sh"
# shellcheck source=lib/merge-queue.sh
source "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/approver-token.sh
source "$SCRIPT_DIR/lib/approver-token.sh"
# shellcheck source=lib/issue-priority.sh
source "$SCRIPT_DIR/lib/issue-priority.sh"
# doctor.sh has no other trap and exits from several points below (bad
# arguments, an unusable config, the ordinary end of a clean pass) — a single
# EXIT trap, armed as soon as the library that owns the cache directory is
# sourced, is what makes every one of those paths remove it (issue #510).
trap 'issue_priority_cache_cleanup' EXIT

usage() {
  cat >&2 <<'USAGE'
usage: doctor.sh [--config PATH] [--offline] [--unattended] [--quiet]

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
  --unattended   For a scheduled, unprompted pass (deploy/docker/crontab.tmpl's
                 hourly line): run the Configuration section and the whole
                 GitHub section — every call there is a GET, so none of it
                 costs anything a schedule shouldn't spend — but skip the two
                 checks that do spend: the Claude-credentials check and the
                 stream-flushing probe (a model call). Each is reported
                 skipped with its own reason, distinct from --offline's.
                 Also writes state_dir/.doctor-status.json, which
                 scripts/publish-dashboard.sh reads to surface this run's
                 warnings and failures. --offline already implies these two
                 skips; combining the flags adds nothing.
  --quiet        Print only warnings, failures and the summary.

Exit 0 clean, 1 at least one failure, 2 unusable arguments or config.
USAGE
}

config_file="$SCRIPT_DIR/config.json"
schema_file="$SCRIPT_DIR/config.schema.json"
offline=0
unattended=0
quiet=0
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --config)
      [[ $# -ge 2 ]] || { echo "doctor: --config needs a path" >&2; exit 2; }
      config_file="$2"; shift 2 ;;
    --offline) offline=1; shift ;;
    --unattended) unattended=1; shift ;;
    --quiet) quiet=1; shift ;;
    *) echo "doctor: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

fails=0
warns=0
skips=0
pending_section=""
# Every warn()/fail() message, in the order printed — kept only so
# --unattended's end-of-run write (write_unattended_status, defined beside
# the Summary section below) can hand scripts/publish-dashboard.sh something
# structured rather than reparsing this script's own text output.
fail_msgs=()
warn_msgs=()

# A section heading is held back until something under it prints, so --quiet
# never leaves a heading with nothing beneath it.
section() { pending_section="$1"; }
show_section() {
  [[ -n "$pending_section" ]] || return 0
  printf '\n%s\n' "$pending_section"
  pending_section=""
}
ok()   { ((quiet)) || { show_section; printf '  [ ok ] %s\n' "$1"; }; }
warn() { warns=$((warns + 1)); warn_msgs+=("$1"); show_section; printf '  [warn] %s\n' "$1"; }
fail() { fails=$((fails + 1)); fail_msgs+=("$1"); show_section; printf '  [fail] %s\n' "$1"; }
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

# issue #567: a key whose `x-docs.value` documents a specific installation's
# choice — differing from that key's own schema `default` — is itself a claim
# nothing had ever checked against the live config. `refiner_model` documented
# as `claude-haiku-4-5-20251001` while the key had never once been set in
# config.json (it silently ran the empty-string default — the stage off — for
# eight days) is exactly this failure, and it looked like a healthy install:
# every unrefined item still fell through to the ordinary Enabler path.
doc_value_mismatches="$(config_documented_value_mismatches "$DEFAULTED_CONFIG" "$schema_file")"
if [[ -n "$doc_value_mismatches" ]]; then
  while IFS=$'\t' read -r dvm_key dvm_doc dvm_resolved; do
    [[ -n "$dvm_key" ]] || continue
    warn "$dvm_key is documented (README.md/docs/IMPLEMENTATION-PIPELINE-SPEC.md) as $dvm_doc but resolves to $dvm_resolved from $config_file — the documentation describes an installation that does not exist"
  done <<<"$doc_value_mismatches"
else
  ok "every documented installation value (x-docs.value differing from its own default) matches config.json"
fi

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

# D18 (agent-ops#627): `escalation_autonomy`'s `adjudicate-first` runs one
# extra Enabler engagement per refinement-disagreement escalation, so it is a
# configuration nobody can act on with the Enabler itself disabled — the same
# pairing check merge_autonomy's own block runs against approver_app_id
# above. Checked against every configured *source* of a level, on the same
# terms as merge_autonomy_sources below: the top-level key and each repo's
# own override, not the level each repo is effectively governed by.
escalation_autonomy_sources="$(jq -r '
  [{label: "escalation_autonomy", level: (.escalation_autonomy // "always-escalate")}]
  + [(.repos // [])[] | select(has("escalation_autonomy"))
     | {label: (.slug + "'"'"'s escalation_autonomy override"), level: .escalation_autonomy}]
  | .[] | [.label, .level] | @tsv' <<<"$DEFAULTED_CONFIG" 2>/dev/null || true)"
if [[ -n "$escalation_autonomy_sources" ]]; then
  while IFS=$'\t' read -r ea_label ea_level; do
    [[ -n "$ea_label" ]] || continue
    if [[ "$ea_level" == "adjudicate-first" && -z "$enabler_model" ]]; then
      warn "$ea_label is \"adjudicate-first\" but enabler_model is empty — the Enabler is disabled, so no refinement-disagreement escalation is ever raised for an adjudication pass to run before"
    else
      ok "$ea_label is \"$ea_level\""
    fi
  done <<<"$escalation_autonomy_sources"
else
  warn "escalation_autonomy could not be resolved from $config_file — the schema check above should already have failed this"
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
# also trusted at agent-merges-routine or above is worth surfacing: at that
# level the arming step (requirement 8d) may land pull requests itself, and
# an operator is better told the budget will not bound that before it
# happens than after. Judged against the *configured* level, not the
# kill-switch/freeze-adjusted effective one, for the same reason the
# merge_autonomy pairing check above is.
while IFS= read -r mb_slug; do
  [[ -n "$mb_slug" ]] || continue
  mb_level="$(merge_autonomy_configured_level "$DEFAULTED_CONFIG" "$mb_slug")"
  mb_rank="$(merge_autonomy_rank "$mb_level" 2>/dev/null || printf 0)"
  mb_routine_rank="$(merge_autonomy_rank agent-merges-routine)"
  mb_cap="$(merge_budget_effective_cap "$DEFAULTED_CONFIG" "$mb_slug")"
  if (( mb_rank >= mb_routine_rank )) && [[ "$mb_cap" == "0" ]]; then
    warn "$mb_slug's merge_autonomy is \"$mb_level\" with merge_budget_per_day unlimited (0) — no cap will bound its landing rate"
  fi
done < <(cfg '.repos[]?.slug // empty')

# D18 WI-12 (Stage 4, agent-ops#415): landing_cool_off_hours, reported per
# configured source the same way merge_budget_per_day is above — the
# top-level key and each repo's own override.
landing_cool_off_sources="$(jq -r '
  [{label: "landing_cool_off_hours", hours: (.landing_cool_off_hours // 24)}]
  + [(.repos // [])[] | select(has("landing_cool_off_hours"))
     | {label: (.slug + "'"'"'s landing_cool_off_hours override"), hours: .landing_cool_off_hours}]
  | .[] | [.label, (.hours | tostring)] | @tsv' <<<"$DEFAULTED_CONFIG" 2>/dev/null || true)"
if [[ -n "$landing_cool_off_sources" ]]; then
  while IFS=$'\t' read -r lc_label lc_hours; do
    [[ -n "$lc_label" ]] || continue
    ok "$lc_label is ${lc_hours}h$([[ "$lc_hours" == "0" ]] && printf ' (no wait)')"
  done <<<"$landing_cool_off_sources"
fi
# A repository trusted at agent-merges-all with landing_cool_off_hours
# resolved to 0 disables D18 WI-12's own cool-off control entirely — worth
# surfacing before a protected-path pull request lands on the strength of
# the critical-tier control alone, since §7 risk 1's residual risk is
# accepted only with both compensating controls in force. Judged against the
# *configured* level, not the kill-switch/freeze-adjusted effective one, the
# same reason the merge_autonomy pairing check above is.
while IFS= read -r lc_slug; do
  [[ -n "$lc_slug" ]] || continue
  lc_level="$(merge_autonomy_configured_level "$DEFAULTED_CONFIG" "$lc_slug")"
  lc_rank="$(merge_autonomy_rank "$lc_level" 2>/dev/null || printf 0)"
  lc_all_rank="$(merge_autonomy_rank agent-merges-all)"
  lc_hours="$(jq -r --arg slug "$lc_slug" \
    '(.repos // [])[] | select(.slug == $slug) | .landing_cool_off_hours // empty' \
    <<<"$DEFAULTED_CONFIG" 2>/dev/null | head -1)"
  [[ -n "$lc_hours" ]] || lc_hours="$(jq -r '.landing_cool_off_hours // 24' <<<"$DEFAULTED_CONFIG" 2>/dev/null)"
  if (( lc_rank >= lc_all_rank )) && [[ "$lc_hours" == "0" ]]; then
    warn "$lc_slug's merge_autonomy is \"$lc_level\" with landing_cool_off_hours 0 — a protected-path pull request lands the moment its critical-tier Approver review stands, with no fleet-day observation window (D18 WI-12)"
  fi
done < <(cfg '.repos[]?.slug // empty')

# D18 WI-7 (requirement 8d): merge_autonomy_routine_sources names which work
# sources the arming step may land automatically at agent-merges-routine and
# above. An entry naming a source this repository's own `sources` list never
# gathers can never be selected, let alone armed — dead configuration nobody
# would notice until they went looking for why nothing autonomous ever lands
# from it. Checked per repository, against that repository's own effective
# list (its own override, else the top-level key, else the shipped default),
# never fleet-wide: a source missing from one repository's `sources` may be
# present in another's.
#
# The two lists speak deliberately different vocabularies (agent-ops#558):
# `sources` is banded (`issues:high`), the routine list is not (`issues`),
# because a work order's own `source` has lost its band by the time landing
# compares it. A naive set difference would therefore report a correctly
# configured bare `issues` as ungathered — the fix reported as the fault —
# so the routine side is normalised first: `issues` counts as gathered when
# the repository's `sources` carry any `issues:<band>` at all. Every other
# token is identical in both vocabularies and compares unchanged.
while IFS= read -r rs_slug; do
  [[ -n "$rs_slug" ]] || continue
  rs_missing="$(jq -r --arg slug "$rs_slug" '
    ((.repos // [])[] | select(.slug == $slug)) as $r
    | ($r.merge_autonomy_routine_sources // .merge_autonomy_routine_sources
       // ["register-hygiene","tech-debt"]) as $routine
    | ($r.sources // []) as $have
    | (if ($have | any(startswith("issues"))) then $have + ["issues"] else $have end) as $have
    | ($routine - $have) | .[]
  ' <<<"$DEFAULTED_CONFIG" 2>/dev/null | paste -sd, - || true)"
  if [[ -n "$rs_missing" ]]; then
    warn "$rs_slug's merge_autonomy_routine_sources names [$rs_missing], which its own sources list never gathers — a routine source this repository never produces can never be selected, let alone armed (D18 WI-7)"
  else
    ok "$rs_slug's merge_autonomy_routine_sources are all sources it actually gathers"
  fi
  # A banded `issues:<band>` token validates clean against the check above —
  # it is typically present in the repository's own `sources` list too — but
  # can still never match a work order: every `issues:<band>` candidate's own
  # `source` collapses to the plain word "issues" the moment it becomes a
  # work order (scripts/gather-issues.sh), before landing_eligible's exact
  # string comparison ever runs (lib/landing.sh's own header). Left
  # unreported, that reads as a clean doctor run and a silent, permanent
  # never-match (#519).
  rs_banded="$(jq -r --arg slug "$rs_slug" '
    ((.repos // [])[] | select(.slug == $slug)) as $r
    | ($r.merge_autonomy_routine_sources // .merge_autonomy_routine_sources
       // ["register-hygiene","tech-debt"])
    | map(select(startswith("issues:"))) | .[]
  ' <<<"$DEFAULTED_CONFIG" 2>/dev/null | paste -sd, - || true)"
  if [[ -n "$rs_banded" ]]; then
    warn "$rs_slug's merge_autonomy_routine_sources names [$rs_banded], a banded issues:<band> token — every issues:<band> work order's own source collapses to the plain word \"issues\" before landing_eligible's comparison ever runs (lib/landing.sh's own header), so this entry can never match a work order; list \"issues\" itself if this repository should land issues work routinely (D18 WI-7)"
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
# alone is projected onto every draft the Implementer raises. Case-insensitive,
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
    {k: "implementer_model_default",  v: .implementer_model_default},
    {k: "implementer_model_trivial",  v: .implementer_model_trivial},
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
for prompt in coordinator implementer reviewer approver enabler project-reviewer; do
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
  warn "shellcheck is not on PATH — an Implementer working on shell cannot lint before it pushes"
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
# at any of requirement 4f's three precedence levels: the twelve top-level
# `timeout_<actor>` / `inactivity_<actor>` keys (six actors, including the
# Refiner and the Approver), and every repository's own `stage_timeouts` /
# `stage_inactivity` entry, named by that repository's slug so the warning
# says which entry to edit.
while IFS= read -r overridden; do
  [[ -n "$overridden" ]] || continue
  warn "$overridden is set, which pins that cap and turns off its self-tuning — remove it unless you mean to"
done < <(jq -r '
  [ "timeout_coordinator", "timeout_implementer", "timeout_reviewer",
    "timeout_approver", "timeout_enabler", "timeout_refiner",
    "inactivity_coordinator", "inactivity_implementer", "inactivity_reviewer",
    "inactivity_approver", "inactivity_enabler", "inactivity_refiner" ]
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
  # D18 Stage 3 (agent-ops#575): facts about each repository's forge
  # configuration, gathered as the ruleset and merge-settings/merge-queue
  # passes below already walk every repository, and read back afterwards by
  # the one consolidated autonomy-readiness verdict per repository — so that
  # verdict costs no API call of its own beyond what each individual check
  # already made.
  declare -A ra_ruleset_readable ra_found_pr_rule ra_required_count \
    ra_require_code_owner ra_dismiss_stale_ok ra_bypass_count ra_merge_path_ok

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

  # requirement 39g: the Refiner's Priority triage duty (issue #414) depends
  # on a `Priority` `IssueFieldSingleSelect` this token can read, carrying
  # all four band names — nothing else here would tell an operator that duty
  # is silently doing nothing in a repository. Checked only where the issues
  # source is actually configured, the same gate the cycle's own gather uses
  # (`startswith("issues")`, agent-cycle.sh), since a repository that never
  # gathers issues has nothing for the duty to act on either way. That gate
  # has to be the prefix and not `== "issues"`: the source is one source at
  # four ranks and the schema's `sources` enum offers only the four banded
  # tokens (`issues:urgent` … `issues:low`), so an equality test against the
  # bare name matches no valid configuration at all and this check would
  # never run.
  check_priority_field() {
    local slug="$1" field_json
    if field_json="$(issue_priority_field_ids "$slug" 2>/dev/null)"; then
      if issue_priority_options_complete "$field_json"; then
        ok "$slug's Priority field is readable and carries all four bands"
      else
        warn "$slug's Priority field is readable but is missing one of Urgent/High/Medium/Low — the Refiner's triage duty can band only the options actually present"
      fi
    else
      warn "$slug exposes no readable Priority field to this token — the Refiner's triage duty (and requirement 15e's own ranking) silently treats every issue as Medium here"
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
    if jq -e --arg s "$slug" \
         '(.repos[] | select(.slug == $s) | .sources // []) | any(startswith("issues"))' \
         <<<"$DEFAULTED_CONFIG" >/dev/null 2>&1; then
      check_priority_field "$slug"
    fi
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
      ra_ruleset_readable[$slug]=0
      continue
    fi
    ra_ruleset_readable[$slug]=1
    required_count="" found_pr_rule=0 require_code_owner=0 dismiss_stale_ok=1 bypass_count=0
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
      # D18 Stage 3 (agent-ops#575): a stale review — one left over from
      # before the pull request's last push — must not still count once the
      # code has moved; without dismiss_stale_reviews_on_push a landed
      # Approver review from an earlier commit stays valid forever. Read off
      # the same `pull_request` rule and the same active-default-branch pass
      # as the two checks above, for the same reason: a second walk of the
      # same rulesets would double the API calls for no new information. Any
      # active rule reporting it *off* (or unset, GitHub's own default) is
      # enough to fail this precondition — the union-of-active-rules
      # reasoning above runs the other way here, since what is wanted is
      # universal coverage, not any one rule opting in.
      [[ "$(jq -r '[.rules[]? | select(.type == "pull_request")
                    | (.parameters.dismiss_stale_reviews_on_push // false)] | all' \
                <<<"$ruleset_detail" 2>/dev/null)" == "true" ]] || dismiss_stale_ok=0
      # A ruleset's own bypass_actors (its own field, not a rule parameter)
      # names identities that can push straight past every rule it declares,
      # the Approver gate included — a precondition on the ruleset as a
      # whole, summed across every active default-branch ruleset this
      # repository carries.
      this_bypass="$(jq -r '(.bypass_actors // []) | length' <<<"$ruleset_detail" 2>/dev/null)"
      [[ "$this_bypass" =~ ^[0-9]+$ ]] && bypass_count=$(( bypass_count + this_bypass ))
    done < <(jq -r '.[] | select(.target == "branch" and .enforcement == "active") | .id' \
              <<<"$ruleset_repo_json" 2>/dev/null)
    ra_found_pr_rule[$slug]=$found_pr_rule
    ra_required_count[$slug]="$required_count"
    ra_require_code_owner[$slug]=$require_code_owner
    ra_dismiss_stale_ok[$slug]=$dismiss_stale_ok
    ra_bypass_count[$slug]=$bypass_count
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
        # D18 Stage 3 (agent-ops#575): the two remaining ruleset preconditions
        # a repository needs before this level's forge configuration is
        # trustworthy — stale-review dismissal, and no bypass actor able to
        # skip the gate outright.
        if ((dismiss_stale_ok)); then
          ok "$slug's merge_autonomy is \"$ma_level\" and its default-branch ruleset dismisses stale reviews on push — an Approver review cannot outlive the commit it reviewed (D18 Stage 3, agent-ops#575)"
        else
          fail "$slug's merge_autonomy is \"$ma_level\" but its default-branch ruleset does not dismiss stale reviews on push — a pull request could land on an Approver review left over from before its last change (D18 Stage 3, agent-ops#575)"
        fi
        if (( bypass_count > 0 )); then
          fail "$slug's merge_autonomy is \"$ma_level\" but its default-branch ruleset names $bypass_count bypass actor(s) — a bypass actor can land a pull request around the Approver gate entirely (D18 Stage 3, agent-ops#575)"
        else
          ok "$slug's merge_autonomy is \"$ma_level\" and its default-branch ruleset names no bypass actor — nothing can land around the Approver gate (D18 Stage 3, agent-ops#575)"
        fi
      fi
    fi
  done < <(cfg '.repos[]?.slug // empty')

  # agent-ops#532 (D18 WI-7 follow-up): `landing_arm`'s no-queue fallback is
  # `gh pr merge --auto --squash`, a call that needs *two* of the
  # repository's own merge settings, not one — `allow_auto_merge` and
  # `allow_squash_merge` — and which GitHub refuses outright when either is
  # off, neither of them something `merge_autonomy` itself validates. A
  # repository that merges by rebase or merge commit is an ordinary
  # configuration, so checking only the first would hand exactly that
  # installation a green all-clear on the very failure mode this check
  # exists to catch. Below the routine tier `landing_arm` is unreachable at
  # all, so the check stays silent there; judged against each repository's
  # *configured* level, the same "an operator raising the level later must
  # not discover this for the first time as a stuck landing-refused loop"
  # reasoning the pairing check above already uses.
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    aam_level="$(merge_autonomy_configured_level "$DEFAULTED_CONFIG" "$slug")"
    aam_rank="$(merge_autonomy_rank "$aam_level" 2>/dev/null || printf 0)"
    aam_routine_rank="$(merge_autonomy_rank agent-merges-routine)"
    if [[ ! "$aam_rank" =~ ^[0-9]+$ ]] || (( aam_rank < aam_routine_rank )); then
      continue
    fi

    if ! aam_repo_json="$(gh api "repos/$slug" --jq '{auto: .allow_auto_merge, squash: .allow_squash_merge, default_branch: .default_branch}' 2>/dev/null)"; then
      skip "$slug's merge-settings/merge-queue pairing — repos/$slug is not reachable with this token"
      continue
    fi
    aam_auto="$(jq -r '.auto' <<<"$aam_repo_json" 2>/dev/null)"
    aam_squash="$(jq -r '.squash' <<<"$aam_repo_json" 2>/dev/null)"
    aam_default_branch="$(jq -r '.default_branch' <<<"$aam_repo_json" 2>/dev/null)"
    if [[ -z "$aam_default_branch" || "$aam_default_branch" == "null" ]]; then
      skip "$slug's merge-settings/merge-queue pairing — repos/$slug did not report a default_branch"
      continue
    fi
    if ! aam_queue_json="$(merge_queue_for_branch "$slug" "$aam_default_branch")"; then
      skip "$slug's merge-settings/merge-queue pairing — could not read $aam_default_branch's merge-queue state"
      continue
    fi

    # Sort the two settings into "read as a definite `false`" and "not
    # reported at all", so the verdict chain below can test the first before
    # the second: an unreadable sibling must never mask a setting doctor did
    # read as off. Both are classified only once the queue read has already
    # reported no queue, since that is the one branch whose verdict either
    # value changes. `repos/$slug` carries these keys only for a token with
    # admin visibility of the repository's merge settings — verified live
    # 2026-08-18: the same token that reads `true` for both on
    # Poetic-Poems/agent-ops (where it is an admin) gets neither key at all
    # from cli/cli. `jq -r` renders that absence as the string `null`, which
    # is *unknown*, not `false`: reading it as `false` would fail an
    # installation, exit code and all, for a setting doctor never got to see.
    # Unreadable is a skip, exactly as an unreachable repository or
    # merge-queue state above is.
    aam_off=""
    aam_unknown=""
    for aam_pair in "allow_auto_merge:$aam_auto" "allow_squash_merge:$aam_squash"; do
      aam_key="${aam_pair%%:*}"
      aam_value="${aam_pair#*:}"
      if [[ "$aam_value" == "false" ]]; then
        aam_off="${aam_off:+$aam_off and }$aam_key"
      elif [[ "$aam_value" != "true" ]]; then
        aam_unknown="${aam_unknown:+$aam_unknown and }$aam_key"
      fi
    done

    if [[ "$aam_queue_json" != "null" ]]; then
      ok "$slug's merge_autonomy is \"$aam_level\" and $aam_default_branch carries an active merge queue — landing_arm enqueues regardless of allow_auto_merge and allow_squash_merge"
      ra_merge_path_ok[$slug]=1
    elif [[ -n "$aam_off" ]]; then
      fail "$slug's merge_autonomy is \"$aam_level\" with no merge queue on $aam_default_branch and $aam_off disabled — landing_arm's no-queue fallback, gh pr merge --auto --squash, would be refused outright; enable $aam_off on $slug or adopt a merge queue on $aam_default_branch"
      ra_merge_path_ok[$slug]=0
    elif [[ -n "$aam_unknown" ]]; then
      skip "$slug's merge-settings/merge-queue pairing — $aam_default_branch carries no merge queue and repos/$slug did not report $aam_unknown (this token cannot see $slug's merge settings)"
      ra_merge_path_ok[$slug]=-1
    else
      # Deliberately claims only what was read. Repository settings are a
      # necessary condition for the fallback call, not a sufficient one —
      # agent-ops#553 is open on whether GitHub accepts `--auto` at all for a
      # pull request `run_landing_stage` has already established as mergeable
      # — so this states the settings and stops there.
      ok "$slug's merge_autonomy is \"$aam_level\" with no merge queue on $aam_default_branch, but allow_auto_merge and allow_squash_merge are both enabled — no repository setting refuses landing_arm's no-queue fallback"
      ra_merge_path_ok[$slug]=1
    fi
  done < <(cfg '.repos[]?.slug // empty')

  # D18 Stage 3 (agent-ops#575): the Approver App installation's actual
  # granted permissions, read live rather than assumed from approver_app_id
  # alone — an installation can be re-scoped through GitHub's own consent
  # screen at any time, entirely outside config.json. Exactly three
  # permissions are needed, no more and no less: contents:write (push a
  # review's own comments and, at agent-merges-routine+, land), metadata:read
  # (read the repository at all) and pull_requests:write (submit the review).
  # Fleet-wide, not per-repository — one installation backs every repository
  # this identity reviews — so this is a single check, gated the same way the
  # runtime-credential check above is (component 14's ma_above_human, and
  # only once the credential is present enough to ask; an absent credential
  # is already warned about there, and asking again here would only fail the
  # same way a second time).
  app_permissions_verdict="unknown"
  if (( ma_above_human )) && approver_token_credential_present; then
    if perms_json="$(approver_token_installation_permissions "" 2>/dev/null)"; then
      perms_gap="$(jq -rn --argjson want '{"contents":"write","metadata":"read","pull_requests":"write"}' \
                   --argjson got "$perms_json" '
        ($want | keys_unsorted) as $wanted
        | ($got  | keys_unsorted) as $granted
        | ([$wanted[] | select(($got[.] // "") != $want[.])
            | if ($got[.] // "") == "" then "\(.) missing" else "\(.) is \($got[.]), needs \($want[.])" end]
          + [$granted[] | select(($want[.] // "") == "") | "\(.) granted but not required"]
          ) as $problems
        | ($problems | join("; "))
      ' 2>/dev/null)"
      if [[ -z "$perms_gap" ]]; then
        ok "the Approver App installation carries exactly contents:write, metadata:read and pull_requests:write (D18 Stage 3, agent-ops#575)"
        app_permissions_verdict="ok"
      else
        fail "the Approver App installation's live permissions do not match what this fleet needs: $perms_gap — an owner act, only the installer can regrant them (D18 Stage 3, agent-ops#575)"
        app_permissions_verdict="fail"
      fi
    else
      skip "the Approver App installation's live permissions — GitHub did not answer /app/installations/<id>, or the response could not be read (network failure, or PULLWRIGHT_APPROVER_INSTALLATION_ID/PULLWRIGHT_APPROVER_APP_ID do not name a real installation)"
    fi
  fi

  # The same installation's *repository selection* (D18 Stage 3,
  # agent-ops#721). Permissions say what the App may do; the selection says
  # where it may do it, and an installation scoped to `selected` can leave a
  # configured repository out with nothing in config.json the wiser — a
  # readiness verdict that checked only the permissions would report "fully
  # supported" over an App that cannot see the repository at all. Read once,
  # fleet-wide, like the permissions above; `all` is the whole-account
  # selection, in which case every repository is covered by construction.
  # Unreadable is left as the empty string and reported per repository as
  # unconfirmed, never as "not covered": a repository the App genuinely
  # cannot see is a `fail` and an owner act, and no network failure should
  # ever be able to mint one of those.
  app_repos_list=""
  app_repos_readable=0
  if (( ma_above_human )) && approver_token_credential_present; then
    if app_repos_list="$(approver_token_installation_repositories "" 2>/dev/null)"; then
      app_repos_readable=1
    else
      app_repos_list=""
      skip "which repositories the Approver App installation covers — GitHub did not answer /installation/repositories, or the listing came back incomplete (D18 Stage 3, agent-ops#721)"
    fi
  fi

  # --- D18 Stage 3 (#575): one consolidated autonomy-readiness verdict per
  # repository, gathering every forge precondition above into the one
  # question an operator raising a repository's level actually has: is its
  # *configured* merge_autonomy something its forge configuration can
  # actually support right now, and if not, exactly which precondition is
  # missing and whether only a repository/org admin can fix it (an "owner
  # act") or this fleet's own config.json is (a "configuration error"). A
  # repository configured above what its forge supports is a doctor `fail`,
  # never a `warn`: the pipeline would raise approvals or land pull requests
  # nobody has verified the forge can actually clear. Below `agent-approves`
  # (`human`) there is nothing to verify, so the check stays silent there,
  # the same convention every per-repository pairing check above already
  # follows. A precondition this run could not evaluate — an unreachable
  # ruleset, an unreadable merge setting, an unconfirmed installation
  # permission — is never read as a gap: it is named separately as
  # "unconfirmed", and only turns the verdict into a `skip` ("readiness could
  # not be fully confirmed") when nothing else is definitely missing, never a
  # `fail` for something this run simply could not check.
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    ra_level="$(merge_autonomy_configured_level "$DEFAULTED_CONFIG" "$slug")"
    ra_rank="$(merge_autonomy_rank "$ra_level" 2>/dev/null || printf 0)"
    ra_routine_rank="$(merge_autonomy_rank agent-merges-routine)"
    [[ "$ra_rank" =~ ^[0-9]+$ ]] || continue
    (( ra_rank >= 1 )) || continue

    missing=()
    unconfirmed=()
    [[ -n "$approver_app_id" ]] || missing+=("approver_app_id is not set (configuration error)")
    [[ -n "$approver_model_default_cfg" ]] || missing+=("approver_model_default is not set (configuration error)")

    if (( ra_rank >= ra_routine_rank )); then
      if [[ "${ra_ruleset_readable[$slug]:-0}" != "1" ]]; then
        unconfirmed+=("its default-branch ruleset was not reachable with this token")
      elif [[ "${ra_found_pr_rule[$slug]:-0}" != "1" ]]; then
        missing+=("no active default-branch ruleset requires approving reviews (owner act)")
      else
        [[ "${ra_required_count[$slug]}" != "0" ]] \
          || missing+=("the ruleset requires 0 approving reviews (owner act)")
        [[ "${ra_require_code_owner[$slug]}" == "0" ]] \
          || missing+=("the ruleset still requires code-owner review (owner act)")
        [[ "${ra_dismiss_stale_ok[$slug]}" == "1" ]] \
          || missing+=("the ruleset does not dismiss stale reviews on push (owner act)")
        [[ "${ra_bypass_count[$slug]}" == "0" ]] \
          || missing+=("the ruleset names ${ra_bypass_count[$slug]} bypass actor(s) (owner act)")
      fi

      case "${ra_merge_path_ok[$slug]:-2}" in
        1) : ;;
        0) missing+=("no merge queue and allow_auto_merge/allow_squash_merge are not both enabled (owner act)") ;;
        -1) unconfirmed+=("allow_auto_merge/allow_squash_merge could not be read with this token") ;;
        # Every remaining case is an unset entry, and at this rank that can
        # only mean the merge-path pass above reached one of its own three
        # skip-and-continue paths — repos/<slug> unreachable, no
        # default_branch reported, or the merge-queue state unreadable. It
        # was attempted and could not be read, which is not the same as
        # never having been looked at, and the skip line above already names
        # which of the three it was.
        *) unconfirmed+=("its merge-settings/merge-queue pairing could not be read") ;;
      esac
    fi

    # The Approver App's live permissions are a precondition from
    # agent-approves upward, not just agent-merges-routine upward:
    # pull_requests:write is what lets the App post a review at all, so a
    # narrowed installation is exactly as fatal to "agent-approves is
    # supported" as it is to "agent-merges-routine is supported".
    case "$app_permissions_verdict" in
      ok) : ;;
      fail) missing+=("the Approver App installation's live permissions do not match exactly what this fleet needs (owner act)") ;;
      *) unconfirmed+=("the Approver App installation's live permissions could not be confirmed") ;;
    esac

    # And that those permissions reach *this* repository (agent-ops#721). The
    # comparison is on the full `owner/name`, case-insensitively, because that
    # is what GitHub returns and what config.json carries; `all` short-circuits
    # it, being the whole-account selection.
    if (( app_repos_readable )); then
      if [[ "$app_repos_list" != "all" ]] \
         && ! grep -qixF -- "$slug" <<<"$app_repos_list"; then
        missing+=("the Approver App installation does not cover $slug — add it to the installation's repository selection (owner act)")
      fi
    elif (( ma_above_human )) && approver_token_credential_present; then
      unconfirmed+=("which repositories the Approver App installation covers could not be read")
    fi

    missing_str="$(printf '%s; ' "${missing[@]}")"; missing_str="${missing_str%; }"
    unconfirmed_str="$(printf '%s; ' "${unconfirmed[@]}")"; unconfirmed_str="${unconfirmed_str%; }"

    if (( ${#missing[@]} > 0 )); then
      fail "$slug is configured at \"$ra_level\" but its forge configuration does not support it — missing: $missing_str$( (( ${#unconfirmed[@]} > 0 )) && printf '; also unconfirmed: %s' "$unconfirmed_str" ) (D18 Stage 3, agent-ops#575)"
    elif (( ${#unconfirmed[@]} > 0 )); then
      skip "$slug's autonomy readiness at \"$ra_level\" could not be fully confirmed — unconfirmed: $unconfirmed_str (D18 Stage 3, agent-ops#575)"
    else
      ok "$slug's autonomy readiness: \"$ra_level\" is fully supported by its forge configuration (D18 Stage 3, agent-ops#575)"
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
elif ((unattended)); then
  skip "Claude credentials (--unattended; a scheduled pass must not read a credential)"
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
elif ((unattended)); then
  skip "stream flushing (--unattended; the check costs one minimal model call, which a scheduled pass must not spend)"
elif ! command -v claude >/dev/null 2>&1; then
  skip "stream flushing (claude is not installed)"
elif [[ "${logged_in:-}" != "true" ]]; then
  skip "stream flushing (needs a working credential)"
else
  flush_dir="$(mktemp -d)"
  flush_stream="$flush_dir/probe.stream.jsonl"
  claude -p --model "$(cfg '.implementer_model_trivial // "claude-haiku-4-5-20251001"')" \
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

# --unattended's own artefact (agent-ops#543): scripts/publish-dashboard.sh
# reads this rather than re-running the GitHub section itself, which would
# cost several API calls per configured repository every heartbeat instead of
# once an hour. Written only from this, the normal end-of-run path — the
# "unusable configuration" exits far above bail before state_dir is even
# known, so a broken config produces no dashboard artefact here; the crontab
# render itself already fails loudly elsewhere in that state (entrypoint.sh).
# Best-effort: a state_dir that cannot be written to is exactly what the
# Directories section above already reported as a fail, and this must not
# mask that behind a second, unrelated failure of its own.
write_unattended_status() {
  local dir="$1" ts verdict tmp fail_json warn_json
  [[ -n "$dir" && "$dir" != "null" ]] || return 0
  mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]] || return 0
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ((fails)); then verdict="fail"; elif ((warns)); then verdict="warn"; else verdict="ok"; fi
  fail_json="$(printf '%s\n' "${fail_msgs[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null)"
  warn_json="$(printf '%s\n' "${warn_msgs[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))' 2>/dev/null)"
  [[ -n "$fail_json" ]] || fail_json='[]'
  [[ -n "$warn_json" ]] || warn_json='[]'
  tmp="$(mktemp "$dir/.doctor-status.json.XXXXXX" 2>/dev/null)" || return 0
  if jq -n --arg ts "$ts" --arg verdict "$verdict" \
        --argjson fails "$fail_json" --argjson warns "$warn_json" --argjson skips "$skips" \
        '{timestamp: $ts, verdict: $verdict, fails: $fails, warns: $warns, skips: $skips}' \
        > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dir/.doctor-status.json"
  else
    rm -f "$tmp"
  fi
}
((unattended)) && write_unattended_status "$state_dir"

# --- Summary ---

printf '\n'
if ((fails)); then
  printf '%d failure(s), %d warning(s), %d skipped.\n' "$fails" "$warns" "$skips"
  exit 1
fi
printf 'No failures. %d warning(s), %d skipped.\n' "$warns" "$skips"
exit 0
