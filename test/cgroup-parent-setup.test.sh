#!/usr/bin/env bash
#
# test/cgroup-parent-setup.test.sh — regression coverage for the
# host-independent decision logic in scripts/cgroup-parent-setup.sh:
# argument parsing, size conversion (to_bytes/to_ceiling/systemd_ceiling),
# the --check verdicts, and the text printed for both cgroup drivers.
#
# Against a stubbed docker/systemctl/id on PATH, and a fixture
# CGROUP_PARENT_SYS_ROOT/CGROUP_PARENT_UNIT_DIR standing in for the live
# /sys/fs/cgroup and /etc/systemd/system — the two overridable roots this
# change adds to the script, following the MEMORY_CGROUP_ROOT precedent in
# lib/memory.sh (test/memory.test.sh's own stub_cgroup does the same for
# that file). Neither root nor a real cgroup v2 host is available where this
# suite runs (agent-ops#1320), and the script needs both for its actual
# write paths, so those — writing the live memory.high/memory.max/
# memory.swap.max, `systemctl daemon-reload`, `systemctl enable --now`, and
# the reboot-persistence hook (crontab or a oneshot unit, always skipped
# below via --no-boot-hook) — stay manual-verification-only, per the issue's
# own scope. What is covered here is the decision logic upstream of those
# writes: the same class of thing that regressed silently in agent-ops#1296
# and stayed regressed until it wedged a live node in agent-ops#1305.
#
# Known gap, not fixed here (flagged by agent-ops#1320 itself): the cgroupfs
# branch (scripts/cgroup-parent-setup.sh's cgroupfs case) writes
# memory.swap.max unconditionally, with no way to skip it — even
# `--swap max` still writes — and dies if the file is absent (a host with
# swap accounting disabled has no memory.swap.max to write). A plain
# directory fixture cannot reproduce that failure: cgroupfs itself refuses
# to create an unknown file where a fixture directory would just create one,
# so the die path this gap would hit is not exercised below. If it needs
# fixing, that is a separate issue.
#
# Run directly: ./test/cgroup-parent-setup.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="$SCRIPT_DIR/scripts/cgroup-parent-setup.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

pass() { printf 'ok   - %s\n' "$1"; }

# --- Stubs: docker, systemctl, id --------------------------------------------
#
# `command -v docker` and the root check are host probes the script has no
# other way to answer; stubbing them on PATH is the same technique
# test/check-node-image.test.sh already uses for docker and
# test/doctor.test.sh uses for gh/claude.

stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"

cat > "$stub_bin/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" && "${2:-}" == "--format" ]]; then
  case "${3:-}" in
    *CgroupDriver*)  printf '%s' "${STUB_DRIVER:-systemd}" ;;
    *CgroupVersion*) printf '%s' "${STUB_CGROUP_VERSION:-2}" ;;
  esac
  exit 0
fi
exit 1
STUB
chmod +x "$stub_bin/docker"

# systemctl show -p ControlGroup --value <slice>  → the live slice path, or
# empty to fall through to the naming-rule path. daemon-reload/enable always
# succeed: the unit under test is `--no-boot-hook`'s partner, `.slice`
# management, and this suite is not testing systemd itself.
cat > "$stub_bin/systemctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  show) printf '%s' "${STUB_LIVE_SLICE:-}" ;;
  *)    exit 0 ;;
esac
STUB
chmod +x "$stub_bin/systemctl"

# id -u — the root gate (scripts/cgroup-parent-setup.sh: `[[ "$(id -u)" ==
# "0" ]]`). Ignoring the arguments and always answering STUB_UID is enough:
# the script never calls `id` any other way.
cat > "$stub_bin/id" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${STUB_UID:-0}"
STUB
chmod +x "$stub_bin/id"

# crontab, because the boot-hook path installs one and this suite must never
# touch the real user's. An earlier draft of these tests did exactly that,
# leaving two @reboot entries pointing at deleted temp directories. The stub
# records what would have been installed in CRONTAB_SPOOL so a test can assert
# on it, and answers `-l` from that same file so the replace-don't-append
# behaviour is observable.
cat > "$stub_bin/crontab" <<'STUB'
#!/usr/bin/env bash
spool="${CRONTAB_SPOOL:?CRONTAB_SPOOL must be set - refusing to touch a real crontab}"
if [[ "${1:-}" == "-l" ]]; then
  [[ -f "$spool" ]] && cat "$spool"
  exit 0
