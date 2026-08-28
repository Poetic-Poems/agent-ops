#!/usr/bin/env bash
#
# test/report-directory.test.sh — regression test for lib/report-directory.sh
# (issue #761): resolving a configurable `report_directory` — a GNU date(1)
# format string — into today's write path, and discovering which of its past
# instances already exist on a repository's default branch.
#
# Behaviours asserted:
#
#   - `report_directory_regex` turns a format string into an ERE matching any
#     string `date` could produce from it, escaping literal regex
#     metacharacters (including a literal backslash) and degrading an
#     unrecognised specifier to a wildcard rather than failing.
#   - `report_directory_find_dirs` discovers existing directories matching a
#     format's shape: the common case (the whole dynamic part is the format's
#     final segment, as the shipped default and every example in the issue
#     are shaped) costs exactly one directory listing; a format with a
#     dynamic segment in the middle and a static leaf after it still
#     resolves, at the cost of one further listing per level.
#   - `report_directory_most_recent` finds the latest existing instance and
#     its own date, and prints nothing when none exist within the lookback
#     window.
#
# `gh` is stubbed the same shape test/gather-project-review.test.sh uses.
# Fixture dates are computed relative to the real clock at run time (10/20/45
# days ago), never hardcoded to a calendar year, because
# report_directory_most_recent's own search runs backward from today — a
# fixture pinned to "2026" would go stale (silently start failing) the day
# that year is more than the default 400-day lookback in the past.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/report-directory.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$SCRIPT_DIR/lib/report-directory.sh"

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

# shellcheck source=lib/report-directory.sh
. "$LIB"

# --- report_directory_regex -------------------------------------------------

assert_eq "the shipped default format" \
  'project-review-[0-9]{4}-[0-9]{2}-[0-9]{2}' \
  "$(report_directory_regex 'project-review-%Y-%m-%d')"
assert_eq "a docs/ prefix is copied through literally" \
  'docs/reviews/project-review-[0-9]{4}-[0-9]{2}-[0-9]{2}' \
  "$(report_directory_regex 'docs/reviews/project-review-%Y-%m-%d')"
# shellcheck disable=SC2016  # both single-quoted arguments are literal test data — $ and the rest are not meant to expand
assert_eq "regex metacharacters in the literal text are escaped" \
  'a\.b\*c\+d\?e\(f\)g\[h\]i\{j\}k\^l\$m\|n\\o' \
  "$(report_directory_regex 'a.b*c+d?e(f)g[h]i{j}k^l$m|n\o')"
assert_eq "an unrecognised specifier degrades to a wildcard, not a failure" \
  'x.*y' \
  "$(report_directory_regex 'x%Zy')"
assert_eq "a literal percent (%%) is a literal percent" \
  '100%' \
  "$(report_directory_regex '100%%')"

# --- Fixture dates, relative to the real clock (see file header) -----------
old_date="$(date -u -d '-45 day' +%Y-%m-%d)"
mid_date="$(date -u -d '-20 day' +%Y-%m-%d)"
recent_date="$(date -u -d '-10 day' +%Y-%m-%d)"

# --- A stub `gh`, the same shape test/gather-project-review.test.sh uses ---
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
[[ "\${1:-}" == "api" ]] || { echo "stub gh: unexpected call: \$*" >&2; exit 1; }
path="\${2:-}"
case "\$path" in
  repos/o/r/contents/reviews\\?ref=*)
    echo '[{"name":"project-review-$old_date","type":"dir"},{"name":"project-review-$recent_date","type":"dir"},{"name":"$mid_date","type":"dir"},{"name":"README.md","type":"file"}]'
    ;;
  repos/o/r/contents/docs/reviews\\?ref=*)
    echo '[{"name":"project-review-$recent_date","type":"dir"}]'
    ;;
  repos/o/r/contents\\?ref=*)
    echo '[{"name":"reviews","type":"dir"},{"name":"README.md","type":"file"}]'
    ;;
  repos/o/r/contents/reviews/$mid_date\\?ref=*)
    echo '[{"name":"my-repo-review","type":"dir"}]'
    ;;
  repos/o/empty/contents/reviews\\?ref=*)
    echo '[{"name":"README.md","type":"file"}]'
    ;;
  *)
    echo "stub gh: unexpected call: \$*" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# --- report_directory_find_dirs ---------------------------------------------

assert_eq "the default format's whole dynamic part is its final segment — every match found" \
  "reviews/project-review-$old_date
reviews/project-review-$recent_date" \
  "$(report_directory_find_dirs o/r main 'reviews/project-review-%Y-%m-%d')"
assert_eq "a leading static segment (docs/) is folded into the listing path" \
  "docs/reviews/project-review-$recent_date" \
  "$(report_directory_find_dirs o/r main 'docs/reviews/project-review-%Y-%m-%d')"
assert_eq "a dynamic segment in the middle, with a static leaf after it, still resolves" \
  "reviews/$mid_date/my-repo-review" \
  "$(report_directory_find_dirs o/r main 'reviews/%Y-%m-%d/my-repo-review')"
assert_eq "no report directory ever written degrades to nothing, not a failure" \
  "" \
  "$(report_directory_find_dirs o/empty main 'reviews/project-review-%Y-%m-%d')"

# --- report_directory_most_recent -------------------------------------------

assert_eq "the most recent of several candidates, by date rather than listing order" \
  "$(printf '%s\treviews/project-review-%s' "$recent_date" "$recent_date")" \
  "$(report_directory_most_recent o/r main 'reviews/project-review-%Y-%m-%d')"
assert_eq "the resolved directory for a custom format" \
  "$(printf '%s\tdocs/reviews/project-review-%s' "$recent_date" "$recent_date")" \
  "$(report_directory_most_recent o/r main 'docs/reviews/project-review-%Y-%m-%d')"
assert_eq "a dynamic-middle format's own date and full path" \
  "$(printf '%s\treviews/%s/my-repo-review' "$mid_date" "$mid_date")" \
  "$(report_directory_most_recent o/r main 'reviews/%Y-%m-%d/my-repo-review')"
assert_eq "nothing to discover prints nothing" \
  "" \
  "$(report_directory_most_recent o/empty main 'reviews/project-review-%Y-%m-%d')"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
