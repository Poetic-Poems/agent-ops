#!/usr/bin/env bash
#
# deploy/docker/egress-proxy-start.sh — entrypoint of the egress-proxy
# service (D24; IMPLEMENTATION-PIPELINE-SPEC, "The node stack").
#
# Merges the image's baked allowlist with the node's own EGRESS_EXTRA_ALLOW
# (comma- or whitespace-separated domains from .env — a custom Vercel
# preview domain is the expected case) into the one file
# egress-proxy.conf reads, then runs squid in the foreground.
#
# This replaces the image's normal entrypoint deliberately: the proxy runs
# no cycles and needs none of entrypoint.sh's gates — in particular it must
# not require the state volume writable, which it mounts read-only solely so
# watchtower-pre-update.sh can honour a running cycle's lock.
#
# `set -e` on purpose, unlike the cycle scripts: any failure here must kill
# the container loudly — a proxy that starts without its allowlist would
# either fence nothing or refuse everything, and both should look like a
# crash, not a running service.

set -euo pipefail

APP_DIR="${APP_DIR:-/app}"
baked="$APP_DIR/deploy/docker/egress-allowlist.txt"
merged="/tmp/egress-allowlist"

# The baked list, comments and blank lines stripped. `|| true` because a
# baked file that is *all* comments greps empty with rc 1, and whether the
# resulting fence is unusable is judged below on the merged count, with a
# clearer message than grep's silence.
grep -vE '^[[:space:]]*(#|$)' "$baked" > "$merged" || true

if [[ -n "${EGRESS_EXTRA_ALLOW:-}" ]]; then
  IFS=$', \t' read -ra extra <<<"$EGRESS_EXTRA_ALLOW"
  printf '%s\n' "${extra[@]}" | grep -vE '^$' >> "$merged" || true
fi

count="$(grep -c . "$merged" || true)"
if [[ "$count" -eq 0 ]]; then
  echo "egress-proxy: ERROR: merged allowlist is empty — $baked carries no domains and EGRESS_EXTRA_ALLOW adds none. Refusing to start a fence that would refuse everything." >&2
  exit 1
fi
echo "egress-proxy: allowing $count domains ($(tr '\n' ' ' < "$merged"))" >&2

exec squid -N -f "$APP_DIR/deploy/docker/egress-proxy.conf"
