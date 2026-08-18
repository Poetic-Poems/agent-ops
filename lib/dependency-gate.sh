#!/usr/bin/env bash
#
# lib/dependency-gate.sh — the structured `Blocked-by:` convention
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md, requirement 34j).
#
# No code used to parse a dependency note like "hold until #195 is merged"
# and check the referenced item's live state: the note was prose, and the
# only reader of it was a model, re-judging the same paragraph every time it
# was asked to. When the dependency actually merged, nothing told the
# pipeline that — the note still read "hold until #195", and a Co-Ordinator
# asked to re-examine the thread (requirement 18a, triggered by some later,
# unrelated comment) could read that same stale sentence and re-conclude
# "still blocked", each wrong conclusion costing a full Enabler round to
# undo. Four issues (#196–#199) produced exactly that: cleared once when
# #195 actually merged, then re-blocked from the same paragraph more than
# once after.
#
# `Blocked-by: #195` (same repo) or `Blocked-by: owner/repo#195` (a
# dependency in another repo this pipeline also walks) is the fix: a
# reference to a *specific, numbered* item whose *live* open/closed state is
# what decides the block, checked fresh every time rather than narrated once
# and left to go stale. Staleness stops being a failure mode by
# construction — a `Blocked-by:` line naming an already-closed item is
# inert, not wrong, because nothing here ever trusts what the line asserted
# happened; it only trusts what re-checking the number says now.
#
# Two call sites share this file's parsing:
#
#   - `scripts/gather-issues.sh` drops a candidate whose thread names an
#     unresolved dependency, the same way it drops an assigned or
#     `blocked`-labelled one — deterministically, before the Co-Ordinator
#     ever sees it, so an item newly declaring a dependency never earns an
#     `attempt-failed` at all.
#   - `agent-cycle.sh`'s pre-extract window (alongside requirement 34i's
#     work-gone reconciliation) clears an *existing* block the moment its
#     dependency resolves, reusing this cycle's own freshly gathered issue
#     candidates rather than re-deriving anything: an already-blocked item
#     reappearing in this cycle's `issues` array, with a `Blocked-by:` line
#     still in its thread, is itself the proof that gather-issues.sh's own
#     live check found every reference resolved — that is what
#     `dependency_clearances` below reads, not a second opinion on the
#     reference's state.
#
# Sourced, never executed: it sets no shell options, because both callers run
# under `set -euo pipefail` (agent-cycle.sh) or `set -uo pipefail`
# (gather-issues.sh).

# A `Blocked-by:` line's value, once split on commas and whitespace, is a
# list of tokens; only a token shaped like `#123` or `owner/repo#123`
# survives — the same explicit-reference shape GitHub's own cross-linking
# uses, deliberately narrower than a bare number, so an unrelated digit in
# the same sentence ("the third of 42 items") is never mistaken for one.
DEPENDENCY_REF_RE='^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+$'

# dependency_refs TEXT
# Print, as a JSON array of strings, every dependency reference named on a
# `Blocked-by:` line anywhere in TEXT (an issue body, a comment body, or
# several concatenated with newlines) — a same-repo reference normalized to
# a bare number ("195"), a cross-repo one kept whole ("owner/repo#42").
# Duplicates collapse; the line's keyword is matched case-insensitively, and
# an optional `-`/`*` list marker before it is tolerated (issue bodies
# routinely itemise their dependencies). Prints `[]` for text with no such
# line, and always succeeds: a gatherer or the pre-extract window running
# under `set -e` must never fail on a malformed thread.
dependency_refs() {
  local text="${1:-}"
  [[ -n "$text" ]] || { printf '[]'; return 0; }
  local raw tokens
  raw="$(awk '
    {
      lower = tolower($0)
      if (lower ~ /^[ \t]*[-*][ \t]*blocked-by:/ || lower ~ /^[ \t]*blocked-by:/) {
        idx = index($0, ":")
        if (idx > 0) print substr($0, idx + 1)
      }
    }' <<<"$text" 2>/dev/null)" || true
  [[ -n "$raw" ]] || { printf '[]'; return 0; }
  # `grep -oE` finding nothing is the ordinary case (a `Blocked-by:` line
  # with no valid reference token), not a failure — captured into a variable
  # first, with its exit code explicitly discarded, so that legitimate empty
  # case can never be mistaken for the `jq` failure the `||` below exists to
  # catch, which under `set -e -o pipefail` (agent-cycle.sh) it otherwise
  # would be, printing a duplicate `[]` after `jq` had already printed one.
  tokens="$(tr ',' ' ' <<<"$raw" | tr -s ' \t' '\n' | grep -oE "$DEPENDENCY_REF_RE" 2>/dev/null || true)"
  jq -R -s -c '
      [splits("\n")] | map(select(length > 0))
      | map(if test("/") then . else ltrimstr("#") end)
      | unique' <<<"$tokens" 2>/dev/null || printf '[]'
}

