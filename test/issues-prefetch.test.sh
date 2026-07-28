#!/usr/bin/env bash
#
# test/issues-prefetch.test.sh — regression test for the pre-fetched issues
# source (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 3j).
#
# The issues source used to be the Co-Ordinator's own `gh` read, and a cycle
# was observed skipping the entire walk on a "no issue data provided in
# input" misreading (20260727T145500Z-poetic-1-1431114). The fix hands the
# candidates over pre-fetched, and three halves of that have to hold outside
# the model, each failing silently if broken:
#
#   - **The deterministic filter.** Assigned issues, `blocked`-labelled
#     issues (whatever the case) and the pull requests the issues endpoint
#     interleaves must be dropped by the gatherer — requirement 16.4's
#     deterministic half — while everything else arrives whole-thread, with
#     its `Priority` band read exactly as the source-state digest reads it.
#   - **Degrading.** An API failure must yield `[]` (exit 0) with the failure
#     on stderr: the array is *given to* the Co-Ordinator, so an empty array
#     is a faithful record of its input, and aborting the cycle would make
#     cost control a reliability risk.
#   - **The fingerprint.** An *edit* to an existing comment moves no field the
#     issues digest samples — not even `updated_at`, which GitHub moves for
#     new comments but not edits — while the Co-Ordinator reads the thread
#     from this array. Hashing the array verbatim is the only thing that
#     wakes the cycle for it; if the fingerprint holds still across a comment
#     edit, a re-scoped instruction waits for an unrelated commit. That is
#     this system's signature failure (see the Gotchas table).
#
# `scripts/gather-issues.sh` is run for real here against a stubbed `gh`, so
# the assertions are about the shipped filter rather than a copy of it.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/issues-prefetch.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/noop-skip.sh
. "$SCRIPT_DIR/lib/noop-skip.sh"

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

# --- A stub `gh`, so the real gatherer runs offline ---
#
# It answers the two endpoints gather-issues.sh calls — the issues listing
# (fetched raw) and per-issue comments (fetched with `--jq`) — and mimics
# `gh api --jq` printing string results raw via `jq -rc`. Comments must be
# matched before the listing: both paths contain `/issues`.
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
  */issues\?*) body="$(cat "$STUB_ISSUES")";;
  *) echo "stub gh: unexpected path: $path" >&2; exit 1;;
esac
jq -rc "$filter" <<<"$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# --- The fixture: one issue per way an entry can qualify or be dropped ---
#
# #5 is clean with an explicit High band, labels and a two-comment thread;
# #6 is assigned; #7 is labelled `Blocked` (upper case, so the drop is proven
# case-insensitive); #8 is a pull request; #9 is clean, untriaged (no
# `Priority` — the Medium default) and commentless.
export STUB_ISSUES="$tmp_dir/issues.json"
export STUB_COMMENTS_DIR="$tmp_dir/comments"
mkdir -p "$STUB_COMMENTS_DIR"
cat >"$STUB_ISSUES" <<'EOF'
[
  {"number": 5, "html_url": "https://github.com/o/r/issues/5", "title": "Add the frobnicator",
   "user": {"login": "warwick"}, "labels": [{"name": "enhancement"}, {"name": "backend"}],
   "assignees": [], "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "The body of five.",
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "High"}}]},
  {"number": 6, "html_url": "https://github.com/o/r/issues/6", "title": "Assigned work",
   "user": {"login": "warwick"}, "labels": [],
   "assignees": [{"login": "somebody"}], "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "Assigned, so not a candidate.",
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "Urgent"}}]},
  {"number": 7, "html_url": "https://github.com/o/r/issues/7", "title": "Blocked work",
   "user": {"login": "warwick"}, "labels": [{"name": "Blocked"}],
   "assignees": [], "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "Labelled Blocked, so not a candidate.",
   "issue_field_values": []},
  {"number": 8, "html_url": "https://github.com/o/r/pull/8", "title": "A pull request",
   "user": {"login": "warwick"}, "labels": [], "assignees": [],
   "pull_request": {"url": "https://api.github.com/repos/o/r/pulls/8"},
   "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "PRs must never reach the array.",
   "issue_field_values": [{"issue_field_name": "Priority", "single_select_option": {"name": "Urgent"}}]},
  {"number": 9, "html_url": "https://github.com/o/r/issues/9", "title": "Untriaged work",
   "user": {"login": "warwick"}, "labels": [], "assignees": [],
   "created_at": "2026-07-19T08:00:00Z", "updated_at": "2026-07-20T09:00:00Z",
   "body": "No Priority field set.",
   "issue_field_values": []}
]
EOF
cat >"$STUB_COMMENTS_DIR/5.json" <<'EOF'
[
  {"user": {"login": "warwick"}, "created_at": "2026-07-19T10:00:00Z", "body": "Acceptance: it frobnicates."},
  {"user": {"login": "reviewer"}, "created_at": "2026-07-20T09:00:00Z", "body": "Scope cut: skip the UI."}
]
EOF

