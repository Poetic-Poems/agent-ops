#!/usr/bin/env bash
#
# test/render-config-table.test.sh — self-contained regression test for
# scripts/render-config-table.sh (#198).
#
# Runs the actual shipped script (copied byte-for-byte into a scratch
# "repository" built from a small fixture schema and fixture docs) rather
# than a reimplementation of its logic, so this test exercises the real
# marker parsing, the real jq row rendering and the real --check diffing.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/render-config-table.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$(( failures + 1 )); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:               %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts" "$tmp/docs"
cp "$SCRIPT_DIR/scripts/render-config-table.sh" "$tmp/scripts/render-config-table.sh"
chmod +x "$tmp/scripts/render-config-table.sh"

# --- Fixture schema. Covers: no x-docs (falls back to description); a
#     default with no x-docs.value; four distinct x-docs.value rows that must
#     render verbatim; a `|` inside prose; one level of nesting under
#     "schedule" (the "main" region) and under "review" (its own region). ---
cat > "$tmp/config.schema.json" <<'JSON'
{
  "properties": {
    "alpha": {
      "description": "Alpha description fallback."
    },
    "beta": {
      "description": "Beta short.",
      "default": "b-default",
      "x-docs": { "readme": "Beta readme prose.", "spec": "Beta spec prose." }
    },
    "gamma": {
      "description": "Gamma short.",
      "x-docs": { "readme": "Gamma readme prose.", "spec": "Gamma spec prose.", "value": "`gamma-value`" }
    },
    "delta": {
      "description": "Delta description fallback.",
      "x-docs": { "value": "*(delta-required)*" }
    },
    "epsilon": {
      "description": "Epsilon description.",
      "default": 5,
      "x-docs": { "readme": "Epsilon prose with a pipe: left | right.", "spec": "Epsilon spec prose." }
    },
    "zeta": {
      "description": "Zeta description.",
      "x-docs": { "value": "see `config.json`" }
    },
    "eta": {
      "description": "Eta description fallback.",
      "x-docs": { "value": "*(eta-value)*" }
    },
    "schedule": {
      "properties": {
        "nested_key": {
          "description": "Nested key description.",
          "default": "nested-default"
        }
      }
    },
    "review": {
      "properties": {
        "sub_key": {
          "description": "Sub key description.",
          "x-docs": { "value": "`sub-value`" }
        }
      }
    }
  }
}
JSON

# --- Fixture docs. README.md carries both regions; the two specs each carry
#     one, matching the real repository's layout. The "main" region starts
#     deliberately stale — missing "beta" entirely and carrying a hand-edited
#     "gamma" row — so the first render must both add and restore rows. ---
write_fixture_readme() {
  cat > "$tmp/README.md" <<'MD'
# Fixture

Sentinel before.

| Key | Default | Notes |
|---|---|---|
<!-- config-table:start id=main -->
| `alpha` | `"stale"` | stale notes |
| `gamma` | `hand-edited-value` | hand-edited notes |
<!-- config-table:end -->

Sentinel between.

| Key | Default | Notes |
|---|---|---|
<!-- config-table:start id=review -->
<!-- config-table:end -->

Sentinel after.
MD
}

write_fixture_impl_spec() {
  cat > "$tmp/docs/IMPLEMENTATION-PIPELINE-SPEC.md" <<'MD'
# Fixture spec

| Key | Value | Notes |
|---|---|---|
<!-- config-table:start id=main -->
<!-- config-table:end -->
MD
}

write_fixture_review_spec() {
  cat > "$tmp/docs/REVIEW-PIPELINE-SPEC.md" <<'MD'
# Fixture review spec

| Key | Value | Notes |
|---|---|---|
<!-- config-table:start id=review -->
<!-- config-table:end -->
MD
}

write_fixture_readme
write_fixture_impl_spec
write_fixture_review_spec

run_script() (
  cd "$tmp" && ./scripts/render-config-table.sh "$@"
)

# --- --check on a stale tree: non-zero, and names the file + first key ---
check_out="$(run_script --check 2>&1)"
check_rc=$?
if (( check_rc != 0 )); then
  pass "--check exits non-zero on a stale region"
else
  fail "--check exits non-zero on a stale region (got rc=0)"
fi
assert_contains "--check names the stale file" "$check_out" "README.md"
assert_contains "--check names the first differing key" "$check_out" "alpha"

# --- Rewrite in place ---
run_script >/dev/null
rewrite_rc=$?
assert_eq "rewriting in place exits 0" "0" "$rewrite_rc"

main_region="$(awk '/<!-- config-table:start id=main -->/{f=1;next} /<!-- config-table:end -->/{f=0} f' "$tmp/README.md")"

# --- A key present in the schema and absent from the region is added ---
# shellcheck disable=SC2016
assert_contains "a missing key (beta) is added" "$main_region" '| `beta` |'

