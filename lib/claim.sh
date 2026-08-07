#!/usr/bin/env bash
#
# lib/claim.sh — atomic per-item claims, the lock that lets several nodes run
# cycles at once without doing the same work twice.
#
# The primitive is create-only: a claim is won by creating something that can
# exist exactly once, and GitHub arbitrates.
#
#   branch claims   a REST create-ref on the *target* repository
#                   (`POST /git/refs`), which returns 422 when the ref exists
#                   — even at the same SHA, which a plain `git push` of an
#                   identical ref would silently no-op ("Everything
#                   up-to-date", both racers convinced they won). The claim
#                   branch *is* the working branch: `td/<ID>` for tech-debt —
#                   the same lock the human claiming workflow in TECH-DEBT.md
#                   takes, so agents and humans contend safely — and
#                   `agent/<item-ref>` for everything else.
#   file claims     a create-only contents-API PUT (no `sha`) in the state
#                   repository, for work that has no new branch to create:
#                   review-feedback amends an existing PR.
#
# Every won claim also writes a registry entry under `claims/<repo>/<key>.json`
# in the state repository — best-effort, advisory: the ref or file above is the
# lock; the registry is what back-pressure counts, the dashboard shows, and gc
# sweeps. The entry records the base SHA so a release deletes a claim branch
# only when it is exactly where the claim left it — pushed work is never
# deleted, whoever has to clean it up later.
#
#   claim.sh claim    branch <target-slug> <branch> <default-branch>
#   claim.sh claim    file   <target-slug> <key>
#   claim.sh release  branch <target-slug> <branch>   # ref iff unmoved+PR-less, then registry
#   claim.sh release  file   <target-slug> <key>      # registry only
#   claim.sh expire   <target-slug> <key>             # backdate ts; gc retires it next sweep
#   claim.sh count    <target-slug>                   # live registry entries
#   claim.sh claims   <target-slug>                   # registry entries younger than claim_ttl_hours,
#                                                      # as {item, kind, age_hours} (both shapes)
#   claim.sh branches <target-slug>                   # live td/*, <branch_prefix>* branch names
#   claim.sh gc                                       # sweep entries older than claim_ttl_hours
#
# Exit codes: 0 won / done · 3 lost (someone else holds it) · 1 error.
# A caller treating 1 as "lost" fails closed — correct: a node that cannot
# reach GitHub to claim could not push the work either. `claims` and
# `branches` are read-only listings, not claim/release outcomes: each always
# prints a JSON array (empty on any read failure) and exits 0, because their
# caller (the Script, gathering fleet-wide claim visibility before the
# Co-Ordinator runs — requirement 3o) must never fail a cycle over a listing
# it can simply come up short on this once.
#
# Environment:
#   CLAIM_GH      override `gh` (tests stub it).
#   CLAIM_NODE    this node's name, recorded in the registry entry.
#   CLAIM_CYCLE   the claiming cycle's id, recorded in the registry entry.
#   CLAIM_ITEM    the work item, recorded in the registry entry.
#   CLAIM_SOURCE  the work source, recorded in the registry entry.
#
# When `state_repo` is unset in config.json this is a single-node operation:
# file claims are vacuously won, the registry is skipped, and branch claims
# still work — the target repository exists regardless.
#
# One caller passes a pseudo-slug instead of a repository, and nothing here needs
# to know: the Enabler claims `file enabler <repo>__<item>__<blocked-epoch>`
# (implementation spec 35c), so its claims live under `claims/enabler/` where no
# target repo's can collide with them. Two properties of the code below are what
# make that safe, and both are worth not breaking. `count` reads only the slugs
# `config.json` configures, so an Enabler claim can never inflate back-pressure
# (requirement 2.2) with work that raises no PR. And `gc` sweeps whatever
# directories it finds, which is the *only* thing that retires those claims:
# they are deliberately never released, so a tombstone ageing out at
# `claim_ttl_hours` — or `expire`'s backdated `ts`, when the engagement that
# held it was itself discarded (issue #237) — is what lets a failed
# engagement be tried again.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

