#!/usr/bin/env bash
#
# test/pager.test.sh — lib/pager.sh's own framework: the registry, the
# event-sourced state machine (clear/candidate/fired), and the three remedy
# classes (agent-ops#1278).
#
# Everything with a side effect outside the process is stubbed: `gh` (issue
# list/create/close), and a stand-in for lib/claim.sh's own `claim file`
# dispatch — controllable via CLAIM_STUB_RC — since this file's own job is
# pager.sh's state machine, not lib/claim.sh's contention behaviour (covered
# by test/claim.test.sh). A pipeline-act remedy function is stubbed too, with
# its call count tracked through a file rather than a plain variable, on
# test/crash-loop-escalate.test.sh's own precedent: every real call site
# invokes it via command substitution, a subshell a plain variable set inside
# would not survive.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/pager.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/pager.sh
. "$SCRIPT_DIR/lib/pager.sh"

failures=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Test doubles ------------------------------------------------------------

CLAIM_STUB="$WORKDIR/claim-stub.sh"
cat > "$CLAIM_STUB" <<'EOF'
#!/usr/bin/env bash
exit "${CLAIM_STUB_RC:-0}"
EOF
chmod +x "$CLAIM_STUB"

GH_CALLS_FILE="$WORKDIR/gh-calls"
: > "$GH_CALLS_FILE"
STUB_GH_LIST_OPEN="[]"     # `gh issue list --state open ...` result
STUB_GH_LIST_ALL="[]"      # `gh issue list --state all ...` result (decision-log dedup)
STUB_GH_CREATE_URL="https://github.com/o/r/issues/501"
STUB_GH_CREATE_FAIL=""
STUB_GH_CLOSE_MODE="success"
# Every real call site invokes `gh` through a command substitution
# ($(...)), a subshell — so anything this stub needs a later assertion to
# see must go through a file, on test/crash-loop-escalate.test.sh's own
# precedent, never a plain variable, which would vanish with the subshell.
STUB_GH_LAST_BODY_FILE="$WORKDIR/gh-last-body"
: > "$STUB_GH_LAST_BODY_FILE"
gh() {
  printf '%s\n' "$*" >> "$GH_CALLS_FILE"
  case "$1 $2" in
    "issue list")
      if [[ " $* " == *" all "* ]]; then printf '%s' "$STUB_GH_LIST_ALL"
      else printf '%s' "$STUB_GH_LIST_OPEN"; fi
      return 0 ;;
    "issue create")
      # Capture the --body-file's own content, the way a real create would
      # read it, so a test can assert on what actually went into the issue.
      local a next=""
      for a in "$@"; do
        if [[ "$next" == "body-file" ]]; then cat "$a" > "$STUB_GH_LAST_BODY_FILE" 2>/dev/null || true; next=""; fi
        [[ "$a" == "--body-file" ]] && next="body-file"
      done
      [[ -z "$STUB_GH_CREATE_FAIL" ]] || return 1
      printf 'created: %s\n' "$STUB_GH_CREATE_URL"
      return 0 ;;
    "issue close")
      [[ "$STUB_GH_CLOSE_MODE" == "success" ]] ;;
    *) return 1 ;;
  esac
}

REMEDY_CALLS_FILE="$WORKDIR/remedy-calls"
: > "$REMEDY_CALLS_FILE"
STUB_REMEDY_OUTPUT="did the thing"
STUB_REMEDY_FAIL=""
stub_remedy() {
  printf 'x\n' >> "$REMEDY_CALLS_FILE"
  [[ -z "$STUB_REMEDY_FAIL" ]] || return 1
  printf '%s' "$STUB_REMEDY_OUTPUT"
}
remedy_calls() { wc -l < "$REMEDY_CALLS_FILE" | tr -d ' '; }

STUB_FIRING="true"
STUB_EVIDENCE="the sky is falling"
stub_eval() {
  if [[ "$STUB_FIRING" == "true" ]]; then
    jq -nc --arg e "$STUB_EVIDENCE" '{firing: true, evidence: $e}'
  else
    printf '{"firing":false}'
  fi
}

