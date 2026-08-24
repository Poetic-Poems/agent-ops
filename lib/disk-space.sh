#!/usr/bin/env bash
#
# lib/disk-space.sh — free space on a directory's filesystem, read and judged
# one way everywhere: `scripts/doctor.sh`'s advisory warning and
# `agent-cycle.sh`'s pre-clone stand-down gate (requirement 2.0c, agent-ops#756)
# share this rather than each doing its own `df` arithmetic, so the two can no
# longer silently disagree about what "low" means.
#
# ## Why this exists
#
# `doctor.sh` has read `workspace_root`'s free space and warned below a fixed
# 2 GiB since before this file existed — "a cycle clones every repository it
# touches" — but that warning only ever reached a human running `doctor.sh` by
# hand. The cycle itself cloned straight into whatever room was actually left.
# On the ockham laptop that ran out, a write truncated mid-flight left
# zero-length git objects in both nodes' state mirrors, permanently disabling
# `git gc` (#604) and leaving 4.2 GB of orphaned clones behind (#605) — a
# failure a gate ahead of the clone would have refused to start into.

# disk_space_free_kb PATH
# Free space on PATH's filesystem, in KiB (`df -Pk`'s own unit), or empty if
# it cannot be read — PATH does not exist, or `df` itself fails. Never prints
# `0` for "unreadable": a caller must be able to tell "definitely short" from
# "no idea", the same distinction `github_limit_verdict`'s `unknown` already
# draws for the GitHub budget check (lib/github-limit.sh).
disk_space_free_kb() {
  local path="${1:-}" kb
  [[ -n "$path" ]] || return 0
  kb="$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 {print $4}')"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$kb"
}

# disk_space_verdict FREE_KB MIN_BYTES
# "low" when FREE_KB (KiB) is below MIN_BYTES (bytes — the config unit) once
# converted to the same one; "ok" otherwise, including when MIN_BYTES is `0`
# (the floor is off) or FREE_KB is empty/unreadable. An unreadable meter is no
# evidence of a full disk — standing down on it would invent a failure mode a
# network blip never had, the same reasoning requirement 2.0's `unknown`
# already rests on.
disk_space_verdict() {
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

# disk_space_describe PATH FREE_KB MIN_BYTES
# The one-line explanation both the stand-down event and doctor.sh's warning
# use, so the two can never describe the same shortfall differently.
disk_space_describe() {
  local path="${1:-}" free_kb="${2:-0}" min_bytes="${3:-0}" min_mib
  [[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0
  [[ "$min_bytes" =~ ^[0-9]+$ ]] || min_bytes=0
  min_mib=$(( min_bytes / 1024 / 1024 ))
  printf '%s has only %d MiB free, below the %d MiB this cycle needs — a cycle clones every repository it touches' \
    "$path" $(( free_kb / 1024 )) "$min_mib"
}
