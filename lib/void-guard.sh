#!/usr/bin/env bash
#
# lib/void-guard.sh — what any stage must produce before one of its `void`
# verdicts is allowed to be permanent (requirement 34d).
#
# `void` is the only terminal state in the system. Requirement 34c makes that
# deliberate and one-directional: no agent may clear a void, because the only
# evidence that could ever arrive — "the work is already done" — is the reason
# the item is void, so an agent permitted to weigh it would reason its way out
# of every void it met. Only a human, appending `unvoided` by hand, can reverse
# one.
#
# That asymmetry is right, and it makes *creating* a void the dangerous act.
# The system's own note on requirement 34c says creating is safe where clearing
# is not — "a wrong void costs a human one line in a log". It costs more than
# that, because nothing will ever tell the human the line is needed. A wrong
# void is silent: the item vanishes from selection, the Co-Ordinator that
# skipped it reports `none-selected`, the no-op fingerprint (requirement 3b)
# then matches on every following cycle and the fleet stands down without even
# buying a Co-Ordinator turn. The pipeline looks healthy and idle. It is idle
# because it has been lied to.
#
# The PR-diff check below only fires when the voided repo+item matches a
# gathered candidate carrying a `pr_number` — the finishing sources
# (review-feedback, merge-conflicts, abandoned-drafts). For everything else —
# most tech-debt items, every review recommendation, a failed-runs entry —
# nothing tested the citation itself, only that the `evidence` field was
# non-empty, and a model willing to assert a false reason is just as willing
# to write a plausible-looking free-text citation for it (TD26072601). So a
# second, independent test resolves what it can: an `evidence` value shaped
# `{ref, path, expect, pattern}` names a specific file at a specific ref and a
# specific claim about it, which is exactly as checkable as a PR diff — fetch
# it and see. A citation that does not take that shape is unstructured prose,
# accepted on the presence test alone as before; one that does take the shape
# but does not hold when fetched is refused, on the same "uncorroborated is
# not innocent" reasoning as an unreadable PR.
#
# It happened. A Co-Ordinator voided a tech-debt item with
# "PR #92 work is finished: workflow timeout, fetch timeouts, retry-on-rejection
# and tests all merged; TECH-DEBT.md Ledger marked resolved" — while the
# workflow file on the default branch still had no timeout, the Ledger row still
# read `open`, and the PR was still an open, conflicted draft. Every clause was
# checkable, and none of it was checked. The item was unreachable from both
# directions after that: void as a tech-debt candidate, and void as the
# abandoned-draft that would have finished it, because a void keys on the item
# and so bypasses the per-head refs (requirements 3e, 3g) that exist precisely
# so a changed state gets a fresh look.
#
# ## Why the guard lives here and not in the prompt
#
# The obvious repair is to tell the model to be more careful. That is not a
# repair: "be certain" is already in prompts/coordinator.md, twice, and the
# model that voided #92 was certain. Nor is it enough to point at which stage
# can see the most — the Co-Ordinator reads a JSON digest of candidates and
# nothing else, but the Implementor (requirement 27b) and the Enabler
# (requirement 35) read the tree, the issue and the PR directly, and issue #243
# is what a Co-Ordinator void looked like anyway: it voided #224 citing "PR
# #232 implemented all five rewrites" — a real, mergeable PR, just one that
# belonged to #221. Every mechanical test that already existed passed, because
# none of them had ever asked whether the cited PR was *about this item*.
# Reading more context does not stop a model from citing the wrong artifact
# inside it; only checking the citation does.
#
# So the guard is mechanical, and it runs on the Script's side of the boundary
# — for every stage that can write `item-void` (the Co-Ordinator, the Enabler,
# the Implementor), through the one shared entry point, `void_guard_reason`:
#
#   1. **Evidence must exist.** Requirement 34c has always said an `item-void`
#      carries `reason` *and* `evidence` — "the SHAs, paths, or commands proving
#      there is no work", so a human can audit the verdict without redoing the
#      investigation. The Co-Ordinator's `voided` entries never carried it, and
#      the Script never asked; the false void above was recorded with a reason
#      and nothing else. An entry with no evidence is not a verdict, it is an
#      opinion, and opinions are not terminal.
#   2. **This cycle's own candidates must not refute it.** A void asserts the
#      work is already on the default branch. When the item has an open pull
#      request among the candidates this very cycle gathered, that assertion is
#      testable for the price of one API call: a PR whose diff against its base
#      is non-empty is a PR whose changes are, by definition, not on the base.
#      No amount of model confidence survives that. (Co-Ordinator only — it is
#      the only stage with a gathered candidate list to test against.)
#   3. **A cited PR or commit must actually be about this item** (issue #243).
#      Evidence naming "PR #N" or a commit SHA is fetched live and checked for
#      the item id in the PR's body/branch, or the commit's message/associated
#      PRs — see `void_citation_reason` below. This is what requirement 34d was
#      missing before #243: a citation that merely *exists* is not
#      corroboration, and it is checked the same way for every stage, since it
#      needs nothing but the API and the citation itself.
#
# ## What a refused void becomes
#
# Not nothing, and not a human's problem: `blocked` (requirement 32a). Blocked
# is the clearable twin of void — the Co-Ordinator skips it, so the item does
# not churn, and it becomes Enabler-eligible under requirement 35a, so an actor
# that *can* read the tree adjudicates it. If the item really is done, the
# Enabler voids it properly, with evidence, and the state is reached by the
# route that can be audited. The pipeline gets to the same answer; it just is
# not allowed to get there by assertion.
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`.
#
# Environment:
#   VOID_GUARD_GH  override `gh` (tests stub it).

# entry_field_text ENTRY_JSON FIELD
# Print one field of a model-supplied entry as a single string — objects and
# arrays are rendered as JSON so a caller can test emptiness without caring
# which shape the model chose. Prints nothing when the field holds nothing
# usable.
#
# `null`, `{}`, `[]`, `""` and whitespace all count as nothing. A model asked
# for a field will fill it with something; the empty container is the something
# it reaches for first, and accepting it would make the requirement decorative.
#
# Generalised from `void_entry_evidence` (below) when the same discipline was
# needed field by field on the Co-Ordinator's `needs_refinement` entries
# (requirement 34e, `lib/refinement.sh`). One definition, per requirement 34a:
# two copies of "what counts as a filled-in field" would agree until the day one
# of them was relaxed.
entry_field_text() {
  local entry="$1" field="$2" text
  text="$(jq -r --arg f "$field" '
    (.[$f] // null)
    | if . == null then ""
      elif type == "string" then .
      elif (type == "object" or type == "array") then (if length == 0 then "" else tojson end)
      else tostring
      end' <<<"$entry" 2>/dev/null || true)"
  # Trim, so a field holding a single space is treated as the absence it is.
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  [[ "$text" == "null" ]] && text=""
  printf '%s' "$text"
}

# void_entry_evidence ENTRY_JSON
# Print the entry's evidence, or nothing when it carries none that counts.
void_entry_evidence() {
  entry_field_text "$1" evidence
}

# void_entry_resolvable_evidence ENTRY_JSON
# Print the entry's evidence, normalised to `{ref, path, expect, pattern}`,
# when it is shaped for the Script to dereference — `ref` and `path` non-empty
# strings, `expect` one of `"present"`/`"absent"`, `pattern` optional. Print
# nothing when the evidence is anything else: a string, a differently-shaped
# object, or absent. That "anything else" bucket is deliberately wide — it is
# where free-text citations live, and TD26072601 keeps them accepted on the
# presence test alone rather than demanding every void fit one mould.
void_entry_resolvable_evidence() {
  jq -c '
    (.evidence // null) as $e
    | if ($e | type) != "object" then empty else
      ( ($e.ref  // "") | if type == "string" then . else "" end) as $ref
    | ( ($e.path // "") | if type == "string" then . else "" end) as $path
    | ( ($e.expect // "") | if type == "string" then . else "" end) as $expect
    | if ($ref | length) == 0 or ($path | length) == 0
         or ($expect != "present" and $expect != "absent")
      then empty
      else {ref: $ref, path: $path, expect: $expect,
            pattern: (($e.pattern // "") | if type == "string" then . else "" end)}
      end
    end' <<<"$1" 2>/dev/null || true
}

# void_api_is_not_found API_BODY
# True when a failed contents fetch failed because GitHub has nothing at that
# path — and not because it would not answer at all.
#
# `gh api` exits non-zero for every HTTP error alike, but GitHub's own response
# body says which one it was, and `gh` hands that body back on stdout even as
# it exits: `{"message": "Not Found", …, "status": "404"}`. Testing GitHub's
# answer rather than `gh`'s phrasing of it is the idiom
# `scripts/gather-register-hygiene.sh` already uses to tell "this repo keeps no
# register" from "we could not look", and it is the same distinction here.
#
# A `ref` GitHub cannot resolve is a 404 too, but a differently-worded one
# ("No commit found for the ref …"), and it is *not* absence: nothing was
# established about a ref that does not exist. Both directions of drift in that
# wording fail towards refusing a void, which is the safe direction.
void_api_is_not_found() {
  local body="$1" http_status message
  http_status="$(jq -r '.status // ""' <<<"$body" 2>/dev/null || true)"
  message="$(jq -r '.message // ""' <<<"$body" 2>/dev/null || true)"
  [[ "$http_status" == "404" && "$message" == "Not Found" ]]
}

# void_evidence_resolves RESOLVABLE_JSON SLUG
# Test one `{ref, path, expect, pattern}` citation against `repos/<slug>` via
# the GitHub contents API. Prints nothing and returns 0 when the citation
# holds; prints a one-line reason and returns 1 otherwise — including when the
# API will not answer, on the same "uncorroborated is not innocent" reasoning
# `void_guard_reason` already applies to an unreadable PR.
#
# `expect: "absent"` is satisfied only by GitHub answering `404 Not Found` (see
# `void_api_is_not_found`). A fetch that fails any other way — rate limited,
# unauthenticated, no network, a `ref` GitHub cannot resolve — has established
# nothing, and an unanswered fetch must not read as corroboration when the
# unreadable PR two checks below is refused for exactly that. Within a real
# 404 no further distinction is drawn: the claim being made ("the fix is on
# `main`" for a file `main` no longer needs) doesn't separate "removed" from
# "never existed at that ref", so neither do we. `expect: "present"` requires
# the fetch to succeed and, when `pattern` is given, the decoded content to
# match it (extended regex, `grep -E`) — the shape the second claim TD26072601
# names takes: "the Ledger row says resolved" is a pattern match against
# TECH-DEBT.md, not just the file existing.
void_evidence_resolves() {
  local resolvable="$1" slug="$2" gh_bin="${VOID_GUARD_GH:-gh}"
  local ref path expect pattern api_out status content detail

  ref="$(jq -r '.ref' <<<"$resolvable")"
  path="$(jq -r '.path' <<<"$resolvable")"
  expect="$(jq -r '.expect' <<<"$resolvable")"
  pattern="$(jq -r '.pattern' <<<"$resolvable")"

  api_out="$("$gh_bin" api "repos/$slug/contents/$path?ref=$ref" 2>/dev/null)"
  status=$?

  if [[ "$expect" == "absent" ]]; then
    if (( status == 0 )) && [[ -n "$api_out" ]]; then
      printf 'evidence claims %s is absent from %s@%s, but it exists' "$path" "$slug" "$ref"
      return 1
    fi
    if ! void_api_is_not_found "$api_out"; then
      detail="$(jq -r '.message // ""' <<<"$api_out" 2>/dev/null || true)"
      [[ -n "$detail" ]] || detail="the API did not answer"
      printf 'evidence claims %s is absent from %s@%s, but the fetch failed with "%s" rather than reporting it absent' \
        "$path" "$slug" "$ref" "$detail"
      return 1
    fi
    return 0
  fi

  if (( status != 0 )) || [[ -z "$api_out" ]]; then
    printf 'evidence claims %s is present at %s@%s, but it could not be read' "$path" "$slug" "$ref"
    return 1
  fi

  if [[ -n "$pattern" ]]; then
    content="$(jq -r '.content // empty' <<<"$api_out" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null)"
    if ! grep -qE -- "$pattern" <<<"$content"; then
      printf 'evidence claims %s at %s@%s matches %s, but it does not' "$path" "$slug" "$ref" "$pattern"
      return 1
    fi
  fi

  return 0
}

# void_candidate_prs ENTRY_JSON REPOS_JSON
# Print, one per line as `<owner/repo>#<number>`, every open pull request this
# cycle's gathered candidates associate with the voided entry's repo and item.
#
# REPOS_JSON is the Co-Ordinator's own runtime input (requirement 3): an array
# of repos each carrying its `findings`, `review_feedback`, `abandoned_drafts`
# and `merge_conflicts` arrays. Those are the only PRs in scope, and that is the
# point — the guard tests the void against the same facts the Co-Ordinator was
# looking at when it made it, so it can never be refuted by something it could
# not have known.
#
# Matching is case-insensitive on the item id: gatherers recover an item by
# grepping the branch name and PR body (`grep -oiE`), so the case that reaches a
# candidate is whatever the author typed, while the Co-Ordinator reports the id
# as the register spells it. An entry naming no repo is matched across all of
# them — the same over-matching requirement 34's `unblocked` rule chooses, and
# for the same reason: erring towards *more* corroboration is the safe
# direction.
void_candidate_prs() {
  local entry="$1" repos="$2"
  jq -r --argjson e "$entry" '
    (($e.item // "") | ascii_downcase) as $item
    | (($e.repo // "")) as $repo
    | [ .[]
        | select($repo == "" or .slug == $repo)
        | .slug as $slug
        | ((.findings // []) + (.review_feedback // [])
           + (.abandoned_drafts // []) + (.merge_conflicts // []))[]
        | select((((.item // "") | tostring) | ascii_downcase) == $item and $item != "")
        | select((.pr_number // null) != null)
        | "\($slug)#\(.pr_number)"
      ]
    | unique
    | .[]' <<<"$repos" 2>/dev/null || true
}

# void_item_regex ITEM
# ITEM, escaped so it can be dropped into a `grep -E` pattern literally. Item
# ids are ordinarily alnum/dash (`TD26051201`, `review-2026-07-20-R03`,
# `dependabot-alert-42`, a bare issue number), but nothing enforces that on
# the way in, and a stray regex metacharacter must not turn a corroboration
# check into a crash or a false match.
void_item_regex() {
  printf '%s' "$1" | sed -E 's/[][\.^$*+?(){}|]/\\&/g'
}

# void_text_names_item TEXT ITEM
# True when ITEM appears in TEXT as a whole token — `\b…\b`, the same
# word-boundary discipline the gatherers already apply when they recover an
# item id from a branch name or PR body (`grep -oiE '\b(TD[0-9]{8}|…)\b'` in
# scripts/gather-*.sh). Plain substring matching would let a bare issue number
# like `224` match `1224` or `22456`; a word boundary will not.
void_text_names_item() {
  local text="$1" item="$2"
  [[ -n "$item" ]] || return 1
  grep -qiE "\\b$(void_item_regex "$item")\\b" <<<"$text" 2>/dev/null
}

# void_evidence_cited_pr_numbers EVIDENCE_TEXT
# Print, one per line, every PR number the free-text evidence names as "PR
# #123" or "pull request #123" (case-insensitive). This is deliberately
# narrower than "any `#N` in the text" — an evidence sentence citing an issue
# ("confirmed via #123 that…") is not a claim about a pull request, and
# treating it as one would refuse legitimate voids on a coincidence. Prints
# nothing when the text cites none.
void_evidence_cited_pr_numbers() {
  local text="$1" matches
  matches="$(grep -oiE '(pr|pull request)[[:space:]]*#[0-9]+' <<<"$text" 2>/dev/null || true)"
  grep -oE '[0-9]+' <<<"$matches" 2>/dev/null | sort -un || true
}

# void_evidence_cited_commit_shas EVIDENCE_TEXT
# Print, one per line, every commit-like hex string the free-text evidence
# cites as "commit <sha>" or "<ref>@<sha>" (the shape this repository's own
# void evidence already uses — see the `main@aad1405` example above). Requires
# 7-40 lowercase hex characters including at least one digit, so an ordinary
# hex-looking word ("cafebabe", "deadbeef") with no digit in it is not
# mistaken for a SHA.
void_evidence_cited_commit_shas() {
  local text="$1" by_word by_at
  by_word="$(grep -oiE 'commit[[:space:]]+[0-9a-f]{7,40}\b' <<<"$text" 2>/dev/null \
    | grep -oE '[0-9a-f]{7,40}$' 2>/dev/null || true)"
  by_at="$(grep -oE '@[0-9a-f]{7,40}\b' <<<"$text" 2>/dev/null \
    | grep -oE '[0-9a-f]{7,40}$' 2>/dev/null || true)"
  printf '%s\n%s\n' "$by_word" "$by_at" | grep -E '[0-9]' 2>/dev/null | sort -u || true
}

# void_pr_matches_item SLUG NUM ITEM
# Test one cited PR against the item it is supposed to corroborate: fetched
# live from the API — never from a gathered candidate list, so this works
# identically for a stage that has no such list (the Enabler, the
# Implementor) — and checked for ITEM in its body or its head branch, the same
# two places `scripts/gather-*.sh` reads to associate a PR with an item in the
# first place. Prints nothing and returns 0 on a match; prints a one-line
# reason and returns 1 otherwise, including when the PR cannot be read at all
# — an unreadable citation corroborates nothing.
#
# One item shape needs no fetch at all: a finishing-source item *is* a pull
# request. The gatherers mint its id from the PR's own number —
# `pr-<n>-abandoned-<head-sha>`, `pr-<n>-review-<review-id>`,
# `pr-<n>-conflict-<head-sha>` (scripts/gather-abandoned-drafts.sh,
# gather-review-feedback.sh, gather-merge-conflicts.sh) — so citing that very
# pull request is not a loose association, it is the item's own definition.
# Nothing will ever write `pr-205-abandoned-1a2b3c4d5e6f` in PR #205's body or
# branch name, so the body/branch test below would refuse the most natural
# evidence these items can carry — the same pull request `void_candidate_prs`
# then reads the diff of. That refusal would fall precisely on the sources the
# guard corroborates best, so the id is read for what it already says.
void_pr_matches_item() {
  local slug="$1" num="$2" item="$3" gh_bin="${VOID_GUARD_GH:-gh}"
  local pr_json body head_ref

  if grep -qiE "^pr-$num-" <<<"$item" 2>/dev/null; then
    return 0
  fi

  pr_json="$("$gh_bin" api "repos/$slug/pulls/$num" 2>/dev/null)" || pr_json=""
  if [[ -z "$pr_json" ]]; then
    printf 'PR #%s in %s, cited as evidence, could not be read' "$num" "$slug"
    return 1
  fi
  body="$(jq -r '.body // ""' <<<"$pr_json" 2>/dev/null || true)"
  head_ref="$(jq -r '.head.ref // ""' <<<"$pr_json" 2>/dev/null || true)"
  if void_text_names_item "$body
$head_ref" "$item"; then
    return 0
  fi
  printf 'fabricated citation: PR #%s in %s (branch %s) references neither its body nor its branch name with item %s' \
    "$num" "$slug" "${head_ref:-?}" "$item"
  return 1
}

# void_commit_matches_item SLUG SHA ITEM
# Test one cited commit against the item it is supposed to corroborate. Two
# facts must both hold:
#
#   1. SHA is an ancestor of the repository's default branch — via the
#      compare API rather than a local clone, since this guard runs from
#      wherever the writing stage runs, not necessarily inside a checkout of
#      SLUG. `compare/SHA...default_branch` reports `identical` or `ahead`
#      exactly when default_branch contains everything SHA does — the
#      definition of "SHA has already landed".
#   2. Something ties SHA to ITEM: its own commit message names it, or a pull
#      request GitHub associates with it does (checked the same way a cited PR
#      is — `void_pr_matches_item`). A squash-merge commit's message is the
#      PR title, which does not reliably repeat an item id, so the associated-
#      PR fallback is not optional polish; without it almost every genuine
#      commit citation would be refused.
#
# Prints nothing and returns 0 when both hold; prints a one-line reason and
# returns 1 otherwise.
void_commit_matches_item() {
  local slug="$1" sha="$2" item="$3" gh_bin="${VOID_GUARD_GH:-gh}"
  local default_branch cmp_json status commit_json message num

  default_branch="$("$gh_bin" api "repos/$slug" --jq '.default_branch' 2>/dev/null)"
  [[ -n "$default_branch" ]] || default_branch="main"

  cmp_json="$("$gh_bin" api "repos/$slug/compare/$sha...$default_branch" 2>/dev/null)" || cmp_json=""
  if [[ -z "$cmp_json" ]]; then
    printf 'commit %s in %s, cited as evidence, could not be compared against %s' \
      "$sha" "$slug" "$default_branch"
    return 1
  fi
  status="$(jq -r '.status // ""' <<<"$cmp_json" 2>/dev/null || true)"
  if [[ "$status" != "identical" && "$status" != "ahead" ]]; then
    printf 'commit %s in %s is not an ancestor of %s (compare status: %s)' \
      "$sha" "$slug" "$default_branch" "${status:-unreadable}"
    return 1
  fi

  commit_json="$("$gh_bin" api "repos/$slug/commits/$sha" 2>/dev/null)" || commit_json=""
  message="$(jq -r '.commit.message // ""' <<<"$commit_json" 2>/dev/null || true)"
  if void_text_names_item "$message" "$item"; then
    return 0
  fi

  while IFS= read -r num; do
    [[ -n "$num" ]] || continue
    if void_pr_matches_item "$slug" "$num" "$item" >/dev/null; then
      return 0
    fi
  done < <("$gh_bin" api "repos/$slug/commits/$sha/pulls" --jq '.[].number' 2>/dev/null || true)

  printf 'commit %s in %s is on %s, but neither its message nor any pull request associated with it references item %s' \
    "$sha" "$slug" "$default_branch" "$item"
  return 1
}

# void_citation_reason ENTRY_JSON REPO_SLUG
# The corroboration requirement 34d's window exposed: evidence existing, and
# even resolving, is not the same as evidence *connecting to this item*. The
# Co-Ordinator once voided an item citing "PR #232 implemented all five
# rewrites" — #232 was a real, mergeable PR, so every check that had ever run
# against it (evidence non-empty, PR diff empty) passed. It belonged to a
# different item entirely. Nothing had ever asked whether the PR it cited was
# about *this* item.
#
# This asks exactly that, and it is what makes the guard usable by the
# Enabler and the Implementor as well as the Co-Ordinator: unlike
# `void_candidate_prs`, it needs no cycle-gathered candidate list — every
# citation is resolved live against the API — so a stage that never gathered
# candidates in the first place gets the same check.
#
# Prints nothing and returns 0 when the evidence cites no PR or commit at all
# (nothing to corroborate this way; the presence/resolvable rules above are
# what govern free prose), or when every citation it does make checks out.
# Prints a one-line reason and returns 1 the moment one citation does not —
# a partly-fabricated citation is a fabricated citation.
void_citation_reason() {
  local entry="$1" repo="$2" item evidence_text num sha reason

  item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
  evidence_text="$(void_entry_evidence "$entry")"
  [[ -n "$item" && -n "$evidence_text" ]] || return 0

  while IFS= read -r num; do
    [[ -n "$num" ]] || continue
    if [[ -z "$repo" ]]; then
      printf 'evidence cites PR #%s to corroborate against, but the entry names no repo' "$num"
      return 1
    fi
    if ! reason="$(void_pr_matches_item "$repo" "$num" "$item")"; then
      printf '%s' "$reason"
      return 1
    fi
  done < <(void_evidence_cited_pr_numbers "$evidence_text")

  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    if [[ -z "$repo" ]]; then
      printf 'evidence cites commit %s to corroborate against, but the entry names no repo' "$sha"
      return 1
    fi
    if ! reason="$(void_commit_matches_item "$repo" "$sha" "$item")"; then
      printf '%s' "$reason"
      return 1
    fi
  done < <(void_evidence_cited_commit_shas "$evidence_text")

  return 0
}

# void_guard_reason ENTRY_JSON REPOS_JSON
# Decide whether a void may be recorded as terminal. Shared by all three
# stages that write `item-void` (requirement 34d, extended by issue #243 from
# "the Co-Ordinator" to "every stage"): the Co-Ordinator passes REPOS_JSON, its
# gathered candidates, so `void_candidate_prs` below can also weigh in;
# the Enabler and the Implementor have no such list and call this with `[]`,
# which simply skips that one extra check — `void_citation_reason` above needs
# nothing from it, since it resolves every citation live.
#
# Prints nothing and returns 0 when it may. Prints a one-line reason and
# returns 1 when it may not — the line is written to be readable in a log event
# and on the dashboard without the reader having to reconstruct the cycle.
#
# Every failure mode returns 1, including the ones that are nobody's fault (an
# API that would not answer). Refusing costs a blocked item that the Enabler
# will look at; accepting costs an item nothing will ever look at again.
void_guard_reason() {
  local entry="$1" repos="${2:-[]}" gh_bin="${VOID_GUARD_GH:-gh}"
  local ref slug num files resolvable repo_slug resolve_reason citation_refusal

  if [[ -z "$(void_entry_evidence "$entry")" ]]; then
    printf 'no evidence recorded, and requirement 34c makes evidence what a terminal verdict is'
    return 1
  fi

  repo_slug="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"

  resolvable="$(void_entry_resolvable_evidence "$entry")"
  if [[ -n "$resolvable" ]]; then
    if [[ -z "$repo_slug" ]]; then
      printf 'evidence names %s to resolve against, but the entry names no repo' \
        "$(jq -r '.path' <<<"$resolvable")"
      return 1
    fi
    if ! resolve_reason="$(void_evidence_resolves "$resolvable" "$repo_slug")"; then
      printf 'unresolved: %s' "$resolve_reason"
      return 1
    fi
  fi

  if ! citation_refusal="$(void_citation_reason "$entry" "$repo_slug")"; then
    printf 'not corroborated: %s' "$citation_refusal"
    return 1
  fi

  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    slug="${ref%%#*}"
    num="${ref##*#}"
    files="$("$gh_bin" api "repos/$slug/pulls/$num/files" --jq 'length' 2>/dev/null)" || files=""
    if ! [[ "$files" =~ ^[0-9]+$ ]]; then
      printf 'PR #%s in %s could not be read, so "already done" is uncorroborated' "$num" "$slug"
      return 1
    fi
    if (( files > 0 )); then
      printf 'refuted: PR #%s in %s still changes %s file(s) against its base' \
        "$num" "$slug" "$files"
      return 1
    fi
  done < <(void_candidate_prs "$entry" "$repos")

  return 0
}
