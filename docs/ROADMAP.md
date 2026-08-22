# Pullwright — Product Roadmap

*The productisation of the Autonomous Implementation Pipeline.*

> **Nature of this document.** This is a planning document, not an as-built
> specification: it describes intent, not the system that exists. The
> as-built specs in this directory remain the authority on what *is*; when a
> roadmap item lands, the code change and its spec edit travel in the same
> pull request as usual, and the relevant phase checklist here is ticked in
> that PR or a follow-up. Revise this document whenever a decision below is
> overtaken by evidence — a roadmap that no longer matches intent is a bug in
> the roadmap.

## Vision

The Autonomous Implementation Pipeline becomes **Pullwright**
([github.com/Pullwright](https://github.com/Pullwright)) — a monetised
product that any software team can point at their repositories: an
unattended fleet that selects, implements, and reviews pending work and
raises mergeable pull requests, with a human merge as the default gate —
and, where an installation deliberately opts in, a trust ladder that
retires even that (D18).
Poetic-Poems stops being the pipeline's home and becomes its first
customer.

## Settled decisions

Decided July 2026 unless a row says otherwise; these shape every phase
below. Reopen them only deliberately, by editing this table in a PR that
says why.

| # | Decision | Choice |
|---|---|---|
| D1 | First phase | **Untether first** — generalise the pipeline out of Poetic-Poems before building platform or launch features. |
| D2 | Delivery model | **Deliberately open** (self-hosted product vs hosted SaaS vs both) until the explicit decision gate at Phase 4. Until then, every phase does only work that serves both paths. |
| D3 | Target customers | Solo developers and small teams; open-source maintainers; mid-size engineering organisations. Not (yet) agencies running many client repos. |
| D4 | Model-usage billing | **BYO API key is the primary, first-class path** — Anthropic first (including Claude via Bedrock and Vertex), and likewise for every other supported provider (D12). Claude subscription OAuth is retained as a supported self-hosted configuration, documented with its constraints (interactive login per node; own-use only). Usage resale is deferred until a hosted SaaS exists and has traction, but metering hooks are designed in from Phase 1 so resale needs no re-architecture. |
| D5 | Licensing | **Source-available** (BSL/FSL-family): code public and auditable, free to self-host for your own use, no competing hosted offering. The exact licence is an open question with a Phase 1 decide-by gate. |
| D6 | Technology | **Strangler rewrite.** The proven bash cycle engine is retained. All *new* product surface — control plane, config APIs, packaging — is written in a proper language; engine pieces migrate across only when a change touches them anyway. |
| D7 | Product scope | **The whole suite**: the implementation pipeline, the **repository-review** pipeline, and the dashboard. They compound — reviews feed the pipeline the work it does, and the dashboard is the product's face. The name the review pipeline carries today, *weekly project review*, is wrong twice over, and neither word survives productisation. **Weekly** is configuration, not identity: the cadence is a cron tick plus `project_review.defaults.min_days_between_reviews`, set per installation and overridable per repository, so a nightly or fortnightly installation is as ordinary as Poetic's weekly one — the Phase 1 sweep retires the word from both pipelines. **Project** overstates the scope: a run reviews *one repository*, each entry in `project_review.repos` on its own, with its own clone, branch, report set and pull request; nothing reviews a project — several repositories that deliver one thing — as a single subject. Reviewing one as a single subject is a wanted feature, deliberately deferred (Phase 3). Until then the product's term is **repository review** — and a review is instructed and contextualised per repository (Phase 1), because what a repository is for, which of its oddities are deliberate, and what is out of scope for it are not things a reviewer can reliably infer from the clone alone. |
| D8 | Repository shape | **Split**: a new product repository in the Pullwright organisation (D13) holds the pipeline; agent-ops shrinks to Poetic's consumer configuration and deployment — the reference installation and customer zero. |
| D9 | Build mode | **Mixed.** Architectural moves happen in interactive sessions; everything decomposable is authored as agent-workable items that the fleet works down itself. The roadmap doubles as dogfooding evidence. |
| D10 | Pacing | **Phase-gated, no dates.** Progress is gates passed, not calendar time. |
| D11 | Go-to-market | **A parallel lightweight workstream from Phase 1**: the name is chosen early (it gates the repo split), design partners are recruited during untethering, and pricing is tested before anything launches. |
| D12 | Model providers | **Not limited to the Claude family.** Customers choose the model for each actor from any supported provider. Claude is the first-supported and reference provider; how non-Claude providers are executed (the substrate question) is parked in Open questions with a decide-by gate. |
| D13 | Product name | **Pullwright.** Decided July 2026, ahead of its Phase 1 gate; the GitHub organisation ([github.com/Pullwright](https://github.com/Pullwright)) is created and the namespace secured. |
| D14 | Efficiency | **Per-container efficiency is an explicit product goal from the start.** Decided August 2026. Every container is held to budgets for CPU load, memory footprint, disk usage, and bandwidth, alongside — never at the expense of — quality and speed of delivery. Where these pull against each other, the trade-off is a calculated decision recorded in the change that makes it, never an accident discovered on a bill. Kubernetes requests and limits (Phase 2) become one enforcement mechanism, but the budgets exist whatever the control plane. |
| D15 | Tech-debt management | **The tech-debt management framework is part of the offering.** Decided August 2026. The per-item register proven across the Poetic repositories — append-only item files, scope-coded ID grammar, `td/<id>` claim locking, allocation/lookup/validation tooling, CI enforcement, drift-synced copies in consumer repositories — ships with the suite, on the same compounding logic as D7: the register is already one of the sources the pipeline works down. Canonical tooling today lives in `Poetic-Poems/poetic`; productisation moves it into the product repository, and D20 governs how it then reaches a repository — delivered by the product, not copied into it. |
| D16 | Infrastructure as code | **The configuration of the pipeline and of the orchestration layer / control plane is infrastructure-as-code.** Decided August 2026. Everything that configures an installation — `config.json`, compose files and Kubernetes manifests, schedules, secrets wiring, per-node deployment shape — is declared in version-controlled code and reaches a running installation only by applying a versioned change, never by hand-editing a live node. Today compose- and env-level fixes are walked out to each node by hand, and the drift detection of #131 exists to catch exactly the divergence that this rule makes structurally impossible. Phase 2's deployment-as-artefact and Kubernetes items are the first enforcement, and the control-plane skeleton (D6) grows up under the same rule. |
| D17 | Merge queues | **Supported and recommended where available; never required.** Decided August 2026. A GitHub merge queue serialises landings and tests every candidate merged with the latest `main`, retiring the behind-but-green rework class that strict up-to-date rules otherwise create — Poetic-Poems adopts queues on its own repositories (tracked by #377). The product cannot mandate them: GitHub offers merge queues only on organisation-owned repositories — public on any plan, private only on Enterprise Cloud — and never on personal accounts, where D3's solo developers live. The pipeline therefore stays fully functional without a queue and becomes queue-aware where one exists: landings are asynchronous, a pull request can be `queued` or silently dequeued, and a push to a queued branch evicts it. Under a queue the merge act is enqueueing ("Merge when ready"). Below `agent-merges-routine` on D18's ladder that act is the human's, and the product never enqueues a pull request, exactly as it never merges one; at or above it, enqueueing is the Script's landing step, performed only after every D18 gate has passed. |
| D18 | Merge autonomy | **An opt-in trust ladder; the default is the human gate.** Decided August 2026 (investigation: `docs/reviews/2026-08-14-autonomy-investigation.md`; rollout umbrella #402). `merge_autonomy` — `human` → `agent-approves` → `agent-merges-routine` → `agent-merges-all` — sets, per installation and per repository, who approves and who lands a pull request. At every level above `human`, approval and landing are acts of the Script under a non-author forge identity (a GitHub App, "Pullwright Approver"), performed only after every deterministic gate and an independent Approver verdict pass; no model ever holds approve or merge rights, and a human `CHANGES_REQUESTED` blocks landing at every level. Where a merge queue exists, landing is enqueueing (amending D17); otherwise it is GitHub auto-merge. Landings are capped by `merge_budget_per_day`, which replaces the human merge rate as the spend governor. The product default is `human`, unchanged from today — nothing a customer has not opted into ever lands a pull request. Poetic-Poems, customer zero, climbs the whole ladder. |
| D19 | Rendered-preview checking | **A tiered preview check, with the browser in a shared renderer — never in the agent images.** Decided August 2026. Reviewing a web change means seeing the page a user will see, and the pipeline today stops two tiers short: it verifies a preview *deployed* (answers 2xx on `/`), never what it *serves*, never what it *renders*. On poetic-fiddle#319 the CSP defect was caught only by a human clicking the deployed preview; on agent-ops#424 a Reviewer tried to stage a browser onto its node by hand, failed for want of root, and handed the eyeballing back to the human — the nodes already think to check, and are blocked by tooling, not by intent or credentials. The check becomes a three-tier ladder, each tier priced and entered only when the diff warrants it: **deployed** — the preview exists and answers (today's `preview-deploy.sh`); **served** — fetch the routes the diff touches and read the HTML and response headers statically through the deployment-protection bypass, no browser required (Content-Security-Policy headers are the proven catch); **rendered** — a real browser executes the page and returns screenshots, console output, and the resulting DOM as artefacts the reviewing stage reads. How a preview is *obtained* sits behind a per-repo `preview` block in config — an adapter interface with Vercel as the proven first provider, others by demand — and a repository with no preview deployment, or one whose owner withholds its build system's credentials, declares a **local fallback**: build and serve the pull-request head from commands stated in config, then check that. The browser itself ships in one separately-deployable renderer container per installation, serving every node on demand — the dashboard-split precedent, honouring D14 — so agent images stay browser-free, idle nodes pay nothing for a capability they use occasionally, and the preview credentials live server-side in the renderer rather than passing through an agent's transcript. A rendered page is untrusted input: its content reaches the reviewing model as data, never as instructions. |
| D20 | Tooling delivery | **The tooling a repository is maintained by belongs to the product, not to the repository.** Decided August 2026. Every repository-maintenance and development script the pipeline relies on — the tech-debt register's allocator, resolver, validator and CI guards (D15) first among them, and the lint, format, and drift-check helpers of the same class behind them — is *vendored* today: one canonical copy in `Poetic-Poems/poetic`, byte-identical copies walked by hand into agent-ops, poetic-fiddle and the ArtistOS ports, each policed by its own weekly workflow diffing a hard-coded file list. The copying is the defect, not the copies, and every failure mode it has is now on the record: an upstream change to `td-check.pl` (poetic#180, 2026-08-14) left two consumers validating their registers with the old checker for as long as nobody re-copied it (#485); two scripts added the day before (poetic#166) reached no consumer at all, because a file that was never copied is absent from every hard-coded list, which is how #346 and #350 came to mint the same ID — and the fix for *that* (a published manifest, poetic#188/#191) makes the copying mechanism honest without retiring it; and each consumer's adoption is then its own tracked, human-shepherded work item (#468, poetic-fiddle#326). None of it survives contact with D3's customers, who cannot be asked to vendor the product's scripts, hand-sync them on every upstream fix, and carry a drift check per repository — that is the customer-zero rule failing in advance. In the end state a repository declares which maintenance capabilities it wants and Pullwright supplies the executables; the repository holds only its own data — its register items, its configuration — a fix reaches every installation by upgrading the product, and drift stops being a category of failure rather than a category of check. *How* they are delivered is an open question with a Phase 2 gate; *that* they are delivered rather than copied is not. |
| D21 | Productivity analytics | **The product measures the two rates it exists to raise — delivered work per elapsed hour, and delivered work per token — and no figure it publishes lacks a lever.** Decided August 2026. An installation's levers are few and enumerable: which model runs each actor (D12), how many nodes run, where the caps sit (`max_open_agent_prs`, `merge_budget_per_day`), which repositories and work-source bands the fleet is pointed at, how far up D18's ladder it has climbed, and which defect to fix next. Choosing among them needs three **exhaustive** accounts, each carrying an invariant that makes it trustworthy rather than merely plausible: **time** — every node-second in a window falls into exactly one state (producing, overhead, externally blocked, idle with demand, idle without demand, down), and the states sum to node-count × window; **spend** — every token and dollar is attributed either to one work item's fate or to a named overhead class, and those sum to the roll-up total; **flow** — every work item carries a lifecycle from first sighting to terminal fate, and items entering equals items leaving plus work in progress. A second, a token or an item that cannot be classified lands in an explicit `unaccounted` bucket and is never dropped: an account that silently loses its remainder can be glanced at but not reasoned from. Analytics is a **separate surface** from operations — "is it broken now" and "am I getting value, and what should I change" are different questions, with different windows, audiences and refresh rates, and today's dashboard mixes them — and it needs history the transcripts do not have: every rate the dashboard states is bounded by `log_retained_bytes` and the live log generation, which is why the Co-Ordinator verdict-quality panel can only honestly claim "over the log we still have". The analytics records are small, structured and append-only, so they are retained on their own schedule rather than inheriting the rotation that exists to bound 40 KB transcripts. Their production is priced under D14 like everything else: agent containers emit facts, the analytics container does the arithmetic. |
| D22 | Evidence-driven model selection | **Models are graded on what their runs produced, not on what they did; comparisons are stratified or not made; and an installation can run controlled trials to get comparable evidence.** Decided August 2026. Per-actor model choice (D12) is the largest single lever on both of D21's rates, and it is chosen today by reputation and revised by anecdote. Grading on activity — how often each model ran, how many turns it took, what it cost — describes the fleet without informing the choice; what informs the choice is outcome: whether the Implementer's pull request landed unchanged, whether it needed a second pass, whether the Reviewer's findings held up, whether the Co-Ordinator's pick survived corroboration, and at what cost and latency per landed item. Two disciplines keep such a comparison honest. **Stratify or abstain:** models are assigned by tier and the tiers see systematically different work, so an unstratified ranking compares hard items against easy ones and will confidently recommend the wrong model; every comparison states its strata and its sample size, and shows "insufficient evidence" rather than a spurious ordering below a stated minimum. **Trial deliberately:** observational data alone cannot separate a model from the work it happened to be given, so the product supports an opt-in **model trial** — a candidate takes a configured share of one actor's eligible work for a bounded period or item count, the arm is recorded on the item, and the comparison is then between arms rather than between eras. A trial is opt-in per installation, capped by a stated cost budget, abortable at any moment, and never assigned to the critical tier unless that is separately opted into. What it yields is a recommendation with an effect size, a sample and a confidence statement — or no recommendation at all — never a leaderboard. |
| D23 | Rework and escape accounting | **Rework is the pipeline's only honest quality signal and its largest recoverable waste, so it is counted by class, attributed to the stage that caused it, and priced — and never driven to zero.** Decided August 2026. A repetition spends both of D21's rates at once and produces nothing that did not already exist, which makes it the first place to look for either; it is also the only quality measure the product can make without asserting one, since code quality cannot be observed directly but a second attempt is a judgement already made — some actor, check or human found the first insufficient and said so. It is counted **by class**, because a single rework rate names no lever: review round-trips, human change requests after an agent had already flipped a pull request to ready, check failures on a raised pull request, merge conflicts, abandoned drafts resumed by a later cycle, re-runs of killed or crash-looped stages, work duplicated by a claim race, refinement bounce-backs, and post-merge reverts or follow-up fixes. Each has a detector already emitting today or a gap where one belongs, and each points at a different lever — a model, a prompt, a cap, the fleet size, or a product defect. It is attributed **to cause, not to performer**: a second Implementer pass spends Implementer tokens and may be the Refiner's fault for under-specifying, the Co-Ordinator's for picking something unworkable, the Reviewer's for passing a defect the human then caught, or the Implementer's own, and an account that skips this reports the Implementer as expensive when the finding is that items arrive under-specified. Cause is recorded from the detector that fired and the evidence it fired on, never inferred by a model after the fact. And it is **never a target of zero**: a Reviewer catching a defect is the system working, not failing. Detection has a cost ladder — agent review, then the human gate, then a post-merge revert — that rises steeply at each rung, so the goal is moving detection *earlier*, and a panel reading "rework bad" would reward a Reviewer that waves work through, which is the most expensive failure the ladder has. The headline measures are therefore **escape rate per detection stage** — what share of defects got past this rung to the dearer one above it — alongside first-pass yield and rework's share of tokens and of elapsed time. One class is called out separately because it prices something other than a model: a merge conflict is `main` moving under a pull request that waited, so it measures landing latency, and it is retired by D17's queues and D18's ladder rather than by any change of model. |

## End state

What the finished product looks like, whichever delivery model Phase 4
chooses:

- Fully untethered from Poetic-Poems, which consumes it as an external tool
  like any other customer.
- Deployed via an orchestration tool (Kubernetes first), with autoscaling
  and scale-to-zero.
- Zero manual per-container steps: provisioning, credentials, and retirement
  are all non-interactive.
- Non-intrusive updates: a rollout never destroys in-progress work.
- Frugal by design: every container runs within stated CPU, memory, disk,
  and bandwidth budgets (D14), and components a node does not need — the
  dashboard first among them — are simply not deployed there.
- Deeply customisable: per-actor model selection (Co-Ordinator, Implementer
  at both tiers, Reviewer at both tiers, Enabler) from any supported
  provider — not only the Claude family — plus schedules, work sources,
  prompts, and repo conventions.
- Reviews scoped and instructed per repository (D7): the review pipeline
  reviews a repository, at whatever cadence the installation sets — neither
  "weekly" nor "project" is part of its name — and applies that repository's
  own review instructions and context, so an adopting repository's standards,
  deliberate conventions and out-of-scope areas shape its reviews without
  anyone forking the skill. A project spanning several repositories is
  reviewed as one subject, with the findings that only exist across a
  boundary routed to the repository that must act on them.
- Configured as code (D16): an installation's entire configuration —
  pipeline, orchestration layer, control plane — is versioned declaration
  applied by tooling; nothing is hand-mutated on a running node.
- Tech-debt management built in (D15): the per-item register, its tooling
  and CI guards ship with the product, race-safe for concurrent human and
  agent writers, and the pipeline works registers down as an ordinary
  source.
- Maintenance tooling delivered, never vendored (D20): a repository under
  Pullwright's care declares the capabilities it wants and receives the
  executables from the product. It holds its own data — register items,
  configuration — and none of the product's scripts, so a fix reaches every
  repository in every installation by upgrading the product, and no
  repository carries a drift check for tooling it does not own.
- Rendered previews verified (D19): every web-facing change is checked at
  the tier it needs — deployed, served, or fully rendered in a browser —
  with the browser living in one shared renderer per installation, never
  in the agent images, and a local build-and-serve fallback for
  repositories with no preview deployment at all.
- Productivity measured rather than asserted (D21): an installation can see,
  over any window, where its wall-clock went, where its tokens went, and what
  each work item did between first sighting and terminal fate — each as an
  account that adds up — and the product names the constraint currently
  limiting throughput instead of leaving an operator to infer it from a wall
  of counters.
- Models chosen on evidence (D22): every actor's model is backed by outcome
  data over comparable work, and a customer can trial a candidate against the
  incumbent on a share of real items rather than switching on reputation and
  hoping.
- Rework counted, attributed and priced (D23): an installation can see how
  much of its elapsed time and its token spend went into doing work a second
  time, which class of repetition it was, which stage caused it as against
  which stage performed it, and how far up the detection cost ladder each
  defect got before something caught it.
- Several supported hosting options.
- Source-available, under a marketable product name.

## Principles

1. **Both-paths rule.** Until the Phase 4 delivery gate, no work may assume
   self-hosted or SaaS exclusively. Anything that would (e.g. building
   usage resale, which only makes sense hosted) waits for the gate.
2. **Strangler rule.** No big-bang rewrite, ever. New surface in the new
   language; the bash engine earns its retirement one touched piece at a
   time.
3. **Dogfood rule.** Decomposable roadmap work is authored as
   agent-workable GitHub issues, labelled `roadmap`, in the repository the
   work belongs to — and the fleet implements them through its ordinary
   `issues` source. Items marked *[fleet]* below are intended for this path;
   *[interactive]* items are architectural moves done in sessions.
4. **Customer-zero rule.** Poetic's installation is never special. If
   Poetic needs anything that is not configuration, the product is not
   generic enough — that is a product bug, not a Poetic quirk.
5. **Specs stay as-built.** The existing spec discipline continues
   unchanged through every phase; the roadmap never substitutes for it.
6. **Calculated-trade-off rule (D14).** Resource cost — CPU, memory, disk,
   bandwidth — is a tracked property of every container, not an emergent
   one. Work may spend resources to buy quality or speed of delivery, but
   the trade is made knowingly and stated in the change that makes it.
7. **Lever rule (D21).** Every figure the product publishes names the
   decision it informs and, where the evidence supports one, the change it
   recommends and the effect that change is expected to have — otherwise it
   says "no action indicated" or "insufficient evidence" in as many words. A
   panel that is accurate, carefully bounded, honest about its window and
   still cannot tell a reader what to do differently is not finished. The
   Co-Ordinator verdict-quality panel is the worked counter-example, and it
   is superseded rather than extended.

## Phase 1 — Untether

**Goal:** the pipeline is adoptable by an arbitrary repository through
configuration alone.

**Entry:** now.

**Exit gate:** a repository outside Poetic-Poems runs the whole suite —
implementation cycle, review cycle, dashboard — from published artefacts
with no code changes; agent-ops contains no pipeline code, only Poetic's
configuration and deployment; the product repository exists in the
Pullwright organisation and carries its licence.

- [ ] Sweep the Poetic-specifics out of scripts, prompts, and config:
      hardcoded repo slugs, the owner's username, label names, branch
      conventions, and the poetic-fiddle implementation-plan source. Four are
      swept (the Enabler's assignee, the entrypoint's git identity, the
      implementation-plan path, the Co-Ordinator's repo/source table); the
      audit is done —
      [`docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md`](PHASE-1-POETIC-SPECIFICS-AUDIT.md)
      inventories what is left across `prompts/`, `lib/`, `scripts/`,
      `deploy/` and `config.schema.json`, classified, with one follow-up
      issue per hit that needs a config key or a generic default (#585,
      #586, #653–#657). *[fleet — one item per specific]*
- [x] Parameterise the operating prompts so an installation can extend or
      override them without forking the product (`prompt_overrides` in
      `config.json`, docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 4a).
      Installation-wide per stage, not yet scoped per repo — see the item
      below. *[fleet]*
- [ ] Scope prompt overrides per repository, not just per installation. The
      Co-Ordinator runs once per cycle across every configured repo together,
      so a per-repo selection prompt needs that invocation split first; the
      Implementer and Reviewer stages already run against a single known repo
      and could take a per-repo override without it. *[fleet]*
- [ ] Give a review its repository's own instructions and context (D7). A
      Reviewer-Agent is launched today with five facts — `repo`,
      `default_branch`, `review_date`, `branch`, `pr_label` — plus the
      shipped `prompts/project-reviewer.md` and the injected `project-review`
      skill, identical for every repository; everything else it knows it has
      to infer from the clone. `prompt_overrides` (requirement 4a) does not
      help: its enumeration covers the implementation pipeline's five stages,
      and `review-cycle.sh` never reads it, so the review pipeline has no
      override facility at all — per-installation or per-repository. An
      installation that wants one repository reviewed against a standard
      another does not follow, a deliberate convention left alone rather than
      re-reported at every review, or a generated or vendored directory held
      out of scope, has nowhere to say so short of forking the skill. Build
      the facility: per-repository **instructions** (how to review this
      repository — what to weigh, what to ignore, which standards apply) and
      per-repository **context** (what it is for, its domain, its
      relationships to other repositories, its consumers and deployment),
      resolved by the Script and appended to the Reviewer-Agent's runtime
      input, layered installation-wide → per-repository on the same
      resolution rule as the rest of `project_review` (requirement 342), and
      recorded in the run's record so a review's inputs are reconstructable.
      Where the text lives is an open question below, and one caution shapes
      it: anything read out of the repository under review is content that
      repository's contributors can edit, so it is trustworthy only as far as
      a pull request into that repository is — the class of concern D19
      records about rendered pages — which argues for the installation's own
      configuration holding whatever changes how strictly a review judges.
      This is the review pipeline's counterpart to the per-repo prompt-override
      item above; if one mechanism will serve both, they should land on it.
      *[fleet]*
- [x] Config schema with validation and a `doctor` command that checks an
      installation end to end — the skeleton: `config.schema.json` (every key,
      its type, its constraints, and the value the code falls back to),
      `lib/config-schema.sh`, and `scripts/doctor.sh` over config, cross-key
      rules, models, prompts, toolchain, directories and GitHub access
      (requirement 1b). *[interactive]*
- [x] Make the schema the startup gate: `agent-cycle.sh` and
      `review-cycle.sh` validate `config.json` against it before any
      individual key is read, and the two guards it wholly subsumed
      (`nice`'s range, `prompt_overrides`' shape) are retired in favour of it
      (requirement 1b, `docs/IMPLEMENTATION-PIPELINE-SPEC.md`). *[fleet]*
- [x] Make the schema the *only* source of truth rather than a third one
      beside the two prose tables: every reader takes its defaults from
      `config_defaults` (`lib/config-schema.sh`) instead of repeating a
      `// literal` of its own (#197), and the README and spec tables are
      generated from the schema's descriptions
      (`scripts/render-config-table.sh`, #198). *[fleet]*
- [x] Make schedules configuration-driven (per-pipeline cadence in config,
      not a baked crontab) — the `schedule` block, rendered by
      `deploy/docker/render-crontab.sh`. *[fleet]*
- [ ] Retire the cadence — and the false scope — from each pipeline's
      identity (D7): "hourly" and "weekly" must disappear from spec titles,
      documentation, prompts, and code, and every timing derived from the
      period today (lock staleness, retention counts, stand-down probing)
      must follow the configured value instead of assuming an hour. The
      review pipeline sheds "project" in the same sweep — it reviews a
      repository, so it is the repository-review pipeline — and the
      identifiers that say otherwise go with it: the `project_review` config
      block, the `project-review` pull-request label and work source, the
      vendored skill's own name. Each of those is a breaking change for an
      existing installation (a config key renamed, a label relabelled on live
      pull requests), so each travels with its migration note; the prose
      rename does not wait on them. The cadence is configurable and the scope
      is a repository; the product still calls itself the hourly pipeline and
      the weekly project review. *[fleet]*
- [ ] First-class non-interactive auth: Anthropic API key, Bedrock, and
      Vertex as the primary path; subscription OAuth documented as the
      supported self-hosted alternative (D4). *[interactive]*
- [x] Formalise the metering schema: per-cycle, per-stage token and cost
      accounting as a stable, documented format — `docs/METERING-SCHEMA.md`,
      the contract both pipelines and the dashboard are held to. *[fleet]*
- [x] Provider-qualified model identifiers in the config schema, so models
      from other providers can arrive later without a breaking change
      (D12). *[fleet]*
- [ ] Make the spend data say *what* the money bought, before anything is
      built on it (D21). Two defects stand between today's metering and any
      productivity figure — a third, the model dimension, is already fixed
      (issue #536): `scripts/publish-dashboard.sh`'s cost scan now reads each
      `modelUsage` entry's own `costUSD` rather than crediting a transcript's
      whole `total_cost_usd` to whichever model `keys` sorted first, and
      summing those entries reproduces `total_cost_usd` to the cent.
      **The item dimension is absent:** `cost_rows[]` is
      `{day, model, actor, usd}`, so "what did we spend on work that never
      landed" cannot be asked at all — though the scan already holds the cycle
      id it discards (`$cid`, the same string it slices `day` and `ts` out of)
      and that cycle's own record already names its repo, item, source and
      outcome. **The token dimension is recorded and never read:**
      `lib/metering.sh` writes `tokens.input`, `tokens.output`,
      `tokens.cache_creation`, `tokens.cache_read` and
      `gaps.{n,p50,p95,p99,max}` onto every `stage-end`, and neither the
      Publisher nor the page reads one of them, so the prompt-cache
      economics and the stall profile the pipeline already pays to measure are
      invisible. Carry `{repo, item, source, cycle, outcome}` on each cost
      row, and surface the token and gap series — both additive under the
      metering schema's own stability policy. *[fleet]*
- [ ] Fix the flow-and-outcome event contract now, for the reason the metering
      schema was fixed now (D21): an analytic can only ever be computed from
      what was recorded while the work happened, so every month the contract
      is deferred is a month of history no later panel can reconstruct. Extend
      `docs/METERING-SCHEMA.md`, or a sibling under the same stability policy,
      to cover two event families neither pipeline emits today. **Item
      lifecycle** — one durable record per work item, accumulating instants
      that already exist as scattered facts (`first-seen`, refinement,
      `selection`, stage starts and ends, `pr-raised`, checks green, review
      verdict, `pr-ready`, human merge, item closed); the **rework record**
      that exists nowhere (D23) — one entry per repetition, carrying its class
      (review round-trip, human change request after an agent flipped the pull
      request to ready, check failure on a raised pull request, merge
      conflict, resumed abandoned draft, re-run of a killed or crash-looped
      stage, work duplicated by a claim race, refinement bounce-back,
      post-merge revert or follow-up fix), the detector that fired and the
      evidence it fired on, and the stage the repetition is *attributed* to,
      which is frequently not the stage that performs it; and the item's
      terminal fate (`landed`, `voided`, `blocked`, `abandoned`, `superseded`,
      `open`). Recording the class and its evidence as the repetition happens
      is the whole of the difference between an account and a guess: a
      `CHANGES_REQUESTED` round and a re-run after a stage was killed both
      look like "two Implementer passes" to anything reading the transcripts
      afterwards, and they have nothing in common but the cost. Two
      scripts already compute halves of this offline and are the prototypes to
      generalise rather than duplicate: `scripts/pickup-metrics.sh` pairs
      `first-seen` with `selection` for pickup latency, and
      `scripts/mine-merge-history.sh` reports open→merge and ready→merge
      latency and the 48-hour revert-or-follow-up outcome per repository.
      **Node time state** — a transition event each time a node changes which
      of D21's six states it is in, carrying the cause, so that idleness is
      recorded with its reason at the moment it happens instead of being
      inferred afterwards from an absence of cycles. *[fleet]*
- [ ] Retain those records past the transcripts they were derived alongside
      (D21). `log.jsonl` rotates at `log_retained_bytes` and `fleet_logs`
      reads only the live generation, so every rate the dashboard states is
      bounded by a window chosen to keep transcript volume down — which is why
      the verdict-quality panel carries `window_from`/`window_to` and says so
      beneath its own figures. The lifecycle and time-state records are orders
      of magnitude smaller than the transcripts and are the only thing a trend
      or a model comparison can be computed over, so they get retention of
      their own, independent of transcript rotation — and a fleet in which
      several nodes publish the same union must not double-count them, the
      objection that made per-publish counters the wrong answer for the
      verdict panel. Where they are stored is an open question below, gated
      with Phase 2's state-store interface, which owes its caller *verify* and
      *rebuild-from-source* in any case. *[fleet]*
- [ ] Read the served preview, not merely its status (D19, the *served*
      tier): extend `scripts/preview-deploy.sh` with a fetch mode that
      returns a chosen route's response headers and HTML through the
      deployment-protection bypass without the secret ever entering the
      transcript, and point the Implementer's and Reviewer's preview steps
      at the routes the diff touches — response headers included, which is
      the class poetic-fiddle#319 proved a status probe cannot catch.
      *[fleet]*
- [ ] Move the preview check behind per-repo configuration (D19): the
      Vercel specifics — one project per secret, the bypass header, the
      poetic-fiddle mention hardcoded into two prompts — become a `preview`
      block in `config.json` (provider, URL resolution, credential shape,
      or `none`), so an adopting repository declares its own arrangement
      instead of inheriting Poetic's. *[fleet]*
- [ ] Create the product repository in the Pullwright organisation (the
      name and org exist — D13); move the suite across — both pipelines, the
      dashboard, and the review skill `.claude/skills/project-review/` that
      `review-cycle.sh` stages into each clone at runtime, which stops being
      a pinned copy of a personal authoring repo and becomes product source
      (D7, D8); reduce agent-ops to consumer config + deployment.
      *[interactive]*
- [ ] Adopt the tech-debt management framework into the product (D15): move
      the canonical register tooling out of `Poetic-Poems/poetic` into the
      product repository (the drift-synced copies consumer repositories hold
      are the interim mechanism, until D20's delivery replaces them), and
      close the known allocation gap — atomic, collision-proof ID
      reservation via the `td/<id>` ref-push lock the claiming workflow
      already uses (`Poetic-Poems/poetic` register item TD-PPpoet-26080801;
      adopted by poetic#166, agent-ops#476, and poetic-fiddle#326 — three
      separate adoptions of one fix, which is the case for D20).
      *[interactive]*
- [ ] Select and apply the source-available licence (D5). *[interactive]*

## Phase 2 — Zero-touch fleet

**Goal:** nodes are provisioned, updated, and retired with no manual steps;
updates are non-intrusive; Kubernetes is a supported target; every
container has a stated resource budget it demonstrably runs within (D14).

**Entry:** Phase 1 exit gate passed.

**Exit gate:** a new node reaches its first successful cycle with zero
interactive steps; a rollout during a cycle results in a drained, completed,
or cleanly handed-off cycle — never a killed one; the suite runs on a
Kubernetes cluster from published manifests/chart; scale-to-zero is
demonstrated (no idle compute cost between ticks); per-container CPU,
memory, disk, and bandwidth budgets are stated and the metrics export
reports actuals against them; a node whose derived local state has been
corrupted returns to publishing without intervention, demonstrated by
injecting the fault rather than by waiting for it; and a node that fails to
converge on a rollout says so without anyone going to look, demonstrated the
same way; and the time account balances — every node-second in a stated window
classified into exactly one state, the states summing to node-count × window
with any remainder shown as `unaccounted`, demonstrated across a rollout and an
induced outage rather than only over a quiet afternoon.

- [ ] Graceful drain: a shutting-down node finishes or hands off its
      in-flight cycle before exiting. The auto-update case is already
      retired — watchtower's pre-update hook defers a roll while a cycle
      holds either lock — but that only covers the roll. A drain covers
      every other way a container goes away: a manual `up -d`, `restart`,
      `down`, a host reboot, an evicted pod. *[interactive]*
- [ ] Secrets-based provisioning: tokens and API keys arrive as
      secrets/environment, never via `exec` logins into a running
      container. *[fleet]*
- [ ] Health, readiness, and liveness endpoints plus structured metrics
      export. Health has to mean *outbound* health and not merely local
      liveness: a node whose last state-sync push failed is unhealthy even
      though its cycles run, its logs look ordinary, and its own dashboard
      renders it green. The incident below is what fixes the definition —
      both laptop nodes reported themselves fresh for four days while
      publishing nothing, because every signal either of them emitted was
      one it also consumed.
      Health also has to mean *converged*: whether the node runs the version
      the installation intends, and whether whatever is meant to get it there
      is succeeding. On 2026-08-14 watchtower on poetic-vm-1 tried to create
      two replacement containers it had never stopped, hit a name collision,
      and logged `Session done Failed=2` on every poll thereafter while the
      node stayed on the previous image — through a fleet roll carrying the
      fix for an outage the other three nodes had already taken. It was
      cleared by recycling the node by hand, and would not have cleared
      otherwise: the retry repeats the operation that collides. Nothing
      raised it while it lasted. The node was healthy by every
      definition it had (cycles idle, locks clean, heartbeat current, its own
      dashboard rendering), and it surfaced only because a human ran
      `check-nodes.sh` and read the image line: `lib/image-drift.sh`
      deliberately tolerates `image_behind_grace_hours` of lag, since a roll
      waiting on a cycle in flight is normal and not an alarm. So the
      updater's verdict has to leave the updater. An update mechanism failing
      repeatedly is a reportable fact in its own right, ahead of and
      independent of the drift it eventually causes — the drift check is a
      backstop against the *symptom*, and it was never meant to be the only
      thing watching. *[fleet]*
- [ ] Self-healing derived state: every local store that is a cache of
      something else — the state-sync mirror first among them, and the
      workspace clones — is integrity-checked before use and rebuilt from
      source when the check fails, instead of being trusted because it sits
      on a volume that survives restarts.
      On 2026-08-08 an unclean shutdown truncated ~20 loose git objects to
      zero bytes in each laptop node's `.agent-ops-state` mirror. The damage
      landed on a *peer's* remote-tracking ref, so `git push` could no longer
      compute what the remote already had, and both nodes silently stopped
      publishing for four days; `git gc` stayed wedged on the same objects,
      so nothing self-healed. The mirror is wholly derived — the node's own
      branch from `state_dir`, every other branch from the remote — so
      discarding and re-initialising it costs one fetch and no information,
      which is exactly why it should happen automatically rather than by
      hand. *[fleet]*
- [ ] Per-container resource budgets (D14): measure each container's
      baseline CPU, memory, disk, and bandwidth; set budgets from the
      measurements; and surface actuals-against-budget through the metrics
      export above, so an efficiency regression is as visible as a failed
      cycle. Kubernetes requests and limits then enforce what the budgets
      state — but the budgets, and the measurement, exist on Compose too.
      *[fleet]*
- [ ] Split the dashboard into its own container, deployed only where it is
      wanted: agent containers ship raw data — metering, heartbeats, cycle
      results — and the dashboard container assembles and serves the page.
      Today the Publisher runs on every node's cron whether or not anyone
      is looking; a node without the dashboard container stops paying that
      CPU and GitHub traffic. The suite stays whole (D7) — the dashboard
      just becomes separately deployable (D14) — and the raw-data feed
      never leaves the installation's private boundary. *[interactive]*
- [ ] Account for every node-second, and name the idleness (D21). The fleet
      today can say a node is running or idle, and for a no-op tick whether it
      stood down or found the lock held (`noop_ticks.{standdown,skipped}`); it
      cannot say why a node that was idle stayed idle, which is the
      distinction "should I run more nodes, or fix something?" turns on.
      Classify each node-second into exactly one of: **producing** — a stage
      executing against a claimed item; **overhead** — cloning, gathering work
      sources, pushing, publishing, state-sync: busy, but not the work the
      customer asked for; **externally blocked** — usage-limit stand-down,
      forge rate limit, provider outage, operator disable, each already
      distinguishable from `limit-hit`, `disabled` and the `github_min_*`
      budget guards; **idle with demand** — eligible unclaimed work existed
      and this node did nothing, split by cause, because each cause has a
      different fix: waiting for the next cron firing (fixed by the
      event-driven-dispatch item below), the back-pressure cap bound (fixed by
      a larger cap, or a rung of D18's ladder), every eligible item already
      claimed by a peer (fixed by a *smaller* fleet, which costs no throughput
      and saves the idle spend), and the Co-Ordinator declining to select
      against a non-empty eligible set (fixed by a different
      `coordinator_model` — the same failure the verdict-quality panel
      reports, arriving here as the elapsed time it actually cost); **idle
      without demand** — nothing eligible anywhere, the healthy zero, and the
      state Kubernetes scale-to-zero should make free; and **down** — crashed,
      crash-looping, heartbeat stale, container unscheduled, or the
      wedged-updater signature of 2026-08-14. Demand at rest is the part that
      needs building: a gather runs per cycle, so a sleeping node records
      nothing about work that arrived while it slept. The observable proxy
      already exists — `first-seen`-to-`selection` latency, which
      `scripts/pickup-metrics.sh` computes and whose own header notes it can
      never resolve below one `cycle_interval_minutes`. *[fleet]*
- [ ] Export the analytics series alongside the health and liveness endpoints
      above, in the orchestrator's own idiom (D21): the time, spend and flow
      accounts as metrics and structured events a customer can point their own
      Prometheus or OpenTelemetry collector at — so an installation that
      already runs monitoring gets these numbers inside it without adopting
      the product's page, and Pullwright's own surface becomes one opinionated
      reader of a published contract rather than the only way to see the data.
      Kubernetes' own signals join the **down** bucket here rather than being
      left surfaced-but-unread: pod phase and restart counts, evictions,
      `ImagePullBackOff`, a rollout past its `progressDeadlineSeconds`, a
      CronJob that has stopped scheduling — exactly the reporting gap the
      Kubernetes item below records and does not itself close. The wire format
      is an open question with a Phase 2 gate. *[fleet]*
- [ ] Build the analytics surface as its own deployable, on the dashboard
      split's precedent (D21, D14). Operations answers "is it broken now" at
      heartbeat cadence for whoever is on the hook; analytics answers "am I
      getting value, and what should I change" over days and weeks for whoever
      pays. They are different questions with different refresh rates and
      different readers, they share one page today, and the arithmetic belongs
      where the dashboard split already puts assembly — in one container,
      never on every agent node's cron. *[interactive]*
- [ ] State the constraint (D21). The analytics surface leads with one
      sentence — what is limiting throughput right now, over what share of the
      window, and what to do about it — computed from the time account above:
      the human merge gate, the back-pressure cap, model capacity, node count,
      cron latency, or the pipeline's own defect rate. Everything else on the
      page exists to justify or refute that sentence. It is also the honest
      business case for levers the product already has: an installation whose
      gate binds for most of a week is told, in figures it can check, what a
      rung of D18's ladder or a higher `max_open_agent_prs` would buy it, and
      one whose fleet is mostly idle without demand is told to shrink rather
      than being sold more nodes. *[fleet]*
- [ ] Actor and model scorecards, superseding the Co-Ordinator verdict-quality
      panel and subsuming #529 (D22). One card per actor and, within it, one
      row per model and tier, reporting outcomes rather than activity:
      attempts, and how many ended cleanly (no `kill_reason`, no contribution
      to a crash loop); what those attempts *produced* — landed unchanged,
      landed after N further passes, voided, abandoned; first-pass yield; cost
      and wall-clock per landed item; and each actor's own measure — the
      Reviewer's findings raised against findings that led to a change, and
      against defects that reached the human or a revert past it; the
      Co-Ordinator's corroboration rate, today's panel folded in, alongside
      whether the items it picked went on to land; the Enabler's and Refiner's
      unblock and refinement success. Every row states its stratum and its
      sample size and declines to rank below the minimum (D22). #529's model
      ratios become one facet of this card rather than a chart of their own,
      and they must not be built before the Phase 1 attribution fix lands:
      built on today's `keys[0]` join, a usage ratio inherits the same error
      that puts 98.7% of the fleet's spend on the wrong model. *[fleet]*
- [ ] Report rework by class, cause and escape (D23). The pipeline already
      emits every detector this needs and joins none of them: `attempt-failed`
      and `kill_reason` for a stage that had to be re-run, the review gate's
      own `CHANGES_REQUESTED` rounds, `claim-lost` contention for duplicated
      work, `abandoned_draft_after_hours` for a draft another cycle resumes,
      the `merge-conflicts` work source for a pull request `main` moved under,
      the refinement block for an item bounced back as under-specified, and
      `scripts/mine-merge-history.sh`'s 48-hour revert-or-follow-up check for
      what escaped a merge. One class has no sound detector yet and this item
      inherits rather than closes the gap: a human change request arriving as
      a plain comment is invisible to the review gate, which is #533 — so the
      most expensive rung but one is precisely the one currently least well
      observed, and the escape ladder below understates itself until that
      lands. Assemble the rest into one panel that answers three
      questions and nothing else. **How much?** — rework's share of tokens and
      of elapsed time, against first-pass yield: the fraction of items that go
      from first sighting to landed with no repetition of any class. **Whose?**
      — repetitions grouped by the stage they are attributed to rather than
      the stage that performed them, which is what turns "the Implementer is
      expensive" into "items are arriving under-specified" and points the fix
      at the Refiner. **How far did it get?** — the escape ladder, one row per
      detection stage (agent review, the human gate, post-merge), each
      carrying what share of defects passed that rung and the measured cost of
      catching one at the next: this is the panel's actual quality-control
      output, and it is why the page must never present rework as a quantity
      to minimise. A rising escape rate at the agent-review rung with a
      falling rework rate is the signature of a Reviewer that has started
      waving work through, and the panel has to make that legible as a
      regression rather than as an improvement. Feeds the actor and model
      scorecards above: rework attributed to a stage is that stage's model's
      record, and it is the outcome half of D22's grading. *[fleet]*
- [ ] Price the fleet and the tokens (D21, D14). Two questions the accounts
      make answerable and nothing asks today. **Is this fleet the right
      size?** — per node, the items it landed that no peer would have taken,
      set against its idle-without-demand hours and its share of contended
      `claim-lost` events, which `scripts/pickup-metrics.sh` already counts as
      its duplicate-work measure; a fleet whose nodes mostly lose claims to
      each other is over-provisioned, and shrinking it raises work-per-token
      at no cost in elapsed time. **Where do the tokens go?** — the spend
      account split by fate (delivered, rework, discarded, overhead,
      defect-driven), the prompt-cache ratio per stage and model from the
      `tokens.cache_read`/`cache_creation` series Phase 1 surfaces, and turns
      and stall profile per landed item from `num_turns` and `gaps`. A stage
      re-sending an uncached prompt every cycle, or a model taking three times
      the turns for the same diff, is a token-efficiency regression as
      concrete as a failed cycle, and is invisible today. *[fleet]*
- [ ] The renderer (D19, the *rendered* tier): one separately-deployable
      container per installation — the dashboard-split precedent — that
      takes a URL or a built static page, drives a headless browser, and
      returns screenshot, console log, and rendered DOM as artefacts to
      the requesting stage; agent images stay browser-free. On Compose an
      optional profile whose browser process exists only for the duration
      of a job; on Kubernetes an on-demand Job, so scale-to-zero holds. It
      alone holds the preview credentials, and it carries a stated resource
      budget (D14) like every other container. Rendered output is untrusted
      page content and reaches the model as data, never as instructions.
      *[interactive]*
- [ ] Local preview fallback (D19): where a repository has no preview
      deployment — agent-ops#424's dashboard is the motivating case — or
      will not share its build system's credentials, the renderer's builder
      side clones the pull-request head, runs the build-and-serve commands
      declared in the repo's `preview` block, and checks the result. The
      expensive path by construction, so it is opt-in per repo,
      concurrency-capped, cached between runs, and priced under D14; a
      static page needs no build step and costs almost nothing.
      *[interactive]*
- [ ] Decide how the suite authenticates to the forge, so that no
      installation depends on a human's personal API quota. Every node, the
      Publisher, and every interactive session presents a personal access
      token belonging to the installation's owner, and GitHub keys the
      primary rate limit to the *user* and not the token — so extra PATs buy
      nothing, and the refusal names the person (`API rate limit already
      exceeded for user ID 2049303`, fleet-wide on 2026-08-12). #312 cut the
      cycles' GraphQL demand by ~97% and the dashboard split above removes
      most of what is left, but both are demand-side: one bucket of 5,000
      points per hour still has to cover an entire installation, however
      large it grows. Evaluate every available identity against demand
      measured *after* those two land, and record the arithmetic rather than
      the conclusion alone (D14) — the owner's PAT (status quo: 5,000 REST
      and 5,000 GraphQL points per hour per *user*, shared with their
      shell); one machine account per node (N × 5,000, but the Terms of
      Service permit "no more than one free machine account in addition to
      your free Personal Account", and on a paid organisation each is also a
      billable seat); one GitHub App installed on the organisation (seatless
      on every plan, but 5,000 points per hour *per installation*, rising by
      50/hour per repository above 20 and per member above 20 to a cap of
      12,500 — for a small organisation, isolation without extra capacity);
      one App per node against the same organisation (N × 5,000, still
      seatless, at the cost of a key per app and hourly installation-token
      minting that `gh` cannot do natively); and the Actions `GITHUB_TOKEN`
      (1,000/hour per repository and scoped to a workflow run, so rejected
      for a long-running node). Whatever ships as the default is what every
      adopter inherits, and a hosted delivery (D2) would have no option but
      an App, so this is a product decision and not merely an operational
      one — which means pricing it for Pullwright rather than for
      Poetic-Poems, because **the Pullwright repositories will not
      necessarily be public.** A Free organisation of public repositories,
      which is what Poetic-Poems is today, charges nothing for members and
      nothing for standard-runner minutes; that arithmetic makes several of
      these options look free when they are not free in general. Private
      repositories move the bill on both axes at once — Actions minutes
      begin drawing on the plan's allowance, and branch restrictions, the
      merge gate the whole pipeline is built around, reach private
      repositories only on GitHub Team or Enterprise Cloud — so a private
      product repository that needs the gate puts the organisation on a
      per-seat plan, which is precisely the plan on which machine accounts
      stop being free and Apps stay free. Evaluate under both organisation
      shapes and state which one the recommendation assumes. D18 adds a
      second criterion that rate-limit arithmetic cannot settle: any
      `merge_autonomy` level above `human` needs a non-author identity able
      to hold review and merge rights — GitHub refuses self-approval, and
      the pipeline authors as its owner. The Approver half is therefore
      decided ahead of the arithmetic here: one GitHub App per installation
      ("Pullwright Approver", `docs/reviews/2026-08-14-autonomy-investigation.md`
      §5.3). This item still owns the authoring identity and rate-limit
      capacity. *[interactive]*
- [ ] Climb the D18 merge-autonomy ladder on the Poetic fleet to
      `agent-merges-all`: Stage 0 evidence baseline and kill switch, Stage 1
      agent approval under the Approver App (human still merges), Stage 2
      autonomous landing for the routine tier on agent-ops, Stage 3
      fleet-wide, Stage 4 protected paths behind critical-tier review and a
      cool-off. Each promotion is a one-line IaC config PR the owner merges;
      exit criteria, prerequisites, and the work-item breakdown are in
      umbrella #402 and the investigation report. *[fleet]* with owner-only
      acts flagged (App creation, ruleset changes, stage promotions). This
      item's Phase 2 placement is deliberately overtaken: per #628, all D18
      prerequisite and preparation work proceeds now, ahead of the Phase 1
      exit gate — WI-1..WI-11 already landed during Phase 1 and Stage 2 was
      entered 2026-08-18 under a recorded waiver — and only the promotion
      acts themselves (raising a repository to a higher rung) stay gated by
      umbrella #402's own evidence bars, which is the ladder's own gating
      rather than a phase boundary.
- [ ] Event-driven dispatch: GitHub webhooks, or a lightweight poller on the
      state repo, wake an idle node when a source-relevant event lands,
      instead of leaving it to wait for the next cron firing. Staged behind
      finish-then-continue and the sub-hourly heartbeat, both of which
      shipped in #268, since shrinking the pickup interval further widens
      the concurrent-claim window those two already had to account for.
      Unblocked now that its prerequisite — WI-2's PR-level claim exclusion
      (#238) — closed 2026-08-09. Issue #248 stage 3, WI-12 of #236.
      *[fleet]*
- [ ] Kubernetes deployment: manifests or a Helm chart, with the scheduler
      as a CronJob so scale-to-zero falls out naturally; Compose remains a
      supported option. This retires one whole class of update failure by
      construction rather than by fixing it: watchtower updates imperatively
      — stop *this* named container, create its replacement under the same
      name — so a step that half-completes leaves a collision it then repeats
      forever, which is what wedged poetic-vm-1 on 2026-08-14. A rollout
      reconciles toward a declared state under generated names, so there is
      no name to collide and no single failed step to repeat. What it does
      *not* retire is the reporting gap recorded against the health item
      above: `ImagePullBackOff`, a rollout past its `progressDeadlineSeconds`
      and a CronJob that has stopped scheduling are all conditions Kubernetes
      exposes and none that anything here reads yet. Surfaced in an API is
      not the same as reported to an operator. *[interactive]*
- [ ] Make the deployment an artefact: a node's compose (or manifest) comes
      from a pinned, versioned release rather than a hand-fetched file, so
      configuration drift becomes a version comparison the heartbeat already
      carries — retiring the detection machinery of #131 (the self-mount,
      `lib/compose-drift.sh`, the deploy-reminder workflow) along with the
      manual `up -d` ritual it watches. *[interactive]*
- [ ] Begin the control-plane skeleton in the chosen language (D6): a
      config service/CLI wrapping the engine — the first strangler fig.
      *[interactive]*
- [ ] Deliver the repository tooling instead of vendoring it (D20): fix the
      surface by which a repository declares the maintenance capabilities it
      wants and receives their executables from the product, with the
      tech-debt register's tooling as the first delivered set (D15 has
      already moved it into the product repository by then). Then migrate
      customer zero and delete what the migration makes redundant: the
      vendored script copies in agent-ops, poetic and poetic-fiddle, each
      repository's `td-tooling-drift.yml`, and the upstream manifest those
      workflows read. A capability the product delivers cannot drift from
      itself, so the checks that exist to notice drift go with it — a
      migration that leaves them standing has not finished. *[interactive]*
- [ ] Extract a state-store interface so the git-branch state-sync stays
      the default but alternatives (object store, database) can arrive
      later without re-architecture. A git repository (`agent-ops-state`)
      is an expensive way to replicate small, frequently-changing state —
      every sync is a fetch/push round-trip and the history only grows — so
      candidate replacements are weighed on measured bandwidth and disk
      cost (D14) as well as on scale. The interface owes its caller two
      operations the git implementation lacks today, *verify* and
      *rebuild-from-source*, so that self-healing is a property every
      backend must supply rather than a repair someone wrote once for this
      one. *[interactive]*

## Phase 3 — First external users

**Goal:** strangers can adopt the product self-served, and design partners
run it in anger.

**Entry:** Phase 2 exit gate passed; at least two design partners
committed (GTM workstream).

**Exit gate:** two to three design partners outside Poetic-Poems run the
suite on their own repositories, self-served from public documentation;
onboarding takes less than an evening; per-repo cost is visible on the
dashboard; at least one design partner has changed a model, a cap or a fleet
size on the strength of a figure the analytics surface put in front of them,
and the effect of that change is visible in the same surface; a feedback
channel exists and is producing roadmap items.

- [ ] Quickstart: one documented command sequence from clean machine to
      first cycle. *[fleet]*
- [ ] Public documentation site generated from the repo. *[fleet]*
- [ ] Multi-repo configuration UX reviewed against real partner setups.
      *[interactive]*
- [ ] Dashboard authentication story for remote and multi-user viewing
      (today's answer is "tailnet"; partners will need more). *[interactive]*
- [ ] Surface the Phase 1 metering as per-repo cost reporting in the
      dashboard. *[fleet]*
- [ ] Support channel and telemetry (opt-in, privacy-respecting) for
      failure patterns. *[interactive]*
- [ ] First non-Claude model provider supported end to end, chosen by
      design-partner demand (D12). *[interactive]*
- [ ] Preview adapters beyond Vercel — Netlify, Cloudflare Pages, a plain
      URL template over the forge's deployments API — chosen by
      design-partner demand (D19). *[fleet]*
- [ ] Controlled model trials, and the recommendation they feed (D22).
      Observational scorecards can only compare what happened to run; a trial
      assigns a candidate model a configured share of one actor's eligible
      work for a bounded period or item count, records the arm on the item,
      and compares arms within the same strata — opt-in, cost-capped,
      abortable, and off the critical tier unless that is separately opted
      into. What it produces is a recommendation carrying an effect size, a
      sample and a confidence statement, or no recommendation at all. Here
      rather than in Phase 2 because it needs the scorecards' definitions
      settled and enough item volume to conclude anything, and because design
      partners on different repositories are what show whether a
      recommendation generalises at all; the opt-in telemetry item above is
      the channel through which cross-installation comparison —
      "installations like yours run X for this actor" — could later be
      offered, inheriting that item's privacy stance rather than relaxing it.
      *[interactive]*
- [ ] Project-scoped review (D7), the deferred half of the naming fix: review
      the several repositories that deliver one product as a single subject,
      not one at a time. That means one report set for the project, the
      findings that exist only across a boundary — logic duplicated on both
      sides of a sync, a contract changed in the provider and not in its
      consumers, an interface a consumer is still a version behind on — and
      each recommendation routed to the repository that has to implement it,
      as a pull request into that repository. Poetic is the motivating case:
      the framework in `Poetic-Poems/poetic` and the repositories it syncs
      into are one product reviewed in halves today, and the vendored-tooling
      drift D20 exists to retire is precisely the class of finding a
      single-repository review cannot see. Deferred to here rather than
      Phase 1 because it needs repository review untethered first, and
      because it is a genuine cost step, priced under D14 before it is built —
      N repositories in one review multiply the context one agent must hold,
      and a report that spans repositories has a wider blast radius when it is
      wrong. The instructions-and-context facility gains a project level above
      its repository one; project membership is configuration, so a repository
      may be reviewed on its own, as part of a project, or both.
      *[interactive]*

## Phase 4 — Delivery decision and launch

**Entry gate (a decision, not a task):** with design-partner evidence in
hand, close D2 — self-hosted product, hosted SaaS, or both. This is the
point where the both-paths rule ends.

**Exit gate:** first paying customer.

Common to either path:

- [ ] Pricing set (tested in Phase 3) and billing integration.
- [ ] Launch positioning, landing page conversion, licence story published.

If SaaS is chosen, additionally:

- [ ] Multi-tenant control plane and tenant isolation.
- [ ] The deferred leg of D4: metered usage resale with margin, quotas,
      and abuse controls.

If mid-size-org demand shows, an enterprise track opens (SSO, RBAC, audit
trails) — demand-driven, never speculative.

## Go-to-market workstream (parallel, from Phase 1)

Deliberately lightweight — hours a week, not a phase of its own:

- **Name:** ~~shortlist, domain and trademark checks~~ — decided:
  **Pullwright** (D13), org created. Remaining: secure `pullwright.dev`
  (and `.io` if wanted) and a proper trademark search before the licence
  carries the name.
- **Positioning and landing page:** drafted during Phase 2.
- **Design partners:** recruitment starts at the end of Phase 1 — two or
  three, drawn from the three target segments (D3); committed partners gate
  Phase 3 entry.
- **Pricing hypothesis:** drafted during Phase 2, tested with partners
  during Phase 3, set at Phase 4.
- **Licence communication:** publish the reasoning for source-available
  alongside the licence itself.

## Open questions

Parked deliberately, each with a decide-by gate:

| Question | Decide by |
|---|---|
| Exact source-available licence (BSL 1.1 / FSL / Elastic 2.0) | Phase 1 exit |
| Where a repository's review instructions and context live (D7) — a block in the installation's versioned configuration (D16), a file in the repository under review (D20's rule that a repository holds its own data), or both layered with configuration winning; and how far text taken from the repository may be trusted as instruction rather than merely read as evidence | Phase 1, with the item that builds the facility |
| Control-plane language (Go and TypeScript are the front-runners) | First control-plane commit, Phase 2 |
| Execution substrate for non-Claude providers — abstraction over agentic CLIs, a provider-neutral runtime, or an API gateway | Interface fixed with the control-plane skeleton, Phase 2; first non-Claude provider lands in Phase 3 |
| State store beyond git state-sync | Interface fixed in Phase 2; replacement whenever scale or measured resource cost (D14) demands |
| Forge API identity — the owner's PAT, machine accounts, one GitHub App on the organisation, or one App per node | Phase 2, before secrets-based provisioning fixes the credential shape; priced for a Pullwright organisation whose repositories may be private. The Approver role is already decided — one GitHub App per installation (D18); this question still owns the authoring identity and capacity arithmetic |
| What a rendered verdict is (D19) — screenshots a model eyeballs, scripted assertions the repo declares, a visual diff against a baseline, or some blend | First renderer commit, Phase 2 |
| How tooling reaches a repository (D20) — a versioned package the repository pins, an image or action the pipeline mounts at cycle time, or product-managed synchronisation pull requests the repository merges. The choice is constrained by where the tooling has to run: some of it is CI (a repository's own workflow calling a register guard), some of it is an agent's shell mid-cycle | Interface fixed with the control-plane skeleton, Phase 2 |
| What counts as a unit of delivered work (D21's numerator) — merged pull requests, closed work items, or a size- or tier-weighted measure — and how a voided, superseded or human-abandoned item scores | Phase 2, with the first panel to state a rate |
| Where the lifecycle and time-state records live, and for how long (D21) — a table in the state store, a time-series database beside the analytics container, or the state repository itself — priced under D14 against the retention a year of trend needs | Phase 2, with the state-store interface |
| Wire format for the analytics export (D21) — Prometheus/OpenMetrics, OTLP, or the product's own JSON behind an adapter — and whether the analytics surface reads that export or the store behind it | Phase 2, with the control-plane skeleton |
| Whether a model trial may ever be assigned to the critical tier, and what evidence would justify allowing it (D22) | Phase 3, with the trial facility |
| How a repetition's cause is attributed (D23) — from the detector alone, from the diff between one pass and the next, or from the reviewing actor's own stated finding — and what is admissible when two causes are equally plausible, given that a model inferring cause after the fact is exactly what the decision forbids | Phase 2, with the rework panel |
| How long after a merge a revert or a follow-up fix still counts as an escape (D23) — `scripts/mine-merge-history.sh` uses 48 hours — and whether that window is the same for a repository merging once a week as for one merging hourly | Phase 2, with the rework panel |
| Multi-forge support (GitLab, Bitbucket, Gitea) | Revisit on design-partner demand, Phase 3 |
| SaaS infrastructure | Only if Phase 4 chooses SaaS |

## Assumptions

- **An orchestrator does not make derived state safe.** Kubernetes improves
  *detection*: a sync modelled as its own CronJob fails as a first-class Job
  status rather than as a line in a log nobody reads, and graceful drain
  removes one of the triggers. It does not repair anything. A corrupt
  PersistentVolumeClaim survives every pod restart, eviction and
  rescheduling the platform can perform, so the failure recurs on each tick
  and the backoff merely re-runs it; and the mirror has to be persistent,
  because re-fetching ~600 MB per node per tick is precisely the bandwidth
  the budgets of D14 exist to prevent. Volume durability guarantees the
  bytes are still present, never that they are still valid. Recovery is
  application work on any platform, which is why it is a checklist item
  above and not a consequence of the deployment target.
- GitHub is the only forge until demand says otherwise.
- The headless Claude CLI is the execution substrate for the Claude
  provider; the product's value is the orchestration, which is
  model-agnostic by design (D12). Non-Claude providers arrive behind the
  substrate abstraction, not by rewriting the engine per provider.
- The human merge is the default gate, and remains the only gate in every
  installation that has not deliberately configured otherwise: below
  `agent-merges-routine` on D18's ladder the product never auto-merges and
  never enqueues (D17). At or above that level, landing is a Script act
  behind D18's gates — and a human `CHANGES_REQUESTED` still blocks it at
  every level. The veto outlives the gate.
