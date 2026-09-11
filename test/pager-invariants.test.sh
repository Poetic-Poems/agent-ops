#!/usr/bin/env bash
#
# test/pager-invariants.test.sh — the invariants lib/pager-invariants.sh
# ships with: agent-ops#1278's `verdict-unanimous` (fixture heartbeat sets)
# and `page-outlived-item` (a stubbed `gh`); agent-ops#1282's five
# peer-vantage invariants; agent-ops#1281's seven selection/ledger
# invariants (idle-with-demand, fit-ladder-pinned, work-order-repaired-rate,
# blocked-label-orphaned, claim-unreconciled, escalation-burst,
# digest-truncated).
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
# agent-ops#1281's own three invariants need these for the real detection
# functions (requirement 38b's release path, the #815 correction-comment
# convention, requirement 36d's reason-key fingerprint) rather than a
# reimplementation.
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/escalation-autonomy.sh
. "$SCRIPT_DIR/lib/escalation-autonomy.sh"

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
stub_gh_repo_of() {  # stub_gh_repo_of ARGS... -> the value after -R
  local a next=""
  for a in "$@"; do
    [[ "$next" == "repo" ]] && { printf '%s' "$a"; return 0; }
    [[ "$a" == "-R" ]] && next="repo"
  done
  return 0
}
# agent-ops#1281's own three stub knobs: STUB_GH_EDIT_OK (issue edit's own
# exit status, for blocked-label-orphaned's remedy), STUB_GH_API_MAP (path
# -> value, for digest-truncated's live search/issues counts), and
# STUB_GH_COMMENT_OK (issue comment's own exit status, for
# claim-unreconciled's remedy). agent-ops#1280's own:
# STUB_GH_PR_LIST_BY_REPO (repo -> `gh pr list` JSON array, answered per the
# `-R` repository the call actually names, mirroring `issue list`'s own
# per-label answering above), for pr-unreviewed's own listing.
STUB_GH_EDIT_OK=1
declare -A STUB_GH_API_MAP=()
STUB_GH_COMMENT_OK=1
declare -A STUB_GH_PR_LIST_BY_REPO=()
gh() {
  printf '%s\n' "$*" >> "$GH_CALLS_FILE"
  if [[ "$1" == "api" ]]; then
    printf '%s' "${STUB_GH_API_MAP[$2]:-}"
    return 0
  fi
  case "$1 $2" in
    "issue list")
      local lbl; lbl="$(stub_gh_label_of "$@")"
      if (( ${#STUB_GH_LIST_BY_LABEL[@]} )); then
        printf '%s' "${STUB_GH_LIST_BY_LABEL[$lbl]:-[]}"
      else
        printf '%s' "$STUB_GH_LIST_OPEN"
      fi
      return 0 ;;
    "pr list")
      local repo; repo="$(stub_gh_repo_of "$@")"
      printf '%s' "${STUB_GH_PR_LIST_BY_REPO[$repo]:-[]}"
      return 0 ;;
    "issue create") printf 'created: %s\n' "$STUB_GH_CREATE_URL"; return 0 ;;
    "issue close") return 0 ;;
    "issue comment") if (( STUB_GH_COMMENT_OK )); then return 0; else return 1; fi ;;
    "issue edit") if (( STUB_GH_EDIT_OK )); then return 0; else return 1; fi ;;
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
# never fires, however old that start was. n5: cycle-start 40 minutes ago,
# still unmatched (a cycle genuinely still running, past 2x the 15-minute
# interval), with two later cycle-skipped events (own, distinct cycle ids,
# same as a real skipped attempt logs — agent-cycle.sh:1472) at -25m and
# -10m proving the scheduler kept ticking and correctly deferred to the
# still-running cycle — never fires, since a recent skip is itself evidence
# the scheduler is alive (agent-ops#1312's own review of #1282: a trailing
# skip must not invert "holds no lock" into "missed").
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
  "$(cycle_ev "$(rel -14400)" n4 c1 cycle-start)" \
  "$(cycle_ev "$(rel -2400)" n5 c1 cycle-start)" \
  "$(cycle_ev "$(rel -1500)" n5 c2 cycle-skipped)" \
  "$(cycle_ev "$(rel -600)" n5 c3 cycle-skipped)"
fm_nodes="$(fleet3 "$(node_row n1 false "" "" "")" "$(node_row n2 false "" "" "")" \
  "$(node_row n3 true "" "" "")")"
fm_nodes="$(jq -c --argjson extra "$(node_row n4 false "" "" "")" '. + [$extra]' <<<"$fm_nodes")"
fm_nodes="$(jq -c --argjson extra "$(node_row n5 false "" "" "")" '. + [$extra]' <<<"$fm_nodes")"

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
assert_eq "  ... n5 (long cycle, but a recent trailing skip proves the scheduler is alive) is never named" "0" \
  "$(jq -r '.nodes | index("n5") != null' <<<"$verdict" | grep -c true)"
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

# --- idle-with-demand (agent-ops#1281) -------------------------------------

