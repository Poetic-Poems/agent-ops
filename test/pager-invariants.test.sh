#!/usr/bin/env bash
#
# test/pager-invariants.test.sh — the two invariants lib/pager-invariants.sh
# ships with (agent-ops#1278): `verdict-unanimous` against fixture heartbeat
# sets, `page-outlived-item` against a stubbed `gh`.
#
# lib/pager.sh's own registry/state-machine/remedy-class behaviour is
# test/pager.test.sh's job; this file calls each invariant's EVAL_FN and
# remedy function directly rather than through pager_evaluate, since what
# it is proving is what fires and what the remedy actually does — not the
# claim/hysteresis/event-sourcing machinery around it.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/pager-invariants.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/pager.sh
. "$SCRIPT_DIR/lib/pager.sh"
# shellcheck source=lib/pager-invariants.sh
. "$SCRIPT_DIR/lib/pager-invariants.sh"

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

# --- verdict-unanimous ---------------------------------------------------------

node_row() {  # node_row NAME STALE STAGE_VERDICT UPDATER_STATUS DOCTOR_VERDICT
  jq -nc --arg n "$1" --argjson stale "$2" --arg sv "$3" --arg us "$4" --arg dv "$5" '
    {node: $n, stale: $stale,
     stage_health: (if $sv == "" then null else {stages: {coordinator: {verdict: $sv}}} end),
     updater: (if $us == "" then null else {status: $us} end),
     doctor: (if $dv == "" then null else {verdict: $dv} end)}'
}
# fleet3 ROW1 ROW2 ROW3 -> a 3-element JSON array. Built by feeding each row
# to `jq -s` on stdin rather than process substitution (`<(...)`): this
# sandbox's /dev/fd entries are not always openable by a second process, so
# `<(...)` is avoided throughout this file.
fleet3() { printf '%s\n%s\n%s\n' "$1" "$2" "$3" | jq -sc '.'; }

fleet3_all_failing="$(fleet3 "$(node_row n1 false failing "" "")" \
  "$(node_row n2 false failing "" "")" "$(node_row n3 false failing "" "")")"
verdict="$(pager_eval_verdict_unanimous "$fleet3_all_failing" /dev/null)"
assert_eq "three active nodes, the same stage failing on all: fires" "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names the #1071 signature" "1" "$(grep -c '#1071' <<<"$(jq -r '.evidence' <<<"$verdict")")"

fleet3_split="$(fleet3 "$(node_row n1 false failing "" "")" \
  "$(node_row n2 false ok "" "")" "$(node_row n3 false failing "" "")")"
verdict="$(pager_eval_verdict_unanimous "$fleet3_split" /dev/null)"
assert_eq "three active nodes, only two agree: does not fire" "false" "$(jq -r '.firing' <<<"$verdict")"

fleet_one_active="$(fleet3 "$(node_row n1 false failing "" "")" \
  "$(node_row n2 true failing "" "")" "$(node_row n3 true failing "" "")")"
verdict="$(pager_eval_verdict_unanimous "$fleet_one_active" /dev/null)"
assert_eq "fewer than two active nodes: never unanimous, even if all named nodes agree" \
  "false" "$(jq -r '.firing' <<<"$verdict")"

fleet_stale_disagrees="$(fleet3 "$(node_row n1 false failing "" "")" \
  "$(node_row n2 false failing "" "")" "$(node_row n3 true ok "" "")")"
verdict="$(pager_eval_verdict_unanimous "$fleet_stale_disagrees" /dev/null)"
assert_eq "a stale node's own disagreement does not break the active nodes' unanimity" \
  "true" "$(jq -r '.firing' <<<"$verdict")"

fleet3_updater_stuck="$(fleet3 "$(node_row n1 false "" stuck "")" \
  "$(node_row n2 false "" stuck "")" "$(node_row n3 false "" stuck "")")"
verdict="$(pager_eval_verdict_unanimous "$fleet3_updater_stuck" /dev/null)"
assert_eq "updater.status stuck on every active node: fires" "true" "$(jq -r '.firing' <<<"$verdict")"
fleet3_updater_split="$(fleet3 "$(node_row n1 false "" stuck "")" \
  "$(node_row n2 false "" stuck "")" "$(node_row n3 false "" running "")")"
