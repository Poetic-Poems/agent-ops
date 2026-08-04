#!/usr/bin/env bash
#
# rotate-logs.sh — bound the diagnostic and cron logs beside state_dir's
# records (TD26072501).
#
# TD26072004 (scripts/state-sync.sh) bounded the *records* in state_dir —
# cycles/ and reviews/ are pruned on every push — but left the logs beside
# them appended to forever. The heartbeat is the worst of them by two orders
# of magnitude: one line per tick, growing megabytes a day and never
# stopping.
#
# Rotation here is intentionally narrow, because the logs in state_dir are
# not interchangeable:
#
#   dashboard.log, state-sync.log   pure diagnostics, excluded from the
#                                   state branch (scripts/state-sync.sh) —
#                                   safe to rotate on size alone.
#   cron.log, review-cron.log       published to the node's state branch, so
#                                   bounding them here also bounds the
#                                   mirror. scripts/publish-dashboard.sh
#                                   renders cron.log's tail in the cron
#                                   panel, so it reads the previous
#                                   generation too when the live file is
#                                   short — rotating here never has to keep
#                                   a tail of its own.
#   log.jsonl, review-log.jsonl     NEVER rotated. This is the fleet's
#                                   memory: the union readers (blocked/void
#                                   extraction, the no-op fingerprint, the
#                                   limit cooldown) scan it whole, and
#                                   dropping its head would silently change
#                                   what the Co-Ordinator believes has been
#                                   tried.
#
# Plain rename is enough: every writer here reopens the file by name on each
# append (`>>"$log"` per cron invocation), so nothing holds a stale
# descriptor across a rotation and copytruncate is not needed.
#
# Meant to run from its own crontab line (deploy/docker/crontab.tmpl),
# independent of the pipelines it tidies up after.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"

usage() {
  cat <<'EOF'
usage: rotate-logs.sh

Rotate the diagnostic and cron logs in state_dir once they exceed
log_retained_bytes, keeping log_generations of history. log.jsonl and
review-log.jsonl are never touched.

Environment:
  ROTATE_LOGS_RETAINED_BYTES   override log_retained_bytes (tests use a
                               small value).
  ROTATE_LOGS_GENERATIONS      override log_generations.
EOF
}
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "rotate-logs: unexpected argument: $1" >&2; usage >&2; exit 64 ;;
esac

say() { printf '%s rotate-logs: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}
# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below, with no `// literal` of its own to drift from the schema's.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }

state_dir="$(expand_home "$(cfg '.state_dir')")"
retained_bytes="${ROTATE_LOGS_RETAINED_BYTES:-$(cfg '.log_retained_bytes')}"
generations="${ROTATE_LOGS_GENERATIONS:-$(cfg '.log_generations')}"
(( generations >= 1 )) || generations=1

# The logs this script owns. log.jsonl and review-log.jsonl are deliberately
# absent — see the file header.
LOGS=(dashboard.log state-sync.log cron.log review-cron.log)

file_size() {
  stat -c%s -- "$1" 2>/dev/null || stat -f%z -- "$1" 2>/dev/null || echo 0
}

rotate_one() {
  local name="$1" size gen
  local path="$state_dir/$name"
  [[ -f "$path" ]] || return 0
  size="$(file_size "$path")"
  (( size >= retained_bytes )) || return 0

  # Oldest generation first, so a rename never clobbers one still wanted.
  rm -f -- "$path.$generations"
  for (( gen = generations - 1; gen >= 1; gen-- )); do
    [[ -e "$path.$gen" ]] && mv -f -- "$path.$gen" "$path.$(( gen + 1 ))"
  done
  mv -f -- "$path" "$path.1"
  : > "$path"
  say "rotated $name ($size bytes, keeping $generations generation(s))"
}

for log in "${LOGS[@]}"; do
  rotate_one "$log"
done

# One-off cleanup (TD26072501): a verification log left in state_dir on
# ockham-container that should never have been there.
rm -f -- "$state_dir/once-pr4-verify.log"

exit 0
