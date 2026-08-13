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
# Print `clean` or `dirty<TAB>reason`. Exit 0 for clean, 1 for dirty — the
# same shape lib/review-gate.sh's `review_gate_verdict` reports, so a caller
# can fold both into one handoff gate.
closing_keyword_gate() {
  local url="${1:-}" gh_bin="${CLOSING_KEYWORD_GATE_GH:-gh}"
  local checker="${CLOSING_KEYWORD_GATE_CHECK:-}"
  local pr_json body head_branch reason

  [[ -n "$checker" ]] || checker="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/check-closing-keyword.sh"

  if [[ -z "$url" ]]; then
    printf 'dirty\tno pull request URL to check'
    return 1
  fi

  if ! pr_json="$("$gh_bin" pr view "$url" --json body,headRefName 2>/dev/null)"; then
    printf 'dirty\tcould not read %s' "$url"
    return 1
  fi
  body="$(jq -r '.body // ""' <<<"$pr_json")"
  head_branch="$(jq -r '.headRefName // ""' <<<"$pr_json")"

  if reason="$("$checker" "$body" "$head_branch" 2>&1 >/dev/null)"; then
    printf 'clean'
    return 0
  fi
  # One line, always. The checker writes one `::error::`-prefixed line per
  # fault it finds, and an `agent/<N>` branch missing its marker earns two of
  # them (the absent marker, then the absent keyword) — but every caller reads
  # this verdict with `IFS=$'\t' read -r word reason`, which keeps the first
  # line and silently discards the rest. Flatten here, where the whole reason
  # is still in hand, rather than let it be truncated there. The `::error::`
  # prefix is a GitHub Actions workflow command and means nothing in the two
  # places this reason actually lands — a PR comment a human reads, and the
  # `attempt-failed` record the Enabler reads — so it goes with it.
  reason="${reason//::error::/}"
  reason="${reason//$'\n'/; }"
  printf 'dirty\t%s' "${reason:-check-closing-keyword.sh failed with no output}"
  return 1
}
