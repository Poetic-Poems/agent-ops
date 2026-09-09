#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# SC2034: PAGER_EVAL_REPO/PAGER_EVAL_ESCALATION_LABEL/PAGER_REMEDY_REPO,
# agent-ops#1282's PAGER_EVAL_CYCLE_INTERVAL_MINUTES/PAGER_EVAL_NODE_STALE_
# AFTER_MINUTES/PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES/PAGER_EVAL_DASHBOARD_
# FETCH_SECONDS/PAGER_EVAL_REVIEW_UNION_LOG_FILE, and agent-ops#1281's
# PAGER_EVAL_IDLE_CYCLES/PAGER_EVAL_REPAIR_RATE_PERCENT/PAGER_EVAL_ESCALATION_
# BURST/PAGER_REMEDY_LOG_FILE/PAGER_REMEDY_UNION_LOG_FILE/PAGER_REMEDY_NODE/
# PAGER_REMEDY_CYCLE, are set here for a dynamically-invoked EVAL_FN/remedy
# function to read (see this file's own header) — real, load-bearing reads
# this tool cannot see across an indirect call by name.
# SC2016: every backtick inside a single-quoted printf format string below is
# literal — deliberate Markdown code-span syntax for the issue body it
# builds, never a shell expansion shellcheck's heuristic mistakes it for.
#
# lib/pager.sh — fleet-level invariant evaluation, filing and auto-close
# (issue #1278, D21 follow-on to #608's Phase 2 health item).
#
# A registry of named **invariants** — each a pure function over facts every
# node already holds fleet-wide (the union fleet log, every peer's heartbeat,
# this node's own doctor verdict) — evaluated where those facts already
# converge: scripts/publish-dashboard.sh's own WITH_GITHUB tick of the
# Publisher's `*/5` pass (requirement 51 in docs/IMPLEMENTATION-PIPELINE-
# SPEC.md, requirement 20 in docs/DASHBOARD-SPEC.md's Publisher section).
# Exactly one node evaluates a given invariant in a given five-minute window
# — a claim on `<key>__<window>` through lib/claim.sh, the same pseudo-slug
# pattern the Enabler's own `claims/enabler/` uses (see lib/claim.sh's own
# header).
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh (the caller — scripts/publish-dashboard.sh — owns those).
# Deliberately independent of lib/enabler.sh: the Enabler's own
# `create_escalation_issue`/`create_decision_log_issue` read cycle-scoped
# globals (`cycle_dir`, `enabler_assignee`, `escalation_webhook_url`,
# `node_name`, `cycle_id`) that only exist inside agent-cycle.sh's own
# per-item cycle. The Publisher has no cycle and no item — this file mirrors
# those two functions' behaviour (the same dedup search, the same
# retry-without-label, the same webhook fallback) rather than reaching into
# a stage it does not run as.
#
# An invariant's lifecycle is event-sourced over the union log, exactly the
# transition-only convention lib/crash-loop.sh's `crash_loop_escalate`/
# `crash_loop_retire_resolved` and lib/decision-veto.sh already settled: a
# firing invariant re-evaluated every five minutes writes nothing new.
# Three transition events:
#
#   pager-candidate {key, first_seen}          firing seen for the first time
#   pager-candidate-cleared {key}               a candidate stopped firing
#                                                 before `pager_min_firing_
#                                                 minutes` elapsed — never
#                                                 announced, so nothing to
#                                                 retract, just a reset to
#                                                 "clear"
#   pager-fired {key, first_seen, evidence, …}  hysteresis elapsed; filed
#   pager-cleared {key, cleared_at, evidence}    the fact cleared; closed
#
# `pager_state_for`/`pager_last_event` derive the current state purely from
# the latest of these four event names for a key — no state file, no cache:
# any node can evaluate any invariant in any window and agree with every
# other node about what has already happened, on the same terms
# `token_expiry_escalated_for` (lib/token-expiry.sh) already does for a
# single-shot escalation.
#
# Remedy classes (the issue's own "Remedy by class"): every firing invariant
# that reaches the hysteresis threshold gets ONE issue per key, in
# `pager_repo`, carrying the fixed `pw::pager` label (lib/labels.sh's
# `escalation` role catalogue) — deduped on the key exactly as
# `create_escalation_issue` dedupes on an item reference, so a second
# evaluation of an already-firing invariant files nothing. What differs by
# class:
#
#   pipeline-act   REMEDY_ARG names a shell function, `REMEDY_ARG KEY
#                  EVIDENCE`, called before filing. It performs the fix
#                  directly (never asks) and prints one line describing what
#                  it did, embedded in the issue body under "## Remedy
#                  taken". The issue itself is filed unassigned — a record,
#                  not a request.
#   config-lever   REMEDY_ARG is prose. The pw::pager issue is filed
#                  unassigned as the tracking record, and a second, separate
#                  `pw::decision` issue is filed via the same
#                  filed-closed-immediately convention
#                  `create_decision_log_issue` (lib/enabler.sh) uses — the
#                  decide-tactical seam's own durable record, complete with
#                  the veto window a human reopening it gives (#937).
#   owner-only     REMEDY_ARG is prose (what the owner must decide). The
#                  pw::pager issue is assigned to PAGER_ASSIGNEE — the load-
#                  bearing half, exactly as for an ordinary Enabler
#                  escalation: assignment is what excludes it from the
#                  `issues` work source (requirement 16.4).
#
# Configuration is read by the caller and handed in as explicit parameters —
# this file has no config_defaults call of its own, so it stays testable
# against a plain fixture with no config.json on disk at all.