assert_eq "  ... two active nodes stuck, one running: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_verdict_unanimous "$fleet3_updater_split" /dev/null)")"

fleet3_doctor_fail="$(fleet3 "$(node_row n1 false "" "" fail)" \
  "$(node_row n2 false "" "" fail)" "$(node_row n3 false "" "" fail)")"
verdict="$(pager_eval_verdict_unanimous "$fleet3_doctor_fail" /dev/null)"
assert_eq "doctor.verdict fail on every active node: fires" "true" "$(jq -r '.firing' <<<"$verdict")"

fleet3_healthy="$(fleet3 "$(node_row n1 false ok stuck fail)" \
  "$(node_row n2 false ok running ok)" "$(node_row n3 false failing running ok)")"
verdict="$(pager_eval_verdict_unanimous "$fleet3_healthy" /dev/null)"
assert_eq "no single signal is unanimous across all three: does not fire" \
  "false" "$(jq -r '.firing' <<<"$verdict")"

# --- verdict-unanimous remedy: files a pw::type:tech-debt issue against the reader
#
# One `gh` stub for the rest of this file, driven by state variables rather
# than a mid-file redefinition — a second `gh() { ... }` later on reads as
# dead code to a static reader (and to shellcheck) even though it is real,
# temporally-scoped behaviour; a single function with a case per subcommand
# has no such ambiguity.

GH_CALLS_FILE="$WORKDIR/gh-calls"; : > "$GH_CALLS_FILE"
STUB_GH_LIST_OPEN="[]"
# Per-label listings, keyed by the `--label` value the call actually passes.
# The stub answers *by label* rather than returning one fixed array for every
# listing, because the relation `_pager_open_page_issues` needs is a union and
# `gh issue list --label "a,b"` gives an intersection — a label-blind stub
# cannot tell the two apart, and the comma-joined listing this replaced was
# empty against real GitHub while passing every assertion here.
declare -A STUB_GH_LIST_BY_LABEL=()
STUB_GH_CREATE_URL="https://github.com/o/r/issues/701"
STUB_GH_PR_STATE_MAP=""    # "<url>=<state>;<url>=<state>;..." — pr view lookups
STUB_GH_ISSUE_STATE_MAP="" # same shape, for issue view lookups
gh_state_lookup() {  # gh_state_lookup MAP URL -> STATE, default OPEN
  local map="$1" url="$2" pair
  IFS=';' read -ra pairs <<<"$map"
  for pair in "${pairs[@]}"; do
    [[ "${pair%%=*}" == "$url" ]] && { printf '%s' "${pair#*=}"; return 0; }
  done
  printf 'OPEN'
}
stub_gh_label_of() {  # stub_gh_label_of ARGS... -> the value after --label
  local a next=""
  for a in "$@"; do
    [[ "$next" == "label" ]] && { printf '%s' "$a"; return 0; }
    [[ "$a" == "--label" ]] && next="label"
  done
  return 0
}
gh() {
  printf '%s\n' "$*" >> "$GH_CALLS_FILE"
  case "$1 $2" in
    "issue list")
      local lbl; lbl="$(stub_gh_label_of "$@")"
      if (( ${#STUB_GH_LIST_BY_LABEL[@]} )); then
        printf '%s' "${STUB_GH_LIST_BY_LABEL[$lbl]:-[]}"
      else
        printf '%s' "$STUB_GH_LIST_OPEN"
      fi
      return 0 ;;
    "issue create") printf 'created: %s\n' "$STUB_GH_CREATE_URL"; return 0 ;;
    "issue close") return 0 ;;
    "pr view") gh_state_lookup "$STUB_GH_PR_STATE_MAP" "$3" ;;
    "issue view") gh_state_lookup "$STUB_GH_ISSUE_STATE_MAP" "$3" ;;
    *) return 1 ;;
  esac
}
PAGER_REMEDY_REPO="reader/repo"
outcome="$(pager_remedy_verdict_unanimous verdict-unanimous "updater.status=stuck on every active node")"
assert_eq "the remedy reports what it filed" "1" "$(grep -c 'reader/repo#701' <<<"$outcome")"
assert_eq "  ... labelled pw::type:tech-debt" "1" \
  "$(grep '^issue create' "$GH_CALLS_FILE" | grep -c 'pw::type:tech-debt')"
