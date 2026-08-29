#!/usr/bin/env bash
#
# lib/updater-health.sh — has the update mechanism itself gone wrong, ahead of
# and independent of the drift it eventually causes?
#
# On 2026-08-14 watchtower on poetic-vm-1 tried to create two replacement
# containers it had never stopped, hit a name collision, and logged
# `Session done Failed=2` on every poll thereafter while the node stayed on
# the previous image — through a fleet roll carrying a fix the other three
# nodes had already taken. Nothing raised it: the node was healthy by every
# definition it had (agent-ops#603). `lib/image-drift.sh` deliberately
# tolerates `image_behind_grace_hours` of lag, because a roll waiting on a
# cycle already in flight is routine — but a roll watchtower has stopped even
# attempting is not drift at all, and would not have cleared on its own: the
# retry repeats the operation that collides.
#
# Nothing inside a container can read watchtower's log or the Docker socket
# (neither exists here, by design), so the one fact this side of the fence
# can ever learn is what `deploy/docker/watchtower-pre-update.sh` itself
# decided — which it records, one line per invocation, in a durable ledger
# under `state_dir` (`updater-ledger/<hostname>.jsonl`, keyed by container
# exactly as that script already keys lock ownership, since a tailnet node's
# scheduler and dashboard containers share this state volume but not an
# identity). Each line also carries `service` — the compose service name
# (`AGENT_OPS_SERVICE`: `scheduler`, `dashboard` or `dashboard-local`) the
# writing container ran as, `"unknown"` when unset. `updater_status` reads
# that ledger back and answers one of:
#
#   {status:"rolled", at, seconds}
#     the newest invocation this ledger knows of *from our own service*,
#     under any hostname, was an "allow" — and it was not us. Some container
#     of the same service was told to roll and this one, a different
#     hostname, is running in its place: the ordinary case.
#   {status:"deferring", at, seconds}
#     our own most recent invocation deferred (EX_TEMPFAIL), every invocation
#     before it back to `at` did too, and that streak has not yet outlasted
#     what any lock this hook honours could legitimately hold — how long the
#     hook has been protecting a cycle in flight.
#   {status:"stuck", at, seconds, reason}
#     a fault only a human clears, either because (`reason:"allow"`) our own
#     most recent invocation allowed the roll, every invocation back to `at`
#     did too, and `seconds` (now minus `at`) has already reached
#     <stuck-after-seconds> with this exact container — same hostname, so the
#     very container that was told to go ahead — still the one running; or
#     because (`reason:"defer"`) the defer streak above has itself outlasted
#     <defer-stuck-after-seconds>, past which no lock this hook honours could
#     still be legitimately held, so this is no longer "a cycle in flight".
#   null
#     no watchtower has ever polled this container (no ledger entry under
#     any hostname at all), or the most recent "allow" from our own service
#     anywhere already belongs to us with less than <stuck-after-seconds>
#     elapsed — too recent to call either "rolled" or "stuck" yet. Never
#     returns non-zero and never asserts a verdict the ledger cannot support:
#     this runs under `set -e` inside a heartbeat push, and an unanswerable
#     question is not a reason to abort one. A threshold that is not a whole
#     number of seconds, or a timestamp this file cannot parse, is one such
#     unanswerable question, and reads null (or, mid-streak, ends the streak
#     there) rather than guessing at a value this file has no business
#     choosing. Guessing is the one thing this file must never do with a
#     malformed timestamp: unlike `held_by()` in watchtower-pre-update.sh,
#     where an unparseable `started_at` reading as epoch 0 fails the lock
#     *open* (not honoured), the same convention here would fail *closed* —
#     into a "stuck"/"deferring" alarm nothing could ever clear, since a
#     corrupt line's own string timestamp can also defeat the hook's 48h
#     trim. So a timestamp this file cannot parse supports no verdict at all.
#
# Both of the states this container can be in for itself are *streaks*, not
# moments, and are measured from the streak's start. watchtower re-runs the
# hook on every poll for as long as the container is still stale — the hook's
# own header records `Failed=3 Scanned=3 Updated=0` "every five minutes for
# hours", and "each poll is answered independently" — so a container that is
# deferring, and equally one that allowed a roll that never happened, appends
# one entry per poll. Reading only the newest would measure the age of the
# last poll (under one `WATCHTOWER_POLL_INTERVAL`, 300s by default) rather
# than the age of the condition, and `stuck` — whose threshold is minutes of
# polls, not one — could then never be reached at all. A line that will not
# parse, mid-streak, is skipped rather than treated as ending the streak: one
# transient bad line must not silence an alarm four polls early, or reset the
# clock on a stuck container that has been running for hours.
#
# <stuck-after-seconds> is the caller's, not a literal here — the same shape
# `image_behind_grace_hours` already uses one layer up (config.schema.json's
# `updater_stuck_after_minutes`, read and converted by the caller) — so this
# file carries no config-reading of its own and no default that could drift
# from the schema's. <defer-stuck-after-seconds> is the caller's on the same
# terms: the natural bound on a legitimate defer streak is the longer of
# `lock_stale_after` and `project_review.lock_stale_after`, since past that
# point watchtower-pre-update.sh's own `held_by()` would no longer honour
# either lock — the caller derives it, this file only applies it.
#
# The "rolled" fallback scan is restricted to ledger entries carrying the
# same `service` this container itself runs as (passed in, since a fresh
# container has no ledger entry of its own to read one back from). Without
# that, a stuck sibling *of a different service* sharing this ledger
# directory — the scheduler and the dashboard mount the same state volume
# but are different services — keeps appending fresh "allow" entries every
# poll, and its ever-newer timestamp wins the "newest allow anywhere" scan
# even though it has nothing to do with why this container exists. Two
# containers of the *same* service never coexist (one replaces the other),
# so same-service filtering is exactly the scope that fallback needs.

