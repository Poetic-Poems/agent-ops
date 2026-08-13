#!/usr/bin/env bash
#
# test/cycle-state.test.sh — self-contained regression test for
# lib/cycle-state.sh, plus (requirement 3u, issue #320) the agent-cycle.sh
# functions that read this file's `blocked_items`/`void_items` output to
# decide what the Co-Ordinator is allowed to see, since that decision is what
# requirement 18a's mandatory re-check depends on and belongs alongside it.
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
# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/lib/work-gone.sh"
# shellcheck source=lib/void-liveness.sh
. "$SCRIPT_DIR/lib/void-liveness.sh"

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

# --- retire_void_items (requirement 34n) ---
# A fixed NOW_EPOCH throughout, never `date +%s`: the test must not depend on
# when it happens to run. 2026-08-13T00:00:00Z; the boundary case sits exactly
# 30 days before it (2026-07-14T00:00:00Z), the "old" case 35 days before, and
# the "young" case 10 days before.
now_epoch=1786579200
actioned_one='[{"repo":"o/r","item":"1"}]'

void_all='[
  {"ts":"2026-07-09T00:00:00Z","repo":"o/r","item":"1","detail":"actioned and old"},
  {"ts":"2026-07-14T00:00:00Z","repo":"o/r","item":"boundary","detail":"actioned, exactly 30d old"},
  {"ts":"2026-08-03T00:00:00Z","repo":"o/r","item":"2","detail":"actioned but young"},
  {"ts":"2026-07-09T00:00:00Z","repo":"o/r","item":"3","detail":"old but not actioned"},
  {"repo":"o/r","item":"4","detail":"no ts at all, actioned would be irrelevant"},
  {"ts":"not-a-date","repo":"o/r","item":"5","detail":"unparseable ts"},
  {"ts":"2026-07-09T00:00:00Z","item":"6","detail":"repoless, hand-appended, old"}
]'
actioned_all=$(jq -nc '[{"repo":"o/r","item":"1"},{"repo":"o/r","item":"boundary"},
  {"repo":"o/r","item":"2"},{"repo":"o/r","item":"4"},{"repo":"o/r","item":"5"},
  {"repo":"o/r","item":"6"}]')

assert_eq "actioned and old (30d default): the two matching entries retire, five remain" \
  "5" "$(retire_void_items "$void_all" "$actioned_all" 30 "$now_epoch" | jq 'length')"
assert_eq "exactly the threshold age retires (>=, not >)" \
  "0" "$(retire_void_items "$void_all" "$actioned_all" 30 "$now_epoch" | jq '[.[] | select(.item == "boundary")] | length')"
assert_eq "actioned but younger than the threshold is kept" \
  "1" "$(retire_void_items "$void_all" "$actioned_all" 30 "$now_epoch" | jq '[.[] | select(.item == "2")] | length')"
assert_eq "old but not in the actioned set is kept" \
  "1" "$(retire_void_items "$void_all" "$actioned_one" 30 "$now_epoch" | jq '[.[] | select(.item == "3")] | length')"
assert_eq "no ts at all is kept even when actioned and the threshold is low" \
  "1" "$(retire_void_items "$void_all" "$actioned_all" 1 "$now_epoch" | jq '[.[] | select(.item == "4")] | length')"
assert_eq "an unparseable ts is kept even when actioned" \
  "1" "$(retire_void_items "$void_all" "$actioned_all" 30 "$now_epoch" | jq '[.[] | select(.item == "5")] | length')"
assert_eq "a repoless (hand-appended) void never matches an actioned pair, and is kept" \
  "1" "$(retire_void_items "$void_all" "$actioned_all" 30 "$now_epoch" | jq '[.[] | select(.item == "6")] | length')"

assert_eq "void_retire_after_days 0 disables retirement outright" \
  "$(jq -c . <<<"$void_all")" "$(retire_void_items "$void_all" "$actioned_all" 0 "$now_epoch" | jq -c .)"
