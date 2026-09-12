# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **`docs/DATA-HANDLING.md`** (issue #975): a data-handling inventory stating
  what the pipeline reads (public GitHub usernames, issue/PR/comment/review
  text, repository metadata), what it stores and where (cycle logs and
  dashboard data under `state_dir` and its replicated mirror), and the
  retention keys that bound it (`cycles_retained`,
  `state_local_cycles_retained`, `log_retained_bytes`) — ahead of onboarding
  any non-Poetic-Poems installation. Linked from README.md's Installation
  section.

### Fixed

- **The dashboard's cost-window `<select>` is now programmatically
  associated with its label** (issue #975). `costWindowControl()` built the
  `<label>` as a plain sibling of the `<select class="costwindow">`, with no
  `for`/`id` pair — unlike the auto-refresh checkbox elsewhere in the same
  file, correctly nested. The select is now wrapped inside the label, the
  same shape the checkbox already uses; same text, same classes, same
  `onchange` handler.

### Added

- **CI now enforces the tech-debt record-file flip a closing pull request
  owes** (issue #1363). `scripts/check-closing-keyword.sh` takes a repo slug
  and the pull request's own number as two further, optional arguments;
  given both, for every issue its existing marker/closing-keyword resolution
  yields, it reads that issue and — where the issue is
  `pw::type:tech-debt`-labelled and its body's last non-blank line names a
  permanent register file (the "Filed as `tech-debt/<id>.md`, <date>." phrase
  left by #1039's migration or an earlier direct filing) — requires this pull
  request's own changed-files listing to add a `status: resolved` line for
  that file, failing and naming both the issue and the file when it does
  not. Until now the rule lived only in prose (`CLAUDE.md`, `TECH-DEBT.md`
  "Resolution and history", `prompts/implementer.md`, `prompts/reviewer.md`)
  plus `lib/work-gone.sh`'s after-the-fact runtime signal: PR #1355's first
  round closed its issue and left `tech-debt/TD-PPagop-26082412.md` at
  `status: open`, wrong on `main` until a later round caught it by hand.
  `.github/workflows/closing-keyword.yml` passes the two new arguments and
  carries `issues: read`/`pull-requests: read` for them; a `gh` call that
  cannot be made at all warns rather than failing the check, since the
  marker/keyword half never depended on the network.
  `lib/closing-keyword-gate.sh` passes neither argument, so `poetic` and
  `poetic-fiddle` — which carry no `tech-debt/` register of their own — keep
  the marker/keyword behaviour unchanged.

- **A per-owner installation map for the forge authoring App**
  (`PULLWRIGHT_AUTHOR_INSTALLATION_IDS`), the shape agent-ops#913/#921 already
  gave the Pullwright Approver. A GitHub App installation is per account, and
  since the 2026-09-07 re-homing this fleet's repositories sit in two of them
  — `repos[]` on `Poetic-Poems` and `Pullwright`, `state_repo` on
  `Poetic-Poems`, `crash_loop_repo` on `Pullwright` — so the single scalar
  `PULLWRIGHT_AUTHOR_INSTALLATION_ID` D25 shipped with could not have covered
  them: provisioning the App (#1083) would have put one organisation's token
  into `GH_TOKEN` for *every* call, and the PAT was reached for only when a
  mint **failed**, never when a perfectly good token simply did not cover the
  target. `lib/author-token.sh` gains
  `author_token_installation_for_owner`/`author_token_any_installation_id`
  and an optional owner on `author_token_get`/`_credential_present`/
  `_identity_login`, resolving map → scalar → nothing, case-insensitively,
  with one cache file per installation.

  **`lib/gh-shim.sh` recovers the owner from the invocation itself**
  (`gh_shim_target_owner`), because this identity's call site is `gh` — a
  `PATH` shim in front of a binary whose argv five model-driven stages write.
  In order: a buffered `gh auth git-credential` request's `path=` attribute,
  `-R`/`--repo`, a `gh api` `repos`/`orgs`/`users` path (or a graphql
  `owner=` field, or a `repository(owner: "…")` literal), a positional
  github.com URL — plus, **only under `gh repo <subcommand>`**, a bare
  `OWNER/REPO` — and finally the work tree's own `origin` remote. The
  `gh repo` restriction is what keeps a *branch* from being read as a
  repository: every branch this fleet creates carries a slash, and
  `gh pr checkout agent/1051` inside a `Poetic-Poems` clone must resolve to
  `Poetic-Poems`, never to `agent`. A flag's value is never read as an owner
  either. `gh_shim_resolve_token` then mints for that owner's
  installation; an owner neither the map nor the scalar names degrades to
  `PW_GH_DEGRADE_TOKEN` (the PAT) rather than presenting a token GitHub would
  404; an invocation naming no owner takes the scalar default. "Explicit
  wins; empty resolves" is unchanged — a non-empty `GH_TOKEN` is never
  touched.

  For `git` to say which repository it is pushing to,
  `deploy/docker/entrypoint.sh` now also sets
  `credential.https://github.com.useHttpPath true` beside the helper wiring,
  and the shim buffers that one invocation's stdin before feeding it to the
  real binary unchanged. `scripts/doctor.sh` fails, by name and naming both
  variables, for any owner across `repos[]`, `state_repo`, `crash_loop_repo`
  and `pager_repo` that resolves to no installation, and mints once per
  distinct installation, reporting the App's login per owner.

- **A fourth `escalation_autonomy` rung, `decide-with-veto`** (PR #1389,
  requirement 36f), answering recommendation 3 of
  `docs/reviews/2026-09-11-escalation-autonomy-review.md`. The same
  decide pass, at the same tier, over the same escalations, under a wider
  **delegate mandate** its runtime input now names (`mandate`: `tactical` at
  `decide-tactical`, `delegate` here). The mandate adds exactly two reaches
  to requirement 36a's owner-only boundary and nothing else: accepting a
  residual exposure or risk in a repository the installation itself owns
  where the filer named a `## Default` and no credential, ruleset,
  permission, App or account is touched (the agent-ops#1310/#1298 case, which
  the owner then accepted exactly as the filer's default proposed); and
  supplying the **human corroboration of a void** for the three pull-request
  shapes requirement 34k closes — `pr-<n>-abandoned-…`, `pr-<n>-review-…`,
  `pr-<n>-superseded-…` — through a `decide` verdict carrying
  `act: {"kind": "corroborate-void"}`. Never the `-conflict-` or `-dequeued-`
  shapes, which 34k excludes by construction. At `decide-tactical` a verdict
  carrying an act is out of mandate and escalates, with the evidence naming
  the act.
  **The veto moves in front of the act.** A decision that carries one is
  recorded `decision-taken` with `act`/`act_after` and does *not* unblock the
  item; its `pw::decision` log issue says what the act is and when it becomes
  due; and a new per-cycle sweep, `run_pending_decision_acts`
  (`lib/decision-veto.sh`), performs it only after
  `decision_veto_window_hours` (new key, default 24, `0` meaning the next
  cycle) have passed **and** a live re-read finds the log issue still closed.
  A reopen before then cancels the act, recorded as `decision-acted` with
  `outcome: "cancelled"`; an unreadable log issue refuses the act rather than
  taking it; and a pending act whose log issue could not be filed at all is
  abandoned and escalated, because an act nobody could veto is the one thing
  this rung must never take. Performing `corroborate-void` writes the item's
  ordinary `item-void` with `stage: "decision"`, and requirement 34k's
  existing close does the rest — the void record and the close already
  existed; the corroboration was what was missing. A decision carrying no act
  (a pure acceptance) unblocks immediately, exactly as at `decide-tactical`.
  The dashboard's Decisions panel gains a `pending act` badge for a decision
  still inside its window. The product default stays `always-escalate`; the
  Poetic fleet's own `config.json` opts in.
- **The Pipeline Monitor** (issue #1284, `docs/MONITOR-PIPELINE-SPEC.md`): a
  third pipeline, sibling to `agent-cycle.sh` and `review-cycle.sh`, whose
  subject is the pipelines themselves. `monitor-cycle.sh` carries its own lock
  (`monitor-lock.json`), its own stream (`monitor-log.jsonl`), the shared
  switch, the `active` role guard and the shared `limit-hit` signal, and
  defers to a live implementation *or* review cycle. Its cadence is one
  hourly crontab line plus a due gate: the run is owed once a day at
  `schedule.monitor_hour`, and again within the hour after any `pager-fired`
  event — a trigger no crontab line can express, because it is a fact about
  the fleet's own log. Exactly one node takes a given slot, through a
  `lib/claim.sh` file claim under `claims/monitor/`.

  The model never reads a primary record: `lib/monitor-digest.sh` assembles a
  deterministic digest — 24 h of the union log grouped by event class with
  counts and up to three samples each, every `pager-fired`/`pager-cleared`
  and every open `pw::pager` issue, every node's heartbeat verdicts and its
  host-facts record, selections per work band, the Co-Ordinator fit's rung
  histogram and the day's verbatim `none-selected` reasons, the escalation
  repository's own last 24 h, and the specs' `## Gotchas` sections — bounded
  to `monitor_max_input_bytes` by a stated drop ladder that sheds samples and
  gotcha prose before it ever truncates.

  A run produces a dated report in the state store
  (`monitor/<date>/report.md`) and at most `monitor_max_filings_per_run`
  (default 3) filings, each carrying a stable `finding_key` and the
  provenance line `Monitor: monitor/<date> M-<nn>`, deduplicated
  search-first against every open issue already carrying that key. Filing is
  the Script's, never the stage's: **mechanical** findings become
  `pw::type:tech-debt` issues the implementation pipeline then works;
  **tactical** ones are proposed in the report and moved only for keys in
  `monitor_tactical_keys` (empty by default) as a `pw::decision` with the
  #937 veto; **strategic** ones become one `enabler-escalation` assigned to
  `enabler_assignee`, options written out — the only path to the owner.

  The Monitor is also the consumer of pager pages: every open `pw::pager`
  issue gets a triage verdict in the report, a mechanical one gets the
  tech-debt issue filed and one comment on the page linking it, and **no page
  is ever closed by the Monitor** — the pager's transition-only lifecycle
  (`pager-cleared`, `page-outlived-item`) owns that, and a close from
  anywhere else would leave the union log saying `fired` for ever.

  Its stage-health verdict ships from day one rather than as a later issue
  (the gap #996 records for the review pipeline): `stage_health_write_status`
  gains a stage-name parameter and now **merges** rather than overwrites, so
  `agent-cycle.sh` and `monitor-cycle.sh` each refresh only their own stages
  in `.stage-health.json`, and the `monitor` row reaches the heartbeat and the
  dashboard's Stage health panel, fleet badge and banner with no render
  change. New keys: `monitor_model` (default `claude-sonnet-5`; empty
  disables the pipeline), `monitor_max_input_bytes`,
  `monitor_max_filings_per_run`, `monitor_tactical_keys`,
  `schedule.monitor_hour`, `schedule.monitor_offset_minutes` and
  `prompt_overrides.monitor`. Deferred and recorded:
  `tech-debt/TD-PPagop-26091101.md` (the report is not surfaced on the
  dashboard), `tech-debt/TD-PPagop-26091102.md` (the Monitor writes no
  `node-state` transition) and `tech-debt/TD-PPagop-26091105.md` (its
  filings do not reach requirement 2m's push channel, which landed while
  this was in flight).

- **The dashboard's cycle rows, void-item rows and fleet-node cards are now
  keyboard-reachable** (issue #970). These three `.clickable` widgets were
  plain `<tr>`/`<div>` elements with no keyboard behaviour of their own — the
  page's only other interactive widget, the pull-request-reference card, is
  built on native `<a>` anchors and got keyboard support for free. Each now
  carries `tabindex="0"`, `role="button"`, an `aria-label` naming what it
  does, and a `keydown` handler firing on Enter or Space in place of a click,
  and shows the page's ordinary accent-coloured `:focus-visible` outline on
  focus.

- **The host-facts collector** (issue #1283, requirement 36a):
  `scripts/collect-host-facts.sh` writes one record per node,
  `state_dir/host-facts/<node>.json`, of facts no container running the
  pipeline can read for itself, because the runtime deliberately holds
  neither the Docker socket nor the Kubernetes API (the agent-ops#603
  property, unchanged). Two drivers share one envelope
  (`lib/host-facts.sh`) and each add their own vantage-specific section
  (`lib/host-facts-compose.sh`, `lib/host-facts-kubernetes.sh`): `compose`
  reads the Docker Engine over a **read-only** socket mount — container
  state, restart counts, cgroup memory figures, and running-versus-registry
  image digest, one entry per container; `kubernetes` reads the cluster
  over a read-only Role — pods, rollout stalls, CronJob scheduling,
  node-pressure conditions and PVC identity. Both also read the host's own
  disk/memory/load, the host's egress MTU against the configured
  `DOCKER_MTU`, the watchtower ledger tail and last session, and run the
  **viewer-vantage probe** (agent-ops#1286) — fetching every peer's own
  dashboard `data.js` to confirm it actually serves, the self-certification
  gap the 2026-08-08 four-day silent outage burned this installation on
  once already. The record is as-built at `docs/HOST-FACTS-SCHEMA.md` and
  carried to the rest of the fleet by the ordinary `state-sync.sh`
  push/fetch, no dedicated sync code needed. Ships as a `collector` compose
  service (`deploy/docker/compose.yaml`) and a sample Kubernetes CronJob
  manifest (`deploy/kubernetes/collector-cronjob.yaml`); `scripts/doctor.sh`'s
  Egress section now surfaces an MTU mismatch this node's own container
  could never detect on its own, and the dashboard's node card gains a
  `host` line folding in this node's own record and each peer's. Requirement
  36a's "The owner-only boundary" is narrowed to match, and
  `prompts/enabler.md`'s own `escalate` verdict with it: an `escalate` under
  condition 7 (an external account) or condition 8 (information only in
  someone's head) is refused when this record already answers the fact
  being asked for — everything else the boundary reserves still escalates
  exactly as before. The `collector` service joins the host's docker group
  (`DOCKER_GID` in `.env`, defaulting to 999) so it can actually open the
  read-only socket it mounts, and carries the workspaces volume so the
  viewer-vantage probe can enumerate this node's peers.

- **Host-budget stand-down** (issue #757, requirement 2.0g): per-container
  ceilings (D14, #606) bound one container's blast radius, but Docker
  reserves nothing, so nothing before this checked whether the *sum* of
  every container's ceiling still fit the host it shares with its
  siblings — the two-Compose-projects-per-host layout
  `deploy/docker/compose.yaml`'s own D14 comment already reasons about by
  hand. The host-facts record now also publishes the host's own total
  memory and CPU count, and the compose driver's record gains a `budget`
  section summing every running container's declared `memory.max_bytes`/
  `cpu.limit_nanos` from the same Docker socket the collector already
  reads (`lib/host-budget.sh`, `docs/HOST-FACTS-SCHEMA.md`). `lib/
  standdown.sh` stands a cycle down with `cause: "host-overcommit"`,
  arithmetic included in the `reason`, when the declared sum overcommits
  the host — gated by the new `host_budget_enforce` config key
  (`false` by default: advisory only, the figures still published and
  visible, nothing refused, until an operator opts in) and two configured
  reserve margins (`host_budget_reserved_memory_bytes`,
  `host_budget_reserved_cpus`). `scripts/doctor.sh` gains a matching
  advisory "Host budget" section reading the same record.

- **Overrun-slot skips** (issue #1287, requirement 11a): supercronic drops a
  firing silently when the previous cycle's job is still running, logging
  only to a container log the fleet never reads — a cycle running long lost
  its node a whole schedule slot, or several, with no event of any kind and
  a `--status`/dashboard reading of plain `RUNNING` the whole time. At
  cleanup, before the lock releases, `agent-cycle.sh` now computes which of
  its own schedule's slots fell strictly inside its own run and logs one
  `cycle-skipped {reason: "overlap", slot_ts, held_by, elapsed_s}` per slot
  — for the cron-fired original alone, since a chained continuation or a
  `--once`/`--dry-run` run is not supercronic's running job, so its slots
  really did fire and the contending tick already recorded them.
  `scripts/publish-dashboard.sh`'s `noop_ticks` gains an `overlap` count
  (never folded into `total`, since the cycle logging one kept its own row
  by running real stages), and `--status` gains an `overrun: N firing(s)
  overrun in the last 24h` line, which `check-nodes.sh` inherits for free.

- **`escalation_webhook_url` promoted to the installation's one
  push-notification channel** (issue #1279, requirement 2m): `lib/notify.sh`'s
  `notify_post` POSTs one compact JSON body — `{event, key, title, url, repo,
  node, ts, detail}` — to `notify_webhook_url` for every escalation issue
  filed or auto-closed, every `pager-fired`/`pager-cleared` (#1278), and
  every fleet-wide stand-down beginning or ending (a usage-limit cooldown,
  the fleet switch, the merge-autonomy kill switch), gated per class by
  `notify_events` (default all three: `escalation`, `pager`,
  `fleet-standdown`) and coalesced per `(event, key)` pair by
  `notify_min_interval_seconds` (default 600s) so a burst of the same fact
  repeating arrives as one message and a count, while the `end` of a
  transition never disappears behind the `begin` that shares its key. `escalation_webhook_url` — previously only a
  filing-failure fallback — is accepted as an alias for `notify_webhook_url`
  for one release; `scripts/doctor.sh` warns on the old name and gains a
  live reachability check of the resolved webhook host through the egress
  fence. New config: `notify_webhook_url`, `notify_events`,
  `notify_min_interval_seconds`.

  **The alias preserves the URL, not the body.** An installation already
  pointing `escalation_webhook_url` at a receiver keeps delivering to the same
  endpoint, but the JSON it delivers has changed: the old filing-failure body
  was `{reason, detail, repo, item, node, cycle}` and there is no `reason`,
  `item` or `cycle` in the new one. A receiver that reads those fields needs
  updating — `reason` is now `title`, `item` is folded into `key` (as
  `<repo>#<item>`), and the filing failure that used to be the only thing this
  channel sent is now the `escalation-unfiled` event rather than every message
  on it.

- **The pager: fleet-level invariant evaluation, filing and auto-close**
  (issue #1278, requirement 51): `lib/pager.sh`, a registry of named
  invariants evaluated once per Publisher GitHub tick, each a function over
  facts every node already holds fleet-wide (the union log, every peer's
  heartbeat, this node's own doctor verdict). A firing invariant claims its
  evaluation window through `lib/claim.sh`, waits out `pager_min_firing_
  minutes`' hysteresis, then files one deduped `pw::pager`-labelled issue in
  `pager_repo` (default: falls back to `crash_loop_repo`) — a *pipeline-act*
  remedy performs the fix directly and records it, a *config-lever* remedy
  additionally files a `pw::decision` record under `escalation_autonomy:
  decide-tactical`, an *owner-only* remedy assigns the issue to
  `enabler_assignee` — and auto-closes it with a one-line comment the
  moment the fact clears. Ships with two invariants
  (`lib/pager-invariants.sh`): `verdict-unanimous` (the #1071 signature — the
  identical failing verdict on every active node at once, almost always the
  reader being wrong rather than a real fleet-wide failure; files a
  `pw::type:tech-debt` issue against this pipeline's own repository), and
  `page-outlived-item` (closes an open page whose own linked PR or issue has
  already gone terminal, generalising #1215's `approver_escalation_retire`
  to every page this framework or the Enabler files). `.doctor-status.json`'s
  own verdict now folds into every heartbeat, the same way `stage_health`'s
  does, so `verdict-unanimous` can see a peer's doctor verdict, not only its
  own. New config: `pager_enabled` (default `true`), `pager_repo`,
  `pager_min_firing_minutes` (default 15). The dashboard gains a
  `pager-firing` page-top banner and a node-card badge naming a firing
  invariant on the node(s) its evidence names.

- **The dashboard polls a stamp instead of re-downloading `data.js` every
  tick** (issue #1288): every open dashboard tab was re-fetching the whole
  payload — 2.7–2.9 MB measured on real nodes — unconditionally on every
  `dashboard_refresh_seconds` tick, whether or not anything had changed;
  about 45 GB/day per tab left open, and over a slow enough path a single
  tick took longer than the interval it was fired at, so a tab there never
  caught up. `scripts/publish-dashboard.sh` now writes a `stamp.js` sibling
  beside `data.js` on every run — `window.DASHBOARD_STAMP =
  {generated_at, fingerprint}`, a few dozen bytes, atomically, from the same
  no-op-skip fingerprint that already governs whether `data.js` itself gets
  rewritten. `dashboard/index.html` fetches `stamp.js` every tick and
  `data.js` only when its `fingerprint` no longer matches the one last
  loaded; `generated_at` still ticks the header's staleness clock every
  tick regardless. With unchanged data a tick now costs bytes, not
  megabytes.

- **The pager: fleet liveness from a peer's vantage** (issue #1282, part 3c
  of #1126's findings, requirement 51): five more built-in invariants
  (`lib/pager-invariants.sh`), all `owner-only` — the class where every
  signal a node emitted was one it also consumed, so only another node
  evaluating it can catch the gap. `firing-missed` (an active node's newest
  `cycle-start` or `cycle-skipped` older than 2× `schedule.cycle_interval_
  minutes` while its heartbeat is fresh and it holds no lock — caught purely
  from the union log, since `lock.json` is never published; a long cycle
  whose scheduler keeps ticking and skipping around it never counts as
  missed). `node-stale` (publication age
  past 2× `node_stale_after_minutes`; files only after the new
  `pager_stale_file_after_minutes`, default 180 min — a per-key override of
  the framework's own filing hysteresis, `pager_register`'s new fifth
  argument). `updater-stuck` (`updater.status == "stuck"` for over 2×
  `updater_stuck_after_minutes`, reading `.updater.seconds`' own elapsed
  time directly). `review-pipeline-failing` (`review-log.jsonl`'s streak of
  failed review *runs* at 3 or more with no completed review between —
  runs, not events, because `review-cycle.sh` writes `review-end` on every
  run whatever happened, so a failed run's own `review-end` still reports
  `exit_code: 0`; the interim reader pending #996's own heartbeat
  verdict). `dashboard-unreadable` (a node's `data.js` slower than the new
  `pager_dashboard_fetch_seconds`, default 30 s, or unparseable, from a
  viewer's vantage — reads the `dashboard_fetch` field #1283's own
  viewer-vantage probe is expected to fold into `fleet_nodes_json`; never
  fires until that lands). New config: `pager_stale_file_after_minutes`
  (default 180), `pager_dashboard_fetch_seconds` (default 30).

- **The pager: selection and ledger invariants** (issue #1281, part 3b of
  #1126's findings, requirement 51): seven more built-in invariants
  (`lib/pager-invariants.sh`) — the class that wedged or starved the fleet
  in August and September, this time read from the Co-Ordinator's own
  selection/fit machinery and from the block/escalation ledger.
  `idle-with-demand` (owner-only; an active node's last `pager_idle_cycles`,
  default 6, cycles — each read from its own last `node-state` event, since
  several are logged per cycle — all ended `idle-with-demand` with a cause
  other than `back-pressure` — evidence carries the node's own most recent
  `none-selected` reason and `coordinator-input-fitted` detail).
  `fit-ladder-pinned` (owner-only; `coordinator-input-fitted` pinned in the
  ladder's own entry-dropping segment — rung 9 or tighter, where #1128's own
  evidence sat — with entries dropped on every fitted cycle for 24h).
  `work-order-repaired-rate` (owner-only; more than `pager_repair_rate_
  percent`, default 20, of a trailing 24h's selections needed a
  work-order-repaired repair — #821's own signature). `blocked-label-
  orphaned` (pipeline-act; a live `blocked:needs-refinement`/`blocked` label
  with no open block behind it — the remedy calls requirement 38b's own
  release path, `refinement_label_remove`, directly, never a
  reimplementation). `claim-unreconciled` (pipeline-act; an Enabler escalate
  verdict in the trailing 24h with no matching `escalated`/`tech-debt-filed`
  event in the same
  cycle — #815's own signature recurring; the remedy posts one correction
  comment naming what could not be confirmed). `escalation-burst`
  (owner-only; more than `pager_escalation_burst`, default 10, escalations
  filed fleet-wide in 24h, or the same re-flag reason paging the same item
  twice inside that window — fingerprinted with `escalation_autonomy_decide_reason_key`, reused
  from requirement 36d). `digest-truncated` (pipeline-act; a repo's
  `source-state-digest` undercounting a live paginated total this
  invariant fetches itself — #1165's own signature recurring; the remedy
  vetoes that repo's digest for the affected cycle via a new
  `digest-truncation-veto` event `lib/candidate-gather.sh` now checks before
  trusting a digest, then files). New config: `pager_idle_cycles` (default
  6), `pager_repair_rate_percent` (default 20), `pager_escalation_burst`
  (default 10).

- **The pager: landing and approval invariants** (issue #1280, part 3a of
  #1126's findings, requirement 51): three more built-in invariants
  (`lib/pager-invariants.sh`) — the class where a pull request sits ready,
  or a whole repository stops landing, with nothing any existing invariant
  reads catching it. `landing-never-armed` (pipeline-act; a repository
  configured at `merge_autonomy` `agent-merges-routine` or above with
  `landing-refused` activity but no `landing-armed` event in the trailing
  `pager_landing_armed_within_days`, default 7 — #718's own signature: six
  days of refusals and zero armings, because `landing_protected_paths_hit`'s
  `gh api … -F` was 404ing on every call; the remedy files a
  `pw::type:tech-debt` issue naming the repo's own refusal-class
  histogram). `landing-refused-unknown` (pipeline-act; `landing-refused`
  events of class `unknown` — `lib/landing.sh`'s own fail-closed vocabulary
  for a live GitHub read that could not even be attempted — at or above
  half of a trailing 24h's refusals fleet-wide, with at least five; the same
  #718 incident was 72 of 115). `pr-unreviewed` (pipeline-act; a ready,
  non-draft, `pr_label` pull request older than
  `approver_unreviewed_engage_after_hours` with no standing review, no
  `approver-verdict`, no Approver warning and no
  `approver-unreviewed-engaged` event at all — requirement 46's own
  unreviewed trigger never having run for it even once, the #1081 signature
  that stranded PR #1059; the remedy logs the identical
  `approver-unreviewed-engaged` event the ordinary sweep would, `result:
  "unavailable"`, which starts that sweep's own escalate clock for a pull
  request it had never started for at all). New config:
  `pager_landing_armed_within_days` (default 7).

- **Labels a stage asks for** (issue #714, requirement 6c): the Refiner's
  per-item verdict and the Implementer's summary may each name up to 3
  descriptive labels of their own — `{name, colour?, description?}` — for
  the Script to create and apply, the same create-only safety
  `labels_ensure_one` already gives the catalogue's own labels. A name is
  refused, silently to the stage and logged as a `labels-minted` event for a
  human, when it is empty, over 50 characters, carries a comma, or collides
  with a name this pipeline itself reads to decide something (`blocked`,
  `blocked:*`, `obsolete`, `complexity:*`, `pw::type:tech-debt`,
  `pw::owner-decision`, `pw::decision`, `open-question`, or any of this
  installation's own configured control labels) — a minted label is
  inert by design: nothing anywhere in this pipeline ever reads one back to
  decide anything. The Refiner's own suggestions across one engagement share
  a further pool of 10, since only it processes more than one item per
  engagement. `scripts/doctor.sh`'s existing reserved-name check now refuses
  a configured label claiming the whole `blocked:*` namespace, not only the
  exact word `blocked`.

- **`doctor.sh` warns when an empty `merge_autonomy_protected_paths` disarms
  gate 4 for a routine-tier repository** (issue #963, TD-PPagop-26082403):
  a resolved `merge_autonomy_protected_paths` of `[]` — schema-valid, since
  neither the top-level key nor the `repos[]` override carries a `minItems`
  — was silently disabling the protected-path landing gate for any
  repository trusted at `agent-merges-routine` or above, with nothing
  reporting it was off. `scripts/doctor.sh` now warns, naming the
  repository and its configured level, on the model of its neighbouring
  `landing_cool_off_hours 0` warning.

- **Analytics retention policy** (issue #598, D21): a new
  `analytics_retained_days` config key states that `log.jsonl`/
  `review-log.jsonl`'s analytics content — the per-stage metering record,
  the rework record, and the events the item-lifecycle fold reads — is
  retained independently of `scripts/rotate-logs.sh`'s size-based rotation
  and `scripts/state-sync.sh`'s pruning of `cycles/`/`reviews/`, neither of
  which has ever reached either file. Default `0` (retain indefinitely)
  preserves today's behaviour; nothing yet enforces an expiry against a
  non-zero value. `docs/IMPLEMENTATION-PIPELINE-SPEC.md` requirement 2.6d
  also generalises the fleet-wide de-duplication rule `docs/FLOW-SCHEMA.md`'s
  rework record already used (first-wins-by-`ts` on a record's own stable
  identity) to bind every analytics record this policy retains, proved for
  the item-lifecycle fold by a new two-node fixture in
  `test/item-lifecycle.test.sh`. Corrects a since-inaccurate claim, repeated
  in `docs/DASHBOARD-SPEC.md`, `docs/METERING-SCHEMA.md` and
  `scripts/publish-dashboard.sh`'s own comments, that `log.jsonl` rotates or
  can "rotate out of" the union — it never has: `log.jsonl` and
  `review-log.jsonl` have always been excluded from rotation
  (requirement 2.6).

- **Per-close re-filing rate limit for escalation issues** (issue #779,
  decided on #784 as behaviour (b)): a human closing an escalation issue
  without performing the releasing act (removing the `open-question` label
  for requirement 8f, reviewing and merging for requirement 8c) no longer
  gets a fresh escalation issue on every subsequent refusing round.
  `open_question_escalate` (`lib/landing.sh`) and `approver_escalate`
  (`lib/approver.sh`) both now read the most recently closed escalation
  issue for the item live (`escalation_recent_close`, `lib/enabler.sh`) and
  suppress a re-filing within the new `escalation_refile_after_hours`
  window (default 24h, pure comparator `escalation_refile_suppressed`,
  `lib/escalation-autonomy.sh`) — unless it is the one immediate
  re-escalation a failed post-close adjudication owes
  (`escalation_event_logged_since`), which always files regardless of the
  window. `escalation_refile_after_hours: 0` disables the guard outright.

- **Node time-state record** (issue #597, D21): a `node-state` transition
  event, logged the instant a node's own state changes, classifying every
  node-second into one of six states — producing, overhead,
  externally-blocked, idle-with-demand, idle-without-demand, down — with
  idle-with-demand split by cause (`awaiting-tick`, `back-pressure`,
  `peer-claimed`, `coordinator-declined`). Emitted at every stage-start/
  stage-end, every `stand-down` (now carrying a `cause` from a closed
  fourteen-token vocabulary at the sites that previously carried none),
  every genuinely-nothing-selected `none-selected`, `limit-hit`/
  `limit-cleared`, and cycle-start/cycle-end, in both `agent-cycle.sh` and
  `review-cycle.sh`. `lib/node-time-state.sh`'s `node_time_state_fold`
  (behind the read-only `scripts/node-time-state.sh`) reconstructs seconds
  per state from these events alone, asserting the invariant (states sum to
  node-count x window) rather than merely trusting it. Documented under
  `docs/FLOW-SCHEMA.md`'s new "Node time-state record" section, alongside
  the rework and item-lifecycle records it joins.

- **Tech-debt close-guard** (issue #877; D15 as revised, #869/#875/#879): a
  new `.github/workflows/tech-debt-close-guard.yml` posts one advisory
  comment when a `pw::type:tech-debt` issue closes with neither a linked
  pull request/commit nor an explanatory comment — `completed` without
  either, or `not_planned`/`duplicate` without a reason. Purely advisory: it
  never reopens the issue, never relabels it, and never fails its own run.

- **Per-repository review instructions and context** (issue #589, D7): three
  new `project_review.defaults`/`repos[]` keys, resolved on requirement 342's
  usual rule, give a review the repository it is reviewing rather than the
  same five facts everywhere. `review_instructions` and `review_context` are
  arrays of installation-held paths, resolved against `state_dir` exactly
  like `prompt_overrides`' `extend`, and reach the Reviewer-Agent's runtime
  input as `instructions`/`context`; a configured path that does not resolve
  to a readable file is a fail-fast error at cycle start and at
  `scripts/doctor.sh`, not the silent skip a `prompt_overrides` path earns,
  because this text changes how strictly a review judges.
  `repo_context_file` additionally admits one file from the repository under
  review's own clone — **context only, never instruction**: text a reviewed
  repository's contributors can edit is trustworthy only as far as a pull
  request into that repository is, so it reaches the model attributed
  `"source": "repository"` and the prompt tells it to read that as evidence
  rather than obey it. Unset by default, and absent from the clone is simply
  absent. `review-stage-start` records every resolved source and a sha256 of
  the text sent, never the text, so a past review's inputs are
  reconstructable from the log. Closes D7's open question — both layered,
  configuration winning.

- **`--now <iso8601>` on `scripts/publish-dashboard.sh`** (issue #957):
  overrides the single instant every rolling window in the script measures
  from — `day_cut`/`today`/`recent_cut` and the WI-8 landing digest's
  `in_window`/`stale()` cutoffs alike — mirroring the seam
  `scripts/publish-revert-rate.sh` and `scripts/autonomy-stage-report.sh`
  already provide, so a test can pin a fixed calendar date instead of
  computing fixture timestamps as offsets from the real clock. Fixes two
  latent bugs found in the process: `day_cut`/`today`/`recent_cut` read the
  real clock independently of `now_iso` rather than deriving from it (no
  production effect without `--now`, since both were always the real clock
  anyway, but it meant `--now` could not reach them), and the no-op
  short-circuit's fingerprint (#787) did not account for `--now`, so two
  ticks over unchanged on-disk state but a different pinned instant would
  have incorrectly served a stale page. Omitted, behaviour is unchanged.

- **Actor and model scorecards** (issue #610, D22): one dashboard card per
  actor with a model choice (coordinator, implementer, reviewer, enabler,
  refiner), one row per model and tier, graded on outcome — attempts and how
  many ended cleanly, terminal fate (landed unchanged / landed after rework /
  voided / abandoned), first-pass yield, cost and wall-clock per landed item,
  and each actor's own measure (the Co-Ordinator's corroboration rate and
  whether its picks landed, the Reviewer's escape rate, the Enabler's unblock
  success, the Refiner's refinement-hold rate). Every row states its stratum
  and sample size and reads "insufficient evidence" below the minimum sample
  rather than ranking on too little data. Supersedes the Co-Ordinator
  verdict-quality panel (issue #319, folded into the Co-Ordinator card's own
  measure) and retires the two "model used" pies (issue #529, folded into
  every row's own `attempts`).
- The **item lifecycle record** additively flags a `landed` item that was
  reworked afterwards (requirement 49, agent-ops#1181): a
  `reworked_after_landed: {since, event}` field, naming the earliest
  item-scoped event later than the item's own earliest landing evidence — a
  reopened or re-worked item, e.g. a second `pr-raised` for another pull
  request — and omitted entirely, never `false`/`null`, when no such later
  event exists. Further landing evidence itself (a second `merge-observed`/
  `issue-closed-post-merge`) does not count as rework. The fate priority
  order and every existing fate's assignment rule are unchanged;
  `docs/FLOW-SCHEMA.md`'s `landed` row and requirement 49's acceptance check
  in `docs/IMPLEMENTATION-PIPELINE-SPEC.md` document the new field.

- A **Rework panel** on the monitoring dashboard (D23, issue #611),
  answering exactly three questions from the rework record and the item
  lifecycle record (`docs/FLOW-SCHEMA.md`) and nothing else: **how much** —
  rework's share of tokens and of elapsed time against first-pass yield;
  **whose** — repetitions grouped by `attributed_stage`, with an explicit
  "not attributed" bucket for the seven classes the record's own attribution
  rule leaves `null`; **how far did it get** — the escape ladder, one row
  per detection stage (agent review, the human gate, post-merge) with each
  rung's population, catch count, escape rate and the measured cost of
  catching one at the next rung. Never presents rework as a quantity to
  minimise (D23): `caught` and `escape_rate` are reported as two separate
  figures on the same row precisely so a falling catch count alongside a
  rising escape rate — the signature of a Reviewer waving work through —
  stays legible as a regression rather than reading as an improvement.
  States its own limits on the panel's face: the rework share is
  cycle-granular (a cycle carrying any rework record counts in full, so the
  share is an upper bound rather than a measured split), and the human-gate
  rung only catches what the reconciliation gate observes at the Reviewer's
  own ready handoff (`TD-PPagop-26082919`). New `lib/rework-panel.sh`,
  wired into `scripts/publish-dashboard.sh` and `dashboard/index.html`.

- A **`--drain` mode** (agent-ops#865, requirements 2.2c/2.3d/2.9): a third
  `disabled.json` `mode`, alongside the switch's original `"stop"`, that stops
  new work being picked up while letting the four finishing sources
  (review-feedback, merge-conflicts, dequeued, abandoned-drafts) keep landing
  until every configured repo has nothing left to finish, then rests there
  rather than exiting. `agent-cycle.sh --drain '<reason>' [--for|--until]
  [--this-node]`, mirroring `--disable`'s own TTL/scope handling; `--enable`
  clears either mode. A `--disable` issued over an active drain tightens it to
  a full stop immediately; a `--drain` issued over an active stop is a usage
  error (`--enable` first), whether that stop is this node's own record or a
  fleet-wide one a peer set; a `--drain` over a `--drain` extends it, same as
  re-issuing `--disable`. `review-cycle.sh` stands down under either mode
  unchanged. `--status`, the dashboard badge and the heartbeat report
  **draining**/**drained** with the finishing-source items still outstanding,
  and log a single deduplicated `drained` event once a drain reaches rest.
  Renames the roadmap's existing Phase 2 *Graceful drain* item — a single
  node finishing its own in-flight cycle before exiting — to *Graceful
  shutdown*, freeing the name for this unrelated, operator-issued mode.
- D15-as-revised's durable-ledger mitigation gains its archive mirror
  (issue #878, following #869/#875/#879): a new daily
  `scripts/publish-tech-debt-archive.sh`, on its own crontab line
  (`schedule.tech_debt_archive_hour`/`tech_debt_archive_offset_minutes`),
  mirrors every `pw::type:tech-debt`-labelled issue, per configured
  repository, into the state repository as one JSON file per issue
  (`tech-debt-archive/<owner>/<repo>/<number>.json` —
  `{number, title, state, state_reason, author, labels, created_at,
  updated_at, closed_at, body}`). The working store is a mutable GitHub
  issue; this mirror's guarantee lives in the state repository's own git
  history instead, since the script only ever adds or updates a file, never
  deletes one — an issue that is later edited, closed, deleted or
  relabelled away still has its last-archived state on record. Costs one
  label search and one open-pull-request listing per repository per run,
  whatever the archive's size; every further call is bounded by what
  changed since the last run, tracked in a small per-repository index file.
  Also audits (and logs, never fixes) two shapes of gap: a labelled issue
  with an empty body, and an open pull request already filed the
  pre-migration way (`lib/tech-debt-file.sh`'s `techdebt_file_debt`, never
  labelled `pw::type:tech-debt` by construction) that is therefore
  invisible to this archive.
- A **decision log and veto** for `decide-tactical` (D18, agent-ops#937): every
  `decide` verdict now files a closed, unassigned `pw::decision` issue — the
  decision, the rationale, the options considered — as a durable record a
  human can scan in one place, alongside a one-click way to undo it.
  Reopening that issue vetoes the decision: `scripts/sweep-decision-vetoes.sh`
  (wired via the new `lib/decision-veto.sh`) re-blocks a non-terminal item
  with a fresh `needs-refinement`, comments on its thread, flips any open
  pull request for it back to draft, and, for a terminal item, files a fresh
  "revisit: …" issue quoting the veto's own comment. The dashboard's new
  **Decisions** panel lists every decision taken in the last 7 days, vetoed
  ones marked as such, and `agent-cycle.sh --status` carries a one-line count
  of decisions taken in the last 24h.
- A **free-memory stand-down** before every cycle (requirement 2.0f), the
  memory counterpart of requirement 2.0c's free-disk gate and deliberately
  the same shape. `lib/memory.sh` is the one place free host memory is read
  and judged — `memory_available_kb` (MemAvailable, not MemFree, and the
  host's rather than this cgroup's, since `/proc/meminfo` is not namespaced),
  `memory_verdict`, `memory_describe` — so `agent-cycle.sh`'s gate and
  `scripts/doctor.sh`'s advisory warning cannot disagree about what "low"
  means. Below the new `min_free_memory_bytes` floor (default 512 MiB; `0`
  turns it off) the cycle stands down with `cause: "memory-low"`, carrying
  both the available and the total KiB, before any stage the host cannot hold
  ever runs. An unreadable `/proc/meminfo` falls through rather than standing
  down on a guess, the same "no evidence" reasoning requirement 2.0's
  `unknown` rests on.

  The gap this closes: requirement 2.0c refuses to start a cycle into a host
  with no room to finish it, and nothing refused to start one into a host
  with no memory to run it. On the ockham WSL2 host — a VM capped at 6 GiB
  running two nodes whose cycles overlap for most of every hour — that is the
  half that kept freezing the machine.
- `scripts/doctor.sh` gains a **Memory** section: the host's available memory
  against the same `min_free_memory_bytes` floor the gate uses, and whether
  anything reclaims this container's own memory before its hard ceiling
  (`memory_cgroup_verdict`, reading cgroup v2 read-only). A cgroup with a real
  `memory.max` but `memory.high` unset reports `unbounded` — it ratchets up to
  its ceiling and returns memory only under pressure — and points at the
  operator recipe now documented in `deploy/docker/compose.yaml`. The
  pipeline cannot fix this itself: Docker exposes no `memory.high` setting and
  a container can read its cgroup but never write it, so detection is the
  whole of what this repository can contribute.
- The **item lifecycle record** (D21 of `docs/ROADMAP.md`, requirement 49,
  issue #595): one durable record per work item, *derived* rather than
  emitted — `lib/item-lifecycle.sh`'s `item_lifecycle_fold`, behind the
  read-only `scripts/item-lifecycle.sh` — folding the union log's own
  item-scoped events into an explicit terminal fate (`landed`, `voided`,
  `superseded`, `blocked`, `abandoned` or `open`), with a checked flow
  invariant and an `unaccounted` bucket for whatever the fold cannot resolve
  automatically rather than dropping it. Two genuine gaps are filled to make
  the fold possible: a `checks-green` event where nothing before named a
  required-checks read that actually came back clean, and a `merge-observed`
  event at `lib/landing.sh`'s own arm site and `scripts/sweep-closed-
  issues.sh`'s periodic sweep — the two merge-observation points issue #916's
  own `merge-observed` event had not yet reached. `{repo, item}` is added, additive, to every
  item-scoped event the fold needs that lacked it (`stage-start`,
  `stage-end`, `pr-raised`, `pr-ready`, `landing-armed`, `landing-refused`,
  `approver-verdict`, `review-gate-checks-read`, `issue-closed-post-merge`).
  `docs/FLOW-SCHEMA.md`'s "The item lifecycle record" section is the
  field-by-field contract, sibling to the rework record above it under the
  same stability policy. `scripts/pickup-metrics.sh`'s own first-seen/
  selection pairing is generalised onto the same fold rather than left
  duplicating it, with its CLI contract and output unchanged;
  `scripts/mine-merge-history.sh` is explicitly out of this item's scope
  (escalation #827) and is untouched.

### Changed

- **A hung test in CI now fails in ten minutes instead of spinning for six
  hours, and the nine slowest test files spawn far fewer real subprocesses**
  (agent-ops#969). `.github/workflows/build-image.yml`'s test-suite loop
  carries the same per-test `timeout 600` `scripts/run-tests.sh` has always
  applied, and its build job carries `timeout-minutes: 90`; between them, the
  one environment that actually gates a merge stops relying on Actions'
  implicit six-hour default — the gap that would have let a watchdog-kill
  regression sit as an unexplained, spinning step. The nine runtime outliers
  the item named now reach the same assertions through fewer real entry-point
  invocations: `doctor.test.sh`, `toggle.test.sh`, `config-schema.test.sh`,
  `review-claim.test.sh` and `state-sync.test.sh` consolidate fixtures that
  differed only in configuration into single multi-repository runs (or, for
  `config-schema.test.sh`, reuse a prior run's output for a byte-identical
  fixture), `toggle.test.sh` writes state directly through `lib/toggle.sh`
  where a `run_node` call was pure setup for a later assertion, and
  `coordinator-input-wiring.test.sh` drops one re-invocation that recomputed
  a byte count it already had. Every file keeps at least one genuine
  subprocess-based assertion; `review-not-before.test.sh` and `role.test.sh`
  are unchanged, each of their invocations having been confirmed to prove a
  distinct branch. Two of those files were also making real, unstubbed `gh`
  calls against this repository's own live GitHub state —
  `publish-dashboard.test.sh`'s launcher-exit-status section and
  `state-sync.test.sh`'s `--disable`/`--enable` pair, both now pointed at the
  existing `DASHBOARD_GH_CMD` seam. README.md's "Running the tests" states
  what a full run actually costs, measured against CI's own history rather
  than a developer host's.

- **`san()`, `expand_home`/`cfg`/`cfg_json`, and `log_event`'s envelope logic
  are each defined once instead of copy-pasted** (agent-ops#967). `san()`
  (the claim-path sanitizer) now lives in `lib/claim-key.sh`, sourced by
  both `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` in place of
  their own identical copies — the correctness-risk case, since a drift
  here would have let `sweep-orphan-branches.sh`'s registry lookups
  silently miss a real claim and delete a branch a peer node still owns.
  `expand_home`/`cfg`/`cfg_json` now live in `lib/config-access.sh`, sourced
  by both `agent-cycle.sh` and `review-cycle.sh`. `log_event`'s envelope
  logic (the issue #361/#458 FIELDS contract) now lives in
  `lib/log-event.sh`'s `log_event_append`, taking the one genuine
  difference between the two cycles' copies — the envelope's id field and
  the target log file — as arguments; each cycle keeps its own one-line
  `log_event` wrapper. Pure refactor, no behavioural change.

- **`maybe_run_refiner` is decomposed into named helpers** (agent-ops#964,
  continuing agent-ops#771's split). The Refiner stage's 322-line function in
  `lib/refinement.sh` is now a 23-line orchestration-only sequence of calls
  into eleven `_refiner_*` helpers split along its existing guard-clause and
  verdict-branch structure — `_refiner_guards_pass`,
  `_refiner_engagement_json`, `_refiner_fleet_limit_active`,
  `_refiner_claim_eligible`, `_refiner_expire_claims`,
  `_refiner_run_engagement`, `_refiner_process_one_verdict`,
  `_refiner_apply_priority`, `_refiner_apply_verdicts`,
  `_refiner_warn_unclaimed` and the shared `_refiner_json_length` — matching
  `lib/handoff.sh`'s style. Pure refactor, no behavioural change: the two
  tests that lift the function out via `awk` now lift the helper carrying the
  marker each one checks for, with their assertions untouched.
  `_refiner_run_engagement` returns through the global `refiner_parsed` and
  is called bare rather than in a command substitution, because the stage it
  runs sets three globals its caller's own shell must see — `stage_pid` and
  `stage_name` for requirement 9c's signal handler, and
  `limit_hit_this_cycle` — and writes the `--once` stage dump to stdout. The
  remaining five pieces of agent-ops#964 (`agent-cycle.sh`'s top-level script
  and four larger functions) are tracked as agent-ops#1253-#1257.

- **A failed Priority write now names why it failed** (agent-ops#960,
  requirement 39g). `issue_priority_apply` (`lib/issue-priority.sh`) sent its
  `setIssueFieldValue` mutation with `>/dev/null 2>&1` and collapsed any
  rejection to a bare `mutation-failed`, so GitHub's own explanation was
  discarded at the pipe. It now captures the mutation's stderr, and a
  `mutation-failed` result carries an `error` key — the first line of that
  text, always present on this reason and empty rather than omitted when the
  mutation produced no stderr at all, so a caller can log it unconditionally.
  `maybe_run_refiner`'s (`lib/refinement.sh`) warning appends `— error:
  <text>` when it is non-empty, alongside the repo, item and band(s) it
  already named. The four documented reasons, the `requested` key and the
  `applied`/`reason` shape are all unchanged; this is additive. What the
  silence cost: the one-token schema mismatch fixed in agent-ops#737 —
  `$optionId` declared `String!` against an argument GitHub types `ID` —
  rejected every Priority write in the fleet for three days behind 14
  identical, unactionable warnings, and the rejection itself named the defect
  precisely the first time it was sent.

- **The Approver's and Enabler's `file_debt` verdict — and the Reviewer's own
  leftover filing when its subject merges mid-pass — now files a
  `pw::type:tech-debt`-labelled GitHub issue, not a register pull request**
  (agent-ops#874, D15 as revised #869): `techdebt_file_debt()`
  (`lib/tech-debt-file.sh`) dedups first against the target repository's own
  open `pw::type:tech-debt` issues by normalised title — every one of them,
  since that search states its own page cap rather than inheriting `gh issue
  list`'s default of 30 — commenting new
  evidence onto a match rather than filing a duplicate, and otherwise creates
  a fresh labelled issue — retrying unlabelled where a fresh repository has
  not had the label ensured yet. The id-reservation branch
  (`scripts/reserve-tech-debt-id.pl`), the `td-record/<id>` filing branch, the
  filing pull request, and their rollback (`_techdebt_unfile`) are retired
  along with it: a single issue create either lands or degrades, with nothing
  left to half-finish. This is the same labelled-issue move PR #919
  (review-sourced debt) and PR #923 (the Co-Ordinator's `tech-debt` band)
  already made for their own paths; `file_debt` was the one caller D15's
  revision had not yet reached. `TECHDEBT_RECORD_BRANCH_PREFIX` stays defined
  in `lib/tech-debt-file.sh` — unused there now, but still sourced by
  `scripts/sweep-orphan-branches.sh` and `scripts/publish-tech-debt-archive.sh`
  to recognise and drain any `td-record/<id>` branch a pre-#874 filing already
  left behind.

- **The test suite no longer expects any particular value from
  `config.json`.** Changing a configured value — a threshold, a cadence, an
  autonomy rung, a repository added or removed — is a configuration change,
  and now touches no test. The shipped file is still asserted to be *valid*
  (it matches `config.schema.json`, and `scripts/doctor.sh` passes it), and
  `scripts/render-config-table.sh --check` still gates the documentation
  regeneration; what is gone is every assertion that quoted a value it
  happens to carry. `test/config-schema.test.sh` now mutates a new
  `test/fixtures/config-base.json` — a configuration the suite owns, asserted
  valid in its own right, naming no `merge_autonomy` or `approver_*` key at
  all — instead of the shipped file, which retires `DOCTOR_NEUTRAL_MUTATION`
  and the per-key normalisations that had accreted around the same failure
  (TD-PPagop-26081801, TD-PPagop-26082201, TD-PPagop-26082302,
  agent-ops#546, agent-ops#560). `test/doctor.test.sh` pins its own
  `schedule` in the single-target-repo fixture, and
  `test/render-crontab.test.sh` derives every expectation for the shipped
  config from the file itself, through `config_defaults` — the renderer's own
  resolution — rather than repeating its minutes, and gives its
  explicit-`CYCLE_MINUTE` and excluded-minute cases schedules of their own.
  `test/publish-dashboard.test.sh` derives its repository counts, so
  "15 calls across 3 repos" follows the file rather than pinning it. The rule
  is now written down in both pipelines' *Acceptance checks* preambles, so a
  new check inherits it; `TD-PPagop-26090610` records the two couplings this
  change does not reach — ten suites still spell out the shipped `state_dir`
  path, and two repository slugs are still written into
  `publish-dashboard`'s GitHub stubs.

- **The Script, not the Co-Ordinator, now composes a work order's `context`,
  `acceptance` and `title`** (requirement 17h, `compose_selected_candidate_text`
  in `lib/candidate-select.sh`) — agent-ops#769, resolving the escalation at
  agent-ops#844 with the owner's decision for option (b). For the ten sources
  the Script already gathers as structured data (`security`, `code-quality`,
  `review-feedback`, `merge-conflicts`, `dequeued`, `abandoned-drafts`,
  `human-visibility`, `register-hygiene`, `tech-debt`, `issues`) the
  Co-Ordinator now selects `{repo, source, item}` and nothing else: the Script
  builds the three text fields itself immediately before the claim, from a
  fresh `gh issue view` for `issues`/`tech-debt` — the only two bands the fit
  ladder (requirement 4i) ever trims — and from the never-trimmed pre-fetched
  band entry for the other eight, using the same per-source template
  `fallback_select_candidate` (requirement 3v) already used. The recorded
  refinement is spliced in unconditionally rather than checked for, generalising
  agent-ops#767. A failed live read, or a candidate naming an item this cycle's
  own gather no longer holds, is a fail-closed skip under requirement 17f's
  existing `untraceable` cause — never a fallback to a trimmed or stale entry.
  `coordinator_model` stays `claude-haiku-4-5-20251001`; its job narrows to
  selection.

  The arrangement this ends: the cheapest model in the fleet was asked to
  reproduce kilobytes of text verbatim out of input its own fit ladder had
  already trimmed, and requirements 17f/17g could only ever catch that failing
  after the fact — agent-ops#821 measured one work order whose `context`
  reproduced an issue to the truncation point and then continued into a section
  that appears nowhere in the issue. The three sources the Co-Ordinator still
  derives itself live — `project-review`, `failed-runs`, `implementation-plan`
  — are unaffected: they have no pre-fetched band to compose from and were
  never subject to the trimming.

### Fixed

- **`test/gh-shim-auth.test.sh`'s "nothing configured" fixture no longer
  leaks a host's ambient `PW_GH_DEGRADE_TOKEN` into its assertion**
  (agent-ops#1432). `gh_shim_resolve_token` falls back to
  `PW_GH_DEGRADE_TOKEN` whenever it is non-empty, and the fixture named
  `GH_TOKEN=` explicitly but never `PW_GH_DEGRADE_TOKEN=` — so on any node
  that provisions `PW_GH_DEGRADE_TOKEN` in its own operational shell (every
  node in this fleet does, for real `gh` calls made outside this test), that
  ambient credential reached the stub and failed the "the call still reaches
  the real binary, with an empty token" assertion, byte-identically on a
  pristine checkout. The fixture now names `PW_GH_DEGRADE_TOKEN=` explicitly
  too, mirroring `GH_TOKEN=`'s existing idiom.

- **`scripts/render-toc.sh` no longer silently passes a target file whose
  `<!-- toc:start -->` / `<!-- toc:end -->` marker pair is missing, unpaired,
  or reversed** (issue #1402). The awk pass only rewrote content already
  between the markers, so a file with neither marker, only one of the pair,
  or more than one of either, was copied through unchanged — regeneration
  was a no-op and `--check` exited 0 even though the ToC region was gone,
  the one case `.github/workflows/toc.yml` could not catch. A file with
  exactly one of each but with `toc:end` appearing before `toc:start` was
  worse: the awk pass would read past the reversed end marker looking for
  one that came after the start marker, silently discarding every line in
  between. Each target file is now checked for exactly one correctly
  ordered marker pair before rendering, in both the plain and `--check`
  invocations, matching `render-config-table.sh`'s existing precedent of
  hard-failing on a malformed region.

- **A review-feedback item whose blocking review has already been answered
  no longer burns a full Implementer/Reviewer/Approver round** (issue
  #1360). `lib/work-gone.sh`'s PR-shaped clearance only asked whether a
  `pr-<n>-review-<id>` item's *pull request* was closed or merged, never
  whether the *specific* review the ref names was still the reviewer's
  standing position — so once a `CHANGES_REQUESTED` review was answered and
  superseded by an `APPROVED` from the same reviewer (bot or human), the
  pull request stayed open throughout and that clearance never fired,
  leaving a stale ref dispatchable for as long as a non-selected node kept
  replaying its own last-cached `review_feedback` band (requirement 48's
  `expensive-gather` cache is refreshed for only one repository per cycle,
  per node). `lib/preflight.sh`'s new `preflight_review_feedback_reason`
  adds a third pre-flight done-signal, scoped to `review-feedback` claims
  alone: one live re-check of the pull request's reviews, recomputing "the
  review currently blocking" exactly as `scripts/gather-review-feedback.sh`
  already does when deciding whether to offer the candidate at all, run
  immediately before the Implementer engagement it would otherwise waste.

- **`digest-truncated`'s live GitHub search no longer false-positives on a
  digest that is merely a few minutes old** (issue #1348). The invariant
  (`pager_eval_digest_truncated`, `lib/pager-invariants.sh`) compared each
  repo's most recent `source-state-digest` event against a freshly fetched,
  unbounded "right now" `gh api search/issues` total, even though the digest
  event's own `ts` was already available — so a repository that creates
  issues/PRs quickly enough between the digest's capture and the invariant's
  next evaluation (this pipeline's own traffic, several per cycle) always
  read as truncated, vetoing that cycle's work-gone clearances for no real
  reason. The live query now carries a `created:<=<ts>` qualifier bound to
  the matched digest event's own `ts`, so it only ever compares like for
  like.

- **A fractional `approver_unreviewed_engage_after_hours` or
  `approver_restale_escalate_after_hours` no longer silently disables
  requirement 46's sweep and the `pr-unreviewed` pager invariant** (issue
  #1353). Both keys are schema-legal `number`s, but every cutoff derived from
  one was computed with GNU date's relative parser
  (`date -u -d "${hours} hours ago"`), which rejects a fractional value like
  `1.5` outright — `lib/approver.sh`'s `_approver_restale_sweep_repo` (three
  sites: stale-review escalate, unreviewed-engage, unreviewed-escalate) and
  `lib/pager-invariants.sh`'s `_pager_ready_pr_candidates` each failed safe to
  an empty cutoff and quietly never fired, with no warning logged anywhere —
  so one schema-legal config value could disable the watchdog and the
  invariant that watches it at once. All four sites now compute the cutoff
  with jq arithmetic (`now - hours*3600 | strftime(...)`), which honours the
  schema's declared `number` type instead of narrowing it and produces the
  identical `%Y-%m-%dT%H:%M:%SZ` UTC string every downstream comparison
  already expects.

- **The same four cutoff guards now log a warning when the computed cutoff
  comes out empty, instead of failing silently** (issue #1366, following on
  from #1353/#1365 above). Narrowing the trigger to schema-illegal values
  did not remove "no warning logged anywhere": a jq failure for any other
  reason — a non-numeric value reaching `tonumber`, or a schema-legal but
  extreme one overflowing `strftime` — still emptied the cutoff and
  disabled requirement 46's sweep and the `pr-unreviewed` pager invariant
  the same way, with nothing in the cycle log to distinguish it from
  "nothing to do". `lib/approver.sh`'s three sites now call `log_event`
  (its own established `warning` channel) and `lib/pager-invariants.sh`'s
  `_pager_ready_pr_candidates` calls `pager_log_event`, each naming the
  config key, the raw value that failed to produce a cutoff, and the
  function it fired from, before falling back to the unchanged
  continue/return behaviour.

- **A `pr-unreviewed` cutoff rejected by the invariant's own numeric-format
  guard now warns there too, rather than only at the guard downstream of it**
  (issue #1403, following on from #1366 above). #1366's warning covers the
  case where the cutoff computation itself fails, and lives in
  `_pager_ready_pr_candidates` — but `lib/pager-invariants.sh`'s
  `_pager_pr_unreviewed_candidates`, its only caller, turns a value that is
  not a plain number away at its own upstream guard, and returned silently
  when it did. It now logs the identical warning shape itself at that guard,
  naming the config key, the raw value and its own function name, before
  falling back to the unchanged `return 0`. Note that this states the
  function's contract rather than closing a live silence: the pipeline's own
  evaluation site, `scripts/publish-dashboard.sh`, already substitutes the
  schema default (`2`) for an `approver_unreviewed_engage_after_hours`
  failing that same regex before the pager ever sees it — which is its own,
  separate silence, filed as issue #1416.

- **Two hand-flag gather scripts no longer read a garbage `labelled_at` off a
  timeline past one page** (issue #1000, TD-PPagop-26082701). `gh api
  --paginate --jq` re-runs its filter once per page and prints each page's
  own result as its own document (TD-PPagop-26081306); `gather-unvoid-
  requests.sh` and `gather-hand-flagged-refinements.sh` still took their
  "latest labeled event" aggregate *inside* the filter, so an issue whose
  timeline runs past thirty events with the label applied, removed and
  re-applied across a page boundary resolved to a multi-line, unparseable
  stamp rather than the single ISO-8601 one downstream code compares against
  block and cycle timestamps to decide whether a request is fresh enough to
  act on. Both now stream one stamp (or `{at, by}` object) per line across
  every page and pick the latest outside the filter — `sort | tail -1` /
  `jq -s 'sort_by(.at) | last'` — the same fix `lib/candidate-gather.sh`'s
  own timeline read already applied (PR #823).

- **`deploy/docker/Dockerfile` pins the `claude-code` CLI install instead of
  floating on `latest`** (issue #968, TD-PPagop-26082412). The image already
  pinned and checksum-verified `supercronic` and `shellcheck` — binaries with
  no package-manager-provided integrity check — but installed
  `@anthropic-ai/claude-code` via `ARG CLAUDE_CODE_VERSION=latest`, on the
  reasoning that CI rebuilds the image on every merge. That left two builds
  of the same commit, days apart, able to produce different images if
  Anthropic published a new release in between, and `claude-code` is the
  dependency with the deepest reach on a node — the same tool/token access
  the pipeline itself has — so a bad release would have reached every
  subsequently-built node with no local pin to fall back to. The `ARG` now
  pins a specific version (`2.1.267`), bumped deliberately in its own PR. The
  OS-package layer below it (`jq`, `curl`, `python3`, `perl`, `git`, ...) is
  left floating on Ubuntu's own apt repository by design — documented in a
  comment beside `FROM ubuntu:24.04` — since it carries none of
  supercronic/shellcheck's risk and a floating layer picks up security
  updates within a rebuild cycle rather than sitting stale behind a pin.

- **The cgroupfs reboot hook no longer leaves a cgroup path Docker can poison**
  (issue #1347). On `ockham-container`, an unclean restart left the node unable
  to start **any** memory-limited container — including sidecars with no
  `cgroup_parent` — with `runc` reporting `openat2
  /sys/fs/cgroup/docker/<id>/memory.max: no such file or directory`.

  Two faults composed. `scripts/cgroup-parent-setup.sh`'s `@reboot` hook ran
  `mkdir` and then redirected into `memory.high`, but at boot the `memory`
  controller is not yet delegated in the root's `cgroup.subtree_control`, so
  the interface files do not exist and cgroupfs will not let a redirect create
  them: the hook half-succeeded silently, leaving a controller-less cgroup.
  `compose.yaml` then bind-mounted those paths, and Docker creates a missing
  bind source **as a directory** — inside the cgroup filesystem a directory is
  a cgroup, so `memory.high` became one, occupying the name the controller
  needs. #1316 had extended the hook to write `memory.max` and
  `memory.swap.max` too, so a failed boot could poison four paths rather than
  one.

  The script now delegates `memory` down every ancestor of the parent before
  writing anything, removes any interface path it finds existing as a directory
  (announcing the repair), and — the invariant that makes this recoverable —
  **removes the parent it created if it cannot finish**, so there is no bare
  directory left for Docker to mount over. A parent that already existed is
  never removed, since it may hold containers. The reboot persistence is now a
  generated script rewritten on each run rather than an inline `&&` chain, and
  installing it replaces any earlier entry for the same parent, so the old form
  does not survive an upgrade.

  The systemd path was never affected: `poetic-1` and `poetic-2` came through
  the same period untouched, because systemd creates the slice with controllers
  already delegated and `Before=docker.service` holds the directory open from
  boot. The parent-cgroup design is sound; the cgroupfs boot hook was the weak
  part.

- **The forge authoring App's token is now minted on demand, not once per
  cycle** (issue #1021, TD-PPagop-26082833). `lib/standdown.sh` used to
  resolve the App's installation token once, at stand-down, and export it
  as `GH_TOKEN` for the rest of the cycle's process — but the token carries
  GitHub's ~1 h lifetime, and a cycle routinely outlives that (the
  Implementer alone budgets 150 minutes), so a long-running stage's
  `git push`/`gh pr create` could present an expired credential after all
  its work was already paid for. `lib/gh-shim.sh`'s `gh` transport shim now
  mints (or reuses a cached token) immediately before every `gh` call, and
  the same shim, reached through `git`'s own credential helper
  (`deploy/docker/entrypoint.sh`), does the same for plain `git` — both
  minting only when `GH_TOKEN` is already empty, so an explicit token (a
  human's own, or the Approver's) always passes through untouched.

- **The livelock band between a parent cgroup's `memory.high` and an
  unbounded `memory.max` no longer has no escape** (issue #1305, following
  #1296). A parent ceiling that only sets `memory.high`, with `memory.max`
  left at `max`, throttles the whole hierarchy without ever disengaging: the
  cgroup sits above the soft ceiling and below both cgroups' hard ones,
  nothing anywhere reclaims past or kills, and every allocating task parks in
  uninterruptible `D` state. `ockham-container` wedged 75 minutes in exactly
  this band on 2026-09-09 — 2,788,595 throttle events climbing at
  ~96/second, `docker exec` itself hanging — while `doctor.sh`'s `parented`
  verdict reported it `[ ok ]` throughout. `scripts/cgroup-parent-setup.sh`
  now also sets the parent's `memory.max` (`--max`, default `1536m`, the sum
  of what runs under it) and `memory.swap.max` (`--swap`, default `0` — the
  same incident took 100% of host swap on a memory-capped VM), and `--check`
  exits 2 for a parent whose `memory.high` is set but whose `memory.max` is
  not. Two new read-only mounts (`AGENT_OPS_SCHEDULER_CGROUP_MAX`,
  `AGENT_OPS_SCHEDULER_CGROUP_EVENTS`) let `lib/memory.sh`'s
  `memory_cgroup_verdict` tell a closed band (`parented`) apart from an open
  one (`livelocked`) or an unmeasured one (`unconfirmed`, never guessed as
  `parented`), and let `doctor.sh` warn on a rising delta in the parent's own
  `memory.events` `high` counter — a signal that fires even on a
  `livelocked` or `unconfirmed` node, since it needs no ceiling correctly
  configured first. Separately, `scripts/lint-shell.sh`'s memory budget now
  reads the parent cgroup window too and costs *every* file's estimated
  `shellcheck -x` memory against it, not only files above a fixed line-count
  threshold. A line count picked to isolate one file says nothing about what
  a node can afford: `scripts/doctor.sh`'s 9,367-line union sat under the old
  10,000-line gate and so followed its sources unconditionally, at an
  estimated 772 MiB against the 768 MiB a parented node actually has — a
  ceiling its own container-only budget reading never saw. On such a node
  `agent-cycle.sh`, `scripts/publish-dashboard.sh` and `scripts/doctor.sh`
  are now skipped rather than linted, which is the announced trade: CI has
  the memory and still checks all three in full.
  `scripts/publish-dashboard-launcher.sh`'s pacing backoff is now
  clamped to what its window has left, so a tick costing minutes rather than
  seconds — this incident's own symptom of the wedge — cannot compute or log
  a backoff of hours.

- **`state-sync.sh` now redacts tokens and home paths before pushing state**
  (issue #966): its push committed `log.jsonl`, `review-log.jsonl`, cron
  logs, and cycle/review transcripts to the private state-mirror
  repository — deliberately never rotated — with no redaction pass, even
  though `publish-dashboard.sh` already strips token-shaped strings and
  home-directory paths from its own (lower-risk) published payload as
  defence-in-depth. The pattern set is now shared (`lib/redact.sh`) and
  applied to every file the push stages before it commits.

- **A scheduler's memory ceiling now survives being recreated**
  (TD-PPagop-26090401, following issue #1266). `memory.high` — the soft
  ceiling that has the kernel reclaim a ratcheting cgroup instead of
  OOM-killing whatever stage reaches the hard limit — was previously written
  onto the container itself by an operator recipe, and every `docker compose
  up -d`, watchtower roll and reboot wiped it. Measured across this fleet on
  2026-09-08, after the recipe was applied by hand to all four schedulers:
  three had lost it again within 90 minutes to ordinary rolls, and one had hit
  its hard ceiling 23,995 times in the 92 minutes since being recreated. The
  register item filed against this in September predicted it; what was new was
  the half-life — and, on a `systemd`-driver host, that "until the next
  recreation" was itself optimistic: any `systemctl daemon-reload` erases a
  container-level `memory.high` on a live container, nothing recreated and
  nothing restarted, because systemd re-applies the properties a unit
  *declares* and a `docker-<id>.scope` declares no `MemoryHigh`. A package
  upgrade touching any unit on the host is enough.

  The ceiling now goes on the scheduler's **parent** cgroup, selected with
  Compose's `cgroup_parent`, because the parent is not what gets recreated.
  `scripts/cgroup-parent-setup.sh` creates it and prints the two `.env` lines
  that put it to use — `AGENT_OPS_SCHEDULER_CGROUP_PARENT` and
  `AGENT_OPS_SCHEDULER_CGROUP_HIGH`. Both are unset by default and both are
  genuinely inert unset: Compose renders no `cgroup_parent` key at all, and
  the parent window mounts `/dev/null`, so a node that has not opted in
  behaves exactly as before. Under the `systemd` driver the parent is a slice
  unit, so systemd re-applies `MemoryHigh=` on every start and reboots are
  covered — and, because a slice unit *does* declare the property, a
  `daemon-reload` re-asserts the ceiling rather than clearing it, the same
  mechanism read the other way round; under `cgroupfs` the directory survives recreation but not a
  reboot, so the script installs a boot hook — a unit where systemd is PID 1,
  a root `@reboot` crontab entry where it is not, which on the ockham node it
  is not.

  Nothing here is a hardcoded path, which is the lesson #1266 paid for. The
  driver comes from `docker info`; the slice path is derived from systemd's
  own naming rule and cross-checked against `systemctl show`, because systemd
  reads `-` in a slice name as a hierarchy separator and so puts
  `agentops-1.slice` under `agentops.slice` — one level deeper than its name
  suggests, and the same class of wrong assumption as #1266's, one layer up.

  `doctor.sh`'s "container memory" line changes with it. A ceiling on the
  parent is the new `parented` verdict and reads `[ ok ]`; a ceiling on the
  container itself still reads `bounded` but now **warns**, naming itself as
  something the next roll will wipe — a state that is correct today and gone
  tomorrow should not report as healthy. The parent's ceiling cannot be
  inferred from inside a cgroup namespace (verified on the poetic node: a
  container held to 64 MiB by its parent read its own `memory.high` as `max`
  and its own `memory.events` `high` as `0` while the parent counted 250
  reclaim events), so it is bind-mounted read-only as a single file — a
  measurement rather than an inference, and narrower than giving the
  egress-fenced scheduler a view of the host's whole cgroup tree.

- **The `memory.high` operator recipe now works on a host whose Docker uses
  the `systemd` cgroup driver** (issue #1266). The recipe in
  `deploy/docker/compose.yaml`'s `scheduler:` block — the documented remedy
  for a scheduler cgroup that ratchets page cache to its hard ceiling and is
  then OOM-killed — hardcoded `/sys/fs/cgroup/docker/<id>/memory.high`, the
  path Docker's `cgroupfs` driver uses. The poetic host runs the `systemd`
  driver, where the cgroup is `/sys/fs/cgroup/system.slice/docker-<id>.scope`
  instead, so the recipe failed there with `No such file or directory`, wrote
  nothing, and left both schedulers unbounded — which is what was killing
  every Implementer stage on `poetic-1` with exit 137. The recipe now derives
  the cgroup from `/proc/<pid>/cgroup` rather than assuming a layout, which
  resolves correctly under either driver (verified on both this fleet's
  `cgroupfs` and `systemd` hosts), and the comment states the difference and
  how to tell which driver a host is on. Detection is unaffected:
  `lib/memory.sh` reads the container's own `/sys/fs/cgroup`, which is the
  same path inside the container under either driver.

- **`dashboard/index.html`'s `kv()` helper no longer builds markup by
  string-concatenating into `innerHTML`** (issue #965, TD-PPagop-26082409):
  its `esc()` helper performed no HTML-entity escaping despite its name, and
  `kv()` trusted it to escape a value (`g.model`, `g.terminal_reason`, …)
  before splicing it into an `innerHTML` string. No live XSS existed — every
  value passed through it today is pipeline-internal — but the broken
  abstraction invited a future stored-XSS regression the moment a call site
  trusted `esc()`'s name with attacker-influenced content. `kv()` now builds
  its `<span class="kv">` via `el()`-based DOM construction (a `<b>` element
  with a `text:` child) instead of `innerHTML`, and the tech-debt/security-
  findings count-summary site now renders via `text:` instead of `html:`
  (it never actually carried markup). No `html:` attribute use remains in
  `dashboard/index.html`.

- **`review-cycle.sh`'s five pre-lock stand-down sites now suppress their
  node-state transition against a live peer review run, not just a live
  implementation cycle** (issue #1275). An operator config change
  (`--disable`, or `project_review.defaults.not_before`) landing while a peer
  `review-cycle.sh` was mid-Reviewer let the next tick's terminal `down`/
  `idle-without-demand` transition overwrite that live run's own `producing`
  on the shared per-node timeline — `suppress_node_state_if_peer_owns_node`
  probed only `lock.json` (a live `agent-cycle.sh`), never
  `review-lock.json`. It now also probes `review-lock.json` for a live peer
  pid, on the same "err toward not-running" terms as the existing probe.

- **Recent cycles no longer reads as an idle fleet when the Publisher could
  not render it** (the 2026-08-29 blackout). Every dashboard in the fleet
  reported "No substantive cycles in the fleet window" for ten days while all
  four nodes worked normally. `scripts/publish-revert-rate.sh` emits its
  post-merge-revert `rework` rows with `cycle: null` by design (they are mined
  outside any cycle); the detail window grouped the fleet's event union by
  `.cycle` without filtering those out, and a null group makes jq build
  `{(null): …}`, which is a fatal error rather than a null row. Because that
  one program renders every cycle in the window, the first such row cost the
  whole panel, and the per-cycle cache then drained as the window slid over
  cycles that were never rendered. `scripts/publish-dashboard.sh` now filters
  cycle-less events before the group, as the file's three other
  `group_by(.cycle)` readers already did.

  The ten days are the other half of the fix. That jq's stderr went to
  `/dev/null`, the guard's only action was to leave the cache alone, and the
  publish then reported a successful write — so a page saying the fleet had
  done nothing was the sole evidence, and it was indistinguishable from a
  fleet that had. A failed render now writes jq's reason to the Publisher's
  log, carries `cycle_render: {ok, error}` in `DASHBOARD_DATA`, and withholds
  the state fingerprint so the next tick rebuilds instead of skipping;
  `dashboard/index.html` renders that verdict as a red banner naming the
  Publisher's own failure, which outranks every other empty-state message.
  The publish itself still completes — one broken panel must not cost the
  other twenty.

- **The Implementer no longer risks losing its own test evidence to the Bash
  tool's 10-minute ceiling** (issue #962, extending agent-ops#734's Reviewer-
  side fix). Requirement 24's "Verify like CI does" step runs the identical
  140-odd-file `test/*.test.sh` suite as the Reviewer, through the identical
  `scripts/run-tests.sh`, under the identical one-shot, no-resumption
  constraint (requirement 21), whenever the repo under work is agent-ops
  itself — so a single unbatched invocation risked the same silent loss of
  test evidence #734 fixed for the Reviewer, and nothing in the Implementer's
  own prompt or the spec said so. `prompts/implementer.md`'s "Long-running
  commands" section now documents the ceiling in the same terms
  `prompts/reviewer.md` already does, and step 4 now directs the Implementer
  to list this repo's own suite via `scripts/run-tests.sh --list` and batch
  it into groups sized to clear the ceiling, instead of one unbatched call or
  a hand-rolled loop — the same discipline requirement 29a already requires
  of the Reviewer. `docs/IMPLEMENTATION-PIPELINE-SPEC.md` gains requirement
  24c, mirroring 29a. No change to `prompts/reviewer.md`, requirement 29a, or
  `scripts/run-tests.sh` itself.

- **The PAT-expiry warning no longer implies classic tokens are exempt from
  it** (issue #1233). `lib/token-expiry.sh` and its callers described the
  `GitHub-Authentication-Token-Expiration` response header as absent for "a
  classic PAT" alongside an installation token — false: GitHub sends the
  header for any personal access token, classic or fine-grained, that has an
  expiry set, and has done since the header was introduced for classic PATs
  in 2021. The mechanism itself never gated on token type and needed no
  code change; only the wrong claim, and the "fine-grained" label the
  warning's own user-facing text and comments carried, are corrected — this
  node's PAT expires in N day(s) at `scripts/doctor.sh`'s warn/ok lines and
  `agent-cycle.sh`'s escalation issue heading, and README.md's own
  description. Matters now rather than eventually: #912 moves every node's
  `GH_TOKEN` to a classic PAT, and a reader of the old wording would have
  concluded the warning goes dark at that cutover and needed a manual
  stand-in — it does not, and never did.

- **Both by-number callers of `landing_protected_paths_hit` now fail closed
  on an exit code outside its documented contract** (issue #1232). That
  classifier's contract is exits 0/1/2/3, but its two callers that branch on
  the number defaulted the other way — toward a pass — for anything else
  (e.g. `128+n`, the command substitution's own subshell being signal-killed
  mid-gate). `landing_eligible` (`lib/landing.sh`) handled 0, 2 and 3
  explicitly and then fell through to `eligible`, which is right for the
  legitimate 1 and a silent pass for everything unrecognised; `lib/approver.sh`'s
  protected-path-forces-Critical check enumerated `== 0 || == 2 || == 3`, so
  an unrecognised code skipped the forced critical tier — the same fail-open
  shape pointing at the cheaper tier. Each call site now names only the
  legitimate exit 1 (no protected path touched) as its explicit exemption and
  routes every other code to the fail-closed side: `landing_eligible` returns
  `unknown:` naming the out-of-contract code, and the Approver forces the
  critical tier. Nothing changes for the documented codes 0, 1, 2 and 3, and
  `landing_protected_paths_hit`'s own contract is untouched; the fix is to
  the default arm alone, on the gate `lib/landing.sh`'s own header calls the
  deadliest landing class.

- **`landing_eligible`'s `unknown:` diagnostic now names which of
  `landing_protected_paths_hit`'s two refusal causes actually fired**
  (issue #961). `landing_protected_paths_hit` (`lib/landing.sh`) returned a
  single exit 2 for both an unreadable or truncated changed-file list and —
  since TD-PPagop-26082320 — a `merge_autonomy_protected_paths` entry it
  cannot evaluate against a changed path at all, and `landing_eligible`
  printed the same "could not establish …'s changed-file list" wording for
  either, so a malformed protected-paths override sent whoever debugged it
  to `gh` and pagination rather than to their own `config.json`
  (agent-ops#718 held D18 arming shut for five days on exactly this wording,
  for the changed-file-list cause). The unevaluable-list cause is now its own
  exit 3, and `landing_eligible` names the protected-paths list explicitly
  for it, mirroring `scripts/detect-classifier-escapes.sh`'s own wording for
  the same cause. `lib/approver.sh`'s protected-path-forces-Critical check —
  the one other caller that branches on this exit code by number rather than
  through a catch-all — now also treats exit 3 the same fail-closed way it
  already treated exit 2; the split would otherwise have made a malformed
  protected-paths list silently skip the critical tier there.
  Diagnostics only: no change to which pull requests `landing_eligible`
  admits or blocks.

- **An adjudication `refuse` naming a concrete, unanswered defect no longer
  pages the owner** (agent-ops#1214). `prompts/approver.md` gives the model
  three adjudication verdicts — `land` (resolved), `refuse` (something real
  the pull request still gets wrong) and `escalate` (a genuine judgement call
  neither side is equipped to settle alone) — but `lib/approver.sh`'s
  adjudicating `refuse)` branch escalated unconditionally, so a verdict that
  explicitly disclaimed escalation paged a human anyway, under an
  `approver_escalate` body that misstated what the engagement had concluded
  ("could not resolve the disagreement"). A `refuse` now posts
  `REQUEST_CHANGES` and returns to `review-feedback` next cycle like any
  ordinary refusal, escalating only once it keeps recurring — the third
  consecutive adjudication `refuse` on the same pull request — and the
  escalation issue's body now names which of the three conditions
  (`escalate`, an unparseable/failed verdict, or a recurring `refuse`)
  actually triggered it, instead of one fixed sentence for all three.

- **An Approver-adjudication escalation issue is now retired when the
  pipeline itself resolves the disagreement it was raised for** (issue
  #1215). Nothing previously read a `pr-<n>-approver-adjudication` escalation
  back once `approver_escalate` filed it, so it stayed open long after the
  disagreement ended without a human — issue #1202 sat open for eight hours
  after its own adjudication `land`ed and merged, still asking a human to
  review and merge a pull request that was already merged, until they closed
  it by hand. `approver_escalation_retire` (`lib/approver.sh`) now closes it,
  logging an `approver-escalation-retired` event (`cause: "land"` or
  `"merged"`), from either of the two places the disagreement can end without
  the human: `run_approver_stage`'s own `land` branch, once its `APPROVE`
  actually reaches GitHub, and `scripts/sweep-closed-issues.sh`'s fleet-wide
  merged-pull-request listing, for a pull request that merges some other way
  — a human's own click, a later automatic landing, or a merge queue
  resolving after the fact. Neither path touches an escalation somebody
  *reopened* after a retirement: a human's own re-open wins, the same answer
  every other close this system performs already gives.

- **`prompts/implementer.md` and `prompts/reviewer.md` no longer tell a stage
  to POST a GitHub App's login for a review-feedback re-request**
  (agent-ops#959). Both prompts said `<login>` was "whoever's review blocks
  the PR" without saying that GitHub's `requested_reviewers` holds only users
  and teams — so on this installation, where
  `pullwright-approver-poetic[bot]` is the account that submits
  `CHANGES_REQUESTED`, a stage following the instruction literally POSTed a
  bot login, got a 200, and found it silently absent from
  `requested_reviewers` on the very next read (PR #713). Both prompts now say
  `<login>` must be a human or team account and that there is nothing to POST
  when the only blocking review is an App's; requirement 31b in
  `docs/IMPLEMENTATION-PIPELINE-SPEC.md` states the same consequence
  explicitly — a blocking App review yields `none`, never `failed`, and
  `ensure_human_reviewer` reaches the human instead. No script or library
  change: `lib/handoff.sh` already excluded bots from its blocking set
  (#194/#257).

- The claim loop (`agent-cycle.sh`) now stamps the configured `pr_label`
  onto every claimed work order, alongside `branch`, unconditionally —
  overriding whatever value the candidate already carried, including none
  (agent-ops#956). Previously a claimed work order's `pr_label` came only
  from the Co-Ordinator's own copy of its runtime input, or from
  `fallback_select_candidate`'s composition on the mechanical-selection path
  (PR #715): a Co-Ordinator whose model output omitted or mistyped the field
  raised a pull request no gatherer — `gather-review-feedback.sh`,
  `gather-abandoned-drafts.sh`, `gather-merge-conflicts.sh`,
  `gather-dequeued.sh`, `gather-human-visibility-hygiene.sh`,
  `scripts/sweep-closed-issues.sh`, `lib/merge-budget.sh` — could ever find
  again, and requirement 2.2's back-pressure count silently missed it. The
  Co-Ordinator's own copy and the mechanical fallback's composition are now
  belt-and-braces rather than load-bearing.

- **NUL byte runs in the pipeline's JSONL logs are now repaired, and what a
  read still drops is counted rather than silently dropped** (agent-ops#794).
  `scripts/publish-dashboard-launcher.sh`'s `repair_log()` — which stripped
  NUL runs from `dashboard.log` only, left by a container killed mid-append —
  is generalised into `fleet_repair_log` (`lib/fleet.sh`) and now also runs
  once per launcher window on `log.jsonl`, `review-log.jsonl` and
  `revert-rate.jsonl`; a `.jsonl` target gets a JSON repair record
  (`log-repaired`, `dropped_nul_bytes`, `dropped_lines`) rather than the
  plain-text line every `fromjson? // empty` reader would otherwise silently
  drop, and the run itself becomes the line break it destroyed — so the record
  it truncated goes and is counted, the intact record it ran into is recovered,
  and `jq -s` reads the whole file again rather than aborting over the splice
  the NUL bytes' removal would otherwise leave. `agent-cycle.sh`
  and `review-cycle.sh` apply the same repair to their own per-cycle/
  per-review `.fleet-log.jsonl` union snapshot immediately after building it,
  since a peer that has not deployed this repair yet can still hand a
  NUL-holed line to an otherwise-clean node. `scripts/publish-dashboard.sh`
  now counts what its own reads of `log.jsonl` and `revert-rate.jsonl` drop
  and carries it as `log_repair` in the payload; the dashboard folds a
  non-zero count into the affected panel's own title.

- `scripts/gather-source-state.sh` now pages its open-issue and open-PR
  listings to completion (`api_json_paged`). A single `gh api` call returns
  one page, and requirement 34i's work-gone sweep reads a blocked item's
  *absence* from these two lists as "the work is closed" — so on a
  repository holding more open issues than one page carries (agent-ops
  passed 100 open issues in early September), every issue past the first
  page read as closed, and the sweep cleared real blocks the moment they
  formed. This is what falsely unblocked #874 on 2026-09-04T14:13Z —
  returning the phantom-refined item to the Co-Ordinator's pool and handing
  the fleet-wide stand-down its trigger — and what cleared the hand-applied
  `needs-refinement` blocks on #874/#877/#878 eleven seconds after they
  formed later the same day, defeating the one human lever for routing an
  item back to the Refiner. A page that fails mid-walk fails the whole
  sample into `ok: false` (deciding nothing), and no output at all is a
  failed sample rather than an empty digest, so the fail-safe direction is
  unchanged. The test suite's stub `gh` now emulates GitHub's real page
  semantics — one page without `--paginate`, every page with it — so a
  gatherer that forgets to paginate loses data in the suite exactly as it
  does against GitHub, instead of passing by stub accident. The workflow-runs
  window deliberately stays a single page; nothing reads absence from it.

- `refinements_map` and `decisions_map` (`lib/cycle-state.sh`) now skip a
  **phantom `item-refined` event** — `comment_url` present but naming no
  comment, the pre-TD-PPagop-26082819 shape — on the same
  `refinement_comment_url_valid` terms `enabler_eligible_items` already
  applied. PR #950 fixed the recording seam and the thrash-guard's
  `refined_before` derivation but left these two extracts trusting the raw
  event, so a phantom already on the union log split the pipeline against
  itself: the map said the item was refined (the Co-Ordinator kept proposing
  it, `refiner_candidate_items` kept excluding it from a fresh
  specification), while requirement 17f's traceability gate could never
  resolve the recorded URL — every claim faulted `untraceable`, and once
  Co-Ordinator variance answered "nothing to do", the no-op fingerprint
  (whose refinements projection the phantom sat inside, unchanging) held the
  whole fleet in stand-down indefinitely. That is exactly how #874's
  2026-08-28 phantom idled all four nodes from 2026-09-04T17:15Z: cycles ran,
  every one stood down, and nothing on the log's own terms could repair it.
  With the skip, the phantom items read unrefined (the Refiner owes them a
  genuine specification), the traceability gate has nothing unresolvable to
  fault, the dropped entries change the fingerprint's refinements projection
  so the fix itself wakes the fleet, and a phantom never supersedes a pending
  tactical decision. Requirement 3h states the rule; requirement 35a now
  names all three reading seams.

- `deploy/docker/compose.yaml`'s scheduler `mem_limit` comment claimed the
  1.5 GiB ceiling was "~5x the observed peak". It is not. That 2026-08-24
  figure was `docker stats`', which reports `memory.current` minus
  `inactive_file` and so excludes most of the page cache the cgroup actually
  holds, while `mem_limit` bounds the total. Re-measured 2026-09-04 against
  `memory.current` itself across live cycles, the two schedulers peaked at
  1423 MiB and 1326 MiB against the 1536 MiB ceiling — 7% and 14% below it,
  or ~1.05x rather than ~5x. The comment now states the meter alongside the
  measurement, and records that the OOM-kill exchange it describes does not
  actually happen on a host where `docker info` warns "No swap limit
  support": `memory.swap.max` stays `max` there, so a container over its
  ceiling swaps instead of dying, which on a memory-capped VM is what freezes
  the host.

- A **GitHub API budget** dashboard card (issue #1090), the first section on
  the page: the latest readable rate-limit reading (core/graphql used,
  remaining, reset countdown), a trailing-24h per-hour table of peak core
  usage alongside refusal and requirement-2.0 stand-down counts, and two
  badges — **about to bind** (the latest reading is below its configured
  floor) and **meter gone quiet** (no readable reading in the last two
  cycle intervals) — answering whether the shared rate-limit bucket is about
  to bind before the first `guard-degraded` refusal, not after. Folded
  entirely from the fleet's existing `github-budget` log events
  (requirement 2.0d); the publish tick spends no new `gh` call for it.
- Four of the hottest per-pull-request and per-repository GitHub reads move
  from the REST `core` pool onto the idle `graphql` pool (agent-ops#1085):
  `lib/handoff.sh`'s review/reviewer/author/pending-review-request reads
  collapse onto one shared GraphQL query; `lib/candidate-gather.sh`'s
  per-repository default-branch/tip-commit poll becomes one GraphQL call per
  repository; `scripts/gather-human-visibility-hygiene.sh`'s
  `could_not_read_reviews` re-check folds into its own existing GraphQL read,
  now that both share the same surface; and `lib/issue-prefetch.sh` gains
  `issue_prefetch_open_issues`, a paginated GraphQL walk replacing
  `scripts/gather-issues.sh`'s and `scripts/gather-tech-debt.sh`'s REST issue
  listing plus one REST call per surviving issue for its comments — which,
  as a side effect, also fixes those two gatherers silently missing every
  open issue past their REST listing's own uncontrolled first 100-issue
  page. Each new query validates against GitHub's live schema via the
  existing `scripts/check-graphql-drift.sh`, discovered automatically with
  no workflow changes.
- A `gh` transport shim, installed on `PATH` ahead of the real binary
  (requirement 2.0e, agent-ops#1084), so every `gh` call — this
  repository's own scripts and a model-driven stage's bare `gh …` alike —
  passes through it. A plain `gh api` GET is conditioned on a stored `ETag`
  and served from cache on a `304`, which GitHub's own guidance says does
  not count against the primary rate limit; a primary-limit `403` or a
  `5xx`, with a fresh-enough cached body, is served last-known-good with a
  `PW_GH_CACHE=stale` marker; a successful write invalidates the cache
  entries its own path feeds. Writes, `graphql`, `--input`, a caller
  already reading its own headers, and a `--paginate`/`--slurp` read are
  always passed through unmodified — the last of those because `-i` changes
  the shape of the document `gh` prints for a paginated call rather than
  merely prepending headers to it, though such a read is still stored and
  still served last-known-good.
  Every call is ledgered (`state_dir/gh-shim/ledger.ndjson`) and a cacheable
  GET's ratelimit headers update a per-identity `budget.json`;
  `scripts/github-budget-report.sh` sums the ledger by cache outcome and
  `scripts/rotate-logs.sh` bounds its size.
- New `min_prs_between_reviews` skip-guard for the review pipeline
  (agent-ops#1079), analogous to the existing `min_days_between_reviews`:
  a repository whose default branch has had fewer than this many pull
  requests merged since its last review is skipped this run, independent of
  the day-count guard (a review needs both enough elapsed days *and* enough
  merged PRs). Configurable at `project_review.defaults.min_prs_between_reviews`
  and per-repository as `project_review.repos[].min_prs_between_reviews`;
  absent everywhere, a code-level default of `5` applies, the same pattern
  `report_directory` already uses. `review-cycle.sh`'s `skip_reason()` gains
  a `min_prs` parameter and a `merged_pr_count_since` helper, fail-open to
  "proceed" on any `gh` read it can't verify, and only evaluated once a
  repository has a most-recent review date to count PRs since.
- Expensive per-repository gather — issue threads with comments, the
  tech-debt register, PR review reads, merge-conflict/dequeued/register-
  hygiene walks — runs for one configured repository per cycle, not every
  one of them (requirement 48, agent-ops#1086): `lib/expensive-gather-
  cache.sh` picks whichever configured repository this node has gone
  longest without reading and caches its raw gather under `state_dir`, so
  every other repository reuses its own last read (with this cycle's claim
  exclusion and `sources` gating re-applied fresh) instead of paying another
  full GitHub read. Every repository entry gains `expensive_gather: {fresh,
  gathered_at}`; `prompts/coordinator.md` requires a live re-check before
  selecting from a non-fresh entry, and requirement 34j's dependency release
  reads only the repositories this cycle actually gathered, so no block is
  cleared on a replayed band's stale proof. Cheap fleet-wide probes (repo ordering,
  `gather_source_state`, label-ensure, unvoid/hand-flagged-refinement scans)
  are unaffected and still run for every configured repository every cycle.
  `scripts/github-budget-report.sh` gains a `per_cycle` breakdown (core/
  graphql spend per cycle, node named) to measure the reduction.
- The GitHub API budget is recorded (requirement 2.0d, agent-ops#1087): a
  `github-budget` event at cycle start, after every model stage and at cycle
  end carries both pools' `limit/used/remaining/reset` and `since_previous`,
  the bucket's movement since the process's last reading, read from the
  `x-ratelimit-*` headers of one metered `GET /meta` and the GraphQL
  `rateLimit` object (`github_budget_record`, `lib/github-limit.sh`). New
  `scripts/github-budget-report.sh` sums the events across the fleet's logs —
  per hour (peak used, minimum remaining, refusals, budget stand-downs), per
  stage (the bucket's movement during the stage) and per node — as Markdown
  plus a JSON block. This is the measurement D25 names as the trigger for a
  per-node authoring App: while every node authenticates as one user the
  movement is the bucket's, an upper bound on any one segment's own spend.
- The expensive per-repository gather's rotation (requirement 48,
  agent-ops#1086) is offset per node (agent-ops#1106): a tie among a node's
  own candidates — most often every configured repository uncached — now
  breaks on `_expensive_gather_node_offset`, a stable hash of `node_name`
  reduced modulo the repository count, instead of slug ascending. Without
  this every node ties the same way and reads the same repository fresh in
  the same cycles, leaving every other one unread for the next
  `repositories`-1 cycles; with it, nodes whose names hash to different
  offsets read different repositories in the same interval. A hash spreads a
  fleet without coordination but does not make it cover: node names that
  collide on an offset stay aligned with each other, and a repository whose
  offset no node holds is still read by none of them that interval.
  Assigning offsets so that they cover is fleet coordination
  (agent-ops#1092), not this change.
- `escalation_autonomy` gains a third rung, `decide-tactical` (agent-ops#936):
  one bounded Enabler decide pass (`prompts/enabler-decide.md`) runs before
  *any* `escalate` verdict is filed as a human escalation — not only a
  refinement disagreement, `adjudicate-first`'s own narrower scope — reaching
  `settle` (nothing needed deciding), `decide` (a tactical trade-off the
  pipeline may answer on its own authority, posted as a comment where the
  item is a GitHub issue and logged as `decision-taken`), or `escalate`
  (still a human's call). What counts as tactical versus owner-only is a
  single, exhaustive nine-point boundary (requirement 36a's own "The
  owner-only boundary" in `docs/IMPLEMENTATION-PIPELINE-SPEC.md`), referenced
  rather than restated by `prompts/enabler-decide.md`, `prompts/enabler.md`
  and `prompts/refiner.md`. Bounded per distinct reason rather than once per
  item, capped by the new `escalation_adjudication_max_passes` (default `3`).
  Both `adjudicate-first`'s and `decide-tactical`'s passes now run at the new
  `enabler_model_critical` (falling back to `enabler_model`), the Enabler's
  first critical tier. Poetic's own `config.json` opts in:
  `escalation_autonomy: "decide-tactical"`, `enabler_model_critical:
  "claude-fable-5"`. A `decide` verdict on a non-issue item that already
  carried a refinement now reaches the next Refiner engagement rather than
  being lost: the `item-refined` this path re-records to preserve
  `refinements_map` is marked `unchanged: true`, `decisions_map`
  (`lib/cycle-state.sh`) no longer reads that marked re-record as having
  carried the decision forward, and `refiner_candidate_items`
  (`lib/refinement.sh`) offers such an item as a full candidate for as long
  as its decision stays pending (agent-ops#1049).
- Per-owner Approver App installation resolution (agent-ops#913):
  `PULLWRIGHT_APPROVER_INSTALLATION_IDS`, a JSON object mapping repository
  owner to installation id, so a fleet whose `repos[]` span more than one
  GitHub owner mints the right installation token for each — a scalar
  `PULLWRIGHT_APPROVER_INSTALLATION_ID` alone could no longer do this once
  `repos[]` spans two accounts. Falls back to that scalar for an owner the
  map does not name; a single-owner fleet needs no configuration change.
  `scripts/doctor.sh`'s Approver installation-permissions and
  repository-selection checks now run once per distinct installation and
  name the owner in every verdict, and fail naming the owner and both
  variables when a configured repository's owner resolves to neither — from
  `agent-approves` upward only (agent-ops#1060): a repository at
  `merge_autonomy: human` never mints an Approver token, so it is skipped
  before its owner is even resolved, costing neither a `fail` for an
  installation nothing will use nor a live GitHub read on one. Resolution is
  fail-closed on a malformed map value and on an empty repository slug —
  neither falls back to the fleet-wide scalar, which in a multi-owner fleet
  would mint one owner's installation token for another owner's repository —
  and an installation `permissions` payload doctor cannot compare at all is
  reported as unreadable rather than as the exact-match all-clear
  (agent-ops#575).
- New `scripts/migrate-tech-debt-register.sh` (agent-ops#880), a reusable
  per-repo migration script that closes the gap agent-ops#875 above
  deliberately accepted: for every `status: open`/`status: in-progress`
  `tech-debt/<id>.md` record in a checkout, it creates a
  `pw::type:tech-debt`-labelled GitHub issue carrying the record's title and
  body, then appends a `Migrated to <issue url>.` line to the record's body —
  `status:` untouched, so `td-check.pl` and the append-only open-item-body
  rule both still pass. Idempotent: a record already carrying a `Migrated
  to ` line is left alone, so re-running it against a checkout that already
  reflects a prior run is a no-op. Run once against this repository's own
  register: every open record now has its issue, and the 44 stale
  reservation-only `td/<id>` branches (a single `chore(tech-debt): reserve`
  commit, no filed record, no pull request) that had accumulated on origin
  were released.
- The Approver's and the Enabler's `file_debt`/`file_issue` verdicts gain two
  fields, `default_fix` and `owner_decision` (agent-ops#938): `default_fix`
  names the option the filer would take when the body enumerates more than
  one way to fix it, and `owner_decision: true` reserves the choice under
  requirement 36a's owner-only boundary instead. `lib/tech-debt-file.sh`
  writes either into the filed body as a `## Default: <fix>` heading
  (`## Default: not stated`, logged as a warning, when a filing enumerates
  options and sets neither), plus an `Owner decision: yes` line beside it in
  a tech-debt record or the new `pw::owner-decision` label on a filed issue.
  The Refiner now specifies to a stated default instead of declining with
  `needs-refinement` merely because alternatives exist, escalating only a
  genuine owner-only marker or an unmarked, operator-visible fork — closing
  the pattern behind four 2026-08-28 decision escalations that each took
  three Co-Ordinator cycles and an Enabler engagement to confirm a default
  the filing itself had already argued for.
- A nightly check now asks GitHub whether the GraphQL documents this
  repository sends still mean anything to its schema (TD-PPagop-26082930).
  `scripts/check-graphql-drift.sh` discovers every document by walking the
  tree for `-f query='` at an argv token boundary, wraps each operation's
  selection set in `... @skip(if:true) { … }` — GraphQL validates a document
  in full before executing any of it, so every field is checked while nothing
  is collected, which is what lets the `enqueuePullRequest` and
  `setIssueFieldValue` mutations be validated without being run — and posts it
  as a `{query, variables}` body, which has no reserved key for a document's
  own `$query` variable to collide with. It fails on anything GitHub no longer
  recognises, and equally on anything it could not check: no document found, a
  document that opens and never closes, a document whose shape it cannot read,
  or a file that calls `api graphql` and yields no document at all — the last
  being how a call site written in a different but equally idiomatic form
  would otherwise stay invisible to the check meant to cover it. Drift and
  "could not check" are separate verdicts and the second wins, so a run never
  claims a survey it did not finish.
  `.github/workflows/graphql-drift.yml` runs it daily, deliberately off the
  pull-request path: the failure it catches arrives without a commit, as it
  did when GitHub moved `mergeMethod` and `mergingStrategy` off `MergeQueue`
  and took every autonomous landing down with them for six days while the
  suite stayed green (#953). A red run reaches the pipeline as a
  `failed-run-graphql-drift` candidate only while it is still inside the
  unpaginated 100-run page the Co-Ordinator reads — about seven hours on this
  repository, measured — which TD-PPagop-26082936 records.

- The update mechanism's own verdict now leaves the updater (agent-ops#603):
  `deploy/docker/watchtower-pre-update.sh` records every invocation, one line
  per poll, to a durable ledger under `state_dir` (`updater-ledger/
  <hostname>.jsonl`, keyed by the container's own `$HOSTNAME` and tagged with
  its compose service, excluded from state-sync replication like
  `.image-drift-cache.json`), and a new `lib/updater-health.sh` reads it back
  as `rolled` (the ordinary case, no badge — scoped to the reading
  container's own service, so a stuck sibling of a different service sharing
  this ledger cannot masquerade as evidence of a healthy roll), `deferring`
  (grey, resolves itself, bounded by how long any lock the hook honours could
  still legitimately be held) or `stuck` (amber, a fault only a human clears
  — either the container the hook allowed to roll is still the one running,
  or a defer streak has itself outlasted that same bound). The verdict
  travels in every node's heartbeat as `updater`, a sibling of
  `compose`/`image`/`switch`/`stage_health`, and the dashboard's fleet strip
  renders it as a third badge beneath compose and image; a peer heartbeat
  predating the field, or carrying a status this page does not recognise,
  reads as unknown, never as healthy. New `updater_stuck_after_minutes`
  config key (default 20 minutes), following `image_behind_grace_hours`'
  shape: the threshold lives one layer above the library, never as a literal
  inside it. On 2026-08-14 a node stayed on its previous image through a
  whole fleet roll while every existing signal on the dashboard still read
  healthy, because none of them read the update mechanism's own verdict,
  only the drift it eventually causes.
- The product-managed `pw::type:tech-debt` label is now part of the `target`
  role's catalogue (agent-ops#872), so the pipeline creates it in every
  repository it gathers data for, at most once per
  `labels_ensure_interval_hours`, the same create-only, never-fatal way as
  every other catalogue entry. It is D15's (revised 2026-08-28) store for tech
  debt filed as a GitHub issue rather than an in-repo register record, and its
  name is fixed rather than configurable because it is D24's trust anchor:
  only a collaborator with triage can apply a label, which is what makes an
  issue's membership of the `tech-debt` work band trustable even though its
  body stays untrusted data. The issue-backed band itself is agent-ops#875,
  below.
- A tech-debt filing a human declines no longer leaves its branches behind
  for good (TD-PPagop-26082310). `scripts/sweep-orphan-branches.sh` now
  sweeps a third prefix, `td-record/*` — unconditionally, since
  `techdebt_file_debt` mints a filing's record branch there whatever
  `tech_debt_branch_prefix` says — and treats it as delete-only, never
  recovered: where the branch's own filing pull request was closed without
  merging, a recovery draft would hand the human back exactly the record
  they declined, so the sweep deletes `td-record/<id>` outright
  (`released`, `reason: "filing-declined"`) and then, only once it has
  confirmed `tech-debt/<id>.md` never reached the default branch some other
  way, releases the paired `td/<id>` reservation too — reserving headroom
  for both actions up front against the sweep's per-run cap, so a run one
  action short of the cap defers the whole pair rather than deleting the
  record and stranding the reservation release. A merged filing, and
  one with no pull request at all, are unaffected; the issue #545 exemption
  that leaves a bare `td/<ID>` lock alone is unchanged for every reservation
  with no `td-record/` sibling. `TECH-DEBT.md` documents the same two-branch
  cleanup as the by-hand fallback.
- The `tech-debt` work band now selects from open GitHub issues labelled
  `pw::type:tech-debt` instead of the in-repo register (agent-ops#875, D15 as
  revised #869): `scripts/gather-tech-debt.sh` fetches those issues, sharing
  `scripts/gather-issues.sh`'s deterministic exclusions (assigned, labelled
  `blocked`, an unresolved `Blocked-by:` reference) via new
  `lib/issue-prefetch.sh`, and `gather-issues.sh` itself now excludes
  `pw::type:tech-debt`-labelled issues so the two bands stay disjoint. Between
  this landing and a repository's own register migration, that repository's
  unmigrated register items are invisible to the band — a low-urgency,
  deliberately accepted gap the migrations (agent-ops#880 and siblings) close.
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
- Node host hygiene for `.env` (agent-ops#696): the deploy runbook
  (`deploy/docker/README.md`, `deploy/docker/.env.example`) now states `.env`
  must be `chmod 600`, the same protection the Approver App's private key
  already gets, and that token rotation must edit `.env` in place or swap in
  a `0600` temp file rather than leave a dated backup beside it.
  `scripts/check-node-compose.sh` flags, host-side and without touching
  anything, a `.env` that is not `0600` and any `.env.bak*`/`*.env.old`
  sibling found beside it.
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
- A second GitHub App identity, the **forge authoring App**, distinct from
  the Pullwright Approver (D25, agent-ops#607): every authoring act — clone,
  push, comment, open a pull request or issue — runs under its short-lived
  installation tokens once an owner provisions it (`PULLWRIGHT_AUTHOR_APP_ID`
  / `_INSTALLATION_ID` / `_PRIVATE_KEY_PATH` in `.env`), degrading silently
  to the node's own `GH_TOKEN` when unset, unreadable, or a mint fails —
  never bricking a node. `lib/approver-token.sh`'s GitHub App token-minting
  mechanics are generalised into a shared `lib/github-app-token.sh` core so
  the two identities share one implementation; `lib/forge-auth.sh` resolves
  which credential a cycle authenticates with, ahead of every GitHub call
  including the startup credential probe. `scripts/doctor.sh` reports the
  new identity's presence, key readability and a live mint attempt.
  Landed with the App's own values unset — provisioning it is an owner act.
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
  still wants. No call site uses either function yet — every call site still
  goes through `labels_ensure_role`/`labels_ensure_stamped`, so
  `pw::type:tech-debt`, the one catalogue entry that carries the prefix,
  takes the same create-only path as the rest until a call site is wired
  across; that migration is recorded as TD-PPagop-26082809.
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
- The rework record (D23 of `docs/ROADMAP.md`, requirement 47, issue #596):
  one `rework` event per repetition, emitted by the detector that already
  exists for it — a review round-trip, a human change request the
  reconciliation gate catches, a required-checks read failure, a merge
  conflict or abandoned draft resumed, a stage killed by requirement 4e's
  backstop caps or an escalated crash loop, a claim lost to healthy
  contention, a needs-refinement block on an already-refined item, or a
  post-merge revert/follow-up fix — never inferred after the fact and never
  classified by a model. `lib/rework.sh`'s `rework_fields` and its nine
  per-class helpers are the one shaping layer every site calls; `docs/FLOW-
  SCHEMA.md` is the field-by-field contract, sibling to `docs/METERING-
  SCHEMA.md` under the same stability policy. `docs/FLOW-SCHEMA.md` also
  states agent-ops#533's real, current state — closed 2026-08-20, caught by
  `lib/reconciliation-gate.sh` at the Reviewer's own handoff — and the
  residual coverage that fix does not reach, rather than the blind spot's
  own now-stale framing.

### Fixed

- `scripts/github-budget-report.sh` rendered a null figure as an empty
  tab-separated field, which `read -r` under a tab IFS collapses, so every
  column after it shifted left — on the first live run an hour with
  refusals but no readings printed its refusal count under "core peak
  used". Nulls are now rendered as em dashes inside jq, before `@tsv`.
- A `human-visibility` violation logged as "could not read the pull
  request's state — skipping its review-state checks" no longer survives
  forever once the underlying read starts working again (requirement 38e;
  agent-ops#1127). This is the read that gates every downstream check
  `scripts/sweep-human-visibility.sh` makes for a pull request, so it
  previously fell through as an unrecognised warning shape in
  `scripts/gather-human-visibility-hygiene.sh`'s own live re-check —
  kept indefinitely for as long as the pull request stayed open, since
  that catch-all has no live signal of its own to test. It now has its own
  `could_not_read_state` class there: the live re-check re-runs the sweep's
  own broad `gh pr view --json reviewDecision,mergeable,mergeStateStatus,
  statusCheckRollup,reviews,comments` call verbatim — the narrower `gh pr
  view` this function already opened with proves nothing about it, since it
  omits `statusCheckRollup` entirely — and drops the violation only once
  that call succeeds again.
- The Approver stage skipped a ready pull request silently whenever the
  merge-autonomy kill switch's own read failed closed with no cached copy
  (TD-PPagop-26081507) — a lone rate-limited refusal, the everyday cause,
  read exactly like a genuinely configured or manually killed `human`
  (agent-ops#1081): no App review, and no `warning` logging why, breaking
  requirement 8b's own contract that every other way this stage cannot run
  says so. `run_approver_stage` now asks `merge_autonomy_kill_state`
  directly, ahead of `merge_autonomy_effective_level`, with a new `RETRY`
  argument: on a fail-closed read it classifies whatever was left in the
  kill flag's own `$cache.err` via `github_limit_kind` and, only when the
  cause was rate-limiting, waits out `github_limit_wait_plan`'s existing
  wait/backoff and asks once more before giving up. A still-fail-closed read
  now logs a `warning` naming the pull request, the flag, and the cause,
  distinguishable from a genuinely configured `human` (which stays silent,
  unchanged) — leaving the pull request exactly the shape issue #890's own
  recovery sweep is built to recover, once it lands.
- A blocked `merge-conflicts`, `dequeued` or `abandoned-drafts` ref could
  never reach the Enabler — the only stage that can clear such a block — because
  requirement 35e's stale-ref filter judged it against a set the blocked/void
  subtraction had already emptied of exactly the refs it was being asked about
  (agent-ops#1119). `compute_enabler_eligible_set` (`lib/eligibility.sh`)
  derived its live set of `pr-<n>-conflict-<sha>` /`-superseded-` /`-dequeued-`
  /`-abandoned-` refs from `ordered_repos_json` *after*
  `compute_band_eligibility` had run requirements 3t/3u's
  `exclude_blocked_or_void_items` over those same three bands, and since the
  Enabler is only ever eligible for items that *are* blocked, every such ref was
  missing from the set by construction: judged superseded, logged
  `enabler-stale-refs-skipped`, and dropped — every cycle, forever. It was true
  of 24 distinct refs across two repositories and roughly 1000 skip events since
  2026-08-14, the morning after #329 generalised the blocked/void exclusion from
  `tech_debt` (which #253's filter had been written against) to every
  pre-fetched band but `issues`, silently invalidating that filter's premise.
  `compute_band_eligibility` now snapshots `live_pr_refs_json` from the fresh
  gather at its own start, before its subtraction loop runs, and
  `compute_enabler_eligible_set` consumes that snapshot. The staleness
  comparison itself is unchanged — a ref whose head has genuinely moved is still
  dropped, and a failed derivation still leaves the eligible set unfiltered —
  and the Co-Ordinator's own band eligibility is untouched: it never reads the
  snapshot, and still never sees a blocked candidate.
  `test/pr-claim-exclusion.test.sh`'s "live conflict ref survives" case now
  builds its state *through* the real `compute_band_eligibility` with a ref that
  is both live and blocked — the only shape that can tell the fix from the bug,
  and the reason the hand-built fixture it replaces passed throughout.
- The expensive-gather cache (requirement 48 above) wrote a 0-byte file for
  any repository whose raw bands outgrew `MAX_ARG_STRLEN`, so the fleet's
  busiest repository was invisible to each node two cycles in three
  (agent-ops#1107). `lib/candidate-gather.sh` built the cache document with
  all nine raw bands in argv (`jq --argjson`) — the shape requirement 4g
  forbids — and agent-ops's own raw tech-debt band, 421,622 bytes, put it
  past the 131072-byte cap: `jq` died at `execve` inside `$(…)`, the
  substitution yielded `""` without tripping `set -e`, and the save wrote
  that faithfully, so every node's `Poetic-Poems_agent-ops.json` was empty
  and every non-selected cycle replayed the repository with no issues, no
  tech debt, no review feedback and no findings, indistinguishable in the
  log and the digest from a repository with genuinely nothing to do. The
  nine values now reach `jq` on stdin, one document per line, bound
  positionally with `input as $name`, matching the per-repo entry build
  beside it. The same failure can no longer be silent if it recurs:
  `expensive_gather_cache_save` refuses (non-zero, no write) an empty or
  non-object document, so the caller's existing `|| log_event "warning"`
  fires; `expensive_gather_cache_load` treats a zero-byte or unparseable
  cache file as absent rather than `{}` and logs a `warning` naming the
  slug; and `expensive_gather_pick_repo` treats that same file as
  never-cached (epoch 0), so an affected repository is re-read on the very
  next cycle instead of waiting out a full rotation — which is also what
  heals the caches already on disk.
- Three GitHub REST budget call sites logged a 403 rate-limit refusal the
  same as any other failure, so an operator could not tell "no human was
  notified because the owner's shared budget was gone" from a genuine fault
  (agent-ops#1082): `ensure_human_reviewer`'s review-request read
  (`lib/handoff.sh`) now reports `failed-rate-limited` distinctly from a bare
  `failed`, and all three sites that read that answer — the Reviewer's own
  handoff, the Enabler's `complete_handoff` and the human-visibility sweep —
  name the rate limit in the warning they already logged rather than falling
  silent on the new state; the pull request/reviews read behind
  `sweep-human-visibility.sh`'s idle-nudge check names the cause in its
  warning; and `approver_post_or_warn`'s review write (`lib/approver.sh`)
  does too, and now retries once through `github_limit_wait_plan`'s existing
  wait/backoff (`lib/github-limit.sh`) instead of dropping the verdict
  outright when the cause was rate-limiting.
- A healthy node running long or chained cycles could stay behind the
  registry's newest image for hours — two images behind, on the 2026-08-30
  evidence (agent-ops#1096) — because `deploy/docker/
  watchtower-pre-update.sh` deferred the roll whenever a cycle held the lock,
  and a node whose next cycle starts before watchtower's next five-minute
  poll never presented a gap to poll into: every individual deferral stayed
  correctly bounded by `lock_stale_after`, but the *sequence* of them was
  not, and nothing about the node was actually wedged. `agent-cycle.sh`'s
  `cleanup()` now checks, at every cycle boundary, whether the running image
  has fallen behind (`lib/image-drift.sh`'s `image_drift_status`, the same
  verdict the heartbeat's `image` field already publishes — no second
  signal); if so it declines a chain it would otherwise take and writes
  `$state_dir/roll-pending.json`, which the hook now honours as an
  unconditional allow against `lock.json` alone — never `review-lock.json`,
  which never wrote the marker and never yielded anything (agent-ops#1102)
  — until the window it names expires, or until the cycle that next
  reacquires `lock.json` clears it itself, at its own start, once the image
  is no longer "behind" (also agent-ops#1102: the window is a fixed clock
  offset from cycle-end, not "until the next cycle would have started", so
  without this a reacquired lock could otherwise run its own stages
  underneath a marker still authorising an override of it). The bound is
  now two-part: one cycle's length for a node that is merely busy,
  `lock_stale_after` only for one that is actually wedged. An allow the
  marker granted says so as it signs off, rather than reporting the idle
  path's "no cycle in flight" over the in-flight line the same run printed a
  few checks earlier — that log is what an operator reads after losing a
  cycle to a roll, and is the whole reason this machinery is legible.
- `test/updater-health.test.sh` read the clock twice for one fixture — once
  writing the ledger entry, once as the assertion's expected value — so a
  second boundary falling between the two reads failed "a defer in between
  ends the run" by one second; it did on CI's arm64 leg on 2026-08-30 and
  failed the image build of a merge commit the merge queue had just passed.
  The timestamp is now read once, as the neighbouring `streak_start` fixture
  already did.
- Requirement 2.0's budget gate read `GET /rate_limit`, whose body — read
  cold, as the first call of every cycle — is an empty window (`5000/5000`,
  reset exactly an hour from now) rather than a reading; it answered `ok`
  through 95 recorded refusals in 48 hours (agent-ops#1087). The snapshot now
  comes from the `x-ratelimit-*` headers of a metered call and the GraphQL
  `rateLimit` object, which describe the bucket GitHub enforces — the user's
  aggregate, so the gate is fleet-aware without any per-node arithmetic — and
  a body that carries the empty-window signature is classified `unknown`,
  never `ok` (`github_limit_resource_pristine`). The wrapper's own reset
  lookup under a primary refusal reads the same headers off the refusal.
- An unreachable provider no longer escalates as a deterministic crash loop
  (agent-ops#1073, escalation #1070). `stage_api_refusal` narrows every API
  refusal to one stable token so requirement 2.7's ladder can group across
  cycles whose messages differ (requirement 4i), and that narrowing discarded
  the one fact separating two classes with opposite handling: the API
  *refusing* a request it considered (400, `prompt_too_long`,
  `invalid_request_error` — deterministic, will not clear by retrying) and the
  API being *unreachable* (a 5xx, a dropped connection — external, and
  self-clearing). Between 2026-08-29T22:21Z and 2026-08-30T02:15Z the Ockham
  host lost outbound network, the Co-Ordinator failed 16 consecutive times on
  both nodes with `api_error_status: 503` on every record, and the escalation
  that produced told a human the fault was "almost certainly deterministic …
  no amount of retrying will clear it" — false on its own evidence, and gone
  the moment the network returned. `lib/stage-attempt.sh`'s new
  `stage_api_refusal_class` reads that status (and a named connection-level
  `terminal_reason`) as a sibling of the stable token, answering `transient`
  or `refused`, and `handle_stage_failure` carries it on the `attempt-failed`
  event as `api_refusal_class`; `detail` itself is byte-identical to what it
  was, so nothing about the grouping changes. `crash_loop_verdict` now returns
  an `escalate` field, `false` only when every failure the run counted was
  classified `transient`, and `agent-cycle.sh` logs `provider-unreachable`
  instead of filing an issue in that case — the run is still counted and still
  resets on a Co-Ordinator success. A sustained transient run is not thereby
  invisible: `scripts/publish-dashboard.sh` re-runs the same verdict over the
  fleet union log and `dashboard/index.html` renders a **provider
  unreachable** badge on every node the run names, beside the updater and
  image verdicts, which is where a node-health fact nothing in this repository
  can fix belongs.

- `lib/updater-health.sh`'s `updater_status` no longer reads a stale ledger
  as a permanent **updater stuck** alarm (agent-ops#1071, deciding
  agent-ops#1053, resolving `TD-PPagop-26082913`). Before branching on a
  container's own most recent invocation, it now checks that entry's own
  timestamp against `updater_stuck_after_minutes` first: older than that and
  it reads `null` outright, whatever the `allow`/`defer` streak underneath
  would have said, since nothing has polled the container recently enough to
  answer for the present. Without this gate, a multi-hour network outage
  left every node's ledger trailing a stale entry and the whole fleet read
  `updater stuck` at once, though every node was healthy; a node
  deliberately taken down after its last allowed roll would have read
  `stuck` forever. `rolled` is unaffected — it is a claim about the past and
  already carries its own age.

- `lib/updater-health.sh`'s `allow` arm no longer reads a rolled container's
  own creation as proof it never rolled (agent-ops#1072). Watchtower clones
  `Config.Hostname` forward when it recreates a container, so a roll's
  replacement inherits its predecessor's hostname and keeps appending to the
  very same ledger file — measured across the fleet on 2026-08-30, no
  scheduler's `$HOSTNAME` names its own container id. `deploy/docker/
  watchtower-pre-update.sh`'s `record_verdict` now stamps each ledger line
  with the writing container's own PID 1 start time (`started`, best-effort —
  field 22 of `/proc/1/stat`, in clock ticks since the host booted, which is
  fixed for the life of the process, unlike `stat -c %Y /proc/1`, whose
  procfs inode mtime records when that inode was last instantiated);
  `updater_status` reports `reason: "allow"` only when a container's own
  reading of that value matches the ledger's trailing entry, reads a
  mismatch as `rolled` instead, and the `allow` streak scan itself stops at
  a `started` change as well as a verdict change — closing the residual
  false-positive class agent-ops#1071's liveness fix could not reach on its
  own: a container rolled repeatedly inside `updater_stuck_after_minutes`,
  each roll's own genuine `allow` previously read as one streak spanning
  several successful rolls. An entry with no `started` field supports no
  identity verdict and never produces `stuck` on a hostname match alone.

- A subject pull request that merges mid-Reviewer-pass is now caught and
  retired as a completion, instead of running the rest of the cycle against a
  pull request no longer there (agent-ops#916, escalation #922). Nothing on
  the handoff path used to ask GitHub whether `$impl_pr_url` was still open,
  so a Reviewer whose subject merged part-way through improvised: it opened a
  replacement pull request reported only in prose, invisible to every
  machine-readable record the pipeline keeps for one it raises, while the
  cycle's own tail (`pr-ready`, an Approver engagement, a landing attempt) ran
  against the pull request that had already merged. `lib/handoff.sh`'s new
  `pr_merge_state` is the one fail-closed read both call sites share: at the
  handoff, ahead of `confirm_pr_ready`'s own isDraft read, and, advisory, at
  the Reviewer's own stage-start, so a whole engagement is never spent on a
  pull request already gone. A confirmed merge now logs `merge-observed`
  (`lib/merge-observed.sh`) and retires the item as a completion — never
  `pr-ready`, never an Approver engagement, never `attempt-failed` — filing
  whatever the Reviewer's own verdict found under `file_debt`/`file_issue`
  (the Approver's own field shape) rather than a `Defers:` line, since there
  is no live pull request left to add one to. `prompts/reviewer.md` now says
  plainly that the Reviewer may not open a replacement pull request when its
  subject merges mid-pass.

- `scripts/run-tests.sh --help` no longer stops mid-sentence. Its `usage`
  printed the header block with `sed -n '3,/^# Exit status/p'`, which stops
  *on* the line it matches, so the paragraph explaining what `--list`'s exit
  status means — the part a caller reading `--help` most needs — was never
  printed. Noticed in review of `scripts/check-graphql-drift.sh`, which had
  copied the idiom and truncated its own exit-code contract the same way; both
  now print the block whole.

- Back-pressure no longer counts a ready pull request the pipeline is barred
  from landing as pipeline-owed (#946). At `agent-merges-routine` or above,
  `lib/standdown.sh`'s level-aware exclusion (D18 WI-6) zeroed the human-queue
  count for *every* ready pull request in a repository, without asking
  whether the pipeline could actually land it — so a `complexity:high` pull
  request sat in a human's queue by construction (`landing_eligible` refuses
  anything outside `merge_autonomy_routine_complexity`) while still occupying
  a `max_open_agent_prs` slot nothing in the fleet could free, and the
  composition string it logs (`… plus N waiting on human`) reported `N` as
  lower than the true figure. The exclusion now asks `landing_routine_eligible`
  (lib/landing.sh, the complexity-and-source subset of `landing_eligible`'s
  own gates, factored out so the two can never drift) per ready,
  non-`CHANGES_REQUESTED` pull request — a `CHANGES_REQUESTED` one is owed a
  change by the pipeline at every level whatever its grade or source, so the
  narrowing never reaches it and can never hold fewer pull requests against
  the cap than the un-narrowed rule did —
  complexity from the same listing already fetched, source read back from the
  fleet's union log via `landing_retry_source`, the same primitive the 2.1e
  landing-retry sweep already uses. A pull request whose source cannot be
  resolved this way counts toward the cap rather than being excluded from it
  (fail-closed), logged as a `warning` naming the repository and the pull
  request. `counted_prs_array` (and the `claim.sh count` exclusion it feeds)
  now agree with the same otherwise-eligible verdict, and the dashboard's
  back-pressure card (`scripts/publish-dashboard.sh`, `dashboard/index.html`)
  mirrors it on the complexity half, approximated from each repository's
  configured `merge_autonomy` level rather than the live effective one, to
  avoid a per-repository merge-budget-freeze read on every publish tick.

- Requirement 1a's model-key enumeration
  (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`) named six of the eleven model keys
  `agent-cycle.sh` actually resolves through `resolve_model_id`
  (agent-ops#1002): `refiner_model` and
  `approver_model_default`/`_complex`/`_critical` were all resolved by the
  code and named nowhere in the requirement that governs the resolution. The
  list now carries every key, `enabler_model_critical` included.

- A Refiner (or Enabler) verdict whose `comments_posted[0]`/`comment_url` is a
  bare issue URL — no `#issuecomment-` anchor, so it cannot name any comment
  at all — is no longer recorded as a genuine refinement (TD-PPagop-26082819,
  #935). `refinement_record_fields` (`lib/refinement.sh`) now validates the
  URL's shape (an `#issuecomment-<n>` anchor or a REST API comment URL, via
  the new shared `refinement_comment_url_valid`/`_id`) before extracting
  `comment_url`; an invalid shape is treated exactly as absent, falling into
  the existing `refined-uncorroborated` warning path instead of arming
  requirement 36b's thrash guard on a specification that was never written.
  `enabler_eligible_items` (`lib/cycle-state.sh`) applies the same check when
  deriving `refined_before`, so the two phantom `item-refined` events already
  on the fleet log (agent-ops#818, #874) stop blocking their items with no
  edit to history, and logs a warning naming any phantom it skips. Folds in
  TD-PPagop-26082603 in the same change: `refinement_traceability_fault`
  (`lib/candidate-select.sh`) now recognises the REST API comment-URL shape
  too, via the same shared predicate, rather than silently testing nothing
  for it.
- The Approver stage (`lib/approver.sh`) no longer spends a stale
  installation token on its post-engagement GitHub writes (#945). It used to
  mint the token once, before launching the model engagement, and spend that
  same value afterwards on the tech-debt/issue filings and the review post;
  an installation token lives about an hour, and an engagement lasting close
  to that long — a 749 s critical-tier round on PR #929 among them — spent a
  token already too near expiry, losing a recorded `approve` verdict and its
  filed tech-debt record to a silent `401`. The pre-engagement read is now a
  gate only ("is the credential even readable"); a fresh token is minted once
  the engagement returns and spent across the whole write block, with a
  distinct warning (and, mid-adjudication, an escalation) if that re-mint
  itself fails. `approver_post_review`'s own refusals now land in
  `approver-post.err` instead of `/dev/null`, the same discipline
  `techdebt_file_debt`'s own error log already applies, so a future refusal
  is diagnosable without depending on a sibling call's error file.
- The Co-Ordinator's fit-exemption gate (`agent-cycle.sh`) now reads its own
  fit report correctly, restoring requirement 34e's fourth refusal,
  requirement 3x's trimmed exemption and requirement 17g's fabrication check
  on every fitted cycle (TD-PPagop-26082816, #933). The gate read
  `${coordinator_fit_report_json:-{}}`; bash's `${parameter:-word}` closes on
  the *first* unquoted `}`, so the default word was `{` with a literal `}`
  appended after it — on every cycle the fit actually ran, that stray brace
  corrupted the report into invalid JSON, and the gate silently read it as
  "fit did not run". `coordinator_fit_trimmed_json` was therefore permanently
  `[]` and `coordinator_fit_rung` permanently `0`, and a context-tight
  Co-Ordinator's `needs_refinement` reports against already-trimmed items
  went unrefused. `coordinator_fit_report_json` is now initialised to `'{}'`
  ahead of the guard instead, removing the parameter-expansion default (and
  the trap) entirely.
- The stand-down classifier's own documentation now names all five causes
  it can report — `raced`, `unreachable`, `pre-claimed`, `untraceable` and
  `fabricated` — rather than describing a "three-way distinction" and
  reasoning about chaining for only `unreachable`/`pre-claimed`
  (TD-PPagop-26082313). `agent-cycle.sh`'s own comment above the
  `chain_eligible` test, and requirement 17a's and requirement 39's
  accounts in `docs/IMPLEMENTATION-PIPELINE-SPEC.md`, now give
  `untraceable` and `fabricated` their own reason for never chaining: both
  are the Script's own construction-time checks refusing to hand a
  candidate on, with no peer's claim or absence involved either way, so a
  fresh cycle would spend its chain budget re-composing the same broken
  work order rather than routing around anyone. The `stand-down` event
  itself now carries `trace_faults`/`fab_faults`, when non-zero, the same
  way `claim_skips` already is, so an `untraceable` or `fabricated`
  stand-down's own fault count is visible without cross-referencing
  `claim-skipped` lines. No change to which causes chain — only `raced`
  does, as before.
- A `human-visibility` violation logged as "could not read the pull
  request's reviews — skipping the idle-nudge check" no longer survives
  forever once the underlying read starts working again (requirement 38e).
  `_handoff_pr_approved`'s own reviews-read failure, inside the idle-nudge
  check alone, previously fell through as an unrecognised warning shape —
  cleared, in the log-union reduction, by any unrelated success for the same
  pull request, and, in `scripts/gather-human-visibility-hygiene.sh`'s live
  re-check, kept indefinitely with no live signal of its own to test. It now
  has its own class in both: the log-union reduction only clears it on a
  later nudge, and the live re-check drops it only once a fresh
  `_handoff_pr_approved` call — the same REST read that failed, not the
  unrelated GraphQL `gh pr view` this script already re-checks with —
  succeeds in its own right.
- A voided `review-<date>-R-NN` project-review ref now retires instead of
  sitting in the void extract for ever (TD-PPagop-26082309). Requirement
  34n's only actioned signal for that shape was `review-merged`, which needs
  a merged pull request *naming* the ref — and such a ref is voided precisely
  when a stage finds the work already done, so no Implementer ran and no
  merged pull request ever named it: the signal was defined for exactly the
  population that never gets voided. On 2026-08-23 the only four entries in
  the whole 135-entry extract past `void_retire_after_days` were of this one
  shape. A second signal, `review-superseded`, now reaches them: a ref whose
  review folder is no longer the repository's current one. Retiring it costs
  nothing, because `scripts/gather-project-review.sh` (and the Co-Ordinator's
  own live read) only ever reads the latest folder, so a recommendation from
  a superseded one is never offered again by anything — the same reasoning
  `void_config_actioned`'s `source-dropped` rule already rests on. That
  script gains a `--current-date` mode reporting the current folder's own
  date, called once per repository already walked for review-shaped void
  residue, so a repository carrying none pays nothing;
  `void_review_plan_actioned` (`lib/void-liveness.sh`) reads it back as a
  fourth stdin input.
  A read that fails decides nothing rather than retiring — including the case
  where the script's own listing succeeds but `lib/report-directory.sh`'s
  second call over the same path does not, which the library degrades to the
  same silence an empty listing produces. Requirement 34n's retirements are
  facts nothing clears, so that distinction is what keeps a rate limit from
  minting a `review-superseded` no later cycle could take back.
- A Reviewer round that raised an open question against a repository where
  the `open-question` label could not be projected no longer kills the
  cycle before the Approver ever runs (agent-ops#889). `landing_open_
  question_label_project` (`lib/landing.sh`) documents exit 1 for its own
  `unrecorded` and `failed` words as ordinary outcomes, but `agent-cycle.sh`
  assigned its output unguarded under `set -euo pipefail`, so that exit
  status ended the cycle at requirement 8f — six fleet cycles hit this for
  real, each stranding a green, ready pull request with no Approver review
  and no landing arming. Both call sites now guard the assignment with
  `|| true`, so a projection failure costs only the landing gate's
  label-based hold, never the round itself.
- The landing audit record's adjudication history (`approver.history`,
  requirement 8x) now carries every `approver-verdict` event a pull request
  received, including a peer node's refusal (TD-PPagop-26082308).
  `landing_approver_adjudication_history` (`lib/landing.sh`) previously read
  `$log_file` alone on the round that first approves a pull request and
  `$union_log` alone on a 2.1e landing-retry re-arm — never both — so a
  refuse streak whose earlier rounds ran on a peer node left those refusals
  out of a first-approval round's own history. It now reads the
  deduplicated union of both on either round.
- `labels_catalogue`'s (`lib/labels.sh`) `obsolete` and `open-question`
  entries carried 148-character descriptions against GitHub's 100-character
  limit on a label's `description` field (issue #888), so the create call
  was refused outright and `labels_ensure` reported `failed` for both, on
  every cycle, in every repository, indefinitely — neither label could ever
  be created by the pipeline. Both descriptions are now within the limit;
  `test/labels.test.sh` asserts every role's catalogue descriptions stay
  under it, reading `labels_catalogue`'s own output rather than a fixture
  list, so a future entry that regresses past the limit is caught the same
  way.
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
- The Enabler's `issue-closed` eligibility (requirement 35a) no longer strands
  a human's close when a `needs-refinement` re-flag lands between the raise
  and the next Enabler pass (TD-PPagop-26082901). The reason was granted only
  when the item's latest escalation was raised after its latest block, so a
  fresh re-flag — cheap and frequent (agent-ops#683) — moved the block past
  the escalation and left the close unable to satisfy either `issue-closed`
  (keyed on the raise) or `threshold` (requirement 36b's thrash guard refuses
  a second refinement without a human touch); the only exit was a second
  escalation asking the human to say again what they had already said (#849
  → #905, #784 → #906, #813 → #910). `ENABLER_ELIGIBLE_JQ`
  (`lib/cycle-state.sh`) now also grants `issue-closed` when the current block
  is a `needs-refinement` re-flag raised after the escalation and no
  `item-refined` event has landed since — the re-flag disputes the same,
  unchanged specification the escalation was about, so the human's close
  answers it too. The exemption still only grants an *examination*, not an
  unblock: `prompts/enabler.md` already has the engagement verify the closed
  issue's claim against reality either way.
- Dequeue diagnosis on a fenced node could not read a failed job's log
  (agent-ops#1091): `gh run view --log-failed` and the per-job
  `.../actions/jobs/<job-id>/logs` route both resolve to
  `productionresultssa*.blob.core.windows.net`, which the D24 egress fence
  blocks by design, leaving the Implementer's merge-group diagnosis (and the
  Enabler's own log reads) to infer a cause rather than read it. Both
  `prompts/implementer.md` and `prompts/enabler.md` now read the run-level
  endpoint instead — `gh api repos/<owner>/<repo>/actions/runs/<run-id>/logs`,
  which stays on `api.github.com` and returns every job's log as one zip —
  and name a `Forbidden` naming `blob.core.windows.net` as the fence itself
  rather than a credentials problem. `deploy/docker/egress-allowlist.txt`'s
  "Not here, deliberately" paragraph now records the Azure Blob hosts as a
  deliberate omission with this endpoint as the supported route, so the gap
  is not re-proposed as a widening of the allowlist.
- A crash-loop escalation retried after a failed filing could file a false
  alarm the instant the fault it described had already cleared
  (agent-ops#1074): the 2026-08-29/30 Ockham outage filed agent-ops#1070 six
  minutes after the network recovered, in the very cycle whose own
  Co-Ordinator attempt then succeeded — the retry's verdict was computed
  before that attempt ran and so could never see the recovery it was about
  to produce. `crash_loop_escalate_or_defer` (lib/enabler.sh) now files a
  verdict never before attempted immediately, exactly as before, but queues
  a deferred retry (or a fresh attempt that itself failed to file) for
  `crash_loop_refile_pending` to re-verify from `cleanup()`, once every
  stage the cycle might run — Co-Ordinator included — has had its chance;
  a run a fresh union-log read then shows broken is dropped
  (`crash-loop-dropped`) rather than filed. `crash_loop_retire_resolved`
  closes the other half of the same gap, retiring an already-open
  Co-Ordinator-class escalation once its run has broken, with a comment
  naming the success that cleared it. Step 1b now runs `crash_loop_retire_
  resolved` *before* either filing call, and the function itself now also
  checks for a same-detail run already active anywhere in the union log
  regardless of its own `first_ts` — both close a collision where a
  resolved run's still-open issue gets rebound (via `create_escalation_
  issue`'s live open-issue dedup) to a new same-detail run and is then
  retired out from under it, closing the alarm for that run's entire
  remaining life.
- A node's freshness is now a fact about what it has **published**, never
  about its own clock (agent-ops#602): on 2026-08-08 both laptop nodes
  reported themselves fresh for four days while `state-sync.sh push` was
  failing the whole time, because the dashboard's self row was built from
  `date` and a hardcoded `false` rather than read back from anywhere.
  `state-sync.sh fetch` now reads back this node's own branch — already
  brought down by the same fetch that materialises every peer's — into a
  local cache, `.state-sync-published.json`; `lib/fleet.sh`'s new
  `fleet_publication_status` applies the identical verdict (fresh/stale/
  unknown) to that cache for self and to a peer's `heartbeat.json` alike, so
  the two can never disagree. The threshold is now `node_stale_after_minutes`
  (default 30) rather than a literal `1800` buried in the dashboard script.
  `scripts/doctor.sh` gains a matching check: `warn` when this node has never
  confirmed a publication yet (not itself a fault), `fail` once a
  once-confirmed publication has gone stale — distinct from a genuinely idle
  node, which still publishes a heartbeat on its own schedule regardless of
  whether it has run a cycle.

### Changed

- The implementation pipeline claims, resolves and defers tech debt as issues
  rather than as register files (agent-ops#879; D15 as revised #869, on top of
  the issue-backed band #875). `lib/candidate-select.sh`'s `claim_branch_for`
  drops its tech-debt special case: a tech-debt selection's item is a bare
  issue number like any `issues` one, so it claims and names its branch
  `agent/<item-ref>` the same way, and `tech_debt_branch_prefix` is deprecated
  — read only so `lib/claim.sh` and the gatherer/sweep scripts still recognise
  a repository's pre-migration human tech-debt-claim branch, or a `td/<ID>`
  minted before this change, as not their own agent's fresh claim. Resolving a
  debt item now means a real closing keyword plus a fenced `td-record` block
  (`issue`, `title`, `filed`, `summary`, `resolution`) in the pull request
  body, which the squash merge writes into `main`'s own immutable history —
  the permanent record that replaces the register file's line in it. Deferring
  a shortcut noticed mid-implementation means a dedup-searched,
  `pw::type:tech-debt`-labelled issue plus a `Defers: #n` line in the same
  body, never a closing keyword; the Reviewer verifies each `Defers:` link
  exists and still carries the label (requirement 30e). `prompts/implementer.md`,
  `prompts/reviewer.md` and requirements 17a, 23, 24b, 25, 25a, 30d and 30e
  move with it. Neither the `td/` namespace nor the frozen `tech-debt/`
  directory is removed here; both retire with the register machinery
  (agent-ops#882).
- The landing audit record's `head_sha` field is renamed `review_commit_sha`
  (requirement 8x, TD-PPagop-26082312): the value is unchanged — still the
  Approver's standing review's own `commit_id` — but the old name read as the
  commit that landed, which it is not on every path. The record's
  `human-veto` gate entry is now derived from `_handoff_blocking_reviewers`'s
  own return (empty on every arm) rather than a hardcoded `"clear"` literal,
  and carries that list as a new `blocking_reviewers` field beside its
  verdict, the same way the `protected_path` field already names the paths it
  examined. The observable verdict does not change on any arm.
- The repository-review pipeline now files the debt it surfaces as
  `pw::type:tech-debt`-labelled GitHub issues in the repository under review,
  rather than as `tech-debt/*.md` register files committed inside the review
  pull request (agent-ops#876; D15 as revised 2026-08-28). Each issue is
  dedup-searched before it is filed (`gh issue list --label
  pw::type:tech-debt --search …`) and, where it mirrors a recommendation's
  whole *Intended end state*, names that recommendation's `R-NN` and the
  review folder in its body — the cross-reference the Co-Ordinator's
  `project-review` dedup reads (requirement 16). The review pull request
  lists every issue filed under a `Defers:` section instead of carrying a
  register diff, so it adds no `tech-debt/` file at all; the only register
  edit it may still carry is an existing item's frontmatter flip where the
  review found that item already resolved. The debt therefore reaches the
  implementation pipeline's `issues` source as soon as it is filed, instead
  of waiting for the review pull request to merge, and the `td/<id>`
  reservation bookkeeping the review used to do disappears with it.
  `docs/REVIEW-PIPELINE-SPEC.md` R12/R12a/R13 and acceptance checks 5, 7 and
  8, `prompts/project-reviewer.md` and the vendored `project-review` skill
  all move together.
- Seven timings sized against a once-an-hour cycle now derive from
  `schedule.cycle_interval_minutes` instead (requirement 1d, agent-ops#591):
  `claim_ttl_hours`, `abandoned_draft_after_hours`, `disable_default_ttl` and
  `none_selected_recheck_hours` re-express their old "a few cycles" intent
  against the actual cadence (accounting for `schedule.cycle_hours` and
  `excluded_minutes` too, since either can widen the real gap between cycles
  past the bare interval), and `cycles_retained`,
  `state_local_cycles_retained` and `state_local_streams_retained` hold their
  wall-clock retention window constant as that cadence moves rather than
  quietly shrinking it. The four thresholds take the *worst-case* gap between
  firings, since each has to outlast a quiet stretch; the three retention
  counts take the *mean* gap, since a cycle directory is written per firing —
  a distinction that matters only where `cycle_hours` or `excluded_minutes`
  restrict the schedule, and there it is the difference between a `9-17`,
  15-minute installation keeping the 300 cycle directories its ~8.3-day
  window means and keeping 14. `crash_loop_after`'s intent is a literal count of
  consecutive failures, not a span of history, so it is unaffected and keeps
  its plain default. None of the seven carries a schema `default` any more —
  absent, each is derived; a configured value is a floor under the
  derivation, never a ceiling, the same shape `lock_stale_after` already
  uses. `claim_ttl_hours` and `abandoned_draft_after_hours` carry a second
  floor beyond the cadence one (TD-PPagop-26082829): each also bounds a
  cycle's own worst-case *runtime*, not only the gap between cycle starts —
  `do_gc` sweeps a claim (and its still-untouched, PR-less branch) past
  `claim_ttl_hours` regardless of whether the cycle holding it is still
  running, and `gather-abandoned-drafts.sh`'s own candidacy race presumes
  that claim has not already been swept — so a fast cadence can raise either
  key's cadence term but can no longer derive either below requirement 4f's
  own stage-backstop quantity (`stage_budget_lock_seconds`, the one
  `lock_stale_after` already derives). On Poetic's own 15-minute
  installation the cadence term alone would put `claim_ttl_hours` at 2 h and
  `abandoned_draft_after_hours` at 1 h — both well under a cycle's own
  worst-case runtime — so the runtime floor is what actually governs there:
  both derive to 7 h, higher than either key's original flat default (6 h,
  4 h), which is the fix working as intended rather than a regression.
  `cycles_retained` grows from 200 to 800 on the same installation to hold
  the same ~8.3 days of mirror history it always meant to, and
  `state_local_cycles_retained`/`state_local_streams_retained` grow
  1000 → 4000 and 50 → 200 the same way (TD-PPagop-26082830) — the last of
  which is the one whose retained volume is worth an order-of-magnitude
  estimate rather than only a ratio: roughly low hundreds of megabytes on a
  busy repository, comfortably inside `min_free_workspace_bytes`'s 2 GiB
  pre-clone floor.
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
- `config.schema.json`'s entries for `cycles_retained`,
  `state_local_cycles_retained` and `state_local_streams_retained` now say
  that a configured value below requirement 1d's derivation is inert, and
  why: the floor preserves the span of history the base count was sized for
  at this installation's own cadence, disk is bounded separately by
  `min_free_workspace_bytes` (requirement 2.0c) and its own derivation
  (#904, still open), and the `STATE_SYNC_*` overrides two of the three keys
  have are test-only, never an operator lever — `cycles_retained` has no
  such override, so a configured value is its only lever (owner decision,
  escalation #918: floor-never-ceiling stands for the count keys too; no
  behaviour change, requirement 1d's contract paragraph unchanged; #901).
