#!/usr/bin/env bash
#
# lib/compose-reconcile.sh — apply this node's own merged compose.yaml, the
# way watchtower applies a merged image.
#
# lib/compose-drift.sh answers "has this node's compose.yaml fallen behind the
# copy its image shipped". It has been answering "yes" on nodes for days at a
# time, because the only thing that could act on the answer was a human
# running `docker compose up -d` on that host: an image roll recreates a
# container from the *old* container's Config, so labels, service environment,
# mounts and whole new services merged to `main` sit inert on every node until
# someone visits it. Two escalations in one week (agent-ops#1266's
# `memory.high` parent, agent-ops#1339's collector change) existed only to ask
# the owner to perform that visit.
#
# This library is the deterministic actor the badge never had. No model is in
# this path and none can be: the file it installs is the one that arrived
# through the image, byte for byte, and the only decision taken here is
# whether now is a safe moment to install it.
#
# What it will do, and nothing else:
#
#   1. compare the node's own compose.yaml against the image's copy, through
#      lib/compose-drift.sh — the same comparison the heartbeat badge makes,
#      so the actor and the alarm can never disagree about what drift is;
#   2. check every `${VAR}` the *new* file requires against the keys in the
#      node's `.env`, and refuse outright if one is missing;
#   3. honour the cycle lock and the roll-pending marker exactly as
#      deploy/docker/watchtower-pre-update.sh does, so a compose recreate can
#      no more kill a running cycle than an image roll can;
#   4. copy the image's copy over the node's, and run
#      `docker compose up -d --remove-orphans` for that project.
#
# It never touches `.env`. That file holds the node's identity and its live
# credentials, it is the one file that legitimately differs between two nodes,
# and it is the owner's. The env check reads *key names only* — the
# `sed` below discards everything after the `=` before anything is printed —
# so no value is read into a variable, logged, or compared; the same idea the
# workstation's own `env-key-hash.sh` uses to compare a node's `.env` against
# its running containers without ever handling what is in it.
#
# **The copy is written in place, not renamed.** A bind mount of a *file*
# pins the inode it was created against, so `mv`-ing a new file over
# compose.yaml would leave every already-running container's
# `/host/compose.yaml` showing the old content — and `compose up -d` recreates
# only the services whose own config changed, so a node that took a merged
# change adding one new service would go on reporting `compose drifted` from
# every container the change did not touch, for ever, with nothing left to
# reconcile. Truncating the existing inode instead makes the new content
# visible through every existing mount the moment it lands. The write is
# staged beside the target and verified byte-for-byte first, so the
# non-atomic step is a single local copy of an already-checked file.
#
# Verdicts, one compact JSON object, written to `$state_dir/.compose-
# reconcile.json` and carried to every dashboard in this node's heartbeat
# (IMPLEMENTATION-PIPELINE-SPEC requirement 2.5a):
#
#   {status:"in-sync", at}                  nothing to do
#   {status:"reconciled", at, from, to}     the file was replaced and the
#                                           project recreated; `from`/`to` are
#                                           the SHA-256 of the old and new file
#   {status:"deferred", at, reason}         a cycle is in flight, or the
#                                           recreate itself failed — retried on
#                                           the next tick either way
#   {status:"refused", at, reason}          the node is not configured for
#                                           reconciliation, or the new file
#                                           needs a `${VAR}` its `.env` does
#                                           not define. Nothing was applied.
#
# A failed `docker compose up -d` is `deferred` rather than `refused` because
# it is retried: the file has already been replaced by then, so drift alone
# would never ask again — `pending_apply` on the marker is what makes the next
# tick retry the recreate it could not finish, and it is the one piece of
# state this library keeps across ticks.
#
# Events reach `$state_dir/log.jsonl` through lib/log-event.sh's envelope, and
# only on a *transition*: this runs every few minutes, and a node that defers
# through a 40-minute cycle must leave one record of the deferral, not eight.
#
# Every path override exists for the tests, which must control all of them and
# must never reach a real Docker socket: COMPOSE_RECONCILE_PROJECT_DIR,
# _IMAGE_FILE, _STATE_DIR, _CONFIG, _DOCKER (the `docker` command itself,
# stubbed), _NOW.

