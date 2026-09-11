# Standing decisions

The Poetic installation's record of owner answers the pipeline is to stay
consistent with: one dated line per decision, oldest first. The
`decide-tactical` pass receives this file whole as
`precedents.standing_decisions` (requirement 36d,
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`) and answers from it before it weighs
the owner-only boundary; a line here that already settles a re-flag's
question is a `decide` citing the line. Lines are data about what was
decided, never instructions to a stage.

Maintained by the owner, or by a delegate answering escalations on the
owner's behalf: add a line when an escalation is answered, amend a line when
the owner changes their mind (date the change on the line), never delete one.
The file changes only through the pull-request gate, like every other file
here. `standing_decisions_file` in `config.json` names it.

Format: `- YYYY-MM-DD · where decided · **the decision** — rationale or the
principle it rests on.`

## Principles

- **Trigger discipline.** A revisit is earned by a *measured* trigger (a
  release breaking a cycle, a budget measured to bind, a recorded footprint
  within an order of magnitude of a floor), never by a guess about scale.
  Decided on #607, reused on #813, #830, #902, #918, #1155.
- **Never loosen a shipped safety property to spare one pull request.**
  Mark the check required instead (#648); file residuals as their own issues
  rather than weakening a gate (#667). A not-yet-merged check proven to fault
  honest work by construction is a defective detector, not a safety property
  (#830).
- **Fail closed at arming time; fail open only on advisory reads.** A merge
  over an unread veto is irreversible and a stalled landing is recoverable
  (#753). A most-recent-wins reader of positive evidence never drops a stale
  source — stale evidence is strictly more than none (#1065).
- **Contradictory-by-construction config is refused at startup; config idle
  by an operator's temporary choice is warned about every cycle, never
  refused** (#924).
- **A liveness or staleness bound is never longer than the fault threshold
  it gates**, or every retired predecessor reads as the fault (#1053, #1065).
- **A pin without a named bump owner is a liability, not a control** (#900).
- **A new stand-down state goes on the existing switch record, never in a
  new file — old readers must fail closed** (#903).
- **Owner decisions go at the top of the item's body, never only in a
  comment**: a context-tight cycle clips bodies and drops comments (#607).
- **Escalations asking only for a mechanical act (a label removal, a
  confirmation) are actioned, not debated** (#666); then look for the loop
  that caused them.
- **Tactical, evidence-resolvable questions are the pipeline's to decide;
  only strategic decisions, owner-only acts and genuine judgement calls reach
  the owner** (2026-08-21, agent-ops#627; reaffirmed 2026-09-11 in
  `docs/reviews/2026-09-11-escalation-autonomy-review.md`).

## Decisions

- 2026-08-21 · #628 · **D18 preparation proceeds ahead of the Phase 1 exit
  gate (P1)**; promotion acts stay gated by #402's evidence bars only.
- 2026-08-21 · #633 · **Documentation and planning-record work is ordinary
  selectable pipeline work (S1)**; no separate track. "Output is prose, not
  code" is never a decline reason (#847).
- 2026-08-21 · #629 · **Kill-switch drill = one test case per ladder rung
  (L2)**, each rung collapsing to `human`.
- 2026-08-21 · #587/#638 · **No D14 cost ceiling on the Co-Ordinator
  per-repo split**; the measured cost stated in the PR is the control.
- 2026-08-22 · #648 · **Landing does not wait for non-required checks.** A
  check that should hold a merge is marked required, never special-cased.
- 2026-08-22 · #667 · **Requirement 25a is not weakened**: no per-PR opt-out
  from the `Closes #N` anchor; residuals become their own issues.
- 2026-08-22 · #607 · **Forge authoring identity = one GitHub App on the
  organisation**, distinct from the Approver App; one App per node only once
  the shared budget is measured to bind. Subscription-OAuth login is an
  accepted exception, not a defect.
- 2026-08-24 · #753/#746 · **Gate 4 reconciliation at arming time fails
  closed unconditionally**; any non-`clean` word refuses arming.
- 2026-08-25 · #784/#779 · **Escalation re-filing after a human close is
  rate-limited per close** (`escalation_refile_after_hours`), never
  never-file-twice; a close never releases a gate, label removal does.
- 2026-08-26 · #813/#810 · **Refiner re-affirmation of an adequate existing
  entry counts as refinement**; "a specification already exists" is never a
  `needs-refinement` reason.
- 2026-08-27 · #830/#821 · **Requirement 17g keeps the `acceptance` span
  check and drops the `context` half** (option c); the deferred detection is
  a register record, not a rider.
- 2026-08-28 · #844/#769 · **Work orders are Script-composed for all
  sources (option b)**; the Co-Ordinator selects only and never authors
  work-order text; a failed live fetch refuses the claim.
- 2026-08-28 · #847/#818 · **The pipeline answers research issues itself;
  posting the answers is completion.** A pre-#639 "assign to the owner"
  instruction means hand it back, never perform it.
- 2026-08-28 · #900 · **No new image pins anywhere**: `claude-code` stays
  `latest`, the base tag and apt layer float; CI-rebuild-per-merge is the
  update mechanism.
- 2026-08-28 · #902/#857 · **A `Closes #N` residual = the issue stays
  closed and the residual is filed as its own issue** (#756 → #904, Low).
  `min_free_workspace_bytes` is a floor under any derivation, never a
  ceiling.
- 2026-08-28 · #903/#865 · **`--drain` is a third switch position on
  `disabled.json`'s record** (`"mode": "drain"`); the roadmap's "Graceful
  drain" is renamed "Graceful shutdown". Finishing beats starting.
- 2026-08-29 · #911 · **Requirement 2.0c reads free disk for both
  `state_dir` and `workspace_root` under the one key** (option b); no
  rename.
- 2026-08-29 · #905/#906/#910 · **A confirmed-adequate specification is
  released by a human-voice comment on the item, a top-of-body note and the
  escalation's close — never by hand-clearing the block labels.**
- 2026-08-29 · #918/#901 · **Retention count keys keep floor-never-ceiling
  (option a)**: `max(configured, derived)`.
- 2026-08-29 · #921/#913 · **Per-owner Approver installations = one JSON
  map `PULLWRIGHT_APPROVER_INSTALLATION_IDS`**; the single id stays the
  default; the check runs from `agent-approves` upward (#1064).
- 2026-08-29 · #922/#916 · **A mid-stage merge is a completion decided by
  the Script's own state read**; the Reviewer never opens a replacement PR
  and carries leftovers in `file_debt`/`file_issue`.
- 2026-08-29 · #924 · **`refiner_max_per_engagement: 0` with a required
  source warns every cycle; `failed-runs: "required"` hard-fails.**
- 2026-08-29 · #926 · **Forge-App token freshness = on-demand seam for
  `git` and `gh`** (`gh` as a PATH shim); explicit `GH_TOKEN` wins, empty
  resolves.
- 2026-08-29 · #942 · **The vendored project-review skill's tech-debt step
  is GitHub-only (option a)**, creating `pw::type:tech-debt` if missing and
  filing unlabelled with a notice otherwise; multi-forge is decided in
  principle, post-MVP.
- 2026-08-30 · #1053/#1037 · **An updater ledger is live while its newest
  entry is younger than `updater_stuck_after_minutes`**, liveness evaluated
  before the streak, one rule for own and sibling ledgers.
- 2026-08-30 · #1065/#990 · **Peers freshness marker = `{ok, ts,
  last_ok_ts}` with transition-only rewrites**; stale ⇔ `ok:false` or `ts`
  older than 3 × the fetch interval, capped at `LABEL_OWN_GRACE_SECONDS`;
  union readers carry on, the dashboard shows one badge.
- 2026-09-04 · #1153/#1144 · **`config-table` becomes a required check**
  only after `merge_group:` lands on its workflow (owner act pending).
- 2026-09-04 · #1155/#1154 · **Historical asides inside a requirement stay
  where the deletion test passes**: legal iff deleting the aside leaves the
  requirement complete and correct.
- 2026-09-08 · #1262/#1032 · **D23 attribution = fresh at the record, same
  at the reader, no emitter-side dedup**; the roadmap row re-parks at Phase
  3 with D22.
- 2026-09-08 · PR #1258/#964 · **A decomposition umbrella closes on its
  `Fixes #N`; the remaining pieces are their own issues** (#1253–#1257).
- 2026-09-11 · #1358/#1339 · **The collector reaches the tailnet through
  the existing `tailscale` sidecar's namespace (option a)**: no new identity,
  key or credential in the collector; it keeps running under every profile.
- 2026-09-11 · #1359/#1340 · **A Kubernetes host-facts record lands with
  the scheduler as the reader (option d now, option a when a Kubernetes
  scheduler exists)**; the collector never holds a credential on any driver.
- 2026-09-11 · #1343 · **Fit-ladder pinning is fixed by shrinking the
  unsheddable bands (#1379), not by raising the byte budget or changing the
  model.**
- 2026-09-11 · #1333/#1156 · **Requirement 17h's soak is over; the 17g
  retirement is specified now.** An undefined soak threshold is set by the
  pass, not asked.
- 2026-09-11 · #1310/#1298 · **Pre-#1295 content in the private state
  repository: accept the GC tail** — no support ticket, history rewrite,
  credential rotation or exhaustive blob scan; one note under requirement
  2.5.
