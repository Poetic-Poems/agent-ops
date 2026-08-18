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

# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
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

# --- confirm_pr_draft (agent-ops#539): the mirror of confirm_pr_ready ---------
# `handoff_complete_review`'s last resort when the reconciliation gate
# refuses a handoff: put the pull request back in draft, not merely refuse it
# — otherwise the Reviewer's own step-7 flip survives the round it was
# refused in and becomes the very next round's reconciliation anchor
# (lib/reconciliation-gate.sh's `_reconciliation_gate_anchor`), and the
# refused pull request reads `clean` one round later with the same comment
# still unanswered (agent-ops#539). Same "confirm, don't trust" shape as
# `confirm_pr_ready`, mirrored: the `--undo` call's own exit status is not
# the answer, a re-read of the draft flag is.
#
# `confirm_pr_ready`'s own stub above, extended to answer `pr ready … --undo`
# too:
#   $tmp_dir/draft       "true" | "false" | "error" — what `pr view` reports
#   $tmp_dir/undo        "works" | "silent" — whether `pr ready --undo` changes anything
#   $tmp_dir/undo-calls  incremented on every `gh pr ready … --undo`
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
    if [[ "$*" == *"--undo"* ]]; then
      printf 'x' >>"$d/undo-calls"
      [[ "$(cat "$d/undo" 2>/dev/null)" == "works" ]] && printf 'true' >"$d/draft"
    else
      echo "stub gh: confirm_pr_draft must never call the forward flip" >&2
      exit 1
    fi
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/gh"
# HANDOFF_GH is already exported (line 82) pointing at this same path — only
# the file's own content changes here, so it does not need re-exporting.

reset_draft_stub() {  # <draft-flag> <undo-behaviour>
  printf '%s' "$1" >"$tmp_dir/draft"
  printf '%s' "$2" >"$tmp_dir/undo"
  : >"$tmp_dir/undo-calls"
}
undo_calls() { wc -c <"$tmp_dir/undo-calls" | tr -d ' '; }

# --- the ordinary repeat path: the pull request is already a draft ------------
# Reachable on the Enabler's `complete_handoff` recovery path, whose block
# never ran a flip of its own before this gate refused it — must not
# "helpfully" call `gh pr ready --undo` on a pull request that is already a
# draft, the same reason `confirm_pr_ready` must not flip an already-ready one.
reset_draft_stub true works
out="$(confirm_pr_draft "$URL")"; rc=$?
assert_eq "a draft PR reports already-draft" "already-draft" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... without calling gh pr ready --undo" "0" "$(undo_calls)"

# --- the revert itself: ready, and the gate just refused it -------------------
reset_draft_stub false works
out="$(confirm_pr_draft "$URL")"; rc=$?
assert_eq "a ready PR is reverted, not left exactly as the Reviewer's flip left it" \
  "reverted" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... having called gh pr ready --undo once" "1" "$(undo_calls)"
assert_eq "  ... and GitHub now says it is a draft" "true" "$(cat "$tmp_dir/draft")"

# --- the undo that does not take -----------------------------------------------
# `gh pr ready --undo` can exit 0 and change nothing, the same shape
# `confirm_pr_ready` guards against in the forward direction. The re-read,
# not the exit status, is the answer.
reset_draft_stub false silent
out="$(confirm_pr_draft "$URL")"; rc=$?
assert_eq "an undo that changes nothing is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... still ready" "false" "$(cat "$tmp_dir/draft")"

# --- the unreadable PR -----------------------------------------------------------
# "Could not ask" must never resolve to "reverted": a pull request this
# gate meant to pull back from a human's view must not be silently trusted
# to have been, on an API outage standing in for GitHub's own answer.
reset_draft_stub error works
out="$(confirm_pr_draft "$URL")"; rc=$?
assert_eq "an unreadable PR is a failure, never an assumed revert" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... without attempting an undo it cannot verify" "0" "$(undo_calls)"

# --- a PR that vanishes mid-undo --------------------------------------------------
# First read says ready, the undo runs, the confirming read fails. Nothing is
# known, so nothing is claimed.
printf 'false' >"$tmp_dir/draft"; printf 'silent' >"$tmp_dir/undo"; : >"$tmp_dir/undo-calls"
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
case "$1 $2" in
  "pr view")
    n="$(cat "$d/views" 2>/dev/null || echo 0)"; printf '%s' "$(( n + 1 ))" >"$d/views"
    (( n == 0 )) || exit 1
    printf 'false'
    ;;
  "pr ready") printf 'x' >>"$d/undo-calls" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/gh"
printf '0' >"$tmp_dir/views"
out="$(confirm_pr_draft "$URL")"; rc=$?
assert_eq "a confirming read that fails is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

# --- No URL at all --------------------------------------------------------------
out="$(confirm_pr_draft "")"; rc=$?
assert_eq "an empty PR url is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

# --- Survives the caller's shell options -----------------------------------------
# `handoff_complete_review`'s call site is `x="$(confirm_pr_draft …)" || true`
# under `set -euo pipefail`, the same shape `confirm_pr_ready`'s own test
# above pins.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/handoff.sh"
  # shellcheck disable=SC2030  # Not leaking is the point: the stub outside
  # this subshell must go on answering for the assertions that follow it.
  HANDOFF_GH="/nonexistent/gh"
  x="$(confirm_pr_draft "$URL")" || true
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
  # shellcheck disable=SC2030  # As above: the stub outside this subshell must
  # go on answering for the confirm_review_requested assertions that follow it.
  HANDOFF_GH="/nonexistent/gh"
  url=""
  [[ -z "$url" ]] && url="$(pr_url_for_branch o/r agent/1)"
  [[ -z "$url" ]] || exit 9
  exit 0
) >/dev/null 2>&1
assert_eq "pr_url_for_branch's call-site shape survives set -e" "0" "$?"

# --- confirm_review_requested: the round after the first (requirement 31b) ------
# `confirm_pr_ready` above answers `already` for every one of these, truthfully,
# and that is the hole: the pull request never went back to draft, so the flip
# is a no-op and nothing else puts it in front of the human. Their review
# request was consumed the moment they submitted the review that asked for the
# changes, and the author cannot clear `CHANGES_REQUESTED`. poetic-fiddle #200
# sat like that — reviewed, answered, pushed, commented — until a human went
# looking for it.
#
# The stub answers the three REST calls the function makes. State:
#   $tmp_dir/reviews   the reviews array, verbatim JSON
#   $tmp_dir/pending   the requested_reviewers logins, one per line
#   $tmp_dir/post      "works" | "silent" — whether the POST changes `pending`
#   $tmp_dir/api-fail  the path fragment whose GET should fail, if any
#   $tmp_dir/posts     one line per POST, recording its arguments
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
fail="$(cat "$d/api-fail" 2>/dev/null || true)"
if [[ "$1 $2" == "api -X" ]]; then
  printf '%s\n' "$*" >>"$d/posts"
  [[ "$(cat "$d/post")" == "works" ]] && cat "$d/blocking" >"$d/pending"
  exit 0
