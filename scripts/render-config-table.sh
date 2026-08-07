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
# `x-docs.readme`/`x-docs.spec` (a key's notes, not its value) is a plain
# string, or an array of *blocks* (#220): a plain string element is its own
# paragraph; `{"list": [...]}` is an unordered list, each item a string; and
# `{"code": "...", "lang": "..."}` (`lang` optional) is a fenced code example.
# Two renderings of the same blocks exist because a table cell and a
# generated `### Extended notes` subsection (below) can hold different
# things: a cell is one line, so every block flattens into it — a paragraph
# verbatim, a list's items joined `, `, code's newlines turned to spaces and
# wrapped in a backtick span — with a single space between blocks, the same
# join a plain array of paragraph strings always got; the Extended notes
# subsection is ordinary document prose, so blocks render as real block
# Markdown there instead — a blank line between paragraphs, a real `- `
# list, a real fenced ```` ``` ```` block — one blank line between each pair
# of blocks. A plain string (no array) is exactly a one-block array, in
# either rendering, which is why every existing single-string and
# single-paragraph-array note renders unchanged.
#
# Row order is the schema's own property order (`jq`'s `keys_unsorted`), so
# reordering a table means reordering the schema. `schedule` and `review` are
# the two object-valued properties whose own children are rendered instead of
# themselves, one level deep, as dotted keys (`schedule.review_hour`,
# `review.model`) in the parent's position — everything else (`repos`,
# `prompt_overrides`) renders as a single row.
#
# Four marked regions hold the whole table — header row, `|---|---|---|`
# delimiter row, then the generated body rows:
#
#   README.md                              id=main, id=review
#   docs/IMPLEMENTATION-PIPELINE-SPEC.md   id=main
#   docs/REVIEW-PIPELINE-SPEC.md           id=review
#
#   <!-- config-table:start id=main -->
#   | Key | Default | Notes |
#   |---|---|---|
#   ...generated rows...
#   <!-- config-table:end -->
#
# The header and delimiter — the region's first two lines — are preserved
# verbatim rather than generated, which is what lets the README say `Default`
# and the specs say `Value` without this script knowing either. They live
# *inside* the markers rather than above the start marker: a bare HTML
# comment line between the delimiter row and the first data row has no pipe
# in it, so it does not look like a table row, and GitHub's Markdown parser
# ends the table right there — the delimiter row renders with an empty body
# and every generated row below it falls through as literal piped text. That
# is not hypothetical; it is what this file's own `id=main` region did until
# the marker moved. Wrapping the header and delimiter in the markers keeps
# every line of the table contiguous, which is what a table requires, while
# the marker comments themselves sit safely outside the contiguous run — one
# line before the header, one line after the last generated row. Both modes
# refuse a region whose first two lines are not a header row and a
# `|---|---|---|` delimiter row.
#
# A Notes cell longer than 500 characters (`NOTES_CAP` in the jq program
# below) is capped: the cell carries a truncated prefix — at most 480
# characters, tokenised into Markdown atoms (a code span, a link, an
# emphasis run, whitespace or a plain word) and cut at the last atom
# boundary that fits, never inside one of those constructs — followed by
# `...[continued below](#extended-notes-<slug>)`, and the note's full text
# is repeated below the table in that document's `config-table:notes`
# region, under a generated `Extended notes: `<key>`` heading. One notes
# region sits beside each table region above, matched by `id`, and renders
# empty when every note in that region fits:
#
#   <!-- config-table:notes id=main -->
#
#   ### Extended notes: `repos`
#
#   ...full note...
#
#   <!-- config-table:notes-end -->
#
# The notes markers are placed by hand, wherever the section reads best in
# the surrounding prose — this script rewrites what sits between them and
# never moves them — and each heading's level is derived, not hard-coded:
# the nearest ATX heading above the start marker, plus one, clamped at 6:
# missing that heading is a hard failure. The anchor is GitHub's own slug for
# that heading (lower-cased, stripped to `[a-z0-9_-]`/space, spaces turned
# to `-`); two headings in one document slugging the same is also a hard
# failure, asserted rather than handled, since the current key sets make it
# impossible. Pipes are not escaped in the notes region — `esc_pipes` exists
# for table cells, where a raw `|` would end one; outside the table an
# escaped pipe would render as a literal `\|`.
#
# With no arguments, every region — table and notes alike — is rewritten in
# place. `--check` renders each region to a temporary file instead and exits
# non-zero — naming the file, the region and the first differing key — the
# moment any region is stale; this is what `.github/workflows/config-table.yml`
# runs on every pull request, the same way `.github/workflows/tech-debt-register.yml`
# gates the tech-debt register.

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
def NOTES_CAP: 500;
def CONTINUATION_TEXT: "...[continued below]";
def PREFIX_BUDGET: NOTES_CAP - (CONTINUATION_TEXT | length);

