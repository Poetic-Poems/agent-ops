#!/usr/bin/env bash
#
# test/render-toc.test.sh — self-contained regression test for
# scripts/render-toc.sh (#1402).
#
# Runs the actual shipped script (copied byte-for-byte into a scratch
# "repository" built from fixture docs) rather than a reimplementation of its
# logic, so this test exercises the real heading extraction, the real
# marker-pair validation and the real --check diffing.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/render-toc.test.sh
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
cp "$SCRIPT_DIR/scripts/render-toc.sh" "$tmp/scripts/render-toc.sh"
chmod +x "$tmp/scripts/render-toc.sh"

# --- Fixture docs: README.md carries a deliberately stale ToC region (a
#     heading was added without regenerating); the impl spec fixture carries
#     an already-fresh region, so the "fresh tree is a no-op" case is covered
#     on a second file too. ---
write_fixture_readme() {
  cat > "$tmp/README.md" <<'MD'
# Fixture

Sentinel before.

<!-- toc:start -->
- [Old Heading](#old-heading)
<!-- toc:end -->

Sentinel between.

## First Heading

### A Sub Heading

## Second Heading

Sentinel after.
MD
}

write_fixture_impl_spec() {
  cat > "$tmp/docs/IMPLEMENTATION-PIPELINE-SPEC.md" <<'MD'
# Fixture spec

<!-- toc:start -->
- [Alpha Section](#alpha-section)
- [Beta Section](#beta-section)
<!-- toc:end -->

## Alpha Section

## Beta Section
MD
}

write_fixture_readme
write_fixture_impl_spec

run_script() (
  cd "$tmp" && ./scripts/render-toc.sh "$@"
)

# --- --check on a stale tree: non-zero ---
check_out="$(run_script --check 2>&1)"
check_rc=$?
if (( check_rc != 0 )); then
  pass "--check exits non-zero on a stale region"
else
  fail "--check exits non-zero on a stale region (got rc=0)"
fi
assert_contains "--check names the stale file" "$check_out" "README.md"

# --- Rewrite in place ---
run_script >/dev/null
rewrite_rc=$?
assert_eq "rewriting in place exits 0" "0" "$rewrite_rc"

readme_content="$(cat "$tmp/README.md")"
assert_contains "the regenerated ToC lists First Heading" "$readme_content" "- [First Heading](#first-heading)"
assert_contains "the regenerated ToC nests A Sub Heading" "$readme_content" "  - [A Sub Heading](#a-sub-heading)"
assert_contains "the regenerated ToC lists Second Heading" "$readme_content" "- [Second Heading](#second-heading)"
if [[ "$readme_content" == *"Old Heading"* ]]; then
  fail "the stale Old Heading entry is gone"
else
  pass "the stale Old Heading entry is gone"
fi
assert_contains "text before the region survives" "$readme_content" "Sentinel before."
assert_contains "text between the region and headings survives" "$readme_content" "Sentinel between."
assert_contains "text after the headings survives" "$readme_content" "Sentinel after."

# --- --check stays clean on the freshly rewritten tree, and regenerating
#     again is a no-op ---
before_hash="$(cat "$tmp/README.md" "$tmp"/docs/*.md | sha256sum)"
run_script --check >/dev/null 2>&1
fresh_check_rc=$?
assert_eq "--check exits zero on a fresh tree" "0" "$fresh_check_rc"
run_script >/dev/null
after_hash="$(cat "$tmp/README.md" "$tmp"/docs/*.md | sha256sum)"
assert_eq "regenerating a fresh tree is a no-op" "$before_hash" "$after_hash"

# ============================================================================
# Marker validation (#1402): a file with no toc:start/toc:end markers, or
# with only one of the pair, or with more than one of either, is refused
# rather than silently copied through unchanged.
# ============================================================================

# --- Both markers missing entirely ---
cp "$tmp/README.md" "$tmp/README.md.bak"
sed -i '/<!-- toc:start -->/,/<!-- toc:end -->/d' "$tmp/README.md"
missing_regen_out="$(run_script 2>&1)"
missing_regen_rc=$?
if (( missing_regen_rc != 0 )); then
  pass "regenerate mode refuses a file with no toc markers"
else
  fail "regenerate mode refuses a file with no toc markers (got rc=0)"
fi
assert_contains "the no-markers error (regenerate mode) names the file" "$missing_regen_out" "README.md"
missing_check_out="$(run_script --check 2>&1)"
missing_check_rc=$?
if (( missing_check_rc != 0 )); then
  pass "--check mode refuses a file with no toc markers"
else
  fail "--check mode refuses a file with no toc markers (got rc=0)"
fi
assert_contains "the no-markers error (--check mode) names the file" "$missing_check_out" "README.md"
mv "$tmp/README.md.bak" "$tmp/README.md"

# --- Only the start marker present (end missing) ---
cp "$tmp/README.md" "$tmp/README.md.bak"
grep -v '^<!-- toc:end -->$' "$tmp/README.md" > "$tmp/README.md.tmp" && mv "$tmp/README.md.tmp" "$tmp/README.md"
only_start_out="$(run_script --check 2>&1)"
only_start_rc=$?
if (( only_start_rc != 0 )); then
  pass "--check refuses a file with only the start marker"
else
  fail "--check refuses a file with only the start marker (got rc=0)"
fi
assert_contains "the unpaired-start error names the file" "$only_start_out" "README.md"
mv "$tmp/README.md.bak" "$tmp/README.md"

# --- Only the end marker present (start missing) ---
cp "$tmp/README.md" "$tmp/README.md.bak"
grep -v '^<!-- toc:start -->$' "$tmp/README.md" > "$tmp/README.md.tmp" && mv "$tmp/README.md.tmp" "$tmp/README.md"
only_end_out="$(run_script --check 2>&1)"
only_end_rc=$?
if (( only_end_rc != 0 )); then
  pass "--check refuses a file with only the end marker"
else
  fail "--check refuses a file with only the end marker (got rc=0)"
fi
assert_contains "the unpaired-end error names the file" "$only_end_out" "README.md"
mv "$tmp/README.md.bak" "$tmp/README.md"

# --- More than one marker pair ---
cp "$tmp/README.md" "$tmp/README.md.bak"
sed -i '0,/<!-- toc:end -->/{s/<!-- toc:end -->/<!-- toc:end -->\n<!-- toc:start -->\n- extra\n<!-- toc:end -->/}' "$tmp/README.md"
dup_out="$(run_script --check 2>&1)"
dup_rc=$?
if (( dup_rc != 0 )); then
  pass "--check refuses a file with more than one marker pair"
else
  fail "--check refuses a file with more than one marker pair (got rc=0)"
fi
assert_contains "the duplicate-markers error names the file" "$dup_out" "README.md"
mv "$tmp/README.md.bak" "$tmp/README.md"

# --- A correctly paired region is unaffected: --check is clean afterwards ---
run_script --check >/dev/null 2>&1
final_check_rc=$?
assert_eq "a correctly paired region still checks clean after all the above" "0" "$final_check_rc"

echo
if (( failures == 0 )); then
  echo "render-toc.test.sh: all assertions passed"
  exit 0
else
  echo "render-toc.test.sh: $failures assertion(s) failed"
  exit 1
fi
