#!/usr/bin/env bash
#
# lib/host-facts-compose.sh — the compose driver's own section of the
# host-facts record (docs/HOST-FACTS-SCHEMA.md, "containers"). Reads the
# Docker Engine API directly over `curl --unix-socket` rather than the
# `docker` CLI, which this image does not install (D20: no new base-image
# package for a control-plane question still open at Phase 2 — see
# docs/ROADMAP.md). The API's own JSON is the same shape `docker inspect`
# prints — a thin CLI wrapper over exactly this endpoint — which is why
# `test/collect-host-facts-compose.test.sh` can drive the pure functions
# below with fixture files literally captured from `docker inspect`.
#
# Every function here holds lib/host-facts.sh's own contract: one compact
# JSON value, never non-zero, never a fabricated fact for one this cannot
# read.

# _host_facts_compose_systemd_slice_path NAME — systemd's own naming rule
# for a slice's path under the root cgroup: a dash in the name is a
# hierarchy separator, so `agentops-1.slice` lives at
# `agentops.slice/agentops-1.slice`, not as a flat sibling of `agentops.slice`.
# The same rule `scripts/cgroup-parent-setup.sh`'s `systemd_slice_path`
# already applies for the one parent slice a node sets up by hand; this
# copy exists because that file is a standalone host script (no `docker`
# socket, no JSON to build) and this one runs inside the collector's own
# container answering a different question — the container's own cgroup,
# not the parent's.
_host_facts_compose_systemd_slice_path() {
  local name="${1%.slice}" parts="" acc="" out=""
  IFS='-' read -r -a parts <<<"$name"
  for part in "${parts[@]}"; do
    if [[ -z "$acc" ]]; then acc="$part"; else acc="$acc-$part"; fi
    out="$out${out:+/}$acc.slice"
  done
  printf '%s' "$out"
}

# _host_facts_compose_cgroup_relpath DRIVER CGROUP_PARENT ID — the
# container's own cgroup path, relative to the cgroup root, under either
# driver Docker supports. Empty CGROUP_PARENT is the ordinary case — most
# containers in this repo's own stack set none (only the scheduler
# optionally does, via `cgroup_parent` in deploy/docker/compose.yaml).
_host_facts_compose_cgroup_relpath() {
  local driver="${1:-}" parent="${2:-}" id="${3:-}"
  case "$driver" in
    systemd)
      if [[ -n "$parent" ]]; then
        printf '%s/docker-%s.scope' "$(_host_facts_compose_systemd_slice_path "$parent")" "$id"
      else
        printf 'system.slice/docker-%s.scope' "$id"
      fi
      ;;
    cgroupfs)
      if [[ -n "$parent" ]]; then
        printf '%s/%s' "${parent#/}" "$id"
      else
        printf 'docker/%s' "$id"
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# _host_facts_compose_cgroup_field ROOT RELPATH FIELD — one cgroup file's
# raw contents, or empty when ROOT/RELPATH is not given or the file cannot
# be read (no such mount, wrong driver guess, container already gone).
_host_facts_compose_cgroup_field() {
  local root="${1:-}" relpath="${2:-}" field="${3:-}"
  [[ -n "$root" && -n "$relpath" ]] || return 0
  cat "$root/$relpath/$field" 2>/dev/null
}

# host_facts_compose_container_memory_json ROOT DRIVER PARENT ID —
# {"current_bytes","high_bytes","max_bytes","oom_kill_count"}, each `null`
# on its own when unreadable — never guessed, and never one failure taking
# the other three down with it.
host_facts_compose_container_memory_json() {
  local root="${1:-}" driver="${2:-}" parent="${3:-}" id="${4:-}" rel=""
  rel="$(_host_facts_compose_cgroup_relpath "$driver" "$parent" "$id" 2>/dev/null)"
  local current="" high="" max="" events="" oom=""
  if [[ -n "$rel" ]]; then
    current="$(_host_facts_compose_cgroup_field "$root" "$rel" memory.current)"
    high="$(_host_facts_compose_cgroup_field "$root" "$rel" memory.high)"
    max="$(_host_facts_compose_cgroup_field "$root" "$rel" memory.max)"
    events="$(_host_facts_compose_cgroup_field "$root" "$rel" memory.events)"
    oom="$(awk '/^oom_kill /{print $2; exit}' <<<"$events" 2>/dev/null)"
  fi
  jq -nc \
    --argjson current "$( [[ "$current" =~ ^[0-9]+$ ]] && printf '%s' "$current" || printf 'null' )" \
    --argjson high "$( [[ "$high" =~ ^[0-9]+$ ]] && printf '%s' "$high" || printf 'null' )" \
    --argjson max "$( [[ "$max" =~ ^[0-9]+$ ]] && printf '%s' "$max" || printf 'null' )" \
    --argjson oom "$( [[ "$oom" =~ ^[0-9]+$ ]] && printf '%s' "$oom" || printf 'null' )" \
    '{current_bytes:$current, high_bytes:$high, max_bytes:$max, oom_kill_count:$oom}'
}

