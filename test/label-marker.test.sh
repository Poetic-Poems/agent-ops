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
assert_eq "the map also carries every recorded add, not just the latest action" \
  '["2026-08-01T09:00:00Z"]' "$(jq -c '."o/r|5".adds' <<<"$nr_map")"

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

# --- label_own_stale_applications --------------------------------------------
# The complement of `label_filter_own_applications`, expressed in terms of it:
# exactly the entries that function drops are what a caller may safely retry
# `refinement_label_remove` on — requirement 39f's retry, not just its
# read-back.
stale="$(label_own_stale_applications "$candidates" "$stuck_map")"
assert_eq "the entry the filter dropped is the one this returns" "1" \
  "$(jq 'length' <<<"$stale")"
assert_eq "  ... naming the stuck item, not the untouched one" "52" \
  "$(jq -r '.[0].number' <<<"$stale")"
assert_eq "  ... with its gathered fields intact, for the caller to act on" \
  "warwick" "$(jq -r '.[0].by' <<<"$stale")"
assert_eq "the filter and its complement partition the list — nothing lost, nothing doubled" \
  "$(jq 'length' <<<"$candidates")" \
  "$(( $(jq 'length' <<<"$filtered") + $(jq 'length' <<<"$stale") ))"
assert_eq "an empty own map has nothing to retry" "[]" \
  "$(label_own_stale_applications "$candidates" '{}')"
assert_eq "a malformed own map has nothing to retry — the safe direction for a write" "[]" \
  "$(label_own_stale_applications "$candidates" 'not json')"
assert_eq "a malformed candidate list yields an empty array, never a crash" "[]" \
  "$(label_own_stale_applications 'not json' "$stuck_map")"
assert_eq "an empty candidate list stays empty" "[]" \
  "$(label_own_stale_applications '[]' "$stuck_map")"

# The blocked extract is the other half of the test, and the one that keeps
# this from undoing requirement 34e: the label the Script put on an item it
# blocked is its own last action too, but it is a live projection of that
# block, not a leftover, and removing it would take the human's only signal
# off the issue while the block still stands.
open_block='[{"repo":"o/r","item":"52","kind":"needs-refinement"}]'
assert_eq "a label whose block is still open is never retried" "[]" \
  "$(label_own_stale_applications "$candidates" "$stuck_map" "$open_block")"
assert_eq "  ... and once that block has cleared, the same label is retried" "52" \
  "$(jq -r '.[0].number' <<<"$(label_own_stale_applications "$candidates" "$stuck_map" '[]')")"
assert_eq "any open block disqualifies it, not only a refinement one" "[]" \
  "$(label_own_stale_applications "$candidates" "$stuck_map" \
       '[{"repo":"o/r","item":"52","kind":""}]')"
assert_eq "another item's block does not shield this one" "52" \
  "$(jq -r '.[0].number' <<<"$(label_own_stale_applications "$candidates" "$stuck_map" \
       '[{"repo":"o/r","item":"53","kind":"needs-refinement"}]')")"
assert_eq "another repo's identically-numbered block does not shield it either" "52" \
  "$(jq -r '.[0].number' <<<"$(label_own_stale_applications "$candidates" "$stuck_map" \
       '[{"repo":"o/other","item":"52","kind":"needs-refinement"}]')")"
assert_eq "a numeric item id in the blocked extract matches a numeric candidate" "[]" \
  "$(label_own_stale_applications "$candidates" "$stuck_map" \
       '[{"repo":"o/r","item":52,"kind":"needs-refinement"}]')"
assert_eq "a malformed blocked extract has nothing to retry — the safe direction for a write" "[]" \
  "$(label_own_stale_applications "$candidates" "$stuck_map" 'not json')"
assert_eq "an empty blocked argument reads as nothing blocked" "52" \
  "$(jq -r '.[0].number' <<<"$(label_own_stale_applications "$candidates" "$stuck_map" '')")"

