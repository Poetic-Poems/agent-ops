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
# Since the per-owner installation map it also covers `gh_shim_target_owner`,
# which decides *which* installation a given call mints against. Two things
# must hold there and are asserted separately: every invocation shape this
# fleet issues names its owner (an explicit `-R`, a positional slug or URL, a
# `gh api` path, a graphql `owner` field or `repository(owner:)` literal, a
# buffered `gh auth git-credential` request's `path=`, and finally the
# `origin` remote of the work tree the call was made from), and an invocation
# that names *no* owner prints nothing — because a wrong guess resolves to
# some other account's installation, where a token 404s at write time,
# whereas no guess resolves to the operator's own scalar default.
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
  cat >> "$d/stdin.log" 2>/dev/null
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

# === gh_shim_target_owner: which account one `gh` invocation acts against ==
#
# Sourced directly, not run through the shim, because every rule below is a
# pure argv (plus buffered-stdin, plus `origin`) derivation and the point is
# to pin each rule on its own rather than through a mint. What must hold:
# every shape this fleet actually issues names its owner, a *flag's value*
# never does, and an invocation naming none prints nothing at all — which is
# the input `author_token_get`'s scalar default answers, so a wrong guess
# here is worse than no guess.
clear_author_env
unset GH_TOKEN
# shellcheck source=lib/gh-shim.sh
. "$SCRIPT_DIR/lib/gh-shim.sh"

# Every case below must be judged outside a git work tree, or the `origin`
# fallback (rule 5) would answer the ones meant to answer nothing.
no_repo_dir="$tmp_dir/not-a-repo"
mkdir -p "$no_repo_dir"

owner_of() { ( cd "$no_repo_dir" && gh_shim_target_owner "$@" ); }

assert_eq "-R owner/repo names the owner" "acme-org" "$(owner_of -R acme-org/widgets pr view 5)"
assert_eq "--repo=owner/repo names the owner" "acme-org" "$(owner_of --repo=acme-org/widgets pr list)"
assert_eq "-R HOST/OWNER/REPO names the owner, not the host" \
  "acme-org" "$(owner_of -R github.com/acme-org/widgets pr list)"
assert_eq "-R with a full github.com URL names the owner" \
  "acme-org" "$(owner_of -R https://github.com/acme-org/widgets pr list)"
assert_eq "-R outranks a positional that names another owner" \
  "acme-org" "$(owner_of repo view other-org/widgets -R acme-org/widgets)"

# A *bare* slug is a repository only under `gh repo <subcommand>`: see the
# branch-name cases below for why that restriction is the whole of this
# rule's correctness.
assert_eq "a bare OWNER/REPO under gh repo clone names the owner" \
  "acme-org" "$(owner_of repo clone acme-org/widgets)"
assert_eq "a bare OWNER/REPO under gh repo view names the owner" \
  "acme-org" "$(owner_of repo view acme-org/widgets)"
assert_eq "  ... and a HOST/OWNER/REPO under gh repo names the owner, not the host" \
  "acme-org" "$(owner_of repo view github.com/acme-org/widgets)"
assert_eq "  ... while a three-segment path whose first segment is no hostname names nobody" \
  "" "$(owner_of repo view docs/foo/bar.md)"
assert_eq "a pull-request URL names the owner" \
  "acme-org" "$(owner_of pr view https://github.com/acme-org/widgets/pull/5)"
assert_eq "an issue URL names the owner" \
  "acme-org" "$(owner_of issue view https://github.com/acme-org/widgets/issues/9)"
assert_eq "a clone URL with a .git suffix names the owner" \
  "acme-org" "$(owner_of repo clone https://github.com/acme-org/widgets.git)"
assert_eq "a URL on another forge names nobody — this identity is a github.com App" \
  "" "$(owner_of repo view https://gitlab.com/acme-org/widgets)"

assert_eq "gh api repos/OWNER/... names the owner" \
  "acme-org" "$(owner_of api repos/acme-org/widgets/pulls/5)"
assert_eq "  ... with a leading slash too" \
  "acme-org" "$(owner_of api /repos/acme-org/widgets)"
