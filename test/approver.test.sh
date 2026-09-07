#!/usr/bin/env bash
#
# test/approver.test.sh — regression test for lib/approver.sh (D18 WI-5,
# agent-ops#408; design: docs/reviews/2026-08-14-autonomy-investigation.md
# §5.2/§5.3).
#
# Covers the pure tier/model lookups, the refuse-streak derivation (the one
# piece of state this whole stage keeps, and it keeps none — every count is
# read fresh from the pull request's own reviews list, never a private
# counter this pipeline could drift from GitHub's own record), the prior-
# refusal-bodies reader an adjudication engagement's prompt is built from, and
# the one GitHub write this file performs (`approver_post_review`), including
# that `GH_TOKEN` never leaks past the one invocation it is set for.
#
# `gh` is stubbed through APPROVER_GH, the same way lib/handoff.sh's own
# tests stub theirs.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/approver.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Sourced ahead of lib/approver.sh, matching every real caller's own order
# (agent-cycle.sh) — approver_post_or_warn reuses its github_limit_kind
# classifier and github_limit_wait_plan/github_limit_primary_reset_epoch
# retry policy (agent-ops#1082).
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/approver.sh
. "$SCRIPT_DIR/lib/approver.sh"
# approver_escalation_retire wraps its own close comment in the same
# header/marker envelope every other comment this system posts carries
# (requirement 3f) — agent-cycle.sh sources this file too.
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# approver_post_review's own error log (agent-ops#945) lands at
# "${cycle_dir:-/tmp}/approver-post.err" — set here so a test asserting on it
# never touches the real /tmp.
cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"

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

URL="https://github.com/Poetic-Poems/agent-ops/pull/408"

# --- approver_tier_for (requirement 8b) ---------------------------------------

assert_eq "low is trivial" "trivial" "$(approver_tier_for low)"
assert_eq "medium is standard" "standard" "$(approver_tier_for medium)"
assert_eq "high is high" "high" "$(approver_tier_for high)"
assert_eq "an unknown grade defaults to standard" "standard" "$(approver_tier_for weird)"
assert_eq "an empty grade defaults to standard" "standard" "$(approver_tier_for "")"

# --- approver_model_for_tier (requirement 8b) ---------------------------------

assert_eq "high launches the complex model" "opus" \
  "$(approver_model_for_tier high sonnet opus)"
assert_eq "standard launches the default model" "sonnet" \
  "$(approver_model_for_tier standard sonnet opus)"
assert_eq "trivial (never actually called for a model, but degrades safely) launches the default" \
  "sonnet" "$(approver_model_for_tier trivial sonnet opus)"

# --- The stub for everything that talks to GitHub -----------------------------
# State:
#   $tmp_dir/reviews    the reviews array, verbatim JSON (login/state/at/body)
#   $tmp_dir/api-fail   non-empty disables every GET, unconditionally
#   $tmp_dir/posts      one line per POST, recording GH_TOKEN, event and body
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ -s "$d/api-fail" ]]; then
  echo "gh: Bad credentials (HTTP 401)" >&2
  exit 1
fi
if [[ "$1 $2" == "api -X" ]]; then
  # api -X POST repos/<slug>/pulls/<n>/reviews -f event=<e> -f body=<b>
  # api -X PUT  repos/<slug>/pulls/<n>/reviews/<id>/dismissals -f message=<m>
  method="$3"
  event=""
  body=""
  message=""
  shift 4
  while (( $# )); do
    case "$1" in
      -f) shift; case "$1" in
            event=*) event="${1#event=}" ;;
            body=*) body="${1#body=}" ;;
            message=*) message="${1#message=}" ;;
          esac ;;
    esac
    shift
  done
  if [[ "$method" == "PUT" ]]; then
    printf 'token=%s\tmessage=%s\n' "${GH_TOKEN:-}" "$message" >>"$d/dismissals"
  else
    printf 'token=%s\tevent=%s\tbody=%s\n' "${GH_TOKEN:-}" "$event" "$body" >>"$d/posts"
  fi
  exit 0
fi
if [[ "$1 $2" == "pr view" ]]; then
  # pr view <number> -R <slug> --json commits --jq '[.commits[].authoredDate] | max // empty'
  # `gh --jq` prints a selected scalar raw, unquoted (`-r`'s own behaviour) —
  # `jq -r` here, never `-c`, to match what the real call actually receives.
  jq -r '[.commits[].authoredDate] | max // empty' "$d/commits.json" 2>/dev/null
  exit 0
