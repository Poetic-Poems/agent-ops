#!/usr/bin/env bash
#
# scripts/release-td-branch.sh — delete a tech-debt reservation branch the
# moment its record lands on main (agent-ops#631).
#
# scripts/reserve-tech-debt-id.pl locks an id by pushing a throwaway commit to
# td/<id>; "Claiming an item" (TECH-DEBT.md) reuses that same branch to do the
# actual work, so GitHub's own delete-branch-on-merge setting retires it once
# that pull request lands. "Filing alongside other work" (TECH-DEBT.md) never
# touches td/<id> again after the reservation — the filing commit lands on
# whatever branch the filing stage already held — so nothing ever merges
# td/<id> and nothing deletes it. scripts/sweep-orphan-branches.sh already
# knows about this shape and deliberately leaves it alone (issue #545): a
# td/<id> branch whose sole commit ahead is the reservation itself is the
# lock, not orphaned work, and that sweep cannot tell whether <id> has since
# been filed elsewhere without reading the whole register on every pass. This
# script is the other half: triggered by the one event that actually answers
# that question — a push to main that adds a new tech-debt/<id>.md — so the
# two never race and neither has to guess.
#
# Usage: release-td-branch.sh <repo-slug> <before-sha> <after-sha>
#
# Diffs before..after for tech-debt/*.md files *added* by this push (never
# renamed or deleted — the register is append-only and CI already enforces
# that), extracts each new file's id from its own name, and best-effort
# deletes refs/heads/td/<id> on origin if it still exists. A branch that is
# already gone (the common case: the item was claimed and worked on td/<id>
# itself, and GitHub's own merge cleanup already retired it) is not an error.
# Requires GH_TOKEN (or gh's own login) with contents:write on <repo-slug>.
#
# Emits one JSON object per new record found, on stdout:
#   {"id":"TD-...","branch":"td/TD-...","action":"deleted"}
#   {"id":"TD-...","branch":"td/TD-...","action":"absent"}
#   {"id":"TD-...","branch":"td/TD-...","action":"warning","detail":"..."}
# Always exits 0 — a branch this script fails to delete is not a broken push
# to main; scripts/sweep-orphan-branches.sh's own periodic pass, and the
# "Filing an item" workflow's manual fallback, are both still there behind it.

set -euo pipefail

GH="${GH:-gh}"

usage() {
  echo "usage: $(basename "$0") <repo-slug> <before-sha> <after-sha>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
slug="$1" before="$2" after="$3"
[[ -n "$slug" && -n "$before" && -n "$after" ]] || usage

# A force-push or a first-ever push reports an all-zero "before" SHA; there is
# no prior state to diff against, so there is nothing this run can safely
# attribute to one push. Warn and stop rather than diffing against a ref that
# does not exist — the next ordinary push still catches whatever this one
# would have.
if [[ "$before" =~ ^0+$ ]]; then
  echo "release-td-branch: before-sha is all-zero (force-push or new branch) — nothing to diff, skipping" >&2
  exit 0
fi

# Piped through a local `jq -r` rather than `gh api --jq`, deliberately: a
# jq filter over `.filename` (a string) risks JSON-quoted output rather than
# raw text depending on how the caller's own `--jq` flag behaves, and this
# script's own regex match below must see the raw path either way.
added="$("$GH" api "repos/$slug/compare/$before...$after" 2>/dev/null \
  | jq -r '[.files[]? | select(.status == "added") | .filename] | .[]' 2>/dev/null || true)"

[[ -n "$added" ]] || exit 0

while IFS= read -r path; do
  [[ "$path" =~ ^tech-debt/(TD-[A-Z0-9]{2}[a-z0-9]{4}-[0-9]{6}[0-9a-z][0-9])\.md$ ]] || continue
  id="${BASH_REMATCH[1]}"
  branch="td/$id"

  if ! "$GH" api "repos/$slug/git/ref/heads/$branch" >/dev/null 2>&1; then
    jq -nc --arg id "$id" --arg branch "$branch" \
      '{id: $id, branch: $branch, action: "absent"}'
    continue
  fi

  if "$GH" api -X DELETE "repos/$slug/git/refs/heads/$branch" >/dev/null 2>&1; then
    jq -nc --arg id "$id" --arg branch "$branch" \
      '{id: $id, branch: $branch, action: "deleted"}'
  else
    jq -nc --arg id "$id" --arg branch "$branch" \
      '{id: $id, branch: $branch, action: "warning", detail: "delete failed"}'
  fi
done <<<"$added"

exit 0
