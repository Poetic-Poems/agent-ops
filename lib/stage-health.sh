#!/usr/bin/env bash
#
# lib/stage-health.sh — per-stage health verdict from a node's own log.jsonl
# (issue #662).
#
# During the 2026-08-21 incident (01:38-12:09Z) every stage in every node's
# cycles failed for 10.5 hours, and nothing said so: `agent-cycle.sh
# --status` reported "cycle: RUNNING" (the process was alive), no
# `check-node-*.sh` complained (nothing there reads a stage's own outcome),
# and the dashboard stayed green. All three were technically true — the
# needed detection already existed, as `stage-end`'s own `exit_code` — but
# nothing read it. This file is that reading.
#
# It complements requirement 2.7's crash-loop escalation (lib/crash-loop.sh),
# rather than replacing it: that reader is fleet-wide, matches on one
# identical failure detail, and files a GitHub issue — built for one specific
# deterministic class of Co-Ordinator failure. This reader is node-local,
# purely informational (nothing here ever opens an issue, blocks a cycle, or
# escalates anything), and answers a narrower, cheaper question for every
# stage the Script runs, not only the Co-Ordinator: "is this stage's most
# recent run of attempts on this node succeeding?"
#
# `stage_health_verdicts` is a pure reader of one node's own event stream on
# stdin — deliberately never the fleet union `crash_loop_verdict` reads: a
# stage that is healthy on every other node says nothing about whether it is
# healthy on this one, which is exactly the distinction requirement 2.7's own
# fleet-wide, identical-detail matching cannot draw. Torn lines are skipped
# (`fromjson? // empty`), the same tolerance every other log reader in this
# codebase gives a partial write.
#
# The stream is parsed with `jq -R -n 'inputs'`, one line at a time, and
# deliberately not with the `jq -R -s '[splits("\n")]'` spelling the other
# log readers here use (lib/crash-loop.sh, lib/review-gate.sh,
# lib/escalation-autonomy.sh — TD-PPagop-26082503). `splits` runs an
# oniguruma regex over the whole slurped file, which is quadratic enough in
# practice that a real 2.3 MB `log.jsonl` takes ~80 s to split and ~0.07 s
# to read with `inputs` — a difference that matters here more than it does
# there, because this reader runs inside every cycle's own `cleanup()` and
# `log.jsonl` is never rotated (scripts/rotate-logs.sh), so the cost would
# grow without bound for the life of the node.
#
# For each stage in `stage_names` (below) it returns:
#   - last_success: the `ts` of the most recent `stage-end` with exit_code 0
#     for that stage, or null if it has never once succeeded on this node.
#   - consecutive_failures: how many `stage-end` events in a row, most
#     recent first, this stage has recorded a non-zero exit_code — reset to
#     0 the instant a success is seen. The same running-streak reduction
#     `crash_loop_verdict` already uses, but per-stage, per-node, and
#     without requiring an identical failure detail: any failure counts,
#     because "always wrong in some new way" is exactly as unhealthy as
#     "always wrong the same way".
#   - last_detail: the `detail` of the most recent `attempt-failed` event
#     for this stage, but only while `consecutive_failures` > 0 — null again
#     the moment a success clears the streak, because this describes the
#     *current* failure, not a history of every failure this stage has ever
#     logged.
#   - verdict: one of:
#       `idle`    — this stage has no `stage-end` record at all on this node
#                   (never invoked, e.g. a Reviewer this node has never had
#                   a pull request to review), or its last success is older
#                   than IDLE_AFTER_HOURS and nothing has failed since — a
#                   stage that simply has had no work is not unhealthy.
#       `failing` — consecutive_failures has reached THRESHOLD.
#       `ok`      — anything else, including a stage that has failed once or
#                   twice but not yet reached THRESHOLD: "one failure does
#                   not trigger a verdict — normal transients exist" is the
#                   issue's own acceptance bar.
#
# THRESHOLD (default 3) and IDLE_AFTER_HOURS (default 48) are one pair of
# defaults shared by every stage, rather than the per-stage table the
# issue's own refinement comment floats, because every stage listed here
# shares the same invocation shape once it does run: one whole attempt per
# cycle, success or failure, with nothing that retries several times inside
# a single cycle the way a `gh` call does. Three consecutive whole-cycle
# failures is already the same order of confidence `crash_loop_after`
# requires by default (4, config.schema.json) before requirement 2.7
# escalates a fleet-wide issue — reached here well before that heavier,
# issue-filing mechanism would ever fire, which is the detection gap #662
# exists to close. Both are ordinary function parameters, not config keys:
# nothing here needs the schema/README/spec table machinery a config key
# would commit this feature to before its numbers have seen a real incident,
# and a stage whose actual behaviour ever diverges enough to need its own
# number can be given one by its caller without touching this file.

