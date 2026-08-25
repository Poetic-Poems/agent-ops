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
printf '{"ts":"2026-08-21T02:00:00Z","node":"active-node","event":"revert-rate","repo":"o/r"}\n' > "$state/revert-rate.jsonl"
printf '{"reason":"testing"}\n' > "$state/disabled.json"
printf 'cron says hello\n' > "$state/cron.log"
mkdir -p "$state/cycles/20260720T010000Z-1" "$state/reviews/20260720T020000Z-1"
printf 'transcript\n' > "$state/cycles/20260720T010000Z-1/coordinator.out"
# The stage event stream beside it (requirement 4d). It is the one thing in a
# cycle directory that must not replicate: `.out` is one JSON object, a stream
# is every message and every tool result, and the branch is a rolling commit
# holding `cycles_retained` of them.
printf '{"type":"system"}\n' > "$state/cycles/20260720T010000Z-1/coordinator.stream.jsonl"
printf '{"type":"system"}\n' > "$state/reviews/20260720T020000Z-1/reviewer.stream.jsonl"
# The fleet-log snapshot beside them (agent-ops#763). Same class and a sharper
# case of it: the union of every node's log.jsonl as this cycle saw it, so
# publishing it would send a peer a derivative of the logs it is already being
# sent — one copy per retained cycle, each the whole fleet's history to that
# point.
printf '{"type":"union"}\n' > "$state/cycles/20260720T010000Z-1/.fleet-log.jsonl"
printf '{"type":"union"}\n' > "$state/reviews/20260720T020000Z-1/.fleet-log.jsonl"
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
printf '{"ok":false}\n' > "$state/.image-drift-cache.json"
# The hourly unattended doctor pass's own artefacts (agent-ops#543): local to
# this node, like the caches above, so neither should replicate.
printf 'doctor noise\n' > "$state/doctor.log"
printf '{"verdict":"ok"}\n' > "$state/.doctor-status.json"
# The daily revert-rate publishing pass's own text output (agent-ops#579):
# local to this node, like doctor.log above — its structured sibling,
# revert-rate.jsonl (set up above, beside log.jsonl), is fleet-wide data and
# must replicate instead.
printf 'revert-rate noise\n' > "$state/revert-rate.log"
mkdir -p "$state/dashboard"
printf '<html>\n' > "$state/dashboard/index.html"

out="$(sync_as "$active_home" active push)"
assert_eq "push exits 0" "0" "$?"
assert_contains "push names the node's branch" "nodes/active-node" "$out"

pushed="$tmp_dir/pushed"
git clone --quiet --branch nodes/active-node "$remote" "$pushed"
assert_eq "the log replicates" "1" "$(test -f "$pushed/log.jsonl" && echo 1 || echo 0)"
assert_eq "the review log replicates" "1" "$(test -f "$pushed/review-log.jsonl" && echo 1 || echo 0)"
assert_eq "the revert-rate log replicates" "1" "$(test -f "$pushed/revert-rate.jsonl" && echo 1 || echo 0)"
assert_eq "the switch replicates" "1" "$(test -f "$pushed/disabled.json" && echo 1 || echo 0)"
assert_eq "cycle transcripts replicate" "1" \
  "$(test -f "$pushed/cycles/20260720T010000Z-1/coordinator.out" && echo 1 || echo 0)"
assert_eq "reviews replicate" "1" "$(test -d "$pushed/reviews/20260720T020000Z-1" && echo 1 || echo 0)"
assert_eq "the cron log replicates" "1" "$(test -f "$pushed/cron.log" && echo 1 || echo 0)"

