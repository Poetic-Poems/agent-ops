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

# --- gh / git authentication (D18 decision 1, agent-ops#607; the on-demand
#     credential seam, agent-ops#1021) ---
# The commit identity (GIT_USER_NAME/GIT_USER_EMAIL) is deliberately not set
# here: this entrypoint gates every container this image runs — the dashboard
# services and every CI smoke-test invocation included — and neither touches
# git. Requiring it here would refuse a dashboard-only node, and every one of
# those invocations, over an identity they never use. agent-cycle.sh and
# review-cycle.sh require and configure it themselves, right before a cycle
# that might actually commit — see lib/git-identity.sh.
#
# Nothing here mints a token any more. Every `git`/`gh` authoring act on this
# node resolves its own credential on demand, per call, through the seam
# (lib/gh-shim.sh's `gh` transport shim, installed ahead of the real binary
# on PATH by the Dockerfile) — which is what lets a cycle outlive a forge
# authoring App installation token's ~1 h lifetime without presenting a stale
# one to whichever call needed it. This block's only job is to make the App
# the *default* identity, and to wire git into the same seam gh already
# reaches.
# shellcheck source=lib/author-token.sh
. "$APP_DIR/lib/author-token.sh"
# shellcheck disable=SC2119 # "is this identity configured at all", deliberately no owner
if author_token_credential_present; then
  # Stash the ambient PAT (if any) as the seam's fallback — lib/forge-auth.sh
  # owns this variable's name — and leave GH_TOKEN explicitly empty
  # (exported, not merely unset), so every process this entrypoint execs —
  # cycles, cron entry points, `docker compose exec` — inherits an empty
  # GH_TOKEN and resolves through the seam rather than a token that may be
  # hours from expiry by the time it authenticates anything. The seam falls
  # back to this variable when a mint fails.
  export PW_GH_DEGRADE_TOKEN="${GH_TOKEN:-}"
  export GH_TOKEN=""
  say "the forge authoring App is configured — GH_TOKEN resolves per call through the credential seam"
elif [[ -n "${GH_TOKEN:-}" ]]; then
  say "no forge authoring App configured — GH_TOKEN authenticates every git/gh call"
else
  say "WARNING: neither GH_TOKEN nor the forge authoring App's credentials (PULLWRIGHT_AUTHOR_APP_ID, PULLWRIGHT_AUTHOR_INSTALLATION_ID or _INSTALLATION_IDS, PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH) are set — this node can read nothing from GitHub and push nothing to it"
fi

# shellcheck disable=SC2119 # as above — the helper is wired for either credential
if author_token_credential_present || [[ -n "${GH_TOKEN:-}" ]]; then
  # Wired directly, never via `gh auth setup-git`: that command bakes the
  # *absolute path* of whichever `gh` process ran it (`os.Executable()`) into
  # the config — and reached through the shim, which execs the real binary
  # directly by its own fixed path rather than via PATH, that path is the
  # real binary's, /usr/bin/gh, never the shim's own. A helper configured
  # that way would call the real binary straight, bypassing the seam above
  # on every future credential fill. The unqualified `gh` below instead
  # re-resolves through PATH — the shim, installed at /usr/local/bin/gh
  # ahead of it — on every single call.
  # `--replace-all`, not append: this runs on every container start and must
  # not stack a new helper entry on top of the last one.
  #
  # Guarded, because this file runs under `set -euo pipefail` and is PID 1's
  # entrypoint: an unwritable $HOME or a malformed ~/.gitconfig must degrade
  # to "pushes will not authenticate", exactly as the `gh auth setup-git`
  # call this replaced already did, never to a container that refuses to
  # start at all.
  if git config --global --replace-all credential.https://github.com.helper '!gh auth git-credential'; then
    say "git credential helper wired to the credential seam"
  else
    say "WARNING: could not configure the git credential helper — pushes will not authenticate"
  fi
  # Without this, git tells the helper only the protocol and the host, and
  # `gh_shim_target_owner` has nothing in the request that names the
  # repository — so every push and fetch would mint against the scalar
  # default installation whatever organisation it was for. `useHttpPath`
  # adds `path=<owner>/<repo>.git` to the credential request, which is the
  # one attribute that distinguishes them. It changes nothing else here:
  # the helper is `gh`, not a credential *store*, so the finer key this
  # setting normally affects has nothing to key.
  # Not fatal, for the same reason the helper itself is not: a node that
  # could not write it still authenticates, just always as the default
  # installation.
  # `--replace-all`, like the helper above: this runs on every container
  # start, and a key that somehow acquired two values would otherwise make
  # a plain `git config` set error out.
  if ! git config --global --replace-all credential.https://github.com.useHttpPath true; then
    say "WARNING: could not set credential.useHttpPath — git pushes will mint against the default installation whatever repository they target"
  fi
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
