#!/usr/bin/env bash
#
# test/merge-conflicts.test.sh — regression test for the candidate rule of
# scripts/gather-merge-conflicts.sh (requirement 3g) and the back-pressure
# narrowing it shares with review-feedback and abandoned-drafts (requirement 2.2a).
#
# The rule decides which of *our own* ready PRs are conflicted and safe to rebase,
# and it has two dangerous directions:
#   - too eager, and it force-pushes a rebase onto a PR that does not really
#     conflict (mergeability is computed asynchronously, so a PR whose base just
#     moved reads `UNKNOWN` for a beat), or onto a human's branch;
#   - too shy, and a genuinely conflicted PR a human is waiting to merge sits
#     forever occupying a back-pressure slot while every cycle looks healthy.
# The `CONFLICTING`-not-`UNKNOWN` gate and the non-draft/ours-by-branch filters are
# what hold the line; they are asserted here as jq over the same shapes the GitHub
# API returns. Keep this in step with the filters in the script.
#
# The `bot` half of the rule (requirement 3s, issue #250 — Dependabot's own
# conflicted PRs, `rebase_requested` and `superseded_by`) is exercised for real,
# through MERGE_CONFLICTS_GH, further down: unlike the ours-by-label filter
# above, its logic (lib/dependabot-bump.sh, comment-marker scanning) is enough
# to be worth invoking the actual script against a stub rather than
# re-replicating it in jq a second time.
#
# Further down still: agent-cycle.sh's own `gather_merge_conflicts` wrapper,
# lifted straight out of the script (as test/stage-salvage.test.sh already
# does for its own functions), pinning that its nudge-failure fallback drops a
# never-nudged bot candidate exactly as scripts/nudge-dependabot-rebase.sh
# itself would — the third leg of requirement 3s's defence in depth, alongside
# the write-side drop and prompts/coordinator.md's explicit fourth case.
#
# Run directly:
#
#   ./test/merge-conflicts.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# --- The candidate filter: which ready PRs are ours to rebase? ---

# The shape `gh pr list --json number,title,headRefName,baseRefName,commits,isDraft,mergeable,updatedAt,url,body`
# returns (the `--label` filter is applied by gh, so every row here already
# carries pr_label). One of each kind we must accept or reject. A PR is a
# candidate when it is open, *not* a draft, `mergeable` is exactly `CONFLICTING`,
# and its head is on a branch we own.
prs='[
  {"number": 90, "isDraft": false, "mergeable": "CONFLICTING", "headRefName": "agent/td1-fix"},
  {"number": 91, "isDraft": true,  "mergeable": "CONFLICTING", "headRefName": "agent/td2-fix"},
  {"number": 92, "isDraft": false, "mergeable": "MERGEABLE",   "headRefName": "agent/td3-fix"},
  {"number": 93, "isDraft": false, "mergeable": "UNKNOWN",     "headRefName": "agent/td4-fix"},
  {"number": 94, "isDraft": false, "mergeable": "CONFLICTING", "headRefName": "feature/a-humans-branch"},
  {"number": 95, "isDraft": false, "mergeable": "CONFLICTING", "headRefName": "td/TD26072001"}
]'

candidate_filter() {
  jq -c '[.[] | select(.isDraft | not)
              | select(.mergeable == "CONFLICTING")
              | select((.headRefName | startswith("agent/"))
                       or (.headRefName | startswith("td/")))
              | .number]' <<<"$prs"
}

assert_eq "only open, non-draft, CONFLICTING, ours-by-branch PRs are candidates" \
  "[90,95]" "$(candidate_filter)"

# Each exclusion, named, so a future edit that drops one fails loudly:
# - #91 draft: a draft is the Implementor's own claim marker; a draft's conflict
#   is abandoned-drafts' to resolve once the draft goes stale, never here.
# - #92 mergeable: no conflict — nothing to do. Rebasing it would be churn.
# - #93 UNKNOWN: mergeability is computed asynchronously, so a PR whose base just
#   moved reads UNKNOWN for a beat. Treating that as a conflict would send the
#   Implementor to rebase a PR that may not conflict. This is the assertion that
#   keeps the feature from acting on a guess.
# - #94 human branch: only branches under agent/ (or the tech-debt td/ claim
#   branch) are ours; the Human Gate reserves the rest — force-pushing a rebase
#   onto a human's PR would breach it.
assert_eq "a draft PR is never a merge-conflicts candidate" \
  "0" "$(jq '[.[] | select(.number == 91) | select(.isDraft | not)] | length' <<<"$prs")"
