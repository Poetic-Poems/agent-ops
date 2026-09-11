#!/usr/bin/env bash
#
# test/compose-reconcile.test.sh — the compose reconciler (lib/compose-
# reconcile.sh): what applies a merged compose.yaml to a node without a human,
# the way watchtower applies a merged image.
#
# The properties that matter, each one a way the thing could be worse than the
# manual ritual it replaces:
#
#   - it acts only on drift, and a second run after a successful one does
#     nothing at all — an actor on a five-minute tick that is not idempotent
#     recreates a node's whole stack every five minutes;
#   - a `${VAR}` the new file requires and the node's `.env` does not define
#     refuses the whole apply, changing nothing: compose would otherwise
#     interpolate an empty string and `up -d` would deploy it;
#   - a `${VAR:-default}` is not such a variable, and neither is `$$VAR` nor a
#     shell fragment in a comment — a scan that cannot tell those apart
#     refuses every node for ever;
#   - a cycle in flight defers it, exactly as `watchtower-pre-update.sh`
#     defers a roll, and the roll-pending marker overrides `lock.json` alone;
#   - a recreate that failed is retried even though the file it installed has
#     already cleared the drift that would otherwise be the only thing asking;
#   - the file is replaced *in place*, keeping its inode, because a bind mount
#     of a file pins the inode it was created against;
#   - `.env` is never written, and its values are never read;
#   - every event is a transition, not a tick.
#
# `docker` is stubbed throughout: this suite creates no container and reaches
# no socket. Every path the library reads is given explicitly
# (COMPOSE_RECONCILE_PROJECT_DIR / _IMAGE_FILE / _STATE_DIR / _CONFIG /
# _DOCKER / _NOW), the same way test/compose-drift.test.sh gives its own,
# because the CI suite runs inside the image where the defaults would answer
# for the build container instead of the fixture.
#
# Run directly: ./test/compose-reconcile.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/compose-reconcile.sh
. "$SCRIPT_DIR/lib/compose-reconcile.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:              %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- The fixture ---------------------------------------------------------------
# A node's project directory (its compose.yaml and its .env), the image's own
# copy of compose.yaml, a state directory, a config.json of its own values —
# never this repository's, which must be free to change without moving a test
# — and a `docker` that records its arguments instead of running.

project="$tmp_dir/project"
state="$tmp_dir/state"
bin="$tmp_dir/bin"
mkdir -p "$project" "$state" "$bin"

config="$tmp_dir/config.json"
cat > "$config" <<'EOF'
{"lock_stale_after": 4, "project_review": {"lock_stale_after": 6}}
EOF

export DOCKER_STUB_LOG="$tmp_dir/docker-calls.log"
: > "$DOCKER_STUB_LOG"
cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_STUB_LOG"
printf 'Container agent-ops-scheduler-1  Recreated\n'
exit "${DOCKER_STUB_RC:-0}"
EOF
chmod +x "$bin/docker"

image_file="$tmp_dir/image-compose.yaml"
host_file="$project/compose.yaml"
env_file="$project/.env"
marker="$state/.compose-reconcile.json"
log_file="$state/log.jsonl"

