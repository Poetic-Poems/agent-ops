#!/usr/bin/env bash
#
# test/author-token.test.sh — regression test for lib/author-token.sh (D18
# decision 1, agent-ops#607 Phase 2).
#
# lib/author-token.sh is a thin wrapper over the same lib/github-app-token.sh
# mechanics test/approver-token.test.sh already exercises in full — the JWT
# signing, the mint, the cache's expiry/ownership/tmpfs-only guarantees — so
# this file does not re-prove all of that. It proves instead that the forge
# authoring App's own three environment variables, cache-file prefix and
# override variables are wired correctly and stay isolated from the
# Approver's: what must hold, always, is that a caller never mistakes "no
# credential" for "a token", never sees a GH_TOKEN fallback anywhere in this
# file, and never has this identity's cache collide with the Approver's.
#
# `curl` is stubbed through AUTHOR_TOKEN_CURL; real `openssl` signs a
# throwaway RSA key generated for this run, so the JWT-building path is
# exercised for real rather than faked.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/author-token.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/author-token.sh
. "$SCRIPT_DIR/lib/author-token.sh"

tmp_dir="$(mktemp -d)"
# The cache tests need a directory the wrapper's mount-type check accepts, so
# they live under /dev/shm — the same tmpfs the runtime default points at.
cache_dir="$(mktemp -d /dev/shm/author-token-test.XXXXXX)"
trap 'rm -rf "$tmp_dir" "$cache_dir"' EXIT

