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
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/compose-drift.sh
. "$SCRIPT_DIR/lib/compose-drift.sh"
# shellcheck source=lib/image-drift.sh
. "$SCRIPT_DIR/lib/image-drift.sh"
# shellcheck source=lib/updater-health.sh
. "$SCRIPT_DIR/lib/updater-health.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/mirror-integrity.sh
. "$SCRIPT_DIR/lib/mirror-integrity.sh"

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
  STATE_SYNC_STREAMS_RETAINED
                        override `state_local_streams_retained` (likewise).
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
# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below, with no `// literal` of its own to drift from the schema's.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }

state_repo="$(cfg '.state_repo')"
# Unconfigured is not a failure: it is a single-node operation, which is what
# this one was until the fleet existed.
[[ -n "$state_repo" ]] || exit 0

state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
cycles_retained="$(cfg '.cycles_retained')"
local_retained="${STATE_SYNC_LOCAL_RETAINED:-$(cfg '.state_local_cycles_retained')}"
streams_retained="${STATE_SYNC_STREAMS_RETAINED:-$(cfg '.state_local_streams_retained')}"
# Minutes → seconds: lib/updater-health.sh's own contract takes a threshold
# in seconds, never a config key of its own (agent-ops#603, following
# image_behind_grace_hours' shape — the judgement lives one layer up from
# the library, not baked into it). Converted in jq rather than `$(( ))`
# because the schema types the key `number`, so a node may legitimately
# configure `7.5` — which bash arithmetic cannot evaluate at all, and this
# script runs under `set -e`, so the node would stop publishing a heartbeat
# entirely over a legal config value.
updater_stuck_after_seconds="$(cfg '.updater_stuck_after_minutes * 60 | floor')"
# The bound on a legitimate defer streak: past the longer of the two lock
# staleness windows, watchtower-pre-update.sh's own held_by() would no longer
# honour either lock, so a defer streak that has outlived both is no longer
# "a cycle in flight" — it is the same "stuck" fault an unresolved allow is.
# Mirrors the hook's own simple `// 4`/`// 6` defaults (config.json read
# directly there, not the derived value acquire_lock uses) rather than
# re-deriving them, since this is bounding the same hook's own behaviour.
updater_defer_stuck_after_seconds="$(cfg \
  '([.lock_stale_after // 4, .project_review.lock_stale_after // 6] | max) * 3600 | floor')"

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
#                   logs, never locks. `roll-pending.json` (agent-ops#1096)
#                   travels the same way and for the same reason: it is this
#                   node's own instruction to its own watchtower hook to
#                   allow an update despite its own lock, for a window only
#                   this node's own cycle boundary can have earned — a copy on
#                   a peer would tell that peer's hook to allow a roll nothing
#                   about that peer actually asked for.
#   this script's   `state-sync.log` is where a node records its own
#   own log          replication; replicating it would be a node describing
#                   another node's description of itself.
#   the dashboard   `dashboard/` is generated from the state beside it, and the
#                   logs and caches beside it (`dashboard.log`,
#                   `dashboard-server.log`, `.dashboard-github.json`,
#                   `.dashboard-claims.json`, `.dashboard-tick-cost`) are one
#                   node's rendering machinery. Each node republishes its own
#                   page from the union it fetches; copying the pixels would
#                   be copying a derivative of what we are already copying.
#   the image-drift `.image-drift-cache.json` is this node's own last read of
#   cache            the registry (lib/image-drift.sh) — a peer's copy of it
#                   would answer for a registry query nobody there ran, not
#                   for that peer.
#   the stage-      `.stage-health.json` (lib/stage-health.sh, agent-ops#662)
#   health snapshot  is excluded as a raw file for the same reason
#                   `.doctor-status.json` is — a peer's copy of the file
#                   itself would answer for a computation nobody there ran —
#                   but unlike doctor's status this verdict does need to
#                   reach peers, which is the whole point of #662: a fleet
#                   dashboard that can only see this node's own stages is no
#                   better than `--status` run locally. So its *content*
#                   travels a different way, the same one `compose`/`image`/
#                   `switch` already use below: folded into `heartbeat.json`,
#                   this node's own verdict about itself, published like any
#                   other fact only this node can state.
#   the stage       `*.stream.jsonl` is a stage's whole event stream, every
#   streams          message and every tool result (lib/stage-run.sh). It is
#                   local forensics and, while the stage runs, its liveness
#                   signal — neither of which is a fact about this node that
#                   a peer needs. The size is what makes it a hard exclusion
#                   rather than a preference: a stage's `.out` is one JSON
#                   object, but its stream runs to megabytes, and the mirror
#                   holds `cycles_retained` cycles across four branches with
#                   the whole history in git. What a peer reads — the result
#                   envelope — is published as `<stage>.out` exactly as
#                   before.
#   the fleet-log   `.fleet-log.jsonl` is the union of every node's
#   snapshot         `log.jsonl` as one cycle saw it, materialised into that
#                   cycle's own directory (`fleet_logs`, lib/fleet.sh) and
#                   read only by the cycle that wrote it. Publishing it would
#                   send a peer a derivative of the very logs it is already
#                   being sent — and one copy of it per retained cycle,
#                   `cycles_retained` of them, each the size of the whole
#                   fleet's history to that point (agent-ops#763).
#   .git            the mirror's own repository, which lives at the same root.
#
# Everything else — log.jsonl, review-log.jsonl, revert-rate.jsonl, cycles/,
# reviews/, disabled.json, the cron logs — is the node's contribution to the
# fleet's memory and is published.
#
# The two per-cycle exclusions — the stage streams and the fleet-log snapshot
# — have to be stated twice, once here and once in the cycles filter file
# below, because the cycle directories are transferred by a second rsync whose
# `--filter` rules these `--exclude`s do not reach. The comment is here rather
# than there so the two do not drift.
EXCLUDES=(
  --exclude=.git
  --exclude=lock.json
  --exclude=review-lock.json
  --exclude=roll-pending.json
  --exclude=dashboard.lck
  --exclude=dashboard.log
  --exclude=dashboard-server.log
  --exclude=state-sync.log
  # doctor.log and its structured sibling (scripts/doctor.sh --unattended,
  # agent-ops#543): the hourly pass is local to this node the same way
  # dashboard.log and .image-drift-cache.json below are — nothing reads
  # either from a peer, so neither travels.
  --exclude=doctor.log
  --exclude=.doctor-status.json
  --exclude=.stage-health.json
  # revert-rate.log (scripts/publish-revert-rate.sh, agent-ops#579): the
  # daily pass's own text output, local to this node on the same reasoning
  # as doctor.log above. Its structured sibling, revert-rate.jsonl, is
  # deliberately absent from this list — every node's own rows are the
  # fleet-wide data the revert-rate dashboard panel unions, the same as
  # log.jsonl, so it must travel.
  --exclude=revert-rate.log
  # revert-rate-cumulative-state.json (TD-PPagop-26082204): this node's own
  # memoisation of the cumulative-since-baseline pass's settled aggregate —
  # a cache of what this node has already mined, not a fact about the fleet
  # a peer would read, so it stays local on the same reasoning as
  # .doctor-status.json above.
  --exclude=revert-rate-cumulative-state.json
  --exclude=.dashboard-github.json
  --exclude=.dashboard-tick-cost
  --exclude=.dashboard-payload
  --exclude=/.dashboard-cycle-cache/
  --exclude=.dashboard-claims.json
  --exclude=.image-drift-cache.json
  # .mirror-rebuild-state.json (lib/mirror-integrity.sh, agent-ops#604): this
  # node's own durable record of whether/when it last discarded and rebuilt
  # its state-sync mirror — memoisation like .image-drift-cache.json above,
  # published to peers only as the heartbeat's `mirror` verdict below, never
  # as this raw file.
  --exclude=.mirror-rebuild-state.json
  # labels-ensured/ (lib/labels.sh's labels_ensure_stamped, agent-ops#687):
  # per-(repo, role) rate-limit stamp files, local to this node on the same
  # reasoning as .image-drift-cache.json above — no peer reads another
  # node's stamps, and a stamp restored from the fleet state branch would
  # carry a checkout-fresh mtime, silently deferring that node's next ensure
  # of every repository by a full interval.
  --exclude=labels-ensured/
  # expensive-gather/ (lib/expensive-gather-cache.sh, requirement 48,
  # agent-ops#1086): this node's own cache of each configured repository's
  # last expensively-gathered bands, local to this node on the same
  # reasoning as labels-ensured/ above — no peer reads another node's cache,
  # and expensive_gather_pick_repo keys entirely on cache-file mtime, so a
  # cache restored from the fleet state branch would carry a checkout-fresh
  # mtime, making every repository look freshly read and deferring this
  # node's next real gather of each one by a full rotation while it keeps
  # serving the restored (arbitrarily stale) snapshots.
  --exclude=/expensive-gather/
  # updater-ledger/ (deploy/docker/watchtower-pre-update.sh,
  # lib/updater-health.sh, agent-ops#603): this node's own record of its
  # pre-update hook's invocations, keyed by container — a peer's copy of it
  # would answer for invocations against nobody's containers there, on the
  # same reasoning as .image-drift-cache.json above. Its *verdict* does reach
  # peers, folded into the heartbeat's own `updater` field below, exactly as
  # `stage_health`'s raw file is excepted the same way one entry up.
  --exclude=/updater-ledger/
  --exclude=*.stream.jsonl
  --exclude=.fleet-log.jsonl
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
  local fresh=0
  if [[ ! -d "$mirror/.git" ]]; then
    fresh=1
    rm -rf "$mirror"
    mkdir -p "$mirror"
    git -C "$mirror" init --quiet
    git -C "$mirror" remote add origin "$remote_url"
  fi
  git -C "$mirror" remote set-url origin "$remote_url"

  # A mirror that already existed has to prove it still deserves the trust a
  # bare directory check used to hand it for free (lib/mirror-integrity.sh).
  # A mirror this call just created has nothing to have failed yet, so the
  # check — and any rebuild it might otherwise log — never runs against a
  # fresh init: that first-ever push must stay silent, not report
  # self-healing that never happened.
  if (( ! fresh )) && ! mirror_integrity_ok "$mirror"; then
    say "WARNING: mirror failed its integrity check — discarding and rebuilding from source"
    rm -rf "$mirror"
    mkdir -p "$mirror"
    git -C "$mirror" init --quiet
    git -C "$mirror" remote add origin "$remote_url"
    mirror_record_rebuild "$state_dir"
  fi
}