def esc_pipes: gsub("\\|"; "\\|");

# GitHub'"'"'s own heading-anchor slug: lower-case, strip anything that is not
# alphanumeric/underscore/hyphen/space, spaces to hyphens.
def gh_slug: ascii_downcase | gsub("[^a-z0-9_\\- ]"; "") | gsub(" "; "-");

def slug_for($key): "extended-notes-" + ($key | gh_slug);

# A note tokenised into the atoms a truncation cut must never fall inside:
# a code span, a link (text and target together), an emphasis run (`**`,
# `__`, `*` or `_`), a whitespace run, or a plain word — matched in that
# order, since a code span must be claimed before a link or emphasis run
# mistakes its contents for their own syntax.
def atomize:
  [scan("`[^`]*`|\\[[^\\]]*\\]\\([^)]*\\)|\\*\\*[^*]+\\*\\*|__[^_]+__|\\*[^*]+\\*|_[^_]+_|\\s+|\\S+")];

# The longest run of leading atoms whose combined length is at most
# PREFIX_BUDGET, with a trailing whitespace run and then one trailing
# `,`/`;`/`:` dropped. Falls back to the note'"'"'s very first atom when even
# that alone exceeds the budget, so the prefix is never empty.
def truncated_prefix:
  . as $note
  | atomize as $atoms
  | (reduce $atoms[] as $a
       ({acc: "", done: false};
        if .done then .
        elif (((.acc | length) + ($a | length)) > PREFIX_BUDGET) then (.done = true)
        else (.acc += $a) end)
    ).acc as $acc
  | (if ($acc == "" and ($atoms | length) > 0) then $atoms[0] else $acc end)
  | sub("[ \t]+$"; "")
  | if test("[,;:]$") then .[0:-1] else . end;

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

# A note block flattened to the one line a table cell can hold: a paragraph
# string verbatim, a list'"'"'s items joined `, `, code'"'"'s newlines turned to
# spaces and wrapped in a backtick span.
def block_flat:
  if (type) == "string" then .
  elif (type) == "object" and (has("list")) then (.list | join(", "))
  elif (type) == "object" and (has("code")) then ("`" + (.code | gsub("\n"; " ")) + "`")
  else error("render-config-table: unrecognised note block: " + (tojson))
  end;

