#!/usr/bin/env bash
#
# test/collect-host-facts-compose.test.sh — the compose driver of the
# host-facts collector (issue #1283, docs/HOST-FACTS-SCHEMA.md), against
# fixture Docker Engine API JSON — the same shape `docker inspect` prints,
# since it is a thin client over exactly this API (lib/host-facts-
# compose.sh's own header). No real Docker socket exists where this suite
# runs, so every Engine-API call goes through a fixture `curl` stub keyed
# on the URL it is asked for, the same override shape
# `test/image-drift.test.sh` already exercises via `IMAGE_DRIFT_CURL_CMD`.
#
# The properties that matter:
#   - a running container's state, restart count and start time come
#     through from its own inspect JSON;
#   - the zero-value `StartedAt` Docker reports for "never started" reads
#     `null`, never that literal string;
#   - a container's own image digest is resolved through a *second*,
#     per-image `GET /images/{id}/json` call — never read off the
#     container's own inspect, which carries no `RepoDigests` field at all;
#   - digest_match is true when the resolved digest equals the registry's,
#     false when it differs, and null when either side is unreadable;
#   - the registry digest reaches only containers running the repository it
#     was actually fetched for — a container from another repository reads
#     registry_digest/digest_match null, never a foreign repository's digest
#     and a permanent false;
#   - memory.current/high/max/oom_kill each read independently from a
#     fixture cgroup tree, and each is null on its own when that file is
#     absent — one missing file never takes the other three down with it;
#   - a container carrying no compose-service label reads service: null,
#     never a fabricated name;
#   - the watchtower log's own "Session done Failed=N Scanned=N Updated=N"
#     line parses into the updater section, ts included.
#
# Run directly: ./test/collect-host-facts-compose.test.sh — exit 0 iff all
# passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/host-facts.sh
. "$SCRIPT_DIR/lib/host-facts.sh"
# shellcheck source=lib/host-facts-compose.sh
. "$SCRIPT_DIR/lib/host-facts-compose.sh"

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

# --- Fixture cgroup tree -------------------------------------------------
cgroup_root="$tmp_dir/cgroup"
mkdir -p "$cgroup_root/system.slice/docker-fullid1.scope"
printf '104857600\n' > "$cgroup_root/system.slice/docker-fullid1.scope/memory.current"
printf 'max\n' > "$cgroup_root/system.slice/docker-fullid1.scope/memory.high"
printf '536870912\n' > "$cgroup_root/system.slice/docker-fullid1.scope/memory.max"
cat > "$cgroup_root/system.slice/docker-fullid1.scope/memory.events" <<'EOF'
low 0
high 3
max 0
oom 0
oom_kill 1
EOF
# fullid2's cgroup tree deliberately does not exist — the "unreadable"
# scenario.

# --- Fixture Docker Engine API + registry, keyed on the requested URL ---
stub_curl="$tmp_dir/stub-curl.sh"
cat > "$stub_curl" <<'STUB'
#!/usr/bin/env bash
args=("$@")
url="${args[-1]}"
case "$url" in
  *"/token?"*)
    echo '{"token":"tok123"}'
    ;;
  https://ghcr.io/v2/*/manifests/*)
    printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:regdigest\r\n\r\n'
    ;;
  "http://localhost/info")
    echo '{"CgroupDriver":"systemd"}'
    ;;
  "http://localhost/containers/json?all=true")
    echo '[{"Id":"fullid1","Labels":{"com.docker.compose.service":"scheduler"}},{"Id":"fullid2","Labels":{"com.docker.compose.service":"watchtower"}}]'
    ;;
  "http://localhost/containers/fullid1/json")
    cat "$STUB_INSPECT_1"
    ;;
  "http://localhost/containers/fullid2/json")
    cat "$STUB_INSPECT_2"
    ;;
  "http://localhost/images/sha256:imageA/json")
    echo '{"RepoDigests":["ghcr.io/pullwright/agent-ops@sha256:regdigest"]}'
    ;;
  "http://localhost/images/sha256:imageB/json")
    # A foreign repository, as watchtower and tailscale really are on a
    # node: a real repo digest of its own, from a repository that is not the
    # one HOST_FACTS_IMAGE_REPO names.
    echo '{"RepoDigests":["docker.io/containrrr/watchtower@sha256:wtdigest"]}'
    ;;
  *"/containers/fullid2/logs"*)
    printf '%s' "$STUB_WT_LOG"
    ;;
  *)
    echo "unhandled: $url" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$stub_curl"

inspect_1="$tmp_dir/inspect1.json"
cat > "$inspect_1" <<'EOF'
{"Id":"fullid1","Name":"/agent-ops-scheduler-1",
 "HostConfig":{"CgroupParent":"","NanoCpus":2000000000},
 "Config":{"Labels":{"com.docker.compose.service":"scheduler"}},
 "State":{"Status":"running","RestartCount":0,"StartedAt":"2026-09-09T12:00:00Z"},
 "Image":"sha256:imageA"}
EOF

inspect_never_started="$tmp_dir/inspect-never-started.json"
cat > "$inspect_never_started" <<'EOF'
{"Id":"fullid2","Name":"/agent-ops-watchtower-1",
 "HostConfig":{"CgroupParent":"","NanoCpus":0},
 "Config":{"Labels":{}},
 "State":{"Status":"created","RestartCount":0,"StartedAt":"0001-01-01T00:00:00Z"},
 "Image":"sha256:imageB"}
EOF