fi
cat "${1:-/dev/stdin}" > "$spool"
STUB
chmod +x "$stub_bin/crontab"

root_n=0
fresh_roots() {  # fresh_roots — a clean pair of fixture roots per call
  root_n=$(( root_n + 1 ))
  sys_root="$tmp_dir/sys-$root_n"
  unit_dir="$tmp_dir/unit-$root_n"
  mkdir -p "$sys_root" "$unit_dir"
}

run_setup() {  # run_setup ENV=val... -- ARG...
  local -a envs=()
  while [[ "${1:-}" != "--" ]]; do
    envs+=("$1")
    shift
  done
  shift
  out="$(env PATH="$stub_bin:$PATH" "${envs[@]}" bash "$SETUP" "$@" 2>&1)"
  rc=$?
}

# --- Argument parsing ---------------------------------------------------------

run_setup -- --name agentops-1 --bogus-flag
assert_eq "an unknown flag hits die, exit 1" "1" "$rc"
assert_contains "…naming the flag" "unknown argument: --bogus-flag" "$out"

run_setup -- --limit 768m
assert_eq "--name is required" "1" "$rc"
assert_contains "…and says so" "--name is required" "$out"

run_setup -- --name 'bad name!'
assert_eq "an invalid --name hits die, exit 1" "1" "$rc"
assert_contains "…naming the rule" "must be letters, digits and internal '-' only" "$out"

run_setup -- --name agentops-1 --limit
assert_eq "a flag with a missing value hits die, exit 1" "1" "$rc"
assert_contains "…naming the flag" "--limit needs a value" "$out"

run_setup -- -h
assert_eq "-h prints usage and exits 0" "0" "$rc"
assert_contains "…covering the exit-status contract" "Exit status" "$out"

# Not covered here: an invalid --limit/--max/--swap (e.g. `5x`) is a `die`
# reachable from this suite's own stubs, but it does not behave like the
# `die`s above. `to_bytes`/`to_ceiling` are called from inside a `$(...)`
# command substitution (`limit_bytes="$(to_bytes "$limit")"`), and this
# script carries no `set -e` — so that `die`'s `exit 1` only ends the
# subshell, is never seen by the caller, and the script carries on with an
# *empty* `limit_bytes` all the way to a real write. Confirmed live against
# this suite's own fixtures: `--limit 5x --check` prints "size is not a
# number: 5x" to stderr and still exits with the ordinary --check verdict,
# not 1. Filed as agent-ops#1325 rather than fixed here — this test file's
# job is coverage, not a change to the script's own error handling, and this
# gap is one call away from the real write path this item's own acceptance
# criteria puts out of scope.

# --- The docker/driver probes themselves -------------------------------------

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=systemd STUB_CGROUP_VERSION=1 \
  -- --name agentops-1 --check
assert_eq "a non-v2 cgroup host hits die, exit 1" "1" "$rc"
assert_contains "…naming the version" "this host is on cgroup v1" "$out"

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=weird STUB_CGROUP_VERSION=2 \
  -- --name agentops-1 --check
assert_eq "an unknown cgroup driver hits die, exit 1" "1" "$rc"
assert_contains "…naming it" "unknown cgroup driver 'weird'" "$out"

# --- --check: parent cgroup absent -------------------------------------------

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=cgroupfs \
  -- --name agentops-1 --check
assert_eq "an absent parent is exit 2" "2" "$rc"
assert_contains "…and says not in force" "Not in force." "$out"

# --- --check: in force, memory.max bounded -----------------------------------

fresh_roots
mkdir -p "$sys_root/agentops-1"
printf '%s' 805306368  > "$sys_root/agentops-1/memory.high"
printf '%s' 1610612736 > "$sys_root/agentops-1/memory.max"
printf '%s' 0           > "$sys_root/agentops-1/memory.swap.max"
printf '%s' 104857600   > "$sys_root/agentops-1/memory.current"
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=cgroupfs \
  -- --name agentops-1 --check
assert_eq "a bounded parent is exit 0" "0" "$rc"
assert_contains "…reporting the ceiling it read" "memory.high   805306368" "$out"
assert_contains "…and the hard ceiling" "memory.max    1610612736" "$out"

