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
# Candidate shape (deliberately comparable to gather-register-hygiene.sh's
# own, `source: "register-hygiene"` included, so the selection walk, the
# branch derivation and the block/void escape hatch all treat it exactly like
# any other register-hygiene item — no new selectable source. The shared
# source is wiring, not meaning: prompts/coordinator.md and
# prompts/implementor.md split their register-hygiene guidance on the `ref`
# prefix below, because a work order for this kind carries a different
# acceptance test, a different model tier and no `blob_sha`):
#   {
#     "source": "register-hygiene",
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
# it becomes a candidate: a repo-level listing failure only survives if the
# listing still fails right now; a pull-request violation only survives if that
# pull request is still open and not a draft. An answer this script cannot get
# — `gh` itself unreachable for the re-check — is not read as "resolved": the
# violation is kept, on the same reasoning `sweep-human-visibility.sh` itself
# uses (an unread state is never guessed at as clean). Only a *definite* "no
# longer true" answer drops a violation.
#
# ## The ref
#
# `human-visibility-<12 hex>`, a digest of the surviving violations' own
# identities and details (sorted, so entry order never matters) — not a bare
# `human-visibility`, for the same "expiry by irrelevance" reason
# gather-register-hygiene.sh's own ref is scoped to the register's identity
# (requirement 3i): a block recorded against one set of violations must not
# swallow a later, disjoint set, while re-detecting the *same* set keeps the
# same ref and stays correctly blocked. Deliberately its own namespace,
# disjoint from `register-hygiene-<hash>` (the register-content ref
# gather-register-hygiene.sh mints): the two scripts' candidates are unrelated
# facts about the repository — one about a file tree, this one about GitHub's
# live PR state — and folding them into one ref would mean fixing either one
# retires a block that still describes the other.
#
# Fails safe: always prints a valid JSON array and exits 0. No violations
# handed in, or none surviving the live re-check, is `[]` — the ordinary
# answer almost every cycle gets.

set -uo pipefail

slug="${1:-}"
violations_json="${2:-[]}"
pr_label="${3:-autonomous-agent}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-human-visibility-hygiene.sh <owner/repo> [violations-json] [pr-label]" >&2
  exit 64
fi
jq -e 'type == "array"' <<<"$violations_json" >/dev/null 2>&1 || violations_json='[]'

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
  pr_state="$(gh pr view "$pr_url" --json state,isDraft \
                --jq '(.state) + "\t" + (.isDraft | tostring)' 2>/dev/null || true)"
  if [[ -z "$pr_state" ]]; then
    # Could not be read at all — kept, not dropped; see the header note.
    survivors="$(jq -c --argjson v "$v" '. + [$v]' <<<"$survivors")"
    continue
  fi
  IFS=$'\t' read -r pr_open pr_draft <<<"$pr_state"
  if [[ "$pr_open" == "OPEN" && "$pr_draft" == "false" ]]; then
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
  '[{source: "register-hygiene",
     ref: $ref,
     url: $url,
     problems: $problems,
     body: $body}]'
