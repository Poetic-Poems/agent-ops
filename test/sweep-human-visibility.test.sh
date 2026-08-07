#!/usr/bin/env bash
#
# test/sweep-human-visibility.test.sh — regression test for
# scripts/sweep-human-visibility.sh (requirement 38, agent-ops#242).
#
# The script is the periodic half of the human-visibility guarantee: for
# every open, ready pull request this system raised, whichever review request
# `lib/handoff.sh` would ensure at the moment of handoff (requirement 38a) is
# re-ensured here too, on a cycle that never touches that pull request through
# any stage — and an approved, mergeable, green pull request idle past
# `human_nudge_idle_hours` gets one nudge comment (requirement 38c), never a
# second one for the same approval.
#
# `gh` is stubbed through SWEEP_GH; the underlying `lib/handoff.sh` functions
# have their own dedicated regression test (test/handoff.test.sh) and are
# exercised only for the call shapes this script's own control flow depends
# on — not re-proven here.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/sweep-human-visibility.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$SCRIPT_DIR/scripts/sweep-human-visibility.sh"

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

# --- The config the sweep reads --------------------------------------------------
config="$tmp_dir/config.json"
write_config() {  # <enabler_assignee> <human_nudge_idle_hours>
  jq -n --arg a "$1" --argjson h "$2" \
    '{pr_label: "autonomous-agent", enabler_assignee: $a, human_nudge_idle_hours: $h}' \
    > "$config"
}
write_config warwickallen 24

URL="https://github.com/o/r/pull/1"

# --- The stub gh -------------------------------------------------------------
# State lives in files, the same shapes test/handoff.test.sh's stubs use, so a
# gh call the underlying lib/handoff.sh functions make is served identically.
#   $tmp_dir/prlist.json  the `gh pr list` payload, already the shape the real
#                          `--jq` filter would leave: a bare array of URLs
#   $tmp_dir/list-fail    present -> `pr list` fails
#   $tmp_dir/draft        "true" | "false" — the draft flag `pr view` reports
#   $tmp_dir/reviews      the reviews array, verbatim JSON
#   $tmp_dir/pending      the requested_reviewers logins, one per line
#   $tmp_dir/author       the pull request author's login
#   $tmp_dir/post-fail    present -> the POST changes nothing
#   $tmp_dir/api-fail     the path fragment whose GET should fail, if any
#   $tmp_dir/idle-view.json  the payload for the script's own idle-check
#                             `pr view --json reviewDecision,...` (no --jq)
#   $tmp_dir/view-fail    present -> that idle-check view fails
#   $tmp_dir/comment-fail present -> `pr comment` fails
#   $tmp_dir/posts        one line per POST
#   $tmp_dir/comments.log one paragraph per posted comment body
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr list" ]]; then
  [[ -f "$d/list-fail" ]] && exit 1
  jq -r '.[]' "$d/prlist.json"
  exit 0
fi

if [[ "$1 $2" == "pr view" ]]; then
  if [[ "$*" == *"isDraft"* ]]; then
    cat "$d/draft"
    exit 0
  fi
  [[ -f "$d/view-fail" ]] && exit 1
  cat "$d/idle-view.json"
  exit 0
fi

if [[ "$1 $2" == "pr comment" ]]; then
  [[ -f "$d/comment-fail" ]] && exit 1
  body=""
  shift 2
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body" ]]; then body="$2"; shift 2; else shift; fi
  done
  printf '%s\n===\n' "$body" >> "$d/comments.log"
  exit 0
fi

if [[ "$1 $2" == "api -X" ]]; then
  printf '%s\n' "$*" >> "$d/posts"
  if [[ ! -f "$d/post-fail" ]]; then
    for a in "$@"; do
      [[ "$a" == reviewers\[\]=* ]] && printf '%s\n' "${a#reviewers[]=}" >> "$d/pending"
    done
    sort -u -o "$d/pending" "$d/pending"
  fi
  exit 0
fi

