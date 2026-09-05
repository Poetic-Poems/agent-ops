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
          ;;
        needs-refinement)
          record_needs_refinement_block "$(jq -c 'del(.action)' <<<"$sweep_action" 2>/dev/null || printf '{}')" \
            "script"
          ;;
        comment-posted|pr-flipped-to-draft|revisit-filed)
          : # informational only — the veto and the re-block are what future
            # cycles need on the log; these three are already visible on
            # GitHub itself (the comment, the draft flip, the filed issue).
          ;;
        warning)
          log_event "warning" "$(jq -c --arg r "$sweep_slug" \
            '{detail: ("decision-veto sweep (" + $r + "): " + (del(.action) | tostring))}' \
            <<<"$sweep_action" 2>/dev/null || printf '{}')"
          ;;
        deferred) ;; # nothing to record — a future cycle picks up where this one capped out
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-decision-vetoes.sh" "$sweep_slug" "$node_name" "$cycle_id" \
               <<<"$slug_processed_json" 2>>"$cycle_dir/decision-veto-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)

  return 0
}
