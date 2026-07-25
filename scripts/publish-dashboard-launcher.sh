#!/usr/bin/bash
#
# publish-dashboard-launcher.sh — sub-minute dashboard heartbeat.
#
# cron can't fire more than once a minute, so cron launches this once every
# 5 minutes and it self-loops on 5-second boundaries for ~295s (leaving a
# ~5s gap so consecutive cron runs don't overlap). Each tick regenerates the
# dashboard; a full GitHub-hitting refresh runs only when the last one has
# aged out (~5 minutes), with the cheap local-only --no-github refresh in
# between — so the page stays near-live without hammering the GitHub API.

set -uo pipefail

startat=$EPOCHSECONDS
# LAUNCHER_WINDOW exists for the test suite, which cannot wait five minutes;
# cron always runs the default.
endat=$(( startat + ${LAUNCHER_WINDOW:-295} ))
# A tick started in the window's final seconds finishes after it, and the
# overrun collides with the next cron-fired launcher. Ten seconds covers a
# publish that misses its 5-second budget once.
tick_margin=10

scriptdir="$(cd "$(dirname "$0")" && pwd)"
appdir="$(dirname "$scriptdir")"
# LAUNCHER_PUBLISH_CMD exists for the test suite, which must be able to watch
# which mode each tick chose without a network call; cron always runs the
# Publisher itself.
cmd="${LAUNCHER_PUBLISH_CMD:-$scriptdir/publish-dashboard.sh}"

# Derive the state dir from config.json (same source publish-dashboard.sh
# uses) so the lock and log always land where the dashboard is written.
expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
logdir="$(expand_home "$(jq -r '.state_dir' "$appdir/config.json")")"
log="${1:-$logdir/dashboard.log}"
lck="$logdir/dashboard.lck"

# Which ticks talk to GitHub, decided by the age of the last real fetch rather
# than by the wall clock. publish-dashboard.sh stamps this file on every fetch
# it *attempts* — success or failure alike — so the gate is both self-healing
# and self-limiting: a missed cron window, a publish that overran its 5-second
# budget, or a GitHub outage all resolve to "the next tick is the one that
# fetches", and none of them can turn into a retry storm.
#
# It replaces `(( EPOCHSECONDS % 300 < 5 ))`, which could not fire. The sleep
# below always lands a tick on an exact multiple of 5, so that test meant
# `% 300 == 0`; a window opened by a `*/5` cron entry starts on a 300-second
# boundary and runs from offset +5 to +285, so the one instant it needed was
# the one instant the loop never reached. In practice the GitHub panels
# refreshed only when cron's sub-second jitter happened to put the first tick
# on the boundary — every half hour or worse, not every five minutes, and
# with nothing anywhere saying so.
#
# 285 rather than 300: the stamp is written when a fetch *finishes*, so the
# gap between fetches is this plus however long one takes (~20s on a two-repo
# node). Ageing out slightly early keeps the observed cadence at five minutes
# instead of drifting past it.
gh_cache="$logdir/.dashboard-github.json"
gh_max_age="${LAUNCHER_GITHUB_MAX_AGE:-285}"

# The very first thing we touch is the lock/log in $logdir, before
# publish-dashboard.sh gets a chance to create it — make sure it exists.
mkdir -p "$logdir"

# A container killed mid-append (a watchtower roll, TD26072301) can leave the
# log's size recorded while the data blocks behind the last few writes never
# reach disk: they read back as NUL bytes. `ockham-container` carries one such
# hole — 652 bytes, four whole lines, between two intact ones.
#
# The lost lines are lost. What matters is what the hole does to every *later*
# read: one NUL anywhere makes the whole file binary, and grep then stops
# printing matches for all 8 MB of plain text around it. GNU grep at least says
# "binary file matches"; ugrep, which is what `grep` resolves to on the node
# owner's own shell, prints nothing and exits 1 — indistinguishable from "the
# heartbeat has never logged a refresh". That is precisely the wrong failure
# for the one file you open when something is wrong, and it persists for the
# life of the log.
#
# So strip the NULs once per window and record what was dropped, rather than
# closing the gap silently — the loss is a fact about the node worth keeping.
# Cost when there is nothing to do (the normal case) is one read of the log and
# no write; the rewrite is safe because every writer here reopens by name per
# append, so none of them holds a descriptor across the rename.
repair_log() {
  [[ -s "$log" ]] || return 0
  local size clean tmp
  size="$(stat -c %s "$log" 2>/dev/null)" || return 0
  clean="$(tr -d '\0' < "$log" 2>/dev/null | wc -c)" || return 0
  (( clean < size )) || return 0
  tmp="$log.repair.$$"
  if tr -d '\0' < "$log" > "$tmp" 2>/dev/null; then
    printf '%(%Y-%m-%dT%H:%M:%S%z)T repaired: dropped %s NUL byte(s) — an unclean stop lost the log lines in flight (TD26072301)\n' \
      -1 "$(( size - clean ))" >> "$tmp"
    mv "$tmp" "$log"
  else
    rm -f "$tmp"
  fi
}
repair_log

while (( EPOCHSECONDS < endat - tick_margin )); do
  github=(--no-github)
  sleep $(( 5 - EPOCHSECONDS % 5 ))
  gh_at="$(stat -c %Y "$gh_cache" 2>/dev/null)" || gh_at=0
  if (( EPOCHSECONDS - ${gh_at:-0} >= gh_max_age )); then
    github=()
    # One line every five minutes, and the only record anywhere of when the
    # GitHub-sourced panels were last actually refreshed — the symptom this
    # gate's predecessor produced was a page that looked healthy while its PR
    # list quietly aged, with nothing in the log to say so.
    if (( gh_at > 0 )); then age="$(( EPOCHSECONDS - gh_at ))s ago"; else age="never"; fi
    printf '%(%Y-%m-%dT%H:%M:%S%z)T github: refreshing (last fetch %s)\n' -1 "$age" >>"$log"
  fi
  # -E 111: distinguish "another publish holds the lock" (skip, don't stack
  # up) from a genuine publish failure, and leave a trace so a stuck lock
  # doesn't look like a quiet system.
  flock -n -E 111 "$lck" "$cmd" "${github[@]}" >>"$log" 2>&1
  rc=$?
  if (( rc == 111 )); then
    # Not our turn and no fetch happened, so the stamp is deliberately left
    # alone: the next tick inherits the attempt rather than losing the window.
    printf '%(%Y-%m-%dT%H:%M:%S%z)T skipped: publish already running\n' -1 >>"$log"
  elif (( ${#github[@]} == 0 )); then
    # A GitHub tick ran. The Publisher stamps the file itself at the end of
    # any fetch it reaches, but one that dies before then — a missing binary,
    # a killed process — would leave the stamp untouched and put every
    # following tick back into GitHub mode, five seconds apart. Stamping the
    # attempt here bounds that to one try per window, whatever happened.
    touch "$gh_cache" 2>/dev/null || true
  fi
done

# A healthy window must end 0. Without this, the script's status is that of
# the last loop-body command — the `(( rc == 111 ))` bookkeeping above, which
# is 1 (false) after every *successful* publish — and supercronic reports the
# whole window as failed every five minutes, drowning real failures in noise.
exit 0
