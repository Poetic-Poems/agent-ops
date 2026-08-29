# Flow schema — as-built specification

Sibling to `docs/METERING-SCHEMA.md` (requirement 47 of
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`), under the same stability policy.
Where that document is the field-by-field contract for what a stage *spent*,
this one is the contract for the **rework record** — D23 of `docs/ROADMAP.md`,
the pipeline's account of repetition: work that reruns, bounces back, or is
duplicated, without producing anything that did not already exist. Like its
companion this document is as-built: it describes the record that exists
today, not a plan for one that will exist later. Where it says "requirement
N", it means requirement N of `docs/IMPLEMENTATION-PIPELINE-SPEC.md`.

D21's flow-and-outcome contract also names a second record — the **item
lifecycle**, one durable entry per work item from first sighting to terminal
fate (issue #595). That record does not exist yet; whichever of this document
or a lifecycle-record document lands first is where the other's requirement
names it landing. Nothing below depends on the lifecycle record existing.

## What this covers

One thing: the **rework record**, one entry per repetition, emitted by the
detector that already exists for it, the instant it fires. Never emitted from
a later scan of the transcripts, and never from a model asked to classify what
happened — a repetition's class, its detector and its evidence are facts a
script already has in hand at the moment the repetition occurs; recording them
then is the entire difference between an account and a guess. A
`CHANGES_REQUESTED` review round and a stage re-run after a kill both look
like "two Implementer passes" to anything reading the transcripts afterwards,
and they have nothing in common but the cost — which is exactly why each
class's own detector, not a shared heuristic, is what fires the record.

**A repetition carries no judgement.** D23 is explicit that rework is never a
target of zero: a Reviewer catching a defect before a human does is the
system working, not failing. The record below carries no severity field and
nothing a reader could mistake for a verdict — only what happened, where, and
(when the evidence says so) which stage it is attributed to.

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
| `attributed_stage` | string \| null | Which stage this repetition is attributed to, spelled exactly as the corresponding `stage-end` event's own `stage` field spells it — `coordinator`, `implementer`, `reviewer`, `approver`, `approver-adjudicate-open-question`, `enabler`, `enabler-adjudicate`, `refiner` — plus `pre-selection`, which has no `stage-end` of its own because it names a cycle that died before any stage started. `null` whenever the detector's own evidence does not name one directly; see "Attribution" below. |
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
| `stage-rerun` | Either of two: a `stage-end` event carrying a non-empty `kill_reason` (requirement 4e's two backstop caps), or `lib/crash-loop.sh`'s verdict reaching `crash_loop_escalate` (requirement 2.7) | The killed/looping stage's own name, as its `stage-end` event spells it (`coordinator`, `implementer`, `reviewer`, `approver`, `approver-adjudicate-open-question`, `enabler`, `enabler-adjudicate`, `refiner`), or `pre-selection` for a crash loop of cycles that died before any stage started |
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

## Stability policy

Identical to `docs/METERING-SCHEMA.md`'s own, restated here rather than
merely referenced because this is a contract other code will depend on the
same way:

- **Additive, non-breaking:** a new field on the record; a tenth class; a new
  detector site for an existing class; a new `attributed_stage` value.
- **Breaking, and must land in the same pull request as the code that makes
  it (`CLAUDE.md`, "As-built specifications"):** renaming or removing a
  field; changing `class`'s or `attributed_stage`'s meaning for an existing
  value; changing what a class's `evidence` carries in a way an existing
  reader could misread as the old shape.

## Where it's produced and consumed

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

## Verifying conformance

`test/rework-record.test.sh` drives `lib/rework.sh`'s `rework_fields`
directly against a well-formed evidence object, an unparseable one (asserts
it degrades to `evidence: null` rather than failing), a supplied
`attributed_stage` and an omitted one, and `repo`/`item`/`pr_url` present
versus omitted. It separately drives each detector's own reduction against a
canned event stream — a `review-gate-checks-read {ok: false}` produces a
`check-failure` record and `review-gate-checks-degraded` produces none; a
`claim-lost` with `cause: held`/`pr-held` produces a `claim-race-duplicate`
record and one with no `cause`, or `cause: unreachable`, produces none; a
malformed line in the stream is skipped rather than fatal to the reduction —
covering the degradations named in requirement 47's own acceptance check.