# The image's copy. Deliberately carries all four shapes the variable scan has
# to tell apart: a defaulted reference, a required one, compose's `$$` escape,
# and a shell fragment inside a comment.
write_image_compose() {  # [extra line]
  cat > "$image_file" <<'EOF'
# The reference copy, as the image ships it.
# A comment full of things that look like shell and are not:
#   pid=$(docker inspect -f '{{.State.Pid}}' "$c") && echo "/sys/fs/cgroup$pid"
name: agent-ops
services:
  scheduler:
    image: ${AGENT_OPS_IMAGE:-ghcr.io/pullwright/agent-ops:latest}
    environment:
      NODE_NAME: ${NODE_NAME}
    command:
      - bash
      - -c
      - |
        sleep "$$AGENT_OPS_INTERVAL_SECONDS"
EOF
  [[ $# -eq 0 ]] || printf '%s\n' "$1" >> "$image_file"
}

write_env() {  # <keys...>
  : > "$env_file"
  printf '# a node.env\n' >> "$env_file"
  local k
  for k in "$@"; do printf '%s=some-secret-value\n' "$k" >> "$env_file"; done
}

reset_fixture() {
  rm -rf "$project" "$state"
  mkdir -p "$project" "$state"
  write_image_compose
  # The node's own copy starts a release behind: one material line differs.
  sed 's/^name: agent-ops$/name: agent-ops-old/' "$image_file" > "$host_file"
  write_env NODE_NAME AGENT_OPS_IMAGE
  : > "$DOCKER_STUB_LOG"
  unset DOCKER_STUB_RC
}

run_reconcile() {  # [now]
  COMPOSE_RECONCILE_PROJECT_DIR="$project" \
  COMPOSE_RECONCILE_IMAGE_FILE="$image_file" \
  COMPOSE_RECONCILE_STATE_DIR="$state" \
  COMPOSE_RECONCILE_CONFIG="$config" \
  COMPOSE_RECONCILE_DOCKER="$bin/docker" \
  COMPOSE_RECONCILE_NOW="${1:-2026-09-11T00:00:00Z}" \
  NODE_NAME=fixture-node \
    compose_reconcile_run
}

docker_calls() { wc -l < "$DOCKER_STUB_LOG" | tr -d ' '; }
events_of()   { grep -c "\"event\":\"$1\"" "$log_file" 2>/dev/null || echo 0; }
last_event()  { tail -n 1 "$log_file" 2>/dev/null; }

# --- The variable scan ---------------------------------------------------------
# Ahead of any run, because everything below depends on it being able to tell a
# required variable from the three things that merely look like one.

write_image_compose
assert_eq "only the undefaulted \${VAR} is required — a default, a \$\$ escape and a comment's shell are not" \
  "NODE_NAME" "$(compose_reconcile_required_vars "$image_file" | paste -sd, -)"

write_image_compose '    mem_limit: ${AGENT_OPS_MEM:?a node must size this}'
assert_eq "\${VAR:?…} is required too — it has no default, it has an error message" \
  "AGENT_OPS_MEM,NODE_NAME" "$(compose_reconcile_required_vars "$image_file" | paste -sd, -)"
write_image_compose

write_env NODE_NAME GH_TOKEN
assert_eq "the .env scan reports key names and never a value" \
  "GH_TOKEN,NODE_NAME" "$(compose_reconcile_env_keys "$env_file" | paste -sd, -)"

# --- No drift ------------------------------------------------------------------

reset_fixture
cp "$image_file" "$host_file"
verdict="$(run_reconcile)"
assert_eq "identical copies read in-sync" "in-sync" "$(jq -r '.status' <<<"$verdict")"
assert_eq "in-sync runs no docker command at all" "0" "$(docker_calls)"
assert_eq "in-sync is not an event — it is the steady state, and log.jsonl is replicated fleet-wide" \
  "0" "$( [[ -f "$log_file" ]] && wc -l < "$log_file" | tr -d ' ' || echo 0)"
assert_eq "the verdict is recorded even when there is nothing to do" \
  "in-sync" "$(jq -r '.status' "$marker")"

# --- The ordinary reconciliation ----------------------------------------------

reset_fixture
before_inode="$(stat -c %i "$host_file")"
before_env="$(sha256sum "$env_file" | cut -d' ' -f1)"
verdict="$(run_reconcile)"
assert_eq "drift with everything in place reconciles" "reconciled" "$(jq -r '.status' <<<"$verdict")"
assert_eq "the node's file is now the image's file, byte for byte" \
  "$(sha256sum "$image_file" | cut -d' ' -f1)" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "the verdict names both digests" \
  "$(sha256sum "$image_file" | cut -d' ' -f1)" "$(jq -r '.to' <<<"$verdict")"
assert_eq "and the digest it replaced" "1" \
  "$([[ "$(jq -r '.from' <<<"$verdict")" != "$(jq -r '.to' <<<"$verdict")" ]] && echo 1 || echo 0)"
assert_eq "the project is recreated through the node's own project directory" \
  "1" "$(grep -c -- "compose --project-directory $project up -d --remove-orphans" "$DOCKER_STUB_LOG")"
assert_eq "exactly one docker command, never one per service" "1" "$(docker_calls)"
assert_eq "the file keeps its inode — a bind-mounted file pins the inode it was created against" \
  "$before_inode" "$(stat -c %i "$host_file")"
assert_eq ".env is never written" "$before_env" "$(sha256sum "$env_file" | cut -d' ' -f1)"
assert_eq "no staging file is left behind in the node's stack directory" "0" \
  "$(find "$project" -maxdepth 1 -name '.compose.yaml.reconcile.*' | wc -l | tr -d ' ')"
assert_eq "one compose-reconciled event" "1" "$(events_of compose-reconciled)"
assert_eq "the event carries both digests" \
  "$(jq -r '.to' <<<"$verdict")" "$(jq -r '.to' <<<"$(last_event)")"
assert_eq "and no fabricated cycle id" "null" "$(jq -r '.cycle' <<<"$(last_event)")"
assert_eq "and this node's name" "fixture-node" "$(jq -r '.node' <<<"$(last_event)")"

# --- Idempotence ---------------------------------------------------------------

: > "$DOCKER_STUB_LOG"
verdict="$(run_reconcile 2026-09-11T00:05:00Z)"
assert_eq "the next tick finds nothing to do" "in-sync" "$(jq -r '.status' <<<"$verdict")"
assert_eq "and runs no docker command" "0" "$(docker_calls)"
assert_eq "and logs nothing further" "1" "$(events_of compose-reconciled)"

# --- A variable the node's .env does not define --------------------------------

reset_fixture
write_env AGENT_OPS_IMAGE          # NODE_NAME, which the new file requires, is gone
host_before="$(sha256sum "$host_file" | cut -d' ' -f1)"
verdict="$(run_reconcile)"
assert_eq "a missing required variable refuses" "refused" "$(jq -r '.status' <<<"$verdict")"
assert_contains "and names it" "NODE_NAME" "$(jq -r '.reason' <<<"$verdict")"
assert_eq "and applies nothing" "$host_before" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "and recreates nothing" "0" "$(docker_calls)"
assert_eq "one compose-reconcile-refused event" "1" "$(events_of compose-reconcile-refused)"

# The discriminating half: the same run, with the same .env, once the file's
# only requirement carries a default instead. A scan that cannot tell the two
# apart refuses every node for ever.
reset_fixture
write_env AGENT_OPS_IMAGE
sed -i 's/\${NODE_NAME}/${NODE_NAME:-unnamed}/' "$image_file"
verdict="$(run_reconcile)"
assert_eq "a defaulted variable is not a missing one" "reconciled" "$(jq -r '.status' <<<"$verdict")"

# --- A cycle in flight ---------------------------------------------------------

reset_fixture
lock_now() { printf '{"pid":1,"started_at":"%s","host":"agent-ops-scheduler"}\n' \
  "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"; }
lock_now > "$state/lock.json"
host_before="$(sha256sum "$host_file" | cut -d' ' -f1)"
verdict="$(run_reconcile)"
assert_eq "an implementation cycle in flight defers" "deferred" "$(jq -r '.status' <<<"$verdict")"
assert_eq "and nothing is applied" "$host_before" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "and nothing is recreated" "0" "$(docker_calls)"
assert_eq "one compose-reconcile-deferred event" "1" "$(events_of compose-reconcile-deferred)"

# A tick every five minutes must leave one record of a deferral, not one per
# tick: a 40-minute cycle would otherwise put eight identical lines into a log
# replicated to every node in the fleet.
run_reconcile 2026-09-11T00:05:00Z >/dev/null
run_reconcile 2026-09-11T00:10:00Z >/dev/null
assert_eq "a deferral that has not changed is not logged again" \
  "1" "$(events_of compose-reconcile-deferred)"

# The same lock, past this fixture's own lock_stale_after: the hook stops
# honouring a lock exactly where the next cycle would take it over, and so
# does this.
printf '{"pid":1,"started_at":"%s","host":"agent-ops-scheduler"}\n' \
  "$(date -u -d '10 hours ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state/lock.json"
verdict="$(run_reconcile 2026-09-11T00:15:00Z)"
assert_eq "a stale lock defers nothing" "reconciled" "$(jq -r '.status' <<<"$verdict")"

# --- roll-pending, and its scope ----------------------------------------------

reset_fixture
lock_now > "$state/lock.json"
printf '{"until":"%s"}\n' "$(date -u -d '30 minutes' +%Y-%m-%dT%H:%M:%SZ)" > "$state/roll-pending.json"
verdict="$(run_reconcile)"
assert_eq "a live roll-pending marker overrides lock.json, as it does for a roll" \
  "reconciled" "$(jq -r '.status' <<<"$verdict")"

reset_fixture
lock_now > "$state/review-lock.json"
printf '{"until":"%s"}\n' "$(date -u -d '30 minutes' +%Y-%m-%dT%H:%M:%SZ)" > "$state/roll-pending.json"
verdict="$(run_reconcile)"
assert_eq "it never overrides review-lock.json — review-cycle.sh never wrote it and never yielded anything" \
  "deferred" "$(jq -r '.status' <<<"$verdict")"

reset_fixture
lock_now > "$state/lock.json"
printf '{"until":"%s"}\n' "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state/roll-pending.json"
verdict="$(run_reconcile)"
assert_eq "an expired marker overrides nothing" "deferred" "$(jq -r '.status' <<<"$verdict")"

# --- A recreate that failed ----------------------------------------------------
# The file is installed before `up -d` runs, so drift reads in-sync from that
# moment on: without the marker's own retry state, a failed recreate would
# leave the containers stale in exactly the silence this whole mechanism
# exists to end.

reset_fixture
DOCKER_STUB_RC=1
export DOCKER_STUB_RC
verdict="$(run_reconcile)"
assert_eq "a failed recreate defers rather than refusing — it is retried" \
  "deferred" "$(jq -r '.status' <<<"$verdict")"
assert_contains "and says what docker said" "exited 1" "$(jq -r '.reason' <<<"$verdict")"
assert_eq "the file is installed regardless, so drift alone can no longer ask" \
  "$(sha256sum "$image_file" | cut -d' ' -f1)" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "so the retry rides on the verdict itself" "true" "$(jq -r '.pending_apply' "$marker")"

unset DOCKER_STUB_RC
: > "$DOCKER_STUB_LOG"
verdict="$(run_reconcile 2026-09-11T00:05:00Z)"
assert_eq "the next tick retries the recreate even though there is no drift left" \
  "reconciled" "$(jq -r '.status' <<<"$verdict")"
assert_eq "and does recreate" "1" "$(docker_calls)"
assert_eq "and the retry state is cleared" "null" "$(jq -r '.pending_apply // null' "$marker")"

# --- A node that is not configured for this ------------------------------------

reset_fixture
verdict="$(COMPOSE_RECONCILE_PROJECT_DIR="" COMPOSE_RECONCILE_IMAGE_FILE="$image_file" \
  COMPOSE_RECONCILE_STATE_DIR="$state" COMPOSE_RECONCILE_CONFIG="$config" \
  COMPOSE_RECONCILE_DOCKER="$bin/docker" COMPOSE_RECONCILE_NOW=2026-09-11T00:00:00Z \
  compose_reconcile_run)"
assert_eq "no project directory refuses, rather than guessing at one" \
  "refused" "$(jq -r '.status' <<<"$verdict")"
assert_contains "and says what to set" "AGENT_OPS_PROJECT_DIR" "$(jq -r '.reason' <<<"$verdict")"

# --- Never non-zero ------------------------------------------------------------
# This runs from cron in a container whose only job it is. Nothing reads its
# exit status, and no verdict is worth one.

( set -e; run_reconcile >/dev/null )
assert_eq "no path returns non-zero" "0" "$?"

# --- The wiring ----------------------------------------------------------------
# The library is only ever reached through the compose service and the crontab
# that call it, exactly as compose-drift.sh is only ever armed through its own
# mount line — so losing either would silently disarm every node.

compose="$SCRIPT_DIR/deploy/docker/compose.yaml"

# The service's own block, cut out of the file: everything from its key to the
# next service's. Text, not a YAML parse — this image carries python3 but no
# PyYAML, and test/compose-drift.test.sh's own mount-line check sets the
# precedent that a wiring assertion here is a `grep` against the file the
# nodes actually run.
block="$(awk '/^  reconciler:$/ {inblock=1; next}
              inblock && /^  [a-z]/ {exit}
              inblock {print}' "$compose")"

has() { grep -qE "$1" <<<"$block" && echo 1 || echo 0; }

assert_eq "compose.yaml declares a reconciler service" "1" \
  "$([[ -n "$block" ]] && echo 1 || echo 0)"
assert_eq "in the auto-update profile, with watchtower — a node opted out of new images is opted out of new deployment files" \
  "1" "$(has '^ +profiles: \[auto-update\]$')"
assert_eq "it mounts the Docker socket read-write — recreating containers is the job" \
  "1" "$(has '^ +- /var/run/docker\.sock:/var/run/docker\.sock$')"
assert_eq "and the node's project directory at the same absolute path on both sides" \
  "1" "$(has '^ +- \$\{AGENT_OPS_PROJECT_DIR:-/dev/null\}:\$\{AGENT_OPS_PROJECT_DIR:-/dev/null\}$')"
assert_eq "and runs its own crontab under supercronic" \
  "1" "$(has '^ +command: \[.supercronic., ./app/deploy/docker/reconcile-crontab.\]$')"
assert_eq "and has no network at all — a container holding the socket needs no route out" \
  "1" "$(has '^ +network_mode: none$')"
# The credential check is the containment claim the PR makes, so it is pinned
# rather than trusted to the reading: this service must take neither shared
# anchor, because those carry every token and both App private keys.
assert_eq "and takes neither credential anchor" "0" \
  "$(grep -cE '^ +<<: \*agent-ops(-env)?$' <<<"$block")"
assert_eq "and names no secret of its own" "0" \
  "$(grep -cE 'GH_TOKEN|ANTHROPIC_API_KEY|PRIVATE_KEY' <<<"$block")"

assert_eq "the reconciler's crontab runs the script the image ships" "1" \
  "$(grep -cE '^\*/[0-9]+ \* \* \* \*[[:space:]]+/app/scripts/reconcile-compose\.sh$' \
     "$SCRIPT_DIR/deploy/docker/reconcile-crontab")"
assert_eq "and that script is executable, since supercronic execs it directly" "1" \
  "$([[ -x "$SCRIPT_DIR/scripts/reconcile-compose.sh" ]] && echo 1 || echo 0)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
