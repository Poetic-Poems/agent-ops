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
# lib/merge-queue.sh's own seam, pointed at the same stub as everything else
# this script calls through gh — sweep-human-visibility.sh sets it the same
# way for the same reason.
MERGE_QUEUE_GH="$DASHBOARD_GH_CMD"
export MERGE_QUEUE_GH

for bin in jq "$DASHBOARD_GH_CMD"; do
  command -v "$bin" >/dev/null 2>&1 || { echo "publish-dashboard: missing binary: $bin" >&2; exit 1; }
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
TEMPLATE="$SCRIPT_DIR/dashboard/index.html"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
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
# shellcheck source=lib/compose-drift.sh
. "$SCRIPT_DIR/lib/compose-drift.sh"
# shellcheck source=lib/image-drift.sh
. "$SCRIPT_DIR/lib/image-drift.sh"
# shellcheck source=lib/stage-budget.sh
. "$SCRIPT_DIR/lib/stage-budget.sh"
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/merge-autonomy.sh
# Only `merge_autonomy_kill_state` (D18 issue #576) is used here — the same
# reader scripts/doctor.sh already sources it through — so this file never
# also needs lib/merge-budget.sh, which merge_autonomy_effective_level alone
# (never called from this script) would require.
. "$SCRIPT_DIR/lib/merge-autonomy.sh"

MAX_CYCLES=40        # recent substantive cycles shown in detail (with
                     # transcripts); no-op ticks aggregate instead (#271)
MAX_LOG_TAIL=300     # recent raw log events surfaced
TRANSCRIPT_CAP=40000 # bytes kept per transcript / stderr
GH_TIMEOUT=15        # seconds per gh call
COST_SCAN_DAYS=60    # how far back to scan transcripts for cost roll-ups

WITH_GITHUB=1
[[ "${1:-}" == "--no-github" ]] && WITH_GITHUB=0