# shellcheck source=lib/compose-drift.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compose-drift.sh"
# shellcheck source=lib/log-event.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/log-event.sh"

# The SHA-256 of a file, or the empty string. Identifies *which* compose file
# was installed in a way a line count cannot, and both digests ride the
# `compose-reconciled` event so a later reader can tell one reconciliation
# from another without the files themselves.
compose_reconcile_sha() {
  [[ -f "$1" ]] || return 0
  sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# The `${VAR}` references a compose file needs the environment to supply,
# sorted and de-duplicated: the braced forms only, and only those with no
# default or alternate — `${VAR}` and `${VAR:?…}`/`${VAR?…}`, never
# `${VAR:-…}`, `${VAR-…}`, `${VAR:+…}` or `${VAR+…}`, all of which compose
# resolves on its own when the variable is unset.
#
# Whole-line comments go first, through the identical filter
# lib/compose-drift.sh applies — partly so the two agree about what is
# material, and partly because this file's comments are full of prose that
# looks like shell (`$pid`, `$(sed …)`), none of which compose ever sees: it
# parses YAML before it interpolates, so a comment is gone before
# interpolation begins. `$$` is compose's own escape for a literal `$`, so it
# is stripped before the scan and `$${VAR}` correctly matches nothing.
#
# Braced forms only, deliberately. A bare `$VAR` is legal compose and is not
# looked for: this file does not use it, and a scan loose enough to catch it
# is loose enough to read the shell fragments in a comment that survived the
# filter as node configuration — a false refusal, which here means a node that
# stops reconciling itself and says a merged change is missing a variable that
# does not exist.
compose_reconcile_required_vars() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" 2>/dev/null \
    | sed 's/\$\$//g' \
    | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*(\}|:?[-+?][^}]*\})' \
    | sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*)(\}|:?([-+?])[^}]*\})$/\1 \3/' \
    | awk '$2 == "" || $2 == "?" { print $1 }' \
    | sort -u
}

# The key names an `.env` file defines, sorted and de-duplicated. Names only:
# the substitution keeps capture group 2 and discards the whole of the rest of
# the line, so no value ever reaches stdout, a variable, or a comparison. A
# missing or unreadable file is an empty set rather than an error — the caller
# decides what that means.
compose_reconcile_env_keys() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*$/\2/p' \
    "$file" 2>/dev/null | sort -u
}

# The set difference: what the new compose file requires and the node's `.env`
# does not define, one name per line. Empty output is the passing case.
compose_reconcile_missing_env() {  # <compose-file> <env-file>
  comm -23 \
    <(compose_reconcile_required_vars "$1") \
    <(compose_reconcile_env_keys "$2") 2>/dev/null || true
}

# A one-line description of a lock this container must respect, or nothing.
#
# The judgement is deploy/docker/watchtower-pre-update.sh's, and this is
# deliberately only its *foreign* branch: that script runs inside the
# container it is about to destroy and so can meaningfully ask whether its own
# pid is alive, while this one runs in a container that writes neither lock
# and shares no PID namespace with whatever did. A pid is meaningful only
# inside the namespace that minted it (agent-ops#130), so every lock is
# honoured here without a liveness check, until it is released or until it
# passes the same `lock_stale_after` the next cycle would take it over at. The
# asymmetry is priced exactly as the hook prices it: honouring a dead lock
# costs one tick's delay, and the next tick is five minutes away.
compose_reconcile_lock_held() {  # <lock-file> <stale-after-hours>
  local f="$1" stale_after_hours="$2" pid started_at host started_epoch now_epoch
  [[ -f "$f" ]] || return 0
  pid="$(jq -r '.pid // empty' "$f" 2>/dev/null || true)"
  started_at="$(jq -r '.started_at // empty' "$f" 2>/dev/null || true)"
  host="$(jq -r '.host // empty' "$f" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  # An unparseable `started_at` reads as epoch 0 and so as impossibly old —
  # the hook's own convention, and `acquire_lock`'s: a lock whose age cannot
  # be established is one the next cycle would take over, and nothing here
  # should protect what the pipeline itself would not.
  started_epoch="$(date -d "$started_at" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  (( now_epoch - started_epoch < stale_after_hours * 3600 )) || return 0
  # The description deliberately carries no age. It is the key the transition
  # check compares one tick against the next (`_compose_reconcile_settle`), and
  # a live age makes every tick a transition: a node deferring through a
  # 40-minute cycle would log eight identical deferrals into a log replicated
  # to every peer. What is stable while a lock is held — which lock, whose
  # container, since when — is exactly what a reader needs, and the age is
  # arithmetic on the timestamp already in it.
  printf '%s held by container %s since %s' \
    "$(basename "$f")" "${host:-unknown}" "${started_at:-unknown}"
}

