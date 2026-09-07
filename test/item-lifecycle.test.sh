#!/usr/bin/env bash
#
# test/item-lifecycle.test.sh — self-contained regression test for
# lib/item-lifecycle.sh (docs/FLOW-SCHEMA.md's "Item lifecycle record",
# requirement 49 of docs/IMPLEMENTATION-PIPELINE-SPEC.md, issue #595). Also
# covers requirement 2.6d's de-duplication property (agent-ops#598), which
# this fold is the worked example for.
#
# What matters here:
#
#   one fixture per     landed, voided, superseded, abandoned, blocked, open
#   terminal fate       — each item resolvable from exactly one rule, per
#                        lib/item-lifecycle.sh's own documented priority.
#   the invariant       every entered item lands in exactly one of the seven
#   balances            buckets (six fates plus unaccounted); `totals.balanced`
#                        is asserted true on a fixture carrying all of them at
#                        once.
#   unaccounted         a voided-after-landed contradiction is not silently
#                        resolved either way — it is named, with its reason,
#                        and still counted (never dropped).
#   reworked_after_      additive alongside fate: "landed" — present, naming
#   landed               the earliest later item-scoped event, when one
#                        exists; absent (never false/null) otherwise.
#   degradation         a malformed line, a missing field, an event naming
#                        no item, and a non-string `repo` all yield a
#                        conforming report rather than aborting the fold.
#   two-node dedup       two nodes each folding the union `fleet_logs` hands
#                        them (their own log plus the other's, as a peer)
#                        produce byte-identical `records[]`, and merging
#                        both folds' records by `{repo, item}` still yields
#                        exactly one record per item (requirement 2.6d).
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/item-lifecycle.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/item-lifecycle.sh
. "$SCRIPT_DIR/lib/item-lifecycle.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"

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

fold_of() {  # <fixture-file> [since]
  item_lifecycle_fold "$1" "${2:-}"
}

fate_of() {  # <report-json> <repo> <item>
  jq -r --arg r "$2" --arg i "$3" '.records[] | select(.repo == $r and .item == $i) | .fate' <<<"$1"
}

# --- One fixture per terminal fate --------------------------------------------
# Every item below is deliberately independent of every other — one clean
# rule fires per item, and nothing about another item's evidence leaks across
# the group_by this fold keys on.

fixture="$tmp_dir/fates.jsonl"
cat > "$fixture" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","node":"n1","cycle":"c1","event":"first-seen","repo":"acme/widgets","item":"1"}
{"ts":"2026-01-01T00:01:00Z","node":"n1","cycle":"c1","event":"selection","repo":"acme/widgets","item":"1","source":"issues"}
{"ts":"2026-01-01T00:02:00Z","node":"n1","cycle":"c1","event":"pr-raised","repo":"acme/widgets","item":"1","pr_url":"https://github.com/acme/widgets/pull/1"}
{"ts":"2026-01-01T00:03:00Z","node":"n1","cycle":"c1","event":"merge-observed","repo":"acme/widgets","item":"1","pr_url":"https://github.com/acme/widgets/pull/1","stage":"landing"}
{"ts":"2026-01-02T00:00:00Z","node":"n1","cycle":"c2","event":"first-seen","repo":"acme/widgets","item":"2"}
{"ts":"2026-01-02T00:01:00Z","node":"n1","cycle":"c2","event":"item-void","repo":"acme/widgets","item":"2"}
{"ts":"2026-01-03T00:00:00Z","node":"n1","cycle":"c3","event":"orphan-branch-released","repo":"acme/widgets","reason":"superseded","branch":"agent/3","superseded_by":"https://github.com/acme/widgets/pull/30"}
{"ts":"2026-01-04T00:00:00Z","node":"n1","cycle":"c4","event":"pr-raised","repo":"acme/widgets","item":"4","pr_url":"https://github.com/acme/widgets/pull/4"}
{"ts":"2026-01-04T00:01:00Z","node":"n1","cycle":"c4","event":"draft-obsolete-flagged","repo":"acme/widgets","item":"4","pr":"https://github.com/acme/widgets/pull/4","evidence":"stale"}
{"ts":"2026-01-05T00:00:00Z","node":"n1","cycle":"c5","event":"first-seen","repo":"acme/widgets","item":"5"}
{"ts":"2026-01-05T00:01:00Z","node":"n1","cycle":"c5","event":"selection","repo":"acme/widgets","item":"5","source":"issues"}
{"ts":"2026-01-05T00:02:00Z","node":"n1","cycle":"c5","event":"attempt-failed","repo":"acme/widgets","item":"5","stage":"implementer","detail":"build failed"}
{"ts":"2026-01-06T00:00:00Z","node":"n1","cycle":"c6","event":"first-seen","repo":"acme/widgets","item":"6"}
EOF

