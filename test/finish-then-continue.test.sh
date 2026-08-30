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
# The extracted block also carries the image-behind check ahead of the chain
# decision (requirement 39, agent-ops#1096): a section further down drives it
# with the real `chain_image_behind`/`chain_write_roll_pending` (lib/chain.sh,
# test/chain.test.sh already covers those two in isolation) and a stubbed
# `image_drift_status`/`agent_ops_version`, checking that this new check only
# ever *cancels* an otherwise-eligible chain — never grants one — and writes
# `roll-pending.json` exactly when, and only when, it does.
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
    printf 'log_file=%q\n' "$run_dir/log.jsonl"
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

# --- Yielding to a pending image roll (requirement 39, agent-ops#1096) ----------
# The image-behind check inside cleanup() only ever *cancels* a chain that was
# otherwise eligible; it must never grant one, and — when there is nothing to
# cancel — it must not run at all. Driven with the real chain_image_behind and
# chain_write_roll_pending (lib/chain.sh) and a stubbed image_drift_status/
# agent_ops_version, so no real registry call or build-info.json is needed.

run_cycle_image() {  # run_cycle_image DESC CHAIN_ELIGIBLE EXIT_CODE IMAGE_STATUS_JSON
  local desc="$1" eligible="$2" code="$3" image_json="$4"
  local run_dir spawn_record script
  run_dir="$tmp_dir/img-$(printf '%s' "$desc" | tr -c 'A-Za-z0-9' '-')"
  mkdir -p "$run_dir/scripts"
  spawn_record="$run_dir/spawned.txt"

  cat > "$run_dir/agent-cycle.sh" <<STUB
#!/usr/bin/env bash
printf 'spawned\n' > "$spawn_record"
exit 0
STUB
  chmod +x "$run_dir/agent-cycle.sh"

  script="$run_dir/run.sh"
  {
    printf '#!/usr/bin/env bash\nset -uo pipefail\n'
    printf 'SCRIPT_DIR=%q\n' "$run_dir"
    printf 'state_dir=%q\n' "$run_dir"
    printf 'log_file=%q\n' "$run_dir/log.jsonl"
    printf 'lock_acquired=0\nlock_file=%q\nclone_dir=""\n' "$run_dir/lock.json"
    printf 'max_chained_cycles=3\ncycle_interval_minutes=15\nORIGINAL_ARGV=()\n'
    printf 'log_event() { printf "EVENT %%s %%s\\n" "$1" "$2" >> %q; }\n' "$run_dir/events.log"
    printf 'maybe_run_enabler() { :; }\n'
    printf 'agent_ops_version() { printf null; }\n'
    printf 'IMG_JSON=%q\n' "$image_json"
    printf 'image_drift_status() { printf %%s "$IMG_JSON"; }\n'
    # shellcheck source=lib/chain.sh
    printf 'source %q\n' "$SCRIPT_DIR/lib/chain.sh"
    printf '%s\n' "$block"
    printf 'chain_eligible=%q\n' "$eligible"
    printf 'chain_count=1\n'
    printf 'exit %q\n' "$code"
  } > "$script"
  chmod +x "$script"

  timeout 10 bash "$script" >/dev/null 2>&1 || true

  # Poll briefly for the spawn the same way run_cycle does; a "does not
  # chain" case simply times out this wait, which costs it two seconds.
  local waited=0
  while [[ ! -s "$spawn_record" ]] && (( waited < 20 )); do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  printf '%s' "$run_dir"
}

behind='{"status":"behind","registry_commit":"abc1234","checked_at":"2026-08-30T00:00:00Z"}'
current='{"status":"current","checked_at":"2026-08-30T00:00:00Z"}'

run_dir="$(run_cycle_image behind-cancels-chain 1 0 "$behind")"
assert_eq "a pending image roll cancels an otherwise-eligible chain" "0" \
  "$(test -s "$run_dir/spawned.txt" && echo 1 || echo 0)"
assert_eq "…and writes the roll-pending marker" "1" \
  "$(test -f "$run_dir/roll-pending.json" && echo 1 || echo 0)"
assert_eq "…naming a bare ISO-8601 'until'" "1" \
  "$([[ "$(jq -r '.until' "$run_dir/roll-pending.json" 2>/dev/null)" \
      =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo 1 || echo 0)"

