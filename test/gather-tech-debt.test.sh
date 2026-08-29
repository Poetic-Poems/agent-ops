#!/usr/bin/env bash
#
# test/gather-tech-debt.test.sh — regression test for
# scripts/gather-tech-debt.sh (requirement 3t, issue #310; store moved to
# labelled issues by D15 as revised, #869/#875): the source that hands the
# Co-Ordinator every open `pw::type:tech-debt`-labelled issue pre-fetched,
# whole thread included.
#
# Behaviours asserted, each of which fails silently if broken:
#
#   - **Only issues carrying `pw::type:tech-debt` are candidates.** The
#     labels-scoped listing call is trusted to have done that filtering; this
#     test asserts the gatherer does not additionally require anything else.
#   - **The deterministic filter, shared with scripts/gather-issues.sh via
#     lib/issue-prefetch.sh, still applies**: an assigned issue, an issue
#     labelled `blocked`, and an issue naming a still-open `Blocked-by:`
#     reference (requirement 34j) are all dropped.
#   - **Each candidate carries the whole issue thread verbatim** — `body` and
#     every comment — plus `source`, `ref` (the bare issue number, as a
#     string), `number`, `url`, `title`, `labels`, `author`, `created_at` and
#     `updated_at`.
#   - **Sorted by issue number ascending** — "the oldest item is kept first"
#     (lib/coordinator-input.sh's own `keep_order_tech_debt`).
#   - **Degrades to `[]` (exit 0) on any failure**, silently for none of the
#     old register-specific cases (there is no register left to read) but
#     always loudly on stderr for a genuine API failure — matching
#     scripts/gather-issues.sh's own degrade contract, which this gatherer
#     now shares in spirit.
#
# The gatherer is run for real against a stubbed `gh`, the same stub shape
# test/issues-prefetch.test.sh uses for scripts/gather-issues.sh, so the
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

# --- A stub `gh`, the same shape test/issues-prefetch.test.sh uses for
#     scripts/gather-issues.sh: it answers the labelled-issues listing (fetched
#     raw) and per-issue comments (fetched with `--jq`). Comments must be
#     matched before the listing: both paths contain `/issues`. ---
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
  */issues/*/comments*)
    n="${path##*/issues/}"; n="${n%%/*}"
    if [[ -f "$STUB_COMMENTS_DIR/$n.json" ]]; then
      body="$(cat "$STUB_COMMENTS_DIR/$n.json")"
    else
      body='[]'
    fi
    ;;
  */issues*labels=pw*) body="$(cat "$STUB_ISSUES")";;
  */issues/*)
    # A Blocked-by live-check reading one referenced issue's state.
    n="${path##*/issues/}"
    if [[ -f "$STUB_REFS_DIR/$n.json" ]]; then
      body="$(cat "$STUB_REFS_DIR/$n.json")"
    else
      body='{"state":"open"}'
    fi
    ;;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1;;
