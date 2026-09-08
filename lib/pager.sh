#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# SC2034: PAGER_EVAL_REPO/PAGER_EVAL_ESCALATION_LABEL/PAGER_REMEDY_REPO are
# set here for a dynamically-invoked EVAL_FN/remedy function to read (see
# this file's own header) — real, load-bearing reads shellcheck cannot see
# across an indirect call by name.
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
declare -ga PAGER_KEYS=()

# pager_register KEY EVAL_FN REMEDY_CLASS REMEDY_ARG
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
pager_register() {
  local key="$1" eval_fn="$2" remedy_class="$3" remedy_arg="${4:-}"
  case "$remedy_class" in
    pipeline-act|config-lever|owner-only) ;;
    *) printf 'pager_register: unknown remedy class: %s\n' "$remedy_class" >&2; return 1 ;;
  esac
  [[ -n "$key" && -n "$eval_fn" ]] || { printf 'pager_register: key and eval_fn are required\n' >&2; return 1; }
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

# _pager_create_issue REPO ITEM LABEL TITLE BODY_FILE ASSIGNEE
# Prints "<number>\t<url>"; prints nothing and returns 1 on failure. ASSIGNEE
# empty files unassigned (config-lever's tracking issue and pipeline-act's
# both do). Dedup: an open issue carrying LABEL whose body already contains
# ITEM is reused, on the same body-contains-item-ref convention every other
# escalation dedup in this codebase already uses.
_pager_create_issue() {
  local repo="$1" item="$2" label="$3" title="$4" body_file="$5" assignee="${6:-}"
  local gh existing raw url number
  gh="$(_pager_gh)"
  existing="$("$gh" issue list -R "$repo" --label "$label" --state open --search "$item" \
                --json number,url,body 2>/dev/null \
              | jq -r --arg it "$item" \
                  'map(select(((.body // "") | contains($it)))) | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf '%s' "$existing"
    return 0
  fi
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
  existing="$("$gh" issue list -R "$repo" --label "$label" --state all --search "$item" \
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
  found="$("$gh" issue list -R "$repo" --label "$label" --state open --search "$item" \
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
pager_file() {
  local key="$1" remedy_class="$2" remedy_arg="$3" evidence="$4" first_seen="$5" \
        pager_repo="$6" label="$7" assignee="$8" webhook_url="$9" log_file="${10}" \
        node="${11}" cycle="${12}" nodes_json="${13:-[]}"
  [[ -n "$pager_repo" ]] || return 0
  local item="pager:$key" body_file remedy_note="" created number url fields
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
  if created="$(_pager_create_issue "$pager_repo" "$item" "$label" "Pager: $key ($evidence)" \
        "$body_file" "$file_assignee")" && [[ -n "$created" ]]; then
    number="${created%%$'\t'*}"; url="${created#*$'\t'}"
    fields="$(jq -nc --arg k "$key" --arg fs "$first_seen" --arg e "$evidence" \
      --argjson n "$number" --arg u "$url" --arg rc "$remedy_class" --argjson nodes "$nodes_json" \
      '{key: $k, first_seen: $fs, evidence: $e, issue_number: $n, issue_url: $u,
        remedy_class: $rc, nodes: $nodes}')"
    pager_log_event "$log_file" "$node" "$cycle" "pager-fired" "$fields"
  else
    _pager_webhook_notify "$webhook_url" "$pager_repo" "$item" "Pager: $key" "$body_file" "$node" "$cycle"
  fi
  if [[ "$remedy_class" == "config-lever" ]]; then
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
#                     UNION_LOG_FILE FLEET_NODES_JSON NODE CYCLE
_pager_evaluate_one() {
  local key="$1" claim_script="$2" pager_repo="$3" label="$4" \
        escalation_label="$5" assignee="$6" webhook_url="$7" min_firing_minutes="$8" \
        log_file="$9" union_log_file="${10}" fleet_nodes_json="${11}" node="${12}" cycle="${13}"
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
      local cand first_seen first_seen_epoch age_min nodes_json
      cand="$(pager_last_event "$key" < "$union_log_file")"
      first_seen="$(jq -r '.first_seen // empty' <<<"$cand" 2>/dev/null)"
      [[ -n "$first_seen" ]] || first_seen="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      first_seen_epoch="$(date -u -d "$first_seen" +%s 2>/dev/null || date -u +%s)"
      age_min=$(( ( $(date -u +%s) - first_seen_epoch ) / 60 ))
      if (( age_min >= min_firing_minutes )); then
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
#                FLEET_NODES_JSON NODE CYCLE
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