ns_ev() {  # ns_ev TS NODE CYCLE STATE CAUSE
  jq -nc --arg ts "$1" --arg n "$2" --arg c "$3" --arg s "$4" --arg cause "$5" \
    '{ts: $ts, node: $n, cycle: $c, event: "node-state", state: $s, cause: $cause}'
}
idle_log="$WORKDIR/idle.jsonl"
# One cycle is several `node-state` events, not one, and this fixture says so:
# agent-cycle.sh logs `overhead` unconditionally at the top of every cycle
# that takes the lock and one more transition per stage-start, and only
# `finalize_node_state_for_cycle` — the last event of the cycle — says how the
# cycle *ended*. A fixture carrying terminal events alone would let an
# invariant that reads the last N *events* pass here while never firing on a
# real union log, which is exactly what this shape exists to prevent.
write_log "$idle_log" \
  "$(ns_ev "$(rel -920)" n1 c1 overhead "")" \
  "$(ns_ev "$(rel -910)" n1 c1 overhead "")" \
  "$(ns_ev "$(rel -900)" n1 c1 idle-with-demand awaiting-tick)" \
  "$(ns_ev "$(rel -620)" n1 c2 overhead "")" \
  "$(ns_ev "$(rel -610)" n1 c2 overhead "")" \
  "$(ns_ev "$(rel -600)" n1 c2 idle-with-demand peer-claimed)" \
  "$(ns_ev "$(rel -320)" n1 c3 overhead "")" \
  "$(ns_ev "$(rel -300)" n1 c3 idle-with-demand coordinator-declined)" \
  "$(cycle_ev "$(rel -650)" n1 c2 none-selected '{"reason":"nothing eligible clears the model'"'"'s own bar","eligible_total":4}')" \
  "$(cycle_ev "$(rel -910)" n1 c1 coordinator-input-fitted '{"detail":"trimmed to rung 3","rung":3}')" \
  "$(ns_ev "$(rel -920)" n2 c1 overhead "")" \
  "$(ns_ev "$(rel -900)" n2 c1 idle-with-demand back-pressure)" \
  "$(ns_ev "$(rel -620)" n2 c2 overhead "")" \
  "$(ns_ev "$(rel -600)" n2 c2 idle-with-demand back-pressure)" \
  "$(ns_ev "$(rel -320)" n2 c3 overhead "")" \
  "$(ns_ev "$(rel -300)" n2 c3 idle-with-demand back-pressure)" \
  "$(ns_ev "$(rel -920)" n3 c1 overhead "")" \
  "$(ns_ev "$(rel -900)" n3 c1 idle-with-demand awaiting-tick)" \
  "$(ns_ev "$(rel -620)" n3 c2 overhead "")" \
  "$(ns_ev "$(rel -610)" n3 c2 producing "")" \
  "$(ns_ev "$(rel -600)" n3 c2 idle-without-demand no-demand)" \
  "$(ns_ev "$(rel -320)" n3 c3 overhead "")" \
  "$(ns_ev "$(rel -300)" n3 c3 idle-with-demand awaiting-tick)"
idle_nodes="$(fleet3 "$(node_row n1 false "" "" "")" "$(node_row n2 false "" "" "")" \
  "$(node_row n3 false "" "" "")")"
PAGER_EVAL_IDLE_CYCLES=3
verdict="$(pager_eval_idle_with_demand "$idle_nodes" "$idle_log")"
assert_eq "last 3 cycles all ended idle-with-demand (excluding back-pressure): fires" "true" \
  "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... names exactly n1" "n1" "$(jq -r '.nodes | join(",")' <<<"$verdict")"
assert_eq "  ... the per-cycle overhead transitions between them do not break the streak" "1" \
  "$(jq -r '.nodes | index("n1") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... n2's own back-pressure cycles are excluded" "0" \
  "$(jq -r '.nodes | index("n2") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... n3's one cycle that ended without demand breaks the streak" "0" \
  "$(jq -r '.nodes | index("n3") != null' <<<"$verdict" | grep -c true)"

idle_log_short="$WORKDIR/idle-short.jsonl"
write_log "$idle_log_short" \
  "$(ns_ev "$(rel -620)" n1 c1 overhead "")" \
  "$(ns_ev "$(rel -610)" n1 c1 overhead "")" \
  "$(ns_ev "$(rel -600)" n1 c1 idle-with-demand awaiting-tick)" \
  "$(ns_ev "$(rel -320)" n1 c2 overhead "")" \
  "$(ns_ev "$(rel -300)" n1 c2 idle-with-demand awaiting-tick)"
assert_eq "two idle cycles' worth of events, however many: an incomplete window decides nothing" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_idle_with_demand "$idle_nodes" "$idle_log_short")")"
assert_eq "  ... evidence carries the none-selected reason" "1" \
  "$(grep -c 'nothing eligible clears' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... evidence carries the fit report" "1" \
  "$(grep -c 'trimmed to rung 3' <<<"$(jq -r '.evidence' <<<"$verdict")")"

PAGER_EVAL_IDLE_CYCLES=""
assert_eq "no configured cycle count: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_idle_with_demand "$idle_nodes" "$idle_log")")"
PAGER_EVAL_IDLE_CYCLES=3

# --- fit-ladder-pinned (agent-ops#1281) -------------------------------------

