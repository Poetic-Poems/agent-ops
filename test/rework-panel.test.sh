#!/usr/bin/env bash
#
# test/rework-panel.test.sh — self-contained regression test for
# lib/rework-panel.sh (docs/FLOW-SCHEMA.md's rework and item-lifecycle
# records, D23 of docs/ROADMAP.md, issue #611).
#
# What matters here, one section per acceptance criterion:
#
#   the three questions   how much (tokens/elapsed share vs first-pass
#                         yield), whose (grouped by attributed_stage, an
#                         explicit not-attributed bucket) and how far (the
#                         escape ladder) are each computed correctly from a
#                         constructed event stream.
#   the signature         a fixture built on test/item-lifecycle.test.sh's
#                         own precedent — one log exercising every rung and
#                         class at once — demonstrates that a rising
#                         escape rate at the agent-review rung and a falling
#                         raw rework count are two different, independently
#                         reported figures: the panel never blends them into
#                         one score a Reviewer waving work through could hide
#                         behind.
#   dedup                 a repetition two nodes both logged counts once;
#                         post-merge-revert dedups additionally by
#                         evidence.by, since two distinct corrective pull
#                         requests can name the same original.
#   degradation           a malformed line and a missing log both yield a
#                         conforming report rather than aborting the fold.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/rework-panel.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/item-lifecycle.sh
. "$SCRIPT_DIR/lib/item-lifecycle.sh"
# shellcheck source=lib/rework-panel.sh
. "$SCRIPT_DIR/lib/rework-panel.sh"

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

panel_of() {  # <fixture-file>
  rework_panel_build "$1" ""
}

row_of() {  # <report-json> <stage>
  jq -c --arg s "$2" '.escape_ladder[] | select(.stage == $s)' <<<"$1"
}

# =====================================================================
# The three questions, over one small, hand-traceable fixture
# =====================================================================
# item 1: clean (landed, no rework at all).
# item 2: one review-round-trip (agent-review rung, null attribution).
# item 3: one human-change-request, attributed to reviewer (human-gate rung).
# item 4: one post-merge-revert (post-merge rung, no cycle — mined after the
#         fact) on top of an earlier review-round-trip on the *same* item —
#         its furthest rung is post-merge, not double-counted at agent-review.

basic="$tmp_dir/basic.jsonl"
cat > "$basic" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","node":"n1","cycle":"c1","event":"stage-end","stage":"implementer","repo":"o/r","item":"1","cost_usd":1,"duration_ms":1000,"tokens":{"input":10,"output":10,"cache_creation":0,"cache_read":0}}
{"ts":"2026-01-01T00:01:00Z","node":"n1","cycle":"c1","event":"merge-observed","repo":"o/r","item":"1","pr_url":"https://github.com/o/r/pull/1"}
{"ts":"2026-01-02T00:00:00Z","node":"n1","cycle":"c2","event":"stage-end","stage":"reviewer","repo":"o/r","item":"2","cost_usd":2,"duration_ms":2000,"tokens":{"input":20,"output":20,"cache_creation":0,"cache_read":0}}
{"ts":"2026-01-02T00:01:00Z","node":"n1","cycle":"c2","event":"rework","class":"review-round-trip","detector":"scripts/gather-review-feedback.sh","evidence":{},"attributed_stage":null,"repo":"o/r","item":"2","pr_url":"https://github.com/o/r/pull/2"}
{"ts":"2026-01-02T00:02:00Z","node":"n1","cycle":"c2","event":"merge-observed","repo":"o/r","item":"2","pr_url":"https://github.com/o/r/pull/2"}
{"ts":"2026-01-03T00:00:00Z","node":"n1","cycle":"c3","event":"stage-end","stage":"reviewer","repo":"o/r","item":"3","cost_usd":4,"duration_ms":4000,"tokens":{"input":40,"output":40,"cache_creation":0,"cache_read":0}}
{"ts":"2026-01-03T00:01:00Z","node":"n1","cycle":"c3","event":"rework","class":"human-change-request","detector":"lib/reconciliation-gate.sh:reconciliation_gate","evidence":{},"attributed_stage":"reviewer","repo":"o/r","item":"3","pr_url":"https://github.com/o/r/pull/3"}
{"ts":"2026-01-03T00:02:00Z","node":"n1","cycle":"c3","event":"merge-observed","repo":"o/r","item":"3","pr_url":"https://github.com/o/r/pull/3"}
{"ts":"2026-01-04T00:00:00Z","node":"n1","cycle":"c4","event":"rework","class":"review-round-trip","detector":"scripts/gather-review-feedback.sh","evidence":{},"attributed_stage":null,"repo":"o/r","item":"4","pr_url":"https://github.com/o/r/pull/4"}
{"ts":"2026-01-04T00:01:00Z","node":"n1","cycle":"c4","event":"merge-observed","repo":"o/r","item":"4","pr_url":"https://github.com/o/r/pull/4"}
{"ts":"2026-01-05T00:00:00Z","node":"n1","cycle":null,"event":"rework","class":"post-merge-revert","detector":"scripts/mine-merge-history.sh:AGGREGATE_JQ","evidence":{"kind":"revert","reason":"reference","by":50,"by_title":"Revert x","hours_after":3},"attributed_stage":null,"repo":"o/r","item":"4","pr_url":"https://github.com/o/r/pull/4"}
EOF

