#!/usr/bin/env bash
#
# test/signal-exit.test.sh — a signal leaves a record, a released claim, and no
# orphaned model (implementation spec requirement 9c / acceptance check 4a;
# review spec R7a).
#
# What this guards: the kills that reach a cycle script are real and routine —
# a peer taking over a stale lock TERMs the whole process group, an operator
# stops a container, a `--once` run is interrupted at the terminal. Before the
# handler under test existed, any of them ended bash between one statement and
# the next: no `attempt-failed`, no claim release, no `cycle-end` — and the
# stage's own process group, which `set -m` detaches precisely so the timeout
# can kill it whole, kept a model running for a cycle that was already dead.
# Every stale-lock takeover in the July logs left exactly that nothing behind.
#
# The machinery is lifted out of each script rather than restated here, so this
# cannot pass against a copy the script has since moved on from; the extraction
# asserts it found something for the same reason. The signalled process is a
# real second process assembled from the lifted parts plus recording stubs —
# signal semantics are the one thing a same-process eval cannot exercise.
# `claude` is a stub that records its pid and sleeps; no network, no model, no
# cost.
#
# Run directly: ./test/signal-exit.test.sh — exit 0 iff all passed.
#
# shellcheck disable=SC2016
# This file's whole business is assembling scripts whose `$`-expressions must
# reach the assembled file unexpanded; every single-quoted block below is
# deliberate.

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
# Stands in for the Claude CLI: records the pid a later liveness probe will ask
# about, then sleeps far past every timeout in play.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
echo "$BASHPID" > "$STUB_CAPTURE/claude.pid"
sleep 60
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

# --- Extraction -----------------------------------------------------------------
# The signal block runs from the module-level `stage_pid=""` initialiser to the
# last trap line; the stage runner comes from the library both scripts source.
extract_signal_block() {
  awk '
    /^stage_pid=""$/     { on = 1 }
    on                   { print }
    on && /^trap .on_signal HUP/ { exit }
  ' "$1"
}

# The stage runner is a library both cycle scripts source (requirement 4d), so
# it is taken whole rather than carved out of a script: `run_claude_stage`
# calls its neighbours in that file, and a lift of the function alone would
# assemble a script that could not run it.
stage_runner_lib() {
  cat "$SCRIPT_DIR/lib/stage-run.sh"
}

# assemble_and_signal NAME CAPTURE_DIR PRELUDE MAINLINE SIGNAL_BLOCK STAGE_FN
# Build a runnable script from the lifted parts plus recording stubs, start it,
# TERM it once the readiness marker appears, and reap it. Prints the exit
# status; the recorded calls are in CAPTURE_DIR/calls.log.
assemble_and_signal() {
  local name="$1" capture="$2" prelude="$3" mainline="$4" signal_block="$5" stage_fn="$6"
  local mini="$capture/mini.sh" pid waited

  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'CAPTURE=%q\n' "$capture"
    printf 'export STUB_CAPTURE=%q\n' "$capture"
    # The EXIT trap stands in for cleanup: what matters is that the handler
    # exits *through* it, carrying 128+n.
    printf 'record() { printf '\''%%s\n'\'' "$*" >> "$CAPTURE/calls.log"; }\n'
    printf 'trap '\''record "cycle-end $?"'\'' EXIT\n'
    printf '%s\n' "$prelude"
    printf '%s\n' "$signal_block"
    printf '%s\n' "$stage_fn"
    printf '%s\n' "$mainline"
  } > "$mini"
  chmod +x "$mini"

  "$mini" &
  pid=$!

  waited=0
  while [[ ! -f "$capture/ready" ]] && (( waited < 100 )); do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  if [[ ! -f "$capture/ready" ]]; then
    printf 'FAIL - %s: the assembled script never became ready\n' "$name" >&2
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    echo "unready"
    return
  fi

  kill -TERM "$pid" 2>/dev/null
  wait "$pid"
  echo "$?"
}

# The stubs every assembled script shares. read_pr_url_breadcrumb honours
# FAKE_PR_URL so one prelude serves both the no-pr and have-pr cases.
common_prelude='
log_attempt_failed() { record "attempt-failed stage=$1 detail=$2 extra=$3"; }
log_event() { record "event $1 $2"; }
release_claim() { record "release-claim $1"; }
release_review_claim() { record "release-review-claim $1 $2 $3 $4"; }
read_pr_url_breadcrumb() { printf "%s\n" "${FAKE_PR_URL:-}"; }
clone_dir="${FAKE_CLONE_DIR:-}"
selected_repo=""
selected_item=""
claim_active=1
'

