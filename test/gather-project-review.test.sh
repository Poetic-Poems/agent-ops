#!/usr/bin/env bash
#
# test/gather-project-review.test.sh — regression test for
# scripts/gather-project-review.sh (requirement 3y; TD-PPagop-26081307): the
# source that hands the Refiner the most recent repository review's
# recommendations pre-fetched.
#
# Behaviours asserted, each of which fails silently if broken:
#
#   - **Only the most recent `reviews/project-review-YYYY-MM-DD/` folder is
#     read**, by date, never by listing order.
#   - **Each candidate's `ref` is `review-<date>-R-NN`**, `id` is the bare
#     `R-NN`, `title` is read from the section heading, `body` is the whole
#     `## R-NN — …` section verbatim, and `improvement_prompt` is the fenced
#     prompt body from `04-improvement-prompts.md`.
#   - **A prompt containing a fenced block of its own arrives whole** — the
#     body runs from the section's first fence line to its last, so the nested
#     block and the fences around it are content, not delimiters. Closing at
#     the first fence after the opening one would truncate such a prompt with
#     nothing to signal the loss, and the Refiner would write a specification
#     from the half it was left. This is the shape the project-review skill's
#     own mandatory cost-policy block produces.
#   - **Sorted by recommendation number ascending.**
#   - **A repository with no `reviews/` folder, or an unreadable one,
#     contributes `[]`**, silently for the former and loudly (stderr) for the
#     latter.
#   - **A missing `04-improvement-prompts.md` degrades that one field, not the
#     whole array** — recommendations are still emitted with an empty
#     `improvement_prompt`.
#
# The gatherer is run for real against a stubbed `gh`, the same shape
# test/gather-tech-debt.test.sh uses.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/gather-project-review.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATHER="$SCRIPT_DIR/scripts/gather-project-review.sh"

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

# --- Fixture content --------------------------------------------------------

cat >"$tmp_dir/03-recommendations.md" <<'EOF'
# Recommendations

Ordering note: severity first, quick wins before long campaigns.

| ID | Recommendation | Severity | Effort | Addresses |
|---|---|---|---|---|
| R-01 | Fix thing | High | Small | F-SEC-01 |
| R-02 | Fix other thing | Medium | Medium | F-DOC-03 |
| R-03 | Fix third thing | Low | Small | F-TST-02 |

## R-01 — Fix thing

**Severity:** High · **Effort:** Small · **Addresses:** F-SEC-01

**Current state:** bad.

**Intended end state:** good.

**Approach:** do it.

## R-02 — Fix other thing

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-DOC-03

**Current state:** meh.

**Intended end state:** better.

**Approach:** do that too.

## R-03 — Fix third thing

**Severity:** Low · **Effort:** Small · **Addresses:** F-TST-02

**Current state:** unpatched.

**Intended end state:** patched.

**Approach:** apply the patch the prompt carries.
EOF

cat >"$tmp_dir/04-improvement-prompts.md" <<'EOF'
# Improvement prompts

One prompt per recommendation, in priority order.

## Prompt for R-01 — Fix thing

**Bundles:** R-01 only · **Run after:** no prerequisites

```text
Fix the thing described in R-01.
Do it well.
```

## Prompt for R-02 — Fix other thing

**Bundles:** R-02 only · **Run after:** no prerequisites

```text
Fix the other thing.
```

## Prompt for R-03 — Fix third thing

**Bundles:** R-03 only · **Run after:** no prerequisites

```text
Apply this patch:

```diff
-old
+new
```

Then run the tests, and work cost-consciously.
```
EOF

# --- A stub `gh`, the same shape test/gather-tech-debt.test.sh uses --------
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
[[ "\${1:-}" == "api" ]] || { echo "stub gh: unexpected call: \$*" >&2; exit 1; }
path="\${2:-}"
case "\$path" in
  repos/o/r/contents/reviews\\?ref=*)
    case "\${STUB_LISTING:-two}" in
      two)
        echo '[{"name":"project-review-2026-07-01","type":"dir"},{"name":"project-review-2026-08-10","type":"dir"},{"name":"README.md","type":"file"}]'
        ;;
      none)
        echo '[{"name":"README.md","type":"file"}]'
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
  repos/o/r/contents/reviews/project-review-2026-08-10/03-recommendations.md\\?ref=*)
    b64="\$(base64 -w0 "$tmp_dir/03-recommendations.md")"
    printf '{"content":"%s"}' "\$b64"
    ;;
  repos/o/r/contents/reviews/project-review-2026-08-10/04-improvement-prompts.md\\?ref=*)
    if [[ "\${STUB_PROMPTS:-hit}" == "404" ]]; then
      echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
      echo "gh: Not Found (HTTP 404)" >&2
      exit 1
    fi
    b64="\$(base64 -w0 "$tmp_dir/04-improvement-prompts.md")"
    printf '{"content":"%s"}' "\$b64"
    ;;
  *)
    echo "stub gh: unexpected call: \$*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

run() {  # prints stdout; stderr lands in $tmp_dir/err
  "$GATHER" "o/r" main 2>"$tmp_dir/err"
}

