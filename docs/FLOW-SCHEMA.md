# Flow schema — as-built specification

Sibling to `docs/METERING-SCHEMA.md` (requirements 47, 49 and 50 of
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`), under the same stability policy.
Where that document is the field-by-field contract for what a stage *spent*,
this one is the contract for D21/D23 of `docs/ROADMAP.md`'s **flow-and-outcome**
records — three of them, each its own major section below:

- **The rework record** (requirement 47, issue #596) — the pipeline's account
  of repetition: work that reruns, bounces back, or is duplicated, without
  producing anything that did not already exist.
- **The item lifecycle record** (requirement 49, issue #595) — one durable
  entry per work item, folded from the union log's own item-scoped events,
  from first sighting to an explicit terminal fate.
- **The node time-state record** (requirement 50, issue #597) — every
  node-second in a window classified into exactly one of D21's six time
  states, folded from a `node-state` transition event emitted the instant a
  node's own state changes.

Like its companion this document is as-built: it describes the records that
exist today, not a plan for ones that will exist later. Where it says
"requirement N", it means requirement N of
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`.

## What this covers

Three things, each a durable account built from facts already in hand at the
moment they happen — never from a later scan of the transcripts, and never
from a model asked to classify what happened:

- **The rework record**, one entry per repetition, emitted by the detector
  that already exists for it, the instant it fires. A repetition's class, its
  detector and its evidence are facts a script already has in hand at the
  moment the repetition occurs; recording them then is the entire difference
  between an account and a guess. A `CHANGES_REQUESTED` review round and a
  stage re-run after a kill both look like "two Implementer passes" to
  anything reading the transcripts afterwards, and they have nothing in
  common but the cost — which is exactly why each class's own detector, not a
  shared heuristic, is what fires the record.

  **A repetition carries no judgement.** D23 is explicit that rework is never
  a target of zero: a Reviewer catching a defect before a human does is the
  system working, not failing. The record carries no severity field and
  nothing a reader could mistake for a verdict — only what happened, where,
  and (when the evidence says so) which stage it is attributed to.

- **The item lifecycle record**, one entry per work item, *derived* rather
  than emitted: a read-only fold (`lib/item-lifecycle.sh`, behind
  `scripts/item-lifecycle.sh`) over instants that already exist as ordinary
  events in the union log — the join key this document's own "Item lifecycle
  record" section below adds to the ones that lacked it, plus the two genuine
  gaps (`checks-green`, and a `merge-observed` at every point this pipeline
  can observe a merge) nothing emitted before requirement 49. The fold itself
  writes nothing back to the log; it only reads what happened and assigns
  each item the terminal fate its own evidence supports.

- **The node time-state record**, one `node-state` event per transition,
  emitted the instant a node's own state changes — at every `stage-start`
  and `stage-end`, every `stand-down`, every genuinely-nothing-selected
  `none-selected`, every `limit-hit`/`limit-cleared`, once the cycle has won
  the lock, and at `cycle-end` (`review-end` in the review pipeline). Each
  carries the state it is entering, the cause (for the four states that have
  one), and the state it is leaving. `lib/node-time-state.sh`'s
  `node_time_state_fold` (behind the read-only `scripts/node-time-state.sh`)
  is a pure derivation over these events alone — no other event in either
  log is read — reconstructing, per node, which of the six states held at
  every second in a window.

## The rework record

One JSON object per repetition, logged as a `rework` event carrying `ts`,
`cycle` and `node` from the same envelope every other event in `log.jsonl`
carries (`log_event`, `agent-cycle.sh`) — except the one class mined after the
fact (see "post-merge-revert" below), whose `cycle` is `null` because it runs
outside any cycle. Produced by `lib/rework.sh`'s `rework_fields`, the one
shaping function every detector site calls, the same way `lib/metering.sh`'s
`metering_fields` is the one shaping function every `stage-end` site calls for
requirement 33a's record.

| Field | Type | Meaning |
| --- | --- | --- |
| `class` | string | One of the nine classes below. |
| `detector` | string | The file (and, where it disambiguates, the function or event name) whose own logic decided this is a repetition — e.g. `scripts/gather-review-feedback.sh`, `lib/reconciliation-gate.sh:reconciliation_gate`, `agent-cycle.sh:review-gate-checks-read`. Never "the Script" or "the pipeline" in general — always the specific site. |
| `evidence` | any \| null | Whatever the detector's own logic actually saw — an event id, a check name, a comment id, a `kill_reason`, a claim `cause` — never a summary and never re-derived by `rework_fields` itself. `null` only when the caller's own evidence argument was not valid JSON, which `rework_fields` degrades to rather than failing the event it may be riding alongside (the same fail-safe contract `metering_fields` keeps for `docs/METERING-SCHEMA.md`'s own record). |
| `attributed_stage` | string \| null | Which stage this repetition is attributed to, spelled exactly as the corresponding `stage-end` event's own `stage` field spells it — `coordinator`, `implementer`, `reviewer`, `approver`, `approver-adjudicate-open-question`, `enabler`, `enabler-adjudicate`, `enabler-decide`, `refiner` — plus `pre-selection`, which has no `stage-end` of its own because it names a cycle that died before any stage started. `null` whenever the detector's own evidence does not name one directly; see "Attribution" below. |
| `repo` | string | Present where the repetition is about one repository. Omitted (never `null`) for a fleet-wide detector — crash-loop escalation foremost — that spans every configured repository at once. |
| `item` | string | Present where the repetition is about one work item. Omitted on the same terms as `repo`, and independently: a fleet-wide stage kill (the Co-Ordinator, the Enabler, the Refiner, all of which span several items in one engagement) carries neither. |
| `pr_url` | string | Present where a pull request already exists for the item in question. Omitted for a repetition that predates one — most of the nine classes fire only once a pull request exists, but a Co-Ordinator-stage `stage-rerun` or `refinement-bounce-back` can fire before one ever does. |

`repo`/`item`/`pr_url` are omitted, never `null`, when the caller has none to
give — the same "absent, not falsely present" contract requirement 33a's
`tokens`/`gaps` already keep for a stage that never ran. A reader testing for
one of these fields should use `has("repo")`, not `.repo != null`.

## The nine classes

| Class | Detector | Attribution |
| --- | --- | --- |
| `review-round-trip` | `scripts/gather-review-feedback.sh`'s candidate rule, read at the Script's own selection of a `review-feedback` work order | `null` |
| `human-change-request` | `lib/reconciliation-gate.sh`'s `reconciliation_gate` going `dirty`, at the Reviewer's own handoff (`agent-cycle.sh`) | `reviewer` |
| `check-failure` | `agent-cycle.sh`'s `review-gate-checks-read` event carrying `ok: false` | `null` |
| `merge-conflict` | `scripts/gather-merge-conflicts.sh`'s candidate rule, read at selection of a `merge-conflicts` work order | `null` |
| `abandoned-draft-resumed` | `scripts/gather-abandoned-drafts.sh`'s candidate rule, read at selection of an `abandoned-drafts` work order | `null` |
| `stage-rerun` | Either of two: a `stage-end` event carrying a non-empty `kill_reason` (requirement 4e's two backstop caps), or `lib/crash-loop.sh`'s verdict reaching `crash_loop_escalate` (requirement 2.7) | The killed/looping stage's own name, as its `stage-end` event spells it (`coordinator`, `implementer`, `reviewer`, `approver`, `approver-adjudicate-open-question`, `enabler`, `enabler-adjudicate`, `enabler-decide`, `refiner`), or `pre-selection` for a crash loop of cycles that died before any stage started |
| `claim-race-duplicate` | A `claim-lost` event whose `cause` is `held` or `pr-held` | `null` |
| `refinement-bounce-back` | `lib/candidate-select.sh`'s `record_needs_refinement_block` recording a fresh block on an item `refinements_json` already shows as refined | `null` |
| `post-merge-revert` | `scripts/mine-merge-history.sh`'s 48-hour post-merge outcome detection, read by `scripts/publish-revert-rate.sh`'s daily mining pass | `null` |

### Notes on individual classes

**review-round-trip / merge-conflict / abandoned-draft-resumed.** These three
share a shape: a Script-side gatherer (`scripts/gather-*.sh`) already computes
the candidate rule that makes something a repetition of this kind — a pull
request waiting on the agent to answer a human's review, one blocked by a
conflict with its base, or a draft a prior cycle started and never finished.
The record is emitted the moment the Script selects one of that gatherer's
candidates as this cycle's work order, where `{repo, item, pr_url}` are
already in hand from the candidate itself. Whether the repetition is really
the fault of the original Implementer pass, a Reviewer that missed something,
or the Co-Ordinator that picked an unworkable item is not determinable from
this evidence alone, so `attributed_stage` is `null` — see "Attribution"
below.

**human-change-request.** Before requirement 31c's reconciliation gate
existed (2026-08-20), a human change request arriving as a plain pull request
comment — rather than a formal `REQUEST_CHANGES` review, which GitHub refuses
from a pull request's own author, and every write and comment on this
project's own pull requests lands under the same account — was invisible to
the review gate entirely. That was agent-ops#533's blind spot, and this class
used to inherit it. **It does not anymore**: the gate now refuses the
Reviewer's own "ready" handoff, and reverts the pull request to draft, the
moment it finds an unreconciled human comment, and that refusal is exactly
where this class's record is emitted. But the gate runs at one point only —
the Reviewer's own handoff — so its coverage is not total: a change request
posted *after* a pull request is already ready (with no further handoff ever
running to catch it), or one a human acts on directly without the Script's
own handoff running at all, is still outside what this detector can see.
Nothing in this codebase closes that residual gap today; a reader should not
assume `human-change-request`'s absence from a given round means no human
change request happened, only that the reconciliation gate did not catch one.

One further narrowing, for the same reason: `handoff_complete_review` — the
one gate implementation the Reviewer's handoff shares with the Enabler's
handoff-recovery path (requirement 34a) — is also called from
`lib/enabler.sh`, and a `dirty` reconciliation verdict there produces a
`warning`, not a record. Only the Reviewer's own handoff site emits this
class. A recovery pass re-observing a condition an earlier round already
recorded is not obviously a fresh repetition, and deciding that is the
attribution question D23 parks at Phase 2, so the narrower reading is the one
this document states rather than one it guesses at (TD-PPagop-26082919).

**check-failure.** `ok: false` on `review-gate-checks-read` means this
particular attempt to *read* the pull request's required-check list failed —
the same per-attempt fact `review_gate_unknown_streak_verdict`
(TD-PPagop-26081404) already counts a run of before escalating. Read the
class name against that definition rather than the other way round: a
required check that ran and came back red is a `gate.word` of `dirty`, not an
unreadable list, and no class in this document records it — this one counts
the pipeline's inability to establish the check state, which is the
repetition it costs a cycle. The escalation of a run of these,
`review-gate-checks-degraded`, is never counted as a second repetition: it is
a summary of repetitions already recorded at their own per-attempt site, and
counting both would double the same population. `lib/enabler.sh`'s
handoff-recovery path logs its own `review-gate-checks-read` from the same
shared `handoff_complete_review` (requirement 34a) and emits no record, on
the same terms — and for the same parked reason — as `human-change-request`
above.

**stage-rerun.** Two different mechanisms share this one class, because both
end the same way — a stage's work is discarded and has to run again — even
though nothing else about them is alike. A `kill_reason` is one stage, one
run, ended by one of requirement 4e's two backstop caps (inactivity or
wall-clock); the record is emitted once per non-empty `kill_reason`, at that
stage's own `stage-end`. A crash loop is the opposite shape: many consecutive
identical failures across the fleet, caught only once the loop is confirmed
and escalated (requirement 2.7). Expanding an escalated run into one record
per failure it comprises would fabricate history — those individual failures
were never a repetition this system could see at the time, since nothing
pinned a `repo`/`item` to a Co-Ordinator crash or a pre-selection death — so
the escalation itself is recorded as one entry, carrying the run's own
`count`, `first_ts`, `last_ts` and `nodes` as `evidence`.

**claim-race-duplicate.** Only `held`/`pr-held` — a peer genuinely holding
this item already — is a repetition: healthy contention, the same class
`scripts/pickup-metrics.sh`'s own header already isolates for its pickup-
latency accounting, reused here rather than restated. A `claim-lost` whose
`cause` is `unreachable` is an outage, not contention; one with no `cause` at
all predates the convention and is excluded the same way
`pickup-metrics.sh` excludes it — never guessed at.

**refinement-bounce-back.** Fires only on a *fresh* needs-refinement block —
`record_needs_refinement_block` already refuses, with a warning and no
record, a re-report of an item that is already blocked, so this class can
never double-fire on the same standing block. What makes a fresh block a
bounce-back is `refinements_json` already carrying an entry for the same
`{repo, item}`: some earlier engagement already refined this item once, and
whatever it wrote was not enough. `evidence` carries the fresh block's own
`reason` and which stage reported it (`reported_by`) — not `attributed_stage`,
which stays `null`: whether the earlier refinement, the item itself, or the
work that followed it is at fault is exactly the arbitration D23 parks at
Phase 2.

**post-merge-revert.** The one class whose latency is inherent, not a gap in
detection: a pull request's outcome cannot be known until its own 48-hour
post-merge observation window has elapsed (`scripts/mine-merge-history.sh`'s
own header, "Post-merge outcome"), so this class is mined after the fact by
`scripts/publish-revert-rate.sh`'s existing daily pass rather than emitted
in-cycle. That pass already computes each repository's
`post_merge.detail[]` — one entry per pull request a later, corrective-titled
pull request reverted or followed up within 48 hours — to publish its own
aggregate rate; this is the same list, read again for the entries this node
has not already logged (memoised in `<state_dir>/rework-post-merge-revert-
seen.json`, since the same rolling 14-day window is re-mined on every run).
`evidence` carries the detected outcome's own `kind` (`revert` or
`follow-up-fix`), `reason` (`reference` or `file-overlap`), the reverting or
following-up pull request's own number and title, and how many hours after
the merge it landed. `cycle` is `null` on this class's records: the mining
pass runs on its own schedule, outside any cycle.

## Attribution

`attributed_stage` is set only where a class's own detector evidence names a
stage directly — never by arbitrating between plausible causes. Today that is
exactly two classes: `human-change-request` (`reviewer`, because the
reconciliation gate fires at that stage's own handoff and nowhere else) and
`stage-rerun` (the stage that was actually killed or crash-looping — again,
the evidence itself, not an inference). Every other class records `null`.

This is deliberate, not an omission to fill in later. `docs/ROADMAP.md`'s
open-questions table parks "how a repetition's cause is attributed … and what
is admissible when two causes are equally plausible" at Phase 2, with the
rework panel (D23) — because a repetition's real cause is very often not the
stage that performed the repeated work: a second Implementer pass may be the
Refiner's fault for under-specifying, the Co-Ordinator's for picking
something unworkable, or the Reviewer's for passing a defect a human then
caught, and settling which is exactly the judgement a script must not make on
its own and a model must not make after the fact, since "a model inferring
cause after the fact is exactly what the decision forbids" (D23's own
open-question wording). Recording `null` and letting Phase 2's panel arbitrate
against the full record is the correct incomplete answer; guessing here would
be a wrong complete one.

## No cause is ever inferred after the fact

Every record in this document is written at the moment its detector fires,
from that detector's own evidence, by a script — never by a model reading a
transcript, and never by a later batch job re-deriving what must have
happened. The one class that runs outside a cycle (`post-merge-revert`) is
still detector-driven and evidence-only; "mined after the fact" describes
when its underlying event (a corrective-titled pull request landing) can
first be observed, which is inherently after the original merge, not a
looser standard for how the record is produced. Nothing in the emission path
described above invokes a model.

## Do not double-count

The union log (`log.jsonl`, fleet-unioned by `lib/fleet.sh`'s `fleet_logs`)
carries every node's own copy of the events it logged, so two nodes observing
the same repetition can each write their own `rework` record for it — most
visible on `claim-race-duplicate`, where the very definition of the class is
that more than one node raced for the same item. A reader computing a rate
from this stream reduces first-wins-by `ts` (or by the record's own stable
identity — `{repo, item, class}` for most classes, `{repo, item, class,
evidence.by}` for `post-merge-revert`, where more than one corrective pull
request can in principle be detected for the same original) before counting,
the same way every other fleet-wide count in this codebase (`counts.by_day`
et al., `docs/METERING-SCHEMA.md`) already reduces over the union rather than
per-node. This document defines the record only; computing a rate from it —
the rework panel — is D23's Phase 2, out of this document's scope.

This reduction is not particular to the rework record. `docs/IMPLEMENTATION-
PIPELINE-SPEC.md` requirement 2.6d states it as the general property every
analytics record retained under `analytics_retained_days` must honour before
being counted: a record's identity is its own natural key — `{repo, item}`
for the item lifecycle record, `{repo, item, class[, evidence.by]}` for the
rework record — reduced first-wins-by-`ts`, never the emitting node or the
timestamp of the raw event that happened to produce a given copy: two nodes
independently observing the same occurrence log it under their own,
necessarily different `node` (and often `ts`), so including either in the
identity would defeat the very dedup this property exists to guarantee.
Because `fleet_logs` hands every node an identical union of the same
underlying events regardless of which node does the reading, a fold built on
that identity is idempotent under multiple publishers by construction: two
nodes folding the same union produce identical record sets, and merging
those two outputs by the same identity yields one copy of each record, never
two. The rework record's own version of that proof is
`test/rework-panel.test.sh`'s "first-wins" fixture; the item lifecycle
record's is `test/item-lifecycle.test.sh`'s two-node fixture (below).

## The item lifecycle record

D21's flow account (`docs/ROADMAP.md`) states the invariant this record
exists to make checkable: **every work item carries a lifecycle from first
sighting to terminal fate, and items entering equals items leaving plus work
in progress** — a count, a token or an item that cannot be classified lands
in an explicit `unaccounted` bucket and is never dropped. Requirement 49
implements it: one record per `{repo, item}`, folded from the union log by
`lib/item-lifecycle.sh`'s `item_lifecycle_fold` (behind the read-only
`scripts/item-lifecycle.sh`), never a second event stream — the record is
*derived*, not emitted, so it costs nothing to keep accumulating history from
the moment this document lands, and it can be recomputed from scratch at any
time against whatever of the log survives.

Most of the instants this record accumulates already existed as scattered
facts before requirement 49 — the roadmap's own list is `first-seen`,
refinement, `selection`, stage starts and ends, `pr-raised`, checks green,
review verdict, `pr-ready`, landing, and the item closed. What was missing
was narrower than that list suggests:

1. **The join key.** Several of those events carried a pull request or a
   stage name but not `{repo, item}` — `stage-start`, `stage-end`,
   `pr-raised`, `pr-ready`, `landing-armed`, `landing-refused`,
   `approver-verdict`, `review-gate-checks-read` and `issue-closed-post-merge`
   now all carry it, additive and non-breaking, whenever the emitting site
   knows both. A stage that runs ahead of or across selection — the
   Co-Ordinator, the Enabler's and the Refiner's own top-level engagement —
   still carries neither: it has no one item to name (see each site's own
   comment). `review-gate-checks-degraded` is deliberately **not** one of
   these: it is a streak escalation over a run of consecutive per-node
   failures that can span several different items, so naming one item on it
   would misattribute the others'.
2. **Checks green.** `review-gate-checks-read`'s own `ok` field has always
   named whether the required-checks *read* succeeded, never whether what it
   found was clean — a genuinely dirty gate and an unreadable one both left
   no positive record that checks had actually gone green. A `checks-green`
   event now fires at both sites that reach `handoff_complete_review`'s gate
   (the Reviewer's own handoff in `agent-cycle.sh`, and the Enabler's
   `complete_handoff` recovery path in `lib/enabler.sh`) the moment its
   `gate.word` reads `"clean"` — the first point in the pipeline that fact is
   knowable at all.
3. **The merge itself.** Nothing emitted an event for a pull request actually
   merging; `scripts/mine-merge-history.sh` only reconstructs it after the
   fact from the GitHub API, over every merged pull request back to the
   repository's own beginning, keyed by pull request rather than by item — a
   miner and a Stage 0 autonomy baseline (#404/D18 §6) requirement 49 leaves
   untouched. A `merge-observed` event (`lib/merge-observed.sh`, requirement
   32c) now fires at every point this pipeline can observe a merge as it
   happens: the Reviewer's own mid-pass reads (`reviewer_merge_observed`, at
   its stage-start and its handoff, agent-ops#916), `lib/landing.sh`'s own arm
   site (a synchronous merge the no-queue auto-merge fallback sometimes
   performs directly — see that file's own header on the distinction, and
   `pr_merge_state`'s read confirming which one just happened rather than
   assuming from the arm method alone), and `scripts/sweep-closed-issues.sh`'s
   own periodic sweep (a catch-all: it already lists every merged,
   `pr_label`-labelled pull request fleet-wide, every stand-down, whether the
   pipeline armed it, a human clicked merge, or GitHub's merge queue resolved
   it well after any other site last looked). The sweep's own emission is
   bounded and de-duplicated per node against a small seen-file — see its own
   header for why a pull request re-emits nothing once it ages out of the
   window it lists.

### Identity and instants

| Field | Meaning |
| --- | --- |
| `repo` | The item's own repository slug. |
| `item` | The item's own reference — a bare issue number, a finishing source's own id (`pr-<n>-abandoned-…` and siblings), a review recommendation ref, or a register-hygiene/human-visibility ref. Always paired with `repo`: an id is only unique within its own repository (`lib/cycle-state.sh`'s own header gives the reason — both repositories carry a `dependabot-alert-1`). |
| `source` | The most recent `selection` event's own `.source` for this item, or `null` if the item was never selected (a `first-seen` with no claim yet, or an item this fold only knows from a non-`selection` event such as `orphan-branch-released`). |
| `first_seen` | The earliest `first-seen` event's own `ts` for this item, or `null` if none was ever logged (a finishing-source item, whose branch and pull request already exist before any cycle "discovers" it the way `first-seen` means). |
| `instants` | Every event this fold found for the item, in timestamp order: `{event, ts, node, cycle, fields}`, where `fields` is that event's own payload minus `repo`/`item`/`event`/`ts`/`node`/`cycle` — the originating event and everything it carried, exactly as logged, never summarised or re-derived. |
| `fate` | One of the six values below, or `unaccounted` — the one case that sits outside their priority order rather than inside it. |

### Terminal fates

Assigned by one strict priority — each rule checked only once every rule
ahead of it has failed to match — over the item's own whole event history,
which under `--since` is wider than the `instants` this run reports (see the
window caveat below), reusing
`lib/cycle-state.sh`'s existing `void_items`/`blocked_items`/
`draft_obsolete_flags` extracts for the set/clear resolution rather than
re-deriving that logic a second time (the drift requirement 34a already
warns against, generalised here to a third reader):

| Fate | Rule |
| --- | --- |
| `landed` | A `merge-observed` or `issue-closed-post-merge` event exists for this item. The strongest possible evidence — a real merge was observed — outranks every other mark, including a stale void. A `landed` record additionally carries `reworked_after_landed: {since, event}` when the item's own full event history holds a later item-scoped event — a reopened or re-worked item, e.g. a later `pr-raised` for a second pull request — naming the earliest such event and its own timestamp; further landing evidence itself (a second `merge-observed`/`issue-closed-post-merge`) does not count, since multiple merges is not rework. The field is additive per the Stability policy below, and omitted entirely — never `false`/`null` — when no such later event exists. |
| `voided` | `void_items` still carries this pair: the latest `item-void` has no later `unvoided`. |
| `superseded` | An `orphan-branch-released {reason: "superseded"}` event resolves to this item. That event carries no `item` field of its own — `scripts/sweep-orphan-branches.sh` is not one of the sites requirement 49 touches — so the fold resolves one the same way `scripts/sweep-closed-issues.sh` already does: a head branch of exactly `agent/<N>`, the name this pipeline mints only for an issue- or tech-debt-sourced work order. A branch that does not match that shape names no item this fold can key on, and is silently excluded from consideration — never guessed at. |
| `blocked` | `blocked_items` still carries this pair: the latest `attempt-failed` has no later `unblocked`. A currently-blocked item is demonstrably still in the system, which outranks the merely uncorroborated intent `abandoned` records below. |
| `abandoned` | A `draft-obsolete-flagged` event exists for this item: the pipeline's own recorded intent to abandon a draft (design doc §5.5, issue #413, WI-10), pending the human corroboration (the `obsolete` label, `lib/void-guard.sh`) that would otherwise retire it as `voided` on a later fold. A standing block is stronger evidence than this uncorroborated intent, hence ranked below it. |
| `open` | None of the above: the item has entered (some event names it) but nothing yet says it has left. |

One case sits outside this priority order rather than inside it:
**`unaccounted`**. An item is `unaccounted`, not `landed`, when it is *also*
void *and* that void's own `ts` is later than the earliest landing evidence —
a human or the Enabler recorded "no work exists" for an item that, on the
log's own evidence, had already merged. The fold does not resolve that
contradiction by guessing which side is right; it surfaces the item, and the
reason, in `unaccounted[]` — the same discipline D21 states for the flow
account generally. The mirror-image order — a void recorded *before* the
merge that follows it — is not a contradiction: the void was simply wrong,
and the later merge is the stronger evidence, so `landed` wins outright. An
`unaccounted` item still appears in `records[]` with `fate: "unaccounted"`,
exactly as every other item does; `unaccounted[]` is a convenience projection
of the same records carrying the reason, never a second population.

### The flow invariant

`totals.balanced` states, and `test/item-lifecycle.test.sh` asserts on a
fixture built to exercise every fate at once, that `entered` (every distinct
`{repo, item}` pair with any event) equals `leaving` (`landed` + `voided` +
`superseded` + `abandoned`) plus `in_progress` (`blocked` + `open`) plus
`unaccounted`. This holds by construction — fate is a total function over the
entered set into exactly one of seven buckets — and is computed and printed
rather than merely asserted in prose: a future change that lets an item fall
through every rule above, or match two, is exactly the defect this field
exists to catch.

### The window caveat

`window.from`/`window.to` name the earliest and latest timestamp this run
actually read, bounded by `--since` and by whatever the union log currently
holds. `log.jsonl` is **never rotated** (`scripts/rotate-logs.sh`'s own
header: "NEVER rotated — this is the fleet's memory") and its analytics
content is retained per `analytics_retained_days`
(`docs/IMPLEMENTATION-PIPELINE-SPEC.md` requirement 2.6d) — `0` by default,
meaning indefinitely, which is today's behaviour — so this record's only
real bound in practice is how far back this pipeline's own logging began,
not a size-based rotation: no `log_retained_bytes`-style cap ever applies to
this file. That is still a bound worth stating: a fleet whose
`state_dir` was reset, or whose oldest node joined after this record's own
instants started emitting, reads a shorter history than the pipeline's true
age, and `window.from` is how a reader tells the difference between "nothing
happened before this" and "nothing was recorded before this."

**`--since` bounds the population, never the fate.** Which items appear in
`records[]` at all is decided by whether an item has any event at or after
`--since` — an item with no such event is simply absent, exactly as if it
had never entered. An item that *does* appear, though, is resolved to its
true current fate from the whole log, regardless of `--since`: `voided`,
`blocked` and `abandoned` are read off `void_items`/`blocked_items`/
`draft_obsolete_flags`, each already computed from the unfiltered log, and
`landed`/`superseded` are read the same way, off the item's own full event
history rather than only the events inside the window. So an item entering
the population on the strength of one recent event still reports the fate
its full history supports — an older merge, an older void, an older block —
never the weaker fate a truncated view of the same item would otherwise
produce. Put another way: **fate is current state; `--since` bounds only the
population**, not "fate is whatever the window alone can see." `instants`,
`first_seen` and `source` are the one place the window still shows through —
they answer "what did this run see for this item," not "everything this item
ever did," so a reader wanting the item's full history reads `fate` and
re-runs with an earlier `--since` for the rest.

### Generalising, not duplicating: `scripts/pickup-metrics.sh`

`scripts/pickup-metrics.sh` already paired `first-seen` with `selection` for
pickup-latency accounting (TD-PPagop-26081405, issue #248 acceptance 4)
before this record existed. That pairing is now `lib/item-lifecycle.sh`'s own
`item_lifecycle_pickup_pairs` — the identical reduction, moved rather than
rewritten — and `pickup-metrics.sh` calls it instead of carrying a second
copy. Its CLI contract, output field names and its own test
(`test/pickup-metrics.test.sh`) are unchanged; only where the computation
lives moved. `scripts/mine-merge-history.sh` is explicitly **not**
generalised the same way (escalation #827): it is a GitHub-API miner and a
Stage 0 autonomy baseline, keyed by pull request rather than by item, reading
no event log at all — its population, its key, its `--since` semantics and
its own tests all stay exactly as they are.

## The node time-state record

D21 of `docs/ROADMAP.md` names the time account's own invariant: every
node-second in a window falls into exactly one of six states — **producing**,
**overhead**, **externally-blocked**, **idle-with-demand**,
**idle-without-demand**, **down** — and the states sum to node-count x
window. Requirement 50 is where it is made checkable: a `node-state`
transition event, logged the instant a node's own state changes, carrying
the state it is entering, its cause (for the four states that have one), and
the state it was in a moment before; and a pure fold over those events,
`lib/node-time-state.sh`'s `node_time_state_fold` (behind the read-only
`scripts/node-time-state.sh`), reconstructing seconds per state from them.

Most of the instants already existed as ordinary events before this
requirement — `cycle-start`, `stage-start`, `stage-end`, `stand-down`,
`none-selected`, `limit-hit`, `limit-cleared`, `cycle-end` (and their
`review-*` counterparts in the review pipeline) all fire already. What this
requirement adds is narrower than that list suggests: a `node-state` event
logged alongside each one, translating whatever that site already knows into
one of the six states, and — for the four `stand-down`/`none-selected` sites
that previously carried no machine-readable reason at all — a `cause` field
from the closed vocabulary below.

### A tick that owns no node-second emits nothing

The one exception to "alongside each one", and the reason the opening
transition is logged where it is. A node's timeline is per *node*, not per
process, and `agent-cycle.sh` and `review-cycle.sh` each have their own
crontab line and their own lock — so a tick can start, discover the node is
already busy under the other process, and end without ever having owned a
second of it. Three sites are unconditionally that:

- `cycle-skipped` — `agent-cycle.sh` found `lock.json` held by a live cycle;
- `review-skipped` — `review-cycle.sh` found `review-lock.json` held;
- `review-cycle.sh`'s "an implementation cycle is running" `review-stand-down`
  (`cause: "peer-pipeline-busy"`, the one `stand-down` cause deliberately
  outside the six-state vocabulary below, because it names a fact about the
  *other* process rather than a state of this node).

All three write their own ordinary event and **no `node-state` transition at
all**: they call `suppress_node_state_transitions`, which is what stops
`finalize_node_state_for_cycle`/`finalize_node_state_for_review` logging a
terminal state on the way out, and they exit before the opening `overhead`
transition is reached — which is why `agent-cycle.sh` logs that one just
after `acquire_lock` rather than beside `cycle-start`, and `review-cycle.sh`
just after the implementation-cycle check rather than beside `review-start`.

A fourth event shares `cycle-skipped`'s own name without being a fourth
site: `cycle-skipped {reason: "overlap", …}` (requirement 11a of
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`, agent-ops#1287) is logged by the
cycle that *held* the lock throughout, at its own cleanup, for a schedule
slot supercronic silently dropped while that cycle was still running — the
opposite case from the one above, where the tick that logs `cycle-skipped`
is the one that found the lock held. It never calls
`suppress_node_state_transitions`: the seconds it describes already belong
to the logging cycle's own node-state timeline, finalized moments before.

Six further `review-stand-down` sites are *conditionally* that, and are
silent on the same terms whenever the condition holds. The
implementation-cycle check is the last ending in `review-cycle.sh` that can
fire while `agent-cycle.sh` is mid-stage, but it is not the first: both
switch stand-downs, both `project_review.defaults.not_before` stand-downs,
the tier-two every-repository-held one (requirement 342) and the usage-limit
cooldown all `exit 0` before it is reached, and each records a terminal state
of its own. Each therefore calls `suppress_node_state_if_peer_owns_node`
beside its `set_node_state_terminal`, which runs two probes of the same
shape, each with no staleness test so a lock naming a pid that is gone reads
as not-running: `review-cycle.sh`'s own `impl_cycle_running` — the same
`lock.json` pid probe the check below it uses — and `review_cycle_running`,
the equivalent probe of `review-lock.json`. That second probe ignores a lock
naming this process's own pid, which is what makes it peer detection rather
than "is this lock held at all": five of the six sites run before this
process's own lock acquisition ever writes `review-lock.json`, where any live
pid is a peer by construction, but the usage-limit cooldown runs *after* it,
over a lock file this run has just written its own pid into. The terminal
transition is suppressed when either probe finds a live peer — a live
implementation cycle or a live peer review run — owning the node; a node
genuinely idle under both pipelines still records its idle state from these
sites, unchanged.

Silence is not tidiness here. The fold holds each point's state until the
next point's `ts`, and a running stage emits nothing between its own
`stage-start` and `stage-end`, so a single unguarded tick's transitions would
relabel the rest of a live Implementer engagement — up to its backstop — as
this tick's overhead and then as idle. The cycle holding the lock is the one
occupying those node-seconds and its own events already say so; #597's
refinement puts it as "`cycle-skipped` is not a state … counting it as a
state of its own is the same double-count by another route." The `not_before`
stand-downs are the reason the conditional half matters as much as the
unconditional one: holding reviews off until a date is a steady state, not a
race, so on an installation using it every review tick reaches one of those
endings — including the ticks that land inside a live Implementer stage.

The maintenance chores are not node states either, for a related reason:
`publish-dashboard-launcher.sh`, `state-sync.sh`, `doctor.sh` and
`rotate-logs.sh` run on their own crontab lines, never take either cycle
lock, and never stop a cycle starting — so they occupy no node-second of
pipeline capacity and emit no `node-state` transition. They are not an
omission.

### The six states

| State | Meaning |
| --- | --- |
| `producing` | Wall time between a `stage-start` and its `stage-end` for the **Implementer** or the **Reviewer** stage only — the two stages whose output becomes a delivered change. |
| `overhead` | Every other in-cycle second: gather, the Co-Ordinator, the Enabler, the Refiner, the Approver, claiming, teardown. They buy the decision, not the change. |
| `externally-blocked` | A usage-limit cooldown, a GitHub API/credential/rate-limit guard, or a host resource guard (disk, memory) — something outside this node's own work that is stopping it. |
| `idle-with-demand` | Eligible unclaimed work existed and this node did nothing about it this tick — split by cause below, because each cause has a different fix. |
| `idle-without-demand` | Nothing eligible existed anywhere — the healthy zero, the state a scale-to-zero fleet should be free to sit in. |
| `down` | The node was deliberately switched off (`disabled-node`/`disabled-fleet`), or produced no evidence at all before its first event in the window (see "Absence is `down`" below) — a live node cannot emit its own transition *into* `down`, only out of it. A node that *stops* mid-window holds its last state instead of falling to `down`; see "Known limitations". |

### The definitional pin

D21 names the six states but not which pipeline second belongs to which; this
is the one judgement this requirement cannot avoid, so it is pinned here,
revisable in this one place rather than scattered across every emission site:

- **`producing`** is deliberately narrow — the Co-Ordinator, the Enabler, the
  Refiner and the Approver all buy a *decision*, and only the Implementer and
  the Reviewer buy the *change* itself (`node_state_for_stage`,
  `lib/node-time-state.sh`).
- **`down`** covers both "nothing is running" and "switched off"
  (`disabled-node`/`disabled-fleet`), told apart by `cause`. A deliberately
  disabled node is not idle: nothing about demand would change its behaviour.
- **`externally-blocked`** covers `usage-limit`, `github-budget`,
  `unreachable` (GitHub itself unreachable for a claim attempt),
  `unauthorized` (a dead or missing credential), and the host resource
  guards `disk-low`/`disk-full`/`memory-low`. The last three are not
  "external" in the strictest sense — they are a fact about this node's own
  host — but they are grouped here rather than under `idle-without-demand`
  because the fix is host capacity, not a change in demand, the same
  distinction the other members of this bucket already turn on.
- A cycle-ending `stand-down`/`none-selected` that a peer's own claim
  explains (`raced`, `pre-claimed`, and this pipeline's own
  draining-with-live-claims stand-down) is `idle-with-demand`/
  `peer-claimed`: demand existed and someone else has it.
- A cycle-ending `stand-down` that names a defect in the Co-Ordinator's own
  candidate construction (`fabricated`, `untraceable`) is
  `idle-with-demand`/`coordinator-declined`, the same cause a genuine decline
  against a non-empty eligible set earns: both are "the Co-Ordinator did not
  turn eligible work into a claim," whatever the reason.
- **`down` cannot emit its own transition.** A node that is truly off writes
  nothing, so it is the one state the fold derives from *absence* (see
  below) rather than from an event naming it. A live node's very first
  `node-state` transition in a fresh process is always logged as leaving
  `down` (`log_node_state_transition`'s own default `prev_state`),
  regardless of what a peer's log might say this node was doing under a
  different process a moment before — `prev_state` is audit context the fold
  never reads for interval reconstruction, never a value anything downstream
  computes from.

If any of these readings is wrong, it is wrong in exactly one paragraph of
this document.

### The closed cause vocabulary

Fourteen tokens, each mapping to exactly one state — `lib/node-time-state.sh`'s
`node_time_state_for_cause` is the one function that knows the mapping:

| Cause | State |
| --- | --- |
| `disabled-node`, `disabled-fleet` | `down` |
| `usage-limit`, `github-budget`, `unreachable`, `unauthorized`, `disk-low`, `disk-full`, `memory-low` | `externally-blocked` |
| `back-pressure`, `awaiting-tick`, `peer-claimed`, `coordinator-declined` | `idle-with-demand` |
| `no-demand` | `idle-without-demand` |

`awaiting-tick`, `back-pressure`, `peer-claimed` and `coordinator-declined`
are D21's own four idle-with-demand causes — waiting for the next cron
firing, the back-pressure cap bound, every eligible item already claimed by
a peer, and the Co-Ordinator declining to select against a non-empty
eligible set, respectively.

Four of these tokens are **not** new names on the events that already
carried a `cause` — the pre-existing `stand-down`/`claim-lost` vocabulary is
never renamed to satisfy this requirement (an existing field's values are a
contract other readers, the dashboard included, already depend on). `raced`
and `pre-claimed` (the claim-race stand-down, `agent-cycle.sh`) keep those
names on the `stand-down` event itself and translate to `peer-claimed` only
on the `node-state` event beside it; `fabricated` and `untraceable`
(corroboration-gate stand-downs, same site) keep their names and translate
to `coordinator-declined` the same way. Every other cause in the table above
*is* the literal value logged on both the originating event and the
`node-state` event beside it — there is only one vocabulary to remember for
a newly-added site.

One `stand-down` cause sits deliberately outside this table:
`peer-pipeline-busy`, on `review-cycle.sh`'s "an implementation cycle is
running" `review-stand-down`. It maps to no state because that site emits no
`node-state` event at all (see "A tick that owns no node-second emits
nothing" above) — it records why *this process* stopped, not what the node
was doing, which its peer process's own transitions already say. It is a
value of the pre-existing `stand-down` `cause` field, not a member of the
`node-state` vocabulary, and `node_time_state_for_cause` maps it to nothing
like any other token it does not recognise.

`node_time_state_idle_split(total, cause)` is the other half of the
classification, used at every site whose cause depends on a live count
rather than being fixed: a `none-selected` outcome, the no-op fingerprint
short-circuit, and the idle state a normal cycle settles into once it ends
(see "Where it's produced" below). A positive eligible-item count earns
`idle-with-demand` tagged with the named cause; zero (or an unreadable
count — never a guess) earns the healthy `idle-without-demand`/`no-demand`
zero.

An unrecognised cause maps to nothing (`node_time_state_for_cause` prints
empty), and a caller finding that skips logging a cause-bearing state rather
than inventing one. A `node-state` event whose own `state` is not one of the
six is not excluded — the instant it names is real even if the label is
not — its interval lands in `unaccounted_seconds` instead, and an
`idle-with-demand` event whose `cause` is missing or unrecognised still
counts fully toward `idle-with-demand`'s own total, with the cause itself
filed under `unspecified` rather than dropped.

### Absence is `down`

Per node, the fold's timeline is a synthetic `down` point at the window's
own start, followed by every one of that node's own `node-state` events
inside the window, sorted by `ts`. Each point's `state` holds until the
next point's own `ts` (the last, until the window's end). A node with zero
`node-state` events anywhere in the window therefore scores `down` for the
window's entire span — the synthetic point alone — and a node whose first
event lands partway through the window scores `down` for the leading gap
before it: the "a node absent for part of the window scores down"
requirement, satisfied by the general rule rather than a special case for
it.

`prev_state` is never read by the fold for this reconstruction — every
interval comes from consecutive points' own `ts`/`state` alone, which is
also what makes the fold immune to two processes racing to log the same
instant, or to two pipelines' events for one node interleaving on the
merged timeline (see "Known limitations" below): whichever event actually
carries the later `ts` simply starts the next interval, and a node
contributes exactly one window's worth of seconds no matter how many events
land on it or in what order they are read.

### Deferred emission for a stand-down's own terminal state

A `stand-down`/`none-selected` site does not log its own `node-state`
transition immediately — it calls `set_node_state_terminal(state, cause)`,
which only records intent. `agent-cycle.sh`'s exit trap (`cleanup`) still
runs `maybe_run_enabler`/`maybe_run_refiner` after any stand-down, and their
own `stage-start`/`stage-end` pairs are real `overhead` that must land on
the timeline *before* the node settles into the idle/down/
externally-blocked state the stand-down named — logging it at the
stand-down site itself would let a later Enabler engagement's own
`overhead` transition silently overwrite it on the shared per-node
timeline. `finalize_node_state_for_cycle`, called once at the true end of
`cleanup` (`finalize_node_state_for_review` in the review pipeline), is
what actually logs it: whatever `set_node_state_terminal` recorded, if
anything did, or — for a cycle that ran a stage and ended normally, so
nothing called it — the idle state implied by `eligible_items_total` (the
Co-Ordinator's own pre-selection count, minus the one item this cycle just
claimed, floored at zero). A stage-start/stage-end transition, by contrast,
*is* logged immediately at its own site (`log_node_state_transition`): it
names real, ongoing state during the cycle, not a settling point the rest
of the cycle could still revise.

### Known limitations

Stated plainly, on the same terms every other simplification in this
document is, rather than hidden:

- **The node set is not evaluated per second of the window.** It is every
  node that has *ever* logged a `node-state` event, over the fold's whole
  unwindowed input — not the roadmap's own "node-count is not a constant"
  precision for a node truly joining or leaving the fleet mid-window. A node
  that joins mid-window is handled correctly for free by the general
  "absence is `down`" rule above; a node that *leaves* stays in the
  denominator for every later window, so the invariant keeps charging the
  fleet for capacity it no longer has (issue #1248).
- **A node that stops holds its last state for the rest of the window, so
  `down` never covers a crash or a decommission** (issue #1250). "Absence is
  `down`" governs the stretch *before* a node's first event, not the stretch
  after its last: each point's state holds until the next point's `ts`, and a
  node that stops has no next point. A node stopped cleanly therefore scores
  whatever `finalize_node_state_for_cycle` last logged — normally
  `idle-without-demand`/`no-demand` — indefinitely, and a node SIGKILLed
  mid-Implementer (a container OOM or eviction, anything that outruns
  `cleanup`'s TERM handler) scores `producing` indefinitely. Neither reaches
  `down`, which is the state D21's own bullet leads with ("crashed,
  crash-looping, heartbeat stale, container unscheduled"). Bounding a
  trailing segment — against each node's own `heartbeat.json` age, which is
  the derivation #597's refinement named, or against a multiple of
  `schedule.cycle_interval_minutes` — is what would close it; #1250 carries
  the choice.
- **`balanced` checks the arithmetic, not the data.** Every node's segments
  tile `[window.from, window.to]` exactly by construction, so
  `expected_total_seconds` and the summed states agree for any input the
  fold can parse at all. A `true` here means the fold did not lose or
  duplicate a second while reducing; it is not evidence that the events it
  reduced described the fleet correctly, and the two limitations above are
  both invisible to it. Read it as a self-check on the reduction, and
  `skipped_events` and `unaccounted` as the honest measures of what the
  input could not say.
- **A `--since` boundary cuts a node off from its own prior state.** The
  synthetic `down` point sits at the window's own start, so a node that was
  mid-`producing` when a windowed query begins scores `down` from
  `--since` until its next transition, rather than continuing the state it
  was actually in. The error is bounded by one transition — for a node
  running cycles, at most one `schedule.cycle_interval_minutes`, the same
  resolution floor `scripts/pickup-metrics.sh` records for pickup latency —
  but it is real, and it is why a window narrower than a cycle interval
  reports mostly `down`.
- **Two pipelines' events on one node are merged, not precedence-ordered.**
  `agent-cycle.sh` and `review-cycle.sh` have separate crontab lines and
  separate locks, so both can run on one node at once. `scripts/node-time-
  state.sh` unions `log.jsonl` and `review-log.jsonl` into one timeline per
  node, ordered by `ts` alone: whichever event's own timestamp is later
  starts the next interval, with no notion that the earlier pipeline's own
  interval is still, in truth, running underneath it. A genuine overlap is
  read as the later-logged pipeline's own state for as long as it is the
  most recent event, rather than the documented `producing > overhead`
  precedence a fuller model would need. This is why every `review-cycle.sh`
  ending that can fire while `agent-cycle.sh` owns the node logs no
  `node-state` transition when it does (see "A tick that owns no node-second
  emits nothing" above) — the alternative, a competing idle
  transition from the pipeline that is *not* doing the work, would be
  actively wrong rather than merely imprecise. The converse is not covered:
  `agent-cycle.sh` never probes `review-lock.json`, so one of *its*
  stand-downs landing during a live project review writes its own idle state
  over that review's `producing`, which is the plain last-writer-wins case
  this bullet describes.
- **`agent-cycle.sh`'s two switch stand-downs log `down` without owning the
  node** (issue #1268). They record their terminal state and `exit 0` ahead
  of `acquire_lock`, so a `--disable` issued while a cycle is mid-stage means
  the next tick writes `down` over that cycle's own `producing`, until its
  next transition. `review-cycle.sh` guards the equivalent endings with
  `impl_cycle_running`; `agent-cycle.sh` cannot reuse that shape as it
  stands, because the value `acquire_lock` decides staleness from
  (`lock_stale_after_sec`) is not derived until after both stand-downs — and
  a probe that guessed wrong in the other direction would suppress a
  disabled node's `down` permanently, which is the only transition such a
  node ever emits. #1268 carries the choice.
- **The review pipeline's own idle state is not modelled.** `review-
  cycle.sh` has no per-run eligible-item count the way `agent-cycle.sh`'s
  Co-Ordinator gather does — it reviews one configured repository on a
  dated cadence, not against a backlog — so `finalize_node_state_for_review`
  settles unconditionally into `idle-without-demand`/`no-demand` whenever no
  `review-stand-down` site called `set_node_state_terminal` itself. None of
  D21's four idle-with-demand causes name a backlog this pipeline has. Where
  this matters most is not the review pipeline's own reading but what it
  overwrites: on a node running both pipelines, a review tick settling into
  `no-demand` replaces whatever `agent-cycle.sh` last settled into, so a real
  `idle-with-demand`/`awaiting-tick` verdict can be relabelled as the healthy
  zero by a review tick that knows nothing about the implementation backlog.
  Only the overlap with a *running* implementation cycle is guarded (the
  `impl_cycle_running` probe above); an overlap with a sleeping one is the
  last-writer-wins case #1248 carries.
- **An unparseable `--since`/`--until` degrades to the all-empty report
  rather than being rejected** (issue #1273). A `node-state` event whose own
  `ts` fails `fromdateiso8601` is skipped and counted (above), but the
  window bounds themselves are parsed unguarded once either becomes
  `window.from`/`window.to`, and `scripts/node-time-state.sh` passes both
  flags through without validating them. A date-only value, a `+00:00`
  offset or a typo therefore aborts the fold's one jq program, and
  `node_time_state_fold`'s fallback prints the conforming all-zero shape
  with `balanced: true` — indistinguishable from a window in which the fleet
  genuinely did nothing. #1273 carries the choice between rejecting the
  bound at the CLI boundary and degrading to an absent bound inside the
  fold.

## Stability policy

Identical to `docs/METERING-SCHEMA.md`'s own, restated here rather than
merely referenced because this is a contract other code will depend on the
same way. It binds all three records this document defines — the rework
record, the item lifecycle record, and the node time-state record, all
above — on the same terms:

- **Additive, non-breaking:** a new field on any record; a tenth rework
  class; a new detector site for an existing rework class; a new
  `attributed_stage` value; a new item-lifecycle instant; a new terminal
  fate; `{repo, item}` added to a further event; a new `node-state`
  emission site for an existing state; a new cause added to the closed
  vocabulary, so long as it maps to one of the six existing states.
- **Breaking, and must land in the same pull request as the code that makes
  it (`CLAUDE.md`, "As-built specifications"):** renaming or removing a
  field on any record; changing `class`'s or `attributed_stage`'s meaning
  for an existing rework value; changing what a rework class's `evidence`
  carries in a way an existing reader could misread as the old shape;
  changing an existing fate's own assignment rule; changing the fate
  priority order; renaming or removing one of the six states or one of the
  fourteen causes; changing which state an existing cause maps to; changing
  the definitional pin (which stages count as `producing`, what `down`
  covers).

## Where it's produced and consumed

**The rework record:**

- **Produced:** `lib/rework.sh`'s `rework_fields`, called from each class's
  own site above — `agent-cycle.sh` and the libraries it sources for eight of
  the nine classes (`lib/candidate-select.sh` for `refinement-bounce-back`,
  `lib/enabler.sh` for the crash-loop half of `stage-rerun`, and
  `lib/stage-attempt.sh`, `lib/approver.sh`, `lib/landing.sh`,
  `lib/refinement.sh` and `lib/enabler.sh` for the `stage-end` half, one call
  per `stage-end` site that can carry a `kill_reason`), and
  `scripts/publish-revert-rate.sh` standalone for `post-merge-revert`.
- **Consumed:** nothing yet. This document defines the record so it starts
  accumulating history from the moment it lands (D21's own reasoning for
  fixing the metering schema early applies identically here: "every month the
  contract is deferred is a month of history no later panel can
  reconstruct" — `docs/ROADMAP.md`). The rework panel that reads it — escape
  rate per detection stage, first-pass yield, rework's share of tokens and of
  elapsed time — is D23's Phase 2, and is not built by this document.

**The item lifecycle record:**

- **Produced:** the join key, `{repo, item}`, added at each of the sites
  named in "The item lifecycle record" above — `agent-cycle.sh`'s
  `stage_budget_apply` (`stage-start`) and its own `stage-end` (the
  Implementer's and the Reviewer's), `pr-raised`, `pr-ready` and
  `review-gate-checks-read` sites, `lib/approver.sh`'s own
  `stage-end`/`approver-verdict`, `lib/enabler.sh`'s `stage-end` (its two
  per-item adjudication sites) and its own copies of `pr-ready`/
  `review-gate-checks-read`, `lib/landing.sh`'s `landing-armed`/
  `landing-refused` (threaded through `_landing_stage_attempt`, resolved from
  the fleet log via `landing_retry_item` on the 2.1e retry sweep's own
  candidates, which have no in-process item to read) and its
  `approver-adjudicate-open-question` `stage-end`, and
  `lib/standdown.sh`'s own `issue-closed-post-merge` wiring (`item`, alongside
  the existing `issue` field, derived from `scripts/sweep-closed-issues.sh`'s
  own already-resolved marker/branch). `checks-green`:
  `agent-cycle.sh`'s Reviewer handoff and `lib/enabler.sh`'s
  `complete_handoff` recovery path, both immediately after
  `handoff_complete_review` returns. `merge-observed`: `lib/merge-observed.sh`
  (unchanged since agent-ops#916), plus `lib/landing.sh`'s own arm site and
  `scripts/sweep-closed-issues.sh`'s sweep (wired through
  `lib/standdown.sh`), both new. The fold itself: `lib/item-lifecycle.sh`'s
  `item_lifecycle_fold`, behind the read-only `scripts/item-lifecycle.sh`.
- **Consumed:** `scripts/pickup-metrics.sh`, via `item_lifecycle_pickup_pairs`
  (see "Generalising, not duplicating" above) — the one existing reader this
  requirement moved onto the shared fold rather than left duplicating it. The
  panels that would read `scripts/item-lifecycle.sh`'s own output as a trend
  — a rate, a percentile, a dashboard tile — are Phase 2, the same as the
  rework panel above, and are not built by this document.

**The node time-state record:**

- **Produced:** `lib/node-time-state.sh`'s `log_node_state_transition`
  (immediate) and `set_node_state_terminal`/`finalize_node_state_for_cycle`
  (deferred to the end of `cleanup`) — called from `agent-cycle.sh`'s
  `stage_budget_apply` (`stage-start`) and every `stage-end` site
  (`agent-cycle.sh` itself for the Implementer/Reviewer, `lib/approver.sh`,
  `lib/enabler.sh` x3, `lib/landing.sh`, `lib/refinement.sh`,
  `lib/stage-attempt.sh` for the Co-Ordinator), `acquire_lock` (the opening
  `overhead`) and `cycle-end`,
  every `stand-down` site (`agent-cycle.sh` and `lib/standdown.sh`), every
  genuinely-nothing-selected `none-selected` site (`lib/stage-attempt.sh`),
  and `limit-hit`/`limit-cleared` (`lib/candidate-select.sh`,
  `lib/standdown.sh`). `review-cycle.sh` and the libraries it shares with
  `agent-cycle.sh` emit the identical event just past its own
  implementation-cycle check and at `review-end`, at its one
  `review-stage-start`/`review-stage-end` pair, and at
  every `review-stand-down` site except "an implementation cycle is
  running". That site, `cycle-skipped` and `review-skipped` are the three
  deliberately silent ones — see "A tick that owns no node-second emits
  nothing" above. The fold
  itself: `lib/node-time-state.sh`'s `node_time_state_fold`, behind the
  read-only `scripts/node-time-state.sh`, which unions `log.jsonl` and
  `review-log.jsonl` before folding.
- **Consumed:** nothing yet, for the same reason the rework record's own
  entry above gives: this document defines the record so it starts
  accumulating history from the moment it lands. The panel that reads it —
  D21's own time-account tile, and the constraint-naming sentence the
  roadmap's analytics surface leads with — is Phase 2, and is not built by
  this document.

## Verifying conformance

**The rework record:** `test/rework-record.test.sh` drives `lib/rework.sh`'s
`rework_fields` directly against a well-formed evidence object, an
unparseable one (asserts it degrades to `evidence: null` rather than
failing), a supplied `attributed_stage` and an omitted one, and
`repo`/`item`/`pr_url` present versus omitted. It separately drives each
detector's own reduction against a canned event stream — a
`review-gate-checks-read {ok: false}` produces a `check-failure` record and
`review-gate-checks-degraded` produces none; a `claim-lost` with `cause:
held`/`pr-held` produces a `claim-race-duplicate` record and one with no
`cause`, or `cause: unreachable`, produces none; a malformed line in the
stream is skipped rather than fatal to the reduction — covering the
degradations named in requirement 47's own acceptance check.

**The item lifecycle record:** `test/item-lifecycle.test.sh` drives
`lib/item-lifecycle.sh`'s `item_lifecycle_fold` directly against one fixture
per terminal fate, the flow invariant balancing on a fixture carrying every
fate at once, the voided-after-landed contradiction landing in `unaccounted`
(and its mirror image, voided-before-landed, resolving to `landed` outright),
`--since` bounding both the population and `window.from`, and the
degradations requirement 49's own acceptance check names: a malformed line, a
missing field, and an event naming no item, all yielding a conforming report
rather than aborting. `test/pickup-metrics.test.sh` covers
`item_lifecycle_pickup_pairs` indirectly, unchanged, by continuing to drive
`scripts/pickup-metrics.sh` end to end. The join key itself is asserted at
each producing site directly, lifting the real code the same way
`test/rework-record.test.sh`'s own detector reductions do:
`test/stage-budget-apply-join-key.test.sh` (`stage-start`),
`test/stage-end-join-key.test.sh` (`agent-cycle.sh`'s own two item-scoped
`stage-end` sites, which `stage_budget_apply` does not write),
`test/pr-raised-join-key.test.sh`, `test/checks-green-join-key.test.sh`,
`test/standdown-sweep-join-key.test.sh`,
and dedicated assertions folded into `test/landing-wiring.test.sh`,
`test/landing-retry-sweep.test.sh`, `test/approver-wiring.test.sh`,
`test/human-reviewer-handoff-wiring.test.sh` and
`test/sweep-closed-issues.test.sh`.

**The node time-state record:** `test/node-time-state.test.sh` drives
`lib/node-time-state.sh` directly: `node_time_state_for_cause` against every
one of the fourteen closed-vocabulary tokens (including the four translated
rather than renamed — `raced`/`pre-claimed` to `peer-claimed`,
`fabricated`/`untraceable` to `coordinator-declined`) and an unrecognised
one (maps to nothing); `node_time_state_idle_split` against a positive
count, a zero count and an unreadable one; `node_state_for_stage` against
the Implementer/Reviewer (`producing`) and every other actor (`overhead`);
and `node_time_state_fold` against a fixture exercising all six states on
two nodes at once, asserting the flow invariant (`balanced`,
`expected_total_seconds`) holds, that a node absent for part of the window
(and a node absent for the whole of it) both score `down` for exactly the
ungoverned stretch, that widening the window with `--until` extends the
last transition's own interval rather than truncating it, that two
overlapping event streams for one node (an `agent-cycle.sh` run and a
`review-cycle.sh` run, unioned exactly as `scripts/node-time-state.sh`
unions the two logs) still sum to exactly one window's worth of seconds for
that node — never double-counted — and the degradations requirement 50's
own acceptance check names: an unrecognised `state` value (lands in
`unaccounted_seconds`, not dropped and not misclassified), an
`idle-with-demand` event with no recognised `cause` (counts under
`unspecified`, never guessed at a real one), a malformed raw line (dropped
before it ever becomes a candidate event, uncounted), and an event naming no
node or whose `ts` is present but fails `fromdateiso8601` (excluded and
counted under `skipped_events`) — none of them fatal to the fold.
