#!/usr/bin/env bash
#
# test/state-sync.test.sh — regression test for scripts/state-sync.sh and the
# lease check in agent-cycle.sh.
#
# Three things here are worth a test rather than a careful reading:
#
#   what replicates   the exclude list is the difference between a warm spare
#                     and a node that stands itself down forever on a restored
#                     lock nobody holds.
#   what does not     a push that finds no change must not force-push, or the
#                     state repository churns once an hour for no reason.
#   what is kept      the push bounds the node's own cycles/ and reviews/ to
#                     state_local_cycles_retained — the local record must stay
#                     longer than the mirror's, and the newest must survive.
#   who may run       a fresh lease belonging to another node must stop a cycle
#                     before it spends anything.
#
# No network and no GitHub: the remote is a local bare repository
# (STATE_SYNC_REMOTE) and `gh` is a stub that answers the contents API from
# environment variables. No test framework is used (none exists elsewhere in
# this repo). Run directly:
#
#   ./test/state-sync.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC="$SCRIPT_DIR/scripts/state-sync.sh"

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
    STATE_SYNC_REMOTE="$remote" PATH="$stub_bin:$PATH" "$@" \
    "$SYNC" "$mode" 2>&1
}

# --- A stub gh ----------------------------------------------------------------
# Answers `gh api repos/…/contents/leader.json` from GH_STUB_LEASE (empty means
# 404 — no lease yet) and records every write to GH_STUB_LOG, so a test can ask
# both "did it stand down?" and "did it claim the lease?".
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/bin/sh
case "$*" in
  *contents/leader.json*)
    case "$*" in
      *"-X PUT"*)
        printf '%s\n' "$*" >> "${GH_STUB_LOG:-/dev/null}"
        exit "${GH_STUB_PUT_RC:-0}"
        ;;
    esac
    [ -n "${GH_STUB_LEASE:-}" ] || exit 1
    printf '{"sha":"stub-sha","encoding":"base64","content":"%s"}\n' \
      "$(printf '%s' "$GH_STUB_LEASE" | base64 -w0)"
    exit 0
    ;;
esac
exit 1
STUB
chmod +x "$stub_bin/gh"

# ==============================================================================
# push
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
# the dashboard and the no-op short-circuit actually read.
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

pushed="$tmp_dir/pushed"
git clone --quiet "$remote" "$pushed"
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

# --- A push with nothing new must not force-push ---
before="$(git -C "$remote" rev-parse main)"
out="$(sync_as "$active_home" active push)"
assert_contains "an unchanged push says so" "no state change" "$out"
assert_eq "an unchanged push leaves the remote alone" "$before" "$(git -C "$remote" rev-parse main)"

# --- A changed push amends rather than accumulating history ---
printf '{"ts":"2026-07-20T01:00:00Z","event":"cycle-end"}\n' >> "$state/log.jsonl"
sync_as "$active_home" active push >/dev/null
assert_eq "a changed push moves the remote" "1" \
  "$([[ "$(git -C "$remote" rev-parse main)" != "$before" ]] && echo 1 || echo 0)"
assert_eq "history stays a single rolling commit" "1" \
  "$(git -C "$remote" rev-list --count main)"

# --- Retention ---
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
rm -rf "$pushed"; git clone --quiet "$remote" "$pushed"
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
# a push with nothing to replicate still prunes, because the prune runs before
# the no-change early-return.
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
# push even when the mirror has nothing new to take.
mkdir -p "$lr_state/cycles/20250101T000000Z-9"
printf 'stale\n' > "$lr_state/cycles/20250101T000000Z-9/coordinator.out"
out="$(sync_as "$lr_home" active push STATE_SYNC_LOCAL_RETAINED=3)"
assert_contains "a no-change push still prunes" "pruned 1 cycles record(s)" "$out"
assert_contains "and does not force-push" "no state change" "$out"
assert_eq "the stale directory is gone" "0" \
  "$(test -e "$lr_state/cycles/20250101T000000Z-9" && echo 1 || echo 0)"

