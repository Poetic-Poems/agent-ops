#!/usr/bin/env bash
#
# check-node-compose.sh — is this node's compose.yaml, and the containers it
# created, still what the repository would deploy?
#
# A node holds its own copy of deploy/docker/compose.yaml, and an image roll
# cannot update it: labels, service environment and mounts arrive only via a
# human running `docker compose up -d` on that host (issue #131). The
# in-container check (lib/compose-drift.sh) answers for the *file* from
# inside and publishes its verdict in the node's heartbeat; what it cannot
# see is whether the running containers were actually created from that file
# — a file synced without `up -d` reads in-sync while the containers still
# carry the old config — or watchtower's own environment, the one container
# nothing ever rolls. Both need the Docker socket. This script answers from
# the host, where the socket lives.
#
# Run it on the node's host, from the stack directory (wherever compose.yaml
# and .env live — see deploy/docker/README.md), or point STACK_DIR at one; a
# host running two stacks runs it once per directory. Read-only throughout —
# `docker compose exec/ps`, `docker inspect/logs` and a diff — so it is safe
# to allow-list wholesale, like watch-node.sh.
#
# The checks, each a property that has actually been lost in the field:
#   file       the stack's compose.yaml against the copy inside the running
#              image (comments and blank lines aside) — has the merged change
#              reached this host's file at all?
#   mount      the scheduler carries /host/compose.yaml, so the in-container
#              check is armed and the heartbeat verdict means something
#   labels     every running container on the agent-ops image carries the
#              watchtower pre-update hook label — the property whose silent
#              loss cost the cycles that led to #131
#   watchtower lifecycle hooks are enabled in its *actual* environment (not
#              the file's), and schedule/interval are not both set
#
# The container checks are the ground truth and the file check is the early
# warning: a clean file with stale containers fails the label/env checks, a
# stale file fails the diff. What this script does not attempt is a full
# config comparison of every running container against the file — the
# roadmap's zero-touch-fleet phase retires the hand-held file entirely,
# which is that comparison done properly.
#
# Exit: 0 every check passed · 1 at least one failed · 2 could not check.

set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: check-node-compose.sh

Verify, from a node's host, that its compose.yaml and the containers created
from it have not fallen behind the repository: the file against the running
image's own copy, the pre-update hook label on every agent-ops container, and
watchtower's actual environment.

Run from the node's stack directory (wherever compose.yaml and .env live), or
set STACK_DIR to point at it. A host running two stacks: once per directory.

Exit 0 all checks passed, 1 at least one failed, 2 could not check.
USAGE
}
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "check-node-compose: unknown argument: $1" >&2; usage; exit 2 ;;
esac

stack_dir="${STACK_DIR:-$PWD}"
if [[ ! -f "$stack_dir/compose.yaml" ]]; then
  echo "check-node-compose: no compose.yaml in $stack_dir" >&2
  echo "  run this from the node's stack directory, or set STACK_DIR to it" >&2
  exit 2
fi
compose=(docker compose --project-directory "$stack_dir")

failures=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; failures=$(( failures + 1 )); }
info() { printf 'info - %s\n' "$1"; }

# The same normalisation lib/compose-drift.sh applies, for the same reason:
# comments drift constantly and change nothing a container runs.
material() { grep -vE '^[[:space:]]*(#|$)' "$@"; }

# --- The file, against the copy the running image carries ---------------------
# The image is built from `main` by CI, so its /app copy is what the
# repository would deploy as of this node's image — the comparison needs no
# clone and no network. Read through the scheduler because every node runs
# one; if that exec fails there is nothing on this host to check against.
if ! image_copy="$("${compose[@]}" exec -T scheduler \
    cat /app/deploy/docker/compose.yaml 2>/dev/null)"; then
  echo "check-node-compose: cannot read the running image's compose.yaml" >&2
  echo "  is the stack up? (docker compose ps — the scheduler must be running)" >&2
  exit 2
fi

diff_out="$(diff <(printf '%s\n' "$image_copy" | material -) \
                 <(material "$stack_dir/compose.yaml") 2>/dev/null)"
if [[ -z "$diff_out" ]]; then
  ok "compose.yaml matches the running image's copy"
