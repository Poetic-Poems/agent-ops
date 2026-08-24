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
# genuinely failing, or a pull request with no required checks at all (the
# trap above), are findings about the pull request and stay `dirty`; `gh pr
# checks --required` failing to answer at all — a 502, a transient auth
# failure, a rate limit — is a fact about this node or GitHub's availability,
# and is reported `unknown` instead. That `unknown` still refuses the handoff,
# signalled by a non-zero exit unlike the two `unknown`s below: a node whose
# `gh` cannot be trusted must not be read as "nothing wrong" merely because
# "wrong" could not be confirmed either. The distinction exists so the caller
# can log a node-level warning naming what could not be read, instead of a
# pull-request-shaped complaint that names nothing to fix.
#
# The two are told apart by `gh`'s **stderr**, not by the shape of its stdout,
# because `gh` reports "this pull request has no required checks" as an error
# and not as an empty list: `populateStatusChecks` returns
# `no required checks reported on the '<branch>' branch` (or `no checks
# reported…`, when nothing ran at all) and `checksRun` returns that before it
# ever writes the `--json` payload, so #190's trap arrives with empty stdout
# and a non-zero exit — byte-for-byte what a 502 looks like. Splitting on
# stdout alone would file every conflicting pull request as a degraded node,
# which is this item's own misattribution pointed the other way. An empty
# `[]` is still read as the trap if a future `gh` ever emits one, and any
# unrecognised diagnosis falls to `unknown`: both words refuse the handoff, so
# a reworded message costs attribution, never safety.
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
# `review_gate_unknown_streak_verdict` (TD-PPagop-26081404) is the follow-up
# to the node-level `warning` above: a `gh` degraded enough to fail the
# required-checks read rarely fails it only once, so it turns a run of
# consecutive per-node failures into one louder escalation event instead of
# one warning per item — see its own header for how it reuses
# `lib/crash-loop.sh`'s shape. `review_gate_degraded_since` is its dedup
# companion, answering "has this run already had its one loud event?" the
# way `crash_loop_escalated_since` does for requirement 2.7's crash loop.
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
# clean, 1 for dirty *or* unknown — both refuse the handoff. A pull request
# reporting no required checks stays `dirty`, never a vacuous "clean" (see
# header — the conflicting-PR-runs-no-CI trap, poetic-fiddle #190), and so
# does a required check that is real and not green. Only `gh pr checks
# --required` failing to answer at all — a 502, a transient auth failure, a
# rate limit — is `unknown`: a fact about this node or GitHub's availability,
# not about the pull request, though it still fails closed exactly like
# `dirty` (the non-zero exit is the same; only the word differs, so a caller
# can log a node-level warning instead of a pull-request-shaped complaint).
#
# Both of those arrive as a failed `gh` call with empty stdout, so the header's
# stderr test — not the shape of stdout — is what separates them.
review_gate_required_checks() {
  local url="${1:-}" gh_bin="${REVIEW_GATE_GH:-gh}" parts slug number raw failing
  local err_file diagnosis no_checks

  if [[ -z "$url" ]] || ! parts="$(_review_gate_pr_parts "$url")"; then
    printf 'dirty\tcould not resolve a pull request from %s' "$url"
    return 1
  fi
  IFS=$'\t' read -r slug number <<<"$parts"

  # stderr is kept rather than discarded because it carries the only signal
  # that tells "this pull request has no required checks" apart from "this
  # node could not ask" — see the header. A `mktemp` that fails leaves the
  # diagnosis empty, which lands on `unknown`: the conservative word, and the
  # honest one, since nothing was read.
  err_file="$(mktemp 2>/dev/null || printf '/dev/null')"
  raw="$("$gh_bin" pr checks "$number" -R "$slug" --required --json name,bucket 2>"$err_file")" || true
  diagnosis="$(cat "$err_file" 2>/dev/null || true)"
  [[ "$err_file" == /dev/null ]] || rm -f "$err_file"

  # One reason, two ways of arriving at it: `gh`'s refusal to answer for a
  # pull request that has no required checks, and the empty array no `gh` on
  # record actually emits but which would mean exactly the same thing.
  printf -v no_checks 'dirty\t%s reports no required checks at all against its head commit — the conflicting-PR-runs-no-CI trap' "$url"

  if ! jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1; then
    if [[ "$diagnosis" == *"no required checks reported on the"* \
       || "$diagnosis" == *"no checks reported on the"* ]]; then
      printf '%s' "$no_checks"
      return 1
    fi
    printf 'unknown\tcould not read %s'\''s required checks against its current head commit' "$url"
    return 1
  fi
  if ! jq -e 'length > 0' <<<"$raw" >/dev/null 2>&1; then
    printf '%s' "$no_checks"
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
# not treat them alike: exit 2 means the required-check list itself could not
# be read, so this still refuses the handoff exactly like `dirty` (an unread
# check list is never certified "nothing wrong" — see lib/review-gate.sh's
# header and TD-PPagop-26081305); exit 0 means only the security-alert (or,
# at the caller, closing-keyword) read failed, which does not itself block —
# the handoff proceeds and the caller is expected to log a warning instead.
#
# Exit 2 carries that fact even when the printed word is `dirty`: a real
# alert still outranks an unreadable required-check list for the word and the
# reason (the pull request has a nameable problem, and a milder node-level
# `unknown` must not hide it), but the word alone would then falsely certify
# the required-checks read as having succeeded — exactly the false reset
# `review_gate_unknown_streak_verdict`'s streak cannot afford
# (TD-PPagop-26081404) — so the read's own health travels in the exit status
# independently of which sub-check won the word: 0 or 1, the required-check
# list was read; 2, it was not. A caller that discards this exit status with
# `|| true` the way it safely can for a `dirty`/`clean` verdict will silently
# let an unreadable required-check list through; capture it.
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
    # The alert wins the word, but an unreadable required-check list must
    # still reach the caller — in the exit status, the only channel left
    # once the word is spoken for (see header).
    if [[ "$checks_word" == "unknown" ]]; then
      return 2
    fi
    return 1
  fi

  # Required-checks unreadable takes precedence over an unreadable alert
  # list: it is the one that must still block, so its reason is the one a
  # caller needs in hand to log the right warning and unblock_condition.
  if [[ "$checks_word" == "unknown" ]]; then
    printf 'unknown\t%s' "$checks_reason"
    return 2
  fi

  if [[ "$alerts_word" == "unknown" ]]; then
    printf 'unknown\t%s' "$alerts_reason"
    return 0
  fi

  printf 'clean'
  return 0
}

