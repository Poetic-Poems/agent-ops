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
# $tmp_dir/contents-<ref>-<path, `/` replaced by `_`>. When that file does not
# exist it fails the way the real thing fails: exit 1, with GitHub's own error
# body still on stdout — `{"message": "Not Found", "status": "404"}`, verbatim
# from `gh api repos/…/contents/NO-SUCH-FILE.md?ref=main`. A `<file>.err`
# alongside overrides that body, so a test can ask for the failures that are
# *not* absence (a rate limit, an unresolvable ref) and check they are refused.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
printf '%s\n' "$*" >> "$d/calls.log"
# `gh pr list -R <slug> --state open --author <login> --limit <n> --json
# number,headRefName` — the superseded-shape corroboration's re-derivation of the repository's
# *currently* open Dependabot pull requests (void_finishing_pr_reason). A
# fixture `prlist-<slug, / replaced by _>.json` holds the array; none means no
# open Dependabot PRs right now, an ordinary answer, not a failure.
if [[ "$1" == "pr" && "$2" == "list" ]]; then
  slug=""
  shift 2
  while (( $# )); do
    if [[ "$1" == "-R" ]]; then slug="$2"; break; fi
    shift
  done
  f="$d/prlist-${slug//\//_}.json"
  if [[ -f "$f" ]]; then cat "$f"; else printf '[]'; fi
  exit 0
fi
# `gh api graphql ...` — `lib/merge-queue.sh`'s `merge_queue_probe`, called by
# the `dequeued` shape's own live re-check (void_finishing_pr_reason). A
# fixture `$d/mq-response.json`, rewritten between assertions, holds the raw
# GraphQL response the real query would return; the caller's own `--jq`
# filter is applied to it, same technique test/merge-queue.test.sh's stub
# uses. No fixture at all means the probe fails, exactly like a real
# unreachable/erroring `gh`.
if [[ "$1 $2" == "api graphql" ]]; then
  [[ -f "$d/mq-response.json" ]] || exit 1
  jqfilter="" prev=""
  for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -c "$jqfilter" "$d/mq-response.json" 2>/dev/null
  exit 0
fi
[[ "$1" == "api" ]] || exit 1
if [[ "$2" == */contents/* ]]; then
  rest="${2#*/contents/}"
  path="${rest%%\?*}"
  ref="${rest##*ref=}"
  key="${path//\//_}"
  f="$d/contents-$ref-$key"
  if [[ -f "$f.err" ]]; then
    cat "$f.err"
    echo "gh: the stub was asked for a failure (HTTP 4xx)" >&2
    exit 1
  fi
  if [[ ! -f "$f" ]]; then
    printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/repos/contents#get-repository-content","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
  cat "$f"
  exit 0
fi
if [[ "$2" == */pulls/*/files ]]; then
  n="${2%/files}"; n="${n##*/pulls/}"
  [[ -f "$d/files-$n" ]] || exit 1
  cat "$d/files-$n"
  exit 0
fi
# A bare `repos/<slug>/pulls/<n>` — the citation guard's own fetch of a cited
# PR's body and branch, distinct from the `/files` count above. A
# slug-specific fixture (`pr-<slug>-<n>.json`) is tried first — matched
# case-insensitively, since GitHub resolves owner/repo the same way and a
# caller (e.g. the id shortcut's own case-insensitive slug comparison) may
# hand this stub a differently-cased slug than the fixture was written with —
# so a test can put the same PR number in two repos and prove each resolves
# independently; a plain `pr-<n>.json` (no repo distinction) is the fallback
# every existing fixture already uses.
if [[ "$2" == */pulls/* ]]; then
  slug="${2#repos/}"; slug="${slug%%/pulls/*}"
  n="${2##*/pulls/}"
  f="$d/pr-${slug//\//_}-$n.json"
  if [[ ! -f "$f" ]]; then
    match="$(find "$d" -maxdepth 1 -iname "pr-${slug//\//_}-$n.json" -print -quit 2>/dev/null)"
    [[ -n "$match" ]] && f="$match"
  fi
  [[ -f "$f" ]] || f="$d/pr-$n.json"
  [[ -f "$f" ]] || exit 1
  cat "$f"
  exit 0
fi
# `repos/<slug>/compare/<sha>...<default_branch>` — ancestry for a cited
# commit. Same slug-specific-then-plain fallback as the PR fetch above.
if [[ "$2" == */compare/* ]]; then
  slug="${2#repos/}"; slug="${slug%%/compare/*}"
  rest="${2##*/compare/}"
  key="${rest//.../_TO_}"
  f="$d/compare-${slug//\//_}-$key.json"
  [[ -f "$f" ]] || f="$d/compare-$key.json"
  [[ -f "$f" ]] || exit 1
  cat "$f"
  exit 0
fi
# `repos/<slug>/commits/<sha>/pulls` — PRs GitHub associates with a commit. A
# missing fixture is an empty list (a real, ordinary answer), not a failure.
# Same slug-specific-then-plain fallback.
if [[ "$2" == */commits/*/pulls ]]; then
  slug="${2#repos/}"; slug="${slug%%/commits/*}"
  sha="${2%/pulls}"; sha="${sha##*/commits/}"
  f="$d/commit-${slug//\//_}-$sha-pulls"
  [[ -f "$f" ]] || f="$d/commit-$sha-pulls"
  [[ -f "$f" ]] && cat "$f"
  exit 0
fi
if [[ "$2" == */commits/* ]]; then
  slug="${2#repos/}"; slug="${slug%%/commits/*}"
  sha="${2##*/commits/}"
  f="$d/commit-${slug//\//_}-$sha.json"
  [[ -f "$f" ]] || f="$d/commit-$sha.json"
  [[ -f "$f" ]] || exit 1
  cat "$f"
  exit 0
fi
# A bare `repos/<slug>` — the citation guard's own default-branch lookup for a
# cited commit. `--jq '.default_branch'` is what the caller asks for, so the
# fixture holds the already-projected raw value, exactly like `files-<n>` above.
slug="${2#repos/}"
f="$d/repo-${slug//\//_}"
[[ -f "$f" ]] || exit 1
cat "$f"
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
# `entry_92`/`entry_77`'s own evidence cites their PR by number — a citation
# the closed-list gate (issue #413, WI-10) demands before `void_guard_reason`
# ever reaches the candidate-diff check below, which is what these two entries
# actually exist to exercise. `pr-92.json`/`pr-77.json` let that citation
# corroborate (each PR's own branch names its item), so the candidate-diff
# check is what decides the verdict, exactly as before the gate existed.
printf '{"body": "", "head": {"ref": "td/TD26072114"}}' >"$tmp_dir/pr-92.json"
printf '{"body": "", "head": {"ref": "td/TD26070101"}}' >"$tmp_dir/pr-77.json"

entry_92='{"item": "TD26072114", "repo": "Poetic-Poems/poetic", "reason": "done",
  "evidence": "PR #92 finishes this item"}'
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

# An `absent` claim rests entirely on the API saying "not found", so every
# other way a fetch can fail must refuse it. Accepting them would make a rate
# limit — or a moment without a network — silently corroborate any absence a
# model cared to assert, which is precisely the unchecked-claim hole this test
# file exists to close.
printf '{"message":"API rate limit exceeded for user ID 1.","status":"403"}' \
  >"$tmp_dir/contents-main-RATELIMITED.md.err"
out="$(void_evidence_resolves '{"ref":"main","path":"RATELIMITED.md","expect":"absent","pattern":""}' \
  "Poetic-Poems/poetic")"; rc=$?
assert_eq "absent is refused when the API would not answer" "1" "$rc"
assert_contains "  ... naming what came back instead" "rate limit exceeded" "$out"

# A ref GitHub cannot resolve is a 404 as well, but it establishes nothing
# about absence: there was no tree to be absent from.
printf '{"message":"No commit found for the ref nope","status":"404"}' \
  >"$tmp_dir/contents-nope-GONE.md.err"
out="$(void_evidence_resolves '{"ref":"nope","path":"GONE.md","expect":"absent","pattern":""}' \
  "Poetic-Poems/poetic")"; rc=$?
assert_eq "absent is refused when the ref itself does not resolve" "1" "$rc"
assert_contains "  ... saying so" "No commit found for the ref" "$out"

# The same failures on a `present` claim were already refused, and still are.
out="$(void_evidence_resolves '{"ref":"main","path":"RATELIMITED.md","expect":"present","pattern":""}' \
  "Poetic-Poems/poetic")"; rc=$?
assert_eq "present is refused when the API would not answer" "1" "$rc"

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
  "reason": "landed via #70", "evidence": "PR #77'"'"'s own diff against its base is empty"}'
out="$(void_guard_reason "$entry_77" "$REPOS")"; rc=$?
assert_eq "an evidenced void with an empty PR diff is allowed" "0" "$rc"
assert_eq "  ... silently" "" "$out"

# Items with no PR at all — most tech-debt and every review recommendation —
# are governed by the evidence rule alone, but that rule is now a closed list
# (issue #413, WI-10): prose naming neither a structured citation nor a
# PR/commit is refused rather than accepted on being merely non-empty — the
# exact fall-through TD26072601 once carved out and the shipped defect at the
# top of this file walked straight through.
out="$(void_guard_reason '{"item": "review-2026-07-21-R-04", "repo": "Poetic-Poems/poetic",
  "reason": "the licence file exists", "evidence": "main:LICENCE present at 9d45df4"}' "$REPOS")"
rc=$?
assert_eq "an evidenced void with prose evidence and no PR is refused" "1" "$rc"
assert_contains "  ... naming what was missing" "no checkable citation" "$out"

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

# And an `absent` claim the API would not answer for reaches the same verdict
# as the unreadable PR below: refused, not waved through on the fetch having
# failed.
out="$(void_guard_reason '{"item": "TD26072601", "repo": "Poetic-Poems/poetic",
  "reason": "the workaround is gone from main",
  "evidence": {"ref": "main", "path": "RATELIMITED.md", "expect": "absent"}}' "$REPOS")"
rc=$?
assert_eq "an absent citation the API would not answer for is refused" "1" "$rc"
assert_contains "  ... as unresolved" "unresolved" "$out"

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
# state. Reached with the working stub, and checkable evidence (issue #413,
# WI-10 closed the fall-through, so bare unchecked prose no longer reaches the
# candidate-diff loop this is actually testing) — `EXISTS.md` is the fixture
# `void_evidence_resolves` already set up above.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/void-guard.sh"
  VOID_GUARD_GH="$tmp_dir/gh"
  if r="$(void_guard_reason '{"item": "X", "repo": "Poetic-Poems/poetic",
      "evidence": {"ref": "main", "path": "EXISTS.md", "expect": "present"}}' 'not json')"; then
    [[ -z "$r" ]] || exit 9
  else
    exit 8
  fi

  VOID_GUARD_GH="/nonexistent/gh"
  if r="$(void_guard_reason '{"item": "X"}')"; then exit 7; fi
  [[ "$r" == *"no evidence"* ]] || exit 6
  # A resolvable citation reads `$?` straight after a command substitution, so
  # it is the shape `set -e` is most likely to take exception to — and a `gh`
  # that will not run at all is how the fetch fails when a node is misconfigured
  # rather than merely offline. Refused, and the cycle still standing.
  if r="$(void_guard_reason '{"item": "X", "repo": "Poetic-Poems/poetic",
      "evidence": {"ref": "main", "path": "TECH-DEBT.md", "expect": "absent"}}')"; then
    exit 5
  fi
  [[ "$r" == *"unresolved"* ]] || exit 4
  exit 0
) >/dev/null 2>&1
assert_eq "the real call-site shape survives set -e and bad input" "0" "$?"

# --- Citation corroboration (issue #243) ---------------------------------------
# void_guard_reason is now shared by every stage that writes `item-void`, not
# only the Co-Ordinator — the Enabler and the Implementor call it with no
# gathered candidate list (`repos` = `[]`), so every assertion below passes
# `'[]'` rather than $REPOS, exactly as those two call sites do.

# --- void_evidence_cited_pr_numbers / void_evidence_cited_commit_shas ---------
# Both extractors now take a DEFAULT_SLUG and return `slug#number`/`slug#sha`
# pairs — the bare forms resolve against DEFAULT_SLUG (possibly empty), a URL
# citation always carries its own owner/repo regardless of DEFAULT_SLUG.
assert_eq "a PR citation is extracted" \
  "Poetic-Poems/poetic#232" \
  "$(void_evidence_cited_pr_numbers "PR #232 implemented all five rewrites" "Poetic-Poems/poetic")"
assert_eq "a 'pull request' citation is extracted" \
  "Poetic-Poems/poetic#235" \
  "$(void_evidence_cited_pr_numbers "pull request #235 landed it" "Poetic-Poems/poetic")"
assert_eq "a bare issue reference is not a PR citation" \
  "" "$(void_evidence_cited_pr_numbers "confirmed via #123 that nothing remains" "Poetic-Poems/poetic")"
assert_eq "multiple PR citations are deduped and sorted" \
  "$(printf 'Poetic-Poems/poetic#232\nPoetic-Poems/poetic#92\n')" \
  "$(void_evidence_cited_pr_numbers "see PR #232 and pr#92, also PR #92" "Poetic-Poems/poetic")"
assert_eq "no citation at all extracts nothing" \
  "" "$(void_evidence_cited_pr_numbers "the ledger row is already marked resolved" "Poetic-Poems/poetic")"
assert_eq "a bare citation with no default slug still prints, with an empty slug" \
  "#232" "$(void_evidence_cited_pr_numbers "PR #232 implemented it" "")"
assert_eq "a GitHub PR URL is extracted with its own owner/repo" \
  "Poetic-Poems/agent-ops#281" \
  "$(void_evidence_cited_pr_numbers \
    "see https://github.com/Poetic-Poems/agent-ops/pull/281 for the fix" "Poetic-Poems/poetic")"
assert_eq "a PR URL from a different repo than DEFAULT_SLUG keeps its own slug" \
  "Poetic-Poems/poetic-fiddle#40" \
  "$(void_evidence_cited_pr_numbers \
    "https://github.com/Poetic-Poems/poetic-fiddle/pull/40 landed it" "Poetic-Poems/poetic")"
assert_eq "a PR URL needs no default slug at all" \
  "Poetic-Poems/agent-ops#281" \
  "$(void_evidence_cited_pr_numbers "https://github.com/Poetic-Poems/agent-ops/pull/281" "")"

assert_eq "a 'commit <sha>' citation is extracted" \
  "Poetic-Poems/poetic#aad1405b" \
  "$(void_evidence_cited_commit_shas "landed as commit aad1405b on main" "Poetic-Poems/poetic")"
assert_eq "a 'ref@sha' citation is extracted" \
  "Poetic-Poems/poetic#aad1405" \
  "$(void_evidence_cited_commit_shas "main@aad1405 has the fix" "Poetic-Poems/poetic")"
assert_eq "an all-letter hex word with no digit is not a SHA citation" \
  "" "$(void_evidence_cited_commit_shas "the commit deadbeef is a placeholder word" "Poetic-Poems/poetic")"
assert_eq "no citation at all extracts nothing" \
  "" "$(void_evidence_cited_commit_shas "the ledger row is already marked resolved" "Poetic-Poems/poetic")"
assert_eq "a bare commit citation with no default slug still prints, with an empty slug" \
  "#aad1405b" "$(void_evidence_cited_commit_shas "commit aad1405b landed it" "")"
assert_eq "a GitHub commit URL is extracted with its own owner/repo" \
  "Poetic-Poems/agent-ops#30aa46f69ec8" \
  "$(void_evidence_cited_commit_shas \
    "see https://github.com/Poetic-Poems/agent-ops/commit/30aa46f69ec8 for the fix" \
    "Poetic-Poems/poetic")"
assert_eq "a commit URL from a different repo than DEFAULT_SLUG keeps its own slug" \
  "Poetic-Poems/poetic-fiddle#1a2b3c4" \
  "$(void_evidence_cited_commit_shas \
    "https://github.com/Poetic-Poems/poetic-fiddle/commit/1a2b3c4 landed it" \
    "Poetic-Poems/poetic")"
# The URL's SHA is taken in either case, and — the point of the assertion —
# the pattern that matches it and the expression that extracts it agree on
# that. When they did not, an upper-case SHA matched the pattern but not the
# extraction, and the pair came back carrying the whole URL where its sha
# belonged, refusing an honest citation with an unreadable reason.
assert_eq "an upper-case SHA in a commit URL is extracted as the SHA, not the whole URL" \
  "Poetic-Poems/agent-ops#30AA46F69EC8" \
  "$(void_evidence_cited_commit_shas \
    "see https://github.com/Poetic-Poems/agent-ops/commit/30AA46F69EC8 for the fix" \
    "Poetic-Poems/poetic")"