fit_ev() {  # fit_ev TS NODE CYCLE RUNG DROPPED
  jq -nc --arg ts "$1" --arg n "$2" --arg c "$3" --argjson rung "$4" --argjson dropped "$5" \
    '{ts: $ts, node: $n, cycle: $c, event: "coordinator-input-fitted", rung: $rung, entries_dropped: $dropped}'
}
fit_log="$WORKDIR/fit.jsonl"
# n1 sits at the ladder's very last notch; n2 sits at rung 9, the *first* of
# the entry caps and the rung agent-ops#1281's own evidence records
# (`poetic-1`, 48–68 entries dropped in 149 of 150 fitted cycles from
# 2026-09-04) — both are the ladder out of prose to shed and dropping whole
# entries, which is what this invariant is about. n3 comes back up to a prose
# rung, dropping nothing, within the window.
write_log "$fit_log" \
  "$(fit_ev "$(rel -7200)" n1 c1 15 12)" \
  "$(fit_ev "$(rel -3600)" n1 c2 15 30)" \
  "$(fit_ev "$(rel -7200)" n2 c1 9 48)" \
  "$(fit_ev "$(rel -3600)" n2 c2 9 68)" \
  "$(fit_ev "$(rel -900)" n3 c1 9 8)" \
  "$(fit_ev "$(rel -300)" n3 c2 6 0)"
verdict="$(pager_eval_fit_ladder_pinned "[]" "$fit_log")"
assert_eq "every fitted cycle in the entry-dropping segment: fires" "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... names n1, pinned at the ladder's last notch" "1" \
  "$(jq -r '.nodes | index("n1") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... names n2 too, pinned at rung 9 — agent-ops#1128's own shape" "1" \
  "$(jq -r '.nodes | index("n2") != null' <<<"$verdict" | grep -c true)"
assert_eq "  ... evidence carries n2's own rung and drop range" "1" \
  "$(grep -c 'n2 (2 cycle(s) at rung 9-9, 48-68 entries dropped)' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... n3 (one cycle back up to a prose rung, dropping nothing) is excluded" "0" \
  "$(jq -r '.nodes | index("n3") != null' <<<"$verdict" | grep -c true)"

fit_log_none="$WORKDIR/fit-none.jsonl"
write_log "$fit_log_none" "$(fit_ev "$(rel -100000)" n1 c1 15 12)"
assert_eq "the only fitted cycle is outside the trailing 24h: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_fit_ladder_pinned "[]" "$fit_log_none")")"

# --- work-order-repaired-rate (agent-ops#1281) ------------------------------

sel_ev() { jq -nc --arg ts "$1" --arg n "$2" --arg c "$3" '{ts: $ts, node: $n, cycle: $c, event: "selection"}'; }
repaired_ev() { jq -nc --arg ts "$1" --arg n "$2" --arg c "$3" '{ts: $ts, node: $n, cycle: $c, event: "work-order-repaired"}'; }
rate_log="$WORKDIR/rate.jsonl"
write_log "$rate_log" \
  "$(sel_ev "$(rel -3600)" n1 c1)" "$(repaired_ev "$(rel -3550)" n1 c1)" \
  "$(sel_ev "$(rel -3000)" n1 c2)" \
  "$(sel_ev "$(rel -2000)" n1 c3)" \
  "$(sel_ev "$(rel -1000)" n1 c4)" "$(repaired_ev "$(rel -950)" n1 c4)"
PAGER_EVAL_REPAIR_RATE_PERCENT=20
verdict="$(pager_eval_work_order_repaired_rate "[]" "$rate_log")"
assert_eq "2 of 4 selections repaired (50%), above the 20% threshold: fires" "true" \
  "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names the rate" "1" "$(grep -c '50%' <<<"$(jq -r '.evidence' <<<"$verdict")")"

PAGER_EVAL_REPAIR_RATE_PERCENT=60
assert_eq "the same rate under a 60% threshold: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_work_order_repaired_rate "[]" "$rate_log")")"

rate_log_empty="$WORKDIR/rate-empty.jsonl"
: > "$rate_log_empty"
PAGER_EVAL_REPAIR_RATE_PERCENT=20
assert_eq "no selections in the window: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_work_order_repaired_rate "[]" "$rate_log_empty")")"

# --- blocked-label-orphaned (agent-ops#1281) --------------------------------

orph_log="$WORKDIR/orphaned.jsonl"
write_log "$orph_log" \
  "$(cycle_ev 2026-09-01T00:00:00Z n1 c1 attempt-failed '{"repo":"o/r","item":"5","kind":"needs-refinement","blocked_label":"blocked"}')" \
  "$(cycle_ev 2026-09-01T00:00:01Z n1 c1 own-label-action '{"repo":"o/r","item":"5","label":"blocked","action":"add"}')" \
  "$(cycle_ev 2026-09-02T00:00:00Z n1 c2 unblocked '{"repo":"o/r","item":"5"}')"
STUB_GH_LIST_BY_LABEL=()
STUB_GH_LIST_OPEN='[]'
verdict="$(pager_eval_blocked_label_orphaned "[]" "$orph_log")"
assert_eq "an own-label-action add with no later remove, and the block cleared: fires" "true" \
  "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names the issue" "1" "$(grep -c 'o/r#5' <<<"$(jq -r '.evidence' <<<"$verdict")")"

