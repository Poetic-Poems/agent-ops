#!/usr/bin/env bash
#
# lib/author-token.sh — GitHub App installation-token minting for the forge
# authoring App (D18 decision 1, agent-ops#607 Phase 2).
#
# This is the identity every authoring act runs under when it is
# configured — cloning a target repository, pushing a branch, opening or
# commenting on a pull request or issue, reading a repository's contents —
# replacing the owner's own long-lived personal access token with short-lived
# installation tokens minted from a second, distinct GitHub App
# ("Pullwright Author", never the Pullwright Approver — a single identity
# able to both author and approve its own work would recreate the
# self-approval D18 already exists to retire). See lib/forge-auth.sh for how
# a cycle actually selects between this identity and its degrade path.
#
# A thin wrapper over lib/github-app-token.sh's shared minting mechanics —
# the three-step dance, its fail-closed contract, and its tmpfs-only cache
# guarantee are all specified there, not repeated here. It is the same
# generalisation lib/approver-token.sh was rebuilt on by this same item, so
# both identities share one implementation and one set of tests for the
# mechanics themselves.
#
# Three environment variables carry this identity, the same shape
# lib/approver-token.sh's own three already established:
#
#   PULLWRIGHT_AUTHOR_APP_ID              the App's numeric id
#   PULLWRIGHT_AUTHOR_INSTALLATION_ID     the installation's numeric id
#   PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH    path to the App's .pem private key
#
# All three optional, and this file degrades rather than bricks a node when
# they are unset or unreadable: `author_token_credential_present` returning
# false, or a mint attempt failing, is exactly the "gate unreadable" contract
# `lib/github-app-token.sh` already specifies, and lib/forge-auth.sh's
# `forge_auth_effective_gh_token` treats both the same way — fall back to the
# node's own `GH_TOKEN`, exactly as every cycle has always authenticated
# before this item. No node bricks over this identity being unconfigured; the
# owner-PAT path keeps working unchanged.
#
# Unlike lib/approver-token.sh, there is no config.json declaration to
# reconcile this identity's App id against: nothing in config.json gates on
# knowing it ahead of time (the Approver's `approver_app_id` exists
# specifically to gate `merge_autonomy`, which this identity does not touch),
# the same reason GH_TOKEN itself has no config.json key either.
#
# Sourced, never executed: it sets no shell options, so a caller's own
# `set -euo pipefail` (agent-cycle.sh, deploy/docker/entrypoint.sh) decides.
#
# Environment overrides, for tests only: AUTHOR_TOKEN_CURL, AUTHOR_TOKEN_OPENSSL
# (stub binaries) and AUTHOR_TOKEN_CACHE_DIR (an alternative tmpfs — a
# non-tmpfs directory is refused, so the override cannot re-introduce disk).

# shellcheck source=lib/github-app-token.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-app-token.sh"

# author_token_credential_present
# True (exit 0) iff all three identity variables are set and the private key
# is readable.
author_token_credential_present() {
  github_app_token_credential_present \
    "${PULLWRIGHT_AUTHOR_APP_ID:-}" \
    "${PULLWRIGHT_AUTHOR_INSTALLATION_ID:-}" \
    "${PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH:-}"
}

# author_token_get [NOW_EPOCH]
# Print a valid forge authoring App installation token on stdout. Same exit
# contract as lib/approver-token.sh's approver_token_get: 0 success (token on
# stdout), 2 no credential configured (gate unreadable), 1 a mint attempt was
# made and refused.
author_token_get() {
  github_app_token_get \
    "${PULLWRIGHT_AUTHOR_APP_ID:-}" \
    "${PULLWRIGHT_AUTHOR_INSTALLATION_ID:-}" \
    "${PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH:-}" \
    "${AUTHOR_TOKEN_CACHE_DIR:-/dev/shm}" \
    "pullwright-author-token" \
    "${AUTHOR_TOKEN_CURL:-curl}" \
    "${AUTHOR_TOKEN_OPENSSL:-openssl}" \
    "${1:-$(date +%s)}"
}

# author_token_identity_login [NOW_EPOCH]
# Print the forge authoring App's own GitHub login ("<app-slug>[bot]") — used
# by scripts/doctor.sh to report which identity a node actually authors as,
# on the same "gate unreadable" terms as `author_token_get`.
author_token_identity_login() {
  github_app_token_identity_login \
    "${PULLWRIGHT_AUTHOR_APP_ID:-}" \
    "${PULLWRIGHT_AUTHOR_INSTALLATION_ID:-}" \
    "${PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH:-}" \
    "${AUTHOR_TOKEN_CURL:-curl}" \
    "${AUTHOR_TOKEN_OPENSSL:-openssl}" \
    "${1:-$(date +%s)}"
}
