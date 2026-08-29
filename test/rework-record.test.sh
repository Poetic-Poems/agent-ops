#!/usr/bin/env bash
#
# test/rework-record.test.sh — self-contained regression test for
# lib/rework.sh (docs/FLOW-SCHEMA.md, requirement 47 of
# docs/IMPLEMENTATION-PIPELINE-SPEC.md, issue #596).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/rework-record.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# rework_stage_rerun_maybe is the one function under test that calls
# log_event itself — every other function only prints fields, which the
# assertions below read straight off stdout. A minimal stand-in, matching
# agent-cycle.sh's own envelope shape closely enough for this test's purpose,
# appends to $log_capture rather than a real log file.
log_capture="$(mktemp)"
log_event() {
  local event="$1" fields="${2:-{\}}"
  jq -nc --arg event "$event" --argjson fields "$fields" '{event: $event} + $fields' \
    >> "$log_capture"
}

# shellcheck source=lib/rework.sh
. "$SCRIPT_DIR/lib/rework.sh"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir" "$log_capture"' EXIT

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

assert_empty() {
  local desc="$1" actual="$2"
  assert_eq "$desc" "" "$actual"
}

# =====================================================================
# rework_fields — the shared shaping function every class builds on
# =====================================================================

assert_eq "rework_fields: a well-formed call carries class/detector/evidence" \
  '{"attributed_stage":null,"class":"check-failure","detector":"agent-cycle.sh:review-gate-checks-read","evidence":{"ok":false}}' \
  "$(rework_fields "check-failure" "agent-cycle.sh:review-gate-checks-read" '{"ok":false}' | jq -Sc .)"

assert_eq "rework_fields: an unparseable evidence argument degrades to evidence: null, not a failed call" \
  'null' \
  "$(rework_fields "check-failure" "det" 'not json' | jq -c '.evidence')"

assert_eq "rework_fields: an omitted attributed_stage is JSON null, never a guessed string" \
  'null' \
  "$(rework_fields "check-failure" "det" '{}' | jq -c '.attributed_stage')"

assert_eq "rework_fields: a supplied attributed_stage is carried verbatim" \
  '"reviewer"' \
  "$(rework_fields "human-change-request" "det" '{}' "reviewer" | jq -c '.attributed_stage')"

assert_eq "rework_fields: repo/item/pr_url are omitted, not null, when not given" \
  'false' \
  "$(rework_fields "check-failure" "det" '{}' | jq -c 'has("repo") or has("item") or has("pr_url")')"

assert_eq "rework_fields: repo/item/pr_url are carried verbatim when given" \
  '{"item":"42","pr_url":"https://github.com/o/r/pull/1","repo":"o/r"}' \
  "$(rework_fields "check-failure" "det" '{}' "" "o/r" "42" "https://github.com/o/r/pull/1" \
     | jq -Sc '{repo, item, pr_url}')"

# =====================================================================
# review-round-trip / merge-conflict / abandoned-draft-resumed —
# rework_selection_fields, driven by a canned candidate/work-order
# =====================================================================

review_wo='{"source":"review-feedback","repo":"o/r","item":"TD1","pr_url":"https://github.com/o/r/pull/9",
  "ref":"pr-9-review-123","head_sha":"abc123","reviewed_at":"2026-08-01T00:00:00Z"}'
assert_eq "review-feedback selection earns class review-round-trip" \
  '"review-round-trip"' "$(rework_selection_fields "$review_wo" | jq -c '.class')"
assert_eq "review-feedback selection: detector names the gatherer" \
  '"scripts/gather-review-feedback.sh"' "$(rework_selection_fields "$review_wo" | jq -c '.detector')"
assert_eq "review-feedback selection: attributed_stage is null (not arbitrated)" \
  'null' "$(rework_selection_fields "$review_wo" | jq -c '.attributed_stage')"
assert_eq "review-feedback selection: evidence carries the candidate's own ref/head_sha/reviewed_at" \
  '{"head_sha":"abc123","ref":"pr-9-review-123","reviewed_at":"2026-08-01T00:00:00Z"}' \
  "$(rework_selection_fields "$review_wo" | jq -Sc '.evidence')"
assert_eq "review-feedback selection: repo/item/pr_url carried" \
  '{"item":"TD1","pr_url":"https://github.com/o/r/pull/9","repo":"o/r"}' \
  "$(rework_selection_fields "$review_wo" | jq -Sc '{repo, item, pr_url}')"

conflict_wo='{"source":"merge-conflicts","repo":"o/r","item":"TD2","pr_url":"https://github.com/o/r/pull/10",
  "ref":"pr-10-conflict-abc","base":"main"}'
assert_eq "merge-conflicts selection earns class merge-conflict" \
  '"merge-conflict"' "$(rework_selection_fields "$conflict_wo" | jq -c '.class')"

draft_wo='{"source":"abandoned-drafts","repo":"o/r","item":"TD3","pr_url":"https://github.com/o/r/pull/11",
  "ref":"pr-11-abandoned-abc","updated_at":"2026-08-01T00:00:00Z"}'
