#!/usr/bin/env bash
#
# scripts/sweep-orphan-branches.sh — find claim branches whose work became
# invisible, and put it back in front of the pipeline (requirement 17b).
#
# The orphan this hunts: an Implementer pushes commits to its claim branch and
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
# For one repository, this sweeps every `<tech_debt_branch_prefix>*`,
# `<branch_prefix>*`, and `td-record/*` ref — the last unconditionally,
# never gated by `tech_debt_branch_prefix`, since `techdebt_file_debt`
# (`lib/tech-debt-file.sh`) mints a filing's record branch there regardless
# of that setting — and, for each one that is provably an orphan — **no
# open PR** uses it, **no registry entry** stands for it, and its tip commit
# is **older than `abandoned_draft_after_hours`** (the same judgement that
# makes a draft abandoned) — does the one thing that makes the state
# self-healing:
#
#   commits ahead, never merged,
#   no rival branch landed the
#   same work                             open a DRAFT pull request from the
#                                         ref, labelled `pr_label`, so the
#                                         existing abandoned-drafts machinery
#                                         recovers the work exactly as it
#                                         recovers any other stalled draft
#   nothing ahead, or ahead but already
#   merged into the default branch        delete the ref: either it was only
#                                         ever the claim, or every repo here
#                                         squash-merges, so a landed branch's
#                                         commits never leave `ahead_by`
#                                         positive and the ref is just a
#                                         leftover the claim gc didn't clean up
#   ahead, never merged, but a rival
#   branch sharing the same item ref
#   merged after this branch's first
#   commit                                delete the ref: this branch lost a
#                                         race and its work already landed
#                                         under a different head, so a
#                                         recovery draft would resurrect
#                                         superseded — sometimes regressed —
#                                         code (issue #500)
#   a `td/<ID>` branch whose sole commit
#   ahead is reserve-tech-debt-id.pl's
#   own reservation commit (its fixed
#   subject, no files touched)            touch nothing: it is the
#                                         ID-reservation scheme's atomic claim
#                                         lock, not work, whether or not <ID>
#                                         has since been filed — and, when it
#                                         has, regardless of which branch that
#                                         filing actually landed on
#                                         (issue #545)
#   a `td-record/<id>` branch whose only
#   pull request was closed without
#   merging                               delete the ref: a human declined
#                                         that filing, so a recovery draft
#                                         would hand back exactly the record
#                                         they declined — never recovered,
#                                         only deleted, for this prefix
#                                         alone; then, once the delete lands,
#                                         additionally release the paired
#                                         `td/<id>` reservation, but only if
#                                         `<id>`'s record is confirmed absent
#                                         from the default branch, since it
#                                         may have landed some other way
#                                         (TD-PPagop-26082310)
#
# Fail-closed everywhere: any answer this script cannot get (a PR list that
# errors, a registry read that fails with anything but 404, an undatable tip)
# skips that branch with a `warning` action rather than touching it, and the
# rival-branch check specifically falls back to filing the recovery draft, as
# if the check had never run, on any unreadable or ambiguous answer. Two nodes
# sweeping at once is safe by the same shape claim.sh relies on: GitHub
# rejects a second open PR for the same head, and a second ref delete is a
# no-op.
#
# Output: one JSON object per action on stdout —
#   {"action":"recovered","branch":…,"pr_url":…,"ahead_by":…}
#   {"action":"released","branch":…}
#   {"action":"released","branch":…,"reason":"superseded","superseded_by":…}
#   {"action":"released","branch":…,"reason":"filing-declined"}
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
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
GH="${SWEEP_GH:-gh}"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# TECHDEBT_RECORD_BRANCH_PREFIX (td-record/), for the third ref-walk prefix
# below — sourced rather than typed a second time so the two files can never
# drift (TD-PPagop-26082310).
# shellcheck source=lib/tech-debt-file.sh
. "$SCRIPT_DIR/lib/tech-debt-file.sh"

slug="${1:-}"
if [[ -z "$slug" ]]; then
  echo "usage: sweep-orphan-branches.sh <owner/repo>" >&2
  exit 64
fi

# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below, with no `// literal` of its own to drift from the schema's. Only
# ever invoked downstream of agent-cycle.sh's own schema gate, so a required
# key with no schema default (branch_prefix, pr_label) is guaranteed present.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

branch_prefix="$(cfg '.branch_prefix')"
tech_debt_branch_prefix="$(cfg '.tech_debt_branch_prefix')"
pr_label="$(cfg '.pr_label')"
stale_hours="$(cfg '.abandoned_draft_after_hours')"
state_repo="$(cfg '.state_repo')"
[[ "$stale_hours" =~ ^[0-9]+$ ]] || stale_hours=3

# The per-run action cap. Deliberate and small: an orphan has already waited
# hours, so surfacing a backlog three at a time over consecutive cycles costs
# little — and a bug that suddenly minted fifty "orphans" costs fifty PRs
# without it.
max_actions=3

san() { local s="$1"; printf '%s' "${s//\//__}"; }

# stem BRANCH — reduce a claim branch to its item ref, for comparing two
# branches that might carry the same work: strip the leading
# `$tech_debt_branch_prefix` or `$branch_prefix`, then drop a trailing
# 12-hex-digit random suffix if one is present (exactly twelve, no more and
# no fewer — claim.sh's own width).
stem() {
  local b="$1" p
  for p in "$tech_debt_branch_prefix" "$branch_prefix"; do
    if [[ -n "$p" && "$b" == "$p"* ]]; then
      b="${b#"$p"}"
      break
    fi
  done
  [[ "$b" =~ ^(.+)-[0-9a-f]{12}$ ]] && b="${BASH_REMATCH[1]}"
  printf '%s' "$b"
}



warn() {  # warn BRANCH DETAIL
  jq -nc --arg b "$1" --arg d "$2" '{action: "warning", branch: $b, detail: $d}'
}

# sweep_record_branch BRANCH — the td-record/ delete-only path
# (TD-PPagop-26082310): 0 if BRANCH's own closed-but-unmerged pull request
# was found and handled (the caller returns without falling through), 1 to
# fall through to the ordinary flow below — a merged PR, which the ordinary
# merged-PR check there already deletes, or none at all, a genuine
# crash-orphan the recovery draft there lands as usual. `gh pr list --state
# closed` is `states: [CLOSED, MERGED]`, exactly as GitHub's own "Closed"
# tab is, so the merged half has to be filtered out here rather than
# assumed away: only a pull request whose own `state` is `CLOSED` was
# declined, and counting a merged one as declined would report a landed
# filing as a refused one and skip the merged arm that owns it.
sweep_record_branch() {
  local branch="$1" closed id
  closed="$("$GH" pr list -R "$slug" --head "$branch" --state closed \
              --json state --jq '[.[] | select(.state == "CLOSED")] | length' \
              2>/dev/null)" || closed=""
  if [[ -z "$closed" ]]; then
    warn "$branch" "could not check for a closed pull request — leaving it alone"
    return 0
  fi
  [[ "$closed" != "0" ]] || return 1

  if "$GH" api -X DELETE "repos/$slug/git/refs/heads/$branch" >/dev/null 2>&1; then
    jq -nc --arg b "$branch" '{action: "released", branch: $b, reason: "filing-declined"}'
    actions=$(( actions + 1 ))
  else
    warn "$branch" "could not delete the declined-filing record ref"
    return 0
  fi

  id="${branch#"$TECHDEBT_RECORD_BRANCH_PREFIX"}"
  release_paired_reservation "$id"
  return 0
}