fi
path="$2"
[[ -n "$fail" && "$path" == *"$fail" ]] && exit 1
if [[ "$path" == *"/reviews" ]]; then
  jq -c '.[] | select(.submitted_at != null)
             | {login: .user.login,
                bot: (((.user.type // "User") == "Bot") or (.user.login | endswith("[bot]"))),
                state: .state}' "$d/reviews"
else
  # The PR object; only `requested_reviewers` is read from it.
  while IFS= read -r l; do [[ -n "$l" ]] && printf '%s\n' "$l"; done <"$d/pending"
fi
STUB
chmod +x "$tmp_dir/gh"

review() {  # <login> <state> [type]
  printf '{"user":{"login":"%s","type":"%s"},"state":"%s","submitted_at":"2026-08-03T10:%02d:00Z"}' \
    "$1" "${3:-User}" "$2" "$(( ++review_n ))"
}
set_reviews() {  # <json review>...
  review_n=0
  local IFS=,
  printf '[%s]' "$*" >"$tmp_dir/reviews"
}
reset_review_stub() {  # <post-behaviour>
  : >"$tmp_dir/pending"; : >"$tmp_dir/posts"; : >"$tmp_dir/blocking"
  printf '%s' "$1" >"$tmp_dir/post"; : >"$tmp_dir/api-fail"
}
posts() { wc -l <"$tmp_dir/posts" | tr -d ' '; }

# The ordinary first-round PR: nobody has asked for changes, so there is nothing
# to re-request and the call must cost one API read and stop. This is the answer
# on the overwhelming majority of cycles, which is what makes it safe to run the
# check unconditionally rather than trusting the work order's `source`.
review_n=0
reset_review_stub works
set_reviews "$(review octocat APPROVED)"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "an unblocked PR has nobody to re-request" "none" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... without asking GitHub to request anything" "0" "$(posts)"

# The defect, and the fix: changes requested, nothing pending. #200 exactly.
review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
printf 'Warwick-Allen\n' >"$tmp_dir/blocking"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "a blocking reviewer with no pending request is re-requested" \
  "$(printf 'requested\tWarwick-Allen')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... having posted once" "1" "$(posts)"
assert_eq "  ... naming the reviewer" "1" \
  "$(grep -c -- '-f reviewers\[\]=Warwick-Allen' "$tmp_dir/posts")"

# A COMMENTED review is not a decision. GitHub does not let one clear
# `CHANGES_REQUESTED`, so neither may this: reading each reviewer's *newest*
# review rather than their newest *decision* would conclude nobody is blocking
# and ask nobody for anything — silently, on the PRs that need it most.
review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)" "$(review Warwick-Allen COMMENTED)"
printf 'Warwick-Allen\n' >"$tmp_dir/blocking"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "a later comment does not withdraw a request for changes" \
  "$(printf 'requested\tWarwick-Allen')" "$out"

# A later approval does. The reviewer is satisfied; asking again would be noise.
review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)" "$(review Warwick-Allen APPROVED)"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "a later approval does withdraw it" "none" "$out"
assert_eq "  ... and asks for nothing" "0" "$(posts)"

# Bots are not the human this exists to reach. This org runs Copilot code review
# on every pull request, and a bot can be re-requested exactly like a person —
# which would spend money and noise on the one reviewer who is not waiting.
review_n=0
reset_review_stub works
set_reviews "$(review 'copilot-pull-request-reviewer[bot]' CHANGES_REQUESTED Bot)"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "a bot's changes-requested is not a human to notify" "none" "$out"
assert_eq "  ... and asks for nothing" "0" "$(posts)"

# Already pending: the Implementor got there first (requirement 26b). Asking
# again is a no-op that would nonetheless report `requested` and read in the log
# as work this cycle did.
review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
printf 'Warwick-Allen\n' >"$tmp_dir/pending"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "a request already pending is reported, not repeated" \
  "$(printf 'already\tWarwick-Allen')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... without posting" "0" "$(posts)"

# Two humans blocking, one already asked: the other still must be.
review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)" "$(review octocat CHANGES_REQUESTED)"
printf 'Warwick-Allen\n' >"$tmp_dir/pending"
printf 'Warwick-Allen\noctocat\n' >"$tmp_dir/blocking"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "the reviewer not yet asked is asked" \
  "$(printf 'requested\tWarwick-Allen,octocat')" "$out"
assert_eq "  ... and only that one is named in the request" "0" \
  "$(grep -c -- '-f reviewers\[\]=Warwick-Allen' "$tmp_dir/posts")"
assert_eq "  ... which does name them" "1" \
  "$(grep -c -- '-f reviewers\[\]=octocat' "$tmp_dir/posts")"

# The POST that reports success and changes nothing — `gh pr ready`'s failure
# mode one function over, and the reason the confirming read exists here too.
review_n=0
reset_review_stub silent
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "a request that does not take is a failure" \
  "$(printf 'failed\tWarwick-Allen')" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

# The silent direction, both halves. "Could not ask" must never resolve to
# "nobody was waiting" — that is this whole file's rule, and here it would leave
# a finished pull request in nobody's queue while the log recorded a clean
# handoff.
review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
printf '/reviews' >"$tmp_dir/api-fail"
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "unreadable reviews are a failure, never an assumed none" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... without posting blind" "0" "$(posts)"

review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
printf 'Warwick-Allen\n' >"$tmp_dir/blocking"
printf 'pulls/111' >"$tmp_dir/api-fail"   # the PR object; `…/pulls/111/reviews` still answers
out="$(confirm_review_requested "$URL")"; rc=$?
assert_eq "an unreadable pending list is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... without posting into the dark" "0" "$(posts)"

# No URL, and a URL that is not a pull request's. `gh api repos//pulls//reviews`
# is a usage error dressed as a lookup; neither may reach the API at all.
reset_review_stub works
out="$(confirm_review_requested "")"; rc=$?
assert_eq "an empty PR url is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
out="$(confirm_review_requested "https://github.com/Poetic-Poems/poetic-fiddle/issues/200")"; rc=$?
assert_eq "a non-PR url is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... and neither reached the API" "0" "$(posts)"

