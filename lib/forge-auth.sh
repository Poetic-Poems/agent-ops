#!/usr/bin/env bash
#
# lib/forge-auth.sh — which identity a cycle authors as (D18 decision 1,
# agent-ops#607 Phase 2), and the name of the seam's degrade-path variable
# (D18 decision 1 as amended, agent-ops#1021).
#
# Since agent-ops#1021, no single point in a cycle's process resolves a
# credential once for the process's whole life — a forge authoring App
# installation token carries GitHub's ~1 h lifetime, and a cycle routinely
# outlives that. The credential is instead resolved on demand, per call, by
# an on-demand seam: `lib/gh-shim.sh` (the `gh` transport shim, requirement
# 2.0e, installed ahead of the real binary on `PATH`) for every `gh`
# invocation, and the same shim reached through `git`'s own credential
# helper (`!gh auth git-credential`, `deploy/docker/entrypoint.sh`) for
# plain `git`. Both mint only when `GH_TOKEN` is empty in their own
# environment — an explicit `GH_TOKEN` (a human's own, or
# `lib/approver.sh`'s `GH_TOKEN="$(approver_token_get)" gh …`) always passes
# through untouched, so the seam can never re-identify the Approver's own
# calls as the author.
#
# `deploy/docker/entrypoint.sh` makes the App the default: when
# `author_token_credential_present`, it moves whatever ambient PAT `GH_TOKEN`
# already held into `PW_GH_DEGRADE_TOKEN` — the name this file owns — and
# leaves `GH_TOKEN` explicitly empty (exported, not merely unset) before it
# execs the service, so every process the node runs — cycles, cron entry
# points, `docker compose exec` — inherits an empty `GH_TOKEN` and resolves
# through the seam. The seam falls back to `PW_GH_DEGRADE_TOKEN` whenever no
# App is configured or a mint attempt fails, which is the degrade path
# agent-ops#607 requires: an unset, unreadable or momentarily unreachable App
# identity must never brick a node that has always worked fine on its PAT
# alone, and a token that ages out mid-cycle must never present a stale one
# to the call that needed it.
#
# `forge_auth_effective_gh_token`, below, is no longer what sets the
# credential a cycle authenticates with — the seam does that, per call — but
# `lib/standdown.sh` still calls it once, at stand-down, purely to log which
# path a cycle would take (the `forge-auth` event's `source`) for
# `scripts/publish-dashboard.sh` and an operator reading the log.
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
# rather than reaching the caller at all. TOKEN is diagnostic only — see this
# file's own header for why nothing exports it any more.
#
# SOURCE is one of:
#   forge-app            the forge authoring App's identity, minted fresh
#                         (or served from its own cache)
#   gh-token-degraded    the App is configured but a mint just failed —
#                         degraded to PW_GH_DEGRADE_TOKEN (or, absent that,
#                         the ambient GH_TOKEN) for this cycle
#   gh-token             no forge authoring App is configured — the ambient
#                         GH_TOKEN, exactly as every cycle before D25
#
# Never fails: an absent or broken App credential always resolves to
# whatever PW_GH_DEGRADE_TOKEN or GH_TOKEN already held (possibly empty, if
# the node has neither — the pre-existing "no credential" failure mode this
# file does not change; lib/standdown.sh's own credential probe still
# catches that).
#
# It names no owner, so the mint it reports on is against the *default*
# installation (PULLWRIGHT_AUTHOR_INSTALLATION_ID) — the same one
# lib/gh-shim.sh's `gh_shim_resolve_token` uses for any call it cannot
# attribute to a repository owner, which is exactly the path this line
# exists to report. A fleet that configures only the per-owner map
# (PULLWRIGHT_AUTHOR_INSTALLATION_IDS) and no scalar default therefore reads
# `gh-token-degraded` here — correctly: an owner-less call on such a node
# really does take the fallback. Setting the scalar as well is what makes it
# report `forge-app`, and deploy/docker/.env.example says so.
forge_auth_effective_gh_token() {
  local now="${1:-}"
  if author_token_credential_present; then
    local token
    if token="$(author_token_get "$now")" && [[ -n "$token" ]]; then
      printf 'forge-app\t%s\n' "$token"
      return 0
    fi
    printf 'gh-token-degraded\t%s\n' "${PW_GH_DEGRADE_TOKEN:-${GH_TOKEN:-}}"
    return 0
  fi
  printf 'gh-token\t%s\n' "${GH_TOKEN:-}"
}
