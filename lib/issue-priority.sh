#!/usr/bin/env bash
#
# lib/issue-priority.sh — resolves and writes GitHub's `Priority` issue
# field, and enforces the one-way ratchet (D18 WI-11; agent-ops#414).
#
# `Priority` is a repository/org `IssueFieldSingleSelect`, not a label — read
# elsewhere in this repository (`scripts/gather-issues.sh`,
# `scripts/gather-source-state.sh`) through the REST `issue_field_values`
# array GitHub returns alongside an issue, but writable only through the
# GraphQL `setIssueFieldValue` mutation, which needs the field's own id and
# the target option's own id. Both are per-repository objects — verified live
# against agent-ops's own `Priority` field (`IFSS_kgDOAqB-kw`, options
# `Urgent`/`High`/`Medium`/`Low`) — and must be resolved at runtime rather
# than hardcoded, since nothing here can assume another repository's ids
# match, or that this token can even see the field: it is `ORG_ONLY`
# visibility, so a token without organisation membership reads it as absent
# rather than empty.
#
# The ratchet — never lower a band, including one an agent set — lives here
# rather than in the Refiner's own prompt (prompts/refiner.md), because a
# prompt rule is a request and this is the one place that actually writes the
# pipeline's records. `issue_priority_apply` re-reads the issue's current
# band immediately before writing, so a band a human set between this cycle's
# pre-fetch and this write is honoured, never clobbered by a stale read.
#
# Environment: ISSUE_PRIORITY_GH overrides `gh` (tests stub it);
# ISSUE_PRIORITY_CACHE_DIR overrides the field-id cache directory below
# (tests isolate it; a fresh directory per invocation loses caching but
# never correctness).

# ISSUE_PRIORITY_CACHE_DIR / ISSUE_PRIORITY_CACHE_DIR_OWNED — one resolution
# per repository per process, since a single cycle's Refiner engagement can
# apply several verdicts against the same repository and the field/option ids
# do not change mid-cycle. A directory of one file per SLUG, not an in-memory
# associative array: every caller here reads this file's own output through a
# command substitution (`field_json="$(issue_priority_field_ids "$slug")"`),
# which forks a subshell — a shell variable a function writes inside that
# subshell never reaches the parent, so an in-memory cache would silently
# miss on every single call, caching nothing while still claiming to. A file
# on disk has no such boundary: any subshell can read what an earlier one
# wrote. Created once, here, at source time — never inside a function a
# caller might invoke through its own command substitution, for the same
# reason.
#
# Cleanup is each sourcing site's own responsibility, through
# `issue_priority_cache_cleanup` below, since only the caller knows when it is
# done with the cache: `agent-cycle.sh` calls it from its `cleanup()` EXIT
# trap, after `maybe_run_refiner` — the cache's main consumer;
# `scripts/doctor.sh` calls it from an EXIT trap of its own, armed
# immediately after this file is sourced, since it has no other trap and
# exits from several points.
# `ISSUE_PRIORITY_CACHE_DIR_OWNED` records which case this process is
# in: `1` when the `mktemp -d` below ran to fill `ISSUE_PRIORITY_CACHE_DIR`
# in, `0` when the caller supplied its own path — a directory that path
# names is the caller's to manage, and `issue_priority_cache_cleanup` must
# never remove it. Ownership is a property of the *directory*, not of the
# most recent source: a process can source this file more than once (issue
# #541 — a second library sourcing this one, or a test re-sourcing it), and
# on that second source `ISSUE_PRIORITY_CACHE_DIR` is already non-empty
# because the first source filled it in, not because a caller supplied it.
# `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATH` records the path this file created
# for itself, so a re-source can tell "the directory I made last time" apart
# from "a directory some caller handed me" — the two cases a bare `-n
# "$ISSUE_PRIORITY_CACHE_DIR"` check cannot distinguish.
if [[ "${ISSUE_PRIORITY_CACHE_DIR_OWNED:-0}" == "1" && \
      -n "${ISSUE_PRIORITY_CACHE_DIR_OWNED_PATH:-}" && \
      "$ISSUE_PRIORITY_CACHE_DIR_OWNED_PATH" == "${ISSUE_PRIORITY_CACHE_DIR:-}" ]]; then
  : # re-source with the same directory this file created earlier — still ours