report="$(fold_of "$fixture")"

assert_eq "landed: a merge-observed event resolves it" "landed" "$(fate_of "$report" acme/widgets 1)"
assert_eq "voided: an unresolved item-void resolves it" "voided" "$(fate_of "$report" acme/widgets 2)"
assert_eq "superseded: an orphan-branch-released{reason:superseded} resolves it, item derived from its branch" \
  "superseded" "$(fate_of "$report" acme/widgets 3)"
assert_eq "abandoned: a draft-obsolete-flagged event resolves it" "abandoned" "$(fate_of "$report" acme/widgets 4)"
assert_eq "blocked: an unresolved attempt-failed resolves it" "blocked" "$(fate_of "$report" acme/widgets 5)"
assert_eq "open: first-seen alone, nothing since, resolves it" "open" "$(fate_of "$report" acme/widgets 6)"

assert_eq "identity, source and first_seen are all correct for the landed item" \
  '{"repo":"acme/widgets","item":"1","source":"issues","first_seen":"2026-01-01T00:00:00Z"}' \
  "$(jq -c '.records[] | select(.item == "1") | {repo, item, source, first_seen}' <<<"$report")"
assert_eq "instants are in timestamp order, each naming its own event" \
  '["first-seen","selection","pr-raised","merge-observed"]' \
  "$(jq -c '[.records[] | select(.item == "1") | .instants[].event]' <<<"$report")"
assert_eq "an item resolved only via its branch carries no source (no selection event)" \
  "null" "$(jq -c '.records[] | select(.item == "3") | .source' <<<"$report")"

# --- The invariant balances ----------------------------------------------------

assert_eq "six items entered" "6" "$(jq -c '.totals.entered' <<<"$report")"
assert_eq "four are leaving (landed+voided+superseded+abandoned)" "4" "$(jq -c '.totals.leaving' <<<"$report")"
assert_eq "in_progress is blocked+open, i.e. 2" "2" "$(jq -c '.totals.in_progress' <<<"$report")"
assert_eq "nothing is unaccounted in this fixture" "0" "$(jq -c '.totals.unaccounted' <<<"$report")"
assert_eq "the invariant balances: entered == leaving + in_progress + unaccounted" \
  "true" "$(jq -c '.totals.balanced' <<<"$report")"
assert_eq "fates.blocked counts item 5" "1" "$(jq -c '.fates.blocked' <<<"$report")"
assert_eq "fates.open counts item 6" "1" "$(jq -c '.fates.open' <<<"$report")"

# --- Unaccounted: a genuine contradiction, never silently resolved ------------
# Voided *after* a merge was already observed disputes its own void: the
# fold does not guess which side is right.

contradiction="$tmp_dir/contradiction.jsonl"
cat > "$contradiction" <<'EOF'
{"ts":"2026-02-01T00:00:00Z","node":"n1","cycle":"c9","event":"merge-observed","repo":"acme/widgets","item":"9","pr_url":"https://github.com/acme/widgets/pull/9","stage":"landing"}
{"ts":"2026-02-02T00:00:00Z","node":"n1","cycle":"c9","event":"item-void","repo":"acme/widgets","item":"9"}
EOF
out="$(fold_of "$contradiction")"
assert_eq "a void recorded after its own merge evidence is unaccounted, not landed" \
  "unaccounted" "$(fate_of "$out" acme/widgets 9)"