run_dir="$(run_cycle_image current-still-chains 1 0 "$current")"
assert_eq "no pending image roll: the chain proceeds exactly as before this check existed" "1" \
  "$(test -s "$run_dir/spawned.txt" && echo 1 || echo 0)"
assert_eq "…and no marker is written" "0" \
  "$(test -f "$run_dir/roll-pending.json" && echo 1 || echo 0)"

run_dir="$(run_cycle_image not-eligible-skips-the-check 0 0 "$behind")"
assert_eq "a cycle with no chain to give up never even checks the image" "0" \
  "$(test -f "$run_dir/roll-pending.json" && echo 1 || echo 0)"

run_dir="$(run_cycle_image crashed-skips-the-check 1 1 "$behind")"
assert_eq "an untrapped non-zero exit never checks the image either" "0" \
  "$(test -f "$run_dir/roll-pending.json" && echo 1 || echo 0)"

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
  printf 'log_file=%q\n' "$slow_run_dir/log.jsonl"
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

# --- The child can still be signalled -------------------------------------------
# cleanup() ignores TERM/INT/HUP before it spawns (requirement 9c's
# re-entrancy guard), and an ignored disposition survives both fork and exec:
# a child inherited into it could never trap those signals again, leaving the
# whole chained cycle deaf to requirement 1's stale-lock takeover and to a
# container stop. Assert on what the chained process actually inherits.
sig_run_dir="$tmp_dir/signals"
mkdir -p "$sig_run_dir/scripts"
sig_record="$sig_run_dir/traps.txt"
cat > "$sig_run_dir/agent-cycle.sh" <<STUB
#!/usr/bin/env bash
# A signal ignored on entry cannot be trapped; this records which of the three
# arrived that way, exactly as a real chained cycle would find them.
ignored=""
for s in TERM INT HUP; do
  [[ "\$(trap -p "\$s")" == *"trap -- '' SIG\$s"* ]] && ignored="\$ignored \$s"
done
printf 'ignored:%s\n' "\$ignored" > "$sig_record"
exit 0
STUB
chmod +x "$sig_run_dir/agent-cycle.sh"
sig_script="$sig_run_dir/run.sh"
{
  printf '#!/usr/bin/env bash\nset -uo pipefail\n'
  printf 'SCRIPT_DIR=%q\n' "$sig_run_dir"
  printf 'state_dir=%q\n' "$sig_run_dir"
  printf 'log_file=%q\n' "$sig_run_dir/log.jsonl"
  printf 'lock_acquired=0\nlock_file=%q\nclone_dir=""\n' "$sig_run_dir/lock.json"
  printf 'max_chained_cycles=3\nORIGINAL_ARGV=()\n'
  printf 'log_event() { :; }\nmaybe_run_enabler() { :; }\n'
  printf '%s\n' "$block"
  printf 'chain_eligible=1\nchain_count=1\nexit 0\n'
} > "$sig_script"
chmod +x "$sig_script"

timeout 10 bash "$sig_script" >/dev/null 2>&1 || true
waited=0
while [[ ! -s "$sig_record" ]] && (( waited < 30 )); do
  sleep 0.1
  waited=$(( waited + 1 ))
done
assert_eq "the chained cycle inherits no ignored signals — it can still be TERMed" \
  "ignored:" "$(cat "$sig_record" 2>/dev/null || true)"