fi
# A GET against .../reviews. `gh api --jq` takes one query string with no
# `--arg` of its own, so — matching the real functions — neither call filters
# by login here; that happens in the real, un-stubbed second `jq --arg`
# call each function pipes this output through. The three callers ask for
# different shapes via --jq, distinguished the same way the real filters
# differ: only approver_prior_refusal_bodies' own filter names
# CHANGES_REQUESTED and body explicitly.
if [[ "$*" == *"CHANGES_REQUESTED"* ]]; then
  jq -c '.[] | select(.submitted_at != null and .state == "CHANGES_REQUESTED")
             | {login: .user.login, at: .submitted_at, body: (.body // "")}' "$d/reviews"
else
  jq -c '.[] | select(.submitted_at != null)
             | {login: .user.login, at: .submitted_at, state: .state}' "$d/reviews"
fi
STUB
chmod +x "$tmp_dir/gh"
export APPROVER_GH="$tmp_dir/gh"

review() {  # <login> <state> <minute> [body]
  printf '{"user":{"login":"%s"},"state":"%s","submitted_at":"2026-08-15T10:%02d:00Z","body":"%s"}' \
    "$1" "$2" "$3" "${4:-}"
}
set_reviews() {  # <json review>...
  local IFS=,
  printf '[%s]' "$*" >"$tmp_dir/reviews"
}
set_commits() {  # <authoredDate>...
  jq -cn '{commits: ($ARGS.positional | map({authoredDate: .}))}' --args "$@" >"$tmp_dir/commits.json"
}
reset_stub() {
  : >"$tmp_dir/posts"; : >"$tmp_dir/api-fail"; : >"$tmp_dir/dismissals"; rm -f "$tmp_dir/commits.json"
  rm -f "$cycle_dir/approver-post.err"
}
posts() { wc -l <"$tmp_dir/posts" | tr -d ' '; }
dismissals() { wc -l <"$tmp_dir/dismissals" | tr -d ' '; }

# --- approver_refuse_streak (requirement 8c) ----------------------------------

reset_stub
set_reviews
assert_eq "a login that never reviewed streaks at 0" "0" \
  "$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"

reset_stub
assert_eq "an empty login streaks at 0 without asking GitHub" "0" \
  "$(approver_refuse_streak "$URL" "")"

reset_stub
set_reviews "$(review "pullwright-approver[bot]" APPROVED 1)"
assert_eq "the most recent review approving streaks at 0" "0" \
  "$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"

reset_stub
set_reviews "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 1)"
assert_eq "one refusal streaks at 1" "1" \
  "$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"

reset_stub
set_reviews \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 1)" \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 2)"
assert_eq "two refusals in a row streak at 2" "2" \
  "$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"

reset_stub
set_reviews \
  "$(review "pullwright-approver[bot]" APPROVED 1)" \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 2)" \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 3)"
assert_eq "the streak stops at the most recent approval, not the oldest" "2" \
  "$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"

reset_stub
set_reviews \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 1)" \
  "$(review "pullwright-approver[bot]" COMMENTED 2)" \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 3)"
assert_eq "a COMMENTED review neither extends nor resets the streak" "2" \
  "$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"

reset_stub
set_reviews \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 1)" \
  "$(review "pullwright-approver[bot]" DISMISSED 2)" \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 3)"
assert_eq "nor does a DISMISSED one — it carries no standing verdict either" "2" \
  "$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"

reset_stub
set_reviews \
  "$(review "a-human" CHANGES_REQUESTED 1)" \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 2)"
assert_eq "another account's reviews never count toward this login's streak" "1" \
  "$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"

reset_stub
printf 'x' >"$tmp_dir/api-fail"
out="$(approver_refuse_streak "$URL" "pullwright-approver[bot]")"; rc=$?
assert_eq "an unreadable reviews list is a failure, never a guessed 0" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

reset_stub
out="$(approver_refuse_streak "" "pullwright-approver[bot]")"; rc=$?
assert_eq "an empty PR URL is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

# --- approver_prior_refusal_bodies (requirement 8c) ---------------------------

reset_stub
set_reviews \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 1 "first refusal")" \
  "$(review "pullwright-approver[bot]" APPROVED 2)" \
  "$(review "pullwright-approver[bot]" CHANGES_REQUESTED 3 "second refusal")"
