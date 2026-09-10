#!/usr/bin/env bash
#
# test/host-facts.test.sh — the driver-independent half of the host-facts
# record (lib/host-facts.sh, docs/HOST-FACTS-SCHEMA.md): `host.network`'s
# MTU comparison, the updater ledger/last-session parse, and the
# viewer-vantage probe. The compose- and Kubernetes-specific sections each
# have their own test file; this one covers what both drivers share.
#
# The properties that matter:
#   - mtu_match is true when the configured DOCKER_MTU equals the measured
#     egress MTU, false when it differs, and null — never guessed — when
#     the egress MTU itself could not be measured;
#   - the updater ledger tail reads the last N entries across every file in
#     the ledger directory — never one named for the querying node, which
#     no writer ever creates — merged oldest-first, and degrades to an empty
#     array rather than failing on a missing directory or a malformed line;
#   - the last-session parser reads the newest "Session done Failed=N
#     Scanned=N Updated=N" line's own `time="…"` timestamp, never this
#     collector's own clock, and reads null when no such line exists;
#   - a viewer probe that gets valid JSON back reads ok:true with a byte
#     count and a timing; one that fails to fetch, or gets a body that will
#     not parse, reads ok:false with a reason and null timing/bytes.
#
# Run directly: ./test/host-facts.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/host-facts.sh
. "$SCRIPT_DIR/lib/host-facts.sh"

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

# --- host.network / MTU ------------------------------------------------------
network_match="$(DOCKER_MTU=1500 host_facts_network_json)"
egress="$(jq -r '.egress_mtu' <<<"$network_match")"
if [[ "$egress" == "null" ]]; then
  assert_eq "no default route here: mtu_match is null, never guessed" \
    "null" "$(jq -r '.mtu_match' <<<"$network_match")"
else
  assert_eq "DOCKER_MTU equal to the measured egress MTU matches" \
    "true" "$(DOCKER_MTU="$egress" host_facts_network_json | jq -r '.mtu_match')"
fi
network_mismatch="$(DOCKER_MTU=1 host_facts_network_json)"
if [[ "$(jq -r '.egress_mtu' <<<"$network_mismatch")" != "null" ]]; then
  assert_eq "DOCKER_MTU of 1 never equals a real egress MTU" \
    "false" "$(jq -r '.mtu_match' <<<"$network_mismatch")"
fi
assert_eq "DOCKER_MTU falls back to 1500, the same default compose.yaml uses" \
  "1500" "$(env -u DOCKER_MTU bash -c '. "'"$SCRIPT_DIR"'/lib/host-facts.sh"; host_facts_network_json' | jq -r '.docker_mtu_configured')"

# --- Updater ledger tail ------------------------------------------------------
# Every filename here is deliberately container-ID-shaped and shares no
# characters with any node name. That is the real shape on a compose node:
# the ledger's only writer keys each file by the *writing container's* own
# $HOSTNAME, never by NODE_NAME, so a reader that selects a file by node
# name finds nothing while a populated ledger sits beside it — the defect
# every earlier fixture hid by keying its file to the name it then queried.
ledger_dir="$tmp_dir/updater-ledger"
mkdir -p "$ledger_dir"
{
  printf '{"verdict":"allow","ts":"2026-09-08T00:00:00Z","service":"scheduler"}\n'
  printf '{"verdict":"allow","ts":"2026-09-08T00:05:00Z","service":"scheduler"}\n'
  printf 'not json\n'
  printf '{"verdict":"allow","ts":"2026-09-08T00:10:00Z","service":"scheduler"}\n'
} > "$ledger_dir/3f9a1c2b4d5e.jsonl"

tail_json="$(host_facts_updater_ledger_tail "$ledger_dir" 3)"
assert_eq "a malformed line among the tail is skipped, not fatal to the rest" \
  "2" "$(jq 'length' <<<"$tail_json")"
assert_eq "ledger tail is oldest-first" "2026-09-08T00:05:00Z" \
  "$(jq -r '.[0].ts' <<<"$tail_json")"
assert_eq "the tail is read though no file is named for the querying node" \
  "2026-09-08T00:10:00Z" "$(jq -r '.[-1].ts' <<<"$tail_json")"

# A roll's replacement writes under a fresh container ID, so one node's own
# updater history spans files by construction: the tail is the newest
# entries across all of them, ordered by ts rather than by filename.
printf '{"verdict":"allow","ts":"2026-09-08T00:07:00Z","service":"scheduler"}\n' \
  > "$ledger_dir/a1b2c3d4e5f6.jsonl"
