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
# Since the per-owner installation map (`PULLWRIGHT_AUTHOR_INSTALLATION_IDS`,
# the shape agent-ops#913 gave the Approver) it also proves the resolution
# rules themselves — `author_token_installation_for_owner`,
# `author_token_any_installation_id`, and which installation
# `author_token_get`/`author_token_identity_login` actually mint against for
# a given owner. What must hold there is that an owner nothing configures
# resolves to *nothing* rather than to another owner's installation (which
# would 404 at write time instead of failing as a readable gate), and that
# two owners' tokens never share a cache file.
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
    PULLWRIGHT_AUTHOR_INSTALLATION_IDS PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH \
    AUTHOR_TOKEN_CURL AUTHOR_TOKEN_CACHE_DIR
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
# approver_token_get takes the repository slug it mints for first and the
# clock second (agent-ops#913); no PULLWRIGHT_APPROVER_INSTALLATION_IDS is
# set here, so any owner resolves to the scalar id set above.
out="$(approver_token_get "acme-org/widgets" "$now")"
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

# === One App, several installations (the shape agent-ops#913 gave the
#     Approver, applied to this identity) ==================================
#
# A GitHub App installation is per account, and this fleet's repositories
# span two of them, so what must hold here is that *which* installation a
# call mints against follows the owner it names — and that an owner nothing
# configures resolves to nothing rather than to somebody else's installation,
# which would 404 at write time instead of failing as a readable gate.
#
# A second curl stub, which answers with the installation id embedded in the
# URL it was asked for: every assertion below is about which installation was
# minted against, and a fixed body could not tell two apart.
cat > "$tmp_dir/curl-by-id" <<STUB
#!/usr/bin/env bash
d="$tmp_dir"
printf 'call\n' >> "\$d/curl_calls"
cat >/dev/null 2>&1
url=""
for a in "\$@"; do case "\$a" in https://*) url="\$a" ;; esac; done
case "\$url" in
  */access_tokens)
    id="\${url#*/app/installations/}"; id="\${id%%/access_tokens}"
    printf '{"token":"ghs_for_%s","expires_at":"2099-01-01T00:00:00Z"}\n201' "\$id"
    exit 0 ;;
  */app)
    printf '{"slug":"pullwright-author","id":7710033}\n200'
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$tmp_dir/curl-by-id"

map_env() {  # MAP_JSON [SCALAR]
  PULLWRIGHT_AUTHOR_APP_ID="7710033"
  PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH="$key_path"
  AUTHOR_TOKEN_CURL="$tmp_dir/curl-by-id"
  AUTHOR_TOKEN_CACHE_DIR="$cache_dir"
  if [[ -n "${1:-}" ]]; then
    PULLWRIGHT_AUTHOR_INSTALLATION_IDS="$1"
    export PULLWRIGHT_AUTHOR_INSTALLATION_IDS
  else
    unset PULLWRIGHT_AUTHOR_INSTALLATION_IDS
  fi
  if [[ -n "${2:-}" ]]; then
    PULLWRIGHT_AUTHOR_INSTALLATION_ID="$2"
    export PULLWRIGHT_AUTHOR_INSTALLATION_ID
  else
    unset PULLWRIGHT_AUTHOR_INSTALLATION_ID
  fi
  export PULLWRIGHT_AUTHOR_APP_ID PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH \
    AUTHOR_TOKEN_CURL AUTHOR_TOKEN_CACHE_DIR
}

two_orgs='{"Pullwright": 111111111, "Poetic-Poems": 222222222}'

# --- author_token_installation_for_owner ------------------------------------
map_env "$two_orgs"
assert_eq "map: an owner it names resolves to that owner's installation" \
  "111111111" "$(author_token_installation_for_owner "Pullwright")"
assert_eq "  ... and the other owner to the other installation, never the first" \
  "222222222" "$(author_token_installation_for_owner "Poetic-Poems")"
assert_eq "  ... matched case-insensitively, as GitHub itself treats account names" \
  "222222222" "$(author_token_installation_for_owner "poetic-poems")"
assert_eq "  ... a full slug resolves by its owner half alone" \
  "111111111" "$(author_token_installation_for_owner "Pullwright/agent-ops")"

out="$(author_token_installation_for_owner "third-org")"; rc=$?
assert_eq "map without a scalar default: an owner named by neither resolves to nothing" "" "$out"
assert_eq "  ... and returns non-zero, so a caller can tell it apart from an id" "1" "$rc"

out="$(author_token_installation_for_owner "")"; rc=$?
assert_eq "map without a scalar default: no owner at all resolves to nothing" "" "$out"
assert_eq "  ... and returns non-zero" "1" "$rc"

map_env "$two_orgs" "999999999"
assert_eq "with a scalar default: an owner the map does not name falls back to it" \
  "999999999" "$(author_token_installation_for_owner "third-org")"
assert_eq "  ... and no owner at all resolves to it too — the seam's own 'cannot tell' answer" \
  "999999999" "$(author_token_installation_for_owner "")"
assert_eq "  ... while an owner the map does name still wins over it" \
  "111111111" "$(author_token_installation_for_owner "Pullwright")"

