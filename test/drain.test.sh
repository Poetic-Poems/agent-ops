#!/usr/bin/env bash
#
# test/drain.test.sh — regression test for lib/drain.sh: the at-rest
# detection, the cached progress readers (`--status`, the dashboard, the
# heartbeat) build on, and the deduplicated `drained` event.
#
# The `--drain` CLI surface itself — the mode field, the tighten/error/extend
# precedence, `--enable` clearing either mode, `review-cycle.sh` standing
# down under either — is covered end to end in test/toggle.test.sh's own
# offline e2e section, which already owns the node/gh-stub harness a CLI test
# needs; a second copy of that harness here would only drift from it. This
# file is `lib/drain.sh`'s own pure functions: no `gh`, no lock, no cycle.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/drain.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/drain.sh
. "$SCRIPT_DIR/lib/drain.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# A pinned clock, same convention as test/toggle.test.sh.
export TOGGLE_NOW_EPOCH=1784289600   # 2026-07-17T12:00:00Z

# --- drain_remaining_count / drain_at_rest: the band count alone -----------
# `AGENT_OPS_ROOT` points at a scratch tree whose `lib/claim.sh` is a stub
# printing canned claims per slug, so these assertions never touch `gh` or
# the real lib/claim.sh — the same seam agent-cycle.sh itself uses
# (`"$AGENT_OPS_ROOT/lib/claim.sh" claims "$slug"`).
export AGENT_OPS_ROOT="$tmp_dir/root"
mkdir -p "$AGENT_OPS_ROOT/lib"
claim_stub="$AGENT_OPS_ROOT/lib/claim.sh"
claims_fixture="$tmp_dir/claims.json"
echo '{}' > "$claims_fixture"
cat > "$claim_stub" <<STUB
#!/usr/bin/env bash
# Test stub for lib/claim.sh's "claims <slug>" subcommand: prints whatever
# this fixture file maps the slug to, or an empty array for an unmapped one.
slug="\$2"
jq -c --arg s "\$slug" '.[\$s] // []' "$claims_fixture"
STUB
chmod +x "$claim_stub"

empty_repos='[{"slug":"acme/widgets","review_feedback":[],"merge_conflicts":[],"dequeued":[],"abandoned_drafts":[]}]'
assert_eq "no bands, no claims: remaining is zero" "0" "$(drain_remaining_count "$empty_repos")"
assert_eq "no bands, no claims: at rest" "1" "$(drain_at_rest "$empty_repos")"

busy_repos='[{"slug":"acme/widgets","review_feedback":[{"number":12}],"merge_conflicts":[],"dequeued":[],"abandoned_drafts":[]},
             {"slug":"acme/gadgets","review_feedback":[],"merge_conflicts":[{"number":7}],"dequeued":[],"abandoned_drafts":[{"number":3}]}]'
assert_eq "three finishing-band PRs across two repos" "3" "$(drain_remaining_count "$busy_repos")"
assert_eq "not at rest with bands non-empty" "0" "$(drain_at_rest "$busy_repos")"

# --- The claim-registry half: a claim with no matching band entry yet ------
# The gap requirement 2.9 exists for: a claim taken moments before its pull
# request appears. The band count alone reads zero; the claim count must
# still surface it.
jq -n '{"acme/widgets": [{"item":"pr-99-review-abc123","kind":"file","age_hours":1}]}' > "$claims_fixture"
assert_eq "a live finishing claim with an empty band still counts" "1" \
  "$(drain_remaining_count "$empty_repos")"
assert_eq "and is not at rest" "0" "$(drain_at_rest "$empty_repos")"

# A claim that does NOT name a finishing-source ref (an ordinary branch claim,
# e.g. a tech-debt item mid-flight) must not count — a drain never waits on
# new-work claims, only on the four finishing kinds.
jq -n '{"acme/widgets": [{"item":"agent-42","kind":"branch","age_hours":1}]}' > "$claims_fixture"
assert_eq "a non-finishing claim (e.g. an ordinary agent/<item> branch) is ignored" "0" \
  "$(drain_remaining_count "$empty_repos")"
assert_eq "at rest" "1" "$(drain_at_rest "$empty_repos")"