assert_eq "a non-numeric threshold degrades to disabled, not an error" \
  "$(jq -c . <<<"$void_all")" "$(retire_void_items "$void_all" "$actioned_all" "banana" "$now_epoch" | jq -c .)"

assert_eq "an empty actioned set retires nothing" \
  "$(jq -c . <<<"$void_all")" "$(retire_void_items "$void_all" "[]" 30 "$now_epoch" | jq -c .)"

assert_eq "malformed void_json is returned verbatim rather than raising" \
  "not valid json" "$(retire_void_items "not valid json" "$actioned_all" 30 "$now_epoch")"
assert_eq "malformed actioned_json fails safe to no retirement" \
  "$(jq -c . <<<"$void_all")" "$(retire_void_items "$void_all" "not valid json" 30 "$now_epoch" | jq -c .)"

# The shared void/blocked pairing (LATEST_UNRESOLVED_JQ) is what every
# internal reader — open_blocked_items, and (via ENABLER_ELIGIBLE_JQ and
# REFINEMENTS_MAP_JQ) enabler_eligible_items and refinements_map — recomputes
# straight off the raw log, with no retirement arguments anywhere in their
# signatures. Retirement is exclusively a property of the extract a caller
# builds by calling retire_void_items on void_items' own output; it is not a
# second definition of void, so an item retired from one cycle's delivered
# extract still cannot resurface as blocked.
cat > "$log" <<'EOF'
{"ts":"2026-06-01T00:00:00Z","event":"item-void","stage":"implementor","repo":"o/r","item":"7","detail":"already done"}
EOF
assert_eq "a void old enough to retire is still void, not blocked, on the raw log" \
  "0" "$(open_blocked_items "$log" | jq 'length')"
assert_eq "…and still the one entry void_items reports, unretired" \
  "7" "$(void_items "$log" | jq -r '.[].item')"

# --- void_retired_items + subtract_retired_voids (requirement 34n's memory) ---
# `void-retired` is a fact like `void-object-closed`, with one addition: the
# latest ts per pair is kept, because the subtraction is ts-ordered — an item
# voided afresh *after* its old verdict retired must re-enter the extract.
cat > "$log" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","event":"void-retired","repo":"o/r","item":"1","void_ts":"2026-06-01T00:00:00Z","by":"object-closed"}
{"ts":"2026-08-05T00:00:00Z","event":"void-retired","repo":"o/r","item":"1","void_ts":"2026-06-01T00:00:00Z","by":"object-closed"}
{"ts":"2026-08-01T00:00:00Z","event":"void-retired","repo":"o/r","item":"2","void_ts":"2026-05-01T00:00:00Z","by":"register-resolved"}
{"ts":"2026-08-01T00:00:00Z","event":"void-retired","repo":"o/other","item":"1","void_ts":"2026-05-01T00:00:00Z","by":"object-closed"}
{"ts":"2026-08-01T00:00:00Z","event":"void-retired","item":"repoless"}
{"ts":"2026-08-01T00:00:00Z","event":"void-retired","repo":"o/r"}
{"ts":"2026-08-01T00:00:00Z","event":"item-void","repo":"o/r","item":"unrelated","detail":"not a retirement"}
EOF
assert_eq "void_retired_items: one record per pair, repoless and itemless dropped" \
  "3" "$(void_retired_items "$log" | jq 'length')"
assert_eq "void_retired_items: the latest ts per pair wins" \
  "2026-08-05T00:00:00Z" \
  "$(void_retired_items "$log" | jq -r '.[] | select(.repo == "o/r" and .item == "1") | .ts')"
assert_eq "void_retired_items: a missing or empty log is an empty set" \
  "[]" "$(void_retired_items /nonexistent/log.jsonl)"

retired_one='[{"repo":"o/r","item":"1","ts":"2026-08-01T00:00:00Z"}]'
void_masked='[{"ts":"2026-06-01T00:00:00Z","repo":"o/r","item":"1","detail":"voided before retirement"}]'
void_revoided='[{"ts":"2026-08-10T00:00:00Z","repo":"o/r","item":"1","detail":"voided afresh after retirement"}]'
void_other_repo='[{"ts":"2026-06-01T00:00:00Z","repo":"o/else","item":"1","detail":"same id, different repo"}]'