# --- void_pr_matches_item: the exact shape of the shipped defect --------------
# #224's Co-Ordinator voided it citing "PR #232 implemented all five rewrites".
# #232 was real and mergeable — but it was #221's PR, not #224's; #224's actual
# fix was #235. Fixtures reproduce exactly that.
cat >"$tmp_dir/pr-232.json" <<'JSON'
{"body": "Implements the five rewrites for item 221.", "head": {"ref": "agent/221"}}
JSON
cat >"$tmp_dir/pr-235.json" <<'JSON'
{"body": "Closes #224 — implements the five rewrites.", "head": {"ref": "agent/224"}}
JSON

out="$(void_pr_matches_item "Poetic-Poems/poetic" "232" "224" "Poetic-Poems/poetic")"; rc=$?
assert_eq "an unrelated-but-real PR does not match" "1" "$rc"
assert_contains "  ... naming the fabrication" "fabricated citation" "$out"

assert_eq "the genuinely implementing PR matches" \
  "0" "$(void_pr_matches_item "Poetic-Poems/poetic" "235" "224" "Poetic-Poems/poetic"; echo $?)"

out="$(void_pr_matches_item "Poetic-Poems/poetic" "999" "224" "Poetic-Poems/poetic")"; rc=$?
assert_eq "an unreadable cited PR does not match" "1" "$rc"
assert_contains "  ... saying so" "could not be read" "$out"

assert_eq "matching on the branch name alone is enough" \
  "0" "$(printf '{"body": "", "head": {"ref": "td/TD26051201"}}' >"$tmp_dir/pr-50.json"; \
    void_pr_matches_item "Poetic-Poems/poetic" "50" "TD26051201" "Poetic-Poems/poetic"; echo $?)"

