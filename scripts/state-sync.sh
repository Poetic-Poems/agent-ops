#!/usr/bin/env bash
#
# state-sync.sh — replicate pipeline memory between nodes through a private
# GitHub repository, and arbitrate which node may spend.
#
# The pipelines' memory lives in state_dir: what has been tried, what is
# blocked, what the switch says, what each cycle cost. A node that has none of
# it is not a spare — it would re-select work the fleet has already done and
# re-learn every no-op the hard way. This script is what makes a standby node a
# warm one.
#
#   state-sync.sh push      the active node publishes its state (after a cycle)
#   state-sync.sh restore    a standby node takes a copy (from its crontab)
#   state-sync.sh lease      the active node claims the right to run
#
# Every mode is a silent no-op when `state_repo` is unset in config.json, so a
# lone node — the laptop before cutover — behaves exactly as it did before this
# script existed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"

usage() {
  cat <<'EOF'
usage: state-sync.sh push|restore|lease

Replicate the pipelines' state_dir between nodes through the private repository
named by `state_repo` in config.json.

  push      Mirror this node's state_dir into the state repository as a single
            rolling commit. Active nodes only; called at the end of a cycle.
  restore   Mirror the state repository into this node's state_dir. Standby
            nodes only; called from the node's crontab.
  lease     Claim or refresh `leader.json`, the record of which node is
            running cycles. Exits 3 if another node holds a lease that has not
            yet expired (`lease_ttl_hours`), which is a standing-down node's
            cue, not an error.

Exit codes: 0 done or nothing to do · 3 the lease is held elsewhere · 1 failure.

Environment:
  NODE_NAME             this node's name in the lease and the commit message
                        (defaults to the hostname).
  AGENT_OPS_ROLE        `active` or standby; decides which modes do anything.
  STATE_SYNC_REMOTE     override the remote URL (tests point it at a bare repo).
  STATE_SYNC_MIRROR     override the local mirror checkout's location.
  STATE_SYNC_GH         override the `gh` used for the lease (tests stub it).
  STATE_SYNC_LOCAL_RETAINED
                        override `state_local_cycles_retained` (tests use a
                        small value).
EOF
}

MODE=""
case "${1:-}" in
  push|restore|lease) MODE="$1"; shift ;;
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
lease_ttl_hours="$(cfg '.lease_ttl_hours // 3')"
cycles_retained="$(cfg '.cycles_retained // 200')"
local_retained="${STATE_SYNC_LOCAL_RETAINED:-$(cfg '.state_local_cycles_retained // 1000')}"

node_name="${NODE_NAME:-$(hostname)}"
remote_url="${STATE_SYNC_REMOTE:-https://github.com/$state_repo.git}"
mirror="${STATE_SYNC_MIRROR:-$workspace_root/.agent-ops-state}"

