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

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
