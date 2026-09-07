#!/usr/bin/env bash
#
# lib/node-time-state.sh — the node time-state record (docs/FLOW-SCHEMA.md,
# D21 of docs/ROADMAP.md, issue #597, Phase 1's time account): a `node-state`
# transition event every time a node changes what it is doing, carrying the
# cause, so idleness is recorded with its reason at the moment it happens
# rather than inferred afterwards from an absence of cycles.
#
# One shaping/logging function pair, on the same terms lib/metering.sh's
# `metering_fields` and lib/rework.sh's `rework_fields` already are: every
# call site here already knows, from the check it just ran, which of the six
# states applies and (for four of them) which cause — this file only shapes
# that into the documented event and, for the pure fold, derives seconds per
# state from the events already logged. It never classifies, never reads a
# transcript, and never asks a model.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# --- The closed cause vocabulary (docs/FLOW-SCHEMA.md) ---
#
# `node_time_state_for_cause CAUSE` maps one of the closed vocabulary's
# tokens to its state, as "STATE\tCAUSE\n" (cause echoed back verbatim, so a
# caller has one tuple to destructure regardless of which helper produced
# it). An unrecognised cause prints "\t\n" (both fields empty) — the caller's
# signal to skip logging a cause-bearing state at all rather than guess one.
# Every branch's own trailing newline is not decoration: a caller destructures
# this with `read -r a b < <(...)`, and `read` reports failure — a nonzero
# exit under this repository's own `set -e` — for a line with no terminating
# newline, however completely it still populated the variables. Every printf
# in this file keeps that newline for the same reason, whether or not the
# variables it fills are ever inspected by a caller that would notice.
#
# Three of the fourteen tokens are pre-existing `stand-down`/`claim-lost`
# causes this requirement does not rename (agent-ops#598's join-key
# precedent: an existing field's values are never renamed to satisfy a new
# reader) — `raced`/`pre-claimed` (claim-race stand-downs, agent-cycle.sh)
# and `fabricated`/`untraceable` (corroboration-gate stand-downs) keep their
# own names on the `stand-down` event itself, and are translated here to the
# canonical `peer-claimed`/`coordinator-declined` tokens only for the
# `node-state` event this file emits alongside it.
node_time_state_for_cause() {  # CAUSE -> "STATE\tCAUSE\n"
  case "$1" in
    disabled-node)   printf 'down\tdisabled-node\n' ;;
    disabled-fleet)  printf 'down\tdisabled-fleet\n' ;;
    usage-limit)     printf 'externally-blocked\tusage-limit\n' ;;
    github-budget)   printf 'externally-blocked\tgithub-budget\n' ;;
    unreachable)     printf 'externally-blocked\tunreachable\n' ;;
    unauthorized)    printf 'externally-blocked\tunauthorized\n' ;;
    disk-low)        printf 'externally-blocked\tdisk-low\n' ;;
    disk-full)       printf 'externally-blocked\tdisk-full\n' ;;
    memory-low)      printf 'externally-blocked\tmemory-low\n' ;;
    back-pressure)   printf 'idle-with-demand\tback-pressure\n' ;;
    awaiting-tick)   printf 'idle-with-demand\tawaiting-tick\n' ;;
    peer-claimed|raced|pre-claimed)         printf 'idle-with-demand\tpeer-claimed\n' ;;
    coordinator-declined|fabricated|untraceable) printf 'idle-with-demand\tcoordinator-declined\n' ;;
    no-demand)       printf 'idle-without-demand\tno-demand\n' ;;
    *)               printf '\t\n' ;;
  esac
}

# node_time_state_idle_split TOTAL CAUSE_IF_POSITIVE -> "STATE\tCAUSE"
# The one test every idle classification in this file reduces to: eligible
# demand existed and this node did nothing about it (`idle-with-demand`,
# tagged with whichever of the four causes the caller names for a positive
# count), or nothing was eligible anywhere (`idle-without-demand`/
# `no-demand`, the healthy zero). TOTAL that is not a non-negative integer
# (unset, empty, unreadable) is treated as zero — "unknown demand" degrades
# to the healthy-zero reading rather than a guess, on the same "never invent
# a reading" terms every stand-down cause above already keeps.
node_time_state_idle_split() {
  local total="${1:-}" cause_pos="${2:-awaiting-tick}"
  if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )); then
    printf 'idle-with-demand\t%s\n' "$cause_pos"
  else
    printf 'idle-without-demand\tno-demand\n'
  fi
}

