#!/usr/bin/env bash
#
# scripts/render-config-table.sh — render the configuration-key table rows
# that README.md, docs/IMPLEMENTATION-PIPELINE-SPEC.md and
# docs/REVIEW-PIPELINE-SPEC.md carry, from config.schema.json.
#
# Every configuration key used to be written down three times: the README's
# table, the owning spec's table, and the schema (#195) — so a key could be
# added to the schema and forgotten in either prose copy (#198). This script
# makes the schema the single source: each leaf key's `x-docs.readme` and
# `x-docs.spec` are the two documents' own prose (they are not
# interchangeable — the spec's cites requirement numbers and test-only env
# overrides, the README's cites README anchors and is addressed to someone
# installing), and `x-docs.value` — when present — is the verbatim value
# cell. `x-docs.value` is either one string for both documents, or an object
# keyed `readme`/`spec` for the keys whose two tables say different things
# there (the spec's `Value` column carries the unit — `4 h`, `15 min` — that
# the README's `Default` column leaves to the key's name and its notes), and
# an audience absent from that object falls through as if the key had no
# `x-docs.value` at all. Falling through renders the schema `default` — a
# non-empty string bare in backticks, so a label reads `unvoided` rather than
# `"unvoided"` beside the two dozen rows whose value comes from
# `x-docs.value`; anything else as compact JSON in backticks — and a key with
# no `default` either renders `*(required)*`. A key entirely absent from
# `x-docs` falls back to its plain `description`.
#
# Row order is the schema's own property order (`jq`'s `keys_unsorted`), so
# reordering a table means reordering the schema. `schedule` and `review` are
# the two object-valued properties whose own children are rendered instead of
# themselves, one level deep, as dotted keys (`schedule.review_hour`,
# `review.model`) in the parent's position — everything else (`repos`,
# `prompt_overrides`) renders as a single row.
#
# Four marked regions hold the generated body rows — header and delimiter
# lines stay outside the markers, which is what lets the README say `Default`
# and the specs say `Value` without this script knowing either, and both
# modes refuse a region that has swallowed its delimiter row:
#
#   README.md                              id=main, id=review
#   docs/IMPLEMENTATION-PIPELINE-SPEC.md   id=main
#   docs/REVIEW-PIPELINE-SPEC.md           id=review
#
#   <!-- config-table:start id=main -->
#   ...generated rows...
#   <!-- config-table:end -->
#
# With no arguments, every region is rewritten in place. `--check` renders
# each region to a temporary file instead and exits non-zero — naming the
# file, the region and the first differing key — the moment any region is
# stale; this is what `.github/workflows/config-table.yml` runs on every pull
# request, the same way `.github/workflows/tech-debt-register.yml` gates the
# tech-debt register.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

schema_file="config.schema.json"

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

if ! command -v jq >/dev/null 2>&1; then
  echo "render-config-table: jq is required" >&2
  exit 1
fi

# file:region-id:audience — audience picks which x-docs field (and which
# schema description fallback) a region renders.
regions=(
  "README.md:main:readme"
  "README.md:review:readme"
  "docs/IMPLEMENTATION-PIPELINE-SPEC.md:main:spec"
  "docs/REVIEW-PIPELINE-SPEC.md:review:spec"
)

# shellcheck disable=SC2016 # backticks here are literal Markdown, not command substitution
jq_program='
def esc_pipes: gsub("\\|"; "\\|");

def flatten_region($region):
  if $region == "main" then
    (.properties | to_entries[] | select(.key != "review")) as $e |
    if $e.key == "schedule" then
      ($e.value.properties | to_entries[] | {key: ("schedule." + .key), node: .value})
    else
      {key: $e.key, node: $e.value}
    end
  else
    (.properties.review.properties | to_entries[] | {key: ("review." + .key), node: .value})
  end;

def notes_for($audience):
  (.node["x-docs"][$audience]?) as $d |
  (if $d == null then .node.description
   elif ($d | type) == "array" then ($d | join(" "))
   else $d end);

def value_for($audience):
  (.node["x-docs"].value?) as $v |
  (if ($v | type) == "object" then $v[$audience] else $v end) as $value |
  (if $value != null then $value
   elif (.node.default? != null) then
     (.node.default as $d |
      if ($d | type) == "string" and $d != "" then ("`" + $d + "`")
      else ("`" + ($d | tojson) + "`") end)
   else "*(required)*" end);

