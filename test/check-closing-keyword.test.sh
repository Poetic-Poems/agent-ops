#!/usr/bin/env bash
#
# test/check-closing-keyword.test.sh — regression test for
# scripts/check-closing-keyword.sh (requirement 25a): the deterministic gate
# that stops "Implements #198" from repeating unnoticed.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/check-closing-keyword.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-closing-keyword.sh"

failures=0

assert_pass() {  # assert_pass DESC BODY [BRANCH]
  local desc="$1" body="$2" branch="${3:-}"
  if "$CHECK" "$body" "$branch" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected exit 0)\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_fail() {  # assert_fail DESC BODY [NEEDLE] [BRANCH]
  local desc="$1" body="$2" needle="${3:-}" branch="${4:-}" err
  err="$("$CHECK" "$body" "$branch" 2>&1 >/dev/null)"
  if "$CHECK" "$body" "$branch" >/dev/null 2>&1; then
    printf 'FAIL - %s (expected non-zero exit)\n' "$desc"
    failures=$(( failures + 1 ))
    return
  fi
  if [[ -n "$needle" && "$err" != *"$needle"* ]]; then
    printf 'FAIL - %s\n     expected stderr to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$err"
    failures=$(( failures + 1 ))
    return
  fi
  printf 'ok   - %s\n' "$desc"
}

# --- No marker: every non-issue source passes trivially --------------------------
assert_pass "no marker at all" "A tech-debt fix, nothing to close."
assert_pass "prose that merely mentions an issue number, no marker" \
  "See #198 for background."

# --- The regression itself --------------------------------------------------------
assert_fail "prose describing intent is not a closing keyword" \
  "Implements #198.

<!-- agent-ops:closes-issue item=198 -->" \
  "#198"

# --- A real closing keyword passes ------------------------------------------------
assert_pass "Closes #N" "Closes #198.
<!-- agent-ops:closes-issue item=198 -->"
assert_pass "Fixes #N" "This Fixes #7 nicely.
<!-- agent-ops:closes-issue item=7 -->"
assert_pass "Resolves: #N (colon form)" "Resolves: #42
<!-- agent-ops:closes-issue item=42 -->"
assert_pass "case-insensitive keyword" "closes #198
<!-- agent-ops:closes-issue item=198 -->"
assert_pass "past-tense forms (fixed/closed/resolved)" "Fixed #9, closed #9 twice over.
<!-- agent-ops:closes-issue item=9 -->"

assert_pass "markdown emphasis around the keyword still passes" \
  "**Closes #55**
<!-- agent-ops:closes-issue item=55 -->"

# --- The keyword must be a word of its own, as it is to GitHub ---------------------
assert_fail "a word merely ending in a keyword does not close anything" \
  "This leaves #198 unclosed #198 for now.
<!-- agent-ops:closes-issue item=198 -->" \
  "#198"
assert_fail "\"discloses\" is not \"closes\"" \
  "The report discloses #77 in full.
<!-- agent-ops:closes-issue item=77 -->" \
  "#77"

# --- The keyword must name the SAME number the marker names -----------------------
assert_fail "a closing keyword for the wrong number does not satisfy the marker" \
  "Closes #199.
<!-- agent-ops:closes-issue item=198 -->" \
  "#198"

# --- Multiple markers are each checked independently -------------------------------
assert_fail "one satisfied marker does not excuse a second, unsatisfied one" \
  "Closes #1.
<!-- agent-ops:closes-issue item=1 -->
<!-- agent-ops:closes-issue item=2 -->" \
  "#2"
assert_pass "two markers, both satisfied" \
  "Closes #1 and Fixes #2.
<!-- agent-ops:closes-issue item=1 -->
<!-- agent-ops:closes-issue item=2 -->"

# --- No PR body at all (defensive) --------------------------------------------------
assert_pass "an empty body has no marker to fail" ""

