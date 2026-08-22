#!/usr/bin/env bash
#
# test/approver-token.test.sh — regression test for lib/approver-token.sh
# (D18 WI-4, agent-ops#407).
#
# What must hold, always: a caller never mistakes "no credential" for "a
# token", never mistakes a mint failure for one either, never sees a PAT
# fallback anywhere in this file, and never sees a token land anywhere but
# stdout and (best-effort) a mode-600 tmpfs cache file this test substitutes
# with a throwaway /dev/shm directory — genuinely tmpfs, because the wrapper
# now verifies the mount type before writing anything.
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
# The cache tests need a directory the wrapper's mount-type check accepts, so
# they live under /dev/shm — the same tmpfs the runtime default points at.
# Every platform this suite runs on (both CI legs, the node image, WSL) is
# Linux, where /dev/shm is guaranteed.
cache_dir="$(mktemp -d /dev/shm/approver-token-test.XXXXXX)"
trap 'rm -rf "$tmp_dir" "$cache_dir"' EXIT

# The cache filename the wrapper derives for setup_env's installation id
# below — keyed by that id, so one installation's token is never served for
# another's.
cache_file_name="pullwright-approver-token.153689775.json"

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

# --- The stub curl -----------------------------------------------------------
# $tmp_dir/curl_status   HTTP status to answer with (default 201)
# $tmp_dir/curl_body     response body (default a fresh token + expires_at)
# $tmp_dir/curl_fail     present -> curl itself fails (network/timeout)
# $tmp_dir/curl_calls    appended to on every invocation, so tests can assert
#                        whether a mint actually happened
# $tmp_dir/curl_argv     every invocation's argv, one word per line, so tests
#                        can assert what never rides in /proc/<pid>/cmdline
# $tmp_dir/curl_stdin    everything delivered on stdin (--config -), so tests
#                        can assert the Authorization header travelled there
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
assert_true "  ... the cache file exists" test -f "$cache_dir/$cache_file_name"
perm="$(stat -c '%a' "$cache_dir/$cache_file_name" 2>/dev/null)"
assert_eq "  ... the cache file is mode 600" "600" "$perm"
assert_eq "  ... the cache never carries the JWT, only the token" "ghs_first000" \
  "$(jq -r '.token' "$cache_dir/$cache_file_name")"

# --- The App JWT never rides in argv ----------------------------------------
# An argv entry is world-readable in /proc/<pid>/cmdline for the duration of
# the call, so the Authorization header reaches curl through `--config -` on
# stdin instead — the same move #433 and #437 made for related payloads.
assert_eq "  ... the Authorization header is absent from curl's argv" "" \
  "$(grep -i 'authorization' "$tmp_dir/curl_argv" || true)"
assert_true "  ... and arrives on stdin via --config instead" \
  grep -q '^header = "Authorization: Bearer ' "$tmp_dir/curl_stdin"

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
  "$(jq -r '.token' "$cache_dir/$cache_file_name")"

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
assert_true "  ... nothing was cached" bash -c "[[ ! -s '$cache_dir/$cache_file_name' ]]"

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