assert_eq "subtract_retired_voids: a pair retired after its void ts is dropped" \
  "0" "$(subtract_retired_voids "$void_masked" "$retired_one" | jq 'length')"
assert_eq "subtract_retired_voids: a fresh item-void after the retirement is kept" \
  "1" "$(subtract_retired_voids "$void_revoided" "$retired_one" | jq 'length')"
assert_eq "subtract_retired_voids: the match is repo-scoped, same-id other-repo voids are kept" \
  "1" "$(subtract_retired_voids "$void_other_repo" "$retired_one" | jq 'length')"
assert_eq "subtract_retired_voids: an empty retired set subtracts nothing" \
  "$(jq -c . <<<"$void_masked")" "$(subtract_retired_voids "$void_masked" "[]" | jq -c .)"
assert_eq "subtract_retired_voids: malformed void_json is returned verbatim rather than raising" \
  "not valid json" "$(subtract_retired_voids "not valid json" "$retired_one")"
assert_eq "subtract_retired_voids: a malformed retired set fails safe to no subtraction" \
  "$(jq -c . <<<"$void_masked")" "$(subtract_retired_voids "$void_masked" "not valid json" | jq -c .)"

# Round-trip on one log: the raw void definition never learns about
# retirement — void_items still reports the entry (the dashboard's view, and
# what keeps requirement 34c intact) — while the extract a caller builds by
# subtracting the recorded set no longer carries it, until a fresh verdict
# post-dates the retirement and re-enters on its own terms.
cat > "$log" <<'EOF'
{"ts":"2026-06-01T00:00:00Z","event":"item-void","stage":"implementor","repo":"o/r","item":"8","detail":"already done"}
{"ts":"2026-07-01T00:00:00Z","event":"void-retired","repo":"o/r","item":"8","void_ts":"2026-06-01T00:00:00Z","by":"object-closed"}
EOF
assert_eq "round-trip: void_items still reports a retired item, unretired" \
  "8" "$(void_items "$log" | jq -r '.[].item')"
assert_eq "round-trip: the recorded subtraction removes it from the extract" \
  "0" "$(subtract_retired_voids "$(void_items "$log")" "$(void_retired_items "$log")" | jq 'length')"
cat >> "$log" <<'EOF'
{"ts":"2026-07-15T00:00:00Z","event":"item-void","stage":"enabler","repo":"o/r","item":"8","detail":"voided again after the object was reopened"}
EOF
assert_eq "round-trip: a fresh verdict after the retirement re-enters the extract" \
  "1" "$(subtract_retired_voids "$(void_items "$log")" "$(void_retired_items "$log")" | jq 'length')"

# --- void_liveness_actioned (requirement 34n's liveness rule, --------------
# --- TD-PPagop-26081303) ----------------------------------------------------
#
# The four shapes the cycle already gathers as structured data each cycle:
# an alert ref, a register-hygiene ref, a failed-run ref and a merge-conflict
# ref (the addendum's `pr-<n>-conflict-<head-sha>` — "merge-conflict-
# resolved" below). Each is tested for both halves of the rule: liveness (an
# id still present in this cycle's own gather is never actioned, however old)
# and the gather's own success (an id absent from a gather that did not
# succeed decides nothing either).
void_shapes='[
  {"repo":"o/r","item":"dependabot-alert-1","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"dependabot-alert-2","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"code-scanning-alert-9","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"register-hygiene-aaaaaaaaaaaa","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"register-hygiene-bbbbbbbbbbbb","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"failed-run-ci","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"failed-run-sync-framework","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"pr-12-conflict-1a2b3c4d5e6f","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"pr-13-conflict-9f8e7d6c5b4a","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/other","item":"dependabot-alert-1","ts":"2026-07-01T00:00:00Z"},
  {"item":"dependabot-alert-1","ts":"2026-07-01T00:00:00Z"}
]'
gather_map='{
  "o/r": {
    "alert": {"ok": true, "ids": ["dependabot-alert-1"]},
    "register-hygiene": {"ok": true, "ids": ["register-hygiene-aaaaaaaaaaaa"]},
    "failed-run": {"ok": false, "ids": []},
    "merge-conflict": {"ok": true, "ids": ["pr-12-conflict-1a2b3c4d5e6f"]}
  }
}'
liveness_out="$(void_liveness_actioned "$void_shapes" "$gather_map")"

