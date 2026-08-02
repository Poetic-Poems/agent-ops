#!/usr/bin/env bash
#
# test/check-node-image.test.sh — the host-side image-staleness check (#155),
# against a stubbed `docker` on PATH (as test/check-node-compose.test.sh
# stubs it): no daemon and no registry exist where this suite runs, and the
# script's job under test is turning a verdict into an exit code, not
# reaching either one.
#
# The properties that matter:
#   - a node running the registry's newest commit passes, exit 0;
#   - one behind an image published inside the configured grace also passes,
#     exit 0, with the deferred-roll explanation — the same mid-roll
#     tolerance lib/image-drift.sh's own header and the dashboard badge give;
#   - one behind an image published longer ago than the grace fails, exit 1,
#     and names the registry commit and the grace that was exceeded;
#   - a registry the container could not reach is "cannot check", exit 2,
#     never a clean pass or a false failure;
#   - a node not running a CI-stamped image at all (a developer checkout)
#     is exit 0 with a note that the comparison does not apply — the same
#     rule lib/image-drift.sh itself uses;
#   - no compose.yaml in the stack directory, or a scheduler that cannot be
#     exec'd into, is exit 2, never a clean pass.
#
# Run directly: ./test/check-node-image.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-node-image.sh"

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

# --- The stubbed docker -------------------------------------------------------
# `docker compose --project-directory <dir> exec -T scheduler bash` reads the
# script's own heredoc on stdin (discarded here — the stub answers from
# STUB_RESULT rather than actually running lib/image-drift.sh) and prints
# STUB_RESULT, exactly the shape the real inner script's final `jq -nc`
# produces: {verdict: {...}, grace_hours: N}.
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/docker" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
case "$cmd" in
  compose)
    [[ "${1:-}" == "--project-directory" ]] && shift 2
    sub="$1"; shift
    case "$sub" in
      exec)
        shift 2   # -T scheduler
        cat >/dev/null   # the heredoc script this stub does not execute
        [[ "${STUB_EXEC_FAIL:-}" == "1" ]] && exit 1
        printf '%s' "${STUB_RESULT:-}"
        ;;
    esac ;;
esac
STUB
chmod +x "$stub_bin/docker"

stack="$tmp_dir/stack"
mkdir -p "$stack"
: > "$stack/compose.yaml"

result_json() {  # result_json <verdict-json> <grace-hours>
  jq -nc --argjson v "$1" --arg g "$2" '{verdict: $v, grace_hours: ($g | tonumber)}'
}

rc=0
out=""
run_check() {  # run_check VAR=value…
  out="$(env PATH="$stub_bin:$PATH" STACK_DIR="$stack" "$@" "$CHECK" 2>&1)"
  rc=$?
}

# --- Current --------------------------------------------------------------------

run_check STUB_RESULT="$(result_json '{"status":"current","checked_at":"2026-08-02T00:00:00Z"}' 3)"
assert_eq "a node on the registry's newest image passes" "0" "$rc"
assert_contains "and says so" "newest published image" "$out"

# --- Behind, within the grace -----------------------------------------------

created="$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
run_check STUB_RESULT="$(result_json "$(jq -nc --arg c "$created" \
  '{status:"behind", registry_commit:"abc1234567890", registry_created_at:$c, checked_at:"2026-08-02T00:00:00Z"}')" 3)"
assert_eq "behind an image published within the grace still passes" "0" "$rc"
assert_contains "explaining the deferred-roll tolerance" "grace a deferred roll is given" "$out"

# --- Behind, past the grace ---------------------------------------------------

created="$(date -u -d '10 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
run_check STUB_RESULT="$(result_json "$(jq -nc --arg c "$created" \
  '{status:"behind", registry_commit:"abc1234567890", registry_created_at:$c, checked_at:"2026-08-02T00:00:00Z"}')" 3)"
assert_eq "behind an image published past the grace fails" "1" "$rc"
assert_contains "naming the registry commit" "abc1234" "$out"
assert_contains "naming the grace that was exceeded" "3h grace" "$out"

# --- Unverified -----------------------------------------------------------------

run_check STUB_RESULT="$(result_json '{"status":"unverified","reason":"could not get a registry pull token","checked_at":"2026-08-02T00:00:00Z"}' 3)"
assert_eq "a registry the container could not reach is cannot-check" "2" "$rc"
assert_contains "naming the reason" "could not get a registry pull token" "$out"

# --- Not a CI-stamped image at all -------------------------------------------

run_check STUB_RESULT="$(result_json 'null' 3)"
assert_eq "a developer checkout is not a failure" "0" "$rc"
assert_contains "and says the comparison does not apply" "does not apply" "$out"

# --- Cannot check is never a pass ---------------------------------------------

out="$(env PATH="$stub_bin:$PATH" STACK_DIR="$tmp_dir/empty" "$CHECK" 2>&1)"; rc=$?
assert_eq "no compose.yaml in the stack directory is exit 2" "2" "$rc"

run_check STUB_EXEC_FAIL=1
assert_eq "a scheduler that cannot be exec'd into is exit 2" "2" "$rc"
assert_contains "asking whether the stack is up" "is the stack up" "$out"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