# --- The lease survives the mirroring ---
# leader.json lives in the state repository but in no node's state_dir, so a
# push that mirrored blindly would delete the record of who is running — and
# every node would then find the operation unclaimed.
lease_seed="$tmp_dir/lease-seed"
git clone --quiet "$remote" "$lease_seed"
printf '{"node":"active-node","updated":"2026-07-20T00:00:00Z"}\n' > "$lease_seed/leader.json"
git -C "$lease_seed" add leader.json
git -C "$lease_seed" -c user.name=t -c user.email=t@t commit --quiet -m "lease"
git -C "$lease_seed" push --quiet origin HEAD:main
printf 'more log\n' >> "$state/log.jsonl"
sync_as "$active_home" active push >/dev/null
rm -rf "$pushed"; git clone --quiet "$remote" "$pushed"
assert_eq "a push does not delete the lease" "1" \
  "$(test -f "$pushed/leader.json" && echo 1 || echo 0)"

# --- A standby node must not push ---
standby_home="$(new_node standby-node)"
sb_state="$standby_home/.local/state/poetic-agents"
printf 'this must never reach the remote\n' > "$sb_state/log.jsonl"
head="$(git -C "$remote" rev-parse main)"
out="$(sync_as "$standby_home" standby push)"
assert_eq "a standby push is a silent no-op" "" "$out"
assert_eq "a standby push leaves the remote alone" "$head" "$(git -C "$remote" rev-parse main)"

# ==============================================================================
# restore
# ==============================================================================
# The standby's own local-only files, which a restore must leave alone.
printf '{"pid":123}\n' > "$sb_state/lock.json"
printf 'my own dashboard log\n' > "$sb_state/dashboard.log"
mkdir -p "$sb_state/dashboard"
printf '<html>mine\n' > "$sb_state/dashboard/index.html"

out="$(sync_as "$standby_home" standby restore)"
assert_contains "restore reports what it took" "restored" "$out"
assert_eq "the active node's log arrives" "1" \
  "$(grep -c 'cycle-start' "$sb_state/log.jsonl" 2>/dev/null || true)"
assert_eq "cycle transcripts arrive" "1" \
  "$(test -f "$sb_state/cycles/20260720T010000Z-1/coordinator.out" && echo 1 || echo 0)"
assert_eq "the standby's own lock is untouched" "1" \
  "$(test -f "$sb_state/lock.json" && echo 1 || echo 0)"
assert_eq "the standby's own dashboard log is untouched" "1" \
  "$(test -f "$sb_state/dashboard.log" && echo 1 || echo 0)"
assert_eq "the standby's own dashboard is untouched" "<html>mine" \
  "$(cat "$sb_state/dashboard/index.html")"

assert_eq "the lease is not restored into state_dir" "0" \
  "$(test -e "$sb_state/leader.json" && echo 1 || echo 0)"

out="$(sync_as "$standby_home" standby restore)"
assert_eq "a restore with nothing new is silent" "" "$out"

out="$(sync_as "$active_home" active restore)"
assert_eq "restore on the active node is a silent no-op" "" "$out"
assert_eq "restore did not overwrite the active node's state" "1" \
  "$(test -f "$state/lock.json" && echo 1 || echo 0)"

# A cycle pruned upstream goes from the mirror too — a mirror, not a merge.
assert_eq "the standby does not receive pruned cycles" "0" \
  "$(test -e "$sb_state/cycles/20260101T000000Z-0" && echo 1 || echo 0)"

# ==============================================================================
# lease
# ==============================================================================
lease_log="$tmp_dir/gh-writes.log"

lease_as() {  # lease_as <home> <role> <lease json|-> ; prints output, sets rc
  local home="$1" role="$2" lease="$3"
  [[ "$lease" == "-" ]] && lease=""
  env HOME="$home" AGENT_OPS_ROLE="$role" NODE_NAME="$(basename "$home")" \
    STATE_SYNC_REMOTE="$remote" STATE_SYNC_GH="$stub_bin/gh" \
    GH_STUB_LEASE="$lease" GH_STUB_LOG="$lease_log" \
    "$SYNC" lease 2>&1
}

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
long_ago="$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)"

: > "$lease_log"
out="$(lease_as "$active_home" active -)"; rc=$?
assert_eq "an unclaimed lease is taken" "0" "$rc"
assert_eq "taking an unclaimed lease writes it" "1" "$(grep -c 'PUT' "$lease_log")"

: > "$lease_log"
out="$(lease_as "$active_home" active "{\"node\":\"active-node\",\"updated\":\"$now\"}")"; rc=$?
assert_eq "our own lease refreshes" "0" "$rc"
assert_eq "refreshing writes it" "1" "$(grep -c 'PUT' "$lease_log")"