GH="${CLAIM_GH:-gh}"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"

# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below. Only ever invoked downstream of agent-cycle.sh's own schema gate, so
# a required key with no schema default (branch_prefix) is guaranteed present.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

state_repo="$(cfg '.state_repo')"
claim_ttl_hours="$(cfg '.claim_ttl_hours')"
branch_prefix="$(cfg '.branch_prefix')"

say() { printf 'claim: %s\n' "$*"; }

usage() { sed -n '3,47p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

san() { local s="$1"; printf '%s' "${s//\//__}"; }

registry_path() {  # <target-slug> <key> -> path inside the state repo
  printf 'claims/%s/%s.json' "$(san "$1")" "$(san "$2")"
}

# --- Registry (best-effort; the lock lives elsewhere) -------------------------
registry_put() {  # <target-slug> <key> <kind> <branch> <sha>
  [[ -n "$state_repo" ]] || return 0
  local body payload
  body="$(jq -nc \
    --arg node "${CLAIM_NODE:-$(hostname)}" --arg cycle "${CLAIM_CYCLE:-}" \
    --arg repo "$1" --arg key "$2" --arg kind "$3" --arg branch "$4" --arg sha "$5" \
    --arg item "${CLAIM_ITEM:-}" --arg source "${CLAIM_SOURCE:-}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{node: $node, cycle: $cycle, repo: $repo, key: $key, kind: $kind,
      branch: $branch, sha: $sha, item: $item, source: $source, ts: $ts}')"
  payload="$(printf '%s\n' "$body" | base64 -w0)"
  "$GH" api -X PUT "repos/$state_repo/contents/$(registry_path "$1" "$2")" \
    -f "message=claim: ${CLAIM_NODE:-?} $2" -f "content=$payload" >/dev/null 2>&1 || true
}

registry_get() {  # <target-slug> <key> -> the entry's JSON on stdout, or fail
  [[ -n "$state_repo" ]] || return 1
  local resp
  resp="$("$GH" api "repos/$state_repo/contents/$(registry_path "$1" "$2")" 2>/dev/null)" || return 1
  jq -r '.content' <<<"$resp" | tr -d '\n' | base64 -d 2>/dev/null
}

registry_rm() {  # <target-slug> <key>
  [[ -n "$state_repo" ]] || return 0
  local path sha
  path="$(registry_path "$1" "$2")"
  sha="$("$GH" api "repos/$state_repo/contents/$path" --jq '.sha' 2>/dev/null)" || return 0
  "$GH" api -X DELETE "repos/$state_repo/contents/$path" \
    -f "message=claim released: $2" -f "sha=$sha" >/dev/null 2>&1 || true
}

# --- The claims themselves -----------------------------------------------------
lost_or_error() {  # after a failed create: 3 if the thing now exists, else 1
  if "$@" >/dev/null 2>&1; then return 3; else return 1; fi
}

do_claim_branch() {  # <target-slug> <branch> <default-branch>
  local slug="$1" branch="$2" default_branch="$3" base_sha rc=0
  base_sha="$("$GH" api "repos/$slug/git/ref/heads/$default_branch" --jq '.object.sha' 2>/dev/null)" \
    || { say "cannot read $slug $default_branch head"; return 1; }
  if ! "$GH" api -X POST "repos/$slug/git/refs" \
        -f "ref=refs/heads/$branch" -f "sha=$base_sha" >/dev/null 2>&1; then
    # Existence decides between lost and error, rather than parsing gh's
    # message text: a 422 today words itself differently than it might later.
    lost_or_error "$GH" api "repos/$slug/git/ref/heads/$branch" || rc=$?
    (( rc == 3 )) && say "lost: $slug $branch already exists"
    (( rc == 1 )) && say "error: could not create nor read $slug $branch"
    return "$rc"
  fi
  say "won: $slug $branch at ${base_sha:0:12}"
  registry_put "$slug" "$branch" branch "$branch" "$base_sha"
  return 0
}

do_claim_file() {  # <target-slug> <key>
  local slug="$1" key="$2" rc=0 body payload path
  [[ -n "$state_repo" ]] || { say "no state_repo — file claim vacuously won"; return 0; }
  path="$(registry_path "$slug" "$key")"
  body="$(jq -nc \
    --arg node "${CLAIM_NODE:-$(hostname)}" --arg cycle "${CLAIM_CYCLE:-}" \
    --arg repo "$slug" --arg key "$key" \
    --arg item "${CLAIM_ITEM:-}" --arg source "${CLAIM_SOURCE:-}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{node: $node, cycle: $cycle, repo: $repo, key: $key, kind: "file",
      branch: "", sha: "", item: $item, source: $source, ts: $ts}')"
  payload="$(printf '%s\n' "$body" | base64 -w0)"
  if ! "$GH" api -X PUT "repos/$state_repo/contents/$path" \
        -f "message=claim: ${CLAIM_NODE:-?} $key" -f "content=$payload" >/dev/null 2>&1; then
    lost_or_error "$GH" api "repos/$state_repo/contents/$path" || rc=$?
    (( rc == 3 )) && say "lost: $key is already claimed"
    (( rc == 1 )) && say "error: could not create nor read the claim for $key"
    return "$rc"
  fi
  say "won: $key"
  return 0
}

# A claim branch is deleted only when BOTH hold: the ref still points at the
# SHA the claim recorded (nothing was pushed), and no open PR uses it as its
# head. Anything else means work happened — leave it for a human or for gc's
# same test on a later pass.
release_branch_if_untouched() {  # <target-slug> <branch> <claimed-sha>
  local slug="$1" branch="$2" claimed_sha="$3" current prs
  [[ -n "$claimed_sha" ]] || { say "no recorded SHA for $slug $branch — keeping the ref"; return 0; }
  current="$("$GH" api "repos/$slug/git/ref/heads/$branch" --jq '.object.sha' 2>/dev/null)" || return 0
  if [[ "$current" != "$claimed_sha" ]]; then
    say "keeping $slug $branch — it has moved since the claim"
    return 0
  fi
  prs="$("$GH" pr list -R "$slug" --head "$branch" --state open --json number --jq 'length' 2>/dev/null || echo 0)"
  if [[ "$prs" != "0" ]]; then
    say "keeping $slug $branch — an open PR uses it"
    return 0
  fi
  "$GH" api -X DELETE "repos/$slug/git/refs/heads/$branch" >/dev/null 2>&1 \
    && say "released: deleted untouched $slug $branch"
  return 0
}

do_release() {  # <kind> <target-slug> <key>
  local kind="$1" slug="$2" key="$3" entry sha
  if [[ "$kind" == "branch" ]]; then
    entry="$(registry_get "$slug" "$key" || true)"
    sha="$(jq -r '.sha // ""' <<<"$entry" 2>/dev/null || true)"
    release_branch_if_untouched "$slug" "$key" "$sha"
  fi
  registry_rm "$slug" "$key"
  return 0
}

# A discarded engagement whose claims are tombstones (the Enabler's — see
# the note at the top of this file) is never released outright: doing so
# would let the very next cycle re-engage the same unchanged items at Opus
# prices, which is the failure the tombstone exists to bound (issue #237,
# and requirement 35c's design-decision note). `expire` is the middle
# ground: it rewrites the registry entry's `ts` to a fixed date long past any
# realistic `claim_ttl_hours`, so `gc` retires it on the very next sweep
# instead of waiting out the entry's full, unshortened life. Every other
# field is carried over unchanged — this is a backdate, not a new claim, and
# a reader mid-way through `claims`/`gc` must see the same node, cycle, item
# and source it always would have.
#
# Silent no-op when the entry cannot be read or `state_repo` is unset — an
# annotation is advisory, like the registry it targets, and a caller already
# treats not-expired the same as expired-but-still-within-TTL: both just mean
# a later gc sweep is what retires it.
do_expire() {  # <target-slug> <key>
  local slug="$1" key="$2" path cursha entry node cycle kind branch sha item source body payload
  [[ -n "$state_repo" ]] || return 0
  path="$(registry_path "$slug" "$key")"
  cursha="$("$GH" api "repos/$state_repo/contents/$path" --jq '.sha' 2>/dev/null)" || return 0
  entry="$(registry_get "$slug" "$key" || true)"
  [[ -n "$entry" ]] || return 0
  node="$(jq -r '.node // ""' <<<"$entry")"
  cycle="$(jq -r '.cycle // ""' <<<"$entry")"
  kind="$(jq -r '.kind // "file"' <<<"$entry")"
  branch="$(jq -r '.branch // ""' <<<"$entry")"
  sha="$(jq -r '.sha // ""' <<<"$entry")"
  item="$(jq -r '.item // ""' <<<"$entry")"
  source="$(jq -r '.source // ""' <<<"$entry")"
  body="$(jq -nc --arg node "$node" --arg cycle "$cycle" --arg repo "$slug" --arg key "$key" \
    --arg kind "$kind" --arg branch "$branch" --arg sha "$sha" --arg item "$item" --arg source "$source" \
    '{node: $node, cycle: $cycle, repo: $repo, key: $key, kind: $kind,
      branch: $branch, sha: $sha, item: $item, source: $source, ts: "1970-01-01T00:00:01Z"}')"
  payload="$(printf '%s\n' "$body" | base64 -w0)"
  "$GH" api -X PUT "repos/$state_repo/contents/$path" \
    -f "message=claim expired: $key" -f "content=$payload" -f "sha=$cursha" >/dev/null 2>&1 || true
  return 0
}