elif [[ -n "${ISSUE_PRIORITY_CACHE_DIR:-}" ]]; then
  ISSUE_PRIORITY_CACHE_DIR_OWNED=0
else
  ISSUE_PRIORITY_CACHE_DIR="$(mktemp -d 2>/dev/null || true)"
  ISSUE_PRIORITY_CACHE_DIR_OWNED=1
  ISSUE_PRIORITY_CACHE_DIR_OWNED_PATH="$ISSUE_PRIORITY_CACHE_DIR"
fi

# issue_priority_cache_cleanup
# Remove ISSUE_PRIORITY_CACHE_DIR, but only when this file created it itself
# (ISSUE_PRIORITY_CACHE_DIR_OWNED=1) — a caller-supplied path is that caller's
# to remove, never this function's. A no-op, printing nothing, when the
# directory was never created (mktemp -d failed above), when the caller owns
# it, or when it has already been removed — idempotent, so a sourcing site's
# own trap can call it more than once with no ill effect. Always returns 0: a
# missing cache directory is never a failure worth reporting.
issue_priority_cache_cleanup() {
  if [[ "${ISSUE_PRIORITY_CACHE_DIR_OWNED:-0}" == "1" && -n "${ISSUE_PRIORITY_CACHE_DIR:-}" ]]; then
    rm -rf "$ISSUE_PRIORITY_CACHE_DIR" 2>/dev/null || true
  fi
  return 0
}

# issue_priority_rank BAND
# Print the ratchet's rank for BAND — higher outranks lower — or 0 for
# anything that is not one of the four band names. Used only for comparison;
# the number itself carries no meaning outside this file.
issue_priority_rank() {
  case "${1:-}" in
    Urgent) printf '4' ;;
    High) printf '3' ;;
    Medium) printf '2' ;;
    Low) printf '1' ;;
    *) printf '0' ;;
  esac
}

# issue_priority_band_name RANK
# The inverse of issue_priority_rank, for walking the ranked bands in order
# (issue_priority_fallback_band below). Prints nothing and returns 1 for
# anything outside 1..4 — there is no band to name.
issue_priority_band_name() {
  case "${1:-}" in
    4) printf 'Urgent' ;;
    3) printf 'High' ;;
    2) printf 'Medium' ;;
    1) printf 'Low' ;;
    *) return 1 ;;
  esac
}

# issue_priority_fallback_band FIELD_IDS_JSON BAND
# BAND's own option is absent from FIELD_IDS_JSON (agent-ops#534 — a
# repository's `Priority` field missing one of the four band names, the
# narrower complement to agent-ops#511's "field unreadable at all").
# Rather than fail outright and have the Refiner re-offered the same
# unwritable band forever, print the nearest band FIELD_IDS_JSON actually
# has an option for: the nearest *lower* rank first, since that never
# overstates the issue's priority, falling back to the nearest *higher*
# rank only when no lower option exists at all (BAND was already `Low`, or
# every lower band is missing too) — ending the loop is worth the
# occasional overstatement (Enabler refinement on agent-ops#534;
# the alternative, treating "nothing lower" as permanently unbandable,
# reopens the same starvation this exists to close). Prints nothing and
# returns 1 only when FIELD_IDS_JSON carries none of the four band names at
# all — every band, not just BAND's own, is unwritable.
issue_priority_fallback_band() {
  local field_json="$1" band="$2" want_rank r name
  want_rank="$(issue_priority_rank "$band")"
  for (( r = want_rank - 1; r >= 1; r-- )); do
    name="$(issue_priority_band_name "$r")"
    if jq -e --arg n "$name" '(.options // {}) | has($n)' <<<"$field_json" >/dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
  done
  for (( r = want_rank + 1; r <= 4; r++ )); do
    name="$(issue_priority_band_name "$r")"
    if jq -e --arg n "$name" '(.options // {}) | has($n)' <<<"$field_json" >/dev/null 2>&1; then
      printf '%s' "$name"
      return 0
    fi
  done
  return 1
}

