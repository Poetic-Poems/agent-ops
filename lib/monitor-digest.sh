#!/usr/bin/env bash
# shellcheck disable=SC2016
# SC2016: the backticks in the truncation marker and in the jq programs below
# are literal Markdown code spans in the text this file renders, never shell
# expansions — the same blanket lib/pager.sh carries for the same reason.
#
# lib/monitor-digest.sh — what the Pipeline Monitor reads instead of the
# records themselves (issue #1284, docs/MONITOR-PIPELINE-SPEC.md M6/M7).
#
# The primary records this pipeline exists to reason over are not readable by
# a model: the fleet's union `log.jsonl` is measured in megabytes and the
# dashboard's `data.js` in the same order. Handing either to a stage would
# spend a context window on transport and still arrive truncated at an
# arbitrary place. So the Script reads them and the model reads this — one
# deterministic digest, assembled by jq from files that already exist, with
# every section's shape fixed here rather than left to whatever the stage
# happened to grep.
#
# Deterministic is the load-bearing word. Two runs over the same inputs must
# produce the same digest, because the Monitor's own dedup (M13) keys on
# findings a previous run stated, and a digest that reshuffled its samples
# would produce a different reading of the same day. Every function here is
# therefore a pure reader: it takes paths and JSON on argv, never reads
# `config.json`, never calls `gh`, and never writes anything. The one input
# that cannot be derived from a file — what the forge currently holds — is
# fetched by the caller and handed in as JSON, which is also what keeps this
# file testable against a fixture directory with no network at all.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.
#
# Every reader below degrades to its empty shape rather than failing. A
# monitor run over a fleet whose peers have not synced yet, or whose
# host-facts collector has never run, is a run with less to say — never a
# failed one.

# The event names the union log carries that are worth their own class in
# the digest rather than being pooled into "everything else". Ordered by how
# often a reader wants them, not alphabetically: the first rows of the
# digest's own event table are the ones a monitor run opens on.
#
# Not a closed list: `monitor_digest_events` groups by whatever `event`
# values the window actually holds, so an event added upstream appears in the
# digest under its own name the day it is first written, with no edit here.
# This constant only fixes the *order* the known ones render in.
MONITOR_DIGEST_EVENT_ORDER='[
  "limit-hit", "pager-fired", "pager-cleared", "pager-candidate",
  "stand-down", "cycle-skipped", "attempt-failed", "review-attempt-failed",
  "warning", "none-selected", "selection", "stage-end", "review-stage-end",
  "claim-lost", "claim-skipped", "escalation-raised", "pr-raised", "pr-ready"
]'

# monitor_digest_since NOW_EPOCH WINDOW_HOURS
# The ISO-8601 UTC instant WINDOW_HOURS before NOW_EPOCH — the digest's own
# lower bound, computed once by the caller and passed to every reader below,
# so a run that crosses an hour boundary mid-assembly cannot end up with two
# sections describing two different windows.
monitor_digest_since() {
  local now="${1:-}" hours="${2:-24}"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  [[ "$hours" =~ ^[0-9]+$ ]] || hours=24
  date -u -d "@$(( now - hours * 3600 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '1970-01-01T00:00:00Z'
}