# The floor, not a sum: a claim whose PR the band already counts must not be
# double-counted. One repo, one band entry, one matching claim — band count
# and claim count are both 1, and the combined answer must stay 1, not 2.
single_item_repos='[{"slug":"acme/widgets","review_feedback":[{"number":12}],"merge_conflicts":[],"dequeued":[],"abandoned_drafts":[]}]'
jq -n '{"acme/widgets": [{"item":"pr-12-review-abc123","kind":"file","age_hours":1,"pr_number":12}]}' > "$claims_fixture"
assert_eq "a claim matching an already-counted band PR is a floor, not a sum" "1" \
  "$(drain_remaining_count "$single_item_repos")"

echo '{}' > "$claims_fixture"

# --- drain_write_state / drain_read_state: the cache round-trips ----------
state_dir="$tmp_dir/state"
mkdir -p "$state_dir"
assert_eq "no cache yet reads as null" "null" "$(drain_read_state "$state_dir")"

drain_write_state "$state_dir" "2026-07-17T09:00:00Z" 3 0
cached="$(drain_read_state "$state_dir")"
assert_eq "the cache round-trips disabled_at" "2026-07-17T09:00:00Z" "$(jq -r '.disabled_at' <<<"$cached")"
assert_eq "and remaining" "3" "$(jq -r '.remaining' <<<"$cached")"
assert_eq "and at_rest false" "false" "$(jq -r '.at_rest' <<<"$cached")"
assert_eq "and stamps checked_at from the pinned clock" "2026-07-17T12:00:00Z" "$(jq -r '.checked_at' <<<"$cached")"

drain_write_state "$state_dir" "2026-07-17T09:00:00Z" 0 1
assert_eq "re-writing with at_rest true updates the cache" "true" \
  "$(jq -r '.at_rest' <<<"$(drain_read_state "$state_dir")")"

# --- drain_status_line: --status's own reporting line ----------------------
no_cache_state_dir="$tmp_dir/no-cache-state"
mkdir -p "$no_cache_state_dir"
record_fresh='{"disabled_at":"2026-07-17T11:00:00Z","reason":"testing"}'
assert_contains "no cache at all: --status says so honestly" \
  "no cycle has checked yet" "$(drain_status_line "$no_cache_state_dir" "$record_fresh")"

record_matching='{"disabled_at":"2026-07-17T09:00:00Z","reason":"testing"}'
assert_contains "a cache from a different (older) drain does not leak into --status" \
  "no cycle has checked yet" "$(drain_status_line "$no_cache_state_dir" "$record_fresh")"

# A dedicated state_dir here, rather than reusing the round-trip section's
# above: that one's cache was last written at_rest=true, and reusing it would
# make this assertion depend on that section's own final write rather than on
# what this one sets up.
draining_state_dir="$tmp_dir/draining-state"
mkdir -p "$draining_state_dir"
drain_write_state "$draining_state_dir" "2026-07-17T09:00:00Z" 3 0
draining_line="$(drain_status_line "$draining_state_dir" "$record_matching")"
assert_contains "a matching cache reports DRAINING with the count" "DRAINING" "$draining_line"
assert_contains "and the remaining count" "3 finishing-source item(s) left" "$draining_line"

drain_write_state "$draining_state_dir" "2026-07-17T09:00:00Z" 0 1
assert_contains "at rest reports DRAINED" "DRAINED" "$(drain_status_line "$draining_state_dir" "$record_matching")"

stale_record='{"disabled_at":"2026-07-18T00:00:00Z","reason":"a newer drain"}'
assert_contains "a cache from a superseded drain (stale disabled_at) does not leak either" \
  "no cycle has checked yet" "$(drain_status_line "$state_dir" "$stale_record")"

# --- drain_event_logged: dedup across the union log -------------------------
union_log_none='{"ts":"2026-07-17T08:00:00Z","cycle":"c1","node":"a","event":"stand-down"}'
assert_eq "no drained event at all: not logged" "0" \
  "$(drain_event_logged "$union_log_none" "2026-07-17T09:00:00Z")"

union_log_one="$union_log_none
{\"ts\":\"2026-07-17T10:00:00Z\",\"cycle\":\"c2\",\"node\":\"b\",\"event\":\"drained\",\"disabled_at\":\"2026-07-17T09:00:00Z\"}"
assert_eq "a matching drained event from ANY node counts as logged" "1" \
  "$(drain_event_logged "$union_log_one" "2026-07-17T09:00:00Z")"
assert_eq "a drained event for a DIFFERENT disabled_at does not match" "0" \
  "$(drain_event_logged "$union_log_one" "2026-07-17T05:00:00Z")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
