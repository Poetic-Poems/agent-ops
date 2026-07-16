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

# --- attempt_failed_fields ---

assert_eq "attempt-failed carries the item it failed on" \
  '{"stage":"implementor","detail":"already done","repo":"o/r","item":"review-2026-07-11-R-01"}' \
  "$(attempt_failed_fields "implementor" "already done" "o/r" "review-2026-07-11-R-01")"

assert_eq "extra fields are merged in" \
  '{"stage":"implementor","detail":"already done","repo":"o/r","item":"R-01","unblock_condition":"refresh the review"}' \
  "$(attempt_failed_fields "implementor" "already done" "o/r" "R-01" '{"unblock_condition":"refresh the review"}')"

# A stage that fails before anything is selected blames no item.
assert_eq "repo/item omitted when there is no selection" \
  '{"stage":"coordinator","detail":"unparseable final message"}' \
  "$(attempt_failed_fields "coordinator" "unparseable final message" "" "")"

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

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
