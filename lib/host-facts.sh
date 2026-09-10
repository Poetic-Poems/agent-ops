#!/usr/bin/env bash
#
# lib/host-facts.sh — the driver-independent half of the host-facts record
# (docs/HOST-FACTS-SCHEMA.md): the envelope, `host`, `updater` and
# `viewer_probe`. `lib/host-facts-compose.sh` and
# `lib/host-facts-kubernetes.sh` each add their own vantage-specific section
# on top of what this file builds; `scripts/collect-host-facts.sh` is the
# only caller of either.
#
# Every function here holds the same contract `lib/compose-drift.sh` and
# `lib/image-drift.sh` already do: one compact JSON object (or `null` for a
# whole section that does not apply), never a non-zero return, never a
# fabricated value for a fact that could not be read. This runs from a
# collector's own periodic tick, not from inside a heartbeat push, but the
# same discipline applies for the same reason — a degraded fact must not
# abort the record it would otherwise ride along in.

# host_facts_node_name — this node's own identity, the same fallback
# `state-sync.sh` already uses (`NODE_NAME`, or a bare `hostname`), so a
# record and the heartbeat beside it never disagree about whose node they
# describe.
host_facts_node_name() {
  printf '%s' "${NODE_NAME:-$(hostname 2>/dev/null || echo unknown)}"
}

# host_facts_mem_available_bytes — `MemAvailable` from /proc/meminfo, in
# bytes, or empty when the file is missing or carries no such field (a
# non-Linux dev box, a heavily sandboxed container).
host_facts_mem_available_bytes() {
  local kb=""
  kb="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  printf '%s' $(( kb * 1024 ))
}

# host_facts_mem_total_bytes — `MemTotal` from /proc/meminfo, in bytes, or
# empty when unreadable. Not namespaced (the same property
# `host_facts_mem_available_bytes` and lib/memory.sh's own `memory_total_kb`
# already rest on, verified on the ockham node 2026-09-04) — a container
# reads the real host's total, which is what lib/host-budget.sh needs to
# judge the sum of every container's declared ceiling against, not this
# container's own cgroup limit.
host_facts_mem_total_bytes() {
  local kb=""
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null)"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  printf '%s' $(( kb * 1024 ))
}

# host_facts_cpu_count — the host's own CPU count, from the number of
# `processor` lines in /proc/cpuinfo, or empty when unreadable. Read from
# /proc rather than `nproc` for the same D20 reason
# lib/host-facts-compose.sh's header gives for reading the Docker API over
# `curl` rather than the `docker` CLI: no new base-image package for a
# control-plane question still open at Phase 2. /proc/cpuinfo carries the
# same not-namespaced property /proc/meminfo does — a container sees the
# host's own CPUs, not a cpuset-restricted subset, absent an explicit
# `--cpuset-cpus` this stack never sets.
host_facts_cpu_count() {
  local n=""
  n="$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) || return 0
  printf '%s' "$n"
}

# host_facts_load_json — {"1m","5m","15m"} from /proc/loadavg, or the JSON
# literal `null` when it cannot be read.
host_facts_load_json() {
  local one="" five="" fifteen=""
  read -r one five fifteen _ < /proc/loadavg 2>/dev/null || { printf 'null'; return 0; }
  [[ -n "$one" && -n "$five" && -n "$fifteen" ]] || { printf 'null'; return 0; }
  jq -nc --argjson a "$one" --argjson b "$five" --argjson c "$fifteen" \
    '{"1m":$a,"5m":$b,"15m":$c}' 2>/dev/null || printf 'null'
}

# host_facts_disk_entry PATH — {"path","free_bytes","total_bytes"}, either
# byte count `null` when `df` cannot read PATH. Free space reuses
# lib/disk-space.sh's own `disk_space_free_kb` so this and doctor.sh's
# existing disk warning can never disagree about what a path's free space
# is.
host_facts_disk_entry() {
  local path="${1:-}" free_kb="" total_kb=""
  free_kb="$(disk_space_free_kb "$path")"
  total_kb="$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 {print $2}')"
  jq -nc --arg path "$path" \
    --argjson free "$( [[ "$free_kb" =~ ^[0-9]+$ ]] && printf '%s' $(( free_kb * 1024 )) || printf 'null' )" \
    --argjson total "$( [[ "$total_kb" =~ ^[0-9]+$ ]] && printf '%s' $(( total_kb * 1024 )) || printf 'null' )" \
    '{path:$path, free_bytes:$free, total_bytes:$total}'
}

