#!/usr/bin/env bash
#
# lib/version.sh — what code this node is actually running.
#
# A node updates by pulling a new image, never by pulling a branch, so "which
# version is this?" is a question about the image and not about any checkout on
# the host. The image answers it itself: CI stamps `build-info.json` into /app
# at build time (see deploy/docker/Dockerfile and .github/workflows/
# build-image.yml), naming the commit that was built, the pull request that
# commit merged, and when the build ran.
#
# The pull request number is the version an operator can actually use. A commit
# SHA says which bytes are running but not what is in them; `#89` is a title, a
# diff, a review and a merge time, one click away — which is the whole reason
# the dashboard renders it as a link with the record behind it.
#
# Sourced by scripts/state-sync.sh (which publishes the answer in each node's
# heartbeat, so every node's dashboard can report every node's version), by
# scripts/publish-dashboard.sh (which reads our own directly), and by
# scripts/doctor.sh (which uses .repo alone, to know which repository's own
# branch ruleset to check — requirement 25a). All three need the same
# answer, so the derivation lives here rather than in any of them.

# The pull request a squash-merge subject names: this repository merges every
# change as `<conventional commit subject> (#N)`, so the trailing `(#N)` of the
# commit at the tip of `main` is the last pull request contained in a build of
# it. Prints nothing when the subject carries no such marker — a build of an
# unmerged branch, or of a commit pushed straight to main.
version_pr_from_subject() {  # <commit subject>
  [[ "$1" =~ \(#([0-9]+)\)[[:space:]]*$ ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# owner/repo from a remote URL, in either of git's two shapes. Anything else
# prints nothing rather than a guess.
version_slug_from_remote() {  # <remote url>
  local url="${1%.git}"
  case "$url" in
    *github.com[:/]*) printf '%s' "${url#*github.com}" | sed -e 's#^[:/]##' ;;
    *) : ;;
  esac
  return 0
}

# One JSON object describing the running code, or the JSON literal `null` when
# neither source can answer:
#
#   {pr, commit, short, built_at, repo, source, dirty}
#
#   source "image"    the CI stamp — a deployed container
#   source "checkout"  git HEAD — a developer's clone, or the legacy WSL install
#
# `pr` is a number or null: a build can legitimately contain no merged pull
# request, and inventing one would be worse than saying so.
agent_ops_version() {  # [app-dir]
  local app="${1:-}"
  [[ -n "$app" ]] || app="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  local stamp="$app/build-info.json"
  local commit="" pr="" built_at="" repo="" source="" dirty=false

  # Every read below is `|| true`-guarded rather than merely redirected. This is
  # sourced by scripts/state-sync.sh, which runs under `set -e`, and each of
  # these can legitimately fail — a truncated stamp, a repository with no
  # commits yet, a clone with no `origin` — none of which is a reason to abort a
  # node's heartbeat. A bare assignment from a failing command substitution
  # would do exactly that.
  #
  # The stamp comes first, and only if it names a commit: a locally built image
  # gets the file with empty values (the build args are CI's), and those must
  # fall through to git rather than render as a version of nothing.
  if [[ -s "$stamp" ]]; then
    commit="$(jq -r '.commit // ""' "$stamp" 2>/dev/null || true)"
    [[ "$commit" == "null" ]] && commit=""
    if [[ -n "$commit" ]]; then
      pr="$(jq -r '.pr // ""'             "$stamp" 2>/dev/null || true)"
      built_at="$(jq -r '.built_at // ""' "$stamp" 2>/dev/null || true)"
      repo="$(jq -r '.repo // ""'         "$stamp" 2>/dev/null || true)"
      source="image"
    fi
  fi

  if [[ -z "$source" ]] && command -v git >/dev/null 2>&1 \
     && git -C "$app" rev-parse --git-dir >/dev/null 2>&1; then
    # `--verify`, because plain `rev-parse HEAD` in a repository with no commits
    # prints the literal string "HEAD" on stdout and fails — so swallowing the
    # failure alone would report a node running commit "HEAD". The hex test is
    # the belt to that brace.
    commit="$(git -C "$app" rev-parse --verify HEAD 2>/dev/null || true)"
    [[ "$commit" =~ ^[0-9a-f]{7,}$ ]] || commit=""
    if [[ -n "$commit" ]]; then
      pr="$(version_pr_from_subject "$(git -C "$app" log -1 --pretty=%s 2>/dev/null || true)")"
      built_at="$(git -C "$app" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --pretty=%cd 2>/dev/null || true)"
      repo="$(version_slug_from_remote "$(git -C "$app" remote get-url origin 2>/dev/null || true)")"
      # A checkout with uncommitted work is not the commit it claims to be, and
      # on the one node that still runs from a checkout that is worth knowing.
      git -C "$app" diff --quiet HEAD 2>/dev/null || dirty=true
      source="checkout"
    fi
  fi

  [[ -n "$source" ]] || { printf 'null'; return 0; }

  jq -nc \
    --arg commit "$commit" \
    --arg built_at "$built_at" \
    --arg repo "$repo" \
    --arg source "$source" \
    --argjson pr "$([[ "$pr" =~ ^[0-9]+$ ]] && printf '%s' "$pr" || printf 'null')" \
    --argjson dirty "$dirty" \
    '{pr: $pr,
      commit: $commit,
      short: ($commit | .[0:7]),
      built_at: (if $built_at == "" then null else $built_at end),
      repo: (if $repo == "" then null else $repo end),
      source: $source,
      dirty: $dirty}'
}