# issue_priority_field_ids SLUG
# Print `{"field_id": "…", "options": {"Urgent": "…", "High": "…", …}}` for
# SLUG's `Priority` field, resolved live via GraphQL introspection of the
# repository's own `issueFields`. Prints nothing and returns 1 when the field
# is missing, unreadable, or the query itself fails — the same "unknown means
# cannot write" direction every caller here must take, since a naive
# implementation that read a missing field as "nothing to band" would write
# the entire backlog once field visibility failed (see the header's ORG_ONLY
# note). Cached per SLUG for the life of this process; see
# ISSUE_PRIORITY_CACHE_DIR above.
issue_priority_field_ids() {
  local slug="$1" gh_bin="${ISSUE_PRIORITY_GH:-gh}"
  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
  local cache_file="" cached
  if [[ -n "$ISSUE_PRIORITY_CACHE_DIR" ]]; then
    cache_file="$ISSUE_PRIORITY_CACHE_DIR/${slug//\//__}.json"
    if [[ -f "$cache_file" ]]; then
      cached="$(cat "$cache_file" 2>/dev/null || true)"
      if [[ "$cached" == "FAIL" ]]; then
        return 1
      elif [[ -n "$cached" ]]; then
        printf '%s' "$cached"
        return 0
      fi
    fi
  fi
  local owner="${slug%%/*}" repo="${slug#*/}" node result
  # shellcheck disable=SC2016  # GraphQL's own $owner/$repo, not the shell's.
  node="$("$gh_bin" api graphql \
    -f query='query($owner:String!,$repo:String!){
      repository(owner:$owner,name:$repo){
        issueFields(first:20){
          nodes{ ... on IssueFieldSingleSelect { id name options { id name } } }
        }
      }
    }' \
    -f owner="$owner" -f repo="$repo" \
    --jq '.data.repository.issueFields.nodes[]? | select(.name == "Priority")' \
    2>/dev/null)"
  if [[ -z "$node" ]]; then
    [[ -n "$cache_file" ]] && printf 'FAIL' > "$cache_file" 2>/dev/null
    return 1
  fi
  result="$(jq -c '{field_id: .id, options: (reduce .options[] as $o ({}; .[$o.name] = $o.id))}' \
    <<<"$node" 2>/dev/null)"
  if [[ -z "$result" ]]; then
    [[ -n "$cache_file" ]] && printf 'FAIL' > "$cache_file" 2>/dev/null
    return 1
  fi
  [[ -n "$cache_file" ]] && printf '%s' "$result" > "$cache_file" 2>/dev/null
  printf '%s' "$result"
}

# issue_priority_options_complete FIELD_IDS_JSON
# True (exit 0) iff FIELD_IDS_JSON (issue_priority_field_ids's own output)
# carries all four band names among its options — an organisation may add a
# fifth later (the same possibility gather-issues.sh already tolerates on
# read), which is harmless here since only the four recognised names are ever
# looked up; missing one of the four is what actually breaks a write.
issue_priority_options_complete() {
  jq -e '(.options // {}) as $o
         | ["Urgent","High","Medium","Low"] | all(. as $n | $o | has($n))' \
    <<<"${1:-}" >/dev/null 2>&1
}

# issue_priority_options_any FIELD_IDS_JSON
# True (exit 0) iff FIELD_IDS_JSON carries at least one of the four band
# names among its options. The complement of `issue_priority_options_complete`
# above, and needed for a different distinction: `refiner_filter_unbandable_triage`
# (agent-cycle.sh, agent-ops#542) must tell "some bands missing, `triage_only`
# candidates still unaffected" (agent-ops#534, `issue_priority_fallback_band`
# handles it per-issue) apart from "every band missing" — a field that
# resolves but carries none of the four names can never write any
# `triage_only` verdict at all, the same terminal state, for that pre-flight's
# purposes, as a field that fails to resolve outright.
issue_priority_options_any() {
  jq -e '(.options // {}) as $o
         | ["Urgent","High","Medium","Low"] | any(. as $n | $o | has($n))' \
    <<<"${1:-}" >/dev/null 2>&1
}

