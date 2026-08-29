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
# Four environment variables carry the App's identity, deliberately not
# committed anywhere and not read from config.json (the same discipline
# GH_TOKEN already follows — deploy/docker/.env.example, "GitHub"):
#
#   PULLWRIGHT_APPROVER_APP_ID              the App's numeric id
#   PULLWRIGHT_APPROVER_INSTALLATION_ID     the default installation's numeric id
#   PULLWRIGHT_APPROVER_INSTALLATION_IDS    per-owner installation ids (JSON map)
#   PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH    path to the App's .pem private key
#
# The key is read from a path, never from its own environment variable: an
# RSA private key is multi-line and openssl's `-sign` flag already wants a
# file, so a path is the one shape that needs no on-disk materialisation step
# of its own. The file must exist wherever this runs — bind-mounted read-only,
# `chmod 600`, kept out of every repository, exactly as agent-ops#406's own
# comment describes.
#
# One App, several installations (agent-ops#913): a GitHub App installation
# is per account, so once `repos[]` spans two owners — e.g. `agent-ops` on
# `Pullwright` while `poetic`/`poetic-fiddle`/`agent-ops-state` stay on
# `Poetic-Poems` — one installation id can no longer back every repository
# this identity reviews. `PULLWRIGHT_APPROVER_INSTALLATION_IDS` is a JSON
# object mapping owner to installation id (`{"Pullwright": 12345678,
# "Poetic-Poems": 87654321}`); every function below that mints or reads
# against a specific installation takes the repository slug (or bare owner)
# it is acting for and resolves the installation id by the owner half,
# case-insensitively, from that map, falling back to
# `PULLWRIGHT_APPROVER_INSTALLATION_ID` for an owner the map does not name.
# A single-owner fleet sets only the scalar `PULLWRIGHT_APPROVER_INSTALLATION_ID`,
# exactly as before, and never needs the map at all.
#
# Rejected: deriving the installation from `GET /app/installations` with the
# App JWT. The installation id is an operator *declaration* of where the
# Approver may act — the same reason `approver_app_id` is declared in
# config.json and reconciled by doctor rather than looked up — and a lookup
# would let an installation added on any account silently widen the fleet's
# reach.
#
# `approver_token_identity_login` is the one function here that needs no
# installation id to resolve: an App's own login (`GET /app`) is identical
# across every installation of the same App, so it takes no slug and simply
# asks for *some* configured installation (default or, absent that, any one
# entry of the map) to satisfy the shared credential-present gate.
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

