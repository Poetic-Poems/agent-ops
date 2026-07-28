#!/usr/bin/env bash
#
# test/void-guard.test.sh — regression test for lib/void-guard.sh
# (requirement 34d).
#
# The defect, verbatim from the log that produced it: a Co-Ordinator recorded
#
#   item-void  Poetic-Poems/poetic  TD26072114
#   "PR #92 work is finished: workflow timeout, fetch timeouts,
#    retry-on-rejection and tests all merged; TECH-DEBT.md Ledger marked
#    resolved; only awaiting human review"
#
# while the workflow file on the default branch still had no timeout, the Ledger
# row still read `open`, and PR #92 was still an open, conflicted draft. A void
# is terminal by requirement 34c — no agent may clear one — so the item became
# unreachable from both directions at once: void as a tech-debt candidate, and
# void as the abandoned draft that would have finished it, because a void keys
# on the item and so bypasses the per-head refs of requirements 3e and 3g. Every
# following cycle reported `none-selected` citing the void, the no-op
# fingerprint then matched, and three nodes stood down hourly on a repository
# with outstanding work. Nothing looked broken.
#
# What makes it a mechanism gap rather than a bad model day: every clause of
# that reason was checkable, and the Co-Ordinator is the one void author that
# structurally cannot check — it reads a digest of candidates, never the
# default branch. So the guard tested here is not "was the model careful"; it is
# "did anything corroborate this", and the corroboration is drawn from the same
# candidates the Co-Ordinator was looking at.
#
# `gh` is stubbed through VOID_GUARD_GH. No test framework is used (none exists
# elsewhere in this repo). Run it directly:
#
#   ./test/void-guard.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"

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

# --- The stub -----------------------------------------------------------------
# `gh api repos/<slug>/pulls/<n>/files --jq length` answers with the contents of
# $tmp_dir/files-<n>, or fails when that file does not exist (a PR the API will
# not talk about).
#
# `gh api repos/<slug>/contents/<path>?ref=<ref>` (no `--jq`, as
# `void_evidence_resolves` calls it) answers with the contents of
# $tmp_dir/contents-<ref>-<path, `/` replaced by `_`>, or fails when that file
# does not exist — a 404, exactly what a real ref/path GitHub does not have
# looks like.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
[[ "$1" == "api" ]] || exit 1
if [[ "$2" == */contents/* ]]; then
  rest="${2#*/contents/}"
  path="${rest%%\?*}"
  ref="${rest##*ref=}"
  key="${path//\//_}"
  f="$d/contents-$ref-$key"
  [[ -f "$f" ]] || exit 1
  cat "$f"
  exit 0
fi
n="${2##*/pulls/}"; n="${n%%/*}"
[[ -f "$d/files-$n" ]] || exit 1
cat "$d/files-$n"
STUB
chmod +x "$tmp_dir/gh"
export VOID_GUARD_GH="$tmp_dir/gh"

# The runtime input the Co-Ordinator was given, in the shape agent-cycle.sh
# builds (requirement 3): the abandoned draft that PR #92 actually was, plus a
# second repo carrying an unrelated candidate, so a void naming no repo cannot
# quietly match the wrong one.
REPOS='[
  {"slug": "Poetic-Poems/poetic", "default_branch": "main",
   "findings": [], "review_feedback": [], "merge_conflicts": [],
   "abandoned_drafts": [
     {"source": "abandoned-drafts", "ref": "pr-92-abandoned-b4ff79990332",
      "number": 92, "pr_number": 92, "item": "TD26072114",
      "title": "fix(sync-blogger): add request timeouts"}]},
  {"slug": "Poetic-Poems/poetic-fiddle", "default_branch": "main",
   "findings": [], "review_feedback": [], "merge_conflicts": [],
   "abandoned_drafts": [
     {"source": "abandoned-drafts", "ref": "pr-77-abandoned-aaaaaaaaaaaa",
      "number": 77, "pr_number": 77, "item": "TD26070101", "title": "unrelated"}]}
]'