# --- Config ------------------------------------------------------------------
expand_home() { local p="$1"; [[ "$p" == "~"* ]] && p="$HOME${p:1}"; printf '%s\n' "$p"; }
# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below, with no `// literal` of its own to drift from the schema's.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg()      { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }
cfg_json() { jq -c "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

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
state_repo="$(cfg '.state_repo')"
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
# Tech-debt item metadata (title, status) by blob SHA, on the same never-stale
# argument as the claims cache: an item file's SHA names its bytes, so the
# title behind it cannot change without the SHA changing. An item is written
# once and touched again only when its status flips, so a warm register costs
# no call at all. Kept out of the served dir like the three caches above.
td_cache="$state_dir/.dashboard-td.json"
# The merge-queue state machine for every open agent pull request, by
# "<owner>/<repo>#<number>" — not a TTL cache like the others above, but the
# Publisher's own memory of `{queued, warn}`, which is what lets a dequeue be
# detected and held as a transition (this tick's answer versus the last one
# seen) rather than re-derived from GitHub's own removal-event history
# (agent-ops#394's open follow-up on that approach). Rewritten wholesale each
# GitHub tick from that tick's own open pull requests, so it never
# accumulates entries for a pull request that has merged or closed. Kept out
# of the served dir like the four caches above.
queue_cache="$state_dir/.dashboard-queue.json"
# This node's own image-drift verdict (lib/image-drift.sh), cached because
# unlike compose_drift_status and agent_ops_version it costs a real network
# round trip — one this script cannot pay on every 5-second tick. The name is
# fixed rather than derived from anything here so that scripts/state-sync.sh
# (which computes the identical verdict for the fleet heartbeat) names the
# same file: whichever of the two next crosses the cache's TTL pays the one
# query and the other reads its answer off disk.
image_cache="$state_dir/.image-drift-cache.json"
# The hourly `doctor.sh --unattended` pass's own artefact (agent-ops#543),
# read rather than recomputed: its GitHub section alone makes several calls
# per configured repository, too much to repeat on this script's own 5-minute
# heartbeat, so a separate crontab.tmpl line runs it once an hour and writes
# this instead. `null` when no unattended pass has run yet on this node.
doctor_status_file="$state_dir/.doctor-status.json"
doctor_status_json="$(jq -c '.' "$doctor_status_file" 2>/dev/null || echo null)"
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

# gh_call — like gh_json, but a source that needs to tell "answered emptily"
# from "failed to answer" (TD-PPagop-26080201) cannot afford gh_json's own
# trade: it discards stderr and the caller is left reading an empty string
# either way. Prints stdout exactly as gh_json does and returns gh's exit
# status, so `x="$(gh_call …)"; rc=$?` gives a caller both the answer and
# whether the call actually succeeded; gh_call_err (below) gives it gh's own
# diagnosis of that same call, on request.
gh_call() {
  timeout "$GH_TIMEOUT" "$DASHBOARD_GH_CMD" "$@" 2>"$work_tmp/gh_call.err"
}
# gh's own diagnosis of the *last* gh_call, one line. Every caller checks it
# immediately after its own gh_call and before anyone else's, so there is
# nothing here yet to overwrite it — a plain file rather than a variable
# gh_call itself sets, because every caller is `x="$(gh_call …)"`, and a
# command substitution runs in a subshell: an assignment gh_call made to a
# "global" there would vanish the moment that subshell exited, exactly the
# trap scripts/gather-findings.sh's own fetch() avoids the same way.
gh_call_err() { tr '\n' ' ' < "$work_tmp/gh_call.err" 2>/dev/null; }

epoch_of() { date -d "$1" +%s 2>/dev/null || echo 0; }

# td_frontmatter — read a tech-debt item file on stdin, print "<title>\t<status>".
# The same shape scripts/td-check.pl and scripts/get-tech-debt-record.pl parse:
# a leading `---` line, `key: value` lines with the key case-folded, a closing
# `---`. Anything else prints an empty pair, which renders as the bare ID —
# the page must never turn a malformed item into a missing one. Tabs in a
# value would split the pair, so they are spaces by the time it is emitted.
td_frontmatter() {
  awk '
    NR == 1              { if ($0 !~ /^---[ \t\r]*$/) exit; next }
    /^---[ \t\r]*$/      { exit }
    /^[A-Za-z][A-Za-z-]*:/ {
      key = tolower(substr($0, 1, index($0, ":") - 1))
      val = substr($0, index($0, ":") + 1)
      gsub(/\t/, " ", val); sub(/^[ ]+/, "", val); sub(/[ \r]+$/, "", val)
      if      (key == "title")  title  = val
      else if (key == "status") status = val
    }
    END { printf "%s\t%s\n", title, status }
  '
}

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

# TRANSCRIPT_CAP is a byte budget (see its definition above), but jq's own
# `.[0:$cap]` slices by Unicode codepoint, not byte — a transcript with
# multi-byte UTF-8 content (this pipeline handles poems, so non-ASCII text is
# routine, not an edge case) would slice to $cap *characters*, up to 4x
# $cap bytes for an all-multi-byte transcript, defeating the cap the 5-second
# heartbeat budget (this same TD) relies on to bound data.js size. This walks
# codepoints, summing each one's UTF-8 encoded length, and stops at the last
# whole codepoint that still fits in $cap bytes — matching head -c's byte
# budget while (unlike head -c) never splitting a multi-byte codepoint.
def byte_trunc($s; $cap):
  ($s | explode) as $cps
  | (reduce $cps[] as $cp ({bytes:0, out:[], done:false};
       if .done then .
       else
         ($cp | if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end) as $blen
         | if (.bytes + $blen) > $cap then (.done = true)
           else {bytes: (.bytes + $blen), out: (.out + [$cp]), done: false}
           end
       end)) as $r
  | ($r.out | implode);

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
# outright, else the last fenced ``` block within it regardless of its info
# string, else the earliest brace-opening line whose suffix parses as JSON
# (the same algorithm as agent-cycle.sh's extract_json_result, per
# DASHBOARD-SPEC.md — the design note on the third step, the 2026-08-03
# Enabler engagement it would have saved, and issue #237's fence-tag fix,
# live on that function; the dashboard must parse the same verdicts the
# cycle accepted, or a rescued engagement renders here as a stage that said
# nothing). An empty-or-whitespace result
# is a stage that ran and said nothing parseable, exactly like any other
# unparseable text (TD26072802): `ok:true` with a null status, so it renders
# in its own cycle's row instead of the whole cycle vanishing. (The pre-jq
# `stage_json`/`cycle_json` code went `ok:false` here by shell accident, not
# design — `jq empty`/`jq -c '.'` produced nothing for whitespace input,
# which collapsed a `--argjson` into invalid JSON and failed the enclosing
# `jq -n` call for the whole cycle.)
def extract_status($text):
  if ($text | test("^\\s*$")) then {ok:true, value:null}
  else
    (try_json($text)) as $direct
    | if $direct != null then {ok:true, value:$direct}
      else
        ($text | split("\n")) as $lines
        | (reduce $lines[] as $line
             ({in_block:false, capture:"", last:null};
              if ($line | test("^```[A-Za-z0-9_-]*[[:space:]]*$")) then
                if .in_block then (.last = .capture | .in_block = false)
                else (.in_block = true | .capture = "")
                end
              elif .in_block then
                .capture += ($line + "\n")
              else . end)).last as $block
        | if $block != null and ($block | length) > 0 and (try_json($block) != null) then
            {ok:true, value: try_json($block)}
          else
            # The bare-object salvage: the earliest line opening a brace whose
            # text from there to the end parses. `fromjson` (via try_json) is
            # already single-value-strict, matching the bash side's
            # `jq -es 'length == 1'`.
            {ok:true,
             value: (first(
                       range(0; $lines | length) as $i
                       | select($lines[$i] | test("^\\s*\\{"))
                       | (try_json($lines[$i:] | join("\n"))) as $v
                       | select($v != null)
                       | $v
                     ) // null)}
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
    | (($envtry | type) == "object") as $env_ok
    | (if $env_ok then $envtry else {} end) as $env
    # `sub("\n+$";"")` mirrors the trailing-newline strip every bash
    # `$(...)` capture in the old stage_json got for free; without it, a
    # stage whose result/stderr ends in a newline would render with one jq's
    # string slicing would otherwise keep.
    | ($env.result // "" | sub("\n+$"; "")) as $result_stripped
    | byte_trunc($result_stripped; $cap) as $result_disp
    | (byte_trunc($err_full; $cap) | sub("\n+$"; "")) as $err_disp
    | extract_status($result_stripped) as $status
    | limit_info($out_full; $err_full) as $lim
    | {
        # $env_ok, not $status.ok (extract_status always returns ok:true —
        # a stage that ran and produced *some* envelope always renders, even
        # with a null status). A torn/mid-write envelope is what still drops
        # the whole cycle: $envtry never became an object, so $env fell back
        # to {} and $result_stripped is indistinguishable from a genuinely
        # empty result — the two are told apart here, before extract_status
        # ever sees the text.
        ok: $env_ok,
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
  | (["coordinator","implementer","reviewer"] | map(build_stage($manifest_idx[$cid + "|" + .]; $cap))) as $built
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
          # Issue #245: whether this cycle lost a claim to healthy contention
          # before its outcome was decided — a stand-down `cause` of "raced"
          # (every candidate lost, exit 0 empty-handed) or a `claim-lost`
          # (cause "held") on a candidate this cycle then moved past to reach
          # whatever `outcome` below records. A `claim-skipped` (cause
          # "pre-claimed", spec 17a) is deliberately neither: no peer raced
          # this cycle for anything, so it must not light this badge. `raced` with an `outcome` other
          # than "stand-down" is a *recovered* race: the fleet contended for
          # the top candidate and this cycle still did the next one's work,
          # rather than forfeiting the cycle outright.
          #
          # `race_losses` (requirement 17d) is counted from those same
          # `claim-lost` events rather than read off the `selection` event
          # that also carries it: the two agree wherever a selection happened
          # at all, and only the count covers the cycle that stood down
          # having lost every candidate, which has no `selection` event to
          # read.
          race_losses: ([ $e[] | select(.event=="claim-lost" and (.cause // "") == "held") ] | length),
          raced: (([ $e[] | select(.event=="claim-lost" and (.cause // "") == "held") ] | length) > 0),
          standdown_cause: ([ $e[] | select(.event=="stand-down") | .cause ] | last),
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
          stages: { coordinator: $stageobjs[0], implementer: $stageobjs[1], reviewer: $stageobjs[2] },
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

# Nor does a no-op tick hold a detail slot (issue #271). Under the `*/15`
# cadence most firings are no-ops — the stand-down short-circuit
# (`cycle-start` → `stand-down` → `cycle-end`) and the lock-held skip
# (`cycle-start` → `cycle-skipped` → `cycle-end`) — and at one slot each they
# shrank the fleet's MAX_CYCLES window from half a day of history to a couple
# of hours of mostly nothing. They are classified here, ahead of the cap, and
# surfaced as the single O(1) `noop_ticks` aggregate (a count split by kind
# plus the newest timestamp) rather than as rows or a second list — the cap
# is what keeps data.js near its single-node size, and the aggregate must not
# grow with what it counts. The match is those exact event shapes: a cycle
# that logged anything else — a `claim-lost` race (17d's badge lives on that
# row), a `claim-skipped` (a pre-claimed stand-down is a selection defect,
# not a no-op), an `unvoided`, a kill that cost it its `cycle-end` — carries
# information and keeps its row.
noop_cycles_file="$work_tmp/noop-cycles.json"
jq -c --arg re "$cycle_id_re" '
  # The kind is named by the outcome value the detail ladder (cycle_obj)
  # would have given the row: "stand-down" or "skipped", or null for any
  # cycle that is not one of the two no-op shapes.
  def noop_kind:
    ([ .[].event ] | unique) as $t
    | if   (($t - ["cycle-start", "stand-down", "cycle-end"]) == [])
           and ($t | contains(["stand-down", "cycle-end"]))    then "stand-down"
      elif (($t - ["cycle-start", "cycle-skipped", "cycle-end"]) == [])
           and ($t | contains(["cycle-skipped", "cycle-end"])) then "skipped"
      else null end;
  [ .[] | select((.cycle // "") | test($re)) ]
  | group_by(.cycle)
  | map({id: .[0].cycle, kind: noop_kind, last_ts: ([ .[].ts // "" ] | max)})
  | map(select(.kind != null))' "$events_file" > "$noop_cycles_file" 2>/dev/null
jq -e 'type == "array"' "$noop_cycles_file" >/dev/null 2>&1 || printf '[]' > "$noop_cycles_file"
noop_ids="$work_tmp/noop-ids"
jq -r '.[].id' "$noop_cycles_file" > "$noop_ids" 2>/dev/null || : > "$noop_ids"
noop_json="$(jq -c '{total: length,
                     standdown: (map(select(.kind == "stand-down")) | length),
                     skipped:   (map(select(.kind == "skipped"))    | length),
                     last_ts:   ((map(.last_ts) | max) // null)}' "$noop_cycles_file" 2>/dev/null)"
[[ -n "$noop_json" ]] || noop_json='{"total":0,"standdown":0,"skipped":0,"last_ts":null}'

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
} | sort -t "$tab" -k1,1r -k2,2 | awk -F'\t' -v re="$cycle_id_re" -v noopfile="$noop_ids" \
      'BEGIN { while ((getline id < noopfile) > 0) noop[id] = 1 }
       $1 ~ re && !($1 in noop) && !seen[$1]++' | cut -f1,3 \
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
  for stage in coordinator implementer reviewer; do
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
# `host` names the container (PID namespace) the lock's pid is meaningful in
# (agent-cycle.sh's acquire_lock, #130). This reader is almost always a
# foreign one: the dashboard shares the scheduler's state volume but never its
# PID namespace (deploy/docker/compose.yaml), so a bare `kill -0` here answers
# about an unrelated process in *our* namespace, not the scheduler's — able to
# say "running" for a pid that only coincidentally matches something local, or
# "not running" for a writer that is very much alive next door, exactly the
# confusion #130 fixed in the watchtower pre-update hook and
# TD-PPagop-26072901 fixed in both cycle scripts' `acquire_lock`. Only a lock
# this container itself wrote, or one from before the `host` stamp existed, is
# answerable by `kill -0`; any other lock is unanswerable from here and reads
# as not alive, exactly as if there were no lock at all — `self_live_json`
# below already falls back to the log-derived state on that path.
lock_pid=""; lock_started=""; lock_alive=false
if [[ -f "$lock_file" ]]; then
  lock_pid="$(jq -r '.pid // empty' "$lock_file" 2>/dev/null)"
  lock_started="$(jq -r '.started_at // empty' "$lock_file" 2>/dev/null)"
  lock_host="$(jq -r '.host // empty' "$lock_file" 2>/dev/null)"
  if [[ "$lock_pid" =~ ^[0-9]+$ && ( -z "$lock_host" || "$lock_host" == "${HOSTNAME:-}" ) ]]; then
    kill -0 "$lock_pid" 2>/dev/null && lock_alive=true
  fi
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
      then (.stages.implementer.limit_text // .stages.reviewer.limit_text // .stages.coordinator.limit_text // "usage limit reported in transcript")
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
switch_json="$(toggle_switch_summary "$state_dir")"

status_json="$(jq -n \
  --argjson alive "$lock_alive" \
  --arg pid "$lock_pid" --arg started "$lock_started" \
  --argjson running "$running_events" \
  --argjson limit_active "$limit_active" --arg limit_note "$limit_note" \
  --argjson switch "$switch_json" \
  --argjson doctor "$doctor_status_json" \
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
        ((reduce (.[] | select((.event=="stage-start" or .event=="stage-end") and .stage)) as $x
            ({}; .[$x.stage] = {event: $x.event, ts: $x.ts, backstop: $x.backstop_min}))
         | to_entries | map(select(.value.event=="stage-start")) | last) as $live_stage
        | {
          stage: ($live_stage.key // null),
          # When that stage started. Every stage the pipeline runs is bounded —
          # agent-cycle.sh hands run_claude_stage a timeout and kills the process
          # group when it expires — so the page can hold a live stage against its
          # own timeout and say, in minutes rather than in hours, that a stage
          # still shown as running has in fact been killed.
          stage_since: ($live_stage.value.ts // null),
          # The cap this stage was actually given (requirement 4f announces it
          # on stage-start). Carried rather than re-derived, because it is the
          # number that will kill this stage and no other; every stage now has
          # its own, so a shared config key could only ever be an approximation
          # of it.
          stage_backstop_min: ($live_stage.value.backstop // null),
          repo:   ([ .[] | select(.event=="selection") | .repo ]   | last),
          item:   ([ .[] | select(.event=="selection") | .item ]   | last),
          source: ([ .[] | select(.event=="selection") | .source ] | last),
          title:  ([ .[] | select(.event=="selection") | .title ]  | last),
          race_losses: (([ .[] | select(.event=="selection") | .race_losses ] | last) // 0)
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
      switch: $switch,
      doctor: $doctor
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
# `reviews/` is scanned alongside `cycles/`: the repository-review pipeline
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
# Each row also carries `ts` — the cycle/review id's own timestamp
# (`YYYYMMDDTHHMMSSZ-…`, always UTC) reformatted to a plain ISO 8601 instant —
# alongside the coarser `day` bucket the charts already group by. `day` alone
# can only ever answer "which GMT calendar day", which is exactly what issue
# #186 found not obvious: a reader in any other zone sees a "today" that
# doesn't match their own clock. `ts` is null for a row whose directory name
# doesn't match the expected shape (a hand-placed or future format change)
# rather than a guess, so a malformed name drops out of `recent_costs` below
# without corrupting the totals that never depended on it.
#
# `cost_rows` (issue #334) is the per-(transcript × model) breakdown of this
# same set, trimmed to {day, model, actor, usd, cycle} — un-summed, so the
# page can re-aggregate the model/actor breakdowns over whatever time frame
# the reader picks instead of only the whole COST_SCAN_DAYS window
# `by_day`/`by_model`/`by_actor` are fixed to. `cycle` carries the same
# transcript's cost across the (possibly several) model rows it now
# contributes: the model chart's windowed `n` wants a count of rows (one per
# model a transcript touched, matching `by_model.n` below) but the actor
# chart's wants a count of transcripts (one per `.out` file, matching
# `by_actor.n` below) — without `cycle` the client cannot tell those two
# counts apart once a transcript spans more than one model, and a reader who
# narrows the time-frame selector would see an actor's "stage run(s)" figure
# inflated by however many of its transcripts touched two models. `models[]`
# below is one entry per `modelUsage` key,
# each carrying that model's own `costUSD` (issue #536): a transcript's whole
# `total_cost_usd` is not one model's spend, subagent calls routinely add a
# second (typically a cheaper model dispatched inside the same invocation),
# and crediting all of it to whichever key `keys[0]` names credited every
# subagent's spend to that one alphabetically-first model — systematically
# Haiku, since it sorts before Opus and Sonnet. Summing `models[].usd` back up
# reproduces `total_cost_usd` to the cent. `select(.value | type == "object")`
# mirrors `lib/metering.sh`'s own `tokens` derivation: a `modelUsage` entry
# that isn't an object (seen in the wild as a bare number) would make `.value
# .costUSD` a hard jq error, taking a parseable envelope's whole row down with
# it, so it is skipped rather than fatal. An empty or unreadable `modelUsage`
# falls back to one `unknown` entry carrying the transcript's whole cost, so
# that total is never lost — only its model attribution is.
# shellcheck disable=SC2016  # `$p` below is a jq binding, not a shell variable
find "${cost_dirs[@]}" -name '*.out' -type f -print0 2>/dev/null | sort -z \
  | xargs -0 -r -n 25 jq -c '
      (input_filename | split("/")) as $p
      | ($p[-2] // "") as $cid
      | (.total_cost_usd // 0) as $total
      | ((.modelUsage // {}) as $mu
         | (if ($mu | type) == "object" then $mu else {} end)
         | to_entries
         | map(select(.value | type == "object"))
         | map({model: .key, usd: (.value.costUSD // 0)})) as $model_entries
      | (if ($model_entries | length) > 0 then $model_entries
         else [{model: "unknown", usd: $total}] end) as $models
      | {
          day: ($cid[0:8]),
          ts: (if ($cid | test("^[0-9]{8}T[0-9]{6}Z"))
               then ($cid[0:16]
                     | capture("(?<Y>[0-9]{4})(?<Mo>[0-9]{2})(?<D>[0-9]{2})T(?<H>[0-9]{2})(?<Mi>[0-9]{2})(?<S>[0-9]{2})Z")
                     | .Y+"-"+.Mo+"-"+.D+"T"+.H+":"+.Mi+":"+.S+"Z")
               else null end),
          cost: $total,
          models: $models,
          cycle: $cid,
          actor: (if ($p[-3] // "") == "reviews" then "project-reviewer"
                  else ($p[-1] | rtrimstr(".out")) end)
        }' 2>/dev/null \
  | jq -sc --arg cut "$day_cut" '[ .[] | select(.day >= $cut) ]' \
  > "$costs_file" 2>/dev/null
jq -e 'type == "array"' "$costs_file" >/dev/null 2>&1 || printf '[]' > "$costs_file"

today="$(date -u +%Y%m%d)"
# `recent_costs` backs the "today (local)" and "last 24h" readings of the
# spend-today card (#186): both need each row's own instant, not just its GMT
# day, and which instants count as "today" depends on the *reader's* zone, so
# the Publisher can't resolve that server-side. Three days back is generous
# padding either side of any real interpretation — the widest timezone offset
# is +14 (Kiribati), so "today" there can start 14h before UTC midnight, and
# "last 24h" only ever reaches 24h back — while staying a rounding error next
# to the 60-day `by_day` window it rides alongside.
recent_cut="$(date -u -d "-3 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "1970-01-01T00:00:00Z")"
# `cost_rows[]`'s join (issue #593, D21): which work item the money bought,
# derived from the same fleet-wide event union `$events_file` already holds
# (`$ev` below) rather than from `$cycles_file` — `$cycles_file` is capped at
# MAX_CYCLES (40) so a fleet running several cycles an hour loses the join for
# all but the newest few hours, while the event union is bounded only by
# `log_retained_bytes`, the same window the cost scan itself already outlives
# (COST_SCAN_DAYS reaches 60 days back; the log rotates far sooner). Grouping
# the union by `.cycle` and re-deriving `repo`/`item`/`source`/`outcome` here
# is deliberately the same expression `cycle_obj` (above) uses for its own
# per-cycle rendering — one cycle's facts must read the same on both surfaces
# — except `title` is dropped: no reader of `cost_rows` needs it, and carrying
# it here would just be one more field to keep in lock-step for nothing.
cycle_index_file="$work_tmp/cycle-index.json"
jq -c --slurpfile ev "$events_file" -n '
  ($ev[0] // [] | map(select((.cycle // "") != ""))) as $events
  | ($events | group_by(.cycle) | map(
      (.[0].cycle) as $cid
      | (sort_by(.ts)) as $se
      | ($se | map(.event)) as $types
      | { ($cid): {
            repo:   ([ $se[] | select(.repo)  | .repo ] | last),
            item:   ([ $se[] | select(.item)  | .item ] | last),
            source: ([ $se[] | select(.event=="selection") | .source ] | last),
            outcome: (
              if   ($types | any(. == "pr-ready"))       then "pr-ready"
              elif ($types | any(. == "pr-raised"))      then "pr-raised"
              elif ($types | any(. == "attempt-failed")) then "failed"
              elif ($types | any(. == "none-selected"))  then "none-selected"
              elif ($types | any(. == "stand-down"))     then "stand-down"
              elif ($types | any(. == "cycle-skipped"))  then "skipped"
              elif ($types | any(. == "selection"))      then "selected"
              else "ended" end
            )
          }
        }
    ) | add // {})' > "$cycle_index_file" 2>/dev/null
jq -e 'type == "object"' "$cycle_index_file" >/dev/null 2>&1 || printf '{}' > "$cycle_index_file"
counts_json="$(jq -n --slurpfile cyc "$cycles_file" --slurpfile costs_in "$costs_file" \
  --slurpfile cycle_index_in "$cycle_index_file" \
  --arg today "$today" --arg recent_cut "$recent_cut" '
  ($cyc[0]) as $cycles
  | ($costs_in[0]) as $costs
  | ($cycle_index_in[0]) as $cycle_index
  | {
    cycles_shown: ($cycles | length),
    failures_shown: ($cycles | map(select(.outcome=="failed")) | length),
    prs_reached_ready: ($cycles | map(select(.outcome=="pr-ready")) | length),
    spend_total_usd: ($costs | map(.cost) | add // 0),
    spend_today_usd: ($costs | map(select(.day==$today) | .cost) | add // 0),
    by_day:   ($costs | group_by(.day)   | map({day: .[0].day, usd: (map(.cost)|add), n: length}) | sort_by(.day)),
    # Grouped over the flattened (transcript × model) rows, not `$costs`
    # itself, so `.usd` sums each model own `costUSD` (issue #536) rather than
    # crediting a transcript-wide total to whichever model sorted first. `.n`
    # therefore counts transcripts that touched this model, not transcripts
    # attributed to it — a transcript with two models now contributes to both
    # counts, deliberately, since it spent on both. `by_day`/`by_actor` above
    # and below still group `$costs` itself, one row per transcript, so
    # neither is inflated by this per-model split.
    by_model: ([$costs[] | .models[]]
                      | group_by(.model) | map({model: .[0].model, usd: (map(.usd)|add), n: length})
                      | map(select(.model != "unknown" or .usd > 0)) | sort_by(-.usd)),
    by_actor: ($costs | group_by(.actor) | map({actor: .[0].actor, usd: (map(.cost)|add), n: length})
                      | sort_by(-.usd)),
    recent_costs: ($costs | map(select(.ts != null and .ts >= $recent_cut)) | map({ts, cost})),
    # (No apostrophes below: this whole block is a single-quoted shell
    # string, so one would end it and hand the rest of the jq to the shell.)
    #
    # `attributed` is true only for a coordinator/implementer/reviewer row
    # whose cycle actually has events in `$cycle_index` — an Enabler/Refiner/
    # limit-probe row (which shares its cycle directory, and so its `cycle`
    # id, with whichever coordinator/implementer/reviewer cycle triggered it
    # from the exit trap) never attributes, because that cycle owns the item
    # some other stage of the same cycle worked, not the one the
    # Enabler/Refiner/probe itself examined; a `project-reviewer` row (from
    # `reviews/`, never `cycles/`) never has a cycle in this index at all. A
    # coordinator/implementer/reviewer row whose own cycle has rotated out of
    # the log union attributes false too, rather than guessing — carrying
    # nulls, exactly like a row that was never attributable.
    cost_rows: ([$costs[] | . as $c | $c.models[] | . as $m
        | ($cycle_index[$c.cycle]) as $facts
        | (($c.actor == "coordinator" or $c.actor == "implementer" or $c.actor == "reviewer")
           and $facts != null) as $attributed
        | {day: $c.day, model: $m.model, actor: $c.actor, usd: $m.usd, cycle: $c.cycle,
           repo:      (if $attributed then $facts.repo else null end),
           item:      (if $attributed then $facts.item else null end),
           source:    (if $attributed then $facts.source else null end),
           outcome:   (if $attributed then $facts.outcome else null end),
           attributed: $attributed}])
  }')"

# --- Co-Ordinator verdict quality (requirement 3w, issue #319) ----------------
# How often the Script rejects a Co-Ordinator verdict, by UTC day and by the
# model that produced it. Requirement 3t made a confabulated verdict
# *detectable* and requirement 3v made it *recoverable* — a retry, then a
# mechanical fallback pick — but both act one cycle at a time, and the
# question the detection exists to serve is a rate: does it justify changing
# `coordinator_model`? A rate needs both terms, and only the rejections were
# ever counted.
#
# The unit is the **verdict**, not the cycle, because requirement 3v made a
# cycle able to produce two: the first engagement and its one retry are two
# separate answers from the model, each corroborated against the same eligible
# set on its own. `corroboration` events (3v) are therefore the primary
# record — one per verdict, carrying the Script's own `eligible_total`, the
# outcome, and (3w) the model. A cycle that logged none, which is every cycle
# from before 3v shipped and every cycle whose band was genuinely empty, falls
# back to its `none-selected` events instead; the two are never mixed for one
# cycle, or a rejection that reached the fallback path would be counted twice
# — 3v writes both a rejected `corroboration` and a `td_verdict_rejected`
# `none-selected` when no fallback candidate exists.
#
# `accepted-by-selection` counts in the denominator like any other verdict:
# it is the retry getting it right, and leaving it out would credit a recovery
# to nobody and flatter every model that recovers that way.
#
# The window is the retained union log and nothing more — `log.jsonl` is
# rotated at `log_retained_bytes` and `fleet_logs` reads only the live
# generation, so a figure here is "over the log we still have", which is why
# `window_from`/`window_to` ship alongside the counts rather than leaving the
# page to imply a window it cannot see. Persisting counters across publishes
# was the alternative; it would have to survive four nodes publishing the same
# union independently, and a double-counted rejection is a worse answer than
# an honestly bounded one.
#
# Attribution comes from the event itself (`coordinator_model`, requirement
# 3w), falling back to the model that cycle recorded on its coordinator
# `stage-end` — which is the same invocation id, so the two never disagree —
# so the card populates from history already in the log rather than only from
# cycles run after this ships. `selection` carries a `model` of its own; it is
# the *Implementer* model chosen for the item, and reading it here would
# attribute a Co-Ordinator verdict to whichever model was about to do the
# work, so this reads the cycle map and never that field.
#
# The events arrive as a file, and the aggregate leaves as one (requirement
# 4g) — neither is large today, and neither is bounded by anything that would
# keep it that way.
coord_verdicts_file="$work_tmp/coord-verdicts.json"
jq -c --arg cut "$day_cut" '
  . as $ev
  # cycle -> the model its Co-Ordinator stage ran under. Both attempts of a
  # cycle run under the same id, so one entry per cycle is enough.
  | ($ev
     | map(select(.event == "stage-end" and .stage == "coordinator" and ((.cycle // "") != "")))
     | reduce .[] as $s ({}; .[$s.cycle] = ($s.model // null))) as $cyc_model
  # The cycles whose verdicts are on the record as `corroboration` events. A
  # `none-selected` from one of these is the same verdict said twice, so it is
  # read for the cycle outcome and never again as a verdict.
  # A map, not a list: the membership test below sits inside a `select`, where
  # `$list | index(.cycle)` would evaluate `.cycle` against the list rather
  # than against the event, and abort the whole program on the first cycle
  # that has one.
  | ($ev | map(select(.event == "corroboration") | .cycle // "")
         | reduce .[] as $c ({}; .[$c] = true)) as $corr_cycles
  | def day_of: ((.ts // "" | tostring)
                 | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")
                   then (.[0:4] + .[5:7] + .[8:10]) else null end);
    def model_of: (.coordinator_model // $cyc_model[(.cycle // "")] // "unknown");
    def zero: {runs: 0, retries: 0, selections: 0, fallbacks: 0,
               none_selected: 0, corroborated: 0, rejected: 0};
    def cell: {day: day_of, model: model_of} + zero;
    def rate: (if .corroborated > 0 then (.rejected / .corroborated) else null end);
    def total($k): (map(.[$k]) | add // 0);

    # Engagements: both attempts of a cycle are runs, the second is also a
    # retry.
    [ $ev[] | select(.event == "stage-end" and .stage == "coordinator")
            | cell + {runs: 1, retries: (if .retry == true then 1 else 0 end)} ]
    # Outcomes: what the cycle did, as distinct from what its verdicts were.
  + [ $ev[] | select(.event == "selection")
            | cell + {selections: 1,
                      fallbacks: (if .selected_by == "script-fallback" then 1 else 0 end)} ]
  + [ $ev[] | select(.event == "none-selected") | cell + {none_selected: 1} ]
    # Verdicts, from the corroboration record where there is one…
  + [ $ev[] | select(.event == "corroboration")
            | cell + {corroborated: (if ((.eligible_total // 0) > 0)
                                        or (.verdict == "rejected")
                                        or (.verdict == "accepted-by-selection")
                                     then 1 else 0 end),
                      rejected: (if .verdict == "rejected" then 1 else 0 end)} ]
    # …and from the verdict event itself where there is not. A rejection is by
    # construction over a non-empty eligible set (requirement 3t corroborates
    # nothing else), so it counts in both terms even on an event too old to
    # carry the total.
  + [ $ev[] | select(.event == "none-selected"
                     and (($corr_cycles[(.cycle // "")] // false) | not))
            | cell + {corroborated: (if ((.eligible_total // 0) > 0)
                                        or (.td_verdict_rejected == true)
                                     then 1 else 0 end),
                      rejected: (if .td_verdict_rejected == true then 1 else 0 end)} ]
  | map(select(.day != null and .day >= $cut))
  | group_by([.day, .model])
  | map({day: .[0].day, model: .[0].model,
         runs:          total("runs"),
         retries:       total("retries"),
         selections:    total("selections"),
         fallbacks:     total("fallbacks"),
         none_selected: total("none_selected"),
         corroborated:  total("corroborated"),
         rejected:      total("rejected")}
        | . + {rate: rate})
  | sort_by([.day, .model])
  | . as $by_day
  | ($by_day | group_by(.model)
     | map({model: .[0].model,
            runs:          total("runs"),
            retries:       total("retries"),
            selections:    total("selections"),
            fallbacks:     total("fallbacks"),
            none_selected: total("none_selected"),
            corroborated:  total("corroborated"),
            rejected:      total("rejected")}
           | . + {rate: rate})
     | sort_by([- .rejected, .model])) as $by_model
  # Requirement 3x per-band tally (issue #322), rolled up rather than
  # rendered per verdict: counts, not a rate — a verdict rejected over
  # `issues` was not "a verdict about issues", it was a verdict about
  # everything the Script handed over that cycle, so there is no sound
  # per-band denominator to divide by (the single rate above stays the only
  # one). `rejected` is how many rejected verdicts named this band at all;
  # `unaccounted` is the item count behind that, summed across those
  # verdicts — the two answer "which band" and "how much", respectively.
  # Same source selection as `rejected` above (corroboration first, the
  # fallback `none-selected` only where no corroboration event exists for
  # that cycle), restricted to the same day window, and the same
  # sibling-`warning` fallback `last_rejection` already uses for a record
  # logged before the field it needs existed. A rejection with no `bands`
  # at all — every event from before #322 — lands in an explicit `unknown`
  # bucket rather than vanishing or being guessed into a real band; its
  # `unaccounted` is that same events own `unaccounted_total` where it
  # carries one (a `corroboration` always does), else the count of the
  # sibling `warning` events `unaccounted` refs — a pre-3v `none-selected`
  # carries no figure at all, and only the warning of its cycle holds it.
  | ([ $ev[] | select(.event == "corroboration" and .verdict == "rejected")
             | select(day_of != null and day_of >= $cut) ]
     + [ $ev[] | select(.event == "none-selected" and .td_verdict_rejected == true
                        and (($corr_cycles[(.cycle // "")] // false) | not))
               | select(day_of != null and day_of >= $cut) ]
     | map(
         . as $r
         | ([ $ev[] | select(.event == "warning" and (.cycle // "") == ($r.cycle // "")
                             and ((.unaccounted | type) == "array")) ]
            | max_by(.ts // "")) as $w
         | ($r.bands // ($w // {}).bands // null) as $b
         | if $b == null
           then [{band: "unknown", rejected: 1,
                  unaccounted: ($r.unaccounted_total // ((($w // {}).unaccounted // []) | length))}]
           else ($b | to_entries | map({band: .key, rejected: 1, unaccounted: .value}))
           end)
     | flatten
     | group_by(.band)
     | map({band: .[0].band,
            rejected:    (map(.rejected)    | add),
            unaccounted: (map(.unaccounted) | add)})
     | sort_by([- .rejected, .band])) as $by_band
  # The newest rejection, whichever record carries it, with what became of the
  # cycle that produced it — a rate with no instance is not actionable, and an
  # instance that does not say whether the fleet recovered is half the story
  # requirement 3v now has to tell. The refs are capped because 33 of them is a
  # real, observed case and data.js is a byte budget; the full count rides
  # alongside so the cap is visible rather than silent.
  | ([ $ev[] | select(.event == "corroboration" and .verdict == "rejected") ]
     | max_by(.ts // "")) as $rc
  | ([ $ev[] | select(.event == "none-selected" and .td_verdict_rejected == true
                      and (($corr_cycles[(.cycle // "")] // false) | not)) ]
     | max_by(.ts // "")) as $rn
  | (if   $rc == null then $rn
     elif $rn == null then $rc
     elif ($rn.ts // "") > ($rc.ts // "") then $rn
     else $rc end) as $rej
  | ($rej
     | if . == null then null
       else . as $r
       # The sibling `warning` of the same verdict, for a rejection recorded
       # before `corroboration` events carried the detail themselves.
       | ([ $ev[] | select(.event == "warning" and (.cycle // "") == ($r.cycle // "")
                           and ((.unaccounted | type) == "array")) ]
          | max_by(.ts // "")) as $w
       | (($r.unaccounted // ($w // {}).unaccounted // [])) as $un
       | ([ $ev[] | select((.cycle // "") == ($r.cycle // "") and (.ts // "") > ($r.ts // "")) ]) as $after
       | {ts: ($r.ts // null), node: ($r.node // null), cycle: ($r.cycle // null),
          attempt: ($r.attempt // null),
          model: ($r.coordinator_model // $cyc_model[($r.cycle // "")] // "unknown"),
          reason: ($r.reason // ""),
          detail: (($w // {}).detail // ""),
          eligible_total: ($r.eligible_total // ($w // {}).eligible_total // null),
          unaccounted_total: ($r.unaccounted_total // ($un | length)),
          unaccounted: ($un | map({repo: (.repo // ""), item: (.item // ""),
                                   source: (.source // "")}) | .[0:20]),
          bands: ($r.bands // ($w // {}).bands // null),
          outcome: (if   ($after | any(.event == "selection" and .selected_by == "script-fallback"))
                         then "recovered-by-fallback"
                    elif ($after | any(.event == "selection")) then "recovered-by-retry"
                    elif ($after | any(.event == "corroboration" and .verdict == "accepted"))
                         then "accepted-on-retry"
                    else "stood-down" end)}
       end) as $last
  | ([ $ev[] | .ts // empty ]) as $tss
  | {window_from: ($tss | min), window_to: ($tss | max)}
    + ($by_day
       | {runs:          total("runs"),
          retries:       total("retries"),
          selections:    total("selections"),
          fallbacks:     total("fallbacks"),
          none_selected: total("none_selected"),
          corroborated:  total("corroborated"),
          rejected:      total("rejected")})
  | . + {rate: rate, by_day: $by_day, by_model: $by_model, by_band: $by_band, last_rejection: $last}
' "$events_file" > "$coord_verdicts_file" 2>/dev/null
if ! jq -e 'type == "object"' "$coord_verdicts_file" >/dev/null 2>&1; then
  printf '%s' '{"window_from":null,"window_to":null,"runs":0,"retries":0,"selections":0,"fallbacks":0,"none_selected":0,"corroborated":0,"rejected":0,"rate":null,"by_day":[],"by_model":[],"by_band":[],"last_rejection":null}' \
    > "$coord_verdicts_file"
fi
# Merged into `counts` rather than shipped as a key of its own: it is a
# roll-up over the same window as everything else there, and the page reads
# one object for its metric cards.
counts_merged="$(jq -c --slurpfile v "$coord_verdicts_file" \
  '. + {coordinator_verdicts: $v[0]}' <<<"$counts_json" 2>/dev/null)"
[[ -n "$counts_merged" ]] && counts_json="$counts_merged"

# --- Implementer/Reviewer model selection (issue #529) -----------------------
# Which model each of these two stages was *asked* to run, as a ratio — the
# dashboard's two "model used" pies. The unit is the stage-end event, not the
# cycle: a cycle logs at most one Implementer and one Reviewer stage-end, so
# double-counting is not a risk here the way it is for the Co-Ordinator block
# above (which can see two verdicts from one cycle's retry).
#
# `.model` is `lib/metering.sh`'s own field — the id passed to the `claude`
# invocation, not read back out of the transcript envelope — deliberately not
# `counts.cost_rows[]`/`modelUsage`: those are spend attribution, and a single
# Implementer stage running on Sonnet still emits Haiku `modelUsage` rows for
# the subagents its own invocation spawns, so a ratio built from them would
# report Haiku for most Implementer runs, which is the #536 failure this issue
# was explicitly asked not to repeat. Every stage-end for these two stages
# counts once, including a failed run (`exit_code != 0`) or a retry: the
# question is which model was dispatched, and a failed run still consumed
# one. A stage-end with no readable model falls back to `unknown`, exactly as
# `by_model` above does, rather than being dropped.
#
# Shaped like `coordinator_verdicts` just above: `by_stage` is the whole
# retained window's totals for the client's "Lifetime" default, `rows` is
# per-day so the page can re-aggregate over whatever narrower window its
# shared time-frame selector picks, and `window_from`/`window_to` are the span
# of the *whole* retained log (not just these two stages' own events) — the
# same "figure here is 'over the log we still have'" reasoning
# `coordinator_verdicts` already documents, since `log.jsonl` is rotated at
# `log_retained_bytes` independently of `COST_SCAN_DAYS`, so these pies can
# span less history than the cost charts beside them.
stage_models_file="$work_tmp/stage-models.json"
jq -c --arg cut "$day_cut" '
  . as $ev
  | def day_of: ((.ts // "" | tostring)
                 | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}")
                   then (.[0:4] + .[5:7] + .[8:10]) else null end);
    ([ $ev[] | select(.event == "stage-end" and (.stage == "implementer" or .stage == "reviewer"))
             | {day: day_of, stage: .stage, model: (.model // "unknown")} ]
     | map(select(.day != null and .day >= $cut))) as $recs
  | ($recs | group_by([.stage, .model])
           | map({stage: .[0].stage, model: .[0].model, n: length})
           | sort_by([.stage, - .n, .model])) as $by_stage
  | ($recs | group_by([.day, .stage, .model])
           | map({day: .[0].day, stage: .[0].stage, model: .[0].model, n: length})
           | sort_by([.day, .stage, .model])) as $rows
  | ([ $ev[] | .ts // empty ]) as $tss
  | {window_from: ($tss | min), window_to: ($tss | max), by_stage: $by_stage, rows: $rows}
' "$events_file" > "$stage_models_file" 2>/dev/null
if ! jq -e 'type == "object"' "$stage_models_file" >/dev/null 2>&1; then
  printf '%s' '{"window_from":null,"window_to":null,"by_stage":[],"rows":[]}' \
    > "$stage_models_file"
fi
counts_merged="$(jq -c --slurpfile v "$stage_models_file" \
  '. + {stage_models: $v[0]}' <<<"$counts_json" 2>/dev/null)"
[[ -n "$counts_merged" ]] && counts_json="$counts_merged"

# --- Blocked and void items (requirements 34, 34c, 34h) ----------------------
# Both rules live in lib/cycle-state.sh, shared with agent-cycle.sh, so what the
# dashboard calls blocked or void is by construction what the Co-Ordinator is
# told. Only the projection for display is local. They are shown apart because
# they mean opposite things to a human deciding whether to intervene: a blocked
# item is waiting on something, a void item is finished with.
#
# Which is why the blocked list is `open_blocked_items` and not `blocked_items`:
# an item can carry both marks, and one that does is void (requirement 34h).
# Every `void` verdict the Enabler reaches leaves the block that preceded it
# standing — `item-void` clears nothing — so listing the raw blocked set here
# put items in *both* tables, in the one panel whose whole purpose is to keep
# the two apart, and left them there for as long as the log remembered them.
blocked_json="$(printf '%s\n' "$ALL_EVENTS" | open_blocked_items - | jq -c \
  'map({repo: (.repo // ""), item: .item, ts: .ts, detail: (.detail // ""), stage: (.stage // ""), kind: (.kind // "")})' 2>/dev/null)"
[[ -z "$blocked_json" ]] && blocked_json='[]'

# What the Enabler has made of each blocked item (implementation spec 35, 36a),
# joined onto the row rather than listed apart. An escalated item is still a
# blocked item — what changes is *who* it is waiting for, and that is the one
# thing about a blocked row an operator most needs at a glance: their own name on
# an open issue, or the pipeline's last verdict if it is still the pipeline's
# move. Only marks newer than the block count, so a re-blocked item does not
# inherit the resolved escalation of an older one.
#
# The rows arrive on stdin ahead of the events, never as an `--argjson`
# (requirement 4g): the blocked extract grows with the fleet's history, and this
# guard would swallow an `execve` past MAX_ARG_STRLEN as an empty enrichment —
# every escalation and Enabler verdict silently dropped from a panel that still
# rendered. `input` takes the rows, `inputs` the event stream behind them; the
# order is the order the here-string prints them in.
# shellcheck disable=SC2016  # jq's $rows/$events/$r/$esc/$exam, not the shell's.
blocked_json="$(jq -nc '
  input as $rows
  | [ inputs ] as $events
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
  <<<"$blocked_json"$'\n'"$ALL_EVENTS" 2>/dev/null || true)"
[[ -z "$blocked_json" ]] && blocked_json='[]'

void_json="$(printf '%s\n' "$ALL_EVENTS" | void_items - | jq -c \
  'map({repo: (.repo // ""), item: .item, ts: .ts, detail: (.detail // ""), stage: (.stage // ""), evidence: (.evidence // "")})' 2>/dev/null)"
[[ -z "$void_json" ]] && void_json='[]'

# --- Log tail ----------------------------------------------------------------
# `review-gate-checks-read` (requirement 31c, TD-PPagop-26081404) is machine
# bookkeeping — one `{ok}` event per ready-gate evaluation, existing only for
# `review_gate_unknown_streak_verdict` to read — with nothing to show an
# operator, so a run of them would displace rows that have something to say.
# The escalation it feeds, `review-gate-checks-degraded`, is operator-facing
# and stays. `first-seen` (requirement 33, TD-PPagop-26081405) gets the same
# treatment for the same reason: one per item a gather first reports, read
# only by scripts/pickup-metrics.sh, with nothing an operator can act on.
log_tail_json="$(printf '%s\n' "$ALL_EVENTS" | jq -sc --argjson n "$MAX_LOG_TAIL" '
  map(select(.event != "review-gate-checks-read" and .event != "first-seen"))
  | sort_by(.ts) | reverse | .[0:$n]' 2>/dev/null)"
[[ -z "$log_tail_json" ]] && log_tail_json='[]'

# --- cron.log tail -----------------------------------------------------------
# scripts/rotate-logs.sh (TD26072501) renames cron.log to cron.log.1 once it
# grows past log_retained_bytes, leaving the live file to start over empty —
# reading the previous generation too means the panel never goes blank the
# moment that happens.
cron_tail_json='[]'
if [[ -f "$cron_log" ]]; then
  cron_tail_json="$( { [[ -f "$cron_log.1" ]] && cat -- "$cron_log.1"; cat -- "$cron_log"; } 2>/dev/null \
    | tail -n 40 | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo '[]')"
fi

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
        | ((reduce ($c[] | select((.event == "stage-start" or .event == "stage-end") and .stage))
              as $x ({}; .[$x.stage] = {event: $x.event, ts: $x.ts, backstop: $x.backstop_min}))
           | to_entries | map(select(.value.event == "stage-start")) | last) as $live_stage
        | { cycle: $cid,
            since: $start.ts,
            running: ($done == null),
            ended_at: ($done.ts // null),
            stage: ($live_stage.key // null),
            # As in `status.current` above, and load-bearing for a peer in a way
            # it is not for us: no lock reaches us from another node, so this is
            # the only clock its card has for the stage it is showing.
            # (No apostrophes in here — see the note in that program.)
            stage_since: ($live_stage.value.ts // null),
            # The cap that stage was given, as in `status.current` above.
            stage_backstop_min: ($live_stage.value.backstop // null),
            repo:   ([ $c[] | select(.event == "selection") | .repo ]   | last),
            item:   ([ $c[] | select(.event == "selection") | .item ]   | last),
            source: ([ $c[] | select(.event == "selection") | .source ] | last),
            title:  ([ $c[] | select(.event == "selection") | .title ]  | last),
            race_losses: (([ $c[] | select(.event == "selection") | .race_losses ] | last) // 0) }
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
      stage_since: ($st.current.stage_since // null),
      # The cap this stage was given, carried through from `status.current`
      # so our own row is judged on exactly what a peer row would be.
      stage_backstop_min: ($st.current.stage_backstop_min // null),
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
self_version_json="$(agent_ops_version "$SCRIPT_DIR")"
jq -nc --arg n "$self_node" --arg r "$(role_current)" --arg ts "$now_iso" --arg lc "$last_local_cycle" \
  --argjson live "$self_live_json" \
  --argjson version "$self_version_json" \
  --argjson compose "$(compose_drift_status)" \
  --argjson image "$(image_drift_status "$self_version_json" "$image_cache")" \
  --argjson switch "$switch_json" \
  '{node: $n, role: $r, heartbeat_ts: $ts, heartbeat_age_s: 0,
    last_cycle: (if $lc == "" then null else $lc end), self: true, stale: false,
    live: $live, version: $version, compose: $compose, image: $image, switch: $switch}' > "$nodes_rows"
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
       version: ($h.version // null),
       # Same rule for the compose-drift verdict (lib/compose-drift.sh): only
       # the node itself can read the compose.yaml on its own host, so a
       # heartbeat carrying no verdict yields null, never a local answer.
       compose: ($h.compose // null),
       # And for the image-drift verdict (lib/image-drift.sh): only the
       # peer itself can query the registry on its own behalf, so an absent
       # field (a peer on an image built before this check existed) yields
       # null rather than this node answering in its place.
       image: ($h.image // null),
       # And for the node-scoped switch (issue #379): the peer does
       # replicate its own `disabled.json`, but only the peer evaluated it —
       # against its own clock, through the one implementation `--status`
       # also reads (requirement 34a). So an absent field (a peer on a
       # heartbeat built before this check existed) yields null rather than
       # this node re-deriving a verdict — silently — in its place.
       switch: ($h.switch // null)}' \
    "$hb" 2>/dev/null >> "$nodes_rows" || true
done
fleet_nodes_json="$(jq -sc 'sort_by([(.self | not), .node])' "$nodes_rows" 2>/dev/null)"
[[ -z "$fleet_nodes_json" ]] && fleet_nodes_json='[]'

# The fleet flags, from the local cache lib/toggle.sh keeps (the GitHub tick
# below refreshes it; requirement 2.3a). Read as files so a --no-github tick
# costs no API call and a standby node still shows them.
#
# The merge-autonomy kill switch (D18 issue #576) is a fourth flag in the
# same cache, but it cannot be read the same bare way: `disabled`/`limit`
# fail open on an unreadable record (lib/toggle.sh's own header), so a raw
# `null` reads correctly as "not set" either way. The kill switch fails
# *closed* (lib/merge-autonomy.sh) — `merge_autonomy_kill_state` is the only
# reader that already draws that distinction, so this local-only value runs
# the raw cache through the *pure* half of that same function
# (`_toggle_eval`, no network) rather than reimplementing its record shape.
# It never calls `merge_autonomy_kill_state` itself here: that function
# always attempts a live fetch the first time this process asks it
# (`fleet_flag_fetch_status`'s own memo is empty on a cache miss), which a
# --no-github tick must not do — see the WITH_GITHUB block below for the
# live read this falls back from. No cached copy at all reads as "enabled"
# here, deliberately: this is a display default for "nothing confirms a
# kill", not the live gate's own fail-closed reasoning, which only applies
# once a fetch has actually been attempted and found the repo unreachable.
ma_kill_cache="$(fleet_cache_file "$state_dir" "$MERGE_AUTONOMY_KILL_FLAG")"
if [[ -s "$ma_kill_cache" ]]; then
  ma_kill_json="$(_toggle_eval "$(cat "$ma_kill_cache")" present 2>/dev/null)"
else
  ma_kill_json='{"state":"enabled"}'
fi
[[ -n "$ma_kill_json" ]] || ma_kill_json='{"state":"enabled"}'

fleet_flags_json="$(jq -nc \
  --argjson d "$(jq -c '.' "$(fleet_cache_file "$state_dir" disabled)" 2>/dev/null || echo null)" \
  --argjson l "$(jq -c '.' "$(fleet_cache_file "$state_dir" limit)" 2>/dev/null || echo null)" \
  --argjson mak "$ma_kill_json" \
  '{disabled: $d, limit: $l, merge_autonomy_kill: $mak}' 2>/dev/null)"
[[ -z "$fleet_flags_json" ]] && fleet_flags_json='{"disabled":null,"limit":null,"merge_autonomy_kill":{"state":"enabled"}}'

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
# How many unread tech-debt items a repo's register may cost in one tick, on
# exactly the reasoning above: the fleet's registers hold well over a hundred
# items between them and a cold cache cannot read them all in one publish, so
# it fills a few a tick and is warm within the hour. Nothing waits on it — an
# unread item renders as the bare ID it always was. Per repo rather than per
# tick, so that every register fills at once: a budget shared across the fleet
# is spent entirely on the first repo in the config, and the last one stays
# bare for as long as the first one took to warm. What that costs is a ceiling
# that grows with the repo count, which is why it is this small.
TD_META_MISS_BUDGET=4
# How long an item's metadata survives after the last register that named it.
# Item files are append-only, so this bounds the cache rather than trimming it:
# what it collects is the superseded SHA left behind by every status flip.
TD_CACHE_TTL=2592000   # 30 days

prs_json='[]'; inputs_json='{}'; gh_ok=false; gh_err=""
# Every source's failure this tick (TD-PPagop-26080201): each entry is one
# source, one repo. `gh_err` — the single string the "GitHub unavailable"
# banner reads — is their join, so the banner names every source that failed,
# not only the first (historically `pr list`, the only one that raised it).
gh_fail_msgs=()
pr_rows="$work_tmp/pr.rows"; : > "$pr_rows"
# This tick's tech-debt reads, and every item SHA the registers still name.
td_new="$work_tmp/td.new";   : > "$td_new"
td_seen="$work_tmp/td.seen"; : > "$td_seen"
td_cache_json="$work_tmp/td-cache.json"
if [[ -s "$td_cache" ]] && jq -e 'type == "object"' "$td_cache" >/dev/null 2>&1; then
  cp "$td_cache" "$td_cache_json"
else
  printf '{}' > "$td_cache_json"
fi
if (( WITH_GITHUB )); then
  gh_ok=true
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    prs="$(gh_call pr list -R "$slug" --state open --label "$pr_label" \
             --json "$PR_INDEX_FIELDS",mergeable,mergeStateStatus,headRefName,statusCheckRollup)"
    pr_rc=$?
    if (( pr_rc != 0 )); then
      gh_ok=false
      gh_fail_msgs+=("pr list failed for $slug: $(gh_call_err)")
      prs='[]'
    fi
    # $prs_json is the running fleet-wide accumulator and $prs is one repo's
    # whole open-PR-with-label page, both unbounded past this call (requirement
    # 4g, TD-PPagop-26081506). Both arrive on stdin, one document per line,
    # bound positionally with `input as $name` in the printed order — never in
    # argv.
    prs_json="$(jq -nc --arg slug "$slug" "$PR_JQ"'
      input as $cur | input as $add |
      $cur + ($add | map({
        repo: $slug, number, title, url, isDraft, state, mergeable, mergeStateStatus, headRefName, createdAt,
        review_decision: (.reviewDecision // ""),
        checks: (.statusCheckRollup | checks_of)
      }))' <<<"$prs_json"$'\n'"$prs")"
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
    issues_raw="$(gh_call api "repos/$slug/issues?state=open&per_page=30")"
    issues_rc=$?
    if (( issues_rc != 0 )); then
      state_issues="failed"; issues='[]'
      gh_ok=false; gh_fail_msgs+=("issues listing failed for $slug: $(gh_call_err)")
    else
      state_issues="answered"
      issues="$(jq -c \
        '[.[] | select(has("pull_request") | not)
              | {number, title, url: .html_url,
                 labels: [.labels[] | {name}], assignees: [.assignees[] | {login}],
                 priority: (([.issue_field_values[]?
                              | select(.issue_field_name == "Priority")
                              | .single_select_option.name
                              | select(. == "Urgent" or . == "High"
                                       or . == "Medium" or . == "Low")] | first) // "Medium")}]' \
        <<<"$issues_raw" 2>/dev/null)"
      issues="${issues:-[]}"
    fi

    runs="$(gh_call run list -R "$slug" --branch "$db" --limit 40 --json workflowName,conclusion,status,event,createdAt,url)"
    runs_rc=$?
    if (( runs_rc != 0 )); then
      state_runs="failed"; failed_runs='[]'
      gh_ok=false; gh_fail_msgs+=("run list failed for $slug: $(gh_call_err)")
    else
      state_runs="answered"
      failed_runs="$(jq -c '
        [ .[] | select(.event == "push" or .event == "schedule" or .event == "dynamic") ]
        | group_by(.workflowName) | map(sort_by(.createdAt) | last)
        | map(select(.conclusion == "failure"))' <<<"$runs" 2>/dev/null)"
      failed_runs="${failed_runs:-[]}"
    fi

    # The per-item register. One listing read gives the roster, and free with
    # each filename comes the item's blob SHA — which is what makes the title
    # and status behind it affordable: the metadata cache is keyed by that SHA,
    # so a register whose items are not moving costs exactly the one call it
    # always did. An ID on its own names no work; and three-quarters of a
    # mature register is resolved items the Co-Ordinator will never pick up, so
    # those are dropped here rather than shown as work sources. Items whose
    # metadata has not been read yet are kept — they are not yet known *not* to
    # be work — and render as the bare ID until the cache reaches them.
    # A repo with no register just 404s to an empty roster — legitimate, and
    # distinguished from a real failure the same way gather-register-hygiene.sh
    # tells the two apart: gh still prints the API's own JSON error body (with
    # its own `.status`) on a non-2xx response, so a genuine 404 and a rate
    # limit or outage are told apart from the body, not guessed from an empty
    # string either could equally produce.
    td_rows="$work_tmp/td.rows"; : > "$td_rows"
    td_raw="$(gh_call api "repos/$slug/contents/tech-debt")"
    td_rc=$?
    if (( td_rc == 0 )); then
      state_td="answered"
      jq -r '.[] | select(.type == "file" and (.name | endswith(".md"))) | "\(.sha)\t\(.name)"' \
        <<<"$td_raw" > "$td_rows" 2>/dev/null || true
    elif [[ "$(jq -r '.status // ""' <<<"$td_raw" 2>/dev/null)" == "404" ]]; then
      state_td="answered_404"
    else
      state_td="failed"
      gh_ok=false; gh_fail_msgs+=("tech-debt listing failed for $slug: $(gh_call_err)")
    fi
    cat "$td_rows" >> "$td_seen"
    td_fetched=0
    while IFS= read -r td_sha; do
      (( td_fetched < TD_META_MISS_BUDGET )) || break
      [[ "$td_sha" =~ ^[0-9a-f]{7,40}$ ]] || continue
      # Counted before the call, not after: a register whose blobs will not
      # answer must cost the budget and stop, not walk the whole roster making
      # a failing call for every item in it.
      td_fetched=$(( td_fetched + 1 ))
      # Through a file, so a call that answered nothing stays distinguishable
      # from an item that parsed to nothing. The first has to be tried again
      # next tick; the second is a malformed item — cached as read-and-empty so
      # that it costs one call rather than one every tick for ever.
      gh_json api "repos/$slug/git/blobs/$td_sha" --jq '.content' \
        | tr -d '\n' | base64 -d > "$work_tmp/td.blob" 2>/dev/null
      [[ -s "$work_tmp/td.blob" ]] || continue
      td_meta="$(td_frontmatter < "$work_tmp/td.blob")"
      jq -Rc --arg s "$td_sha" \
        'split("\t") | {sha: $s, title: (.[0] // ""), status: (.[1] // "")}' \
        <<<"$td_meta" >> "$td_new" 2>/dev/null || true
    done < <(jq -Rr --slurpfile c "$td_cache_json" '
      ($c[0] // {}) as $cache
      | split("\t") | select(length == 2) | select($cache[.[0]] == null) | .[0]' \
      "$td_rows" 2>/dev/null)
    td_json="$(jq -n --rawfile rows "$td_rows" --slurpfile cache "$td_cache_json" \
      --slurpfile fresh "$td_new" --arg slug "$slug" --arg db "$db" '
      ($cache[0] // {}) as $c
      | (reduce $fresh[] as $e ({}; .[$e.sha] = $e)) as $n
      | [ $rows | split("\n")[] | select(length > 0) | split("\t") | select(length == 2)
          | { id: (.[1] | sub("\\.md$"; "")), sha: .[0] }
          | ($n[.sha] // $c[.sha] // {}) as $m
          | { id,
              title:  ($m.title // ""),
              status: (($m.status // "") | ascii_downcase),
              url:    "https://github.com/\($slug)/blob/\($db)/tech-debt/\(.id).md" } ]
      | map(select(.status != "resolved" and .status != "not-debt"))
      | sort_by([ (if .status == "in-progress" then 0 elif .status == "open" then 1 else 2 end), .id ])
      | .[0:40]' 2>/dev/null)"
    [[ -n "$td_json" ]] || td_json='[]'

    # Security & code-quality findings, via the same script the pipeline uses,
    # so the dashboard shows the highest-priority work source the Co-Ordinator
    # actually sees. Always valid JSON; a disabled feature or a repo with
    # neither alert type enabled degrades to [] and exit 0 (gather-findings.sh's
    # own contract), but a real failure — a timeout, a rate limit, an outage —
    # now exits non-zero rather than looking exactly like "nothing to report".
    findings="$(timeout "$GH_TIMEOUT" "$SCRIPT_DIR/scripts/gather-findings.sh" "$slug" 2>/dev/null)"
    findings_rc=$?
    if (( findings_rc != 0 )); then
      state_findings="failed"; findings='[]'
      gh_ok=false; gh_fail_msgs+=("findings gathering failed for $slug")
    else
      state_findings="answered"
      findings="$(jq -c 'if type == "array" then . else [] end' <<<"$findings" 2>/dev/null || echo '[]')"
    fi

    inputs_json="$(jq -c --arg slug "$slug" \
      --argjson issues "$issues" --argjson failed "$failed_runs" --argjson td "$td_json" --argjson findings "$findings" \
      --arg s_issues "$state_issues" --arg s_runs "$state_runs" --arg s_td "$state_td" --arg s_findings "$state_findings" '
      . + {($slug): {issues: $issues, failed_runs: $failed, tech_debt: $td, findings: $findings,
                     state: {issues: $s_issues, failed_runs: $s_runs, tech_debt: $s_td, findings: $s_findings}}}' \
      <<<"$inputs_json")"
  done < <(jq -r '.[].slug' <<<"$repos_json")

  # --- Merge-queue awareness (agent-ops#374, #375; D17) ------------------------
  # lib/merge-queue.sh's merge_queue_probe is the one place that knows how to
  # ask GitHub whether a pull request is currently queued — shared with
  # scripts/sweep-human-visibility.sh (requirement 38f) rather than
  # reimplemented here. Only non-draft pull requests are probed: GitHub will
  # not enqueue a draft, so one is never worth the call. The set probed is
  # exactly this tick's open, labelled pull requests — bounded by
  # `max_open_agent_prs` per repo, so unlike the pull-request index or the
  # tech-debt register (forty-odd references, budgeted a few a tick) this
  # never needs a miss budget of its own.
  #
  # "Dequeued" is this Publisher's own memory (`queue_cache`) of whether a
  # pull request has fallen out of the queue since it was last seen queued,
  # not the probe's own timeline read (`dequeued_at`/`dequeue_reason`): that
  # field is the *last* removal event regardless of age or of a later
  # re-queue (agent-ops#394's open follow-up on the same probe), which is the
  # wrong signal for a badge that must both persist until a human deals with
  # it and clear the moment the pull request is queued again. So the warning
  # is a small state machine kept in `queue_cache`, one entry per pull
  # request, `{queued, warn}`: `warn` is set the tick `queued` is observed to
  # flip from true to false, stays set on every later tick that still reads
  # not-queued (a maintainer glancing at the page between heartbeats must
  # still see it, not just the one tick it started on), and clears the
  # moment either `queued` reads true again or the pull request merges or
  # closes — the latter for free, since a pull request no longer `state:
  # open` no longer appears in `prs_json` at all, so its cache entry is
  # simply never re-written (the cache is rebuilt wholesale below, not
  # merged with what came before).
  queue_cache_json="$work_tmp/queue-cache.json"
  if [[ -s "$queue_cache" ]] && jq -e 'type == "object"' "$queue_cache" >/dev/null 2>&1; then
    cp "$queue_cache" "$queue_cache_json"
  else
    printf '{}' > "$queue_cache_json"
  fi
  # Per pull request: ref, this tick's badge answer (queued, dequeued-warn),
  # then what to persist to queue_cache for next tick (cache_queued,
  # cache_warn) — the same pair except on an unreadable probe, where the
  # cache carries the prior answer forward unchanged rather than guessing.
  queue_answers="$work_tmp/queue.answers"; : > "$queue_answers"
  while IFS=$'\t' read -r mq_ref mq_slug mq_number mq_draft; do
    [[ -n "$mq_ref" ]] || continue
    mq_prior="$(jq -r --arg r "$mq_ref" '(.[$r] // {}) |
      [(.queued | if . == null then "unknown" elif . then "true" else "false" end),
       ((.warn // false) | tostring)] | @tsv' "$queue_cache_json" 2>/dev/null)"
    IFS=$'\t' read -r mq_prior_queued mq_prior_warn <<<"$mq_prior"
    mq_prior_queued="${mq_prior_queued:-unknown}"
    mq_prior_warn="${mq_prior_warn:-false}"

    if [[ "$mq_draft" == "true" ]]; then
      # Never queueable, so never worth remembering as queued or warned about.
      printf '%s\tfalse\tfalse\tfalse\tfalse\n' "$mq_ref" >> "$queue_answers"
      continue
    fi

    mq_probe="$(merge_queue_probe "$mq_slug" "$mq_number" 2>/dev/null || true)"
    mq_queued="unknown"
    if [[ -n "$mq_probe" ]]; then
      mq_queued="$(jq -r '.queued | if type == "boolean" then (if . then "true" else "false" end) else "unknown" end' \
        <<<"$mq_probe" 2>/dev/null)"
      [[ -n "$mq_queued" ]] || mq_queued="unknown"
    fi

    if [[ "$mq_queued" == "unknown" ]]; then
      # Never assumed false (lib/merge-queue.sh's own contract): a read that
      # didn't happen carries the last known answer forward unchanged, badge
      # and cache alike, rather than guessing or silently clearing a live
      # warning. This is a best-effort read like every other one in this
      # loop — it does not set gh_ok false, the same treatment
      # sweep-human-visibility.sh gives the identical probe.
      printf '%s\t%s\t%s\t%s\t%s\n' "$mq_ref" "$mq_prior_queued" "$mq_prior_warn" "$mq_prior_queued" "$mq_prior_warn" \
        >> "$queue_answers"
    else
      mq_warn="false"
      if [[ "$mq_queued" != "true" && ( "$mq_prior_warn" == "true" || "$mq_prior_queued" == "true" ) ]]; then
        mq_warn="true"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$mq_ref" "$mq_queued" "$mq_warn" "$mq_queued" "$mq_warn" \
        >> "$queue_answers"
    fi
  done < <(jq -r '.[] | [(.repo + "#" + (.number|tostring)), .repo, (.number|tostring), (.isDraft|tostring)] | @tsv' \
    <<<"$prs_json" 2>/dev/null)

  # $prs_json is the whole cross-repo PR index, unbounded past this call
  # (requirement 4g, TD-PPagop-26081506) — it arrives on stdin, bound with
  # `input as $prs`, rather than as `--argjson`. `$queue_answers` is a
  # filename, not fleet state, so `--rawfile` (a file jq reads itself, not an
  # argv element) is unaffected and keeps reading it exactly as `-Rs` did.
  prs_json="$(jq -nc --rawfile qa "$queue_answers" '
    input as $prs |
    ($qa | split("\n") | map(select(length > 0) | split("\t")) |
     map({(.[0]): {queued: (if .[1] == "unknown" then null else (.[1] == "true") end),
                    dequeued: (.[2] == "true")}}) | add // {}) as $q
    | $prs | map(. + ($q[.repo + "#" + (.number|tostring)] // {queued: null, dequeued: false}))' \
    <<<"$prs_json" 2>/dev/null)"
  [[ -n "$prs_json" ]] || prs_json='[]'

  # Rebuilt wholesale from this tick's own open pull requests (fields 4/5
  # above) — never merged with what came before, so a pull request that has
  # merged or closed since the last tick simply has no entry here and drops
  # out of memory rather than being carried forever.
  jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t"))
    | map({(.[0]): {queued: (.[3] == "true"), warn: (.[4] == "true")}}) | add // {}' \
    "$queue_answers" > "$queue_cache" 2>/dev/null || true

  # Every source that failed this tick, across every repo — not just `pr
  # list`'s — so the "GitHub unavailable" banner names what actually broke.
  if (( ${#gh_fail_msgs[@]} > 0 )); then
    gh_err="$(IFS='; '; echo "${gh_fail_msgs[*]}")"
  fi

  # Fold this tick's item reads into the metadata cache, stamp everything the
  # registers still name as seen, and drop what none of them has named for a
  # month. Stamping — rather than keeping only what was seen this tick — is
  # what makes a failed listing cost nothing: a register that could not be read
  # keeps its items' metadata, instead of paying to read every one of them
  # again, four a tick, once it comes back.
  jq -n --slurpfile cache "$td_cache_json" --slurpfile fresh "$td_new" \
        --rawfile seen "$td_seen" --argjson now "$now_epoch" --argjson ttl "$TD_CACHE_TTL" '
    (($cache[0] // {})
     + (reduce $fresh[] as $e ({};
          .[$e.sha] = {title: $e.title, status: $e.status, seen: $now}))) as $all
    | ([ $seen | split("\n")[] | select(length > 0) | split("\t")[0]
         | {key: ., value: $now} ] | from_entries) as $stamp
    | $all
    | with_entries(.value += {seen: ($stamp[.key] // .value.seen // 0)})
    | with_entries(select(.value.seen + $ttl >= $now))' \
    > "$td_cache.t" 2>/dev/null && mv "$td_cache.t" "$td_cache"

  # Refresh the fleet-flag cache while we are talking to GitHub anyway
  # (requirement 2.3a): the cycles fall back to these cached copies when the
  # state repo is unreachable, and a standby node — which runs no cycles —
  # has no other refresher. The publisher only warms the cache; nothing here
  # acts on the flags. Re-read after the refresh so this very publish shows
  # what was just fetched, not last tick's copy.
  fleet_flag_fetch "$state_repo" "$state_dir" disabled >/dev/null || true
  fleet_flag_fetch "$state_repo" "$state_dir" limit    >/dev/null || true
  # The kill switch's own reader, not fleet_flag_fetch (D18 issue #576): with
  # GitHub actually reachable this tick, `merge_autonomy_kill_state` gives the
  # accurate answer — including the fail-closed distinction the local-only
  # value above cannot make (its own header explains why) — and this is the
  # one place in the whole publisher allowed to call it, since only here is a
  # live fetch (its own first call in this process) an acceptable cost.
  ma_kill_json="$(merge_autonomy_kill_state "$state_repo" "$state_dir" 2>/dev/null)"
  [[ -n "$ma_kill_json" ]] || ma_kill_json='{"state":"enabled"}'
  fleet_flags_json="$(jq -nc \
    --argjson d "$(jq -c '.' "$(fleet_cache_file "$state_dir" disabled)" 2>/dev/null || echo null)" \
    --argjson l "$(jq -c '.' "$(fleet_cache_file "$state_dir" limit)" 2>/dev/null || echo null)" \
    --argjson mak "$ma_kill_json" \
    '{disabled: $d, limit: $l, merge_autonomy_kill: $mak}' 2>/dev/null)"
  [[ -z "$fleet_flags_json" ]] && fleet_flags_json='{"disabled":null,"limit":null,"merge_autonomy_kill":{"state":"enabled"}}'

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

  # $prs and $claims are the whole cross-repo PR index and claims cache, both
  # of which grow with the fleet — unbounded past this call (requirement 4g,
  # TD-PPagop-26081503). Both arrive on stdin, one document per line, bound
  # positionally with `input as $name` in the printed order — never in argv.
  github_json="$(jq -n --argjson ok "$gh_ok" --arg err "$gh_err" --arg at "$now_iso" \
    --argjson inputs "$inputs_json" \
    --slurpfile pri "$pr_index_file" \
    'input as $prs | input as $claims |
     {ok: $ok, error: $err, fetched_at: $at, stale: false, prs: $prs, inputs: $inputs,
      claims: $claims, pr_index: ($pri[0] // {})}' <<<"$prs_json"$'\n'"$claims_json")"
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

# --- The autonomous-landing digest (D18 WI-8, agent-ops#411) -----------------
# Risk 6 of the autonomy investigation ("overnight merges with nobody
# watching") is accepted deliberately, on the stated condition that this
# replaces the synchronous landing gate at `human` with an asynchronous audit:
# the queue
# re-tests, `failed-runs` turns post-merge breakage back into selectable work,
# and this section is where a human sees, once a day, everything the Script
# landed without them. It is permanent, not rollout scaffolding — at
# `agent-merges-all` it is the *only* routine account of what merged.
#
# Built from the fleet-wide event union, never from a private counter, so a
# landing armed on any node appears on every node's dashboard. Three parts:
#
#   armed    — one row per `landing-armed` inside the window, joined to the
#              `landing-audit-record` (requirement 8x, agent-ops#578) that
#              `_landing_stage_attempt` wrote at the same moment it armed —
#              its tier and verdict are the audit's whole point: "which model
#              tier passed this, and did it approve or merely not refuse" —
#              and, where GitHub has been read this tick, to the pull
#              request's own title and state.
#   refused  — the counterpart the digest would lie by omitting. A day with
#              two landings and forty refusals is a classifier holding the
#              line; the same two landings with no refusals is a gate that
#              may not be running at all, and those must not look alike.
#   budget   — per repository, `merge_budget_per_day`'s effective cap against
#              the rolling-24h count `lib/merge-budget.sh` itself last read,
#              its status (`ok`/`held`/`frozen`), and — held or frozen — the
#              oldest waiting pull request and (`frozen` only) why, so an
#              operator can tell "the fleet is idle because there is no work"
#              from "the fleet is idle because the governor closed hours ago"
#              without a live read of the freeze flag on this tick.
#
# The join is by `pr_url` and the arming cycle, and is deliberately
# first-write-wins over that cycle's audit records *at or after* the arm:
# `_landing_stage_attempt` writes `landing-armed` first and
# `landing-audit-record` second, moments apart from the same function call,
# so this never has to reach further than the earliest match at or after the
# arm's own ts. `landing-armed` carries no pointer of its own to the record
# that follows it, so the cycle `log_event` stamps on both stands in for one
# — which is what keeps a *second* arm of the same pull request from being
# answered by the wrong cycle's record. A `landing-armed` with no
# matching record at all — an event from before requirement 8x shipped, or a
# write this process died between the two log_event calls for — is
# `anomaly: true`: reported, never silently dropped nor rendered with nulls
# as though the join had simply come up empty. This is the one property WI-8
# existed to promise and, before requirement 8x, could not always keep: every
# landing this digest shows is either fully explained or flagged as
# unexplained, never quietly incomplete. A pre-8x `landing-armed` can still
# have its tier/verdict explained, even though it stays `anomaly: true`
# forever (it genuinely has no audit record) — the older `approver-verdict`
# join this panel used before requirement 8x lives on purely as that
# fallback, so "the record could not be found" and "the record said so" stay
# distinguishable without also going back to reading every landing's
# tier/verdict as `unknown` for events this old.
# Both inputs travel by file, not argv: `github_json` carries every open pull
# request the fleet knows about and is exactly the kind of value requirement
# 4g's MAX_ARG_STRLEN rule exists for (see the note above the assemble call).
# The configured caps below are a fallback only, for a repository this tick
# has never yet seen a `merge_budget_decide` result for — they are not derived
# by sourcing lib/merge-budget.sh, whose `merge_budget_effective_cap` also
# consults the freeze flag over the network, a read this script has no
# business making on a dashboard tick. The precedence is the same one that
# file documents: the repository's own entry, else the top-level key, else
# the shipped default of 8.
#
# The per-repository `budget` block itself (D18 issue #574) is sourced from
# the event log, never recomputed: `landing-armed` (an `arm`), `merge-budget-
# hold` (a `hold`) and `merge-budget-frozen` (a `hold` that was also an
# anomaly) each carry the `cap`/`count` `merge_budget_decide` actually read at
# that decision — the same rolling-24h count `lib/merge-budget.sh` itself
# counts, never a private one — so the *single latest* of the three for a
# repository, across the whole log rather than only this digest's own window
# (the same "not restricted to the window" reasoning `$audit_records` above
# already uses), is that repository's state *as of that last gate-5 decision* — not a
# live read, and unbounded in age: a repository whose backlog is empty, or
# whose candidates all fail eligibility before reaching gate 5, keeps
# whatever event last fired indefinitely. `ok` means the last thing gate 5
# did for it was arm, and its `consumed` is the count `merge_budget_decide`
# read *before* granting that arm (the landing the arm itself produced is not
# in it, so a repository that just spent its last permitted landing this
# window reads e.g. 7/8, not 8/8) — but that count is a rolling-24h fact
# exactly like a hold's, and is aged back the same way: once its own event
# falls outside this digest's window, `consumed` resets to unmeasured rather
# than carrying a count forward that has already rolled off the governor's
# own clock, whatever the number would otherwise claim. `held` means
# exhausted, no anomaly, and is aged back to `ok` on the identical rule — a
# hold is a rolling-24h fact, so one nothing has refreshed for a full window
# has already rolled off the governor's own clock — and its `consumed`
# resets to unmeasured with it, so an aged hold reads exactly like a
# repository gate 5 has never reached rather than carrying a stale count
# forward under a status that now claims to be healthy. `frozen` means an
# anomaly tripped it to `agent-approves`, and is never aged back this way: a
# freeze stands until a human clears the fleet flag, not until time passes,
# so staying stuck is correct even indefinitely. A `held`/`frozen` row's
# `as_of` carries the source event's own timestamp for the page to render an
# age against; an `ok` row never carries `as_of`, aged back or not — once its
# count resets to unmeasured its status, consumed and as_of read as a
# repository gate 5 has never reached at all reads, which has no age to show
# either. Only `cap` still separates the two: a row with any recorded decision
# keeps that decision's own cap until its next decision refreshes it, never
# re-reading config.json, so an operator's edit to `merge_budget_per_day`
# becomes visible on the next gate-5 decision rather than the next tick. A repository gate 5
# has never reached — no candidate pull request has reached it yet this
# fleet's whole retained log — reports `ok` with `consumed: 0` against its
# configured cap: a real absence of data, not a claim that nothing has
# landed, but the same one merge_budget_decide itself makes before its first
# read. An unlimited repository (`merge_budget_per_day: 0`) never has a
# `count` to read at all — `merge_budget_decide` short-circuits before
# counting — so its `consumed` instead counts this digest's own
# `landing-armed` events in-window, the same plain reading the
# `armed`/`refused` rows above already give.
printf '%s' "$github_json" > "$work_tmp/landing-github.json"
jq -c '(.merge_budget_per_day // 8) as $top
  | [ (.repos // [])[] | {key: .slug, value: ((.merge_budget_per_day // $top))} ]
  | from_entries' "$CONFIG_FILE" > "$work_tmp/landing-config.json" 2>/dev/null \
  || printf '{}' > "$work_tmp/landing-config.json"
jq -e 'type == "object"' "$work_tmp/landing-config.json" >/dev/null 2>&1 \
  || printf '{}' > "$work_tmp/landing-config.json"
landings_json="$(printf '%s\n' "$ALL_EVENTS" | jq -c -s \
  --arg now "$now_iso" \
  --argjson hours "${LANDING_DIGEST_WINDOW_HOURS:-24}" \
  --slurpfile ghf "$work_tmp/landing-github.json" \
  --slurpfile cfgf "$work_tmp/landing-config.json" '
  ($now | fromdateiso8601) as $now_s
  | ($now_s - ($hours * 3600)) as $from_s
  | def in_window: (.ts // "") as $t
      | ($t | length) > 0
      and (try ($t | fromdateiso8601) catch 0) >= $from_s;
  # A timestamp is stale once it falls before the window this digest itself
  # is computed over — the same cutoff in_window already tests an event
  # against, but usable on a bare string ($lb.ts below is not the event
  # itself).
  def stale($t): ($t // "" | length) == 0
      or (try ($t | fromdateiso8601) catch 0) < $from_s;
  # Every landing-audit-record (requirement 8x, agent-ops#578), oldest last,
  # so a lookup can take the earliest one at or after a given arm. Not
  # restricted to the window: the record that justified a landing early in
  # the window may predate the window itself. The audit record itself
  # already carries, in its own `approver` field, the tier/verdict/
  # adjudication the older `$verdicts` join below used to reconstruct — this
  # is the primary source for both now, with `$verdicts` kept only as a
  # fallback for a `landing-armed` event that predates requirement 8x and so
  # can never have a matching record at all (see `audit_record_for` below).
  ([ .[] | select(.event == "landing-audit-record") ]
    | sort_by(.ts // "")) as $audit_records
  # Every verdict, newest last, so a lookup can take the last one at or
  # before a given arm — kept only as the pre-8x fallback described above;
  # `approver-verdict` genuinely precedes the arm it authorised, unlike
  # `landing-audit-record`, so "at or before" is correct here even though it
  # is wrong for `audit_record_for`.
  | ([ .[] | select(.event == "approver-verdict") ]
    | sort_by(.ts // "")) as $verdicts
  | ([ .[] | select(.event == "landing-armed") | select(in_window) ]
      | sort_by(.ts // "") | reverse) as $armed
  | ([ .[] | select(.event == "landing-refused") | select(in_window) ]
      | sort_by(.ts // "") | reverse) as $refused
  | (($ghf[0].prs // []) | map({key: (.url // ""), value: .}) | from_entries) as $prs
  | ($cfgf[0] // {}) as $caps
  # Per-repository count of landing-armed events inside the window this
  # digest itself uses (never the whole log) — the only meaning "consumed"
  # can have for an unlimited (cap 0) repository: merge_budget_decide
  # short-circuits a zero cap before counting at all (lib/merge-budget.sh),
  # so its own landing-armed events never carry a count to read from
  # $latest_budget below. This is also what this panel counted before
  # $latest_budget existed, so a cap-0 repository row still agrees with the
  # plain "how many landed in the window" reading the Landed table above it
  # gives.
  | ($armed | group_by(.repo // "") | map({key: (.[0].repo // ""), value: length})
      | from_entries) as $armed_counts
  # The budget state per repository, latest wins, over the whole retained
  # log — see the comment above this jq call for why unbounded is correct
  # here even though $armed/$refused stay window-bound.
  | ( [ .[] | select(.event == "landing-armed") | select(has("cap")) | . + {status: "ok"} ]
    + [ .[] | select(.event == "merge-budget-hold") | . + {status: "held"} ]
    + [ .[] | select(.event == "merge-budget-frozen") | . + {status: "frozen"} ]
    | sort_by(.ts // "") | group_by(.repo // "") | map(last) ) as $latest_budget
  # The audit record at or after a given arm, from the cycle that armed it:
  # `_landing_stage_attempt` always writes `landing-armed` first and
  # `landing-audit-record` second, moments apart from the same function call
  # (agent-cycle.sh:4563 and :4613), so the record this arm produced is never
  # the newest match at-or-before its own ts — it is the *earliest* one
  # at-or-after it. $audit_records is sorted ascending, so `first` here is
  # that earliest match, never the latest.
  #
  # The cycle is part of the key, and carries the whole weight of pairing a
  # *second* arm of the same pull request with the right record. `log_event`
  # stamps every event with the cycle that wrote it (agent-cycle.sh:669), and
  # both writes come from one call inside one cycle, so an arm and its own
  # record always agree on it. On timestamps alone an arm this process died
  # between the two writes for would adopt the record the *next* cycle wrote
  # for the same pr_url — nothing consumes a record, so every arm before it
  # matches — and render `anomaly: false`, hiding precisely the unexplained
  # landing this panel exists to surface. An arm or record carrying no cycle
  # at all falls back to the timestamp join alone rather than being excluded
  # outright: nothing in the write path produces one, but log.jsonl is never
  # rotated (requirement 2.6) and this join must not start dropping rows if
  # one ever appears.
  | def audit_record_for($url; $at; $cyc):
      ([ $audit_records[]
         | select((.pr_url // "") == $url)
         | select((.ts // "") >= $at)
         | select($cyc == "" or (.cycle // "") == "" or (.cycle // "") == $cyc) ]
        | first);
  # The pre-8x fallback (see the comment above $verdicts): only reached when
  # audit_record_for above found nothing, which is the one case an
  # approver-verdict join can still explain — a `landing-armed` this old
  # never gets a `landing-audit-record` no matter how the join runs, so
  # falling back is not a second attempt at the same fact, it is the only
  # source left for it.
  def verdict_for($url; $at):
      ([ $verdicts[] | select((.pr_url // "") == $url) | select((.ts // "") <= $at) ] | last);
  # Every classifier-escape/landing-audit event, newest last, joined by
  # pr_url alone — never at-or-before, unlike audit_record_for above, since
  # an audit only ever happens after the landing it covers, so there is no
  # "which one could the arm have seen" question to answer. A pull request
  # with no audit yet reads audit: null, never folded into clean or escape
  # (requirement 8e).
  ([ .[] | select(.event == "classifier-escape" or .event == "landing-audit") ]
    | sort_by(.ts // "")) as $audits
  | def audit_for($url):
      ([ $audits[] | select((.pr_url // "") == $url) ] | last) as $a
      | if $a == null then {audit: null, audit_reason: null}
        else {audit: ($a.outcome // "escape"), audit_reason: ($a.reason // null)} end;
  {
    window_hours: $hours,
    generated_at: $now,
    armed: [ $armed[] | (.pr_url // "") as $u | (.ts // "") as $at
      | (.cycle // "") as $cyc
      | (audit_record_for($u; $at; $cyc)) as $ar
      | (if $ar == null then verdict_for($u; $at) else null end) as $v
      | ($prs[$u] // null) as $pr
      | { ts: $at,
          repo: (.repo // ""),
          pr_url: $u,
          ref: ($pr.ref // (if ($u | test("/pull/[0-9]+$")) then
                  ((.repo // "") + "#" + ($u | capture("/pull/(?<n>[0-9]+)$").n)) else $u end)),
          title: ($pr.title // null),
          state: ($pr.state // null),
          merged_at: ($pr.merged_at // null),
          source: (.source // ""),
          complexity: (.complexity // ""),
          method: (.method // ""),
          node: (.node // ""),
          tier: ($ar.approver.tier // $v.tier // null),
          verdict: ($ar.approver.verdict // $v.verdict // null),
          adjudication: ($ar.approver.adjudication // $v.adjudication // null),
          anomaly: ($ar == null) } + audit_for($u) ],
    refused: [ $refused[] | { ts: (.ts // ""), repo: (.repo // ""),
                              pr_url: (.pr_url // ""), reason: (.reason // "") } ],
    budget: ( ([ ($latest_budget[] | .repo // ""), ($caps | keys[]) ] | unique
                | map(select(. != ""))) as $repos
      | [ $repos[] | . as $r
          | (($caps[$r] // null)) as $cfg_cap
          | (([ $latest_budget[] | select((.repo // "") == $r) ] | first)) as $lb
          # The cap the recorded decision itself carries wins over the one
          # configured in config.json: the pair merge_budget_decide reasoned
          # from is read together, so an edit to merge_budget_per_day
          # becomes visible when that repository next reaches gate 5, rather
          # than on the next dashboard tick. A cap of 0 must survive the //
          # below, and does — 0 is not null in jq. A repository with no
          # recorded decision at all has only the configured cap to fall
          # back on.
          | (if $lb then ($lb.cap // $cfg_cap) else $cfg_cap end) as $cap
          | ($cap == 0 or $cap == null) as $unlimited
          # A hold is a rolling-24h fact: once the event that recorded it
          # falls outside the window this digest itself is computed over,
          # the count behind it has already rolled off the rolling 24h clock
          # the governor itself keeps — nothing still holds the repository,
          # whatever the latest event in the log says, so a stale hold reads
          # back as `ok` rather than staying stuck until the next gate-5
          # decision happens to refresh it. A freeze is not a rolling fact —
          # it stands until a human clears it via the fleet flag — so it is
          # never aged back on its own.
          | ($lb != null and $lb.status == "held" and stale($lb.ts)) as $held_stale
          # An `ok` count is a rolling-24h fact too, read from the same
          # `landing-armed` event a hold or freeze would have read it from —
          # the same reasoning that ages a stale hold back applies verbatim
          # to a stale `ok`: once its event rolls off the window, the count
          # behind it has rolled off the clock the governor itself keeps,
          # so it must reset to unmeasured rather than carrying forward
          # indefinitely under a status that gives no sign of its true age.
          | ($lb != null and $lb.status == "ok" and stale($lb.ts)) as $ok_stale
          | (if $held_stale then "ok" elif $lb then $lb.status else "ok" end) as $status
          # A demoted hold count rolled off along with it — carrying it
          # forward under `ok` would show a repository sitting at its old
          # cap while claiming to be healthy, so it reads exactly like a
          # repository gate 5 has never reached: unmeasured, not stale. A
          # stale `ok` count resets the same way, for the same reason.
          | (if $unlimited then ($armed_counts[$r] // 0)
             elif $held_stale then null
             elif $ok_stale then null
             elif $lb then $lb.count else null end) as $c
          | (if $lb and $status == "frozen" then ($lb.reason // null) else null end) as $reason
          | (if $lb then ($lb.waiting_backlog // null) else null end) as $backlog
          | { repo: $r, cap: $cap, consumed: ($c // 0),
              unlimited: $unlimited,
              remaining: (if $unlimited then null
                          else ([ ($cap - ($c // 0)), 0 ] | max) end),
              status: $status, reason: $reason, oldest_waiting: $backlog,
              as_of: (if $lb and ($status == "held" or $status == "frozen")
                      then ($lb.ts // null) else null end) } ] )
  }' 2>/dev/null)"
if ! jq -e 'type == "object"' <<<"$landings_json" >/dev/null 2>&1; then
  # Same fail-visible-not-fail-silent rule the rest of this script follows: an
  # empty object renders as "nothing landed", which is a claim, so degrade to
  # a shape the page can tell apart from a real quiet day.
  landings_json="$(jq -nc --arg now "$now_iso" \
    '{window_hours: null, generated_at: $now, armed: null, refused: null, budget: null}')"
fi

# --- Classifier-escape audit roll-up (requirement 8e, agent-ops#572) --------
# `counts.escape_audits`, never windowed like `landings_json` above — an
# escape is a permanent fact about one merged pull request, and letting it
# age out of a 24h/30-day window would recreate exactly the "row nobody
# reads" the detector exists to prevent. Folded from the fleet-wide event
# union, the same `classifier-escape`/`landing-audit` events already joined
# into `landings_json.armed` above by `audit_for`, so the two can never
# disagree about which pull requests carry which outcome.
escape_audits_json="$(printf '%s\n' "$ALL_EVENTS" | jq -c -s '
  ([ .[] | select(.event == "classifier-escape") | . + {outcome: "escape"} ]
    + [ .[] | select(.event == "landing-audit") ]) as $all
  | ($all | group_by(.pr_url // "") | map(sort_by(.ts // "") | last)) as $latest
  | { checked: ($latest | length),
      clean: ([ $latest[] | select(.outcome == "clean") ] | length),
      escapes: ([ $latest[] | select(.outcome == "escape") ] | length),
      unverifiable: ([ $latest[] | select(.outcome == "unverifiable") ] | length),
      escape_list: ([ $latest[] | select(.outcome == "escape")
          | {ts: (.ts // ""), repo: (.repo // ""), pr_url: (.pr_url // ""),
             reason: (.reason // "")} ] | sort_by(.ts) | reverse),
      unverifiable_list: ([ $latest[] | select(.outcome == "unverifiable")
          | {ts: (.ts // ""), repo: (.repo // ""), pr_url: (.pr_url // ""),
             reason: (.reason // "")} ] | sort_by(.ts) | reverse) }
' 2>/dev/null)"
if ! jq -e 'type == "object"' <<<"$escape_audits_json" >/dev/null 2>&1; then
  # Same explicit-failure discipline as landings_json's own degrade path:
  # a payload this could not assemble must never render as "zero escapes".
  escape_audits_json='{"checked":null,"clean":null,"escapes":null,"unverifiable":null,"escape_list":null,"unverifiable_list":null}'
fi
counts_with_escapes="$(jq -c --argjson e "$escape_audits_json" '. + {escape_audits: $e}' \
  <<<"$counts_json" 2>/dev/null)"
[[ -n "$counts_with_escapes" ]] && counts_json="$counts_with_escapes"

# --- Revert rate by repository (D18 issue #579) -----------------------------
#
# scripts/publish-revert-rate.sh appends one row per repository, per node,
# per day to revert-rate.jsonl (never rotated, replicated fleet-wide exactly
# like log.jsonl — see that script's own header). This reads the fleet-wide
# union and keeps the newest row per repository (by its own `ts`, across
# every node — union-with-most-recent-event-wins, the same rule the blocked
# and void extractions use over log.jsonl), joined against config.repos so a
# repository whose publishing tick has never once succeeded still gets a row
# — `{repo}` alone, no other keys — rather than silently vanishing from the
# panel.
revert_rate_repos_json="$(jq -c '[.repos[].slug]' <<<"$DEFAULTED_CONFIG" 2>/dev/null || printf '[]')"
revert_rate_json="$(fleet_logs "$state_dir" "$peers_dir" revert-rate.jsonl \
  | jq -c -R 'fromjson? // empty' | jq -s -c --argjson repos "$revert_rate_repos_json" '
      (group_by(.repo) | map(max_by(.ts))) as $latest
      | [ $repos[] as $slug | (($latest[] | select(.repo == $slug)) // {repo: $slug}) ]
    ' 2>/dev/null)"
jq -e 'type == "array"' <<<"$revert_rate_json" >/dev/null 2>&1 || revert_rate_json='null'

# --- Assemble ----------------------------------------------------------------
# --- The stage budgets, as the page needs them (requirement 4f) -----------------
# Two things the page cannot work out for itself. `lock_stale_after` is no
# longer a configured constant but a derivation over the backstops in force,
# and the page uses it to decide when a peer that stopped publishing should
# stop being believed; and the per-actor backstops let a row whose event
# predates the announcement still be judged against something real. Both are
# computed from the same union the rest of this script reads.
stage_budget_json="$(stage_budget_table \
  "$(printf '%s\n' "$ALL_EVENTS" | stage_budget_observations 2>/dev/null || printf '[]')" \
  "$(stage_budget_settings "$(cat "$CONFIG_FILE" 2>/dev/null || printf '{}')")" 2>/dev/null \
  || printf '{"cells":{},"actors":{}}')"
lock_stale_derived_hours="$(jq -nr --argjson sec \
  "$(stage_budget_lock_seconds "$stage_budget_json" \
     "$(stage_budget_all_overrides "$(cat "$CONFIG_FILE" 2>/dev/null || printf '{}')")" 30 \
     "$(jq -r '.lock_stale_after // 0' "$CONFIG_FILE" 2>/dev/null || printf 0)")" \
  '(($sec / 3600) * 100 | round) / 100' 2>/dev/null || printf 4)"
config_json="$(jq -c --argjson t "$stage_budget_json" --argjson lock "$lock_stale_derived_hours" \
  '{repos, coordinator_model, implementer_model_default, implementer_model_trivial,
    reviewer_model_default, reviewer_model_complex, pr_label, branch_prefix,
    max_open_agent_prs, limit_cooldown_default, dashboard_refresh_seconds,
    image_behind_grace_hours}
   + {lock_stale_after: $lock,
      stage_backstops: (($t.cells // {}) | to_entries
        | reduce .[] as $e ({};
            .[$e.value.actor] = ([ (.[$e.value.actor] // 0), $e.value.backstop_min ] | max)))}' \
  "$CONFIG_FILE")"

# cycles/github/log_tail can each be large; hand them to jq via files.
# fleet.claims rides in github (fetched on the tick, carried by gh_cache
# between ticks); it is surfaced under fleet because that is what it is.
printf '%s' "$github_json"   > "$work_tmp/github.json"
printf '%s' "$log_tail_json" > "$work_tmp/logtail.json"
# So can the void and blocked extracts and the counts roll-up, and for the same
# reason: all three grow with the fleet's history, so none of them may travel as
# an `--argjson` value — a single argv entry, capped at MAX_ARG_STRLEN (131072
# bytes) by `execve`, not by jq. This is requirement 4g's rule, which the Script
# adopted after the 2026-08-12 outage; the Publisher was left behind, and on
# 2026-08-14 the void extract reached 132539 bytes here and the cap bit again.
# It bit differently, because this call site is unguarded and not under `set -e`:
# jq never ran, `$data_json` came back empty, and the write below still emitted
# `window.DASHBOARD_DATA = ;` — a JavaScript syntax error, so every dashboard on
# every node stopped updating while each tick logged a successful write. Only
# values bounded by configuration (a node name, the config object, a count) may
# still ride argv.
printf '%s' "$counts_json"  > "$work_tmp/counts.json"
printf '%s' "$landings_json" > "$work_tmp/landings.json"
printf '%s' "$revert_rate_json" > "$work_tmp/revert-rate.json"
printf '%s' "$blocked_json" > "$work_tmp/blocked.json"
printf '%s' "$void_json"    > "$work_tmp/void.json"
data_json="$(jq -n \
  --arg generated_at "$now_iso" \
  --arg self_node "$self_node" \
  --argjson config "$config_json" \
  --argjson status "$status_json" \
  --slurpfile counts "$work_tmp/counts.json" \
  --slurpfile cyc "$cycles_file" \
  --argjson noop "$noop_json" \
  --slurpfile blocked "$work_tmp/blocked.json" \
  --slurpfile void "$work_tmp/void.json" \
  --slurpfile landings "$work_tmp/landings.json" \
  --slurpfile rr "$work_tmp/revert-rate.json" \
  --slurpfile gh "$work_tmp/github.json" \
  --slurpfile lt "$work_tmp/logtail.json" \
  --argjson cron_tail "$cron_tail_json" \
  --argjson fleet_nodes "$fleet_nodes_json" \
  --argjson fleet_flags "$fleet_flags_json" \
  --arg max_prs "$max_open_agent_prs" \
  '{generated_at: $generated_at, node: $self_node, config: $config, status: $status,
    counts: $counts[0], cycles: $cyc[0], noop_ticks: $noop, blocked: $blocked[0],
    void: $void[0], github: $gh[0], log_tail: $lt[0], landings: $landings[0],
    revert_rate: $rr[0],
    cron_tail: $cron_tail, max_open_agent_prs: ($max_prs|tonumber),
    fleet: {nodes: $fleet_nodes, flags: $fleet_flags, claims: ($gh[0].claims // [])}}')"

# An assemble that failed must not be published. `set -e` is deliberately off
# here, so a jq that dies — at `execve`, on a malformed input, out of memory —
# leaves `$data_json` empty rather than stopping the script, and an empty
# payload written out is not a thin dashboard but a broken one: the page's own
# `data.js` fails to parse, so it keeps rendering whatever it loaded last and
# never says why. Leaving the previous data.js in place is strictly better —
# the page ages visibly against its own `generated_at`, which is the signal an
# operator already reads — and the non-zero exit is what puts the reason in
# cron.log instead of another line claiming a write.
if ! jq -e . >/dev/null 2>&1 <<<"$data_json"; then
  echo "publish-dashboard: could not assemble the payload; $data_file left unchanged" >&2
  exit 1
fi

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
