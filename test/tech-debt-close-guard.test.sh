#!/usr/bin/env bash
#
# test/tech-debt-close-guard.test.sh — regression tests for
# scripts/tech-debt-close-guard.sh (issue #877): the advisory check that a
# closed `pw::type:tech-debt` issue carries some evidence of its resolution.
#
# Behaviours asserted:
#
#   - **An issue with no `pw::type:tech-debt` label is skipped entirely** —
#     `gh` is never even called.
#   - **A `completed` close with a linked closing pull request or commit
#     (the issue's own timeline `closer`) needs nothing else** — no comment.
#   - **A `completed` close with no linked closer but a real comment already
#     on the issue needs nothing else** — no comment.
#   - **A `completed` close with neither draws exactly one guard comment.**
#   - **A `not_planned` close with a comment already present needs nothing
#     else**; with none, draws exactly one guard comment.
#   - **An empty/unset `state_reason` follows the `completed` rule** — GitHub's
#     own default.
#   - **The guard's own past comments never count as "a comment already
#     present"** — otherwise the first guarded close would silently satisfy
#     every later one.
#   - **A guard comment already posted for this exact close (same
#     `closed_at` marker) is not posted twice**; a *different* `closed_at`
#     (a later close of the same issue) is judged fresh.
#   - **Malformed arguments exit 2 without calling `gh`.**
#
# `gh` is stubbed through GH, matching the technique
# test/release-td-branch.test.sh's stub uses for its own `gh api` calls.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/tech-debt-close-guard.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$SCRIPT_DIR/scripts/tech-debt-close-guard.sh"

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
# $tmp_dir/comments.json    JSON array of {"body": "..."} the GET call returns
# $tmp_dir/graphql-answer   {"pr": N, "commit": bool} — the graphql call's answer
# $tmp_dir/post-fails       present (any content) => the POST call fails
# $tmp_dir/posted-bodies    every posted comment body, --- separated
# $tmp_dir/calls            every invocation's argv, one per line
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "$d/calls"

has_body_at=0 has_slurp=0 has_jq=0
for a in "$@"; do
  [[ "$a" == body=@* ]] && has_body_at=1
  [[ "$a" == "--slurp" ]] && has_slurp=1
  [[ "$a" == "--jq" || "$a" == "-q" ]] && has_jq=1
done

# The real binary refuses this pair (gh 2.98.0), exiting 1 with empty stdout —
# issue #1116, where a stub that accepted it kept two live call sites' silent
# failure invisible for as long as the suite was the only thing reading them.
if (( has_slurp && has_jq )); then
  echo 'the `--slurp` option is not supported with `--jq` or `--template`' >&2
  exit 1
fi

if [[ "$1" == "api" && "$has_body_at" == "1" ]]; then
  for a in "$@"; do
    if [[ "$a" == body=@* ]]; then
      f="${a#body=@}"
      cat "$f" >> "$d/posted-bodies" 2>/dev/null
      printf -- '\n---\n' >> "$d/posted-bodies"
    fi
  done
  [[ -f "$d/post-fails" ]] && exit 1
  echo '{}'
  exit 0
fi

if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  cat "$d/graphql-answer" 2>/dev/null || echo '{"pr":0,"commit":false}'
  exit 0
fi

if [[ "$1" == "api" && "$2" == *"/comments" ]]; then
  # Answer in `--slurp`'s own shape — an array *of pages*, each itself the
  # array of that page's comments — not the flat array a caller ultimately
  # wants. A stub that flattened on the caller's behalf would hide whichever
  # side of the pairing got it wrong.
  jq -c '[.]' "$d/comments.json" 2>/dev/null || echo '[[]]'
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/gh"

reset_stub() {
  : > "$tmp_dir/calls"
  rm -f "$tmp_dir/post-fails" "$tmp_dir/posted-bodies"
  echo '[]' > "$tmp_dir/comments.json"
  echo '{"pr":0,"commit":false}' > "$tmp_dir/graphql-answer"
}

