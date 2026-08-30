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
# under `state_dir` (`updater-ledger/<hostname>.jsonl`). `$HOSTNAME` tells a
# tailnet node's scheduler and dashboard containers apart — they share this
# state volume but not an identity — but it does not tell one *generation* of
# the same service from the next: watchtower clones `Config.Hostname` forward
# when it recreates a container (agent-ops#1072), so a roll's replacement
# inherits its predecessor's hostname and keeps appending to the very same
# file. Each line therefore also carries `started` — the epoch seconds the
# *writing* container's own PID 1 has been running since (`stat -c %Y
# /proc/1`), `null` when unreadable — the one field two lines in the same
# file can disagree on across a roll, and so the only thing that can answer
# "did the container reading this line write it?" Each line also carries
# `service` — the compose service name (`AGENT_OPS_SERVICE`: `scheduler`,
# `dashboard` or `dashboard-local`) the writing container ran as, `"unknown"`
# when unset. `updater_status` reads that ledger back and answers one of:
#
#   {status:"rolled", at, seconds}
#     the newest "allow" invocation this ledger can show was *not* written by
#     the container now reading it — either under a different hostname
#     entirely (from our own service, the ordinary post-roll case: no ledger
#     entry yet exists under this container's own name), or under this
#     container's own hostname file, but its trailing "allow" carries a
#     `started` different from this container's own: the roll that produced
#     this very container (agent-ops#1072), not evidence that it never
#     happened.
#   {status:"deferring", at, seconds}
#     our own most recent invocation deferred (EX_TEMPFAIL), every invocation
#     before it back to `at` did too, and that streak has not yet outlasted
#     what any lock this hook honours could legitimately hold — how long the
#     hook has been protecting a cycle in flight.
#   {status:"stuck", at, seconds, reason}
#     a fault only a human clears, either because (`reason:"allow"`) our own
#     most recent invocation allowed the roll — proven by `started` matching
#     this container's own, never by the hostname alone (agent-ops#1072) —
#     every invocation of that same generation back to `at` did too, and
#     `seconds` (now minus `at`) has already reached <stuck-after-seconds>
#     with this exact container still the one running; or because
#     (`reason:"defer"`) the defer streak above has itself outlasted
#     <defer-stuck-after-seconds>, past which no lock this hook honours could
#     still be legitimately held, so this is no longer "a cycle in flight".
#   null
#     no watchtower has ever polled this container (no ledger entry under
#     any hostname at all), our own newest entry is already older than
#     <stuck-after-seconds> (see "Liveness first" below), the most recent
#     "allow" from our own service anywhere already belongs to us with less
#     than <stuck-after-seconds> elapsed — too recent to call either "rolled"
#     or "stuck" yet — or the trailing entry under our own hostname carries no
#     `started` at all, or this container cannot read its own, so no identity
#     verdict is possible on the strength of that entry, in either direction
#     (agent-ops#1072). Never returns non-zero and never asserts a verdict
#     the ledger cannot support:
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
# The `allow` streak scan is bounded by `started` as well as by verdict: the
# unbroken run stops the moment `started` changes, not only when the verdict
# does. Without that, a container watchtower rolls repeatedly inside
# <stuck-after-seconds> — each roll's replacement appending its own genuine
# "allow" under the one hostname every replacement inherits — would read as
# one continuous streak spanning several *successful* rolls, `stuck` while
# everything is working (agent-ops#1072). The `defer` streak needs no such
# bound: the entry immediately before any roll is always an "allow" (that is
# what authorises the roll), so a defer streak can never itself straddle a
# generation boundary — the ordinary verdict-mismatch break already stops it
# there.
#
# Liveness first (agent-ops#1071, deciding agent-ops#1053): before either
# streak above is even read, our own hostname's newest entry — whatever its
# verdict — must itself be no older than <stuck-after-seconds>, or this
# returns null outright. Both self-states are claims about the present, and a
# ledger nothing has appended to in that long no longer supports one, however
# long the streak underneath it runs: a node whose watchtower stopped
# polling after one last "allow" (TD-PPagop-26082913) and a node genuinely
# stuck since that same "allow" are indistinguishable from the ledger alone
# once the newest line itself has gone that stale, so both get the same
# unanswerable reading rather than the first reading as a permanent, human-
# unclearable alarm. One gate, the same threshold that already bounds the
# `allow` streak — no second number for siblings. `rolled` below is exempt:
# it is a claim about the past, already carries its own age in `seconds`, and
# keeps the hook's 7-day prune as its only bound.
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

