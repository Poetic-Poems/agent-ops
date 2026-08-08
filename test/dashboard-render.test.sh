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
# The log tail's Node / Repo / Actor cell. Three fixed slots read positionally,
# so what each one is claiming does not depend on how many of them the event
# happened to carry — the case that used to make the old "Where" column
# ambiguous, since a lone token could be either the repo or the stage.
assert_contains "the log tail heads its where-column with all three data" \
  "Node / Repo / Actor" "$out"
assert_contains "a stage event names the node it ran on and the actor that ran" \
  "poetic-1 / — / coordinator" "$out"
assert_contains "an event whose actor is named in 'by' rather than 'stage' still names it" \
  "poetic-2 / poetic-fiddle / enabler" "$out"
assert_contains "and a missing node keeps its slot rather than shifting the repo into it" \
  "— / agent-ops / —" "$out"

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
  "implementor" "$out"
# issue #245: a cycle that recovered from a lost claim carries a second badge
# beside its outcome, distinct from the outcome badge itself.
assert_contains "a recovered race is marked, beside its outcome badge" \
  "raced" "$out"
assert_eq "and no other cycle in the fixture is marked raced" "1" \
  "$(grep -o 'raced' <<<"$out" | wc -l)"

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

assert_contains "the review pipeline's single agent is named as the Project Reviewer" \
  "ockham-container / poetic / project-reviewer" "$out"
assert_contains "a pr-ready names the actor that took the PR out of draft" \
  "poetic-1 / — / reviewer" "$out"
assert_contains "the clone step names no actor, being a stage with no agent in it" \
  "poetic-1 / agent-ops / —" "$out"
assert_contains "and a cycle-level event names neither repo nor actor" \
  "poetic-1 / — / —" "$out"
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

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
