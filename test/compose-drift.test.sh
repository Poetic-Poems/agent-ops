#!/usr/bin/env bash
#
# test/compose-drift.test.sh — the in-container compose-drift check (#131).
#
# The properties that matter:
#   - identical copies read in-sync, and so do copies that differ only in
#     comments and blank lines — upstream rewrites compose comments freely,
#     and a badge that fired on every comment edit would be ignored;
#   - a material difference reads drifted, with a count of differing lines;
#   - a missing mount inside a container reads "unmounted" — the node's
#     compose.yaml predates the check, which is itself the verdict, and it is
#     what defeats the bootstrap problem: the check arrives by image roll, no
#     `up -d` required;
#   - a missing mount outside a container reads null, not "unmounted" — a
#     checkout install runs no compose file, and a false alarm there would
#     teach the operator the badge lies;
#   - an image carrying no copy to compare against reads null, never a guess;
#   - and deploy/docker/compose.yaml really does mount itself at the path the
#     library reads, read-only — the check is only ever reached through that
#     line, so losing it would silently disarm every node.
#
# Every path is overridden explicitly (COMPOSE_DRIFT_HOST / _IMAGE /
# _SENTINEL): the CI suite runs inside the image, where /.dockerenv exists
# and the defaults would answer for the build container, not the fixtures.
#
# Run directly: ./test/compose-drift.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/compose-drift.sh
. "$SCRIPT_DIR/lib/compose-drift.sh"

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

# The three fixture paths, and a sentinel standing in for /.dockerenv.
image="$tmp_dir/image-compose.yaml"
host="$tmp_dir/host-compose.yaml"
sentinel="$tmp_dir/dockerenv"
missing="$tmp_dir/does-not-exist"

# One verdict per call, with every path stated. `status <host> <image> <sentinel>`.
status() {
  COMPOSE_DRIFT_HOST="$1" COMPOSE_DRIFT_IMAGE="$2" COMPOSE_DRIFT_SENTINEL="$3" \
    compose_drift_status
}

cat > "$image" <<'EOF'
# the reference copy, as the image ships it
services:
  scheduler:
    image: ghcr.io/example/agent-ops:latest

  watchtower:
    environment:
      WATCHTOWER_LIFECYCLE_HOOKS: "true"
EOF

# --- In sync ------------------------------------------------------------------

cp "$image" "$host"
touch "$sentinel"
assert_eq "identical copies read in-sync" \
  '{"status":"in-sync"}' "$(status "$host" "$image" "$sentinel")"

# --- Comments and blanks are not drift ----------------------------------------

cat > "$host" <<'EOF'
# a completely rewritten comment
# spread over more lines than before

services:
  scheduler:
    # and one inside a service too
    image: ghcr.io/example/agent-ops:latest
  watchtower:
    environment:
      WATCHTOWER_LIFECYCLE_HOOKS: "true"
EOF
assert_eq "comment and blank-line differences alone are not drift" \
  '{"status":"in-sync"}' "$(status "$host" "$image" "$sentinel")"

# --- Material drift -----------------------------------------------------------
# The real 2026-07-28 divergence in miniature: the lifecycle flag gone and a
# stanza the upstream copy does not carry.

cat > "$host" <<'EOF'
services:
  scheduler:
    image: ghcr.io/example/agent-ops:latest
    network_mode: host

  watchtower:
    environment: {}
EOF
verdict="$(status "$host" "$image" "$sentinel")"
assert_eq "a material difference reads drifted" \
  "drifted" "$(jq -r '.status' <<<"$verdict")"
# The exact count is diff's business; what the contract owes the operator is
# a positive number to gauge the drift by.
diff_lines="$(jq -r '.diff_lines' <<<"$verdict")"
assert_eq "carrying a positive count of differing lines" \
  "1" "$([[ "$diff_lines" =~ ^[0-9]+$ && "$diff_lines" -gt 0 ]] && echo 1 || echo 0)"

# --- No mount -----------------------------------------------------------------

assert_eq "no mount inside a container reads unmounted — the file predates the check, which is the verdict" \
  '{"status":"unmounted"}' "$(status "$missing" "$image" "$sentinel")"

assert_eq "no mount outside a container is null, never a false alarm" \
  'null' "$(status "$missing" "$image" "$missing")"

# --- Nothing to compare against -----------------------------------------------

assert_eq "an image with no copy of its own reads null, never a guess" \
  'null' "$(status "$host" "$missing" "$sentinel")"

# --- The mount line in compose.yaml -------------------------------------------
# The library reads /host/compose.yaml because compose.yaml puts it there; the
# check is only ever armed through that line, and it must be read-only — a
# writable mount would let a compromised container rewrite the node's own
# deployment.

compose="$SCRIPT_DIR/deploy/docker/compose.yaml"
assert_eq "compose.yaml mounts itself where the library reads, read-only" \
  "1" "$(grep -qE '^\s*-\s*\./compose\.yaml:/host/compose\.yaml:ro\s*$' "$compose" && echo 1 || echo 0)"

# The verdict must never abort a heartbeat: the function is called under
# `set -e` from state-sync.sh, so every path above must also return 0.
( set -e; status "$missing" "$missing" "$missing" >/dev/null )
assert_eq "no path returns non-zero, even with nothing to read" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
