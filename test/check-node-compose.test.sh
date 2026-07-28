#!/usr/bin/env bash
#
# test/check-node-compose.test.sh — the host-side compose audit (#131),
# against a stubbed `docker` on PATH (as test/watch-node.test.sh stubs it):
# no daemon exists where this suite runs, and the script's job is verdicts,
# not Docker.
#
# The properties that matter:
#   - a synced file, an armed mount, labelled containers and a healthy
#     watchtower pass, exit 0;
#   - a comment-only difference in the file is not a failure — same
#     normalisation, same reasoning as lib/compose-drift.sh;
#   - a material difference fails and shows the diff; a missing mount, a
#     missing hook label, a watchtower without lifecycle hooks, and a
#     watchtower given both schedule and interval each fail on their own;
#   - a stack with no watchtower is information, not a failure — a node
#     without auto-update is a configuration, not a defect;
#   - no compose.yaml in the stack directory, or a scheduler that cannot be
#     exec'd into, is "cannot check" (exit 2), never a clean pass.
#
# Run directly: ./test/check-node-compose.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-node-compose.sh"

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
# One binary, its behaviour driven entirely by STUB_* variables, so each
# scenario below is a handful of env assignments rather than a new stub.
# Container c1 plays the scheduler; wt plays watchtower.
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
        case "$1" in
          cat)  [[ -n "${STUB_IMAGE_COMPOSE:-}" ]] || exit 1
                cat "$STUB_IMAGE_COMPOSE" ;;
          test) [[ "${STUB_MOUNTED:-}" == "yes" ]] ;;
        esac ;;
      ps)
        case "$1" in
          -q)  [[ -n "${STUB_CONTAINERS:-}" ]] && printf '%s\n' "$STUB_CONTAINERS" ;;
          -aq) [[ -n "${STUB_WT_ID:-}" ]] && printf '%s\n' "$STUB_WT_ID" ;;
        esac ;;
    esac ;;
  inspect)
    id="$1"; fmt="$3"
    case "$id:$fmt" in
      c1:*compose.service*) printf 'scheduler' ;;
      c1:*pre-update*)      printf '%s' "${STUB_HOOK:-}" ;;
      wt:*State.Running*)   printf '%s' "${STUB_WT_RUNNING:-true}" ;;
      wt:*Config.Env*)      printf '%s\n' "${STUB_WT_ENV:-}" ;;
    esac ;;
  logs) printf '%s\n' "${STUB_WT_LOG:-}" ;;
esac
STUB
chmod +x "$stub_bin/docker"

# --- The stack fixtures -------------------------------------------------------
stack="$tmp_dir/stack"
mkdir -p "$stack"
image_compose="$tmp_dir/image-compose.yaml"
cat > "$image_compose" <<'EOF'
# as the image ships it
services:
  scheduler:
    image: ghcr.io/example/agent-ops:latest
EOF
cp "$image_compose" "$stack/compose.yaml"

hook_path='/app/deploy/docker/watchtower-pre-update.sh'
healthy_env='WATCHTOWER_LIFECYCLE_HOOKS=true
WATCHTOWER_POLL_INTERVAL=300'

# One run, both answers, every stub variable stated per scenario.
rc=0
out=""
run_check() {  # run_check VAR=value…
  out="$(env PATH="$stub_bin:$PATH" STACK_DIR="$stack" \
    STUB_IMAGE_COMPOSE="$image_compose" STUB_CONTAINERS='c1' STUB_MOUNTED=yes \
    STUB_HOOK="$hook_path" STUB_WT_ID='wt' STUB_WT_ENV="$healthy_env" \
    STUB_WT_LOG='pre-update hook ran' \
    "$@" "$CHECK" 2>&1)"
  rc=$?
}

# --- Everything as deployed ---------------------------------------------------

run_check
assert_eq "a healthy node passes every check" "0" "$rc"
assert_contains "and says so" "all checks passed" "$out"

# --- The file -----------------------------------------------------------------

printf '# a rewritten comment, and nothing else\n\nservices:\n  scheduler:\n    image: ghcr.io/example/agent-ops:latest\n' \
  > "$stack/compose.yaml"
run_check
assert_eq "a comment-only difference is not drift" "0" "$rc"

printf 'services:\n  scheduler:\n    image: ghcr.io/example/agent-ops:latest\n    network_mode: host\n' \
  > "$stack/compose.yaml"
run_check
assert_eq "a material difference fails" "1" "$rc"
assert_contains "showing the divergence" "network_mode: host" "$out"
cp "$image_compose" "$stack/compose.yaml"

# --- The mount ----------------------------------------------------------------

run_check STUB_MOUNTED=no
assert_eq "an unarmed drift check fails" "1" "$rc"
assert_contains "naming the missing mount" "/host/compose.yaml" "$out"

# --- The labels ---------------------------------------------------------------

run_check STUB_HOOK=""
assert_eq "a container without the hook label fails" "1" "$rc"
assert_contains "saying a roll would land mid-cycle" "mid-cycle" "$out"

# --- Watchtower ---------------------------------------------------------------

run_check STUB_WT_ENV="WATCHTOWER_POLL_INTERVAL=300"
assert_eq "watchtower without lifecycle hooks fails" "1" "$rc"
assert_contains "calling the labels inert" "inert" "$out"

run_check STUB_WT_ENV="$healthy_env
WATCHTOWER_SCHEDULE=0 0 4 * * *"
assert_eq "schedule and interval both set fails" "1" "$rc"
assert_contains "warning of the fatal exit ahead" "exit fatally" "$out"

run_check STUB_WT_RUNNING=false
assert_eq "a watchtower that exists but is not running fails" "1" "$rc"

run_check STUB_WT_ID=""
assert_eq "no watchtower at all is not a failure" "0" "$rc"
assert_contains "but is said" "auto-update profile off" "$out"

# --- Cannot check is never a pass ---------------------------------------------

out="$(env PATH="$stub_bin:$PATH" STACK_DIR="$tmp_dir/empty" "$CHECK" 2>&1)"; rc=$?
assert_eq "no compose.yaml in the stack directory is exit 2" "2" "$rc"

run_check STUB_IMAGE_COMPOSE=""
assert_eq "a scheduler that cannot be exec'd into is exit 2" "2" "$rc"
assert_contains "asking whether the stack is up" "is the stack up" "$out"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