# The call-site shape agent-cycle.sh uses, under the options it uses.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/handoff.sh"
  HANDOFF_GH="/nonexistent/gh"
  x="$(confirm_review_requested "$URL")" || true
  [[ "$x" == "failed" ]] || exit 9
  state=""; who=""
  IFS=$'\t' read -r state who <<<"$x" || true
  [[ "$state" == "failed" && "$who" == "" ]] || exit 9
  exit 0
) >/dev/null 2>&1
assert_eq "confirm_review_requested's call-site shape survives set -e" "0" "$?"

# --- _handoff_pr_approved: the APPROVED half of the same computation -----------
# (agent-ops#391). `reviewDecision` never becomes `APPROVED` on a repository
# whose branch ruleset requires zero approving reviews — this repository's
# own — however many humans approve, so requirement 38c's idle nudge cannot
# depend on that field. `_handoff_pr_approved` derives it instead from the
# same reviews list `_handoff_blocking_reviewers` reads above, sharing
# `_handoff_latest_reviews` with it (one definition, two callers, requirement
# 34a's own argument). Still the same stub as `confirm_review_requested`'s
# section above.
review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen APPROVED)"
out="$(_handoff_pr_approved o/r 111)"; rc=$?
assert_eq "an approved PR with nothing blocking reads approved" "true" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
out="$(_handoff_pr_approved o/r 111)"
assert_eq "changes requested with no approval reads not approved" "false" "$out"

review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)" "$(review Warwick-Allen APPROVED)"
out="$(_handoff_pr_approved o/r 111)"
assert_eq "a later approval supersedes an earlier changes-requested" "true" "$out"

review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen APPROVED)" "$(review Warwick-Allen CHANGES_REQUESTED)"
out="$(_handoff_pr_approved o/r 111)"
assert_eq "a later changes-requested supersedes an earlier approval" "false" "$out"

review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen APPROVED)" "$(review octocat CHANGES_REQUESTED)"
out="$(_handoff_pr_approved o/r 111)"
assert_eq "one approver and a different blocker: still not approved" "false" "$out"

review_n=0
reset_review_stub works
set_reviews "$(review 'copilot-pull-request-reviewer[bot]' APPROVED Bot)"
out="$(_handoff_pr_approved o/r 111)"
assert_eq "a bot's approval is not a human's" "false" "$out"

review_n=0
reset_review_stub works
set_reviews "$(review Warwick-Allen APPROVED)"
printf '/reviews' >"$tmp_dir/api-fail"
out="$(_handoff_pr_approved o/r 111)"; rc=$?
assert_eq "unreadable reviews is a failure, never a guessed answer" "" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

# --- ensure_human_reviewer: the case confirm_review_requested has nobody for ---
# (requirement 38a). poetic-fiddle #170: approved, green, idle 6.8 days, nobody
# ever asked again once the review that approved it consumed the request that
# put it in front of a human. `confirm_review_requested` correctly answers
# `none` here — nothing is CHANGES_REQUESTED — which is exactly the case this
# function exists to cover.
#
# The stub answers everything `ensure_human_reviewer` reads:
#   $tmp_dir/draft         "true" | "false" | "error" — same as confirm_pr_ready's
#   $tmp_dir/reviews       the reviews array, verbatim JSON (as above)
#   $tmp_dir/pending       the requested_reviewers entries, one per line —
#                          `login` alone (type defaults to `User`), or
#                          `login<TAB>type` to fixture a bot-type account
#   $tmp_dir/pending-teams the requested_teams slugs, one per line
#   $tmp_dir/author        the pull request author's login
#   $tmp_dir/post          "works" | "silent" — whether the POST changes `pending`
#   $tmp_dir/api-fail      the path fragment whose GET should fail, if any
#   $tmp_dir/posts         one line per POST, recording its arguments
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
fail="$(cat "$d/api-fail" 2>/dev/null || true)"
if [[ "$1 $2" == "pr view" ]]; then
  flag="$(cat "$d/draft")"
  [[ "$flag" == "error" ]] && exit 1
  printf '%s' "$flag"
  exit 0
fi
if [[ "$1 $2" == "api -X" ]]; then
  printf '%s\n' "$*" >>"$d/posts"
  if [[ "$(cat "$d/post")" == "works" ]]; then
    for a in "$@"; do
      [[ "$a" == reviewers\[\]=* ]] && printf '%s\n' "${a#reviewers[]=}" >>"$d/pending"
    done
    sort -u -o "$d/pending" "$d/pending"
  fi
  exit 0
