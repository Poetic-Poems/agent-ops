# Tech debt

Deferred work and known gaps in agent-ops. Record an entry here whenever you
defer something, rather than leaving it only in a commit message or in chat.
Keep entries short and dated. Live items live under the "Current Items" heading
as `### <id> <title>` sections. Once an issue has been resolved, remove its
`### <id> <title>` section from Current Items below — but never remove its row
from the Ledger table at the bottom of this file; see "Ledger" below.

Format:
```
### <id> <short title>

A description of what, why it matters, where, and a suggested fix.
```
Where `<id>` is a literal "TD" then the date followed by a zero-padded
sequential number (starting at 1 for the first entry of a day). I.e.:
**TD*YYMMDDNN***. `NN` is one more than the highest `NN` already used for that
date **in the Ledger table**, not just what's currently visible above it — a
resolved entry's body is removed, but its Ledger row stays forever, so the
Ledger (not memory or scrollback) is the source of truth for the next free ID.
Compute it with `scripts/next-tech-debt-id.pl --ref origin/main` (after a
`git fetch origin`) rather than counting by hand — the `--ref` makes the
allocation reflect the shared state instead of a possibly stale checkout. It
still cannot see IDs allocated on unmerged branches, so also skim open pull
requests and `td/*` branches when filing.

IDs are only unique within this repository: sister repositories allocate from
the same date-based sequence, so the bare ID may exist in several of them.
When referring to an item anywhere outside this repository (a sister repo's
docs, a cross-repo PR, chat), qualify it with the repo name — e.g.
`agent-ops TD26072001`.

## Claiming an item

This repository is worked by concurrent agents: autonomous and interactive
sessions may pick up items at the same time, so a claim must be checked and
taken against the shared state, never against what a local checkout happens
to say. Before starting work on an open item:

1. `git fetch origin`, then confirm the item's Ledger row is `open` (not
   `in-progress`) **as of `origin/main`** — e.g. via
   `perl scripts/get-tech-debt-record.pl --ref origin/main <id>`.
2. Confirm nobody holds a claim: `git ls-remote origin "refs/heads/td/<id>"`
   must print nothing, and skim open pull requests for the ID (which also
   catches claims made on unconventionally named branches).
3. Create the claim branch, named exactly **`td/<id>`**, from `origin/main`;
   flip the item's Ledger row Status to `in-progress`; commit and push. The
   branch name is the claim lock: git refuses the push if the branch already
   exists, so a rejected push means another agent won the race — abandon
   quietly; never force-push over it.
4. Open a **draft** pull request right away — before the fix is finished — so
   `gh pr list` shows the claim too. The Ledger status flip can be its first
   commit.
5. Do the work, pushing further commits to the same branch/PR.
6. Once verified, flip the Ledger row to `resolved` (fill in `Resolved` and
   `Ref`), remove the entry's `### <id>` section from Current Items, and mark
   the PR ready for review.

If a claim is abandoned, close the draft PR and delete the `td/<id>` branch —
that releases the lock. The in-progress flip only ever lived on the branch,
so `main`'s Ledger still says `open` and nothing needs reverting.

## Current Items

The open and in-progress items, each as a `### <id> <title>` section. This
heading is permanent: when there are no current items it stays here (empty), so
it is always obvious where a new item's body belongs.

<!-- Add new items directly below, as `### <id> <title>` sections. -->

### TD26072604 Refinement blocks inherit the ordinary Enabler threshold

A refinement block becomes Enabler-eligible after
`enabler_after_coordinator_cycles`, like any other block (requirement 35a).
The inheritance was deliberate — the delay leaves room for a human to refine
the item first, and the Co-Ordinator's cheap re-check can clear a refinement
block whose condition has demonstrably been met — but the two cases age
differently: an ordinary block can be cleared by the world at any moment,
while a refinement block waits on the Enabler and nothing else. Whether
refinement deserves its own threshold — sooner, because waiting establishes
nothing a human has not already; or later, with a larger
`refinement_max_per_engagement`, because batching spends the expensive stage
better — is a tuning question the soak should answer, not a default to guess
now.

