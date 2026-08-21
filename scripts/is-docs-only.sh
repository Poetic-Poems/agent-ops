#!/usr/bin/env bash
#
# scripts/is-docs-only.sh — is this set of changed paths prose and nothing else?
#
# Exit 0 when every path handed to it is one that cannot reach a node through
# the image, and non-zero otherwise, printing the paths that forced the "no" so
# the caller's log says which file cost the build.
#
# `.github/workflows/build-image.yml` asks the question to decide whether a
# change needs an image at all. /app inside the image *is* this repository, so
# very little here is incapable of changing what a node does — but a document
# the image is not the delivery path for cannot, and a change confined to those
# is worth neither a build on a pull request nor an image roll across the fleet
# on `main`.
#
# "Cannot reach a node through the image" is the exact test, and it is not the
# same thing as "nobody reads it". A cycle working on *this* repository does
# read its `CLAUDE.md` and its `TECH-DEBT.md` — but out of the fresh
# `gh repo clone` in `workspace_root`, and scripts/gather-register-hygiene.sh
# reads the register straight from the contents API. Both arrive from GitHub
# the moment a pull request merges, with no image in the path, so no build can
# make them arrive sooner and skipping one delays nothing.
#
# What is never read is the copy at /app. Every `claude -p` in agent-cycle.sh
# and review-cycle.sh runs with its working directory under `workspace_root`
# or `state_dir` (`assert_in_workspace` pins the first of those), so /app is
# neither a working directory nor an ancestor of one, and /app/CLAUDE.md is
# never loaded as project memory. Moving a stage's cwd would break that, which
# is why it is written down here.
#
# Paths on the command line, or one per line on stdin when there are none:
#
#   git diff --no-renames --name-only main...HEAD | ./scripts/is-docs-only.sh
#
# The inert set is an explicit allowlist of paths, deliberately not a rule
# about file extensions, and that is the whole point of this file. The
# `prompts/*.md` are Markdown documents, and they are also the *code* of the
# coordinator, the implementer and the reviewer — the text fed to `claude -p`
# at each stage. Judging by extension would let a change to how a node thinks
# skip the build that deploys it, which is the one failure this must not have.
# `test/fixtures/*.md` and `.claude/skills/**` are Markdown for the same
# not-prose reason.
#
# So anything not named below counts as code. Adding a document is one line
# here, and forgetting to add it costs a build nobody needed — the cheap side
# of the mistake, against a deployment nobody got.
#
# It fails safe in one direction only: no paths at all — an empty diff, or a
# caller that could not work out what changed — is "not documentation-only",
# because "may we skip the build?" must never be answered yes by silence.

set -uo pipefail

# Every pattern anchored whole, so `README.mdx` and `docsy/note.md` are code.
is_inert() {
  case "$1" in
    docs/*) return 0 ;;                   # the as-built specs and the roadmap
    README.md) return 0 ;;
    CLAUDE.md) return 0 ;;                # a cycle reads the clone's copy, never /app's
    TECH-DEBT.md) return 0 ;;             # likewise, and via the contents API
    tech-debt/*) return 0 ;;              # the per-item register: item files are records, not code
    LICENCE) return 0 ;;
    deploy/docker/README.md) return 0 ;;  # the node runbook
    *) return 1 ;;
  esac
}

paths=( "$@" )
if (( ${#paths[@]} == 0 )); then
  while IFS= read -r line; do
    [[ -n "$line" ]] && paths+=( "$line" )
  done
fi

if (( ${#paths[@]} == 0 )); then
  echo "is-docs-only: no paths given — treating the change as not documentation-only" >&2
  exit 1
fi

status=0
for path in "${paths[@]}"; do
  is_inert "$path" || { printf '%s\n' "$path"; status=1; }
done
exit "$status"
