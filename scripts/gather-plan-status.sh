#!/usr/bin/env bash
#
# gather-plan-status.sh — what an implementation-plan document's own checkbox
# says about specific task ids (requirement 34i's implementation-plan half).
#
# Given a repo slug, its default branch, the repo's `implementation_plan_path`
# and one or more task ids, print a JSON object mapping each id it could read a
# definite checkbox state for to `"done"` or `"open"`:
#
#   {"W10-breach-handling": "done"}
#
# Usage: gather-plan-status.sh <owner/repo> <default-branch> <path> <id> [<id>…]
#
# ## Certainty, and what happens without it
#
# An id resolves only when exactly one markdown task-list line in the document
# names it: `- [ ] W10-breach-handling: …` or `- [x] …` (also `*` bullets and
# `1.`-style numbered ones; case-insensitive on the `x`). The id must appear as
# a whole word on that line — bounded by anything other than a letter, digit,
# underscore or hyphen, including the line's own edges — so one task id that
# happens to be a substring of another's (`W10-breach` inside
# `W10-breach-handling`) cannot be credited to the wrong line. Two lines naming
# the same id, or none, resolve nothing: an ambiguous document is not a
# completion signal, and unlike `scripts/gather-register-status.sh`'s frontmatter
# there is no second field here to break the tie.
#
# Everything short of that certainty is simply absent from the output. The
# caller (`lib/work-gone.sh`) treats absence as "not known to be gone" and
# leaves the item blocked — the failure this leans toward is a delayed
# clearance, never a false one.
#
# Never exits non-zero: it always prints a valid object. A gatherer that
# aborted the cycle would make a tidy-up a reliability risk.

set -uo pipefail

slug="${1:-}"
branch="${2:-}"
path="${3:-}"
shift 3 2>/dev/null || true
if [[ -z "$slug" || -z "$branch" || -z "$path" ]]; then
  echo "usage: gather-plan-status.sh <owner/repo> <default-branch> <path> <id> [<id>…]" >&2
  printf '{}'
  exit 0
fi
if (( $# == 0 )); then
  printf '{}'
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The document, and the one place a missing plan is normal rather than a
# fault: a repo's `implementation_plan_path` can point at a file since deleted
# or renamed. A 404 is that answer and is silent; anything else — auth, rate
# limit, network — is diagnosed on stderr, where agent-cycle.sh captures it per
# cycle. Both print `{}`; only one of them says nothing.
content_json="$(gh api "repos/$slug/contents/$path?ref=$branch" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  if [[ "$(jq -r '.status // ""' <<<"$content_json" 2>/dev/null)" != "404" ]]; then
    cat "$work/gh.err" >&2
  fi
  printf '{}'
  exit 0
fi

blob="$(jq -r '.content // ""' <<<"$content_json" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null || true)"
if [[ -z "$blob" ]]; then
  printf '{}'
  exit 0
fi

# checkbox_state ID — read the plan document on stdin, print "done", "open" or
# nothing. Only a task-list line (`-`/`*`/`N.` bullet, then `[ ]`/`[x]`/`[X]`)
# that names ID as a whole word counts; `n` above 1 means two such lines
# disagreed about which one is ID's, which resolves nothing rather than
# guessing.
checkbox_state() {
  awk -v id="$1" '
    /^[ \t]*([-*]|[0-9]+\.)[ \t]*\[[ xX]\]/ {
      padded = " " $0 " "
      pat = "[^A-Za-z0-9_-]" id "[^A-Za-z0-9_-]"
      if (padded ~ pat) {
        match($0, /\[[ xX]\]/)
        mark = substr($0, RSTART + 1, 1)
        n++
        last = (mark == " ") ? "open" : "done"
      }
    }
    END { if (n == 1) print last }
  '
}

out="{}"
for id in "$@"; do
  [[ -n "$id" ]] || continue
  state="$(printf '%s\n' "$blob" | checkbox_state "$id")"
  [[ -n "$state" ]] || continue
  out="$(jq -c --arg k "$id" --arg v "$state" '. + {($k): $v}' <<<"$out" 2>/dev/null || printf '%s' "$out")"
done

printf '%s' "$out"