assert_eq "alert: still present in this cycle's gather is never actioned" \
  "0" "$(jq '[.[] | select(.item == "dependabot-alert-1")] | length' <<<"$liveness_out")"
assert_eq "alert: absent from a successful gather is actioned" \
  "liveness-alert" "$(jq -r '.[] | select(.item == "dependabot-alert-2") | .by' <<<"$liveness_out")"
assert_eq "alert: the code-scanning shape is recognised too" \
  "liveness-alert" "$(jq -r '.[] | select(.item == "code-scanning-alert-9") | .by' <<<"$liveness_out")"
assert_eq "register-hygiene: still present is never actioned" \
  "0" "$(jq '[.[] | select(.item == "register-hygiene-aaaaaaaaaaaa")] | length' <<<"$liveness_out")"
assert_eq "register-hygiene: absent from a successful gather is actioned" \
  "liveness-register-hygiene" \
  "$(jq -r '.[] | select(.item == "register-hygiene-bbbbbbbbbbbb") | .by' <<<"$liveness_out")"
assert_eq "failed-run: absent but the gather did not succeed decides nothing" \
  "0" "$(jq '[.[] | select(.item == "failed-run-ci")] | length' <<<"$liveness_out")"
assert_eq "  ... neither failed-run entry is actioned while ok is false" \
  "0" "$(jq '[.[] | select(.item == "failed-run-sync-framework")] | length' <<<"$liveness_out")"

# The failed-run shape's own liveness half, which the map above can only test
# for `ok: false`: the same two ids against a succeeded gather that still
# names one of the two workflows.
liveness_fr_out="$(void_liveness_actioned "$void_shapes" '{
  "o/r": {"failed-run": {"ok": true, "ids": ["failed-run-ci"]}}
}')"
assert_eq "failed-run: a workflow still failing this cycle is never actioned" \
  "0" "$(jq '[.[] | select(.item == "failed-run-ci")] | length' <<<"$liveness_fr_out")"
assert_eq "failed-run: one absent from a succeeded gather is actioned" \
  "liveness-failed-run" \
  "$(jq -r '.[] | select(.item == "failed-run-sync-framework") | .by' <<<"$liveness_fr_out")"
assert_eq "  ... and a shape the partial map says nothing about decides nothing" \
  "0" "$(jq '[.[] | select(.item == "dependabot-alert-2")] | length' <<<"$liveness_fr_out")"

assert_eq "merge-conflict-resolved: a conflict still reported by this cycle's gather is kept" \
  "0" "$(jq '[.[] | select(.item == "pr-12-conflict-1a2b3c4d5e6f")] | length' <<<"$liveness_out")"
assert_eq "merge-conflict-resolved: a conflict no longer reported is actioned" \
  "liveness-merge-conflict" \
  "$(jq -r '.[] | select(.item == "pr-13-conflict-9f8e7d6c5b4a") | .by' <<<"$liveness_out")"
assert_eq "a same-id void in a different repo, absent from GATHER_JSON, decides nothing" \
  "0" "$(jq '[.[] | select(.repo == "o/other")] | length' <<<"$liveness_out")"
assert_eq "a repo-less (hand-appended) void matches no shape's repo lookup" \
  "0" "$(jq '[.[] | select(.repo == "")] | length' <<<"$liveness_out")"

assert_eq "an id shaped like nothing this rule knows decides nothing" \
  "0" "$(void_liveness_actioned '[{"repo":"o/r","item":"TD26070101","ts":"2026-07-01T00:00:00Z"}]' "$gather_map" | jq 'length')"
