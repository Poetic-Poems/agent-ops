#!/usr/bin/env bash
#
# lib/github-app-token.sh — GitHub App installation-token minting, generalised
# over identity (D18 §5.3 WI-4, agent-ops#407; generalised by agent-ops#607
# Phase 2). Written first for one caller only — the Pullwright Approver
# (lib/approver-token.sh) — and generalised once a second identity needed the
# identical dance against a different App/installation/key: the forge
# authoring App (lib/author-token.sh, D18 decision 1). The mechanics live here
# exactly once; each identity's own file is a thin wrapper supplying its own
# environment variable names, cache-file prefix and override variables, so a
# fix or a new capability here reaches both callers at once.
#
# `gh` cannot mint an installation token on its own — it authenticates as an
# owner PAT or a user OAuth token — so every function below does the
# three-step dance by hand: sign a short-lived JWT with the App's private
# key, exchange it for an installation token (~1 h lifetime), cache the
# result until shortly before it expires.
#
# Every function is parameterised rather than reading a fixed set of
# environment variables — it carries no identity of its own. A caller passes
# its own app id, installation id, key path, cache directory, cache-file
# prefix, and `curl`/`openssl` binaries (or their test stubs) positionally;
# nothing here ever reads `PULLWRIGHT_APPROVER_*`, `PULLWRIGHT_AUTHOR_*`, or
# any other identity-specific name directly.
#
# Fail-closed, by design: `github_app_token_credential_present` is the
# identity check on its own; every minting/reading function returns a
# distinct non-zero status (2) when the credential is not configured or not
# readable, so a caller can tell "there is nothing to check" apart from
# "GitHub refused the request" (1) — a caller must treat both alike as *gate
# unreadable, hand back*, never as a gate read and passed, but the
# distinction is worth keeping for anyone reading a log. There is no fallback
# to any other credential anywhere in this file: it references only the
# identity values a caller passes in, so an absent App key can never silently
# reroute a call through some other credential — that decision belongs to the
# caller (see lib/forge-auth.sh's own degrade-to-GH_TOKEN logic, which is
# deliberately not here).
#
# The minted token is never written to persistent storage and never logged.
# Every function below prints only the token (or, for the read-only calls,
# the data GitHub returned) to stdout — every error path prints a diagnosis,
# never the token or the JWT that produced it — and the JWT itself travels to
# `curl` on stdin, never in argv, where it would sit world-readable in
# /proc/<pid>/cmdline for the length of the call. The one cache this file
# keeps is best-effort and tmpfs-only, keyed by installation id so one
# installation's token is never served for another's, mode 600, written
# `mktemp`-then-rename so no reader sees a partial write, and read back only
# when the file is this user's own — a cache directory's filesystem type is
# checked before anything is written, so a disk-backed override disables
# caching rather than putting a live token on disk.
#
# Sourced, never executed: it sets no shell options, so a caller's own
# `set -euo pipefail` or `set -uo pipefail` decides.

# _github_app_token_b64
# Read stdin, print unpadded base64url — the encoding a JWT's header, payload
# and signature all need (RFC 7515 §2), which plain `base64` does not produce
# on its own.
_github_app_token_b64() {
  local openssl_bin="$1"
  "$openssl_bin" base64 -A | tr '+/' '-_' | tr -d '='
}

# _github_app_token_jwt APP_ID NOW_EPOCH KEY_PATH OPENSSL_BIN
# Print a signed RS256 App JWT (`iat` a minute in the past, `exp` nine minutes
# ahead — GitHub's own documented tolerance and ceiling for this token).
# Non-zero and nothing on stdout if signing fails for any reason (missing/
# unreadable key, openssl error).
_github_app_token_jwt() {
  local app_id="$1" now="$2" key_path="$3" openssl_bin="$4"
  local header payload signing_input sig
  header="$(printf '{"alg":"RS256","typ":"JWT"}' | _github_app_token_b64 "$openssl_bin")" || return 1
  payload="$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    "$((now - 60))" "$((now + 540))" "$app_id" | _github_app_token_b64 "$openssl_bin")" || return 1
  [[ -n "$header" && -n "$payload" ]] || return 1
  signing_input="$header.$payload"
  sig="$(printf '%s' "$signing_input" \
    | "$openssl_bin" dgst -sha256 -sign "$key_path" 2>/dev/null \
    | _github_app_token_b64 "$openssl_bin")" || return 1
  [[ -n "$sig" ]] || return 1
  printf '%s.%s' "$signing_input" "$sig"
}

