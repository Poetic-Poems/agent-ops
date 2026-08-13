#!/usr/bin/env bash
#
# lib/review-gate.sh — script-side confirmation, independent of what a
# Reviewer's own model says, that a pull request is genuinely safe to hand to
# a human as ready for review (requirement 31c, agent-ops#249).
#
# poetic-fiddle #216 reached `reviewDecision: APPROVED` while a CodeQL
# high-severity alert ("clear-text logging of sensitive information") sat
# open, hidden inside an otherwise 15/16-green check list. The Reviewer's own
# prompt already tells it to confirm CI is green before handing off
# (prompts/reviewer.md step 6), but that is a model reading a check list and
# judging it — exactly the judgement that missed this one. `lib/handoff.sh`
# already carries the fix for the same class of problem one step later (did
# the draft flip actually happen?); this file is the fix for the step before
# it — is this pull request's current state actually clean? — asked of
# GitHub rather than trusted from a report.
#
# Two things gate the handoff, both read fresh at the moment of the decision
# rather than reused from anything read earlier in the same engagement, so a
# check still catching up to a fix just pushed is never mistaken for a check
# that passed:
#
#   - every required status check is green at the pull request's current head
#     commit (`review_gate_required_checks`, `gh pr checks --required`);
#   - no code-scanning alert carrying a security severity exists on the pull
#     request's branch that does not already sit open on the base branch too
#     (`review_gate_security_alerts`) — a base branch that already lives with
#     an accepted alert must not freeze every future pull request over debt
#     that isn't theirs, so the base branch's own open alerts are subtracted
#     before anything is judged "introduced by this pull request".
#
# Both fail closed on an empty or unreadable required-check list rather than
# reading silence as "nothing wrong": poetic-fiddle #190, a CONFLICTING pull
# request, reports *no* required checks at all, which a plain "every check
# that ran was green" test over an empty list satisfies vacuously — the
# conflicting-PR-runs-no-CI trap this file's caller must not fall into.
#
# `review_gate_required_checks` still tells its own two failure shapes apart
# (TD-PPagop-26081305, agent-ops#327's review): a required check that is
# genuinely failing or an empty list (the trap above) are findings about the
# pull request and stay `dirty`; `gh pr checks --required` failing to answer
# at all — a 502, a transient auth failure, a rate limit — is a fact about
# this node or GitHub's availability, and is reported `unknown` instead. That
# `unknown` still refuses the handoff, signalled by a non-zero exit unlike the
# two `unknown`s below: a node whose `gh` cannot be trusted must not be read
# as "nothing wrong" merely because "wrong" could not be confirmed either. The
# distinction exists so the caller can log a node-level warning naming what
# could not be read, instead of a pull-request-shaped complaint that names
# nothing to fix.
#
# `review_gate_security_alerts` is a different exception, and only for the
# specific failure "the alerts API could not be asked at all" (no
# `security_events` permission on this token, code scanning not enabled on
# the repository, GitHub unreachable): that is a fact about this node or this
# repository, not about the pull request, and blocking every handoff on it
# forever would trade one hazard for a worse one — the same reasoning
# scripts/preview-deploy.sh already applies to a Vercel preview it cannot
# reach. `review_gate_verdict` reports that case as `unknown` too, but exits
# 0: a caller must say so rather than certifying a check that was never
# actually made, but need not refuse the handoff over it. The two `unknown`s
# are told apart by `review_gate_verdict`'s own exit status, not by the word
# alone — see its own header.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (agent-cycle.sh runs under `set -euo pipefail`;
# a test, `set -uo pipefail`) owns those.
#
# Environment:
#   REVIEW_GATE_GH  override `gh` (tests stub it).