# host_facts_compose_registry_digest OWNER/REPO [TAG] [CURL-CMD] — the
# registry's current manifest digest for TAG (default `latest`), read off
# the `Docker-Content-Digest` response header on a HEAD-equivalent GET
# (anonymous pull token, same public-registry contract
# `lib/image-drift.sh` already uses for the commit-level comparison this
# one complements) — or empty when the token, the manifest fetch, or the
# header itself is unavailable. Never fatal: a registry outage degrades the
# caller's own `digest_match` to `null`, not to a wrong record.
host_facts_compose_registry_digest() {
  local repo="${1:-}" tag="${2:-latest}" curl_cmd="${3:-curl}" \
    registry="${HOST_FACTS_IMAGE_REGISTRY:-ghcr.io}" repo_lower="" token="" headers=""
  [[ -n "$repo" ]] || return 0
  repo_lower="$(tr '[:upper:]' '[:lower:]' <<<"$repo" 2>/dev/null || printf '%s' "$repo")"
  token="$("$curl_cmd" -fsSL --max-time 4 \
      "https://$registry/token?service=$registry&scope=repository:$repo_lower:pull" 2>/dev/null \
    | jq -r '.token // empty' 2>/dev/null)"
  [[ -n "$token" ]] || return 0
  local accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
  headers="$("$curl_cmd" -fsSL --max-time 4 -D - -o /dev/null \
      -H "Authorization: Bearer $token" -H "Accept: $accept" \
      "https://$registry/v2/$repo_lower/manifests/$tag" 2>/dev/null)"
  grep -i '^docker-content-digest:' <<<"$headers" 2>/dev/null \
    | head -n 1 | cut -d: -f2- | tr -d '\r' | tr -d '[:space:]'
}

# host_facts_compose_container_entry INSPECT DIGEST REGISTRY-DIGEST ROOT
# DRIVER — one entry of the `containers[]` array, built from INSPECT (one
# element of what `docker inspect` — or a bare `GET /containers/{id}/json`
# — prints). DIGEST is this container's own image's repo digest, already
# resolved by the caller (`host_facts_compose_image_digests_json` below) —
# a *container* inspect carries no `RepoDigests` field at all; only an
# *image* inspect does, which is why this is a parameter here rather than
# read out of INSPECT directly.
host_facts_compose_container_entry() {
  local inspect="${1:-}" digest="${2:-}" registry_digest="${3:-}" root="${4:-}" driver="${5:-}"
  local id="" parent="" name="" service="" state="" restarts="" started="" memory=""
  id="$(jq -r '.Id // ""' <<<"$inspect" 2>/dev/null)"
  parent="$(jq -r '.HostConfig.CgroupParent // ""' <<<"$inspect" 2>/dev/null)"
  name="$(jq -r '(.Name // "") | ltrimstr("/")' <<<"$inspect" 2>/dev/null)"
  service="$(jq -r '.Config.Labels["com.docker.compose.service"] // ""' <<<"$inspect" 2>/dev/null)"
  state="$(jq -r '.State.Status // "unknown"' <<<"$inspect" 2>/dev/null)"
  restarts="$(jq -r '.State.RestartCount // 0' <<<"$inspect" 2>/dev/null)"
  started="$(jq -r '.State.StartedAt // ""' <<<"$inspect" 2>/dev/null)"
  # Docker's zero-value timestamp for "never started".
  [[ "$started" == "0001-01-01T00:00:00Z" ]] && started=""

  memory="$(host_facts_compose_container_memory_json "$root" "$driver" "$parent" "$id")"

  local nano_cpus=""
  nano_cpus="$(jq -r '.HostConfig.NanoCpus // 0' <<<"$inspect" 2>/dev/null)"
  [[ "$nano_cpus" =~ ^[0-9]+$ ]] || nano_cpus=0

  jq -nc \
    --arg name "${name:-unknown}" \
    --argjson service "$( [[ -n "$service" ]] && jq -nc --arg s "$service" '$s' || printf 'null' )" \
    --arg state "${state:-unknown}" \
    --argjson restarts "$( [[ "$restarts" =~ ^[0-9]+$ ]] && printf '%s' "$restarts" || printf '0' )" \
    --argjson started "$( [[ -n "$started" ]] && jq -nc --arg s "$started" '$s' || printf 'null' )" \
    --argjson digest "$( [[ -n "$digest" ]] && jq -nc --arg d "$digest" '$d' || printf 'null' )" \
    --argjson registry_digest "$( [[ -n "$registry_digest" ]] && jq -nc --arg d "$registry_digest" '$d' || printf 'null' )" \
    --argjson memory "$memory" \
    --argjson limit_nanos "$( (( nano_cpus > 0 )) && printf '%s' "$nano_cpus" || printf 'null' )" \
    '{name:$name, service:$service, state:$state, restart_count:$restarts,
      started_at:$started,
      image:{digest:$digest, registry_digest:$registry_digest,
             digest_match:(if $digest == null or $registry_digest == null then null
                           else $digest == $registry_digest end)},
      memory:$memory, cpu:{limit_nanos:$limit_nanos}}'
}

