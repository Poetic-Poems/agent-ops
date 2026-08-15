#!/usr/bin/env bash
#
# test/gather-source-state.test.sh — regression test for the argv cap
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 4g; TD-PPagop-26081503)
# in scripts/gather-source-state.sh's final state build.
#
# `$issues`, `$workflows` and `$open_prs` each grow with the repo — one
# repo's whole open-issue list, workflow digest and open-PR list — and used
# to ride into the final `jq -nc` as three separate `--argjson` values. Past
# `MAX_ARG_STRLEN` (131072 bytes) the build dies at `execve`, `ok` is never
# flipped by the failed subshell (the header comment's own warning), and the
# Script would trust a digest built from a call that never ran.
#
# The gatherer is run for real here against a stubbed `gh`, with `$issues`
# fixtured past the cap, so what is asserted is the shipped build rather than
# a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-source-state.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-source-state.sh"

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

# --- A stub `gh`, so the real gatherer runs offline ---
#
# Mimics the one behaviour of `gh api --jq` the script depends on: string
# results print raw, not JSON (jq -rc reproduces that exactly). `$STUB_ISSUES`
# names a file holding the raw (unfiltered) issues-endpoint body, fixtured
# past the argv cap below; the other three endpoints stay small.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected command: $*" >&2; exit 1; }
path="$2"; shift 2
filter='.'
while [[ $# -gt 0 ]]; do
  case "$1" in --jq) filter="$2"; shift 2;; *) shift;; esac
done
case "$path" in
  */commits/*)     body='{"sha":"aaa111"}';;
  */issues\?*)     body="$(cat "$STUB_ISSUES")";;
  */actions/runs*) body='{"workflow_runs":[]}';;
  */pulls\?*)      body='[]';;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1;;
esac
jq -rc "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# --- The fixture: 1500 open issues, each padded past what fits in one line -
export STUB_ISSUES="$tmp_dir/issues.json"
jq -nc '[range(1500) | {number: ., updated_at: "2026-07-20T09:00:00Z",
  labels: [{name: ("pad-" + ("x" * 100))}], assignee: null, issue_field_values: []}]' \
  > "$STUB_ISSUES"

state="$("$GATHER" "o/r" "main")"
rc=$?

assert_eq "the gatherer still exits 0 with an oversized issues source" "0" "$rc"
assert_eq "the sample is still marked ok" "true" "$(jq -r '.ok' <<<"$state")"
assert_eq "every one of the 1500 issues survives into the digest" \
  "1500" "$(jq '.issues | length' <<<"$state")"
assert_eq "the digested issues array really is past MAX_ARG_STRLEN (131072 bytes)" "1" \
  "$(( $(jq -c '.issues' <<<"$state" | wc -c) > 131072 ))"
assert_eq "workflows and open_prs still arrive alongside the oversized issues array" \
  "[] []" "$(jq -c '"\(.workflows) \(.open_prs)"' <<<"$state" | tr -d '"')"
assert_eq "head_sha and slug are untouched by the conversion" "aaa111 o/r" \
  "$(jq -r '"\(.head_sha) \(.slug)"' <<<"$state")"

# --- Fail-safe direction is unchanged: a broken source still marks not-ok ---
rm -f "$STUB_ISSUES"
state_broken="$("$GATHER" "o/r" "main")"
assert_eq "an unreadable issues endpoint still marks the sample not-ok" \
  "false" "$(jq -r '.ok' <<<"$state_broken")"
assert_eq "  ... and still prints a valid object rather than aborting" \
  "0" "$(jq -e . >/dev/null 2>&1 <<<"$state_broken"; echo $?)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