# stage_health_verdicts [THRESHOLD] [IDLE_AFTER_HOURS] [NOW_EPOCH] < log.jsonl
# Print one JSON object keyed by stage name, each value
# {last_success, consecutive_failures, last_detail, verdict} as described
# above. Never fails the caller: an unreadable/malformed stream, or a jq
# fault, prints `{}` rather than nothing, so a caller that always expects an
# object never has to guard against an empty string too.
stage_health_verdicts() {
  local threshold="${1:-3}" idle_after_hours="${2:-48}" now="${3:-}" out
  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
  [[ "$idle_after_hours" =~ ^[0-9]+$ ]] || idle_after_hours=48
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  out="$(jq -c -R -n --argjson threshold "$threshold" \
    --argjson idle_secs "$(( idle_after_hours * 3600 ))" --argjson now "$now" '
    def stage_names: [
      "coordinator", "approver", "approver-adjudicate-open-question",
      "enabler-adjudicate", "enabler", "refiner", "implementer", "reviewer"
    ];
    ([ inputs | select(length > 0) | (fromjson? // empty) ]) as $events
    | reduce stage_names[] as $stage (
        {};
        . + { ($stage): (
          ($events | map(select(.event == "stage-end" and (.stage // "") == $stage)) | sort_by(.ts)) as $ends
          | ($events | map(select(.event == "attempt-failed" and (.stage // "") == $stage)) | sort_by(.ts)) as $fails
          | (reduce $ends[] as $e (0; if (($e.exit_code // 1) == 0) then 0 else . + 1 end)) as $consecutive
          | ($ends | map(select((.exit_code // 1) == 0)) | last | .ts) as $last_success
          | (if $last_success == null then null
             else (try ($last_success | fromdateiso8601) catch null) end) as $last_success_epoch
          | (
              if ($ends | length) == 0 then "idle"
              elif $consecutive >= $threshold then "failing"
              elif $consecutive == 0 and $last_success_epoch != null
                   and ($now - $last_success_epoch) > $idle_secs then "idle"
              else "ok"
              end
            ) as $verdict
          | {
              last_success: $last_success,
              consecutive_failures: $consecutive,
              last_detail: (if $consecutive > 0 then ($fails | last | .detail // null) else null end),
              verdict: $verdict
            }
        )}
      )
  ' 2>/dev/null)" || out=""
  [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1 || out='{}'
  printf '%s\n' "$out"
}

# stage_health_write_status STATE_DIR LOG_FILE [THRESHOLD] [IDLE_AFTER_HOURS] [NOW_EPOCH]
# Compute `stage_health_verdicts` from LOG_FILE — this node's own log.jsonl,
# never the fleet union — and write it atomically to
# STATE_DIR/.stage-health.json as `{computed_at, threshold, idle_after_hours,
# stages}`, on `write_unattended_status`'s own precedent (scripts/doctor.sh,
# #617): `mktemp` in the same directory, then `mv -f`, so a reader never sees
# a partial file. An unwritable or missing STATE_DIR is a silent no-op, the
# same tolerance doctor's own writer gives it — recording this status is
# never worth failing the cycle that computed it. Always returns 0.
stage_health_write_status() {
  local state_dir="$1" log_file="$2" threshold="${3:-3}" idle_after_hours="${4:-48}" now="${5:-}"
  [[ -n "$state_dir" && -d "$state_dir" && -w "$state_dir" ]] || return 0
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  local ts stages_json tmp
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  stages_json="$( { [[ -n "$log_file" && -f "$log_file" ]] && cat "$log_file"; } \
    | stage_health_verdicts "$threshold" "$idle_after_hours" "$now")"
  tmp="$(mktemp "$state_dir/.stage-health.json.XXXXXX" 2>/dev/null)" || return 0
  if jq -n --arg ts "$ts" --argjson threshold "$threshold" --argjson idle_hours "$idle_after_hours" \
        --argjson stages "$stages_json" \
        '{computed_at: $ts, threshold: $threshold, idle_after_hours: $idle_hours, stages: $stages}' \
        > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$state_dir/.stage-health.json"
  else
    rm -f "$tmp"
  fi
  return 0
}

# stage_health_status_lines STATUS_FILE [NOW_EPOCH]
# Print the `--status` `stages:` block's own body lines (the caller owns the
# `stages:` header itself, the same division `toggle_status_report` leaves
# its caller for `switch:`) — one line per stage, read from a
# `stage_health_write_status`-shaped STATUS_FILE. A missing or unreadable
# file (no cycle has completed on this node since this feature shipped)
# prints one explanatory line instead of nothing, so `--status` never goes
# quiet on a question it was just asked.
stage_health_status_lines() {
  local status_file="$1" now="${2:-}"
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  if [[ ! -s "$status_file" ]]; then
    printf '  no data yet (written at the end of this node'"'"'s next completed cycle)\n'
    return 0
  fi
  jq -r --argjson now "$now" '
    def ago:
      if . == null then "never"
      else (try (. | fromdateiso8601) catch null) as $t
        | if $t == null then "unknown"
          else ([$now - $t, 0] | max) as $d
          | if $d < 60 then "\($d)s ago"
            elif $d < 3600 then "\(($d/60)|floor)m ago"
            elif $d < 86400 then "\(($d/3600)|floor)h ago"
            else "\(($d/86400)|floor)d ago" end
          end
      end;
    (.stages // {}) | to_entries[]
    | .key as $stage | .value as $v
    | if $v.verdict == "failing" then
        "  \($stage) failing (\($v.consecutive_failures) consecutive, last success \($v.last_success | ago))"
      elif $v.verdict == "idle" and $v.last_success == null then
        "  \($stage) idle (never run)"
      else
        "  \($stage) \($v.verdict) (last success \($v.last_success | ago))"
      end
  ' "$status_file" 2>/dev/null
}