assert_eq "an empty GATHER_JSON actions nothing" \
  "0" "$(void_liveness_actioned "$void_shapes" '{}' | jq 'length')"
assert_eq "malformed VOID_JSON fails safe to []" \
  "[]" "$(void_liveness_actioned "not valid json" "$gather_map")"
assert_eq "malformed GATHER_JSON fails safe to []" \
  "[]" "$(void_liveness_actioned "$void_shapes" "not valid json")"

# The age half of requirement 34n's rule is `retire_void_items` itself
# (already covered above); this pins that a liveness verdict feeds it exactly
# like any other actioned pair — young stays, old-and-actioned retires — and
# that a prior `void-retired` record still masks it via
# `subtract_retired_voids`, the same interaction the round-trip block above
# proves for the register-resolved path.
liveness_now_epoch=1786579200
liveness_void='[
  {"ts":"2026-07-01T00:00:00Z","repo":"o/r","item":"dependabot-alert-101","detail":"actioned and old"},
  {"ts":"2026-08-10T00:00:00Z","repo":"o/r","item":"dependabot-alert-102","detail":"actioned but young"}
]'
liveness_gather='{"o/r":{"alert":{"ok":true,"ids":[]},"register-hygiene":{"ok":true,"ids":[]},"failed-run":{"ok":true,"ids":[]},"merge-conflict":{"ok":true,"ids":[]}}}'
liveness_actioned="$(void_liveness_actioned "$liveness_void" "$liveness_gather")"
assert_eq "liveness feeding retire_void_items: actioned and old retires" \
  "0" "$(retire_void_items "$liveness_void" "$liveness_actioned" 30 "$liveness_now_epoch" \
         | jq '[.[] | select(.item == "dependabot-alert-101")] | length')"
assert_eq "liveness feeding retire_void_items: actioned but young is kept" \
  "1" "$(retire_void_items "$liveness_void" "$liveness_actioned" 30 "$liveness_now_epoch" \
         | jq '[.[] | select(.item == "dependabot-alert-102")] | length')"

cat > "$log" <<'EOF'
{"ts":"2026-06-01T00:00:00Z","event":"item-void","stage":"coordinator","repo":"o/r","item":"dependabot-alert-101","detail":"already closed"}
{"ts":"2026-08-01T00:00:00Z","event":"void-retired","repo":"o/r","item":"dependabot-alert-101","void_ts":"2026-06-01T00:00:00Z","by":"liveness-alert"}
EOF
assert_eq "a prior void-retired record masks a liveness-retired id from the extract" \
  "0" "$(subtract_retired_voids "$(void_items "$log")" "$(void_retired_items "$log")" | jq 'length')"

# --- void_review_plan_actioned (requirement 34n's on-demand-reader rule, ---
# --- TD-PPagop-26081303) -----------------------------------------------------
#
# The two shapes the cycle does not pre-fetch: a project-review ref and an
# implementation-plan task id, actioned by the same on-demand readers
# requirement 34i already uses for the blocked set (a merged pull request, a
# checked task-list box).
review_plan_void='[
  {"repo":"o/r","item":"review-2026-07-11-R-02","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"review-2026-07-11-R-03","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"W10-breach-handling","ts":"2026-07-01T00:00:00Z"},
  {"repo":"o/r","item":"W10-still-open","ts":"2026-07-01T00:00:00Z"}
]'
review_status='{"o/r":{"review-2026-07-11-R-02":"merged"}}'
plan_status='{"o/r":{"W10-breach-handling":"done","W10-still-open":"open"}}'
rp_out="$(void_review_plan_actioned "$review_plan_void" "$review_status" "$plan_status")"

assert_eq "a review ref named by a merged pull request is actioned" \
  "review-merged" "$(jq -r '.[] | select(.item == "review-2026-07-11-R-02") | .by' <<<"$rp_out")"
assert_eq "a review ref with no merged pull request is kept" \
  "0" "$(jq '[.[] | select(.item == "review-2026-07-11-R-03")] | length' <<<"$rp_out")"
