#!/usr/bin/env bash
#
# lib/approver-token.sh — GitHub App installation-token minting for the
# Pullwright Approver (D18 WI-4, agent-ops#407; design:
# docs/reviews/2026-08-14-autonomy-investigation.md §5.3).
#
# The Approver acts as a GitHub App identity ("Pullwright Approver",
# agent-ops#406), not the owner's PAT: an App-submitted review is what makes
# `required_approving_review_count: 1` load-bearing without recreating
# self-approval. This file is a thin wrapper over lib/github-app-token.sh's
# shared minting mechanics — the three-step dance (sign a JWT, exchange it
# for an installation token, cache the result), its fail-closed contract, and
# its tmpfs-only cache guarantee are all specified there, not repeated here.
# agent-ops#607 (Phase 2) pulled that machinery out of this file into the
# shared one once a second identity (the forge authoring App,
# lib/author-token.sh) needed the identical dance against a different
# App/installation/key; every function below now does nothing but supply
# this identity's own environment variable names and delegate.
#
# Three environment variables carry the App's identity, deliberately not
# committed anywhere and not read from config.json (the same discipline
# GH_TOKEN already follows — deploy/docker/.env.example, "GitHub"):
#
#   PULLWRIGHT_APPROVER_APP_ID              the App's numeric id
#   PULLWRIGHT_APPROVER_INSTALLATION_ID     the installation's numeric id
#   PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH    path to the App's .pem private key
#
# The key is read from a path, never from its own environment variable: an
# RSA private key is multi-line and openssl's `-sign` flag already wants a
# file, so a path is the one shape that needs no on-disk materialisation step
# of its own. The file must exist wherever this runs — bind-mounted read-only,
# `chmod 600`, kept out of every repository, exactly as agent-ops#406's own
# comment describes.
#
# The App id, unlike the key, is not a secret — it already exists in
# config.json as `approver_app_id`, the operator's declaration doctor
# validates for any merge_autonomy level above `human` (requirement 2.3b).
# The environment stays what this file reads (it is the wiring compose/.env
# will carry), but the two are not independent: `scripts/doctor.sh`
# reconciles them, failing a set `PULLWRIGHT_APPROVER_APP_ID` that differs
# from a set `approver_app_id`, so the App the operator declared and the App
# this file mints against cannot drift apart silently.
#
# No fallback to any other credential anywhere in this file: it references
# no identity but the Approver's own, so an absent App key can never silently
# reroute an approve/land call through the owner's own token, which would
# recreate the self-approval the App exists to retire.
#
# Sourced, never executed: it sets no shell options, so a caller's own
# `set -euo pipefail` (agent-cycle.sh) or `set -uo pipefail` decides.
#
# Environment overrides, for tests only: APPROVER_TOKEN_CURL, APPROVER_TOKEN_OPENSSL
# (stub binaries) and APPROVER_TOKEN_CACHE_DIR (an alternative tmpfs — a
# non-tmpfs directory is refused, so the override cannot re-introduce disk).

# shellcheck source=lib/github-app-token.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/github-app-token.sh"

# approver_token_credential_present
# True (exit 0) iff all three identity variables are set and the private key
# is readable — the fail-closed check `approver_token_get` itself applies,
# exposed separately so a caller can ask "is the gate even readable" without
# minting anything.
approver_token_credential_present() {
  github_app_token_credential_present \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}"
}

# approver_token_get [NOW_EPOCH]
# Print a valid Pullwright Approver installation token on stdout. NOW_EPOCH
# defaults to the real clock; tests pass it explicitly to exercise expiry
# without waiting on one.
#
# Exit status:
#   0  success — the token is on stdout, nothing else is.
#   2  no credential configured, or the private key is unreadable — "gate
#      unreadable": the caller must hand back, never proceed as though the
#      gate had been read and passed.
#   1  a mint attempt was made and GitHub did not issue a token — network
#      failure, a rejected JWT, an unparsable response. Also gate-unreadable
#      to the caller, kept as a distinct code so a log can tell "nothing
#      configured" from "something broke".
approver_token_get() {
  github_app_token_get \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
    "${APPROVER_TOKEN_CACHE_DIR:-/dev/shm}" \
    "pullwright-approver-token" \
    "${APPROVER_TOKEN_CURL:-curl}" \
    "${APPROVER_TOKEN_OPENSSL:-openssl}" \
    "${1:-$(date +%s)}"
}

# approver_token_installation_permissions [NOW_EPOCH]
# Print the Pullwright Approver installation's actual granted permissions —
# the live `.permissions` object from `GET /app/installations/<id>`
# (`{"contents":"write","metadata":"read","pull_requests":"write",...}`) — or
# return non-zero, printing nothing, on the same "gate unreadable" terms as
# `approver_token_get` (2 no credential, 1 mint/request failed).
#
# D18 Stage 3 (agent-ops#575): an installation's granted permissions are
# whatever the organisation owner last approved through GitHub's own consent
# screen, entirely outside config.json, and can be narrowed or widened there
# at any time with nothing in this repository the wiser. `scripts/doctor.sh`
# reads this rather than assuming the three permissions the Approver needs
# (`contents: write`, `metadata: read`, `pull_requests: write`) from
# `approver_app_id` alone.
approver_token_installation_permissions() {
  github_app_token_installation_permissions \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
    "${APPROVER_TOKEN_CURL:-curl}" \
    "${APPROVER_TOKEN_OPENSSL:-openssl}" \
    "${1:-$(date +%s)}"
}

# approver_token_installation_repositories [NOW_EPOCH]
# Print the repositories the Pullwright Approver installation can actually
# act on — one `owner/name` per line — or the single word `all` when the
# installation was granted every repository in the account. Returns non-zero,
# printing nothing, on the same "gate unreadable" terms as
# `approver_token_get` (2 no credential, 1 request failed).
#
# D18 Stage 3 (agent-ops#721): an installation's *repository selection*, like
# its permissions above, lives entirely on GitHub's own consent screen and can
# be narrowed at any time with nothing in this repository the wiser — and
# `scripts/doctor.sh`'s autonomy-readiness verdict was checking the
# permissions without ever checking that they applied to the repository in
# front of it. A repository configured at `agent-approves` or above that the
# App cannot see is a verdict of "fully supported" over an App that can
# neither review nor land there.
approver_token_installation_repositories() {
  github_app_token_installation_repositories \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
    "${APPROVER_TOKEN_CACHE_DIR:-/dev/shm}" \
    "pullwright-approver-token" \
    "${APPROVER_TOKEN_CURL:-curl}" \
    "${APPROVER_TOKEN_OPENSSL:-openssl}" \
    "${1:-$(date +%s)}"
}

# approver_token_identity_login [NOW_EPOCH]
# Print the Pullwright Approver's own GitHub login — "<app-slug>[bot]", the
# form every review or comment it submits carries as its `user.login` — or
# return non-zero, printing nothing, on the same "gate unreadable" terms as
# `approver_token_get`.
#
# `lib/approver.sh` needs this login to tell the Approver's own past reviews
# on a pull request apart from a human's or another bot's when it counts a
# refuse streak (D18 WI-5, agent-ops#408, design doc §5.2) — GitHub exposes no
# other way to ask "which login does this App write as".
approver_token_identity_login() {
  github_app_token_identity_login \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
    "${APPROVER_TOKEN_CURL:-curl}" \
    "${APPROVER_TOKEN_OPENSSL:-openssl}" \
    "${1:-$(date +%s)}"
}
