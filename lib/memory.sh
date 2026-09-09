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

# MEMORY_CGROUP_PARENT_HIGH is a read-only window onto the *parent* cgroup's
# `memory.high` — the one number a container cannot otherwise learn about
# itself.
#
# Under `cgroup_parent` (deploy/docker/compose.yaml) the ceiling that governs
# this container is set on an ancestor, because an ancestor is the only place
# it can be set that a container recreation does not wipe. The kernel does not
# expose an effective, hierarchy-wide `memory.high` anywhere, and a cgroup
# namespace makes the container's own cgroup the root of what it can see, so
# ancestors are invisible from in here: measured on the poetic node
# 2026-09-08, a container held to 64 MiB by its parent read its own
# `memory.high` as `max` and its own `memory.events` `high` as `0` while the
# parent counted 250 reclaim events. The only trace in the child was
# `pgscan`/`pgsteal`, which rise under ordinary host pressure too and so
# cannot distinguish a configured ceiling from a busy machine.
#
# Hence one file, bind-mounted read-only, rather than an inference. It reads
# empty when the variable is unset, because compose mounts `/dev/null` there
# — the same no-op-mount idiom the Approver key uses in that file — so the
# default is provably "no parent ceiling" rather than a guess. The mount
# cannot go stale beneath us: a cgroup cannot be removed while a process lives
# in it, so this container's own existence pins the parent it points at.
: "${MEMORY_CGROUP_PARENT_HIGH:=/run/cgroup-parent/memory.high}"

# MEMORY_CGROUP_PARENT_MAX and MEMORY_CGROUP_PARENT_EVENTS are the same kind
# of read-only window, onto the parent's `memory.max` and `memory.events`
# respectively. `memory.max` is what tells `parented` (a hard ceiling exists
# somewhere) apart from `livelocked` (it does not, so `memory.high`'s
# throttling never disengages — agent-ops#1305: `memory.current` sat above the
# parent's `memory.high` and below both `memory.max`s, so neither cgroup's OOM
# killer ever fired and every allocating task parked in `D` state for 75
# minutes). `memory.events` is what lets a rising `high` counter be reported
# before that wedge, rather than only after — the child's own copy cannot
# substitute (see `memory_cgroup_parent_high` above), so this is the parent's.
: "${MEMORY_CGROUP_PARENT_MAX:=/run/cgroup-parent/memory.max}"
: "${MEMORY_CGROUP_PARENT_EVENTS:=/run/cgroup-parent/memory.events}"

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

