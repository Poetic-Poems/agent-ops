#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/enabler.sh — the Enabler stage (requirements 35–37): the pipeline's
# escalation path, a high-tier model engaged rarely to re-examine items
# recorded as blocked that the pipeline has not managed to unstick by
# itself, and — for the ones that genuinely need a human — compose the
# GitHub issue the Script then files, assigned, saying exactly what to do.
#
# Split out of agent-cycle.sh (#771). Runs from the exit trap (see
# `cleanup`, still in agent-cycle.sh), so every substitution here is
# guarded and every `gh` call tolerates failure by construction — the
# Enabler failing must never look like the cycle failing (requirement 37).
# Reads and writes the cycle's own globals (`cycle_dir`, `enabler_allowed`,
# `enabler_eligible_json`, …) exactly as they did inline.

# `run_claude_stage` — the stage launcher, its wall-clock cap and its
# process-group kill — lives in lib/stage-run.sh, sourced at the top of this
# script alongside every other shared rule. It is shared with review-cycle.sh
# rather than copied into it (requirement 4d).

# --- The Enabler (requirements 35–37) ---------------------------------------
# The pipeline's escalation path: a high-tier model, engaged rarely, that
# re-examines items recorded as blocked which the pipeline has not managed to
# unstick by itself — and, for the ones that genuinely need a human, composes a
# GitHub issue the Script then files, assigned, saying exactly what to do.
#
# Everything below is best-effort by construction, because it runs from the exit
# trap (see `cleanup`). A non-zero status escaping any of it would abandon the
# trap part-way and cost the cycle its `cycle-end` event, its lock release and
# its state-sync push — the Enabler failing must never look like the cycle
# failing (requirement 37). So every substitution is guarded, every `gh` call
# tolerates failure, and the whole thing is invoked as `… || true`.

# enabler_claim_key ENTRY
# The fleet's dedup key for one eligible item (requirement 35c): the repo, the
# item, and the epoch of the block it was minted from — plus `__verify<n>` when
# this engagement is verifying a closed escalation, which needs a fresh key
# because the earlier examination's claim is still in the registry.
#
# Derived here, never chosen by a model: two nodes must compute the same key for
# the same item or the claim locks nothing. Keying on the block's timestamp is
# what lets a re-blocked item be examined again while the tombstone of its last
# examination stands.
enabler_claim_key() {
  local entry="$1" repo item ts issue epoch key
  repo="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
  item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
  ts="$(jq -r '.blocked_ts // ""' <<<"$entry" 2>/dev/null || true)"
  issue="$(jq -r 'if (.reason // "") == "issue-closed"
                  then ((.escalation.issue_number // "") | tostring) else "" end' \
             <<<"$entry" 2>/dev/null || true)"
  epoch="$(date -d "$ts" +%s 2>&1)" || { guard_warn "blocked-item-epoch" "$epoch"; epoch=0; }
  key="${repo//[^A-Za-z0-9._-]/-}__${item//[^A-Za-z0-9._-]/-}__$epoch"
  [[ -n "$issue" && "$issue" != "null" ]] && key="${key}__verify${issue}"
  printf '%s' "$key"
}

# escalation_webhook_notify REPO ITEM TITLE BODY_FILE
# Best-effort, `GH_TOKEN`-independent fallback for an escalation
# `create_escalation_issue` could not file (requirement 2m,
# TD-PPagop-26082304). Every escalation route ultimately reaches GitHub
# through the same credential its own trigger may have just shown GitHub
# rejects — requirement 2.0b's is the expected case, but 1c's usage-limit
# freeze and requirement 2.7's crash loop can hit a dead token or a genuine
# outage too — so this lives inside `create_escalation_issue` itself rather
# than at each call site: every route gets the same fallback, and no site
# has to guess whether its own failure was credential-shaped.
#
# A no-op when `escalation_webhook_url` is unset (the default): nothing is
# attempted, so an installation that configures none of this behaves exactly
# as it did before this existed. When it is set, POSTs a JSON body carrying
# `reason` (TITLE) and `detail` (BODY_FILE's own content) — the same two
# fields a `stand-down` event already carries — plus `item`, `repo`, `node`
# and `cycle` for routing. Never propagates a failure of its own: a webhook
# that is down, misconfigured, or rejects the payload is worth a local
# `warning` event for a human to find later, never worth costing the caller
# the escalation it was already failing to file through GitHub.
escalation_webhook_notify() {
  local repo="$1" item="$2" title="$3" body_file="$4"
  [[ -n "$escalation_webhook_url" ]] || return 0
  local detail payload
  detail="$(cat "$body_file" 2>/dev/null || true)"
  payload="$(jq -nc --arg reason "$title" --arg detail "$detail" \
    --arg repo "$repo" --arg item "$item" --arg node "$node_name" \
    --arg cycle "$cycle_id" \
    '{reason: $reason, detail: $detail, repo: $repo, item: $item, node: $node, cycle: $cycle}' \
    2>/dev/null)" || return 0
  if ! curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
        --data-binary "$payload" "$escalation_webhook_url" \
        >/dev/null 2>>"$cycle_dir/escalation-webhook.err"; then
    log_event "warning" "$(jq -nc --arg d "escalation webhook POST to escalation_webhook_url failed for item $item — see escalation-webhook.err" '{detail: $d}')"
  fi
  return 0
}

# create_escalation_issue REPO ITEM LABEL TITLE BODY_FILE
# File one escalation issue, printing "<number>\t<url>"; print nothing and
# return 1 if it could not be filed — after which `escalation_webhook_notify`
# has already made one best-effort attempt at the credential-independent
# fallback, so a caller need not repeat it. Three behaviours, in order:
#
#   - A duplicate guard. An open issue carrying the escalation label whose body
#     already quotes this item's reference *is* the escalation — return it
#     rather than filing a second one at the same human. The item ref in the
#     issue footer (prompts/enabler.md) is what makes this findable, and the
#     body check is what stops a bare number matching an unrelated escalation.
#   - The create carries the label *and* the assignee. The assignee is the
#     load-bearing half: assignment is what excludes an issue from the `issues`
#     work source (requirement 16.4), so the pipeline can never select its own
#     request for help as work. The label is for the human's filter and the
#     guard above.
#   - One retry without the label, because a repo where the label has not been
#     created yet must still get its issue. Losing the label costs a filter;
#     losing the issue costs the escalation.
create_escalation_issue() {
  local repo="$1" item="$2" label="$3" title="$4" body_file="$5"
  local existing raw url number
  existing="$(gh issue list -R "$repo" --label "$label" --state open --search "$item" \
                --json number,url,body 2>/dev/null \
              | jq -r --arg it "$item" \
                  'map(select(((.body // "") | contains($it)))) | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi
  # Only on the path that actually creates: an escalation repo is often not one
  # the cycle otherwise touches (`crash_loop_repo` by construction is not), so
  # its label has nowhere else to be ensured. Costs nothing on the duplicate
  # path above, which is the common one. The retry-without-label below stays
  # regardless — this makes the label likely, not certain, and an escalation
  # must be raised either way.
  labels_ensure_role "$CONFIG_FILE" "$SCHEMA_FILE" "$repo" escalation >/dev/null 2>&1 || true
  raw="$(gh issue create -R "$repo" --title "$title" --body-file "$body_file" \
           --assignee "$enabler_assignee" --label "$label" \
           2>>"$cycle_dir/enabler-issue.err" || true)"
  if [[ -z "$raw" ]]; then
    raw="$(gh issue create -R "$repo" --title "$title" --body-file "$body_file" \
             --assignee "$enabler_assignee" \
             2>>"$cycle_dir/enabler-issue.err" || true)"
  fi
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  if [[ -z "$url" ]]; then
    escalation_webhook_notify "$repo" "$item" "$title" "$body_file"
    return 1
  fi
  number="${url##*/}"
  if [[ ! "$number" =~ ^[0-9]+$ ]]; then
    escalation_webhook_notify "$repo" "$item" "$title" "$body_file"
    return 1
  fi
  printf '%s\t%s' "$number" "$url"
}

# escalation_thread_reconcile REPO ITEM OUTCOME NUMBER URL
# The Script's own completing or correcting comment on a `needs-refinement`
# item that is itself a GitHub issue, once this engagement has established
# what actually happened to its `escalate` verdict (agent-ops#815).
#
# `prompts/enabler.md` ("Refinement items", "When the work item *is* an
# issue") has the Enabler post its own comment on the work item's thread
# during its one turn, linking to the escalation it is composing. But that
# turn ends before any of the three things that decide whether an escalation
# actually exists ever run: whether `adjudicate-first`'s adjudication pass
# overrides the verdict with `adequate`, the `create_escalation_issue` call
# itself, and whether that call succeeds — all of which happen afterwards, in
# this function's caller. The model cannot truthfully assert the escalation
# exists at comment time, because nothing has decided that yet. Three items
# escalated in the same cycle (#604, #613, #640) each carried exactly this
# false claim, left standing, because nothing reconciled it against what the
# Script went on to do.
#
# Scoped to the one case `prompts/enabler.md` documents a work-item comment
# for at all: a `needs-refinement` block whose item is a bare GitHub issue
# number (the caller checks both before calling this at all).
#
#   OUTCOME                the thread gets
#   escalated               a completing comment carrying `Blocked-by:
#                           #NUMBER` on its own line — the exact form
#                           `dependency_refs` (lib/dependency-gate.sh) and
#                           `scripts/gather-issues.sh` require, so the very
#                           next gather excludes this item deterministically
#                           rather than from prose.
#   adjudicated-adequate     a correcting comment: no escalation was filed,
#                           because the adjudication pass found the existing
#                           refinement adequate and the item was unblocked on
#                           that basis instead.
#   decide-settled           a correcting comment: no escalation was filed,
#                           because a decide-tactical pass (agent-ops#936)
#                           settled the item — the `settle` verdict's own
#                           equivalent of `adjudicated-adequate` above. A
#                           `decide` verdict never reaches here: it posts its
#                           own comment carrying the decision itself
#                           (`enabler_decision_comment`), which already says
#                           plainly that no escalation was filed.
#   escalation-failed        a correcting comment: the escalation attempt
#                           itself failed; a later re-examination will retry
#                           it.
#
# Best-effort like every other `gh` write in this file (requirement 37): a
# failure here is logged as a `warning`, never a reason to unwind the verdict
# already recorded — the underlying outcome stands whether or not this
# comment lands.
escalation_thread_reconcile() {
  local repo="$1" item="$2" outcome="$3" number="$4" url="$5"
  local prose body
  case "$outcome" in
    escalated)
      [[ -n "$number" ]] || return 0
      prose="Escalation filed: $url

Blocked-by: #$number"
      ;;
    adjudicated-adequate)
      prose="No escalation issue was filed for this item: an \`adjudicate-first\` pass found the existing refinement adequate, and the item was unblocked on that basis instead."
      ;;
    decide-settled)
      prose="No escalation issue was filed for this item: a \`decide-tactical\` pass settled it directly, and the item was unblocked on that basis instead."
      ;;
    escalation-failed)
      prose="No escalation issue was filed for this item: the attempt itself failed. A later cycle will retry once this item is re-examined."
      ;;
    *)
      return 0
      ;;
  esac
  body="$(pipeline_comment_header script "$node_name")

$prose

$(pipeline_comment_marker "$cycle_id" script)"
  gh issue comment "$item" -R "$repo" --body "$body" \
    >/dev/null 2>>"$cycle_dir/enabler-escalation-link.err" \
    || log_event "warning" "$(jq -nc --arg r "$repo" --arg i "$item" \
         --arg d "enabler: could not post the escalation-thread reconciliation comment on $repo#$item (see enabler-escalation-link.err)" \
         '{detail: $d, repo: $r, item: $i}')"
}

