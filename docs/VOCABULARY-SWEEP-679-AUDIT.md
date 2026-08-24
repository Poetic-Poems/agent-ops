# Vocabulary sweep audit (#679)

This is the inventory #679's own "Done when" criterion 1 asks for: every one
of the ~2,536 lines across agent-ops mentioning "human", read and placed in
Band A (reword — the destination is now configuration), Band B (keep — a
person's job at every setting) or Band C (historical record — leave alone),
in the shape of `docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md`. Like that audit,
this records **patterns**, not a 2,536-row spreadsheet: every hit was read in
context (by a grep-and-classify pass per file, covering every match of
`\bhuman[s]?\b`), but hits sharing one mechanism are grouped into one row
here rather than repeated.

## Method

Since issue #627 landed `escalation_autonomy`, "a human" is no longer the
fixed destination of an escalation — it is one of two destinations chosen by
configuration. The same is true one layer up for `merge_autonomy`. The rule
applied to every hit:

- **Band A — the destination is now configuration. Reworded.** The
  escalation/landing *act* is named; its target is not, unless the sentence
  needs to say where it goes, in which case it names the configuration key.
- **Band B — genuinely a person, at every setting. Kept**, often retitled to
  **owner-only** so the reason travels with the claim: rulesets, credentials,
  spend, product/architecture decisions, a human `CHANGES_REQUESTED` (a
  structural veto GitHub itself enforces — the pipeline's own account cannot
  clear its own PR's review), hand-applied labels (`unvoided`, `obsolete`,
  a hand-flagged `blocked`), and the entire `human-visibility` notification
  cluster (Edge 1 below).
- **Band C — historical record. Left alone.** `CHANGELOG.md`, `docs/reviews/*`,
  resolved `tech-debt/*` records, and test fixtures reconstructing a past
  incident.

Only the Enabler's **refinement-disagreement** escalation (requirement 36b —
an item with `kind: "needs-refinement"` and `refined_before` already set) is
actually gated by `escalation_autonomy`: at `adjudicate-first` a bounded
adjudication pass runs first, and only an `inadequate`/unparseable/failed
pass reaches a person. Every other `escalate` verdict (requirement 36a —
credentials, product/architecture decisions, external services) is
unconditionally a person's at every level; that distinction was checked
against `agent-cycle.sh`'s actual branching, not assumed from prose, at every
file this swept.

## Directories swept

| Area | Lines (at sweep time) | How classified | Band A rewordings |
|---|---:|---|---|
| `prompts/` (8 files) | 234 | Every hit in every file read in context | 40 |
| `docs/IMPLEMENTATION-PIPELINE-SPEC.md` | 569 | Every hit read in context, in four overlapping-free line-range passes, cross-checked against `agent-cycle.sh`'s real branching for escalation-gating claims | ~22 |
| `lib/` (33 files) | 282 | Every hit in every file read in context | 10 |
| `scripts/` (19 files) | 216 | Every hit in every file read in context | 1 (keeping the `merge_autonomy: human` rung per Edge 3) |
| `agent-cycle.sh` | 196 | Every hit read in context, in two line-range passes | 8 |
| `config.schema.json` | 47 | Every hit read; edited via the schema `description`/`x-docs`, never a generated table cell; `scripts/render-config-table.sh` re-run after | 2 keys (3 fields) |
| `README.md` | 41 | Every hit outside the generated config-table regions read in context | 1 (plus the table regions, regenerated) |
| `docs/ROADMAP.md` | 20 | Every hit read in context | 5 (3 of which keep the `merge_autonomy: human` rung per Edge 3, reworded to "the landing gate at `human`" rather than flattened) |
| `docs/DASHBOARD-SPEC.md` | 22 | Every hit read in context | 1 |
| `dashboard/index.html` | 18 | Every hit read in context | 4 (1 of which keeps the `merge_autonomy: human` rung per Edge 3) |
| `docs/REVIEW-PIPELINE-SPEC.md` | 12 | Every hit read in context; cross-checked that `review-cycle.sh` does not read `merge_autonomy`/`escalation_autonomy` at all | 1 (the one generic "the human gate" phrase site; every other hit confirmed unconditionally correct as-is, since this pipeline has no config-selectable destination yet) |
| `test/` (64 files) | 617 | Every hit skimmed; assertions on strings this sweep changed were grepped for specifically (below) and synced; everything else is a fixture reconstructing history or an internal test comment, Band C by the issue's own rule | 2 assertions synced |
| `tech-debt/` (33 records) | 128 | Not read line-by-line: every record is either `resolved` (Band C by definition — it describes the system as it was when filed) or, where `open`/`in-progress`, checked for a live quote of "the human gate"/"needs a human" as current doctrine (none found) | 0 |
| `docs/reviews/` (3 files) | 101 | Not read line-by-line: point-in-time review reports, Band C by the issue's own rule; checked (`grep`) that none is quoted elsewhere as current doctrine outside its own folder | 0 |
| `CHANGELOG.md` | 33 | Not read line-by-line: a changelog is definitionally historical, Band C | 0 |