count_events() {  # count_events LOG_FILE EVENT_NAME [KEY]
  local log="$1" name="$2" key="${3:-}"
  jq -R -n --arg n "$name" --arg k "$key" \
    '[inputs | select(length>0) | fromjson? // empty
      | select(.event == $n and ($k == "" or (.key // "") == $k))] | length' \
    < "$log" 2>/dev/null
}
last_event() {  # last_event LOG_FILE EVENT_NAME KEY
  local log="$1" name="$2" key="$3"
  jq -R -n --arg n "$name" --arg k "$key" \
    '[inputs | select(length>0) | fromjson? // empty
      | select(.event == $n and (.key // "") == $k)] | sort_by(.ts) | last // empty' \
    < "$log" 2>/dev/null
}

# --- pager_register -----------------------------------------------------------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
if pager_register "" stub_eval pipeline-act "" 2>/dev/null; then
  printf 'FAIL - an empty key is refused\n'; failures=$(( failures + 1 ))
else
  printf 'ok   - an empty key is refused\n'
fi
if pager_register k1 stub_eval nonsense-class "" 2>/dev/null; then
  printf 'FAIL - an unknown remedy class is refused\n'; failures=$(( failures + 1 ))
else
  printf 'ok   - an unknown remedy class is refused\n'
fi
pager_register k1 stub_eval pipeline-act stub_remedy
pager_register k2 stub_eval owner-only "decide this"
assert_eq "registered keys, in registration order" "k1 k2" "$(pager_registered_keys | tr '\n' ' ' | sed 's/ $//')"
pager_register k1 stub_eval owner-only "changed my mind"
assert_eq "re-registering a key replaces it rather than duplicating" "k1 k2" "$(pager_registered_keys | tr '\n' ' ' | sed 's/ $//')"
assert_eq "  ... and the new registration wins" "owner-only" "${PAGER_REMEDY_CLASS[k1]}"

# A fifth, optional argument (agent-ops#1282) — MIN_FIRING_MINUTES_OVERRIDE,
# `node-stale`'s own per-key filing-hysteresis override — records against the
# key; omitted (every call above), it stays empty rather than absent, so
# _pager_evaluate_one's own `${...:-}` lookup falls through to
# pager_evaluate's shared parameter unchanged.
assert_eq "an omitted override records as empty, not unset" "" "${PAGER_MIN_FIRING_MINUTES_OVERRIDE[k1]}"
pager_register k3 stub_eval owner-only "decide this too" 180
assert_eq "a given override records against the key" "180" "${PAGER_MIN_FIRING_MINUTES_OVERRIDE[k3]}"

# --- pager_state_for / pager_last_event ---------------------------------------

state_fixture="$WORKDIR/state-fixture.jsonl"
: > "$state_fixture"
assert_eq "no events at all reads clear" "clear" "$(pager_state_for demo < "$state_fixture")"
printf '{"ts":"2026-01-01T00:00:00Z","event":"pager-candidate","key":"demo","first_seen":"2026-01-01T00:00:00Z"}\n' >> "$state_fixture"
assert_eq "a candidate event reads candidate" "candidate" "$(pager_state_for demo < "$state_fixture")"
printf '{"ts":"2026-01-01T00:05:00Z","event":"pager-candidate-cleared","key":"demo"}\n' >> "$state_fixture"
assert_eq "a candidate-cleared event resets to clear" "clear" "$(pager_state_for demo < "$state_fixture")"
printf '{"ts":"2026-01-01T00:10:00Z","event":"pager-fired","key":"demo","first_seen":"2026-01-01T00:10:00Z","evidence":"x"}\n' >> "$state_fixture"
assert_eq "a fired event reads fired" "fired" "$(pager_state_for demo < "$state_fixture")"
printf '{"ts":"2026-01-01T00:20:00Z","event":"pager-cleared","key":"demo","cleared_at":"2026-01-01T00:20:00Z"}\n' >> "$state_fixture"
assert_eq "a cleared event reads clear again" "clear" "$(pager_state_for demo < "$state_fixture")"
assert_eq "a different key's events are ignored" "clear" "$(pager_state_for other < "$state_fixture")"

# --- End to end: fire (candidate) -> hysteresis -> fired -> clear ------------
# One invariant, pipeline-act, min_firing_minutes 0 so the very first
# candidate evaluation is already past hysteresis on the next tick.

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register demo stub_eval pipeline-act stub_remedy

union_log="$WORKDIR/e2e.jsonl"
: > "$union_log"
: > "$GH_CALLS_FILE"; : > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_CREATE_FAIL=""; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"

pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 1 (first firing): one pager-candidate, nothing filed" \
  "1" "$(count_events "$union_log" pager-candidate demo)"
assert_eq "  ... no issue created yet" "0" "$(remedy_calls)"
assert_eq "  ... and not yet fired" "0" "$(count_events "$union_log" pager-fired demo)"

pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 2 (hysteresis 0, still firing): exactly one pager-fired" \
  "1" "$(count_events "$union_log" pager-fired demo)"
assert_eq "  ... the remedy function ran exactly once" "1" "$(remedy_calls)"
assert_eq "  ... its return value rode into the issue body" "1" \
  "$(grep -c "$STUB_REMEDY_OUTPUT" "$STUB_GH_LAST_BODY_FILE")"

# The tracking issue now "exists" on the fake GitHub — the close attempt
# below must find it via `gh issue list`, exactly as the real one would.
STUB_GH_LIST_OPEN="$(jq -nc --arg u "$STUB_GH_CREATE_URL" \
  '[{number: 501, url: $u, body: "ref: pager:demo", stateReason: null}]')"

pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 3 (still firing, already fired): no second pager-fired" \
  "1" "$(count_events "$union_log" pager-fired demo)"
assert_eq "  ... and no second remedy call" "1" "$(remedy_calls)"

STUB_FIRING="false"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 4 (fact clears): exactly one pager-cleared" \
  "1" "$(count_events "$union_log" pager-cleared demo)"
assert_eq "  ... the tracking issue got a close call" "1" \
  "$(grep -c '^issue close' "$GH_CALLS_FILE")"

pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 5 (still clear): no second pager-cleared" \
  "1" "$(count_events "$union_log" pager-cleared demo)"

# --- Hysteresis: a candidate that drops before the threshold is never filed -

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register blip stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/blip.jsonl"; : > "$union_log"
: > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 15 "$union_log" "$union_log" '[]' n1 c1
STUB_FIRING="false"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 15 "$union_log" "$union_log" '[]' n1 c1
assert_eq "a candidate that clears before the hysteresis threshold logs candidate-cleared" \
  "1" "$(count_events "$union_log" pager-candidate-cleared blip)"
assert_eq "  ... and is never filed" "0" "$(count_events "$union_log" pager-fired blip)"
assert_eq "  ... the remedy never ran" "0" "$(remedy_calls)"
assert_eq "  ... state is clear again" "clear" "$(pager_state_for blip < "$union_log")"

# --- Per-key MIN_FIRING_MINUTES override (agent-ops#1282) --------------------
# A key registered with its own override ignores pager_evaluate's own shared
# MIN_FIRING_MINUTES entirely: 0 would ordinarily file on the very next tick
# (the end-to-end case above), but a key overridden to 180 stays a candidate
# through a second tick regardless.

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register overridden stub_eval pipeline-act stub_remedy 180
union_log="$WORKDIR/override.jsonl"; : > "$union_log"
: > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 1: still just a candidate" "candidate" "$(pager_state_for overridden < "$union_log")"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 2: the shared MIN_FIRING_MINUTES (0) is ignored — the override wins" \
  "0" "$(count_events "$union_log" pager-fired overridden)"
assert_eq "  ... still just a candidate" "candidate" "$(pager_state_for overridden < "$union_log")"
assert_eq "  ... the remedy never ran" "0" "$(remedy_calls)"

# --- A lost/unreachable claim never evaluates --------------------------------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register locked stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/locked.jsonl"; : > "$union_log"
CLAIM_STUB_RC=3 pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "a lost claim (rc 3) evaluates nothing" "clear" "$(pager_state_for locked < "$union_log")"
CLAIM_STUB_RC=1 pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "an unreachable claim (rc 1) evaluates nothing either — fail closed" "clear" "$(pager_state_for locked < "$union_log")"

# --- config-lever: a second, separate pw::decision record --------------------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register lever stub_eval config-lever "raise the threshold"
union_log="$WORKDIR/lever.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "config-lever: the tracking issue is filed unassigned" "0" \
  "$(grep -c -- '--assignee' "$GH_CALLS_FILE")"
assert_eq "  ... and a second create call files the pw::decision record" "2" \
  "$(grep -c '^issue create' "$GH_CALLS_FILE")"
assert_eq "  ... the decision record is filed under the pw::decision label" "1" \
  "$(grep '^issue create' "$GH_CALLS_FILE" | grep -c 'pw::decision')"
assert_eq "  ... which is then closed immediately (a log, not a request)" "1" \
  "$(grep -c '^issue close' "$GH_CALLS_FILE")"

# --- owner-only: the tracking issue is assigned -------------------------------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register owner stub_eval owner-only "a human must decide this"
union_log="$WORKDIR/owner.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "owner-only: the tracking issue is assigned to the configured assignee" "1" \
  "$(grep '^issue create' "$GH_CALLS_FILE" | grep -c -- '--assignee the-owner')"
assert_eq "  ... exactly one issue created, no separate decision record" "1" \
  "$(grep -c '^issue create' "$GH_CALLS_FILE")"

# --- pipeline-act: a failed remedy still records the failure honestly -------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register broken stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/broken.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"; : > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"; STUB_REMEDY_FAIL="1"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "a failing remedy still lets the tracking issue file" "1" \
  "$(count_events "$union_log" pager-fired broken)"
STUB_REMEDY_FAIL=""

# --- The pw::pager label is ensured on the create path, and only there -------
# Both the dedup search and the auto-close find a page *by* its label, so a
# page filed into a repository that has never carried `pw::pager` — which
# `pager_repo` is, by construction: it falls back to `crash_loop_repo`, which
# no cycle otherwise touches — would be re-filed on every later fire and
# never auto-closed. lib/enabler.sh's create_escalation_issue ensures the
# catalogue on its own create path for exactly this reason; lib/pager.sh
# probes for `labels_ensure_role` with `declare -F` so the rest of this file
# still runs without lib/labels.sh sourced at all.
ENSURE_CALLS_FILE="$WORKDIR/ensure-calls"; : > "$ENSURE_CALLS_FILE"
labels_ensure_role() { printf '%s\n' "$3 $4" >> "$ENSURE_CALLS_FILE"; }
ensure_calls() { wc -l < "$ENSURE_CALLS_FILE" | tr -d ' '; }

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register labelled stub_eval owner-only "a human must decide this"
union_log="$WORKDIR/labelled.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "filing ensures the escalation label catalogue in pager_repo first" \
  "o/r escalation" "$(head -n1 "$ENSURE_CALLS_FILE")"
assert_eq "  ... exactly once, on the create path" "1" "$(ensure_calls)"

# The page now exists on the fake GitHub, so the next fire dedups onto it —
# and the ensure must not run again: it is a label listing per call, and the
# dedup path is the common one.
: > "$ENSURE_CALLS_FILE"
STUB_GH_LIST_OPEN="$(jq -nc '[{number: 501, url: "https://github.com/o/r/issues/501",
                               body: "ref: pager:labelled", stateReason: null}]')"
PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register labelled2 stub_eval owner-only "a human must decide this"
union_log="$WORKDIR/labelled2.jsonl"; : > "$union_log"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"pager-candidate","key":"labelled2","first_seen":"2026-01-01T00:00:00Z"}' > "$union_log"
STUB_GH_LIST_OPEN="$(jq -nc '[{number: 502, url: "https://github.com/o/r/issues/502",
                               body: "ref: pager:labelled2", stateReason: null}]')"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "  ... and never on the dedup path, where the label already exists" \
  "0" "$(ensure_calls)"