# _updater_health_live TS STUCK-AFTER-SECONDS NOW-EPOCH — true (exit 0) iff TS
# is no older than STUCK-AFTER-SECONDS as of NOW-EPOCH: a claim about the
# present needs an entry recent enough to still describe it (see the header's
# "Liveness first"). False — never a crash — for an unparseable TS or a
# STUCK-AFTER-SECONDS that is not a whole number of seconds too: neither
# supports an answer, and "no answer" is not liveness. A property of a file,
# not of a service — identical for this container's own ledger and any
# foreign one — so it takes no hostname or service of its own.
_updater_health_live() {
  local ts="$1" stuck_after="$2" now_epoch="$3" epoch=""
  [[ "$stuck_after" =~ ^[0-9]+$ ]] || return 1
  epoch="$(_updater_health_epoch "$ts")" || return 1
  (( now_epoch - epoch <= stuck_after ))
}

# _updater_health_own_started — epoch seconds this container's own PID 1 has
# been running since, or nothing if unreadable. Same source
# `deploy/docker/watchtower-pre-update.sh`'s `record_verdict` stamps into
# each ledger line it writes (`stat -c %Y /proc/1`) — this file runs inside
# the very same container whose ledger it reads back (state-sync.sh's and
# publish-dashboard.sh's own heartbeat pushes), so asking the question the
# same way is what makes the two comparable at all. `/proc/uptime` is
# deliberately not used: under Docker it reports the *host's* uptime, not
# this container's, and would read as "running since the host booted"
# regardless of when this container was actually created.
_updater_health_own_started() {
  stat -c %Y /proc/1 2>/dev/null
}

