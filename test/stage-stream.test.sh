#!/usr/bin/env bash
#
# test/stage-stream.test.sh — a stage streams as it runs, and still leaves the
# envelope every reader downstream of it expects (requirement 4d).
#
# What this guards, and why it is two properties rather than one:
#
#   the stream grows while the stage is still running
#     This is the whole reason for `--output-format stream-json --verbose`.
#     The non-streaming form writes one object at the very end, so a stage
#     killed at its cap left an empty file and nothing at all was known about
#     how far it had got — the shape of every timeout in this repository's
#     history. If a runtime ever buffers the stage's stdout when it is not a
#     tty, the file stops growing until the run ends and every use of the
#     stream silently becomes a use of nothing; asserting on growth *during*
#     the run is what catches that, and asserting on the finished file would
#     not.
#
#   `<stage>.out` is unchanged
#     Nothing downstream reads the stream: the result parsers, the per-stage
#     metering record (requirement 33a), limit detection and the dashboard all
#     read `<stage>.out`, and they read it exactly as they did before the
#     switch because `run_claude_stage` truncates the stream to its final
#     `result` event. `metering_fields` is run against both here — the
#     truncated line and a bare non-streaming envelope carrying the same
#     numbers — and asserted to derive the identical record, because "the
#     migration changed nothing" is a claim about that record and not about
#     the file it came from.
#
# The degradations matter as much as the happy path, because a killed stage is
# a normal event here and its stream ends mid-line: a torn tail must still
# yield an earlier `result` event, and a stream with no `result` event at all
# must leave `.out` empty rather than corrupt — empty is what every reader
# already treats as "this stage produced no envelope".
#
# `claude` is a stub on PATH that emits canned NDJSON with pauses between
# lines — no network, no model, no cost.
#
# Run directly: ./test/stage-stream.test.sh — exit 0 iff all passed.

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

