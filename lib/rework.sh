#!/usr/bin/env bash
#
# lib/rework.sh — the rework record (docs/FLOW-SCHEMA.md, D23 of
# docs/ROADMAP.md, issue #596).
#
# One shaping function, called from every detector site this repo already
# has — agent-cycle.sh's selection/handback/stage-end paths, lib/enabler.sh's
# crash-loop escalation, lib/refinement.sh's refiner verdict loop, and
# scripts/publish-revert-rate.sh's standalone mining pass. Every one of those
# already knows, from its own detector firing, which class this repetition
# is, what evidence it fired on and (sometimes) which stage it is attributed
# to; this function only shapes that into the one documented record shape.
# It never classifies, never reads a transcript, and never asks a model — the
# "account, not a guess" line docs/FLOW-SCHEMA.md draws.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# rework_fields CLASS DETECTOR EVIDENCE_JSON [ATTRIBUTED_STAGE [REPO [ITEM [PR_URL]]]]
# Print the `rework` event's own fields — everything docs/FLOW-SCHEMA.md
# documents beyond the envelope a caller's own logger already adds
# (ts/cycle/node): `class`, `detector`, `evidence`, `attributed_stage`, and
# `repo`/`item`/`pr_url` where the caller has them ("where applicable" —
# several classes, crash-loop-escalated foremost, are fleet-wide rather than
# about one item).
#
# ATTRIBUTED_STAGE is the empty string, by default, meaning "not determined
# from the detector's own evidence" — recorded as a JSON `null`, never a
# guess (docs/FLOW-SCHEMA.md's attribution rule): a caller passes a stage
# name only when its own detector's evidence names one directly, never by
# arbitrating between plausible causes.
#
# EVIDENCE_JSON must already be a JSON value — the detector's own raw
# output (an event id, a check name, a comment id, a kill_reason, a claim
# cause), never a summary and never re-derived here. A caller that hands
# this something unparseable gets `evidence: null` rather than a failed
# call — the same degrade-not-fail contract lib/metering.sh's
# `metering_fields` keeps, because this is interpolated into the same
# `log_event` `--argjson` merge every other event field is (see
# lib/metering.sh's own header for what an unparseable argument there costs
# the whole event).
rework_fields() {
  local class="$1" detector="$2" evidence="${3:-null}" attributed="${4:-}" \
        repo="${5:-}" item="${6:-}" pr_url="${7:-}"
  jq -e . <<<"$evidence" >/dev/null 2>&1 || evidence="null"
  jq -nc --arg class "$class" --arg detector "$detector" --argjson evidence "$evidence" \
    --arg attributed "$attributed" --arg repo "$repo" --arg item "$item" --arg pr_url "$pr_url" \
    '{class: $class, detector: $detector, evidence: $evidence,
      attributed_stage: (if $attributed == "" then null else $attributed end)}
     + (if $repo == "" then {} else {repo: $repo} end)
     + (if $item == "" then {} else {item: $item} end)
     + (if $pr_url == "" then {} else {pr_url: $pr_url} end)' 2>/dev/null \
    || jq -nc --arg class "$class" --arg detector "$detector" \
         '{class: $class, detector: $detector, evidence: null, attributed_stage: null}'
}

# Every function below is a pure predicate-and-builder pair: given exactly
# the evidence its own detector already has, print that class's `rework_
# fields` (docs/FLOW-SCHEMA.md's "The nine classes"), or nothing at all when
# the evidence does not clear that class's own bar. None of them log
# anything — the one exception, `rework_stage_rerun_maybe`, is named `_maybe`
# for that reason and is the only one that calls `log_event` itself, since
# every one of its call sites wants exactly "log it if it fires" and nothing
# else. Splitting predicate from side effect is what lets
# `test/rework-record.test.sh` drive each class from canned input without
# faking a whole cycle's worth of state.