assert_eq "  ... filed in the reader's own repo (PAGER_REMEDY_REPO), unassigned" "0" \
  "$(grep '^issue create' "$GH_CALLS_FILE" | grep -c -- '--assignee')"

PAGER_REMEDY_REPO=""
if pager_remedy_verdict_unanimous verdict-unanimous "x" >/dev/null 2>&1; then
  printf 'FAIL - no PAGER_REMEDY_REPO should return failure\n'; failures=$(( failures + 1 ))
else
  printf 'ok   - no PAGER_REMEDY_REPO returns failure rather than filing nowhere\n'
fi

# --- page-outlived-item ---------------------------------------------------------

: > "$GH_CALLS_FILE"
PAGER_EVAL_REPO="o/r"
PAGER_EVAL_ESCALATION_LABEL="enabler-escalation"

# Three open pages: one whose PR merged (outlived), one whose PR is still
# open (not outlived), one whose linked issue is closed (outlived) — split
# across the two labels the way real pages are, an Enabler escalation never
# carrying `pw::pager` and vice versa. Issue #3 is reachable only through the
# `pw::pager` listing, so a reader that asks GitHub for both labels at once
# (an intersection) sees nothing at all here.
STUB_GH_LIST_BY_LABEL=(
  [enabler-escalation]="$(jq -nc \
    --arg b1 'This page is about https://github.com/o/r/pull/10 among other things.' \
    --arg b2 'This page is about https://github.com/o/r/pull/11 among other things.' \
    '[{number:1,url:"https://github.com/o/r/issues/1",body:$b1},
      {number:2,url:"https://github.com/o/r/issues/2",body:$b2}]')"
  [pw::pager]="$(jq -nc \
    --arg b3 'This page is about https://github.com/o/r/issues/12 among other things.' \
    '[{number:3,url:"https://github.com/o/r/issues/3",body:$b3}]')"
)

# _pager_open_page_issues reads one `gh issue list`; per-item pr/issue view
# calls answer per the *referenced* URL, via the shared gh() stub's lookup
# maps above.
STUB_GH_PR_STATE_MAP="https://github.com/o/r/pull/10=MERGED;https://github.com/o/r/pull/11=OPEN"
STUB_GH_ISSUE_STATE_MAP="https://github.com/o/r/issues/12=CLOSED"

verdict="$(pager_eval_page_outlived_item "" "")"
assert_eq "two of three pages' own items already concluded: fires" "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence counts exactly two" "1" "$(grep -c '^2 page' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... one listing per label, never one comma-joined (which GitHub ANDs)" "0" \
  "$(grep '^issue list' "$GH_CALLS_FILE" | grep -c -- '--label [^ ]*,')"
assert_eq "  ... both labels were asked for" "2" \
  "$(grep '^issue list' "$GH_CALLS_FILE" | grep -c -- '--label')"

: > "$GH_CALLS_FILE"
outcome="$(pager_remedy_page_outlived_item page-outlived-item "irrelevant, re-derived live")"
assert_eq "the remedy closes exactly the two outlived pages" "closed 2 outlived page(s)" "$outcome"
assert_eq "  ... issue #1 (merged PR) was closed" "1" \
  "$(grep -c '^issue close 1 ' "$GH_CALLS_FILE")"
assert_eq "  ... issue #2 (still-open PR) was left alone" "0" \
  "$(grep -c '^issue close 2 ' "$GH_CALLS_FILE")"
assert_eq "  ... issue #3 (closed issue) was closed" "1" \
  "$(grep -c '^issue close 3 ' "$GH_CALLS_FILE")"

STUB_GH_LIST_BY_LABEL=([enabler-escalation]="[]" [pw::pager]="[]")
verdict="$(pager_eval_page_outlived_item "" "")"
assert_eq "no open pages at all: does not fire" "false" "$(jq -r '.firing' <<<"$verdict")"