assert_eq "the lock does not replicate" "0" "$(test -e "$pushed/lock.json" && echo 1 || echo 0)"
assert_eq "the review lock does not replicate" "0" "$(test -e "$pushed/review-lock.json" && echo 1 || echo 0)"
assert_eq "the dashboard log does not replicate" "0" "$(test -e "$pushed/dashboard.log" && echo 1 || echo 0)"
assert_eq "the GitHub cache does not replicate" "0" "$(test -e "$pushed/.dashboard-github.json" && echo 1 || echo 0)"
assert_eq "the image-drift cache does not replicate" "0" "$(test -e "$pushed/.image-drift-cache.json" && echo 1 || echo 0)"
assert_eq "the doctor log does not replicate" "0" "$(test -e "$pushed/doctor.log" && echo 1 || echo 0)"
assert_eq "the doctor status cache does not replicate" "0" "$(test -e "$pushed/.doctor-status.json" && echo 1 || echo 0)"
assert_eq "the revert-rate publish log does not replicate" "0" "$(test -e "$pushed/revert-rate.log" && echo 1 || echo 0)"
assert_eq "the generated dashboard does not replicate" "0" "$(test -e "$pushed/dashboard" && echo 1 || echo 0)"
# Both transfers are covered: the cycle directories go through their own rsync
# with its own filter, so an exclusion that held only for the general transfer
# would let every cycle's stream through anyway.
assert_eq "a cycle's stage stream does not replicate" "0" \
  "$(test -e "$pushed/cycles/20260720T010000Z-1/coordinator.stream.jsonl" && echo 1 || echo 0)"
assert_eq "nor does a review's" "0" \
  "$(test -e "$pushed/reviews/20260720T020000Z-1/reviewer.stream.jsonl" && echo 1 || echo 0)"
assert_eq "a cycle's fleet-log snapshot does not replicate" "0" \
  "$(test -e "$pushed/cycles/20260720T010000Z-1/.fleet-log.jsonl" && echo 1 || echo 0)"
assert_eq "nor does a review's" "0" \
  "$(test -e "$pushed/reviews/20260720T020000Z-1/.fleet-log.jsonl" && echo 1 || echo 0)"
# The record itself is untouched by either exclusion — what a peer reads of a
# cycle is still there.
assert_eq "the record survives both exclusions" "1" \
  "$(test -f "$pushed/cycles/20260720T010000Z-1/coordinator.out" && echo 1 || echo 0)"

assert_contains "the commit names the node" "state: active-node" \
  "$(git -C "$pushed" log -1 --format=%s)"

hb="$(cat "$pushed/heartbeat.json" 2>/dev/null || echo '{}')"
assert_eq "the heartbeat names the node" "active-node" "$(jq -r '.node' <<<"$hb")"
assert_eq "the heartbeat records the role" "active" "$(jq -r '.role' <<<"$hb")"
assert_eq "the heartbeat records the newest cycle" "20260720T010000Z-1" "$(jq -r '.last_cycle' <<<"$hb")"

# --- The heartbeat carries the node-scoped switch (issue #379) ---------------
# The node's own state_dir/disabled.json above ({"reason":"testing"}, no
# other fields) is exactly the switch this node's cycles gate on, so the same
# read (lib/toggle.sh's toggle_switch_summary) that feeds `--status` and the
# dashboard's page-top banner feeds the heartbeat's `switch` field too — one
# implementation, so a peer's card cannot disagree with what that node itself
# would report (requirement 34a).
assert_eq "the heartbeat reports the node's own switch as disabled" "true" \
  "$(jq -r '.switch.disabled' <<<"$hb")"
assert_eq "carrying the reason from disabled.json" "testing" \
  "$(jq -r '.switch.reason' <<<"$hb")"

# --- The heartbeat carries an image-drift verdict slot (#155) -----------------
# lib/image-drift.sh's own suite (test/image-drift.test.sh) covers what the
# verdict says; what belongs here is only that state-sync.sh asks for one at
# all. This suite runs from a plain checkout (source "checkout", not "image"
# — SCRIPT_DIR names this repository's own working tree, which ships no
# build-info.json), so the verdict is null by lib/image-drift.sh's own rule
# for a node not running a CI-stamped image — the key existing, not its
# value, is the wiring this asserts.
assert_eq "the heartbeat carries an image-drift slot" "true" "$(jq 'has("image")' <<<"$hb")"

# --- The heartbeat carries the compose-drift verdict (#131) -------------------
# End to end: a node whose compose.yaml has drifted publishes that fact with
# its next push. The check's paths are forced to fixtures, because this suite
# runs both on developer hosts and inside the CI image, and the defaults
# would answer for whichever environment it happens to be in.
drift_image="$tmp_dir/drift-image.yaml"
drift_host="$tmp_dir/drift-host.yaml"
printf 'services:\n  scheduler:\n    image: ghcr.io/example/agent-ops:latest\n' > "$drift_image"
printf 'services:\n  scheduler:\n    image: ghcr.io/example/agent-ops:pinned\n' > "$drift_host"
sync_as "$active_home" active push \
  COMPOSE_DRIFT_HOST="$drift_host" COMPOSE_DRIFT_IMAGE="$drift_image" >/dev/null
