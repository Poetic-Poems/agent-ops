#!/usr/bin/env bash
#
# test/stage-watchdog.test.sh — the liveness watchdog of requirement 4e: a
# stage that stops producing is stopped, one that keeps producing is not, and
# the two kinds of kill are told apart afterwards.
#
# The second of those is the assertion that matters most, and it is easy to
# lose sight of. The failure this whole mechanism replaces was not "hung
# stages went unnoticed" — in 456 recorded stage runs there was never one
# genuinely hung actor. It was the opposite: a wall-clock cap killing stages
# that were working, at a tempo indistinguishable from the runs beside them
# that finished. A watchdog that kills a busy stage would be that same failure
# arriving from the other side, so "a stage emitting steadily survives a span
# several times its threshold" is tested first-class here, not as an
# afterthought to the kill.
#
# What the other cases pin down:
#
#   backstop vs inactivity   both kills exit 124, and only `kill_reason`
#                            separates them. They are opposite findings — one
#                            says the cap is too tight for work that was
#                            progressing, the other says the stage stopped —
#                            so a reader that cannot tell them apart draws the
#                            wrong correction from either.
#   0 disables               the documented escape hatch. If a node's runtime
#                            ever buffers stdout, every healthy stage would
#                            otherwise be killed at its threshold, and this is
#                            what an operator reaches for.
#   the stream survives      a killed stage's forensics are the only record of
#                            what it had done, since its envelope is never
#                            written. A kill that took the stream with it
#                            would leave the same nothing the non-streaming
#                            format left.
#   no orphaned model        the kill goes to the process group, as the
#                            backstop's always has.
#
# Timings are deliberately short (seconds, not minutes) and the assertions
# one-sided wherever a clock is involved. The poll loop wakes every two
# seconds, so every threshold here is a comfortable multiple of that.
#
# `claude` is a stub on PATH — no network, no model, no cost.
#
# Run directly: ./test/stage-watchdog.test.sh — exit 0 iff all passed.

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

# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"

# Read by the cycle scripts' signal handlers, which this file does not have.
# shellcheck disable=SC2034
stage_pid=""
# shellcheck disable=SC2034
stage_name=""

# --- The stub ---------------------------------------------------------------------
# Three behaviours, chosen by STUB_MODE:
#   quiet    emit one line, then sit silent for STUB_HOLD seconds
#   busy     emit a line every second for STUB_HOLD seconds, then finish
#   silent   emit nothing at all, for STUB_HOLD seconds
#   prompt   emit and exit immediately
# It records its own pid so the group kill can be checked.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
echo "$BASHPID" > "$STUB_CAPTURE/claude.pid"
case "${STUB_MODE:-prompt}" in
  quiet)
    printf '%s\n' '{"type":"system","subtype":"init"}'
    sleep "${STUB_HOLD:-60}"
    ;;
  rejected)
    printf '%s\n' '{"type":"system","subtype":"init"}'
    printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1786086000,"rateLimitType":"five_hour"}}'
    sleep "${STUB_HOLD:-60}"
    ;;
  warned)
    printf '%s\n' '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","utilization":0.9,"rateLimitType":"five_hour"}}'
    sleep 1
    ;;
  quoted)
    # The string, but inside a tool result rather than as an event of its own:
    # an Implementer working on limit detection reads fixtures like this.
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"expected {\"status\":\"rejected\"} here"}]}}'
    sleep 1
    ;;
  busy)
    i=0
    while (( i < ${STUB_HOLD:-10} )); do
      printf '%s\n' '{"type":"assistant","message":{}}'
      sleep 1
      i=$(( i + 1 ))
    done
    ;;
  silent)
    sleep "${STUB_HOLD:-60}"
    ;;
esac
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

run_case() {  # run_case NAME MODE HOLD BACKSTOP_SEC INACTIVITY_SEC -> sets rc, capture
  local name="$1" mode="$2" hold="$3" backstop="$4" inactivity="$5"
  capture="$tmp_dir/$name"
  mkdir -p "$capture"
  STUB_CAPTURE="$capture" STUB_MODE="$mode" STUB_HOLD="$hold" \
    run_claude_stage "$name" "$backstop" test-model "a prompt" "$capture/$name.out" "$capture" "$inactivity"
  rc=$?
}

# --- 1. A stage that stops producing is stopped -------------------------------------
# One line, then silence for far longer than the 6-second threshold. The
# backstop is 120s, so nothing but the watchdog can be responsible.
run_case wedged quiet 60 120 6
assert_eq "a stage that goes quiet past its threshold is killed" "124" "$rc"
assert_eq "and the kill is attributed to the watchdog, not the backstop" \
  "inactivity" "$stage_kill_reason"
assert_contains "which earns a warning naming what to check first" \
  "produced no output at all" "$(stage_watchdog_warning wedged)"
assert_contains "and says the threshold may be the fault, not the stage" \
  "too tight" "$(stage_watchdog_warning wedged)"

