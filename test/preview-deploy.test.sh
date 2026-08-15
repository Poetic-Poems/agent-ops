#!/usr/bin/env bash
#
# test/preview-deploy.test.sh — the preview-deployment check (scripts/preview-deploy.sh),
# against a stubbed `gh` and `curl` on PATH: no GitHub and no Vercel exist where
# this suite runs, and the script's job is verdicts, not either API.
#
# The property the whole script exists for is the third one below. A protected
# preview answers 302 → vercel.com/login, and a check that follows redirects and
# reads the status code sees 200: a login page certified as a healthy
# deployment. It must read as "could not check", and it must say which secret is
# missing — a preview nobody can reach is a fact about the node, not the branch.
#
# The rest:
#   - a built deployment whose page answers is a pass, and the bypass secret
#     travels in the x-vercel-protection-bypass header (the stub answers the
#     wall to anyone who does not send the right one);
#   - a bypass secret that is set and rejected is a different message from one
#     that was never set — the two have different fixes;
#   - a failed build is exit 1 and names the inspector; with VERCEL_TOKEN it
#     also carries the tail of the build log;
#   - a deployment that built and then serves an error is exit 1, distinct from
#     a build failure;
#   - an ordinary application redirect is followed rather than mistaken for the
#     wall;
#   - no Preview deployment, and a deployment still building, are both "could
#     not check" (exit 2) — never a pass;
#   - --wait polls until the deployment reaches a terminal state.
#
# Run directly: ./test/preview-deploy.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/preview-deploy.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"

# --- The stubbed gh -----------------------------------------------------------
# Two endpoints, each driven by a STUB_* variable. STUB_DEPLOYMENTS_2, when
# set, is what the *second* and later calls return — which is how the --wait
# case below has a deployment appear while the script is polling.
#
# `pr view` and `pr list` are what resolves the pull request when no --sha is
# given (the "real gh CLI" section below tests directly, this is what the rest
# of the suite relies on to reach the same code without a network call). Its
# `pr view` case mirrors one real rule rather than accepting anything: gh
# refuses to combine --repo with no PR number, URL or branch. Getting that rule
# wrong here is exactly how the previous version of this stub missed the bug
# TD-PPagop-26080301 files — it accepted the shape the real binary refuses.
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  api)
    case "$2" in
      *"/statuses"*) printf '%s\n' "${STUB_STATUSES:-[]}" ;;
      *"/deployments"*)
        n=0
        [[ -f "$STUB_CALLS" ]] && n="$(cat "$STUB_CALLS")"
        printf '%s\n' "$(( n + 1 ))" > "$STUB_CALLS"
        if (( n > 0 )) && [[ -n "${STUB_DEPLOYMENTS_2:-}" ]]; then
          printf '%s\n' "$STUB_DEPLOYMENTS_2"
        else
          printf '%s\n' "${STUB_DEPLOYMENTS:-[]}"
        fi ;;
      *) exit 1 ;;
    esac ;;
  repo)
    case "$2" in
      view) printf '%s\n' "${STUB_REPO_SLUG:-}" ;;
      *) exit 1 ;;
    esac ;;
  pr)
    case "$2" in
      view)
        shift 2
        has_repo=0
        ident=""
        while (( $# > 0 )); do
          case "$1" in
            --repo) has_repo=1; shift 2 ;;
            --json|--jq) shift 2 ;;
            -*) shift ;;
            *) ident="$1"; shift ;;
          esac
        done
        if (( has_repo )) && [[ -z "$ident" ]]; then
          echo "argument required when using the --repo flag" >&2
          exit 1
        fi
        printf '%s\n' "${STUB_PR_ANSWER:-}" ;;
      list) printf '%s\n' "${STUB_PR_LIST_NUMBER:-}" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub_bin/gh"