out="$(approver_prior_refusal_bodies "$URL" "pullwright-approver[bot]")"
assert_eq "prior refusal bodies come oldest first" "1" \
  "$([[ "$out" == *"first refusal"*"second refusal"* ]] && echo 1 || echo 0)"
assert_eq "  ... and only the refusals, not the approval" "0" \
  "$(grep -c 'APPROVED' <<<"$out" || true)"

reset_stub
set_reviews
assert_eq "no prior refusals prints nothing" "" \
  "$(approver_prior_refusal_bodies "$URL" "pullwright-approver[bot]")"

reset_stub
assert_eq "an empty login prints nothing, without asking GitHub" "" \
  "$(approver_prior_refusal_bodies "$URL" "")"

# --- approver_post_review (requirement 8c) ------------------------------------

reset_stub
approver_post_review "$URL" APPROVE "looks fine" "secret-token"
assert_eq "one POST is made" "1" "$(posts)"
assert_eq "  ... carrying the token for that call only" "1" \
  "$(grep -c '^token=secret-token' "$tmp_dir/posts")"
assert_eq "  ... the right event" "1" "$(grep -c 'event=APPROVE' "$tmp_dir/posts")"
assert_eq "  ... and the right body" "1" "$(grep -c 'body=looks fine' "$tmp_dir/posts")"

# GH_TOKEN must never leak into this process's own environment — the same
# discipline lib/approver-token.sh's header states for the JWT it builds. A
# leading assignment on the command (`GH_TOKEN="$token" gh ...`), not
# `export`, is what the implementation relies on for that; this asserts the
# caller's own shell sees exactly what it started with, whatever that was
# (this repo's own dev/CI environment may or may not already export one for
# `gh` itself to use — the point is that this call must not change it).
before_gh_token="${GH_TOKEN-<unset>}"
reset_stub
approver_post_review "$URL" APPROVE "x" "a-different-token-entirely"
assert_eq "GH_TOKEN never leaks into the caller's own environment" \
  "$before_gh_token" "${GH_TOKEN-<unset>}"

reset_stub
approver_post_review "$URL" REQUEST_CHANGES "needs work" ""
assert_eq "no token means no POST is even attempted" "0" "$(posts)"

reset_stub
approver_post_review "" APPROVE "x" "secret-token"
assert_eq "an empty PR URL posts nothing" "0" "$(posts)"

# GitHub's own refusal (agent-ops#945): before this fix the status/body went
# to /dev/null, and the only reason the incident that motivated it was
# diagnosable at all was that a sibling call (techdebt_file_debt) happened to
# keep its own error file. approver_post_review now keeps one too.
reset_stub
printf 'x' >"$tmp_dir/api-fail"
rc=0
approver_post_review "$URL" APPROVE "x" "secret-token" || rc=$?
assert_eq "GitHub refusing the write is reported, never read as posted" "1" "$rc"
assert_eq "  ... and its status/body land in cycle_dir's own error file, not /dev/null" "1" \
  "$(grep -c "Bad credentials (HTTP 401)" "$cycle_dir/approver-post.err" 2>/dev/null || true)"

# --- approver_review_stale (requirement 46, agent-ops#682) ---------------------
# Pure predicate, no `gh` involved.

assert_eq "a matching commit is not stale" "1" \
  "$(approver_review_stale CHANGES_REQUESTED abc123 abc123 && echo 0 || echo 1)"
assert_eq "a mismatched commit under CHANGES_REQUESTED is stale" "0" \
  "$(approver_review_stale CHANGES_REQUESTED abc123 def456 && echo 0 || echo 1)"
assert_eq "an APPROVED state is never stale, mismatch or not" "1" \
  "$(approver_review_stale APPROVED abc123 def456 && echo 0 || echo 1)"
assert_eq "an empty state is never stale" "1" \
  "$(approver_review_stale "" abc123 def456 && echo 0 || echo 1)"
assert_eq "an empty commit is never stale" "1" \
  "$(approver_review_stale CHANGES_REQUESTED "" def456 && echo 0 || echo 1)"
assert_eq "an empty head is never stale" "1" \
  "$(approver_review_stale CHANGES_REQUESTED abc123 "" && echo 0 || echo 1)"

# --- approver_newest_commit_authored_at (requirement 46, agent-ops#682) --------