# --- agent-cycle.sh: a TERM mid-stage -------------------------------------------
signal_block="$(extract_signal_block "$SCRIPT_DIR/agent-cycle.sh")"
stage_fn="$(stage_runner_lib)"

if [[ "$signal_block" != *"on_signal"* || "$stage_fn" != *"claude -p"* ]]; then
  printf 'FAIL - the signal machinery could not be found in agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
assert_contains "the lifted block arms all three traps" "on_signal INT" "$signal_block"
assert_contains "and the lifted stage runner advertises its pid" 'stage_pid="$pid"' "$stage_fn"

mid_stage_mainline='
touch "$CAPTURE/ready.pre"
( while [[ ! -f "$CAPTURE/claude.pid" ]]; do sleep 0.1; done; touch "$CAPTURE/ready" ) &
run_claude_stage implementor 60 test-model "a prompt" "$CAPTURE/out" "$CAPTURE" || true
record "stage-returned"
'

capture="$tmp_dir/agent-mid-stage"
mkdir -p "$capture"
rc="$(FAKE_PR_URL="" FAKE_CLONE_DIR="" assemble_and_signal "agent-cycle mid-stage" \
  "$capture" "$common_prelude" "$mid_stage_mainline" "$signal_block" "$stage_fn")"
calls="$(cat "$capture/calls.log" 2>/dev/null)"

assert_eq "agent-cycle: a TERM mid-stage exits 143 through the EXIT trap" "143" "$rc"
assert_contains "agent-cycle: and the death is recorded against the stage in flight" \
  "attempt-failed stage=implementor detail=implementor terminated by SIGTERM" "$calls"
assert_contains "agent-cycle: the claim is released no-pr when no PR is known" \
  "release-claim no-pr" "$calls"
assert_contains "agent-cycle: cycle-end still carries the truthful code" \
  "cycle-end 143" "$calls"
assert_not_contains "agent-cycle: the stage never returned on its own" \
  "stage-returned" "$calls"

stub_pid="$(cat "$capture/claude.pid" 2>/dev/null)"
stage_dead=alive
if [[ -n "$stub_pid" ]]; then
  # The handler KILLs the stage's group; give the kernel a moment to reap.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$stub_pid" 2>/dev/null || { stage_dead=dead; break; }
    sleep 0.2
  done
fi
assert_eq "agent-cycle: the stub model's own process group is dead, not orphaned" \
  "dead" "$stage_dead"

# --- agent-cycle.sh: the breadcrumb names a PR ----------------------------------
capture="$tmp_dir/agent-breadcrumb"
mkdir -p "$capture"
rc="$(FAKE_PR_URL="https://github.com/example/repo/pull/1" FAKE_CLONE_DIR="$capture" \
  assemble_and_signal "agent-cycle breadcrumb" \
  "$capture" "$common_prelude" "$mid_stage_mainline" "$signal_block" "$stage_fn")"
calls="$(cat "$capture/calls.log" 2>/dev/null)"

assert_eq "agent-cycle: a TERM with a breadcrumb still exits 143" "143" "$rc"
assert_contains "agent-cycle: the recorded event carries the PR the breadcrumb names" \
  "pull/1" "$calls"
assert_contains "agent-cycle: and the claim is released have-pr" \
  "release-claim have-pr" "$calls"

# --- agent-cycle.sh: no stage in flight -----------------------------------------
idle_mainline='
touch "$CAPTURE/ready"
sleep 20 &
wait $! || true
record "slept-through"
'

capture="$tmp_dir/agent-idle"
mkdir -p "$capture"
rc="$(FAKE_PR_URL="" FAKE_CLONE_DIR="" assemble_and_signal "agent-cycle idle" \
  "$capture" "$common_prelude" "$idle_mainline" "$signal_block" "$stage_fn")"
calls="$(cat "$capture/calls.log" 2>/dev/null)"

assert_eq "agent-cycle: a TERM between stages exits 143" "143" "$rc"
assert_contains "agent-cycle: and blames the cycle, not a stage that had already ended" \
  "attempt-failed stage=cycle detail=cycle terminated by SIGTERM" "$calls"

# --- review-cycle.sh: a TERM mid-review -----------------------------------------
review_signal_block="$(extract_signal_block "$SCRIPT_DIR/review-cycle.sh")"
# The same library, deliberately: the two pipelines run one stage runner, and
# a review-side copy of this fixture would be testing something the review
# pipeline no longer has.
review_stage_fn="$stage_fn"

