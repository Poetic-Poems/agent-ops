#!/usr/bin/env bash
#
# scripts/release-pending-reservations.sh — retry a tech-debt reservation
# release lib/tech-debt-file.sh's `_techdebt_unfile` could not make land
# (TD-PPagop-26082427).
#
# `_techdebt_unfile` runs once, on techdebt_file_debt's own failure path,
# against the same GitHub API whose failure just put it there — a transient
# window that fails a filing's branch-create or contents-write call is the
# same window that can fail the DELETE meant to undo it. Nothing before this
# script ever retried that DELETE: `scripts/sweep-orphan-branches.sh`
# deliberately leaves a bare `td/<id>` reservation branch alone (issue #545,
# since it cannot tell whether <id> has since been filed elsewhere), and
# `.github/workflows/release-td-branch.yml` only ever fires for a `td/<id>`
# whose record actually reached `main` — an id that was reserved and then
# abandoned never gets that push. Left uncovered, a reservation orphaned this
# way is "left for good", the exact phrase `lib/tech-debt-file.sh`'s own
# header used to concede before this script existed: observed for real on
# this repository, fourteen consecutive reservations (TD-PPagop-26082407
# through TD-PPagop-26082420) orphaned in one seventy-second window on
# 2026-08-23, each one _techdebt_unfile's own failed DELETE.
#
# Since TD-PPagop-26082427, a DELETE _techdebt_unfile could not make land
# writes a durable marker instead of only logging and swallowing the
# failure — `_techdebt_record_pending_release`, one JSON file per pending
# release under `reservation-releases/<repo>/<branch>.json` in the state
# repository (the same `state_repo` `lib/claim.sh`'s own claim registry
# already lives in, under its own `claims/` tree). This script is the other
# half: every cycle (lib/standdown.sh, step 2.1g), fleet-wide regardless of
# `--repo`, it walks that tree, retries each marker's own delete, and clears
# the marker once the branch is confirmed gone — by this retry, by a peer
# node's concurrent retry, or by anything else that already deleted it
# (`.github/workflows/release-td-branch.yml`'s own ordinary path included).
# A delete that fails again leaves the marker in place for the next cycle's
# pass, so recovery costs no more than time: the marker survives until a
# transient GitHub failure finally clears, or a human deletes the branch by
# hand and lets this script notice on its next pass.
#
# Requires no repository argument: every marker names its own target repo,
# so one invocation walks every pending release in the state repository
# regardless of which repositories this installation is configured against.
# A no-op when `state_repo` is unset — the same single-node reading
# `lib/claim.sh`'s own registry gives it.
#
# Output: one JSON object per marker examined, on stdout —
#   {"action":"released","repo":…,"branch":…}
#   {"action":"absent","repo":…,"branch":…}
#   {"action":"warning","repo":…,"branch":…,"detail":…}
# The caller logs them; this script logs nothing itself. Always exits 0 — a
# branch this script fails to delete must not fail the cycle it runs inside;
# the marker it leaves behind is what stands behind it.
#
# Usage: release-pending-reservations.sh
# Environment: RELEASE_PENDING_GH overrides `gh` (tests stub it);
# AGENT_OPS_CONFIG overrides the config path, as review-cycle.sh accepts it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this pass to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
GH="${RELEASE_PENDING_GH:-gh}"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"

# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below, with no `// literal` of its own to drift from the schema's.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

state_repo="$(cfg '.state_repo')"
[[ -n "$state_repo" ]] || exit 0

warn() {  # warn REPO BRANCH DETAIL
  jq -nc --arg r "$1" --arg b "$2" --arg d "$3" \
    '{action: "warning", repo: $r, branch: $b, detail: $d}'
}

# One marker: retry its delete, then clear the marker on any outcome that
# leaves nothing further to retry.
release_one() {  # <dir> <file>
  local dir="$1" f="$2" resp file_sha entry e_repo e_branch get_err get_rc action

  resp="$("$GH" api "repos/$state_repo/contents/reservation-releases/$dir/$f" 2>/dev/null)" || return 0
  file_sha="$(jq -r '.sha // empty' <<<"$resp" 2>/dev/null)"
  entry="$(jq -r '.content // empty' <<<"$resp" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null)"
  [[ -n "$file_sha" && -n "$entry" ]] || return 0

  e_repo="$(jq -r '.repo // empty' <<<"$entry" 2>/dev/null)"
  e_branch="$(jq -r '.branch // empty' <<<"$entry" 2>/dev/null)"
  if [[ -z "$e_repo" || -z "$e_branch" ]]; then
    warn "" "reservation-releases/$dir/$f" "malformed marker — leaving it in place"
    return 0
  fi

  if "$GH" api -X DELETE "repos/$e_repo/git/refs/heads/$e_branch" >/dev/null 2>&1; then
    action="released"
  else
    # Same confirmation _techdebt_release_ref itself makes (lib/tech-debt-file.sh):
    # a DELETE can fail because the branch is already gone — released by a
    # peer node's own concurrent retry, or by release-td-branch.yml's
    # ordinary path, since a marker is only ever cleared once, never
    # renewed. Only a confirmed 404 counts as "nothing left to retry"; any
    # other answer, including the confirmation call itself failing, leaves
    # the marker standing for the next pass.
    get_err="$("$GH" api "repos/$e_repo/git/ref/heads/$e_branch" 2>&1 >/dev/null)"
    get_rc=$?
    if (( get_rc == 0 )) || [[ "$get_err" != *"HTTP 404"* ]]; then
      warn "$e_repo" "$e_branch" "delete failed again — marker left in place"
      return 0
    fi
    action="absent"
  fi

  if "$GH" api -X DELETE "repos/$state_repo/contents/reservation-releases/$dir/$f" \
       -f "message=reservation release settled: $e_branch" -f "sha=$file_sha" \
       >/dev/null 2>&1; then
    jq -nc --arg r "$e_repo" --arg b "$e_branch" --arg a "$action" '{action: $a, repo: $r, branch: $b}'
  else
    warn "$e_repo" "$e_branch" \
      "branch $action but its marker could not be cleared — will report it again next pass"
  fi
}

dirs="$("$GH" api "repos/$state_repo/contents/reservation-releases" \
  --jq '[.[] | select(.type == "dir") | .name] | .[]' 2>/dev/null)" || exit 0

while IFS= read -r dir; do
  [[ -n "$dir" ]] || continue
  files="$("$GH" api "repos/$state_repo/contents/reservation-releases/$dir" \
    --jq '[.[] | select(.type == "file") | .name] | .[]' 2>/dev/null)" || continue
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    release_one "$dir" "$f"
  done <<<"$files"
done <<<"$dirs"

exit 0
