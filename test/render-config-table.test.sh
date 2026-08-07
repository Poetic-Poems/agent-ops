#!/usr/bin/env bash
#
# test/render-config-table.test.sh — self-contained regression test for
# scripts/render-config-table.sh (#198, #215).
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
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'FAIL - %s\n     expected NOT to contain: %s\n' "$desc" "$needle"
    failures=$(( failures + 1 ))
  else
    pass "$desc"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts" "$tmp/docs"
cp "$SCRIPT_DIR/scripts/render-config-table.sh" "$tmp/scripts/render-config-table.sh"
chmod +x "$tmp/scripts/render-config-table.sh"

# --- Fixture schema. Covers: no x-docs (falls back to description); a
#     default with no x-docs.value; four distinct x-docs.value rows that must
#     render verbatim; an x-docs.value keyed per audience, both with and
#     without an entry for the audience being rendered; an empty-string
#     default; a `|` inside prose; one level of nesting under "schedule" (the
#     "main" region) and under "review" (its own region); and four notes-cap
#     cases — a plain note over 500 characters (`mu`), one whose naive
#     480-character cut point lands inside a code span (`nu`) and inside a
#     link (`xi`), and a dotted key that overflows
#     (`schedule.overflow_key`) — plus one more dotted overflow in the
#     "review" region (`review.overflow_sub`) to exercise notes-region
#     heading derivation there too. Every overflowing note here carries only
#     `x-docs.readme`, so the two specs' (audience "spec") regions render
#     these particular rows short, falling back to `description` — deliberate,
#     so the specs' own Extended-notes regions stay exercised as the "nothing
#     overflows" empty case. ---
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
    "theta": {
      "description": "Theta description.",
      "default": 4,
      "x-docs": { "readme": "Theta readme prose.", "spec": "Theta spec prose.", "value": { "spec": "4 h" } }
    },
    "iota": {
      "description": "Iota description.",
      "x-docs": { "value": { "readme": "see `config.json`", "spec": "`[\"a\", \"b\"]`" } }
    },
    "kappa": {
      "description": "Kappa description.",
      "default": ""
    },
    "mu": {
      "description": "Mu description.",
      "x-docs": { "readme": "lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem" }
    },
    "nu": {
      "description": "Nu description.",
      "x-docs": { "readme": "lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem `abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ` ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt." }
    },
    "xi": {
      "description": "Xi description.",
      "x-docs": { "readme": "lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem [a fairly long link label spanning well past the boundary](https://example.com/somewhere) ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt." }
    },
    "schedule": {
      "properties": {
        "nested_key": {
          "description": "Nested key description.",
          "default": "nested-default"
        },
        "overflow_key": {
          "description": "Overflow key description.",
          "default": "sched-default",
          "x-docs": { "readme": "lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore." }
        }
      }
    },
    "review": {
      "properties": {
        "sub_key": {
          "description": "Sub key description.",
          "x-docs": { "value": "`sub-value`" }
        },
        "overflow_sub": {
          "description": "Overflow sub description.",
          "x-docs": { "readme": "lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem lorem" }
        }
      }
    }
  }
}
JSON

# --- Fixture docs. README.md carries both regions; the two specs each carry
#     one, matching the real repository's layout. The "main" region starts
#     deliberately stale — missing "beta" entirely and carrying a hand-edited
#     "gamma" row — so the first render must both add and restore rows. Each
#     table region is paired with a notes region, each preceded by an ATX
#     heading so its level can be derived; the review notes region sits under
#     a level-6 heading on purpose, to prove the "clamped at 6" rule (a naive
#     `+1` would try for a nonexistent level 7). ---
write_fixture_readme() {
  cat > "$tmp/README.md" <<'MD'
# Fixture

Sentinel before.

<!-- config-table:start id=main -->
| Key | Default | Notes |
|---|---|---|
| `alpha` | `"stale"` | stale notes |
| `gamma` | `hand-edited-value` | hand-edited notes |
<!-- config-table:end -->

## Extended notes heading (main)

<!-- config-table:notes id=main -->
<!-- config-table:notes-end -->

Sentinel between.

<!-- config-table:start id=review -->
| Key | Default | Notes |
|---|---|---|
<!-- config-table:end -->

###### Deep heading for review notes

<!-- config-table:notes id=review -->
<!-- config-table:notes-end -->

Sentinel after.
MD
}

write_fixture_impl_spec() {
  cat > "$tmp/docs/IMPLEMENTATION-PIPELINE-SPEC.md" <<'MD'
# Fixture spec

<!-- config-table:start id=main -->
| Key | Value | Notes |
|---|---|---|
<!-- config-table:end -->

<!-- config-table:notes id=main -->
<!-- config-table:notes-end -->
MD
}

