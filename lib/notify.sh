#!/usr/bin/env bash
# shellcheck disable=SC2034  # notify_post's context params are read by name at each call site, not by shellcheck's flow analysis.
#
# lib/notify.sh — the installation's one push-notification channel
# (issue #1279, requirement 2m as rewritten): every escalation issue filed or
# auto-closed, every `pager-fired`/`pager-cleared` (#1278), and every
# fleet-wide stand-down beginning or ending, POSTed as one compact JSON body
# to `notify_webhook_url`. Promoted from `escalation_webhook_notify`'s own
# narrower job — a filing-failure fallback only — which is now the
# `escalation-unfiled` event class alongside the others.
#
# Deliberately self-contained, the same reasoning lib/pager.sh's own header
# gives for not depending on lib/enabler.sh: `notify_post` is called from
# inside an active agent-cycle.sh process (cycle-scoped globals available:
# `log_file`, `node_name`, `cycle_id`) and from scripts/publish-dashboard.sh's
# Publisher tick (no cycle, no per-item context) alike. Every context
# `notify_post` needs is therefore an explicit parameter, never a global this
# file reads directly — `notify_post_cycle` below is the one place that
# bridges the two, reading the cycle's own globals once and forwarding them
# positionally, exactly the shape `escalation_webhook_notify` used to be.
#
# Event-sourced, like every other dedup/retry state this codebase keeps: no
# state file of its own. `notify-sent`/`notify-suppressed`/`notify-failed`
# land in the ordinary log.jsonl, and `notify_min_interval_seconds`'s
# per-(event, key) coalescing is a read over that log (READ_LOG, ordinarily
# `${union_log:-$log_file}` — fleet-wide where a union exists, so two nodes
# racing the same key still coalesce), not a cache.

# notify_resolve_webhook_url NOTIFY_URL ESCALATION_URL
# `notify_webhook_url` wins when both are set; `escalation_webhook_url` is
# accepted as an alias for one release (issue #1279) when `notify_webhook_url`
# is empty. Prints the resolved URL, or nothing.
notify_resolve_webhook_url() {
  local notify_url="${1:-}" escalation_url="${2:-}"
  if [[ -n "$notify_url" ]]; then
    printf '%s' "$notify_url"
  else
    printf '%s' "$escalation_url"
  fi
}

# notify_event_class EVENT
# The three classes `notify_events` gates on. An event not in this table
# posts to no class and so is never sent, whatever `notify_events` says —
# fail closed on an unrecognised event name rather than posting it
# unconditionally.
notify_event_class() {
  case "$1" in
    escalation-filed|escalation-closed|escalation-unfiled) printf 'escalation' ;;
    pager-fired|pager-cleared) printf 'pager' ;;
    fleet-standdown-begin|fleet-standdown-end) printf 'fleet-standdown' ;;
    *) printf '' ;;
  esac
}

# _notify_log_event LOG_FILE NODE CYCLE EVENT FIELDS_JSON
# The same envelope agent-cycle.sh's own log_event and lib/pager.sh's own
# pager_log_event write — {ts, cycle, node, event} + FIELDS_JSON. A third
# copy rather than calling either: this file must stay sourceable standalone,
# from a process with neither.
_notify_log_event() {
  local log_file="$1" node="$2" cycle="$3" event="$4" fields="${5:-{\}}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg cycle "$cycle" --arg node "$node" --arg event "$event" \
    --argjson fields "$fields" '{ts: $ts, cycle: $cycle, node: $node, event: $event} + $fields' \
    >> "$log_file" 2>/dev/null || true
}