# _github_app_token_mint JWT INSTALLATION_ID CURL_BIN
# Exchange a signed App JWT for an installation access token. Prints the
# GitHub API's JSON body ({"token", "expires_at", ...}) on stdout and returns
# 0 only on a real 201; any other status, an unreachable API, or a body
# missing either field is a failure — non-zero, nothing on stdout.
#
# The Authorization header travels on stdin (`--config -`), never in argv:
# only the ~9-minute App JWT would be exposed — the minted token never goes
# near argv — but that JWT mints installation tokens, so it gets the same
# treatment. Nothing else competes for stdin here; the request has no body.
_github_app_token_mint() {
  local jwt="$1" installation_id="$2" curl_bin="$3"
  local response status body
  response="$(printf 'header = "Authorization: Bearer %s"\n' "$jwt" \
    | "$curl_bin" --config - -sS --max-time 30 -w $'\n%{http_code}' -X POST \
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

# _github_app_token_to_epoch ISO8601
# Print an ISO 8601 UTC timestamp ("2026-08-14T13:16:31Z", GitHub's own
# `expires_at` shape) as epoch seconds. Non-zero and nothing on stdout if it
# does not parse.
_github_app_token_to_epoch() {
  local iso="$1"
  [[ -n "$iso" ]] || return 1
  date -u -d "$iso" +%s 2>/dev/null
}

# _github_app_token_cache_file CACHE_DIR CACHE_PREFIX INSTALLATION_ID
# Print the tmpfs path this identity caches a minted token at, or nothing if
# the cache directory does not exist or is not tmpfs-backed — caching is
# best-effort, never a condition for success.
#
# The filename carries the installation id, so a token is only ever served to
# the installation it was minted for. CACHE_PREFIX is what keeps two
# identities sharing one cache directory (as every node here does — /dev/shm)
# from ever colliding on the same filename.
#
# The filesystem-type check is what makes "never touches persistent storage"
# enforced rather than assumed: a caller's own cache-dir override is an
# ordinary environment variable, so without the check anything setting it to
# a disk-backed path would put a live token on disk, silently. A directory
# that is not tmpfs/ramfs gets no cache at all — every call mints fresh,
# which is correct, just less efficient.
_github_app_token_cache_file() {
  local cache_dir="$1" cache_prefix="$2" installation_id="$3"
  [[ -d "$cache_dir" ]] || return 0
  local fs_type
  fs_type="$(stat -f -c %T "$cache_dir" 2>/dev/null)" || return 0
  [[ "$fs_type" == "tmpfs" || "$fs_type" == "ramfs" ]] || return 0
  printf '%s/%s.%s.json' "$cache_dir" "$cache_prefix" "${installation_id//[^0-9A-Za-z_-]/_}"
}

# _github_app_token_cache_read CACHE_FILE NOW_EPOCH REFRESH_BUFFER_SECONDS
# Print the cached token on stdout iff CACHE_FILE holds one that will not
# expire within REFRESH_BUFFER_SECONDS of NOW_EPOCH. Silent, non-zero
# otherwise — a missing, unreadable, malformed or near-expiry cache is simply
# "mint a fresh one", never an error.
#
# The provenance check is not decoration. The default cache directory
# `/dev/shm` is mode 1777, and a file's name in it is fixed and predictable,
# so any local user can create it first — the sticky bit stops them replacing
# *our* file, not claiming the name before we do. Without the check below we
# would then read a token of their choosing and hand it to a caller as this
# identity's credential. So: not a symlink, and owned by this user, or it is
# not ours and we mint fresh instead. (The write path needs no equivalent —
# it is `mktemp` plus a rename, which replaces a planted symlink rather than
# following it, and cannot rename over a file it does not own.)
_github_app_token_cache_read() {
  local cache_file="$1" now="$2" buffer="$3"
  [[ -n "$cache_file" && -r "$cache_file" ]] || return 1
  [[ ! -L "$cache_file" && -O "$cache_file" ]] || return 1
  local token exp
  token="$(jq -r '.token // empty' "$cache_file" 2>/dev/null)"
  exp="$(jq -r '.exp_epoch // empty' "$cache_file" 2>/dev/null)"
  [[ -n "$token" && "$exp" =~ ^[0-9]+$ ]] || return 1
  (( now + buffer < exp )) || return 1
  printf '%s' "$token"
}

# _github_app_token_cache_write CACHE_FILE TOKEN EXPIRES_AT EXP_EPOCH
# Best-effort: write mode-600 into CACHE_FILE's own tmpfs directory, then
# rename over it, so a reader never observes a partial write. Any failure
# (unwritable directory, `mktemp`/`jq` erroring) is swallowed — a token that
# could not be cached is still a token the caller already has.
_github_app_token_cache_write() {
  local cache_file="$1" token="$2" expires_at="$3" exp_epoch="$4"
  [[ -n "$cache_file" ]] || return 0
  local dir tmp
  dir="$(dirname "$cache_file")"
  [[ -d "$dir" && -w "$dir" ]] || return 0
  tmp="$(mktemp "$dir/.github-app-token.XXXXXX" 2>/dev/null)" || return 0
  if ! ( umask 077; jq -n --arg t "$token" --arg e "$expires_at" --argjson exp "$exp_epoch" \
      '{token: $t, expires_at: $e, exp_epoch: $exp}' > "$tmp" ) 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$cache_file" 2>/dev/null
  return 0
}

# github_app_token_credential_present APP_ID INSTALLATION_ID KEY_PATH
# True (exit 0) iff all three identity values are non-empty and the private
# key is readable — the fail-closed check `github_app_token_get` itself
# applies, exposed separately so a caller can ask "is the gate even
# readable" without minting anything.
github_app_token_credential_present() {
  local app_id="$1" installation_id="$2" key_path="$3"
  [[ -n "$app_id" && -n "$installation_id" && -n "$key_path" && -r "$key_path" ]]
}

# github_app_token_get APP_ID INSTALLATION_ID KEY_PATH CACHE_DIR CACHE_PREFIX
#                       CURL_BIN OPENSSL_BIN [NOW_EPOCH]
# Print a valid installation token for this identity on stdout. NOW_EPOCH
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
github_app_token_get() {
  local app_id="$1" installation_id="$2" key_path="$3" cache_dir="$4" cache_prefix="$5" \
        curl_bin="$6" openssl_bin="$7" now="${8:-$(date +%s)}"

  if ! github_app_token_credential_present "$app_id" "$installation_id" "$key_path"; then
    echo "github-app-token ($cache_prefix): no credential configured — app id," >&2
    echo "  installation id and a readable private key must all be present (gate unreadable)" >&2
    return 2
  fi

  local refresh_buffer=300
  local cache_file cached
  cache_file="$(_github_app_token_cache_file "$cache_dir" "$cache_prefix" "$installation_id")"
  if cached="$(_github_app_token_cache_read "$cache_file" "$now" "$refresh_buffer")"; then
    printf '%s' "$cached"
    return 0
  fi

  local jwt mint_out token expires_at exp_epoch
  jwt="$(_github_app_token_jwt "$app_id" "$now" "$key_path" "$openssl_bin")" || {
    echo "github-app-token ($cache_prefix): failed to build/sign the App JWT" >&2
    return 1
  }
  mint_out="$(_github_app_token_mint "$jwt" "$installation_id" "$curl_bin")" || {
    echo "github-app-token ($cache_prefix): GitHub did not issue an installation token" >&2
    return 1
  }
  token="$(jq -r '.token' <<<"$mint_out")"
  expires_at="$(jq -r '.expires_at' <<<"$mint_out")"

  # An `expires_at` that does not parse is never guessed at: the token is
  # still returned — GitHub issued it, and refusing it over a timestamp
  # format would turn a cosmetic API change into an outage — but it is not
  # cached, since a cache entry needs an expiry this file can actually stand
  # behind. Every call simply mints fresh until the shape parses again.
  if exp_epoch="$(_github_app_token_to_epoch "$expires_at")"; then
    _github_app_token_cache_write "$cache_file" "$token" "$expires_at" "$exp_epoch"
  fi

  printf '%s' "$token"
}

# github_app_token_installation_permissions APP_ID INSTALLATION_ID KEY_PATH
#                                            CURL_BIN OPENSSL_BIN [NOW_EPOCH]
# Print this identity's installation's actual granted permissions — the live
# `.permissions` object from `GET /app/installations/<id>` — or return
# non-zero, printing nothing, on the same "gate unreadable" terms as
# `github_app_token_get` (2 no credential, 1 mint/request failed).
#
# JWT-signed: an installation *access token* can act as the installation but
# cannot ask GitHub what it is itself entitled to — only the App's own JWT
# can read `/app/installations/<id>`. Not cached: this is an operator-invoked
# or doctor-invoked read, never a per-cycle one.
github_app_token_installation_permissions() {
  local app_id="$1" installation_id="$2" key_path="$3" curl_bin="$4" openssl_bin="$5" \
        now="${6:-$(date +%s)}"

  github_app_token_credential_present "$app_id" "$installation_id" "$key_path" || return 2

  local jwt
  jwt="$(_github_app_token_jwt "$app_id" "$now" "$key_path" "$openssl_bin")" || return 1

  local response status body
  response="$(printf 'header = "Authorization: Bearer %s"\n' "$jwt" \
    | "$curl_bin" --config - -sS --max-time 30 -w $'\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/$installation_id" 2>/dev/null)" || return 1
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [[ "$status" == "200" ]] || return 1
  jq -e '(.permissions // empty) != {}' <<<"$body" >/dev/null 2>&1 || return 1
  jq -c '.permissions' <<<"$body"
}