# --- void_entry_evidence: what counts as evidence -----------------------------
# Requirement 34c has always demanded it; nothing ever asked for it, which is
# how the void above was recorded with a reason and nothing else. A model asked
# for a field will fill it, and the empty container is what it reaches for
# first, so the empty container must not pass.
assert_eq "a prose citation is evidence" \
  "main@aad1405 still has no timeout-minutes" \
  "$(void_entry_evidence '{"evidence": "main@aad1405 still has no timeout-minutes"}')"
assert_eq "a structured citation is evidence" \
  '{"ref":"main","path":"TECH-DEBT.md"}' \
  "$(void_entry_evidence '{"evidence": {"ref": "main", "path": "TECH-DEBT.md"}}')"
assert_eq "an absent field is not" "" "$(void_entry_evidence '{"reason": "already done"}')"
assert_eq "an explicit null is not" "" "$(void_entry_evidence '{"evidence": null}')"
assert_eq "an empty string is not" "" "$(void_entry_evidence '{"evidence": ""}')"
assert_eq "whitespace is not" "" "$(void_entry_evidence '{"evidence": "   "}')"
assert_eq "an empty object is not" "" "$(void_entry_evidence '{"evidence": {}}')"
assert_eq "an empty array is not" "" "$(void_entry_evidence '{"evidence": []}')"

# --- void_candidate_prs: which PRs can speak to this item ---------------------
printf '3' >"$tmp_dir/files-92"
printf '0' >"$tmp_dir/files-77"

entry_92='{"item": "TD26072114", "repo": "Poetic-Poems/poetic", "reason": "done", "evidence": "read main"}'
assert_eq "the item's own PR is found" \
  "Poetic-Poems/poetic#92" "$(void_candidate_prs "$entry_92" "$REPOS")"

# The gatherers recover an item by grepping the branch and body (`grep -oiE`),
# so the case that reaches a candidate is whatever the author typed, while the
# Co-Ordinator reports the id as the register spells it.
assert_eq "matching is case-insensitive on the item id" \
  "Poetic-Poems/poetic#92" \
  "$(void_candidate_prs '{"item": "td26072114", "repo": "Poetic-Poems/poetic", "evidence": "x"}' "$REPOS")"

assert_eq "an entry naming no repo is matched across all of them" \
  "Poetic-Poems/poetic#92" \
  "$(void_candidate_prs '{"item": "TD26072114", "evidence": "x"}' "$REPOS")"

assert_eq "a different repo's identically-named item is not borrowed" \
  "" \
  "$(void_candidate_prs '{"item": "TD26072114", "repo": "Poetic-Poems/poetic-fiddle", "evidence": "x"}' "$REPOS")"

assert_eq "an item with no PR-backed candidate finds nothing" \
  "" \
  "$(void_candidate_prs '{"item": "review-2026-07-21-R-04", "evidence": "x"}' "$REPOS")"

# An entry with no item must not match every PR that also has no item — that
# would refuse unrelated voids on a technicality.
assert_eq "an empty item matches nothing" \
  "" "$(void_candidate_prs '{"repo": "Poetic-Poems/poetic", "evidence": "x"}' "$REPOS")"

# --- void_entry_resolvable_evidence: what counts as a citation the Script can
# resolve itself, rather than a free-text claim it can only check for presence
# (TD26072601) ------------------------------------------------------------------
assert_eq "a well-formed present citation is resolvable" \
  '{"ref":"main","path":"TECH-DEBT.md","expect":"present","pattern":"TD26072601.*resolved"}' \
  "$(void_entry_resolvable_evidence '{"evidence": {"ref": "main", "path": "TECH-DEBT.md",
      "expect": "present", "pattern": "TD26072601.*resolved"}}')"
assert_eq "pattern is optional on a resolvable citation" \
  '{"ref":"main","path":".github/workflows/ci.yml","expect":"absent","pattern":""}' \
  "$(void_entry_resolvable_evidence '{"evidence": {"ref": "main",
      "path": ".github/workflows/ci.yml", "expect": "absent"}}')"