if [[ "$review_signal_block" != *"on_signal"* ]]; then
  printf 'FAIL - the signal machinery could not be found in review-cycle.sh (renamed or moved?)\n'
  exit 1
fi

review_mainline='
signal_claim_slug="Poetic-Poems/example"
signal_claim_branch="review/2026-01-01"
signal_claim_safe="Poetic-Poems_example"
touch "$CAPTURE/ready.pre"
( while [[ ! -f "$CAPTURE/claude.pid" ]]; do sleep 0.1; done; touch "$CAPTURE/ready" ) &
run_claude_stage reviewer 60 test-model "a prompt" "$CAPTURE/out" "$CAPTURE" || true
record "stage-returned"
'

capture="$tmp_dir/review-mid-stage"
mkdir -p "$capture"
rc="$(FAKE_PR_URL="" FAKE_CLONE_DIR="" assemble_and_signal "review-cycle mid-stage" \
  "$capture" "$common_prelude" "$review_mainline" "$review_signal_block" "$review_stage_fn")"
calls="$(cat "$capture/calls.log" 2>/dev/null)"

assert_eq "review-cycle: a TERM mid-review exits 143 through the EXIT trap" "143" "$rc"
assert_contains "review-cycle: the record names the repo and the stage in flight" \
  "terminated by SIGTERM" "$calls"
assert_contains "review-cycle: and the review claim is released no-pr" \
  "release-review-claim Poetic-Poems/example review/2026-01-01 Poetic-Poems_example no-pr" \
  "$calls"

# --- agent-cycle.sh: the requirement-1 takeover grace ---------------------------
# A live stale holder is TERMed and the taker proceeds as soon as the holder
# exits — polled, not slept — then takes the lock over.
acquire_fn="$(awk '
  /^acquire_lock\(\) \{$/ { on = 1 }
  on                      { print }
  on && /^\}$/            { exit }
' "$SCRIPT_DIR/agent-cycle.sh")"

if [[ "$acquire_fn" != *"grace_waited"* ]]; then
  printf 'FAIL - the takeover grace could not be found in acquire_lock (renamed or moved?)\n'
  failures=$(( failures + 1 ))
else
  capture="$tmp_dir/takeover"
  mkdir -p "$capture"

  # The stale holder: its own process group (setsid), a TERM handler that
  # records and exits — the shape of a cycle whose requirement-9c handler
  # works. Its lock is 5 hours old against a 4-hour staleness bound.
  setsid bash -c '
    trap "printf \"holder-got-term\n\" >> \"$1/calls.log\"; exit 0" TERM
    sleep 300 &
    wait $!
  ' holder "$capture" &
  holder_pid=$!
  sleep 0.3

  jq -n --argjson pid "$holder_pid" \
    --arg started_at "$(date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "${HOSTNAME:-}" \
    '{pid: $pid, started_at: $started_at, host: $host}' > "$capture/lock.json"

  started_epoch="$(date +%s)"
  (
    set -euo pipefail
    # The next three variables and the stub are consumed by the eval'd
    # acquire_lock, which shellcheck cannot see into.
    # shellcheck disable=SC2034
    lock_file="$capture/lock.json"
    # shellcheck disable=SC2034
    lock_stale_after_hours=4
    lock_acquired=0
    # shellcheck disable=SC2317
    log_event() { printf 'event %s %s\n' "$1" "$2" >> "$capture/calls.log"; }
    eval "$acquire_fn"
    acquire_lock
    printf 'lock-acquired %s\n' "$lock_acquired" >> "$capture/calls.log"
  )
  takeover_rc=$?
  elapsed=$(( $(date +%s) - started_epoch ))

  calls="$(cat "$capture/calls.log" 2>/dev/null)"
  assert_eq "takeover: acquire_lock over a live stale holder succeeds" "0" "$takeover_rc"
  assert_contains "takeover: the holder was TERMed, not KILLed outright" \
    "holder-got-term" "$calls"
  assert_contains "takeover: and the takeover was logged as a warning" \
    "stale lock from pid $holder_pid" "$calls"
  assert_contains "takeover: the lock was taken" "lock-acquired 1" "$calls"
  grace_verdict="within"
  (( elapsed >= 15 )) && grace_verdict="slept out the grace"
  assert_eq "takeover: a holder that exits promptly is not waited out (${elapsed}s)" \
    "within" "$grace_verdict"

  kill -KILL "$holder_pid" 2>/dev/null
  wait "$holder_pid" 2>/dev/null
fi

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