# host_facts_compose_image_digests_json INSPECT-ARRAY [CURL-CMD] — an
# object mapping each distinct container's own `.Image` id (the local
# image ID `docker inspect <container>` carries) to that image's own repo
# digest — read from `GET /images/{id}/json`'s `.RepoDigests[0]`, the one
# endpoint that actually carries it; a container's own inspect does not.
# One call per *distinct* image, never per container, so a stack where
# every service shares one image (the ordinary case here) pays the cost
# once.
host_facts_compose_image_digests_json() {
  local inspects="${1:-[]}" curl_cmd="${2:-${HOST_FACTS_DOCKER_CURL_CMD:-curl}}"
  local out="{}" image_id="" digest=""
  while IFS= read -r image_id; do
    [[ -n "$image_id" ]] || continue
    [[ "$(jq -nc --argjson o "$out" --arg k "$image_id" '$o | has($k)' 2>/dev/null)" == "true" ]] && continue
    digest="$(host_facts_compose_docker_get "/images/$image_id/json" "$curl_cmd" \
      | jq -r '(.RepoDigests // [])[0] // "" | if test("@sha256:") then split("@")[1] else "" end' 2>/dev/null)"
    out="$(jq -nc --argjson o "$out" --arg k "$image_id" \
      --argjson d "$( [[ -n "$digest" ]] && jq -nc --arg x "$digest" '$x' || printf 'null' )" \
      '$o + {($k): $d}' 2>/dev/null || printf '%s' "$out")"
  done < <(jq -r '.[]?.Image // empty' <<<"$inspects" 2>/dev/null)
  printf '%s' "$out"
}

# host_facts_compose_containers_json INSPECT-ARRAY REGISTRY-DIGEST ROOT
# DRIVER [CURL-CMD] — the whole `containers[]` array, in the order
# INSPECT-ARRAY carries. A single malformed element is skipped, never
# fatal to the rest.
host_facts_compose_containers_json() {
  local inspects="${1:-[]}" registry_digest="${2:-}" root="${3:-}" driver="${4:-}" \
    curl_cmd="${5:-${HOST_FACTS_DOCKER_CURL_CMD:-curl}}"
  local digests="" out="[]" one="" image_id="" digest=""
  digests="$(host_facts_compose_image_digests_json "$inspects" "$curl_cmd")"
  while IFS= read -r one; do
    [[ -n "$one" ]] || continue
    image_id="$(jq -r '.Image // ""' <<<"$one" 2>/dev/null)"
    digest="$(jq -r --arg k "$image_id" '.[$k] // "" | if type == "string" then . else "" end' <<<"$digests" 2>/dev/null)"
    local entry=""
    entry="$(host_facts_compose_container_entry "$one" "$digest" "$registry_digest" "$root" "$driver")"
    [[ -n "$entry" ]] || continue
    out="$(jq -nc --argjson arr "$out" --argjson e "$entry" '$arr + [$e]' 2>/dev/null || printf '%s' "$out")"
  done < <(jq -c '.[]?' <<<"$inspects" 2>/dev/null)
  printf '%s' "$out"
}

