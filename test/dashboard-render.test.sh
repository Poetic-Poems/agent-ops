#!/usr/bin/env bash
#
# test/dashboard-render.test.sh — the first test of the ~1,265 lines of inline
# JavaScript in dashboard/index.html: what it *renders*, not just whether it
# throws (TD-PPagop-26072606).
#
# `docs/DASHBOARD-SPEC.md`'s verification list already asked for a headless
# render with no thrown errors, which catches a page that breaks and nothing
# about a page that lies — and the Outcome column's "Ended" on a running cycle
# (#94) is exactly that: it shipped, and stayed shipped, because reading the
# log-derived event ladder in isolation looks correct, and no test named the
# gap between a rule written for finished cycles and a column that renders
# unfinished ones.
#
# So this feeds checked-in JSON DASHBOARD_DATA fixtures through the page's own
# script — unmodified, via test/dashboard-render-harness.js — under a DOM stub
# that only builds trees (createElement/createTextNode/appendChild, plus a
# serialiser), and greps the rendered output for the cells under test. That
# stub is a maintenance liability if it grows to chase page features, so it
# stays to the tree-building subset: pointer/focus-driven behaviour (the
# pull-request hover card, #96) is out of scope, same as the record notes.
#
# Fixture timestamps are relative-time tokens ("@now", "@ago:5m") resolved by
# the harness at run time, not baked in — otherwise every "3m ago" assertion
# would rot the day it was written.
#
# No network. The rendered assertions need node, which the image carries for
# the Claude CLI; absent, they skip with a note rather than failing, as the
# record asks for and as test/render-crontab.test.sh does for supercronic —
# but the plain-grep check of the header's static documentation links runs
# either way, since it needs nothing but the file itself.
#
# Run directly: ./test/dashboard-render.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$SCRIPT_DIR/test/dashboard-render-harness.js"
FIXTURES_DIR="$SCRIPT_DIR/test/fixtures/dashboard-data"

failures=0

# --- the header's documentation nav: static markup, no data behind it ------
# A plain grep over the file, not a rendered assertion, because the six links
# are static HTML the harness's DOM stub never touches (they sit in
# header.top, outside the #app the script rebuilds) — and unlike the
# assertions below, this runs whether or not node is installed here.
INDEX_HTML="$SCRIPT_DIR/dashboard/index.html"
for path in \
  README.md \
  docs/IMPLEMENTATION-PIPELINE-SPEC.md \
  docs/REVIEW-PIPELINE-SPEC.md \
  docs/DASHBOARD-SPEC.md \
  docs/METERING-SCHEMA.md \
  docs/ROADMAP.md \
; do
  url="https://github.com/Poetic-Poems/agent-ops/blob/main/$path"
  if grep -qF "$url" "$INDEX_HTML"; then
    printf 'ok   - the docs nav links %s\n' "$path"
  else
    printf 'FAIL - the docs nav is missing a link to %s\n     expected: %s\n' "$path" "$url"
    failures=$(( failures + 1 ))
  fi
done

if ! command -v node >/dev/null 2>&1; then
  printf 'ok   - node not installed here; CI runs the node-backed assertions in-image\n'
  if (( failures > 0 )); then
    printf '\n%d assertion(s) failed\n' "$failures"
    exit 1
  fi
  printf '\nall assertions passed\n'
  exit 0
fi

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

render() {  # render <fixture> [localStorage-json]
  node "$HARNESS" "$FIXTURES_DIR/$1" "${2:-}"
}

