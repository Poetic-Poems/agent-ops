#!/usr/bin/env bash
#
# lib/approver-token.sh — GitHub App installation-token minting for the
# Pullwright Approver (D18 WI-4, agent-ops#407; design:
# docs/reviews/2026-08-14-autonomy-investigation.md §5.3).
#
# The Approver acts as a GitHub App identity ("Pullwright Approver",
# agent-ops#406), not the owner's PAT: an App-submitted review is what makes
# `required_approving_review_count: 1` load-bearing without recreating
# self-approval. `gh` cannot mint an App installation token on its own — it
# authenticates as the owner PAT or as a user OAuth token — so this file does
# the three-step dance by hand: sign a short-lived JWT with the App's private
# key, exchange it for an installation token (~1 h lifetime), cache the
# result until shortly before it expires.
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
# comment describes; wiring it into a node's compose/.env is a later work
# item's job, once something (D18 WI-5, the Approver stage) actually calls
# this file.
#
# Fail-closed, by design: `approver_token_get` returns a distinct non-zero
# status (2) when the credential is not configured or not readable, so a
# caller can tell "there is nothing to check" apart from "GitHub refused the
# request" (1) — the arming path must treat *both* as "gate unreadable" and
# hand back rather than proceed as though the gate had been read and passed,
# but the distinction is worth keeping for anyone reading a log. There is no
# fallback to any PAT anywhere in this file: it references no other
# credential, so an absent App key can never silently reroute an
# approve/land call through the owner's own token, which would recreate the
# self-approval the App exists to retire.
#
# The minted token is never written to persistent storage and never logged.
# `approver_token_get` prints it to stdout and nowhere else; every error path
# below prints a diagnosis, never the token or the JWT that produced it. The
# one cache this file keeps is best-effort and tmpfs-only — `/dev/shm` by
# default, mode 600 — so a token can be reused across separate invocations
# within its lifetime without ever touching a disk-backed path; if that
# directory is unusable for any reason, caching is simply skipped and every
# call mints fresh, which is correct, just less efficient.
#
# Sourced, never executed: it sets no shell options, so a caller's own
# `set -euo pipefail` (agent-cycle.sh) or `set -uo pipefail` decides.
#
# Environment overrides, for tests only: APPROVER_TOKEN_CURL, APPROVER_TOKEN_OPENSSL
# (stub binaries) and APPROVER_TOKEN_CACHE_DIR (stand in for tmpfs).

# _approver_token_b64
# Read stdin, print unpadded base64url — the encoding a JWT's header, payload
# and signature all need (RFC 7515 §2), which plain `base64` does not produce
# on its own.
_approver_token_b64() {
  local openssl_bin="${APPROVER_TOKEN_OPENSSL:-openssl}"
  "$openssl_bin" base64 -A | tr '+/' '-_' | tr -d '='
}

# _approver_token_jwt APP_ID NOW_EPOCH KEY_PATH
# Print a signed RS256 App JWT (`iat` a minute in the past, `exp` nine minutes
# ahead — GitHub's own documented tolerance and ceiling for this token,
# verified live against agent-ops#406). Non-zero and nothing on stdout if
# signing fails for any reason (missing/unreadable key, openssl error).
_approver_token_jwt() {
  local app_id="$1" now="$2" key_path="$3"
  local openssl_bin="${APPROVER_TOKEN_OPENSSL:-openssl}"
  local header payload signing_input sig
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | _approver_token_b64)" || return 1
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    "$((now - 60))" "$((now + 540))" "$app_id" | _approver_token_b64)" || return 1
  [[ -n "$header" && -n "$payload" ]] || return 1
  signing_input="$header.$payload"
  sig="$(printf '%s' "$signing_input" \
    | "$openssl_bin" dgst -sha256 -sign "$key_path" 2>/dev/null \
    | _approver_token_b64)" || return 1
  [[ -n "$sig" ]] || return 1
  printf '%s.%s' "$signing_input" "$sig"
}

# _approver_token_mint JWT INSTALLATION_ID
# Exchange a signed App JWT for an installation access token. Prints the
# GitHub API's JSON body ({"token", "expires_at", ...}) on stdout and returns
# 0 only on a real 201; any other status, an unreachable API, or a body
# missing either field is a failure — non-zero, nothing on stdout.
_approver_token_mint() {
  local jwt="$1" installation_id="$2"
  local curl_bin="${APPROVER_TOKEN_CURL:-curl}"
  local response status body
  response="$("$curl_bin" -sS --max-time 30 -w $'\n%{http_code}' -X POST \
    -H "Authorization: Bearer $jwt" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/$installation_id/access_tokens" \
    2>/dev/null)" || return 1
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [[ "$status" == "201" ]] || return 1
  jq -e '(.token // empty) != "" and (.expires_at // empty) != ""' <<<"$body" \
    >/dev/null 2>&1 || return 1
  printf '%s' "$body"
}