# release_paired_reservation ID — having just deleted a declined filing's
# td-record/<ID>, ask whether <ID>'s record reached the default branch some
# other way. A clean 404 proves it never did, so the id is spent with
# nothing to show for it and its td/<ID> reservation is released alongside
# it; a 200 means the record landed some other way, so
# release-td-branch.yml already owns that reservation; any other failure
# answers nothing, so — fail closed, like every guard above — it is left
# alone. Deliberately narrower than the issue #545 reservation-lock
# exemption above: this only ever runs for a td/<ID> whose td-record/<ID>
# sibling was just confirmed declined, never for a bare reservation with no
# sibling at all.
release_paired_reservation() {
  local id="$1" content_err
  content_err="$("$GH" api "repos/$slug/contents/tech-debt/$id.md?ref=$default_branch" \
    2>&1 >/dev/null)" && return 0
  if [[ "$content_err" != *"HTTP 404"* ]]; then
    warn "td/$id" "could not confirm tech-debt/$id.md's absence from $default_branch — leaving the paired reservation alone"
    return 0
  fi
  if "$GH" api -X DELETE "repos/$slug/git/refs/heads/td/$id" >/dev/null 2>&1; then
    jq -nc --arg b "td/$id" '{action: "released", branch: $b}'
    actions=$(( actions + 1 ))
  else
    warn "td/$id" "could not delete the reservation paired with a declined filing"
  fi
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
  local prs merged registry_err tip_date tip_epoch compare_json ahead
  local pr_out pr_url body_file
  local my_stem first_commit_date first_commit_epoch rivals rival_lookup_failed
  local rival_ref rival_merged_at rival_url rival_merged_epoch superseded_by
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

  # td-record/ is delete-only — never recovered (TD-PPagop-26082310): check
  # this before anything the generic flow below needs (ahead_by, the
  # merged-PR list), since a declined filing is answered by its own
  # closed-but-unmerged PR alone.
  if [[ "$branch" == "${TECHDEBT_RECORD_BRANCH_PREFIX}"* ]]; then
    sweep_record_branch "$branch" && return 0
  fi

  # The full payload, not just `.ahead_by`: the superseded-branch check below
  # reuses this same call for the branch's first commit date rather than
  # asking GitHub twice.
  compare_json="$("$GH" api "repos/$slug/compare/$default_branch...$branch" \
    2>/dev/null)" || compare_json=""
  ahead="$(jq -r '.ahead_by // empty' <<<"$compare_json" 2>/dev/null)"
  if ! [[ "$ahead" =~ ^[0-9]+$ ]]; then
    warn "$branch" "could not compare against $default_branch — leaving it alone"
    return 0
  fi

  # reserve-tech-debt-id.pl's own reservation commit: a `td/<ID>` branch
  # whose sole commit ahead carries that script's fixed subject and touches
  # no files is the ID-reservation scheme's atomic claim lock, not work,
  # whether or not `<ID>` has since been filed — and, when it has, whether
  # the filing landed on this branch or, as usually happens, on whichever
  # branch the containing item's own work actually shipped from. The lock's
  # own commit shape says all of that without needing a lookup into either
  # (issue #545). Leave it exactly as found: neither recovered nor deleted.
  if [[ -n "$tech_debt_branch_prefix" && "$branch" == "$tech_debt_branch_prefix"* && "$ahead" == "1" ]]; then
    local reservation_id reservation_message reservation_subject reservation_files
    reservation_id="${branch#"$tech_debt_branch_prefix"}"
    reservation_message="$(jq -r '.commits[0].commit.message // empty' <<<"$compare_json" 2>/dev/null)"
    reservation_subject="${reservation_message%%$'\n'*}"
    reservation_files="$(jq -r '(.files // []) | length' <<<"$compare_json" 2>/dev/null)"
    if [[ "$reservation_subject" == "chore(tech-debt): reserve $reservation_id" \
          && "$reservation_files" == "0" ]]; then
      return 0
    fi
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

  # Every repo in the fleet squash-merges, so a merged branch's commits never
  # enter the default branch's history — `ahead_by` stays positive forever
  # for a branch that landed and was simply never deleted. Ask GitHub whether
  # this head was ever merged before trusting `ahead_by` as proof of
  # unrecovered work; a merged PR means the ref is a leftover the claim gc
  # left behind, not an orphan, and the fix is the same delete as the
  # ahead-zero case above, not another recovery draft (issue #302).
  merged="$("$GH" pr list -R "$slug" --head "$branch" --state merged \
          --json number --jq 'length' 2>/dev/null)" || merged=""
  if [[ -z "$merged" ]]; then
    warn "$branch" "could not check for a merged PR — leaving it alone"
    return 0
  fi
  if [[ "$merged" != "0" ]]; then
    if "$GH" api -X DELETE "repos/$slug/git/refs/heads/$branch" >/dev/null 2>&1; then
      jq -nc --arg b "$branch" '{action: "released", branch: $b}'
      actions=$(( actions + 1 ))
    else
      warn "$branch" "could not delete the already-merged leftover ref"
    fi
    return 0
  fi

  # This branch's own head never merged (just ruled out above), but the
  # *work* it carries may have landed anyway, on a rival branch that raced it
  # and won (issue #500, PR #370): a cycle that loses a race dies with commits
  # on a dead branch, and resurrecting that branch as a recovery draft would
  # reintroduce code a rival PR already superseded — sometimes with a
  # regression, since the rival kept moving after the loser stopped. Look for
  # a different branch sharing this one's item-ref stem that merged after
  # this branch's first commit. Unlike every guard above, an unanswered
  # question here does not leave the ref untouched: it changes nothing about
  # today's behaviour, so the recovery draft still gets filed — a clean "no
  # rival found" says nothing at all, but a lookup that actually failed still
  # warns, naming the branch, so the gap is visible without being noise on
  # every ordinary recovery.
  my_stem="$(stem "$branch")"
  first_commit_date="$(jq -r '.commits[0].commit.committer.date // empty' \
    <<<"$compare_json" 2>/dev/null)"
  first_commit_epoch=0
  [[ -n "$first_commit_date" ]] && first_commit_epoch="$(date -d "$first_commit_date" +%s 2>/dev/null || echo 0)"
  superseded_by=""
  rival_lookup_failed=0
  if (( first_commit_epoch > 0 )); then
    if rivals="$("$GH" api \
        "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
        2>/dev/null)" && jq -e 'type == "array"' <<<"$rivals" >/dev/null 2>&1; then
      while IFS=$'\t' read -r rival_ref rival_merged_at rival_url; do
        [[ -n "$rival_ref" && "$rival_ref" != "$branch" ]] || continue
        [[ "$(stem "$rival_ref")" == "$my_stem" ]] || continue
        rival_merged_epoch="$(date -d "$rival_merged_at" +%s 2>/dev/null || echo 0)"
        (( rival_merged_epoch > first_commit_epoch )) || continue
        superseded_by="$rival_url"
        break
      done < <(jq -r '.[] | select(.merged_at != null)
                          | [.head.ref, .merged_at, .html_url] | @tsv' \
               <<<"$rivals" 2>/dev/null)
    else
      rival_lookup_failed=1
    fi
  else
    rival_lookup_failed=1
  fi
  if [[ -n "$superseded_by" ]]; then
    if "$GH" api -X DELETE "repos/$slug/git/refs/heads/$branch" >/dev/null 2>&1; then
      jq -nc --arg b "$branch" --arg u "$superseded_by" \
        '{action: "released", branch: $b, reason: "superseded", superseded_by: $u}'
      actions=$(( actions + 1 ))
    else
      warn "$branch" "could not delete the superseded ref"
    fi
    return 0
  fi
  if (( rival_lookup_failed )); then
    warn "$branch" "could not check for a rival branch that already merged this work — filing the recovery draft anyway"
  fi

  body_file="$(mktemp)"
  cat > "$body_file" <<ORPHAN_BODY
The pipeline pushed commits to \`$branch\` but its cycle died before a pull
request existed, leaving the work invisible: nothing recovers a branch with no
PR, and the live claim ref blocks every later attempt at the same item
(IMPLEMENTATION-PIPELINE-SPEC requirement 17b).

This draft makes the work visible to the abandoned-drafts source again. Its
Implementer should read \`gh pr diff\` and the commit messages here, continue
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

# Both claim namespaces, prefix-listed server-side, plus td-record/ —
# unconditional, never gated by tech_debt_branch_prefix, since
# techdebt_file_debt mints a filing's record branch there regardless of that
# setting (TECHDEBT_RECORD_BRANCH_PREFIX, lib/tech-debt-file.sh). A failed
# listing is an unanswered question about the whole namespace: warn and move
# on.
for prefix in "$tech_debt_branch_prefix" "$branch_prefix" "$TECHDEBT_RECORD_BRANCH_PREFIX"; do
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