assert_eq "a plan task whose checkbox reads done is actioned" \
  "plan-task-done" "$(jq -r '.[] | select(.item == "W10-breach-handling") | .by' <<<"$rp_out")"
assert_eq "a plan task whose checkbox reads open is kept" \
  "0" "$(jq '[.[] | select(.item == "W10-still-open")] | length' <<<"$rp_out")"
assert_eq "malformed VOID_JSON fails safe to []" \
  "[]" "$(void_review_plan_actioned "not valid json" "$review_status" "$plan_status")"
assert_eq "malformed status maps fail safe to []" \
  "[]" "$(void_review_plan_actioned "$review_plan_void" "not valid json" "not valid json")"

rp_now_epoch=1786579200
rp_void='[{"ts":"2026-07-01T00:00:00Z","repo":"o/r","item":"review-2026-07-11-R-02","detail":"actioned and old"}]'
rp_actioned="$(void_review_plan_actioned "$rp_void" "$review_status" "$plan_status")"
assert_eq "review-plan liveness feeding retire_void_items: actioned and old retires" \
  "0" "$(retire_void_items "$rp_void" "$rp_actioned" 30 "$rp_now_epoch" | jq 'length')"

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

# --- exclude_blocked_or_void_items / exclude_blocked_or_void_issues / -----------
# --- coordinator_blocked_view, extended to every pre-fetched band -------------
# --- (requirement 3u, issue #320) ----------------------------------------------
#
# Lifted whole out of agent-cycle.sh, the same way
# test/tech-debt-eligibility.test.sh lifts exclude_blocked_or_void_items — a
# change to the real functions is what these assertions exercise, not a
# reimplementation that could drift from them.

extract_function() {  # extract_function <name>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1 }
    on                          { print }
    on && /^}$/                 { exit }
  ' "$SCRIPT_DIR/agent-cycle.sh"
}

for fn in exclude_blocked_or_void_items exclude_blocked_or_void_issues coordinator_blocked_view; do
  fn_src="$(extract_function "$fn")"
  if [[ "$fn_src" != *"$fn()"* ]]; then
    printf 'FAIL - could not extract %s from agent-cycle.sh (renamed or moved?)\n' "$fn"
    exit 1
  fi
  eval "$fn_src"
done

# --- exclude_blocked_or_void_items applies to every band, not just tech-debt ---
# The function itself is unchanged by requirement 3u — only its call sites
# grew, from `tech_debt` alone to every pre-fetched band but `issues`. Proven
# here against a `findings`-shaped array (a Dependabot alert ref), not a
# tech-debt one, so a future reader can see the exclusion was never
# tech-debt-specific.
finding_cands='[{"ref":"dependabot-alert-1"},{"ref":"dependabot-alert-2"},{"ref":"code-scanning-alert-4"}]'
finding_blocked='[{"repo":"org/a","item":"dependabot-alert-1","ts":"2026-08-01T00:00:00Z"}]'
finding_void='[{"repo":"org/a","item":"dependabot-alert-2","ts":"2026-08-01T00:00:00Z"}]'
out="$(exclude_blocked_or_void_items "$finding_cands" "org/a" "$finding_blocked" "$finding_void")"
assert_eq "a blocked finding is dropped, the same as a blocked tech-debt item" \
  '["code-scanning-alert-4"]' "$(jq -c 'map(.ref)' <<<"$out")"
out="$(exclude_blocked_or_void_items "$finding_cands" "org/b" "$finding_blocked" "$finding_void")"
assert_eq "the same block/void does not reach a different repo's findings" \
  "3" "$(jq 'length' <<<"$out")"

# --- exclude_blocked_or_void_issues: void is dropped unconditionally ----------
iss_cands='[{"ref":"52","updated_at":"2026-08-01T00:00:00Z"},{"ref":"53","updated_at":"2026-08-01T00:00:00Z"}]'
iss_void='[{"repo":"org/a","item":"53","ts":"2026-07-01T00:00:00Z"}]'
out="$(exclude_blocked_or_void_issues "$iss_cands" "org/a" '[]' "$iss_void")"
assert_eq "a void issue is dropped, exactly like every other band" \
  '["52"]' "$(jq -c 'map(.ref)' <<<"$out")"

