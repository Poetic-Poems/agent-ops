#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/approver.sh — the Approver stage's own decision primitives (D18 WI-5,
# agent-ops#408; design: docs/reviews/2026-08-14-autonomy-investigation.md
# §5.2/§5.3).
#
# `merge_autonomy` above `human` (lib/merge-autonomy.sh) needs a non-author
# identity to hold review rights, since GitHub refuses self-approval and this
# pipeline authors as its own configured owner — that identity is the
# "Pullwright Approver" GitHub App, whose installation-token minting
# lib/approver-token.sh already provides (D18 WI-4). This file is what turns
# a minted token into an actual judgement: which tier a pull request's
# complexity grade routes to, whether a run of consecutive refusals has
# reached the point a Standard/High engagement must yield to a critical-tier
# adjudication instead, and the two GitHub writes the Script performs on the
# Approver's own verdict — never the model's.
#
# Four tiers, mirroring the owner's own delegation ladder (§5.2):
#   trivial       complexity:low — deterministic, no model call at all. The
#                 grading rubric (docs/IMPLEMENTATION-PIPELINE-SPEC.md
#                 requirement 26a) already forces anything touching
#                 concurrency, security, CI/workflow machinery or shared
#                 library code to grade `high`, never `low` — so the
#                 protected-paths classifier `lib/landing.sh` adds (WI-7) is
#                 a second fence around ground the complexity label already
#                 fences off, not this tier's only guard.
#   standard      complexity:medium — one engagement on `approver_model_default`.
#   high          complexity:high — one engagement on `approver_model_complex`
#                 (falling back to the default tier when unset, the same
#                 escalation-off convention `reviewer_model_complex` uses).
#   adjudication  triggered by refuse-streak, not by complexity — see
#                 `approver_refuse_streak` below — always on
#                 `approver_model_critical` (falling back down the same
#                 chain), regardless of what tier the ordinary grade would
#                 have chosen.
#
# Refuse-wins, structurally: a refusal is posted as a real `REQUEST_CHANGES`
# review from the Approver identity (`approver_post_review`), so GitHub
# itself holds the pull request at `CHANGES_REQUESTED` and the existing
# `review-feedback` source picks it up next cycle exactly as it already picks
# up a human's own `CHANGES_REQUESTED` — no new work source, no new gate. An
# approval is the ordinary `APPROVE` review on the same pull request; this
# file itself never merges anything, at any level (D18's cardinal rule: the
# model never holds merge rights, and neither does the code in this file) —
# landing, where `agent-merges-routine`/`agent-merges-all` actually differ
# from `agent-approves`, is `lib/landing.sh`'s own separate arming step (WI-7,
# requirement 8d), called only after this file's `run_approver_stage` has
# already returned.
#
# The refuse streak is derived from the reviews list itself, read fresh at
# the moment of the decision, the same "ask GitHub, don't keep a private
# count that can drift" discipline `lib/handoff.sh` and `lib/review-gate.sh`
# already apply, and the same move agent-ops#449 made for
# `could_not_request` — a second, independent counter this file might keep
# instead would need its own reconciliation the moment a cycle dies mid-write
# or two nodes touch the same pull request, and the reviews list already
# cannot disagree with itself.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (agent-cycle.sh runs under `set -euo pipefail`;
# a test, `set -uo pipefail`) owns those.
#
# Environment:
#   APPROVER_GH  override `gh` (tests stub it).

# approver_tier_for COMPLEXITY
# Print `trivial`, `standard` or `high` for `low`, `medium` or `high`. Any
# other value — including empty — reads as `standard`, the same
# fail-toward-the-middle-tier caution the resolved `complexity` this reads
# already earned one level up (`reviewer_complexity`'s own raise-never-lower
# resolution): this function trusts its caller handed it an already-resolved
# grade, and only degrades gracefully if it did not.
approver_tier_for() {
  case "${1:-}" in
    low) printf 'trivial' ;;
    high) printf 'high' ;;
    *) printf 'standard' ;;
  esac
}

# approver_model_for_tier TIER MODEL_DEFAULT MODEL_COMPLEX
# Print the model an ordinary (non-adjudication) engagement launches on:
# MODEL_COMPLEX for `high`, MODEL_DEFAULT otherwise. `trivial` never reaches
# this — the caller skips the model call entirely — and every route to the
# Critical tier launches on MODEL_CRITICAL directly instead: an
# adjudication (requirement 8c), and a protected-path hit forcing Critical
# ahead of the complexity grade (D18 WI-12, requirement 8b). So only the
# two ordinary tiers are resolved here.
approver_model_for_tier() {
  local tier="${1:-}" default_m="${2:-}" complex_m="${3:-}"
  if [[ "$tier" == "high" ]]; then
    printf '%s' "$complex_m"
  else
    printf '%s' "$default_m"
  fi
}

# _approver_err_log
# Where approver_post_review's own GitHub failures land — cycle_dir when the
# caller has one (every real caller does by the time this runs), /tmp as a
# last resort for a standalone call or test with none, the same fallback
# lib/tech-debt-file.sh's own `_techdebt_err_log` already uses for the
# identical reason.
_approver_err_log() {
  printf '%s' "${cycle_dir:-/tmp}/approver-post.err"
}

# _approver_pr_parts PR_URL
# Print `owner/repo<TAB>number`, or return non-zero printing nothing. The
# same shape lib/handoff.sh's and lib/review-gate.sh's own private helpers
# compute, duplicated rather than depended on so this file sources and tests
# standalone, matching their own stated reason for the same duplication.
_approver_pr_parts() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  printf '%s/%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# approver_refuse_streak PR_URL LOGIN
# Print how many `CHANGES_REQUESTED` reviews LOGIN has most recently
# submitted on PR_URL, counting back from the newest and stopping at the
# first `APPROVED` review from the same login (or the list's start) — the
# number of refuse cycles in a row, right now. Prints `0` when LOGIN is empty
# or has never reviewed this pull request, or when its most recent review
# approved. `COMMENTED`/`DISMISSED` reviews from LOGIN neither extend nor
# reset the streak — they carry no standing verdict.
#
# Returns non-zero, printing nothing, when the reviews list could not be read
# at all — the caller must not read that as `0`, the same "could not ask"
# convention every other reader in this codebase's review-state readers
# (lib/handoff.sh's `_handoff_*` family) follows.
approver_refuse_streak() {
  local url="${1:-}" login="${2:-}" gh_bin="${APPROVER_GH:-gh}"
  local parts slug number lines

  if [[ -z "$login" ]]; then
    printf '0'
    return 0
  fi
  if [[ -z "$url" ]] || ! parts="$(_approver_pr_parts "$url")"; then
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  # One JSON object per line, not one array per page — `--paginate`
  # concatenates a separate document per page, so an aggregate computed
  # inside `--jq` would be computed per page and silently disagree with
  # itself past thirty reviews (the same trap `_handoff_latest_reviews`'s own
  # header documents). The aggregation happens below, over every page at once.
  #
  # The login filter runs in the second jq call, not here: `gh api --jq`
  # takes one query string and nothing else — it has no `--arg` of its own to
  # parameterise that query with, so a login can only be woven in by string
  # interpolation (fragile the moment a login carries a character jq's
  # string-literal syntax cares about) or, as here, left for a real `jq`
  # invocation downstream that has genuine `--arg` support.
  lines="$("$gh_bin" api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null)
                      | {login: .user.login, at: .submitted_at, state: .state}' \
            2>/dev/null)" || return 1

  jq -s -r --arg l "$login" '
    map(select(.login == $l))
    | sort_by(.at) | reverse
    | reduce .[] as $r ({stopped: false, count: 0};
        if .stopped then .
        elif $r.state == "CHANGES_REQUESTED" then {stopped: false, count: (.count + 1)}
        elif $r.state == "APPROVED" then {stopped: true, count: .count}
        else . end)
    | .count
  ' <<<"$lines" 2>/dev/null || return 1
}