assert_true() {
  local desc="$1" cond="$2"
  if [[ "$cond" == "true" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (was %s)\n' "$desc" "$cond"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"
# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"

# The signal handlers' globals, which run_claude_stage advertises into. Set
# here because the library is sourced without a cycle script around it; read
# by a handler this file does not have, which is why shellcheck is told so.
# shellcheck disable=SC2034
stage_pid=""
# shellcheck disable=SC2034
stage_name=""

# --- The stub -------------------------------------------------------------------
# Emits one NDJSON line at a time with a pause between them, recording its argv
# so the invocation itself can be asserted on. `STUB_LINES` names a file of
# lines to emit; `STUB_PAUSE` is the gap between them.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_CAPTURE/argv.seen"
cat > /dev/null
while IFS= read -r line; do
  printf '%s\n' "$line"
  sleep "${STUB_PAUSE:-0}"
done < "$STUB_LINES"
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

# A four-event run: the CLI's own preamble, two assistant turns, and the result
# envelope. The numbers in the envelope are the ones metering reads.
RESULT_LINE='{"type":"result","subtype":"success","is_error":false,"result":"done","duration_ms":4200,"num_turns":7,"total_cost_usd":0.25,"modelUsage":{"claude-sonnet-5":{"inputTokens":100,"outputTokens":20,"cacheCreationInputTokens":5,"cacheReadInputTokens":7}}}'
{
  printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1"}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}'
  printf '%s\n' "$RESULT_LINE"
} > "$tmp_dir/lines.happy"

# --- 1. The stream grows while the stage runs -------------------------------------
capture="$tmp_dir/happy"
mkdir -p "$capture"
export STUB_CAPTURE="$capture"
export STUB_LINES="$tmp_dir/lines.happy"

out="$capture/implementer.out"
stream="$(stage_stream_file "$out")"
assert_eq "the stream sits beside the .out under a derived name" \
  "$capture/implementer.stream.jsonl" "$stream"

# Sampled from a watcher rather than after the fact: what is under test is that
# bytes land in the file *before* the run ends. The stub pauses between lines,
# so a sample taken while it is still emitting must see a partial file — and a
# buffered runtime would show zero the whole way and then everything at once.
: > "$capture/samples"
(
  while [[ ! -f "$stream" ]]; do sleep 0.05; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s\n' "$(wc -l < "$stream" 2>/dev/null || echo 0)" >> "$capture/samples"
    sleep 0.15
  done
) &
watcher=$!

STUB_PAUSE=0.3 run_claude_stage implementer 60 test-model "a prompt" "$out" "$capture"
rc=$?
wait "$watcher" 2>/dev/null || true

assert_eq "a streaming stage exits with the invocation's own status" 0 "$rc"
assert_contains "the invocation asks for the streaming output format" \
  "stream-json" "$(cat "$capture/argv.seen" 2>/dev/null)"
assert_contains "and for the --verbose that makes it emit every event" \
  "--verbose" "$(cat "$capture/argv.seen" 2>/dev/null)"

# `partial` is a sample strictly between "nothing yet" and "all four lines".
partial="$(awk '$1 > 0 && $1 < 4 { found = 1 } END { print (found ? "true" : "false") }' \
  "$capture/samples")"
assert_true "the stream is readable mid-run, not only once the stage ends" "$partial"

assert_eq "and it holds every event the run emitted" \
  "4" "$(wc -l < "$stream")"

# --- 2. `.out` is the envelope, unchanged ------------------------------------------
assert_eq "the .out holds exactly the final result event" \
  "$RESULT_LINE" "$(cat "$out")"
assert_eq "one line and no more" "1" "$(wc -l < "$out")"

# The claim the whole migration rests on: the derived record is identical
# whether the envelope arrived as a stream's last line or as the whole file a
# non-streaming invocation used to write.
printf '%s\n' "$RESULT_LINE" > "$capture/non-streaming.out"
assert_eq "metering derives the same record from it as from a non-streaming envelope" \
  "$(metering_fields claude-sonnet-5 "$capture/non-streaming.out")" \
  "$(metering_fields claude-sonnet-5 "$out")"
assert_eq "and that record carries the envelope's own numbers" \
  "4200 7 0.25 100" \
  "$(jq -r '[.duration_ms, .num_turns, .cost_usd, .tokens.input] | join(" ")' \
     <<<"$(metering_fields claude-sonnet-5 "$out")")"

# --- 3. A torn tail — the shape a killed stage leaves ------------------------------
# jq reports a parse error at EOF on a stream that ends mid-line. That must not
# cost the reader an earlier, complete result event.
torn="$tmp_dir/torn.stream.jsonl"
{ cat "$tmp_dir/lines.happy"; printf '{"type":"assist'; } > "$torn"
assert_eq "a torn tail still yields the result event before it" \
  "$RESULT_LINE" "$(stage_result_line "$torn")"

# --- 4. No result event at all — a stage killed before it finished ------------------
printf '%s\n' '{"type":"system","subtype":"init"}' > "$tmp_dir/lines.killed"
printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}' >> "$tmp_dir/lines.killed"

killed="$tmp_dir/killed"
mkdir -p "$killed"
STUB_CAPTURE="$killed" STUB_LINES="$tmp_dir/lines.killed" \
  run_claude_stage reviewer 60 test-model "a prompt" "$killed/reviewer.out" "$killed"

assert_true "a stage that emitted no result event still leaves a .out" \
  "$([[ -f "$killed/reviewer.out" ]] && echo true || echo false)"
assert_eq "and that .out is empty rather than corrupt" \
  "0" "$(wc -c < "$killed/reviewer.out")"
assert_eq "which metering degrades to the all-null record, as for a stage that never ran" \
  "null" "$(jq -r '.cost_usd // "null"' <<<"$(metering_fields test-model "$killed/reviewer.out")")"
assert_eq "while the stream keeps what the stage did emit" \
  "2" "$(wc -l < "$killed/reviewer.stream.jsonl")"

# A stream that is only garbage yields nothing, and says so.
printf 'not json at all\n' > "$tmp_dir/garbage.stream.jsonl"
if stage_result_line "$tmp_dir/garbage.stream.jsonl" >/dev/null 2>&1; then
  printf 'FAIL - a stream with no readable event reported one anyway\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - a stream with no readable event reports none\n'
fi

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
