#!/usr/bin/env bash
#
# test/stage-prompt-delivery.test.sh — a stage prompt reaches `claude` on stdin,
# whatever its size (requirement 4c).
#
# What this guards: Linux caps a *single* argv entry at MAX_ARG_STRLEN — 32
# pages, 131072 bytes, a compile-time constant no `ulimit` raises. `getconf
# ARG_MAX` reports the limit on the *total*, megabytes larger, and is no guide
# to it at all. So `claude -p "$prompt"` works right up until the assembled
# prompt crosses that line, and then fails at `execve` with E2BIG, before the
# model is ever reached.
#
# On 2026-08-01 it crossed. `prompts/coordinator.md` had grown from 37850 bytes
# to 62603 over a week of ordinary requirement work; the assembled Co-Ordinator
# prompt reached 131441 bytes, and every node in the fleet went quiet inside the
# hour — the stage exiting 126, the cycle logging `attempt-failed` and then
# `cycle-end exit_code 0`, and the dashboard showing four healthy idle nodes.
# The prompt ships in the image, so a single roll broke all of them together.
#
# The property under test is therefore *not* "the prompt is delivered" (which
# the argv version also satisfied, for a year) but "the prompt is delivered at a
# size the argv version could not carry". Both cycle scripts are covered: they
# hold byte-identical copies of `run_claude_stage`, and the review pipeline's
# smaller prompt makes it the one that would sit broken longest unnoticed.
#
# The function is lifted out of each script rather than restated here, so this
# cannot pass against a copy the script has since moved on from; the extraction
# asserts it found something for the same reason. `claude` is a stub on PATH
# that records what it was given — no network, no model, no cost.
#
# Run directly: ./test/stage-prompt-delivery.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- The stub -------------------------------------------------------------------
# Stands in for the Claude CLI: drains stdin into `prompt.seen`, records its own
# arguments into `argv.seen`, and writes the JSON envelope the parser expects.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_CAPTURE/argv.seen"
cat > "$STUB_CAPTURE/prompt.seen"
printf '{"type":"result","is_error":false,"result":"ok"}\n'
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

# --- The prompts ---------------------------------------------------------------
# `over_cap` is deliberately past MAX_ARG_STRLEN rather than merely near it: a
# test sized to the prompt of the day would stop testing anything the first time
# the prompt shrank. 200000 bytes is ~1.5x the cap and still trivial to handle
# on stdin, which is the whole point.
readonly MAX_ARG_STRLEN=131072
over_cap="$(head -c 200000 /dev/zero | tr '\0' 'x')"
small="a modest prompt"

# Confirm the cap is real on this kernel before asserting anything about it —
# otherwise a platform without it would make this file pass vacuously forever.
if /bin/true "$over_cap" 2>/dev/null; then
  printf 'ok   - this kernel imposes no single-argument cap; nothing to guard here\n\nall assertions passed\n'
  exit 0
fi

# --- One script's copy of the function -------------------------------------------
check_script() {
  local script="$1" name="${1##*/}"
  local fn capture rc seen_bytes argv_seen

  fn="$(awk '
    /^run_claude_stage\(\) \{$/ { on = 1 }
    on                          { print }
    on && /^\}$/                { exit }
  ' "$script")"

  if [[ -z "$fn" || "$fn" != *"claude -p"* ]]; then
    printf 'FAIL - run_claude_stage could not be found in %s (renamed or moved?)\n' "$name"
    failures=$(( failures + 1 ))
    return
  fi

  capture="$tmp_dir/${name%.sh}"
  mkdir -p "$capture"

  # Exported out here rather than inside the subshell: the subshell inherits it
  # either way, and an export *within* `( … )` is a change shellcheck is right
  # to flag as lost (SC2030/SC2031).
  export STUB_CAPTURE="$capture"

  # `set -euo pipefail` matches the shell both scripts run the function under —
  # the pipefail half is load-bearing here, since a `printf | claude` delivery
  # would report printf's SIGPIPE (141) rather than the stage's own status.
  (
    set -euo pipefail
    eval "$fn"
    run_claude_stage 60 test-model "$over_cap" "$capture/out" "$capture"
  )
  rc=$?

  assert_eq "$name: a prompt past the argv cap runs to completion" 0 "$rc"

  seen_bytes=0
  [[ -f "$capture/prompt.seen" ]] && seen_bytes="$(wc -c < "$capture/prompt.seen")"
  # The here-string adds the trailing newline every text stream ends with.
  assert_eq "$name: and arrives on stdin whole" \
    "$(( ${#over_cap} + 1 ))" "$seen_bytes"

  # Asserted against the flags the stub really saw, so this cannot pass by the
  # stub never having run — which is exactly what the argv version did.
  argv_seen="$(cat "$capture/argv.seen" 2>/dev/null)"
  assert_contains "$name: the stage was launched with its model" \
    "--model" "$argv_seen"
  assert_not_contains "$name: with no part of the prompt in argv" \
    "xxxxxxxxxx" "$argv_seen"

  # The envelope still lands where the caller's parser looks for it: delivery
  # changed, capture did not.
  assert_eq "$name: and the JSON envelope is captured as before" \
    '{"type":"result","is_error":false,"result":"ok"}' \
    "$(cat "$capture/out" 2>/dev/null)"

  # A small prompt must be unaffected — the fix is about the ceiling, not about
  # changing what an ordinary stage sees.
  rm -f "$capture/prompt.seen"
  (
    set -euo pipefail
    eval "$fn"
    run_claude_stage 60 test-model "$small" "$capture/out" "$capture"
  )
  assert_eq "$name: an ordinary prompt is delivered byte for byte" \
    "$small" "$(cat "$capture/prompt.seen" 2>/dev/null)"
}

printf -- '--- the cap this guards: %d bytes ---\n' "$MAX_ARG_STRLEN"
check_script "$SCRIPT_DIR/agent-cycle.sh"
check_script "$SCRIPT_DIR/review-cycle.sh"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
