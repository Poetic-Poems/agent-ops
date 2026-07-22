#!/usr/bin/env bash
#
# test/state-sync.test.sh — regression test for scripts/state-sync.sh under
# the multi-active fleet model (per-node branches, no lease).
#
# Four things here are worth a test rather than a careful reading:
#
#   what replicates   the exclude list is the difference between a fleet that
#                     shares its memory and one that shares its locks.
#   where it goes     each node writes its own `nodes/<NODE_NAME>` branch and
#                     never anyone else's — the property that made a lease
#                     unnecessary for state.
#   what is kept      the push bounds the node's own cycles/ and reviews/ to
#                     state_local_cycles_retained — the local record must stay
#                     longer than the mirror's, and the newest must survive.
#   what comes back   a fetch materialises every peer, whole, and prunes a
#                     peer whose branch is gone — half a peer or a ghost peer
#                     both poison the union readers.
#
# No network and no GitHub: the remote is a local bare repository
# (STATE_SYNC_REMOTE). No test framework is used (none exists elsewhere in
# this repo). Run directly:
#
#   ./test/state-sync.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$SCRIPT_DIR/scripts/state-sync.sh"

# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"

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

# --- The stand-in remote ------------------------------------------------------
remote="$tmp_dir/remote.git"
git init --quiet --bare --initial-branch=main "$remote"

# --- A node ------------------------------------------------------------------
# Each node is a HOME: config.json's state_dir and workspace_root are
# ~-relative, so a throwaway home is a throwaway node.
cycles_retained="$(jq -r '.cycles_retained' "$SCRIPT_DIR/config.json")"

new_node() {  # new_node <name> -> prints its HOME
  local home="$tmp_dir/$1"
  mkdir -p "$home/.local/state/poetic-agents/cycles" \
           "$home/.local/state/poetic-agents/reviews" \
           "$home/.cache/poetic-agents/workspaces"
  printf '%s' "$home"
}

sync_as() {  # sync_as <home> <role> <mode> [env assignments…]
  local home="$1" role="$2" mode="$3"; shift 3
  env HOME="$home" AGENT_OPS_ROLE="$role" NODE_NAME="$(basename "$home")" \
    STATE_SYNC_REMOTE="$remote" "$@" \
    "$SYNC" "$mode" 2>&1
}

# ==============================================================================
# push — each node its own branch
# ==============================================================================
active_home="$(new_node active-node)"
state="$active_home/.local/state/poetic-agents"

printf '{"ts":"2026-07-20T00:00:00Z","event":"cycle-start"}\n' > "$state/log.jsonl"
printf '{"ts":"2026-07-20T00:00:00Z","event":"review-start"}\n' > "$state/review-log.jsonl"
printf '{"reason":"testing"}\n' > "$state/disabled.json"
printf 'cron says hello\n' > "$state/cron.log"
mkdir -p "$state/cycles/20260720T010000Z-1" "$state/reviews/20260720T020000Z-1"
printf 'transcript\n' > "$state/cycles/20260720T010000Z-1/coordinator.out"
# Every directory here carries a file, because git stores no empty ones: a
# cycle that stood down before its first stage leaves an empty directory, and
# that directory does not replicate. Its log.jsonl entry does, which is what
# the union readers actually consume.
printf 'review\n' > "$state/reviews/20260720T020000Z-1/review.out"

# The things that must stay behind, one per reason in the exclude list.
printf '{"pid":999}\n' > "$state/lock.json"
printf '{"pid":998}\n' > "$state/review-lock.json"
printf 'server noise\n' > "$state/dashboard.log"
printf '{}\n' > "$state/.dashboard-github.json"
mkdir -p "$state/dashboard"
printf '<html>\n' > "$state/dashboard/index.html"

out="$(sync_as "$active_home" active push)"
assert_eq "push exits 0" "0" "$?"
assert_contains "push names the node's branch" "nodes/active-node" "$out"

pushed="$tmp_dir/pushed"
git clone --quiet --branch nodes/active-node "$remote" "$pushed"
assert_eq "the log replicates" "1" "$(test -f "$pushed/log.jsonl" && echo 1 || echo 0)"
assert_eq "the review log replicates" "1" "$(test -f "$pushed/review-log.jsonl" && echo 1 || echo 0)"
assert_eq "the switch replicates" "1" "$(test -f "$pushed/disabled.json" && echo 1 || echo 0)"
assert_eq "cycle transcripts replicate" "1" \
  "$(test -f "$pushed/cycles/20260720T010000Z-1/coordinator.out" && echo 1 || echo 0)"