assert_eq "  ... and with a query string" \
  "acme-org" "$(owner_of api "repos/acme-org/widgets/issues?state=open")"
assert_eq "gh api orgs/OWNER names the owner" \
  "acme-org" "$(owner_of api orgs/acme-org/installations)"
assert_eq "gh api users/OWNER names the owner" \
  "acme-org" "$(owner_of api users/acme-org)"
assert_eq "gh api on a path that names no owner names none" \
  "" "$(owner_of api rate_limit)"
assert_eq "  ... including the ones every cycle makes about itself" \
  "" "$(owner_of api user)"

# shellcheck disable=SC2016 # a GraphQL variable reference, not a shell expansion
assert_eq "gh api graphql with an owner field names the owner" \
  "acme-org" "$(owner_of api graphql -f 'query=query($owner:String!){x}' -f owner=acme-org -f name=widgets)"
assert_eq "  ... in the --field spelling too" \
  "acme-org" "$(owner_of api graphql --field owner=acme-org)"
assert_eq "  ... or, with no field, from the query's own repository(owner:) literal" \
  "acme-org" "$(owner_of api graphql -f 'query=query { repository(owner: "acme-org", name: "widgets") { id } }')"
assert_eq "  ... across a line break, as a multi-line query writes it" \
  "acme-org" "$(owner_of api graphql -f 'query=query {
  repository(
    owner: "acme-org"
    name: "widgets"
  ) { id }
}')"
assert_eq "  ... and a graphql call naming neither names nobody" \
  "" "$(owner_of api graphql -f 'query=query { viewer { login } }')"

# The case that makes the flag-value skip load-bearing rather than tidy:
# under `gh repo`, where a bare slug *is* read, a flag's value must not be.
assert_eq "a branch name in gh repo clone --branch is never read as an owner" \
  "acme-org" "$(owner_of repo clone --branch feat/author-installation-map acme-org/widgets)"
assert_eq "  ... nor a directory argument that looks like one" \
  "acme-org" "$(owner_of repo clone --directory work/trees acme-org/widgets)"
assert_eq "an invocation with no arguments at all names nobody" "" "$(owner_of --version)"

# --- The git-credential request's own `path=` line --------------------------
cred_req="$tmp_dir/cred-request"
printf 'protocol=https\nhost=github.com\npath=acme-org/widgets.git\n\n' > "$cred_req"
assert_eq "gh auth git-credential: the buffered request's path= names the owner" \
  "acme-org" "$( cd "$no_repo_dir" && GH_SHIM_STDIN_FILE="$cred_req" gh_shim_target_owner auth git-credential get )"
assert_eq "  ... read by the pure reader on its own" \
  "acme-org" "$(gh_shim_credential_owner "$cred_req")"

printf 'protocol=https\nhost=gitlab.com\npath=acme-org/widgets.git\n\n' > "$cred_req"
assert_eq "  ... a request for another host names nobody" \
  "" "$(gh_shim_credential_owner "$cred_req")"

printf 'protocol=https\nhost=github.com\n\n' > "$cred_req"
assert_eq "  ... a request with no path= (useHttpPath unset) names nobody" \
  "" "$(gh_shim_credential_owner "$cred_req")"
assert_eq "  ... and a missing buffer file names nobody rather than erroring" \
  "" "$(gh_shim_credential_owner "$tmp_dir/no-such-file")"

