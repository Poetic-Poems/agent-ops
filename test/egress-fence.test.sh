#!/usr/bin/env bash
#
# test/egress-fence.test.sh — the D24 egress fence's static shape
# (IMPLEMENTATION-PIPELINE-SPEC, "The node stack"), and the proxy start
# script's real merge behaviour.
#
# What this guards: the fence is spread across four files that only work
# together — the compose topology (internal-only network, proxy on both),
# the squid config (default-deny, CONNECT-443-only), the baked allowlist
# (every domain a cycle actually needs — several of which, like
# codeload.github.com, appear in no source file and fail as quiet degrades
# when missing), and the scheduler's proxy environment. Any one of them
# regressing leaves a fence that either blocks the fleet or fences nothing,
# and three of those failure shapes are silent. The *live* fence cannot be
# exercised here — the suite runs inside one container and cannot stand up
# Docker networks — which is exactly why scripts/doctor.sh's Egress section
# probes it per node; this file pins everything that is checkable statically,
# plus the one behavioural piece (allowlist merging) that runs anywhere.
#
# Run directly: ./test/egress-fence.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

pass() { printf 'ok   - %s\n' "$1"; }
flunk() { printf 'FAIL - %s\n' "$1"; failures=$(( failures + 1 )); }

assert_line() {  # exact line $2 present in file $1
  if grep -qxF "$2" "$1"; then pass "$3"; else flunk "$3"; fi
}

allowlist="$SCRIPT_DIR/deploy/docker/egress-allowlist.txt"
conf="$SCRIPT_DIR/deploy/docker/egress-proxy.conf"
compose="$SCRIPT_DIR/deploy/docker/compose.yaml"
starter="$SCRIPT_DIR/deploy/docker/egress-proxy-start.sh"

# --- The baked allowlist carries every domain a cycle needs ---------------
# Each entry here traces to a real consumer; the two comments name the ones
# that are invisible to a grep of the source (codeload: a 302 target only;
# ghcr.io: lib/image-drift.sh runs in the scheduler, not just watchtower).
for domain in \
  github.com api.github.com codeload.github.com .githubusercontent.com \
  api.anthropic.com platform.claude.com claude.ai claude.com \
  api.vercel.com .vercel.app vercel.com \
  registry.npmjs.org fonts.googleapis.com fonts.gstatic.com ghcr.io
do
  assert_line "$allowlist" "$domain" "allowlist carries $domain"
done

# --- The squid config is default-deny, CONNECT-to-443-only ----------------
assert_line "$conf" 'http_access deny all' "conf denies by default"
assert_line "$conf" 'http_access allow CONNECT allowed_dst' "conf allows only allowlisted CONNECT"
assert_line "$conf" 'http_access deny CONNECT !SSL_ports' "conf refuses CONNECT to non-443 ports"
assert_line "$conf" 'acl allowed_dst dstdomain "/tmp/egress-allowlist"' "conf reads the merged allowlist"
assert_line "$conf" 'cache deny all' "conf caches nothing"
if [[ "$(grep -c '^http_access' "$conf")" == 3 ]] \
   && [[ "$(grep '^http_access' "$conf" | tail -1)" == "http_access deny all" ]]; then
  pass "conf's rule order ends on the deny (squid takes the first match)"
else
  flunk "conf's http_access rules changed shape — the final rule must be the deny"
fi

# --- The compose topology is the enforcement ------------------------------
# The scheduler's service block: from its heading to the next same-indent
# service. Lifted rather than restated so this fails when the file moves on.
scheduler_block="$(awk '/^  scheduler:$/{on=1; next} on && /^  [a-z-]+:$/{exit} on' "$compose")"
proxy_block="$(awk '/^  egress-proxy:$/{on=1; next} on && /^  [a-z-]+:$/{exit} on' "$compose")"
if [[ -z "$scheduler_block" || -z "$proxy_block" ]]; then
  echo "FAIL - could not lift the scheduler or egress-proxy service block from compose.yaml"
  exit 1
fi

if grep -qF 'networks: [egress]' <<<"$scheduler_block"; then
  pass "scheduler sits on the egress network only"
else
  flunk "scheduler is not confined to the egress network"
fi
for var in HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY no_proxy; do
  if grep -qE "^      $var: " <<<"$scheduler_block"; then
    pass "scheduler environment names $var"
  else
    flunk "scheduler environment is missing $var (compose's environment block is an allowlist — an unnamed variable reaches nothing)"
  fi
done
if grep -qF 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"' <<<"$scheduler_block"; then
  pass "scheduler disables Claude Code's nonessential traffic (its domains are off the allowlist)"
else
  flunk "scheduler no longer disables Claude Code's nonessential traffic, but its domains are not on the allowlist"
