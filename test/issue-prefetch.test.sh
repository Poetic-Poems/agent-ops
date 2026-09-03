#!/usr/bin/env bash
#
# test/issue-prefetch.test.sh — regression test for lib/issue-prefetch.sh's
# `issue_prefetch_open_issues` (agent-ops#1085): the paginated GraphQL walk
# shared by scripts/gather-issues.sh and scripts/gather-tech-debt.sh, replacing
# what was one REST listing call (capped at its own first page, silently) plus
# one further REST call per surviving candidate for its comments.
#
# Every assertion below is really one assertion in different clothes: the
# array this prints must be exactly the REST shape both callers' own jq
# filters already read (`html_url`, `user.login`, `labels[].name`,
# `issue_field_values[].issue_field_name`/`.single_select_option.name`,
# `comments[].user.login`, and no `pull_request` key ever), so neither
# caller's own filter needed to change to keep reading it, and a caller must
# never read a failed or malformed read as an empty-but-complete answer.
#
# `gh` is stubbed through ISSUE_PREFETCH_GH; the stub applies the caller's own
# `--jq` filter to a fixture GraphQL response per page, the same technique
# test/merge-queue.test.sh and test/candidate-gather-repo-order.test.sh use
# for their own `gh api graphql` stubs.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/issue-prefetch.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/issue-prefetch.sh
. "$SCRIPT_DIR/lib/issue-prefetch.sh"

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

# --- The stub gh -------------------------------------------------------------
# $tmp_dir/page-<n>.json  the raw GraphQL response for the n-th page (1-based;
#                          page 1 is the call with no cursor at all)
# $tmp_dir/pages          how many pages exist before the walk should stop
#                          (default 1)
# $tmp_dir/fail-page      if set, the call for that page number fails outright
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
[[ "$1 $2" == "api graphql" ]] || exit 1

cursor="" jqfilter="" prev=""
for a in "$@"; do
  [[ "$prev" == "-f" && "$a" == cursor=* ]] && cursor="${a#cursor=}"
  [[ "$prev" == "--jq" ]] && jqfilter="$a"
  prev="$a"
done

pages="$(cat "$d/pages" 2>/dev/null || printf 1)"
if [[ -z "$cursor" ]]; then
  page=1
else
  page="${cursor#page-}"
fi

failpage="$(cat "$d/fail-page" 2>/dev/null || true)"
[[ -n "$failpage" && "$page" == "$failpage" ]] && exit 1

(( page <= pages )) || exit 1
jq -c "$jqfilter" "$d/page-$page.json"
STUB
chmod +x "$tmp_dir/gh"

# page N HAS_NEXT ISSUES_JSON — ISSUES_JSON is a compact JSON array of
# `{number,title,url,createdAt,updatedAt,body,author,labels,assignees,
# issueFieldValues,comments}` node objects, already in GraphQL node shape;
# the cursor for the *next* page is always literally "page-<n+1>", which this
# stub's own page-number parsing above expects.
page() {
  local n="$1" has_next="$2" nodes="$3" next_cursor="null"
  [[ "$has_next" == "true" ]] && next_cursor="\"page-$(( n + 1 ))\""
  jq -nc --argjson nodes "$nodes" --argjson hn "$has_next" --argjson nc "$next_cursor" \
    '{data: {repository: {issues: {pageInfo: {hasNextPage: $hn, endCursor: $nc}, nodes: $nodes}}}}' \
    > "$tmp_dir/page-$n.json"
}

# node NUMBER [EXTRA] — the common fields every test below leaves at
# defaults; EXTRA (a JSON object, default {}) overrides/extends them.
node() {
  local extra="${2:-{\}}"
  jq -c --argjson n "$1" --argjson extra "$extra" \
    '{number: $n, title: "t\($n)", url: "https://github.com/o/r/issues/\($n)",
      createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-02T00:00:00Z",
      body: "body \($n)", author: {login: "alice"},
      labels: {nodes: []}, assignees: {totalCount: 0},
      issueFieldValues: {nodes: []}, comments: {nodes: []}} + $extra' <<<null
}

read_issues() { ISSUE_PREFETCH_GH="$tmp_dir/gh" issue_prefetch_open_issues "$@"; }

# --- A single page, ordinary shape --------------------------------------------
: > "$tmp_dir/fail-page"
printf 1 > "$tmp_dir/pages"
page 1 false "[$(node 10), $(node 11)]"
out="$(read_issues o/r)"; rc=$?
assert_eq "a single page: exit 0" "0" "$rc"
assert_eq "  ... both issues present" "2" "$(jq 'length' <<<"$out")"
assert_eq "  ... html_url mirrors the REST field name" \
  "https://github.com/o/r/issues/10" "$(jq -r '.[0].html_url' <<<"$out")"
assert_eq "  ... user.login mirrors the REST author shape" \
  "alice" "$(jq -r '.[0].user.login' <<<"$out")"