# --- firing-missed (agent-ops#1282) ---------------------------------------------

cycle_ev() {  # cycle_ev TS NODE CYCLE EVENT [EXTRA_JSON]
  jq -nc --arg ts "$1" --arg n "$2" --arg c "$3" --arg e "$4" --argjson extra "${5:-{\}}" \
    '{ts: $ts, node: $n, cycle: $c, event: $e} + $extra'
}
write_log() { local path="$1"; shift; printf '%s\n' "$@" > "$path"; }
# rel SECONDS_OFFSET -> an ISO-8601 timestamp that many seconds from *now*
# (negative = in the past). The EVAL_FN reads the real clock (`date -u
# +%s`), so every fixture below is anchored to whenever this file actually
# runs, not to a fixed calendar date.
rel() { date -u -d "@$(( $(date -u +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

# n1: last cycle completed 3 minutes ago — well within the interval, never
# fires. n2: last cycle-start 4 hours ago, cleanly completed (no lock held)
# — fires, with a two-entry duration histogram. n3: last cycle-start equally
# ancient, but its heartbeat itself is stale — excluded regardless. n4:
# active, but its last event is an unmatched cycle-start (still running) —
# never fires, however old that start was.
fm_log="$WORKDIR/firing-missed.jsonl"
write_log "$fm_log" \
  "$(cycle_ev "$(rel -300)" n1 c1 cycle-start)" \
  "$(cycle_ev "$(rel -180)" n1 c1 cycle-end '{"exit_code":0}')" \
  "$(cycle_ev "$(rel -14400)" n2 c1 cycle-start)" \
  "$(cycle_ev "$(rel -14300)" n2 c1 cycle-end '{"exit_code":0}')" \
  "$(cycle_ev "$(rel -7200)" n2 c2 cycle-start)" \
  "$(cycle_ev "$(rel -7100)" n2 c2 cycle-end '{"exit_code":0}')" \
  "$(cycle_ev "$(rel -14400)" n3 c1 cycle-start)" \
  "$(cycle_ev "$(rel -14300)" n3 c1 cycle-end '{"exit_code":0}')" \
  "$(cycle_ev "$(rel -14400)" n4 c1 cycle-start)"
fm_nodes="$(fleet3 "$(node_row n1 false "" "" "")" "$(node_row n2 false "" "" "")" \
  "$(node_row n3 true "" "" "")")"
fm_nodes="$(jq -c --argjson extra "$(node_row n4 false "" "" "")" '. + [$extra]' <<<"$fm_nodes")"

PAGER_EVAL_CYCLE_INTERVAL_MINUTES=15
verdict="$(pager_eval_firing_missed "$fm_nodes" "$fm_log")"
assert_eq "an active node past 2x the interval, no lock held: fires" "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... n1 (recently cycled) is not named" "0" \
  "$(jq -r '.nodes | index("n1") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... n2 (stale cycle-start, no lock held) is named" "1" \
  "$(jq -r '.nodes | index("n2") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... n3 (stale heartbeat) is excluded even though equally ancient" "0" \
  "$(jq -r '.nodes | index("n3") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... n4 (still holds its lock) is never named, however old" "0" \
  "$(jq -r '.nodes | index("n4") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... evidence carries n2's own cycle-duration histogram" "1" \
  "$(grep -c 'cycle durations' <<<"$(jq -r '.evidence' <<<"$verdict")")"

PAGER_EVAL_CYCLE_INTERVAL_MINUTES=""
assert_eq "no configured interval: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_firing_missed "$fm_nodes" "$fm_log")")"
PAGER_EVAL_CYCLE_INTERVAL_MINUTES=15

# --- node-stale (agent-ops#1282) -------------------------------------------------

