#!/usr/bin/env bash
#
# test/dashboard-refresh.test.sh — regression tests for dashboard/index.html's
# SPA refresh tick: the conditional data.js fetch stamp.js added (issue
# #1288), and two correctness fixes review found missing coverage for
# (agent-ops#1300):
#
#   the lost-fetch wedge   a data.js fetch that fails (loadScript's onerror)
#                          must not advance the tab's own comparison
#                          fingerprint, or the tab retries never again — every
#                          later tick sees its own fresher stamp "agree" with
#                          a fingerprint the tab never actually applied, and
#                          the page quietly stops updating while its header
#                          clock keeps ticking as if nothing were wrong.
#   the two-request race   the page's first load fetches data.js and stamp.js
#                          as two separate, uncoordinated HTTP requests (a
#                          plain <script src> pair, not the refresh tick's
#                          cache-busted one); a publish landing between them
#                          can pair a newer stamp with the older data.js the
#                          tab actually has. Seeding the tab's starting
#                          fingerprint from data.js's own embedded value,
#                          rather than from stamp.js, is what closes this —
#                          proven here by handing the harness exactly that
#                          disagreement at page load.
#
# dashboard-render-harness.js is deliberately a tree-building stub only, so
# this uses a second, narrower one — test/dashboard-refresh-harness.js — that
# never renders and instead fires the page's own #refreshbtn click listener
# (the only external hook onto tick()) against a scripted, synchronous
# sequence of simulated stamp.js/data.js fetch outcomes. See that file's own
# header for the scenario format.
#
# No network, no real DOM. Needs node, same as dashboard-render.test.sh;
# absent, this skips with a note rather than failing.
#
# Run directly: ./test/dashboard-refresh.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$SCRIPT_DIR/test/dashboard-refresh-harness.js"
BASE_FIXTURE="$SCRIPT_DIR/test/fixtures/dashboard-data/refresh-base.json"

failures=0

if ! command -v node >/dev/null 2>&1; then
  printf 'ok   - node not installed here; CI runs the node-backed assertions in-image\n'
  printf '\nall assertions passed\n'
  exit 0
fi

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- the scenario --------------------------------------------------------
# fp1 (below, only in comments) is refresh-base.json's own embedded
# `fingerprint` — what the tab's *first load* actually parsed out of data.js.
# fp2 and fp3 are two later publishes' fingerprints; only their distinctness
# from each other and from fp1 matters, not their form.
fp2="2222222222222222222222222222222222222222222222222222222222222222"
fp3="3333333333333333333333333333333333333333333333333333333333333333"

# initialStamp answers fp2 — a newer publish than fp1, exactly the race a
# publish landing between the page's two initial <script src> fetches would
# produce. If the page seeded its starting comparison fingerprint from this
# (the bug review found), tick 0 below would wrongly read as "unchanged".
cat > "$work/scenario.json" <<EOF
{
  "initialStamp": {"generated_at": "2026-09-09T00:00:01Z", "fingerprint": "$fp2"},
  "ticks": [
    { "stamp": {"generated_at": "2026-09-09T00:00:01Z", "fingerprint": "$fp2"},
      "dataOverrides": {"generated_at": "2026-09-09T00:00:01Z", "fingerprint": "$fp2"} },
    { "stamp": {"generated_at": "2026-09-09T00:00:02Z", "fingerprint": "$fp2"} },
    { "stamp": {"generated_at": "2026-09-09T00:00:03Z", "fingerprint": "$fp3"},
      "dataOverrides": null },
    { "stamp": {"generated_at": "2026-09-09T00:00:04Z", "fingerprint": "$fp3"},
      "dataOverrides": {"generated_at": "2026-09-09T00:00:04Z", "fingerprint": "$fp3"} },
    { "stamp": {"generated_at": "2026-09-09T00:00:05Z", "fingerprint": "$fp3"} }
  ]
}
EOF

out="$(node "$HARNESS" "$BASE_FIXTURE" "$work/scenario.json" 2>&1)"
rc=$?
if (( rc != 0 )); then
  printf 'FAIL - the scenario ran without error\n     exit %d, output:\n%s\n' "$rc" "$out"
  failures=$(( failures + 1 ))
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi

tick() { jq -c "select(.tick == $1)" <<<"$out"; }

# Tick 0: the tab's own fingerprint (seeded from data.js's fp1, not stamp.js's
# fp2 — see the header above) disagrees with the stamp's fp2, so it must
# fetch data.js even though nothing changed between the initial stamp and
# this tick's own stamp answer. A tab still seeding from stamp.js would see
# fp2 == fp2 here and wrongly skip.
assert_eq "tick 0: the race at page load still triggers a data.js fetch" \
  "true" "$(jq -r '.dataFetched' <<<"$(tick 0)")"

# Tick 1: now genuinely unchanged (fp2 == fp2, the fingerprint tick 0 just
# applied) — the ordinary no-op-skip case, unchanged from before #1288.
assert_eq "tick 1: an unchanged fingerprint fetches no data.js" \
  "false" "$(jq -r '.dataFetched' <<<"$(tick 1)")"

# Tick 2: the fingerprint moves to fp3, so a fetch is attempted — and it
# fails (the harness's dataOverrides: null simulates loadScript's onerror).
assert_eq "tick 2: a changed fingerprint attempts a data.js fetch" \
  "true" "$(jq -r '.dataFetched' <<<"$(tick 2)")"

# Tick 3: the *same* fp3 the failed tick 2 already saw, and this time the
# fetch succeeds. If the failed fetch had advanced the tab's own fingerprint
# anyway (the bug review found), this tick would see fp3 == fp3 and skip —
# wedging the tab on stale data indefinitely, since every later tick would
# keep seeing the same false agreement. It must instead retry and land.
assert_eq "tick 3: a fingerprint a failed fetch never applied is retried, not skipped" \
  "true" "$(jq -r '.dataFetched' <<<"$(tick 3)")"

# Tick 4: fp3, unchanged since tick 3's successful apply — skip again,
# confirming the fingerprint only advances on a fetch that actually landed.
assert_eq "tick 4: unchanged again after a successful retry fetches no data.js" \
  "false" "$(jq -r '.dataFetched' <<<"$(tick 4)")"

# Every tick polls stamp.js regardless of whether data.js follows — the
# whole point of the split (issue #1288).
for i in 0 1 2 3 4; do
  assert_eq "tick $i: stamp.js is polled" "true" "$(jq -r '.stampFetched' <<<"$(tick "$i")")"
done

# ---------------------------------------------------------------------------
if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
