#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/decision-veto.sh — the decision-veto sweep (agent-ops#937): find a
# `pw::decision` decision-log issue a human reopened and act on it.
#
# `decide-tactical` (agent-ops#936) lets the pipeline take a tactical decision
# on its own authority rather than paging a human; `lib/enabler.sh`'s `decide`
# verdict files that decision's own durable record as a closed `pw::decision`
# issue (`create_decision_log_issue`) — a log, not an ask. Reopening it is the
# veto: the D18 pattern (a log a human can scan, a lever they can pull)
# applied to decisions the way requirement 36a already applies it to
# escalations. `scripts/sweep-decision-vetoes.sh` does the GitHub-facing half
# of finding and acting on one; this file is the wiring that turns its stdout
# into fleet-log events and, for a non-terminal item, a real needs-refinement
# block — the one piece a standalone script cannot do itself, since
# `record_needs_refinement_block` (lib/candidate-select.sh) reads and writes
# this cycle's own globals (`blocked_json`, `needs_refinement_label`, …).
#
# Deliberately **not** part of `run_standdown_checks` (lib/standdown.sh),
# despite being a fleet-wide, `--dry-run`-skipped, per-cycle sweep exactly like
# every one of that function's own 2.1a–2.1g sections: that function is called
# before `compute_skip_lists` (agent-cycle.sh) sets `blocked_json`, and
# `record_needs_refinement_block`'s own already-blocked dedup check needs it
# current. `run_decision_veto_sweep` is called separately, after
# `compute_band_eligibility`'s own extracts are settled, so every global this
# file's one function touches already exists.
#
# The re-block this function records for a non-terminal veto also registers
# the still-open log issue as that block's own escalation (agent-ops#937's
# third "Done when" bullet, agent-ops#1198): an `escalated` event naming the
# same `issue_number`/`issue_url`, marked `decision: true`. `ENABLER_ELIGIBLE_JQ`
# (lib/cycle-state.sh) reads that event exactly the way it reads any ordinary
# Enabler escalation — while the log issue stays open, `$issue_state` reads
# `open` and the item is not eligible at all, a mechanical hold no
# `decide-tactical` pass can talk its way past, since the item never reaches
# the Enabler to be re-decided while the veto stands; once the owner comments
# their own decision and re-closes the log issue, the very same `issue-closed`
# branch that answers an ordinary closed escalation fires for this one too,
# with no extra coordinator-cycle wait. Without this registration the veto's
# own re-block would age out through the ordinary threshold regardless of
# whether the log issue was ever closed, and nothing would have stopped a
# later `decide-tactical` pass from silently re-deciding over the still-open
# veto.
#
# The registration is not conditioned on `record_needs_refinement_block`
# actually recording a *fresh* block (review round 2): that call refuses —
# and returns 1 — for an item this cycle's own `blocked_json` already shows
# blocked, the ordinary case being an Implementer's own needs-refinement
# bounce landing between the decision and the owner's reopen, which is
# exactly the situation most likely to prompt a veto. Registering the
# escalation only on a successful *fresh* record would leave that real,
# common case with no registration at all — the existing block ages out on
# its own unrelated threshold, oblivious to the veto standing over it. The
# escalated event is logged whenever this cycle's own `blocked_json` already
# carried the item *or* the fresh record succeeds — the two ways a live
# block for this item can exist the moment the veto is discovered — so it
# always has a block to attach to.

# run_decision_veto_sweep
# Called once, after `compute_band_eligibility`/`compute_enabler_eligible_set`/
# `compute_refiner_candidates` (agent-cycle.sh) have run. Reads
# `decision_vetoes_processed_items` off `union_log` once, fleet-wide, then
# sweeps every configured repository regardless of `--repo` — the same
# breadth every sweep in lib/standdown.sh uses, since a veto on a repository
# this cycle is not otherwise touching still needs to reach a human. Skipped
# on `--dry-run`: the sweep comments, re-blocks, flips pull requests to draft,
# and files issues.
run_decision_veto_sweep() {
  (( DRY_RUN )) && return 0

  local processed_json sweep_slug slug_processed_json sweep_action action
  local veto_repo="" veto_item="" veto_issue_number="" veto_issue_url=""
  local na_repo="" na_item="" na_already_blocked=0 na_recorded=0
  processed_json="$(decision_vetoes_processed_items "$union_log")"

  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    slug_processed_json="$(jq -c --arg r "$sweep_slug" \
      '[.[] | select(.repo == $r)]' <<<"$processed_json" 2>/dev/null || printf '[]')"
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      action="$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)"
      case "$action" in
        vetoed)
          log_event "decision-vetoed" "$(jq -c 'del(.action)' <<<"$sweep_action" 2>/dev/null || printf '{}')"
          veto_repo="$(jq -r '.repo // ""' <<<"$sweep_action" 2>/dev/null || true)"
          veto_item="$(jq -r '.item // ""' <<<"$sweep_action" 2>/dev/null || true)"
          veto_issue_number="$(jq -r '.issue_number // ""' <<<"$sweep_action" 2>/dev/null || true)"
          veto_issue_url="$(jq -r '.issue_url // ""' <<<"$sweep_action" 2>/dev/null || true)"
          ;;
        needs-refinement)
          na_repo="$(jq -r '.repo // ""' <<<"$sweep_action" 2>/dev/null || true)"
          na_item="$(jq -r '.item // ""' <<<"$sweep_action" 2>/dev/null || true)"
          na_already_blocked=0
          if jq -e --arg r "$na_repo" --arg i "$na_item" \
               'any(.[]?; (.repo // "") == $r and ((.item // "") | tostring) == $i)' \
               <<<"${blocked_json:-[]}" >/dev/null 2>&1; then
            na_already_blocked=1
          fi
          na_recorded=0
          record_needs_refinement_block "$(jq -c 'del(.action)' <<<"$sweep_action" 2>/dev/null || printf '{}')" \
            "script" && na_recorded=1
          if (( na_recorded || na_already_blocked )) \
             && [[ -n "$veto_issue_number" ]] \
             && [[ "$na_repo" == "$veto_repo" ]] \
             && [[ "$na_item" == "$veto_item" ]]; then
            log_event "escalated" "$(jq -nc --arg r "$veto_repo" --arg i "$veto_item" \
              --argjson n "$veto_issue_number" --arg u "$veto_issue_url" \
              '{repo: $r, item: $i, issue_number: $n, issue_url: $u, decision: true}')"
          fi
          ;;
        comment-posted|pr-flipped-to-draft|revisit-filed)
          : # informational only — the veto, the re-block and its escalation
            # registration are what future cycles need on the log; these
            # three are already visible on GitHub itself (the comment, the
            # draft flip, the filed issue).
          ;;
        warning)
          log_event "warning" "$(jq -c --arg r "$sweep_slug" \
            '{detail: ("decision-veto sweep (" + $r + "): "
                       + ((.detail // "") | if . == "" then (del(.action) | tostring) else . end))}' \
            <<<"$sweep_action" 2>/dev/null || printf '{}')"
          ;;
        deferred) ;; # nothing to record — a future cycle picks up where this one capped out
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-decision-vetoes.sh" "$sweep_slug" "$node_name" "$cycle_id" \
               <<<"$slug_processed_json" 2>>"$cycle_dir/decision-veto-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)

  return 0
}