ns_row() { jq -nc --arg n "$1" --argjson age "$2" '{node: $n, heartbeat_age_s: $age}'; }
ns_nodes="$(printf '%s\n%s\n' "$(ns_row n1 100)" "$(ns_row n2 10000)" | jq -sc '.')"
PAGER_EVAL_NODE_STALE_AFTER_MINUTES=30
verdict="$(pager_eval_node_stale "$ns_nodes" /dev/null)"
assert_eq "only the node past 2x node_stale_after_minutes fires" "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... names exactly that node" "n2" "$(jq -r '.nodes | join(",")' <<<"$verdict")"

ns_nodes_fresh="$(printf '%s\n' "$(ns_row n1 100)" | jq -sc '.')"
assert_eq "every node under threshold: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_node_stale "$ns_nodes_fresh" /dev/null)")"

PAGER_EVAL_NODE_STALE_AFTER_MINUTES=""
assert_eq "no configured threshold: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_node_stale "$ns_nodes" /dev/null)")"
PAGER_EVAL_NODE_STALE_AFTER_MINUTES=30

# --- updater-stuck (agent-ops#1282) ----------------------------------------------

us_row() {  # us_row NAME STALE STATUS SECONDS
  jq -nc --arg n "$1" --argjson stale "$2" --arg st "$3" --argjson sec "$4" \
    '{node: $n, stale: $stale, updater: {status: $st, seconds: $sec}}'
}
us_nodes="$(printf '%s\n%s\n%s\n' "$(us_row n1 false stuck 100)" "$(us_row n2 false stuck 10000)" \
  "$(us_row n3 true stuck 10000)" | jq -sc '.')"
PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES=20
verdict="$(pager_eval_updater_stuck "$us_nodes" /dev/null)"
assert_eq "only the active node stuck past 2x updater_stuck_after_minutes fires" "true" \
  "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... names exactly that node" "n2" "$(jq -r '.nodes | join(",")' <<<"$verdict")"
assert_eq "  ... a stale node's stuck streak is not trusted" "0" \
  "$(jq -r '.nodes | index("n3") != null' <<<"$verdict" | grep -c true)"

PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES=""
assert_eq "no configured threshold: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_updater_stuck "$us_nodes" /dev/null)")"
PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES=20

# --- review-pipeline-failing (agent-ops#1282) ------------------------------------
# Every fixture run below carries the shape review-cycle.sh actually writes:
# its `cleanup()` EXIT trap logs `review-end` on *every* run whatever
# happened, and both ordinary `review-attempt-failed` sites `return 0`, so a
# failed run's own `review-end` still reports `exit_code: 0`. A reader that
# reduced over raw events and reset on that would reset on the very run that
# just failed; these fixtures are what prove it does not.

review_ev() {  # review_ev TS NODE REVIEW EVENT [EXTRA_JSON]
  jq -nc --arg ts "$1" --arg n "$2" --arg r "$3" --arg e "$4" --argjson extra "${5:-{\}}" \
    '{ts: $ts, node: $n, review: $r, event: $e} + $extra'
}
rv_log="$WORKDIR/review-log.jsonl"
write_log "$rv_log" \
  "$(review_ev 2026-09-09T09:00:00Z n1 r1 review-stage-end '{"rc":1}')" \
  "$(review_ev 2026-09-09T09:01:00Z n1 r1 review-attempt-failed)" \
  "$(review_ev 2026-09-09T09:02:00Z n1 r1 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T09:10:00Z n1 r2 review-attempt-failed)" \
  "$(review_ev 2026-09-09T09:12:00Z n1 r2 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T09:20:00Z n1 r3 review-stage-end '{"rc":124}')" \
  "$(review_ev 2026-09-09T09:21:00Z n1 r3 review-attempt-failed)" \
  "$(review_ev 2026-09-09T09:22:00Z n1 r3 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T08:00:00Z n2 s1 review-attempt-failed)" \
  "$(review_ev 2026-09-09T08:02:00Z n2 s1 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T08:30:00Z n2 s2 review-stage-end '{"rc":0}')" \
  "$(review_ev 2026-09-09T08:32:00Z n2 s2 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T09:00:00Z n2 s3 review-attempt-failed)" \
  "$(review_ev 2026-09-09T09:02:00Z n2 s3 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T09:30:00Z n2 s4 review-attempt-failed)" \
  "$(review_ev 2026-09-09T09:32:00Z n2 s4 review-end '{"exit_code":0}')"