# crash_loop_escalate VERDICT_JSON ITEM_REF KIND_LABEL TITLE_PREFIX EVIDENCE_LINE
# Shared by both requirement-2.7 crash-loop classes: same dedup
# (`crash_loop_escalated_since`), same label, same load-bearing assignee, same
# `crash-loop-escalated` event shape — only the wording, the item ref that
# keys `create_escalation_issue`'s open-issue dedup, and where a human should
# start reading differ between them. KIND_LABEL is the plural noun phrase for
# "N consecutive KIND_LABEL"; EVIDENCE_LINE is a prose line naming what to
# read first.
#
# Files immediately, unconditionally, whatever VERDICT_JSON's own history —
# callers decide *whether* and *when* it is safe to call this (see
# `crash_loop_escalate_or_defer` below, agent-ops#1074); this function only
# ever files or defers, on the dedup check it has always made. Returns 0 on
# a successful filing (or the dedup no-op) and 1 when `create_escalation_issue`
# could not file, so a caller that queued this attempt for a later re-check
# (a fresh verdict's own first attempt, called from `crash_loop_escalate_or_
# defer`) knows to queue it.
crash_loop_escalate() {
  local verdict_json="$1" item_ref="$2" kind_label="$3" title_prefix="$4" evidence_line="$5"
  local cl_detail cl_first_ts cl_body cl_created
  cl_detail="$(jq -r '.detail // ""' <<<"$verdict_json")"
  cl_first_ts="$(jq -r '.first_ts // ""' <<<"$verdict_json")"
  if crash_loop_escalated_since "$cl_first_ts" "$cl_detail" < "$union_log"; then
    return 0
  fi
  cl_body="$cycle_dir/crash-loop-issue-${item_ref#crash-loop:}.md"
  {
    printf '## What the fleet log shows\n\n'
    jq -r --arg k "$kind_label" \
      '"- **\(.count) consecutive \($k)**, every one `\(.detail)`\n- first at `\(.first_ts)`, still failing at `\(.last_ts)`\n- nodes affected: \(.nodes | join(", "))"' \
      <<<"$verdict_json"
    cat <<CRASH_LOOP_BODY

No recovery — a success, or (for a pre-selection death) a cycle reaching a
selection stage — has happened anywhere in the fleet since the first of these.
A failure this uniform is almost certainly deterministic — something that
ships in the image or the config, not a transient — so no amount of retrying
will clear it, and until it clears the fleet selects no work at all.

$evidence_line

---
Filed automatically by agent-cycle.sh (requirement 2.7).
ref: $item_ref
CRASH_LOOP_BODY
  } > "$cl_body"
  if cl_created="$(create_escalation_issue "$crash_loop_repo" "$item_ref" \
        "$enabler_escalation_label" \
        "$title_prefix ($cl_detail)" \
        "$cl_body")" && [[ -n "$cl_created" ]]; then
    log_event "crash-loop-escalated" "$(jq -c \
      --argjson n "${cl_created%%$'\t'*}" --arg u "${cl_created#*$'\t'}" \
      '. + {issue_number: $n, issue_url: $u}' <<<"$verdict_json")"
    # stage-rerun's other detector (docs/FLOW-SCHEMA.md, D23): the deterministic-
    # failure and pre-selection-death classes `crash_loop_verdict`/
    # `crash_loop_preselection_verdict` catch never carried a `kill_reason` —
    # a killed-by-backstop stage and a deterministic crash loop are different
    # mechanisms, which is why `rework_stage_rerun_maybe` above cannot see this
    # one. One record per escalated *run*, not per failure it counted: the
    # individual failures a run comprises were never a repetition this system
    # could see at the time (no per-item block, nothing pinned a repo/item),
    # so `verdict_json`'s own `count` is carried as evidence rather than
    # expanded into that many synthetic entries. Fleet-wide, like the run
    # itself: no repo/item.
    log_event "rework" "$(rework_crash_loop_fields "$verdict_json")"
  else
    # Structured, not a bare `warning`, because `crash_loop_deferred_since`
    # (lib/crash-loop.sh) must recognise this exact run on a later cycle —
    # the whole reason a deferred retry does not repeat this same premature
    # filing attempt (agent-ops#1074). Carries VERDICT_JSON's own fields
    # (`detail`, `first_ts`, …) untouched, under `message` rather than
    # overwriting `detail` with prose a dedup check would have to re-parse.
    log_event "crash-loop-deferred" "$(jq -c --arg m "crash loop detected ($cl_detail) but the escalation issue could not be filed — will retry" '. + {message: $m}' <<<"$verdict_json")"
    return 1
  fi
}

# crash_loop_escalate_or_defer VERDICT_JSON ITEM_REF KIND_LABEL TITLE_PREFIX EVIDENCE_LINE
# The step-1b entry point for either crash-loop class (requirement 2.7,
# agent-ops#1074) — called at the same early point in the cycle
# `crash_loop_escalate` always was, before this cycle's own Co-Ordinator
# attempt (if any) has run.
#
# A FRESH verdict — nothing has ever tried to file this exact run before
# (`crash_loop_deferred_since` finds no prior attempt) — is filed here,
# immediately, exactly as `crash_loop_escalate` always has: at this point in
# the cycle the verdict is as current as it has ever been, since no earlier
# attempt existed to have gone stale.
#
# A DEFERRED RETRY — a previous cycle already tried and failed to file this
# exact run — is not filed here at all. The verdict computed at this point in
# *this* cycle is exactly as stale as the one a previous cycle already
# failed to file: it was gathered before this cycle's own Co-Ordinator has
# had its chance, so it can never see a recovery that attempt is about to
# produce. Filing it here is what turned the 2026-08-29/30 Ockham outage's
# last hour into a false alarm (agent-ops#1070): the escalation and the
# success that refuted it landed in the same cycle, the escalation first
# only because this block runs before the Co-Ordinator does.
#
# So a deferred retry (and a fresh verdict that itself failed to file, added
# by `crash_loop_escalate`'s own new return code — no reason to make it wait
# a whole extra cycle when this one is not over yet) is queued in
# `crash_loop_pending_refile` instead, and re-verified against the fleet's
# freshest state at `cleanup()`, after every stage this cycle might run has
# had its chance to prove the run over.
crash_loop_escalate_or_defer() {
  local verdict_json="$1" item_ref="$2" kind_label="$3" title_prefix="$4" evidence_line="$5"
  local cl_detail cl_first_ts
  cl_detail="$(jq -r '.detail // ""' <<<"$verdict_json")"
  cl_first_ts="$(jq -r '.first_ts // ""' <<<"$verdict_json")"
  if crash_loop_escalated_since "$cl_first_ts" "$cl_detail" < "$union_log"; then
    return 0
  fi
  if crash_loop_deferred_since "$cl_first_ts" "$cl_detail" < "$union_log"; then
    crash_loop_pending_refile+=("$(jq -nc \
      --arg ref "$item_ref" --arg kl "$kind_label" --arg tp "$title_prefix" --arg ev "$evidence_line" \
      --argjson v "$verdict_json" \
      '{item_ref: $ref, kind_label: $kl, title_prefix: $tp, evidence_line: $ev, verdict: $v}')")
    return 0
  fi
  if ! crash_loop_escalate "$verdict_json" "$item_ref" "$kind_label" "$title_prefix" "$evidence_line"; then
    crash_loop_pending_refile+=("$(jq -nc \
      --arg ref "$item_ref" --arg kl "$kind_label" --arg tp "$title_prefix" --arg ev "$evidence_line" \
      --argjson v "$verdict_json" \
      '{item_ref: $ref, kind_label: $kl, title_prefix: $tp, evidence_line: $ev, verdict: $v}')")
  fi
}