[ flatten_region($region) ]
| map(
    "| `" + .key + "` | " + (. | value_for($audience)) + " | "
    + (({node: .node} | notes_for($audience)) | esc_pipes) + " |"
  )
| .[]
'

render_region() {
  local region="$1" audience="$2"
  jq -r --arg region "$region" --arg audience "$audience" "$jq_program" "$schema_file"
}

start_marker() { printf '<!-- config-table:start id=%s -->' "$1"; }
end_marker() { printf '<!-- config-table:end -->'; }

# Prints the lines strictly between the start-id marker and the next end
# marker (exclusive of both), or nothing (and a non-zero return) if either
# marker is missing.
extract_region() {
  local file="$1" id="$2"
  awk -v start="$(start_marker "$id")" -v end="$(end_marker)" '
    $0 == start { found=1; next }
    found && $0 == end { printed=1; exit }
    found { print }
    END { exit(printed ? 0 : 1) }
  ' "$file"
}

# True when the line immediately above the start-id marker is a Markdown
# table delimiter row. Each document keeps its own header and `|---|---|---|`
# *outside* the markers — that is what lets the README say `Default` where
# the specs say `Value` without this script knowing either — and a region
# whose delimiter row was swallowed by the marker stops being a table at all
# on GitHub, silently, since every generated row still looks right in the
# diff. Cheap to assert, so assert it.
delimiter_above() {
  local file="$1" id="$2"
  awk -v start="$(start_marker "$id")" '
    $0 == start { found=1; ok = (prev ~ /^\|[-| :]+\|$/); exit }
    { prev = $0 }
    END { exit((found && ok) ? 0 : 1) }
  ' "$file"
}

# Replaces the lines strictly between the start-id marker and the next end
# marker with the content of $content_file, in place.
replace_region() {
  local file="$1" id="$2" content_file="$3"
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v start="$(start_marker "$id")" -v end="$(end_marker)" -v contentfile="$content_file" '
    $0 == start {
      print
      while ((getline line < contentfile) > 0) print line
      close(contentfile)
      found=1
      next
    }
    found && $0 == end { found=0 }
    !found || $0 == end { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

first_differing_key() {
  # $1 old content file, $2 new content file. diff's own exit status (1 for
  # "files differ", which is exactly why we are here) must not be mistaken
  # for a pipeline failure under `set -o pipefail`, hence the `|| true`.
  local key
  # shellcheck disable=SC2016  # the backtick in the grep/sed patterns is a literal Markdown backtick, not a shell one.
  key="$( { { diff -u "$1" "$2" 2>/dev/null || true; } \
    | grep -m1 -E '^[+-]\| `' \
    | sed -E 's/^.\| `([^`]+)`.*/\1/'; } || true )"
  printf '%s' "${key:-(unknown)}"
}

stale=0

for spec in "${regions[@]}"; do
  IFS=: read -r file id audience <<<"$spec"
  if [[ ! -f "$file" ]]; then
    echo "render-config-table: $file does not exist" >&2
    exit 1
  fi

  old_content="$(mktemp)"
  if ! extract_region "$file" "$id" > "$old_content"; then
    echo "render-config-table: $file has no config-table region id=$id" >&2
    rm -f "$old_content"
    exit 1
  fi
  if ! delimiter_above "$file" "$id"; then
    echo "render-config-table: $file region id=$id is not preceded by a table delimiter row (\`|---|---|---|\`), so the table does not render" >&2
    rm -f "$old_content"
    exit 1
  fi

  new_content="$(mktemp)"
  render_region "$id" "$audience" > "$new_content"

  if (( check_mode )); then
    if ! diff -q "$old_content" "$new_content" >/dev/null; then
      key="$(first_differing_key "$old_content" "$new_content")"
      echo "render-config-table: $file region id=$id is stale (first differing key: \`$key\`) — regenerated rows in $new_content" >&2
      stale=1
    else
      rm -f "$new_content"
    fi
  else
    replace_region "$file" "$id" "$new_content"
    rm -f "$new_content"
  fi
  rm -f "$old_content"
done

if (( check_mode )); then
  if (( stale )); then
    exit 1
  fi
  echo "render-config-table: all regions match config.schema.json"
fi
