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
# (review-feedback, merge-conflicts, dequeued, abandoned-drafts). For everything else —
# most tech-debt items, every review recommendation, a failed-runs entry —
# nothing tested the citation itself, only that the `evidence` field was
# non-empty, and a model willing to assert a false reason is just as willing
# to write a plausible-looking free-text citation for it (TD26072601). So a
# second, independent test resolves what it can: an `evidence` value shaped
# `{ref, path, expect, pattern}` names a specific file at a specific ref and a
# specific claim about it, which is exactly as checkable as a PR diff — fetch
# it and see. A citation that does not take that shape but names a PR or a
# commit is checked live against the item instead (`void_citation_reason`,
# below). One that takes neither shape — unstructured prose with no PR/commit
# citation, and not a finishing-source item whose own id names the pull
# request to finish — is refused outright (issue #413, WI-10): accepting it on
# the strength of merely being non-empty was TD26072601's own deliberate
# carve-out, and it is exactly the fall-through the shipped defect below
# walked through. A citation that does take a checkable shape but does not
# hold when fetched is refused too, on the same "uncorroborated is not
# innocent" reasoning as an unreadable PR.
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
#      Evidence naming "PR #N" or a commit SHA — or a GitHub PR/commit URL
#      (`https://github.com/<owner>/<repo>/pull/<n>` or `.../commit/<sha>`),
#      the form `gh pr view`/`gh pr create` print and so the one a model is
#      most likely to paste — is fetched live and checked for the item id in
#      the PR's body/branch, or the commit's message/associated PRs — see
#      `void_citation_reason` below. A bare "PR #N"/SHA citation resolves
#      against the entry's own `repo`, as before; a URL citation carries its
#      own `owner/repo` and is resolved against *that*, never against the
#      entry's `repo`, so a citation of another repository's PR is not tested
#      against the wrong repository. This is what requirement 34d was missing
#      before #243: a citation that merely *exists* is not corroboration, and
#      it is checked the same way for every stage, since it needs nothing but
#      the API and the citation itself.
#   4. **Evidence that fits none of the checkable shapes is refused, not
#      waved through** (issue #413, WI-10). Checks 1-3 above only ever
#      *strengthened* what a non-empty `evidence` field could pass with; until
#      now, prose carrying neither the structured shape nor a PR/commit
#      citation still passed on presence alone — the exact hole
#      `void_entry_resolvable_evidence`'s own comment named as a deliberate
#      carve-out (TD26072601), because closing it seemed to demand every void
#      fit one mould. It does not: `void_guard_reason` now accepts evidence in
#      exactly three checkable shapes — the structured shape (must resolve), a
#      PR/commit citation (must corroborate), or a finishing-source item whose
#      own id names the pull request to finish, corroborated the same way
#      `void_finishing_pr_reason` already corroborates one cited by the id
#      shortcut in check 3 — and refuses anything else outright, naming what
#      was missing. Prior art #243 closed the citation gap and left this one
#      open, on the reasoning that a human backstop (the `unvoided` label)
#      covered the residual; D18 retires that backstop, so the residual is
#      closed here instead.
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

# `DEPENDABOT_LOGIN`, `dependabot_bump_family` and `dependabot_newer_open_pr`
# — needed to re-derive a `pr-<n>-superseded-…` void's own claim live, below —
# are lib/dependabot-bump.sh's, sourced here rather than re-implemented
# (requirement 34a's one-definition rule). Self-contained, the same way
# lib/claim.sh sources its own dependencies, so this file works whether
# agent-cycle.sh sources it first or a test sources lib/void-guard.sh alone.
VOID_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/dependabot-bump.sh
. "$VOID_GUARD_DIR/lib/dependabot-bump.sh"

# `GITHUB_PR_LIST_LIMIT` and `github_pr_list_truncated` — the stated bound the
# superseded-shape corroboration's listing asks for, and the check that notices
# when it came back at that bound — are lib/github-limit.sh's, sourced for the
# same self-containment reason as above. Sourcing it also shadows `gh` with its
# rate-limit-aware wrapper, which changes nothing for any current consumer:
# agent-cycle.sh sources the same file itself before this one, and the tests
# that source this file alone reach their stubs through `VOID_GUARD_GH`.
# shellcheck source=lib/github-limit.sh
. "$VOID_GUARD_DIR/lib/github-limit.sh"