## Band A patterns (reworded)

| Pattern | Representative sites | Rewording |
|---|---|---|
| "needs a human" / "only a human can settle this" as an escalation destination | `prompts/enabler.md`, `prompts/enabler-adjudicate.md`, `prompts/refiner.md`, `prompts/coordinator.md`, `lib/escalation-autonomy.sh:59`, `agent-cycle.sh:5553,5834`, spec's requirement-36b thrash guard and "Escalates" bullet | "escalates" / "this stage cannot settle it" / "settled above this stage", naming `escalation_autonomy`'s two destinations where the sentence needs to say where it goes |
| "the human gate" naming the mechanism generically | `prompts/*.md` (3 sites), `agent-cycle.sh` (2), `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (5), `README.md`, `docs/REVIEW-PIPELINE-SPEC.md`, `test/coordinator-retry-fallback.test.sh` — 13 sites total | "the landing gate" (#412's own term) |
| "the human gate" naming a specific `merge_autonomy: human` rung | `docs/ROADMAP.md` (D18's own row, the D23 row, the End state's escape-ladder bullet), `scripts/publish-dashboard.sh` and `dashboard/index.html` (D18 WI-8's risk-6 condition: what autonomous landing replaces is the *synchronous* rung, not the gate, which the Script still arms) — 5 sites total | "the landing gate at `human`" — the rung is the entire content of those sentences, so it is kept, not flattened |
| "a human is waiting to land it" / "a human can merge" / "the human's merge click", asserted unconditionally for a landing decision that is actually `merge_autonomy`-gated | `lib/handoff.sh`, `lib/merge-queue.sh`, `lib/work-gone.sh`, `lib/claim.sh`, `lib/github-limit.sh`, `agent-cycle.sh`'s back-pressure claim-counting comment (the caller's own copy of `lib/claim.sh`'s), `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (requirement 15d, the cost-profile passage, the abandoned-drafts/merge-conflicts/dequeued design decisions, the Gotchas table), `README.md`'s pipeline overview and architecture diagram, `dashboard/index.html` | Names `merge_autonomy`'s ladder ("a human's click at `merge_autonomy: human`, or the Script's own arming step at `agent-merges-routine` and above") or drops the actor for a landing-state fact ("otherwise ready to land", "a landable PR") |
| The refinement-block "past one refinement, on a human" framing | `docs/DASHBOARD-SPEC.md`, `dashboard/index.html` (tooltip + comment) | "past one refinement, on escalation — `escalation_autonomy` deciding whether that reaches a human straightaway or is adjudicated first" |
| `enabler-escalation` label description | `lib/labels.sh` (both `labels_catalogue` entries), the manual-setup example in `docs/IMPLEMENTATION-PIPELINE-SPEC.md`, and the label as it already existed on every repository this fleet has created it in (`agent-ops`, `poetic`, `poetic-fiddle`) | "Raised by the Enabler: a blocked item that escalates" |
| `config.schema.json`'s "before human review" / "human-side" | `reviewer_model_default.x-docs.readme`, `max_open_agent_prs` (`description`, `x-docs.readme`, `x-docs.spec`) | "before the landing gate" / "lies outside the pipeline" |
| Requirement 32's never-implemented `needs-human` synonym for `blocked` | `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (requirement 32, requirement 8e's acceptance text), `prompts/reviewer.md`, `agent-cycle.sh` (comment) | Deleted outright (Edge 2) — no code path ever parsed it; requirement 32a's `!= ready` fall-through already provides the tolerance it promised |
| Requirement 38's opening sentence stating its membership test as a universal | `docs/IMPLEMENTATION-PIPELINE-SPEC.md` | Restated as a consequence of the configured ladder, naming #668 as the trigger to revisit it (Edge 1) — no identifier in the cluster renamed |

