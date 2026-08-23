# Merge-Autonomy Investigation — 2026-08-14

Question under investigation: the pipeline's owner reserves final pull-request
review, merging, and escalated issues for himself, and reports adding no real
value there — trivial items get a mechanical approval, and non-trivial reviews
are delegated to a Fable or Opus agent anyway. What would it take for the only
things that ever reach him to be (a) direction and strategic decisions and
(b) acts an agent physically cannot perform?

Data: a fresh clone of `agent-ops` at `edfad2b`; the live rulesets and repo
settings of `Poetic-Poems/agent-ops` read on 2026-08-14; the merged-PR history
of all three fleet repositories (search API + per-PR review listings); the
as-built specs, prompts and libraries cited by file:line throughout.

Outcome: **decision D18** — merge autonomy becomes an opt-in trust ladder
whose default is today's human gate, and the Poetic-Poems fleet climbs it to
`agent-merges-all`. Rollout umbrella: #402.

---

## 1. Executive summary

The human gate is one structural point — approve and merge — but it is held in
place by two different kinds of fastener, and they need different tools:

- **Doctrine.** "The human merge remains the only gate" is asserted in the
  roadmap's Vision and Assumptions, reaffirmed by D17, specified in
  `docs/IMPLEMENTATION-PIPELINE-SPEC.md:733` ("The Human Gate") and
  `docs/REVIEW-PIPELINE-SPEC.md:196`, prohibited in all four stage prompts,
  and promised in `README.md:12`. There is no numbered decision to reopen;
  removing the gate is a *new* decision (D18) plus coordinated spec, prompt
  and README amendments.
- **Identity.** The pipeline authors pull requests as the owner's own account,
  and GitHub structurally refuses self-approval and self-dismissal
  (`README.md:50-56`). Even a prompt told to approve could not. Any level of
  agent approval therefore requires a non-author forge identity first — a
  decision that is already open on the roadmap (Phase 2, forge identity,
  `docs/ROADMAP.md:269-311`) but currently priced only on rate limits.

The evidence (§3) supports the owner's self-assessment. Across all 303 merged
agent PRs, every one carries his formal review; in the 30 most recent, 30 of
32 of his reviews are plain approvals, and of the two `CHANGES_REQUESTED`
interventions, one is visibly an agent-authored work order relayed through his
account. No revert-titled PR exists anywhere in the organisation's history.
The human gate is not catching defects at a rate that justifies a human; what
it *is* silently providing is a spend ceiling (§2.3) and a backstop for a
handful of known trust gaps (§2.4) — both of which need engineered
replacements before the gate can retire.

The design (§5) is a four-level trust ladder under a new `merge_autonomy`
config key, with three invariants at every level above `human`: the **Script,
never the model, holds approve and merge rights**; landing happens only after
every deterministic gate plus an independent Approver verdict; and a human
`CHANGES_REQUESTED` blocks landing unconditionally — the veto outlives the
gate. For the Pullwright product the ladder is strictly opt-in and defaults to
`human`: nothing a customer has not deliberately configured ever lands a pull
request.

## 2. The gate as built

### 2.1 The one structural point

