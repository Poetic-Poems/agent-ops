#!/usr/bin/env bash
#
# test/dependency-gate.test.sh — regression test for requirement 34j: the
# structured `Blocked-by:` convention, held and released by code, never by a
# model re-reading prose.
#
# Four things are asserted:
#
#   - `dependency_refs` parses the convention correctly: same-repo and
#     cross-repo references, several on one comma-separated line, references
#     spread across a body and comments, case-insensitivity on the keyword, a
#     tolerated leading list marker, a bare number with no `#` ignored (it is
#     not a reference), and no `Blocked-by:` line at all yielding `[]`.
#   - `dependency_clearances` only clears a blocked issue that is (a) present
#     in this cycle's reshaped `issues` map — proof `scripts/gather-issues.sh`
#     already found every reference resolved — and (b) still carries a
#     `Blocked-by:` line, so a candidate present for some unrelated reason is
#     never mistaken for a dependency clearing.
#   - The #196–#199-shaped false-block scenario, end to end against a stubbed
#     `gh`: an issue naming a still-open dependency is held by
#     `scripts/gather-issues.sh` alone, with no `attempt-failed` needed to do
#     it; an issue *already* blocked clears, by both halves, within the one
#     cycle its dependency resolves in — no model, no Enabler round.
#   - `dependency_refusal_reason` (agent-ops#566) refuses a needs_refinement
#     entry only when all three hold — source `"issues"`, the item present in
#     this cycle's reshaped `issues` map, and the entry's own text citing a
#     `Blocked-by:` reference — and passes every entry short of one of the
#     three, so a genuine under-specification or question/discussion decline
#     is never caught by it.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/dependency-gate.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- dependency_refs -------------------------------------------------------

assert_eq "a same-repo reference parses to a bare number" \
  '["195"]' "$(dependency_refs 'Blocked-by: #195')"

assert_eq "a cross-repo reference is kept whole" \
  '["owner/repo#42"]' "$(dependency_refs 'Blocked-by: owner/repo#42')"

assert_eq "several comma-separated references on one line all parse" \
  '["1","2","owner/repo#3"]' \
  "$(dependency_refs 'Blocked-by: #1, #2, owner/repo#3' | jq -Sc 'sort')"

assert_eq "references across a body and comments (caller-concatenated) all parse" \
  '["195","196"]' \
  "$(dependency_refs "$(printf 'Blocked-by: #195\n---\nBlocked-by: #196')" | jq -Sc 'sort')"

assert_eq "the keyword is case-insensitive" \
  '["7"]' "$(dependency_refs 'BLOCKED-BY: #7')"

assert_eq "a leading list marker is tolerated" \
  '["9"]' "$(dependency_refs '- Blocked-by: #9')"

assert_eq "a bare number with no # is not a reference" \
  '[]' "$(dependency_refs 'Blocked-by: 8')"

assert_eq "text with no Blocked-by line yields []" \
  '[]' "$(dependency_refs 'Just an ordinary issue body, mentioning #123 in passing.')"

assert_eq "an empty body yields []" '[]' "$(dependency_refs '')"

# --- dependency_clearances ---------------------------------------------------

blocked_196='[{"repo":"o/r","item":"196","ts":"2026-08-01T00:00:00Z"}]'

resolved_map='{"o/r":{"196":{"body":"Needs #195 first.\n\nBlocked-by: #195","comments":[]}}}'
cleared="$(dependency_clearances "$blocked_196" "$resolved_map")"
assert_eq "a blocked issue present with a Blocked-by line clears" \
  '1' "$(jq 'length' <<<"$cleared")"
assert_eq "the clearance names the right repo and item" \
  '{"repo":"o/r","item":"196"}' \
  "$(jq -c '.[0] | {repo, item}' <<<"$cleared")"
assert_eq "the reason names the reference" \
  "true" "$(jq -r '.[0].reason | test("#195")' <<<"$cleared")"

absent_map='{"o/r":{}}'
assert_eq "a blocked issue absent from the map clears nothing" \
  '0' "$(jq 'length' <<<"$(dependency_clearances "$blocked_196" "$absent_map")")"

no_dep_map='{"o/r":{"196":{"body":"An ordinary thread with no dependency line.","comments":[]}}}'
assert_eq "a blocked issue present but with no Blocked-by line clears nothing" \
  '0' "$(jq 'length' <<<"$(dependency_clearances "$blocked_196" "$no_dep_map")")"

blocked_other_shape='[{"repo":"o/r","item":"pr-9-review-123","ts":"2026-08-01T00:00:00Z"}]'
other_shape_map='{"o/r":{"pr-9-review-123":{"body":"Blocked-by: #195","comments":[]}}}'
assert_eq "a non-issue-shaped blocked item is never considered" \
  '0' "$(jq 'length' <<<"$(dependency_clearances "$blocked_other_shape" "$other_shape_map")")"

