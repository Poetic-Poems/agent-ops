#!/usr/bin/env bash
#
# test/watch-node.test.sh — the wrapper agents and humans watch a node's
# cycle events with, in place of the docker-exec incantation (TD26072102).
#
# The properties that matter:
#   - `cron` and `events` map to the right files, `-f` maps to a real follow
#     and its absence to the last 50 lines;
#   - the stack directory resolves from STACK_DIR when set, and from the
#     working directory otherwise — never silently from somewhere else;
#   - a directory with no compose.yaml is refused rather than guessed at;
#   - a missing or unknown mode, and an unknown flag, both exit non-zero with
#     usage, rather than falling through to docker with bad arguments.
#
# `docker` is stubbed, so this runs with no Docker installed, straight out of
# the checkout, exactly like the rest of the suite.
#
# Run directly: ./test/watch-node.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH="$SCRIPT_DIR/scripts/watch-node.sh"

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

# --- A stub docker, so the real script runs offline -----------------------
bin_dir="$tmp_dir/bin"
mkdir -p "$bin_dir"
capture="$tmp_dir/docker-args"
cat > "$bin_dir/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$capture"
exit 0
STUB
chmod +x "$bin_dir/docker"
export PATH="$bin_dir:$PATH"

stack_dir="$tmp_dir/stack"
mkdir -p "$stack_dir"
: > "$stack_dir/compose.yaml"

no_compose_dir="$tmp_dir/not-a-stack"
mkdir -p "$no_compose_dir"

# --- Mode -> file, and -f -> follow, via STACK_DIR -------------------------

STACK_DIR="$stack_dir" "$WATCH" cron >/dev/null
assert_contains "cron resolves to cron.log" \
  "/home/agent/.local/state/poetic-agents/cron.log" "$(cat "$capture")"
assert_contains "cron defaults to the last 50 lines" \
  "-n 50" "$(cat "$capture")"

STACK_DIR="$stack_dir" "$WATCH" events -f >/dev/null
assert_contains "events resolves to log.jsonl" \
  "/home/agent/.local/state/poetic-agents/log.jsonl" "$(cat "$capture")"
assert_contains "-f follows instead of taking the last 50 lines" \
  "-f " "$(cat "$capture")"

STACK_DIR="$stack_dir" "$WATCH" cron -f >/dev/null
assert_contains "exec's scheduler with -T (non-interactive)" \
  "exec -T scheduler" "$(cat "$capture")"
assert_contains "passes the stack dir through to docker compose" \
  "--project-directory $stack_dir" "$(cat "$capture")"

# --- The working directory resolves the stack when STACK_DIR is unset -----

( cd "$stack_dir" && "$WATCH" cron >/dev/null )
assert_eq "the cwd resolves the stack when STACK_DIR is unset" "0" "$?"
assert_contains "and it is the cwd's compose.yaml that was used" \
  "--project-directory $stack_dir" "$(cat "$capture")"

# --- Refusals ----------------------------------------------------------

STACK_DIR="$no_compose_dir" "$WATCH" cron >/dev/null 2>"$tmp_dir/err"
assert_eq "a stack dir with no compose.yaml is refused" "1" "$?"
assert_contains "naming the directory it looked in" \
  "$no_compose_dir" "$(cat "$tmp_dir/err")"

STACK_DIR="$stack_dir" "$WATCH" >/dev/null 2>"$tmp_dir/err"
assert_eq "no mode at all is refused" "1" "$?"

STACK_DIR="$stack_dir" "$WATCH" reviews >/dev/null 2>"$tmp_dir/err"
assert_eq "an unknown mode is refused" "1" "$?"

STACK_DIR="$stack_dir" "$WATCH" cron --tail >/dev/null 2>"$tmp_dir/err"
assert_eq "an unknown flag is refused" "1" "$?"

STACK_DIR="$stack_dir" "$WATCH" -h >/dev/null 2>"$tmp_dir/err"
assert_eq "-h prints usage and exits 0" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
