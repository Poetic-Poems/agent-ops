#!/usr/bin/env bash
#
# test/label-marker.test.sh — regression test for the pipeline's own memory of
# the label actions it has taken (lib/label-marker.sh, requirement 39f).
#
# This is the counterpart to test/comment-identity.test.sh for the one write a
# comment marker cannot reach: a label carries no hidden text, so the memory
# lives in the shared log instead, and the whole point is telling the
# Script's own label writes apart from a human's without over-reaching into
# the wider "any touch of the label means something" mechanism
# lib/refinement.sh's own design note declines (TD26072602). Every case below
# is chosen to fail in the direction requirement 39f exists to close (a stuck
# label misread as a fresh human flag), never in the direction that would
# reopen the wider read-back.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/label-marker.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"

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

log="$tmp_dir/log.jsonl"

# --- label_own_action_fields -------------------------------------------------

assert_eq "the fields carry repo, item, label and action" \
  '{"repo":"o/r","item":"5","label":"needs-refinement","action":"add"}' \
  "$(label_own_action_fields "o/r" "5" "needs-refinement" "add")"
assert_eq "a numeric item is carried as a string, like every other item ref" \
  "5" "$(label_own_action_fields "o/r" 5 "refined" "remove" | jq -r '.item')"

# --- label_own_actions_map ----------------------------------------------------

cat > "$log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","event":"own-label-action","repo":"o/r","item":"5","label":"needs-refinement","action":"add"}
{"ts":"2026-08-01T10:00:00Z","event":"own-label-action","repo":"o/r","item":"6","label":"needs-refinement","action":"add"}
{"ts":"2026-08-01T11:00:00Z","event":"own-label-action","repo":"o/r","item":"5","label":"needs-refinement","action":"remove"}
{"ts":"2026-08-01T09:30:00Z","event":"own-label-action","repo":"o/r","item":"5","label":"refined","action":"add"}
{"ts":"2026-08-01T09:00:00Z","event":"own-label-action","repo":"o/other","item":"5","label":"needs-refinement","action":"add"}
EOF
nr_map="$(label_own_actions_map "needs-refinement" "$log")"
assert_eq "the latest action wins" "remove" "$(jq -r '."o/r|5".action' <<<"$nr_map")"
assert_eq "an item touched once keeps that action" "add" "$(jq -r '."o/r|6".action' <<<"$nr_map")"
assert_eq "a different label's action does not leak into this map" \
  "" "$(jq -r '."o/r|5".label // ""' <<<"$nr_map")"
assert_eq "the map is keyed by repo as well as item" "add" "$(jq -r '."o/other|5".action' <<<"$nr_map")"

refined_map="$(label_own_actions_map "refined" "$log")"
assert_eq "the refined label's own map is independent of needs-refinement's" \
  "add" "$(jq -r '."o/r|5".action' <<<"$refined_map")"

assert_eq "a missing log yields an empty map" "{}" "$(label_own_actions_map "refined" "$tmp_dir/nonexistent.jsonl")"
printf '%s' '{"ts":"2026-08-01T12:00:00Z","event":"own-label-a' >> "$log"
assert_eq "a malformed trailing line does not lose the map" "remove" \
  "$(label_own_actions_map "needs-refinement" "$log" | jq -r '."o/r|5".action')"

# --- label_is_own_application ------------------------------------------------
# The whole point: was the current presence of a label explained by the
# Script's own last write, or must it be a human's?

own_add="$(jq -nc '{action: "add", ts: "2026-08-01T09:00:00Z"}')"
own_remove="$(jq -nc '{action: "remove", ts: "2026-08-01T11:00:00Z"}')"
none='{}'

if label_is_own_application "$(jq -nc --argjson e "$own_add" '{"o/r|5": $e}')" "o/r" "5" "2026-08-01T09:00:00Z"; then
  assert_eq "our own add, no later GitHub timestamp, is ours" "yes" "yes"
else
  assert_eq "our own add, no later GitHub timestamp, is ours" "yes" "no"
fi

if label_is_own_application "$(jq -nc --argjson e "$own_add" '{"o/r|5": $e}')" "o/r" "5" "2026-08-02T09:00:00Z"; then
  assert_eq "a human's later re-application is not ours" "no" "yes"
else
  assert_eq "a human's later re-application is not ours" "no" "no"
fi

if label_is_own_application "$(jq -nc --argjson e "$own_remove" '{"o/r|5": $e}')" "o/r" "5" "2026-08-01T11:00:00Z"; then
  assert_eq "our last action was a remove, so a present label is not ours" "no" "yes"