assert_eq "an empty blocked set clears nothing" \
  '0' "$(jq 'length' <<<"$(dependency_clearances '[]' "$resolved_map")")"

# --- dependency_refusal_reason (agent-ops#566) ------------------------------
#
# The agent-ops#566 incident shape: an issue whose own thread still reads
# `Blocked-by: #410` after #410 closed, present in this cycle's own
# issues_by_repo_json map (proof gather-issues.sh already resolved it), and a
# needs_refinement entry that quoted the stale line back as its reason.
stale_dep_map='{"o/r":{"411":{"body":"Needs #410 first.\n\nBlocked-by: #410","comments":[]}}}'

nr_566='{"repo":"o/r","item":"411","source":"issues","reason":"waiting on #410",
         "missing":"nothing — #410 is still open","evidence":"issue body: Blocked-by: #410"}'
refusal="$(dependency_refusal_reason "$nr_566" "$stale_dep_map")"
refusal_rc=$?
assert_eq "the #566-shaped entry is refused" "1" "$refusal_rc"
assert_contains "the refusal names the resolved reference" "#410" "$refusal"

# The source default (requirement 16a: an entry naming no source is "issues")
# still refuses when the source key is simply absent.
nr_566_no_source='{"repo":"o/r","item":"411","reason":"waiting on #410",
                    "missing":"nothing","evidence":"Blocked-by: #410"}'
dependency_refusal_reason "$nr_566_no_source" "$stale_dep_map" >/dev/null
assert_eq "a missing source field still defaults to issues and refuses" "1" "$?"

# A non-`issues` source is never refused on this bar, whatever its text says —
# the convention is documented for issue threads only.
nr_other_source='{"repo":"o/r","item":"411","source":"tech-debt","reason":"waiting on #410",
                   "missing":"nothing","evidence":"Blocked-by: #410"}'
dependency_refusal_reason "$nr_other_source" "$stale_dep_map" >/dev/null
assert_eq "a non-issues source is never refused" "0" "$?"

# An item this cycle's map does not carry decides nothing — "unknown is never
# gone", the same rule dependency_clearances observes above.
dependency_refusal_reason "$nr_566" "$absent_map" >/dev/null
assert_eq "an item absent from this cycle's issues map is not refused" "0" "$?"

# A genuine under-specification report on the very same, present item is
# untouched: the judgement half must survive this bar intact.
nr_genuine='{"repo":"o/r","item":"411","source":"issues","reason":"no acceptance criteria",
             "missing":"what counts as done","evidence":"issue body has no criteria at all"}'
dependency_refusal_reason "$nr_genuine" "$stale_dep_map" >/dev/null
assert_eq "a genuine under-specification report on the same item is not refused" "0" "$?"

# A superstring digit run is not a match — #4100 naming the resolved #410 is
# a different issue, not a stale reference to this one.
nr_superstring='{"repo":"o/r","item":"411","source":"issues","reason":"see #4100 for context",
                 "missing":"nothing","evidence":"no acceptance criteria at all"}'
dependency_refusal_reason "$nr_superstring" "$stale_dep_map" >/dev/null
assert_eq "a superstring digit run does not falsely match the resolved reference" "0" "$?"

# A cross-repo reference is matched on the slug verbatim, same as
# dependency_refs itself keeps it whole.
cross_repo_map='{"o/r":{"412":{"body":"Needs the other side.\n\nBlocked-by: owner/repo#42","comments":[]}}}'
nr_cross='{"repo":"o/r","item":"412","source":"issues","reason":"waiting on owner/repo#42",
           "missing":"nothing","evidence":"owner/repo#42 closed last week"}'
dependency_refusal_reason "$nr_cross" "$cross_repo_map" >/dev/null
assert_eq "a cross-repo reference named in the entry is refused" "1" "$?"

# Malformed input never refuses (fail-open, same terms as dependency_refs and
# dependency_clearances above).
dependency_refusal_reason "not json" "$stale_dep_map" >/dev/null
assert_eq "malformed entry JSON is not refused" "0" "$?"
dependency_refusal_reason "$nr_566" "not json" >/dev/null
assert_eq "malformed map JSON is not refused" "0" "$?"

