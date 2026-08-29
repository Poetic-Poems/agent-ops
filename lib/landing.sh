#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/landing.sh — the deterministic eligibility classifier and the arming
# step (D18 WI-7, docs/reviews/2026-08-14-autonomy-investigation.md §5.1,
# §6, §7; agent-ops#410).
#
# This is the one place in the pipeline where a pull request's landing is
# armed without a human click — never a prompt's job (no model call happens
# anywhere in this file), and never a judgement call: every function below
# is plain code, printing a fixed vocabulary an interpreter never has to
# guess at. `landing_eligible` is the classifier (requirement 8d): given a
# pull request's already-resolved complexity, source and effective
# `merge_autonomy` level, does it qualify for automatic landing at all?
# `landing_arm` is the one write — enqueue where the base branch has a
# merge queue, `gh pr merge --auto --squash` where it does not — performed
# under the Approver App's own minted token, never the owner PAT, so the
# two-identity audit trail §5.3 exists for survives the write that actually
# lands a pull request, not only the review that approved it.
#
# ## The no-queue fallback does not always arm anything (agent-ops#553)
#
# `gh pr merge --auto --squash` reads as "arm auto-merge and let GitHub fire
# it later", but that is only true from `mergeStateStatus: BLOCKED` (a
# required check still pending) — the one state where it genuinely calls
# `enablePullRequestAutoMerge` and returns with the pull request still open.
# From `CLEAN` and `UNSTABLE` (every required check already passed, whether
# or not a non-required one is still running) `gh` instead detects the pull
# request is already mergeable and issues `mergePullRequest` directly, so
# the call merges it immediately rather than arming anything — confirmed
# live against `gh 2.96.0` (2026-08-18, agent-ops#553) with `GH_DEBUG=api`
# showing no `enablePullRequestAutoMerge` mutation sent from either state.
# Since `run_landing_stage` only ever reaches `landing_arm` once
# `review_gate_verdict` has already read `clean`, the immediate-merge path
# is the one this pipeline actually takes whenever the no-queue fallback
# fires at all. This is a property of the **`gh` CLI version**, not of the
# GitHub API — the `Pull request is in clean status` refusal older reports
# describe is a `enablePullRequestAutoMerge` error current `gh` simply never
# sends from an already-mergeable pull request — and `deploy/docker/
# Dockerfile` installs `gh` unpinned from GitHub's own apt repository (lines
# 85–93), so a later image rebuild can move this behaviour without any
# change in this file. `UNSTABLE`'s immediate merge carries its own
# behavioural caveat, filed separately as TD-PPagop-26082101.
#
# `agent-cycle.sh`'s own arming block (`run_landing_stage`, immediately
# after `run_approver_stage`) is what re-reads every other gate fresh at the
# moment of decision and calls these four functions; nothing in this file
# talks to `lib/review-gate.sh` or `lib/merge-budget.sh` directly, and
# nothing in this file decides whether the Approver *should* approve — only
# `landing_approver_standing_review` reads GitHub's own review list at all,
# and only to confirm a write `agent-cycle.sh` already decided to make
# actually landed (see that function's own header for why this round's
# in-process verdict is not proof enough on its own). Ships dormant: this
# file changes nothing about what a cycle does unless a caller reaches
# `landing_arm`, and the only caller (`run_landing_stage`) only reaches it
# once `merge_autonomy_effective_level` is `agent-merges-routine` or above —
# unset in every installation's `config.json` today (`merge_autonomy`'s own
# default is `human`), so this file is fully implemented and
# regression-tested (test/landing.test.sh) but
# otherwise inert until an operator raises the level (D16, §6).
#
# ## The protected-path list (risk register item 1)
#
# `landing_protected_paths_hit` is the second fence around ground the
# complexity grade already fences off once (`complexity:high` is forced for
# anything touching concurrency, security, CI/workflow machinery or shared
# library code — docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 26a, and
# `landing_eligible` already refuses anything above `complexity:medium`) —
# belt and braces against the deadliest class this design names: a pull
# request that edits the gate it is riding through the gate it just
# weakened. `merge_autonomy_protected_paths` (config, D18 Stage 3,
# agent-ops#724) names the list — a `repos[]` entry's own value overrides the
# top-level one, the same precedence `merge_autonomy_routine_sources` uses —
# matched the same way `scripts/is-docs-only.sh` matches its own allowlist
# (denylist here): an entry ending `/*` is a whole-path prefix, any other
# entry an exact path, never an extension rule. That file's own argument
# holds here unchanged: adding one line to a protected-paths list is cheap,
# forgetting one is not. Every installation defaults to agent-ops's own nine
# whole-path prefixes below, unless it names its own:
#
#   .github/     workflow definitions and branch-protection-adjacent config
#   deploy/      the node image and its compose/runbook
#   prompts/     the operating prompts every stage launches on
#   lib/         every sourced library this file itself lives in — see below
#   config.schema.json   the machine-readable statement of what config.json
#                may hold, including this file's own two new keys
#   config.json  the live configuration those keys are set in — the
#                `merge_autonomy` level and the routine-source list this
#                file's own gates read
#   agent-cycle.sh   the engine every stage runs inside, this arming step
#                included
#   review-cycle.sh  the review pipeline's own entry point
#   CODEOWNERS   who §5.3's ruleset lets the Approver App substitute for
#
# `lib/landing.sh` is self-protecting through the `lib/` prefix already —
# no separate entry names this file, because one already covers it and a
# redundant second entry is one more place to forget to update together.
# That reasoning is specific to agent-ops's own default list; a repository
# that overrides `merge_autonomy_protected_paths` takes over the job of
# covering whatever gates *its* own routine-tier landings — nothing here
# checks that an override actually does.
#
# The last three were left off when this list was first written, raised as
# an explicit question on this file's own pull request rather than decided
# here. That question has been answered: all three are on the list. Each is
# gate-bearing in the same direct sense as the entries above —
# `agent-cycle.sh` is the engine that calls this very arming step,
# `review-cycle.sh` is the review pipeline's entry point, and `config.json`
# carries the `merge_autonomy` level, `merge_autonomy_routine_sources` and
# `merge_autonomy_routine_complexity` that `landing_eligible` reads — so a
# pull request editing one of them is precisely the self-modifying case risk
# register item 1 names, and the "adding one line is cheap, forgetting one
# is not" argument above applies to them unchanged.
# Protected paths refuse arming at every level below `agent-merges-all`
# unconditionally. At `agent-merges-all` a hit is deliberately relaxed to
# `eligible` by `landing_eligible` itself, and the decision deferred to
# `landing_protected_path_controls_ok` — D18 WI-12's own compensating
# controls (§7 risk 1): the critical Approver tier, forced regardless of
# complexity (`run_approver_stage`, agent-cycle.sh), and a `landing_cool_off_hours`
# wait since that approval's own timestamp — measured only against a standing
# review whose own `commit_id` still matches the pull request's current head,
# so a push after approval restarts it — all re-read fresh at the moment of
# arming, never trusted from this round alone.
#
# ## The `SOURCE` comparison is a plain string, never a banded one
#
# `landing_eligible`'s `SOURCE` argument is compared against
# `merge_autonomy_routine_sources` by exact string equality, nothing more —
# confirmed against `agent-cycle.sh`'s own work-order construction
# (`selected_source`, set from the work order's `.source` field) and pinned
# by test/landing.test.sh rather than left to be re-discovered: every
# `issues:<band>` token in `repos[].sources` is a *config-time* rank
# (requirement 15e), but the four bands collapse to one plain `"issues"` the
# moment a candidate becomes a work order (`scripts/gather-issues.sh`,
# `"source": "issues"`) — the same collapse requirement 33's `first-seen`
# vocabulary already documents for all four bands.
#
# The comparison itself is unchanged, and deliberately so — no special case
# folding bands together lives here, which was the right call. What was
# wrong until agent-ops#558 was the *config vocabulary*: both this key and
# `repos[].sources` referenced one shared `sourceToken` enum, which offers
# the four banded spellings and no bare `issues`. So the only token that
# could ever match an issues work order was un-writable, and the four that
# were writable could never match — an installation widening its routine
# list to include issues got a config that validated and not one issue ever
# armed. agent-ops#519 (PR #554) caught the silence and added a doctor warn
# whose remedy reads "list `issues` itself" — correct advice the shared
# enum then rejected, which is how the gap survived being noticed: the
# warning and the schema each described half of a configuration that could
# not be written. Since #558 the key takes its own
# `landingSourceToken` enum: bare `issues`, no bands. A banded entry is now
# a schema error at load, which is the loud failure this quiet one deserved,
# and `scripts/doctor.sh` reads a bare `issues` in the routine list as
# gathered whenever the repository's own `sources` carry any `issues:<band>`
# (without that, its set-difference check would report the fix as a fault).
#
# The residual limitation is real but now honest, and stated in the schema:
# landing sees no band, so `issues` is all-or-nothing. An installation that
# wants only its low-band issues landed narrows what it *gathers*, not what
# it arms.
#
# ## Queue detection lives beside `merge_queue_probe`, not here
#
# `landing_arm`'s enqueue-vs-auto-merge choice reads
# `merge_queue_for_branch` (`lib/merge-queue.sh`) rather than a GraphQL
# query of its own — that file already owns every merge-queue GraphQL read
# in this codebase, and a second one here would be the same drift
# TD26071401 recorded for `lib/limit-detect.sh`'s two rate-limit detectors.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (`agent-cycle.sh` runs under
# `set -euo pipefail`; a test, `set -uo pipefail`) owns those. Depends on
# `github_pr_list_truncated` (lib/github-limit.sh) and `merge_queue_for_branch`
# (lib/merge-queue.sh), both already sourced ahead of this file by every
# caller.
#
# Environment:
#   LANDING_GH  override `gh` (tests stub it), matching
#               MERGE_QUEUE_GH/APPROVER_GH/HANDOFF_GH/REVIEW_GATE_GH.

# shellcheck source=lib/github-limit.sh
# shellcheck source=lib/merge-queue.sh
# (Sourced by every caller of this file already — see the header above.)

# GitHub documents a 3000-file ceiling on the pull-request files endpoint
# (and stops paginating usefully beyond it): a listing that reaches this
# count may be hiding protected-path files past whatever page this call
# happened to stop reading, so it is treated as unreadable rather than
# trusted as a complete answer — the same "a page cap is a truncation
# signal, not a floor to trust" reasoning `GITHUB_PR_LIST_LIMIT` and
# `github_pr_list_truncated` already apply to `gh pr list`.
LANDING_PR_FILES_LIMIT="${LANDING_PR_FILES_LIMIT:-3000}"

# Fixed, unconfigurable — the same footing `blocked`/`obsolete`
# (lib/labels.sh's own header) already stand on: no installation renames
# this, and unlike `blocked` no human has a reason to hand-apply it for an
# unrelated purpose, so its whole lifecycle (add, and the one release below)
# stays this pipeline's own (D18, agent-ops#668).
LANDING_OPEN_QUESTION_LABEL="${LANDING_OPEN_QUESTION_LABEL:-open-question}"

# _landing_protected_paths CONFIG_JSON SLUG
# The protected-path list SLUG is governed by: its own `repos[]` entry's
# `merge_autonomy_protected_paths` when present, else the top-level key, else
# the schema default — agent-ops's own nine paths (see the header). Prints a
# compact JSON array; never fails, on the same "a missing or malformed key is
# not evidence of an empty list" reasoning `_landing_routine_sources` above
# already documents.
_landing_protected_paths() {
  local config_json="$1" slug="$2" repo_list
  repo_list="$(jq -c --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy_protected_paths // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_list" ]] && jq -e 'type == "array"' <<<"$repo_list" >/dev/null 2>&1; then
    printf '%s' "$repo_list"
    return 0
  fi
  local top_list
  top_list="$(jq -c '.merge_autonomy_protected_paths // empty' <<<"$config_json" 2>/dev/null)"
  if [[ -n "$top_list" ]] && jq -e 'type == "array"' <<<"$top_list" >/dev/null 2>&1; then
    printf '%s' "$top_list"
    return 0
  fi
  printf '%s' '[".github/*","deploy/*","prompts/*","lib/*","config.schema.json","config.json","agent-cycle.sh","review-cycle.sh","CODEOWNERS"]'
}

# _landing_is_protected PROTECTED_JSON PATH
# Exit 0 iff PATH matches one of PROTECTED_JSON's entries — see the header
# for the default list and why each entry is there. An entry ending `/*`
# matches as a whole-path prefix (`lib/*` matches `lib/landing.sh`, never
# `libfoo.sh`); any other entry matches only that exact path — never an
# extension rule, and never a shell glob, so an entry containing a `?` or a
# `[...]` in a future override matches itself literally rather than as a
# pattern. Exit 1 when nothing matches. Exit 5 — `jq -e`'s own code for a
# program that raised rather than merely returned false — when PROTECTED_JSON
# holds an entry `endswith`/`==` cannot compare against a string at all (a
# number, an object, a bool): `config.schema.json` constrains every
# `merge_autonomy_protected_paths` entry to a non-empty string, so this is
# unreachable through a schema-validated config, but the caller must still
# tell it apart from "no match" (TD-PPagop-26082320) rather than reading a
# malformed list as "nothing here is protected".
_landing_is_protected() {
  local protected_json="$1" path="$2"
  jq -e --arg p "$path" '
    any(.[]; . as $entry | if $entry | endswith("/*") then ($p | startswith($entry[:-1])) else $entry == $p end)
  ' <<<"$protected_json" >/dev/null 2>&1
}

