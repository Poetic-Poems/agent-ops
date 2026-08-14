#!/usr/bin/env bash
#
# test/nudge-dependabot-rebase.test.sh — regression test for
# scripts/nudge-dependabot-rebase.sh (requirement 3s, issue #250).
#
# The script is the write half of Dependabot-conflict handling: for every
# candidate gather-merge-conflicts.sh reported as a first-sighting Dependabot
# conflict (`bot: true`, `rebase_requested: false`, no `superseded_by`), it
# posts `@dependabot rebase` and drops that candidate from the array handed
# back — nothing selectable this cycle — so the takeover path
# (prompts/coordinator.md) only ever fires once Dependabot has already had a
# full cycle to rebase on its own.
#
# `gh` is stubbed through NUDGE_GH.
#
# Run directly:
#
#   ./test/nudge-dependabot-rebase.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NUDGE="$SCRIPT_DIR/scripts/nudge-dependabot-rebase.sh"

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

# --- The stub gh ---
#   $tmp_dir/comment-fail   present -> every `pr comment` fails
#   $tmp_dir/comments.log   one paragraph per posted comment body, prefixed
#                           with the PR url it was posted to
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1 $2" == "pr comment" ]]; then
  [[ -f "$d/comment-fail" ]] && exit 1
  url="$3"
  body=""
  shift 3
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--body" ]]; then body="$2"; shift 2; else shift; fi
  done
  printf '%s\n%s\n===\n' "$url" "$body" >> "$d/comments.log"
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"

reset_stub() {
  rm -f "$tmp_dir/comment-fail"
  : > "$tmp_dir/comments.log"
}

comments() { cat "$tmp_dir/comments.log" 2>/dev/null || true; }
comment_count() {
  [[ -s "$tmp_dir/comments.log" ]] || { printf '0'; return; }
  grep -c '^===$' "$tmp_dir/comments.log"
}

run_nudge() {  # <candidates-json>
  printf '%s' "$1" | NUDGE_GH="$tmp_dir/gh" bash "$NUDGE" o/r c1 node1
}

cand() {  # <number> <bot> <rebase_requested> <superseded_by-or-empty>
  jq -nc --argjson n "$1" --argjson bot "$2" --argjson rr "$3" --arg sb "$4" \
    --arg sha "$(printf 'a%.0s' {1..16})" --arg url "https://github.com/o/r/pull/$1" \
    '{number: $n, url: $url, head_sha: $sha, bot: $bot, rebase_requested: $rr,
      superseded_by: (if $sb == "" then null else ($sb | tonumber) end)}'
}
ours() {  # <number> — one of our own (non-bot) candidates
  jq -nc --argjson n "$1" '{number: $n, url: ("https://github.com/o/r/pull/" + ($n|tostring)), bot: false}'
}

# --- A first-sighting bot conflict is nudged and dropped from the output ---
reset_stub
c1="$(cand 129 true false "")"
out="$(run_nudge "[$c1]")"
assert_eq "the freshly-nudged candidate is dropped from conflicts" \
  "[]" "$(jq -c '.conflicts' <<<"$out")"
assert_eq "  ... and recorded as a requested action" \
  '[{"number":129,"outcome":"requested"}]' "$(jq -c '.actions' <<<"$out")"
assert_eq "  ... exactly one comment posted" "1" "$(comment_count)"
assert_contains "  ... to the right PR" "https://github.com/o/r/pull/129" "$(comments)"
assert_contains "  ... asking Dependabot to rebase" "@dependabot rebase" "$(comments)"
assert_contains "  ... carrying the head-scoped marker" \
  "<!-- agent-ops:dependabot-rebase-requested head=aaaaaaaaaaaa -->" "$(comments)"
assert_contains "  ... attributed to this system" "**Script**" "$(comments)"
assert_contains "  ... and stamped as this cycle's own write" \
  "<!-- agent-ops:pipeline-comment cycle=c1 actor=script -->" "$(comments)"

# --- Already nudged (rebase_requested: true): passes through, no re-nudge ---
reset_stub
c2="$(cand 130 true true "")"
out="$(run_nudge "[$c2]")"
assert_eq "an already-nudged candidate passes through unchanged" \
  "[$c2]" "$(jq -c '.conflicts' <<<"$out")"
