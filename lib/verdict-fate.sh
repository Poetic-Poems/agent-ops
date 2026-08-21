#!/usr/bin/env bash
#
# lib/verdict-fate.sh — pairing an Approver verdict with the pull request's
# eventual fate (D18, agent-ops#573).
#
# The divergence figure that justified entering Stage 2 (#402's 2026-08-18
# amendment) was assembled by hand, pull request by pull request, because
# nothing recorded the pairing durably. `agent-cycle.sh`'s `run_approver_stage`
# already writes the verdict half live, as an `approver-verdict` event
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 33) — `repo`, `tier`,
# `model`, `verdict`, `refuse_streak`, `adjudication`, `posted` (whether the
# GitHub review this verdict describes actually reached GitHub). This file is
# the read side: given that event log plus a small amount of live GitHub
# state, it joins the two into one entry per pull request and classifies
# agreement vs divergence. `scripts/verdict-fate-report.sh` is the I/O
# wrapper that fetches the live state and renders a report; the D18 stage-1
# `divergence` criterion in `scripts/autonomy-stage-report.sh` calls the same
# functions rather than recomputing the join itself (agent-ops#571 must
# consume this record, not re-derive it).
#
# ## One entry per pull request: the *latest* verdict wins, but not for every field
#
# A pull request can carry more than one `approver-verdict` event — a refusal
# the Implementer then addresses, followed by an approval once the Reviewer
# and Approver re-run, or an approval, a human `CHANGES_REQUESTED`, and a
# second approval once the `review-feedback` source brings the pull request
# back round. The entry this file reports is always the most recent by `ts`:
# an early refusal that was later superseded is not "the" verdict this pull
# request's eventual fate is judged against, only its last one is. The one
# exception is `first_approve_ts` (`verdict_fate_latest_per_pr`): the window a
# standing human `CHANGES_REQUESTED` is tested against is the *earliest*
# `APPROVE`, not the latest verdict's own `ts` — otherwise a human review that
# lands between two approvals reads as coming "before" the (later) one this
# entry reports, and the divergence it represents never surfaces
# (agent-ops#661).
#
# ## Verdict vocabulary vs GitHub's own
#
# `approver-verdict`'s own `verdict` field carries the model's vocabulary
# (`approve`/`refuse`/`land`/`escalate`/an adjudication's own `refuse`) —
# `verdict_fate_posted_review` maps that, together with `adjudication`, onto
# the two GitHub review events the Script ever actually posts:
# `APPROVE`/`REQUEST_CHANGES`. This mapping is fixed application logic, not a
# runtime fact, so it is safe to recompute for events written before this
# file existed — no backfill needed for old events to be readable.
#
# ## Divergence is symmetric, and one fate is never collapsed
#
# `verdict_fate_classify` compares the *posted* review against what actually
# happened next:
#
#   - An `APPROVE` diverges if the pull request closed unmerged, or if a
#     human posted a `CHANGES_REQUESTED` after the approval — this second
#     case is `changes-requested-after-approval`, its own fate, never folded
#     into `closed-unmerged` even when the pull request is later fixed and
#     lands anyway (the issue's own "sharp edge": this is the specific signal
#     Stage 1/2 exist to observe, and it must never be silently dropped). It
#     agrees if the pull request landed (by the Script or by a human) with no
#     such request against it.
#   - A `REQUEST_CHANGES` diverges if the pull request landed anyway (a human
#     overrode the standing refusal) — `landed-by-script` cannot happen here,
#     since the arming step never lands a pull request the Approver refused.
#     It agrees if the pull request closed unmerged (the human concurred).
#   - Either way, a pull request still open with no standing
#     `CHANGES_REQUESTED` is `pending` — not yet resolved, excluded from the
#     agreement/divergence rate rather than guessed at.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those. Every function here is pure: it
# reads only its arguments, so it is directly unit-testable
# (test/verdict-fate.test.sh) without a live GitHub read.

# verdict_fate_posted_review VERDICT ADJUDICATION
# Print `APPROVE`, `REQUEST_CHANGES`, or empty (no review was ever attempted
# for this verdict — an adjudication `escalate`, or a verdict the stage did
# not recognise). ADJUDICATION is `true`/`false` (or unset, read as `false`).
verdict_fate_posted_review() {
  local verdict="${1:-}" adjudication="${2:-false}"
  if [[ "$adjudication" == "true" ]]; then
    case "$verdict" in
      land) printf 'APPROVE' ;;
      refuse) printf 'REQUEST_CHANGES' ;;
      *) printf '' ;;
    esac
  else
    case "$verdict" in
      approve) printf 'APPROVE' ;;
      refuse) printf 'REQUEST_CHANGES' ;;
      *) printf '' ;;
    esac
  fi
}