reset_stub
set_commits "2026-08-21T09:00:00Z" "2026-08-21T13:00:00Z" "2026-08-20T08:00:00Z"
assert_eq "the newest authoredDate wins, not list order" "2026-08-21T13:00:00Z" \
  "$(approver_newest_commit_authored_at "$URL")"

reset_stub
set_commits "2026-08-21T09:00:00Z"
assert_eq "a single commit is its own newest" "2026-08-21T09:00:00Z" \
  "$(approver_newest_commit_authored_at "$URL")"

reset_stub
set_commits
out="$(approver_newest_commit_authored_at "$URL")"; rc=$?
assert_eq "an empty commit list is a failure, never a guessed date" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

reset_stub
printf 'x' >"$tmp_dir/api-fail"
out="$(approver_newest_commit_authored_at "$URL")"; rc=$?
assert_eq "an unreadable commit list is a failure too" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

reset_stub
out="$(approver_newest_commit_authored_at "")"; rc=$?
assert_eq "an empty PR URL is a failure" "" "$out"
assert_eq "  ... and exits non-zero" "1" "$rc"

# --- approver_dismiss_review (requirement 46, agent-ops#682) -------------------

reset_stub
approver_dismiss_review "$URL" "12345" "rebase only, dismissed" "secret-token"
assert_eq "one PUT is made" "1" "$(dismissals)"
assert_eq "  ... carrying the token for that call only" "1" \
  "$(grep -c '^token=secret-token' "$tmp_dir/dismissals")"
assert_eq "  ... and the right message" "1" \
  "$(grep -c 'message=rebase only, dismissed' "$tmp_dir/dismissals")"
assert_eq "  ... and never touches the ordinary review-post log" "0" "$(posts)"

before_gh_token="${GH_TOKEN-<unset>}"
reset_stub
approver_dismiss_review "$URL" "12345" "x" "a-different-token-entirely"
assert_eq "GH_TOKEN never leaks into the caller's own environment" \
  "$before_gh_token" "${GH_TOKEN-<unset>}"

reset_stub
approver_dismiss_review "$URL" "12345" "x" ""
assert_eq "no token means no PUT is even attempted" "0" "$(dismissals)"

reset_stub
approver_dismiss_review "$URL" "" "x" "secret-token"
assert_eq "a non-numeric review id means no PUT is even attempted" "0" "$(dismissals)"

reset_stub
approver_dismiss_review "" "12345" "x" "secret-token"
assert_eq "an empty PR URL dismisses nothing" "0" "$(dismissals)"

reset_stub
printf 'x' >"$tmp_dir/api-fail"
rc=0
approver_dismiss_review "$URL" "12345" "x" "secret-token" || rc=$?
assert_eq "GitHub refusing the write is reported, never read as a dismissal" "1" "$rc"

# --- approver_post_or_warn: rate-limit refusals (agent-ops#1082) ---------------
# A failed write used to log the same generic "GitHub refused the write"
# whether GitHub rejected the token outright or merely refused because the
# owner's shared REST budget was spent — and dropped the verdict outright
# either way. This covers both halves: the log line names a rate-limit
# refusal distinguishably, and a refusal `github_limit_wait_plan` says is
# worth waiting for is retried rather than dropped.
#
# A dedicated stub, since the two behaviours this section tests — a
# controllable fail-then-succeed POST sequence, and a real (short) secondary
# rate-limit wait — are not what the stub above exercises. `GITHUB_LIMIT_
# SECONDARY_WAIT_SECONDS=1` keeps the real `sleep` this exercises well under
# a second's worth of test time rather than the production default's 20s.
rl_dir="$tmp_dir/ratelimit"
mkdir -p "$rl_dir"
cat >"$rl_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1 $2" == "api -X" ]]; then
  n="$(cat "$d/post-calls" 2>/dev/null || printf 0)"
  n=$(( n + 1 ))
  printf '%s' "$n" >"$d/post-calls"
  fail_count="$(cat "$d/fail-count" 2>/dev/null || printf 0)"
  if (( n <= fail_count )); then
    cat "$d/fail-message" >&2
    exit 1
  fi
  printf 'posted\n' >>"$d/posts"
  exit 0
fi
exit 1
STUB
chmod +x "$rl_dir/gh"