# Newest-first list of the cycle directories worth keeping. Their names are
# UTC timestamps, so lexical order is chronological order.
#
# `sed -n '1,Np'` rather than `head -n N`, and the same at every other site
# that slices a sorted stream: `head` closes the pipe the instant it has its N
# lines, and `sort` — which cannot emit anything before it has read every name
# — is still writing. That is a SIGPIPE, and `pipefail` promotes it to 141 for
# the whole pipeline. `sed` without `q` reads its input to the end, so no
# writer upstream is ever signalled.
#
# This particular site never killed anything, but only by accident of its
# caller: `done < <(kept_cycles)` is a process substitution, and bash discards
# a process substitution's status. The identical shape at `node_meta`'s
# `last_cycle` below sat in a command substitution under `set -euo pipefail`
# instead, and killed roughly half of every node's state pushes for a month
# (#806). Depending on the caller's shape to stay safe is not a property worth
# keeping, so both were rewritten the same way.
kept_cycles() {
  [[ -d "$state_dir/cycles" ]] || return 0
  # Matching prune_local's floor: a nonsense retention value must not turn
  # into `sed -n '1,0p'`, which is an error rather than an empty list.
  local retained="$cycles_retained"
  (( retained >= 1 )) || retained=1
  find "$state_dir/cycles" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
    | sort -r | sed -n "1,${retained}p"
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

# A record directory's *derived* files are bounded far more tightly than the
# record that holds them, and separately from it, because they are a different
# order of size: a cycle directory without them is a handful of kilobytes of
# JSON, while one 47-turn Reviewer stream alone can be megabytes and the
# fleet-log snapshot beside it is the whole fleet's history to that moment.
# Keeping `state_local_cycles_retained` cycles' worth of those would
# trade the node's whole disk for forensics nobody reads past the day of the
# incident, so they go early and the records they belong to stay.
#
# Two files qualify, and the rule is the property they share rather than
# either name: large, purely derived, and read only by the cycle that wrote
# them.
#
#   `*.stream.jsonl`    a stage's whole event stream (lib/stage-run.sh).
#   `.fleet-log.jsonl`  the union of every node's log as that cycle saw it
#                       (`fleet_logs`, lib/fleet.sh).
#
# The second was missing here until agent-ops#763, so it fell through to
# `prune_local` and was kept a thousand deep — 17 GB across one host's two
# nodes and their peer mirrors, growing about a gigabyte a day. Anything
# added to a record directory later that shares those three properties
# belongs in this list too; the disk is the only thing that reports its
# absence, and only once it is already gone.
#
# Newest-first with a floor of 1, exactly as `prune_local`: the cycle running
# right now must never lose the stream its own watchdog is reading, nor the
# snapshot its own gates are still reading back.
prune_derived() {
  local dir="$1" retained="$2" doomed pruned=0
  [[ -d "$dir" ]] || return 0
  (( retained >= 1 )) || retained=1
  while IFS= read -r doomed; do
    [[ -n "$doomed" ]] || continue
    while IFS= read -r -d '' f; do
      rm -f -- "$f"
      pruned=$(( pruned + 1 ))
    done < <(find "${dir:?}/$doomed" -maxdepth 1 -type f \
                  \( -name '*.stream.jsonl' -o -name '.fleet-log.jsonl' \) \
                  -print0 2>/dev/null)
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
             | sort -r | tail -n "+$(( retained + 1 ))")
  (( pruned > 0 )) && say "pruned $pruned derived file(s) from $(basename "$dir"), keeping those of the newest $retained"
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
  prune_derived "$state_dir/cycles"  "$streams_retained"
  prune_derived "$state_dir/reviews" "$streams_retained"

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
  # First rule wins in an rsync filter, so the derived per-cycle files are
  # excluded ahead of the per-cycle includes that would otherwise carry them.
  # With `--delete-excluded` below, this also removes any copy a node
  # published before these rules existed — which for `.fleet-log.jsonl` is
  # every copy on every branch at the time of agent-ops#763.
  printf -- '- *.stream.jsonl\n' >> "$filter_file"
  printf -- '- .fleet-log.jsonl\n' >> "$filter_file"
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
  #
  # It also carries the node's version (lib/version.sh), for the same reason it
  # carries the role: a peer publishes no container and no checkout, so what
  # code it is running is knowable to the rest of the fleet only if it says so
  # itself. Since a roll defers while a cycle is in flight, nodes are routinely
  # on different images, and a dashboard that could not tell them apart could
  # not answer whether a fix had reached the node that needed it.
  #
  # And the compose-drift verdict (lib/compose-drift.sh), on the same
  # reasoning one layer down: the node's compose.yaml lives on its host,
  # where no image roll can update it and nothing but that node can read it
  # (issue #131). The node is the only party that can say whether its own
  # deployment file has fallen behind, so it says so here.
  #
  # And the image-drift verdict (lib/image-drift.sh), for the gap #155
  # writes up: a fleet that is uniformly stale looks identical to a healthy
  # one when nodes are only ever compared with each other, so the verdict
  # against the registry — the one party that actually knows what "newest"
  # means — travels here too. Its cache file lives beside the state this
  # push already reads and is excluded above like the other local caches;
  # sharing it with scripts/publish-dashboard.sh's own reads means the two
  # never pay for the same registry query twice inside its TTL.
  #
  # And the node-scoped switch (lib/toggle.sh's `toggle_switch_summary`,
  # issue #379). Unlike compose.yaml, `disabled.json` itself does replicate
  # in the push below — but a record is not a verdict: whether it is still in
  # force is decided against a clock, and a reader working that out from the
  # replicated file would be a second implementation of the switch, free to
  # disagree with what this node's own `--status` says (requirement 34a). So
  # what travels is the verdict this node reached, through the same call the
  # dashboard's page-top banner reads. The fleet-wide switch needs none of
  # this: it is a flag every node fetches for itself
  # (`fleet/disabled.json`).
  #
  # And the per-stage health verdict (lib/stage-health.sh, agent-ops#662), on
  # the identical shape: `agent-cycle.sh`'s own cleanup already computed and
  # persisted it to `.stage-health.json` this cycle, so what is read here is
  # that finished verdict, not a second computation over this node's log —
  # the file is `null` on a node that has not completed a cycle since
  # upgrading, which the dashboard already renders as no data rather than as
  # healthy.
  #
  # And the mirror-rebuild verdict (lib/mirror-integrity.sh's
  # `mirror_rebuild_verdict`, issue #604): `null` until `mirror_init` above
  # has ever had to discard and rebuild this checkout, else
  # {status:"rebuilt", count, last_rebuilt_at}. A corrupt mirror silently
  # self-healing on every tick would hide a disk that is quietly damaging it
  # on a schedule; publishing the verdict, and bumping `count` on every
  # further rebuild rather than reading the same as the first, is what makes
  # a repeat visible instead of indistinguishable noise.
  #
  # And the updater verdict (lib/updater-health.sh, agent-ops#603):
  # `deploy/docker/watchtower-pre-update.sh` keys its ledger by `$HOSTNAME` —
  # the container's own identity, the same one it stamps into `lock.json`
  # (`host: $host` above `held_by`'s foreign-lock branch) — never by
  # `node_name`, which is `NODE_NAME` or a bare `hostname` fallback and may
  # name the same node under a friendlier string than the container Docker
  # actually created. Reading the ledger under `node_name` here would ask
  # for a file the hook never wrote, and read every node as "not applicable"
  # for ever. `null` until this node has ever been polled by the hook, or —
  # on a fresh roll — for the short window before the replacement's own
  # first poll lands (agent-ops#603, "at least these states" is deliberate:
  # a container that has just been told to go ahead is not yet either
  # rolled or stuck).
  # Newest cycle id. Sliced in bash rather than piped into `head -n 1`, for
  # the reason kept_cycles sets out — and this is the site where it mattered:
  # a command substitution in the current shell, under `set -euo pipefail`, so
  # `sort`'s SIGPIPE became the push's own exit status. `do_push` died here,
  # after taking the mirror lock and fetching but before committing anything,
  # writing not one line to state-sync.log. Measured at 17 of 30 runs on
  # `ockham-container` and 16 of 30 on `ockham-2`: a node replicated its state
  # every 11-20 minutes against the `*/5` the cron entry asks for, and the
  # only evidence anywhere was supercronic's `exit status 141` (#806).
  local last_cycle version_json cycles_newest_first
  cycles_newest_first="$(find "$state_dir/cycles" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
    | sort -r)"
  last_cycle="${cycles_newest_first%%$'\n'*}"
  version_json="$(agent_ops_version "$SCRIPT_DIR")"
  jq -nc \
    --arg node "$node_name" \
    --arg role "${AGENT_OPS_ROLE:-standby}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg lc "${last_cycle:-}" \
    --argjson version "$version_json" \
    --argjson compose "$(compose_drift_status)" \
    --argjson image "$(image_drift_status "$version_json" "$state_dir/.image-drift-cache.json")" \
    --argjson switch "$(toggle_switch_summary "$state_dir")" \
    --argjson stage_health "$(jq -c '.' "$state_dir/.stage-health.json" 2>/dev/null || echo null)" \
    --argjson mirror_rebuild "$(mirror_rebuild_verdict "$state_dir")" \
    --argjson updater "$(updater_status "$state_dir/updater-ledger" "$updater_stuck_after_seconds" \
      "$updater_defer_stuck_after_seconds" "${HOSTNAME:-}" "${AGENT_OPS_SERVICE:-}" || echo null)" \
    '{node: $node, role: $role, ts: $ts, last_cycle: $lc, version: $version,
      compose: $compose, image: $image, switch: $switch,
      stage_health: $stage_health, mirror: $mirror_rebuild, updater: $updater}' > "$mirror/heartbeat.json"

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

  # Probe before fetching: the bootstrap case (no node branches published
  # yet) and a real failure (bad credentials, network outage, a corrupt
  # mirror) used to fail the plain `git fetch` below the same way, with
  # stderr discarded — so a dead credential and an empty state repository
  # were indistinguishable, and both silently reported success (#693).
  # `git ls-remote`'s own exit status tells them apart: non-zero is a real
  # failure; a zero exit with empty output is the genuine bootstrap case.
  local err_file ls_out
  err_file="$(mktemp)"
  # shellcheck disable=SC2064  # expand the path now, while it is still set
  trap "rm -f '$err_file'" RETURN
  if ! ls_out="$(git -C "$mirror" ls-remote --heads origin 'refs/heads/nodes/*' 2>"$err_file")"; then
    say "WARNING: could not reach the state repository to fetch peers — $(cat "$err_file")"
    fleet_mark_peers "$peers_dir" false
    return 1
  fi
  if [[ -z "$ls_out" ]]; then
    say "the state repository has no node branches yet — nothing to fetch"
    return 0
  fi

  # All the nodes' branches at once, pruning the tracking refs of nodes whose
  # branch has been deleted — a decommissioned machine leaves the fleet by
  # having its branch removed. The probe above already confirmed branches
  # exist and the remote is reachable, so a failure here is a second, later
  # real failure (a network blip between the two calls) rather than the
  # bootstrap case, and is reported the same way as the probe's own.
  : > "$err_file"
  if ! git -C "$mirror" fetch --quiet --prune --depth 1 origin \
      '+refs/heads/nodes/*:refs/remotes/origin/nodes/*' 2>"$err_file"; then
    say "WARNING: fetch failed — $(cat "$err_file")"
    fleet_mark_peers "$peers_dir" false
    return 1
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
  fleet_mark_peers "$peers_dir" true
  return 0
}

case "$MODE" in
  push) do_push ;;
  fetch) do_fetch ;;
esac
