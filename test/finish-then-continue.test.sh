#!/usr/bin/env bash
#
# test/finish-then-continue.test.sh — the chain-spawn half of finish-then-
# continue (requirement 39): once lib/chain.sh (test/chain.test.sh) says a
# cycle should chain, does agent-cycle.sh's cleanup() actually launch the next
# one, only when it should, and without ever waiting on it?
#
# The block under test is lifted verbatim out of agent-cycle.sh, the same way
# test/signal-exit.test.sh lifts the signal handler: extracted rather than
# restated, so this cannot pass against a copy the script has since moved on
# from. Assembled around it are recording stubs for `log_event` and a fake
# `agent-cycle.sh` that records how it was invoked and exits immediately — no
# real cycle ever runs.
#
# What matters, in both directions: a chain-eligible, exit-0 cycle launches
# exactly one child, with the incremented chain count and the original argv,
# detached — the parent must not block on it. `chain_eligible` alone is not
# a safe gate: every ordinary ending after a won claim — blocked, void,
# complete, a handled stage failure (handle_stage_failure) — exits 0 just
# like a stand-down does, by design, so those *do* still chain (a failed
# item must not stall the fleet from picking up a different one sooner).
# What must never chain is a cycle that did not end cleanly at all: an
# untrapped error under `set -e`, or a signal's 128+n. That is what the
# `exit_code == 0` half of the gate actually guards, and the cases below
# check exactly that boundary.
#
# Run directly: ./test/finish-then-continue.test.sh — exit 0 iff all passed.
#
# shellcheck disable=SC2016
# This file's whole business is assembling scripts whose `$`-expressions must
# reach the assembled file unexpanded; the single-quoted printf template
# below is deliberate.

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

# --- Extraction ---------------------------------------------------------------
# From the chain_eligible initialiser through `trap cleanup EXIT`, inclusive —
# the same span requirement 39's own comments live in.
extract_chain_block() {
  awk '
    /^chain_eligible=0$/ { on = 1 }
    on                   { print }
    on && /^trap cleanup EXIT$/ { exit }
  ' "$1"
}

block="$(extract_chain_block "$SCRIPT_DIR/agent-cycle.sh")"
if [[ -z "$block" ]]; then
  echo "FAIL - could not extract the chain block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Assembly ------------------------------------------------------------------
# run_cycle DESC CHAIN_ELIGIBLE MAX_CHAINED CHAIN_COUNT EXIT_CODE [ARGV...]
# Runs an assembled script that sets the globals the extracted block reads,
# then exits with EXIT_CODE (so the block's `exit_code` — captured as `$?` at
# the top of `cleanup`, exactly as agent-cycle.sh's own trap does — is real,
# not asserted by hand). Returns once the *parent* has exited; the spawn
# recording is polled for separately, since the child is detached on purpose.
child_bin_dir="$tmp_dir/child-bin"
mkdir -p "$child_bin_dir"