fi
path="$2"
[[ -n "$fail" && "$path" == *"$fail" ]] && exit 1
if [[ "$path" == *"/reviews" ]]; then
  jq -c '.[] | select(.submitted_at != null)
             | {login: .user.login,
                bot: (((.user.type // "User") == "Bot") or (.user.login | endswith("[bot]"))),
                state: .state}' "$d/reviews"
elif [[ "$*" == *"user.login"* ]]; then
  cat "$d/author"
else
  # Builds the raw `requested_reviewers`/`requested_teams` shape a real PR
  # object carries and runs the production `--jq` filter over it for real —
  # rather than passing `$d/pending` through untouched, which would let a
  # bot-filtering regression there go unnoticed (tech-debt/TD-PPagop-26081403.md).
  #
  # The filter is the one `ensure_human_reviewer` actually handed this call,
  # read back out of its own argv, never a copy of it written here: a copy
  # asserts only that the copy filters, and would keep passing with the
  # production `--jq` reverted to an unfiltered `[.requested_reviewers[]?
  # .login]` — which is precisely the regression the previous paragraph
  # claims to catch.
  jq_filter=""
  prev=""
  for a in "$@"; do
    if [[ "$prev" == "--jq" ]]; then jq_filter="$a"; break; fi
    prev="$a"
  done
  [[ -n "$jq_filter" ]] || { echo "stub: no --jq in: $*" >&2; exit 1; }
  {
    printf '{"requested_reviewers":['
    first=true
    while IFS=$'\t' read -r login rtype; do
      [[ -n "$login" ]] || continue
      $first || printf ','
      first=false
      printf '{"login":"%s","type":"%s"}' "$login" "${rtype:-User}"
    done <"$d/pending"
    printf '],"requested_teams":['
    first=true
    while IFS= read -r slug; do
      [[ -n "$slug" ]] || continue
      $first || printf ','
      first=false
      printf '{"slug":"%s"}' "$slug"
    done <"$d/pending-teams"
    printf ']}'
  } | jq -r "$jq_filter"
fi
STUB
chmod +x "$tmp_dir/gh"

reset_human_stub() {  # <draft-flag> <post-behaviour>
  printf '%s' "$1" >"$tmp_dir/draft"
  printf '%s' "$2" >"$tmp_dir/post"
  : >"$tmp_dir/pending"; : >"$tmp_dir/pending-teams"; : >"$tmp_dir/posts"; : >"$tmp_dir/api-fail"
  printf 'warwickallen\n' >"$tmp_dir/author"
}

# The ordinary case: CODEOWNERS already resolved the review to someone who is
# not the author (it never proposes the author), that person approved, and the
# approval consumed their request. Re-request them — never ASSIGNEE, whose only
# job here is the fallback for a pull request nobody has ever reviewed.
review_n=0
reset_human_stub false works
set_reviews "$(review Warwick-Allen APPROVED)"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "an approved-but-idle PR re-requests its own approver" \
  "$(printf 'requested\tWarwick-Allen')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... naming that reviewer, not the assignee" "1" \
  "$(grep -c -- '-f reviewers\[\]=Warwick-Allen' "$tmp_dir/posts")"
assert_eq "  ... and never the assignee, who is the PR's own author here" "0" \
  "$(grep -c -- '-f reviewers\[\]=warwickallen' "$tmp_dir/posts")"

# Already pending: nothing to do, and it must say so rather than re-asking.
review_n=0
reset_human_stub false works
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' >"$tmp_dir/pending"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "an already-pending request is reported, not repeated" \
  "$(printf 'already\tWarwick-Allen')" "$out"
assert_eq "  ... without posting" "0" "$(wc -l <"$tmp_dir/posts" | tr -d ' ')"

# Nobody has ever reviewed this pull request — CODEOWNERS never fired, or the
# repo has none. ASSIGNEE is the only candidate left, and it is not the author.
review_n=0
reset_human_stub false works
set_reviews
printf 'octocat\n' >"$tmp_dir/author"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "with nobody known, ASSIGNEE is the fallback" \
  "$(printf 'requested\twarwickallen')" "$out"

# CODEOWNERS' own auto-request, live before anyone has reviewed at all — the
# gap that misread agent-ops #350, #353, #355 as `skip\tno-candidate` even
# though a live human review request already stood on each: nobody has
# submitted a review yet, so `known` is empty, but a request is already
# pending for someone who is not ASSIGNEE and not the author. Report it as
# `already`, never fall through to `no-candidate`.
review_n=0
reset_human_stub false works
set_reviews
printf 'octocat\n' >"$tmp_dir/author"
printf 'Warwick-Allen\n' >"$tmp_dir/pending"
out="$(ensure_human_reviewer "$URL" "octocat")"; rc=$?
assert_eq "a pending CODEOWNERS request is reported, not read as no-candidate" \
  "$(printf 'already\tWarwick-Allen')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... without posting" "0" "$(wc -l <"$tmp_dir/posts" | tr -d ' ')"

# The exact agent-ops #350/#353/#355 shape: ASSIGNEE equal to the author too
# (this system's own pull requests), which alone would fall to
# `skip\tno-candidate` — but CODEOWNERS' pending request for a distinct
# account already answers the requirement, so this must not.
review_n=0
reset_human_stub false works
set_reviews
printf 'Warwick-Allen\n' >"$tmp_dir/pending"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "a pending request survives even when ASSIGNEE equals the author" \
  "$(printf 'already\tWarwick-Allen')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# A bot-type account sitting in `requested_reviewers` is never read as proof a
# human was asked — this org runs Copilot code review, and a repository
# ruleset can auto-request it into this exact list
# (tech-debt/TD-PPagop-26081403.md). With nobody known and ASSIGNEE equal to
# the author, a bot-only pending entry must still fall to `no-candidate`,
# never `already`.
review_n=0
reset_human_stub false works
set_reviews
printf 'copilot-pull-request-reviewer\tBot\n' >"$tmp_dir/pending"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "a bot-type pending reviewer is not a candidate" \
  "$(printf 'skip\tno-candidate')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# The other half of the same filter `_handoff_known_reviewers` already
# applies: a `[bot]`-suffixed login with no explicit `type` field.
review_n=0
reset_human_stub false works
set_reviews
printf 'some-app[bot]\n' >"$tmp_dir/pending"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "a [bot]-suffixed pending reviewer is not a candidate" \
  "$(printf 'skip\tno-candidate')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# A requested team is extended the same review-request mechanism CODEOWNERS
# gives a named human, and a team can never itself be a bot: it answers the
# requirement on its own, exactly as a pending user login does — agreeing
# with `scripts/gather-human-visibility-hygiene.sh`'s own read of this rule
# (requirement 38e, tech-debt/TD-PPagop-26081403.md).
review_n=0
reset_human_stub false works
set_reviews
printf 'reviewers-team\n' >"$tmp_dir/pending-teams"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "a pending team request is reported, not read as no-candidate" \
  "$(printf 'already\treviewers-team')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# The collision this function exists to avoid a 422 on: nobody has ever
# reviewed, and ASSIGNEE is also the pull request's own author — exactly this
# system's own pull requests, authored and comment-attributed under one
# account while a human reviews under another. GitHub refuses a review request
# aimed at an author; asking is not attempted at all, and it is not a warning-
# worthy `failed` either, because the configuration will say the same thing
# again next cycle. It is, though, a distinguishable `skip\tno-candidate`
# (tech-debt/TD-PPagop-26081001.md): nobody else will ever ask this human
# either, unlike a draft or a blocked pull request's own bare `skip`.
review_n=0
reset_human_stub false works
set_reviews
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "ASSIGNEE equal to the author is a distinguishable skip, not a 422 attempt" \
  "$(printf 'skip\tno-candidate')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... having asked GitHub nothing" "0" "$(wc -l <"$tmp_dir/posts" | tr -d ' ')"

# The author in the reviews list, which GitHub does permit: `APPROVE` and
# `REQUEST_CHANGES` are closed to a pull request's author but `COMMENT` is not,
# and the Reviewer stage may file its findings exactly that way, under the same
# account that raised the pull request. The POST 422s as a whole when any one
# login on it is invalid — it would add nobody at all, including the human who
# actually approved — so the author must be struck off before anything is
# asked.
review_n=0
reset_human_stub false works
set_reviews "$(review warwickallen COMMENTED)" "$(review Warwick-Allen APPROVED)"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "the author's own COMMENT review is never a request target" \
  "$(printf 'requested\tWarwick-Allen')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... asking only for the reviewer who is not the author" "0" \
  "$(grep -c -- '-f reviewers\[\]=warwickallen' "$tmp_dir/posts")"
assert_eq "  ... in one POST" "1" "$(wc -l <"$tmp_dir/posts" | tr -d ' ')"

# The same, with nobody else on the list: striking the author off leaves no
# candidate at all, and ASSIGNEE is the author too, so it is a skip — not a
# request GitHub would refuse, and not a `failed` worth warning about — and,
# like the case above, distinguishable as `no-candidate`.
review_n=0
reset_human_stub false works
set_reviews "$(review warwickallen COMMENTED)"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "an author-only reviews list leaves nobody to ask" \
  "$(printf 'skip\tno-candidate')" "$out"
assert_eq "  ... having asked GitHub nothing" "0" "$(wc -l <"$tmp_dir/posts" | tr -d ' ')"

# CHANGES_REQUESTED still blocking: confirm_review_requested's job, not this
# one's — this function must stay out of the way rather than also requesting a
# review from ASSIGNEE alongside it.
review_n=0
reset_human_stub false works
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "something CHANGES_REQUESTED-blocking is left to confirm_review_requested" \
  "skip" "$out"
assert_eq "  ... without posting" "0" "$(wc -l <"$tmp_dir/posts" | tr -d ' ')"

# A draft has no review to request at all.
reset_human_stub true works
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "a draft pull request is skipped" "skip" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# An empty ASSIGNEE with nobody known is a skip too — there is nobody to name
# — and the same distinguishable `no-candidate` shape, not a bare `skip`.
review_n=0
reset_human_stub false works
set_reviews
out="$(ensure_human_reviewer "$URL" "")"; rc=$?
assert_eq "no assignee and no known reviewer is a distinguishable skip" \
  "$(printf 'skip\tno-candidate')" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# The POST that reports success and changes nothing.
review_n=0
reset_human_stub false silent
set_reviews "$(review Warwick-Allen APPROVED)"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "a request that does not take is a failure" \
  "$(printf 'failed\tWarwick-Allen')" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

# The silent direction: "could not ask" must never resolve to "skip" or "none".
review_n=0
reset_human_stub false works
set_reviews "$(review Warwick-Allen APPROVED)"
printf '/reviews' >"$tmp_dir/api-fail"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "unreadable reviews are a failure, never an assumed skip" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

review_n=0
reset_human_stub false works
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'pulls/111' >"$tmp_dir/api-fail"
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
assert_eq "an unreadable pending list is a failure" "failed" "$out"
assert_eq "  ... and exits 1" "1" "$rc"

reset_human_stub true works
out="$(ensure_human_reviewer "$URL" "warwickallen")"; rc=$?
out2="$(ensure_human_reviewer "" "warwickallen")"; rc2=$?
assert_eq "an empty PR url is a skip, not a failure" "skip" "$out2"
assert_eq "  ... and exits 0" "0" "$rc2"

# --- handoff_round_answered: the tri-state, and which way it fails ------------
# The shared answered-from-events predicate two callers agree on
# (scripts/gather-review-feedback.sh's requirement 3c candidate rule and
# scripts/sweep-human-visibility.sh's requirement 38c self-heal). It needs its
# own assertions here rather than only its callers' because the two read
# opposite halves of it, and because its failure direction is the whole point:
# `answered` is the verdict that acts — it re-requests a human's review — so
# anything this cannot compute must land on `unknown`, never there. A read
# failure that reads as `answered` re-requests an unanswered round, which is
# PR #205's silent starvation reintroduced fleet-wide.
BLOCK_AT="2026-08-03T10:01:00Z"
marked_reply() {  # <at>
  jq -cn --arg at "$1" \
    --arg body "Addressed. $PIPELINE_COMMENT_MARKER_PREFIX cycle=X actor=implementor -->" \
    '{at: $at, body: $body}'
}

assert_eq "no events at all is unanswered" "unanswered" \
  "$(handoff_round_answered "$BLOCK_AT" '[]' '[]')"
assert_eq "a marked implementor reply after the blocking review answers it" "answered" \
  "$(handoff_round_answered "$BLOCK_AT" '[]' "[$(marked_reply 2026-08-03T10:05:00Z)]")"
assert_eq "the same reply before the blocking review answers a previous round" "unanswered" \
  "$(handoff_round_answered "$BLOCK_AT" '[]' "[$(marked_reply 2026-08-03T09:00:00Z)]")"
assert_eq "an unmarked comment never answers" "unanswered" \
  "$(handoff_round_answered "$BLOCK_AT" '[]' '[{"at":"2026-08-03T10:05:00Z","body":"looks close"}]')"
assert_eq "another actor's marked comment never answers" "unanswered" \
  "$(handoff_round_answered "$BLOCK_AT" '[]' \
      "[{\"at\":\"2026-08-03T10:05:00Z\",\"body\":\"$PIPELINE_COMMENT_MARKER_PREFIX cycle=X actor=reviewer -->\"}]")"
assert_eq "a rerequest event answers only when the caller passes that signal" "answered" \
  "$(handoff_round_answered "$BLOCK_AT" '[]' '[]' '[{"at":"2026-08-03T10:05:00Z"}]')"
assert_eq "  ... and the caller that omits it is not answered by one" "unanswered" \
  "$(handoff_round_answered "$BLOCK_AT" '[]' '[]')"

# Every unreadable input is `unknown`, and specifically not `answered`.
assert_eq "a non-array reviews argument is unknown" "unknown" \
  "$(handoff_round_answered "$BLOCK_AT" 'oops' '[]')"
assert_eq "a non-array comments argument is unknown" "unknown" \
  "$(handoff_round_answered "$BLOCK_AT" '[]' '{"not":"an array"}')"
assert_eq "an empty blocking timestamp is unknown, not a match on everything" "unknown" \
  "$(handoff_round_answered "" '[]' "[$(marked_reply 2026-08-03T10:05:00Z)]")"
# A `gh api --paginate --jq '[…]'` read of a PR past the endpoint's thirty-item
# default emits one array *per page*. Two documents satisfy a `type == "array"`
# check — jq evaluates the filter once per document — and then break the
# extraction. That must not read as an answered round.
assert_eq "two concatenated pages are unknown, never answered" "unknown" \
  "$(handoff_round_answered "$BLOCK_AT" "$(printf '[]\n[]')" '[]' 2>/dev/null)"
assert_eq "an array whose elements break the extraction is unknown" "unknown" \
  "$(handoff_round_answered "$BLOCK_AT" '[1,2,3]' '[]' 2>/dev/null)"
# The remaining two shapes are pinned on `handoff_answer_events` directly.
# `handoff_round_answered`'s own `type == "array"` checks reject them one step
# earlier whenever the stray document is an argument's *last* — jq exits on
# the last document's truth — so routing them through it would assert the
# checks, not the guard. What must hold is that the guard itself refuses:
#
#   - a trailing document that is literally `null` is indistinguishable from
#     "nothing left" to any test on a bound value, on every jq version;
#   - unparseable trailing bytes are a parse error `--argjson` rejected too,
#     and a `try` around the read swallows it.
#
# Both shift the later bindings onto the wrong documents, and a shifted `$rr`
# counts every element unconditionally — `[$rr[] | .at]` applies no marker
# filter — so ordinary unmarked human chatter would close the round. The
# concatenated-pages pin above is the third shape, and is the one that fails
# on jq 1.6 and passes on 1.7 if the guard regresses to a `try input` binding
# (the node image is 1.7; a developer box's system jq is 1.6), so this
# section is only fully proven when run on both.
out="$(handoff_answer_events '[]' '[]' "$(printf '[]\nnull')" 2>/dev/null)"; rc=$?
assert_eq "a trailing null document is refused, not read as nothing left" "5" "$rc"
assert_eq "  ... and nothing is printed when it is" "" "$out"
out="$(handoff_answer_events '[]' '[]' "$(printf '[]\nnotjson')" 2>/dev/null)"; rc=$?
assert_eq "unparseable trailing bytes are refused, as --argjson refused them" "5" "$rc"
assert_eq "  ... and nothing is printed when they are" "" "$out"
# The good path, so the guard is proven to refuse only what it should: a
# trailing newline after the third document is not a fourth document.
out="$(handoff_answer_events '[]' "[$(marked_reply 2026-08-03T10:05:00Z)]" '[]')"; rc=$?
assert_eq "three well-formed arguments are not refused" "0" "$rc"
assert_eq "  ... and the marked reply is still found" '["2026-08-03T10:05:00Z"]' "$out"

# --- The argv cap (requirement 4g, TD-PPagop-26081501) -------------------------
#
# REVIEWS_JSON, COMMENTS_JSON and REREQUESTS_JSON used to ride into
# `handoff_answer_events`'s own `jq` call as `--argjson`: genuinely unbounded,
# the same shape TD-PPagop-26081401/26081406 already fixed elsewhere in this
# file's siblings. Past MAX_ARG_STRLEN (131072 bytes) a single oversized
# review or comment body made the call die at `execve`, and both callers
# (scripts/gather-review-feedback.sh's direct call, and
# scripts/sweep-human-visibility.sh's through `handoff_round_answered`) read
# that failure back with no distinct "could not tell" outcome. Requirement 4g
# moves all three onto stdin.
oversized_body="$(head -c 140000 < /dev/zero | tr '\0' 'x')"
assert_eq "the oversized-body fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( ${#oversized_body} > 131072 ))"

# The marked reply itself is the oversized one — the exact shape the register
# entry confirmed reproduces `/usr/bin/jq: Argument list too long` — sitting
# alongside an oversized *unmarked* review, so the fix is proven to filter
# correctly, not merely to avoid crashing. Built with the `printf` builtin,
# not `jq --arg`: an `--arg` carrying the oversized body would hit the very
# argv cap this section exists to prove the real code no longer does.
oversized_marked_reply="$(printf '{"at": "2026-08-03T10:05:00Z", "body": "Addressed. %s %s cycle=X actor=implementor -->"}' \
  "$oversized_body" "$PIPELINE_COMMENT_MARKER_PREFIX")"
oversized_unmarked_review="$(printf '{"at": "2026-08-03T09:00:00Z", "body": "%s"}' "$oversized_body")"

events="$(handoff_answer_events "[$oversized_unmarked_review]" "[$oversized_marked_reply]" '[]' 2>/dev/null)"; rc=$?
assert_eq "a review/comment body past the argv cap no longer kills the call" "0" "$rc"
assert_eq "  ... and still finds only the marked implementor reply" "1" "$(jq 'length' <<<"$events")"
assert_eq "  ... at its own timestamp" "2026-08-03T10:05:00Z" "$(jq -r '.[0]' <<<"$events")"

assert_eq "handoff_round_answered survives the same oversized bodies, reading the round answered" \
  "answered" \
  "$(handoff_round_answered "$BLOCK_AT" "[$oversized_unmarked_review]" "[$oversized_marked_reply]" 2>/dev/null)"

# --- handoff_complete_review (requirements 31c/32b, agent-ops#440, #533) ------
#
# The one gate-and-flip implementation both the Reviewer's own handoff and
# the Enabler's `complete_handoff` recovery path call. Its seven callees —
# `review_gate_verdict`, `closing_keyword_gate`, `reconciliation_gate`,
# `confirm_pr_draft`, `confirm_pr_ready`, `confirm_review_requested`,
# `ensure_human_reviewer` — are stubbed as plain bash functions here rather
# than run for real: each already has its own test (test/review-gate.test.sh,
# test/closing-keyword-gate.test.sh, test/reconciliation-gate.test.sh, and
# `confirm_pr_draft`/`confirm_pr_ready`/`confirm_review_requested`/
# `ensure_human_reviewer` above in this file), so what this section proves is
# the composition — which callee runs, in what order, and what `safe` and
# `revert` end up meaning — not any one of them individually.
REVIEW_URL="https://github.com/Poetic-Poems/agent-ops/pull/440"

# Every case below defines whichever of the seven stubs it needs; the rest
# fail loudly if called at all, so a short-circuit that should skip a later
# gate — or, for `confirm_pr_draft`, a case that never reaches a `dirty`
# reconciliation verdict at all — is caught the moment it is not.
unset -f review_gate_verdict closing_keyword_gate reconciliation_gate confirm_pr_draft \
  confirm_pr_ready confirm_review_requested ensure_human_reviewer 2>/dev/null || true
not_reached() { echo "FAIL - $1 was called but should not have been" >&2; exit 99; }

# --- a dirty review gate refuses, and nothing past it runs ---------------------
review_gate_verdict() { printf 'dirty\trequired check(s) not green: CI'; return 1; }
closing_keyword_gate() { not_reached closing_keyword_gate; }
reconciliation_gate() { not_reached reconciliation_gate; }
confirm_pr_draft() { not_reached confirm_pr_draft; }
confirm_pr_ready() { not_reached confirm_pr_ready; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "a dirty gate: safe is false" "false" "$(jq -r '.safe' <<<"$out")"
assert_eq "  ... gate.word carries dirty" "dirty" "$(jq -r '.gate.word' <<<"$out")"
assert_eq "  ... gate.reason names the fault" "required check(s) not green: CI" "$(jq -r '.gate.reason' <<<"$out")"
assert_eq "  ... checks_unreadable is false — this is a real fault, not an unread list" \
  "false" "$(jq -r '.gate.checks_unreadable' <<<"$out")"
assert_eq "  ... closing_keyword.word is empty — the ck gate never ran" "" "$(jq -r '.closing_keyword.word' <<<"$out")"
assert_eq "  ... reconciliation.word is empty — the reconciliation gate never ran" "" "$(jq -r '.reconciliation.word' <<<"$out")"
assert_eq "  ... revert is empty — confirm_pr_draft never ran" "" "$(jq -r '.revert' <<<"$out")"
assert_eq "  ... handoff is empty — confirm_pr_ready never ran" "" "$(jq -r '.handoff' <<<"$out")"

# --- an unreadable required-check list refuses too, distinctly ----------------
review_gate_verdict() { printf 'unknown\tcould not read required checks'; return 2; }
closing_keyword_gate() { not_reached closing_keyword_gate; }
reconciliation_gate() { not_reached reconciliation_gate; }
confirm_pr_draft() { not_reached confirm_pr_draft; }
confirm_pr_ready() { not_reached confirm_pr_ready; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "an unreadable check list: safe is false" "false" "$(jq -r '.safe' <<<"$out")"
assert_eq "  ... checks_unreadable is true — the caller must branch on this, not the word" \
  "true" "$(jq -r '.gate.checks_unreadable' <<<"$out")"

# A `dirty` alerts verdict can still win the word while the required-checks
# read failed underneath it (`review_gate_verdict`'s own header) — the exit
# status carries that fact independently of the word, and this function must
# still refuse on `checks_unreadable`, not merely on `gate.word == "dirty"`.
review_gate_verdict() { printf 'dirty\topen security-severity code-scanning alert(s): #42 (critical)'; return 2; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "a dirty alert over an unreadable check list: safe is still false" \
  "false" "$(jq -r '.safe' <<<"$out")"
assert_eq "  ... checks_unreadable is true even though the word says dirty" \
  "true" "$(jq -r '.gate.checks_unreadable' <<<"$out")"
assert_eq "  ... and the reason is the alert's, not the check list's" \
  "open security-severity code-scanning alert(s): #42 (critical)" "$(jq -r '.gate.reason' <<<"$out")"

# --- a clean gate falls through to the closing-keyword gate --------------------
review_gate_verdict() { printf 'clean'; return 0; }
closing_keyword_gate() { printf 'dirty\tno closing keyword for #42'; return 1; }
reconciliation_gate() { not_reached reconciliation_gate; }
confirm_pr_draft() { not_reached confirm_pr_draft; }
confirm_pr_ready() { not_reached confirm_pr_ready; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "a dirty closing keyword (gate clean): safe is false" "false" "$(jq -r '.safe' <<<"$out")"
assert_eq "  ... gate.word still carries the clean gate's own word" "clean" "$(jq -r '.gate.word' <<<"$out")"
assert_eq "  ... closing_keyword.reason names the fault" "no closing keyword for #42" "$(jq -r '.closing_keyword.reason' <<<"$out")"
assert_eq "  ... reconciliation.word is empty — the reconciliation gate never ran" "" "$(jq -r '.reconciliation.word' <<<"$out")"
assert_eq "  ... revert is empty — confirm_pr_draft never ran" "" "$(jq -r '.revert' <<<"$out")"
assert_eq "  ... handoff is empty — confirm_pr_ready never ran" "" "$(jq -r '.handoff' <<<"$out")"

# --- both prior gates clean, but the reconciliation gate is dirty -------------
# agent-ops#539: a `dirty` verdict now reverts the pull request to draft
# (`confirm_pr_draft`) rather than merely refusing — this is the fix's core
# assertion, that `revert` carries what that call found.
review_gate_verdict() { printf 'clean'; return 0; }
closing_keyword_gate() { printf 'clean'; return 0; }
reconciliation_gate() { printf 'dirty\thuman comment(s) posted since the PR last left draft carry no reconcile citation: comment id(s) 4718691960'; return 1; }
confirm_pr_draft() { printf 'reverted'; return 0; }
confirm_pr_ready() { not_reached confirm_pr_ready; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "a dirty reconciliation gate (both prior gates clean): safe is false" "false" "$(jq -r '.safe' <<<"$out")"
assert_eq "  ... gate.word still carries the clean review gate's own word" "clean" "$(jq -r '.gate.word' <<<"$out")"
assert_eq "  ... closing_keyword.word still carries the clean ck gate's own word" "clean" "$(jq -r '.closing_keyword.word' <<<"$out")"
assert_eq "  ... reconciliation.reason names the unreconciled comment" \
  "human comment(s) posted since the PR last left draft carry no reconcile citation: comment id(s) 4718691960" \
  "$(jq -r '.reconciliation.reason' <<<"$out")"
assert_eq "  ... revert carries confirm_pr_draft's own word" "reverted" "$(jq -r '.revert' <<<"$out")"
assert_eq "  ... handoff is empty — confirm_pr_ready never ran" "" "$(jq -r '.handoff' <<<"$out")"

# `confirm_pr_draft` can also answer `already-draft` (the Enabler's
# `complete_handoff` path, whose block never flipped this pull request ready
# in the first place) or `failed` (the pull request could not be confirmed
# back in draft at all) — both must reach `revert` unchanged, the same as
# `reverted` above, so a caller can tell them apart.
confirm_pr_draft() { printf 'already-draft'; return 0; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "a dirty reconciliation gate on an already-draft PR: revert says so" \
  "already-draft" "$(jq -r '.revert' <<<"$out")"
assert_eq "  ... safe is still false" "false" "$(jq -r '.safe' <<<"$out")"

confirm_pr_draft() { printf 'failed'; return 1; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "a dirty reconciliation gate whose revert itself fails: revert says so" \
  "failed" "$(jq -r '.revert' <<<"$out")"
assert_eq "  ... safe is still false — this is worse than the ordinary dirty case, not better" \
  "false" "$(jq -r '.safe' <<<"$out")"

# --- the round-start bound reaches the reconciliation gate --------------------
# `handoff_complete_review` runs after the Reviewer's own step-7 `gh pr ready`,
# so an unbounded `reconciliation_gate` anchors on that very flip and reports
# `clean` on every pull request it exists to refuse (agent-ops#533; see
# `_reconciliation_gate_anchor`). The bound is this function's fourth
# argument, handed straight through as the gate's second — pinned here so a
# change that drops it fails loudly rather than silently disarming the gate.
review_gate_verdict() { printf 'clean'; return 0; }
closing_keyword_gate() { printf 'clean'; return 0; }
# Recorded through a file, not a variable: `handoff_complete_review` calls
# each gate inside a command substitution, so an assignment made in the stub
# dies with that subshell.
recon_bound_file="$tmp_dir/recon-bound"
reconciliation_gate() { printf '%s' "${2-<unset>}" >"$recon_bound_file"; printf 'clean'; return 0; }
confirm_pr_draft() { not_reached confirm_pr_draft; }
confirm_pr_ready() { printf 'already'; return 0; }
confirm_review_requested() { printf 'none'; return 0; }
ensure_human_reviewer() { printf 'skip'; return 0; }
handoff_complete_review "$REVIEW_URL" "main" "" "2026-08-17T00:00:00Z" >/dev/null
assert_eq "the round-start bound is forwarded to reconciliation_gate" \
  "2026-08-17T00:00:00Z" "$(cat "$recon_bound_file")"
handoff_complete_review "$REVIEW_URL" "main" "" >/dev/null
assert_eq "  ... and an omitted bound reaches it as empty, not as a missing argument" \
  "" "$(cat "$recon_bound_file")"

# --- all three gates clean, but the flip itself does not take -----------------
review_gate_verdict() { printf 'clean'; return 0; }
closing_keyword_gate() { printf 'clean'; return 0; }
reconciliation_gate() { printf 'clean'; return 0; }
confirm_pr_draft() { not_reached confirm_pr_draft; }
confirm_pr_ready() { printf 'failed'; return 1; }
confirm_review_requested() { not_reached confirm_review_requested; }
ensure_human_reviewer() { not_reached ensure_human_reviewer; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "gates clean, flip fails: safe is false" "false" "$(jq -r '.safe' <<<"$out")"
assert_eq "  ... handoff carries failed, naming the one real fault left" "failed" "$(jq -r '.handoff' <<<"$out")"
assert_eq "  ... revert is empty — the reconciliation gate was clean, nothing to revert" \
  "" "$(jq -r '.revert' <<<"$out")"
assert_eq "  ... rereview never ran" "" "$(jq -r '.rereview.state' <<<"$out")"

# --- the full clean path: flip, re-request, and the human-reviewer nudge ------
review_gate_verdict() { printf 'clean'; return 0; }
closing_keyword_gate() { printf 'clean'; return 0; }
reconciliation_gate() { printf 'clean'; return 0; }
confirm_pr_draft() { not_reached confirm_pr_draft; }
confirm_pr_ready() { printf 'already'; return 0; }
confirm_review_requested() { printf 'requested\tcarol'; return 0; }
ensure_human_reviewer() { not_reached ensure_human_reviewer; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "a clean path: safe is true" "true" "$(jq -r '.safe' <<<"$out")"
assert_eq "  ... reconciliation.word carries clean" "clean" "$(jq -r '.reconciliation.word' <<<"$out")"
assert_eq "  ... revert is empty — nothing was ever dirty enough to revert" \
  "" "$(jq -r '.revert' <<<"$out")"
assert_eq "  ... handoff carries the flip's own word" "already" "$(jq -r '.handoff' <<<"$out")"
assert_eq "  ... rereview carries confirm_review_requested's answer" "requested" "$(jq -r '.rereview.state' <<<"$out")"
assert_eq "  ... and its who" "carol" "$(jq -r '.rereview.who' <<<"$out")"
assert_eq "  ... human_reviewer never ran — rereview.state was not none" "" "$(jq -r '.human_reviewer.state' <<<"$out")"

# `ensure_human_reviewer` is only asked when nothing is CHANGES_REQUESTED
# (`rereview.state == "none"`) — the same precondition the function carries
# inline today, applied here instead so a caller cannot forget it.
confirm_review_requested() { printf 'none'; return 0; }
ensure_human_reviewer() { printf 'requested\tbob'; return 0; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "rereview none: human_reviewer is asked" "requested" "$(jq -r '.human_reviewer.state' <<<"$out")"
assert_eq "  ... and its who" "bob" "$(jq -r '.human_reviewer.who' <<<"$out")"

# An empty ASSIGNEE is `ensure_human_reviewer`'s own no-candidate precondition
# too — asking with nothing to fall back to is never useful, so this function
# must not call it either.
ensure_human_reviewer() { not_reached ensure_human_reviewer; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "")"
assert_eq "rereview none, no assignee: human_reviewer never ran" "" "$(jq -r '.human_reviewer.state' <<<"$out")"

# --- non-blocking unknowns pass through rather than refusing -------------------
# An alerts read, a closing-keyword read or a reconciliation read that could
# not be asked at all is a node or token fact (see each gate's own header),
# not a reason to refuse the handoff forever.
review_gate_verdict() { printf 'unknown\tcould not confirm no new security-severity alert: 403'; return 0; }
closing_keyword_gate() { printf 'unknown\tcould not read PR body'; return 0; }
reconciliation_gate() { printf 'unknown\tcould not read the PR'\''s timeline'; return 0; }
confirm_pr_ready() { printf 'already'; return 0; }
confirm_review_requested() { printf 'none'; return 0; }
ensure_human_reviewer() { printf 'skip'; return 0; }
out="$(handoff_complete_review "$REVIEW_URL" "main" "alice")"
assert_eq "non-blocking unknowns: safe is still true" "true" "$(jq -r '.safe' <<<"$out")"
assert_eq "  ... gate.word carries the unread-alerts unknown" "unknown" "$(jq -r '.gate.word' <<<"$out")"
assert_eq "  ... checks_unreadable is false — only the alerts read failed" \
  "false" "$(jq -r '.gate.checks_unreadable' <<<"$out")"
assert_eq "  ... closing_keyword.word carries its own unknown" "unknown" "$(jq -r '.closing_keyword.word' <<<"$out")"
assert_eq "  ... reconciliation.word carries its own unknown" "unknown" "$(jq -r '.reconciliation.word' <<<"$out")"
assert_eq "  ... revert is empty — unknown is not dirty, confirm_pr_draft never ran" \
  "" "$(jq -r '.revert' <<<"$out")"
assert_eq "  ... and the flip still completed" "already" "$(jq -r '.handoff' <<<"$out")"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