The Reviewer's handoff is `gh pr ready` — never approve, never merge
(`prompts/reviewer.md:8`). The Script verifies the flip rather than trusting
the report (`confirm_pr_ready`, `lib/handoff.sh:160`) and runs two
deterministic gates first: `review_gate_verdict` (`lib/review-gate.sh:301` —
required checks green at the PR's *current* head, failing closed on an
unreadable list; no security-severity code-scanning alert the base does not
already carry) and the closing-keyword gate. Everything after `ready` belongs
to the human: approval (CODEOWNERS routes it to the owner's review account),
the merge click, and — since the merge queue went live on `agent-ops` on
2026-08-14 — the enqueue click, which D17 defines as the human act.

Nothing in the system approves, merges, or enqueues: the only merge-adjacent
GraphQL in the codebase is the read-only queue probe (`lib/merge-queue.sh`).
The prohibitions are uniform across `prompts/reviewer.md:8`,
`prompts/implementer.md:7`, `prompts/enabler.md:209` and
`prompts/project-reviewer.md:8`.

### 2.2 The escalation taxonomy already matches the target

The end state the owner wants — only strategy and physically-human acts reach
him — is already written down, twice:

- The Enabler's `escalate` verdict (`prompts/enabler.md:255-262`): "a secret
  or credential only they hold, an account/settings/permissions change, a
  product or architecture decision, an external service, or information that
  exists only in their head."
- Co-Ordinator exclusions 4/5/6 (`prompts/coordinator.md:950-975`): question
  issues, security fixes whose remedy is a human decision, and work dependent
  on an unmade product or architecture decision — "Decisions belong to the
  human; never guess one on their behalf" (`prompts/coordinator.md:972`).

`create_escalation_issue` (`agent-cycle.sh:3141`) is the only path in the
entire system that files an issue at a human. At the time of writing, zero
escalation issues are open anywhere in the organisation. The human's actual
queue is merge clicks — the work is not inventing the strategic/tactical
boundary but removing everything else that crosses it.

### 2.3 What the gate silently provides: the spend ceiling

`docs/IMPLEMENTATION-PIPELINE-SPEC.md:10390-10391`: because back-pressure caps
open agent PRs, "sustained spend is bounded by the rate at which the human
merges — the system cannot run ahead of its only consumer." The human gate is
the throughput governor. Remove it without a replacement and the ceiling is
whatever the fleet can generate; §5.4 replaces the emergent governor with a
declared one.

### 2.4 What the gate silently backstops

Three known weaknesses currently resolve to "a human will notice":

- **Fail-open guards** (TD-PPagop-26081407): 88 sites where "I could not
  tell" is answered with "there is nothing". Tolerable while a human reads
  the output; disqualifying on an arming path with nobody behind it.
- **Void integrity** (flow-review RC9; prior art #243, closed): the
  Implementer and Enabler can write an `item-void` on their own say-so, and
  only the human `unvoided` label reverses one. The residual gap was
  documented as deliberate — its justification was the human backstop.
- **Human-only corroboration labels**: `obsolete` (this draft is unwanted)
  and `unvoided` exist precisely because no API call can corroborate those
  judgements. §5.5 gives `obsolete` a machine-checkable alternative and keeps
  `unvoided` human-only at every level.

### 2.5 The GitHub-side state is closer than the doctrine

Read live on 2026-08-14: ruleset #18857310 on `agent-ops` `main` requires nine
checks and code-owner review but **zero approving reviews**; the merge queue
is live (ALLGREEN grouping, squash only); `allow_auto_merge: true` is already
set at repo level and unused. Most of the platform plumbing for autonomous
landing exists — the gate is doctrine, prompts, and the authoring identity.

## 3. Evidence: what the human's review contributes

First-cut mining, 2026-08-14 (WI-1 formalises this as a repeatable baseline):

- **303 merged agent PRs** (`autonomous-agent` label): 105 agent-ops,
  79 poetic, 119 poetic-fiddle. Every one was formally reviewed by the
  owner's review account.
- **Sample: the 30 most recently merged.** 32 human reviews: 30 `APPROVED`,
  2 `CHANGES_REQUESTED`, 0 comment-only. A 93% mechanical-approval rate, in
  the owner's own description and in the record.
- **The two interventions are instructive.**
  - *poetic-fiddle#319*: a genuine human catch — left-clicking a rendered
    link in the deployed Vercel preview hit a Content-Security-Policy
    `frame-src` block. Found by exercising the running preview in a browser,
    which the pipeline Reviewer does not do (it confirms the preview
    *deployed*, `prompts/reviewer.md`, step 6). The catch is real, and its
    class is narrow: runtime behaviour of a deployed artefact. It argues for
    a browser-exercising check in the review pipeline, not for a human gate
    on every PR.
  - *agent-ops#353*: the `CHANGES_REQUESTED` body is a fully-specified work
    order — exact Dockerfile hunk, rationale, acceptance criteria — visibly
    authored by a delegated agent and relayed through the human account.
    The "human review" of the non-trivial case was already an agent review.
- **Post-merge outcomes**: zero PRs titled as reverts exist in the
  organisation, ever. (Crude proxy; the WI-1 miner adds follow-up-fix
  tracking.)
- **Latency**: median 1 h open→merge across the sample, p90 6 h. The owner is
  fast — the case for D18 is his time and the system's scalability, not
  present queue pain, though the 2026-08-07 flow review recorded a full human
  queue back-pressuring all new work for ~7 h (RC8) when he wasn't.

One honest caveat: a 7% intervention rate is not zero. Both interventions were
things an agent can do — one is a testing-coverage gap, one was already agent
work. The design's answer is not "no second look" but a cheaper, independent
one: the Approver gate (§5.2), plus a browser-exercising item for the review
pipeline's backlog.

## 4. Decision D18 and the doctrine it amends

**D18 — Merge autonomy is an opt-in trust ladder; the default is the human
gate.** `merge_autonomy` — `human` → `agent-approves` → `agent-merges-routine`
→ `agent-merges-all` — sets, per installation and per repository, who approves
and who lands a pull request. At every level above `human`, approval and
landing are acts of the Script under a non-author forge identity, performed
only after every deterministic gate and an independent Approver verdict pass;
no model ever holds approve or merge rights, and a human `CHANGES_REQUESTED`
blocks landing at every level. Where a merge queue exists, landing is
enqueueing (amending D17); otherwise it is GitHub auto-merge. Landings are
capped by `merge_budget_per_day`, which replaces the human merge rate as the
spend governor. The product default is `human`, unchanged from today.

Doctrine touched, and when:

| Document | Change | Lands with |
|---|---|---|
| `docs/ROADMAP.md` Vision, D17, Assumptions, forge-identity item | Default gate, not only gate; D18 row | The decision PR (this report) |
| `docs/IMPLEMENTATION-PIPELINE-SPEC.md:733` "The Human Gate" | Becomes "The Landing Gate": levels, Approver stage, arming requirements | WI-9, with the Approver stage (WI-5) |
| `docs/IMPLEMENTATION-PIPELINE-SPEC.md:10390` economics | Governor replacement | WI-6 |
| `docs/REVIEW-PIPELINE-SPEC.md:196` | Review PRs follow the same ladder | WI-9 |
| `README.md:3,:12,:50-56` | Product promise: default human gate, opt-in ladder, structural human veto | WI-9 |
| `prompts/{reviewer,implementer,enabler,project-reviewer}.md` | Prohibition retained for the model; attribution reworded ("the Script performs approval and landing where the trust level allows; you never do") | WI-9 |
| `config.schema.json` + generated tables | `merge_autonomy`, `approver_model_default/_complex/_critical`, `merge_budget_per_day`, `sensitive_paths` | WI-2, WI-5, WI-6, WI-7 |

Per the as-built rule (`CLAUDE.md`), each spec edit travels in the PR that
changes the behaviour it describes — which is why the table above assigns
doctrine to work items rather than to one big rewrite.

## 5. The trust ladder

### 5.1 Levels

| Level | Who approves | Who lands | Human's residual act |
|---|---|---|---|
| `human` | Human | Human | Everything — today's behaviour, byte-for-byte |
| `agent-approves` | Approver identity | Human | The merge/enqueue click |
| `agent-merges-routine` | Approver identity | Script — `complexity:low`/`medium`, no protected paths | Click for high/protected PRs |
| `agent-merges-all` | Approver identity | Script — everything passing gates | Escalation issues only |

Landing is enqueueing where a queue exists — the ALLGREEN queue, which tests
every candidate merged with the latest `main`, is the strongest deterministic
gate in the whole system, and refusing to use it while claiming autonomy would
be backwards — and `gh pr merge --auto --squash` where none does (solo
developers on personal accounts, per D3/D17, never have queues; the repo-level
`allow_auto_merge` flag is the fallback). Both are arm-and-let-GitHub-fire:
asynchronous, revocable, and already understood by the queue-aware lifecycle
machinery that landed with #388.

**The cardinal rule: the model never holds merge rights; the Script does.**
No prompt gains an approve, enqueue, or merge instruction at any level. The
arming step is a deterministic function (beside `confirm_pr_ready` in
`lib/handoff.sh`, or a new `lib/landing.sh`) that re-reads every gate fresh at
the moment of decision — the same read-at-decision-time discipline
`lib/review-gate.sh` already establishes — and every fail-closed property
stays in auditable bash rather than model intent.

### 5.2 The Approver gate

Four cost tiers, mirroring the owner's own delegation ladder (trivial →
mechanical; complex → Opus; hardest → Fable). Tier models are config slots on
the `reviewer_model_default`/`_complex` pattern, so D12 (not Claude-only)
holds; `approver_model_critical` unset falls back to `_complex`:

- **Trivial** (`complexity:low`, no protected paths, size-capped diff):
  deterministic gates only — zero model tokens. Exactly the PRs the owner
  approves mechanically today.
- **Standard** (`complexity:medium`): one Approver engagement — a short,
  read-only stage in a fresh context, `approver_model_default` (Sonnet),
  adversarial posture: *find a reason to refuse; approve only if you cannot*.
  Verdict `approve | refuse` with structured reasons. Unlike the Reviewer,
  the Approver **judges and never fixes** — the current design has the same
  agent repairing and certifying a PR; the Approver restores the
  independence the human's second look was meant to provide.
- **High** (`complexity:high`): Approver on `approver_model_complex` (Opus),
  refuse-by-default framing.
- **Critical** (`approver_model_critical`; customer zero sets Fable): fires
  in exactly two rare places — protected-path PRs once they become
  auto-landable at `agent-merges-all`, and adjudication (below). Risk
  concentrates precisely where self-modification and litigated judgement
  live, and the tier fires seldom enough that its cost is noise.

**Disagreement: refuse wins, structurally.** A refusal is posted as a real
`request-changes` review from the Approver identity, so GitHub itself holds
the PR at `CHANGES_REQUESTED` and the existing `review-feedback` source picks
it up next cycle, exactly as it picks up human feedback today. No
retry-until-yes: a refusal pins the PR out of auto-landing until a new head
commit exists. Once the same PR carries two refusals in a row, every
following round re-enters a critical-tier adjudication engagement — not once
per disagreement, but every round while that streak holds, until an approval
resets it — reading both sides and returning `land | refuse | escalate`; only
if it refuses or cannot settle does the Script raise an escalation via
`create_escalation_issue`, deduplicated to one issue per pull request so a
persisting disagreement does not raise one per round — persistent agent
disagreement is a decision being litigated, which is the human's category.
Quorum-on-every-PR was considered and rejected on cost: the merge queue
already supplies an independent deterministic vote on every candidate.

### 5.3 Identity

One GitHub App per installation — **"Pullwright Approver"** —
holds `pull_requests: write` and `contents: write`: it submits the approving
or refusing review, enqueues, and arms auto-merge. Apps are seatless on every
plan, can submit reviews, and the hosted-SaaS leg of D2 would force an App
anyway; choosing it now avoids re-deciding at Phase 4, and the hourly
installation-token minting it needs (a small `lib/` wrapper — `gh` cannot mint
App tokens natively) also relieves the rate-limit problem the forge-identity
roadmap item was opened for. The fleet's authoring identity is unchanged
(owner PAT); author and approver stay distinct accounts, which is what GitHub
requires and what preserves the two-identity audit trail. The product
end-state (two Apps, author + approver, no human identity load-bearing
anywhere) waits for the wider forge-identity decision.

Ruleset at `agent-approves` and above: `required_approving_review_count` 0→1;
`require_code_owner_review` off (code owners are users or teams — an App
cannot satisfy it, and keeping it would re-summon the human review the level
exists to retire); `dismiss_stale_reviews_on_push` on, so a post-approval push
re-opens the gate. No bypass actors: the App lands through the front door or
not at all. The human veto survives at every level — a `CHANGES_REQUESTED`
from a human account blocks landing, and the Script never dismisses a human
review (the generalisation of today's "the agent can't clear your
CHANGES_REQUESTED, ever", `README.md:50-56`, from can't to won't-and-audited).
`scripts/doctor.sh` cross-validates: a `merge_autonomy` above `human` with no
Approver identity, or at `agent-merges-routine`+ with code-owner review still
required, is a fail-fast configuration error.

### 5.4 The spend governor

`merge_budget_per_day`: a rolling-24-hour cap on Script-landed PRs, top-level
with per-repo override, default 8, `0` unlimited, enforced at the arming step
and deterministically countable from the merged-PR record. An exhausted
budget approves but does not arm — the backlog queues visibly on the
dashboard. Metering stays what it is (observability and alerting), because it
measures spend after the fact and a governor must refuse before it. If more
PRs land in a window than the budget permits — a counting anomaly that should
be impossible — the repo freezes to `agent-approves` and escalates. At
`agent-merges-routine` and above, `max_open_agent_prs` stops excluding
auto-eligible PRs from back-pressure: there is no human queue for them to be
parked in.

### 5.5 The residual human surface

- The Enabler `escalate` taxonomy (`prompts/enabler.md:255-262`) is confirmed
  as the **complete** list of what reaches a human, and
  `create_escalation_issue` as the only channel.
- `obsolete` gains a machine-checkable alternative at `agent-merges-all`:
  an independent Enabler confirmation from a fresh context at least 24 h
  after the flagging verdict, citing structured evidence in the shape
  `lib/void-guard.sh` already defines. The human label remains valid input.
- `unvoided` **stays human-only at every level**. The void-guard's argument
  is correct: the only evidence that could clear a void is the reason the
  item is void, so any agent permitted to weigh it will reason its way out of
  every void. Reversing a void is a judgement about intent — category (a) —
  and it is rare enough to cost nothing.
- The human `blocked` label stays an optional human input.
- Issue triage: the Refiner gains a Priority-banding duty with a one-way
  ratchet — set or raise a missing priority, never lower a human-set one —
  so the owner's mechanical triage disappears while his deliberate triage
  still binds.

## 6. Staged rollout

Mirrors the merge-queue adoption pattern (#377): agent-ops as the trial repo,
then the fleet. Each promotion is a one-line IaC config change (D16) raised as
a PR the owner merges — the stage-gates stay deliberate strategic acts. A
fleet-wide kill switch forcing `human` everywhere is a permanent operational
control, not scaffolding.

| Stage | Level | What changes | Rollback | Exit criteria |
|---|---|---|---|---|
| 0 | `human` | WI-1 baseline miner; WI-2 config key + kill switch as dead code; D18 merges | n/a | Baseline recorded; D18 on `main` |
| 1 | `agent-approves` | WI-3 App + ruleset (0→1 approvals, code-owner review off, stale-dismissal on); WI-4 tokens; WI-5 Approver stage; #390/#391 fixed first (the idle nudge comes back to life at count=1) | Ruleset back; level to `human` | ~50 agent-approved PRs, zero divergence between App verdict and human action |
| 2 | `agent-merges-routine`, agent-ops only | WI-6 budget; WI-7 classifier + arming (`complexity:low`/`medium`; `register-hygiene` + `tech-debt` sources; no protected paths); WI-8 digest. Prerequisites: fail-closed arming path (TD-PPagop-26081407 subset), #393–#395, #338, TD-PPagop-26081409 | Level downgrade; belt-and-braces: repo `allow_auto_merge` off | ≥30 autonomous merges or 4 weeks; zero classifier escapes; revert rate ≤ baseline |
| 3 | `agent-merges-routine`, fleet-wide | agent-ops widens to all sources + `complexity:high`; poetic/poetic-fiddle enter narrow (queues there first — poetic#175/poetic-fiddle#318, owner act; WI-10 void corroboration landed) | Per-repo downgrade | Same metrics per repo, ≥30 merges each |
| 4 | `agent-merges-all` | WI-12 protected-path controls (critical tier + ~24 h cool-off between approval and arming for gate code); WI-9 end-state doctrine complete | Kill switch | Zero human merges in 30 days at baseline revert rate, no unactioned escalations |

**Stage 3's own promotion is written out in advance** — the exact `config.json`
diff for each of the three repositories, the preconditions each edit assumes,
the order, the rollback, and a schema/doctor validation of the proposed
configuration — in `docs/reviews/2026-08-23-d18-stage-3-promotion.md`
(agent-ops#580). That document is preparation, not a promotion: no repository's
level changes in it.

The dequeue hole TD-PPagop-26081409 deserves its sentence: it was deferred *on
the reasoning that under D17 the product never enqueues*. The moment the
Script becomes the enqueuer, a dequeue is the pipeline's own problem, and the
deferral rationale is repealed — a `dequeued` facet of the `merge-conflicts`
source is the natural consumer.

### 6.1 Stage 1 exit check (2026-08-21)

Verification record for what the App-approval mechanism (WI-3/WI-4/WI-5) has
actually demonstrated, written for issue #518. This is evidence for the
Stage 2 entry decision, not that decision itself — item 2's residual and
item 3 below still stand open, and the Stage 1 row above is unchanged.

1. **The Stage 1 ruleset amendment is applied.** Ruleset `18857310` on
   `main` reads `required_approving_review_count: 1`,
   `require_code_owner_review: false`, `dismiss_stale_reviews_on_push: true`,
   `bypass_actors: []`, merge queue `ALLGREEN`/`SQUASH` — exactly WI-3
   item 2.
2. **The App's review alone satisfies the one required approval.** Six pull
   requests have merged to `main` whose only `APPROVED` review is
   `pullwright-approver-poetic[bot]`: #617, #618, #620, #622, #624, #632.
3. **Token authority to call `enqueuePullRequest` is established
   negatively, not positively.** A 2026-08-17 probe against #525 (already
   merged, so no merge could result) returned `UNPROCESSABLE` on
   pull-request state, not `FORBIDDEN` — GitHub accepted the App's
   authority to call the mutation and refused only on the pull request's
   eligibility (issue #518,
   [2026-08-17T11:44:25Z comment](https://github.com/Poetic-Poems/agent-ops/issues/518#issuecomment-5315585316)).
4. **No enqueue under the App token has ever succeeded, and no merge has
   ever been performed by the App.** Each of the six pull requests above,
   and every other recent merge to `main`, was merged by a human account
   (`Warwick-Allen` or `warwickallen`); the fleet's retained `log.jsonl`
   (covering events back to 2026-07-25T22:30Z, bounded by log rotation)
   carries no `landing-armed` event.
5. **The `--auto --squash` fallback (item 3) is unverified.** #532, the
   `allow_auto_merge` doctor check it depended on, is closed, but the
   fallback path itself has not been exercised.

**"Merged with only the App's approval" and "merged by the App" are
different facts, not two phrasings of one fact.** Statement 2 has been
observed six times; statement 4 — the App actually performing an enqueue or
a merge — has been observed zero times. A reader deciding Stage 2 entry from
this record alone should conclude that the App's *review* authority is
proven and its *merge* authority remains unexercised.

## 7. Risk register

1. **Self-merge of a gate-weakening change.** The deadliest class: a PR
   editing `lib/review-gate.sh`, the classifier, prompts, workflows, or the
   ruleset IaC, riding the routine tier through the gate it just weakened.
   Mitigation: the protected-paths classifier is deterministic code, lives on
   its own list, and runs from the first autonomous merge; Stage 4 adds the
   critical tier and a cool-off so a whole fleet-day of behaviour is observed
   before gate code changes gate behaviour; the queue re-tests everything
   against latest `main`; the kill switch survives everything. Residual risk
   at Stage 4 is accepted by D18, explicitly.
2. **Runaway spend.** The emergent governor (the human) is replaced by a
   declared one (`merge_budget_per_day`) *before* the first autonomous merge;
   breach anomaly freezes to `agent-approves`.
3. **Prompt-injection loop.** Issue or dependency content steers an agent and
   the fleet can now land the result. `prompts/` is a protected path;
   Co-Ordinator exclusion 5 keeps human-decision security fixes escalated;
   the security-alert delta gate blocks at every level.
4. **Silent outage read as "nothing to do".** Fail-open guards on the arming
   path are converted to fail-closed as a Stage 2 entry condition
   (TD-PPagop-26081407 subset; the full 88-site sweep can trail).
5. **Work destroyed by uncorroborated voids.** With the human lever
   unexercised, RC9's residual gap stops being tolerable: WI-10 lands before
   Stage 3. `unvoided` stays human-only regardless.
6. **Overnight merges with nobody watching.** Accepted deliberately: the
   queue re-tests, `failed-runs` turns post-merge breakage into selectable
   work, and the morning digest (WI-8) replaces the synchronous gate with an
   asynchronous audit. No extra unattended-window cap — one governor, not
   two.

## 8. Work items

Tracked in umbrella #402, one issue per item, `Blocked-by:` lines carrying the
dependencies. Suggested complexity in each body anchors the Implementer's
self-grading and so the Reviewer/Approver model tier — every part of the
implementation runs at the cheapest tier that can do it well.

| WI | Item | Who | Suggested complexity |
|---|---|---|---|
| WI-1 | Merged-PR history miner + Stage 0 baseline | fleet | medium |
| WI-2 | `merge_autonomy` key + per-repo override + kill switch + doctor validation | fleet | medium |
| WI-3 | "Pullwright Approver" GitHub App; agent-ops ruleset reconciliation | **owner** | — |
| WI-4 | App installation-token minting wrapper in `lib/` | fleet | high (credential-handling) |
| WI-5 | Approver stage: four tiers, refuse-wins, adjudication path | fleet | high |
| WI-6 | `merge_budget_per_day` landing governor | fleet | high (fail-closed counting) |
| WI-7 | Protected-paths classifier + arming/enqueue step | fleet | high (the security-critical core) |
| WI-8 | Autonomous-landing morning digest | fleet | low |
| WI-9 | Doctrine rewrite: §The Human Gate → §The Landing Gate; prompts; README | fleet | medium |
| WI-10 | Void + `obsolete` machine corroboration (closes #243's residual gap) | fleet | high |
| WI-11 | Refiner priority-triage ratchet | fleet | medium |
| WI-12 | Stage 4 protected-path controls: critical tier + cool-off | fleet | high |
| WI-13 | Pullwright product exposure: ladder in schema + docs, default `human` | fleet | medium |

Existing items doing prerequisite duty, not duplicated: #390, #391 (Stage 1),
#393, #394, #395, #338, TD-PPagop-26081407, TD-PPagop-26081409 (Stage 2),
poetic#175, poetic-fiddle#318 (Stage 3). One new candidate for the review
pipeline's backlog, from §3: a browser-exercising check on deployed previews —
the only class of defect the human caught that no agent currently looks for.

---

*Written by an interactive Claude Code session (Fable 5) at
@warwickallen's request.*
