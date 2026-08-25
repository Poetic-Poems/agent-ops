#!/usr/bin/env bash
#
# test/token-expiry.test.sh — regression test for lib/token-expiry.sh: the
# fine-grained PAT expiry warning (agent-ops#694). Pure-function coverage
# only; test/doctor.test.sh covers the header read and the artefact write,
# and test/token-expiry-wiring.test.sh covers agent-cycle.sh's escalation.
#
# Two directions matter here:
#
#   - `token_expiry_parse` must floor a same-day expiry at 0 days, never at
#     1 (rounding up would read a token that expires in six hours as "still
#     safe until tomorrow") and never negative (an already-expired token is
#     agent-ops#691's own territory, not this file's — a caller must not see
#     a more alarming number than "0 days left" from here).
#   - `token_expiry_escalated_for` must dedup on the exact `expires_at`
#     rather than merely "was a token-expiry-escalated event ever logged" —
#     a rotated token (a new expiry) must be able to escalate again even
#     though the event name repeats.
#
# Run directly: ./test/token-expiry.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/token-expiry.sh
. "$SCRIPT_DIR/lib/token-expiry.sh"

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

# --- token_expiry_parse ---

now_epoch="$(date -u -d '2026-08-01 00:00:00 UTC' +%s)"

out="$(token_expiry_parse '2026-08-30 00:00:00 UTC' "$now_epoch")"
assert_eq "29 days out parses to expires_at" "2026-08-30T00:00:00Z" "$(cut -f1 <<<"$out")"
assert_eq "…and the day count" "29" "$(cut -f2 <<<"$out")"

out="$(token_expiry_parse '2026-08-04 12:00:00 UTC' "$now_epoch")"
assert_eq "a fractional-day remainder floors down" "3" "$(cut -f2 <<<"$out")"

out="$(token_expiry_parse '2026-08-01 06:00:00 UTC' "$now_epoch")"
assert_eq "six hours out floors to 0 days, never rounds up to 1" "0" "$(cut -f2 <<<"$out")"

out="$(token_expiry_parse '2026-07-25 00:00:00 UTC' "$now_epoch")"
assert_eq "a token already past its own expiry floors at 0, never negative" \
  "0" "$(cut -f2 <<<"$out")"

if token_expiry_parse '' "$now_epoch" >/dev/null 2>&1; then
  assert_eq "an empty header value is refused" "refused" "accepted"
else
  assert_eq "an empty header value is refused" "refused" "refused"
fi

if token_expiry_parse 'not a date' "$now_epoch" >/dev/null 2>&1; then
  assert_eq "an unparseable header value is refused, not read as some fallback date" "refused" "accepted"
else
  assert_eq "an unparseable header value is refused, not read as some fallback date" "refused" "refused"
fi

# --- token_expiry_escalated_for ---

union_log="$(mktemp)"
trap 'rm -f "$union_log"' EXIT
cat > "$union_log" <<'EOF'
{"ts":"2026-08-01T00:00:00Z","node":"ockham-1","event":"token-expiry-escalated","expires_at":"2026-08-22T09:35:00Z","days_remaining":6}
{"ts":"2026-08-01T00:05:00Z","node":"ockham-2","event":"token-expiry-escalated","expires_at":"2026-09-01T00:00:00Z","days_remaining":6}
EOF

if token_expiry_escalated_for "ockham-1" "2026-08-22T09:35:00Z" < "$union_log"; then
  assert_eq "an exact node+expiry match is found" "found" "found"
else
  assert_eq "an exact node+expiry match is found" "found" "missing"
fi

if token_expiry_escalated_for "ockham-1" "2026-09-15T00:00:00Z" < "$union_log"; then
  assert_eq "a rotated token (a new expires_at) is not shadowed by the old escalation" "not-found" "found"
else
  assert_eq "a rotated token (a new expires_at) is not shadowed by the old escalation" "not-found" "not-found"
fi

if token_expiry_escalated_for "ockham-3" "2026-08-22T09:35:00Z" < "$union_log"; then
  assert_eq "a different node's identical expiry does not cross-match" "not-found" "found"
else
  assert_eq "a different node's identical expiry does not cross-match" "not-found" "not-found"
fi

echo
if (( failures == 0 )); then
  echo "All token-expiry assertions passed."
  exit 0
else
  echo "$failures token-expiry assertion(s) FAILED."
  exit 1
fi
