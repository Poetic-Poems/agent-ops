#!/usr/bin/env bash
#
# lib/stage-run.sh — the one implementation of "run a headless `claude` stage"
# (requirement 4d of docs/IMPLEMENTATION-PIPELINE-SPEC.md).
#
# Sourced by agent-cycle.sh and review-cycle.sh so both pipelines launch, cap
# and kill a stage the same way, rather than each keeping its own copy of the
# mechanism — the same reason lib/metering.sh exists. The two copies this
# replaces were byte-identical apart from their comments, and both specs
# already said in as many words that they must not diverge; a shared file is
# the only form of that promise a reviewer does not have to check by eye.
#
# What a stage leaves behind, per invocation:
#
#   <stage>.stream.jsonl  every event the run emitted, newline-delimited JSON,
#                         written as it happens rather than at the end. Local
#                         forensics for a stage that did not finish, and the
#                         observable record of a stage's progress while it is
#                         still in flight.
#   <stage>.out           the run's final `result` event and nothing else —
#                         the same envelope `--output-format json` used to
#                         write, so every reader downstream of this function
#                         is unchanged by the switch to streaming.
#   <stage>.out.stderr    the invocation's diagnostics, kept apart from the
#                         envelope for the reason given at the redirect.

# stage_stream_file OUT_FILE
# The progress stream that accompanies a stage's `.out`. Derived rather than
# passed so that every caller — and every reader, in this repository and in
# the state mirror's exclude list — names the same file by the same rule.
stage_stream_file() {
  printf '%s.stream.jsonl' "${1%.out}"
}

# stage_result_line STREAM_FILE
# Print the run's final `result` event, or nothing (returning 1) when the
# stream carries none. Reading is deliberately tolerant in both directions a
# stream can be damaged:
#
#   - a killed run's stream ends mid-line, and jq reports a parse error at
#     EOF *after* emitting everything it had already parsed. Its status and
#     its stderr are therefore both discarded: the question here is "was a
#     complete result event written", and a torn tail is the normal shape of
#     a stage that was killed, not an error to propagate.
#   - a line that is valid JSON but not an object would make `.type` a hard
#     jq error, taking the whole program — and with it a perfectly readable
#     result line — down with it. jq's `and` short-circuits, so the type
#     guard ahead of the field test is what keeps such a line merely skipped.
#
# `tail -n 1` rather than `head`: the result event is the last thing a run
# emits, and taking the last match keeps this correct if a future CLI version
# ever emits more than one.
stage_result_line() {
  local stream_file="$1" line
  [[ -s "$stream_file" ]] || return 1
  line="$(jq -c 'select(type == "object" and .type == "result")' "$stream_file" 2>/dev/null | tail -n 1)" || true
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

# --- Run a headless claude invocation with a wall-clock timeout, killing its
#     whole process group on timeout. `set -m` gives the backgrounded job its
#     own process group so `kill -TERM -$pid` reaches every descendant. ---
#
# run_claude_stage STAGE TIMEOUT_SEC MODEL PROMPT OUT_FILE CWD
# Returns the invocation's own exit status, or 124 when the timeout fired.
# Sets the caller-visible `stage_pid`/`stage_name` for the duration (see the
# note at each pipeline's signal handler) and clears them on the way out.
run_claude_stage() {
  local stage="$1" timeout_sec="$2" model="$3" prompt="$4" out_file="$5" cwd="$6"
  local pid waited=0 rc stream_file
  stream_file="$(stage_stream_file "$out_file")"

  # stdout (the event stream) and stderr (diagnostics) are kept in separate
  # files — merging them would let stray stderr output break the JSON parse
  # of the events.
  #
  # `--output-format stream-json --verbose` rather than `--output-format
  # json`, and the difference is not the shape of the answer but *when* it
  # arrives: the JSON form writes one object at the very end, so a stage
  # killed at its cap leaves an empty file and nothing at all is known about
  # what it had done. The stream form flushes an event per line as the run
  # proceeds, so a stage's progress is observable while it is still running
  # and survives a kill. The final line of a completed stream is the same
  # envelope the JSON form produced, and it is what lands in `.out` below, so
  # nothing downstream of here can tell the difference.
  #
  # The prompt goes in on stdin, never as an argument (requirement 4c). Linux
  # caps a *single* argv entry at MAX_ARG_STRLEN — 32 pages, 131072 bytes,
  # fixed at compile time and unaffected by `ulimit`, so `getconf ARG_MAX`'s
  # far larger total is no guide to it. An assembled stage prompt is already
  # the same order of magnitude and grows with every prompt edit, so passing
  # it as `claude -p "$prompt"` puts the pipeline one paragraph away from an
  # exec that fails with E2BIG before the model is ever reached. A here-string
  # (rather than a pipe) keeps the invocation a single process whose status is
  # the stage's own: under `pipefail` a `printf | claude` would report
  # printf's SIGPIPE, 141, whenever a stage exited without draining stdin.
  #
  # This pipeline's own prompts have room to spare in the review cycle and
  # none to spare in the implementation cycle; they share this function
  # precisely so the one with room cannot quietly stop being covered.
  set -m
  ( cd "$cwd" && claude -p --model "$model" --dangerously-skip-permissions \
      --output-format stream-json --verbose <<<"$prompt" ) \
    >"$stream_file" 2>"$out_file.stderr" &
  pid=$!
  set +m
  # Advertised for the signal handler (requirement 9c): the job's own process
  # group is beyond any signal sent to ours, so a handler that does not know
  # this pid cannot stop the model this cycle is paying for.
  stage_pid="$pid"
  stage_name="$stage"

  rc=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= timeout_sec )); then
      kill -TERM "-$pid" 2>/dev/null || true
      sleep 5
      kill -KILL "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rc=124
      break
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done

  if (( rc != 124 )); then
    wait "$pid"
    rc=$?
  fi
  # Cleared for the signal handler, which reads these to decide whether to
  # blame a stage or the cycle. shellcheck cannot see that reader from here —
  # it lives in whichever script sourced this file.
  # shellcheck disable=SC2034
  stage_pid=""
  # shellcheck disable=SC2034
  stage_name=""

  # `.out` is written on every path, including the killed one, so a reader
  # never has to distinguish "no envelope" from "no file": the callers'
  # `jq -r '.result // empty'` and `metering_fields` both already degrade to
  # nothing on an empty file, which is exactly what a killed stage leaves.
  # Truncating the stream to its result event here — rather than publishing
  # the stream as `.out` — is also what keeps the state mirror's size where
  # it was: see scripts/state-sync.sh on why a stream is never replicated.
  stage_result_line "$stream_file" >"$out_file" 2>/dev/null || : >"$out_file"

  return "$rc"
}
