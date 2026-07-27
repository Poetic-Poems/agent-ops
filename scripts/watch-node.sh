#!/usr/bin/env bash
#
# watch-node.sh — watch a running node's pipeline output, without needing to
# know the docker-exec incantation by heart.
#
# Usage:
#   watch-node.sh cron   [-f]
#   watch-node.sh events [-f]
#
#   cron    the node's cron log  (cron.log)  — one line per tick, including
#           the standby ones
#   events  the node's cycle log (log.jsonl) — cycle starts, selections, PRs
#           raised, stand-downs; see docs/IMPLEMENTATION-PIPELINE-SPEC.md
#           (requirement 33) for event types and fields
#   -f      follow, like `tail -f`, instead of printing the last 50 lines and
#           exiting
#
# Run this from the node's stack directory — wherever its compose.yaml and
# .env live, see deploy/docker/README.md — or set STACK_DIR to point at it
# from anywhere else.
#
# Read-only: this wraps `docker compose exec -T scheduler tail` and nothing
# more, so it is safe to allow-list wholesale — for an interactive agent, in
# place of the ad-hoc docker-exec commands it replaces.

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: watch-node.sh cron|events [-f]

  cron    the node's cron log   (/home/agent/.local/state/poetic-agents/cron.log)
  events  the node's cycle log  (/home/agent/.local/state/poetic-agents/log.jsonl)
  -f      follow, like tail -f, instead of printing the last 50 lines and exiting

Run from the node's stack directory (wherever compose.yaml and .env live), or
set STACK_DIR to point at it from anywhere else.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  cron)   path=/home/agent/.local/state/poetic-agents/cron.log ;;
  events) path=/home/agent/.local/state/poetic-agents/log.jsonl ;;
  "")     echo "watch-node: missing mode (cron or events)" >&2; usage; exit 1 ;;
  *)      echo "watch-node: unknown mode: $1" >&2; usage; exit 1 ;;
esac
shift

tail_args=(-n 50)
while (( $# )); do
  case "$1" in
    -f) tail_args=(-f) ;;
    -h|--help) usage; exit 0 ;;
    *) echo "watch-node: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

stack_dir="${STACK_DIR:-$PWD}"
if [[ ! -f "$stack_dir/compose.yaml" ]]; then
  echo "watch-node: no compose.yaml in $stack_dir" >&2
  echo "  run this from the node's stack directory, or set STACK_DIR to it" >&2
  exit 1
fi

exec docker compose --project-directory "$stack_dir" exec -T scheduler \
  tail "${tail_args[@]}" "$path"