assert_eq "  ... still counted, never dropped" "1" "$(jq -c '.totals.entered' <<<"$out")"
assert_eq "  ... and the invariant still balances" "true" "$(jq -c '.totals.balanced' <<<"$out")"
assert_contains "  ... named in unaccounted[] with its own reason" \
  "contradictory" "$(jq -r '.unaccounted[0].reason' <<<"$out")"
assert_eq "  ... naming the repo and item" \
  '{"repo":"acme/widgets","item":"9"}' \
  "$(jq -c '.unaccounted[0] | {repo, item}' <<<"$out")"

# The mirror-image order — voided *before* any merge evidence — is not a
# contradiction: the void was simply wrong, and the later merge is the
# stronger evidence. `landed` wins outright.
resolved_order="$tmp_dir/resolved-order.jsonl"
cat > "$resolved_order" <<'EOF'
{"ts":"2026-03-01T00:00:00Z","node":"n1","cycle":"c10","event":"item-void","repo":"acme/widgets","item":"10"}
{"ts":"2026-03-02T00:00:00Z","node":"n1","cycle":"c10","event":"merge-observed","repo":"acme/widgets","item":"10","pr_url":"https://github.com/acme/widgets/pull/10","stage":"landing"}
EOF
out="$(fold_of "$resolved_order")"
assert_eq "voided before a later merge is landed outright, no contradiction" \
  "landed" "$(fate_of "$out" acme/widgets 10)"
assert_eq "  ... and it is not counted as unaccounted" "0" "$(jq -c '.totals.unaccounted' <<<"$out")"

# --- reworked_after_landed: an item-scoped event later than the earliest ----
# landing evidence, additive alongside fate: "landed" (issue #1181).

reworked="$tmp_dir/reworked.jsonl"
cat > "$reworked" <<'EOF'
{"ts":"2026-01-10T00:00:00Z","node":"n1","cycle":"c30","event":"first-seen","repo":"acme/widgets","item":"70"}
{"ts":"2026-01-10T00:01:00Z","node":"n1","cycle":"c30","event":"pr-raised","repo":"acme/widgets","item":"70","pr_url":"https://github.com/acme/widgets/pull/70"}
{"ts":"2026-01-10T00:02:00Z","node":"n1","cycle":"c30","event":"merge-observed","repo":"acme/widgets","item":"70","pr_url":"https://github.com/acme/widgets/pull/70","stage":"landing"}
{"ts":"2026-01-11T00:00:00Z","node":"n1","cycle":"c31","event":"pr-raised","repo":"acme/widgets","item":"70","pr_url":"https://github.com/acme/widgets/pull/71"}
{"ts":"2026-01-12T00:00:00Z","node":"n1","cycle":"c32","event":"first-seen","repo":"acme/widgets","item":"72"}
{"ts":"2026-01-12T00:01:00Z","node":"n1","cycle":"c32","event":"pr-raised","repo":"acme/widgets","item":"72","pr_url":"https://github.com/acme/widgets/pull/72"}
{"ts":"2026-01-12T00:02:00Z","node":"n1","cycle":"c32","event":"merge-observed","repo":"acme/widgets","item":"72","pr_url":"https://github.com/acme/widgets/pull/72","stage":"landing"}
EOF
out="$(fold_of "$reworked")"
assert_eq "a landed item with a later pr-raised still resolves landed" \
  "landed" "$(fate_of "$out" acme/widgets 70)"
assert_eq "  ... and carries reworked_after_landed naming the earliest later event" \
  '{"since":"2026-01-11T00:00:00Z","event":"pr-raised"}' \
  "$(jq -c '.records[] | select(.item == "70") | .reworked_after_landed' <<<"$out")"
assert_eq "an ordinary landed item with no later activity carries no reworked_after_landed field" \
  "false" "$(jq -c '.records[] | select(.item == "72") | has("reworked_after_landed")' <<<"$out")"

# --- Degradation: a malformed line, a missing field, an event with no item ----

