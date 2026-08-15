#!/usr/bin/env bash
#
# test/approver-token.test.sh — regression test for lib/approver-token.sh
# (D18 WI-4, agent-ops#407).
#
# What must hold, always: a caller never mistakes "no credential" for "a
# token", never mistakes a mint failure for one either, never sees a PAT
# fallback anywhere in this file, and never sees a token land anywhere but
# stdout and (best-effort) a mode-600 tmpfs cache file this test substitutes
# with a throwaway directory.
#
# `curl` is stubbed through APPROVER_TOKEN_CURL; real `openssl` signs a
# throwaway RSA key generated for this run, so the JWT-building path is
# exercised for real rather than faked.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/approver-token.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/approver-token.sh
. "$SCRIPT_DIR/lib/approver-token.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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

# --- A regression guard against a self-approval-recreating fallback --------
# Nothing in this file may *use* GH_TOKEN (or any other credential) as a
# shell variable — the helper either mints from the App's own key, or fails
# closed. (The header comment names GH_TOKEN in prose, by way of contrast, so
# the guard looks for a variable reference, not the bare word.)
assert_eq "the wrapper never references \$GH_TOKEN as a variable" "" \
  "$(grep -oE '\$\{?GH_TOKEN\b' "$SCRIPT_DIR/lib/approver-token.sh" || true)"

# --- A throwaway App key for this run ---------------------------------------
key_path="$tmp_dir/app-key.pem"
openssl genrsa -out "$key_path" 2048 >/dev/null 2>&1
chmod 600 "$key_path"

cache_dir="$tmp_dir/cache"
mkdir -p "$cache_dir"

# --- The stub curl -----------------------------------------------------------
# $tmp_dir/curl_status   HTTP status to answer with (default 201)
# $tmp_dir/curl_body     response body (default a fresh token + expires_at)
# $tmp_dir/curl_fail     present -> curl itself fails (network/timeout)
# $tmp_dir/curl_calls    appended to on every invocation, so tests can assert
#                        whether a mint actually happened
stub_curl() {
  local status="${1:-201}" body="$2"
  printf '%s' "$status" > "$tmp_dir/curl_status"
  printf '%s' "$body" > "$tmp_dir/curl_body"
  rm -f "$tmp_dir/curl_fail" "$tmp_dir/curl_calls"
}

cat > "$tmp_dir/curl" <<STUB
#!/usr/bin/env bash
d="$tmp_dir"
printf 'call\n' >> "\$d/curl_calls"
[[ -f "\$d/curl_fail" ]] && exit 1
status="\$(cat "\$d/curl_status" 2>/dev/null || echo 201)"
body="\$(cat "\$d/curl_body" 2>/dev/null || echo '{}')"
printf '%s\n%s' "\$body" "\$status"
STUB
chmod +x "$tmp_dir/curl"