# A bare numeric item must not match a PR merely because a *longer* number
# containing it appears somewhere — the word-boundary discipline this whole
# check exists to apply.
printf '{"body": "see line 1224 for details", "head": {"ref": "agent/9224x"}}' >"$tmp_dir/pr-60.json"
out="$(void_pr_matches_item "Poetic-Poems/poetic" "60" "224" "Poetic-Poems/poetic")"; rc=$?
assert_eq "a number embedded in a longer number does not match" "1" "$rc"

# --- void_finishing_item_pr: reading the PR number out of the id --------------
assert_eq "an abandoned-draft id yields its PR number" \
  "205" "$(void_finishing_item_pr "pr-205-abandoned-1a2b3c4d5e6f")"
assert_eq "a review-feedback id yields its PR number" \
  "205" "$(void_finishing_item_pr "pr-205-review-2071883842")"
assert_eq "a merge-conflict id yields its PR number" \
  "205" "$(void_finishing_item_pr "pr-205-conflict-1a2b3c4d5e6f")"
assert_eq "a superseded-bump id yields its PR number" \
  "205" "$(void_finishing_item_pr "pr-205-superseded-1a2b3c4d5e6f")"
assert_eq "a dequeued id yields its PR number" \
  "205" "$(void_finishing_item_pr "pr-205-dequeued-1a2b3c4d5e6f")"
assert_eq "an ordinary tech-debt id yields nothing" \
  "" "$(void_finishing_item_pr "TD26051201")"
assert_eq "a bare issue number yields nothing" "" "$(void_finishing_item_pr "224")"
# The trailing dash of the id's own shape is what keeps `pr-2050-…` from
# reading as `pr-205-…`.
assert_eq "a longer embedded number is not truncated to a prefix match" \
  "2050" "$(void_finishing_item_pr "pr-2050-abandoned-1a2b3c4d5e6f")"

# --- void_finishing_item_shape: which source minted the id --------------------
# The shape decides which live test the void gets, so an id whose middle word is
# none of the three must read as unknown and take the strict test, never the
# permissive one.
assert_eq "an abandoned-draft id names its source" \
  "abandoned" "$(void_finishing_item_shape "pr-205-abandoned-1a2b3c4d5e6f")"
assert_eq "a review-feedback id names its source" \
  "review" "$(void_finishing_item_shape "pr-205-review-2071883842")"
assert_eq "a merge-conflict id names its source" \
  "conflict" "$(void_finishing_item_shape "pr-205-conflict-1a2b3c4d5e6f")"
assert_eq "a superseded-bump id names its source" \
  "superseded" "$(void_finishing_item_shape "pr-205-superseded-1a2b3c4d5e6f")"
assert_eq "a dequeued id names its source" \
  "dequeued" "$(void_finishing_item_shape "pr-205-dequeued-1a2b3c4d5e6f")"
assert_eq "an unrecognised middle word names no source" \
  "" "$(void_finishing_item_shape "pr-205-something-else")"
assert_eq "the shape is read case-insensitively, as item ids are throughout" \
  "conflict" "$(void_finishing_item_shape "PR-205-Conflict-1a2b3c4d5e6f")"
assert_eq "an ordinary tech-debt id names no source" \
  "" "$(void_finishing_item_shape "TD26051201")"

# --- void_finishing_pr_reason: what "already done" means for one of these -----
# A finishing-source item exists only to finish one named pull request, so its
# void is corroborated by that PR's own live state rather than by a diff
# against a gathered candidate — the fetch these items need is driven by their
# id, not by a per-cycle candidate list, so it works identically for the
# Enabler and the Implementor (repos: []) as for the Co-Ordinator
# (TD-PPagop-26080807). Closed corroborates every shape; an *open* PR is read
# against what its own shape claims, with the strictness calibrated to what
# requirement 34k then does with the void.
printf '{"state": "closed", "merged_at": "2026-08-01T00:00:00Z"}' >"$tmp_dir/pr-210.json"
assert_eq "a merged PR corroborates outright" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "210" "pr-210-abandoned-aaaaaaaaaaaa"; echo $?)"
assert_eq "  ... and so does a merged PR cited by a superseded-bump item" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "210" "pr-210-superseded-aaaaaaaaaaaa"; echo $?)"

printf '{"state": "closed", "merged_at": null}' >"$tmp_dir/pr-211.json"
assert_eq "a closed, unmerged PR corroborates too — there is nothing left to finish on it" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "211" "pr-211-abandoned-bbbbbbbbbbbb"; echo $?)"

# `-abandoned-` and `-review-` are the two shapes requirement 34k *closes* the
# pull request for, so an empty diff against its base is the only open-PR
# reading accepted: closing it then discards nothing.
printf '{"state": "open"}' >"$tmp_dir/pr-212.json"
printf '0' >"$tmp_dir/files-212"
assert_eq "an open PR with an empty diff against its base corroborates" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "212" "pr-212-abandoned-cccccccccccc"; echo $?)"

printf '{"state": "open"}' >"$tmp_dir/pr-213.json"
printf '3' >"$tmp_dir/files-213"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "213" "pr-213-abandoned-dddddddddddd")"; rc=$?
assert_eq "an open PR that still changes files is refused" "1" "$rc"
assert_contains "  ... naming the count still outstanding" "still changes 3 file(s)" "$out"
assert_contains "  ... refuted" "refuted:" "$out"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "213" "pr-213-review-2071883842")"; rc=$?
assert_eq "  ... and the review-feedback shape is read exactly the same way" "1" "$rc"
assert_contains "  ... on the same diff" "still changes 3 file(s)" "$out"
# An id whose shape is none of the three gets the strict reading, not the
# permissive one.
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "213" "pr-213-something-else")"; rc=$?
assert_eq "  ... as does an id of no recognised shape" "1" "$rc"

out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "214" "pr-214-abandoned-eeeeeeeeeeee")"; rc=$?
assert_eq "an unreadable PR is refused, not treated as innocent" "1" "$rc"
assert_contains "  ... saying so" "could not be read" "$out"

# The human-applied `obsolete` label (TD-PPagop-26081308) is the other reading
# an open `-abandoned-`/`-review-` PR can be accepted on: checked live off the
# same fetch that already read `state`, before the `/files` diff count is ever
# asked for. `files-222`/`files-223` are deliberately absent, so a stray diff
# fetch on a labelled PR would fail loudly rather than pass by coincidence.
: >"$tmp_dir/calls.log"
printf '{"state": "open", "labels": [{"name": "obsolete"}]}' >"$tmp_dir/pr-222.json"
assert_eq "an open, still-diff-carrying PR labelled obsolete corroborates an abandoned-draft void" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "222" "pr-222-abandoned-ffffffffffff"; echo $?)"
assert_eq "  ... without ever fetching its diff" "0" \
  "$(grep -c 'pulls/222/files' "$tmp_dir/calls.log" || true)"

printf '{"state": "open", "labels": [{"name": "obsolete"}]}' >"$tmp_dir/pr-223.json"
assert_eq "  ... and the review-feedback shape is read exactly the same way" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "223" "pr-223-review-2071883842"; echo $?)"

# The label match is case-insensitive on the label's own name, and unmoved by
# other labels sharing the PR — the same "any of the listed labels" reading
# GitHub's own UI gives a labelled object.
printf '{"state": "open", "labels": [{"name": "bug"}, {"name": "Obsolete"}]}' >"$tmp_dir/pr-222.json"
assert_eq "  ... case-insensitively, and alongside other labels" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "222" "pr-222-abandoned-ffffffffffff"; echo $?)"

# The label buys nothing on its own — a PR with a non-empty diff and no
# `obsolete` label is still refused, whether or not other labels are present.
printf '{"state": "open", "labels": [{"name": "bug"}]}' >"$tmp_dir/pr-222.json"
printf '2' >"$tmp_dir/files-222"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "222" "pr-222-abandoned-ffffffffffff")"; rc=$?
assert_eq "  ... but an unlabelled PR still falls to the diff test" "1" "$rc"
assert_contains "  ... refused on the outstanding diff" "still changes 2 file(s)" "$out"

# An id of no recognised shape gets the strict reading even when the PR is
# labelled — the label corroborates only the two shapes 34k actually closes
# for on the diff claim.
printf '{"state": "open", "labels": [{"name": "obsolete"}]}' >"$tmp_dir/pr-225.json"
printf '4' >"$tmp_dir/files-225"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "225" "pr-225-something-else")"; rc=$?
assert_eq "an id of no recognised shape ignores the label" "1" "$rc"
assert_contains "  ... and is still refused on the diff" "still changes 4 file(s)" "$out"

# The label is equally inert on the two shapes it was never meant to
# corroborate: `-conflict-` still reads its own mergeability, and
# `-superseded-` still reads its own author/newer-bump pair, whatever the PR
# is labelled.
printf '{"state": "open", "mergeable": false, "user": {"login": "someone-else"}, "labels": [{"name": "obsolete"}]}' \
  >"$tmp_dir/pr-226.json"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "226" "pr-226-conflict-000000000000")"; rc=$?
assert_eq "a labelled but still-conflicting PR is refused on the conflict shape" "1" "$rc"
assert_contains "  ... on the conflict, not the label" "still conflicting" "$out"

printf '{"state": "open", "mergeable": false, "user": {"login": "someone-else"}, "labels": [{"name": "obsolete"}]}' \
  >"$tmp_dir/pr-227.json"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "227" "pr-227-superseded-000000000000")"; rc=$?