# --- exclude_blocked_or_void_issues: only a *stale* block is dropped ----------
# The threshold is requirement 18a's own comparison, already pinned above by
# `needs_mandatory_reread` against the same `blocked_items` output — asserted
# here to *agree* with that mirror on identical fixtures, rather than
# reimplemented as a second, driftable definition of "stale".
cat > "$log" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","detail":"waiting on maintainer"}
{"ts":"2026-07-29T10:30:00Z","event":"recheck-clean","repo":"o/r","item":"52"}
EOF
block_52="$(blocked_items "$log" | jq -c '.[0]')"
blocked_52="$(jq -c '[.]' <<<"$block_52")"

stale_cands='[{"ref":"52","updated_at":"2026-07-29T10:00:00Z"}]'
fresh_cands='[{"ref":"52","updated_at":"2026-07-30T00:00:00Z"}]'

assert_eq "a stale blocked issue (per needs_mandatory_reread) is dropped" \
  "false" "$(needs_mandatory_reread "2026-07-29T10:00:00Z" "$block_52")"
assert_eq "  ... and exclude_blocked_or_void_issues drops it too" \
  "0" "$(jq 'length' <<<"$(exclude_blocked_or_void_issues "$stale_cands" "o/r" "$blocked_52" '[]')")"

assert_eq "a fresh blocked issue (per needs_mandatory_reread) is due a re-read" \
  "true" "$(needs_mandatory_reread "2026-07-30T00:00:00Z" "$block_52")"
assert_eq "  ... and exclude_blocked_or_void_issues keeps it, for that re-read" \
  '["52"]' "$(jq -c 'map(.ref)' <<<"$(exclude_blocked_or_void_issues "$fresh_cands" "o/r" "$blocked_52" '[]')")"

# --- exclude_blocked_or_void_issues: the general fail-safe terms --------------
assert_eq "the block/void does not apply to a different repo's issues" \
  "1" "$(jq 'length' <<<"$(exclude_blocked_or_void_issues "$stale_cands" "o/other" "$blocked_52" '[]')")"
assert_eq "malformed blocked/void degrades to unfiltered" "$stale_cands" \
  "$(exclude_blocked_or_void_issues "$stale_cands" "o/r" 'not json' 'also not json')"
assert_eq "an issue candidate with no ref is dropped, not crashed on" "0" \
  "$(jq 'length' <<<"$(exclude_blocked_or_void_issues '[{"title":"no ref"}]' "o/r" '[]' '[]')")"

# The void extract past MAX_ARG_STRLEN, delivered on stdin (requirement 4g) —
# the same pin as test/tech-debt-eligibility.test.sh's own oversized-void case,
# proving this new function shares that call's stdin-only delivery rather than
# reintroducing an `--argjson` that would fail open past the cap.
BIG_VOID="$(jq -nc --argjson keep "$iss_void" '
  [range(1300) | {repo: "Poetic-Poems/filler", item: ("R-fill-" + tostring),
                  ts: "2026-07-01T00:00:00Z", detail: ("pad " + ("x" * 80)),
                  event: "item-void"}] + $keep')"
assert_eq "the oversized void fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$BIG_VOID" | wc -c) > 131072 ))"
assert_eq "a void extract past the argv cap still drops the void issue" \
  '["52"]' "$(jq -c 'map(.ref)' <<<"$(exclude_blocked_or_void_issues "$iss_cands" "org/a" '[]' "$BIG_VOID")")"