# The same block rendered as real block Markdown, for the Extended notes
# subsection: a paragraph string verbatim, a list as `- ` items, code as a
# fenced block.
def block_md:
  if (type) == "string" then .
  elif (type) == "object" and (has("list")) then (.list | map("- " + .) | join("\n"))
  elif (type) == "object" and (has("code")) then ("```" + (.lang // "") + "\n" + .code + "\n```")
  else error("render-config-table: unrecognised note block: " + (tojson))
  end;

# A plain string/object counts as a single-block array; an already-array
# x-docs value is one block per element (#220).
def blocks_of($d): if ($d | type) == "array" then $d else [$d] end;

def notes_for($audience):
  (.node["x-docs"][$audience]?) as $d |
  (if $d == null then [.node.description] else blocks_of($d) end) as $blocks |
  {
    flat: ($blocks | map(block_flat) | join(" ")),
    block: ($blocks | map(block_md) | join("\n\n"))
  };

def value_for($audience):
  (.node["x-docs"].value?) as $v |
  (if ($v | type) == "object" then $v[$audience] else $v end) as $value |
  (if $value != null then $value
   elif (.node.default? != null) then
     (.node.default as $d |
      if ($d | type) == "string" and $d != "" then ("`" + $d + "`")
      else ("`" + ($d | tojson) + "`") end)
   else "*(required)*" end);

[ flatten_region($region) ] as $entries |
($entries | map(. + {note: (. | notes_for($audience))})) as $with_notes |
($with_notes | map(select((.note.flat | length) > NOTES_CAP))) as $overlong |
{
  rows: ($with_notes | map(
    . as $e |
    ($e | value_for($audience)) as $val |
    (if ($e.note.flat | length) <= NOTES_CAP then
       ($e.note.flat | esc_pipes)
     else
       (($e.note.flat | truncated_prefix | esc_pipes)
        + CONTINUATION_TEXT + "(#" + slug_for($e.key) + ")")
     end) as $notes_cell |
    "| `" + $e.key + "` | " + $val + " | " + $notes_cell + " |"
  )),
  notes: (
    ($overlong | map(["#" * $level + " Extended notes: `" + .key + "`", "", .note.block])) as $blocks |
    if ($blocks | length) == 0 then []
    else
      [""] + (
        reduce range(0; ($blocks | length)) as $i
          ([]; . + (if $i > 0 then [""] else [] end) + $blocks[$i])
      ) + [""]
    end
  ),
  slugs: ($overlong | map(slug_for(.key)))
}
'

render_region_json() {
  local region="$1" audience="$2" level="$3"
  jq -c --arg region "$region" --arg audience "$audience" --argjson level "$level" "$jq_program" "$schema_file"
}

start_marker() { printf '<!-- config-table:start id=%s -->' "$1"; }
end_marker() { printf '<!-- config-table:end -->'; }
notes_start_marker() { printf '<!-- config-table:notes id=%s -->' "$1"; }
notes_end_marker() { printf '<!-- config-table:notes-end -->'; }

# Prints the region's generated body rows — the lines strictly between the
# start-id marker and the next end marker, minus the header and delimiter
# rows that occupy the first two of them — or nothing (and a non-zero
# return) if either marker is missing.
extract_body() {
  local file="$1" id="$2"
  awk -v start="$(start_marker "$id")" -v end="$(end_marker)" '
    $0 == start { found=1; n=0; next }
    found && $0 == end { printed=1; exit }
    found {
      n++
      if (n <= 2) next
      print
    }
    END { exit(printed ? 0 : 1) }
  ' "$file"
}

# True when the region's first two lines, immediately after the start-id
# marker, are a Markdown table header row and a `|---|---|---|` delimiter
# row. A region whose header or delimiter row is missing — or was pushed
# below the start marker so a bare comment line sits between the delimiter
# and the first data row — stops being a table at all on GitHub, silently,
# since every generated row still looks right in the diff. Cheap to assert,
# so assert it.
header_delimiter_ok() {
  local file="$1" id="$2"
  awk -v start="$(start_marker "$id")" '
    $0 == start { found=1; n=0; next }
    found {
      n++
      if (n == 1) { header_ok = ($0 ~ /\|/) }
      else if (n == 2) { delim_ok = ($0 ~ /^\|[-| :]+\|$/); exit }
    }
    END { exit((n >= 2 && header_ok && delim_ok) ? 0 : 1) }
  ' "$file"
}

# Replaces the generated body rows — the lines strictly between the region's
# header/delimiter and the end marker — with the content of $content_file,
# in place. The header and delimiter rows themselves (the first two lines
# after the start-id marker) pass through untouched.
replace_body() {
  local file="$1" id="$2" content_file="$3"
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v start="$(start_marker "$id")" -v end="$(end_marker)" -v contentfile="$content_file" '
    $0 == start { print; inregion=1; n=0; next }
    inregion && $0 == end {
      while ((getline line < contentfile) > 0) print line
      close(contentfile)
      inregion=0
      print
      next
    }
    inregion {
      n++
      if (n <= 2) { print; next }
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Prints the notes region's current content — every line strictly between
# the notes-start and notes-end markers — or nothing (and a non-zero
# return) if either marker is missing. Unlike extract_body there is no
# header/delimiter to skip: the whole region is generated.
extract_notes_body() {
  local file="$1" id="$2"
  awk -v start="$(notes_start_marker "$id")" -v end="$(notes_end_marker)" '
    $0 == start { found=1; next }
    found && $0 == end { printed=1; exit }
    found { print }
    END { exit(printed ? 0 : 1) }
  ' "$file"
}

# Prints the derived heading level for the notes region — the nearest ATX
# heading strictly above the notes-start marker, plus one, clamped at 6 —
# or nothing (and a non-zero return) if the marker is missing or no heading
# precedes it.
notes_heading_level() {
  local file="$1" id="$2"
  awk -v start="$(notes_start_marker "$id")" '
    match($0, /^#+ /) { level = RLENGTH - 1; have_level = 1 }
    $0 == start {
      if (have_level) { print (level + 1 > 6 ? 6 : level + 1); found = 1 }
      exit
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

# Replaces the whole notes region — every line strictly between the
# notes-start and notes-end markers — with the content of $content_file,
# in place.
replace_notes_body() {
  local file="$1" id="$2" content_file="$3"
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v start="$(notes_start_marker "$id")" -v end="$(notes_end_marker)" -v contentfile="$content_file" '
    $0 == start { print; inregion=1; next }
    inregion && $0 == end {
      while ((getline line < contentfile) > 0) print line
      close(contentfile)
      inregion=0
      print
      next
    }
    inregion { next }
    { print }
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

first_differing_notes_key() {
  # As first_differing_key, but for the notes region's generated headings.
  local key
  # shellcheck disable=SC2016  # the backtick in the grep/sed patterns is a literal Markdown backtick, not a shell one.
  key="$( { { diff -u "$1" "$2" 2>/dev/null || true; } \
    | grep -m1 -E '^[+-]#+ Extended notes: `' \
    | sed -E 's/^.#+ Extended notes: `([^`]+)`.*/\1/'; } || true )"
  printf '%s' "${key:-(unknown)}"
}

stale=0
declare -A seen_slugs

for spec in "${regions[@]}"; do
  IFS=: read -r file id audience <<<"$spec"
  if [[ ! -f "$file" ]]; then
    echo "render-config-table: $file does not exist" >&2
    exit 1
  fi

  old_content="$(mktemp)"
  if ! extract_body "$file" "$id" > "$old_content"; then
    echo "render-config-table: $file has no config-table region id=$id" >&2
    rm -f "$old_content"
    exit 1
  fi
  if ! header_delimiter_ok "$file" "$id"; then
    echo "render-config-table: $file region id=$id does not open with a header row and a \`|---|---|---|\` delimiter row, so the table does not render" >&2
    rm -f "$old_content"
    exit 1
  fi

  old_notes_content="$(mktemp)"
  if ! extract_notes_body "$file" "$id" > "$old_notes_content"; then
    echo "render-config-table: $file has no config-table:notes region id=$id" >&2
    rm -f "$old_content" "$old_notes_content"
    exit 1
  fi
  if ! level="$(notes_heading_level "$file" "$id")"; then
    echo "render-config-table: $file region id=$id: no heading precedes the config-table:notes start marker" >&2
    rm -f "$old_content" "$old_notes_content"
    exit 1
  fi

  region_json="$(render_region_json "$id" "$audience" "$level")"

  while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue
    slug_key="$file:$slug"
    if [[ -n "${seen_slugs[$slug_key]:-}" ]]; then
      echo "render-config-table: $file: Extended notes heading for region id=$id slugs to #$slug, already used by region id=${seen_slugs[$slug_key]}" >&2
      rm -f "$old_content" "$old_notes_content"
      exit 1
    fi
    seen_slugs["$slug_key"]="$id"
  done < <(jq -r '.slugs[]' <<<"$region_json")

  new_content="$(mktemp)"
  jq -r '.rows[]' <<<"$region_json" > "$new_content"
  new_notes_content="$(mktemp)"
  jq -r '.notes[]' <<<"$region_json" > "$new_notes_content"

  if (( check_mode )); then
    if ! diff -q "$old_content" "$new_content" >/dev/null; then
      key="$(first_differing_key "$old_content" "$new_content")"
      echo "render-config-table: $file region id=$id is stale (first differing key: \`$key\`) — regenerated rows in $new_content" >&2
      stale=1
    else
      rm -f "$new_content"
    fi
    if ! diff -q "$old_notes_content" "$new_notes_content" >/dev/null; then
      key="$(first_differing_notes_key "$old_notes_content" "$new_notes_content")"
      echo "render-config-table: $file region id=$id Extended notes are stale (first differing key: \`$key\`) — regenerated notes in $new_notes_content" >&2
      stale=1
    else
      rm -f "$new_notes_content"
    fi
  else
    replace_body "$file" "$id" "$new_content"
    rm -f "$new_content"
    replace_notes_body "$file" "$id" "$new_notes_content"
    rm -f "$new_notes_content"
  fi
  rm -f "$old_content" "$old_notes_content"
done

if (( check_mode )); then
  if (( stale )); then
    exit 1
  fi
  echo "render-config-table: all regions match config.schema.json"
fi