# --- Grace period and skew tolerance (#526) ----------------------------------
# The fixtures above all stamp `own.ts` a second *after* `labelled_at`, which
# is the direction the pre-#526 exact-order comparison happened to work in.
# These are the three cases #526 found it missing: a node's clock running
# *behind* GitHub's (own.ts earlier than labelled_at, within tolerance), an
# add whose later recorded remove did not actually take, and an
# own-label-action record that has not propagated to the reading node yet.

fixed_now="2026-08-17T12:00:00Z"

# Skew: our own write is recorded a few seconds *behind* GitHub's own record
# of the same label add — the failing direction the pre-#526 comparison
# asserted nothing about.
skew_log="$tmp_dir/skew.jsonl"
printf '%s\n' '{"ts":"2026-08-17T11:00:00Z","event":"own-label-action","repo":"o/r","item":"60","label":"needs-refinement","action":"add"}' > "$skew_log"
skew_map="$(label_own_actions_map "needs-refinement" "$skew_log")"
if label_is_own_application "$skew_map" "o/r" "60" "2026-08-17T11:00:10Z" "$fixed_now"; then
  assert_eq "own.ts behind labelled_at by less than the skew tolerance is still ours" "yes" "yes"
else
  assert_eq "own.ts behind labelled_at by less than the skew tolerance is still ours" "yes" "no"
fi
if label_is_own_application "$skew_map" "o/r" "60" "2026-08-17T11:05:00Z" "$fixed_now"; then
  assert_eq "own.ts behind labelled_at by more than the skew tolerance is not ours" "no" "yes"
else
  assert_eq "own.ts behind labelled_at by more than the skew tolerance is not ours" "no" "no"
fi

# An add matching labelled_at, with a later remove recorded — #526 cause 2:
# the still-present label reads as ours despite the map's latest action
# being "remove", because a matching add exists somewhere in the record.
addremove_log="$tmp_dir/addremove.jsonl"
cat > "$addremove_log" <<'EOF'
{"ts":"2026-08-16T22:39:57Z","event":"own-label-action","repo":"o/r","item":"61","label":"needs-refinement","action":"add"}
{"ts":"2026-08-16T22:40:02Z","event":"own-label-action","repo":"o/r","item":"61","label":"needs-refinement","action":"remove"}
EOF
addremove_map="$(label_own_actions_map "needs-refinement" "$addremove_log")"
assert_eq "the latest recorded action is still remove" "remove" "$(jq -r '."o/r|61".action' <<<"$addremove_map")"
if label_is_own_application "$addremove_map" "o/r" "61" "2026-08-16T22:39:56Z" "$fixed_now"; then
  assert_eq "an add matching labelled_at is ours even with a later recorded remove" "yes" "yes"
else
  assert_eq "an add matching labelled_at is ours even with a later recorded remove" "yes" "no"
fi
addremove_candidates='[{"repo":"o/r","number":61,"label":"needs-refinement","state":"open","labelled_at":"2026-08-16T22:39:56Z","by":"warwick"}]'
assert_eq "  ... so the filter drops it rather than reporting it as a hand-flag" "0" \
  "$(jq 'length' <<<"$(label_filter_own_applications "$addremove_candidates" "$addremove_map" "$fixed_now")")"
assert_eq "  ... and it is offered back for the stale removal to retry" "61" \
  "$(jq -r '.[0].number' <<<"$(label_own_stale_applications "$addremove_candidates" "$addremove_map" '[]' "$fixed_now")")"

# Grace: no own record at all, but the label was applied recently enough that
# an unpropagated own-label-action record — not a human — is the likely
# explanation (#526 cause 1). Deferred: neither reported as a hand-flag nor
# offered up for a stale-removal retry.
grace_candidates='[{"repo":"o/r","number":62,"label":"needs-refinement","state":"open","labelled_at":"2026-08-17T11:45:00Z","by":"warwick"}]'
assert_eq "a label applied within the grace window, with no own record, is not reported as a hand-flag" "0" \
  "$(jq 'length' <<<"$(label_filter_own_applications "$grace_candidates" '{}' "$fixed_now")")"
assert_eq "  ... nor is it offered for stale removal" "0" \
  "$(jq 'length' <<<"$(label_own_stale_applications "$grace_candidates" '{}' '[]' "$fixed_now")")"