: > "$GH_CALLS_FILE"
PAGER_REMEDY_UNION_LOG_FILE="$orph_log"
PAGER_REMEDY_LOG_FILE="$WORKDIR/orph-remedy.jsonl"; : > "$PAGER_REMEDY_LOG_FILE"
PAGER_REMEDY_NODE="n1"; PAGER_REMEDY_CYCLE="c9"
STUB_GH_EDIT_OK=1
outcome="$(pager_remedy_blocked_label_orphaned blocked-label-orphaned "irrelevant, re-derived live")"
assert_eq "the remedy removes the orphaned label" "removed 1 orphaned label(s); 0 removal(s) failed" "$outcome"
assert_eq "  ... via issue edit --remove-label" "1" "$(grep -c '^issue edit' "$GH_CALLS_FILE")"

STUB_GH_EDIT_OK=0
outcome="$(pager_remedy_blocked_label_orphaned blocked-label-orphaned "irrelevant, re-derived live")"
assert_eq "a failing removal is reported, not silently dropped" "removed 0 orphaned label(s); 1 removal(s) failed" "$outcome"
STUB_GH_EDIT_OK=1

orph_log_clear="$WORKDIR/orphaned-clear.jsonl"
write_log "$orph_log_clear" \
  "$(cycle_ev 2026-09-01T00:00:00Z n1 c1 warning '{"detail":"unrelated"}')"
assert_eq "no blocked-label history at all: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_blocked_label_orphaned "[]" "$orph_log_clear")")"

# --- claim-unreconciled (agent-ops#1281) ------------------------------------

claim_log="$WORKDIR/claim.jsonl"
write_log "$claim_log" \
  "$(cycle_ev "$(rel -100)" n1 c1 enabler-examined '{"repo":"o/r","item":"9","outcome":"escalate"}')"
verdict="$(pager_eval_claim_unreconciled "[]" "$claim_log")"
assert_eq "an escalate verdict with no matching escalated event in the same cycle: fires" "true" \
  "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names the item and cycle" "1" \
  "$(grep -c 'o/r#9 (cycle c1)' <<<"$(jq -r '.evidence' <<<"$verdict")")"

: > "$GH_CALLS_FILE"
PAGER_REMEDY_UNION_LOG_FILE="$claim_log"
PAGER_REMEDY_NODE="n1"; PAGER_REMEDY_CYCLE="c9"
STUB_GH_COMMENT_OK=1
outcome="$(pager_remedy_claim_unreconciled claim-unreconciled "irrelevant, re-derived live")"
assert_eq "the remedy posts one correction comment" "posted 1 correction comment(s)" "$outcome"
assert_eq "  ... on the claimed item's own thread" "1" "$(grep -c '^issue comment 9 ' "$GH_CALLS_FILE")"

claim_log_reconciled="$WORKDIR/claim-reconciled.jsonl"
write_log "$claim_log_reconciled" \
  "$(cycle_ev "$(rel -100)" n1 c1 escalated '{"repo":"o/r","item":"9","issue_number":11}')" \
  "$(cycle_ev "$(rel -99)" n1 c1 enabler-examined '{"repo":"o/r","item":"9","outcome":"escalate"}')"
assert_eq "a matching escalated event in the same cycle: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_claim_unreconciled "[]" "$claim_log_reconciled")")"

claim_log_failed="$WORKDIR/claim-failed.jsonl"
write_log "$claim_log_failed" \
  "$(cycle_ev "$(rel -100)" n1 c1 enabler-examined '{"repo":"o/r","item":"9","outcome":"escalation-failed"}')"
assert_eq "an escalation-failed outcome (never claimed escalate): does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_claim_unreconciled "[]" "$claim_log_failed")")"

# The union log is never rotated (scripts/rotate-logs.sh), so an unwindowed
# reading would fire on agent-ops#815's own original incident for ever and
# could never clear — and the remedy would comment on items settled months
# ago. Both the eval and its remedy are bound to the trailing 24h.
claim_log_old="$WORKDIR/claim-old.jsonl"
write_log "$claim_log_old" \
  "$(cycle_ev "$(rel -172800)" n1 c1 enabler-examined '{"repo":"o/r","item":"9","outcome":"escalate"}')"
assert_eq "an unreconciled claim older than the trailing 24h: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_claim_unreconciled "[]" "$claim_log_old")")"
: > "$GH_CALLS_FILE"
PAGER_REMEDY_UNION_LOG_FILE="$claim_log_old"
assert_eq "  ... and its remedy comments on nothing" \
  "no unreconciled claim found on re-check — nothing to correct" \
  "$(pager_remedy_claim_unreconciled claim-unreconciled "irrelevant, re-derived live")"
assert_eq "  ... posting no comment at all" "0" "$(grep -c '^issue comment' "$GH_CALLS_FILE")"

# --- escalation-burst (agent-ops#1281) --------------------------------------