# --- --check: the livelock band (agent-ops#1305) -----------------------------

fresh_roots
mkdir -p "$sys_root/agentops-1"
printf '%s' 805306368 > "$sys_root/agentops-1/memory.high"
printf '%s' max        > "$sys_root/agentops-1/memory.max"
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=cgroupfs \
  -- --name agentops-1 --check
assert_eq "the livelock band is exit 2, same code as absent" "2" "$rc"
assert_contains "…but a distinct message naming the gap" "In the livelock band" "$out"
assert_contains "…citing the incident" "agent-ops#1305" "$out"

# --- The root gate itself, still enforced after this change ------------------

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=cgroupfs STUB_UID=1000 \
  -- --name agentops-1 --limit 768m --no-boot-hook
assert_eq "a non-root apply hits die, exit 1" "1" "$rc"
assert_contains "…naming what to do about it" "must run as root" "$out"

# --- systemd driver: to_bytes/to_ceiling/systemd_ceiling, and the printed ----
# --- unit + .env text --------------------------------------------------------
#
# `agentops-1` is the same slice name scripts/cgroup-parent-setup.sh's own
# header comment walks through, so the expected path below
# (/agentops.slice/agentops-1.slice) matches that worked example.

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=systemd STUB_CGROUP_VERSION=2 STUB_UID=0 \
  -- --name agentops-1 --limit 768m --max 1G --swap 500000000 --no-boot-hook
assert_eq "a systemd apply with bounded sizes succeeds" "0" "$rc"
unit_file="$unit_dir/agentops-1.slice"
assert_eq "…and writes the unit file" "1" "$( [[ -f "$unit_file" ]] && echo 1 || echo 0 )"
assert_contains "…768m converts to bytes" "MemoryHigh=805306368" "$(cat "$unit_file")"
assert_contains "…1G converts to bytes" "MemoryMax=1073741824" "$(cat "$unit_file")"
assert_contains "…a plain byte count passes through" "MemorySwapMax=500000000" "$(cat "$unit_file")"
assert_contains "…and reports the same numbers on stdout" \
  "wrote $unit_file (MemoryHigh=805306368, MemoryMax=1073741824, MemorySwapMax=500000000)" "$out"
parent_path="$sys_root/agentops.slice/agentops-1.slice"
assert_contains "…the naming rule nests the leaf under its own parent slice" \
  "AGENT_OPS_SCHEDULER_CGROUP_PARENT=agentops-1.slice" "$out"
assert_contains "…and the printed .env lines carry the derived path" \
  "AGENT_OPS_SCHEDULER_CGROUP_HIGH=$parent_path/memory.high" "$out"
assert_contains "…memory.max too" \
  "AGENT_OPS_SCHEDULER_CGROUP_MAX=$parent_path/memory.max" "$out"
assert_contains "…and the events file used for the livelock counter" \
  "AGENT_OPS_SCHEDULER_CGROUP_EVENTS=$parent_path/memory.events" "$out"

# --- systemd driver: to_ceiling's `max` passthrough, and systemd_ceiling's ---
# --- max → infinity translation ----------------------------------------------

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=systemd STUB_CGROUP_VERSION=2 STUB_UID=0 \
  -- --name agentops-2 --max max --swap max --no-boot-hook
assert_eq "max/max still succeeds" "0" "$rc"
unit_file="$unit_dir/agentops-2.slice"
assert_contains "…the unit file spells it systemd's way, infinity" \
  "MemoryMax=infinity" "$(cat "$unit_file")"
assert_contains "…for the swap ceiling too" \
  "MemorySwapMax=infinity" "$(cat "$unit_file")"
assert_contains "…while what to_ceiling itself produced (the cgroupfs spelling) is what stdout reports" \
  "wrote $unit_file (MemoryHigh=805306368, MemoryMax=max, MemorySwapMax=max)" "$out"

# --- systemd driver: a live slice overrides the naming rule ------------------
#
# "Where systemd says it is, when it is running, beats where the rule says
# it should be" (scripts/cgroup-parent-setup.sh) — the one branch in the
# systemd case that is not a pure function of --name.

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=systemd STUB_CGROUP_VERSION=2 STUB_UID=0 \
  STUB_LIVE_SLICE=/custom.slice/agentops-3.slice \
  -- --name agentops-3 --no-boot-hook