# host_facts_default_route_iface — the network interface the kernel's
# default route (destination 0.0.0.0) uses, read straight from
# /proc/net/route so this needs no `ip`/`iproute2` binary this image does
# not carry. Empty when there is no default route, or the file cannot be
# read.
host_facts_default_route_iface() {
  awk '$2 == "00000000" {print $1; exit}' /proc/net/route 2>/dev/null
}

# host_facts_egress_mtu — the MTU of the interface the default route uses
# (/sys/class/net/<iface>/mtu), or empty when there is no default route or
# the sysfs file cannot be read.
host_facts_egress_mtu() {
  local iface="" mtu=""
  iface="$(host_facts_default_route_iface)"
  [[ -n "$iface" ]] || return 0
  mtu="$(cat "/sys/class/net/$iface/mtu" 2>/dev/null)"
  [[ "$mtu" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$mtu"
}

# host_facts_network_json — {"egress_mtu","docker_mtu_configured","mtu_match"}.
# `docker_mtu_configured` falls back to 1500, the same default
# deploy/docker/compose.yaml's own `driver_opts` uses when `DOCKER_MTU` is
# unset, so the two can never disagree about what "unset" means.
host_facts_network_json() {
  local egress_mtu="" configured="${DOCKER_MTU:-1500}"
  egress_mtu="$(host_facts_egress_mtu)"
  [[ "$configured" =~ ^[0-9]+$ ]] || configured=1500
  jq -nc \
    --argjson egress "$( [[ "$egress_mtu" =~ ^[0-9]+$ ]] && printf '%s' "$egress_mtu" || printf 'null' )" \
    --argjson configured "$configured" \
    '{egress_mtu:$egress, docker_mtu_configured:$configured,
      mtu_match:(if $egress == null then null else $egress == $configured end)}'
}

# host_facts_host_json STATE_DIR WORKSPACE_ROOT — the shared `host` section:
# memory (available and total), CPU count, load, disk on both named paths,
# and network. `mem_total_bytes`/`cpu_count` are what lib/host-budget.sh
# compares the compose driver's declared-ceiling sum against (issue #757) —
# carried here, not in the compose-only `budget` section, because they are
# facts about the host itself, true under either driver, unlike the sum
# they bound.
host_facts_host_json() {
  local state_dir="${1:-}" workspace_root="${2:-}" mem="" mem_total="" cpu_count=""
  mem="$(host_facts_mem_available_bytes)"
  mem_total="$(host_facts_mem_total_bytes)"
  cpu_count="$(host_facts_cpu_count)"
  jq -nc \
    --argjson mem "$( [[ "$mem" =~ ^[0-9]+$ ]] && printf '%s' "$mem" || printf 'null' )" \
    --argjson mem_total "$( [[ "$mem_total" =~ ^[0-9]+$ ]] && printf '%s' "$mem_total" || printf 'null' )" \
    --argjson cpu_count "$( [[ "$cpu_count" =~ ^[0-9]+$ ]] && printf '%s' "$cpu_count" || printf 'null' )" \
    --argjson load "$(host_facts_load_json)" \
    --argjson state_disk "$(host_facts_disk_entry "$state_dir")" \
    --argjson workspace_disk "$(host_facts_disk_entry "$workspace_root")" \
    --argjson network "$(host_facts_network_json)" \
    '{mem_available_bytes:$mem, mem_total_bytes:$mem_total, cpu_count:$cpu_count, load:$load,
      disk:{state_dir:$state_disk, workspace_root:$workspace_disk},
      network:$network}'
}

