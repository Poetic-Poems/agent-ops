#!/usr/bin/bash
#
# publish-dashboard-launcher.sh — sub-minute dashboard heartbeat.
#
# cron can't fire more than once a minute, so cron launches this once every
# 5 minutes and it self-loops on 5-second boundaries for ~295s (leaving a
# ~5s gap so consecutive cron runs don't overlap). Each tick regenerates the
# dashboard; a full GitHub-hitting refresh runs only once per 5-minute
# window (at the top), with the cheap local-only --no-github refresh in
# between — so the page stays near-live without hammering the GitHub API.

set -uo pipefail

startat=$EPOCHSECONDS
endat=$(( startat + 295 ))

scriptdir="$(cd "$(dirname "$0")" && pwd)"
appdir="$(dirname "$scriptdir")"
cmd="$scriptdir/publish-dashboard.sh"

# Derive the state dir from config.json (same source publish-dashboard.sh
# uses) so the lock and log always land where the dashboard is written.
expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
logdir="$(expand_home "$(jq -r '.state_dir' "$appdir/config.json")")"
log="${1:-$logdir/dashboard.log}"
lck="$logdir/dashboard.lck"

# The very first thing we touch is the lock/log in $logdir, before
# publish-dashboard.sh gets a chance to create it — make sure it exists.
mkdir -p "$logdir"

while (( EPOCHSECONDS < endat )); do
  github=--no-github
  sleep $(( 5 - EPOCHSECONDS % 5 ))
  (( EPOCHSECONDS % 300 < 5 )) && github=
  # -E 111: distinguish "another publish holds the lock" (skip, don't stack
  # up) from a genuine publish failure, and leave a trace so a stuck lock
  # doesn't look like a quiet system.
  flock -n -E 111 "$lck" "$cmd" $github >>"$log" 2>&1
  (( $? == 111 )) && printf '%(%Y-%m-%dT%H:%M:%S%z)T skipped: publish already running\n' -1 >>"$log"
done