# dependency_clearances BLOCKED_JSON ISSUES_BY_REPO_JSON
# Print, as a JSON array, one entry per blocked item whose declared
# dependencies are all resolved — the input to the `unblocked` events the
# Script writes:
#
#   {"repo": "owner/repo", "item": "196", "reason": "Blocked-by #195 resolved"}
#
# BLOCKED_JSON is the open blocked set (requirement 34h): a void item needs
# no unblocking, exactly as in `work_gone_clearances`.
#
# ISSUES_BY_REPO_JSON is this cycle's own freshly gathered issue candidates,
# reshaped to `{"owner/repo": {"196": {"body": "…", "comments": [{"body": "…"}]}}}`.
# An item present here, whatever its `Blocked-by:` line still says, has
# already passed `gather-issues.sh`'s own live check this same cycle — the
# array excludes anything with an unresolved reference — so finding the item
# here at all *is* the resolved verdict; this function never re-checks a
# reference's state itself; it only reads whether a `Blocked-by:` line is
# there to explain the presence. An item this cycle's candidates do not
# carry (excluded for any reason, including a dependency still open, or
# simply not walked this cycle) decides nothing and stays blocked — the same
# "unknown is never gone" rule requirement 34i's clearances observe.
#
# Only items shaped like a bare GitHub issue number are considered: the
# convention is documented for issue threads only (like requirement 18a),
# because that is the one blocked-item shape with a thread this cycle reads
# whole.
#
# Always succeeds, printing `[]` for input it cannot read.
dependency_clearances() {
  local blocked="${1:-[]}" issues_by_repo="${2:-{\}}" out='[]'
  local repo item entry text refs reason
  while IFS=$'\t' read -r repo item; do
    [[ -n "$repo" && -n "$item" ]] || continue
    [[ "$item" =~ ^[0-9]+$ ]] || continue
    entry="$(jq -c --arg r "$repo" --arg i "$item" '(.[$r] // {})[$i] // null' \
      <<<"$issues_by_repo" 2>/dev/null || true)"
    [[ -n "$entry" && "$entry" != "null" ]] || continue
    text="$(jq -r '(.body // "") as $b | ((.comments // []) | map(.body // "")) as $c
                   | ([$b] + $c | join("\n"))' <<<"$entry" 2>/dev/null || true)"
    refs="$(dependency_refs "${text:-}")"
    [[ "$(jq 'length' <<<"$refs" 2>/dev/null || echo 0)" != "0" ]] || continue
    reason="$(jq -r '"Blocked-by " + (map(if test("/") then . else "#" + . end) | join(", ")) + " resolved"' \
      <<<"$refs" 2>/dev/null || echo "Blocked-by dependency resolved")"
    out="$(jq -c --arg r "$repo" --arg i "$item" --arg reason "$reason" \
      '. + [{repo: $r, item: $i, reason: $reason}]' <<<"$out" 2>/dev/null || printf '%s' "$out")"
  done < <(jq -r '.[] | [(.repo // ""), (.item // "")] | @tsv' <<<"$blocked" 2>/dev/null || true)
  printf '%s' "$out"
}

