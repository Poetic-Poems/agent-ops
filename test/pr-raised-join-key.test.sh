#!/usr/bin/env bash
# shellcheck disable=SC2034
# impl_pr_url/repo_slug/selected_item are read only by the extracted block
# below, `eval`-defined rather than sourced, so shellcheck cannot see the
# use — the same false positive lib/merge-observed.sh's own header disables
# for the same reason.
#
# test/pr-raised-join-key.test.sh — regression test for the item-lifecycle
# join key (requirement 49, issue #595) on `pr-raised` (agent-cycle.sh):
# carries `item` alongside its existing `repo` whenever the cycle's own
# `$selected_item` is non-empty, and omits it — never a literal `null` —
# otherwise.
#
# Lifted verbatim, the same technique test/landing-wiring.test.sh and its
# siblings use, so the assertions are about the shipped code rather than a
# copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/pr-raised-join-key.test.sh
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

block="$(awk '
  /^if \[\[ -n "\$impl_pr_url" \]\]; then$/ { on = 1 }
  on { print }
  on && /pr_url: \$u, repo: \$r\} \+ \(if \$i == "" then \{\} else \{item: \$i\} end\)\047\)"$/ { exit }
' "$CYCLE")"
if [[ -z "$block" || "$block" != *"pr-raised"* ]]; then
  echo "FAIL - could not extract the pr-raised block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi
# Close the `if` the awk range's own end line leaves dangling, plus a
# trailing `fi` for the `if [[ -n "$impl_pr_url" ]]` it opens, so the
# extracted text is a complete, evaluable statement on its own.
block="$block"$'\nfi'

events_file="$(mktemp)"
trap 'rm -f "$events_file"' EXIT
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$events_file"; }
event_of() { grep -m1 "^$1"$'\t' "$events_file" | cut -f2- || true; }

run_it() {  # <impl_pr_url> <repo_slug> <selected_item>
  : > "$events_file"
  ( impl_pr_url="$1" repo_slug="$2" selected_item="$3"
    eval "$block" )
}

run_it "https://github.com/acme/widgets/pull/1" "acme/widgets" "42"
assert_eq "a raised PR with a known item carries repo and item" \
  '{"pr_url":"https://github.com/acme/widgets/pull/1","repo":"acme/widgets","item":"42"}' \
  "$(event_of pr-raised)"

run_it "https://github.com/acme/widgets/pull/2" "acme/widgets" ""
assert_eq "an empty item is omitted entirely, never logged null" \
  "false" "$(jq -c 'has("item")' <<<"$(event_of pr-raised)")"
assert_eq "  ... while repo is still present" \
  '"acme/widgets"' "$(jq -c '.repo' <<<"$(event_of pr-raised)")"

run_it "" "acme/widgets" "42"
assert_eq "no PR raised at all logs nothing" "" "$(event_of pr-raised)"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
