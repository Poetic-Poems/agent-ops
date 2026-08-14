#!/usr/bin/env bash
#
# test/merge-queue.test.sh — regression test for lib/merge-queue.sh
# (agent-ops#374, D17).
#
# `merge_queue_probe` is the one place this repository reads GitHub's merge
# queue: whether a pull request is currently queued, and — since GitHub marks
# neither state nor field for "this used to be queued" — the most recent
# timeline event recording its removal, if any. Every assertion below is
# really one assertion: a caller must never read a failed or malformed probe
# as "definitely not queued", the one direction that would let a push evict a
# human's live queue entry.
#
# `gh` is stubbed through MERGE_QUEUE_GH; the stub applies the caller's own
# `--jq` filter to a fixture GraphQL response, the same technique
# test/sweep-human-visibility.test.sh's stub uses for its own `gh api` calls.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/merge-queue.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"

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

# --- The stub gh -------------------------------------------------------------
# $tmp_dir/response.json  the GraphQL response body, verbatim (the shape
#                          `gh api graphql` itself would hand to `--jq`)
# $tmp_dir/fail            present -> the call fails outright (network/auth)
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1 $2" == "api graphql" ]]; then
  [[ -f "$d/fail" ]] && exit 1
  jqfilter="" prev=""
  for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -c "$jqfilter" "$d/response.json" 2>/dev/null || exit 1
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"

# response ISINQUEUE [EVENT_CREATED_AT] [EVENT_REASON]
response() {
  local queued="$1" at="${2:-}" reason="${3:-}" nodes='[]'
  if [[ -n "$at" ]]; then
    nodes="$(jq -nc --arg at "$at" --arg r "$reason" '[{createdAt:$at, reason:$r}]')"
  fi
  jq -n --argjson q "$queued" --argjson nodes "$nodes" \
    '{data: {repository: {pullRequest: {isInMergeQueue: $q, timelineItems: {nodes: $nodes}}}}}' \
    > "$tmp_dir/response.json"
}

probe() { MERGE_QUEUE_GH="$tmp_dir/gh" merge_queue_probe "$@"; }

# --- Never queued -----------------------------------------------------------
response false
out="$(probe o/r 12)"; rc=$?
assert_eq "never-queued PR: exit 0" "0" "$rc"
assert_eq "  ... queued: false" "false" "$(jq -r '.queued' <<<"$out")"
assert_eq "  ... dequeued_at: null" "null" "$(jq -r '.dequeued_at' <<<"$out")"
assert_eq "  ... dequeue_reason: null" "null" "$(jq -r '.dequeue_reason' <<<"$out")"

# --- Currently queued --------------------------------------------------------
response true
out="$(probe o/r 12)"
assert_eq "currently-queued PR: queued true" "true" "$(jq -r '.queued' <<<"$out")"
assert_eq "  ... no dequeue event" "null" "$(jq -r '.dequeued_at' <<<"$out")"

# --- Dequeued: not queued, one removal event ---------------------------------
response false "2026-08-14T10:00:00Z" "CI_FAILURE"
out="$(probe o/r 12)"
assert_eq "dequeued PR: queued false" "false" "$(jq -r '.queued' <<<"$out")"
assert_eq "  ... dequeued_at carries the event's timestamp" "2026-08-14T10:00:00Z" \
  "$(jq -r '.dequeued_at' <<<"$out")"
assert_eq "  ... dequeue_reason carries the event's reason" "CI_FAILURE" \
  "$(jq -r '.dequeue_reason' <<<"$out")"

# --- Re-queued after an earlier dequeue: queued wins, event still reported --
# The caller's own job to gate on `queued == false`; this function reports
# both facts and lets the caller decide, so a re-enqueue at the same head does
# not silently lose the earlier event's timestamp.
response true "2026-08-14T09:00:00Z" "CI_FAILURE"
out="$(probe o/r 12)"
assert_eq "re-queued PR: queued true despite a past dequeue event" "true" \
  "$(jq -r '.queued' <<<"$out")"
assert_eq "  ... the past event is still reported" "2026-08-14T09:00:00Z" \
  "$(jq -r '.dequeued_at' <<<"$out")"

# --- A failed read is unknown, never "not queued" ----------------------------
response false
: > "$tmp_dir/fail"
out="$(probe o/r 12)"; rc=$?
assert_eq "a failed gh call: non-zero exit" "1" "$rc"
assert_eq "  ... and no output a caller could mistake for a real answer" "" "$out"
rm -f "$tmp_dir/fail"

# --- A malformed response is also unknown, never guessed at ------------------
printf '{"data":{}}' > "$tmp_dir/response.json"
out="$(probe o/r 12)"; rc=$?
assert_eq "a malformed response: non-zero exit" "1" "$rc"
assert_eq "  ... and no output" "" "$out"

# --- Bad arguments never reach gh at all -------------------------------------
response false
out="$(probe "" 12)"; rc=$?
assert_eq "an empty slug is rejected before calling gh" "1" "$rc"
assert_eq "  ... no output" "" "$out"

out="$(probe o/r "")"; rc=$?
assert_eq "an empty number is rejected before calling gh" "1" "$rc"

out="$(probe o/r abc)"; rc=$?
assert_eq "a non-numeric number is rejected before calling gh" "1" "$rc"

out="$(probe justowner 12)"; rc=$?
assert_eq "a slug with no '/' is rejected before calling gh" "1" "$rc"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
