#!/usr/bin/env bash
#
# test/sweep-closed-issues.test.sh — the post-merge sweep closes an issue
# whose implementing PR merged without a real closing keyword (requirement
# 17c, acceptance check for issue #240).
#
# What this guards: PR #206 said "Implements #198" instead of "Closes #198",
# so GitHub never auto-closed #198 when the PR merged — it sat open, was
# selected and voided twice, for three days. This sweep is the backstop that
# notices a merged, marker-carrying PR whose issue is still open and closes
# it with the merge as evidence.
#
# `gh` is a stub on PATH via SWEEP_GH; no network.
#
# Run directly: ./test/sweep-closed-issues.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$SCRIPT_DIR/scripts/sweep-closed-issues.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

config="$tmp_dir/config.json"
jq -n '{pr_label: "autonomous-agent"}' > "$config"

stub="$tmp_dir/gh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
S="$SWEEP_STUB_DIR"
printf '%s\n' "$*" >> "$S/calls.log"
args="$*"
case "$args" in
  "pr list -R x/y --state merged --label autonomous-agent "*)
    cat "$S/prs.json" ;;
  "api repos/x/y/issues/"*)
    n="${args##*issues/}"
    if [[ -f "$S/issue-$n" ]]; then cat "$S/issue-$n"; else exit 1; fi ;;
  "issue close "*" -R x/y --comment "*)
    n="${args#issue close }"; n="${n%% *}"
    [[ -f "$S/fail-close-$n" ]] && exit 1
    exit 0 ;;
  *)
    echo "stub gh: unexpected call: $args" >&2; exit 1 ;;
esac
STUB
chmod +x "$stub"

run_sweep() {
  SWEEP_STUB_DIR="$1" SWEEP_GH="$stub" AGENT_OPS_CONFIG="$config" \
    bash "$SWEEP" x/y node-1 cycle-1 "$tmp_dir/state"
}

# --- Case 1: a merged, marker-carrying PR whose issue is still open --------------
c="$tmp_dir/case1"; mkdir -p "$c"
jq -n '[{number: 206, url: "https://github.com/x/y/pull/206",
         body: "Implements #198.\n\n<!-- agent-ops:closes-issue item=198 -->",
         mergeCommit: {oid: "abc123"}}]' > "$c/prs.json"
jq -n '{state: "open"}' > "$c/issue-198"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"

assert_eq "the issue is closed" \
  '{"action":"closed","issue":198,"pr_number":206,"pr_url":"https://github.com/x/y/pull/206"}' \
  "$(jq -c 'select(.action == "closed")' <<<"$out")"
assert_contains "with the PR's merge cited in the close call" \
  'issue close 198 -R x/y --comment' "$calls"
assert_eq "  ... and the item-lifecycle merge instant is reported too (requirement 49)" \
  '{"action":"merge-observed","pr_number":206,"pr_url":"https://github.com/x/y/pull/206","item":"198","merge_sha":"abc123"}' \
  "$(jq -c 'select(.action == "merge-observed")' <<<"$out")"

# --- Case 2: the issue already closed (GitHub's own auto-close worked) -----------
c="$tmp_dir/case2"; mkdir -p "$c"
jq -n '[{number: 300, url: "https://github.com/x/y/pull/300",
         body: "Closes #301.\n\n<!-- agent-ops:closes-issue item=301 -->",
         mergeCommit: {oid: "def456"}}]' > "$c/prs.json"
jq -n '{state: "closed"}' > "$c/issue-301"

out="$(run_sweep "$c")"
assert_eq "an already-closed issue is left alone" '' \
  "$(jq -c 'select(.action == "closed")' <<<"$out" 2>/dev/null || true)"
assert_eq "  ... but the merge instant still fires — it costs no issue lookup" \
  '{"action":"merge-observed","pr_number":300,"pr_url":"https://github.com/x/y/pull/300","item":"301","merge_sha":"def456"}' \
  "$(jq -c 'select(.action == "merge-observed")' <<<"$out")"

# --- Case 3: a merged PR with no marker and no numeric agent branch ----------------
c="$tmp_dir/case3"; mkdir -p "$c"
jq -n '[{number: 400, url: "https://github.com/x/y/pull/400",
         body: "A tech-debt fix, nothing to close.",
         headRefName: "agent/td26072001-cache",
         mergeCommit: {oid: "ghi789"}}]' > "$c/prs.json"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"
assert_eq "no action for a PR naming no issue either way" '' \
  "$(jq -c 'select(.action == "closed")' <<<"$out" 2>/dev/null || true)"
assert_not_contains "and no issue lookup is even made" "issues/" "$calls"
assert_eq "  ... and no merge instant either — there is no item to key it to" '' \
  "$(jq -c 'select(.action == "merge-observed")' <<<"$out" 2>/dev/null || true)"