# approver_post_review PR_URL EVENT BODY TOKEN
# POST a review to PR_URL from the Approver identity, authenticated with
# TOKEN (an installation token from `approver_token_get`, never the owner's
# own PAT — the whole reason a separate identity exists). EVENT is `APPROVE`
# or `REQUEST_CHANGES`. Prints nothing; returns 0 only on a real 2xx from
# GitHub, non-zero otherwise — the caller must not read a failure as a posted
# review.
#
# A refusal's own status and body land in `_approver_err_log`'s file, never
# discarded — the same "keep what GitHub actually said" discipline
# lib/tech-debt-file.sh's own error log already applies. Before agent-ops#945
# this call's stderr went to `/dev/null`, and the only reason that incident
# was diagnosable at all was that `techdebt_file_debt`, spending the same
# token seconds earlier, happened to keep its own error file — this call had
# none.
#
# `GH_TOKEN` is set only for this one invocation (a leading assignment on the
# command, not `export`), so the override cannot leak into any later `gh`
# call this process makes under the owner's own login.
approver_post_review() {
  local url="${1:-}" event="${2:-}" body="${3:-}" token="${4:-}" gh_bin="${APPROVER_GH:-gh}"
  local parts slug number errlog

  [[ -n "$token" && -n "$event" ]] || return 1
  if [[ -z "$url" ]] || ! parts="$(_approver_pr_parts "$url")"; then
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  errlog="$(_approver_err_log)"
  GH_TOKEN="$token" "$gh_bin" api -X POST "repos/$slug/pulls/$number/reviews" \
    -f "event=$event" -f "body=$body" >/dev/null 2>>"$errlog"
}