Fix: a `refinement_after_coordinator_cycles` config key defaulting to
`enabler_after_coordinator_cycles`'s value, applied in the eligibility rule
where `kind` is already to hand; pick the shipped default from observed fleet
behaviour once the day-one backlog of previously silent items has drained.

Filed 2026-07-26, deferred from #84.

### TD26072606 Nothing tests the dashboard page's JavaScript

`test/` covers the Publisher thoroughly and the page not at all. The ~1,265
lines of inline JavaScript in `dashboard/index.html` — every panel, badge,
filter and the in-place refresh — have no automated test of any kind, so the
only thing
standing between a rendering bug and an operator is someone opening the page and
recognising that what it says is wrong. That is a weak guard precisely where the
page is most useful, because the reader has no independent view of the state to
check it against: a badge that says the wrong thing confidently reads exactly
like one that says the right thing. `docs/DASHBOARD-SPEC.md`'s verification list
asks for a headless render with no thrown errors, which catches a page that
breaks and nothing about a page that lies.

The Outcome column's "Ended" on a running cycle (#94) is what this costs. It
shipped, and stayed shipped, because no test could have caught it and reading
`cycle_json`'s ladder in isolation makes it look correct — the bug only exists
in the gap between a rule written for finished cycles and a column that renders
unfinished ones. A test naming the case would have failed the day it was written.

Fix: a `test/dashboard-render.test.sh` in the repository's own idiom — bash,
asserting on output — that feeds fixture `DASHBOARD_DATA` files through the
page's script and greps the rendered result for the cells under test. It needs a
DOM, and neither a browser nor jsdom is a dependency this repository should take
on for it; a ~50-line stub (`createElement`/`createTextNode`/`appendChild`, a
serialiser) run under `node` is enough for panels that only ever build trees,
which is all of them. Guard it the way `render-crontab.test.sh` guards
supercronic — skip with a printed note when `node` is absent — so the suite
still passes on a host without it.

Two things to settle when writing it. Fixtures should be checked-in JSON rather
than generated, except for timestamps, which have to be relative to now or every
"3m ago" assertion rots. And the stub is a maintenance liability if it grows to
chase the page: keep it to the tree-building subset and let a test that needs
more be the argument for a real headless browser in CI instead.

That argument now has one live example. #96's pull-request hover card is the
page's first behaviour that is not tree-building: it turns on pointer and focus
events, measures an element's box, and positions itself against the viewport.
None of that is reachable from the stub above, so it is worth deciding
deliberately whether this entry's fix covers it or stops short of it, rather
than discovering the gap when the card lands in the wrong place. Until then the
card is guarded only by the headless render of the verification list — which,
as above, catches a page that breaks and nothing about a page that lies.

Filed 2026-07-26, out of #94; scope noted from #96.

### TD26072801 A still-valid block is re-read every cycle once its issue's thread has moved