else
  assert_eq "our last action was a remove, so a present label is not ours" "no" "no"
fi

if label_is_own_application "$(jq -nc --argjson e "$none" '{"o/r|5": $e}')" "o/r" "5" "2026-08-01T09:00:00Z"; then
  assert_eq "no own record at all is never ours" "no" "yes"
else
  assert_eq "no own record at all is never ours" "no" "no"
fi

if label_is_own_application "$(jq -nc --argjson e "$own_add" '{"o/r|5": $e}')" "o/r" "9" "2026-08-01T09:00:00Z"; then
  assert_eq "a different item's own record does not attach to this one" "no" "yes"
else
  assert_eq "a different item's own record does not attach to this one" "no" "no"
fi

if label_is_own_application "$(jq -nc --argjson e "$own_add" '{"o/r|5": $e}')" "o/r" "5" ""; then
  assert_eq "an empty GitHub timestamp resolves to not-ours, the safe direction" "no" "yes"
else
  assert_eq "an empty GitHub timestamp resolves to not-ours, the safe direction" "no" "no"
fi

# The scenario requirement 39f exists for: a block cleared, the label removal
# silently failed (so it is still present), and the next hand-flag scan must
# not manufacture a fresh block from the Script's own stuck write.
stuck_log="$tmp_dir/stuck.jsonl"
printf '%s\n' '{"ts":"2026-08-01T09:00:00Z","event":"own-label-action","repo":"o/r","item":"52","label":"needs-refinement","action":"add"}' > "$stuck_log"
stuck_map="$(label_own_actions_map "needs-refinement" "$stuck_log")"
own_entry="$(jq -c '."o/r|52" // {}' <<<"$stuck_map")"
if label_is_own_application "$stuck_map" "o/r" "52" "2026-08-01T09:00:00Z"; then
  assert_eq "a stuck label with no later human touch is attributed to the Script" "yes" "yes"
else
  assert_eq "a stuck label with no later human touch is attributed to the Script" "yes" "no"
fi
[[ -n "$own_entry" ]] || assert_eq "the own-action record for the stuck label exists" "non-empty" "empty"

# --- label_filter_own_applications -------------------------------------------
# The form `agent-cycle.sh` actually calls: a whole gathered candidate list,
# with the Script's own applications dropped and everything else preserved
# verbatim for `refinement_hand_flag_new` to judge.
candidates='[{"repo":"o/r","number":52,"label":"needs-refinement","state":"open","labelled_at":"2026-08-01T09:00:00Z","by":"warwick"},
             {"repo":"o/r","number":53,"label":"needs-refinement","state":"open","labelled_at":"2026-08-01T09:00:00Z","by":"warwick"}]'
filtered="$(label_filter_own_applications "$candidates" "$stuck_map")"
assert_eq "our own application is dropped from the candidate list" "1" \
  "$(jq 'length' <<<"$filtered")"
assert_eq "  ... and the candidate nobody recorded survives, verbatim" "53" \
  "$(jq -r '.[0].number' <<<"$filtered")"
assert_eq "  ... with its gathered fields untouched" "warwick" \
  "$(jq -r '.[0].by' <<<"$filtered")"
assert_eq "an empty own map drops nothing" "2" \
  "$(jq 'length' <<<"$(label_filter_own_applications "$candidates" '{}')")"
assert_eq "a malformed own map drops nothing — 'not ours' is the safe direction" "2" \
  "$(jq 'length' <<<"$(label_filter_own_applications "$candidates" 'not json')")"
assert_eq "a malformed candidate list yields an empty array, never a crash" "[]" \
  "$(label_filter_own_applications 'not json' "$stuck_map")"
assert_eq "an empty candidate list stays empty" "[]" \
  "$(label_filter_own_applications '[]' "$stuck_map")"

# The call-site shape under `set -e`.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/label-marker.sh"
  a="$(label_own_actions_map "needs-refinement" "/nonexistent/log.jsonl")"
  b="$(label_own_actions_map "needs-refinement" "garbage-not-a-path-either")"
  label_is_own_application 'not json' "o/r" "5" "2026-08-01T09:00:00Z" || true
  c="$(label_filter_own_applications 'not json' 'not json')"
  printf '%s' "$c" >/dev/null
  printf '%s%s' "$a" "$b" >/dev/null
  exit 0
) >/dev/null 2>&1
assert_eq "malformed input never aborts the caller under set -e" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
