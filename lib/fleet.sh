#!/usr/bin/env bash
#
# lib/fleet.sh — where the fleet's shared memory lands on disk, and the union
# read over it. Sourced by both pipelines and scripts/state-sync.sh so the
# path convention exists in exactly one place.

# Peers' state trees, one directory per node, materialised by
# `state-sync.sh fetch` from the state repository's nodes/* branches.
fleet_peers_dir() {  # <workspace_root>
  printf '%s/.agent-ops-peers' "$1"
}

# The peers directory's own freshness marker (requirement 2.5, #693):
# `state-sync.sh fetch` writes it after every attempt —
# `{"ok":true,"ts":…}` once the peer trees below it were just materialised
# from a successful fetch, `{"ok":false,"ts":…}` while a real failure (bad
# credentials, network outage, a corrupt mirror) is in force. A reader that
# cares whether the peer copies it is about to union might be frozen reads
# this rather than trusting a directory that looks populated either way — an
# absent marker is the genuine bootstrap case: no fetch has ever succeeded,
# because the state repository has no node branches yet.
fleet_peers_marker() {  # <peers_dir>
  printf '%s/.last-fetch.json' "$1"
}

# Written whole and renamed into place, for the same reason the peer trees
# beside it are: a reader is a separate process on the same machine, and a
# plain `> marker` truncates the file at redirection and fills it a moment
# later, so a read landing in that window sees an empty file rather than
# either the old answer or the new one.
fleet_mark_peers() {  # <peers_dir> true|false
  local dir="$1" ok="$2" marker
  mkdir -p "$dir"
  marker="$(fleet_peers_marker "$dir")"
  jq -nc --argjson ok "$ok" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ok: $ok, ts: $ts}' > "$marker.tmp" \
    && mv -f "$marker.tmp" "$marker"
}

# fleet_logs_healthy <state_dir> <peers_dir> <union_log>
# True when UNION_LOG — the snapshot `fleet_logs` above just wrote — is fit to
# read a *negative* off: "no open block exists," not merely "no open block is
# visible from here" (agent-ops#816 review, requirement 38b). `fleet_logs`
# degrades silently, emitting nothing at all when STATE_DIR/log.jsonl is
# absent and PEERS_DIR is empty — a fresh node before its first state-sync, a
# mirror just discarded and rebuilt (requirement 2.5's own corruption path),
# or a fetch cron that has been failing all produce exactly that, and an
# empty union is indistinguishable from "the fleet genuinely has no blocks" to
# a reader that only ever acts on positive log evidence until now. Unhealthy
# in either of two ways this checks in order: the union itself came back
# empty, or PEERS_DIR's own freshness marker (`fleet_mark_peers`, above) says
# the last fetch attempt failed — a marker no reader consulted before this.
# A marker that does not exist yet (no `state-sync.sh fetch` has ever run) is
# not itself a failure — the union's own emptiness already catches that
# node — so it is read as healthy here.
fleet_logs_healthy() {  # <state_dir> <peers_dir> <union_log>
  local peers="$2" union_log="$3" marker
  [[ -s "$union_log" ]] || return 1
  marker="$(fleet_peers_marker "$peers")"
  if [[ -s "$marker" ]]; then
    [[ "$(jq -r '.ok // false' "$marker" 2>/dev/null)" == "true" ]] || return 1
  fi
  return 0
}

# fleet_publication_status <ts> <threshold_s> [now_epoch]
#
# The one verdict over a publication timestamp — self's or a peer's alike
# (agent-ops#602). A node's freshness is a fact about what it last actually
# published into the shared state, never about its own local clock: on
# 2026-08-08 both laptop nodes reported themselves fresh for four days while
# publishing nothing, because the self row used to be built from `date` and
# a hardcoded `false` rather than read back from anywhere. Called once per
# row by both scripts/publish-dashboard.sh (every fleet.nodes[] row, self
# included) and scripts/doctor.sh (this node's own row), so the two can
# never derive it differently (requirement 34a) — a peer's <ts> is its
# heartbeat's own `ts`; self's is `.state-sync-published.json`'s `ts`
# (scripts/state-sync.sh's `do_fetch`, reading back what the shared state
# holds for this node's own branch).
#
#   {ts: null, age_s: null, verdict: "unknown"}
#     <ts> is empty or does not parse — no publication has ever been read
#     back for this node/peer. Not itself a failure: a fresh install, or the
#     short window before a node's first successful push has been fetched
#     back at all.
#   {ts: "…", age_s: N, verdict: "fresh"|"stale"}
#     N seconds have passed since the shared state last held a publication
#     from this node/peer; "stale" once N exceeds <threshold_s>
#     (`node_stale_after_minutes * 60`).
fleet_publication_status() {
  local ts="${1:-}" threshold="${2:-1800}" now="${3:-}" then_epoch age verdict
  [[ -n "$now" ]] || now="$(date -u +%s)"
  if [[ -z "$ts" ]]; then
    jq -nc '{ts: null, age_s: null, verdict: "unknown"}'
    return 0
  fi
  if ! then_epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || [[ -z "$then_epoch" ]]; then
    jq -nc '{ts: null, age_s: null, verdict: "unknown"}'
    return 0
  fi
  age=$(( now - then_epoch ))
  (( age < 0 )) && age=0
  verdict="fresh"
  (( age > threshold )) && verdict="stale"
  jq -nc --arg ts "$ts" --argjson age "$age" --arg v "$verdict" \
    '{ts: $ts, age_s: $age, verdict: $v}'
}

# The fleet's event stream: this node's own log followed by every peer's,
# sorted into time order (each line begins {"ts":"…", so a plain byte sort is
# a time sort). The consumers that reduce by most-recent-event-wins — the
# blocked and void extractions (requirement 34/34c), the no-op fingerprint
# (3b), the usage-limit cooldown (2.1) — need the order, not the provenance;
# requirement 33 stamps `node` on every event for anything that does. The
# union is advisory speed — a lesson one node learned sparing the rest — and
# the claims of requirement 17a are the lock underneath it.
fleet_logs() {  # <state_dir> <peers_dir> [log-basename]
  local state_dir="$1" peers="$2" name="${3:-log.jsonl}" f
  {
    [[ -f "$state_dir/$name" ]] && cat "$state_dir/$name"
    for f in "$peers"/*/"$name"; do
      [[ -f "$f" ]] && cat "$f"
    done
  } 2>/dev/null | sort
  return 0
}
