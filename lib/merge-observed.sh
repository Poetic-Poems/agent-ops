#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/merge-observed.sh — the completion path for a subject pull request that
# merges out from under a stage before that stage ever hands it off
# (agent-ops#916, escalation #922).
#
# `agent-cycle.sh`'s `$impl_pr_url` merging mid-Reviewer-pass used to go
# unnoticed: nothing on the handoff path ever asked GitHub whether the pull
# request it was about to flip ready, or approve, or land was still open, so
# a Reviewer that noticed had no contract for it and improvised — opening a
# replacement pull request reported only in prose, invisible to every
# machine-readable record the pipeline keeps (`pr-raised`, the `pr-<n>`
# claim, a `complexity:*` label, an Approver engagement). See lib/handoff.sh's
# `pr_merge_state` for the read that catches this; this file is what a
# confirmed merge does once caught.
#
# Escalation #922 settled three points this file and its two callers in
# agent-cycle.sh (the Reviewer's own stage-start, advisory, and its handoff,
# fail-closed) divide between them:
#
#   1. The Reviewer may not open a replacement pull request when its subject
#      merges mid-pass. It stops — no further push anywhere, no replacement —
#      and ends `"status": "blocked"` naming the merge, with whatever it had
#      already found carried in `file_debt`/`file_issue` instead of a
#      `Defers:` line (there is no live pull request left to add one to).
#   2. A mid-stage merge is a completion, decided by the Script's own read —
#      never the Reviewer verdict's word, so this runs whether the Reviewer
#      never noticed (`"status": "ready"`) or noticed and said so
#      (`"status": "blocked"`). No `pr-ready`, no Approver engagement, no
#      landing attempt; the item retires the way `lib/work-gone.sh` retires
#      one whose issue closed underneath it, never as `attempt-failed`.
#   3. One state-read helper (`pr_merge_state`), fail-closed at the handoff
#      and advisory at each stage-start.
#
# `reviewer_merge_observed` is decision 2 and the leftover-filing half of
# decision 1: it logs `merge-observed`, files whatever the Reviewer's own
# verdict (or, at the stage-start call site, nothing — the Reviewer never
# ran) asked for under the ordinary pipeline login — the Reviewer carries no
# App identity of its own, the same reason `lib/enabler.sh`'s own
# `file_debt`/`file_issue` handling always omits TOKEN too — and releases the
# PR-keyed claim. Sourced, never executed: it sets no shell options, because
# agent-cycle.sh runs under `set -euo pipefail`. Depends on `log_event`,
# `release_pr_claim` (lib/candidate-select.sh) and `techdebt_file_debt`/
# `techdebt_file_issue` (lib/tech-debt-file.sh), all already sourced by the
# time agent-cycle.sh can reach either call site.