# crash_loop_refile_pending
# Runs from `cleanup()` (agent-ops#1074), after every stage this cycle might
# run has had its chance — the fresh union snapshot `fleet_logs` builds here
# includes this cycle's own now-complete Co-Ordinator attempt, which the
# original verdict in `crash_loop_pending_refile` (built at step 1b, before
# that attempt) could never see.
#
# For each queued attempt: re-verify with `crash_loop_reverify`. Broken (the
# run this verdict named has since ended) drops it — `crash-loop-dropped`
# records why, naming the run's own detail/first_ts, so this is
# distinguishable in the log from a run that simply never re-crossed
# threshold. Still active refiles it, via the same `crash_loop_escalate` a
# fresh verdict uses (its own dedup guards against a peer having escalated
# this run meanwhile) — a filing that fails here just logs another
# `crash-loop-deferred`, exactly as a fresh failure does, and the run is
# picked up again next cycle.
#
# A union log this function cannot read (`fleet_logs` producing nothing) is
# never evidence of recovery: requirement 2.7's own rule, "silence must never
# retire an alarm" — every still-queued attempt is filed on the strength of
# its original (step-1b) verdict instead of being re-verified at all.
crash_loop_refile_pending() {
  (( ${#crash_loop_pending_refile[@]} )) || return 0
  local fresh_union
  fresh_union="$(fleet_logs "$state_dir" "$peers_dir" log.jsonl)"
  local entry item_ref kind_label title_prefix evidence_line verdict_json fresh
  for entry in "${crash_loop_pending_refile[@]}"; do
    item_ref="$(jq -r '.item_ref' <<<"$entry")"
    kind_label="$(jq -r '.kind_label' <<<"$entry")"
    title_prefix="$(jq -r '.title_prefix' <<<"$entry")"
    evidence_line="$(jq -r '.evidence_line' <<<"$entry")"
    verdict_json="$(jq -c '.verdict' <<<"$entry")"
    if [[ -z "$fresh_union" ]]; then
      crash_loop_escalate "$verdict_json" "$item_ref" "$kind_label" "$title_prefix" "$evidence_line" || true
      continue
    fi
    fresh="$(crash_loop_reverify "$verdict_json" "$crash_loop_after" <<<"$fresh_union")"
    if [[ -n "$fresh" ]]; then
      crash_loop_escalate "$fresh" "$item_ref" "$kind_label" "$title_prefix" "$evidence_line" || true
    else
      log_event "crash-loop-dropped" "$(jq -c --arg ref "$item_ref" \
        '. + {item_ref: $ref, reason: "run broken since first_ts; deferred filing dropped"}' \
        <<<"$verdict_json")"
    fi
  done
}

# crash_loop_retire_resolved
# Closes any open crash-loop escalation whose run has since broken *and*
# whose breaking Co-Ordinator success can be named — both conditions, since
# the detector going quiet alone is not evidence of recovery (see the
# `success_ts` guard below) — the Co-Ordinator class only (`stage:
# "coordinator"`, agent-ops#1074);
# `crash_loop_preselection_verdict`'s own class has no single resetting
# event `crash_loop_last_success_since` can name for the closing comment (a
# clean cycle exit and a selection-path stage-start both reset it), and
# nothing in the issue this exists for asked for that class's retirement.
#
# Runs from step 1b, against this cycle's ordinary start-of-cycle
# `$union_log`: unlike a deferred filing, retirement has no same-cycle race
# to lose to — an open issue's run either broke some earlier cycle (visible
# in any union snapshot since) or it did not, so the freshest-available
# snapshot serves exactly as well as one gathered later would.
#
# Before touching any open escalation, this also checks whether the same
# `$union_log` already shows a *fresh* Co-Ordinator run under the very same
# detail — regardless of that run's own `first_ts` — via a plain
# `crash_loop_verdict` recompute, and skips retirement outright if so
# (agent-ops#1134 review). `crash_loop_reverify` below already refuses to
# retire the *exact* run an open issue names; it cannot see a *new* run that
# has since re-crossed `crash_loop_after` under the same detail, because that
# new run has a different `first_ts` and so reads as a different run to a
# same-first_ts match. Step 1b in agent-cycle.sh now runs this function
# before either `crash_loop_escalate_or_defer` call, which closes the
# single-cycle, single-node version of that gap — but a peer node can still
# have escalated (and so rebound the still-open issue to) that new run in an
# earlier cycle whose own rebind event has not yet reached this node's
# peer-synced union. Without this check, this node would then retire the
# issue the peer just rebound, on the strength of a union snapshot that is
# stale only about the rebind, not about the new run's failures themselves —
# which this same snapshot already shows.
crash_loop_retire_resolved() {
  [[ -n "$crash_loop_repo" && -s "$union_log" ]] || return 0
  local entry stage detail first_ts issue_number issue_url success_ts body
  local active_detail
  active_detail="$(jq -r '.detail // empty' <<<"$(crash_loop_verdict "$crash_loop_after" < "$union_log")" 2>/dev/null)"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    stage="$(jq -r '.stage // ""' <<<"$entry")"
    [[ "$stage" == "coordinator" ]] || continue
    detail="$(jq -r '.detail // ""' <<<"$entry")"
    first_ts="$(jq -r '.first_ts // ""' <<<"$entry")"
    issue_number="$(jq -r '.issue_number // ""' <<<"$entry")"
    issue_url="$(jq -r '.issue_url // ""' <<<"$entry")"
    [[ -n "$detail" && -n "$first_ts" && "$issue_number" =~ ^[0-9]+$ ]] || continue
    [[ -n "$active_detail" && "$active_detail" == "$detail" ]] && continue
    [[ -z "$(crash_loop_reverify "$(jq -nc --arg s "$stage" --arg d "$detail" --arg f "$first_ts" \
                '{stage: $s, detail: $d, first_ts: $f}')" "$crash_loop_after" < "$union_log")" ]] || continue
    success_ts="$(crash_loop_last_success_since "$stage" "$first_ts" < "$union_log")"
    # Positive evidence only. `crash_loop_reverify` going quiet is not the
    # same fact as "the Co-Ordinator recovered": a run stops matching the
    # detector whenever it stops being *this* run, and a still-broken fleet
    # does that all the time — every run is same-detail by construction, so
    # one failing node starting to say `api_error` where it used to say
    # `coordinator exited 126` ends the run without anything recovering. A
    # `crash_loop_after` raised between the filing and now, or a peer whose
    # failures made up the run no longer syncing its log, end it the same
    # way. Retiring on any of those closes a live alarm and asserts a
    # success that never happened — the precise mistake, in the opposite
    # direction, that requirement 2.7's "silence must never retire an alarm"
    # forbids. So the success must be nameable before the issue is closed,
    # which is also the only way the closing comment can name it as
    # requirement 2.7 says it does. Not nameable: leave it open, and let a
    # human close it.
    [[ -n "$success_ts" ]] || continue
    body="The Co-Ordinator has succeeded since this run's first failure (\`$first_ts\`) — at \`$success_ts\`. The loop this escalation reported has broken.

---
Retired automatically by agent-cycle.sh (requirement 2.7)."
    if gh issue close "$issue_number" -R "$crash_loop_repo" --comment "$body" \
         >/dev/null 2>>"$cycle_dir/crash-loop-retire.err"; then
      log_event "crash-loop-retired" "$(jq -nc --arg s "$stage" --arg d "$detail" --arg f "$first_ts" \
        --argjson n "$issue_number" --arg u "$issue_url" \
        '{stage: $s, detail: $d, first_ts: $f, issue_number: $n, issue_url: $u}')"
    else
      log_event "warning" "$(jq -nc --argjson n "$issue_number" \
        --arg d "crash-loop escalation issue #$issue_number has resolved but could not be closed — see crash-loop-retire.err" \
        '{detail: $d, issue_number: $n}')"
    fi
  done < <(crash_loop_open_escalations < "$union_log")
}

# escalation_autonomy_pass_available REPO ITEM CLAIMED_ENTRY_JSON
# The bound on `adjudicate-first` (agent-ops#627, requirement 36b): one
# adjudication pass per item, per human touch. True (exit 0) when this item
# still has its pass to spend; false, having logged why, when it does not.
#
# Mechanical, for the same reason the thrash guard beside it is. An `adequate`
# verdict clears the block and re-records the *existing* refinement, so the
# item returns to the pool with `refined_before` still set — and a re-flag of
# it reaches the very same `escalate` verdict, over the very same evidence, a
# pass has already answered once. Left unbounded, that pass would run again
# and answer the same way, and the disagreement requirement 36b routes to a
# human would loop between two models indefinitely with nobody ever paged:
# the failure the thrash guard exists to stop, one level up.
#
# The one exemption is the thrash guard's own — eligibility `reason:
# "issue-closed"`, which exists only because a human acted on an escalation
# about this item (requirement 35a), making the pass it authorises the first
# since they did. `${union_log:-$log_file}` for the reason
# `void_obsolete_ctx_json` uses it: a peer's adjudication counts as much as
# this node's, and an Enabler reached before the union log is built falls back
# to this node's own record rather than dying under `errexit`.
escalation_autonomy_pass_available() {
  local repo="$1" item="$2" entry="$3" elig_reason
  elig_reason="$(jq -r '.reason // ""' <<<"$entry" 2>/dev/null || true)"
  [[ "$elig_reason" != "issue-closed" ]] || return 0
  escalation_autonomy_adjudicated_before "$repo" "$item" \
    < "${union_log:-$log_file}" || return 0
  log_event "warning" "$(jq -nc --arg r "$repo" --arg i "$item" \
    --arg d "enabler: $repo $item has already spent its one adjudication pass and no human has acted on it since — escalating without adjudicating (escalation_autonomy is bounded per item, per human touch)" \
    '{detail: $d, repo: $r, item: $i}')"
  return 1
}

# run_enabler_adjudication REPO ITEM CLAIMED_ENTRY_JSON EX_JSON CYCLE_DIR IDX
# One bounded adjudication pass (agent-ops#627, D18 pattern,
# `escalation_autonomy: "adjudicate-first"`): before the Script files the
# escalation issue for a refinement-disagreement item (requirement 36b), ask
# a fresh, narrower Enabler engagement — over this one item alone — whether
# CLAIMED_ENTRY's own existing refinement (`refined_before`) already answers
# the re-flag's reason, mirroring the Approver's own adjudication path
# (requirement 8c) in shape: bounded, once, verdict-plus-evidence logged.
# Runs at `enabler_model_critical` (agent-ops#936, requirement 36d/§6),
# falling back to `enabler_model` when that is empty — the Enabler's own
# critical tier, the same "empty switches the escalation off" pattern
# `approver_model_critical` uses for the Approver's own adjudication —
# reusing the backstop and inactivity caps `stage_budget_apply` already
# resolved for the calling engagement rather than deriving a second budget
# for an actor this system has no per-actor timeout key for.
#
# Prints `{"verdict": "adequate"|"inadequate", "evidence": "..."}` on stdout.
# A missing prompt file, a stage failure, or an unparseable verdict all print
# `inadequate` with an `evidence` string naming why — "cannot settle" reads
# the same way the Approver's own adjudication reads it: not as "nothing
# wrong" (requirement 8c).
run_enabler_adjudication() {
  local repo="$1" item="$2" claimed_entry="$3" ex="$4" cycle_dir="$5" idx="$6"
  local input prompt out rc=0 result parsed verdict evidence
  local critical_model="${enabler_model_critical:-$enabler_model}"

  if [[ ! -f "$PROMPTS_DIR/enabler-adjudicate.md" ]]; then
    printf '{"verdict":"inadequate","evidence":"no prompts/enabler-adjudicate.md in this installation"}'
    return 0
  fi

  input="$(jq -nc --arg r "$repo" --arg i "$item" \
    --argjson refinement "$(jq -c '.refined_before // {}' <<<"$claimed_entry" 2>/dev/null || printf '{}')" \
    --argjson reflag "$(jq -c '{reason: (.reason // ""), detail: (.detail // ""), unblock_condition: (.unblock_condition // "")}' \
       <<<"$claimed_entry" 2>/dev/null || printf '{}')" \
    --argjson escalation "$(jq -c '{title: (.issue.title // ""), body: (.issue.body // "")}' <<<"$ex" 2>/dev/null || printf '{}')" \
    '{repo: $r, item: $i, refinement: $refinement, reflag: $reflag, escalation: $escalation}' \
    2>/dev/null || true)"
  if [[ -z "$input" ]]; then
    printf '{"verdict":"inadequate","evidence":"could not build the adjudication input"}'
    return 0
  fi

  prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" enabler-adjudicate "$prompt_overrides_json")

## Runtime input for this adjudication

\`\`\`json
$(jq . <<<"$input")
\`\`\`
"
  out="$cycle_dir/enabler-adjudicate-$idx.out"
  if run_claude_stage enabler-adjudicate "$(( stage_backstop_min * 60 ))" "$critical_model" "$prompt" "$out" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" \
    --argjson m "$(metering_fields "$critical_model" "$out" "$stage_gaps_json")" \
    '{stage: "enabler-adjudicate", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
  rework_stage_rerun_maybe "enabler-adjudicate" "$stage_kill_reason" "$repo" "$item" \
    "$(jq -r '.pr_url // ""' <<<"$claimed_entry")"

  result="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$result" 2>/dev/null || true)"
  if (( rc != 0 )) || [[ -z "$parsed" ]]; then
    if (( rc == 124 )); then
      printf '{"verdict":"inadequate","evidence":"the adjudication engagement timed out"}'
    else
      printf '{"verdict":"inadequate","evidence":"the adjudication engagement returned no parseable verdict"}'
    fi
    return 0
  fi
  verdict="$(jq -r '.verdict // ""' <<<"$parsed" 2>/dev/null || true)"
  evidence="$(jq -r '.evidence // ""' <<<"$parsed" 2>/dev/null || true)"
  [[ "$verdict" == "adequate" ]] || verdict="inadequate"
  jq -nc --arg v "$verdict" --arg e "$evidence" '{verdict: $v, evidence: $e}' 2>/dev/null \
    || printf '{"verdict":"inadequate","evidence":"could not encode the adjudication verdict"}'
}

# escalation_autonomy_decide_pass_available REPO ITEM CLAIMED_ENTRY_JSON MAX_PASSES
# The bound on `decide-tactical` (agent-ops#936, requirement 36d): a pass is
# available when eligibility `reason` is `issue-closed` — the same one-touch
# exemption `escalation_autonomy_pass_available` grants `adjudicate-first`,
# since a human has just acted on an escalation about this item (requirement
# 35a) and the pass it authorises is the first since they did — or when this
# reflag's own reason key has never been decided or adjudicated before *and*
# fewer than MAX_PASSES decide-tactical passes have run for this item at all,
# whatever their reason. A reason already seen refuses regardless of how many
# passes remain under the cap: two engagements disagreeing about the same
# question, repeatedly, is exactly what `always-escalate` would have routed to
# a human on the first round, and a bound that let it retry indefinitely would
# reinstate the loop `escalation_autonomy_adjudicated_before`'s own "bounded,
# not a loop" guard exists to stop, one rung up.
escalation_autonomy_decide_pass_available() {
  local repo="$1" item="$2" entry="$3" max_passes="$4" elig_reason reason_key count
  elig_reason="$(jq -r '.reason // ""' <<<"$entry" 2>/dev/null || true)"
  [[ "$elig_reason" != "issue-closed" ]] || return 0
  reason_key="$(escalation_autonomy_decide_reason_key "$entry")"
  if escalation_autonomy_decide_reason_seen "$repo" "$item" "$reason_key" < "${union_log:-$log_file}"; then
    log_event "warning" "$(jq -nc --arg r "$repo" --arg i "$item" \
      --arg d "enabler: $repo $item has already been decided or adjudicated over this exact reason and no human has acted since — escalating without a fresh pass (escalation_autonomy: decide-tactical is bounded per reason, per item, per human touch)" \
      '{detail: $d, repo: $r, item: $i}')"
    return 1
  fi
  count="$(escalation_autonomy_decide_pass_count "$repo" "$item" < "${union_log:-$log_file}")"
  [[ "$max_passes" =~ ^[0-9]+$ ]] || max_passes=3
  if (( count >= max_passes )); then
    log_event "warning" "$(jq -nc --arg r "$repo" --arg i "$item" --argjson n "$max_passes" \
      --arg d "enabler: $repo $item has already spent its $max_passes decide-tactical passes — escalating without a fresh pass (the cap counts the item's whole history; a human touch grants one further pass regardless of it)" \
      '{detail: $d, repo: $r, item: $i}')"
    return 1
  fi
  return 0
}

# run_enabler_decide REPO ITEM CLAIMED_ENTRY_JSON EX_JSON CYCLE_DIR IDX
# One bounded decide-tactical pass (agent-ops#936, D18 pattern,
# `escalation_autonomy: "decide-tactical"`): before the Script files the
# escalation issue for *any* `escalate` verdict — not only a refinement
# disagreement, `run_enabler_adjudication`'s own narrower scope — ask a fresh,
# narrower Enabler engagement, over this one item alone, whether the item can
# be settled, decided tactically, or genuinely needs a person. Mirrors
# `run_enabler_adjudication` in shape and runs at the same tier
# (`enabler_model_critical`, falling back to `enabler_model`).
#
# Prints `{"verdict": "settle"|"decide"|"escalate", "evidence": "...",
# "decision": "...", "rationale": "...", "options_considered": "..."}` on
# stdout. A missing prompt file, a stage failure, or an unparseable verdict
# all print `escalate` with an `evidence` string naming why — "cannot settle"
# reads the same way the Approver's own adjudication reads it: not as
# "nothing wrong" (requirement 8c).
run_enabler_decide() {
  local repo="$1" item="$2" claimed_entry="$3" ex="$4" cycle_dir="$5" idx="$6"
  local input prompt out rc=0 result parsed verdict evidence decision rationale options
  local critical_model="${enabler_model_critical:-$enabler_model}"

  if [[ ! -f "$PROMPTS_DIR/enabler-decide.md" ]]; then
    printf '{"verdict":"escalate","evidence":"no prompts/enabler-decide.md in this installation"}'
    return 0
  fi

  input="$(jq -nc --arg r "$repo" --arg i "$item" \
    --arg kind "$(jq -r '.kind // ""' <<<"$claimed_entry" 2>/dev/null || true)" \
    --argjson refinement "$(jq -c '.refined_before // {}' <<<"$claimed_entry" 2>/dev/null || printf '{}')" \
    --argjson reflag "$(jq -c '{reason: (.reason // ""), detail: (.detail // ""), unblock_condition: (.unblock_condition // "")}' \
       <<<"$claimed_entry" 2>/dev/null || printf '{}')" \
    --argjson escalation "$(jq -c '{title: (.issue.title // ""), body: (.issue.body // "")}' <<<"$ex" 2>/dev/null || printf '{}')" \
    '{repo: $r, item: $i, kind: $kind, refinement: $refinement, reflag: $reflag, escalation: $escalation}' \
    2>/dev/null || true)"
  if [[ -z "$input" ]]; then
    printf '{"verdict":"escalate","evidence":"could not build the decide-tactical input"}'
    return 0
  fi

  prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" enabler-decide "$prompt_overrides_json")

## Runtime input for this decide-tactical pass

\`\`\`json
$(jq . <<<"$input")
\`\`\`
"
  out="$cycle_dir/enabler-decide-$idx.out"
  if run_claude_stage enabler-decide "$(( stage_backstop_min * 60 ))" "$critical_model" "$prompt" "$out" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" \
    --argjson m "$(metering_fields "$critical_model" "$out" "$stage_gaps_json")" \
    '{stage: "enabler-decide", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
  rework_stage_rerun_maybe "enabler-decide" "$stage_kill_reason" "$repo" "$item" \
    "$(jq -r '.pr_url // ""' <<<"$claimed_entry")"

  result="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$result" 2>/dev/null || true)"
  if (( rc != 0 )) || [[ -z "$parsed" ]]; then
    if (( rc == 124 )); then
      printf '{"verdict":"escalate","evidence":"the decide-tactical engagement timed out"}'
    else
      printf '{"verdict":"escalate","evidence":"the decide-tactical engagement returned no parseable verdict"}'
    fi
    return 0
  fi
  verdict="$(jq -r '.verdict // ""' <<<"$parsed" 2>/dev/null || true)"
  evidence="$(jq -r '.evidence // ""' <<<"$parsed" 2>/dev/null || true)"
  case "$verdict" in
    settle|decide) : ;;
    *) verdict="escalate" ;;
  esac
  decision="$(jq -r '.decision // ""' <<<"$parsed" 2>/dev/null || true)"
  rationale="$(jq -r '.rationale // ""' <<<"$parsed" 2>/dev/null || true)"
  options="$(jq -r '.options_considered // ""' <<<"$parsed" 2>/dev/null || true)"
  if [[ "$verdict" == "decide" && ( -z "$decision" || -z "$rationale" ) ]]; then
    # A decide verdict missing its own decision or rationale is not one this
    # system can act on: nothing would be recorded on decision-taken or posted
    # to the item's thread that a human could later audit. Falls to escalate
    # rather than being recorded as a decision nobody can read (requirement
    # 8c's "cannot settle" reading applies here too).
    verdict="escalate"
    evidence="${evidence:-the decide-tactical pass reached \"decide\" but returned no decision or rationale to record}"
  fi
  jq -nc --arg v "$verdict" --arg e "$evidence" --arg d "$decision" --arg ra "$rationale" --arg o "$options" \
    '{verdict: $v, evidence: $e}
     + (if $v == "decide" then {decision: $d, rationale: $ra, options_considered: $o} else {} end)' 2>/dev/null \
    || printf '{"verdict":"escalate","evidence":"could not encode the decide-tactical verdict"}'
}

# enabler_decision_comment REPO ITEM DECISION RATIONALE OPTIONS SUPPLEMENTS_REFINEMENT
# The human-touch equivalent for a `decide` verdict (agent-ops#936,
# requirement 36d): one comment on the item's own issue thread, in the
# pipeline's voice, carrying the decision taken in place of escalating —
# and, since the ordinary Enabler engagement that reached `escalate` may
# already have posted its own "an escalation is being requested" comment on
# this same thread for a refinement item (`prompts/enabler.md`, "Refinement
# items"), this one also says plainly that no escalation was filed after all.
# Prints the comment's own URL on success, nothing on failure — best-effort
# like every other `gh` write in this file (requirement 37): a failure here
# is logged as a warning, never a reason to unwind the verdict already
# recorded, the same contract `escalation_thread_reconcile` beside it keeps.
enabler_decision_comment() {
  local repo="$1" item="$2" decision="$3" rationale="$4" options="$5" supplements_refinement="$6"
  local prose body url
  prose="No escalation issue was filed for this item: a decide-tactical pass decided the tactical question directly.

## Tactical decision

$decision

**Rationale:** $rationale"
  [[ -n "$options" ]] && prose="$prose

**Options considered:** $options"
  if [[ -n "$supplements_refinement" ]]; then
    prose="$prose

The specification already on this thread stands, amended by this decision."
  fi
  body="$(pipeline_comment_header enabler-decide "$node_name")

$prose

$(pipeline_comment_marker "$cycle_id" enabler-decide)"
  url="$(gh issue comment "$item" -R "$repo" --body "$body" \
    2>>"$cycle_dir/enabler-decision-comment.err")" || return 0
  printf '%s' "$url"
}

# maybe_run_enabler CYCLE_EXIT_CODE
# Engage the Enabler if this cycle should, and translate its verdicts into log
# events and issues. Always returns without disturbing the cycle's outcome.
maybe_run_enabler() {
  local cycle_rc="${1:-1}"
  local claimed_json='[]' engagement_json='[]' n_eligible=0 n_claimed=0 n_out=0 i j
  local entry repo item key live_resume live_epoch input prompt out rc=0 result parsed detail
  local items_named_json
  local ex e_repo e_item verdict e_reason claimed_entry blocked_ts outcome extra e_evidence_field
  local e_void_entry e_void_refusal
  local e_pr_url e_handoff e_refusal e_refined
  local e_flag_evidence_field e_flag_resolvable e_flag_resolve_reason e_flag_pr_num
  local e_block_stage e_default_branch e_review_json e_gate_word e_gate_reason
  local e_gate_checks_unreadable e_ck_word e_ck_reason e_rc_word e_rc_reason e_rc_revert
  local e_review_safe e_gate_checks_ok e_finding
  local e_rereview_state e_rereview_who e_human_reviewer_state e_human_reviewer_who
  local e_human_rate_note
  local issue_title issue_body_file created number url missing
  local e_adjudication e_adj_verdict e_adj_evidence e_adjudicated e_refined_adj
  local e_ea_level e_kind e_refined_before_present
  local e_decided e_decision e_dec_verdict e_dec_evidence e_dec_reason_key e_refined_dec
  local e_dec_decision_text e_dec_rationale e_dec_options e_dec_comment_url
  local e_file_debt fd_title fd_body fd_pr_label fd_result fd_id fd_pr_url \
    fd_default_fix fd_owner_decision
  local e_file_issue fi_title fi_body fi_body_file fi_result fi_number fi_url \
    fi_default_fix fi_owner_decision

  # --- Guards (requirement 35). Every one of them declining is normal. ---
  # The lock is the log's single-writer guarantee, and this stage writes events.
  (( lock_acquired )) || return 0
  # Set only once the gatherers finished, so no early exit — a standby node, the
  # switch, a cooldown, a skipped cycle that never sampled — can engage a stage
  # on inputs that were never computed.
  (( enabler_allowed )) || return 0
  # A dry run claims nothing and writes nothing, here as everywhere.
  (( DRY_RUN )) && return 0
  # A cycle that ended badly is not the moment to spend the expensive model: the
  # failure itself is the thing to look at, and the item will still be blocked
  # next cycle.
  [[ "$cycle_rc" == "0" ]] || return 0
  (( limit_hit_this_cycle )) && return 0
  [[ -n "$enabler_model" ]] || return 0
  [[ -f "$PROMPTS_DIR/enabler.md" ]] || return 0

  # Requirement 35d: the refinement class is capped per engagement, ordinary
  # blocked items are not. Applied before the claims, so a capped-out item is
  # left unclaimed and waits — a claim taken and not examined would be a
  # tombstone standing for `claim_ttl_hours` over an item nobody looked at.
  engagement_json="$(refinement_engagement_set "$enabler_eligible_json" "$refinement_max_per_engagement")"
  n_eligible="$(jq 'length' <<<"$engagement_json" 2>&1)" \
    || { guard_warn "enabler:n_eligible" "$n_eligible"; n_eligible=0; }
  [[ "$n_eligible" =~ ^[0-9]+$ ]] || n_eligible=0
  (( n_eligible > 0 )) || return 0

  # The fleet limit file, read live rather than from the union snapshot taken at
  # the start of the cycle (requirement 2.1's second carrier): a limit a peer hit
  # while this cycle was working is exactly the news that should stop the most
  # expensive stage in the system from starting.
  live_resume="$(fleet_limit_resume_at "$state_repo" "$state_dir" 2>/dev/null || true)"
  if [[ -n "$live_resume" ]]; then
    live_epoch="$(date -d "$live_resume" +%s 2>&1)" \
      || { guard_warn "live_epoch" "$live_epoch"; live_epoch=0; }
    (( live_epoch > $(date +%s) )) && return 0
  fi

  # --- Claim each item (requirement 35c) ---
  # A per-item file claim under the pseudo-slug `enabler`, deterministic across
  # nodes so exactly one engages, and **never released**: the claim is a
  # tombstone. `lib/claim.sh gc` sweeping it at `claim_ttl_hours` is what lets a
  # failed engagement be retried, and is the only thing that does.
  for (( i = 0; i < n_eligible; i++ )); do
    entry="$(jq -c --argjson i "$i" '.[$i]' <<<"$engagement_json" 2>/dev/null || true)"
    [[ -n "$entry" ]] || continue
    repo="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
    item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
    [[ -n "$repo" && -n "$item" ]] || continue
    key="$(enabler_claim_key "$entry")"
    [[ -n "$key" ]] || continue
    if CLAIM_NODE="$node_name" CLAIM_CYCLE="$cycle_id" CLAIM_ITEM="$item" CLAIM_SOURCE="enabler" \
         "$SCRIPT_DIR/lib/claim.sh" claim file enabler "$key" \
         >>"$cycle_dir/claim.log" 2>&1; then
      # requirement 4g (TD-PPagop-26081401): $claimed_json grows by one
      # blocked entry, evidence payload included, per Enabler claim this
      # cycle — unbounded past this call, so $entry joins it on stdin
      # rather than riding in as a second --argjson.
      # TD-PPagop-26081407: passes test 1 -- $claimed_json and $entry are
      # concatenated in-memory immediately above; the trivial append script
      # cannot fail independently of the concatenation itself.
      claimed_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
        <<<"$claimed_json"$'\n'"$entry" 2>/dev/null || printf '%s' "$claimed_json")"
    fi
  done
  n_claimed="$(jq 'length' <<<"$claimed_json" 2>&1)" \
    || { guard_warn "n_claimed" "$n_claimed"; n_claimed=0; }
  [[ "$n_claimed" =~ ^[0-9]+$ ]] || n_claimed=0
  # Every eligible item already claimed is the ordinary quiet case — this node
  # examined them last cycle, or a peer is examining them now — and is silent on
  # purpose: a warning here would fire every cycle until the tombstones expire.
  (( n_claimed > 0 )) || return 0

  # --- One engagement over every claimed item ---
  # Batched deliberately: the reading is per-item but the session overhead is
  # not, and the items in front of it are few by construction.
  # `$lbl`, not `$label`: `label` is a jq keyword, and a jq program that fails to
  # compile here would leave the runtime input empty — which the guard below turns
  # into a silently skipped engagement.
  # The claimed items arrive on stdin, bound with `input as $items`
  # (requirement 4g) — never in argv. Only the refinement class is capped per
  # engagement (see the claim loop above); ordinary blocked items are not, and
  # each carries its block's evidence payload, so past MAX_ARG_STRLEN this
  # build would fail into the guard below and skip the engagement silently —
  # disabling the very stage that retires blocked state.
  input="$(jq -nc --arg lbl "$enabler_escalation_label" \
    --arg assignee "$enabler_assignee" --arg cycle "$cycle_id" --arg node "$node_name" \
    'input as $items
     | {items: $items, escalation_label: $lbl, assignee: $assignee, cycle: $cycle, node: $node}' \
    <<<"$claimed_json" 2>/dev/null || true)"
  [[ -n "$input" ]] || return 0

  prompt="$(stage_prompt_text "$PROMPTS_DIR" "$state_dir" enabler "$prompt_overrides_json")

## Runtime input for this engagement

\`\`\`json
$(jq . <<<"$input")
\`\`\`
"
  out="$cycle_dir/enabler.out"
  # The Enabler spans repositories by construction, so its cell is keyed `*`
  # (requirement 4f) — there is no repository this engagement belongs to.
  stage_budget_apply enabler "*" "$enabler_model"
  if run_claude_stage enabler "$(( stage_backstop_min * 60 ))" "$enabler_model" "$prompt" "$out" "$cycle_dir" "$(( stage_inactivity_min * 60 ))"; then
    rc=0
  else
    rc=$?
  fi
  log_event "stage-end" "$(jq -nc --argjson rc "$rc" --arg kr "$stage_kill_reason" --argjson m "$(metering_fields "$enabler_model" "$out" "$stage_gaps_json")" \
    '{stage: "enabler", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
  # No repo/item: the Enabler spans repositories by construction (see above).
  rework_stage_rerun_maybe "enabler" "$stage_kill_reason"
  # `if`, not `&&`: an empty warning is the common case, and a trailing
  # `&&` whose test fails is a non-zero status at exactly the place
  # `set -e` acts on — the same trap that cost a --once cycle its
  # failure handling at dump_stage_output.
  watchdog_warning="$(stage_watchdog_warning enabler || true)"
  if [[ -n "$watchdog_warning" ]]; then
    log_event "warning" "$watchdog_warning"
  fi
  (( ONCE )) && dump_stage_output "$out"

  result="$(jq -r '.result // empty' "$out" 2>/dev/null || true)"
  parsed="$(extract_json_result "$result" 2>/dev/null || true)"
  # A process that exited cleanly but left an unparseable final message has a
  # living session behind it worth one more ask (issue #237); a timeout or a
  # non-zero exit does not, since nothing held the session open to resume.
  if (( rc == 0 )) && [[ -z "$parsed" ]]; then
    parsed="$(stage_salvage_result enabler "$out" "$enabler_model" "$cycle_dir" || true)"
  fi
  if (( rc != 0 )) || [[ -z "$parsed" ]]; then
    # A timeout or unparseable output changes nothing: no verdict was reached, so
    # no state event is written and the claims stand until gc allows a retry. The
    # cycle's own outcome is untouched (requirement 37); a usage-limit phrase in
    # the transcript still goes down the ordinary cooldown path, because that
    # applies to the whole fleet and not just to this stage.
    if (( rc == 124 )); then
      detail="enabler timed out"
    elif (( rc != 0 )); then
      detail="enabler exited $rc"
    else
      detail="enabler returned an unparseable final message"
    fi
    detect_and_log_limit_hit "$out" || true
    items_named_json="$(jq -c '[.[] | {repo: (.repo // ""), item: (.item // "")}]' <<<"$claimed_json" 2>&1)" \
      || { guard_warn "items_named_json" "$items_named_json"; items_named_json='[]'; }
    # requirement 4g (TD-PPagop-26081401): trimmed to {repo, item} per entry,
    # the most bounded aggregate on TD-PPagop-26081401's list, but it still
    # grows with the number of items this engagement claimed, so it arrives
    # on stdin rather than as a second --argjson.
    log_event "warning" "$(jq -nc --arg d "$detail — no verdicts recorded; the claims stand until gc lets a later cycle retry" \
      'input as $items | {detail: $d, items: $items}' <<<"$items_named_json")"
    # The tombstone (requirement 35c) stays a tombstone — releasing it outright
    # would let the next cycle re-engage the same still-unchanged items at
    # Opus prices with nothing new to show for it. Backdating each entry's
    # `ts` past `claim_ttl_hours` is the middle ground requirement 37 asks
    # for: `lib/claim.sh gc` retires it on its very next sweep — this cycle's
    # own 2.1a, an hour away rather than up to `claim_ttl_hours` — instead of
    # leaving a lost engagement's items frozen for the tombstone's full life.
    for (( i = 0; i < n_claimed; i++ )); do
      entry="$(jq -c --argjson i "$i" '.[$i]' <<<"$claimed_json" 2>/dev/null || true)"
      [[ -n "$entry" ]] || continue
      key="$(enabler_claim_key "$entry")"
      [[ -n "$key" ]] || continue
      "$SCRIPT_DIR/lib/claim.sh" expire enabler "$key" >>"$cycle_dir/claim.log" 2>&1 || true
    done
    return 0
  fi

  # --- Verdicts (requirement 36a) ---
  n_out="$(jq '(.examined // []) | length' <<<"$parsed" 2>&1)" \
    || { guard_warn "n_out" "$n_out"; n_out=0; }
  [[ "$n_out" =~ ^[0-9]+$ ]] || n_out=0
  for (( j = 0; j < n_out; j++ )); do
    ex="$(jq -c --argjson j "$j" '(.examined // [])[$j]' <<<"$parsed" 2>/dev/null || true)"
    [[ -n "$ex" ]] || continue
    e_repo="$(jq -r '.repo // ""' <<<"$ex" 2>/dev/null || true)"
    e_item="$(jq -r '.item // ""' <<<"$ex" 2>/dev/null || true)"
    verdict="$(jq -r '.verdict // ""' <<<"$ex" 2>/dev/null || true)"
    e_reason="$(jq -r '.reason // "no reason given"' <<<"$ex" 2>/dev/null || true)"
    # Only items this cycle actually claimed are actionable. The model cannot
    # introduce work of its own, and an item a peer holds is the peer's to
    # answer — acting on either would write state nobody arbitrated.
    claimed_entry="$(jq -c --arg r "$e_repo" --arg i "$e_item" \
      'map(select((.repo // "") == $r and (.item // "") == $i)) | first // empty' \
      <<<"$claimed_json" 2>/dev/null || true)"
    if [[ -z "$claimed_entry" ]]; then
      log_event "warning" "$(jq -nc \
        --arg d "enabler: a verdict for an item this cycle did not claim ($e_repo $e_item) — ignored" \
        '{detail: $d}')"
      continue
    fi
    blocked_ts="$(jq -r '.blocked_ts // ""' <<<"$claimed_entry" 2>/dev/null || true)"
    outcome="$verdict"
    extra='{}'
    case "$verdict" in
      unblocked)
        # The thrash guard (requirement 36b), mechanical for the reason
        # requirement 34d's guard is: "do not do this" is already in the prompt,
        # and the model that would do it anyway is one that has convinced itself.
        # Refusing costs a cycle of waiting on an item that is already waiting;
        # accepting costs a loop in which two models re-specify each other's work
        # and no human is ever asked. The examined event is still written, so the
        # item is not re-examined until the recheck window — by which time
        # `refined_before` is still set and the answer is an escalation.
        if ! e_refusal="$(refinement_second_pass_refused "$claimed_entry" "$ex")"; then
          log_event "warning" "$(jq -nc \
            --arg d "enabler: second refinement of $e_repo $e_item refused — $e_refusal; the item stays blocked" \
            '{detail: $d}')"
          outcome="refinement-refused"
          extra="$(jq -nc --arg c "Whether this item's specification is adequate is escalation_autonomy's call from here; the Enabler has already refined it once." \
            '{unblock_condition: $c}')"
        else
          # The item becomes selectable again next cycle. `by` names the Enabler
          # so a reader can tell this from the Co-Ordinator's own cheap re-checks
          # (requirement 18) without cross-referencing timestamps.
          log_event "unblocked" "$(jq -nc --arg i "$e_item" --arg r "$e_repo" --arg reason "$e_reason" \
            '{item: $i, repo: $r, by: "enabler", reason: $reason}')"
          # Requirement 36b: an unblocked refinement item carries the refinement
          # itself, and this is where it is made durable — as the comment URL a
          # future Co-Ordinator will read in the issue's thread, or as the spec
          # text for the item types that have no thread to read (requirement 3h).
          # An unblock with neither is the failure worth naming: the block clears
          # and the item returns to the pool exactly as under-specified as it was.
          if [[ "$(jq -r '.kind // ""' <<<"$claimed_entry" 2>/dev/null || true)" == "$REFINEMENT_BLOCK_KIND" ]]; then
            e_refined="$(refinement_record_fields "$ex")"
            if [[ -n "$e_refined" ]]; then
              log_event "item-refined" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
                --argjson x "$e_refined" '{repo: $r, item: $i} + $x')"
            else
              log_event "warning" "$(jq -nc \
                --arg d "enabler: unblocked $e_repo $e_item as refined but returned neither a refined_spec nor a comment — nothing was recorded for the next Co-Ordinator to read" \
                '{detail: $d}')"
            fi
            release_refinement_label "$e_item" "$e_repo"
          fi
          # Requirement 32b: the one block the Enabler can clear by act rather
          # than by verdict — a finished pull request that never left draft. It
          # decides; the Script performs the flip, for the same reason the Script
          # and not the Enabler files an escalation issue (requirement 36): one
          # writer of the pipeline's outward acts. The handoff itself is
          # lib/handoff.sh's `handoff_complete_review` — the one gate-and-flip
          # implementation this path and the Reviewer's own handoff above both
          # call, so they cannot drift (requirement 34a).
          e_pr_url="$(jq -r '.pr_url // ""' <<<"$claimed_entry" 2>/dev/null || true)"
          if [[ "$(jq -r '.complete_handoff // false' <<<"$ex" 2>/dev/null || true)" == "true" \
                && -n "$e_pr_url" ]]; then
            # Requirement 31c/32b (agent-ops#440): `complete_handoff` recovers
            # a pull request whose Reviewer ran and left it a draft — never
            # one the Reviewer never reached. An item blocked at the
            # Implementer or the Co-Ordinator has no Reviewer verdict on
            # record at all: nothing has confirmed the diff is even safe to
            # look at, let alone that CI is green, so flipping it to ready
            # would hand a human a pull request no pipeline stage has ever
            # examined (PR #433: the Implementer failed, the Reviewer block
            # never ran, and an Enabler `complete_handoff` flipped it to ready
            # anyway on four preconditions that were all vacuously true).
            # `claimed_entry.stage` (lib/cycle-state.sh's
            # `enabler_eligible_items`) is the block's own record of which
            # stage produced it — `handle_stage_failure`/`log_reviewer_
            # handback` both stamp `"reviewer"` there, whatever the Reviewer's
            # own verdict was, so its presence is exactly "a Reviewer verdict
            # is on record for this pull request".
            e_block_stage="$(jq -r '.stage // ""' <<<"$claimed_entry" 2>/dev/null || true)"
            if [[ "$e_block_stage" != "reviewer" ]]; then
              log_event "warning" "$(jq -nc --arg u "$e_pr_url" --arg s "${e_block_stage:-none}" \
                --arg d "enabler asked for the handoff on $e_pr_url to be completed, but this item's recorded failure never reached the Reviewer stage (stage: ${e_block_stage:-none}) — refusing; a Reviewer must examine this pull request before it can be handed off" \
                '{detail: $d, pr_url: $u}')"
              extra="$(jq -nc '{complete_handoff: "refused-no-reviewer"}')"
            else
              e_default_branch="$(jq -r --arg r "$e_repo" \
                'map(select(.slug == $r)) | .[0].default_branch // "main"' \
                <<<"$ordered_repos_json" 2>/dev/null || true)"
              [[ -n "$e_default_branch" ]] || e_default_branch="main"
              e_review_json="$(handoff_complete_review "$e_pr_url" "$e_default_branch" "$enabler_assignee" "$cycle_started_at")"

              e_gate_word="$(jq -r '.gate.word // ""' <<<"$e_review_json")"
              e_gate_reason="$(jq -r '.gate.reason // ""' <<<"$e_review_json")"
              e_gate_checks_unreadable="$(jq -r '.gate.checks_unreadable // false' <<<"$e_review_json")"
              e_ck_word="$(jq -r '.closing_keyword.word // ""' <<<"$e_review_json")"
              e_ck_reason="$(jq -r '.closing_keyword.reason // ""' <<<"$e_review_json")"
              e_rc_word="$(jq -r '.reconciliation.word // ""' <<<"$e_review_json")"
              e_rc_reason="$(jq -r '.reconciliation.reason // ""' <<<"$e_review_json")"
              e_rc_revert="$(jq -r '.revert // ""' <<<"$e_review_json")"
              e_review_safe="$(jq -r '.safe // false' <<<"$e_review_json")"

              # Same node-health bookkeeping as the Reviewer's own handoff
              # site — TD-PPagop-26081404's streak, via the shared
              # `review_gate_escalate_unreadable_streak` (TD-PPagop-26081603),
              # so a run of consecutive unreadable-checks failures escalates
              # the same way here as it does at the Reviewer's own site,
              # rather than only naming the fault per item.
              e_gate_checks_ok=true
              [[ "$e_gate_checks_unreadable" == "true" ]] && e_gate_checks_ok=false
              log_event "review-gate-checks-read" "$(jq -nc --argjson ok "$e_gate_checks_ok" '{ok: $ok}')"

              if [[ "$e_review_safe" != "true" ]]; then
                if [[ "$e_gate_word" == "dirty" ]]; then
                  e_finding="$e_gate_reason"
                elif [[ "$e_gate_checks_unreadable" == "true" ]]; then
                  e_finding="its required checks could not be confirmed: $e_gate_reason"
                  review_gate_escalate_unreadable_streak >/dev/null
                elif [[ "$e_ck_word" == "dirty" ]]; then
                  e_finding="$e_ck_reason"
                elif [[ "$e_rc_word" == "dirty" ]]; then
                  e_finding="$e_rc_reason"
                else
                  e_finding="it is still a draft after the attempt"
                fi
                log_event "warning" "$(jq -nc --arg u "$e_pr_url" --arg d "$e_finding" \
                  --arg m "enabler asked for the handoff on $e_pr_url to be completed, but it is not safe to hand off: " \
                  '{detail: ($m + $d), pr_url: $u}')"
                # agent-ops#539: the same revert-on-refusal `handoff_complete_review`
                # performs at the Reviewer's own handoff site, reached here too
                # because both share that one function (requirement 34a) — see
                # this file's own comment just above the call. `revert: "failed"`
                # is worth its own warning here for the same reason it is there:
                # this pull request may already have been sitting ready, with
                # its comment unanswered, since the round the Reviewer's block
                # first failed in.
                if [[ "$e_rc_word" == "dirty" && "$e_rc_revert" == "failed" ]]; then
                  log_event "warning" "$(jq -nc --arg u "$e_pr_url" \
                    --arg d "$e_pr_url carries an unreconciled human comment and could not be converted back to draft — it remains ready, and a human could merge it with the comment still unanswered" \
                    '{detail: $d, pr_url: $u}')"
                fi
                e_handoff="failed"
              else
                if [[ "$e_ck_word" == "unknown" ]]; then
                  log_event "warning" "$(jq -nc --arg u "$e_pr_url" --arg d "$e_ck_reason" \
                    '{detail: ("could not confirm " + $u + " carries its closing keyword: " + $d), pr_url: $u}')"
                fi
                if [[ "$e_rc_word" == "unknown" ]]; then
                  log_event "warning" "$(jq -nc --arg u "$e_pr_url" --arg d "$e_rc_reason" \
                    '{detail: ("could not confirm every human comment on " + $u + " since it last left draft is reconciled: " + $d), pr_url: $u}')"
                fi
                if [[ "$e_gate_word" == "unknown" ]]; then
                  log_event "warning" "$(jq -nc --arg u "$e_pr_url" --arg d "$e_gate_reason" \
                    '{detail: ("could not confirm " + $u + " carries no new security-severity code-scanning alert: " + $d), pr_url: $u}')"
                fi

                e_handoff="$(jq -r '.handoff // ""' <<<"$e_review_json")"

                # Requirement 31b on the recovery path too. `already` is the
                # answer for a review round that stalled at the Reviewer and the
                # Enabler has now cleared: the PR never was a draft, so the flip
                # settles nothing and the human is still not being asked. Both
                # handoff paths run both halves, or they drift (requirement 34a).
                e_rereview_state="$(jq -r '.rereview.state // ""' <<<"$e_review_json")"
                e_rereview_who="$(jq -r '.rereview.who // ""' <<<"$e_review_json")"
                if [[ "$e_rereview_state" == "failed" ]]; then
                  log_event "warning" "$(jq -nc --arg u "$e_pr_url" \
                    --arg d "enabler completed the handoff on $e_pr_url, but review could not be re-requested from ${e_rereview_who:-the reviewer} — they will not see it in their review queue" \
                    '{detail: $d, pr_url: $u}')"
                fi

                # Requirement 38, same as the Reviewer's own handoff site
                # above — this path exists precisely so the two cannot drift.
                e_human_reviewer_state="$(jq -r '.human_reviewer.state // ""' <<<"$e_review_json")"
                e_human_reviewer_who="$(jq -r '.human_reviewer.who // ""' <<<"$e_review_json")"
                if [[ "$e_human_reviewer_state" == "failed" || "$e_human_reviewer_state" == "failed-rate-limited" ]]; then
                  # agent-ops#1082, the same shape agent-cycle.sh's own site
                  # carries: `ensure_human_reviewer` distinguishes a rate-limit
                  # refusal, so both shapes are matched — a `failed` arm alone
                  # would drop this warning entirely for exactly the case that
                  # distinction exists to surface.
                  e_human_rate_note=""
                  [[ "$e_human_reviewer_state" == "failed-rate-limited" ]] \
                    && e_human_rate_note=" — GitHub's REST rate limit refused the read"
                  log_event "warning" "$(jq -nc --arg u "$e_pr_url" --arg a "$enabler_assignee" --arg w "$e_human_reviewer_who" \
                    --arg d "enabler completed the handoff on $e_pr_url, but review could not be requested from ${e_human_reviewer_who:-$enabler_assignee} — it will not appear in their review queue$e_human_rate_note" \
                    '{detail: $d, pr_url: $u} + (if $w == "" then {reviewers: [$a]} else {reviewers: ($w | split(","))} end)')"
                fi

                log_event "pr-ready" "$(jq -nc --arg u "$e_pr_url" --arg h "$e_handoff" \
                  --arg rr "$e_rereview_state" --arg w "$e_rereview_who" \
                  --arg hr "$e_human_reviewer_state" --arg ha "$enabler_assignee" \
                  '{pr_url: $u, handoff: "enabler", state: $h}
                   + (if $rr == "" or $rr == "none" then {} else {review_requested: $rr} end)
                   + (if $w == "" then {} else {reviewers: ($w | split(","))} end)
                   + (if $hr == "" or $hr == "skip" then {}
                      else {human_review_requested: $hr, human_reviewer: $ha} end)')"
              fi
              extra="$(jq -nc --arg h "$e_handoff" '{complete_handoff: $h}')"
            fi
          fi
        fi
        ;;
      void)
        # Requirement 9b: "the work is already done" is a void, never an unblock.
        # Requirement 34d, extended by issue #243 from the Co-Ordinator alone to
        # every stage: the Enabler reads the issue and the PR (requirement 35),
        # but reading more does not stop a model citing the wrong artefact
        # inside it — see lib/void-guard.sh's own note on issue #243. `repos`
        # is passed as `[]`: the Enabler gathers no per-cycle candidate list, so
        # `void_guard_reason`'s PR-diff check (Co-Ordinator only) simply has
        # nothing to test against; the citation check needs nothing from it.
        e_void_entry="$(jq -nc --arg r "$e_repo" --arg i "$e_item" --arg reason "$e_reason" \
          --argjson x "$ex" '{repo: $r, item: $i, reason: $reason, evidence: ($x.evidence // "")}')"
        if e_void_refusal="$(void_guard_reason "$e_void_entry" '[]' "$(void_obsolete_ctx_json "$e_repo")")"; then
          # TD-PPagop-26081407: $ex is an agent stage's own parsed verdict
          # (test 1 -- external, can be malformed) and {} reads exactly like
          # "no evidence given" (test 2).
          e_evidence_field="$(jq -c '{evidence: (.evidence // "")}' <<<"$ex" 2>&1)" \
            || { guard_warn "enabler:item-void-evidence" "$e_evidence_field"; e_evidence_field='{}'; }
          log_event "item-void" "$(item_event_fields "enabler" "$e_reason" "$e_repo" "$e_item" \
            "$e_evidence_field")"
          release_refinement_label "$e_item" "$e_repo"
        else
          log_event "warning" "$(jq -nc \
            --arg d "enabler void refused for ${e_repo:-<no repo>} $e_item — $e_void_refusal; recorded blocked instead" \
            '{detail: $d}')"
          log_event "attempt-failed" "$(item_event_fields "enabler" \
            "void refused ($e_void_refusal). The Enabler's stated reason was: $e_reason" "$e_repo" "$e_item" \
            "$(jq -nc --arg c "Establish from the repository itself whether this item describes any remaining work." \
              '{unblock_condition: $c}')")"
          outcome="void-refused"
        fi
        ;;
      still-blocked)
        # Nothing extra to record: the block stands, and the refreshed condition
        # travels on the examined event below, which is what a later engagement
        # and the dashboard read.
        # TD-PPagop-26081407: same rationale as the item-void evidence field
        # above -- $ex is agent-produced (test 1) and {} reads as "no
        # condition given" (test 2).
        extra="$(jq -c '{unblock_condition: (.unblock_condition // "")}' <<<"$ex" 2>&1)" \
          || { guard_warn "enabler:still-blocked-extra" "$extra"; extra='{}'; }

        # The machine `obsolete` alternative's first touch (design doc §5.5,
        # issue #413, WI-10): an Enabler that judges a stalled draft unwanted
        # flags it here rather than voiding it — flagging is not itself a
        # verdict that closes anything, so this never writes `item-void`; a
        # *later*, independent engagement's own void is what a corroborated
        # flag can eventually support, via lib/void-guard.sh's
        # `void_draft_obsolete_flag_reason`. `e_pr_url` is the item's own
        # `pr_url` (from `claimed_entry`, the same field the `unblocked`/
        # `complete_handoff` path above reads); the flag carries no weight
        # without one, since there is then no pull request to flag.
        if [[ "$(jq -r '.flag_obsolete // false' <<<"$ex" 2>/dev/null || true)" == "true" ]]; then
          e_pr_url="$(jq -r '.pr_url // ""' <<<"$claimed_entry" 2>/dev/null || true)"
          e_flag_evidence_field="$(jq -c '{evidence: (.evidence // null)}' <<<"$ex" 2>&1)" \
            || { guard_warn "enabler:flag-obsolete-evidence" "$e_flag_evidence_field"; e_flag_evidence_field='{}'; }
          e_flag_resolvable="$(void_entry_resolvable_evidence "$e_flag_evidence_field")"
          e_flag_pr_num="${e_pr_url##*/}"
          if [[ -z "$e_pr_url" ]]; then
            log_event "warning" "$(jq -nc \
              --arg d "enabler set flag_obsolete for ${e_repo:-<no repo>} $e_item, but the item carries no pr_url to flag — ignored" \
              '{detail: $d}')"
          elif ! [[ "$e_flag_pr_num" =~ ^[0-9]+$ ]]; then
            log_event "warning" "$(jq -nc --arg u "$e_pr_url" \
              --arg d "enabler set flag_obsolete for $e_pr_url, but no pull request number could be read from it — ignored" \
              '{detail: $d, pr_url: $u}')"
          elif [[ -z "$e_flag_resolvable" ]]; then
            log_event "warning" "$(jq -nc --arg u "$e_pr_url" \
              --arg d "enabler set flag_obsolete for $e_pr_url, but its evidence is not the structured {ref,path,expect,pattern} shape — ignored" \
              '{detail: $d, pr_url: $u}')"
          elif ! e_flag_resolve_reason="$(void_evidence_resolves "$e_flag_resolvable" "$e_repo")"; then
            log_event "warning" "$(jq -nc --arg u "$e_pr_url" --arg r "$e_flag_resolve_reason" \
              --arg d "enabler set flag_obsolete for $e_pr_url, but its evidence did not resolve: " \
              '{detail: ($d + $r), pr_url: $u}')"
          else
            log_event "draft-obsolete-flagged" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
              --argjson pr "$e_flag_pr_num" --argjson ev "$(jq -c '.evidence' <<<"$e_flag_evidence_field")" \
              '{repo: $r, item: $i, pr: $pr, evidence: $ev}')"
          fi
        fi
        ;;
      escalate)
        issue_title="$(jq -r '.issue.title // ""' <<<"$ex" 2>/dev/null || true)"
        issue_body_file="$cycle_dir/enabler-issue-$j.md"
        jq -r '.issue.body // ""' <<<"$ex" > "$issue_body_file" 2>/dev/null || true
        e_ea_level="$(escalation_autonomy_configured_level "$DEFAULTED_CONFIG" "$e_repo")"
        e_kind="$(jq -r '.kind // ""' <<<"$claimed_entry" 2>/dev/null || true)"
        e_refined_before_present="$(jq -r 'if (.refined_before // null) == null then "" else "x" end' \
          <<<"$claimed_entry" 2>/dev/null || true)"

        # D18 (agent-ops#627): `escalation_autonomy: "adjudicate-first"` runs
        # one bounded adjudication pass, over this item alone, before a
        # refinement-disagreement escalation is actually filed. Only a
        # refinement disagreement qualifies — `refinement_is_disagreement`,
        # the same shape `refinement_second_pass_refused` refuses a second
        # `unblocked` verdict against — and only once a title/body actually
        # exist to adjudicate; an escalate verdict that already carried
        # nothing filable is unaffected by the setting. `decide-tactical`
        # (agent-ops#936) includes this rung — its own pass below is a strict
        # superset of what this one judges — so this branch runs only at
        # `adjudicate-first` itself; a repository dialled past it never runs
        # both passes over the same verdict.
        e_adjudicated=0
        e_adjudication=""
        if [[ -n "$issue_title" && -s "$issue_body_file" ]] \
             && [[ "$e_ea_level" == "adjudicate-first" ]] \
             && refinement_is_disagreement "$claimed_entry" \
             && escalation_autonomy_pass_available "$e_repo" "$e_item" "$claimed_entry"; then
          e_adjudication="$(run_enabler_adjudication "$e_repo" "$e_item" "$claimed_entry" "$ex" "$cycle_dir" "$j")"
          e_adj_verdict="$(jq -r '.verdict // "inadequate"' <<<"$e_adjudication" 2>/dev/null || printf 'inadequate')"
          e_adj_evidence="$(jq -r '.evidence // ""' <<<"$e_adjudication" 2>/dev/null || true)"
          log_event "enabler-adjudication" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
            --arg v "$e_adj_verdict" --arg ev "$e_adj_evidence" \
            '{repo: $r, item: $i, verdict: $v, evidence: $ev, adjudication: true}')"
          if [[ "$e_adj_verdict" == "adequate" ]]; then
            e_adjudicated=1
            # Recorded exactly as an ordinary unblocked refinement
            # (requirement 36b): the adjudication confirmed the *existing*
            # refinement rather than writing a new one, so item-refined
            # carries refined_before's own spec/comment_url, unchanged.
            #
            # The reason is the adjudication's own, never `$e_reason` — that
            # is the *escalate* verdict's rationale for why the item was
            # escalating, and an `unblocked` event carrying it would read, to
            # whoever later asks why this item came back, as the pipeline
            # unblocking an item on the strength of an argument that it could
            # not proceed.
            log_event "unblocked" "$(jq -nc --arg i "$e_item" --arg r "$e_repo" \
              --arg reason "the existing refinement was adjudicated adequate${e_adj_evidence:+: $e_adj_evidence}" \
              '{item: $i, repo: $r, by: "enabler", reason: $reason}')"
            e_refined_adj="$(jq -c '(.refined_before // {}) | {spec: (.spec // ""), comment_url: (.comment_url // "")}
                                     | with_entries(select(.value != ""))' \
                                <<<"$claimed_entry" 2>/dev/null || printf '{}')"
            if [[ "$e_refined_adj" != "{}" ]]; then
              # `unchanged: true` (agent-ops#1049): this re-records the
              # *existing* spec verbatim rather than a fresh one, so it must
              # not read, to DECISIONS_MAP_JQ, as a refinement that carried a
              # decision forward — this path never records a decision at all,
              # but the marker is applied on the same terms the decide-
              # tactical path below applies it, since both re-record the same
              # shape of unchanged item-refined.
              log_event "item-refined" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
                --argjson x "$e_refined_adj" '{repo: $r, item: $i, unchanged: true} + $x')"
            else
              log_event "warning" "$(jq -nc \
                --arg d "enabler: adjudication confirmed $e_repo $e_item's existing refinement as adequate, but refined_before carried neither a spec nor a comment_url — nothing was recorded for the next Co-Ordinator to read" \
                '{detail: $d}')"
            fi
            release_refinement_label "$e_item" "$e_repo"
            outcome="unblocked"
          fi
        fi

        # D18 (agent-ops#936): `escalation_autonomy: "decide-tactical"` runs
        # one bounded decide pass over *any* escalate verdict — refinement
        # disagreement or not — before the escalation is filed, per-reason
        # bounded and capped at `escalation_adjudication_max_passes`.
        e_decided=0
        e_decision=""
        e_dec_verdict=""
        if (( ! e_adjudicated )) \
             && [[ -n "$issue_title" && -s "$issue_body_file" ]] \
             && [[ "$e_ea_level" == "decide-tactical" ]] \
             && escalation_autonomy_decide_pass_available "$e_repo" "$e_item" "$claimed_entry" \
                  "$escalation_adjudication_max_passes"; then
          e_decision="$(run_enabler_decide "$e_repo" "$e_item" "$claimed_entry" "$ex" "$cycle_dir" "$j")"
          e_dec_verdict="$(jq -r '.verdict // "escalate"' <<<"$e_decision" 2>/dev/null || printf 'escalate')"
          e_dec_evidence="$(jq -r '.evidence // ""' <<<"$e_decision" 2>/dev/null || true)"
          e_dec_reason_key="$(escalation_autonomy_decide_reason_key "$claimed_entry")"
          log_event "enabler-adjudication" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
            --arg v "$e_dec_verdict" --arg ev "$e_dec_evidence" --arg rk "$e_dec_reason_key" \
            '{repo: $r, item: $i, verdict: $v, evidence: $ev, adjudication: true,
              pass: "decide-tactical", reason_key: $rk}')"

          if [[ "$e_dec_verdict" == "settle" || "$e_dec_verdict" == "decide" ]]; then
            e_decided=1
            if [[ "$e_dec_verdict" == "decide" ]]; then
              e_dec_decision_text="$(jq -r '.decision // ""' <<<"$e_decision" 2>/dev/null || true)"
              e_dec_rationale="$(jq -r '.rationale // ""' <<<"$e_decision" 2>/dev/null || true)"
              e_dec_options="$(jq -r '.options_considered // ""' <<<"$e_decision" 2>/dev/null || true)"
              e_dec_comment_url=""
              if [[ "$e_item" =~ ^[0-9]+$ ]]; then
                e_dec_comment_url="$(enabler_decision_comment "$e_repo" "$e_item" \
                  "$e_dec_decision_text" "$e_dec_rationale" "$e_dec_options" "$e_refined_before_present")"
              fi
              log_event "decision-taken" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
                --arg d "$e_dec_decision_text" --arg ra "$e_dec_rationale" --arg op "$e_dec_options" \
                --arg cu "$e_dec_comment_url" --arg m "${enabler_model_critical:-$enabler_model}" \
                --arg rk "$e_dec_reason_key" \
                '{repo: $r, item: $i, decision: $d, rationale: $ra, options_considered: $op}
                 + (if $cu == "" then {} else {comment_url: $cu} end)
                 + {model: $m, reason_key: $rk}')"
              log_event "unblocked" "$(jq -nc --arg i "$e_item" --arg r "$e_repo" \
                --arg reason "decided: $e_dec_decision_text" \
                '{item: $i, repo: $r, by: "enabler", reason: $reason}')"
            else
              log_event "unblocked" "$(jq -nc --arg i "$e_item" --arg r "$e_repo" \
                --arg reason "settled${e_dec_evidence:+: $e_dec_evidence}" \
                '{item: $i, repo: $r, by: "enabler", reason: $reason}')"
            fi

            # Same carrier as the adjudicate-first `adequate` path above: a
            # decide-tactical pass never writes a specification of its own
            # (`prompts/enabler-decide.md`), so the only spec worth
            # re-recording is one that already existed before this pass ran.
            # The label release below is deliberately *not* held to that same
            # condition: it is a projection of the open block (requirement
            # 34e), and this branch has just cleared the block whether or not
            # a refinement was ever written — a `needs-refinement` item the
            # Enabler escalated before refining it at all
            # (`prompts/enabler-decide.md`'s own "never been refined" shape)
            # would otherwise be unblocked with the label still standing,
            # waiting on requirement 39f's stale sweep to notice. Every
            # neighbouring path releases it on `kind` alone — the ordinary
            # `unblocked` verdict, `void`, and `adjudicate-first`'s own
            # `adequate` — and so does this one.
            if [[ "$e_kind" == "$REFINEMENT_BLOCK_KIND" ]]; then
              if [[ -n "$e_refined_before_present" ]]; then
                e_refined_dec="$(jq -c '(.refined_before // {}) | {spec: (.spec // ""), comment_url: (.comment_url // "")}
                                         | with_entries(select(.value != ""))' \
                                    <<<"$claimed_entry" 2>/dev/null || printf '{}')"
                if [[ "$e_refined_dec" != "{}" ]]; then
                  # `unchanged: true` (agent-ops#1049): for the `decide`
                  # verdict on a non-issue item this re-record is the *only*
                  # item-refined event this pass writes, and it always
                  # postdates the decision-taken event just logged above — so
                  # without this marker, DECISIONS_MAP_JQ (lib/cycle-state.sh)
                  # reads it as "a refinement already carried the decision
                  # forward" and drops the decision from decisions_map before
                  # any Refiner engagement ever reads it, even though the spec
                  # re-recorded here is refined_before's own, unamended by the
                  # decision. refiner_candidate_items (lib/refinement.sh)
                  # reads the marker's absence the same way `triage_only`
                  # reads an unbanded issue: a decision still pending against
                  # this item keeps it a candidate despite refinements_map
                  # showing it refined, until an actual Refiner pass writes a
                  # fresh item-refined (no marker) that supersedes it for
                  # real.
                  log_event "item-refined" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
                    --argjson x "$e_refined_dec" '{repo: $r, item: $i, unchanged: true} + $x')"
                fi
              fi
              release_refinement_label "$e_item" "$e_repo"
            fi
            outcome="unblocked"
          fi
        fi

        if (( ! e_adjudicated )) && (( ! e_decided )); then
          if [[ -n "$e_adjudication" ]]; then
            # agent-ops#681: the adjudication pass ran and did not settle the
            # disagreement (an `inadequate` verdict, or a stage failure whose
            # own evidence says why no adjudicator answer exists) — fold that
            # evidence into the escalation body, exactly as the `adequate`
            # branch above threads it into the `unblocked` event's own
            # reason, so the human starts from why an adjudication answer is
            # missing rather than only the pre-adjudication verdict.
            printf '\n\n## Adjudication attempted\n\nAdjudication was attempted and returned: %s\n' \
              "${e_adj_evidence:-no evidence given}" >> "$issue_body_file"
          fi
          if [[ -n "$e_decision" ]]; then
            # Same rationale, for the decide-tactical pass's own `escalate`
            # verdict (or an unreadable one): the human starts from why the
            # pipeline could not decide it, not only from the pre-pass verdict.
            printf '\n\n## Adjudication attempted\n\nA decide-tactical pass was attempted and returned: %s\n' \
              "${e_dec_evidence:-no evidence given}" >> "$issue_body_file"
          fi
          if [[ -z "$issue_title" || ! -s "$issue_body_file" ]]; then
            log_event "warning" "$(jq -nc \
              --arg d "enabler: escalate verdict for $e_repo $e_item carried no issue title or body — nothing filed" \
              '{detail: $d}')"
            outcome="escalation-failed"
          elif created="$(create_escalation_issue "$e_repo" "$e_item" "$enabler_escalation_label" \
                            "$issue_title" "$issue_body_file")" && [[ -n "$created" ]]; then
            IFS=$'\t' read -r number url <<<"$created"
            log_event "escalated" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
              --argjson n "$number" --arg u "$url" --arg b "$blocked_ts" \
              '{repo: $r, item: $i, issue_number: $n, issue_url: $u, blocked_ts: $b}')"
          else
            # The examined event records `escalation-failed`, which requirement 35a
            # deliberately does not count as an examination: the item stays at the
            # threshold and is retried once its claim expires.
            log_event "warning" "$(jq -nc \
              --arg d "enabler: could not file the escalation issue for $e_repo $e_item (see enabler-issue.err) — retried after the claim TTL" \
              '{detail: $d}')"
            outcome="escalation-failed"
          fi
        fi

        # agent-ops#815: complete or correct the Blocked-by claim on the work
        # item's own thread now that this engagement — unlike the Enabler's
        # own turn, which ended before any of the above ran — knows what
        # actually happened. Scoped exactly to what prompts/enabler.md
        # documents a linking comment for: a needs-refinement block whose
        # item is itself a bare GitHub issue number. `outcome` still reads
        # "escalate" (its initial value, never reassigned) on the one path
        # that filed successfully, so it is what tells that case apart from
        # `escalation-failed` here. A `decide` verdict is not corrected here
        # at all: `enabler_decision_comment` above already posted its own
        # comment on this same thread, and it already says plainly that no
        # escalation was filed — a second, near-identical correcting comment
        # would only restate it.
        if [[ "$e_item" =~ ^[0-9]+$ ]] && [[ "$e_kind" == "$REFINEMENT_BLOCK_KIND" ]]; then
          if (( e_adjudicated )); then
            escalation_thread_reconcile "$e_repo" "$e_item" "adjudicated-adequate" "" ""
          elif (( e_decided )) && [[ "$e_dec_verdict" == "settle" ]]; then
            escalation_thread_reconcile "$e_repo" "$e_item" "decide-settled" "" ""
          elif (( e_decided )); then
            : # decide: enabler_decision_comment already posted the thread's own comment
          elif [[ "$outcome" == "escalation-failed" ]]; then
            escalation_thread_reconcile "$e_repo" "$e_item" "escalation-failed" "" ""
          else
            escalation_thread_reconcile "$e_repo" "$e_item" "escalated" "$number" "$url"
          fi
        fi
        ;;
      *)
        log_event "warning" "$(jq -nc \
          --arg d "enabler: unrecognised verdict '$verdict' for $e_repo $e_item — recorded, acted on in no way" \
          '{detail: $d}')"
        outcome="unknown-verdict"
        ;;
    esac

    # file_debt/file_issue (agent-ops#631): orthogonal to `verdict` -- any of
    # the four arms above may carry either, since deferred work the Enabler
    # notices while examining an item is independent of what it decided
    # about the item itself. The Enabler never writes to GitHub or a branch
    # (prompts/enabler.md, "What you must never do"), so lib/tech-debt-file.sh
    # is what actually files it, here, under the ordinary pipeline login --
    # the Enabler carries no App identity of its own the way the Approver
    # does, so every call omits TOKEN.
    e_file_debt="$(jq -c '.file_debt // empty' <<<"$ex" 2>/dev/null || true)"
    if [[ -n "$e_file_debt" && "$e_file_debt" != "null" ]]; then
      fd_title="$(jq -r '.title // ""' <<<"$e_file_debt" 2>/dev/null || true)"
      fd_body="$(jq -r '.body // ""' <<<"$e_file_debt" 2>/dev/null || true)"
      # default_fix/owner_decision (agent-ops#938): the option this
      # engagement would take, or the owner-only clause it names instead —
      # see prompts/enabler.md's "file_debt/file_issue" for what each means
      # and requirement 36c for what the Script does with them.
      fd_default_fix="$(jq -r '.default_fix // ""' <<<"$e_file_debt" 2>/dev/null || true)"
      fd_owner_decision="$(jq -r \
        'if (.owner_decision // false) == true then "true" else "false" end' \
        <<<"$e_file_debt" 2>/dev/null || true)"
      [[ -n "$fd_owner_decision" ]] || fd_owner_decision="false"
      # The fleet's configured `pr_label` (agent-ops TD-PPagop-26082426): this
      # call site does not otherwise have it in hand, so it is read from
      # `DEFAULTED_CONFIG` here and threaded through to techdebt_file_debt,
      # which would otherwise open its filing pull request unlabelled and
      # invisible to every gatherer that filters on it.
      fd_pr_label="$(jq -r '.pr_label // empty' <<<"$DEFAULTED_CONFIG" 2>/dev/null || true)"
      [[ -n "$fd_pr_label" ]] || fd_pr_label="autonomous-agent"
      if [[ -z "$fd_title" || -z "$fd_body" ]]; then
        log_event "warning" "$(jq -nc \
          --arg d "enabler set file_debt for $e_repo $e_item, but it carries no title or body — ignored" \
          '{detail: $d}')"
      else
        # A verdict naming neither is malformed, not refused: it is filed
        # anyway with "## Default: not stated" (techdebt_default_section)
        # rather than lost, and this warning is what lets the refusal be
        # counted so the filing prompts can be tuned.
        if [[ -z "$fd_default_fix" && "$fd_owner_decision" != "true" ]]; then
          log_event "warning" "$(jq -nc \
            --arg d "enabler set file_debt for $e_repo $e_item with no default_fix and no owner_decision — filed with '## Default: not stated'" \
            '{detail: $d}')"
        fi
        if fd_result="$(techdebt_file_debt "$e_repo" "$fd_title" "$fd_body" \
               "during an Enabler engagement on $e_item (cycle $cycle_id)" "" "" "$fd_pr_label" \
               "$fd_default_fix" "$fd_owner_decision")" \
               && [[ -n "$fd_result" ]]; then
          IFS=$'\t' read -r fd_id fd_pr_url <<<"$fd_result"
          log_event "tech-debt-filed" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
            --arg id "$fd_id" --arg u "$fd_pr_url" \
            '{repo: $r, item: $i, by: "enabler", id: $id, pr_url: $u}')"
        else
          log_event "warning" "$(jq -nc \
            --arg d "enabler: could not file the tech-debt record for $e_repo $e_item (see tech-debt-file.err)" \
            '{detail: $d}')"
        fi
      fi
    fi

    e_file_issue="$(jq -c '.file_issue // empty' <<<"$ex" 2>/dev/null || true)"
    if [[ -n "$e_file_issue" && "$e_file_issue" != "null" ]]; then
      fi_title="$(jq -r '.title // ""' <<<"$e_file_issue" 2>/dev/null || true)"
      fi_body="$(jq -r '.body // ""' <<<"$e_file_issue" 2>/dev/null || true)"
      fi_default_fix="$(jq -r '.default_fix // ""' <<<"$e_file_issue" 2>/dev/null || true)"
      fi_owner_decision="$(jq -r \
        'if (.owner_decision // false) == true then "true" else "false" end' \
        <<<"$e_file_issue" 2>/dev/null || true)"
      [[ -n "$fi_owner_decision" ]] || fi_owner_decision="false"
      if [[ -z "$fi_title" || -z "$fi_body" ]]; then
        log_event "warning" "$(jq -nc \
          --arg d "enabler set file_issue for $e_repo $e_item, but it carries no title or body — ignored" \
          '{detail: $d}')"
      else
        if [[ -z "$fi_default_fix" && "$fi_owner_decision" != "true" ]]; then
          log_event "warning" "$(jq -nc \
            --arg d "enabler set file_issue for $e_repo $e_item with no default_fix and no owner_decision — filed with '## Default: not stated'" \
            '{detail: $d}')"
        fi
        # The item ref is appended, not merely hoped for in the model's own
        # prose, because techdebt_file_issue's dedup guard searches the
        # issue body for exactly this string on every later call.
        fi_body_file="$cycle_dir/enabler-file-issue-$j.md"
        # shellcheck disable=SC2016 # the backtick around %s is literal Markdown, not code
        printf '%s\n\n---\nNoticed by the autonomous pipeline while examining `%s` in %s.\n' \
          "$fi_body" "$e_item" "$e_repo" > "$fi_body_file"
        if fi_result="$(techdebt_file_issue "$e_repo" "$e_item" "$fi_title" "$fi_body_file" "" \
               "$fi_default_fix" "$fi_owner_decision")" \
             && [[ -n "$fi_result" ]]; then
          IFS=$'\t' read -r fi_number fi_url <<<"$fi_result"
          log_event "issue-filed" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
            --argjson n "$fi_number" --arg u "$fi_url" \
            '{repo: $r, item: $i, by: "enabler", issue_number: $n, issue_url: $u}')"
        else
          log_event "warning" "$(jq -nc \
            --arg d "enabler: could not file the issue for $e_repo $e_item (see tech-debt-file.err)" \
            '{detail: $d}')"
        fi
      fi
    fi

    # Written for every verdict, including the ones that changed nothing: this
    # marker is what stops the same item being re-examined next cycle, and what
    # the recheck window is measured from (requirement 35a).
    log_event "enabler-examined" "$(jq -nc --arg r "$e_repo" --arg i "$e_item" \
      --arg b "$blocked_ts" --arg o "$outcome" --arg d "$e_reason" --argjson x "$extra" \
      '{repo: $r, item: $i, blocked_ts: $b, outcome: $o, detail: $d} + $x')"
  done

  # A claimed item the model never mentioned keeps its claim and stays blocked,
  # so gc is what eventually retries it. Named in a warning rather than dropped
  # silently: a stage that routinely omits items is a prompt problem, and the log
  # is the only place that would ever become visible.
  while IFS= read -r missing; do
    [[ -n "$missing" ]] || continue
    log_event "warning" "$(jq -nc \
      --arg d "enabler: no verdict for claimed item $missing — left blocked until the claim TTL lets a later cycle retry" \
      '{detail: $d}')"
  done < <(jq -r --argjson p "$parsed" '
      (($p.examined // []) | map(((.repo // "") + " " + (.item // "")))) as $seen
      | .[] | ((.repo // "") + " " + (.item // ""))
      | select(. as $k | $seen | index($k) | not)' <<<"$claimed_json" 2>/dev/null || true)
  return 0
}