events=()
log_event() { events+=("$1"$'\t'"$2"); }
reset_rl_stub() {  # <fail-count> <fail-message>
  printf '%s' "$1" >"$rl_dir/fail-count"
  printf '%s' "$2" >"$rl_dir/fail-message"
  : >"$rl_dir/post-calls"; : >"$rl_dir/posts"
  events=()
  GITHUB_LIMIT_WAITED_SECONDS=0
}
rl_posts() { wc -l <"$rl_dir/posts" 2>/dev/null | tr -d ' '; }
rl_post_calls() { cat "$rl_dir/post-calls" 2>/dev/null || printf 0; }
warning_events() { local e; for e in "${events[@]}"; do [[ "$e" == warning$'\t'* ]] && printf '%s\n' "${e#*$'\t'}"; done; }

GITHUB_LIMIT_SECONDARY_WAIT_SECONDS=1
APPROVER_GH="$rl_dir/gh"
cycle_dir="$rl_dir/cycle"; mkdir -p "$cycle_dir"

# A secondary refusal (a wait always worth taking, per github_limit_wait_plan)
# on the first attempt, success on the retry: the verdict reaches GitHub, not
# dropped, and approver_last_post_ok says so.
reset_rl_stub 1 "You have exceeded a secondary rate limit. Please wait a few minutes."
approver_last_post_ok=-1
approver_post_or_warn "$URL" APPROVE "looks fine" "secret-token"
assert_eq "a rate-limited write is retried rather than dropped" "1" "$approver_last_post_ok"
assert_eq "  ... exactly two POST attempts were made" "2" "$(rl_post_calls)"
assert_eq "  ... and the retry actually reached GitHub" "1" "$(rl_posts)"
assert_eq "  ... logging no warning at all — the retry recovered it" "" "$(warning_events)"

# A refusal that is still rate-limited on the retry: dropped, but the warning
# names the cause distinguishably from a generic refusal, and says a retry
# was attempted.
reset_rl_stub 99 "You have exceeded a secondary rate limit. Please wait a few minutes."
approver_last_post_ok=-1
approver_post_or_warn "$URL" APPROVE "looks fine" "secret-token"
assert_eq "a write still rate-limited after the retry is not posted" "0" "$approver_last_post_ok"
assert_contains "  ... its warning names the rate limit, not a generic refusal" \
  "secondary rate limit" "$(warning_events)"
assert_contains "  ... and says a retry was made" "retried" "$(warning_events)"

# A generic (non-rate-limit) refusal: no retry attempted at all, and the
# warning keeps its original, generic wording — unchanged behaviour.
reset_rl_stub 99 "Bad credentials (HTTP 401)"
approver_last_post_ok=-1
approver_post_or_warn "$URL" APPROVE "looks fine" "secret-token"
assert_eq "a generic refusal is not retried" "1" "$(rl_post_calls)"
assert_eq "  ... and is not posted" "0" "$approver_last_post_ok"
assert_contains "  ... its warning keeps the original generic wording" \
  "GitHub refused the write" "$(warning_events)"

# --- approver_escalate: the condition that fired (requirement 8c) --------------
# agent-ops#1214: one fixed "could not resolve the disagreement" sentence used
# to be filed for every condition, so #1202 told the owner an adjudication
# "could not resolve" a disagreement whose own verdict had named concrete
# remedies and explicitly disclaimed escalation. The optional third argument
# now selects the "Why the pipeline is blocked" wording; nothing else about
# the issue — the reasons, the footer, and above all the `pr-<n>-approver-
# adjudication` item ref `create_escalation_issue` dedups on — may vary with
# it, or a second condition on the same pull request would file a second
# issue rather than finding the first.
esc_dir="$tmp_dir/escalate"
mkdir -p "$esc_dir"
# shellcheck disable=SC2034  # Read by approver_escalate, which a real cycle calls with these in scope.
selected_repo="Poetic-Poems/agent-ops"
# shellcheck disable=SC2034
enabler_escalation_label="escalation"
# shellcheck disable=SC2034
cycle_id="test-cycle"
# shellcheck disable=SC2034
node_name="test-node"
create_escalation_issue() {
  printf '%s\n' "$2" >"$esc_dir/item-ref"
  printf '%s\n' "$4" >"$esc_dir/title"
  printf '11\thttps://github.com/Poetic-Poems/agent-ops/issues/11'
}
run_escalate() {  # <condition-or-empty>
  events=()
  cycle_dir="$esc_dir"
  if [[ -n "$1" ]]; then
    approver_escalate "$URL" '["the same defect, unanswered"]' "$1"
  else
    approver_escalate "$URL" '["the same defect, unanswered"]'
  fi
  cycle_dir="$tmp_dir/cycle"
}
esc_body() { cat "$esc_dir/approver-escalation-${URL##*/}.md"; }
esc_why() { sed -n '/^## Why the pipeline is blocked$/,/^## What has already/p' "$esc_dir/approver-escalation-${URL##*/}.md"; }