# rework_selection_class SOURCE
# Print the class name a finishing-source selection earns — `review-round-
# trip` for `review-feedback`, `merge-conflict` for `merge-conflicts`,
# `abandoned-draft-resumed` for `abandoned-drafts` — or nothing for any other
# source (`dequeued` included: it is not one of the nine classes). The
# Script's own detector for these three is the gatherer that already computed
# the candidate (`scripts/gather-<source>.sh`); selection is only where the
# record is emitted, once `{repo, item, pr_url}` are in hand.
rework_selection_class() {
  case "$1" in
    review-feedback) printf 'review-round-trip' ;;
    merge-conflicts) printf 'merge-conflict' ;;
    abandoned-drafts) printf 'abandoned-draft-resumed' ;;
  esac
}

# rework_selection_fields WORK_ORDER_JSON
# Print the rework fields for a selected finishing-source work order, or
# nothing when its `.source` earns no class (`rework_selection_class`).
# EVIDENCE is whatever of `ref`/`head_sha`/`reviewed_at`/`updated_at`/`base`
# the candidate itself carries — never re-fetched.
rework_selection_fields() {
  local work_order="${1:-{\}}" source class evidence repo item pr_url
  source="$(jq -r '.source // ""' <<<"$work_order" 2>/dev/null)"
  class="$(rework_selection_class "$source")"
  [[ -n "$class" ]] || return 0
  evidence="$(jq -c '{ref, head_sha, reviewed_at, updated_at, base}
    | with_entries(select(.value != null))' <<<"$work_order" 2>/dev/null || printf 'null')"
  repo="$(jq -r '.repo // ""' <<<"$work_order" 2>/dev/null)"
  item="$(jq -r '.item // ""' <<<"$work_order" 2>/dev/null)"
  pr_url="$(jq -r '.pr_url // ""' <<<"$work_order" 2>/dev/null)"
  rework_fields "$class" "scripts/gather-${source}.sh" "$evidence" "" "$repo" "$item" "$pr_url"
}

# rework_check_failure_fields OK REASON [REPO [ITEM [PR_URL]]]
# Print `check-failure` fields iff OK is not the literal string "true" — the
# same test `agent-cycle.sh` already applies to decide `review-gate-checks-
# read`'s own `ok` field. Never fires for `review-gate-checks-degraded`,
# which is a different event entirely (the streak *escalation*, not a
# per-attempt read) and has no call site here.
rework_check_failure_fields() {
  local ok="$1" reason="${2:-}" repo="${3:-}" item="${4:-}" pr_url="${5:-}"
  [[ "$ok" == "true" ]] && return 0
  rework_fields "check-failure" "agent-cycle.sh:review-gate-checks-read" \
    "$(jq -nc --arg r "$reason" '{ok: false, reason: $r}')" "" "$repo" "$item" "$pr_url"
}

# rework_human_change_request_fields REASON REPO ITEM PR_URL
# Print `human-change-request` fields, attributed to `reviewer` — the one
# class whose evidence names its stage directly (docs/FLOW-SCHEMA.md). The
# caller is `agent-cycle.sh`'s own `rc_word == "dirty"` branch, which already
# established that the reconciliation gate refused this handoff; there is no
# further predicate here to apply.
rework_human_change_request_fields() {
  local reason="$1" repo="${2:-}" item="${3:-}" pr_url="${4:-}"
  rework_fields "human-change-request" "lib/reconciliation-gate.sh:reconciliation_gate" \
    "$(jq -nc --arg r "$reason" '{reason: $r}')" "reviewer" "$repo" "$item" "$pr_url"
}

# rework_claim_race_duplicate_fields CAUSE RC REPO ITEM
# Print `claim-race-duplicate` fields iff CAUSE is `held` or `pr-held` —
# healthy contention, the same population `scripts/pickup-metrics.sh`'s own
# header isolates for its pickup-latency accounting (reused, not restated).
# Nothing for an empty CAUSE (predates the convention), `unreachable` (an
# outage) or any other value.
rework_claim_race_duplicate_fields() {
  local cause="$1" rc="${2:-}" repo="${3:-}" item="${4:-}"
  [[ "$cause" == "held" || "$cause" == "pr-held" ]] || return 0
  rework_fields "claim-race-duplicate" "agent-cycle.sh:claim-lost" \
    "$(jq -nc --arg cause "$cause" --arg rc "$rc" \
       '{cause: $cause} + (if $rc == "" then {} else {rc: ($rc | tonumber? // $rc)} end)')" \
    "" "$repo" "$item"
}