esc_ev() { jq -nc --arg ts "$1" --arg n "$2" --arg c "$3" --arg r "$4" --arg i "$5" \
  '{ts: $ts, node: $n, cycle: $c, event: "escalated", repo: $r, item: $i}'; }
burst_log="$WORKDIR/burst.jsonl"
write_log "$burst_log" \
  "$(esc_ev "$(rel -300)" n1 c1 o/r 1)" "$(esc_ev "$(rel -200)" n1 c2 o/r 2)" "$(esc_ev "$(rel -100)" n1 c3 o/r 3)"
PAGER_EVAL_ESCALATION_BURST=2
verdict="$(pager_eval_escalation_burst "[]" "$burst_log")"
assert_eq "3 escalations in 24h, above a burst threshold of 2: fires" "true" "$(jq -r '.firing' <<<"$verdict")"

PAGER_EVAL_ESCALATION_BURST=10
assert_eq "the same 3 escalations under a burst threshold of 10: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_escalation_burst "[]" "$burst_log")")"

reflag_log="$WORKDIR/reflag.jsonl"
write_log "$reflag_log" \
  "$(cycle_ev "$(rel -500)" n1 c1 attempt-failed '{"repo":"o/r","item":"9","detail":"cannot tell what done means","unblock_condition":"a human clarifies scope"}')" \
  "$(esc_ev "$(rel -400)" n1 c1 o/r 9)" \
  "$(cycle_ev "$(rel -300)" n1 c2 attempt-failed '{"repo":"o/r","item":"9","detail":"cannot tell what done means","unblock_condition":"a human clarifies scope"}')" \
  "$(esc_ev "$(rel -200)" n1 c2 o/r 9)"
PAGER_EVAL_ESCALATION_BURST=10
verdict="$(pager_eval_escalation_burst "[]" "$reflag_log")"
assert_eq "the same re-flag reason paged the same item twice: fires despite a high burst threshold" \
  "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names the reflagged item" "1" "$(grep -c 'o/r#9 reflagged 2x' <<<"$(jq -r '.evidence' <<<"$verdict")")"

reflag_log_old="$WORKDIR/reflag-old.jsonl"
write_log "$reflag_log_old" \
  "$(cycle_ev "$(rel -176400)" n1 c1 attempt-failed '{"repo":"o/r","item":"9","detail":"cannot tell what done means","unblock_condition":"a human clarifies scope"}')" \
  "$(esc_ev "$(rel -176000)" n1 c1 o/r 9)" \
  "$(cycle_ev "$(rel -175000)" n1 c2 attempt-failed '{"repo":"o/r","item":"9","detail":"cannot tell what done means","unblock_condition":"a human clarifies scope"}')" \
  "$(esc_ev "$(rel -174000)" n1 c2 o/r 9)"
PAGER_EVAL_ESCALATION_BURST=10
assert_eq "the same re-flag reason, but outside the trailing 24h: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_escalation_burst "[]" "$reflag_log_old")")"

PAGER_EVAL_ESCALATION_BURST=""
assert_eq "no configured burst threshold: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_escalation_burst "[]" "$burst_log")")"

# --- digest-truncated (agent-ops#1281, ts-bound live query per agent-ops#1348) --

digest_ev() { jq -nc --arg ts "$1" --arg r "$2" --argjson ok "$3" --argjson ic "$4" --argjson pc "$5" \
  '{ts: $ts, node: "n1", cycle: "c1", event: "source-state-digest", repo: $r, ok: $ok, issues_count: $ic, open_prs_count: $pc}'; }
digest_ts="2026-01-01T00:00:00Z"
digest_log="$WORKDIR/digest.jsonl"
write_log "$digest_log" "$(digest_ev "$digest_ts" o/r true 50 2)"
STUB_GH_API_MAP=(["search/issues?q=repo:o/r+type:issue+state:open+created:<=$digest_ts"]="150"
                 ["search/issues?q=repo:o/r+type:pr+state:open+created:<=$digest_ts"]="2")
verdict="$(pager_eval_digest_truncated "[]" "$digest_log")"
assert_eq "the digest undercounts a live total as of the digest's own ts: fires" "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names the repo and both counts" "1" \
  "$(grep -c 'o/r (digest issues=50/live=150, digest open_prs=2/live=2)' <<<"$(jq -r '.evidence' <<<"$verdict")")"

: > "$GH_CALLS_FILE"
: > "$WORKDIR/pager-remedy.jsonl"
PAGER_REMEDY_LOG_FILE="$WORKDIR/pager-remedy.jsonl"
PAGER_REMEDY_NODE="n1"
PAGER_REMEDY_CYCLE="c9"
outcome="$(pager_remedy_digest_truncated digest-truncated "$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "the remedy vetoes the affected repo" "vetoed this cycle's work-gone clearances for 1 repo(s) pending a healthy digest" "$outcome"
assert_eq "  ... logging a digest-truncation-veto event" "1" \
  "$(grep -c '"event":"digest-truncation-veto"' "$WORKDIR/pager-remedy.jsonl")"
assert_eq "  ... naming the affected repo" "1" \
  "$(grep -c '"repo":"o/r"' "$WORKDIR/pager-remedy.jsonl")"