# reviewer_merge_observed PR_URL MERGE_SHA REV_STATUS_JSON STAGE
#
# PR_URL is the subject that merged. MERGE_SHA is `pr_merge_state`'s own
# second field, logged when non-empty. REV_STATUS_JSON is the Reviewer's
# parsed final JSON at the handoff call site, or `{}` at the stage-start
# call site (the Reviewer never ran, so there is nothing to have asked it
# for). STAGE is `"reviewer"` or `"reviewer-stage-start"`, carried on the
# `merge-observed` event so a reader can tell which read caught it.
reviewer_merge_observed() {
  local pr_url="${1:-}" merge_sha="${2:-}" rev_status_json="${3:-{\}}" stage="${4:-reviewer}"
  local fd_json fd_title fd_body fd_pr_label fd_result fd_id fd_pr_url fd_default_fix fd_owner_decision
  local fi_json fi_title fi_body fi_body_file fi_result fi_number fi_url fi_default_fix fi_owner_decision

  log_event "merge-observed" "$(jq -nc --arg r "$selected_repo" --arg i "$selected_item" \
    --arg u "$pr_url" --arg s "$merge_sha" --arg stage "$stage" \
    '{repo: $r, item: $i, pr_url: $u, stage: $stage} + (if $s == "" then {} else {merge_sha: $s} end)')"

  # file_debt/file_issue (agent-ops#916, following agent-ops#631's shape):
  # the Reviewer's own leftovers from a pass its subject merged underneath —
  # never a `Defers:` line, since there is no live pull request left to add
  # one to. Omitted entirely at the stage-start call site, where
  # REV_STATUS_JSON is `{}` and both reads are no-ops.
  fd_json="$(jq -c '.file_debt // empty' <<<"$rev_status_json" 2>/dev/null || true)"
  if [[ -n "$fd_json" && "$fd_json" != "null" ]]; then
    fd_title="$(jq -r '.title // ""' <<<"$fd_json" 2>/dev/null || true)"
    fd_body="$(jq -r '.body // ""' <<<"$fd_json" 2>/dev/null || true)"
    fd_default_fix="$(jq -r '.default_fix // ""' <<<"$fd_json" 2>/dev/null || true)"
    fd_owner_decision="$(jq -r \
      'if (.owner_decision // false) == true then "true" else "false" end' \
      <<<"$fd_json" 2>/dev/null || true)"
    [[ -n "$fd_owner_decision" ]] || fd_owner_decision="false"
    fd_pr_label="$(jq -r '.pr_label // empty' <<<"$DEFAULTED_CONFIG" 2>/dev/null || true)"
    [[ -n "$fd_pr_label" ]] || fd_pr_label="autonomous-agent"
    if [[ -z "$fd_title" || -z "$fd_body" ]]; then
      log_event "warning" "$(jq -nc --arg u "$pr_url" \
        --arg d "reviewer set file_debt for $pr_url, but it carries no title or body — ignored" \
        '{detail: $d, pr_url: $u}')"
    else
      if [[ -z "$fd_default_fix" && "$fd_owner_decision" != "true" ]]; then
        log_event "warning" "$(jq -nc --arg u "$pr_url" \
          --arg d "reviewer set file_debt for $pr_url with no default_fix and no owner_decision — filed with '## Default: not stated'" \
          '{detail: $d, pr_url: $u}')"
      fi
      if fd_result="$(techdebt_file_debt "$selected_repo" "$fd_title" "$fd_body" \
             "while the Reviewer was examining $pr_url, whose subject merged mid-pass" "" "${cycle_dir:-}" "$fd_pr_label" \
             "$fd_default_fix" "$fd_owner_decision")" \
             && [[ -n "$fd_result" ]]; then
        IFS=$'\t' read -r fd_id fd_pr_url <<<"$fd_result"
        log_event "tech-debt-filed" "$(jq -nc --arg u "$pr_url" --arg r "$selected_repo" \
          --arg id "$fd_id" --arg fu "$fd_pr_url" \
          '{pr_url: $u, repo: $r, by: "reviewer", id: $id, filed_pr_url: $fu}')"
      else
        log_event "warning" "$(jq -nc --arg u "$pr_url" \
          --arg d "reviewer: could not file the tech-debt record for $pr_url (see tech-debt-file.err)" \
          '{detail: $d, pr_url: $u}')"
      fi
    fi
  fi

  fi_json="$(jq -c '.file_issue // empty' <<<"$rev_status_json" 2>/dev/null || true)"
  if [[ -n "$fi_json" && "$fi_json" != "null" ]]; then
    fi_title="$(jq -r '.title // ""' <<<"$fi_json" 2>/dev/null || true)"
    fi_body="$(jq -r '.body // ""' <<<"$fi_json" 2>/dev/null || true)"
    fi_default_fix="$(jq -r '.default_fix // ""' <<<"$fi_json" 2>/dev/null || true)"
    fi_owner_decision="$(jq -r \
      'if (.owner_decision // false) == true then "true" else "false" end' \
      <<<"$fi_json" 2>/dev/null || true)"
    [[ -n "$fi_owner_decision" ]] || fi_owner_decision="false"
    if [[ -z "$fi_title" || -z "$fi_body" ]]; then
      log_event "warning" "$(jq -nc --arg u "$pr_url" \
        --arg d "reviewer set file_issue for $pr_url, but it carries no title or body — ignored" \
        '{detail: $d, pr_url: $u}')"
    else
      if [[ -z "$fi_default_fix" && "$fi_owner_decision" != "true" ]]; then
        log_event "warning" "$(jq -nc --arg u "$pr_url" \
          --arg d "reviewer set file_issue for $pr_url with no default_fix and no owner_decision — filed with '## Default: not stated'" \
          '{detail: $d, pr_url: $u}')"
      fi
      fi_body_file="${cycle_dir:-/tmp}/reviewer-merge-observed-file-issue.md"
      printf '%s\n\n---\nNoticed by the autonomous pipeline while the Reviewer was examining %s, whose subject merged mid-pass.\n' \
        "$fi_body" "$pr_url" > "$fi_body_file"
      if fi_result="$(techdebt_file_issue "$selected_repo" "$pr_url" "$fi_title" \
             "$fi_body_file" "" "$fi_default_fix" "$fi_owner_decision")" \
             && [[ -n "$fi_result" ]]; then
        IFS=$'\t' read -r fi_number fi_url <<<"$fi_result"
        log_event "issue-filed" "$(jq -nc --arg u "$pr_url" --arg r "$selected_repo" \
          --argjson n "$fi_number" --arg iu "$fi_url" \
          '{pr_url: $u, repo: $r, by: "reviewer", issue_number: $n, issue_url: $iu}')"
      else
        log_event "warning" "$(jq -nc --arg u "$pr_url" \
          --arg d "reviewer: could not file the issue for $pr_url (see tech-debt-file.err)" \
          '{detail: $d, pr_url: $u}')"
      fi
    fi
  fi

  release_pr_claim
}