# --- End to end: the #196-199-shaped scenario, against a stubbed gh -------
#
# One issue, #196, whose body names a dependency on #195 in the same repo.
# The stub answers two things gather-issues.sh now calls: the listing-plus-
# comments GraphQL walk (`issue_prefetch_open_issues`, lib/issue-prefetch.sh,
# agent-ops#1085), from the fixture below, and one issue's own state (the
# REST live-check `issue_blocked_by_ref` still makes — unaffected by that
# migration) — the latter reading a file this test flips between the two
# halves of the scenario, so the same stub script serves both "#195 open"
# and "#195 closed" without being rewritten.
mkdir -p "$tmp_dir/bin"
dep_state_file="$tmp_dir/dep-195-state"
echo "open" > "$dep_state_file"
dep_issues_file="$tmp_dir/dep-issues.json"
cat >"$dep_issues_file" <<'EOF'
{"data": {"repository": {"issues": {"pageInfo": {"hasNextPage": false, "endCursor": null}, "nodes": [
  {"number": 196, "url": "https://github.com/o/r/issues/196", "title": "Needs 195 first",
   "author": {"login": "warwick"},
   "labels": {"nodes": []}, "assignees": {"totalCount": 0},
   "issueFieldValues": {"nodes": []},
   "createdAt": "2026-08-01T00:00:00Z", "updatedAt": "2026-08-01T00:00:00Z",
   "body": "Needs #195 first.\n\nBlocked-by: #195", "comments": {"nodes": []}}
]}}}}
EOF
cat >"$tmp_dir/bin/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
if [[ "\${1:-}" == "api" && "\${2:-}" == "graphql" ]]; then
  shift 2
  filter='.'
  while [[ \$# -gt 0 ]]; do
    case "\$1" in --jq) filter="\$2"; shift 2;; *) shift;; esac
  done
  jq -c "\$filter" "$dep_issues_file"
  exit 0
fi
[[ "\${1:-}" == "api" ]] || { echo "stub gh: unexpected command: \$*" >&2; exit 1; }
path="\$2"; shift 2
filter='.'
while [[ \$# -gt 0 ]]; do
  case "\$1" in --jq) filter="\$2"; shift 2;; *) shift;; esac
done
case "\$path" in
  repos/o/r/issues/195)
    state="\$(cat "$dep_state_file")"
    body="{\\"state\\": \\"\$state\\"}"
    ;;
  *) echo "stub gh: unexpected path: \$path" >&2; exit 1;;
esac
jq -rc "\$filter" <<<"\$body"
STUB
chmod +x "$tmp_dir/bin/gh"
export PATH="$tmp_dir/bin:$PATH"

# Half one: the dependency is still open. #196 must never reach the
# candidates array — held by code, before any block is ever recorded — and
# must instead be reported in the sibling `excluded` array, naming why
# (agent-ops#447).
issues_before_json="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r)"
issues_before="$(jq -c '.candidates' <<<"$issues_before_json")"
assert_eq "an unresolved Blocked-by reference holds the candidate out" \
  '0' "$(jq 'length' <<<"$issues_before")"
excluded_before="$(jq -c '.excluded' <<<"$issues_before_json")"
assert_eq "and it is reported excluded, naming the unresolved reference" \
  '{"number":196,"reason":"blocked-by: #195"}' "$(jq -c '.[0]' <<<"$excluded_before")"

# Simulate the shape of an already-blocked #196 (as if a Co-Ordinator, before
# this convention existed, had attempt-failed it) and confirm the pre-extract
# release finds nothing to clear while the dependency still stands: #196 is
# absent from this cycle's issues map (it was just excluded above), so
# dependency_clearances has no thread to read.
issues_by_repo_before="$(jq -nc --argjson issues "$issues_before" \
  '{"o/r": ($issues | map({key: (.number | tostring), value: {body: (.body // ""), comments: (.comments // [])}}) | from_entries)}')"
assert_eq "and the pre-extract release clears nothing while it stands" \
  '0' "$(jq 'length' <<<"$(dependency_clearances "$blocked_196" "$issues_by_repo_before")")"

# Half two: #195 closes. Within the very next gather, #196 must reappear as
# a candidate, and the already-recorded block must clear in that same cycle.
echo "closed" > "$dep_state_file"
issues_after_json="$("$SCRIPT_DIR/scripts/gather-issues.sh" o/r)"
issues_after="$(jq -c '.candidates' <<<"$issues_after_json")"
assert_eq "a resolved Blocked-by reference lets the candidate through" \
  '1' "$(jq 'length' <<<"$issues_after")"
assert_eq "and it is still #196, thread intact" \
  '196' "$(jq -r '.[0].number' <<<"$issues_after")"
assert_eq "and it is no longer reported excluded" \
  '0' "$(jq '.excluded | length' <<<"$issues_after_json")"

issues_by_repo_after="$(jq -nc --argjson issues "$issues_after" \
  '{"o/r": ($issues | map({key: (.number | tostring), value: {body: (.body // ""), comments: (.comments // [])}}) | from_entries)}')"
released="$(dependency_clearances "$blocked_196" "$issues_by_repo_after")"
assert_eq "the pre-extract release clears the already-blocked item the same cycle #195 closed" \
  '1' "$(jq 'length' <<<"$released")"
assert_eq "naming the resolved reference" \
  "true" "$(jq -r '.[0].reason | test("#195")' <<<"$released")"

echo
if (( failures == 0 )); then
  echo "All dependency-gate assertions passed."
  exit 0
else
  echo "$failures dependency-gate assertion(s) FAILED."
  exit 1
fi
