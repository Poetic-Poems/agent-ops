#!/usr/bin/env bash
#
# test/closing-keyword-wiring.test.sh — regression test for the two blocks in
# agent-cycle.sh that decide what requirement 25a's script-side gate
# (lib/closing-keyword-gate.sh) actually *does* with its verdict at the
# Implementor→Reviewer handoff.
#
# test/closing-keyword-gate.test.sh covers the gate's own verdict, and
# test/check-closing-keyword.test.sh the rule underneath it. Both pass with the
# consequence wired either way round, and the consequence is the whole
# question this file exists for:
#
#   - **A `dirty` verdict here is feedback, not a refusal.** What the gate
#     finds is a pull-request *body* edit, the class of defect the Reviewer's
#     own step 4 fixes and pushes in the same cycle. Refusing the handoff
#     would record the item `attempt-failed` and block it pending an Enabler
#     engagement — a self-healing case turned into a stuck one — and buy no
#     safety, since the same gate is asked again at the Reviewer's `ready`
#     handoff, which is the only way a pull request reaches a human or a
#     merge. So the block must set the finding and *carry on*; the shipped
#     first cut of this gate exited here instead.
#   - **The finding has to actually reach the Reviewer.** It cannot see the
#     later gate's verdict from inside its own session, so a finding recorded
#     in the log and left out of the prompt is a review that hands off and is
#     handed back — the review spent and the item lost anyway. The prompt
#     section is therefore asserted, in both directions: present and naming
#     the fault when there is one, and wholly absent (not an empty heading)
#     when there is not.
#   - **`unknown` is neither.** A `gh` that could not answer says something
#     about this node, not this pull request; it warns, and nothing is handed
#     to the Reviewer to "fix".
#
# Both blocks are lifted verbatim out of agent-cycle.sh, the same way
# test/human-visibility-wiring.test.sh lifts its block, so the assertions are
# about the shipped code rather than a copy of its logic. Their callees are
# stubbed: `closing_keyword_gate` (covered by its own test), `log_event`,
# `release_claim` and `stage_prompt_text`.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/closing-keyword-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

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

assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                 %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- Extraction ---------------------------------------------------------------
# Block 1: the `closing_keyword_finding` initialiser through the `fi` closing
# the `if [[ -n "$impl_pr_url" ]]` the gate call sits in.
gate_block="$(awk '
  /^closing_keyword_finding=""$/ { on = 1 }
  on                             { print }
  on && /^fi$/                   { exit }
' "$CYCLE")"

# Block 2: the `## Script findings` section builder and the reviewer prompt
# assembly it feeds, up to (not including) the line after it.
prompt_block="$(awk '
  /^script_findings_section=""$/ { on = 1 }
  on && /^rev_out=/              { exit }
  on                             { print }
' "$CYCLE")"

for pair in "gate:$gate_block" "prompt:$prompt_block"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL - could not extract the ${pair%%:*} block from agent-cycle.sh — has it moved?" >&2
    exit 1
  fi
done

# --- Block 1: what the verdict costs ------------------------------------------
# run_gate_block VERDICT
# Runs the block with `closing_keyword_gate` stubbed to VERDICT (a literal
# `clean` / `dirty<TAB>reason` / `unknown<TAB>reason`), under the same
# `set -euo pipefail` agent-cycle.sh runs under. Prints the resulting
# `closing_keyword_finding`, a `--` line, then every `log_event` call as
# `<kind><TAB><detail>`. A block that exits early — the behaviour this file
# exists to catch — prints no `--` at all, so `reached_end` can assert it.
# shellcheck disable=SC2016  # The harness's own `$1`/`$2`/`$closing_keyword_finding`, written out literally for it to expand, not this shell's.
run_gate_block() {
  local verdict="$1" harness="$tmp_dir/gate-harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'impl_pr_url=%q\n' "https://github.com/Poetic-Poems/poetic-fiddle/pull/198"
    printf 'repo_slug=%q\n' "Poetic-Poems/poetic-fiddle"
    printf '%s\n' 'log_event() { printf "%s\t%s\n" "$1" "$(jq -r ".detail // \"\"" <<<"$2")" >>'"$(printf '%q' "$tmp_dir/events")"'; }'
    printf '%s\n' 'release_claim() { :; }'
    printf 'closing_keyword_gate() { printf %%s %q; [[ %q == dirty* ]] && return 1; return 0; }\n' \
      "$verdict" "$verdict"
    printf '%s\n' "$gate_block"
    printf '%s\n' 'printf "%s\n" "$closing_keyword_finding"'
    printf '%s\n' 'printf -- "--\n"'
  } > "$harness"
  : > "$tmp_dir/events"
  bash "$harness" 2>/dev/null
  printf '%s' "$(cat "$tmp_dir/events" 2>/dev/null || true)"
}

