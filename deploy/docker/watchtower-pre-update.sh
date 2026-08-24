#!/usr/bin/env bash
#
# deploy/docker/watchtower-pre-update.sh — make an image roll wait for the
# cycle it would otherwise kill.
#
# Updating a container means destroying it and creating a new one, and
# destroying the scheduler kills the process group its cycle runs in: an
# Implementer dies mid-edit, its clone is orphaned under `workspace_root`, and
# any branch or draft pull request it had already pushed is left behind. The
# pipeline itself heals — the lock is taken over as stale on a later tick and
# the claim GC releases what the dead cycle held — but nothing cleans up that
# debris, and the half-finished work is simply lost.
#
# So the roll waits instead. watchtower runs this script *inside* the container
# it is about to update (`docker exec`, via `sh -c`) and reads its exit status:
#
#   exit 75  (EX_TEMPFAIL) — cancel this container's update; try again on the
#            next poll. Nothing is lost: the newer image is still in the
#            registry and the next poll finds it.
#   exit 0   — nothing is running here; roll away.
#
# "Running" is deliberately the *same* judgement `acquire_lock` makes in
# agent-cycle.sh and review-cycle.sh: a lock file naming a live pid, younger
# than that pipeline's `lock_stale_after`. Taking only "live pid" would let one
# wedged process veto every update for as long as it survived; bounding it by
# the same staleness the next cycle uses means the hook can never defer past
# the point where a cycle would have taken the lock over anyway.
#
# That bounds **one** deferral, and only one. It does not bound the sequence.
# Each poll is answered independently, so a node whose next cycle starts
# before watchtower's next poll is never *asked* at a moment when the lock is
# free: every individual refusal is correct, every one is well inside
# `lock_stale_after`, and the node still never rolls. Nothing here is wedged
# and nothing self-corrects.
#
# Measured on VM1, 2026-08-24: `Failed=3 Scanned=3 Updated=0` every five
# minutes for hours. One of the two nodes sharing that host happened to be
# polled during a gap between cycles and rolled; its neighbour kept missing
# the gap and stayed on an image ninety minutes older, with nothing anywhere
# saying so. This earlier read the other way — "the worst case is therefore
# `lock_stale_after` hours of deferral, not 'until somebody notices this node
# stopped updating'" — which holds for the *wedged* cycle it was written
# about and not for a merely busy one. Reporting the repeated `Failed` is
# agent-ops#603; this comment's job is only to stop the bound being read as
# wider than it is.
#
# Both pipelines count. agent-cycle.sh holds `lock.json` and review-cycle.sh
# holds `review-lock.json`, and either dying to a roll costs the same.
#
# One thing acquire_lock never has to think about: *which container* wrote the
# lock. This script must — watchtower runs it in every container carrying the
# label, and on a tailnet node the dashboard shares the scheduler's state
# volume, so it reads the scheduler's locks. A pid is only meaningful inside
# the PID namespace that minted it, and `kill -0` from any other container
# answers a question about the wrong process. That is not theoretical: on
# 2026-07-28 the dashboard read the scheduler's live lock, found pid 55423
# dead in its own namespace, exited 0 — and that put the image the two share
# into watchtower's restart map, which is keyed by image id, so watchtower
# tried to recreate the very scheduler it had just agreed to defer. Only the
# name conflict with the never-stopped container saved the cycle (#130).
#
# So the lock records the hostname of the container that wrote it, and the
# rule here is:
#
#   - our own lock ($HOSTNAME matches): judge liveness with `kill -0`, exactly
#     as acquire_lock would;
#   - anyone else's (the host differs, or an old lock carries no host): the
#     pid is unanswerable from here, so honour the lock — fail *closed*,
#     bounded by the same staleness as everything else. The asymmetry is
#     priced: honouring a lock whose process is actually gone defers this
#     container's roll until the next cycle takes the leftover lock over (the
#     lock is acquired before the stand-down checks, so every node clears it
#     within the hour; `lock_stale_after` bounds even a node whose cron is
#     dead), while trusting a foreign `kill -0` kills live cycles — and pid
#     collisions make it wrong in both directions, since an unrelated local
#     process at the same number would defer for a cycle that ended hours ago.
#
# The judgement is reimplemented here rather than sourced from lib/toggle.sh on
# purpose: this is the one script in the tree that runs from outside the
# pipeline, on a container that is about to be destroyed, and its answer must
# not depend on anything more than bash, jq and config.json.
#
# Requires `WATCHTOWER_LIFECYCLE_HOOKS=true` on the watchtower service and the
# `com.centurylinklabs.watchtower.lifecycle.pre-update` label on each container
# to be protected — both in deploy/docker/compose.yaml.
#
# Usage: watchtower-pre-update.sh [CONFIG_FILE]   (the argument is for tests;
# watchtower invokes it bare and it defaults to /app/config.json).

