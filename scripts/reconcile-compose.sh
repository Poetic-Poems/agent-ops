#!/usr/bin/env bash
#
# scripts/reconcile-compose.sh — the compose reconciler's one tick.
#
# Watchtower keeps a node's *image* current with `main` without anyone
# visiting the host. Nothing kept its *compose.yaml* current, because an image
# roll recreates a container from the old container's Config: a merged
# compose change — a label, a service's environment, a mount, a whole new
# service — reached a node only when a human ran `docker compose up -d` there.
# This is the deterministic actor that closes that gap. No model is in this
# path; the file it installs is the one the image shipped, byte for byte.
#
# The decision logic lives in lib/compose-reconcile.sh, which is where the
# tests reach it with `docker` stubbed. This script is the crontab's entry
# point: it resolves the three paths from config.json and prints a line a
# human reading `docker compose logs reconciler` can act on.
#
# It runs in the `reconciler` service (deploy/docker/compose.yaml, profile
# `auto-update`) on the schedule in deploy/docker/reconcile-crontab. It needs
# the Docker socket and the node's own project directory bind-mounted at the
# same absolute path it has on the host — see that service, and
# `AGENT_OPS_PROJECT_DIR` in .env.example.
#
# Usage: reconcile-compose.sh [--print]
#
#   --print   print the verdict JSON and change nothing else (there is no
#             "dry run": the verdict is computed the same way either way, and
#             this flag only suppresses the human line, for a caller that
#             wants the object).
#
# Exit status is 0 on every verdict, including `refused`. Nothing reads a
# cron job's exit status on this image, and a refusal is a recorded state, not
# a crashed script — the verdict travels in the heartbeat and onto every
# dashboard (IMPLEMENTATION-PIPELINE-SPEC requirement 2.5a). Exit 2 is a usage
# error alone.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/compose-reconcile.sh
. "$SCRIPT_DIR/lib/compose-reconcile.sh"

print_only=0
case "${1:-}" in
  -h|--help)
    awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 0 ;;
  --print) print_only=1 ;;
  "") ;;
  *) echo "reconcile-compose: unknown argument: $1" >&2; exit 2 ;;
esac

CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

state_dir="$(expand_home "$(jq -r '.state_dir // "~/.local/state/poetic-agents"' "$CONFIG_FILE" 2>/dev/null)")"

verdict="$(COMPOSE_RECONCILE_STATE_DIR="$state_dir" COMPOSE_RECONCILE_CONFIG="$CONFIG_FILE" \
  compose_reconcile_run)"

if (( print_only )); then
  printf '%s\n' "$verdict"
  exit 0
fi

# One line per tick, and the steady state is the quiet one: this runs every
# few minutes and a node with nothing to do must not fill its container log
# with the fact.
status="$(jq -r '.status // "unknown"' <<<"$verdict" 2>/dev/null || echo unknown)"
case "$status" in
  in-sync) ;;
  reconciled)
    printf 'reconcile-compose: applied the merged compose.yaml (%s -> %s) and recreated this project\n' \
      "$(jq -r '(.from // "unknown")[0:12]' <<<"$verdict")" \
      "$(jq -r '(.to // "unknown")[0:12]' <<<"$verdict")" ;;
  *)
    printf 'reconcile-compose: %s — %s\n' "$status" "$(jq -r '.reason // "no reason recorded"' <<<"$verdict")" ;;
esac
exit 0