assert_eq "the drift-carrying push exits 0" "0" "$?"
drift_pushed="$tmp_dir/pushed-drift"
git clone --quiet --branch nodes/active-node "$remote" "$drift_pushed"
assert_eq "a drifted compose.yaml is published in the heartbeat" "drifted" \
  "$(jq -r '.compose.status' "$drift_pushed/heartbeat.json" 2>/dev/null)"
assert_eq "with the count of differing lines" "2" \
  "$(jq -r '.compose.diff_lines' "$drift_pushed/heartbeat.json" 2>/dev/null)"

# --- A second push amends rather than accumulating history ---
printf '{"ts":"2026-07-20T01:00:00Z","event":"cycle-end"}\n' >> "$state/log.jsonl"
sync_as "$active_home" active push >/dev/null
assert_eq "the amending push exits 0" "0" "$?"
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
assert_eq "the retention push exits 0" "0" "$?"
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
assert_eq "the local-retention push exits 0" "0" "$?"
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
assert_eq "the reappearing-stale-dir push exits 0" "0" "$?"
assert_contains "a later push prunes a reappearing stale dir" "pruned 1 cycles record(s)" "$out"
assert_eq "the stale directory is gone" "0" \
  "$(test -e "$lr_state/cycles/20250101T000000Z-9" && echo 1 || echo 0)"

# --- Local retention of the derived files -------------------------------------
# A second, much tighter bound (state_local_streams_retained), on the derived
# files alone: they are megabytes where the records holding them are kilobytes,
# so they go early and the records stay. What this asserts is precisely that
# separation — the record survives them.
#
# Both files in the class are exercised, not just the stream: `.fleet-log.jsonl`
# was absent from this prune until agent-ops#763 and so fell through to the
# record retention, a thousand deep, which is the whole of the bug.
sr_home="$(new_node stream-retention-node)"
sr_state="$sr_home/.local/state/poetic-agents"
# A real event rather than filler: this node's branch survives to the union
# read below, and a line with no `ts` would sort ahead of every dated one.
printf '{"ts":"2026-07-22T00:00:00Z","event":"cycle-start"}\n' > "$sr_state/log.jsonl"
i=0
while (( i < 4 )); do
  d="$(printf '%s/cycles/20260301T%06dZ-%d' "$sr_state" "$i" "$i")"
  mkdir -p "$d"
  printf 'filler\n' > "$d/coordinator.out"
  printf '{"type":"system"}\n' > "$d/coordinator.stream.jsonl"
  printf '{"type":"union"}\n' > "$d/.fleet-log.jsonl"
  r="$(printf '%s/reviews/20260301T%06dZ-%d' "$sr_state" "$i" "$i")"
  mkdir -p "$r"
  printf 'filler\n' > "$r/review.out"
  printf '{"type":"system"}\n' > "$r/reviewer.stream.jsonl"
  printf '{"type":"union"}\n' > "$r/.fleet-log.jsonl"
  i=$(( i + 1 ))
done
out="$(sync_as "$sr_home" active push STATE_SYNC_LOCAL_RETAINED=10 STATE_SYNC_STREAMS_RETAINED=2)"
assert_eq "the derived-retention push exits 0" "0" "$?"
# Four files across the two doomed cycle directories: a stream and a snapshot
# each. The count is the assertion that the snapshot is in the class at all.
assert_contains "a push reports the derived prune" "pruned 4 derived file(s) from cycles" "$out"
assert_eq "the oldest cycle's stream is deleted" "0" \
  "$(test -e "$sr_state/cycles/20260301T000000Z-0/coordinator.stream.jsonl" && echo 1 || echo 0)"
assert_eq "…and its fleet-log snapshot with it" "0" \
  "$(test -e "$sr_state/cycles/20260301T000000Z-0/.fleet-log.jsonl" && echo 1 || echo 0)"
