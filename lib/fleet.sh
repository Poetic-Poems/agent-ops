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

# fleet_ts_field <file>
#
# A one-line JSON file's own top-level `.ts` string field — the shared read
# behind `fleet_publication_status` below, for both call sites: self's
# `.state-sync-published.json` (`{"ts":"…"}`, whole) and a peer's
# `heartbeat.json` (`{"node":…,"role":…,"ts":…,…}`, `ts` mid-object). Every
# writer of either file uses `jq -nc`, whose compact encoding is always one
# line with no inserted whitespace, so a plain prefix match is exact for the
# shape `jq -nc '{ts: $ts}'` itself produces — the fast path below, no fork —
# falling back to an actual jq parse for any other shape (`ts` not first, a
# hand-edited file, a future writer that pretty-prints) so correctness never
# depends on which shape a caller happens to hold. D14: called once per
# fleet-strip row, self included, on both a full and a fast
# publish-dashboard.sh tick, so a jq fork saved here is saved on every tick.
fleet_ts_field() {
  local file="${1:-}" line stripped
  [[ -s "$file" ]] || return 0
  # Not `read ... || return 0`: `read` itself reports failure on a file with
  # no trailing newline (every writer's `jq -nc` output has one; a test
  # fixture built with a bare `printf` does not) even though `line` still
  # holds the whole thing correctly — the read is genuinely done at EOF
  # either way, so only an empty result (an empty file, already excluded
  # above, or truly nothing readable) means bail.
  IFS= read -r line < "$file" 2>/dev/null
  [[ -n "$line" ]] || return 0
  case "$line" in
    '{"ts":"'*)
      stripped="${line#\{\"ts\":\"}"
      stripped="${stripped%%\"*}"
      printf '%s' "$stripped"
      return 0
      ;;
  esac
  # The fallback reads the whole *file*, never the one line the fast-path test
  # above needed: a pretty-printed object's first line is `{` alone, which no
  # jq parse can answer, and answering it with empty would report the node
  # `unknown` — silently stale — on the one page whose job is to be believed
  # about staleness. The fork is spent either way, so parsing all of what is
  # there costs nothing over parsing the first line of it.
  #
  # `|| true` because jq exits 5 on input it cannot parse, and this reader owes
  # its callers "the ts if there is one" rather than a status: every consumer
  # already treats an empty answer as `fleet_publication_status`'s `unknown`,
  # and `scripts/state-sync.sh` — which sources this file — runs under `set -e`,
  # where a corrupt peer heartbeat would otherwise end the run rather than the
  # read.
  jq -r '.ts // empty' < "$file" 2>/dev/null || true
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
#
# Built with `printf`, not `jq` (D14: called once per fleet-strip row, self
# included, on both a full and a fast publish-dashboard.sh tick, so a jq fork
# here counts directly against #798's fast/full cost ratio) — every field is
# already known safe: <ts> is always machine-generated (`date -u`'s own
# output or a git committer date), never free text, and <age>/verdict are
# ours to choose.
fleet_publication_status() {
  local ts="${1:-}" threshold="${2:-1800}" now="${3:-}" then_epoch age verdict
  [[ -n "$now" ]] || now="$(date -u +%s)"
  if [[ -z "$ts" ]] || ! then_epoch="$(date -u -d "$ts" +%s 2>/dev/null)" \
      || [[ -z "$then_epoch" ]]; then
    printf '{"ts":null,"age_s":null,"verdict":"unknown"}'
    return 0
  fi
  age=$(( now - then_epoch ))
  (( age < 0 )) && age=0
  verdict="fresh"
  (( age > threshold )) && verdict="stale"
  printf '{"ts":"%s","age_s":%s,"verdict":"%s"}' "$ts" "$age" "$verdict"
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

# fleet_repair_log <path> <node>
# A container killed mid-append can leave a log's size recorded while the
# data blocks behind the last few writes never reach disk: they read back as
# NUL bytes. One NUL makes the whole file binary to grep, which then stops
# printing matches for everything around it — so the damage is not the lost
# lines but every later read of whatever survived. Strip the NUL run and
# record what was dropped, rather than closing the gap silently: the loss is
# a fact about the node worth keeping.
#
# A JSONL target (PATH ending `.jsonl`) gets a JSON repair record so every
# `fromjson? // empty` reader still sees it; anything else (dashboard.log)
# gets the plain-text line that predates this generalisation. A plain-text
# line appended to a `.jsonl` file would be exactly what those readers
# silently drop, reproducing the same "loss recorded nowhere" failure this
# exists to close.
#
# A JSONL target needs more than the NUL bytes gone, because the run eats
# whatever those blocks held — the newline separators inside it included. Strip
# the bytes alone and what is left is the head of one record spliced onto the
# whole of a later one, on one line: `jq -s` still aborts over the join
# (`Expected separator between values` — the same refusal agent-ops#794 opened
# on, in different words), and every `fromjson? // empty` reader still drops the
# line with nothing saying so. Worse, a file whose tail was in flight when the
# stop came ends mid-record with no closing newline, so the repair record itself
# gets appended onto that stump and becomes the unparseable line — the one line
# whose whole job is to say something was lost.
#
# So for a JSONL target the run becomes a line break rather than nothing, and
# each resulting line survives only if it parses: the truncated stump goes, the
# intact record the run ran into is recovered whole, and the file is left
# something `jq -s` and an operator's grep can both read end to end. What went
# is counted (`dropped_lines`) beside the bytes.
#
# Cost when there is nothing to do (the normal case) is one read of PATH and
# no write; the rewrite is safe because every writer reopens by name per
# append, so none holds a descriptor across the rename.
fleet_repair_log() {
  local target="$1" node="$2" size clean tmp split dropped lines
  [[ -s "$target" ]] || return 0
  size="$(stat -c %s "$target" 2>/dev/null)" || return 0
  clean="$(tr -d '\0' < "$target" 2>/dev/null | wc -c)" || return 0
  (( clean < size )) || return 0
  dropped=$(( size - clean ))
  tmp="$target.repair.$$"
  if [[ "$target" == *.jsonl ]]; then
    split="$target.split.$$"
    # `-s` squeezes the run — and a newline the run happens to abut — down to
    # the single separator the records either side of it are missing.
    tr -s '\0' '\n' < "$target" > "$split" 2>/dev/null || { rm -f "$split"; return 0; }
    jq -R -r 'select(try (fromjson | true) catch false)' "$split" > "$tmp" 2>/dev/null \
      || { rm -f "$split" "$tmp"; return 0; }
    lines=$(( $(awk '$0 != "" {n++} END{print n+0}' "$split" 2>/dev/null || echo 0) \
        - $(awk 'END{print NR}' "$tmp" 2>/dev/null || echo 0) ))
    (( lines >= 0 )) || lines=0
    rm -f "$split"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg node "$node" \
      --argjson dropped "$dropped" --argjson lines "$lines" \
      '{ts: $ts, node: $node, event: "log-repaired", dropped_nul_bytes: $dropped,
        dropped_lines: $lines}' >> "$tmp"
  else
    tr -d '\0' < "$target" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    printf '%(%Y-%m-%dT%H:%M:%S%z)T repaired: dropped %s NUL byte(s) — an unclean stop lost the log lines in flight\n' \
      -1 "$dropped" >> "$tmp"
  fi
  mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp"
  return 0
}