# --- The other place chain_eligible is set: the contention stand-down (17a/39) --
# A raced stand-down chains — the Co-Ordinator engagement bought "the fleet is
# busy", and a fresh gather sees the winners' claims — while `unreachable`
# (same outage again), `pre-claimed` (same selection defect again), and
# `untraceable`/`fabricated` (the Script's own construction-time checks
# refusing to hand a candidate on, with no peer involved either way) never
# do. Lifted verbatim like the cleanup block above, driven with the *real*
# chain_should_continue from lib/chain.sh so the sources-remain and
# lineage-room gates are the ones that actually run.
extract_standdown_block() {
  awk '
    /^if \[\[ -z "\$claimed_json" \]\]; then$/ { on = 1 }
    on                                         { print }
    on && /^fi$/                               { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh"
}
standdown_block="$(extract_standdown_block)"
if [[ "$standdown_block" != *"standdown_cause="* ]]; then
  echo "FAIL - could not extract the stand-down block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# run_standdown ATTEMPTS UNREACHABLE SKIPS RACE_LOSSES TRACE_FAULTS FAB_FAULTS \
#   ONCE CHAIN_COUNT MAX ORDERED
# Prints the block's own stand-down event line as "EVENT stand-down <payload>
# chain=<chain_eligible as the block left it>".
run_standdown() {
  (
    # Consumed by the eval'd block, which shellcheck cannot see into.
    # shellcheck disable=SC2034
    claimed_json="" n_cand=3
    # shellcheck disable=SC2034
    claim_attempts="$1" claim_unreachable="$2" claim_skips="$3" race_losses="$4"
    # shellcheck disable=SC2034
    trace_faults="$5" fab_faults="$6"
    # shellcheck disable=SC2034
    ONCE="$7" chain_count="$8" max_chained_cycles="$9" ordered_repos_json="${10}"
    chain_eligible=0
    # Called only from inside the eval'd block, which shellcheck cannot see.
    # shellcheck disable=SC2317
    log_event() { printf 'EVENT %s %s chain=%s\n' "$1" "$2" "$chain_eligible"; }
    # shellcheck source=lib/chain.sh
    . "$SCRIPT_DIR/lib/chain.sh"
    eval "$standdown_block"
  )
}

sources_remain='[{"slug": "o/r", "sources": ["issues"]}]'
out="$(run_standdown 2 0 0 2 0 0 0 1 3 "$sources_remain")"
assert_eq "every attempted claim lost to a peer stands down raced" "raced" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.cause')"
assert_eq "…and a raced stand-down chains while sources remain" "chain=1" "${out##* }"
assert_eq "…carrying its race losses" "2" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.race_losses')"

out="$(run_standdown 2 0 0 2 0 0 0 3 3 "$sources_remain")"
assert_eq "a raced stand-down at the lineage cap does not chain" "chain=0" "${out##* }"
out="$(run_standdown 2 0 0 2 0 0 1 1 3 "$sources_remain")"
assert_eq "--once never chains, raced or not" "chain=0" "${out##* }"
out="$(run_standdown 2 0 0 2 0 0 0 1 3 '[]')"
assert_eq "no sources remaining, no chain" "chain=0" "${out##* }"

out="$(run_standdown 2 2 0 0 0 0 0 1 3 "$sources_remain")"
assert_eq "an outage stands down unreachable" "unreachable" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.cause')"
assert_eq "…and never chains into the same outage" "chain=0" "${out##* }"

out="$(run_standdown 0 0 3 0 0 0 0 1 3 "$sources_remain")"
assert_eq "no attempts at all, every candidate pre-claimed" "pre-claimed" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.cause')"
assert_eq "…and never chains into the same selection defect" "chain=0" "${out##* }"
assert_eq "…carrying the skip count" "3" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.claim_skips')"

out="$(run_standdown 1 0 2 1 0 0 0 1 3 "$sources_remain")"
assert_eq "skips beside a genuine loss still read as raced" "raced" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.cause')"
assert_eq "…with the skip count still carried" "2" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.claim_skips')"
assert_eq "…and the mixed shape chains like any raced stand-down" "chain=1" "${out##* }"

out="$(run_standdown 0 0 0 0 3 0 0 1 3 "$sources_remain")"
assert_eq "every candidate untraceable stands down untraceable" "untraceable" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.cause')"
assert_eq "…and never chains into the same construction-time fault" "chain=0" "${out##* }"
assert_eq "…carrying its own fault count" "3" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.trace_faults')"

out="$(run_standdown 0 0 0 0 0 3 0 1 3 "$sources_remain")"
assert_eq "every candidate fabricated stands down fabricated" "fabricated" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.cause')"
assert_eq "…and never chains into the same construction-time fault" "chain=0" "${out##* }"
assert_eq "…carrying its own fault count" "3" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.fab_faults')"

out="$(run_standdown 1 0 0 1 2 0 0 1 3 "$sources_remain")"
assert_eq "a genuine loss beside untraceable faults still reads raced" "raced" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.cause')"
assert_eq "…and chains like any raced stand-down" "chain=1" "${out##* }"

out="$(run_standdown 1 0 0 1 0 2 0 1 3 "$sources_remain")"
assert_eq "a genuine loss beside fabricated faults still reads raced" "raced" \
  "$(sed 's/^EVENT stand-down //; s/ chain=.*$//' <<<"$out" | jq -r '.cause')"
assert_eq "…and chains like any raced stand-down" "chain=1" "${out##* }"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
