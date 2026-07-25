#!/usr/bin/env bash
#
# test/handoff.test.sh — regression test for lib/handoff.sh (requirement 31a).
#
# The defect: a Reviewer answered `{"status": "ready", "ci": "passing"}` for a
# pull request whose work was complete and whose checks were green, never ran
# `gh pr ready`, and the Script logged `pr-ready` from the report alone. The PR
# stayed a draft — invisible to the human, who watches for review requests —
# while the log recorded a successful handoff. Three hours on, the
# abandoned-drafts source re-detected it as a stalled draft at a fresh head SHA,
# which is a fresh ref no block covers, and paid an Implementor and a Reviewer to
# finish finished work. On the hour, indefinitely, every cycle looking productive.
#
# So the assertions below are all one assertion in different clothes: the word
# this function prints must come from GitHub's answer, never from the caller's
# hope. In particular an API that will not answer must read as `failed` — the
# one direction where a wrong guess is silent.
#
# `gh` is stubbed through HANDOFF_GH, the same way lib/claim.sh's tests stub
# theirs; the stub keeps the draft flag in a file so a flip is observable.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/handoff.test.sh
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
# State lives in files so the test can set it up and read it back:
#   $tmp_dir/draft       "true" | "false" | "error" — what `pr view` reports
#   $tmp_dir/flip        "works" | "silent" — whether `pr ready` changes anything
#   $tmp_dir/ready-calls incremented on every `gh pr ready`
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
case "$1 $2" in
  "pr view")
    flag="$(cat "$d/draft")"
    [[ "$flag" == "error" ]] && exit 1
    printf '%s' "$flag"
    ;;
  "pr ready")
    printf 'x' >>"$d/ready-calls"
    [[ "$(cat "$d/flip")" == "works" ]] && printf 'false' >"$d/draft"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/gh"
export HANDOFF_GH="$tmp_dir/gh"

reset_stub() {  # <draft-flag> <flip-behaviour>
  printf '%s' "$1" >"$tmp_dir/draft"
  printf '%s' "$2" >"$tmp_dir/flip"
  : >"$tmp_dir/ready-calls"
}

ready_calls() { wc -c <"$tmp_dir/ready-calls" | tr -d ' '; }

URL="https://github.com/Poetic-Poems/poetic-fiddle/pull/111"

# --- The ordinary path: the Reviewer did its job ------------------------------
# Costs one read and nothing else; in particular it must not "helpfully" run
# `gh pr ready` on a PR that already left draft, which prints an error and
# would make every clean handoff look like a repair.
reset_stub false works
out="$(confirm_pr_ready "$URL")"; rc=$?
assert_eq "a non-draft PR reports already" "already" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... without calling gh pr ready" "0" "$(ready_calls)"

# --- The defect: reported ready, still a draft ---------------------------------
# The Reviewer's judgement stands — it read the diff — so the Script completes
# the mechanism rather than failing a PR that has been certified.
reset_stub true works
out="$(confirm_pr_ready "$URL")"; rc=$?
assert_eq "a draft PR is flipped, not accepted" "flipped" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... having called gh pr ready once" "1" "$(ready_calls)"
assert_eq "  ... and GitHub now says it is not a draft" "false" "$(cat "$tmp_dir/draft")"

# --- The flip that does not take ----------------------------------------------
# `gh pr ready` can exit 0 and change nothing. The re-read, not the exit status,
# is the answer — this is the assertion that stops the same bug reappearing one
# layer down.
reset_stub true silent
out="$(confirm_pr_ready "$URL")"; rc=$?
assert_eq "a flip that changes nothing is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... still a draft" "true" "$(cat "$tmp_dir/draft")"

# --- The unreadable PR ---------------------------------------------------------
# The silent direction. "Could not ask" must never resolve to "not a draft":
# that is the original defect with an API outage standing in for the Reviewer.
reset_stub error works
out="$(confirm_pr_ready "$URL")"; rc=$?
assert_eq "an unreadable PR is a failure, never an assumed handoff" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... without attempting a flip it cannot verify" "0" "$(ready_calls)"

# --- A PR that vanishes mid-flip ------------------------------------------------
# First read says draft, the flip runs, the confirming read fails. Nothing is
# known, so nothing is claimed.
printf 'true' >"$tmp_dir/draft"; printf 'silent' >"$tmp_dir/flip"; : >"$tmp_dir/ready-calls"
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
case "$1 $2" in
  "pr view")
    n="$(cat "$d/views" 2>/dev/null || echo 0)"; printf '%s' "$(( n + 1 ))" >"$d/views"
    (( n == 0 )) || exit 1
    printf 'true'
    ;;
  "pr ready") printf 'x' >>"$d/ready-calls" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/gh"
printf '0' >"$tmp_dir/views"
out="$(confirm_pr_ready "$URL")"; rc=$?
assert_eq "a confirming read that fails is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

# --- No URL at all --------------------------------------------------------------
# Reachable: the Implementor can complete without the Script ever recovering a
# PR URL. An empty string must not become `gh pr view ""`.
out="$(confirm_pr_ready "")"; rc=$?
assert_eq "an empty PR url is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

# --- Survives the caller's shell options ----------------------------------------
# agent-cycle.sh runs under `set -euo pipefail`, and the call site is
# `x="$(confirm_pr_ready …)" || true`. A non-zero return that escapes would abort
# the cycle at exactly the point it is trying to report a problem.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/handoff.sh"
  HANDOFF_GH="/nonexistent/gh"
  x="$(confirm_pr_ready "$URL")" || true
  [[ "$x" == "failed" ]] || exit 9
  exit 0
) >/dev/null 2>&1
assert_eq "the real call-site shape survives set -e" "0" "$?"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
