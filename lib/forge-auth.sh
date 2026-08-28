#!/usr/bin/env bash
#
# lib/forge-auth.sh — which identity a cycle authors as (D18 decision 1,
# agent-ops#607 Phase 2).
#
# Every git/gh operation this pipeline performs while authoring — cloning a
# target repository, pushing a branch, opening a pull request, commenting,
# reading an issue — goes through whatever `GH_TOKEN` names in this process's
# environment: `gh` itself honours the variable directly, and
# deploy/docker/entrypoint.sh's `gh auth setup-git` makes plain `git` read
# the same value through `gh`'s own credential helper. This file is the one
# place that decides what that value is for a cycle about to do any of that
# work: the forge authoring App's own minted installation token
# (lib/author-token.sh) when it is configured and a mint actually succeeds,
# the node's own ambient `GH_TOKEN` — set from `.env`, exactly as before this
# item — in every other case. This is the degrade path agent-ops#607
# requires: an unset, unreadable or momentarily unreachable App identity must
# never brick a node that has always worked fine on its PAT alone.
#
# Sourced, never executed: it sets no shell options, so a caller's own
# `set -euo pipefail` (agent-cycle.sh) decides. Requires lib/author-token.sh
# to already be sourced (agent-cycle.sh sources it first).

# forge_auth_effective_gh_token [NOW_EPOCH]
# Print "SOURCE<TAB>TOKEN" — one tab-separated line, the same shape
# lib/github-limit.sh's `github_auth_probe` already uses, and for the same
# reason: a caller must read it via `IFS=$'\t' read -r source token < <(...)`,
# never `x="$(...)"` — a plain command substitution runs in a subshell, and a
# side-effect global this function set would be lost the moment it returned,
# rather than reaching the caller at all.
#
# SOURCE is one of:
#   forge-app            the forge authoring App's identity, minted fresh
#                         (or served from its own cache)
#   gh-token-degraded    the App is configured but a mint just failed —
#                         degraded to the ambient GH_TOKEN for this cycle
#   gh-token             no forge authoring App is configured — the ambient
#                         GH_TOKEN, exactly as every cycle before this item
#
# Never fails: an absent or broken App credential always resolves to
# whatever GH_TOKEN already held (possibly empty, if the node has neither —
# the pre-existing "GH_TOKEN is unset" failure mode this file does not
# change; lib/standdown.sh's own credential probe still catches that).
forge_auth_effective_gh_token() {
  local now="${1:-}"
  if author_token_credential_present; then
    local token
    if token="$(author_token_get "$now")" && [[ -n "$token" ]]; then
      printf 'forge-app\t%s\n' "$token"
      return 0
    fi
    printf 'gh-token-degraded\t%s\n' "${GH_TOKEN:-}"
    return 0
  fi
  printf 'gh-token\t%s\n' "${GH_TOKEN:-}"
}
