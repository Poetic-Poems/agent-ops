#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# SC2034: sweep_slug/sweep_action are read only by the extracted `case` block
# below, `eval`-defined rather than sourced, so shellcheck cannot see the
# use — the same false positive lib/merge-observed.sh's own header disables
# for the same reason.
# SC2016: the fixed grep pattern locating that block's own `case` line is
# jq/bash source text, deliberately single-quoted so nothing in it expands.
#
# test/standdown-sweep-join-key.test.sh — regression test for the
# item-lifecycle join key (requirement 49, issue #595) on the two events
# `lib/standdown.sh` logs from `scripts/sweep-closed-issues.sh`'s own
# actions: `issue-closed-post-merge` (carries `item`, derived from the
# sweep's own `issue` field, alongside the `issue` field itself — additive,
# never a rename) and `merge-observed` (one of the item-lifecycle record's
# two merge observation points this sweep adds, per that event's own
# `stage` naming which read caught it).
#
# The `case` block is lifted verbatim, the same technique
# test/landing-wiring.test.sh and its siblings use, so the assertions are
# about the shipped code rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/standdown-sweep-join-key.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDDOWN="$SCRIPT_DIR/lib/standdown.sh"

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

# lib/standdown.sh has more than one `case "$(jq -r '.action // ""')" in`
# block (the orphan-branch sweep's own, ahead of this one) — anchored here on
# the arm unique to this sweep (`closed) log_event "issue-closed-post-merge"`)
# and walked backwards/forwards to that one block's own `case`/`esac`.
arm_line="$(grep -n 'closed) log_event "issue-closed-post-merge"' "$STANDDOWN" | head -1 | cut -d: -f1)"
case_line="$(head -n "$arm_line" "$STANDDOWN" | grep -n '^      case "\$(jq -r' | tail -1 | cut -d: -f1)"
esac_line="$(tail -n "+$arm_line" "$STANDDOWN" | grep -n '^      esac$' | head -1 | cut -d: -f1)"
esac_line="$(( arm_line + esac_line - 1 ))"
block="$(sed -n "${case_line},${esac_line}p" "$STANDDOWN")"
if [[ -z "$block" || "$block" != *"issue-closed-post-merge"* || "$block" != *"merge-observed"* ]]; then
  echo "FAIL - could not extract the sweep-closed-issues case block from lib/standdown.sh — has it moved?" >&2
  exit 1
fi

events_file="$(mktemp)"
trap 'rm -f "$events_file"' EXIT
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$events_file"; }
event_of() { grep -m1 "^$1"$'\t' "$events_file" | cut -f2- || true; }

run_it() {  # <sweep_action_json>
  : > "$events_file"
  ( sweep_slug="acme/widgets" sweep_action="$1"
    eval "$block" )
}

run_it '{"action":"closed","issue":198,"pr_number":206,"pr_url":"https://github.com/acme/widgets/pull/206"}'
assert_eq "issue-closed-post-merge carries item alongside the existing issue field" \
  '{"repo":"acme/widgets","item":"198","issue":198,"pr_number":206,"pr_url":"https://github.com/acme/widgets/pull/206"}' \
  "$(event_of issue-closed-post-merge)"

run_it '{"action":"merge-observed","pr_number":300,"pr_url":"https://github.com/acme/widgets/pull/300","item":"301","merge_sha":"abc123"}'
assert_eq "merge-observed carries repo and the sweep's own stage naming" \
  '{"repo":"acme/widgets","stage":"sweep-closed-issues","pr_number":300,"pr_url":"https://github.com/acme/widgets/pull/300","item":"301","merge_sha":"abc123"}' \
  "$(event_of merge-observed)"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