# _updater_health_epoch TS — epoch seconds for TS on stdout, or nothing with
# a non-zero exit if TS cannot be parsed. The one place this file turns a
# timestamp into a number; every caller must treat a non-zero exit as "this
# entry supports no verdict", never default to epoch 0 (see the header).
_updater_health_epoch() {
  date -u -d "$1" +%s 2>/dev/null
}

# _updater_health_last_entry FILE — prints "<verdict>\t<ts>\t<service>" for a
# file's last line, or nothing if the file is missing, empty, its last line
# will not parse, or that line carries no verdict/timestamp. `service`
# defaults to "unknown" when the line predates that field. File-scoped
# (never redefined per call) because in bash a function defined inside
# another becomes a global, unprefixed name in every script that sources
# this library — `publish-dashboard.sh` and `state-sync.sh` each source 20+
# libs, so a name as generic as "last_entry" is one this file must not leave
# lying around in their shells.
_updater_health_last_entry() {
  local f="$1"
  [[ -s "$f" ]] || return 0
  local line="" verdict="" ts="" svc=""
  line="$(tail -n 1 "$f" 2>/dev/null)"
  IFS=$'\t' read -r verdict ts svc < <(
    jq -r 'try ((.verdict // "") + "\t" + (.ts // "") + "\t" + (.service // "unknown")) catch "\t\t"' \
      <<<"$line" 2>/dev/null
  )
  [[ -n "$verdict" && -n "$ts" ]] || return 0
  printf '%s\t%s\t%s\n' "$verdict" "$ts" "${svc:-unknown}"
}

# _updater_health_streak_start FILE VERDICT LAST-TS — the timestamp of the
# earliest entry in the unbroken run of VERDICT entries that ends at the
# file's last line, scanning backwards from the line before it and stopping
# at the first entry that is anything else, or at the start of the file. A
# line that will not parse is skipped — neither extending the streak nor
# ending it, since it supports neither reading. LAST-TS — the last line's own
# timestamp — is the answer when the run is one entry long. See the header:
# both self-states are streaks, and reading only the newest entry would time
# the last poll rather than the condition.
#
# One jq invocation for the whole file, not one per line: `updater_status`
# runs on every state-sync push and every dashboard publish, precisely in
# the stuck state this feature exists to detect, and a 48h ledger at
# watchtower's five-minute poll cadence is hundreds of lines. `-R` (raw
# input) plus `try … catch` keeps a single malformed line from aborting the
# whole parse, which slurping the file as JSON would do.
_updater_health_streak_start() {
  local f="$1" want="$2" start="$3" v="" t=""
  local fields
  fields="$(jq -R -r 'try (fromjson | (.verdict // "") + "\t" + (.ts // "")) catch "\t"' \
    "$f" 2>/dev/null)" || { printf '%s\n' "$start"; return 0; }
  while IFS=$'\t' read -r v t; do
    if [[ "$v" == "$want" && -n "$t" ]]; then
      start="$t"
    elif [[ -z "$v" && -z "$t" ]]; then
      continue
    else
      break
    fi
  done < <(printf '%s\n' "$fields" | tac | tail -n +2)
  printf '%s\n' "$start"
}