# node_state_for_stage ACTOR -> producing | overhead
# The one place D21's narrow reading of "producing" lives (docs/FLOW-
# SCHEMA.md's "node time-state record", the definitional pin): wall time
# between a stage's own stage-start and stage-end counts as producing only
# for the Implementer and the Reviewer — the two stages whose output becomes
# a delivered change. Every other actor (coordinator, enabler,
# enabler-adjudicate, enabler-decide, refiner, approver,
# approver-adjudicate-open-question) buys the decision, not the change, so
# its own stage-start/stage-end interval is overhead.
node_state_for_stage() {
  case "$1" in
    implementer|reviewer) printf 'producing' ;;
    *)                     printf 'overhead' ;;
  esac
}

# log_node_state_transition STATE [CAUSE]
# Log one `node-state` event: {state, cause, prev_state}. `prev_state` is
# this process's own last-known state (`_NODE_STATE_CURRENT`), defaulting to
# `down` on this process's first transition — the pitfall this requirement's
# refinement names: `down` is derived from absence and never emits its own
# transition, so a live node's very first transition of a fresh process is
# always read as "out of down" (docs/FLOW-SCHEMA.md), regardless of what a
# peer's log might say this node was doing under a different process a
# moment before. The fold itself never trusts `prev_state` for interval
# reconstruction — it re-derives every interval from consecutive events'
# own `ts`/`state` — so this default costs the record nothing: `prev_state`
# is audit context, not a value anything downstream computes from.
log_node_state_transition() {
  local state="$1" cause="${2:-}" prev="${_NODE_STATE_CURRENT:-down}"
  log_event "node-state" "$(jq -nc --arg s "$state" --arg p "$prev" --arg c "$cause" \
    '{state: $s, prev_state: $p} + (if $c == "" then {cause: null} else {cause: $c} end)')"
  _NODE_STATE_CURRENT="$state"
}

# set_node_state_terminal STATE [CAUSE]
# Record — without logging anything yet — the state this cycle/review run is
# heading into once it stops. Every stand-down and every genuinely-nothing-
# selected site calls this instead of logging immediately, because the exit
# trap (`cleanup`) can still run the Enabler and the Refiner after any of
# them fires (requirement 35), and their own stage-start/stage-end pairs are
# real overhead that must land on the timeline *before* the node settles
# into the idle/down/externally-blocked state this call names — logging here
# would let a later Enabler engagement's own "overhead" transition silently
# overwrite this one on the shared per-node timeline the fold reconstructs.
# `finalize_node_state_for_cycle`/`finalize_node_state_for_review`, called
# once at the true end of `cleanup`, is what actually logs it.
set_node_state_terminal() {
  _CYCLE_TERMINAL_STATE="$1"
  _CYCLE_TERMINAL_CAUSE="${2:-}"
}

# finalize_node_state_for_cycle
# Called once, at the very end of agent-cycle.sh's `cleanup`, after
# `maybe_run_enabler`/`maybe_run_refiner` have had their chance to add real
# overhead to this same timeline. Logs whatever `set_node_state_terminal`
# recorded, if anything did; otherwise this cycle ran a stage and ended
# normally, and the idle state the *next* sleep starts in is read off
# `eligible_items_total` — the Co-Ordinator's own pre-selection count, minus
# the one item this cycle just claimed (floored at zero) — the same
# idle-with-demand/idle-without-demand test every other site in this file
# applies. A cycle that never reached that count (an exit before requirement
# 3u's gather, every one of which already calls `set_node_state_terminal`
# itself) simply has nothing to finalize beyond what was already set.
finalize_node_state_for_cycle() {
  if [[ -n "${_CYCLE_TERMINAL_STATE:-}" ]]; then
    log_node_state_transition "$_CYCLE_TERMINAL_STATE" "${_CYCLE_TERMINAL_CAUSE:-}"
    return 0
  fi
  local remaining="${eligible_items_total:-}"
  if [[ "$remaining" =~ ^[0-9]+$ ]] && (( remaining > 0 )); then
    remaining=$(( remaining - 1 ))
  fi
  local state cause
  IFS=$'\t' read -r state cause < <(node_time_state_idle_split "$remaining" awaiting-tick)
  log_node_state_transition "$state" "$cause"
}

# finalize_node_state_for_review
# review-cycle.sh's own analogue. The review pipeline has no per-cycle
# eligible-item count the way agent-cycle.sh's Co-Ordinator gather does — it
# reviews one configured repository on a dated cadence rather than against a
# backlog — so a review run that ends without any `review-stand-down` ever
# calling `set_node_state_terminal` settles into `idle-without-demand`/
# `no-demand` unconditionally. Documented as a known simplification in
# docs/FLOW-SCHEMA.md rather than a modelled account: this pipeline's own
# demand shape is not part of D21's four idle-with-demand causes, all of
# which name a *backlog* agent-cycle.sh's Co-Ordinator declines against.
finalize_node_state_for_review() {
  if [[ -n "${_CYCLE_TERMINAL_STATE:-}" ]]; then
    log_node_state_transition "$_CYCLE_TERMINAL_STATE" "${_CYCLE_TERMINAL_CAUSE:-}"
    return 0
  fi
  log_node_state_transition idle-without-demand no-demand
}