assert_eq "abandoned-drafts selection earns class abandoned-draft-resumed" \
  '"abandoned-draft-resumed"' "$(rework_selection_fields "$draft_wo" | jq -c '.class')"

assert_empty "a dequeued selection earns no rework class (not one of the nine)" \
  "$(rework_selection_fields '{"source":"dequeued","repo":"o/r","item":"1"}')"
assert_empty "an ordinary tech-debt selection earns no rework class" \
  "$(rework_selection_fields '{"source":"tech_debt","repo":"o/r","item":"TD1"}')"

# =====================================================================
# check-failure — review-gate-checks-read {ok: false}, and the
# review-gate-checks-degraded non-counting rule
# =====================================================================

assert_eq "check-failure fires when ok is false" \
  '"check-failure"' \
  "$(rework_check_failure_fields "false" "checks unreadable" "o/r" "TD1" "https://github.com/o/r/pull/1" | jq -c '.class')"
assert_empty "check-failure does not fire when ok is true (the ordinary case)" \
  "$(rework_check_failure_fields "true" "" "o/r" "TD1")"
# review-gate-checks-degraded is a different event with no call site into
# lib/rework.sh at all — there is nothing to drive here beyond confirming
# rework_check_failure_fields is the *only* function this class's detector
# calls, which the wiring above (agent-cycle.sh) rather than this pure
# function establishes; asserted structurally by grep below instead.
if grep -q 'rework_check_failure_fields' "$SCRIPT_DIR/agent-cycle.sh" \
   && ! grep -B2 'review-gate-checks-degraded' "$SCRIPT_DIR/agent-cycle.sh" | grep -q 'rework_'; then
  printf 'ok   - %s\n' "review-gate-checks-degraded's own log_event site calls no rework function"
else
  printf 'FAIL - %s\n' "review-gate-checks-degraded's own log_event site calls no rework function"
  failures=$(( failures + 1 ))
fi

# =====================================================================
# human-change-request — always attributed to reviewer
# =====================================================================

assert_eq "human-change-request is always attributed to reviewer" \
  '"reviewer"' \
  "$(rework_human_change_request_fields "unreconciled comment" "o/r" "TD1" "https://github.com/o/r/pull/1" | jq -c '.attributed_stage')"
assert_eq "human-change-request: detector names the reconciliation gate" \
  '"lib/reconciliation-gate.sh:reconciliation_gate"' \
  "$(rework_human_change_request_fields "reason" "o/r" "TD1" "" | jq -c '.detector')"

# =====================================================================
# claim-race-duplicate — only held/pr-held, never a bare miss
# =====================================================================

assert_eq "claim-lost cause held fires claim-race-duplicate" \
  '"claim-race-duplicate"' \
  "$(rework_claim_race_duplicate_fields "held" "3" "o/r" "TD1" | jq -c '.class')"
assert_eq "claim-lost cause pr-held fires claim-race-duplicate" \
  '"claim-race-duplicate"' \
  "$(rework_claim_race_duplicate_fields "pr-held" "3" "o/r" "TD1" | jq -c '.class')"
assert_empty "claim-lost cause unreachable does not fire (an outage, not contention)" \
  "$(rework_claim_race_duplicate_fields "unreachable" "1" "o/r" "TD1")"
assert_empty "claim-lost with no cause at all does not fire (excluded, not guessed)" \
  "$(rework_claim_race_duplicate_fields "" "1" "o/r" "TD1")"
assert_empty "claim-lost with an ordinary rc-as-cause does not fire" \
  "$(rework_claim_race_duplicate_fields "2" "2" "o/r" "TD1")"

# =====================================================================
# stage-rerun — kill_reason, and the crash-loop-escalated sibling
# =====================================================================

rework_stage_rerun_maybe "implementer" "" "o/r" "TD1"
assert_eq "stage-rerun: an empty kill_reason logs nothing" "0" "$(wc -l < "$log_capture")"

rework_stage_rerun_maybe "implementer" "backstop-timeout" "o/r" "TD1" "https://github.com/o/r/pull/1"
assert_eq "stage-rerun: a non-empty kill_reason logs one rework event" "1" "$(wc -l < "$log_capture")"
last_rework="$(tail -n1 "$log_capture")"
assert_eq "stage-rerun: event is 'rework'" '"rework"' "$(jq -c '.event' <<<"$last_rework")"
assert_eq "stage-rerun: class is stage-rerun" '"stage-rerun"' "$(jq -c '.class' <<<"$last_rework")"
assert_eq "stage-rerun: attributed_stage is the killed stage itself" \
  '"implementer"' "$(jq -c '.attributed_stage' <<<"$last_rework")"
assert_eq "stage-rerun: evidence carries the kill_reason" \
  '"backstop-timeout"' "$(jq -c '.evidence.kill_reason' <<<"$last_rework")"

crash_verdict='{"stage":"coordinator","detail":"coordinator exited 126","count":5,
  "first_ts":"2026-08-01T00:00:00Z","last_ts":"2026-08-01T05:00:00Z","nodes":["a","b"]}'
assert_eq "crash-loop escalation: class is stage-rerun (the same class, its other detector)" \
  '"stage-rerun"' "$(rework_crash_loop_fields "$crash_verdict" | jq -c '.class')"
