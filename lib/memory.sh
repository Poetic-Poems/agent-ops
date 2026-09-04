#!/usr/bin/env bash
#
# lib/memory.sh — free host memory, and this container's own memory cgroup,
# read and judged one way everywhere: `scripts/doctor.sh`'s advisory warnings
# and `agent-cycle.sh`'s pre-cycle stand-down gate (requirement 2.0f) share
# this rather than each doing its own `/proc/meminfo` arithmetic, so the two
# can no longer silently disagree about what "low" means. It is the memory
# counterpart of `lib/disk-space.sh`, deliberately the same shape.
#
# ## Why this exists
#
# Requirement 2.0c stands a cycle down when `workspace_root` is short of
# disk. Nothing did the same for memory, and on the ockham WSL2 host that is
# the half that keeps biting: the VM is capped at 6 GiB, two nodes' cycles
# overlap for most of every hour, and a cycle that starts into a host with no
# headroom pushes the VM into a Windows-backed swap file, whereupon the whole
# machine stalls. A stand-down costs one cycle; a freeze costs the host, and
# takes the state mirrors' git objects with it (#604).
#
# ## What can be read from inside a container, and what cannot
#
# Two facts this file rests on, both verified on the ockham node 2026-09-04:
#
#   1. `/proc/meminfo` is **not** namespaced. A container reads its host's
#      (here, the WSL2 VM's) real MemTotal and MemAvailable, which is exactly
#      what a gate protecting the host needs — the cgroup's own accounting
#      would describe only this container and miss the peer node, the editor
#      and everything else sharing the machine.
#
#   2. A container can read, but not write, its own cgroup v2 files. So this
#      file can *report* that `memory.high` is unset while `memory.current`
#      sits near `memory.max` — the state in which nothing reclaims until the
#      hard limit — but it cannot fix it. Docker exposes no `memory.high`
#      setting at all, and its `--memory-swap` is silently inert wherever
#      `docker info` reports "No swap limit support" (which is a false
#      negative on this kernel: the cgroup accepts the write, Docker's own
#      cgroup-v1 probe simply fails to detect it). The remedy is therefore an
#      operator recipe, documented in `deploy/docker/compose.yaml`, and what
#      this file contributes is the detection that tells an operator to run
#      it.
#
# ## What this file deliberately does not do
#
# Release page cache. `posix_fadvise(POSIX_FADV_DONTNEED)` does work
# unprivileged from inside the container and drops clean, unmapped cache
# immediately (measured: 307 MiB in one call), but it earns almost nothing
# here: a cycle already deletes its clone, and deleting a file frees its
# cache anyway, so the only trees that survive a cycle are the state
# directory and the peer mirrors — which a `memory.high` that is actually set
# keeps trimmed continuously. Measured on a live node with `memory.high` in
# force, fadvising every file under `workspace_root`, `state_dir`, the Claude
# configuration and `/app` released **zero** bytes: what remained was mapped
# executables and libraries, which `DONTNEED` cannot evict. A cycle-end
# release pass would therefore be code that runs every cycle to do nothing.

# memory_available_kb
# MemAvailable from /proc/meminfo, in KiB (that file's own unit), or empty if
# it cannot be read. Never prints `0` for "unreadable": a caller must be able
# to tell "definitely short" from "no idea", the same distinction
# `disk_space_free_kb` and `github_limit_verdict`'s `unknown` already draw.
#
# MemAvailable, not MemFree: the kernel's own estimate of what a new
# allocation can have without swapping, which counts reclaimable page cache
# as available. MemFree would read a host whose cache is doing its job as
# critically short and stand down every cycle on a healthy machine.
memory_available_kb() {
  local kb
  kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$kb"
}

# memory_total_kb
# MemTotal from /proc/meminfo, in KiB, or empty when unreadable. Reported
# alongside the shortfall so a reader can tell a small host from a busy one.
memory_total_kb() {
  local kb
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$kb"
}