# dependency_refusal_reason ENTRY_JSON ISSUES_BY_REPO_JSON
# Decide whether a needs_refinement-shaped ENTRY (`{repo, item, source,
# reason, missing, evidence}`, from any reporting stage) asserts, as its
# block, the same `Blocked-by:` dependency this cycle's own gate has already
# resolved for that item — exclusion 4 (docs/IMPLEMENTATION-PIPELINE-SPEC.md
# requirement 16), which belongs to the Script and must never be re-derived
# from a model's own reading of an issue thread (issue #566: five items
# mislabelled `needs_refinement` in one cycle, each naming a dependency issue
# number that had already closed, because the entry's own prose — "blocked
# on #410 (closed …)", never the raw `Blocked-by:` line itself — reasoned
# past what the Script had already checked live).
#
# Prints nothing and returns 0 when ENTRY may be recorded ordinarily. Prints
# a one-line reason and returns 1 when it must be refused instead — the same
# calling convention as `refinement_entry_problem` in lib/refinement.sh, so a
# caller can chain both bars the same way.
#
# Refusal requires all three:
#   - ENTRY's `source` is (or defaults to, requirement 16a) `"issues"` — the
#     `Blocked-by:` convention is documented for issue threads only.
#   - ENTRY's own item's thread, read from ISSUES_BY_REPO_JSON, names at least
#     one `Blocked-by:` reference (`dependency_refs`, the same parser
#     `dependency_clearances` reads — never re-derived here, on the fix's own
#     "the gate is already computed" terms). The thread is reachable at all
#     only when `scripts/gather-issues.sh`'s live check this same cycle found
#     every one of its references already resolved (the same proof
#     `dependency_clearances` above reads: an item with an unresolved
#     reference is dropped before it ever reaches this map, so being in it at
#     all *is* the resolved verdict) — an item this cycle never gathered, or
#     whose thread names no dependency at all, decides nothing here, on the
#     same "unknown is never gone" terms `dependency_clearances` observes.
#   - ENTRY's own `reason`/`missing`/`evidence` names that *same* reference by
#     number — a genuine `#410` token, or the cross-repo slug verbatim, not
#     merely the digits in passing. Deliberately not "cites a `Blocked-by:`
#     line": the Co-Ordinator's own fields are prose about the thread, not a
#     copy of it, so the check reads what the report actually asserts rather
#     than demanding it echo the convention's exact keyword. An entry naming
#     no reference the thread's own resolved list carries — a report that
#     fails to rank, or is under-specified, for some unrelated reason — is
#     untouched: this refuses only the specific, false, dependency claim,
#     never the judgement half.
#
# ISSUES_BY_REPO_JSON is `agent-cycle.sh`'s own `issues_by_repo_json`
# (`{"owner/repo": {"196": {"body": …, "comments": […]}}}`), computed once
# per cycle from this cycle's freshly gathered `issues` candidates — reused
# here exactly as `dependency_clearances` reuses it, never a second `gh`
# read.
dependency_refusal_reason() {
  local entry="$1" issues_by_repo="${2:-{\}}" source repo item thread_text \
        thread_refs entry_text ref matched=""
  source="$(jq -r '.source // "issues"' <<<"$entry" 2>/dev/null || echo issues)"
  [[ "$source" == "issues" ]] || return 0
  repo="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
  item="$(jq -r '(.item // "") | tostring' <<<"$entry" 2>/dev/null || true)"
  [[ -n "$repo" && "$item" =~ ^[0-9]+$ ]] || return 0
  thread_text="$(jq -r --arg r "$repo" --arg i "$item" '
    ((.[$r] // {})[$i]) as $e
    | if $e == null then ""
      else ([($e.body // "")] + (($e.comments // []) | map(.body // "")) | join("\n"))
      end' <<<"$issues_by_repo" 2>/dev/null || true)"
  [[ -n "$thread_text" ]] || return 0
  thread_refs="$(dependency_refs "$thread_text")"
  [[ "$(jq 'length' <<<"$thread_refs" 2>/dev/null || echo 0)" != "0" ]] || return 0
  entry_text="$(jq -r '[(.reason // ""), (.missing // ""), (.evidence // "")] | join("\n")' \
    <<<"$entry" 2>/dev/null || true)"
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    if [[ "$ref" == */* ]]; then
      [[ "$entry_text" == *"$ref"* ]] && { matched="$ref"; break; }
    elif grep -qE "(^|[^0-9])#${ref}([^0-9]|\$)" <<<"$entry_text" 2>/dev/null; then
      matched="#$ref"
      break
    fi
  done < <(jq -r '.[]' <<<"$thread_refs" 2>/dev/null || true)
  [[ -n "$matched" ]] || return 0
  printf 'names the same dependency (%s) this cycle'"'"'s own gate already resolved for %s#%s — exclusion 4 belongs to the Script, never re-derived from the thread' \
    "$matched" "$repo" "$item"
  return 1
}