unset -f labels_ensure_role

# --- pager_repo empty: the transition is still logged, nothing is filed ------
# This is the whole reason `pager_enabled` is a boolean rather than reusing
# `pager_repo` empty as the off switch `crash_loop_repo` uses (requirement
# 51): an installation with nowhere to file still gets the fired/cleared
# history on its dashboard. An early return here instead would strand the key
# on `candidate` for ever — never firing, and never able to clear.

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register norepo stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/norepo.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"; : > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "no pager_repo: the invariant still fires and the transition is logged" \
  "1" "$(count_events "$union_log" pager-fired norepo)"
assert_eq "  ... with a null issue_number, not a missing one" "null" \
  "$(jq -r '.issue_number | tostring' <<<"$(last_event "$union_log" pager-fired norepo)")"
assert_eq "  ... and a null issue_url" "null" \
  "$(jq -r '.issue_url | tostring' <<<"$(last_event "$union_log" pager-fired norepo)")"
assert_eq "  ... nothing was created on GitHub" "0" "$(grep -c '^issue create' "$GH_CALLS_FILE")"
assert_eq "  ... the state really is fired, not stranded on candidate" \
  "fired" "$(pager_state_for norepo < "$union_log")"
STUB_FIRING="false"
pager_evaluate "$CLAIM_STUB" "" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "  ... and it can clear again, with nothing to close" \
  "1" "$(count_events "$union_log" pager-cleared norepo)"
