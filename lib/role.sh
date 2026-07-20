#!/usr/bin/env bash
#
# lib/role.sh — which node may run unattended cycles.
#
# The pipelines are meant to run on more than one machine (a laptop and any
# number of cloud nodes), but exactly one of them may actually spend: two
# nodes cycling on the same repos would open competing pull requests for the
# same item and pay twice to do it. `AGENT_OPS_ROLE` names that machine.
#
# Fail-closed by design: only the literal value `active` runs unattended
# cycles. Unset, empty, misspelt or any other value is a standby, because the
# failure modes are not symmetric — a standby that should have been active
# costs one skipped cycle, an accidental second active costs money and makes a
# mess a human has to clean up in the target repos.
#
# Shared by agent-cycle.sh and review-cycle.sh so there is one definition of
# "active", the same way lib/toggle.sh is the one definition of the switch.

# The current role, normalised: lowercased, whitespace stripped, defaulting to
# `standby` when the variable is unset or empty.
role_current() {
  local r="${AGENT_OPS_ROLE:-}"
  r="$(printf '%s' "$r" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  printf '%s' "${r:-standby}"
}

# True only for the one role that may spend.
role_is_active() {
  [[ "$(role_current)" == "active" ]]
}

# One line for the cron log explaining a skip. Names the role it saw, because
# the common fault is a value that is neither `active` nor `standby` — a typo
# in a .env or a crontab — and "AGENT_OPS_ROLE=activ" diagnoses itself where a
# bare "not active" would not.
role_skip_message() {
  local who="${1:-agent-cycle}" role
  role="$(role_current)"
  case "$role" in
    standby) printf '%s: skipped — this node is standby (AGENT_OPS_ROLE=%s)\n' "$who" "${AGENT_OPS_ROLE:-<unset>}" ;;
    *)       printf '%s: skipped — AGENT_OPS_ROLE=%s is not a role; treating this node as standby\n' "$who" "$role" ;;
  esac
}