# approver_prior_refusal_bodies PR_URL LOGIN
# Print LOGIN's own `REQUEST_CHANGES` review bodies on PR_URL, oldest first,
# each preceded by its submission timestamp — what an adjudication engagement
# reads to judge whether a refusal's own reasons were ever actually answered.
#
# Never fails: prints nothing when LOGIN has none, or the list could not be
# read. Adjudication only ever runs once `approver_refuse_streak` has already
# established the streak that triggers it, so an unreadable list here costs
# missing context in the prompt, not a wrong decision about whether to run.
approver_prior_refusal_bodies() {
  local url="${1:-}" login="${2:-}" gh_bin="${APPROVER_GH:-gh}" parts slug number lines
  [[ -n "$url" && -n "$login" ]] || return 0
  parts="$(_approver_pr_parts "$url")" || return 0
  IFS=$'\t' read -r slug number <<<"$parts"
  # Same split as approver_refuse_streak: `gh api --jq` has no `--arg` of its
  # own, so the login filter runs in the second, genuine `jq` call below.
  lines="$("$gh_bin" api "repos/$slug/pulls/$number/reviews" --paginate \
            --jq '.[] | select(.submitted_at != null and .state == "CHANGES_REQUESTED")
                      | {login: .user.login, at: .submitted_at, body: (.body // "")}' \
            2>/dev/null)" || return 0
  jq -s -r --arg l "$login" '
    map(select(.login == $l))
    | sort_by(.at)[]
    | "### " + .at + "\n\n" + .body
  ' <<<"$lines" 2>/dev/null || return 0
}

# approver_review_stale STATE COMMIT HEAD_SHA
# Exit 0 iff STATE is a standing `CHANGES_REQUESTED` and COMMIT — the
# `commit_id` that review was submitted against — no longer matches HEAD_SHA,
# the pull request's current head: the deterministic re-review trigger
# agent-ops#682 defines, read from GitHub's own review record rather than
# depended on GitHub's `requested_reviewers` re-request, which silently
# no-ops for a Bot account (the Approver's own identity) and so can never
# itself signal a stale review. Exits 1 on any other STATE, or when COMMIT or
# HEAD_SHA is empty — an incomplete read must never be misread as "stale".
approver_review_stale() {
  local state="${1:-}" commit="${2:-}" head="${3:-}"
  [[ "$state" == "CHANGES_REQUESTED" && -n "$commit" && -n "$head" && "$commit" != "$head" ]]
}

# approver_newest_commit_authored_at PR_URL
# Print the ISO-8601 `authoredDate` of PR_URL's most recently authored
# commit — the newest value in `git log`'s own `%aI` sense. A rebase does not
# move it: `git rebase` (absent an explicit `--committer-date-is-author-date`
# or similar) reuses each replayed commit's original author date and only
# stamps a fresh committer date, which is what GraphQL's `committedDate` and
# the REST `commit.committer.date` read instead — the same forgeable-by-
# force-push signal gather-review-feedback.sh's own header already rejected
# `committedDate` for. Comparing this against a stale review's own
# `submitted_at` is agent-ops#682's answer to "ignore a rebase-only push":
# a rebase alone can never produce a commit whose authored date is newer than
# a review that already stood over every commit that rebase replayed.
#
# One `gh pr view` call, not `--paginate` over the commits REST endpoint: `gh`
# resolves `--json commits` through GraphQL's `commits(last: 100)`, so this
# costs the same one read regardless of how many commits the pull request
# carries, at the same per-call GraphQL price gather-review-feedback.sh's own
# header measured for `headRefOid` — acceptable here because, unlike that
# per-cycle listing, this is only ever asked for a pull request the caller has
# already confirmed carries a stale Approver review, never for every open one.
#
# Returns non-zero, printing nothing, when the commit list could not be read
# or came back empty — the caller must not read that as "no progress", only
# as "could not tell".
approver_newest_commit_authored_at() {
  local url="${1:-}" gh_bin="${APPROVER_GH:-gh}" parts slug number newest
  [[ -n "$url" ]] || return 1
  parts="$(_approver_pr_parts "$url")" || return 1
  IFS=$'\t' read -r slug number <<<"$parts"
  newest="$("$gh_bin" pr view "$number" -R "$slug" --json commits \
              --jq '[.commits[].authoredDate] | max // empty' 2>/dev/null)" || return 1
  [[ -n "$newest" ]] || return 1
  printf '%s' "$newest"
}

# approver_dismiss_review PR_URL REVIEW_ID BODY TOKEN
# Dismiss REVIEW_ID on PR_URL — self-authored, needs no new permission
# (agent-ops#682) — via `PUT .../reviews/{id}/dismissals`, authenticated with
# TOKEN (an installation token from `approver_token_get`, the same identity
# `approver_post_review` posts under). Prints nothing; returns 0 only on a
# real 2xx from GitHub, non-zero otherwise — same "the caller must not read a
# failure as a dismissal" contract `approver_post_review`'s own header states.
#
# `GH_TOKEN` is set only for this one invocation, the same leading-assignment
# scoping `approver_post_review` already uses, so the override cannot leak
# into any later `gh` call this process makes under the owner's own login.
approver_dismiss_review() {
  local url="${1:-}" review_id="${2:-}" body="${3:-}" token="${4:-}" gh_bin="${APPROVER_GH:-gh}"
  local parts slug number

  [[ -n "$token" && "$review_id" =~ ^[0-9]+$ ]] || return 1
  if [[ -z "$url" ]] || ! parts="$(_approver_pr_parts "$url")"; then
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  GH_TOKEN="$token" "$gh_bin" api -X PUT "repos/$slug/pulls/$number/reviews/$review_id/dismissals" \
    -f "message=$body" >/dev/null 2>&1
}

# The following four functions moved from agent-cycle.sh (#771): the
# per-round Approver stage itself (`run_approver_stage`), its posting and
# escalation helpers, and the complexity-to-tier mapping. Reads and writes
# the cycle's own globals (`cycle_dir`, `node_name`, `approver_stage_*`, …)
# exactly as they did inline.
# approver_post_or_warn PR_URL EVENT BODY TOKEN
# `approver_post_review` (lib/approver.sh) returns 0 only on a real 2xx from
# GitHub, and its own header is explicit that a caller must not read a failure
# as a posted review. This is that reading, in one place: a review GitHub
# refused — an expired token, an App whose installation lost review rights, an
# API outage — leaves the pull request exactly as it was, which is the
# harmless half of requirement 8b's "a missing review, never a stranded PR".
# The harmful half would be leaving no trace: every other way this stage can
# fail to post logs a `warning`, so the one failure that happens at the moment
# of the write must too, or an operator reading the log sees an
# `approver-verdict` and no review on the pull request and has nothing to
# connect them. Always returns 0 — the caller's own path is unchanged either
# way.
#
# Reports the write's own success through `approver_last_post_ok` (`1`/`0`),
# reset on every call — the one fact `run_approver_stage` needs to decide
# whether this round's verdict actually reached GitHub before logging it
# (requirement 8c's `posted` field, agent-ops#573): a verdict a human never
# saw a review for cannot have diverged from, or agreed with, anything.
#
# agent-ops#1082: a failed write used to log the same generic "GitHub refused
# the write" whether GitHub rejected the token outright or merely refused
# because the owner's shared REST budget was spent — indistinguishable to an
# operator, and the second case silently dropped a verdict a short wait could
# have delivered. `approver_post_review`'s own `gh` call already goes through
# the rate-limit-aware wrapper (lib/github-limit.sh) when it is sourced ahead
# of this file (every real caller's own order, per that file's header) and
# `APPROVER_GH` is left at its default — but that wrapper commits to exactly
# one wait-and-retry per call, and gives up silently if the reset it saw then
# was not worth waiting for. This is the caller's own second look, taken only
# once the wrapper has already given up: it classifies the diagnostic
# `approver_post_review` just left in `_approver_err_log` via
# `github_limit_kind` (reused, not reclassified) and, only when the cause was
# rate-limiting, tries the same wait/backoff (`github_limit_wait_plan`) once
# more itself before conceding the verdict is dropped.
approver_post_or_warn() {
  local pr_url="$1" event="$2" body="$3" token="$4"
  local errlog before diag kind wait now reset_epoch retried=0
  approver_last_post_ok=1
  errlog="$(_approver_err_log)"
  before=0
  [[ -f "$errlog" ]] && before="$(wc -c <"$errlog" 2>/dev/null || printf 0)"

  if approver_post_review "$pr_url" "$event" "$body" "$token"; then
    return 0
  fi

  diag=""
  [[ -f "$errlog" ]] && diag="$(tail -c "+$(( before + 1 ))" "$errlog" 2>/dev/null || true)"
  kind="none"
  declare -F github_limit_kind >/dev/null 2>&1 && kind="$(github_limit_kind "$diag")"

  if [[ "$kind" != "none" ]] && declare -F github_limit_wait_plan >/dev/null 2>&1; then
    now="$(date +%s)"
    reset_epoch=0
    if [[ "$kind" == "primary" ]] && declare -F github_limit_primary_reset_epoch >/dev/null 2>&1; then
      reset_epoch="$(github_limit_primary_reset_epoch "$now")"
    fi
    wait="$(github_limit_wait_plan "$kind" "$reset_epoch" "$now" "${GITHUB_LIMIT_WAITED_SECONDS:-0}")"
    if [[ -n "$wait" ]]; then
      retried=1
      sleep "$wait"
      GITHUB_LIMIT_WAITED_SECONDS=$(( ${GITHUB_LIMIT_WAITED_SECONDS:-0} + wait ))
      if approver_post_review "$pr_url" "$event" "$body" "$token"; then
        return 0
      fi
    fi
  fi

  approver_last_post_ok=0
  if [[ "$kind" == "none" ]]; then
    log_event "warning" "$(jq -nc --arg u "$pr_url" --arg e "$event" \
      --arg d "the Approver's $event review of $pr_url could not be posted — GitHub refused the write (see approver-post.err), so the pull request carries no App review this round" \
      '{detail: $d, pr_url: $u, event: $e}')"
  else
    local outcome="not worth waiting for — see approver-post.err" retried_bool=false
    if (( retried )); then
      outcome="retried, but it still refused the write — see approver-post.err"
      retried_bool=true
    fi
    log_event "warning" "$(jq -nc --arg u "$pr_url" --arg e "$event" --argjson r "$retried_bool" \
      --arg d "the Approver's $event review of $pr_url could not be posted — GitHub's $kind rate limit refused the write ($outcome), so the pull request carries no App review this round" \
      '{detail: $d, pr_url: $u, event: $e, rate_limited: true, retried: $r}')"
  fi
  return 0
}

# approver_escalate PR_URL REASONS_JSON
# File (or find already-filed, via create_escalation_issue's own dedup) the
# escalation issue for a pull request an Approver adjudication engagement
# could not settle — land it, or refuse it and let a human decide. Unlike
# crash_loop_escalate and the Enabler's own escalations, there is no model
# drafting this one: `reasons_json` already carries the adjudication's
# structured findings (or the Script's own "could not settle" fallback), so
# the Script composes the issue body directly.
approver_escalate() {
  local pr_url="$1" reasons_json="$2"
  local number item_ref body_file reasons_text created
  number="${pr_url##*/}"
  item_ref="pr-${number}-approver-adjudication"
  body_file="$cycle_dir/approver-escalation-${number}.md"
  reasons_text="$(jq -r 'if length == 0 then "(no reasons given)" else map("- " + .) | join("\n") end' <<<"$reasons_json")"
  {
    printf '## What the autonomous pipeline needs from you\n\n'
    printf 'Review %s and either request further changes yourself or approve and merge it — the Approver could not settle its own disagreement about this pull request.\n\n' "$pr_url"
    printf '## Why the pipeline is blocked\n\n'
    printf 'The Approver App refused %s twice in a row. A critical-tier adjudication engagement then read both the pull request and the prior refusals and could not resolve the disagreement on its own.\n\n' "$pr_url"
    printf '## What has already been tried and established\n\n'
    printf '%s\n\n' "$reasons_text"
    cat <<APPROVER_ESC_BODY
## When you're done: close this issue

Close this issue once you have reviewed the pull request yourself. The
pipeline takes no further automatic landing action on it — your own GitHub
review and merge are the next step.

---
Item: \`$item_ref\` · pull request $pr_url
Raised by the Approver stage (D18 WI-5) · cycle \`$cycle_id\` · node \`$node_name\`
APPROVER_ESC_BODY
  } > "$body_file"
  if created="$(create_escalation_issue "$selected_repo" "$item_ref" \
        "$enabler_escalation_label" \
        "Approver adjudication could not settle $pr_url" \
        "$body_file")" && [[ -n "$created" ]]; then
    log_event "approver-escalated" "$(jq -nc --arg u "$pr_url" \
      --arg n "${created%%$'\t'*}" --arg iu "${created#*$'\t'}" \
      '{pr_url: $u, issue_number: ($n | tonumber), issue_url: $iu}')"
  else
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "Approver adjudication could not settle $pr_url, and the escalation issue could not be filed — will retry next cycle" \
      '{detail: $d, pr_url: $u}')"
  fi
}

# approver_stage_complexity PR_URL PRE_REVIEW_COMPLEXITY TRIVIAL
# Requirement 8b: the Approver's tier is resolved from the complexity as it
# stands *after* the Reviewer stage has run, not the value requirement 8a
# resolved before it. The Reviewer may correct a `complexity:*` label it
# finds plainly wrong for the diff, in either direction (prompts/reviewer.md
# step 4, requirement 30) — a correction that lands on the pull request after
# PRE_REVIEW_COMPLEXITY (the caller's `rev_complexity`) was already computed
# and the Reviewer itself already launched at that grade. This re-reads the
# label now and folds it through the same raise-never-lower comparison
# `reviewer_complexity` (lib/cycle-state.sh) already applies at requirement
# 8a, with PRE_REVIEW_COMPLEXITY standing in for the Implementer's own grade:
# the Approver's tier can rise on a mid-cycle correction, but never settles
# below what the round was already reviewed at. Best-effort, the same as
# requirement 8a's own read: an unreadable label contributes nothing and the
# result falls back to PRE_REVIEW_COMPLEXITY unchanged.
approver_stage_complexity() {
  local pr_url="$1" pre="$2" trivial="${3:-0}"
  local grades=()
  if [[ -n "$pr_url" ]]; then
    mapfile -t grades < <(gh pr view "$pr_url" --json labels \
      --jq '.labels[].name | select(startswith("complexity:")) | sub("^complexity:"; "")' 2>/dev/null || true)
  fi
  reviewer_complexity "$pre" "$trivial" ${grades[@]+"${grades[@]}"}
}

# run_approver_stage PR_URL COMPLEXITY
# D18 WI-5 (requirement 8b): the tiered Approver, engaged once per
# Reviewer-ready round, for every repository whose merge_autonomy is
# currently above `human` (lib/merge-autonomy.sh's own kill-switch-aware
# resolution — the fleet-wide kill switch reads as `human` here exactly as
# everywhere else). Judges the pull request `confirm_pr_ready` has already
# flipped out of draft, and posts a real GitHub review — `APPROVE` or
# `REQUEST_CHANGES` — from the Pullwright Approver's own App identity, never
# from a model-issued `gh` command; the model only ever returns a verdict
# (prompts/approver.md).
#
# Always returns 0, and never touches the PR claim or the draft flag: a
# stage that cannot run, or a GitHub write that fails, costs a missing App
# review, never a blocked pull request — by construction, since every path
# through this function ends in either a best-effort review post or a
# best-effort escalation, and the caller's own `pr-ready` log and
# `release_pr_claim` follow unconditionally regardless of what happened here.
#
# Reports its own outcome through three globals, reset here on every call
# rather than left to whatever a previous pull request's round left behind
# — `approver_stage_verdict` (this round's `verdict`, or empty when the
# stage did not reach one), `approver_stage_adjudicating` (`1` iff the
# refuse streak, not the complexity grade, chose the tier), and
# `approver_stage_tier` (D18 WI-12, agent-ops#415: this round's own tier,
# `trivial`/`standard`/`high`/`critical` — `critical` whenever a protected
# path forced it, whatever the complexity grade said). `run_landing_stage`
# (D18 WI-7, requirement 8d), called immediately after this function
# returns, is the one reader of the first two: it arms nothing at all unless
# this round's own engagement reached an explicit, non-adjudicating
# `approve` — an adjudication's own `land` does not count, because a
# disagreement settled this round is not the same fact as an engagement
# that agreed the first time. `_landing_stage_attempt`'s own protected-path
# gate (D18 WI-12) is the reader of the third, on the original arming round
# only — a re-arm reads `landing_retry_tier` from the fleet log instead,
# since that round's own `approver_stage_tier` belongs to a process this one
# never was. A return value rather than a global would say the same thing,
# but every existing caller of this function already reads nothing from it
# (`run_approver_stage "$impl_pr_url" "$approver_complexity"`, no
# assignment) and a second, unrelated caller could plausibly want the
# verdict without wanting to restructure that call — the same reasoning
# `stage_kill_reason` (set by `run_claude_stage`, read by its own callers)
# already applies to a stage outcome this file needs to carry past its own
# return.
run_approver_stage() {
  local pr_url="$1" complexity="$2"
  local level login streak tier model="" mode="" adjudicating=0 kill_json
  local prompt out rc status_json verdict="" reasons_json="[]"
  approver_stage_verdict=""
  approver_stage_adjudicating=0
  approver_stage_tier=""
  local token review_body prior_section adj_bool
  local number="" protected_rc=0 protected_hit=0 critical_reason=""
  local posted_review="" posted_bool="false"
  local ap_file_debt ap_fd_title ap_fd_body ap_fd_pr_label ap_fd_result ap_fd_id ap_fd_pr_url \
    ap_fd_default_fix ap_fd_owner_decision
  local ap_file_issue ap_fi_title ap_fi_body ap_fi_body_file ap_fi_result ap_fi_number ap_fi_url \
    ap_fi_default_fix ap_fi_owner_decision
  approver_last_post_ok=""

  # `fresh` (issue #513, PR #506 review follow-up): this stage posts a real
  # App review under the level it reads, so an operator's mid-cycle kill must
  # stop it here, not wait for the next cycle's process — see
  # merge_autonomy_effective_level's own comment on FRESH.
  #
  # `retry` (agent-ops#1081): `merge_autonomy_kill_state` fails closed to
  # `human` on any transport failure reading the kill switch with no cached
  # copy (TD-PPagop-26081507) — a lone rate-limited refusal is the common
  # cause, and before this fix that silently stranded the pull request with
  # no App review and no log trace, breaking requirement 8b's own contract
  # that every other way this stage cannot run logs a `warning`. Reading the
  # kill switch itself, ahead of (and instead of asking
  # merge_autonomy_effective_level to ask on its behalf) is deliberate: a
  # fail-closed `human` is entirely a property of the kill switch (the
  # merge-budget freeze can only ever cap *down* to `agent-approves`, never
  # produce `human`), so this one read already carries everything needed to
  # tell the fail-closed case apart from a genuinely configured or manually
  # killed `human` — via `.record.kind` on the very document this call
  # returns, never a global a `$(...)` command substitution (needed here to
  # capture that document at all) would silently drop.
  kill_json="$(merge_autonomy_kill_state "$state_repo" "$state_dir" fresh retry)"
  if [[ "$(jq -r '.state' <<<"$kill_json" 2>/dev/null)" != "enabled" ]]; then
    if [[ "$(jq -r '.record.kind // ""' <<<"$kill_json" 2>/dev/null)" == "fail-closed" ]]; then
      local kill_errf kill_cause kill_detail kill_retried_bool
      kill_errf="$(fleet_cache_file "$state_dir" "$MERGE_AUTONOMY_KILL_FLAG").err"
      kill_cause="$(cat "$kill_errf" 2>/dev/null || true)"
      kill_retried_bool="$(jq -r 'if (.retried // false) == true then "true" else "false" end' <<<"$kill_json" 2>/dev/null)"
      if [[ "$kill_retried_bool" == "true" ]]; then
        kill_detail="could not read the $MERGE_AUTONOMY_KILL_FLAG flag for $selected_repo, even after one retry — failing closed to human this round, so no App review was posted on $pr_url ($kill_cause)"
      else
        kill_detail="could not read the $MERGE_AUTONOMY_KILL_FLAG flag for $selected_repo — failing closed to human this round, so no App review was posted on $pr_url ($kill_cause)"
      fi
      log_event "warning" "$(jq -nc --arg u "$pr_url" --arg f "$MERGE_AUTONOMY_KILL_FLAG" \
        --arg c "$kill_cause" --argjson r "$kill_retried_bool" --arg d "$kill_detail" \
        '{detail: $d, pr_url: $u, flag: $f, cause: $c, fail_closed: true, retried: $r}')"
    fi
    return 0
  fi
  level="$(merge_autonomy_effective_level "$DEFAULTED_CONFIG" "$selected_repo" "$state_repo" "$state_dir" fresh)"
  [[ "$level" != "human" ]] || return 0

  if [[ -z "$approver_model_default" ]]; then
    log_event "warning" "$(jq -nc --arg u "$pr_url" --arg l "$level" \
      --arg d "merge_autonomy is \"$level\" for $selected_repo but approver_model_default is empty — the Approver stage is disabled, so no App review was posted on $pr_url" \
      '{detail: $d, pr_url: $u}')"
    return 0
  fi
  if ! approver_token_credential_present "$selected_repo"; then
    log_event "warning" "$(jq -nc --arg u "$pr_url" --arg l "$level" \
      --arg d "merge_autonomy is \"$level\" for $selected_repo but the Approver's runtime credential is not present on this node — no App review was posted on $pr_url" \
      '{detail: $d, pr_url: $u}')"
    return 0
  fi
  if ! login="$(approver_token_identity_login "")" || [[ -z "$login" ]]; then
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "could not read the Approver App's own login — no App review was posted on $pr_url" \
      '{detail: $d, pr_url: $u}')"
    return 0
  fi
  if ! streak="$(approver_refuse_streak "$pr_url" "$login")" || [[ ! "$streak" =~ ^[0-9]+$ ]]; then
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "could not read $pr_url's own review history to count a refuse streak — no App review was posted this round" \
      '{detail: $d, pr_url: $u}')"
    return 0
  fi
  if ! token="$(approver_token_get "$selected_repo")"; then
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "could not mint the Approver's installation token — no App review was posted on $pr_url" \
      '{detail: $d, pr_url: $u}')"
    return 0
  fi

  tier="$(approver_tier_for "$complexity")"

  # D18 WI-12 (Stage 4, agent-ops#415, docs/reviews/2026-08-14-autonomy-
  # investigation.md §7 risk 1): a pull request touching a protected path
  # routes to the critical tier regardless of its complexity grade — the
  # deadliest class this design names is a self-modifying change riding a
  # cheap tier through the gate it just weakened. `landing_protected_paths_hit`
  # is the one classifier this reads (lib/landing.sh); nothing here keeps a
  # second copy of its list. This read only ever runs once the stage has
  # already committed to engaging (every check above has passed), so it
  # never costs a `gh` call at `merge_autonomy: human`, where the stage
  # already returned. Its own exit 2 (the changed-file list unreadable or
  # truncated, or a protected-paths list it cannot evaluate against a path
  # at all — TD-PPagop-26082320) routes *to* the critical tier, not away
  # from it — the opposite fail-closed polarity from `landing_eligible`'s
  # own exit-2 handling, since here fail-closed means the more expensive
  # tier, never the cheaper one.
  if [[ "$pr_url" =~ /pull/([0-9]+)$ ]]; then
    number="${BASH_REMATCH[1]}"
    landing_protected_paths_hit "$DEFAULTED_CONFIG" "$selected_repo" "$number" >/dev/null 2>&1 || protected_rc=$?
  else
    protected_rc=2
  fi
  if (( protected_rc == 0 || protected_rc == 2 )); then
    protected_hit=1
    tier="critical"
  fi

  if (( protected_hit )); then
    critical_reason="protected-path"
  elif (( streak >= 2 )); then
    critical_reason="refuse-streak"
  fi

  if (( streak >= 2 )); then
    adjudicating=1
    mode="adjudication"
    model="$approver_model_critical"
  elif [[ "$tier" == "trivial" ]]; then
    # Deterministic: complexity:low already means "docs, comments, or
    # register entries only; no behaviour change" (requirement 26a) — no
    # model call, zero tokens, per the design's own framing of this tier
    # (docs/reviews/2026-08-14-autonomy-investigation.md §5.2). A protected
    # path already forced tier to `critical` above, so this branch is only
    # ever reached for a genuinely untouched-protected-path complexity:low
    # pull request.
    verdict="approve"
    reasons_json='["complexity:low — deterministic approval, no model engagement (D18 §5.2)"]'
  elif [[ "$tier" == "critical" ]]; then
    mode="tier"
    model="$approver_model_critical"
  else
    mode="tier"
    model="$(approver_model_for_tier "$tier" "$approver_model_default" "$approver_model_complex")"
  fi

  if [[ -n "$mode" ]]; then
    if [[ -z "$model" ]]; then
      log_event "warning" "$(jq -nc --arg u "$pr_url" \
        --arg d "no Approver model resolved for tier $tier on $pr_url (every configured tier fell back to empty) — no App review was posted this round" \
        '{detail: $d, pr_url: $u}')"
      return 0
    fi

    prior_section=""
    if (( adjudicating )); then
      prior_section="
## Prior refusals

$(approver_prior_refusal_bodies "$pr_url" "$login")
"
    fi

    # '{}', never "$prompt_overrides_json": the Approver's adversarial prompt
    # is the gate the D18 trust ladder rests on, so no installation may extend
    # or replace it — the schema's prompt_overrides enumeration omits
    # `approver`, and this call site matches it deliberately (requirement 4a,
    # agent-ops#469).
    prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" approver '{}')

## Work order

\`\`\`json
$(jq . <<<"$work_order_json")
\`\`\`

## Implementer summary

\`\`\`json
$(jq . <<<"$impl_status_json")
\`\`\`

## Reviewer summary

\`\`\`json
$(jq . <<<"$rev_status_json")
\`\`\`

## Tier

$([[ $adjudicating -eq 1 ]] && printf 'adjudication' || printf '%s' "$tier")
$prior_section
## Cycle

$cycle_id

## Node

$node_name
"
    out="$cycle_dir/approver.out"
    stage_budget_apply approver "$selected_repo" "$model" \
      "$(jq -nc --arg t "$tier" --arg m "$mode" '{complexity: $t, mode: $m}')"
    if run_claude_stage approver "$(( stage_backstop_min * 60 ))" "$model" "$prompt" "$out" "$clone_dir" "$(( stage_inactivity_min * 60 ))"; then
      rc=0
    else
      rc=$?
    fi
    log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$model" "$out" "$stage_gaps_json")" \
      '{stage: "approver", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
    rework_stage_rerun_maybe "approver" "$stage_kill_reason" "$selected_repo" "$selected_item" "$pr_url"
    approver_watchdog_warning="$(stage_watchdog_warning approver || true)"
    [[ -n "$approver_watchdog_warning" ]] && log_event "warning" "$approver_watchdog_warning"
    (( ONCE )) && dump_stage_output "$out"

    status_json="$(extract_json_result "$(jq -r '.result // empty' "$out" 2>/dev/null || true)" 2>/dev/null || true)"
    if (( rc == 0 )) && [[ -z "$status_json" ]]; then
      status_json="$(stage_salvage_result approver "$out" "$model" "$clone_dir" || true)"
    fi

    if (( rc != 0 )) || [[ -z "$status_json" ]]; then
      log_event "warning" "$(jq -nc --arg u "$pr_url" \
        --arg d "the Approver stage did not return a parseable verdict for $pr_url — no App review was posted this round" \
        '{detail: $d, pr_url: $u}')"
      if (( adjudicating )); then
        approver_escalate "$pr_url" \
          '["the adjudication engagement did not return a parseable verdict — treated as \"cannot settle\" (D18 §5.2)"]'
      fi
      return 0
    fi

    verdict="$(jq -r '.verdict // empty' <<<"$status_json")"
    reasons_json="$(jq -c '[.reasons[]? | select(type == "string")]' <<<"$status_json" 2>/dev/null)"
    [[ "$reasons_json" != "null" && -n "$reasons_json" ]] || reasons_json='[]'

    # agent-ops#945: the token minted before the engagement (above, at the
    # top of this function) is a pre-engagement gate only — "is the
    # credential even readable" — never the value spent on the writes below.
    # An installation token lives about an hour, and an engagement can run
    # close to that long, so every write this stage makes from here on
    # (both filings and both `approver_post_or_warn` call sites) spends one
    # fresh mint read now, immediately after the engagement returns and
    # before the first write — never re-read per call, since the writes
    # land seconds apart and a per-call re-read would buy nothing.
    if ! token="$(approver_token_get "$selected_repo")"; then
      log_event "warning" "$(jq -nc --arg u "$pr_url" \
        --arg d "the Approver's installation token could not be minted again once the model engagement returned (it was still mintable at stage entry) — no tech-debt filing or App review was attempted for $pr_url this round" \
        '{detail: $d, pr_url: $u}')"
      if (( adjudicating )); then
        approver_escalate "$pr_url" "$reasons_json"
      fi
      return 0
    fi

    # file_debt/file_issue (agent-ops#631): orthogonal to `verdict` — the
    # Approver's own posture ("What you must never do") never writes to
    # GitHub itself, so lib/tech-debt-file.sh is what actually files it,
    # here, under the Approver's own App token — the same identity
    # approver_post_or_warn already posts its review under — never the
    # ordinary pipeline login. `clone_dir` is reused as-is for the tech-debt
    # id reservation: it is still on disk at this point in the cycle (torn
    # down only in the EXIT trap, well after this stage returns), and
    # techdebt_file_debt never reads or writes its checked-out branch or
    # working tree, only `origin/main` — safe regardless of what this pull
    # request's own branch happens to be checked out to.
    ap_file_debt="$(jq -c '.file_debt // empty' <<<"$status_json" 2>/dev/null || true)"
    if [[ -n "$ap_file_debt" && "$ap_file_debt" != "null" ]]; then
      ap_fd_title="$(jq -r '.title // ""' <<<"$ap_file_debt" 2>/dev/null || true)"
      ap_fd_body="$(jq -r '.body // ""' <<<"$ap_file_debt" 2>/dev/null || true)"
      # default_fix/owner_decision (agent-ops#938): the option this review
      # would take, or the owner-only clause it names instead — see
      # prompts/approver.md's "file_debt/file_issue" for what each means and
      # requirement 42a for what the Script does with them.
      ap_fd_default_fix="$(jq -r '.default_fix // ""' <<<"$ap_file_debt" 2>/dev/null || true)"
      ap_fd_owner_decision="$(jq -r \
        'if (.owner_decision // false) == true then "true" else "false" end' \
        <<<"$ap_file_debt" 2>/dev/null || true)"
      [[ -n "$ap_fd_owner_decision" ]] || ap_fd_owner_decision="false"
      # The fleet's configured `pr_label` (agent-ops TD-PPagop-26082426): this
      # call site does not otherwise have it in hand, so it is read from
      # `DEFAULTED_CONFIG` here and threaded through to techdebt_file_debt,
      # which would otherwise open its filing pull request unlabelled and
      # invisible to every gatherer that filters on it. Read here rather than
      # taken from the ambient `pr_label` agent-cycle.sh resolves (which
      # `_approver_restale_sweep_repo` below does rely on) so that the value
      # this stage files under is its own, and testable as such.
      ap_fd_pr_label="$(jq -r '.pr_label // empty' <<<"$DEFAULTED_CONFIG" 2>/dev/null || true)"
      [[ -n "$ap_fd_pr_label" ]] || ap_fd_pr_label="autonomous-agent"
      if [[ -z "$ap_fd_title" || -z "$ap_fd_body" ]]; then
        log_event "warning" "$(jq -nc --arg u "$pr_url" \
          --arg d "approver set file_debt for $pr_url, but it carries no title or body — ignored" \
          '{detail: $d, pr_url: $u}')"
      else
        # A verdict naming neither is malformed, not refused: it is filed
        # anyway with "## Default: not stated" (techdebt_default_section)
        # rather than lost, and this warning is what lets the refusal be
        # counted so the filing prompts can be tuned.
        if [[ -z "$ap_fd_default_fix" && "$ap_fd_owner_decision" != "true" ]]; then
          log_event "warning" "$(jq -nc --arg u "$pr_url" \
            --arg d "approver set file_debt for $pr_url with no default_fix and no owner_decision — filed with '## Default: not stated'" \
            '{detail: $d, pr_url: $u}')"
        fi
        if ap_fd_result="$(techdebt_file_debt "$selected_repo" "$ap_fd_title" "$ap_fd_body" \
               "while the Approver was judging $pr_url" "$token" "$clone_dir" "$ap_fd_pr_label" \
               "$ap_fd_default_fix" "$ap_fd_owner_decision")" \
               && [[ -n "$ap_fd_result" ]]; then
          IFS=$'\t' read -r ap_fd_id ap_fd_pr_url <<<"$ap_fd_result"
          log_event "tech-debt-filed" "$(jq -nc --arg u "$pr_url" --arg r "$selected_repo" \
            --arg id "$ap_fd_id" --arg fu "$ap_fd_pr_url" \
            '{pr_url: $u, repo: $r, by: "approver", id: $id, filed_pr_url: $fu}')"
        else
          log_event "warning" "$(jq -nc --arg u "$pr_url" \
            --arg d "approver: could not file the tech-debt record for $pr_url (see tech-debt-file.err)" \
            '{detail: $d, pr_url: $u}')"
        fi
      fi
    fi

    ap_file_issue="$(jq -c '.file_issue // empty' <<<"$status_json" 2>/dev/null || true)"
    if [[ -n "$ap_file_issue" && "$ap_file_issue" != "null" ]]; then
      ap_fi_title="$(jq -r '.title // ""' <<<"$ap_file_issue" 2>/dev/null || true)"
      ap_fi_body="$(jq -r '.body // ""' <<<"$ap_file_issue" 2>/dev/null || true)"
      ap_fi_default_fix="$(jq -r '.default_fix // ""' <<<"$ap_file_issue" 2>/dev/null || true)"
      ap_fi_owner_decision="$(jq -r \
        'if (.owner_decision // false) == true then "true" else "false" end' \
        <<<"$ap_file_issue" 2>/dev/null || true)"
      [[ -n "$ap_fi_owner_decision" ]] || ap_fi_owner_decision="false"
      if [[ -z "$ap_fi_title" || -z "$ap_fi_body" ]]; then
        log_event "warning" "$(jq -nc --arg u "$pr_url" \
          --arg d "approver set file_issue for $pr_url, but it carries no title or body — ignored" \
          '{detail: $d, pr_url: $u}')"
      else
        if [[ -z "$ap_fi_default_fix" && "$ap_fi_owner_decision" != "true" ]]; then
          log_event "warning" "$(jq -nc --arg u "$pr_url" \
            --arg d "approver set file_issue for $pr_url with no default_fix and no owner_decision — filed with '## Default: not stated'" \
            '{detail: $d, pr_url: $u}')"
        fi
        # The pull request's own URL is appended, not merely hoped for in
        # the model's own prose, because techdebt_file_issue's dedup guard
        # searches the issue body for exactly this string on every later
        # call — the Approver runs once per Reviewer round, so a repeated
        # observation across rounds on the same pull request must not spawn
        # a fresh issue each time.
        ap_fi_body_file="$cycle_dir/approver-file-issue.md"
        printf '%s\n\n---\nNoticed by the autonomous pipeline while approving %s.\n' \
          "$ap_fi_body" "$pr_url" > "$ap_fi_body_file"
        if ap_fi_result="$(techdebt_file_issue "$selected_repo" "$pr_url" "$ap_fi_title" \
               "$ap_fi_body_file" "$token" "$ap_fi_default_fix" "$ap_fi_owner_decision")" \
               && [[ -n "$ap_fi_result" ]]; then
          IFS=$'\t' read -r ap_fi_number ap_fi_url <<<"$ap_fi_result"
          log_event "issue-filed" "$(jq -nc --arg u "$pr_url" --arg r "$selected_repo" \
            --argjson n "$ap_fi_number" --arg iu "$ap_fi_url" \
            '{pr_url: $u, repo: $r, by: "approver", issue_number: $n, issue_url: $iu}')"
        else
          log_event "warning" "$(jq -nc --arg u "$pr_url" \
            --arg d "approver: could not file the issue for $pr_url (see tech-debt-file.err)" \
            '{detail: $d, pr_url: $u}')"
        fi
      fi
    fi
  fi

  review_body="$(jq -r 'if length == 0 then "(no reasons given)" else map("- " + .) | join("\n") end' <<<"$reasons_json")"

  if (( adjudicating )); then
    case "$verdict" in
      land)
        posted_review="APPROVE"
        approver_post_or_warn "$pr_url" APPROVE "$review_body" "$token"
        ;;
      refuse)
        posted_review="REQUEST_CHANGES"
        approver_post_or_warn "$pr_url" REQUEST_CHANGES "$review_body" "$token"
        approver_escalate "$pr_url" "$reasons_json"
        ;;
      escalate)
        approver_escalate "$pr_url" "$reasons_json"
        ;;
      *)
        approver_escalate "$pr_url" \
          '["the adjudication engagement returned an unrecognised verdict — treated as \"cannot settle\" (D18 §5.2)"]'
        ;;
    esac
  else
    case "$verdict" in
      approve)
        posted_review="APPROVE"
        approver_post_or_warn "$pr_url" APPROVE "$review_body" "$token"
        ;;
      refuse)
        posted_review="REQUEST_CHANGES"
        approver_post_or_warn "$pr_url" REQUEST_CHANGES "$review_body" "$token"
        ;;
      *)
        log_event "warning" "$(jq -nc --arg u "$pr_url" --arg v "${verdict:-empty}" \
          --arg d "the Approver returned an unrecognised verdict (\"${verdict:-empty}\") for $pr_url — no App review was posted this round" \
          '{detail: $d, pr_url: $u, verdict: $v}')"
        ;;
    esac
  fi

  # `posted` (agent-ops#573): true only when a review was actually attempted
  # (`posted_review` non-empty — an escalate-only or unrecognised verdict
  # attempts none) *and* `approver_post_or_warn` reported success. A verdict a
  # human never saw a review for cannot be compared against their eventual
  # action, so the divergence report (`lib/verdict-fate.sh`) drops it rather
  # than reading a failed write as either agreement or divergence.
  [[ -n "$posted_review" && "$approver_last_post_ok" == "1" ]] && posted_bool="true"

  adj_bool="false"
  (( adjudicating )) && adj_bool="true"
  log_event "approver-verdict" "$(jq -nc --arg u "$pr_url" --arg r "$selected_repo" --arg t "$tier" \
    --arg m "$model" --arg v "${verdict:-none}" --argjson s "$streak" --argjson adj "$adj_bool" \
    --argjson posted "$posted_bool" --arg cr "$critical_reason" \
    '{pr_url: $u, repo: $r, tier: $t, model: $m, verdict: $v, refuse_streak: $s, adjudication: $adj, posted: $posted}
     + (if $cr == "" then {} else {critical_reason: $cr} end)')"
  approver_stage_verdict="$verdict"
  approver_stage_adjudicating="$adjudicating"
  approver_stage_tier="$tier"
  return 0
}

# The restale sweep (requirement 46, agent-ops#682), moved here from
# agent-cycle.sh with the rest of the Approver stage (#771). Its own caller is
# `run_standdown_checks` (lib/standdown.sh, phase 2.1d), immediately before the
# landing-retry sweep it can feed; it sat beside `_landing_retry_sweep_repo`
# while both were inline, but it is the Approver's sweep — it re-enters
# `run_approver_stage` above, the way that one re-enters `_landing_stage_
# attempt` — so it follows the stage it drives rather than the sweep it
# precedes.
# _approver_restale_review SLUG PR_URL NUMBER BRANCH COMPLEXITY TITLE
# Requirement 46 (agent-ops#682), acceptance criterion 1: trigger a genuine
# re-review of PR_URL, reusing `run_approver_stage` itself rather than a
# second copy of its tiering/adjudication/escalation/tech-debt-filing logic —
# the same DRY reasoning `_landing_retry_sweep_repo` already applies to
# `_landing_stage_attempt`. Unlike that function's own ordinary call
# (`run_approver_stage "$impl_pr_url" "$approver_complexity"`, immediately
# after the Reviewer stage in the same cycle that raised or fixed the pull
# request), this call has no live work order, Implementer summary or
# Reviewer summary handed to it by an already-running cycle — the whole
# reason the restale sweep exists is that the cycle which *did* have them
# never reached this point (a stage timeout, a kill, a host failure; "Long-
# running commands" above names this exact failure shape, and it is what
# stranded PR #621 for 13.5 hours). So this function clones the repository
# fresh, checks the pull request's own branch out into it, and builds
# synthetic-but-honest work-order/Implementer/Reviewer JSON that says exactly
# that, then borrows `run_approver_stage`'s own globals for the one call —
# saved and restored around it, never left mutated for whatever this cycle's
# own selected work order does next.
#
# Reports its outcome through the global `_approver_restale_review_result`,
# set on every path before this function returns — `posted` once
# `run_approver_stage` reached a real verdict (whether or not the GitHub write
# itself then succeeded — that failure is already `approver_post_or_warn`'s
# own warning, and retrying it again immediately would only compound writes
# rather than fix anything), `unavailable` when a verdict could not even be
# reached: the clone or checkout failed, or `run_approver_stage` bailed out
# before engaging (the stage disabled at this level, the credential absent,
# the streak unreadable, no model resolved). `unavailable` is what tells the
# caller acceptance criterion 2's dismissal is the fallback to take instead.
#
# A global rather than something printed for the caller to capture, the same
# signalling `_landing_stage_attempt_armed` uses and for a sharper version of
# the same reason: this function's stdout is not its own. `run_approver_stage`
# ends in `(( ONCE )) && dump_stage_output`, which `cat`s the whole stage's
# result to stdout, so a `--once` run of a caller reading `$(…)` would capture
# the stage output with the outcome word glued to the end of it and route a
# re-review that did post into the dismissal fallback.
_approver_restale_review() {
  local slug="$1" pr_url="$2" number="$3" branch="$4" complexity="$5" title="$6"
  local restale_clone_dir saved_repo saved_clone saved_wo saved_impl saved_rev
  local synthetic_wo synthetic_impl synthetic_rev restale_acceptance

  _approver_restale_review_result="unavailable"

  # `${…-}` on all five: this sweep runs before the cycle has selected any
  # work of its own — that is the whole point of it — so `work_order_json`,
  # `impl_status_json` and `rev_status_json` are genuinely unset here, and
  # reading them bare under `set -u` kills this function outright. (The kill
  # lands in whatever context the caller runs it in and leaves the outcome
  # looking exactly like `unavailable`, which is why the dismissal fallback
  # hid it rather than the cycle failing loudly.) The same hazard
  # `landing_armed_by_repo`'s own declaration below names, answered where the
  # unset read actually happens, so this function stays correct wherever in a
  # cycle it is called from.
  saved_repo="${selected_repo-}"; saved_clone="${clone_dir-}"
  saved_wo="${work_order_json-}"; saved_impl="${impl_status_json-}"; saved_rev="${rev_status_json-}"

  restale_clone_dir="$workspace_root/${cycle_id}-restale-${number}"
  assert_in_workspace "$restale_clone_dir"
  if clone_repo "$slug" "$restale_clone_dir" 2>"$cycle_dir/restale-clone-${number}.err" \
     && git -C "$restale_clone_dir" fetch --quiet origin "$branch" 2>>"$cycle_dir/restale-clone-${number}.err" \
     && git -C "$restale_clone_dir" checkout --quiet "$branch" 2>>"$cycle_dir/restale-clone-${number}.err"; then
    restale_acceptance="Recovery re-review (requirement 46, agent-ops#682): the Approver's own most recent CHANGES_REQUESTED review on this pull request no longer matches its current head — a commit was authored after that review was submitted, so real work happened, but no fresh Approver round ever reached GitHub (most likely the cycle that pushed it did not finish; see this repository's own Implementer prompt, 'Long-running commands'). Judge the diff as it stands now, against this pull request's own description and history."
    synthetic_wo="$(jq -nc --arg r "$slug" --arg i "pr-${number}-approver-restale" \
      --arg b "$branch" --arg t "$title" --arg acc "$restale_acceptance" \
      '{repo: $r, item: $i, source: "approver-restale", branch: $b, title: $t, acceptance: $acc}')"
    synthetic_impl="$(jq -nc --arg u "$pr_url" \
      --arg n "synthetic recovery summary (requirement 46, agent-ops#682) — the original Implementer round's own summary is not available to this recovery engagement" \
      '{status: "complete", pr_url: $u, notes: $n}')"
    synthetic_rev="$(jq -nc --arg u "$pr_url" '{status: "ready", pr_url: $u}')"

    selected_repo="$slug"
    clone_dir="$restale_clone_dir"
    work_order_json="$synthetic_wo"
    impl_status_json="$synthetic_impl"
    rev_status_json="$synthetic_rev"

    run_approver_stage "$pr_url" "$complexity"
    [[ -n "$approver_stage_verdict" ]] && _approver_restale_review_result="posted"
  fi

  [[ -d "$restale_clone_dir" ]] && rm -rf -- "$restale_clone_dir"
  selected_repo="$saved_repo"; clone_dir="$saved_clone"
  work_order_json="$saved_wo"; impl_status_json="$saved_impl"; rev_status_json="$saved_rev"
  return 0
}

# _approver_restale_dismiss SLUG PR_URL REVIEW_ID REASON
# Requirement 46 (agent-ops#682), acceptance criterion 2: the fallback
# `_approver_restale_sweep_repo` reaches for when `_approver_restale_review`
# reports `unavailable` — self-dismissing the Approver's own stale review via
# the dismissals endpoint, which needs no permission beyond what
# `approver_post_review` already holds (both write under the same App
# identity; `approver_dismiss_review`'s own header states the precondition).
# Best-effort: logs its own outcome and never raises past the sweep that
# called it — the same "a missing review, never a stranded pull request"
# posture `approver_post_or_warn` already holds for the ordinary post.
_approver_restale_dismiss() {
  local slug="$1" pr_url="$2" review_id="$3" reason="$4" login token ok=0

  if ! login="$(approver_token_identity_login "")" || [[ -z "$login" ]]; then
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "$pr_url carries a stale Approver review a re-review could not be attempted for, and the Approver App's own login could not be read to dismiss it either — it remains blocked" \
      '{detail: $d, pr_url: $u}')"
    return 1
  fi
  if ! token="$(approver_token_get "$slug")"; then
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "$pr_url carries a stale Approver review a re-review could not be attempted for, and the Approver's installation token could not be minted to dismiss it either — it remains blocked" \
      '{detail: $d, pr_url: $u}')"
    return 1
  fi
  if approver_dismiss_review "$pr_url" "$review_id" "$reason" "$token"; then
    ok=1
    log_event "approver-restale-dismissed" "$(jq -nc --arg u "$pr_url" --arg r "$slug" --argjson id "$review_id" \
      '{pr_url: $u, repo: $r, review_id: $id}')"
  else
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "$pr_url carries a stale Approver review, a re-review could not be attempted, and GitHub refused the dismissal write too — it remains blocked" \
      '{detail: $d, pr_url: $u}')"
  fi
  (( ok ))
}

