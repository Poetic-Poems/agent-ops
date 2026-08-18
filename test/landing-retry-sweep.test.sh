#!/usr/bin/env bash
#
# test/landing-retry-sweep.test.sh — regression test for
# `_landing_retry_sweep_repo`, the 2.1e landing-retry sweep's own candidate
# rule (requirement 2.1e, TD-PPagop-26081701).
#
# `test/landing-wiring.test.sh` already covers the six gates
# `_landing_stage_attempt` runs once a candidate reaches it, including a
# direct call with RETRY set. This file covers what decides which pull
# requests reach that call at all: the level pre-check, the open/non-draft/
# complexity filter, the standing-Approver-review precondition, and the
# `landing_retry_source` lookup that resolves the one gate this sweep cannot
# re-read fresh from GitHub. `_landing_stage_attempt` itself is stubbed here
# — this file is about what is offered to it, never about what it does with
# an offer — except for its own `_landing_stage_attempt_armed` global, which
# the stub sets on cue so this file can also pin the per-pass merge-budget
# bound: `armed_this_pass`, threaded through as `_landing_stage_attempt`'s own
# ALREADY_ARMED argument, must grow by exactly one after each candidate the
# stub reports as armed and stay put after one it reports as refused (PR #557
# review of TD-PPagop-26081701).
#
# `_landing_retry_sweep_repo` is lifted verbatim out of agent-cycle.sh, the
# same technique test/landing-wiring.test.sh and its siblings use, so the
# assertions are about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/landing-retry-sweep.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file assembles a harness script whose `$`-expressions must reach the
# assembled file unexpanded; the single-quoted here-doc and `printf` lines
# below are deliberate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$CYCLE"
}

sweep_block="$(extract _landing_retry_sweep_repo)"
if [[ -z "$sweep_block" || "$sweep_block" != *"_landing_stage_attempt"* ]]; then
  echo "FAIL - could not extract _landing_retry_sweep_repo from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Assembly -----------------------------------------------------------------
# PR_LIST_JSON is the `gh pr list` fixture; STANDING_<n> / SOURCE_<branch,
# sanitised> steer the per-candidate stubs; LEVEL/DEFAULT_BRANCH_RC/
# LIST_TRUNCATED steer the repo-level ones.

cat >"$tmp_dir/harness.sh" <<'HARNESS'
set -euo pipefail

# shellcheck source=lib/github-limit.sh
source "$SCRIPT_DIR/lib/github-limit.sh"

pr_label="autonomous-agent"
DEFAULTED_CONFIG='{}'
state_repo="acme/widgets"
state_dir="$T/state"
union_log="$T/union-log.jsonl"
mkdir -p "$state_dir"
: > "$union_log"

log_event() { printf '%s\t%s\n' "$1" "$2" >>"$T/events"; }

merge_autonomy_effective_level() { printf '%s' "$LEVEL"; }

gh() {
  if [[ "$1" == "api" ]]; then
    [[ "${DEFAULT_BRANCH_RC:-0}" == "0" ]] || return 1
    printf '%s' "${DEFAULT_BRANCH:-main}"
    return 0
  fi
  if [[ "$1" == "pr" && "$2" == "list" ]]; then
    printf '%s' "$PR_LIST_JSON"
    return 0
  fi
  return 1
}

github_pr_list_truncated_orig="$(declare -f github_pr_list_truncated)"
if [[ "${FORCE_TRUNCATED:-0}" == "1" ]]; then
  github_pr_list_truncated() { return 0; }
fi

landing_approver_standing_review() {
  local slug="$1" number="$2"
  local var="STANDING_$number"
  [[ "${!var:-0}" != "RC1" ]] || return 1
  printf '%s' "${!var:-}"
}

landing_retry_source() {
  local slug="$1" branch="$2"
  local key="SOURCE_${branch//[^A-Za-z0-9]/_}"
  printf '%s' "${!key:-}"
}

