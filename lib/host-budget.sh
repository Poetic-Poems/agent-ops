#!/usr/bin/env bash
#
# lib/host-budget.sh — whether the *sum* of every running container's
# declared ceiling on this host still fits the host itself (issue #757).
# D14 (#606) bounds one container's blast radius with a `mem_limit`/`cpus`
# ceiling; Docker reserves nothing, so the sum of every limit on a host may
# freely exceed it, and nothing before this file computed that sum or
# compared it to anything. `deploy/docker/compose.yaml`'s own "Resource
# ceilings (D14)" comment already does this arithmetic by hand for the
# two-nodes-one-host layout ("one tailnet node at 2.4 GiB plus one local
# node at 2.2 GiB leaves headroom for the VM itself") — this file is that
# arithmetic, automated and checked every cycle instead of trusted to stay
# correct in a comment.
#
# Deliberately the same shape as lib/disk-space.sh / lib/memory.sh: a pure
# reader, a verdict, and a describe — so a caller (lib/standdown.sh's
# requirement 2.0g, scripts/doctor.sh's advisory) can never disagree with
# another about what "over budget" means. Every function here takes its
# numbers as arguments rather than reading anything itself — the numbers
# come from the host-facts record (docs/HOST-FACTS-SCHEMA.md), already
# published by scripts/collect-host-facts.sh from a vantage (the Docker
# socket) this container does not hold (agent-ops#603) — so this file has
# no I/O of its own and is trivial to drive from a fixture, the same way
# test/collect-host-facts-compose.test.sh drives lib/host-facts-compose.sh.
#
# ## Why summing only *known* ceilings, never guessing at an unknown one
#
# A container on a shared Docker host that sets no `mem_limit`/`--cpus` at
# all (not one of this stack's own — anything else sharing the socket) has
# no ceiling to add to the sum. Treating its absence as "unlimited, so the
# sum is infinite" would make every host with one unbounded container read
# as permanently overcommitted regardless of what this stack itself
# declares — a false alarm on every tick. Treating it as "0, so it costs
# nothing" would hide a real risk. Neither is a measurement this file
# actually has, so it does neither: an unknown ceiling is excluded from the
# sum (the same "no evidence is not evidence" reasoning `memory_verdict`
# and `disk_space_verdict` already rest on) and counted separately, so a
# reader can tell "this sum is complete" from "this sum is a lower bound".
#
# ## Why only *running* containers count
#
# An exited container's declared ceiling binds nothing right now — Docker
# does not reserve for a stopped container any more than it reserves for a
# running one, and counting it would overstate the host's actual current
# commitment for no reason a restart couldn't already explain.

# host_budget_declared_mem_bytes CONTAINERS_JSON — the sum of
# `memory.max_bytes` across every entry whose `state` is `"running"` and
# whose `memory.max_bytes` is a number, in bytes. `0` for an empty or
# malformed array — a real answer ("nothing running has a known ceiling"),
# never empty: unlike a single unreadable meter, an array with nothing
# countable in it is not "unknown", it is "zero".
host_budget_declared_mem_bytes() {
  local containers="${1:-[]}"
  jq -r '[ .[]? | select(.state == "running") | .memory.max_bytes // empty
           | select(type == "number") ] | add // 0' \
    <<<"$containers" 2>/dev/null || printf '0'
}