report="$(panel_of "$basic")"

# --- How much: tokens/elapsed/cost share vs first-pass yield -----------------
assert_eq "how_much.tokens.total sums every stage-end's tokens (10+10+20+20+40+40)" \
  "140" "$(jq -c '.how_much.tokens.total' <<<"$report")"
assert_eq "how_much.tokens.rework sums only cycles carrying a rework record (c2+c3: 40+80)" \
  "120" "$(jq -c '.how_much.tokens.rework' <<<"$report")"
assert_eq "how_much.tokens.rework_share is rework/total" \
  "0.8571428571428571" "$(jq -c '.how_much.tokens.rework_share' <<<"$report")"
assert_eq "how_much.elapsed_ms.total sums every stage-end's duration_ms" \
  "7000" "$(jq -c '.how_much.elapsed_ms.total' <<<"$report")"
assert_eq "how_much.elapsed_ms.rework sums only the rework-bearing cycles' duration_ms (c2+c3)" \
  "6000" "$(jq -c '.how_much.elapsed_ms.rework' <<<"$report")"
assert_eq "how_much.rework_count is the deduped rework record count (4 records)" \
  "4" "$(jq -c '.how_much.rework_count' <<<"$report")"
assert_eq "first_pass_yield.landed_total counts every landed item" \
  "4" "$(jq -c '.how_much.first_pass_yield.landed_total' <<<"$report")"
assert_eq "first_pass_yield.first_pass excludes only items with an attributed rework record (item 3 alone)" \
  "3" "$(jq -c '.how_much.first_pass_yield.first_pass' <<<"$report")"
assert_eq "  ... item 4's post-merge-revert is unattributed, so it still counts as first-pass by the literal definition" \
  "0.75" "$(jq -c '.how_much.first_pass_yield.yield' <<<"$report")"

# --- Whose: grouped by attributed_stage, explicit not-attributed bucket -----
assert_eq "whose.by_attributed_stage carries exactly the one attributed class (human-change-request -> reviewer)" \
  '[{"stage":"reviewer","count":1}]' "$(jq -c '.whose.by_attributed_stage' <<<"$report")"
assert_eq "whose.not_attributed.count is the other three records (two review-round-trip, one post-merge-revert)" \
  "3" "$(jq -c '.whose.not_attributed.count' <<<"$report")"
assert_eq "  ... broken down by class, never guessed at" \
  '[{"class":"post-merge-revert","count":1},{"class":"review-round-trip","count":2}]' \
  "$(jq -Sc '.whose.not_attributed.by_class' <<<"$report")"

# --- How far: the escape ladder ----------------------------------------------
assert_eq "clean_count is the one item with zero rework records of any class (item 1)" \
  "1" "$(jq -c '.clean_count' <<<"$report")"
assert_eq "agent-review population is every item that ever showed a caught defect (items 2, 3, 4 — not the clean item)" \
  "3" "$(jq -c '.how_much | empty' <<<"$report"; row_of "$report" agent-review | jq -c '.population')"
assert_eq "  ... caught here is the one item whose furthest rung is agent-review (item 2)" \
  "1" "$(row_of "$report" agent-review | jq -c '.caught')"
assert_eq "  ... escaped is items 3 and 4, whose defect was not caught until a later rung" \
  "2" "$(row_of "$report" agent-review | jq -c '.escaped')"
assert_eq "human-gate population is what escaped agent-review (items 3, 4)" \
  "2" "$(row_of "$report" human-gate | jq -c '.population')"
assert_eq "  ... caught here is item 3 alone" \
  "1" "$(row_of "$report" human-gate | jq -c '.caught')"
assert_eq "  ... escaped is item 4, whose review-round-trip did not stop its later post-merge revert" \
  "1" "$(row_of "$report" human-gate | jq -c '.escaped')"
assert_eq "post-merge population is item 4 alone" \
  "1" "$(row_of "$report" post-merge | jq -c '.population')"