# --- A cache file this user does not own is never served as a credential ----
# The default cache directory is /dev/shm, mode 1777, and this file's name in
# it is fixed — so any local user can create it before we do. Such a file must
# be ignored and a fresh token minted, never handed back as the Approver's.
# Ownership cannot be faked here without root, so the symlink half of the same
# check stands in: a symlink is never something this file wrote.
setup_env
rm -f "$cache_dir"/*
printf '{"token":"ghs_PLANTED","expires_at":"2099-01-01T00:00:00Z","exp_epoch":4070908800}' \
  > "$tmp_dir/planted.json"
ln -s "$tmp_dir/planted.json" "$cache_dir/$cache_file_name"
stub_curl 201 '{"token":"ghs_minted999","expires_at":"2026-08-14T20:00:00Z"}'
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "planted cache file: still succeeds" "0" "$rc"
assert_eq "  ... the planted token is never returned" "ghs_minted999" "$out"
assert_eq "  ... a real mint happened instead of trusting the cache" "1" "$(call_count)"
rm -f "$cache_dir/$cache_file_name" "$tmp_dir/planted.json"

# --- Caching is best-effort: an unusable cache directory never blocks a mint
setup_env
APPROVER_TOKEN_CACHE_DIR="$tmp_dir/no-such-cache-dir"
export APPROVER_TOKEN_CACHE_DIR
stub_curl 201 '{"token":"ghs_nocachedir","expires_at":"2026-08-14T20:00:00Z"}'
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "cache directory absent: still succeeds" "0" "$rc"
assert_eq "  ... the minted token on stdout" "ghs_nocachedir" "$out"

# --- The cache is keyed by installation id ----------------------------------
# A token minted for one installation must never be served for another: with
# a single fixed filename, changing PULLWRIGHT_APPROVER_INSTALLATION_ID (or
# running two installations from one node) would hand the previous
# installation's token out for up to an hour, in a failure shape that reads
# as a GitHub problem rather than a stale cache.
setup_env
rm -f "$cache_dir"/*
stub_curl 201 '{"token":"ghs_installA","expires_at":"2026-08-14T14:00:00Z"}'
out="$(approver_token_get "$now")"; rc=$?
assert_eq "installation A mints: exit 0" "0" "$rc"
PULLWRIGHT_APPROVER_INSTALLATION_ID="999000111"
export PULLWRIGHT_APPROVER_INSTALLATION_ID
stub_curl 201 '{"token":"ghs_installB","expires_at":"2026-08-14T14:00:00Z"}'
out="$(approver_token_get "$((now + 60))")"; rc=$?
assert_eq "a different installation id within A's lifetime: exit 0" "0" "$rc"
assert_eq "  ... never serves installation A's cached token" "ghs_installB" "$out"
assert_eq "  ... a real mint happened for the new installation" "1" "$(call_count)"
assert_true "  ... each installation holds its own cache file" \
  test -f "$cache_dir/pullwright-approver-token.999000111.json"
out="$(PULLWRIGHT_APPROVER_INSTALLATION_ID=153689775 approver_token_get "$((now + 120))")"
assert_eq "  ... switching back serves A's still-valid cache" "ghs_installA" "$out"
assert_eq "  ... without a further mint" "1" "$(call_count)"

# --- A disk-backed cache directory gets no cache at all ---------------------
# APPROVER_TOKEN_CACHE_DIR is an ordinary environment variable; #407's
# guarantee — tokens live only in memory/tmpfs, never persistent storage —
# must not hinge on nobody ever pointing it at a disk. The wrapper checks the
# mount type and skips caching entirely rather than writing a token to disk.
disk_dir="$tmp_dir/disk-cache"
mkdir -p "$disk_dir"
if [[ "$(stat -f -c %T "$disk_dir" 2>/dev/null)" == "tmpfs" ]]; then
  # This box mounts its temp directory on tmpfs, so it cannot host the
  # negative case; every other environment this suite runs in still does.
  printf 'ok   - %s\n' "disk-backed cache dir refused (skipped: the temp dir is itself tmpfs here)"
else
  setup_env
  APPROVER_TOKEN_CACHE_DIR="$disk_dir"
  export APPROVER_TOKEN_CACHE_DIR
  stub_curl 201 '{"token":"ghs_diskdir","expires_at":"2026-08-14T14:00:00Z"}'
  out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
  assert_eq "disk-backed cache dir: still succeeds" "0" "$rc"
  assert_eq "  ... the minted token on stdout" "ghs_diskdir" "$out"
  assert_eq "  ... but nothing at all was written to the disk-backed directory" "" \
    "$(ls -A "$disk_dir")"
  out="$(approver_token_get "$((now + 60))" 2>/dev/null)"
  assert_eq "  ... and a second call mints fresh rather than caching" "2" "$(call_count)"
fi

# --- An unparsable expires_at is never guessed at: token returned, not cached
# GitHub issued the token, so refusing it over a timestamp format would turn
# a cosmetic API change into an outage — but a cache entry needs an expiry
# the wrapper can stand behind, so nothing is cached and every call mints
# fresh until the shape parses again.
setup_env
rm -f "$cache_dir"/*
stub_curl 201 '{"token":"ghs_oddexpiry","expires_at":"not-a-timestamp"}'
out="$(approver_token_get "$now" 2>/dev/null)"; rc=$?
assert_eq "unparsable expires_at: still exit 0" "0" "$rc"
assert_eq "  ... the minted token on stdout" "ghs_oddexpiry" "$out"
assert_eq "  ... nothing was cached" "" "$(ls -A "$cache_dir")"

# --- approver_token_identity_login (D18 WI-5) ---------------------------------
# The one call in this file that authenticates as the App itself rather than
# an installation — lib/approver.sh's refuse-streak counting needs the App's
# own login to tell its past reviews apart from anyone else's.
setup_env
stub_curl 200 '{"slug":"pullwright-approver","id":4593249}'
out="$(approver_token_identity_login "$now")"; rc=$?
assert_eq "identity login: exit 0" "0" "$rc"
assert_eq "  ... the [bot]-suffixed login form reviews actually carry" \
  "pullwright-approver[bot]" "$out"
assert_eq "  ... the Authorization header is absent from curl's argv here too" "" \
  "$(grep -i 'authorization' "$tmp_dir/curl_argv" || true)"

stub_curl 404 '{"message":"Not Found"}'
out="$(approver_token_identity_login "$now")"; rc=$?
assert_eq "identity login: a non-200 is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

stub_curl 200 '{"id":4593249}'
out="$(approver_token_identity_login "$now")"; rc=$?
assert_eq "identity login: a body with no slug is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

setup_env
touch "$tmp_dir/curl_fail"
out="$(approver_token_identity_login "$now")"; rc=$?
assert_eq "identity login: an unreachable API is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"
rm -f "$tmp_dir/curl_fail"

clear_env
out="$(approver_token_identity_login "$now")"; rc=$?
assert_eq "identity login: no credential configured is gate-unreadable" "" "$out"
assert_eq "  ... exit 2, the same code approver_token_get uses for it" "2" "$rc"

# --- approver_token_installation_permissions (D18 Stage 3, agent-ops#575) ----
# The one call in this file that reads what the installation is actually
# entitled to, rather than what it can mint or who it is — scripts/doctor.sh's
# autonomy-readiness verdict is the sole caller.
setup_env
stub_curl 200 '{"id":153689775,"permissions":{"contents":"write","metadata":"read","pull_requests":"write"}}'
out="$(approver_token_installation_permissions "$now")"; rc=$?
assert_eq "installation permissions: exit 0" "0" "$rc"
assert_eq "  ... prints exactly the live .permissions object" \
  '{"contents":"write","metadata":"read","pull_requests":"write"}' "$out"
assert_eq "  ... the Authorization header is absent from curl's argv" "" \
  "$(grep -i 'authorization' "$tmp_dir/curl_argv" || true)"

stub_curl 404 '{"message":"Not Found"}'
out="$(approver_token_installation_permissions "$now")"; rc=$?
assert_eq "installation permissions: a non-200 is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

stub_curl 200 '{"id":153689775}'
out="$(approver_token_installation_permissions "$now")"; rc=$?
assert_eq "installation permissions: a body with no permissions is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

stub_curl 200 '{"id":153689775,"permissions":{}}'
out="$(approver_token_installation_permissions "$now")"; rc=$?
assert_eq "installation permissions: an empty permissions object is a failure too" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

setup_env
touch "$tmp_dir/curl_fail"
out="$(approver_token_installation_permissions "$now")"; rc=$?
assert_eq "installation permissions: an unreachable API is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"
rm -f "$tmp_dir/curl_fail"

clear_env
out="$(approver_token_installation_permissions "$now")"; rc=$?
assert_eq "installation permissions: no credential configured is gate-unreadable" "" "$out"
assert_eq "  ... exit 2, the same code approver_token_get uses for it" "2" "$rc"

clear_env

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
