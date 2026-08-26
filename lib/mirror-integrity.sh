#!/usr/bin/env bash
#
# lib/mirror-integrity.sh — whether scripts/state-sync.sh's own mirror
# checkout is trustworthy before either push or fetch reads or writes it.
#
# The mirror (STATE_SYNC_MIRROR, default `workspace_root/.agent-ops-state`)
# is a git checkout that survives across cron ticks and container restarts,
# so a host whose disk quietly damages a loose object — an unclean shutdown
# mid-write, as happened on ockham-container from 2026-08-08 and ockham-2 on
# 2026-08-24 — hands the next tick a `.git` directory that opens fine but
# cannot answer for what it holds. `mirror_init` (scripts/state-sync.sh) used
# to trust that a directory existing was the whole check, so a corrupt
# mirror kept being read from and pushed to for four days straight, with
# `git gc` itself failing at repair the entire time and nothing in the
# automation logs saying so — the only visible symptom was an unbounded
# branch.
#
# The mirror is wholly derived, which is what makes discarding it — rather
# than repairing it — both cheap and correct: this node's own branch is
# rsync'd back out of state_dir on the very next push, and every peer branch
# is re-fetched at --depth 1 by the very next fetch. Nothing in the mirror is
# the only copy of anything, and repair (`git gc`) is exactly what was
# already failing throughout the incident above, so the answer is never
# "try to fix it" — it is "throw it away and rebuild from source".
#
# `git fsck --connectivity-only` is the check: it walks every object
# reachable from a ref and confirms it exists and parses, without reading
# every object's full content the way a plain `git fsck` does. That bound is
# the right one here — the incident's own damage sat on a *peer's*
# remote-tracking ref, which is reachable — and, measured against mirrors
# from a few thousand to several hundred thousand objects, costs well under a
# second: comfortably inside the 5-minute push / 7-minute fetch interval this
# runs on (requirement 2.5), so no stamp-file gate is needed to keep it off
# the common path.
#
# A rebuild has to be recorded somewhere that outlives the rebuild itself —
# the mirror it happened to is exactly what gets discarded — so the record
# lives under state_dir as a small local cache file
# (mirror_rebuild_state_file below), the same class of node-local
# memoisation as .image-drift-cache.json: not fleet data, so it does not
# replicate (scripts/state-sync.sh's own EXCLUDES), but read back into the
# heartbeat's `mirror` field on every push — the same channel that already
# carries the compose/image/switch verdicts (lib/compose-drift.sh,
# lib/image-drift.sh, lib/toggle.sh) — so a rebuild is as visible to a human
# or a peer as any other node fact, and a *second* rebuild is visibly a
# repeat rather than one more indistinguishable line.
#
# Sourced by scripts/state-sync.sh only: the mirror belongs to state-sync,
# unlike compose/image/switch, which other scripts (publish-dashboard.sh,
# doctor.sh) also read for this node's own status.

# mirror_rebuild_state_file STATE_DIR
# The path of the durable local record, one function so state-sync.sh's
# EXCLUDES list and the read/write sites below cannot name it differently.
mirror_rebuild_state_file() {
  printf '%s/.mirror-rebuild-state.json\n' "$1"
}

# mirror_integrity_ok MIRROR
# True (exit 0) iff every object `git fsck --connectivity-only` can reach in
# MIRROR exists and parses. False on any nonzero fsck exit — an empty loose
# object exits 2, other corruption 3, and no third outcome is worth telling
# apart from a caller that is about to discard and rebuild either way.
mirror_integrity_ok() {
  local mirror="$1"
  git -C "$mirror" fsck --connectivity-only --no-progress >/dev/null 2>&1
}

# mirror_record_rebuild STATE_DIR
# Bump the durable rebuild counter and stamp the time. Called only when a
# rebuild actually happens — never for the ordinary first-run init, which
# must stay silent (a fresh `git init` has nothing to have failed).
mirror_record_rebuild() {
  local f prev=0
  f="$(mirror_rebuild_state_file "$1")"
  if [[ -f "$f" ]]; then
    prev="$(jq -r '.count // 0' "$f" 2>/dev/null || echo 0)"
    [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
  fi
  mkdir -p "$(dirname "$f")"
  jq -nc --argjson count "$(( prev + 1 ))" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{count: $count, last_rebuilt_at: $ts}' > "$f"
}

# mirror_rebuild_verdict STATE_DIR
# The heartbeat's `mirror` field: the JSON literal `null` if this node has
# never rebuilt its mirror, else {status:"rebuilt", count, last_rebuilt_at} —
# the same shape family as compose_drift_status/image_drift_status/
# toggle_switch_summary, read back fresh on every push so a repeat rebuild
# bumps `count` rather than reading identically to the first. Never returns
# non-zero: this runs under `set -e` inside a node's heartbeat push, and no
# verdict is worth aborting one.
mirror_rebuild_verdict() {
  local f
  f="$(mirror_rebuild_state_file "$1")"
  [[ -f "$f" ]] || { printf 'null'; return 0; }
  jq -c '{status: "rebuilt", count: (.count // 1), last_rebuilt_at: (.last_rebuilt_at // "")}' "$f" 2>/dev/null \
    || printf 'null'
  return 0
}