# --- The `origin` remote of the work tree the call was made from ------------
# The rule that covers the large remainder: `gh pr list`, `gh pr checks`, `gh
# issue comment 12` — every bare call a stage makes inside its cloned
# workspace, which names no repository because `gh` itself resolves them
# exactly this way.
# --- The case rule 4's `gh repo` restriction exists for ---------------------
# On this fleet every branch name carries a slash — `agent/1051`, `feat/x`,
# `fix/x`, `docs/x` — and the Implementer, Reviewer and Enabler stages run
# `gh pr checkout`, `gh pr view` and `gh pr diff` against one, bare, inside a
# cloned workspace, constantly. Reading the branch's first segment as an
# owner would resolve to no installation, fall through to the scalar default,
# and hand a `Poetic-Poems` clone a `Pullwright` token: a 404 at write time,
# which is the exact failure this change exists to prevent. What must hold is
# that such a call resolves to the workspace's *own* owner, by rule 5.
poetic_repo="$tmp_dir/poetic-workspace"
mkdir -p "$poetic_repo"
git -C "$poetic_repo" init -q 2>/dev/null
git -C "$poetic_repo" remote add origin https://github.com/Poetic-Poems/poetic.git
assert_eq "gh pr checkout <branch> resolves to the workspace's own owner, never the branch" \
  "Poetic-Poems" "$( cd "$poetic_repo" && gh_shim_target_owner pr checkout agent/1051 )"
assert_eq "  ... and so does gh pr view <branch>" \
  "Poetic-Poems" "$( cd "$poetic_repo" && gh_shim_target_owner pr view feat/x )"
assert_eq "  ... and gh pr diff <branch>" \
  "Poetic-Poems" "$( cd "$poetic_repo" && gh_shim_target_owner pr diff docs/x )"
assert_eq "  ... while an explicit -R in the same workspace still wins" \
  "Pullwright" "$( cd "$poetic_repo" && gh_shim_target_owner -R Pullwright/agent-ops pr view feat/x )"
assert_eq "  ... and a pull-request URL in the same workspace still wins" \
  "Pullwright" "$( cd "$poetic_repo" && gh_shim_target_owner pr view https://github.com/Pullwright/agent-ops/pull/5 )"
assert_eq "  ... while gh repo clone's own bare slug is still read as a repository" \
  "Poetic-Poems" "$( cd "$poetic_repo" && gh_shim_target_owner repo clone Poetic-Poems/poetic )"
assert_eq "  ... and a three-segment path under gh repo falls through to the remote, never naming its middle segment" \
  "Poetic-Poems" "$( cd "$poetic_repo" && gh_shim_target_owner repo view docs/foo/bar.md )"

origin_repo="$tmp_dir/origin-repo"
mkdir -p "$origin_repo"
git -C "$origin_repo" init -q 2>/dev/null
git -C "$origin_repo" remote add origin https://github.com/acme-org/widgets.git
assert_eq "a bare call inside a work tree falls back to its origin remote" \
  "acme-org" "$( cd "$origin_repo" && gh_shim_target_owner pr list )"
assert_eq "  ... an SSH origin resolves the same owner" \
  "acme-org" "$( cd "$origin_repo" && git remote set-url origin git@github.com:acme-org/widgets.git && gh_shim_target_owner pr checks )"
assert_eq "  ... an origin on another forge names nobody" \
  "" "$( cd "$origin_repo" && git remote set-url origin https://gitlab.com/acme-org/widgets.git && gh_shim_target_owner pr list )"
git -C "$origin_repo" remote set-url origin https://github.com/acme-org/widgets.git
assert_eq "  ... and an explicit -R still outranks the remote" \
  "other-org" "$( cd "$origin_repo" && gh_shim_target_owner -R other-org/widgets pr list )"

# === gh_shim_resolve_token: the owner selects the installation =============
#
# The three outcomes the two-organisation fleet needs, end to end through the
# shim: a mapped owner mints that owner's own token; an owner the map and the
# scalar are both silent about degrades to the PAT rather than presenting a
# token GitHub would 404; and an invocation naming no owner takes the scalar
# default, or the PAT when there is none.
map_curl="$tmp_dir/curl-by-id"
cat > "$map_curl" <<STUB
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
esac
exit 1
STUB
chmod +x "$map_curl"

setup_map_env() {  # [SCALAR]
  export PULLWRIGHT_AUTHOR_APP_ID="7710033"
  export PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH="$key_path"
  export PULLWRIGHT_AUTHOR_INSTALLATION_IDS='{"acme-org": 111111111, "other-org": 222222222}'
  export AUTHOR_TOKEN_CURL="$map_curl"
  export AUTHOR_TOKEN_CACHE_DIR="$cache_dir"
  if [[ -n "${1:-}" ]]; then
    export PULLWRIGHT_AUTHOR_INSTALLATION_ID="$1"
  else
    unset PULLWRIGHT_AUTHOR_INSTALLATION_ID
  fi
}