assert_eq "a labelled PR that is not Dependabot's own is refused on the superseded shape" "1" "$rc"
assert_contains "  ... on the author, not the label" "authored by someone-else" "$out"

# `-conflict-` is the shape requirement 34k closes *nothing* for
# (TD-PPagop-26080901): the void says the conflict resolved, not the pull
# request, which stays a live PR of ours carrying its full diff. So the diff
# test is not the test — mergeability is, mirroring the `CONFLICTING` reading
# that minted the item in gather-merge-conflicts.sh. A non-empty diff on a PR
# GitHub no longer calls conflicting corroborates the void; `files-217` is
# deliberately absent, so a stray diff fetch here would fail loudly.
printf '{"state": "open", "mergeable": true, "user": {"login": "someone-else"}}' >"$tmp_dir/pr-217.json"
assert_eq "a conflict item whose PR is mergeable again corroborates, diff and all" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "217" "pr-217-conflict-111111111111"; echo $?)"

# Mergeability GitHub has not finished computing reads as not *definitively*
# conflicting and is accepted — the same asymmetry the gatherer chose in the
# other direction, admitting a candidate on CONFLICTING and never on UNKNOWN.
printf '{"state": "open", "mergeable": null, "user": {"login": "someone-else"}}' >"$tmp_dir/pr-218.json"
assert_eq "  ... as does one whose mergeability is not yet computed" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "218" "pr-218-conflict-222222222222"; echo $?)"

printf '{"state": "open", "mergeable": false, "user": {"login": "someone-else"}}' >"$tmp_dir/pr-216.json"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "216" "pr-216-conflict-000000000000")"; rc=$?
assert_eq "a conflict item whose PR is still conflicting is refused" "1" "$rc"
assert_contains "  ... on the conflict, never on the diff" "still conflicting" "$out"

# --- The `dequeued` shape (TD-PPagop-26081409): mirrors `conflict` — closes
# nothing, re-derives its own claim live rather than trusting the entry's own
# evidence. The test here is the head SHA embedded in the item's own id,
# compared against the PR's *current* head, and — only when they still
# match — `lib/merge-queue.sh`'s `merge_queue_probe`, re-read live.
graphql_probe() {  # <queued: true|false> [dequeued_at] [reason]
  local queued="$1" at="${2:-}" reason="${3:-}" nodes='[]'
  if [[ -n "$at" ]]; then
    nodes="$(jq -nc --arg at "$at" --arg r "$reason" '[{createdAt:$at, reason:$r}]')"
  fi
  jq -nc --argjson q "$queued" --argjson n "$nodes" \
    '{data: {repository: {pullRequest: {isInMergeQueue: $q, timelineItems: {nodes: $n}}}}}' \
    > "$tmp_dir/mq-response.json"
}

# #230: PR's current head still matches the item's embedded SHA, and the probe
# still reports it not re-queued — nothing has changed since the dequeue this
# item names, so the void is refused.
printf '{"state": "open", "head": {"sha": "111111111111aaaabbbbcccc"}}' >"$tmp_dir/pr-230.json"
graphql_probe false "2026-08-14T01:00:00Z" "failed_checks"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "230" "pr-230-dequeued-111111111111")"; rc=$?
assert_eq "a dequeued item whose PR is still at the same head and not re-queued is refused" "1" "$rc"
assert_contains "  ... on the dequeue, same head, not re-queued" "still at the same head and not re-queued" "$out"

# #230 again, same head, but now re-queued since — a human acted, so the void
# corroborates even though nothing about the code changed.
graphql_probe true
assert_eq "the same PR, now re-queued at the same head, corroborates" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "230" "pr-230-dequeued-111111111111"; echo $?)"

# #231: PR's current head has moved past what the item names — a fix landed,
# whether by this cycle or another — so the void corroborates regardless of
# what the probe would say; deliberately no mq-response.json fixture removed
# ahead of this call (queued:true is still cached from above), proving the
# head check alone decided it rather than a lucky probe answer.
printf '{"state": "open", "head": {"sha": "222222222222ddddeeeeffff"}}' >"$tmp_dir/pr-231.json"
assert_eq "a dequeued item whose PR's head has since moved corroborates without even asking the probe" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "231" "pr-231-dequeued-111111111111"; echo $?)"

# #233: same head as the item names, but the probe cannot answer at all (no
# mq-response.json fixture) — accepted, the same "ambiguous accepts" asymmetry
# the conflict shape's null-mergeable case gets above (#218).
rm -f "$tmp_dir/mq-response.json"
printf '{"state": "open", "head": {"sha": "333333333333aaaabbbbcccc"}}' >"$tmp_dir/pr-233.json"
assert_eq "a dequeued item whose merge-queue probe cannot answer corroborates" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "233" "pr-233-dequeued-333333333333"; echo $?)"

# `-superseded-` (TD-PPagop-26081304) is the shape requirement 34k *does*
# close the pull request for, and the `-conflict-` shape's mergeability test
# proves the wrong claim here — a superseded bump can be superseded whether or
# not it still conflicts. So this shape gets its own live test instead:
# accepted only when both the PR's author is still Dependabot's and a
# strictly-newer open bump of the same family is still open, re-derived now
# rather than trusted from the entry's own `superseded_evidence`.
printf '{"state": "open", "mergeable": false, "user": {"login": "dependabot[bot]"}, "head": {"ref": "dependabot/npm_and_yarn/eslint-9.39.5"}}' \
  >"$tmp_dir/pr-219.json"
printf '[{"number": 220, "headRefName": "dependabot/npm_and_yarn/eslint-10.9.0"}]' \
  >"$tmp_dir/prlist-Poetic-Poems_poetic.json"
assert_eq "a Dependabot bump with a newer open bump of the same family corroborates" \
  "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "219" "pr-219-superseded-ffffffffffff"; echo $?)"

# `mergeable` decides nothing on this shape, in either direction — a bump is
# superseded whether or not it still conflicts, and reading the field here
# would be the `-conflict-` test smuggled back in. The fixture above pins
# `false`; these pin the other two readings, so a regression that started
# consulting the field fails on one of the three rather than passing by
# whichever one it happened to be given.
for mergeable in true null; do
  printf '{"state": "open", "mergeable": %s, "user": {"login": "dependabot[bot]"}, "head": {"ref": "dependabot/npm_and_yarn/eslint-9.39.5"}}' \
    "$mergeable" >"$tmp_dir/pr-219.json"
  assert_eq "  ... whatever mergeable reads ($mergeable)" \
    "0" "$(void_finishing_pr_reason "Poetic-Poems/poetic" "219" "pr-219-superseded-ffffffffffff"; echo $?)"
done
printf '{"state": "open", "mergeable": false, "user": {"login": "dependabot[bot]"}, "head": {"ref": "dependabot/npm_and_yarn/eslint-9.39.5"}}' \
  >"$tmp_dir/pr-219.json"

# Re-derived live, not read off the void's own claim: no newer bump open now
# (Dependabot merged it, or it was closed) refuses even though the item still
# says superseded.
printf '[]' >"$tmp_dir/prlist-Poetic-Poems_poetic.json"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "219" "pr-219-superseded-ffffffffffff")"; rc=$?
assert_eq "  ... but not once no newer bump is open" "1" "$rc"
assert_contains "  ... naming the missing bump" "has none open now" "$out"

# The listing that answers it is bounded at GITHUB_PR_LIST_LIMIT (PR #352) —
# the same stated cap the gatherer that minted the item read at, so the two
# reads cannot page differently — and an empty answer that came back at the
# cap refuses naming the cap: "no newer bump in the first N" is not "no newer
# bump". A newer bump *found* in a listing at the cap is real regardless of
# what the cap hid, so that one still corroborates. The cap is forced down to
# the fixture's own size per call, never reassigned for the file.
printf '[{"number": 220, "headRefName": "dependabot/npm_and_yarn/prettier-4.0.0"}, {"number": 222, "headRefName": "dependabot/github_actions/github/codeql-action-4.37.3"}]' \
  >"$tmp_dir/prlist-Poetic-Poems_poetic.json"
out="$(GITHUB_PR_LIST_LIMIT=2 void_finishing_pr_reason "Poetic-Poems/poetic" "219" "pr-219-superseded-ffffffffffff")"; rc=$?
assert_eq "  ... and an empty answer from a listing at its cap still refuses" "1" "$rc"
assert_contains "  ... naming the cap rather than asserting absence" "came back at its 2-item cap" "$out"

: >"$tmp_dir/calls.log"
printf '[{"number": 220, "headRefName": "dependabot/npm_and_yarn/eslint-10.9.0"}, {"number": 222, "headRefName": "dependabot/npm_and_yarn/prettier-4.0.0"}]' \
  >"$tmp_dir/prlist-Poetic-Poems_poetic.json"
assert_eq "  ... while a newer bump found in a listing at the cap corroborates — present is real" \
  "0" "$(GITHUB_PR_LIST_LIMIT=2 void_finishing_pr_reason "Poetic-Poems/poetic" "219" "pr-219-superseded-ffffffffffff"; echo $?)"
assert_eq "  ... and the listing asked for the stated cap, not gh's default" \
  "1" "$(grep -c -- '--limit 2 ' "$tmp_dir/calls.log" || true)"

