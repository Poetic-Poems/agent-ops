#!/usr/bin/env bash
#
# state-sync.sh — publish each node's pipeline memory as its own branch of a
# private GitHub repository, and mirror every peer's back for union reads.
#
# The pipelines' memory lives in state_dir: what has been tried, what is
# blocked, what each cycle cost. Under the multi-active fleet every node is a
# writer, so there is no one state to adopt and no lease to arbitrate who may
# write it — work is arbitrated per item by the claims of requirement 17a
# (lib/claim.sh), and state is per node:
#
#   state-sync.sh push    publish this node's state_dir as the rolling branch
#                         `nodes/<NODE_NAME>` — every node, every few minutes
#                         and at the end of every cycle; contention-free,
#                         because no two nodes share a branch
#   state-sync.sh fetch   materialise every peer's branch under the peers
#                         directory (lib/fleet.sh), where the union readers —
#                         blocked/void extraction, the no-op fingerprint, the
#                         usage-limit cooldown, the fleet dashboard — find
#                         them as ordinary local files
#
# Every mode is a silent no-op when `state_repo` is unset in config.json, so a
# lone node behaves exactly as it did before the fleet existed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"

usage() {
  cat <<'EOF'
usage: state-sync.sh push|fetch

Publish this node's state_dir as its own branch (`nodes/<NODE_NAME>`) of the
private repository named by `state_repo` in config.json, and mirror the other
nodes' branches back for union reads.

  push      Mirror state_dir into the node's own rolling branch, stamped with
            a heartbeat ({node, role, ts, last_cycle}). Every node pushes —
            an active node publishes its cycles, a standby its liveness.
  fetch     Refresh the local copy of every peer's branch into the peers
            directory (see lib/fleet.sh). Prunes a peer whose branch is gone.

Exit codes: 0 done or nothing to do · 1 failure.

Environment:
  NODE_NAME             this node's name — the branch and heartbeat carry it
                        (defaults to the hostname).
  AGENT_OPS_ROLE        recorded in the heartbeat; gates neither mode.
  STATE_SYNC_REMOTE     override the remote URL (tests point it at a bare repo).
  STATE_SYNC_MIRROR     override the local mirror checkout's location.
  STATE_SYNC_LOCAL_RETAINED
                        override `state_local_cycles_retained` (tests use a
                        small value).
EOF
}

MODE=""
case "${1:-}" in
  push|fetch) MODE="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
  "") usage >&2; exit 64 ;;
  *) echo "state-sync: unknown mode: $1" >&2; usage >&2; exit 64 ;;
