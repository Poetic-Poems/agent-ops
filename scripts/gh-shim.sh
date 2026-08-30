#!/usr/bin/env bash
#
# scripts/gh-shim.sh — the executable installed on `PATH` ahead of the real
# `gh` binary (requirement 2.0e, agent-ops#1084). All of the logic lives in
# lib/gh-shim.sh, which this only sources and calls; see that file's own
# header for what the shim does and why.
#
# Never `source`d — this is the thing `PATH` resolves when anything, this
# repository's own scripts or a model-driven stage alike, runs `gh …`.
#
# `readlink -f` matters here in a way it does not for most other scripts in
# this repository: `deploy/docker/Dockerfile` installs this file's own PATH
# entry as a symlink (`/usr/local/bin/gh -> /app/scripts/gh-shim.sh`), and a
# symlinked invocation's `${BASH_SOURCE[0]}` is the *link's* path
# (`/usr/local/bin/gh`), not the file it points to — `dirname` on that gives
# `/usr/local/bin`, one directory removed from where `lib/gh-shim.sh` lives.
# Resolving the real path first is what makes the same file work identically
# invoked directly (`./scripts/gh-shim.sh`, as every test in this repository
# does) and invoked through the installed symlink.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=lib/gh-shim.sh
. "$SCRIPT_DIR/lib/gh-shim.sh"

gh_shim_main "$@"
exit $?