# --- The branch anchor: `agent/<N>` demands presence, not just consistency ---------
# The Script mints `agent/<N>` (a bare issue number) for every work order
# whose item is one — the `issues` and `tech-debt` sources alike, since D15 as
# revised (#869/#875/#879) — and for nothing else, so the branch — which no
# model writes — demands both the marker and the keyword be *present*. Without
# this, an Implementer that forgot the marker passed trivially: the same
# silent prompt-skip the check exists to prevent.
assert_pass "an agent/<N> branch with marker and keyword passes" \
  "Closes #240.
<!-- agent-ops:closes-issue item=240 -->" \
  "agent/240"
assert_fail "an agent/<N> branch with no marker fails, naming the marker" \
  "Closes #240." \
  "closes-issue item=240" \
  "agent/240"
assert_fail "an agent/<N> branch with a marker but no keyword fails, naming the number" \
  "Implements #240.
<!-- agent-ops:closes-issue item=240 -->" \
  "#240" \
  "agent/240"
assert_fail "an agent/<N> branch with an empty body fails both ways" \
  "" \
  "closes-issue item=240" \
  "agent/240"
assert_fail "a forgotten marker still demands the keyword too" \
  "Some prose, no keyword, no marker." \
  "#240" \
  "agent/240"
assert_fail "a satisfied branch anchor does not excuse an unsatisfied second marker" \
  "Closes #240.
<!-- agent-ops:closes-issue item=240 -->
<!-- agent-ops:closes-issue item=2 -->" \
  "#2" \
  "agent/240"
# A tech-debt item is an issue too now, so its `agent/<N>` branch is anchored
# on the same terms — a `td-record` block alone never substitutes for the
# closing keyword the branch demands.
assert_fail "a tech-debt PR's agent/<N> branch demands the keyword too" \
  '<!-- agent-ops:closes-issue item=240 -->

```td-record
issue: 240
```' \
  "#240" \
  "agent/240"
assert_pass "a tech-debt PR carrying Fixes and the marker passes" \
  "Fixes #240.
<!-- agent-ops:closes-issue item=240 -->" \
  "agent/240"

# --- Non-numeric branches demand nothing -------------------------------------------
assert_pass "a non-numeric agent branch (slug shaped) demands nothing" \
  "A fix, nothing to close." "agent/td26072001-cache"
assert_pass "a register-hygiene branch demands nothing" \
  "Register housekeeping." "agent/register-hygiene-abc123"
assert_pass "a td/ claim branch demands nothing" \
  "A tech-debt fix." "td/TD-PPagop-26080101"
assert_pass "a human's branch demands nothing" \
  "Anything at all." "feature/agent/240-lookalike"
assert_pass "no branch argument at all keeps the marker-only behaviour" \
  "No marker here."

# --- The tech-debt record-flip check (issue #1363) ---------------------------------
# Only exercised when a repo slug and PR number are both given — every
# assertion above omits them, and passing regardless is what proves this half
# adds no burden to a caller that predates it.
#
# `gh` is stubbed through GH, matching the technique
# test/tech-debt-close-guard.test.sh's stub uses for its own `gh api` calls.
# $fixtures/issue-<n>.json  — `gh issue view <n> --json body,labels` reply
# $fixtures/files.json      — `gh api …/pulls/<n>/files` reply (a JSON array
#                             of pages, the `--slurp` shape)
# A missing fixture makes the stub exit non-zero, standing in for a `gh` call
# that could not be made at all.
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
fixtures="${GH_STUB_FIXTURES:?}"
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  f="$fixtures/issue-$3.json"
  [[ -f "$f" ]] && cat "$f" || exit 1
  exit 0
fi
if [[ "$1" == "api" ]]; then
  for a in "$@"; do
    if [[ "$a" == repos/*/pulls/*/files ]]; then
      f="$fixtures/files.json"
      [[ -f "$f" ]] || exit 1
      cat "$f"
      exit 0
    fi
  done
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"

