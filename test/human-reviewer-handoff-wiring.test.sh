#!/usr/bin/env bash
#
# test/human-reviewer-handoff-wiring.test.sh — regression test for the two
# blocks in agent-cycle.sh that read `ensure_human_reviewer`'s (lib/handoff.sh)
# return value at requirement 38's handoff: the Reviewer's own handoff, and
# the Enabler's `complete_handoff` recovery path.
#
# `test/handoff.test.sh` covers `ensure_human_reviewer` itself, including its
# two `failed` shapes — a bare `failed` for a read it could not make, and
# `failed<TAB><logins>` for the case a request was posted and GitHub still
# does not show it pending. Neither call site had its own coverage
# (tech-debt/TD-PPagop-26081402.md): both matched the raw return value
# against the literal string `failed`, which only ever equals the bare shape,
# so the `failed<TAB><logins>` case — the one the warning most concerns, since
# it means a request really was attempted at the moment of handoff and did not
# take — produced no warning at all, and leaked `failed\t<logins>` into the
# `pr-ready` event's `human_review_requested` field instead of the state
# alone. This file asserts, for both call sites:
#
#   - **Either `failed` shape produces the warning** — bare and `failed<TAB>
#     <logins>` alike — naming the pull request and, when GitHub says who was
#     actually attempted, those logins rather than always falling back to
#     `enabler_assignee`.
#   - **`pr-ready` carries the bare state**, never `state<TAB>logins`, in
#     `human_review_requested`.
#   - **A `skip` (bare, or `skip<TAB>no-candidate`) omits `human_review_
#     requested` from `pr-ready` entirely** — the case the `startswith("skip")`
#     comparison this file replaces was working around; splitting the tab off
#     at the source lets the `jq` compare against the plain string again.
#   - **A live `requested` reaches `pr-ready` untouched**, so the fix does not
#     regress the ordinary path.
#
# Both blocks are lifted verbatim out of agent-cycle.sh, the same way
# test/human-visibility-wiring.test.sh and test/closing-keyword-wiring.test.sh
# lift theirs, so the assertions are about the shipped code rather than a copy
# of its logic. Their callees are stubbed: `confirm_review_requested`,
# `ensure_human_reviewer` and `log_event`.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/human-reviewer-handoff-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.
#
# shellcheck disable=SC2016
# This file's whole business is assembling scripts whose `$`-expressions must
# reach the assembled file unexpanded; the single-quoted printf templates
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
# Both blocks run the same shape of read: `confirm_review_requested`, then
# (guarded on `none`) `ensure_human_reviewer`, then the `pr-ready` event. The
# end anchor is the closing line of the `pr-ready` jq common to both blocks;
# the start anchors differ only in the call sites' own variable prefixes
# (`e_` on the Enabler's recovery path).

reviewer_block="$(awk '
  /^  rereview_result="\$\(confirm_review_requested/ { on = 1 }
  on { print }
  on && /human_review_requested: \$hr, human_reviewer: \$ha} end\)'"'"'\)"$/ { exit }
' "$CYCLE")"

enabler_block="$(awk '
  /^ *e_rereview="\$\(confirm_review_requested/ { on = 1 }
  on { print }
  on && /human_review_requested: \$hr, human_reviewer: \$ha} end\)'"'"'\)"$/ { exit }
' "$CYCLE")"

for pair in "reviewer:$reviewer_block" "enabler:$enabler_block"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL - could not extract the ${pair%%:*} handoff block from agent-cycle.sh — has it moved?" >&2
    exit 1
  fi
done

# --- Assembly -------------------------------------------------------------
# run_block BLOCK PR_URL_VAR PR_URL_VAL HANDOFF_VAR HANDOFF_VAL ASSIGNEE \
#           CONFIRM_RESULT ENSURE_RESULT
# Runs BLOCK under the same `set -euo pipefail` agent-cycle.sh runs under,
# with `confirm_review_requested` and `ensure_human_reviewer` stubbed to
# print CONFIRM_RESULT / ENSURE_RESULT verbatim (a literal `none`, `failed`,
# `failed<TAB>logins`, `skip`, `skip<TAB>no-candidate` or `requested<TAB>
# logins`) and `log_event` recording every call as `<kind><TAB><json>`.
# Prints the recorded events, one per line.
run_block() {
  local block="$1" pr_url_var="$2" pr_url_val="$3" handoff_var="$4" handoff_val="$5" \
        assignee="$6" confirm_result="$7" ensure_result="$8" \
        harness="$tmp_dir/harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf '%s=%q\n' "$pr_url_var" "$pr_url_val"
    printf '%s=%q\n' "$handoff_var" "$handoff_val"
    printf 'enabler_assignee=%q\n' "$assignee"
    printf 'confirm_review_requested() { printf %%s %q; }\n' "$confirm_result"
    printf 'ensure_human_reviewer() { printf %%s %q; }\n' "$ensure_result"
    printf '%s\n' 'log_event() { printf "%s\t%s\n" "$1" "$2" >>'"$(printf '%q' "$tmp_dir/events")"'; }'
    printf '%s\n' "$block"
  } > "$harness"
  : > "$tmp_dir/events"
  bash "$harness" 2>"$tmp_dir/stderr"
  cat "$tmp_dir/events" 2>/dev/null || true
}