# The author test runs first, and independently: a superseded-shaped item
# citing a PR that is not Dependabot's own is refused on the author alone. The
# newer bump is deliberately present in the live list for this one, and the
# head ref deliberately of that same family, so the refusal cannot be the
# no-newer-bump half passing itself off as the author half — the fourth of the
# four author x newer-bump combinations, and the only one where the two tests
# would disagree.
printf '[{"number": 220, "headRefName": "dependabot/npm_and_yarn/eslint-10.9.0"}]' \
  >"$tmp_dir/prlist-Poetic-Poems_poetic.json"
printf '{"state": "open", "mergeable": false, "user": {"login": "someone-else"}, "head": {"ref": "dependabot/npm_and_yarn/eslint-9.39.5"}}' \
  >"$tmp_dir/pr-221.json"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "221" "pr-221-superseded-ffffffffffff")"; rc=$?
assert_eq "a superseded item whose PR is not Dependabot's own is refused" "1" "$rc"
assert_contains "  ... naming the author" "authored by someone-else" "$out"

# Dependabot's authorship buys nothing on a shape whose corroborated void
# closes the pull request for a reason other than supersession: `-conflict-`
# still reads its own mergeability, unmoved by who authored the PR.
printf '{"state": "open", "mergeable": false, "user": {"login": "dependabot[bot]"}}' \
  >"$tmp_dir/pr-215.json"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "215" "pr-215-conflict-ffffffffffff")"; rc=$?
assert_eq "a still-conflicting Dependabot bump is no longer excused on the conflict shape" "1" "$rc"
assert_contains "  ... refused on the conflict, same as any other author" "still conflicting" "$out"

printf '5' >"$tmp_dir/files-215"
out="$(void_finishing_pr_reason "Poetic-Poems/poetic" "215" "pr-215-abandoned-ffffffffffff")"; rc=$?
assert_eq "  ... and buys nothing on an abandoned-draft or review item either" "1" "$rc"
assert_contains "  ... which is still read on its diff" "still changes 5 file(s)" "$out"

# --- void_pr_matches_item: the finishing-source id shortcut --------------------
# A finishing-source item is a pull request, and its id says which one. PR
# #205's body and branch will never spell `pr-205-abandoned-<head-sha>`, so
# without reading the id itself the guard would refuse the one citation these
# items can honestly make — their own pull request. Closed corroborates every
# shape outright, so this fixture proves the id selects the live-state check,
# not that the state check is skipped — a `files-205` fixture is deliberately
# absent, so a wrong diff fetch here would fail loudly rather than pass by
# coincidence.
printf '{"state": "closed", "body": "Draft implementing the widget.", "head": {"ref": "agent/widget"}}' \
  >"$tmp_dir/pr-205.json"
for shape in "pr-205-abandoned-1a2b3c4d5e6f" "pr-205-review-2071883842" "pr-205-conflict-1a2b3c4d5e6f" "pr-205-superseded-1a2b3c4d5e6f"; do
  assert_eq "a finishing-source item citing its own PR matches ($shape)" \
    "0" "$(void_pr_matches_item "Poetic-Poems/poetic" "205" "$shape" "Poetic-Poems/poetic"; echo $?)"
done
out="$(void_pr_matches_item "Poetic-Poems/poetic" "232" "pr-205-abandoned-1a2b3c4d5e6f" "Poetic-Poems/poetic")"; rc=$?
assert_eq "  ... but citing a different PR is still refused" "1" "$rc"
assert_contains "  ... as a fabrication" "fabricated citation" "$out"
# `pr-2050-…` is a different item from `pr-205-…`: the trailing dash of the
# id's own shape is what keeps one from reading as the other. Falls through to
# the ordinary body/branch test against `pr-205.json`, which names neither.
out="$(void_pr_matches_item "Poetic-Poems/poetic" "205" "pr-2050-abandoned-1a2b3c4d5e6f" "Poetic-Poems/poetic")"; rc=$?
assert_eq "  ... and a longer PR number is not this PR" "1" "$rc"

# --- void_pr_matches_item: the id shortcut is slug-gated (issue #290) ----------
# The id `pr-281-…` names a pull request in the repository that minted it, so
# the number is identity only within the entry's own repo. A URL citation
# carrying any other owner/repo used to corroborate on the number coincidence
# alone, with no fetch at all — the one citation shape the guard could never
# catch, since nothing was ever read.

# Cross-repo, same number: no fixture exists for Some/OtherRepo#281, so the
# refusal is itself the proof a fetch was attempted where none used to be.
out="$(void_pr_matches_item "Some/OtherRepo" "281" "pr-281-abandoned-deadbee1" "Poetic-Poems/agent-ops")"; rc=$?
assert_eq "a cross-repo citation of a coinciding number does not take the id shortcut" "1" "$rc"
assert_contains "  ... it is fetched, and refused unread" "could not be read" "$out"

# ... and when the cross-repo PR does exist, its body and branch decide, like
# any other citation's.
printf '{"body": "Bumps the widget from 1.2 to 1.3.", "head": {"ref": "dependabot/widget-1.3"}}' \
  >"$tmp_dir/pr-Some_OtherRepo-281.json"
out="$(void_pr_matches_item "Some/OtherRepo" "281" "pr-281-abandoned-deadbee1" "Poetic-Poems/agent-ops")"; rc=$?
assert_eq "  ... and a fetched cross-repo body naming no item is refused" "1" "$rc"
assert_contains "  ... as a fabrication" "fabricated citation" "$out"

# Same repo: the shortcut fetches PR #281's own live state — closed
# corroborates outright, so no `files-281` fixture is needed to prove it (and
# its absence means a wrong diff fetch here would fail loudly, not pass by
# coincidence).
printf '{"state": "closed", "body": "", "head": {"ref": "agent/281"}}' \
  >"$tmp_dir/pr-Poetic-Poems_agent-ops-281.json"
assert_eq "a same-repo citation takes the id shortcut, corroborated by the PR's own live state" \
  "0" "$(void_pr_matches_item "Poetic-Poems/agent-ops" "281" "pr-281-abandoned-deadbee1" \
    "Poetic-Poems/agent-ops"; echo $?)"
assert_eq "  ... comparing the slugs case-insensitively, as GitHub does" \
  "0" "$(void_pr_matches_item "poetic-poems/AGENT-OPS" "281" "pr-281-abandoned-deadbee1" \
    "Poetic-Poems/agent-ops"; echo $?)"

# --- void_commit_matches_item ---------------------------------------------------
printf 'main' >"$tmp_dir/repo-Poetic-Poems_poetic"

printf '{"status": "ahead"}' >"$tmp_dir/compare-aad1405b_TO_main.json"
printf '{"commit": {"message": "fix(sync): add timeouts (TD26051201)"}}' \
  >"$tmp_dir/commit-aad1405b.json"
assert_eq "an ancestor commit whose own message names the item matches" \
  "0" "$(void_commit_matches_item "Poetic-Poems/poetic" "aad1405b" "TD26051201" "Poetic-Poems/poetic"; echo $?)"

printf '{"status": "ahead"}' >"$tmp_dir/compare-bbbb111_TO_main.json"
printf '{"commit": {"message": "fix(sync): add timeouts"}}' >"$tmp_dir/commit-bbbb111.json"
printf '50\n' >"$tmp_dir/commit-bbbb111-pulls"
assert_eq "an ancestor commit with no item in its own message matches via its linked PR" \
  "0" "$(void_commit_matches_item "Poetic-Poems/poetic" "bbbb111" "TD26051201" "Poetic-Poems/poetic"; echo $?)"

printf '{"status": "diverged"}' >"$tmp_dir/compare-ccccccc_TO_main.json"
out="$(void_commit_matches_item "Poetic-Poems/poetic" "ccccccc" "TD26051201" "Poetic-Poems/poetic")"; rc=$?
assert_eq "a commit that is not an ancestor of default_branch is refused" "1" "$rc"
assert_contains "  ... saying so" "not an ancestor" "$out"

out="$(void_commit_matches_item "Poetic-Poems/poetic" "ddddddd" "TD26051201" "Poetic-Poems/poetic")"; rc=$?
assert_eq "an unreadable commit is refused" "1" "$rc"
assert_contains "  ... saying so" "could not be compared" "$out"

printf '{"status": "ahead"}' >"$tmp_dir/compare-eeeeeee_TO_main.json"
printf '{"commit": {"message": "fix(sync): add timeouts"}}' >"$tmp_dir/commit-eeeeeee.json"
out="$(void_commit_matches_item "Poetic-Poems/poetic" "eeeeeee" "TD26051201" "Poetic-Poems/poetic")"; rc=$?
assert_eq "an ancestor commit tied to nothing is refused" "1" "$rc"
assert_contains "  ... saying so" "neither its message nor any pull request" "$out"

# The slug gate travels through the associated-PR fallback (issue #290): a
# commit in another repository, linked there to its own PR #281, must not
# corroborate `pr-281-…` on the number, while the same link in the entry's
# own repo still does.
printf 'main' >"$tmp_dir/repo-Some_OtherRepo"
printf '{"status": "ahead"}' >"$tmp_dir/compare-Some_OtherRepo-abc1234_TO_main.json"
printf '{"commit": {"message": "bump widget to 1.3"}}' >"$tmp_dir/commit-Some_OtherRepo-abc1234.json"
printf '281\n' >"$tmp_dir/commit-Some_OtherRepo-abc1234-pulls"
out="$(void_commit_matches_item "Some/OtherRepo" "abc1234" "pr-281-abandoned-deadbee1" \
  "Poetic-Poems/agent-ops")"; rc=$?
