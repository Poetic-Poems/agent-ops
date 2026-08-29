#!/usr/bin/env bash
#
# test/pr-merge-state.test.sh — regression test for `pr_merge_state`
# (lib/handoff.sh, requirement 31d, agent-ops#916).
#
# The defect this exists to prevent: a subject pull request merging mid-stage
# went unnoticed because nothing on the handoff path ever asked GitHub whether
# it was still open. `pr_merge_state` is the one read both call sites in
# agent-cycle.sh now share, and it must be fail-closed the same way
# `confirm_pr_ready` already is: "could not tell whether this merged" must
# never read as "open", because a caller that treated an unreadable pull
# request as still open would run the very handoff a genuine merge
# invalidates.
#
# `gh` is stubbed through HANDOFF_GH, the same convention test/handoff.test.sh
# already uses for `confirm_pr_ready`.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/pr-merge-state.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"

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

# --- The stub -----------------------------------------------------------------
# $tmp_dir/reply holds whatever `gh pr view --json state,mergedAt,mergeCommit`
# should print (raw JSON), or the literal string "error" to make the call fail.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
case "$1 $2" in
  "pr view")
    reply="$(cat "$d/reply")"
    [[ "$reply" == "error" ]] && exit 1
    printf '%s' "$reply"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/gh"
export HANDOFF_GH="$tmp_dir/gh"

set_reply() { printf '%s' "$1" >"$tmp_dir/reply"; }

URL="https://github.com/Poetic-Poems/agent-ops/pull/916"

# --- Merged, with a merge commit ----------------------------------------------
set_reply '{"state":"MERGED","mergedAt":"2026-08-28T02:38:28Z","mergeCommit":{"oid":"b48eebf1234"}}'
out="$(pr_merge_state "$URL")"; rc=$?
assert_eq "a MERGED reply reports merged" "merged" "$(cut -f1 <<<"$out")"
assert_eq "  ... carrying the merge commit's oid" "b48eebf1234" "$(cut -f2 <<<"$out")"
assert_eq "  ... and exits 0" "0" "$rc"

# --- Merged, with no merge commit reported ------------------------------------
set_reply '{"state":"MERGED","mergedAt":"2026-08-28T02:38:28Z","mergeCommit":null}'
out="$(pr_merge_state "$URL")"; rc=$?
assert_eq "a MERGED reply with no mergeCommit still reports merged" "merged" "$(cut -f1 <<<"$out")"
assert_eq "  ... with an empty second field" "" "$(cut -f2 <<<"$out")"
assert_eq "  ... and exits 0" "0" "$rc"

# --- Still open ----------------------------------------------------------------
set_reply '{"state":"OPEN","mergedAt":null,"mergeCommit":null}'
out="$(pr_merge_state "$URL")"; rc=$?
assert_eq "an OPEN reply reports open" "open" "$(cut -f1 <<<"$out")"
assert_eq "  ... and exits 0" "0" "$rc"

# --- Closed without merging (a different, unrelated defect) -------------------
set_reply '{"state":"CLOSED","mergedAt":null,"mergeCommit":null}'
out="$(pr_merge_state "$URL")"; rc=$?
assert_eq "a CLOSED-unmerged reply reports open (not merged)" "open" "$(cut -f1 <<<"$out")"
assert_eq "  ... and exits 0" "0" "$rc"

# --- Unreachable API: fail-closed, never "open" -------------------------------
set_reply 'error'
out="$(pr_merge_state "$URL")"; rc=$?
assert_eq "an unreachable API reports failed, never open" "failed" "$(cut -f1 <<<"$out")"
assert_eq "  ... and exits 1" "1" "$rc"

# --- A reply GitHub never actually sends: fail-closed -------------------------
set_reply '{"state":"UNKNOWABLE"}'
out="$(pr_merge_state "$URL")"; rc=$?
assert_eq "an unrecognised state reports failed, never open" "failed" "$(cut -f1 <<<"$out")"
assert_eq "  ... and exits 1" "1" "$rc"

# --- An empty PR URL: nothing to ask, fail-closed -----------------------------
out="$(pr_merge_state "")"; rc=$?
assert_eq "an empty URL reports failed without calling gh" "failed" "$(cut -f1 <<<"$out")"
assert_eq "  ... and exits 1" "1" "$rc"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
