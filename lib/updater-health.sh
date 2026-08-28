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
# identity). `updater_status` reads that ledger back and answers one of:
#
#   {status:"rolled", at, seconds}
#     the newest invocation this ledger knows of, under any hostname, was an
#     "allow" — and it was not us. Some container was told to roll and this
#     one, a different hostname, is running in its place: the ordinary case.
#   {status:"deferring", at, seconds}
#     our own most recent invocation deferred (EX_TEMPFAIL), and every
#     invocation before it back to `at` did too — how long the hook has been
#     protecting a cycle in flight.
#   {status:"stuck", at, seconds}
#     our own most recent invocation allowed the roll, at `at`, and
#     `seconds` (now minus `at`) has already reached <stuck-after-seconds>
#     with this exact container — same hostname, so the very container that
#     was told to go ahead — still the one running. "Same $HOSTNAME still
#     running after an allowed roll" is the entire signature: it needs
#     nothing watchtower has to tell us, because it is the one thing this
#     side of the fence can observe for itself.
#   null
#     no watchtower has ever polled this container (no ledger entry under
#     any hostname at all), or the most recent "allow" anywhere already
#     belongs to us with less than <stuck-after-seconds> elapsed — too
#     recent to call either "rolled" or "stuck" yet. Never returns non-zero
#     and never asserts a verdict the ledger cannot support: this runs under
#     `set -e` inside a heartbeat push, and an unanswerable question is not a
#     reason to abort one.
#
# <stuck-after-seconds> is the caller's, not a literal here — the same shape
# `image_behind_grace_hours` already uses one layer up (config.schema.json's
# `updater_stuck_after_minutes`, read and converted by the caller) — so this
# file carries no config-reading of its own and no default that could drift
# from the schema's.
#
# A malformed or unparseable timestamp reads as epoch 0 — impossibly old —
# the same convention `held_by()` in watchtower-pre-update.sh already uses
# for the identical reason: a fact this file cannot establish must not read
# as healthier than one it can.

# updater_status <ledger-dir> <stuck-after-seconds> [<hostname>]
updater_status() {
  local ledger_dir="${1:-}" stuck_after="${2:-0}" host="${3:-${HOSTNAME:-}}"
  [[ -n "$ledger_dir" && -d "$ledger_dir" && -n "$host" ]] || { printf 'null'; return 0; }

  local now_epoch=""
  now_epoch="$(date +%s)"

  # last_entry FILE — prints "<verdict> <ts>" for a file's last line, or
  # nothing if the file is missing, empty or its last line will not parse.
  last_entry() {
    local f="$1"
    [[ -s "$f" ]] || return 0
    local line="" verdict="" ts=""
    line="$(tail -n 1 "$f" 2>/dev/null)"
    verdict="$(jq -r '.verdict // empty' <<<"$line" 2>/dev/null || true)"
    ts="$(jq -r '.ts // empty' <<<"$line" 2>/dev/null || true)"
    [[ -n "$verdict" && -n "$ts" ]] || return 0
    printf '%s %s\n' "$verdict" "$ts"
  }

  local own_file="$ledger_dir/$host.jsonl"
  local own_entry=""
  own_entry="$(last_entry "$own_file")"

  if [[ -n "$own_entry" ]]; then
    local verdict="${own_entry%% *}" ts="${own_entry#* }"

    if [[ "$verdict" == "defer" ]]; then
      # The earliest contiguous "defer" reading backward from the end: the
      # start of the current streak. A verdict other than "defer" — or the
      # start of the file — ends the scan.
      local streak_start="$ts" line v2 t2
      while IFS= read -r line; do
        v2="$(jq -r '.verdict // empty' <<<"$line" 2>/dev/null || true)"
        t2="$(jq -r '.ts // empty' <<<"$line" 2>/dev/null || true)"
        [[ "$v2" == "defer" && -n "$t2" ]] || break
        streak_start="$t2"
      done < <(tac "$own_file" 2>/dev/null | tail -n +2)
      local start_epoch=0 elapsed=0
      start_epoch="$(date -u -d "$streak_start" +%s 2>/dev/null || echo 0)"
      elapsed=$(( now_epoch - start_epoch ))
      (( elapsed >= 0 )) || elapsed=0
      jq -nc --arg at "$streak_start" --argjson s "$elapsed" '{status:"deferring", at:$at, seconds:$s}'
      return 0
    fi

    if [[ "$verdict" == "allow" ]]; then
      local ts_epoch=0 elapsed=0
      ts_epoch="$(date -u -d "$ts" +%s 2>/dev/null || echo 0)"
      elapsed=$(( now_epoch - ts_epoch ))
      (( elapsed >= 0 )) || elapsed=0
      if (( elapsed >= stuck_after )); then
        jq -nc --arg at "$ts" --argjson s "$elapsed" '{status:"stuck", at:$at, seconds:$s}'
      else
        printf 'null'
      fi
      return 0
    fi

    printf 'null'
    return 0
  fi

  # No invocation recorded under our own name yet. If some other container
  # ever recorded an "allow", the newest one is the roll that produced us.
  local newest_ts="" f entry v t
  for f in "$ledger_dir"/*.jsonl; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "$host.jsonl" ]] && continue
    entry="$(last_entry "$f")"
    [[ -n "$entry" ]] || continue
    v="${entry%% *}" t="${entry#* }"
    [[ "$v" == "allow" ]] || continue
    if [[ -z "$newest_ts" || "$t" > "$newest_ts" ]]; then
      newest_ts="$t"
    fi
  done

  if [[ -n "$newest_ts" ]]; then
    local ts_epoch=0 elapsed=0
    ts_epoch="$(date -u -d "$newest_ts" +%s 2>/dev/null || echo 0)"
    elapsed=$(( now_epoch - ts_epoch ))
    (( elapsed >= 0 )) || elapsed=0
    jq -nc --arg at "$newest_ts" --argjson s "$elapsed" '{status:"rolled", at:$at, seconds:$s}'
    return 0
  fi

  printf 'null'
  return 0
}