# The pure fold (docs/FLOW-SCHEMA.md's "Node time-state record"). Reads
# `node-state` events only — every other event this requirement touches
# (`stand-down`, `none-selected`, `limit-hit`, …) already has its own
# `node-state` sibling logged beside it at the same instant, so the fold
# never has to re-derive a state from anything but this one event type.
#
# Per node: the timeline is a synthetic `down` point at the window's own
# start, followed by every one of that node's own `node-state` events inside
# the window, sorted by `ts`. Each point's own `state` holds from its `ts`
# until the next point's (the last, until the window's end) — so a node with
# zero events in the window scores `down` for the window's entire span (the
# synthetic point alone), and a node whose first event lands partway through
# the window scores `down` for the leading gap before it, exactly the
# "absent for part of the window" case this requirement's acceptance names.
# `prev_state` is never read here — every interval comes from consecutive
# points' own `ts`/`state`, which is also what makes this fold immune to two
# processes racing to log the same instant: whichever pipeline's own event
# actually carries the later `ts` simply starts the next interval, and
# nothing is double-counted, because a node contributes exactly one
# `window_seconds`-wide timeline no matter how many events land on it.
#
# One documented simplification (docs/FLOW-SCHEMA.md states it plainly
# rather than hiding it): the node set considered is every node that has
# *ever* logged a `node-state` event, over the fold's whole unwindowed input
# — not evaluated per second of the window the way a node truly joining or
# leaving the fleet mid-window would need. A decommissioned node keeps
# scoring `down` for the rest of the window after its last event, which
# overstates `down` for an installation that shrinks its fleet; a node that
# joins mid-window scores its own leading gap as `down` correctly (the
# general rule above already gives this one for free).
#
# An event naming no `node`, no `ts`, or no `state` cannot be placed on any
# timeline at all and is excluded, counted under `skipped_events` rather
# than silently dropped. An event whose `state` is not one of the six names
# below cannot be classified either, but *can* still be placed — its own
# interval lands in `unaccounted_seconds` rather than being excluded, since
# the instant it names is real even though the label on it is not one the
# invariant recognises.
# shellcheck disable=SC2016  # jq's own $all/$since/$until, not the shell's.
NODE_TIME_STATE_FOLD_JQ='
  def valid_states: ["producing","overhead","externally-blocked","idle-with-demand","idle-without-demand","down"];
  def idle_causes: ["awaiting-tick","back-pressure","peer-claimed","coordinator-declined"];

  ($all | map(select(type == "object" and .event == "node-state"))) as $ns_candidates
  | ([$ns_candidates[] | select(((.node // "") | tostring) == "" or (.ts // "") == "" or (.state // "") == "")] | length) as $skipped
  | ($ns_candidates | map(select(((.node // "") | tostring) != "" and (.ts // "") != "" and (.state // "") != ""))) as $ns_all
  | ($ns_all | map(.node) | unique) as $nodes
  | ($ns_all | map(select($since == "" or .ts >= $since)) | map(select($until == "" or .ts <= $until))) as $ns
  | ($ns | map(.ts) | sort) as $ts_all
  | (if $since != "" then $since elif ($ts_all | length) > 0 then $ts_all[0] else null end) as $win_from
  | (if $until != "" then $until elif ($ts_all | length) > 0 then $ts_all[-1] else null end) as $win_to
  | (if $win_from == null or $win_to == null then 0
     else (($win_to | fromdateiso8601) - ($win_from | fromdateiso8601)) end) as $win_seconds

  | ($win_from // "1970-01-01T00:00:00Z") as $wf_ts
  | (if $win_from == null then 0 else ($win_from | fromdateiso8601) end) as $wf
  | (if $win_to   == null then 0 else ($win_to   | fromdateiso8601) end) as $wt

  | ([ $nodes[] as $node
      | ($ns | map(select(.node == $node)) | map({ts, state, cause: (.cause // null)})) as $evs
      | ([{ts: $wf_ts, state: "down", cause: null}] + $evs
          | map(. + {epoch: (.ts | fromdateiso8601)})
          | sort_by(.epoch)) as $points
      | ([range(0; ($points | length)) as $i
          | $points[$i] as $p
          | (if $i + 1 < ($points | length) then $points[$i+1].epoch else $wt end) as $seg_end
          | {start: $p.epoch, end: $seg_end, state: $p.state, cause: $p.cause}
         ]) as $segments
      | (reduce $segments[] as $seg
          ({seconds: {}, idle_by_cause: {}, unaccounted_seconds: 0};
           (if $seg.end > $seg.start then ($seg.end - $seg.start) else 0 end) as $dur
           | if (valid_states | index($seg.state)) then
               (.seconds[$seg.state] = ((.seconds[$seg.state] // 0) + $dur))
               | if $seg.state == "idle-with-demand" then
                   ((if (idle_causes | index($seg.cause)) then $seg.cause else "unspecified" end) as $c
                    | .idle_by_cause[$c] = ((.idle_by_cause[$c] // 0) + $dur))
                 else . end
             else
               .unaccounted_seconds += $dur
             end)) as $acc
      | {node: $node} + $acc
     ]) as $per_node

  | (reduce $per_node[] as $n
      ({}; reduce (valid_states[]) as $s (.; .[$s] = ((.[$s] // 0) + ($n.seconds[$s] // 0)))
       )) as $fleet_seconds
  | ($per_node | map(.unaccounted_seconds) | add // 0) as $fleet_unaccounted
  | (reduce $per_node[] as $n
      ({}; reduce (idle_causes + ["unspecified"])[] as $c
             (.; .[$c] = ((.[$c] // 0) + ($n.idle_by_cause[$c] // 0)))
       )) as $idle_with_demand_by_cause
  | (($nodes | length) * $win_seconds) as $expected_total
  | ((valid_states | map($fleet_seconds[.]) | add // 0) + $fleet_unaccounted) as $actual_total

  | {
      window: {from: $win_from, to: $win_to, seconds: $win_seconds},
      nodes: ($nodes | sort),
      skipped_events: $skipped,
      totals: ({
        producing: $fleet_seconds.producing, overhead: $fleet_seconds.overhead,
        "externally-blocked": $fleet_seconds["externally-blocked"],
        "idle-with-demand": $fleet_seconds["idle-with-demand"],
        "idle-without-demand": $fleet_seconds["idle-without-demand"],
        down: $fleet_seconds.down,
        unaccounted: $fleet_unaccounted
      }),
      expected_total_seconds: $expected_total,
      balanced: ($actual_total == $expected_total),
      idle_with_demand_by_cause: $idle_with_demand_by_cause,
      by_node: ($per_node | map({key: .node, value: ({
          producing: (.seconds.producing // 0), overhead: (.seconds.overhead // 0),
          "externally-blocked": (.seconds["externally-blocked"] // 0),
          "idle-with-demand": (.seconds["idle-with-demand"] // 0),
          "idle-without-demand": (.seconds["idle-without-demand"] // 0),
          down: (.seconds.down // 0),
          unaccounted: .unaccounted_seconds,
          idle_with_demand_by_cause: .idle_by_cause
        })}) | from_entries)
    }
'

# node_time_state_fold LOG_FILE [SINCE [UNTIL]]
# Print the node time-state report — `window`, `totals` (the six states plus
# `unaccounted`), `expected_total_seconds`/`balanced` (the invariant:
# node-count x window seconds), `idle_with_demand_by_cause`, and `by_node` —
# folded from LOG_FILE, or stdin if it is "-". Always succeeds, printing the
# all-empty shape for a missing, empty or unreadable log, on the same terms
# `lib/item-lifecycle.sh`'s `item_lifecycle_fold` already does.
node_time_state_fold() {
  local src="${1:--}" since="${2:-}" until="${3:-}" raw="" all_json="" out=""
  if [[ "$src" == "-" ]]; then
    raw="$(cat 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    raw="$(cat "$src" 2>/dev/null || true)"
  fi
  all_json="$(jq -c -R 'fromjson? // empty' <<<"$raw" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  [[ -n "$all_json" ]] || all_json='[]'

  out="$(jq -nc --arg since "$since" --arg until "$until" \
      'input as $all | ('"$NODE_TIME_STATE_FOLD_JQ"')' <<<"$all_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{"window":{"from":null,"to":null,"seconds":0},"nodes":[],"skipped_events":0,"totals":{"producing":0,"overhead":0,"externally-blocked":0,"idle-with-demand":0,"idle-without-demand":0,"down":0,"unaccounted":0},"expected_total_seconds":0,"balanced":true,"idle_with_demand_by_cause":{"awaiting-tick":0,"back-pressure":0,"peer-claimed":0,"coordinator-declined":0,"unspecified":0},"by_node":{}}'
  printf '%s' "$out"
}
