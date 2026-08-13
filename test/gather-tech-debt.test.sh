#!/usr/bin/env bash
#
# test/gather-tech-debt.test.sh — regression test for
# scripts/gather-tech-debt.sh (requirement 3t, issue #310): the source that
# hands the Co-Ordinator every open tech-debt register item pre-fetched,
# replacing the live tarball-and-grep read the prompt used to ask for.
#
# Behaviours asserted, each of which fails silently if broken:
#
#   - **Only `status: open` items are candidates.** `in-progress`, `resolved`
#     and `not-debt` rows are never selectable and must not appear.
#   - **Each candidate carries the whole item file verbatim as `body`**, plus
#     `id`/`ref` (the same string, the item's own id), `title`, `filed` and
#     `url` — everything the Co-Ordinator needs with no second read.
#   - **Sorted by id ascending** — "lowest tech-debt ID first" (the prompt's
#     own "Selection algorithm").
#   - **A repository with no register, or an unreadable one, contributes `[]`,
#     silently** for the former and loudly (stderr) for the latter — the same
#     distinction scripts/gather-register-hygiene.sh makes and the same trap
#     ("no register" indistinguishable from "no answer") that cost its sibling
#     gatherers a debugging round.
#
# The gatherer is run for real against a stubbed `gh` and the same fixtures
# test/register-hygiene.test.sh uses (test/fixtures/tech-debt-items-*), so the
# assertions are about the shipped script rather than a copy of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-tech-debt.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-tech-debt.sh"
FIXTURES_DIR="$SCRIPT_DIR/test/fixtures"

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

# --- A stub `gh`, the same shape test/register-hygiene.test.sh uses ------------
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${1:-}" == "api" ]] || { echo "stub gh: unexpected call: $*" >&2; exit 1; }
case "${2:-}" in
  */git/trees/*)
    case "${STUB_MODE:-hit}" in
      hit)
        case "${STUB_FORMAT:-peritem}" in
          peritem)
            printf '{"tree":[{"path":"TECH-DEBT.md","type":"blob","sha":"%s"},{"path":"tech-debt","type":"tree","sha":"%s"}]}\n' \
              "$STUB_POLICY_SHA" "$STUB_TREE_SHA"
            ;;
          none)
            printf '{"tree":[{"path":"README.md","type":"blob","sha":"%s"}]}\n' \
              "$STUB_BLOB_SHA"
            ;;
        esac
        ;;
      404)
        echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
        ;;
      *)
        echo "gh: error connecting to api.github.com" >&2
        exit 1
        ;;
    esac
    ;;
  */tarball/*)
    cat "$STUB_TARBALL"
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

make_tarball() {
  local fixture="$1" out="$2" staging
  staging="$(mktemp -d)"
  mkdir -p "$staging/Poetic-Poems-poetic-abc1234"
  cp -r "$fixture"/. "$staging/Poetic-Poems-poetic-abc1234/"
  tar -czf "$out" -C "$staging" Poetic-Poems-poetic-abc1234
  rm -rf "$staging"
}

export STUB_BLOB_SHA="413128de0d60d9502bf469348bc70fbbacccf569"
export STUB_POLICY_SHA="9f2c11d34d5f0b6ba7a1c56d2e8f4a0b1c2d3e4f"
export STUB_TREE_SHA="5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f"
export STUB_TARBALL="$tmp_dir/register.tar.gz"
export STUB_MODE=hit
export STUB_FORMAT=peritem

run() {  # prints stdout; stderr lands in $tmp_dir/err
  "$GATHER" "Poetic-Poems/poetic" main 2>"$tmp_dir/err"
}

# --- Only status:open items are candidates, whole file verbatim -----------------
#
# tech-debt-items-consistent carries one open item (TD-PPtest-26071501) and one
# resolved item (TD-PPtest-26071502, which must never appear).
make_tarball "$FIXTURES_DIR/tech-debt-items-consistent" "$STUB_TARBALL"
out="$(run)"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "exactly the one open item is a candidate" "1" "$(jq 'length' <<<"$out")"
assert_eq "the resolved item is dropped" "0" \
  "$(jq '[.[] | select(.id == "TD-PPtest-26071502")] | length' <<<"$out")"
assert_eq "source is tech-debt" "tech-debt" "$(jq -r '.[0].source' <<<"$out")"
assert_eq "ref is the item's own id" "TD-PPtest-26071501" "$(jq -r '.[0].ref' <<<"$out")"
assert_eq "id is the item's own id" "TD-PPtest-26071501" "$(jq -r '.[0].id' <<<"$out")"
assert_eq "title is read from frontmatter" \
  "An open item carried over from the legacy register" "$(jq -r '.[0].title' <<<"$out")"
assert_eq "filed is read from frontmatter" "2026-07-15" "$(jq -r '.[0].filed' <<<"$out")"
assert_eq "url points at the item file on the default branch" \
  "https://github.com/Poetic-Poems/poetic/blob/main/tech-debt/TD-PPtest-26071501.md" \
  "$(jq -r '.[0].url' <<<"$out")"
expected_body="$(cat "$FIXTURES_DIR/tech-debt-items-consistent/tech-debt/TD-PPtest-26071501.md")"
assert_eq "body is the whole item file verbatim, frontmatter included" "$expected_body" \
  "$(jq -r '.[0].body' <<<"$out")"

# --- Multiple open items, sorted by id ascending ---------------------------------
#
# tech-debt-items-drifted carries three open items (a register-hygiene fixture,
# reused here purely for its open rows — this gatherer does not run td-check.pl
# and does not care that the register disagrees with itself).
make_tarball "$FIXTURES_DIR/tech-debt-items-drifted" "$STUB_TARBALL"
out="$(run)"; rc=$?
assert_eq "  ... still exits 0" "0" "$rc"
assert_eq "every open item in the fixture is a candidate" "3" "$(jq 'length' <<<"$out")"
assert_eq "sorted by id ascending" \
  "TD-PPtest-26071501 TD-PPtest-26071599 TD-XXwron-26071601" \
  "$(jq -r '[.[].id] | join(" ")' <<<"$out")"

# --- A repository with no register is a normal, silent [] -----------------------
export STUB_FORMAT=none
out="$(run)"; rc=$?
assert_eq "a repository with no register contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... and says nothing on stderr — a missing register is not an error" \
  "" "$(cat "$tmp_dir/err")"
export STUB_FORMAT=peritem

export STUB_MODE=404
out="$(run)"; rc=$?
assert_eq "a repository that is gone (404) contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... and silently — the API body said 404, not error" \
  "" "$(cat "$tmp_dir/err")"

# --- An API failure is [] as well, but a loud one -------------------------------
export STUB_MODE=error
out="$(run)"; rc=$?
assert_eq "an API failure contributes [] too" "[]" "$out"
assert_eq "  ... and still exits 0" "0" "$rc"
assert_eq "  ... but leaves gh's diagnosis on stderr, unlike the 404" \
  "1" "$( [[ -s "$tmp_dir/err" ]] && echo 1 || echo 0 )"
export STUB_MODE=hit

# --- The gatherer fails safe against the real API too ---------------------------
assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$(PATH="${PATH#"$tmp_dir/bin:"}" "$GATHER" "Poetic-Poems/does-not-exist" main 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