assert_eq "reviews replicate" "1" "$(test -d "$pushed/reviews/20260720T020000Z-1" && echo 1 || echo 0)"
assert_eq "the cron log replicates" "1" "$(test -f "$pushed/cron.log" && echo 1 || echo 0)"

assert_eq "the lock does not replicate" "0" "$(test -e "$pushed/lock.json" && echo 1 || echo 0)"
assert_eq "the review lock does not replicate" "0" "$(test -e "$pushed/review-lock.json" && echo 1 || echo 0)"
assert_eq "the dashboard log does not replicate" "0" "$(test -e "$pushed/dashboard.log" && echo 1 || echo 0)"
assert_eq "the GitHub cache does not replicate" "0" "$(test -e "$pushed/.dashboard-github.json" && echo 1 || echo 0)"
assert_eq "the generated dashboard does not replicate" "0" "$(test -e "$pushed/dashboard" && echo 1 || echo 0)"

assert_contains "the commit names the node" "state: active-node" \
  "$(git -C "$pushed" log -1 --format=%s)"

hb="$(cat "$pushed/heartbeat.json" 2>/dev/null || echo '{}')"
assert_eq "the heartbeat names the node" "active-node" "$(jq -r '.node' <<<"$hb")"
assert_eq "the heartbeat records the role" "active" "$(jq -r '.role' <<<"$hb")"
assert_eq "the heartbeat records the newest cycle" "20260720T010000Z-1" "$(jq -r '.last_cycle' <<<"$hb")"

# --- A second push amends rather than accumulating history ---
printf '{"ts":"2026-07-20T01:00:00Z","event":"cycle-end"}\n' >> "$state/log.jsonl"
sync_as "$active_home" active push >/dev/null
assert_eq "history stays a single rolling commit" "1" \
  "$(git -C "$remote" rev-list --count nodes/active-node)"

# --- A standby pushes too (its heartbeat is the point) ---
standby_home="$(new_node standby-node)"
sb_state="$standby_home/.local/state/poetic-agents"
printf '{"ts":"2026-07-21T00:00:00Z","event":"cycle-start"}\n' > "$sb_state/log.jsonl"
out="$(sync_as "$standby_home" standby push)"
assert_eq "a standby push exits 0" "0" "$?"
assert_eq "a standby publishes its own branch" "1" \
  "$(git -C "$remote" rev-parse --verify --quiet refs/heads/nodes/standby-node >/dev/null && echo 1 || echo 0)"
assert_eq "…and never touches a peer's" "1" \
  "$(git -C "$remote" rev-list --count nodes/active-node)"

# --- Mirror retention ---
# One more cycle directory than the configured retention, so the oldest must
# fall out of the mirror while staying on the node that made it.
i=0
while (( i < cycles_retained + 1 )); do
  d="$(printf '%s/cycles/20260101T%06dZ-%d' "$state" "$i" "$i")"
  mkdir -p "$d"
  printf 'filler\n' > "$d/coordinator.out"
  i=$(( i + 1 ))
done
sync_as "$active_home" active push >/dev/null
rm -rf "$pushed"; git clone --quiet --branch nodes/active-node "$remote" "$pushed"
assert_eq "the mirror keeps cycles_retained cycles" "$cycles_retained" \
  "$(find "$pushed/cycles" -mindepth 1 -maxdepth 1 -type d | wc -l)"
assert_eq "the oldest cycle is pruned from the mirror" "0" \
  "$(test -e "$pushed/cycles/20260101T000000Z-0" && echo 1 || echo 0)"
assert_eq "the newest cycle survives the prune" "1" \
  "$(test -e "$pushed/cycles/20260720T010000Z-1" && echo 1 || echo 0)"
assert_eq "the node keeps its own history" "1" \
  "$(test -e "$state/cycles/20260101T000000Z-0" && echo 1 || echo 0)"

# --- Local retention ---
# The push also bounds the node's own state_dir (state_local_cycles_retained,
# overridden small here): newest kept, oldest deleted, reviews included — and
# the prune runs before any mirroring, so it happens on every push.
lr_home="$(new_node local-retention-node)"
lr_state="$lr_home/.local/state/poetic-agents"
printf 'log\n' > "$lr_state/log.jsonl"
i=0
while (( i < 5 )); do
  d="$(printf '%s/cycles/20260201T%06dZ-%d' "$lr_state" "$i" "$i")"
  mkdir -p "$d"; printf 'filler\n' > "$d/coordinator.out"
  r="$(printf '%s/reviews/20260201T%06dZ-%d' "$lr_state" "$i" "$i")"
  mkdir -p "$r"; printf 'filler\n' > "$r/review.out"
  i=$(( i + 1 ))
