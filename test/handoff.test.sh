#!/usr/bin/env bash
#
# test/handoff.test.sh — regression test for lib/handoff.sh (requirements 31a
# and 9).
#
# Two functions, two halves of one promise: that a pull request this pipeline
# opened reaches a human. `confirm_pr_ready` covers the half where the PR is
# known and the handoff was claimed but not performed; `pr_url_for_branch`
# covers the half below it, where the stage died without ever saying which pull
# request it had opened — at which point nothing above can run at all.
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
  # shellcheck disable=SC2030  # Not leaking is the point: the stub outside this
  # subshell must go on answering for the assertions that follow it.
  HANDOFF_GH="/nonexistent/gh"
  x="$(confirm_pr_ready "$URL")" || true
  [[ "$x" == "failed" ]] || exit 9
  exit 0
) >/dev/null 2>&1
assert_eq "the real call-site shape survives set -e" "0" "$?"

# --- pr_url_for_branch: naming the PR a failed stage never named (req. 9) -------
# The other end of the same story. `confirm_pr_ready` above cannot run at all on
# a pull request nobody can name, and on 2026-08-03 three finished items were
# blocked for exactly that reason: the Implementor exited 0 with prose instead
# of a JSON object, so no `pr_url` was reported, none was printable from the
# stage output, and no `.git/agent-ops-pr-url` breadcrumb had been written —
# every fallback that depends on the stage failed together with the stage. The
# claimed branch does not depend on it: the Script computed and pushed it before
# the stage began, which is what makes it the fallback worth having.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
[[ -f "$d/api-down" ]] && exit 1
printf '%s\n' "$*" >>"$d/list-calls"
branch=""
while (( $# )); do
  [[ "$1" == "--head" ]] && { branch="${2:-}"; shift; }
  shift
done
case "$branch" in
  agent/172) printf '  https://github.com/Poetic-Poems/agent-ops/pull/180  \n' ;;
  *)         printf '' ;;
esac
STUB
chmod +x "$tmp_dir/gh"
rm -f "$tmp_dir/api-down"; : >"$tmp_dir/list-calls"
list_calls() { wc -l <"$tmp_dir/list-calls" | tr -d ' '; }

# Trimmed like the breadcrumb's own reader is, because this URL is pasted into
# a `gh pr comment` target and a log field, and stray whitespace breaks both.
assert_eq "an open PR on the claimed branch is found by the branch alone" \
  "https://github.com/Poetic-Poems/agent-ops/pull/180" \
  "$(pr_url_for_branch Poetic-Poems/agent-ops agent/172)"

assert_eq "a branch with no open PR yields nothing" "" \
  "$(pr_url_for_branch Poetic-Poems/agent-ops agent/999)"

# The silent direction, and the reason this returns 0 whatever happens: every
# call site is on a failure path already in progress under `errexit`, so a
# non-zero here kills the cycle before it logs the failure it is describing.
printf 'x' >"$tmp_dir/api-down"
out="$(pr_url_for_branch Poetic-Poems/agent-ops agent/172)"; rc=$?
assert_eq "an unreachable API yields nothing" "" "$out"
assert_eq "  ... and still exits 0" "0" "$rc"
rm -f "$tmp_dir/api-down"

# Neither is knowable before the claim loop has run — a Co-Ordinator that failed
# to select pins no repo and no branch — and `gh pr list -R ''` is a usage
# error, not a lookup that comes up empty.
: >"$tmp_dir/list-calls"
assert_eq "no repo asks GitHub nothing" "" "$(pr_url_for_branch "" agent/172)"
assert_eq "no branch asks GitHub nothing" "" "$(pr_url_for_branch Poetic-Poems/agent-ops "")"
assert_eq "  ... and neither reached the API" "0" "$(list_calls)"

# The call-site shape as agent-cycle.sh writes it: a bare
# `[[ -z "$url" ]] && url="$(pr_url_for_branch …)"`, the same shape
# `read_pr_url_breadcrumb`'s own comment records the cost of getting wrong.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/handoff.sh"
  HANDOFF_GH="/nonexistent/gh"
  url=""
  [[ -z "$url" ]] && url="$(pr_url_for_branch o/r agent/1)"
  [[ -z "$url" ]] || exit 9
  exit 0
) >/dev/null 2>&1
assert_eq "pr_url_for_branch's call-site shape survives set -e" "0" "$?"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
