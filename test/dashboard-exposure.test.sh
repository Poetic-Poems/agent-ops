#!/usr/bin/env bash
#
# test/dashboard-exposure.test.sh — the dashboard answers on the host's
# loopback and on no network.
#
# That is DASHBOARD-SPEC's requirement, and each compose profile arranges it a
# different way, so the ways are what this file guards:
#
#   local    the server binds 0.0.0.0 *inside the container* and the port is
#            published to 127.0.0.1 on the host. Both halves are load-bearing
#            and they fail in opposite directions. Drop the `127.0.0.1:` prefix
#            and the page is published on every interface the host has —
#            silently, because it still works exactly as before from the
#            machine you are testing on. Put the bind back to 127.0.0.1 and the
#            page answers nothing, because a server on the container's own
#            loopback is reachable through no published port.
#   tailnet  the server stays on 127.0.0.1 in the Tailscale sidecar's network
#            namespace, and is reached only through Serve. A `ports:` entry
#            there, or a widened bind, would put it on the host's networks.
#
# The first of those is why this file exists: it is the failure mode with no
# local symptom. The rest are here because the property is "and on no network",
# which no single service can be checked for alone.
#
# Scope: this reads `deploy/docker/compose.yaml` and runs
# `scripts/serve-dashboard.sh`. It cannot prove the socket-level result — that
# a request from another machine is refused — because that needs the stack
# actually up, and the suite runs inside the image with no Docker. Acceptance
# check 1c in IMPLEMENTATION-PIPELINE-SPEC is where that is proven; this is the
# guard that runs on every commit.
#
# No network. Run directly: ./test/dashboard-exposure.test.sh — exit 0 iff all
# passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="$SCRIPT_DIR/deploy/docker/compose.yaml"
SERVE="$SCRIPT_DIR/scripts/serve-dashboard.sh"

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

# --- Reading compose.yaml -----------------------------------------------------
# Enough YAML for this file and no more: services sit at two-space indent under
# `services:`, their keys at four. A block runs to the next key at two-space
# indent or shallower — comments and blank lines do not end one, and are
# dropped, so that prose about `ports:` can never be mistaken for a `ports:`.

service_names() {
  awk '
    /^services:/          { in_services = 1; next }
    /^[^[:space:]]/       { in_services = 0 }
    in_services && /^  [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      sub(/:[[:space:]]*$/, ""); sub(/^  /, ""); print
    }
  ' "$COMPOSE"
}