assert_pass_tdr() {  # assert_pass_tdr DESC BODY BRANCH REPO PR_NUMBER FIXTURES_SUBDIR
  local desc="$1" body="$2" branch="$3" repo="$4" pr="$5" fixtures="$tmp_dir/$6"
  if GH="$tmp_dir/gh" GH_STUB_FIXTURES="$fixtures" "$CHECK" "$body" "$branch" "$repo" "$pr" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected exit 0)\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_fail_tdr() {  # assert_fail_tdr DESC BODY BRANCH REPO PR_NUMBER FIXTURES_SUBDIR NEEDLE
  local desc="$1" body="$2" branch="$3" repo="$4" pr="$5" fixtures="$tmp_dir/$6" needle="$7" err
  err="$(GH="$tmp_dir/gh" GH_STUB_FIXTURES="$fixtures" "$CHECK" "$body" "$branch" "$repo" "$pr" 2>&1 >/dev/null)"
  if GH="$tmp_dir/gh" GH_STUB_FIXTURES="$fixtures" "$CHECK" "$body" "$branch" "$repo" "$pr" >/dev/null 2>&1; then
    printf 'FAIL - %s (expected non-zero exit)\n' "$desc"
    failures=$(( failures + 1 ))
    return
  fi
  if [[ -n "$needle" && "$err" != *"$needle"* ]]; then
    printf 'FAIL - %s\n     expected stderr to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$err"
    failures=$(( failures + 1 ))
    return
  fi
  printf 'ok   - %s\n' "$desc"
}

body_240="Fixes #240.
<!-- agent-ops:closes-issue item=240 -->"

# No "Filed as" line on the closed issue: passes exactly as today, no new
# burden on an ordinary issue-closing PR.
mkdir -p "$tmp_dir/no-filed-line"
cat > "$tmp_dir/no-filed-line/issue-240.json" <<'JSON'
{"body": "An ordinary issue with nothing special about its last line.",
 "labels": [{"name": "pw::type:tech-debt"}]}
JSON
assert_pass_tdr "no 'Filed as' line on the closed issue passes as today" \
  "$body_240" "agent/240" "acme/widgets" "9" "no-filed-line"

# A "Filed as" line, but the issue is not pw::type:tech-debt-labelled: the
# phrase means nothing without the label, so this is left alone too.
mkdir -p "$tmp_dir/not-tech-debt"
cat > "$tmp_dir/not-tech-debt/issue-240.json" <<'JSON'
{"body": "Some issue whose body happens to end oddly.\n\nFiled as `tech-debt/TD-1.md`, 2026-08-01.",
 "labels": [{"name": "bug"}]}
JSON
assert_pass_tdr "a 'Filed as'-shaped line on a non-tech-debt issue is ignored" \
  "$body_240" "agent/240" "acme/widgets" "9" "not-tech-debt"

# A "Filed as" line, and this PR's diff flips the named record to resolved.
mkdir -p "$tmp_dir/flipped"
cat > "$tmp_dir/flipped/issue-240.json" <<'JSON'
{"body": "The debt itself, described here.\n\nFiled as `tech-debt/TD-1.md`, 2026-08-01.",
 "labels": [{"name": "pw::type:tech-debt"}]}
JSON
cat > "$tmp_dir/flipped/files.json" <<'JSON'
[[{"filename": "tech-debt/TD-1.md",
  "patch": "@@ -1,5 +1,7 @@\n ---\n id: TD-1\n-status: open\n+status: resolved\n+resolved: 2026-09-01\n+ref: https://github.com/acme/widgets/pull/9\n filed: 2026-08-01\n ---"}]]
JSON
assert_pass_tdr "'Filed as' present, diff flips status to resolved: pass" \
  "$body_240" "agent/240" "acme/widgets" "9" "flipped"

# A "Filed as" line, but this PR's diff never touches the file at all.
mkdir -p "$tmp_dir/untouched"
cp "$tmp_dir/flipped/issue-240.json" "$tmp_dir/untouched/issue-240.json"
cat > "$tmp_dir/untouched/files.json" <<'JSON'
[[{"filename": "README.md", "patch": "@@ -1 +1 @@\n-old\n+new"}]]
JSON
# The needle is each branch's own distinguishing phrase, never the record
# path both messages carry: the two failures are a file this PR never touched
# and a file it touched without flipping, and a needle common to both would
# let either assertion pass on the other's message — which is exactly how the
# case below first went green against a malformed fixture.
assert_fail_tdr "'Filed as' present, diff never touches the record: fail" \
  "$body_240" "agent/240" "acme/widgets" "9" "untouched" \
  "does not touch that file"

