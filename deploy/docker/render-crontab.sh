#!/usr/bin/env bash
#
# deploy/docker/render-crontab.sh — render the node's schedule from
# crontab.tmpl and config.json's `schedule`, writing over the baked crontab
# (design decision D5: per-node cycle offsets from one image).
#
# Why offsets exist: every active node spends the same Claude account and
# talks to the same GitHub repos. N nodes all firing at the same minute is N
# heavy `claude` runs colliding on one quota and N clone/push bursts
# colliding on the same refs — the claims sort out correctness, but the
# collisions are pure waste. Spreading the fleet across the hour costs
# nothing and needs no coordination: each node's default minute is a stable
# hash of its own name, drawn only from the minutes `schedule.excluded_minutes`
# does not rule out.
#
#   CYCLE_MINUTE unset            → a stable hash of NODE_NAME onto an
#     allowed minute (0..59 minus `schedule.excluded_minutes`).
#   CYCLE_MINUTE=<allowed minute> → exactly that.
#   CYCLE_MINUTE=<excluded|junk>  → a loud warning, then the hash default —
#     a typo must not silently land a node on an excluded minute.
#
# The review cycle runs at `schedule.review_offset_minutes` past
# CYCLE_MINUTE (mod 60), past `schedule.review_hour` — keeping one node's
# two heavy pipelines maximally apart within its hour.
#
# Failure never breaks the schedule: the output is written to a temp file
# and moved into place only when it rendered completely; on any failure the
# baked crontab — a valid, working schedule — stays, and the caller
# (entrypoint.sh) says so. Exit 0 iff the render was written.

set -uo pipefail

say() { printf 'render-crontab: %s\n' "$*" >&2; }

# The repository root, however this script is invoked — needed to find
# lib/config-schema.sh and config.schema.json regardless of which config the
# caller names (a test may point `config` at a throwaway fixture with no
# schema file of its own beside it).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"

tmpl="${1:-/app/deploy/docker/crontab.tmpl}"
out="${2:-/app/deploy/docker/crontab}"
config="${3:-/app/config.json}"

node="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"

if [[ ! -f "$config" ]]; then
  say "ERROR: config $config is missing — the baked schedule stays"
  exit 1
fi

# config_defaults fills in every schedule.* default (requirement/issue #197),
# so a deployment that ships no `schedule` block at all — "absent, every
# field below takes its default" — renders identically to one that spells
# every field out.
defaulted="$(config_defaults "$config" "$SCRIPT_DIR/config.schema.json" 2>/dev/null)"
if [[ -z "$defaulted" ]]; then
  say "ERROR: config $config is not valid JSON — the baked schedule stays"
  exit 1
fi

cfg() { jq -r "$1" <<<"$defaulted" 2>/dev/null; }
cfg_json() { jq -c "$1" <<<"$defaulted" 2>/dev/null; }

excluded_minutes="$(cfg_json '.schedule.excluded_minutes')"
review_hour="$(cfg '.schedule.review_hour')"
review_offset="$(cfg '.schedule.review_offset_minutes')"
cycle_hours="$(cfg '.schedule.cycle_hours')"
cycle_interval="$(cfg '.schedule.cycle_interval_minutes')"
heartbeat_minutes="$(cfg '.schedule.heartbeat_minutes')"
push_minutes="$(cfg '.schedule.state_sync_push_minutes')"
fetch_minutes="$(cfg '.schedule.state_sync_fetch_minutes')"
rotation_minute="$(cfg '.schedule.log_rotation_minute')"

if ! jq -e 'type == "array" and all(.[]; type == "number")' <<<"$excluded_minutes" >/dev/null 2>&1; then
  say "ERROR: $config's schedule.excluded_minutes is not an array of numbers — the baked schedule stays"
  exit 1
fi

if ! [[ "$cycle_interval" =~ ^[0-9]+$ ]] || (( cycle_interval < 1 || cycle_interval > 60 )); then
  say "ERROR: $config's schedule.cycle_interval_minutes is not an integer in 1..60 — the baked schedule stays"
  exit 1
fi

is_excluded() {
  jq -e --argjson m "$1" 'index($m) != null' <<<"$excluded_minutes" >/dev/null 2>&1
}

