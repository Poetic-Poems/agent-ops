#!/usr/bin/env bash
#
# test/forge-auth.test.sh — regression test for lib/forge-auth.sh (D18
# decision 1, agent-ops#607 Phase 2).
#
# What must hold, always: the forge authoring App's own minted token is
# selected whenever it is configured and a mint succeeds; the node's ambient
# GH_TOKEN is selected in every other case — unconfigured, or configured but
# a mint just failed — and this file never blocks or fails, only degrades.
# `forge_auth_effective_gh_token` must always name which path was taken
# (SOURCE) alongside the token itself, on one tab-separated line, since a
# plain `x="$(...)"` command substitution runs in a subshell and could never
# hand a side-effect global back to the caller.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/forge-auth.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/author-token.sh
. "$SCRIPT_DIR/lib/author-token.sh"
# shellcheck source=lib/forge-auth.sh
. "$SCRIPT_DIR/lib/forge-auth.sh"

tmp_dir="$(mktemp -d)"
cache_dir="$(mktemp -d /dev/shm/forge-auth-test.XXXXXX)"
trap 'rm -rf "$tmp_dir" "$cache_dir"' EXIT

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

key_path="$tmp_dir/app-key.pem"
openssl genrsa -out "$key_path" 2048 >/dev/null 2>&1
chmod 600 "$key_path"

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
cat >/dev/null 2>&1
[[ -f "\$d/curl_fail" ]] && exit 1
status="\$(cat "\$d/curl_status" 2>/dev/null || echo 201)"
body="\$(cat "\$d/curl_body" 2>/dev/null || echo '{}')"
printf '%s\n%s' "\$body" "\$status"
STUB
chmod +x "$tmp_dir/curl"

clear_author_env() {
  unset PULLWRIGHT_AUTHOR_APP_ID PULLWRIGHT_AUTHOR_INSTALLATION_ID \
    PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH AUTHOR_TOKEN_CURL AUTHOR_TOKEN_CACHE_DIR
}
setup_author_env() {
  PULLWRIGHT_AUTHOR_APP_ID="7710033"
  PULLWRIGHT_AUTHOR_INSTALLATION_ID="882110044"
  PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH="$key_path"
  AUTHOR_TOKEN_CURL="$tmp_dir/curl"
  AUTHOR_TOKEN_CACHE_DIR="$cache_dir"
  export PULLWRIGHT_AUTHOR_APP_ID PULLWRIGHT_AUTHOR_INSTALLATION_ID \
    PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH AUTHOR_TOKEN_CURL AUTHOR_TOKEN_CACHE_DIR
}

now=1786708800  # 2026-08-14T12:00:00Z

# --- No forge authoring App configured: the ambient GH_TOKEN, unchanged ----
clear_author_env
GH_TOKEN="ghp_the_owner_pat"
export GH_TOKEN
IFS=$'\t' read -r src out < <(forge_auth_effective_gh_token "$now" 2>/dev/null)
assert_eq "no App configured: the ambient GH_TOKEN is returned" "ghp_the_owner_pat" "$out"
assert_eq "  ... source names the plain GH_TOKEN path" "gh-token" "$src"

# --- No forge authoring App configured, and no GH_TOKEN either: empty, still
#     never fails — the pre-existing "GH_TOKEN unset" case is unchanged. ----
clear_author_env
unset GH_TOKEN
IFS=$'\t' read -r src out < <(forge_auth_effective_gh_token "$now" 2>/dev/null)
assert_eq "  ... empty output" "" "$out"
assert_eq "no App and no GH_TOKEN: source still names the plain GH_TOKEN path" "gh-token" "$src"

# --- The App is configured and mints successfully: its token wins over
#     whatever GH_TOKEN already held. --------------------------------------
setup_author_env
rm -f "$cache_dir"/*
GH_TOKEN="ghp_the_owner_pat"
export GH_TOKEN
stub_curl 201 '{"token":"ghs_forgeauth000","expires_at":"2026-08-14T14:00:00Z"}'
IFS=$'\t' read -r src out < <(forge_auth_effective_gh_token "$now" 2>/dev/null)
assert_eq "App configured and mints: its own token is preferred over GH_TOKEN" \
  "ghs_forgeauth000" "$out"
assert_eq "  ... source names the forge-app path" "forge-app" "$src"

# --- The App is configured but a mint fails: degrade to GH_TOKEN, never fail
setup_author_env
rm -f "$cache_dir"/*
GH_TOKEN="ghp_the_owner_pat"
export GH_TOKEN
stub_curl 401 '{"message":"Bad credentials"}'
IFS=$'\t' read -r src out < <(forge_auth_effective_gh_token "$now" 2>/dev/null)
assert_eq "App configured but mint fails: falls back to GH_TOKEN" "ghp_the_owner_pat" "$out"
assert_eq "  ... source names the degraded path" "gh-token-degraded" "$src"

# --- The App is configured but unreachable (network failure): same degrade -
setup_author_env
rm -f "$cache_dir"/*
GH_TOKEN="ghp_the_owner_pat"
export GH_TOKEN
stub_curl 201 '{}'
: > "$tmp_dir/curl_fail"
IFS=$'\t' read -r src out < <(forge_auth_effective_gh_token "$now" 2>/dev/null)
assert_eq "App unreachable: falls back to GH_TOKEN" "ghp_the_owner_pat" "$out"
assert_eq "  ... source names the degraded path" "gh-token-degraded" "$src"
rm -f "$tmp_dir/curl_fail"

# --- The App is configured, mints fail, and GH_TOKEN is also unset: still
#     never fails — empty output, degraded source. --------------------------
setup_author_env
rm -f "$cache_dir"/*
unset GH_TOKEN
stub_curl 401 '{"message":"Bad credentials"}'
IFS=$'\t' read -r src out < <(forge_auth_effective_gh_token "$now" 2>/dev/null)
assert_eq "App fails and no GH_TOKEN either: empty output" "" "$out"
assert_eq "  ... source names the degraded path" "gh-token-degraded" "$src"

# --- A cached App token is reused rather than re-minted on the next call ---
setup_author_env
rm -f "$cache_dir"/*
GH_TOKEN="ghp_the_owner_pat"
export GH_TOKEN
stub_curl 201 '{"token":"ghs_forgeauth111","expires_at":"2026-08-14T14:00:00Z"}'
forge_auth_effective_gh_token "$now" >/dev/null
IFS=$'\t' read -r src out < <(forge_auth_effective_gh_token "$((now + 60))" 2>/dev/null)
assert_eq "second call within the token's lifetime: still the App's token" \
  "ghs_forgeauth111" "$out"
assert_eq "  ... no new mint call" "1" "$(wc -l < "$tmp_dir/curl_calls")"
assert_eq "  ... source still names the forge-app path" "forge-app" "$src"

clear_author_env
unset GH_TOKEN

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