assert_eq "a mergeable PR is never a merge-conflicts candidate" \
  "0" "$(jq '[.[] | select(.number == 92) | select(.mergeable == "CONFLICTING")] | length' <<<"$prs")"
assert_eq "an UNKNOWN-mergeability PR is not a candidate — never rebase on a guess" \
  "0" "$(jq '[.[] | select(.number == 93) | select(.mergeable == "CONFLICTING")] | length' <<<"$prs")"
assert_eq "a human's own branch is never ours to rebase" \
  "0" "$(jq '[.[] | select(.number == 94) | select((.headRefName | startswith("agent/")) or (.headRefName | startswith("td/")))] | length' <<<"$prs")"
assert_eq "a tech-debt td/ claim branch counts as ours" \
  "1" "$(jq '[.[] | select(.number == 95) | select(.headRefName | startswith("td/"))] | length' <<<"$prs")"

# --- The ref: scoped to the head SHA ---
#
# `pr-<n>-conflict-<head-sha[:12]>`, not `pr-<n>-conflict`. An item recorded
# blocked (requirement 34) stays blocked until something clears it, so a bare
# `pr-90-conflict` that an Implementor once failed to resolve would still be
# blocked after fresh commits landed — and the new, possibly-resolvable state
# would never be looked at again. Scoping to the head means each distinct
# conflicted state is its own item that no older block covers, while a resolution
# (which moves the head) retires the ref and a conflict re-detected at the same
# head keeps it. Same reasoning as abandoned-drafts' per-head refs.
ref_of() { jq -r '"pr-\(.number)-conflict-\(.head_sha[0:12])"' <<<"$1"; }
assert_eq "the ref pins to the PR number and the head SHA's first 12 chars" \
  "pr-90-conflict-1a2b3c4d5e6f" \
  "$(ref_of '{"number": 90, "head_sha": "1a2b3c4d5e6f7a8b9c0d"}')"
assert_eq "a new head after a resolution yields a different ref, so an old block cannot cover it" \
  "pr-90-conflict-ffffffffffff" \
  "$(ref_of '{"number": 90, "head_sha": "ffffffffffffaaaa1111"}')"

# --- Back-pressure narrowing (requirement 2.2a) ---
#
# When back-pressure trips, the cycle narrows to the three *finishing* sources
# rather than standing down, so a gate full of stalled work can still be cleared.
# Tested here rather than live because reaching the branch needs
# max_open_agent_prs exceeded *and* a finishing candidate waiting at the same
# moment — the exact state nobody wants to be discovering the behaviour of.
ordered='[
  {"slug": "o/one", "sources": ["security", "review-feedback", "merge-conflicts", "abandoned-drafts", "tech-debt"], "review_feedback": [], "merge_conflicts": [{"ref": "pr-90-conflict-1a2b3c4d5e6f"}], "abandoned_drafts": []},
  {"slug": "o/two", "sources": ["security", "review-feedback", "merge-conflicts", "abandoned-drafts", "issues"], "review_feedback": [], "merge_conflicts": [], "abandoned_drafts": []}
]'
restrict() { jq -c '[.[] | .sources = (.sources | map(select(. == "review-feedback" or . == "merge-conflicts" or . == "abandoned-drafts")))]' <<<"$ordered"; }

assert_eq "restriction leaves only the three finishing sources selectable" \
  '["review-feedback","merge-conflicts","abandoned-drafts"] ["review-feedback","merge-conflicts","abandoned-drafts"]' \
  "$(restrict | jq -r '[.[] | (.sources | tojson)] | join(" ")')"
assert_eq "security and fresh sources are narrowed away — a full gate means finish, don't start" \
  "0" "$(restrict | jq '[.[].sources[] | select(. == "security" or . == "tech-debt" or . == "issues")] | length')"

# The count that decides stand-down vs restrict: all three finishing sources,
# across all repos.
assert_eq "finishing candidates count review-feedback, merge-conflicts AND abandoned-drafts across all repos" \
  "1" "$(jq '[.[].review_feedback[]?, .[].merge_conflicts[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"