Requirement 18a (#109) makes the Co-Ordinator re-read a blocked GitHub issue
whenever the issue's `updated_at` is newer than the `ts` of the
`attempt-failed` event that blocked it. The block's `ts` moves only on a
re-block, and the Co-Ordinator has no cross-cycle memory in which to record
"re-checked at T; still holds" — so once a comment lands that does *not* clear
the block, every later cycle that runs a Co-Ordinator re-reads the whole
thread and re-judges the same evidence, until the block finally clears. The
review on #109 flagged this as a deliberate trade-off rather than a defect:
the check fails safe (it reads too often; it never misses evidence), and the
cost is one `gh issue view --comments` plus the tokens to re-judge, per such
issue, per cycle that runs a Co-Ordinator at all.

Two bounds keep the loop's population small, both worth re-reading before
pricing this higher. Cross-references do not move `updated_at`, so an Enabler
escalation that links to the blocked issue does not enrol it — TD26072605
ruled this out for pull requests against poetic#92, and the same holds for
issues (poetic#96 and poetic#97 each carry a latest `cross-referenced`
timeline event *later* than their `updated_at`, measured 2026-07-28). And the
needs-refinement projection cannot self-trip the check, because the Script
applies the label *before* writing the `attempt-failed` event, which leaves
the label's `updated_at` bump behind the block's `ts`. What remains is
exactly: a genuine comment that fails to clear its block.

Fix: give the next cycle a marker to compare against, the way requirement
35a's `enabler-examined` bounds the Enabler. The Co-Ordinator's work order
grows a field for "re-checked, still holds" (bare item ids, like `unblocked`);
the Script logs each as a `recheck-clean` event; the blocked extract carries
the newest such `ts` alongside the block's own; and requirement 18a compares
`updated_at` against the later of the two. Two traps when building it: do not
re-emit `attempt-failed` as the marker — a fresh block moves *B* forward and
resets requirement 35a's Enabler clock, so a mere confirmation would delay
escalation — and do not move the blocked entry's existing `ts` for the same
reason; the marker must be a separate timestamp that only the 18a comparison
reads. The spec (requirements 18a and 20, and the work-order and
blocked-extract descriptions) travels in the same PR.

Filed 2026-07-28, from the review discussion on #109.

### TD26072802 A stage with an empty result silently drops its whole cycle from the dashboard

`scripts/publish-dashboard.sh`'s detail-window assembly (`stage_json`,
pre-TD26072201; now the `extract_status`/`build_stage` jq port that replaced
it) treats a stage's extracted `.result` text as "unparseable" whenever it is
empty or whitespace-only — and an unparseable stage does not just render with
a blank status, it drops the **whole cycle** from `.cycles` on the dashboard,
silently.

This was not a deliberate design choice; it fell out of a shell quirk. The
pre-TD26072201 code built each stage's JSON via
`jq -n --argjson status "$status_json" …`, where `$status_json` came from
`extract_status_json`. That function's first move is `jq empty <<<"$text"`,
and `jq empty` on whitespace-only input (which is what an empty `$text`
becomes once `<<<` appends its trailing newline) succeeds trivially with no
output — so `jq -c '.' <<<"$text"` right after it also prints nothing, and
`status_json` ends up the empty string rather than the literal `"null"` every
other unparseable case falls through to. `--argjson status ""` is invalid
JSON, so the enclosing `jq -n` call for that stage — and, since cycle_json
passes each stage straight through as its own `--argjson`, the whole cycle's
`jq -n` call — fails outright, leaving that cycle's JSON unparseable and
excluded by the `jq -e . "$cf"` check in the assembly loop. Confirmed by
direct reproduction: a well-formed envelope with `"result":""` disappears
from `.cycles` exactly like a torn envelope does, even though nothing about
it failed to run.

TD26072201's jq port (`extract_status` in `scripts/publish-dashboard.sh`)
preserves this behaviour on purpose — marked `ok:false` and commented in
place — rather than fixing it as a drive-by change bundled with an unrelated
performance rewrite; retiring it is its own review-sized change with its own
test.

Fix: decide what a genuinely empty stage result should mean (most likely:
render the stage with `status: null` like any other unparseable text, and
never let one stage's content silently take its cycle's row off the page),
change `extract_status` (and, for symmetry, agent-cycle.sh's
`extract_json_result`, which shares the same straight-parse-else-fenced-block
algorithm per DASHBOARD-SPEC.md) accordingly, and add a
`test/publish-dashboard.test.sh` case with a well-formed envelope whose
`result` is `""` asserting the cycle still renders.

Filed 2026-07-28, from TD26072201.

### TD26072901 acquire_lock trusts a pid across container incarnations