# --- The registry ------------------------------------------------------------
declare -gA PAGER_EVAL_FN=()
declare -gA PAGER_REMEDY_CLASS=()
declare -gA PAGER_REMEDY_ARG=()
declare -gA PAGER_MIN_FIRING_MINUTES_OVERRIDE=()
declare -ga PAGER_KEYS=()

# pager_register KEY EVAL_FN REMEDY_CLASS REMEDY_ARG [MIN_FIRING_MINUTES_OVERRIDE]
# EVAL_FN is a shell function, `EVAL_FN FLEET_NODES_JSON UNION_LOG_FILE`,
# called with the union log as EVAL_FN's own stdin is *not* used — it takes
# the path so a pure jq reader can `-R -n` it directly without this framework
# forking a second copy of a potentially large stream through a pipe.
# EVAL_FN must print exactly one line, `{"firing": bool, "evidence": "…"}`
# (evidence non-empty only when firing), plus an optional `"nodes": [...]`
# naming which fleet nodes the evidence is about — the dashboard's own node
# card badge (docs/DASHBOARD-SPEC.md) reads it to know which card to mark,
# rather than parsing EVIDENCE's own prose. Nothing else, ever — a raising
# invariant must never abort the evaluation of every invariant registered
# after it. REMEDY_CLASS is one of pipeline-act, config-lever, owner-only;
# REMEDY_ARG's meaning depends on it (see this file's header). Re-registering
# an existing KEY replaces its entry — the last registration wins, which lets
# a caller (or a test) override a built-in invariant's eval function without
# needing a separate unregister.
#
# MIN_FIRING_MINUTES_OVERRIDE, when non-empty, replaces `pager_evaluate`'s own
# MIN_FIRING_MINUTES for this key alone — agent-ops#1282's `node-stale`, whose
# fact (a publication age already past `2 × node_stale_after_minutes`) is
# itself slow-forming, needs a filing wait measured in hours
# (`pager_stale_file_after_minutes`) rather than the framework's own
# blip-sized default. Every other registered key is unaffected: an empty
# override (the default, and every call site before agent-ops#1282) falls
# through to `pager_evaluate`'s own parameter exactly as before.
pager_register() {
  local key="$1" eval_fn="$2" remedy_class="$3" remedy_arg="${4:-}" \
        min_firing_override="${5:-}"
  case "$remedy_class" in
    pipeline-act|config-lever|owner-only) ;;
    *) printf 'pager_register: unknown remedy class: %s\n' "$remedy_class" >&2; return 1 ;;
  esac
  [[ -n "$key" && -n "$eval_fn" ]] || { printf 'pager_register: key and eval_fn are required\n' >&2; return 1; }
  PAGER_MIN_FIRING_MINUTES_OVERRIDE["$key"]="$min_firing_override"
  local k seen=0
  for k in "${PAGER_KEYS[@]}"; do [[ "$k" == "$key" ]] && { seen=1; break; }; done
  (( seen )) || PAGER_KEYS+=("$key")
  PAGER_EVAL_FN["$key"]="$eval_fn"
  PAGER_REMEDY_CLASS["$key"]="$remedy_class"
  PAGER_REMEDY_ARG["$key"]="$remedy_arg"
}