# _approver_restale_escalate SLUG PR_URL NUMBER ITEM_REF REVIEW_AT
# Requirement 46 (agent-ops#682), acceptance criteria 3 and 4: a
# rebase-only-stale Approver review — the head keeps moving, but no commit has
# been authored since the review — retried every cycle with nothing ever
# changing is exactly the "rebase-only cycle masquerading as progress" the
# issue names. Once REVIEW_AT (the standing review's own `submitted_at`,
# which a rebase does not move — never `updatedAt`) is older than
# `approver_restale_escalate_after_hours`, this hands the pull request to a
# human instead of retrying it forever, through the same generic
# `create_escalation_issue` (`enabler_assignee`) every other escalation in
# this file already uses — never a destination this function names itself
# (D18, agent-ops#627/#679).
_approver_restale_escalate() {
  local slug="$1" pr_url="$2" number="$3" item_ref="$4" review_at="$5"
  local body_file created

  body_file="$cycle_dir/approver-restale-escalation-${number}.md"
  {
    printf '## What the autonomous pipeline needs from you\n\n'
    printf 'Review %s yourself and either dismiss the standing Approver review or push a real fix — the pipeline could not tell the difference between a genuine fix and a rebase.\n\n' "$pr_url"
    printf '## Why the pipeline is blocked\n\n'
    printf "The Approver's own \`CHANGES_REQUESTED\` review (submitted %s) no longer matches this pull request's head, but no commit has been authored since that review was submitted — every push since has been a rebase, never a fix. The restale sweep (requirement 46, agent-ops#682) does not treat that as progress worth a fresh Approver engagement, and \`approver_restale_escalate_after_hours\` (%s h) has now passed with the review still standing.\n\n" \
      "$review_at" "$approver_restale_escalate_after_hours"
    cat <<RESTALE_ESC_BODY
## When you're done: close this issue

Close this issue once you have looked at the pull request yourself — dismiss
the review, or push an actual fix and let the pipeline pick the round up as
ordinary review feedback next cycle.

---
Item: \`$item_ref\` · pull request $pr_url
Raised by the Approver restale sweep (requirement 46, agent-ops#682) · cycle \`$cycle_id\` · node \`$node_name\`
RESTALE_ESC_BODY
  } > "$body_file"

  if created="$(create_escalation_issue "$slug" "$item_ref" \
        "$enabler_escalation_label" \
        "Stale Approver review on $pr_url needs your judgement" \
        "$body_file")" && [[ -n "$created" ]]; then
    log_event "approver-restale-escalated" "$(jq -nc --arg u "$pr_url" --arg r "$slug" \
      --arg n "${created%%$'\t'*}" --arg iu "${created#*$'\t'}" \
      '{pr_url: $u, repo: $r, issue_number: ($n | tonumber), issue_url: $iu}')"
  else
    log_event "warning" "$(jq -nc --arg u "$pr_url" \
      --arg d "$pr_url carries a rebase-only-stale Approver review past the escalation threshold, and the escalation issue could not be filed — will retry next cycle" \
      '{detail: $d, pr_url: $u}')"
  fi
}

# _approver_restale_sweep_repo SLUG LOGIN
# Requirement 46 (agent-ops#682): the fleet-wide sweep that keeps a pull
# request from sitting silently behind the Approver's own stale
# `CHANGES_REQUESTED` — the gap PR #621 fell into for 13.5 hours before a
# human dismissed it by hand. Same shape as `_landing_retry_sweep_repo`
# immediately above: skip a repository the kill switch or a freeze currently
# holds at `human` before any further GitHub call, then walk every open,
# non-draft, `pr_label` pull request whose `reviewDecision` is
# `CHANGES_REQUESTED`.
#
# The deterministic trigger (`approver_review_stale`, lib/approver.sh) is the
# Approver's own standing review (`landing_approver_standing_review_at`, the
# same fresh read `_landing_retry_sweep_repo` and `_landing_stage_attempt`'s
# own gate 4 already make) carrying a `commit_id` that no longer matches the
# pull request's current head — never GitHub's `requested_reviewers`, which
# silently no-ops for the Approver's own Bot identity (the exact failure
# `prompts/implementer.md`'s review-feedback section already documents
# best-effort around, and the reason this sweep exists at all rather than
# trusting that call to have worked).
#
# A stale review with a commit *authored* since it was submitted
# (`approver_newest_commit_authored_at`) is genuine progress — a rebase alone
# cannot produce one, since it reuses each replayed commit's own original
# author date — and gets a real re-review (`_approver_restale_review`,
# acceptance criterion 1), falling back to a self-dismissal
# (`_approver_restale_dismiss`, criterion 2) only when the re-review itself
# could not even be attempted. A stale review with nothing authored since it
# is a rebase-only push masquerading as one worth reviewing — neither
# re-reviewed nor dismissed, since nothing has actually changed for either
# action to judge — and is left alone until `approver_restale_escalate_after_
# hours` hands it to a human instead (`_approver_restale_escalate`, criteria 3
# and 4).
_approver_restale_sweep_repo() {
  local slug="$1" login="$2"
  local level open

  level="$(merge_autonomy_effective_level "$DEFAULTED_CONFIG" "$slug" "$state_repo" "$state_dir" fresh)"
  [[ "$level" != "human" ]] || return 0

  open="$(gh pr list -R "$slug" --state open --label "$pr_label" \
    --json number,url,headRefName,headRefOid,isDraft,reviewDecision,title,labels \
    --limit "$GITHUB_PR_LIST_LIMIT" 2>/dev/null || true)"
  jq -e 'type == "array"' <<<"$open" >/dev/null 2>&1 || open='[]'
  if github_pr_list_truncated "$(jq 'length' <<<"$open")"; then
    log_event "warning" "$(jq -nc --arg r "$slug" \
      --arg d "approver-restale sweep ($slug): the pull-request listing came back at its ${GITHUB_PR_LIST_LIMIT}-item cap; a stale review beyond it is not swept this cycle" \
      '{detail: $d, repo: $r}')"
  fi

  local candidates
  candidates="$(jq -c '[.[] | select(.isDraft | not) | select(.reviewDecision == "CHANGES_REQUESTED")
    | . + {complexity: ((.labels // []) | map(.name) | map(select(startswith("complexity:"))) | first // "" | sub("^complexity:";""))}
    | {number, url, branch: .headRefName, head: (.headRefOid // ""), title, complexity}]' <<<"$open" 2>/dev/null || echo '[]')"

  local cand pr_url branch number head title complexity standing state commit review_at
  local reviews_raw review_id item_ref newest cutoff
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    pr_url="$(jq -r '.url' <<<"$cand")"
    branch="$(jq -r '.branch' <<<"$cand")"
    number="$(jq -r '.number' <<<"$cand")"
    head="$(jq -r '.head' <<<"$cand")"
    title="$(jq -r '.title' <<<"$cand")"
    complexity="$(jq -r '.complexity' <<<"$cand")"
    [[ -n "$head" ]] || continue

    standing="$(landing_approver_standing_review_at "$slug" "$number" "$login" 2>/dev/null)" || continue
    IFS=$'\t' read -r state review_at commit <<<"$standing"
    approver_review_stale "$state" "$commit" "$head" || continue

    # The review's own numeric id, never derived from `commit`/`review_at`
    # alone (a login can legitimately submit two reviews against the same
    # commit): a fresh `jq --arg` filter over every one of this login's own
    # reviews, matched on `submitted_at` — the same unique key
    # `landing_approver_standing_review_at` itself just read. `gh api --jq`
    # has no `--arg` of its own, so the login/timestamp filter runs in this
    # second, genuine `jq` call, the same split every other reader in this
    # file already applies for the same reason.
    reviews_raw="$(gh api "repos/$slug/pulls/$number/reviews" --paginate \
                    --jq '.[] | select(.submitted_at != null) | {id, login: .user.login, at: .submitted_at}' \
                    2>/dev/null || true)"
    review_id="$(jq -s -r --arg l "$login" --arg at "$review_at" \
      '[.[] | select(.login == $l and .at == $at)] | first | (.id // empty)' <<<"$reviews_raw" 2>/dev/null || true)"
    [[ "$review_id" =~ ^[0-9]+$ ]] || continue
    item_ref="pr-${number}-approver-restale-${review_id}"

    if newest="$(approver_newest_commit_authored_at "$pr_url" 2>/dev/null)" && [[ -n "$newest" ]] \
       && [[ "$newest" > "$review_at" ]]; then
      _approver_restale_review "$slug" "$pr_url" "$number" "$branch" "$complexity" "$title"
      if [[ "$_approver_restale_review_result" != "posted" ]]; then
        _approver_restale_dismiss "$slug" "$pr_url" "$review_id" \
          "Dismissed by the autonomous pipeline (requirement 46, agent-ops#682): a commit was authored after this review, but a fresh re-review could not be attempted this cycle." || true
      fi
    else
      cutoff="$(date -u -d "${approver_restale_escalate_after_hours} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
      [[ -n "$cutoff" && "$review_at" < "$cutoff" ]] || continue
      _approver_restale_escalate "$slug" "$pr_url" "$number" "$item_ref" "$review_at"
    fi
  done < <(jq -c '.[]' <<<"$candidates" 2>/dev/null || true)
  return 0
}