degraded="$tmp_dir/degraded.jsonl"
cat > "$degraded" <<'EOF'
this line is not json at all
{"ts":"2026-04-01T00:00:00Z","node":"n1","event":"warning","detail":"no repo or item here"}
{"ts":"2026-04-01T00:01:00Z","node":"n1","event":"first-seen","item":"20"}
{"ts":"2026-04-01T00:02:00Z","node":"n1","event":"first-seen","repo":"acme/widgets","item":"21"}
EOF
out="$(fold_of "$degraded")"
assert_eq "a malformed line and events missing repo or item are skipped, not fatal" \
  "1" "$(jq -c '.totals.entered' <<<"$out")"
assert_eq "  ... the one fully-keyed event still enters" \
  "open" "$(fate_of "$out" acme/widgets 21)"
assert_eq "  ... and the fold prints a conforming report throughout" \
  "true" "$(jq -c '.totals.balanced' <<<"$out")"

# A `repo` that is valid JSON but not a string keys the item like any other
# (`item_key` coerces both halves) — it must not error the per-item lookup of
# the unwindowed evidence index and collapse the whole fold to its all-zero
# fallback, the way concatenating the raw `repo` and `item` would.

nonstring_repo="$tmp_dir/non-string-repo.jsonl"
cat > "$nonstring_repo" <<'EOF'
{"ts":"2026-04-02T00:00:00Z","node":"n1","event":"first-seen","repo":42,"item":"22"}
{"ts":"2026-04-02T00:01:00Z","node":"n1","event":"first-seen","repo":"acme/widgets","item":"23"}
{"ts":"2026-04-02T00:02:00Z","node":"n1","event":"merge-observed","repo":"acme/widgets","item":"23","pr_url":"https://github.com/acme/widgets/pull/23"}
EOF
out="$(fold_of "$nonstring_repo")"
assert_eq "a non-string repo does not collapse the fold to its all-zero fallback" \
  "2" "$(jq -c '.totals.entered' <<<"$out")"
assert_eq "  ... the well-formed item beside it still resolves from its own evidence" \
  "landed" "$(fate_of "$out" acme/widgets 23)"
assert_eq "  ... and the odd one still enters, keyed on its coerced repo" \
  "open" "$(jq -r '.records[] | select((.repo | tostring) == "42") | .fate' <<<"$out")"

# --- --since bounds what the fold reads, same as every other reader --------

since_fixture="$tmp_dir/since.jsonl"
cat > "$since_fixture" <<'EOF'
{"ts":"2026-05-01T00:00:00Z","node":"n1","event":"first-seen","repo":"acme/widgets","item":"30"}
{"ts":"2026-05-02T00:00:00Z","node":"n1","event":"first-seen","repo":"acme/widgets","item":"31"}
EOF
out="$(fold_of "$since_fixture" "2026-05-02T00:00:00Z")"
assert_eq "--since excludes an item first seen before the bound" "1" "$(jq -c '.totals.entered' <<<"$out")"
assert_eq "  ... window.from reflects the bound, not the log's own start" \
  '"2026-05-02T00:00:00Z"' "$(jq -c '.window.from' <<<"$out")"

# --- Priority: blocked outranks abandoned when both apply --------------------
# A currently-blocked item is demonstrably still in the system, which
# outranks the merely uncorroborated intent `abandoned` records.

both="$tmp_dir/blocked-and-abandoned.jsonl"
cat > "$both" <<'EOF'
{"ts":"2026-06-01T00:00:00Z","node":"n1","cycle":"c20","event":"pr-raised","repo":"acme/widgets","item":"40","pr_url":"https://github.com/acme/widgets/pull/40"}
{"ts":"2026-06-01T00:01:00Z","node":"n1","cycle":"c20","event":"draft-obsolete-flagged","repo":"acme/widgets","item":"40","pr":"https://github.com/acme/widgets/pull/40","evidence":"stale"}
{"ts":"2026-06-01T00:02:00Z","node":"n1","cycle":"c20","event":"attempt-failed","repo":"acme/widgets","item":"40","stage":"implementer","detail":"build failed"}
EOF
out="$(fold_of "$both")"
assert_eq "blocked outranks abandoned when both apply" "blocked" "$(fate_of "$out" acme/widgets 40)"