# host_facts_updater_ledger_tail LEDGER_DIR [N] — the last N (default 5)
# parsed entries across *every* `*.jsonl` in LEDGER_DIR, merged and ordered
# by each entry's own `ts`, oldest first, as a JSON array.
#
# Every file in the directory, not one named for the querying node. The
# ledger's only writer (`deploy/docker/watchtower-pre-update.sh`) keys each
# file by the *writing container's* own `$HOSTNAME`, which on this stack is
# a Docker-generated container ID; this collector knows only `NODE_NAME`
# ("poetic-1"). The two can never be equal, so reading a single
# `<NODE_NAME>.jsonl` published `ledger_tail: []` on every compose node
# while a populated ledger sat beside it in the same directory —
# indistinguishable from a genuinely empty ledger, and exactly the
# wrong-but-plausible fact `docs/HOST-FACTS-SCHEMA.md`'s "null, never
# fabricated" contract exists to prevent. Reading the whole directory is
# also what `lib/updater-health.sh`'s own cross-generation scan already
# does for the same reason: a roll's replacement writes under a new
# container ID, so one node's updater history is spread across files by
# construction.
#
# The directory is this node's own `state_dir` — a peer's copy lands under
# `<peers_dir>/<peer>/`, never here — so every file in it is this node's
# own history. Sibling *services* do share it (the scheduler and dashboard
# containers hold the same state volume), which is why each entry keeps its
# own `service` field: that, not the filename, is what tells one service's
# line from another's now that they are read together.
#
# `tail -q -n "$n"` per file before the merge bounds the read without
# changing the answer: each file is append-ordered by `ts`, so the global
# newest N is always a subset of the per-file newest N. `-R` (raw input) so
# one malformed line is skipped rather than aborting the whole parse — the
# same discipline `lib/updater-health.sh`'s own line-at-a-time reads hold,
# and the reason this is not a plain `jq -cs .` slurp. Empty array when the
# directory is missing, holds no `.jsonl` file, or every line in it is
# malformed — never fatal to the caller.
host_facts_updater_ledger_tail() {
  local ledger_dir="${1:-}" n="${2:-5}" f="" found=0
  [[ -d "$ledger_dir" ]] || { printf '[]'; return 0; }
  for f in "$ledger_dir"/*.jsonl; do
    [[ -f "$f" ]] && { found=1; break; }
  done
  (( found )) || { printf '[]'; return 0; }
  tail -q -n "$n" "$ledger_dir"/*.jsonl 2>/dev/null \
    | jq -Rc '[try fromjson catch empty]' 2>/dev/null \
    | jq -sc --argjson n "$n" 'map(.[]) | sort_by(.ts // "") | .[-$n:]' 2>/dev/null \
    || printf '[]'
}

# host_facts_parse_last_session LOG-TEXT — {"ts","failed","scanned","updated"}
# from the newest `Session done Failed=<n> Scanned=<n> Updated=<n>` line in
# LOG-TEXT (a watchtower container's own log), `null` when no such line is
# present. `ts` is whatever ISO-ish timestamp the log line itself leads
# with, verbatim, `null` when the line carries none this can recognise —
# never guessed from the collector's own clock, which describes when this
# ran, not when the session finished.
host_facts_parse_last_session() {
  local line=""
  line="$(grep -aF 'Session done' <<<"${1:-}" 2>/dev/null | tail -n 1)"
  [[ -n "$line" ]] || { printf 'null'; return 0; }
  local ts="" failed="" scanned="" updated=""
  # logrus's default text formatter fronts every line with `time="<ts>"
  # level=..."` — the timestamp watchtower itself stamped the session with,
  # never this collector's own clock.
  ts="$(grep -aoE 'time="[^"]+"' <<<"$line" | head -n 1 | sed -e 's/^time="//' -e 's/"$//')"
  failed="$(grep -aoE 'Failed=[0-9]+' <<<"$line" | head -n 1 | cut -d= -f2)"
  scanned="$(grep -aoE 'Scanned=[0-9]+' <<<"$line" | head -n 1 | cut -d= -f2)"
  updated="$(grep -aoE 'Updated=[0-9]+' <<<"$line" | head -n 1 | cut -d= -f2)"
  [[ "$failed" =~ ^[0-9]+$ && "$scanned" =~ ^[0-9]+$ && "$updated" =~ ^[0-9]+$ ]] || { printf 'null'; return 0; }
  jq -nc \
    --argjson ts "$( [[ -n "$ts" ]] && jq -nc --arg t "$ts" '$t' || printf 'null' )" \
    --argjson failed "$failed" --argjson scanned "$scanned" --argjson updated "$updated" \
    '{ts:$ts, failed:$failed, scanned:$scanned, updated:$updated}'
}

# host_facts_updater_json STATE_DIR [LOG-TEXT] — the `updater` section: the
# ledger tail plus, when LOG-TEXT is given, the last session result parsed
# from it. `null` whole when neither the ledger directory nor any log text
# exists — no updater runs on this node at all. Takes no node name: the
# ledger is keyed by the writing container's hostname, never by
# `NODE_NAME`, so there is nothing here for one to select (see
# `host_facts_updater_ledger_tail`).
host_facts_updater_json() {
  local state_dir="${1:-}" log_text="${2:-}" ledger_dir=""
  ledger_dir="$state_dir/updater-ledger"
  if [[ ! -d "$ledger_dir" && -z "$log_text" ]]; then
    printf 'null'
    return 0
  fi
  jq -nc \
    --argjson tail "$(host_facts_updater_ledger_tail "$ledger_dir")" \
    --argjson last "$(host_facts_parse_last_session "$log_text")" \
    '{ledger_tail:$tail, last_session:$last}'
}

# host_facts_viewer_probe_one NODE URL [CURL-CMD] — one entry's own value:
# {"ok":true,"bytes":N,"seconds":N} on a fetch that both succeeds and parses
# as JSON, {"ok":false,"bytes":null,"seconds":null,"reason":"..."} otherwise.
# CURL-CMD defaults to `curl`; the test suite points it at a fixture
# standing in for the network, the same override shape
# `IMAGE_DRIFT_CURL_CMD` already gives `lib/image-drift.sh`.
host_facts_viewer_probe_one() {
  local node="${1:-}" url="${2:-}" curl_cmd="${3:-${HOST_FACTS_CURL_CMD:-curl}}"
  local start="" end="" body="" rc=0 seconds=""
  start="$(date +%s.%N 2>/dev/null || date +%s)"
  body="$($curl_cmd -fsS --max-time "${HOST_FACTS_VIEWER_PROBE_TIMEOUT:-5}" "$url" 2>/dev/null)"
  rc=$?
  end="$(date +%s.%N 2>/dev/null || date +%s)"
  seconds="$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f", e - s}' 2>/dev/null || echo 0)"
  if (( rc != 0 )) || [[ -z "$body" ]]; then
    jq -nc --argjson s "$seconds" \
      '{ok:false, bytes:null, seconds:null, reason:"fetch failed"}' 2>/dev/null \
      || printf '{"ok":false,"bytes":null,"seconds":null,"reason":"fetch failed"}'
    return 0
  fi
  if ! jq -e . >/dev/null 2>&1 <<<"$body"; then
    jq -nc --argjson bytes "${#body}" \
      '{ok:false, bytes:$bytes, seconds:null, reason:"body did not parse as JSON"}'
    return 0
  fi
  jq -nc --argjson bytes "${#body}" --argjson seconds "$seconds" \
    '{ok:true, bytes:$bytes, seconds:$seconds, reason:null}'
}

# host_facts_viewer_probe_json NODE-LIST URL-TEMPLATE [CURL-CMD] — the whole
# `viewer_probe` object, one key per line of NODE-LIST (blank lines
# skipped). URL-TEMPLATE carries a literal `{node}` this substitutes each
# node's name into — the caller decides the scheme, host suffix and port
# (see scripts/collect-host-facts.sh), this file only runs the probe.
host_facts_viewer_probe_json() {
  local node_list="${1:-}" url_template="${2:-}" curl_cmd="${3:-}"
  local out="{}" node="" url="" entry=""
  [[ -n "$url_template" ]] || { printf '{}'; return 0; }
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    url="${url_template//\{node\}/$node}"
    entry="$(host_facts_viewer_probe_one "$node" "$url" "$curl_cmd")"
    out="$(jq -nc --argjson o "$out" --arg n "$node" --argjson e "$entry" '$o + {($n): $e}' 2>/dev/null || printf '%s' "$out")"
  done <<<"$node_list"
  printf '%s' "$out"
}