if label_is_own_application '{}' "o/r" "62" "2026-08-17T11:45:00Z" "$fixed_now"; then
  assert_eq "  ... and a deferred candidate is not reported as ours either" "no" "yes"
else
  assert_eq "  ... and a deferred candidate is not reported as ours either" "no" "no"
fi

# Past the grace window, with no own record, the pre-#526 hand-flag behaviour
# is unchanged (requirement 34g).
old_candidates='[{"repo":"o/r","number":63,"label":"needs-refinement","state":"open","labelled_at":"2026-08-17T11:00:00Z","by":"warwick"}]'
assert_eq "a label applied longer ago than the grace window, with no own record, is still reported as a hand-flag" "63" \
  "$(jq -r '.[0].number' <<<"$(label_filter_own_applications "$old_candidates" '{}' "$fixed_now")")"
assert_eq "  ... and is not offered for stale removal either, since it was never proven ours" "0" \
  "$(jq 'length' <<<"$(label_own_stale_applications "$old_candidates" '{}' '[]' "$fixed_now")")"

# --- log_latest_ts and the snapshot horizon (#670) ---------------------------
# The grace period above is only ever exercised with a hand-picked $fixed_now.
# In production that value is `union_log_horizon` — `log_latest_ts`'s own read
# of `$union_log`, captured once right after the snapshot is taken, before the
# cycle appends any of its own events into it — never wall clock. This section
# tests the extract itself, then replays agent-ops#598's own trace through it.

horizon_log="$tmp_dir/horizon.jsonl"
cat > "$horizon_log" <<'EOF'
{"ts":"2026-08-21T07:10:00Z","event":"stage-end","stage":"coordinator"}
{"ts":"2026-08-21T07:36:00Z","event":"stage-end","stage":"reviewer"}
{"ts":"2026-08-21T07:20:00Z","event":"warning","detail":"unrelated"}
EOF
assert_eq "log_latest_ts prints the newest ts across a mixed stream" \
  "2026-08-21T07:36:00Z" "$(log_latest_ts "$horizon_log")"
printf '%s\n' 'not json at all' >> "$horizon_log"
assert_eq "an unparseable trailing line is skipped, not fatal" \
  "2026-08-21T07:36:00Z" "$(log_latest_ts "$horizon_log")"
assert_eq "a missing log yields empty output" "" "$(log_latest_ts "$tmp_dir/nonexistent.jsonl")"
: > "$tmp_dir/empty.jsonl"
assert_eq "an empty log yields empty output" "" "$(log_latest_ts "$tmp_dir/empty.jsonl")"
assert_eq "reads stdin when no file is given, same as the map extracts above" \
  "2026-08-21T07:36:00Z" "$(log_latest_ts < "$horizon_log")"

# The agent-ops#598 replay: ockham-2's cycle snapshots `union_log` before
# poetic-1 — a peer node, mid its own concurrent cycle — applies the label and
# logs its own `own-label-action`, so the snapshot's own-actions map has no
# record of it at all. Measured against the snapshot's own horizon, the
# absence is exactly what "deferred" describes; measured against wall clock
# read back once the cycle has run long enough to clear the grace window, the
# identical absence reads as "not-ours" — the misattribution #670 closes.
replay_horizon="$(log_latest_ts "$tmp_dir/nonexistent.jsonl")"
[[ -z "$replay_horizon" ]] || assert_eq "sanity: nonexistent log has no horizon" "" "$replay_horizon"
replay_horizon="2026-08-21T07:36:00Z"
replay_own_map='{}'
replay_candidates='[{"repo":"o/r","number":598,"label":"needs-refinement","state":"open","labelled_at":"2026-08-21T07:41:25Z","by":"poetic-1"}]'

assert_eq "#598 replay: measured against the snapshot's own horizon, the peer's write is deferred, not a hand-flag" "0" \
  "$(jq 'length' <<<"$(label_filter_own_applications "$replay_candidates" "$replay_own_map" "$replay_horizon")")"
assert_eq "  ... and it is not offered up for stale removal either" "0" \
  "$(jq 'length' <<<"$(label_own_stale_applications "$replay_candidates" "$replay_own_map" '[]' "$replay_horizon")")"