assert_eq "  ... and nothing is nudged again" "[]" "$(jq -c '.actions' <<<"$out")"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# --- Superseded: never nudged, even on a first sighting ---
reset_stub
c3="$(cand 131 true false 999)"
out="$(run_nudge "[$c3]")"
assert_eq "a superseded candidate passes through untouched" \
  "[$c3]" "$(jq -c '.conflicts' <<<"$out")"
assert_eq "  ... it is not nudged — the Co-Ordinator will void it instead" \
  "[]" "$(jq -c '.actions' <<<"$out")"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# --- Our own (non-bot) candidates are untouched ---
reset_stub
c4="$(ours 90)"
out="$(run_nudge "[$c4]")"
assert_eq "a non-bot candidate passes through untouched" "[$c4]" "$(jq -c '.conflicts' <<<"$out")"
assert_eq "  ... and is never nudged" "[]" "$(jq -c '.actions' <<<"$out")"
assert_eq "  ... no comment posted" "0" "$(comment_count)"

# --- A mixed batch: only the eligible one is nudged, the rest pass through ---
reset_stub
out="$(run_nudge "[$c1, $c2, $c3, $c4]")"
assert_eq "only the first-sighting bot candidate is dropped" \
  "3" "$(jq '.conflicts | length' <<<"$out")"
assert_eq "  ... and it alone was nudged" "129" "$(jq -r '.actions[0].number' <<<"$out")"
assert_eq "  ... exactly one comment posted across the whole batch" "1" "$(comment_count)"

# --- A failed post: recorded as failed, still dropped from conflicts (there
# is nothing selectable for it either way, and the next cycle retries it) ---
reset_stub
printf x > "$tmp_dir/comment-fail"
out="$(run_nudge "[$c1]")"
assert_eq "a failed nudge is recorded as failed" \
  '[{"number":129,"outcome":"failed"}]' "$(jq -c '.actions' <<<"$out")"
assert_eq "  ... and the candidate still carries no selectable work this cycle" \
  "[]" "$(jq -c '.conflicts' <<<"$out")"

# --- Fails safe on bad input ---
reset_stub
out="$(printf 'not json' | NUDGE_GH="$tmp_dir/gh" bash "$NUDGE" o/r c1 node1)"
assert_eq "unreadable stdin yields empty conflicts and actions" \
  '{"conflicts":[],"actions":[]}' "$(jq -c . <<<"$out")"

# --- Usage error ---
out="$(NUDGE_GH="$tmp_dir/gh" bash "$NUDGE" 2>&1)"; rc=$?
assert_eq "missing arguments is a usage error" "64" "$rc"

# --- The argv cap (requirement 4g, TD-PPagop-26081406) ---
#
# The `conflicts` accumulator — every skipped candidate's whole pull-request
# body, the same shape gather-merge-conflicts.sh's own candidate build
# carries — used to ride into jq as --argjson, both at the per-candidate fold
# and the final `{conflicts, actions}` build. Past MAX_ARG_STRLEN (131072
# bytes) the build died at execve and this repo's whole merge_conflicts band
# was lost. Requirement 4g moves it onto stdin; this drives the real script
# (stdin already, so no CLI-argv confound) over enough already-nudged
# candidates, each padded with a large body, to push the accumulator past
# the cap well before the last one.
reset_stub
big_cands="$(jq -nc \
  '[range(20) | {number: (200 + .), url: ("https://github.com/o/r/pull/" + ((200 + .) | tostring)),
                 head_sha: "bbbbbbbbbbbbbbbbbbbb", bot: true, rebase_requested: true,
                 superseded_by: null, body: ("pad " + ("x" * 8000))}]')"
assert_eq "the oversized candidates fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_cands" | wc -c) > 131072 ))"
out="$(run_nudge "$big_cands")"
assert_eq "an accumulator of already-nudged candidates past the argv cap still passes every one through" \
  "20" "$(jq '.conflicts | length' <<<"$out")"
assert_eq "  ... none nudged again" "[]" "$(jq -c '.actions' <<<"$out")"
assert_eq "  ... no comment posted" "0" "$(comment_count)"
assert_eq "  ... and the first candidate's own padded body survives intact" \
  "1" "$(jq '[.conflicts[] | select(.number == 200)] | length' <<<"$out")"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
