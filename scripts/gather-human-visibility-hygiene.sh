#!/usr/bin/env bash
#
# gather-human-visibility-hygiene.sh — pre-fetch a repo's still-live
# human-visibility violations that `scripts/sweep-human-visibility.sh`
# (requirement 38c) could not self-heal, so a `gh` read or the review-request
# POST failing there stops being only a `warning` log line nobody re-reads
# (requirement 38e; tech-debt/TD-PPagop-26080801.md).
#
# Given a repo slug and this repo's slice of `human_visibility_violations`
# (lib/human-visibility-hygiene.sh, read from the log union), print a JSON
# array holding at most one candidate: the violations that are still true
# right now, re-verified live rather than trusted from the log alone.
#
# Usage: gather-human-visibility-hygiene.sh <owner/repo> [violations-json] [pr-label]
#
# `violations-json` (default `[]`) is an array of
#   {"repo": "owner/repo", "pr_url": "…" | "", "detail": "…", "ts": "…"}
# — `pr_url` is "" for a repo-level (listing) violation. Entries for a
# different repo are ignored, so a caller may hand this the whole fleet-wide
# array without filtering first.
#
# Candidate shape — its own source (issue #284's decision 2), not a
# register-hygiene ref-prefix split: a violation here means finished work is
# invisible to the human whose merge everything waits on, the same
# "finishing beats starting" class `review-feedback`, `merge-conflicts` and
# `abandoned-drafts` are, which register-hygiene's cosmetic-repair rationale
# does not describe:
#   {
#     "source": "human-visibility",
#     "ref": "human-visibility-1a2b3c4d5e6f",  // scoped to THIS set of violations
#     "url": "https://github.com/owner/repo/pulls",
#     "problems": ["HUMAN VISIBILITY  https://github.com/…/pull/9: could not request review from foo"],
#     "body": "…one paragraph per violation, verbatim detail included…"
#   }
#
# ## Why re-verified live, not trusted from the log alone
#
# The reduction this script's input already went through (`_latest_unresolved`-
# style: latest event per identity wins) clears a per-pull-request violation the
# moment the sweep next succeeds for that same pull request — but a repo-level
# listing failure has no such per-PR success to clear it: a listing that
# succeeds with nothing to act on logs nothing at all, so a one-off blip would
# read as permanently broken. And a per-pull-request violation goes stale a
# different way — the pull request merges or closes, and the sweep never visits
# it again to log anything at all, one way or the other.
#
# So every violation handed in is re-checked against GitHub's live state before
# it becomes a candidate, read-only throughout (issue #284's decision 1: never
# `confirm_review_requested` or `ensure_human_reviewer`, which POST) — a
# repo-level listing failure only survives if the listing still fails right
# now; a pull-request violation only survives if that pull request is still
# open and not a draft, *and* its own warning class's own live signal still
# says the violation holds (below). An answer this script cannot get — `gh`
# itself unreachable for the re-check — is not read as "resolved": the
# violation is kept, on the same reasoning `sweep-human-visibility.sh` itself
# uses (an unread state is never guessed at as clean). Only a *definite* "no
# longer true" answer drops a violation.
#
# ## Three warning classes, told apart
#
# `sweep-human-visibility.sh` logs three different per-pull-request warnings —
# "could not request review from …" (the review-request POST itself failed),
# "could not post the idle nudge comment" (the nudge comment POST itself
# failed), and "no legal review-request candidate" (no POST was even
# attempted — `ensure_human_reviewer`'s `skip\tno-candidate`,
# tech-debt/TD-PPagop-26081001.md) — and they clear on three different live
# facts. A single shared check would get more than one of them wrong: every
# pull request a nudge warning is logged against is, by the nudge's own gate,
# already `APPROVED` — so a check that only asks "has a human reviewed this"
# would read every nudge-class warning as resolved the moment it is created,
# silently dropping it before anyone ever saw the nudge that failed to post.
# So each class re-verifies its own claim:
#
#   could_not_request      — a read-only "is a human review currently
#                             requested (or already given)" check: `gh pr
#                             view --json reviewDecision,reviewRequests`.
#                             `reviewRequests` non-empty means a request is
#                             live right now; `reviewDecision` of `APPROVED`
#                             or `CHANGES_REQUESTED` means a review already
#                             happened, which only a request already granted
#                             could have produced — either is the violation
#                             resolving itself, the same two facts
#                             `ensure_human_reviewer` (`lib/handoff.sh`)
#                             itself reasons from, read rather than acted on.
#   could_not_post_nudge   — did the nudge comment land after all: `gh pr
#                             view --json comments`, searched for the
#                             `<!-- agent-ops:human-nudge -->` marker
#                             `sweep-human-visibility.sh` itself posts and
#                             checks for idempotency.
#   no_candidate            — does a candidate exist now: `gh pr view --json
#                             author,reviews,reviewRequests`, generalising
#                             `ensure_human_reviewer`'s own candidate rule
#                             read-only — a non-author, non-bot reviewer
#                             having since reviewed the pull request, a
#                             review request already pending (most often
#                             CODEOWNERS' own auto-request, live before
#                             anyone has reviewed — the `known`-reviewer
#                             check alone cannot see it), or `enabler_assignee`
#                             (carried in the warning's own detail text, at
#                             the value it held when the sweep warned) no
#                             longer naming the author, is the violation
#                             resolving itself: the sweep's own next pass
#                             would report `already` or `requested`, never
#                             `no-candidate` again, before this gatherer runs
#                             again.
#   (anything else)         — a warning this script does not recognise (e.g.
#                             "could not read the pull request's state —
#                             skipping the idle check", or a future warning
#                             shape) has no live signal of its own to check,
#                             so it is kept for as long as the pull request
#                             stays open and not a draft — the same fail-safe
#                             default an unreadable re-check gets.
#
# A pull request that has since merged, closed, or gone back to draft drops
# every class's violation regardless — none of the above can matter to a
# human on a pull request nobody is being asked to look at any more.
#
# ## The ref
#
# `human-visibility-<12 hex>`, a digest of the surviving violations' own
# identities and details (sorted, so entry order never matters) — not a bare
# `human-visibility`, for the same "expiry by irrelevance" reason
# gather-register-hygiene.sh's own ref is scoped to the register's identity
# (requirement 3i): a block recorded against one set of violations must not
# swallow a later, disjoint set, while re-detecting the *same* set keeps the
# same ref and stays correctly blocked.
#
# Fails safe: always prints a valid JSON array and exits 0. No violations
# handed in, or none surviving the live re-check, is `[]` — the ordinary
# answer almost every cycle gets.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than being read as
# an answer this script could not get. See lib/github-limit.sh. It matters
# more here than in most gatherers: an unreadable re-check *keeps* its
# violation, so a rate-limited cycle would otherwise offer a candidate for a
# violation that had already resolved.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
violations_json="${2:-[]}"
pr_label="${3:-autonomous-agent}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-human-visibility-hygiene.sh <owner/repo> [violations-json] [pr-label]" >&2
  exit 64