assert_eq "  ... but the identical candidate against wall clock 36 minutes later reproduces the pre-#670 misattribution" "598" \
  "$(jq -r '.[0].number' <<<"$(label_filter_own_applications "$replay_candidates" "$replay_own_map" "2026-08-21T08:12:36Z")")"

# A negative age (labelled_at after NOW) must always classify deferred, never
# not-ours — pinned with a gap well past the grace window's own magnitude, so
# an `abs()` "simplification" of `own_class`'s `($now_epoch - $at_epoch) <
# $grace` test (which would read a 2-hour *future* label as a 2-hour-old one,
# and drop it as not-ours) cannot silently regress it.
future_now="2026-08-17T09:00:00Z"
future_labelled_at="2026-08-17T11:00:00Z"
if label_is_own_application '{}' "o/r" "70" "$future_labelled_at" "$future_now"; then
  assert_eq "a labelled_at two hours after NOW is still not reported as ours" "no" "yes"
else
  assert_eq "a labelled_at two hours after NOW is still not reported as ours" "no" "no"
fi
future_candidates='[{"repo":"o/r","number":70,"label":"needs-refinement","state":"open","labelled_at":"'"$future_labelled_at"'","by":"warwick"}]'
assert_eq "  ... and label_filter_own_applications drops it as deferred rather than keeping it as not-ours" "0" \
  "$(jq 'length' <<<"$(label_filter_own_applications "$future_candidates" '{}' "$future_now")")"

# --- The argv cap (requirement 4g) -------------------------------------------
# The own-actions map and the blocked extract both grow with the fleet's
# history, and past MAX_ARG_STRLEN (131072 bytes, the kernel's per-entry argv
# cap) an `--argjson` delivery made each of these calls fail into its own
# fallback. The two fallbacks point opposite ways by design — "not ours" here,
# "nothing to retry" below — so the cap did not merely disable the pair, it
# desynchronised them: the filter would stop dropping our own stuck write
# (re-manufacturing the block requirement 39f exists to prevent) while its
# complement stopped offering that same write for retry. Requirement 4g puts
# every one of these arrays on stdin; these pin it, with fixtures the size
# assertions prove are genuinely past the cap.
big_map="$(jq -nc --argjson m "$stuck_map" \
  '$m + ([range(3000) | {("o/filler|" + tostring):
     {action: "add", ts: "2026-08-01T09:00:00Z", label: "needs-refinement"}}] | add)')"
assert_eq "the oversized own-actions fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_map" | wc -c) > 131072 ))"
assert_eq "an own-actions map past the argv cap still drops our own application" "1" \
  "$(jq 'length' <<<"$(label_filter_own_applications "$candidates" "$big_map")")"
assert_eq "  ... leaving the candidate nobody recorded" "53" \
  "$(jq -r '.[0].number' <<<"$(label_filter_own_applications "$candidates" "$big_map")")"

big_blocked="$(jq -nc '[range(3000) | {repo: "o/filler", item: ("TD-fill-" + tostring),
  kind: "needs-refinement", detail: ("pad " + ("x" * 40))}]')"
assert_eq "the oversized blocked fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_blocked" | wc -c) > 131072 ))"
assert_eq "a blocked extract past the argv cap still names the stuck label to retry" "52" \
  "$(jq -r '.[0].number' <<<"$(label_own_stale_applications "$candidates" "$stuck_map" "$big_blocked")")"

# The call-site shape under `set -e`.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/label-marker.sh"
  a="$(label_own_actions_map "needs-refinement" "/nonexistent/log.jsonl")"
  b="$(label_own_actions_map "needs-refinement" "garbage-not-a-path-either")"
  label_is_own_application 'not json' "o/r" "5" "2026-08-01T09:00:00Z" || true
  c="$(label_filter_own_applications 'not json' 'not json')"
  d="$(label_own_stale_applications 'not json' 'not json')"
  e="$(label_own_stale_applications 'not json' 'not json' 'not json')"
  printf '%s%s%s' "$c" "$d" "$e" >/dev/null
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