assert_eq "  ... post-merge is terminal: no escape_rate, not a misleading 0" \
  "null" "$(row_of "$report" post-merge | jq -c '.escape_rate')"
assert_eq "  ... and no further-rung cost to catch at" \
  '"terminal rung: nothing further to escape to"' \
  "$(row_of "$report" post-merge | jq -c '.cost_to_catch_at_next_note')"
assert_eq "human-gate's own 'cost to catch at next' (post-merge) is unmeasurable, not zero: post-merge-revert carries no cycle" \
  "null" "$(row_of "$report" human-gate | jq -c '.cost_to_catch_at_next')"
assert_eq "  ... and says why, distinctly from the terminal row's own null reason" \
  '"not measurable: post-merge-revert records carry no cycle (mined after the fact, outside any cycle)"' \
  "$(row_of "$report" human-gate | jq -c '.cost_to_catch_at_next_note')"
assert_eq "agent-review's own 'cost to catch at next' (human-gate) is measurable: item 3's cycle c3 cost 4 USD" \
  "4" "$(row_of "$report" agent-review | jq -c '.cost_to_catch_at_next.cost_usd')"

# =====================================================================
# Dedup: a repetition two nodes both logged counts once; post-merge-revert
# additionally keys on evidence.by
# =====================================================================

dupes="$tmp_dir/dupes.jsonl"
cat > "$dupes" <<'EOF'
{"ts":"2026-02-01T00:00:00Z","node":"n1","cycle":"c9","event":"merge-observed","repo":"o/r","item":"9","pr_url":"https://github.com/o/r/pull/9"}
{"ts":"2026-02-01T00:01:00Z","node":"n1","cycle":"c9","event":"rework","class":"review-round-trip","detector":"scripts/gather-review-feedback.sh","evidence":{},"attributed_stage":null,"repo":"o/r","item":"9","pr_url":"https://github.com/o/r/pull/9"}
{"ts":"2026-02-01T00:01:05Z","node":"n2","cycle":"c9","event":"rework","class":"review-round-trip","detector":"scripts/gather-review-feedback.sh","evidence":{},"attributed_stage":null,"repo":"o/r","item":"9","pr_url":"https://github.com/o/r/pull/9"}
{"ts":"2026-02-02T00:00:00Z","node":"n1","cycle":null,"event":"rework","class":"post-merge-revert","detector":"scripts/mine-merge-history.sh:AGGREGATE_JQ","evidence":{"by":60},"attributed_stage":null,"repo":"o/r","item":"10","pr_url":"https://github.com/o/r/pull/10"}
{"ts":"2026-02-02T00:01:00Z","node":"n1","cycle":null,"event":"rework","class":"post-merge-revert","detector":"scripts/mine-merge-history.sh:AGGREGATE_JQ","evidence":{"by":61},"attributed_stage":null,"repo":"o/r","item":"10","pr_url":"https://github.com/o/r/pull/10"}
EOF
dup_report="$(panel_of "$dupes")"
assert_eq "two nodes logging the same repetition ({repo,item,class}) count once, plus two genuinely distinct post-merge-revert corrections" \
  "3" "$(jq -c '.how_much.rework_count' <<<"$dup_report")"
assert_eq "  ... one review-round-trip (deduped from two nodes) and two post-merge-revert (different evidence.by, not deduped)" \
  '[{"class":"post-merge-revert","count":2},{"class":"review-round-trip","count":1}]' \
  "$(jq -Sc '[.whose.not_attributed.by_class[] | {class, count}]' <<<"$dup_report")"

# =====================================================================
# The Reviewer-waving-work-through signature: escape rate and raw rework
# count move in *opposite* directions, and the panel never blends them
# into one score that could hide the regression.
#
# "Before": agent review catches 4 of 5 defects (escape_rate 20%).
# "After":  agent review catches 1 of 5 defects, but the other 4 still
#           surface later (human-gate/post-merge) — a Reviewer waving work
#           through, not fewer defects. A reader looking only at the raw
#           rework count would see it fall and misread that as improvement.
# =====================================================================

before="$tmp_dir/before.jsonl"
: > "$before"
for i in 1 2 3 4; do
  cat >> "$before" <<EOF
{"ts":"2026-03-01T00:00:0${i}Z","node":"n1","cycle":"cb${i}","event":"rework","class":"review-round-trip","detector":"d","evidence":{},"attributed_stage":null,"repo":"o/r","item":"b${i}"}
{"ts":"2026-03-01T00:00:1${i}Z","node":"n1","cycle":"cb${i}","event":"merge-observed","repo":"o/r","item":"b${i}","pr_url":"https://github.com/o/r/pull/b${i}"}
EOF
done
cat >> "$before" <<'EOF'
{"ts":"2026-03-01T00:01:00Z","node":"n1","cycle":"cb5","event":"rework","class":"human-change-request","detector":"d","evidence":{},"attributed_stage":"reviewer","repo":"o/r","item":"b5"}
{"ts":"2026-03-01T00:01:01Z","node":"n1","cycle":"cb5","event":"merge-observed","repo":"o/r","item":"b5","pr_url":"https://github.com/o/r/pull/b5"}
EOF
before_report="$(panel_of "$before")"