write_fixture_review_spec() {
  cat > "$tmp/docs/REVIEW-PIPELINE-SPEC.md" <<'MD'
# Fixture review spec

<!-- config-table:start id=review -->
| Key | Value | Notes |
|---|---|---|
<!-- config-table:end -->

<!-- config-table:notes id=review -->
<!-- config-table:notes-end -->
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

# --- A default with no x-docs.value renders the schema default: a non-empty
#     string bare (so a label does not read `"b-default"` beside the rows
#     whose value comes from x-docs.value), anything else as compact JSON ---
# shellcheck disable=SC2016
assert_contains "beta's string default renders bare in backticks" "$main_region" '| `beta` | `b-default` |'
# shellcheck disable=SC2016
assert_contains "epsilon's numeric default renders as compact JSON in backticks" "$main_region" '| `epsilon` | `5` |'
# shellcheck disable=SC2016
assert_contains "kappa's empty-string default stays visible as compact JSON" "$main_region" '| `kappa` | `""` | Kappa description. |'

# --- The four x-docs.value rows render verbatim ---
# shellcheck disable=SC2016
assert_contains "gamma's x-docs.value renders verbatim" "$main_region" '| `gamma` | `gamma-value` |'
# shellcheck disable=SC2016
assert_contains "delta's x-docs.value renders verbatim" "$main_region" '| `delta` | *(delta-required)* |'
# shellcheck disable=SC2016
assert_contains "zeta's x-docs.value renders verbatim" "$main_region" '| `zeta` | see `config.json` |'
# shellcheck disable=SC2016
assert_contains "eta's x-docs.value renders verbatim" "$main_region" '| `eta` | *(eta-value)* |'

# --- A per-audience x-docs.value gives each document its own value cell:
#     iota has one for both, theta only for the spec (so the README falls
#     through to theta's schema default) ---
# shellcheck disable=SC2016
assert_contains "iota's per-audience value renders the README's" "$main_region" '| `iota` | see `config.json` |'
# shellcheck disable=SC2016
assert_contains "theta falls through to its default for the README" "$main_region" '| `theta` | `4` | Theta readme prose. |'

# --- A `|` inside prose survives (escaped, so the table stays well-formed) ---
# shellcheck disable=SC2016
epsilon_line="$(grep '`epsilon`' "$tmp/README.md")"
assert_contains "a pipe in prose is escaped" "$epsilon_line" 'left \| right'
total_pipes="$(grep -o '|' <<<"$epsilon_line" | wc -l)"
escaped_pipes="$(grep -o -F '\|' <<<"$epsilon_line" | wc -l)"
assert_eq "the epsilon row still has exactly 4 unescaped pipes (3 columns)" "4" "$(( total_pipes - escaped_pipes ))"

# --- Nesting renders as dotted keys in the parent's position ---
# shellcheck disable=SC2016
assert_contains "schedule.nested_key renders dotted, in the main region" "$main_region" '| `schedule.nested_key` | `nested-default` | Nested key description. |'

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
# shellcheck disable=SC2016
assert_contains "the impl spec renders theta's own value cell" "$impl_spec_content" '| `theta` | 4 h | Theta spec prose. |'
# shellcheck disable=SC2016
assert_contains "the impl spec renders iota's own value cell" "$impl_spec_content" '| `iota` | `["a", "b"]` |'
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

# ============================================================================
# Notes cap (#215): a note over 500 characters is truncated at an atom
# boundary and deferred to the matching Extended notes region.
# ============================================================================

main_notes_region="$(awk '/<!-- config-table:notes id=main -->/{f=1;next} /<!-- config-table:notes-end -->/{f=0} f' "$tmp/README.md")"
review_notes_region="$(awk '/<!-- config-table:notes id=review -->/{f=1;next} /<!-- config-table:notes-end -->/{f=0} f' "$tmp/README.md")"

# --- A plain over-long note (mu) is truncated with a continuation link, and
#     no truncated Notes cell in the region exceeds the 500-character cap
#     (cell content only — the `| ` / ` |` padding and the link target are
#     not counted, per the issue's own rule) ---
# shellcheck disable=SC2016
mu_line="$(grep '`mu`' "$tmp/README.md" | head -1)"
assert_contains "mu's row carries the continuation link" "$mu_line" '...[continued below](#extended-notes-mu)'
while IFS= read -r row; do
  [[ "$row" == *'[continued below]'* ]] || continue
  # shellcheck disable=SC2016
  cell="$(sed -E 's/^\| `[^`]+` \| [^|]*\| (.*) \|$/\1/' <<<"$row")"
  cell_no_target="${cell%(#*)}"
  if (( ${#cell_no_target} > 500 )); then
    fail "Notes cell for row does not exceed 500 counted characters: $row"
  fi
done <<<"$main_region"
pass "no truncated Notes cell in the main region exceeds the 500-character cap"

# --- The cut never lands inside a code span (nu) or a link (xi): the
#     truncated cell backs off to the word before the construct rather than
#     splitting it, so it carries no unmatched backtick or link bracket ---
# shellcheck disable=SC2016
nu_line="$(grep '`nu`' "$tmp/README.md" | head -1)"
assert_contains "nu's row carries the continuation link" "$nu_line" '...[continued below](#extended-notes-nu)'
assert_not_contains "nu's truncated cell does not carry the code span (backed off before it)" "$nu_line" 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
# shellcheck disable=SC2016
nu_cell="$(sed -E 's/^\| `nu` \| [^|]*\| (.*) \|$/\1/' <<<"$nu_line")"
nu_backticks="$(grep -o '`' <<<"$nu_cell" | wc -l)"
assert_eq "nu's truncated cell has an even number of backticks (no unclosed code span)" "0" "$(( nu_backticks % 2 ))"

# shellcheck disable=SC2016
xi_line="$(grep '`xi`' "$tmp/README.md" | head -1)"
assert_contains "xi's row carries the continuation link" "$xi_line" '...[continued below](#extended-notes-xi)'
assert_not_contains "xi's truncated cell does not carry the embedded link (backed off before it)" "$xi_line" 'example.com'

# --- A dotted key's slug drops the dot rather than the whole segment ---
# shellcheck disable=SC2016
sched_line="$(grep '`schedule.overflow_key`' "$tmp/README.md" | head -1)"
assert_contains "schedule.overflow_key's row slugs the dotted key with the dot dropped" "$sched_line" '...[continued below](#extended-notes-scheduleoverflow_key)'

# --- Every over-long note appears in full, verbatim (pipes unescaped), in
#     its own Extended notes subsection — and only the over-long ones.
#     Headings are matched with a leading newline so a run of the wrong
#     number of `#`s can never satisfy the check by substring overlap (e.g.
#     "#### Extended notes: `mu`" contains "### Extended notes: `mu`" as a
#     bare substring, one character in) — the level must be exact. ---
# shellcheck disable=SC2016
assert_contains "the main notes region has a level-3 heading for mu" "$main_notes_region" $'\n### Extended notes: `mu`'
# shellcheck disable=SC2016
assert_contains "the main notes region has a level-3 heading for nu" "$main_notes_region" $'\n### Extended notes: `nu`'
# shellcheck disable=SC2016
assert_contains "the main notes region has a level-3 heading for xi" "$main_notes_region" $'\n### Extended notes: `xi`'
# shellcheck disable=SC2016
assert_contains "the main notes region has a level-3 heading for schedule.overflow_key" "$main_notes_region" $'\n### Extended notes: `schedule.overflow_key`'
# shellcheck disable=SC2016
assert_contains "nu's full note (code span intact) appears in the notes region" "$main_notes_region" '`abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ`'
assert_contains "xi's full note (link intact) appears in the notes region" "$main_notes_region" '(https://example.com/somewhere)'
# shellcheck disable=SC2016
assert_not_contains "a note that fits (beta) gets no Extended notes subsection" "$main_notes_region" '### Extended notes: `beta`'

# --- The main heading level above (level 3) comes from "## Extended notes
#     heading (main)" being level 2; the review region below proves the
#     other end — clamped at 6: it sits under a level-6 heading, so a naive
#     +1 (level 7, not valid Markdown) is clamped back down to 6 rather than
#     emitted as-is. The leading-newline anchor above is what makes the
#     level-3 assertions already exact; this one is the level-6 analogue. ---
# shellcheck disable=SC2016
assert_contains "review.overflow_sub's row carries the continuation link" "$review_region_readme" '...[continued below](#extended-notes-reviewoverflow_sub)'
# shellcheck disable=SC2016
assert_contains "the review notes heading is clamped to exactly level 6" "$review_notes_region" $'\n###### Extended notes: `review.overflow_sub`'

# --- --check stays clean on the freshly rewritten tree, including the notes
#     regions, and stays a no-op on a second render ---
before_hash="$(cat "$tmp/README.md" "$tmp"/docs/*.md | sha256sum)"
run_script --check >/dev/null 2>&1
fresh_check_rc=$?
assert_eq "--check exits zero on a fresh tree" "0" "$fresh_check_rc"
run_script >/dev/null
after_hash="$(cat "$tmp/README.md" "$tmp"/docs/*.md | sha256sum)"
assert_eq "regenerating a fresh tree is a no-op" "$before_hash" "$after_hash"

# --- A stale Extended notes subsection is refused, naming the region and
#     the first differing key, the same way a stale table row is ---
cp "$tmp/README.md" "$tmp/README.md.bak"
# shellcheck disable=SC2016
sed -i 's/### Extended notes: `mu`/### Extended notes: `mu` (EDITED)/' "$tmp/README.md"
stale_notes_out="$(run_script --check 2>&1)"
stale_notes_rc=$?
if (( stale_notes_rc != 0 )); then
  pass "--check exits non-zero on a stale Extended notes subsection"
else
  fail "--check exits non-zero on a stale Extended notes subsection (got rc=0)"
fi
assert_contains "the stale-notes error names the region" "$stale_notes_out" "id=main"
assert_contains "the stale-notes error names the first differing key" "$stale_notes_out" "mu"
mv "$tmp/README.md.bak" "$tmp/README.md"

# --- A missing notes-region marker pair is refused, naming the file and
#     region, rather than silently skipping the region ---
cp "$tmp/README.md" "$tmp/README.md.bak"
# shellcheck disable=SC2016
grep -v '^<!-- config-table:notes id=main -->$' "$tmp/README.md" > "$tmp/README.nomarker" && mv "$tmp/README.nomarker" "$tmp/README.md"
missing_marker_out="$(run_script --check 2>&1)"
missing_marker_rc=$?
if (( missing_marker_rc != 0 )); then
  pass "--check exits non-zero when a notes-region marker is missing"
else
  fail "--check exits non-zero when a notes-region marker is missing (got rc=0)"
fi
assert_contains "the missing-marker error names the file" "$missing_marker_out" "README.md"
assert_contains "the missing-marker error names the region" "$missing_marker_out" "id=main"
mv "$tmp/README.md.bak" "$tmp/README.md"

# --- A notes-region marker with no ATX heading above it is a hard failure,
#     in both modes, not just a --check staleness report ---
cp "$tmp/README.md" "$tmp/README.md.bak"
{
  printf '<!-- config-table:notes id=main -->\n<!-- config-table:notes-end -->\n'
  cat "$tmp/README.md"
} > "$tmp/README.orphan" && mv "$tmp/README.orphan" "$tmp/README.md"
no_heading_out="$(run_script --check 2>&1)"
no_heading_rc=$?
if (( no_heading_rc != 0 )); then
  pass "a notes marker with no heading above it is refused"
else
  fail "a notes marker with no heading above it is refused (got rc=0)"
fi
assert_contains "the no-heading error names the region" "$no_heading_out" "id=main"
mv "$tmp/README.md.bak" "$tmp/README.md"

# --- Two keys whose Extended notes headings would slug the same are
#     refused rather than silently landing on the same anchor (a duplicate
#     `#extended-notes-mu` here, since GitHub's own slugging is
#     case-insensitive) ---
cp "$tmp/config.schema.json" "$tmp/config.schema.json.bak"
jq '.properties.MU = .properties.mu' "$tmp/config.schema.json" > "$tmp/config.schema.json.dup" && mv "$tmp/config.schema.json.dup" "$tmp/config.schema.json"
dup_slug_out="$(run_script --check 2>&1)"
dup_slug_rc=$?
if (( dup_slug_rc != 0 )); then
  pass "two headings slugging the same are refused"
else
  fail "two headings slugging the same are refused (got rc=0)"
fi
assert_contains "the duplicate-slug error names the slug" "$dup_slug_out" "extended-notes-mu"
mv "$tmp/config.schema.json.bak" "$tmp/config.schema.json"

# --- A region whose delimiter row is missing from its first two lines is
#     refused rather than rendered into something GitHub shows as prose ---
awk '
  /^<!-- config-table:start id=review -->$/ { print; c = 1; next }
  c == 1 { print; c = 2; next }   # header row - keep
  c == 2 { c = 3; next }          # delimiter row - drop
  { print }
' "$tmp/README.md" > "$tmp/README.nodelim" && mv "$tmp/README.nodelim" "$tmp/README.md"
delim_out="$(run_script --check 2>&1)"
delim_rc=$?
if (( delim_rc != 0 )); then
  pass "a region with no delimiter row in its first two lines is refused"
else
  fail "a region with no delimiter row in its first two lines is refused (got rc=0)"
fi
assert_contains "the delimiter-row error names the region" "$delim_out" "id=review"
write_fixture_readme
run_script >/dev/null

echo
if (( failures == 0 )); then
  echo "render-config-table.test.sh: all assertions passed"
  exit 0
else
  echo "render-config-table.test.sh: $failures assertion(s) failed"
  exit 1
fi