# monitor_digest_events UNION_LOG_FILE SINCE_ISO [MAX_SAMPLES]
# The window's events grouped by `event`, as
#   [{event, count, nodes, samples: [ … ]}]
# — count first because the count is the reading and a sample is only its
# evidence. `nodes` names which machines contributed, since "every node" and
# "one node" are different faults wearing the same event name.
#
# A sample is the whole event object with the fields that carry no
# information at this altitude dropped (`ts` is kept; `cycle`/`review`/
# `monitor` ids are not — an id identifies a run the Monitor cannot open).
# MAX_SAMPLES defaults to 3: enough to tell "the same thing N times" from "N
# different things", which is the only question a sample answers here.
# Samples are taken from the *newest* events in the class, because a fault
# still in force matters more than the first time it was seen — and the class
# already carries `count` for how long it has been going on.
monitor_digest_events() {
  local union_log="${1:-}" since="${2:-}" max_samples="${3:-3}"
  [[ "$max_samples" =~ ^[0-9]+$ ]] || max_samples=3
  if [[ ! -s "$union_log" ]]; then printf '[]\n'; return 0; fi
  local out
  out="$(jq -c -R -n --arg since "$since" --argjson n "$max_samples" \
    --argjson order "$MONITOR_DIGEST_EVENT_ORDER" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(type == "object")
      | select((.ts // "") >= $since)
      | select((.event // "") != "") ]
    | group_by(.event)
    | map(
        (.[0].event) as $e
        | (sort_by(.ts)) as $rows
        | { event: $e,
            count: ($rows | length),
            nodes: ([$rows[] | .node // empty] | unique),
            samples: ([$rows | reverse | .[range(0; ([$n, ($rows|length)] | min))]
                        | del(.cycle, .review, .monitor, .event)]) }
      )
    | sort_by([ (.event as $e | ($order | index($e)) // 9999), .event ])
  ' "$union_log" 2>/dev/null)" || out=""
  [[ -n "$out" ]] || out='[]'
  printf '%s\n' "$out"
}

# monitor_digest_pager UNION_LOG_FILE SINCE_ISO OPEN_PAGES_JSON
# The pager's own half of the digest (M6): every `pager-fired` and
# `pager-cleared` transition inside the window, and every page currently open
# on the forge.
#
# The two are deliberately separate arrays rather than one joined view. A
# page can be open with no transition in the window (it fired last week and
# the fact has not cleared), and a transition can have no open page behind it
# (a `pager-cleared`, or a filing that fell back to the webhook) — and the
# Monitor's triage duty (M15) is owed to the *open* pages, not to the
# transitions, so joining them would let a page with an old first_seen fall
# out of the list it is supposed to be triaged from.
#
# OPEN_PAGES_JSON is whatever the caller's `gh issue list --label pw::pager
# --state open` returned, or `[]`; only the fields a triage needs are kept.
monitor_digest_pager() {
  local union_log="${1:-}" since="${2:-}" open_pages="${3:-[]}"
  jq -e 'type == "array"' <<<"$open_pages" >/dev/null 2>&1 || open_pages='[]'
  local transitions='[]' out
  if [[ -s "$union_log" ]]; then
    transitions="$(jq -c -R -n --arg since "$since" '
      [ inputs | select(length > 0) | (fromjson? // empty)
        | select(type == "object")
        | select(.event == "pager-fired" or .event == "pager-cleared")
        | select((.ts // "") >= $since)
        | {ts, event, node, key: (.key // ""), evidence: (.evidence // ""),
           issue_number: (.issue_number // null), issue_url: (.issue_url // null),
           remedy_class: (.remedy_class // null), nodes: (.nodes // [])} ]
      | sort_by(.ts)' "$union_log" 2>/dev/null)" || transitions='[]'
    [[ -n "$transitions" ]] || transitions='[]'
  fi
  out="$(jq -nc --argjson t "$transitions" --argjson o "$open_pages" '
    {transitions: $t,
     open_pages: ($o | map({number: (.number // null), url: (.url // null),
                            title: (.title // ""), created_at: (.createdAt // null),
                            assignees: ([(.assignees // [])[] | .login // empty]),
                            body: (.body // "")}))}' 2>/dev/null)" || out=""
  [[ -n "$out" ]] || out='{"transitions":[],"open_pages":[]}'
  printf '%s\n' "$out"
}

# monitor_digest_nodes SELF_NODE STATE_DIR PEERS_DIR
# Every node's published verdicts, as [{node, self, ts, role, stage_health,
# updater, compose, image, mirror, doctor, host}] sorted with self first.
#
# A peer's row comes from its own `heartbeat.json` — the record it published
# about itself — never from anything this node derives on a peer's behalf,
# the same rule scripts/publish-dashboard.sh's own fleet fold states at
# length. This node's own row is assembled from the files that heartbeat is
# folded *from* (`.stage-health.json`, `.doctor-status.json`), because a node
# does not keep a copy of its own published heartbeat outside the state
# mirror, and reading the mirror would make this reader depend on a git
# checkout rather than on state_dir.
#
# `host` is the host-facts record (docs/HOST-FACTS-SCHEMA.md) where one
# exists — the only route by which a CronJob-shaped Monitor may know anything
# about a host at all (M3). Absent, the field is `null`: no collector has run
# on that node, which is itself worth the Monitor seeing.
monitor_digest_nodes() {
  local self_node="${1:-}" state_dir="${2:-}" peers_dir="${3:-}"
  local rows hb peer peer_host self_row='' out
  rows="$(mktemp 2>/dev/null)" || { printf '[]\n'; return 0; }
  self_row="$(jq -nc --arg n "$self_node" \
    --argjson sh "$(jq -c '.' "$state_dir/.stage-health.json" 2>/dev/null || printf 'null')" \
    --argjson dr "$(jq -c '{timestamp, verdict, fails, warns}' "$state_dir/.doctor-status.json" 2>/dev/null || printf 'null')" \
    --argjson host "$(jq -c '.' "$state_dir/host-facts/$self_node.json" 2>/dev/null || printf 'null')" \
    '{node: $n, self: true, ts: null, role: null, stage_health: $sh, updater: null,
      compose: null, image: null, mirror: null, doctor: $dr, host: $host}' 2>/dev/null)" || self_row=''
  [[ -n "$self_row" ]] && printf '%s\n' "$self_row" >> "$rows"
  for hb in "$peers_dir"/*/heartbeat.json; do
    [[ -f "$hb" ]] || continue
    peer="$(basename "$(dirname "$hb")")"
    [[ "$peer" == "$self_node" ]] && continue
    peer_host="$(jq -c '.' "$(dirname "$hb")/host-facts/$peer.json" 2>/dev/null || printf 'null')"
    jq -c --argjson host "$peer_host" '
      {node: (.node // "unknown"), self: false, ts: (.ts // null), role: (.role // null),
       stage_health: (.stage_health // null), updater: (.updater // null),
       compose: (.compose // null), image: (.image // null), mirror: (.mirror // null),
       doctor: (.doctor // null), host: $host}' "$hb" 2>/dev/null >> "$rows" || true
  done
  out="$(jq -sc 'sort_by([(.self | not), .node])' "$rows" 2>/dev/null)" || out=''
  rm -f "$rows"
  [[ -n "$out" ]] || out='[]'
  printf '%s\n' "$out"
}

# monitor_digest_work UNION_LOG_FILE SINCE_ISO
# What the window says about throughput, as
#   {selections_by_source, stand_downs_by_cause, none_selected_reasons,
#    fit_rungs, fit_unassessable, landed, raced}
#
# These are the three readings issue #1126 had to reconstruct by hand, and
# each is a fold the Script can do exactly and a model cannot do at all:
#
#   selections_by_source  which work bands actually produced a selection —
#                         the source-state count per band. Counted from the
#                         `selection` events themselves rather than from a
#                         live gather, so it says what the fleet *did*, which
#                         is the question ("what limited throughput?") the
#                         report's second section asks.
#   fit_rungs             the Co-Ordinator input fit's rung histogram
#                         (`coordinator-input-fitted`). A rung climbing over
#                         a day is the signature of an input outgrowing its
#                         allowance; rung 0 every cycle is the healthy shape.
#                         `fits: false` is counted separately because it is a
#                         different fact — the ladder ran out.
#   none_selected_reasons the day's `none-selected` reasons, verbatim and
#                         counted. `budget: 1` meaning a *negative* allowance
#                         (agent-ops#1128) was a sentence in one of these.
#
# `stand_downs_by_cause` rides along because a stand-down and a
# `none-selected` are different answers to "why did nothing happen", and a
# report that conflates them names the wrong lever.
monitor_digest_work() {
  local union_log="${1:-}" since="${2:-}" out
  if [[ ! -s "$union_log" ]]; then
    printf '%s\n' '{"selections_by_source":[],"stand_downs_by_cause":[],"none_selected_reasons":[],"fit_rungs":[],"fit_unassessable":0,"landed":0,"raced":0}'
    return 0
  fi
  out="$(jq -c -R -n --arg since "$since" '
    def tally(f): group_by(f) | map({key: (.[0] | f), count: length}) | sort_by(-.count);
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(type == "object") | select((.ts // "") >= $since) ] as $rows
    | { selections_by_source:
          ($rows | map(select(.event == "selection")) | tally(.source // "unknown")),
        stand_downs_by_cause:
          ($rows | map(select(.event == "stand-down" or .event == "review-stand-down"))
                 | tally(.cause // "unknown")),
        none_selected_reasons:
          ($rows | map(select(.event == "none-selected"))
                 | tally(.reason // "")),
        fit_rungs:
          ($rows | map(select(.event == "coordinator-input-fitted"))
                 | tally((.rung // 0) | tostring)),
        fit_unassessable:
          ($rows | map(select(.event == "coordinator-input-fit-unassessable")) | length),
        landed:
          ($rows | map(select(.event == "pr-ready")) | length),
        raced:
          ($rows | map(select(.event == "claim-lost")) | length) }
  ' "$union_log" 2>/dev/null)" || out=''
  [[ -n "$out" ]] \
    || out='{"selections_by_source":[],"stand_downs_by_cause":[],"none_selected_reasons":[],"fit_rungs":[],"fit_unassessable":0,"landed":0,"raced":0}'
  printf '%s\n' "$out"
}

# monitor_digest_forge PRS_JSON ISSUES_JSON ESCALATIONS_JSON
# The forge's own last 24 h in the escalation repository, narrowed to the
# fields a report cites. Every array is whatever the caller's `gh` read
# returned — this function fetches nothing, so a monitor run against an
# unreachable forge produces a digest saying "nothing from the forge" rather
# than failing, and the report says so in as many words.
monitor_digest_forge() {
  local prs="${1:-[]}" issues="${2:-[]}" escalations="${3:-[]}" out
  jq -e 'type == "array"' <<<"$prs"         >/dev/null 2>&1 || prs='[]'
  jq -e 'type == "array"' <<<"$issues"      >/dev/null 2>&1 || issues='[]'
  jq -e 'type == "array"' <<<"$escalations" >/dev/null 2>&1 || escalations='[]'
  out="$(jq -nc --argjson p "$prs" --argjson i "$issues" --argjson e "$escalations" '
    def slim: map({number: (.number // null), url: (.url // null), title: (.title // ""),
                   state: (.state // null), created_at: (.createdAt // null),
                   labels: ([(.labels // [])[] | .name // empty])});
    {pull_requests: ($p | slim), issues: ($i | slim), escalations: ($e | slim)}' 2>/dev/null)" || out=''
  [[ -n "$out" ]] || out='{"pull_requests":[],"issues":[],"escalations":[]}'
  printf '%s\n' "$out"
}

# monitor_digest_gotchas FILE...
# The `## Gotchas` section of each named Markdown file, as
# [{source, text}] — the known-signature catalogue a monitor prompt needs and
# the only part of a 26000-line specification worth a monitor's context
# window. A file with no such section contributes nothing, silently: the
# section is where it is by convention, not by schema, and a spec that has
# not grown one is not a fault.
#
# Issue #1284 names the incident runbook (agent-ops#1149) as this section's
# eventual source. That runbook does not exist, so these sections are what
# the digest carries; when it does, it joins this list rather than replacing
# it — the two answer different halves of "what does this signature mean".
monitor_digest_gotchas() {
  local f rows out
  rows="$(mktemp 2>/dev/null)" || { printf '[]\n'; return 0; }
  for f in "$@"; do
    [[ -s "$f" ]] || continue
    awk -v src="$f" '
      /^## / { if (on) exit; on = ($0 ~ /^## Gotchas[[:space:]]*$/); next }
      on     { print }
    ' "$f" 2>/dev/null \
      | jq -R -s --arg src "$f" 'select(length > 0) | {source: $src, text: .}' 2>/dev/null >> "$rows" || true
  done
  out="$(jq -sc '.' "$rows" 2>/dev/null)" || out=''
  rm -f "$rows"
  [[ -n "$out" ]] || out='[]'
  printf '%s\n' "$out"
}

# monitor_digest_build WINDOW_JSON EVENTS_JSON PAGER_JSON NODES_JSON \
#                      WORK_JSON FORGE_JSON GOTCHAS_JSON
# The whole digest as one object. A plain assembly, kept as its own function
# so the key names exist in exactly one place: `monitor_digest_render` below
# and `prompts/monitor.md` both name these sections, and a rename that
# reached only one of them would leave the stage reading a heading that is
# not there.
monitor_digest_build() {
  local window="${1:-{\}}" events="${2:-[]}" pager="${3:-{\}}" nodes="${4:-[]}" \
        work="${5:-{\}}" forge="${6:-{\}}" gotchas="${7:-[]}" out
  out="$(jq -nc --argjson window "$window" --argjson events "$events" \
    --argjson pager "$pager" --argjson nodes "$nodes" --argjson work "$work" \
    --argjson forge "$forge" --argjson gotchas "$gotchas" \
    '{window: $window, events: $events, pager: $pager, nodes: $nodes,
      work: $work, forge: $forge, gotchas: $gotchas}' 2>/dev/null)" || out=''
  [[ -n "$out" ]] || out='{}'
  printf '%s\n' "$out"
}

# The drop ladder `monitor_digest_render` walks, rung by rung, until the
# rendered digest fits `monitor_max_input_bytes`. Named here rather than
# inlined because the spec (M7) states this order and the report records
# which rung a run reached, so all three have to mean the same thing.
#
#   0  everything
#   1  one sample per event class instead of three
#   2  the gotcha sections' headings only, not their prose
#   3  no gotcha sections at all
#   4  no samples at all — counts and nodes only
#   5  the rendered text truncated to the bound, with a marker saying so
#
# Prose before counts, always: a count is the reading and a sample is its
# illustration, so a bound that shed counts would leave the Monitor unable to
# say how big anything was. The last rung exists because nothing above it can
# be *guaranteed* to fit — a fleet with ten thousand distinct event names
# would still overflow on the counts alone — and a run that silently sent an
# over-long prompt is the failure agent-ops#641 already paid for once.
MONITOR_DIGEST_MAX_RUNG=5

# monitor_digest_render DIGEST_JSON MAX_BYTES OUT_FILE
# The Markdown the stage actually reads, bounded: written to OUT_FILE, with
# `<rung>\t<bytes>` printed on stdout.
#
# The text goes to a file rather than to stdout deliberately. A caller that
# wanted both the text and the rung would have to capture stdout in a command
# substitution, which is a subshell — so a rung left in a global would be
# lost at exactly the moment the caller needed it for its own event. Writing
# the one large thing to a file and returning the two small ones keeps every
# value reachable from the caller's own shell.
#
# MAX_BYTES 0 disables the bound, as every other `*_max_bytes` key in this
# configuration does, and the rung stays 0.
monitor_digest_render() {
  local digest="${1:-{\}}" max_bytes="${2:-0}" out_file="${3:-}" rung=0 bytes=0
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || max_bytes=0
  [[ -n "$out_file" ]] || { printf '0\t0\n'; return 0; }
  while (( rung < MONITOR_DIGEST_MAX_RUNG )); do
    _monitor_digest_render_at "$digest" "$rung" > "$out_file"
    # Bytes, not characters: `${#text}` counts characters under a UTF-8
    # locale, and this digest carries plenty of multi-byte text (an arrow in
    # a heading, an em dash in every evidence string). Measuring characters
    # would let a digest dense in them overshoot the bound by exactly the
    # overhead the bound exists to keep out of the prompt.
    bytes="$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if (( max_bytes == 0 )) || (( bytes <= max_bytes )); then
      printf '%s\t%s\n' "$rung" "$bytes"
      return 0
    fi
    rung=$(( rung + 1 ))
  done
  # The last rung: whatever rung 4 produced, cut to the bound. The marker is
  # written inside the bound, not appended past it, so the promise this key
  # makes — the stage is never handed more than MAX_BYTES — holds on every
  # path. `head -c` cuts bytes, which may land mid-character; the marker that
  # follows it re-synchronises the text, and a stage reading one broken
  # glyph at a truncation point is not a failure mode worth a second pass.
  local marker='

> The digest was truncated here to fit `monitor_max_input_bytes`.
'
  local marker_bytes
  marker_bytes="$(printf '%s' "$marker" | wc -c | tr -d ' ')"
  [[ "$marker_bytes" =~ ^[0-9]+$ ]] || marker_bytes=0
  local tmp
  tmp="$(mktemp "$out_file.XXXXXX" 2>/dev/null)" || tmp="$out_file.tmp"
  _monitor_digest_render_at "$digest" 4 > "$tmp"
  if (( max_bytes > marker_bytes )); then
    { head -c "$(( max_bytes - marker_bytes ))" "$tmp"; printf '%s' "$marker"; } > "$out_file"
  else
    head -c "$max_bytes" "$tmp" > "$out_file"
  fi
  rm -f "$tmp"
  bytes="$(wc -c < "$out_file" 2>/dev/null | tr -d ' ')"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  printf '%s\t%s\n' "$MONITOR_DIGEST_MAX_RUNG" "$bytes"
}

# _monitor_digest_render_at DIGEST_JSON RUNG
# One rung's rendering. Markdown rather than JSON, deliberately: the sections
# are prose-shaped (a gotcha section *is* prose), and a model reading a
# hundred-kilobyte JSON object spends its attention on the punctuation. The
# structured parts stay tables, so a count is still a count.
_monitor_digest_render_at() {
  local digest="$1" rung="${2:-0}"
  jq -r --argjson rung "$rung" '
    def samples_for($s):
      if $rung >= 4 then []
      elif $rung >= 1 then ($s | .[0:1])
      else $s end;
    def esc: tostring | gsub("\\|"; "\\\\|") | gsub("\n"; " ");
    def block($title; $body): "## \($title)\n\n\($body)\n";

    ( "# Pipeline digest\n\nWindow: `\(.window.from // "?")` → `\(.window.to // "?")` "
      + "(\(.window.hours // 24) h), assembled on node `\(.window.node // "?")` "
      + "by `monitor-cycle.sh`.\n" ),

    block("Events by class";
      ( "| Event | Count | Nodes |\n|---|---|---|\n"
        + ( [ .events[] | "| `\(.event)` | \(.count) | \(.nodes | join(", ")) |" ] | join("\n") )
        + "\n"
        + ( [ .events[]
              | (samples_for(.samples)) as $s
              | select(($s | length) > 0)
              | "\n### `\(.event)` — \(.count) in the window\n\n"
                + ( [ $s[] | "- `\(. | tojson)`" ] | join("\n") ) ]
            | join("\n") ) )),

    block("Pager";
      ( "Transitions in the window:\n\n"
        + ( if (.pager.transitions | length) == 0 then "_none_\n"
            else ( [ .pager.transitions[]
                     | "- `\(.ts)` **\(.event)** `\(.key)` — \(.evidence | esc)"
                       + (if .issue_url then " (\(.issue_url))" else "" end) ]
                   | join("\n") ) + "\n" end )
        + "\nOpen `pw::pager` issues — every one of these is owed a triage verdict:\n\n"
        + ( if (.pager.open_pages | length) == 0 then "_none_\n"
            else ( [ .pager.open_pages[]
                     | "- #\(.number // "?") \(.title | esc)"
                       + (if ((.assignees // []) | length) > 0
                          then " — assigned to \((.assignees | join(", ")))" else "" end)
                       + "\n\n  ```\n  " + ((.body // "") | esc) + "\n  ```" ]
                   | join("\n") ) + "\n" end ) )),

    block("Nodes";
      ( "| Node | Self | Published | Role | Failing stages | Updater | Compose | Image | Mirror | Doctor | Host facts |\n"
        + "|---|---|---|---|---|---|---|---|---|---|---|\n"
        + ( [ .nodes[]
              | "| `\(.node)` | \(.self) | \(.ts // "—") | \(.role // "—") "
                + "| \( [ ((.stage_health.stages // {}) | to_entries[] | select(.value.verdict == "failing") | .key) ] | if length == 0 then "—" else join(", ") end ) "
                + "| \(.updater.verdict // "—") | \(.compose.verdict // "—") | \(.image.verdict // "—") "
                + "| \(.mirror.verdict // "—") | \(.doctor.verdict // "—") "
                + "| \(if .host == null then "none" else "\(.host.driver // "?") @ \(.host.generated_at // "?")" end) |" ]
            | join("\n") )
        + "\n\nHost-facts records in full (the only vantage a CronJob-shaped Monitor has on a host):\n\n"
        + ( [ .nodes[] | select(.host != null) | "- `\(.node)`: `\(.host | tojson)`" ]
            | if length == 0 then "_no node has published one_" else join("\n") end ) + "\n" )),

    block("Throughput";
      ( "Selections by work source:\n\n"
        + ( [ .work.selections_by_source[] | "- `\(.key)`: \(.count)" ]
            | if length == 0 then "_no item was selected in the window_" else join("\n") end )
        + "\n\nStand-downs by cause:\n\n"
        + ( [ .work.stand_downs_by_cause[] | "- `\(.key)`: \(.count)" ]
            | if length == 0 then "_none_" else join("\n") end )
        + "\n\n`none-selected` reasons:\n\n"
        + ( [ .work.none_selected_reasons[] | "- (\(.count)×) \(.key | esc)" ]
            | if length == 0 then "_none_" else join("\n") end )
        + "\n\nCo-Ordinator input fit — rung histogram:\n\n"
        + ( [ .work.fit_rungs[] | "- rung \(.key): \(.count)" ]
            | if length == 0 then "_the fit was never applied in the window_" else join("\n") end )
        + "\n\n- fit unassessable: \(.work.fit_unassessable)\n"
        + "- pull requests marked ready: \(.work.landed)\n"
        + "- claims lost to peers: \(.work.raced)\n" )),

    block("The escalation repository, last 24 h";
      ( "Pull requests:\n\n"
        + ( [ .forge.pull_requests[] | "- #\(.number) \(.title | esc) (\(.state // "?"))" ]
            | if length == 0 then "_none_" else join("\n") end )
        + "\n\nIssues:\n\n"
        + ( [ .forge.issues[] | "- #\(.number) \(.title | esc) (\(.state // "?")) [\(.labels | join(", "))]" ]
            | if length == 0 then "_none_" else join("\n") end )
        + "\n\nEscalations:\n\n"
        + ( [ .forge.escalations[] | "- #\(.number) \(.title | esc) (\(.state // "?"))" ]
            | if length == 0 then "_none_" else join("\n") end ) + "\n" )),

    ( if $rung >= 3 then empty
      else block("Known signatures (gotcha sections from the specs)";
        ( [ .gotchas[]
            | "### \(.source)\n\n"
              + ( if $rung >= 2
                  then ( [ (.text | split("\n")[] | select(startswith("|") or startswith("- **") or startswith("### "))) ]
                         | .[0:60] | join("\n") )
                  else .text end ) ]
          | if length == 0 then "_no gotcha section was readable_" else join("\n\n") end ) )
      end )
  ' <<<"$digest" 2>/dev/null || printf '# Pipeline digest\n\n_the digest could not be rendered_\n'
}
