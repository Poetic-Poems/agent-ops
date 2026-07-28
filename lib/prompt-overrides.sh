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
# Prints one line per configured, readable extension file, in configured
# order: the configured path exactly as written in config.json, a tab, then
# the resolved path the content is read from. Both travel because they serve
# different masters — the resolved path is what this node can open, the
# configured path is the node-independent name the assembled text and the
# fingerprint identify the fragment by. An unreadable or unconfigured entry
# contributes no line.
stage_extend_files() {
  local state_dir="$1" stage="$2" overrides_json="$3"
  local raw resolved
  while IFS= read -r raw; do
    [[ -n "$raw" ]] || continue
    resolved="$(resolve_prompt_override_path "$state_dir" "$raw")"
    [[ -r "$resolved" ]] && printf '%s\t%s\n' "$raw" "$resolved"
  done < <(jq -r --arg s "$stage" '(.[$s].extend // [])[]?' <<<"$overrides_json" 2>/dev/null || true)
}

# _prompt_override_fragment CONFIGURED_PATH FILE
# The appended section for one extension file: a heading naming the entry's
# configured path (as written in config.json, never the node-resolved
# location — the assembled text must be identical on every node serving the
# same config and content, or the fleet-compared fingerprint below cannot
# be), its content, plus a fixed disclaimer that it is guidance, not a
# licence to skip a numbered requirement (CLAUDE.md, "As-built
# specifications": specs outrank prompts).
_prompt_override_fragment() {
  local configured="$1" file="$2"
  printf '\n\n## Installation extension (%s)\n\n%s\n\n> This extension may add guidance for this installation. It does not\n> exempt this installation from any numbered requirement in this\n> repository'"'"'s specs (see CLAUDE.md, "As-built specifications") — the\n> specs outrank every prompt, this text included.\n' \
    "$configured" "$(cat "$file")"
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
  # The base is product content, not an override, so the tolerance above does
  # not extend to it: an unreadable `prompts/<stage>.md` is a broken install,
  # and a stage launched on an empty prompt would spend a model with no
  # instructions at all. Fail here so `errexit` at the call site kills the
  # cycle, exactly as the bare `cat` this function replaced did. (A configured
  # `replace` that is unreadable never reaches this line — it has already
  # fallen back to the shipped prompt.)
  cat "$base_file" || return 1
  while IFS=$'\t' read -r cfg ext; do
    _prompt_override_fragment "$cfg" "$ext"
  done < <(stage_extend_files "$state_dir" "$stage" "$overrides_json")
}

# stage_prompt_sha PROMPTS_DIR STATE_DIR STAGE OVERRIDES_JSON
# A digest that changes iff stage_prompt_text's output for STAGE would
# change — for the no-op fingerprint (requirement 3b), which must notice an
# edited or newly-broken override exactly as it notices an edited
# prompts/<stage>.md. Content-addressed: the base file contributes its
# content hash alone, and each configured `extend` entry contributes its
# content hash keyed by its *configured* path — the config.json string the
# fragment heading also serves, so it is already part of the text — with a
# configured-but-unreadable entry recorded explicitly under that same name,
# so a fragment silently going missing busts the fingerprint rather than
# reproducing the same "no work" verdict forever. No resolved filesystem
# path enters the digest: `none-selected` fingerprints are compared
# fleet-wide (requirement 3b reads the shared log), so two nodes serving
# identical prompt bytes from different install paths must compute the same
# fingerprint, and moving an installation without changing a byte of content
# must not bust the short-circuit. A `replace` file becoming readable, or a
# rename, registers exactly when it changes the bytes served — and not when
# it does not.
stage_prompt_sha() {
  local prompts_dir="$1" state_dir="$2" stage="$3" overrides_json="$4"
  local base_file raw resolved
  base_file="$(stage_base_prompt_file "$prompts_dir" "$state_dir" "$stage" "$overrides_json")"
  {
    [[ -r "$base_file" ]] && sha256sum "$base_file" | cut -d' ' -f1
    while IFS= read -r raw; do
      [[ -n "$raw" ]] || continue
      resolved="$(resolve_prompt_override_path "$state_dir" "$raw")"
      if [[ -r "$resolved" ]]; then
        printf '%s %s\n' "$(sha256sum "$resolved" | cut -d' ' -f1)" "$raw"
      else
        printf 'missing %s\n' "$raw"
      fi
    done < <(jq -r --arg s "$stage" '(.[$s].extend // [])[]?' <<<"$overrides_json" 2>/dev/null || true)
  } | sha256sum | cut -d' ' -f1
}

# prompt_overrides_config_error OVERRIDES_JSON
# Prints one line naming the first structural fault in OVERRIDES_JSON — a
# non-object at the top, an unknown stage key, a non-object stage value, an
# unknown key inside a stage, a non-array `extend`, a non-string `extend`
# entry or `replace` — and prints nothing when the shape is valid. Called at
# startup (agent-cycle.sh, requirement 4a): every fault here is a config.json
# authoring error that the `?`/`// empty` tolerance in the functions above
# would otherwise swallow, serving the unmodified shipped prompt every cycle
# with no error and, for a misspelled stage key, no fingerprint movement
# either. Runtime faults — a well-formed entry whose file is unreadable this
# cycle — are deliberately not this function's business.
prompt_overrides_config_error() {
  local overrides_json="$1"
  jq -r '
    def stages: ["coordinator", "implementor", "reviewer", "enabler"];
    if type != "object" then
      "must be an object keyed by stage (coordinator/implementor/reviewer/enabler)"
    else
      first(
        (keys_unsorted[] | select(. as $k | stages | index($k) | not)
          | "unknown stage \"\(.)\" — stages are coordinator/implementor/reviewer/enabler"),
        (to_entries[] | .key as $s | .value |
          if type != "object" then
            "\($s): must be an object holding \"extend\" and/or \"replace\""
          else
            (keys_unsorted[] | select(. != "extend" and . != "replace")
              | "\($s): unknown key \"\(.)\" — valid keys are \"extend\" and \"replace\""),
            (if has("extend") then
              if (.extend | type) != "array" then
                "\($s).extend: must be an array of file paths"
              else
                (.extend[] | select(type != "string")
                  | "\($s).extend: every entry must be a file-path string")
              end
            else empty end),
            (if has("replace") and ((.replace | type) != "string") then
              "\($s).replace: must be a single file-path string"
            else empty end)
          end)
      ) // empty
    end
  ' <<<"$overrides_json" 2>/dev/null || printf 'is not valid JSON\n'
}
