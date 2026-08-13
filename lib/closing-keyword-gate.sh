#!/usr/bin/env bash
#
# lib/closing-keyword-gate.sh — pipeline-side enforcement of requirement 25a
# for every target repository, not only the one that carries a workflow file
# (TD-PPagop-26080803).
#
# `.github/workflows/closing-keyword.yml` runs `scripts/check-closing-keyword.sh`
# on every `pull_request` event, but a workflow file only guards the
# repository that ships it, and only agent-ops does. For poetic and
# poetic-fiddle — the other two repositories this pipeline raises pull
# requests in — an issue-sourced pull request could still merge without its
# closing keyword: pre-merge enforcement there was the Implementor prompt
# again, the same prompt-only enforcement that was already asked for this and
# silently skipped once (PR #206, issue #198 open three days — issue #240).
#
# This file runs the exact same check the workflow does, script-side, so it
# applies everywhere the Script itself acts, regardless of which repository's
# CI does or does not carry the workflow. It reuses
# `scripts/check-closing-keyword.sh` unmodified — that script already takes
# `<pr-body> [<head-branch>]` and needs nothing from the caller but the two
# facts `gh pr view` already knows.
#
# "Could not ask" is `unknown`, not `dirty`. A `gh pr view` that fails past
# lib/github-limit.sh's retry — a 502, a transient auth failure, a primary
# limit whose reset is too far off to wait — says something about this node,
# not about the pull request, and the reasoning lib/review-gate.sh spells out
# for its own alerts read applies unchanged: blocking every handoff on a
# degraded `gh` forever would trade one hazard for a worse one. The analogy
# that does *not* hold is `review_gate_required_checks`, which does report an
# unreadable check list as `dirty` — there, silence is itself the hazard
# (poetic-fiddle #190, a CONFLICTING pull request, genuinely reports no
# required checks at all, so an empty list is what a bad pull request looks
# like). Nothing of the sort is true here: an unreadable pull request looks
# nothing like one missing its keyword, so reading one as the other buys no
# safety and costs every item on the node. The gate that a pull request
# cannot reach a human through is the one at the Reviewer's `ready` handoff,
# and `review_gate_required_checks` already fails closed there for any node
# whose `gh` is degraded enough to matter.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller (agent-cycle.sh runs under `set -euo pipefail`;
# a test, `set -uo pipefail`) owns those.
#
# Environment:
#   CLOSING_KEYWORD_GATE_GH     override `gh` (tests stub it).
#   CLOSING_KEYWORD_GATE_CHECK  override the checker script's path (tests
#     point it at a fixture; defaults to the real
#     scripts/check-closing-keyword.sh next to this file's own repository).

# closing_keyword_gate PR_URL
# Print `clean`, `dirty<TAB>reason`, or `unknown<TAB>reason`. Exit 0 for clean
# or unknown, 1 for dirty — the same shape lib/review-gate.sh's
# `review_gate_verdict` reports, so a caller can fold both into one handoff
# gate.
#   clean    the pull request's body carries a closing keyword for every issue
#            it claims to close, or claims none.
#   dirty    it claims one and does not close it — a fact about this pull
#            request, and a one-line body edit away from clean.
#   unknown  the question could not be put: `gh pr view` failed or answered
#            with something that is not a pull request, or the checker itself
#            could not be run. See the header for why that is not `dirty`.
closing_keyword_gate() {
  local url="${1:-}" gh_bin="${CLOSING_KEYWORD_GATE_GH:-gh}"
  local checker="${CLOSING_KEYWORD_GATE_CHECK:-}"
  local pr_json body head_branch reason rc

  [[ -n "$checker" ]] || checker="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/check-closing-keyword.sh"

  # No URL at all is the one unanswerable case that stays `dirty`: it is a
  # caller asking about nothing, a bug in this file's caller rather than a
  # degraded node, and the same thing `review_gate_required_checks` reports
  # for a URL it cannot resolve.
  if [[ -z "$url" ]]; then
    printf 'dirty\tno pull request URL to check'
    return 1
  fi

  # `headRefName` non-empty, not merely "the call exited 0": a truncated or
  # otherwise unexpected payload leaves both fields empty, and an empty body
  # on an empty branch name is exactly what a *clean* non-issue-sourced pull
  # request looks like to the checker. Silence must not read as a pass here
  # any more than it may in lib/review-gate.sh.
  if ! pr_json="$("$gh_bin" pr view "$url" --json body,headRefName 2>/dev/null)" \
     || ! jq -e '(type == "object") and (.headRefName | type == "string") and (.headRefName != "")' \
          <<<"$pr_json" >/dev/null 2>&1; then
    printf 'unknown\tcould not read %s'\''s body and head branch' "$url"
    return 0
  fi
  body="$(jq -r '.body // ""' <<<"$pr_json")"
  head_branch="$(jq -r '.headRefName' <<<"$pr_json")"

  reason="$("$checker" "$body" "$head_branch" 2>&1 >/dev/null)"
  rc=$?
  if (( rc == 0 )); then
    printf 'clean'
    return 0
  fi
  # One line, always. The checker writes one `::error::`-prefixed line per
  # fault it finds, and an `agent/<N>` branch missing its marker earns two of
  # them (the absent marker, then the absent keyword) — but every caller reads
  # this verdict with `IFS=$'\t' read -r word reason`, which keeps the first
  # line and silently discards the rest. Flatten here, where the whole reason
  # is still in hand, rather than let it be truncated there. The `::error::`
  # prefix is a GitHub Actions workflow command and means nothing in any of
  # the three places this reason actually lands — a `## Script findings` line
  # a Reviewer is asked to act on, a warning on the cycle log, and the
  # `attempt-failed` record the Enabler reads — so it goes with it.
  reason="${reason//::error::/}"
  reason="${reason//$'\n'/; }"
  # 126 (not executable), 127 (not found), 128+n (killed): the checker never
  # reached a verdict, so neither did this gate. Same reasoning as the
  # unreadable pull request above — a broken or missing checker is a fact
  # about this node's checkout, not about the pull request.
  if (( rc >= 126 )); then
    printf 'unknown\tcould not run %s (exit %d): %s' "$checker" "$rc" "${reason:-no output}"
    return 0
  fi
  printf 'dirty\t%s' "${reason:-check-closing-keyword.sh failed with no output}"
  return 1
}
