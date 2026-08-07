# `agent-ops` Pipeline-Flow Review — 2026-08-07

Review window: **2026-08-03T22:00+12:00 → 2026-08-07T22:00+12:00** (2026-08-03T10:00Z → 2026-08-07T10:00Z).
Data: all four nodes' cycle state (`log.jsonl` + per-cycle records for `poetic-1`, `poetic-2`, `ockham-container`, `ockham-2`), the live dashboard data feed (10:06Z snapshot), every PR and issue in `Poetic-Poems/{agent-ops,poetic,poetic-fiddle}` open or touched in the window (69 PRs, 18 issues), and a fresh clone of `agent-ops` at `e581fa4`.
Detailed working papers (per-node cycle tables, PR dossiers, issue timelines, code-mechanism map with file:line citations) are in the session scratchpad under `analysis/`.

---

## 1. Executive summary

The fleet ran **368 cycles** in the four-day window. Roughly **55–60 did real forward work** (~15%); the rest stood down. The largest block of stood-down cycles — a fleet-wide "wait for quota" switch covering ~39 hours (2026-08-05T01:04Z → 2026-08-06T16:21Z, ~42% of the window's cycles) — was **not a defect**: Warwick deliberately stood the fleet down as the weekly quota neared expiry, to reserve budget for interactive sessions and to avoid an autonomous agent running out of quota mid-job and losing its work. The only defect in that episode is that the manual action was recorded as `unknown@36d6b89ec803`, which is also what led this review to initially misread it as a runaway automatic freeze.

When the pipeline was actually running, its clean path is genuinely good: **agent-ops merged 37 PRs in the window with a median open→merge of 15–40 minutes** and drained to zero open PRs. The damage is concentrated in a handful of recurring flow defects, each with a clear mechanism:

1. Completed work is **discarded at the finish line** when a stage's final message fails JSON extraction (≥9 stage runs discarded in-window, *after* the 2026-08-03 salvage fix — the surviving shapes are plain ``` fences and "I'll wait for the background task" endings).
2. Claims **lock the work item, never the PR**, so one PR was legitimately worked by **three nodes at once** (#205).
3. Completion **doesn't propagate to ground truth** — issues left open for want of a `Closes #N`, register rows not flipped, obsolete drafts never closed — so agents repeatedly re-select finished work and burn full engagements discovering it's done (the 49-entry void inventory is mostly this).
4. Blocked/dependency state is **prose re-judged by an LLM every cycle** rather than a fact checked by code.
5. Work that is genuinely waiting on the human is **invisible to the human**: none of the currently-open PRs carries a live review request, and the one true human-decision block (#203) is unassigned.

None of this needs an architectural rewrite. Fourteen work items (§6) target the mechanisms directly; two of them adopt your starter ideas in modified form.

---

## 2. What the window looked like

| Node | Cycles | Real work | Quota/limit stand-downs | No-op fingerprint | Notes |
|---|---|---|---|---|---|
| poetic-1 | 95 | 11 | 42 | 21 | 19 coordinator-ran-but-none-selected; 3 lost claim races |
| poetic-2 | 91 | ~10 | 41 | 19 | 3 stalls, 2 timeouts, 2 all-claimed |
| ockham-container | 91 | 16 | 41 | 17 | 13 none-selected; 2 claimed-elsewhere |
| ockham-2 | 91 | 18 | 41 | 19 | 2 zero-output stalls |

- **Throughput when healthy:** 13 PRs reached ready in the last dashboard accounting; agent-ops opened+merged 37 PRs in-window; poetic drained to zero open PRs.
- **Spend:** $1,290 lifetime, $91.24 on the final review day. Identified in-window waste: ~$28 duplicated on PR #205 across two nodes, ~$12.7 in discarded stalled stage runs on ockham-container alone, plus a full 90-minute implementor timeout with zero commits (issue #197) and a re-implementation of an already-merged tech-debt item (TD-PPpfid-26072801, done 15 minutes before the window opened, re-selected 21 hours later).
- **The 39-hour stand-down:** two "fleet switch: wait for quota to renew" flags, the second extending the first, both recorded as `unknown@36d6b89ec803` (a container id). This was Warwick's deliberate manual stand-down ahead of weekly-quota expiry (reserving budget for interactive use; avoiding mid-job quota exhaustion), and it behaved exactly as intended — including freezing the review pipeline. The defect is attribution only: nothing on the flag distinguishes "the operator chose this" from "a limit-detector inferred this", which matters because the correct automated response differs (see RC7).

---

## 3. Root causes

### RC1 — Results discarded at the finish line (the stall class survives)
`extract_json_result` (`agent-cycle.sh:1238-1263`) was hardened on 2026-08-03 (#192: suffix-parse salvage; #187 stranded-PR recovery; #191/#193 prompt warnings). The literal prose-then-bare-object shape is fixed. But in-window, post-fix, at least nine stage runs still exited 0 and were discarded:
- **Plain-fence JSON**: poetic-2's reviewer resolved PR #205's conflict at 04:40Z on 08-07 (rebased, CI green, "ready"), but the verdict object sat in a ``` fence without a `json` tag after a prose sentence — fallback 2 only matches ```` ```json ````, and the suffix parse fails on the closing fence. The **completed conflict resolution was erased from the pipeline's memory**, which is what allowed the whole #205 double-work cascade three hours later.
- **"Waiting on background task" endings**: four ockham-container runs and two ockham-2 runs ended with prose like "I'll check back shortly" — the model had launched background work and ended its turn; the runner discards the engagement wholesale.
- **Cost multiplier**: a discarded Enabler engagement leaves its file-claims (`claims/enabler/…`) unreleased by design; the items freeze behind them for the rest of `claim_ttl_hours` (6h) (`lib/claim.sh:60-68`). One ockham-2 stall left `pr-200-review-4843029175`'s claim never released or GC'd and the item vanished for good.

The failure is structural: **discard is the only response to an unparseable ending**. The session that did the work still exists at that moment; nothing tries a cheap continuation ("emit the verdict JSON now") before throwing the engagement away.

### RC2 — Claims lock the item, never the PR
Confirmed from `agent-cycle.sh:2861-2877` and `lib/claim.sh`: finishing sources (review-feedback / merge-conflicts / abandoned-drafts) take **file claims keyed on the item ref itself**; nothing anywhere folds `pr_number` into a claim key or into the Co-Ordinator's exclusion list (`gather_claimed`, `agent-cycle.sh:719-738`). Conflict item ids embed the **head short-SHA** (`gather-merge-conflicts.sh:154`), so every push mints a fresh id (PR #205 cycled through four).
Net effect on 08-07: ockham-container resolving `pr-205-conflict-6319fee06dfc` (07:06Z), poetic-2 working `pr-205-review-4880700727` on the same branch (07:21Z) — its coordinator *explicitly saw* the peer's claim and selected anyway ("claimed separately, but that doesn't exclude the review-feedback source") — and poetic-1's Enabler claiming the stale `pr-205-conflict-305ca060016d` (08:10Z), voided minutes later because the head had moved twice. Three nodes, one PR, ~$28 duplicated, a near-miss mid-rebase, and two `pr-ready` signals to the human 20 minutes apart.

### RC3 — Completion doesn't propagate to ground truth
The void inventory (49 entries) is dominated by agents discovering, at full engagement price, that the work was already done:
- **Missing closing keywords**: PR #206 said "Implements #198", so #198 stayed open; it was selected and voided **twice** (08-04, 08-07) and is *still open three days after its work merged*. #221 likewise voided ~5h after its own PR (#232) merged. The Implementor's own comment on #221 names this exact gap.
- **Register rows not flipped / premises gone**: `TD-PPpfid-26071901` and `26072429` still listed "open" in the sources feed despite being voided as done in July.
- **Nothing acts on a void verdict**: abandoned drafts #190 and #214 were re-derived void on **≥7 separate cycles** — never closed, so they resurface as candidates forever. Voided issues stay visible in "what the Co-Ordinator sees" (at 10:03Z the feed still listed #198 and #221).
Tombstones are private state; the world they describe is never corrected, so every union reader and every future cycle pays for the divergence.

### RC4 — Dependencies and blocks are prose, re-judged every cycle
No code parses "hold until #195 is merged" and checks #195's live state (`analysis/mechanisms.md` Q2; the only cross-ref extraction is self-identification). The Haiku Co-Ordinator re-reads a blocked issue's whole thread fresh each cycle (`prompts/coordinator.md:677-736`); non-issue blocked items get **no** re-check until the Enabler clock (3 coordinator cycles, then at most every 72h). The #196–#199 hold-back verdict is nuanced: the initial post-merge re-check actually worked (all four unassigned within 43 minutes of #195 merging), but stale "held until #195" body text kept triggering fresh false blocks, each costing an Opus Enabler round, and the label churn was self-inflicted — the pipeline cannot distinguish its own `warwickallen`-token label actions from the human's (#222 fixed this for comments, not labels).

### RC5 — Human-waiting work is invisible to the human
- **Zero currently-open PRs carry a live review request** — every prior request was cleared by a submitted review or never made. #170 has sat approved, green, and idle for 6.8 days waiting for a merge click nobody was asked to make.
- **#203** is the only genuine human-decision block in agent-ops — and it is unassigned, so it never appears on your "Assigned to me" dashboard. The contrast case proves the pattern works: poetic-fiddle's three `enabler-escalation` + assigned issues were all resolved in 1–2 hours.
- **Comment-only feedback is invisible to the pipeline**: non-review comments on #207 and poetic-fiddle #217 sat 59 and 55 hours — `review-feedback` only sees formal reviews.

### RC6 — Review-feedback bookkeeping trusts commit timestamps
PR #205 spent much of its 73.7h open invisible to selection because a conflict-resolution force-push re-stamped commit dates, which satisfied `gather-review-feedback.sh`'s "review answered" comparison; the Enabler caught it by hand. `lib/handoff.sh` already fixed two cousins of this bug (draft-not-really-ready; `CHANGES_REQUESTED` with nobody in queue) — this is the third leg.

### RC7 — Stand-down switches don't say who set them or why
The 39-hour stand-down (§2) was deliberate and correct — but it was recorded as `unknown@<container-id>`, and nothing on a switch distinguishes a **manual** operator stand-down from an **automatic** limit-detected one. That distinction is load-bearing in both directions: an automatic switch *should* be probed and cleared early when the limit turns out to have lapsed (the known "monthly spend limit 429 that was really session-window exhaustion" false positive), while a probe must **never** clear a deliberate human stand-down. Today the two are indistinguishable, so neither behaviour can be implemented safely — and a reviewer (human or agent) reading the log cannot tell an operator's choice from a runaway detector, exactly the misreading this review initially made. A long-running *automatic* fleet-wide freeze should additionally escalate to an assigned issue; a manual one plainly should not.

### RC8 — Selection-cycle waste
Losing a claim race ends the whole cycle (3× on poetic-1) instead of re-selecting the next candidate; "all-claimed" likewise. `max_open_agent_prs` (8) counts PRs that are only waiting on the human, so a full human review queue back-pressured all new work for ~7 hours on 08-06. And the Haiku Co-Ordinator's reliability is a real tax: it voided #224 citing "PR #232 implemented all five rewrites" — a **fabricated citation** (#232 belonged to #221; #224's actual fix was #235) that happened to reach the right verdict; the corroboration guard (`lib/void-guard.sh`) validated the void because the evidence *cited* a PR from this cycle's gather, not because the citation was *true*.

### RC9 — Void integrity is guarded on only one of three paths
`void_guard_reason()` corroboration runs only on the Co-Ordinator's path (`agent-cycle.sh:909`). Implementor (`agent-cycle.sh:3017-3020`) and Enabler (`agent-cycle.sh:1806-1807`) write `item-void` directly — a documented, deliberate trust gap. A valid-JSON hallucinated void from either becomes a **permanent, unrefusable tombstone** (void has no TTL; only the human `unvoided` label clears it). RC8's fabricated-evidence incident shows exactly how this goes wrong someday.

### RC10 — Cadence: an idle node waits up to an hour by construction
Cycles are one-shot scripts fired by cron, one minute-slot per node per hour (`deploy/docker/crontab`, `render-crontab.sh:90-99`). There is no "work arrived" signal and no "I finished with work still queued, go again" loop. This is the correct frame for your starter idea 2: the latency is real but it was **not** the dominant cost in this window (the deliberate stand-down aside, the discards and the invisibility classes were); it becomes dominant once those are fixed.

---

## 4. The two corner cases, resolved

**PR #205 (three agents, one PR).** Full chain: (1) poetic-2's reviewer *did* resolve the conflict at 04:40Z but the result was discarded (RC1, plain fence), erasing the resolution from pipeline memory; (2) Warwick's 07:09Z CHANGES_REQUESTED spawned a review-feedback item while the (stale) conflict state spawned merge-conflict items — different sources, different item ids, no PR-level exclusion (RC2); (3) ockham-container resolved the conflict again 07:06–08:23Z, poetic-2 worked the review item 07:21–08:43Z (its implementor had to rebase around ockham's concurrent commit mid-session), poetic-1's Enabler picked up the orphaned stale-SHA conflict item and voided it 08:13Z; (4) Warwick merged at 08:32Z off ockham's pass; poetic-2's reviewer finished 11 minutes later with nothing to do. The dashboard "Enabler + Reviewer on the same item" oddity was real, not a rendering quirk: the Enabler's *claim* on the stale item id coexisted with ockham's *cycle* on the fresh one — two items, one PR. No work was destroyed (`--force-with-lease` held); money and a duplicate review-request signal were the cost.

**Issues #196–#199.** #195 merged 01:15Z on 08-04; the initial re-check unassigned all four within 43 minutes — that part worked. #196 closed cleanly 3h28m later (the control case). The real losses: #197's finished PR sat **2d 3h 42m** with no Reviewer re-engagement after Warwick explicitly asked for a full review (RC5/RC6); #198's work merged in 8h37m but the issue is still open today for want of `Closes #198` (RC3); #199 waited 2d 11h on the ordinary human review queue (legitimate). The repeated "held until #195" false blocks each cost an Enabler round because the note is prose (RC4).

---

## 5. Assessment of the starter ideas

**Idea 1 — invert `needs-refinement` into a positive `refined` marker with a dedicated Refiner.** Adopted, in modified form (WI-11). The window's evidence says refinement *churn* (label flapping, self-triggering) hurt more than refinement *absence*, so the design keeps `needs-refinement` as the Implementor's escape hatch, adds `refined` as the positive stamp, makes the Co-Ordinator prefer refined items, and runs refinement as a cheap-model engagement decoupled from the scarce Opus Enabler. This also cleanly fixes the "who set this label" ambiguity when combined with WI-4's own-action recording.

**Idea 2 — replace cron with idle-node-picks-up-next-item.** Adopted as a staged path (WI-12), not a rewrite: (a) *finish-then-continue* — a cycle that did work and can see non-empty sources immediately runs again (bounded), which alone converts the fleet from "one item per node-hour" to "drain the queue"; (b) shorten the cron interval with the existing deterministic no-op fingerprint as the cheap gate; (c) webhook-triggered dispatch as the Phase-2 end state. Full event-driven claims coordination is where RC2's PR-level locking becomes a prerequisite, which is why WI-2 precedes it.

---

## 6. Work items

Created in `Poetic-Poems/agent-ops`, indexed by umbrella issue [#236](https://github.com/Poetic-Poems/agent-ops/issues/236). Recommended priorities in the table; the Priority project field needs setting by hand.

| # | Issue | Title | Root cause | Priority |
|---|---|---|---|---|
| WI-1 | [#237](https://github.com/Poetic-Poems/agent-ops/issues/237) | Salvage or continue a stage whose final message fails JSON extraction; release claims on discard | RC1 | Urgent |
| WI-2 | [#238](https://github.com/Poetic-Poems/agent-ops/issues/238) | Claims must exclude concurrent work on the same PR across sources | RC2 | Urgent |
| WI-3 | [#239](https://github.com/Poetic-Poems/agent-ops/issues/239) | Detect answered review feedback from review/reply events, not commit timestamps | RC6 | High |
| WI-4 | [#240](https://github.com/Poetic-Poems/agent-ops/issues/240) | Propagate completion to ground truth: closing keywords, post-merge sweep, act on void verdicts | RC3 | High |
| WI-5 | [#241](https://github.com/Poetic-Poems/agent-ops/issues/241) | Structured cross-item dependencies (`Blocked-by: #N`) resolved deterministically | RC4 | High |
| WI-6 | [#242](https://github.com/Poetic-Poems/agent-ops/issues/242) | Surface human-blocked work on the human's dashboards: assignment + live review requests | RC5 | High |
| WI-7 | [#243](https://github.com/Poetic-Poems/agent-ops/issues/243) | Machine-corroborate every `item-void` write, not just the Co-Ordinator's | RC9 | High |
| WI-8 | [#244](https://github.com/Poetic-Poems/agent-ops/issues/244) | Stand-down switches: record actor and kind (manual vs automatic); probe only automatic ones; escalate only long automatic freezes | RC7 | High |
| WI-9 | [#245](https://github.com/Poetic-Poems/agent-ops/issues/245) | Stop wasting selection cycles: re-select after a lost claim race; already-done pre-flight before engagement | RC8 | Medium |
| WI-10 | [#246](https://github.com/Poetic-Poems/agent-ops/issues/246) | `max_open_agent_prs` must not count PRs waiting on a human | RC8 | Medium |
| WI-11 | [#247](https://github.com/Poetic-Poems/agent-ops/issues/247) | Positive `refined` marker and a Refiner engagement (starter idea 1) | RC4 | Medium |
| WI-12 | [#248](https://github.com/Poetic-Poems/agent-ops/issues/248) | Reduce pickup latency: finish-then-continue, faster deterministic pre-checks, webhooks later (starter idea 2) | RC10 | Medium |
| WI-13 | [#249](https://github.com/Poetic-Poems/agent-ops/issues/249) | Reviewer must not approve a PR with failing required or security checks | — (#216) | High |
| WI-14 | [#250](https://github.com/Poetic-Poems/agent-ops/issues/250) | Keep dependabot PRs flowing: rebase or take over conflicted dependabot PRs | — (#129) | Low |

**Remedial actions taken with this review:** #198 and #221 closed as completed (work merged via #206/#232); #203 assigned to @warwickallen so it surfaces on the Assigned dashboard.

**For Warwick directly:** poetic-fiddle #170 (dependabot's codeql-action bump — approved, green, 6.8 days idle) needs its merge click; poetic-fiddle #216 is *approved but should not be merged* — a CodeQL high-severity finding ("clear-text logging of sensitive information") is failing inside an otherwise-green check list; poetic-fiddle #129 (dependabot, conflicted, CI-failing, ~12 days) will be handled by WI-14 or can be closed-and-recreated now.

---

## 7. What was already fixed before this review

Credit where due — the window itself contains the remediation wave: #187 (stranded-PR-by-claim-branch recovery), #191/#193 (no-later-ending prompt warnings), #192 (suffix-parse salvage), #222 (own-comment recognition), #235 (reviewer completion comment), plus `lib/handoff.sh`'s two confirm-don't-trust fixes and `lib/stage-budget.sh`'s adaptive timeouts. The recommendations above extend that direction: **trust nothing a model *says*; confirm against GitHub, and make the world match the verdict.**