assert_eq "a cross-repo commit's associated PR does not corroborate on the number" "1" "$rc"
assert_contains "  ... saying so" "neither its message nor any pull request" "$out"

printf 'main' >"$tmp_dir/repo-Poetic-Poems_agent-ops"
printf '{"status": "ahead"}' >"$tmp_dir/compare-Poetic-Poems_agent-ops-abc1234_TO_main.json"
printf '{"commit": {"message": "bump widget to 1.3"}}' >"$tmp_dir/commit-Poetic-Poems_agent-ops-abc1234.json"
printf '281\n' >"$tmp_dir/commit-Poetic-Poems_agent-ops-abc1234-pulls"
assert_eq "  ... while the entry's own repo's associated PR still does, on the id" \
  "0" "$(void_commit_matches_item "Poetic-Poems/agent-ops" "abc1234" "pr-281-abandoned-deadbee1" \
    "Poetic-Poems/agent-ops"; echo $?)"

# --- void_citation_reason: the entry-level composition -------------------------
entry_224_bad='{"item": "224", "repo": "Poetic-Poems/poetic",
  "reason": "the five rewrites are already merged",
  "evidence": "PR #232 implemented all five rewrites"}'
out="$(void_citation_reason "$entry_224_bad" "Poetic-Poems/poetic")"; rc=$?
assert_eq "a fabricated PR citation is refused" "1" "$rc"
assert_contains "  ... as a fabrication" "fabricated citation" "$out"

entry_224_good='{"item": "224", "repo": "Poetic-Poems/poetic",
  "reason": "the five rewrites are already merged",
  "evidence": "PR #235 implemented all five rewrites"}'
assert_eq "the genuinely implementing PR citation is accepted" \
  "0" "$(void_citation_reason "$entry_224_good" "Poetic-Poems/poetic"; echo $?)"

assert_eq "evidence with no citation at all has nothing to corroborate this way" \
  "0" "$(void_citation_reason '{"item": "224", "repo": "Poetic-Poems/poetic",
    "evidence": "read main directly, nothing remains"}' "Poetic-Poems/poetic"; echo $?)"

out="$(void_citation_reason '{"item": "224", "evidence": "PR #232 implemented it"}' "")"; rc=$?
assert_eq "a PR citation with no repo to check it against is refused" "1" "$rc"
assert_contains "  ... saying so" "names no repo" "$out"

# --- void_citation_reason: URL citations, resolved against their own repo -----
# The point of this item (TD-PPagop-26080806): PR #232 means something
# different in each repo. Poetic-Poems/poetic's own #232 (fixture above)
# implements item 221, not 224. A second, distinct #232 in
# Poetic-Poems/poetic-fiddle genuinely implements 224. A URL citation must
# resolve against the repo the URL itself names, never against the entry's
# `repo` — otherwise the second #232 would be tested against the first repo's
# PR and wrongly refused, or the first against the second's and wrongly
# accepted.
printf '{"body": "Closes #224 in poetic-fiddle.", "head": {"ref": "agent/224"}}' \
  >"$tmp_dir/pr-Poetic-Poems_poetic-fiddle-232.json"

entry_224_url_good='{"item": "224", "repo": "Poetic-Poems/poetic",
  "reason": "the five rewrites are already merged",
  "evidence": "see https://github.com/Poetic-Poems/poetic-fiddle/pull/232 for the fix"}'
assert_eq "a PR URL citation resolves against its own repo, not the entry's" \
  "0" "$(void_citation_reason "$entry_224_url_good" "Poetic-Poems/poetic"; echo $?)"

entry_224_url_wrong_repo='{"item": "224", "repo": "Poetic-Poems/poetic",
  "reason": "the five rewrites are already merged",
  "evidence": "see https://github.com/Poetic-Poems/poetic/pull/232 for the fix"}'
out="$(void_citation_reason "$entry_224_url_wrong_repo" "Poetic-Poems/poetic")"; rc=$?
assert_eq "  ... so the same PR number in the entry's own (wrong) repo is still refused" "1" "$rc"
assert_contains "  ... as a fabrication" "fabricated citation" "$out"

assert_eq "  ... and a PR URL citation needs no entry repo at all to resolve" \
  "0" "$(void_citation_reason '{"item": "224",
    "evidence": "https://github.com/Poetic-Poems/poetic-fiddle/pull/232 fixed it"}' ""; echo $?)"

# The same shape holds for a cited commit.
printf 'main' >"$tmp_dir/repo-Poetic-Poems_poetic-fiddle"
printf '{"status": "ahead"}' >"$tmp_dir/compare-Poetic-Poems_poetic-fiddle-cccccc1_TO_main.json"
printf '{"commit": {"message": "fix(sync): add timeouts (224)"}}' \
  >"$tmp_dir/commit-Poetic-Poems_poetic-fiddle-cccccc1.json"

entry_224_commit_url_good='{"item": "224", "repo": "Poetic-Poems/poetic",
  "reason": "already fixed",
  "evidence": "https://github.com/Poetic-Poems/poetic-fiddle/commit/cccccc1 has it"}'
assert_eq "a commit URL citation resolves against its own repo, not the entry's" \
  "0" "$(void_citation_reason "$entry_224_commit_url_good" "Poetic-Poems/poetic"; echo $?)"

# --- void_citation_reason: the id shortcut is slug-gated (issue #290) ----------
# The exact shape issue #290 is about: an entry for a finishing-source item
# whose evidence pastes another repository's PR URL, the two numbers
# coinciding. Corroborated with no fetch at all before the gate.
entry_281_cross='{"item": "pr-281-abandoned-deadbee1", "repo": "Poetic-Poems/agent-ops",
  "reason": "the draft is finished",
  "evidence": "see https://github.com/Some/OtherRepo/pull/281"}'
out="$(void_citation_reason "$entry_281_cross" "Poetic-Poems/agent-ops")"; rc=$?
assert_eq "a cross-repo URL citation of a coinciding number is refused" "1" "$rc"
assert_contains "  ... on what the fetch found" "fabricated citation" "$out"

# A bare self-citation resolves against the entry's own repo, so the gate
# never touches the ordinary finishing-source shape — it is corroborated by
# PR #281's own live state (the "closed" fixture set up above), not by the
# citation text.
assert_eq "a bare self-citation still corroborates via the id-driven live check" \
  "0" "$(void_citation_reason '{"item": "pr-281-abandoned-deadbee1",
    "repo": "Poetic-Poems/agent-ops",
    "evidence": "PR #281 has an empty diff against its base"}' "Poetic-Poems/agent-ops"; echo $?)"

# An entry naming no repo can still be corroborated by a URL citation — via
# the live test the gate falls through to, never on the number alone. This is
# the deliberate empty-repo improvement the gate must preserve.
printf '{"body": "Finishing the abandoned draft pr-281-abandoned-deadbee1.", "head": {"ref": "agent/finish-281"}}' \
  >"$tmp_dir/pr-Poetic-Poems_agent-ops-281.json"
assert_eq "an entry with no repo falls through to the live test, and can corroborate" \
  "0" "$(void_citation_reason '{"item": "pr-281-abandoned-deadbee1",
    "evidence": "https://github.com/Poetic-Poems/agent-ops/pull/281 is finished"}' ""; echo $?)"

# --- void_guard_reason: the acceptance criteria, verbatim -----------------------
# "a void citing an unrelated-but-real PR is rejected; a void citing the
# genuinely implementing PR passes" — and with `repos` = `[]`, exactly the way
# the Enabler and the Implementor call it (neither gathers candidates).
out="$(void_guard_reason "$entry_224_bad" '[]')"; rc=$?
assert_eq "void_guard_reason rejects a void citing an unrelated-but-real PR" "1" "$rc"
assert_contains "  ... not corroborated" "not corroborated" "$out"
assert_contains "  ... naming the fabrication" "fabricated citation" "$out"

assert_eq "void_guard_reason accepts a void citing the genuinely implementing PR" \
  "0" "$(void_guard_reason "$entry_224_good" '[]'; echo $?)"
assert_eq "  ... silently" "" "$(void_guard_reason "$entry_224_good" '[]')"

# The same corroboration applies with no `repos` argument at all — the exact
# call shape the Enabler and Implementor use.
assert_eq "void_guard_reason works with repos omitted entirely" \
  "0" "$(void_guard_reason "$entry_224_good"; echo $?)"
out="$(void_guard_reason "$entry_224_bad")"; rc=$?
assert_eq "  ... and still refuses the fabrication" "1" "$rc"

# And the finishing sources end to end: an abandoned-draft void whose evidence
# cites the draft's own pull request is the ordinary, correct shape of that
# verdict, so the citation test must not turn it into a refusal.
assert_eq "an abandoned-draft void citing its own PR survives the guard" \
  "0" "$(void_guard_reason '{"item": "pr-205-abandoned-1a2b3c4d5e6f",
    "repo": "Poetic-Poems/poetic", "reason": "the draft is finished",
    "evidence": "PR #205 has an empty diff against its base; nothing remains"}' '[]'; echo $?)"