assert_eq "…while the record it belonged to is untouched" "1" \
  "$(test -f "$sr_state/cycles/20260301T000000Z-0/coordinator.out" && echo 1 || echo 0)"
assert_eq "the newest cycles keep their streams" "1" \
  "$(test -f "$sr_state/cycles/20260301T000003Z-3/coordinator.stream.jsonl" && echo 1 || echo 0)"
assert_eq "…and their snapshots — the running cycle still reads its own" "1" \
  "$(test -f "$sr_state/cycles/20260301T000003Z-3/.fleet-log.jsonl" && echo 1 || echo 0)"
assert_eq "reviews are bounded the same way" "0" \
  "$(test -e "$sr_state/reviews/20260301T000000Z-0/reviewer.stream.jsonl" && echo 1 || echo 0)"
assert_eq "…snapshots included" "0" \
  "$(test -e "$sr_state/reviews/20260301T000000Z-0/.fleet-log.jsonl" && echo 1 || echo 0)"
assert_eq "…and keep their own records too" "1" \
  "$(test -f "$sr_state/reviews/20260301T000000Z-0/review.out" && echo 1 || echo 0)"
assert_eq "no cycle directory is removed by the derived prune" "4" \
  "$(find "$sr_state/cycles" -mindepth 1 -maxdepth 1 -type d | wc -l)"

# A derived file already in the mirror from before its exclusion existed is
# deleted from it, not merely left behind: `--delete-excluded` is what makes
# the rules retroactive, and without it every node's branch would keep whatever
# it had published up to the day this landed. For `.fleet-log.jsonl` that is
# not a hypothetical tail: at agent-ops#763 every copy on every branch predated
# the rule, so the retroactive half is the entire reclamation.
git clone --quiet --branch nodes/active-node "$remote" "$tmp_dir/legacy"
mkdir -p "$tmp_dir/legacy/cycles/20260720T010000Z-1"
printf '{"type":"system"}\n' > "$tmp_dir/legacy/cycles/20260720T010000Z-1/legacy.stream.jsonl"
printf '{"type":"union"}\n' > "$tmp_dir/legacy/cycles/20260720T010000Z-1/.fleet-log.jsonl"
git -C "$tmp_dir/legacy" add -A >/dev/null 2>&1
git -C "$tmp_dir/legacy" commit --quiet -m "state: derived files published before the exclusions" >/dev/null 2>&1
git -C "$tmp_dir/legacy" push --quiet origin HEAD:nodes/active-node >/dev/null 2>&1
sync_as "$active_home" active push >/dev/null
assert_eq "the legacy-derived push exits 0" "0" "$?"
rm -rf "$tmp_dir/pushed-again"
git clone --quiet --branch nodes/active-node "$remote" "$tmp_dir/pushed-again"
assert_eq "a stream already in the mirror is deleted from it" "0" \
  "$(test -e "$tmp_dir/pushed-again/cycles/20260720T010000Z-1/legacy.stream.jsonl" && echo 1 || echo 0)"
assert_eq "a snapshot already in the mirror is deleted from it" "0" \
  "$(test -e "$tmp_dir/pushed-again/cycles/20260720T010000Z-1/.fleet-log.jsonl" && echo 1 || echo 0)"

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
assert_eq "the active node's fetch exits 0" "0" "$?"
a_peers="$(fleet_peers_dir "$active_home/.cache/poetic-agents/workspaces")"
assert_eq "the active node holds its peers too" "1" \
  "$(test -f "$a_peers/standby-node/log.jsonl" && echo 1 || echo 0)"

# A deleted branch is a decommissioned node: its peer copy goes on the next
# fetch.
git -C "$remote" update-ref -d refs/heads/nodes/local-retention-node
sync_as "$standby_home" standby fetch >/dev/null
assert_eq "the branch-pruning fetch exits 0" "0" "$?"
assert_eq "a vanished branch prunes its peer copy" "0" \
  "$(test -e "$sb_peers/local-retention-node" && echo 1 || echo 0)"

# ==============================================================================
# fetch — a real failure is distinguished from the bootstrap no-op (#693)
# ==============================================================================
# A successful fetch marks the peers directory fresh.
marker="$sb_peers/.last-fetch.json"
assert_eq "a successful fetch marks the peers fresh" "true" \
  "$(jq -r '.ok' "$marker" 2>/dev/null)"
