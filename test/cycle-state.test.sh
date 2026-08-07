#!/usr/bin/env bash
#
# test/cycle-state.test.sh — self-contained regression test for
# lib/cycle-state.sh.
#
# Covers the two defects that let a stale work order (review-2026-07-11-R-01,
# "Add a licence" — already done on main) be re-selected nine times, each time
# paying for a full Implementor run that correctly reported `blocked` and was
# then forgotten:
#
#   1. read_pr_url_breadcrumb returned non-zero when no PR had been opened,
#      which under `set -e` aborted the cycle at its call site — before the
#      blocked verdict could be logged at all.
#   2. attempt-failed events carried no `item`, so the blocked extract (which
#      keys on repo+item) could never match the item that had failed.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/cycle-state.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"

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

# --- read_pr_url_breadcrumb ---

clone_dir="$tmp_dir/clone"
mkdir -p "$clone_dir/.git"

# The regression: absent breadcrumb must not be a failure. Asserted through the
# real call-site shape under `set -e`, in a subshell, because the bug was in the
# interaction between the two — the function alone looked fine.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/cycle-state.sh"
  url=""
  [[ -z "$url" ]] && url="$(read_pr_url_breadcrumb "$clone_dir")"
  exit 0
) >/dev/null 2>&1
assert_eq "absent breadcrumb does not abort its caller under set -e" "0" "$?"

assert_eq "absent breadcrumb reads as empty" "" "$(read_pr_url_breadcrumb "$clone_dir")"

printf '  https://github.com/o/r/pull/7  \n' > "$clone_dir/.git/agent-ops-pr-url"
assert_eq "present breadcrumb is read and trimmed" \
  "https://github.com/o/r/pull/7" "$(read_pr_url_breadcrumb "$clone_dir")"

# --- item_event_fields ---

assert_eq "attempt-failed carries the item it failed on" \
  '{"stage":"implementor","detail":"blocked on an unmerged dep","repo":"o/r","item":"review-2026-07-11-R-01"}' \
  "$(item_event_fields "implementor" "blocked on an unmerged dep" "o/r" "review-2026-07-11-R-01")"

assert_eq "extra fields are merged in" \
  '{"stage":"implementor","detail":"dep unmerged","repo":"o/r","item":"R-01","unblock_condition":"refresh the review"}' \
  "$(item_event_fields "implementor" "dep unmerged" "o/r" "R-01" '{"unblock_condition":"refresh the review"}')"

# A stage that fails before anything is selected blames no item.
assert_eq "repo/item omitted when there is no selection" \
  '{"stage":"coordinator","detail":"unparseable final message"}' \
  "$(item_event_fields "coordinator" "unparseable final message" "" "")"

# --- blocked_items ---

log="$tmp_dir/log.jsonl"

assert_eq "missing log yields no blocked items" "[]" "$(blocked_items "$tmp_dir/nonexistent.jsonl")"

: > "$log"
assert_eq "empty log yields no blocked items" "[]" "$(blocked_items "$log")"

cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-01","detail":"already done on main"}
{"ts":"2026-07-16T09:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-02","detail":"premise wrong"}
{"ts":"2026-07-16T10:00:00Z","event":"unblocked","item":"R-02"}
{"ts":"2026-07-16T11:00:00Z","event":"attempt-failed","stage":"coordinator","detail":"unparseable final message"}
EOF

assert_eq "an item's latest attempt-failed blocks it" \
  "R-01" "$(blocked_items "$log" | jq -r '.[].item')"

assert_eq "a later unblocked event clears the item" \
  "0" "$(blocked_items "$log" | jq '[.[] | select(.item == "R-02")] | length')"

assert_eq "an itemless failure blocks nothing" \
  "1" "$(blocked_items "$log" | jq 'length')"

assert_eq "the blocking detail is carried through for the Co-Ordinator to judge" \
  "already done on main" "$(blocked_items "$log" | jq -r '.[].detail')"

# Ordering is by timestamp, not by file order: a re-blocked item stays blocked
# even if its unblocked event happens to appear later in the file.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T10:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-03","detail":"still wrong"}
{"ts":"2026-07-16T09:00:00Z","event":"unblocked","item":"R-03"}
EOF
assert_eq "latest event wins regardless of file order" \
  "R-03" "$(blocked_items "$log" | jq -r '.[].item')"

