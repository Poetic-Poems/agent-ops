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

# shellcheck source=lib/approver.sh
. "$SCRIPT_DIR/lib/approver.sh"

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
  exit 1
fi
if [[ "$1 $2" == "api -X" ]]; then
  # api -X POST repos/<slug>/pulls/<n>/reviews -f event=<e> -f body=<b>
  event=""
  body=""
  shift 3
  while (( $# )); do
    case "$1" in
      -f) shift; case "$1" in event=*) event="${1#event=}" ;; body=*) body="${1#body=}" ;; esac ;;
    esac
    shift
  done
  printf 'token=%s\tevent=%s\tbody=%s\n' "${GH_TOKEN:-}" "$event" "$body" >>"$d/posts"
  exit 0
fi
# A GET against .../reviews. `gh api --jq` takes one query string with no
# `--arg` of its own, so — matching the real functions — neither call filters
# by login here; that happens in the real, un-stubbed second `jq --arg`
# call each function pipes this output through. The two callers ask for
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
reset_stub() {
  : >"$tmp_dir/posts"; : >"$tmp_dir/api-fail"
}
posts() { wc -l <"$tmp_dir/posts" | tr -d ' '; }

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