# updater_status <ledger-dir> <stuck-after-seconds> <defer-stuck-after-seconds> [<hostname>] [<service>]
updater_status() {
  local ledger_dir="${1:-}" stuck_after="${2:-}" defer_stuck_after="${3:-}" \
    host="${4:-}" service="${5:-}"
  [[ -n "$host" ]] || host="${HOSTNAME:-unknown}"
  [[ -n "$service" ]] || service="${AGENT_OPS_SERVICE:-unknown}"
  [[ -n "$ledger_dir" && -d "$ledger_dir" ]] || { printf 'null'; return 0; }

  local now_epoch=""
  now_epoch="$(date +%s)"

  local own_file="$ledger_dir/$host.jsonl"
  local own_entry="" verdict="" ts=""
  own_entry="$(_updater_health_last_entry "$own_file")"

  if [[ -n "$own_entry" ]]; then
    IFS=$'\t' read -r verdict ts _ <<<"$own_entry"

    if [[ "$verdict" == "defer" ]]; then
      local since="" start_epoch="" elapsed=0
      since="$(_updater_health_streak_start "$own_file" defer "$ts")"
      start_epoch="$(_updater_health_epoch "$since")" || { printf 'null'; return 0; }
      elapsed=$(( now_epoch - start_epoch ))
      (( elapsed >= 0 )) || elapsed=0
      if [[ "$defer_stuck_after" =~ ^[0-9]+$ ]] && (( elapsed >= defer_stuck_after )); then
        jq -nc --arg at "$since" --argjson s "$elapsed" \
          '{status:"stuck", at:$at, seconds:$s, reason:"defer"}' || printf 'null'
      else
        jq -nc --arg at "$since" --argjson s "$elapsed" '{status:"deferring", at:$at, seconds:$s}' \
          || printf 'null'
      fi
      return 0
    fi

    if [[ "$verdict" == "allow" ]]; then
      # A threshold this function cannot read is a question it cannot answer:
      # neither "stuck" nor "not stuck" is supportable, so say nothing. The
      # caller owns the number (config.json's `updater_stuck_after_minutes`),
      # and inventing one here is exactly the drift the header rules out.
      [[ "$stuck_after" =~ ^[0-9]+$ ]] || { printf 'null'; return 0; }
      local since="" ts_epoch="" elapsed=0
      since="$(_updater_health_streak_start "$own_file" allow "$ts")"
      ts_epoch="$(_updater_health_epoch "$since")" || { printf 'null'; return 0; }
      elapsed=$(( now_epoch - ts_epoch ))
      (( elapsed >= 0 )) || elapsed=0
      if (( elapsed >= stuck_after )); then
        jq -nc --arg at "$since" --argjson s "$elapsed" \
          '{status:"stuck", at:$at, seconds:$s, reason:"allow"}' || printf 'null'
      else
        printf 'null'
      fi
      return 0
    fi

    printf 'null'
    return 0
  fi

  # No invocation recorded under our own name yet. If some other container of
  # our own service ever recorded an "allow", the newest one is the roll that
  # produced us (see the header on why the scan is service-scoped).
  local newest_ts="" f entry v t svc
  for f in "$ledger_dir"/*.jsonl; do
    [[ -f "$f" ]] || continue
    [[ "${f##*/}" == "$host.jsonl" ]] && continue
    entry="$(_updater_health_last_entry "$f")"
    [[ -n "$entry" ]] || continue
    IFS=$'\t' read -r v t svc <<<"$entry"
    [[ "$v" == "allow" ]] || continue
    [[ "$svc" == "$service" ]] || continue
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || continue
    if [[ -z "$newest_ts" || "$t" > "$newest_ts" ]]; then
      newest_ts="$t"
    fi
  done

  if [[ -n "$newest_ts" ]]; then
    local ts_epoch="" elapsed=0
    ts_epoch="$(_updater_health_epoch "$newest_ts")" || { printf 'null'; return 0; }
    elapsed=$(( now_epoch - ts_epoch ))
    (( elapsed >= 0 )) || elapsed=0
    jq -nc --arg at "$newest_ts" --argjson s "$elapsed" '{status:"rolled", at:$at, seconds:$s}' \
      || printf 'null'
    return 0
  fi

  printf 'null'
  return 0
}