do_count() {  # <target-slug> -> number of live registry entries
  [[ -n "$state_repo" ]] || { echo 0; return 0; }
  "$GH" api "repos/$state_repo/contents/claims/$(san "$1")" \
    --jq '[.[] | select(.type == "file")] | length' 2>/dev/null || echo 0
}

do_claims() {  # <target-slug> -> JSON array of {item, kind, age_hours} younger than claim_ttl_hours
  local slug="$1" now_epoch cutoff files f key entry ts_epoch item kind age_hours out
  out='[]'
  [[ -n "$state_repo" ]] || { printf '%s\n' "$out"; return 0; }
  now_epoch="$(date +%s)"
  cutoff=$(( now_epoch - claim_ttl_hours * 3600 ))
  files="$("$GH" api "repos/$state_repo/contents/claims/$(san "$slug")" \
    --jq '[.[] | select(.type == "file") | .name] | .[]' 2>/dev/null)" || { printf '%s\n' "$out"; return 0; }
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    key="${f%.json}"; key="${key//__//}"
    entry="$(registry_get "$slug" "$key" || true)"
    [[ -n "$entry" ]] || continue
    ts_epoch="$(date -d "$(jq -r '.ts // ""' <<<"$entry")" +%s 2>/dev/null || echo 0)"
    (( ts_epoch > 0 && ts_epoch >= cutoff )) || continue
    item="$(jq -r '.item // ""' <<<"$entry")"
    [[ -n "$item" ]] || continue
    kind="$(jq -r '.kind // "file"' <<<"$entry")"
    age_hours=$(( (now_epoch - ts_epoch) / 3600 ))
    out="$(jq -c --arg i "$item" --arg k "$kind" --argjson a "$age_hours" \
      '. + [{item: $i, kind: $k, age_hours: $a}]' <<<"$out" 2>/dev/null || printf '%s' "$out")"
  done <<<"$files"
  printf '%s\n' "$out"
}