after="$tmp_dir/after.jsonl"
cat > "$after" <<'EOF'
{"ts":"2026-04-01T00:00:01Z","node":"n1","cycle":"ca1","event":"rework","class":"review-round-trip","detector":"d","evidence":{},"attributed_stage":null,"repo":"o/r","item":"a1"}
{"ts":"2026-04-01T00:00:02Z","node":"n1","cycle":"ca1","event":"merge-observed","repo":"o/r","item":"a1","pr_url":"https://github.com/o/r/pull/a1"}
EOF
for i in 2 3 4 5; do
  cat >> "$after" <<EOF
{"ts":"2026-04-01T00:01:0${i}Z","node":"n1","cycle":"ca${i}","event":"rework","class":"human-change-request","detector":"d","evidence":{},"attributed_stage":"reviewer","repo":"o/r","item":"a${i}"}
{"ts":"2026-04-01T00:01:1${i}Z","node":"n1","cycle":"ca${i}","event":"merge-observed","repo":"o/r","item":"a${i}","pr_url":"https://github.com/o/r/pull/a${i}"}
EOF
done
after_report="$(panel_of "$after")"

before_escape="$(row_of "$before_report" agent-review | jq -c '.escape_rate')"
after_escape="$(row_of "$after_report" agent-review | jq -c '.escape_rate')"
before_caught="$(row_of "$before_report" agent-review | jq -c '.caught')"
after_caught="$(row_of "$after_report" agent-review | jq -c '.caught')"

assert_eq "before: agent-review escape rate is low (4 of 5 caught here)" "0.2" "$before_escape"
assert_eq "after: agent-review escape rate has risen (only 1 of 5 caught here)" "0.8" "$after_escape"
assert_eq "before: the Reviewer's own catch count reads 4" "4" "$before_caught"
assert_eq "after: the Reviewer's own catch count has *fallen* to 1 — the exact figure a naive dashboard would report as improvement" \
  "1" "$after_caught"
# The regression is real (defects still surface, just later and more
# expensively) even though the one figure a naive reader might watch — how
# many the Reviewer itself caught — went down. escape_rate is what makes
# that legible as a regression rather than an improvement: it rises exactly
# when caught falls for the wrong reason. The panel never blends the two
# into one score, so this divergence stays visible instead of cancelling out.
if awk -v a="$after_escape" -v b="$before_escape" 'BEGIN{exit !(a>b)}' \
   && [[ "$after_caught" -lt "$before_caught" ]]; then
  printf 'ok   - %s\n' "escape_rate rose while the Reviewer's own catch count fell — the two figures move oppositely, never blended into one score"
else
  printf 'FAIL - %s\n' "escape_rate rose while the Reviewer's own catch count fell — the two figures move oppositely, never blended into one score"
  failures=$(( failures + 1 ))
fi

# =====================================================================
# Degradation: a malformed line, a missing log
# =====================================================================

degraded="$tmp_dir/degraded.jsonl"
cat > "$degraded" <<'EOF'
this line is not json at all
{"ts":"2026-05-01T00:00:00Z","node":"n1","event":"warning","detail":"unrelated"}
{"ts":"2026-05-01T00:00:01Z","node":"n1","cycle":"c1","event":"rework","class":"review-round-trip","detector":"d","evidence":{},"attributed_stage":null,"repo":"o/r","item":"1"}
{"ts":"2026-05-01T00:00:02Z","node":"n1","cycle":"c1","event":"merge-observed","repo":"o/r","item":"1","pr_url":"https://github.com/o/r/pull/1"}
EOF
degraded_report="$(panel_of "$degraded")"
assert_eq "a malformed line is skipped, not fatal — the well-formed record still counts" \
  "1" "$(jq -c '.how_much.rework_count' <<<"$degraded_report")"

empty_report="$(panel_of "$tmp_dir/does-not-exist.jsonl")"
assert_eq "a missing log reports zero rework, never null-crashes" \
  "0" "$(jq -c '.how_much.rework_count' <<<"$empty_report")"
assert_eq "  ... and a conforming, empty escape ladder throughout" \
  "0" "$(jq -c '.escape_ladder | length - 3' <<<"$empty_report")"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
