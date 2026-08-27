#!/usr/bin/env bash
#
# test/disk-space-wiring.test.sh — regression test for requirement 2.0c's
# free-disk-space check in agent-cycle.sh (agent-ops#756): not whether
# disk_space_verdict classifies a shortfall correctly (test/disk-space.test.sh
# covers that in isolation) but whether the cycle actually acts on it —
# standing down with the right cause and reason, before the clone (and
# everything after it, the Co-Ordinator most of all) ever runs.
#
# The incident this guards: a node ran short of disk mid-clone / mid-push,
# leaving zero-length git objects in both nodes' state mirrors, permanently
# disabling `git gc` (#604) and leaving 4.2 GB of orphaned clones behind it
# (#605). `scripts/doctor.sh` had already read and warned about the same
# shortfall — nothing acted on the warning until this check.
#
# The block is lifted verbatim out of agent-cycle.sh, the way
# test/auth-failure-wiring.test.sh and test/backpressure-wiring.test.sh lift
# their own, so the assertions are about the shipped code rather than a copy
# of its logic.
#
# No network, no real disk read: lib/disk-space.sh is deliberately not
# sourced here. `disk_space_free_kb`, `disk_space_verdict` and
# `disk_space_describe` are all supplied as stubs below, so the free-KiB
# figure the block sees is injected outright and no assertion depends on this
# host's real free space. What the real helpers compute is
# test/disk-space.test.sh's subject; this file's subject is only whether the
# shipped block acts on their verdict.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/disk-space-wiring.test.sh — exit 0 iff all passed.

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

disk_block="$(extract_block '^# 2\.0c Free disk space' '^# 2\.1 Usage-limit cooldown' "$AGENT_CYCLE")"
if [[ -z "$disk_block" ]]; then
  echo "FAIL - could not extract the free-disk-space check block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
if ! grep -q 'disk_space_verdict' <<<"$disk_block"; then
  echo "FAIL - extracted block does not call disk_space_verdict — the anchors matched the wrong text" >&2
  exit 1
fi

# run_block FREE_KB MIN_BYTES EVENT_FILE — FREE_KB is what the stubbed
# disk_space_free_kb reports for workspace_root; MIN_BYTES seeds
# min_free_workspace_bytes exactly as agent-cycle.sh's own cfg read would.
# Writes every log_event call to EVENT_FILE and prints the block's own exit
# status followed by "FELL THROUGH" iff it ran off the end rather than
# exiting.
run_block() {
  local free_kb="$1" min_bytes="$2" event_file="$3"
  : > "$event_file"
  (
    # `-e`, matching agent-cycle.sh's own top-of-file flags exactly (not this
    # test file's own, looser `set -uo pipefail`): a stubbed helper that
    # returns non-zero for a benign reason would abort the block silently
    # under `-e` and read here as a false "FELL THROUGH never happened", the
    # same way it would abort a real cycle.
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by $disk_block below, invisible to a static reader
    workspace_root="/fake/workspace"
    # shellcheck disable=SC2034  # consumed by $disk_block below, invisible to a static reader
    min_free_workspace_bytes="$min_bytes"

    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    disk_space_free_kb() { printf '%s' "$FREE_KB"; }
    export FREE_KB="$free_kb"
    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    disk_space_verdict() {
      local free="$1" min="$2"
      [[ "$min" =~ ^[0-9]+$ ]] || min=0
      (( min > 0 )) || { printf 'ok'; return 0; }
      [[ "$free" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
      if (( free < min / 1024 )); then printf 'low'; else printf 'ok'; fi
    }
    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    disk_space_describe() { printf '%s has only %s KiB free, below the %s bytes this cycle needs' "$1" "$2" "$3"; }

    # shellcheck disable=SC2317  # called from $disk_block via eval, invisible to a static reader
    log_event() {
      printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$EVENT_FILE"
    }
    export EVENT_FILE="$event_file"

    eval "$disk_block"
    printf 'FELL THROUGH\n' >> "$EVENT_FILE"
  )
  printf '%s' "$?"
}

# --- below the floor, nonzero free space: cause is disk-low ---

evt_file="$tmp_dir/low-events"
block_rc="$(run_block 1000 2147483648 "$evt_file")"
assert_eq "free space below the floor stands the cycle down (exit 0, never falls through)" \
  "0" "$block_rc"
assert_eq "…and the block never runs off its own end into the rest of the cycle" \
  "no" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "a stand-down event was logged" \
  "yes" "$(if [[ -n "$standdown_line" ]]; then echo yes; else echo no; fi)"
assert_eq "…with cause disk-low for a nonzero shortfall" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"disk-low"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…naming workspace_root in the reason" \
  "yes" "$(if [[ "$standdown_line" == *'/fake/workspace'* ]]; then echo yes; else echo no; fi)"

# --- exactly zero free space: cause is disk-full ---

evt_file="$tmp_dir/full-events"
block_rc="$(run_block 0 2147483648 "$evt_file")"
assert_eq "zero free space also stands the cycle down" "0" "$block_rc"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "…with cause disk-full at exactly zero" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"disk-full"'* ]]; then echo yes; else echo no; fi)"

# --- at or above the floor: falls through untouched ---

evt_file="$tmp_dir/ok-events"
block_rc="$(run_block 9999999 2147483648 "$evt_file")"
assert_eq "free space above the floor falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- an unreadable df (empty free_kb): falls through, not standing down on a guess ---

evt_file="$tmp_dir/unknown-events"
block_rc="$(run_block '' 2147483648 "$evt_file")"
assert_eq "an unreadable free-space read falls through rather than standing down on a guess" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- min_free_workspace_bytes: 0 turns the check off entirely, however low free space is ---

evt_file="$tmp_dir/disabled-events"
block_rc="$(run_block 0 0 "$evt_file")"
assert_eq "a 0 floor turns the check off even at zero free space" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

echo
if (( failures == 0 )); then
  echo "All disk-space-wiring assertions passed."
  exit 0
else
  echo "$failures disk-space-wiring assertion(s) FAILED."
  exit 1
fi
