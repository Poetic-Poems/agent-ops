#!/usr/bin/env bash
#
# test/implementer-labels-wiring.test.sh — regression test for the block in
# agent-cycle.sh that turns the Implementer summary's optional `labels` field
# into a `labels_mint` call and a `labels-minted` event (requirements 26b/6c,
# issue #714) — the Implementer's own half of "labels a stage asks for";
# test/refiner-verdicts.test.sh covers the Refiner's.
#
# Lifted verbatim out of agent-cycle.sh with awk, the same way
# test/closing-keyword-wiring.test.sh lifts its own block, so this cannot pass
# against a copy the script has since moved on from. Its callees —
# `labels_mint`, `labels_reserved_names`, `log_event` — are stubbed: each has
# (or belongs to) its own test elsewhere (test/labels.test.sh), wiring the
# real ones in here would make this file a second copy of that one, coupled
# to its internals for no assertion this file makes.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/implementer-labels-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLE="$SCRIPT_DIR/agent-cycle.sh"

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

# --- Extraction ---------------------------------------------------------------
# The block runs from `impl_labels_json`'s own assignment through the `fi`
# that closes its `if`, both two-space indented — distinct from the outer
# `if [[ -n "$impl_pr_url" ]]` this block lives inside, whose own closing `fi`
# sits at column 0 and is deliberately left out: this block is self-contained
# without it.
mint_block="$(awk '
  /^  impl_labels_json="\$\(jq -c '"'"'\.labels/ { on = 1 }
  on          { print }
  on && /^  fi$/ { exit }
' "$CYCLE")"

if [[ -z "$mint_block" ]]; then
  echo "FAIL - could not extract the label-minting block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# run_mint_block IMPL_STATUS_JSON
# Runs the block under the same `set -euo pipefail` agent-cycle.sh runs
# under, with `impl_pr_url`/`repo_slug`/`selected_item`/`CONFIG_FILE`/
# `SCHEMA_FILE` set as agent-cycle.sh would have them by this point, and
# `labels_mint`/`labels_reserved_names`/`log_event` stubbed. Prints, in
# order: every `labels_mint` invocation's own argv (one per line, prefixed
# `mint`), whether stdin fed to it matched `labels_reserved_names`'s own
# argv (prefixed `reserved-stdin`), and every `log_event` call as
# `event<TAB>fields-json`.
# shellcheck disable=SC2016  # The harness's own $impl_status_json etc., written out literally for it to expand, not this shell's.
run_mint_block() {
  local impl_status_json="$1" harness="$tmp_dir/mint-harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf 'impl_status_json=%q\n' "$impl_status_json"
    printf 'impl_pr_url=%q\n' "https://github.com/Owner/repo/pull/42"
    printf 'repo_slug=%q\n' "Owner/repo"
    printf 'selected_item=%q\n' "55"
    printf 'CONFIG_FILE=%q\n' "config.json"
    printf 'SCHEMA_FILE=%q\n' "schema.json"
    printf '%s\n' 'labels_reserved_names() { printf "%s\t%s\n" "reserved-called" "$*" >> '"$(printf '%q' "$tmp_dir/calls")"'; printf "blocked\n"; }'
    printf '%s\n' 'labels_mint() { printf "mint\t%s\n" "$*" >> '"$(printf '%q' "$tmp_dir/calls")"'; cat >> '"$(printf '%q' "$tmp_dir/reserved-stdin")"'; printf "%s" '"'"'{"created":["x"],"applied":["x"],"refused":[]}'"'"'; }'
    printf '%s\n' 'log_event() { printf "event\t%s\t%s\n" "$1" "$2" >> '"$(printf '%q' "$tmp_dir/calls")"'; }'
    printf '%s\n' "$mint_block"
  } > "$harness"
  : > "$tmp_dir/calls"
  : > "$tmp_dir/reserved-stdin"
  bash "$harness" 2>&1
  cat "$tmp_dir/calls" 2>/dev/null
}

out="$(run_mint_block '{"status":"complete","pr_url":"https://github.com/Owner/repo/pull/42"}')"
assert_eq "a summary with no labels field never calls labels_mint" "0" \
  "$(grep -c '^mint	' <<<"$out" || true)"

out="$(run_mint_block '{"status":"complete","labels":[]}')"
assert_eq "a summary with an empty labels array never calls labels_mint either" "0" \
  "$(grep -c '^mint	' <<<"$out" || true)"
assert_eq "  ... nor does it log a labels-minted event" "0" \
  "$(grep -c '^event	labels-minted	' <<<"$out" || true)"

out="$(run_mint_block '{"status":"complete","labels":[{"name":"good-topic","colour":"112233"}]}')"
assert_eq "a non-empty labels array calls labels_mint exactly once" "1" \
  "$(grep -c '^mint	' <<<"$out")"
assert_contains "  ... against this PR's own repo, kind pr, and its number parsed from the URL" \
  "mint	Owner/repo pr 42 " "$out"
assert_contains "  ... carrying the labels array itself" \
  '[{"name":"good-topic","colour":"112233"}]' "$out"
assert_eq "  ... having drawn reserved names from labels_reserved_names(CONFIG_FILE, SCHEMA_FILE)" \
  "1" "$(grep -c '^reserved-called	config.json schema.json$' <<<"$out")"
assert_eq "  ... and fed labels_mint's own stdin with that exact reserved-name list" \
  "blocked" "$(cat "$tmp_dir/reserved-stdin")"
assert_eq "  ... logging exactly one labels-minted event" "1" \
  "$(grep -c '^event	labels-minted	' <<<"$out")"
ev_fields="$(grep '^event	labels-minted	' <<<"$out" | cut -f3-)"
assert_eq "  ... naming the repo and item" "Owner/repo 55" \
  "$(jq -r '"\(.repo) \(.item)"' <<<"$ev_fields")"
assert_eq "  ... attributed to the implementer" "implementer" "$(jq -r '.actor' <<<"$ev_fields")"
assert_eq "  ... carrying labels_mint's own report merged in" '["x"]' \
  "$(jq -c '.applied' <<<"$ev_fields")"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
