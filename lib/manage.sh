#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/manage.sh — the management commands (`--status`, `--disable`,
# `--enable`, `--clear-limit`, `--kill-merge-autonomy`, …): everything
# `agent-cycle.sh` does *instead of* running a cycle.
#
# Split out of agent-cycle.sh (#771). The seam is the sharpest one left in
# that file: these run before the lock and before any `gh` call, share none
# of the cycle's own phases, and every branch of them ends the process — so
# nothing below the call site can be reached from here, and nothing here is
# reachable from a cycle that runs. What is left in the spine is the one
# `run_manage_command` call, in the place the block occupied.
#
# `--status` must stay usable — and instant — while a cycle holds the lock,
# since "is one running right now?" is the question it is most often asked,
# and the switch's transitions are logged like any other state change: an
# operator finding cycles stopped is owed the same evidence trail as one
# finding them failing, and `disabled`/`enabled` events are what let the
# dashboard say why.
#
# Sourced by agent-cycle.sh only. Reads the cycle's own globals
# (`MANAGE_ACTION`, `SCRIPT_DIR`, `state_dir`, `state_repo`, `workspace_root`,
# `lock_file`, `review_lock_file`, `disable_default_ttl_hours`, `DISABLE_FOR`,
# `DISABLE_UNTIL`, `DISABLE_REASON`, `THIS_NODE`, …) directly, and — like
# `run_standdown_checks` (lib/standdown.sh) — deliberately declares nothing
# `local`, so the call is indistinguishable, to the rest of the cycle, from
# the inline block it replaces. `exit` inside it ends the process exactly as
# it did inline: nothing here runs inside a subshell.
refresh_dashboard() {
  if [[ -x "$SCRIPT_DIR/scripts/publish-dashboard.sh" ]]; then
    timeout 120 "$SCRIPT_DIR/scripts/publish-dashboard.sh" >/dev/null 2>&1 || true
  fi
}

# The usage-limit stand-down in force right now (requirement 2.1), as its
# governing record, or empty when there is none. The management commands run
# long before the cycle's union snapshot exists, so they build their own.
current_limit_record() {
  local union
  union="$(fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl \
    | limit_union_record)"
  limit_later_record "$union" "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)"
}

# The `--status` line for that stand-down. Reported alongside the switch
# because they are two answers to one question — "why is nothing happening?"
# — and a status that knew only about the switch is what let a stale limit
# cooldown sit unexplained for a day.
limit_status_report() {
  local rec resume_at resume_epoch rec_class
  rec="$(current_limit_record)"
  resume_at="$(jq -r '.resume_at // empty' <<<"${rec:-{\}}" 2>/dev/null || true)"
  # TD-PPagop-26081407: `rec` is fleet state read off disk/across nodes by
  # current_limit_record above (test 1 — a peer's flag file or log line can be
  # mid-write); epoch 0 reads as "already expired" (test 2 — indistinguishable
  # from a stand-down that genuinely lapsed), which would silently let the
  # fleet ignore an active cooldown.
  if [[ -n "$resume_at" ]]; then
    resume_epoch="$(date -d "$resume_at" +%s 2>&1)" \
      || { guard_warn "limit_status_report:resume_epoch" "$resume_epoch"; resume_epoch=0; }
  else
    resume_epoch=0
  fi
  if [[ -z "$resume_at" ]] || (( resume_epoch <= $(date +%s) )); then
    printf 'limit:    none in force\n'
    return 0
  fi
  # Same site class as above: `rec` can fail to parse, and "other" is exactly
  # the class a well-formed-but-unset record also reports (test 2).
  rec_class="$(jq -r '.class // "other"' <<<"$rec" 2>&1)" \
    || { guard_warn "limit_status_report:rec_class" "$rec_class"; rec_class=other; }
  printf 'limit:    STANDING DOWN — %s\n' \
    "$(limit_describe "$resume_at" "$rec_class" "$(limit_reset_known "$rec")")"
  return 0
}

