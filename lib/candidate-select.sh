#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/candidate-select.sh — the claim loop and candidate selection: gathering
# each source's candidates per repository, excluding what a peer already
# claimed or what is blocked/void, the refinement-traceability check and
# repair (#768), and the accounting the Co-Ordinator's verdict is checked
# against (requirement 3t/3x).
#
# Split out of agent-cycle.sh (#771) as the "claim loop and candidate
# selection" seam docs/IMPLEMENTATION-PIPELINE-SPEC.md's requirements name.
# Sourced by agent-cycle.sh only; reads and writes the cycle's own globals
# (`cycle_dir`, `claim_active`, `claim_kind`, `claim_key`, `claim_pr_key`,
# `first_seen_known_json`, …) exactly as they did inline.

# release_claim have-pr|no-pr|have-pr-pending
#
# Releases the item-keyed claim (branch or file) per the have-pr/no-pr rule
# above, then — unless told to hold off — releases the PR-keyed claim too.
# "have-pr-pending" is the one caller (pr-raised, below) that must not: the
# open PR now stands in for the item-keyed claim, but the PR-keyed exclusion
# claim (issue #238) exists to keep a *peer* off this same PR, and the
# Reviewer stage that runs next still writes to it. Dropping the PR-keyed
# claim here reopened exactly the race issue #238 closed — poetic-2's
# Reviewer was still pushing to PR #353 forty-three minutes after this call
# released it, while ockham-2 claimed and force-pushed a rebase of the same
# PR under a fresh review-feedback ref (issue #360). Every other caller
# already runs at this cycle's true end (a stage failure, a reviewer
# handback, a signal, or the terminal "ready"/void/blocked paths below), so
# it is safe — and necessary — for them to drop both.
release_claim() {  # release_claim have-pr|no-pr|have-pr-pending
  if (( claim_active )); then
    if [[ "$1" == "have-pr" || "$1" == "have-pr-pending" ]]; then
      timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release file "$selected_repo" "$claim_key" \
        >>"$cycle_dir/claim.log" 2>&1 || true
    else
      timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release "$claim_kind" "$selected_repo" "$claim_key" \
        >>"$cycle_dir/claim.log" 2>&1 || true
    fi
    claim_active=0
  fi
  [[ "$1" == "have-pr-pending" ]] && return 0
  release_pr_claim
}

# The PR-keyed claim's own release, split out so it can be deferred past the
# item-keyed claim's (issue #360) and still be reachable — idempotently, on
# whichever path this cycle actually ends on — from every one of them.
# Independent of claim_active by design (see above): a caller that already
# released the item-keyed claim via "have-pr-pending" has claim_active=0 by
# the time this runs, and must not skip the PR-keyed release on that account.
# `cleanup` (the EXIT trap) calls it too, as the backstop for the one ending
# no handler reaches — an unhandled errexit abort after `pr-raised` — which
# is why the empty-key guard below must stay the first line: on every handled
# path the trap's call finds claim_pr_key already cleared and does nothing.
release_pr_claim() {
  [[ -n "$claim_pr_key" ]] || return 0
  timeout "$claim_release_timeout" "$SCRIPT_DIR/lib/claim.sh" release file "$selected_repo" "$claim_pr_key" \
    >>"$cycle_dir/claim.log" 2>&1 || true
  claim_pr_key=""
}

# The claim/working branch is derived here, deterministically, never by the
# model: two nodes must compute the same name for the same item or the lock
# locks nothing. Tech-debt takes the human protocol's own `td/<ID>` — agents
# and humans then contend on the same ref and git arbitrates; everything else
# is `agent/<item-ref>`.
claim_branch_for() {  # <source> <item>
  local source="$1" item="$2"
  case "$source" in
    tech-debt) printf 'td/%s' "$item" ;;
    *)         printf 'agent/%s' "${item//[^A-Za-z0-9._-]/-}" ;;
  esac
}

