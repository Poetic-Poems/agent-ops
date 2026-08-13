#!/usr/bin/env bash
#
# lib/crash-loop.sh — detect a fleet-wide crash loop in the union log, and
# decide whether it has already been escalated (requirement 2.7).
#
# The failure class this first existed for is the one the fleet has actually
# lived through: a deterministic Co-Ordinator failure that ships in the
# image, so a single roll breaks every node identically. On 2026-08-01 the
# assembled Co-Ordinator prompt crossed the kernel's argv cap and every node
# in the fleet exited 126 hourly for ~15 hours — and the record made it look
# like a healthy idle fleet, because a Co-Ordinator failure pins no repo/item
# (so nothing was blocked, and the Enabler had nothing to examine) and the
# cycle still ends 0. Item-scoped failures already have a whole recovery
# ladder (blocked → Enabler → escalation issue); the Co-Ordinator's own
# failures had no rung at all. This is that rung.
#
# `crash_loop_verdict`'s detection is deliberately narrow: *consecutive*
# Co-Ordinator `attempt-failed` events carrying *one identical* detail, with
# no Co-Ordinator success anywhere in the fleet in between. Identical detail
# is what separates the deterministic class (every node says `coordinator
# exited 126`) from ordinary transient noise (one timeout here, one
# unparseable message there), and any Co-Ordinator success resets the count
# to zero — a fleet that is mostly working is not in a crash loop, however
# many failures it accumulates over a week.
#
# `crash_loop_preselection_verdict` (TD-PPagop-26081302) covers the class the
# first reader cannot see: a cycle that dies while assembling its own runtime
# input, before `stage-start` for any stage is ever logged, writes no
# `attempt-failed` at all — the 2026-08-12 void-extract outage took exactly
# this shape, crossing the same argv cap before requirement 4g's stdin fix
# landed. It groups consecutive cycle-start/cycle-end(non-zero)/no-stage-start
# runs by `exit_code`, the cheapest fingerprint this class leaves in place of
# a `detail` string.
#
# All functions are pure readers of an event stream on stdin — the same
# union the stand-down checks read, so a loop any node detects is one every
# node agrees about. Torn lines are skipped (`fromjson? // empty`), exactly
# as the dashboard's reader treats the same stream.