fi

if grep -qF 'networks: [default, egress]' <<<"$proxy_block"; then
  pass "egress-proxy bridges the internal network and the default one"
else
  flunk "egress-proxy is not on exactly [default, egress]"
fi
if grep -qE '^      EGRESS_EXTRA_ALLOW: ' <<<"$proxy_block"; then
  pass "egress-proxy environment names EGRESS_EXTRA_ALLOW"
else
  flunk "EGRESS_EXTRA_ALLOW is not named in egress-proxy's environment, so a node's .env additions reach nothing"
fi

egress_net="$(awk '/^  egress:$/{on=1; next} on && /^  [a-z-]+:$/{exit} on' "$compose")"
if grep -qF 'internal: true' <<<"$egress_net"; then
  pass "the egress network is internal (no gateway — the fence is topology)"
else
  flunk "the egress network is not internal: true — the fence is advisory"
fi
# shellcheck disable=SC2016  # the ${DOCKER_MTU:-1500} is the literal being asserted, not an expansion.
if grep -qF 'com.docker.network.driver.mtu: ${DOCKER_MTU:-1500}' <<<"$egress_net"; then
  pass "the egress network carries the DOCKER_MTU treatment"
else
  flunk "the egress network lost the DOCKER_MTU driver_opts — an MTU black hole through the fence looks like a broken allowlist"
fi

# --- The start script's merge, run for real against a stub squid ----------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/app/deploy/docker" "$tmp/bin"
printf '# a comment\n\ngithub.com\napi.github.com\n' > "$tmp/app/deploy/docker/egress-allowlist.txt"
cp "$conf" "$tmp/app/deploy/docker/egress-proxy.conf"
cat > "$tmp/bin/squid" <<'STUB'
#!/usr/bin/env bash
printf 'squid-args:%s\n' "$*" > "${SQUID_STUB_OUT:?}"
STUB
chmod +x "$tmp/bin/squid"

out="$(TMPDIR=/tmp PATH="$tmp/bin:$PATH" APP_DIR="$tmp/app" SQUID_STUB_OUT="$tmp/squid-args" \
  EGRESS_EXTRA_ALLOW="preview.example.com, other.example.net" \
  bash "$starter" 2>&1)"
rc=$?
merged=/tmp/egress-allowlist
if (( rc == 0 )) && [[ "$(cat "$tmp/squid-args" 2>/dev/null)" == "squid-args:-N -f $tmp/app/deploy/docker/egress-proxy.conf" ]]; then
  pass "start script execs squid foreground on the shipped conf"
else
  flunk "start script did not exec squid as expected (rc=$rc; output: $out)"
fi
if [[ "$(cat "$merged" 2>/dev/null)" == $'github.com\napi.github.com\npreview.example.com\nother.example.net' ]]; then
  pass "merge = baked list stripped of comments, plus EGRESS_EXTRA_ALLOW split on commas and spaces"
else
  flunk "merged allowlist is wrong: $(tr '\n' '|' < "$merged" 2>/dev/null)"
fi
rm -f "$merged"

printf '# only comments\n' > "$tmp/app/deploy/docker/egress-allowlist.txt"
if PATH="$tmp/bin:$PATH" APP_DIR="$tmp/app" SQUID_STUB_OUT="$tmp/squid-args2" \
   bash "$starter" >/dev/null 2>&1; then
  flunk "start script accepted an empty merged allowlist — a fence that refuses everything should refuse to start"
else
  pass "start script refuses to start on an empty merged allowlist"
fi
rm -f "$merged"

# --- doctor's live-fence probes exist (their behaviour needs a real node) --
for needle in 'section "Egress"' 'the allowlist is not enforced' 'direct egress works despite HTTPS_PROXY'; do
  if grep -qF "$needle" "$SCRIPT_DIR/scripts/doctor.sh"; then
    pass "doctor.sh carries the egress probe: $needle"
  else
    flunk "doctor.sh lost its egress probe: $needle"
  fi
done

# --- The shipped conf parses, where squid is present ----------------------
if command -v squid >/dev/null 2>&1 && [[ "$(command -v squid)" != "$tmp/bin/squid" ]]; then
  cp "$allowlist" /tmp/egress-allowlist
  if squid -k parse -f "$conf" >/dev/null 2>&1; then
    pass "squid parses the shipped conf"
  else
    flunk "squid rejects the shipped conf"
  fi
  rm -f /tmp/egress-allowlist
else
  # The image build asserts this regardless (deploy/docker/Dockerfile), so a
  # host without squid loses nothing that CI does not still enforce.
  printf 'skip - squid not on this host; the image build runs the parse check\n'
fi

exit "$(( failures > 0 ))"