# git is stubbed too, only for `branch --show-current` — the one call the
# --repo-with-no---pr path below makes. Real git would work in a developer's
# checkout, but this suite also runs inside the node image, which
# .dockerignore excludes .git from entirely, so nothing here can depend on
# actually being inside a git repository.
cat > "$stub_bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "branch" && "$2" == "--show-current" ]]; then
  printf '%s\n' "${STUB_BRANCH-td/TD-PPagop-26080301}"
else
  exit 1
fi
STUB
chmod +x "$stub_bin/git"

# --- The stubbed curl ---------------------------------------------------------
# It plays two different servers. api.vercel.com returns the build-log events
# on stdout; everything else is the preview host, which answers the SSO wall to
# any request that does not carry the project's bypass secret — exactly as the
# real one does, so the header is genuinely under test rather than assumed.
cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; dump=""; url=""; bypass=""
while (( $# > 0 )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) dump="$2"; shift 2 ;;
    -H) [[ "$2" == "x-vercel-protection-bypass: "* ]] && bypass="${2#x-vercel-protection-bypass: }"
        shift 2 ;;
    -w|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done

if [[ "$url" == *api.vercel.com* ]]; then
  printf '%s\n' "${STUB_EVENTS:-[]}"
  exit 0
fi

# The wall, unless the right secret was presented.
if [[ "$bypass" != "${STUB_GOOD_SECRET:-}" ]]; then
  [[ -n "$dump" ]] && printf 'HTTP/2 302\r\nlocation: https://vercel.com/login?next=%%2Fsso-api\r\n\r\n' > "$dump"
  [[ -n "$out" ]] && printf 'Redirecting...' > "$out"
  printf '302'
  exit 0
fi

n=0
[[ -f "$STUB_HTTP_CALLS" ]] && n="$(cat "$STUB_HTTP_CALLS")"
printf '%s\n' "$(( n + 1 ))" > "$STUB_HTTP_CALLS"
code="${STUB_HTTP_CODE:-200}"
location=""
if (( n == 0 )) && [[ -n "${STUB_FIRST_CODE:-}" ]]; then
  code="$STUB_FIRST_CODE"
  location="${STUB_FIRST_LOCATION:-}"
fi
{ printf 'HTTP/2 %s\r\n' "$code"
  [[ -n "$location" ]] && printf 'location: %s\r\n' "$location"
  printf '\r\n'; } > "${dump:-/dev/null}"
if [[ -n "$out" ]]; then
  if [[ "${STUB_BODY_BINARY:-}" == "1" ]]; then
    printf '\x00\x01\x02binarydata' > "$out"
  else
    printf '%s' "${STUB_BODY:-the application}" > "$out"
  fi
fi
printf '%s' "$code"
STUB
chmod +x "$stub_bin/curl"

# Instant, so a --wait test costs nothing.
printf '#!/usr/bin/env bash\nexit 0\n' > "$stub_bin/sleep"
chmod +x "$stub_bin/sleep"

# --- Fixtures -----------------------------------------------------------------
preview_url='https://poetic-fiddle-abc123-team.vercel.app'
inspector='https://vercel.com/team/poetic-fiddle/dep_abc123'
secret='bypass-secret-0123456789'

deployment_preview='[{"id":991,"environment":"Preview"}]'
deployment_production_only='[{"id":992,"environment":"Production"}]'

status_success="[{\"state\":\"success\",\"environment_url\":\"$preview_url\",\"log_url\":\"$inspector\"}]"
status_failure="[{\"state\":\"failure\",\"environment_url\":\"$preview_url\",\"log_url\":\"$inspector\"}]"
status_building="[{\"state\":\"in_progress\",\"environment_url\":null,\"log_url\":\"$inspector\"}]"

rc=0
out=""
run_check() {  # run_check [VAR=value…] [-- extra args to the script]
  local env_pairs=() script_args=()
  while (( $# > 0 )); do
    if [[ "$1" == "--" ]]; then shift; script_args=( "$@" ); break; fi
    env_pairs+=( "$1" ); shift
  done
  rm -f "$tmp_dir/calls" "$tmp_dir/http-calls"
  out="$(env PATH="$stub_bin:$PATH" \
    STUB_CALLS="$tmp_dir/calls" STUB_HTTP_CALLS="$tmp_dir/http-calls" \
    STUB_DEPLOYMENTS="$deployment_preview" STUB_STATUSES="$status_success" \
    STUB_GOOD_SECRET="$secret" \
    VERCEL_AUTOMATION_BYPASS_SECRET="$secret" \
    VERCEL_TOKEN="" \
    "${env_pairs[@]}" \
    "$CHECK" --repo Poetic-Poems/poetic-fiddle --sha deadbeefcafe \
    "${script_args[@]}" 2>&1)"
  rc=$?
}

# Like run_check, but without the hardcoded --repo/--sha — for the pull
# request resolution scenarios below, which are the point of this file's
# existence: they exercise the code that decides *how* to ask gh, not just
# what to do once a SHA is already in hand.
run_check_raw() {  # run_check_raw [VAR=value…] -- <script args>
  local env_pairs=() script_args=()
  while (( $# > 0 )); do
    if [[ "$1" == "--" ]]; then shift; script_args=( "$@" ); break; fi
    env_pairs+=( "$1" ); shift
  done
  rm -f "$tmp_dir/calls" "$tmp_dir/http-calls"
  out="$(env PATH="$stub_bin:$PATH" \
    STUB_CALLS="$tmp_dir/calls" STUB_HTTP_CALLS="$tmp_dir/http-calls" \
    STUB_DEPLOYMENTS="$deployment_preview" STUB_STATUSES="$status_success" \
    STUB_GOOD_SECRET="$secret" \
    VERCEL_AUTOMATION_BYPASS_SECRET="$secret" \
    VERCEL_TOKEN="" \
    "${env_pairs[@]}" \
    "$CHECK" "${script_args[@]}" 2>&1)"
  rc=$?
}

# --- A preview that built and answers -----------------------------------------

run_check
assert_eq "a built, reachable preview passes" "0" "$rc"
assert_contains "and says so" "deployed and serving" "$out"

# --- The wall, which is what this script is for -------------------------------

run_check VERCEL_AUTOMATION_BYPASS_SECRET=
assert_eq "a protected preview is 'could not check', never a pass" "2" "$rc"
assert_contains "naming the secret that would fix it" \
  "VERCEL_AUTOMATION_BYPASS_SECRET is not set" "$out"
assert_contains "and absolving the branch" "says nothing about the branch" "$out"
assert_lacks "without claiming the preview is serving" "deployed and serving" "$out"

run_check VERCEL_AUTOMATION_BYPASS_SECRET=a-stale-secret
assert_eq "a rejected bypass secret is also 'could not check'" "2" "$rc"
assert_contains "and is a different diagnosis from an unset one" "regenerated" "$out"

# --- A build that failed ------------------------------------------------------

run_check STUB_STATUSES="$status_failure"
assert_eq "a failed build is a failure" "1" "$rc"
assert_contains "naming the inspector" "$inspector" "$out"
assert_contains "and saying how to get the log here" "set VERCEL_TOKEN" "$out"

run_check STUB_STATUSES="$status_failure" VERCEL_TOKEN=vercel-token \
  STUB_EVENTS='[{"text":"Error: Cannot find module @poetic/core"}]'
assert_eq "a failed build with a token is still a failure" "1" "$rc"
assert_contains "carrying the build log" "Cannot find module" "$out"

# --- Built, but the application is broken -------------------------------------

run_check STUB_HTTP_CODE=500
assert_eq "a preview that built and then 500s is a failure" "1" "$rc"
assert_contains "distinguished from a build failure" "the application failing" "$out"

# --- An ordinary redirect is not the wall -------------------------------------

run_check STUB_FIRST_CODE=307 STUB_FIRST_LOCATION="$preview_url/poems"
assert_eq "an application's own redirect is followed, not mistaken for the wall" "0" "$rc"
assert_contains "and shown" "/poems" "$out"

# --- --fetch: route evidence, without leaking the secret -----------------------
# This is the tier D19's roadmap entry and issue #460 both call "served": once
# the readiness check above has confirmed the preview answers past the wall,
# --fetch prints status, headers and body for whatever routes the diff
# touched — proof that a preview a human would otherwise have to click through
# in a browser (poetic-fiddle#319's CSP defect) is readable from here instead.

run_check -- --fetch /poems
assert_eq "a preview with --fetch still passes the readiness check" "0" "$rc"
assert_contains "and prints route evidence" "route evidence:" "$out"
assert_contains "naming the fetched route" "$preview_url/poems" "$out"
assert_contains "the response status" "status: 200" "$out"
assert_contains "the response headers" "HTTP/2 200" "$out"
assert_contains "the response body" "the application" "$out"
assert_lacks "the bypass secret never appears in the output" "$secret" "$out"

run_check STUB_BODY_BINARY=1 -- --fetch /
assert_eq "a binary body still passes" "0" "$rc"
assert_contains "and is noted as binary rather than dumped" "binary" "$out"
assert_lacks "without the raw bytes" $'\x01\x02' "$out"

run_check STUB_BODY="$(printf 'x%.0s' $(seq 1 9000))" -- --fetch /
assert_eq "an oversized body still passes" "0" "$rc"
assert_contains "and is noted as truncated" "truncated" "$out"

# --- Nothing to check is never a pass -----------------------------------------

run_check STUB_DEPLOYMENTS='[]'
assert_eq "no deployment at all is exit 2" "2" "$rc"
assert_contains "saying what that means" "not deployed from Vercel" "$out"

run_check STUB_DEPLOYMENTS="$deployment_production_only"
assert_eq "a Production-only SHA has no preview to check" "2" "$rc"
assert_contains "naming the environments GitHub does have" "Production" "$out"

run_check STUB_STATUSES="$status_building"
assert_eq "a deployment still building is exit 2" "2" "$rc"
assert_contains "suggesting the wait" "longer --wait" "$out"

# --- Waiting ------------------------------------------------------------------
# The first poll finds no deployment, the second finds the built one: the loop
# must re-ask rather than answer from its first look.
run_check STUB_DEPLOYMENTS='[]' STUB_DEPLOYMENTS_2="$deployment_preview" \
  -- --wait 60
assert_eq "--wait polls until the deployment appears" "0" "$rc"
assert_contains "having said it was waiting" "waiting" "$out"

# --- Resolving the pull request without --sha (TD-PPagop-26080301) ------------
# The default invocation — no arguments at all — is how both prompts/
# implementor.md and prompts/reviewer.md run this script, from their own
# workspace clone. It used to always exit 2: with no --repo and no --pr, the
# script filled slug from `gh repo view` and then unconditionally passed
# --repo to `gh pr view` even with no PR number, URL or branch given — a
# combination the real gh CLI refuses outright (see the real-CLI pin below).
# The three cases here are the three shapes the fixed code can produce.

run_check_raw STUB_REPO_SLUG="Poetic-Poems/poetic-fiddle" \
  STUB_PR_ANSWER="deadbeefcafe 7" -- --wait 0
assert_eq "the default invocation resolves the branch's own PR (no --repo, no --pr)" \
  "0" "$rc"
assert_contains "and says so" "deployed and serving" "$out"

run_check_raw STUB_PR_LIST_NUMBER="7" STUB_PR_ANSWER="deadbeefcafe 7" \
  -- --repo Poetic-Poems/poetic-fiddle
assert_eq "an explicit --repo with no --pr resolves the number first, then asks by number" \
  "0" "$rc"

run_check_raw STUB_PR_ANSWER="deadbeefcafe 7" \
  -- --repo Poetic-Poems/poetic-fiddle --pr 7
assert_eq "an explicit --repo and --pr together still work" "0" "$rc"

run_check_raw STUB_BRANCH="" STUB_PR_LIST_NUMBER="7" \
  -- --repo Poetic-Poems/poetic-fiddle
assert_eq "no checked-out branch to resolve --repo against is 'could not check'" "2" "$rc"

run_check_raw STUB_PR_LIST_NUMBER="" -- --repo Poetic-Poems/poetic-fiddle
assert_eq "--repo with no PR for the branch is 'could not check'" "2" "$rc"

# --- The real gh CLI's own argument validation (not a mock) --------------------
# TD-PPagop-26080301 existed because the previous version of the stub above
# always accepted `gh pr view --repo X` with no PR number, URL or branch,
# where the real CLI refuses it — so this pins that refusal against the
# actual installed `gh` binary rather than trusting the stub to have modelled
# it correctly, which is exactly the assumption that went stale unnoticed
# last time.
#
# No GitHub credentials or network are needed: gh's argument parser rejects
# this combination before it tries to authenticate — any non-empty GH_TOKEN
# is enough to get past the "please log in" check that would otherwise
# produce a different message and mask what is under test here.
if command -v gh >/dev/null 2>&1; then
  real_gh_out="$(GH_TOKEN=dummy-token-for-argument-validation-only \
    gh pr view --json headRefOid,number --repo Poetic-Poems/agent-ops 2>&1)"
  assert_contains "real gh refuses --repo with no PR number, URL or branch" \
    "argument required when using the --repo flag" "$real_gh_out"
else
  printf 'skip - gh not on PATH, cannot pin the real CLI argument validation\n'
fi

# --- The path the prompts use -------------------------------------------------
# A stage's working directory is its own clone, so the prompts can only name
# this script through the variable the Script exports. Three files have to
# agree; asserting them against each other here is what keeps them agreeing
# (requirement 34a, as test/abandoned-drafts.test.sh does for the comment
# marker).
#
# Both literals below are single-quoted on purpose: they are the text those
# files must contain, not something to expand here — which is what SC2016 is
# warning about, and exactly what is wanted.
# shellcheck disable=SC2016
invocation='"$AGENT_OPS_ROOT/scripts/preview-deploy.sh"'
# shellcheck disable=SC2016
if grep -q '^export AGENT_OPS_ROOT="\$SCRIPT_DIR"$' "$SCRIPT_DIR/agent-cycle.sh"; then
  printf 'ok   - agent-cycle.sh exports AGENT_OPS_ROOT for the stages\n'
else
  printf 'FAIL - agent-cycle.sh does not export AGENT_OPS_ROOT — the prompts name a path nothing sets\n'
  failures=$(( failures + 1 ))
fi
for prompt in implementor reviewer; do
  assert_contains "prompts/$prompt.md invokes the check through AGENT_OPS_ROOT" \
    "$invocation" "$(cat "$SCRIPT_DIR/prompts/$prompt.md")"
done

# --fetch (issue #460): both prompts direct a stage to read what a diff-touched
# route actually served, not just that the preview answered — on the same
# invocation as the readiness check, so it costs no second network round trip.
# shellcheck disable=SC2016
fetch_invocation='"$AGENT_OPS_ROOT/scripts/preview-deploy.sh" --wait 180 --fetch <path> [--fetch <path> ...]'
for prompt in implementor reviewer; do
  assert_contains "prompts/$prompt.md invokes --fetch for the diff-touched routes" \
    "$fetch_invocation" "$(cat "$SCRIPT_DIR/prompts/$prompt.md")"
done

# --- Arguments ----------------------------------------------------------------

out="$(env PATH="$stub_bin:$PATH" "$CHECK" --wait soon 2>&1)"; rc=$?
assert_eq "a non-numeric --wait is rejected" "2" "$rc"
out="$(env PATH="$stub_bin:$PATH" "$CHECK" --nonsense 2>&1)"; rc=$?
assert_eq "an unknown argument is rejected" "2" "$rc"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
