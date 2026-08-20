#!/usr/bin/env bash
#
# scripts/detect-classifier-escapes.sh — independent post-hoc classifier-
# escape detector (D18 Stage 2 exit criterion "zero classifier escapes",
# agent-ops#572).
#
# `lib/landing.sh`'s `landing_eligible` is the *decision*: given a pull
# request's complexity, source and the effective `merge_autonomy` level,
# does it qualify for automatic landing? Nothing independently re-checks the
# *outcome* — that every pull request which actually landed autonomously was
# in fact eligible. This script is that check, and by design it never calls
# `landing_eligible`, and never sources `lib/landing.sh` at all: the
# protected-path list and the "did this land under the Approver identity"
# test below are each reimplemented from scratch, deliberately, per the
# issue's own Refiner comment ("`landing_protected_paths` and the
# Approver-identity check already exist in lib/landing.sh — read there for
# the exact logic this detector must reproduce independently (not call
# into)"). An audit that shared the code it exists to check could not catch
# a bug in that shared code — both the classifier and its own auditor would
# agree, and agreement is exactly what a classifier escape looks like from
# the inside. `test/detect-classifier-escapes.test.sh` pins the reimplemented
# protected-path list identical to `lib/landing.sh`'s own, so the two cannot
# drift apart unnoticed even though neither sources the other.
#
# ## What counts as "landed under the Approver identity"
#
# Not "carries `pr_label`", and not "has a `landing-armed` event in the fleet
# log" — trusting the pipeline's own event log to say which pull requests it
# landed would make the audit circular, exactly the thing it exists to avoid
# (a bug that caused `agent-cycle.sh` to log `landing-armed` without actually
# arming, or against the wrong pull request, would then audit nothing wrong).
# Instead: every merged, `pr_label`-carrying pull request in SLUG whose own
# `merged_by.login` (GitHub's live record, `gh api repos/SLUG/pulls/N`) is
# APPROVER_LOGIN. `landing_arm` (lib/landing.sh) always writes under the
# Approver App's minted token, never a human's, so this is the fact of an
# autonomous landing exactly as GitHub itself recorded it — independent of
# whether this pipeline's own log agrees.
#
# ## What is recomputed, and from what
#
#   - **Protected-path hit** — from the *merge commit's own file list*
#     (`gh api repos/SLUG/commits/SHA`), never the pull request's changed-file
#     endpoint `landing_protected_paths_hit` reads: a different GitHub
#     resource entirely, so a bug specific to either read is caught by the
#     other disagreeing. Checked against a prefix list declared fresh in this
#     file (see above).
#   - **Complexity** — not the `complexity:*` label GitHub shows *today*
#     (labels change), but whichever one the pull request actually carried
#     *at the moment it merged*, replayed from its own labelled/unlabelled
#     timeline (`gh api repos/SLUG/issues/N/events`) up to `merged_at`. A
#     landing audited weeks later still reports the complexity it actually
#     landed at.
#   - **Source** — GitHub carries no field for this at all (`lib/landing.sh`'s
#     own `landing_retry_source` header explains why), so it is read back
#     from the one place it is genuinely recorded: the fleet log's own
#     `landing-armed` event for this `pr_url`, which itself only ever holds
#     the value the round that armed the landing was given — never a value
#     `landing_eligible` derived.
#   - **The routine-sources list** — SLUG's own `merge_autonomy_routine_sources`
#     (repo override, else the top-level key, else the shipped default),
#     resolved fresh from CONFIG_FILE by a copy of the precedence
#     `lib/landing.sh`'s own `_landing_routine_sources` uses, declared here
#     rather than sourced, for the same reason as the protected-path list.
#     This is necessarily read from *current* configuration, not whatever was
#     in force the moment a given pull request landed — nothing in this
#     codebase preserves that history — so a landing audited long after a
#     deliberate widening or narrowing of this key is judged by today's list.
#     That is a real, accepted limitation of a post-hoc audit over a
#     forward-only log, not an oversight.
#
# Any input that cannot be reconstructed reports `unverifiable`, never
# `clean` — an unreadable merge commit's file list, a merge with zero or
# more than one `complexity:*` label standing at merge time, or a pull
# request with no matching `landing-armed` event to read a source from. An
# `unverifiable` landing is exactly as far from "cleared" as an `escape` is:
# neither is silently folded into the other.
#
# ## Idempotency
#
# Each merged, Approver-identified pull request is audited at most once,
# ever: LOG_FILE (the fleet's own union log, or stdin/"-") is scanned first
# for every prior `classifier-escape`/`landing-audit` event's own `pr_url`,
# and every one already seen is skipped before a single `gh` call is spent on
# it. A pull request's own merged history is a fixed, past fact, so nothing
# about re-checking it later could change the answer.
#
# ## Output
#
# One compact JSON object per newly-audited pull request, printed to stdout —
# never appended to the fleet log directly. Requirement 33 reserves that
# single-writer act to `agent-cycle.sh`, under its own lock (agents/scripts
# report; the Script translates into events) — this script is invoked from
# there, once per repository per cycle, and never runs standalone against
# the live log for that reason, exactly the same shape
# `scripts/sweep-human-visibility.sh` already established. Each line:
#
#   {"outcome": "clean"|"escape"|"unverifiable", "pr_url": "...",
#    "repo": "OWNER/REPO", "number": 123, "merge_commit_sha": "..."|null,
#    "source": "..."|null, "complexity_recomputed": "low"|"medium"|"high"|null,
#    "protected_paths_hit": true|false|null, "protected_paths": [...]|null,
#    "reason": "..."}
#
# `reason` is always present: for `clean` it says so plainly; for `escape` it
# names which check disagreed; for `unverifiable` it names which input could
# not be reconstructed.
#
# Usage:
#   scripts/detect-classifier-escapes.sh SLUG APPROVER_LOGIN LOG_FILE
#                                         [--config FILE] [--label LABEL]
#
# LOG_FILE is a path, or "-" to read stdin. With no --config, reads
# config.json beside this script; with no --label, reads config.json's
# `pr_label` (default "autonomous-agent"), matching every other script that
# scopes a GitHub read to this pipeline's own pull requests.
#
# Environment:
#   ESCAPE_AUDIT_GH             override `gh` (tests stub it), matching
#                                LANDING_GH/MERGE_QUEUE_GH/APPROVER_GH.
#   ESCAPE_AUDIT_RETRY_DELAY_SECONDS  backoff scale for the transient-failure
#                                retry around each `gh` read (tests set 0),
#                                matching mine-merge-history.sh's own
#                                MINE_RETRY_DELAY_SECONDS.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