assert_eq "a live slice path is honoured" "0" "$rc"
assert_contains "…over the naming-rule path" \
  "AGENT_OPS_SCHEDULER_CGROUP_HIGH=$sys_root/custom.slice/agentops-3.slice/memory.high" "$out"

# --- cgroupfs driver: to_bytes/to_ceiling, and the printed file + .env text --

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=cgroupfs STUB_UID=0 \
  -- --name agentops-4 --limit 768m --max 1536m --swap 0 --no-boot-hook
assert_eq "a cgroupfs apply with bounded sizes succeeds" "0" "$rc"
parent_dir="$sys_root/agentops-4"
assert_contains "…1536m converts to bytes, written to memory.max" "1610612736" "$(cat "$parent_dir/memory.max")"
assert_contains "…and 0 is written verbatim to memory.swap.max" "0" "$(cat "$parent_dir/memory.swap.max")"
assert_contains "…768m converts to bytes, written to memory.high" "805306368" "$(cat "$parent_dir/memory.high")"
assert_contains "…and each write is echoed on stdout, in the order written (max, swap, high)" \
  "set $parent_dir/memory.max = 1610612736
set $parent_dir/memory.swap.max = 0
set $parent_dir/memory.high = 805306368" "$out"
assert_contains "…the .env parent line carries no .slice suffix on cgroupfs" \
  "AGENT_OPS_SCHEDULER_CGROUP_PARENT=agentops-4" "$out"
assert_eq "…and the .env line is never suffixed .slice on cgroupfs" \
  "0" "$( [[ "$out" == *"agentops-4.slice"* ]] && echo 1 || echo 0 )"

# --- cgroupfs driver: to_ceiling's `max` passthrough, unmodified by ----------
# --- systemd_ceiling (that translation belongs to the systemd case alone) ----

fresh_roots
run_setup CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  STUB_DRIVER=cgroupfs STUB_UID=0 \
  -- --name agentops-5 --max max --swap max --no-boot-hook
assert_eq "max/max still succeeds" "0" "$rc"
parent_dir="$sys_root/agentops-5"
assert_eq "…written to memory.max as the literal cgroupfs word, never systemd's infinity" \
  "max" "$(cat "$parent_dir/memory.max")"
assert_eq "…and to memory.swap.max the same way" \
  "max" "$(cat "$parent_dir/memory.swap.max")"

# --- Delegation, poisoned paths, and leaving no bait (agent-ops#1347) ---------
#
# The failure these cover took ockham-container off the air: the reboot hook
# created the parent, could not write the interface files because the memory
# controller was not delegated yet, and left a bare directory that Docker then
# populated with a cgroup named `memory.high`. The invariant worth protecting
# is the last one — a run that cannot finish must leave nothing behind.

fresh_roots
printf 'cpuset cpu io memory pids\n' > "$sys_root/cgroup.controllers"
printf 'cpuset cpu io pids\n' > "$sys_root/cgroup.subtree_control"
run_setup STUB_DRIVER=cgroupfs CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  CGROUP_PARENT_HELPER_DIR="$tmp_dir/sbin-$root_n" -- \
  --name agentops-d1 --limit 768m --no-boot-hook
assert_eq "an undelegated root is delegated rather than written through" "0" "$rc"
assert_contains "…and says which cgroup it delegated to" \
  "delegated the memory controller to the children of $sys_root" "$out"
assert_contains "…leaving memory in subtree_control" "memory" "$(cat "$sys_root/cgroup.subtree_control")"

fresh_roots
printf 'cpuset cpu io pids\n' > "$sys_root/cgroup.controllers"
printf 'cpuset cpu io pids\n' > "$sys_root/cgroup.subtree_control"
run_setup STUB_DRIVER=cgroupfs CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  CGROUP_PARENT_HELPER_DIR="$tmp_dir/sbin-$root_n" -- \
  --name agentops-d2 --limit 768m --no-boot-hook
assert_eq "a host whose kernel has no memory controller is refused, not half-done" "1" "$rc"
assert_contains "…naming the reason" "memory controller is not available" "$out"
assert_eq "…and the parent it created is removed, so Docker has nothing to mount over" \
  "absent" "$([ -e "$sys_root/agentops-d2" ] && echo present || echo absent)"