esac
if [[ $# -gt 0 ]]; then
  echo "state-sync: unexpected argument: $1" >&2
  exit 64
fi

say() { printf '%s state-sync(%s): %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$*"; }

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}
cfg() { jq -r "$1" "$CONFIG_FILE"; }

state_repo="$(cfg '.state_repo // ""')"
# Unconfigured is not a failure: it is a single-node operation, which is what
# this one was until the fleet existed.
[[ -n "$state_repo" && "$state_repo" != "null" ]] || exit 0

state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
cycles_retained="$(cfg '.cycles_retained // 200')"
local_retained="${STATE_SYNC_LOCAL_RETAINED:-$(cfg '.state_local_cycles_retained // 1000')}"

node_name="${NODE_NAME:-$(hostname)}"
node_name="${node_name//[^A-Za-z0-9._-]/-}"
state_branch="nodes/$node_name"
remote_url="${STATE_SYNC_REMOTE:-https://github.com/$state_repo.git}"
mirror="${STATE_SYNC_MIRROR:-$workspace_root/.agent-ops-state}"
peers_dir="$(fleet_peers_dir "$workspace_root")"

# --- What is memory and what is merely local ---------------------------------
# Excluded from the branch in both directions:
#
#   the locks       a copied lock.json is a lock no process holds; peers read
#                   logs, never locks.
#   this script's   `state-sync.log` is where a node records its own
#   own log          replication; replicating it would be a node describing
#                   another node's description of itself.
#   the dashboard   `dashboard/` is generated from the state beside it and
#                   `dashboard.log`/`dashboard-server.log`/`.dashboard-github.json`
#                   are one node's rendering machinery. Each node republishes
#                   its own page from the union it fetches; copying the pixels
#                   would be copying a derivative of what we are already
#                   copying.
#   .git            the mirror's own repository, which lives at the same root.
#
# Everything else — log.jsonl, review-log.jsonl, cycles/, reviews/,
# disabled.json, the cron logs — is the node's contribution to the fleet's
# memory and is published.
EXCLUDES=(
  --exclude=.git
  --exclude=lock.json
  --exclude=review-lock.json
  --exclude=dashboard.lck
  --exclude=dashboard.log
  --exclude=dashboard-server.log
  --exclude=state-sync.log
  --exclude=.dashboard-github.json
  --exclude=/dashboard/
)

require() {
  local bin="$1"
  if ! command -v "$bin" >/dev/null 2>&1; then
    say "WARNING: $bin is not on PATH — skipping"
    exit 0
  fi
}

# One state-sync per mirror at a time: the every-few-minutes cron push and the
# end-of-cycle push are the same operation racing on the same checkout, and
# the loser of that race has nothing to add that the winner will not.
mirror_lock() {
  mkdir -p "$(dirname "$mirror")"
  exec 9>"$mirror.lock"
  if ! flock -n 9; then
    say "another state-sync holds the mirror — nothing to do"
    exit 0
  fi
}

mirror_init() {
  if [[ ! -d "$mirror/.git" ]]; then
    rm -rf "$mirror"
    mkdir -p "$mirror"
    git -C "$mirror" init --quiet
    git -C "$mirror" remote add origin "$remote_url"
  fi
  git -C "$mirror" remote set-url origin "$remote_url"
}

# Newest-first list of the cycle directories worth keeping. Their names are
# UTC timestamps, so lexical order is chronological order.
kept_cycles() {
  [[ -d "$state_dir/cycles" ]] || return 0
  find "$state_dir/cycles" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
    | sort -r | head -n "$cycles_retained"
}

# The node's own history is bounded too (TD26072004): without this, a
# long-lived active node accretes one cycle directory an hour forever.
# Newest-first, so the cycle being recorded right now is always kept; the
# floor of 1 keeps a nonsense retention value from deleting it.
prune_local() {
  local dir="$1" retained="$2" doomed pruned=0
  [[ -d "$dir" ]] || return 0
  (( retained >= 1 )) || retained=1
  while IFS= read -r doomed; do
    [[ -n "$doomed" ]] || continue
    rm -rf -- "${dir:?}/$doomed"
    pruned=$(( pruned + 1 ))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
             | sort -r | tail -n "+$(( retained + 1 ))")
  (( pruned > 0 )) && say "pruned $pruned $(basename "$dir") record(s), keeping the newest $retained"
  return 0
}

do_push() {
  require rsync
  require git
  mirror_lock
  mirror_init

  # Bound this node's own history before mirroring any of it: the local cap
  # (`state_local_cycles_retained`) sits deliberately far above the mirror's
  # (`cycles_retained`), so everything the mirror wants is always still here
  # and the machine stays the longer record of the two.
  prune_local "$state_dir/cycles"  "$local_retained"
  prune_local "$state_dir/reviews" "$local_retained"

  # Start from the branch's current tip when there is one — the amend below
  # keeps history a single rolling commit per node.
  if git -C "$mirror" fetch --quiet --depth 1 origin "$state_branch" 2>/dev/null; then
    git -C "$mirror" reset --quiet --hard FETCH_HEAD
    git -C "$mirror" clean -qfd
  fi

  # Everything but the cycle directories, which need a filter of their own.
  rsync -a --delete "${EXCLUDES[@]}" --exclude=/cycles/ --exclude=/heartbeat.json \
    "$state_dir/" "$mirror/"

  # The cycles, newest `cycles_retained` only. `--delete-excluded` is what
  # prunes: a cycle that falls out of the keep list is excluded from the
  # transfer *and* deleted from the mirror.
  local filter_file
  filter_file="$(mktemp)"
  # shellcheck disable=SC2064  # expand the path now, while it is still set
  trap "rm -f '$filter_file'" RETURN
  while IFS= read -r c; do
    [[ -n "$c" ]] && printf -- '+ /%s/\n' "$c" >> "$filter_file"
  done < <(kept_cycles)
  printf -- '- /*\n' >> "$filter_file"
  mkdir -p "$mirror/cycles"
  rsync -a --delete --delete-excluded --filter="merge $filter_file" \
    "$state_dir/cycles/" "$mirror/cycles/"

  # The heartbeat is why every push moves the branch: it is what lets the
  # fleet dashboard tell a quiet node from a dead one — on a standby (which
  # has no cycles to publish) it is the entire point of the push.
  local last_cycle
  last_cycle="$(find "$state_dir/cycles" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
    | sort -r | head -n 1)"
  jq -nc \
    --arg node "$node_name" \
    --arg role "${AGENT_OPS_ROLE:-standby}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg lc "${last_cycle:-}" \
    '{node: $node, role: $role, ts: $ts, last_cycle: $lc}' > "$mirror/heartbeat.json"

  # One rolling commit per node, amended and force-pushed. The state files
  # carry their own history — log.jsonl is append-only and every cycle keeps
  # its own directory — so a commit per push would be a second, redundant
  # history whose only lasting effect would be a repository that grows
  # without bound. A mid-cycle push is fine now: peers consume logs and the
  # dashboard tolerates a torn transcript for one tick, and nobody adopts
  # this state wholesale any more.
  git -C "$mirror" add -A
  local msg
  msg="state: $node_name $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local commit=(git -C "$mirror"
    -c "user.name=${GIT_USER_NAME:-agent-ops}"
    -c "user.email=${GIT_USER_EMAIL:-agent-ops@localhost}"
    commit --quiet -m "$msg")
  if git -C "$mirror" rev-parse --verify --quiet HEAD >/dev/null; then
    "${commit[@]}" --amend
  else
    "${commit[@]}"
  fi
  git -C "$mirror" push --quiet --force origin "HEAD:refs/heads/$state_branch"
  say "pushed $(du -sh "$mirror" 2>/dev/null | cut -f1) of state as $state_branch"
}