# pager_registered_keys — one registered key per line, in registration order.
pager_registered_keys() {
  local k
  for k in "${PAGER_KEYS[@]}"; do printf '%s\n' "$k"; done
}

# --- Event log helpers ---------------------------------------------------------
# pager_log_event LOG_FILE NODE CYCLE EVENT FIELDS_JSON
# The same envelope agent-cycle.sh's own log_event writes — {ts, cycle, node,
# event} + FIELDS_JSON — appended to LOG_FILE. `|| true`: recording a pager
# transition is never worth failing a publish tick over.
pager_log_event() {
  local log_file="$1" node="$2" cycle="$3" event="$4" fields="${5:-{\}}"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -nc --arg ts "$ts" --arg cycle "$cycle" --arg node "$node" --arg event "$event" \
    --argjson fields "$fields" '{ts: $ts, cycle: $cycle, node: $node, event: $event} + $fields' \
    >> "$log_file" 2>/dev/null || true
}

# pager_last_event KEY < union.jsonl
# The most recent (by ts) pager-candidate/pager-candidate-cleared/pager-fired/
# pager-cleared event for KEY, or nothing.
pager_last_event() {
  local key="$1"
  jq -c -R -n --arg k "$key" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "pager-candidate" or .event == "pager-candidate-cleared"
               or .event == "pager-fired" or .event == "pager-cleared")
      | select((.key // "") == $k) ]
    | sort_by(.ts) | last // empty
  ' 2>/dev/null || true
}

# pager_state_for KEY < union.jsonl -> clear|candidate|fired
pager_state_for() {
  local key="$1" last event
  last="$(pager_last_event "$key")"
  [[ -n "$last" ]] || { printf 'clear'; return 0; }
  event="$(jq -r '.event' <<<"$last" 2>/dev/null)"
  case "$event" in
    pager-fired) printf 'fired' ;;
    pager-candidate) printf 'candidate' ;;
    *) printf 'clear' ;;
  esac
}

# --- Issue primitives (mirror lib/enabler.sh's create_escalation_issue /
# create_decision_log_issue; see this file's header for why they are not
# reused directly) --------------------------------------------------------------

# _pager_gh -> which `gh` to call. PAGER_GH is the test seam, matching
# lib/claim.sh's CLAIM_GH and lib/labels.sh's LABELS_GH.
_pager_gh() { printf '%s' "${PAGER_GH:-gh}"; }

# _pager_webhook_notify URL REPO ITEM TITLE BODY_FILE NODE CYCLE
# Best-effort fallback, parameterised twin of lib/enabler.sh's
# escalation_webhook_notify. A no-op when URL is empty.
_pager_webhook_notify() {
  local url="$1" repo="$2" item="$3" title="$4" body_file="$5" node="$6" cycle="$7"
  [[ -n "$url" ]] || return 0
  local detail payload
  detail="$(cat "$body_file" 2>/dev/null || true)"
  payload="$(jq -nc --arg reason "$title" --arg detail "$detail" --arg repo "$repo" \
    --arg item "$item" --arg node "$node" --arg cycle "$cycle" \
    '{reason: $reason, detail: $detail, repo: $repo, item: $item, node: $node, cycle: $cycle}' 2>/dev/null)" \
    || return 0
  curl -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
    --data-binary "$payload" "$url" >/dev/null 2>&1 || true
  return 0
}

# _pager_ensure_label_role REPO ROLE
# Ensure ROLE's label catalogue exists in REPO, on the create path only —
# lib/enabler.sh's create_escalation_issue does exactly this, for exactly the
# reason it states: an escalation repository "is often not one the cycle
# otherwise touches (`crash_loop_repo` by construction is not), so its label
# has nowhere else to be ensured". `pager_repo` falls back to
# `crash_loop_repo`, so by that same construction nothing else would ever
# create `pw::pager`.
#
# Here the label is load-bearing rather than cosmetic, which is why this is
# not merely a nicety: both _pager_create_issue's own dedup and
# _pager_close_issue find a page by its label, so an issue filed by the
# retry-without-label path below would be re-filed on every later fire and
# never auto-closed when the fact clears — the page would outlive its own
# invariant on the owner's open list, the one outcome requirement 51 exists
# to prevent.
#
# Guarded by `declare -F` and a ROLE that may be empty, so this file stays
# sourceable on its own against a plain fixture with no lib/labels.sh and no
# config.json (see this file's header). A caller that has not sourced
# lib/labels.sh gets the previous behaviour exactly.
_pager_ensure_label_role() {
  local repo="$1" role="${2:-}"
  [[ -n "$repo" && -n "$role" ]] || return 0
  declare -F labels_ensure_role >/dev/null 2>&1 || return 0
  labels_ensure_role "${CONFIG_FILE:-}" "${SCHEMA_FILE:-}" "$repo" "$role" >/dev/null 2>&1 || true
  return 0
}