# --- Case 3a: no marker, but the head branch is agent/<N> --------------------------
# The branch is the Script's own name for an issue-sourced work order — the
# anchor that survives an Implementer forgetting the marker, so the sweep and
# the CI check cannot both be blinded by the same omission (issue #240).
c="$tmp_dir/case3a"; mkdir -p "$c"
jq -n '[{number: 600, url: "https://github.com/x/y/pull/600",
         body: "Implements the thing. No marker, no keyword.",
         headRefName: "agent/601",
         mergeCommit: {oid: "mno345"}}]' > "$c/prs.json"
jq -n '{state: "open"}' > "$c/issue-601"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"
assert_eq "the branch-named issue is closed" \
  '{"action":"closed","issue":601,"pr_number":600,"pr_url":"https://github.com/x/y/pull/600"}' \
  "$(jq -c 'select(.action == "closed")' <<<"$out")"
assert_contains "with the branch cited as the anchor" "agent/601" "$calls"
assert_not_contains "and the marker not claimed as evidence" \
  "closes-issue item=601\` marker" "$calls"

# --- Case 3b: an issue a human reopened after a close ------------------------------
# "Open" alone cannot tell "never closed" from "somebody put it back"; without
# the state_reason test the sweep would re-close this every cycle, forever,
# commenting each time.
c="$tmp_dir/case3b"; mkdir -p "$c"
jq -n '[{number: 500, url: "https://github.com/x/y/pull/500",
         body: "Implements #501.\n\n<!-- agent-ops:closes-issue item=501 -->",
         mergeCommit: {oid: "jkl012"}}]' > "$c/prs.json"
jq -n '{state: "open", state_reason: "reopened"}' > "$c/issue-501"

out="$(run_sweep "$c")"
calls="$(cat "$c/calls.log")"
assert_eq "a reopened issue is not closed again" '' \
  "$(jq -c 'select(.action == "closed")' <<<"$out" 2>/dev/null || true)"
assert_not_contains "and no close call is made for it" "issue close 501" "$calls"
assert_contains "the skip is reported, not silent" "reopened" \
  "$(jq -r 'select(.action == "warning") | .detail' <<<"$out")"

# --- Case 4: the action cap defers the rest ---------------------------------------
c="$tmp_dir/case4"; mkdir -p "$c"
jq -n '[
  {number: 1, url: "https://github.com/x/y/pull/1", mergeCommit: {oid: "s1"},
   body: "<!-- agent-ops:closes-issue item=11 -->"},
  {number: 2, url: "https://github.com/x/y/pull/2", mergeCommit: {oid: "s2"},
   body: "<!-- agent-ops:closes-issue item=12 -->"},
  {number: 3, url: "https://github.com/x/y/pull/3", mergeCommit: {oid: "s3"},
   body: "<!-- agent-ops:closes-issue item=13 -->"},
  {number: 4, url: "https://github.com/x/y/pull/4", mergeCommit: {oid: "s4"},
   body: "<!-- agent-ops:closes-issue item=14 -->"}
]' > "$c/prs.json"
for n in 11 12 13 14; do jq -n '{state: "open"}' > "$c/issue-$n"; done

out="$(run_sweep "$c")"
assert_eq "closes exactly the per-run cap" 3 \
  "$(jq -c 'select(.action == "closed")' <<<"$out" | wc -l | tr -d ' ')"
assert_eq "and reports the rest as deferred" \
  '{"action":"deferred","remaining":1}' \
  "$(jq -c 'select(.action == "deferred")' <<<"$out")"
assert_eq "  ... but the merge instant is never capped (requirement 49)" 4 \
  "$(jq -c 'select(.action == "merge-observed")' <<<"$out" | wc -l | tr -d ' ')"

# --- Case 5: the merge instant is not re-reported once a node has seen it ---------
# `sweep-closed-issues.sh` re-lists the same recently-merged window every
# stand-down; without the seen-file this PR's merge-observed action would
# repeat forever. A shared state-dir (this file's own `run_sweep`) is what
# lets the second call see the first's own memo.
c="$tmp_dir/case5"; mkdir -p "$c"
jq -n '[{number: 700, url: "https://github.com/x/y/pull/700",
         body: "<!-- agent-ops:closes-issue item=701 -->",
         mergeCommit: {oid: "pqr901"}}]' > "$c/prs.json"
jq -n '{state: "closed"}' > "$c/issue-701"

out1="$(run_sweep "$c")"
assert_eq "the first sighting reports the merge instant" \
  '{"action":"merge-observed","pr_number":700,"pr_url":"https://github.com/x/y/pull/700","item":"701","merge_sha":"pqr901"}' \
  "$(jq -c 'select(.action == "merge-observed")' <<<"$out1")"

out2="$(run_sweep "$c")"
assert_eq "a second sighting of the same window reports it not at all" '' \
  "$(jq -c 'select(.action == "merge-observed")' <<<"$out2" 2>/dev/null || true)"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