# _approver_token_to_epoch ISO8601
# Print an ISO 8601 UTC timestamp ("2026-08-14T13:16:31Z", GitHub's own
# `expires_at` shape) as epoch seconds. Non-zero and nothing on stdout if it
# does not parse.
_approver_token_to_epoch() {
  local iso="$1"
  [[ -n "$iso" ]] || return 1
  date -u -d "$iso" +%s 2>/dev/null
}

# _approver_token_cache_file
# Print the tmpfs path this file caches a minted token at, or nothing if the
# cache directory does not exist — caching is best-effort, never a condition
# for success.
_approver_token_cache_file() {
  local dir="${APPROVER_TOKEN_CACHE_DIR:-/dev/shm}"
  [[ -d "$dir" ]] || return 0
  printf '%s/pullwright-approver-token.json' "$dir"
}

# _approver_token_cache_read CACHE_FILE NOW_EPOCH REFRESH_BUFFER_SECONDS
# Print the cached token on stdout iff CACHE_FILE holds one that will not
# expire within REFRESH_BUFFER_SECONDS of NOW_EPOCH. Silent, non-zero
# otherwise — a missing, unreadable, malformed or near-expiry cache is simply
# "mint a fresh one", never an error.
_approver_token_cache_read() {
  local cache_file="$1" now="$2" buffer="$3"
  [[ -n "$cache_file" && -r "$cache_file" ]] || return 1
  local token exp
  token="$(jq -r '.token // empty' "$cache_file" 2>/dev/null)"
  exp="$(jq -r '.exp_epoch // empty' "$cache_file" 2>/dev/null)"
  [[ -n "$token" && "$exp" =~ ^[0-9]+$ ]] || return 1
  (( now + buffer < exp )) || return 1
  printf '%s' "$token"
}

# _approver_token_cache_write CACHE_FILE TOKEN EXPIRES_AT EXP_EPOCH
# Best-effort: write mode-600 into CACHE_FILE's own tmpfs directory, then
# rename over it, so a reader never observes a partial write. Any failure
# (unwritable directory, `mktemp`/`jq` erroring) is swallowed — a token that
# could not be cached is still a token the caller already has.
_approver_token_cache_write() {
  local cache_file="$1" token="$2" expires_at="$3" exp_epoch="$4"
  [[ -n "$cache_file" ]] || return 0
  local dir tmp
  dir="$(dirname "$cache_file")"
  [[ -d "$dir" && -w "$dir" ]] || return 0
  tmp="$(mktemp "$dir/.pullwright-approver-token.XXXXXX" 2>/dev/null)" || return 0
  if ! ( umask 077; jq -n --arg t "$token" --arg e "$expires_at" --argjson exp "$exp_epoch" \
      '{token: $t, expires_at: $e, exp_epoch: $exp}' > "$tmp" ) 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$cache_file" 2>/dev/null
  return 0
}

# approver_token_credential_present
# True (exit 0) iff all three identity variables are set and the private key
# is readable — the fail-closed check `approver_token_get` itself applies,
# exposed separately so a caller can ask "is the gate even readable" without
# minting anything.
approver_token_credential_present() {
  [[ -n "${PULLWRIGHT_APPROVER_APP_ID:-}" \
     && -n "${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}" \
     && -n "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}" \
     && -r "${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-/dev/null/no-such-key}" ]]
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
  local now="${1:-$(date +%s)}"
  local app_id="${PULLWRIGHT_APPROVER_APP_ID:-}"
  local installation_id="${PULLWRIGHT_APPROVER_INSTALLATION_ID:-}"
  local key_path="${PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH:-}"

  if ! approver_token_credential_present; then
    echo "approver-token: no credential configured — PULLWRIGHT_APPROVER_APP_ID," >&2
    echo "  PULLWRIGHT_APPROVER_INSTALLATION_ID and PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH" >&2
    echo "  must all be set, and the key file must be readable (gate unreadable)" >&2
    return 2
  fi

  local refresh_buffer=300
  local cache_file cached
  cache_file="$(_approver_token_cache_file)"
  if cached="$(_approver_token_cache_read "$cache_file" "$now" "$refresh_buffer")"; then
    printf '%s' "$cached"
    return 0
  fi

  local jwt mint_out token expires_at exp_epoch
  jwt="$(_approver_token_jwt "$app_id" "$now" "$key_path")" || {
    echo "approver-token: failed to build/sign the App JWT" >&2
    return 1
  }
  mint_out="$(_approver_token_mint "$jwt" "$installation_id")" || {
    echo "approver-token: GitHub did not issue an installation token" >&2
    return 1
  }
  token="$(jq -r '.token' <<<"$mint_out")"
  expires_at="$(jq -r '.expires_at' <<<"$mint_out")"
  exp_epoch="$(_approver_token_to_epoch "$expires_at")" || exp_epoch=$(( now + 3300 ))

  _approver_token_cache_write "$cache_file" "$token" "$expires_at" "$exp_epoch"

  printf '%s' "$token"
}