assert_eq "a prose citation is not resolvable" \
  "" "$(void_entry_resolvable_evidence '{"evidence": "main@aad1405 has no timeout-minutes"}')"
assert_eq "an object missing path is not resolvable" \
  "" "$(void_entry_resolvable_evidence '{"evidence": {"ref": "main", "expect": "present"}}')"
assert_eq "an object missing ref is not resolvable" \
  "" "$(void_entry_resolvable_evidence '{"evidence": {"path": "x", "expect": "present"}}')"
assert_eq "an object with an unrecognised expect is not resolvable" \
  "" "$(void_entry_resolvable_evidence '{"evidence": {"ref": "main", "path": "x", "expect": "gone"}}')"
assert_eq "no evidence at all is not resolvable" \
  "" "$(void_entry_resolvable_evidence '{"reason": "already done"}')"

# --- void_evidence_resolves: testing one citation against the repository ------
printf '{"content":"%s"}' "$(printf 'irrelevant' | base64)" >"$tmp_dir/contents-main-EXISTS.md"
printf '{"content":"%s"}' \
  "$(printf '| TD26072601 | title | resolved | 2026-07-28 | #116 |\n' | base64)" \
  >"$tmp_dir/contents-main-TECH-DEBT.md"

assert_eq "absent holds when the API has nothing at that ref/path" \
  "0" "$(void_evidence_resolves '{"ref":"main","path":"GONE.md","expect":"absent","pattern":""}' \
    "Poetic-Poems/poetic"; echo $?)"
out="$(void_evidence_resolves '{"ref":"main","path":"EXISTS.md","expect":"absent","pattern":""}' \
  "Poetic-Poems/poetic")"; rc=$?
assert_eq "absent is refused when the file exists" "1" "$rc"
assert_contains "  ... saying so" "exists" "$out"

out="$(void_evidence_resolves '{"ref":"main","path":"GONE.md","expect":"present","pattern":""}' \
  "Poetic-Poems/poetic")"; rc=$?
assert_eq "present is refused when the API has nothing there" "1" "$rc"
assert_contains "  ... saying so" "could not be read" "$out"

assert_eq "present holds with no pattern to check" \
  "0" "$(void_evidence_resolves '{"ref":"main","path":"EXISTS.md","expect":"present","pattern":""}' \
    "Poetic-Poems/poetic"; echo $?)"

assert_eq "present with a matching pattern holds" \
  "0" "$(void_evidence_resolves \
    '{"ref":"main","path":"TECH-DEBT.md","expect":"present","pattern":"TD26072601.*resolved"}' \
    "Poetic-Poems/poetic"; echo $?)"

out="$(void_evidence_resolves \
  '{"ref":"main","path":"TECH-DEBT.md","expect":"present","pattern":"TD26072601.*open"}' \
  "Poetic-Poems/poetic")"; rc=$?
assert_eq "present with a non-matching pattern is refused" "1" "$rc"
assert_contains "  ... saying so" "does not" "$out"

# --- void_guard_reason: the verdict -------------------------------------------

# The exact defect. Reason, no evidence: refused before any API call is made.
out="$(void_guard_reason '{"item": "TD26072114", "repo": "Poetic-Poems/poetic",
  "reason": "PR #92 work is finished: all merged; TECH-DEBT.md marked resolved"}' "$REPOS")"
rc=$?
assert_eq "an unevidenced void is refused" "1" "$rc"
assert_contains "  ... saying so" "no evidence recorded" "$out"

# The same defect with the evidence field filled in: still refused, because the
# PR the void is about still changes files against its base. This is the
# assertion that would have caught the shipped bug even had the model cited
# something — the claim is testable, so it gets tested.
out="$(void_guard_reason "$entry_92" "$REPOS")"; rc=$?
assert_eq "a void refuted by its own PR's diff is refused" "1" "$rc"
assert_contains "  ... naming the PR" "PR #92" "$out"
assert_contains "  ... and the count" "3 file(s)" "$out"