path="$2"
fail="$(cat "$d/api-fail" 2>/dev/null || true)"
[[ -n "$fail" && "$path" == *"$fail" ]] && exit 1
if [[ "$path" == *"/reviews" ]]; then
  jq -c '.[] | select(.submitted_at != null)
             | {login: .user.login,
                bot: (((.user.type // "User") == "Bot") or (.user.login | endswith("[bot]"))),
                state: .state}' "$d/reviews"
elif [[ "$*" == *"user.login"* ]]; then
  cat "$d/author"
else
  while IFS= read -r l; do [[ -n "$l" ]] && printf '%s\n' "$l"; done < "$d/pending"
fi
STUB
chmod +x "$tmp_dir/gh"

review_n=0
review() {  # <login> <state> [type]
  printf '{"user":{"login":"%s","type":"%s"},"state":"%s","submitted_at":"2026-08-03T10:%02d:00Z"}' \
    "$1" "${3:-User}" "$2" "$(( ++review_n ))"
}
set_reviews() {
  review_n=0
  local IFS=,
  printf '[%s]' "$*" > "$tmp_dir/reviews"
}

comments() { cat "$tmp_dir/comments.log" 2>/dev/null || true; }
comment_count() {
  [[ -s "$tmp_dir/comments.log" ]] || { printf '0'; return; }
  grep -c '^===$' "$tmp_dir/comments.log"
}

# idle_view REVIEW_DECISION MERGEABLE CI_GREEN APPROVED_AT ALREADY_NUDGED
idle_view() {
  local decision="$1" mergeable="$2" green="$3" at="$4" nudged="$5"
  local rollup='[]'
  [[ "$green" == "yes" ]] && rollup='[{"conclusion":"SUCCESS"}]'
  [[ "$green" == "mixed" ]] && rollup='[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"}]'
  local comments='[]'
  [[ "$nudged" == "yes" ]] && comments='[{"body":"reminder\n\n<!-- agent-ops:human-nudge -->"}]'
  jq -n --arg d "$decision" --arg m "$mergeable" --argjson rollup "$rollup" \
    --arg at "$at" --argjson comments "$comments" \
    '{reviewDecision: $d, mergeable: $m, statusCheckRollup: $rollup,
      reviews: (if $at == "" then [] else [{state: "APPROVED", submittedAt: $at}] end),
      comments: $comments}' > "$tmp_dir/idle-view.json"
}

reset_stub() {
  printf '["%s"]\n' "$URL" > "$tmp_dir/prlist.json"
  printf 'false' > "$tmp_dir/draft"
  printf 'warwickallen\n' > "$tmp_dir/author"
  : > "$tmp_dir/pending"; : > "$tmp_dir/posts"; : > "$tmp_dir/comments.log"
  rm -f "$tmp_dir/api-fail" "$tmp_dir/post-fail" "$tmp_dir/list-fail" \
        "$tmp_dir/view-fail" "$tmp_dir/comment-fail"
  idle_view "" "" "" "" no
}

run_sweep() {
  SWEEP_GH="$tmp_dir/gh" AGENT_OPS_CONFIG="$config" bash "$SWEEP" o/r c1 node1
}

# --- No pull requests: costs one listing and nothing else -----------------------
write_config warwickallen 24
reset_stub
printf '[]\n' > "$tmp_dir/prlist.json"
out="$(run_sweep)"
assert_eq "no open pull requests produces no actions" "" "$out"

# --- enabler_assignee unset: the same silent no-op an Enabler disabled is -------
write_config "" 24
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
out="$(run_sweep)"
assert_eq "no enabler_assignee means nothing to request or nudge" "" "$out"
write_config warwickallen 24

# --- Still CHANGES_REQUESTED-blocked: left entirely alone -----------------------
# The sweep never calls confirm_review_requested (see the script's design
# note): it cannot judge whether the round has been answered, a premature
# re-request inverts the queue, and gather-review-feedback.sh would read the
# request event itself as the round having been answered. The blocked PR's
# next actor is the pipeline, not the human, so nothing is requested and
# nothing is nudged.
reset_stub
set_reviews "$(review Warwick-Allen CHANGES_REQUESTED)"
idle_view CHANGES_REQUESTED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a still-blocked PR is left entirely alone" "" "$out"
assert_eq "  ... no review request POSTed" "" "$(cat "$tmp_dir/posts")"
assert_eq "  ... no nudge comment posted" "0" "$(comment_count)"

# --- Approved, idle, and never re-asked: both halves fire together --------------
# ensure_human_reviewer re-requests the approver (nobody CHANGES_REQUESTED-
# blocking it), and because the PR is also approved+mergeable+green+idle with
# no nudge yet, the idle nudge fires in the same pass.
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an idle approved PR is both re-requested and nudged" \
  "$(printf 'human-review-requested\nnudged')" \
  "$(jq -r '.action' <<<"$out" | sort)"
assert_eq "  ... naming the approver as the review target" "Warwick-Allen" \
  "$(jq -r 'select(.action == "human-review-requested") | .reviewers[0]' <<<"$out")"
assert_eq "  ... naming the assignee as the nudge target" "warwickallen" \
  "$(jq -r 'select(.action == "nudged") | .reviewer' <<<"$out")"
assert_contains "the nudge comment carries the header and the marker" \
  "<!-- agent-ops:human-nudge -->" "$(comments)"
assert_contains "  ... and is stamped as this system's own write" \
  "<!-- agent-ops:pipeline-comment cycle=c1 actor=script -->" "$(comments)"
assert_contains "  ... visibly attributed" "**Script**" "$(comments)"
assert_eq "  ... exactly one comment posted" "1" "$(comment_count)"

# --- Already nudged: the marker makes it idempotent, not time-windowed ----------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" yes
out="$(run_sweep)"
assert_eq "a PR nudged once already is not nudged again" "" "$out"
assert_eq "  ... and posts no comment" "0" "$(comment_count)"

# --- Not idle long enough yet: no nudge, review request still self-heals --------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
idle_view APPROVED MERGEABLE yes "$(date -u +%Y-%m-%dT%H:%M:%SZ)" no
out="$(run_sweep)"
assert_eq "a freshly-approved PR is not nudged" "human-review-requested" \
  "$(jq -r '.action' <<<"$out")"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# --- Conflicting: never nudge a PR that is not actually mergeable ---------------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED CONFLICTING yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a conflicting PR is never nudged" "" "$out"

# --- Checks not all green: an empty or mixed rollup is never "green" ------------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE mixed "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "a mixed rollup is never nudged" "" "$out"

reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf 'Warwick-Allen\n' > "$tmp_dir/pending"
idle_view APPROVED MERGEABLE "" "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "an empty rollup (no checks run yet) is never nudged" "" "$out"

# --- human_nudge_idle_hours 0 disables the nudge, not the review request --------
write_config warwickallen 0
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
idle_view APPROVED MERGEABLE yes "2020-01-01T00:00:00Z" no
out="$(run_sweep)"
assert_eq "idle_hours 0 disables the nudge only" "human-review-requested" \
  "$(jq -r '.action' <<<"$out")"
write_config warwickallen 24

# --- Failures are warnings, never a silent "nothing to do" ----------------------
reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf '/reviews' > "$tmp_dir/api-fail"
out="$(run_sweep)"
assert_eq "an unreadable reviews list is a warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_contains "  ... naming the pull request" "$URL" "$(jq -r '.pr_url' <<<"$out")"

reset_stub
printf x > "$tmp_dir/list-fail"
out="$(run_sweep)"
assert_eq "an unreadable pull-request listing is a warning" "warning" "$(jq -r '.action' <<<"$out")"

reset_stub
set_reviews "$(review Warwick-Allen APPROVED)"
printf x > "$tmp_dir/view-fail"
out="$(run_sweep)"
assert_eq "an unreadable idle-check view is a warning, after the self-heal" \
  "human-review-requested" "$(jq -r 'select(.action != "warning") | .action' <<<"$out")"
assert_eq "  ... and a warning" "1" \
  "$(jq -r 'select(.action == "warning") | .action' <<<"$out" | wc -l | tr -d ' ')"

# --- Usage error: no repo argument ----------------------------------------------
out="$(SWEEP_GH="$tmp_dir/gh" AGENT_OPS_CONFIG="$config" bash "$SWEEP" 2>&1)"; rc=$?
assert_eq "no repo argument is a usage error" "64" "$rc"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