_landing_stage_attempt() {
  local pr_url="$2" already_armed="${7:-0}" num="${2##*/}" armvar
  printf 'slug=%s\tpr_url=%s\tcomplexity=%s\tsource=%s\tdefault_branch=%s\tretry=%s\talready_armed=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "${6:-}" "$already_armed" >>"$T/attempts"
  # Simulates an arm/refusal outcome per candidate, steered by ARM_<number>
  # (mirroring STANDING_<number> above), so a test can pin how the caller's
  # own running tally (`armed_this_pass`) grows across a pass — PR #557
  # review of TD-PPagop-26081701.
  armvar="ARM_$num"
  if [[ "${!armvar:-0}" == "1" ]]; then
    _landing_stage_attempt_armed=1
  else
    _landing_stage_attempt_armed=0
  fi
}

HARNESS

{
  printf '%s\n' "$sweep_block"
  printf '_landing_retry_sweep_repo "acme/widgets" "pullwright-approver[bot]"\n'
} >>"$tmp_dir/harness.sh"

# --- Fixtures -----------------------------------------------------------------

pr_open() {  # number url branch draft complexity_label
  jq -nc --argjson n "$1" --arg u "$2" --arg b "$3" --argjson d "$4" --arg c "$5" \
    '{number: $n, url: $u, headRefName: $b, isDraft: $d,
      labels: (if $c == "" then [] else [{name: $c}] end)}'
}

run_case() {  # PR_LIST_JSON=... plus any stub-steering env
  : >"$tmp_dir/events"; : >"$tmp_dir/attempts"
  env -i PATH="$PATH" HOME="$HOME" \
    T="$tmp_dir" SCRIPT_DIR="$SCRIPT_DIR" \
    LEVEL="agent-merges-routine" \
    "$@" \
    bash "$tmp_dir/harness.sh" >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
  printf '%s' "$?"
}

attempts() { cat "$tmp_dir/attempts" 2>/dev/null || true; }
count_attempts() { [[ -s "$tmp_dir/attempts" ]] && wc -l <"$tmp_dir/attempts" | tr -d ' ' || printf '0'; }
events() { cat "$tmp_dir/events" 2>/dev/null || true; }

open_list="$(jq -sc '.' <(
  pr_open 1 "https://github.com/acme/widgets/pull/1" "td/TD-1" false "complexity:low"
  pr_open 2 "https://github.com/acme/widgets/pull/2" "td/TD-2" true  "complexity:low"
  pr_open 3 "https://github.com/acme/widgets/pull/3" "agent/x" false "complexity:high"
  pr_open 4 "https://github.com/acme/widgets/pull/4" "agent/y" false ""
))"

# --- The happy path: one eligible candidate reaches _landing_stage_attempt --

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="APPROVED" SOURCE_td_TD_1="tech-debt")"
assert_eq "a well-formed sweep returns 0" "0" "$rc"
assert_eq "exactly the one open, non-draft, low/medium, approved candidate is offered" \
  "1" "$(count_attempts)"
assert_contains "  ... with its own slug" "slug=acme/widgets" "$(attempts)"
assert_contains "  ... its own pull request url" "pr_url=https://github.com/acme/widgets/pull/1" "$(attempts)"
assert_contains "  ... the complexity read off its own label" "complexity=low" "$(attempts)"
assert_contains "  ... the source landing_retry_source resolved" "source=tech-debt" "$(attempts)"
assert_contains "  ... and RETRY set" "retry=retry" "$(attempts)"

# --- Level pre-check: no candidate is even listed below agent-merges-routine -

for level in human agent-approves; do
  rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="APPROVED" SOURCE_td_TD_1="tech-debt" LEVEL="$level")"
  assert_eq "at $level nothing is offered" "0" "$(count_attempts)"
  assert_eq "  ... returning 0" "0" "$rc"
done

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="APPROVED" SOURCE_td_TD_1="tech-debt" LEVEL="agent-merges-all")"
assert_eq "agent-merges-all offers on the same terms" "1" "$(count_attempts)"

# --- Draft, complexity:high and no-complexity-label are excluded up front --

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="APPROVED" SOURCE_td_TD_1="tech-debt")"
assert_eq "  ... a draft PR (#2) is never offered" "" "$(grep 'pull/2' <(attempts) || true)"
assert_eq "  ... a complexity:high PR (#3) is never offered" "" "$(grep 'pull/3' <(attempts) || true)"
assert_eq "  ... a PR with no complexity label at all (#4) is never offered" "" "$(grep 'pull/4' <(attempts) || true)"

