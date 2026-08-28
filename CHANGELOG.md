# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- New `project_review.defaults.report_directory` and
  `project_review.repos[].report_directory` config keys (agent-ops#761): a
  GNU `date`(1) format string, resolved with `date -u` relative to the
  repository root, naming where the review pipeline writes its report set and
  reads past ones from. Absent everywhere, resolution falls back to
  `reviews/project-review-%Y-%m-%d` — today's layout, unchanged — so an
  installation configuring neither key is unaffected. `review-cycle.sh`
  resolves this per repository (requirement 342's rule) and passes it to the
  Reviewer-Agent as `report_dir`; the skip-guard and the implementation
  pipeline's `project-review` Refiner source (`gather-project-review.sh`,
  requirement 3y) discover past instances of an arbitrary format string
  through the same shared `lib/report-directory.sh`, rather than the
  fixed-layout listing either used before. The write path is resolved for the
  run's own pinned `review_date`, so the folder, the branch, the claim and the
  PR title still name the same day when a sequential run crosses midnight UTC;
  a format string must be day-granular (date-level specifiers and literal text
  only), because discovery probes one calendar day at a time.
  `Poetic-Poems/agent-ops`'s own
  `project_review.repos[]` entry now sets `report_directory` to
  `docs/reviews/project-review-%Y-%m-%d`, matching where #762 already moved
  its most recent review — without this, the next scheduled review of this
  repository would have written back into the pre-#762 location.
- The BYO API-key model-credential path (D4's primary, agent-ops#684) is now
  documented alongside subscription OAuth (the existing, self-hosted
  alternative) rather than the deployment covering only the latter:
  `deploy/docker/.env.example`, `compose.yaml` and `README.md` name
  `ANTHROPIC_API_KEY` as the first-class path, with OAuth's constraints
  (interactive login per node; own-use only) stated for the alternative.
  `scripts/doctor.sh`'s Claude section now reports on whichever of the two
  paths a node actually carries — a well-shaped `ANTHROPIC_API_KEY` is `ok`
  and OAuth is not consulted, a badly-shaped one is `warn`, and OAuth status
  is read (as before) only when no key is present — instead of always
  reading OAuth status and skipping the other path; the stream-flush probe
  gates on either credential rather than OAuth alone. No default or running
  configuration changes: `ANTHROPIC_API_KEY` is unset unless an operator
  sets it, same as every other credential in `compose.yaml`'s environment
  block.
- New `label_prefix` config key (default `pw::`, agent-ops#840) and
  `lib/labels.sh`'s `labels_reconcile`/`labels_reconcile_role`: full CRUD —
  create, reconcile colour/description drift, and delete once no longer
  catalogued — for any label whose name starts with the prefix, further
  colons and all. Every label outside that namespace keeps `labels_ensure`'s
  own create-only, never-touch treatment, so an operator's own recolouring is
  still never undone; empty disables reconciliation and deletion entirely.
  Deletion is scoped to `labels_reconcile_role`'s `target` role, the one
  catalogue call that is a repository's complete desired label set; `review`
  and `escalation` reconcile drift without ever deleting, since each is a
  partial subset whose own deletion pass would remove labels the other role
  still wants. No call site uses either function yet — the pipeline's own
  catalogue entries are still unprefixed, and renaming them is a live
  migration recorded as TD-PPagop-26082809.
- An abandoned tech-debt reservation branch is no longer left orphaned for
  good when its own release attempt fails (TD-PPagop-26082427). A `td/<id>`
  or `td-record/<id>` branch `lib/tech-debt-file.sh`'s `_techdebt_unfile`
  could not delete — the same GitHub API whose failure put it on that path
  is the same window most likely to fail the `DELETE` meant to undo it —
  now writes a durable marker into the state repository's
  `reservation-releases/` tree instead of only logging and swallowing the
  failure. New `scripts/release-pending-reservations.sh` retries every
  pending marker each cycle (`lib/standdown.sh` step 2.1g) until the branch
  is confirmed gone, clearing its own marker once it is. Observed for real
  on this repository: fourteen consecutive reservations orphaned in a
  seventy-second window on 2026-08-23, none of which any existing sweep
  would ever have released.

- New `tech_debt_branch_prefix` config key (default `td/`, agent-ops#655): the
  human tech-debt-claim protocol's (`TECH-DEBT.md`) own branch prefix was a
  bare `"td/"` literal in `lib/claim.sh`, the four `gather-*.sh` sources and
  `sweep-orphan-branches.sh`, with no way for an adopting repository that
  does not follow that convention to change or disable it. All six sites now
  read the new key instead; left unset, it defaults to `td/` and behaviour is
  unchanged. Empty disables the tech-debt namespace, so those scripts then
  match only `branch_prefix`.
- A trimmed Co-Ordinator candidate's `acceptance` is now checked against the
  item's own live text before it is claimed, not just against its recorded
  refinement (requirement 17g, issue #821, decided agent-ops#830 option (c)):
  `item_text_fault` (`lib/candidate-select.sh`) re-fetches an issue's full
  thread or a tech-debt item's register file fresh and faults an
  `acceptance` backtick-quoted specific that text does not support —
  reproducing and closing the #815 incident, where a Co-Ordinator whose input
  had been trimmed to fit its model's window invented an `acceptance` in
  full, and requirement 17f's own repair logged the result a success.
  `context` is not checked: the work-order schema requires it to carry the
  Co-Ordinator's own framing prose alongside the entry's verbatim paste, with
  no marker for where the paste ends, so a check faulting unrecognised
  paragraphs faulted that mandated framing on ordinary honest work orders
  (TD-PPagop-26082801 tracks the deferred detection gap against #769). Unlike
  a missing refinement, an `acceptance` fabrication fault is never repaired —
  it is a hard skip, logged with its own `cause: "fabricated"`, distinct from
  `untraceable`. A trimmed candidate that clears the check is still
  unconditionally supplied the item's live text via `item_text_supply`
  (a no-op once it is already there), so "the live read demonstrably
  happened, or the Script supplies the full text itself" holds either way.
- Requirement 4i's `warning` events (both the allowance-exhausted warning and
  the warning logged when a fit still does not fit at one entry per band)
  and the `coordinator-input-fitted` event now carry a `terms` object
  breaking the measured overhead down by band — `prompt`, `blocked`,
  `refinements`, `claimed`, `scaffold` — so a `prompt_too_long` refusal names
  which half of the document was actually too big directly off the cycle
  log, rather than requiring a live shell into the container to re-derive
  each band by hand (issue #645).
- A `blocked`/`blocked:needs-refinement` pair whose block has cleared now
  comes off the issue even when nothing in the shared log can prove the
  pipeline applied it (requirement 38b, agent-ops#816, TD-PPagop-26082602).
  The existing reconciliation sweep keys on a logged `own-label-action add`
  with no later `remove`, which two real cases never have: a label
  `scripts/sweep-legacy-refinement-assignees.sh` applied, since it runs
  outside a cycle and has no log of its own to append to, and one whose
  block cleared before that logging existed at all. Both left the issue
  excluded by `scripts/gather-issues.sh`'s deterministic `blocked`-label
  filter for good, invisibly — twelve high-priority issues in
  `Poetic-Poems/agent-ops` were sitting in exactly that state, cleared by
  hand on 2026-08-26. New `refinement_blocked_label_orphaned`
  (`lib/refinement.sh`) proves the same fact from live GitHub state instead
  of from history — `blocked:<reason>` is never a name a human reaches for,
  so its presence on an open issue with no open block behind it is proof
  enough on its own. `lib/candidate-gather.sh` runs it once per repo per
  cycle, ahead of the issue gather, so a freed issue re-enters candidacy the
  same cycle rather than the next one. A bare `blocked` with no reason label
  beside it is never touched, so a label a human applied for their own
  reasons is as safe as it was before; the residue that leaves — a
  legacy-swept issue whose reason label was released successfully, keeping
  its `blocked` for good — is recorded as TD-PPagop-26082608.

  Three guards keep that live read from over-acting, all added on PR #823's
  own review. The generic `blocked` rides along only when the issue's own
  block history — a modern `attempt-failed` event's `blocked_label` field,
  or the absence of one at all — actually says this pipeline put it there;
  a modern event that recorded finding `blocked` already present (a human's
  own hand) leaves it alone even though the reason label still comes off.
  The whole reconciliation is skipped for a cycle whose fleet-wide log looks
  degraded — an empty union, or a peers directory whose own fetch marker
  reports failure (`lib/fleet.sh`'s new `fleet_logs_healthy`) — rather than
  reading that silence as proof no block exists. And a label applied too
  recently for its own block record to plausibly have reached this node yet
  (within `LABEL_OWN_GRACE_SECONDS` of `union_log_horizon`, the same
  tolerance requirement 39f already measures peer label writes with) is
  deferred to a later cycle rather than stripped.

- A model-tier floor (requirement 1c, issue #822): `lib/model-id.sh` now
  ranks the fleet's models by capability
  (`claude-haiku-4-5-20251001` < `claude-sonnet-5` < `claude-opus-5` <
  `claude-fable-5`), and `scripts/doctor.sh`/`agent-cycle.sh` refuse a
  configuration where `refiner_model` or `enabler_model` — the two stages
  that can author a work order's `context`/`acceptance` directly — ranks
  below `implementer_model_default`/`implementer_model_trivial`, or where a
  `refinement_policy` source is `"required"` with no `refiner_model`
  configured to ever refine it. `refinement_policy`'s shipped default now
  names `tech-debt` alongside `issues` as `"preferred"`, and this
  installation's own `config.json` sets both to `"required"`, closing the
  gap #815 (fixed by #819) and #821 both traced to a cheaper model authoring
  a specification for a more capable Implementer.

- `scripts/state-sync.sh`'s mirror is no longer trusted just because its
  `.git/` directory still exists (requirement 2.5, issue #604): `mirror_init`
  now runs `git fsck --connectivity-only` against a mirror that already
  existed, and on any failure discards it and rebuilds it from source
  instead of continuing to read from and publish a corrupted checkout — the
  behaviour observed on ockham-container from 2026-08-08 and ockham-2 on
  2026-08-24, where an unclean shutdown left truncated loose objects and
  `git gc` failed at repair for four days with no visible failure anywhere.
  A rebuild is recorded durably under `state_dir` and published as the
  heartbeat's new `mirror` field, alongside the existing `compose`/`image`/
  `switch` verdicts, so a repeat rebuild reads as a repeat rather than one
  more indistinguishable line.
- Every escalation route now reaches an operator even when GitHub itself
  rejects the node's own credential (requirement 2m, TD-PPagop-26082304): a
  new optional `escalation_webhook_url` config key, POSTed to
  from inside `create_escalation_issue` (`lib/enabler.sh`) on every failure
  to file — most often the same dead `GH_TOKEN` requirement 2.0b's
  auth-failure check has just detected, which previously left the
  escalation issue itself unable to file, `warning`-and-retry the only
  trace, and nobody outside the node told. The fallback lives inside the
  shared `create_escalation_issue` rather than at each of its call sites, so
  2.0b's auth-failure escalation, 1c's usage-limit freeze escalation and
  requirement 2.7's crash loop all pick it up identically. Unset (the
  default) is a no-op: an installation that configures none of this behaves
  exactly as before. Switching it on is two edits per node rather than one —
  the key is fleet-wide (`config.json` ships in the image), while the
  webhook's host has to be named in each node's own `EGRESS_EXTRA_ALLOW`,
  since the scheduler reaches the internet only through the default-deny
  egress fence (D24) and an unlisted host turns every POST into a proxy
  `403`, which in the log is indistinguishable from a webhook that is down.
- A pull request the Approver refused no longer relies on the same cycle
  that fixed it to also re-review it (requirement 46, agent-ops#682): a new
  fleet-wide restale sweep (`_approver_restale_sweep_repo`, `lib/approver.sh`)
  detects a standing Approver `CHANGES_REQUESTED` whose `commit_id` no
  longer matches the pull request's head — never GitHub's
  `requested_reviewers`, which silently no-ops for the Approver's own Bot
  identity — and, where a commit was genuinely authored since the review
  (never a rebase alone, which cannot move an authored date), triggers a
  real re-review by reusing `run_approver_stage` itself, falling back to a
  self-dismissal (`PUT .../reviews/{id}/dismissals`) only when that
  re-review could not even be attempted. A rebase-only-stale review — the
  head moved, but nothing was authored since — is left alone until the new
  `approver_restale_escalate_after_hours` config key (default 24) elapses,
  then escalated to `enabler_assignee` instead of retried forever. Closes
  the gap that left PR #621 blocked for 13.5 hours on a fix nobody re-reviewed.
- A fine-grained PAT's own expiry is now read and acted on before it arrives
  (agent-ops#694, agent-ops#691's own postmortem): GitHub states it on every
  authenticated API response (`GitHub-Authentication-Token-Expiration`), and
  `scripts/doctor.sh --unattended`'s existing hourly pass now reads it — the
  same free `/rate_limit` call requirement 2.0 already reads — recording
  `{expires_at, days_remaining}` in `.doctor-status.json`. The dashboard's
  Doctor panel shows the day count alongside the existing fail/warn table,
  amber under a 7-day threshold. `agent-cycle.sh` escalates once per expiry
  timestamp — through the same fleet-scoped, deduplicated route the crash-loop
  and dead-credential (agent-ops#691) checks already use — when a node's own
  token falls under that threshold, so a rotation is never again the fleet's
  only warning that its credentials are about to lapse.
- A Reviewer that finds a pull request otherwise green and finished, but
  carrying a question about the work order or its scope it is not the right
  actor to settle, can now say so structurally (requirement 32/8f, D18,
  agent-ops#668): an `open_questions` entry alongside a `ready` verdict.
  The landing gate refuses unattended landing while one stands
  (`open-question:`-classed, grouped by the *Autonomous landings* panel with
  no dashboard change needed) and requirement 8u's retry sweep holds it
  across cycles through the identical gate. It resolves through the
  `escalation_autonomy` ladder: at `always-escalate`, one escalation issue
  per pull request; at `adjudicate-first`, one bounded adjudication pass at
  the Approver's own critical tier (`prompts/approver-adjudicate-open-
  question.md`) settles it with a posted answer or escalates — distinct
  from both the Approver's own refuse-streak adjudication (requirement 8c)
  and the Enabler's refinement-disagreement one (requirement 36b). A new
  head commit never clears it; only a settled adjudication or a human's own
  act does.
- A per-stage health verdict (agent-ops#662), for the incident a `RUNNING`
  cycle and a clean fleet check both stayed silent about on 2026-08-21: every
  stage failed for 10.5 hours and nothing read `stage-end`'s own `exit_code`
  to say so. `lib/stage-health.sh` derives, per stage on each node,
  `last_success`, a `consecutive_failures` streak (reset by any success),
  the most recent failure's own detail, and a verdict (`idle`/`ok`/`failing`
  once three consecutive whole-cycle failures accumulate). Written
  atomically to `state_dir/.stage-health.json` at the end of every cycle
  (`write_unattended_status`'s own precedent), it now surfaces as a new
  `stages:` section in `agent-cycle.sh --status` (and so in
  `check-nodes.sh`, which already prints `--status` per node), and — folded
  into the fleet heartbeat alongside the compose/image/switch verdicts — as
  a **Stage health** dashboard section plus a fleet-strip badge naming which
  stage(s) are failing, independent of that node's own running/idle state.
- The scheduler's egress is fenced (agent-ops#760; roadmap D24 stage two,
  review F-SEC-01, `TD-PPagop-26082407`/`TD-PPagop-26082429`): it now sits
  on an internal-only Docker network — no gateway, so the fence is topology
  rather than convention — and reaches the internet solely through a new
  `egress-proxy` service, squid on the same agent-ops image, permitting
  only HTTPS CONNECT to the domains in `deploy/docker/egress-allowlist.txt`
  (every entry commented with the code that needs it, several reachable
  only via redirects no grep would find) plus a node's own
  `EGRESS_EXTRA_ALLOW`. Claude Code's optional traffic — update checks,
  telemetry, error reporting, claude.ai connectors — is disabled in the
  scheduler's environment rather than allowlisted. Being compose-level,
  the fence reaches an existing node only by hand (`README.md`, "The
  egress fence"); until then the node self-reports compose drift, and
  `scripts/doctor.sh`'s new Egress section probes the live fence's three
  failure shapes — path broken, allowlist not enforcing, direct egress
  still open — on every unattended run. `test/egress-fence.test.sh` pins
  the static shape, and the image build refuses a squid config or an
  empty allowlist rather than shipping either to a node.
- Every stage prompt now states its untrusted-content stance explicitly: a
  canonical `## Untrusted external content` block — byte-identical across
  all eight prompts, stated canonically in
  `IMPLEMENTATION-PIPELINE-SPEC.md`'s new requirement 45 (R18 in
  `REVIEW-PIPELINE-SPEC.md` for the project reviewer) — frames
  forge-authored free text (issue and pull-request titles and bodies,
  comments, review text, commit messages — embedded in a stage's input or
  fetched mid-run) as data about the work, never instructions to the stage
  (agent-ops#759; roadmap D24 stage one, review F-SEC-01,
  `TD-PPagop-26082407`). The line it draws: such text may define *what the
  work is*, and can never change *how the stage operates* — nor
  authenticate anyone, since a `pipeline:` stamp in a comment body can be
  typed by any account. `test/prompt-untrusted-framing.test.sh` pins every
  copy to the spec's canonical one at run time, so the one containment
  that is only words cannot quietly become different words.
- The routine landing class's protected-path list — the whole-path prefixes a
  routine-tier landing must touch none of before it can land unattended — is
  now a config key, `merge_autonomy_protected_paths`, with a per-repository
  `repos[]` override on the same precedence `merge_autonomy_routine_sources`
  uses (agent-ops#724, D18 Stage 3 preparation). It defaults to agent-ops's
  own nine paths byte-for-byte, so nothing changes for any repository until
  it names its own list — a repository whose gate code lives elsewhere (a
  product `lib/` that is ordinary code, a release script under `scripts/`)
  can now declare the paths that actually gate *its* release rather than
  inherit a list written for agent-ops. `scripts/detect-classifier-escapes.sh`
  resolves the same configured list, from its own independent
  reimplementation, so the post-hoc audit can never disagree with the gate
  about what counts as protected.
- The `agent-merges-routine`/`agent-merges-all` complexity ceiling is now
  configurable, `merge_autonomy_routine_complexity` (default
  `["low", "medium"]`, a `repos[]` entry may override it per repository, the
  same precedence `merge_autonomy_routine_sources` uses), rather than
  hard-coded `low`/`medium` in `landing_eligible` (D18 Stage 3, agent-ops#725).
  `scripts/detect-classifier-escapes.sh` reads the same effective list when
  recomputing whether a landed pull request was actually eligible. Widening
  it to admit `high` is a bigger step than it looks: requirement 26a already
  forces that grade onto anything touching concurrency/locking, security,
  CI/workflow machinery or shared library code, so admitting `high` here
  routes exactly that class of diff through automatic landing — the
  protected-path gate stays in force regardless.
- `scripts/doctor.sh`'s D18 autonomy-readiness verdict now checks that the
  Approver App installation can actually see each configured repository, not
  only that its permissions are right (agent-ops#721). The installation is
  `repository_selection: "selected"`, so a repository can sit at
  `agent-approves` or above and simply not be in the selection — and the
  verdict would have read "fully supported by its forge configuration" over an
  App that could neither review nor land there. A repository the installation
  does not cover is now a `fail` naming the owner act that fixes it, from
  `agent-approves` upward — the same rung the permissions check binds at,
  since posting a review is what needs the App to see the repository at all.
  `lib/approver-token.sh` gains `approver_token_installation_repositories`,
  an installation-token-signed `GET /installation/repositories`: the JWT read
  behind the permissions check reports `repository_selection` but never the
  list, so the two questions need the two identities. A `repository_selection`
  of `all` covers everything by construction, and a listing that could not be
  read whole — a page shorter than its own `total_count`, a non-200, an
  unreachable API — reports `unconfirmed` for every repository rather than
  "does not cover", so no read failure can mint a `fail` that reads as an
  owner act.
- `pr_label` now reaches the Implementer, so an installation can change the
  label its implementation pipeline puts on the pull requests it raises
  without forking `prompts/implementer.md` (agent-ops#654). The
  Co-Ordinator's runtime input carries the configured value, its work order
  carries it on to the Implementer as `pr_label` — as does a mechanical
  fallback pick (requirement 3v), which composes its own work order — and
  the Implementer labels its draft with that field instead of the literal
  `autonomous-agent` the prompt used to name. Nothing changes for an
  installation that has not set `pr_label`: it still defaults to
  `autonomous-agent`, which every gatherer and the back-pressure limit
  already find pull requests by.

- A rejected GitHub credential is now caught before the Co-Ordinator ever
  runs, instead of being spent on and misreported as an outage (agent-ops#691).
  `github_auth_probe` (`lib/github-limit.sh`) reuses the same free
  `/rate_limit` call requirement 2.0's budget check already makes, but
  classifies an HTTP 401 apart from every other failure. A new,
  unconditional stand-down check (requirement 2.0b) runs it ahead of the
  Co-Ordinator: an expired or revoked `GH_TOKEN` now stands the cycle down
  immediately with `GitHub authentication failed (HTTP 401) — GH_TOKEN is
  invalid or expired`, rather than costing a full Co-Ordinator engagement
  every cycle only to have every claim fail with the misleading "this is an
  outage, not contention". It also escalates — once, deduplicated — through
  the same `create_escalation_issue` route requirement 1c's usage-limit
  freeze and requirement 2.7's crash loop already use, filed in
  `crash_loop_repo`.

- A durable **landing audit record** (requirement 8x, D18, agent-ops#578):
  `_landing_stage_attempt` (`agent-cycle.sh`) now logs `landing-audit-record`
  once, alongside `landing-armed`, at the exact moment it arms a pull
  request — the pull request's own number and head SHA, the effective
  `merge_autonomy` level and whether it came from a repository's own
  override or the top-level key (`merge_autonomy_resolution_source`,
  `lib/merge-autonomy.sh`), the work source and complexity label, the
  protected-path verdict and the protected paths it hit, the Approver's
  tier/model/verdict/adjudication and this pull request's full adjudication
  history (`landing_approver_adjudication_history`, `lib/landing.sh`), every
  deterministic gate this attempt passed with its own evidence, the merge
  budget's decision object, and the landing mechanism. What justified an
  autonomous landing was previously spread across a cycle record, a
  dashboard digest row, a GitHub review and a log line, joined by whoever
  asked; now it is assembled once, at arming time, and never reconstructed.
  `scripts/publish-dashboard.sh`'s WI-8 autonomous-landing digest reads this
  record instead of re-joining `approver-verdict` events against
  `landing-armed` by timestamp, and reports a landing with no matching
  record as its own anomaly rather than rendering silent nulls — the older
  verdict join lives on only to explain the tier and verdict of a
  `landing-armed` from before this record existed, which stays an anomaly
  either way;
  `dashboard/index.html`'s landings panel gained a Record column
  (`ok`/`missing`) and a summary line for any such anomaly.

- Any pipeline stage can now log deferred work it notices — a
  `tech-debt/<id>.md` record or a plain GitHub issue — riding along in the PR
  or output it is already producing, instead of losing the finding to a
  review body or deferring it to a separate round trip (agent-ops#631).
  `TECH-DEBT.md` documents the reserve-then-file-on-current-branch variant
  ("Filing alongside other work") as generally available, with a dedup
  helper (`scripts/find-similar-tech-debt.sh`) and an automatic release of
  the `td/<id>` reservation branch once its record lands on `main` via any
  pull request (`.github/workflows/release-td-branch.yml`,
  `scripts/release-td-branch.sh`) — manual branch deletion is now a
  fallback, not the only path. The Implementer and Reviewer may file inline
  on their own branch; the Approver and Enabler, which must never write to
  GitHub themselves, gain structured `file_debt`/`file_issue` output fields
  the Script fulfils on their behalf (`lib/tech-debt-file.sh`), under the
  Approver's own App token where one applies. The first record filed under
  this workflow is `tech-debt/TD-PPagop-26082202.md` — the single-slot
  ownership record `lib/issue-priority.sh` was already carrying, found on PR
  #618 and previously unfileable because it could not land in that pull
  request.

- D18's Stage 2 exit criterion ("revert rate ≤ baseline") is now measured
  continuously rather than only by hand (agent-ops#579): a new daily
  `scripts/publish-revert-rate.sh`, on its own crontab line
  (`schedule.revert_rate_hour`/`revert_rate_offset_minutes`), runs
  `scripts/mine-merge-history.sh` — which gains a `--since ISO8601` flag to
  bound the mined population — over three bounded windows per repository and
  appends a rolling-window (14 days, excluding the last 48 hours, floored at
  10 samples), cumulative-since-baseline, and stored-baseline
  revert-or-follow-up rate to `revert-rate.jsonl` in `state_dir`, replicated
  fleet-wide exactly like `log.jsonl`. The Stage 0 baseline figures
  (`docs/reviews/2026-08-15-merge-autonomy-baseline.md`) are copied into
  `config.json`'s new `revert_rate_baseline` as a fixed reference rather than
  re-derived at runtime. The dashboard gains a "Revert rate by repository"
  panel beneath Autonomous landings, showing all three figures per
  configured repository and badging whether the cumulative rate sits at or
  below the stored baseline.

- D18's fleet-wide `merge_autonomy` kill switch (WI-2, agent-ops#405) is now
  exercised end to end against the landing path (agent-ops#576): gate 1 of
  `_landing_stage_attempt` (`agent-cycle.sh`) asks `merge_autonomy_kill_state`
  a second, independent, `FRESH` time whenever the effective level does not
  qualify, and `landing_autonomy_refusal_reason` (`lib/landing.sh`) tags the
  refusal `kill-switch:` when the switch is the actual cause — distinguishable
  in the `landing-refused` log, and in `scripts/publish-dashboard.sh`'s
  landings digest, from a repository that has simply never had its level
  raised, which keeps the plain "effective level is …" wording. One test case
  per `merge_autonomy` rung (`test/landing-kill-switch-wiring.test.sh`) proves
  the collapse to `human` through the real landing path with nothing armed.
  The dashboard now also surfaces the switch's own position — sourced the
  same way `scripts/doctor.sh` already does — as its own banner, separate
  from the fleet-wide disable banner since cycles keep running while only
  landing collapses to `human`.

- A per-repository **autonomy-readiness verdict** in `scripts/doctor.sh`
  (agent-ops#575, D18 Stage 3 prerequisite): one line per repository saying
  whether its *configured* `merge_autonomy` is something the forge
  configuration can actually support right now, naming every unmet
  precondition and tagging each as an **owner act** (a ruleset, repository or
  App-installation setting only an admin can change) or a **configuration
  error** (this fleet's own `config.json`). Configured above what the forge
  supports is a `fail`, never a `warn`; a precondition this run could not read
  is named separately as unconfirmed and downgrades the verdict to a `skip`
  rather than failing for something nobody got to check. Three of the
  preconditions are new checks — the default-branch ruleset's
  `dismiss_stale_reviews_on_push`, its own `bypass_actors`, and the Approver
  App installation's **live** granted permissions, diffed against exactly
  `contents: write`, `metadata: read` and `pull_requests: write` rather than
  assumed from `approver_app_id`. The rest (the ruleset's approving-review
  count and code-owner requirement, the merge-queue/`allow_auto_merge`/
  `allow_squash_merge` path, `approver_app_id`/`approver_model_default`) were
  already checked singly and are gathered rather than reimplemented, so the
  verdict costs no API call beyond what those checks already made. Reading a
  repository's ruleset by hand was previously the only way to answer this,
  which is how agent-ops#518 came to be filed against conditions that did not
  yet exist.

- `approver_token_installation_permissions` in `lib/approver-token.sh`: the
  Approver App installation's live `.permissions` object, from a JWT-signed
  `GET /app/installations/<id>` — an installation *access* token can act as
  the installation but cannot ask GitHub what it is itself entitled to. Read
  by the readiness verdict above; an installation's granted permissions are
  whatever the organisation owner last approved through GitHub's own consent
  screen, entirely outside `config.json`, and can be narrowed there at any
  time with nothing in this repository the wiser.

- `scripts/run-tests.sh`: run the `test/` suite the way CI runs it — the
  working tree copied into a throwaway `docker run` container from the image,
  with nothing of the host or of any running node reaching it. The suite will
  *start* anywhere and only *pass* in the environment CI uses, and both ways of
  getting that wrong fail on an untouched `main` while naming something other
  than their own cause: from the checkout, the host's `jq` (1.6 and 1.7
  disagree about enough for roughly nine files to fail); through `docker exec`
  into a running node, that container's `PULLWRIGHT_APPROVER_APP_ID`, which
  `doctor.sh` reconciles against `approver_app_id` — so a fixture deleting the
  config key builds "an Approver the config does not declare" instead of "no
  Approver", and three assertions in `test/config-schema.test.sh` invert.
  `README.md`'s "Running the tests" recommended the first of those and now
  documents both.

- D18 Stage 4's protected-path compensating controls (agent-ops#415): a
  pull request touching a protected path (`.github/`, `deploy/`, `prompts/`,
  `lib/`, `config.schema.json`, `config.json`, `agent-cycle.sh`,
  `review-cycle.sh`, `CODEOWNERS`) now routes to the Approver's critical
  tier regardless of its complexity grade, including `complexity:low` (which
  otherwise short-circuits to a deterministic, model-free approval); the
  `approver-verdict` event's own `critical_reason` field
  (`protected-path`/`refuse-streak`) distinguishes the two causes a critical
  engagement can have. At `agent-merges-all`, a protected-path pull request
  is now eligible to land automatically — the one relaxation Stage 4 makes —
  but only once the approving engagement ran at that critical tier and a
  new `landing_cool_off_hours` config key (default 24, per-repo override,
  `0` disables) has elapsed since the standing review's own timestamp; a
  fresh push restarts the wait, since the standing review's own `commit_id`
  no longer matches the pull request's current head and nothing here
  dismisses a stale review on push. Both controls are
  re-read fresh at every arming attempt, including a landing-retry sweep
  re-arm outside the round that first approved the pull request. Below
  `agent-merges-all` a protected path stays ineligible exactly as before.

- `lib/verdict-fate.sh` and `scripts/verdict-fate-report.sh` (D18,
  agent-ops#573): a durable, per-pull-request record of the Approver's
  verdict against that pull request's eventual GitHub fate — landed by the
  Script, landed by a human, closed unmerged, still open, or a human
  `CHANGES_REQUESTED` standing after an agent approval, its own fate, never
  collapsed into "closed unmerged" even once the pull request is later fixed
  and lands anyway, including across a later re-approval (agent-ops#661).
  `agent-cycle.sh`'s `run_approver_stage` now logs `repo`,
  `model` and `posted` (whether the review it describes actually reached
  GitHub) on every `approver-verdict` event, written live as the verdict
  happens; `lib/verdict-fate.sh` joins that record against each pull
  request's live state and reports agreement, divergence and sample size,
  declining to state a rate below a stated minimum sample and reporting the
  rate `unavailable`, never `met`, over a partial read.
  `scripts/autonomy-stage-report.sh`'s Stage 1 `divergence` criterion
  (previously always `unavailable`, agent-ops#571) now consumes this join
  rather than a placeholder.

- `docs/reviews/2026-08-14-autonomy-investigation.md` §6.1, a dated
  verification record for the Stage 1 exit check (agent-ops#518): what the
  App-approval mechanism has actually demonstrated (the ruleset amendment
  applied; six pull requests merged on the App's review alone; token
  authority to call `enqueuePullRequest` established only negatively) and
  what it has not (no enqueue under the App token has ever succeeded, and no
  merge has ever been performed by the App — every merge to date is a human
  account). Corrects a premise conflated earlier in the issue's own thread:
  "merged with only the App's approval" and "merged by the App" are
  different facts.

- `scripts/autonomy-stage-report.sh` (D18, agent-ops#571): a read-only
  operator report answering "has this repository met its current D18
  rollout-stage exit criteria?" — its `merge_autonomy` level, the stage
  (agent-ops#402) that level corresponds to, that stage's exit criteria, the
  measured value of each, and a closing `met`/`not-met (criterion: …)`/
  `insufficient-evidence` verdict. One criterion, classifier escapes, has no
  detector yet (agent-ops#572) and is always reported `unavailable`, never a
  guessed `0`, so a promotion decision is never made to look ready on
  missing data.

- `coordinator_prompt_max_bytes` config key (agent-ops#641), and
  `lib/coordinator-input.sh` behind it: a bound on the assembled Co-Ordinator
  prompt, so it can no longer grow past its model's context window unnoticed.
  The Script measures the rendered base prompt, subtracts it and the rest of
  the runtime-input document, and trims the two bands that carry a whole
  document each — an issue's entire thread, a tech-debt item's entire file —
  into what is left, along an eight-rung ladder walked only as far as the
  allowance requires. Prose is shed and candidacy is not: every entry keeps
  its `ref`, `url`, `title`, `priority` and `updated_at`, so a trimmed item is
  ranked and selected exactly as an untrimmed one, and every cut ends in
  `…[Script: elided N of M bytes … read it whole at <url>]` — which
  `prompts/coordinator.md` now obliges the Co-Ordinator to follow before it
  may *select* that entry, so the fetch is paid once for the item picked
  rather than for every item considered. Dropping whole entries is the last
  rung only, keeps the highest-`Priority` and freshest first, and is counted
  on the repo entry and in the union log. Trimming logs
  `coordinator-input-fitted`; a prompt that still does not fit logs a
  `warning` before the API refuses it. `0` disables the bound, which is how
  every release before this key behaved.

- `escalation_autonomy` config key (D18, agent-ops#627): `always-escalate`
  (the default, today's behaviour byte-for-byte) or `adjudicate-first`, which
  runs one bounded Enabler adjudication pass — a fresh, narrower engagement
  over one item alone, at `enabler_model` — before the Script files an
  escalation issue for a refinement disagreement (requirement 36b's thrash
  guard: a `needs-refinement` block that was already refined once and has
  since been re-flagged). The pass either confirms the existing refinement
  (recorded exactly as an ordinary `unblocked` refinement, no issue ever
  filed) or escalates exactly as `always-escalate` already does, logged
  either way as an `enabler-adjudication` event carrying its verdict and
  evidence. Bounded, not a loop: one pass per item, per human touch — an item
  that has already had one escalates without a second, the one exemption
  being a human having acted on an escalation about it since. `scripts/doctor.sh` warns when `adjudicate-first` is configured
  with no `enabler_model` to run the pass with. Poetic's own `config.json`
  sets `adjudicate-first`.

- `scripts/doctor.sh` warns when a key documented as installed —
  `x-docs.value` differing from its own schema `default` — resolves, from the
  live `config.json`, to something else (agent-ops#567): `refiner_model`
  documented as `claude-haiku-4-5-20251001` while the key had never once been
  set in `config.json` (silently running the Refiner off) went undetected for
  eight days, and nothing before this compared what the configuration tables
  claimed against what the config actually had. A key whose `x-docs.value`
  equals its own `default` — describing the product's shipped behaviour, not
  an installation's choice — is never checked, and neither is one with no
  `x-docs.value` at all or one keyed `readme`/`spec`.

- Two dashboard pie charts, **Model used — Implementer** and **Model used —
  Reviewer** (issue #529): which model each stage was *asked* to run, not
  spend attribution — a single Implementer stage on Sonnet still emits Haiku
  `modelUsage` rows for the subagents its own invocation spawns, so a ratio
  built from `cost_rows` would have reported Haiku for most Implementer runs
  (the #536 failure this issue was asked not to repeat). Backed by a new
  `counts.stage_models` Publisher aggregate, read from `stage-end` events'
  own `model` field; every stage-end counts once, including a failed run or a
  retry, and one with no readable model lands under "unknown" rather than
  being dropped. Appended to the existing cost section, sharing its
  time-frame selector, with a muted caption naming the aggregate's own
  retained-log window — which can be shorter than the cost charts' — since
  `log.jsonl` is rotated independently of `COST_SCAN_DAYS`.

- `counts.cost_rows[]` entries now carry `repo`, `item`, `source`, `outcome`
  and `attributed` (issue #593, D21) — previously the total spend was visible
  but the item dimension left this question unanswerable: what was spent on
  work that never landed. Joined by `cycle` against the same fleet-wide event
  union `cycles[]` renders from, not against `cycles[]` itself: the union is
  bounded by `log_retained_bytes`, independent of `cycles[]`'s own
  `MAX_CYCLES` cap, so the join reaches back over the whole `COST_SCAN_DAYS`
  span the cost roll-ups already cover. `attributed:true`, with the other
  four fields populated, only for a coordinator/implementer/reviewer row
  whose own cycle has events in that union; every other row —
  enabler/refiner/limit-probe (which share their triggering cycle's id but
  spent on a different item than the one that cycle selected),
  project-reviewer (whose review id never reaches `log.jsonl`), or a
  coordinator/implementer/reviewer row whose cycle has rotated out of the
  union — carries all four as `null` and `attributed:false`, never dropping
  the row itself.

- The dashboard's autonomous-landing digest reports the merge budget's own
  state per repository (issue #574, D18 §5.4): the effective cap, what the
  governor's rolling-24-hour count last read against it, the repository's
  status (`ok`/`held`/`frozen`), and — held or frozen — the oldest pull
  request the cap is making wait, with a `frozen` row also naming why. The
  numbers come from the governor itself rather than a counter the dashboard
  keeps of its own: `landing-armed` now carries the `cap`/`count`
  `merge_budget_decide` read at the moment it granted that arm, and
  `merge-budget-frozen` carries the freeze's `reason` and the same
  `waiting_backlog` its paired `merge-budget-hold` logs, so the latest of
  those three events for a repository is its state as of that last decision
  — not a live read, and of unbounded age — with no live read of the freeze
  flag or the waiting backlog on a dashboard tick. A held row ages back to
  `ok`, and an `ok` row's consumption back to unmeasured, once the event
  behind it falls outside the digest window — both are rolling-24h facts, so
  neither is carried forward under a status that gives no sign of its age; a
  frozen row never ages back, since a freeze stands until a human clears it.
  A repository's recorded cap does outlive that window, standing until its
  next gate-5 decision refreshes it rather than being re-read from
  `config.json` each tick. Every held or frozen row carries the source
  event's own timestamp (`as_of`) so the page can render its age
  (`held · as of 2d ago`). An unlimited (`0`) repository,
  which the governor never counts at all, reports the plain count of
  landings this digest's own window saw, rather than always reading
  `0/∞`. A held or frozen repository renders as its own badged row, never
  folded into the quiet `consumed/cap` line an unheld repository gets and
  never counted as an eligibility refusal: "the fleet is idle because the
  governor closed" and "the fleet is idle because there is no work" no
  longer read alike.

- An hourly, unattended `scripts/doctor.sh --unattended` pass (agent-ops#543),
  on its own `deploy/docker/crontab.tmpl` line: the same Configuration and
  GitHub checks an operator runs by hand, run unprompted, so a configuration
  gap that only shows up against a live repository — a repository's
  `Priority` field missing one of `Urgent`/`High`/`Medium`/`Low`, above all —
  is no longer invisible on a node nobody happens to run the command on.
  Skips only the two checks that spend (the Claude-credentials check and the
  stream-flushing probe), each with its own reason, distinct from
  `--offline`'s; the GitHub section runs in full, since every call there is a
  GET. Its verdict — the summary, and every `warn`/`fail` line with a
  timestamp — reaches the dashboard as a new **Doctor** section and a
  page-top banner (red for a failure, amber for a warning), read from
  `state_dir/.doctor-status.json` rather than recomputed on the dashboard's
  own 5-minute heartbeat.

- The autonomous-landing digest (D18 WI-8, agent-ops#411): a new
  **Autonomous landings** dashboard section reporting, over a rolling 24 h
  window, every pull request the Script landed without a human — when, which
  repository and pull request, its title, the work source, the complexity it
  was armed at, the `enqueued`/`auto-merge` method used, the node that armed
  it, and the Approver tier and verdict that authorised it. This is the
  asynchronous audit D18 accepts unattended merging in exchange for (risk 6 of
  `docs/reviews/2026-08-14-autonomy-investigation.md`), and is permanent
  rather than rollout scaffolding: at `agent-merges-all` it is the only
  routine account of what merged.

  Built from the fleet-wide event union, so a landing armed on any node shows
  on every node's page. The verdict join takes the newest `approver-verdict`
  for that pull request *at or before* the arm, never a later re-review — an
  Approver may review the same pull request across several cycles, and only
  the verdict the arming stage could have seen explains the landing. A landing
  whose verdict cannot be located still renders, marked `unknown`, since an
  unexplained landing is the most important row the panel can carry.

  Alongside the landings it reports what would otherwise mislead by omission:
  refusals over the same window grouped by reason class (two landings beside
  forty refusals is a classifier holding the line; two beside none may be a
  gate that is not running), and each repository's `merge_budget_per_day` cap
  against what the window consumed, with an unlimited repository reading as
  `∞` rather than a cap of zero. A payload the Publisher could not assemble
  renders as "could not be assembled this tick", explicitly distinguished from
  a quiet night — an empty list is a reportable nothing, `null` is an outage,
  and the two must not look alike.

- The landing-retry sweep (requirement 8u, TD-PPagop-26081701): once per
  cycle, fleet-wide, for every repository at `merge_autonomy:
  agent-merges-routine` or `agent-merges-all`, re-enters the arming step's
  own six gates for every open pull request whose Approver review is
  genuinely standing `APPROVED` on GitHub right now — closing the gap the
  original arming step (D18 WI-7) left, where a refusal whose reason could
  change on its own (the merge budget resetting, the kill switch or a
  per-repo freeze lifting, a `merge_autonomy`/`merge_autonomy_routine_sources`
  config change, a transient unreadable, a required check going green) was
  never revisited and a human had to notice and merge by hand. Reuses
  `landing_eligible` rather than a second copy of it, so a protected-path
  hit, a `complexity:high` pull request, or a source outside the routine
  list is never armed here either. `landing-armed`/`landing-refused` events
  from the sweep carry `retry: true`. Neither the sweep nor this round's own
  arming step ever arms more of a repository's stranded pull requests,
  between them, than its remaining merge budget — `merge_budget_per_day`
  less what it has already landed in the rolling window: `merge_budget_decide`
  (`lib/merge-budget.sh`) discounts a running, cycle-scoped tally (shared by
  both call sites) from the live merged-PR count, since GitHub's own record
  only shows a pull request as merged once the merge has actually landed,
  never the moment either arms it — without the bound, every stranded
  candidate offered in the same cycle read the same not-yet-merged count and
  all of them armed regardless of the cap. Neither call site ever re-arms a
  pull request GitHub's merge queue has already removed once and nobody has
  re-queued since — a maintainer's own deliberate removal is never reversed,
  and a checks-failure removal is left for `scripts/gather-dequeued.sh`'s own
  `dequeued` source to diagnose and fix before a human re-queues, rather than
  blindly re-running the same failing merge group every cycle.

- The classifier-escape audit (requirement 8e, D18 Stage 2 exit criterion
  "zero classifier escapes"; agent-ops#572): `scripts/detect-classifier-
  escapes.sh`, run once per cycle for every configured repository, is an
  independent, read-only, post-hoc check that every pull request which
  actually landed under the Approver identity really was eligible — never
  calling `landing_eligible`, and never sourcing `lib/landing.sh` at all
  (the protected-path list and the routine-sources resolution are each
  reimplemented from scratch, so a bug shared between the classifier and
  its own auditor cannot pass unnoticed by both agreeing). For every
  merged, `pr_label`-carrying pull request whose `merged_by` is the
  Approver App's own login, it recomputes the protected-path hit from the
  merge commit's own file list and the complexity from the pull request's
  labelled/unlabelled timeline as it stood at `merged_at`, and reads back
  the work source and the effective `merge_autonomy` level the landing was
  armed under — `landing_eligible`'s own first gate — from the fleet log's
  own `landing-armed` event, the two inputs nothing can reconstruct after
  the fact — the arming step now records that effective level (kill switch
  and per-repo merge-budget freeze already folded in) on the event, since
  the moment it resolves it is the only moment anything knows it. The
  protected-path hit is itself level-dependent, matching `landing_eligible`'s
  own gate: below `agent-merges-all` it disagrees unconditionally, but at
  `agent-merges-all` the classifier defers it to the WI-12 compensating
  controls (`landing_protected_path_controls_ok`) — facts this post-hoc
  detector cannot recompute — so that case reports `unverifiable`, never
  `escape`, unless some other, genuinely reconstructable input already
  disagrees on its own. Any input
  that cannot be reconstructed reports `unverifiable`,
  never `clean`; a disagreement is a first-class `classifier-escape` event,
  loud rather than a row nobody reads. Each merged pull request is looked at
  most once, ever; one merged by anyone other than the Approver identity is
  not an audit finding, but that fact too is recorded once (its own
  `landing-audit-skip` event, kept out of the scoreboard below), so the read
  that discovers it is never repeated on a later cycle. Surfaces as a new
  `audit`/`audit_reason` column on the autonomous-landings digest's own
  rows, and as an all-time `counts.escape_audits` scoreboard
  (checked/clean/escapes/unverifiable) on the dashboard, never windowed like
  the digest above it — an escape is a permanent fact about one merged pull
  request. A landing armed before `landing-armed` carried a level reports
  `unverifiable` for that input rather than being judged against today's
  configuration — an operator dialling `merge_autonomy` back must never
  retroactively manufacture a classifier escape out of a landing that was
  correct when it happened. The sweep runs under a 120-second budget per repository per cycle
  and reads its candidates oldest-first, so on a repository whose candidate
  list costs more than that to walk in one pass it converges over as many
  cycles as it takes rather than stalling at a permanent frontier: the
  scoreboard is a floor on what has been checked at any given moment, not a
  final coverage statement (requirement 8e records the size of that backlog
  as of the day this landed).

- The deterministic eligibility classifier and the arming/enqueue step (D18
  WI-7, requirement 8d; agent-ops#410): at `merge_autonomy: agent-merges-routine`
  or `agent-merges-all`, once the Approver's own engagement reaches an
  explicit, non-adjudicating approval, `run_landing_stage` re-reads every
  gate fresh — the effective level, `complexity:low`/`medium`, the work
  order's `source` against the new `merge_autonomy_routine_sources` config
  key, no protected path touched (`.github/`, `deploy/`, `prompts/`, `lib/`,
  `config.schema.json`, `CODEOWNERS`), the required checks and security-alert
  delta, no standing human `CHANGES_REQUESTED`, the merge budget, and the
  merge queue — and lands the pull request itself: `enqueuePullRequest`
  where the base branch has an active merge queue, `gh pr merge --auto
  --squash` where it does not, both under the Approver App's own minted
  token. Any unreadable gate refuses arming (`landing-refused`), never a
  pass. Ships dormant — `merge_autonomy` is `human` fleet-wide by default,
  so nothing arms until an installation explicitly raises a repository's
  level (D16, §6). D17's rule that the product never enqueues a pull request
  is repealed at those two levels, and requirement 38f, requirement 3g's
  `dequeued` paragraph and three operating prompts now say so; nothing in
  this pipeline re-queues a *dequeued* pull request at any level, since the
  arming step arms only on the round the Approver approves
  (tech-debt/TD-PPagop-26081701.md).
- Priority triage (D18 WI-11, requirement 39g; agent-ops#414): the Refiner now
  bands every open issue whose `Priority` field is unset, so the owner never
  has to set it by hand. `gather-issues.sh` emits a new `priority_set`
  boolean alongside `priority`, an unbanded-but-already-refined issue is
  offered to the Refiner solely for its band (`triage_only: true`) — and a
  `needs-refinement` decline of such an item is refused rather than recorded,
  so banding an already-refined issue can never block it — and
  `lib/issue-priority.sh` enforces a one-way ratchet: a band is written only
  when the issue currently has none, or the Refiner's verdict strictly
  outranks the current one, re-read live immediately before writing.
  `scripts/doctor.sh` warns when a configured repository's `Priority` field
  cannot be resolved.
- `merge_budget_per_day` (D18 §5.4, requirement 2.3c): a rolling-24-hour cap,
  per repository, on pull requests this pipeline may land, with a `repos[]`
  override on the same precedence `merge_autonomy` uses. Default `8`, `0`
  unlimited. Landing more than the cap in a window — a counting anomaly a
  correct governor should never observe — freezes the repository's
  `merge_autonomy_effective_level` at `agent-approves` and escalates to that
  repository. `max_open_agent_prs`'s back-pressure exclusion is now level-
  aware: at `agent-merges-routine` and above, a ready pull request counts
  toward the cap even when it is not `CHANGES_REQUESTED`, since there is no
  human queue for it to be parked in at that level. Enforced at the arming
  step (D18 WI-7, above).

- The Approver's own backstop and watchdog overrides (TD-PPagop-26081601,
  agent-ops#473): `timeout_approver` and `inactivity_approver` fleet-wide, and
  `approver` under a `repos[]` entry's `stage_timeouts` / `stage_inactivity`,
  completing requirement 4f's precedence for the one implementation actor that
  had none. The Approver stage (D18 WI-5) shipped with its own
  `stage_budget_apply` call but no configuration to reach it, so an
  installation could not pin either cap for that stage while it could for
  every other. Omitting them stays the normal case — both caps still derive
  themselves. The derived `lock_stale_after` accordingly sums six actors
  rather than five, widening the default cycle lock by the Approver's 30 min
  prior, and `scripts/doctor.sh`'s pinned-cap warning now covers both new
  keys at every level of the precedence (TD-PPagop-26081802).
- A cycle no longer starts work the host has no room to finish (requirement
  2.0c, agent-ops#756): before the clone, and free like the GitHub-budget and
  credential checks ahead of it, the Script now reads `workspace_root`'s free
  space and stands down (`cause: "disk-full"` or `"disk-low"`) below a new
  config key, `min_free_workspace_bytes` (default 2 GiB; `0` turns it off).
  `scripts/doctor.sh` had warned about the same shortfall since before this
  key existed, but only a human running it by hand ever saw the warning —
  the cycle itself cloned into whatever room was actually left, which is
  what let a disk-full ockham node disable `git gc` (#604) and leave 4.2 GB
  of orphaned clones behind (#605). `lib/disk-space.sh` is the one place
  free space is now read and judged, shared by the gate and by `doctor.sh`'s
  own warning so the two cannot disagree about what "low" means.

### Fixed

- The Autonomous landings panel's refusal-reason grouping no longer garbles
  a whole family of `landing-refused` reasons into one-off groups keyed on a
  fragment of a pull request URL (TD-PPagop-26082502). The panel groups by
  the `reason` text before its first `:` (`byReason`, `dashboard/index.html`);
  several of `_landing_stage_attempt`'s (`lib/landing.sh`) sentence-form
  refusals embedded `$pr_url` — itself a `https://…` string carrying its own
  scheme colon — before any stable word boundary, so two pull requests
  hitting the identical underlying failure (e.g. the Approver's review list
  becoming unreadable) never accumulated into one visible count. Every
  refusal reason that carries a `:` at all now carries it behind a class
  word, in the same `class:detail` shape the classifier-driven refusals
  (`ineligible:`, `kill-switch:`, `open-question:`) already used — including
  the App-approval gate's own refusal, whose `(state: …)` parenthetical
  grouped it under a sentence cut off mid-clause rather than under the gate
  that refused.
- The dashboard's "GitHub data unavailable" banner (`scripts/publish-dashboard.sh`)
  now classifies and collapses `gh_fail_msgs` by cause instead of
  concatenating every raw failure (agent-ops#695). During the 2026-08-22
  token expiry the banner carried fifteen semicolon-joined "Bad credentials"
  bodies — one per source per repo — with the one fact that mattered, the
  token being dead, stated nowhere in the text. Each failure is now
  classified as auth (401/"Bad credentials"), rate-limit (403 or a
  rate-limit phrase), network (a connection/timeout string) or other, and
  same-cause failures collapse into one line with a call/repo count; a tick
  that fails more than one way gets one line per cause. The full raw list
  still reaches `dashboard.log`, which the collapsed banner now names.
- `techdebt_file_debt` (`lib/tech-debt-file.sh`) now labels the pull request
  it opens to file a tech-debt record with the fleet's configured
  `pr_label`, rather than opening it unlabelled (TD-PPagop-26082426). Every
  gatherer that finds this pipeline's own pull requests filters on that
  label — `gather-review-feedback.sh`, `gather-abandoned-drafts.sh`,
  `gather-merge-conflicts.sh`, `gather-dequeued.sh`,
  `gather-human-visibility-hygiene.sh` — so an unlabelled filing pull
  request was invisible to all of them at once: nothing would ever review
  it, notice it going stale, or notice it conflicting, while the call
  itself still reported success. The Approver and the Enabler, its only two
  callers, each resolve `pr_label` from `DEFAULTED_CONFIG` at their own call
  site (neither having it otherwise in hand) and pass it through.
- The dashboard's "Live claims" table no longer shows a discarded Enabler/
  Refiner tombstone as held for tens of thousands of days (agent-ops#839).
  `lib/claim.sh`'s `do_expire()` deliberately backdates such a claim's `ts`
  to the fixed sentinel `1970-01-01T00:00:01Z` so `gc`'s next TTL sweep
  retires it (issue #237, requirement 35c) — correct and intentional. The
  claims panel had no notion of this sentinel and rendered it straight
  through `fmtAgo`, producing a fabricated ~56.65-year age. `claimsPanel()`
  (`dashboard/index.html`) now recognises the sentinel and renders "expired
  — pending cleanup" instead; every other caller of `fmtAgo` is unchanged.
- The dashboard no longer badges a cycle `↻ raced`/"recovered race ×N" when
  at most one node is currently active (agent-ops#829). Per-item claims only
  arbitrate contention between concurrently *active* nodes (`lib/role.sh`) —
  a standby never attempts one — so with `fleet.nodes` present and at most
  one node carrying `role: "active"`, no peer could have held the claim a
  cycle's `raced`/`race_losses` fields describe, and the badge previously
  named contention that could not have happened. The underlying log fields
  are unchanged; only their rendering is gated, in `dashboard/index.html`'s
  new `racedMarkersPossible()`. Fleet-less data (no `fleet` key at all) is
  not evidence of a single node and renders exactly as before.
- `github_auth_probe` (`lib/github-limit.sh`, requirement 2.0b) no longer
  classifies a missing `GH_TOKEN`/`GITHUB_TOKEN` as `unreachable`
  (TD-PPagop-26082306). Before, only an HTTP 401 GitHub itself answered was
  read as `unauthorized`; an unset or empty token with no `gh auth login`
  session either makes `gh` refuse locally, in a shape that matched neither
  that pattern nor anything else, so requirement 2.0b's stand-down fell
  through and the cycle proceeded to a full Co-Ordinator engagement every
  time — the same indefinite per-cycle burn agent-ops#691 was filed about,
  in a different failure mode of the same fault. The probe now recognises
  `gh`'s own no-credentials refusal too and reports it as `unauthorized`,
  with `detail` leading "no token present" rather than an HTTP status; the
  stand-down reason and the escalation issue's title and body
  (`lib/standdown.sh`) now say so plainly instead of claiming a rejected
  token ("HTTP 401", "invalid or expired") that never happened.
- `refinement_traceability_fault` (requirement 17f, `lib/candidate-select.sh`)
  no longer faults a compliant work order on ordinary paste drift, and no
  longer assumes a refinement is present when it cannot check
  (TD-PPagop-26082307). The comparison against a candidate's `context`/
  `acceptance` now normalizes whitespace (collapses runs, trims both ends)
  on both sides before testing containment, so a model's reflowed line or
  collapsed spacing no longer defeats a verbatim match — the check still
  faults a passage that is genuinely missing or different. A failed `gh api`
  read of the actual refinement comment is now itself a fault
  (`untraceable`, retried next cycle) rather than a silent pass, reported
  via `guard_warn` instead of swallowed — previously a degraded token, a
  narrowed scope or a sustained rate limit could disarm the whole gate
  indefinitely while it kept reading as a passing check. `TRACEABILITY_DEBUG=1`
  logs the normalized comparison to stderr for diagnosing a real
  drift-tolerance edge case.
- The Enabler's escalation comment on a `needs-refinement` issue no longer
  asserts an escalation exists before the Script has decided whether one
  actually does (agent-ops#815). The Enabler's own turn ends before
  `adjudicate-first`'s adjudication pass runs, before `create_escalation_issue`
  is called, and before that call's own result is known, so its comment can no
  longer claim the escalation issue's number — three items escalated in the
  same cycle (#604, #613, #640) each carried that claim, uncorrected, when the
  filing never happened or was superseded. `escalation_thread_reconcile`
  (`lib/enabler.sh`) now posts the Script's own follow-up once the outcome is
  known: a completing `Blocked-by: #<n>` comment naming the issue actually
  filed, or, when `adjudicate-first` settled the disagreement as `adequate`
  instead or the filing itself failed, a correcting comment saying plainly
  that no escalation was raised.
- `state-sync.sh fetch` no longer reports a real failure — dead credentials,
  a network outage, a corrupt mirror — as the benign "the state repository
  has no node branches yet" bootstrap case (agent-ops#693). During the
  2026-08-22 token expiry the fetch failed with HTTP 401, and the discarded
  stderr and the swallowed non-zero exit meant nothing recorded why: the
  step logged the bootstrap line and exited 0 regardless. `do_fetch` now
  probes with `git ls-remote --heads origin 'refs/heads/nodes/*'` before
  fetching — a non-zero exit is a real failure, logged from git's own
  stderr and returned non-zero so the scheduler surfaces it; a zero exit
  with empty output is the genuine bootstrap case, still a silent no-op.
  While a real failure is in force, `fleet_mark_peers` (`lib/fleet.sh`)
  marks the peers directory stale (`.last-fetch.json`,
  `{"ok": false, "ts": …}`) rather than leaving it looking as fresh as a
  directory a successful fetch just materialised, so a union reader can
  tell frozen peer state from current state.
- A context-tight Co-Ordinator cycle no longer mass-flags its whole backlog
  `needs-refinement` (agent-ops#683). On 2026-08-21 the fit ladder
  (requirement 4i) reached its bottom rung, every candidate's body was cut
  to a title-level fragment, and the Co-Ordinator — correctly following its
  own prompt's "if you cannot tell what done would mean, report
  needs_refinement" — reported exactly that for its entire visible backlog;
  requirement 3x's completeness bar then obliged the Script to record every
  one as a block, so nine items, most of them refined within the preceding
  day, were flagged in 68 seconds. Neither rule was wrong on its own, and
  the outcome recurred on every context-tight cycle that selected nothing.
  `record_needs_refinement_block` now refuses a Co-Ordinator report naming
  an item this cycle's fit actually trimmed — Script-side and deterministic,
  logged as a `warning` naming the item and the rung, writing no label,
  block or assignment, and scoped to the Co-Ordinator alone, since the
  Refiner and Implementer read the repository live. `unaccounted_items`
  carries the matching exemption, so declining to write the block does not
  itself read as an unaccounted verdict and simply relocate the mass-flag
  into a retry loop over the same trimmed input; the count of candidates
  that went unassessed is logged as `coordinator-input-fit-unassessable`
  instead. An entry counts as trimmed on any of the three marks `fit_entry`
  leaves — a clipped body, a clipped comment body, or a cut comment list —
  so the ordinary shape here, a short issue whose acceptance criteria live
  in a Refiner's comment, is covered by a middle rung as well as by the
  bottom one. The ladder itself is unchanged: `0:0:1000` stays a trim rather
  than becoming a drop, reasoned in requirement 4i, because the refusal
  removes the harm that made dropping tempting while a trimmed entry still
  buys the Co-Ordinator something to rank and, if worth it, live-read.
- A human's plain comment now vetoes an autonomous landing however late it
  arrives, not only if it arrives before the pull request goes Ready
  (agent-ops#672, part of #402). The landing gate's human-veto check
  (`_landing_stage_attempt`'s gate 4, `agent-cycle.sh`) read only formal
  reviews — and a human cannot leave a formal `REQUEST_CHANGES` review on this
  system's own pull requests at all, since GitHub refuses that review type from
  a pull request's own author and every pipeline write and human comment here
  land under the same account, so an ordinary comment is their only instrument.
  `lib/reconciliation-gate.sh` (agent-ops#533) already closed that gap at the
  Reviewer's own ready-flip, but it runs once, at hand-off: a comment posted in
  the window between a pull request going Ready and a later cycle's arming step
  was seen by neither check, and the pull request could land with it never
  consulted. Gate 4 now calls `reconciliation_gate` itself, a second time and
  unbounded — this stage never flips the pull request out of draft, so the raw
  "last left draft, and stayed left" anchor is the one this read needs. A
  `dirty` verdict refuses to arm, naming the unreconciled comments as
  permalinks; anything else that is not `clean` — an unreadable timeline or
  comment list, or no answer at all — refuses too (agent-ops#746, ruled in
  agent-ops#753), naming the pull request and what could not be confirmed, so
  the veto holds whether or not the read succeeds rather than only when it
  does. The refusal is unconditional, and draws no distinction between an
  `unknown` a read genuinely returned and the empty word a call that never
  executed leaves behind: neither passes a safety gate. Only the exact word
  `clean` reaches the arm, and rides in the landing audit record (requirement
  8x) as its own `comment-reconciliation` gate entry. The refusal is not
  terminal — the landing-retry sweep re-offers the pull request next cycle, so
  a transient read failure costs a delayed landing rather than a lost one.
- An `adjudicate-first` escalation now carries the adjudicator's own finding,
  not just the Enabler's pre-adjudication verdict (agent-ops#681). Where
  `run_enabler_adjudication` returned `inadequate` — or any other reason the
  pass could not settle the disagreement — the Script filed the escalation
  issue with the body the Enabler wrote *before* adjudication ran; the
  adjudication's own `evidence` reached the `enabler-adjudication` log event
  and nowhere else, leaving the human to start the escalation with no idea
  why an adjudicator's answer was missing, even though the `adequate` branch
  already threaded the same evidence into its own `unblocked` event's reason.
  The escalate branch in `agent-cycle.sh` now appends the evidence under an
  `## Adjudication attempted` heading to the issue body before filing,
  whenever the pass actually ran.
- The Refiner's Priority ratchet now writes at all: every `setIssueFieldValue`
  mutation it has ever sent was rejected before reaching the resolver, so no
  issue in any repository has been banded by the pipeline (agent-ops#737).
  `issue_priority_apply` (`lib/issue-priority.sh`) declared the mutation's
  `$optionId` variable as `String!` while GitHub types the
  `singleSelectOptionId` argument as `ID`, and GraphQL rejects that pairing
  outright — `Type mismatch on variable $optionId and argument
  singleSelectOptionId (String! / ID)`. The call discards stderr, so the
  caller saw only a bare `mutation-failed`: `ockham-container`'s retained
  `log.jsonl` carries 14 `refiner: could not set Priority …` warnings between
  2026-08-20 and 2026-08-23 and **not one** `issue-prioritised` event. The
  variable is now `ID!`, matching the two id variables either side of it. The
  suite could not have caught this — the stubbed `gh` in
  `test/refiner-priority-triage.test.sh` matches on `*setIssueFieldValue*` and
  never parses the query, so a declaration GitHub rejects looks identical to a
  correct one — so section (B2) of that test now asserts the declared types
  against the source directly. Requirement 39g is unchanged: the spec always
  described this behaviour, and the code now does it.
  `TD-PPagop-26082322` records the swallowed stderr that hid it.

- The Reviewer stage no longer burns its budget retrying a test run it cannot
  finish (agent-ops#734). Its own Bash tool kills any single command still
  running at 10 minutes and returns nothing for it — not even the output of
  whatever had already passed — and re-running `test/*.test.sh` (140 files) as
  one invocation risked exactly that wall. On PR #729 a Reviewer lost 30 of
  its 90-minute budget to three identical 10-minute kills against that one
  unbatched run, then spent the rest re-batching by hand and still did not
  finish before its final message came due, discarding a review whose
  findings had already been complete after the first 13 minutes.
  `scripts/run-tests.sh` gains `--list`: no Docker, no container, just the
  selected basenames printed one per line, so a caller can list the suite
  once and split it into groups sized to clear the ceiling before running any
  of them. `prompts/reviewer.md` now documents the ceiling explicitly and
  directs the Reviewer to batch this repo's own suite through `--list` rather
  than one unbatched call or a hand-rolled loop, and to post its diff findings
  before starting the test run so a batch that exhausts the remaining budget
  costs only the test evidence, not the review itself (requirement 29a,
  `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s Gotchas table).
- The protected-path classifier no longer fails open on a malformed
  `merge_autonomy_protected_paths` (TD-PPagop-26082320). `_landing_is_protected`
  (`lib/landing.sh`) and its deliberate twin `_escape_audit_is_protected`
  (`scripts/detect-classifier-escapes.sh`) compare each changed path against
  the configured list with a jq program that raises — `jq -e`'s own exit 5 —
  rather than returning false, when an entry is not a string; the caller
  could not tell that apart from "no match" (exit 1), so a list like
  `[123, "lib/*"]` would have read as "nothing protected was touched" for
  every path in the diff. `landing_protected_paths_hit` now returns its own
  "could not be established" exit 2 for the raising case, exactly as it
  already does for an unreadable or truncated changed-file listing, and
  `landing_eligible` reads that as `unknown`, never `eligible`. Not reachable
  through a schema-validated `config.json` — `config.schema.json` already
  constrains every `merge_autonomy_protected_paths` entry to a non-empty
  string — but `scripts/detect-classifier-escapes.sh` reads its own `--config`
  file with no such gate, so this closes a latent contract defect rather than
  a live hole.
- D18 arming now works at all: the changed-file read behind the protected-path
  gate had been failing on every single call since Stage 2 was entered, so the
  pipeline has never autonomously landed a pull request (agent-ops#718).
  `landing_protected_paths_hit` (`lib/landing.sh`) asked for
  `repos/…/pulls/N/files` with `-F per_page=100` and no `--method GET`, and
  `gh api` sends a request carrying `-f`/`-F` fields as a POST unless told
  otherwise — a 404 on that path. The gate did exactly what it should with an
  unreadable list and refused to arm, so nothing looked broken: 72 of the 115
  `landing-refused` events across the fleet between 2026-08-17 and 2026-08-23
  read `unknown:could not establish …'s changed-file list`, and no
  `landing-armed` event exists in any node's log. The read is now an explicit
  GET; the stubbed `gh` in `test/landing.test.sh` models `gh api`'s own method
  selection, so a field-carrying request that forgets `--method GET` now 404s
  in the test suite exactly as it did in production; and
  `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s Gotchas table carries the trap — a
  fail-closed gate that fails every time is indistinguishable from a working
  one.
- The D18 stage report's "zero classifier escapes" criterion now measures
  something. It was hard-coded `unavailable` with the reason "no
  classifier-escape detector yet (agent-ops#572)" — true when the report
  landed, and stale from the moment the detector did (requirement 8e,
  `scripts/detect-classifier-escapes.sh`), which `agent-cycle.sh` has been
  running every cycle since. Because a criterion is never reported `met` from
  missing data, that left Stage 2's exit unsignable-off from the report even
  once landings started. `crit_classifier_escapes`
  (`scripts/autonomy-stage-report.sh`) now reads the audit's own events: a
  `classifier-escape` fails the bar and names the pull request; a
  `landing-audit` with `outcome: "clean"` is evidence toward the zero; an
  `unverifiable` audit is named separately rather than counted; and a
  repository whose audit has recomputed nothing yet still reports
  `unavailable`, because zero escapes out of zero audits is an absence of
  evidence, not evidence of absence.

- The pipeline's own labels are now created in every configured repository it
  gathers data for, not only the one a cycle happens to select for work
  (requirement 6a, agent-ops#687). A repository the Co-Ordinator had not yet
  selected work in got no ensure at all, so its own `needs_refinement`/
  `blocked` block projection and the Refiner's `refined_label` projection
  silently failed there until some later cycle selected it — and `blocked`,
  `obsolete` and `unvoid_label`, the human-only controls no stage ever
  applies itself, were simply absent from that repository in the meantime.
  `labels_ensure_stamped` (`lib/labels.sh`) rate-limits the new
  per-gathered-repository ensure via a stamp file under `state_dir`
  (`labels_ensure_interval_hours`, default 24h, new config key — whole hours,
  a fractional value being refused at configuration time), used by
  `agent-cycle.sh`'s gather loop; the same repository's own selected-work
  listing in `agent-cycle.sh`'s step 6a, and `review-cycle.sh`'s
  per-repository ensure, both call the unstamped `labels_ensure_role`
  directly instead, immediately before the point that needs the label to
  exist. `refinement_label_add` additionally self-heals a failed projection
  once, through the new `labels_ensure_one` primitive.

- A `human-visibility-<hash>` void now retires like every other shape the
  cycle gathers as structured data, instead of sitting in the void extract
  for ever (agent-ops#646). Requirement 34n's liveness rule knew five shapes;
  this sixth one — the content digest
  `scripts/gather-human-visibility-hygiene.sh` mints over its surviving
  violations — was in none of them, is not a GitHub object 34k can close and
  is not a register row 34l can resolve, so nothing could ever mark it
  actioned. Four such entries had accumulated in a 135-entry, 156,454-byte
  extract, three of them describing pull requests merged days earlier.
  `lib/void-liveness.sh` now carries the shape in both of its maps —
  `void_liveness_actioned`'s (as `liveness-human-visibility`) and
  `void_config_actioned`'s source inverse, where `human-visibility` had been
  listed among the sources no `source-dropped` verdict can be read off
  despite minting exactly one id shape of its own.
  `gather_human_visibility_hygiene` writes the `.ok` marker the rule reads
  back, and the walk that calls it
  now also covers a repo carrying unretired residue of this shape
  but no live violation — the state in which such a void *should* retire, and
  the one that previously produced no marker at all. Costs no additional
  `gh` call: with no violations handed to it that gatherer re-verifies
  nothing and prints the `[]` the rule was missing.

  The same measurement showed the extract's remaining stall is not a defect
  but the age gate: 131 of the 135 entries were younger than
  `void_retire_after_days`, and 91 already carried `void-object-closed`, so
  requirements 34k and 34l are actioning items and the extract simply has the
  8–10 August void burst to age out. The one shape that is stuck for a
  structural reason is filed rather than fixed here —
  `tech-debt/TD-PPagop-26082309.md`, a voided `review-<date>-R-NN` ref, whose
  `review-merged` signal needs a merged pull request naming the ref and so is
  defined for exactly the population that never gets voided. All four entries
  in the extract already past the age gate are of that shape.

- `techdebt_file_debt` no longer orphans a `td-record/<id>` branch or its
  `td/<id>` reservation when a filing stops part way through
  (TD-PPagop-26082203). It reserves the id, then writes the branch and the
  record commit purely through the API, then calls `gh pr create`; if any of
  those steps failed, whatever it had already written was left behind with
  no pull request ever pointing at it — `td-record/` isn't a prefix
  `scripts/sweep-orphan-branches.sh` sweeps, and a bare `td/<id>` is one it
  deliberately leaves alone (issue #545), so neither was ever found again.
  Every failure past the reservation now best-effort deletes the record
  branch and then releases the reservation before returning.

- A `tailnet` node with no `TS_AUTHKEY` no longer thrashes `dashboard` once
  the sidecar it shares a network namespace with has stopped
  (TD-PPagop-26082303). PR #698 bounded `tailscale`'s own `restart` so it
  settles after five attempts instead of retrying forever, but left
  `dashboard` on the shared `unless-stopped` policy; since it cannot join the
  network namespace of a container that is not running, it retried
  indefinitely at Docker's capped backoff once `tailscale` had already given
  up — the loop issue #644 was fixing moved to a different container rather
  than ending. `dashboard` now carries `restart: on-failure:5` too, so it
  settles on the same schedule as the dependency it cannot run without.

- `lib/issue-priority.sh`'s cache-directory ownership record now tracks every
  directory this process has created, not only the most recent
  (TD-PPagop-26082202). `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATH` held a single
  path, so a process that made the library create a second directory in the
  same run — by repointing `ISSUE_PRIORITY_CACHE_DIR` and re-sourcing, or
  unsetting it and re-sourcing — orphaned the first one permanently:
  `issue_priority_cache_cleanup` only ever knew about the most recent record.
  `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATHS`, an array, replaces it, and cleanup
  now removes every directory this process owns while still leaving a
  caller-supplied directory untouched. Because bash cannot export an array, a
  parent process exporting `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATHS` necessarily
  exports it as a scalar, and the source-time branch that creates a fresh
  directory now resets the array rather than appending to it whenever the
  inherited `ISSUE_PRIORITY_CACHE_DIR_OWNER_PID` does not match this
  process's own `$$` — appending would have silently upgraded the inherited
  scalar into element 0 of this process's own array, reopening agent-ops#552
  against the array form: a child process could be talked into folding a
  parent-supplied path into its own ownership record and `rm -rf`-ing it on
  cleanup.

- A `tailnet` node with no `TS_AUTHKEY` no longer registers a fresh Tailscale
  node key once a minute forever (agent-ops#644). The profile's documented
  precondition was enforced by nothing, so `tailscaled` started anyway, asked
  for an interactive login it had no way to complete and exited 0 — having
  already generated and registered a new node key — and `restart:
  unless-stopped` did it again, 1,421 times over nine days on one node. The
  `tailscale` service's `entrypoint` now checks `TS_AUTHKEY` before handing
  control to the image's `containerboot`, logging one line to stderr and
  exiting 1 when it is empty, and that service alone carries `restart:
  on-failure:5` so the failure stops rather than loops. `TS_AUTHKEY` is now
  required at every start of the sidecar, not only its first: a node whose
  identity already lives in the `tailscale-state` volume must still keep the
  variable set. Merging this deploys nothing — each node needs its
  `compose.yaml` re-fetched and `docker compose up -d`.

- The own-label grace period (requirement 39f) is now measured against the
  union-log snapshot's own horizon, not wall clock (agent-ops#670). A long
  cycle used to read a peer node's `own-label-action` record, already
  present in the snapshot it took at cycle start, against `date -u` read
  back however much later that cycle's requirement-39f read-back actually
  ran — so once the cycle ran longer than `LABEL_OWN_GRACE_SECONDS` (1800s),
  the peer's own write misattributed to a human, restarting a
  `needs-refinement` block nobody asked for. Two items, agent-ops#597/#602
  and #598, cycled indefinitely on exactly this before a human intervened
  by hand each time. `lib/label-marker.sh`'s new `log_latest_ts` extract —
  the newest `.ts` across `union_log`, captured once immediately after the
  snapshot and before that cycle appends any of its own events into it — is
  now passed as the explicit `NOW` to both `label_filter_own_applications`
  and `label_own_stale_applications`.

- A work order's `acceptance`/`context` can no longer carry a *different*
  item's refinement content past a claim (requirement 17f, agent-ops#626).
  Issue #571's work order was assembled carrying issue #529's own refinement
  comment — a Co-Ordinator engagement composing several candidates' work
  orders at once produced a response that was syntactically fine and each
  candidate individually plausible, so nothing detected the cross-item swap
  until the Implementer, handed nothing but the mismatched work order, found
  it incoherent and burned the item's one refinement-per-human-touch
  allowance re-flagging a fault the item never had — stalling #571 for a full
  human round trip (Enabler escalation #625) over a defect in assembly, not
  in the item. `refinement_traceability_fault` (`agent-cycle.sh`) now checks
  every ranked candidate before its claim is attempted: a `spec`-carrying
  refinement must be present in the candidate's own `context`; a
  `comment_url`-carrying refinement must name the candidate's own issue and
  (fetched live) be present in its own `context` or `acceptance`. A candidate
  that fails either check is skipped without a claim attempt, logged as
  `claim-skipped` with `cause: "untraceable"`, and never reaches an
  Implementer. The check is scoped to a model-composed work order: the
  Script's own fallback pick (requirement 3v) builds `context` in jq from the
  band entry it names, so it cannot cross-contaminate, and it draws on the
  item's own record rather than on `refinements`, so checking it would fault
  every spec-refined mechanical pick and leave that cycle nothing to claim.

- The Co-Ordinator's `refinements` input is scoped to candidacy
  (agent-ops#643). `refinements` is a ledger that is never retired, and an
  entry for an item type with no thread to hold it carries the whole
  specification in markdown. By 2026-08-21 it had reached 237,339 bytes, 24
  `spec` payloads accounting for 219,175 of them, and the Co-Ordinator's
  prompt text plus the unsheddable half of its input came to 387,840 bytes
  against a 350,000-byte maximum *before any candidate was added* — so the
  allowance `coordinator_prompt_max_bytes` computes came out negative, the
  fit ladder was never walked, and the API refused the stage on every node of
  the fleet for eleven consecutive cycles with no work selected anywhere.
  `coordinator_refinements_view` now keeps a `spec` only for an item some
  band of the cycle actually offers, and keeps `ts`/`cycle`/`comment_url` for
  every item as before. `prompts/coordinator.md` gives a spec exactly one use
  — pasted verbatim into the work order of an item being selected — so a spec
  for a non-candidate was prose the model paid to read and could never act
  on. On the cycle that found the outage this took the band from 237,339
  bytes to 29,304, and the unsheddable overhead from 387,840 to 179,629.

- A Co-Ordinator allowance that comes out at or below zero now sheds as much
  as the ladder can rather than nothing at all (agent-ops#643). The branch
  added with `coordinator_prompt_max_bytes` warned and then fell past the fit
  entirely, sending the candidate bands whole — which is how a 350,052-byte
  `issues` extract went into a prompt that was already over the window
  without it. The allowance is now clamped to 1 before the ladder is walked:
  0 or less means "bound off" to `coordinator_fit_bands` and returns the
  array unchanged, while 1 fails every rung and lands in its final branch,
  which returns the smallest array the ladder can build with `fits: false`.
  The warning still says the prompt may be refused regardless; the cycle just
  no longer makes that more likely on its way out.


- The Co-Ordinator no longer takes the fleet down by outgrowing its model's
  context window (agent-ops#641). On 2026-08-21 the assembled prompt reached
  ~226580 tokens against a 200000-token window and the API refused four
  consecutive cycles on every node; nothing had broken, the `issues` band had
  simply grown one comment at a time past a limit nothing measured. See
  `coordinator_prompt_max_bytes` under Added for the bound.

- A stage the API refuses outright now says which refusal it was
  (agent-ops#641). The whole record of those four lost cycles was `coordinator
  exited 1`, and the crash-loop escalation sent its reader to
  `coordinator.out.stderr` — which an API refusal leaves empty, because the
  refusal is a `result` with `is_error: true` in `coordinator.out`. The
  `attempt-failed` detail is now "<stage> was refused by the API before it
  could run: <terminal reason>", with the API's own message beside it on the
  event as `api_message`; the two are kept apart deliberately, since the
  crash-loop ladder groups on the detail and the message carries a token count
  that moves every cycle. The escalation's hint names `coordinator.out` first.

- A cycle with `refiner_model` empty (no Refiner) no longer pays for the
  Refiner's `triage_only` pre-flight (agent-ops#567): candidate computation
  itself is unconditional, so a repository contributing a triage-only
  candidate still cost a `Priority`-field GraphQL read, and could still log a
  `refiner:` warning about candidates it dropped, for a stage that could never
  engage. The pre-flight now runs only when this installation has a Refiner —
  unchanged, including under `--dry-run`, for one that does.

- A Co-Ordinator `needs_refinement` report for an issue can no longer
  re-assert a `Blocked-by:` dependency the Script's own gate already resolved
  (agent-ops#566). Requirement 3j drops any issue naming an unresolved
  dependency before the Co-Ordinator ever sees it, but a stale sentence can
  still sit in an otherwise-selectable issue's thread after the reference it
  named has closed — one cycle read that sentence for five separate issues
  and reported each `needs_refinement`, even though the dependency gate had
  already cleared all five. `record_needs_refinement_block` now refuses, with
  a logged warning and no block, label, or assignment, any `source: "issues"`
  entry whose own `reason`/`missing`/`evidence` names — by issue number — a
  dependency this cycle's own gathered thread already proves resolved
  (`dependency_refusal_reason`, `lib/dependency-gate.sh`); a genuine
  under-specification or question/discussion decline on the same item is
  untouched. `prompts/coordinator.md` now states plainly, ahead of restating
  the mechanics, that this exclusion's dependency half is never the
  Co-Ordinator's to re-derive, and that `evidence` may never assert the live
  state of an item outside this cycle's own runtime input.
- `lib/issue-priority.sh`'s cache-dir ownership record could be talked into
  removing a directory it never created (agent-ops#552, follow-up to #548/#541).
  The record was trusted straight from the environment with no check that it
  came from this process, so an inherited `ISSUE_PRIORITY_CACHE_DIR_OWNED=1`
  let a child process treat a caller's own directory as its own and `rm -rf`
  it; a new `ISSUE_PRIORITY_CACHE_DIR_OWNER_PID`, stamped with the creating
  process's own `$$`, is now required to match before a record is trusted. A
  stale record also outlived the directory it named — a source following a
  cleanup could keep trusting a directory that no longer existed, leaving
  field-id caching dead for the rest of that process — fixed by checking the
  directory still exists independently of cleanup's own record-clearing (which
  does not reach a caller invoking it through a command substitution), and by
  keying `issue_priority_cache_cleanup` on the owned path itself rather than
  the current `ISSUE_PRIORITY_CACHE_DIR`, so a directory this file created is
  never abandoned when a caller later repoints `ISSUE_PRIORITY_CACHE_DIR`
  elsewhere.
- `merge_autonomy_routine_sources` can now name issue work at all
  (agent-ops#558). The key shared one `sourceToken` enum with
  `repos[].sources`, but the two are matched against different things: a
  `sources` token is compared against a *candidate*, while a routine-list
  token is compared against a finished work order's own `source`, which
  `scripts/gather-issues.sh` has by then collapsed from `issues:<band>` to
  the plain word `issues`. The shared enum therefore offered exactly the
  four spellings landing can never match and withheld the only one it can,
  so an installation widening its routine list to include issues got a
  config that validated and not one issue ever armed. agent-ops#519 caught
  the silence and added a doctor warn whose remedy — "list `issues` itself"
  — the same enum then rejected, leaving issue work with no writable
  spelling at all. The key now takes its own `landingSourceToken` enum
  (bare `issues`, no bands), a banded entry is a schema error rather than a
  silent never-match, and `scripts/doctor.sh` reads a bare `issues` in the
  routine list as gathered whenever the repository's own `sources` carry any
  `issues:<band>` — without which following its own advice would simply
  trade one warning for another. Banding remains a gathering-time rank that
  landing cannot see, now stated plainly in the schema rather than buried as
  a disclosed limitation: `issues` is all-or-nothing at the arming step, and
  an installation wanting only its low-band issues landed narrows what it
  gathers, not what it arms.
- `landing_eligible`'s routine-source membership test no longer inverts on
  jq 1.6 (agent-ops#558). `jq -e` exits 0 on *empty input* under jq 1.6 and
  4 under jq 1.7, and both `_landing_routine_sources`' array probes and the
  membership test itself fed possibly-empty strings to `jq -e`: on a 1.6
  host the routine list resolved empty instead of falling through to the
  shipped default, and the membership test then admitted every source the
  gate exists to refuse. The container image pins jq 1.7 (`ubuntu:24.04`),
  which is the only reason this was never a live fail-open on the fleet — an
  argument from a pinned dependency rather than from the gate's own code,
  which is the wrong thing to rest an arming decision on. All three call
  sites now test for emptiness explicitly before consulting `jq -e`. The
  three `test/landing.test.sh` assertions that failed on any jq 1.6 host —
  and passed in CI purely because CI runs inside the image — now pass
  everywhere.

- `scripts/doctor.sh` now also warns when a repository's effective
  `merge_autonomy_routine_sources` names a banded `issues:<band>` token
  (agent-ops#519): the existing "does this repository's own `sources` list
  gather it" check (agent-ops#512) passes cleanly, since the banded token
  typically is present there too, but every `issues:<band>` work order's own
  `source` collapses to the plain word `issues` before `landing_eligible`'s
  exact-string comparison ever runs (`lib/landing.sh`'s own header) — a
  known, disclosed limitation — so the entry could validate clean and still
  never match a work order. The new warn names the offending token and
  suggests listing `issues` itself.
- `scripts/doctor.sh` now checks that a repository configured at
  `merge_autonomy: agent-merges-routine` or above can actually land a pull
  request the way `landing_arm` would (agent-ops#532): where its default
  branch carries no merge queue, the arming step falls back to `gh pr merge
  --auto --squash`, a call that needs both the repository's own
  `allow_auto_merge` and its `allow_squash_merge` and which GitHub refuses
  outright when either is off — settings nothing in `merge_autonomy`'s own
  validation looked at, so the combination passed every gate, reached the one
  write, and failed it on every otherwise-eligible pull request indefinitely.
  The check `fail`s that pairing naming which of the two is off and both
  fixes (enable it, or adopt a merge queue), is `ok` for an active queue
  regardless of either setting, `skip`s whatever it cannot read — including a
  `repos/{slug}` that returns neither key, the pair GitHub withholds from a
  token without admin visibility of the repository's merge settings — and
  stays silent below the routine tier. A setting read as a definite `false`
  outranks an unreported sibling, so an unreadable one never masks a setting
  doctor did read as off. `--offline` skips it with the rest of the GitHub
  section.
- `landing_arm` (`lib/landing.sh`) now returns a distinguishable exit status
  for each of its own failure points rather than a bare non-zero, and
  `run_landing_stage` folds `_landing_arm_failure_reason`'s text into its
  `landing-refused` reason — so the log names which step failed (the pull
  request read, the merge-queue read, the enqueue mutation, its partial-write
  case, or the fallback merge) instead of one generic "could not enqueue or
  auto-merge" shared by all of them.
- The Reviewer can no longer flip a draft pull request ready while a
  standing human comment goes unanswered (requirement 31c, agent-ops#533,
  PR #512): a human cannot leave a formal `REQUEST_CHANGES` review on this
  system's own pull requests, so a plain PR comment — often paired with
  converting the pull request back to draft — is the change-request signal
  here, and nothing previously refused a hand-off that silently dropped one.
  `lib/reconciliation-gate.sh`'s new gate reads every general PR comment
  posted since the pull request's most recent `ready_for_review` timeline
  event *as the round found it* — bounded by the cycle's own start time,
  since the Reviewer runs `gh pr ready` itself and an unbounded search would
  take that flip as the anchor and filter out every comment the round existed
  to answer — and refuses the flip, on the same terms as the existing
  closing-keyword gate, unless a pipeline comment since cites it with
  `<!-- agent-ops:reconciles comment=<id> -->`. A refusal names each
  unanswered comment by permalink, so the next round can act on it rather
  than re-deriving it. `prompts/reviewer.md`'s
  completion comment now carries that citation for every human comment it
  answers.
- The reconciliation gate above (requirement 31c, agent-ops#533) could refuse
  a pull request exactly once per unreconciled comment, never twice
  (agent-ops#539). A `dirty` verdict left the pull request exactly as the
  Reviewer's own step-7 `gh pr ready` had just left it — ready, not draft —
  so that flip survived the round it was refused in, and because GitHub keeps
  a `ready_for_review` event rather than deleting it when a later
  `convert_to_draft` supersedes it, that surviving flip became the very next
  round's reconciliation anchor: the standing comment the gate had just named
  fell before it and read as reconciled, permanently, one round after the
  refusal. `handoff_complete_review` (`lib/handoff.sh`) now calls
  `confirm_pr_draft` on every `dirty` reconciliation verdict — the same
  "confirm against GitHub, don't trust the call's own exit status" shape
  `confirm_pr_ready` already applies in the forward direction — converting
  the pull request back to draft on both the Reviewer's own handoff and the
  Enabler's `complete_handoff` recovery path, and `_reconciliation_gate_anchor`
  (`lib/reconciliation-gate.sh`) now skips any `ready_for_review` event that
  has a `convert_to_draft` event after it at or before the bound, so a
  reverted flip cannot win the anchor either. A revert that itself fails to
  take logs its own warning, distinct from the ordinary refusal, since the
  pull request is at that point not merely carrying an unanswered comment but
  still ready for a human to merge. `prompts/reviewer.md`'s own anchor
  instructions (step 6) now carry the same undone-event exclusion, since the
  Reviewer's live read of "most recent `ready_for_review` event" was open to
  the identical trap.
- `merge_budget_oldest_waiting`'s `waiting_backlog` (the pull request a
  `merge-budget-hold` event names as the one waiting longest) now sorts
  GitHub's own listing oldest-first before paging, so a repository with more
  than `GITHUB_PR_LIST_LIMIT` open, labelled pull requests names the true
  oldest rather than the oldest of whatever page happened to come back. Its
  search now also excludes drafts server-side (`draft:false`), so a
  repository whose oldest page is entirely drafts still names its true
  oldest non-draft instead of reporting no backlog at all.
- `lib/issue-priority.sh`'s field-resolution cache directory (issue #510) is
  now removed by the process that created it, rather than left behind once
  per sourcing process — a directory per cycle in a long-lived node
  container, and one per `scripts/doctor.sh` run, which had no exit trap at
  all. `issue_priority_cache_cleanup` is idempotent and removes only a
  directory the library itself created, never a caller-supplied
  `ISSUE_PRIORITY_CACHE_DIR`; `agent-cycle.sh` calls it from its `cleanup()`
  EXIT trap, after the Refiner that is the cache's main consumer, and
  `doctor.sh` from a new EXIT trap of its own.
- `lib/issue-priority.sh`'s cache-directory ownership (issue #541, a
  follow-up to #510) is now a property of the directory rather than of the
  most recent source: a process that sources the library twice used to see,
  on the second source, `ISSUE_PRIORITY_CACHE_DIR` already set to the
  directory the first source created and read it as caller-supplied, so
  `issue_priority_cache_cleanup` declined to remove the very directory the
  library made. `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATH` now records the path
  the library created for itself, so a re-source with that same path still
  marks it owned.
- The per-process fleet-flag memo (issue #502) is now keyed by mode as well
  as by flag and `state_dir`, so a default-mode `clear` answer can never be
  served to a later `probe-404` read of the same flag, and reads it into a
  variable rather than testing-then-reading the memo file, so a file that
  vanishes or is empty mid-write falls through to a live fetch instead of
  being served as an (incorrectly) confirmed answer. `run_approver_stage`'s
  own read of the merge-autonomy kill switch now always bypasses the memo,
  so an operator's mid-cycle kill stops the stage at its own boundary rather
  than waiting for the next cycle's process to notice.
- `approver_escalate`'s "could not settle, and the escalation issue could not
  be filed" warning event now carries `pr_url` and a `detail` naming it — a
  pre-existing bug (a bash string interpolation, not the intended jq `--arg`)
  silently emptied both fields under `set -u`.
- The dashboard's switch banner for a node stood down with
  `agent-cycle.sh --this-node --disable` (issue #514) now reads "This node is
  disabled" rather than "Pipeline disabled" — the old wording read as a
  fleet-wide stand-down even though only the one node had stopped. Its
  re-enable advice now names `--enable --this-node` for a genuine node-scoped
  disable, rather than the bare `--enable` it shared with the fleet-wide
  banner and the orphaned-mirror case (agent-cycle.sh's own `--status` report
  and the fleet-strip badge already drew this distinction; the banner did
  not) — the bare command clears the fleet switch, not this node's own
  record, and would have left the node down after an operator followed it.
- The Priority triage ratchet (requirement 39g) no longer overwrites a band
  outside the four names it ranks (issue #509). `issue_priority_current` used
  to parse only `Urgent`/`High`/`Medium`/`Low`, so an organisation-added
  fifth option read back as no band at all and the ratchet's skip guard never
  fired; it now reads the raw option name, and `issue_priority_apply` skips
  such a band (`skipped-unrankable`, logged like any other ordinary skip)
  instead of silently replacing it. `gather-issues.sh`'s `priority_set` is
  now true whenever any option is set on the field, not only one of the four
  recognised names, so a fifth-band issue is no longer offered to the
  Refiner's triage duty as if nobody had triaged it.
- A repository whose `Priority` field this token cannot resolve at all no
  longer re-engages the Refiner forever for band-only (`triage_only`)
  candidates it can never actually band (issue #511). A pre-flight
  (`refiner_filter_unbandable_triage`, `agent-cycle.sh`) now resolves each
  contributing repository's field once per cycle before any candidate is
  claimed, drops that repository's `triage_only` candidates when the field
  cannot be resolved — every other candidate, from that repository or any
  other, is unaffected — and logs one `warning` per affected repository
  naming it and how many candidates were dropped. Previously such a
  repository's `triage_only` candidates re-entered the candidate set every
  cycle with no possible progress, and `refiner_engagement_set`'s
  alphabetical cap meant an early-sorting repository in this state could
  fill the entire engagement set, starving refinement everywhere else.
- `gather-issues.sh`'s `priority_set` (issue #527, a follow-up to #509/#522)
  no longer reads `true` for a `Priority` field value that carries no
  `single_select_option` at all — GitHub's field-value union also includes
  text and date shapes, which an admin retyping the field can produce, and
  the raw option name it contributed was `null` rather than nothing. Such an
  issue read as triaged and never reached the Refiner's triage duty again;
  it now agrees with `issue_priority_current`'s own verdict and reads
  `priority_set: false`, same as an unset field.
- The dashboard's `by_model` chart and `cost_rows[]` (issue #536) no longer
  credit a transcript's whole `total_cost_usd` to whichever model
  `(.modelUsage | keys)[0]` named — jq's `keys` sorts, so a transcript that
  spent on more than one model (routine, since a subagent call inside a
  stage often reaches for a cheaper one) always credited its entire cost to
  the alphabetically-first model touched, systematically Haiku ahead of Opus
  and Sonnet. Measured on poetic-node-1 on 2026-08-17, this credited Haiku
  98.7% of the fleet's spend against its true 12.4% share, and Opus did not
  appear at all. `scripts/publish-dashboard.sh`'s cost scan now reads each
  `modelUsage` entry's own `costUSD` and sums them independently per model,
  reproducing `total_cost_usd` to the cent; `by_day` and `by_actor` are
  unaffected, still counting one row per transcript. `cost_rows[]` — which
  the model/actor charts' own time-frame selector (issue #334) re-aggregates
  client-side — now carries one row per (transcript × model) rather than one
  per transcript, and without a way to tell those rows back apart the
  windowed `by_actor` figure would have double-counted any transcript that
  spent on two models; `cost_rows[]` rows now also carry the transcript's own
  `cycle` id so the client can dedupe on it and count transcripts, not rows.
- The own-label read-back (requirement 39f) no longer misattributes its own
  `needs-refinement` label writes to a human when the reading node's clock
  runs behind GitHub's, or when a peer node's `own-label-action` record has
  not yet reached this node's union log (issue #526). `lib/label-marker.sh`'s
  comparison now matches any recorded `add` within a skew tolerance of
  GitHub's own `labelled_at`, in either direction, rather than requiring
  ours to be no later — which the RC4-style recurrence measured failing in
  the trailing-clock direction — and now scans every recorded `add`, not
  only the latest action, so an add that matches followed by a `remove` that
  silently failed is still recognised as ours. A label applied within a
  30-minute grace period with no own record yet is deferred rather than
  read as a human's, since the record may simply not have propagated over
  the fleet's periodic state-sync — neither reported as a hand-flag nor
  offered up for a stale-removal retry until the grace period passes.
- `issue_priority_apply` (issue #534, a narrower follow-up to #511/#528) no
  longer fails a band write outright when a repository's `Priority` field
  resolves but is missing one or more of the four band options — previously
  indistinguishable from a field that cannot be resolved at all
  (`field-unresolvable`), which left the Refiner re-offered the same
  unwritable band, and re-spent, on the same `triage_only` issue forever.
  It now falls back to the nearest band the field actually has an option
  for — preferring the next lower band, tying upward only when no lower
  option exists at all — applies the ratchet against that band instead, and
  names the band actually requested in a new `requested` field wherever it
  differs. A field with none of the four names writable at all is reported
  as a new, distinct reason, `band-option-missing`, rather than reusing
  `field-unresolvable` for a different failure.
- `maybe_run_refiner`'s `mutation-failed` warning (issue #551, a follow-up to
  #538/#534) now names the band actually attempted, not the band the verdict
  asked for, when a fallback ran: previously the warning always named the
  verdict's own band even though the failed write targeted a different,
  fallback band, so an operator reading it could not tell which band the
  pipeline actually tried to set. It now also names the requested band
  alongside the attempted one whenever the failed result carries a
  `requested` field; a `mutation-failed` with no fallback, and the other
  three failure reasons (`field-unresolvable`, `band-option-missing`,
  `issue-unreadable`), keep their existing wording unchanged, since nothing
  was attempted on those paths.
- `refiner_filter_unbandable_triage`'s pre-flight (issue #542, the degenerate
  case between #511 and #534) now also drops a repository's `triage_only`
  candidates when its `Priority` field resolves cleanly but carries none of
  `Urgent`/`High`/`Medium`/`Low` at all — an organisation that renamed every
  option, e.g. to `P0`…`P3`. Previously such a repository passed the
  pre-flight (its field *does* resolve), paid the Refiner's spend every
  cycle, and then hit `issue_priority_apply`'s `band-option-missing` with
  nothing to fall back to, leaving every `triage_only` issue in that
  repository — not just those with one band missing — re-entering the
  candidate set forever: #511's starvation shape again, at #511's own blast
  radius. The new check reuses the field lookup the pre-flight already made
  (`issue_priority_options_any`, `lib/issue-priority.sh`), so it costs no
  additional GraphQL call, and logs a warning worded distinctly from the
  existing "Priority field unresolvable" one. A repository missing only
  *some* of the four names is unaffected — `issue_priority_apply`'s own
  per-issue fallback (#534, above) still bands it.
- The Refiner no longer manufactures a block only a human can clear when it
  finds an item already adequately specified (agent-ops#670 Part 2,
  TD-PPagop-26082305). Its prompt's "never write a second specification"
  rule left `needs-refinement` as the only verdict for that case, and the
  resulting block's own `unblock_condition` — "a human must remove the
  hand-applied label" — named a state the Script's own requirement 34e
  projection was about to create three seconds later: a deadlock the
  pipeline built for itself and could not exit under its own power
  (agent-ops#597, #598, #660, #666). Requirement 39c's `refined` verdict now
  covers **re-affirmation**: an item the Refiner judges already carries an
  adequate, unchanged specification — its own, the Enabler's, or a human's —
  is `refined`, citing the *existing* specification's URL (or reproducing
  its existing text) rather than declined. The Script's recording needed no
  change — `refinement_record_fields` never required the specification to
  be this cycle's own write — so the fix is confined to `prompts/refiner.md`
  and the spec; disagreeing with an existing specification is unaffected and
  still declines `needs-refinement`, escalating rather than being settled
  here.

### Changed

- The Co-Ordinator no longer treats a documentation-only item as a separate,
  lower-priority track (agent-ops#582, owner decision S1 on agent-ops#633).
  `prompts/coordinator.md` now states plainly, beside the existing
  `models.trivial` model-routing rule, that a documentation-only item is
  ordinary selectable work — unparking #590, #600 and #601, none of which
  should have been held back on that premise.
- `agent-cycle.sh` is no longer one 10,000-line file (agent-ops#771,
  discharging the cause of #770). Its ninety-six functions and the top-level
  blocks around them now live in `lib/*.sh` beside the modules they already
  worked with — `lib/stage-attempt.sh` (the Co-Ordinator stage-attempt
  sequence and the failure handling every stage shares), `lib/approver.sh`,
  `lib/landing.sh`, `lib/enabler.sh` and `lib/refinement.sh` (their stages),
  `lib/candidate-gather.sh` and `lib/candidate-select.sh` (the repo-ordering
  and gather loop, the claim loop and candidate selection),
  `lib/standdown.sh` (the stand-down reason ladder), `lib/eligibility.sh`
  (what this cycle is allowed to act on) and `lib/manage.sh` (`--status`,
  `--disable`, `--enable` and the rest) — leaving the file at 2,865 lines
  carrying the cycle's spine and nothing else: argument handling, the lock,
  the ordered sequence of phases, and the exit path. Pure moves, landed one
  seam at a time with the affected tests green at each, and no behavioural
  change: every test that lifted a function out of `agent-cycle.sh` now lifts
  it from its new home, and the implementation spec's component list moves
  with the code.
- `scripts/lint-shell.sh`'s size guard now measures the union `-x` actually
  parses — a file plus everything it sources, transitively — rather than the
  file's own length, which after #771 no longer says anything about what a
  lint costs: `agent-cycle.sh` fell from 10,136 lines to 2,865 while the
  26,262 lines `-x` re-inlines for it, and the more than 4.5 GiB they cost,
  did not move. It also suppresses SC2154 and SC2034 alongside SC1091 when it
  does drop `-x`, all three being artefacts of not following the sources
  rather than findings about the code, and still checked in full in CI, where
  the guard is switched off outright. The split does show up where it counts:
  linted without `-x`, `agent-cycle.sh` now completes in 634 MiB against a
  scheduler container's 1,536 MiB ceiling, so the file that used to be
  skipped outright on a node is now checked on every one.
- The pipeline no longer names a human as the destination of an escalation or
  a landing where `escalation_autonomy` or `merge_autonomy` chooses that
  destination (agent-ops#679, discharging the debt #668 declared). Since #627
  landed `escalation_autonomy`, "needs a human" and "the human gate" had been
  false at `adjudicate-first` and at every `merge_autonomy` rung above
  `human` — and the wording is read by the actors themselves, so a stage told
  the destination is a person could not reason about the ladder it was
  actually standing on. Every line in the repository mentioning a human was
  read and placed in one of three bands: reworded where configuration now
  chooses (the escalation *act* is named, its target is not, and where the
  sentence must say where it goes it names the key), kept where it is a
  person's at every setting — owner-only acts, a human `CHANGES_REQUESTED`,
  hand-applied labels, the `human-visibility` notification cluster — and left
  alone where it is historical record. `lib/refinement.sh`'s runtime refusal
  string and the `enabler-escalation` label's description (updated live on
  every repository the fleet has already created it in, not only in
  `lib/labels.sh`) are now true at both settings. Requirement 36a states the
  distinction outright: every escalation it names is owner-only at every
  rung, and requirement 36b's refinement disagreement is the only one the key
  gates. Requirement 38's opening sentence states its membership test as a
  consequence of the configured ladder rather than as a universal, naming
  #668 as the trigger to revisit it. No identifier changed, so there is no
  migration and no compatibility window; `docs/VOCABULARY-SWEEP-679-AUDIT.md`
  records the band placement for every pattern found.

- Requirement 32 no longer promises `needs-human` as a synonym for the
  Reviewer's `blocked` status (agent-ops#679). The synonym was never
  implemented — no code path ever parsed it — and requirement 32a's `!=
  ready` fall-through already routes every non-`ready` ending, an unparseable
  status included, down the same `attempt-failed` path, which is the
  tolerance the synonym claimed to provide. Nothing behavioural changes; the
  sentence promising it is gone from the spec and from
  `prompts/reviewer.md`.

- Requirement 38b no longer assigns a Co-Ordinator-, Refiner- or
  Implementer-recorded refinement block's issue to `enabler_assignee`
  (agent-ops#639): it projects `blocked` and `blocked:needs-refinement`
  labels instead, mirroring the same lifecycle assignment used to. Assignment
  now means only "a human must personally act" — an actual Enabler escalation
  (requirement 36a) — never the pipeline's own bookkeeping, so it can no
  longer be confused with the two. The Enabler's escalation-link comment
  (requirement 36b, posted on the work item's own issue) now carries a
  structured `Blocked-by: #<n>` line naming the escalation issue, which
  requirement 34j's existing parser already excludes the work item on —
  deterministic, rather than merely readable prose. New
  `scripts/sweep-legacy-refinement-assignees.sh` clears the assignments the
  old mechanism left behind on every still-open block that recorded one (21
  cleared by hand on 2026-08-21 ahead of this fix; 14 more had accumulated in
  `Poetic-Poems/agent-ops` by the time this landed) — idempotent, safe to
  re-run against any repository at any time. `blocked` — unlike its reason
  label — is also a human's own, hand-applied control, so it is projected
  through a read-before-write (`refinement_label_project`) rather than an
  unconditional add, the same guard the deleted `refinement_assignee_project`
  gave the assignment this replaced — in both the fresh path and the
  migration sweep — and a removal that silently fails when a block clears is
  retried every cycle by a new reconciliation sweep
  (`refinement_blocked_label_stale`), so a stuck `blocked`/
  `blocked:needs-refinement` no longer needs a human to notice it. Because
  the migration sweep has no event of its own to record whether a given run
  actually added `blocked` or found it already there, a legacy block never
  offers the generic `blocked` up for release at all — only its reason
  label does — so a legacy-swept issue's `blocked` is over-held rather than
  guessed at, and comes off only by a human's own hand.
- Every `item-void` a Co-Ordinator, Enabler or Implementer
  writes must now cite evidence in one of two checkable forms — a structured
  `{ref, path, expect, pattern}` shape, or a PR/commit citation naming the
  item — or, for a finishing-source item, corroborate directly against its
  own pull request's live state; prose citing neither is refused rather than
  accepted on being merely non-empty (issue #413, WI-10). Also adds a
  machine-checkable alternative to the human `obsolete` label: at
  `merge_autonomy_effective_level` `agent-merges-all`, an Enabler's
  `flag_obsolete` verdict on a stalled draft can be corroborated by a later,
  independent Enabler engagement's own void, at least 24 hours apart, both
  citing structured evidence. `unvoided` is untouched and gains no machine
  path.
- Every fleet flag (the fleet switch, the usage-limit flag, the merge-autonomy
  kill switch and a repository's merge-budget freeze) is now read from GitHub
  at most once per flag per process, rather than once per reader: a cycle that
  resolves `merge_autonomy_effective_level` for each repository spends one
  contents-API read on the kill switch instead of one per repository. A flag
  set or cleared elsewhere is therefore picked up by the next cycle rather
  than part-way through the running one; a flag this process itself writes or
  deletes is picked up immediately.
- **Breaking:** `config.json`'s `review` block is renamed `project_review` and
  restructured: every tunable now lives under `project_review.defaults`
  (installation-wide) and may be overridden per repository on
  `project_review.repos[]` — each entry `{"slug": "owner/name", ...}` — rather
  than the old flat, installation-wide-only block. An installation with its
  own `config.json` outside this fleet must migrate its `review` block to the
  new shape before upgrading; see `docs/REVIEW-PIPELINE-SPEC.md`'s
  Configuration section for the resolution rule and an example.
- `docs/ROADMAP.md`'s D18 row now documents that `landing_arm`'s no-queue
  fallback (`gh pr merge --auto --squash`) merges as soon as every
  **required** check is green, without waiting for a non-required check
  still running, and that an adopter who wants a check to hold a merge
  must mark it required (TD-PPagop-26082101, closed `not-debt`:
  documentation only, no behaviour change).
