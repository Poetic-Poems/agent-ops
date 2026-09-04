#!/usr/bin/env bash
#
# test/memory-wiring.test.sh — regression test for requirement 2.0f's
# free-memory check in lib/standdown.sh: not whether memory_verdict
# classifies a shortfall correctly (test/memory.test.sh covers that in
# isolation) but whether the cycle actually acts on it — standing down with
# the right cause and reason, before any stage the host cannot hold ever runs.
#
# The incident this guards: the ockham WSL2 host, capped at 6 GiB and running
# two nodes whose cycles overlap for most of every hour, froze repeatedly
# because a cycle started into a host with no headroom and pushed the VM into
# a Windows-backed swap file. Requirement 2.0c already refused to start into a
# full disk; nothing refused to start into an exhausted host.
#
# The block is lifted verbatim out of lib/standdown.sh, the way
# test/disk-space-wiring.test.sh lifts its own, so the assertions are about
# the shipped code rather than a copy of its logic.
#
# No real memory read: lib/memory.sh is deliberately not sourced here.
# `memory_available_kb`, `memory_total_kb`, `memory_verdict` and
# `memory_describe` are all supplied as stubs below, so the available-KiB
# figure the block sees is injected outright and no assertion depends on this
# host's real free memory. What the real helpers compute is
# test/memory.test.sh's subject; this file's subject is only whether the
# shipped block acts on their verdict.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/memory-wiring.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_CYCLE="$SCRIPT_DIR/lib/standdown.sh"

failures=0
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

memory_block="$(extract_block '^# 2\.0f Free host memory' '^# 2\.1 Usage-limit cooldown' "$AGENT_CYCLE")"
if [[ -z "$memory_block" ]]; then
  echo "FAIL - could not extract the free-memory check block from lib/standdown.sh — has it moved?" >&2
  exit 1
fi
if ! grep -q 'memory_verdict' <<<"$memory_block"; then
  echo "FAIL - extracted block does not call memory_verdict — the anchors matched the wrong text" >&2
  exit 1
fi

# run_block AVAIL_KB MIN_BYTES EVENT_FILE — AVAIL_KB is what the stubbed
# memory_available_kb reports; MIN_BYTES seeds min_free_memory_bytes exactly
# as agent-cycle.sh's own cfg read would. Writes every log_event call to
# EVENT_FILE and prints the block's own exit status, followed by
# "FELL THROUGH" in the event file iff it ran off the end rather than exiting.
run_block() {
  local avail_kb="$1" min_bytes="$2" event_file="$3"
  : > "$event_file"
  (
    # `-e`, matching agent-cycle.sh's own top-of-file flags exactly (not this
    # test file's looser `set -uo pipefail`): a stubbed helper returning
    # non-zero for a benign reason would abort the block silently under `-e`
    # and read here as a false "FELL THROUGH never happened", the same way it
    # would abort a real cycle.
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by $memory_block below, invisible to a static reader
    min_free_memory_bytes="$min_bytes"

    # shellcheck disable=SC2317  # called from $memory_block via eval, invisible to a static reader
    memory_available_kb() { printf '%s' "$AVAIL_KB"; }
    export AVAIL_KB="$avail_kb"
    # shellcheck disable=SC2317  # called from $memory_block via eval, invisible to a static reader
    memory_total_kb() { printf '6072776'; }
    # shellcheck disable=SC2317  # called from $memory_block via eval, invisible to a static reader
    memory_verdict() {
      local free="$1" min="$2"
      [[ "$min" =~ ^[0-9]+$ ]] || min=0
      (( min > 0 )) || { printf 'ok'; return 0; }
      [[ "$free" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
      if (( free < min / 1024 )); then printf 'low'; else printf 'ok'; fi
    }
    # shellcheck disable=SC2317  # called from $memory_block via eval, invisible to a static reader
    memory_describe() { printf 'the host has only %s KiB available, below the %s bytes this cycle needs' "$1" "$2"; }

    # shellcheck disable=SC2317  # called from $memory_block via eval, invisible to a static reader
    log_event() {
      printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$EVENT_FILE"
    }
    export EVENT_FILE="$event_file"

    eval "$memory_block"
    printf 'FELL THROUGH\n' >> "$EVENT_FILE"
  )
  printf '%s' "$?"
}

# --- below the floor: stands down with cause memory-low ---

evt_file="$tmp_dir/low-events"
block_rc="$(run_block 100000 536870912 "$evt_file")"
assert_eq "memory below the floor stands the cycle down (exit 0, never falls through)" \
  "0" "$block_rc"
assert_eq "…and the block never runs off its own end into the rest of the cycle" \
  "no" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "a stand-down event was logged" \
  "yes" "$(if [[ -n "$standdown_line" ]]; then echo yes; else echo no; fi)"
assert_eq "…with cause memory-low" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"memory-low"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…carrying the available figure the verdict was made on" \
  "yes" "$(if [[ "$standdown_line" == *'"free_kb":"100000"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…and the host's total, so a small host reads differently from a busy one" \
  "yes" "$(if [[ "$standdown_line" == *'"total_kb":"6072776"'* ]]; then echo yes; else echo no; fi)"

# --- zero available: still memory-low, the one cause this gate has ---

evt_file="$tmp_dir/zero-events"
block_rc="$(run_block 0 536870912 "$evt_file")"
assert_eq "zero available memory also stands the cycle down" "0" "$block_rc"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "…with cause memory-low (unlike disk, there is no distinct 'full' state to name)" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"memory-low"'* ]]; then echo yes; else echo no; fi)"

# --- at or above the floor: falls through untouched ---

evt_file="$tmp_dir/ok-events"
block_rc="$(run_block 3629220 536870912 "$evt_file")"
assert_eq "memory above the floor falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- an unreadable /proc/meminfo: falls through, not standing down on a guess ---

evt_file="$tmp_dir/unknown-events"
block_rc="$(run_block '' 536870912 "$evt_file")"
assert_eq "an unreadable memory read falls through rather than standing down on a guess" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- min_free_memory_bytes: 0 turns the check off entirely ---

evt_file="$tmp_dir/disabled-events"
block_rc="$(run_block 0 0 "$evt_file")"
assert_eq "a 0 floor turns the check off even at zero available memory" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

echo
if (( failures == 0 )); then
  echo "All memory-wiring assertions passed."
  exit 0
else
  echo "$failures memory-wiring assertion(s) FAILED."
  exit 1
fi