setup_map_env
rm -f "$cache_dir"/* "$log_dir"/*.log "$tmp_dir/curl_calls"

run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- -R acme-org/widgets pr view 5 >/dev/null
assert_eq "a mapped owner mints that owner's own installation token" \
  "ghs_for_111111111" "$(last_token)"
run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- -R other-org/widgets pr view 5 >/dev/null
assert_eq "the other mapped owner mints the other installation's, never the first's" \
  "ghs_for_222222222" "$(last_token)"
run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- -R third-org/widgets pr view 5 >/dev/null
assert_eq "an owner neither the map nor a scalar names degrades to the PAT, not to another owner's token" \
  "ghp_the_owner_pat" "$(last_token)"
( cd "$no_repo_dir" && run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- api rate_limit >/dev/null )
assert_eq "an invocation naming no owner, with no scalar default, degrades to the PAT" \
  "ghp_the_owner_pat" "$(last_token)"

setup_map_env 999999999
rm -f "$cache_dir"/* "$log_dir"/*.log "$tmp_dir/curl_calls"
( cd "$no_repo_dir" && run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- api rate_limit >/dev/null )
assert_eq "the same call with a scalar default mints against it" \
  "ghs_for_999999999" "$(last_token)"
run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- -R third-org/widgets pr view 5 >/dev/null
assert_eq "  ... and an unmapped owner falls back to it rather than to the PAT" \
  "ghs_for_999999999" "$(last_token)"
run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- -R acme-org/widgets pr view 5 >/dev/null
assert_eq "  ... while a mapped owner still wins over the default" \
  "ghs_for_111111111" "$(last_token)"

# Explicit still wins, per owner: a caller's own GH_TOKEN is never re-minted
# for the repository it happens to name.
run_shim GH_TOKEN=approver_own_token PW_GH_NOW_EPOCH="$now0" \
  -- -R acme-org/widgets pr view 5 >/dev/null
assert_eq "a non-empty GH_TOKEN passes through even when the owner is mapped" \
  "approver_own_token" "$(last_token)"

# --- The credential helper: git's own `path=` selects the installation, and
#     the request reaches the real binary byte for byte --------------------
setup_map_env
rm -f "$cache_dir"/* "$log_dir"/*.log "$tmp_dir/curl_calls" "$log_dir/stdin.log"
cred_out="$(run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- auth git-credential get <<<$'protocol=https\nhost=github.com\npath=acme-org/widgets.git\n')"
assert_eq "git-credential for a mapped owner presents that owner's own token" \
  "yes" "$(grep -qF 'password=ghs_for_111111111' <<<"$cred_out" && echo yes || echo no)"
assert_eq "  ... and the buffered request reaches the real binary unchanged" \
  "$(printf 'protocol=https\nhost=github.com\npath=acme-org/widgets.git\n')" \
  "$(cat "$log_dir/stdin.log")"

rm -f "$log_dir/stdin.log"
cred_out="$(run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- auth git-credential get <<<$'protocol=https\nhost=github.com\npath=other-org/state.git\n')"
assert_eq "git-credential for the other owner presents the other installation's token" \
  "yes" "$(grep -qF 'password=ghs_for_222222222' <<<"$cred_out" && echo yes || echo no)"

cred_out="$(run_shim GH_TOKEN= PW_GH_DEGRADE_TOKEN=ghp_the_owner_pat PW_GH_NOW_EPOCH="$now0" \
  -- auth git-credential get <<<$'protocol=https\nhost=github.com\npath=third-org/thing.git\n')"
assert_eq "git-credential for an owner named by neither degrades to the PAT" \
  "yes" "$(grep -qF 'password=ghp_the_owner_pat' <<<"$cred_out" && echo yes || echo no)"

unset PULLWRIGHT_AUTHOR_INSTALLATION_IDS PULLWRIGHT_AUTHOR_INSTALLATION_ID
clear_author_env

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