# An item id is only unique within its repo: both repos carry a
# dependabot-alert-1, and blocking one must not starve the other.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T10:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/a","item":"dependabot-alert-1","detail":"a"}
{"ts":"2026-07-16T10:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/b","item":"dependabot-alert-1","detail":"b"}
{"ts":"2026-07-16T11:00:00Z","event":"unblocked","repo":"o/b","item":"dependabot-alert-1"}
EOF
assert_eq "a repo-scoped unblock clears only that repo's item" \
  "o/a" "$(blocked_items "$log" | jq -r '.[].repo')"

# The Co-Ordinator reports unblocked as a bare item id, and a human may append
# one by hand — neither carries a repo, so it has to clear the item anywhere.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T10:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/a","item":"dependabot-alert-1","detail":"a"}
{"ts":"2026-07-16T10:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/b","item":"dependabot-alert-1","detail":"b"}
{"ts":"2026-07-16T11:00:00Z","event":"unblocked","item":"dependabot-alert-1"}
EOF
assert_eq "a repo-less unblock clears the item in every repo" \
  "0" "$(blocked_items "$log" | jq 'length')"

# --- blocked_items: recheck_clean_ts (requirement 18a, TD-PPagop-26072801) ---

cat > "$log" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","detail":"waiting on maintainer"}
EOF
assert_eq "a block with no recheck-clean event carries no recheck_clean_ts" \
  "null" "$(blocked_items "$log" | jq -r '.[0].recheck_clean_ts // "null"')"

cat > "$log" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","detail":"waiting on maintainer"}
{"ts":"2026-07-29T09:00:00Z","event":"recheck-clean","item":"52"}
EOF
assert_eq "a recheck-clean event is folded into the block as recheck_clean_ts" \
  "2026-07-29T09:00:00Z" "$(blocked_items "$log" | jq -r '.[0].recheck_clean_ts')"
assert_eq "recheck-clean does not clear the block" \
  "1" "$(blocked_items "$log" | jq 'length')"

# The newest recheck-clean wins, exactly as the newest attempt-failed does.
cat > "$log" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","detail":"waiting on maintainer"}
{"ts":"2026-07-29T09:00:00Z","event":"recheck-clean","item":"52"}
{"ts":"2026-07-30T10:00:00Z","event":"recheck-clean","item":"52"}
EOF
assert_eq "the newest recheck-clean ts is the one carried" \
  "2026-07-30T10:00:00Z" "$(blocked_items "$log" | jq -r '.[0].recheck_clean_ts')"

# A repo-less event — older logs, or a report the Script accepted as a bare
# id — is the tolerated fallback (requirement 33): it folds into every
# same-numbered item across repos, leaning on the emitting Co-Ordinator
# having re-read all of them.
cat > "$log" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/a","item":"52","detail":"a"}
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/b","item":"52","detail":"b"}
{"ts":"2026-07-29T09:00:00Z","event":"recheck-clean","item":"52"}
EOF
assert_eq "a repo-less recheck-clean folds into every repo's same-numbered item" \
  "2" "$(blocked_items "$log" | jq '[.[] | select(.recheck_clean_ts == "2026-07-29T09:00:00Z")] | length')"

# The canonical shape (requirements 20 and 33): a repo-scoped recheck-clean
# folds into that repo's item alone, so a marker can only suppress the one
# issue its Co-Ordinator actually read.
cat > "$log" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/a","item":"52","detail":"a"}
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/b","item":"52","detail":"b"}
{"ts":"2026-07-29T09:00:00Z","event":"recheck-clean","repo":"o/a","item":"52"}
EOF
assert_eq "a repo-scoped recheck-clean folds into only that repo's item" \
  "o/a" "$(blocked_items "$log" | jq -r '[.[] | select(.recheck_clean_ts != null)][0].repo')"

# --- requirement 18a: the mandatory re-check loop, end to end (check 7a, ---
# --- TD-PPagop-26080102) ---
#
# The fold above proves `blocked_items` carries `ts` and `recheck_clean_ts`
# correctly; this section proves the two-timestamp comparison those fields
# exist for — prompts/coordinator.md's "A blocked issue with fresh evidence
# must be re-read" — round-trips exactly as check 7 round-trips the general
# blocked case. The comparison itself is the Co-Ordinator's own judgement,
# not shell code, so `needs_mandatory_reread` below is not production logic:
# it mirrors the documented rule verbatim so the real data `blocked_items`
# computes can be checked against it.
needs_mandatory_reread() {
  local updated_at="$1" block_json="$2"
  jq -n --arg u "$updated_at" --argjson b "$block_json" \
    '(([$b.ts] + (if $b.recheck_clean_ts then [$b.recheck_clean_ts] else [] end)) | max) as $threshold
     | $u > $threshold'
}