assert_eq "with nothing waiting to finish, the count is 0 and the cycle stands down as before" \
  "0" "$(jq '[.[] | .review_feedback = [] | .merge_conflicts = [] | .abandoned_drafts = []] | [.[].review_feedback[]?, .[].merge_conflicts[]?, .[].abandoned_drafts[]?] | length' <<<"$ordered")"

# --- Dependabot candidates: exercised through the real script via a stub gh ---
#
# requirement 3s (issue #250): a Dependabot-authored, open, non-draft,
# CONFLICTING PR is a candidate regardless of label or branch prefix — it is
# never ours by either signal — and carries `bot: true` plus two fields the
# `ours` candidates above never carry: `rebase_requested` (a marker comment
# already on the PR, scoped to this exact head) and `superseded_by` (a newer
# open Dependabot PR bumping the same dependency).
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1 $2" == "pr list" ]]; then
  for a in "$@"; do
    if [[ "$a" == "--label" ]]; then cat "$d/ours.json"; exit 0; fi
    if [[ "$a" == "--author" ]]; then cat "$d/dependabot.json"; exit 0; fi
  done
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"

printf '[]\n' > "$tmp_dir/ours.json"

# One conflicted bot PR, never nudged yet, and a newer open bump of the same
# dependency (no comments at all — the `--label` call above never fetches
# `comments`, so `ours` candidates are unaffected either way).
cat > "$tmp_dir/dependabot.json" <<'JSON'
[
  {"number": 129, "title": "chore(deps-dev): Bump eslint from 9.39.5 to 10.8.0",
   "headRefName": "dependabot/npm_and_yarn/eslint-10.8.0", "baseRefName": "main",
   "commits": [{"oid": "c96c8ef9d31a8928b39d963f1de3b92dbea256c4"}],
   "isDraft": false, "mergeable": "CONFLICTING", "updatedAt": "2026-08-03T00:48:14Z",
   "url": "https://github.com/o/r/pull/129", "body": "Bumps eslint from 9.39.5 to 10.8.0.",
   "comments": []},
  {"number": 135, "title": "chore(deps-dev): Bump eslint from 9.39.5 to 10.9.0",
   "headRefName": "dependabot/npm_and_yarn/eslint-10.9.0", "baseRefName": "main",
   "commits": [{"oid": "deadbeefcafebabe0000000000000000000000"}],
   "isDraft": false, "mergeable": "MERGEABLE", "updatedAt": "2026-08-05T00:00:00Z",
   "url": "https://github.com/o/r/pull/135", "body": "Bumps eslint from 9.39.5 to 10.9.0.",
   "comments": []},
  {"number": 170, "title": "chore(ci): bump codeql-action",
   "headRefName": "dependabot/github_actions/github/codeql-action-4.37.3", "baseRefName": "main",
   "commits": [{"oid": "1111111111111111111111111111111111111"}],
   "isDraft": false, "mergeable": "UNKNOWN", "updatedAt": "2026-08-01T00:00:00Z",
   "url": "https://github.com/o/r/pull/170", "body": "", "comments": []}
]
JSON

out="$(MERGE_CONFLICTS_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-merge-conflicts.sh" o/r autonomous-agent agent/ 2>/dev/null)"
assert_eq "only the CONFLICTING bot PR is a candidate (#135 MERGEABLE, #170 UNKNOWN are not)" \
  "1" "$(jq 'length' <<<"$out")"
assert_eq "  ... marked as a bot candidate" "true" "$(jq -r '.[0].bot' <<<"$out")"
assert_eq "  ... never yet asked to rebase (no marker comment)" \
  "false" "$(jq -r '.[0].rebase_requested' <<<"$out")"
assert_eq "  ... superseded by #135, the newer open bump of the same dependency" \
  "135" "$(jq -r '.[0].superseded_by' <<<"$out")"
assert_contains_json() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}
assert_contains_json "  ... the pre-formatted evidence cites this PR's own number, not #135's, as 'PR #N'" \
  "PR #129" "$(jq -r '.[0].superseded_evidence' <<<"$out")"
assert_eq "  ... and never writes '#135' with a PR/pull-request prefix (would fail void-guard corroboration)" \
  "0" "$(jq -r '.[0].superseded_evidence' <<<"$out" | grep -ciE '(pr|pull request)[[:space:]]*#135' || true)"