# Written whole and renamed into place, so a reader never catches it empty —
# and the write-side temporary is not left behind for one to find.
assert_eq "the marker leaves no half-written temporary behind" "0" \
  "$(test -e "$marker.tmp" && echo 1 || echo 0)"

# The genuine bootstrap case: a state repository with no node branches at all
# (a fresh bare repo, never pushed to) stays a silent no-op — exit 0, no
# marker written, because no fetch has ever actually run against real peer
# data.
bootstrap_remote="$tmp_dir/bootstrap-remote.git"
git init --quiet --bare --initial-branch=main "$bootstrap_remote"
bootstrap_home="$(new_node bootstrap-node)"
bootstrap_peers="$(fleet_peers_dir "$bootstrap_home/.cache/poetic-agents/workspaces")"
out="$(env HOME="$bootstrap_home" AGENT_OPS_ROLE=standby NODE_NAME=bootstrap-node \
  STATE_SYNC_REMOTE="$bootstrap_remote" "$SYNC" fetch 2>&1)"
assert_eq "the bootstrap fetch exits 0" "0" "$?"
assert_contains "the bootstrap fetch names itself as such" \
  "no node branches yet" "$out"
assert_eq "the bootstrap fetch writes no marker" "0" \
  "$(test -e "$bootstrap_peers/.last-fetch.json" && echo 1 || echo 0)"

# A real failure — modelled here as an unreachable remote, standing in for
# dead credentials or a network outage — is not the bootstrap case: it logs
# git's stderr, exits non-zero so the scheduler surfaces it, and marks the
# peers directory stale rather than leaving it silently looking fresh.
unreachable_home="$(new_node unreachable-node)"
unreachable_peers="$(fleet_peers_dir "$unreachable_home/.cache/poetic-agents/workspaces")"
out="$(env HOME="$unreachable_home" AGENT_OPS_ROLE=standby NODE_NAME=unreachable-node \
  STATE_SYNC_REMOTE="$tmp_dir/does-not-exist.git" "$SYNC" fetch 2>&1)"
status=$?
assert_eq "a real fetch failure exits non-zero" "1" "$status"
assert_contains "a real fetch failure is logged, not swallowed" \
  "could not reach the state repository" "$out"
assert_eq "a real fetch failure marks the peers stale" "false" \
  "$(jq -r '.ok' "$unreachable_peers/.last-fetch.json" 2>/dev/null)"

# A peer directory that was fresh and then starts failing is marked stale in
# place — a reader must see the flip, not a directory that still looks fresh
# from the last successful fetch.
was_fresh_home="$active_home"
was_fresh_peers="$a_peers"
sync_as "$was_fresh_home" active fetch >/dev/null
assert_eq "was fresh before the failure" "true" \
  "$(jq -r '.ok' "$was_fresh_peers/.last-fetch.json" 2>/dev/null)"
env HOME="$was_fresh_home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$was_fresh_home")" \
  STATE_SYNC_REMOTE="$tmp_dir/does-not-exist.git" "$SYNC" fetch >/dev/null 2>&1
assert_eq "a previously fresh peers directory flips to stale on failure" "false" \
  "$(jq -r '.ok' "$was_fresh_peers/.last-fetch.json" 2>/dev/null)"

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
# TOGGLE_GH is pinned to /bin/false so the fleet-flag writes that --disable
# and --enable now attempt (requirement 2.3a) go to a stub that fails like an
# unreachable state repo — never to the real one — and the local switch keeps
# working regardless, which is exactly the degraded mode being asserted here.
cycle_home="$(new_node cycle-node)"
env HOME="$cycle_home" AGENT_OPS_ROLE=standby NODE_NAME=cycle-node \
  STATE_SYNC_REMOTE="$remote" TOGGLE_GH=/bin/false \
  "$SCRIPT_DIR/agent-cycle.sh" --disable "state-sync test" >/dev/null 2>&1
assert_contains "switch events carry the node's name" '"node":"cycle-node"' \
  "$(cat "$cycle_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"
env HOME="$cycle_home" AGENT_OPS_ROLE=standby NODE_NAME=cycle-node \
  STATE_SYNC_REMOTE="$remote" TOGGLE_GH=/bin/false \
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
