#!/usr/bin/env bash
#
# scripts/sweep-orphan-branches.sh — find claim branches whose work became
# invisible, and put it back in front of the pipeline (requirement 17b).
#
# The orphan this hunts: an Implementor pushes commits to its claim branch and
# dies before the draft pull request exists. Nothing recovers it —
# `gather-abandoned-drafts.sh` lists PRs, not branches — and nothing can even
# reach it again: the claim gc keeps a moved ref on purpose (pushed work is
# never deleted), every later `claim branch` 422s against it, and the
# Co-Ordinator's own exclusion reads the live ref as "claimed, skip". The work
# is unreachable, the item is permanently unselectable, and no event ever said
# so. The near-miss sibling is the ref with *no* work on it whose registry
# entry was lost (a best-effort write that never landed), wedging its item the
# same way with nothing to recover at all.
#
# For one repository, this sweeps every `td/*` and `<branch_prefix>*` ref and,
# for each one that is provably an orphan — **no open PR** uses it, **no
# registry entry** stands for it, and its tip commit is **older than
# `abandoned_draft_after_hours`** (the same judgement that makes a draft
# abandoned) — does the one thing that makes the state self-healing:
#
#   commits ahead of the default branch   open a DRAFT pull request from the
#                                         ref, labelled `pr_label`, so the
#                                         existing abandoned-drafts machinery
#                                         recovers the work exactly as it
#                                         recovers any other stalled draft
#   nothing ahead                         delete the ref, which is all a claim
#                                         at the base SHA ever was
#
# Fail-closed everywhere: any answer this script cannot get (a PR list that
# errors, a registry read that fails with anything but 404, an undatable tip)
# skips that branch with a `warning` action rather than touching it. Two nodes
# sweeping at once is safe by the same shape claim.sh relies on: GitHub
# rejects a second open PR for the same head, and a second ref delete is a
# no-op.
#
# Output: one JSON object per action on stdout —
#   {"action":"recovered","branch":…,"pr_url":…,"ahead_by":…}
#   {"action":"released","branch":…}
#   {"action":"deferred","remaining":N}     (the per-run cap, so a pathological
#                                            backlog surfaces over several
#                                            cycles instead of as a PR flood)
#   {"action":"warning","branch":…,"detail":…}
# The caller logs them; this script logs nothing itself. Exit 0 unless the
# arguments are unusable.
#
# Usage: sweep-orphan-branches.sh <owner/repo>
# Environment: SWEEP_GH overrides `gh` (tests stub it); AGENT_OPS_CONFIG
# overrides the config path, as review-cycle.sh accepts it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
GH="${SWEEP_GH:-gh}"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "usage: sweep-orphan-branches.sh <owner/repo>" >&2
  exit 64
fi

cfg() { jq -r "$1" "$CONFIG_FILE" 2>/dev/null; }

branch_prefix="$(cfg '.branch_prefix // "agent/"')"
pr_label="$(cfg '.pr_label // ""')"
stale_hours="$(cfg '.abandoned_draft_after_hours // 3')"
state_repo="$(cfg '.state_repo // ""')"
[[ "$state_repo" == "null" ]] && state_repo=""
[[ "$stale_hours" =~ ^[0-9]+$ ]] || stale_hours=3

# The per-run action cap. Deliberate and small: an orphan has already waited
# hours, so surfacing a backlog three at a time over consecutive cycles costs
# little — and a bug that suddenly minted fifty "orphans" costs fifty PRs
# without it.
max_actions=3

san() { local s="$1"; printf '%s' "${s//\//__}"; }



warn() {  # warn BRANCH DETAIL
  jq -nc --arg b "$1" --arg d "$2" '{action: "warning", branch: $b, detail: $d}'
}

default_branch="$("$GH" api "repos/$slug" --jq '.default_branch' 2>/dev/null)" || default_branch=""
if [[ -z "$default_branch" ]]; then
  warn "" "could not read $slug's default branch — sweeping nothing"
  exit 0
fi

now_epoch="$(date +%s)"
actions=0
deferred=0

