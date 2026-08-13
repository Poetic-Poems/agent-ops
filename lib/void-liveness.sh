#!/usr/bin/env bash
#
# lib/void-liveness.sh — the actioned signal for the void shapes requirement
# 34n's original two rules (a closed GitHub object, a resolved register row)
# never covered (TD-PPagop-26081303).
#
# Requirement 34n retires a void entry once it is both actioned and old, but
# "actioned" was only ever defined for the two shapes requirements 34k and 34l
# already act on. Every other shape a cycle can void —
# `dependabot-alert-<n>`/`code-scanning-alert-<n>`, `register-hygiene-<hash>`,
# `failed-run-<workflow>`, and `pr-<n>-conflict-<head-sha>` — had no actioned
# signal at all, so a void of one of those shapes never retired and the
# extract kept the same unbounded growth curve requirement 34n exists to stop,
# underneath the part it does bound.
#
# The decided direction (TD-PPagop-26081303, filed against PR #311's review):
# age-only retirement is rejected, because a void whose id is *still being
# gathered* — a still-open alert, a register-hygiene finding the register
# still has, a workflow still failing, a PR still conflicted — is doing live
# suppression work every cycle, and retiring it on age alone re-exposes the
# item to be rediscovered void all over again (the exact churn requirement 34k
# exists to stop). The actioned analogue these four shapes have is liveness:
# the source that mints the id no longer yields it, this cycle, and the
# source's own gather succeeded — "unknown is not gone" (requirement 34i)
# applies here exactly as it does to the blocked set.
#
# Two other shapes a cycle can void — a project-review ref
# (`review-<date>-R-NN`) and an implementation-plan task id — are not
# pre-fetched as structured data at all; for those, requirement 34i's existing
# on-demand readers (`scripts/gather-review-status.sh`,
# `scripts/gather-plan-status.sh`) are the actioned signal, read for the void
# residue the same way they already are for the blocked one.
#
# A void naming no repo at all (the hand-appended form requirement 34c allows)
# matches none of these shapes by construction — a repo-scoped GATHER_JSON
# lookup on an empty repo key finds nothing — so it is left, as it always was,
# for a human to retract.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`.

# The id shapes this file can decide, kept in one place for the same reason
# lib/work-gone.sh's own regexes are (requirement 34a): the classifier below
# and the Script, which asks each side-channel only about ids that could
# possibly be its shape, both need them to agree.
#
# The alert refs are minted by scripts/gather-findings.sh ("dependabot-alert-"
# / "code-scanning-alert-" + the alert number).
VOID_LIVENESS_ALERT_RE='^(dependabot|code-scanning)-alert-[0-9]+$'

# scripts/gather-register-hygiene.sh's own ref: `register-hygiene-` plus a
# 12-hex-character digest of the register's tree and policy blob SHAs.
VOID_LIVENESS_REGISTER_HYGIENE_RE='^register-hygiene-[0-9a-f]{12}$'

# Requirement 19's `failed-runs` item id: `failed-run-` plus the workflow
# file's basename, without extension — free-form beyond that (a workflow
# filename may carry dots, underscores or hyphens).
VOID_LIVENESS_FAILED_RUN_RE='^failed-run-.+$'

# scripts/gather-merge-conflicts.sh's own ref for the shape requirement 34k
# deliberately excludes from its close (the addendum to TD-PPagop-26081303):
# `pr-<n>-conflict-` plus the head SHA's leading 12 hex characters
# (`${head_sha:0:12}`).
VOID_LIVENESS_MERGE_CONFLICT_RE='^pr-[0-9]+-conflict-[0-9a-f]{6,40}$'