service_block() {
  awk -v svc="  $1:" '
    $0 == svc                 { in_svc = 1; next }
    in_svc && /^[^[:space:]]/ { exit }          # the next top-level key
    in_svc && /^  [^[:space:]#]/ { exit }       # the next service
    in_svc                    { print }
  ' "$COMPOSE" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$'
}

# The published port mappings of one service, quotes stripped, one per line.
service_ports() {
  service_block "$1" | awk '
    /^    ports:[[:space:]]*$/ { in_ports = 1; next }
    in_ports && /^      - /    { sub(/^      - /, ""); gsub(/"/, ""); print; next }
    in_ports                   { exit }
  '
}

service_key() {  # service_key SERVICE KEY — the scalar value, or "" if absent
  service_block "$1" | awk -v k="    $2:" '
    index($0, k) == 1 { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }
  '
}

# Sanity: the reader above must actually be reading something. Every assertion
# below is of the form "this string is absent", which an empty block would
# satisfy for the wrong reason.
assert_contains "compose.yaml defines the local dashboard" \
  "dashboard-local" "$(service_names | tr '\n' ' ')"
assert_contains "and the tailnet one" \
  " dashboard " " $(service_names | tr '\n' ' ')"
assert_eq "and the local dashboard's block is non-empty" \
  "0" "$([[ -n "$(service_block dashboard-local)" ]] && echo 0 || echo 1)"

# --- local: published to the host's loopback and nowhere else -----------------
# The assertion the whole file is for. `127.0.0.1:8787:8787` and `8787:8787`
# differ by nine characters and one of them puts the dashboard on every
# interface the host has.

local_ports="$(service_ports dashboard-local)"

assert_eq "the local dashboard publishes exactly one port" \
  "1" "$(printf '%s\n' "$local_ports" | grep -c .)"

unscoped=0
while IFS= read -r mapping; do
  [[ -n "$mapping" ]] || continue
  [[ "$mapping" == 127.0.0.1:* ]] || unscoped=$(( unscoped + 1 ))
done <<< "$local_ports"
assert_eq "and every mapping it publishes is scoped to the host's loopback" \
  "0" "$unscoped"

# The mapping is compared as the literal text compose.yaml holds, unexpanded:
# where `DASHBOARD_PORT` sits in it is the point, since it must move the host
# side alone.
# shellcheck disable=SC2016
assert_eq "with DASHBOARD_PORT moving the host side and the container side fixed" \
  '127.0.0.1:${DASHBOARD_PORT:-8787}:8787' "$local_ports"

# Host networking is what this replaced. It reached the same place on Linux and
# nowhere else: under Docker Desktop the namespace shared is the VM's, not the
# user's, so the page never answered at all.
assert_eq "the local dashboard takes no network_mode" \
  "" "$(service_key dashboard-local network_mode)"

# --- local: the two halves agree ----------------------------------------------
# A published port reaches the container's address, so the server has to be on
# it. This is the half that fails loudly rather than silently — but it fails as
# a page that does not answer, which reads like a dozen other things.

local_command="$(service_key dashboard-local command)"

assert_contains "the local dashboard's server binds the container's every address" \
  '"0.0.0.0"' "$local_command"
assert_contains "on the port the mapping's container side names" \
  '"8787"' "$local_command"
assert_contains "running the dashboard server and nothing else" \
  "/app/scripts/serve-dashboard.sh" "$local_command"

# --- tailnet: reached only through the sidecar --------------------------------
# No `ports:` is possible here while `network_mode: service:tailscale` holds —
# Docker rejects the pair — so this guards the two together: whoever removed the
# sidecar wiring would be free to add a mapping, and it would not be
# loopback-scoped by accident.

assert_eq "the tailnet dashboard lives in the sidecar's network namespace" \
  "service:tailscale" "$(service_key dashboard network_mode)"
assert_eq "and publishes no port of its own" \
  "" "$(service_ports dashboard)"

# Its bind stays the default: inside the sidecar's namespace, 127.0.0.1 is the
# address Serve proxies to (ts-serve.json), and it is shared with nothing else.
tailnet_command="$(service_key dashboard command)"
assert_eq "the tailnet dashboard's server is given no bind address, so it keeps loopback" \
  '["/app/scripts/serve-dashboard.sh", "8787"]' "$tailnet_command"

# --- nothing else publishes anything ------------------------------------------
# The guarantee is about the dashboard, but it is stated as "and on no network",
# and the scheduler shares the dashboard's image and its whole environment. A
# `ports:` pasted onto the wrong service is exactly the kind of edit this
# catches.

publishers=""
while IFS= read -r svc; do
  [[ -n "$svc" ]] || continue
  [[ -n "$(service_ports "$svc")" ]] && publishers="$publishers $svc"
done <<< "$(service_names)"
assert_eq "dashboard-local is the only service that publishes a port" \
  " dashboard-local" "$publishers"

# --- the server's own default is loopback -------------------------------------
# Run for real, because the default is the whole contract for every caller that
# passes no bind: the legacy WSL SysV init script, the tailnet profile, and
# anyone running it by hand. Port 0 so there is no port to collide with — the
# bind address is what is under test, and the script reports it before exec'ing
# python, which is as far as this needs to go. (python's own startup line is
# block-buffered into a pipe and would never arrive.)

serve_bind() {  # serve_bind [bind-address] — the address the server resolves to
  local tmp out pid line
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/.local/state/poetic-agents/dashboard"
  printf '<html></html>\n' > "$tmp/.local/state/poetic-agents/dashboard/index.html"
  out="$tmp/serve.log"

  HOME="$tmp" "$SERVE" 0 ${1+"$1"} > "$out" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do
    grep -q 'Serving .* at http://' "$out" 2>/dev/null && break
    sleep 0.1
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  line="$(sed -n 's|.* at http://\(.*\):0 .*|\1|p' "$out")"
  rm -rf "$tmp"
  printf '%s' "$line"
}

assert_eq "invoked with no bind address the server binds loopback" \
  "127.0.0.1" "$(serve_bind)"
assert_eq "and the setting the local profile depends on works" \
  "0.0.0.0" "$(serve_bind 0.0.0.0)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