esac
jq -rc "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# --- The fixture: one issue per way an entry can qualify or be dropped ---
#
# #20 is clean, labelled `pw::type:tech-debt` plus an extra label, with a
# two-comment thread; #21 is assigned; #22 is labelled `Blocked` (upper case,
# proving the drop case-insensitive); #23 names an unresolved `Blocked-by:
# #24` (still open); #19 is clean and commentless, the lowest number, to
# prove ascending sort.
export STUB_ISSUES="$tmp_dir/issues.json"
export STUB_COMMENTS_DIR="$tmp_dir/comments"
export STUB_REFS_DIR="$tmp_dir/refs"
mkdir -p "$STUB_COMMENTS_DIR" "$STUB_REFS_DIR"
cat >"$STUB_ISSUES" <<'EOF'
[
  {"number": 20, "html_url": "https://github.com/o/r/issues/20", "title": "Untangle the frobnicator",
   "user": {"login": "warwick"}, "labels": [{"name": "pw::type:tech-debt"}, {"name": "backend"}],
   "assignees": [], "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "The body of twenty."},
  {"number": 21, "html_url": "https://github.com/o/r/issues/21", "title": "Assigned debt",
   "user": {"login": "warwick"}, "labels": [{"name": "pw::type:tech-debt"}],
   "assignees": [{"login": "somebody"}], "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "Assigned, so not a candidate."},
  {"number": 22, "html_url": "https://github.com/o/r/issues/22", "title": "Blocked debt",
   "user": {"login": "warwick"}, "labels": [{"name": "pw::type:tech-debt"}, {"name": "Blocked"}],
   "assignees": [], "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "Labelled Blocked, so not a candidate."},
  {"number": 23, "html_url": "https://github.com/o/r/issues/23", "title": "Debt with an open dependency",
   "user": {"login": "warwick"}, "labels": [{"name": "pw::type:tech-debt"}],
   "assignees": [], "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "Blocked-by: #24"},
  {"number": 19, "html_url": "https://github.com/o/r/issues/19", "title": "The oldest debt",
   "user": {"login": "warwick"}, "labels": [{"name": "pw::type:tech-debt"}],
   "assignees": [], "created_at": "2026-07-18T08:00:00Z", "updated_at": "2026-07-18T08:00:00Z",
   "body": "No comments, no labels but the one that matters."}
]
EOF
cat >"$STUB_COMMENTS_DIR/20.json" <<'EOF'
[
  {"user": {"login": "warwick"}, "created_at": "2026-07-19T10:00:00Z", "body": "Acceptance: it untangles."},
  {"user": {"login": "reviewer"}, "created_at": "2026-07-20T09:00:00Z", "body": "Scope cut: skip the UI."}
]
EOF
cat >"$STUB_REFS_DIR/24.json" <<'EOF'
{"state": "open"}
EOF

out="$("$GATHER" o/r 2>"$tmp_dir/err")"; rc=$?

# --- The filter: what arrives, and what never does ---
assert_eq "exits 0" "0" "$rc"
assert_eq "exactly the two clean labelled issues arrive" \
  "2" "$(jq 'length' <<<"$out")"
assert_eq "the assigned issue is dropped" \
  "false" "$(jq 'any(.[]; .number == 21)' <<<"$out")"
assert_eq "the Blocked-labelled issue is dropped, case notwithstanding" \
  "false" "$(jq 'any(.[]; .number == 22)' <<<"$out")"
assert_eq "the issue with an unresolved Blocked-by reference is dropped" \
  "false" "$(jq 'any(.[]; .number == 23)' <<<"$out")"
assert_eq "nothing on stderr on the success path" "" "$(cat "$tmp_dir/err")"

# --- Sorted by issue number ascending ---
assert_eq "sorted by issue number ascending, oldest first" \
  "19 20" "$(jq -r '[.[].number] | join(" ")' <<<"$out")"

# --- The entry shape: everything the Co-Ordinator selects on ---
entry20="$(jq -c '.[] | select(.number == 20)' <<<"$out")"
assert_eq "the entry's source is tech-debt" "tech-debt" "$(jq -r '.source' <<<"$entry20")"
assert_eq "the ref is the bare issue number, as a string" "20" "$(jq -r '.ref' <<<"$entry20")"
assert_eq "labels arrive sorted" '["backend","pw::type:tech-debt"]' "$(jq -c '.labels' <<<"$entry20")"
assert_eq "the body arrives verbatim" "The body of twenty." "$(jq -r '.body' <<<"$entry20")"
assert_eq "the whole thread arrives" "2" "$(jq '.comments | length' <<<"$entry20")"
assert_eq "a comment keeps its author, timestamp and body" \
  '{"author":"reviewer","created_at":"2026-07-20T09:00:00Z","body":"Scope cut: skip the UI."}' \
  "$(jq -c '.comments[1]' <<<"$entry20")"
assert_eq "the url is the issue's own html_url" \
  "https://github.com/o/r/issues/20" "$(jq -r '.url' <<<"$entry20")"

entry19="$(jq -c '.[] | select(.number == 19)' <<<"$out")"
assert_eq "a commentless issue carries an empty comments array, not null" \
  "[]" "$(jq -c '.comments' <<<"$entry19")"

# --- Once the dependency closes, the issue is no longer dropped ---
cat >"$STUB_REFS_DIR/24.json" <<'EOF'
{"state": "closed"}
EOF
out_resolved="$("$GATHER" o/r 2>"$tmp_dir/err2")"
assert_eq "a resolved Blocked-by reference stops excluding the issue" \
  "true" "$(jq 'any(.[]; .number == 23)' <<<"$out_resolved")"

# --- Degrading: a failing API yields [], exit 0, and is loud on stderr ---
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "stub gh: HTTP 500" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh"

degraded="$("$GATHER" o/r 2>"$tmp_dir/degrade.err")"
degraded_rc=$?
assert_eq "a failing API degrades to []" "[]" "$degraded"
assert_eq "  ... and still exits 0" "0" "$degraded_rc"
if [[ -s "$tmp_dir/degrade.err" ]]; then
  printf 'ok   - %s\n' "and the failure is loud on stderr"
else
  printf 'FAIL - %s\n' "and the failure is loud on stderr (stderr was empty)"
  failures=$(( failures + 1 ))
fi

# --- The gatherer fails safe against the real API too ---
assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$(PATH="${PATH#"$tmp_dir/bin:"}" "$GATHER" "Poetic-Poems/does-not-exist" 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