assert_eq "crash-loop escalation: attributed_stage is the verdict's own stage" \
  '"coordinator"' "$(rework_crash_loop_fields "$crash_verdict" | jq -c '.attributed_stage')"
assert_eq "crash-loop escalation: no repo/item (fleet-wide)" \
  'false' "$(rework_crash_loop_fields "$crash_verdict" | jq -c 'has("repo") or has("item")')"
assert_eq "crash-loop escalation: evidence carries the whole verdict, count included" \
  "5" "$(rework_crash_loop_fields "$crash_verdict" | jq -c '.evidence.count')"

preselection_verdict='{"stage":"pre-selection","detail":"cycle exited 1 before any stage started",
  "count":3,"first_ts":"2026-08-01T00:00:00Z","last_ts":"2026-08-01T02:00:00Z","nodes":["a"]}'
assert_eq "crash-loop escalation: pre-selection verdicts attribute to pre-selection, not a guess" \
  '"pre-selection"' "$(rework_crash_loop_fields "$preselection_verdict" | jq -c '.attributed_stage')"

# =====================================================================
# refinement-bounce-back — a fresh block on an already-refined item
# =====================================================================

refined_map='{"o/r":{"TD1":{"ts":"2026-07-01T00:00:00Z"}}}'
assert_eq "a fresh block on an item refinements_json already shows refined bounces back" \
  '"refinement-bounce-back"' \
  "$(rework_refinement_bounce_back_fields "o/r" "TD1" "still unclear" "coordinator" "$refined_map" | jq -c '.class')"
assert_eq "refinement-bounce-back: evidence names the reporting stage" \
  '"coordinator"' \
  "$(rework_refinement_bounce_back_fields "o/r" "TD1" "still unclear" "coordinator" "$refined_map" | jq -c '.evidence.reported_by')"
assert_empty "a fresh block on an item never refined does not bounce back" \
  "$(rework_refinement_bounce_back_fields "o/r" "TD9" "reason" "coordinator" "$refined_map")"
assert_empty "a fresh block in a different repo with the same item id does not bounce back" \
  "$(rework_refinement_bounce_back_fields "o/other" "TD1" "reason" "coordinator" "$refined_map")"

# =====================================================================
# post-merge-revert — one entry per mine-merge-history.sh outcome
# =====================================================================

revert_entry='{"number":57,"kind":"revert","reason":"reference","by":60,"by_title":"Revert \"fix: x\"","hours_after":3.5}'
assert_eq "post-merge-revert: class and pr_url derived from slug+number" \
  '{"class":"post-merge-revert","item":"57","pr_url":"https://github.com/o/r/pull/57","repo":"o/r"}' \
  "$(rework_post_merge_revert_fields "o/r" "$revert_entry" | jq -Sc '{class, repo, item, pr_url}')"
assert_eq "post-merge-revert: evidence carries kind/reason/by/by_title/hours_after" \
  '{"by":60,"by_title":"Revert \"fix: x\"","hours_after":3.5,"kind":"revert","reason":"reference"}' \
  "$(rework_post_merge_revert_fields "o/r" "$revert_entry" | jq -Sc '.evidence')"

followup_entry='{"number":58,"kind":"follow-up-fix","reason":"file-overlap","by":61,"by_title":"fix: y","hours_after":10}'
assert_eq "post-merge-revert: a follow-up-fix entry is still class post-merge-revert (one class, two kinds)" \
  '"post-merge-revert"' "$(rework_post_merge_revert_fields "o/r" "$followup_entry" | jq -c '.class')"

# =====================================================================
# Degradations: a malformed event in a stream must never be fatal
# =====================================================================

malformed_stream="$work_dir/malformed.jsonl"
cat > "$malformed_stream" <<'JSONL'
{"event":"claim-lost","repo":"o/r","item":"TD1","cause":"held","rc":3}
not even json
{"event":"claim-lost","repo":"o/r","item":"TD2","cause":"pr-held","rc":3}
JSONL
# The same "skip a torn line, never fail the reduction" discipline
# lib/crash-loop.sh's own readers keep (`fromjson? // empty`); this is what
# a caller processing a stream of claim-lost events, rather than one call at
# a time, would apply before calling rework_claim_race_duplicate_fields.
recovered=0
while IFS= read -r line; do
  parsed="$(jq -c 'select(length > 0)' <<<"$line" 2>/dev/null)" || continue
  [[ -n "$parsed" ]] || continue
  cause="$(jq -r '.cause // ""' <<<"$parsed")"
  fields="$(rework_claim_race_duplicate_fields "$cause" "$(jq -r '.rc // ""' <<<"$parsed")" \
    "$(jq -r '.repo // ""' <<<"$parsed")" "$(jq -r '.item // ""' <<<"$parsed")")"
  [[ -n "$fields" ]] && recovered=$(( recovered + 1 ))
done < "$malformed_stream"
assert_eq "a malformed line in the stream is skipped, never fatal — both well-formed entries still recovered" \
  "2" "$recovered"

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed.\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed.\n'
