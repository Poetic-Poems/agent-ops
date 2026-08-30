#!/usr/bin/env bash
#
# scripts/gh-shim.sh — the executable installed on `PATH` ahead of the real
# `gh` binary (requirement 2.0e, agent-ops#1084). All of the logic lives in
# lib/gh-shim.sh, which this only sources and calls; see that file's own
# header for what the shim does and why.
#
# Never `source`d — this is the thing `PATH` resolves when anything, this
# repository's own scripts or a model-driven stage alike, runs `gh …`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/gh-shim.sh
. "$SCRIPT_DIR/lib/gh-shim.sh"

gh_shim_main "$@"
exit $?