# Print a reason and succeed iff `$state_dir/roll-pending.json` names an
# `until` that has not passed — agent-ops#1096's marker, read here exactly as
# the pre-update hook reads it, including its scope: it overrides `lock.json`
# alone and never `review-lock.json`, because review-cycle.sh never wrote it
# and never agreed to be destroyed (agent-ops#1102). An unparseable `until`
# reads as epoch 0, so a corrupt marker never grants an allow it did not earn.
compose_reconcile_roll_pending() {  # <state-dir>
  local f="$1/roll-pending.json" until_ts until_epoch now_epoch
  [[ -f "$f" ]] || return 1
  until_ts="$(jq -r '.until // empty' "$f" 2>/dev/null || true)"
  [[ -n "$until_ts" ]] || return 1
  until_epoch="$(date -d "$until_ts" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  (( until_epoch > now_epoch )) || return 1
  printf 'a roll-pending marker from the last cycle boundary is in force until %s' "$until_ts"
}

# The verdict file itself — `$state_dir/.compose-reconcile.json` — is read
# rather than recomputed by everything that reports it (scripts/state-sync.sh
# for the heartbeat, scripts/publish-dashboard.sh for this node's own row),
# with the one-line `jq -c '.' … || echo null` those scripts already use for
# `.stage-health.json` and `.doctor-status.json`. Same reason: the reconciler
# runs on its own schedule in its own container, and a second computation
# elsewhere would be free to disagree with what that container actually did.
# It is local to this node and excluded from replication, like every other
# file of its kind; only the verdict travels, folded into the heartbeat.

# --- The run itself -----------------------------------------------------------

