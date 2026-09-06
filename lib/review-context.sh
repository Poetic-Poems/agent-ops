#!/usr/bin/env bash
#
# lib/review-context.sh — per-repository instructions and context for the
# Reviewer-Agent (issue #589, D7 in docs/ROADMAP.md).
#
# The decision recorded on that issue, restated here because it is what this
# file implements: **both layered, configuration winning** — a repository's
# own resolved `review_instructions`/`review_context` (its override, or
# `project_review.defaults`', requirement 342) hold installation-supplied
# text; `repo_context_file` additionally admits one file read from the
# repository under review's own clone, but *only* as context, never as
# instruction. The reasoning is D19's: text a reviewed repository's
# contributors can edit is trustworthy only as far as a pull request into
# that repository is, so anything that changes how *strictly* a review
# judges must live in the installation's own configuration, never in the
# repository it is judging.
#
# `review_instructions`/`review_context` paths are resolved against
# `state_dir`, on the same terms as `lib/prompt-overrides.sh`'s `extend` —
# but deliberately do not share that file's tolerance for a missing path.
# `prompt_overrides` treats an unreadable configured file as absent, because
# it is guidance a stage can simply run without; these paths are read
# instead, because a silently-dropped `review_instructions` entry would look
# like a review that quietly stopped weighing what an operator configured it
# to weigh. `review_context_missing_configured` is the shared check
# review-cycle.sh (fail-fast, before the lock) and scripts/doctor.sh (a
# `fail`, not a `warn`) both call, so the two can never disagree about what
# counts as a broken path.
#
# Sourced by review-cycle.sh and scripts/doctor.sh.

# A generous bound on one source's contribution to the runtime input — large
# enough for any genuine instructions/context document, small enough that a
# runaway or mistakenly-pointed file cannot blow out the reviewer's prompt.
# Not configurable: the issue that added this facility asked for a cap and a
# truncation warning, not a tunable, and one fixed value is one fewer thing
# to get wrong in `config.json`.
REVIEW_CONTEXT_SOURCE_MAX_BYTES=20000