sweep_branch() {  # <branch> <tip-sha>
  local branch="$1" sha="$2"
  local prs registry_err tip_date tip_epoch ahead pr_out pr_url body_file
  local -a label_args=()

  [[ "$branch" == "$default_branch" ]] && return 0

  # An open PR means the ordinary machinery already owns this ref.
  prs="$("$GH" pr list -R "$slug" --head "$branch" --state open \
          --json number --jq 'length' 2>/dev/null)" || prs=""
  if [[ -z "$prs" ]]; then
    warn "$branch" "could not list PRs — leaving it alone"
    return 0
  fi
  [[ "$prs" == "0" ]] || return 0

  # A registry entry means a live claim (until the gc retires it). Only a
  # clean 404 proves absence; any other failure is an unanswered question,
  # and an unanswered question never justifies touching a ref.
  if [[ -n "$state_repo" ]]; then
    registry_err="$("$GH" api \
      "repos/$state_repo/contents/claims/$(san "$slug")/$(san "$branch").json" \
      2>&1 >/dev/null)" && return 0
    if [[ "$registry_err" != *"HTTP 404"* ]]; then
      warn "$branch" "registry read failed with something other than 404 — leaving it alone"
      return 0
    fi
  fi

  # The same staleness judgement that makes a draft abandoned. A moved ref's
  # tip is the dead agent's last push; an unmoved ref's tip is the default
  # branch's own head at claim time — either way, younger than the threshold
  # means someone may still be working, so wait.
  tip_date="$("$GH" api "repos/$slug/commits/$sha" \
    --jq '.commit.committer.date' 2>/dev/null)" || tip_date=""
  tip_epoch="$(date -d "$tip_date" +%s 2>/dev/null || echo 0)"
  if (( tip_epoch == 0 )); then
    warn "$branch" "could not date the tip commit — leaving it alone"
    return 0
  fi
  (( now_epoch - tip_epoch >= stale_hours * 3600 )) || return 0

  if (( actions >= max_actions )); then
    deferred=$(( deferred + 1 ))
    return 0
  fi

  ahead="$("$GH" api "repos/$slug/compare/$default_branch...$branch" \
    --jq '.ahead_by' 2>/dev/null)" || ahead=""
  if ! [[ "$ahead" =~ ^[0-9]+$ ]]; then
    warn "$branch" "could not compare against $default_branch — leaving it alone"
    return 0
  fi

  if (( ahead == 0 )); then
    # Nothing ahead: the ref is all the claim ever was, and the claim is dead.
    if "$GH" api -X DELETE "repos/$slug/git/refs/heads/$branch" >/dev/null 2>&1; then
      jq -nc --arg b "$branch" '{action: "released", branch: $b}'
      actions=$(( actions + 1 ))
    else
      warn "$branch" "could not delete the empty orphan ref"
    fi
    return 0
  fi

  body_file="$(mktemp)"
  cat > "$body_file" <<ORPHAN_BODY
The pipeline pushed commits to \`$branch\` but its cycle died before a pull
request existed, leaving the work invisible: nothing recovers a branch with no
PR, and the live claim ref blocks every later attempt at the same item
(IMPLEMENTATION-PIPELINE-SPEC requirement 17b).

This draft makes the work visible to the abandoned-drafts source again. Its
Implementor should read \`gh pr diff\` and the commit messages here, continue
from what already exists rather than starting the item over, and open the
result for review as usual.

---
Filed automatically by scripts/sweep-orphan-branches.sh.
ORPHAN_BODY

  # The label is what the abandoned-drafts gatherer keys on; a repo missing
  # the label must still get its work back, so retry bare — and say so, since
  # a PR without the label is one the gatherer cannot see.
  [[ -n "$pr_label" ]] && label_args=(--label "$pr_label")
  pr_out="$("$GH" pr create -R "$slug" --draft \
    --head "$branch" --base "$default_branch" \
    --title "chore(recover): resume orphaned branch $branch" \
    --body-file "$body_file" \
    "${label_args[@]}" 2>/dev/null)" || pr_out=""
  if [[ -z "$pr_out" && -n "$pr_label" ]]; then
    pr_out="$("$GH" pr create -R "$slug" --draft \
      --head "$branch" --base "$default_branch" \
      --title "chore(recover): resume orphaned branch $branch" \
      --body-file "$body_file" 2>/dev/null)" || pr_out=""
    [[ -n "$pr_out" ]] && warn "$branch" \
      "recovered without the $pr_label label — the abandoned-drafts source cannot see it until someone adds the label"
  fi
  rm -f "$body_file"

  pr_url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/pull/[0-9]+' <<<"$pr_out" | tail -n1 || true)"
  if [[ -z "$pr_url" ]]; then
    warn "$branch" "could not open a recovery draft PR"
    return 0
  fi
  jq -nc --arg b "$branch" --arg u "$pr_url" --argjson a "$ahead" \
    '{action: "recovered", branch: $b, pr_url: $u, ahead_by: $a}'
  actions=$(( actions + 1 ))
  return 0
}

# Both claim namespaces, prefix-listed server-side. A failed listing is an
# unanswered question about the whole namespace: warn and move on.
for prefix in "td/" "$branch_prefix"; do
  [[ -n "$prefix" ]] || continue
  refs="$("$GH" api "repos/$slug/git/matching-refs/heads/$prefix" \
    --jq '.[] | [(.ref | sub("^refs/heads/"; "")), .object.sha] | @tsv' 2>/dev/null)" || {
    warn "" "could not list $prefix refs — skipping that namespace this pass"
    continue
  }
  while IFS=$'\t' read -r branch sha; do
    [[ -n "$branch" && -n "$sha" ]] || continue
    sweep_branch "$branch" "$sha"
  done <<<"$refs"
done

if (( deferred > 0 )); then
  jq -nc --argjson n "$deferred" '{action: "deferred", remaining: $n}'
fi

exit 0