pr_ready_json() { grep -m1 $'^pr-ready\t' <<<"$1" | cut -f2-; }
warning_jsons() { grep $'^warning\t' <<<"$1" | cut -f2-; }

URL="https://github.com/Poetic-Poems/agent-ops/pull/368"
ASSIGNEE="warwickallen"

# run_case DESC PR_URL_VAR HANDOFF_VAR HANDOFF_VAL BLOCK ENSURE_RESULT
# Runs one block for both the "did-not-take" and "read failed" shapes plus
# `skip` and `requested`, asserting the same invariants each time. DESC names
# which call site (used in assertion labels only).
run_case() {
  local desc="$1" pr_url_var="$2" handoff_var="$3" handoff_val="$4" block="$5"

  # --- failed<TAB><logins>: the request was attempted and did not take -----
  local out warn ready
  out="$(run_block "$block" "$pr_url_var" "$URL" "$handoff_var" "$handoff_val" \
          "$ASSIGNEE" "none" "$(printf 'failed\talice,eve')")"
  warn="$(warning_jsons "$out")"
  ready="$(pr_ready_json "$out")"
  assert_contains "$desc: failed<TAB>logins produces a warning" \
    "could not be requested from" "$warn"
  assert_contains "  ... naming the logins GitHub actually tried, not the fallback assignee" \
    "could not be requested from alice,eve" "$warn"
  assert_eq "  ... and reviewers name exactly those logins" \
    '["alice","eve"]' "$(jq -c '.reviewers' <<<"$warn")"
  assert_eq "  ... pr-ready carries the bare state, not state+logins" \
    '"failed"' "$(jq -c '.human_review_requested' <<<"$ready")"

  # --- bare failed: the read itself could not be made -----------------------
  out="$(run_block "$block" "$pr_url_var" "$URL" "$handoff_var" "$handoff_val" \
          "$ASSIGNEE" "none" "failed")"
  warn="$(warning_jsons "$out")"
  ready="$(pr_ready_json "$out")"
  assert_contains "$desc: bare failed still produces a warning" \
    "could not be requested from $ASSIGNEE" "$warn"
  assert_eq "  ... reviewers fall back to enabler_assignee when GitHub named nobody" \
    "[\"$ASSIGNEE\"]" "$(jq -c '.reviewers' <<<"$warn")"
  assert_eq "  ... pr-ready still carries the bare state" \
    '"failed"' "$(jq -c '.human_review_requested' <<<"$ready")"

  # --- skip<TAB>no-candidate: never warned as a failed request ---------------
  out="$(run_block "$block" "$pr_url_var" "$URL" "$handoff_var" "$handoff_val" \
          "$ASSIGNEE" "none" "$(printf 'skip\tno-candidate')")"
  warn="$(warning_jsons "$out")"
  ready="$(pr_ready_json "$out")"
  assert_lacks "$desc: skip<TAB>no-candidate is not reported as a failed request" \
    "could not be requested from" "$warn"
  assert_eq "  ... and pr-ready omits human_review_requested entirely" \
    "null" "$(jq -c '.human_review_requested // null' <<<"$ready")"

  # --- bare skip: the same omission, without startswith("skip") to lean on --
  out="$(run_block "$block" "$pr_url_var" "$URL" "$handoff_var" "$handoff_val" \
          "$ASSIGNEE" "none" "skip")"
  ready="$(pr_ready_json "$out")"
  assert_eq "$desc: bare skip also omits human_review_requested" \
    "null" "$(jq -c '.human_review_requested // null' <<<"$ready")"

  # --- requested<TAB>logins: the ordinary path is unaffected ----------------
  out="$(run_block "$block" "$pr_url_var" "$URL" "$handoff_var" "$handoff_val" \
          "$ASSIGNEE" "none" "$(printf 'requested\tcarol')")"
  warn="$(warning_jsons "$out")"
  ready="$(pr_ready_json "$out")"
  assert_lacks "$desc: a live request logs no warning" \
    "could not be requested from" "$warn"
  assert_eq "  ... and pr-ready carries the requested state" \
    '"requested"' "$(jq -c '.human_review_requested' <<<"$ready")"
}

run_case "reviewer's own handoff" impl_pr_url handoff_by "reviewer" "$reviewer_block"
run_case "enabler's complete_handoff" e_pr_url e_handoff "already" "$enabler_block"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