PAGER_EVAL_REVIEW_UNION_LOG_FILE="$rv_log"
verdict="$(pager_eval_review_pipeline_failing "" "")"
assert_eq "three failed runs, each ending review-end exit_code 0, still fire" "true" \
  "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... names exactly the node with the streak" "n1" "$(jq -r '.nodes | join(",")' <<<"$verdict")"
assert_eq "  ... the evidence counts runs, not the events within them" "1" \
  "$(grep -c 'n1 (3 runs)' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... a run that completed a review resets: n2's own 2-run tail does not fire" "0" \
  "$(jq -r '.nodes | index("n2") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... notes #996 as the interim's own proper fix" "1" "$(grep -c '#996' <<<"$(jq -r '.evidence' <<<"$verdict")")"

# A run that stood down, was skipped, or had no repository due writes neither
# a `review-attempt-failed` nor a `review-stage-end`: it says nothing about
# whether the pipeline works, so it must neither raise the streak nor silence
# it — the very indistinguishability #996 names, refused rather than guessed.
rv_log_idle="$WORKDIR/review-log-idle.jsonl"
write_log "$rv_log_idle" \
  "$(review_ev 2026-09-09T09:00:00Z n1 r1 review-attempt-failed)" \
  "$(review_ev 2026-09-09T09:02:00Z n1 r1 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T09:10:00Z n1 r2 review-stand-down '{"cause":"peer-pipeline-busy"}')" \
  "$(review_ev 2026-09-09T09:12:00Z n1 r2 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T09:20:00Z n1 r3 review-attempt-failed)" \
  "$(review_ev 2026-09-09T09:22:00Z n1 r3 review-end '{"exit_code":0}')" \
  "$(review_ev 2026-09-09T09:30:00Z n1 r4 review-attempt-failed)" \
  "$(review_ev 2026-09-09T09:32:00Z n1 r4 review-end '{"exit_code":0}')"
PAGER_EVAL_REVIEW_UNION_LOG_FILE="$rv_log_idle"
assert_eq "a stood-down run between failures neither resets nor counts" "true" \
  "$(jq -r '.firing' <<<"$(pager_eval_review_pipeline_failing "" "")")"

PAGER_EVAL_REVIEW_UNION_LOG_FILE=""
assert_eq "no review union log configured: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_review_pipeline_failing "" "")")"
PAGER_EVAL_REVIEW_UNION_LOG_FILE="$rv_log"

# --- dashboard-unreadable (agent-ops#1282) ---------------------------------------

df_row() {  # df_row NAME SECONDS_OR_EMPTY PARSED_OR_EMPTY
  jq -nc --arg n "$1" --arg sec "$2" --arg p "$3" \
    '{node: $n,
      dashboard_fetch: (if $sec == "" and $p == "" then null
                         else {seconds: ($sec | if . == "" then null else tonumber end),
                               parsed: ($p | if . == "" then true elif . == "true" then true else false end)}
                         end)}'
}
df_nodes="$(printf '%s\n%s\n%s\n' "$(df_row n1 "" "")" "$(df_row n2 45 "")" "$(df_row n3 5 false)" | jq -sc '.')"
PAGER_EVAL_DASHBOARD_FETCH_SECONDS=30
verdict="$(pager_eval_dashboard_unreadable "$df_nodes" /dev/null)"
assert_eq "a slow fetch and a failed parse both fire" "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... names both, never the node with no probe result at all" "n2,n3" \
  "$(jq -r '.nodes | sort | join(",")' <<<"$verdict")"

df_nodes_ok="$(printf '%s\n' "$(df_row n1 5 true)" | jq -sc '.')"
assert_eq "a fast, parsed fetch does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_dashboard_unreadable "$df_nodes_ok" /dev/null)")"

PAGER_EVAL_DASHBOARD_FETCH_SECONDS=""
assert_eq "no configured threshold: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_dashboard_unreadable "$df_nodes" /dev/null)")"
PAGER_EVAL_DASHBOARD_FETCH_SECONDS=30

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
