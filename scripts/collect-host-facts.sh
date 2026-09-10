#!/usr/bin/env bash
#
# scripts/collect-host-facts.sh — the collector (issue #1283): a host- and
# cluster-vantage record of the facts no container running the pipeline can
# see for itself, since the runtime deliberately holds neither the Docker
# socket nor the Kubernetes API (a property since the agent-ops#603
# postmortem). This is the CLI over lib/host-facts.sh (the driver-independent
# envelope, `host`, `updater`, `viewer_probe`) and
# lib/host-facts-compose.sh / lib/host-facts-kubernetes.sh (the two
# vantage-specific sections) — docs/HOST-FACTS-SCHEMA.md is the record's own
# field-by-field contract.
#
# Run this from the collector's own container, on its own cadence (the
# compose service's loop, or the Kubernetes CronJob's schedule — see
# deploy/docker/compose.yaml's `collector` service and
# deploy/kubernetes/collector-cronjob.yaml). It writes
# state_dir/host-facts/<node>.json atomically (temp file, then `mv`); the
# ordinary state-sync push carries it out to the rest of the fleet on its own
# cadence, no dedicated sync code needed.
#
# Never returns non-zero for a degraded fact — every section this collects
# holds the "null, never fabricated" contract lib/host-facts.sh's own header
# states — but does exit non-zero when it cannot determine a driver at all,
# or cannot write the record anywhere, since those are this script's own
# job failing outright rather than one fact within it degrading.
#
# Exit: 0 the record was collected (and written, unless --print) · 2 usage
#         error, no driver could be determined, or the record could not be
#         written.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/config-access.sh
. "$SCRIPT_DIR/lib/config-access.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/host-facts.sh
. "$SCRIPT_DIR/lib/host-facts.sh"
# shellcheck source=lib/host-facts-compose.sh
. "$SCRIPT_DIR/lib/host-facts-compose.sh"
# shellcheck source=lib/host-facts-kubernetes.sh
. "$SCRIPT_DIR/lib/host-facts-kubernetes.sh"

usage() {
  cat >&2 <<'USAGE'
usage: collect-host-facts.sh [--print] [--driver compose|kubernetes]

Collect this node's host-facts record (docs/HOST-FACTS-SCHEMA.md) and write
it to state_dir/host-facts/<node>.json, atomically. The ordinary state-sync
push carries it out to the rest of the fleet.

  --print    write the record to stdout instead of the file (manual/CI use)
  --driver   compose|kubernetes — overrides AGENT_OPS_COLLECTOR_DRIVER and
             auto-detection

Exit 0 collected (and written, unless --print); 2 usage error, no driver
could be determined, or the record could not be written.
USAGE
}

print_only=0
driver="${AGENT_OPS_COLLECTOR_DRIVER:-}"
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --print) print_only=1; shift ;;
    # `shift 2` on a lone `--driver` shifts nothing and returns non-zero, and
    # this loop has no `set -e` to stop it — so the missing value is refused
    # here rather than spinning the loop forever on an argument list that
    # never shrinks.
    --driver)
      [[ $# -ge 2 ]] || { echo "collect-host-facts: --driver needs a value" >&2; usage; exit 2; }
      driver="$2"; shift 2 ;;
    *) echo "collect-host-facts: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

# host_facts_detect_driver — AGENT_OPS_COLLECTOR_DRIVER (or --driver) wins
# outright; otherwise auto-detect from what this container can actually
# reach, in the order a container is more likely to carry one signal than
# the other: the Kubernetes API's own injected env var, then the Docker
# socket's mount point.
host_facts_detect_driver() {
  case "$driver" in
    compose|kubernetes) printf '%s' "$driver"; return 0 ;;
    "") ;;
    *) return 1 ;;
  esac
  if [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]]; then
    printf 'kubernetes'
  elif [[ -S "${DOCKER_SOCKET:-/var/run/docker.sock}" ]]; then
    printf 'compose'
  else
    return 1
  fi
}

driver="$(host_facts_detect_driver)" || {
  echo "collect-host-facts: could not determine a driver — set AGENT_OPS_COLLECTOR_DRIVER (compose|kubernetes) or pass --driver" >&2
  exit 2
}

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)" || {
  echo "collect-host-facts: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 2
}
# `cfg` and `expand_home` come from lib/config-access.sh, sourced above —
# the same two helpers agent-cycle.sh and review-cycle.sh read their own
# config through (agent-ops#967), rather than a third private copy here.
state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"

node="$(host_facts_node_name)"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

host_json="$(host_facts_host_json "$state_dir" "$workspace_root")"

# The viewer-vantage probe (agent-ops#1286): every peer this node's own
# state-sync fetch has ever materialised, plus itself — never only the
# nodes this pass happens to know are healthy, since a peer that stopped
# publishing is exactly the case worth still trying to reach.
peers_dir="$(fleet_peers_dir "$workspace_root")"
node_list="$node"
if [[ -d "$peers_dir" ]]; then
  for d in "$peers_dir"/*/; do
    [[ -d "$d" ]] || continue
    peer="$(basename "$d")"
    [[ "$peer" == "$node" ]] || node_list="$node_list"$'\n'"$peer"
  done
fi
url_template="${AGENT_OPS_VIEWER_URL_TEMPLATE:-https://{node}/data.js}"
viewer_probe_json="$(host_facts_viewer_probe_json "$node_list" "$url_template")"

driver_section="{}"
watchtower_log_tail=""
case "$driver" in
  compose)
    driver_section="$(host_facts_compose_section "")"
    watchtower_log_tail="$(jq -r '.watchtower_log_tail // ""' <<<"$driver_section" 2>/dev/null)"
    driver_section="$(jq -c '{containers: (.containers // [])}' <<<"$driver_section" 2>/dev/null || printf '{"containers":[]}')"
    ;;
  kubernetes)
    driver_section="$(host_facts_kubernetes_section "")"
    ;;
esac

updater_json="$(host_facts_updater_json "$state_dir" "$watchtower_log_tail")"

record="$(jq -nc \
  --arg node "$node" --arg driver "$driver" --arg generated_at "$generated_at" \
  --argjson host "$host_json" --argjson updater "$updater_json" \
  --argjson viewer_probe "$viewer_probe_json" --argjson section "$driver_section" \
  '{node:$node, driver:$driver, generated_at:$generated_at, host:$host,
    updater:$updater, viewer_probe:$viewer_probe} + $section')"

if (( print_only )); then
  printf '%s\n' "$record"
  exit 0
fi

out_dir="$state_dir/host-facts"
mkdir -p "$out_dir" 2>/dev/null || {
  echo "collect-host-facts: cannot create $out_dir" >&2
  exit 2
}
out_file="$out_dir/$node.json"
if printf '%s\n' "$record" > "$out_file.tmp.$$" 2>/dev/null; then
  mv -f "$out_file.tmp.$$" "$out_file"
else
  echo "collect-host-facts: could not write $out_file" >&2
  rm -f "$out_file.tmp.$$" 2>/dev/null
  exit 2
fi