# memory_cgroup_parent_high
# The parent cgroup's `memory.high` in bytes, or empty when there is no parent
# window, when it reads `max` (a parent with no ceiling bounds nothing), or
# when it is unreadable. Empty means "no parent ceiling known", never "no
# ceiling" — the same refusal to assert an unmeasured verdict as
# `memory_available_kb`'s.
memory_cgroup_parent_high() {
  local value
  value="$(cat "$MEMORY_CGROUP_PARENT_HIGH" 2>/dev/null)" || return 0
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

# memory_cgroup_parent_max
# The parent cgroup's `memory.max` verbatim — `max`, a byte count, or empty
# when the window cannot be read (an un-migrated compose.yaml with nothing
# mounted there, or the /dev/null default). Unlike `memory_cgroup_parent_high`,
# `max` is deliberately **not** collapsed to empty here: a real hard ceiling
# and "no ceiling and this container cannot tell" are exactly the two states
# `memory_cgroup_verdict` must distinguish for the livelock band, and folding
# them together would silently re-report a livelocked node as merely
# unmeasured, or an unmeasured one as livelocked.
memory_cgroup_parent_max() {
  local value
  value="$(cat "$MEMORY_CGROUP_PARENT_MAX" 2>/dev/null)" || return 0
  [[ -n "$value" ]] || return 0
  printf '%s' "$value"
}

# memory_cgroup_parent_events_high
# The parent cgroup's `memory.events` `high` field — the running count of
# times the kernel has throttled this hierarchy under `memory.high` — or empty
# when the window cannot be read. Cumulative since the parent cgroup was
# created, so a caller compares a delta between two samples, never the
# absolute value: agent-ops#1305 measured 2,788,595 of these, climbing at
# ~96/second, on a node `doctor.sh` was reporting `[ ok ]`.
memory_cgroup_parent_events_high() {
  local value
  value="$(awk '$1 == "high" {print $2; exit}' "$MEMORY_CGROUP_PARENT_EVENTS" 2>/dev/null)" || return 0
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

# memory_cgroup_verdict
# Whether anything will reclaim this container's memory before it reaches its
# hard ceiling:
#
#   unbounded  `memory.max` is a real ceiling but `memory.high` is `max` here
#              and on the parent, so nothing throttles or reclaims until the
#              hard limit. The cgroup ratchets: page cache accumulates to the
#              ceiling and is given back only under pressure, which on a
#              memory-capped VM means the whole host is already in trouble.
#   bounded    `memory.high` is set on this cgroup — the kernel reclaims
#              proactively. This is what the one-shot operator recipe leaves
#              behind, and it lasts until the container is next recreated.
#   parented   this cgroup's own `memory.high` is `max`, but an ancestor
#              carries a real `memory.high` **and** the parent's own
#              `memory.max` is a real hard ceiling, so the kernel still
#              reclaims before something is actually killed — and unlike
#              `bounded` it survives a roll, because the ceiling does not live
#              on the container. Distinguished from `bounded` rather than
#              folded into it because the two differ in exactly the property
#              this check exists to report: whether the node will still be
#              bounded tomorrow.
#   livelocked the parent carries a real `memory.high` below this cgroup's own
#              `memory.max`, but the parent's own `memory.max` is `max` — so
#              `memory.high` throttles the whole hierarchy and never
#              disengages, because nothing anywhere is a hard enough ceiling
#              to reclaim past it or to kill. agent-ops#1305: 2,788,595
#              throttle events and a node wedged in `D` state for 75 minutes,
#              in exactly this band.
#   unconfirmed the parent carries a real `memory.high` below this cgroup's
#              own `memory.max`, but the parent's own `memory.max` cannot be
#              read — an un-migrated compose.yaml, or a node that has not
#              re-run `cgroup-parent-setup.sh` since it started mounting that
#              window — so whether the livelock band above is actually closed
#              is unmeasured, not confirmed. Never reported as `parented`: a
#              guess given as `[ ok ]` is exactly what left agent-ops#1305's
#              node wedged while `doctor.sh` called it healthy.
#   unlimited  no `memory.max` either; nothing to say, and nothing to fix.
#   unknown    the files cannot be read (not cgroup v2, or not a container).
memory_cgroup_verdict() {
  local high max parent_high parent_max
  high="$(memory_cgroup_field memory.high)"
  max="$(memory_cgroup_field memory.max)"
  [[ -n "$high" && -n "$max" ]] || { printf 'unknown'; return 0; }
  parent_high="$(memory_cgroup_parent_high)"
  if [[ "$max" == "max" ]]; then
    printf 'unlimited'
  elif [[ "$high" != "max" ]]; then
    printf 'bounded'
  elif [[ -n "$parent_high" ]] && (( parent_high < max )); then
    # Only below the hard ceiling. A parent set at or above `memory.max`
    # reclaims nothing before the kill and is `unbounded` in every sense that
    # matters — and this branch is the one that must not be given away on an
    # unchecked number, since `parented`/`livelocked` are the only two here
    # that can read `[ ok ]`/warn without also being `unbounded`'s own plain
    # warning. `bounded` needs no equivalent guard: it warns either way.
    parent_max="$(memory_cgroup_parent_max)"
    if [[ -z "$parent_max" ]]; then
      printf 'unconfirmed'
    elif [[ "$parent_max" == "max" ]]; then
      printf 'livelocked'
    else
      printf 'parented'
    fi
  else
    printf 'unbounded'
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
  printf 'this container holds %d MiB of memory that never gets freed up as usage grows, against a %d MiB ceiling — once that ceiling is reached the container is killed outright, instead of memory being freed beforehand; see deploy/docker/compose.yaml to fix this' \
    $(( current / 1048576 )) $(( max / 1048576 ))
}

# memory_cgroup_parent_describe
# The `parented` counterpart of `memory_cgroup_describe`: the same measured
# shape, reporting the ancestor's ceiling rather than this cgroup's absent one,
# so the ok line carries its evidence exactly as the warning does.
memory_cgroup_parent_describe() {
  local current max parent_high
  current="$(memory_cgroup_field memory.current)"
  max="$(memory_cgroup_field memory.max)"
  parent_high="$(memory_cgroup_parent_high)"
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  [[ "$max" =~ ^[0-9]+$ ]] || max=0
  [[ "$parent_high" =~ ^[0-9]+$ ]] || parent_high=0
  printf 'memory.high is set to %d MiB on this container'"'"'s parent cgroup, so the kernel reclaims before the %d MiB hard ceiling and keeps doing so after a roll; holding %d MiB now' \
    $(( parent_high / 1048576 )) $(( max / 1048576 )) $(( current / 1048576 ))
}

# memory_cgroup_livelock_describe
# The `livelocked` counterpart of memory_cgroup_describe: a real memory.high
# on the parent with no hard ceiling anywhere above this container, so
# throttling engages and never disengages — measured on agent-ops#1305 at
# ~96 events/second for 75 minutes before the node's D-state processes could
# no longer make progress at all.
memory_cgroup_livelock_describe() {
  local current max parent_high
  current="$(memory_cgroup_field memory.current)"
  max="$(memory_cgroup_field memory.max)"
  parent_high="$(memory_cgroup_parent_high)"
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  [[ "$max" =~ ^[0-9]+$ ]] || max=0
  [[ "$parent_high" =~ ^[0-9]+$ ]] || parent_high=0
  printf 'this container'"'"'s parent cgroup has memory.high set to %d MiB but its own memory.max left unbounded, so nothing ever reclaims below the %d MiB ceiling this container relies on and nothing kills above it either — holding %d MiB now; re-run scripts/cgroup-parent-setup.sh to give the parent a memory.max' \
    $(( parent_high / 1048576 )) $(( max / 1048576 )) $(( current / 1048576 ))
}

# memory_cgroup_unconfirmed_describe
# The parent carries a real memory.high below this cgroup's own memory.max,
# but the parent's own memory.max cannot be read from in here, so whether the
# livelock band above is closed is unmeasured rather than confirmed — every
# node deployed before this window was mounted lands here until it re-runs
# cgroup-parent-setup.sh and picks up the new compose.yaml mounts.
memory_cgroup_unconfirmed_describe() {
  printf 'this container'"'"'s parent cgroup has a memory.high ceiling, but its memory.max cannot be read from in here, so whether a hard ceiling would ever reclaim it is unmeasured, not confirmed ok — mount the parent'"'"'s memory.max (see deploy/docker/compose.yaml) and re-run scripts/cgroup-parent-setup.sh'
}