# The default minute: a stable hash of the node's name onto whichever
# minutes schedule.excluded_minutes leaves standing. Excluding nothing
# reduces this to `hash mod 60`; excluding just minute 0 reduces it to
# exactly the historical `1 + (hash mod 59)` shape, just expressed
# generally enough to exclude any set a deployment names.
hash_minute() {
  local h dec allowed k idx
  h="$(printf '%s' "$node" | sha256sum | cut -c1-8)"
  dec=$(( 0x$h ))
  allowed="$(jq -c -n --argjson excluded "$excluded_minutes" '[range(0;60)] - $excluded')"
  k="$(jq 'length' <<<"$allowed")"
  (( k > 0 )) || return 1
  idx=$(( dec % k ))
  jq -r --argjson i "$idx" '.[$i]' <<<"$allowed"
}

cycle_minute=""
if [[ -n "${CYCLE_MINUTE:-}" ]]; then
  if [[ "$CYCLE_MINUTE" =~ ^[0-9]+$ ]] && (( 10#$CYCLE_MINUTE <= 59 )) && ! is_excluded "$(( 10#$CYCLE_MINUTE ))"; then
    cycle_minute="$(( 10#$CYCLE_MINUTE ))"
  else
    say "WARNING: CYCLE_MINUTE='$CYCLE_MINUTE' is not an allowed minute (0..59, minus $config's schedule.excluded_minutes) — using the hash default"
  fi
fi
if [[ -z "$cycle_minute" ]]; then
  if ! cycle_minute="$(hash_minute)"; then
    say "ERROR: $config's schedule.excluded_minutes excludes every minute of the hour — no minute left to hash onto"
    exit 1
  fi
fi
review_minute=$(( (cycle_minute + review_offset) % 60 ))

# The implementation cycle fires every schedule.cycle_interval_minutes past
# cycle_minute within an allowed hour (issue #248, "faster heartbeat"):
# cycle_minute, cycle_minute+interval, cycle_minute+2*interval, ... while
# still under 60, each occurrence dropped (not shifted) if it lands on an
# excluded minute — cycle_minute itself never is, so the list is never
# empty. cron's minute field accepts an explicit comma list exactly like
# this, so no step-syntax gymnastics are needed. cycle_interval=60
# reproduces the historical one-firing-per-hour shape exactly, since the
# second occurrence (cycle_minute+60) is already >= 60.
cycle_minutes="$cycle_minute"
m=$(( cycle_minute + cycle_interval ))
while (( m < 60 )); do
  is_excluded "$m" || cycle_minutes="$cycle_minutes,$m"
  m=$(( m + cycle_interval ))
done

if [[ ! -f "$tmpl" ]]; then
  say "ERROR: template $tmpl is missing — the baked schedule stays"
  exit 1
fi

tmp="$(mktemp "$out.XXXXXX" 2>/dev/null)" || { say "ERROR: cannot write beside $out — the baked schedule stays"; exit 1; }
if ! sed \
      -e "s#@CYCLE_MINUTE@#$cycle_minutes#g" \
      -e "s#@CYCLE_HOURS@#$cycle_hours#g" \
      -e "s#@REVIEW_MINUTE@#$review_minute#g" \
      -e "s#@REVIEW_HOUR@#$review_hour#g" \
      -e "s#@HEARTBEAT_MINUTES@#$heartbeat_minutes#g" \
      -e "s#@STATE_SYNC_PUSH_MINUTES@#$push_minutes#g" \
      -e "s#@STATE_SYNC_FETCH_MINUTES@#$fetch_minutes#g" \
      -e "s#@LOG_ROTATION_MINUTE@#$rotation_minute#g" \
      "$tmpl" > "$tmp"; then
  rm -f "$tmp"
  say "ERROR: rendering $tmpl failed — the baked schedule stays"
  exit 1
fi
if grep -q '@[A-Z_]\{1,\}@' "$tmp"; then
  rm -f "$tmp"
  say "ERROR: $tmpl contains a placeholder this renderer does not know — the baked schedule stays"
  exit 1
fi
mv -f "$tmp" "$out"
say "node $node: cycle at minute(s) $cycle_minutes past $cycle_hours (every ${cycle_interval}m), review at $review_minute past $review_hour:00"
exit 0
