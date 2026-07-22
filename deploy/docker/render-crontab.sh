#!/usr/bin/env bash
#
# deploy/docker/render-crontab.sh — render the node's schedule from
# crontab.tmpl, writing over the baked crontab (design decision D5:
# per-node cycle offsets from one image).
#
# Why offsets exist: every active node spends the same Claude account and
# talks to the same GitHub repos. N nodes all firing at minute 0 is N heavy
# `claude` runs colliding on one quota and N clone/push bursts colliding on
# the same refs — the claims sort out correctness, but the collisions are
# pure waste. Spreading the fleet across the hour costs nothing and needs no
# coordination: each node's default minute is a stable hash of its own name.
#
#   CYCLE_MINUTE unset      → 1 + (sha256(NODE_NAME) mod 59), i.e. 1..59.
#   CYCLE_MINUTE=<1..59>    → exactly that.
#   CYCLE_MINUTE=<junk|0>   → a loud warning, then the hash default — a typo
#     must not silently move a node onto minute 0, which is deliberately
#     excluded everywhere: poetic's hourly sync workflow owns the top of the
#     hour.
#
# The review cycle runs at (CYCLE_MINUTE + 29) mod 60 past 03:00, keeping
# the two heavy pipelines on one node maximally apart within its hour.
#
# Failure never breaks the schedule: the output is written to a temp file
# and moved into place only when it rendered completely; on any failure the
# baked crontab — a valid, working schedule — stays, and the caller
# (entrypoint.sh) says so. Exit 0 iff the render was written.

set -uo pipefail

say() { printf 'render-crontab: %s\n' "$*" >&2; }

tmpl="${1:-/app/deploy/docker/crontab.tmpl}"
out="${2:-/app/deploy/docker/crontab}"

node="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"

hash_minute() {
  local h
  h="$(printf '%s' "$node" | sha256sum | cut -c1-8)"
  printf '%s' "$(( 1 + (0x$h % 59) ))"
}

cycle_minute=""
if [[ -n "${CYCLE_MINUTE:-}" ]]; then
  if [[ "$CYCLE_MINUTE" =~ ^[0-9]+$ ]] && (( 10#$CYCLE_MINUTE >= 1 && 10#$CYCLE_MINUTE <= 59 )); then
    cycle_minute="$(( 10#$CYCLE_MINUTE ))"
  else
    say "WARNING: CYCLE_MINUTE='$CYCLE_MINUTE' is not a minute in 1..59 (0 belongs to poetic's hourly sync) — using the hash default"
  fi
fi
[[ -n "$cycle_minute" ]] || cycle_minute="$(hash_minute)"
review_minute=$(( (cycle_minute + 29) % 60 ))

if [[ ! -f "$tmpl" ]]; then
  say "ERROR: template $tmpl is missing — the baked schedule stays"
  exit 1
fi

tmp="$(mktemp "$out.XXXXXX" 2>/dev/null)" || { say "ERROR: cannot write beside $out — the baked schedule stays"; exit 1; }
if ! sed -e "s/@CYCLE_MINUTE@/$cycle_minute/g" -e "s/@REVIEW_MINUTE@/$review_minute/g" "$tmpl" > "$tmp"; then
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
say "node $node: cycle at minute $cycle_minute, review at $review_minute past 03:00"
exit 0