cat > "$log" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","detail":"waiting on maintainer"}
EOF
block="$(blocked_items "$log" | jq -c '.[0]')"

# Half 1: a comment landing after the block's own `ts` forces the re-read.
assert_eq "half 1: an issue updated after the block's ts is due a mandatory re-read" \
  "true" "$(needs_mandatory_reread "2026-07-29T10:00:00Z" "$block")"
assert_eq "an issue quiet since the block needs no re-read" \
  "false" "$(needs_mandatory_reread "2026-07-28T07:00:00Z" "$block")"

# The Co-Ordinator re-read the thread found above, judged the blocker still
# holds, and reported `recheck_clean` — the Script logs it, and the next
# cycle's `blocked_items` folds it in.
cat >> "$log" <<'EOF'
{"ts":"2026-07-29T10:30:00Z","event":"recheck-clean","repo":"o/r","item":"52"}
EOF
block="$(blocked_items "$log" | jq -c '.[0]')"

# Half 2: the same, unchanged `updated_at` that demanded a re-read a moment
# ago no longer does, now that the marker covers it — the thread said
# nothing new, so it must not be paid for twice.
assert_eq "half 2: a recheck-clean confirming the still-quiet thread suppresses the next re-read" \
  "false" "$(needs_mandatory_reread "2026-07-29T10:00:00Z" "$block")"

# And the marker's suppression is not permanent: a further comment past the
# recheck-clean makes the re-read mandatory again.
assert_eq "the thread moving again past the recheck-clean makes the re-read mandatory once more" \
  "true" "$(needs_mandatory_reread "2026-07-30T00:00:00Z" "$block")"

# --- void_items (requirement 34c) ---

assert_eq "missing log yields no void items" "[]" "$(void_items "$tmp_dir/nonexistent.jsonl")"

: > "$log"
assert_eq "empty log yields no void items" "[]" "$(void_items "$log")"

# The production sequence this state exists to stop, replayed exactly: the
# Implementor finds R-02 already done; the next Co-Ordinator sees the work is
# done and reports it unblocked. Under the old single-state design that freed
# R-02 for reselection every cycle, forever. `unblocked` must not touch a void.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T09:03:10Z","event":"item-void","stage":"implementor","repo":"o/poetic","item":"review-2026-07-11-R-02","detail":"already implemented on main","evidence":"e0ac584"}
{"ts":"2026-07-16T09:12:21Z","event":"unblocked","item":"review-2026-07-11-R-02"}
EOF
assert_eq "an unblocked event cannot clear a void item" \
  "review-2026-07-11-R-02" "$(void_items "$log" | jq -r '.[].item')"
assert_eq "a void item is not also reported as blocked" \
  "0" "$(blocked_items "$log" | jq 'length')"
assert_eq "the void evidence is carried through" \
  "e0ac584" "$(void_items "$log" | jq -r '.[].evidence')"

# Only a human, appending unvoided by hand, may reopen one.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T09:03:10Z","event":"item-void","stage":"implementor","repo":"o/poetic","item":"R-02","detail":"already done"}
{"ts":"2026-07-17T09:00:00Z","event":"unvoided","item":"R-02"}
EOF
assert_eq "a later unvoided event reopens the item" "0" "$(void_items "$log" | jq 'length')"

# Re-voiding after an unvoid: the human reopened it, the Implementor looked
# again and still found no work. Latest event wins, as for blocked.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T09:03:10Z","event":"item-void","stage":"implementor","repo":"o/poetic","item":"R-02","detail":"already done"}
{"ts":"2026-07-17T09:00:00Z","event":"unvoided","item":"R-02"}
{"ts":"2026-07-18T09:00:00Z","event":"item-void","stage":"implementor","repo":"o/poetic","item":"R-02","detail":"still nothing to do"}
EOF
assert_eq "an item can be voided again after being unvoided" \
  "still nothing to do" "$(void_items "$log" | jq -r '.[].detail')"

# The two states are independent channels over the same log.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-01","detail":"dep unmerged"}
{"ts":"2026-07-16T09:00:00Z","event":"item-void","stage":"implementor","repo":"o/r","item":"R-02","detail":"already done"}
EOF
assert_eq "blocked and void are separate lists: blocked" "R-01" "$(blocked_items "$log" | jq -r '.[].item')"
assert_eq "blocked and void are separate lists: void" "R-02" "$(void_items "$log" | jq -r '.[].item')"

