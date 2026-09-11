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
# Four environment variables carry this identity, the same shape
# lib/approver-token.sh's own four already established:
#
#   PULLWRIGHT_AUTHOR_APP_ID              the App's numeric id
#   PULLWRIGHT_AUTHOR_INSTALLATION_ID     the default installation's numeric id
#   PULLWRIGHT_AUTHOR_INSTALLATION_IDS    per-owner installation ids (JSON map)
#   PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH    path to the App's .pem private key
#
# All optional, and this file degrades rather than bricks a node when
# they are unset or unreadable: `author_token_credential_present` returning
# false, or a mint attempt failing, is exactly the "gate unreadable" contract
# `lib/github-app-token.sh` already specifies, and lib/forge-auth.sh's
# `forge_auth_effective_gh_token` treats both the same way — fall back to the
# node's own `GH_TOKEN`, exactly as every cycle has always authenticated
# before this item. No node bricks over this identity being unconfigured; the
# owner-PAT path keeps working unchanged.
#
# One App, several installations — the same problem agent-ops#913 answered
# for the Approver, answered here the same way (decision #921, "one JSON
# map"), so that provisioning the App (agent-ops#1083, an owner act) cannot
# break authoring into the other organisation. A GitHub App installation is
# per account, and since the 2026-09-07 re-homing this fleet's own
# repositories span two of them — `repos[]` naming `Poetic-Poems/poetic`,
# `Poetic-Poems/poetic-fiddle` and `Pullwright/agent-ops`, `state_repo`
# `Poetic-Poems/agent-ops-state`, `crash_loop_repo` `Pullwright/agent-ops` —
# so one installation id can no longer back every repository this identity
# authors into.
# `PULLWRIGHT_AUTHOR_INSTALLATION_IDS` is a JSON object mapping owner to
# installation id (`{"Pullwright": 12345678, "Poetic-Poems": 87654321}`);
# `author_token_installation_for_owner` resolves it by the owner half of a
# slug, case-insensitively, falling back to the scalar
# `PULLWRIGHT_AUTHOR_INSTALLATION_ID` for an owner the map does not name. A
# single-owner fleet sets only the scalar, exactly as before, and never needs
# the map at all.
#
# Unlike lib/approver-token.sh's own resolver, an **empty owner** here
# resolves to the scalar default rather than to nothing. The difference is
# not cosmetic: every Approver call site holds a repository slug by
# construction, so an empty one there can only be a caller error, whereas
# this identity's busiest caller — lib/gh-shim.sh's `gh_shim_resolve_token`,
# which runs on every single `gh` and `git` credential fill — legitimately
# cannot name an owner for some invocations (`gh auth status`, `gh api user`,
# a bare `gh api rate_limit`). The scalar is precisely the operator's
# declared answer to "when you cannot tell, use this one", and refusing it
# would degrade every such call to the PAT on a fleet that had configured an
# App perfectly well.
#
# Rejected here for the same reason lib/approver-token.sh rejects it:
# deriving the installation from `GET /app/installations` with the App JWT.
# The installation id is an operator *declaration* of where this identity may
# act, and a lookup would let an installation added on any account silently
# widen the fleet's reach.
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

# _author_token_installation_id_valid ID
# True (exit 0) iff ID is a syntactically usable installation id: a non-empty
# run of digits, which is what GitHub issues and the only thing any consumer
# of this file can do anything with. Everything below routes both the map and
# the scalar through here, so a configuration typo can never be *carried* —
# only fallen back from, or reported as gate-unreadable. The three things
# that break on an unchecked id are set out in full in lib/approver-token.sh's
# own copy of this check: a 404 that reads as "GitHub did not issue a token"
# rather than as the typo it is, a cache-key collision between two distinct
# malformed ids (github-app-token.sh's `_github_app_token_cache_file` folds
# every [^0-9A-Za-z_-] to `_`), and `*`/`@` expanding as every element when a
# caller indexes an associative array by installation id (scripts/doctor.sh).
_author_token_installation_id_valid() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# author_token_installation_for_owner OWNER
# Resolve the forge authoring App installation id for a repository slug
# ("owner/repo") or a bare owner, by the owner half, case-insensitively,
# against PULLWRIGHT_AUTHOR_INSTALLATION_IDS (a JSON object of owner to
# installation id), falling back to PULLWRIGHT_AUTHOR_INSTALLATION_ID for an
# owner the map does not name — and for no owner at all. Prints the resolved
# id and returns 0, or prints nothing and returns 1 if neither names it.
#
# An **empty OWNER** skips the map and resolves straight to the scalar
# default: see this file's header for why this identity's answer to "no owner
# in play" differs from the Approver's.
#
# A map that is set but not valid JSON, or not a JSON object, is treated the
# same as an empty map (falls straight through to the scalar default) rather
# than raised as an error here — malformed configuration is exactly what
# scripts/doctor.sh exists to catch before this ever runs against it, and a
# minting path failing closed on a config typo would turn a doctor `fail`
# into a mint failure with a much less specific diagnosis. A malformed
# *value* under a well-formed map key falls through the same way, and for the
# same reason: `null`, an object or an array stringifies to a non-empty token
# that would otherwise shadow a perfectly good scalar default, turning a
# fallback into a permanent mint failure for that one owner.
author_token_installation_for_owner() {
  local owner="${1:-}" id=""
  owner="${owner%%/*}"
  if [[ -n "$owner" && -n "${PULLWRIGHT_AUTHOR_INSTALLATION_IDS:-}" ]]; then
    id="$(jq -r --arg o "$owner" '
      if (type == "object") then
        (to_entries[] | select((.key | ascii_downcase) == ($o | ascii_downcase)) | .value | tostring)
      else empty end
    ' <<<"$PULLWRIGHT_AUTHOR_INSTALLATION_IDS" 2>/dev/null | head -n1)"
    _author_token_installation_id_valid "$id" || id=""
  fi
  if [[ -z "$id" ]]; then
    id="${PULLWRIGHT_AUTHOR_INSTALLATION_ID:-}"
  fi
  _author_token_installation_id_valid "$id" || return 1
  printf '%s' "$id"
}