# --- A hand-edited row is restored ---
# The backticks below are literal Markdown, not shell command substitution.
# shellcheck disable=SC2016
assert_contains "a hand-edited row (gamma) is restored" "$main_region" '| `gamma` | `gamma-value` | Gamma readme prose. |'
if [[ "$main_region" == *"hand-edited"* ]]; then
  fail "the hand-edited gamma row's stale text is gone"
else
  pass "the hand-edited gamma row's stale text is gone"
fi

# --- A key with no x-docs falls back to description (alpha has no default
#     either, so its value cell is the required marker) ---
# shellcheck disable=SC2016
assert_contains "alpha (no x-docs) falls back to description" "$main_region" '| `alpha` | *(required)* | Alpha description fallback. |'

# --- A default with no x-docs.value renders the schema default ---
# shellcheck disable=SC2016
assert_contains "beta's default renders as compact JSON in backticks" "$main_region" '| `beta` | `"b-default"` |'

# --- The four x-docs.value rows render verbatim ---
# shellcheck disable=SC2016
assert_contains "gamma's x-docs.value renders verbatim" "$main_region" '| `gamma` | `gamma-value` |'
# shellcheck disable=SC2016
assert_contains "delta's x-docs.value renders verbatim" "$main_region" '| `delta` | *(delta-required)* |'
# shellcheck disable=SC2016
assert_contains "zeta's x-docs.value renders verbatim" "$main_region" '| `zeta` | see `config.json` |'
# shellcheck disable=SC2016
assert_contains "eta's x-docs.value renders verbatim" "$main_region" '| `eta` | *(eta-value)* |'

# --- A `|` inside prose survives (escaped, so the table stays well-formed) ---
# shellcheck disable=SC2016
epsilon_line="$(grep '`epsilon`' "$tmp/README.md")"
assert_contains "a pipe in prose is escaped" "$epsilon_line" 'left \| right'
total_pipes="$(grep -o '|' <<<"$epsilon_line" | wc -l)"
escaped_pipes="$(grep -o -F '\|' <<<"$epsilon_line" | wc -l)"
assert_eq "the epsilon row still has exactly 4 unescaped pipes (3 columns)" "4" "$(( total_pipes - escaped_pipes ))"

# --- Nesting renders as dotted keys in the parent's position ---
# shellcheck disable=SC2016
assert_contains "schedule.nested_key renders dotted, in the main region" "$main_region" '| `schedule.nested_key` | `"nested-default"` | Nested key description. |'

review_region_readme="$(awk '/<!-- config-table:start id=review -->/{f=1;next} /<!-- config-table:end -->/{f=0} f' "$tmp/README.md")"
# shellcheck disable=SC2016
assert_contains "review.sub_key renders dotted, in its own region" "$review_region_readme" '| `review.sub_key` | `sub-value` | Sub key description. |'
if [[ "$main_region" == *"review.sub_key"* ]]; then
  fail "review.sub_key does not leak into the main region"
else
  pass "review.sub_key does not leak into the main region"
fi

# --- The two specs use the "spec" audience, not "readme" ---
impl_spec_content="$(cat "$tmp/docs/IMPLEMENTATION-PIPELINE-SPEC.md")"
assert_contains "the impl spec renders x-docs.spec prose" "$impl_spec_content" 'Gamma spec prose.'
if [[ "$impl_spec_content" == *"Gamma readme prose."* ]]; then
  fail "the impl spec does not render the README's prose"
else
  pass "the impl spec does not render the README's prose"
fi

review_spec_content="$(cat "$tmp/docs/REVIEW-PIPELINE-SPEC.md")"
# shellcheck disable=SC2016
assert_contains "the review spec renders review.sub_key" "$review_spec_content" '| `review.sub_key` |'

# --- Sentinels outside the markers are untouched ---
readme_content="$(cat "$tmp/README.md")"
assert_contains "text before the main region survives" "$readme_content" "Sentinel before."
assert_contains "text between the two regions survives" "$readme_content" "Sentinel between."
assert_contains "text after the review region survives" "$readme_content" "Sentinel after."

# --- --check exits zero on a freshly rewritten tree, and stays a no-op ---
before_hash="$(cat "$tmp/README.md" "$tmp"/docs/*.md | sha256sum)"
run_script --check >/dev/null 2>&1
fresh_check_rc=$?
assert_eq "--check exits zero on a fresh tree" "0" "$fresh_check_rc"
run_script >/dev/null
after_hash="$(cat "$tmp/README.md" "$tmp"/docs/*.md | sha256sum)"
assert_eq "regenerating a fresh tree is a no-op" "$before_hash" "$after_hash"

echo
if (( failures == 0 )); then
  echo "render-config-table.test.sh: all assertions passed"
  exit 0
else
  echo "render-config-table.test.sh: $failures assertion(s) failed"
  exit 1
fi
