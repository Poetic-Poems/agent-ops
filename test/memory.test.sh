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

# stub_cgroup HIGH MAX [PARENT_HIGH] — a cgroup v2 memory directory holding
# just the files the verdict reads, plus the parent window compose mounts.
#
# PARENT_HIGH defaults to the empty file `/dev/null` reads as, which is the
# unopted-in default and must be pinned rather than inherited: without it
# these assertions would read the *real* /run/cgroup-parent/memory.high and
# so pass or fail depending on whether the host running the suite happens to
# be a scheduler with a parent ceiling of its own.
stub_cgroup() {
  MEMORY_CGROUP_ROOT="$fixture_dir/cgroup"
  mkdir -p "$MEMORY_CGROUP_ROOT"
  printf '%s\n' "$1" > "$MEMORY_CGROUP_ROOT/memory.high"
  printf '%s\n' "$2" > "$MEMORY_CGROUP_ROOT/memory.max"
  printf '%s\n' "786432000" > "$MEMORY_CGROUP_ROOT/memory.current"
  MEMORY_CGROUP_PARENT_HIGH="$fixture_dir/parent-memory.high"
  printf '%s' "${3-}" > "$MEMORY_CGROUP_PARENT_HIGH"
  # Fourth arg, when passed, stubs the parent's own memory.max window; when
  # omitted the window is left unset (pointed at a path that does not exist)
  # rather than written empty, so a test can tell "read empty" apart from
  # "never read at all" the same way `stub_cgroup`'s own callers do for
  # MEMORY_CGROUP_PARENT_HIGH via the unset-vs-empty-string distinction on $3.
  if (( $# >= 4 )); then
    MEMORY_CGROUP_PARENT_MAX="$fixture_dir/parent-memory.max"
    printf '%s' "$4" > "$MEMORY_CGROUP_PARENT_MAX"
  else
    MEMORY_CGROUP_PARENT_MAX="$fixture_dir/no-such-parent-max"
  fi
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

# --- memory_cgroup_verdict: a ceiling on the parent --------------------------
#
# The state `cgroup_parent` produces, and the one the container cannot infer:
# its own memory.high reads `max` exactly as an unbounded cgroup's does, and
# only the mounted parent window tells the two apart. Getting this wrong in
# either direction is a live failure — `unbounded` here is a warning nobody
# can act on, `parented` in the case below is a node quietly ratcheting while
# doctor calls it healthy.

stub_cgroup max 1610612736 805306368 1610612736
assert_eq "a ceiling on the parent, itself hard-ceilinged, is parented" \
  "parented" "$(memory_cgroup_verdict)"

stub_cgroup max 1610612736 max
assert_eq "a parent with no ceiling of its own bounds nothing" \
  "unbounded" "$(memory_cgroup_verdict)"

stub_cgroup max 1610612736 1610612736
assert_eq "a parent ceiling at the hard limit reclaims nothing first" \
  "unbounded" "$(memory_cgroup_verdict)"

stub_cgroup max 1610612736 2147483648
assert_eq "a parent ceiling above the hard limit is not a ceiling" \
  "unbounded" "$(memory_cgroup_verdict)"

stub_cgroup max 1610612736 ""
assert_eq "an unmounted parent window (the /dev/null default) is unbounded" \
  "unbounded" "$(memory_cgroup_verdict)"

stub_cgroup 805306368 1610612736 805306368
assert_eq "this cgroup's own ceiling wins the verdict over the parent's" \
  "bounded" "$(memory_cgroup_verdict)"

stub_cgroup max 1610612736 805306368
MEMORY_CGROUP_PARENT_HIGH="$fixture_dir/no-such-parent-window"
assert_eq "a missing parent window is unbounded, never parented" \
  "unbounded" "$(memory_cgroup_verdict)"

# --- memory_cgroup_verdict: the livelock band (agent-ops#1305) ---------------
#
# A ceiling on the parent closes the band only if the parent itself has a
# real memory.max somewhere above it. Without one, memory.high throttles
# forever and nothing ever kills anything — the exact state that wedged
# ockham-container for 75 minutes while doctor.sh reported this as `parented`
# and `[ ok ]`.

stub_cgroup max 1610612736 805306368 max
assert_eq "a parent high with the parent's own max unbounded is livelocked" \
  "livelocked" "$(memory_cgroup_verdict)"

stub_cgroup max 1610612736 805306368
assert_eq "a parent high with the parent's own max unreadable is unconfirmed, not parented" \
  "unconfirmed" "$(memory_cgroup_verdict)"

stub_cgroup max 1610612736 805306368 3221225472
assert_eq "a parent high with a real parent max above it stays parented" \
  "parented" "$(memory_cgroup_verdict)"

# --- memory_cgroup_parent_max -------------------------------------------------

stub_cgroup max 1610612736 805306368 max
assert_eq "memory_cgroup_parent_max reads 'max' verbatim, not collapsed to empty" \
  "max" "$(memory_cgroup_parent_max)"

stub_cgroup max 1610612736 805306368 1610612736
assert_eq "memory_cgroup_parent_max reads a real ceiling" \
  "1610612736" "$(memory_cgroup_parent_max)"

stub_cgroup max 1610612736 805306368
assert_eq "memory_cgroup_parent_max is empty when the window cannot be read" \
  "" "$(memory_cgroup_parent_max)"

# --- memory_cgroup_parent_events_high -----------------------------------------

stub_events() {
  MEMORY_CGROUP_PARENT_EVENTS="$fixture_dir/parent-memory.events"
  printf 'low 0\nhigh %s\nmax 0\noom 0\noom_kill 0\n' "$1" > "$MEMORY_CGROUP_PARENT_EVENTS"
}

stub_events 2788595
assert_eq "memory_cgroup_parent_events_high reads the 'high' field" \
  "2788595" "$(memory_cgroup_parent_events_high)"

MEMORY_CGROUP_PARENT_EVENTS="$fixture_dir/no-such-parent-events"
assert_eq "memory_cgroup_parent_events_high is empty when the window cannot be read" \
  "" "$(memory_cgroup_parent_events_high)"

# --- memory_cgroup_describe --------------------------------------------------

stub_cgroup max 1610612736
desc="$(memory_cgroup_describe)"
assert_contains "memory_cgroup_describe names the held MiB" "750 MiB" "$desc"
assert_contains "memory_cgroup_describe names the ceiling in MiB" "1536 MiB" "$desc"
assert_contains "memory_cgroup_describe points at the fix" \
  "compose.yaml" "$desc"

# --- memory_cgroup_parent_describe -------------------------------------------

stub_cgroup max 1610612736 805306368
desc="$(memory_cgroup_parent_describe)"
assert_contains "memory_cgroup_parent_describe names the parent's ceiling" \
  "768 MiB" "$desc"
assert_contains "memory_cgroup_parent_describe names the hard ceiling" \
  "1536 MiB" "$desc"
assert_contains "memory_cgroup_parent_describe names what is held now" \
  "750 MiB" "$desc"
assert_contains "memory_cgroup_parent_describe says it survives a roll" \
  "after a roll" "$desc"

# --- memory_cgroup_livelock_describe ------------------------------------------

stub_cgroup max 1610612736 805306368 max
desc="$(memory_cgroup_livelock_describe)"
assert_contains "memory_cgroup_livelock_describe names the parent's high" "768 MiB" "$desc"
assert_contains "memory_cgroup_livelock_describe names the hard ceiling" "1536 MiB" "$desc"
assert_contains "memory_cgroup_livelock_describe names what is held now" "750 MiB" "$desc"
assert_contains "memory_cgroup_livelock_describe points at the fix" \
  "cgroup-parent-setup.sh" "$desc"

# --- memory_cgroup_unconfirmed_describe ---------------------------------------

desc="$(memory_cgroup_unconfirmed_describe)"
assert_contains "memory_cgroup_unconfirmed_describe says the state is unmeasured" \
  "unmeasured" "$desc"
assert_contains "memory_cgroup_unconfirmed_describe points at the fix" \
  "cgroup-parent-setup.sh" "$desc"

# --- Result ------------------------------------------------------------------

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
