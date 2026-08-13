#!/usr/bin/env bash
#
# test/gather-workflow-basenames.test.sh — regression test for
# scripts/gather-workflow-basenames.sh (requirement 34n's liveness
# retirement, TD-PPagop-26081303): the id -> basename map a `failed-run-<…>`
# void entry is tested against.
#
# Behaviours asserted, each of which fails silently if broken:
#
#   - **A successful read maps each workflow id to its file's basename**,
#     without the `.github/workflows/` prefix or the `.yml`/`.yaml`
#     extension.
#   - **An API failure reports `ok: false` and an empty map** — never a
#     partial map read as complete, which is exactly the "unknown is not
#     gone" failure requirement 34n's liveness rule guards against.
#
# The gatherer is run for real against a stubbed `gh`, matching the pattern
# test/register-hygiene.test.sh already uses.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-workflow-basenames.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-workflow-basenames.sh"

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

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected call: $*" >&2; exit 1; }
case "${STUB_MODE:-hit}" in
  hit)
    # Pre-filtered, the same shape `gh api --jq '...'` itself would print —
    # the stub does not interpret the real script's `--jq` argument, so it
    # prints the filter's own output shape directly (`id` already stringified
    # by the script's own `(.id | tostring)`).
    printf '[{"id":"123","path":".github/workflows/ci.yml"},{"id":"456","path":".github/workflows/sync-framework.yaml"}]\n'
    ;;
  error)
    echo '{"message":"rate limit exceeded","status":"403"}'
    echo "gh: rate limit exceeded (HTTP 403)" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

export STUB_MODE=hit
out="$("$GATHER" "Poetic-Poems/poetic")"
assert_eq "a successful read reports ok: true" "true" "$(jq -r '.ok' <<<"$out")"
assert_eq "each workflow id maps to its file's basename, extension and directory stripped" \
  '{"123":"ci","456":"sync-framework"}' "$(jq -c '.basenames' <<<"$out")"

export STUB_MODE=error
out="$("$GATHER" "Poetic-Poems/poetic" 2>/dev/null)"
assert_eq "an API failure reports ok: false" "false" "$(jq -r '.ok' <<<"$out")"
assert_eq "  ... and an empty map, never a partial one read as complete" \
  "{}" "$(jq -c '.basenames' <<<"$out")"

assert_eq "no slug at all reports ok: false rather than aborting the cycle" \
  "false" "$("$GATHER" 2>/dev/null | jq -r '.ok')"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