# The fleet line of `--status` (issue #379): `toggle_status_report` above
# already covers the node-scoped switch (`switch:`/`record:`), so this adds
# only the fleet one and, where both are in play, says plainly what each of
# --enable and --enable --this-node would leave — the question an operator
# who finds a node down for more than one reason actually has.
#
# The local record's `scope` (requirement 2.3) is what makes that answer
# truthful rather than merely confident. A fleet-wide --disable writes both
# levels, so the node that issued one has a local record it never asked for;
# calling that "its own node-scoped disable" describes a second decision that
# was never taken, and sends the operator looking for whoever made it.
fleet_status_report() {
  local local_disabled=0 local_scope="node" local_state fleet_state
  local_state="$(toggle_state "$state_dir")"
  if [[ "$(jq -r '.state' <<<"$local_state")" == "disabled" ]]; then
    local_disabled=1
    local_scope="$(toggle_scope "$(jq -c '.record // {}' <<<"$local_state")")"
  fi
  fleet_state="$(fleet_disabled_state "$state_repo" "$state_dir")"
  if [[ "$(jq -r '.state' <<<"$fleet_state")" == "disabled" ]]; then
    printf 'fleet:    DISABLED — %s\n' "$(toggle_describe "$(jq -c '.record' <<<"$fleet_state")")"
    if (( local_disabled )) && [[ "$local_scope" == "fleet" ]]; then
      printf '          the local record above mirrors this fleet switch — it is not a second, node-scoped disable; --enable clears both levels and every node resumes\n'
    elif (( local_disabled )); then
      printf '          this node also carries its own node-scoped disable (above) — --enable clears both; --enable --this-node clears only the local record, leaving the fleet switch (and this node) still down\n'
    else
      printf '          this node has no node-scoped disable of its own — --enable clears the fleet switch and every node resumes\n'
    fi
  elif (( local_disabled )) && [[ "$local_scope" == "fleet" ]]; then
    # The orphan (requirement 2.3): --enable run on a *peer* clears the fleet
    # flag but cannot reach this file, so this node alone stays down under a
    # fleet decision that has since been lifted. Naming it is the whole point
    # of the scope tag — otherwise this reads as a node-scoped disable nobody
    # set, and the node waits out a `forever` TTL that no longer applies.
    printf 'fleet:    not set — but the local record above mirrors a fleet switch that has since been cleared (probably by --enable on another node), so this node is standing down alone; --enable clears it\n'
  elif (( local_disabled )); then
    printf 'fleet:    not set — this node stands down on its own node-scoped disable above; --enable --this-node clears it\n'
  else
    printf 'fleet:    not set\n'
  fi
}

# The D18 kill switch (requirement 2.3b) — a separate flag from the fleet
# switch above, so killing merge autonomy never stops cycles running and
# disabling the pipeline never touches this. Reported alongside the other two
# stand-downs because all three answer some version of "why is this pipeline
# behaving the way it is right now".
merge_autonomy_status_report() {
  local ma_state
  ma_state="$(merge_autonomy_kill_state "$state_repo" "$state_dir")"
  # Anything but `enabled` is killed, the same test merge_autonomy_effective_level
  # itself applies — not `== "disabled"`. _toggle_eval also speaks `expired`,
  # and a record carrying an expiry it has passed resolves to `human` there
  # while reading as "not killed" here, which is the one way this report can
  # tell an operator the opposite of what the pipeline is doing.
  if [[ "$(jq -r '.state' <<<"$ma_state")" != "enabled" ]]; then
    # The fail-closed synthesis names itself — `record.kind: "fail-closed"`,
    # written by merge_autonomy_kill_state and nothing else, the same
    # discriminator scripts/doctor.sh branches on (requirement 2.3b, #454).
    # Nobody has necessarily set anything in that state: the node simply
    # cannot confirm the switch is clear, so KILLED here would send the
    # operator hunting a lever-pull that never happened, and
    # --restore-merge-autonomy would not help. Reporting-only — both branches
    # resolve every repo's effective level to human, unchanged.
    if [[ "$(jq -r '.record.kind // ""' <<<"$ma_state")" == "fail-closed" ]]; then
      printf 'merge_autonomy: FAIL-CLOSED — %s\n' "$(jq -r '.record.reason // "state repo unreachable"' <<<"$ma_state")"
      printf '          nobody has necessarily set the switch; check connectivity and state-repo health — --restore-merge-autonomy does not apply\n'
    else
      printf 'merge_autonomy: KILLED — %s\n' "$(toggle_describe "$(jq -c '.record' <<<"$ma_state")")"
      printf '          every repo'"'"'s effective level is human regardless of merge_autonomy; --restore-merge-autonomy clears it\n'
    fi
  else
    printf 'merge_autonomy: not killed — each repo runs at its configured level\n'
  fi
}