# host_facts_compose_docker_get PATH [CURL-CMD] — one Docker Engine API GET
# over the read-only socket mount, or empty on any failure. CURL-CMD
# defaults to `curl`; the test suite points it at a fixture standing in for
# the socket, the same override shape `IMAGE_DRIFT_CURL_CMD` already gives
# `lib/image-drift.sh`.
host_facts_compose_docker_get() {
  local path="${1:-}" curl_cmd="${2:-${HOST_FACTS_DOCKER_CURL_CMD:-curl}}" \
    socket="${DOCKER_SOCKET:-/var/run/docker.sock}"
  "$curl_cmd" -fsS --max-time 5 --unix-socket "$socket" "http://localhost$path" 2>/dev/null
}

# host_facts_compose_section [CURL-CMD] — the whole compose-driver section:
# `{"containers":[...]}`, plus `updater` (this driver's own way of getting
# at watchtower's log — through the same socket, since nothing else on this
# node can). ROOT is the host cgroup mount (`HOST_FACTS_CGROUP_ROOT`,
# default `/sys/fs/cgroup`); DRIVER defaults to auto-detecting via
# `GET /info`'s own `CgroupDriver` field.
host_facts_compose_section() {
  local curl_cmd="${1:-${HOST_FACTS_DOCKER_CURL_CMD:-curl}}"
  local root="${HOST_FACTS_CGROUP_ROOT:-/sys/fs/cgroup}" driver="${HOST_FACTS_CGROUP_DRIVER:-}"
  [[ -n "$driver" ]] || driver="$(host_facts_compose_docker_get /info "$curl_cmd" | jq -r '.CgroupDriver // ""' 2>/dev/null)"

  local list="" inspects="[]" id="" one=""
  list="$(host_facts_compose_docker_get '/containers/json?all=true' "$curl_cmd")"
  # The one degradation worth a word on stderr rather than a silent `[]`: an
  # engine that answers nothing at all is almost always this container
  # lacking permission to *open* the socket it mounts (uid 1000 against a
  # `root:docker` socket — see `group_add` in deploy/docker/compose.yaml),
  # and that is indistinguishable, in the record, from a host genuinely
  # running no containers. Everything below still degrades exactly as
  # documented; this only makes the cause findable in the collector's own
  # container log.
  if [[ -z "$list" ]]; then
    echo "host-facts: the Docker Engine API returned nothing for /containers/json — the socket is unreachable or unreadable (see DOCKER_GID in deploy/docker/.env.example); containers[] will be empty" >&2
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    one="$(host_facts_compose_docker_get "/containers/$id/json" "$curl_cmd")"
    [[ -n "$one" ]] || continue
    inspects="$(jq -nc --argjson arr "$inspects" --argjson e "$one" '$arr + [$e]' 2>/dev/null || printf '%s' "$inspects")"
  done < <(jq -r '.[]?.Id // empty' <<<"$list" 2>/dev/null)

  local registry="${HOST_FACTS_IMAGE_REPO:-}" registry_digest=""
  if [[ -n "$registry" ]]; then
    registry_digest="$(host_facts_compose_registry_digest "$registry" "${HOST_FACTS_IMAGE_TAG:-latest}" "$curl_cmd")"
  fi

  local containers=""
  containers="$(host_facts_compose_containers_json "$inspects" "$registry_digest" "$root" "$driver" "$curl_cmd")"

  # The engine's logs endpoint multiplexes stdout/stderr with an 8-byte
  # binary frame header ahead of each write when the container carries no
  # TTY (watchtower's own default) — but each of its log lines is one
  # `Fprintln`, i.e. one frame, so the header bytes sit *between* lines,
  # never inside the ASCII text this collector greps for. `grep -a` treats
  # the whole blob as text rather than refusing it as binary; demuxing the
  # frames properly would buy nothing this collector's own substring
  # matches need.
  local wt_id="" wt_log=""
  wt_id="$(jq -r '.[]? | select(.Labels["com.docker.compose.service"] == "watchtower") | .Id' <<<"$list" 2>/dev/null | head -n 1)"
  if [[ -n "$wt_id" ]]; then
    wt_log="$(host_facts_compose_docker_get "/containers/$wt_id/logs?stdout=true&stderr=true&tail=200" "$curl_cmd" | grep -a '.' || true)"
  fi

  jq -nc --argjson containers "$containers" --arg wt_log "${wt_log:-}" \
    '{containers:$containers, watchtower_log_tail:(if $wt_log == "" then null else $wt_log end)}'
}