# _pager_create_issue REPO ITEM LABEL TITLE BODY_FILE ASSIGNEE [ENSURE_ROLE]
# Prints "<number>\t<url>"; prints nothing and returns 1 on failure. ASSIGNEE
# empty files unassigned (config-lever's tracking issue and pipeline-act's
# both do). Dedup: an open issue carrying LABEL whose body already contains
# ITEM is reused, on the same body-contains-item-ref convention every other
# escalation dedup in this codebase already uses. ENSURE_ROLE, when given, is
# the lib/labels.sh catalogue role that owns LABEL, ensured in REPO on the
# create path only (see _pager_ensure_label_role); omitted, nothing is
# ensured and the retry-without-label below is the only safety net.
_pager_create_issue() {
  local repo="$1" item="$2" label="$3" title="$4" body_file="$5" assignee="${6:-}" \
        ensure_role="${7:-}"
  local gh existing raw url number
  gh="$(_pager_gh)"
  existing="$("$gh" issue list -R "$repo" --label "$label" --state open --search "$item" --limit 200 \
                --json number,url,body 2>/dev/null \
              | jq -r --arg it "$item" \
                  'map(select(((.body // "") | contains($it)))) | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi
  # Only on the path that actually creates — costs nothing on the dedup path
  # above, which is the common one.
  _pager_ensure_label_role "$repo" "$ensure_role"
  if [[ -n "$assignee" ]]; then
    raw="$("$gh" issue create -R "$repo" --title "$title" --body-file "$body_file" \
             --assignee "$assignee" --label "$label" 2>/dev/null || true)"
    [[ -n "$raw" ]] || raw="$("$gh" issue create -R "$repo" --title "$title" --body-file "$body_file" \
             --assignee "$assignee" 2>/dev/null || true)"
  else
    raw="$("$gh" issue create -R "$repo" --title "$title" --body-file "$body_file" \
             --label "$label" 2>/dev/null || true)"
    [[ -n "$raw" ]] || raw="$("$gh" issue create -R "$repo" --title "$title" --body-file "$body_file" \
             2>/dev/null || true)"
  fi
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  [[ -n "$url" ]] || return 1
  number="${url##*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$number" "$url"
}

