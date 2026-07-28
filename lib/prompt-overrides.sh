#!/usr/bin/env bash
#
# lib/prompt-overrides.sh — per-installation prompt overrides (issue #79,
# docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 4a).
#
# `prompts/*.md` are product content: they ship with the image, and a fork
# that edits one directly stops receiving updates to it. config.json's
# `prompt_overrides.<stage>` lets a consumer add or replace a stage's prompt
# without touching `prompts/`, by naming files that live outside it — a
# relative path resolves against `state_dir`, the one location this repo
# guarantees survives an image update or a `git pull` (prompts/*.md does
# not). `extend` (the primary mode) appends one or more files, each wrapped
# with a disclaimer that the installation's specs still outrank it; `replace`
# (sharper, flagged loudly in the README) substitutes a whole file for the
# stage's shipped prompt before any `extend` fragments are appended.
#
# Absent `prompt_overrides` (or a stage missing from it), every function here
# reproduces today's behaviour byte-for-byte: `stage_prompt_text` prints
# exactly `cat prompts/<stage>.md` would. A configured path that is not
# readable is treated the same as absent — a typo must not fail a cycle —
# though it still changes the fingerprint (`stage_prompt_sha`), so a broken
# path is visible as an unexplained fingerprint change rather than silently
# eaten.
#
# Sourced by agent-cycle.sh.

# resolve_prompt_override_path STATE_DIR RAW
# Expands a leading ~ against $HOME, then resolves a still-relative path
# against STATE_DIR. Prints nothing for an empty RAW.
resolve_prompt_override_path() {
  local state_dir="$1" raw="$2" p
  [[ -n "$raw" ]] || return 0
  p="$raw"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  [[ "$p" == /* ]] || p="$state_dir/$p"
  printf '%s\n' "$p"
}

# stage_base_prompt_file PROMPTS_DIR STATE_DIR STAGE OVERRIDES_JSON
# Prints the path whose content is the stage's base prompt: the configured
# `replace` file when it is set and readable, else prompts/<stage>.md.
stage_base_prompt_file() {
  local prompts_dir="$1" state_dir="$2" stage="$3" overrides_json="$4"
  local replace_raw replace_path
  replace_raw="$(jq -r --arg s "$stage" '(.[$s].replace // empty)' <<<"$overrides_json" 2>/dev/null || true)"
  if [[ -n "$replace_raw" ]]; then
    replace_path="$(resolve_prompt_override_path "$state_dir" "$replace_raw")"
    if [[ -r "$replace_path" ]]; then
      printf '%s\n' "$replace_path"
      return 0
    fi
  fi
  printf '%s\n' "$prompts_dir/$stage.md"
}

# stage_extend_files STATE_DIR STAGE OVERRIDES_JSON
# Prints one resolved, readable extension path per line, in configured
# order. An unreadable or unconfigured entry contributes no line.
stage_extend_files() {
  local state_dir="$1" stage="$2" overrides_json="$3"
  local raw resolved
  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue
    resolved="$(resolve_prompt_override_path "$state_dir" "$raw")"
    [[ -r "$resolved" ]] && printf '%s\n' "$resolved"
  done < <(jq -r --arg s "$stage" '(.[$s].extend // [])[]?' <<<"$overrides_json" 2>/dev/null || true)
}

# _prompt_override_fragment PATH
# The appended section for one extension file: its content, plus a fixed
# disclaimer that it is guidance, not a licence to skip a numbered
# requirement (CLAUDE.md, "As-built specifications": specs outrank prompts).
_prompt_override_fragment() {
  local path="$1"
  printf '\n\n## Installation extension (%s)\n\n%s\n\n> This extension may add guidance for this installation. It does not\n> exempt this installation from any numbered requirement in this\n> repository'"'"'s specs (see CLAUDE.md, "As-built specifications") — the\n> specs outrank every prompt, this text included.\n' \
    "$path" "$(cat "$path")"
}

# stage_prompt_text PROMPTS_DIR STATE_DIR STAGE OVERRIDES_JSON
# The whole assembled prompt for STAGE: the base file (default or configured
# `replace`) followed by every configured, readable `extend` file in order.
# With no override configured for STAGE, this is byte-identical to
# `cat "$PROMPTS_DIR/$STAGE.md"`.
stage_prompt_text() {
  local prompts_dir="$1" state_dir="$2" stage="$3" overrides_json="$4"
  local base_file ext
  base_file="$(stage_base_prompt_file "$prompts_dir" "$state_dir" "$stage" "$overrides_json")"
  cat "$base_file"
  while IFS= read -r ext; do
    _prompt_override_fragment "$ext"
  done < <(stage_extend_files "$state_dir" "$stage" "$overrides_json")
}

# stage_prompt_sha PROMPTS_DIR STATE_DIR STAGE OVERRIDES_JSON
# A digest that changes iff stage_prompt_text's output for STAGE would
# change — for the no-op fingerprint (requirement 3b), which must notice an
# edited or newly-broken override exactly as it notices an edited
# prompts/<stage>.md. Hashes each contributing file's own sha256sum line
# (so a rename without a content change still registers, matching how a
# `replace` path becoming readable changes what would be served) rather than
# stage_prompt_text's output directly, and records a missing configured
# `extend` file explicitly, so a fragment silently going missing also busts
# the fingerprint rather than reproducing the same "no work" verdict forever.
stage_prompt_sha() {
  local prompts_dir="$1" state_dir="$2" stage="$3" overrides_json="$4"
  local base_file raw resolved
  base_file="$(stage_base_prompt_file "$prompts_dir" "$state_dir" "$stage" "$overrides_json")"
  {
    [[ -r "$base_file" ]] && sha256sum "$base_file"
    while IFS= read -r raw; do
      [[ -n "$raw" ]] || continue
      resolved="$(resolve_prompt_override_path "$state_dir" "$raw")"
      if [[ -r "$resolved" ]]; then
        sha256sum "$resolved"
      else
        printf 'missing %s\n' "$resolved"
      fi
    done < <(jq -r --arg s "$stage" '(.[$s].extend // [])[]?' <<<"$overrides_json" 2>/dev/null || true)
  } | sha256sum | cut -d' ' -f1
}
