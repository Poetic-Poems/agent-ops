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
# No network. Needs node, which the image carries for the Claude CLI; absent,
# the file skips with a note rather than failing, as the record asks for and
# as test/render-crontab.test.sh does for supercronic.
#
# Run directly: ./test/dashboard-render.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$SCRIPT_DIR/test/dashboard-render-harness.js"
FIXTURES_DIR="$SCRIPT_DIR/test/fixtures/dashboard-data"

failures=0

if ! command -v node >/dev/null 2>&1; then
  printf 'ok   - node not installed here; CI runs this suite in-image\n\nall assertions passed\n'
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

render() {  # render <fixture>
  node "$HARNESS" "$FIXTURES_DIR/$1"
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
  "1 of 2 nodes running" "$out"
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
