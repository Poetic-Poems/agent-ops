#!/usr/bin/env bash
#
# lib/config-access.sh — the small, identical config-reading helpers both
# cycles build on: `expand_home`, and `cfg`/`cfg_json` over the caller's own
# `DEFAULTED_CONFIG`.
#
# `cfg`/`cfg_json` read the global `DEFAULTED_CONFIG` by name at call time,
# not by argument, so this file can be sourced before that variable is set —
# each caller still computes its own `DEFAULTED_CONFIG` from its own
# `CONFIG_FILE`/`SCHEMA_FILE` (agent-cycle.sh and review-cycle.sh read
# different config files in principle, `AGENT_OPS_CONFIG` included), only the
# shape of the two lookup functions is shared, never the config they read.

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }
cfg_json() { jq -c "$1" <<<"$DEFAULTED_CONFIG"; }