# An itemless void pins nothing, exactly as an itemless failure blocks nothing.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T09:00:00Z","event":"item-void","stage":"coordinator","detail":"no item named"}
EOF
assert_eq "an itemless void voids nothing" "0" "$(void_items "$log" | jq 'length')"

# A void must not be killed by a malformed line elsewhere in the log, or one
# truncated append would silently reopen every void item.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T09:00:00Z","event":"item-void","stage":"implementor","repo":"o/r","item":"R-02","detail":"already done"}
{"ts":"2026-07-16T09:01:00Z","event":"cycle-e
EOF
assert_eq "a malformed trailing line does not strand void items" \
  "R-02" "$(void_items "$log" | jq -r '.[].item')"

# --- void_object_closed_items (requirement 34k) ---

assert_eq "missing log yields no closed-void items" "[]" \
  "$(void_object_closed_items "$tmp_dir/nonexistent.jsonl")"

: > "$log"
assert_eq "empty log yields no closed-void items" "[]" "$(void_object_closed_items "$log")"

cat > "$log" <<'EOF'
{"ts":"2026-08-08T09:00:00Z","event":"void-object-closed","repo":"o/r","item":"198","kind":"issue","closed_by":"sweep"}
EOF
assert_eq "a closed void item is recorded" \
  '[{"repo":"o/r","item":"198"}]' "$(void_object_closed_items "$log")"

# Once actioned, an item stays actioned even if it recurs — there is no
# clearing event for this fact, unlike item-void/unvoided.
cat > "$log" <<'EOF'
{"ts":"2026-08-08T09:00:00Z","event":"void-object-closed","repo":"o/r","item":"198","kind":"issue","closed_by":"sweep"}
{"ts":"2026-08-08T10:00:00Z","event":"void-object-closed","repo":"o/r","item":"198","kind":"issue","closed_by":"already"}
EOF
assert_eq "a repeated closure still yields exactly one entry" \
  "1" "$(void_object_closed_items "$log" | jq 'length')"

# An itemless or repoless line pins nothing, exactly as for the other states.
cat > "$log" <<'EOF'
{"ts":"2026-08-08T09:00:00Z","event":"void-object-closed","item":"198","kind":"issue"}
EOF
assert_eq "a repoless closure record is dropped" "0" "$(void_object_closed_items "$log" | jq 'length')"

# --- open_blocked_items (requirement 34h) ---
# Where the two states meet, void wins. The shape is not exotic: `item-void`
# clears no block, so every `void` verdict the Enabler reaches leaves the
# `attempt-failed` before it standing, and an item finished with stays in the
# blocked set for as long as the log remembers it. The dashboard listed fifteen
# such items as blocked, one of them a fortnight after the pipeline had closed
# the book on it.

assert_eq "missing log yields no open blocked items" "[]" \
  "$(open_blocked_items "$tmp_dir/nonexistent.jsonl")"

: > "$log"
assert_eq "empty log yields no open blocked items" "[]" "$(open_blocked_items "$log")"

cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-01","detail":"dep unmerged"}
{"ts":"2026-07-16T09:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-02","detail":"dep unmerged"}
{"ts":"2026-07-18T09:00:00Z","event":"item-void","repo":"o/r","item":"R-02","detail":"already done","evidence":"e0ac584"}
EOF
assert_eq "a blocked item a later void covers is not open" \
  "R-01" "$(open_blocked_items "$log" | jq -r '.[].item')"
# The raw rule is untouched: the Co-Ordinator is handed both lists and
# requirement 34c means it to see the item under the state that binds it.
assert_eq "blocked_items still reports the raw requirement 34 set" \
  "2" "$(blocked_items "$log" | jq 'length')"
assert_eq "and the void item is still void" \
  "R-02" "$(void_items "$log" | jq -r '.[].item')"

# Order is not the rule — the mark is. A void recorded *before* the block still
# covers it, because void is terminal until a human says otherwise; only an
# `unvoided` reopens the item, and then the block underneath it stands again.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"item-void","repo":"o/r","item":"R-03","detail":"already done"}
{"ts":"2026-07-17T08:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-03","detail":"dep unmerged"}
EOF
assert_eq "a void older than the block still covers it" "0" \
  "$(open_blocked_items "$log" | jq 'length')"

cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-03","detail":"dep unmerged"}
{"ts":"2026-07-17T08:00:00Z","event":"item-void","repo":"o/r","item":"R-03","detail":"already done"}
{"ts":"2026-07-18T08:00:00Z","event":"unvoided","item":"R-03"}
EOF
assert_eq "a human's unvoided returns the item to the blocked list" \
  "R-03" "$(open_blocked_items "$log" | jq -r '.[].item')"

# Requirement 34's matching rule, not a stricter one: either half of the void
# pair may be hand-appended by a human, who has no repo to hand.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/a","item":"R-04","detail":"dep unmerged"}
{"ts":"2026-07-16T08:00:01Z","event":"attempt-failed","stage":"implementor","repo":"o/b","item":"R-04","detail":"dep unmerged"}
{"ts":"2026-07-17T08:00:00Z","event":"item-void","item":"R-04","detail":"already done"}
EOF
assert_eq "a repo-less void covers the item in every repo" "0" \
  "$(open_blocked_items "$log" | jq 'length')"

cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/a","item":"R-05","detail":"dep unmerged"}
{"ts":"2026-07-16T08:00:01Z","event":"attempt-failed","stage":"implementor","repo":"o/b","item":"R-05","detail":"dep unmerged"}
{"ts":"2026-07-17T08:00:00Z","event":"item-void","repo":"o/a","item":"R-05","detail":"already done"}
EOF
assert_eq "a repo-scoped void covers only that repo's item" \
  "o/b" "$(open_blocked_items "$log" | jq -r '.[].repo')"

# The entry is `blocked_items`' entry, unchanged — the Publisher's projection
# and requirement 18a's marker both read fields off it.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"41","detail":"needs specifying","kind":"needs-refinement"}
{"ts":"2026-07-17T08:00:00Z","event":"recheck-clean","repo":"o/r","item":"41"}
EOF
assert_eq "an open block keeps its kind" \
  "needs-refinement" "$(open_blocked_items "$log" | jq -r '.[0].kind')"
assert_eq "and its recheck_clean_ts" \
  "2026-07-17T08:00:00Z" "$(open_blocked_items "$log" | jq -r '.[0].recheck_clean_ts')"

# Same tolerance as every other extract: the caller runs under `set -e`, and a
# torn append must not empty the panel that says the pipeline is stuck.
cat > "$log" <<'EOF'
{"ts":"2026-07-16T08:00:00Z","event":"attempt-failed","stage":"implementor","repo":"o/r","item":"R-06","detail":"dep unmerged"}
{"ts":"2026-07-16T09:01:00Z","event":"cycle-e
EOF
assert_eq "a malformed trailing line does not strand open blocked items" \
  "R-06" "$(open_blocked_items "$log" | jq -r '.[].item')"
assert_eq "stdin reads the same as a file" \
  "R-06" "$(open_blocked_items - < "$log" | jq -r '.[].item')"

# --- reviewer_complexity (requirement 8a) ---
# The reviewer tier follows the highest valid grade offered by the summary and
# the PR's labels; garbage degrades to nothing; no grade at all falls back on
# the Co-Ordinator's trivial classification.

assert_eq "summary grade alone is used" \
  "medium" "$(reviewer_complexity "medium" 0)"
assert_eq "label high outranks summary medium (raise-never-lower holds at the decision point)" \
  "high" "$(reviewer_complexity "medium" 0 "high")"
assert_eq "summary high outranks label medium" \
  "high" "$(reviewer_complexity "high" 0 "medium")"
assert_eq "label low does not drag a medium summary down" \
  "medium" "$(reviewer_complexity "medium" 0 "low")"
assert_eq "several labels: the highest wins" \
  "high" "$(reviewer_complexity "" 0 "low" "high" "medium")"
assert_eq "an unknown grade contributes nothing" \
  "low" "$(reviewer_complexity "urgent" 0 "low")"
assert_eq "all-garbage grades fall back to the default tier" \
  "medium" "$(reviewer_complexity "banana" 0 "urgent")"
assert_eq "no grade at all: non-trivial work order defaults to medium" \
  "medium" "$(reviewer_complexity "" 0)"
assert_eq "no grade at all: trivial work order is low by classification" \
  "low" "$(reviewer_complexity "" 1)"
assert_eq "a real grade outranks the trivial fallback" \
  "high" "$(reviewer_complexity "high" 1)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