reached_end() { [[ "$1" == *$'--\n'* || "$1" == *$'--' ]] && echo yes || echo no; }

DIRTY_REASON='PR body names issue #198 (agent-ops:closes-issue marker) but has no closing keyword (Closes/Fixes/Resolves #198) for it'

out="$(run_gate_block "dirty	$DIRTY_REASON")"
assert_eq "a dirty verdict does not end the cycle — the Reviewer still runs" \
  "yes" "$(reached_end "$out")"
assert_eq "  ... and the fault is held for the Reviewer, reason intact" \
  "$DIRTY_REASON" "$(head -n1 <<<"$out")"
assert_contains "  ... with a warning logged naming the pull request" \
  "pull/198 fails the closing-keyword check" "$out"
# The regression: recording the item `attempt-failed` here is what turned a
# one-line body edit into an item blocked pending an Enabler engagement.
assert_lacks "  ... and nothing recorded against the item as a failed attempt" \
  "attempt-failed" "$out"

out="$(run_gate_block "unknown	could not read https://github.com/o/r/pull/1's body and head branch")"
assert_eq "an unknown verdict does not end the cycle either" \
  "yes" "$(reached_end "$out")"
assert_eq "  ... and hands the Reviewer nothing to fix" "" "$(head -n1 <<<"$out")"
assert_contains "  ... but warns that the check could not be made" \
  "could not check whether" "$out"

out="$(run_gate_block "clean")"
assert_eq "a clean verdict hands the Reviewer nothing" "" "$(head -n1 <<<"$out")"
assert_lacks "  ... and logs no warning" "warning" "$out"

# --- Block 2: the finding reaches the Reviewer's prompt -----------------------
# run_prompt_block FINDING — prints the assembled reviewer prompt.
# shellcheck disable=SC2016  # The harness's own `$reviewer_prompt`, written out literally for it to expand, not this shell's.
run_prompt_block() {
  local finding="$1" harness="$tmp_dir/prompt-harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'closing_keyword_finding=%q\n' "$finding"
    printf '%s\n' 'stage_prompt_text() { printf "%s" "<<reviewer prompt>>"; }'
    printf '%s\n' 'PROMPTS_DIR=""; state_dir=""; prompt_overrides_json="{}"'
    printf '%s\n' 'work_order_json='"'"'{"item":"198"}'"'"'; impl_status_json='"'"'{"status":"complete"}'"'"''
    printf '%s\n' 'cycle_id="20260813T045756Z-ockham-2-5031"; node_name="ockham-2"'
    printf '%s\n' "$prompt_block"
    printf '%s\n' 'printf "%s" "$reviewer_prompt"'
  } > "$harness"
  bash "$harness" 2>/dev/null
}

with="$(run_prompt_block "$DIRTY_REASON")"
assert_contains "a held finding reaches the Reviewer as a Script findings section" \
  $'\n## Script findings\n' "$with"
assert_contains "  ... naming the requirement it came from" \
  "Closing keyword (requirement 25a)" "$with"
assert_contains "  ... and the fault itself, verbatim" "$DIRTY_REASON" "$with"
assert_contains "  ... ahead of the Cycle section, not appended past it" \
  $'## Script findings' "$(sed -n '1,/^## Cycle$/p' <<<"$with")"

without="$(run_prompt_block "")"
assert_lacks "no finding leaves no heading at all — not an empty one" \
  "Script findings" "$without"
# An always-present section variable that merely expands to nothing would
# still shift the spacing every prompt around it; the Reviewer's prompt is
# unchanged when the gate found nothing.
assert_contains "  ... and the sections either side keep their usual spacing" \
  $'```\n\n## Cycle\n' "$without"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
