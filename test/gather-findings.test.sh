#!/usr/bin/env bash
#
# test/gather-findings.test.sh — regression test for the argv cap
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 4g; TD-PPagop-26081503)
# in scripts/gather-findings.sh's combine-and-order build.
#
# `$dependabot_json` and `$code_scanning_json` are each a repo's whole open
# finding list — unbounded past this call — and used to ride into the final
# `jq -n` as two separate `--argjson` values. Past `MAX_ARG_STRLEN`
# (131072 bytes) the build dies at `execve`, and a repo with a large backlog
# of open alerts — exactly the repo whose `findings` band matters most —
# comes back empty.
#
# The gatherer is run for real here against a stubbed `gh` (via
# `DASHBOARD_GH_CMD`, the script's own test seam), with the Dependabot list
# fixtured past the cap, so what is asserted is the shipped build rather than
# a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-findings.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-findings.sh"

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

# --- A stub `gh`, driven through DASHBOARD_GH_CMD (the script's own seam) --
# so the real gatherer runs offline. Answers `api --paginate <path>` — the
# one shape gather-findings.sh's `fetch` ever calls — for both alert types.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh-stub.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-} ${2:-}" == "api --paginate" ]] || { echo "stub gh: unexpected call: $*" >&2; exit 1; }
case "$3" in
  repos/*/dependabot/alerts*)    cat "$STUB_DEPENDABOT" ;;
  repos/*/code-scanning/alerts*) cat "$STUB_CODE_SCANNING" ;;
  *) echo "stub gh: unexpected path: $3" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh-stub.sh"
export DASHBOARD_GH_CMD="$tmp_dir/bin/gh-stub.sh"

# --- The fixture: 800 open Dependabot alerts, each padded with a long
# summary, and no code-scanning alerts.
export STUB_DEPENDABOT="$tmp_dir/dependabot.json"
jq -nc '[range(800) | {
  number: .,
  state: "open",
  security_advisory: {severity: "high", summary: ("known vulnerability " + ("x" * 150))},
  security_vulnerability: {severity: "high"},
  dependency: {package: {name: ("pkg-" + (. | tostring))}, manifest_path: "package.json"},
  html_url: ("https://github.com/o/r/security/dependabot/" + (. | tostring))
}]' > "$STUB_DEPENDABOT"
export STUB_CODE_SCANNING="$tmp_dir/code-scanning.json"
printf '[]' > "$STUB_CODE_SCANNING"

out="$("$GATHER" "o/r")"
rc=$?

assert_eq "the gatherer still exits 0 with an oversized dependabot source" "0" "$rc"
assert_eq "every one of the 800 alerts survives into the findings array" \
  "800" "$(jq 'length' <<<"$out")"
assert_eq "the findings array really is past MAX_ARG_STRLEN (131072 bytes)" "1" \
  "$(( $(jq -c '.' <<<"$out" | wc -c) > 131072 ))"
assert_eq "every surviving finding is still security-sourced dependabot" \
  "800" "$(jq '[.[] | select(.source == "security" and .kind == "dependabot")] | length' <<<"$out")"

# --- A real failure (not a disabled feature) still exits 1, loudly ---------
# Requirement 4g's own acceptance discipline: where a converted site
# currently fails loudly, keep it loud (TD-PPagop-26080201's own distinction
# between "disabled" and "broken").
cat >"$tmp_dir/bin/gh-fail.sh" <<'STUB'
#!/usr/bin/env bash
echo '{"message":"rate limit exceeded","status":"403"}'
echo "gh: rate limit exceeded (HTTP 403)" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh-fail.sh"
DASHBOARD_GH_CMD="$tmp_dir/bin/gh-fail.sh" "$GATHER" "o/r" >/dev/null 2>"$tmp_dir/err"
assert_eq "a genuine API failure (rate limit) still exits 1" "1" "$?"
assert_eq "  ... and still leaves gh's own diagnosis on stderr" "1" \
  "$([[ -s "$tmp_dir/err" ]] && echo 1 || echo 0)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