# --- --since bounds the population, never the fate --------------------------
# An item entering the reported population on the strength of one recent
# event still resolves to its true fate from the whole log, even when the
# evidence deciding that fate sits before --since.

full_history="$tmp_dir/full-history.jsonl"
cat > "$full_history" <<'EOF'
{"ts":"2026-07-01T00:00:00Z","node":"n1","cycle":"c21","event":"first-seen","repo":"acme/widgets","item":"50"}
{"ts":"2026-07-05T00:00:00Z","node":"n1","cycle":"c22","event":"first-seen","repo":"acme/widgets","item":"51"}
{"ts":"2026-07-01T00:00:00Z","node":"n1","cycle":"c23","event":"first-seen","repo":"acme/widgets","item":"52"}
{"ts":"2026-07-01T00:01:00Z","node":"n1","cycle":"c23","event":"merge-observed","repo":"acme/widgets","item":"52","pr_url":"https://github.com/acme/widgets/pull/52","stage":"landing"}
{"ts":"2026-07-05T00:00:00Z","node":"n1","cycle":"c23","event":"first-seen","repo":"acme/widgets","item":"52"}
{"ts":"2026-07-01T00:00:00Z","node":"n1","cycle":"c24","event":"pr-raised","repo":"acme/widgets","item":"53","pr_url":"https://github.com/acme/widgets/pull/53"}
{"ts":"2026-07-01T00:01:00Z","node":"n1","cycle":"c24","event":"draft-obsolete-flagged","repo":"acme/widgets","item":"53","pr":"https://github.com/acme/widgets/pull/53","evidence":"stale"}
{"ts":"2026-07-05T00:00:00Z","node":"n1","cycle":"c24","event":"first-seen","repo":"acme/widgets","item":"53"}
EOF
out="$(fold_of "$full_history" "2026-07-04T00:00:00Z")"
assert_eq "item 50 has no event inside the window, so it is not in the population at all" \
  "" "$(fate_of "$out" acme/widgets 50)"
assert_eq "item 51 enters the population from a within-window event alone, no other evidence anywhere" \
  "open" "$(fate_of "$out" acme/widgets 51)"
assert_eq "item 52 enters the population from a within-window event, but its merge evidence from before --since still governs its fate" \
  "landed" "$(fate_of "$out" acme/widgets 52)"
assert_eq "item 53 enters the population from a within-window event, but its draft-obsolete-flagged evidence from before --since still governs its fate" \
  "abandoned" "$(fate_of "$out" acme/widgets 53)"

# --- item_lifecycle_pickup_pairs tolerates a valid-JSON, non-object line -----
# A bare scalar (e.g. a torn/interleaved append leaving `42` on its own line)
# is valid JSON but not an object; indexing `.ts`/`.event` on it must not
# error the whole jq program and silently collapse pairing to the all-zero
# fallback (the same object-type guard `ITEM_LIFECYCLE_FOLD_JQ` already
# applies to `$all` before this guard was added here too).

pickup_fixture="$tmp_dir/pickup-guard.jsonl"
cat > "$pickup_fixture" <<'EOF'
42
{"ts":"2026-08-01T00:00:00Z","node":"n1","event":"first-seen","repo":"acme/widgets","item":"60"}
{"ts":"2026-08-01T00:05:00Z","node":"n1","event":"selection","repo":"acme/widgets","item":"60","source":"issues"}
EOF
out="$(item_lifecycle_pickup_pairs "" "$pickup_fixture")"
assert_eq "a bare scalar JSON line does not zero out pickup pairing" \
  "1" "$(jq -c '.coverage.paired' <<<"$out")"
assert_eq "  ... and the paired latency is computed, not the all-zero fallback" \
  "1" "$(jq -c '.pickup_latency.fleet.count' <<<"$out")"

# --- An empty or unreadable log prints a conforming, all-zero report ---------

empty_out="$(fold_of "$tmp_dir/does-not-exist.jsonl")"
assert_eq "a missing log reports zero entered" "0" "$(jq -c '.totals.entered' <<<"$empty_out")"
assert_eq "  ... balanced true, window null" \
  '{"balanced":true}' "$(jq -c '.totals | {balanced}' <<<"$empty_out")"
