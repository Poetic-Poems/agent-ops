#!/usr/bin/env bash
#
# test/gh-shim-auth.test.sh — regression test for lib/gh-shim.sh's
# `gh_shim_resolve_token`: the forge authoring App's on-demand credential
# seam (D18 decision 1 as amended, agent-ops#1021, TD-PPagop-26082833).
#
# What must hold, always: a cycle that outlives a minted installation
# token's ~1 h lifetime must present a *fresh* one to its next `git`/`gh`
# authoring call, never the stale one that was valid when the cycle started.
# `test/gh-shim.test.sh` already covers this file's transport mechanics
# (classification, caching, last-known-good) in full; this file covers only
# `gh_shim_resolve_token` and the "explicit wins; empty resolves" contract it
# implements, end to end against a stub "real gh" binary — never a live App
# or network call.
#
# The stub "real gh" answers two shapes, both logging the `GH_TOKEN` it saw:
#
#   - `auth git-credential` — stands in for the credential helper `git push`
#     invokes (`!gh auth git-credential`, deploy/docker/entrypoint.sh),
#     answering the git-credential protocol with whatever token it was
#     given, so this file can assert on the very credential a `git push`
#     would receive.
#   - any other argv (`pr view 5`) — stands in for an ordinary `gh` call.
#
# `curl` is stubbed (AUTHOR_TOKEN_CURL, the same shape
# test/author-token.test.sh uses); real `openssl` signs a throwaway RSA key,
# so the JWT-building path is exercised for real. Stub ordering matters here
# (lib/gh-shim.sh's own header): the stub is never placed ahead of the shim
# on `PATH` — it is reached through AUTHOR_TOKEN_CURL, one layer below the
# shim's own dispatch, so the shim's real code path runs unmodified.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/gh-shim-auth.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

tmp_dir="$(mktemp -d)"
# The mint cache needs a directory the wrapper's mount-type check accepts —
# the same tmpfs the runtime default (/dev/shm) points at.
cache_dir="$(mktemp -d /dev/shm/gh-shim-auth-test.XXXXXX)"
trap 'rm -rf "$tmp_dir" "$cache_dir"' EXIT

state_dir="$tmp_dir/state"
log_dir="$tmp_dir/ghlog"
mkdir -p "$state_dir" "$log_dir"

# --- A throwaway App key for this run ---------------------------------------
key_path="$tmp_dir/app-key.pem"
openssl genrsa -out "$key_path" 2048 >/dev/null 2>&1
chmod 600 "$key_path"