# issue_priority_current SLUG NUMBER
# Print `{"node_id": "…", "priority": "<raw option name>"|null}` for issue
# NUMBER in SLUG, read live — the pre-write re-read the ratchet needs so a
# band changed since this cycle's pre-fetch is never clobbered. `priority` is
# the raw option name, whatever it is — unlike gather-issues.sh's own parse,
# which collapses anything outside the four recognised names to its Medium
# default, this read must see an org-added fifth option too, since
# `issue_priority_apply` needs to tell "no band" (safe to write) apart from "a
# band this ratchet cannot rank" (must not overwrite); `issue_priority_rank`
# already treats any unrecognised name as rank 0, so only the raw value needs
# to travel through here. Prints nothing and returns 1 on any read failure.
issue_priority_current() {
  local slug="$1" number="$2" gh_bin="${ISSUE_PRIORITY_GH:-gh}"
  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || return 1
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  "$gh_bin" api "repos/$slug/issues/$number" \
    --jq '{node_id: .node_id,
           priority: (([.issue_field_values[]? | select(.issue_field_name == "Priority")
                                               | .single_select_option.name] | first) // null)}' \
    2>/dev/null
}

# issue_priority_apply SLUG NUMBER BAND
# Apply the ratchet for issue NUMBER in SLUG against verdict BAND (one of the
# four names). Always prints one JSON object describing what happened —
# regardless of exit code, so a caller can log either an `issue-prioritised`
# event or a `warning` from the same value without a second branch:
#
#   {"applied": true,  "priority": "High", "previous": "Low"|null}
#   {"applied": false, "reason": "skipped-lower-or-equal", "priority": "…", "previous": "…"}
#   {"applied": false, "reason": "skipped-unrankable", "priority": "…", "previous": "…"}
#   {"applied": false, "reason": "bad-slug"|"bad-number"|"bad-band"
#                               |"field-unresolvable"|"band-option-missing"
#                               |"issue-unreadable"|"mutation-failed"}
#
# The four shapes that reach the ratchet — the successful write, either skip,
# and `"mutation-failed"` — gain an optional `"requested"` key, present only
# when the band actually written or skipped differs from BAND; see the
# fallback paragraph below. No other shape carries it: the three bad-argument
# reasons are rejected before any band is chosen, and `"field-unresolvable"`,
# `"band-option-missing"` and `"issue-unreadable"` — the last of which *is*
# reached after a fallback band has been picked — are each logged by the
# caller as a `warning` naming BAND itself, so the substitution is not lost.
#
# "skipped-unrankable" is the band an org admin can add to the field at any
# time (issue #509, requirement 39g's own promise never to overwrite a band a
# human set): the issue's current option is present but is not one of the
# four names this ratchet can rank, so `issue_priority_rank` reads it as 0 and
# a naive `cur_rank >= new_rank` comparison would never block the write — the
# defect this case exists to close. `previous` carries the raw, unranked name.
#
# `"field-unresolvable"` and `"band-option-missing"` are deliberately distinct
# reasons (agent-ops#534) for two failures a caller must be able to tell
# apart: the former is the field itself — missing, or
# `ORG_ONLY`-invisible to this token (agent-ops#511) — the latter is a field
# that resolves fine but is missing one or more of the four band names as
# options. A missing BAND is not an immediate failure: `issue_priority_fallback_band`
# is tried first, and the ratchet below is applied against whatever band it
# finds, with `requested` naming BAND so a reader can see the substitution.
# `"band-option-missing"` therefore fires only when the field carries *none*
# of the four names at all — the degenerate case one step short of
# `field-unresolvable` itself, and (like it) never offered a second write
# attempt, since nothing about a retry would change the outcome.
#
# Returns 0 when the ratchet's own decision (apply, or skip because the
# written band does not outrank the current band, or skip because the
# current band cannot be ranked at all) completed without error — a skip is
# not a failure, it is the ratchet working. Returns 1 for every "reason"
# above that names an actual failure to read or write, which callers must
# treat as "the band may or may not be what it was" and log as a warning,
# never retry silently in a loop.
issue_priority_apply() {
  local slug="$1" number="$2" band="$3" gh_bin="${ISSUE_PRIORITY_GH:-gh}"
  local field_json field_id opt_id cur_json issue_node cur_band cur_rank new_rank
  local write_band requested=""

  [[ "$slug" =~ ^[^/]+/[^/]+$ ]] || { printf '{"applied":false,"reason":"bad-slug"}'; return 1; }
  [[ "$number" =~ ^[0-9]+$ ]] || { printf '{"applied":false,"reason":"bad-number"}'; return 1; }
  case "$band" in
    Urgent | High | Medium | Low) ;;
    *) printf '{"applied":false,"reason":"bad-band"}'; return 1 ;;
  esac

  field_json="$(issue_priority_field_ids "$slug")" \
    || { printf '{"applied":false,"reason":"field-unresolvable"}'; return 1; }
  field_id="$(jq -r '.field_id // ""' <<<"$field_json" 2>/dev/null || true)"
  [[ -n "$field_id" ]] \
    || { printf '{"applied":false,"reason":"field-unresolvable"}'; return 1; }

  write_band="$band"
  opt_id="$(jq -r --arg b "$band" '.options[$b] // ""' <<<"$field_json" 2>/dev/null || true)"
  if [[ -z "$opt_id" ]]; then
    write_band="$(issue_priority_fallback_band "$field_json" "$band")" \
      || { printf '{"applied":false,"reason":"band-option-missing"}'; return 1; }
    requested="$band"
    opt_id="$(jq -r --arg b "$write_band" '.options[$b] // ""' <<<"$field_json" 2>/dev/null || true)"
    [[ -n "$opt_id" ]] \
      || { printf '{"applied":false,"reason":"band-option-missing"}'; return 1; }
  fi

  cur_json="$(issue_priority_current "$slug" "$number")" \
    || { printf '{"applied":false,"reason":"issue-unreadable"}'; return 1; }
  issue_node="$(jq -r '.node_id // ""' <<<"$cur_json" 2>/dev/null || true)"
  [[ -n "$issue_node" ]] \
    || { printf '{"applied":false,"reason":"issue-unreadable"}'; return 1; }
  cur_band="$(jq -r '.priority // ""' <<<"$cur_json" 2>/dev/null || true)"

  cur_rank="$(issue_priority_rank "$cur_band")"
  new_rank="$(issue_priority_rank "$write_band")"
  if [[ -n "$cur_band" ]] && (( cur_rank == 0 )); then
    jq -nc --arg p "$write_band" --arg prev "$cur_band" --arg req "$requested" \
      '{applied: false, reason: "skipped-unrankable", priority: $p, previous: $prev}
       + (if $req == "" then {} else {requested: $req} end)'
    return 0
  fi
  if [[ -n "$cur_band" ]] && (( cur_rank >= new_rank )); then
    jq -nc --arg p "$write_band" --arg prev "$cur_band" --arg req "$requested" \
      '{applied: false, reason: "skipped-lower-or-equal", priority: $p, previous: $prev}
       + (if $req == "" then {} else {requested: $req} end)'
    return 0
  fi

  # shellcheck disable=SC2016  # GraphQL's own $issueId/$fieldId/$optionId.
  if "$gh_bin" api graphql \
      -f query='mutation($issueId:ID!,$fieldId:ID!,$optionId:String!){
        setIssueFieldValue(input:{issueId:$issueId, issueFields:[{fieldId:$fieldId, singleSelectOptionId:$optionId}]}){
          clientMutationId
        }
      }' \
      -f issueId="$issue_node" -f fieldId="$field_id" -f optionId="$opt_id" \
      >/dev/null 2>&1; then
    jq -nc --arg p "$write_band" --arg prev "$cur_band" --arg req "$requested" \
      '{applied: true, priority: $p, previous: (if $prev == "" then null else $prev end)}
       + (if $req == "" then {} else {requested: $req} end)'
    return 0
  fi
  jq -nc --arg p "$write_band" --arg prev "$cur_band" --arg req "$requested" \
    '{applied: false, reason: "mutation-failed", priority: $p, previous: (if $prev == "" then null else $prev end)}
     + (if $req == "" then {} else {requested: $req} end)'
  return 1
}