# verdict_fate_latest_per_pr EVENTS_JSON [REPO_PREFIX]
# Given a fleet event array (`fleet_logs`' own shape — one JSON object per
# line, already parsed into an array), reduce every `approver-verdict` event
# to the single latest (by `ts`) per `pr_url`, restricted to those whose
# posted review actually reached GitHub (`posted` true, defaulting to true
# for an event logged before that field existed — the best available
# assumption for history this file cannot re-observe) and whose mapped
# `posted_review` is non-empty. REPO_PREFIX, when given, additionally
# restricts to pull requests whose `pr_url` starts with
# `https://github.com/<REPO_PREFIX>/pull/` (case-insensitive), the same
# exact-prefix match `scripts/autonomy-stage-report.sh`'s own
# `crit_agent_approved_prs` already uses so a same-prefix decoy repo is never
# counted. `repo` is always derived from `pr_url` rather than read off the
# event's own `repo` field (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement
# 33), so a pre-agent-ops#573 event carrying no `repo` at all reads the same
# as a current one.
#
# Also carries `first_approve_ts` — the earliest `ts` among every surviving
# `approver-verdict` for this pull request whose own posted review was
# `APPROVE`, empty when there was none. A pull request can be approved,
# re-reviewed, and approved again (`review-feedback` is this pipeline's own
# way of bringing one back round after a human requests changes), and the
# *first* approval is what a standing human `CHANGES_REQUESTED` must be
# compared against — testing against the latest verdict's own `ts` would put
# an earlier human review "before" it and hide the divergence entirely
# (agent-ops#661). `verdict_fate_classify` is the reader.
#
# Prints a JSON array of `{pr_url, repo, tier, model, adjudication, verdict,
# posted_review, ts, first_approve_ts}`, oldest-verdict information already
# collapsed away — this is "one entry per pull request" (agent-ops#573).
verdict_fate_latest_per_pr() {
  local events_json="$1" prefix="${2:-}"
  jq -c --arg prefix "$prefix" '
    def posted_review:
      if .adjudication == true then
        if .verdict == "land" then "APPROVE"
        elif .verdict == "refuse" then "REQUEST_CHANGES"
        else "" end
      else
        if .verdict == "approve" then "APPROVE"
        elif .verdict == "refuse" then "REQUEST_CHANGES"
        else "" end
      end;
    def repo_from_pr_url:
      ((.pr_url // "")
        | capture("^https://github\\.com/(?<r>[^/]+/[^/]+)/pull/[0-9]+"; "i").r) // "";
    [.[] | select(.event == "approver-verdict") | select((.pr_url // "") != "")]
    | (if $prefix == "" then . else
         [.[] | select(((.pr_url // "") | ascii_downcase)
                       | startswith(("https://github.com/" + $prefix + "/pull/") | ascii_downcase))]
       end)
    | map(. + {posted_review: posted_review})
    | map(select((if .posted == null then true else .posted end) == true and .posted_review != ""))
    | group_by(.pr_url)
    | map(
        (sort_by(.ts) | last) as $latest
        | (($latest | repo_from_pr_url)) as $repo
        | ((map(select(.posted_review == "APPROVE")) | map(.ts) | sort | first) // "") as $first_approve_ts
        | {pr_url: $latest.pr_url, repo: $repo, tier: ($latest.tier // ""), model: ($latest.model // ""),
           adjudication: ($latest.adjudication // false), verdict: $latest.verdict,
           posted_review: $latest.posted_review, ts: $latest.ts, first_approve_ts: $first_approve_ts}
      )
    | sort_by(.pr_url)
  ' <<<"$events_json"
}

# verdict_fate_classify POSTED_REVIEW ARMED PR_STATE REVIEWS_JSON FIRST_APPROVE_TS
# Classify one pull request's eventual fate against its posted review.
#
#   POSTED_REVIEW  `APPROVE` or `REQUEST_CHANGES` (verdict_fate_latest_per_pr's
#                  own output).
#   ARMED          `true`/`false` — whether a `landing-armed` event exists for
#                  this `pr_url` (the same join
#                  `scripts/autonomy-stage-report.sh`'s own
#                  `crit_autonomous_landings` already performs).
#   PR_STATE       `open`, `closed` or `merged` (GitHub's own three states;
#                  case-insensitive).
#   REVIEWS_JSON   array of `{login, state, submitted_at, bot}` — every review
#                  ever submitted on the pull request, *not* reduced to each
#                  reviewer's standing position. A `CHANGES_REQUESTED` the
#                  same human later replaced with an `APPROVED` still counts
#                  here, deliberately: a divergence that happened is one this
#                  record states, however it was later resolved. That is
#                  where this differs from `_handoff_latest_reviews`'
#                  group-by-login-take-last rule (lib/handoff.sh), which
#                  answers the different question "does a human review block
#                  this pull request right now" — the one the landing gate
#                  asks.
#   FIRST_APPROVE_TS  the earliest `ts` (ISO 8601) among every `approver-verdict`
#                  for this pull request whose posted review was `APPROVE`
#                  (`verdict_fate_latest_per_pr`'s own `first_approve_ts`) —
#                  never the latest verdict's own `ts`. A pull request
#                  approved at T0, sent a standing human `CHANGES_REQUESTED`
#                  at T1, and re-approved at T2 after a `review-feedback`
#                  round must still record that divergence: testing the
#                  window against T2 would put T1 "before" it and silently
#                  drop the signal this file exists to keep (agent-ops#661).
#                  Empty when no verdict for this pull request was ever
#                  posted `APPROVE` — harmless, since the window below is
#                  only consulted when `POSTED_REVIEW` is `APPROVE`.
#
# Prints `{fate, comparison}` — `fate` one of `landed-by-script`,
# `landed-by-human`, `closed-unmerged`, `still-open`,
# `changes-requested-after-approval`; `comparison` one of `agreement`,
# `divergence`, `pending`.
verdict_fate_classify() {
  local posted_review="${1:-}" armed="${2:-false}" pr_state="${3:-}" reviews_json="${4:-[]}" first_approve_ts="${5:-}"
  jq -nc --arg pr "$posted_review" --arg armed "$armed" --arg state "$pr_state" \
    --argjson reviews "$reviews_json" --arg ts "$first_approve_ts" '
    ($state | ascii_downcase) as $s
    | ($armed == "true") as $armed_b
    | (if $s == "merged" then (if $armed_b then "landed-by-script" else "landed-by-human" end)
       elif $s == "closed" then "closed-unmerged"
       else "still-open" end) as $base_fate
    | ($reviews | map(select(((.bot // false) | not)
                              and (.state == "CHANGES_REQUESTED")
                              and (.submitted_at // "") > $ts))
                | length > 0) as $cra_after
    | if $pr == "APPROVE" and $cra_after then
        {fate: "changes-requested-after-approval", comparison: "divergence"}
      elif $pr == "APPROVE" then
        (if $base_fate == "landed-by-script" or $base_fate == "landed-by-human" then
           {fate: $base_fate, comparison: "agreement"}
         elif $base_fate == "closed-unmerged" then
           {fate: $base_fate, comparison: "divergence"}
         else
           {fate: $base_fate, comparison: "pending"}
         end)
      elif $pr == "REQUEST_CHANGES" then
        (if $base_fate == "landed-by-human" or $base_fate == "landed-by-script" then
           {fate: "landed-by-human", comparison: "divergence"}
         elif $base_fate == "closed-unmerged" then
           {fate: $base_fate, comparison: "agreement"}
         else
           {fate: $base_fate, comparison: "pending"}
         end)
      else
        {fate: $base_fate, comparison: "pending"}
      end
  '
}

# verdict_fate_summarize ENTRIES_JSON MIN_SAMPLE
# Given an array of `{comparison, ...}` (verdict_fate_classify's own output,
# one per pull request, `pending` entries included), print
# `{agreement, divergence, pending, sample, rate, status}` — `sample` is
# `agreement + divergence` (a `pending` pull request has no eventual action
# yet to compare against, so it is excluded from both the count and the
# rate); `rate` is `divergence / sample` (`null` when `sample` is 0); `status`
# is `insufficient-sample` when `sample < MIN_SAMPLE`, `divergence` when
# `divergence > 0`, `clean` otherwise — never a rate stated with too few
# pull requests behind it to mean anything (agent-ops#573's own "declining to
# state a rate below a stated minimum sample").
verdict_fate_summarize() {
  local entries_json="$1" min_sample="${2:-5}"
  jq -c --argjson min "$min_sample" '
    (map(select(.comparison == "agreement")) | length) as $a
    | (map(select(.comparison == "divergence")) | length) as $d
    | (map(select(.comparison == "pending")) | length) as $p
    | ($a + $d) as $sample
    | {
        agreement: $a, divergence: $d, pending: $p, sample: $sample,
        rate: (if $sample == 0 then null else ($d / $sample * 1000 | round) / 1000 end),
        status: (if $sample < $min then "insufficient-sample"
                 elif $d > 0 then "divergence"
                 else "clean" end)
      }
  ' <<<"$entries_json"
}