# _notify_last_sent_ts EVENT KEY < READ_LOG
# The `ts` of the most recent `notify-sent` event for this (EVENT, KEY) pair,
# or nothing. Both halves matter: `fleet-standdown-begin` and
# `fleet-standdown-end` share one key by design (`standdown:usage-limit` and
# its three siblings), and a stand-down in force re-posts its `begin` every
# cycle — so keying on KEY alone would leave that key's last `notify-sent`
# permanently younger than the interval, and the `end` an operator is waiting
# on would be suppressed almost every time. `pager-fired`/`pager-cleared`
# collide the same way.
_notify_last_sent_ts() {
  local event="$1" key="$2"
  jq -r -R -n --arg e "$event" --arg k "$key" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "notify-sent" and (.notify_event // "") == $e
               and (.key // "") == $k) ]
    | sort_by(.ts) | last | (.ts // empty)
  ' 2>/dev/null || true
}

# _notify_suppressed_count_since EVENT KEY SINCE_TS < READ_LOG
# How many `notify-suppressed` events this (EVENT, KEY) pair has logged since
# SINCE_TS (exclusive; every one of them, when SINCE_TS is empty — no prior
# send). The count folded into the next allowed POST's `count` field, so a
# burst coalesces into one message and a number rather than N identical ones.
_notify_suppressed_count_since() {
  local event="$1" key="$2" since="${3:-}"
  jq -n -R --arg e "$event" --arg k "$key" --arg since "$since" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "notify-suppressed" and (.notify_event // "") == $e
               and (.key // "") == $k) ]
    | (if $since == "" then . else map(select(.ts > $since)) end)
    | length
  ' 2>/dev/null || printf '0'
}

# notify_post EVENT KEY TITLE URL REPO DETAIL WEBHOOK_URL EVENTS_JSON \
#             MIN_INTERVAL READ_LOG WRITE_LOG NODE CYCLE
# POSTs `{event, key, title, url, repo, node, ts, detail}` (plus `count` when
# a suppressed burst preceded this send) to WEBHOOK_URL — a no-op, always
# returning 0, when: WEBHOOK_URL is empty; EVENT's class
# (`notify_event_class`) is not a member of EVENTS_JSON; or this (EVENT, KEY)
# pair's last `notify-sent` (read from READ_LOG) is younger than MIN_INTERVAL
# seconds, in which case a `notify-suppressed` event is logged instead and the
# next allowed send folds this one into its own `count`.
#
# Requirement 2m's guarantees, unchanged from `escalation_webhook_notify`:
# credential-independent (no `gh`/`GH_TOKEN` anywhere in this path),
# best-effort (a POST failure logs one local `notify-failed` and never
# propagates), `https://`-only by the schema's own pattern on
# `notify_webhook_url`/`escalation_webhook_url`, and never blocks the cycle
# (a 10s `curl --max-time`, same as every other webhook call in this
# codebase).
notify_post() {
  local event="$1" key="$2" title="$3" url="$4" repo="$5" detail="$6" \
        webhook_url="$7" events_json="${8:-[]}" min_interval="${9:-600}" \
        read_log="${10:-/dev/null}" write_log="${11:-/dev/null}" node="${12:-}" cycle="${13:-}"
  [[ -n "$webhook_url" ]] || return 0
  local class
  class="$(notify_event_class "$event")"
  [[ -n "$class" ]] || return 0
  jq -e --arg c "$class" 'index($c) != null' <<<"$events_json" >/dev/null 2>&1 || return 0
  [[ "$min_interval" =~ ^[0-9]+$ ]] || min_interval=600
  # A read log that does not exist yet is an ordinary state for a freshly
  # provisioned node, not an error: without this the redirect below fails,
  # and because every caller runs under `set -e` that failure would abort the
  # cycle from inside the one path requirement 2m promises never blocks it.
  # No prior send is readable, so no send is suppressed — fail open.
  [[ -r "$read_log" ]] || read_log=/dev/null

  local now last_sent_ts last_sent_epoch
  now="$(date -u +%s)"
  last_sent_ts="$(_notify_last_sent_ts "$event" "$key" < "$read_log")"
  if [[ -n "$last_sent_ts" ]]; then
    last_sent_epoch="$(date -u -d "$last_sent_ts" +%s 2>/dev/null || printf '0')"
    if (( now - last_sent_epoch < min_interval )); then
      _notify_log_event "$write_log" "$node" "$cycle" "notify-suppressed" \
        "$(jq -nc --arg e "$event" --arg k "$key" '{notify_event: $e, key: $k}')"
      return 0
    fi
  fi

  local suppressed_count count ts payload
  suppressed_count="$(_notify_suppressed_count_since "$event" "$key" "$last_sent_ts" < "$read_log")"
  [[ "$suppressed_count" =~ ^[0-9]+$ ]] || suppressed_count=0
  count=$(( suppressed_count + 1 ))
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  payload="$(jq -nc --arg event "$event" --arg key "$key" --arg title "$title" \
    --arg url "$url" --arg repo "$repo" --arg node "$node" --arg ts "$ts" \
    --arg detail "$detail" --argjson count "$count" \
    '{event: $event, key: $key, title: $title, url: $url, repo: $repo, node: $node, ts: $ts, detail: $detail}
     + (if $count > 1 then {count: $count} else {} end)' 2>/dev/null)" || return 0

  if curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
        --data-binary "$payload" "$webhook_url" >/dev/null 2>/dev/null; then
    _notify_log_event "$write_log" "$node" "$cycle" "notify-sent" \
      "$(jq -nc --arg e "$event" --arg k "$key" '{notify_event: $e, key: $k}')"
  else
    _notify_log_event "$write_log" "$node" "$cycle" "notify-failed" \
      "$(jq -nc --arg e "$event" --arg k "$key" \
           --arg d "notify webhook POST failed for key $key (event $event)" \
           '{notify_event: $e, key: $k, detail: $d}')"
  fi
  return 0
}

# notify_post_cycle EVENT KEY TITLE URL REPO DETAIL
# The cycle-context convenience wrapper: reads `notify_webhook_url`,
# `notify_events_json`, `notify_min_interval_seconds`, `log_file`,
# `node_name` and `cycle_id` — every one of them already resolved once by
# agent-cycle.sh (the same single-sourced-process convention lib/enabler.sh's
# own header describes) — and forwards to `notify_post`. `${union_log:-
# $log_file}` for the read side, the same fallback `escalation_autonomy_*`
# already uses elsewhere: fleet-wide once a union exists, this node's own
# log before one does (management commands, run before the cycle's union is
# built).
notify_post_cycle() {
  local event="$1" key="$2" title="$3" url="$4" repo="$5" detail="$6"
  notify_post "$event" "$key" "$title" "$url" "$repo" "$detail" \
    "${notify_webhook_url:-}" "${notify_events_json:-[]}" "${notify_min_interval_seconds:-600}" \
    "${union_log:-${log_file:-/dev/null}}" "${log_file:-/dev/null}" "${node_name:-}" "${cycle_id:-}"
}