fi
jq -e 'type == "array"' <<<"$violations_json" >/dev/null 2>&1 || violations_json='[]'

# _warning_class DETAIL
# Classify a sweep warning's detail text into the live check that resolves
# it. Prefix/substring matched against the three fixed shapes
# sweep-human-visibility.sh's own `warn` calls produce; anything else is
# `unknown`.
_warning_class() {
  case "$1" in
    "could not request review from"*) printf 'could_not_request' ;;
    *"idle nudge comment"*) printf 'could_not_post_nudge' ;;
    "no legal review-request candidate"*) printf 'no_candidate' ;;
    *) printf 'unknown' ;;
  esac
}

# _pr_violation_survives PR_URL DETAIL
# Print `keep` or `drop` for one pull-request-level violation, read-only
# throughout. `drop` only on a definite live answer that it no longer holds;
# an unreadable pull request is `keep`, the same fail-safe default the header
# note describes.
_pr_violation_survives() {
  local pr_url="$1" detail="$2" class json state draft decision requests has_marker
  local assignee author_login known_other
  class="$(_warning_class "$detail")"

  json="$(gh pr view "$pr_url" \
            --json state,isDraft,reviewDecision,reviewRequests,comments,author,reviews 2>/dev/null)" || true
  if [[ -z "$json" ]]; then
    printf 'keep'
    return
  fi

  state="$(jq -r '.state // ""' <<<"$json" 2>/dev/null || true)"
  draft="$(jq -r '.isDraft // false' <<<"$json" 2>/dev/null || true)"
  if [[ "$state" != "OPEN" || "$draft" != "false" ]]; then
    printf 'drop'
    return
  fi

  case "$class" in
    could_not_request)
      decision="$(jq -r '.reviewDecision // ""' <<<"$json" 2>/dev/null || true)"
      requests="$(jq -r '(.reviewRequests // []) | length' <<<"$json" 2>/dev/null || echo 0)"
      if [[ "$decision" == "APPROVED" || "$decision" == "CHANGES_REQUESTED" || "$requests" != "0" ]]; then
        printf 'drop'
      else
        printf 'keep'
      fi
      ;;
    could_not_post_nudge)
      has_marker="$(jq -r '(.comments // []) | any((.body // "") | test("agent-ops:human-nudge"))' \
                     <<<"$json" 2>/dev/null || echo false)"
      if [[ "$has_marker" == "true" ]]; then
        printf 'drop'
      else
        printf 'keep'
      fi
      ;;
    no_candidate)
      # Generalises `ensure_human_reviewer`'s own candidate rule (`lib/
      # handoff.sh`) read-only: a candidate now exists if either a non-author,
      # non-bot reviewer has since reviewed the pull request (the `known`
      # list `ensure_human_reviewer` would target first), or a review request
      # is already pending — most often CODEOWNERS' own auto-request, made
      # the moment the pull request opened, before anyone has reviewed yet,
      # which the `known`-reviewer check cannot see (agent-ops #350, #353,
      # #355: each already had `Warwick-Allen` live-requested by CODEOWNERS
      # with nobody's review submitted) — or `enabler_assignee` — carried in
      # DETAIL, `sweep-human-visibility.sh`'s own value at the time it warned
      # — is not (or is no longer) the pull request's own author. Any of the
      # three is the violation resolving itself: the sweep's own next pass
      # would report `already` or `requested` for this pull request, never
      # `no-candidate` again, before this gatherer ever ran again.
      assignee="$(sed -n 's/.*enabler_assignee=//p' <<<"$detail")"
      author_login="$(jq -r '.author.login // ""' <<<"$json" 2>/dev/null || true)"
      known_other="$(jq -r --arg a "$author_login" '
          [(.reviews // [])[] | select((.state // "") != "PENDING")
             | (.author.login // "")
             | select(. != "" and . != $a and (endswith("[bot]") | not))]
          | unique | length' <<<"$json" 2>/dev/null || echo 0)"
      requests="$(jq -r '(.reviewRequests // []) | length' <<<"$json" 2>/dev/null || echo 0)"
      if [[ "$known_other" != "0" ]] || [[ "$requests" != "0" ]] \
          || { [[ -n "$assignee" ]] && [[ "$assignee" != "$author_login" ]]; }; then
        printf 'drop'
      else
        printf 'keep'
      fi
      ;;
    *)
      printf 'keep'
      ;;
  esac
}

