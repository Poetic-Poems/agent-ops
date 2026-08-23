# D18 Stage 3 — the promotion diff, written before the decision

**Status: preparation. No repository's `merge_autonomy` changes in this
document, and none of the preconditions below is met yet.** Written for
agent-ops#580, which asks that the Stage 3 promotion be spelled out — the exact
`config.json` diff, what each edit assumes, the order, and the rollback — and
validated against the schema and the doctor *before* it is a decision rather
than after. Stage 2's own promotion (PR #560) needed a companion vocabulary fix
(#559) and a doctor warning (#554) discovered after the fact; Stage 3 touches
three repositories and six config edits.

The stage table is umbrella #402's (2026-08-18 amendment); the ladder's design
is `docs/reviews/2026-08-14-autonomy-investigation.md` §5–§6. Promotion remains
a deliberate owner act, one config pull request at a time.

## 1. The diff

Against `config.json` as at `main` on 2026-08-23. Six edits, three
repositories.

```diff
     {
       "slug": "Poetic-Poems/poetic",
+      "merge_autonomy": "agent-merges-routine",
+      "merge_autonomy_routine_sources": ["register-hygiene", "tech-debt"],
+      "merge_autonomy_protected_paths": [".github/*", "scripts/*", "CODEOWNERS"],
+      "merge_budget_per_day": 8,
       "sources": ["security", "issues:urgent", …]
     },
     {
       "slug": "Poetic-Poems/poetic-fiddle",
+      "merge_autonomy": "agent-merges-routine",
+      "merge_autonomy_routine_sources": ["register-hygiene", "tech-debt"],
+      "merge_autonomy_protected_paths": [".github/*", "scripts/*", "CODEOWNERS"],
+      "merge_budget_per_day": 8,
       "sources": ["security", "issues:urgent", …],
       "nice": 6,
       "implementation_plan_path": "docs/IMPLEMENTATION-PLAN.md"
     },
     {
       "slug": "Poetic-Poems/agent-ops",
       "merge_autonomy": "agent-merges-routine",
-      "merge_autonomy_routine_sources": ["register-hygiene", "tech-debt", "issues"],
+      "merge_autonomy_routine_sources": ["security", "issues", "review-feedback",
+        "merge-conflicts", "dequeued", "human-visibility", "abandoned-drafts",
+        "failed-runs", "tech-debt", "code-quality", "register-hygiene"],
+      "merge_autonomy_routine_complexity": ["low", "medium", "high"],
       "merge_budget_per_day": 24,
```

Notes on each choice:

- **poetic and poetic-fiddle enter at the narrow class**, which is what #402's
  Stage 3 row says: `register-hygiene` and `tech-debt` only — the schema
  default, written out explicitly so the entry states its own class rather than
  inheriting one. Both repositories gather both sources today, so neither edit
  trips the doctor's "names a source this repository never gathers" warning
  (#554).
- **poetic and poetic-fiddle each name their own protected paths**, rather than
  inheriting agent-ops's nine (agent-ops#724, which made the key configurable
  per repository). Neither repository runs this pipeline, so most of agent-ops's
  own gate-bearing paths (`deploy/`, `prompts/`, `lib/`, `agent-cycle.sh`,
  `review-cycle.sh`, `config.schema.json`, `config.json`) name nothing that
  exists there: as at 2026-08-23, poetic's tree carries no `lib/` at all and
  poetic-fiddle's is `src/lib/`, which a root-anchored `lib/*` prefix never
  matched in the first place. Only `.github/*` and `CODEOWNERS` bite today, and
  the override keeps both — so, against the inherited default, this edit is
  purely additive, and cannot narrow either repository's routine class.

  What it adds is the gap that matters. What actually gates a routine landing in
  either repository is its own CI workflows (`.github/*`, including `release.yml`
  and, for poetic-fiddle, `check-poetic-release.yml`, `td-tooling-drift.yml`,
  `required-checks-drift.yml` and `supabase-auth-drift.yml`) and the compliance
  scripts those workflows invoke (`scripts/*` — `td-check.pl` and its own tooling
  in both, `check-supabase-auth-drift.mjs` and `check-workflow-wiring.mjs` in
  poetic-fiddle) — and `scripts/*` is unprotected under the inherited list. That
  is the unsafe direction, not the safe one, and naming it here is what closes
  it. `CODEOWNERS` is kept for the same reason agent-ops keeps it on its own
  list. `supabase/migrations` is deliberately left off: a malformed migration is
  an ordinary product bug the review pipeline already catches, not a
  self-modifying gate-weakening risk the way editing `.github/*` or `scripts/*`
  is. Both lists are reasoned from each repository's layout as it stands, not
  confirmed with the owner; confirming them is part of the promotion decision,
  not a precondition this document can satisfy on its own.
- **`merge_budget_per_day: 8`** is the schema default, and again explicit. It is
  a third of agent-ops's 24 because these repositories currently raise a third
  of a pull request a day between them (§4), so the cap is nowhere near binding
  — it is there to bound a runaway, not to pace the fleet.
- **agent-ops widens to every source it actually gathers.** `project-review` and
  `implementation-plan` are absent because agent-ops's own `sources` list does
  not carry them. A conservative variant is to hold `security` back for one
  further stage; #402 does not ask for that, and the Approver's own
  refuse-by-default posture applies to a security-sourced pull request like any
  other, so the widening is written whole here and the narrowing left as an
  explicit owner choice rather than a silent one. agent-ops's own
  `merge_autonomy_protected_paths` is left unset in this diff — its schema
  default is already agent-ops's nine paths, so there is nothing to override.
- **agent-ops also widens `merge_autonomy_routine_complexity` to
  `["low", "medium", "high"]`** — the other half of #402's Stage 3 row for
  agent-ops, "+ `complexity:high`". agent-ops#725 made the ceiling
  configurable; poetic and poetic-fiddle are left at the schema default
  (`["low", "medium"]`, so their entries carry no explicit key) since #402's
  Stage 3 row widens complexity for agent-ops alone. Requirement 26a already
  forces `complexity:high` onto anything touching concurrency/locking,
  security, CI/workflow machinery or shared library code, so this widening
  routes exactly that class of agent-ops diff through automatic landing; the
  protected-path gate (belt and braces, risk register item 1) stays in force
  regardless.

## 2. Preconditions

### 2.1 Satisfied — the forge configuration

Verified live on 2026-08-23 against all three repositories. Nothing here needs
an owner act; it is recorded so a later reader can tell what was true when the
diff was written.

| Fact | poetic | poetic-fiddle | agent-ops |
|---|---|---|---|
| default-branch ruleset | 18226786 | 18828479 | 18857310 |
| `required_approving_review_count` | 1 | 1 | 1 |
| `require_code_owner_review` | false | false | false |
| `dismiss_stale_reviews_on_push` | true | true | true |
| `bypass_actors` | none | none | none |
| merge queue | `ALLGREEN` / `SQUASH` | `ALLGREEN` / `SQUASH` | `ALLGREEN` / `SQUASH` |
| `allow_auto_merge` / `allow_squash_merge` | both on | both on | both on |

poetic#175 and poetic-fiddle#318 — the merge queues #402 lists as a Stage 3
prerequisite and an owner act — are done.

One asymmetry worth knowing rather than fixing: poetic and poetic-fiddle set
`strict_required_status_checks_policy: true` (branches must be up to date),
agent-ops does not. Under a merge queue that mostly costs rework rather than
correctness (D17), and it does not block this promotion.

### 2.2 Blocking — code

| # | What | State |
|---|---|---|
| #718 | `landing_protected_paths_hit`'s changed-file read POSTs and 404s, so **no landing has ever been armed anywhere** | PR #719 |
| #572 | the stage report hard-coded `classifier_escapes` to `unavailable`, so Stage 2 could not be signed off from it | PR #720 |
| #721 | the readiness verdict never checked that the Approver App installation covers the repository | PR #722 |

#718 is not a Stage 3 precondition in the ordinary sense — it is the reason
Stage 2 has produced no evidence at all. Nothing below can start accruing until
it merges *and* the fleet picks up the image built from it.

### 2.3 Blocking — evidence

Stage 3 is entered from a *finished* Stage 2 on agent-ops, and each entering
repository must have cleared Stage 1 on its own. Measured 2026-08-23 from the
fleet's retained logs and GitHub:

| Bar | Required | agent-ops | poetic | poetic-fiddle |
|---|---|---|---|---|
| Stage 1: agent-approved pull requests | ≥15 | 41 ✅ | **0** | **3** |
| Stage 1: Approver/human divergence | zero, ≥5 settled | to re-read | no sample | no sample |
| Stage 2: autonomous landings | ≥15, or 14 days at the level | **0** | n/a | n/a |
| Stage 2: classifier escapes | zero, backed by audits | no audits yet | n/a | n/a |
| Stage 2: revert-or-follow-up rate | ≤ Stage 0 baseline | see below | n/a | n/a |

Two of these deserve their own sentence.

**The Stage 2 clock cannot start on its own.** `crit_autonomous_landings` dates
the "or 14 days" alternative from the repository's *first `landing-armed`
event*. There is none, so the elapsed alternative is not merely unmet — it is
unmeasurable, and stays that way until #718 lands. Neither the count nor the
clock is running today.

**The revert rate is close to its baseline and worth watching.** The fleet's own
`revert-rate` record of 2026-08-22 reports agent-ops at a rolling-14-day rate of
0.92 against a Stage 0 baseline of 0.883, and a cumulative-since-baseline rate
of 0.756. The criterion compares a freshly mined cumulative rate against the
baseline, so it reads as met today — but the rolling window is above the
baseline, and a promotion that raises landing throughput is exactly the change
that would move it.

### 2.4 Blocking — owner acts

1. **Confirm the Approver App installation covers `Poetic-Poems/poetic`.** The
   installation (App `4593249`, installation `153689775`) is
   `repository_selection: "selected"`. It has demonstrably reviewed pull
   requests in agent-ops and poetic-fiddle; it has **never posted a review in
   poetic**. That may simply be an empty work queue (§4) — but it cannot be
   read off `config.json`, and only the installation's own settings page or an
   App-authenticated read can settle it. Once #722 lands, `scripts/doctor.sh`
   answers this itself on any node.
2. **Merge the promotion pull request.** Each stage promotion stays a deliberate
   owner act; nothing in the pipeline may raise its own level.

## 3. Known consequences, accepted or tracked

- **A Stage 3 landing inherits every open landing-path defect**, of which two
  matter at fleet scale: the Approver's own `CHANGES_REQUESTED` cannot be
  cleared from inside the pipeline (#682, and its live escalation #712), and
  the landing gate's human-veto check does not see a plain comment posted after
  Ready (#672). Both are single-repository irritations today and become
  three-repository irritations at Stage 3.

## 4. Why the evidence is not accruing on the other two repositories

Measured 2026-08-23. This is the practical obstacle to "fleet-wide", and no
config edit fixes it:

| | agent-ops | poetic-fiddle | poetic |
|---|---|---|---|
| open issues, selectable | 40 | 0 | 0 |
| pull requests raised since 2026-08-16 | 118 | 8 | 3 |
| Approver approvals (retained log) | 41 | 3 | 0 |

poetic and poetic-fiddle have **no open issues at all**. Their remaining sources
— `tech-debt`, `register-hygiene`, `code-quality` and the scheduled
`project-review` — produce a trickle. At the observed rate, poetic-fiddle
reaches the 15-approval bar in roughly two weeks and poetic in over a month.

Three ways forward, and the choice is the owner's:

1. **Supply work.** The scheduled project reviews (poetic `not_before`
   2026-08-24, poetic-fiddle 2026-08-27) each generate a findings backlog;
   letting them run is the cheapest path to a real queue.
2. **Restate the bar for these repositories**, as #402's 2026-08-18 amendment
   already did once for Stage 2 — deliberately, in the umbrella, with the
   reasoning recorded. The blast radius of the narrow class on a repository the
   pipeline touches three times a week is small.
3. **Accept a staggered Stage 3**: agent-ops widens now, poetic-fiddle follows
   when it clears, poetic last. This is the default if nothing is decided, and
   costs nothing except that "fleet-wide" arrives in three steps.

## 5. Order, and rollback

Land in this order; each step is independently revertible.

1. #719 (arming works at all) → confirm a first `landing-armed` event, and that
   the pull request it names actually merged.
2. #720 and #722 (the report can measure, the doctor can verify).
3. Let Stage 2's bars accrue on agent-ops. Re-run
   `scripts/autonomy-stage-report.sh`; it prints the verdict this document
   would otherwise be guessing at.
4. The agent-ops half of §1's diff (widen sources, and the complexity
   ceiling to `["low", "medium", "high"]`).
5. The poetic / poetic-fiddle half, per repository, as each clears Stage 1.

**Rollback** is per repository and is a one-line config revert — `merge_autonomy`
back to absent (inheriting the top-level `agent-approves`), which returns that
repository to "the Approver approves, a human lands" without touching any other
repository. For an emergency affecting more than one, the fleet-wide kill switch
(`merge_autonomy_kill_set`, requirement 2.3b) forces every repository to `human`
within one cycle without a config change or a container restart, and is the
lever to reach for first: it does not stop cycles, only landings.

## 6. Validation

The §1 diff was applied to a copy of `config.json` and checked without being
applied to the live one:

- `jq -e . stage3-config.json` — parses.
- `scripts/doctor.sh --config stage3-config.json` — **exit 0, no failures.** Its
  warning and failure lines are byte-identical to the same run against the
  current `config.json`: the promotion introduces no new warning. The three
  warnings it does print are pre-existing and environmental (the Approver's
  runtime credential is absent on a workstation; poetic and poetic-fiddle have
  not yet been given the `blocked:needs-refinement` label).
- The per-repository lines the promotion adds all read `ok`, including
  `merge_autonomy_routine_sources are all sources it actually gathers` for each
  of the three repositories, and the ruleset trio (code-owner review off, stale
  reviews dismissed, no bypass actor) for poetic and poetic-fiddle at their new
  level.
- The autonomy-readiness verdict for all three reports `skip` on a workstation
  — the merge-queue pairing read and the App-installation permissions both need
  credentials a node has and a checkout does not. Re-run it on a node before
  promoting; that verdict is the one this document cannot stand in for.