# landing_protected_paths_hit CONFIG_JSON SLUG NUMBER
# Print the offending paths, one per line. Exit 0 when at least one changed
# path is protected, 1 when none is, 2 when the answer could not be
# established at all (bad arguments, `gh` erroring, a listing that reached
# LANDING_PR_FILES_LIMIT and so may be hiding more, or `_landing_is_protected`
# raising — TD-PPagop-26082320 — because CONFIG_JSON's protected-paths list
# holds a non-string entry `_landing_is_protected` cannot compare at all).
# Reads the changed-file list fresh from GitHub — `gh api
# repos/SLUG/pulls/N/files`, never the ephemeral clone, whose branch may have
# moved since it was checked out. At the gate-4.5 call site this guards,
# exit 2 is a refusal to arm: an unreadable or truncated list, or a protected-
# paths list this cannot even evaluate, must never read as "nothing protected
# was touched". The other call site — `_landing_stage_attempt`'s own
# `landing-audit-record` write (requirement 8x) — runs after the arm has
# already happened, so exit 2 there instead maps to a bare `unknown`
# protected-path verdict in the record and proceeds; there is nothing left
# to refuse.
#
# `--method GET` is not decoration, and `_review_gate_open_alerts`
# (lib/review-gate.sh) carries the same warning for the same reason: `gh api`
# switches a request carrying `-f`/`-F` fields to POST unless told otherwise,
# and `POST /repos/…/pulls/N/files` is a 404. Without it this read failed on
# every call, every call site treated the exit 2 as the refusal it is meant to
# be, and D18 arming was held shut for five days while the logs said only
# `unknown:could not establish …'s changed-file list` (agent-ops#718).
landing_protected_paths_hit() {
  local config_json="$1" slug="$2" number="${3:-}" gh_bin="${LANDING_GH:-gh}"
  [[ -n "$slug" && "$number" =~ ^[0-9]+$ ]] || return 2

  local protected_json
  protected_json="$(_landing_protected_paths "$config_json" "$slug")"

  local raw count
  raw="$("$gh_bin" api --method GET "repos/$slug/pulls/$number/files" \
    --paginate -F per_page=100 \
    --jq '.[].filename' 2>/dev/null)" || return 2

  if [[ -z "$raw" ]]; then
    count=0
  else
    count="$(wc -l <<<"$raw")"
  fi
  github_pr_list_truncated "$count" "$LANDING_PR_FILES_LIMIT" && return 2

  local hit=0 path is_protected_rc
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    _landing_is_protected "$protected_json" "$path"; is_protected_rc=$?
    case "$is_protected_rc" in
      0) printf '%s\n' "$path"; hit=1 ;;
      1) ;;
      *) return 2 ;;
    esac
  done <<<"$raw"
  (( hit )) && return 0
  return 1
}

# _landing_routine_sources CONFIG_JSON SLUG
# The routine-source list SLUG is governed by: its own `repos[]` entry's
# `merge_autonomy_routine_sources` when present, else the top-level key,
# else the schema default `["register-hygiene","tech-debt"]` — the same
# entry-wins-else-top-level-else-shipped-default precedence
# `merge_autonomy_configured_level` and `merge_budget_effective_cap` both
# already use. Prints a compact JSON array; never fails — a config that
# does not parse simply falls through to the shipped default, since a
# missing or malformed key is not evidence a repository has no routine
# sources, and this must not be the reason `landing_eligible` reads
# `unknown` for an otherwise ordinary pull request.
_landing_routine_sources() {
  local config_json="$1" slug="$2" repo_list
  repo_list="$(jq -c --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy_routine_sources // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_list" ]] && jq -e 'type == "array"' <<<"$repo_list" >/dev/null 2>&1; then
    printf '%s' "$repo_list"
    return 0
  fi
  local top_list
  top_list="$(jq -c '.merge_autonomy_routine_sources // empty' <<<"$config_json" 2>/dev/null)"
  if [[ -n "$top_list" ]] && jq -e 'type == "array"' <<<"$top_list" >/dev/null 2>&1; then
    printf '%s' "$top_list"
    return 0
  fi
  printf '["register-hygiene","tech-debt"]'
}

# _landing_routine_complexity CONFIG_JSON SLUG
# The routine-complexity list SLUG is governed by: its own `repos[]` entry's
# `merge_autonomy_routine_complexity` when present, else the top-level key,
# else the schema default `["low","medium"]` — the same
# entry-wins-else-top-level-else-shipped-default precedence
# `_landing_routine_sources` above already uses (D18 Stage 3, agent-ops#725).
# Prints a compact JSON array; never fails — a config that does not parse
# simply falls through to the shipped default, for the same reason
# `_landing_routine_sources` does: a missing or malformed key is not evidence
# a repository accepts no complexity at all, and this must not be the reason
# `landing_eligible` reads `unknown` for an otherwise ordinary pull request.
_landing_routine_complexity() {
  local config_json="$1" slug="$2" repo_list
  repo_list="$(jq -c --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy_routine_complexity // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_list" ]] && jq -e 'type == "array"' <<<"$repo_list" >/dev/null 2>&1; then
    printf '%s' "$repo_list"
    return 0
  fi
  local top_list
  top_list="$(jq -c '.merge_autonomy_routine_complexity // empty' <<<"$config_json" 2>/dev/null)"
  if [[ -n "$top_list" ]] && jq -e 'type == "array"' <<<"$top_list" >/dev/null 2>&1; then
    printf '%s' "$top_list"
    return 0
  fi
  printf '["low","medium"]'
}

# landing_autonomy_refusal_reason STATE_REPO STATE_DIR LEVEL [FRESH]
# The `landing-refused` reason text for gate 1 of `_landing_stage_attempt`
# (agent-cycle.sh) when LEVEL is not `agent-merges-routine`/`agent-merges-all`
# — D18 WI-2's fleet-wide kill switch (lib/merge-autonomy.sh) is one possible
# cause of that, a repository simply never raised past `human`/
# `agent-approves` is the other, and issue #576's own acceptance criterion 2
# is that a human reading the log can tell which. Gate 1 already has LEVEL in
# hand (`merge_autonomy_effective_level`'s own collapsed answer, which does
# not say *why* it collapsed) by the time it calls this — the extra
# `merge_autonomy_kill_state` read below is what recovers the "why", asked
# again rather than threaded through because `merge_autonomy_effective_level`
# returns one word, not a cause.
#
# FRESH (issue #513's own discipline, applied here for the same reason gate
# 1's own LEVEL read already carries it: an operator's mid-cycle kill must be
# visible in the very refusal it causes, not the next cycle's) is threaded
# straight through to `merge_autonomy_kill_state`.
#
# Named the same "ineligible:$reason" convention `landing_eligible` below and
# `_landing_arm_failure_reason` both, so every refusal this file's callers can
# produce reads the same way in the fleet log: this is never a pass, no
# caller need treat it as anything other than the reason a refusal names. The
# kill-switch branch carries its own `kill-switch:` tag ahead of the colon —
# scripts/publish-dashboard.sh's landings digest groups `landing-refused`
# reasons by the text before the first `:` (dashboard/index.html's
# `byReason`), so this is also what makes the switch its own, single-word
# group there rather than folding into (or being confused with) the
# full-sentence group the plain "effective level is …" wording below forms
# (acceptance criterion 4).
landing_autonomy_refusal_reason() {
  local state_repo="$1" state_dir="$2" level="$3" fresh="${4:-}"
  local kill_state
  kill_state="$(jq -r '.state' <<<"$(merge_autonomy_kill_state "$state_repo" "$state_dir" "$fresh")" 2>/dev/null)"
  if [[ "$kill_state" != "enabled" ]]; then
    printf 'kill-switch:merge_autonomy kill switch is engaged fleet-wide — effective level forced to human regardless of the configured level, until an operator clears it'
    return 0
  fi
  printf 'merge_autonomy effective level is %s, not agent-merges-routine or agent-merges-all' "${level:-empty}"
}

# landing_routine_eligible CONFIG_JSON SLUG COMPLEXITY SOURCE
# Print `eligible` or `ineligible:<reason>` — the complexity-and-source
# subset of `landing_eligible`'s own gates, factored out so a caller that
# only needs *that* verdict (D18 WI-6's back-pressure exclusion,
# lib/standdown.sh) reads the identical primitives `landing_eligible` itself
# does rather than re-deriving them, and the two can never drift apart.
# Deliberately never calls `landing_protected_paths_hit`: that gate is a
# live changed-file read `landing_eligible` pays for once, at arming time,
# for a decision this function's own callers do not need — a protected-path
# pull request is not barred from a *human* landing it, only from the
# pipeline doing so automatically, so back-pressure counting has no business
# with it.
#
# Eligible iff **both**:
#   - COMPLEXITY is a member of `_landing_routine_complexity`'s list for
#     SLUG (default `low`/`medium`; agent-ops#725) — an empty or
#     unrecognised COMPLEXITY is ineligible, never eligible by omission.
#     This is the first half of risk register item 1's belt and braces:
#     requirement 26a already forces `high` onto anything touching
#     concurrency, security, CI/workflow machinery or shared library code,
#     so widening this list to admit `high` routes exactly that class of
#     diff through automatic landing;
#   - SOURCE is a member of `_landing_routine_sources`'s list for SLUG — an
#     empty or unrecognised SOURCE is ineligible, never eligible by
#     omission.
landing_routine_eligible() {
  local config_json="$1" slug="$2" complexity="$3" source="$4"

  local routine_complexity_json
  routine_complexity_json="$(_landing_routine_complexity "$config_json" "$slug")"
  # Same emptiness-guard reasoning as the SOURCE membership test below: `jq
  # -e` on empty input exits 0 on jq 1.6 and 4 on jq 1.7, so skipping this
  # guard would silently admit every complexity on a 1.6 host. See that
  # test's own comment for the full argument.
  if [[ -z "$complexity" || -z "$routine_complexity_json" ]] \
     || ! jq -e --arg c "$complexity" 'index($c) != null' <<<"$routine_complexity_json" >/dev/null 2>&1; then
    printf 'ineligible:complexity is %s, not in %s'\''s configured routine complexity %s' \
      "${complexity:-empty}" "$slug" "$routine_complexity_json"
    return 0
  fi

  local routine_json
  routine_json="$(_landing_routine_sources "$config_json" "$slug")"
  # The emptiness guards are not redundant with _landing_routine_sources'
  # own guarantee, and must not be removed as though they were: `jq -e` on
  # *empty input* exits 0 on jq 1.6 and 4 on jq 1.7, so on a 1.6 host every
  # one of these membership tests silently inverts and this gate admits
  # every source it exists to refuse. The image pins 1.7 (deploy/docker/
  # Dockerfile, ubuntu:24.04), which is the only reason that was never a
  # live fail-open — an argument from a pinned dependency, not from this
  # code, and the wrong kind of argument to rest an arming gate on.
  if [[ -z "$source" || -z "$routine_json" ]] \
     || ! jq -e --arg s "$source" 'index($s) != null' <<<"$routine_json" >/dev/null 2>&1; then
    printf 'ineligible:source %s is not in %s'\''s configured routine list %s' \
      "${source:-empty}" "$slug" "$routine_json"
    return 0
  fi

  printf 'eligible'
}

# landing_eligible CONFIG_JSON SLUG NUMBER COMPLEXITY SOURCE LEVEL
# Print `eligible`, `ineligible:<reason>` or `unknown:<reason>`. LEVEL is
# the caller's own already-resolved `merge_autonomy_effective_level` — this
# function never resolves it itself, so the kill switch and a WI-6 budget
# freeze both bind exactly once, at the caller, rather than being read
# twice and risking the two reads disagreeing.
#
# Eligible iff **all** of:
#   - LEVEL is `agent-merges-routine` or `agent-merges-all`;
#   - `landing_routine_eligible` says so (COMPLEXITY and SOURCE, above);
#   - `landing_protected_paths_hit` says no — below `agent-merges-all`. At
#     `agent-merges-all` a hit is instead reported `eligible` and deferred
#     to `landing_protected_path_controls_ok` (D18 WI-12), which needs
#     facts this function is never handed; see the hit branch's own comment
#     below.
#
# `unknown` is returned only for `landing_protected_paths_hit`'s own exit 2
# (the changed-file list could not be read or was truncated, or the
# configured protected-paths list could not be evaluated against a path at
# all — TD-PPagop-26082320) — every other refusal above is a deterministic
# `ineligible`, since COMPLEXITY, SOURCE and LEVEL are all already in the
# caller's hand, nothing further to ask GitHub. Both words carry the same
# instruction to every call site: **never a pass** — `unknown` is treated
# as `ineligible` everywhere this is read, the distinction exists only so a
# log can say whether the diff was genuinely disqualified or merely
# unreadable.
landing_eligible() {
  local config_json="$1" slug="$2" number="$3" complexity="$4" source="$5" level="$6"

  case "$level" in
    agent-merges-routine|agent-merges-all) ;;
    *)
      printf 'ineligible:merge_autonomy effective level is %s, not agent-merges-routine or agent-merges-all' "${level:-empty}"
      return 0
      ;;
  esac

  local routine_elig
  routine_elig="$(landing_routine_eligible "$config_json" "$slug" "$complexity" "$source")"
  if [[ "$routine_elig" != "eligible" ]]; then
    printf '%s' "$routine_elig"
    return 0
  fi

  local hit_paths hit_rc
  hit_paths="$(landing_protected_paths_hit "$config_json" "$slug" "$number")"; hit_rc=$?
  case "$hit_rc" in
    0)
      # D18 WI-12 (Stage 4, agent-ops#415): a protected path stays ineligible
      # at every level below `agent-merges-all` exactly as before. At
      # `agent-merges-all` this is deliberately *not* the final word — the
      # compensating controls §7 risk 1 requires (the critical Approver tier,
      # the cool-off since that approval, measured only against a review that
      # still covers the current head) are gates only `_landing_stage_attempt`
      # can check, since they need facts (the tier an already-standing review
      # ran at, its own submitted_at and commit_id) this function is never
      # handed. Reporting
      # `eligible` here defers the decision to `landing_protected_path_controls_ok`,
      # never skips it.
      if [[ "$level" == "agent-merges-all" ]]; then
        printf 'eligible'
      else
        printf 'ineligible:touches protected path(s): %s' "$(paste -sd, - <<<"$hit_paths")"
      fi
      return 0
      ;;
    2)
      printf 'unknown:could not establish %s#%s'\''s changed-file list' "$slug" "$number"
      return 0
      ;;
  esac

  printf 'eligible'
}

# landing_cool_off_effective_hours CONFIG_JSON SLUG
# The D18 WI-12 protected-path cool-off for SLUG: its own `repos[]` override
# when present, else the top-level `landing_cool_off_hours` key, else 24 —
# the same precedence `merge_budget_effective_cap` and
# `merge_autonomy_configured_level` both already use. `0` at either level
# means no wait, and is returned as-is, never treated as "unset". Accepts a
# non-negative integer or decimal; anything else falls through exactly as a
# missing key does.
landing_cool_off_effective_hours() {
  local config_json="$1" slug="$2" repo_hours top_hours
  repo_hours="$(jq -r --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .landing_cool_off_hours // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ "$repo_hours" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$repo_hours"
    return 0
  fi
  top_hours="$(jq -r '.landing_cool_off_hours // empty' <<<"$config_json" 2>/dev/null)"
  [[ "$top_hours" =~ ^[0-9]+(\.[0-9]+)?$ ]] || top_hours=24
  printf '%s' "$top_hours"
}

