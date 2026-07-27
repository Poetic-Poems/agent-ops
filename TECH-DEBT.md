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

### TD26072501 The state dir's logs grow without bound

TD26072004 bounded the *records* in `state_dir` — `cycles/` and `reviews/` are
pruned on every push — but left the logs beside them appended to for ever. The
heartbeat is the worst of them by two orders of magnitude: one line per tick,
~57 ticks per 5-minute window, which on 2026-07-25 had `dashboard.log` at
8.8 MB / 53,988 lines on `ockham-container` and 4.8 MB / 29,598 on `ockham-2`,
growing about 2.7 MB a day and never stopping. `state-sync.log` (93 KB /
1,234 lines in four days), `cron.log` and `review-cron.log` do the same more
slowly. Nothing is broken today; a node simply keeps a file that only ever gets
bigger, and every `grep` a human runs over it gets slower.

Rotation here has to be *intelligent* rather than a size cap, because these
files are not interchangeable:

- **`dashboard.log` and `state-sync.log`** are pure diagnostics, excluded from
  the state branch, and safe to rotate on size. They are also the only record
  of the heartbeat's GitHub cadence (`github: refreshing`, #68) and of
  `skipped: publish already running`, so a generation or two must survive —
  a cap that keeps only the last few minutes would have hidden exactly the
  bug #68 fixed.
- **`cron.log` and `review-cron.log`** *are* published to the node's state
  branch, so bounding them bounds the mirror and every peer's fetch too. But
  `scripts/publish-dashboard.sh` renders their tail in the cron panel, so
  rotation must not empty that panel the moment it happens — either keep the
  tail window's worth in the live file, or have the publisher read `.1` when
  the live file is short.
- **`log.jsonl` must not be rotated at all.** It is the fleet's memory: the
  union readers (blocked/void extraction, the no-op fingerprint, the limit
  cooldown) scan it whole, and dropping its head silently changes what the
  Co-Ordinator believes has been tried. If it ever needs bounding — 279 KB /
  1,766 lines today, so not yet — it needs age-based pruning consistent with
  `cycles_retained`, which is a separate and riskier change.

Fix: a small `scripts/rotate-logs.sh` on its own crontab line, sizes from
`config.json` beside `cycles_retained` (e.g. `log_retained_bytes`,
`log_generations`). Plain rename is enough — every writer here reopens by name
per append (`>>"$log"` per command), so nothing holds a stale descriptor across
a rotation, and `copytruncate` is not needed. Worth doing at the same time:
`once-pr4-verify.log`, a one-off left in `state_dir` on `ockham-container`,
should not be there at all.

### TD26072601 A void with no pull request behind it is checked for evidence, not for truth

Requirement 34d makes a Co-Ordinator void corroborated rather than merely
confident, and the mechanical half of that — reading the PR's changed files to
see whether the "already done" claim survives contact with the diff — only fires
when the voided repo+item matches a gathered candidate carrying a `pr_number`.
That covers the finishing sources, which is where the shipped defect lived (a
void on `TD26072114` whose own draft PR #92 still had a full diff against
`main`). It does not cover the rest: a tech-debt item with no PR open, a review
recommendation, a `failed-runs` entry. For those the guard tests only that an
`evidence` field is present and non-empty, and a model that will assert a false
reason will also write a plausible-looking citation for it.

Why this is worth doing rather than tolerating: `void` is the only terminal
state in the system, and requirement 34c is emphatic that no agent may clear
one. So the *entire* protection against a permanently silenced item is the
quality of the check at creation, and for the majority of items that check is
currently "did you fill in the box".

Fix: make the citation itself resolvable, and resolve it. Constrain `evidence`
for a Co-Ordinator void to a shape the Script can dereference —
`{ref, path, expect: "absent"|"present", pattern}` is enough for the two claims
that actually get made ("the fix is on `main`", "the Ledger row says resolved")
— and have `lib/void-guard.sh` fetch `repos/<slug>/contents/<path>?ref=<ref>`
and test it. Keep the free-text form accepted for anything that does not fit,
but treat only the resolvable form as corroboration: unresolvable evidence
follows the same path a refuted void does today, to `blocked` and the Enabler,
which reads the repository properly and can void it with evidence of its own.
Note when doing this that the Implementor and Enabler voids need no such guard —
both have already read the thing they are asserting about.

Filed 2026-07-26, alongside the change that introduced requirement 34d.

### TD26072602 A human-applied needs-refinement label is inert

Requirement 34e's label projection is deliberately one-way: the Script applies
`needs-refinement` to an issue when a Co-Ordinator reports the block and takes
it off when the block clears, but nothing ever reads the label back. So a
human who applies it by hand gets nothing — no block is recorded, the item
stays selectable, and the label sits there looking as though it did something.
The one person the flow exists to serve has no way to invoke it deliberately.

Deferred from #84 because it is a design decision, not an omission: it adds a
second writer of refinement state, and a reconciliation path the current
design gets to live without (a hand-applied label the human later removes, a
label on an item already blocked for another reason, a label applied while
the Enabler holds the item).

Fix: keep the log as the only record and make the label a report rather than a
state. During source gathering the Script scans open issues for the configured
label (one search per repo) and, where no refinement block is open for that
item, records one — kind `needs-refinement`, detail naming the label and who
applied it — after which the ordinary lifecycle owns it, including the label's
removal when the block clears. A human removing the label while the block is
open maps to the existing hand-appended `unblocked` path. Decide when building
it whether a hand-flagged item waits the full
`enabler_after_coordinator_cycles` like a reported one — a human has already
established the thing that threshold exists to establish.