# _pager_create_decision_log_issue REPO ITEM LABEL TITLE BODY_FILE REASON_KEY
# Parameterised twin of lib/enabler.sh's create_decision_log_issue: dedup
# across all states (a decision log is filed closed and stays closed until a
# human vetoes it by reopening), narrowed by REASON_KEY exactly as that
# function's own header explains (a fresh reason_key needs a fresh issue,
# never the previous decision's own closed record).
_pager_create_decision_log_issue() {
  local repo="$1" item="$2" label="$3" title="$4" body_file="$5" reason_key="${6:-}"
  local gh existing raw url number
  gh="$(_pager_gh)"
  existing="$("$gh" issue list -R "$repo" --label "$label" --state all --search "$item" --limit 200 \
                --json number,url,body 2>/dev/null \
              | jq -r --arg it "$item" --arg rk "$reason_key" \
                  'map(select(((.body // "") | contains($it))
                             and (($rk == "") or ((.body // "") | contains("reason_key=" + $rk)))))
                   | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi
  # `pw::decision` is load-bearing twice over: this function's own dedup finds
  # a prior decision by it, and scripts/sweep-decision-vetoes.sh is what reads
  # it across every configured repository to notice a human's reopen-as-veto
  # (#937). Unlike _pager_create_issue there is no retry-without-label here —
  # a decision record nobody can sweep for a veto is worse than none — so the
  # ensure is what makes the create succeed at all in a repository that has
  # never carried the label.
  _pager_ensure_label_role "$repo" escalation
  raw="$("$gh" issue create -R "$repo" --title "$title" --body-file "$body_file" \
           --label "$label" 2>/dev/null || true)"
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  [[ -n "$url" ]] || return 1
  number="${url##*/}"
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  "$gh" issue close "$number" -R "$repo" >/dev/null 2>&1 || true
  printf '%s\t%s' "$number" "$url"
}

# _pager_close_issue REPO LABEL ITEM COMMENT
# The auto-close-on-clear primitive, the pattern lib/approver.sh's
# `approver_escalation_retire` established (#1215): find the open issue
# carrying LABEL whose body names ITEM — never one a human has reopened
# (`stateReason == "reopened"` wins, always) — and close it with a one-line
# comment naming what cleared it. Prints "<number>\t<url>" on an actual
# close; nothing (not an error) when there is no open issue to close, since
# "already closed, nothing to do" is not a failure.
_pager_close_issue() {
  local repo="$1" label="$2" item="$3" comment="$4"
  local gh found number url
  gh="$(_pager_gh)"
  found="$("$gh" issue list -R "$repo" --label "$label" --state open --search "$item" --limit 200 \
             --json number,url,body,stateReason 2>/dev/null \
           | jq -r --arg it "$item" \
               'map(select(((.body // "") | contains($it)) and (.stateReason != "reopened"))) | first
                | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  [[ -n "$found" ]] || return 0
  number="${found%%$'\t'*}"; url="${found#*$'\t'}"
  "$gh" issue close "$number" -R "$repo" --comment "$comment" >/dev/null 2>&1 \
    && printf '%s\t%s' "$number" "$url"
  return 0
}

# --- Fire / close ----------------------------------------------------------------

# pager_file KEY REMEDY_CLASS REMEDY_ARG EVIDENCE FIRST_SEEN PAGER_REPO \
#            LABEL ASSIGNEE WEBHOOK_URL LOG_FILE NODE CYCLE [NODES_JSON]
# Performs the remedy (pipeline-act) and/or files the pw::pager tracking
# issue (config-lever, owner-only; pipeline-act files one too, unassigned,
# recording what it did), then logs pager-fired. A failed filing logs
# nothing — the invariant stays "candidate" and the next window's evaluation
# tries again, exactly as crash_loop_escalate's own dedup-then-retry does.
#
# PAGER_REPO empty is not a failure and must not be treated as one: it is an
# installation that has configured no repository to file into, which
# requirement 51 states still gets the transition on its dashboard ("nothing
# is filed or assigned" — not "nothing happens"). This is the whole reason
# `pager_enabled` exists as a boolean rather than reusing `pager_repo` empty
# as the off switch the way `crash_loop_repo` does, so the transition has to
# actually be logged: an early return here would leave the key `candidate`
# for ever, never firing on the dashboard and never able to clear, and would
# make that documented distinction between the two keys purely notional.
pager_file() {
  local key="$1" remedy_class="$2" remedy_arg="$3" evidence="$4" first_seen="$5" \
        pager_repo="$6" label="$7" assignee="$8" webhook_url="$9" log_file="${10}" \
        node="${11}" cycle="${12}" nodes_json="${13:-[]}"
  local item="pager:$key" body_file remedy_note="" created number="" url="" fields logged=0
  body_file="$(mktemp)"
  if [[ "$remedy_class" == "pipeline-act" && -n "$remedy_arg" ]]; then
    # Same unexported-variable handoff _pager_evaluate_one uses for EVAL_FN:
    # a remedy function is a plain bash function, called via command
    # substitution, so it sees these without needing `export`.
    PAGER_REMEDY_REPO="$pager_repo"
    remedy_note="$("$remedy_arg" "$key" "$evidence" 2>/dev/null || true)"
  fi
  {
    printf '## What fired\n\n%s\n\n' "$evidence"
    printf -- '- first seen: `%s`\n\n' "$first_seen"
    case "$remedy_class" in
      pipeline-act)
        printf '## Remedy taken\n\n%s\n\n' "${remedy_note:-(the automatic remedy could not run — see cron.log)}"
        ;;
      config-lever)
        printf '## Remedy\n\n%s\n\nA `pw::decision` record is filed separately under `escalation_autonomy: decide-tactical`.\n\n' "$remedy_arg"
        ;;
      owner-only)
        printf '## What the owner needs to decide\n\n%s\n\n' "$remedy_arg"
        ;;
    esac
    printf -- '---\nFiled automatically by lib/pager.sh (issue #1278).\nref: %s\n' "$item"
  } > "$body_file"
  local file_assignee=""
  [[ "$remedy_class" == "owner-only" ]] && file_assignee="$assignee"
  if [[ -z "$pager_repo" ]]; then
    logged=1  # nothing to file into; the transition is still the fact
  elif created="$(_pager_create_issue "$pager_repo" "$item" "$label" "Pager: $key ($evidence)" \
        "$body_file" "$file_assignee" escalation)" && [[ -n "$created" ]]; then
    number="${created%%$'\t'*}"; url="${created#*$'\t'}"
    logged=1
  else
    _pager_webhook_notify "$webhook_url" "$pager_repo" "$item" "Pager: $key" "$body_file" "$node" "$cycle"
  fi
  if (( logged )); then
    # `issue_number`/`issue_url` are null rather than absent on the no-repo
    # path, so the dashboard's own reader (which already defaults both) and a
    # human reading the union log see "fired, nothing filed" rather than a
    # record that looks truncated.
    fields="$(jq -nc --arg k "$key" --arg fs "$first_seen" --arg e "$evidence" \
      --arg n "$number" --arg u "$url" --arg rc "$remedy_class" --argjson nodes "$nodes_json" \
      '{key: $k, first_seen: $fs, evidence: $e,
        issue_number: (if $n == "" then null else ($n | tonumber) end),
        issue_url: (if $u == "" then null else $u end),
        remedy_class: $rc, nodes: $nodes}')"
    pager_log_event "$log_file" "$node" "$cycle" "pager-fired" "$fields"
  fi
  if [[ "$remedy_class" == "config-lever" && -n "$pager_repo" ]]; then
    local dec_body dec_created
    dec_body="$(mktemp)"
    {
      printf '## Tactical decision: %s\n\n%s\n\n%s\n\n' "$key" "$evidence" "$remedy_arg"
      printf 'Reopening this issue vetoes the decision (#937).\n\n'
      printf -- '---\nref: %s\nreason_key=pager-%s\n' "$item" "$key"
    } > "$dec_body"
    dec_created="$(_pager_create_decision_log_issue "$pager_repo" "$item" "pw::decision" \
      "Pager decision: $key" "$dec_body" "pager-$key" 2>/dev/null || true)"
    rm -f "$dec_body"
    [[ -n "$dec_created" ]] || _pager_webhook_notify "$webhook_url" "$pager_repo" "$item" \
      "Pager decision: $key" "$body_file" "$node" "$cycle"
  fi
  rm -f "$body_file"
}