fresh_roots
printf 'cpuset cpu io memory pids\n' > "$sys_root/cgroup.controllers"
printf 'cpuset cpu io memory pids\n' > "$sys_root/cgroup.subtree_control"
mkdir -p "$sys_root/agentops-d3/memory.high"
run_setup STUB_DRIVER=cgroupfs CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  CGROUP_PARENT_HELPER_DIR="$tmp_dir/sbin-$root_n" -- \
  --name agentops-d3 --limit 768m --no-boot-hook
assert_eq "a poisoned interface path is repaired rather than fatal" "0" "$rc"
assert_contains "…and the repair is announced" "is a directory, not a file" "$out"
assert_eq "…leaving memory.high a real file again" \
  "805306368" "$(cat "$sys_root/agentops-d3/memory.high" 2>/dev/null)"

fresh_roots
printf 'cpuset cpu io pids\n' > "$sys_root/cgroup.controllers"
printf 'cpuset cpu io pids\n' > "$sys_root/cgroup.subtree_control"
mkdir -p "$sys_root/agentops-d4"
printf 'pre-existing\n' > "$sys_root/agentops-d4/marker"
run_setup STUB_DRIVER=cgroupfs CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  CGROUP_PARENT_HELPER_DIR="$tmp_dir/sbin-$root_n" -- \
  --name agentops-d4 --limit 768m --no-boot-hook
assert_eq "a parent this run did not create is never removed on failure" \
  "present" "$([ -e "$sys_root/agentops-d4/marker" ] && echo present || echo absent)"

# --- The reboot hook is a generated script, not an inline chain ----------------

fresh_roots
helper_dir="$tmp_dir/sbin-$root_n"
spool="$tmp_dir/crontab-$root_n"
printf 'cpuset cpu io memory pids\n' > "$sys_root/cgroup.controllers"
printf 'cpuset cpu io memory pids\n' > "$sys_root/cgroup.subtree_control"
# Seed the spool with the old inline chain this change replaces, plus an
# unrelated line that must survive.
printf '@reboot mkdir -p %s/agentops-h1 && echo 1 > %s/agentops-h1/memory.high\n4 4 * * * updatedb\n' \
  "$sys_root" "$sys_root" > "$spool"
run_setup STUB_DRIVER=cgroupfs CGROUP_PARENT_SYS_ROOT="$sys_root" CGROUP_PARENT_UNIT_DIR="$unit_dir" \
  CRONTAB_SPOOL="$spool" CGROUP_PARENT_HELPER_DIR="$helper_dir" -- \
  --name agentops-h1 --limit 768m
helper="$helper_dir/agent-ops-cgroup-parent-agentops-h1.sh"
assert_eq "the boot hook is written as its own script" \
  "yes" "$([ -x "$helper" ] && echo yes || echo no)"
assert_contains "…which delegates the controller before writing" \
  "cgroup.subtree_control" "$(cat "$helper" 2>/dev/null)"
assert_contains "…clears a poisoned path" "rmdir" "$(cat "$helper" 2>/dev/null)"
assert_contains "…and removes the parent again if the files never appeared" \
  "left nothing for Docker to mount over" "$(cat "$helper" 2>/dev/null)"
assert_eq "installing it replaces the old inline chain rather than appending" \
  "0" "$(grep -c 'mkdir -p .* && echo' "$spool" 2>/dev/null)"
assert_eq "…leaving exactly one hook for this parent" \
  "1" "$(grep -c 'agent-ops-cgroup-parent-agentops-h1.sh' "$spool" 2>/dev/null)"
assert_eq "…and unrelated crontab lines untouched" \
  "1" "$(grep -c 'updatedb' "$spool" 2>/dev/null)"

# --- shellcheck ---

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x "$SETUP" >/dev/null; then
    pass "scripts/cgroup-parent-setup.sh is shellcheck-clean"
  else
    printf 'FAIL - scripts/cgroup-parent-setup.sh is shellcheck-clean\n'
    shellcheck -x "$SETUP"
    failures=$(( failures + 1 ))
  fi
else
  printf 'skip - shellcheck not on PATH\n'
fi

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