# host_budget_declared_mem_unknown_count CONTAINERS_JSON — how many running
# containers carry no readable `memory.max_bytes` (unset, or the collector
# could not read the cgroup) — the count the sum above silently excludes,
# so a caller can say "at least N bytes, from M containers whose own
# ceiling is unknown" rather than presenting a sum as if it were complete.
host_budget_declared_mem_unknown_count() {
  local containers="${1:-[]}"
  jq -r '[ .[]? | select(.state == "running")
           | select((.memory.max_bytes // null) | type != "number") ] | length' \
    <<<"$containers" 2>/dev/null || printf '0'
}

# host_budget_declared_cpu_nanos CONTAINERS_JSON — the sum of
# `cpu.limit_nanos` across every running entry whose limit is a number, in
# nanocpus (Docker's own unit — 1 whole CPU is 1e9). Same "0, never empty"
# contract as the memory sum above.
host_budget_declared_cpu_nanos() {
  local containers="${1:-[]}"
  jq -r '[ .[]? | select(.state == "running") | .cpu.limit_nanos // empty
           | select(type == "number") ] | add // 0' \
    <<<"$containers" 2>/dev/null || printf '0'
}

# host_budget_declared_cpu_unknown_count CONTAINERS_JSON — the CPU
# counterpart of host_budget_declared_mem_unknown_count: running containers
# with no `cpu.limit_nanos` (unset — Docker's own "no CPU limit").
host_budget_declared_cpu_unknown_count() {
  local containers="${1:-[]}"
  jq -r '[ .[]? | select(.state == "running")
           | select((.cpu.limit_nanos // null) | type != "number") ] | length' \
    <<<"$containers" 2>/dev/null || printf '0'
}

# host_budget_summary_json MEM_TOTAL_BYTES CPU_COUNT CONTAINERS_JSON — the
# whole `budget` section (docs/HOST-FACTS-SCHEMA.md): the declared sums
# above, the unknown-container counts beside them, the host's own totals
# (`null` through when the caller could not measure them), and each
# dimension's headroom (`null` when its own total is `null` — a headroom
# against an unmeasured total would be a guess). MEM_TOTAL_BYTES/CPU_COUNT
# non-numeric or empty is carried through as `null`, not coerced to 0: a
# host whose own memory or CPU count could not be read is unmeasured, not
# a host with none.
host_budget_summary_json() {
  local mem_total="${1:-}" cpu_count="${2:-}" containers="${3:-[]}" \
    mem_declared="" mem_unknown="" cpu_declared="" cpu_unknown="" cpu_total_nanos=""
  mem_declared="$(host_budget_declared_mem_bytes "$containers")"
  mem_unknown="$(host_budget_declared_mem_unknown_count "$containers")"
  cpu_declared="$(host_budget_declared_cpu_nanos "$containers")"
  cpu_unknown="$(host_budget_declared_cpu_unknown_count "$containers")"
  [[ "$cpu_count" =~ ^[0-9]+$ ]] && cpu_total_nanos=$(( cpu_count * 1000000000 ))
  jq -nc \
    --argjson mem_total "$( [[ "$mem_total" =~ ^[0-9]+$ ]] && printf '%s' "$mem_total" || printf 'null' )" \
    --argjson mem_declared "$mem_declared" \
    --argjson mem_unknown "$mem_unknown" \
    --argjson cpu_count "$( [[ "$cpu_count" =~ ^[0-9]+$ ]] && printf '%s' "$cpu_count" || printf 'null' )" \
    --argjson cpu_total_nanos "$( [[ -n "$cpu_total_nanos" ]] && printf '%s' "$cpu_total_nanos" || printf 'null' )" \
    --argjson cpu_declared "$cpu_declared" \
    --argjson cpu_unknown "$cpu_unknown" \
    '{mem_total_bytes:$mem_total, mem_declared_bytes:$mem_declared,
      mem_unknown_containers:$mem_unknown,
      mem_headroom_bytes:(if $mem_total == null then null else $mem_total - $mem_declared end),
      cpu_count:$cpu_count, cpu_declared_nanos:$cpu_declared,
      cpu_unknown_containers:$cpu_unknown,
      cpu_headroom_nanos:(if $cpu_total_nanos == null then null else $cpu_total_nanos - $cpu_declared end)}'
}

# host_budget_mem_verdict DECLARED_BYTES HOST_TOTAL_BYTES RESERVED_BYTES —
# "over" when DECLARED_BYTES plus RESERVED_BYTES (the margin an operator
# wants left for the host/VM itself, beyond the containers' own sum)
# exceeds HOST_TOTAL_BYTES; "ok" otherwise, including whenever
# HOST_TOTAL_BYTES cannot be read — an unmeasured host total is no evidence
# of an overcommitted one, the same reasoning memory_verdict's own
# unreadable-meter branch rests on.
host_budget_mem_verdict() {
  local declared="${1:-0}" host_total="${2:-}" reserved="${3:-0}"
  [[ "$declared" =~ ^[0-9]+$ ]] || declared=0
  [[ "$reserved" =~ ^[0-9]+$ ]] || reserved=0
  [[ "$host_total" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
  if (( declared + reserved > host_total )); then
    printf 'over'
  else
    printf 'ok'
  fi
}

# host_budget_cpu_verdict DECLARED_NANOS HOST_CPU_COUNT RESERVED_CPUS — the
# CPU counterpart of host_budget_mem_verdict. RESERVED_CPUS is whole-or-
# fractional cores (matching compose.yaml's own `cpus:` unit), converted to
# nanocpus for the comparison; a non-numeric RESERVED_CPUS reads as 0, same
# as an absent reservation.
host_budget_cpu_verdict() {
  local declared="${1:-0}" host_cpus="${2:-}" reserved="${3:-0}" \
    host_nanos="" reserved_nanos=0
  [[ "$declared" =~ ^[0-9]+$ ]] || declared=0
  [[ "$host_cpus" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
  host_nanos=$(( host_cpus * 1000000000 ))
  reserved_nanos="$(awk -v r="$reserved" 'BEGIN{ n = r + 0; if (n < 0) n = 0; printf "%d", n * 1000000000 }' 2>/dev/null)"
  [[ "$reserved_nanos" =~ ^[0-9]+$ ]] || reserved_nanos=0
  if (( declared + reserved_nanos > host_nanos )); then
    printf 'over'
  else
    printf 'ok'
  fi
}

# host_budget_describe SUMMARY_JSON RESERVED_MEM_BYTES RESERVED_CPUS — the
# one-line explanation both the 2.0g stand-down event and doctor.sh's own
# advisory use verbatim, so the two can never describe the same overcommit
# differently. Names both dimensions' arithmetic regardless of which one
# tripped the verdict, and the unknown-container counts, so a reader is
# never left to wonder whether the sum was complete.
host_budget_describe() {
  local summary="${1:-{\}}" reserved_mem="${2:-0}" reserved_cpus="${3:-0}" \
    mem_total="" mem_declared="" mem_unknown="" cpu_count="" cpu_declared_nanos="" cpu_unknown=""
  mem_total="$(jq -r '.mem_total_bytes // "unknown"' <<<"$summary" 2>/dev/null)"
  mem_declared="$(jq -r '.mem_declared_bytes // 0' <<<"$summary" 2>/dev/null)"
  mem_unknown="$(jq -r '.mem_unknown_containers // 0' <<<"$summary" 2>/dev/null)"
  cpu_count="$(jq -r '.cpu_count // "unknown"' <<<"$summary" 2>/dev/null)"
  cpu_declared_nanos="$(jq -r '.cpu_declared_nanos // 0' <<<"$summary" 2>/dev/null)"
  cpu_unknown="$(jq -r '.cpu_unknown_containers // 0' <<<"$summary" 2>/dev/null)"
  [[ "$mem_declared" =~ ^[0-9]+$ ]] || mem_declared=0
  [[ "$cpu_declared_nanos" =~ ^[0-9]+$ ]] || cpu_declared_nanos=0
  [[ "$reserved_mem" =~ ^[0-9]+$ ]] || reserved_mem=0
  local mem_total_mib="unknown" mem_declared_mib cpu_declared_cores reserved_mem_mib
  [[ "$mem_total" =~ ^[0-9]+$ ]] && mem_total_mib=$(( mem_total / 1048576 ))
  mem_declared_mib=$(( mem_declared / 1048576 ))
  reserved_mem_mib=$(( reserved_mem / 1048576 ))
  cpu_declared_cores="$(awk -v n="$cpu_declared_nanos" 'BEGIN{printf "%.2f", n / 1000000000}')"
  printf 'declared container memory ceilings on this host sum to %d MiB (%d container(s) with an unknown ceiling not counted) plus a %d MiB reserve, against %s MiB of host memory; declared CPU ceilings sum to %s cores (%d container(s) unknown) against %s host CPUs plus a %s core reserve' \
    "$mem_declared_mib" "$mem_unknown" "$reserved_mem_mib" "$mem_total_mib" \
    "$cpu_declared_cores" "$cpu_unknown" "$cpu_count" "$reserved_cpus"
}