# The cache filename the wrapper derives for setup_env's installation id
# below — keyed by that id and prefixed "pullwright-author-token", so this
# identity's cache can never collide with the Approver's own
# "pullwright-approver-token" prefix even in the same directory.
cache_file_name="pullwright-author-token.882110044.json"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_true() {
  local desc="$1"
  if "${@:2}"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

# --- A regression guard against a GH_TOKEN fallback -------------------------
# Nothing in this file, or the shared core it wraps, may *use* GH_TOKEN (or
# any other credential) as a shell variable — either mints from this App's
# own key, or fails closed. The degrade-to-GH_TOKEN decision belongs entirely
# to lib/forge-auth.sh, never to this file or lib/github-app-token.sh.
assert_eq "the wrapper never references \$GH_TOKEN as a variable" "" \
  "$(grep -oE '\$\{?GH_TOKEN\b' "$SCRIPT_DIR/lib/author-token.sh" || true)"
assert_eq "the shared core never references \$GH_TOKEN as a variable" "" \
  "$(grep -oE '\$\{?GH_TOKEN\b' "$SCRIPT_DIR/lib/github-app-token.sh" || true)"

# --- A throwaway App key for this run ---------------------------------------
key_path="$tmp_dir/app-key.pem"
openssl genrsa -out "$key_path" 2048 >/dev/null 2>&1
chmod 600 "$key_path"

# --- The stub curl -----------------------------------------------------------
stub_curl() {
  local status="${1:-201}" body="$2"
  printf '%s' "$status" > "$tmp_dir/curl_status"
  printf '%s' "$body" > "$tmp_dir/curl_body"
  rm -f "$tmp_dir/curl_fail" "$tmp_dir/curl_calls" \
    "$tmp_dir/curl_argv" "$tmp_dir/curl_stdin"
}

cat > "$tmp_dir/curl" <<STUB
#!/usr/bin/env bash
d="$tmp_dir"
printf 'call\n' >> "\$d/curl_calls"
printf '%s\n' "\$@" >> "\$d/curl_argv"
cat >> "\$d/curl_stdin" 2>/dev/null
[[ -f "\$d/curl_fail" ]] && exit 1
status="\$(cat "\$d/curl_status" 2>/dev/null || echo 201)"
body="\$(cat "\$d/curl_body" 2>/dev/null || echo '{}')"
printf '%s\n%s' "\$body" "\$status"
STUB
chmod +x "$tmp_dir/curl"

setup_env() {
  PULLWRIGHT_AUTHOR_APP_ID="7710033"
  PULLWRIGHT_AUTHOR_INSTALLATION_ID="882110044"
  PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH="$key_path"
  AUTHOR_TOKEN_CURL="$tmp_dir/curl"
  AUTHOR_TOKEN_CACHE_DIR="$cache_dir"
  export PULLWRIGHT_AUTHOR_APP_ID PULLWRIGHT_AUTHOR_INSTALLATION_ID \
    PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH AUTHOR_TOKEN_CURL AUTHOR_TOKEN_CACHE_DIR
}
clear_env() {
  unset PULLWRIGHT_AUTHOR_APP_ID PULLWRIGHT_AUTHOR_INSTALLATION_ID \
    PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH AUTHOR_TOKEN_CURL AUTHOR_TOKEN_CACHE_DIR
}

call_count() {
  if [[ -f "$tmp_dir/curl_calls" ]]; then
    wc -l < "$tmp_dir/curl_calls"
  else
    printf '0\n'
  fi
}

# --- Success path ------------------------------------------------------------
setup_env
rm -f "$cache_dir"/*
body='{"token":"ghs_author000","expires_at":"2026-08-14T14:00:00Z"}'
stub_curl 201 "$body"
now=1786708800  # 2026-08-14T12:00:00Z
out="$(author_token_get "$now")"; rc=$?
assert_eq "success path: exit 0" "0" "$rc"
assert_eq "  ... the minted token on stdout" "ghs_author000" "$out"
assert_eq "  ... exactly one mint call" "1" "$(call_count)"
assert_true "  ... the cache file exists" test -f "$cache_dir/$cache_file_name"
perm="$(stat -c '%a' "$cache_dir/$cache_file_name" 2>/dev/null)"
assert_eq "  ... the cache file is mode 600" "600" "$perm"

# --- A second call within the token's lifetime reuses the cache, mints nothing
out2="$(author_token_get "$((now + 60))")"; rc=$?
assert_eq "cached call: exit 0" "0" "$rc"
assert_eq "  ... the same cached token" "ghs_author000" "$out2"
assert_eq "  ... no new mint call" "1" "$(call_count)"

# --- Expired token refresh: cache is honoured until near expiry, then a fresh
#     mint replaces it ---------------------------------------------------------
stub_curl 201 '{"token":"ghs_author111","expires_at":"2026-08-14T15:00:00Z"}'
near_expiry=1786715900  # 100s before the cached token's 14:00:00Z expiry — inside the 5-minute buffer
out3="$(author_token_get "$near_expiry")"; rc=$?
assert_eq "near-expiry call: exit 0" "0" "$rc"
assert_eq "  ... a freshly minted token, not the stale cached one" "ghs_author111" "$out3"
assert_eq "  ... a new mint call was made" "1" "$(call_count)"

# --- Missing credential: distinct exit 2, no output, no mint attempt --------
setup_env
rm -f "$cache_dir"/*
stub_curl 201 '{"token":"should-not-be-minted","expires_at":"2026-08-14T20:00:00Z"}'
unset PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH
out="$(author_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "no key path set: exit 2" "2" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... no mint call was attempted" "0" "$(call_count)"

setup_env
unset PULLWRIGHT_AUTHOR_APP_ID
out="$(author_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "no App id set: exit 2" "2" "$rc"

setup_env
unset PULLWRIGHT_AUTHOR_INSTALLATION_ID
out="$(author_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "no installation id set: exit 2" "2" "$rc"

setup_env
PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH="$tmp_dir/no-such-key.pem"
export PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH
out="$(author_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "key file does not exist: exit 2" "2" "$rc"

# --- author_token_credential_present mirrors the same check ----------------
setup_env
rm -f "$cache_dir"/*
assert_true "credential_present: true when fully configured" author_token_credential_present
unset PULLWRIGHT_AUTHOR_APP_ID
if author_token_credential_present; then
  assert_eq "credential_present: false with no App id" "false" "true"
else
  assert_eq "credential_present: false with no App id" "false" "false"
fi
clear_env
if author_token_credential_present; then
  assert_eq "credential_present: false with nothing configured" "false" "true"
else
  assert_eq "credential_present: false with nothing configured" "false" "false"
fi

# --- A mint failure (GitHub refuses) is exit 1, distinct from exit 2 -------
setup_env
rm -f "$cache_dir"/*
stub_curl 401 '{"message":"Bad credentials"}'
out="$(author_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "GitHub refuses the JWT: exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"

# --- curl itself failing (network/timeout) is also exit 1 -------------------
setup_env
rm -f "$cache_dir"/*
stub_curl 201 '{}'
: > "$tmp_dir/curl_fail"
out="$(author_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "curl fails outright: exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"
rm -f "$tmp_dir/curl_fail"

# --- The Approver and the forge authoring App never share a cache file, even
#     pointed at the same directory -----------------------------------------
setup_env
rm -f "$cache_dir"/*
stub_curl 201 '{"token":"ghs_authorshared","expires_at":"2026-08-14T14:00:00Z"}'
author_token_get "$now" >/dev/null 2>&1
PULLWRIGHT_APPROVER_APP_ID="4593249"
PULLWRIGHT_APPROVER_INSTALLATION_ID="882110044"
PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$key_path"
APPROVER_TOKEN_CURL="$tmp_dir/curl"
APPROVER_TOKEN_CACHE_DIR="$cache_dir"
export PULLWRIGHT_APPROVER_APP_ID PULLWRIGHT_APPROVER_INSTALLATION_ID \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH APPROVER_TOKEN_CURL APPROVER_TOKEN_CACHE_DIR
# shellcheck source=lib/approver-token.sh
. "$SCRIPT_DIR/lib/approver-token.sh"
stub_curl 201 '{"token":"ghs_approvershared","expires_at":"2026-08-14T14:00:00Z"}'
out="$(approver_token_get "$now")"
assert_eq "same installation id, same cache dir, different identity: still mints its own" \
  "ghs_approvershared" "$out"
assert_true "  ... each identity holds its own cache file" \
  test -f "$cache_dir/pullwright-approver-token.882110044.json"
assert_true "  ... the author's own cache file is untouched" \
  test -f "$cache_dir/$cache_file_name"
unset PULLWRIGHT_APPROVER_APP_ID PULLWRIGHT_APPROVER_INSTALLATION_ID \
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH APPROVER_TOKEN_CURL APPROVER_TOKEN_CACHE_DIR

# --- author_token_identity_login --------------------------------------------
setup_env
stub_curl 200 '{"slug":"pullwright-author","id":7710033}'
out="$(author_token_identity_login "$now")"; rc=$?
assert_eq "identity login: exit 0" "0" "$rc"
assert_eq "  ... the [bot]-suffixed login form commits actually carry" \
  "pullwright-author[bot]" "$out"

stub_curl 404 '{"message":"Not Found"}'
out="$(author_token_identity_login "$now")"; rc=$?
assert_eq "identity login: a non-200 is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

clear_env
out="$(author_token_identity_login "$now")"; rc=$?
assert_eq "identity login: no credential configured is gate-unreadable" "" "$out"
assert_eq "  ... exit 2, the same code author_token_get uses for it" "2" "$rc"

clear_env

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