# compose_reconcile_run — one tick. Prints the verdict object and returns 0 on
# every path: this runs from cron in a container whose only job it is, and no
# verdict is worth a non-zero exit that nothing reads.
compose_reconcile_run() {
  local project_dir image_file state_dir config_file docker_cmd now
  project_dir="${COMPOSE_RECONCILE_PROJECT_DIR:-${AGENT_OPS_PROJECT_DIR:-}}"
  image_file="${COMPOSE_RECONCILE_IMAGE_FILE:-}"
  [[ -n "$image_file" ]] \
    || image_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/deploy/docker/compose.yaml"
  state_dir="${COMPOSE_RECONCILE_STATE_DIR:-}"
  config_file="${COMPOSE_RECONCILE_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config.json}"
  docker_cmd="${COMPOSE_RECONCILE_DOCKER:-docker}"
  now="${COMPOSE_RECONCILE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

  local host_file="$project_dir/compose.yaml" env_file="$project_dir/.env"

  # --- Is this node configured for reconciliation at all? ---------------------
  # The project directory is bind-mounted at the *same absolute path* it has
  # on the host (deploy/docker/compose.yaml's `reconciler` service), which is
  # what makes the relative bind mounts inside compose.yaml — `./compose.yaml`,
  # `./ts-serve.json` — resolve to the same paths for the daemon as for the
  # CLI. Unset, it self-mounts as /dev/null and there is nothing to reconcile
  # against; that is a refusal, recorded once, not an error every tick.
  if [[ -z "$project_dir" || ! -d "$project_dir" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "the node's project directory is not bind-mounted into this container — set AGENT_OPS_PROJECT_DIR in .env to the directory holding compose.yaml, then run docker compose up -d once"
    return 0
  fi
  if [[ ! -f "$host_file" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "there is no compose.yaml in $project_dir — AGENT_OPS_PROJECT_DIR must name this stack's own directory, the one holding the compose.yaml this node runs"
    return 0
  fi
  if [[ ! -w "$host_file" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "$host_file is not writable from this container — the project directory must be bind-mounted read-write"
    return 0
  fi

  # --- Drift, through the same library the badge uses -------------------------
  local drift drift_status
  drift="$(COMPOSE_DRIFT_HOST="$host_file" COMPOSE_DRIFT_IMAGE="$image_file" compose_drift_status)"
  drift_status="$(jq -r '.status // "null"' <<<"$drift" 2>/dev/null || echo null)"
  if [[ "$drift_status" == "null" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "this image carries no copy of compose.yaml to reconcile against"
    return 0
  fi

  # A recreate that failed last tick is retried whatever drift now says: the
  # file was already replaced before the recreate ran, so drift reads in-sync
  # from that moment on and would otherwise never ask again — the containers
  # staying stale in exactly the silence this whole mechanism exists to end.
  local pending_apply=false
  [[ "$(jq -r '.pending_apply // false' "$state_dir/.compose-reconcile.json" 2>/dev/null || echo false)" == "true" ]] \
    && pending_apply=true

  if [[ "$drift_status" == "in-sync" && "$pending_apply" != "true" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" in-sync ""
    return 0
  fi

  # --- The `.env` gate --------------------------------------------------------
  local missing
  missing="$(compose_reconcile_missing_env "$image_file" "$env_file" | paste -sd, - 2>/dev/null || true)"
  if [[ -n "$missing" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" refused \
      "the merged compose.yaml requires ${missing}, which this node's .env does not define and the file itself gives no default for — add it to .env by hand; nothing was applied"
    return 0
  fi

  # --- The cycle lock, and roll-pending ---------------------------------------
  local cycle_stale review_stale held
  cycle_stale="$(jq -r '.lock_stale_after // 4' "$config_file" 2>/dev/null || echo 4)"
  review_stale="$(jq -r '.project_review.lock_stale_after // 6' "$config_file" 2>/dev/null || echo 6)"
  [[ "$cycle_stale"  =~ ^[0-9]+$ ]] || cycle_stale=4
  [[ "$review_stale" =~ ^[0-9]+$ ]] || review_stale=6

  # A held `lock.json` defers, unless the roll-pending marker overrides it —
  # the hook's own rule, and its own scope: `review-lock.json` below is never
  # overridden.
  held="$(compose_reconcile_lock_held "$state_dir/lock.json" "$cycle_stale")"
  if [[ -n "$held" ]] && ! compose_reconcile_roll_pending "$state_dir" >/dev/null; then
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "an implementation cycle is in flight ($held) — retrying on the next tick"
    return 0
  fi
  held="$(compose_reconcile_lock_held "$state_dir/review-lock.json" "$review_stale")"
  if [[ -n "$held" ]]; then
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "a project review is in flight ($held) — retrying on the next tick"
    return 0
  fi

  # --- Apply ------------------------------------------------------------------
  local from_sha to_sha
  from_sha="$(compose_reconcile_sha "$host_file")"
  to_sha="$(compose_reconcile_sha "$image_file")"

  if [[ "$from_sha" != "$to_sha" ]]; then
    if ! _compose_reconcile_install "$image_file" "$host_file" "$to_sha"; then
      _compose_reconcile_settle "$state_dir" "$now" deferred \
        "could not write $host_file — retrying on the next tick"
      return 0
    fi
  fi

  local up_log up_rc=0
  up_log="$("$docker_cmd" compose --project-directory "$project_dir" \
    up -d --remove-orphans 2>&1)" || up_rc=$?
  if (( up_rc != 0 )); then
    # The file is installed and the containers are not yet created from it, so
    # the retry has to be driven by the marker rather than by drift.
    # The docker output rides in `detail`, never in `reason`: `reason` is what
    # the transition test compares one tick against the next, and compose's
    # own last line carries timings and progress that differ every run — in
    # `reason` it would make every retry a fresh transition and log one event
    # per tick, the same trap the lock description's age already sprang once.
    _compose_reconcile_settle "$state_dir" "$now" deferred \
      "docker compose up -d exited $up_rc — the file is installed, retrying the recreate on the next tick" \
      true "" "" "$(printf '%s' "$up_log" | tail -n 1)"
    return 0
  fi

  _compose_reconcile_settle "$state_dir" "$now" reconciled "" false "$from_sha" "$to_sha"
  return 0
}

# Stage the image's copy beside the target, prove it arrived intact, then
# truncate the target in place and write it. In place because a bind-mounted
# file pins its inode — see the header. `cp` to a dotfile in the same
# directory keeps the staging on the same filesystem as the target and out of
# the way of `check-node-compose.sh`'s own backup-file check, which looks for
# `.env` backups specifically.
_compose_reconcile_install() {  # <image-file> <host-file> <expected-sha>
  local src="$1" dst="$2" want="$3" staged
  staged="$(dirname "$dst")/.compose.yaml.reconcile.$$"
  cp -- "$src" "$staged" 2>/dev/null || { rm -f -- "$staged"; return 1; }
  if [[ "$(compose_reconcile_sha "$staged")" != "$want" ]]; then
    rm -f -- "$staged"
    return 1
  fi
  cat -- "$staged" > "$dst" 2>/dev/null || { rm -f -- "$staged"; return 1; }
  rm -f -- "$staged"
  return 0
}

# Record the verdict, and log it iff it is a *transition* — a different status,
# or a different reason for the same status. A tick every few minutes must not
# write eight identical deferrals through one long cycle; what a reader needs
# is when the node entered this state and why.
#
# `detail` is recorded but never compared: it is for whatever varies run to
# run — a command's own last line of output — which in `reason` would defeat
# the whole transition test.
_compose_reconcile_settle() {  # <state-dir> <now> <status> <reason> [pending] [from] [to] [detail]
  local state_dir="$1" now="$2" status="$3" reason="$4" pending="${5:-false}" from="${6:-}" to="${7:-}" detail="${8:-}"
  local marker="$state_dir/.compose-reconcile.json" previous="" prev_status="" prev_reason=""
  local verdict=""

  verdict="$(jq -nc --arg at "$now" --arg s "$status" --arg r "$reason" \
    --argjson p "${pending:-false}" --arg from "$from" --arg to "$to" --arg d "$detail" \
    '{status: $s, at: $at}
     + (if $r  == "" then {} else {reason: $r} end)
     + (if $d  == "" then {} else {detail: $d} end)
     + (if $to == "" then {} else {from: (if $from == "" then null else $from end), to: $to} end)
     + (if $p then {pending_apply: true} else {} end)' 2>/dev/null)" || return 0
  [[ -n "$verdict" ]] || return 0

  if [[ -n "$state_dir" && -d "$state_dir" ]]; then
    previous="$(cat "$marker" 2>/dev/null || true)"
    prev_status="$(jq -r '.status // ""' <<<"$previous" 2>/dev/null || true)"
    prev_reason="$(jq -r '.reason // ""' <<<"$previous" 2>/dev/null || true)"
    if printf '%s\n' "$verdict" > "$marker.tmp.$$" 2>/dev/null; then
      mv "$marker.tmp.$$" "$marker" 2>/dev/null || rm -f "$marker.tmp.$$" 2>/dev/null
    else
      rm -f "$marker.tmp.$$" 2>/dev/null
    fi
  fi

  printf '%s\n' "$verdict"

  # `in-sync` is the steady state and has no event: a node that is doing
  # nothing because there is nothing to do is not news, and log.jsonl is
  # replicated to every peer.
  [[ "$status" != "in-sync" ]] || return 0
  [[ "$status" != "$prev_status" || "$reason" != "$prev_reason" ]] || return 0
  [[ -n "$state_dir" && -d "$state_dir" ]] || return 0

  local event fields
  case "$status" in
    reconciled) event=compose-reconciled ;;
    deferred)   event=compose-reconcile-deferred ;;
    refused)    event=compose-reconcile-refused ;;
    *)          return 0 ;;
  esac
  fields="$(jq -c 'del(.status, .at)' <<<"$verdict" 2>/dev/null || echo '{}')"
  # No cycle id: this runs outside any cycle, in its own container, and a
  # fabricated one would be worse than an honest null — the same discipline
  # scripts/publish-revert-rate.sh's own out-of-cycle rows already keep.
  log_event_append "$state_dir/log.jsonl" cycle "" "${NODE_NAME:-${HOSTNAME:-unknown}}" "$event" "$fields"
}