done
out="$(sync_as "$lr_home" active push STATE_SYNC_LOCAL_RETAINED=3)"
assert_contains "a push reports the local prune" "pruned 2 cycles record(s)" "$out"
assert_eq "local cycles are pruned to the cap" "3" \
  "$(find "$lr_state/cycles" -mindepth 1 -maxdepth 1 -type d | wc -l)"
assert_eq "the oldest local cycle is deleted" "0" \
  "$(test -e "$lr_state/cycles/20260201T000000Z-0" && echo 1 || echo 0)"
assert_eq "the newest local cycle survives" "1" \
  "$(test -e "$lr_state/cycles/20260201T000004Z-4" && echo 1 || echo 0)"
assert_eq "local reviews are pruned to the cap" "3" \
  "$(find "$lr_state/reviews" -mindepth 1 -maxdepth 1 -type d | wc -l)"

# A stale directory reappearing below the retention cut is pruned by the next
# push.
mkdir -p "$lr_state/cycles/20250101T000000Z-9"
printf 'stale\n' > "$lr_state/cycles/20250101T000000Z-9/coordinator.out"
out="$(sync_as "$lr_home" active push STATE_SYNC_LOCAL_RETAINED=3)"
assert_contains "a later push prunes a reappearing stale dir" "pruned 1 cycles record(s)" "$out"
assert_eq "the stale directory is gone" "0" \
  "$(test -e "$lr_state/cycles/20250101T000000Z-9" && echo 1 || echo 0)"

# ==============================================================================
# fetch — peers materialised whole, pruned when gone
# ==============================================================================
out="$(sync_as "$standby_home" standby fetch)"
assert_eq "fetch exits 0" "0" "$?"
sb_peers="$(fleet_peers_dir "$standby_home/.cache/poetic-agents/workspaces")"
assert_eq "a fetch materialises the peer's log" "1" \
  "$(test -f "$sb_peers/active-node/log.jsonl" && echo 1 || echo 0)"
assert_eq "…and the peer's heartbeat" "active-node" \
  "$(jq -r '.node' "$sb_peers/active-node/heartbeat.json" 2>/dev/null)"
assert_eq "a fetch does not include the node itself" "0" \
  "$(test -e "$sb_peers/standby-node" && echo 1 || echo 0)"
assert_eq "a fetch leaves the node's own state alone" "1" \
  "$(grep -c '2026-07-21' "$sb_state/log.jsonl")"
assert_eq "peers do not carry locks" "0" \
  "$(test -e "$sb_peers/active-node/lock.json" && echo 1 || echo 0)"

# The other direction: the active node holds the standby.
sync_as "$active_home" active fetch >/dev/null
a_peers="$(fleet_peers_dir "$active_home/.cache/poetic-agents/workspaces")"
assert_eq "the active node holds its peers too" "1" \
  "$(test -f "$a_peers/standby-node/log.jsonl" && echo 1 || echo 0)"

# A deleted branch is a decommissioned node: its peer copy goes on the next
# fetch.
git -C "$remote" update-ref -d refs/heads/nodes/local-retention-node
sync_as "$standby_home" standby fetch >/dev/null
assert_eq "a vanished branch prunes its peer copy" "0" \
  "$(test -e "$sb_peers/local-retention-node" && echo 1 || echo 0)"

# ==============================================================================
# the union read (lib/fleet.sh)
# ==============================================================================
union="$(fleet_logs "$sb_state" "$sb_peers" log.jsonl)"
assert_contains "the union carries the node's own events" '2026-07-21' "$union"
assert_contains "the union carries the peer's events" '2026-07-20' "$union"
assert_eq "the union is time-ordered" "1" \
  "$([[ "$(printf '%s\n' "$union" | head -1)" == *2026-07-20T00:00:00Z* ]] && echo 1 || echo 0)"

# ==============================================================================
# node identity in pipeline events (requirement 33, offline path)
# ==============================================================================
# The management switch logs through the same log_event as every pipeline
# event, with no model call and no GitHub write — the cheapest offline proof
# that events carry the node's name.
cycle_home="$(new_node cycle-node)"
env HOME="$cycle_home" AGENT_OPS_ROLE=standby NODE_NAME=cycle-node \
  STATE_SYNC_REMOTE="$remote" \
  "$SCRIPT_DIR/agent-cycle.sh" --disable "state-sync test" >/dev/null 2>&1
assert_contains "switch events carry the node's name" '"node":"cycle-node"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"
env HOME="$cycle_home" AGENT_OPS_ROLE=standby NODE_NAME=cycle-node \
  STATE_SYNC_REMOTE="$remote" \
  "$SCRIPT_DIR/agent-cycle.sh" --enable >/dev/null 2>&1
assert_contains "the enable is logged too" '"event":"enabled"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
