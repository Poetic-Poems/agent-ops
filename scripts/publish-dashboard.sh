#!/usr/bin/env bash
#
# publish-dashboard.sh — regenerate the local monitoring dashboard.
#
# Reads the pipeline's on-disk state (log.jsonl, per-cycle transcripts,
# lock.json, cron.log) plus live GitHub data (via gh), and writes a single
# self-contained data file (data.js) next to a copy of the dashboard's
# index.html under <state_dir>/dashboard/. Open that index.html in a browser
# to view the dashboard — no server, no open port, nothing leaves the machine.
#
# Safe to run any time: it only reads the pipeline's state, never writes into
# it, never touches the lock, and cannot disturb a running cycle. Costs
# nothing to run (no model calls). Companion doc: docs/DASHBOARD-SPEC.md.

set -uo pipefail

# --- PATH: cron's environment is minimal; make sure jq, gh, git resolve. -----
path_dirs=(/usr/local/bin /usr/bin /bin "$HOME/.local/bin")
PATH="$(IFS=:; echo "${path_dirs[*]}"):$PATH"
export PATH

# Which `gh` to call. A seam for the test suite, which must reach no network
# and cannot shadow a binary by PATH — the line above deliberately puts the
# system directories first, and `gh_json` runs gh under `timeout`, which an
# exported shell function would never be seen by. Unset in production, where
# this is exactly `gh`. Exported so scripts/gather-findings.sh, the one other
# GitHub reader a publish invokes, resolves the same way.
export DASHBOARD_GH_CMD="${DASHBOARD_GH_CMD:-gh}"

