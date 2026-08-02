#!/usr/bin/env bash
#
# lib/image-drift.sh — is this node running the newest image this repository
# has published, or one that has fallen behind?
#
# lib/version.sh answers "what is this node running" and the dashboard used
# to answer "have all the nodes got the fix" by comparing nodes with each
# other (fleetNewestVersion in dashboard/index.html) — which only ever
# catches *divergence*. When every node adopts a broken image at once (#149,
# #154), every node agrees with every other node and that comparison reads
# perfectly healthy while the whole fleet quietly does nothing (issue #155).
# What was missing is a reference outside the fleet: the registry itself,
# which is the one party that always knows what "newest" actually means,
# because CI publishes there and nowhere else.
#
# A node updates by watchtower pulling `ghcr.io/poetic-poems/agent-ops:latest`
# (deploy/docker/compose.yaml), never by `git pull`, so the registry's `latest`
# tag — not `origin/main` — is the correct baseline. They are not the same
# thing: a documentation-only merge builds and publishes no image at all
# (`.github/workflows/build-image.yml`'s docs-only skip), so `latest`
# legitimately sits behind `main`'s tip and a node running it is not stale.
# Comparing against git would raise that as a false alarm on every doc change;
# comparing against the registry does not, because the registry is the
# publish record, not the source history.
#
# The registry is read anonymously over the OCI Distribution / Docker
# Registry HTTP API v2 (a pull token, the `:latest` manifest — an index for
# this repository's multi-platform build, so one child manifest is read
# through it — then that manifest's image-config blob), never through
# GitHub's own API: the packages API needs `read:packages`, a scope nothing
# else in this pipeline holds and 403s without, while the registry's pull
# token is issued to anyone for a public package. The commit a manifest was
# built from travels as the `org.opencontainers.image.revision` label
# (`.github/workflows/build-image.yml`'s publish step sets it to the same
# `github.sha` that stamps `build-info.json`), so the comparison this file
# exists to make — is our commit the newest published one — needs no digest
# of our own running image at all, which nothing inside this container could
# read anyway (no Docker socket here; that is what scripts/check-node-image.sh
# and scripts/check-node-compose.sh reach for, from the host).
# `org.opencontainers.image.created` carries the same build's timestamp, for
# the same reason `built_at` rides in `build-info.json`: the dashboard's
# tolerance for a deferred roll (a roll waits for a cycle in flight, so
# "behind" is routinely true for a while) needs to know how long the newest
# image has actually existed, not merely that a newer one does.
#
# Every network call this file makes is a real cost the 5-second dashboard
# tick (scripts/publish-dashboard-launcher.sh) cannot absorb on every run —
# unlike lib/version.sh and lib/compose-drift.sh, which only ever read local
# files. `image_drift_status` is therefore backed by a cache file the caller
# names: a call inside the cache's TTL (`IMAGE_DRIFT_TTL`, default 240s —
# comfortably under both the heartbeat's 5-minute push and the launcher's
# 5-second tick, so neither is ever the one left waiting on the network) reads
# the registry's last answer straight off disk, and only a stale or missing
# cache reaches out. scripts/state-sync.sh and scripts/publish-dashboard.sh
# both name the same cache file for a node, so whichever of them next crosses
# the TTL pays the one query and the other rides along for free.
#
# One compact JSON object, or the JSON literal `null`. Never returns
# non-zero and never lets a failed read escape as anything but a status —
# this runs under `set -e` from state-sync.sh, and a registry outage is not a
# reason to abort a heartbeat.
#
#   {status: "current", checked_at}
#     this node's commit is the one the registry's :latest names.
#   {status: "behind", registry_commit, registry_created_at, checked_at}
#     it is not; registry_created_at is null when the image carries no
#     creation label (an old publish, from before this file existed).
#   {status: "unverified", reason, checked_at}
#     the registry could not be read, or its image carries no revision
#     label to compare against — a real outage, a token/manifest/config
#     fetch that failed, or (routinely, right after this code first rolls
#     out) the newest image simply predating the label. As with #131/#137,
#     a fleet-wide "unverified" the first time this rolls is the mechanism
#     working, not a fault.
#   null
#     this node is not running a CI-stamped image at all — a developer's
#     checkout, the legacy WSL install — so "behind the registry" is not a
#     question that applies to it.
#
# IMAGE_DRIFT_REGISTRY / IMAGE_DRIFT_TAG / IMAGE_DRIFT_CURL_CMD / IMAGE_DRIFT_TTL
# / IMAGE_DRIFT_TIMEOUT exist for the tests, which must reach no network:
# IMAGE_DRIFT_CURL_CMD points at a fixture standing in for `curl`, keyed on
# the URLs it is asked for.