# pager_close KEY EVIDENCE PAGER_REPO LABEL LOG_FILE NODE CYCLE
# The fact behind KEY has cleared: close its pw::pager tracking issue with a
# one-line comment, and log pager-cleared regardless of whether an issue was
# actually found to close (a webhook-only filing, or one a human already
# closed by hand, must still let the key return to "clear" — the log is the
# durable half of this framework's own state machine; the issue is a mirror
# of it, not the other way round).
pager_close() {
  local key="$1" evidence="$2" pager_repo="$3" label="$4" log_file="$5" node="$6" cycle="$7"
  local item="pager:$key" comment fields cleared_at
  cleared_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  comment="This invariant's fact has cleared. Retiring this page.

---
Retired automatically by lib/pager.sh (issue #1278)."
  if [[ -n "$pager_repo" ]]; then
    _pager_close_issue "$pager_repo" "$label" "$item" "$comment" >/dev/null 2>&1 || true
  fi
  fields="$(jq -nc --arg k "$key" --arg ca "$cleared_at" --arg e "$evidence" \
    '{key: $k, cleared_at: $ca, evidence: $e}')"
  pager_log_event "$log_file" "$node" "$cycle" "pager-cleared" "$fields"
}

# --- Evaluation --------------------------------------------------------------

# _pager_evaluate_one KEY CLAIM_SCRIPT PAGER_REPO LABEL ESCALATION_LABEL \
#                     ASSIGNEE WEBHOOK_URL MIN_FIRING_MINUTES LOG_FILE \
#                     UNION_LOG_FILE FLEET_NODES_JSON NODE CYCLE \
#                     [CYCLE_INTERVAL_MINUTES] [NODE_STALE_AFTER_MINUTES] \
#                     [UPDATER_STUCK_AFTER_MINUTES] [DASHBOARD_FETCH_SECONDS] \
#                     [REVIEW_UNION_LOG_FILE] [IDLE_CYCLES] \
#                     [REPAIR_RATE_PERCENT] [ESCALATION_BURST]
# The five trailing parameters through REVIEW_UNION_LOG_FILE exist for
# agent-ops#1282's peer-vantage invariants; the three after them
# (IDLE_CYCLES/REPAIR_RATE_PERCENT/ESCALATION_BURST) are agent-ops#1281's own
# selection/ledger thresholds — see PAGER_EVAL_CYCLE_INTERVAL_MINUTES and its
# siblings, set just below, and this file's own header for why they travel as
# plain variables rather than through EVAL_FN's two-argument contract. Every
# call site before #1282, and every existing test, omits them; an omitted
# trailing bash positional parameter reads as empty, which every EVAL_FN that
# reads one treats as "nothing configured — never fire".
_pager_evaluate_one() {
  local key="$1" claim_script="$2" pager_repo="$3" label="$4" \
        escalation_label="$5" assignee="$6" webhook_url="$7" min_firing_minutes="$8" \
        log_file="$9" union_log_file="${10}" fleet_nodes_json="${11}" node="${12}" cycle="${13}" \
        cycle_interval_minutes="${14:-}" node_stale_after_minutes="${15:-}" \
        updater_stuck_after_minutes="${16:-}" dashboard_fetch_seconds="${17:-}" \
        review_union_log_file="${18:-}" idle_cycles="${19:-}" \
        repair_rate_percent="${20:-}" escalation_burst="${21:-}"
  local eval_fn remedy_class remedy_arg window claim_key claim_rc
  eval_fn="${PAGER_EVAL_FN[$key]}"
  remedy_class="${PAGER_REMEDY_CLASS[$key]}"
  remedy_arg="${PAGER_REMEDY_ARG[$key]}"
  [[ -n "$eval_fn" ]] || return 0

  window="$(( $(date -u +%s) / 300 ))"
  claim_key="${key}__${window}"
  CLAIM_GH="$(_pager_gh)" CLAIM_NODE="$node" CLAIM_CYCLE="$cycle" \
    CLAIM_ITEM="$key" CLAIM_SOURCE="pager" \
    "$claim_script" claim file pager "$claim_key" >/dev/null 2>&1
  claim_rc=$?
  # 0 won, 3 lost (a peer already has this window), 1 error (fail closed —
  # never evaluate on the strength of an unreachable claim, the same rule
  # lib/claim.sh's own header states for every caller).
  (( claim_rc == 0 )) || return 0

  local verdict firing evidence state
  # A handful of built-in invariants (page-outlived-item) need to read
  # GitHub directly — the fact they evaluate (an issue's own item having
  # gone terminal) is not anything any node's heartbeat or union log
  # replicates. Set as plain (unexported) shell variables rather than
  # threaded through EVAL_FN's own two-arg contract, so an ordinary pure
  # invariant's signature stays exactly `EVAL_FN FLEET_NODES_JSON
  # UNION_LOG_FILE` and only the exceptions need to know these exist — a
  # bash function called via command substitution inherits its caller's
  # whole variable set regardless of export, the same reason CLAIM_*
  # elsewhere in this codebase needs no `export` either.
  PAGER_EVAL_REPO="$pager_repo"
  PAGER_EVAL_ESCALATION_LABEL="$escalation_label"
  # agent-ops#1282's five peer-vantage invariants: none of these thresholds
  # (or, for review-pipeline-failing, the review-log union path) is a fact
  # any heartbeat or the implementation union log carries, so — the same
  # documented exception as PAGER_EVAL_REPO above — each travels as a plain
  # variable rather than a third EVAL_FN argument every other invariant
  # would then have to ignore.
  PAGER_EVAL_CYCLE_INTERVAL_MINUTES="$cycle_interval_minutes"
  PAGER_EVAL_NODE_STALE_AFTER_MINUTES="$node_stale_after_minutes"
  PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES="$updater_stuck_after_minutes"
  PAGER_EVAL_DASHBOARD_FETCH_SECONDS="$dashboard_fetch_seconds"
  PAGER_EVAL_REVIEW_UNION_LOG_FILE="$review_union_log_file"
  # agent-ops#1281's own three: idle-with-demand's cycle-count window,
  # work-order-repaired-rate's percentage threshold, escalation-burst's own
  # 24h count threshold — the identical documented-exception pattern above,
  # one plain variable per threshold `pager_evaluate` cannot derive from
  # either of EVAL_FN's own two arguments.
  PAGER_EVAL_IDLE_CYCLES="$idle_cycles"
  PAGER_EVAL_REPAIR_RATE_PERCENT="$repair_rate_percent"
  PAGER_EVAL_ESCALATION_BURST="$escalation_burst"
  # A pipeline-act remedy that needs to log its own union-log event (rather
  # than merely call `gh` directly, the way verdict-unanimous/page-outlived-
  # item's remedies do) has no other way to reach LOG_FILE/NODE/CYCLE: REMEDY_ARG's
  # own contract (`pager_file`'s header) is `REMEDY_ARG KEY EVIDENCE`, nothing
  # else. Set here, not only in `pager_file`, so a remedy needing the union
  # log itself (to re-derive candidates rather than parse EVIDENCE's own
  # prose — the same `_pager_open_page_issues` discipline every remedy here
  # already follows) has it too.
  PAGER_REMEDY_LOG_FILE="$log_file"
  PAGER_REMEDY_UNION_LOG_FILE="$union_log_file"
  PAGER_REMEDY_NODE="$node"
  PAGER_REMEDY_CYCLE="$cycle"
  verdict="$("$eval_fn" "$fleet_nodes_json" "$union_log_file" 2>/dev/null)"
  firing="$(jq -r '.firing // false' <<<"$verdict" 2>/dev/null)"
  evidence="$(jq -r '.evidence // ""' <<<"$verdict" 2>/dev/null)"
  [[ "$firing" == "true" ]] || firing="false"
  state="$(pager_state_for "$key" < "$union_log_file")"

  case "${state}:${firing}" in
    clear:true)
      pager_log_event "$log_file" "$node" "$cycle" "pager-candidate" \
        "$(jq -nc --arg k "$key" --arg fs "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{key: $k, first_seen: $fs}')"
      ;;
    candidate:true)
      local cand first_seen first_seen_epoch age_min nodes_json key_min_firing_minutes
      cand="$(pager_last_event "$key" < "$union_log_file")"
      first_seen="$(jq -r '.first_seen // empty' <<<"$cand" 2>/dev/null)"
      [[ -n "$first_seen" ]] || first_seen="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      first_seen_epoch="$(date -u -d "$first_seen" +%s 2>/dev/null || date -u +%s)"
      age_min=$(( ( $(date -u +%s) - first_seen_epoch ) / 60 ))
      key_min_firing_minutes="${PAGER_MIN_FIRING_MINUTES_OVERRIDE[$key]:-}"
      [[ -n "$key_min_firing_minutes" ]] || key_min_firing_minutes="$min_firing_minutes"
      if (( age_min >= key_min_firing_minutes )); then
        nodes_json="$(jq -c '.nodes // []' <<<"$verdict" 2>/dev/null)"
        [[ -n "$nodes_json" ]] || nodes_json='[]'
        pager_file "$key" "$remedy_class" "$remedy_arg" "$evidence" "$first_seen" \
          "$pager_repo" "$label" "$assignee" "$webhook_url" "$log_file" "$node" "$cycle" "$nodes_json"
      fi
      ;;
    candidate:false)
      pager_log_event "$log_file" "$node" "$cycle" "pager-candidate-cleared" \
        "$(jq -nc --arg k "$key" '{key: $k}')"
      ;;
    fired:false)
      pager_close "$key" "$evidence" "$pager_repo" "$label" "$log_file" "$node" "$cycle"
      ;;
    *) ;;  # fired:true, clear:false — transition-only, nothing new to write
  esac
}