# The forensics survive the kill: this is the only record a killed stage
# leaves, since its envelope is never written.
assert_eq "the stream written before the kill survives it" "1" \
  "$(wc -l < "$capture/wedged.stream.jsonl" 2>/dev/null || echo 0)"
assert_eq "…while the envelope is empty, as it is for any killed stage" "0" \
  "$(wc -c < "$capture/wedged.out" 2>/dev/null || echo 1)"

# The stub is in its own process group; a kill that missed it would leave the
# model running and paid for.
stub_pid="$(cat "$capture/claude.pid" 2>/dev/null || echo 0)"
sleep 1
if (( stub_pid > 0 )) && kill -0 "$stub_pid" 2>/dev/null; then
  printf 'FAIL - the watchdog left the stub process alive (orphaned model)\n'
  failures=$(( failures + 1 ))
  kill -KILL "$stub_pid" 2>/dev/null || true
else
  printf 'ok   - the killed stage takes its whole process group with it\n'
fi

# --- 2. A stage that keeps producing is NOT stopped ---------------------------------
# The assertion that matters most: this is the failure being replaced, and a
# watchdog that fires here would be that failure with a new name. The stub
# emits every second for 10 seconds against a 4-second threshold — so at no
# point is it quiet for as long as the threshold, though it runs for more than
# twice it.
run_case busy busy 10 120 4
assert_eq "a stage emitting steadily is not killed, however long it runs" "0" "$rc"
assert_eq "and no kill is recorded against it" "" "$stage_kill_reason"
assert_eq "it finished, so its envelope is where its readers look" \
  "ok" "$(jq -r '.result' "$capture/busy.out" 2>/dev/null)"

# --- 3. The backstop still exists, and is a different finding ------------------------
# Silent throughout, but the watchdog is disabled — so the only cap that can
# fire is the backstop, and it must say so.
run_case walled silent 60 4 0
assert_eq "a stage that outlives its backstop is killed" "124" "$rc"
assert_eq "and the kill is attributed to the backstop" "backstop" "$stage_kill_reason"
assert_eq "a backstop kill earns no watchdog warning" "" "$(stage_watchdog_warning walled || true)"

# --- 4. Zero disables the watchdog --------------------------------------------------
# Case 3 already proves a silent stage survives to its backstop with the
# watchdog off; what remains is that it survives a span that would have killed
# it had the watchdog been on. Threshold 0, silence 8s, backstop 20s.
run_case disabled silent 8 20 0
assert_eq "with the watchdog off, a silent stage runs to completion" "0" "$rc"
assert_eq "and nothing is attributed to a watchdog that did not run" "" "$stage_kill_reason"

# --- 5. A refused account stops the stage at once -----------------------------------
# Limit detection has always run on the transcript after the stage ended, so a
# stage that hit a limit early burned the rest of its cap first. The stream
# says so as it happens. Backstop 120s, watchdog 60s — neither can be
# responsible for a kill inside a couple of seconds.
run_case refused rejected 60 120 60
assert_eq "a stage whose account is refused is stopped at once" "124" "$rc"
assert_eq "and the stop is attributed to the limit, not to a cap" \
  "rate-limit" "$stage_kill_reason"
assert_eq "the runner's own record is carried out for the stand-down" \
  "rejected" "$(jq -r '.status' <<<"$stage_rate_limit_json" 2>/dev/null)"
assert_eq "…including the reset time a prose parse would have had to guess at" \
  "1786086000" "$(jq -r '.resetsAt' <<<"$stage_rate_limit_json" 2>/dev/null)"
assert_eq "no watchdog warning: the stage was not wedged, it was refused" \
  "" "$(stage_watchdog_warning refused || true)"

# `allowed_warning` is "you are close", not "no". A stage must be allowed to
# run through it — aborting there would throw away work for a limit that had
# not been reached.
run_case warned warned 0 60 30
assert_eq "a rate-limit warning does not stop the stage" "0" "$rc"
assert_eq "and nothing is recorded against it" "" "$stage_kill_reason"

# The same string inside a tool result is content, not an event. An
# Implementer working on limit detection reads fixtures shaped exactly like
# this, and must not abort itself for doing so.
run_case quoted quoted 0 60 30
assert_eq "the status string inside a tool result is content, not a refusal" \
  "0" "$rc"
assert_eq "so the stage runs to completion" "" "$stage_kill_reason"

# --- 6. An ordinary stage reports no kill at all ------------------------------------
run_case clean prompt 0 60 30
assert_eq "a stage that ends on its own exits with its own status" "0" "$rc"
assert_eq "and carries no kill reason for the event to record" "" "$stage_kill_reason"
if stage_watchdog_warning clean >/dev/null 2>&1; then
  printf 'FAIL - a stage that was never killed produced a watchdog warning\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - and produces no warning\n'
fi

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