mine="$(jq -c --arg r "$slug" '[.[] | select((.repo // "") == $r)]' <<<"$violations_json" 2>/dev/null || echo '[]')"
if [[ "$(jq 'length' <<<"$mine" 2>/dev/null || echo 0)" == "0" ]]; then
  printf '[]'
  exit 0
fi

# A repo-level listing violation (there is at most one distinct one per repo,
# by construction of the reduction that produced $mine) survives only if the
# same listing still fails right now.
repo_level="$(jq -c '[.[] | select((.pr_url // "") == "")]' <<<"$mine")"
if [[ "$(jq 'length' <<<"$repo_level")" != "0" ]]; then
  if gh pr list -R "$slug" --state open --label "$pr_label" --json url >/dev/null 2>&1; then
    mine="$(jq -c '[.[] | select((.pr_url // "") != "")]' <<<"$mine")"
  fi
fi

survivors='[]'
while IFS= read -r v; do
  [[ -n "$v" ]] || continue
  pr_url="$(jq -r '.pr_url // ""' <<<"$v")"
  if [[ -z "$pr_url" ]]; then
    survivors="$(jq -c --argjson v "$v" '. + [$v]' <<<"$survivors")"
    continue
  fi
  detail="$(jq -r '.detail // ""' <<<"$v")"
  if [[ "$(_pr_violation_survives "$pr_url" "$detail")" == "keep" ]]; then
    survivors="$(jq -c --argjson v "$v" '. + [$v]' <<<"$survivors")"
  fi
done < <(jq -c '.[]' <<<"$mine" 2>/dev/null || true)

if [[ "$(jq 'length' <<<"$survivors" 2>/dev/null || echo 0)" == "0" ]]; then
  printf '[]'
  exit 0
fi

ref="human-visibility-$(jq -r 'map((.pr_url // "") + "|" + (.detail // "")) | sort | join("\n")' \
      <<<"$survivors" | sha256sum | cut -c1-12)"
url="https://github.com/$slug/pulls"

problems="$(jq -c '[.[] | "HUMAN VISIBILITY  " + (if (.pr_url // "") == "" then $r else .pr_url end) + ": " + (.detail // "")]' \
      --arg r "$slug" <<<"$survivors" 2>/dev/null || echo '[]')"

body="$(jq -r '
  "The following human-visibility violation(s) (requirement 38c) could not be "
  + "self-healed by scripts/sweep-human-visibility.sh and have not cleared on "
  + "their own (requirement 38e):\n\n"
  + (map("- " + (if (.pr_url // "") == "" then $r else .pr_url end)
         + " (last logged " + (.ts // "unknown") + "): " + (.detail // "")) | join("\n"))
' --arg r "$slug" <<<"$survivors")"

jq -nc \
  --arg ref "$ref" \
  --arg url "$url" \
  --argjson problems "$problems" \
  --arg body "$body" \
  '[{source: "human-visibility",
     ref: $ref,
     url: $url,
     problems: $problems,
     body: $body}]'