run_cycle() {
  local desc="$1" eligible="$2" max="$3" count="$4" code="$5"; shift 5
  local run_dir spawn_record script argv_decl a
  run_dir="$tmp_dir/$(printf '%s' "$desc" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$run_dir/scripts"
  spawn_record="$run_dir/spawned.txt"

  # The fake self: what a chained cycle would be. Records its own argv and
  # AGENT_CYCLE_CHAIN_COUNT, then exits — no real cycle, no real claude/gh.
  cat > "$run_dir/agent-cycle.sh" <<STUB
#!/usr/bin/env bash
printf 'count=%s argv=%s\n' "\${AGENT_CYCLE_CHAIN_COUNT:-}" "\$*" > "$spawn_record"
exit 0
STUB
  chmod +x "$run_dir/agent-cycle.sh"

  argv_decl="ORIGINAL_ARGV=("
  for a in "$@"; do argv_decl+="$(printf '%q ' "$a")"; done
  argv_decl+=")"

  script="$run_dir/run.sh"
  {
    printf '#!/usr/bin/env bash\nset -uo pipefail\n'
    printf 'SCRIPT_DIR=%q\n' "$run_dir"
    printf 'state_dir=%q\n' "$run_dir"
    printf 'lock_acquired=0\nlock_file=%q\nclone_dir=""\n' "$run_dir/lock.json"
    printf 'max_chained_cycles=%q\n' "$max"
    printf '%s\n' "$argv_decl"
    printf 'log_event() { printf "EVENT %%s %%s\\n" "$1" "$2" >> %q; }\n' "$run_dir/events.log"
    printf 'maybe_run_enabler() { :; }\n'
    printf '%s\n' "$block"
    printf 'chain_eligible=%q\n' "$eligible"
    printf 'chain_count=%q\n' "$count"
    printf 'exit %q\n' "$code"
  } > "$script"
  chmod +x "$script"

  timeout 10 bash "$script" >/dev/null 2>&1 || true

  # The spawn is detached and asynchronous by design; poll briefly rather
  # than assume it has landed the instant the parent returns.
  local waited=0
  while [[ ! -s "$spawn_record" ]] && (( waited < 30 )); do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  cat "$spawn_record" 2>/dev/null || true
}

# --- Chains when it should -----------------------------------------------------

out="$(run_cycle eligible-exit0 1 3 1 0 --once --repo o/one)"
assert_eq "an eligible, exit-0 cycle chains" "count=2 argv=--once --repo o/one" "$out"

out="$(run_cycle no-argv 1 3 1 0)"
assert_eq "an empty original argv replays as no argv, not a stray token" "count=2 argv=" "$out"

out="$(run_cycle count-increments 1 5 2 0)"
assert_eq "the chain count increments from wherever it stood, not reset to 2" "count=3 argv=" "$out"

# --- Does not chain when it should not -----------------------------------------

out="$(run_cycle not-eligible 0 3 1 0)"
assert_eq "chain_eligible=0 never chains, no matter the exit code" "" "$out"

out="$(run_cycle eligible-but-crashed 1 3 1 1)"
assert_eq "chain_eligible=1 with an untrapped non-zero exit does not chain" "" "$out"

out="$(run_cycle eligible-but-killed 1 3 1 143)"
assert_eq "chain_eligible=1 after a signal (128+n) does not chain" "" "$out"

out="$(run_cycle eligible-handled-failure 1 3 1 0)"
assert_eq "chain_eligible=1 after a *handled* stage failure (exit 0, like a stand-down) still chains" \
  "count=2 argv=" "$out"

# --- The parent never waits on the child ----------------------------------------

slow_run_dir="$tmp_dir/slow"
mkdir -p "$slow_run_dir/scripts"
cat > "$slow_run_dir/agent-cycle.sh" <<'STUB'
#!/usr/bin/env bash
sleep 5
STUB
chmod +x "$slow_run_dir/agent-cycle.sh"
slow_script="$slow_run_dir/run.sh"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'SCRIPT_DIR=%q\n' "$slow_run_dir"
  printf 'state_dir=%q\n' "$slow_run_dir"
  printf 'lock_acquired=0\nlock_file=%q\nclone_dir=""\n' "$slow_run_dir/lock.json"
  printf 'max_chained_cycles=3\nORIGINAL_ARGV=()\n'
  printf 'log_event() { :; }\nmaybe_run_enabler() { :; }\n'
  printf '%s\n' "$block"
  printf 'chain_eligible=1\nchain_count=1\nexit 0\n'
} > "$slow_script"
chmod +x "$slow_script"

start_ts="$(date +%s)"
timeout 10 bash "$slow_script" >/dev/null 2>&1
parent_rc=$?
elapsed=$(( $(date +%s) - start_ts ))
assert_eq "the parent's own exit is not delayed by a slow child" "0" "$parent_rc"
assert_eq "and it returns in well under the child's 5s sleep" "1" "$(( elapsed < 3 ))"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
