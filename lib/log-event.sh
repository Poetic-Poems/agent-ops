#!/usr/bin/env bash
#
# lib/log-event.sh — the event-envelope logic both cycles' own `log_event`
# wraps.
#
# agent-cycle.sh and review-cycle.sh each keep their own event log (keyed by
# `cycle`/`review` respectively, and written to a different file), but the
# envelope shape and the FIELDS contract are otherwise identical, so
# `log_event_append` takes the one genuine difference — which id field to
# stamp, what to stamp it with, and which file to append to — as arguments
# and leaves everything else, including the issue #361/#458 FIELDS coercion,
# in one place both callers share.
#
# FIELDS must be a JSON object: the envelope merge below is jq's `+`, and jq
# cannot add an object and an array — it raises a runtime error, exit 5, and
# under `set -e` that was the whole cycle's exit. Not hypothetical: the one
# call site that passed an array (`enabler-stale-refs-skipped`, a guard that
# had never fired) took every node down in a pre-selection crash loop the
# first time it did (issue #361). So the logger holds the contract itself
# rather than trusting every call site to: a non-object payload is recorded
# wrapped under `fields` — the event still lands, readable, rather than
# vanishing — and the append is `|| true` because recording an event is never
# worth a cycle. stderr stays unredirected on the final jq for the same
# reason the wrap exists: if this still fails somehow, cron.log should show
# it, not swallow it.

# log_event_append LOG_FILE ID_FIELD ID_VALUE NODE EVENT [FIELDS_JSON]
log_event_append() {
  local log_file="$1" id_field="$2" id_value="$3" node="$4" event="$5" fields="${6:-{\}}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! jq -e 'type == "object"' <<<"$fields" >/dev/null 2>&1; then
    local wrapped
    wrapped="$(jq -c '{fields: .}' <<<"$fields" 2>/dev/null)" || true
    [[ -n "$wrapped" ]] || wrapped="$(jq -nc --arg f "$fields" '{fields: $f}')"
    fields="$wrapped"
  fi
  jq -nc --arg ts "$ts" --arg idf "$id_field" --arg idv "$id_value" \
    --arg node "$node" --arg event "$event" --argjson fields "$fields" \
    '{ts: $ts} + {($idf): $idv, node: $node, event: $event} + $fields' \
    >> "$log_file" || true
}
