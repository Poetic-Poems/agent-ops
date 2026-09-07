#!/usr/bin/env bash
#
# check-node-image.sh — is this node running the newest image this repository
# has published, or one that has fallen behind (#155)?
#
# lib/image-drift.sh answers this from inside a node's containers — it needs
# curl, jq, and this node's own build-info.json, none of which this script
# assumes the host itself has. So rather than a second, host-side
# implementation of the registry query (the way check-node-compose.sh reads
# the host's own compose.yaml, because *that* file lives on the host and
# nothing else can), this runs the check through the scheduler container,
# the same way scripts/state-sync.sh and scripts/publish-dashboard.sh do —
# the answer this script prints is exactly the one the fleet dashboard's
# badge is built from, not a second opinion.
#
# The inner script travels on the container's stdin rather than as a
# `bash -c` argument (the fix in #154 for a coordinator prompt that crossed
# MAX_ARG_STRLEN applies here too, at a much smaller scale — stdin has no
# such ceiling and needs no escaping for the single quotes jq's own filters
# carry).
#
# An empty cache path is passed to image_drift_status, deliberately bypassing
# the cache scripts/state-sync.sh and scripts/publish-dashboard.sh share: an
# operator running this by hand wants this instant's answer, not one up to
# IMAGE_DRIFT_TTL (lib/image-drift.sh) old.
#
# Run it on the node's host, from the stack directory (wherever compose.yaml
# and .env live — see deploy/docker/README.md), or point STACK_DIR at one.
# Read-only throughout — `docker compose exec`, `curl` and `jq`, all read-only
# on the registry's side too — so it is safe to allow-list wholesale, like
# check-node-compose.sh and watch-node.sh.
#
# Exit: 0 current, or behind by less than the configured grace (a roll
#         defers while a cycle is in flight, so this is the normal mid-roll
#         state — see lib/image-drift.sh's header) · 1 behind longer than the
#         grace · 2 could not check (the registry was unreachable, or this
#         node is not running a CI-stamped image at all).

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: check-node-image.sh

Ask this node's own scheduler container whether it is running the newest
image ghcr.io/pullwright/agent-ops:latest names, via lib/image-drift.sh —
run inside the container, where the toolchain and this node's own
build-info.json actually live.

Run from the node's stack directory (wherever compose.yaml and .env live), or
set STACK_DIR to point at it.

Exit 0 current or behind within the configured grace, 1 behind past it, 2
could not check.
USAGE
}
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "check-node-image: unknown argument: $1" >&2; usage; exit 2 ;;
esac

stack_dir="${STACK_DIR:-$PWD}"
if [[ ! -f "$stack_dir/compose.yaml" ]]; then
  echo "check-node-image: no compose.yaml in $stack_dir" >&2
  echo "  run this from the node's stack directory, or set STACK_DIR to it" >&2
  exit 2
fi
compose=(docker compose --project-directory "$stack_dir")

ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; }
info() { printf 'info - %s\n' "$1"; }

# One exec, carrying home both the verdict and the grace threshold
# (config.json's image_behind_grace_hours) — a second exec for the threshold
# alone would be a second round trip for one number already sitting beside
# the first.
result="$("${compose[@]}" exec -T scheduler bash <<'INNER' 2>/dev/null
. /app/lib/version.sh
. /app/lib/image-drift.sh
v="$(image_drift_status "$(agent_ops_version /app)" "")"
# Deliberately not config_defaults: this runs inside whatever image the node
# is currently running, which by this script's whole purpose is often one
# that predates config_defaults — reading the raw file stays correct against
# any image vintage the container might be, the same exemption
# deploy/docker/watchtower-pre-update.sh's literals carry.
g="$(jq -r '.image_behind_grace_hours // 3' /app/config.json)"
jq -nc --argjson v "$v" --arg g "$g" '{verdict: $v, grace_hours: ($g | tonumber? // 3)}'
INNER
)"
if [[ -z "$result" ]]; then
  echo "check-node-image: cannot run the check inside the scheduler container" >&2
  echo "  is the stack up? (docker compose ps — the scheduler must be running)" >&2
  exit 2
fi

status="$(jq -r '.verdict.status // "null"' <<<"$result" 2>/dev/null)"
grace_hours="$(jq -r '.grace_hours' <<<"$result" 2>/dev/null)"
[[ "$grace_hours" =~ ^[0-9]+$ ]] || grace_hours=3

case "$status" in
  null)
    info "this node is not running a CI-stamped image (a developer checkout) — the registry comparison does not apply"
    exit 0
    ;;
  unverified)
    reason="$(jq -r '.verdict.reason // "unknown"' <<<"$result")"
    echo "check-node-image: could not verify against the registry: $reason" >&2
    exit 2
    ;;
  current)
    ok "running the registry's newest published image"
    exit 0
    ;;
  behind)
    registry_commit="$(jq -r '.verdict.registry_commit // "?"' <<<"$result")"
    created="$(jq -r '.verdict.registry_created_at // empty' <<<"$result")"
    age_s=""
    if [[ -n "$created" ]]; then
      created_epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
      (( created_epoch > 0 )) && age_s=$(( $(date +%s) - created_epoch ))
    fi
    if [[ -n "$age_s" && "$age_s" -lt $(( grace_hours * 3600 )) ]]; then
      info "behind the registry's newest image (${registry_commit:0:7}, published $(( age_s / 60 ))m ago) — within the ${grace_hours}h grace a deferred roll is given"
      exit 0
    fi
    bad "behind the registry's newest image (${registry_commit:0:7}) for longer than the ${grace_hours}h grace — watchtower may have stopped rolling on this node (docker logs, or docker compose ps watchtower)"
    exit 1
    ;;
  *)
    echo "check-node-image: unexpected verdict from the container: $result" >&2
    exit 2
    ;;
esac
