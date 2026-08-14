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
| D7 | Product scope | **The whole suite**: the implementation pipeline, the weekly review pipeline, and the dashboard. They compound — reviews feed the pipeline the work it does, and the dashboard is the product's face. |
| D8 | Repository shape | **Split**: a new product repository in the Pullwright organisation (D13) holds the pipeline; agent-ops shrinks to Poetic's consumer configuration and deployment — the reference installation and customer zero. |
| D9 | Build mode | **Mixed.** Architectural moves happen in interactive sessions; everything decomposable is authored as agent-workable items that the fleet works down itself. The roadmap doubles as dogfooding evidence. |
| D10 | Pacing | **Phase-gated, no dates.** Progress is gates passed, not calendar time. |
| D11 | Go-to-market | **A parallel lightweight workstream from Phase 1**: the name is chosen early (it gates the repo split), design partners are recruited during untethering, and pricing is tested before anything launches. |
| D12 | Model providers | **Not limited to the Claude family.** Customers choose the model for each actor from any supported provider. Claude is the first-supported and reference provider; how non-Claude providers are executed (the substrate question) is parked in Open questions with a decide-by gate. |
| D13 | Product name | **Pullwright.** Decided July 2026, ahead of its Phase 1 gate; the GitHub organisation ([github.com/Pullwright](https://github.com/Pullwright)) is created and the namespace secured. |
| D14 | Efficiency | **Per-container efficiency is an explicit product goal from the start.** Decided August 2026. Every container is held to budgets for CPU load, memory footprint, disk usage, and bandwidth, alongside — never at the expense of — quality and speed of delivery. Where these pull against each other, the trade-off is a calculated decision recorded in the change that makes it, never an accident discovered on a bill. Kubernetes requests and limits (Phase 2) become one enforcement mechanism, but the budgets exist whatever the control plane. |
| D15 | Tech-debt management | **The tech-debt management framework is part of the offering.** Decided August 2026. The per-item register proven across the Poetic repositories — append-only item files, scope-coded ID grammar, `td/<id>` claim locking, allocation/lookup/validation tooling, CI enforcement, drift-synced copies in consumer repositories — ships with the suite, on the same compounding logic as D7: the register is already one of the sources the pipeline works down. Canonical tooling today lives in `Poetic-Poems/poetic`; productisation moves it into the product repository. |
| D16 | Infrastructure as code | **The configuration of the pipeline and of the orchestration layer / control plane is infrastructure-as-code.** Decided August 2026. Everything that configures an installation — `config.json`, compose files and Kubernetes manifests, schedules, secrets wiring, per-node deployment shape — is declared in version-controlled code and reaches a running installation only by applying a versioned change, never by hand-editing a live node. Today compose- and env-level fixes are walked out to each node by hand, and the drift detection of #131 exists to catch exactly the divergence that this rule makes structurally impossible. Phase 2's deployment-as-artefact and Kubernetes items are the first enforcement, and the control-plane skeleton (D6) grows up under the same rule. |
| D17 | Merge queues | **Supported and recommended where available; never required.** Decided August 2026. A GitHub merge queue serialises landings and tests every candidate merged with the latest `main`, retiring the behind-but-green rework class that strict up-to-date rules otherwise create — Poetic-Poems adopts queues on its own repositories (tracked by #377). The product cannot mandate them: GitHub offers merge queues only on organisation-owned repositories — public on any plan, private only on Enterprise Cloud — and never on personal accounts, where D3's solo developers live. The pipeline therefore stays fully functional without a queue and becomes queue-aware where one exists: landings are asynchronous, a pull request can be `queued` or silently dequeued, and a push to a queued branch evicts it. Under a queue the merge act is enqueueing ("Merge when ready"). Below `agent-merges-routine` on D18's ladder that act is the human's, and the product never enqueues a pull request, exactly as it never merges one; at or above it, enqueueing is the Script's landing step, performed only after every D18 gate has passed. |
| D18 | Merge autonomy | **An opt-in trust ladder; the default is the human gate.** Decided August 2026 (investigation: `docs/reviews/2026-08-14-autonomy-investigation.md`; rollout umbrella #402). `merge_autonomy` — `human` → `agent-approves` → `agent-merges-routine` → `agent-merges-all` — sets, per installation and per repository, who approves and who lands a pull request. At every level above `human`, approval and landing are acts of the Script under a non-author forge identity (a GitHub App, "Pullwright Approver"), performed only after every deterministic gate and an independent Approver verdict pass; no model ever holds approve or merge rights, and a human `CHANGES_REQUESTED` blocks landing at every level. Where a merge queue exists, landing is enqueueing (amending D17); otherwise it is GitHub auto-merge. Landings are capped by `merge_budget_per_day`, which replaces the human merge rate as the spend governor. The product default is `human`, unchanged from today — nothing a customer has not opted into ever lands a pull request. Poetic-Poems, customer zero, climbs the whole ladder. |

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
- Deeply customisable: per-actor model selection (Co-Ordinator, Implementor
  at both tiers, Reviewer at both tiers, Enabler) from any supported
  provider — not only the Claude family — plus schedules, work sources,
  prompts, and repo conventions.
- Configured as code (D16): an installation's entire configuration —
  pipeline, orchestration layer, control plane — is versioned declaration
  applied by tooling; nothing is hand-mutated on a running node.
- Tech-debt management built in (D15): the per-item register, its tooling
  and CI guards ship with the product, race-safe for concurrent human and
  agent writers, and the pipeline works registers down as an ordinary
  source.
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

## Phase 1 — Untether

**Goal:** the pipeline is adoptable by an arbitrary repository through
configuration alone.

**Entry:** now.

**Exit gate:** a repository outside Poetic-Poems runs the whole suite —
implementation cycle, review cycle, dashboard — from published artefacts
with no code changes; agent-ops contains no pipeline code, only Poetic's
configuration and deployment; the product repository exists in the
Pullwright organisation and carries its licence.

- [ ] Audit and sweep the Poetic-specifics out of scripts, prompts, and
      config: hardcoded repo slugs, the owner's username, label names,
      branch conventions, and the poetic-fiddle implementation-plan source.
      Four are swept (the Enabler's assignee, the entrypoint's git identity,
      the implementation-plan path, the Co-Ordinator's repo/source table);
      the audit that would say what is left has not been done, and
      `config.schema.json` is now the place to do it from — writing it
      surfaced that the specs' configuration tables state *Poetic's* values
      where they say "default", `crash_loop_repo` among them.
      *[fleet — one item per specific]*
- [x] Parameterise the operating prompts so an installation can extend or
      override them without forking the product (`prompt_overrides` in
      `config.json`, docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 4a).
      Installation-wide per stage, not yet scoped per repo — see the item
      below. *[fleet]*
- [ ] Scope prompt overrides per repository, not just per installation. The
      Co-Ordinator runs once per cycle across every configured repo together,
      so a per-repo selection prompt needs that invocation split first; the
      Implementor and Reviewer stages already run against a single known repo
      and could take a per-repo override without it. *[fleet]*
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
- [ ] Retire the cadence from each pipeline's identity: "hourly" (and
      "weekly") must disappear from spec titles, documentation, prompts, and
      code, and every timing derived from the period today (lock staleness,
      retention counts, stand-down probing) must follow the configured value
      instead of assuming an hour. The cadence is configurable; the product
      still calls itself the hourly pipeline. *[fleet]*
- [ ] First-class non-interactive auth: Anthropic API key, Bedrock, and
      Vertex as the primary path; subscription OAuth documented as the
      supported self-hosted alternative (D4). *[interactive]*
- [x] Formalise the metering schema: per-cycle, per-stage token and cost
      accounting as a stable, documented format — `docs/METERING-SCHEMA.md`,
      the contract both pipelines and the dashboard are held to. *[fleet]*
- [x] Provider-qualified model identifiers in the config schema, so models
      from other providers can arrive later without a breaking change
      (D12). *[fleet]*
- [ ] Create the product repository in the Pullwright organisation (the
      name and org exist — D13); move the pipeline; reduce agent-ops to
      consumer config + deployment (D8). *[interactive]*
- [ ] Adopt the tech-debt management framework into the product (D15): move
      the canonical register tooling out of `Poetic-Poems/poetic` into the
      product repository (consumer repositories keep drift-synced copies),
      and close the known allocation gap — atomic, collision-proof ID
      reservation via the `td/<id>` ref-push lock the claiming workflow
      already uses (`Poetic-Poems/poetic` register item TD-PPpoet-26080801).
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
same way.

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
      acts flagged (App creation, ruleset changes, stage promotions).
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
dashboard; a feedback channel exists and is producing roadmap items.

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
| Control-plane language (Go and TypeScript are the front-runners) | First control-plane commit, Phase 2 |
| Execution substrate for non-Claude providers — abstraction over agentic CLIs, a provider-neutral runtime, or an API gateway | Interface fixed with the control-plane skeleton, Phase 2; first non-Claude provider lands in Phase 3 |
| State store beyond git state-sync | Interface fixed in Phase 2; replacement whenever scale or measured resource cost (D14) demands |
| Forge API identity — the owner's PAT, machine accounts, one GitHub App on the organisation, or one App per node | Phase 2, before secrets-based provisioning fixes the credential shape; priced for a Pullwright organisation whose repositories may be private. The Approver role is already decided — one GitHub App per installation (D18); this question still owns the authoring identity and capacity arithmetic |
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
