#!/usr/bin/env bash
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
# weakened. Nine whole-path prefixes, an explicit anchored `case` in the
# shape `scripts/is-docs-only.sh` uses (allowlist there, denylist here) —
# never an extension rule, and that file's own argument holds here
# unchanged: adding one line to a protected-paths list is cheap, forgetting
# one is not.
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
#
# The last three were left off when this list was first written, raised as
# an explicit question on this file's own pull request rather than decided
# here. That question has been answered: all three are on the list. Each is
# gate-bearing in the same direct sense as the entries above —
# `agent-cycle.sh` is the engine that calls this very arming step,
# `review-cycle.sh` is the review pipeline's entry point, and `config.json`
# carries the `merge_autonomy` level and `merge_autonomy_routine_sources`
# that `landing_eligible` reads — so a pull request editing one of them is
# precisely the self-modifying case risk register item 1 names, and the
# "adding one line is cheap, forgetting one is not" argument above applies
# to them unchanged.
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

# _landing_is_protected PATH
# True iff PATH falls under one of the nine protected prefixes — see the
# header for the list and why each is there. Whole-path prefixes only,
# anchored, never an extension rule.
_landing_is_protected() {
  case "$1" in
    .github/*) return 0 ;;
    deploy/*) return 0 ;;
    prompts/*) return 0 ;;
    lib/*) return 0 ;;
    config.schema.json) return 0 ;;
    config.json) return 0 ;;
    agent-cycle.sh) return 0 ;;
    review-cycle.sh) return 0 ;;
    CODEOWNERS) return 0 ;;
    *) return 1 ;;
  esac
}

# landing_protected_paths_hit SLUG NUMBER
# Print the offending paths, one per line. Exit 0 when at least one changed
# path is protected, 1 when none is, 2 when the answer could not be
# established at all (bad arguments, `gh` erroring, a listing that reached
# LANDING_PR_FILES_LIMIT and so may be hiding more). Reads the changed-file
# list fresh from GitHub — `gh api repos/SLUG/pulls/N/files`, never the
# ephemeral clone, whose branch may have moved since it was checked out —
# and exit 2 is a refusal to arm at every call site, never a pass: an
# unreadable or truncated list must never read as "nothing protected was
# touched".
landing_protected_paths_hit() {
  local slug="$1" number="${2:-}" gh_bin="${LANDING_GH:-gh}"
  [[ -n "$slug" && "$number" =~ ^[0-9]+$ ]] || return 2

  local raw count
  raw="$("$gh_bin" api "repos/$slug/pulls/$number/files" --paginate -F per_page=100 \
    --jq '.[].filename' 2>/dev/null)" || return 2

  if [[ -z "$raw" ]]; then
    count=0
  else
    count="$(wc -l <<<"$raw")"
  fi
  github_pr_list_truncated "$count" "$LANDING_PR_FILES_LIMIT" && return 2

  local hit=0 path
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if _landing_is_protected "$path"; then
      printf '%s\n' "$path"
      hit=1
    fi
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

# landing_eligible CONFIG_JSON SLUG NUMBER COMPLEXITY SOURCE LEVEL
# Print `eligible`, `ineligible:<reason>` or `unknown:<reason>`. LEVEL is
# the caller's own already-resolved `merge_autonomy_effective_level` — this
# function never resolves it itself, so the kill switch and a WI-6 budget
# freeze both bind exactly once, at the caller, rather than being read
# twice and risking the two reads disagreeing.
#
# Eligible iff **all** of:
#   - LEVEL is `agent-merges-routine` or `agent-merges-all`;
#   - COMPLEXITY is `low` or `medium` — `high` is ineligible regardless of
#     source or path, the first half of risk register item 1's belt and
#     braces (requirement 26a already forces `high` onto anything touching
#     concurrency, security, CI/workflow machinery or shared library code);
#   - SOURCE is a member of `_landing_routine_sources`'s list for SLUG — an
#     empty or unrecognised SOURCE is ineligible, never eligible by
#     omission;
#   - `landing_protected_paths_hit` says no — below `agent-merges-all`. At
#     `agent-merges-all` a hit is instead reported `eligible` and deferred
#     to `landing_protected_path_controls_ok` (D18 WI-12), which needs
#     facts this function is never handed; see the hit branch's own comment
#     below.
#
# `unknown` is returned only for `landing_protected_paths_hit`'s own exit 2
# (the changed-file list could not be read or was truncated) — every other
# refusal above is a deterministic `ineligible`, since COMPLEXITY, SOURCE
# and LEVEL are all already in the caller's hand, nothing further to ask
# GitHub. Both words carry the same instruction to every call site: **never
# a pass** — `unknown` is treated as `ineligible` everywhere this is read,
# the distinction exists only so a log can say whether the diff was
# genuinely disqualified or merely unreadable.
landing_eligible() {
  local config_json="$1" slug="$2" number="$3" complexity="$4" source="$5" level="$6"

  case "$level" in
    agent-merges-routine|agent-merges-all) ;;
    *)
      printf 'ineligible:merge_autonomy effective level is %s, not agent-merges-routine or agent-merges-all' "${level:-empty}"
      return 0
      ;;
  esac

  case "$complexity" in
    low|medium) ;;
    *)
      printf 'ineligible:complexity is %s, not low or medium' "${complexity:-empty}"
      return 0
      ;;
  esac

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

  local hit_paths hit_rc
  hit_paths="$(landing_protected_paths_hit "$slug" "$number")"; hit_rc=$?
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
  landing_protected_paths_hit "$slug" "$number" >/dev/null 2>&1 || hit_rc=$?
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
    # `null` as well as empty: `--jq` prints a JSON null as the four-character
    # word `null`, so a mutation that returned no `mergeQueueEntry` at all —
    # `enqueuePullRequest` reports one as nullable, and GitHub does not
    # always accompany that with a GraphQL error `gh` would exit non-zero on
    # — would otherwise pass the `-n` test and be logged `landing-armed`
    # naming a queue entry that does not exist. Exactly the "a partial write
    # this function cannot vouch for" case the header promises to refuse.
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

# landing_approver_adjudication_history PR_URL [LOG_FILE]
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
# LOG_FILE follows `landing_retry_tier`'s own convention: `$log_file` on the
# round that first approves a pull request (this process's own just-written
# `approver-verdict` event is already there — `log_event` appends
# synchronously, before `_landing_stage_attempt` ever runs) or `$union_log`
# on a re-arm (the approving round belongs to an earlier cycle, possibly a
# peer node's — the same reasoning `landing_retry_tier` already applies to
# TIER alone), or stdin if omitted or "-", matching every reader in
# lib/cycle-state.sh. Malformed lines are skipped, not fatal. Always prints a
# JSON array, `[]` rather than empty output, so a caller can `--argjson` it
# straight into the audit record with no fallback of its own.
landing_approver_adjudication_history() {
  local pr_url="$1" src="${2:--}" out=""
  # shellcheck disable=SC2016  # $pr_url is jq's own --arg variable, not the shell's.
  local jq_prog='
    [ .[] | select(.event == "approver-verdict" and (.pr_url // "") == $u)
      | {ts: (.ts // ""), tier: (.tier // null), model: (.model // null),
         verdict: (.verdict // null), adjudication: (.adjudication // false),
         refuse_streak: (.refuse_streak // null), posted: (.posted // null)} ]
    | sort_by(.ts)'
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