do_branches() {  # <target-slug> -> JSON array of live td/*, <branch_prefix>* branch names
  local slug="$1" prefix td_refs pfx_refs
  td_refs="$("$GH" api "repos/$slug/git/matching-refs/heads/td/" \
    --jq '[.[].ref | ltrimstr("refs/heads/")]' 2>/dev/null)"
  [[ -n "$td_refs" ]] || td_refs='[]'
  prefix="$branch_prefix"
  pfx_refs='[]'
  if [[ "$prefix" != "td/" ]]; then
    pfx_refs="$("$GH" api "repos/$slug/git/matching-refs/heads/$prefix" \
      --jq '[.[].ref | ltrimstr("refs/heads/")]' 2>/dev/null)"
    [[ -n "$pfx_refs" ]] || pfx_refs='[]'
  fi
  jq -c -n --argjson a "$td_refs" --argjson b "$pfx_refs" '$a + $b' 2>/dev/null || echo '[]'
}

do_gc() {
  [[ -n "$state_repo" ]] || return 0
  local now_epoch cutoff dirs dir files f entry ts_epoch kind slug key sha
  now_epoch="$(date +%s)"
  cutoff=$(( now_epoch - claim_ttl_hours * 3600 ))
  dirs="$("$GH" api "repos/$state_repo/contents/claims" \
    --jq '[.[] | select(.type == "dir") | .name] | .[]' 2>/dev/null)" || return 0
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    files="$("$GH" api "repos/$state_repo/contents/claims/$dir" \
      --jq '[.[] | select(.type == "file") | .name] | .[]' 2>/dev/null)" || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      slug="${dir//__//}"; key="${f%.json}"; key="${key//__//}"
      entry="$(registry_get "$slug" "$key" || true)"
      [[ -n "$entry" ]] || continue
      ts_epoch="$(date -d "$(jq -r '.ts // ""' <<<"$entry")" +%s 2>/dev/null || echo 0)"
      (( ts_epoch > 0 && ts_epoch < cutoff )) || continue
      kind="$(jq -r '.kind // "file"' <<<"$entry")"
      sha="$(jq -r '.sha // ""' <<<"$entry")"
      say "gc: $slug $key ($kind) is older than ${claim_ttl_hours}h"
      [[ "$kind" == "branch" ]] && release_branch_if_untouched "$slug" "$key" "$sha"
      registry_rm "$slug" "$key"
    done <<<"$files"
  done <<<"$dirs"
  return 0
}