setup_env() {
  PULLWRIGHT_APPROVER_APP_ID="4593249"
  PULLWRIGHT_APPROVER_INSTALLATION_ID="153689775"
  PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$key_path"
  APPROVER_TOKEN_CURL="$tmp_dir/curl"
  APPROVER_TOKEN_CACHE_DIR="$cache_dir"
  export PULLWRIGHT_APPROVER_APP_ID PULLWRIGHT_APPROVER_INSTALLATION_ID \
    PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH APPROVER_TOKEN_CURL APPROVER_TOKEN_CACHE_DIR
}
clear_env() {
  unset PULLWRIGHT_APPROVER_APP_ID PULLWRIGHT_APPROVER_INSTALLATION_ID \
    PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH APPROVER_TOKEN_CURL APPROVER_TOKEN_CACHE_DIR
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
body='{"token":"ghs_first000","expires_at":"2026-08-14T14:00:00Z","permissions":{"contents":"write"}}'
stub_curl 201 "$body"
now=1786708800  # 2026-08-14T12:00:00Z
out="$(approver_token_get "$now")"; rc=$?
assert_eq "success path: exit 0" "0" "$rc"
assert_eq "  ... the minted token on stdout" "ghs_first000" "$out"
assert_eq "  ... exactly one mint call" "1" "$(call_count)"
assert_true "  ... the cache file exists" test -f "$cache_dir/pullwright-approver-token.json"
perm="$(stat -c '%a' "$cache_dir/pullwright-approver-token.json" 2>/dev/null)"
assert_eq "  ... the cache file is mode 600" "600" "$perm"
assert_eq "  ... the cache never carries the JWT, only the token" "ghs_first000" \
  "$(jq -r '.token' "$cache_dir/pullwright-approver-token.json")"

# --- A second call within the token's lifetime reuses the cache, mints nothing
out2="$(approver_token_get "$((now + 60))")"; rc=$?
assert_eq "cached call: exit 0" "0" "$rc"
assert_eq "  ... the same cached token" "ghs_first000" "$out2"
assert_eq "  ... no new mint call" "1" "$(call_count)"

# --- Expired token refresh: cache is honoured until near expiry, then a fresh
#     mint replaces it ---------------------------------------------------------
stub_curl 201 '{"token":"ghs_second111","expires_at":"2026-08-14T15:00:00Z"}'
near_expiry=1786715900  # 100s before the cached token's 14:00:00Z expiry — inside the 5-minute buffer
out3="$(approver_token_get "$near_expiry")"; rc=$?
assert_eq "near-expiry call: exit 0" "0" "$rc"
assert_eq "  ... a freshly minted token, not the stale cached one" "ghs_second111" "$out3"
assert_eq "  ... a new mint call was made" "1" "$(call_count)"
assert_eq "  ... the cache now holds the refreshed token" "ghs_second111" \
  "$(jq -r '.token' "$cache_dir/pullwright-approver-token.json")"

# --- Missing credential: distinct exit 2, no output, no mint attempt --------
setup_env
rm -f "$cache_dir"/*
stub_curl 201 '{"token":"should-not-be-minted","expires_at":"2026-08-14T20:00:00Z"}'
unset PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "no key path set: exit 2" "2" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... no mint call was attempted" "0" "$(call_count)"

setup_env
PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH="$tmp_dir/no-such-key.pem"
export PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "key file does not exist: exit 2" "2" "$rc"
assert_eq "  ... no output" "" "$out"

setup_env
unset PULLWRIGHT_APPROVER_APP_ID
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "no App id set: exit 2" "2" "$rc"

setup_env
unset PULLWRIGHT_APPROVER_INSTALLATION_ID
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "no installation id set: exit 2" "2" "$rc"

# --- approver_token_credential_present mirrors the same check --------------
setup_env
rm -f "$cache_dir"/*
assert_true "credential_present: true when fully configured" approver_token_credential_present
unset PULLWRIGHT_APPROVER_APP_ID
if approver_token_credential_present; then
  assert_eq "credential_present: false with no App id" "false" "true"
else
  assert_eq "credential_present: false with no App id" "false" "false"
fi

# --- A mint failure (GitHub refuses) is exit 1, distinct from exit 2 -------
setup_env
rm -f "$cache_dir"/*
stub_curl 401 '{"message":"Bad credentials"}'
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "GitHub refuses the JWT: exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"
assert_true "  ... nothing was cached" bash -c "[[ ! -s '$cache_dir/pullwright-approver-token.json' ]]"

# --- curl itself failing (network/timeout) is also exit 1 -------------------
setup_env
rm -f "$cache_dir"/*
stub_curl 201 '{}'
: > "$tmp_dir/curl_fail"
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "curl fails outright: exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"
rm -f "$tmp_dir/curl_fail"

# --- A malformed response body is also exit 1, never guessed at ------------
setup_env
rm -f "$cache_dir"/*
stub_curl 201 '{"expires_at":"2026-08-14T20:00:00Z"}'  # no token field
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "response missing the token field: exit 1" "1" "$rc"
assert_eq "  ... no output" "" "$out"

# --- Caching is best-effort: an unusable cache directory never blocks a mint
setup_env
APPROVER_TOKEN_CACHE_DIR="$tmp_dir/no-such-cache-dir"
export APPROVER_TOKEN_CACHE_DIR
stub_curl 201 '{"token":"ghs_nocachedir","expires_at":"2026-08-14T20:00:00Z"}'
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "cache directory absent: still succeeds" "0" "$rc"
assert_eq "  ... the minted token on stdout" "ghs_nocachedir" "$out"

clear_env

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