# rework_crash_loop_fields VERDICT_JSON
# Print `stage-rerun` fields for one escalated crash-loop run — VERDICT_JSON
# is `crash_loop_verdict`/`crash_loop_preselection_verdict`'s own object
# ({stage, detail, count, first_ts, last_ts, nodes}), carried whole as
# `evidence` since it is the detector's own raw output. `attributed_stage` is
# VERDICT_JSON's own `stage` ("coordinator" or "pre-selection") — evidence,
# not inference. Fleet-wide: no repo/item.
rework_crash_loop_fields() {
  local verdict="${1:-{\}}" stage
  stage="$(jq -r '.stage // ""' <<<"$verdict" 2>/dev/null)"
  rework_fields "stage-rerun" "lib/crash-loop.sh:crash_loop_escalate" "$verdict" "$stage"
}

# rework_refinement_bounce_back_fields REPO ITEM REASON REPORTED_BY REFINEMENTS_JSON
# Print `refinement-bounce-back` fields iff REFINEMENTS_JSON — the same
# `{repo: {item: {...}}}` map `record_needs_refinement_block`'s own
# `refined_label` cleanup already reads — carries a prior refinement for
# REPO/ITEM. Only ever called on a *fresh* block: a re-report of an already-
# open block is refused, with no record at all, before this would run.
rework_refinement_bounce_back_fields() {
  local repo="$1" item="$2" reason="${3:-}" reported_by="${4:-}" refinements="${5:-{\}}"
  jq -e --arg r "$repo" --arg i "$item" '(.[$r][$i] // null) != null' \
    <<<"$refinements" >/dev/null 2>&1 || return 0
  rework_fields "refinement-bounce-back" \
    "lib/candidate-select.sh:record_needs_refinement_block" \
    "$(jq -nc --arg reason "$reason" --arg by "$reported_by" '{reason: $reason, reported_by: $by}')" \
    "" "$repo" "$item"
}

# rework_post_merge_revert_fields SLUG DETAIL_ENTRY_JSON
# Print `post-merge-revert` fields for one entry of `scripts/mine-merge-
# history.sh`'s own `post_merge.detail[]` — always fires (dedup against
# repeated mining passes is the caller's job, via a seen-file, not this
# function's — it has no state to check against). DETAIL_ENTRY_JSON is
# `{number, kind, reason, by, by_title, hours_after}`.
rework_post_merge_revert_fields() {
  local slug="$1" entry="${2:-{\}}" number evidence
  number="$(jq -r '.number // ""' <<<"$entry" 2>/dev/null)"
  evidence="$(jq -c '{kind, reason, by, by_title, hours_after}' <<<"$entry" 2>/dev/null || printf 'null')"
  rework_fields "post-merge-revert" "scripts/mine-merge-history.sh:AGGREGATE_JQ" \
    "$evidence" "" "$slug" "$number" "https://github.com/${slug}/pull/${number}"
}

# rework_stage_rerun_maybe STAGE KILL_REASON [REPO [ITEM [PR_URL]]]
# Log one `stage-rerun` rework record iff KILL_REASON is non-empty — the same
# test every `stage-end` site already applies to decide whether to carry
# `kill_reason` on that event at all (requirement 4e's two backstop caps).
# STAGE is attributed directly: it is the stage that was killed and will be
# re-attempted, not an inference. A caller whose stage spans several items in
# one engagement (the Co-Ordinator before selection, the Enabler, the
# Refiner) passes empty REPO/ITEM/PR_URL, which `rework_fields` omits rather
# than guessing at one item among several.
#
# The one function here that logs directly rather than only printing fields:
# every call site wants exactly "log it if it fires", so folding the `[[ -n
# ]]` guard in here saves repeating it at eight call sites.
rework_stage_rerun_maybe() {
  local stage="$1" kill_reason="$2" repo="${3:-}" item="${4:-}" pr_url="${5:-}"
  [[ -n "$kill_reason" ]] || return 0
  log_event "rework" "$(rework_fields "stage-rerun" "agent-cycle.sh:stage-end" \
    "$(jq -nc --arg kr "$kill_reason" '{kill_reason: $kr}')" "$stage" "$repo" "$item" "$pr_url")"
}