# --- What is memory and what is merely local ---------------------------------
# Excluded from replication in both directions:
#
#   the locks       a restored lock.json is a lock no process holds, and it
#                   would stand every later cycle down until it went stale.
#   this script's   `state-sync.log` is where a node records its own
#   own log          replication; replicating it would be a node describing
#                   another node's description of itself.
#   the dashboard   `dashboard/` is generated from the state beside it and
#                   `dashboard.log`/`dashboard-server.log`/`.dashboard-github.json`
#                   are one node's rendering machinery. Each node republishes
#                   its own page from the state it has; copying the pixels
#                   would be copying a derivative of what we are already
#                   copying.
#   .git            the mirror's own repository, which lives at the same root.
#   leader.json     the lease. It lives in the state repository but not in any
#                   node's state_dir, so without this the first push would
#                   `--delete` it and every node would find the operation
#                   unclaimed. Excluding it protects it from rsync in both
#                   directions: the lease is written through the API, never by
#                   a mirror.
#
# Everything else — log.jsonl, review-log.jsonl, cycles/, reviews/,
# disabled.json, the cron logs — is the fleet's memory and is replicated. The
# cron logs go too because the dashboard reads them: a standby node should be
# able to show what the operation has been doing, not what it has not.
EXCLUDES=(
  --exclude=.git
  --exclude=/leader.json
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

# --- The mirror --------------------------------------------------------------
# A persistent shallow checkout, kept outside state_dir (it must not sync
# itself) and inside workspace_root, which is already the place for large
# throwaway clones. Persistent rather than re-cloned each time because a
# standby restores every few minutes and a fetch of nothing is far cheaper than
# a clone of everything.
mirror_refresh() {
  if [[ ! -d "$mirror/.git" ]]; then
    rm -rf "$mirror"
    mkdir -p "$(dirname "$mirror")"
    git clone --quiet --depth 1 "$remote_url" "$mirror" 2>/dev/null || {
      say "ERROR: cannot clone $remote_url"
      say "       the state repository is private: this node needs a GH_TOKEN that can read it,"
      say "       and git configured to use it (\`gh auth setup-git\`, which the container"
      say "       entrypoint runs at start)."
      return 1
    }
    return 0
  fi
  git -C "$mirror" remote set-url origin "$remote_url"
  # A repository nobody has pushed to yet has no `main` to fetch. That is the
  # state of a freshly created state repo, and the first push is what fixes it.
  if git -C "$mirror" fetch --quiet --depth 1 origin main 2>/dev/null; then
    git -C "$mirror" reset --quiet --hard FETCH_HEAD
    git -C "$mirror" clean -qfd
  fi
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
  role_is_active || exit 0
  require rsync
  require git

  # Bound this node's own history before mirroring any of it: the local cap
  # (`state_local_cycles_retained`) sits deliberately far above the mirror's
  # (`cycles_retained`), so everything the mirror wants is always still here
  # and the machine stays the longer record of the two. Before the no-change
  # early-return below, so a push with nothing to replicate still prunes.
  prune_local "$state_dir/cycles"  "$local_retained"
  prune_local "$state_dir/reviews" "$local_retained"

  mirror_refresh || exit 1

  # Everything but the cycle directories, which need a filter of their own.
  rsync -a --delete "${EXCLUDES[@]}" --exclude=/cycles/ "$state_dir/" "$mirror/"

  # The cycles, newest `cycles_retained` only. `--delete-excluded` is what
  # prunes: a cycle that falls out of the keep list is excluded from the
  # transfer *and* deleted from the mirror. The local state_dir is never
  # pruned — a node's own history is its own business, and this retention
  # exists to bound the size of a repository that is force-pushed on every
  # cycle.
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

  if [[ -z "$(git -C "$mirror" status --porcelain)" ]]; then
    say "no state change since the last push"
    return 0
  fi

  # One rolling commit, amended and force-pushed. The state files carry their
  # own history — log.jsonl is append-only and every cycle keeps its own
  # directory — so a commit per push would be a second, redundant history whose
  # only lasting effect would be a repository that grows without bound.
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
  git -C "$mirror" push --quiet --force origin HEAD:main
  say "pushed $(du -sh "$mirror" 2>/dev/null | cut -f1) of state as $node_name"
}

do_restore() {
  # The active node is the source of truth; restoring onto it would overwrite
  # the cycle it is in the middle of remembering.
  ! role_is_active || exit 0
  require rsync
  require git
  mirror_refresh || exit 1
  if ! git -C "$mirror" rev-parse --verify --quiet HEAD >/dev/null; then
    say "the state repository is empty — nothing to restore yet"
    return 0
  fi

  mkdir -p "$state_dir"
  local changed
  # --delete makes this a mirror rather than a merge: a cycle pruned upstream
  # goes here too. The excluded files are protected from it by rsync, so this
  # node's own locks, logs and dashboard survive untouched.
  changed="$(rsync -a --delete --itemize-changes "${EXCLUDES[@]}" \
    "$mirror/" "$state_dir/" | grep -cv '^$' || true)"
  # Silence when nothing moved: this runs every few minutes on every standby
  # node, and a cron log of "nothing happened" is a cron log nobody reads.
  (( changed > 0 )) && say "restored $changed change(s) from $state_repo"
  return 0
}

# --- The lease ---------------------------------------------------------------
# The safety net under AGENT_OPS_ROLE. The role is a local setting, and the way
# it fails is human: two nodes are configured active, or a failover forgets to
# stand the old node down, and both start spending on the same repositories.
# `leader.json` in the state repository is the shared record of who is running,
# refreshed on every cycle and expiring after `lease_ttl_hours` so that a node
# which dies does not hold the operation down with it.
#
# Read and written through the REST contents API rather than the mirror: this
# check happens before a cycle does anything, and it should cost one request,
# not a clone.
lease_path="leader.json"
# Named rather than called directly so a test can substitute one: the calling
# pipelines put /usr/bin ahead of everything on PATH, so a stub `gh` in a
# throwaway HOME would never be reached.
GH="${STATE_SYNC_GH:-gh}"

do_lease() {
  role_is_active || exit 0
  require "$GH"

  local current sha holder updated
  if current="$("$GH" api "repos/$state_repo/contents/$lease_path" 2>/dev/null)"; then
    sha="$(jq -r '.sha' <<<"$current")"
    local decoded
    decoded="$(jq -r '.content' <<<"$current" | tr -d '\n' | base64 -d 2>/dev/null || true)"
    holder="$(jq -r '.node // ""' <<<"$decoded" 2>/dev/null || true)"
    updated="$(jq -r '.updated // ""' <<<"$decoded" 2>/dev/null || true)"
  else
    # No lease file yet (a state repo nobody has claimed), or GitHub is
    # unreachable. Both are handled below: the first by writing one, the
    # second by failing open.
    sha=""; holder=""; updated=""
  fi

  if [[ -n "$holder" && "$holder" != "$node_name" ]]; then
    local updated_epoch now_epoch age_h
    updated_epoch="$(date -d "$updated" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    age_h=$(( (now_epoch - updated_epoch) / 3600 ))
    if (( updated_epoch > 0 && age_h < lease_ttl_hours )); then
      say "$holder holds the lease (refreshed ${age_h}h ago, expires after ${lease_ttl_hours}h) — standing down"
      exit 3
    fi
    say "taking the lease from $holder, whose lease expired (last refreshed ${age_h}h ago)"
  fi

  local body payload args
  body="$(jq -nc --arg n "$node_name" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{node: $n, updated: $t}')"
  payload="$(printf '%s\n' "$body" | base64 -w0)"
  args=(-X PUT "repos/$state_repo/contents/$lease_path"
    -f "message=lease: $node_name $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    -f "content=$payload")
  # The sha is what makes this a compare-and-set: if another node wrote the
  # lease between the read above and this write, GitHub rejects it and we are
  # the one that stands down.
  [[ -n "$sha" ]] && args+=(-f "sha=$sha")
  if ! "$GH" api "${args[@]}" >/dev/null 2>&1; then
    if [[ -n "$holder" && "$holder" != "$node_name" ]]; then
      say "lost the race to claim the lease — standing down"
      exit 3
    fi
    # Fail open. A node that cannot reach GitHub for one minute is a normal
    # event; an operation that stops running because of it is not. The cost of
    # being wrong here is bounded — it needs a *second* active node to exist
    # before anything is duplicated — while the cost of failing closed is an
    # operation that quietly does nothing and looks healthy doing it.
    say "WARNING: could not write the lease — proceeding anyway"
    return 0
  fi
  return 0
}

case "$MODE" in
  push) do_push ;;
  restore) do_restore ;;
  lease) do_lease ;;
esac