# github_app_token_installation_repositories APP_ID INSTALLATION_ID KEY_PATH
#     CACHE_DIR CACHE_PREFIX CURL_BIN OPENSSL_BIN [NOW_EPOCH]
# Print the repositories this identity's installation can actually act on —
# one `owner/name` per line — or the single word `all` when the installation
# was granted every repository in the account. Returns non-zero, printing
# nothing, on the same "gate unreadable" terms as `github_app_token_get`
# (2 no credential, 1 request failed).
#
# Installation-token-signed, not JWT-signed: `/app/installations/<id>` (the
# JWT read above) reports `repository_selection` but never the list, and
# `/installation/repositories` — which does — is readable only *as* the
# installation.
#
# A listing this call could not read whole is an error, never a short list:
# `total_count` is compared against what came back, and a page that dropped
# repositories returns 1 rather than the partial set.
github_app_token_installation_repositories() {
  local app_id="$1" installation_id="$2" key_path="$3" cache_dir="$4" cache_prefix="$5" \
        curl_bin="$6" openssl_bin="$7" now="${8:-$(date +%s)}"
  local token response status body

  github_app_token_credential_present "$app_id" "$installation_id" "$key_path" || return 2
  token="$(github_app_token_get "$app_id" "$installation_id" "$key_path" \
    "$cache_dir" "$cache_prefix" "$curl_bin" "$openssl_bin" "$now")" || return 1
  [[ -n "$token" ]] || return 1

  response="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | "$curl_bin" --config - -sS --max-time 30 -w $'\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/installation/repositories?per_page=100" 2>/dev/null)" || return 1
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [[ "$status" == "200" ]] || return 1

  if [[ "$(jq -r '.repository_selection // ""' <<<"$body" 2>/dev/null)" == "all" ]]; then
    printf 'all\n'
    return 0
  fi

  jq -e 'has("repositories") and ((.repositories | length) >= (.total_count // 0))' \
    <<<"$body" >/dev/null 2>&1 || return 1
  jq -r '.repositories[].full_name' <<<"$body" 2>/dev/null || return 1
}