# --- The latest folder is read, both recommendations parsed ----------------
export STUB_LISTING=two
export STUB_PROMPTS=hit
out="$(run)"; rc=$?
assert_eq "exits 0" "0" "$rc"
assert_eq "every recommendation is a candidate" "3" "$(jq 'length' <<<"$out")"
assert_eq "source is project-review" "project-review" "$(jq -r '.[0].source' <<<"$out")"
assert_eq "ref is review-<date>-R-NN" "review-2026-08-10-R-01" "$(jq -r '.[0].ref' <<<"$out")"
assert_eq "id is the bare R-NN" "R-01" "$(jq -r '.[0].id' <<<"$out")"
assert_eq "review_date is the folder's own date" "2026-08-10" "$(jq -r '.[0].review_date' <<<"$out")"
assert_eq "title is read from the section heading" "Fix thing" "$(jq -r '.[0].title' <<<"$out")"
assert_eq "url points at the recommendations file on the default branch" \
  "https://github.com/o/r/blob/main/reviews/project-review-2026-08-10/03-recommendations.md" \
  "$(jq -r '.[0].url' <<<"$out")"
assert_eq "body is the whole R-01 section verbatim" \
  "$(printf '%s' '## R-01 — Fix thing

**Severity:** High · **Effort:** Small · **Addresses:** F-SEC-01

**Current state:** bad.

**Intended end state:** good.

**Approach:** do it.')" \
  "$(jq -r '.[0].body' <<<"$out")"
assert_eq "improvement_prompt is the fenced prompt body, verbatim" \
  "$(printf 'Fix the thing described in R-01.\nDo it well.')" \
  "$(jq -r '.[0].improvement_prompt' <<<"$out")"
assert_eq "sorted by recommendation number ascending" "R-01 R-02 R-03" \
  "$(jq -r '[.[].id] | join(" ")' <<<"$out")"
# A prompt with a fenced block of its own: the nested block and its fences are
# content. Stopping at the first closing fence would silently truncate this to
# "Apply this patch:" — a prompt whose whole instruction is the patch it lost.
assert_eq "a prompt with a nested code block arrives whole, fences and all" \
  "$(printf '%s' 'Apply this patch:

```diff
-old
+new
```

Then run the tests, and work cost-consciously.')" \
  "$(jq -r '.[] | select(.id == "R-03") | .improvement_prompt' <<<"$out")"
assert_eq "the earlier review folder's recommendations never appear" "0" \
  "$(jq '[.[] | select(.review_date == "2026-07-01")] | length' <<<"$out")"

# --- A repository with no reviews/ folder is a normal, silent [] -----------
export STUB_LISTING=none
out="$(run)"; rc=$?
assert_eq "a repository with no review folder contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... and says nothing on stderr" "" "$(cat "$tmp_dir/err")"
export STUB_LISTING=two

export STUB_LISTING=404
out="$(run)"; rc=$?
assert_eq "a repository that is gone (404) contributes []" "[]" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... and silently" "" "$(cat "$tmp_dir/err")"
export STUB_LISTING=two

export STUB_LISTING=error
out="$(run)"; rc=$?
assert_eq "an API failure contributes [] too" "[]" "$out"
assert_eq "  ... and still exits 0" "0" "$rc"
assert_eq "  ... but leaves gh's diagnosis on stderr" "1" \
  "$( [[ -s "$tmp_dir/err" ]] && echo 1 || echo 0 )"
export STUB_LISTING=two

# --- A missing improvement-prompts file degrades only that field -----------
export STUB_PROMPTS=404
out="$(run)"; rc=$?
assert_eq "exits 0 even without an improvement-prompts file" "0" "$rc"
assert_eq "recommendations are still emitted" "3" "$(jq 'length' <<<"$out")"
assert_eq "improvement_prompt is empty rather than the array being dropped" "" \
  "$(jq -r '.[0].improvement_prompt' <<<"$out")"
export STUB_PROMPTS=hit

# --- --current-date (requirement 34n's review-superseded signal, ----------
# --- TD-PPagop-26082309) -----------------------------------------------------
#
# Only the reviews/ listing runs — 03-recommendations.md/
# 04-improvement-prompts.md are never fetched — and one JSON object is
# printed instead of the candidate array.
run_current_date() {  # prints stdout; stderr lands in $tmp_dir/err
  "$GATHER" --current-date "o/r" main 2>"$tmp_dir/err"
}

export STUB_LISTING=two
out="$(run_current_date)"; rc=$?
assert_eq "--current-date exits 0" "0" "$rc"
assert_eq "--current-date reports ok:true" "true" "$(jq -r '.ok' <<<"$out")"
assert_eq "--current-date reports the latest folder's own date" \
  "2026-08-10" "$(jq -r '.date' <<<"$out")"

export STUB_LISTING=none
out="$(run_current_date)"; rc=$?
assert_eq "--current-date: no review folder at all still exits 0" "0" "$rc"
assert_eq "  ... reports ok:true" "true" "$(jq -r '.ok' <<<"$out")"
assert_eq "  ... with an empty date, a definite fact rather than a failure" \
  "" "$(jq -r '.date' <<<"$out")"
assert_eq "  ... and says nothing on stderr" "" "$(cat "$tmp_dir/err")"

export STUB_LISTING=404
out="$(run_current_date)"; rc=$?
assert_eq "--current-date: a clean 404 on reviews/ is the same definite fact" \
  "true" "$(jq -r '.ok' <<<"$out")"
assert_eq "  ... with an empty date" "" "$(jq -r '.date' <<<"$out")"
assert_eq "  ... silently" "" "$(cat "$tmp_dir/err")"

export STUB_LISTING=error
out="$(run_current_date)"; rc=$?
assert_eq "--current-date: a genuine API failure reports ok:false" \
  "false" "$(jq -r '.ok' <<<"$out")"
assert_eq "  ... still exits 0" "0" "$rc"
assert_eq "  ... but leaves gh's diagnosis on stderr" "1" \
  "$( [[ -s "$tmp_dir/err" ]] && echo 1 || echo 0 )"

export STUB_LISTING=two
export STUB_PROMPTS=hit

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