for bin in jq "$DASHBOARD_GH_CMD"; do
  command -v "$bin" >/dev/null 2>&1 || { echo "publish-dashboard: missing binary: $bin" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
TEMPLATE="$SCRIPT_DIR/dashboard/index.html"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"
# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"

MAX_CYCLES=40        # recent cycles shown in detail (with transcripts)
MAX_LOG_TAIL=300     # recent raw log events surfaced
TRANSCRIPT_CAP=40000 # bytes kept per transcript / stderr
GH_TIMEOUT=15        # seconds per gh call
COST_SCAN_DAYS=60    # how far back to scan transcripts for cost roll-ups

WITH_GITHUB=1
[[ "${1:-}" == "--no-github" ]] && WITH_GITHUB=0

# --- Config ------------------------------------------------------------------
expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
cfg()      { jq -r "$1" "$CONFIG_FILE" 2>/dev/null; }
cfg_json() { jq -c "$1" "$CONFIG_FILE" 2>/dev/null; }

state_dir="$(expand_home "$(cfg '.state_dir')")"
# No `log_file` here: the log is read as the fleet's, through
# `fleet_logs "$state_dir" "$peers_dir" log.jsonl` (see read_events), which
# builds its own paths. A local one would only ever be the wrong half of it.
lock_file="$state_dir/lock.json"
cron_log="$state_dir/cron.log"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
peers_dir="$(fleet_peers_dir "$workspace_root")"
self_node="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"
self_node="${self_node//[^A-Za-z0-9._-]/-}"
cycles_dir="$state_dir/cycles"
pr_label="$(cfg '.pr_label')"
max_open_agent_prs="$(cfg '.max_open_agent_prs')"
state_repo="$(cfg '.state_repo // ""')"
[[ "$state_repo" == "null" ]] && state_repo=""
repos_json="$(cfg_json '.repos')"

out_dir="$state_dir/dashboard"
data_file="$out_dir/data.js"
# Last real GitHub fetch, kept out of the served dir. A --no-github tick reuses
# it so a local-only refresh doesn't blank the PR list / work sources or raise a
# false "GitHub unavailable" alarm between GitHub refreshes. Its mtime is also
# the heartbeat's gate: publish-dashboard-launcher.sh fetches on the first tick
# to find this file older than LAUNCHER_GITHUB_MAX_AGE, so this write is what
# schedules the next fetch — hence writing it for a failed attempt too, a few
# hundred lines below.
gh_cache="$state_dir/.dashboard-github.json"
# Claim bodies by blob SHA. A blob's SHA is a hash of its content, so a hit is
# never stale by construction and the registry costs one API call a tick while
# the claims it holds are unchanged. Kept out of the served dir for the same
# reason as the fetch cache above.
claims_cache="$state_dir/.dashboard-claims.json"
# Pull-request records by "<owner>/<repo>#<number>", for the hover cards. A
# merged or closed pull request is immutable, so its entry is never re-read;
# see the index build below for what keeps the file from growing. Kept out of
# the served dir like the two caches above.
pr_cache="$state_dir/.dashboard-prs.json"
mkdir -p "$out_dir"

# Large JSON blobs (the cycles array carries full transcripts) are handed to jq
# through files, not argv: a single command-line argument is capped at 128 KB
# (MAX_ARG_STRLEN), which big transcripts blow past. Temp files have no such limit.
work_tmp="$(mktemp -d)"
trap 'rm -rf "$work_tmp"' EXIT

now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
now_epoch="$(date +%s)"

# --- Helpers -----------------------------------------------------------------
# Parse each line of the log independently so a half-written trailing line
# (the Script may be appending as we read) never aborts the whole parse.
# The stream is the FLEET's: this node's log unioned with every fetched
# peer's (lib/fleet.sh), so blocked/void, the log tail, and the cycle list
# below all show what the whole operation did, from any node's dashboard.
# Events carry `node` (requirement 33); with no peers this reduces exactly
# to the old local read.
read_events() { fleet_logs "$state_dir" "$peers_dir" log.jsonl | jq -c -R 'fromjson? // empty' 2>/dev/null; }

gh_json() { timeout "$GH_TIMEOUT" "$DASHBOARD_GH_CMD" "$@" 2>/dev/null; }

epoch_of() { date -d "$1" +%s 2>/dev/null || echo 0; }

# --- Build the whole detail window's JSON in one jq program -------------------
# TD26072201: this used to be two functions, stage_json and cycle_json, each
# forked per cycle (straight-parse-else-fenced-block extraction — mirroring
# agent-cycle.sh's extract_json_result — envelope field pulls, a usage-limit
# phrase/reset-clause scan of the stage's own out+err files, then the
# per-stage and per-cycle assembly) — roughly a dozen jq per shown cycle,
# cheap per fork on native Linux but dominant in the 5-second heartbeat
# budget under WSL2, where each fork costs far more. The stage transcripts
# are already individual files on disk, so every existing one in the window
# is now handed straight to a single jq invocation via --rawfile (jq opens
# the file itself: no extra fork, and — like events_file above — no 128 KB
# argv cap either), and that one process does every parse, fenced-```json```
# extraction, envelope-field pull and limit-phrase scan the two functions
# used to fork out for, for the whole window at once. The limit-phrase scan
# this replaces was its own backstop for a cycle whose limit-hit never made
# it into the log (e.g. the Script crashed before log_event ran, or the
# cycle predates the detector) — `limit_phrase_re`/`reset_re` below restate
# `limit_phrase_in`/`limit_reset_text`'s patterns for that same purpose;
# `lib/limit-detect.sh`'s own copies (shared with agent-cycle.sh, see
# TD26071401) remain in use elsewhere in this script for the stand-down
# banner (`limit_union_record` et al.), which is a different reader of the
# same phrase and is untouched by this change.
detail_defs="$work_tmp/detail-defs.jq"
cat > "$detail_defs" <<'JQDEFS'
def try_json($s): ($s | try fromjson catch null);

# Same phrase/reset-clause patterns as limit_phrase_in/limit_reset_text
# (this file, above) — restated here rather than shared, since this is a
# jq-side port specific to the batched window; the bash originals still
# serve the per-file transcript-cost scan elsewhere in this script.
def limit_phrase_re: "hit your .* limit|usage limit|rate limit|usage cap|quota exceeded";
def reset_re: "reset[s]?( at)? [^\"\\\\]{1,60}";

def find_reset($text):
  ($text | split("\n")) as $lines
  | ([$lines[] | select(test(reset_re; "i"))] | first) as $line
  | if $line == null then null else ($line | match(reset_re; "i").string) end;

# Scans the full out+err text handed in, not the capped/displayed copies
# build_stage derives below: a limit phrase past TRANSCRIPT_CAP must still be
# found, exactly as limit_phrase_in/limit_reset_text scan whole files rather
# than a truncated variable.
def limit_info($out_full; $err_full):
  (($out_full // "") + "\n" + ($err_full // "")) as $combined
  | { hit: ($combined | test(limit_phrase_re; "i")),
      text: ( (find_reset($out_full // "")) as $o
              | if $o != null then $o else find_reset($err_full // "") end )
    };

# Port of extract_status_json(): try the stage's result text as JSON
# outright, else the last fenced ```json block within it (the same
# straight-parse-else-last-fenced-block algorithm as agent-cycle.sh's
# extract_json_result, per DASHBOARD-SPEC.md). `ok:false` marks a shell-era
# quirk this port deliberately preserves rather than fixes: an
# empty-or-whitespace result used to make `jq empty`/`jq -c '.'` produce
# nothing, which collapsed a `--argjson` into an invalid empty string,
# failed the enclosing `jq -n` call, and silently dropped the WHOLE cycle
# row rather than just this one stage. TD26072802 tracks retiring that
# behaviour; until then this keeps the output unchanged.
def extract_status($text):
  if ($text | test("^\\s*$")) then {ok:false, value:null}
  else
    (try_json($text)) as $direct
    | if $direct != null then {ok:true, value:$direct}
      else
        ($text | split("\n")) as $lines
        | (reduce $lines[] as $line
             ({in_block:false, capture:"", last:null};
              if ($line | test("^```json[[:space:]]*$")) then
                .in_block = true | .capture = ""
              elif ($line | test("^```[[:space:]]*$")) then
                if .in_block then (.last = .capture | .in_block = false) else . end
              elif .in_block then
                .capture += ($line + "\n")
              else . end)).last as $block
        | if $block != null and ($block | length) > 0 and (try_json($block) != null) then
            {ok:true, value: try_json($block)}
          else {ok:true, value:null}
          end
      end
  end;

# One stage's JSON, from its manifest entry ({out,err} raw text) — or null
# when the stage never ran, mirroring stage_json's own out-file check.
def build_stage($entry; $cap):
  if $entry == null then null
  else
    ($entry.out // "") as $out_full
    | ($entry.err // "") as $err_full
    | (try_json($out_full)) as $envtry
    | (if ($envtry | type) == "object" then $envtry else {} end) as $env
    # `sub("\n+$";"")` mirrors the trailing-newline strip every bash
    # `$(...)` capture in the old stage_json got for free; without it, a
    # stage whose result/stderr ends in a newline would render with one jq's
    # string slicing would otherwise keep.
    | ($env.result // "" | sub("\n+$"; "")) as $result_stripped
    | ($result_stripped[0:$cap]) as $result_disp
    | ($err_full[0:$cap] | sub("\n+$"; "")) as $err_disp
    | extract_status($result_stripped) as $status
    | limit_info($out_full; $err_full) as $lim
    | {
        ok: $status.ok,
        obj: {
          ran: true,
          cost_usd: ($env.total_cost_usd // null),
          duration_ms: ($env.duration_ms // null),
          num_turns: ($env.num_turns // null),
          is_error: ($env.is_error // null),
          terminal_reason: ($env.terminal_reason // $env.stop_reason // null),
          model: ($env.modelUsage // {} | keys | (.[0] // null)),
          status: $status.value,
          result: $result_disp,
          stderr: $err_disp,
          limit_hit: $lim.hit,
          limit_text: ($lim.text // "")
        }
      }
  end;

# One cycle's JSON: its three stages plus the log-derived outcome — the same
# shape the old cycle_json built per cycle.
def cycle_obj($cid; $ev; $manifest_idx; $cap):
  ($ev | sort_by(.ts)) as $e
  | ($e | map(.event)) as $types
  | (["coordinator","implementor","reviewer"] | map(build_stage($manifest_idx[$cid + "|" + .]; $cap))) as $built
  | if any($built[]; . != null and (.ok | not)) then empty
    else
      ($built | map(.obj)) as $stageobjs
      | {
          id: $cid,
          node: ([ $e[] | select(.node) | .node ] | last),
          started_at: (([ $e[] | select(.event=="cycle-start") | .ts ] | first) // ($e[0].ts // null)),
          ended_at:   ([ $e[] | select(.event=="cycle-end") | .ts ] | last),
          dry_run:    (($e[] | select(.event=="cycle-start") | .dry_run) // false),
          repo:   ([ $e[] | select(.repo)  | .repo ] | last),
          item:   ([ $e[] | select(.item)  | .item ] | last),
          source: ([ $e[] | select(.event=="selection") | .source ] | last),
          title:  ([ $e[] | select(.event=="selection") | .title ]  | last),
          pr_url: ([ $e[] | select(.pr_url) | .pr_url ] | last),
          reason: ([ $e[] | select(.event=="none-selected" or .event=="stand-down" or .event=="cycle-skipped") | (.reason // .detail) ] | last),
          fail_detail: ([ $e[] | select(.event=="attempt-failed") | ((.stage // "?") + ": " + (.detail // "")) ] | last),
          warning: ([ $e[] | select(.event=="warning") | .detail ] | last),
          outcome: (
            if   ($types | any(. == "pr-ready"))       then "pr-ready"
            elif ($types | any(. == "pr-raised"))      then "pr-raised"
            elif ($types | any(. == "attempt-failed")) then "failed"
            elif ($types | any(. == "none-selected"))  then "none-selected"
            elif ($types | any(. == "stand-down"))     then "stand-down"
            elif ($types | any(. == "cycle-skipped"))  then "skipped"
            elif ($types | any(. == "selection"))      then "selected"
            else "ended" end
          ),
          stages: { coordinator: $stageobjs[0], implementor: $stageobjs[1], reviewer: $stageobjs[2] },
          total_cost_usd: ([ $stageobjs[] | .cost_usd // 0 ] | add),
          limit_hit: ([ $stageobjs[] | .limit_hit // false ] | any),
          events: $e
        }
    end;
JQDEFS

# --- Slurp all events once (shared by cycle_json and summaries) ---------------
ALL_EVENTS="$(read_events)"
# The same events as one JSON array on disk, for the per-cycle filters: a file
# beats re-piping the whole stream once per cycle, and files (unlike argv) have
# no 128 KB cap.
events_file="$work_tmp/events.json"
printf '%s\n' "$ALL_EVENTS" | jq -sc '.' > "$events_file" 2>/dev/null \
  || printf '[]' > "$events_file"

# --- Recent cycle ids, newest first, fleet-wide -------------------------------
# One "<id>\t<cycles-dir>" line per known cycle: ours (from the local dir and
# the union's event stream — an id only in events renders from its events
# alone), and each fetched peer's (from its materialised cycles/). Ids begin
# with a UTC timestamp, so one reverse sort interleaves every node's history
# into fleet time order; MAX_CYCLES then caps the *fleet-wide* detail list,
# which is what keeps data.js near its single-node size however many nodes
# report (the transcripts are the bytes that matter).
# The middle column ranks the source: D rows point at a directory that
# really holds the cycle's transcripts, E rows are ids known only from the
# event stream (pruned locally, or a peer's that predates its fetch). Sorting
# id-desc then D-before-E and keeping the first row per id means an id that
# exists on disk always renders from the right node's directory — without
# the ranking, the union's E row for a peer's cycle could win and silently
# strip its stages.
# Only ids of the pipelines' own shape become rows. The log also carries
# records no cycle produced — a hand-appended `unvoided` or `limit-hit` uses
# the `cycle: "manual"` sentinel (implementation spec 33) — and every such
# record, from every node, for all time, collapses into one id here. That id
# has no cycle-start, no cycle-end and no transcript directory, so it renders
# as a cycle that began at the first hand-edit anyone ever made and can never
# end; worse, the sort above is lexical, and "manual" beats every digit, so it
# pins itself to the top of Recent cycles and holds a MAX_CYCLES slot forever.
# Dropping it here rather than in the page keeps it in the log tail, where a
# record that is not a cycle belongs, and keeps the limit and void readers —
# which filter on the event, never on the cycle — untouched.
cycle_id_re='^[0-9]{8}T[0-9]{6}Z-'
cycle_rows="$work_tmp/cycle-rows"
tab="$(printf '\t')"

# The D rows of one cycles directory: every id it holds, tagged with where it
# came from. A glob rather than `ls`, so an id that is not a plain word cannot
# be split or re-interpreted on its way through a pipe; the directory may not
# exist at all (a node that has run nothing, a peer fetched before its first
# cycle), which leaves the pattern unmatched and the loop empty.
dir_rows() {  # dir_rows CYCLES_DIR
  local entry
  for entry in "$1"/*; do
    [[ -e "$entry" ]] || continue
    printf '%s\tD\t%s\n' "${entry##*/}" "$1"
  done
}

{
  dir_rows "$cycles_dir"
  printf '%s\n' "$ALL_EVENTS" | jq -r '.cycle // empty' 2>/dev/null | sed "s|\$|\tE\t$cycles_dir|"
  for pd in "$peers_dir"/*/cycles; do
    [[ -d "$pd" ]] || continue
    dir_rows "$pd"
  done
} | sort -t "$tab" -k1,1r -k2,2 | awk -F'\t' -v re="$cycle_id_re" \
      '$1 ~ re && !seen[$1]++' | cut -f1,3 \
  | head -n "$MAX_CYCLES" > "$cycle_rows"

# Manifest of every existing stage file in the window, plus the window's own
# order (newest first, matching cycle_rows) — the two inputs cycle_obj above
# needs. Each file is read once with bash's own `$(<file)` (no fork, unlike
# `cat`) into a work_tmp copy that jq then opens via --rawfile: a cycle
# pruned out from under this read (cycles/ is bounded elsewhere, TD26072004)
# yields empty content, exactly as the old stage_json's `cat` did, rather
# than a hard "no such file" error from jq that would fail the single
# invocation below and blank the whole window over one vanished cycle.
manifest_items=()
rawfile_args=(--rawfile events_raw "$events_file")
order_items=()
cycle_n=0
while IFS=$'\t' read -r cid cdir; do
  [[ -n "$cid" ]] || continue
  order_items+=("\"$cid\"")
  for stage in coordinator implementor reviewer; do
    outfile="${cdir:-$cycles_dir}/$cid/$stage.out"
    [[ -f "$outfile" ]] || continue
    ovar="o${cycle_n}_$stage"
    otmp="$work_tmp/$ovar"
    { out_content="$(<"$outfile")"; } 2>/dev/null
    printf '%s' "${out_content:-}" > "$otmp"
    rawfile_args+=(--rawfile "$ovar" "$otmp")
    errfile="$outfile.stderr"
    if [[ -f "$errfile" ]]; then
      evar="e${cycle_n}_$stage"
      etmp="$work_tmp/$evar"
      { err_content="$(<"$errfile")"; } 2>/dev/null
      printf '%s' "${err_content:-}" > "$etmp"
      rawfile_args+=(--rawfile "$evar" "$etmp")
      manifest_items+=("{\"cid\":\"$cid\",\"stage\":\"$stage\",\"out\":\$$ovar,\"err\":\$$evar}")
    else
      manifest_items+=("{\"cid\":\"$cid\",\"stage\":\"$stage\",\"out\":\$$ovar,\"err\":null}")
    fi
  done
  cycle_n=$(( cycle_n + 1 ))
done < "$cycle_rows"
manifest_json="[$(IFS=,; echo "${manifest_items[*]}")]"
order_json="[$(IFS=,; echo "${order_items[*]}")]"

# The dynamic trailer that drives the static defs above: bound via plain
# printf (never string-interpolated into the program text), so nothing in a
# cycle id or transcript can be mistaken for jq syntax. The `$name`s below are
# jq variables, not shell ones — single-quoted on purpose so the shell leaves
# them alone.
detail_main="$work_tmp/detail-main.jq"
# shellcheck disable=SC2016
{
  printf '(%s) as $manifest\n' "$manifest_json"
  printf '| (%s) as $order\n' "$order_json"
  printf '| ($events_raw | fromjson) as $all_events\n'
  printf '| ($all_events | group_by(.cycle) | map({(.[0].cycle): .}) | add // {}) as $events_by_cycle\n'
  printf '| ($manifest | INDEX(.cid + "|" + .stage)) as $manifest_idx\n'
  printf '| [ $order[] as $cid | cycle_obj($cid; ($events_by_cycle[$cid] // []); $manifest_idx; $cap) ]\n'
} > "$detail_main"

cycles_file="$work_tmp/cycles.json"
detail_prog="$work_tmp/detail.jq"
cat "$detail_defs" "$detail_main" > "$detail_prog"
jq -n -f "$detail_prog" "${rawfile_args[@]}" --argjson cap "$TRANSCRIPT_CAP" \
  > "$cycles_file" 2>/dev/null
# A hard failure (a bad program, a file that vanished between the stat above
# and jq's own open) must not take down the whole publish — fall back to an
# empty window exactly as the per-cycle loop this replaced did when nothing
# parsed.
jq -e . "$cycles_file" >/dev/null 2>&1 || printf '[]' > "$cycles_file"

# --- Status ------------------------------------------------------------------
lock_pid=""; lock_started=""; lock_alive=false
if [[ -f "$lock_file" ]]; then
  lock_pid="$(jq -r '.pid // empty' "$lock_file" 2>/dev/null)"
  lock_started="$(jq -r '.started_at // empty' "$lock_file" 2>/dev/null)"
  [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null && lock_alive=true
fi

# The events of the cycle that holds the lock right now, so the header can say
# what is being worked on and not just that something is. The cycle id is
# "<ts>-<node>-<pid>" (agent-cycle.sh; older records "<ts>-<pid>") and the lock
# stores that same pid — last in either shape — so the live cycle's events are
# exactly those whose id ends in "-<lock_pid>".
running_events='[]'
if [[ "$lock_alive" == "true" && -n "$lock_pid" ]]; then
  running_events="$(printf '%s\n' "$ALL_EVENTS" \
    | jq -sc --arg pid "$lock_pid" '[ .[] | select((.cycle // "") | endswith("-" + $pid)) ] | sort_by(.ts)' 2>/dev/null)"
  [[ -z "$running_events" || "$running_events" == "null" ]] && running_events='[]'
fi

# Usage-limit state: prefer a logged limit-hit with a future resume_at; else
# fall back to limit phrasing detected in the most recent cycles' transcripts.
# The reduction is lib/limit-detect.sh's, so a `limit-cleared` event retires
# the banner exactly when it retires the stand-down itself (requirement 34a —
# the dashboard must not still be reporting a limit the pipelines have lifted).
last_limit_hit="$(printf '%s\n' "$ALL_EVENTS" | limit_union_record)"
[[ -n "$last_limit_hit" ]] || last_limit_hit='{}'
limit_resume="$(jq -r '.resume_at // empty' <<<"$last_limit_hit" 2>/dev/null)"
limit_class="$(jq -r '.class // "other"' <<<"$last_limit_hit" 2>/dev/null)"
limit_reset_is_known="$(limit_reset_known "$last_limit_hit")"
limit_active=false; limit_note=""
if [[ -n "$limit_resume" ]] && (( $(epoch_of "$limit_resume") > now_epoch )); then
  # When no reset time was stated, `resume_at` is this system's own retry
  # interval. Saying "until <t>" of a guess is what let a stand-down outlive
  # its limit unquestioned, so limit_describe says which kind of time it is
  # and names the two ways out (wait for the rollover, or raise the cap and
  # clear it).
  limit_active=true
  limit_note="$(limit_describe "$limit_resume" "$limit_class" "$limit_reset_is_known") (logged)"
fi

if [[ "$limit_active" != "true" ]]; then
  # A limit is "active" only if the most recent cycle that actually launched a
  # stage hit one — otherwise a later successful cycle has cleared it and the
  # banner would be a stale false positive. (Skipped/stand-down cycles launch no
  # stage, so they don't count as recovery either way.)
  lt="$(jq -r '
    [ .[] | select(any(.stages[]?; .ran)) ] | (.[0] // {})
    | if .limit_hit
      then (.stages.implementor.limit_text // .stages.reviewer.limit_text // .stages.coordinator.limit_text // "usage limit reported in transcript")
      else "" end' "$cycles_file" 2>/dev/null)"
  if [[ -n "$lt" ]]; then limit_active=true; limit_note="$lt"; fi
fi

# The switch (requirement 2.3), read through lib/toggle.sh — the same code the
# cycle gates on, so the dashboard cannot disagree with it (requirement 34a).
#
# A disabled pipeline must be impossible to mistake for a quiet one. Without a
# banner, "disabled" and "nothing to do" render identically: no cycles, no PRs,
# no errors. That is how a switch someone set on Tuesday goes unnoticed until
# Friday — and the whole reason acceptance check 8b insists an operator can
# tell "waiting on something" from "there is nothing to do here" at a glance.
switch_state="$(toggle_state "$state_dir")"
switch_disabled=false
[[ "$(jq -r '.state' <<<"$switch_state")" == "disabled" ]] && switch_disabled=true
switch_json="$(jq -nc --argjson d "$switch_disabled" --argjson s "$switch_state" \
  '{disabled: $d,
    reason: ($s.record.reason // ""),
    by: ($s.record.by // ""),
    since: ($s.record.disabled_at // ""),
    expires_at: ($s.record.expires_at // null)}')"

status_json="$(jq -n \
  --argjson alive "$lock_alive" \
  --arg pid "$lock_pid" --arg started "$lock_started" \
  --argjson running "$running_events" \
  --argjson limit_active "$limit_active" --arg limit_note "$limit_note" \
  --argjson switch "$switch_json" \
  --slurpfile cyc "$cycles_file" '
  ($cyc[0] | map(select(.dry_run|not))) as $real
  # (Comments in this program carry no apostrophes: it is a single-quoted shell
  # string, so one would end it and hand the rest of the jq to the shell.)
  #
  # Both newest-FINISHED, not newest: the field is read as "last cycle <ago>,
  # and how it went", and only a cycle that logged `cycle-end` has either to
  # give. The list is newest-first, so `first` after the filter is the newest
  # that qualifies. Null when nothing has finished yet, which the page already
  # renders as no last-cycle clause at all.
  | ([ $real[]   | select(.ended_at) ] | first) as $last_real
  | ([ $cyc[0][] | select(.ended_at) ] | first) as $last_any
  | {
      running: $alive,
      lock: (if $pid == "" then null else {pid: ($pid|tonumber), started_at: $started, alive: $alive} end),
      # What the live cycle is doing right now, derived from its own events: the
      # last stage whose stage-start has no matching stage-end (the running one),
      # and the work its coordinator selected. Null until a cycle holds the lock;
      # its fields fill in as the cycle progresses (repo/item/title appear only
      # once the coordinator has selected — the coordinator stage runs first).
      current: (
        ($running // []) | if length == 0 then null else
        {
          stage: (
            (reduce (.[] | select(.event=="stage-start" or .event=="stage-end")) as $x
              ({}; .[$x.stage] = $x.event))
            | to_entries | map(select(.value=="stage-start")) | (.[-1].key // null)
          ),
          repo:   ([ .[] | select(.event=="selection") | .repo ]   | last),
          item:   ([ .[] | select(.event=="selection") | .item ]   | last),
          source: ([ .[] | select(.event=="selection") | .source ] | last),
          title:  ([ .[] | select(.event=="selection") | .title ]  | last)
        } end
      ),
      # The newest FINISHED cycle the FLEET ran, not the newest this node ran:
      # the cycle list it is drawn from is the union. `node` says whose it was,
      # which is the whole difference between "the pipeline last ran an hour
      # ago" and "this machine has been quiet for an hour while another worked".
      # An unfinished cycle is excluded because every reader of this field wants
      # a completed one: the headers date it by `ended_at` and the node cards
      # badge it by `outcome`, and a cycle-start with no end has a null for the
      # first and the floor of the outcome ladder for the second.
      last_cycle: (($last_real // $last_any) | if . == null then null else {id, node, ended_at, outcome, repo, item, title} end),
      limit: {active: $limit_active, note: $limit_note},
      switch: $switch
    }')"

# --- Counts / roll-ups (scan all recent transcripts for cost) ----------------
# Envelopes are read in batches — one jq per 25 files, each row's day derived
# from input_filename — rather than two jq forks per file plus a re-parse of a
# growing array per row: with months of history that is thousands of processes
# and tens of seconds per publish. A torn envelope (a stage mid-write) costs at
# most the remainder of its batch for one tick; the next tick reads it whole,
# and sorting puts the newest (the only ones ever mid-write) in the last batch.
# The rows go to jq as a file: at 60 days of history they outgrow argv's cap.
day_cut="$(date -u -d "-${COST_SCAN_DAYS} days" +%Y%m%d 2>/dev/null || echo 00000000)"
costs_file="$work_tmp/costs.json"
# Fleet-wide: every node spends the same Claude account, so the roll-ups scan
# the peers' replicated transcripts too (bounded — a peer's branch carries at
# most cycles_retained cycles). Missing dirs are fine; find just skips them.
#
# `reviews/` is scanned alongside `cycles/`: the weekly project-review pipeline
# is the same account spending the same tokens, and while its transcripts went
# unread every figure on this page was quietly a partial total — the Project
# Reviewer is the single most expensive actor per run and was the only one
# invisible. Its records are shaped like a cycle's (`<id>/<actor>.out` under a
# timestamped id), so the same scan reads both; the directory two levels up is
# what says which pipeline a row came from.
cost_dirs=("$cycles_dir")
[[ -d "$state_dir/reviews" ]] && cost_dirs+=("$state_dir/reviews")
for pd in "$peers_dir"/*/cycles "$peers_dir"/*/reviews; do
  [[ -d "$pd" ]] && cost_dirs+=("$pd")
done
# `actor` is which agent spent it. The Publisher already knew — it is the
# transcript's own filename — but only ever asked per cycle, so "what is the
# money going on?" could be answered by model and by day and not by the thing
# an operator can actually change. A review's file is `reviewer-<repo>.out`,
# one per repository reviewed, so it is named for the pipeline it belongs to
# rather than left to read as a second Reviewer. Any other stem passes through
# verbatim: an actor added upstream should show up unlabelled rather than
# vanish into the totals.
# shellcheck disable=SC2016  # `$p` below is a jq binding, not a shell variable
find "${cost_dirs[@]}" -name '*.out' -type f -print0 2>/dev/null | sort -z \
  | xargs -0 -r -n 25 jq -c '
      (input_filename | split("/")) as $p
      | {
          day: ($p[-2] | .[0:8]),
          cost: (.total_cost_usd // 0),
          model: ((.modelUsage // {}) | keys | (.[0] // "unknown")),
          actor: (if ($p[-3] // "") == "reviews" then "project-reviewer"
                  else ($p[-1] | rtrimstr(".out")) end)
        }' 2>/dev/null \
  | jq -sc --arg cut "$day_cut" '[ .[] | select(.day >= $cut) ]' \
  > "$costs_file" 2>/dev/null
jq -e 'type == "array"' "$costs_file" >/dev/null 2>&1 || printf '[]' > "$costs_file"

today="$(date -u +%Y%m%d)"
counts_json="$(jq -n --slurpfile cyc "$cycles_file" --slurpfile cost_rows "$costs_file" --arg today "$today" '
  ($cyc[0]) as $cycles
  | ($cost_rows[0]) as $costs
  | {
    cycles_shown: ($cycles | length),
    failures_shown: ($cycles | map(select(.outcome=="failed")) | length),
    prs_reached_ready: ($cycles | map(select(.outcome=="pr-ready")) | length),
    spend_total_usd: ($costs | map(.cost) | add // 0),
    spend_today_usd: ($costs | map(select(.day==$today) | .cost) | add // 0),
    by_day:   ($costs | group_by(.day)   | map({day: .[0].day, usd: (map(.cost)|add), n: length}) | sort_by(.day)),
    by_model: ($costs | group_by(.model) | map({model: .[0].model, usd: (map(.cost)|add), n: length})
                      | map(select(.model != "unknown" or .usd > 0)) | sort_by(-.usd)),
    by_actor: ($costs | group_by(.actor) | map({actor: .[0].actor, usd: (map(.cost)|add), n: length})
                      | sort_by(-.usd))
  }')"

# --- Blocked and void items (requirements 34, 34c) ---------------------------
# Both rules live in lib/cycle-state.sh, shared with agent-cycle.sh, so what the
# dashboard calls blocked or void is by construction what the Co-Ordinator is
# told. Only the projection for display is local. They are shown apart because
# they mean opposite things to a human deciding whether to intervene: a blocked
# item is waiting on something, a void item is finished with.
blocked_json="$(printf '%s\n' "$ALL_EVENTS" | blocked_items - | jq -c \
  'map({repo: (.repo // ""), item: .item, ts: .ts, detail: (.detail // ""), stage: (.stage // "")})' 2>/dev/null)"
[[ -z "$blocked_json" ]] && blocked_json='[]'

# What the Enabler has made of each blocked item (implementation spec 35, 36a),
# joined onto the row rather than listed apart. An escalated item is still a
# blocked item — what changes is *who* it is waiting for, and that is the one
# thing about a blocked row an operator most needs at a glance: their own name on
# an open issue, or the pipeline's last verdict if it is still the pipeline's
# move. Only marks newer than the block count, so a re-blocked item does not
# inherit the resolved escalation of an older one.
blocked_json="$(printf '%s\n' "$ALL_EVENTS" | jq -sc --argjson rows "$blocked_json" '
  . as $events
  | [ $rows[]
      | . as $r
      | ([ $events[] | select(.event == "escalated" and (.item // "") == $r.item
                              and (.repo // "") == $r.repo and .ts > $r.ts) ] | last) as $esc
      | ([ $events[] | select(.event == "enabler-examined" and (.item // "") == $r.item
                              and (.repo // "") == $r.repo and .ts > $r.ts) ] | last) as $exam
      | $r
        + (if $esc == null then {}
           else {escalation_issue: ($esc.issue_number // null),
                 escalation_url: ($esc.issue_url // "")} end)
        + (if $exam == null then {}
           else {enabler_outcome: ($exam.outcome // ""), enabler_ts: ($exam.ts // "")} end) ]' \
  2>/dev/null || true)"
[[ -z "$blocked_json" ]] && blocked_json='[]'

void_json="$(printf '%s\n' "$ALL_EVENTS" | void_items - | jq -c \
  'map({repo: (.repo // ""), item: .item, ts: .ts, detail: (.detail // ""), stage: (.stage // ""), evidence: (.evidence // "")})' 2>/dev/null)"
[[ -z "$void_json" ]] && void_json='[]'

# --- Log tail ----------------------------------------------------------------
log_tail_json="$(printf '%s\n' "$ALL_EVENTS" | jq -sc --argjson n "$MAX_LOG_TAIL" 'sort_by(.ts) | reverse | .[0:$n]' 2>/dev/null)"
[[ -z "$log_tail_json" ]] && log_tail_json='[]'

# --- cron.log tail -----------------------------------------------------------
cron_tail_json='[]'
[[ -f "$cron_log" ]] && cron_tail_json="$(tail -n 40 "$cron_log" 2>/dev/null | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"

# --- What each node is doing (requirement 33 / 2.5) ---------------------------
# `status.current` above answers "what is being worked on right now" for one
# node — this node, off its own live lock. A fleet has no single answer, so the
# same question is answered once per node here and rendered on that node's card.
#
# A peer publishes no lock (state-sync excludes it: a copied lock is a lock no
# process holds), but it does publish its log, and requirement 33 stamps `node`
# on every event. So a peer's state is derived exactly as the local one is,
# from its own most recent cycle: running until that cycle logs `cycle-end`,
# the live stage being the last `stage-start` with no matching `stage-end`, and
# the work whatever its Co-Ordinator selected. What that cannot see is a node
# killed mid-cycle, which leaves a `cycle-start` with no end and so goes on
# looking busy for ever; the page bounds the claim with the heartbeat's
# freshness and `lock_stale_after`, rather than the derivation asserting more
# than the log supports.
node_live_json="$(jq -c '
  def live_of:
    sort_by(.ts)
    | . as $evs
    | ([ $evs[] | select(.event == "cycle-start") ] | last) as $start
    | if $start == null then null
      else
        ($start.cycle) as $cid
        | [ $evs[] | select(.cycle == $cid) ] as $c
        | ([ $c[] | select(.event == "cycle-end") ] | last) as $done
        | { cycle: $cid,
            since: $start.ts,
            running: ($done == null),
            ended_at: ($done.ts // null),
            stage: (
              (reduce ($c[] | select((.event == "stage-start" or .event == "stage-end") and .stage))
                 as $x ({}; .[$x.stage] = $x.event))
              | to_entries | map(select(.value == "stage-start")) | (.[-1].key // null)
            ),
            repo:   ([ $c[] | select(.event == "selection") | .repo ]   | last),
            item:   ([ $c[] | select(.event == "selection") | .item ]   | last),
            source: ([ $c[] | select(.event == "selection") | .source ] | last),
            title:  ([ $c[] | select(.event == "selection") | .title ]  | last) }
      end;
  map(select((.node // "") != "")) | group_by(.node)
  | map({key: .[0].node, value: live_of}) | from_entries' "$events_file")"
# Deliberately *not* 2>/dev/null, unlike the best-effort reads above: this one
# takes a file the Publisher has already guaranteed is valid JSON, so anything
# jq says here is a fault in the program and not in the state. Silencing it
# costs every card its live state and says nothing about why.
[[ -z "$node_live_json" ]] && node_live_json='{}'

# Our own row is not derived: the lock is the authoritative answer for this
# machine (a live pid, not an inference from what was logged), and the Publisher
# has already reduced it to `status.current` above. Deriving it a second time
# would also get it wrong in one real case — a cycle that starts, finds the lock
# held and ends is the *latest* cycle-start while an older one is still running.
self_live_json="$(jq -nc \
  --argjson derived "$(jq -c --arg n "$self_node" '.[$n] // null' <<<"$node_live_json")" \
  --argjson alive "$lock_alive" \
  --argjson st "$status_json" \
  --argjson running "$running_events" '
  if $alive then
    { cycle: ([ $running[] | .cycle ] | last),
      since: ($st.lock.started_at // null),
      running: true, ended_at: null,
      stage:  ($st.current.stage  // null),
      repo:   ($st.current.repo   // null),
      item:   ($st.current.item   // null),
      source: ($st.current.source // null),
      title:  ($st.current.title  // null) }
  elif $derived == null then null
  else $derived + {running: false} end')"
[[ -z "$self_live_json" ]] && self_live_json='null'

# --- The fleet (requirement 2.5 / DASHBOARD-SPEC "one fleet view") -----------
# Who exists and how alive they are, from the peers the last state-sync fetch
# materialised. Self is listed too — definitionally fresh — so every node's
# dashboard shows the same set. A peer's heartbeat is its freshness: pushed
# every 5 minutes, fetched every 7, so anything older than 30 minutes means
# missed pushes or missed fetches, and the entry is flagged stale rather than
# silently trusted.
#
# Each row also carries the node's `version` (lib/version.sh) — the code that
# node is running, ours read directly and a peer's from the heartbeat it
# published. A fleet is routinely mid-update, because a roll defers while a
# cycle is in flight, so "have all the nodes got the fix?" is a real operational
# question with no other answer on this page.
nodes_rows="$work_tmp/nodes.rows"
# The newest local cycle id. Bash sorts a glob's matches, so the last one to
# come round is the greatest — the same answer `ls | sort | tail -1` gave, and
# ids are fixed-width and date-ordered, so greatest is newest. Empty when the
# directory holds nothing or does not exist yet.
last_local_cycle=""
for entry in "$cycles_dir"/*; do
  [[ -e "$entry" ]] || continue
  last_local_cycle="${entry##*/}"
done
jq -nc --arg n "$self_node" --arg r "$(role_current)" --arg ts "$now_iso" --arg lc "$last_local_cycle" \
  --argjson live "$self_live_json" \
  --argjson version "$(agent_ops_version "$SCRIPT_DIR")" \
  '{node: $n, role: $r, heartbeat_ts: $ts, heartbeat_age_s: 0,
    last_cycle: (if $lc == "" then null else $lc end), self: true, stale: false,
    live: $live, version: $version}' > "$nodes_rows"
for hb in "$peers_dir"/*/heartbeat.json; do
  [[ -f "$hb" ]] || continue
  jq -c --argjson now "$now_epoch" --argjson live "$node_live_json" '
    . as $h
    | (try ($h.ts | fromdateiso8601) catch 0) as $t
    | {node: ($h.node // "unknown"), role: ($h.role // "unknown"),
       heartbeat_ts: ($h.ts // null),
       heartbeat_age_s: (if $t > 0 then ([$now - $t, 0] | max) else null end),
       last_cycle: ($h.last_cycle // null), self: false,
       stale: (if $t > 0 then (($now - $t) > 1800) else true end),
       live: ($live[($h.node // "")] // null),
       # Absent on a peer still running an image built before the heartbeat
       # carried one, which is exactly the case the card must render as
       # "version unknown" rather than as our own.
       version: ($h.version // null)}' \
    "$hb" 2>/dev/null >> "$nodes_rows" || true
done
fleet_nodes_json="$(jq -sc 'sort_by([(.self | not), .node])' "$nodes_rows" 2>/dev/null)"
[[ -z "$fleet_nodes_json" ]] && fleet_nodes_json='[]'

# The fleet flags, from the local cache lib/toggle.sh keeps (the GitHub tick
# below refreshes it; requirement 2.3a). Read as files so a --no-github tick
# costs no API call and a standby node still shows them.
fleet_flags_json="$(jq -nc \
  --argjson d "$(jq -c '.' "$(fleet_cache_file "$state_dir" disabled)" 2>/dev/null || echo null)" \
  --argjson l "$(jq -c '.' "$(fleet_cache_file "$state_dir" limit)" 2>/dev/null || echo null)" \
  '{disabled: $d, limit: $l}' 2>/dev/null)"
[[ -z "$fleet_flags_json" ]] && fleet_flags_json='{"disabled":null,"limit":null}'

# --- Live GitHub (best-effort) -----------------------------------------------
# The check roll-up and the index entry, written once and used by both the
# open-PR rows and the pull-request index below. The table and the hover card
# describe the same pull requests, and two copies of the rule is how they would
# come to describe them differently.
# shellcheck disable=SC2016  # the `$slug`/`$at` here are jq parameters
PR_JQ='
  def checks_of: ((. // []) | {
    total: length,
    passed:  (map(select((.conclusion // .state) == "SUCCESS")) | length),
    failed:  (map(select((.conclusion // .state) == "FAILURE" or (.conclusion // .state) == "ERROR" or (.conclusion // .state) == "CANCELLED")) | length),
    pending: (map(select((.status // "") == "IN_PROGRESS" or (.status // "") == "QUEUED" or (.status // "") == "PENDING")) | length)
  });
  def entry_of($slug; $at):
    { ref: ($slug + "#" + (.number | tostring)),
      repo: $slug,
      number: .number,
      title: (.title // ""),
      url: (.url // ""),
      state: (.state // ""),
      is_draft: (.isDraft // false),
      author: (.author.login // ""),
      labels: [ (.labels // [])[] | .name ],
      base: (.baseRefName // ""),
      created_at: (.createdAt // null),
      merged_at: (.mergedAt // null),
      closed_at: (.closedAt // null),
      # Seven characters, because that is what the record is *for*: a reader
      # comparing it against `docker image inspect` or a `git log` line, not
      # re-deriving anything from it.
      merge_commit: ((.mergeCommit.oid // "") | .[0:7]),
      review_decision: (.reviewDecision // ""),
      mergeable: (.mergeable // ""),
      checks: (if has("statusCheckRollup") then (.statusCheckRollup | checks_of) else null end),
      cached_at: $at };
'
PR_INDEX_FIELDS=number,title,url,state,isDraft,createdAt,mergedAt,closedAt,mergeCommit,author,labels,reviewDecision,baseRefName
# How many pull requests an index miss may cost in one tick. A cold index holds
# forty-odd refs and each miss is a `gh pr view` of up to GH_TIMEOUT seconds,
# which would not fit in the heartbeat's window — so it fills a few a tick and
# is warm within the hour. Nothing waits on it: an unindexed number renders as
# the plain link it always was.
PR_INDEX_MISS_BUDGET=8
# An open pull request's record moves; a merged or closed one never does. So
# the cache is permanent for terminal states and this old for the rest.
PR_INDEX_OPEN_TTL=3600

prs_json='[]'; inputs_json='{}'; gh_ok=false; gh_err=""
pr_rows="$work_tmp/pr.rows"; : > "$pr_rows"
if (( WITH_GITHUB )); then
  gh_ok=true
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    prs="$(gh_json pr list -R "$slug" --state open --label "$pr_label" \
             --json "$PR_INDEX_FIELDS",mergeable,mergeStateStatus,headRefName,statusCheckRollup)"
    if [[ -z "$prs" ]]; then gh_ok=false; gh_err="pr list failed for $slug"; prs='[]'; fi
    prs_json="$(jq -c --arg slug "$slug" --argjson add "$prs" "$PR_JQ"'
      . + ($add | map({
        repo: $slug, number, title, url, isDraft, state, mergeable, mergeStateStatus, headRefName, createdAt,
        checks: (.statusCheckRollup | checks_of)
      }))' <<<"$prs_json")"
    # The same fetch, indexed. These entries are this tick's freshest answer for
    # every open agent PR, so they always win over anything cached.
    jq -c --arg slug "$slug" --arg at "$now_iso" "$PR_JQ"'
      .[] | entry_of($slug; $at)' <<<"$prs" >> "$pr_rows" 2>/dev/null || true

    db="$(gh_json api "repos/$slug" --jq '.default_branch')"; db="${db:-main}"
    # The REST listing rather than `gh issue list`, because the Co-Ordinator's
    # ranking turns on each issue's `Priority` issue field (pipeline spec,
    # requirement 15e) and `gh issue list --json` cannot see issue fields. Same
    # shape as before plus `priority`; unset or unrecognised reads as `Medium`,
    # matching what the Co-Ordinator itself will do — a panel that showed a
    # different band from the one the pipeline acted on would be worse than no
    # band at all. The endpoint returns pull requests too, so they are dropped.
    issues="$(gh_json api "repos/$slug/issues?state=open&per_page=30" --jq \
      '[.[] | select(has("pull_request") | not)
            | {number, title, url: .html_url,
               labels: [.labels[] | {name}], assignees: [.assignees[] | {login}],
               priority: (([.issue_field_values[]?
                            | select(.issue_field_name == "Priority")
                            | .single_select_option.name
                            | select(. == "Urgent" or . == "High"
                                     or . == "Medium" or . == "Low")] | first) // "Medium")}]')"
    issues="${issues:-[]}"
    runs="$(gh_json run list -R "$slug" --branch "$db" --limit 40 --json workflowName,conclusion,status,event,createdAt,url)"; runs="${runs:-[]}"
    failed_runs="$(jq -c '
      [ .[] | select(.event == "push" or .event == "schedule" or .event == "dynamic") ]
      | group_by(.workflowName) | map(sort_by(.createdAt) | last)
      | map(select(.conclusion == "failure"))' <<<"$runs" 2>/dev/null)"; failed_runs="${failed_runs:-[]}"

    td_raw="$(gh_json api "repos/$slug/contents/TECH-DEBT.md" --jq '.content' | tr -d '\n' | base64 -d 2>/dev/null | grep -iE '^\|.*\b(open|in-progress|resolved)\b' | head -n 40)"
    td_json="$(printf '%s' "$td_raw" | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"

    # Security & code-quality findings, via the same script the pipeline uses,
    # so the dashboard shows the highest-priority work source the Co-Ordinator
    # actually sees. Always valid JSON; degrades to [] on any failure.
    findings="$(timeout "$GH_TIMEOUT" "$SCRIPT_DIR/scripts/gather-findings.sh" "$slug" 2>/dev/null || echo '[]')"
    findings="$(jq -c 'if type == "array" then . else [] end' <<<"$findings" 2>/dev/null || echo '[]')"

    inputs_json="$(jq -c --arg slug "$slug" \
      --argjson issues "$issues" --argjson failed "$failed_runs" --argjson td "$td_json" --argjson findings "$findings" '
      . + {($slug): {issues: $issues, failed_runs: $failed, tech_debt: $td, findings: $findings}}' <<<"$inputs_json")"
  done < <(jq -r '.[].slug' <<<"$repos_json")

  # Refresh the fleet-flag cache while we are talking to GitHub anyway
  # (requirement 2.3a): the cycles fall back to these cached copies when the
  # state repo is unreachable, and a standby node — which runs no cycles —
  # has no other refresher. The publisher only warms the cache; nothing here
  # acts on the flags. Re-read after the refresh so this very publish shows
  # what was just fetched, not last tick's copy.
  fleet_flag_fetch "$state_repo" "$state_dir" disabled >/dev/null || true
  fleet_flag_fetch "$state_repo" "$state_dir" limit    >/dev/null || true
  fleet_flags_json="$(jq -nc \
    --argjson d "$(jq -c '.' "$(fleet_cache_file "$state_dir" disabled)" 2>/dev/null || echo null)" \
    --argjson l "$(jq -c '.' "$(fleet_cache_file "$state_dir" limit)" 2>/dev/null || echo null)" \
    '{disabled: $d, limit: $l}' 2>/dev/null)"
  [[ -z "$fleet_flags_json" ]] && fleet_flags_json='{"disabled":null,"limit":null}'

  # The live claim registry (implementation spec 17a): what the fleet holds
  # right now, per repo. Carried forward through gh_cache on --no-github ticks
  # like every other GitHub-sourced fact; failures degrade to the empty list.
  #
  # One recursive trees call enumerates the whole registry — path and blob SHA
  # for every claim — where walking `contents/` cost a call for the claims
  # directory, one per repository under it and one per claim (1 + D + F round
  # trips, each a fresh `gh` process at ~0.5s). Only the blob reads are left
  # per claim, and a blob's SHA names its bytes for ever, so an unchanged claim
  # is read from the local cache instead of the API: a fleet whose claims are
  # not moving costs one call a tick however many it holds.
  claims_rows="$work_tmp/claims.rows"
  : > "$claims_rows"
  if [[ -n "$state_repo" ]]; then
    claims_tree="$work_tmp/claims.tree"
    # Only replace the cache if this listing actually succeeded — a failed call
    # must degrade to "no claims shown this tick", not to "every claim
    # re-fetched next tick".
    if gh_json api "repos/$state_repo/git/trees/HEAD?recursive=1" \
         --jq '.tree[] | select(.type == "blob" and (.path | startswith("claims/"))) | "\(.sha)\t\(.path)"' \
         > "$claims_tree" 2>/dev/null; then
      claims_cache_new="$work_tmp/claims.cache"
      printf '{}' > "$claims_cache_new"
      while IFS=$'\t' read -r csha cpath; do
        [[ -n "$csha" && -n "$cpath" ]] || continue
        rel="${cpath#claims/}"
        cdir="${rel%%/*}"; cfile="${rel##*/}"
        # claims/<repo>/<key>.json and nothing else; anything shallower or
        # deeper is not a claim this reader understands.
        [[ "$cdir/$cfile" == "$rel" && "$cfile" == *.json ]] || continue
        entry="$(jq -c --arg s "$csha" '.[$s] // empty' "$claims_cache" 2>/dev/null)"
        [[ -n "$entry" ]] || entry="$(gh_json api "repos/$state_repo/git/blobs/$csha" --jq '.content' \
          | tr -d '\n' | base64 -d 2>/dev/null | jq -c '.' 2>/dev/null)" || entry=""
        [[ -n "$entry" ]] || continue
        # Both halves of the path were written through lib/claim.sh's san(),
        # which replaces '/' with '__'; undo both, as claim.sh's own reader
        # does. (The key went un-restored here until now, so a branch claim
        # rendered as `agent__td-…` on the page and `agent/td-…` everywhere
        # else.)
        ckey="${cfile%.json}"
        jq -c --arg r "${cdir//__//}" --arg k "${ckey//__//}" '. + {repo: $r, key: $k}' \
          <<<"$entry" >> "$claims_rows" 2>/dev/null
        jq -c --arg s "$csha" --argjson b "$entry" '.[$s] = $b' "$claims_cache_new" \
          > "$claims_cache_new.t" 2>/dev/null && mv "$claims_cache_new.t" "$claims_cache_new"
      done < "$claims_tree"
      # Only the SHAs still in the registry survive, so a cache of released
      # claims cannot accumulate.
      mv "$claims_cache_new" "$claims_cache"
    fi
  fi
  claims_json="$(jq -sc 'sort_by(.ts) | reverse' "$claims_rows" 2>/dev/null)"
  [[ -z "$claims_json" ]] && claims_json='[]'

  # --- The pull-request index (what a `#number` on the page means) ------------
  # Every pull-request number the page shows resolves to one record here, so a
  # reader can learn what a number *is* without leaving the page: which repo,
  # what it did, whether it landed and when, and which commit it left behind.
  # That question is asked in three places and the number alone answers none of
  # them — least of all the newest, where `#89` is the version a container is
  # running and the only thing that makes it meaningful is the record behind it.
  #
  # Two properties keep it cheap. A merged or closed pull request never changes
  # again, so its entry is cached for ever (`.dashboard-prs.json`, beside the
  # state like the other caches) and a warm tick costs no call at all; the open
  # ones that matter are refetched wholesale by the label query above. And a
  # cold index fills a few refs a tick rather than in one burst, because forty
  # `gh pr view` calls at up to GH_TIMEOUT each would not fit in the heartbeat's
  # window. Nothing waits on it: an unindexed number renders as the plain link
  # it has always been, and gains its card a tick or two later.
  pr_refs_json="$work_tmp/pr-refs.json"
  {
    # Every pull request a cycle in the detail list raised.
    jq -r '
      def ref_of: capture("github\\.com/(?<slug>[^/]+/[^/]+)/pull/(?<n>[0-9]+)")
                  | "\(.slug)#\(.n)";
      .[] | (.pr_url // "") | select(. != "") | ref_of' "$cycles_file" 2>/dev/null
    # The version each node reports running — the one reference that is a
    # merged pull request by construction, and the reason the index cannot be
    # built from the open-PR query alone.
    jq -r '.[] | select((.version.pr // null) != null and (.version.repo // "") != "")
             | "\(.version.repo)#\(.version.pr)"' <<<"$fleet_nodes_json" 2>/dev/null
  } | sort -u | jq -Rsc 'split("\n") | map(select(length > 0))' > "$pr_refs_json" 2>/dev/null
  jq -e 'type == "array"' "$pr_refs_json" >/dev/null 2>&1 || printf '[]' > "$pr_refs_json"

  pr_cache_json="$work_tmp/pr-cache.json"
  if [[ -s "$pr_cache" ]] && jq -e 'type == "object"' "$pr_cache" >/dev/null 2>&1; then
    cp "$pr_cache" "$pr_cache_json"
  else
    printf '{}' > "$pr_cache_json"
  fi

  # The cache, with this tick's fresh rows folded over it — so an open PR the
  # label query just re-read wins over the copy cached an hour ago.
  pr_index_file="$work_tmp/pr-index.json"
  jq -sc --slurpfile cache "$pr_cache_json" '
    ($cache[0] // {}) as $c | reduce .[] as $e ($c; .[$e.ref] = $e)' \
    "$pr_rows" > "$pr_index_file" 2>/dev/null
  jq -e 'type == "object"' "$pr_index_file" >/dev/null 2>&1 || printf '{}' > "$pr_index_file"

  # What is still missing, or cached open and gone stale. A terminal entry is
  # never re-read: that is the whole reason this stays free.
  pr_misses=()
  mapfile -t pr_misses < <(jq -r --slurpfile idx "$pr_index_file" \
    --argjson now "$now_epoch" --argjson ttl "$PR_INDEX_OPEN_TTL" '
    ($idx[0] // {}) as $i
    | .[]
    | . as $ref
    | ($i[$ref] // null) as $e
    | if   $e == null                                       then $ref
      elif ($e.state == "MERGED" or $e.state == "CLOSED")    then empty
      elif ((try ($e.cached_at | fromdateiso8601) catch 0) + $ttl) < $now then $ref
      else empty end' "$pr_refs_json" 2>/dev/null)

  pr_fetched=0
  for pr_ref in ${pr_misses[@]+"${pr_misses[@]}"}; do
    (( pr_fetched < PR_INDEX_MISS_BUDGET )) || break
    pr_slug="${pr_ref%#*}"; pr_num="${pr_ref#*#}"
    [[ "$pr_slug" == */* && "$pr_num" =~ ^[0-9]+$ ]] || continue
    pr_view="$(gh_json pr view "$pr_num" -R "$pr_slug" --json "$PR_INDEX_FIELDS")"
    [[ -n "$pr_view" ]] || continue
    pr_fetched=$(( pr_fetched + 1 ))
    jq -c --arg slug "$pr_slug" --arg at "$now_iso" "$PR_JQ"'entry_of($slug; $at)' \
      <<<"$pr_view" >> "$pr_rows" 2>/dev/null || true
  done

  # Fold again (this time including anything just fetched) and keep only what
  # the page actually refers to, plus everything read this tick. A cache whose
  # keys are the refs still on the page cannot grow without bound, and nothing
  # else needs pruning rules.
  jq -sc --slurpfile cache "$pr_cache_json" --slurpfile refs "$pr_refs_json" '
    ($cache[0] // {}) as $c
    | (reduce .[] as $e ($c; .[$e.ref] = $e)) as $all
    | ([ .[].ref ] + ($refs[0] // []) | unique) as $keep
    | reduce $keep[] as $r ({}; if $all[$r] then .[$r] = $all[$r] else . end)' \
    "$pr_rows" > "$pr_index_file" 2>/dev/null
  jq -e 'type == "object"' "$pr_index_file" >/dev/null 2>&1 || printf '{}' > "$pr_index_file"
  cp "$pr_index_file" "$pr_cache" 2>/dev/null || true

  github_json="$(jq -n --argjson ok "$gh_ok" --arg err "$gh_err" --arg at "$now_iso" \
    --argjson prs "$prs_json" --argjson inputs "$inputs_json" --argjson claims "$claims_json" \
    --slurpfile pri "$pr_index_file" \
    '{ok: $ok, error: $err, fetched_at: $at, stale: false, prs: $prs, inputs: $inputs,
      claims: $claims, pr_index: ($pri[0] // {})}')"
  # Remember this fetch (ok or failed — it is the latest real attempt) so the
  # next --no-github tick can carry it forward rather than start from nothing.
  printf '%s' "$github_json" > "$gh_cache"
else
  # Local-only refresh: don't re-hit GitHub. Reuse the last real fetch verbatim
  # (PRs, work sources, and its ok/error state) and only flag it stale. This is
  # why the sub-minute heartbeat can refresh local state every few seconds
  # without the GitHub panels flickering empty or the "unavailable" banner
  # firing 59 ticks out of 60 — that banner keys on ok === false, which now
  # only ever reflects a fetch that was actually attempted and failed.
  if [[ -s "$gh_cache" ]] && jq -e . "$gh_cache" >/dev/null 2>&1; then
    github_json="$(jq -c '.stale = true' "$gh_cache")"
  else
    # Never fetched yet (e.g. the very first run was --no-github): a neutral
    # not-yet state, not a failure. ok is null so no banner fires.
    github_json='{"ok":null,"error":"","fetched_at":null,"stale":true,"prs":[],"inputs":{},"pr_index":{}}'
  fi
fi

# --- Assemble ----------------------------------------------------------------
# cycles/github/log_tail can each be large; hand them to jq via files.
# fleet.claims rides in github (fetched on the tick, carried by gh_cache
# between ticks); it is surfaced under fleet because that is what it is.
printf '%s' "$github_json"   > "$work_tmp/github.json"
printf '%s' "$log_tail_json" > "$work_tmp/logtail.json"
data_json="$(jq -n \
  --arg generated_at "$now_iso" \
  --arg self_node "$self_node" \
  --argjson config "$(jq -c '{repos, coordinator_model, implementor_model_default, implementor_model_trivial, reviewer_model_default, reviewer_model_complex, pr_label, branch_prefix, max_open_agent_prs, timeout_coordinator, timeout_implementor, timeout_reviewer, lock_stale_after, limit_cooldown_default, dashboard_refresh_seconds}' "$CONFIG_FILE")" \
  --argjson status "$status_json" \
  --argjson counts "$counts_json" \
  --slurpfile cyc "$cycles_file" \
  --argjson blocked "$blocked_json" \
  --argjson void "$void_json" \
  --slurpfile gh "$work_tmp/github.json" \
  --slurpfile lt "$work_tmp/logtail.json" \
  --argjson cron_tail "$cron_tail_json" \
  --argjson fleet_nodes "$fleet_nodes_json" \
  --argjson fleet_flags "$fleet_flags_json" \
  --arg max_prs "$max_open_agent_prs" \
  '{generated_at: $generated_at, node: $self_node, config: $config, status: $status, counts: $counts,
    cycles: $cyc[0], blocked: $blocked, void: $void, github: $gh[0], log_tail: $lt[0],
    cron_tail: $cron_tail, max_open_agent_prs: ($max_prs|tonumber),
    fleet: {nodes: $fleet_nodes, flags: $fleet_flags, claims: ($gh[0].claims // [])}}')"

# --- Redact (defensive) & write atomically -----------------------------------
redact() {
  sed -E \
    -e "s#/home/[A-Za-z0-9._-]+#~#g" \
    -e "s#/Users/[A-Za-z0-9._-]+#~#g" \
    -e "s#gh[pousr]_[A-Za-z0-9]{16,}#[REDACTED-TOKEN]#g" \
    -e "s#github_pat_[A-Za-z0-9_]{20,}#[REDACTED-TOKEN]#g" \
    -e "s#sk-(ant-|proj-)?[A-Za-z0-9_-]{16,}#[REDACTED-TOKEN]#g" \
    -e "s#(Bearer|token) [A-Za-z0-9._~+/-]{16,}#\1 [REDACTED-TOKEN]#g"
}

tmp="$(mktemp "$out_dir/.data.XXXXXX.js")"
{
  printf '// Generated by publish-dashboard.sh at %s — do not edit. Regenerated each run.\n' "$now_iso"
  printf 'window.DASHBOARD_DATA = '
  printf '%s' "$data_json" | redact
  printf ';\n'
} > "$tmp"
mv -f "$tmp" "$data_file"

# Refresh the page template alongside the data (source of truth is the repo).
[[ -f "$TEMPLATE" ]] && cp -f "$TEMPLATE" "$out_dir/index.html"

echo "publish-dashboard: wrote $data_file ($(wc -c < "$data_file") bytes); open $out_dir/index.html"
exit 0