# --- running.json: a cycle live in the Co-Ordinator stage, before selection ---
# This is exactly the #94 window: the log-derived ladder has nothing
# classifiable to say yet (no `selection` logged), which is what used to fall
# to the ladder's floor and render as "Ended" on a cycle that had not begun to
# earn a verdict.
out="$(render running.json)" || { printf 'FAIL - running.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "a coordinator-stage cycle with nothing selected yet reads 'In progress'" \
  "In progress" "$out"
assert_not_contains "and never the finished-cycle badge text" "Ended" "$out"
assert_contains "the fleet card names the stage while nothing is selected" \
  "coordinator" "$out"
assert_contains "and says so in words, not just the stage name" \
  "choosing work" "$out"
assert_contains "a cycle with no cycle-end and no node claiming it now reads 'No clean end'" \
  "No clean end" "$out"
assert_contains "the node card for that dead node carries the lower-case form" \
  "no clean end" "$out"
assert_contains "the fleet strip is visible once a second node exists" \
  'class="cards fleet"' "$out"
assert_contains "the running node's card is tagged as this node" \
  "poetic-1" "$out"
assert_contains "and the idle peer is tagged by name too" \
  "poetic-2" "$out"
assert_contains "the header summarises how many of the fleet are running" \
  "1 of 4 nodes running" "$out"
# The log tail's Node, Repo and Actor columns. Three fixed cells read
# positionally, so what each one is claiming does not depend on how many of
# them the event happened to carry — the case that used to make the old
# combined "Where" column ambiguous, since a lone token could be either the
# repo or the stage. Checked against the tree flattened to one line, same as
# the tech-debt badge check above: the harness serialises each node on its
# own line at its own depth, so a cell and its text are only adjacent once
# the newlines and indentation are gone.
logflat="$(tr '\n' ' ' <<<"$out" | tr -s ' ')"
assert_contains "the log tail heads its three where-columns separately" \
  "<th> Time <th> Event <th> Node <th> Repo <th> Actor <th> Detail" "$logflat"
assert_not_contains "and no longer as one combined column" \
  "Node / Repo / Actor" "$out"
assert_contains "a stage event names the node it ran on and the actor that ran" \
  '<td class="mono muted"> poetic-1 <td class="mono muted"> — <td class="mono muted"> coordinator' \
  "$logflat"
assert_contains "an event whose actor is named in 'by' rather than 'stage' still names it" \
  '<td class="mono muted"> poetic-2 <td class="mono muted"> poetic-fiddle <td class="mono muted"> enabler' \
  "$logflat"
assert_contains "and a missing node keeps its own cell rather than shifting the repo into it" \
  '<td class="mono muted"> — <td class="mono muted"> agent-ops <td class="mono muted"> —' \
  "$logflat"

# --- disabled/enabled events carry their scope on the badge (issue #426) ----
# The bare event name cannot say whether a stop was one node or the whole
# fleet; `scope` is folded into the badge text itself rather than a new
# column, since only these two events carry it.
assert_contains "a node-scoped disable is badged 'disabled · node'" \
  '<span class="badge b-grey"> disabled · node' "$logflat"
assert_contains "a fleet-scoped enable is badged 'enabled · fleet'" \
  '<span class="badge b-grey"> enabled · fleet' "$logflat"
assert_contains "a failed fleet-flag outcome appends to the Detail cell" \
  "fleet flag: failed" "$out"

# --- Image-drift badges on the fleet strip (#155) ---------------------------
# poetic-1 (self) is current and gets no badge; poetic-2 predates the check
# (null, like an old version/compose verdict) and gets no badge either;
# poetic-3 is behind an image published longer ago than
# image_behind_grace_hours, past the mid-roll tolerance; poetic-4's registry
# check failed outright.
assert_contains "a node behind an image older than the grace window is flagged" \
  "image behind" "$out"
assert_contains "carrying the registry's commit, abbreviated for reading" \
  "abc1234" "$out"
assert_contains "a node whose registry check failed reads unverified, not silently current" \
  "image unverified" "$out"
assert_contains "poetic-3 is named on the strip" \
  "poetic-3" "$out"
assert_contains "poetic-4 is named on the strip" \
  "poetic-4" "$out"

# --- The node-scoped switch badge on the fleet strip (issue #379) -----------
# poetic-1 (self) carries an enabled switch and gets no badge; poetic-2
# carries a node-scoped disable and gets one, beside its role badge, naming
# the reason and the expiry; poetic-3/poetic-4 predate the field (absent, like
# an old version/compose/image verdict) and get none either.
assert_contains "a node-scoped disable is badged on its card" \
  "disabled" "$out"
assert_contains "naming the reason" \
  "editing lib/toggle.sh" "$out"
assert_contains "and the expiry" \
  "2030-01-01T00:00:00Z" "$out"

# --- finished.json: ended cycles (ready, failed) + one cycle a fleet-less --------
# data.js (no `fleet` key at all) would have carried before the strip existed.
out="$(render finished.json)" || { printf 'FAIL - finished.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "a cycle that reached pr-ready shows its outcome badge" \
  "Ready for review" "$out"
assert_contains "a failed cycle shows its outcome badge" \
  "Failed" "$out"
assert_contains "and its failure detail" \
  "exceeded the stage timeout" "$out"
assert_contains "a limit-hit failed cycle is flagged in the failures panel" \
  "usage limit" "$out"
assert_contains "an un-ended cycle with no fleet data at all reads 'Not ended', not a verdict" \
  "Not ended" "$out"
assert_not_contains "and is never mistaken for one still running" \
  "In progress" "$out"
assert_contains "the open-PR panel renders the pull request" \
  "fix the thing" "$out"
assert_contains "with its checks summarised" \
  "checks pass" "$out"
# requirement 17d / #248: a cycle whose selection carried race_losses shows
# the recovered-race badge in the cycle history, and a cycle with none does
# not — the second and third cycles in this fixture carry no race_losses at
# all, so an absent field must render nothing, not a badge for zero losses.
assert_contains "a cycle that recovered a lost claim race shows the badge" \
  "recovered race ×2" "$out"
assert_contains "coloured informational, not a warning — healthy contention, not a fault" \
  'class="badge b-blue"' "$out"
# Back-pressure gauge (agent-ops#246): 3 open agent PRs, one of them
# (#200) a ready PR with no reviewDecision — waiting on a human, not the
# pipeline — so the gauge's own figure is 2 (the draft plus the
# changes-requested PR) against max_open_agent_prs, with the raw open
# total and the human-queue count shown alongside it.
assert_contains "the back-pressure gauge trips on the adjusted count, not the raw total" \
  "/ 3 max" "$out"
assert_contains "and names the raw open total and the human-queue count beside it" \
  "3 open, 1 waiting on human" "$out"

# --- backpressure-claims.json: the gauge's own figure includes live claims (#427) ---
# agent-cycle.sh trips its cap on a four-part sum — pipeline-ready PRs, draft
# PRs, ready PRs still CHANGES_REQUESTED, and live claims (work claimed but not
# yet raised as a PR) — and the card must count the same four parts, not just
# the two it can see in the open-PR listing alone. #601 is CHANGES_REQUESTED
# (pipeline-ready), #602 is a draft, #600 is approved (waiting on human, not
# counted); the claims registry holds one unraised item-keyed claim and one
# `pr-601` exclusion entry that must NOT be double-counted since #601 is
# already in the PR listing above — so the gauge's own figure is 3 (1 + 1 + 1),
# tripping the cap at max_open_agent_prs=3.
bp="$(render backpressure-claims.json)" || { printf 'FAIL - backpressure-claims.json did not render:\n%s\n' "$bp"; exit 1; }
bpflat="$(tr '\n' ' ' <<<"$bp" | tr -s ' ')"
assert_contains "the gauge's figure counts the unraised claim, not just the two PR-visible parts" \
  '3 <small> / 3 max' "$bpflat"
assert_contains "and trips red at the cap" \
  "background:var(--red)" "$bp"
assert_contains "the raw open-PR total and human-queue count are unaffected by claims" \
  "3 open, 1 waiting on human" "$bp"
assert_contains "the card's tooltip spells out the same composition the cycle logs" \
  'title="1 changes-requested + 1 draft + 1 unraised claim(s) — plus 1 waiting on human (4 raw)"' \
  "$bp"

# --- backpressure-claim-scope.json: which registry rows are "unraised claims" ---
# The other direction of the same card. #434 taught it to count claims, and it
# counted every row in the registry — but the registry is wider than the repos,
# and holds rows for pull requests that already exist, so the gauge pinned red
# against a gate that was open. `claim.sh count`'s rule, mirrored here, drops
# four of the seven rows below:
#
#   enabler / refiner    pseudo-slug engagement tombstones (spec 35c). The cycle
#                        asks for one configured repo at a time and so never sees
#                        them; this page reads the whole registry in one call and
#                        must re-impose that scope itself. Two rows, dropped.
#   pr-700               the PR-keyed exclusion entry (#238), always dropped.
#   pr-700-abandoned-…   an item claim on #700 — a draft already inside the sum
#                        above, so counting it charges one unit of work twice.
#                        Dropped.
#   pr-701-conflict-…    an item claim on #701, which is approved and so sits in
#                        the human's queue *outside* the sum. Here the claim is
#                        the only record that the work is in flight. Kept.
#   agent/342, td/TD-…   ordinary unraised claims, one per configured repo. Kept.
#
# So the gauge reads 0 changes-requested + 1 draft + 3 claims = 4 of 8, well
# short of the cap — where counting the registry raw would have read 7 and
# tripped it.
bps="$(render backpressure-claim-scope.json)" || { printf 'FAIL - backpressure-claim-scope.json did not render:\n%s\n' "$bps"; exit 1; }
bpsflat="$(tr '\n' ' ' <<<"$bps" | tr -s ' ')"
assert_contains "the gauge counts only the claims the cycle's own gate would count" \
  '4 <small> / 8 max' "$bpsflat"
assert_contains "…so it does not trip a cap the pipeline is nowhere near" \
  "background:var(--accent)" "$bps"
assert_contains "the tooltip names the same three-claim figure" \
  'title="0 changes-requested + 1 draft + 3 unraised claim(s) — plus 1 waiting on human (5 raw)"' \
  "$bps"
assert_contains "the raw open-PR line still counts only pull requests" \
  "2 open, 1 waiting on human" "$bps"
# The panel is deliberately not filtered the way the gauge is: a tombstone
# holding an item off the whole fleet is what an operator hunting a stuck item
# needs to see, whatever the gauge does with it.
assert_contains "the live-claims panel still shows the pseudo-slug rows in full" \
  "Poetic-Poems-agent-ops/342/1786772746" "$bps"

# Single-quoted: these are literal rendered dollar amounts, not shell
# expansions, so the SC2016 the pinned linter raises on them is a false
# positive.
# shellcheck disable=SC2016
assert_contains "stage cost is broken out per stage" \
  '$0.9000' "$out"
# shellcheck disable=SC2016
assert_contains "and totalled per cycle" \
  '$1.23' "$out"
assert_contains "spend-by-day renders a bar per day" \
  "07/31" "$out"
assert_contains "spend-by-model renders a bar per model" \
  "opus-5" "$out"
assert_contains "spend-by-actor renders a bar per actor" \
  "implementer" "$out"
# issue #245: a cycle that recovered from a lost claim carries a second badge
# beside its outcome, distinct from the outcome badge itself.
assert_contains "a recovered race is marked, beside its outcome badge" \
  "raced" "$out"
assert_eq "and no other cycle in the fixture is marked raced" "1" \
  "$(grep -o 'raced' <<<"$out" | wc -l)"
assert_contains "a recovered race also names its count where the item renders" \
  "recovered race ×2" "$out"

# --- raced-standdown.json: a cycle that lost every candidate (issue #245) ------
# `race_losses` counts this cycle's `claim-lost` events, so a cycle that never
# won a claim carries one too. It is marked raced — that is what its "Stood
# down" badge cannot say on its own — but it recovered nothing, and the
# "recovered race ×N" badge must not appear on it.
sd="$(render raced-standdown.json)" || { printf 'FAIL - raced-standdown.json did not render:\n%s\n' "$sd"; exit 1; }
assert_contains "a cycle that lost every candidate still reads as stood down" \
  "Stood down" "$sd"
assert_contains "and is marked raced, which 'Stood down' alone does not say" \
  "raced" "$sd"
assert_not_contains "but is never called a recovered race" \
  "recovered race" "$sd"

# --- preclaimed-standdown.json: skipped everything, contended for nothing ------
# A `standdown_cause` of "pre-claimed" (spec 17a's claim-skipped: the cycle's
# own gather had already seen every candidate claimed) is a selection defect,
# not contention — no peer raced this cycle for anything, so neither race
# badge may appear. The row itself survives (its reason text names the
# defect); only the contention markers are withheld.
pc="$(render preclaimed-standdown.json)" || { printf 'FAIL - preclaimed-standdown.json did not render:\n%s\n' "$pc"; exit 1; }
assert_contains "a pre-claimed stand-down still reads as stood down" \
  "Stood down" "$pc"
assert_not_contains "but wears no raced marker — nothing was contended" \
  "↻ raced" "$pc"
assert_not_contains "and no recovered-race badge either" \
  "recovered race" "$pc"

# --- noop-aggregate.json: no-op ticks summarised, never listed (issue #271) ------
# The Publisher holds the */15 cadence's stand-down short-circuits and
# lock-held skips out of the MAX_CYCLES detail list and ships the single O(1)
# `noop_ticks` aggregate instead. The page must render the substantive rows
# it was given plus one summary line — here the aggregate counts more than
# twice the forty slots the list could ever hold — and no line at all for a
# zero aggregate (running.json above) or for a data.js written before the
# field existed (finished.json and the rest carry no `noop_ticks` key).
np="$(render noop-aggregate.json)" || { printf 'FAIL - noop-aggregate.json did not render:\n%s\n' "$np"; exit 1; }
assert_contains "a substantive cycle keeps its ordinary row under the flood" \
  "raise the widget count" "$np"
assert_contains "and so does a none-selected one — a verdict, not a no-op" \
  "no candidate item cleared the gates this cycle" "$np"
assert_contains "one summary line counts what was held out of the list" \
  "+ 87 no-op ticks held out of this list" "$np"
assert_contains "split by kind, so a scheduler stuck on its lock stays visible" \
  "61 stood down, 26 lock-held skips" "$np"
assert_contains "and dates the newest tick — the cadence still showing itself" \
  "newest 5m ago" "$np"
assert_not_contains "a zero aggregate renders no summary line" \
  "no-op tick" "$(render running.json)"
assert_not_contains "nor does a data.js from before the field existed" \
  "no-op tick" "$(render finished.json)"

# --- verdict-quality.json: the Co-Ordinator verdict-quality card (issue #319) ----
# The card exists to answer a question one cycle never can: how often the
# Script rejects a Co-Ordinator verdict (implementation spec 3t/3v), and
# whether that rate is a property of `coordinator_model`. So the rate, its two
# terms, the split by model, and what the fleet spent recovering are each
# asserted — a card that renders a count without the denominator it was
# divided by is the page the issue was filed against.
vq="$(render verdict-quality.json)" || { printf 'FAIL - verdict-quality.json did not render:\n%s\n' "$vq"; exit 1; }
assert_contains "the card leads with the rejection rate" \
  "75% rejected" "$vq"
assert_contains "and names both terms of it, so the denominator is never implied" \
  "3 of 4 corroborated verdicts rejected" "$vq"
assert_contains "a rate at or above half is coloured as a fault, not a warning" \
  'class="badge b-red"' "$vq"
assert_contains "the recovery line names what the rejections cost (spec 3v)" \
  "2 retry engagement(s), 1 item(s) the Script had to pick itself" "$vq"
assert_contains "the counts name the window they were taken over" \
  "11 Co-Ordinator run(s), 3 selected, 6 nothing-selected" "$vq"
assert_contains "and say what bounds that window, so silence is not read as history" \
  "the retained log union" "$vq"
# Split by model: the whole point of the split is that changing
# `coordinator_model` on one node produces separately attributable rates, so
# both models must appear as their own rows with their own figures.
vqflat="$(tr '\n' ' ' <<<"$vq" | tr -s ' ')"
assert_contains "the by-day table heads its columns as counts and a rate" \
  "<th> Day <th> Co-Ord model <th> Runs <th> Selected <th> Nothing selected <th> Corroborated <th> Rejected <th> Rate" \
  "$vqflat"
assert_contains "the model that produced the rejections has its own row" \
  "haiku-4-5" "$vq"
assert_contains "and the model that did not is attributed separately" \
  "sonnet-5" "$vq"
assert_contains "a day/model row with nothing to corroborate shows no rate rather than a zero one" \
  '<td class="mono"> 0 <td class="mono"> 0 <td> <span class="mono muted"> 0 <td class="mono"> — ' "$vqflat"
assert_contains "while a corroborated day with no rejection shows a real zero rate" \
  '<td class="mono"> 1 <td class="mono"> 1 <td> <span class="mono muted"> 0 <td class="mono"> 0%' "$vqflat"
# The example beneath the rate: a rate with no instance is not actionable.
assert_contains "the newest contradiction is shown beneath the counts" \
  "most recent contradiction" "$vq"
assert_contains "with the verdict's own stated reason" \
  "every eligible tech-debt item is recorded void" "$vq"
assert_contains "the Script's machine detail" \
  "the Script found 33 eligible open tech-debt item(s)" "$vq"
assert_contains "and the unaccounted item refs it named" \
  "TD-PPagop-26080801" "$vq"
assert_contains "counted against the eligible set they were drawn from" \
  "Unaccounted items (33 of 33 eligible)" "$vq"
assert_contains "with the display cap stated rather than silently truncating" \
  "… and 31 more" "$vq"
assert_contains "the node that produced it is named, since a fleet has four" \
  "poetic-2" "$vq"
# Requirement 3v means a contradiction is no longer the same thing as a lost
# cycle, and the card must not imply that it is.
assert_contains "the attempt that produced it is named, since a cycle now has two" \
  "attempt 2" "$vq"
assert_contains "and what became of the cycle it happened on" \
  "recovered — the Script picked" "$vq"

# --- the per-band tally (issue #345): which band, not just how often -------------
# Counts, not a rate, ranked most-rejected first as the aggregate already
# sorts it — and a rejection logged before spec 3x's `bands` object existed
# renders under an explicit "unknown" row rather than vanishing.
assert_contains "the per-band table heads its columns as counts, not a rate" \
  "<th> Band <th> Rejected <th> Unaccounted" "$vqflat"
assert_contains "the band with the most rejections leads the table" \
  '<td class="mono"> tech-debt' "$vqflat"
assert_contains "carrying its own rejected and unaccounted counts" \
  '<td class="mono"> tech-debt <td> <span class="badge b-red"> 2 <td class="mono"> 34' \
  "$vqflat"
assert_contains "a second band appears as its own row" \
  "issues" "$vq"
assert_contains "a rejection from before spec 3x lands under an explicit unknown row" \
  '<td class="mono"> unknown <td> <span class="badge b-red"> 1 <td class="mono"> 7' \
  "$vqflat"

# The zero state, which must read as an answer rather than as missing data —
# the distinction the issue asks for explicitly.
vqc="$(render verdict-quality-clean.json)" || { printf 'FAIL - verdict-quality-clean.json did not render:\n%s\n' "$vqc"; exit 1; }
assert_contains "a window with no rejected verdict says so explicitly" \
  "no rejected verdicts in this window" "$vqc"
assert_contains "coloured as the healthy answer it is" \
  'class="badge b-green"' "$vqc"
assert_contains "and still names the denominator, so zero is legible as a rate" \
  "0 of 3 corroborated verdicts rejected" "$vqc"
assert_not_contains "with no contradiction block to imply one happened" \
  "most recent contradiction" "$vqc"
assert_not_contains "nor a per-band table where no data.js key names one" \
  "Unaccounted" "$vqc"

# A page written before the Publisher recorded any of this must say that,
# rather than rendering a clean-looking zero it has no data for.
assert_contains "a data.js from before the aggregate existed reads as missing data" \
  "written by a Publisher that did not record it yet" "$(render finished.json)"

# --- #186: the spend-today card's persisted GMT/local/24h toggle -----------------
# `render`'s optional second argument seeds the harness's localStorage stub, so
# each mode is exercised as a fresh page load would read it back — not by
# simulating the click (out of the harness's tree-building scope; see its own
# header comment), but by asserting what a reload with that choice already
# stored renders. "local" only asserts the label, not the amount: which rows
# fall on today's *local* calendar date depends on the wall-clock moment this
# suite happens to run, so a dollar assertion there would be flaky exactly at
# the reader's local midnight — the deterministic "24h" case below already
# covers the same `recent_costs` arithmetic on a rolling window instead.
assert_contains "with no persisted choice the card defaults to GMT" \
  "today (GMT)" "$out"
# shellcheck disable=SC2016
assert_contains "and shows the Publisher's own GMT-day figure" \
  '$2.15' "$out"

out_24h="$(render finished.json '{"dashboard.spendMode":"24h"}')" || \
  { printf 'FAIL - finished.json (24h spend mode) did not render:\n%s\n' "$out_24h"; exit 1; }
assert_contains "a persisted '24h' choice survives the reload and relabels the card" \
  "last 24h" "$out_24h"
# shellcheck disable=SC2016
assert_contains "and sums only the recent_costs rows within the last 24 hours" \
  '$0.6000' "$out_24h"

out_local="$(render finished.json '{"dashboard.spendMode":"local"}')" || \
  { printf 'FAIL - finished.json (local spend mode) did not render:\n%s\n' "$out_local"; exit 1; }
assert_contains "a persisted 'local' choice relabels the card too" \
  "today (local)" "$out_local"

# Same per-cell check as running.json above, against this fixture's own log
# tail: flattened, since a cell and its text are only adjacent once the
# newlines and indentation the serialiser inserts are gone.
finflat="$(tr '\n' ' ' <<<"$out" | tr -s ' ')"
assert_contains "the review pipeline's single agent is named as the Project Reviewer" \
  '<td class="mono muted"> ockham-container <td class="mono muted"> poetic <td class="mono muted"> project-reviewer' \
  "$finflat"
assert_contains "a pr-ready names the actor that took the PR out of draft" \
  '<td class="mono muted"> poetic-1 <td class="mono muted"> — <td class="mono muted"> reviewer' \
  "$finflat"
assert_contains "the clone step names no actor, being a stage with no agent in it" \
  '<td class="mono muted"> poetic-1 <td class="mono muted"> agent-ops <td class="mono muted"> —' \
  "$finflat"
assert_contains "and a cycle-level event names neither repo nor actor" \
  '<td class="mono muted"> poetic-1 <td class="mono muted"> — <td class="mono muted"> —' \
  "$finflat"
assert_contains "a single-node page's header carries live state itself" \
  "last cycle" "$out"
assert_not_contains "with no fleet strip to duplicate it" \
  'class="cards fleet"' "$out"
# The work-sources panel's tech-debt ledger. A row is the item's own title and
# status, not the ID alone — the whole point of reading the item files — and an
# item whose metadata has not been read yet still appears, as the bare ID.
assert_contains "a tech-debt row names the work, not just its ID" \
  "An active node's state_dir grows without bound" "$out"
# Against the tree flattened to one line: the harness serialises each node on
# its own line at its own depth, so a badge and its text are only adjacent
# once the newlines and indentation are gone.
flat="$(tr '\n' ' ' <<<"$out" | tr -s ' ')"
assert_contains "and carries the status the Co-Ordinator would find" \
  '<span class="badge b-amber"> open ' "$flat"
assert_contains "an item already being worked is badged as such" \
  '<span class="badge b-blue"> in-progress ' "$flat"
assert_contains "each row links its own item file" \
  "blob/main/tech-debt/TD-PPagop-26072801.md" "$out"
assert_contains "an unread item still appears, as the bare ID it always was" \
  "TD-PPagop-26072803" "$out"
assert_contains "the header counts the read items as open and the rest as unread" \
  "2 open tech-debt items (+1 unread)" "$out"
# A fetch cached before the ledger rows carried titles is a "| ID |" string,
# and a --no-github tick carries it forward until the next real fetch.
assert_contains "a ledger row from an older fetch still renders as its ID" \
  "TD-PPfid-26071501" "$out"
assert_not_contains "with the old row's table pipes gone" \
  "| TD-PPfid-26071501 |" "$out"

# --- blocked.json: ordinary vs refinement blocks, and void items -----------------
out="$(render blocked.json)" || { printf 'FAIL - blocked.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "the heading counts every blocked item" \
  "Blocked items (3)" "$out"
assert_contains "and offers to hide the refinement ones" \
  "hide 2 refinement blocks" "$out"
assert_contains "a needs-refinement block carries the refinement badge" \
  "refinement" "$out"
assert_contains "an escalated refinement block links the issue" \
  "#150" "$out"
assert_contains "and says it needs a human" \
  "needs you" "$out"
assert_contains "an ordinary block gives the Enabler's last verdict" \
  "deferred, retry after refinement" "$out"
assert_contains "void items are listed separately, with their own count" \
  "Void items (1)" "$out"
assert_contains "and the evidence for why there is no work" \
  "removed in #144" "$out"
assert_not_contains "a void list inside the row cap offers no see-more control" \
  "See more" "$out"

# --- void-many.json: the void list's two caps ------------------------------------
# The void list is the page's one list that grows without bound while asking
# nothing of the reader — a fleet retires items steadily, and every panel that
# does want an answer sits below it. So it shows ten rows, three lines each,
# and both caps open on demand. The fixture holds twelve with the oldest two
# first in the array, because a row cap only means anything once the list is
# ordered: `void_items` groups by repo and item, so unsorted the ten kept rows
# would be whichever ids happened to sort first.
out="$(render void-many.json)" || { printf 'FAIL - void-many.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "the heading counts every void item, not the rows shown" \
  "Void items (12)" "$out"
assert_contains "the tenth-newest is the last row inside the cap" \
  "the tenth-newest void" "$out"
assert_not_contains "an item past the cap is not rendered, however early it sits in the data" \
  "TD-PPagop-26071801" "$out"
assert_not_contains "nor the other one past it" \
  "TD-PPagop-26071812" "$out"
assert_contains "a control offers the rest, counted" \
  "See more — 2 older items" "$out"
assert_contains "each void row is capped in height" \
  'class="clip"' "$out"
assert_contains "and is clickable, to open it to its full text" \
  'class="clickable"' "$out"

# --- work-sources.json: the per-repo `nice` badge --------------------------------
# The rendering half of the pipeline spec's requirement 3. What makes this
# worth a test rather than a look is that both of its silences are load-bearing
# and neither shows up on the page that has them: a repo at 0 (or with no key)
# must render exactly what it rendered before the badge existed, and the note
# must say whose ordering this is — the page's one per-repo surface sits under
# a heading reading "what the Co-Ordinator sees", and a `nice` is precisely
# what the Co-Ordinator is not shown.
out="$(render work-sources.json)" || { printf 'FAIL - work-sources.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "a negative nice renders its badge on that repo" \
  "nice -5" "$out"
assert_contains "coloured as a promotion rather than a warning" \
  'class="badge b-blue"' "$out"
assert_contains "and names the weighting it actually buys" \
  "staleness age ×3.05" "$out"
assert_contains "in the direction a negative value means" \
  "so it gets earlier attention" "$out"
assert_contains "a positive nice renders its own badge" \
  "nice 3" "$out"
assert_contains "muted rather than promoted" \
  'class="badge b-grey"' "$out"
assert_contains "with the reciprocal weighting" \
  "staleness age ×0.51" "$out"
assert_contains "and the opposite direction" \
  "so it gets later attention" "$out"
assert_contains "the badge disclaims starvation, which is the first thing an operator will ask" \
  "never starves a repo" "$out"
assert_contains "the panel note names the Script as what acts on a nice" \
  "the Script weights its staleness age" "$out"
assert_contains "and says plainly that the Co-Ordinator is not told" \
  "The Co-Ordinator is never told these values" "$out"
# The first repo in the fixture carries no `nice` key at all and must be
# indistinguishable from one configured before the feature existed.
assert_not_contains "a repo with no nice key renders no badge for it" \
  "nice 0" "$out"

# A failed source (TD-PPagop-26080201) must not render as a bare zero, which
# would be indistinguishable from a repo that genuinely has none: the fixture
# fails poetic-fiddle's `issues` read and marks its `tech_debt` a legitimate
# 404, so the two must render differently from each other and from a repo
# (poetic, agent-ops) whose fixture carries no `state` at all, which must
# still render exactly as it did before this field existed.
assert_contains "a failed source reads 'couldn't read', never a false zero" \
  "couldn't read open issues" "$out"
assert_contains "a legitimate absence (a repo with no register) still reads as an honest zero" \
  "0 open tech-debt items" "$out"
assert_not_contains "and never shows the couldn't-read marker for it" \
  "couldn't read tech-debt" "$out"
assert_contains "a repo with no state field at all renders exactly as before" \
  "0 security findings" "$out"

# --- work-sources-neutral.json: every repo at 0 or absent ------------------------
# The whole-page form of the same silence, and the one that matters to a fleet
# that has set no `nice` anywhere: no badge and no note — the page this file
# rendered before the feature shipped, which is the same omit-never-empty
# contract lib/repo-order.sh keeps for the fingerprint, for the same reason.
out="$(render work-sources-neutral.json)" || { printf 'FAIL - work-sources-neutral.json did not render:\n%s\n' "$out"; exit 1; }

assert_not_contains "an explicit 0 renders no badge, and no repo's absence renders a note" \
  "nice" "$out"
assert_contains "while the work-source panel it sits in renders as it always did" \
  "Poetic-Poems/agent-ops" "$out"

# --- merge-queue.json: queued badge, dequeued warning (agent-ops#375, D17) --------
# The Publisher's own `queued`/`dequeued` fields (test/publish-dashboard.test.sh
# covers how it derives them) driving the open-PR table's badges: #500 is
# currently queued, #501 fell out of the queue without merging, #502 has never
# been near the queue and must render exactly as it did before this feature
# existed.
out="$(render merge-queue.json)" || { printf 'FAIL - merge-queue.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "a currently-queued pull request carries the queued badge, distinct from ready" \
  'class="badge b-purple" title="in GitHub' "$out"
assert_contains "a dequeued-unmerged pull request carries a warning badge beside its ready badge" \
  'class="badge b-amber" style="margin-left:6px" title="removed from the merge queue' \
  "$out"
assert_contains "the dequeued warning names the state a human must act on" \
  "dequeued" "$out"
assert_contains "the same pull request keeps its ordinary ready badge underneath the warning" \
  'class="badge b-blue"' "$out"
assert_contains "a pull request never near the queue renders exactly as before this feature" \
  "never been near the queue" "$out"
assert_contains "an enqueued-then-dequeued pull request belongs in the attention banners too" \
  "removed from the merge queue without merging" "$out"

# --- the cost section's column flow and its reading order (issue #330) -----------
# The cost blocks share one multi-column container, so the *split* between
# columns is the browser's to choose by height and is not assertable here — no
# layout, by design. What is assertable is the thing that choice rests on: a
# multi-column flow fills each column top-to-bottom in document order, so
# document order is the visual order, and the blocks appended out of turn
# would reorder the page silently while every existing assertion still passed.
# The notes' depth is checked with them because they are the blocks that
# moved: the first used to be a paragraph appended after the section, and
# only counts as a block of the flow if it is inside the container.
#
# finished.json carries no `counts.stage_models` (issue #529 predates every
# fixture but its own), so the two model-used pies render — reading `[]` off
# an absent aggregate, same as any other pre-#529 fixture — but the third
# costnote naming their retained-log window does not: that costnote only
# exists once the Publisher actually ships the aggregate.
out="$(render finished.json)" || { printf 'FAIL - finished.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "the cost blocks share one multi-column container" \
  '<div class="costgrid">' "$out"
assert_not_contains "and not the fixed two-column grid it replaced" \
  '<div class="two">' "$out"
assert_contains "a second cost note names the page's fixed currency (issue #438)" \
  "US dollars (USD)" "$out"

# Bounded by the next section's own heading, since all `p.costnote` markers
# now occur inside the grid and a range ending at the first would silently
# drop the rest.
cost_order="$(printf '%s\n' "$out" \
  | sed -n '/<div class="costgrid">/,/Recent log events/p' \
  | grep -oE 'Est\. token cost by (day|model|actor)|Model used . (Implementer|Reviewer)|class="costnote"' \
  | tr '\n' ' ')"
assert_eq "the cost blocks flow in reading order — day, model, actor, both cost notes, then the two model-used pies" \
  'Est. token cost by day Est. token cost by model Est. token cost by actor class="costnote" class="costnote" Model used — Implementer Model used — Reviewer ' \
  "$cost_order"

# The serialiser indents two spaces per level, so six spaces is a child of the
# container (four) inside the section (two) — the depth the three chart blocks
# sit at, and no longer that of a paragraph appended beside the section.
assert_contains "the notes are blocks of that container, not paragraphs after the section" \
  '      <p class="costnote">' "$out"

# --- cost-window.json: the model/actor charts' own time-frame selector (#334) ----
# `cost_rows` carries four un-summed rows: two "today", one three days back,
# one forty days back (well past a 30-day window but still inside the
# fixture's own default "Lifetime" reading). The control re-aggregates these
# client-side per `dashboard.costWindow`, so each persisted choice below is a
# distinct render rather than a click this tree-building harness cannot
# simulate — the same technique the spend-mode assertions above already use.
out="$(render cost-window.json)" || { printf 'FAIL - cost-window.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "the selector renders above the model/actor charts, labelled to name them" \
  "Time frame (model, actor & model-used charts)" "$out"
assert_contains "with no persisted choice it defaults to the lifetime option" \
  '<option value="all" selected="">' "$out"
# shellcheck disable=SC2016
assert_contains "and the model chart sums every row, including the 40-day-old one" \
  '$11.00 · 2' "$out"

# The fixture's oldest row is 40 days back, so `cost_rows` spans 41 days —
# past the 30-day option but short of 90. A reader picking "90 days" here
# would silently get whatever's inside those 41 days rather than the 90 they
# asked for (the same trap PR #467's review flagged: the option's label
# promises a span the data can't back), so it's disabled; every option the
# 41-day span genuinely covers stays selectable.
assert_contains "an option promising more history than cost_rows actually spans is disabled" \
  '<option value="90" disabled="">' "$out"
assert_not_contains "while an option within that span is not — no bare 'disabled=\"\"' on 30 days" \
  '<option value="30" disabled="">' "$out"
assert_not_contains "nor on 7 days" \
  '<option value="7" disabled="">' "$out"
assert_not_contains "nor on 1 day" \
  '<option value="1" disabled="">' "$out"
assert_not_contains "and never on Lifetime, which has no span to exceed" \
  '<option value="all" disabled="">' "$out"

out_1d="$(render cost-window.json '{"dashboard.costWindow":"1"}')" || \
  { printf 'FAIL - cost-window.json (1-day window) did not render:\n%s\n' "$out_1d"; exit 1; }
assert_contains "a persisted '1' choice marks that option selected" \
  '<option value="1" selected="">' "$out_1d"
# shellcheck disable=SC2016
assert_contains "and the model chart sums only today's rows" \
  '$2.00 · 1' "$out_1d"
# shellcheck disable=SC2016
assert_not_contains "excluding the 40-day-old row's amount" \
  '$9.00' "$out_1d"

out_7d="$(render cost-window.json '{"dashboard.costWindow":"7"}')" || \
  { printf 'FAIL - cost-window.json (7-day window) did not render:\n%s\n' "$out_7d"; exit 1; }
# shellcheck disable=SC2016
assert_contains "a 7-day window includes the 3-day-old row alongside today's" \
  '$1.50 · 2' "$out_7d"
# shellcheck disable=SC2016
assert_not_contains "but still excludes the 40-day-old row" \
  '$9.00' "$out_7d"

# A persisted choice the control has since disabled (the fixture spans 41
# days, short of "90 days") falls back to Lifetime for both the selected
# `<option>` and the chart totals, rather than rendering a `<select>` whose
# marked-selected option is simultaneously `disabled` — a state the control
# itself would never let a reader reach by clicking.
out_90d="$(render cost-window.json '{"dashboard.costWindow":"90"}')" || \
  { printf 'FAIL - cost-window.json (90-day window) did not render:\n%s\n' "$out_90d"; exit 1; }
assert_contains "a disabled persisted choice falls back to Lifetime as the selected option" \
  '<option value="all" selected="">' "$out_90d"
assert_not_contains "not to the disabled '90 days' option itself" \
  '<option value="90" selected="">' "$out_90d"
# shellcheck disable=SC2016
assert_contains "and the model chart falls back to the same lifetime total the default render shows" \
  '$11.00 · 2' "$out_90d"

# --- cost-window-actor-split.json: windowed by_actor counts transcripts, not
# model touches (issue #536) --------------------------------------------------
# One transcript split into two `cost_rows` entries — one per model it
# touched — sharing a single `cycle` id. Outside the time-frame selector
# (`by_actor` itself, read straight off the Publisher) this was never wrong;
# the risk is only in the client's own windowed re-aggregation off `cost_rows`,
# which used to count rows rather than transcripts and would have doubled this
# one transcript's "stage run(s)" figure the moment a reader left "Lifetime".
out_split="$(render cost-window-actor-split.json '{"dashboard.costWindow":"1"}')" || \
  { printf 'FAIL - cost-window-actor-split.json did not render:\n%s\n' "$out_split"; exit 1; }
# shellcheck disable=SC2016
assert_contains "a transcript touching two models counts once under the windowed actor chart" \
  '$3.00 · 1' "$out_split"
# shellcheck disable=SC2016
assert_not_contains "not twice, one per model it happened to touch" \
  '$3.00 · 2' "$out_split"
assert_contains "the windowed model chart still credits each model only its own split" \
  'title="1 stage run(s)"' "$out_split"

# --- stage-models.json: the Implementer/Reviewer "model used" pies (#529) --------
# `counts.stage_models` carries Implementer rows at day 0 (sonnet, opus) and
# day 3 (sonnet), and Reviewer rows at day 3 (sonnet) and day 40 (a model-less
# event, which the Publisher folds into "unknown" rather than dropping). The
# default render (below, no persisted `costWindow`) reads the Publisher's own
# lifetime `by_stage` totals directly — the same "cheap path when untouched"
# `spendByModel()` already follows — so it sees every row including day 40's.
out="$(render stage-models.json)" || { printf 'FAIL - stage-models.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "the time-frame label now names the model-used charts too" \
  "Time frame (model, actor & model-used charts)" "$out"
assert_contains "the Implementer pie heading is present" \
  "Model used — Implementer" "$out"
assert_contains "the Reviewer pie heading is present" \
  "Model used — Reviewer" "$out"
assert_contains "Lifetime sums the Implementer rows straight off by_stage: 3 sonnet" \
  "75% · 3" "$out"
assert_contains "and 1 opus" \
  "25% · 1" "$out"
assert_contains "a stage-end with no readable model counts under unknown rather than being dropped" \
  "unknown" "$out"
assert_contains "the unknown slice still carries its own share and count" \
  "33.3% · 1" "$out"
assert_contains "full model ids stay in the title= attribute, matching spendByModel()" \
  'title="claude-sonnet-5-20260101"' "$out"
assert_contains "the caption states failed runs and retries both count" \
  "including runs that failed and retries" "$out"
assert_contains "and reports the aggregate's own retained-log window" \
  "These two pies read the retained log directly" "$out"

# A 1-day window drops every row but day 0's: Implementer still has one of
# each model (50/50), but Reviewer's only row that day was never logged (its
# sonnet row is day 3, its unknown row day 40) — an empty stage in the
# selected window renders the .empty panel, not a blank or a zero-slice pie.
out_1d="$(render stage-models.json '{"dashboard.costWindow":"1"}')" || \
  { printf 'FAIL - stage-models.json (1-day window) did not render:\n%s\n' "$out_1d"; exit 1; }
assert_contains "a 1-day window re-aggregates the Implementer pie to that day alone" \
  "50% · 1" "$out_1d"
assert_contains "a stage with nothing in the selected window renders the empty panel" \
  "No Reviewer runs recorded in this time frame." "$out_1d"

# A 7-day window pulls in day 3 for both stages, so Reviewer now has its
# sonnet row (day 40's unknown row is still outside it) and Implementer's
# split returns to the lifetime ratio.
out_7d="$(render stage-models.json '{"dashboard.costWindow":"7"}')" || \
  { printf 'FAIL - stage-models.json (7-day window) did not render:\n%s\n' "$out_7d"; exit 1; }
assert_contains "a 7-day window includes the day-3 Implementer row alongside day 0's" \
  "75% · 3" "$out_7d"
assert_contains "and gives the Reviewer pie its one (day-3) model, at 100%" \
  "100% · 2" "$out_7d"
assert_not_contains "still excluding the day-40 unknown row" \
  "unknown" "$out_7d"

# --- switch-scope-*.json: which switch a node card is actually claiming ----------
# A fleet-wide --disable writes a local record on the node that issued it as
# well as the fleet flag (implementation spec 2.3a). Before that record was
# tagged `scope`, the issuing node alone wore the amber `disabled` badge while
# its equally-stopped peers wore none — a fleet-wide stand-down rendering as a
# fault peculiar to one node, on the page whose whole job here is to say which
# is which.
out="$(render switch-scope-mirror.json)" || { printf 'FAIL - switch-scope-mirror.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "a set fleet flag raises the fleet banner" \
  "Fleet switch is set" "$out"
assert_not_contains "and its local mirror does not raise a second banner beside it" \
  "This node is disabled" "$out"
assert_not_contains "nor badge the node that issued it as node-scoped" \
  'node-scoped disable: “resize the VM”' "$out"
assert_contains "while a peer's genuine --this-node disable still badges" \
  'node-scoped disable: “editing lib/”' "$out"

# The orphan: --enable on a peer clears the fleet flag but cannot reach this
# node's file, so this node alone stays down under a decision lifted
# elsewhere. Nothing else on the page accounts for that, which is exactly why
# the banner and badge have to.
out="$(render switch-scope-orphan.json)" || { printf 'FAIL - switch-scope-orphan.json did not render:\n%s\n' "$out"; exit 1; }

assert_not_contains "with the fleet flag cleared there is no fleet banner" \
  "Fleet switch is set" "$out"
assert_contains "but the surviving mirror does raise this node's switch banner" \
  "This node is disabled" "$out"
assert_contains "saying what it is, rather than blaming a decision nobody made" \
  "left over from a fleet-wide disable that has since been cleared" "$out"
assert_contains "and the node's own card badges it, naming the command that clears it" \
  "this node is standing down alone" "$out"

# A genuine node-scoped disable (issue #514): the re-enable advice must name
# --this-node, since a bare --enable clears the *fleet* switch and leaves this
# node's own record — and the node — still down.
out="$(render switch-scope-node.json)" || { printf 'FAIL - switch-scope-node.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "a genuine node-scoped disable's banner says this node, not the pipeline" \
  "This node is disabled" "$out"
assert_contains "and its re-enable advice names --this-node" \
  "needs \`agent-cycle.sh --enable --this-node\`" "$out"
assert_not_contains "never the bare --enable, which clears the fleet switch instead" \
  "needs \`agent-cycle.sh --enable\`" "$out"

# --- The merge-autonomy kill switch banner (D18 issue #576) -----------------
# Narrower than the fleet switch above: cycles keep running, only landing is
# forced back to `human` fleet-wide, so it must never be folded into "every
# node stands down" and must render even when neither the fleet switch nor
# any node's own switch is set.

out="$(render merge-autonomy-kill.json)" || \
  { printf 'FAIL - merge-autonomy-kill.json did not render:\n%s\n' "$out"; exit 1; }
assert_contains "an engaged kill switch raises its own banner" \
  "Merge-autonomy kill switch is engaged" "$out"
assert_contains "  ... naming the reason" \
  '“the App is misbehaving”' "$out"
assert_contains "  ... and who set it" \
  "set by warwickallen" "$out"
assert_contains "  ... and the command that clears it" \
  "agent-cycle.sh --restore-merge-autonomy" "$out"
assert_not_contains "  ... never claiming every node stands down (that is the fleet switch's banner)" \
  "Fleet switch is set" "$out"
assert_not_contains "  ... nor the pipeline-wide switch banner" \
  "This node is disabled" "$out"

out="$(render merge-autonomy-kill-failclosed.json)" || \
  { printf 'FAIL - merge-autonomy-kill-failclosed.json did not render:\n%s\n' "$out"; exit 1; }
assert_contains "a fail-closed synthesis (state repo unreachable, no cache) still raises the banner" \
  "Merge-autonomy kill switch is engaged" "$out"
assert_contains "  ... explaining it could not be confirmed clear, not naming an operator" \
  "state repo unreachable and no cached copy of the kill switch" "$out"
assert_not_contains "  ... and never offers the clear command for a cause no command can fix" \
  "agent-cycle.sh --restore-merge-autonomy" "$out"

out="$(render landings-quiet.json)" || \
  { printf 'FAIL - landings-quiet.json did not render:\n%s\n' "$out"; exit 1; }
assert_not_contains "a fixture with no merge_autonomy_kill flag at all raises no banner" \
  "Merge-autonomy kill switch is engaged" "$out"

# --- The autonomous-landing digest (D18 WI-8, agent-ops#411) ----------------
# Risk 6 of the autonomy investigation accepts unattended merges on the
# stated condition that this panel is the asynchronous audit replacing the
# synchronous gate. So the assertions below are about what it refuses to
# hide, not merely that it draws: an unexplained landing, the refusals that
# say whether the gate is running at all, and a payload that failed to
# assemble reading differently from a quiet night.
out="$(render landings.json)" || { printf 'FAIL - landings.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "the landings section names its own window" \
  "Autonomous landings (last 24 h)" "$out"
assert_contains "a landed pull request shows the title joined from GitHub" \
  "tidy the hygiene ledger" "$out"
assert_contains "  ... and the Approver tier that authorised it" \
  "complex" "$out"
# The join is by pr_url against the newest verdict at or before the arm. A
# landing whose verdict cannot be found is the most important row here, so it
# must render with "unknown" rather than be dropped for want of a join.
assert_contains "a landing with no locatable Approver verdict still appears, marked unknown" \
  "unknown" "$out"
# Two landings beside forty refusals is a classifier holding the line; two
# beside none may be a gate that is not running. The digest must not be able
# to show the first while looking like the second.
assert_contains "refusals in the same window are reported, grouped by reason" \
  "refused in the same window" "$out"
assert_contains "  ... naming each refusal class and its count" \
  "ineligible ×2" "$out"
# D18 issue #576: a kill-switch refusal groups under its own tag, distinct
# from an ordinary ineligible/unknown refusal (acceptance criterion 4) —
# `kill-switch:` is the tag `landing_autonomy_refusal_reason`
# (lib/landing.sh) prefixes onto the reason so this grouping (byReason,
# dashboard/index.html) picks it out cleanly rather than folding it into a
# one-off full-sentence group.
assert_contains "  ... and a kill-switch refusal groups under its own tag" \
  "kill-switch ×1" "$out"
assert_contains "the merge budget shows consumed against the cap" \
  "agent-ops 2/8" "$out"
assert_contains "  ... and an unlimited repository reads as unlimited, never as 0" \
  "poetic 0/∞" "$out"

# A quiet window is a real, reportable nothing — and still accounts for the
# budget, so "nothing landed" and "nothing could land" stay distinguishable.
out="$(render landings-quiet.json)" || { printf 'FAIL - landings-quiet.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "a genuinely quiet window says so" \
  "Nothing landed autonomously in the last 24 h." "$out"
assert_contains "  ... and still reports the budget, so a quiet night is not mistaken for a stalled one" \
  "agent-ops 0/8" "$out"
assert_not_contains "  ... and claims no refusals it did not have" \
  "refused in the same window" "$out"

# The failure this panel exists to not commit: rendering an unassembled
# payload as a quiet night. `armed: null` is that state, and it must read as
# an outage, not as an absence of landings.
out="$(render landings-degraded.json)" || { printf 'FAIL - landings-degraded.json did not render:\n%s\n' "$out"; exit 1; }

assert_contains "an unassembled digest says it could not be assembled" \
  "could not be assembled this tick" "$out"
assert_not_contains "  ... and never reads as a quiet night instead" \
  "Nothing landed autonomously" "$out"

# --- doctor-*.json: the unattended pass's own status.doctor (agent-ops#543) --
# status.doctor is THIS node's own most recent hourly `doctor.sh --unattended`
# run, read from state_dir/.doctor-status.json rather than recomputed — null
# until the first hourly pass has run. A `fail` earns a red page-top banner,
# a `warn` an amber one, and both point at the Doctor section, which lists
# every fail/warn line with its own level badge.
out="$(render switch-scope-node.json)" || { printf 'FAIL - switch-scope-node.json did not render:\n%s\n' "$out"; exit 1; }
assert_contains "no unattended pass yet says so, in the Doctor section" \
  "No unattended doctor pass has run on this node yet." "$out"
assert_not_contains "and raises no banner about it" \
  "unattended doctor pass found" "$out"

out="$(render doctor-fail.json)" || { printf 'FAIL - doctor-fail.json did not render:\n%s\n' "$out"; exit 1; }
assert_contains "a fail verdict raises a red banner naming the count" \
  "unattended doctor pass found 1 failure(s)" "$out"
assert_contains "the Doctor section lists the failing line with a fail badge" \
  "acme-org/target-repo is archived" "$out"
assert_contains "  ... and the warning line too, alongside it" \
  "Priority field is readable but is missing" "$out"

out="$(render doctor-warn.json)" || { printf 'FAIL - doctor-warn.json did not render:\n%s\n' "$out"; exit 1; }
assert_contains "a warn-only verdict raises an amber banner, not a red one" \
  "unattended doctor pass found 1 warning(s)" "$out"
assert_contains "the Doctor section lists the warning line" \
  "no \"autonomous-agent\" label" "$out"

out="$(render doctor-clean.json)" || { printf 'FAIL - doctor-clean.json did not render:\n%s\n' "$out"; exit 1; }
assert_not_contains "a clean pass raises no banner at all" \
  "unattended doctor pass found" "$out"
assert_contains "and the Doctor section says so, with when it last ran" \
  "No failures or warnings on the last unattended pass" "$out"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
