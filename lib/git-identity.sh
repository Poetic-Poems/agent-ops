#!/usr/bin/env bash
#
# lib/git-identity.sh — the identity an unattended commit runs under.
#
# Required, not defaulted: a silent fallback would commit every pull request
# this node opens under somebody else's name, and the wrong name is worse
# than no name at all (issue #76).
#
# Checked here, and not in entrypoint.sh, because only a cycle that might
# actually commit needs it — the dashboard services and every other container
# command do not touch git at all, and gating *every* container start on it
# would refuse a dashboard-only node, and every CI smoke-test invocation of
# the image, over a requirement that has nothing to do with them.
#
# Sourced by agent-cycle.sh and review-cycle.sh, and called after their role
# guard, so a standby tick — which commits nothing — is never blocked by it
# either.

require_git_identity() {
  local who="$1"
  if [[ -z "${GIT_USER_NAME:-}" || -z "${GIT_USER_EMAIL:-}" ]]; then
    echo "$who: ERROR: GIT_USER_NAME and/or GIT_USER_EMAIL is unset — this node has" >&2
    echo "$who:        no git identity to commit under. Set both in .env (see" >&2
    echo "$who:        .env.example) and recreate the container: docker compose up -d" >&2
    exit 1
  fi
  git config --global user.name "$GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"
}
