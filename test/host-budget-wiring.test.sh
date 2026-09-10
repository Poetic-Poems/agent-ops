#!/usr/bin/env bash
#
# test/host-budget-wiring.test.sh — regression test for requirement 2.0g's
# host-budget check in lib/standdown.sh (agent-ops#757): not whether
# lib/host-budget.sh's own functions judge a declared sum correctly
# (test/host-budget.test.sh covers that in isolation) but whether the cycle
# actually acts on it — standing down with the right cause and reason when
# `host_budget_enforce` is on, and leaving every cycle alone when it is not.
#
# The gap this closes: per-container ceilings (D14, #606) bound one
# container, but nothing summed every container sharing a host and compared
# that sum to the host's own total. Measured on ockham 2026-08-24, six
# containers each believed they could take the whole 7.457 GiB VM, and the
# host froze repeatedly.
#
# The block is lifted verbatim out of lib/standdown.sh, the way
# test/disk-space-wiring.test.sh and test/memory-wiring.test.sh lift their
# own, so the assertions are about the shipped code rather than a copy of
# its logic.
#
# No file I/O, no real host-facts record: lib/host-budget.sh is deliberately
# not sourced here. host_budget_mem_verdict/host_budget_cpu_verdict/
# host_budget_describe are all supplied as stubs below, and the record `cat`
# would read is injected by writing a fixture file, so no assertion depends
# on this host's real containers or memory.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/host-budget-wiring.test.sh — exit 0 iff all passed.

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

# Ends at 2.1's own heading: requirement 2.0g's block is the last of the
# free, no-network checks before 2.1's usage-limit cooldown, so this is the
# natural closing anchor, the same way 2.0f's own extraction in
# test/memory-wiring.test.sh ends at 2.1 too.
budget_block="$(extract_block '^# 2\.0g Host budget' '^# 2\.1 Usage-limit cooldown' "$AGENT_CYCLE")"
if [[ -z "$budget_block" ]]; then
  echo "FAIL - could not extract the host-budget check block from lib/standdown.sh — has it moved?" >&2
  exit 1
fi
if ! grep -q 'host_budget_mem_verdict' <<<"$budget_block"; then
  echo "FAIL - extracted block does not call host_budget_mem_verdict — the anchors matched the wrong text" >&2
  exit 1
fi

# write_record FILE MEM_DECLARED MEM_TOTAL CPU_DECLARED CPU_COUNT — a
# host-facts record fixture carrying exactly the `budget` sub-object the
# block reads; every other field is irrelevant to it and omitted.
write_record() {
  local file="$1" mem_declared="$2" mem_total="$3" cpu_declared="$4" cpu_count="$5"
  jq -nc --argjson md "$mem_declared" --argjson mt "$mem_total" \
    --argjson cd "$cpu_declared" --argjson cc "$cpu_count" \
    '{node:"test",driver:"compose",budget:{mem_declared_bytes:$md, mem_total_bytes:$mt,
      mem_unknown_containers:0, cpu_declared_nanos:$cd, cpu_count:$cc,
      cpu_unknown_containers:0}}' > "$file"
}