# --- Dispatch -------------------------------------------------------------------
MODE="${1:-}"; shift || true
case "$MODE" in
  claim)
    KIND="${1:-}"; shift || true
    case "$KIND" in
      branch) [[ $# -eq 3 ]] || { usage >&2; exit 64; }; do_claim_branch "$@"; exit $? ;;
      file)   [[ $# -eq 2 ]] || { usage >&2; exit 64; }; do_claim_file "$@";   exit $? ;;
      *) usage >&2; exit 64 ;;
    esac ;;
  release)
    KIND="${1:-}"; shift || true
    [[ ( "$KIND" == "branch" || "$KIND" == "file" ) && $# -eq 2 ]] || { usage >&2; exit 64; }
    do_release "$KIND" "$@"; exit $? ;;
  expire)   [[ $# -eq 2 ]] || { usage >&2; exit 64; }; do_expire "$@";   exit $? ;;
  count)    [[ $# -eq 1 ]] || { usage >&2; exit 64; }; do_count "$@";    exit $? ;;
  claims)   [[ $# -eq 1 ]] || { usage >&2; exit 64; }; do_claims "$@";   exit $? ;;
  branches) [[ $# -eq 1 ]] || { usage >&2; exit 64; }; do_branches "$@"; exit $? ;;
  gc)       [[ $# -eq 0 ]] || { usage >&2; exit 64; }; do_gc;            exit $? ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 64 ;;
esac
