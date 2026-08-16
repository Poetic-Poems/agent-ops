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
# weakened. Six whole-path prefixes, an explicit anchored `case` in the
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
#   CODEOWNERS   who §5.3's ruleset lets the Approver App substitute for
#
# `lib/landing.sh` is self-protecting through the `lib/` prefix already —
# no separate entry names this file, because one already covers it and a
# redundant second entry is one more place to forget to update together.
#
# Deliberately **not** on this list, despite being plainly gate-bearing:
# `agent-cycle.sh`, `review-cycle.sh` and `config.json` itself. Widening the
# list to cover them is the reviewing human's call, raised as an explicit
# question on this file's own pull request rather than decided here.
# Protected paths refuse arming at `agent-merges-all` too — relaxing that
# for the critical tier is WI-12's job (Stage 4, the cool-off), not this
# one's.
#
# ## The `SOURCE` comparison is a plain string, never a banded one
#
# `landing_eligible`'s `SOURCE` argument is compared against
# `merge_autonomy_routine_sources` by exact string equality, nothing more —
# confirmed against `agent-cycle.sh`'s own work-order construction
# (`selected_source`, set from the work order's `.source` field) and pinned
# by test/landing.test.sh rather than left to be re-discovered: every
# `issues:<band>` token in `repos[].sources`/`merge_autonomy_routine_sources`
# is a *config-time* rank (requirement 15e), but the four bands collapse to
# one plain `"issues"` the moment a candidate becomes a work order
# (`scripts/gather-issues.sh`, `"source": "issues"`) — the same collapse
# requirement 33's `first-seen` vocabulary already documents for all four
# bands. This costs nothing today: the default routine list
# (`register-hygiene`, `tech-debt`) carries no banded token, and neither
# name is banded to begin with. It will bite the day an installation adds
# `issues:low` to its own `merge_autonomy_routine_sources` expecting it to
# match — it never will, silently, because `SOURCE` here is always the
# plain word. Left as a known, disclosed limitation rather than papered
# over with a special case this file would then own forever; widening the
# comparison to fold bands together is future work if it is ever wanted.
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
# True iff PATH falls under one of the six protected prefixes — see the
# header for the list and why each is there. Whole-path prefixes only,
# anchored, never an extension rule.
_landing_is_protected() {
  case "$1" in
    .github/*) return 0 ;;
    deploy/*) return 0 ;;
    prompts/*) return 0 ;;
    lib/*) return 0 ;;
    config.schema.json) return 0 ;;
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
  if jq -e 'type == "array"' <<<"$repo_list" >/dev/null 2>&1; then
    printf '%s' "$repo_list"
    return 0
  fi
  local top_list
  top_list="$(jq -c '.merge_autonomy_routine_sources // empty' <<<"$config_json" 2>/dev/null)"
  if jq -e 'type == "array"' <<<"$top_list" >/dev/null 2>&1; then
    printf '%s' "$top_list"
    return 0
  fi
  printf '["register-hygiene","tech-debt"]'
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
#   - `landing_protected_paths_hit` says no.
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
  if [[ -z "$source" ]] || ! jq -e --arg s "$source" 'index($s) != null' <<<"$routine_json" >/dev/null 2>&1; then
    printf 'ineligible:source %s is not in %s'\''s configured routine list %s' \
      "${source:-empty}" "$slug" "$routine_json"
    return 0
  fi

  local hit_paths hit_rc
  hit_paths="$(landing_protected_paths_hit "$slug" "$number")"; hit_rc=$?
  case "$hit_rc" in
    0)
      printf 'ineligible:touches protected path(s): %s' "$(paste -sd, - <<<"$hit_paths")"
      return 0
      ;;
    2)
      printf 'unknown:could not establish %s#%s'\''s changed-file list' "$slug" "$number"
      return 0
      ;;
  esac

  printf 'eligible'
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

# landing_arm SLUG NUMBER TOKEN
# The single write that actually lands a pull request: enqueue where the
# base branch has an active merge queue (`enqueuePullRequest`), or
# `gh pr merge --auto --squash` where it does not. Prints the method used —
# `enqueued` or `auto-merge` — the word `agent-cycle.sh` logs verbatim as
# `landing-armed`'s own `method` field; prints nothing and returns non-zero
# on any failure, including one this function cannot tell apart from a
# partial write (GitHub's own response is what decides that, per call,
# below), so a caller must never read a non-zero exit as anything but "no
# write happened it can vouch for".
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
    --jq '{id: .node_id, base: .base.ref}' 2>/dev/null)" || return 1
  node_id="$(jq -r '.id // empty' <<<"$pr_json" 2>/dev/null)"
  base="$(jq -r '.base // empty' <<<"$pr_json" 2>/dev/null)"
  [[ -n "$node_id" && -n "$base" ]] || return 1

  local queue_json
  queue_json="$(merge_queue_for_branch "$slug" "$base")" || return 1

  if [[ "$queue_json" != "null" ]]; then
    local mutate_out
    # shellcheck disable=SC2016  # GraphQL's own $id variable, not the shell's.
    mutate_out="$(GH_TOKEN="$token" "$gh_bin" api graphql \
      -f query='mutation($id:ID!){enqueuePullRequest(input:{pullRequestId:$id}){mergeQueueEntry{id}}}' \
      -f id="$node_id" \
      --jq '.data.enqueuePullRequest.mergeQueueEntry.id' 2>/dev/null)" || return 1
    [[ -n "$mutate_out" ]] || return 1
    printf 'enqueued'
    return 0
  fi

  GH_TOKEN="$token" "$gh_bin" pr merge "$number" -R "$slug" --auto --squash >/dev/null 2>&1 || return 1
  printf 'auto-merge'
}
