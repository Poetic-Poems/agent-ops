#!/usr/bin/env bash
#
# test/pickup-metrics.test.sh — regression test for scripts/pickup-metrics.sh
# (TD-PPagop-26080808, issue #248 acceptance 5).
#
# What matters here:
#
#   the split       "before"/"after" is per node, at that node's own first
#                    `chained` event — a node with no `chained` event at all
#                    is entirely "before".
#   what counts as   a `claim-lost` whose `cause` is `held` or `pr-held`;
#   contention       every other cause, and a line carrying no `cause` at
#                    all, is excluded rather than guessed at.
#   --since          bounds which events are counted and the reported
#                    window, but never which `chained` event counts as a
#                    node's first — adoption can predate the window a report
#                    asks about.
#   malformed input  a line that is not valid JSON is skipped, not fatal —
#                    the log is appended to while this script reads it.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/pickup-metrics.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PICKUP="$SCRIPT_DIR/scripts/pickup-metrics.sh"

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

state_dir="$tmp_dir/state"
peers_dir="$tmp_dir/peers"
mkdir -p "$state_dir" "$peers_dir/node-b" "$peers_dir/node-c"

# node-a (this node's own log, state_dir/log.jsonl): a selection and a held
# loss before its first `chained` event; an unreachable loss (never
# contention) before it too; the `chained` event itself; then a selection, a
# `pr-held` loss and a causeless `claim-lost` (pre-17a shape) after it — plus
# one malformed trailing line, which must not stop the rest from reading.
cat > "$state_dir/log.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:01Z","node":"node-a","event":"selection","repo":"r","item":"1"}
{"ts":"2026-01-01T00:00:02Z","node":"node-a","event":"claim-lost","cause":"held","repo":"r","item":"2"}
{"ts":"2026-01-01T00:00:03Z","node":"node-a","event":"claim-lost","cause":"unreachable","repo":"r","item":"3"}
{"ts":"2026-01-01T00:00:04Z","node":"node-a","event":"chained","depth":2,"max_chained_cycles":3}
this is not valid json at all
{"ts":"2026-01-01T00:00:05Z","node":"node-a","event":"selection","repo":"r","item":"4"}
{"ts":"2026-01-01T00:00:06Z","node":"node-a","event":"claim-lost","cause":"pr-held","repo":"r","item":"5","pr_claim_key":"pr-9"}
{"ts":"2026-01-01T00:00:07Z","node":"node-a","event":"claim-lost","repo":"r","item":"6"}
EOF

# node-b (a peer): a selection before its own first `chained` event, then a
# selection and a held loss after it.
cat > "$peers_dir/node-b/log.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:01Z","node":"node-b","event":"selection","repo":"r","item":"7"}
{"ts":"2026-01-01T00:00:02Z","node":"node-b","event":"chained","depth":2,"max_chained_cycles":3}
{"ts":"2026-01-01T00:00:03Z","node":"node-b","event":"selection","repo":"r","item":"8"}
{"ts":"2026-01-01T00:00:04Z","node":"node-b","event":"claim-lost","cause":"held","repo":"r","item":"9"}
EOF

# node-c (a peer): never chains at all, so both of its events are "before"
# no matter how late they land.
cat > "$peers_dir/node-c/log.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:01Z","node":"node-c","event":"selection","repo":"r","item":"10"}
{"ts":"2026-01-01T00:00:02Z","node":"node-c","event":"claim-lost","cause":"held","repo":"r","item":"11"}
EOF

# --- The full log: 3 before-selections, 2 after; 2 before-contended, 2 after
out="$("$PICKUP" --state-dir "$state_dir" --peers-dir "$peers_dir")"
rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "before selections (node-a T1, node-b U1, node-c V1)" "3" "$(jq -r '.before.selections' <<<"$out")"
assert_eq "before contended losses (node-a held, node-c held — unreachable excluded)" "2" "$(jq -r '.before.contended_losses' <<<"$out")"
assert_eq "after selections (node-a T5, node-b U3)" "2" "$(jq -r '.after.selections' <<<"$out")"
assert_eq "after contended losses (pr-held and held — causeless excluded)" "2" "$(jq -r '.after.contended_losses' <<<"$out")"
assert_eq "before ratio" "0.6666666666666666" "$(jq -r '.before.ratio' <<<"$out")"
assert_eq "after ratio" "1" "$(jq -r '.after.ratio' <<<"$out")"
assert_eq "window starts at the earliest ts" "2026-01-01T00:00:01Z" "$(jq -r '.window.from' <<<"$out")"
assert_eq "window ends at the latest ts" "2026-01-01T00:00:07Z" "$(jq -r '.window.to' <<<"$out")"
assert_eq "since is null when not given" "null" "$(jq -r '.since' <<<"$out")"

# --- --since narrows counts and the window, but a node's first `chained`
#     event still resolves era correctly even when --since excludes the
#     `chained` line itself (adoption can predate the reported window).
out_since="$("$PICKUP" --state-dir "$state_dir" --peers-dir "$peers_dir" --since "2026-01-01T00:00:05Z")"
assert_eq "--since is echoed back" "2026-01-01T00:00:05Z" "$(jq -r '.since' <<<"$out_since")"
assert_eq "--since: before selections drop to zero (node-a's only remaining event is after)" "0" "$(jq -r '.before.selections' <<<"$out_since")"
assert_eq "--since: after selections keep node-a's T5" "1" "$(jq -r '.after.selections' <<<"$out_since")"
assert_eq "--since: after contended losses keep node-a's pr-held T6" "1" "$(jq -r '.after.contended_losses' <<<"$out_since")"
assert_eq "--since: before contended losses drop to zero" "0" "$(jq -r '.before.contended_losses' <<<"$out_since")"
assert_eq "--since: window starts at the bound, not the log's start" "2026-01-01T00:00:05Z" "$(jq -r '.window.from' <<<"$out_since")"

# --- An empty log directory pair is a clean, zeroed report, not an error ----
empty_state="$tmp_dir/empty-state"
empty_peers="$tmp_dir/empty-peers"
mkdir -p "$empty_state" "$empty_peers"
out_empty="$("$PICKUP" --state-dir "$empty_state" --peers-dir "$empty_peers")"
assert_eq "an empty log exits 0" "0" "$?"
assert_eq "an empty log reports zero before-selections" "0" "$(jq -r '.before.selections' <<<"$out_empty")"
assert_eq "an empty log reports a null before-ratio (no division by zero)" "null" "$(jq -r '.before.ratio' <<<"$out_empty")"
assert_eq "an empty log reports a null window" "null" "$(jq -r '.window.from' <<<"$out_empty")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