# --- coordinator_blocked_view: the Co-Ordinator's own copy is trimmed ---------
rich_blocked='[{"repo":"o/r","item":"52","ts":"2026-08-01T00:00:00Z","detail":"waiting","stage":"coordinator","cycle":"c1","event":"attempt-failed","unblock_condition":"merge #9","recheck_clean_ts":"2026-08-02T00:00:00Z"},{"item":"53","ts":"2026-08-01T00:00:00Z","detail":"d"}]'
out="$(coordinator_blocked_view "$rich_blocked")"
assert_eq "the trimmed view keeps repo/item/ts/detail/recheck_clean_ts" \
  '{"item":"52","ts":"2026-08-01T00:00:00Z","detail":"waiting","repo":"o/r","recheck_clean_ts":"2026-08-02T00:00:00Z"}' \
  "$(jq -c '.[0]' <<<"$out")"
assert_eq "  ... and drops stage/cycle/event/unblock_condition" \
  "false" "$(jq '.[0] | has("stage") or has("cycle") or has("event") or has("unblock_condition")' <<<"$out")"
assert_eq "an entry with no repo/recheck_clean_ts carries neither key" \
  '{"item":"53","ts":"2026-08-01T00:00:00Z","detail":"d"}' "$(jq -c '.[1]' <<<"$out")"
assert_eq "malformed input degrades to the untrimmed array" "not an array" \
  "$(coordinator_blocked_view "not an array")"

# --- the generic pass covers every pre-fetched band but `issues` -------------
# The band list is inline shell, not a function, so this is the one assertion
# that can hold it to the repo entry it filters. `human_visibility` is the band
# that makes the point: it is assigned into the entry well after the repo loop
# (requirement 38e's read-back), so it is easy to add a band in one place and
# not the other — and a band left off this list keeps handing the Co-Ordinator
# blocked and void candidates it no longer has any `void` list to check them
# against (requirement 3u). `issues` is absent by design: it has its own,
# narrower pass through exclude_blocked_or_void_issues.
band_list="$(sed -n 's/^for eligibility_band in \(.*\); do$/\1/p' "$SCRIPT_DIR/agent-cycle.sh")"
assert_eq "every pre-fetched band but issues reaches exclude_blocked_or_void_items" \
  "findings review_feedback abandoned_drafts merge_conflicts register_hygiene human_visibility tech_debt" \
  "$band_list"

# --- coordinator_input itself: no `void` key, and a trimmed `blocked` --------
# The build is lifted verbatim out of agent-cycle.sh, the same way the three
# functions above are: what the Co-Ordinator is handed is the claim requirement
# 3u makes, and it is made by this block rather than by any of them.
ci_src="$(awk '
  /^coordinator_blocked_json="\$\(coordinator_blocked_view/ { on = 1 }
  on                                                        { print }
  on && /<<<"\$coordinator_stdin"\)"$/                       { exit }
' "$SCRIPT_DIR/agent-cycle.sh")"
if [[ "$ci_src" != *coordinator_input=* ]]; then
  printf 'FAIL - could not extract the coordinator_input build from agent-cycle.sh\n'
  exit 1
fi
# All eight are consumed by the eval'd block, which shellcheck cannot see into
# — as is `coordinator_input`, which that block is what assigns.
# shellcheck disable=SC2034
{
  blocked_json="$rich_blocked"
  ordered_repos_json='[{"slug":"o/r"}]'
  refinements_json='{}'
  claimed_json='[]'
  implementor_model_default="claude-sonnet-5"
  implementor_model_trivial="claude-haiku-4-5-20251001"
  candidates_max=3
  refinement_policy_json='{}'
}
eval "$ci_src"
# shellcheck disable=SC2154
assert_eq "the Co-Ordinator's input carries no void key at all" \
  "false" "$(jq 'has("void")' <<<"$coordinator_input")"
assert_eq "  ... and its blocked entries are the trimmed view" \
  '{"item":"52","ts":"2026-08-01T00:00:00Z","detail":"waiting","repo":"o/r","recheck_clean_ts":"2026-08-02T00:00:00Z"}' \
  "$(jq -c '.blocked[0]' <<<"$coordinator_input")"
assert_eq "  ... with no stage/cycle/event/unblock_condition surviving" \
  "false" \
  "$(jq '.blocked | any(has("stage") or has("cycle") or has("event") or has("unblock_condition"))' \
     <<<"$coordinator_input")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
