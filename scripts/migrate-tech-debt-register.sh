#!/usr/bin/env bash
#
# migrate-tech-debt-register.sh <owner/repo> [--dry-run]
#
# One-off (but re-runnable) migration off the per-item tech-debt register
# (D15 as revised, agent-ops#869/#875/#880): for every `tech-debt/<id>.md`
# record in the working tree whose `status:` is `open` or `in-progress`,
# create a GitHub issue carrying the record's title and body, labelled
# `pw::type:tech-debt` — the label the band now selects on
# (scripts/gather-tech-debt.sh) — then append a `Migrated to <issue url>.`
# line to the record's body in the working tree.
#
# Run it against a checkout of the branch you intend to migrate (ordinarily
# a fresh checkout of `origin/main`, matching scripts/find-similar-tech-debt.sh's
# own convention of reading the working tree rather than forcing a ref): this
# script never fetches or checks out anything itself, and never commits,
# pushes, or opens a pull request — the caller does that, exactly as it would
# for any other change to tech-debt/*.md.
#
# `status:` is deliberately left untouched, so `scripts/td-check.pl` still
# passes and the append-only body rule
# (scripts/check-tech-debt-open-rewrites.pl) is satisfied: the appended text
# always lands strictly after the record's existing bytes, never rewriting
# them.
#
# Idempotent: a record whose body already contains a `Migrated to ` line is
# left alone — no issue, no further append — so re-running this script
# against a working tree that already carries a prior run's appends (in the
# same checkout, or a later one after that run's PR merged) is a no-op.
#
# --dry-run prints, for each record that would be migrated, the id and the
# issue title/body that would be created, without calling `gh issue create`
# or touching any file. Use it to review the batch before spending real
# GitHub issues on it — this script has no way to undo an issue it created.
#
# The release of stale `td/<id>` reservation branches that rode alongside
# this migration (agent-ops#880) is a separate, one-off repository operation
# on git refs, not a per-record content transform, so it is not this
# script's job.

set -uo pipefail

usage() {
  echo "usage: migrate-tech-debt-register.sh <owner/repo> [--dry-run]" >&2
  exit 64
}

slug=""
dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -*) usage ;;
    *)
      [[ -z "$slug" ]] || usage
      slug="$arg"
      ;;
  esac
done
[[ -n "$slug" ]] || usage

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "migrate-tech-debt-register: not inside a git checkout" >&2
  exit 1
}
register_dir="$repo_root/tech-debt"
[[ -d "$register_dir" ]] || {
  echo "migrate-tech-debt-register: no tech-debt/ directory in this checkout" >&2
  exit 1
}

# record_frontmatter — read a record file on stdin, print its `id`, `title`
# (YAML-unquoted), `status`, `filed` and `review`, one per line, empty when
# absent. Same key-per-line convention as scripts/gather-register-status.sh's
# item_frontmatter, for the same reason: a tab in IFS would otherwise
# collapse an empty middle field into its neighbour.
record_frontmatter() {
  awk '
    NR == 1                { if ($0 !~ /^---[ \t\r]*$/) exit; next }
    /^---[ \t\r]*$/        { exit }
    /^[A-Za-z][A-Za-z-]*:/ {
      key = tolower(substr($0, 1, index($0, ":") - 1))
      val = substr($0, index($0, ":") + 1)
      gsub(/\t/, " ", val); sub(/^[ ]+/, "", val); sub(/[ \r]+$/, "", val)
      if      (key == "id")     id     = val
      else if (key == "title")  title  = val
      else if (key == "status") status = val
      else if (key == "filed")  filed  = val
      else if (key == "review") review = val
    }
    END { printf "%s\n%s\n%s\n%s\n%s\n", id, title, status, filed, review }
  '
}

# unquote_title — a YAML plain scalar is printed as-is; a double-quoted one
# (used only when the title itself needs escaping from YAML's own special
# characters, e.g. a leading quote or a ": ") has its surrounding quotes
# stripped and its two-character escapes undone. No title in this register
# contains a literal backslash or double quote, so \" and \\ are the only
# escapes handled.
unquote_title() {
  local t="$1"
  if [[ "$t" == \"*\" ]]; then
    t="${t#\"}"
    t="${t%\"}"
    t="${t//\\\"/\"}"
    t="${t//\\\\/\\}"
  fi
  printf '%s' "$t"
}

# record_body <path> — the record's body: everything after the closing
# frontmatter `---`, with leading blank lines dropped (matching
# scripts/get-tech-debt-record.pl's own body extraction).
record_body() {
  awk '
    NR == 1 && /^---[ \t\r]*$/ { in_fm = 1; next }
    in_fm && /^---[ \t\r]*$/   { in_fm = 0; started = 1; next }
    in_fm                      { next }
    started {
      if (!seen && $0 ~ /^[ \t\r]*$/) next
      seen = 1
      print
    }
  ' "$1"
}

migrated=0
skipped=0
failed=0

shopt -s nullglob
for path in "$register_dir"/*.md; do
  { read -r id; read -r title_raw; read -r status; read -r filed; read -r review; } \
    < <(record_frontmatter < "$path")
  [[ -n "$id" ]] || continue
  [[ "$status" == "open" || "$status" == "in-progress" ]] || continue

  if grep -q '^Migrated to ' "$path"; then
    skipped=$(( skipped + 1 ))
    continue
  fi

  title="$(unquote_title "$title_raw")"
  body="$(record_body "$path")"

  provenance="---

Filed as \`tech-debt/$(basename "$path")\`, $filed."
  [[ -n "$review" ]] && provenance+=" Review: $review."

  issue_body="$body

$provenance"

  if (( dry_run )); then
    echo "=== would migrate $id ==="
    echo "--- title ---"
    printf '%s\n' "$title"
    echo "--- body ---"
    printf '%s\n' "$issue_body"
    echo
    migrated=$(( migrated + 1 ))
    continue
  fi

  issue_url="$(gh issue create -R "$slug" \
    --title "$title" \
    --body "$issue_body" \
    --label "pw::type:tech-debt" 2>&1)"
  if [[ $? -ne 0 || "$issue_url" != https://* ]]; then
    echo "migrate-tech-debt-register: $id: issue creation failed: $issue_url" >&2
    failed=$(( failed + 1 ))
    continue
  fi

  if [[ -s "$path" ]] && [[ "$(tail -c1 "$path")" != $'\n' ]]; then
    printf '\n' >> "$path"
  fi
  printf '\nMigrated to %s.\n' "$issue_url" >> "$path"

  echo "migrated $id -> $issue_url"
  migrated=$(( migrated + 1 ))
done

echo "migrate-tech-debt-register: migrated=$migrated skipped=$skipped failed=$failed" >&2
(( failed == 0 ))