# The honest case: the PR really has nothing left in it, so the work really is
# on the base. Nothing here should make a correct void harder to record.
entry_77='{"item": "TD26070101", "repo": "Poetic-Poems/poetic-fiddle",
  "reason": "landed via #70", "evidence": "pulls/77/files is empty"}'
out="$(void_guard_reason "$entry_77" "$REPOS")"; rc=$?
assert_eq "an evidenced void with an empty PR diff is allowed" "0" "$rc"
assert_eq "  ... silently" "" "$out"

# Items with no PR at all — most tech-debt and every review recommendation —
# are governed by the evidence rule alone. The guard must not become a rule that
# only PR-backed voids can ever be recorded.
out="$(void_guard_reason '{"item": "review-2026-07-21-R-04", "repo": "Poetic-Poems/poetic",
  "reason": "the licence file exists", "evidence": "main:LICENCE present at 9d45df4"}' "$REPOS")"
rc=$?
assert_eq "an evidenced void with no PR to check is allowed" "0" "$rc"

# TD26072601: exactly the case above is what the resolvable shape exists to
# strengthen — an item with no PR candidate, corroborated by fetching the file
# instead of trusting the sentence.
out="$(void_guard_reason '{"item": "TD26072601", "repo": "Poetic-Poems/poetic",
  "reason": "the ledger row is resolved",
  "evidence": {"ref": "main", "path": "TECH-DEBT.md", "expect": "present",
               "pattern": "TD26072601.*resolved"}}' "$REPOS")"
rc=$?
assert_eq "a resolvable citation that holds is allowed" "0" "$rc"
assert_eq "  ... silently" "" "$out"

# The false-citation shape the gap actually was: an entry that both looks
# evidenced and names a repo, but whose claim does not survive the fetch.
out="$(void_guard_reason '{"item": "TD26072601", "repo": "Poetic-Poems/poetic",
  "reason": "the ledger row is resolved",
  "evidence": {"ref": "main", "path": "TECH-DEBT.md", "expect": "present",
               "pattern": "TD26072601.*open"}}' "$REPOS")"
rc=$?
assert_eq "a resolvable citation that does not hold is refused" "1" "$rc"
assert_contains "  ... as unresolved" "unresolved" "$out"

# A resolvable-shaped citation names a repo to resolve it against; without one
# there is nothing to fetch, so it is refused rather than silently skipped.
out="$(void_guard_reason '{"item": "TD26072601",
  "reason": "the ledger row is resolved",
  "evidence": {"ref": "main", "path": "TECH-DEBT.md", "expect": "present"}}' "$REPOS")"
rc=$?
assert_eq "a resolvable citation with no repo to resolve against is refused" "1" "$rc"
assert_contains "  ... saying so" "names no repo" "$out"

# Unreadable is not innocent. Refusing costs a blocked item the Enabler will
# look at; accepting costs an item nothing will ever look at again.
rm -f "$tmp_dir/files-92"
out="$(void_guard_reason "$entry_92" "$REPOS")"; rc=$?
assert_eq "a PR that cannot be read refuses the void" "1" "$rc"
assert_contains "  ... saying it is uncorroborated" "uncorroborated" "$out"

# --- Robustness at the call site ------------------------------------------------
printf '3' >"$tmp_dir/files-92"

# agent-cycle.sh calls this as `if refusal="$(void_guard_reason …)"; then` under
# `set -euo pipefail`. A malformed repos array, or none at all, must degrade to
# "evidence rule only" rather than aborting the cycle that is trying to record
# state.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/void-guard.sh"
  VOID_GUARD_GH="/nonexistent/gh"
  if r="$(void_guard_reason '{"item": "X", "evidence": "cited"}' 'not json')"; then
    [[ -z "$r" ]] || exit 9
  else
    exit 8
  fi
  if r="$(void_guard_reason '{"item": "X"}')"; then exit 7; fi
  [[ "$r" == *"no evidence"* ]] || exit 6
  exit 0
) >/dev/null 2>&1
assert_eq "the real call-site shape survives set -e and bad input" "0" "$?"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
