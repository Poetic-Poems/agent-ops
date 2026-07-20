#!/usr/bin/env bash
#
# entrypoint.sh — prepare a node's mutable state, then exec the service.
#
# Runs as `agent` on every container start, for every service, and must be
# idempotent: the volumes it prepares outlive the container, and a restart must
# never undo the work of the last one — least of all the Claude credentials,
# which refresh themselves and are the one thing here that cannot be
# regenerated from the image.

set -euo pipefail

say() { printf 'entrypoint: %s\n' "$*"; }

APP_DIR=/app
CONFIG_FILE="$APP_DIR/config.json"

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

# Every path below is a mount point for a volume that outlives the container,
# and the way that goes wrong is ownership: a volume created before the image
# knew to seed it, or a host directory bind-mounted from another uid, leaves a
# directory this user cannot write. Say so once, plainly, rather than letting
# the first write fail and the service restart-loop on a bare "Permission
# denied" with no clue as to which volume or which uid.
require_writable() {
  local dir="$1" what="$2"
  if [[ ! -w "$dir" ]]; then
    say "ERROR: $dir ($what) is not writable by $(id -un) (uid $(id -u))"
    say "       it is owned by uid $(stat -c %u "$dir" 2>/dev/null || echo '?'); the volume was"
    say "       probably created by an older image or bind-mounted from another user."
    say "       Recreate it (docker compose down -v, if losing it is acceptable) or"
    say "       rebuild with --build-arg PUID=<owner> --build-arg PGID=<group>."
    exit 1
  fi
}

# --- Claude configuration ---
# Seeded only when absent. ~/.claude is a persistent volume holding
# .credentials.json, whose OAuth tokens refresh and write back; overwriting
# settings.json on every start would also throw away anything an operator set
# by hand while logging in. The seed is deliberately minimal — no plugins and
# no marketplaces, least of all the laptop's local-directory marketplace,
# which does not exist here and would break every headless `claude -p`.
mkdir -p "$HOME/.claude"
require_writable "$HOME/.claude" "the Claude configuration volume"
if [[ ! -e "$HOME/.claude/settings.json" ]]; then
  cp "$APP_DIR/deploy/docker/claude-settings.json" "$HOME/.claude/settings.json"
  say "seeded ~/.claude/settings.json"
fi
if [[ ! -e "$HOME/.claude/.credentials.json" ]]; then
  say "WARNING: ~/.claude/.credentials.json is absent — no cycle can run until this node is"
  say "         authenticated once: docker compose exec scheduler claude"
fi

# --- git and gh ---
# The identity the Implementor's commits carry. Defaulted rather than required:
# an unattended node that cannot commit because nobody set a name is a silly
# way to lose a cycle.
git config --global user.name "${GIT_USER_NAME:-Warwick Allen}"
git config --global user.email "${GIT_USER_EMAIL:-warwick@datumprocess.co.nz}"

if [[ -n "${GH_TOKEN:-}" ]]; then
  # Teaches git to use GH_TOKEN for github.com https remotes, which is how the
  # cycles push their branches — they clone over https into workspace_root and
  # never see an ssh key.
  if gh auth setup-git 2>/dev/null; then
    say "git credential helper configured from GH_TOKEN"
  else
    say "WARNING: gh auth setup-git failed — pushes will not authenticate"
  fi
else
  say "WARNING: GH_TOKEN is unset — this node can read nothing from GitHub and push nothing to it"
fi

# --- State and workspace ---
# Created here so a fresh volume is usable before the first cycle, and so the
# dashboard has somewhere to serve from on a node that has never run one.
state_dir="$(expand_home "$(jq -r '.state_dir' "$CONFIG_FILE")")"
workspace_root="$(expand_home "$(jq -r '.workspace_root' "$CONFIG_FILE")")"
mkdir -p "$state_dir" "$workspace_root"
require_writable "$state_dir" "the state volume"
require_writable "$workspace_root" "the workspaces volume"
mkdir -p "$state_dir/cycles" "$state_dir/reviews"

say "node ${NODE_NAME:-<unnamed>}, role ${AGENT_OPS_ROLE:-standby}, state $state_dir"

exec "$@"