Filed 2026-07-26, deferred from #84 (requirement 34e).

### TD26072603 A refinement block is indistinguishable on the dashboard

A refinement block renders in the dashboard's blocked panel as an ordinary
blocked row. That is accurate — it is a block — but the two populations ask
different things of the operator: an ordinary block waits on the world (a
merge, a fix, an answer already asked for), while a refinement block waits on
the pipeline's own Enabler and, past one refinement, on the human. Reading
"blocked: 9" without knowing how many are specification gaps understates how
much of the backlog the fleet is quietly parking. The `kind` marker is already
on every event; nothing surfaces it.

Fix: carry `kind` through the blocked extract into `data.js` and render a
badge (and a filter) in the blocked panel; `docs/DASHBOARD-SPEC.md` travels
with the change, and the data.js size budget gets re-checked, not assumed.

Filed 2026-07-26, deferred from #84.

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

### TD26072605 The pipeline's own writes to a pull request reset its abandoned-draft clock

`scripts/gather-abandoned-drafts.sh` decides a draft is abandoned when its
`updatedAt` is older than `abandoned_draft_after_hours`, and its header explains
why that is right: a push, a comment, a peer node still working it, or a human
poking it all reset the clock, and each genuinely means "somebody is on this".
But `updatedAt` moves for anything at all, including the pipeline's own
housekeeping — and when *this system* touches a pull request, that is not
evidence somebody is on it. It is usually evidence the opposite just happened.

Two measurements on poetic#92, both from 2026-07-26:

- **A label edit.** The `unvoided` label went on at 21:40:28Z and `updatedAt`
  moved to 21:40:44Z with nothing else touching the PR. The perverse part is
  what the label *was*: the maintainer's attempt to unstick it. That attempt
  failed twice over — it did not clear the void, which requirement 34f now
  fixes, and it pushed the one source that could have surfaced the PR out by a
  further `abandoned_draft_after_hours`.
- **The Enabler's own comment, which is the sharper case.** At 00:39:30Z the
  Enabler commented on #92 — "the permission grant took effect, the item's work
  is now complete on this branch, and only a rebase stands between it and
  review" — and at 00:39:53Z logged `unblocked` for `TD26072114`. That is the
  system working exactly as designed: it diagnosed the stall and cleared the
  block. And in the same breath it reset the staleness clock on the pull request
  it had just declared ready to finish, deferring `abandoned-drafts` from
  00:39:30Z to 03:39:30Z. **The better the Enabler explains itself, the longer
  the recovery it enables is delayed.**

The pipeline has several such writes: the Enabler's comment (`prompts/enabler.md`
sanctions one per item), the Implementor's `complexity:*` label on raise and the
Reviewer's correction of it (requirement 8a), requirement 34e's
`needs-refinement` projection and retraction, and the stage-failure comment in
`handle_stage_failure`. Each is on a pull request the system may later need to
recognise as stalled.

**Ruled out, so nobody re-derives it:** a `cross-referenced` event does *not*
move `updatedAt`. agent-ops#83 and #88 both link to poetic#92, firing
cross-references at 21:20:55Z and 00:15:06Z, and `updatedAt` did not move for
either — confirmed against the GraphQL field and both REST endpoints. Mentioning
a stalled pull request from another repository is safe.

**A fix that looks right and is not.** "Take the latest of the head commit's
date, the newest comment and the newest review, and ignore label edits" handles
the first measurement and misses the second entirely — the Enabler's write *is*
a comment, and a human's comment must keep resetting the clock. Filtering by
author cannot separate them either: the fleet raises and comments as
`warwickallen`, the maintainer's own account, so every write has the same author.

The distinction that actually holds is *whose write it was*, and the only
component that knows is the writer. So: **stamp what the pipeline writes**, the
way the Vercel bot does — an invisible marker (an HTML comment carrying the
cycle id) on every comment this system posts, and the gatherer discounts
marker-carrying comments when computing staleness while still counting
everything else. Label edits are discounted unconditionally; the label set is
the pipeline's own bookkeeping surface and a human who wants a PR looked at has
`autonomous-agent` for that.

Worth deciding at the same time whether a stamped comment should reset the clock
*partially* — the Enabler having just examined an item is a reason not to
re-select it immediately — or not at all. Not at all is simpler and safe here,
because the Enabler's verdict already lands as an `unblocked`/`still-blocked`
event that the selection rules read directly.

Check the same measure where else it is used before changing it:
`gather-source-state.sh`'s open-PR digest keys on `updated_at` deliberately, to
notice *any* change, and must keep doing so.

Filed 2026-07-26; second measurement and the revised fix added the same day.

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
| TD26072501 | The state dir's logs grow without bound | open | | |
| TD26072601 | A void with no pull request behind it is checked for evidence, not for truth | open | | |
| TD26072602 | A human-applied needs-refinement label is inert | open | | |
| TD26072603 | A refinement block is indistinguishable on the dashboard | open | | |
| TD26072604 | Refinement blocks inherit the ordinary Enabler threshold | open | | |
| TD26072605 | The pipeline's own writes to a pull request reset its abandoned-draft clock | open | | |
| TD26072606 | Nothing tests the dashboard page's JavaScript | open | | |
| TD26072607 | The published arm64 image has never been run | resolved | 2026-07-26 | #102 |
| TD26072801 | A still-valid block is re-read every cycle once its issue's thread has moved | open | | |
| TD26072802 | A stage with an empty result silently drops its whole cycle from the dashboard | open | | |