# landing_cool_off_remaining_hours SUBMITTED_AT COOL_OFF_HOURS [NOW_ISO]
# Hours still remaining before the D18 WI-12 cool-off since SUBMITTED_AT
# (ISO 8601, the Approver's standing review's own `submitted_at`) elapses,
# one decimal place; `0` once it already has. Empty — never `0` — on
# unparseable input (a bad SUBMITTED_AT or a non-numeric COOL_OFF_HOURS): the
# caller must treat that as "could not establish", not as "elapsed". NOW_ISO
# defaults to the current time and exists so a test can pin the window
# without waiting for one — the same convention `merge_budget_window_status`
# uses.
landing_cool_off_remaining_hours() {
  local submitted_at="${1:-}" cool_off_hours="${2:-}" now_iso="${3:-}"
  [[ -n "$now_iso" ]] || now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ "$cool_off_hours" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
  jq -nr --arg at "$submitted_at" --arg now "$now_iso" --argjson hrs "$cool_off_hours" '
    (($at | fromdateiso8601) as $a
     | ($now | fromdateiso8601) as $n
     | (($a + ($hrs * 3600) - $n) / 3600)
     | if . < 0 then 0 else ((. * 10 | round) / 10) end)
  ' 2>/dev/null
}

# landing_protected_path_controls_ok CONFIG_JSON SLUG NUMBER TIER SUBMITTED_AT REVIEW_COMMIT [NOW_ISO]
# The D18 WI-12 Stage 4 compensating controls (§7 risk 1) a protected-path
# pull request at `agent-merges-all` must additionally clear before
# `_landing_stage_attempt` arms it, once `landing_eligible` has already
# deferred the decision here. Print `ok`, `ineligible:<reason>` or
# `unknown:<reason>` — never a pass on anything this cannot establish.
#
# Re-reads `landing_protected_paths_hit` itself rather than trust the
# caller's own earlier read (never more than one function call old, the same
# discipline every other landing gate follows): a pull request not actually
# touching a protected path is `ok` immediately, since neither control below
# applies to it. TIER, SUBMITTED_AT and REVIEW_COMMIT are the caller's own
# facts about the Approver's already-*standing* review — never re-derived
# here: TIER is either `run_approver_stage`'s own in-process fact (the round
# that first approved this pull request) or read back from the fleet log's
# own `approver-verdict` event (`landing_retry_tier`, a re-arm on a later
# cycle); SUBMITTED_AT and REVIEW_COMMIT are `landing_approver_standing_review_at`'s
# own timestamp and `commit_id`, already fetched fresh by the same gate that
# confirmed the review is standing `APPROVED`. Only `critical` satisfies the
# tier control — an adjudication settled by a refuse-streak counts exactly
# the same as an ordinary engagement forced critical by the protected path
# itself, since both mean the pull request actually got the critical-tier
# scrutiny Stage 4 requires, whichever cause `run_approver_stage`'s own
# `critical_reason` names for the log.
#
# The cool-off is only ever measured against a review that still covers the
# pull request's *current* code: REVIEW_COMMIT (the standing review's own
# `commit_id`) is checked against a fresh read of the pull request's own
# `headRefOid` before `submitted_at` is trusted for anything. A push after
# approval moves the head without touching the standing review at all —
# nothing in this pipeline dismisses a stale review on push — so a mismatch
# here is the only signal a later push ever leaves, and it refuses outright
# rather than measuring a cool-off against a timestamp that no longer speaks
# for the code actually sitting on the branch. There is no fresher
# `submitted_at` to restart the clock from until the Approver reviews the new
# head and a later gate-4 read finds a `commit_id` that matches again — until
# then this control simply never clears, which is what "a fresh push
# restarts the wait" means in practice: the wait does not resume where it
# left off, it starts over from an unmet state.
landing_protected_path_controls_ok() {
  local config_json="$1" slug="$2" number="$3" tier="${4:-}" submitted_at="${5:-}" review_commit="${6:-}" now_iso="${7:-}"
  local gh_bin="${LANDING_GH:-gh}"
  local hit_rc=0
  landing_protected_paths_hit "$config_json" "$slug" "$number" >/dev/null 2>&1 || hit_rc=$?
  case "$hit_rc" in
    1)
      printf 'ok'
      return 0
      ;;
    0) ;;
    *)
      printf 'unknown:could not re-establish %s#%s'\''s changed-file list for the protected-path controls' "$slug" "$number"
      return 0
      ;;
  esac

  if [[ "$tier" != "critical" ]]; then
    printf 'ineligible:touches a protected path at agent-merges-all but the approving engagement did not run at the critical tier (tier: %s)' "${tier:-empty}"
    return 0
  fi
  if [[ -z "$submitted_at" ]]; then
    printf 'ineligible:touches a protected path at agent-merges-all but no approval timestamp could be established for the cool-off'
    return 0
  fi

  local head_sha
  head_sha="$("$gh_bin" pr view "$number" -R "$slug" --json headRefOid --jq '.headRefOid' 2>/dev/null)"
  if [[ -z "$head_sha" ]]; then
    printf 'unknown:could not re-establish %s#%s'\''s current head commit for the protected-path cool-off' "$slug" "$number"
    return 0
  fi
  if [[ -z "$review_commit" || "$review_commit" != "$head_sha" ]]; then
    printf 'ineligible:the standing review approved commit %s, but %s#%s'\''s current head is %s — a push after approval restarts the protected-path cool-off' \
      "${review_commit:-empty}" "$slug" "$number" "$head_sha"
    return 0
  fi

  local cool_off_hours remaining
  cool_off_hours="$(landing_cool_off_effective_hours "$config_json" "$slug")"
  remaining="$(landing_cool_off_remaining_hours "$submitted_at" "$cool_off_hours" "$now_iso")"
  if [[ -z "$remaining" ]]; then
    printf 'unknown:could not compute the protected-path cool-off remaining time for %s#%s' "$slug" "$number"
    return 0
  fi
  if awk -v r="$remaining" 'BEGIN { exit !(r > 0) }'; then
    printf 'ineligible:protected-path cool-off has %sh remaining (approved %s, landing_cool_off_hours=%s)' \
      "$remaining" "$submitted_at" "$cool_off_hours"
    return 0
  fi
  printf 'ok'
}

# landing_approver_standing_review SLUG NUMBER LOGIN
# Print LOGIN's own most recent *standing* review state on SLUG#NUMBER —
# `APPROVED`, `CHANGES_REQUESTED`, or empty when LOGIN has left no standing
# review at all (never reviewed, or only left COMMENTED/DISMISSED ones) —
# the same "last of APPROVED/CHANGES_REQUESTED, ignoring COMMENTED and
# DISMISSED" rule `lib/handoff.sh`'s own `_handoff_latest_reviews` applies
# for every reviewer it considers. Returns non-zero, printing nothing, when
# the reviews list could not be read at all — the caller must not read that
# as "not approved", the same "could not ask" convention every other
# reviews-list reader in this codebase follows.
#
# This exists, and duplicates rather than reuses `_handoff_latest_reviews`,
# because that function excludes bots outright (requirement 34a: a bot's
# review is never a human's standing position) — and the Approver posts as
# one, `<slug>[bot]`. `run_landing_stage` needs exactly the fact
# `_handoff_latest_reviews` is built to discard: whether *this* bot's review
# is genuinely standing on GitHub right now. That is not the same fact as
# `agent-cycle.sh`'s own in-process `approver_stage_verdict` from this
# round: `approver_post_or_warn` always returns 0 even when the write itself
# failed — "a missing review, never a stranded PR" is correct for that
# stage's own purpose, but it means a `verdict` of `approve` is this
# process's *intent*, not GitHub's own record, and a token that expired
# between minting and posting, or an API hiccup on the write, would
# otherwise arm a merge for a pull request that carries no actual Approver
# review at all. This read is what closes that gap, and it is why gate 4
# cannot simply trust gate 0's own precondition.
landing_approver_standing_review() {
  local slug="$1" number="${2:-}" login="${3:-}" gh_bin="${LANDING_GH:-gh}" lines
  [[ -n "$slug" && "$number" =~ ^[0-9]+$ && -n "$login" ]] || return 1
  lines="$("$gh_bin" api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null) | {login: .user.login, at: .submitted_at, state: .state}' \
            2>/dev/null)" || return 1
  jq -s -r --arg l "$login" '
    [.[] | select(.login == $l and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))]
    | sort_by(.at) | last | (.state // "")
  ' <<<"$lines" 2>/dev/null || return 1
}

# landing_approver_standing_review_at SLUG NUMBER LOGIN
# `landing_approver_standing_review`'s own answer, plus the standing
# review's own `submitted_at` and `commit_id` — printed as
# `STATE<TAB>AT<TAB>COMMIT` (empty AT and COMMIT when there is no standing
# review to have them), the same compound-return idiom
# `merge_budget_window_status` uses. D18 WI-12 (agent-ops#415)'s protected-
# path cool-off is measured from exactly this timestamp, but only once
# COMMIT is confirmed to still match the pull request's current head
# (`landing_protected_path_controls_ok`'s own job) — GitHub's own record of
# when, and against which commit, the review it is gating on was actually
# submitted, never anything this process remembers — so gate 4 of
# `_landing_stage_attempt` reads it here rather than
# `landing_approver_standing_review`, at every level and at no extra `gh`
# call: the same one reviews-list read either function makes, so the
# timestamp and commit gate 4.5 needs at `agent-merges-all` cost nothing to
# carry everywhere. (The landing-retry sweep's own pre-filter still calls the
# plain reader, which is all it wants.) Returns non-zero, printing nothing,
# under the same conditions `landing_approver_standing_review` does — an
# unreadable reviews list is never read as "not approved, and no timestamp".
landing_approver_standing_review_at() {
  local slug="$1" number="${2:-}" login="${3:-}" gh_bin="${LANDING_GH:-gh}" lines
  [[ -n "$slug" && "$number" =~ ^[0-9]+$ && -n "$login" ]] || return 1
  lines="$("$gh_bin" api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null) | {login: .user.login, at: .submitted_at, state: .state, commit: .commit_id}' \
            2>/dev/null)" || return 1
  jq -s -r --arg l "$login" '
    [.[] | select(.login == $l and (.state == "APPROVED" or .state == "CHANGES_REQUESTED"))]
    | sort_by(.at) | last
    | ((.state // "") + "\t" + (.at // "") + "\t" + (.commit // ""))
  ' <<<"$lines" 2>/dev/null || return 1
}

# landing_arm SLUG NUMBER TOKEN
# The single write that actually lands a pull request: enqueue where the
# base branch has an active merge queue (`enqueuePullRequest`), or
# `gh pr merge --auto --squash` where it does not. Prints the method used —
# `enqueued` or `auto-merge` — the word `agent-cycle.sh` logs verbatim as
# `landing-armed`'s own `method` field; `auto-merge` names the *call* this
# function made, not a guarantee that call armed anything — see the "no-queue
# fallback" section in the file header above: from `CLEAN`/`UNSTABLE` it
# merges the pull request immediately, and only from `BLOCKED` does it arm
# auto-merge as the name suggests. Prints nothing and returns non-zero on any
# failure, including one this function cannot tell apart from a partial write
# (GitHub's own response is what decides that, per call, below), so a caller
# must never read a non-zero exit as anything but "no write happened it can
# vouch for".
#
# The non-zero exit status itself distinguishes *which* step failed
# (agent-ops#532) — `_landing_arm_failure_reason` below turns it into text a
# `landing-refused` reason can carry, since a bare "landing_arm could not
# enqueue or auto-merge" left every one of these indistinguishable in the
# log, the one place an operator would otherwise look to find out:
#   1 — bad arguments (missing SLUG, NUMBER or TOKEN)
#   2 — could not read the pull request's own node id / base branch
#   3 — that read reported no node id or no base branch
#   4 — could not read the base branch's merge-queue state
#   5 — the enqueue mutation itself failed
#   6 — the enqueue mutation reported no merge-queue entry (a partial write)
#   7 — `gh pr merge --auto --squash` failed
#
# Two reads precede the one write, both under whatever ambient `gh`
# identity the caller already runs as (never TOKEN — they write nothing,
# so the two-identity audit trail has nothing to protect here):
#   - the pull request's own GraphQL node id and current base branch
#     (`gh api repos/SLUG/pulls/NUMBER`), needed because `enqueuePullRequest`
#     takes a node id, not a SLUG/NUMBER pair;
#   - `merge_queue_for_branch SLUG BASE` (lib/merge-queue.sh) — null means
#     no queue.
#
# The write itself runs under TOKEN as a leading one-invocation assignment
# — `GH_TOKEN="$token" "$gh_bin" …`, never `export` — exactly as
# `approver_post_review` (lib/approver.sh) does and for the reason its own
# comment gives: never the owner PAT, which would collapse the two-identity
# audit trail §5.3 exists for into the same account authoring, approving
# and landing every pull request.
landing_arm() {
  local slug="$1" number="${2:-}" token="${3:-}" gh_bin="${LANDING_GH:-gh}"
  [[ -n "$slug" && "$number" =~ ^[0-9]+$ && -n "$token" ]] || return 1

  local pr_json node_id base
  pr_json="$("$gh_bin" api "repos/$slug/pulls/$number" \
    --jq '{id: .node_id, base: .base.ref}' 2>/dev/null)" || return 2
  node_id="$(jq -r '.id // empty' <<<"$pr_json" 2>/dev/null)"
  base="$(jq -r '.base // empty' <<<"$pr_json" 2>/dev/null)"
  [[ -n "$node_id" && -n "$base" ]] || return 3

  local queue_json
  queue_json="$(merge_queue_for_branch "$slug" "$base")" || return 4

  if [[ "$queue_json" != "null" ]]; then
    local mutate_out
    # shellcheck disable=SC2016  # GraphQL's own $id variable, not the shell's.
    mutate_out="$(GH_TOKEN="$token" "$gh_bin" api graphql \
      -f query='mutation($id:ID!){enqueuePullRequest(input:{pullRequestId:$id}){mergeQueueEntry{id}}}' \
      -f id="$node_id" \
      --jq '.data.enqueuePullRequest.mergeQueueEntry.id' 2>/dev/null)" || return 5
    # Empty *and* the literal `null`, because which one arrives is not
    # this code's to predict: `enqueuePullRequest` reports `mergeQueueEntry`
    # as nullable and GitHub does not always accompany a null with a GraphQL
    # error `gh` would exit non-zero on, while `gh --jq` raw-prints, turning
    # a JSON null into an empty line rather than the four characters `null`
    # (checked live, 2026-08-29 — the same behaviour that broke
    # `merge_queue_for_branch`, which now reads its envelope whole rather
    # than through `--jq`). Testing only one of the two would let a mutation
    # that enqueued nothing be logged `landing-armed` naming a queue entry
    # that does not exist — exactly the "a partial write this function
    # cannot vouch for" case the header promises to refuse. Both are tested
    # here so neither `gh`'s rendering nor GitHub's nullability has to be
    # relied on.
    [[ -n "$mutate_out" && "$mutate_out" != "null" ]] || return 6
    printf 'enqueued'
    return 0
  fi

  GH_TOKEN="$token" "$gh_bin" pr merge "$number" -R "$slug" --auto --squash >/dev/null 2>&1 || return 7
  printf 'auto-merge'
}

# _landing_arm_failure_reason CODE
# Human-readable text for one of `landing_arm`'s seven distinguishable exit
# statuses (see its own header) — kept beside `landing_arm` so the mapping
# cannot drift from the return statements it describes. An unrecognised CODE
# (there should never be one) still names itself rather than saying nothing.
_landing_arm_failure_reason() {
  case "$1" in
    1) printf 'bad arguments (missing slug, pull request number or token)' ;;
    2) printf 'could not read the pull request'\''s own node id and base branch' ;;
    3) printf 'the pull request read reported no node id or no base branch' ;;
    4) printf 'could not read the base branch'\''s merge-queue state' ;;
    5) printf 'the enqueue mutation itself failed' ;;
    6) printf 'the enqueue mutation reported no merge-queue entry (a partial write)' ;;
    7) printf 'gh pr merge --auto --squash failed' ;;
    *) printf 'exited %s' "${1:-unknown}" ;;
  esac
}