# _review_gate_pr_parts PR_URL
# Print `owner/repo<TAB>number`, or return non-zero printing nothing. The same
# shape lib/handoff.sh's `_handoff_pr_parts` computes, duplicated rather than
# depended on so this file sources and tests standalone.
_review_gate_pr_parts() {
  local url="${1:-}"
  [[ "$url" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]] || return 1
  printf '%s/%s\t%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# review_gate_required_checks PR_URL
# Print `clean`, `dirty<TAB>reason`, or `unknown<TAB>reason`. Exit 0 for
# clean, 1 for dirty *or* unknown — both refuse the handoff. An empty
# required-check list stays `dirty`, never a vacuous "clean" (see header —
# the conflicting-PR-runs-no-CI trap, poetic-fiddle #190), and so does a
# required check that is real and not green. Only `gh pr checks --required`
# failing to answer at all — a 502, a transient auth failure, a rate limit —
# is `unknown`: a fact about this node or GitHub's availability, not about
# the pull request, though it still fails closed exactly like `dirty` (the
# non-zero exit is the same; only the word differs, so a caller can log a
# node-level warning instead of a pull-request-shaped complaint).
review_gate_required_checks() {
  local url="${1:-}" gh_bin="${REVIEW_GATE_GH:-gh}" parts slug number raw failing

  if [[ -z "$url" ]] || ! parts="$(_review_gate_pr_parts "$url")"; then
    printf 'dirty\tcould not resolve a pull request from %s' "$url"
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  raw="$("$gh_bin" pr checks "$number" -R "$slug" --required --json name,bucket 2>/dev/null)" || true
  if ! jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1; then
    printf 'unknown\tcould not read %s'\''s required checks against its current head commit' "$url"
    return 1
  fi
  if ! jq -e 'length > 0' <<<"$raw" >/dev/null 2>&1; then
    printf 'dirty\t%s reports no required checks at all against its head commit — the conflicting-PR-runs-no-CI trap' "$url"
    return 1
  fi
  if jq -e 'all(.[]; .bucket == "pass")' <<<"$raw" >/dev/null 2>&1; then
    printf 'clean'
    return 0
  fi

  failing="$(jq -r '[.[] | select(.bucket != "pass") | .name] | join(", ")' <<<"$raw" 2>/dev/null)"
  printf 'dirty\trequired check(s) not green: %s' "${failing:-unreadable}"
  return 1
}

# _review_gate_open_alerts SLUG REF
# Print, one per line, "<number><TAB><security_severity_level-or-empty>" for
# every code-scanning alert GitHub reports open with an instance on REF.
# Returns non-zero, printing nothing, when the API could not be asked at all —
# the caller must tell that apart from "zero alerts", which prints nothing on
# success too.
#
# `--method GET` is not decoration: `gh api` switches a request carrying `-f`
# fields to POST unless told otherwise, which against this endpoint would be a
# 404/405 rather than the listing this needs.
_review_gate_open_alerts() {
  local slug="$1" ref="$2" gh_bin="${REVIEW_GATE_GH:-gh}"
  "$gh_bin" api --method GET "repos/$slug/code-scanning/alerts" \
    -f state=open -f ref="$ref" --paginate \
    --jq '.[] | [(.number | tostring), (.rule.security_severity_level // "")] | @tsv' \
    2>/dev/null
}

# _review_gate_analysis_exists SLUG REF
# Print the number of code-scanning analyses GitHub holds for REF (asked with
# per_page=1, so the answer is 0 or 1 — existence is the question). Returns
# non-zero printing nothing when the API could not be asked at all.
#
# This exists because the alerts endpoint answers a ref that was never
# analysed with `[]` and a 200 — the same shape as a genuinely clean result
# (the Gotchas row this gate already earned). An empty alert list is only
# evidence once an analysis is known to exist for the ref it was read from.
_review_gate_analysis_exists() {
  local slug="$1" ref="$2" gh_bin="${REVIEW_GATE_GH:-gh}"
  "$gh_bin" api --method GET "repos/$slug/code-scanning/analyses" \
    -f ref="$ref" -F per_page=1 --jq 'length' 2>/dev/null
}

# review_gate_security_alerts PR_URL DEFAULT_BRANCH
# Print `clean`, `dirty<TAB>reason`, or `unknown<TAB>reason`.
#   clean    no open code-scanning alert with a security severity exists on
#            the pull request's branch that isn't already open on
#            DEFAULT_BRANCH too — and, when the alert list is empty, an
#            analysis for the merge ref actually exists to vouch for it.
#   dirty    at least one does — this pull request introduces it.
#   unknown  the alerts API could not be asked at all (see header), or no
#            analysis exists for the merge ref so an empty alert list proves
#            nothing (CodeQL skipped by path filters, a first-push race, or
#            a repository that scans on push only and files its alerts under
#            `refs/heads/<branch>`); a fact about this node, repository or
#            workflow configuration, not this pull request.
review_gate_security_alerts() {
  local url="${1:-}" default_branch="${2:-main}" parts slug number
  local pr_alerts base_alerts base_numbers new_security analyses

  if [[ -z "$url" ]] || ! parts="$(_review_gate_pr_parts "$url")"; then
    printf 'unknown\tcould not resolve a pull request from %s' "$url"
    return 0
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  # `refs/pull/<n>/merge`, not `.../head`: a pull request's code-scanning
  # analysis is uploaded by the `pull_request`-triggered workflow, which runs
  # against the merge commit, so that is the only ref GitHub ever files a pull
  # request's alerts under. The head ref carries no analysis at all and the
  # alerts API answers it with an empty list and a 200 — indistinguishable, to
  # every caller below, from "this pull request is clean". Asking the wrong ref
  # here does not fail loudly; it passes silently, which is the one failure
  # this whole file exists to prevent. Confirmed against the motivating case:
  # poetic-fiddle #216's high-severity alert is listed on
  # `refs/pull/216/merge` and absent from `refs/pull/216/head` in every state.
  if ! pr_alerts="$(_review_gate_open_alerts "$slug" "refs/pull/$number/merge")"; then
    printf 'unknown\tcould not read %s'\''s code-scanning alerts' "$url"
    return 0
  fi
  if [[ -z "$pr_alerts" ]]; then
    # An empty alert list is the same shape as "no analysis was ever run for
    # this ref" (agent-ops#270): `clean` here without confirming an analysis
    # exists would certify a check that never actually happened — for a pull
    # request CodeQL skipped, a first-push race, or a repository scanning on
    # push only, whose alerts this gate's merge-ref query can never see.
    if ! analyses="$(_review_gate_analysis_exists "$slug" "refs/pull/$number/merge")" \
       || ! [[ "$analyses" =~ ^[0-9]+$ ]]; then
      printf 'unknown\tcould not confirm a code-scanning analysis exists for refs/pull/%s/merge, so its empty alert list cannot be told apart from an analysis that never ran' "$number"
      return 0
    fi
    if (( analyses == 0 )); then
      printf 'unknown\tno code-scanning analysis exists for refs/pull/%s/merge — its empty alert list proves nothing (CodeQL skipped, a first-push race, or a repository that scans on push only)' "$number"
      return 0
    fi
    printf 'clean'
    return 0
  fi

  if ! base_alerts="$(_review_gate_open_alerts "$slug" "refs/heads/$default_branch")"; then
    printf 'unknown\tcould not read %s'\''s open code-scanning alerts, so an alert on the pull request cannot be told apart from inherited debt' "$default_branch"
    return 0
  fi
  base_numbers="$(cut -f1 <<<"$base_alerts")"

  new_security="$(while IFS=$'\t' read -r num sev; do
    [[ -n "$num" && -n "$sev" ]] || continue
    grep -qxF "$num" <<<"$base_numbers" && continue
    printf '#%s (%s)\n' "$num" "$sev"
  done <<<"$pr_alerts")"

  if [[ -z "$new_security" ]]; then
    printf 'clean'
    return 0
  fi
  printf 'dirty\topen security-severity code-scanning alert(s) introduced by this pull request: %s' \
    "$(paste -sd, - <<<"$new_security")"
  return 1
}