# Requirement 3o: the fleet's active claims for one repo, deterministic claim
# visibility for the Co-Ordinator's own exclusion (issue #175) instead of a
# per-candidate live check the model performs unevenly. Two independent
# sources, unioned and deduped by item: `lib/claim.sh claims`, the registry
# already age-filtered to `claim_ttl_hours` — the only source for a file claim,
# since the four finishing sources have no branch — and `lib/claim.sh
# branches`, a live scan that still catches a claim the registry missed
# (`state_repo` unset, or a failed best-effort write). By the time this runs,
# step 2.1a's claim GC has already swept anything past the TTL, so a live
# branch found here is either still fresh or has real work pushed to it, and
# either way belongs in the list — no separate TTL check is needed for it.
#
# A branch-derived item is recovered by stripping `td/` or `branch_prefix`
# from the branch name, the exact inverse of claim_branch_for above. That
# recovery is exact for every item this system ever mints such a branch for —
# an issue number, an alert ref, a register-hygiene or project-review ref —
# none of which contain a character claim_branch_for's sanitiser would have
# touched, so there is nothing lossy to recover from in practice.
#
# `pr_number` (issue #238) rides along wherever the registry knows one — a
# finishing-source claim's item-keyed entry and its PR-keyed sibling both
# record it, so it survives the dedup below regardless of which of the two
# entries `group_by` happens to read it from. Omitted, not `null`, when
# nothing in the group carries one: an ordinary tech-debt or issue claim
# targets no PR at all, and the field's *absence* is what the repo-loop's
# PR-level exclusion (below) and requirement 16's exclusion 3 test for.
gather_claimed() {  # <target-slug> -> JSON array of {item, age_hours, pr_number?}
  local slug="$1" safe registry_out branches_out out
  safe="${slug//\//_}"
  registry_out="$("$SCRIPT_DIR/lib/claim.sh" claims "$slug" 2>"$cycle_dir/claims-$safe.err" || true)"
  jq -e 'type == "array"' <<<"$registry_out" >/dev/null 2>&1 || registry_out='[]'
  branches_out="$("$SCRIPT_DIR/lib/claim.sh" branches "$slug" 2>"$cycle_dir/claim-branches-$safe.err" || true)"
  jq -e 'type == "array"' <<<"$branches_out" >/dev/null 2>&1 || branches_out='[]'
  # TD-PPagop-26081407: $registry_out/$branches_out still ride in as
  # --argjson (unconverted by requirement 4g — the fleet's active claims for
  # one repo, growing with claim volume) and can hit MAX_ARG_STRLEN (test 1);
  # `[]` here reads exactly like "this repo genuinely has no claims" (test 2),
  # which the caller uses to decide whether a candidate is already claimed.
  out="$(jq -c -n --arg tp 'td/' --arg ap "$branch_prefix" --argjson reg "$registry_out" --argjson br "$branches_out" '
    ( [ $reg[] | {item, age_hours, pr_number: (.pr_number // null)} ] ) as $from_registry
    | ( [ $br[]
          | (if startswith($tp) then .[($tp | length):]
             elif ($ap != "" and startswith($ap)) then .[($ap | length):]
             else empty end)
          | select(. != "")
          | {item: ., age_hours: null, pr_number: null} ] ) as $from_branches
    | ($from_registry + $from_branches)
    | group_by(.item)
    | map(
        (.[0].item) as $item
        | (([.[].age_hours | select(. != null)] | first) // null) as $age
        | (([.[].pr_number | select(. != null)] | first) // null) as $pr
        | {item: $item, age_hours: $age} + (if $pr == null then {} else {pr_number: $pr} end)
      )
  ' 2>&1)" || { guard_warn "gather_claimed:$slug" "$out"; out='[]'; }
  printf '%s' "$out"
}

# Requirement 3p/issue #238: drop any of a finishing source's own candidates
# whose `pr_number` is one a peer already holds a claim on — under whatever
# item ref that peer claimed it, which need not be (and after a fresh review
# round or a moved head, usually isn't) this cycle's own ref for the same PR.
# This is what makes the Co-Ordinator's exclusion deterministic code instead of
# a comparison it has to remember to make per candidate: a PR already excluded
# here never reaches its runtime input, so there is nothing left for it to
# reason past. Malformed input degrades to passing the array through
# unfiltered — this is a visibility layer over the atomic PR-level claim taken
# in the selection loop below, never itself the exclusion's hard gate.
#
# Both arrays arrive on stdin, one JSON document per line, bound positionally
# in the order printed (requirement 4g) — never in argv: the claims array
# grows with the fleet's live claim count, and past MAX_ARG_STRLEN an
# `--argjson` delivery would fail into the fail-open fallback below and pass
# every candidate through unfiltered, reopening exactly the claimed-work
# proposals #305 closed.
exclude_claimed_prs() {  # <candidates-json> <claimed-pr-numbers-json>
  local candidates="$1" claimed_prs="${2:-[]}" docs
  jq -e 'type == "array"' <<<"$claimed_prs" >/dev/null 2>&1 || claimed_prs='[]'
  docs="$(printf '%s\n' "$candidates" "$claimed_prs")"
  # TD-PPagop-26081407: the `|| printf` below passes test 2 — it falls back to
  # the pre-filter $candidates, a value the caller already accepted, not a
  # fabricated empty.
  jq -nc '
    input as $candidates | input as $claimed
    | [ $candidates[] | select(((.pr_number // null) as $p | $p == null or ($claimed | index($p)) == null))]' \
    <<<"$docs" 2>/dev/null || printf '%s' "$candidates"
}

# The item-ref sibling of exclude_claimed_prs above, and the same design
# decision extended to every pre-fetched source: drop any candidate whose
# `ref` — the item ref every gather script mints (requirement 3o) and the
# string a claim is keyed on — is one the fleet already holds. Exclusion 3 in
# prompts/coordinator.md asks the model to skip claimed items, and on
# 2026-08-09 a Co-Ordinator read four issues as "claimed in the live
# branches", reasoned that claimed items still make good alternates, and
# ranked three of them — every claim lost, the cycle forfeited. An item
# filtered out here never reaches the runtime input, so there is nothing
# left to reason past. Malformed input degrades to passing the array through
# unfiltered, exactly as exclude_claimed_prs does and for the same reason:
# this is a visibility layer over the atomic claim, never the hard gate.
#
# Both arrays arrive on stdin, one JSON document per line, bound positionally
# in the order printed (requirement 4g) — never in argv, for the same reason
# and on the same fail-open terms as exclude_claimed_prs above.
exclude_claimed_items() {  # <candidates-json> <claimed-item-refs-json>
  local candidates="$1" claimed_items="${2:-[]}" docs
  jq -e 'type == "array"' <<<"$claimed_items" >/dev/null 2>&1 || claimed_items='[]'
  docs="$(printf '%s\n' "$candidates" "$claimed_items")"
  # TD-PPagop-26081407: the `|| printf` below passes test 2 — it falls back to
  # the pre-filter $candidates, a value the caller already accepted, not a
  # fabricated empty.
  jq -nc '
    input as $candidates | input as $claimed
    | [ $candidates[] | select(((.ref // null) as $r | $r == null or ($claimed | index($r)) == null))]' \
    <<<"$docs" 2>/dev/null || printf '%s' "$candidates"
}

# Issue #248 acceptance 4 (TD-PPagop-26081405): log one `first-seen` per item
# the very first time any node's gather ever reports it, so a later report can
# subtract it from the `selection` that eventually claims it. Called on each
# pre-fetched source's RAW candidate array — ahead of exclude_claimed_items and
# the blocked/void pass further down — so an item claimed, blocked or voided
# the same cycle it first appears still gets one (acceptance 3): those
# exclusions only ever narrow what the Co-Ordinator is shown, never what this
# fleet has seen.
#
# $first_seen_known_json (seeded from first_seen_known_items over the union
# log, lib/cycle-state.sh) is the running "already logged" set, updated here so
# a later source's own candidates this same cycle see this call's new items
# too — a `register-hygiene` id first-seen alongside a `tech-debt` one in the
# same cycle must not both fire twice. Like every aggregate requirement 4g
# names, it can grow with the fleet's whole history, so it travels to jq on
# stdin, never as an --argjson; on malformed input it is left exactly as it
# was, which only ever costs a retry next cycle, never a lost or duplicated
# event. $first_seen_bootstrap is one small flag, decided once at the top of
# the cycle, and cheap enough to pass with --argjson like any config-sized
# value.
emit_first_seen() {  # <repo> <source> <candidates-json>
  local repo="$1" source="$2" candidates="$3" docs result new_refs ref
  docs="$(printf '%s\n' "$first_seen_known_json" "$candidates")"
  result="$(jq -nc --arg r "$repo" '
    input as $known | input as $cands
    | ($known | map(select(.repo == $r)) | map(.item)) as $seen
    | ([$cands[].ref // empty | select(. != "")] | unique
       | map(select(. as $ref | ($seen | index($ref)) == null))) as $new
    | {new: $new, known: ($known + ($new | map({repo: $r, item: .})))}
  ' <<<"$docs" 2>/dev/null || echo '{"new":[],"known":null}')"
  new_refs="$(jq -c '.new' <<<"$result" 2>/dev/null || echo '[]')"
  if jq -e '.known != null' <<<"$result" >/dev/null 2>&1; then
    first_seen_known_json="$(jq -c '.known' <<<"$result")"
  fi
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    log_event "first-seen" "$(jq -nc --arg r "$repo" --arg i "$ref" --arg s "$source" --argjson b "$first_seen_bootstrap" \
      '{repo: $r, item: $i, source: $s, basis: "poll", bootstrap: $b}')"
  done < <(jq -r '.[]' <<<"$new_refs" 2>/dev/null || true)
}

# Requirement 3t/issue #310: drop any candidate whose `ref` is recorded
# blocked or void for THIS_REPO in the fleet's shared log — the same
# deterministic-code-not-model-judgement decision exclude_claimed_items above
# makes for claims, applied to the two other exclusions requirement 16's
# exclusion 1 asks the Co-Ordinator to apply by eye. Unlike `issues`
# (requirement 3j), which deliberately leaves blocked items in the array
# because requirement 18a's re-check needs the live thread to decide whether
# fresh evidence unblocks one, a tech-debt item has no such re-check: a block
# whose underlying work has actually landed is already cleared before this
# runs, by requirement 34i's work-gone reconciliation reading the very same
# register this array was drawn from — so nothing here is ever filtered out
# only to need putting back a moment later. Scoped to the repo the block/void
# was recorded against, matching BLOCKED_ITEMS_JQ's own repo-or-blank match:
# a blank `repo` (an old, pre-scoping event) still matches every repo, exactly
# as the Co-Ordinator's own reading of `blocked`/`void` always has. Malformed
# input degrades to passing the array through unfiltered, on the same fail-open
# terms as exclude_claimed_items.
#
# All three arrays arrive on stdin, one JSON document per line, bound
# positionally in the order printed (requirement 4g) — never in argv. Two of
# them are the very aggregates that crossed MAX_ARG_STRLEN on 2026-08-12: the
# void extract measured 133615 bytes that day, and the blocked extract already
# carries its entries' evidence payloads. Past the cap an `--argjson` delivery
# here would fail into the fail-open fallback below and pass every candidate
# through unfiltered — silently restoring the unfiltered band this requirement
# exists to remove, and doing it precisely when the void record is at its
# largest and its "heavily voided" misreading most tempting. A here-string
# rather than a pipe, for requirement 4c's reason: under `pipefail` a
# producer's SIGPIPE must not become this call's status.
exclude_blocked_or_void_items() {  # <candidates-json> <repo> <blocked-json> <void-json>
  local candidates="$1" repo="$2" blocked="${3:-[]}" void="${4:-[]}" docs
  jq -e 'type == "array"' <<<"$blocked" >/dev/null 2>&1 || blocked='[]'
  jq -e 'type == "array"' <<<"$void" >/dev/null 2>&1 || void='[]'
  docs="$(printf '%s\n' "$candidates" "$blocked" "$void")"
  # TD-PPagop-26081407: the `|| printf` below passes test 2 — it falls back to
  # the pre-filter $candidates, a value the caller already accepted, not a
  # fabricated empty.
  jq -nc --arg repo "$repo" '
    input as $candidates | input as $blocked | input as $void
    | [ $candidates[] | select(((.ref // null) as $r
                     | $r != null
                       and ($blocked | any(((.item // "") | tostring) == $r
                                           and ((.repo // "") == "" or (.repo // "") == $repo))) == false
                       and ($void | any(((.item // "") | tostring) == $r
                                        and ((.repo // "") == "" or (.repo // "") == $repo))) == false)) ]
  ' <<<"$docs" 2>/dev/null || printf '%s' "$candidates"
}

# Requirement 3u/issue #320: the fields of a `blocked` entry
# "Re-checking blocked items" and "A blocked issue with fresh evidence must be
# re-read" (prompts/coordinator.md) actually read — `item`, `ts`, `detail`,
# and `repo`/`recheck_clean_ts` where present — and nothing else. Every
# pre-fetched band but `issues` has already had its own blocked entries
# excluded before the Co-Ordinator ever sees the candidate (the loop that
# calls exclude_blocked_or_void_items/exclude_blocked_or_void_issues, below),
# so what remains of `blocked`'s purpose in the Co-Ordinator's own input is
# `issues`' live re-check duty and the exclusion-1 check on the three sources
# it still derives itself — neither reads `stage`, `cycle`, `event`, or an
# Implementer's `unblock_condition`, so there is nothing lost by leaving them
# off a list the model pays token cost to read every cycle. Malformed input
# degrades to the untrimmed array, on the same fail-open terms as
# exclude_blocked_or_void_items: a parse failure here must not silently empty
# the Co-Ordinator's only remaining view of blocked state.
coordinator_blocked_view() {  # <blocked-json>
  jq -c \
    '[.[] | {item, ts, detail}
            + (if has("repo") then {repo} else {} end)
            + (if has("recheck_clean_ts") then {recheck_clean_ts} else {} end)]' \
    <<<"$1" 2>/dev/null || printf '%s' "$1" # TD-PPagop-26081407: passes test 2 -- falls back to the unfiltered $1, a value the caller already accepted
}

# Requirement 4j/issue #643: the `refinements` half of the Co-Ordinator's
# unsheddable input, trimmed the way `coordinator_blocked_view` above trims the
# other half.
#
# A refinement entry is small — `ts`, `cycle`, and either a `comment_url` or a
# `spec`. The `spec` is not: it is a whole work order in markdown, several
# kilobytes of it, written for an item type with no thread to hold it
# (tech-debt, a review recommendation, a plan task). The map is a ledger, never
# retired, so every spec the Refiner has ever written is still in it — on
# 2026-08-21 that was 24 specs totalling 219,175 bytes, of which 22 (203,645
# bytes) belonged to items no band of this cycle still names as a candidate.
# That is what took the assembled prompt past the model's window and had the
# API refuse the stage on every node of the fleet, eleven consecutive cycles,
# with no work selected anywhere while it lasted.
#
# The prompt's "Items that have been refined" gives the spec exactly one use:
# an item the Co-Ordinator is about to put in a work order must have its spec
# pasted verbatim into `context`, because it exists nowhere else. That use is
# reachable only for an item that is a candidate this cycle. So the spec of an
# item no band offers is bytes the Co-Ordinator is told to read and can never
# act on, and dropping it removes no judgement — the same test
# `coordinator_blocked_view` is trimmed against.
#
# What is *not* dropped is the entry: `ts`, `cycle` and `comment_url` stay for
# every item, refined or not, because "Look the item up here before you decide
# it is under-specified" and the `refinement_policy` gate both read the entry's
# presence rather than its spec, and a `comment_url` is a pointer whose cost is
# a line. Only the payload with a single, candidate-scoped use is shed.
#
# Both documents arrive on stdin, never in argv (requirement 4g): this map is
# the value that crossed MAX_ARG_STRLEN, and an `--argjson` here would trade
# the refusal this function exists to prevent for the execve death that
# requirement exists to prevent.
#
# Every degradation is toward the *untrimmed* ledger, never toward a smaller
# one — the same direction `coordinator_blocked_view` and requirement 4i's own
# guards take. Note which way that points for each document: a `repos` array
# that will not parse, or is not an array, means candidacy cannot be decided at
# all, so nothing may be shed on the strength of it. Coercing it to `[]` would
# read as "no candidates" and strip every spec in the fleet — an un-refinement
# of every item at once, dressed as a successful trim, and a far worse failure
# than the overflow this function exists to prevent. An empty array is a
# different fact and is honoured: a cycle really can offer no candidates, and
# then no spec has a use.
coordinator_refinements_view() {  # <refinements-json> <ordered-repos-json>
  local refinements="${1:-{\}}" repos="${2:-[]}" docs
  jq -e 'type == "object"' <<<"$refinements" >/dev/null 2>&1 \
    || { printf '%s' "$refinements"; return 0; }
  jq -e 'type == "array"' <<<"$repos" >/dev/null 2>&1 \
    || { printf '%s' "$refinements"; return 0; }
  docs="$(printf '%s\n' "$refinements" "$repos")"
  jq -cn '
    input as $refinements | input as $repos
    | ( [ $repos[]?
          | {key: (.slug // "" | tostring),
             value: ( [ (.findings, .review_feedback, .issues, .register_hygiene,
                         .human_visibility, .tech_debt, .plan_tasks)[]?
                        | .ref? // empty | tostring ]
                      | map({key: ., value: true}) | from_entries )} ]
        | from_entries ) as $live
    | $refinements
    | with_entries(
        .key as $slug
        | .value |= ( if type == "object"
                      then with_entries(
                             if (.value | type) == "object" and (.value | has("spec"))
                                and (($live[$slug] // {})[.key] | not)
                             then .value |= del(.spec)
                             else . end)
                      else . end))' <<<"$docs" 2>/dev/null || printf '%s' "$refinements"
}

# Requirement 17f (issue #626): requirement 17b already obliges the
# Co-Ordinator to paste a refined item's own recorded refinement — a `spec`
# verbatim, or (for an issue) the comment its own `comment_url` names,
# already folded into requirement 20's whole-thread paste — into that same
# item's work order. Trusting that the model actually did so, for every
# candidate it names in a work order composed alongside others in the same
# engagement, is exactly what let issue #571's work order carry issue #529's
# own refinement content instead of its own: the response was syntactically
# fine and each candidate individually plausible, so nothing detected the
# cross-item swap until an Implementer, handed nothing but the mismatched
# work order, could not reconcile the two and burned a needs-refinement
# report on a fault the item never had.
#
# This closes that gap the only way that does not depend on the model
# getting it right a second time: re-derive the item's own refinement from
# `refinements-json` — keyed on this candidate's own `repo`/`item`, never on
# anything the candidate itself claims — and confirm it is genuinely
# present, verbatim, in the candidate's own `context` or `acceptance`. A
# `spec` entry costs nothing to check (it is already in hand); a
# `comment_url` entry costs one `gh api` read of the actual comment, because
# the pre-fetched `comments` array a repo's `issues` entry carries has no
# per-comment id to join it back against. A `comment_url` whose own embedded
# issue number disagrees with `item` is a fault before any fetch is
# attempted — the one case cheap enough to catch even a corrupted ledger
# entry, not only a model that ignored a correct one. A network failure
# fetching the real comment fails open, the same direction every other
# degraded `gh` read in this pipeline already fails, because it is a fact
# about GitHub's availability, not about the work order.
#
# Normalizes text for the traceability comparison below (TD-PPagop-26082307):
# collapses every run of whitespace — spaces, tabs, reflowed newlines — to a
# single space and trims both ends, by tokenizing on non-whitespace runs and
# rejoining with a single space. A model's paste of a multi-kilobyte spec or
# issue thread drifts in exactly these ways (a reflowed line, a normalized
# list marker, a trimmed trailing space) without changing what it says, and a
# verbatim `contains` trips on every one of them; this tolerates all of them
# while still failing a passage that is genuinely missing or different. Prints
# to stdout; a jq failure (should not happen — input is always a shell
# string) degrades to the input unchanged rather than losing the text.
_traceability_normalize() {  # <text>
  jq -Rrs '[scan("[^[:space:]]+")] | join(" ")' <<<"$1" 2>/dev/null || printf '%s' "$1"
}

# Prints a non-empty, human-readable fault description when the candidate
# fails either check; prints nothing when there is nothing to check (no
# refinement on record for this item) or when the check passes. Never exits
# non-zero: a candidate this cannot evaluate is not, by itself, a fault.
#
# TD-PPagop-26082307: a `gh` read that fails while fetching the actual
# comment text is a fault now, not a silent pass — see the comment at that
# fetch below for why. Set `TRACEABILITY_DEBUG=1` to log, to stderr, the
# normalized haystack/needle a comparison actually ran against; this is
# never required to diagnose a failure, only to see it directly.
refinement_traceability_fault() {  # <candidate-json> <refinements-json>
  local cand="$1" refinements="${2:-{\}}" repo item entry spec comment_url \
    url_issue comment_id body norm_context norm_acceptance norm_needle \
    body_fetch_failed=0
  jq -e 'type == "object"' <<<"$refinements" >/dev/null 2>&1 || refinements='{}'
  repo="$(jq -r '.repo // ""' <<<"$cand" 2>/dev/null || true)"
  item="$(jq -r '.item // ""' <<<"$cand" 2>/dev/null || true)"
  [[ -n "$repo" && -n "$item" ]] || return 0
  entry="$(jq -c --arg r "$repo" --arg i "$item" \
    '((.[$r] // {})[$i]) // {}' <<<"$refinements" 2>/dev/null || printf '{}')"

  spec="$(jq -r '.spec // ""' <<<"$entry" 2>/dev/null || true)"
  if [[ -n "$spec" ]]; then
    norm_context="$(_traceability_normalize "$(jq -r '.context // ""' <<<"$cand" 2>/dev/null)")"
    norm_needle="$(_traceability_normalize "$spec")"
    if [[ -n "${TRACEABILITY_DEBUG:-}" ]]; then
      printf 'traceability-debug: %s %s: spec haystack=%q needle=%q\n' \
        "$repo" "$item" "$norm_context" "$norm_needle" >&2
    fi
    if ! jq -ne --arg h "$norm_context" --arg n "$norm_needle" \
        '$h | contains($n)' >/dev/null 2>&1; then
      printf '%s %s: recorded refinement spec is not present, verbatim (after whitespace normalization), in this work order'\''s context — requirement 17b requires it, and a cross-item swap cannot satisfy this by accident' \
        "$repo" "$item"
      return 0
    fi
  fi

  comment_url="$(jq -r '.comment_url // ""' <<<"$entry" 2>/dev/null || true)"
  [[ -n "$comment_url" ]] || return 0

  url_issue="$(printf '%s' "$comment_url" \
    | sed -n 's|.*/issues/\([0-9][0-9]*\)#issuecomment-.*|\1|p')"
  if [[ -n "$url_issue" && "$url_issue" != "$item" ]]; then
    printf '%s %s: recorded refinement comment_url (%s) names issue #%s, not #%s — its own record disagrees with the item it is attached to' \
      "$repo" "$item" "$comment_url" "$url_issue" "$item"
    return 0
  fi

  comment_id="$(printf '%s' "$comment_url" \
    | sed -n 's|.*#issuecomment-\([0-9][0-9]*\)$|\1|p')"
  [[ -n "$comment_id" ]] || return 0
  # A failed fetch here used to fail open (return 0, no fault) — the same
  # direction every other degraded `gh` read in this pipeline fails, on the
  # reasoning that an outage is a fact about GitHub, not about the work
  # order. But requirement 17f exists to gate a claim on a refinement really
  # being present, and a check that cannot read the refinement cannot know
  # that — assuming pass here means a token going bad, a rate limit, or a
  # malformed `comment_url` silently disarms the whole gate, indefinitely,
  # while still reading as a passing check. So a failed read is now treated
  # the same as a failed match: a fault, reported as `untraceable` by the
  # caller, with the failure itself surfaced via guard_warn rather than
  # swallowed — the caller then retries the item next cycle rather than
  # ever waving it through unverified.
  body="$(gh api "repos/$repo/issues/comments/$comment_id" --jq '.body // ""' 2>&1)" \
    || { guard_warn "traceability:comment-fetch:$repo#$item" "$body"; body=""; body_fetch_failed=1; }
  if (( body_fetch_failed )); then
    printf '%s %s: could not fetch recorded refinement comment (%s) to verify traceability — gh api failed, so the check cannot pass and the candidate is treated as untraceable rather than assumed compliant' \
      "$repo" "$item" "$comment_url"
    return 0
  fi
  [[ -n "$body" ]] || return 0

  norm_context="$(_traceability_normalize "$(jq -r '.context // ""' <<<"$cand" 2>/dev/null)")"
  norm_acceptance="$(_traceability_normalize "$(jq -r '.acceptance // ""' <<<"$cand" 2>/dev/null)")"
  norm_needle="$(_traceability_normalize "$body")"
  if [[ -n "${TRACEABILITY_DEBUG:-}" ]]; then
    printf 'traceability-debug: %s %s: comment context-haystack=%q acceptance-haystack=%q needle=%q\n' \
      "$repo" "$item" "$norm_context" "$norm_acceptance" "$norm_needle" >&2
  fi
  if ! jq -ne --arg hc "$norm_context" --arg ha "$norm_acceptance" --arg n "$norm_needle" \
      '($hc | contains($n)) or ($ha | contains($n))' >/dev/null 2>&1; then
    printf '%s %s: recorded refinement comment (%s) is not present, verbatim (after whitespace normalization), in this work order'\''s context or acceptance — requirement 17b/20 both require it, and a cross-item swap cannot satisfy this by accident' \
      "$repo" "$item" "$comment_url"
  fi
}

# Requirement 17f, repair half (issue #767).
#
# `refinement_traceability_fault` above asks whether the *model* copied the
# refinement across. That question was never the requirement: 17b/20 ask that
# the work order **carry** the item's refinement, and the Script is holding
# the text while it asks. Between 2026-08-22T23:42Z (when the check landed)
# and 2026-08-24T10:00Z it discarded 92 candidates across 20 issues and
# admitted none — a gate with no observed passes is not a gate, it is an
# outage — while `coordinator_model` was `claude-haiku-4-5-20251001` and the
# band feeding it was being trimmed to fit that model's window. Text trimmed
# out of the input cannot be pasted back out of it, so the check was asking
# for something the cycle had already made impossible.
#
# So: supply what is missing instead of discarding the work. This function
# returns the candidate with the recorded refinement appended verbatim to
# `context`, which makes traceability true **by construction** rather than
# by inspection — a stronger guarantee than the check it replaces, and one
# no model can fail.
#
# What it deliberately does not repair:
#
#   * A `comment_url` whose own embedded issue number disagrees with `item`.
#     That is a corrupt ledger entry, not a copying failure, and appending
#     another issue's comment to this item's order is exactly the #626 defect
#     the gate exists to prevent. `refinement_traceability_fault` still
#     reports it and the caller still skips — repair is offered only for the
#     missing-text faults.
#   * A refinement it cannot read. A failed `gh` fetch leaves the candidate
#     untouched and the caller's own fault check decides, so this fails in
#     the same direction the check already does.
#
# Prints the repaired candidate JSON, or nothing when there is nothing to
# repair or the repair cannot be made. Never exits non-zero.
refinement_traceability_repair() {  # <candidate-json> <refinements-json>
  local cand="$1" refinements="${2:-{\}}" repo item entry spec comment_url \
    url_issue comment_id body out changed=0
  jq -e 'type == "object"' <<<"$refinements" >/dev/null 2>&1 || refinements='{}'
  repo="$(jq -r '.repo // ""' <<<"$cand" 2>/dev/null || true)"
  item="$(jq -r '.item // ""' <<<"$cand" 2>/dev/null || true)"
  [[ -n "$repo" && -n "$item" ]] || return 0
  entry="$(jq -c --arg r "$repo" --arg i "$item" \
    '((.[$r] // {})[$i]) // {}' <<<"$refinements" 2>/dev/null || printf '{}')"
  out="$cand"

  # The spec half: appended under a heading naming where it came from, so an
  # Implementer reading the order can tell the refinement from the item's own
  # text — the one thing pasting it inline would lose.
  spec="$(jq -r '.spec // ""' <<<"$entry" 2>/dev/null || true)"
  if [[ -n "$spec" ]] \
     && jq -e --arg spec "$spec" '((.context // "") | contains($spec)) | not' \
          <<<"$out" >/dev/null 2>&1; then
    out="$(jq -c --arg spec "$spec" \
      '.context = ((.context // "") + "\n\n## Recorded refinement (supplied verbatim by the Script)\n\n" + $spec)' \
      <<<"$out" 2>/dev/null)" || return 0
    changed=1
  fi

  comment_url="$(jq -r '.comment_url // ""' <<<"$entry" 2>/dev/null || true)"
  if [[ -n "$comment_url" ]]; then
    url_issue="$(printf '%s' "$comment_url" \
      | sed -n 's|.*/issues/\([0-9][0-9]*\)#issuecomment-.*|\1|p')"
    # The ledger-disagreement case is never repaired — see above.
    if [[ -z "$url_issue" || "$url_issue" == "$item" ]]; then
      comment_id="$(printf '%s' "$comment_url" \
        | sed -n 's|.*#issuecomment-\([0-9][0-9]*\)$|\1|p')"
      if [[ -n "$comment_id" ]]; then
        body="$(gh api "repos/$repo/issues/comments/$comment_id" --jq '.body // ""' 2>/dev/null || true)"
        if [[ -n "$body" ]] \
           && jq -e --arg body "$body" \
                '((((.context // "") | contains($body)) or ((.acceptance // "") | contains($body))) | not)' \
                <<<"$out" >/dev/null 2>&1; then
          out="$(jq -c --arg body "$body" --arg url "$comment_url" \
            '.context = ((.context // "") + "\n\n## Recorded refinement comment (supplied verbatim by the Script)\n\n" + $url + "\n\n" + $body)' \
            <<<"$out" 2>/dev/null)" || return 0
          changed=1
        fi
      fi
    fi
  fi

  (( changed )) && printf '%s\n' "$out"
  return 0
}

# Requirement 3u/issue #320: the same deterministic-code-not-model-judgement
# exclusion as exclude_blocked_or_void_items above, purpose-built for the one
# pre-fetched band that function cannot be reused for as-is. Requirement 3t
# left `issues` out of the blanket exclusion on purpose — requirement 18a
# obliges the Co-Ordinator to re-read a blocked issue's live thread when its
# `updated_at` carries evidence posted after the block was last confirmed
# current, and a candidate dropped before the Co-Ordinator ever saw it cannot
# be re-read. Dropping every blocked issue here, the way `tech_debt` and every
# other band now are (see the loop below), would silently retire that
# mandatory re-check — precisely the live judgement 18a exists to keep in
# front of a human-in-the-loop model, not remove it.
#
# So this drops only what the prompt's own "Re-checking blocked items" and "A
# blocked issue with fresh evidence must be re-read" sections already tell the
# Co-Ordinator to skip *without* a re-read: an issue whose `updated_at` is no
# newer than the later of the block's own `ts` and its newest
# `recheck_clean_ts` (requirement 18a's own threshold, mirrored verbatim —
# `test/cycle-state.test.sh`'s `needs_mandatory_reread` pins the same
# comparison against the same field). That is exactly the "skip it on the
# marker alone, no re-read needed" case the prompt already states is
# mechanical, so removing it from the Co-Ordinator's judgement removes no
# judgement at all. A blocked issue whose `updated_at` *is* newer survives
# this filter and reaches the Co-Ordinator exactly as before, for the live
# re-read only it can perform. Void issues are dropped unconditionally, like
# every other band: unlike a block, a void has no re-check to preserve
# (requirement 34c — only a human's `unvoided` ever reopens one).
#
# Malformed input degrades to passing the array through unfiltered, and a
# candidate missing `ref` is dropped rather than crashed on — the same
# fail-open terms as exclude_blocked_or_void_items. Both extracts arrive on
# stdin, never in argv, for requirement 4g's reason (see
# exclude_blocked_or_void_items's own comment): this function shares that
# call's oversized-void exposure exactly.
exclude_blocked_or_void_issues() {  # <candidates-json> <repo> <blocked-json> <void-json>
  local candidates="$1" repo="$2" blocked="${3:-[]}" void="${4:-[]}" docs
  jq -e 'type == "array"' <<<"$blocked" >/dev/null 2>&1 || blocked='[]'
  jq -e 'type == "array"' <<<"$void" >/dev/null 2>&1 || void='[]'
  docs="$(printf '%s\n' "$candidates" "$blocked" "$void")"
  # TD-PPagop-26081407: the `|| printf` below passes test 2 — it falls back to
  # the pre-filter $candidates, a value the caller already accepted, not a
  # fabricated empty.
  jq -nc --arg repo "$repo" '
    def in_repo($e): ($e.repo // "") == "" or ($e.repo // "") == $repo;
    input as $candidates | input as $blocked | input as $void
    | [ $candidates[] | . as $c | (($c.ref // null) as $r
        | select($r != null)
        | select(($void | any(((.item // "") | tostring) == $r and in_repo(.))) == false)
        | ([ $blocked[] | select(((.item // "") | tostring) == $r and in_repo(.)) ]) as $matches
        | select(
            ($matches | length) == 0
            or (
              ($matches | map([(.ts // empty), (.recheck_clean_ts // empty)]) | flatten) as $thresholds
              | (($thresholds | max) // "") as $threshold
              | (($c.updated_at // "") > $threshold)
            )
          )
        | $c) ]
  ' <<<"$docs" 2>/dev/null || printf '%s' "$candidates"
}

# Requirement 3x's machine corroboration (issue #322) — requirement 3t's own
# (issue #310), generalised off the one band it was proven on: which of this
# cycle's eligible items (ELIGIBLE_JSON, `{repo, item, source}` entries,
# `coordinator_eligible_items`' own output across every pre-fetched band) a
# `selected: false` verdict left completely unaccounted for. A bar-clearing
# item may be declined without being selected only two ways: reported in
# `needs_refinement` under that item's own source, or voided this same cycle —
# the same two the prompt's own "Reporting an under-specified item" and "Void
# items" sections give every source. `refinement_policy[<source>] ==
# "required"` is a third, legitimate silent skip (requirement 39a: an
# unrefined item there is never selectable, so the Co-Ordinator owes it no
# report), which is why an eligible entry from such a source is dropped here
# rather than flagged as unaccounted.
#
# The band is carried on the entry rather than passed as an argument, so one
# call corroborates the whole verdict at once and the per-source policy, the
# per-source `needs_refinement` match and the per-band tally all fall out of
# the same pass. That is deliberately not six copies of one rule: the *only*
# thing that varies by band is which items are eligible, and that is
# `coordinator_eligible_items`' job, not this one's.
#
# RECORDED_JSON is what the Script *recorded* from the Co-Ordinator's message
# — `log_needs_refinement_items`' and `log_voided_items`' own collections —
# never the message's `needs_refinement`/`voided` arrays verbatim, and that
# property is preserved band by band rather than re-argued per band. The
# difference is the whole point: `record_needs_refinement_block` drops an
# entry that fails requirement 34d's five-field bar with nothing but a
# warning, so a claimed-but-dropped report leaves its item open, unclaimed
# and eligible — and had it still counted as accounting for that item, the
# corroboration would have been satisfied, the fingerprint armed, and the
# next cycle's byte-identical inputs would have stood the fleet down on a
# verdict that never engaged with the band: issue #310's freeze, reopened
# through a narrow door (every eligible item reported, every report
# malformed — precisely the fields a small model omits). A `voided` entry, by
# contrast, is counted whichever way the void guard rules, because both
# outcomes are recorded state: a pass writes the void, a refusal writes a
# block (requirement 34d), and either removes the item from the next cycle's
# eligible set — so the two arrays are hardened by the one rule "count what
# was recorded", not by two different shape tests.
#
# Any entry this prints is evidence the Co-Ordinator's verdict did not
# actually engage with the band it is declining — exactly the shape of the
# incident this requirement exists for (issue #310), where the stated reason
# ("requires per-item evaluation…", "heavily voided or blocked") was
# demonstrably false against data the Script itself had already filtered.
# Malformed input degrades to `[]` — silence, not a false positive — on the
# same fail-open terms as exclude_claimed_items and
# exclude_blocked_or_void_items above.
unaccounted_items() {  # <recorded-json> <eligible-json> <refinement-policy-json> [trimmed-json]
  local recorded="$1" eligible="${2:-[]}" policy="${3:-{\}}" trimmed="${4:-[]}" docs
  jq -e 'type == "array"' <<<"$eligible" >/dev/null 2>&1 || eligible='[]'
  jq -e 'type == "object"' <<<"$policy" >/dev/null 2>&1 || policy='{}'
  jq -e 'type == "array"' <<<"$trimmed" >/dev/null 2>&1 || trimmed='[]'
  # Keyed on joined strings through two lookup maps rather than on jq's own
  # array/object equality: `index` given an array argument searches for a
  # *subsequence*, not an element, so the obvious `[$repo,$item] | index` form
  # matches things it should not. `\u0000` cannot occur in a repo slug or an
  # item ref minted by any gatherer here, so the join is unambiguous.
  #
  # requirement 4g (TD-PPagop-26081401): $eligible is the Script's own
  # pre-fetched-band denominator (requirement 3x) and grows with every
  # eligible item across every band and repo this cycle -- unbounded past
  # this call, and it is what the four verdict-contradiction logging sites
  # downstream (site 3 of TD-PPagop-26081401) filter into
  # $unaccounted_json/$unaccounted_retry_json. Leaving this call on argv
  # would fail it first, silently, into this same function's own fail-open
  # [] -- an oversized eligible set would then read as "everything is
  # accounted for" rather than the argv failure it actually is, exactly the
  # silent-degradation failure mode requirement 4g exists to remove.
  # $recorded and $trimmed travel alongside it on the same stdin document, for
  # the same reason -- $trimmed grows with the cycle's own trimmed band
  # (requirement 4i) and is no more bounded than $eligible is.
  docs="$(printf '%s\n' "$recorded" "$eligible" "$trimmed")"
  # TD-PPagop-26081407: this is the guard the 2026-08-14 outage actually went
  # through -- an execve failure here read as "everything is accounted for"
  # and the Script corroborated a none-selected verdict silently. requirement
  # 4g's stdin move above already closed off that specific delivery path
  # (test 1 mostly does not apply any more), but a caller reading [] still
  # cannot tell a clean zero from any other jq failure (test 2 always fails),
  # so this reports regardless of cause.
  local out
  out="$(jq -nc --argjson policy "$policy" '
    input as $recorded | input as $eligible | input as $trimmed
    | def ikey: ((.repo // "") + "\u0000" + ((.item // "") | tostring));
      def skey: (ikey + "\u0000" + (.source // ""));
      (($recorded.needs_refinement // []) | map({key: skey, value: true}) | from_entries) as $reported
      | (($recorded.voided // []) | map({key: ikey, value: true}) | from_entries) as $disposed
      # requirement 34e'"'"'s fourth refusal already discards any needs_refinement
      # report against an item this cycle'"'"'s fit ladder trimmed (agent-ops#683),
      # so this bar must not demand one either -- asking for a report the
      # Script'"'"'s own other rule throws away is the identical self-defeating
      # loop the "required" policy exemption just below already exists to
      # avoid for a different reason.
      | ($trimmed | map({key: skey, value: true}) | from_entries) as $fit_trimmed
      | [ $eligible[]
          | select((($policy[(.source // "")] // "exempt") != "required")
                   and (($reported[skey] // false) | not)
                   and (($disposed[ikey] // false) | not)
                   and (($fit_trimmed[skey] // false) | not)) ]
    ' <<<"$docs" 2>&1)" || { guard_warn "unaccounted_items" "$out"; out='[]'; }
  printf '%s' "$out"
}

# coordinator_unassessable_items ELIGIBLE_JSON TRIMMED_JSON
# The subset of ELIGIBLE_JSON (`coordinator_eligible_items`' own output) the
# fit ladder actually trimmed this cycle (`coordinator_fit_trimmed_items`,
# lib/coordinator-input.sh) -- the set `unaccounted_items` above no longer
# demands an account for (requirement 3x's exemption, agent-ops#683). Kept as
# its own small pass, keyed the same way `unaccounted_items` keys `skey`,
# rather than folded into that function's own jq program, so the count is
# available for the cycle log independently of whether the verdict needed
# correcting at all -- a cycle whose Co-Ordinator got everything right still
# owes the log this figure.
coordinator_unassessable_items() {  # <eligible-json> <trimmed-json>
  local eligible="${1:-[]}" trimmed="${2:-[]}" docs out
  jq -e 'type == "array"' <<<"$eligible" >/dev/null 2>&1 || eligible='[]'
  jq -e 'type == "array"' <<<"$trimmed" >/dev/null 2>&1 || trimmed='[]'
  docs="$(printf '%s\n' "$eligible" "$trimmed")"
  out="$(jq -nc '
    def skey: ((.repo // "") + "\u0000" + ((.item // "") | tostring) + "\u0000" + (.source // ""));
    input as $eligible | input as $trimmed
    | ($trimmed | map({key: skey, value: true}) | from_entries) as $t
    | [ $eligible[] | select($t[skey] // false) ]
  ' <<<"$docs" 2>&1)" || { guard_warn "coordinator_unassessable_items" "$out"; out='[]'; }
  printf '%s' "$out"
}

# Requirement 3x (issue #322): the Script's own answer to "what could the
# Co-Ordinator actually have selected this cycle", across every band it hands
# over pre-fetched — `{repo, item, source}` per entry, `source` the same token
# the repo's `sources` list, a `needs_refinement` entry and
# `refinement_policy` all use. It is the denominator `unaccounted_items`
# above tests a `selected: false` verdict against, and the reason that
# function needs no per-band special-casing of its own.
#
# Read *after* requirement 2.2a's back-pressure decision, for the reason
# requirement 3t's tech-debt-only predecessor was: a restricted cycle narrows
# every repo's `sources` to the four finishing ones, and a verdict is owed no
# account of a band this cycle forbade it to select from. Which is also why
# each band is gated on the repo's own `sources` here rather than on the array
# merely being non-empty: back-pressure narrows the list without emptying
# `findings`, `register_hygiene` or `human_visibility`, so the list is the
# authority on what was selectable and the array is not.
#
# Three bands need more than "every entry in the array":
#
#   - `issues` is one source at four ranks (requirement 15e), so an issue is
#     eligible only if its own `Priority` band's token is listed — a repo
#     configured `issues:high` alone was never offered its Medium issues.
#   - `issues` also still carries blocked entries after requirement 3u's own
#     pass: `exclude_blocked_or_void_issues` deliberately keeps the ones whose
#     thread has moved, because requirement 18a obliges a live re-read only the
#     Co-Ordinator can perform. A blocked issue is not selectable until that
#     re-read unblocks it, so counting it here would demand an account for an
#     item the Script did not offer. They are dropped on exactly
#     `exclude_blocked_or_void_items`' matching rule, blank `repo` included.
#   - `merge_conflicts` carries the one entry shape the prompt tells the
#     Co-Ordinator to skip in silence: a Dependabot PR this system has not yet
#     asked to rebase (`bot`, no `rebase_requested`, not superseded) is "not a
#     candidate of any kind" there, so it is not one here either. Its
#     superseded sibling *is* eligible — the prompt requires that one in
#     `voided`, which is an account.
#
# Every other band is exactly "an entry's presence in this array is the
# candidate test", which is the prompt's own words for all six of them. A jq
# failure yields `[]` — no corroboration rather than a false one — on the same
# fail-open terms as every exclusion above.
coordinator_eligible_items() {  # <ordered-repos-json> <blocked-json>
  local repos="${1:-[]}" blocked="${2:-[]}" out
  jq -e 'type == "array"' <<<"$repos" >/dev/null 2>&1 || repos='[]'
  jq -e 'type == "array"' <<<"$blocked" >/dev/null 2>&1 || blocked='[]'
  # TD-PPagop-26081407: like unaccounted_items, this is the Co-Ordinator's own
  # eligible-set denominator (requirement 3x) -- a jq failure here reading as
  # `[]` would silently tell the fleet nothing was ever selectable.
  out="$(printf '%s\n%s\n' "$repos" "$blocked" | jq -nc '
    def listed($srcs; $s): (($srcs // []) | index($s)) != null;
    def band($r; $srcs; $arr; $src):
      if (listed($srcs; $src) | not) then empty
      else ($arr // [])[]
           | {repo: $r, item: ((.ref // "") | tostring), source: $src}
           | select(.item != "")
      end;
    input as $repos | input as $blocked
    | ([ $blocked[]? | {key: ((.repo // "") + "\u0000" + ((.item // "") | tostring)), value: true} ]
       | from_entries) as $blocked_here
    | ([ $blocked[]? | select((.repo // "") == "")
                     | {key: ((.item // "") | tostring), value: true} ]
       | from_entries) as $blocked_anywhere
    | [ $repos[]
        | . as $e | (.slug // "") as $r | (.sources // []) as $srcs
        | ( band($r; $srcs; [($e.findings // [])[] | select((.source // "") == "security")]; "security"),
            band($r; $srcs; [($e.findings // [])[] | select((.source // "") == "code-quality")]; "code-quality"),
            band($r; $srcs; $e.review_feedback; "review-feedback"),
            band($r; $srcs;
                 [($e.merge_conflicts // [])[]
                  | select(((.bot // false) | not)
                           or (.rebase_requested // false)
                           or ((.superseded_by // null) != null))];
                 "merge-conflicts"),
            band($r; $srcs; $e.dequeued; "dequeued"),
            band($r; $srcs; $e.abandoned_drafts; "abandoned-drafts"),
            band($r; $srcs; $e.human_visibility; "human-visibility"),
            band($r; $srcs; $e.register_hygiene; "register-hygiene"),
            band($r; $srcs; $e.tech_debt; "tech-debt"),
            ( ($e.issues // [])[]
              | (((.priority // "Medium") | tostring | ascii_downcase)) as $pband
              | select(listed($srcs; "issues") or listed($srcs; "issues:" + $pband))
              | {repo: $r, item: ((.ref // "") | tostring), source: "issues"}
              | select(.item != "")
              | select((($blocked_here[(.repo + "\u0000" + .item)] // false) | not)
                       and (($blocked_anywhere[.item] // false) | not)) ) ) ]
    ' 2>&1)" || { guard_warn "coordinator_eligible_items" "$out"; out='[]'; }
  printf '%s' "$out"
}

# Whether a candidate the Co-Ordinator returned is one this same cycle's own
# gather already saw claimed (requirement 17a). The claim attempt below would
# lose anyway — GitHub still arbitrates — but a loss that was knowable from
# data already in hand is not contention, it is the Co-Ordinator proposing
# claimed work, and counting it as a race loss would both misread the
# dashboard's contention signal and spend claim API calls on a foregone
# conclusion. Matched on the raw item ref and on its branch-sanitised form,
# because a claim branch's name (claim_branch_for) flattens characters the
# ref may carry and gather_claimed derives items back off branch names.
candidate_preclaimed() {  # <repo> <item> <claims-at-gather-json> -> 0 iff already claimed at gather
  local repo="$1" item="$2" claims="$3" sanitised
  sanitised="${item//[^A-Za-z0-9._-]/-}"
  # Exactly 0 or 1, whatever jq's own exit code says: malformed claims JSON
  # must read as "not pre-claimed" (fail open — the atomic claim below stays
  # the gate), never as a distinct status a caller could misread.
  jq -e --arg r "$repo" --arg i "$item" --arg s "$sanitised" \
    'any(.[]; .repo == $r and (.item == $i or .item == $s))' <<<"$claims" >/dev/null 2>&1 \
    || return 1
}

# Requirement 17a/issue #238: which PR a finishing-source candidate targets, for
# the PR-keyed claim below to key on. The candidate's own `pr_number` when it
# carries a usable one — prompts/coordinator.md requires it on all four
# finishing sources' work orders — and otherwise the number the *item ref*
# itself embeds, because all four gather scripts mint their refs with it in
# them by construction (`pr-<n>-review-<id>`, `pr-<n>-conflict-<sha>`,
# `pr-<n>-dequeued-<sha>`, `pr-<n>-abandoned-<sha>`; requirements 3c, 3e, 3z,
# 3g). The fallback is the whole point: this claim is the hard gate that
# excludes a peer fleet-wide, and a gate that engages only when the model
# remembered to copy a field is not one — a single omitted `pr_number` would
# silently reopen the three-nodes-on-PR-#205 failure this exists to close.
# Empty only when neither source yields a number, which for these four
# sources cannot happen without a malformed ref.
pr_number_for_candidate() {  # <candidate-json> <item-ref>
  local n
  n="$(jq -r '.pr_number // empty' <<<"$1" 2>/dev/null || true)"
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    printf '%s' "$n"
  elif [[ "$2" =~ ^pr-([0-9]+)- ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Requirement 34c: an item whose premise is false is void, not blocked. It goes
# to a different event with a different clearing rule, because the Co-Ordinator
# is told to clear blockers that have gone away — and "the work is already done"
# reads to it as a blocker that has gone away, when it is in fact the reason the
# item must never be selected again.
log_item_void() {
  local stage="$1" detail="$2" extra="${3:-{\}}"
  log_event "item-void" \
    "$(item_event_fields "$stage" "$detail" "$selected_repo" "$selected_item" "$extra")"
}

log_unblocked_items() {
  local wo="$1" item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    log_event "unblocked" "$(jq -nc --arg i "$item" '{item: $i}')"
    release_refinement_label "$item"
  done < <(jq -r '.unblocked[]? // empty' <<<"$wo")
}

# Requirement 18a: the Co-Ordinator re-read a blocked GitHub issue whose
# thread had moved and judged the recorded blocker still holds. Unlike
# `unblocked`, this clears nothing — the item stays blocked — it only leaves a
# marker (`recheck_clean_ts`, via lib/cycle-state.sh's `blocked_items`) so a
# later cycle does not re-read the same still-unchanged thread again.
# Entries are `{item, repo}` (requirement 20); a bare id is tolerated and
# logged without `repo`, which the extract folds into every same-numbered
# blocked item — the degraded fallback requirement 33 describes.
log_recheck_clean_items() {
  local wo="$1" entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    log_event "recheck-clean" "$entry"
  done < <(jq -c '
    .recheck_clean[]?
    | if type == "object" then
        {item: (.item // "" | tostring)}
        + (if (.repo // "") != "" then {repo: .repo} else {} end)
      else {item: tostring} end
    | select(.item != "")' <<<"$wo")
}

# --- The refinement class (requirements 16a, 34e) ---------------------------
# An item nobody has specified well enough to work on is blocked by that fact,
# and the Co-Ordinator is the actor that discovers it — while walking candidates
# it was going to walk anyway. It reports; the Script records. That division is
# requirement 36's, and it is what makes the record real: an issue or a label the
# Script did not write is one no later cycle can match against its own log.
#
# The label is a projection of the block onto the one item type that can carry
# one, and it is applied *before* the event is written so the event can record
# whether it took. A label recorded on the block is a label a later cycle knows
# to remove; a label assumed from config is one it might try to remove from an
# issue that never had it, or leave on an issue after the key changed.

# release_refinement_label ITEM [REPO]
# Take the projected labels — `needs_refinement_label`, and `blocked`/
# `blocked:<reason>` (requirement 38b, agent-ops#639) — off the issue behind
# ITEM, if this item's refinement block put them there. Called wherever a
# block clears — the Co-Ordinator's own re-check, an Enabler `unblocked`, and
# a `void` from either — because all three labels' lifecycles mirror the
# block's. A removal that fails here is retried later, not by anything else:
# `needs_refinement_label` by requirement 39f's stale-retry,
# `blocked`/`blocked:<reason>` by the reconciliation sweep beside it
# (agent-ops#651).
#
# Reads the blocked extract this cycle computed *before* the Co-Ordinator ran,
# which is the correct one: the block being cleared is by definition one that was
# open when the cycle started. Best-effort throughout — a stale label is a
# cosmetic fault on an issue, and no reason to disturb a cycle recording state.
release_refinement_label() {
  local item="$1" repo="${2:-}" t_repo t_num t_label
  [[ -n "$item" ]] || return 0
  # A dry run changes nothing in any repository (requirement 12). It still logs
  # the verdicts on this path, as it always has, but a label is an outward act.
  # Written as an `if` rather than `(( DRY_RUN )) && return 0`, whose status
  # would be the function's on the common path — the errexit trap in the
  # Gotchas table, one call site away from a caller that runs under `set -e`.
  if (( DRY_RUN )); then return 0; fi
  while IFS=$'\t' read -r t_repo t_num t_label; do
    [[ -n "$t_repo" && -n "$t_num" && -n "$t_label" ]] || continue
    if refinement_label_remove "$t_repo" "$t_num" "$t_label"; then
      log_event "own-label-action" "$(label_own_action_fields "$t_repo" "$t_num" "$t_label" "remove")"
    else
      log_event "warning" \
        "$(jq -nc --arg d "could not remove the $t_label label from $t_repo#$t_num — the block is cleared regardless" \
           '{detail: $d}')"
    fi
  done < <(refinement_label_targets "${blocked_json:-[]}" "$item" "$repo")
  while IFS=$'\t' read -r t_repo t_num t_label; do
    [[ -n "$t_repo" && -n "$t_num" && -n "$t_label" ]] || continue
    if refinement_label_remove "$t_repo" "$t_num" "$t_label"; then
      log_event "own-label-action" "$(label_own_action_fields "$t_repo" "$t_num" "$t_label" "remove")"
    else
      log_event "warning" \
        "$(jq -nc --arg d "could not remove the $t_label label from $t_repo#$t_num — the block is cleared regardless" \
           '{detail: $d}')"
    fi
  done < <(refinement_blocked_label_targets "${blocked_json:-[]}" "$item" "$repo")
}

# record_needs_refinement_block ENTRY STAGE
# Record one needs_refinement-shaped ENTRY (`{repo, item, source, reason,
# missing, evidence}`) as a block attributed to STAGE (requirement 34e).
# Returns 1 and records nothing but a `warning` when ENTRY fails requirement
# 34d's completeness bar, the item is already blocked, or it re-asserts a
# `Blocked-by:` dependency this cycle's own gate already resolved.
#
# The single recorder for every stage that can report this class of block —
# the Co-Ordinator (requirement 16a), the Implementer's escape hatch
# (requirement 9f), and the Refiner's own decline (requirement 39d). One
# definition (requirement 34a): three reporters, one recorder, so the labels
# and the block's shape can never drift between them.
#
# Three entries are dropped rather than recorded, each with a warning, and all
# three refusals are the Script's job rather than the reporting stage's:
#
#   - a malformed entry, on requirement 34d's discipline. The fields are what the
#     Enabler starts from; an entry without them starves the very stage this
#     path exists to reach.
#   - a re-report of an item that is *already* blocked. Requirement 34 keys a
#     block on repo+item and requirement 35a measures the Enabler threshold from
#     the latest one, so re-reporting the same item every cycle would push that
#     clock forward cycle after cycle and the item would never become eligible —
#     the same silent starvation this whole path exists to end, with an event
#     trail that looks like progress.
#   - a `source: "issues"` entry whose own `reason`/`missing`/`evidence` names,
#     by number, the same `Blocked-by:` dependency this cycle's
#     `issues_by_repo_json` already proves resolved for that item's thread
#     (`dependency_refusal_reason`, lib/dependency-gate.sh; issue #566).
#     Requirement 16's dependency exclusion is deterministic and applied by the
#     Script before any candidate reaches a reporting stage — re-asserting it
#     from a thread's own stale prose is never a legitimate reason to decline an
#     item, and recording one as a block would silently blind selection to an
#     item the gate already cleared.
#   - a Co-Ordinator report naming an item this same cycle's fit ladder
#     actually trimmed (`coordinator_fit_trim_refusal_reason`,
#     lib/coordinator-input.sh; requirement 4i; agent-ops#683), logged as a
#     warning naming the item and the rung. A trimmed candidate's body can be
#     as little as a title-level fragment, and "if you cannot tell what done
#     would mean, report needs_refinement" then compels a report the
#     completeness bar (requirement 3x) would otherwise force the Script to
#     record as a block — nine items, most of them already refined, flagged
#     `needs-refinement` in 68 seconds on 2026-08-21 (and, before
#     agent-ops#651 ended that separate path, re-assigned too), on a cycle
#     whose Co-Ordinator did nothing wrong. Scoped to `stage == "coordinator"`:
#     the Refiner and Implementer read the repository live rather than off
#     this cycle's Co-Ordinator input, so a fit-ladder mark on that input says
#     nothing about what either of them actually had in front of them.
record_needs_refinement_block() {
  local entry="$1" stage="$2" repo item reason problem label blocked_label blocked_reason_label reason_label number who
  who="$(pipeline_actor_label "$stage")"
  if ! problem="$(refinement_entry_problem "$entry")"; then
    log_event "warning" "$(jq -nc --arg d "$who needs_refinement entry dropped — it $problem" \
      '{detail: $d}')"
    return 1
  fi
  repo="$(jq -r '.repo // ""' <<<"$entry")"
  item="$(jq -r '.item // ""' <<<"$entry")"
  reason="$(jq -r '.reason // "no reason given"' <<<"$entry")"

  if jq -e --arg r "$repo" --arg i "$item" \
       'any(.[]?; (.repo // "") == $r and ((.item // "") | tostring) == $i)' \
       <<<"${blocked_json:-[]}" >/dev/null 2>&1; then
    log_event "warning" "$(jq -nc \
      --arg d "$who reported $repo $item as needing refinement, but it is already blocked — left as it is so the Enabler threshold keeps running" \
      '{detail: $d}')"
    return 1
  fi

  if ! problem="$(dependency_refusal_reason "$entry" "${issues_by_repo_json:-{\}}")"; then
    log_event "warning" "$(jq -nc --arg d "$who needs_refinement entry for $repo $item refused — it $problem" \
      '{detail: $d}')"
    return 1
  fi

  if [[ "$stage" == "coordinator" ]] \
     && ! problem="$(coordinator_fit_trim_refusal_reason "$entry" "${coordinator_fit_trimmed_json:-[]}" "${coordinator_fit_rung:-0}")"; then
    log_event "warning" "$(jq -nc --arg d "$who needs_refinement entry for $repo $item refused — it $problem" \
      '{detail: $d}')"
    return 1
  fi

  # No label on a dry run, and — because the event records what was actually
  # applied — none recorded either, so nothing later tries to remove
  # something that was never there.
  label=""
  blocked_label=""
  blocked_reason_label=""
  if ! (( DRY_RUN )); then
    number="$(refinement_issue_number "$entry")"
    if [[ -n "$number" ]]; then
      if [[ -n "$needs_refinement_label" ]]; then
        if refinement_label_add "$repo" "$number" "$needs_refinement_label"; then
          label="$needs_refinement_label"
          log_event "own-label-action" \
            "$(label_own_action_fields "$repo" "$number" "$needs_refinement_label" "add")"
        else
          log_event "warning" "$(jq -nc \
            --arg d "could not apply the $needs_refinement_label label to $repo#$number (does it exist in that repo?) — the block is recorded either way" \
            '{detail: $d}')"
        fi
      fi
      # Requirement 38b (agent-ops#639, read-before-write agent-ops#651): a
      # block gated on a decision the human has not made gets `blocked` — the
      # generic hold marker `scripts/gather-issues.sh` already excludes on —
      # plus a reason label naming why, so it reaches the human's own
      # filtered issue list the moment it is recorded, rather than waiting
      # for the Enabler's own, much later, escalation. Through
      # `refinement_label_project`, not `refinement_label_add`: `blocked` is
      # also a human's own, hand-applied control (`lib/labels.sh`'s own
      # catalogue), so a pre-existing instance — applied for the human's own
      # reasons before this block existed — is left exactly as found and
      # recorded as nothing, the same read-before-write contract the deleted
      # `refinement_assignee_project` once gave the assignment this replaced.
      case "$(refinement_label_project "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL")" in
        added)
          blocked_label="$REFINEMENT_BLOCKED_LABEL"
          log_event "own-label-action" \
            "$(label_own_action_fields "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL" "add")"
          ;;
        present) ;;
        unrecorded)
          log_event "warning" "$(jq -nc \
            --arg d "could not read $repo#$number's labels — $REFINEMENT_BLOCKED_LABEL was applied best-effort but not recorded on the block, so clearing it will not remove it" \
            '{detail: $d}')"
          ;;
        *)
          log_event "warning" "$(jq -nc \
            --arg d "could not apply the $REFINEMENT_BLOCKED_LABEL label to $repo#$number — the block is recorded either way" \
            '{detail: $d}')"
          ;;
      esac
      # `blocked:<reason>` keeps the unconditional lifecycle `needs_refinement_label`
      # already has: no human reaches for this compound name on their own, so
      # there is nothing here to read back before writing.
      reason_label="$(refinement_blocked_reason_label "$REFINEMENT_BLOCK_KIND")"
      if [[ -n "$reason_label" ]]; then
        if refinement_label_add "$repo" "$number" "$reason_label"; then
          blocked_reason_label="$reason_label"
          log_event "own-label-action" \
            "$(label_own_action_fields "$repo" "$number" "$reason_label" "add")"
        else
          log_event "warning" "$(jq -nc \
            --arg d "could not apply the $reason_label label to $repo#$number — the block is recorded either way" \
            '{detail: $d}')"
        fi
      fi
      # Requirement 39d: a fresher block supersedes an existing refinement, so
      # a `refined_label` a prior Refiner engagement left must come off too —
      # the same consistency `release_refinement_label` keeps for the negative
      # label, mirrored here for the positive one.
      if [[ -n "$refined_label" ]] && [[ -n "$number" ]] && jq -e --arg r "$repo" --arg i "$item" \
           '(.[$r][$i] // null) != null' <<<"${refinements_json:-{\}}" >/dev/null 2>&1; then
        if refinement_label_remove "$repo" "$number" "$refined_label"; then
          log_event "own-label-action" \
            "$(label_own_action_fields "$repo" "$number" "$refined_label" "remove")"
        else
          log_event "warning" "$(jq -nc \
            --arg d "could not remove the $refined_label label from $repo#$number — the fresher block is recorded regardless" \
            '{detail: $d}')"
        fi
      fi
    fi
  fi

  log_event "attempt-failed" "$(item_event_fields "$stage" "$reason" "$repo" "$item" \
    "$(refinement_block_fields "$entry" "$label" "$blocked_label" "$blocked_reason_label")")"
  return 0
}

# log_needs_refinement_items WORK_ORDER
# Record every one of the Co-Ordinator's `needs_refinement` reports via
# `record_needs_refinement_block`, attributed to `stage: "coordinator"`.
#
# Collects the entries the recorder actually accepted into
# `coord_recorded_refinement_json` for requirement 3t's corroboration, which
# must count what was recorded and never what was claimed: an entry dropped
# at requirement 34d's bar records nothing, so its item stays eligible, and
# letting it account for that item anyway would arm the no-op fingerprint on
# a verdict that never engaged with the band (see
# unaccounted_items). The already-blocked refusal also lands here
# uncounted, harmlessly — a blocked item was never in the eligible set to
# need accounting for.
log_needs_refinement_items() {
  local wo="$1" entry
  coord_recorded_refinement_json="[]"
  while IFS= read -r entry; do
    if record_needs_refinement_block "$entry" "coordinator"; then
      # $entry and the accumulator both arrive on stdin, one document per
      # line, bound positionally with `input as $name` in the order printed
      # (requirement 4g) — never in argv: this accumulator grows with the
      # cycle's whole needs_refinement band, and its builder failing silently
      # fail-opens unaccounted_items to [] (TD-PPagop-26081406).
      coord_recorded_refinement_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
        <<<"$coord_recorded_refinement_json"$'\n'"$entry")"
    fi
  done < <(jq -c '.needs_refinement[]? // empty' <<<"$wo" 2>/dev/null || true)
}

# The Co-Ordinator may void a candidate it can see conclusively is already done,
# rather than paying an Implementer cycle to reach the same verdict. Entries are
# objects (item/repo/reason/evidence), unlike `unblocked`'s bare ids, because a
# void is terminal and worth recording precisely; an entry naming no item is
# ignored.
#
# Requirement 34d: it is corroborated before it is made permanent. The
# Co-Ordinator is the one void author that never reads the tree — it sees a JSON
# digest of candidates and nothing else — so an assertion it makes about the
# default branch is checked against the facts the same cycle gathered, against
# a resolvable `evidence` citation fetched from the repository itself, and
# against requirement 34c's long-standing demand for evidence being present at
# all. An entry the guard refuses is recorded `blocked` instead: the
# Co-Ordinator still skips the item, so nothing churns, but the record is
# clearable and Enabler-eligible (requirement 35a), so an actor that can read
# the tree gets to adjudicate rather than the item disappearing on an unchecked
# claim. See lib/void-guard.sh for what the guard tests and why it is not a
# prompt instruction.
#
# Collects every entry it disposed of into `coord_recorded_voided_json` for
# requirement 3t's corroboration — and "disposed of" deliberately includes a
# refusal, unlike log_needs_refinement_items' collection just above, because
# here both outcomes write state: a pass records the void, a refusal records
# a block, and either takes the item out of the next cycle's eligible set. An
# entry naming no item is the one thing that records nothing, and it is the
# one thing not collected.
#
# `flags_json` is read once, here, rather than once per entry inside the
# loop below (issue #508): within one invocation the union log is a snapshot
# already fixed before this function runs, so `draft_obsolete_flags` gives
# the same answer on entry ten as it did on entry one — recomputing it per
# entry paid two full log scans for a result that never changed. It is
# handed to `void_obsolete_ctx_json` below, which still reads the kill-switch
# level itself, live, per entry (see that function's own comment for why).
log_voided_items() {
  local wo="$1" repos="${2:-[]}" entry item repo reason refusal flags_json
  flags_json="$(draft_obsolete_flags "${union_log:-$log_file}")"
  coord_recorded_voided_json="[]"
  while IFS= read -r entry; do
    item="$(jq -r '.item // ""' <<<"$entry")"
    [[ -n "$item" ]] || continue
    repo="$(jq -r '.repo // ""' <<<"$entry")"
    reason="$(jq -r '.reason // "no reason given"' <<<"$entry")"
    # $entry and the accumulator both arrive on stdin, one document per
    # line, bound positionally with `input as $name` in the order printed
    # (requirement 4g) — never in argv: see log_needs_refinement_items above
    # for why this accumulator's builder failing silently matters
    # (TD-PPagop-26081406).
    coord_recorded_voided_json="$(jq -nc 'input as $arr | input as $e | $arr + [$e]' \
      <<<"$coord_recorded_voided_json"$'\n'"$entry")"

    if refusal="$(void_guard_reason "$entry" "$repos" "$(void_obsolete_ctx_json "$repo" "$flags_json")")"; then
      log_event "item-void" "$(item_event_fields "coordinator" "$reason" "$repo" "$item" \
        "$(jq -nc --arg e "$(void_entry_evidence "$entry")" '{evidence: $e}')")"
      # An item with no work needs no refinement either: the label goes, on the
      # same rule that takes it off an unblocked item (requirement 34e).
      release_refinement_label "$item" "$repo"
      continue
    fi

    # Two events, deliberately. The `warning` is what a human scanning the
    # dashboard sees — an agent tried to make something permanent and was wrong,
    # which is worth knowing even though the cycle recovered. The
    # `attempt-failed` is the state: it blocks the item on repo+item exactly as
    # any other failed attempt does (requirement 34), which is what puts it in
    # front of the Enabler.
    log_event "warning" "$(jq -nc \
      --arg d "co-ordinator void refused for ${repo:-<no repo>} $item — $refusal; recorded blocked instead" \
      '{detail: $d}')"
    log_event "attempt-failed" "$(item_event_fields "coordinator" \
      "void refused ($refusal). The Co-Ordinator's stated reason was: $reason" "$repo" "$item" \
      "$(jq -nc --arg c "Establish from the repository itself whether this item describes any remaining work." \
        '{unblock_condition: $c}')")"
  done < <(jq -c '.voided[]? // empty' <<<"$wo" 2>/dev/null || true)
}

detect_and_log_limit_hit() {
  local out_file="$1" text resume_at class reset_known evidence=""
  # Two sources, and the structured one comes first because it is better
  # evidence, not merely earlier: the stream's own `rate_limit_info` carries
  # an epoch reset time, so the stand-down is a fact rather than the estimate
  # a prose parse has to settle for — and an estimated stand-down costs the
  # fleet a probe every cycle until it clears (requirement 2.1b). It also
  # exists on a path the prose parse cannot reach at all: a stage stopped the
  # moment the account refused never wrote a final message for the phrase
  # matcher to read.
  if [[ -n "${stage_rate_limit_json:-}" ]] \
     && IFS=$'\t' read -r resume_at class reset_known \
          < <(limit_decide_structured "$stage_rate_limit_json" "$limit_cooldown_default_hours"); then
    limit_hit_this_cycle=1
    evidence="$stage_rate_limit_json"
  else
    limit_phrase_in "$out_file" "$out_file.stderr" || return 1
    # Remembered for the rest of the cycle, because the Enabler runs from the exit
    # trap — after this point on every path — and engaging the fleet's most
    # expensive model moments after any stage hit a limit would simply re-hit it
    # (requirement 35's guards).
    limit_hit_this_cycle=1
    text="$(cat "$out_file" "$out_file.stderr" 2>/dev/null || true)"
    IFS=$'\t' read -r resume_at class reset_known < <(limit_decide "$text" "$limit_cooldown_default_hours")
    evidence="$(grep -ihE "$LIMIT_PHRASE_REGEX" "$out_file" "$out_file.stderr" 2>/dev/null | head -n1 || true)"
  fi
  # The API's own words, bounded: what the detector actually saw is what
  # distinguishes an automatic stand-down from an assertion, and is what a
  # later extension must bring fresh (requirement 2; #244).
  evidence="${evidence:0:400}"
  log_event "limit-hit" "$(jq -nc --arg r "$resume_at" --arg c "$class" --argjson k "$reset_known" \
    --arg n "$node_name" --arg e "$evidence" \
    '{resume_at: $r, class: $c, reset_known: $k, kind: "auto", actor: $n,
      evidence: (if $e == "" then null else $e end)}')"
  # Tell the fleet now, not a fetch interval from now: publish the stand-down
  # as fleet/limit.json (extend-only; requirement 2.1). Best-effort — the
  # limit-hit event above is already in this node's log, and the union carries
  # it to every peer on their next fetch regardless.
  fleet_limit_publish "$state_repo" "$state_dir" "$resume_at" "$class" "$reset_known" "$node_name" "$evidence" \
    || log_event "warning" "$(jq -nc \
         '{detail: "could not publish fleet/limit.json — peers will pick the cooldown up from the log union instead"}')"
}

extract_pr_url() {
  grep -oihE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' "$1" "$1.stderr" 2>/dev/null | tail -n1 || true
}

# Deterministically pre-fetch a repo's open Dependabot and code-scanning
# findings (requirement 3a) so the Co-Ordinator reads them instead of spending
# model tokens paginating those APIs itself. gather-findings.sh always prints
# valid JSON and never fails a cycle; this guards its output anyway and
# degrades to an empty array, teeing the result into the cycle dir for
# debugging.
#
# Also records whether this cycle's own read succeeded, for requirement 34n's
# liveness retirement (TD-PPagop-26081303): a `findings-$safe.ok` marker,
# written iff gather-findings.sh's own contract says so (exit 0 — a disabled
# feature or a legitimately empty answer; exit 1 on a real failure). The void-
# liveness pass, further down this cycle, reads the marker and the tee'd
# `.json` array together — `ok` decides whether the array may be trusted as
# "every alert still open", never whether it is non-empty.
gather_findings() {
  local slug="$1" out safe rc
  safe="${slug//\//_}"
  if out="$("$SCRIPT_DIR/scripts/gather-findings.sh" "$slug" 2>"$cycle_dir/findings-$safe.err")"; then
    rc=0
  else
    rc=$?
  fi
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/findings-$safe.json"
    printf '%s' "$out"
    # The marker requires *both* halves: a zero exit and a tee file the
    # liveness pass can actually read. gather-findings.sh exits 0 on paths
    # that can still leave stdout unusable (its final `jq -n` failing prints
    # nothing yet falls through to `exit 0`), and a marker written without
    # the `.json` beside it reads downstream as "gathered, found nothing" —
    # the one sentence this marker exists to stop the cycle saying.
    (( rc == 0 )) && : > "$cycle_dir/findings-$safe.ok"
  else
    printf '[]'
  fi
  return 0
}

# Sample the change-detection signals the no-op short-circuit (requirement 3b)
# fingerprints. Unlike gather_findings, this output is never shown to the
# Co-Ordinator — it is a proxy for the reads the Co-Ordinator performs itself —
# so a degraded result must be marked, not silently accepted: an unusable
# sample yields `{"ok": false}` here and the cycle simply declines to
# fingerprint, which costs one Co-Ordinator run and never a missed one.
# Pre-fetch the PRs waiting on us to answer a human's review (requirement 3c).
# Same rationale as gather_findings, plus one specific to this source: the
# review prose must reach the Implementer verbatim, and the candidate rule
# ("is it our turn?") has to exist for the fingerprint anyway, so it gets one
# definition and both consumers read it (requirement 34a).
gather_review_feedback() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-review-feedback.sh" "$slug" "$pr_label" "$branch_prefix" \
        2>"$cycle_dir/review-feedback-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/review-feedback-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the draft PRs this system raised and then abandoned (requirement 3e).
# Same rationale as gather_review_feedback, plus the one specific to this source:
# its candidacy turns on the clock (a draft crossing the staleness threshold), so
# the array must be computed here and fed to the fingerprint verbatim for the
# no-op short-circuit to notice the transition (see scripts/gather-abandoned-drafts.sh
# and lib/noop-skip.sh).
gather_abandoned_drafts() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-abandoned-drafts.sh" "$slug" "$pr_label" "$branch_prefix" "$abandoned_draft_after_hours" \
        2>"$cycle_dir/abandoned-drafts-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/abandoned-drafts-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the ready-but-conflicted PRs this system raised (requirement 3g),
# plus Dependabot's own conflicted PRs (requirement 3s, issue #250). Same
# rationale as gather_abandoned_drafts: its candidacy turns on a transition
# the open-PR digest does not carry (a PR flips to CONFLICTING a cycle after its
# base moved, as GitHub recomputes mergeability asynchronously), so the array
# must be computed here and fed to the fingerprint verbatim for the no-op
# short-circuit to notice it (see scripts/gather-merge-conflicts.sh and
# lib/noop-skip.sh). A `bot` candidate gets one more step before either of
# those: scripts/nudge-dependabot-rebase.sh, which posts a first `@dependabot
# rebase` request and drops that candidate from the array this cycle — see
# the comment inside the function below.
gather_merge_conflicts() {
  local slug="$1" out safe nudge_result
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-merge-conflicts.sh" "$slug" "$pr_label" "$branch_prefix" \
        2>"$cycle_dir/merge-conflicts-$safe.err" || true)"
  # Requirement 34n's liveness retirement (TD-PPagop-26081303): a
  # `merge-conflicts-$safe.ok` marker, written iff this cycle's own read
  # produced a valid array and said nothing on stderr. gather-merge-
  # conflicts.sh always exits 0 by design (its output feeds the Co-Ordinator,
  # and a source that cannot look must simply not fire rather than abort the
  # cycle), so stderr is the only signal a real `gh` failure leaves — the same
  # distinction scripts/gather-register-hygiene.sh draws between "empty
  # because there is nothing" and "empty because it could not look".
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 \
     && [[ ! -s "$cycle_dir/merge-conflicts-$safe.err" ]]; then
    : > "$cycle_dir/merge-conflicts-$safe.ok"
  fi
  if [[ -z "$out" ]] || ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '[]'
    return
  fi

  # The nudge-then-takeover half of Dependabot-conflict handling (requirement
  # 3s, issue #250): a `bot` candidate this script has never yet asked to
  # rebase gets that ask now — a real write, so `--dry-run` skips it, exactly
  # like every other sweep in this cycle. Whatever it drops from the array
  # (the candidate it just nudged) is dropped from *both* what is stored below
  # for the fingerprint and what reaches the Co-Ordinator: the first sighting
  # of a conflict and the first nudge for it happen in the same cycle, so
  # there is genuinely nothing selectable yet, and the fingerprint should read
  # that the same way the Co-Ordinator does. The transition still surfaces —
  # next cycle's gather-merge-conflicts.sh reports `rebase_requested: true`
  # for the same head, a different array shape from this cycle's, which busts
  # the fingerprint on its own.
  if (( DRY_RUN )); then
    printf '%s\n' "$out" > "$cycle_dir/merge-conflicts-$safe.json"
    printf '%s' "$out"
    return
  fi

  nudge_result="$(printf '%s' "$out" \
      | "$SCRIPT_DIR/scripts/nudge-dependabot-rebase.sh" "$slug" "$cycle_id" "$node_name" \
        2>"$cycle_dir/dependabot-nudge-$safe.err" || true)"
  if [[ -z "$nudge_result" ]] || ! jq -e 'type == "object"' <<<"$nudge_result" >/dev/null 2>&1; then
    # The nudge step failing is not this array's failure — fall back to the
    # gatherer's own output rather than losing every candidate in this repo
    # (including our own, non-bot ones) over one broken write step. Still
    # drop any bot candidate that has never been nudged (`bot: true`,
    # `rebase_requested: false`, no `superseded_by`) — the same predicate
    # nudge-dependabot-rebase.sh itself applies — so a broken nudge step
    # cannot hand the Co-Ordinator's ordinary-case catch-all an un-nudged
    # bot branch to force-push (requirement 3s). A wholly-broken nudge step
    # reaches no other log: it returns before the per-candidate loop below,
    # so without this, a permanently broken step would silently skip every
    # conflicted Dependabot PR, every cycle, forever (requirement 3s).
    log_event "warning" "$(jq -cn --arg r "$slug" \
      '{detail: ("nudge-dependabot-rebase.sh produced no usable result for " + $r + " — falling back to the gatherer'"'"'s own read")}')"
    # `out` is only validated as `type == "array"` above, not that its elements
    # are objects — `.bot` on a non-object element is a `jq` error under
    # `set -euo pipefail`, and this is the one path where a malformed-but-array
    # gatherer output meets an already-broken nudge step. Degrade to an empty
    # array rather than aborting the cycle over it (requirement 3s).
    if ! out="$(jq -c '[.[] | select(
        ((.bot // false) == true)
        and ((.rebase_requested // false) == false)
        and ((.superseded_by // null) == null)
        | not)]' <<<"$out" 2>"$cycle_dir/merge-conflicts-filter-$safe.err")"; then
      log_event "warning" "$(jq -cn --arg r "$slug" \
        '{detail: ("could not filter un-nudged Dependabot candidates for " + $r + " — malformed gatherer output; dropping all candidates for this repo this cycle")}')"
      out='[]'
    fi
    printf '%s\n' "$out" > "$cycle_dir/merge-conflicts-$safe.json"
    printf '%s' "$out"
    return
  fi

  while IFS= read -r nudge_action; do
    [[ -n "$nudge_action" ]] || continue
    if [[ "$(jq -r '.outcome // ""' <<<"$nudge_action")" == "requested" ]]; then
      log_event "dependabot-rebase-requested" \
        "$(jq -c --arg r "$slug" '{repo: $r} + del(.outcome)' <<<"$nudge_action")"
    else
      log_event "warning" "$(jq -c --arg r "$slug" \
        '{detail: ("could not post @dependabot rebase on " + $r + " #" + (.number | tostring))}' \
        <<<"$nudge_action")"
    fi
  done < <(jq -c '.actions[]?' <<<"$nudge_result" 2>/dev/null || true)

  out="$(jq -c '.conflicts' <<<"$nudge_result")"
  printf '%s\n' "$out" > "$cycle_dir/merge-conflicts-$safe.json"
  printf '%s' "$out"
}

# Pre-fetch the ready PRs this system raised that GitHub's merge queue
# dequeued over a merge-group checks failure (TD-PPagop-26081409, requirement
# 3z). Same rationale as gather_merge_conflicts: a dequeue is a transition the
# open-PR digest cannot see at all (no commit lands, `updatedAt` barely
# moves), so the array is computed here and fed to the fingerprint verbatim
# for the no-op short-circuit to notice it (see scripts/gather-dequeued.sh and
# lib/noop-skip.sh). No nudge-then-takeover step exists for this source — no
# bot is involved — so unlike gather_merge_conflicts this is a direct pass
# through to the gatherer script.
gather_dequeued() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-dequeued.sh" "$slug" "$pr_label" "$branch_prefix" \
        2>"$cycle_dir/dequeued-$safe.err" || true)"
  # Requirement 34n's liveness retirement, same marker discipline as
  # `merge-conflicts-$safe.ok`: written iff this cycle's own read produced a
  # valid array and said nothing on stderr.
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 \
     && [[ ! -s "$cycle_dir/dequeued-$safe.err" ]]; then
    : > "$cycle_dir/dequeued-$safe.ok"
  fi
  if [[ -z "$out" ]] || ! jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '[]'
    return
  fi
  printf '%s\n' "$out" > "$cycle_dir/dequeued-$safe.json"
  printf '%s' "$out"
}

# Pre-fetch the repo's TECH-DEBT.md when it disagrees with itself (requirement
# 3i). Unlike the three above this one's candidacy is a pure function of one
# file's content, so the repo's head SHA would already wake the cycle that
# introduced the drift; the array is fed to the fingerprint verbatim anyway, for
# uniformity with its siblings and because editing scripts/td-check.pl changes
# candidacy with no commit to the target repo at all (see
# scripts/gather-register-hygiene.sh and lib/noop-skip.sh).
#
# PURPOSE, like gather_review_status's own, names the asking pass — `prefetch`
# (this repo walk) or `void` (requirement 34l's void re-derivation below) —
# and lands in the diagnostic filenames. Unlike its siblings this function has
# *two* callers per cycle for the same repo, and before they were separated
# the second one's tee silently overwrote the first's: gather-register-
# hygiene.sh prints `[]` on stdout for every failure path (a rate limit, a
# network blip, a branch moved between the two — the exact cases the void pass
# below names), which is a valid array, so a failed second read replaced a
# successful first read's array with an empty one while the `.ok` marker that
# read had already written stayed put. The liveness pass then read
# marker-present plus no ids as "gathered, found nothing" and retired every
# still-live `register-hygiene-<hash>` void in the repo — a retirement caused
# by a failed read, which is the one thing the marker exists to prevent.
gather_register_hygiene() {
  local slug="$1" branch="$2" purpose="$3" void="${4:-[]}" out safe
  safe="$purpose-${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-register-hygiene.sh" "$slug" "$branch" "$void" \
        2>"$cycle_dir/register-hygiene-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/register-hygiene-$safe.json"
    printf '%s' "$out"
    # Requirement 34n's liveness retirement (TD-PPagop-26081303): a
    # `register-hygiene-$safe.ok` marker, written iff this read said nothing
    # on stderr. gather-register-hygiene.sh always exits 0 by design (a real
    # API failure is deliberately as silent, on stdout, as "no register" —
    # see its own header — with the diagnosis reaching only stderr), so
    # stderr emptiness is the one signal a real failure leaves. Written as a
    # full `if`, not a `&&` list: this is the last command in the function,
    # and a bare `&&` whose test fails would return 1 from the function
    # itself — which under `set -e` aborts the whole cycle at the plain
    # assignment the void-register-hygiene pass below makes.
    if [[ ! -s "$cycle_dir/register-hygiene-$safe.err" ]]; then
      : > "$cycle_dir/register-hygiene-$safe.ok"
    fi
  else
    printf '[]'
  fi
}

# Pre-fetch this repo's still-live human-visibility violations (requirement
# 38e) — its own source, `human-visibility` (issue #284's decision 2), never
# `gather_register_hygiene`'s: a violation is a fact about GitHub's live
# pull-request state, unrelated to the register content that source reasons
# about, so the two never share a candidate or a ref (see
# scripts/gather-human-visibility-hygiene.sh). `violations` is the fleet-wide
# array `human_visibility_violations` produced from the union log; the script
# itself filters to this repo's slice. Piped on stdin, never argv — it is
# unbounded past this call and subject to `MAX_ARG_STRLEN` exactly as `jq
# --argjson` is (requirement 4g; tech-debt/TD-PPagop-26081502.md).
gather_human_visibility_hygiene() {
  local slug="$1" violations="${2:-[]}" out safe
  safe="${slug//\//_}"
  out="$(printf '%s' "$violations" | "$SCRIPT_DIR/scripts/gather-human-visibility-hygiene.sh" "$slug" "$pr_label" \
        2>"$cycle_dir/human-visibility-hygiene-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/human-visibility-hygiene-$safe.json"
    # The `.ok` marker requirement 34n's liveness rule reads back
    # (agent-ops#646), written on exactly the condition the four shapes beside
    # it use: this cycle produced a definite answer for this repo. The
    # gatherer prints a valid array only when it completed — every failure
    # path leaves stdout empty or unparseable and lands in the `else` below —
    # and an empty array from a completed run is a real "no ref survives",
    # not an unknown. Without the marker, `void_liveness_actioned` reads the
    # repo as ungathered and decides nothing, which is the safe direction and
    # what this whole file's `ok` convention exists to express.
    : > "$cycle_dir/human-visibility-hygiene-$safe.ok"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the repo's open issues, whole threads included (requirement 3j) —
# the deterministic exclusions (assigned, labelled `blocked`, unresolved
# `Blocked-by:`, pull requests) already applied, the judgement ones left to
# the Co-Ordinator. This source used to be the Co-Ordinator's own `gh` read,
# and a cycle was observed skipping the entire walk on a "the input carries
# no issues" misreading; the array makes the candidate set an input rather
# than an errand (see scripts/gather-issues.sh for the incident and the
# contract).
#
# issues_excluded_sidecar_path SLUG — the sibling exclusion-report path
# `gather_issues` writes and `gather_issues_excluded` reads back for SLUG.
# Computed once, here, so the two functions cannot drift apart on how `safe`
# is derived from a slug containing `/` (review decision on agent-ops#452,
# concern 2) — before this, each computed its own `safe` independently and
# agreement between them depended on nothing but the two literal expressions
# staying identical.
issues_excluded_sidecar_path() {
  local slug="$1" safe
  safe="${slug//\//_}"
  printf '%s' "$cycle_dir/issues-excluded-$safe.json"
}

# scripts/gather-issues.sh now prints `{candidates, excluded}` rather than a
# bare array (agent-ops#447): `candidates` is written to `issues-$safe.json`
# exactly as the whole array always was, so this function still *returns*
# a bare array and every caller of `gather_issues` is unchanged. `excluded`
# — the number and reason for every deterministic drop — is written
# alongside it to `issues_excluded_sidecar_path`'s path, read back by the
# caller (below) to log it and fold it into the Co-Ordinator's own runtime
# input, because a drop nothing downstream could see was the defect: see
# `gather_issues_excluded`.
gather_issues() {
  local slug="$1" out safe raw candidates excl
  safe="${slug//\//_}"
  raw="$("$SCRIPT_DIR/scripts/gather-issues.sh" "$slug" \
        2>"$cycle_dir/issues-$safe.err" || true)"
  # `excl` defaults to `null`, not `[]` (review decision on agent-ops#452
  # concern 3): a gather that failed to produce the object shape at all —
  # the catastrophic case this fallback covers, distinct from the
  # gatherer's own degrade() — knows nothing about what was excluded, and
  # `null` says so. The existing `.excluded | type == "array"` check below
  # already routes a gatherer-reported `excluded: null` (its own degrade)
  # to this same default.
  candidates='[]'; excl='null'
  if [[ -n "$raw" ]] && jq -e 'type == "object"' <<<"$raw" >/dev/null 2>&1; then
    if jq -e '.candidates | type == "array"' <<<"$raw" >/dev/null 2>&1; then
      candidates="$(jq -c '.candidates' <<<"$raw")"
    fi
    if jq -e '.excluded | type == "array"' <<<"$raw" >/dev/null 2>&1; then
      excl="$(jq -c '.excluded' <<<"$raw")"
    fi
  fi
  out="$candidates"
  printf '%s\n' "$out" > "$cycle_dir/issues-$safe.json"
  printf '%s\n' "$excl" > "$(issues_excluded_sidecar_path "$slug")"
  printf '%s' "$out"
}

# gather_issues_excluded SLUG — read back the sibling exclusion report
# `gather_issues` (above) just wrote for this repo, or `null` if it never ran
# (a repo whose `sources` carries no `issues` band) or the sidecar does not
# hold a well-formed array (the gather failed or degraded). `null` here means
# exactly what it means on the sidecar: the exclusion set is unknown, not
# known-empty (review decision on agent-ops#452 concern 3) — the absent-file
# case cannot arise at the one call site, which runs immediately after
# `gather_issues`, so it is not worth a separate `[]` reading. Kept a
# separate read rather than a second return value, because a shell function
# has only the one stdout channel and `gather_issues` already spends it on
# the candidates array every existing caller depends on.
gather_issues_excluded() {
  local slug="$1" file
  file="$(issues_excluded_sidecar_path "$slug")"
  if [[ -s "$file" ]] && jq -e 'type == "array"' <"$file" >/dev/null 2>&1; then
    jq -c '.' <"$file"
  else
    printf 'null'
  fi
}

# Pre-fetch the repo's open tech-debt register items (requirement 3t, issue
# #310) — the same move issues, findings, review-feedback, merge-conflicts,
# abandoned-drafts and register-hygiene already got: a source the model could
# silently misdescribe or decline to re-derive becomes an input instead of an
# errand. Claimed-item exclusion is applied by the caller via
# exclude_claimed_items, like every other pre-fetched array; blocked/void
# exclusion is applied by a second pass once blocked_json/void_json exist (see
# "3c/3u. Pre-fetched-band eligibility" below) — this function only ever
# returns the raw open set.
gather_tech_debt() {
  local slug="$1" branch="$2" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-tech-debt.sh" "$slug" "$branch" \
        2>"$cycle_dir/tech-debt-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/tech-debt-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the most recent repository review's recommendations, for the Refiner
# only (requirement 3y; TD-PPagop-26081307) — never folded into
# `ordered_repos_json`, the Co-Ordinator's own input, which still reads
# `reviews/…` live (prompts/coordinator.md's "Project-review
# recommendations"). Called only for a repo whose `refinement_policy` for
# `project-review` is not exempt, the same "pay nothing unless it's wanted"
# rule tech_debt's own pre-fetch already follows for its `sources` gate.
gather_project_review_candidates() {
  local slug="$1" branch="$2" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-project-review.sh" "$slug" "$branch" \
        2>"$cycle_dir/project-review-candidates-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/project-review-candidates-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the open tasks in a repo's implementation-plan document, for the
# Refiner only (requirement 3y; TD-PPagop-26081307) — same "Refiner-only,
# never folded into ordered_repos_json" reasoning as
# gather_project_review_candidates above. Called only for a repo whose
# `refinement_policy` for `implementation-plan` is not exempt and that
# configures an `implementation_plan_path` — a repo with neither pays
# nothing here.
gather_implementation_plan_candidates() {
  local slug="$1" branch="$2" path="$3" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-implementation-plan.sh" "$slug" "$branch" "$path" \
        2>"$cycle_dir/implementation-plan-candidates-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/implementation-plan-candidates-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the voids a human has asked, on GitHub, to be reopened
# (requirement 34f). Unlike every other gatherer this is not a work source: it
# produces no candidates, it edits the skip-list the Co-Ordinator is about to be
# handed. It runs for every repo regardless of that repo's `sources`, because a
# void can be pinned on any item in any repo and a human's instruction to reopen
# one is not a kind of work anybody opted into.
gather_unvoid_requests() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-unvoid-requests.sh" "$slug" "$unvoid_label" \
        2>"$cycle_dir/unvoid-requests-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/unvoid-requests-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

# Pre-fetch the issues a human has labelled directly, asking the pipeline to
# treat them as too under-specified to select (requirement 34g). Like
# gather_unvoid_requests, this is not a work source and runs for every repo
# regardless of `sources`: the label only ever means something on an issue, but
# it is not one of the `issues` source's own candidates, and a repo that opted
# out of `issues` as work can still have a human flagging one by hand.
gather_hand_flagged_refinements() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-hand-flagged-refinements.sh" "$slug" "$needs_refinement_label" \
        2>"$cycle_dir/hand-flagged-refinements-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/hand-flagged-refinements-$safe.json"
    printf '%s' "$out"
  else
    printf '[]'
  fi
}

gather_source_state() {
  local slug="$1" branch="$2" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-source-state.sh" "$slug" "$branch" \
        2>"$cycle_dir/source-state-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object" and has("ok")' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/source-state-$safe.json"
    printf '%s' "$out"
  else
    jq -nc --arg s "$slug" '{slug: $s, ok: false}'
  fi
}

# What the register says about specific blocked items (requirement 34i). Unlike
# every gatherer above it, this is not called in the repo walk and not called
# per repo: the ids come from the blocked extract, so it runs only for a repo
# that has blocked register items — which is usually none of them, at no cost.
# An unreadable answer is `{}`, and `{}` clears nothing.
#
# PURPOSE names the asking pass — `blocked` (requirement 34i), `void`
# (requirement 34n) or `selected` (the pre-flight read) — and lands in the
# diagnostic filenames, because three passes can ask about the same repo in
# one cycle and a shared name means the last writer silently discards the
# other two's evidence.
gather_register_status() {
  local slug="$1" branch="$2" purpose="$3" out safe
  shift 3
  safe="$purpose-${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-register-status.sh" "$slug" "$branch" "$@" \
        2>"$cycle_dir/register-status-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/register-status-$safe.json"
    printf '%s' "$out"
  else
    printf '{}'
  fi
}

# What a merged pull request says about specific blocked project-review refs
# (requirement 34i). Same shape and same reason as gather_register_status
# above: called only for a repo with blocked project-review items, at no cost
# otherwise.
#
# PURPOSE, like gather_register_status's own, names the asking pass —
# `blocked` (requirement 34i) or `void` (requirement 34n's liveness
# retirement, TD-PPagop-26081303) — and lands in the diagnostic filenames, so
# the two passes this cycle can make against the same repo don't silently
# discard each other's evidence.
gather_review_status() {
  local slug="$1" branch="$2" purpose="$3" out safe
  shift 3
  safe="$purpose-${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-review-status.sh" "$slug" "$branch" "$@" \
        2>"$cycle_dir/review-status-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/review-status-$safe.json"
    printf '%s' "$out"
  else
    printf '{}'
  fi
}

# What the implementation-plan document's own checkboxes say about specific
# blocked plan-task ids (requirement 34i). Same shape and same reason as
# gather_register_status above, including PURPOSE.
gather_plan_status() {
  local slug="$1" branch="$2" path="$3" purpose="$4" out safe
  shift 4
  safe="$purpose-${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-plan-status.sh" "$slug" "$branch" "$path" "$@" \
        2>"$cycle_dir/plan-status-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/plan-status-$safe.json"
    printf '%s' "$out"
  else
    printf '{}'
  fi
}

# Which basename requirement 19's `failed-runs` item id names each workflow id
# (requirement 34n's liveness retirement, TD-PPagop-26081303) —
# scripts/gather-workflow-basenames.sh's own `{ok, basenames}`, called only
# for a repo with still-unretired `failed-run-` void entries: a fleet with
# none spends nothing here.
gather_workflow_basenames() {
  local slug="$1" out safe
  safe="${slug//\//_}"
  out="$("$SCRIPT_DIR/scripts/gather-workflow-basenames.sh" "$slug" \
        2>"$cycle_dir/workflow-basenames-$safe.err" || true)"
  if [[ -n "$out" ]] && jq -e 'type == "object"' <<<"$out" >/dev/null 2>&1; then
    printf '%s\n' "$out" > "$cycle_dir/workflow-basenames-$safe.json"
    printf '%s' "$out"
  else
    printf '{"ok":false,"basenames":{}}'
  fi
}
