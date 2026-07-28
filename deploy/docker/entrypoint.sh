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
#
# The image points CLAUDE_CONFIG_DIR at this same directory (see the
# Dockerfile), so the global config file lands inside the volume rather than
# beside it as `~/.claude.json`, where a watchtower roll would take it.
# Defaulted rather than assumed: this script also runs in contexts that set
# their own environment, and the paths below must not silently disagree with
# whatever the CLI is actually reading.
: "${CLAUDE_CONFIG_DIR:=$HOME/.claude}"
export CLAUDE_CONFIG_DIR
mkdir -p "$CLAUDE_CONFIG_DIR"
require_writable "$CLAUDE_CONFIG_DIR" "the Claude configuration volume"
if [[ ! -e "$CLAUDE_CONFIG_DIR/settings.json" ]]; then
  cp "$APP_DIR/deploy/docker/claude-settings.json" "$CLAUDE_CONFIG_DIR/settings.json"
  say "seeded $CLAUDE_CONFIG_DIR/settings.json"
fi
if [[ ! -e "$CLAUDE_CONFIG_DIR/.credentials.json" ]]; then
  say "WARNING: $CLAUDE_CONFIG_DIR/.credentials.json is absent — no cycle can run until this node is"
  say "         authenticated once: docker compose exec scheduler claude"
fi

# --- git and gh ---
# The identity the Implementor's commits carry. Required, not defaulted: a
# silent fallback would commit every pull request this node ever opens under
# somebody else's name, and the wrong name is worse than no name at all.
if [[ -z "${GIT_USER_NAME:-}" || -z "${GIT_USER_EMAIL:-}" ]]; then
  say "ERROR: GIT_USER_NAME and/or GIT_USER_EMAIL is unset — this node has no git"
  say "       identity to commit under. Set both in .env (see .env.example) and"
  say "       recreate the container: docker compose up -d"
  exit 1
fi
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

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

# --- The schedule (design decision D5: per-node cycle offsets) ---
# Rendered over the baked crontab so several active nodes spread across the
# hour instead of all firing together on one shared account. /app is this
# container's own copy of the image, owned by agent, so writing there
# affects nobody else. Failure is loud but never fatal: the baked crontab is
# a valid, working schedule.
if ! "$APP_DIR/deploy/docker/render-crontab.sh"; then
  say "WARNING: crontab render failed — running on the baked schedule"
fi

say "node ${NODE_NAME:-<unnamed>}, role ${AGENT_OPS_ROLE:-standby}, state $state_dir"

exec "$@"