# --- The standing-Approver-review precondition -------------------------------

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="" SOURCE_td_TD_1="tech-debt")"
assert_eq "a PR never reviewed by the Approver is not offered" "0" "$(count_attempts)"
assert_eq "  ... and nothing is logged for it (ordinary in-flight work, not a stall)" "" "$(events)"

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="CHANGES_REQUESTED" SOURCE_td_TD_1="tech-debt")"
assert_eq "a superseded Approver review is not offered" "0" "$(count_attempts)"

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="RC1" SOURCE_td_TD_1="tech-debt")"
assert_eq "an unreadable standing-review read is not offered (never a guessed pass)" "0" "$(count_attempts)"

# --- The source lookup --------------------------------------------------------

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="APPROVED")"
assert_eq "a candidate whose source cannot be resolved is skipped, never guessed at" \
  "0" "$(count_attempts)"

# --- The truncated-listing warning --------------------------------------------

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="APPROVED" SOURCE_td_TD_1="tech-debt" FORCE_TRUNCATED="1")"
assert_contains "a truncated pull-request listing logs a warning naming the repo" \
  "acme/widgets" "$(events)"
assert_contains "  ... and says a stranded pull request beyond the cap is not retried" \
  "not retried this cycle" "$(events)"

# --- The default-branch fallback ----------------------------------------------

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="APPROVED" SOURCE_td_TD_1="tech-debt" DEFAULT_BRANCH_RC="1")"
assert_contains "an unreadable default branch falls back to main" \
  "default_branch=main" "$(attempts)"

rc="$(run_case PR_LIST_JSON="$open_list" STANDING_1="APPROVED" SOURCE_td_TD_1="tech-debt" DEFAULT_BRANCH="trunk")"
assert_contains "the repository's own default branch, read fresh, is what is passed through" \
  "default_branch=trunk" "$(attempts)"

# --- The per-pass merge-budget bound (PR #557 review of TD-PPagop-26081701) --
# Three eligible candidates offered in one pass: each `_landing_stage_attempt`
# call must carry this pass's own running arm count so far, never a stale 0
# every time — the defect that let an unbounded pass arm every stranded pull
# request in one go regardless of `merge_budget_per_day`.

multi_list="$(jq -sc '.' <(
  pr_open 11 "https://github.com/acme/widgets/pull/11" "td/TD-11" false "complexity:low"
  pr_open 12 "https://github.com/acme/widgets/pull/12" "td/TD-12" false "complexity:medium"
  pr_open 13 "https://github.com/acme/widgets/pull/13" "td/TD-13" false "complexity:low"
))"

already_armed_seq() { attempts | grep -o 'already_armed=[0-9]*' | cut -d= -f2 | paste -sd, -; }

rc="$(run_case PR_LIST_JSON="$multi_list" \
  STANDING_11="APPROVED" STANDING_12="APPROVED" STANDING_13="APPROVED" \
  SOURCE_td_TD_11="tech-debt" SOURCE_td_TD_12="tech-debt" SOURCE_td_TD_13="tech-debt" \
  ARM_11="1" ARM_12="1" ARM_13="1")"
assert_eq "all three eligible candidates are offered" "3" "$(count_attempts)"
assert_eq "  ... and the tally grows by one after each arm: 0, then 1, then 2" \
  "0,1,2" "$(already_armed_seq)"

rc="$(run_case PR_LIST_JSON="$multi_list" \
  STANDING_11="APPROVED" STANDING_12="APPROVED" STANDING_13="APPROVED" \
  SOURCE_td_TD_11="tech-debt" SOURCE_td_TD_12="tech-debt" SOURCE_td_TD_13="tech-debt" \
  ARM_11="1" ARM_13="1")"
assert_eq "a candidate that does not arm (#12) never grows the tally" \
  "0,1,1" "$(already_armed_seq)"

# --- Result -------------------------------------------------------------------

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