issues_json="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r)"

# --- The filter: what arrives, and what never does ---
assert_eq "exactly the two clean issues arrive" \
  "2" "$(jq 'length' <<<"$issues_json")"
assert_eq "the assigned issue is dropped" \
  "false" "$(jq 'any(.[]; .number == 6)' <<<"$issues_json")"
assert_eq "the Blocked-labelled issue is dropped, case notwithstanding" \
  "false" "$(jq 'any(.[]; .number == 7)' <<<"$issues_json")"
assert_eq "the pull request is dropped" \
  "false" "$(jq 'any(.[]; .number == 8)' <<<"$issues_json")"

# --- The entry shape: everything the Co-Ordinator selects on ---
entry5="$(jq -c '.[] | select(.number == 5)' <<<"$issues_json")"
assert_eq "the entry's source is issues" "issues" "$(jq -r '.source' <<<"$entry5")"
assert_eq "the ref is the bare issue number, as a string" "5" "$(jq -r '.ref' <<<"$entry5")"
assert_eq "the Priority band arrives as priority" "High" "$(jq -r '.priority' <<<"$entry5")"
assert_eq "labels arrive sorted" '["backend","enhancement"]' "$(jq -c '.labels' <<<"$entry5")"
assert_eq "the body arrives verbatim" "The body of five." "$(jq -r '.body' <<<"$entry5")"
assert_eq "the whole thread arrives" "2" "$(jq '.comments | length' <<<"$entry5")"
assert_eq "a comment keeps its author, timestamp and body" \
  '{"author":"reviewer","created_at":"2026-07-20T09:00:00Z","body":"Scope cut: skip the UI."}' \
  "$(jq -c '.comments[1]' <<<"$entry5")"

entry9="$(jq -c '.[] | select(.number == 9)' <<<"$issues_json")"
assert_eq "an untriaged issue defaults to Medium, not lowest" \
  "Medium" "$(jq -r '.priority' <<<"$entry9")"
assert_eq "a commentless issue carries an empty comments array, not null" \
  "[]" "$(jq -c '.comments' <<<"$entry9")"

# --- The fingerprint moves when only a comment's text moves ---
#
# Two runtime inputs identical but for the body of one comment — the
# transition no digest field carries, because editing a comment in place does
# not move the issue's `updated_at`. If these fingerprint the same, a
# re-scoped instruction edited into a thread never wakes the Co-Ordinator.
fp_input() {
  jq -nc --argjson issues "$1" '
    {repos: [{slug: "o/r", default_branch: "main", sources: ["issues:medium"],
              findings: [], review_feedback: [], issues: $issues,
              state: {ok: true, head_sha: "aaa111", issues: [], workflows: [], open_prs: []}}],
     blocked: [], void: [], enabler_eligible: [],
     selection_config: {}, coordinator_prompt_sha: "deadbeef",
     enabler_config: {}, enabler_prompt_sha: "cafebabe"}'
}

fp_before="$(fp_input "$issues_json" | noop_fingerprint)"
assert_eq "the sample is fingerprintable" "64" "${#fp_before}"

issues_edited="$(jq -c '(.[] | select(.number == 5) | .comments[1].body) = "Scope restored: include the UI."' \
  <<<"$issues_json")"
fp_after="$(fp_input "$issues_edited" | noop_fingerprint)"
if [[ "$fp_before" != "$fp_after" ]]; then
  printf 'ok   - %s\n' "editing a comment's text busts the no-op fingerprint"
else
  printf 'FAIL - %s\n     both cycles fingerprinted: %s\n' \
    "editing a comment's text busts the no-op fingerprint" "$fp_before"
  failures=$(( failures + 1 ))
fi

fp_same="$(fp_input "$issues_json" | noop_fingerprint)"
assert_eq "an unchanged array fingerprints identically" "$fp_before" "$fp_same"

# --- Degrading: a failing API yields [], exit 0, and says so on stderr ---
cat >"$tmp_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "stub gh: HTTP 500" >&2
exit 1
STUB
chmod +x "$tmp_dir/bin/gh"

degraded="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r 2>"$tmp_dir/degrade.err")"
degraded_rc=$?
assert_eq "a failing API degrades to an empty array" "[]" "$degraded"
assert_eq "and still exits 0" "0" "$degraded_rc"
if [[ -s "$tmp_dir/degrade.err" ]]; then
  printf 'ok   - %s\n' "and the failure is loud on stderr"
else
  printf 'FAIL - %s\n' "and the failure is loud on stderr (stderr was empty)"
  failures=$(( failures + 1 ))
fi

echo
if (( failures == 0 )); then
  echo "All issues-prefetch assertions passed."
  exit 0
else
  echo "$failures issues-prefetch assertion(s) FAILED."
  exit 1
fi
