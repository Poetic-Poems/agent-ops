#!/usr/bin/env bash
#
# gather-register-status.sh — what a repository's tech-debt register says about
# specific items, on its default branch (requirement 34i).
#
# Given a repo slug, its default branch and one or more item ids, print a JSON
# object mapping each id it could resolve *with certainty* to that item's
# `status` field:
#
#   {"TD-PPpfid-26072401": "resolved", "TD26071805": "resolved"}
#
# Usage: gather-register-status.sh <owner/repo> <default-branch> <id> [<id>…]
#
# ## Only the ids asked for, and only when they are blocked
#
# This is not a register reader; `scripts/gather-register-hygiene.sh` is that,
# and it pays for a whole tarball to run the checker over every file. This
# answers one question about a handful of named items — "is this one still
# work?" — and the Script calls it only for the blocked items whose ids are
# register ids, which is nearly always none. A fleet with no blocked register
# items spends nothing here: no ids, no call.
#
# ## Certainty, and what happens without it
#
# An id resolves only when exactly one item file's own frontmatter claims it,
# by `id` or by `legacy-id` (a block recorded before a register migration names
# the item by the id it had at the time, and that id survives as `legacy-id` —
# `docs/TECH-DEBT-REGISTER.md` in Poetic-Poems/poetic). The filename is a
# shortlist, never the answer: two files could end in the same date-and-sequence
# digits, and a block cleared off the wrong item's status is a block cleared out
# from under real work.
#
# Everything short of that certainty is simply absent from the output — an
# unreadable register, a 404, an id that matches no file or more than one, a
# file with no `status`. The caller (`lib/work-gone.sh`) treats absence as "not
# known to be gone" and leaves the item blocked, so every failure mode here
# costs a delay, never a false clearance. That is the opposite of
# `gather-findings.sh`'s degradation rule, and deliberately so: its `[]` is read
# by a Co-Ordinator that then declines, while this output is read as evidence.
#
# Never exits non-zero: it always prints a valid object. A gatherer that aborted
# the cycle would make a tidy-up a reliability risk.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"

slug="${1:-}"
branch="${2:-}"
shift 2 2>/dev/null || true
if [[ -z "$slug" || -z "$branch" ]]; then
  echo "usage: gather-register-status.sh <owner/repo> <default-branch> <id> [<id>…]" >&2
  printf '{}'
  exit 0
fi
if (( $# == 0 )); then
  printf '{}'
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The listing, and the one place a missing register is normal rather than a
# fault: a repo may keep no `tech-debt/` directory at all. A 404 is that answer
# and is silent; anything else — auth, rate limit, network — is diagnosed on
# stderr, where agent-cycle.sh captures it per cycle. Both print `{}`; only one
# of them says nothing.
listing="$(gh api "repos/$slug/contents/tech-debt?ref=$branch" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  if [[ "$(jq -r '.status // ""' <<<"$listing" 2>/dev/null)" != "404" ]]; then
    cat "$work/gh.err" >&2
  fi
  printf '{}'
  exit 0
fi

names="$(jq -r '[.[]? | select(.type == "file" and (.name | endswith(".md"))) | .name] | .[]' \
  <<<"$listing" 2>/dev/null || true)"
if [[ -z "$names" ]]; then
  printf '{}'
  exit 0
fi

# item_frontmatter — read an item file on stdin, print the item's `id`,
# `legacy-id` and `status`, one per line, empty when the file does not carry
# them. The shape `scripts/td-check.pl` and `scripts/get-tech-debt-record.pl`
# parse: a leading `---`, `key: value` lines with the key case-folded, a closing
# `---`. Anything else prints three empty lines, which resolve nothing.
#
# One field per line, not one tab-separated line: tab is IFS whitespace, so a
# `read` over "id<TAB><TAB>status" collapses the empty middle field and shifts
# the status into `legacy-id` — which is every item file that has never been
# renamed, i.e. most of them.
item_frontmatter() {
  awk '
    NR == 1              { if ($0 !~ /^---[ \t\r]*$/) exit; next }
    /^---[ \t\r]*$/      { exit }
    /^[A-Za-z][A-Za-z-]*:/ {
      key = tolower(substr($0, 1, index($0, ":") - 1))
      val = substr($0, index($0, ":") + 1)
      gsub(/\t/, " ", val); sub(/^[ ]+/, "", val); sub(/[ \r]+$/, "", val)
      if      (key == "id")        id     = val
      else if (key == "legacy-id") legacy = val
      else if (key == "status")    status = val
    }
    END { printf "%s\n%s\n%s\n", id, legacy, status }
  '
}

out="{}"
for id in "$@"; do
  [[ -n "$id" ]] || continue
  # The shortlist: the file named for the id exactly, or — for a legacy id —
  # any file whose name ends in the same digits. Each is then confirmed (or
  # not) by its own frontmatter below.
  suffix="${id##*[!0-9]}"
  status=""
  matches=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$name" != "$id.md" && "$name" != *"-$suffix.md" ]]; then
      continue
    fi
    blob="$(gh api "repos/$slug/contents/tech-debt/$name?ref=$branch" --jq '.content' 2>/dev/null \
            | tr -d '\n' | base64 -d 2>/dev/null || true)"
    [[ -n "$blob" ]] || continue
    { read -r file_id; read -r file_legacy; read -r file_status; } \
      < <(printf '%s\n' "$blob" | item_frontmatter)
    if [[ "$file_id" == "$id" || "$file_legacy" == "$id" ]]; then
      matches=$(( matches + 1 ))
      status="$file_status"
    fi
  done <<< "$names"
  # Exactly one claimant, and it said something. Two files claiming one id is a
  # register that disagrees with itself — `register-hygiene` repairs that, and
  # until it does, this reports nothing rather than picking one.
  if (( matches == 1 )) && [[ -n "$status" ]]; then
    out="$(jq -c --arg k "$id" --arg v "$status" '. + {($k): $v}' <<<"$out" 2>/dev/null || printf '%s' "$out")"
  fi
done

printf '%s' "$out"
