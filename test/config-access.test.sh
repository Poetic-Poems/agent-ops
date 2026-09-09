#!/usr/bin/env bash
#
# test/config-access.test.sh — regression test for lib/config-access.sh
# (issue #967): `expand_home`, `cfg` and `cfg_json` used to be typed
# identically in both agent-cycle.sh and review-cycle.sh, with nothing
# pinning the two copies together. This tests the one shared definition
# both scripts now source, and that neither script still types its own.
#
# `cfg`/`cfg_json` read the global `DEFAULTED_CONFIG` by name, exactly as
# each cycle's own does, so this sets that variable directly rather than
# resolving it through config_defaults — lib/config-schema.sh's own tests
# cover that resolution.
#
# No network, no GitHub. Run directly:
#
#   ./test/config-access.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/config-access.sh
. "$SCRIPT_DIR/lib/config-access.sh"

# --- expand_home ---------------------------------------------------------------
assert_eq "a ~-prefixed path expands against \$HOME" "$HOME/state" \
  "$(expand_home '~/state')"
assert_eq "a bare ~ expands to \$HOME alone" "$HOME" "$(expand_home '~')"
assert_eq "an absolute path is untouched" "/var/lib/agent-ops" \
  "$(expand_home '/var/lib/agent-ops')"
assert_eq "a relative path with no ~ is untouched" "state/cycles" \
  "$(expand_home 'state/cycles')"
assert_eq "a ~ in the middle of a path is not special" "/x/~/y" \
  "$(expand_home '/x/~/y')"

# --- cfg / cfg_json, against a fixed DEFAULTED_CONFIG ---------------------------
DEFAULTED_CONFIG='{"pr_label": "autonomous-agent", "claim_ttl_hours": 6, "repos": ["a/b", "c/d"]}'
assert_eq "cfg reads a string value" "autonomous-agent" "$(cfg '.pr_label')"
assert_eq "cfg reads a number value as text" "6" "$(cfg '.claim_ttl_hours')"
assert_eq "cfg_json reads an array compactly" '["a/b","c/d"]' "$(cfg_json '.repos')"

# --- Both cycles source this file rather than typing their own copy ------------
for script in agent-cycle.sh review-cycle.sh; do
  assert_eq "$script sources lib/config-access.sh" "1" \
    "$(grep -c '^\. "\$SCRIPT_DIR/lib/config-access\.sh"$' "$SCRIPT_DIR/$script")"
  assert_eq "$script defines no expand_home() of its own" "0" \
    "$(grep -c '^expand_home()' "$SCRIPT_DIR/$script")"
  assert_eq "$script defines no cfg() of its own" "0" \
    "$(grep -c '^cfg()' "$SCRIPT_DIR/$script")"
  assert_eq "$script defines no cfg_json() of its own" "0" \
    "$(grep -c '^cfg_json()' "$SCRIPT_DIR/$script")"
done

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
