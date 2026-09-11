#!/usr/bin/env bash
#
# scripts/render-toc.sh — render the table of contents for README.md and
# docs/IMPLEMENTATION-PIPELINE-SPEC.md between marker regions.
#
# Extracts `##` and `###` headings from markdown files (ignoring the top-level
# `# ` title, code blocks, and anything inside fenced code), generates a nested
# markdown bullet list with links using GitHub's auto-generated anchor slugging,
# and writes/checks the list between `<!-- toc:start -->` / `<!-- toc:end -->`
# marker pairs placed immediately after each document's title and any lead-in
# paragraph, before the first `##` heading.
#
# With no arguments, regenerate the ToC in both files. `--check` verifies that
# both files' regions are current (exit non-zero if stale), mirroring
# render-config-table.sh's contract.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

usage() {
  echo "usage: $(basename "$0") [--check]" >&2
  exit 2
}

check_mode=0
case "${1:-}" in
  --check) check_mode=1; shift ;;
  "") ;;
  *) usage ;;
esac
if (( $# > 0 )); then
  usage
fi

# GitHub's own heading-anchor slug: lower-case, strip anything that is not
# alphanumeric/underscore/hyphen/space, spaces to hyphens. GitHub does not
# collapse consecutive hyphens: a removed character leaves both its
# neighbouring spaces behind, each becoming its own hyphen.
gh_slug() {
  local text="$1"
  text=$(echo "$text" | tr '[:upper:]' '[:lower:]')
  text="${text//[^a-z0-9 _-]/}"
  text="${text// /-}"
  echo "$text"
}

# Extract headings from a file: lines starting with ## or ###, skipping anything
# inside fenced code blocks (``` or ~~~). Outputs "level heading_text" for each.
extract_headings() {
  local file="$1"
  local in_code=0
  local fence_marker=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Detect code fence start/end (``` or ~~~)
    if [[ "$line" == \`\`\`* ]] || [[ "$line" == \~\~\~* ]]; then
      if [[ -z "$fence_marker" ]]; then
        fence_marker=$(echo "$line" | cut -c1-3)
        in_code=1
      elif [[ "$line" == "$fence_marker"* ]]; then
        in_code=0
        fence_marker=""
      fi
      continue
    fi

    if (( in_code )); then
      continue
    fi

    # Extract headings: ## (level 2) or ### (level 3), skip #
    if [[ "$line" == "### "* ]]; then
      local heading="${line#\#\#\# }"
      echo "3 $heading"
    elif [[ "$line" == "## "* ]]; then
      local heading="${line#\#\# }"
      echo "2 $heading"
    fi
  done < "$file"
}

# Generate ToC markdown from extracted headings. Anchors are de-duplicated
# across the whole document, in heading order, the same way GitHub's own
# renderer de-duplicates repeated headings: the first occurrence of a slug
# keeps it bare, every later occurrence gets -1, -2, ... appended.
generate_toc() {
  local -A seen=()
  while read -r level heading; do
    local indent=""
    if (( level == 3 )); then
      indent="  "
    fi
    local anchor
    anchor=$(gh_slug "$heading")
    if [[ -n "${seen[$anchor]+x}" ]]; then
      seen[$anchor]=$(( seen[$anchor] + 1 ))
      anchor="${anchor}-${seen[$anchor]}"
    else
      seen[$anchor]=0
    fi
    echo "${indent}- [$heading](#$anchor)"
  done
}

# True when a file contains exactly one <!-- toc:start --> and exactly one
# <!-- toc:end --> marker, with the start marker on an earlier line than the
# end marker. A file with neither, only one of the pair, or more than one of
# either has no well-formed region to render into — the awk pass below would
# otherwise copy such a file through unchanged, making regeneration a silent
# no-op and --check a false pass. A file with exactly one of each but in
# reversed order is just as malformed: the awk pass below only recognises a
# toc:end line reached *after* a toc:start line, so a reversed pair would
# have it consume every line to the end of the file looking for one,
# silently discarding whatever lay between the markers.
markers_ok() {
  local file="$1"
  local start_count end_count
  start_count=$(grep -c '^<!-- toc:start -->$' "$file" || true)
  end_count=$(grep -c '^<!-- toc:end -->$' "$file" || true)
  if (( start_count != 1 || end_count != 1 )); then
    return 1
  fi
  local start_line end_line
  start_line=$(grep -n '^<!-- toc:start -->$' "$file" | cut -d: -f1)
  end_line=$(grep -n '^<!-- toc:end -->$' "$file" | cut -d: -f1)
  (( start_line < end_line ))
}

# Render ToC for a file between markers
render_file() {
  local file="$1"
  local temp_file="${file}.toc.tmp"

  if ! markers_ok "$file"; then
    echo "render-toc: $file does not contain exactly one <!-- toc:start --> / <!-- toc:end --> marker pair" >&2
    return 1
  fi

  # Extract headings and generate ToC
  local toc_content
  toc_content=$(extract_headings "$file" | generate_toc)

  # Use awk to replace content between markers
  # This is more robust than sed for multiline replacements
  awk -v toc="$toc_content" '
    /^<!-- toc:start -->/ {
      print "<!-- toc:start -->"
      print toc
      while (getline && !/^<!-- toc:end -->/) {}
      print "<!-- toc:end -->"
      next
    }
    { print }
  ' "$file" > "$temp_file"

  if (( check_mode )); then
    if ! diff -q "$file" "$temp_file" >/dev/null 2>&1; then
      echo "render-toc: $file is stale" >&2
      rm "$temp_file"
      return 1
    fi
    rm "$temp_file"
  else
    mv "$temp_file" "$file"
  fi

  return 0
}

files=(
  "README.md"
  "docs/IMPLEMENTATION-PIPELINE-SPEC.md"
)

failed=0
for file in "${files[@]}"; do
  if ! render_file "$file"; then
    failed=1
  fi
done

if (( failed )); then
  exit 1
fi