# memory_verdict FREE_KB MIN_BYTES
# "low" when FREE_KB (KiB) is below MIN_BYTES (bytes — the config unit) once
# converted to the same one; "ok" otherwise, including when MIN_BYTES is `0`
# (the floor is off) or FREE_KB is empty/unreadable. An unreadable meter is no
# evidence of an exhausted host — standing down on it would invent a failure
# mode a missing /proc never had, the same reasoning requirement 2.0's
# `unknown` and 2.0c's own gate already rest on.
memory_verdict() {
  local free_kb="${1:-}" min_bytes="${2:-0}" min_kb
  [[ "$min_bytes" =~ ^[0-9]+$ ]] || min_bytes=0
  (( min_bytes > 0 )) || { printf 'ok'; return 0; }
  [[ "$free_kb" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
  min_kb=$(( min_bytes / 1024 ))
  if (( free_kb < min_kb )); then
    printf 'low'
  else
    printf 'ok'
  fi
}

# memory_describe FREE_KB MIN_BYTES
# The one-line explanation both the stand-down event and doctor.sh's warning
# use, so the two can never describe the same shortfall differently.
memory_describe() {
  local free_kb="${1:-0}" min_bytes="${2:-0}" min_mib
  [[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0
  [[ "$min_bytes" =~ ^[0-9]+$ ]] || min_bytes=0
  min_mib=$(( min_bytes / 1024 / 1024 ))
  printf 'the host has only %d MiB of memory available, below the %d MiB this cycle needs — a cycle runs a model stage that this host must hold alongside every other node sharing it' \
    $(( free_kb / 1024 )) "$min_mib"
}

# --- This container's own memory cgroup -------------------------------------
#
# Read-only, and advisory only. Everything below degrades to empty or
# `unknown` off cgroup v2 (a cgroup v1 host, a non-container checkout, a
# kernel without these files), because a doctor pass that cannot read a knob
# must say so rather than assert a verdict it did not measure.

# MEMORY_CGROUP_ROOT is the container's own cgroup directory. Overridable so
# the tests can point it at a fixture rather than the live one.
: "${MEMORY_CGROUP_ROOT:=/sys/fs/cgroup}"

# memory_cgroup_field FIELD
# One cgroup memory file's contents (`memory.current`, `memory.high`,
# `memory.max`, ...), or empty when it cannot be read.
memory_cgroup_field() {
  local field="${1:-}" value
  [[ -n "$field" ]] || return 0
  value="$(cat "$MEMORY_CGROUP_ROOT/$field" 2>/dev/null)" || return 0
  [[ -n "$value" ]] || return 0
  printf '%s' "$value"
}

# memory_cgroup_stat KEY
# One field of `memory.stat` (`anon`, `file`, ...), or empty when unreadable.
memory_cgroup_stat() {
  local key="${1:-}" value
  [[ -n "$key" ]] || return 0
  value="$(awk -v k="$key" '$1 == k {print $2; exit}' \
    "$MEMORY_CGROUP_ROOT/memory.stat" 2>/dev/null)" || return 0
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

# memory_cgroup_verdict
# Whether anything will reclaim this container's memory before it reaches its
# hard ceiling:
#
#   unbounded  `memory.max` is a real ceiling but `memory.high` is `max`, so
#              nothing throttles or reclaims until the hard limit. The cgroup
#              ratchets: page cache accumulates to the ceiling and is given
#              back only under pressure, which on a memory-capped VM means
#              the whole host is already in trouble.
#   bounded    `memory.high` is set — the kernel reclaims proactively.
#   unlimited  no `memory.max` either; nothing to say, and nothing to fix.
#   unknown    the files cannot be read (not cgroup v2, or not a container).
memory_cgroup_verdict() {
  local high max
  high="$(memory_cgroup_field memory.high)"
  max="$(memory_cgroup_field memory.max)"
  [[ -n "$high" && -n "$max" ]] || { printf 'unknown'; return 0; }
  if [[ "$max" == "max" ]]; then
    printf 'unlimited'
  elif [[ "$high" == "max" ]]; then
    printf 'unbounded'
  else
    printf 'bounded'
  fi
}

# memory_cgroup_describe
# The one-line explanation doctor.sh's `unbounded` warning uses. Names the
# measured figures rather than only the verdict, so the warning carries its
# own evidence.
memory_cgroup_describe() {
  local current max
  current="$(memory_cgroup_field memory.current)"
  max="$(memory_cgroup_field memory.max)"
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  [[ "$max" =~ ^[0-9]+$ ]] || max=0
  printf 'this container holds %d MiB against a %d MiB ceiling with memory.high unset, so nothing reclaims until the hard limit — see deploy/docker/compose.yaml for the operator recipe' \
    $(( current / 1048576 )) $(( max / 1048576 ))
}