# landing_retry_source REPO BRANCH [LOG_FILE]
# Print the `source` this pull request's claim was raised under — the
# `selection` event `agent-cycle.sh` already logs once per work order,
# `{repo, item, source, model, title, branch}`, verbatim regardless of which
# source it came from (a fresh item or a finishing one). Read back here so the
# 2.1e landing-retry sweep (TD-PPagop-26081701) can call `landing_eligible`
# with the same fact the round that first approved this pull request used,
# for a repository and branch its own process never claimed and so has no
# `$selected_source` for.
#
# This is the one fact `_landing_stage_attempt`'s gates read from the fleet
# log rather than fresh from GitHub, and deliberately so: unlike every other
# gate (a review, a check, the budget, the queue), a pull request's source is
# fixed at claim time and never mutates over its life — GitHub carries no
# field for it at all — so the log's own append-only record of the one
# `selection` event that raised this branch is exactly as current as a fresh
# read would be, for a fact that cannot go stale.
#
# LOG_FILE is the fleet's own union log (`$union_log`, built once per cycle
# from every node's synced log — see agent-cycle.sh's own "1a. The fleet's
# memory"), or stdin if omitted or "-", matching every reader in
# lib/cycle-state.sh. Malformed lines are skipped, not fatal (`fromjson? //
# empty`, the same tolerant-line convention `blocked_items` uses); several
# `selection` events for the same repo/branch keep only the most recent
# (`sort_by(.ts) | last`) — a branch this system reuses (a tech-debt item's
# `td/<ID>` retried under a fresh claim) still resolves to its current claim,
# never a stale one. Empty on no match, an unreadable log, or nothing to
# read — the sweep must skip a candidate it cannot classify, never guess at
# a source that could put a non-routine pull request through the routine
# gate.
landing_retry_source() {
  local repo="$1" branch="$2" src="${3:--}" out=""
  # shellcheck disable=SC2016  # $repo/$branch are jq's own --arg variables, not the shell's.
  local jq_prog='
    [ .[] | select(.event == "selection" and (.repo // "") == $repo
                   and (.branch // "") == $branch and (.source // "") != "") ]
    | sort_by(.ts) | last | .source // empty'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -rs --arg repo "$repo" --arg branch "$branch" "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -rs --arg repo "$repo" --arg branch "$branch" "$jq_prog" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# landing_retry_tier PR_URL [LOG_FILE]
# Print the tier (`trivial`, `standard`, `high` or `critical`) of the most
# recent `approver-verdict` event for PR_URL — the same "fixed at the
# moment, read back from the fleet log" reasoning `landing_retry_source`
# already applies to a work order's `source`, for the same reason: TIER is
# `run_approver_stage`'s own in-process fact on the round that first
# approved a pull request (D18 WI-12, agent-ops#415), and the 2.1e
# landing-retry sweep re-arms a pull request on a later cycle, outside that
# round, with no in-process fact to read. Keyed on `pr_url` rather than
# repo/branch, matching the `approver-verdict` event's own shape — a pull
# request's tier is fixed by that round's engagement and never mutates
# afterwards, so the log's record is exactly as current as a fresh read
# would be. Several `approver-verdict` events for the same pull request keep
# only the most recent. Empty on no match, an unreadable log, or nothing to
# read — `landing_protected_path_controls_ok` must never guess a tier a
# protected-path pull request never actually got.
landing_retry_tier() {
  local pr_url="$1" src="${2:--}" out=""
  # shellcheck disable=SC2016  # $pr_url is jq's own --arg variable, not the shell's.
  local jq_prog='
    [ .[] | select(.event == "approver-verdict" and (.pr_url // "") == $u) ]
    | sort_by(.ts) | last | .tier // empty'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -rs --arg u "$pr_url" "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -rs --arg u "$pr_url" "$jq_prog" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# landing_approver_adjudication_history PR_URL [SRC1] [SRC2]
# Every `approver-verdict` event for PR_URL, oldest first — a compact JSON
# array of `{ts, tier, model, verdict, adjudication, refuse_streak, posted}` —
# the D18 landing audit record's own "adjudication history" field
# (requirement 8x, agent-ops#578): a pull request a refuse streak sent
# through more than one Approver engagement carries every one of them here,
# not only the round that finally approved it. The record's own `approver`
# object is this array's *last* entry, exactly as `landing_retry_tier` reads
# the newest matching event's `tier` alone — never a separate in-process
# fact, so the same read serves both the round that first approves a pull
# request and a later 2.1e landing-retry re-arm without the two ever risking
# disagreement.
#
# Reads the union of SRC1 and SRC2, deduplicated — never either alone. On the
# round that first approves a pull request, `$log_file` (this process's own
# just-written `approver-verdict` event is already there — `log_event`
# appends synchronously, before `_landing_stage_attempt` ever runs) misses
# any peer node's refusal that only ever reached the fleet's `$union_log`
# snapshot (built once at cycle start, so it never carries this round's own
# just-written event either); on a 2.1e landing-retry re-arm, `$union_log`
# alone would equally miss nothing new, since the approving round belongs to
# an earlier cycle and is already folded into it. Neither source alone is
# ever the full history for either round, which is why both callers now pass
# `$union_log` as SRC1 and `${log_file:-}` as SRC2 unconditionally. SRC1 may
# be "-" for stdin (matching every reader in lib/cycle-state.sh); SRC2, if
# given, is always a path, never stdin. Either argument may be a missing,
# empty or unreadable path — that source simply contributes nothing. Rows
# are deduplicated on the whole emitted object (SRC1 and SRC2 commonly
# overlap on this node's own events), not `.ts` alone, since two distinct
# events can share a timestamp. Malformed lines are skipped, not fatal.
# Always prints a JSON array, `[]` rather than empty output, so a caller can
# `--argjson` it straight into the audit record with no fallback of its own.
landing_approver_adjudication_history() {
  local pr_url="$1" src1="${2:--}" src2="${3:-}" out=""
  # shellcheck disable=SC2016  # $pr_url is jq's own --arg variable, not the shell's.
  local jq_prog='
    [ .[] | select(.event == "approver-verdict" and (.pr_url // "") == $u)
      | {ts: (.ts // ""), tier: (.tier // null), model: (.model // null),
         verdict: (.verdict // null), adjudication: (.adjudication // false),
         refuse_streak: (.refuse_streak // null), posted: (.posted // null)} ]
    | unique_by([.ts, .tier, .model, .verdict, .adjudication, .refuse_streak, .posted])
    | sort_by(.ts)'
  if [[ "$src1" == "-" ]]; then
    if [[ -n "$src2" && -s "$src2" ]]; then
      out="$(cat - "$src2" 2>/dev/null | jq -c -R 'fromjson? // empty' 2>/dev/null \
        | jq -cs --arg u "$pr_url" "$jq_prog" 2>/dev/null || true)"
    else
      out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
        | jq -cs --arg u "$pr_url" "$jq_prog" 2>/dev/null || true)"
    fi
  else
    local -a files=()
    if [[ -s "$src1" ]]; then files+=("$src1"); fi
    if [[ -n "$src2" && -s "$src2" ]]; then files+=("$src2"); fi
    if [[ "${#files[@]}" -gt 0 ]]; then
      out="$(cat "${files[@]}" 2>/dev/null | jq -c -R 'fromjson? // empty' 2>/dev/null \
        | jq -cs --arg u "$pr_url" "$jq_prog" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# The following four functions moved from agent-cycle.sh (#771): the arming
# round itself (`run_landing_stage`, `_landing_stage_attempt`, gates and all),
# its refusal logger, and the 2.1e landing-retry sweep that re-enters the same
# gates for a stranded, already-approved pull request. Reads and writes the
# cycle's own globals (`cycle_dir`, `landing_armed_by_repo`, …) exactly as
# they did inline; `landing_armed_by_repo` itself stays declared in
# agent-cycle.sh, ahead of both this file's functions and the Enabler/Refiner
# state beside it, so nothing here reads it unset under `set -u`.
# _landing_refuse PR_URL REPO REASON [RETRY]
# Log `landing-refused` (requirement 8d, requirement 33). The one write
# every refusal path in `_landing_stage_attempt` makes — never a blocked pull
# request, never a withheld claim, exactly as an Approver refusal (8b/8c)
# costs a missing review and nothing else. RETRY, when non-empty, marks the
# event `retry: true` (TD-PPagop-26081701) — a fact worth keeping distinct in
# the log, since it means the refusal happened outside the round that first
# approved this pull request.
_landing_refuse() {
  local retry_bool="false"
  [[ -z "${4:-}" ]] || retry_bool="true"
  log_event "landing-refused" "$(jq -nc --arg u "$1" --arg r "$2" --arg reason "$3" --argjson retry "$retry_bool" \
    '{pr_url: $u, repo: $r, reason: $reason} + (if $retry then {retry: true} else {} end)')"
}

# run_landing_stage PR_URL COMPLEXITY
# The arming step's own gate 0 (D18 WI-7,
# docs/reviews/2026-08-14-autonomy-investigation.md §5.1, §6, §7; requirement
# 8d). Called immediately after `run_approver_stage` — deliberately after,
# not folded into it: `run_approver_stage` is the review, and every failure
# mode `_landing_stage_attempt` has of its own (a budget hold, a protected
# path, a queue race) must never be confused for "the Approver refused to
# review", which requirement 8c's own `approver-verdict` event already
# speaks for.
#
# Arms nothing at all unless this very round's Approver engagement reached
# an explicit, non-adjudicating `approve` — read from `approver_stage_verdict`/
# `approver_stage_adjudicating`, the globals `run_approver_stage` set
# immediately before returning (never reused beyond this one read). Once that
# holds, every other gate is `_landing_stage_attempt`'s job — the same
# function the 2.1e landing-retry sweep calls for a pull request this gate
# already passed once, on a later cycle, for a repo and source this global
# scope does not carry (TD-PPagop-26081701; see that function's own header).
#
# Passes `landing_armed_by_repo[$selected_repo]` as ALREADY_ARMED (PR #557
# review round 2) rather than leaving it at `_landing_stage_attempt`'s own
# default of 0: the 2.1e sweep (`_landing_retry_sweep_repo`, run earlier this
# same cycle, well before this stage) may already have armed candidates for
# this repository, and this stage's own live `merge_budget_decide` read must
# discount those too, not just its own — the gap PR #557's first review round
# left, since that round's fix bounded only the sweep's own pass, and this
# call site threaded no ALREADY_ARMED at all.
run_landing_stage() {
  local pr_url="$1" complexity="$2"
  [[ "$approver_stage_verdict" == "approve" && "$approver_stage_adjudicating" != "1" ]] || return 0
  local already_armed="${landing_armed_by_repo[$selected_repo]:-0}"
  _landing_stage_attempt "$selected_repo" "$pr_url" "$complexity" "$selected_source" "$gate_default_branch" "" "$already_armed"
  if (( _landing_stage_attempt_armed )); then
    # shellcheck disable=SC2004  # false positive: landing_armed_by_repo is
    # declare -A (agent-cycle.sh) — its subscript is a literal string key,
    # never arithmetic, so the $ is required, not "unnecessary".
    landing_armed_by_repo[$selected_repo]=$(( already_armed + 1 ))
  fi
}

# _landing_stage_attempt SLUG PR_URL COMPLEXITY SOURCE DEFAULT_BRANCH [RETRY] [ALREADY_ARMED]
# The seven re-read-fresh gates the arming step re-reads before landing a pull
# request — extracted out of `run_landing_stage` (TD-PPagop-26081701) so the
# 2.1e landing-retry sweep can reuse the identical, single-source-of-truth
# sequence for a pull request outside the round that first approved it,
# rather than a second copy that could drift from what this one actually
# does. SLUG, SOURCE and DEFAULT_BRANCH are parameters rather than
# `$selected_repo`/`$selected_source`/`$gate_default_branch` for exactly that
# reason: the retry sweep runs fleet-wide, for a repository, an originating
# work-order source and a default branch none of those globals carry this
# cycle. RETRY, when non-empty, is threaded through to `_landing_refuse` and
# the final `landing-armed` log as `retry: true` — see that function's own
# header. ALREADY_ARMED (default 0; PR #557 review of TD-PPagop-26081701) is
# forwarded to `merge_budget_decide` verbatim (gate 5 below) — how many pull
# requests this repository has already been armed for earlier in this same
# cycle, by either caller, and therefore how far this candidate's own live
# budget read must be discounted before it can arm another; both callers read
# and grow the same cycle-scoped `landing_armed_by_repo[SLUG]` (declared
# ahead of both, PR #557 review round 2) rather than a tally of their own, so
# a repository's remaining budget is never double-spent across the sweep and
# this round's own arming step just because neither call site knew what the
# other had already armed. Sets the global `_landing_stage_attempt_armed`
# to `1` immediately after a successful arm and to `0` at every other return
# (including every refusal) — the one signal a caller can use to grow its own
# running ALREADY_ARMED count for the next candidate, since this function's
# own exit status stays `0` on every path (a refusal costs a `landing-refused`
# event, never a non-zero return) and cannot carry that.
#
# Everything below is re-read fresh from GitHub, the discipline
# `lib/review-gate.sh` established, because nothing this stage arms may
# trust state more than one function call old:
#
#   1. `merge_autonomy_effective_level`, called with `fresh` (issue #513) so
#      the kill switch bypasses this process's own memo — must still be
#      `agent-merges-routine` or `agent-merges-all` (the kill switch or a
#      budget freeze may have moved since the Approver ran). A refusal here
#      names its actual cause (`landing_autonomy_refusal_reason`, D18 issue
#      #576) — the fleet-wide kill switch, distinguishable in the
#      `landing-refused` log from a repository that simply never had its
#      level raised — rather than always blaming "the level", which a human
#      reading the log has no reason to suspect they set correctly.
#   2. `landing_eligible` (lib/landing.sh) — complexity, source and the
#      protected-paths classifier.
#   2.5. `landing_open_question_hit` (lib/landing.sh, requirement 8f, D18,
#      agent-ops#668) — the `open-question` label the Reviewer's own
#      `open_questions` verdict projects must not be standing. A hit does not
#      merely refuse: `_landing_open_question_resolve` runs the
#      `escalation_autonomy` ladder for it (an escalation issue, or one
#      bounded adjudication pass first), and only a `settled` verdict lets
#      this round fall through to gate 3. Unlike every other unreadable
#      here, an unreadable label list refuses in the plain "could not read"
#      wording rather than routing into that ladder — see that function's
#      own header for why a question never confirmed to exist must not
#      summon anybody.
#   3. `review_gate_verdict` — must read `clean`; `dirty` and `unknown`
#      both refuse (stricter than the ordinary ready-gate handoff, which
#      tolerates an alerts-only `unknown` as a warning — arming an
#      automatic merge does not).
#   4. The Approver App's own review is genuinely standing `APPROVED` on
#      GitHub right now (`landing_approver_standing_review_at`,
#      lib/landing.sh)
#      — never inferred from this round's own `approver_stage_verdict`
#      alone: `approver_post_or_warn` always returns 0 even when the write
#      itself failed ("a missing review, never a stranded PR"), so a local
#      `approve` verdict is this process's *intent*, not GitHub's own
#      record — and no human `CHANGES_REQUESTED` stands
#      (`_handoff_blocking_reviewers`, lib/handoff.sh, requirement 34a's own
#      standing-position computation, reused for the human half rather than
#      re-derived). Both are fresh reads: a token that expired between
#      minting and posting, or a push/review submitted after the Approver
#      ran, are exactly the facts this step must catch.
#
#      Neither read sees a plain comment: a human cannot leave a formal
#      `REQUEST_CHANGES` review on this system's own pull requests at all
#      (GitHub refuses that review type from a pull request's own author, and
#      every pipeline write and every human comment here land under the same
#      account), so their only instrument is an ordinary comment, and
#      `_handoff_blocking_reviewers` reads only formal reviews. #533 closed
#      that gap at the Reviewer's own ready-flip
#      (`lib/reconciliation-gate.sh`'s `reconciliation_gate`, requirement
#      31c): a pull request carrying an unreconciled comment since it last
#      left draft cannot be flipped Ready in the first place. That gate runs
#      once, at hand-off, and never reaches here — a plain comment posted
#      after a pull request is already Ready, in the window before a later
#      cycle's arming step lands it, was answered by neither mechanism
#      (agent-ops#672). Gate 4 closes that residual window by calling
#      `reconciliation_gate` itself, a second time, right here: unbounded (no
#      NOT_AFTER), since this stage never flips the pull request out of draft
#      itself the way the Reviewer's own call must guard against — the real
#      current "last left draft, and stayed left" anchor is exactly the one
#      this arming read needs, not one bounded away from a flip of its own.
#      `dirty` refuses arming, naming the unreconciled comment(s); anything
#      else that is not `clean` — `unknown`, where the timeline or comment
#      list could not be read, and the empty word a call that never ran at
#      all leaves behind — refuses too (#753's ruling on #746): neither
#      should ever pass a safety gate, unlike the Reviewer's own
#      reconciliation read at hand-off (`handoff_complete_review`), which
#      does tolerate an `unknown` there as non-blocking — this arming-time
#      instance is stricter by design. Because every non-`clean` word now
#      refuses before this function can reach an arm, the landing audit
#      record (requirement 8x) never carries a `comment-reconciliation`
#      entry reading anything but `clean`.
#   4.5. D18 WI-12 (Stage 4, agent-ops#415): only at `agent-merges-all`, and
#      only for a pull request `landing_protected_path_controls_ok`
#      (lib/landing.sh) itself confirms still touches a protected path —
#      gate 2's own `landing_eligible` already deferred rather than refused
#      that case. Requires the approving engagement to have run at the
#      critical Approver tier, the standing review's own `commit_id` (gate
#      4's own `landing_approver_standing_review_at` read, no extra `gh`
#      call) to still match a fresh read of the pull request's current
#      `headRefOid`, and the configurable `landing_cool_off_hours` wait
#      since that review's own `submitted_at` to have elapsed. A push after
#      approval moves `headRefOid` without touching the standing review at
#      all — nothing here dismisses a stale review — so a `commit_id`
#      mismatch refuses outright rather than measuring a cool-off against a
#      timestamp that no longer speaks for the code on the branch; this is
#      the sense in which a fresh push restarts the wait, since nothing
#      resumes it until a later review matches the new head. TIER comes from
#      this round's own `approver_stage_tier` on the first-approval round, or
#      `landing_retry_tier`'s fleet-log read on a retry — never re-derived.
#   5. `merge_budget_decide`/`merge_budget_apply_decision`
#      (lib/merge-budget.sh) — only `arm` proceeds; `hold` and `refuse` are
#      applied and stop here.
#   6. `merge_queue_probe` — the pull request must not already be queued,
#      and must never have been queued and removed without being re-queued
#      since (`merge_queue_dequeue_actionable`, lib/merge-queue.sh, PR #557
#      review of TD-PPagop-26081701, distinguishes only the refusal wording —
#      never re-arms either way; `scripts/gather-dequeued.sh`'s own source
#      owns a `failed_checks` dequeue, and a human's own `manual` one is
#      never this stage's to reverse). "Could not read" is "possibly queued
#      or dequeued", so it refuses too.
#
# Any read above that cannot be answered is a refusal (`_landing_refuse`,
# `landing-refused`), never a pass. Every REASON this function or its own
# helpers hand to `_landing_refuse` carries a short, GitHub-URL-free class
# word ahead of its own first `:` — `landing_eligible`'s and
# `landing_protected_path_controls_ok`'s `ineligible:`/`unknown:`,
# `landing_autonomy_refusal_reason`'s `kill-switch:`, gate 3's own
# `review gate:`, this function's own `malformed-pr-url:`/
# `open-question-unreadable:`/`approver-review-unreadable:`/
# `approver-review-not-approved:`/`human-veto-unreadable:`/
# `human-changes-requested:`/`reconciliation-unanswered:`/
# `reconciliation-unreadable:`/`merge-queue-unreadable:`/
# `dequeued-actionable:`/`dequeued-manual:`/`arm-failed:` — so
# `scripts/publish-dashboard.sh`'s landings digest (`byReason`,
# `dashboard/index.html`) groups by that word rather than by the text before
# whatever colon happens to occur first, which for a sentence-form refusal
# embedding `$pr_url` (itself a `https://…` string) is the URL's own scheme
# colon (TD-PPagop-26082502). A message carrying no colon at all, and so no
# varying content a split could cut it off at — "could not read the Approver
# App's own login", "already in the merge queue", "could not mint the
# Approver's installation token", `landing_autonomy_refusal_reason`'s plain
# "effective level is …" — needs no prefix: the whole string is already a
# stable, single group. A successful arm logs `landing-armed`
# exactly once, naming the method (`enqueued`/`auto-merge`) `landing_arm`
# actually used, and never withholds anything requirement 8b already did —
# the *first* attempt (RETRY empty) runs strictly after the `pr-ready` log
# and the claim release, and nothing here can affect either; a retry attempt
# runs long after both, against a pull request already sitting `pr-ready`.
#
# A successful arm also logs `landing-audit-record` (requirement 8x, D18,
# agent-ops#578) — one durable record of everything that justified landing
# this pull request without a human act anywhere in the chain, assembled
# here rather than reconstructed later by joining separate events at report
# time (the WI-8 digest's own former failure mode: a landing whose verdict
# could not be found rendered with nulls rather than saying so). It carries
# the pull request's own number and `review_commit_sha` (the Approver's
# standing review's own `commit_id`, already in hand from gate 4 — never a
# fresh read for a fact this cheap to reuse; the commit the Approver approved,
# not necessarily the commit that actually merged), the effective
# `merge_autonomy` level and whether SLUG's own `repos[]` entry or the
# top-level key produced it (`merge_autonomy_resolution_source`,
# lib/merge-autonomy.sh — reached only once gate 1 has already confirmed the
# kill switch is clear and no budget freeze binds, so no fresher read is
# needed), the protected-path verdict and the protected paths it hit
# (`landing_protected_paths_hit`, read fresh once more here — the same
# "never more than one function call old" discipline gate 4.5's own
# `landing_protected_path_controls_ok` already applies to the same
# primitive, rather than trust gate 2's now-discarded read), the Approver's
# tier/model/verdict/adjudication and this pull request's full adjudication
# history (`landing_approver_adjudication_history`, lib/landing.sh — the
# fleet log's own record of every `approver-verdict` event this pull request
# ever received, not only the one that authorised this landing), every
# deterministic gate this function itself just passed with its own
# evidence — including the human-veto gate's own `blocking_reviewers` list
# (`_handoff_blocking_reviewers`'s return at gate 4, empty on every arm),
# carried beside that gate's verdict the same way the top-level
# `protected_path` object already names the paths it examined — the
# `merge_budget_decide` object gate 5 already computed and would otherwise
# discard the moment `decision == "arm"` was confirmed, and the landing
# mechanism `landing_arm` actually used. `scripts/publish-dashboard.sh`'s
# WI-8 digest reads this record instead of re-joining `approver-verdict`
# events against `landing-armed`, and reports a `landing-armed` with no
# matching record as an anomaly in its own right.
_landing_stage_attempt() {
  local slug="$1" pr_url="$2" complexity="$3" source="$4" default_branch="${5:-main}" retry="${6:-}" already_armed="${7:-0}"
  local number level
  _landing_stage_attempt_armed=0

  if [[ "$pr_url" =~ /pull/([0-9]+)$ ]]; then
    number="${BASH_REMATCH[1]}"
  else
    _landing_refuse "$pr_url" "$slug" "malformed-pr-url:could not parse a pull request number from $pr_url" "$retry"
    return 0
  fi

  # `fresh` (issue #513, PR #506 review follow-up): this stage arms a real
  # merge/enqueue under the level it reads, so an operator's mid-cycle kill
  # must stop it here, not wait for the next cycle's process — see
  # merge_autonomy_effective_level's own comment on FRESH, and
  # run_approver_stage's identical read immediately before this one.
  level="$(merge_autonomy_effective_level "$DEFAULTED_CONFIG" "$slug" "$state_repo" "$state_dir" fresh)"
  case "$level" in
    agent-merges-routine|agent-merges-all) ;;
    *)
      _landing_refuse "$pr_url" "$slug" "$(landing_autonomy_refusal_reason "$state_repo" "$state_dir" "$level" fresh)" "$retry"
      return 0
      ;;
  esac

  local elig
  elig="$(landing_eligible "$DEFAULTED_CONFIG" "$slug" "$number" "$complexity" "$source" "$level")"
  if [[ "$elig" != "eligible" ]]; then
    _landing_refuse "$pr_url" "$slug" "$elig" "$retry"
    return 0
  fi

  # Gate 2.5 (requirement 8f, D18, agent-ops#668): an open question the
  # Reviewer raised against this pull request's work order or scope, and
  # could not settle itself, holds unattended landing until an adjudication
  # pass settles it or a human acts — read fresh from GitHub every round,
  # exactly like every other gate here, so a human's own removal of the
  # label is seen the moment it happens. Unlike `landing_protected_paths_
  # hit`'s own exit 2, an unreadable label list here is a plain, retryable
  # read failure — it refuses with the ordinary "could not read" wording and
  # tries again next cycle, rather than routing into the escalation/
  # adjudication machinery over a question it never confirmed exists.
  # `oq_word` is this gate's own verdict for the landing audit record
  # (requirement 8x, which carries *every* gate this function passed): `clear`
  # when no question stood, `settled` when one did and the adjudication pass
  # answered it on this very round. No other value can reach the record — every
  # other outcome returns above without arming anything.
  local oq_hit_rc=0 oq_word="clear"
  landing_open_question_hit "$slug" "$number" || oq_hit_rc=$?
  case "$oq_hit_rc" in
    1) ;; # clear — no open question stands.
    2)
      _landing_refuse "$pr_url" "$slug" "open-question-unreadable:could not read $pr_url's own labels to confirm no open question stands" "$retry"
      return 0
      ;;
    0)
      if ! _landing_open_question_resolve "$slug" "$pr_url" "$number" "$retry"; then
        return 0
      fi
      oq_word="settled"
      ;;
  esac

  # `review_gate_verdict` speaks in its exit status as well as its word: 1 for
  # `dirty`, 2 when the required-check list itself could not be read (see its
  # own header, which tells every caller to capture that status rather than
  # discard it — `lib/handoff.sh`'s `if gate_combined="$(…)"` is the other
  # site). Captured with `|| gate_rc=$?` rather than a bare assignment because
  # this file runs under `errexit`, where a bare assignment does not merely
  # discard the status: it aborts the whole cycle mid-stage, on the two
  # verdicts — a red required check, an unreadable check list — this gate
  # exists to refuse. A refusal here must cost one `landing-refused` event and
  # nothing else, exactly like every other gate in this function.
  local gate_combined gate_word gate_reason gate_rc=0
  gate_combined="$(review_gate_verdict "$pr_url" "$default_branch" 2>/dev/null)" || gate_rc=$?
  gate_word="${gate_combined%%$'\t'*}"
  gate_reason="${gate_combined#*$'\t'}"
  if [[ "$gate_word" != "clean" || "$gate_rc" != "0" ]]; then
    _landing_refuse "$pr_url" "$slug" \
      "review gate: ${gate_reason:-${gate_word:-unreadable (review_gate_verdict exited $gate_rc)}}" "$retry"
    return 0
  fi

  local login
  if ! login="$(approver_token_identity_login "")" || [[ -z "$login" ]]; then
    _landing_refuse "$pr_url" "$slug" "could not read the Approver App's own login" "$retry"
    return 0
  fi

  # `_at` rather than the plain reader: D18 WI-12's protected-path cool-off
  # (gate 4.5, below) is measured from this exact standing review's own
  # `submitted_at`, and reset by its own `commit_id`, at no extra `gh` call —
  # the same one reviews-list read either function makes (lib/landing.sh's
  # own header).
  local standing_at standing submitted_at review_commit rest
  if ! standing_at="$(landing_approver_standing_review_at "$slug" "$number" "$login")"; then
    _landing_refuse "$pr_url" "$slug" "approver-review-unreadable:could not read $pr_url's own review list to confirm the Approver's review actually landed" "$retry"
    return 0
  fi
  standing="${standing_at%%$'\t'*}"
  rest="${standing_at#*$'\t'}"
  submitted_at="${rest%%$'\t'*}"
  review_commit="${rest#*$'\t'}"
  if [[ "$standing" != "APPROVED" ]]; then
    _landing_refuse "$pr_url" "$slug" "approver-review-not-approved:the Approver's own review is not standing APPROVED on GitHub (state: ${standing:-none})" "$retry"
    return 0
  fi

  local blocking
  if ! blocking="$(_handoff_blocking_reviewers "$slug" "$number")"; then
    _landing_refuse "$pr_url" "$slug" "human-veto-unreadable:could not read $pr_url's own review list to confirm no human CHANGES_REQUESTED stands" "$retry"
    return 0
  fi
  if [[ -n "$blocking" ]]; then
    _landing_refuse "$pr_url" "$slug" "human-changes-requested:a human CHANGES_REQUESTED stands ($(paste -sd, - <<<"$blocking"))" "$retry"
    return 0
  fi

  # agent-ops#672: closes the residual human-veto gap `_handoff_blocking_
  # reviewers` above cannot see — a plain comment posted after this pull
  # request was already Ready. Unbounded (no NOT_AFTER): this stage never
  # flips the pull request out of draft itself, so the raw "most recent
  # ready_for_review event, not since undone" already is the anchor this read
  # needs (see this function's own header comment on gate 4, and
  # `_reconciliation_gate_anchor`'s header on why a caller that does flip the
  # pull request must bound it and this one must not).
  local rc_combined rc_word rc_reason
  rc_combined="$(reconciliation_gate "$pr_url")" || true
  IFS=$'\t' read -r rc_word rc_reason <<<"$rc_combined"
  if [[ "$rc_word" == "dirty" ]]; then
    _landing_refuse "$pr_url" "$slug" "reconciliation-unanswered:$rc_reason" "$retry"
    return 0
  fi
  # Anything that is not `clean` refuses arming outright, never falls through
  # as a pass: the empty word a call that never executed at all leaves behind
  # (`|| true` swallows a `command not found` exactly as it swallows the exit
  # 1 a `dirty` verdict reports, and both arrive here as a bare string) would
  # otherwise clear this gate silently, logging nothing and recording nothing
  # — a veto check reading "clear" on the one path where it did not run is
  # the failure this gate exists to prevent. `unknown` from a read that
  # genuinely ran and the empty word a call that never ran leaves behind are
  # not distinguished: neither should ever pass a safety gate (#753's own
  # ruling on #746) — this is stricter than the ordinary ready-gate handoff,
  # which does tolerate `unknown` as a warning, because arming an automatic
  # merge is not that.
  if [[ "$rc_word" != "clean" ]]; then
    _landing_refuse "$pr_url" "$slug" \
      "reconciliation-unreadable:could not confirm every human comment on $pr_url since it last left draft is reconciled: ${rc_reason:-reconciliation_gate answered ${rc_word:-nothing at all}}" "$retry"
    return 0
  fi

  # Gate 4.5 (D18 WI-12, Stage 4, agent-ops#415): the protected-path
  # compensating controls — critical-tier approval, the standing review's
  # `commit_id` still matching the pull request's current head, and the
  # cool-off since the review's own `submitted_at` — only ever bind at
  # `agent-merges-all`, and only for a pull request
  # `landing_protected_path_controls_ok` itself confirms still touches a
  # protected path (gate 2's own `landing_eligible` already deferred that
  # decision here rather than refusing outright, see its own header). TIER
  # is this round's own in-process fact on the first-approval round
  # (`run_approver_stage`'s `approver_stage_tier`), or read back from the
  # fleet log's `approver-verdict` event on a retry (`landing_retry_tier`) —
  # a retry attempt has no in-process fact for a pull request this process
  # never claimed, the same reasoning `landing_retry_source` already applies
  # to a work order's own source.
  if [[ "$level" == "agent-merges-all" ]]; then
    local pp_tier pp_ctl
    if [[ -n "$retry" ]]; then
      pp_tier="$(landing_retry_tier "$pr_url" "$union_log")"
    else
      pp_tier="$approver_stage_tier"
    fi
    pp_ctl="$(landing_protected_path_controls_ok "$DEFAULTED_CONFIG" "$slug" "$number" "$pp_tier" "$submitted_at" "$review_commit")"
    if [[ "$pp_ctl" != "ok" ]]; then
      _landing_refuse "$pr_url" "$slug" "$pp_ctl" "$retry"
      return 0
    fi
  fi

  local budget_json budget_decision
  budget_json="$(merge_budget_decide "$DEFAULTED_CONFIG" "$slug" "$pr_label" "$login" "" "$already_armed")"
  budget_decision="$(jq -r '.decision' <<<"$budget_json" 2>/dev/null)"
  if [[ "$budget_decision" != "arm" ]]; then
    merge_budget_apply_decision "$budget_json" "$slug" "$state_repo" "$enabler_escalation_label" "$enabler_assignee"
    return 0
  fi

  local queue_json queued dequeue_reason
  if ! queue_json="$(merge_queue_probe "$slug" "$number")"; then
    _landing_refuse "$pr_url" "$slug" "merge-queue-unreadable:could not read $pr_url's merge-queue status" "$retry"
    return 0
  fi
  queued="$(jq -r '.queued' <<<"$queue_json" 2>/dev/null)"
  if [[ "$queued" != "false" ]]; then
    _landing_refuse "$pr_url" "$slug" "already in the merge queue" "$retry"
    return 0
  fi
  # A dequeue is otherwise invisible on an open pull request (PR #557 review
  # of TD-PPagop-26081701): `queued` alone reads identically whether GitHub
  # has never queued this pull request or removed it once and nobody has
  # re-queued it since, and this stage must never arm the second case. Every
  # `dequeue_reason` this scans for is `merge_queue_dequeue_actionable`
  # (lib/merge-queue.sh): `manual` is the maintainer's own removal ("they
  # caused it, so they already know" — re-enqueueing here would silently
  # reverse it, every cycle, for as long as the pull request stays open) and
  # any other reason (chiefly `failed_checks`) is exactly what
  # `scripts/gather-dequeued.sh`'s own `dequeued` source exists to diagnose
  # and fix before a human re-queues — arming it blindly here instead would
  # re-run the same failing merge group every cycle, an unbounded CI cost for
  # no forward progress. Neither reading is this stage's to retry: gate 5's
  # own comment already draws the line between "this gate refuses and a
  # later re-entry may succeed" and "a different mechanism owns this pull
  # request now", and a dequeue is the latter, not the former.
  dequeue_reason="$(jq -r '.dequeue_reason // empty' <<<"$queue_json" 2>/dev/null)"
  if [[ -n "$dequeue_reason" ]]; then
    if merge_queue_dequeue_actionable "$dequeue_reason"; then
      _landing_refuse "$pr_url" "$slug" \
        "dequeued-actionable:GitHub's merge queue removed $pr_url over a $dequeue_reason failure — the dequeued source's own diagnose-and-fix path and a fresh human 'Merge when ready' click land this, never a blind re-arm here" "$retry"
    else
      _landing_refuse "$pr_url" "$slug" \
        "dequeued-manual:GitHub's merge queue removed $pr_url (reason: $dequeue_reason) — a deliberate removal, so this stage never re-enqueues it" "$retry"
    fi
    return 0
  fi

  local token method arm_rc=0
  if ! token="$(approver_token_get "")"; then
    _landing_refuse "$pr_url" "$slug" "could not mint the Approver's installation token" "$retry"
    return 0
  fi
  # Captured with `|| arm_rc=$?` rather than a bare `if ! …; then`, matching
  # `review_gate_verdict`'s own capture above: `landing_arm`'s exit status is
  # itself the signal (agent-ops#532, see its own header) — a bare `if !`
  # would still branch correctly but discard the very code
  # `_landing_arm_failure_reason` needs to say which step failed.
  method="$(landing_arm "$slug" "$number" "$token")" || arm_rc=$?
  if (( arm_rc != 0 )); then
    _landing_refuse "$pr_url" "$slug" \
      "arm-failed:landing_arm could not enqueue or auto-merge $pr_url: $(_landing_arm_failure_reason "$arm_rc")" "$retry"
    return 0
  fi
  if [[ -z "$method" ]]; then
    _landing_refuse "$pr_url" "$slug" "arm-failed:landing_arm could not enqueue or auto-merge $pr_url: printed no method despite exiting 0" "$retry"
    return 0
  fi

  local retry_bool="false"
  [[ -z "$retry" ]] || retry_bool="true"
  # `cap`/`count` (D18 issue #574) are gate 5's own `budget_json`, already
  # paid for above — never a second read. This is the only place an `arm`
  # decision leaves any trace of the cap/count `merge_budget_decide` saw, so
  # a dashboard tick can source a repository's current consumption from the
  # same rolling-24h count `lib/merge-budget.sh` uses (never a private
  # counter) without a live read of its own: the latest of this event and
  # `merge-budget-hold`/`merge-budget-frozen` for a repository is that
  # repository's last-known budget state.
  local budget_cap budget_count
  budget_cap="$(jq -r '.cap' <<<"$budget_json")"
  budget_count="$(jq -c '.count' <<<"$budget_json")"
  # `level` is the *effective* level gate 1 above actually judged this arm
  # against — kill switch and per-repo merge-budget freeze already folded in
  # by `merge_autonomy_effective_level`. It is written down here because this
  # is the only moment anything knows it: requirement 8e's audit
  # (`scripts/detect-classifier-escapes.sh`) runs post hoc with no state-repo
  # access, so it can no more reconstruct the level in force at this instant
  # than it can the work source recorded beside it. Left unrecorded, that
  # audit had to read today's `config.json` instead, which breaks its own
  # governing invariant in both directions: an operator's later dial-down —
  # the exact move D18 staging makes, and the direction an incident would
  # move it — manufactures a `classifier-escape` out of a landing that was
  # correct when it happened, driving the Stage 2 "zero classifier escapes"
  # exit criterion non-zero on an action with nothing wrong with it; and a
  # since-cleared kill switch or since-lifted freeze reads a level that
  # actually forbade landing as one that permitted it. One field closes both.
  log_event "landing-armed" "$(jq -nc --arg u "$pr_url" --arg r "$slug" --arg src "$source" \
    --arg c "$complexity" --arg m "$method" --arg lvl "$level" --argjson retry "$retry_bool" \
    --argjson cap "$budget_cap" --argjson count "$budget_count" \
    '{pr_url: $u, repo: $r, source: $src, complexity: $c, method: $m, level: $lvl, cap: $cap, count: $count} + (if $retry then {retry: true} else {} end)')"

  # requirement 8x (D18, agent-ops#578) — see this function's own header for
  # what each field is and why it costs no extra read beyond the one line
  # below actually needs.
  local autonomy_source
  autonomy_source="$(merge_autonomy_resolution_source "$DEFAULTED_CONFIG" "$slug")"

  local pp_hit_rc=0 pp_hit_paths="" pp_verdict pp_paths_json
  pp_hit_paths="$(landing_protected_paths_hit "$DEFAULTED_CONFIG" "$slug" "$number")" || pp_hit_rc=$?
  case "$pp_hit_rc" in
    0) pp_verdict="hit" ;;
    1) pp_verdict="clear" ;;
    *) pp_verdict="unknown" ;;
  esac
  if [[ "$pp_hit_rc" == "0" ]]; then
    pp_paths_json="$(jq -R -s 'split("\n") | map(select(length > 0))' <<<"$pp_hit_paths")"
  else
    pp_paths_json='[]'
  fi

  local approver_history_json approver_latest_json
  approver_history_json="$(landing_approver_adjudication_history "$pr_url" "$union_log" "${log_file:-}")"
  [[ -n "$approver_history_json" ]] || approver_history_json='[]'
  approver_latest_json="$(jq -c 'if length > 0 then .[-1] else {} end' <<<"$approver_history_json" 2>/dev/null)"
  [[ -n "$approver_latest_json" ]] || approver_latest_json='{}'

  # `blocking_json` is `_handoff_blocking_reviewers`'s own return (`blocking`,
  # bound at gate 4 above) — always empty here, since a non-empty list already
  # refused at that gate and never reached this line. Carried anyway, the same
  # way the record's top-level `protected_path` object already names the
  # paths it examined beside its verdict: the record should say what the
  # gate examined, not merely that the code reached this line
  # (TD-PPagop-26082312).
  local blocking_json
  blocking_json="$(jq -R -s 'split("\n") | map(select(length > 0))' <<<"$blocking")"

  local gates_json
  gates_json="$(jq -nc \
    --arg level "$level" --arg elig "$elig" --arg gate_word "$gate_word" \
    --arg standing "$standing" --arg pp_ctl "${pp_ctl:-n/a}" \
    --arg rc_word "${rc_word:-}" --arg oq "${oq_word:-clear}" \
    --arg budget_decision "$budget_decision" --arg queued "$queued" \
    --argjson blocking_reviewers "$blocking_json" \
    '[
      {gate: "autonomy-level", verdict: $level},
      {gate: "eligibility", verdict: $elig},
      {gate: "open-question", verdict: $oq},
      {gate: "review-gate", verdict: $gate_word},
      {gate: "approver-standing-review", verdict: $standing},
      {gate: "human-veto",
       verdict: (if ($blocking_reviewers | length) == 0 then "clear" else "blocking" end),
       blocking_reviewers: $blocking_reviewers},
      {gate: "comment-reconciliation",
       verdict: (if $rc_word == "" then "unknown" else $rc_word end)},
      {gate: "protected-path-controls", verdict: $pp_ctl},
      {gate: "merge-budget", verdict: $budget_decision},
      {gate: "merge-queue", verdict: (if $queued == "false" then "clear" else $queued end)}
    ]')"

  log_event "landing-audit-record" "$(jq -nc \
    --arg u "$pr_url" --arg r "$slug" --argjson n "$number" --arg sha "${review_commit:-}" \
    --arg src "$source" --arg c "$complexity" --arg level "$level" --arg asrc "$autonomy_source" \
    --arg ppv "$pp_verdict" --argjson pp_paths "$pp_paths_json" \
    --argjson approver_latest "$approver_latest_json" --argjson approver_hist "$approver_history_json" \
    --argjson gates "$gates_json" --argjson budget "$budget_json" \
    --arg m "$method" --argjson retry "$retry_bool" \
    '{
      pr_url: $u, repo: $r, number: $n, review_commit_sha: (if $sha == "" then null else $sha end),
      source: $src, complexity: $c,
      autonomy: {level: $level, source: $asrc},
      protected_path: {verdict: $ppv, paths: $pp_paths},
      approver: {tier: ($approver_latest.tier // null), model: ($approver_latest.model // null),
                 verdict: ($approver_latest.verdict // null),
                 adjudication: ($approver_latest.adjudication // false),
                 history: $approver_hist},
      gates: $gates,
      budget: $budget,
      mechanism: $m
    } + (if $retry then {retry: true} else {} end)')"

  _landing_stage_attempt_armed=1
}

# _landing_open_question_resolve SLUG PR_URL NUMBER [RETRY]
# Requirement 8f's own escalation/adjudication ladder, factored out of
# `_landing_stage_attempt`'s gate 2.5 so that gate's own `case` stays as
# short as every other gate's inline check. Returns 0 when the question is
# settled this round — the caller falls through to the next gate exactly as
# a `clear` read would have — and 1 when it refused and logged
# `landing-refused` itself, in which case the caller must return without
# running any further gate.
_landing_open_question_resolve() {
  local slug="$1" pr_url="$2" number="$3" retry="${4:-}"
  local item_ref level adjudication verdict evidence answer
  item_ref="pr-${number}-open-question"
  level="$(escalation_autonomy_configured_level "$DEFAULTED_CONFIG" "$slug")"

  if [[ "$level" == "adjudicate-first" ]] && open_question_pass_available "$slug" "$pr_url" "$item_ref"; then
    adjudication="$(run_open_question_adjudication "$slug" "$pr_url" "$number")"
    verdict="$(jq -r '.verdict // ""' <<<"$adjudication" 2>/dev/null)"
    evidence="$(jq -r '.evidence // ""' <<<"$adjudication" 2>/dev/null)"
    [[ "$verdict" == "settled" ]] || verdict="escalate"
    log_event "open-question-adjudication" "$(jq -nc --arg u "$pr_url" --arg r "$slug" \
      --arg v "$verdict" --arg e "$evidence" \
      '{pr_url: $u, repo: $r, verdict: $v, evidence: $e, adjudication: true}')"
    if [[ "$verdict" == "settled" ]]; then
      answer="$(jq -r '.answer // ""' <<<"$adjudication" 2>/dev/null)"
      if [[ -n "$answer" ]]; then
        gh pr comment "$pr_url" --body "$(pipeline_comment_header approver-adjudicate-open-question "$node_name")

$answer

$(pipeline_comment_marker "$cycle_id" approver-adjudicate-open-question)" >/dev/null 2>&1 || \
          log_event "warning" "$(jq -nc --arg u "$pr_url" \
            --arg d "the open-question adjudication settled $pr_url but the answer could not be posted as a PR comment" \
            '{detail: $d, pr_url: $u}')"
      fi
      if landing_open_question_label_release "$slug" "$number"; then
        return 0
      fi
      log_event "warning" "$(jq -nc --arg u "$pr_url" --arg l "$LANDING_OPEN_QUESTION_LABEL" \
        --arg d "the open-question adjudication settled $pr_url but the $LANDING_OPEN_QUESTION_LABEL label could not be removed — it will settle again next round" \
        '{detail: $d, pr_url: $u, label: $l}')"
      return 0
    fi
    open_question_escalate "$slug" "$pr_url" "$item_ref" \
      "$(landing_open_question_latest "$pr_url" "${union_log:-$log_file}")" "$adjudication"
    _landing_refuse "$pr_url" "$slug" "open-question:$pr_url carries an unresolved open question the adjudication pass could not settle — see the escalation issue" "$retry"
    return 1
  fi

  open_question_escalate "$slug" "$pr_url" "$item_ref" \
    "$(landing_open_question_latest "$pr_url" "${union_log:-$log_file}")"
  _landing_refuse "$pr_url" "$slug" "open-question:$pr_url carries an unresolved open question — see the escalation issue" "$retry"
  return 1
}

# open_question_adjudicated_before PR_URL < union.jsonl
# Exit 0 when an `open-question-adjudication` event for PR_URL already
# exists in the log on stdin at or after the most recently logged
# `open-question-raised` for it — this question's one adjudication pass has
# been spent — and 1 otherwise. Mirrors `escalation_autonomy_adjudicated_
# before`'s own shape (lib/escalation-autonomy.sh, requirement 36b) for the
# bound agent-ops#668 names as identical: "one pass per question, per human
# touch."
open_question_adjudicated_before() {
  local pr_url="$1" hits
  hits="$(jq -r -R -n --arg u "$pr_url" '
    [inputs | select(length > 0) | (fromjson? // empty)] as $all
    | ([$all[] | select(.event == "open-question-raised" and (.pr_url // "") == $u) | (.ts // "")]
       | sort | last // "") as $raised_ts
    | [$all[] | select(.event == "open-question-adjudication"
                       and (.pr_url // "") == $u and (.ts // "") >= $raised_ts)]
    | length
  ' 2>/dev/null || echo 0)"
  [[ "$hits" =~ ^[0-9]+$ ]] && (( hits > 0 ))
}

# open_question_pass_available SLUG PR_URL ITEM_REF
# The bound on `adjudicate-first` for an open question (requirement 8f,
# mirroring requirement 36b's own `escalation_autonomy_pass_available`): one
# adjudication pass per question, per human touch. True (exit 0) when this
# question still has its pass to spend; false, having logged why, when it
# does not.
#
# The exemption mirrors 36b's own "issue-closed": a *closed* escalation
# issue carrying ITEM_REF in its body means a human has already acted on
# this exact question since the last pass, so the next one is the first
# since they did — read live from GitHub, never from the log, on the same
# "ask the thing that actually changed" reasoning `approver_refuse_streak`
# already applies to the Approver's own streak.
open_question_pass_available() {
  local slug="$1" pr_url="$2" item_ref="$3" closed
  closed="$(gh issue list -R "$slug" --label "$enabler_escalation_label" --state closed --search "$item_ref" \
              --json body 2>/dev/null \
            | jq -r --arg it "$item_ref" 'map(select(((.body // "") | contains($it)))) | length' 2>/dev/null || echo 0)"
  [[ "$closed" =~ ^[0-9]+$ ]] || closed=0
  (( closed > 0 )) && return 0
  open_question_adjudicated_before "$pr_url" < "${union_log:-$log_file}" || return 0
  log_event "warning" "$(jq -nc --arg u "$pr_url" --arg i "$item_ref" \
    --arg d "open-question: $pr_url has already spent its one adjudication pass for $item_ref and no human has acted on it since — escalating without adjudicating (escalation_autonomy is bounded per question, per human touch)" \
    '{detail: $d, pr_url: $u, item: $i}')"
  return 1
}

# run_open_question_adjudication SLUG PR_URL NUMBER
# One bounded adjudication pass (requirement 8f, mirroring requirement 36b's
# own `run_enabler_adjudication` in shape: bounded, once, verdict-plus-
# evidence logged) over a Reviewer's own open question against PR_URL — a
# fresh, narrow engagement at the Approver's own critical tier
# (`approver_model_critical`, the tier D18 §5.2 already reserves for
# litigated judgement), never `enabler_model`: the question is about whether
# this pull request's own diff and work order already answer it, the
# Approver's own ground, not a refinement disagreement.
#
# Distinct from requirement 8c's own refuse-streak adjudication in every way
# that requirement's own text calls for: different trigger (an open question
# stands, never a refuse streak), different prompt (`prompts/approver-
# adjudicate-open-question.md`, never `prompts/approver.md`), different
# input (the question and its own comment, never prior refusal bodies), and
# never conflated in the log — `open-question-adjudication` is its own
# event, carrying `adjudication: true` on the same footing as
# `enabler-adjudication`, never `approver-verdict`.
#
# Prints `{"verdict": "settled"|"escalate", "evidence": "...", "answer":
# "..."}` on stdout — `answer` is present only on `settled`, the text posted
# to the pull request. A missing prompt file, a disabled critical tier, a
# stage failure, or an unparseable verdict all print `escalate` with an
# `evidence` string naming why — "cannot settle" is not read as "nothing to
# settle" (requirement 8c).
run_open_question_adjudication() {
  local slug="$1" pr_url="$2" number="$3"
  local questions input prompt out rc=0 result parsed verdict evidence answer

  if [[ -z "$approver_model_critical" ]]; then
    printf '{"verdict":"escalate","evidence":"no approver_model_critical is configured to adjudicate this question"}'
    return 0
  fi
  if [[ ! -f "$PROMPTS_DIR/approver-adjudicate-open-question.md" ]]; then
    printf '{"verdict":"escalate","evidence":"no prompts/approver-adjudicate-open-question.md in this installation"}'
    return 0
  fi

  questions="$(landing_open_question_latest "$pr_url" "${union_log:-$log_file}")"
  [[ -n "$questions" && "$questions" != "null" ]] || questions='[]'

  input="$(jq -nc --arg r "$slug" --arg u "$pr_url" --argjson qs "$questions" \
    '{repo: $r, pr_url: $u, questions: $qs}' 2>/dev/null || true)"
  if [[ -z "$input" ]]; then
    printf '{"verdict":"escalate","evidence":"could not build the adjudication input"}'
    return 0
  fi

  prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" approver-adjudicate-open-question '{}')

## Runtime input for this adjudication

\`\`\`json
$(jq . <<<"$input")
\`\`\`
"
  out="$cycle_dir/approver-adjudicate-open-question-${number}.out"
  stage_budget_apply approver-adjudicate-open-question "$slug" "$approver_model_critical" '{}'
  if run_claude_stage approver-adjudicate-open-question "$(( stage_backstop_min * 60 ))" "$approver_model_critical" "$prompt" "$out" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" \
    --argjson m "$(metering_fields "$approver_model_critical" "$out" "$stage_gaps_json")" \
    '{stage: "approver-adjudicate-open-question", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
  rework_stage_rerun_maybe "approver-adjudicate-open-question" "$stage_kill_reason" "$slug" "" "$pr_url"

  result="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$result" 2>/dev/null || true)"
  if (( rc != 0 )) || [[ -z "$parsed" ]]; then
    if (( rc == 124 )); then
      printf '{"verdict":"escalate","evidence":"the adjudication engagement timed out"}'
    else
      printf '{"verdict":"escalate","evidence":"the adjudication engagement returned no parseable verdict"}'
    fi
    return 0
  fi
  verdict="$(jq -r '.verdict // ""' <<<"$parsed" 2>/dev/null || true)"
  evidence="$(jq -r '.evidence // ""' <<<"$parsed" 2>/dev/null || true)"
  answer="$(jq -r '.answer // ""' <<<"$parsed" 2>/dev/null || true)"
  if [[ "$verdict" == "settled" ]]; then
    jq -nc --arg v "settled" --arg e "$evidence" --arg a "$answer" '{verdict: $v, evidence: $e, answer: $a}' 2>/dev/null \
      || printf '{"verdict":"escalate","evidence":"could not encode the adjudication verdict"}'
  else
    jq -nc --arg v "escalate" --arg e "$evidence" '{verdict: $v, evidence: $e}' 2>/dev/null \
      || printf '{"verdict":"escalate","evidence":"could not encode the adjudication verdict"}'
  fi
}

# open_question_escalate REPO PR_URL ITEM_REF QUESTIONS_JSON [ADJUDICATION_JSON]
# File (or find already-filed, via `create_escalation_issue`'s own dedup)
# the escalation issue for a pull request an open question holds — land it,
# or leave the pull request refused and let a human decide. Mirrors
# `approver_escalate` exactly in shape (same dedup, same label, same
# load-bearing assignee), differing only in what it names: a question about
# the work order or its scope, never a diff the Approver refused twice.
# Takes REPO explicitly, never `$selected_repo` — this runs from
# `_landing_stage_attempt`, which the requirement 8u retry sweep calls once
# per candidate across every configured repository, not only the one this
# cycle selected.
open_question_escalate() {
  local repo="$1" pr_url="$2" item_ref="$3" questions_json="$4" adjudication_json="${5:-}"
  local body_file questions_text adj_section created
  body_file="$cycle_dir/open-question-escalation-${item_ref}.md"
  [[ -n "$questions_json" && "$questions_json" != "null" ]] || questions_json='[]'
  questions_text="$(jq -r 'if length == 0 then "(no question text recorded)" else
    map("- **" + (.question // "(no question given)") + "**\n  Why the Reviewer could not settle it: "
        + (.why_this_actor_cannot_settle_it // "(not given)") + "\n  " + (.comment_url // "")) | join("\n\n") end' \
    <<<"$questions_json" 2>/dev/null)"
  adj_section=""
  if [[ -n "$adjudication_json" && "$adjudication_json" != "{}" ]]; then
    adj_section="
## Adjudication attempted

$(jq -r '"- verdict: " + (.verdict // "escalate") + "\n- evidence: " + (.evidence // "(none given)")' <<<"$adjudication_json" 2>/dev/null)
"
  fi
  {
    printf '## What the autonomous pipeline needs from you\n\n'
    printf 'Review %s and answer the question below yourself — the Reviewer found nothing wrong with the diff, but raised a question about the work order or its scope that only you can settle.\n\n' "$pr_url"
    printf '## The question\n\n'
    printf '%s\n\n' "$questions_text"
    printf '%s' "$adj_section"
    cat <<OQ_ESC_BODY

## When you're done: answer, then take the label off

Answer the question on $pr_url — a comment is enough. Then
remove the \`$LANDING_OPEN_QUESTION_LABEL\` label from that pull request, and close this issue.

**Removing the label is what releases the pipeline.** Until it comes off — or
until an adjudication pass settles the question itself — no automatic landing
action is taken on this pull request.
Closing this issue alone does not clear it.

---
Item: \`$item_ref\` · pull request $pr_url
Raised by the Reviewer stage (D18, agent-ops#668) · cycle \`$cycle_id\` · node \`$node_name\`
OQ_ESC_BODY
  } > "$body_file"
  if created="$(create_escalation_issue "$repo" "$item_ref" \
        "$enabler_escalation_label" \
        "Open question on $pr_url needs your judgement" \
        "$body_file")" && [[ -n "$created" ]]; then
    log_event "open-question-escalated" "$(jq -nc --arg u "$pr_url" \
      --arg n "${created%%$'\t'*}" --arg iu "${created#*$'\t'}" \
      '{pr_url: $u, issue_number: ($n | tonumber), issue_url: $iu}')"
  else
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "$pr_url carries an unresolved open question, and the escalation issue could not be filed — will retry next cycle" \
      '{detail: $d, pr_url: $u}')"
  fi
}

# _landing_retry_sweep_repo SLUG RETRY_LOGIN
# One repository's own pass of the 2.1e landing-retry sweep
# (TD-PPagop-26081701) — every candidate this repository currently has,
# offered to `_landing_stage_attempt` with `RETRY` set. See that requirement
# for the full design; this function is the candidate rule alone:
#
#   - Same FRESH discipline every other landing read uses (issue #513): a
#     repository the kill switch or a budget freeze currently holds at
#     `human`/`agent-approves` is skipped before any further GitHub call —
#     `_landing_stage_attempt` would refuse every candidate on this gate
#     alone, so asking is pure cost for a repository this sweep cannot act
#     on regardless.
#   - A candidate is open, non-draft, carries `pr_label`, and its own
#     `complexity:*` label reads `low` or `medium` (never `high` — the
#     cheapest of the seven gates to pre-check, from data already fetched here,
#     so a permanently-ineligible pull request costs one list call per
#     repository per cycle rather than the changed-file read
#     `landing_eligible` would otherwise repeat forever).
#   - Only a pull request the Approver has genuinely, currently approved is
#     this sweep's business (`landing_approver_standing_review`, the same
#     fresh read `_landing_stage_attempt`'s own gate 4 makes) — one never
#     reviewed (still mid-Reviewer, or `run_approver_stage` never ran for it)
#     is not a stranded approval, it is ordinary in-flight work, and logging
#     a `landing-refused` against it every cycle would be pure noise.
#   - `landing_retry_source` (lib/landing.sh) resolves the pull request's
#     originating `source` from the fleet's own union log (`$union_log`) —
#     the one fact this sweep cannot re-read fresh from GitHub, because
#     GitHub carries no field for it and a pull request's source is fixed at
#     claim time regardless. A pull request whose source cannot be resolved
#     this cycle (the claim predates this node's log window, or the union
#     log itself could not be read) is skipped, never guessed at.
#
# Every remaining gate — level, eligibility, review, budget, queue, the arm
# itself — is `_landing_stage_attempt`'s alone; this function never repeats
# or second-guesses any of them, with one exception it must carry itself
# (PR #557 review of TD-PPagop-26081701): `merge_budget_decide`'s own count
# is GitHub's *merged*-PR record, which a pull request this same pass just
# armed does not join synchronously, so a naive per-candidate call would read
# every candidate against the same stale count and arm all of them regardless
# of the cap — 12 stranded approved pull requests each reading `count=0`
# against `merge_budget_per_day: 8`, say, all twelve arming, and the *next*
# cycle's own budget read then seeing 12 merged against a cap of 8 and
# tripping the counting-anomaly freeze against an operator who did nothing
# wrong. `armed_this_pass` below starts from — and, on every arm, writes
# back to — the cycle-scoped `landing_armed_by_repo[$slug]` (declared ahead
# of this function, PR #557 review round 2) rather than a tally private to
# this one pass: `run_landing_stage`'s own gate 0, called later the same
# cycle for whatever repository this round's own Implementer worked in,
# reads and grows the identical global, so a repository this sweep already
# armed candidates for cannot then have that round's own arming step push it
# one past `merge_budget_per_day` on a live count neither call site's own
# pass-local tally would have caught alone. Grown here (read off
# `_landing_stage_attempt`'s own `_landing_stage_attempt_armed` global
# immediately after each call, the one signal that function's own always-0
# exit status cannot carry) exactly as before within one pass; only the
# variable it starts from and feeds back into is no longer private to this
# function.
_landing_retry_sweep_repo() {
  local slug="$1" login="$2"
  local level default_branch open armed_this_pass="${landing_armed_by_repo[$slug]:-0}"

  level="$(merge_autonomy_effective_level "$DEFAULTED_CONFIG" "$slug" "$state_repo" "$state_dir" fresh)"
  case "$level" in
    agent-merges-routine|agent-merges-all) ;;
    *) return 0 ;;
  esac

  default_branch="$(gh api "repos/$slug" --jq '.default_branch' 2>/dev/null)" || default_branch=""
  [[ -n "$default_branch" ]] || default_branch="main"

  open="$(gh pr list -R "$slug" --state open --label "$pr_label" \
    --json number,url,headRefName,isDraft,labels --limit "$GITHUB_PR_LIST_LIMIT" 2>/dev/null || true)"
  jq -e 'type == "array"' <<<"$open" >/dev/null 2>&1 || open='[]'
  if github_pr_list_truncated "$(jq 'length' <<<"$open")"; then
    log_event "warning" "$(jq -nc --arg r "$slug" \
      --arg d "landing-retry sweep ($slug): the pull-request listing came back at its ${GITHUB_PR_LIST_LIMIT}-item cap; a stranded pull request beyond it is not retried this cycle" \
      '{detail: $d, repo: $r}')"
  fi

  local candidates
  candidates="$(jq -c '[.[] | select(.isDraft | not)
    | . + {complexity: ((.labels // []) | map(.name) | map(select(startswith("complexity:"))) | first // "" | sub("^complexity:";""))}
    | select(.complexity == "low" or .complexity == "medium")
    | {number, url, branch: .headRefName, complexity}]' <<<"$open" 2>/dev/null || echo '[]')"

  local cand pr_url branch number complexity standing source
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    pr_url="$(jq -r '.url' <<<"$cand")"
    branch="$(jq -r '.branch' <<<"$cand")"
    number="$(jq -r '.number' <<<"$cand")"
    complexity="$(jq -r '.complexity' <<<"$cand")"

    standing="$(landing_approver_standing_review "$slug" "$number" "$login" 2>/dev/null)" || continue
    [[ "$standing" == "APPROVED" ]] || continue

    source="$(landing_retry_source "$slug" "$branch" "$union_log")"
    [[ -n "$source" ]] || continue

    _landing_stage_attempt "$slug" "$pr_url" "$complexity" "$source" "$default_branch" "retry" "$armed_this_pass"
    if (( _landing_stage_attempt_armed )); then
      armed_this_pass=$(( armed_this_pass + 1 ))
      # shellcheck disable=SC2004  # false positive: see the sibling
      # assignment in run_landing_stage above.
      landing_armed_by_repo[$slug]="$armed_this_pass"
    fi
  done < <(jq -c '.[]' <<<"$candidates" 2>/dev/null || true)
  return 0
}

# landing_open_question_hit SLUG NUMBER
# Requirement 8f (D18, agent-ops#668): does pull request #NUMBER in SLUG
# currently carry $LANDING_OPEN_QUESTION_LABEL? Read fresh from GitHub on
# every call, the same "no private state, no log join" contract every other
# gate in this file already holds — a human can remove the label directly,
# and the next read must see that immediately, the same way a fresh
# `merge_autonomy_effective_level` read sees a kill switch an operator just
# flipped.
#
# Exit 0 ("hit") when the label is present, 1 ("clear") when it is not, and 2
# ("unknown") when the label list itself could not be read. Unlike
# `landing_protected_paths_hit`'s own exit 2 — which routes *to* the more
# cautious outcome because a missed protected path is the failure mode this
# whole gate exists to prevent — an unknown label list here is a plain,
# retryable read failure: the caller refuses this round with the ordinary
# "could not read" wording and tries again next cycle, rather than routing
# into the escalation/adjudication machinery over a question it never
# confirmed exists.
landing_open_question_hit() {
  local slug="$1" number="$2" gh_bin="${LANDING_GH:-gh}" labels
  labels="$("$gh_bin" pr view "$number" -R "$slug" --json labels \
              --jq '.labels[].name' 2>/dev/null)" || return 2
  grep -qxF "$LANDING_OPEN_QUESTION_LABEL" <<<"$labels" && return 0
  return 1
}

# landing_open_question_label_project SLUG NUMBER
# Put $LANDING_OPEN_QUESTION_LABEL on pull request #NUMBER in SLUG iff it is
# not already there, and say whether the resulting label is this
# projection's to remove later. Mirrors `refinement_label_project`'s
# (lib/refinement.sh) read-before-write contract exactly, for the identical
# reason: `gh pr edit --add-label` succeeds as a no-op on a pull request that
# already carries the label, so an unconditional add-and-record would let
# `landing_open_question_label_release` later remove a label a human applied
# for their own reasons before this question was ever raised.
#
# Prints one word:
#   added       LABEL was absent and is now on the pull request — record it,
#               so settling the question takes it off again.
#   present     LABEL was already there. Nothing is touched and nothing must
#               be recorded — most often a later Reviewer round raising a
#               further question while an earlier one still stands.
#   unrecorded  the pull request's labels could not be read, so the add was
#               attempted best-effort but must not be recorded — over-holding
#               a label is cosmetic; removing one that may have pre-existed
#               is the defect this function exists to prevent.
#   failed      the list was readable, LABEL was absent, and the add would
#               not take (a repo where the label was never created is the
#               practical case, ordinarily self-healed by `labels_ensure`'s
#               own periodic sweep, lib/labels.sh) — the caller records the
#               question regardless: losing the label costs a filter, losing
#               the gate would cost the hold.
#
# Exit status is 0 for `added` and `present`, 1 for `unrecorded` and `failed`.
landing_open_question_label_project() {
  local slug="$1" number="$2" gh_bin="${LANDING_GH:-gh}" existing
  if [[ -z "$slug" || -z "$number" ]]; then
    printf 'failed'
    return 1
  fi
  if ! existing="$("$gh_bin" pr view "$number" -R "$slug" --json labels \
                     --jq '.labels[].name' 2>/dev/null)"; then
    "$gh_bin" pr edit "$number" -R "$slug" --add-label "$LANDING_OPEN_QUESTION_LABEL" >/dev/null 2>&1 || true
    printf 'unrecorded'
    return 1
  fi
  if grep -qxF "$LANDING_OPEN_QUESTION_LABEL" <<<"$existing"; then
    printf 'present'
    return 0
  fi
  if "$gh_bin" pr edit "$number" -R "$slug" --add-label "$LANDING_OPEN_QUESTION_LABEL" >/dev/null 2>&1; then
    printf 'added'
    return 0
  fi
  printf 'failed'
  return 1
}

# landing_open_question_label_release SLUG NUMBER
# Take $LANDING_OPEN_QUESTION_LABEL off pull request #NUMBER in SLUG. Callers
# never call this except once an adjudication pass has actually returned
# `settled` (agent-cycle.sh's `run_open_question_adjudication`) — the one
# clearing path design point 3 in agent-ops#668 names besides a human's own
# act, and the reason this needs no read-before-write of its own the way the
# projection above does: a pipeline-projected label is the only one this
# function is ever asked to remove.
landing_open_question_label_release() {
  local slug="$1" number="$2" gh_bin="${LANDING_GH:-gh}"
  [[ -n "$slug" && -n "$number" ]] || return 1
  "$gh_bin" pr edit "$number" -R "$slug" --remove-label "$LANDING_OPEN_QUESTION_LABEL" >/dev/null 2>&1
}

# landing_open_question_latest PR_URL [SRC]
# Every question a Reviewer round has logged against PR_URL via
# `open-question-raised`, deduplicated by its own `question` text — never
# only the most recent round's, so a second round raising a further question
# while an earlier one still stands does not silently drop the first from an
# escalation issue's body or an adjudication pass's own input (agent-ops#668
# design point: "whether more than one open question per pull request is
# permitted" — yes, and every one of them is carried forward). `[]` if none
# is on the log SRC names.
#
# SRC follows `landing_approver_adjudication_history`'s own convention:
# `$log_file` on the round that first raises a question (this process's own
# just-written `open-question-raised` event is already there) or
# `$union_log` when read back later (a peer node's or an earlier cycle's
# round), or stdin if omitted or "-". Malformed lines are skipped, not
# fatal. This is read-only, supplementary content for prose a human or an
# adjudication pass reads — never what the landing gate itself decides on,
# which stays the label alone (requirement 8f's own "no log join" reasoning
# for the gate proper), so a peer node's cycle racing to log its own
# `open-question-raised` event costs this reader nothing but slightly stale
# prose.
landing_open_question_latest() {
  local pr_url="$1" src="${2:--}" out=""
  # shellcheck disable=SC2016  # $pr_url is jq's own --arg variable, not the shell's.
  local jq_prog='
    [ .[] | select(.event == "open-question-raised" and (.pr_url // "") == $u)
      | (.questions // [])[] ]
    | unique_by(.question // "")'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -cs --arg u "$pr_url" "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -cs --arg u "$pr_url" "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}