merged="$(host_facts_updater_ledger_tail "$ledger_dir" 5)"
assert_eq "entries from every generation's file are merged into one tail" \
  "4" "$(jq 'length' <<<"$merged")"
assert_eq "the merged tail is ordered by ts, not by filename" \
  "2026-09-08T00:00:00Z 2026-09-08T00:05:00Z 2026-09-08T00:07:00Z 2026-09-08T00:10:00Z" \
  "$(jq -r '[.[].ts] | join(" ")' <<<"$merged")"
assert_eq "the merged tail truncates to the newest N across all files" \
  "2026-09-08T00:07:00Z 2026-09-08T00:10:00Z" \
  "$(host_facts_updater_ledger_tail "$ledger_dir" 2 | jq -r '[.[].ts] | join(" ")')"

mkdir -p "$tmp_dir/empty-ledger"
assert_eq "a ledger directory holding no .jsonl file degrades to an empty array" \
  "[]" "$(host_facts_updater_ledger_tail "$tmp_dir/empty-ledger")"
assert_eq "a missing ledger directory degrades to an empty array" \
  "[]" "$(host_facts_updater_ledger_tail "$tmp_dir/no-such-ledger-dir")"

# --- last-session parse -------------------------------------------------------
log_text='time="2026-09-08T09:00:00Z" level=info msg="Session done" Failed=0 Scanned=3 Updated=1
time="2026-09-08T10:00:00Z" level=info msg="Session done" Failed=2 Scanned=3 Updated=0'
assert_eq "the newest Session-done line wins, not the first" \
  '{"ts":"2026-09-08T10:00:00Z","failed":2,"scanned":3,"updated":0}' \
  "$(host_facts_parse_last_session "$log_text")"
assert_eq "no Session-done line at all reads null" "null" \
  "$(host_facts_parse_last_session 'nothing relevant here')"
assert_eq "no log text at all reads null" "null" "$(host_facts_parse_last_session)"

# --- updater section ----------------------------------------------------------
assert_eq "no ledger dir and no log text: the whole updater section is null" \
  "null" "$(host_facts_updater_json "$tmp_dir/no-such-state-dir" "")"

# End to end through the section builder, which is where the node name used
# to be threaded in and drop the tail on the floor.
assert_eq "the section carries the ledger tail though no file bears this node's name" \
  "4" "$(host_facts_updater_json "$tmp_dir" "" | jq '.ledger_tail | length')"

# --- Viewer probe --------------------------------------------------------------
ok_curl="$tmp_dir/ok-curl.sh"
cat > "$ok_curl" <<'STUB'
#!/usr/bin/env bash
echo '{"generated_at":"2026-09-09T00:00:00Z"}'
STUB
chmod +x "$ok_curl"

fail_curl="$tmp_dir/fail-curl.sh"
cat > "$fail_curl" <<'STUB'
#!/usr/bin/env bash
exit 22
STUB
chmod +x "$fail_curl"

bad_body_curl="$tmp_dir/bad-body-curl.sh"
cat > "$bad_body_curl" <<'STUB'
#!/usr/bin/env bash
echo 'not valid json at all'
STUB
chmod +x "$bad_body_curl"

probe_ok="$(host_facts_viewer_probe_one node-a http://node-a/data.js "$ok_curl")"
assert_eq "a successful fetch that parses reads ok:true" "true" "$(jq -r '.ok' <<<"$probe_ok")"
assert_eq "a successful fetch carries a byte count" "1" \
  "$(jq -r '(.bytes // 0) > 0 | if . then 1 else 0 end' <<<"$probe_ok")"

probe_fail="$(host_facts_viewer_probe_one node-b http://node-b/data.js "$fail_curl")"
assert_eq "a failed fetch reads ok:false" "false" "$(jq -r '.ok' <<<"$probe_fail")"
assert_eq "a failed fetch carries no byte count" "null" "$(jq -r '.bytes' <<<"$probe_fail")"

probe_bad_body="$(host_facts_viewer_probe_one node-c http://node-c/data.js "$bad_body_curl")"
assert_eq "a body that will not parse reads ok:false" "false" "$(jq -r '.ok' <<<"$probe_bad_body")"
assert_eq "a body that will not parse still reports what it received" \
  "body did not parse as JSON" "$(jq -r '.reason' <<<"$probe_bad_body")"

probe_json="$(host_facts_viewer_probe_json $'node-a\nnode-b' 'http://{node}/data.js' "$ok_curl")"
assert_eq "the probe object is keyed by every node in the list" \
  '["node-a","node-b"]' "$(jq -c 'keys' <<<"$probe_json")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