: > "$lease_log"
out="$(lease_as "$active_home" active "{\"node\":\"other-node\",\"updated\":\"$now\"}")"; rc=$?
assert_eq "a fresh foreign lease stands this node down" "3" "$rc"
assert_contains "and says whose it is" "other-node holds the lease" "$out"
assert_eq "and writes nothing" "0" "$(grep -c 'PUT' "$lease_log")"

: > "$lease_log"
out="$(lease_as "$active_home" active "{\"node\":\"other-node\",\"updated\":\"$long_ago\"}")"; rc=$?
assert_eq "an expired foreign lease is taken over" "0" "$rc"
assert_contains "and says so" "taking the lease from other-node" "$out"
assert_eq "and is written" "1" "$(grep -c 'PUT' "$lease_log")"

out="$(lease_as "$standby_home" standby -)"; rc=$?
assert_eq "a standby node takes no lease" "0" "$rc"
assert_eq "and says nothing about it" "" "$out"

# GitHub unreachable: the stub's PUT fails and there is no existing holder.
# Failing open is deliberate (see the comment in do_lease) — an operation that
# stops because one request failed is worse than one that risks a duplicate it
# needs a second active node to produce.
out="$(env GH_STUB_PUT_RC=1 HOME="$active_home" AGENT_OPS_ROLE=active NODE_NAME=active-node \
  STATE_SYNC_REMOTE="$remote" STATE_SYNC_GH="$stub_bin/gh" \
  GH_STUB_LEASE="" GH_STUB_LOG="$lease_log" \
  "$SYNC" lease 2>&1)"; rc=$?
assert_eq "an unwritable lease fails open" "0" "$rc"
assert_contains "and warns" "could not write the lease" "$out"

# ==============================================================================
# The lease as agent-cycle.sh sees it
# ==============================================================================
# The end-to-end case the requirement is really about: a fresh foreign lease
# must stop a cycle before it selects anything, and it must be recorded as a
# stand-down rather than a failure.
cycle_home="$(new_node cycle-node)"
mkdir -p "$cycle_home/.local/bin"
printf '#!/bin/sh\necho "claude stub: the lease should have prevented this" >&2\nexit 1\n' \
  > "$cycle_home/.local/bin/claude"
chmod +x "$cycle_home/.local/bin/claude"

out="$(env HOME="$cycle_home" AGENT_OPS_ROLE=active NODE_NAME=cycle-node \
  STATE_SYNC_REMOTE="$remote" STATE_SYNC_GH="$stub_bin/gh" PATH="$cycle_home/.local/bin:$PATH" \
  GH_STUB_LEASE="{\"node\":\"other-node\",\"updated\":\"$now\"}" GH_STUB_LOG="$lease_log" \
  "$SCRIPT_DIR/agent-cycle.sh" 2>&1)"; rc=$?
assert_eq "a cycle without the lease exits 0" "0" "$rc"
assert_contains "a cycle without the lease says whose it is" "other-node holds the lease" "$out"
assert_contains "a cycle without the lease records a stand-down" \
  '"reason":"the lease is held by another node"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"
assert_contains "cycle events carry the node's name" '"node":"cycle-node"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"
assert_eq "the cycle id carries the node with the pid last" "1" \
  "$(jq -r 'select(.event=="cycle-start") | .cycle' \
       "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null \
     | grep -qE -- '-cycle-node-[0-9]+$' && echo 1 || echo 0)"
assert_eq "a cycle without the lease selects nothing" "0" \
  "$(grep -c 'coordinator' "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null || true)"

# The review pipeline takes the same lease, and must stand down on it the same
# way — checked here rather than inferred from agent-cycle.sh passing, because
# a shared mechanism wired into only one caller looks exactly like a working
# one until the other runs.
out="$(env HOME="$cycle_home" AGENT_OPS_ROLE=active NODE_NAME=cycle-node \
  STATE_SYNC_REMOTE="$remote" STATE_SYNC_GH="$stub_bin/gh" PATH="$cycle_home/.local/bin:$PATH" \
  GH_STUB_LEASE="{\"node\":\"other-node\",\"updated\":\"$now\"}" GH_STUB_LOG="$lease_log" \
  "$SCRIPT_DIR/review-cycle.sh" 2>&1)"; rc=$?
assert_eq "a review without the lease exits 0" "0" "$rc"
assert_contains "a review without the lease records a stand-down" \
  '"reason":"the lease is held by another node"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null)"
assert_contains "review events carry the node's name" '"node":"cycle-node"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null)"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