comments_json() {  # comments_json BODY...
  local args=() b
  for b in "$@"; do
    args+=("$(jq -nc --arg b "$b" '{body:$b}')")
  done
  (( $# == 0 )) && { echo '[]' > "$tmp_dir/comments.json"; return; }
  jq -sc '.' <<<"$(printf '%s\n' "${args[@]}")" > "$tmp_dir/comments.json"
}

run() { GH="$tmp_dir/gh" "$GUARD" "$@"; }

DEFAULT_ARGS=("o/r" "5" "completed" "pw::type:tech-debt" "2026-09-07T10:00:00Z")

# --- Not labelled: skipped entirely, gh never called ------------------------
reset_stub
out="$(run "o/r" "5" "completed" "bug,enhancement" "2026-09-07T10:00:00Z")"; rc=$?
assert_eq "unlabelled: exit 0" "0" "$rc"
assert_eq "  ... action none" "none" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... gh never called" "" "$(cat "$tmp_dir/calls")"

# --- completed + linked PullRequest closer: nothing needed ------------------
reset_stub
echo '{"pr":1,"commit":false}' > "$tmp_dir/graphql-answer"
out="$(run "${DEFAULT_ARGS[@]}")"; rc=$?
assert_eq "linked PR closer: exit 0" "0" "$rc"
assert_eq "  ... action none" "none" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... no comment posted" "" "$(cat "$tmp_dir/posted-bodies" 2>/dev/null || true)"

# --- completed + linked Commit closer: nothing needed ------------------------
reset_stub
echo '{"pr":0,"commit":true}' > "$tmp_dir/graphql-answer"
out="$(run "${DEFAULT_ARGS[@]}")"; rc=$?
assert_eq "linked commit closer: exit 0" "0" "$rc"
assert_eq "  ... action none" "none" "$(jq -r '.action' <<<"$out")"

# --- completed + no closer + a real comment: nothing needed ------------------
reset_stub
comments_json "Fixed by hand, see the linked branch."
out="$(run "${DEFAULT_ARGS[@]}")"; rc=$?
assert_eq "real comment present: exit 0" "0" "$rc"
assert_eq "  ... action none" "none" "$(jq -r '.action' <<<"$out")"

# --- completed + no closer + no comments at all: guarded ---------------------
reset_stub
out="$(run "${DEFAULT_ARGS[@]}")"; rc=$?
assert_eq "nothing at all: exit 0" "0" "$rc"
assert_eq "  ... action commented" "commented" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... exactly one comment posted" "1" "$(grep -c '^---$' "$tmp_dir/posted-bodies")"
assert_eq "  ... comment carries the marker with this close's closed_at" "1" \
  "$(grep -cF '<!-- agent-ops:td-close-guard closed_at=2026-09-07T10:00:00Z -->' "$tmp_dir/posted-bodies")"

# --- The guard's own past comments never count as evidence -------------------
reset_stub
comments_json '<!-- agent-ops:td-close-guard closed_at=2026-01-01T00:00:00Z -->
This tech-debt issue was closed as completed with neither a linked pull request/commit nor a comment explaining the resolution.'
out="$(run "${DEFAULT_ARGS[@]}")"; rc=$?
assert_eq "only a past guard comment present: still guarded" "commented" "$(jq -r '.action' <<<"$out")"

# --- not_planned + a comment present: nothing needed --------------------------
reset_stub
comments_json "Not worth doing, superseded by #900."
out="$(run "o/r" "6" "not_planned" "pw::type:tech-debt" "2026-09-07T11:00:00Z")"; rc=$?
assert_eq "not_planned with comment: exit 0" "0" "$rc"
assert_eq "  ... action none" "none" "$(jq -r '.action' <<<"$out")"

# --- not_planned + no comment: guarded -----------------------------------------
reset_stub
out="$(run "o/r" "6" "not_planned" "pw::type:tech-debt" "2026-09-07T11:00:00Z")"; rc=$?
assert_eq "not_planned with no comment: guarded" "commented" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... reason names not planned" "not planned" "$(jq -r '.reason' <<<"$out" | grep -o 'not planned')"

# --- Empty state_reason follows the completed rule -----------------------------
reset_stub
out="$(run "o/r" "7" "" "pw::type:tech-debt" "2026-09-07T12:00:00Z")"; rc=$?
assert_eq "empty state_reason, nothing at all: guarded" "commented" "$(jq -r '.action' <<<"$out")"
reset_stub
echo '{"pr":1,"commit":false}' > "$tmp_dir/graphql-answer"
out="$(run "o/r" "7" "" "pw::type:tech-debt" "2026-09-07T12:00:00Z")"; rc=$?
assert_eq "empty state_reason, linked closer: exit 0, no comment" "none" "$(jq -r '.action' <<<"$out")"

# --- Idempotency: same close (same closed_at) never guarded twice --------------
reset_stub
comments_json "<!-- agent-ops:td-close-guard closed_at=2026-09-07T10:00:00Z -->
This tech-debt issue was closed as completed with neither a linked pull request/commit nor a comment explaining the resolution."
out="$(run "${DEFAULT_ARGS[@]}")"; rc=$?
assert_eq "already guarded this close: exit 0" "0" "$rc"
assert_eq "  ... action skipped" "skipped" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... no second comment posted" "" "$(cat "$tmp_dir/posted-bodies" 2>/dev/null || true)"

# --- A different closed_at (a later close of the same issue) is judged fresh --
reset_stub
comments_json "<!-- agent-ops:td-close-guard closed_at=2026-01-01T00:00:00Z -->
This tech-debt issue was closed as completed with neither a linked pull request/commit nor a comment explaining the resolution."
out="$(run "${DEFAULT_ARGS[@]}")"; rc=$?
assert_eq "a stale guard marker (different closed_at): guarded again" "commented" "$(jq -r '.action' <<<"$out")"

# --- A failed post reports a warning, still exits 0 -----------------------------
reset_stub
: > "$tmp_dir/post-fails"
out="$(run "${DEFAULT_ARGS[@]}")"; rc=$?
assert_eq "post fails: exit 0" "0" "$rc"
assert_eq "  ... action warning" "warning" "$(jq -r '.action' <<<"$out")"

# --- Malformed arguments: usage error, gh never called --------------------------
reset_stub
"$GUARD" "o/r" "not-a-number" "completed" "pw::type:tech-debt" "2026-01-01T00:00:00Z" >/dev/null 2>&1
assert_eq "non-numeric issue number: exit 2" "2" "$?"
"$GUARD" "o/r" "5" >/dev/null 2>&1
assert_eq "too few arguments: exit 2" "2" "$?"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