set -uo pipefail

# Everything goes to stdout: it is the exec stream watchtower logs, and it is
# the only trace a deferral leaves. `docker compose logs watchtower` is where
# an operator wondering why a node has not taken the new image should look.
say() { printf 'watchtower-pre-update: %s\n' "$*"; }

# sysexits.h. 75 is the *only* status that defers: watchtower's ExecuteCommand
# returns `SkipUpdate = true` for it alone, and for every other non-zero status
# returns `SkipUpdate = false` with an error — "an exit code different than 0 or
# 75 (EX_TEMPFAIL) will not prevent watchtower from updating the container", as
# its documentation puts it. So a hook that fails does not hold the roll back;
# it is logged and ignored, and the cycle dies exactly as if there were no hook.
#
# Which is why the fail-open branches below still exit 0 rather than erroring:
# not because a non-zero status would freeze the node's image — it would not —
# but because 0 says "I checked, there is nothing to protect" in the one
# vocabulary watchtower acts on, and an error log that changes no behaviour is
# a worse way to say the same thing.
EX_TEMPFAIL=75

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.json}"

# Fail open, loudly. Both of these are baked into the image, so neither can
# realistically be missing — but if one somehow is, a node that stops updating
# for ever is a worse and far quieter failure than a roll that lands badly
# once, and watchtower's own behaviour on a hook it cannot run is the same.
if ! command -v jq >/dev/null 2>&1; then
  say "WARNING: jq is not on PATH — cannot read the locks, so allowing the update"
  exit 0
fi
if [[ ! -r "$CONFIG_FILE" ]]; then
  say "WARNING: cannot read $CONFIG_FILE — cannot locate the locks, so allowing the update"
  exit 0
fi

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

state_dir="$(expand_home "$(jq -r '.state_dir // "~/.local/state/poetic-agents"' "$CONFIG_FILE")")"

cycle_stale_after="$(jq -r '.lock_stale_after // 4' "$CONFIG_FILE")"
review_stale_after="$(jq -r '.project_review.lock_stale_after // 6' "$CONFIG_FILE")"
[[ "$cycle_stale_after"  =~ ^[0-9]+$ ]] || cycle_stale_after=4
[[ "$review_stale_after" =~ ^[0-9]+$ ]] || review_stale_after=6

# held_by LOCK_FILE STALE_AFTER_HOURS
# Print a one-line description if LOCK_FILE is a lock this container must
# respect; print nothing otherwise. Always succeeds.
#
# An unparseable `started_at` reads as epoch 0 and so as impossibly old, which
# is exactly what acquire_lock does with it: a lock whose age cannot be
# established is one the next cycle would take over, and this hook must not
# protect what the pipeline itself would not.
#
# Staleness is judged before liveness because it applies to every lock, while
# `kill -0` is meaningful only for a lock this container's own pipeline wrote
# — the `host` comparison decides which kind this is (see the header). The
# comparison deliberately treats an empty `host` on either side as foreign:
# a lock that cannot prove it is ours is one whose pid we must not trust.
held_by() {
  local f="$1" stale_after_hours="$2" pid started_at host started_epoch now_epoch age_sec
  [[ -f "$f" ]] || return 0
  pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
  started_at="$(jq -r '.started_at // empty' "$f" 2>/dev/null || true)"
  host="$(jq -r '.host // empty' "$f" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  started_epoch="$(date -d "$started_at" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  age_sec=$(( now_epoch - started_epoch ))
  (( age_sec < stale_after_hours * 3600 )) || return 0
  if [[ -n "$host" && "$host" == "${HOSTNAME:-}" ]]; then
    kill -0 "$pid" 2>/dev/null || return 0
    printf 'pid %s since %s, %ss old' "$pid" "${started_at:-unknown}" "$age_sec"
  else
    printf 'written by container %s since %s, %ss old — a foreign pid cannot be liveness-checked, so the lock is honoured until released or stale' \
      "${host:-unknown}" "${started_at:-unknown}" "$age_sec"
  fi
}

defer=0

held="$(held_by "$state_dir/lock.json" "$cycle_stale_after")"
if [[ -n "$held" ]]; then
  say "an implementation cycle is in flight ($held) — deferring this update"
  defer=1
fi

held="$(held_by "$state_dir/review-lock.json" "$review_stale_after")"
if [[ -n "$held" ]]; then
  say "a project review is in flight ($held) — deferring this update"
  defer=1
fi

if (( defer )); then
  say "exit $EX_TEMPFAIL: watchtower will re-check on its next poll"
  exit "$EX_TEMPFAIL"
fi

say "no cycle in flight — the update may proceed"
exit 0