# review_context_resolve_path BASE RAW
# Expands a leading ~ against $HOME, then resolves a still-relative path
# against BASE. Identical in shape to lib/prompt-overrides.sh's
# resolve_prompt_override_path, kept as a separate small copy rather than a
# cross-file call: that file is product content for the implementation
# pipeline's prompt overrides (issue #79), and this facility is deliberately
# out of scope for it (issue #589's "out of scope" list) — not a dependency
# to introduce for three lines of path arithmetic. Prints nothing for an
# empty RAW.
review_context_resolve_path() {
  local base="$1" raw="$2" p
  [[ -n "$raw" ]] || return 0
  p="$raw"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  [[ "$p" == /* ]] || p="$base/$p"
  printf '%s\n' "$p"
}

# review_context_missing_configured STATE_DIR PROJECT_REVIEW_REPOS_JSON
# Prints one `slug<TAB>field<TAB>configured<TAB>resolved` line per configured
# review_instructions/review_context entry (from config_project_review_repos'
# already-resolved, requirement-342-applied output) that does not resolve to
# a readable *regular file* — a directory is readable and contributes nothing
# but an empty entry, which is exactly the silent shortfall R1c exists to
# refuse. Empty when every configured entry, across every repository,
# resolves — including the vacuous case of nobody configuring either key.
review_context_missing_configured() {
  local state_dir="$1" repos_json="$2"
  local slug field raw resolved
  while IFS=$'\t' read -r slug field raw; do
    [[ -n "$raw" ]] || continue
    resolved="$(review_context_resolve_path "$state_dir" "$raw")"
    [[ -f "$resolved" && -r "$resolved" ]] \
      || printf '%s\t%s\t%s\t%s\n' "$slug" "$field" "$raw" "$resolved"
  done < <(jq -r '
    .[] | .slug as $s |
    ((.review_instructions // [])[] | [$s, "review_instructions", .] | @tsv),
    ((.review_context // [])[] | [$s, "review_context", .] | @tsv)
  ' <<<"$repos_json" 2>/dev/null || true)
}

# _review_context_entry SOURCE ORIGIN FILE
# One {source, origin, text, truncated, bytes, digest} object for FILE,
# capped at REVIEW_CONTEXT_SOURCE_MAX_BYTES bytes. `bytes` and `digest`
# (sha256 of the text actually carried, i.e. post-truncation) describe
# exactly what review_context_sources_digest later logs; computed once here
# rather than by re-reading the text back out of the assembled JSON. Prints
# nothing for an unreadable FILE — the caller decides whether that is a
# fault (a configured path, already checked by
# review_context_missing_configured before this ever runs) or simply
# absence (repo_context_file, which is allowed to not exist).
_review_context_entry() {
  local source="$1" origin="$2" file="$3" size truncated=false bytes digest
  [[ -f "$file" && -r "$file" ]] || return 0
  size="$(wc -c < "$file" 2>/dev/null || echo 0)"
  (( size > REVIEW_CONTEXT_SOURCE_MAX_BYTES )) && truncated=true
  local capped
  capped="$(head -c "$REVIEW_CONTEXT_SOURCE_MAX_BYTES" "$file")"
  bytes="$(printf '%s' "$capped" | wc -c)"
  digest="sha256:$(printf '%s' "$capped" | sha256sum | cut -d' ' -f1)"
  jq -n --arg source "$source" --arg origin "$origin" --arg text "$capped" \
    --argjson truncated "$truncated" --argjson bytes "$bytes" --arg digest "$digest" \
    '{source: $source, origin: $origin, text: $text, truncated: $truncated, bytes: $bytes, digest: $digest}'
}

# _review_context_within_clone CLONE_DIR PATH
# True when PATH names a file whose bytes genuinely live inside CLONE_DIR:
# PATH itself is not a symlink, and the directory holding it canonicalises
# (`cd` + `pwd -P`, which resolves every symlinked component) to CLONE_DIR
# itself or something under it. `cd`/`pwd -P` rather than `realpath` because
# they are shell builtins and this repo depends on neither `realpath` nor
# `readlink -f` outside scripts/gh-shim.sh. Applies only to
# repo_context_file: the two configured keys name installation-held paths,
# which are not inside a clone at all and are checked by
# review_context_missing_configured instead.
_review_context_within_clone() {
  local clone_dir="$1" path="$2" clone_real dir_real
  [[ ! -L "$path" ]] || return 1
  clone_real="$(cd "$clone_dir" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$clone_real" ]] || return 1
  dir_real="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
  [[ -n "$dir_real" ]] || return 1
  [[ "$dir_real" == "$clone_real" || "$dir_real" == "$clone_real"/* ]]
}

# review_context_build_json STATE_DIR CLONE_DIR ENTRY_JSON
# ENTRY_JSON is one config_project_review_repos() entry (already resolved
# per requirement 342). Prints `{"instructions": [...], "context": [...]}`:
# every configured review_instructions path becomes one `instructions`
# entry (source "config"); every configured review_context path, plus
# repo_context_file when it resolves to a readable file inside CLONE_DIR,
# becomes one `context` entry (source "config" or "repository"
# respectively) — in that order, so configuration is always listed first.
# A configured path this prints nothing useful for is a fault the caller
# should already have refused to start on (review_context_missing_configured,
# run before the lock); repo_context_file simply being absent is not a fault
# at all (D7) and prints nothing for that entry alone.
review_context_build_json() {
  local state_dir="$1" clone_dir="$2" entry_json="$3"
  local raw resolved repo_context_file rp
  local instructions='[]' context='[]' one

  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue
    resolved="$(review_context_resolve_path "$state_dir" "$raw")"
    one="$(_review_context_entry config "$raw" "$resolved")" || continue
    [[ -n "$one" ]] || continue
    instructions="$(jq -c --argjson e "$one" '. + [$e]' <<<"$instructions")"
  done < <(jq -r '(.review_instructions // [])[]' <<<"$entry_json" 2>/dev/null || true)

  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue
    resolved="$(review_context_resolve_path "$state_dir" "$raw")"
    one="$(_review_context_entry config "$raw" "$resolved")" || continue
    [[ -n "$one" ]] || continue
    context="$(jq -c --argjson e "$one" '. + [$e]' <<<"$context")"
  done < <(jq -r '(.review_context // [])[]' <<<"$entry_json" 2>/dev/null || true)

  repo_context_file="$(jq -r '.repo_context_file // ""' <<<"$entry_json" 2>/dev/null || true)"
  # A repository-relative path only: `..` would let a mischievous config
  # entry (this is installation-configured, not repository-supplied, but
  # still worth bounding cheaply) walk out of the clone. Silently treated as
  # not configured, on the same "a typo does not fail a cycle" terms as an
  # absent file — repo_context_file is never a fail-fast key (D7).
  if [[ -n "$repo_context_file" && "$repo_context_file" != /* && "$repo_context_file" != *".."* ]]; then
    rp="$clone_dir/$repo_context_file"
    # …and the *bytes* must come from inside the clone too, not merely the
    # path naming them. The file at that path is under the reviewed
    # repository's own control, so a contributor can commit it as a symlink
    # — `.github/REVIEW-CONTEXT.md -> ../../../../.config/gh/hosts.yml` —
    # and both `-r` and `head -c` follow it out of the clone and into
    # whatever this process can read. That would turn D7's boundary
    # ("repository-held text is context, never instruction") into a
    # statement about the configured path rather than about the text
    # actually read, and the reader is a model whose output lands in a
    # public report in that same repository. `_review_context_within_clone`
    # is what makes the boundary a fact about the bytes; failing it is
    # treated exactly as `..` is, silently not configured.
    if _review_context_within_clone "$clone_dir" "$rp"; then
      one="$(_review_context_entry repository "$repo_context_file" "$rp")" || one=""
      [[ -n "$one" ]] && context="$(jq -c --argjson e "$one" '. + [$e]' <<<"$context")"
    fi
  fi

  jq -nc --argjson i "$instructions" --argjson c "$context" '{instructions: $i, context: $c}'
}

# review_context_sources_digest SOURCES_JSON
# SOURCES_JSON is `{"instructions": [...], "context": [...]}` as
# review_context_build_json returns it, each entry already carrying its own
# `bytes`/`digest` (computed once, in _review_context_entry, over the text
# actually sent). Prints a compact array — one entry per resolved source,
# each `{type, source, origin, digest, bytes, truncated}` — for the run's own
# record (review-stage-start), with `text` stripped: a sha256 and a byte
# count are enough to make a review's inputs reconstructable without copying
# arbitrary file content into the log.
review_context_sources_digest() {
  local sources_json="$1"
  jq -c '
    [ ((.instructions // [])[] | {type: "instructions"} + .) ,
      ((.context // [])[] | {type: "context"} + .) ]
    | map(del(.text))
  ' <<<"$sources_json" 2>/dev/null || printf '[]'
}