assert_eq "  ... no pull_request key is ever present" \
  "false" "$(jq '.[0] | has("pull_request")' <<<"$out")"

# --- Labels, assignees, priority and comments all carry through --------------
page 1 false "[$(node 20 '{"labels":{"nodes":[{"name":"bug"},{"name":"blocked"}]},
  "assignees":{"totalCount":1},
  "issueFieldValues":{"nodes":[
    {"__typename":"IssueFieldSingleSelectValue","name":"High",
     "field":{"__typename":"IssueFieldSingleSelect","name":"Priority"}}]},
  "comments":{"nodes":[{"author":{"login":"bob"},"createdAt":"2026-08-03T00:00:00Z","body":"hi"}]}}')]"
out="$(read_issues o/r)"
assert_eq "labels carry through as {name}" \
  "$(printf 'bug\nblocked')" "$(jq -r '.[0].labels[].name' <<<"$out")"
assert_eq "assignees carries only the count, as one placeholder per assignee" \
  "1" "$(jq '.[0].assignees | length' <<<"$out")"
assert_eq "issue_field_values mirrors the REST Priority shape" \
  "High" "$(jq -r '.[0].issue_field_values[0].single_select_option.name' <<<"$out")"
assert_eq "  ... and issue_field_name" \
  "Priority" "$(jq -r '.[0].issue_field_values[0].issue_field_name' <<<"$out")"
assert_eq "comments carry through in the REST author/created_at/body shape" \
  "bob" "$(jq -r '.[0].comments[0].user.login' <<<"$out")"

# A non-single-select field value (e.g. a text or date field) contributes
# nothing — the same "unset" reading `$priority_names` gives it over REST.
page 1 false "[$(node 21 '{"issueFieldValues":{"nodes":[{"__typename":"IssueFieldTextValue"}]}}')]"
out="$(read_issues o/r)"
assert_eq "a non-single-select field value is dropped, not guessed at" \
  "0" "$(jq '.[0].issue_field_values | length' <<<"$out")"

# --- Pagination: two pages, concatenated in order -----------------------------
printf 2 > "$tmp_dir/pages"
page 1 true "[$(node 1), $(node 2)]"
page 2 false "[$(node 3)]"
out="$(read_issues o/r)"; rc=$?
assert_eq "two pages: exit 0" "0" "$rc"
assert_eq "  ... every issue from both pages is present, in order" \
  "$(printf '1\n2\n3')" "$(jq -r '.[].number' <<<"$out")"
printf 1 > "$tmp_dir/pages"

# --- The page cap: exit 2, with whatever was gathered still printed ----------
printf 5 > "$tmp_dir/pages"
page 1 true "[$(node 1)]"
page 2 true "[$(node 2)]"
page 3 true "[$(node 3)]"
(
  out="$(ISSUE_PREFETCH_GH="$tmp_dir/gh" ISSUE_PREFETCH_MAX_PAGES=2 issue_prefetch_open_issues o/r)"; rc=$?
  [[ "$rc" == "2" ]] || { echo "expected rc 2, got $rc" >&2; exit 1; }
  [[ "$(jq -r '[.[].number] | join(",")' <<<"$out")" == "1,2" ]] || { echo "expected 1,2, got $out" >&2; exit 1; }
  exit 0
)
assert_eq "the page cap stops the walk and reports 2, keeping what was gathered" "0" "$?"
printf 1 > "$tmp_dir/pages"

# --- A failed call outright is unknown, never a guessed empty array ----------
page 1 false "[$(node 1)]"
printf 1 > "$tmp_dir/fail-page"
out="$(read_issues o/r)"; rc=$?
assert_eq "a failed first page: non-zero exit" "1" "$rc"
assert_eq "  ... and no output a caller could mistake for a real (empty) answer" "" "$out"
: > "$tmp_dir/fail-page"

# A failure on a *later* page is the same "could not ask" answer, never a
# silently truncated success on the pages that did work.
printf 2 > "$tmp_dir/pages"
page 1 true "[$(node 1)]"
page 2 false "[$(node 2)]"
printf 2 > "$tmp_dir/fail-page"
out="$(read_issues o/r)"; rc=$?
assert_eq "a failed second page: non-zero exit, not a partial success" "1" "$rc"
assert_eq "  ... and no output" "" "$out"
: > "$tmp_dir/fail-page"
printf 1 > "$tmp_dir/pages"

# --- Bad arguments never reach gh at all --------------------------------------
page 1 false "[$(node 1)]"
out="$(read_issues "")"; rc=$?
assert_eq "an empty slug is rejected before calling gh" "1" "$rc"
assert_eq "  ... no output" "" "$out"

out="$(read_issues "no-slash-here")"; rc=$?
assert_eq "a slug with no owner/repo separator is rejected before calling gh" "1" "$rc"
assert_eq "  ... no output" "" "$out"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