# --- Container entry: the ordinary case ----------------------------------
memory="$(host_facts_compose_container_memory_json "$cgroup_root" systemd "" fullid1)"
assert_eq "memory.current reads from the fixture cgroup" \
  '{"current_bytes":104857600,"high_bytes":null,"max_bytes":536870912,"oom_kill_count":1}' "$memory"

entry="$(host_facts_compose_container_entry "$(cat "$inspect_1")" sha256:regdigest sha256:regdigest "$cgroup_root" systemd)"
assert_eq "container name" "agent-ops-scheduler-1" "$(jq -r '.name' <<<"$entry")"
assert_eq "container service label" "scheduler" "$(jq -r '.service' <<<"$entry")"
assert_eq "container state" "running" "$(jq -r '.state' <<<"$entry")"
assert_eq "container started_at" "2026-09-09T12:00:00Z" "$(jq -r '.started_at' <<<"$entry")"
assert_eq "digest_match true when equal" "true" "$(jq -r '.image.digest_match' <<<"$entry")"
assert_eq "cpu limit_nanos" "2000000000" "$(jq -r '.cpu.limit_nanos' <<<"$entry")"

# --- Never-started container: the zero-value timestamp ------------------
entry_ns="$(host_facts_compose_container_entry "$(cat "$inspect_never_started")" "" "" "$cgroup_root" systemd)"
assert_eq "never-started StartedAt reads null, not the zero-value string" \
  "null" "$(jq -r '.started_at' <<<"$entry_ns")"
assert_eq "container with no compose-service label reads service: null" \
  "null" "$(jq -c '.service' <<<"$entry_ns")"
assert_eq "unreadable cgroup tree degrades memory to all-null, not a crash" \
  '{"current_bytes":null,"high_bytes":null,"max_bytes":null,"oom_kill_count":null}' \
  "$(jq -c '.memory' <<<"$entry_ns")"

# --- digest mismatch and unreadable-registry degrade honestly -----------
entry_mismatch="$(host_facts_compose_container_entry "$(cat "$inspect_1")" sha256:regdigest sha256:other "$cgroup_root" systemd)"
assert_eq "digest_match false when digests differ" "false" "$(jq -r '.image.digest_match' <<<"$entry_mismatch")"

entry_no_registry="$(host_facts_compose_container_entry "$(cat "$inspect_1")" sha256:regdigest "" "$cgroup_root" systemd)"
assert_eq "digest_match null when the registry side is unreadable" \
  "null" "$(jq -r '.image.digest_match' <<<"$entry_no_registry")"

# --- Full section, end to end through the fixture curl -------------------
export STUB_INSPECT_1="$inspect_1" STUB_INSPECT_2="$inspect_never_started"
export STUB_WT_LOG='time="2026-09-08T10:00:00Z" level=info msg="Session done" Failed=2 Scanned=3 Updated=0'
export HOST_FACTS_CGROUP_ROOT="$cgroup_root" HOST_FACTS_IMAGE_REPO="Pullwright/agent-ops"
section="$(host_facts_compose_section "$stub_curl")"

assert_eq "section carries two containers" "2" "$(jq '.containers | length' <<<"$section")"
assert_eq "watchtower_log_tail carries the raw log for the caller to parse" \
  "1" "$(jq -r '(.watchtower_log_tail // "") | test("Session done") | if . then 1 else 0 end' <<<"$section")"

# The registry digest is fetched for exactly one repository
# (HOST_FACTS_IMAGE_REPO), so it reaches only the container actually running
# that repository's image. The other container on this host runs
# containrrr/watchtower — a real repo digest, from a repository this
# collector never asked the registry about — and must read registry_digest
# null / digest_match null rather than a foreign repository's digest and a
# permanent `false` (docs/HOST-FACTS-SCHEMA.md's own `image.registry_digest`
# row).
assert_eq "the configured repository's own container compares against the registry" \
  "sha256:regdigest" \
  "$(jq -r '.containers[] | select(.name=="agent-ops-scheduler-1") | .image.registry_digest' <<<"$section")"
assert_eq "and reads digest_match true when it is up to date" "true" \
  "$(jq -r '.containers[] | select(.name=="agent-ops-scheduler-1") | .image.digest_match' <<<"$section")"
assert_eq "a container from another repository keeps its own digest" \
  "sha256:wtdigest" \
  "$(jq -r '.containers[] | select(.name=="agent-ops-watchtower-1") | .image.digest' <<<"$section")"
assert_eq "a container from another repository is never compared to this one's registry digest" \
  "null" \
  "$(jq -r '.containers[] | select(.name=="agent-ops-watchtower-1") | .image.registry_digest' <<<"$section")"
assert_eq "so its digest_match is null, never a permanent false" "null" \
  "$(jq -r '.containers[] | select(.name=="agent-ops-watchtower-1") | .image.digest_match' <<<"$section")"

updater="$(host_facts_updater_json "$tmp_dir" "$(jq -r '.watchtower_log_tail' <<<"$section")")"
assert_eq "last_session parses Failed/Scanned/Updated from the log" \
  '{"ts":"2026-09-08T10:00:00Z","failed":2,"scanned":3,"updated":0}' \
  "$(jq -c '.last_session' <<<"$updater")"

# --- Registry digest: a header the fixture curl actually answers --------
digest="$(host_facts_compose_registry_digest "Pullwright/agent-ops" latest "$stub_curl")"
assert_eq "registry digest reads the Docker-Content-Digest header" "sha256:regdigest" "$digest"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