assert_eq "  ... state back to clear" "clear" "$(pager_state_for norepo < "$union_log")"

# --- the notify guard leaves the exit status alone ----------------------------
# This file sources lib/pager.sh without lib/notify.sh, so `notify_post` is
# undefined for every assertion above — which is the whole point of the
# `declare -F` guard in `pager_file`/`pager_close` (issue #1279). The guard
# must also be invisible in the *exit status*: written as a `&&` list it
# carried its own failed left-hand side out as the function's result, so
# `pager_close` returned 1 on every standalone source and any caller under
# `set -e` died on it. Asserted in a `set -e` subshell, because `set -uo
# pipefail` alone (this file's own options, line 24) cannot see the fault.
assert_eq "notify_post is genuinely undefined here (the guard is under test)" \
  "" "$(declare -F notify_post 2>/dev/null || true)"
guard_log="$(mktemp)"
assert_eq "pager_close returns 0 when lib/notify.sh is not alongside" "0" \
  "$(pager_close gk "ev" "" "pw::pager" "$guard_log" n1 c1 >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "  ... and a set -e caller survives the call" "survived" \
  "$(set -e; pager_close gk "ev" "" "pw::pager" "$guard_log" n1 c1 >/dev/null 2>&1; printf 'survived')"
assert_eq "  ... while still logging the pager-cleared transition" "2" \
  "$(count_events "$guard_log" pager-cleared gk)"
rm -f "$guard_log"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