assert_eq "  ... and an empty records/unaccounted array, never missing keys" \
  '{"records":[],"unaccounted":[]}' "$(jq -c '{records, unaccounted}' <<<"$empty_out")"

# --- Two nodes folding the same union agree, and merging never double-counts
# (requirement 2.6d, agent-ops#598) --------------------------------------------
# Node A and node B each observe half of the same item's history — the shape
# a claim race or a stage split across two nodes leaves — and each only has
# the other's half through `fleet_logs`, exactly as a real fetch would
# deliver it. Neither node's own log alone tells the whole story; the union
# each of them computes does.
node_a_home="$tmp_dir/dedup-node-a"
node_b_home="$tmp_dir/dedup-node-b"
mkdir -p "$node_a_home" "$node_b_home/peers/nodeA" "$node_a_home/peers/nodeB"

cat > "$node_a_home/log.jsonl" <<'EOF'
{"ts":"2026-02-01T00:00:00Z","node":"nodeA","cycle":"cA1","event":"first-seen","repo":"acme/widgets","item":"100"}
{"ts":"2026-02-01T00:01:00Z","node":"nodeA","cycle":"cA1","event":"selection","repo":"acme/widgets","item":"100","source":"issues"}
EOF
cat > "$node_b_home/log.jsonl" <<'EOF'
{"ts":"2026-02-01T00:02:00Z","node":"nodeB","cycle":"cB1","event":"pr-raised","repo":"acme/widgets","item":"100","pr_url":"https://github.com/acme/widgets/pull/100"}
{"ts":"2026-02-01T00:03:00Z","node":"nodeB","cycle":"cB1","event":"merge-observed","repo":"acme/widgets","item":"100","pr_url":"https://github.com/acme/widgets/pull/100","stage":"landing"}
EOF
# Each node's peers directory holds the *other* node's log, exactly as a
# fetch materialises a peer (lib/fleet.sh) — never its own.
cp "$node_b_home/log.jsonl" "$node_a_home/peers/nodeB/log.jsonl"
cp "$node_a_home/log.jsonl" "$node_b_home/peers/nodeA/log.jsonl"

union_a="$tmp_dir/dedup-union-a.jsonl"
union_b="$tmp_dir/dedup-union-b.jsonl"
fleet_logs "$node_a_home" "$node_a_home/peers" > "$union_a"
fleet_logs "$node_b_home" "$node_b_home/peers" > "$union_b"

# A prerequisite fact, distinct from the record-identity property proved
# below: the raw union itself manufactures no duplicate events. Four
# distinct events went in (two from each node), and the union each node
# computes carries exactly those four, never a node's own doubled by its
# peer's copy of itself.
raw_event_count() {  # <union-file>
  jq -s '[.[] | {node, ts, event, repo, item}] | unique | length' "$1"
}
assert_eq "node A's union carries exactly the four distinct events" "4" "$(raw_event_count "$union_a")"
assert_eq "node B's union carries the identical four, not eight" "4" "$(raw_event_count "$union_b")"
assert_eq "the two unions are byte-identical (same events, same sort)" \
  "$(cat "$union_a")" "$(cat "$union_b")"

report_a="$(fold_of "$union_a")"
report_b="$(fold_of "$union_b")"
assert_eq "two nodes folding the same union produce identical records[]" \
  "$(jq -c '.records' <<<"$report_a")" "$(jq -c '.records' <<<"$report_b")"
assert_eq "the item resolves to its true fate from either node's fold" \
  "landed" "$(fate_of "$report_a" acme/widgets 100)"

# Merging the two folds' own record sets — the shape a future per-node
# publication of this fold would produce — reduces to one record per item,
# never two, by the record's own {repo, item} identity.
merged_records="$(jq -c -n --argjson a "$(jq -c '.records' <<<"$report_a")" \
  --argjson b "$(jq -c '.records' <<<"$report_b")" \
  '($a + $b) | group_by([.repo, .item]) | map(.[0])')"
assert_eq "merging both nodes' outputs still yields exactly one record for the item" \
  "1" "$(jq 'length' <<<"$merged_records")"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