# ... and the Co-Ordinator's own call shape reaches the identical verdict, in
# both directions, because the live-state fetch needs no candidate list
# (TD-PPagop-26080807). The populated `repos` here carries the very candidate
# the item was minted from, in the shape the gatherers actually emit it: the
# synthetic `pr-<n>-abandoned-…` id is the candidate's `ref`, while its `item`
# is whatever id the branch and body named — so `void_candidate_prs` matches
# nothing for a finishing-source item, and the id-driven fetch is the whole of
# what decides these either way, for every stage.
REPOS_FINISHING='[
  {"slug": "Poetic-Poems/poetic", "default_branch": "main",
   "findings": [], "review_feedback": [], "merge_conflicts": [],
   "abandoned_drafts": [
     {"source": "abandoned-drafts", "ref": "pr-206-abandoned-1a2b3c4d5e6f",
      "number": 206, "pr_number": 206, "item": null,
      "title": "feat(widget): the draft this item is"}]}
]'
entry_finishing='{"item": "pr-206-abandoned-1a2b3c4d5e6f",
  "repo": "Poetic-Poems/poetic", "reason": "the draft is finished",
  "evidence": "PR #206 has an empty diff against its base; nothing remains"}'
printf '{"state": "open", "body": "", "head": {"ref": "agent/widget"}}' >"$tmp_dir/pr-206.json"
printf '0' >"$tmp_dir/files-206"
assert_eq "an open, empty-diff finishing-source void is allowed on the \`[]\` call shape" \
  "0" "$(void_guard_reason "$entry_finishing" '[]'; echo $?)"
assert_eq "  ... and identically on the Co-Ordinator's populated \`repos\`" \
  "0" "$(void_guard_reason "$entry_finishing" "$REPOS_FINISHING"; echo $?)"

printf '4' >"$tmp_dir/files-206"
out="$(void_guard_reason "$entry_finishing" '[]')"; rc=$?
assert_eq "the same void once its PR changes files again is refused on \`[]\`" "1" "$rc"
assert_contains "  ... naming the count still outstanding" "still changes 4 file(s)" "$out"
out="$(void_guard_reason "$entry_finishing" "$REPOS_FINISHING")"; rc=$?
assert_eq "  ... and identically on the Co-Ordinator's populated \`repos\`" "1" "$rc"
assert_contains "  ... for the same reason" "still changes 4 file(s)" "$out"

# ... and the case that separates the shapes, end to end (TD-PPagop-26080901,
# pull request #264): a `-conflict-` item is void when the *conflict* resolved,
# which leaves its pull request open, mergeable and carrying its full diff — the
# very triple the `-abandoned-` reading above refuses. Requirement 34k closes
# nothing for this shape, so nothing is destroyed by allowing it, and refusing
# it would refuse every honest void the merge-conflicts source can write.
# `files-207` is deliberately absent: a diff fetch on this shape would fail
# loudly rather than pass by coincidence.
entry_conflict_resolved='{"item": "pr-207-conflict-1a2b3c4d5e6f",
  "repo": "Poetic-Poems/poetic", "reason": "the conflict on this PR has resolved",
  "evidence": "PR #207 no longer conflicts with its base"}'
printf '{"state": "open", "mergeable": true, "user": {"login": "Warwick-Allen"}, "body": "", "head": {"ref": "agent/widget"}}' \
  >"$tmp_dir/pr-207.json"
assert_eq "a resolved-conflict void of a live PR of ours survives the guard" \
  "0" "$(void_guard_reason "$entry_conflict_resolved" '[]'; echo $?)"
assert_eq "  ... silently" "" "$(void_guard_reason "$entry_conflict_resolved" '[]')"

printf '{"state": "open", "mergeable": false, "user": {"login": "Warwick-Allen"}, "body": "", "head": {"ref": "agent/widget"}}' \
  >"$tmp_dir/pr-207.json"
out="$(void_guard_reason "$entry_conflict_resolved" '[]')"; rc=$?
assert_eq "  ... while the same claim about a still-conflicting PR is refused" "1" "$rc"
assert_contains "  ... on the conflict itself" "still conflicting" "$out"

# ... while the cross-repo number coincidence (issue #290) is refused end to
# end, on the Enabler's and Implementor's own `[]` call shape — the shape the
# no-fetch shortcut used to corroborate.
out="$(void_guard_reason "$entry_281_cross" '[]')"; rc=$?
assert_eq "void_guard_reason refuses a cross-repo URL citation of a coinciding number" "1" "$rc"
assert_contains "  ... not corroborated" "not corroborated" "$out"

# --- Dependabot-superseded evidence, the exact shape gather-merge-conflicts.sh
# produces (issue #300, TD-PPagop-26081304). Before the id-shape split (issue
# #300) it named the superseding PR by URL, which PR #281 made the guard
# resolve live — and refuse, since a superseding bump never carries the
# superseded item's id. The repaired format cites the superseded PR's own
# number (corroborated via the finishing-source id shortcut) and names the
# superseding PR only by its branch name, which neither the PR-number nor the
# commit-SHA extractor matches.
#
# The superseded PR is still open and still carrying a real diff at the moment
# this void is recorded — superseding a bump does not empty it — so the
# shortcut's live fetch must corroborate on the supersession test
# (Dependabot's own authorship, a newer open bump of the same family still
# open), never on the diff. `mergeable` is deliberately `false` here too,
# matching the only state gather-merge-conflicts.sh ever gathers from, but it
# is irrelevant to this shape's own test — a regression that started reading
# it here would still pass by coincidence, which the file-129 fixture below
# guards against on the diff side.
printf '{"state": "open", "mergeable": false, "user": {"login": "dependabot[bot]"}, "body": "", "head": {"ref": "dependabot/npm_and_yarn/eslint-9.39.5"}}' \
  >"$tmp_dir/pr-Poetic-Poems_poetic-fiddle-129.json"
printf '2' >"$tmp_dir/files-129"
printf '[{"number": 130, "headRefName": "dependabot/npm_and_yarn/eslint-10.9.0"}]' \
  >"$tmp_dir/prlist-Poetic-Poems_poetic-fiddle.json"
entry_superseded="$(jq -n \
  --arg item "pr-129-superseded-c96c8ef9d31a" \
  --arg repo "Poetic-Poems/poetic-fiddle" \
  --arg reason "a newer Dependabot bump of the same dependency supersedes this one" \
  --arg evidence "PR #129's own branch (dependabot/npm_and_yarn/eslint at 9.39.5) is superseded: a newer open Dependabot pull request on branch dependabot/npm_and_yarn/eslint-10.9.0 bumps dependabot/npm_and_yarn/eslint to 10.9.0. Both cannot land — the older bump (this PR) is redundant now that the newer one exists." \
  '{item: $item, repo: $repo, reason: $reason, evidence: $evidence}')"
assert_eq "a Dependabot-superseded void, cited exactly as gather-merge-conflicts.sh formats it, survives the guard" \
  "0" "$(void_guard_reason "$entry_superseded" '[]'; echo $?)"
assert_eq "  ... silently" "" "$(void_guard_reason "$entry_superseded" '[]')"

# Once the newer bump is no longer open, the same void — unchanged, evidence
# and all — is refused: corroboration is re-derived live at void time, never
# trusted from the entry's own say-so.
printf '[]' >"$tmp_dir/prlist-Poetic-Poems_poetic-fiddle.json"
out="$(void_guard_reason "$entry_superseded" '[]')"; rc=$?
assert_eq "  ... but not once the newer bump is no longer open" "1" "$rc"
assert_contains "  ... naming the missing bump" "has none open now" "$out"

# --- The closed list itself (issue #413, WI-10) --------------------------------
# A finishing-source item is corroborated directly against its own pull
# request's live state — case (c) — even when its evidence carries no citation
# text at all and is not the structured shape either. This is what makes case
# (c) a genuine third alternative rather than a restatement of the citation
# shortcut: nothing here mentions "PR #240".
printf '{"state": "open"}' >"$tmp_dir/pr-240.json"
printf '0' >"$tmp_dir/files-240"
entry_240_prose='{"item": "pr-240-abandoned-abcdef123456", "repo": "Poetic-Poems/poetic",
  "reason": "the draft is finished", "evidence": "nothing remains in this draft"}'
assert_eq "a finishing-source item with uncited prose evidence still corroborates via its own PR's live state" \
  "0" "$(void_guard_reason "$entry_240_prose" '[]'; echo $?)"
assert_eq "  ... silently" "" "$(void_guard_reason "$entry_240_prose" '[]')"

printf '{"state": "open"}' >"$tmp_dir/pr-241.json"
printf '2' >"$tmp_dir/files-241"
entry_241_prose='{"item": "pr-241-abandoned-abcdef123456", "repo": "Poetic-Poems/poetic",
  "reason": "the draft is finished", "evidence": "nothing remains in this draft"}'
out="$(void_guard_reason "$entry_241_prose" '[]')"; rc=$?
assert_eq "  ... and is refused the same way once that PR still carries a diff" "1" "$rc"
assert_contains "  ... naming the count still outstanding" "still changes 2 file(s)" "$out"

# An ordinary (non-finishing-source) item with prose evidence naming neither a
# citation nor the structured shape has no checkable form at all, and is
# refused rather than accepted on presence alone — the exact repeal this WI is
# about, restated as a direct unit test of `void_guard_reason` rather than the
# end-to-end one above.
out="$(void_guard_reason '{"item": "TD26099901", "repo": "Poetic-Poems/poetic",
  "reason": "already done", "evidence": "it is done, trust me"}' '[]')"