STUB_GH_API_MAP=(["search/issues?q=repo:o/r+type:issue+state:open+created:<=$digest_ts"]="50"
                 ["search/issues?q=repo:o/r+type:pr+state:open+created:<=$digest_ts"]="2")
assert_eq "a digest that matches the live count as of its own ts: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_digest_truncated "[]" "$digest_log")")"

# The #1348 false positive this bound exists to prevent: the digest matches
# the live total as of its own ts (the case just above), but ordinary
# traffic since then has created more issues/PRs — an unbounded "right now"
# query would see those and fire; the ts-bound query must not.
STUB_GH_API_MAP=(["search/issues?q=repo:o/r+type:issue+state:open+created:<=$digest_ts"]="50"
                 ["search/issues?q=repo:o/r+type:pr+state:open+created:<=$digest_ts"]="2"
                 ["search/issues?q=repo:o/r+type:issue+state:open"]="217"
                 ["search/issues?q=repo:o/r+type:pr+state:open"]="3")
assert_eq "more issues/PRs exist by evaluation time than as of the digest's own ts: does not fire (the #1348 signature)" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_digest_truncated "[]" "$digest_log")")"

digest_log_empty="$WORKDIR/digest-empty.jsonl"
: > "$digest_log_empty"
assert_eq "no source-state-digest events at all: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_digest_truncated "[]" "$digest_log_empty")")"

# --- landing-never-armed (agent-ops#1280) -----------------------------------

landing_ev() {  # landing_ev TS EVENT REPO [REASON]
  jq -nc --arg ts "$1" --arg ev "$2" --arg r "$3" --arg reason "${4:-}" \
    '{ts: $ts, node: "n1", cycle: "c1", event: $ev, repo: $r}
     + (if $reason == "" then {} else {reason: $reason} end)'
}

lna_log="$WORKDIR/landing-never-armed.jsonl"
write_log "$lna_log" \
  "$(landing_ev "$(rel -500000)" landing-refused o/r "unknown:could not establish o/r#1's changed-file list")" \
  "$(landing_ev "$(rel -400000)" landing-refused o/r "ineligible:complexity high")" \
  "$(landing_ev "$(rel -300000)" landing-refused human/repo "ineligible:complexity high")"

PAGER_EVAL_REPOS_JSON='[{"slug":"o/r","merge_autonomy":"agent-merges-routine"},
  {"slug":"human/repo","merge_autonomy":"human"},
  {"slug":"idle/repo","merge_autonomy":"agent-merges-all"}]'
PAGER_EVAL_LANDING_ARMED_WITHIN_DAYS=7
verdict="$(pager_eval_landing_never_armed "[]" "$lna_log")"
assert_eq "a repo at agent-merges-routine with refusals and zero armings in the window: fires" \
  "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names the repo and its refusal count" "1" \
  "$(grep -c 'o/r (2 refusal' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... a repo at human is excluded despite the same refusal pattern" "0" \
  "$(grep -c 'human/repo' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... a repo with no landing-refused activity in the window never fires" "0" \
  "$(grep -c 'idle/repo' <<<"$(jq -r '.evidence' <<<"$verdict")")"

: > "$GH_CALLS_FILE"
PAGER_REMEDY_REPO="reader/repo"
outcome="$(pager_remedy_landing_never_armed landing-never-armed "$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "the remedy reports what it filed" "1" "$(grep -c 'reader/repo#701' <<<"$outcome")"
assert_eq "  ... labelled pw::type:tech-debt" "1" \
  "$(grep '^issue create' "$GH_CALLS_FILE" | grep -c 'pw::type:tech-debt')"

lna_log_armed="$WORKDIR/landing-never-armed-armed.jsonl"
write_log "$lna_log_armed" \
  "$(landing_ev "$(rel -500000)" landing-refused o/r "unknown:could not establish o/r#1's changed-file list")" \
  "$(landing_ev "$(rel -300000)" landing-armed o/r)"
assert_eq "a landing-armed event inside the window: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_landing_never_armed "[]" "$lna_log_armed")")"

PAGER_EVAL_REPOS_JSON_SAVE="$PAGER_EVAL_REPOS_JSON"
PAGER_EVAL_REPOS_JSON=""
assert_eq "no PAGER_EVAL_REPOS_JSON configured: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_landing_never_armed "[]" "$lna_log")")"
PAGER_EVAL_REPOS_JSON="$PAGER_EVAL_REPOS_JSON_SAVE"
PAGER_EVAL_LANDING_ARMED_WITHIN_DAYS=""
assert_eq "no PAGER_EVAL_LANDING_ARMED_WITHIN_DAYS configured: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_landing_never_armed "[]" "$lna_log")")"
PAGER_EVAL_LANDING_ARMED_WITHIN_DAYS=7

# --- landing-refused-unknown (agent-ops#1280) -------------------------------

refused_ev() { jq -nc --arg ts "$1" --arg reason "$2" \
  '{ts: $ts, node: "n1", cycle: "c1", event: "landing-refused", repo: "o/r", reason: $reason}'; }