## Band B clusters (confirmed, kept)

| Cluster | Why Band B | Representative sites |
|---|---|---|
| `human-visibility` notification surfaces | Nothing is ever durably parked awaiting adjudication today (the adjudication pass runs inline, same cycle as the `escalate` verdict that triggers it), so there is no non-person destination for the cluster to denote (Edge 1) | `scripts/sweep-human-visibility.sh`, `scripts/gather-human-visibility-hygiene.sh`, `lib/human-visibility-hygiene.sh`, `human_nudge_idle_hours`, `ensure_human_reviewer`, the `human-review-requested`/`human-nudged`/`human-dequeue-notice` events, `<!-- agent-ops:human-nudge -->` |
| A human `CHANGES_REQUESTED` on a pull request | A structural veto, not an escalation-ladder destination: GitHub does not let a PR's author clear their own review, at any `merge_autonomy` level | `lib/handoff.sh`, `lib/merge-autonomy.sh`, `scripts/gather-review-feedback.sh`, `prompts/reviewer.md`, `prompts/coordinator.md` |
| Hand-applied labels (`unvoided`, `obsolete`, a hand-flagged `blocked`) | "Only a human may apply/reverse this" is true at every autonomy level by design — these are structural controls, not escalation destinations | `lib/void-guard.sh`, `lib/void-liveness.sh`, `lib/unvoid-label.sh`, `scripts/gather-unvoid-requests.sh`, `scripts/close-void-github-items.sh` |
| Ordinary `escalate` verdicts (requirement 36a) | Only the refinement-disagreement path (36b) is gated by `escalation_autonomy`; a credential, product/architecture decision, or external-service gap escalates unconditionally to a person at every level | `prompts/enabler.md`, `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (requirements 34d/34f), `lib/merge-budget.sh` |
| Owner-only decisions | Rulesets, credentials, spend, architecture/strategy calls — a person's call at every setting; many reworded from a bare "human" to "owner-only" so the reason travels with the claim | `prompts/enabler.md`, `prompts/refiner.md`, `prompts/coordinator.md` |
| The literal `merge_autonomy`/`escalation_autonomy` enum value `human` | Naming a config value, not narrating a claim | `lib/merge-autonomy.sh`, `scripts/doctor.sh`, `scripts/autonomy-stage-report.sh` |

## Edges settled (per the issue's own recommendations, all followed)

1. **Requirement 38's scope.** Kept; only its opening sentence restated, naming #668 as the revisit trigger. No `human-visibility` identifier renamed.
2. **Requirement 32's `needs-human` synonym.** Deleted from the spec, the prompt, and the `agent-cycle.sh` comment; no compatibility window needed since no behaviour ever depended on it.
3. **"The human gate".** Replaced with "the landing gate" at thirteen generic-mechanism sites; kept as "the landing gate at `human`" at the five sites naming a specific rung (`docs/ROADMAP.md` ×3, `scripts/publish-dashboard.sh`, `dashboard/index.html`).
4. **The escalation issue's body (#681).** Not touched by this sweep, which asserts nothing about it either way. #681 landed separately while this pull request was open (#747, `d83dd40`): the adjudication pass's own evidence is now appended to the escalation body under an `## Adjudication attempted` heading, so the prose Edge 4 forbade until it landed is both true and already written — in #747's own spec note, not here.
5. **A glossary.** Not created — the Band A/B distinction lives in requirement 36a/36b context and in `README.md`'s escalation section, not a second document.

## Slice 2 (folded into this pull request)

- The `enabler-escalation` label description, reworded in `lib/labels.sh` and updated live on every repository this fleet has already created it in.
- `lib/limit-detect.sh`'s superseded `needs_human` wire field, left exactly as named (nothing writes it anymore; renaming a cross-version compatibility fallback buys a migration for nothing, and it is Band B on its own merits regardless), with a comment recording why.