# --- A marker comment scoped to the current head makes it rebase_requested ---
cat > "$tmp_dir/dependabot.json" <<'JSON'
[
  {"number": 129, "title": "chore(deps-dev): Bump eslint from 9.39.5 to 10.8.0",
   "headRefName": "dependabot/npm_and_yarn/eslint-10.8.0", "baseRefName": "main",
   "commits": [{"oid": "c96c8ef9d31a8928b39d963f1de3b92dbea256c4"}],
   "isDraft": false, "mergeable": "CONFLICTING", "updatedAt": "2026-08-03T00:48:14Z",
   "url": "https://github.com/o/r/pull/129", "body": "Bumps eslint from 9.39.5 to 10.8.0.",
   "comments": [{"body": "@dependabot rebase\n\n<!-- agent-ops:dependabot-rebase-requested head=c96c8ef9d31a -->"}]}
]
JSON
out="$(MERGE_CONFLICTS_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-merge-conflicts.sh" o/r autonomous-agent agent/ 2>/dev/null)"
assert_eq "a marker comment scoped to the current head sets rebase_requested" \
  "true" "$(jq -r '.[0].rebase_requested' <<<"$out")"
assert_eq "  ... and with no competing bump this time, it is not superseded" \
  "null" "$(jq -r '.[0].superseded_by' <<<"$out")"

# --- A marker scoped to a DIFFERENT (stale) head does not count ---
cat > "$tmp_dir/dependabot.json" <<'JSON'
[
  {"number": 129, "title": "chore(deps-dev): Bump eslint from 9.39.5 to 10.8.0",
   "headRefName": "dependabot/npm_and_yarn/eslint-10.8.0", "baseRefName": "main",
   "commits": [{"oid": "c96c8ef9d31a8928b39d963f1de3b92dbea256c4"}],
   "isDraft": false, "mergeable": "CONFLICTING", "updatedAt": "2026-08-03T00:48:14Z",
   "url": "https://github.com/o/r/pull/129", "body": "Bumps eslint from 9.39.5 to 10.8.0.",
   "comments": [{"body": "@dependabot rebase\n\n<!-- agent-ops:dependabot-rebase-requested head=000000000000 -->"}]}
]
JSON
out="$(MERGE_CONFLICTS_GH="$tmp_dir/gh" "$SCRIPT_DIR/scripts/gather-merge-conflicts.sh" o/r autonomous-agent agent/ 2>/dev/null)"
assert_eq "a marker scoped to a stale head does not satisfy rebase_requested for the current one" \
  "false" "$(jq -r '.[0].rebase_requested' <<<"$out")"

rm -rf "$tmp_dir"
trap - EXIT

# --- The gatherer itself fails safe ---

assert_eq "an unknown repo yields [] and exit 0, never a broken cycle" "[]" \
  "$("$SCRIPT_DIR/scripts/gather-merge-conflicts.sh" "Poetic-Poems/does-not-exist" autonomous-agent 'agent/' 2>/dev/null)"
assert_eq "  ... and exits 0" "0" "$?"

# --- agent-cycle.sh's gather_merge_conflicts: the nudge-failure fallback still
#     drops a never-nudged bot candidate (requirement 3s) ---
#
# When nudge-dependabot-rebase.sh itself fails to produce a usable result,
# gather_merge_conflicts falls back to the gatherer's own array rather than
# losing every candidate in the repo over one broken write step. That fallback
# must apply the same drop the nudge step itself would have: a `bot: true`,
# `rebase_requested: false`, no-`superseded_by` entry is never selectable, and
# letting one through here would land it in prompts/coordinator.md's
# ordinary-case catch-all, which force-pushes onto a branch Dependabot owns.
lift_bash_fn() {
  awk -v name="$2" '
    $0 == name "() {" { on = 1 }
    on               { print }
    on && /^\}$/      { exit }
  ' "$1"
}
gather_fn="$(lift_bash_fn "$SCRIPT_DIR/agent-cycle.sh" gather_merge_conflicts)"
if [[ -z "$gather_fn" ]]; then
  echo "FAIL - could not lift gather_merge_conflicts from agent-cycle.sh"
  failures=$(( failures + 1 ))