rc=$?
assert_eq "an ordinary item with uncheckable prose evidence is refused" "1" "$rc"
assert_contains "  ... naming what was missing" "no checkable citation" "$out"
assert_contains "  ... naming the item" "TD26099901" "$out"

# --- Requirement pin: `unvoided` gains no machine path (issue #413, WI-10) -----
# D18 retires the human backstop that justified the residual void-trust gap
# this file closes, but `unvoided` itself is untouched by design (design doc
# §5.5): reversing a void is a judgement about intent, and the argument this
# file's own header makes for why no agent may weigh a void applies just as
# hard to clearing one. This module is the only place `item-void` is decided,
# so a machine path to `unvoided` would have to appear here first.
assert_eq "lib/void-guard.sh defines no unvoid-adjacent function" \
  "" "$(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$SCRIPT_DIR/lib/void-guard.sh" | grep -i unvoid || true)"

# --- The machine `obsolete` alternative (issue #413, WI-10, design doc §5.5) ---
# `void_draft_obsolete_flag_reason` corroborates a `draft-obsolete-flagged`
# event only where the installation trusts the fleet enough to act on it
# without the human label: `merge_autonomy_effective_level` `agent-merges-all`
# for this repo, a two-touch confirmation at least 24h apart from a different
# cycle, and structured evidence resolving live on *both* touches — the flag's
# own and the current void's. `NOW_EPOCH` is fixed so "24h old" is a
# deterministic boundary rather than a race against the wall clock.
NOW_EPOCH=1700000000
ts_before() {  # <seconds before NOW_EPOCH>
  date -u -d "@$(( NOW_EPOCH - $1 ))" +%Y-%m-%dT%H:%M:%SZ
}
CYCLE_NOW="20260815T090000Z-node-1-999"
CYCLE_OLD="20260814T060000Z-node-2-111"

printf '{"content":"%s"}' "$(printf 'irrelevant' | base64)" >"$tmp_dir/contents-main-FLAG-EXISTS.md"

ctx_agent_merges_all() {  # <flags-json>
  jq -nc --argjson now "$NOW_EPOCH" --arg cycle "$CYCLE_NOW" --argjson flags "$1" \
    '{merge_autonomy_level: "agent-merges-all", cycle: $cycle, now_epoch: $now, flags: $flags}'
}

flag_valid="$(jq -nc --arg ts "$(ts_before 90000)" \
  '{repo: "Poetic-Poems/poetic", item: "pr-250-abandoned-fedcba654321", pr: 250,
    evidence: {ref: "main", path: "FLAG-EXISTS.md", expect: "present"},
    cycle: "'"$CYCLE_OLD"'", node: "node-2", ts: $ts}')"

printf '{"state": "open"}' >"$tmp_dir/pr-250.json"
printf '3' >"$tmp_dir/files-250"
entry_250="$(jq -nc \
  '{item: "pr-250-abandoned-fedcba654321", repo: "Poetic-Poems/poetic",
    reason: "an independent, later Enabler engagement confirms this draft is unwanted",
    evidence: {ref: "main", path: "FLAG-EXISTS.md", expect: "present"}}')"
assert_eq "a draft void corroborates on a valid draft-obsolete-flagged event at agent-merges-all" \
  "0" "$(void_guard_reason "$entry_250" '[]' "$(ctx_agent_merges_all "[$flag_valid]")"; echo $?)"
assert_eq "  ... silently" "" "$(void_guard_reason "$entry_250" '[]' "$(ctx_agent_merges_all "[$flag_valid]")")"

# Below `agent-merges-all`, the identical flag corroborates nothing — only the
# human `obsolete` label does — so the same entry is refused on the ordinary
# diff test, unmoved by the flag.
ctx_below="$(jq -nc --argjson now "$NOW_EPOCH" --arg cycle "$CYCLE_NOW" --argjson flags "[$flag_valid]" \
  '{merge_autonomy_level: "agent-merges-routine", cycle: $cycle, now_epoch: $now, flags: $flags}')"
out="$(void_guard_reason "$entry_250" '[]' "$ctx_below")"; rc=$?
assert_eq "the same flag corroborates nothing below agent-merges-all" "1" "$rc"
assert_contains "  ... refused on the ordinary diff test" "still changes 3 file(s)" "$out"

# A flag younger than 24h does not corroborate, whatever else about it holds.
flag_too_young="$(jq -nc --arg ts "$(ts_before 3600)" \
  '{repo: "Poetic-Poems/poetic", item: "pr-250-abandoned-fedcba654321", pr: 250,
    evidence: {ref: "main", path: "FLAG-EXISTS.md", expect: "present"},
    cycle: "'"$CYCLE_OLD"'", node: "node-2", ts: $ts}')"
out="$(void_guard_reason "$entry_250" '[]' "$(ctx_agent_merges_all "[$flag_too_young]")")"; rc=$?
assert_eq "a flag younger than 24h does not corroborate" "1" "$rc"
assert_contains "  ... refused on the ordinary diff test" "still changes 3 file(s)" "$out"

# A flag from the very same cycle as the current void does not corroborate —
# it would be the same engagement corroborating its own judgement, not a
# second, independent look.
flag_same_cycle="$(jq -nc --arg ts "$(ts_before 90000)" \
  '{repo: "Poetic-Poems/poetic", item: "pr-250-abandoned-fedcba654321", pr: 250,
    evidence: {ref: "main", path: "FLAG-EXISTS.md", expect: "present"},
    cycle: "'"$CYCLE_NOW"'", node: "node-1", ts: $ts}')"
out="$(void_guard_reason "$entry_250" '[]' "$(ctx_agent_merges_all "[$flag_same_cycle]")")"; rc=$?
assert_eq "a flag from the same cycle as the current void does not corroborate" "1" "$rc"
assert_contains "  ... refused on the ordinary diff test" "still changes 3 file(s)" "$out"

# A flag whose own evidence is prose, not the structured shape, does not
# corroborate — both touches must clear the strictest bar this guard has.
flag_prose_evidence="$(jq -nc --arg ts "$(ts_before 90000)" \
  '{repo: "Poetic-Poems/poetic", item: "pr-250-abandoned-fedcba654321", pr: 250,
    evidence: "the draft is redundant now", cycle: "'"$CYCLE_OLD"'", node: "node-2", ts: $ts}')"
out="$(void_guard_reason "$entry_250" '[]' "$(ctx_agent_merges_all "[$flag_prose_evidence]")")"; rc=$?
assert_eq "a flag whose own evidence is prose does not corroborate" "1" "$rc"
assert_contains "  ... refused on the ordinary diff test" "still changes 3 file(s)" "$out"

# The current void's own evidence must also be the structured shape and
# resolve live — a citation-shaped current void does not reach the flag path
# even when a perfectly valid flag exists, because the precondition is about
# the current touch, not only the earlier one.
entry_250_citation="$(jq -nc \
  '{item: "pr-250-abandoned-fedcba654321", repo: "Poetic-Poems/poetic",
    reason: "an independent, later Enabler engagement confirms this draft is unwanted",
    evidence: "PR #250 is confirmed unwanted by a later Enabler pass"}')"
printf '{"body": "", "head": {"ref": "agent/250"}}' >"$tmp_dir/pr-250.json"
out="$(void_guard_reason "$entry_250_citation" '[]' "$(ctx_agent_merges_all "[$flag_valid]")")"; rc=$?
assert_eq "a current void with citation-shaped (not structured) evidence does not reach the flag path" "1" "$rc"
assert_contains "  ... refused on the ordinary diff test" "still changes 3 file(s)" "$out"
printf '{"state": "open"}' >"$tmp_dir/pr-250.json"

# A flag naming a different item does not corroborate this one, even with
# every other condition met.
flag_wrong_item="$(jq -nc --arg ts "$(ts_before 90000)" \
  '{repo: "Poetic-Poems/poetic", item: "pr-251-abandoned-fedcba654321", pr: 251,
    evidence: {ref: "main", path: "FLAG-EXISTS.md", expect: "present"},
    cycle: "'"$CYCLE_OLD"'", node: "node-2", ts: $ts}')"
out="$(void_guard_reason "$entry_250" '[]' "$(ctx_agent_merges_all "[$flag_wrong_item]")")"; rc=$?
assert_eq "a flag naming a different item does not corroborate" "1" "$rc"
assert_contains "  ... refused on the ordinary diff test" "still changes 3 file(s)" "$out"

# The `-review-` shape is read exactly the same way as `-abandoned-`.
flag_valid_review="$(jq -nc --arg ts "$(ts_before 90000)" \
  '{repo: "Poetic-Poems/poetic", item: "pr-252-review-1234567890", pr: 252,
    evidence: {ref: "main", path: "FLAG-EXISTS.md", expect: "present"},
    cycle: "'"$CYCLE_OLD"'", node: "node-2", ts: $ts}')"
printf '{"state": "open"}' >"$tmp_dir/pr-252.json"
printf '1' >"$tmp_dir/files-252"
entry_252="$(jq -nc \
  '{item: "pr-252-review-1234567890", repo: "Poetic-Poems/poetic",
    reason: "an independent, later Enabler engagement confirms this draft is unwanted",
    evidence: {ref: "main", path: "FLAG-EXISTS.md", expect: "present"}}')"
assert_eq "the review-feedback shape corroborates on a valid flag exactly the same way" \
  "0" "$(void_guard_reason "$entry_252" '[]' "$(ctx_agent_merges_all "[$flag_valid_review]")"; echo $?)"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