# crash_loop_verdict THRESHOLD < union.jsonl
# Print one JSON object — {stage, detail, count, first_ts, last_ts, nodes} —
# when the stream's tail shows THRESHOLD or more consecutive same-detail
# Co-Ordinator failures with no intervening Co-Ordinator success; print
# nothing otherwise. A THRESHOLD that is not a positive integer prints
# nothing: 0 (or an unset key upstream) is the feature's off switch.
crash_loop_verdict() {
  local threshold="${1:-0}"
  if ! [[ "$threshold" =~ ^[0-9]+$ ]] || (( threshold < 1 )); then
    return 0
  fi
  jq -c -R -s --argjson threshold "$threshold" '
    [ splits("\n") | select(length > 0) | (fromjson? // empty) ]
    | map(select(
        (.event == "attempt-failed" and (.stage // "") == "coordinator")
        or ((.event == "stage-end") and ((.stage // "") == "coordinator")
            and ((.exit_code // 1) == 0))
      ))
    # The stream is time-ordered by `fleet_logs`; the reduction walks it once.
    # A success resets everything — including after the "stage-end 0 then
    # attempt-failed: unparseable" sequence, where the reset lands first and
    # the failure then counts 1, which is the truth of that cycle.
    | reduce .[] as $e (
        {detail: "", count: 0, first_ts: null, last_ts: null, nodes: []};
        if $e.event == "stage-end" then
          {detail: "", count: 0, first_ts: null, last_ts: null, nodes: []}
        elif ($e.detail // "") == .detail and .count > 0 then
          {detail: .detail, count: (.count + 1), first_ts: .first_ts,
           last_ts: ($e.ts // .last_ts),
           nodes: ((.nodes + [$e.node // "?"]) | unique)}
        else
          {detail: ($e.detail // ""), count: 1,
           first_ts: ($e.ts // null), last_ts: ($e.ts // null),
           nodes: [$e.node // "?"]}
        end
      )
    | select(.count >= $threshold and .detail != "")
    | {stage: "coordinator"} + .
  ' 2>/dev/null || true
}

# crash_loop_preselection_verdict THRESHOLD < union.jsonl
# Print one JSON object — {stage, detail, exit_code, count, first_ts,
# last_ts, nodes} — when the stream's tail shows THRESHOLD or more
# consecutive cycles that each died before any stage started, with the same
# exit code and no intervening recovery; print nothing otherwise. Same
# THRESHOLD off switch as `crash_loop_verdict`.
#
# This covers the class `crash_loop_verdict` cannot see: a cycle that dies
# while assembling its own runtime input — before `stage-start` for any
# stage is ever logged — writes no `attempt-failed` for any stage, so the
# union shows only a `cycle-start` / `cycle-end(<nonzero>)` pair. Both the
# 2026-08-01 argv-cap outage and the 2026-08-12 void-extract one took this
# shape: `execve` failed before the Co-Ordinator process ever started, so
# nothing pinned `stage: coordinator` on anything.
#
# There is no `detail` string for this class the way an `attempt-failed`
# carries one, so cycles are grouped by `exit_code` instead — the cheapest
# fingerprint a pre-selection death leaves. A cycle is joined to a run by
# matching `cycle` id across its `cycle-start`, any `stage-start`s, and its
# `cycle-end`; cycles with no `cycle-end` at all (still running, or killed
# too abruptly to log one) are dropped rather than counted either way. A
# cycle resets the run — exactly like a Co-Ordinator success resets
# `crash_loop_verdict` — the moment it proves the systemic block is not
# reproducing right now: either it exits 0, or it reaches a stage at all
# (any `stage-start`, for any stage), regardless of how that stage then
# fares. What happens to an item once a stage is running already has its
# own recovery ladder; this reader's only job is the gap before that ladder
# can even see a failure.
crash_loop_preselection_verdict() {
  local threshold="${1:-0}"
  if ! [[ "$threshold" =~ ^[0-9]+$ ]] || (( threshold < 1 )); then
    return 0
  fi
  jq -c -R -s --argjson threshold "$threshold" '
    [ splits("\n") | select(length > 0) | (fromjson? // empty) ]
    | map(select(.event == "cycle-start" or .event == "cycle-end"
                 or .event == "stage-start"))
    | group_by(.cycle)
    | map(
        (map(select(.event == "cycle-end")) | first) as $end
        | select($end != null)
        | {
            node: ($end.node // "?"),
            ts: ($end.ts // null),
            exit_code: ($end.exit_code // 1),
            had_stage: (any(.[]; .event == "stage-start"))
          }
      )
    # `group_by` does not preserve input order; the run is only meaningful
    # walked in the order cycles actually concluded.
    | sort_by(.ts)
    | reduce .[] as $c (
        {exit_code: null, count: 0, first_ts: null, last_ts: null, nodes: []};
        if ($c.exit_code == 0) or $c.had_stage then
          {exit_code: null, count: 0, first_ts: null, last_ts: null, nodes: []}
        elif ($c.exit_code == .exit_code) and .count > 0 then
          {exit_code: .exit_code, count: (.count + 1), first_ts: .first_ts,
           last_ts: ($c.ts // .last_ts), nodes: ((.nodes + [$c.node]) | unique)}
        else
          {exit_code: $c.exit_code, count: 1, first_ts: ($c.ts // null),
           last_ts: ($c.ts // null), nodes: [$c.node]}
        end
      )
    | select(.count >= $threshold and .exit_code != null)
    | {stage: "pre-selection", detail: "cycle exited \(.exit_code) before any stage started"} + .
  ' 2>/dev/null || true
}

# crash_loop_escalated_since FIRST_TS DETAIL < union.jsonl
# Exit 0 when a `crash-loop-escalated` event with the same detail exists at
# or after FIRST_TS — the current run of failures has already been escalated,
# by this node or a peer — and 1 otherwise. Keying on the run's own first
# failure is what lets a *new* loop with the same detail, months after the
# old issue was closed, escalate afresh: its first_ts postdates every old
# event.
crash_loop_escalated_since() {
  local first_ts="$1" detail="$2" hits
  hits="$(jq -r -R -s --arg ts "$first_ts" --arg detail "$detail" '
    [ splits("\n") | select(length > 0) | (fromjson? // empty)
      | select(.event == "crash-loop-escalated"
               and (.detail // "") == $detail
               and (.ts // "") >= $ts) ]
    | length
  ' 2>/dev/null || echo 0)"
  [[ "$hits" =~ ^[0-9]+$ ]] && (( hits > 0 ))
}
