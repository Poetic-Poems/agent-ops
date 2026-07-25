#!/usr/bin/env bash
#
# lib/void-guard.sh — what a Co-Ordinator must produce before one of its
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
# The obvious repair is to tell the Co-Ordinator to be more careful. That is
# not a repair: "be certain" is already in prompts/coordinator.md, twice, and
# the model that voided #92 was certain. The Co-Ordinator is also the one void
# author that structurally cannot check — the Implementor reads the tree
# (requirement 27b), the Enabler reads the issue and the PR (requirement 35),
# and the Co-Ordinator reads a JSON digest of candidates and nothing else. An
# assertion about the default branch, made by the one actor that never looks at
# the default branch, is the assertion to corroborate.
#
# So the guard is mechanical, and it runs on the Script's side of the boundary:
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
#      No amount of model confidence survives that.
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

# void_guard_reason ENTRY_JSON REPOS_JSON
# Decide whether this Co-Ordinator void may be recorded as terminal.
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
  local ref slug num files

  if [[ -z "$(void_entry_evidence "$entry")" ]]; then
    printf 'no evidence recorded, and requirement 34c makes evidence what a terminal verdict is'
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
