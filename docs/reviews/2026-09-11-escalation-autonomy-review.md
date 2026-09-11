# Escalation-Autonomy Review — 2026-09-11

Question under investigation: in the week to 2026-09-11, six escalations and
pages reached the owner (agent-ops #1374, #1359, #1358, #1343, #1341, #1333),
plus two the listing had hidden (#1310, #1152). An interactive session
resolved every one of them on the owner's behalf from evidence the pipeline
already held; for the one it left to the owner (#1310) the owner accepted its
recommendation unchanged. The owner's conclusion: none of these needed to
reach a human. What is missing for the pipeline to make these decisions
itself, and does that require a new actor — a top-tier agent with broad
access and context, running as a bot the way the Approver does — with the
feature optional for Pullwright installations that want less autonomy?

Data: the fleet's union log as snapshotted at `2026-09-11T02:21Z`
(99,804 events across `ockham-2`, `ockham-container`, `poetic-1`,
`poetic-2`); `Pullwright/agent-ops` `main` at `fb0dd81`; the issues, pull
requests and labels of `Pullwright/agent-ops` as read on 2026-09-11; the
Poetic fleet's `config.json` as shipped on that commit.

Outcome: **no new always-on actor for escalations.** The actor the owner
describes already exists as the `decide-tactical` rung of
`escalation_autonomy` (requirement 36d), runs at the Fable tier, and is
switched on fleet-wide; it refuses almost everything for four identifiable
reasons, three of them defects. The one genuinely new actor — for pages — is
already specified as the Pipeline Monitor (#1284) and unworked. Six
recommendations, §5; disposition of each, §7.

---

## 1. Executive summary

- **The machinery exists.** `escalation_autonomy` is `decide-tactical` on
  the Poetic fleet and `enabler_model_critical` is `claude-fable-5`, so every
  Enabler `escalate` verdict already gets a Fable-tier decide pass, backed by
  a decision log filed as a closed `pw::decision` issue and a reopen-to-veto
  lever (requirements 36d, 36e; #936, #937, #938 all landed by 2026-09-06).
- **It has decided once.** Sixteen decide-tactical passes ran between
  2026-08-31 and 2026-09-10: one `decide` (#1124, 2026-08-31, which the
  Refiner then specified to — the mechanism works end to end), fifteen
  `escalate`. Every escalation the Enabler filed in that window had a pass;
  none was refused for lack of budget.
- **The refusals cluster on two conditions of the owner-only boundary
  (requirement 36a) that are misfiring**, not on judgement: condition 9
  ("reserved by the item's author") fired on the pipeline's *own* prose in
  three cases, because the fleet authors under the owner's personal token
  (#1083 unprovisioned) and the pass trusts GitHub's author field; condition
  8 ("information only in someone's head") fired on a soak threshold the
  pipeline's own record had left undefined. In #1358 the pass found a route
  inside the boundary and still refused, reasoning it must not "sidestep"
  the boundary by choosing it.
- **What is missing is authority, precedent and hands, not intelligence.**
  Authority: two boundary misfires to narrow, one rule to add, and a fourth,
  opt-in rung for the residual class the owner has now said he would accept
  by default. Precedent: the pass has no store of standing answers; the
  interactive session's advantage this week was memory of #769(b), "no new
  pins", the #1283 direction and #1128's fit history. Hands: a few acts need
  the owner's shell (compose restarts) or the owner's accounts, and the
  session performed them with his; those belong to deterministic
  reconciliation, not to a model.
- **Pages are a separate class.** Three of the six were `pw::pager` pages,
  which never reach the rung and are `owner-only` by construction. Their
  designed consumer is the Pipeline Monitor (#1284), refined on 2026-09-09
  and never selected.
- **Bot identity: yes; separate process: no.** The identity the owner asks
  for is the D25 authoring App (#1083): it fixes condition 9's
  misattribution at the root and gives the fleet its own rate-limit bucket.
  A second always-on decider would race the Enabler over the same items with
  its own claims, budget and log stream, for no gain the existing seam
  cannot deliver.

## 2. What already exists

| Piece | Where | State on 2026-09-11 |
|---|---|---|
| Three-rung ladder `always-escalate` → `adjudicate-first` → `decide-tactical` | `lib/escalation-autonomy.sh`, requirement 36a/36b/36d | shipped (#627, #936) |
| Fable-tier pass over every `escalate` verdict | `run_enabler_decide`, `prompts/enabler-decide.md`, `enabler_model_critical` | shipped; fleet config `decide-tactical` / `claude-fable-5` |
| Decision log + veto | `create_decision_log_issue`, `lib/decision-veto.sh`, `scripts/sweep-decision-vetoes.sh`, requirement 36e | shipped 2026-09-06 (#937); zero `pw::decision` issues exist because the only `decide` predates it |
| Filer-named defaults and the `pw::owner-decision` marker | requirements 36c, 39d, 42a | shipped (#938) |
| Per-installation and per-repository opt-in (D18 pattern) | `escalation_autonomy` top-level and `repos[]` override; product default `always-escalate` | shipped |
| Pager: deterministic fleet invariants, filed once per key | `lib/pager.sh`, `lib/pager-invariants.sh` (#1278, #1280–#1282) | shipped; all eight liveness invariants are remedy class `owner-only` |
| Host-vantage collector (host-facts record; conditions 7/8 carve-out) | `scripts/collect-host-facts.sh`, `docs/HOST-FACTS-SCHEMA.md` (#1283) | shipped |
| Pipeline Monitor (AI observer over the digest; files by the same taxonomy) | #1284, refined 2026-09-09 | **open, never selected** |
| Notification channel (pushes every page) | #1279, PR #1327 | open, review required |
| D25 authoring App | #1083 | **open, owner act** |
| Pass-cap decay | #1051, refined | open |

## 3. The evidence

### 3.1 Decide-tactical passes, fleet-wide, 2026-08-31 → 2026-09-10

| Measure | Count |
|---|---|
| decide-tactical passes run | 16 |
| `decide` verdicts | 1 (#1124, poetic-2, 2026-08-31) |
| `escalate` verdicts | 15 |
| `settle` verdicts | 0 |
| `escalated` events in the window | 15 |
| of which filed **without** a pass (budget spent / same reason) | 0 |

### 3.2 Owner-only conditions the fifteen refusals cited

| Condition (requirement 36a) | Refusals citing it | Items |
|---|---|---|
| 9 — explicitly reserved by the item's author | 7 | #1152/TD-PPagop-26082428, #1154, poetic-fiddle pr-367, poetic#208, #1156, #1339, #1340 |
| 2 — credentials, rulesets, secrets, settings | 5 | #1144, poetic#208, #1298, pr-1300, #1339 |
| spec-reserved act (34k void corroboration; `agent-approves` landing) | 4 | pr-363, pr-368, pr-367, pr-1300 |
| 7 — external account or host access | 3 | #1099, #714/#1266, #1339 |
| 4 — roadmap decision | 1 | #1032 |
| 8 — information only in someone's head | 1 | #1156 |

Several refusals cite more than one condition. Of the seven condition-9
refusals, three (#1339, #1340, #1156) quote text the pipeline itself wrote
— a tech-debt body's "not a guess `compose.yaml` should make on its own", an
Implementer's deferral note — attributed to "warwickallen, the owner" because
that is the login the fleet files under.

### 3.3 The week's own items

| Item | Class | What the rung did | What the session did |
|---|---|---|---|
| #1374 blocked-label-orphaned | page | never reaches the rung | found a phantom (union-log lag); filed #1378 |
| #1343 fit-ladder-pinned | page | never reaches the rung | neither lever applies; filed #1379 |
| #1341 node-stale | page | never reaches the rung | node recovered; page auto-closed |
| #1359 k8s host-facts (#1340) | Enabler escalation | `escalate`, condition 9 on pipeline prose | decided (d) now / (a) later |
| #1358 collector tailnet (#1339) | Enabler escalation | `escalate`, conditions 9, 2, 7; refused the in-boundary route | decided (a): sidecar namespace, collector on every profile — no new credential |
| #1333 17h soak (#1156) | Enabler escalation | `escalate`, condition 8 on an undefined threshold | declared the soak over |
| #1310 pre-#1295 state content (#1298) | Enabler escalation | `escalate`, condition 2 (residual exposure) | recommended the filer's `## Default`; owner accepted unchanged |
| #1152 apply `blocked` to #981 | Enabler escalation | `escalate`, condition 9 (a genuine owner direction) plus an act no stage may perform | applied the label |

### 3.4 Noise the rung never sees

Of the fifteen `enabler-escalation` issues closed in the seven days to
2026-09-11, seven carried no decide pass at all because they were not Enabler
verdicts: one Approver adjudication page (#1202) and six crash-loop pages
(#1164, #1166–#1170), the six being copies of one fleet-wide Co-Ordinator
failure on 2026-09-05 filed and retired once per flap — #1164 was retired one
second before it was filed, citing a success already two minutes old.

## 4. Why the rung refuses

1. **Condition 9 reads the pipeline's own hedges as the owner's
   reservation.** `prompts/enabler-decide.md` tells the pass to authenticate
   text by GitHub's author field, never its content — the right rule against
   injection, the wrong one for authorship while every filing is made under
   the owner's login (#1083). The filer prompts (requirements 36c, 42a) hedge
   an architecture choice as "for a human" by habit; the pass then quotes the
   hedge back as a reservation. Requirement 39d already defines the two
   markers that actually reserve a choice — the `pw::owner-decision` label
   and an `Owner decision: yes` line — and the one `decide` verdict on record
   (#1124) tested exactly those. Condition 9 should be marker-only.
2. **Condition 8 treats an undefined threshold as private knowledge.** A soak
   length, a trust bar, a count the record's author left open is not
   information in anyone's head; nobody holds it. The default-first rule
   (39d) already tells the Refiner to take the smaller of two mechanical
   options; the same rule should tell the pass to set an undefined threshold
   at the conservative end of what the record supports, record the value,
   and let the veto correct it.
3. **No in-boundary-option rule.** #1358 enumerated three routes; one needed
   no credential. The pass reasoned that choosing it would "sidestep" the
   boundary. The boundary bounds decisions, not comparisons: when at least
   one enumerated option lies inside it, choosing that option is tactical.
4. **Spec-reserved acts.** Four refusals were not decisions at all but acts a
   requirement reserves for a human at the current level: closing an
   abandoned draft behind 34k's corroboration, landing at `agent-approves`,
   applying `blocked`. These are the trust-boundary settings the owner has
   said he wants climbed, one rung at a time — a widening the ladder can
   carry as a fourth rung rather than a redraw of 36a.
5. **The cap decays.** #1051: the pass cap counts an item's whole history, so
   a long-lived item burns three passes and the rung reverts to
   `always-escalate` for it, item by item, silently.

None of these is a shortage of judgement, context or model tier. The pass ran
at the Fable tier with the item, its thread, the spec and the repository in
front of it, and in every case its reasoning was sound against the boundary
as written. The boundary is what to change.

## 5. Recommendations

1. **Narrow the misfires (requirement 36a, `prompts/enabler-decide.md`).**
   Condition 9 fires only on the two 39d markers, never on prose and never on
   the author field while the authoring App is unprovisioned. Add the
   in-boundary-option rule. Extend default-first to condition 8's undefined
   thresholds. Land #1051 with "since the last human touch" made true by a
   durable marker on the pass event. These four would have decided #1358,
   #1359 and #1333.
2. **Provision the authoring App (#1083).** Owner act. Fixes attribution at
   the root, makes condition 9 testable by author, gives the fleet its own
   rate-limit bucket. This is the "bot identity like the Approver" the
   question asked for; it is the identity, not a new process.
3. **A fourth rung, `decide-with-veto`.** Same pass, same tier, same seam,
   wider mandate: accept a residual exposure in a repository the installation
   itself owns, corroborate a void, apply or release the `blocked` pair on an
   item whose block the record shows cleared, with every such decision filed
   as a `pw::decision` and any *act* deferred by a veto window before it is
   taken, so reopening the record is a veto before the fact. Conditions 1, 3,
   4 and 6 stay owner-only at every rung, and condition 7 wherever the account
   is genuinely not held. Product default stays `always-escalate`; the Poetic
   fleet opts in. One enum value, no new config surface: this is the optional
   Pullwright feature.
4. **Give the pass precedent.** A standing-decisions file (one dated line per
   owner answer, seeded from the interactive session's own record of
   2026-08-21 → 2026-09-11), the repository's `pw::decision` records and the
   most recently closed escalations, supplied to the decide pass as
   `precedents` in its runtime input; the prompt reads precedent first, and a
   standing answer that covers the question is a `decide` citing it.
5. **Work #1284 and make the Monitor the consumer of pages.** Its digest
   already carries every `pager-fired` event and the pager's open issues; it
   files by the same taxonomy. Land it before #1279's notification channel,
   or every page pushes straight to the owner. Dedupe crash-loop pages per
   run family rather than per flap.
6. **Replace host acts with reconciliation.** A node that applies its own
   merged compose changes the way watchtower applies images — deterministic,
   no model, `.env` untouched, cycle lock respected — removes the largest
   class of condition 7 without giving any model root. Native on the
   Kubernetes target.

## 6. What none of this fixes

Answering escalations does not get them worked. #1284 sat unselected for two
days after refinement, and #1379 records the Co-Ordinator input ladder pinned
at its tightest rung dropping ~86 entries per cycle and never showing the
newest tech debt. Ticket consumption, not generation, is the bottleneck
(#1126's own finding); the rung's decisions will queue behind everything else
until the fit is fixed. The measure to watch is the Autonomy pillar's own:
human acts per landed item (`docs/ROADMAP.md`, §2), which should fall as the
rung rises and has not been reported yet.

## 7. Disposition

Recorded on 2026-09-11 when this review was written and updated the same day
once every carrier existed; the pull requests below were opened from the same
interactive session on the owner's instruction to act rather than file.
Merge state is GitHub's to report — the numbers are stable, the states below
are as of the update.

| Recommendation | Carried by | State at update |
|---|---|---|
| Record of this review | PR #1381 | merged 2026-09-11T03:08Z |
| 1 — boundary narrowing; 4 — precedent input and `docs/STANDING-DECISIONS.md` | PR #1384 (`feat/decide-boundary-precedent`) | merged 2026-09-11 |
| 3 — `decide-with-veto` rung (requirement 36f, `decision_veto_window_hours`) and the Poetic opt-in | PRs #1389 and #1390, squash-merged by the owner into #1384's branch at 04:03Z | merged with #1384 |
| 1 — #1051 pass cap since the last human touch | PR #1385 (`agent/1051`), rebased onto the merged #1384 | open |
| 5 — Pipeline Monitor #1284 with pages triage | PR #1388 (`agent/1284`), plus PR #1395 for the `pager_repo` → `crash_loop_repo` fallback the pages-triage read needs on this installation | #1388 merged 2026-09-11T06:11Z; #1395 open |
| 5 — crash-loop flap dedupe, and #1140's newest-binding fix | PR #1386 (`agent/1140`) | open |
| 6 — compose reconciler | PR #1387 (`feat/compose-reconcile`) | merged 2026-09-11; adoption is one last manual `docker compose up -d` per existing node |
| 2 — authoring App | #1083 | owner act, pending |
| 5 — ordering against #1279 | #1327 merged at 04:26Z, before the Monitor; `notify_webhook_url` (renamed from `escalation_webhook_url` by #1327) is unset on the Poetic fleet, so no page pushes anywhere until a channel is configured — if one is configured before #1388 lands, set `notify_events` without `pager` | owner act, conditional |