# void_liveness_actioned VOID_JSON GATHER_JSON
# Print, as a JSON array of `{repo, item, by}`, the pairs from VOID_JSON that
# requirement 34n's liveness rule counts as actioned: an entry whose item
# matches one of the four shapes above, whose repo carries a GATHER_JSON entry
# for that shape with `ok: true`, and whose item is absent from that shape's
# `ids`.
#
# GATHER_JSON is keyed repo -> shape -> `{ok, ids}`, shape one of "alert",
# "register-hygiene", "failed-run", "merge-conflict":
#
#   {"owner/repo": {"alert": {"ok": true, "ids": ["dependabot-alert-3"]},
#                    "register-hygiene": {"ok": true, "ids": []},
#                    "failed-run": {"ok": false, "ids": []},
#                    "merge-conflict": {"ok": true, "ids": ["pr-9-conflict-1a2b3c4d5e6f"]}}}
#
# `ids` is this cycle's own gather for that repo+shape — the same array (or
# the same source) the Co-Ordinator itself was handed, before any claim
# exclusion narrows it: a claimed alert is still an open one, and narrowing by
# claim status here would retire a void whose object never actually closed.
# `ok` is whether that gather succeeded this cycle; `false` (or the repo+shape
# entry being absent entirely) decides nothing, the same "unknown is not gone"
# rule requirement 34i's own clearances observe — an item present in
# GATHER_JSON with `ok: false` is exactly as undecided as a repo missing from
# it altogether.
#
# The caller builds GATHER_JSON however it can afford to; this function reads
# it and nothing else, so it needs no network access and stays a pure,
# testable transform over state the caller already holds.
#
# Both VOID_JSON and GATHER_JSON travel on stdin, never in argv (requirement
# 4g): VOID_JSON is the unbounded extract itself. Fails safe to `[]` on any
# malformed input — the same "never retiring is the safe direction" rule
# `retire_void_items` already observes for the age half of this decision.
# shellcheck disable=SC2016  # jq's $void/$gather/$e/$shape, not the shell's.
void_liveness_actioned() {
  local void_json="${1:-[]}" gather_json="${2:-{\}}" out=""
  out="$(jq -c -n \
    --arg alert_re "$VOID_LIVENESS_ALERT_RE" \
    --arg rh_re "$VOID_LIVENESS_REGISTER_HYGIENE_RE" \
    --arg fr_re "$VOID_LIVENESS_FAILED_RUN_RE" \
    --arg mc_re "$VOID_LIVENESS_MERGE_CONFLICT_RE" '
    input as $void | input as $gather
    | def shape_of($item):
        if ($item | test($alert_re)) then "alert"
        elif ($item | test($rh_re)) then "register-hygiene"
        elif ($item | test($fr_re)) then "failed-run"
        elif ($item | test($mc_re)) then "merge-conflict"
        else null end;
    [ $void[]
      | . as $e
      | ($e.repo // "") as $repo
      | ($e.item // "") as $item
      | select($repo != "" and $item != "")
      | shape_of($item) as $shape
      | select($shape != null)
      | (($gather[$repo][$shape]) // null) as $g
      | select($g != null and ($g.ok // false) == true)
      | select((($g.ids // []) | index($item)) == null)
      | {repo: $repo, item: $item, by: ("liveness-" + $shape)} ]
  ' <<<"$void_json"$'\n'"$gather_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# void_review_plan_actioned VOID_JSON REVIEW_STATUS_JSON PLAN_STATUS_JSON
# Print, as a JSON array of `{repo, item, by}`, the actioned pairs for the two
# shapes requirement 34n's direction assigns the *existing* on-demand readers
# rather than a fresh liveness rule: a project-review ref backed by a merged
# pull request, and an implementation-plan task id backed by a checked
# checkbox.
#
# REVIEW_STATUS_JSON and PLAN_STATUS_JSON are the same shape
# `scripts/gather-review-status.sh` / `scripts/gather-plan-status.sh` already
# print — repo -> ref/id -> `"merged"`/`"done"` (or anything else, which
# decides nothing) — read here for the void residue exactly as
# `lib/work-gone.sh`'s `work_gone_clearances` already reads them for the
# blocked one. The shape regexes are `lib/work-gone.sh`'s own
# (`WORK_GONE_REVIEW_RE`, `WORK_GONE_PLAN_RE`) — one definition, per
# requirement 34a — so a caller must source that file first.
#
# All three inputs travel on stdin, never in argv (requirement 4g): VOID_JSON
# is unbounded. Fails safe to `[]` on any malformed input.
# shellcheck disable=SC2016  # jq's $void/$review/$plan/$e, not the shell's.
void_review_plan_actioned() {
  local void_json="${1:-[]}" review_json="${2:-{\}}" plan_json="${3:-{\}}" out=""
  out="$(jq -c -n \
    --arg review_re "$WORK_GONE_REVIEW_RE" --arg plan_re "$WORK_GONE_PLAN_RE" '
    input as $void | input as $review | input as $plan
    | [ $void[]
        | . as $e
        | ($e.repo // "") as $repo
        | ($e.item // "") as $item
        | select($repo != "" and $item != "")
        | if ($item | test($review_re)) then
            ((($review[$repo] // {})[$item] // "" | ascii_downcase) as $status
             | select($status == "merged")
             | {repo: $repo, item: $item, by: "review-merged"})
          elif ($item | test($plan_re)) then
            ((($plan[$repo] // {})[$item] // "" | ascii_downcase) as $status
             | select($status == "done")
             | {repo: $repo, item: $item, by: "plan-task-done"})
          else empty
          end ]
  ' <<<"$void_json"$'\n'"$review_json"$'\n'"$plan_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}
