#!/usr/bin/env bash
#
# lib/compose-drift.sh — whether this node's compose.yaml still matches the
# copy its image shipped.
#
# A node runs its own copy of deploy/docker/compose.yaml on the host, not a
# clone of this repository, and an image roll cannot carry compose-level
# changes: labels, service environment and mounts only ever arrive via a human
# running `docker compose up -d` on that host. A merged compose fix can
# therefore sit inert on every node indefinitely while every check in the
# repository stays green — which is exactly what happened to the watchtower
# pre-update hook, twice, before issue #131 was written. Nothing inside the
# container can see the host's file — unless the file is handed in: the
# compose file mounts *itself* read-only at /host/compose.yaml on the shared
# service block, and this library diffs that mount against the image's own
# copy at /app/deploy/docker/compose.yaml. The reference needs no manual step
# to stay current, because CI builds the image from `main` and watchtower
# rolls it: the comparison arrives by exactly the channel that already works.
#
# The bootstrap problem dissolves rather than needing solving. A node whose
# compose.yaml predates the mount cannot be diffed, but the absence of the
# mount is itself the verdict — a file too old to carry it is behind by
# construction — and the *check* reaches every node by image roll, no `up -d`
# required. So the first thing every node reports after this code rolls out
# is "unmounted", which is true, loud, and precisely the alarm that was
# missing.
#
# Comments and blank lines are stripped before the diff (the same
# normalisation issue #131's own detection recipe uses). Upstream rewrites
# compose comments freely — #130 alone rewrote three of them — and a badge
# that fired on every comment edit would train the operator to ignore it;
# what drifts in comments alone cannot change what a container runs.
#
# What this cannot see: whether the *running containers* were created from
# the file — a file synced without `up -d` reads in-sync while the containers
# still carry the old config — and watchtower's own environment. Both need
# the Docker socket, which these containers rightly lack;
# scripts/check-node-compose.sh answers them from the host, where the socket
# lives.
#
# Sourced by scripts/state-sync.sh (the verdict travels in each node's
# heartbeat, so every dashboard can report every node) and by
# scripts/publish-dashboard.sh (which reads our own directly).

# One compact JSON object, or the JSON literal `null` when the question does
# not apply. Never returns non-zero: this runs under `set -e` inside a node's
# heartbeat push, and no verdict is worth aborting one.
#
#   {status: "in-sync"}                  the mounted copy matches the image's
#   {status: "drifted", diff_lines: N}   it does not; N lines differ once
#                                        comments and blanks are stripped
#   {status: "unmounted"}                no mount in a container — the node's
#                                        compose.yaml predates the check, so
#                                        it is behind at least that far
#   null                                 not a container (a developer's
#                                        checkout, the legacy WSL install —
#                                        no compose file exists to drift), or
#                                        an image carrying no copy to compare
#
# COMPOSE_DRIFT_HOST / COMPOSE_DRIFT_IMAGE / COMPOSE_DRIFT_SENTINEL override
# the three paths. They exist for the tests, which must control all three:
# the CI suite runs inside the image, where /.dockerenv exists and the
# defaults would answer for the build container rather than the fixture.
compose_drift_status() {
  local host="${COMPOSE_DRIFT_HOST:-/host/compose.yaml}"
  local image="${COMPOSE_DRIFT_IMAGE:-}"
  local sentinel="${COMPOSE_DRIFT_SENTINEL:-/.dockerenv}"
  [[ -n "$image" ]] || image="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/docker/compose.yaml"

  if [[ ! -f "$host" ]]; then
    if [[ -e "$sentinel" ]]; then printf '{"status":"unmounted"}'; else printf 'null'; fi
    return 0
  fi
  if [[ ! -f "$image" ]]; then
    # Nothing to compare against. Saying nothing beats a false alarm.
    printf 'null'
    return 0
  fi

  # `diff` exits 1 on a difference and `grep -c` exits 1 on a zero count, and
  # the caller may run under pipefail — the trailing `|| true` keeps a
  # legitimate answer from reading as a failure. The count is validated
  # rather than trusted, so a diff that failed outright (unreadable file,
  # binary junk) degrades to null, never to a verdict.
  local diff_lines
  diff_lines="$(diff \
      <(grep -vE '^[[:space:]]*(#|$)' "$image" 2>/dev/null) \
      <(grep -vE '^[[:space:]]*(#|$)' "$host" 2>/dev/null) 2>/dev/null \
    | grep -c '^[<>]' || true)"
  [[ "$diff_lines" =~ ^[0-9]+$ ]] || { printf 'null'; return 0; }

  if (( diff_lines == 0 )); then
    printf '{"status":"in-sync"}'
  else
    printf '{"status":"drifted","diff_lines":%s}' "$diff_lines"
  fi
  return 0
}