lru_log="$WORKDIR/landing-refused-unknown.jsonl"
{
  for i in 1 2 3 4 5 6; do refused_ev "$(rel -300)" "unknown:could not establish o/r#$i's changed-file list"; done
  for i in 1 2 3 4; do refused_ev "$(rel -300)" "ineligible:complexity high"; done
} > "$lru_log"
verdict="$(pager_eval_landing_refused_unknown "[]" "$lru_log")"
assert_eq "6 of 10 landing-refused events are class unknown (>= half, >= 5): fires" \
  "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names the count" "1" "$(grep -c '6 of 10' <<<"$(jq -r '.evidence' <<<"$verdict")")"

: > "$GH_CALLS_FILE"
PAGER_REMEDY_REPO="reader/repo"
outcome="$(pager_remedy_landing_refused_unknown landing-refused-unknown "$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "the remedy reports what it filed" "1" "$(grep -c 'reader/repo#701' <<<"$outcome")"
assert_eq "  ... labelled pw::type:tech-debt" "1" \
  "$(grep '^issue create' "$GH_CALLS_FILE" | grep -c 'pw::type:tech-debt')"

lru_log_below_floor="$WORKDIR/landing-refused-unknown-floor.jsonl"
{
  for i in 1 2 3 4; do refused_ev "$(rel -300)" "unknown:could not establish o/r#$i's changed-file list"; done
  for i in 1 2; do refused_ev "$(rel -300)" "ineligible:complexity high"; done
} > "$lru_log_below_floor"
assert_eq "4 of 6 are unknown (>= half, but below the 5-event floor): does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_landing_refused_unknown "[]" "$lru_log_below_floor")")"

lru_log_below_half="$WORKDIR/landing-refused-unknown-half.jsonl"
{
  for i in 1 2 3 4 5; do refused_ev "$(rel -300)" "unknown:could not establish o/r#$i's changed-file list"; done
  for i in 1 2 3 4 5 6; do refused_ev "$(rel -300)" "ineligible:complexity high"; done
} > "$lru_log_below_half"
assert_eq "5 of 11 are unknown (above the floor, but below half): does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_landing_refused_unknown "[]" "$lru_log_below_half")")"

lru_log_old="$WORKDIR/landing-refused-unknown-old.jsonl"
{
  for i in 1 2 3 4 5 6; do refused_ev "$(rel -176000)" "unknown:could not establish o/r#$i's changed-file list"; done
} > "$lru_log_old"
assert_eq "the same shape, but outside the trailing 24h: does not fire" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_landing_refused_unknown "[]" "$lru_log_old")")"

# --- pr-unreviewed (agent-ops#1280) -----------------------------------------

pr_row() {  # pr_row NUMBER URL IS_DRAFT REVIEW_DECISION CREATED_AT HEAD
  jq -nc --argjson n "$1" --arg u "$2" --argjson d "$3" --arg rd "$4" --arg c "$5" --arg h "$6" \
    '{number: $n, url: $u, isDraft: $d, reviewDecision: $rd, createdAt: $c, headRefOid: $h}'
}
pr_created_old="2020-01-01T00:00:00Z"
pr_created_recent="$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

# #10 ready, no standing review, never touched: the one candidate. #11 is a
# draft. #12 already carries a standing (APPROVED) decision. #13 is younger
# than the engage cutoff. #14/#15/#16 are each excluded by one of the three
# disqualifying union-log events below, one apiece.
STUB_GH_PR_LIST_BY_REPO=(
  [o/r]="$(jq -sc '.' <<PR_ROWS
$(pr_row 10 "https://github.com/o/r/pull/10" false ""         "$pr_created_old"    "sha10")
$(pr_row 11 "https://github.com/o/r/pull/11" true  ""         "$pr_created_old"    "sha11")
$(pr_row 12 "https://github.com/o/r/pull/12" false "APPROVED" "$pr_created_old"    "sha12")
$(pr_row 13 "https://github.com/o/r/pull/13" false ""         "$pr_created_recent" "sha13")
$(pr_row 14 "https://github.com/o/r/pull/14" false ""         "$pr_created_old"    "sha14")
$(pr_row 15 "https://github.com/o/r/pull/15" false ""         "$pr_created_old"    "sha15")
$(pr_row 16 "https://github.com/o/r/pull/16" false ""         "$pr_created_old"    "sha16")
PR_ROWS
)"
)

pru_log="$WORKDIR/pr-unreviewed.jsonl"
write_log "$pru_log" \
  "$(jq -nc '{ts:"2026-01-01T00:00:00Z", node:"n1", cycle:"c1", event:"approver-unreviewed-engaged",
    pr_url:"https://github.com/o/r/pull/14", repo:"o/r", head:"sha14", result:"unavailable"}')" \
  "$(jq -nc '{ts:"2026-01-01T00:00:00Z", node:"n1", cycle:"c1", event:"approver-verdict",
    pr_url:"https://github.com/o/r/pull/15", repo:"o/r", verdict:"changes-requested"}')" \
  "$(jq -nc '{ts:"2026-01-01T00:00:00Z", node:"n1", cycle:"c1", event:"warning",
    pr_url:"https://github.com/o/r/pull/16",
    detail:"could not read the Approver App'\''s own login — no App review was posted"}')"

