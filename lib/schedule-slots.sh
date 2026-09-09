#!/usr/bin/env bash
#
# lib/schedule-slots.sh — which schedule slots fell inside a cycle's own run
# (agent-ops#1287). supercronic will not start a job while the previous run
# of that job is still running: it logs the drop to the container log and
# nothing else records it, so a cycle that runs long loses its fleet a whole
# slot (or several) with no event of any kind in `log.jsonl`. `cleanup()`
# (agent-cycle.sh, requirement 11a) calls `schedule_overrun_slots` at the end
# of every cycle, before the lock releases, and logs one `cycle-skipped
# {reason: "overlap", ...}` per slot it returns.
#
# One pure function, on the same terms lib/node-time-state.sh's fold is: it
# never reads the log, never touches state_dir, and knows nothing about
# `cycle_id` — the caller shapes what this returns into the documented event.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# schedule_overrun_slots START_ISO END_ISO SCHEDULE_JSON
#
# Prints one ISO-8601 UTC timestamp per line, ascending, for each slot of the
# series based on START_ISO's own minute-of-hour (see below) that falls
# strictly after START_ISO and at or before END_ISO — firings supercronic
# silently dropped because this cycle, which started at START_ISO, was still
# holding the lock at each of them. SCHEDULE_JSON is
# the already-defaulted `schedule` config block ({cycle_hours,
# cycle_interval_minutes, excluded_minutes} — `config_defaults`'s own
# output, requirement 1b). Prints nothing (never fails) if START_ISO/END_ISO
# do not parse, or if the span holds no further slot.
#
# START_ISO's own minute-of-hour is taken as the series base directly — there
# is no need to re-derive it by re-hashing NODE_NAME the way
# `deploy/docker/render-crontab.sh`'s own `hash_minute()` does, and doing so
# here would risk drifting from whatever the real crontab actually fired on.
# Every later slot simply repeats that script's own
# restart-at-the-base-minute-each-hour pattern going forward from START_ISO's
# hour.
#
# That base is only as good as START_ISO, and this function has no way to
# check it: it is meaningful precisely when START_ISO is a minute supercronic
# already chose to fire on (the crontab that script renders never fires
# outside one). The caller owns that precondition — `cleanup()` gates its call
# on the cycle being the cron-fired original (requirement 11a), since a
# chained continuation or a `--once`/`--dry-run` run starts at an arbitrary
# minute-of-hour and would make every slot named here a fabrication.
#
# That series is the node's whole slot set only when START_ISO fell on the
# lowest kept minute of its hour. A cycle that fired on a later kept minute
# yields a proper subset — no slot at any earlier minute-of-hour of any
# subsequent hour — because one firing minute does not identify which of the
# hour's kept minutes is the base (:55 at a 15-minute interval is equally
# consistent with a base of 10, 25, 40 or 55; recovering it needs a second
# input this function is not given). The error is one-sided: every slot
# printed is one the crontab really would have fired, so the caller's count
# is a lower bound on the firings lost, never an overstatement
# (agent-ops#1324).
#
# `parse_cycle_hours`/`kept_minutes` below are deliberately the same
# grammar and shape as `lib/config-schema.sh`'s `config_defaults` (cadence_gaps,
# requirement 1d) — a cron hour field (`*`, `*/N`, `a-b`, `a-b/N`, plain
# numbers, comma-combined) into the set of allowed hours 0..23, and a base
# minute into the kept firing minutes within one allowed hour — copied
# rather than shared because jq has no mechanism to import a function
# between two independent `jq` invocations; keep the two in step by hand if
# the grammar ever changes. Unlike that derivation, this one is not a
# worst-case estimate: it walks real slot instants across the actual
# [START_ISO, END_ISO] span, using this cycle's own real base minute.
schedule_overrun_slots() {
  local start_iso="$1" end_iso="$2" schedule_json="$3"
  jq -nr --arg start "$start_iso" --arg end "$end_iso" --argjson sched "$schedule_json" '
    def parse_hour_token($t):
        if $t == "*" then [range(0;24)]
        elif ($t | test("^\\*/[0-9]+$")) then
          ($t | sub("^\\*/"; "") | tonumber) as $step
          | (if $step > 0 then [range(0;24;$step)] else [range(0;24)] end)
        elif ($t | test("^[0-9]+-[0-9]+/[0-9]+$")) then
          ($t | capture("^(?<a>[0-9]+)-(?<b>[0-9]+)/(?<s>[0-9]+)$")) as $c
          | ($c.a | tonumber) as $a | ($c.b | tonumber) as $b | ($c.s | tonumber) as $s
          | (if $a <= $b and $a < 24 and $s > 0 then [range($a; ([$b+1,24] | min); $s)] else [] end)
        elif ($t | test("^[0-9]+-[0-9]+$")) then
          ($t | capture("^(?<a>[0-9]+)-(?<b>[0-9]+)$")) as $c
          | ($c.a | tonumber) as $a | ($c.b | tonumber) as $b
          | (if $a <= $b and $a < 24 then [range($a; ([$b+1,24] | min))] else [] end)
        elif ($t | test("^[0-9]+$")) then
          ($t | tonumber) as $n | (if $n >= 0 and $n < 24 then [$n] else [] end)
        else []
        end;
    def parse_cycle_hours($s):
        ( ($s // "*") | split(",") | map(parse_hour_token(.)) | add // [] )
        | unique | sort;
    def kept_minutes($s; $interval; $excluded):
        [range($s; 60; $interval)] - $excluded;

    (try ($start | fromdateiso8601) catch null) as $start_s
    | (try ($end | fromdateiso8601) catch null) as $end_s
    | if $start_s == null or $end_s == null or $end_s <= $start_s then empty else
      (if ($sched.cycle_hours | type) == "string" then $sched.cycle_hours else "*" end) as $hours
      | (if ($sched.cycle_interval_minutes | type) == "number" and $sched.cycle_interval_minutes > 0
         then $sched.cycle_interval_minutes else 60 end) as $interval
      | (if ($sched.excluded_minutes | type) == "array"
         then ($sched.excluded_minutes | map(select(type == "number"))) else [] end) as $excluded
      | (parse_cycle_hours($hours)) as $allowed_hours
      | ($start_s | gmtime) as $start_bd
      | ($start_bd[4]) as $base_minute
      | (kept_minutes($base_minute; $interval; $excluded) | unique | sort) as $minutes
      | ((($end_s - $start_s) / 3600 | floor) + 2) as $hour_span
      | [ range(0; $hour_span) as $h
          | ($start_bd | .[3] += $h | .[4] = 0 | .[5] = 0 | mktime) as $hour_epoch
          | ($hour_epoch | gmtime | .[3]) as $hour_of_day
          | select(($allowed_hours | length) == 0 or ($allowed_hours | index($hour_of_day)) != null)
          | $minutes[] as $m
          | ($hour_epoch + ($m * 60)) as $candidate
          | select($candidate > $start_s and $candidate <= $end_s)
          | $candidate ]
      | unique
      | .[]
      | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")
      end
  '
}