# `merge_queue_probe` — needed to re-derive a `pr-<n>-dequeued-…` void's own
# claim live, below (TD-PPagop-26081409) — is lib/merge-queue.sh's, sourced
# for the same self-containment reason as the two above. Its own default
# `gh_bin` reads `MERGE_QUEUE_GH`, never `VOID_GUARD_GH` directly, so
# `void_finishing_pr_reason` passes `MERGE_QUEUE_GH="$gh_bin"` at the one call
# site that needs it (below) rather than pinning it here at source time: this
# file may be sourced before a caller (a test, `agent-cycle.sh`) has decided
# what `VOID_GUARD_GH` even is, and a static pin here would freeze the wrong
# value in — the same reason `gh_bin` itself is resolved fresh inside each
# function rather than once at the top of the file.
# shellcheck source=lib/merge-queue.sh
. "$VOID_GUARD_DIR/lib/merge-queue.sh"

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
# object, or absent. That "anything else" bucket is where free-text citations
# live (TD26072601) — `void_guard_reason` checks those separately, via
# `void_citation_reason`, and refuses evidence that is neither shape (issue
# #413, WI-10; this function's own job is only to recognise the structured
# shape, not to decide what happens when evidence takes neither).
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
# of repos each carrying its `findings`, `review_feedback`, `abandoned_drafts`,
# `merge_conflicts` and `dequeued` arrays. Those are the only PRs in scope, and that is the
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
           + (.abandoned_drafts // []) + (.merge_conflicts // []) + (.dequeued // []))[]
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

# void_evidence_cited_pr_numbers EVIDENCE_TEXT DEFAULT_SLUG
# Print, one per line as `<owner/repo>#<number>`, every PR the free-text
# evidence cites — as "PR #123" or "pull request #123" (case-insensitive,
# bare form, resolved against DEFAULT_SLUG — the entry's own repo, exactly as
# before this took a slug at all), or as a GitHub PR URL
# (`https://github.com/<owner>/<repo>/pull/<n>`, the form `gh pr view`/`gh pr
# create` print, and so the one a model pasting evidence is most likely to
# use), which carries its own `owner/repo` and is resolved against *that*
# regardless of DEFAULT_SLUG. A bare citation is still printed even when
# DEFAULT_SLUG is empty — as `#123`, an empty slug — so the caller can still
# report the "entry names no repo" refusal it always has; see
# `void_citation_reason`.
#
# The bare form is deliberately narrower than "any `#N` in the text" — an
# evidence sentence citing an issue ("confirmed via #123 that…") is not a
# claim about a pull request, and treating it as one would refuse legitimate
# voids on a coincidence. Prints nothing when the text cites none.
void_evidence_cited_pr_numbers() {
  local text="$1" default_slug="$2" line num slug
  {
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      num="$(grep -oE '[0-9]+' <<<"$line")"
      printf '%s#%s\n' "$default_slug" "$num"
    done < <(grep -oiE '(pr|pull request)[[:space:]]*#[0-9]+' <<<"$text" 2>/dev/null || true)

    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      slug="$(sed -E 's#^https://github\.com/([^/]+/[^/]+)/pull/.*#\1#' <<<"$line")"
      num="$(sed -E 's#.*/pull/([0-9]+)$#\1#' <<<"$line")"
      printf '%s#%s\n' "$slug" "$num"
    done < <(grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' <<<"$text" 2>/dev/null || true)
  } | sort -u
}

# void_evidence_cited_commit_shas EVIDENCE_TEXT DEFAULT_SLUG
# Print, one per line as `<owner/repo>#<sha>`, every commit the free-text
# evidence cites — as "commit <sha>" or "<ref>@<sha>" (the shape this
# repository's own void evidence already uses — see the `main@aad1405`
# example above; bare form, resolved against DEFAULT_SLUG, exactly as before
# this took a slug at all), or as a GitHub commit URL
# (`https://github.com/<owner>/<repo>/commit/<sha>`, the form `gh` itself
# prints), which carries its own `owner/repo` and is resolved against *that*
# regardless of DEFAULT_SLUG. A bare citation is still printed even when
# DEFAULT_SLUG is empty — as `#<sha>` — so the caller can still report the
# "entry names no repo" refusal it always has; see `void_citation_reason`.
#
# The bare form requires 7-40 lowercase hex characters including at least one
# digit, so an ordinary hex-looking word ("cafebabe", "deadbeef") with no
# digit in it is not mistaken for a SHA. The URL form needs neither rule — a
# `/commit/` path is already unambiguous — and so takes the SHA in either
# case, which the pattern and the extraction below must agree on: a grep that
# matched `/commit/<UPPERCASE>` while the extraction did not would yield a
# pair whose "sha" was the whole URL, and refuse an honest citation with an
# unreadable reason.
void_evidence_cited_commit_shas() {
  local text="$1" default_slug="$2" by_word by_at line sha slug
  by_word="$(grep -oiE 'commit[[:space:]]+[0-9a-f]{7,40}\b' <<<"$text" 2>/dev/null \
    | grep -oE '[0-9a-f]{7,40}$' 2>/dev/null || true)"
  by_at="$(grep -oE '@[0-9a-f]{7,40}\b' <<<"$text" 2>/dev/null \
    | grep -oE '[0-9a-f]{7,40}$' 2>/dev/null || true)"
  {
    while IFS= read -r sha; do
      [[ -n "$sha" ]] || continue
      printf '%s#%s\n' "$default_slug" "$sha"
    done < <(printf '%s\n%s\n' "$by_word" "$by_at" | grep -E '[0-9]' 2>/dev/null || true)

    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      slug="$(sed -E 's#^https://github\.com/([^/]+/[^/]+)/commit/.*#\1#' <<<"$line")"
      sha="$(sed -E 's#.*/commit/([0-9a-fA-F]+)$#\1#' <<<"$line")"
      printf '%s#%s\n' "$slug" "$sha"
    done < <(grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/commit/[0-9a-fA-F]{7,40}\b' <<<"$text" 2>/dev/null || true)
  } | sort -u
}

# void_finishing_item_pr ITEM
# Print the pull request number a finishing-source item id embeds, and
# return 0 — ITEM shaped `pr-<n>-abandoned-<head-sha>`, `pr-<n>-review-
# <review-id>`, `pr-<n>-conflict-<head-sha>`, `pr-<n>-superseded-<head-sha>`
# or `pr-<n>-dequeued-<head-sha>` (scripts/gather-abandoned-drafts.sh,
# gather-review-feedback.sh, gather-merge-conflicts.sh, gather-dequeued.sh)
# prints `<n>`. Prints nothing and returns 1 when
# ITEM is not shaped that way — an ordinary tech-debt id, issue number or
# review recommendation mints nothing a PR number can be read out of.
void_finishing_item_pr() {
  local item="$1" num
  num="$(grep -oiE '^pr-[0-9]+-' <<<"$item" 2>/dev/null | grep -oE '[0-9]+' || true)"
  [[ -n "$num" ]] || return 1
  printf '%s' "$num"
}

# void_finishing_item_shape ITEM
# Print which of the four finishing sources minted ITEM's id — `abandoned`,
# `review`, `conflict`, `superseded` or `dequeued` — and return 0. Prints
# nothing and returns 1 for anything else, including a `pr-<n>-…` id whose
# middle word is none of those: an unrecognised shape gets the strictest
# reading below, never the most permissive one. Matched and reported
# case-insensitively, the same discipline `void_candidate_prs` applies to
# item ids — the gatherers mint these in lower case, but what reaches an
# entry is whatever the writer typed.
void_finishing_item_shape() {
  local item="$1" shape
  shape="$(grep -oiE '^pr-[0-9]+-(abandoned|review|conflict|superseded|dequeued)-' <<<"$item" 2>/dev/null || true)"
  [[ -n "$shape" ]] || return 1
  shape="${shape#*-}"
  shape="${shape#*-}"
  shape="${shape%-}"
  printf '%s' "${shape,,}"
}

# void_draft_obsolete_flag_reason SLUG ITEM CTX_JSON
# The machine-checkable alternative to the human `obsolete` label (issue
# #413, WI-10; design doc §5.5): a two-touch confirmation that a draft pull
# request is unwanted, usable only where the installation trusts the fleet
# enough to act on it without a human's label — `merge_autonomy_effective_
# level` `agent-merges-all` for this repo, which the Script resolves once
# and hands down as CTX_JSON's `merge_autonomy_level`, never re-derived
# here (this file has no access to config or the kill switch, by design —
# see lib/merge-autonomy.sh).
#
# Prints nothing and returns 0 the moment one `draft-obsolete-flagged` event
# in CTX_JSON's `flags` array — `{repo, item, pr, evidence, cycle, node,
# ts}`, written by agent-cycle.sh when an earlier, independent Enabler
# verdict flagged this same draft as unwanted (a flag is never itself a
# void, so this can never be an engagement corroborating its own judgement)
# — corroborates, on **all** of:
#
#   - the flag names this SLUG (case-insensitive) and this ITEM;
#   - the flag's `cycle` differs from CTX_JSON's own `cycle` — a second,
#     independent look, never the same engagement re-asserting itself;
#   - the flag's `ts` is at least 24 hours before CTX_JSON's `now_epoch` —
#     time for anything that would unflag it (a push, a comment) to have
#     happened; a flag younger than that has not had that time and does not
#     corroborate yet, however the other three conditions read;
#   - the flag's own `evidence`, exactly like the current void's own
#     (CTX_JSON's `current_structured_resolved`, computed by
#     `void_guard_reason` and never trusted from the flag's own say-so),
#     is the structured `{ref, path, expect, pattern}` shape and resolves
#     live against SLUG. Free prose does not corroborate here even though it
#     can corroborate an ordinary void (`void_citation_reason`) — this path
#     is not gated behind a human's review at all, so both touches earn the
#     strictest evidence bar this guard has.
#
# Prints a one-line reason and returns 1 when CTX_JSON's own level is not
# `agent-merges-all`, when the current void's evidence is not itself
# structured-and-resolving, or when no flag satisfies every condition above
# — the caller (`void_finishing_pr_reason`) treats this the same as an
# absent `obsolete` label: silently falls through to the diff test, since
# this is one alternative among several, not a claim about the PR's state
# on its own.
void_draft_obsolete_flag_reason() {
  local slug="$1" item="$2" ctx="${3:-{\}}"
  local level structured_ok cycle now_epoch flags_json n i flag
  local f_repo f_item f_cycle f_ts f_ts_epoch f_resolvable

  level="$(jq -r '.merge_autonomy_level // ""' <<<"$ctx" 2>/dev/null || true)"
  if [[ "$level" != "agent-merges-all" ]]; then
    printf 'merge autonomy for %s is not agent-merges-all' "$slug"
    return 1
  fi

  structured_ok="$(jq -r '.current_structured_resolved // false' <<<"$ctx" 2>/dev/null || true)"
  if [[ "$structured_ok" != "true" ]]; then
    printf 'this void'"'"'s own evidence is not the structured shape, resolved live'
    return 1
  fi

  cycle="$(jq -r '.cycle // ""' <<<"$ctx" 2>/dev/null || true)"
  now_epoch="$(jq -r '.now_epoch // empty' <<<"$ctx" 2>/dev/null || true)"
  [[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch="$(date -u +%s)"
  flags_json="$(jq -c '.flags // []' <<<"$ctx" 2>/dev/null || true)"
  jq -e 'type == "array"' <<<"$flags_json" >/dev/null 2>&1 || flags_json='[]'

  n="$(jq 'length' <<<"$flags_json" 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  for (( i = 0; i < n; i++ )); do
    flag="$(jq -c --argjson i "$i" '.[$i]' <<<"$flags_json" 2>/dev/null || true)"
    [[ -n "$flag" ]] || continue
    f_repo="$(jq -r '.repo // ""' <<<"$flag" 2>/dev/null || true)"
    f_item="$(jq -r '.item // ""' <<<"$flag" 2>/dev/null || true)"
    f_cycle="$(jq -r '.cycle // ""' <<<"$flag" 2>/dev/null || true)"
    f_ts="$(jq -r '.ts // ""' <<<"$flag" 2>/dev/null || true)"

    [[ "${f_repo,,}" == "${slug,,}" ]] || continue
    [[ "${f_item,,}" == "${item,,}" ]] || continue
    [[ -n "$f_cycle" && "$f_cycle" != "$cycle" ]] || continue

    f_ts_epoch="$(date -u -d "$f_ts" +%s 2>/dev/null || true)"
    [[ "$f_ts_epoch" =~ ^[0-9]+$ ]] || continue
    (( f_ts_epoch <= now_epoch - 86400 )) || continue

    f_resolvable="$(void_entry_resolvable_evidence "$(jq -c '{evidence: (.evidence // null)}' <<<"$flag" 2>/dev/null)")"
    [[ -n "$f_resolvable" ]] || continue
    void_evidence_resolves "$f_resolvable" "$slug" >/dev/null 2>&1 || continue

    return 0
  done

  printf 'no draft-obsolete-flagged event for %s corroborates (agent-merges-all, but none is ≥24h old, from a different cycle, with structured evidence resolving on both touches)' \
    "$item"
  return 1
}

# void_finishing_pr_reason SLUG NUM ITEM [CTX_JSON]
# Decide whether NUM, the pull request a finishing-source ITEM was minted
# from, corroborates a void of that item. Prints nothing and returns 0 when
# it does; prints a one-line reason and returns 1 otherwise.
#
# CTX_JSON (default `{}`) carries what the machine `obsolete` alternative
# below needs and nothing else — `merge_autonomy_level`, `current_
# structured_resolved`, `cycle`, `now_epoch`, `flags` — all optional; any
# field it omits simply keeps that alternative unreachable rather than
# failing. Every existing caller keeps working with none of this: three
# positional arguments is still a complete, valid call.
#
# A finishing-source item exists only to finish one specific, named pull
# request, so the void is decided against that PR's own live state, fetched
# here (never from a gathered candidate list, so this works identically for a
# stage that has no such list — the Enabler, the Implementor). A pull request
# the API will not answer for is refused whatever the shape: an unreadable
# citation corroborates nothing.
#
# **Merged or otherwise closed corroborates every shape outright.** There is
# no more finishing to do on a pull request that will never land via this
# route, whatever state the underlying work is in. GitHub reports merged and
# closed-unmerged alike under `state: "closed"`; a void does not need to know
# which.
#
# **An open pull request is read against what its own shape claims, and the
# strictness is calibrated to what requirement 34k then does with the void:**
#
#   - `pr-<n>-abandoned-…`, `pr-<n>-review-…` — a corroborated void of these
#     makes 34k *close pull request `<n>`*, with a comment. That is a
#     destructive, human-visible act on someone's live branch, and closing one
#     on an unexamined claim is precisely how pull request #264 and its human
#     `CHANGES_REQUESTED` round were lost (TD-PPagop-26080901). So an open PR
#     is read two ways, either of which corroborates: an **empty diff against
#     its base** — whatever this item was to finish is already in the base, so
#     closing the PR discards nothing — or the pull request already carrying
#     the human-applied **`obsolete` label**, checked live off the same
#     fetch that read `state`, before the `/files` call below is ever made
#     (TD-PPagop-26081308). That label is the deliberate, corroborable "no
#     longer wanted" signal a diff can never be: no pipeline stage may ever
#     apply it (lib/labels.sh's catalogue comment, prompts/implementor.md's
#     prohibition) — a stage that could would be corroborating its own
#     judgement. **A machine-checkable alternative to the label** (issue
#     #413, WI-10, design doc §5.5) corroborates too, but only at
#     `merge_autonomy_effective_level` `agent-merges-all` for this repo
#     (CTX_JSON's `merge_autonomy_level`): a two-touch confirmation — a
#     `draft-obsolete-flagged` log event an earlier, independent Enabler
#     verdict left (see `void_draft_obsolete_flag_reason` below) — an
#     Enabler flagging a draft is not itself a void, so this is never the
#     same engagement corroborating its own judgement — read at least 24
#     hours old, from a different cycle than this void's own, with both
#     touches' evidence in the structured `{ref, path, expect, pattern}`
#     shape and resolving live. An open pull request with none of an empty
#     diff, the label, or a corroborating flag is refused and escalated:
#     that claim is a judgement no API call can corroborate on its own, and
#     a human is the right one to make it, either by resolving the item
#     honestly or by applying the label.
#   - `pr-<n>-conflict-…` — a corroborated void of this shape closes *nothing*
#     (requirement 34k excludes it, TD-PPagop-26080901: the void says the
#     **conflict** resolved, not the pull request, which stays a live PR of
#     ours). An empty diff is therefore not the claim being made, and
#     demanding one would refuse every honest void this shape can write. The
#     test is the mirror of the one that minted the item instead
#     (`gather-merge-conflicts.sh`): the void is refused only while the API
#     still reports the PR **definitively conflicting** (`mergeable: false`).
#     A `mergeable` GitHub has not finished computing (`null`) reads as not
#     definitively conflicting and is accepted, the same asymmetry the
#     gatherer chose in the other direction — it admits a candidate on
#     `CONFLICTING` and never on the transient `UNKNOWN`.
#   - `pr-<n>-dequeued-…` — a corroborated void of this shape also closes
#     *nothing* (requirement 34k excludes it too, TD-PPagop-26081409), for the
#     same reason as `-conflict-`: the void says the *dequeue* resolved, not
#     the pull request. The test again mirrors the one that minted the item
#     (`gather-dequeued.sh`): refused only while the pull request's *current*
#     head still matches the head SHA the item's own id embeds **and**
#     `lib/merge-queue.sh`'s `merge_queue_probe`, re-read live, still reports
#     it not re-queued. A head that has moved (a fix landed, whichever cycle's)
#     or a probe that cannot answer both read as resolved, the same
#     "ambiguous accepts" asymmetry the conflict shape's `null` mergeable gets.
#   - `pr-<n>-superseded-…` — a corroborated void of this shape *does* close
#     pull request `<n>` (requirement 34k's ordinary act-on-void path, once
#     the id shape distinguishes it from `-conflict-`). Closing a Dependabot
#     PR is not the same act as closing a human-visible PR of ours — nobody is
#     mid-review on the bot's own branch — but it is still an irreversible,
#     human-visible act on GitHub, so it earns its own live check rather than
#     the conflict shape's mergeability test, which proves the wrong claim
#     here (a superseded bump can be superseded whether or not it still
#     conflicts). Accepted only when **both** hold, re-derived live and never
#     read off the entry's own `evidence`: the PR's author is
#     `dependabot[bot]` (`DEPENDABOT_LOGIN` is the GraphQL form the gatherer
#     reads; the REST fetch here reports the same account this way — see
#     `lib/dependabot-bump.sh`), and `dependabot_newer_open_pr`, re-run now
#     against the repository's *currently* open Dependabot pull requests,
#     still names a strictly-newer open bump of the same family. Either half
#     failing refuses with a reason naming which one. The listing that answers
#     the second half is bounded at `GITHUB_PR_LIST_LIMIT` — the same stated
#     cap the gatherer read at (lib/github-limit.sh) — and an empty answer
#     from a listing at that cap refuses naming the cap, because "no newer
#     bump in the first N" is not "no newer bump". This is the excuse
#     `-conflict-` used to carry for Dependabot before this shape existed
#     (TD-PPagop-26081304) — moved here because the claim it excuses
#     ("superseded") now has its own shape to be corroborated against, rather
#     than riding on a shape whose own test it can never honestly pass.
void_finishing_pr_reason() {
  local slug="$1" num="$2" item="$3" ctx="${4:-{\}}" gh_bin="${VOID_GUARD_GH:-gh}"
  local pr_json state shape login files head_ref dependabot_open
  local item_sha head_sha mq_probe

  pr_json="$("$gh_bin" api "repos/$slug/pulls/$num" 2>/dev/null)" || pr_json=""
  if [[ -z "$pr_json" ]]; then
    printf 'PR #%s in %s, which item %s names as the pull request to finish, could not be read' \
      "$num" "$slug" "$item"
    return 1
  fi

  state="$(jq -r '.state // ""' <<<"$pr_json" 2>/dev/null || true)"
  if [[ "$state" == "closed" ]]; then
    return 0
  fi

  shape="$(void_finishing_item_shape "$item" || true)"

  if [[ "$shape" == "conflict" ]]; then
    if [[ "$(jq -r 'if .mergeable == false then "conflicting" else "" end' \
      <<<"$pr_json" 2>/dev/null || true)" != "conflicting" ]]; then
      return 0
    fi
    printf 'refuted: PR #%s in %s, whose conflict item %s reports resolved, is still conflicting against its base' \
      "$num" "$slug" "$item"
    return 1
  fi

  if [[ "$shape" == "dequeued" ]]; then
    # Mirror of the conflict shape's own asymmetry (closes nothing —
    # requirement 34k excludes this shape too, TD-PPagop-26081409): refuse
    # only while the pull request is still exactly the state this item
    # names — same head, still not re-queued. The item's own head SHA
    # (scripts/gather-dequeued.sh mints `pr-<n>-dequeued-<head-sha>`, the
    # same `head_sha:0:12` scoping gather-merge-conflicts.sh's own refs use)
    # is read out of the id itself, never trusted from the entry's own
    # `evidence`, and compared against the pull request's *current* head —
    # a probe that cannot answer, or a head that has moved since (a fix
    # landed, whether by this cycle or another), corroborates, the same
    # asymmetry the `mergeable`-null case gets above.
    item_sha="$(grep -oiE '[0-9a-f]{6,40}$' <<<"$item" 2>/dev/null || true)"
    head_sha="$(jq -r '.head.sha // ""' <<<"$pr_json" 2>/dev/null || true)"
    if [[ -n "$item_sha" && -n "$head_sha" ]] \
      && [[ "${head_sha,,}" == "${item_sha,,}"* ]]; then
      mq_probe="$(MERGE_QUEUE_GH="$gh_bin" merge_queue_probe "$slug" "$num" 2>/dev/null || true)"
      if [[ -n "$mq_probe" ]] \
        && [[ "$(jq -r '.queued' <<<"$mq_probe" 2>/dev/null || true)" == "false" ]]; then
        printf 'refuted: PR #%s in %s, whose dequeue item %s reports resolved, is still at the same head and not re-queued' \
          "$num" "$slug" "$item"
        return 1
      fi
    fi
    return 0
  fi

  if [[ "$shape" == "superseded" ]]; then
    login="$(jq -r '.user.login // ""' <<<"$pr_json" 2>/dev/null || true)"
    if [[ "$login" != "dependabot[bot]" ]]; then
      printf 'refuted: PR #%s in %s, whose supersession item %s claims a Dependabot bump, is authored by %s' \
        "$num" "$slug" "$item" "${login:-an unreadable author}"
      return 1
    fi
    head_ref="$(jq -r '.head.ref // ""' <<<"$pr_json" 2>/dev/null || true)"
    # Bounded at the same stated cap as the gatherer that minted the item
    # (lib/github-limit.sh), never `gh`'s undeclared default of 30 — an
    # unpaged read deciding whether a pull request gets closed must not page
    # differently from the read that made the claim. A bump *found* in a
    # listing at the cap is real regardless of what the cap hid, so a
    # truncated listing can only make the refusal below more common, never a
    # close — and when it is the reason for the refusal, the reason says so.
    dependabot_open="$("$gh_bin" pr list -R "$slug" --state open --author "$DEPENDABOT_LOGIN" \
      --limit "$GITHUB_PR_LIST_LIMIT" \
      --json number,headRefName 2>/dev/null)" || dependabot_open=""
    jq -e 'type == "array"' <<<"$dependabot_open" >/dev/null 2>&1 || dependabot_open='[]'
    if [[ -z "$(dependabot_newer_open_pr "$num" "$head_ref" "$dependabot_open")" ]]; then
      if github_pr_list_truncated "$(jq 'length' <<<"$dependabot_open")"; then
        printf 'refuted: PR #%s in %s, whose supersession item %s claims a newer open Dependabot bump of the same family, shows none in a listing that came back at its %s-item cap — the bump may sit beyond it, so this refuses rather than guesses' \
          "$num" "$slug" "$item" "$GITHUB_PR_LIST_LIMIT"
        return 1
      fi
      printf 'refuted: PR #%s in %s, whose supersession item %s claims a newer open Dependabot bump of the same family, has none open now' \
        "$num" "$slug" "$item"
      return 1
    fi
    return 0
  fi

  # The human-applied `obsolete` label corroborates an `-abandoned-`/
  # `-review-` shape outright — read live off `pr_json`, the fetch already
  # made above, before the `/files` call below ever runs, so a labelled draft
  # never pays for a diff nobody needs read. No pipeline stage may ever apply
  # this label (lib/labels.sh, prompts/implementor.md), so its presence here
  # is always a human's own judgement, never the guard corroborating itself.
  if [[ "$shape" == "abandoned" || "$shape" == "review" ]]; then
    if jq -e '[(.labels // [])[].name // "" | ascii_downcase] | index("obsolete") != null' \
         <<<"$pr_json" >/dev/null 2>&1; then
      return 0
    fi
    if void_draft_obsolete_flag_reason "$slug" "$item" "$ctx" >/dev/null 2>&1; then
      return 0
    fi
  fi

  files="$("$gh_bin" api "repos/$slug/pulls/$num/files" --jq 'length' 2>/dev/null)" || files=""
  if ! [[ "$files" =~ ^[0-9]+$ ]]; then
    printf 'PR #%s in %s, which item %s names as the pull request to finish, could not be read' \
      "$num" "$slug" "$item"
    return 1
  fi
  if (( files > 0 )); then
    printf 'refuted: PR #%s in %s, which item %s names as the pull request to finish, still changes %s file(s) against its base' \
      "$num" "$slug" "$item" "$files"
    return 1
  fi

  return 0
}

# void_pr_matches_item SLUG NUM ITEM ENTRY_REPO [CTX_JSON]
# Test one cited PR against the item it is supposed to corroborate: fetched
# live from the API — never from a gathered candidate list, so this works
# identically for a stage that has no such list (the Enabler, the
# Implementor) — and checked for ITEM in its body or its head branch, the same
# two places `scripts/gather-*.sh` reads to associate a PR with an item in the
# first place. Prints nothing and returns 0 on a match; prints a one-line
# reason and returns 1 otherwise, including when the PR cannot be read at all
# — an unreadable citation corroborates nothing.
#
# One item shape is corroborated differently: a finishing-source item *is* a
# pull request. The gatherers mint its id from the PR's own number —
# `pr-<n>-abandoned-<head-sha>`, `pr-<n>-review-<review-id>`,
# `pr-<n>-conflict-<head-sha>`, `pr-<n>-superseded-<head-sha>`,
# `pr-<n>-dequeued-<head-sha>`
# (scripts/gather-abandoned-drafts.sh, gather-review-feedback.sh,
# gather-merge-conflicts.sh, gather-dequeued.sh) — so citing that very pull
# request is not a loose association, it is the item's own definition.
# Nothing will ever write `pr-205-abandoned-1a2b3c4d5e6f` in PR #205's body or
# branch name, so the body/branch test below would refuse the most natural
# evidence these items can carry. That refusal would fall precisely on the
# sources the guard corroborates best, so the id is read for what it already
# says: NUM is handed to `void_finishing_pr_reason` instead of to the
# body/branch test, which corroborates it against the PR's own live state
# (TD-PPagop-26080807) rather than accepting the id's say-so with no fetch at
# all, as this once did.
#
# That live check is the whole of the corroboration these items get, in every
# stage — `void_candidate_prs` never backstopped them and cannot. It matches a
# candidate's `.item`, and a finishing-source id is never a candidate's
# `.item`: the gatherers put it in `.ref` and leave `.item` as whatever
# register id the branch or body named, or `null`
# (`scripts/gather-abandoned-drafts.sh`, `gather-review-feedback.sh`,
# `gather-merge-conflicts.sh`, `gather-dequeued.sh`). So the Co-Ordinator's extra candidate-diff test
# is silent on this shape exactly as the Enabler's and the Implementor's
# `repos: []` calls are, which is why the fetch here has to be the thing that
# looks.
#
# What the id says is scoped, though: it was minted from a pull request in
# ENTRY_REPO — the entry's own `repo` — and carries no slug of its own, so the
# shortcut is taken only when SLUG *is* ENTRY_REPO (case-insensitive, as
# GitHub treats slugs). A URL citation naming another repository's pull
# request `<n>` merely coincides on the number, and an entry naming no repo
# minted nothing; both fall through to the body/branch test below, which can
# still corroborate them the ordinary way (issue #290).
void_pr_matches_item() {
  local slug="$1" num="$2" item="$3" entry_repo="${4-}" ctx="${5:-{\}}"
  local gh_bin="${VOID_GUARD_GH:-gh}" pr_json body head_ref reason

  if [[ -n "$entry_repo" && "${slug,,}" == "${entry_repo,,}" ]] \
    && [[ "$(void_finishing_item_pr "$item")" == "$num" ]]; then
    if reason="$(void_finishing_pr_reason "$slug" "$num" "$item" "$ctx")"; then
      return 0
    fi
    printf '%s' "$reason"
    return 1
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

# void_commit_matches_item SLUG SHA ITEM ENTRY_REPO [CTX_JSON]
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
#      is — `void_pr_matches_item`, with ENTRY_REPO passed through, since its
#      id shortcut needs the entry's own repo to compare SLUG against). A
#      squash-merge commit's message is the PR title, which does not reliably
#      repeat an item id, so the associated-PR fallback is not optional
#      polish; without it almost every genuine commit citation would be
#      refused.
#
# Prints nothing and returns 0 when both hold; prints a one-line reason and
# returns 1 otherwise.
void_commit_matches_item() {
  local slug="$1" sha="$2" item="$3" entry_repo="${4-}" ctx="${5:-{\}}" gh_bin="${VOID_GUARD_GH:-gh}"
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
    if void_pr_matches_item "$slug" "$num" "$item" "$entry_repo" "$ctx" >/dev/null; then
      return 0
    fi
  done < <("$gh_bin" api "repos/$slug/commits/$sha/pulls" --jq '.[].number' 2>/dev/null || true)

  printf 'commit %s in %s is on %s, but neither its message nor any pull request associated with it references item %s' \
    "$sha" "$slug" "$default_branch" "$item"
  return 1
}

# void_citation_reason ENTRY_JSON REPO_SLUG [CTX_JSON]
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
# The extractors return `slug#number`/`slug#sha` pairs: a bare "PR #N"/SHA
# citation carries REPO_SLUG (possibly empty), while a URL citation carries
# the `owner/repo` the URL itself names. Each pair is resolved against its
# own slug, never against REPO_SLUG — a cross-repo URL citation would
# otherwise be tested against the wrong repository, and REPO_SLUG is only
# what a *bare* citation falls back to. REPO_SLUG is also handed to each
# check as the entry's own repo: it is what gates `void_pr_matches_item`'s
# finishing-source id shortcut to citations of the entry's own repository
# (issue #290).
#
# Prints nothing and returns 0 when the evidence cites no PR or commit at all
# (nothing to corroborate this way; the presence/resolvable rules above are
# what govern free prose), or when every citation it does make checks out.
# Prints a one-line reason and returns 1 the moment one citation does not —
# a partly-fabricated citation is a fabricated citation.
void_citation_reason() {
  local entry="$1" repo="$2" ctx="${3:-{\}}" item evidence_text pair slug num sha reason

  item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
  evidence_text="$(void_entry_evidence "$entry")"
  [[ -n "$item" && -n "$evidence_text" ]] || return 0

  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    slug="${pair%%#*}"
    num="${pair##*#}"
    if [[ -z "$slug" ]]; then
      printf 'evidence cites PR #%s to corroborate against, but the entry names no repo' "$num"
      return 1
    fi
    if ! reason="$(void_pr_matches_item "$slug" "$num" "$item" "$repo" "$ctx")"; then
      printf '%s' "$reason"
      return 1
    fi
  done < <(void_evidence_cited_pr_numbers "$evidence_text" "$repo")

  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    slug="${pair%%#*}"
    sha="${pair##*#}"
    if [[ -z "$slug" ]]; then
      printf 'evidence cites commit %s to corroborate against, but the entry names no repo' "$sha"
      return 1
    fi
    if ! reason="$(void_commit_matches_item "$slug" "$sha" "$item" "$repo" "$ctx")"; then
      printf '%s' "$reason"
      return 1
    fi
  done < <(void_evidence_cited_commit_shas "$evidence_text" "$repo")

  return 0
}

# void_guard_reason ENTRY_JSON REPOS_JSON [CTX_JSON]
# Decide whether a void may be recorded as terminal. Shared by all three
# stages that write `item-void` (requirement 34d, extended by issue #243 from
# "the Co-Ordinator" to "every stage"): the Co-Ordinator passes REPOS_JSON, its
# gathered candidates, so `void_candidate_prs` below can also weigh in;
# the Enabler and the Implementor have no such list and call this with `[]`,
# which simply skips that one extra check — the checks below need nothing
# from it, since every one resolves live.
#
# CTX_JSON (default `{}`) carries what the machine `obsolete` alternative
# needs — `merge_autonomy_level`, `cycle`, `now_epoch`, `flags` (issue #413,
# WI-10; see `void_draft_obsolete_flag_reason`) — computed once by the Script
# and handed down unchanged; every field is optional, and omitting all of
# them (every caller before WI-10, and both `void_guard_reason` calls in this
# file's own tests unless a test says otherwise) simply keeps that
# alternative unreachable. This function adds its own `current_structured_
# resolved` to what it forwards to `void_citation_reason` and the direct
# finishing-item check below — never trusted from the caller, always derived
# from whether the structured-shape check just below actually passed.
#
# Prints nothing and returns 0 when it may. Prints a one-line reason and
# returns 1 when it may not — the line is written to be readable in a log event
# and on the dashboard without the reader having to reconstruct the cycle.
#
# Every failure mode returns 1, including the ones that are nobody's fault (an
# API that would not answer). Refusing costs a blocked item that the Enabler
# will look at; accepting costs an item nothing will ever look at again.
#
# Accepted evidence is a closed list (issue #413, WI-10 — before this, prose
# with neither shape below passed on being merely non-empty, which is exactly
# how the shipped defect at the top of this file was recorded): (a) the
# structured `{ref, path, expect, pattern}` shape, checked here, which must
# resolve; (b) free text carrying at least one PR/commit citation, checked via
# `void_citation_reason`, every one of which must corroborate; (c) a
# finishing-source item — one whose own id names the pull request it exists to
# finish — corroborated directly against that pull request's own live state
# via `void_finishing_pr_reason`, independently of whatever the entry's
# `evidence` field says, since these items were always decided against the
# named pull request rather than against the prose. All three are checked
# whenever they apply — a finishing-source item cited by number in the
# evidence text gets both (b) and (c), which is redundant but never
# contradictory, since both resolve to the same live fetch — and any one of
# them failing refuses the void outright, even when another already
# succeeded: each is independent corroboration, not an alternative to be
# skipped once one has passed. An entry for which none applies is refused
# with a reason naming what was missing, rather than accepted on presence
# alone.
void_guard_reason() {
  local entry="$1" repos="${2:-[]}" ctx="${3:-{\}}" gh_bin="${VOID_GUARD_GH:-gh}"
  local ref slug num files resolvable repo_slug resolve_reason citation_refusal
  local item finishing_num finishing_reason checked structured_resolved inner_ctx
  local has_citation

  if [[ -z "$(void_entry_evidence "$entry")" ]]; then
    printf 'no evidence recorded, and requirement 34c makes evidence what a terminal verdict is'
    return 1
  fi

  repo_slug="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
  item="$(jq -r '.item // ""' <<<"$entry" 2>/dev/null || true)"
  checked=0
  structured_resolved=false

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
    structured_resolved=true
    checked=1
  fi

  inner_ctx="$(jq -c --argjson r "$structured_resolved" '. + {current_structured_resolved: $r}' <<<"$ctx" 2>/dev/null)"
  [[ -n "$inner_ctx" ]] || inner_ctx="$(jq -nc --argjson r "$structured_resolved" '{current_structured_resolved: $r}')"

  has_citation=0
  if [[ -n "$(void_evidence_cited_pr_numbers "$(void_entry_evidence "$entry")" "$repo_slug")" ]] \
    || [[ -n "$(void_evidence_cited_commit_shas "$(void_entry_evidence "$entry")" "$repo_slug")" ]]; then
    has_citation=1
  fi
  if (( has_citation )); then
    if ! citation_refusal="$(void_citation_reason "$entry" "$repo_slug" "$inner_ctx")"; then
      printf 'not corroborated: %s' "$citation_refusal"
      return 1
    fi
    checked=1
  fi

  finishing_num="$(void_finishing_item_pr "$item" 2>/dev/null || true)"
  if [[ -n "$finishing_num" ]]; then
    if [[ -z "$repo_slug" ]]; then
      printf 'item %s names a pull request to finish, but the entry names no repo' "$item"
      return 1
    fi
    if ! finishing_reason="$(void_finishing_pr_reason "$repo_slug" "$finishing_num" "$item" "$inner_ctx")"; then
      printf 'not corroborated: %s' "$finishing_reason"
      return 1
    fi
    checked=1
  fi

  if (( ! checked )); then
    printf 'no checkable citation: evidence is prose with no PR/commit citation and no {ref,path,expect,pattern} shape, and item %s names no pull request to finish' \
      "${item:-<no item>}"
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