PAGER_EVAL_REPOS_JSON='[{"slug":"o/r"}]'
PAGER_EVAL_PR_LABEL="autonomous-agent"
PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS=2
verdict="$(pager_eval_pr_unreviewed "[]" "$pru_log")"
assert_eq "a ready pull request with no standing review and no engagement history at all: fires" \
  "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... evidence names exactly #10" "1" "$(grep -c 'o/r#10' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... the draft (#11) is excluded" "0" "$(grep -c 'o/r#11' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... the already-decided review (#12) is excluded" "0" "$(grep -c 'o/r#12' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... the too-young pull request (#13) is excluded" "0" "$(grep -c 'o/r#13' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... the already-engaged pull request (#14) is excluded" "0" "$(grep -c 'o/r#14' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... the already-verdicted pull request (#15) is excluded" "0" "$(grep -c 'o/r#15' <<<"$(jq -r '.evidence' <<<"$verdict")")"
assert_eq "  ... the already-warned pull request (#16) is excluded" "0" "$(grep -c 'o/r#16' <<<"$(jq -r '.evidence' <<<"$verdict")")"

pager_remedy_pr="$WORKDIR/pager-remedy-pr.jsonl"
: > "$pager_remedy_pr"
PAGER_REMEDY_LOG_FILE="$pager_remedy_pr"
PAGER_REMEDY_UNION_LOG_FILE="$pru_log"
PAGER_REMEDY_NODE="n1"
PAGER_REMEDY_CYCLE="c9"
outcome="$(pager_remedy_pr_unreviewed pr-unreviewed "irrelevant, re-derived live")"
assert_eq "the remedy enqueues exactly the one candidate" \
  "enqueued 1 ready pull request(s) into requirement 46's own retry/escalate memory (approver-unreviewed-engaged, result: unavailable)" \
  "$outcome"
assert_eq "  ... logging a fresh approver-unreviewed-engaged event for #10" "1" \
  "$(grep -c '\"pr_url\":\"https://github.com/o/r/pull/10\"' "$pager_remedy_pr")"
assert_eq "  ... result unavailable, never claiming a real review was posted" "1" \
  "$(grep -c '\"result\":\"unavailable\"' "$pager_remedy_pr")"

# issue #1366: an empty cutoff here disables the *entire* pr-unreviewed
# invariant just as silently. _pager_pr_unreviewed_candidates's own upstream
# regex (`^[0-9]+([.][0-9]+)?$`) already turns away a non-numeric value like
# "2h" before it ever reaches this guard, so a value big enough to overflow
# jq's own strftime is used instead — schema-legal (digits only, no
# `maximum` in config.schema.json), but still empties the cutoff the same
# way.
pr_unreviewed_warn_log="$WORKDIR/pr-unreviewed-warn.jsonl"
: > "$pr_unreviewed_warn_log"
PAGER_REMEDY_LOG_FILE="$pr_unreviewed_warn_log"
PAGER_REMEDY_NODE="n1"
PAGER_REMEDY_CYCLE="c9"
PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS="99999999999999999999"
verdict="$(pager_eval_pr_unreviewed "[]" "$pru_log")"
assert_eq "a cutoff so large jq's own strftime overflows still fails safe: never fires" \
  "false" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... but logs a warning naming the actual config key" "1" \
  "$(grep -c '\"key\":\"approver_unreviewed_engage_after_hours\"' "$pr_unreviewed_warn_log")"
assert_eq "  ... and the raw value that failed to produce a cutoff" "1" \
  "$(grep -c '\"value\":\"99999999999999999999\"' "$pr_unreviewed_warn_log")"
assert_eq "  ... and the function it fired from" "1" \
  "$(grep -c '\"fn\":\"_pager_ready_pr_candidates\"' "$pr_unreviewed_warn_log")"
PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS=2

PAGER_EVAL_REPOS_JSON=""
assert_eq "no PAGER_EVAL_REPOS_JSON configured: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_pr_unreviewed "[]" "$pru_log")")"
PAGER_EVAL_REPOS_JSON='[{"slug":"o/r"}]'
PAGER_EVAL_PR_LABEL=""
assert_eq "no PAGER_EVAL_PR_LABEL configured: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_pr_unreviewed "[]" "$pru_log")")"
PAGER_EVAL_PR_LABEL="autonomous-agent"
PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS=""
assert_eq "no PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS configured: never fires" "false" \
  "$(jq -r '.firing' <<<"$(pager_eval_pr_unreviewed "[]" "$pru_log")")"
PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS=2

# issue #1353: a fractional engage cutoff is schema-legal (type: number), but
# GNU date's relative parser this used to rely on rejects "1.5 hours ago"
# outright, which failed the cutoff closed and would have made this
# invariant a silent no-op right alongside the sweep it exists to watch.
PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS="1.5"
verdict="$(pager_eval_pr_unreviewed "[]" "$pru_log")"
assert_eq "a fractional engage cutoff (1.5h) still fires for the same stale candidate" \
  "true" "$(jq -r '.firing' <<<"$verdict")"
assert_eq "  ... naming #10" "1" "$(grep -c 'o/r#10' <<<"$(jq -r '.evidence' <<<"$verdict")")"
PAGER_EVAL_APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS=2

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