# approver_token_installation_id_for SLUG_OR_OWNER
# Resolve the Approver installation id for a repository slug ("owner/repo")
# or a bare owner, by the owner half, case-insensitively, against
# PULLWRIGHT_APPROVER_INSTALLATION_IDS (a JSON object of owner to
# installation id), falling back to PULLWRIGHT_APPROVER_INSTALLATION_ID for
# an owner the map does not name. Prints the resolved id and returns 0, or
# prints nothing and returns 1 if neither names this owner.
#
# A map that is set but not valid JSON, or not a JSON object, is treated the
# same as an empty map (falls straight through to the scalar default) rather
# than raised as an error here — malformed configuration is exactly what
# scripts/doctor.sh exists to catch before this ever runs against it, and a
# minting path failing closed on a config typo would turn a doctor `fail`
# into a mint failure with a much less specific diagnosis.
approver_token_installation_id_for() {
  local slug="$1" owner id
  owner="${slug%%/*}"
  if [[ -n "${PULLWRIGHT_APPROVER_INSTALLATION_IDS:-}" ]]; then
    id="$(jq -r --arg o "$owner" '
      if (type == "object") then
        (to_entries[] | select((.key | ascii_downcase) == ($o | ascii_downcase)) | .value | tostring)
      else empty end
    ' <<<"$PULLWRIGHT_APPROVER_INSTALLATION_IDS" 2>/dev/null | head -n1)"
  fi
  if [[ -z "${id:-}" ]]; then
    id="${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}"
  fi
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# approver_token_any_installation_id
# Print *some* configured installation id — the default scalar if set, else
# the first entry (by key) of the JSON map — or nothing and return 1 if
# neither is configured. Used only where no specific owner is in play (the
# fleet-wide "is any credential configured at all" checks, and
# approver_token_identity_login, whose one API call is identical regardless
# of which installation answers the credential-present gate).
approver_token_any_installation_id() {
  local id="${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}"
  if [[ -z "$id" && -n "${PULLWRIGHT_APPROVER_INSTALLATION_IDS:-}" ]]; then
    id="$(jq -r 'if (type == "object") then (to_entries | sort_by(.key) | .[0].value | tostring) else empty end' \
      <<<"$PULLWRIGHT_APPROVER_INSTALLATION_IDS" 2>/dev/null)"
  fi
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# approver_token_credential_present [SLUG_OR_OWNER]
# True (exit 0) iff the App id and private key are set, the key is readable,
# and an installation id resolves — for SLUG_OR_OWNER's owner if given,
# otherwise any configured installation at all (approver_token_any_installation_id)
# — the fail-closed check `approver_token_get` itself applies, exposed
# separately so a caller can ask "is the gate even readable" without minting
# anything.
approver_token_credential_present() {
  local slug="${1:-}" installation_id
  if [[ -n "$slug" ]]; then
    installation_id="$(approver_token_installation_id_for "$slug")" || installation_id=""
  else
    installation_id="$(approver_token_any_installation_id)" || installation_id=""
  fi
  github_app_token_credential_present \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "$installation_id" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}"
}

# approver_token_get SLUG_OR_OWNER [NOW_EPOCH]
# Print a valid Pullwright Approver installation token, for the installation
# SLUG_OR_OWNER's owner resolves to, on stdout. NOW_EPOCH defaults to the
# real clock; tests pass it explicitly to exercise expiry without waiting on
# one.
#
# Exit status:
#   0  success — the token is on stdout, nothing else is.
#   2  no credential configured for this owner, or the private key is
#      unreadable — "gate unreadable": the caller must hand back, never
#      proceed as though the gate had been read and passed.
#   1  a mint attempt was made and GitHub did not issue a token — network
#      failure, a rejected JWT, an unparsable response. Also gate-unreadable
#      to the caller, kept as a distinct code so a log can tell "nothing
#      configured" from "something broke".
approver_token_get() {
  local slug="${1:-}" now="${2:-$(date +%s)}" installation_id
  installation_id="$(approver_token_installation_id_for "$slug")" || installation_id=""
  github_app_token_get \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "$installation_id" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
    "${APPROVER_TOKEN_CACHE_DIR:-/dev/shm}" \
    "pullwright-approver-token" \
    "${APPROVER_TOKEN_CURL:-curl}" \
    "${APPROVER_TOKEN_OPENSSL:-openssl}" \
    "$now"
}

# approver_token_installation_permissions SLUG_OR_OWNER [NOW_EPOCH]
# Print the Pullwright Approver installation SLUG_OR_OWNER's owner resolves
# to's actual granted permissions — the live `.permissions` object from
# `GET /app/installations/<id>`
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
# `approver_app_id` alone. One App may hold several installations
# (agent-ops#913), so this is read once per distinct installation, never once
# fleet-wide.
approver_token_installation_permissions() {
  local slug="${1:-}" now="${2:-$(date +%s)}" installation_id
  installation_id="$(approver_token_installation_id_for "$slug")" || installation_id=""
  github_app_token_installation_permissions \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "$installation_id" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
    "${APPROVER_TOKEN_CURL:-curl}" \
    "${APPROVER_TOKEN_OPENSSL:-openssl}" \
    "$now"
}

# approver_token_installation_repositories SLUG_OR_OWNER [NOW_EPOCH]
# Print the repositories the Pullwright Approver installation SLUG_OR_OWNER's
# owner resolves to can actually act on — one `owner/name` per line — or the
# single word `all` when the installation was granted every repository in
# the account. Returns non-zero, printing nothing, on the same "gate
# unreadable" terms as `approver_token_get` (2 no credential, 1 request
# failed).
#
# D18 Stage 3 (agent-ops#721): an installation's *repository selection*, like
# its permissions above, lives entirely on GitHub's own consent screen and can
# be narrowed at any time with nothing in this repository the wiser — and
# `scripts/doctor.sh`'s autonomy-readiness verdict was checking the
# permissions without ever checking that they applied to the repository in
# front of it. A repository configured at `agent-approves` or above that the
# App cannot see is a verdict of "fully supported" over an App that can
# neither review nor land there. One App may hold several installations
# (agent-ops#913), so this is read once per distinct installation, never once
# fleet-wide.
approver_token_installation_repositories() {
  local slug="${1:-}" now="${2:-$(date +%s)}" installation_id
  installation_id="$(approver_token_installation_id_for "$slug")" || installation_id=""
  github_app_token_installation_repositories \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "$installation_id" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
    "${APPROVER_TOKEN_CACHE_DIR:-/dev/shm}" \
    "pullwright-approver-token" \
    "${APPROVER_TOKEN_CURL:-curl}" \
    "${APPROVER_TOKEN_OPENSSL:-openssl}" \
    "$now"
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
#
# Takes no owner/slug (agent-ops#913): the App's own login (`GET /app`) is
# identical across every installation of the same App, so this asks for *any*
# configured installation (approver_token_any_installation_id) purely to
# satisfy the shared credential-present gate — never a specific owner's.
approver_token_identity_login() {
  local now="${1:-$(date +%s)}" installation_id
  installation_id="$(approver_token_any_installation_id)" || installation_id=""
  github_app_token_identity_login \
    "${PULLWRIGHT_APPROVER_APP_ID:-}" \
    "$installation_id" \
    "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
    "${APPROVER_TOKEN_CURL:-curl}" \
    "${APPROVER_TOKEN_OPENSSL:-openssl}" \
    "$now"
}