GH_BIN="${ESCAPE_AUDIT_GH:-gh}"
CONFIG_FILE="$SCRIPT_DIR/config.json"
LABEL=""

usage() {
  echo "usage: detect-classifier-escapes.sh SLUG APPROVER_LOGIN LOG_FILE [--config FILE] [--label LABEL]" >&2
  exit 64
}

declare -a POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
[[ ${#POSITIONAL[@]} -eq 3 ]] || usage
slug="${POSITIONAL[0]}"
approver_login="${POSITIONAL[1]}"
log_source="${POSITIONAL[2]}"
[[ -n "$slug" && -n "$approver_login" ]] || usage

if [[ -z "$LABEL" ]]; then
  LABEL="$(jq -r '.pr_label // "autonomous-agent"' "$CONFIG_FILE" 2>/dev/null)"
  [[ -n "$LABEL" && "$LABEL" != "null" ]] || LABEL="autonomous-agent"
fi

# --- Transient-failure retry around the metered `gh` wrapper ---------------
# Same shape as scripts/mine-merge-history.sh's own gh_retry: a dropped
# connection mid-run must not silently mark a pull request unverifiable that
# a second attempt would have read fine.
gh_retry() {
  local buf rc attempt delay
  delay="${ESCAPE_AUDIT_RETRY_DELAY_SECONDS:-5}"
  buf="$(mktemp)" || return 1
  rc=1
  for attempt in 1 2 3; do
    if "$GH_BIN" "$@" >"$buf" 2>/dev/null; then
      cat "$buf"; rm -f "$buf"; return 0
    else
      rc=$?
    fi
    if (( attempt < 3 )); then
      sleep $(( attempt * delay ))
      : >"$buf"
    fi
  done
  rm -f "$buf"
  return "$rc"
}

# --- The reimplemented protected-path list ----------------------------------
# Deliberately not sourced from lib/landing.sh — see this file's own header.
# Kept byte-for-byte in step with _landing_is_protected (lib/landing.sh),
# and test/detect-classifier-escapes.test.sh pins the two identical over the
# same battery of paths so a change to one that is not mirrored in the other
# fails CI rather than drifting silently.
_escape_audit_is_protected() {
  case "$1" in
    .github/*) return 0 ;;
    deploy/*) return 0 ;;
    prompts/*) return 0 ;;
    lib/*) return 0 ;;
    config.schema.json) return 0 ;;
    config.json) return 0 ;;
    agent-cycle.sh) return 0 ;;
    review-cycle.sh) return 0 ;;
    CODEOWNERS) return 0 ;;
    *) return 1 ;;
  esac
}

# --- The reimplemented routine-sources resolution ---------------------------
# Deliberately not sourced from lib/landing.sh's _landing_routine_sources —
# same reasoning as the protected-path list above, and pinned against it the
# same way in test/detect-classifier-escapes.test.sh.
_escape_audit_routine_sources() {
  local config_json="$1" repo_slug="$2" repo_list top_list
  repo_list="$(jq -c --arg slug "$repo_slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_autonomy_routine_sources // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$repo_list" ]] && jq -e 'type == "array"' <<<"$repo_list" >/dev/null 2>&1; then
    printf '%s' "$repo_list"
    return 0
  fi
  top_list="$(jq -c '.merge_autonomy_routine_sources // empty' <<<"$config_json" 2>/dev/null)"
  if [[ -n "$top_list" ]] && jq -e 'type == "array"' <<<"$top_list" >/dev/null 2>&1; then
    printf '%s' "$top_list"
    return 0
  fi
  printf '["register-hygiene","tech-debt"]'
}

# --- The merge commit's own file list ---------------------------------------
# repos/SLUG/commits/SHA, never repos/SLUG/pulls/N/files (landing_protected_
# paths_hit's own read) — a genuinely different GitHub resource. GitHub omits
# `files` from this response outright once a commit's diff is too large to
# enumerate rather than paginating it, so a response with no `files` array at
# all is exactly as untrustworthy as a truncated listing is elsewhere in this
# codebase: a refusal to answer "no protected path", never a pass.
_escape_audit_merge_files() {
  local repo_slug="$1" sha="$2" raw
  raw="$(gh_retry api "repos/$repo_slug/commits/$sha")" || return 2
  jq -e '.files | type == "array"' <<<"$raw" >/dev/null 2>&1 || return 2
  jq -r '.files[].filename' <<<"$raw" 2>/dev/null
}

# --- Complexity as of the merge, replayed from the labelled/unlabelled
# timeline -------------------------------------------------------------------
# Prints the single complexity:* label standing at MERGED_AT, or nothing if
# zero or more than one were standing (the caller treats either as
# unverifiable, never guesses between them).
_escape_audit_complexity_at_merge() {
  local repo_slug="$1" number="$2" merged_at="$3" raw
  raw="$(gh_retry api "repos/$repo_slug/issues/$number/events" --paginate -F per_page=100 \
    --jq '.[] | select(.event == "labeled" or .event == "unlabeled") | select((.label.name // "") | test("^complexity:")) | {event, label: .label.name, at: .created_at}')" \
    || return 2
  jq -s -r --arg cut "$merged_at" '
    map(select((.at // "") <= $cut)) | sort_by(.at)
    | reduce .[] as $e ({}; if $e.event == "labeled" then .[$e.label] = true else del(.[$e.label]) end)
    | keys | if length == 1 then (.[0] | sub("^complexity:"; "")) else empty end
  ' <<<"$raw" 2>/dev/null
}

# --- Every merged, APPROVER_LOGIN-merged, LABEL-carrying pull request ------
# REST over search (same reasoning as mine-merge-history.sh's own header):
# repos/SLUG/issues, state=closed, filtered by label, one flat 1-point-per-
# page cost against the shared `core` budget. A closed issue's own
# `pull_request.merged_at` distinguishes a merge from a plain close.
_escape_audit_candidates() {
  local repo_slug="$1"
  gh_retry api "repos/$repo_slug/issues" --paginate -F per_page=100 \
    -f state=closed -f labels="$LABEL" \
    --jq '.[] | select(.pull_request != null and .pull_request.merged_at != null) | .number'
}

# --- Already-audited pr_urls, and recorded landing-armed facts, from the
# fleet log -------------------------------------------------------------------
audited_file="$(mktemp)"
armed_file="$(mktemp)"
trap 'rm -f "$audited_file" "$armed_file"' EXIT

read_log() {
  if [[ "$log_source" == "-" ]]; then
    cat
  elif [[ -s "$log_source" ]]; then
    cat "$log_source"
  fi
}

read_log | jq -c -R 'fromjson? // empty' 2>/dev/null > "$audited_file.raw" || true

jq -c --arg r "$slug" \
  'select((.repo // "") == $r and (.event == "classifier-escape" or .event == "landing-audit")) | .pr_url // empty' \
  "$audited_file.raw" 2>/dev/null | sort -u > "$audited_file" || true

jq -c --arg r "$slug" \
  'select((.repo // "") == $r and .event == "landing-armed") | {pr_url: (.pr_url // ""), source: (.source // "")}' \
  "$audited_file.raw" 2>/dev/null > "$armed_file" || true
rm -f "$audited_file.raw"

already_audited() {
  local url="$1"
  grep -qxF "\"$url\"" "$audited_file" 2>/dev/null
}

recorded_source_for() {
  local url="$1"
  jq -r --arg u "$url" 'select(.pr_url == $u) | .source' "$armed_file" 2>/dev/null | tail -1
}

config_json="$(cat "$CONFIG_FILE" 2>/dev/null || printf '{}')"
routine_json="$(_escape_audit_routine_sources "$config_json" "$slug")"

emit() {
  local outcome="$1" pr_url="$2" number="$3" sha="$4" source="$5" complexity="$6" \
        hit="$7" paths_json="$8" reason="$9"
  jq -nc --arg o "$outcome" --arg u "$pr_url" --arg r "$slug" --argjson n "$number" \
    --arg sha "$sha" --arg src "$source" --arg c "$complexity" --arg h "$hit" \
    --argjson p "$paths_json" --arg reason "$reason" '
    {outcome: $o, pr_url: $u, repo: $r, number: $n,
     merge_commit_sha: (if $sha == "" then null else $sha end),
     source: (if $src == "" then null else $src end),
     complexity_recomputed: (if $c == "" then null else $c end),
     protected_paths_hit: (if $h == "true" then true elif $h == "false" then false else null end),
     protected_paths: $p, reason: $reason}'
}

while IFS= read -r number; do
  [[ -n "$number" ]] || continue

  pr_json="$(gh_retry api "repos/$slug/pulls/$number")" || {
    # An unreadable pull request record: cannot even confirm merged_by, so
    # this candidate is neither confirmed as an Approver-identity landing
    # nor safely skippable forever. Left unaudited rather than guessed at —
    # the next cycle's run tries again, exactly as an unreadable candidate
    # anywhere else in this codebase is retried, not given up on.
    continue
  }
  merged="$(jq -r '.merged // false' <<<"$pr_json" 2>/dev/null)"
  [[ "$merged" == "true" ]] || continue
  merged_by="$(jq -r '.merged_by.login // ""' <<<"$pr_json" 2>/dev/null)"
  [[ "$merged_by" == "$approver_login" ]] || continue

  pr_url="$(jq -r '.html_url // ""' <<<"$pr_json" 2>/dev/null)"
  [[ -n "$pr_url" ]] || continue
  already_audited "$pr_url" && continue

  merged_at="$(jq -r '.merged_at // ""' <<<"$pr_json" 2>/dev/null)"
  sha="$(jq -r '.merge_commit_sha // ""' <<<"$pr_json" 2>/dev/null)"

  reasons=()

  source="$(recorded_source_for "$pr_url")"
  if [[ -z "$source" ]]; then
    reasons+=("no landing-armed event in the fleet log records this pull request's work source")
  fi

  complexity=""
  if [[ -z "$sha" ]]; then
    reasons+=("the merge carries no merge_commit_sha")
    hit="" paths_json='[]'
  else
    files_out="$(_escape_audit_merge_files "$slug" "$sha")"; files_rc=$?
    if (( files_rc != 0 )); then
      reasons+=("the merge commit's own file list could not be read (unreadable or too large to enumerate)")
      hit="" paths_json='[]'
    else
      declare -a protected=()
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        _escape_audit_is_protected "$path" && protected+=("$path")
      done <<<"$files_out"
      if (( ${#protected[@]} > 0 )); then
        hit="true"
        paths_json="$(printf '%s\n' "${protected[@]}" | jq -R . | jq -s -c .)"
      else
        hit="false"
        paths_json='[]'
      fi
    fi
  fi

  if [[ -z "$merged_at" ]]; then
    reasons+=("the pull request record carries no merged_at")
  else
    complexity="$(_escape_audit_complexity_at_merge "$slug" "$number" "$merged_at")"
    complexity_rc=$?
    if (( complexity_rc != 0 )); then
      reasons+=("the labelled/unlabelled timeline could not be read")
    elif [[ -z "$complexity" ]]; then
      reasons+=("no single complexity:* label was standing at merge time")
    fi
  fi

  if (( ${#reasons[@]} > 0 )); then
    reason="$(IFS='; '; echo "${reasons[*]}")"
    emit "unverifiable" "$pr_url" "$number" "$sha" "$source" "$complexity" "$hit" "$paths_json" "$reason"
    continue
  fi

  eligible=1
  disagreements=()
  case "$complexity" in
    low|medium) ;;
    *) eligible=0; disagreements+=("complexity was $complexity, not low or medium") ;;
  esac
  if ! jq -e --arg s "$source" 'index($s) != null' <<<"$routine_json" >/dev/null 2>&1; then
    eligible=0
    disagreements+=("source $source is not in $slug's routine list $routine_json")
  fi
  if [[ "$hit" == "true" ]]; then
    eligible=0
    disagreements+=("touched protected path(s): $(jq -r 'join(", ")' <<<"$paths_json")")
  fi

  if (( eligible )); then
    emit "clean" "$pr_url" "$number" "$sha" "$source" "$complexity" "$hit" "$paths_json" \
      "recomputed eligibility agrees: this landing should have been eligible"
  else
    reason="$(IFS='; '; echo "${disagreements[*]}")"
    emit "escape" "$pr_url" "$number" "$sha" "$source" "$complexity" "$hit" "$paths_json" \
      "landed under the Approver identity but recomputed eligibility disagrees: $reason"
  fi
done < <(_escape_audit_candidates "$slug")
