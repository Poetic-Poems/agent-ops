#!/usr/bin/env bash
#
# test/first-seen-emission.test.sh — regression test for `emit_first_seen`
# (agent-cycle.sh, TD-PPagop-26081405, issue #248 acceptance 4): the function
# that logs a `first-seen` event the first time any node's gather reports an
# item, read back by scripts/pickup-metrics.sh to answer the issue's median-
# pickup-latency acceptance.
#
# Two properties matter and are not covered anywhere else:
#
#   - **Emitted once, not twice.** A second cycle that gathers the same item
#     — because it is still open, or a node re-gathers it before it is
#     claimed — appends nothing, once `first_seen_known_json` has been
#     re-seeded from the log the way agent-cycle.sh reseeds it every cycle
#     (`first_seen_known_items`, lib/cycle-state.sh).
#   - **Emitted for an item excluded as claimed.** `emit_first_seen` runs on
#     each source's RAW gathered array, before `exclude_claimed_items` ever
#     sees it (agent-cycle.sh's gather step) — so an item claimed the very
#     cycle it first appears still gets a `first-seen`, even though the same
#     candidate never reaches the Co-Ordinator's runtime input. Losing this
#     would silently drop exactly the items that were picked up fastest.
#
# `emit_first_seen` and its sole callee `log_event` are lifted verbatim out
# of agent-cycle.sh, the same extraction test/pr-claim-exclusion.test.sh uses
# for `exclude_claimed_items` (also lifted here, to prove the claimed-same-
# cycle property against the real filter rather than a description of it) —
# so the assertions are about the shipped code, not a copy of its logic.
# `first_seen_known_items` is sourced directly from lib/cycle-state.sh, which
# is safe to source standalone (function definitions only).
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/first-seen-emission.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- Lift emit_first_seen, log_event and exclude_claimed_items whole out of
#     their own files, the same extraction test/pr-claim-exclusion.test.sh
#     uses — emit_first_seen/exclude_claimed_items from lib/candidate-select.sh
#     (#771), log_event still from agent-cycle.sh itself.
extract_function() {  # extract_function <name> <file>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$2"
}

emit_first_seen_src="$(extract_function emit_first_seen "$SCRIPT_DIR/lib/candidate-select.sh")"
log_event_src="$(extract_function log_event "$SCRIPT_DIR/agent-cycle.sh")"
exclude_claimed_items_src="$(extract_function exclude_claimed_items "$SCRIPT_DIR/lib/candidate-select.sh")"

if [[ "$emit_first_seen_src" != *"emit_first_seen()"* ]]; then
  printf 'FAIL - could not extract emit_first_seen from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$log_event_src" != *"log_event()"* ]]; then
  printf 'FAIL - could not extract log_event from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi
if [[ "$exclude_claimed_items_src" != *"exclude_claimed_items()"* ]]; then
  printf 'FAIL - could not extract exclude_claimed_items from agent-cycle.sh (renamed or moved?)\n'
  exit 1
fi

eval "$emit_first_seen_src"
eval "$log_event_src"
eval "$exclude_claimed_items_src"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"

# --- The globals log_event and emit_first_seen read/write ---------------------
# Consumed by the eval'd log_event/emit_first_seen, which shellcheck cannot
# see into — the same pattern test/pr-claim-exclusion.test.sh uses for
# branch_prefix.
# shellcheck disable=SC2034
cycle_id="test-cycle"
# shellcheck disable=SC2034
node_name="node-a"
log_file="$tmp_dir/log.jsonl"
: > "$log_file"

# --- Scenario 1: two never-before-seen candidates, both get a first-seen ------
# shellcheck disable=SC2034
first_seen_known_json='[]'
# shellcheck disable=SC2034
first_seen_bootstrap='false'
candidates_raw='[{"ref":"TD-1","title":"one"},{"ref":"TD-2","title":"two"}]'
emit_first_seen "o/r" "tech-debt" "$candidates_raw"

assert_eq "first cycle: two candidates yield two first-seen lines" \
  "2" "$(wc -l < "$log_file" | tr -d ' ')"
assert_eq "first cycle: TD-1's first-seen carries the right fields" \
  '{"repo":"o/r","item":"TD-1","source":"tech-debt","basis":"poll","bootstrap":false}' \
  "$(jq -c 'select(.item == "TD-1") | {repo, item, source, basis, bootstrap}' "$log_file")"
assert_eq "first cycle: TD-2 also got one" \
  "1" "$(jq -c 'select(.item == "TD-2")' "$log_file" | wc -l | tr -d ' ')"

# --- Scenario 2: emitted once, not twice ---------------------------------------
# A later cycle re-seeds first_seen_known_json from the log the way
# agent-cycle.sh does every cycle, then re-gathers the same two candidates
# (still open, not yet claimed) plus one genuinely new one.
# shellcheck disable=SC2034
first_seen_known_json="$(first_seen_known_items "$log_file")"
# shellcheck disable=SC2034
first_seen_bootstrap='false'
candidates_round2='[{"ref":"TD-1","title":"one"},{"ref":"TD-2","title":"two"},{"ref":"TD-3","title":"three"}]'
emit_first_seen "o/r" "tech-debt" "$candidates_round2"

assert_eq "second cycle: only the genuinely new item appends a line" \
  "3" "$(wc -l < "$log_file" | tr -d ' ')"
assert_eq "second cycle: TD-1 still has exactly one first-seen (not two)" \
  "1" "$(jq -c 'select(.item == "TD-1")' "$log_file" | wc -l | tr -d ' ')"
assert_eq "second cycle: TD-3 is the one new line" \
  "1" "$(jq -c 'select(.item == "TD-3")' "$log_file" | wc -l | tr -d ' ')"

# --- Scenario 3: a different repo's identically-named item is independent -----
# repo is part of the dedup key, so "o/r2"'s own TD-1 is unrelated to "o/r"'s.
emit_first_seen "o/r2" "tech-debt" '[{"ref":"TD-1","title":"one, but a different repo"}]'
assert_eq "a same-ref item in a different repo still gets its own first-seen" \
  "1" "$(jq -c 'select(.item == "TD-1" and .repo == "o/r2")' "$log_file" | wc -l | tr -d ' ')"

# --- Scenario 4: emitted for an item excluded as claimed (acceptance 3) -------
# TD-4 is claimed the very cycle it first appears — exclude_claimed_items
# would drop it from what the Co-Ordinator sees — but emit_first_seen runs on
# the RAW array, ahead of that filter, so it still gets logged.
raw_with_claim='[{"ref":"TD-4","title":"claimed same cycle"},{"ref":"TD-5","title":"not claimed"}]'
emit_first_seen "o/r" "tech-debt" "$raw_with_claim"
filtered="$(exclude_claimed_items "$raw_with_claim" '["TD-4"]')"

assert_eq "TD-4 (claimed this cycle) still gets a first-seen" \
  "1" "$(jq -c 'select(.item == "TD-4" and .repo == "o/r")' "$log_file" | wc -l | tr -d ' ')"
assert_eq "TD-5 (not claimed) also gets a first-seen" \
  "1" "$(jq -c 'select(.item == "TD-5" and .repo == "o/r")' "$log_file" | wc -l | tr -d ' ')"
assert_eq "exclude_claimed_items itself still drops TD-4 from what the Co-Ordinator sees" \
  '["TD-5"]' "$(jq -c '[.[].ref]' <<<"$filtered")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
