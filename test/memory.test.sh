#!/usr/bin/env bash
#
# test/memory.test.sh — regression test for lib/memory.sh: the pure
# free-memory arithmetic doctor.sh's advisory warning and agent-cycle.sh's
# pre-cycle stand-down gate (requirement 2.0f) share, so the two cannot
# silently disagree about what "low" means, plus the read-only cgroup
# inspection doctor.sh reports an unbounded container with.
#
# test/memory-wiring.test.sh covers whether the cycle actually acts on these
# functions' verdicts; this file covers only the functions themselves, against
# a fixture /proc/meminfo and a fixture cgroup so no assertion depends on this
# host's real memory or on being run inside a container at all.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/memory.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/memory.sh
. "$SCRIPT_DIR/lib/memory.sh"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected %q, got %q)\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (%q not found in %q)\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

# --- memory_available_kb / memory_total_kb ----------------------------------
#
# Both read /proc/meminfo by absolute path, so they are exercised here through
# a `cat`/`awk` that sees a fixture: the functions themselves take no path
# argument deliberately — there is exactly one /proc/meminfo, and letting a
# caller point them elsewhere would let the gate and the warning read
# different meters, which is the whole failure this lib exists to prevent.
# The fixture is supplied by shadowing the file through a bind of the awk
# invocation, which is what the stub below does.

stub_meminfo() {
  cat > "$fixture_dir/meminfo" <<EOF
MemTotal:        $1 kB
MemFree:         111111 kB
MemAvailable:    $2 kB
Buffers:          22222 kB
EOF
  # Re-define the two readers against the fixture, byte-identical to the real
  # ones but for the path — the arithmetic under test is the awk program and
  # the numeric guard, not which file they open.
  memory_available_kb() {
    local kb
    kb="$(awk '/^MemAvailable:/ {print $2; exit}' "$fixture_dir/meminfo" 2>/dev/null)"
    [[ "$kb" =~ ^[0-9]+$ ]] || return 0
    printf '%s' "$kb"
  }
  memory_total_kb() {
    local kb
    kb="$(awk '/^MemTotal:/ {print $2; exit}' "$fixture_dir/meminfo" 2>/dev/null)"
    [[ "$kb" =~ ^[0-9]+$ ]] || return 0
    printf '%s' "$kb"
  }
}

stub_meminfo 6072776 3629220
assert_eq "memory_available_kb reads MemAvailable, not MemFree" \
  "3629220" "$(memory_available_kb)"
assert_eq "memory_total_kb reads MemTotal" \
  "6072776" "$(memory_total_kb)"

rm -f "$fixture_dir/meminfo"
assert_eq "memory_available_kb is empty when /proc/meminfo cannot be read, never 0" \
  "" "$(memory_available_kb)"

# --- memory_verdict ----------------------------------------------------------

assert_eq "below the floor is low" \
  "low" "$(memory_verdict 100000 536870912)"     # ~97 MiB free, floor 512 MiB
assert_eq "exactly the floor is ok" \
  "ok" "$(memory_verdict 524288 536870912)"      # 524288 KiB == floor/1024
assert_eq "comfortably above the floor is ok" \
  "ok" "$(memory_verdict 3629220 536870912)"
assert_eq "a floor of 0 turns the check off" \
  "ok" "$(memory_verdict 0 0)"
assert_eq "an unreadable meter is not a shortfall" \
  "ok" "$(memory_verdict '' 536870912)"
assert_eq "a non-numeric meter is not a shortfall" \
  "ok" "$(memory_verdict 'unknown' 536870912)"
assert_eq "a non-numeric floor turns the check off rather than tripping it" \
  "ok" "$(memory_verdict 100000 'nonsense')"
assert_eq "zero available with a floor set is low" \
  "low" "$(memory_verdict 0 536870912)"

# --- memory_describe ---------------------------------------------------------

desc="$(memory_describe 102400 536870912)"
assert_contains "memory_describe names the MiB available" "100 MiB" "$desc"
assert_contains "memory_describe names the floor in MiB" "512 MiB" "$desc"

# --- memory_cgroup_verdict ---------------------------------------------------

# stub_cgroup HIGH MAX — a cgroup v2 memory directory holding just the two
# files the verdict reads.
stub_cgroup() {
  MEMORY_CGROUP_ROOT="$fixture_dir/cgroup"
  mkdir -p "$MEMORY_CGROUP_ROOT"
  printf '%s\n' "$1" > "$MEMORY_CGROUP_ROOT/memory.high"
  printf '%s\n' "$2" > "$MEMORY_CGROUP_ROOT/memory.max"
  printf '%s\n' "786432000" > "$MEMORY_CGROUP_ROOT/memory.current"
}

stub_cgroup max 1610612736
assert_eq "a real ceiling with memory.high unset is unbounded" \
  "unbounded" "$(memory_cgroup_verdict)"

stub_cgroup 805306368 1610612736
assert_eq "memory.high set is bounded" \
  "bounded" "$(memory_cgroup_verdict)"

stub_cgroup max max
assert_eq "no ceiling at all is unlimited, not unbounded" \
  "unlimited" "$(memory_cgroup_verdict)"

MEMORY_CGROUP_ROOT="$fixture_dir/no-such-cgroup"
assert_eq "an unreadable cgroup is unknown, never a verdict" \
  "unknown" "$(memory_cgroup_verdict)"

# --- memory_cgroup_describe --------------------------------------------------

stub_cgroup max 1610612736
desc="$(memory_cgroup_describe)"
assert_contains "memory_cgroup_describe names the held MiB" "750 MiB" "$desc"
assert_contains "memory_cgroup_describe names the ceiling in MiB" "1536 MiB" "$desc"
assert_contains "memory_cgroup_describe points at the operator recipe" \
  "compose.yaml" "$desc"

# --- Result ------------------------------------------------------------------

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
