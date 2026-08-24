#!/usr/bin/env bash
#
# lib/workspace.sh — reclaiming `workspace_root`.
#
# Every cycle clones the repositories it touches into `workspace_root/<cycle-
# id>/` and deletes the clone in its exit trap. That trap is the whole of the
# cleanup, and a trap is exactly what a `SIGKILL` does not run: a cycle killed
# by the machine — an out-of-memory kill, a host freeze, a container recreate
# mid-stage — leaves its clone behind forever. Nothing else ever looks at
# `workspace_root` again, so the residue is invisible until the volume is full,
# and then it is the reason the volume is full (agent-ops#605).
#
# Measured on the two ockham nodes, 2026-08-24: 17 orphans, 4.2 GB, the oldest
# 32 days old. On VM1 the same day: 5 more, ~2.5 GB, the oldest 30 days.
#
# ## Why the rule is mtime and not the cycle-id convention
#
# The obvious reaper matches `workspace_root/<cycle-id>/` against the cycles it
# knows are dead. It would have missed the two largest orphans on the ockham
# nodes — `scratch-implementor/` (968 MB) and `scratch/` (101 MB) — and
# `20260803T105100Z-poetic-1-675091-scratch/` (74 MB) on VM1, because **the
# pipeline does not create those**. The stage agents do: a stage runs with its
# cwd inside the clone, is told by the repository's own `CLAUDE.md` to take a
# dedicated scratch clone rather than work in a checkout someone else may be
# editing, and picks its own name for it. That name is not the framework's to
# predict, and the next agent to invent a new one would silently defeat a
# reaper keyed on the convention.
#
# So the rule is a property instead: **anything directly under
# `workspace_root` that nothing has written to within the cycle-lock window
# cannot belong to a live cycle**. It needs no cooperation from whatever
# created the directory, and it holds for names nobody has thought of yet.
#
# The window is the one requirement 4f already derives from the stage budgets
# in force (`stage_budget_lock_seconds`, ~4 h for a cycle and ~6 h for a
# review, plus slack) — the same number `scripts/doctor.sh` reports — floored
# at 24 hours. The floor is not caution for its own sake: a review cycle and
# an implementation cycle hold separate locks and do run at once, so the
# window has to clear the longest thing that could legitimately be quiet
# beneath it. At 24 h it caught all 17 ockham orphans with no false positives,
# and the youngest was days past it.
#
# Freshness is read from the *tree*, never from the directory's own mtime: a
# clone's top-level mtime is stamped once, when git creates it, and does not
# move as a five-hour Implementer works inside. Reading it alone would reap
# the workspace of a running cycle.

# The floor, in seconds. Overridable for tests, which cannot wait a day.
WORKSPACE_REAP_FLOOR_SEC="${WORKSPACE_REAP_FLOOR_SEC:-86400}"

# workspace_reap_window DERIVED_SEC
# The reap window: the derived cycle-lock window, floored. A caller that has
# not derived one yet (or whose derivation failed) passes 0 and gets the floor.
workspace_reap_window() {
  local derived="${1:-0}"
  [[ "$derived" =~ ^[0-9]+$ ]] || derived=0
  if (( derived > WORKSPACE_REAP_FLOOR_SEC )); then
    printf '%s\n' "$derived"
  else
    printf '%s\n' "$WORKSPACE_REAP_FLOOR_SEC"
  fi
}

# workspace_orphans ROOT WINDOW_SEC NOW_EPOCH
# Print one `<bytes>\t<name>` line per orphan directly under ROOT, newest
# first is not promised and not needed — the caller reclaims all of them.
#
# Entries whose name begins with `.` are never candidates: the fleet's own
# stores live there (`.agent-ops-state`, `.agent-ops-peers` and its lock,
# lib/fleet.sh), they are bounded by their own retentions, and they are
# written to on a schedule that has nothing to do with any cycle.
workspace_orphans() {
  local root="$1" window="$2" now="$3" name path cutoff bytes
  [[ -d "$root" ]] || return 0
  cutoff=$(( now - window ))
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in .*) continue ;; esac
    path="$root/$name"
    # `-quit` on the first hit: a live workspace costs one `stat`, not a walk
    # of a gigabyte-sized clone. Only a directory that really is untouched
    # pays for the full traversal, and that one is about to be deleted anyway.
    [[ -n "$(find "$path" -newermt "@$cutoff" -print -quit 2>/dev/null)" ]] && continue
    bytes="$(du -sb "$path" 2>/dev/null | cut -f1)"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    printf '%s\t%s\n' "$bytes" "$name"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
  return 0
}

# workspace_reap ROOT WINDOW_SEC NOW_EPOCH
# Delete every orphan and print the `<bytes>\t<name>` line of each one that
# was actually removed, for the caller to record. A directory that cannot be
# removed is reported by its absence from the output rather than by a failure:
# reclaiming disk is housekeeping, and housekeeping must never be the reason a
# cycle does not run.
workspace_reap() {
  local root="$1" window="$2" now="$3" line bytes name
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    bytes="${line%%$'\t'*}"
    name="${line#*$'\t'}"
    # Belt and braces against a caller handing us `/` or an empty root: the
    # name is one path segment from `find -printf %f`, never a path, and the
    # root is confirmed non-empty here rather than trusted.
    [[ -n "$root" && -n "$name" && "$name" != "." && "$name" != ".." ]] || continue
    rm -rf -- "${root:?}/${name:?}" 2>/dev/null || continue
    [[ -e "$root/$name" ]] && continue
    printf '%s\t%s\n' "$bytes" "$name"
  done < <(workspace_orphans "$root" "$window" "$now")
  return 0
}

# workspace_reap_summary ROOT WINDOW_SEC [NOW_EPOCH]
# Reap, and print one JSON object describing what went:
#
#   {reaped, bytes, window_sec, names: [...]}
#
# The reclamation is a fact the fleet should be able to read, not a silent
# tidy-up: `bytes` is the whole point of the exercise, and `names` is what
# tells a reader *which* cycles died without cleaning up — a node reaping a
# workspace every cycle is a node being killed every cycle, which is a fault
# in its own right and one nothing else reports (this is a D14 resource
# concern as much as a correctness one, agent-ops#605).
#
# Printing rather than logging: `log_event` belongs to each cycle script and
# knows that script's `cycle_id`, `node_name` and log file. The lib does the
# work and states the outcome; the caller records it in its own voice.
workspace_reap_summary() {
  local root="$1" window="$2" now="${3:-$(date -u +%s)}" reaped
  reaped="$(workspace_reap "$root" "$window" "$now")"
  jq -nc --argjson window "$window" --arg reaped "$reaped" '
    ($reaped | split("\n") | map(select(length > 0) | split("\t"))) as $rows
    | {reaped: ($rows | length),
       bytes:  ($rows | map(.[0] | tonumber) | add // 0),
       window_sec: $window,
       names:  ($rows | map(.[1]))}' 2>/dev/null \
    || printf '{"reaped":0,"bytes":0,"window_sec":%s,"names":[]}\n' "$window"
}
