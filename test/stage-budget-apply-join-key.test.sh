#!/usr/bin/env bash
# shellcheck disable=SC2034
# stage_budget_json is read only by the extracted `stage_budget_apply` body
# below, `eval`-defined rather than sourced, so shellcheck cannot see the use
# and reports it unused — the same false positive lib/merge-observed.sh's own
# header disables for the same reason (a variable this file's own functions
# read and write, assigned once here rather than locally).
#
# test/stage-budget-apply-join-key.test.sh — regression test for the
# item-lifecycle join key (requirement 49, issue #595) on `stage-start`:
# `stage_budget_apply` (agent-cycle.sh) carries `{repo, item}` when its
# caller has them, and omits both — never logs a literal `null` — when REPO
# is the fleet-wide `*` a stage that runs ahead of or across selection
# passes (the Co-Ordinator, the Enabler, the Refiner) or ITEM is left empty.
#
# `stage_budget_apply` itself is lifted verbatim out of agent-cycle.sh, the
# same technique test/landing-wiring.test.sh and its siblings use, so the
# assertions are about the shipped code rather than a copy of its logic.
# `lib/stage-budget.sh` (`stage_budget_resolve`, `STAGE_BUDGET_PRIORS`) runs
# for real — it is a small, already-tested pure resolution
# (test/stage-budget.test.sh covers it directly) — and only
# `stage_budget_overrides` (agent-cycle.sh's own per-repo config read) and
# `log_event` are stubbed.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/stage-budget-apply-join-key.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

extract() {  # <function name>
  awk -v fn="^$1\\\\(\\\\) \\\\{" '$0 ~ fn { on = 1 } on { print } on && /^\}$/ { exit }' "$CYCLE"
}

fn_block="$(extract stage_budget_apply)"
if [[ -z "$fn_block" || "$fn_block" != *"stage-start"* ]]; then
  echo "FAIL - could not extract stage_budget_apply from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# shellcheck source=lib/stage-budget.sh
. "$SCRIPT_DIR/lib/stage-budget.sh"
stage_budget_overrides() { printf '{}'; }

events_file="$(mktemp)"
trap 'rm -f "$events_file"' EXIT
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$events_file"; }
eval "$fn_block"

event_of() { grep -m1 "^$1"$'\t' "$events_file" | cut -f2- || true; }

# --- A real item-scoped stage carries both -------------------------------------
: > "$events_file"
stage_budget_json='{}'
stage_budget_apply implementer "acme/widgets" "claude-test-model" '{}' "42"
assert_eq "an item-scoped stage's stage-start names its repo" \
  '"acme/widgets"' "$(jq -c '.repo' <<<"$(event_of stage-start)")"
assert_eq "  ... and its item" '"42"' "$(jq -c '.item' <<<"$(event_of stage-start)")"
assert_eq "  ... alongside the stage/model fields already there" \
  '"implementer"' "$(jq -c '.stage' <<<"$(event_of stage-start)")"

# --- A fleet-wide stage (REPO "*") carries neither, never a literal null ------
: > "$events_file"
stage_budget_apply coordinator "*" "claude-test-model"
out="$(event_of stage-start)"
assert_eq "a fleet-wide stage's stage-start omits repo entirely" \
  "false" "$(jq -c 'has("repo")' <<<"$out")"
assert_eq "  ... and omits item entirely" "false" "$(jq -c 'has("item")' <<<"$out")"

# --- A real repo but no item (ITEM left empty) omits item alone --------------
: > "$events_file"
stage_budget_apply approver-adjudicate-open-question "acme/widgets" "claude-test-model" '{}'
out="$(event_of stage-start)"
assert_eq "a repo with no item omits item alone" "false" "$(jq -c 'has("item")' <<<"$out")"
assert_eq "  ... while still naming its repo" '"acme/widgets"' "$(jq -c '.repo' <<<"$out")"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