run_escalate escalate
assert_contains "an escalate verdict's body says the adjudication judged it a judgement call" \
  "a genuine judgement call neither side is equipped to settle alone" "$(esc_why)"
assert_eq "  ... under the standing \"could not settle\" title" \
  "Approver adjudication could not settle $URL" "$(cat "$esc_dir/title")"

run_escalate recurring-refuse
assert_contains "a recurring refusal's body says the disagreement kept recurring" \
  "kept recurring across several adjudication rounds" "$(esc_why)"
assert_eq "  ... and does not claim the adjudication could not resolve it" "no" \
  "$([[ "$(esc_why)" == *"could not resolve the disagreement"* ]] && printf 'yes' || printf 'no')"
assert_eq "  ... under a title naming the recurrence, not \"could not settle\"" \
  "Approver adjudication: refusal keeps recurring on $URL" "$(cat "$esc_dir/title")"
assert_eq "  ... keeping the item ref create_escalation_issue dedups on unchanged" \
  "pr-${URL##*/}-approver-adjudication" "$(cat "$esc_dir/item-ref")"
assert_contains "  ... and still carrying the adjudication's own reasons" \
  "- the same defect, unanswered" "$(esc_body)"

run_escalate ""
assert_contains "a verdict the Script could not act on keeps the \"could not resolve\" wording" \
  "could not resolve the disagreement on its own" "$(esc_why)"
assert_eq "  ... and logs the filing as approver-escalated" "approver-escalated" \
  "$(printf '%s\n' "${events[0]%%$'\t'*}")"

# --- approver_escalation_retire (requirement 8c, agent-ops#1215) --------------
# The other half of `approver_escalate`'s own dedup lookup, read back: an open
# `enabler_escalation_label`-labelled issue whose body names this pull
# request's own `pr-<n>-approver-adjudication` reference is closed with a
# cause-specific comment — inside requirement 3f's own header/marker envelope
# — and an `approver-escalation-retired` event; no match, and a match somebody
# reopened, are both a no-op, logging nothing and never calling `gh issue
# close` at all.
ar_dir="$tmp_dir/escalation-retire"
mkdir -p "$ar_dir/cycle"
cat >"$ar_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1 $2" == "issue list" ]]; then
  cat "$d/issues.json" 2>/dev/null || echo '[]'
  exit 0