else
  fallback_tmp="$(mktemp -d)"
  mkdir -p "$fallback_tmp/scripts" "$fallback_tmp/cycle"

  cat > "$fallback_tmp/scripts/gather-merge-conflicts.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' '[
  {"ref": "pr-129-conflict-aaa", "number": 129, "bot": true, "rebase_requested": false, "superseded_by": null},
  {"ref": "pr-57-conflict-bbb", "number": 57, "bot": false}
]'
STUB
  chmod +x "$fallback_tmp/scripts/gather-merge-conflicts.sh"

  # The nudge step fails outright — the exact condition the fallback exists for.
  cat > "$fallback_tmp/scripts/nudge-dependabot-rebase.sh" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
exit 1
STUB
  chmod +x "$fallback_tmp/scripts/nudge-dependabot-rebase.sh"

  log_capture="$fallback_tmp/log_event.calls"
  out="$(bash -c "
    $gather_fn
    SCRIPT_DIR='$fallback_tmp'
    cycle_dir='$fallback_tmp/cycle'
    pr_label=autonomous-agent
    branch_prefix=agent/
    cycle_id=test-cycle
    node_name=test-node
    DRY_RUN=0
    log_event() { printf '%s\t%s\n' \"\$1\" \"\${2:-}\" >> '$log_capture'; }
    gather_merge_conflicts o/r
  ")"

  assert_eq "the fallback drops the never-nudged bot candidate, keeping the ordinary one" \
    '["pr-57-conflict-bbb"]' "$(jq -c '[.[].ref]' <<<"$out")"
  assert_eq "  ... and the fingerprint file on disk reflects the same filtered array" \
    '["pr-57-conflict-bbb"]' "$(jq -c '[.[].ref]' "$fallback_tmp/cycle/merge-conflicts-o_r.json")"
  assert_eq "  ... and a wholly-broken nudge step is logged as a warning, not silent" \
    "1" "$(grep -c '^warning	' "$log_capture" || true)"

  rm -rf "$fallback_tmp"
fi

# --- ...and that fallback's own filter degrades rather than aborting the
#     cycle when the gatherer's output is array-shaped but its elements are
#     not objects (requirement 3s) ---
#
# `out` is only validated as `type == "array"` before the nudge step runs;
# `.bot` on a non-object element is a `jq` error, which a bare assignment
# under `set -euo pipefail` (agent-cycle.sh's own mode) would let abort the
# whole cycle. This can only be reached on the already-broken-nudge-step path
# above, so it is exercised the same way, with the gatherer stub returning a
# malformed array instead.
if [[ -z "$gather_fn" ]]; then
  echo "FAIL - could not lift gather_merge_conflicts from agent-cycle.sh"
  failures=$(( failures + 1 ))
else
  malformed_tmp="$(mktemp -d)"
  mkdir -p "$malformed_tmp/scripts" "$malformed_tmp/cycle"

  cat > "$malformed_tmp/scripts/gather-merge-conflicts.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s' '["not-an-object"]'
STUB
  chmod +x "$malformed_tmp/scripts/gather-merge-conflicts.sh"

  cat > "$malformed_tmp/scripts/nudge-dependabot-rebase.sh" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
exit 1
STUB
  chmod +x "$malformed_tmp/scripts/nudge-dependabot-rebase.sh"

  log_capture="$malformed_tmp/log_event.calls"
  out="$(bash -c "
    set -euo pipefail
    $gather_fn
    SCRIPT_DIR='$malformed_tmp'
    cycle_dir='$malformed_tmp/cycle'
    pr_label=autonomous-agent
    branch_prefix=agent/
    cycle_id=test-cycle
    node_name=test-node
    DRY_RUN=0
    log_event() { printf '%s\t%s\n' \"\$1\" \"\${2:-}\" >> '$log_capture'; }
    gather_merge_conflicts o/r
  ")"
  exit_status=$?

  assert_eq "a malformed-but-array gatherer output does not abort the cycle" "0" "$exit_status"
  assert_eq "  ... and yields [] rather than a half-filtered guess" "[]" "$out"
  assert_eq "  ... and the fingerprint file on disk agrees" \
    "[]" "$(jq -c '.' "$malformed_tmp/cycle/merge-conflicts-o_r.json")"
  assert_eq "  ... and both the broken-nudge-step and the filter failure are logged" \
    "2" "$(grep -c '^warning	' "$log_capture" || true)"

  rm -rf "$malformed_tmp"
fi

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