# review_gate_verdict PR_URL DEFAULT_BRANCH
# The one entry point agent-cycle.sh calls before ever handing a pull request
# to `confirm_pr_ready` (requirement 31a) on a Reviewer's `ready` verdict.
# Prints `clean`, `dirty<TAB>reason`, or `unknown<TAB>reason` — a `dirty`
# verdict from either sub-check always wins, so an `unknown` read never turns
# a genuinely dirty verdict into anything softer.
#
# The two ways to reach `unknown` are not the same thing, and a caller must
# not treat them alike: exit 1 means the required-check list itself could not
# be read, so this still refuses the handoff exactly like `dirty` (an unread
# check list is never certified "nothing wrong" — see lib/review-gate.sh's
# header and TD-PPagop-26081305); exit 0 means only the security-alert (or,
# at the caller, closing-keyword) read failed, which does not itself block —
# the handoff proceeds and the caller is expected to log a warning instead. A
# caller that discards this exit status with `|| true` the way it safely can
# for a `dirty`/`clean` verdict will silently let an unreadable required-check
# list through; capture it.
review_gate_verdict() {
  local url="${1:-}" default_branch="${2:-main}"
  local checks_word checks_reason alerts_word alerts_reason combined

  combined="$(review_gate_required_checks "$url")"
  IFS=$'\t' read -r checks_word checks_reason <<<"$combined"
  if [[ "$checks_word" == "dirty" ]]; then
    printf 'dirty\t%s' "$checks_reason"
    return 1
  fi

  combined="$(review_gate_security_alerts "$url" "$default_branch")"
  IFS=$'\t' read -r alerts_word alerts_reason <<<"$combined"
  if [[ "$alerts_word" == "dirty" ]]; then
    printf 'dirty\t%s' "$alerts_reason"
    return 1
  fi

  # Required-checks unreadable takes precedence over an unreadable alert
  # list: it is the one that must still block, so its reason is the one a
  # caller needs in hand to log the right warning and unblock_condition.
  if [[ "$checks_word" == "unknown" ]]; then
    printf 'unknown\t%s' "$checks_reason"
    return 1
  fi

  if [[ "$alerts_word" == "unknown" ]]; then
    printf 'unknown\t%s' "$alerts_reason"
    return 0
  fi

  printf 'clean'
  return 0
}