# A malformed map, and a malformed value under a well-formed key, both fall
# through to the scalar rather than shadowing it: a configuration typo must
# never turn a working default into a permanent mint failure for one owner.
map_env "not json at all" "999999999"
assert_eq "a map that is not JSON falls through to the scalar default" \
  "999999999" "$(author_token_installation_for_owner "Pullwright")"
map_env '["Pullwright", 111111111]' "999999999"
assert_eq "a map that is a JSON array, not an object, falls through the same way" \
  "999999999" "$(author_token_installation_for_owner "Pullwright")"
map_env '{"Pullwright": null, "Poetic-Poems": {"id": 5}, "third-org": "abc"}' "999999999"
assert_eq "a null map value falls through to the scalar" \
  "999999999" "$(author_token_installation_for_owner "Pullwright")"
assert_eq "an object map value falls through to the scalar" \
  "999999999" "$(author_token_installation_for_owner "Poetic-Poems")"
assert_eq "a non-numeric map value falls through to the scalar" \
  "999999999" "$(author_token_installation_for_owner "third-org")"

# --- author_token_any_installation_id ---------------------------------------
map_env "$two_orgs" "999999999"
assert_eq "any: the scalar default when there is one" \
  "999999999" "$(author_token_any_installation_id)"
map_env "$two_orgs"
assert_eq "any: the first usable map entry by key when there is no scalar" \
  "222222222" "$(author_token_any_installation_id)"
map_env '{"Pullwright": null, "Poetic-Poems": 222222222}'
assert_eq "any: a malformed entry sorting first does not make the map read as unconfigured" \
  "222222222" "$(author_token_any_installation_id)"
map_env ""
out="$(author_token_any_installation_id)"; rc=$?
assert_eq "any: neither configured is nothing" "" "$out"
assert_eq "  ... and non-zero" "1" "$rc"

# --- author_token_credential_present ---------------------------------------
map_env "$two_orgs"
assert_true "credential_present: a map-only fleet still reads as configured" \
  author_token_credential_present
assert_true "  ... and so does each owner the map names" \
  author_token_credential_present "Pullwright"
if author_token_credential_present "third-org"; then
  assert_eq "  ... but an owner named by neither does not" "false" "true"
else
  assert_eq "  ... but an owner named by neither does not" "false" "false"
fi
map_env "$two_orgs" "999999999"
assert_true "  ... with a scalar default, that same owner does" \
  author_token_credential_present "third-org"

# --- author_token_get: the owner selects the installation -------------------
map_env "$two_orgs"
rm -f "$cache_dir"/* "$tmp_dir/curl_calls"
now=1786708800  # 2026-08-14T12:00:00Z
out="$(author_token_get "$now" "Pullwright")"; rc=$?
assert_eq "get(owner in the map): exit 0" "0" "$rc"
assert_eq "  ... the token minted against *that owner's* installation" "ghs_for_111111111" "$out"
assert_true "  ... cached under that installation id, not the identity alone" \
  test -f "$cache_dir/pullwright-author-token.111111111.json"

out="$(author_token_get "$now" "Poetic-Poems")"; rc=$?
assert_eq "get(the other owner): exit 0" "0" "$rc"
assert_eq "  ... a different token, from the other installation" "ghs_for_222222222" "$out"
assert_true "  ... in its own cache file" \
  test -f "$cache_dir/pullwright-author-token.222222222.json"
assert_eq "  ... and the first owner's cached token is still its own, never re-served" \
  "ghs_for_111111111" "$(author_token_get "$((now + 60))" "Pullwright")"
assert_eq "  ... two mints, one per installation — the cache did not collapse them" \
  "2" "$(call_count)"

out="$(author_token_get "$now" "third-org" 2>/dev/null)"; rc=$?
assert_eq "get(an owner named by neither the map nor a scalar): exit 2, the gate-unreadable code" "2" "$rc"
assert_eq "  ... no token" "" "$out"
assert_eq "  ... and no mint was attempted for somebody else's installation" "2" "$(call_count)"

out="$(author_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "get(no owner, map-only fleet): exit 2 — there is no default to fall back to" "2" "$rc"
assert_eq "  ... no token" "" "$out"

map_env "$two_orgs" "999999999"
rm -f "$cache_dir"/* "$tmp_dir/curl_calls"
assert_eq "get(no owner, with a scalar default): mints against the default installation" \
  "ghs_for_999999999" "$(author_token_get "$now")"
assert_eq "get(an owner the map does not name): the same default, not one of the map's" \
  "ghs_for_999999999" "$(author_token_get "$now" "third-org")"
assert_eq "  ... one mint, since both resolved to the one installation" "1" "$(call_count)"

# --- author_token_identity_login takes the same optional owner --------------
map_env "$two_orgs"
assert_eq "identity login: resolves through an owner the map names" \
  "pullwright-author[bot]" "$(author_token_identity_login "$now" "Poetic-Poems")"
assert_eq "identity login: no owner on a map-only fleet still answers — /app needs no installation" \
  "pullwright-author[bot]" "$(author_token_identity_login "$now")"
out="$(author_token_identity_login "$now" "third-org" 2>/dev/null)"; rc=$?
assert_eq "identity login: an owner named by neither is gate-unreadable" "" "$out"
assert_eq "  ... exit 2" "2" "$rc"

unset PULLWRIGHT_AUTHOR_INSTALLATION_IDS
clear_env

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
