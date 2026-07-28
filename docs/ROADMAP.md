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
raises mergeable pull requests, with a human merge as the only gate.
Poetic-Poems stops being the pipeline's home and becomes its first
customer.

## Settled decisions

Decided July 2026; these shape every phase below. Reopen them only
deliberately, by editing this table in a PR that says why.

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
- Deeply customisable: per-actor model selection (Co-Ordinator, Implementor
  at both tiers, Reviewer at both tiers, Enabler) from any supported
  provider — not only the Claude family — plus schedules, work sources,
  prompts, and repo conventions.
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
- [ ] Config schema with validation, defaults, and a `doctor` command that
      checks an installation end to end. *[interactive skeleton, fleet
      completion]*
- [ ] Make schedules configuration-driven (per-pipeline cadence in config,
      not a baked crontab) — and retire the cadence from each pipeline's
      identity: "hourly" (and "weekly") must disappear from spec titles,
      documentation, prompts, and code, and every timing derived from the
      period today (lock staleness, retention counts, stand-down probing)
      must follow the configured value instead of assuming an hour.
      *[fleet]*
- [ ] First-class non-interactive auth: Anthropic API key, Bedrock, and
      Vertex as the primary path; subscription OAuth documented as the
      supported self-hosted alternative (D4). *[interactive]*
- [ ] Formalise the metering schema: per-cycle, per-stage token and cost
      accounting as a stable, documented format (largely exists in the logs
      today; make it a contract). *[fleet]*
- [x] Provider-qualified model identifiers in the config schema, so models
      from other providers can arrive later without a breaking change
      (D12). *[fleet]*
- [ ] Create the product repository in the Pullwright organisation (the
      name and org exist — D13); move the pipeline; reduce agent-ops to
      consumer config + deployment (D8). *[interactive]*
- [ ] Select and apply the source-available licence (D5). *[interactive]*

## Phase 2 — Zero-touch fleet

**Goal:** nodes are provisioned, updated, and retired with no manual steps;
updates are non-intrusive; Kubernetes is a supported target.

**Entry:** Phase 1 exit gate passed.

**Exit gate:** a new node reaches its first successful cycle with zero
interactive steps; a rollout during a cycle results in a drained, completed,
or cleanly handed-off cycle — never a killed one; the suite runs on a
Kubernetes cluster from published manifests/chart; scale-to-zero is
demonstrated (no idle compute cost between ticks).

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
      export. *[fleet]*
- [ ] Kubernetes deployment: manifests or a Helm chart, with the scheduler
      as a CronJob so scale-to-zero falls out naturally; Compose remains a
      supported option. *[interactive]*
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
      later without re-architecture. *[interactive]*

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
| State store beyond git state-sync | Interface fixed in Phase 2; replacement whenever scale demands |
| Multi-forge support (GitLab, Bitbucket, Gitea) | Revisit on design-partner demand, Phase 3 |
| SaaS infrastructure | Only if Phase 4 chooses SaaS |

## Assumptions

- GitHub is the only forge until demand says otherwise.
- The headless Claude CLI is the execution substrate for the Claude
  provider; the product's value is the orchestration, which is
  model-agnostic by design (D12). Non-Claude providers arrive behind the
  substrate abstraction, not by rewriting the engine per provider.
- The human merge remains the only gate: the product never auto-merges,
  whatever the customer's configuration.
