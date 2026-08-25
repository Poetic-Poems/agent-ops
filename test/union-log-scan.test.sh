#!/usr/bin/env bash
#
# test/union-log-scan.test.sh — the union event stream is read by streaming it,
# never by slurping it into one string and regex-splitting that (#791).
#
# What this guards: `jq -R -s '[ splits("\n") | ... ]'` is a regex match over
# the *whole* input. It is super-linear, and the log it reads only ever grows.
# On 2026-08-25 eight readers shared that shape; on `poetic-2`, one
# `crash_loop_verdict` call over a 9.5 MB `.fleet-log.jsonl` was still running
# after 13 minutes at ~90% of a core, and substantive cycles were taking 69 to
# 155 minutes on a box whose no-op cycles finish in one second.
#
# Measured on the same file, same jq, the two forms — which tolerate malformed
# lines identically, since each applies `fromjson? // empty` per line:
#
#     lines    bytes   -R -s + splits("\n")   -R -n + inputs
#     2,500   429 KB              3,607 ms            15 ms
#     5,000   974 KB             16,246 ms            28 ms
#    10,000   2.3 MB             76,008 ms            64 ms
#
# ~4.5x per doubling against ~2x. The two assertions below are deliberately
# different in kind: the first is a static guard that fails the moment the
# shape reappears anywhere, the second proves the property end to end for the
# hottest reader, so the guard cannot be satisfied by a rewrite that keeps the
# cost.
#
# Run directly: ./test/union-log-scan.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/crash-loop.sh
. "$SCRIPT_DIR/lib/crash-loop.sh"

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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# --- The static guard --------------------------------------------------------
# `splits("\n")` is only ever the line-splitting use, and `inputs` under `-R -n`
# replaces it everywhere. Naming the offenders in the failure message matters:
# the whole defect was invisible until someone ran `top`, so a reintroduction
# must say exactly which file brought it back.
mapfile -t offenders < <(
  cd "$SCRIPT_DIR" && grep -rln 'splits("\\n")' \
    agent-cycle.sh review-cycle.sh lib scripts 2>/dev/null | sort
)
assert_eq "no shipped script splits the stream with splits(\"\\n\")" \
  "" "$(printf '%s\n' "${offenders[@]}" | grep -v '^$' | paste -sd, -)"

# --- The property the guard stands for ---------------------------------------
# 20,000 events is a plausible union log for a fleet a few weeks old — smaller
# than the 34,078-line file that provoked this. Streaming, this is well under a
# second. Slurp-and-split took 335 s on the same input on the machine the table
# above was measured on, so the bound below sits ~5x under the old behaviour
# and ~100x over the new: generous to a slow or loaded CI box, and still
# incapable of passing if the quadratic form returns.
stream="$tmp_dir/union.jsonl"
{
  i=0
  while (( i < 20000 )); do
    printf '{"ts":"2026-08-25T00:%02d:%02dZ","node":"n1","event":"attempt-failed","stage":"coordinator","detail":"boom"}\n' \
      $(( i / 60 % 60 )) $(( i % 60 ))
    i=$(( i + 1 ))
  done
} > "$stream"

# A NUL run mid-record, exactly as an unclean stop leaves behind — the reason
# `fromjson? // empty` is load-bearing and must survive any rewrite here.
printf '{"ts":"2026-08-25T01:00:00Z"\0\0\0\0,"event":"truncated"}\n' >> "$stream"

start_s=$SECONDS
verdict="$(crash_loop_verdict 4 < "$stream")"
elapsed=$(( SECONDS - start_s ))
printf '# crash_loop_verdict over %s events: %ss\n' "$(wc -l < "$stream")" "$elapsed"

assert_eq "a 20,000-event stream still yields the loop verdict" \
  "4" "$(jq -r 'if .count >= 4 then 4 else .count end' <<<"$verdict" 2>/dev/null)"
assert_eq "the corrupt record is skipped, not fatal" \
  "coordinator" "$(jq -r '.stage' <<<"$verdict" 2>/dev/null)"
assert_eq "scanning 20,000 events stays linear (<60s)" \
  "1" "$(( elapsed < 60 ))"

if (( failures == 0 )); then
  printf '\nAll assertions passed.\n'
  exit 0
fi
printf '\n%d assertion(s) failed.\n' "$failures"
exit 1