# _updater_health_last_entry FILE — prints "<verdict>\t<ts>\t<service>\t<started>"
# for a file's last line, or nothing if the file is missing, empty, its last
# line will not parse, or that line carries no verdict/timestamp. `service`
# defaults to "unknown" when the line predates that field; `started` is empty
# on the same terms (agent-ops#1072) — the caller decides what an absent
# identity supports, this function only reports it. File-scoped (never
# redefined per call) because in bash a function defined inside another
# becomes a global, unprefixed name in every script that sources this
# library — `publish-dashboard.sh` and `state-sync.sh` each source 20+ libs,
# so a name as generic as "last_entry" is one this file must not leave lying
# around in their shells.
_updater_health_last_entry() {
  local f="$1"
  [[ -s "$f" ]] || return 0
  local line="" verdict="" ts="" svc="" started=""
  line="$(tail -n 1 "$f" 2>/dev/null)"
  IFS=$'\t' read -r verdict ts svc started < <(
    jq -r 'try ((.verdict // "") + "\t" + (.ts // "") + "\t" + (.service // "unknown")
        + "\t" + ((.started // "") | tostring)) catch "\t\t\t"' \
      <<<"$line" 2>/dev/null
  )
  [[ -n "$verdict" && -n "$ts" ]] || return 0
  printf '%s\t%s\t%s\t%s\n' "$verdict" "$ts" "${svc:-unknown}" "$started"
}

# _updater_health_streak_start FILE VERDICT LAST-TS [WANT-STARTED] — the
# timestamp of the earliest entry in the unbroken run of VERDICT entries that
# ends at the file's last line, scanning backwards from the line before it
# and stopping at the first entry that is anything else, or at the start of
# the file. A line that will not parse is skipped — neither extending the
# streak nor ending it, since it supports neither reading. LAST-TS — the last
# line's own timestamp — is the answer when the run is one entry long. See
# the header: both self-states are streaks, and reading only the newest entry
# would time the last poll rather than the condition.
#
# WANT-STARTED, when given, additionally stops the streak the moment an
# entry's own `started` differs from it — an entry with no `started` at all
# stops it too, on the same "no identity verdict" reasoning as the caller's
# own check on the trailing entry (agent-ops#1072): without this, a run of
# same-verdict "allow"s spanning several genuine rolls under one inherited
# hostname would read as a single streak. Omit it (the `defer` caller does)
# to scan on verdict alone, since a defer streak cannot itself cross a
# generation boundary (see the header).
#
# One jq invocation for the whole file, not one per line: `updater_status`
# runs on every state-sync push and every dashboard publish, precisely in
# the stuck state this feature exists to detect, and a 48h ledger at
# watchtower's five-minute poll cadence is hundreds of lines. `-R` (raw
# input) plus `try … catch` keeps a single malformed line from aborting the
# whole parse, which slurping the file as JSON would do.
_updater_health_streak_start() {
  local f="$1" want="$2" start="$3" want_started="${4:-}" v="" t="" s=""
  local fields
  fields="$(jq -R -r 'try (fromjson | (.verdict // "") + "\t" + (.ts // "")
      + "\t" + ((.started // "") | tostring)) catch "\t\t"' \
    "$f" 2>/dev/null)" || { printf '%s\n' "$start"; return 0; }
  while IFS=$'\t' read -r v t s; do
    if [[ -z "$v" && -z "$t" ]]; then
      continue
    elif [[ "$v" == "$want" && -n "$t" ]] \
        && { [[ -z "$want_started" ]] || [[ "$s" == "$want_started" ]]; }; then
      start="$t"
    else
      break
    fi
  done < <(printf '%s\n' "$fields" | tac | tail -n +2)
  printf '%s\n' "$start"
}

# updater_status <ledger-dir> <stuck-after-seconds> <defer-stuck-after-seconds> [<hostname>] [<service>] [<started>]
updater_status() {
  local ledger_dir="${1:-}" stuck_after="${2:-}" defer_stuck_after="${3:-}" \
    host="${4:-}" service="${5:-}" started="${6:-}"
  [[ -n "$host" ]] || host="${HOSTNAME:-unknown}"
  [[ -n "$service" ]] || service="${AGENT_OPS_SERVICE:-unknown}"
  [[ -n "$started" ]] || started="$(_updater_health_own_started)"
  [[ -n "$ledger_dir" && -d "$ledger_dir" ]] || { printf 'null'; return 0; }

  local now_epoch=""
  now_epoch="$(date +%s)"

  local own_file="$ledger_dir/$host.jsonl"
  local own_entry="" verdict="" ts="" entry_started=""
  own_entry="$(_updater_health_last_entry "$own_file")"

  if [[ -n "$own_entry" ]]; then
    IFS=$'\t' read -r verdict ts _ entry_started <<<"$own_entry"

    # Liveness first: a claim about the present needs an own-hostname entry
    # recent enough to still describe it, before either streak below even
    # runs (see the header's "Liveness first"). Covers an unusable
    # `stuck_after` too — same as the old allow-only check this replaces,
    # now applied ahead of both branches, since it is the one gate for both.
    _updater_health_live "$ts" "$stuck_after" "$now_epoch" || { printf 'null'; return 0; }

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
      # Identity, not just hostname (agent-ops#1072): the trailing "allow"
      # under our own hostname file was not necessarily written by us — a
      # roll's replacement inherits its predecessor's hostname and keeps
      # appending to the same file. Only a `started` match proves this
      # container wrote it.
      if [[ -n "$started" && -n "$entry_started" && "$entry_started" == "$started" ]]; then
        local since="" ts_epoch="" elapsed=0
        since="$(_updater_health_streak_start "$own_file" allow "$ts" "$started")"
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

      if [[ -n "$started" && -n "$entry_started" ]]; then
        # Both sides are known and they disagree: this is provably a
        # different generation's entry — the roll that produced this
        # container, not evidence that it never happened.
        local ts_epoch="" elapsed=0
        ts_epoch="$(_updater_health_epoch "$ts")" || { printf 'null'; return 0; }
        elapsed=$(( now_epoch - ts_epoch ))
        (( elapsed >= 0 )) || elapsed=0
        jq -nc --arg at "$ts" --argjson s "$elapsed" '{status:"rolled", at:$at, seconds:$s}' \
          || printf 'null'
        return 0
      fi

      # Either side's start time is unreadable: no identity verdict is
      # possible on the strength of this entry, in either direction — never
      # "stuck" on a hostname match alone (see the header).
      printf 'null'
      return 0
    fi

    printf 'null'
    return 0
  fi

  # No invocation recorded under our own name yet. If some other container of
  # our own service ever recorded an "allow", the newest one is the roll that
  # produced us (see the header on why the scan is service-scoped).
  local newest_ts="" f entry v t svc entry_started
  for f in "$ledger_dir"/*.jsonl; do
    [[ -f "$f" ]] || continue
    [[ "${f##*/}" == "$host.jsonl" ]] && continue
    entry="$(_updater_health_last_entry "$f")"
    [[ -n "$entry" ]] || continue
    IFS=$'\t' read -r v t svc entry_started <<<"$entry"
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
