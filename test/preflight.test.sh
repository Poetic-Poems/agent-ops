#!/usr/bin/env bash
#
# test/preflight.test.sh — regression test for lib/preflight.sh (issue #245):
# the done-check the Script runs on the item a cycle just claimed, before it
# pays for an Implementer engagement.
#
# `preflight_done_reason` is a thin wrapper: `work_gone_clearances`
# (test/work-gone.test.sh already covers that function's own decisions in
# depth) around a one-entry blocked list. `preflight_defer_reason` is the
# stale-open-PR check for an ordinary issues/tech-debt item — a defer signal,
# never a void-feeding one (#279), which is why it must stay out of
# `preflight_done_reason`'s answer. `preflight_branch_merged_reason` is the
# other, impure, done-signal — one live `gh api compare` call, stubbed below —
# and `preflight_existing_branch_source` is the gate that gh call is never
# reached without.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/preflight.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/lib/work-gone.sh"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"

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

states='[{"slug":"o/a","ok":true,
          "issues":[{"n":9},{"n":130}],
          "open_prs":[{"n":9,"h":"agent/9-stale"}]}]'

assert_eq "a closed issue is already done" \
  "issue #125 is closed" \
  "$(preflight_done_reason o/a 125 agent/125 "$states")"
assert_eq "an open issue is not" \
  "" "$(preflight_done_reason o/a 130 agent/130 "$states")"

assert_eq "a finishing source's already-merged-or-closed PR is already done" \
  "pull request #146 is closed or merged" \
  "$(preflight_done_reason o/a pr-146-review-3312 agent/245 "$states")"
assert_eq "one still open is not" \
  "" "$(preflight_done_reason o/a pr-9-abandoned-abc123abc123 agent/245 "$states")"

register='{"o/a":{"TD26072401":"resolved","TD-PPpoet-26072605":"open"}}'
assert_eq "a tech-debt item the register already resolved is already done" \
  "the tech-debt register records it resolved" \
  "$(preflight_done_reason o/a TD26072401 td/TD26072401 "$states" "$register")"
assert_eq "one still open is not" \
  "" "$(preflight_done_reason o/a TD-PPpoet-26072605 td/TD-PPpoet-26072605 "$states" "$register")"
assert_eq "and neither is a tech-debt item pre-flight never fetched a register row for" \
  "" "$(preflight_done_reason o/a TD26072401 td/TD26072401 "$states")"

assert_eq "a repo pre-flight has no digest for decides nothing" \
  "" "$(preflight_done_reason o/z 125 agent/125 "$states")"
assert_eq "a repo whose digest could not be sampled decides nothing" \
  "" "$(preflight_done_reason o/a 125 agent/125 '[{"slug":"o/a","ok":false}]')"

# --- Stale open PR on an ordinary item's own branch (issue #245, #279) -----------
# A defer signal, not a done one: the fact can become false again (the PR may
# close unmerged), so it must never reach `log_item_void` through
# `preflight_done_reason` — a void is terminal and only a human clears one.
assert_eq "the stale-open-PR fact never feeds the void-producing answer" \
  "" "$(preflight_done_reason o/a 9 agent/9-stale "$states")"
assert_eq "an ordinary item whose own branch already has an open PR defers" \
  "an open pull request already carries branch agent/9-stale" \
  "$(preflight_defer_reason o/a 9 agent/9-stale "$states")"
assert_eq "an ordinary item whose branch has no open PR defers nothing" \
  "" "$(preflight_defer_reason o/a 130 agent/130 "$states")"
assert_eq "a finishing source's own PR-shaped item never asks the stale-PR question" \
  "" "$(preflight_defer_reason o/a pr-9-abandoned-xyz agent/9-stale "$states")"
assert_eq "a repo the digest never sampled defers nothing" \
  "" "$(preflight_defer_reason o/z 9 agent/9-stale "$states")"

# --- preflight_existing_branch_source (issue #245) --------------------------------
assert_eq "review-feedback's branch predates the claim" "0" \
  "$(preflight_existing_branch_source review-feedback; echo $?)"
assert_eq "merge-conflicts' branch predates the claim" "0" \
  "$(preflight_existing_branch_source merge-conflicts; echo $?)"
assert_eq "abandoned-drafts' branch predates the claim" "0" \
  "$(preflight_existing_branch_source abandoned-drafts; echo $?)"
assert_eq "an ordinary tech-debt claim's branch does not" "1" \
  "$(preflight_existing_branch_source tech-debt; echo $?)"
assert_eq "an ordinary issues claim's branch does not" "1" \
  "$(preflight_existing_branch_source issues; echo $?)"
assert_eq "a source name that merely contains one as a substring is not matched" "1" \
  "$(preflight_existing_branch_source conflicts; echo $?)"

# --- preflight_branch_merged_reason (issue #245) -----------------------------------
# `gh` is a stub on PATH via PREFLIGHT_GH; no network. It only ever answers
# `api repos/<slug>/compare/<base>...<branch> --jq .status`, returning
# PREFLIGHT_STUB_STATUS (or failing outright when PREFLIGHT_STUB_FAIL=1).
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${PREFLIGHT_STUB_FAIL:-0}" == "1" ]] && exit 1
printf '%s\n' "${PREFLIGHT_STUB_STATUS:-diverged}"
STUB
chmod +x "$stub_dir/gh"

assert_eq "identical reads as already merged" \
  "the branch is already merged into main" \
  "$(PREFLIGHT_GH="$stub_dir/gh" PREFLIGHT_STUB_STATUS=identical \
     preflight_branch_merged_reason o/a main agent/245)"
assert_eq "behind reads as already merged" \
  "the branch is already merged into main" \
  "$(PREFLIGHT_GH="$stub_dir/gh" PREFLIGHT_STUB_STATUS=behind \
     preflight_branch_merged_reason o/a main agent/245)"
assert_eq "diverged is still live work" \
  "" "$(PREFLIGHT_GH="$stub_dir/gh" PREFLIGHT_STUB_STATUS=diverged \
        preflight_branch_merged_reason o/a main agent/245)"
assert_eq "ahead is still live work" \
  "" "$(PREFLIGHT_GH="$stub_dir/gh" PREFLIGHT_STUB_STATUS=ahead \
        preflight_branch_merged_reason o/a main agent/245)"
assert_eq "an unreadable comparison decides nothing" \
  "" "$(PREFLIGHT_GH="$stub_dir/gh" PREFLIGHT_STUB_FAIL=1 \
        preflight_branch_merged_reason o/a main agent/245)"
assert_eq "missing arguments decide nothing" \
  "" "$(PREFLIGHT_GH="$stub_dir/gh" preflight_branch_merged_reason "" main agent/245)"

# ---------------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