# github_app_token_identity_login APP_ID INSTALLATION_ID KEY_PATH CURL_BIN
#                                  OPENSSL_BIN [NOW_EPOCH]
# Print this identity's own GitHub login ("<app-slug>[bot]", the form every
# review, comment, commit or pull request it writes carries as its
# `user.login`) — or return non-zero, printing nothing, on the same "gate
# unreadable" terms as `github_app_token_get`. INSTALLATION_ID is accepted
# (and covered by the same credential-present check as every other call
# here, for one consistent "is this identity configured at all" answer) but
# unused beyond that: `GET /app` asks as the App itself and needs no
# installation to sign against.
#
# This is the one call in this file that authenticates as the App itself
# (JWT-signed) rather than as an installation: an installation token can
# post as the App but cannot ask GitHub what its own slug is.
#
# Not cached, unlike `github_app_token_get`'s installation token: asked
# rarely, and an App's slug changes essentially never, so a second cache
# file would buy nothing a fresh JWT-signed call each time does not already
# give for free.
github_app_token_identity_login() {
  local app_id="$1" installation_id="$2" key_path="$3" curl_bin="$4" openssl_bin="$5" \
        now="${6:-$(date +%s)}"

  github_app_token_credential_present "$app_id" "$installation_id" "$key_path" || return 2

  local jwt
  jwt="$(_github_app_token_jwt "$app_id" "$now" "$key_path" "$openssl_bin")" || return 1

  local response status body slug
  response="$(printf 'header = "Authorization: Bearer %s"\n' "$jwt" \
    | "$curl_bin" --config - -sS --max-time 30 -w $'\n%{http_code}' \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app" 2>/dev/null)" || return 1
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [[ "$status" == "200" ]] || return 1
  slug="$(jq -r '.slug // empty' <<<"$body" 2>/dev/null)"
  [[ -n "$slug" ]] || return 1
  printf '%s[bot]' "$slug"
}
