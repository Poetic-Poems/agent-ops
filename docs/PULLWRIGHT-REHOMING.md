# Re-homing agent-ops in the Pullwright organisation — runbook

**Status: preparation.** The transfer has not happened. This document is the
plan of record for it, tracked by #912 (owner acts, `blocked` so the pipeline
never selects it). It is a planning document, not an as-built specification:
it describes what will be done and in what order; the as-built specs remain
the authority on what *is*. When a step lands, tick it in #912 and amend
this document where the evidence overtook it.

Assessment this runbook condenses (2026-08-28, with its GitHub-documentation
sources): <https://claude.ai/code/artifact/e6519e84-d138-4ea4-8b6e-483e84d98e4b>.

## The decision

`Poetic-Poems/agent-ops` — the repository, its history, its issues and pull
requests, its ruleset — is **transferred** to the Pullwright organisation and
becomes the product repository in place. It **stays public**: D5 (reaffirmed
2026-08-28, #909) makes the public code the marketing, and the private
option is what carried most of the cost — the Team-plan upgrade for a ruleset
on a private repository, a private registry with a login on every node, the
loss of code scanning (paid on private) and of the merge queue (Enterprise
Cloud only on private). None of that applies to a public organisation
repository.

This is one way of doing the Phase 1 D8 item, and the cheaper way. D8 said
"a new product repository holds the pipeline; agent-ops shrinks to Poetic's
consumer configuration". GitHub moves issues only within one owner, so
whichever direction the split runs, one class of issues is stranded — and
this repository's issues are overwhelmingly the pipeline's own. Moving the
repository keeps the pipeline with its issues, its D18 evidence and its
Approver; the small consumer half is extracted afterwards into a new,
differently named repository in Poetic-Poems (GitHub retires
`Poetic-Poems/agent-ops` on transfer, so the name cannot be reused). D8 is
amended to say so.

## What the transfer carries, and what it does not

GitHub transfers issues, pull requests, wiki, stars, watchers, releases and
settings (the `default` branch ruleset included), keeps every commit, and
redirects `git clone`/`fetch`/`push` and every web link from the old
location until something is created at it — which the retirement forbids.
The repository has no webhooks, no Actions secrets or variables, no deploy
keys, no Pages site; every workflow declares its own `permissions:` block,
so the receiving organisation's default `GITHUB_TOKEN` policy does not
matter.

Three things do not follow a repository across an organisation boundary.
Each touches the running fleet, which is why the move is a runbook and not
a click.

1. **Every node's `GH_TOKEN` is a fine-grained PAT, and a fine-grained PAT
   reaches exactly one owner.** ("Each token is limited to access resources
   owned by a single user or organization.") Reads of a public repository
   keep working; the branches, pull requests, issues, labels and comments
   the pipeline writes into agent-ops do not, and the same token still has
   to write to `poetic`, `poetic-fiddle` and `agent-ops-state` in
   Poetic-Poems. See "Credential model" below.
2. **The image is the deployment artefact, and it lives in
   `ghcr.io/poetic-poems/`.** `/app` inside it *is* agent-ops
   (`.github/workflows/build-image.yml`). GHCR packages belong to the
   organisation namespace, not the repository: on transfer the package's
   link to the repository is removed and the transferred repository's
   workflows lose access to it. So `build-image.yml` must publish to
   `ghcr.io/pullwright/agent-ops`, and every node's `AGENT_OPS_IMAGE` must
   follow — otherwise `:latest` in the old namespace goes stale and every
   node silently stops rolling, the failure mode `deploy/docker/README.md`'s
   "Is this node on the newest image" section exists for. Anonymous pulls
   keep working; no registry login is needed.
3. **The Approver App has one installation id, and installations are per
   organisation.** `lib/approver-token.sh` takes a single
   `PULLWRIGHT_APPROVER_INSTALLATION_ID`, and `scripts/doctor.sh`'s
   installation checks assume "one installation backs every repository this
   identity reviews". `pullwright-approver-poetic` is installed on
   Poetic-Poems; agent-ops leaves that installation's scope on transfer.
   Without #913 (per-owner installation resolution), agent-ops drops from
   `agent-merges-routine` to a human landing every pull request — the
   regression Principle 8 forbids — so #913 lands first.

Two lesser effects: the `Priority` issue field is organisation-scoped
(Pullwright already defines one with the same four options; whether values
survive a cross-organisation transfer is undocumented — the rehearsal below
answers it), and claims in the state repository are keyed by slug
(`claims/Poetic-Poems__agent-ops/…`), so the cutover happens with the fleet
stood down and any straggler ages out through `claim_ttl_hours`.

## Order

Every step is marked *owner act* (performed by @warwickallen, on GitHub or
on a node) or *fleet* (an ordinary pull request the pipeline can build).

### Rehearsal — *owner act*, 20 minutes, no fleet impact

1. Create `Poetic-Poems/rehome-rehearsal`, public. Open one issue and set
   `Priority: High`. Add a default-branch ruleset copying `default`'s rules.
2. Transfer it to Pullwright. Check: is the Priority value still on the
   issue? Is the ruleset intact?
3. Delete the repository. If the Priority value was lost, plan to re-band
   agent-ops's open issues after T0 (47 of 57 carried a band on 2026-08-28);
   unbanded issues read as `Medium` and the Refiner's ratchet rebuilds the
   rest over time.

### Before T0

- [ ] The docs PR — this runbook and the D8 amendment. *fleet or owner*
- [ ] #913 — per-owner Approver installation. *fleet*
- [ ] Make `pullwright-approver-poetic` installable outside its owner
      account (App settings → "Where can this GitHub App be installed?"), or
      transfer the App to the Pullwright organisation; install it on
      Pullwright with `contents: write`, `metadata: read`,
      `pull_requests: write`; note the installation id. *owner act*
- [ ] Mint four personal access tokens (classic) — `repo`, `workflow` — one
      per node, each with an expiry; confirm Pullwright's organisation
      settings allow classic tokens. *owner act*
- [ ] The sweep PR (`chore: re-home under Pullwright — slug and image
      sweep`): opened against the old slug, kept green, **not merged**. Its
      `config.json` names a repository that does not exist until T0, and its
      `build-image.yml` publishes to a namespace the Poetic-Poems
      repository's `GITHUB_TOKEN` cannot push to. *fleet keeps it rebased*

### T0 — *owner act*, about an hour with the fleet stood down

1. Stand the fleet down and wait for the running cycles to finish:
   ```bash
   docker exec agent-ops-scheduler-1 /app/agent-cycle.sh --disable 'agent-ops re-homing' --for 3h
   # then, on each node, until it exits 0:
   docker exec agent-ops-scheduler-1 /app/deploy/docker/watchtower-pre-update.sh; echo $?
   ```
2. Transfer the repository: agent-ops → Settings → Danger zone → Transfer →
   `Pullwright`. Confirm the redirect: `gh repo view Poetic-Poems/agent-ops`
   resolves to `Pullwright/agent-ops`.
3. Merge the sweep PR (rebase first if `main` moved; pushes to the old remote
   redirect). Watch "Build the node image" publish
   `ghcr.io/pullwright/agent-ops:latest`. Open the new package's settings:
   link it to the repository and confirm it is **public** — a package first
   published from a workflow may not be.
4. On each node — `~/poetic-node-1` (ockham-container), `~/poetic-node-2`
   (ockham-2), `/opt/poetic-node` (poetic-1), `/opt/poetic-node-2`
   (poetic-2). A running container keeps the `.env` it was created with, so
   the recreate is the step, not the edit:
   ```bash
   $EDITOR .env   # GH_TOKEN=<this node's classic token>
                  # AGENT_OPS_IMAGE=ghcr.io/pullwright/agent-ops:latest
                  # the per-owner Approver installation variable #913 settles on
   until docker exec agent-ops-scheduler-1 /app/deploy/docker/watchtower-pre-update.sh >/dev/null 2>&1; do sleep 30; done
   docker compose pull && docker compose up -d
   docker compose ps -a --format "table {{.Name}}\t{{.Service}}\t{{.Status}}"   # one row per profiled service
   docker exec agent-ops-scheduler-1 /app/scripts/doctor.sh                       # token writes to both owners; App covers agent-ops
   ```
   From the workstation, `helper-scripts/env-key-hash.sh GH_TOKEN` must show
   no node as `STALE`.
5. Re-point the workstation clone:
   `git remote set-url origin https://github.com/Pullwright/agent-ops.git`.
6. `--enable`, and watch the first cycle on each node: it selects and clones
   under the new slug, the Approver reviews an agent-ops pull request, and
   `failed-runs` is empty.

### Aftercare

- [ ] Release any claim still under `claims/Poetic-Poems__agent-ops/` in the
      state repository, or leave it to expire.
- [ ] Delete or leave `ghcr.io/poetic-poems/agent-ops` — it is public and
      contains nothing the repository does not.
- [ ] `Poetic-Poems/helper-scripts/count-autonomous-agent-prs.sh` reads
      `config.json` from the old slug; one line.
- [ ] Dashboard history keeps the old slug on pre-move records, so per-repo
      panels show two agent-ops rows for a while; cosmetic. The daily merge
      budget for agent-ops restarts.
- [ ] Tick #912 and amend this document where the rehearsal or the cutover
      overtook it.

## Credential model

Until D25's Forge App exists, each node's `GH_TOKEN` becomes a personal
access token (classic) with `repo` and `workflow`. It reaches every owner
the fleet writes to, needs no code change, and keeps "one token per node,
so a single node can be revoked without disturbing the others". What it
gives up is the fine-grained model's repository-level scoping: a classic
`repo` token sees every repository its owner can. The alternative — two
fine-grained tokens per node and a per-owner selection in front of every
`gh` call — touches every call site and the doctor's token checks, for a
property D25 delivers anyway; it is not worth building twice. The Forge App
(#607, D25) retires the interim: one installation per organisation, each
minting short-lived tokens scoped to that organisation's repositories.

## What was dropped, and why

The private option (Team plan, private image with `docker login` on every
node, `lib/image-drift.sh` authenticating to the registry, removal of
CodeQL and its ruleset rules, loss of the merge queue) was assessed on
2026-08-28 and dropped the same day when D5 was reaffirmed: a public
repository is the product's marketing, and the private half owned most of
the cost. Should it ever return, the assessment linked at the top carries
the full sequence.