Both pipelines' `acquire_lock` (agent-cycle.sh requirement 1, review-cycle.sh
R2) judge a leftover lock with `kill -0` in their own PID namespace. On a
containerised node that namespace is the container's, and a lock can outlive
its container: a roll that lands on the pre-update hook's one-minute timeout,
an OOM kill, or a manual `down` mid-cycle leaves `lock.json` on the `state`
volume while the container that minted its pid is replaced. The next
incarnation's `kill -0` then answers about the wrong process — the exact
namespace confusion #130 fixed in the watchtower hook, still present in the
writers. Two wrong outcomes: an unrelated process holding the same number
makes a fresh leftover lock read as a live cycle, logging `cycle-skipped`
until the lock goes stale (up to 4h/6h of a node running no cycles); and the
stale-takeover path group-kills whatever innocent pgid that number resolves
to. Low probability — a container's pid space is small and the number must
collide — but the second outcome kills something at random when it hits.

Fix: locks now record the writer's `host` (#130). Only the writer container
ever writes a given state volume's locks, so a lock whose `host` differs from
`$HOSTNAME` was written by a dead incarnation by construction: `acquire_lock`
can take it over immediately — no `kill -0`, no group kill, keep the
`warning` log. Same edit in both cycle scripts; requirement 1 and R2 travel
in the same PR. The hook needs no change: it already honours a foreign lock
only until the next cycle rewrites it, and this fix shortens exactly that
window.

Filed 2026-07-29, from the #130 fix.

## Ledger

Every tech-debt ID ever allocated — open, in-progress, resolved, or not-debt —
is listed here forever, in ID order. This is what makes numbering unambiguous:
the next free ID for a given date is one more than the highest `NN` seen below
for that date, regardless of whether the corresponding entry still has a body
above.

| ID | Title | Status | Resolved | Ref |
|----|-------|--------|----------|-----|
| TD26071401 | Usage-limit detector misses weekly & spend-limit phrasing; no graceful stand-down | resolved | 2026-07-14 | #11 |
| TD26072001 | shellcheck not clean at info level on two scripts | resolved | 2026-07-20 | #38 |
| TD26072002 | The node image is amd64-only | resolved | 2026-07-26 | #100 |
| TD26072003 | The local dashboard profile needs Linux host networking | resolved | 2026-07-26 | #101 |
| TD26072004 | An active node's state_dir grows without bound | resolved | 2026-07-22 | #52 |
| TD26072101 | New evidence on a blocked item is not read until the Enabler's recheck | resolved | 2026-07-27 | #109 |
| TD26072102 | No sanctioned way to watch a node's cycle events from outside | resolved | 2026-07-27 | #107 |
| TD26072201 | The publisher's per-cycle detail loop still forks ~300 jq serially | resolved | 2026-07-28 | #113 |
| TD26072301 | A watchtower roll mid-cycle kills the running pipeline | resolved | 2026-07-26 | #89 |
| TD26072501 | The state dir's logs grow without bound | resolved | 2026-07-28 | #114 |
| TD26072601 | A void with no pull request behind it is checked for evidence, not for truth | resolved | 2026-07-28 | #116 |
| TD26072602 | A human-applied needs-refinement label is inert | resolved | 2026-07-29 | #140 |
| TD26072603 | A refinement block is indistinguishable on the dashboard | resolved | 2026-08-01 | #141 |
| TD26072604 | Refinement blocks inherit the ordinary Enabler threshold | open | | |
| TD26072605 | The pipeline's own writes to a pull request reset its abandoned-draft clock | resolved | 2026-07-29 | #139 |
| TD26072606 | Nothing tests the dashboard page's JavaScript | open | | |
| TD26072607 | The published arm64 image has never been run | resolved | 2026-07-26 | #102 |
| TD26072801 | A still-valid block is re-read every cycle once its issue's thread has moved | open | | |
| TD26072802 | A stage with an empty result silently drops its whole cycle from the dashboard | open | | |
| TD26072901 | acquire_lock trusts a pid across container incarnations | open | | |