fi
if [[ "$1 $2" == "issue close" ]]; then
  number="$3"
  comment=""
  shift 3
  while (( $# )); do
    case "$1" in
      --comment) shift; comment="$1" ;;
    esac
    shift
  done
  if [[ -f "$d/close-fail" ]]; then
    exit 1
  fi
  printf 'number=%s\tcomment=%s\n' "$number" "$comment" >>"$d/closes"
  exit 0
fi
exit 1
STUB
chmod +x "$ar_dir/gh"
ar_reset() {  # <issues-json>
  printf '%s' "${1:-[]}" >"$ar_dir/issues.json"
  : >"$ar_dir/closes"; rm -f "$ar_dir/close-fail"
  events=()
}
ar_closes() { cat "$ar_dir/closes"; }
ar_closes_count() { wc -l <"$ar_dir/closes" 2>/dev/null | tr -d ' '; }

selected_repo="acme/widgets"
enabler_escalation_label="enabler-escalation"
cycle_dir="$ar_dir/cycle"
node_name="node-7"
cycle_id="20260906T221200Z-node-7-1"
APPROVER_GH="$ar_dir/gh"
AR_URL="https://github.com/acme/widgets/pull/77"

ar_reset '[]'
approver_escalation_retire "$AR_URL" land "abc123"
assert_eq "no matching open issue is a no-op" "0" "$(ar_closes_count)"
assert_eq "  ... and logs nothing at all" "0" "${#events[@]}"

ar_reset "$(jq -nc --arg body 'Item: `pr-77-approver-adjudication` · pull request …' \
  '[{number: 501, url: "https://github.com/acme/widgets/issues/501", body: $body}]')"
approver_escalation_retire "$AR_URL" land "abc123"
assert_contains "a matching open issue is closed, naming the right issue number" \
  "number=501" "$(ar_closes)"
assert_contains "  ... the land comment names the landing sha" "abc123" "$(ar_closes)"
# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
assert_contains "  ... opening with the visible pipeline header (requirement 3f)" \
  '**Script** · autonomous pipeline · node `node-7`' "$(ar_closes)"
assert_contains "  ... and closing with the invisible marker" \
  "$PIPELINE_COMMENT_MARKER_PREFIX cycle=$cycle_id actor=script -->" "$(ar_closes)"
assert_eq "  ... and logs exactly one event" "1" "${#events[@]}"
assert_eq "  ... as approver-escalation-retired" "approver-escalation-retired" "$(cut -f1 <<<"${events[0]}")"
retire_json="$(cut -f2- <<<"${events[0]}")"
assert_eq "  ... carrying the pull request url" "\"$AR_URL\"" "$(jq -c '.pr_url' <<<"$retire_json")"
assert_eq "  ... the issue number" "501" "$(jq -c '.issue_number' <<<"$retire_json")"
assert_eq "  ... and cause \"land\"" '"land"' "$(jq -c '.cause' <<<"$retire_json")"

ar_reset "$(jq -nc --arg body 'Item: `pr-77-approver-adjudication` · pull request …' \
  '[{number: 502, url: "https://github.com/acme/widgets/issues/502", body: $body}]')"
approver_escalation_retire "$AR_URL" merged "a-human at 2026-09-06T11:09:07Z"
assert_contains "the merged comment names who merged it and when" \
  "a-human at 2026-09-06T11:09:07Z" "$(ar_closes)"
assert_eq "  ... cause \"merged\"" '"merged"' \
  "$(jq -c '.cause' <<<"$(cut -f2- <<<"${events[0]}")")"

ar_reset "$(jq -nc --arg body 'Item: `pr-77-approver-adjudication` · pull request …' \
  '[{number: 503, url: "https://github.com/acme/widgets/issues/503", body: $body}]')"
touch "$ar_dir/close-fail"
approver_escalation_retire "$AR_URL" land "abc123"
assert_eq "a close GitHub refuses is not silently treated as retired" "0" \
  "$(ar_closes_count)"
assert_eq "  ... and logs a warning instead" "1" "${#events[@]}"
assert_eq "  ... never approver-escalation-retired" "warning" "$(cut -f1 <<<"${events[0]}")"

ar_reset "$(jq -nc \
  '[{number: 601, url: "https://github.com/acme/widgets/issues/601", body: "Item: `pr-99-approver-adjudication`"}]')"
approver_escalation_retire "$AR_URL" land "abc123"
assert_eq "an open issue for a different pull request is left alone" "0" \
  "$(ar_closes_count)"
assert_eq "  ... and logs nothing" "0" "${#events[@]}"

# A human's own re-open wins, the same answer requirement 34k's one-shot rule
# and scripts/sweep-closed-issues.sh's `state_reason: "reopened"` check give
# everywhere else this system closes something: without it, somebody who
# reopens a retired escalation has that undone the next time a retirement
# path runs, with a fresh comment each time.
ar_reset "$(jq -nc --arg body 'Item: `pr-77-approver-adjudication` · pull request …' \
  '[{number: 504, url: "https://github.com/acme/widgets/issues/504", body: $body,
     stateReason: "REOPENED"}]')"
approver_escalation_retire "$AR_URL" land "abc123"
assert_eq "an escalation a human reopened is left alone" "0" "$(ar_closes_count)"
assert_eq "  ... and logs nothing" "0" "${#events[@]}"

# --- Survives the caller's shell options ---------------------------------------
# agent-cycle.sh runs under `set -euo pipefail`; every call site captures
# these functions' output with `|| true`/`|| return 1` around it. A non-zero
# return escaping unexpectedly would abort the cycle at exactly the point it
# is trying to report a problem.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/approver.sh"
  # shellcheck disable=SC2030
  APPROVER_GH="/nonexistent/gh"
  x="$(approver_refuse_streak "$URL" "pullwright-approver[bot]")" || true
  [[ -z "$x" ]] || exit 9
  exit 0
) >/dev/null 2>&1
assert_eq "the real call-site shape survives set -e" "0" "$?"

echo
if (( failures == 0 )); then
  echo "All approver assertions passed."
else
  echo "$failures assertion(s) failed."
fi
exit "$failures"