else
  bad "compose.yaml differs materially from the running image's copy (< image, > this host):"
  sed 's/^/       /' <<<"$diff_out"
fi

# --- The mount that arms the in-container check -------------------------------
if "${compose[@]}" exec -T scheduler test -f /host/compose.yaml 2>/dev/null; then
  ok "the scheduler mounts this host's compose.yaml — the heartbeat drift check is armed"
else
  bad "the scheduler does not mount /host/compose.yaml — its containers were created from a compose.yaml older than the drift check, so the heartbeat cannot verify this node"
fi

# --- The labels on the running containers -------------------------------------
# Read off the containers, not the file: this is the half a synced file says
# nothing about. Which containers matter is decided by the image they run —
# the hook label lives on the shared agent-ops block, and the sidecar images
# (tailscale, watchtower) are not expected to carry it.
hook_label='com.centurylinklabs.watchtower.lifecycle.pre-update'
hook_path='/app/deploy/docker/watchtower-pre-update.sh'
agent_ops_seen=0
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  service="$(docker inspect "$id" \
    --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null)"
  case "$service" in scheduler|dashboard|dashboard-local) ;; *) continue ;; esac
  agent_ops_seen=$(( agent_ops_seen + 1 ))
  label="$(docker inspect "$id" --format "{{index .Config.Labels \"$hook_label\"}}" 2>/dev/null)"
  if [[ "$label" == "$hook_path" ]]; then
    ok "$service carries the pre-update hook label"
  else
    bad "$service does not carry the pre-update hook label — a roll will land mid-cycle; recreate the stack (docker compose up -d) once the node is idle"
  fi
done < <("${compose[@]}" ps -q 2>/dev/null)
(( agent_ops_seen > 0 )) || bad "no running agent-ops container to inspect"

# --- Watchtower's actual environment ------------------------------------------
# The one container nothing ever rolls: its environment is frozen at whatever
# the last manual `up -d` gave it, which is how the lifecycle flag was lost
# the first time. `-a`, because a watchtower that crashed at start (for
# instance: schedule and interval both set) is precisely what must not read
# as "profile off".
wt_id="$("${compose[@]}" ps -aq watchtower 2>/dev/null | head -n 1)"
if [[ -z "$wt_id" ]]; then
  info "watchtower is not part of this stack (auto-update profile off) — skipping its checks"
else
  if [[ "$(docker inspect "$wt_id" --format '{{.State.Running}}' 2>/dev/null)" != "true" ]]; then
    bad "watchtower exists but is not running — this node is not auto-updating (docker logs the container; 'Only schedule or interval can be defined, not both' means .env sets both)"
  else
    wt_env="$(docker inspect "$wt_id" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)"
    if grep -q '^WATCHTOWER_LIFECYCLE_HOOKS=true$' <<<"$wt_env"; then
      ok "watchtower runs with lifecycle hooks enabled"
    else
      bad "watchtower's environment does not enable lifecycle hooks — every pre-update label on this host is inert and rolls land mid-cycle; re-fetch compose.yaml and recreate watchtower (docker compose up -d watchtower)"
    fi
    interval="$(grep '^WATCHTOWER_POLL_INTERVAL=' <<<"$wt_env" | cut -d= -f2-)"
    schedule="$(grep '^WATCHTOWER_SCHEDULE=' <<<"$wt_env" | cut -d= -f2-)"
    if [[ -n "$interval" && -n "$schedule" ]]; then
      bad "watchtower has both a poll interval and a schedule set — it will exit fatally on its next restart and the node will silently stop updating"
    else
      ok "watchtower's poll interval and schedule are not in conflict"
    fi
    # Advisory, not a verdict: zero mentions are only damning over a period
    # that contained a roll, which this script cannot know.
    hook_mentions="$(docker logs "$wt_id" 2>&1 | grep -cE 'pre-update|lifecycle' || true)"
    info "watchtower's log mentions the lifecycle hook $hook_mentions time(s) — 0 across a period containing a roll means the hook never ran"
  fi
fi

printf '\n'
if (( failures > 0 )); then
  printf '%d check(s) failed\n' "$failures"
  exit 1
fi
printf 'all checks passed\n'