do_fetch() {
  require git
  require tar
  mirror_lock
  mirror_init

  # All the nodes' branches at once, pruning the tracking refs of nodes whose
  # branch has been deleted — a decommissioned machine leaves the fleet by
  # having its branch removed.
  if ! git -C "$mirror" fetch --quiet --prune --depth 1 origin \
      '+refs/heads/nodes/*:refs/remotes/origin/nodes/*' 2>/dev/null; then
    say "the state repository has no node branches yet — nothing to fetch"
    return 0
  fi

  mkdir -p "$peers_dir"
  local peers=() name tmp
  while IFS= read -r name; do
    [[ -n "$name" && "$name" != "$node_name" ]] || continue
    peers+=("$name")
    tmp="$peers_dir/.tmp.$name"
    rm -rf "$tmp"
    mkdir -p "$tmp"
    # Materialised whole and swapped in, so a union reader never sees half a
    # peer.
    if git -C "$mirror" archive "origin/nodes/$name" 2>/dev/null | tar -x -C "$tmp" 2>/dev/null; then
      rm -rf "${peers_dir:?}/${name:?}"
      mv "$tmp" "$peers_dir/$name"
    else
      rm -rf "$tmp"
      say "WARNING: could not materialise peer $name"
    fi
  done < <(git -C "$mirror" for-each-ref 'refs/remotes/origin/nodes' \
             --format='%(refname)' | sed 's#^refs/remotes/origin/nodes/##')

  # A peer directory whose branch is gone is a machine that has left the
  # fleet; keeping its copy would keep resurrecting its opinions.
  local existing found p
  while IFS= read -r existing; do
    [[ -n "$existing" ]] || continue
    [[ "$existing" == .tmp.* ]] && { rm -rf "${peers_dir:?}/$existing"; continue; }
    found=0
    for p in ${peers[@]+"${peers[@]}"}; do
      [[ "$p" == "$existing" ]] && { found=1; break; }
    done
    (( found )) || rm -rf "${peers_dir:?}/$existing"
  done < <(find "$peers_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)

  say "holding ${#peers[@]} peer(s)"
  return 0
}

case "$MODE" in
  push) do_push ;;
  fetch) do_fetch ;;
esac