# Per-stage health (issue #662): whether each stage's most recent run of
# attempts on *this node* has been succeeding — the reading that was missing
# during the 2026-08-21 incident, where `cycle: RUNNING` and a clean fleet
# check both stayed true while every stage failed for 10.5 hours. Reads
# `state_dir/.stage-health.json`, written by `stage_health_write_status`
# (lib/stage-health.sh) at the end of every real cycle's own cleanup, rather
# than recomputing here — the same division `doctor_status_json`'s dashboard
# read keeps from `write_unattended_status`. A node that has not completed a
# cycle since upgrading reports that plainly instead of nothing.
stage_health_status_report() {
  printf 'stages:\n'
  stage_health_status_lines "$state_dir/.stage-health.json"
}

# run_manage_command — the `--disable`/`--enable`/`--status`/`--clear-limit`/
# `--kill-merge-autonomy` handling itself, called once from `agent-cycle.sh`
# in place of the inline block it replaces (#771). Returns without doing
# anything when no management action was asked for, so the call site needs no
# guard of its own; every action it does handle exits the process.
run_manage_command() {
if [[ -n "$MANAGE_ACTION" ]]; then
  case "$MANAGE_ACTION" in
    status)
      toggle_status_report "$state_dir" "cycle=$lock_file" "review=$review_lock_file"
      # A drain's own progress line, alongside the switch line above: printed
      # only while the local record is actually a drain (requirement 2.9),
      # since a plain stop or an enabled pipeline has no "how much is left"
      # to report and drain_status_line would otherwise print a misleading
      # "no cycle has checked yet" for a switch that was never a drain at all.
      status_switch_state="$(toggle_state "$state_dir")"
      if [[ "$(jq -r '.state' <<<"$status_switch_state")" == "disabled" ]] \
         && [[ "$(toggle_mode "$(jq -c '.record // {}' <<<"$status_switch_state")")" == "drain" ]]; then
        drain_status_line "$state_dir" "$(jq -c '.record' <<<"$status_switch_state")"
      fi
      fleet_status_report
      limit_status_report
      merge_autonomy_status_report
      stage_health_status_report
      exit 0
      ;;
    disable)
      # toggle_actor, never `${USER:-unknown}`: the record's actor is what
      # tells a reader whose decision this was, and `unknown@<container-id>`
      # is what let a deliberate operator stand-down read as a runaway
      # automatic freeze (#244).
      actor="$(toggle_actor)"
      by="$actor pid $$"
      # Read before writing: a --disable over a live switch is an extension of
      # the operator's earlier decision, and the log should say so rather than
      # presenting it as a fresh stop.
      prior_switch="$(toggle_state "$state_dir")"
      extends="$(jq -c 'select(.state == "disabled") | .record' <<<"$prior_switch" 2>/dev/null || true)"
      if ! disable_spec="$(toggle_resolve_disable_spec "$DISABLE_FOR" "$DISABLE_UNTIL" \
                             "$disable_default_ttl_hours")"; then
        exit 64
      fi
      # What this record *is*, not merely that it exists (requirement 2.3) —
      # written before the record, because the record carries it.
      #
      # This is deliberately not the same question as `disable_scope` below,
      # and the two part company in exactly one case. That one records the
      # operator's *instruction* for the log (issue #426), so a --disable on
      # an installation with no `state_repo` is still `scope: "fleet"`, with
      # `fleet_flag: "unconfigured"` saying why nothing was published. This one
      # answers "is there a fleet flag for this record to mirror?" — and with
      # no state repo there is none, so it is `node`. Tagging it `fleet` would
      # have --status claim a mirror of a switch that cannot exist, and
      # --enable --this-node refuse to clear the only record holding this node
      # down. Under --this-node both agree on `node`, for the same reason.
      record_scope=node
      if (( ! THIS_NODE )) && [[ -n "$state_repo" ]]; then record_scope=fleet; fi
      # mode "stop", explicit rather than left to toggle_disable's own default
      # (requirement 2.3d): a --disable issued while a --drain is active must
      # *tighten* it to a full stop immediately, and writing "stop" here is
      # what makes that the same code path as an ordinary fresh --disable
      # rather than a special case — the record this overwrites is simply
      # whatever mode it was in before.
      if ! record="$(toggle_disable "$state_dir" "$DISABLE_REASON" "$disable_spec" \
                       "$disable_default_ttl_hours" "$by" "$actor" manual "$record_scope" stop)"; then
        exit 64
      fi
      printf 'agent-cycle: disabled — %s\n' "$(toggle_describe "$record")"
      # The same record goes up as the fleet switch (requirement 2.3a): with
      # several nodes active, "stop the pipelines" has to mean all of them.
      # Best-effort — the local switch above already holds this node either
      # way, and the operator is told which of the two situations they are in.
      # --this-node opts out of that: the whole point of the flag is a
      # graceful, single-node stand-down that never reaches the fleet flag,
      # so the rest of the fleet is left running rather than warned about.
      #
      # `disable_scope` and `fleet_flag_outcome` are what the operator asked
      # for and what actually happened to it — logged below, once both are
      # known, rather than at the top of this block (issue #426): a process
      # killed mid-fleet-attempt must lose the event rather than log a
      # `disabled` that never says whether the fleet went down too.
      disable_scope="fleet"
      fleet_flag_outcome=""
      if (( THIS_NODE )); then
        disable_scope="node"
        printf 'agent-cycle: node-scoped disable — only %s stands down; the rest of the fleet keeps running\n' "$actor"
      else
        fleet_flag_outcome="$(fleet_flag_write_outcome "$state_repo" disabled "$record" \
          "fleet: disabled by $by — $DISABLE_REASON" "$state_dir")"
        case "$fleet_flag_outcome" in
          ok) printf 'agent-cycle: fleet switch set — every node will stand down\n' ;;
          failed)
            # Retag before warning: no fleet switch was set, so the local
            # record is no longer a mirror of anything — this node genuinely
            # is standing down alone, and a record still claiming `fleet`
            # would have --status and the dashboard describe a fleet
            # stand-down that does not exist. `unconfigured` needs no retag:
            # record_scope was already `node` when there is no state repo.
            toggle_mark_scope "$state_dir" node
            printf 'agent-cycle: WARNING — could not set the fleet switch (state repo unreachable?); only this node is disabled\n' >&2
            ;;
        esac
      fi
      log_event "disabled" "$(jq -nc --argjson r "$record" --argjson x "${extends:-null}" \
        --arg scope "$disable_scope" --arg ff "$fleet_flag_outcome" \
        '{reason: $r.reason, expires_at: $r.expires_at, by: $r.by,
          actor: $r.actor, kind: $r.kind, scope: $scope, mode: ($r.mode // "stop")}
         + (if $x == null then {} else {extends: $x} end)
         + (if $ff == "" then {} else {fleet_flag: $ff} end)')"
      # Say it plainly rather than leaving it to be discovered: an agent that
      # disables the pipeline to edit these files has not stopped the cycle
      # that is already reading them.
      held="$(toggle_lock_held "$lock_file")"
      [[ -n "$held" ]] && printf 'agent-cycle: WARNING — a cycle is still running (%s); it will finish.\n' "$held"
      held="$(toggle_lock_held "$review_lock_file")"
      [[ -n "$held" ]] && printf 'agent-cycle: WARNING — a review cycle is still running (%s); it will finish.\n' "$held"
      refresh_dashboard
      exit 0
      ;;
    drain)
      # requirement 2.3d. Same shape as `disable)` above — same record, same
      # scope/fleet-flag handling, same TTL resolution, same log fields — with
      # two differences: the record's `mode` is `"drain"` rather than the
      # default `"stop"`, and precedence is checked first, because a drain is
      # not simply "another disable": it may never *loosen* a stop already in
      # force (only --enable may), and issuing it must not silently discard
      # the plain --disable a peer or operator already imposed.
      actor="$(toggle_actor)"
      by="$actor pid $$"
      prior_switch="$(toggle_state "$state_dir")"
      prior_state="$(jq -r '.state' <<<"$prior_switch")"
      prior_mode="$(toggle_mode "$(jq -c '.record // {}' <<<"$prior_switch")")"
      if [[ "$prior_state" == "disabled" && "$prior_mode" == "stop" ]]; then
        echo "agent-cycle: --drain cannot loosen an active --disable (a full stop) — run --enable first if you want to switch to draining instead" >&2
        exit 64
      fi
      # The fleet switch counts as a prior stop too, and this node need not
      # carry a mirror of one: an unmodified `--disable` on a *peer* publishes
      # `fleet/disabled.json` and writes nothing to this node's own
      # `state_dir` (which is exactly why `--enable` below logs for the
      # no-local-record case, issue #426). Reading only the local record would
      # therefore let a fleet-scoped `--drain` here republish that flag as a
      # drain and downgrade the peer's stop across the whole fleet — the loosening
      # requirement 2.3d forbids in as many words. Checked only where the
      # loosening could actually happen: a `--this-node` drain, or one on a
      # node with no `state_repo`, publishes no flag and so cannot discard
      # anyone's stop. Fail-open on the same terms as every other reader of
      # this flag (requirement 2.3a) — an unreachable state repo reads
      # `enabled`, and in that same window the drain's own fleet write would
      # fail and retag itself `node` anyway.
      if (( ! THIS_NODE )) && [[ -n "$state_repo" ]]; then
        fleet_prior_switch="$(fleet_disabled_state "$state_repo" "$state_dir")"
        if [[ "$(jq -r '.state' <<<"$fleet_prior_switch")" == "disabled" ]] \
           && [[ "$(toggle_mode "$(jq -c '.record // {}' <<<"$fleet_prior_switch")")" == "stop" ]]; then
          echo "agent-cycle: --drain cannot loosen the fleet-wide --disable already in force (a full stop) — run --enable first if you want the fleet to drain instead" >&2
          exit 64
        fi
      fi
      extends="$(jq -c 'select(.state == "disabled") | .record' <<<"$prior_switch" 2>/dev/null || true)"
      if ! disable_spec="$(toggle_resolve_disable_spec "$DISABLE_FOR" "$DISABLE_UNTIL" \
                             "$disable_default_ttl_hours")"; then
        exit 64
      fi
      record_scope=node
      if (( ! THIS_NODE )) && [[ -n "$state_repo" ]]; then record_scope=fleet; fi
      if ! record="$(toggle_disable "$state_dir" "$DRAIN_REASON" "$disable_spec" \
                       "$disable_default_ttl_hours" "$by" "$actor" manual "$record_scope" drain)"; then
        exit 64
      fi
      printf 'agent-cycle: draining — %s\n' "$(toggle_describe "$record")"
      printf 'agent-cycle: new work will not be picked up; open review-feedback, merge-conflict, dequeued and abandoned-draft pull requests will still be finished\n'
      disable_scope="fleet"
      fleet_flag_outcome=""
      if (( THIS_NODE )); then
        disable_scope="node"
        printf 'agent-cycle: node-scoped drain — only %s stands down from new work; the rest of the fleet keeps working\n' "$actor"
      else
        fleet_flag_outcome="$(fleet_flag_write_outcome "$state_repo" disabled "$record" \
          "fleet: drain started by $by — $DRAIN_REASON" "$state_dir")"
        case "$fleet_flag_outcome" in
          ok) printf 'agent-cycle: fleet switch set — every node will drain\n' ;;
          failed)
            toggle_mark_scope "$state_dir" node
            printf 'agent-cycle: WARNING — could not set the fleet switch (state repo unreachable?); only this node is draining\n' >&2
            ;;
        esac
      fi
      log_event "disabled" "$(jq -nc --argjson r "$record" --argjson x "${extends:-null}" \
        --arg scope "$disable_scope" --arg ff "$fleet_flag_outcome" \
        '{reason: $r.reason, expires_at: $r.expires_at, by: $r.by,
          actor: $r.actor, kind: $r.kind, scope: $scope, mode: "drain"}
         + (if $x == null then {} else {extends: $x} end)
         + (if $ff == "" then {} else {fleet_flag: $ff} end)')"
      refresh_dashboard
      exit 0
      ;;
    enable)
      # --this-node undoes a --disable --this-node. It must refuse a record
      # tagged `fleet` (requirement 2.3), because clearing that one is never
      # what the operator wanted and can be actively harmful: the mirror is
      # this node's fail-closed hold on itself for exactly the window where
      # the fleet flag cannot be read (state repo unreachable — see
      # lib/toggle.sh's fleet section, which fails *open*), so dropping it
      # while the fleet switch stands is how a node resumes work the fleet was
      # stood down to prevent. Plain --enable is the right command in every
      # case: it clears this record and issues the fleet delete, which is
      # idempotent and treats an already-cleared flag as success.
      if (( THIS_NODE )); then
        enable_state="$(toggle_state "$state_dir")"
        if [[ "$(jq -r '.state' <<<"$enable_state")" == "disabled" ]] \
           && [[ "$(toggle_scope "$(jq -c '.record // {}' <<<"$enable_state")")" == "fleet" ]]; then
          echo "agent-cycle: this node's disable record mirrors a fleet-wide --disable, not a --this-node one; --enable --this-node will not clear it. Use --enable, which clears both levels (harmless if the fleet switch is already clear)." >&2
          exit 64
        fi
      fi
      record="$(toggle_clear "$state_dir")"
      if [[ -n "$record" ]]; then
        printf 'agent-cycle: enabled — cleared the disable set at %s (%s)\n' \
          "$(jq -r '.disabled_at // "?"' <<<"$record")" "$(jq -r '.reason // "?"' <<<"$record")"
      else
        printf 'agent-cycle: already enabled — no switch was set\n'
      fi
      # Clear the fleet switch too — and complain loudly if that fails,
      # because a fleet flag left set keeps every node down after the
      # operator believes they have re-enabled the operation.
      # --this-node opts out: it undoes only this node's own --disable
      # --this-node, and must never clear a fleet switch (or another node's
      # own node-scoped one) it did not set.
      enable_scope="fleet"
      fleet_flag_outcome=""
      if (( THIS_NODE )); then
        enable_scope="node"
        printf 'agent-cycle: node-scoped enable — the fleet switch, if any, is untouched\n'
      elif [[ -n "$state_repo" ]]; then
        fleet_flag_outcome="$(fleet_flag_delete_outcome "$state_repo" "$state_dir" disabled)"
        case "$fleet_flag_outcome" in
          ok|unconfigured) printf 'agent-cycle: fleet switch clear\n' ;;
          failed) printf 'agent-cycle: WARNING — could not clear the fleet switch; every node still stands down. Re-run --enable, or delete fleet/disabled.json in %s by hand.\n' "$state_repo" >&2 ;;
        esac
      else
        fleet_flag_outcome="unconfigured"
      fi
      # Log `enabled` whenever anything was actually cleared — the local
      # record, the fleet flag, or both — not only when the local record was
      # set (issue #426): a node with no local record but a live fleet flag
      # previously left the fleet coming back up absent from the log
      # entirely.
      if [[ -n "$record" || "$fleet_flag_outcome" == "ok" ]]; then
        log_event "enabled" "$(jq -nc --argjson r "${record:-null}" \
          --arg scope "$enable_scope" --arg ff "$fleet_flag_outcome" \
          '{detail: "cleared by hand", was: $r, scope: $scope}
           + (if $ff == "" then {} else {fleet_flag: $ff} end)')"
      fi
      refresh_dashboard
      exit 0
      ;;
    clear-limit)
      # Both carriers of requirement 2.1, because the stand-down lifts only
      # when the later of the two says so. Clearing one alone reads as
      # success and changes nothing — the failure this command exists to end.
      governing="$(current_limit_record)"
      was="$(jq -r '.resume_at // empty' <<<"${governing:-{\}}" 2>/dev/null || true)"

      # Carrier 1: the log union. A `limit-cleared` event dated now outranks
      # every earlier limit-hit, on this node immediately and on its peers at
      # their next state-sync fetch.
      log_event "limit-cleared" "$(jq -nc --arg w "$was" --arg r "$CLEAR_LIMIT_REASON" \
        --arg by "$(toggle_actor)" \
        '{was: (if $w == "" then null else $w end),
          reason: (if $r == "" then "cleared by hand" else $r end),
          by: $by, actor: $by, kind: "manual"}')"

      # Carrier 2: the live flag. Deleting it rather than shortening it,
      # because fleet_limit_publish is extend-only by design (concurrent hits
      # must converge on the latest resume) — a human lifting a stand-down is
      # the one case that legitimately moves it earlier, and delete is the
      # only write that expresses that.
      if [[ -n "$state_repo" ]]; then
        # >/dev/null: fleet_flag_delete now prints which of "deleted"/"absent"
        # it was (issue #426) for callers that log the outcome; this one only
        # ever reads the return code, and the raw word must not leak to the
        # operator's terminal.
        if fleet_flag_delete "$state_repo" "$state_dir" limit >/dev/null; then
          printf 'agent-cycle: fleet usage-limit flag clear\n'
        else
          printf 'agent-cycle: WARNING — could not clear fleet/limit.json; peers reading it live still stand down. Re-run --clear-limit, or delete fleet/limit.json in %s by hand.\n' "$state_repo" >&2
        fi
      fi

      if [[ -n "$was" ]]; then
        printf 'agent-cycle: usage-limit stand-down lifted (resume_at was %s)\n' "$was"
      else
        printf 'agent-cycle: no usage-limit stand-down was in force\n'
      fi
      refresh_dashboard
      exit 0
      ;;
    kill-merge-autonomy)
      # D18 §6 (requirement 2.3b): a permanent operational control, not
      # scaffolding — inherently fleet-wide, so unlike --disable there is no
      # --this-node form and no local record to write first. With no
      # state_repo configured this is a single-node install and the flag
      # cannot be published anywhere every future read would see it — say so
      # rather than pretend the kill took effect.
      by="$(toggle_actor) pid $$"
      if [[ -z "$state_repo" ]]; then
        echo "agent-cycle: no state_repo configured — --kill-merge-autonomy has nothing to publish to (single-node install; the config's own merge_autonomy already governs)" >&2
        exit 64
      fi
      outcome="$(merge_autonomy_kill_set "$state_repo" "$KILL_MERGE_AUTONOMY_REASON" "$by")"
      case "$outcome" in
        ok) printf 'agent-cycle: merge-autonomy kill switch set — every repo'"'"'s effective level is now human\n' ;;
        *) echo "agent-cycle: WARNING — could not set the merge-autonomy kill switch (state repo unreachable?)" >&2 ;;
      esac
      log_event "merge-autonomy-killed" "$(jq -nc --arg r "$KILL_MERGE_AUTONOMY_REASON" \
        --arg by "$by" --arg actor "$(toggle_actor)" --arg outcome "$outcome" \
        '{reason: $r, by: $by, actor: $actor, kind: "manual", fleet_flag: $outcome}')"
      refresh_dashboard
      exit 0
      ;;
    restore-merge-autonomy)
      if [[ -z "$state_repo" ]]; then
        printf 'agent-cycle: no state_repo configured — the kill switch was never publishable (single-node install)\n'
        exit 0
      fi
      outcome="$(merge_autonomy_kill_clear "$state_repo" "$state_dir")"
      case "$outcome" in
        ok) printf 'agent-cycle: merge-autonomy kill switch cleared — each repo'"'"'s configured level governs again\n' ;;
        unconfigured) printf 'agent-cycle: merge-autonomy kill switch was not set\n' ;;
        *) echo "agent-cycle: WARNING — could not clear the merge-autonomy kill switch; every repo still forced to human. Re-run --restore-merge-autonomy, or delete fleet/merge-autonomy-kill.json in $state_repo by hand." >&2 ;;
      esac
      if [[ "$outcome" == "ok" ]]; then
        log_event "merge-autonomy-restored" "$(jq -nc --arg by "$(toggle_actor)" \
          '{detail: "cleared by hand", by: $by, actor: $by, kind: "manual"}')"
      fi
      refresh_dashboard
      exit 0
      ;;
  esac
fi
}