# run_block ENFORCE RECORD_FILE EVENT_FILE — ENFORCE seeds host_budget_enforce
# exactly as agent-cycle.sh's own cfg read would ("true"/"false");
# RECORD_FILE is what the stubbed `state_dir/host-facts/<node>.json` read
# resolves to (state_dir and node_name are pointed at RECORD_FILE's own
# directory/basename). Writes every log_event call to EVENT_FILE and prints
# the block's own exit status followed by "FELL THROUGH" iff it ran off the
# end rather than exiting.
run_block() {
  local enforce="$1" record_file="$2" event_file="$3"
  : > "$event_file"
  (
    # `-e`, matching lib/standdown.sh's own caller (agent-cycle.sh) exactly
    # — a stubbed helper returning non-zero for a benign reason would abort
    # the block silently under `-e` and read here as a false
    # "FELL THROUGH never happened", the same way it would abort a real
    # cycle.
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by $budget_block below, invisible to a static reader
    host_budget_enforce="$enforce"
    # shellcheck disable=SC2034  # consumed by $budget_block below, invisible to a static reader
    host_budget_reserved_memory_bytes=0
    # shellcheck disable=SC2034  # consumed by $budget_block below, invisible to a static reader
    host_budget_reserved_cpus=0
    # shellcheck disable=SC2034  # consumed by $budget_block below, invisible to a static reader
    state_dir="$(dirname "$record_file")/state"
    # shellcheck disable=SC2034  # consumed by $budget_block below, invisible to a static reader
    node_name="node"
    mkdir -p "$state_dir/host-facts"
    if [[ -f "$record_file" ]]; then
      cp "$record_file" "$state_dir/host-facts/node.json"
    fi

    # shellcheck disable=SC2317  # called from $budget_block via eval, invisible to a static reader
    host_budget_mem_verdict() {
      local declared="$1" total="$2" reserved="$3"
      [[ "$total" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
      [[ "$declared" =~ ^[0-9]+$ ]] || declared=0
      [[ "$reserved" =~ ^[0-9]+$ ]] || reserved=0
      if (( declared + reserved > total )); then printf 'over'; else printf 'ok'; fi
    }
    # shellcheck disable=SC2317  # called from $budget_block via eval, invisible to a static reader
    host_budget_cpu_verdict() {
      local declared="$1" count="$2" reserved="$3" total=""
      [[ "$count" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
      [[ "$declared" =~ ^[0-9]+$ ]] || declared=0
      total=$(( count * 1000000000 ))
      if (( declared > total )); then printf 'over'; else printf 'ok'; fi
    }
    # shellcheck disable=SC2317  # called from $budget_block via eval, invisible to a static reader
    host_budget_describe() { printf 'declared sums overcommit this fixture host'; }

    # shellcheck disable=SC2317  # called from $budget_block via eval, invisible to a static reader
    log_event() {
      printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$EVENT_FILE"
    }
    export EVENT_FILE="$event_file"
    # docs/FLOW-SCHEMA.md, requirement 50: the host-budget stand-down also
    # calls lib/node-time-state.sh's set_node_state_terminal. Stubbed to a
    # no-op — this file's own subject is the stand-down's cause and reason,
    # not the node-state record test/node-time-state.test.sh covers
    # directly.
    # shellcheck disable=SC2317  # called from $budget_block via eval, invisible to a static reader
    set_node_state_terminal() { :; }

    eval "$budget_block"
    printf 'FELL THROUGH\n' >> "$EVENT_FILE"
  )
  printf '%s' "$?"
}

# --- host_budget_enforce: false (the default) never stands anything down ---
# even against a record that plainly overcommits the fixture host.

evt_file="$tmp_dir/off-events"
rec_file="$tmp_dir/off.json"
write_record "$rec_file" 5000000000 4000000000 4000000000 2
block_rc="$(run_block false "$rec_file" "$evt_file")"
assert_eq "host_budget_enforce false falls through even against an overcommitted record" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- host_budget_enforce: true, memory overcommitted ---

evt_file="$tmp_dir/mem-over-events"
rec_file="$tmp_dir/mem-over.json"
write_record "$rec_file" 5000000000 4000000000 1000000000 4
block_rc="$(run_block true "$rec_file" "$evt_file")"
assert_eq "an overcommitted memory sum stands the cycle down (exit 0, never falls through)" \
  "0" "$block_rc"
assert_eq "…and the block never runs off its own end into the rest of the cycle" \
  "no" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "a stand-down event was logged" \
  "yes" "$(if [[ -n "$standdown_line" ]]; then echo yes; else echo no; fi)"
assert_eq "…with cause host-overcommit" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"host-overcommit"'* ]]; then echo yes; else echo no; fi)"
assert_eq "…carrying the arithmetic in the reason" \
  "yes" "$(if [[ "$standdown_line" == *'overcommit this fixture host'* ]]; then echo yes; else echo no; fi)"

# --- host_budget_enforce: true, cpu overcommitted, memory fine ---

evt_file="$tmp_dir/cpu-over-events"
rec_file="$tmp_dir/cpu-over.json"
write_record "$rec_file" 1000000000 4000000000 9000000000 2
block_rc="$(run_block true "$rec_file" "$evt_file")"
assert_eq "an overcommitted cpu sum alone also stands the cycle down" "0" "$block_rc"
standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "…with cause host-overcommit" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"host-overcommit"'* ]]; then echo yes; else echo no; fi)"

# --- host_budget_enforce: true, everything fits ---

evt_file="$tmp_dir/ok-events"
rec_file="$tmp_dir/ok.json"
write_record "$rec_file" 1000000000 4000000000 1000000000 4
block_rc="$(run_block true "$rec_file" "$evt_file")"
assert_eq "a declared sum that fits falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- host_budget_enforce: true, but no host-facts record exists yet ---

evt_file="$tmp_dir/missing-events"
block_rc="$(run_block true "$tmp_dir/does-not-exist.json" "$evt_file")"
assert_eq "a missing host-facts record falls through rather than standing down on a guess" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

# --- host_budget_enforce: true, record carries no budget section ---
# (a Kubernetes-driver record, or one written before agent-ops#757)

evt_file="$tmp_dir/no-budget-events"
rec_file="$tmp_dir/no-budget.json"
printf '{"node":"test","driver":"kubernetes"}' > "$rec_file"
block_rc="$(run_block true "$rec_file" "$evt_file")"
assert_eq "a record with no budget section falls through rather than standing down on a guess" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "…and stands nothing down" \
  "no" "$(if grep -q '^stand-down' "$evt_file"; then echo yes; else echo no; fi)"

echo
if (( failures == 0 )); then
  echo "All host-budget-wiring assertions passed."
  exit 0
else
  echo "$failures host-budget-wiring assertion(s) FAILED."
  exit 1
fi