# A "Filed as" line, and this PR's diff touches the file but never sets
# status: resolved (left open, or flipped to something else).
mkdir -p "$tmp_dir/unflipped"
cp "$tmp_dir/flipped/issue-240.json" "$tmp_dir/unflipped/issue-240.json"
cat > "$tmp_dir/unflipped/files.json" <<'JSON'
[[{"filename": "tech-debt/TD-1.md",
  "patch": "@@ -1,5 +1,5 @@\n ---\n id: TD-1\n-title: \"old title\"\n+title: \"clearer title\"\n status: open\n ---"}]]
JSON
assert_fail_tdr "'Filed as' present, diff leaves status unchanged: fail" \
  "$body_240" "agent/240" "acme/widgets" "9" "unflipped" \
  "does not set its frontmatter status: to resolved"

# A `gh` call that fails outright never fails the check itself — only a
# positive reading of the issue and the diff decides pass or fail here. Both
# calls this half makes are covered: the issue lookup (no fixtures directory
# at all) and the changed-files listing (an issue to read, but no files.json).
assert_pass_tdr "a failed issue lookup does not fail the check" \
  "$body_240" "agent/240" "acme/widgets" "9" "no-such-fixtures-dir"

mkdir -p "$tmp_dir/files-unreadable"
cp "$tmp_dir/flipped/issue-240.json" "$tmp_dir/files-unreadable/issue-240.json"
assert_pass_tdr "a failed changed-files lookup does not fail the check" \
  "$body_240" "agent/240" "acme/widgets" "9" "files-unreadable"

# --- Keyword-only closes reach the record-flip check too (issue #1438) ------
# A markerless `Fixes #N` on a branch that is not `agent/N` — a human's PR, or
# an interactive agent's — never puts #N into `items` via the marker/branch
# resolution above, so the record-flip loop must re-derive it from the bare
# closing keyword itself.
body_240_bare="Fixes #240 for real this time."

mkdir -p "$tmp_dir/bare-unflipped"
cp "$tmp_dir/flipped/issue-240.json" "$tmp_dir/bare-unflipped/issue-240.json"
cat > "$tmp_dir/bare-unflipped/files.json" <<'JSON'
[[{"filename": "tech-debt/TD-1.md",
  "patch": "@@ -1,5 +1,5 @@\n ---\n id: TD-1\n-title: \"old title\"\n+title: \"clearer title\"\n status: open\n ---"}]]
JSON
assert_fail_tdr "a markerless Fixes #N with an unflipped record still fails" \
  "$body_240_bare" "fix/some-branch" "acme/widgets" "9" "bare-unflipped" \
  "does not set its frontmatter status: to resolved"

mkdir -p "$tmp_dir/bare-flipped"
cp "$tmp_dir/flipped/issue-240.json" "$tmp_dir/bare-flipped/issue-240.json"
cp "$tmp_dir/flipped/files.json" "$tmp_dir/bare-flipped/files.json"
assert_pass_tdr "a markerless Fixes #N with a correctly flipped record passes" \
  "$body_240_bare" "fix/some-branch" "acme/widgets" "9" "bare-flipped"

# The same word-of-its-own guard the marker/keyword half carries: "discloses"
# and "unfixed" contain a keyword and close nothing, to GitHub's own parser as
# to this script, so neither may drag #240 into the record-flip loop. The
# fixtures deliberately hold an *unflipped* record — the only way this passes
# is by never checking #240 at all.
assert_pass_tdr "a keyword lookalike (discloses/unfixed) demands no record flip" \
  "This discloses #240, and an unfixed #240 note." \
  "fix/some-branch" "acme/widgets" "9" "bare-unflipped"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