# The one HTTP round trip proper — a pull token, the tag's manifest (walking
# one level into a multi-platform index when there is one), and the config
# blob its `Labels` live on. Always one compact JSON object:
#   {ok: true, commit, created}   created is null when the label is absent
#   {ok: false, reason}
_image_drift_fetch_registry_head() {  # <owner/repo>
  local repo_lower="" registry="" tag="" curl_cmd="" timeout=""
  repo_lower="$(tr '[:upper:]' '[:lower:]' <<<"$1" 2>/dev/null || true)"
  registry="${IMAGE_DRIFT_REGISTRY:-ghcr.io}"
  tag="${IMAGE_DRIFT_TAG:-latest}"
  curl_cmd="${IMAGE_DRIFT_CURL_CMD:-curl}"
  timeout="${IMAGE_DRIFT_TIMEOUT:-4}"

  local token=""
  token="$("$curl_cmd" -fsSL --max-time "$timeout" \
      "https://$registry/token?service=$registry&scope=repository:$repo_lower:pull" 2>/dev/null \
    | jq -r '.token // empty' 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    jq -nc '{ok:false, reason:"could not get a registry pull token"}'
    return 0
  fi

  local accept="" top=""
  accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
  top="$("$curl_cmd" -fsSL --max-time "$timeout" -H "Authorization: Bearer $token" -H "Accept: $accept" \
      "https://$registry/v2/$repo_lower/manifests/$tag" 2>/dev/null || true)"
  if [[ -z "$top" ]]; then
    jq -nc --arg tag "$tag" '{ok:false, reason:("could not read the manifest for " + $tag)}'
    return 0
  fi

  # An index lists one manifest per platform (this repository publishes
  # linux/amd64 and linux/arm64 from the same commit and build args — see
  # .github/workflows/build-image.yml's publish job — so any one of them
  # carries the labels this file wants); a single-platform republish has no
  # `manifests[]` at all and `top` already is the manifest to read.
  local child_digest="" manifest="$top"
  child_digest="$(jq -r '(.manifests // [])[0].digest // empty' <<<"$top" 2>/dev/null || true)"
  if [[ -n "$child_digest" ]]; then
    manifest="$("$curl_cmd" -fsSL --max-time "$timeout" -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
        "https://$registry/v2/$repo_lower/manifests/$child_digest" 2>/dev/null || true)"
    if [[ -z "$manifest" ]]; then
      jq -nc '{ok:false, reason:"could not read the per-platform manifest"}'
      return 0
    fi
  fi

  local config_digest=""
  config_digest="$(jq -r '.config.digest // empty' <<<"$manifest" 2>/dev/null || true)"
  if [[ -z "$config_digest" ]]; then
    jq -nc '{ok:false, reason:"the manifest names no image config"}'
    return 0
  fi

  local config=""
  config="$("$curl_cmd" -fsSL --max-time "$timeout" -H "Authorization: Bearer $token" \
      "https://$registry/v2/$repo_lower/blobs/$config_digest" 2>/dev/null || true)"
  if [[ -z "$config" ]]; then
    jq -nc '{ok:false, reason:"could not read the image config blob"}'
    return 0
  fi

  jq -c '{ok:true,
    commit: (.config.Labels["org.opencontainers.image.revision"] // ""),
    created: (.config.Labels["org.opencontainers.image.created"] // null)}' \
    <<<"$config" 2>/dev/null \
    || jq -nc '{ok:false, reason:"the image config could not be parsed"}'
}

# The fetch above, through a cache: a hit within IMAGE_DRIFT_TTL is a disk
# read; a miss pays the round trip and refreshes the file for whoever asks
# next. A failed fetch is cached too, on the same TTL — an outage is not a
# reason to retry every 5 seconds, and the next state-sync push or dashboard
# tick past the TTL tries again on its own. An empty cache-file path (the
# test suite's way of asking for "never cache") always misses and never
# writes.
_image_drift_registry_head() {  # <owner/repo> <cache-file>
  local repo="$1" cache_file="$2" ttl="${IMAGE_DRIFT_TTL:-240}"

  if [[ -n "$cache_file" && -s "$cache_file" ]]; then
    local mtime=0 age=0
    mtime="$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)"
    age=$(( $(date +%s) - mtime ))
    if (( age < ttl )); then
      cat "$cache_file" 2>/dev/null && return 0
    fi
  fi

  local fresh=""
  fresh="$(_image_drift_fetch_registry_head "$repo" || true)"
  [[ -n "$fresh" ]] || fresh='{"ok":false,"reason":"empty response"}'

  if [[ -n "$cache_file" ]]; then
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true
    if printf '%s' "$fresh" > "$cache_file.tmp.$$" 2>/dev/null; then
      mv "$cache_file.tmp.$$" "$cache_file" 2>/dev/null || true
    fi
  fi
  printf '%s' "$fresh"
}

# image_drift_status <version-json> <cache-file>
#
# <version-json> is lib/version.sh's `agent_ops_version` output — the caller
# already has it for the heartbeat's own `version` field, and passing it in
# rather than re-deriving it keeps this file from reading build-info.json or
# git a second time.
image_drift_status() {
  local version_json="${1:-null}" cache_file="${2:-}"
  local own_source="" own_commit="" own_repo=""
  own_source="$(jq -r '.source // ""' <<<"$version_json" 2>/dev/null || true)"
  own_commit="$(jq -r '.commit // ""' <<<"$version_json" 2>/dev/null || true)"
  own_repo="$(jq -r '.repo // ""' <<<"$version_json" 2>/dev/null || true)"

  # Only a CI-stamped image names a build this repository published; a
  # checkout (a developer's clone, the legacy WSL install) is running
  # whatever branch it has, and "behind the registry" is not a question that
  # applies to it — the same rule compose_drift_status uses its own sentinel
  # for.
  if [[ "$own_source" != "image" || -z "$own_commit" || -z "$own_repo" ]]; then
    printf 'null'
    return 0
  fi

  local now=""
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"

  local head_json="" ok=""
  head_json="$(_image_drift_registry_head "$own_repo" "$cache_file" || true)"
  [[ -n "$head_json" ]] || head_json='{"ok":false,"reason":"empty response"}'
  ok="$(jq -r '.ok // false' <<<"$head_json" 2>/dev/null || true)"

  if [[ "$ok" != "true" ]]; then
    local reason=""
    reason="$(jq -r '.reason // "registry unreachable"' <<<"$head_json" 2>/dev/null || true)"
    jq -nc --arg reason "$reason" --arg at "$now" \
      '{status:"unverified", reason:$reason, checked_at:$at}'
    return 0
  fi

  local reg_commit="" reg_created=""
  reg_commit="$(jq -r '.commit // ""' <<<"$head_json" 2>/dev/null || true)"
  reg_created="$(jq -r '.created // ""' <<<"$head_json" 2>/dev/null || true)"

  if [[ -z "$reg_commit" ]]; then
    jq -nc --arg at "$now" \
      '{status:"unverified", reason:"the newest published image carries no revision label", checked_at:$at}'
    return 0
  fi

  if [[ "$reg_commit" == "$own_commit" ]]; then
    jq -nc --arg at "$now" '{status:"current", checked_at:$at}'
    return 0
  fi

  jq -nc --arg rc "$reg_commit" --arg created "$reg_created" --arg at "$now" \
    '{status:"behind", registry_commit:$rc,
      registry_created_at:(if $created == "" then null else $created end),
      checked_at:$at}'
  return 0
}
