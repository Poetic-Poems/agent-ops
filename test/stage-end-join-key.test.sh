#!/usr/bin/env bash
# shellcheck disable=SC2034
# impl_rc/rev_rc/impl_model/impl_out/stage_kill_reason/stage_gaps_json/
# selected_repo/selected_item are read only by the extracted blocks below,
# `eval`-defined rather than sourced, so shellcheck cannot see the use — the
# same false positive test/pr-raised-join-key.test.sh disables for the same
# reason.
#
# test/stage-end-join-key.test.sh — regression test for the item-lifecycle
# join key (requirement 49, issue #595) on `stage-end` at agent-cycle.sh's own
# two item-scoped sites: the Implementer's and the Reviewer's. Both carry
# `{repo, item}` whenever the cycle knows them, and omit either — never a
# literal `null` — when it does not.
#
# These two sites are the pair a reader is most likely to assume are covered
# by test/stage-budget-apply-join-key.test.sh and are not: that test pins
# `stage-start`, which agent-cycle.sh emits from inside `stage_budget_apply`,
# while every `stage-end` is written at its own call site. `lib/approver.sh`'s
# and `lib/enabler.sh`'s own `stage-end` sites are pinned by
# test/approver-wiring.test.sh and their own siblings.
#
# Lifted verbatim, the same technique test/pr-raised-join-key.test.sh uses, so
# the assertions are about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/stage-end-join-key.test.sh
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

# The `stage-end` statement whose exit code is RC_VAR, from its own
# `log_event` line through the line that closes the jq program.
extract() {  # <rc-variable-name>
  local needle='--argjson rc "$'"$1"'"'
  awk -v rc="$needle" '
    index($0, rc) && /^log_event "stage-end"/ { on = 1 }
    on { print }
    on && /end\)\047\)"$/ { exit }
  ' "$CYCLE"
}

impl_block="$(extract impl_rc)"
rev_block="$(extract rev_rc)"
for pair in "implementer:$impl_block" "reviewer:$rev_block"; do
  name="${pair%%:*}"
  body="${pair#*:}"
  if [[ -z "$body" || "$body" != *"stage: \"$name\""* ]]; then
    echo "FAIL - could not extract the $name stage-end from agent-cycle.sh — has it moved?" >&2
    exit 1
  fi
done

events_file="$(mktemp)"
trap 'rm -f "$events_file"' EXIT
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$events_file"; }
event_of() { grep -m1 "^$1"$'\t' "$events_file" | cut -f2- || true; }
metering_fields() { printf '{"model":"%s"}' "$1"; }

run_it() {  # <block> <rc-variable-name> <selected_repo> <selected_item>
  : > "$events_file"
  ( selected_repo="$3" selected_item="$4" stage_kill_reason="" stage_gaps_json='[]' \
    impl_model="m" impl_out="/dev/null" rev_model="m" rev_out="/dev/null"
    printf -v "$2" '%s' 0
    eval "$1" )
}

# --- The Implementer's stage-end ----------------------------------------------

run_it "$impl_block" impl_rc "acme/widgets" "42"
out="$(event_of stage-end)"
assert_eq "the Implementer's stage-end names its repo" '"acme/widgets"' "$(jq -c '.repo' <<<"$out")"
assert_eq "  ... and its item" '"42"' "$(jq -c '.item' <<<"$out")"
assert_eq "  ... alongside the stage/exit_code fields already there" \
  '["implementer",0]' "$(jq -c '[.stage, .exit_code]' <<<"$out")"
assert_eq "  ... and the metering fields it already merged" \
  '"m"' "$(jq -c '.model' <<<"$out")"

run_it "$impl_block" impl_rc "acme/widgets" ""
out="$(event_of stage-end)"
assert_eq "an empty item is omitted entirely, never logged null" \
  "false" "$(jq -c 'has("item")' <<<"$out")"
assert_eq "  ... while repo is still present" '"acme/widgets"' "$(jq -c '.repo' <<<"$out")"

run_it "$impl_block" impl_rc "" ""
out="$(event_of stage-end)"
assert_eq "an empty repo is omitted entirely too" "false" "$(jq -c 'has("repo")' <<<"$out")"

# --- The Reviewer's stage-end -------------------------------------------------

run_it "$rev_block" rev_rc "acme/widgets" "42"
out="$(event_of stage-end)"
assert_eq "the Reviewer's stage-end names its repo and item" \
  '["acme/widgets","42"]' "$(jq -c '[.repo, .item]' <<<"$out")"
assert_eq "  ... alongside the stage field already there" \
  '"reviewer"' "$(jq -c '.stage' <<<"$out")"

run_it "$rev_block" rev_rc "acme/widgets" ""
assert_eq "the Reviewer omits an empty item too, never logging null" \
  "false" "$(jq -c 'has("item")' <<<"$(event_of stage-end)")"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