# review_gate_unknown_streak_verdict THRESHOLD NODE < event-stream.jsonl
# Print one JSON object — {node, gate, count, first_ts, last_ts} — when NODE's
# most recent run of consecutive `review-gate-checks-read` events with
# `ok: false` reaches THRESHOLD or more, with no successful read of the same
# gate by the same node in between; print nothing otherwise. Same
# THRESHOLD-off-switch convention as `lib/crash-loop.sh`'s
# `crash_loop_verdict`: 0 (or unset) prints nothing.
#
# TD-PPagop-26081404 (a follow-up to TD-PPagop-26081305): agent-cycle.sh's
# ready-gate block logs its own node-level `warning` every time this node's
# `gh` fails to read a pull request's required checks — a fact about the node,
# not the pull request, but a `gh` degraded enough to fail this once rarely
# fails it only once, so a run of them buried the same N-warnings-not-one-
# loud-signal problem `lib/crash-loop.sh` already exists to solve for the
# Co-Ordinator. That existing shape is reused here — the same reduce-over-a-
# filtered-stream, same-run-resets-on-success structure as
# `crash_loop_verdict` — rather than reused verbatim: `crash_loop_verdict`
# counts fleet-wide (one run shared by every node, keyed on matching
# `detail`), where this node's own degraded `gh` is a per-node fact a peer's
# success must never reset, so grouping had to move from "the whole stream"
# to "this node's own slice of it".
#
# The caller logs one `review-gate-checks-read` event per ready-gate
# evaluation regardless of outcome — `{ok: false}` exactly when
# `review_gate_verdict` exited 2, its required-checks-read-failed signal,
# which unlike the printed word survives a `dirty` alerts verdict outranking
# the unreadable check list (see `review_gate_verdict`'s header); `{ok:
# true}` otherwise — so this reader never has to infer a reset from the
# *absence* of a failure the way it would if only failures were logged.
review_gate_unknown_streak_verdict() {
  local threshold="${1:-0}" node="${2:-}"
  if ! [[ "$threshold" =~ ^[0-9]+$ ]] || (( threshold < 1 )) || [[ -z "$node" ]]; then
    return 0
  fi
  jq -c -R -s --argjson threshold "$threshold" --arg node "$node" '
    [ splits("\n") | select(length > 0) | (fromjson? // empty) ]
    | map(select(.event == "review-gate-checks-read" and (.node // "") == $node))
    | reduce .[] as $e (
        {count: 0, first_ts: null, last_ts: null};
        if ($e.ok // false) then
          {count: 0, first_ts: null, last_ts: null}
        elif .count > 0 then
          {count: (.count + 1), first_ts: .first_ts, last_ts: ($e.ts // .last_ts)}
        else
          {count: 1, first_ts: ($e.ts // null), last_ts: ($e.ts // null)}
        end
      )
    | select(.count >= $threshold)
    | {node: $node, gate: "required-checks"} + .
  ' 2>/dev/null || true
}

# review_gate_degraded_since FIRST_TS NODE < event-stream.jsonl
# Exit 0 when NODE's own `review-gate-checks-degraded` event for the run
# that began at FIRST_TS already exists — the current streak has had its one
# loud event, and another item degrading in the same run must not re-fire it
# — and 1 otherwise. The crash-loop analogue (`crash_loop_escalated_since`,
# lib/crash-loop.sh) has to key on "same detail at or after the run's first
# failure" because its escalated event carries no better identity for the
# run; this one's escalation event *is* the verdict object, `first_ts`
# included, so the run is matched exactly: a new streak — after any
# successful read — escalates afresh because its own `first_ts` matches no
# event already logged, while the current one, however many more items it
# degrades through, escalates once. An empty FIRST_TS answers "not
# escalated": it can only mean the verdict's own events carried no
# timestamps, and the right failure mode for an alarm is a spurious repeat a
# human sees, never a silent swallow.
review_gate_degraded_since() {
  local first_ts="${1:-}" node="${2:-}" hits
  if [[ -z "$first_ts" || -z "$node" ]]; then
    return 1
  fi
  hits="$(jq -r -R -s --arg ts "$first_ts" --arg node "$node" '
    [ splits("\n") | select(length > 0) | (fromjson? // empty)
      | select(.event == "review-gate-checks-degraded"
               and (.node // "") == $node
               and (.first_ts // "") == $ts) ]
    | length
  ' 2>/dev/null || echo 0)"
  [[ "$hits" =~ ^[0-9]+$ ]] && (( hits > 0 ))
}

# The following two functions moved from agent-cycle.sh (#771): a Reviewer
# handback that did not end in a human-visible pull request, and the
# consecutive-unreadable-checks streak both the Reviewer's own "ready"
# handoff and the Enabler's recovery path escalate through.
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

# review_gate_escalate_unreadable_streak
# TD-PPagop-26081603: the streak-and-escalate half of TD-PPagop-26081404's
# node-health bookkeeping, factored out so both call sites that run
# `handoff_complete_review` and can see `gate.checks_unreadable: true` —
# the Reviewer's own "ready" handoff below, and the Enabler's
# `complete_handoff` recovery path in `maybe_run_enabler` — escalate a run
# of consecutive unreadable-checks failures the same way, rather than only
# the former. Prints `review_gate_unknown_streak_verdict`'s own verdict JSON
# (empty below `review_gate_unknown_streak_after` consecutive failures) so a
# caller that also needs to know whether the threshold was reached — the
# Reviewer's own site logs a different per-item warning when it was not —
# does not have to recompute it. Reads `review_gate_unknown_streak_after`,
# `node_name` and `log_file` as globals, same as every other Script-
# bookkeeping helper in this file. Logs `review-gate-checks-degraded` (and
# its stderr echo) at most once per streak — `review_gate_degraded_since` is
# the dedup.
review_gate_escalate_unreadable_streak() {
  local streak_json streak_count
  streak_json="$(review_gate_unknown_streak_verdict "$review_gate_unknown_streak_after" "$node_name" < "$log_file")"
  if [[ -n "$streak_json" ]] && ! review_gate_degraded_since "$(jq -r '.first_ts // ""' <<<"$streak_json")" "$node_name" < "$log_file"; then
    log_event "review-gate-checks-degraded" "$streak_json"
    streak_count="$(jq -r '.count // "?"' <<<"$streak_json")"
    echo "agent-cycle: WARNING — node $node_name has failed to read required checks $streak_count times in a row (review-gate); see log.jsonl event review-gate-checks-degraded" >&2
  fi
  printf '%s' "$streak_json"
}