# author_token_any_installation_id
# Print *some* configured installation id — the default scalar if set, else
# the first entry (by key) of the JSON map — or nothing and return 1 if
# neither is configured. Used only where no specific owner is in play: the
# "is this identity configured at all" gate (deploy/docker/entrypoint.sh's
# own stash decision, scripts/doctor.sh's presence line) and
# `author_token_identity_login`, whose one API call is identical regardless
# of which installation answers the credential-present gate. Never by a mint:
# a token minted against an arbitrary installation is exactly the silent
# wrong answer the per-owner map exists to retire.
author_token_any_installation_id() {
  local id="${PULLWRIGHT_AUTHOR_INSTALLATION_ID:-}"
  _author_token_installation_id_valid "$id" || id=""
  if [[ -z "$id" && -n "${PULLWRIGHT_AUTHOR_INSTALLATION_IDS:-}" ]]; then
    # The first *usable* entry by key, not simply the first: this answers
    # "is any credential configured at all", so a malformed value sorting
    # ahead of a good one must not make the whole map read as unconfigured.
    id="$(jq -r '
      if (type == "object")
      then (to_entries | sort_by(.key) | map(.value | tostring)
            | map(select(test("^[0-9]+$"))) | .[0] // empty)
      else empty end
    ' <<<"$PULLWRIGHT_AUTHOR_INSTALLATION_IDS" 2>/dev/null)"
    _author_token_installation_id_valid "$id" || id=""
  fi
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# author_token_credential_present [OWNER]
# True (exit 0) iff the App id and private key are set, the key is readable,
# and an installation id resolves — for OWNER if given, otherwise any
# configured installation at all (`author_token_any_installation_id`, so a
# fleet carrying only the per-owner map and no scalar default still reads as
# configured). Exposed separately from `author_token_get` so a caller can ask
# "is the gate even readable" without minting anything.
author_token_credential_present() {
  local owner="${1:-}" installation_id
  if [[ -n "$owner" ]]; then
    installation_id="$(author_token_installation_for_owner "$owner")" || installation_id=""
  else
    installation_id="$(author_token_any_installation_id)" || installation_id=""
  fi
  github_app_token_credential_present \
    "${PULLWRIGHT_AUTHOR_APP_ID:-}" \
    "$installation_id" \
    "${PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH:-}"
}

# author_token_get [NOW_EPOCH] [OWNER]
# Print a valid forge authoring App installation token on stdout, for the
# installation OWNER resolves to — or, with no OWNER, for the scalar default
# installation. NOW_EPOCH defaults to the real clock; tests pass it
# explicitly to exercise expiry without waiting on one. (The clock comes
# first here, unlike `approver_token_get`'s slug-first order, because this
# file's own callers have always passed it first and an owner is the
# addition.)
#
# One cache file per installation, since lib/github-app-token.sh keys its
# cache by installation id underneath this file's own
# `pullwright-author-token` prefix — so two owners' tokens can never be
# served for each other, and the Approver's own cache in the same directory
# still cannot collide with either.
#
# Same exit contract as lib/approver-token.sh's approver_token_get: 0 success
# (token on stdout), 2 no credential configured for this owner (gate
# unreadable), 1 a mint attempt was made and refused.
author_token_get() {
  local now="${1:-}" owner="${2:-}" installation_id
  [[ -n "$now" ]] || now="$(date +%s)"
  installation_id="$(author_token_installation_for_owner "$owner")" || installation_id=""
  github_app_token_get \
    "${PULLWRIGHT_AUTHOR_APP_ID:-}" \
    "$installation_id" \
    "${PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH:-}" \
    "${AUTHOR_TOKEN_CACHE_DIR:-/dev/shm}" \
    "pullwright-author-token" \
    "${AUTHOR_TOKEN_CURL:-curl}" \
    "${AUTHOR_TOKEN_OPENSSL:-openssl}" \
    "$now"
}

# author_token_identity_login [NOW_EPOCH] [OWNER]
# Print the forge authoring App's own GitHub login ("<app-slug>[bot]") — used
# by scripts/doctor.sh to report which identity a node actually authors as,
# on the same "gate unreadable" terms as `author_token_get`.
#
# OWNER is accepted for symmetry with `author_token_get` (so doctor can
# report per owner without a second resolution rule), but the App's own login
# (`GET /app`) is identical across every installation of the same App: the
# installation id is used purely to satisfy the shared credential-present
# gate, which is why no OWNER falls back to *any* configured installation
# rather than to the scalar alone.
author_token_identity_login() {
  local now="${1:-}" owner="${2:-}" installation_id
  [[ -n "$now" ]] || now="$(date +%s)"
  if [[ -n "$owner" ]]; then
    installation_id="$(author_token_installation_for_owner "$owner")" || installation_id=""
  else
    installation_id="$(author_token_any_installation_id)" || installation_id=""
  fi
  github_app_token_identity_login \
    "${PULLWRIGHT_AUTHOR_APP_ID:-}" \
    "$installation_id" \
    "${PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH:-}" \
    "${AUTHOR_TOKEN_CURL:-curl}" \
    "${AUTHOR_TOKEN_OPENSSL:-openssl}" \
    "$now"
}