# pager_evaluate CLAIM_SCRIPT PAGER_REPO LABEL ESCALATION_LABEL ASSIGNEE \
#                WEBHOOK_URL MIN_FIRING_MINUTES LOG_FILE UNION_LOG_FILE \
#                FLEET_NODES_JSON NODE CYCLE [CYCLE_INTERVAL_MINUTES] \
#                [NODE_STALE_AFTER_MINUTES] [UPDATER_STUCK_AFTER_MINUTES] \
#                [DASHBOARD_FETCH_SECONDS] [REVIEW_UNION_LOG_FILE] \
#                [IDLE_CYCLES] [REPAIR_RATE_PERCENT] [ESCALATION_BURST]
# The eight trailing, optional parameters are agent-ops#1282's and
# agent-ops#1281's own — see _pager_evaluate_one's own header for why they
# exist and why omitting them (every call site before #1282) is safe.
# Evaluates every registered invariant once, in registration order. One bad
# EVAL_FN or one lost claim never stops the rest — each invariant's own
# failure is contained to itself, the same isolation crash_loop_verdict's own
# `2>/dev/null || true` gives a torn union-log line.
pager_evaluate() {
  local key
  for key in "${PAGER_KEYS[@]}"; do
    _pager_evaluate_one "$key" "$@" || true
  done
}