# --- The stub curl (test/author-token.test.sh's own shape) ------------------
stub_curl() {  # STATUS BODY
  local status="${1:-201}" body="$2"
  printf '%s' "$status" > "$tmp_dir/curl_status"
  printf '%s' "$body" > "$tmp_dir/curl_body"
  rm -f "$tmp_dir/curl_fail"
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
curl_call_count() {
  [[ -f "$tmp_dir/curl_calls" ]] && wc -l < "$tmp_dir/curl_calls" || printf '0\n'
}

# --- The stub "real gh": logs the token it saw, answers git-credential -----
stub_bin="$tmp_dir/stub"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
d="${STUB_LOG_DIR:?}"
{ printf '%s\x1f' "$@"; printf '\n'; } >> "$d/calls.log"
printf '%s\n' "${GH_TOKEN:-}" >> "$d/tokens.log"
if [[ "${1:-}" == "auth" && "${2:-}" == "git-credential" ]]; then
  cat >/dev/null 2>&1
  printf 'protocol=https\nhost=github.com\nusername=x-access-token\npassword=%s\n' "${GH_TOKEN:-}"
  exit 0
fi
printf '{}'
exit 0
STUB
chmod +x "$stub_bin/gh"

last_token() { tail -1 "$log_dir/tokens.log" 2>/dev/null; }

setup_author_env() {
  export PULLWRIGHT_AUTHOR_APP_ID="7710033"
  export PULLWRIGHT_AUTHOR_INSTALLATION_ID="882110044"
  export PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH="$key_path"
  export AUTHOR_TOKEN_CURL="$tmp_dir/curl"
  export AUTHOR_TOKEN_CACHE_DIR="$cache_dir"
}
clear_author_env() {
  unset PULLWRIGHT_AUTHOR_APP_ID PULLWRIGHT_AUTHOR_INSTALLATION_ID \
    PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH AUTHOR_TOKEN_CURL AUTHOR_TOKEN_CACHE_DIR
}

# run_shim [ENV_ASSIGNS...] -- ARGS...
# Runs scripts/gh-shim.sh with the given extra environment assignments (each
# "NAME=value") ahead of PW_GH_REAL_BIN/PW_GH_STATE_DIR/STUB_LOG_DIR, which
# every call needs, so a caller only ever names what varies (GH_TOKEN,
# PW_GH_DEGRADE_TOKEN, PW_GH_NOW_EPOCH).
run_shim() {
  local -a env_assigns=()
  while [[ "$1" != "--" ]]; do env_assigns+=("$1"); shift; done
  shift
  env "${env_assigns[@]}" \
    PW_GH_REAL_BIN="$stub_bin/gh" PW_GH_STATE_DIR="$state_dir" STUB_LOG_DIR="$log_dir" \
    "$SCRIPT_DIR/scripts/gh-shim.sh" "$@"
}

now0=1786708800  # 2026-08-14T12:00:00Z
now_past_expiry=$(( now0 + 3600 + 1 ))

# === App configured, GH_TOKEN empty: mints on demand, reuses within the
#     token's lifetime, mints fresh again once it is expired ================

setup_author_env
rm -f "$cache_dir"/* "$log_dir"/*.log "$tmp_dir/curl_calls"
stub_curl 201 '{"token":"ghs_tokenA","expires_at":"2026-08-14T13:00:00Z"}'

cred_out="$(run_shim GH_TOKEN= PW_GH_NOW_EPOCH="$now0" -- auth git-credential <<<$'protocol=https\nhost=github.com\n')"
assert_eq "git-credential (empty GH_TOKEN): mints and presents the fresh token" \
  "yes" "$(grep -qF 'password=ghs_tokenA' <<<"$cred_out" && echo yes || echo no)"

run_shim GH_TOKEN= PW_GH_NOW_EPOCH="$now0" -- pr view 5 >/dev/null
assert_eq "the next gh call (empty GH_TOKEN): presents the same fresh token" \
  "ghs_tokenA" "$(last_token)"
assert_eq "…reused from cache, no second mint" "1" "$(curl_call_count)"

# Advance the clock past the minted token's own expires_at: the same two call
# shapes must each present a *different*, freshly-minted token.
stub_curl 201 '{"token":"ghs_tokenB","expires_at":"2026-08-14T15:00:00Z"}'
cred_out2="$(run_shim GH_TOKEN= PW_GH_NOW_EPOCH="$now_past_expiry" -- auth git-credential <<<$'protocol=https\nhost=github.com\n')"
assert_eq "git-credential, clock advanced past expiry: presents a fresh token, not the stale one" \
  "yes" "$(grep -qF 'password=ghs_tokenB' <<<"$cred_out2" && echo yes || echo no)"

run_shim GH_TOKEN= PW_GH_NOW_EPOCH="$now_past_expiry" -- pr view 5 >/dev/null
assert_eq "the next gh call, clock advanced past expiry: presents the same fresh token" \
  "ghs_tokenB" "$(last_token)"
assert_eq "…a second mint actually happened" "2" "$(curl_call_count)"

# === Explicit wins: a non-empty GH_TOKEN is never touched, exactly the
#     shape lib/approver.sh's own GH_TOKEN="$(approver_token_get)" gh … uses
#     — the seam must never re-identify the Approver's calls as the author ==

rm -f "$cache_dir"/* "$log_dir"/*.log "$tmp_dir/curl_calls"
stub_curl 201 '{"token":"SHOULD_NEVER_BE_MINTED","expires_at":"2026-08-14T13:00:00Z"}'
run_shim GH_TOKEN=approver_own_token PW_GH_NOW_EPOCH="$now0" -- pr view 5 >/dev/null
assert_eq "a non-empty GH_TOKEN passes through verbatim" \
  "approver_own_token" "$(last_token)"
assert_eq "…and mints nothing" "0" "$(curl_call_count)"

# === No forge authoring App configured: the ambient GH_TOKEN authenticates
#     everything, exactly as before this item =================================

clear_author_env
rm -f "$log_dir"/*.log
run_shim GH_TOKEN=ghp_the_owner_pat -- pr view 5 >/dev/null
assert_eq "no App configured: the ambient GH_TOKEN authenticates the call" \
  "ghp_the_owner_pat" "$(last_token)"

# === App configured but a mint fails: falls back to PW_GH_DEGRADE_TOKEN
#     rather than reaching the real binary with no credential at all =========

setup_author_env
rm -f "$cache_dir"/* "$log_dir"/*.log "$tmp_dir/curl_calls"
stub_curl 401 '{"message":"Bad credentials"}'
run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_degrade_pat PW_GH_NOW_EPOCH="$now0" -- pr view 5 >/dev/null
assert_eq "a mint failure degrades to PW_GH_DEGRADE_TOKEN" \
  "ghp_degrade_pat" "$(last_token)"

# === Nothing configured at all: GH_TOKEN stays empty — the pre-existing
#     "no credential" case, unchanged and never a crash ======================

clear_author_env
rm -f "$log_dir"/*.log
run_shim GH_TOKEN= -- pr view 5 >/dev/null
assert_eq "nothing configured: the call still reaches the real binary, with an empty token" \
  "" "$(last_token)"

clear_author_env
unset GH_TOKEN

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
