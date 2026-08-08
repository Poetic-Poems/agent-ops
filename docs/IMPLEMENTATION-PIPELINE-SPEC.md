# Hourly Autonomous Implementation Pipeline — as-built specification

## About this document

This is the as-built requirements specification for the hourly implementation
pipeline: the numbered requirements the system satisfies, the components that
satisfy them, the acceptance checks that prove it, and the reasoning behind
them. It describes the system as it exists, and it must keep doing so — any
change to the pipeline lands together with the edit that keeps this document
accurate (see `CLAUDE.md`, "As-built specifications"). Where this document is
silent, follow the conventions of the two target repositories (their
`CLAUDE.md` files are binding on any agent working inside them).

## What it is

A pipeline that, once an hour, picks **at most one** well-scoped item of
pending work from one of two GitHub repositories, implements it on a feature
branch in an ephemeral clone, reviews and corrects the result, and leaves a
mergeable pull request for a human to approve. It runs unattended on the
host machine (WSL2 Ubuntu). The only human involvement is final pull-request
review and merge.

```
cron (hourly)
  └─ agent-cycle.sh                 ← the Script: lock, stand-down checks, repo ordering
       ├─ Co-Ordinator (Haiku)      ← selects ≤ 1 item, emits a work order; nothing else
       ├─ Implementor (Sonnet/Haiku)← ephemeral clone, feature branch, draft PR
       ├─ Reviewer (Sonnet/Opus)    ← corrects the branch, flips the PR to ready
       │     └─ Human               ← reviews and merges (the only gate)
       └─ Enabler (Opus, rarely)    ← re-examines long-blocked items at the end of a
                                      cycle: unblocks, voids, or raises an issue
                                      assigned to the Human saying what to do
```

## Actors

1. The **Cronjob** — the crontab entry that fires the Script.
2. The **Script** (`agent-cycle.sh`) — a bash script that orchestrates one
   whole cycle. It launches every agent; agents never launch other agents.
3. The **Co-Ordinator** — a headless Claude Code invocation that selects one
   item of work and emits a work order. It does not implement anything.
4. The **Implementor** — a headless Claude Code invocation that carries out
   the work order and raises a draft pull request.
5. The **Reviewer** — a headless Claude Code invocation that checks and
   corrects the Implementor's branch, then marks the pull request ready.
6. The **Human Reviewer** — gives final approval and performs the merge on
   every pull request, through the ordinary GitHub process. Not launched by
   any part of this system.
7. The **Enabler** — a headless Claude Code invocation, engaged rarely and at
   the end of a cycle, that re-examines items recorded as blocked which the
   pipeline has not cleared by itself. It unblocks, voids, or leaves them
   blocked with a fresher condition; where an item was never specified well
   enough to select, it specifies it (requirement 36b); and where only a human
   can move an item, it composes a GitHub issue that the Script files, assigned
   to that human. It writes no code and raises no pull request.

## Environment (verified 2026-07-20)

- WSL2 Ubuntu; `bash`, `git`, `jq` and `gh` available.
- `gh` is authenticated as `warwickallen`, with push access to both target
  repositories.
- The standalone `claude` CLI is installed and resolvable from cron's
  minimal environment.
- `cron` is running (started by WSL's `[boot]` command) with the crontab
  entries installed: the hourly cycle, the daily review tick, and the
  dashboard heartbeat (see `README.md`, "Installation").
- Headless `claude -p` invocations authenticate with the user's existing
  Claude subscription login; `gh` uses its existing token. No new keys.

### The node image (`deploy/docker/`)

The same pipeline also runs from a container image, so a node can be a cloud VM
as readily as the laptop. The image is the *only* deployment artefact: it is
built from this repository, `/app` inside it **is** the deployed agent-ops, and
a node updates by pulling a new image rather than by pulling a branch.

- Base `ubuntu:24.04`, non-root user `agent` (uid/gid from the `PUID`/`PGID`
  build args, default 1000) with `HOME=/home/agent`, so `config.json`'s
  `~`-relative `state_dir` and `workspace_root` resolve under that home.
- Toolchain: `bash`, `git`, `jq`, `curl`, `python3`, `perl`, `coreutils`,
  `flock` and `rsync` (requirement 2.5); `gh` from GitHub's apt repository (the distro package is too old for
  the flags the pipelines use); Node.js from NodeSource at the same major as
  the laptop; the `claude` CLI from `@anthropic-ai/claude-code`;
  `supercronic`, a pinned release binary verified by SHA-1 (one pin per
  architecture), which runs the container's crontab as an ordinary process
  with no cron daemon and no root; and `shellcheck`, a pinned release binary
  verified by SHA-256 (one pin per architecture, the amd64 one
  byte-identical to `.github/workflows/shellcheck.yml`'s own pin — component
  10), so an Implementor working inside this image can run
  `scripts/lint-shell.sh` — the gate its own pull request is judged by —
  before pushing.
- `deploy/docker/entrypoint.sh` runs as `agent` on every container start and is
  idempotent: it seeds `$CLAUDE_CONFIG_DIR/settings.json` from
  `deploy/docker/claude-settings.json` **only when absent** (that directory is a
  persistent volume holding refreshing OAuth credentials, and the seed carries
  model/effort defaults only — no plugins and no local marketplaces), runs
  `gh auth setup-git` when `GH_TOKEN` is present so https pushes authenticate,
  creates `state_dir` and `workspace_root`, and then execs the service it was
  given. It refuses to start if `state_dir` is not writable, rather than
  letting a mis-owned volume become a silent failure to record anything. It
  does *not* set the git identity: every container this image runs — including
  the dashboard services and every command a `docker run` might be given —
  goes through this same entrypoint, and only a cycle that might actually
  commit needs an identity to commit under.
- `GIT_USER_NAME`/`GIT_USER_EMAIL` are instead required, with no default, by
  `agent-cycle.sh` and `review-cycle.sh` themselves (`lib/git-identity.sh`),
  checked once each has confirmed this tick will do real work — past its role
  guard, the switch, the fleet switch, the usage-limit stand-down, and (for
  review-cycle.sh) a lost or failed claim — and before the first git operation
  that could commit. A silent default would let a node commit every pull
  request it opens under the wrong name; checking this late means a standby
  tick, a switched-off node, a stood-down node, or a tick that ends up with
  nothing to do never needs an identity it was never going to use.
- The image sets `CLAUDE_CONFIG_DIR=/home/agent/.claude` — the `claude-config`
  volume's mount point. Claude Code's global config file defaults to
  `~/.claude.json`, a *sibling* of its config directory rather than a member of
  it, so it sat in the container's writable layer and every image roll destroyed
  it: each new container announced "Claude configuration file not found" on
  stderr and rebuilt the file from nothing. Pointing the variable at the default
  directory moves that one file inside the volume and changes no other path —
  credentials, `settings.json`, `projects/` and `sessions/` resolve exactly
  where they already did. It is set in the image rather than in each node's
  compose `environment:` so watchtower delivers it without a `docker compose up
  -d`, which would kill a cycle in flight — and in the image rather than only
  defaulted in `entrypoint.sh`, because the two reach different processes:
  `docker compose exec scheduler claude`, the once-per-node interactive login,
  starts from the image's environment and never runs the entrypoint. With the
  default alone, that login would write its config where the next roll destroys
  it while the cycles read the volume, and an operator who authenticated
  successfully would watch the node fail to authenticate. The entrypoint
  defaults it regardless, for any context that replaces the environment
  wholesale. The variable is honoured by the CLI but is not in its published
  settings documentation, so the image build asserts it (requirement 1b's
  checks) — against the image's own config rather than a running container's
  environment, since the entrypoint's default would otherwise mask a missing
  `ENV`. If a future CLI drops the variable, that check fails before the image
  reaches a node.
- `deploy/docker/crontab` carries the same three pipeline schedules as the
  laptop crontab — the dashboard heartbeat, the implementation cycle, the
  review tick — plus two fleet lines (requirement 2.5): a `state-sync.sh
  push`, which publishes this node's state and heartbeat to its own branch,
  and a `state-sync.sh fetch`, which materialises every peer's for the union
  readers; and one log-rotation line (requirement 2.6), `rotate-logs.sh`,
  which bounds the four logs those schedules append to. Every cadence named
  above — the heartbeat and both fleet lines' intervals, and the
  log-rotation minute — comes from `config.json`'s `schedule` (`heartbeat_minutes`,
  `state_sync_push_minutes`, `state_sync_fetch_minutes`, `log_rotation_minute`;
  see Configuration), baked at 5, 5, 7 and 19 in the checked-in config. The
  same redirections into `state_dir` apply, so the dashboard's log-derived
  views work identically. It deliberately omits the laptop's personal
  `update-main-branches.sh` entry: that refreshes interactive checkouts, and
  a node has none.
- **The cycle and review minutes are per-node** (design decision D5). At
  every container start, `entrypoint.sh` runs
  `deploy/docker/render-crontab.sh`, which renders `crontab.tmpl` over the
  baked crontab with this node's offsets: `CYCLE_MINUTE` from the
  environment when it names a minute `schedule.excluded_minutes` does not
  rule out, else a stable hash of `NODE_NAME` onto whichever minutes that
  exclusion list leaves standing — deterministic, needing no coordination,
  and never one of the excluded minutes. The cycle fires every hour named by
  `schedule.cycle_hours` (`*` by default); the review runs at
  `schedule.review_offset_minutes` past `CYCLE_MINUTE` (mod 60), at
  `schedule.review_hour`, keeping one node's two heavy pipelines maximally
  apart. Why: every active node spends one Claude account and pushes to the
  same repositories; the claims (17a) make simultaneous firing *correct*, the
  offsets make it *cheap*. Excluding minutes at all is a per-deployment
  choice, not logic this renderer carries: `schedule.excluded_minutes` is
  configuration, and poetic's own `config.json` excludes `0` because its
  hourly sync workflow owns the top of the hour, recording that reason in
  `schedule.excluded_minutes_reason` — a deployment with no such conflict
  ships an empty list. An invalid or excluded `CYCLE_MINUTE` warns loudly and
  uses the hash — a typo must not silently land a node on an excluded minute
  — and any render failure (including a missing or malformed `config.json`)
  leaves the baked crontab, a valid schedule, byte-untouched
  (`test/render-crontab.test.sh` pins all of this). The offsets therefore
  arrive with the image alone; setting `CYCLE_MINUTE` explicitly requires the
  compose file that maps it.
- Nothing host-specific and nothing secret is baked in. `GH_TOKEN`, the Claude
  credentials volume, `NODE_NAME` and `AGENT_OPS_ROLE` all arrive at run time,
  and a node that is not `active` (requirement 2.4) costs nothing but its
  cron-log lines.
- The image is built by CI, not by hand:
  `.github/workflows/build-image.yml` builds it on every pull request and
  every merge that could change it, runs the acceptance checks below *inside*
  it, and — on `main` only — publishes it to
  `ghcr.io/poetic-poems/agent-ops` tagged both `latest`
  (what a node's watchtower follows) and the commit SHA (how a node is pinned
  or rolled back, through `AGENT_OPS_IMAGE`), each tag a multi-platform manifest
  list covering `linux/amd64` and `linux/arm64`. A pull request builds and
  tests both legs — each in its own job on a runner of the image's own
  architecture, loaded (`load: true`) and run natively through requirement
  1b's acceptance checks — but publishes nothing. This is the whole update
  path: merge produces an image, and nodes replace containers. "Could change
  it" is requirement 1b-i's question: a change confined to prose builds
  nothing and publishes nothing, so a documentation merge leaves the fleet
  where it is and no tag carries its SHA.
- The image creates the volume mount points (`~/.claude`, `state_dir`,
  `workspace_root`) owned by `agent`, because a container runtime seeds a new
  named volume from the image's mount point — ownership included — and creates
  it as root when the image has nothing there.
- The image builds for both `linux/amd64` and `linux/arm64`: `supercronic` is
  the one binary not coming from a signed, multi-architecture apt repository,
  so the Dockerfile selects its release asset and pinned checksum from
  `TARGETARCH`, buildx's predefined build arg for the platform currently
  building.

### The node stack (`deploy/docker/compose.yaml`)

A node is a single Compose project. Every node runs the same file and the same
image; the only thing that differs between two nodes is `deploy/docker/.env` —
its name, its role and its tokens. `deploy/docker/.env.example` documents that
file and carries placeholders only; `.env` itself is never committed.

- **`scheduler`** — `supercronic /app/deploy/docker/crontab`, in no profile, so
  it runs on every node. `AGENT_OPS_ROLE` comes from `ROLE` in `.env` and
  **defaults to `standby`** if unset, so a half-configured node cannot become a
  second worker.
- **The Vercel variables are a capability, not a precondition.**
  `VERCEL_AUTOMATION_BYPASS_SECRET` and `VERCEL_TOKEN` reach both agent-ops
  services from `.env` through the shared environment block, and requirement
  24a's check is the only thing that reads them. A node with neither runs every
  cycle exactly as it did before that check existed — it reports "could not
  check" where a configured node reports a verdict — so they are never a reason
  for a cycle to stand down or an item to block. Being compose-level, they
  arrive only when a human edits that node's `.env` and runs
  `docker compose up -d` there; no image roll delivers them, which is the
  general hazard `lib/compose-drift.sh` and `scripts/check-node-compose.sh`
  exist for.
- **`dashboard`** (profile `tailnet`) — `scripts/serve-dashboard.sh` sharing the
  `tailscale` sidecar's network namespace (`network_mode: service:tailscale`).
  That shared namespace is what lets Tailscale Serve reach a server bound to
  `127.0.0.1` while nothing on any network can, so containerisation costs the
  dashboard's privacy model nothing. The sidecar's `ts-serve.json` proxies
  `https://<node>.<tailnet>` to `http://127.0.0.1:8787` and allows no Funnel.
- **`dashboard-local`** (profile `local`) — the same server on a node with no
  tailnet, readable on that host's loopback and nowhere else (`DASHBOARD-SPEC`).
  It gets there in two moves: the server is told to bind `0.0.0.0` *inside the
  container*, since a bind to the container's own loopback is reachable from
  nothing, and the port is published as
  `127.0.0.1:${DASHBOARD_PORT:-8787}:8787`, which keeps the page off every
  network the host is on. `DASHBOARD_PORT` moves the host side of that mapping
  only, and exists because the host may already have something on 8787 — the
  laptop's legacy SysV dashboard does.
- **`watchtower`** (profile `auto-update`) — how a node picks up new code: it
  polls for a new image tag and restarts the services into it. Enabled by
  label, so it touches this stack's containers and no others on the host. It
  runs with `WATCHTOWER_LIFECYCLE_HOOKS` on, and `WATCHTOWER_SCHEDULE` exists
  as an alternative to `WATCHTOWER_POLL_INTERVAL` for a node that would rather
  roll at a fixed time than poll — the two are mutually exclusive and
  watchtower exits fatally if given both, so setting the schedule means
  clearing the interval.
- **A roll defers to a running cycle.** Recreating a container kills the
  process group its cycle runs in, so before watchtower touches any agent-ops
  container it runs `deploy/docker/watchtower-pre-update.sh` inside it (the
  `com.centurylinklabs.watchtower.lifecycle.pre-update` label, on the shared
  block so every service carrying the image has it). The script exits **75**
  (`EX_TEMPFAIL`), which watchtower reads as "cancel this container's update
  and re-check on the next poll", whenever `lock.json` or `review-lock.json`
  is held: always bounded by **that pipeline's `lock_stale_after`**, and
  beyond that judged by who is asking. A lock the running container itself
  wrote (the recorded `host` matches) is held while its process is alive —
  the same judgement requirement 1's `acquire_lock` makes, so the hook
  protects exactly what a cycle would have respected. A lock written by any
  other container, or one carrying no `host`, is held **until released or
  stale, with no liveness check at all**: a pid is only meaningful in the PID
  namespace that minted it, and on a tailnet node the dashboard reads the
  scheduler's locks through the shared `state` volume. Either way a deferral
  can never outlast `lock_stale_after`, and the fail-closed side is the cheap
  one — a leftover foreign lock is taken over or removed within the hour by
  the next cycle (requirement 1 precedes the stand-down checks, so standby
  nodes clear it too), while a foreign `kill -0` answers for the wrong
  process in both directions, and watchtower undid a live deferral off
  exactly that answer once (issue #130): its restart map is keyed by *image*
  id, so the dashboard's wrong exit 0 led it to recreate the deferred
  scheduler sharing that image, stopped only by the name conflict with the
  never-stopped container. That name conflict remains the only backstop
  against a *second compose project* running the same image on one host: its
  own state volume is rightly separate, so it rolls whenever its own node is
  idle and its map entry still names the shared image — the deferred
  container survives because the create fails on its own name, at the price
  of a `Failed` count and a name-conflict error in watchtower's log each
  poll. It exits 0 when both are free, and also on any
  internal failure — not because a non-zero status would freeze the node's
  image, but because **75 is the only status watchtower defers on**: every
  other non-zero code is logged as a failed hook and the update proceeds
  regardless ("an exit code different than 0 or 75 (EX_TEMPFAIL) will not
  prevent watchtower from updating the container"). A hook that cannot answer
  therefore cannot protect anything whatever it returns, and 0 is simply the
  honest way to say so. The label carries a `pre-update-timeout` of 1 minute
  (watchtower's unit is minutes), and that bound **fails open** too: on
  expiry watchtower continues the update loop, so a container too wedged to
  answer inside the minute is rolled anyway. Setting the label to `0` would
  disable the timeout and fail closed, at the price of one wedged container
  stalling every node's updates indefinitely; the minute stands as the lesser
  hazard while the hook remains a handful of `jq` calls.
  `test/watchtower-pre-update.test.sh` pins all of this.
  The hook covers the automatic roll and nothing else: a manual `up -d`,
  `restart`, `down` or host reboot recreates containers without consulting
  watchtower, so the operating rule for those remains `--status` first.
- **A node's copy of this file is watched for drift.** A node holds its own
  `compose.yaml`, which no image roll can update — labels, service
  environment and mounts arrive only via a human running `docker compose up
  -d` on that host — so a merged compose change can otherwise sit inert on
  every node while the repository's own checks stay green (issue #131, which
  is what it cost to learn this). The file therefore mounts *itself*
  read-only into the agent-ops services (`./compose.yaml:/host/compose.yaml:ro`,
  on the shared block), and `lib/compose-drift.sh` diffs the mount against
  the image's own copy at `/app/deploy/docker/compose.yaml` — comments and
  blank lines aside, since what drifts in comments cannot change what a
  container runs. The reference tracks `main` by exactly the channel that
  already works, the image roll. The verdict — `{status: "in-sync"}`,
  `{status: "drifted", diff_lines: N}`, `{status: "unmounted"}`, or `null`
  outside a container — travels in the node's heartbeat (requirement 2.5)
  and is rendered on every dashboard's fleet strip (`DASHBOARD-SPEC.md`).
  `unmounted` is the bootstrap problem answering itself: a compose file too
  old to carry the mount is behind by construction, and the *check* reaches
  every node by image roll with no `up -d` required, so a node that cannot
  be verified says so from its first rolled image until its stack is
  re-created. What the mount cannot see — whether the running containers
  were created from the file, and watchtower's own environment, the one
  container nothing ever rolls — needs the Docker socket, which these
  containers rightly lack: `scripts/check-node-compose.sh` (component 12)
  answers those from the host. Merging a change to this file is not
  deploying it, and `.github/workflows/compose-deploy-reminder.yml` says so
  on every pull request that touches it — one marker-keyed comment naming
  the per-node ritual, posted once rather than per push.
- **A node's running image is watched for staleness against the registry.**
  Comparing nodes with each other (`version`, above) answers *divergence* —
  are the nodes on the same commit — but not *staleness*: a fleet that
  adopts one broken image at once agrees with itself perfectly and reads as
  healthy on that measure alone, which is exactly what happened across
  issues #149/#154. `lib/image-drift.sh` answers against a reference outside
  the fleet instead — `ghcr.io/poetic-poems/agent-ops:latest`'s own
  `org.opencontainers.image.revision` label, read anonymously over the OCI
  Distribution API (no GitHub `read:packages` scope needed) — never against
  `origin/main`, since a documentation-only merge publishes no image at all
  and would otherwise read as false staleness. The verdict —
  `{status: "current"}`, `{status: "behind", registry_commit,
  registry_created_at}`, `{status: "unverified", reason}`, or `null` for a
  node not running a CI-stamped image — travels in the node's heartbeat
  (requirement 2.5) and is rendered on every dashboard's fleet strip
  (`DASHBOARD-SPEC.md`) with a threshold that tolerates the ordinary
  mid-roll deferral. `scripts/check-node-image.sh` answers the same question
  by hand from a node's host, exec'd into the scheduler container to reuse
  the same library rather than duplicating a registry client there.
- Which profiles a node runs is set by `COMPOSE_PROFILES` in its `.env`, so the
  operator's command is `docker compose up -d` on every node regardless.
- Three named volumes carry everything that must survive a container being
  replaced: `state` (the node's cycle records, logs and locks), `claude-config`
  (the OAuth credentials, which refresh themselves and cannot be rebuilt from
  the image, and — via `CLAUDE_CONFIG_DIR` — the global config file that would
  otherwise sit outside it), and `workspaces`. A node updates by replacing its
  containers; these are what it keeps. Anything Claude Code writes that is not
  under one of these mount points is lost on the next roll, which is why the
  config directory is relocated rather than the volume list extended: a named
  volume cannot mount a single file.
- The dashboard service of either profile `depends_on` the scheduler. Both mount
  the `state` volume, and on a node's first start that volume is empty and is
  seeded from the image's mount point; two containers seeding it at once race,
  and one aborts the `up` with `mkdir … /cycles: file exists`. The dependency
  routes the first-run seed through a single container. On every later start the
  volume already exists, so it only orders startup.

### Target repositories

| Repo | GitHub | Work sources, in priority order |
|---|---|---|
| poetic (framework) | `Poetic-Poems/poetic` | 1. **security findings** · 2. **`issues:urgent`** · 3. **review-feedback** · 4. **merge-conflicts** · 5. **abandoned-drafts** · 6. failed Actions runs on `main` · 7. `issues:high` · 8. `TECH-DEBT.md` · 9. `issues:medium` · 10. project-review recommendations · 11. `issues:low` · 12. code-quality findings · 13. register-hygiene |
| poetic-fiddle (web app) | `Poetic-Poems/poetic-fiddle` | 1. **security findings** · 2. **`issues:urgent`** · 3. **review-feedback** · 4. **merge-conflicts** · 5. **abandoned-drafts** · 6. failed Actions runs on `main` · 7. `issues:high` · 8. `TECH-DEBT.md` · 9. `issues:medium` · 10. `implementation-plan` (its configured plan document, `docs/IMPLEMENTATION-PLAN.md`; next milestone task) · 11. project-review recommendations · 12. `issues:low` · 13. code-quality findings · 14. register-hygiene |

This is this installation's current `config.json`: its `repos` array names
these two repos and each one's `sources`, in this order. Unlike this document,
`prompts/coordinator.md` names neither repo — the Co-Ordinator's own copy of
this table is rendered from `config.json` at cycle time, not hand-written
here twice (requirement 4b), so this table is the one place a config change
needs an editorial update to stay accurate.

The `security` and `code-quality` sources draw on GitHub's own automated
analysis, not just files in the tree:

- **`security`** — open **Dependabot alerts** (vulnerable dependencies) and
  open **code-scanning alerts** (CodeQL and any other configured code-scanning
  tool) that carry a security severity. All Dependabot alerts are security by
  nature; a code-scanning alert counts here when its
  `security_severity_level` is set. This source is **first in every repo's
  list**, and, more strongly, **any security-related candidate takes
  precedence over every non-security candidate regardless of which source it
  came from** — including a GitHub issue labelled `security`/`vulnerability`
  or a `TECH-DEBT.md` entry flagged as a security concern. Security work is
  always prioritised.
- **`code-quality`** — the remaining open **code-scanning alerts** (those
  *without* a security severity: maintainability, correctness, and style
  findings) plus any other code-quality findings GitHub surfaces. Automated
  quality suggestions are more speculative and higher-volume than curated
  tech-debt or filed issues, so they are picked up only when nothing more
  deliberate is waiting.

The `register-hygiene` source draws on the repo's own per-item tech-debt
register, checked against the convention that register states for itself:

- **`register-hygiene`** — the repo's register failing `scripts/td-check.pl`
  (requirement 3i): an item file whose frontmatter disagrees with its
  filename, its repository's declared scope, or itself. **Last in every
  repo's list.** The repair is deterministic and touches
  nothing but the register, so it must never outrank substantive work; but a
  register that advertises finished work as outstanding misleads every later
  reader, human and agent alike, and this pipeline reads it as a work source.
  It is a *starting* source like any other, and so subject to back-pressure
  (requirement 2.2a). Its volume trends to zero, because each consumer repo
  also runs the same check in CI
  (`.github/workflows/tech-debt-register.yml`), which fails the pull request
  that would introduce the drift; this source exists for the drift that lands
  anyway — a register that predates the guard, a direct push, a merge that
  reintroduces it.

The `issues` source is **banded by the issue's own `Priority` field**, so it
occupies four separate ranks rather than one:

- **`issues:urgent`**, **`issues:high`**, **`issues:medium`**, **`issues:low`**
  — open GitHub issues whose organisation-level `Priority` issue field reads
  `Urgent`, `High`, `Medium` or `Low` respectively. An issue with **no**
  `Priority` set is **`Medium`** (requirement 15e), which is the rank the
  single, unbanded `issues` source used to hold — so an untriaged backlog ranks
  exactly where it always did, and setting the field is what moves an issue up
  or down.

  The four bands are one source, not four: they share the whole of the `issues`
  source's behaviour — the exclusions of requirement 16 (assigned, `blocked`,
  a question or discussion), the whole-thread read of requirement 14a, the bare
  issue number as the item ref, and the work order's `"source": "issues"`
  (requirement 21). Only the rank differs. Nothing downstream of selection can
  tell the bands apart, which is deliberate: the band is a statement about
  *when* the work is picked up, not about what the work is or how it is done.

  The `Priority` field is GitHub's native issue field, not a label and not a
  Projects v2 field, so it arrives on the ordinary REST issues endpoint in
  `issue_field_values` (the entry whose `issue_field_name` is `Priority`, read
  from its `single_select_option.name`). It is absent from `gh issue view
  --json`, which is why requirement 15e names the REST read. An issue whose
  `issue_field_values` is empty, or that carries no `Priority` entry, or whose
  entry cannot be read at all, is `Medium` — the field's visibility is
  `organization_members_only`, and a token that cannot see it must degrade to
  today's behaviour rather than to an unranked pile.

The `project-review` source draws on the weekly project-review pipeline's own
output (see `docs/REVIEW-PIPELINE-SPEC.md`), which lands in each repo via a
merged PR:

- **`project-review`** — the prioritised **recommendations** produced by the
  most recent project review, which live on the default branch under
  `reviews/project-review-YYYY-MM-DD/` as `03-recommendations.md` (the
  recommendation table and per-`R-NN` detail) paired with
  `04-improvement-prompts.md` (one ready-to-run agent prompt per
  recommendation). The Co-Ordinator reads the **latest** review folder's two
  files directly (`gh api .../contents/...`, no pre-fetch needed) and treats
  each recommendation as a candidate. A recommendation's **stable ref** is
  `review-<review-date>-R-NN` (e.g. `review-2026-07-20-R03`); that ref goes in
  the branch and PR so a claim (open PR) and a completion (merged PR) are both
  detectable later. The improvement prompt is the Implementor's brief and the
  recommendation's *Intended end state* is its acceptance. This source sits
  **below tech-debt and `issues:medium`** deliberately: the review already
  mirrors its debt-shaped recommendations into the tech-debt register
  (cross-referencing the `R-NN`), and those curated, status-tracked entries are
  the primary channel — the `project-review` source exists to pick up the
  review's remaining recommendations (typically smaller improvements) that were
  *not* also filed as tech-debt or an issue, so nothing the review surfaced is
  silently dropped. It ranks above `issues:low` and `code-quality` because a
  human-approved review recommendation is more deliberate than either an
  automated quality suggestion or an issue its own author has marked as the
  least pressing thing they filed. A recommendation whose text flags a
  **security concern** is security-related and so is caught by "security is
  always prioritised" like any other security candidate.

The `review-feedback`, `merge-conflicts` and `abandoned-drafts` sources are all
*finishing* sources — they carry an already-open pull request the rest of the way
rather than starting new work — and all are pre-fetched:

- **`review-feedback`** — pull requests this system raised on which a human has
  requested changes we have not yet answered (requirement 3c). Ranked second, and
  across all repos (requirement 15b).
- **`merge-conflicts`** — pull requests this system raised that are otherwise
  ready (for review or for merge) but whose `mergeable` is definitively
  `CONFLICTING` because the base advanced underneath them (requirement 3g). A
  rebase-and-resolve makes the PR mergeable again; until it is, a human cannot land
  it and nothing else on it can proceed. Ranked third, and across all repos
  (requirement 15d). Like `abandoned-drafts` its candidacy turns on something no
  event on the PR itself carries — the base moving, which GitHub reflects in
  `mergeable` a beat later — so the no-op fingerprint must account for it
  (requirement 3b).
- **`abandoned-drafts`** — draft pull requests this system raised and then
  abandoned: still open, still draft, carrying `pr_label` on a branch under
  `branch_prefix` (or `td/`), and untouched for at least
  `abandoned_draft_after_hours` (requirement 3e). A stage that timed out, hit a
  usage limit, or died leaves its draft PR behind as a stalled claim; finishing it
  costs less than starting fresh and turns the back-pressure slot it occupies —
  which nothing would otherwise clear — into a PR a human can merge.
  Ranked fourth, and across all repos (requirement 15c). Uniquely, its candidacy
  turns on the passage of time itself, which the no-op fingerprint must account
  for (requirement 3b) as it must for merge-conflicts' base-driven flip.

Because Dependabot and code-scanning alerts live behind paginated, verbose
GitHub APIs, the Script pre-fetches and normalises them once per cycle via
`scripts/gather-findings.sh` (a deterministic, model-free script) and injects
the compact result into the Co-Ordinator's runtime input, so the Co-Ordinator
does not spend model tokens paginating those endpoints itself (see
requirement 3a and 20).

Conventions shared by both repos (agents must honour all of these):

- `main` is protected: no direct pushes by anyone or anything; every change
  lands via a pull request, squash-merged, so **the PR title becomes the
  commit on `main` and must be in Conventional Commits format**.
- The tech-debt register holds deferred work as dated records carrying a
  status (`open` / `in-progress` / `resolved` / `not-debt`), one
  `tech-debt/<id>.md` file per record, frontmatter plus a Markdown body.
  Claiming and resolving are both frontmatter-only edits (`status:`, and on
  resolution `resolved:` and `ref:`), the body stays in place either way, and
  a file already on the default branch is never deleted or renamed. The
  "Claiming an item" workflow flips `status:` to `in-progress` and opens a
  **draft** pull request immediately, so the claim is visible; flip to
  `resolved` and mark the PR ready when done.
  `scripts/get-tech-debt-record.pl` resolves an ID to its record,
  `scripts/next-tech-debt-id.pl` allocates IDs, and
  `scripts/td-check.pl` cross-checks the register against its own rules (exit
  0 consistent, 1 problems). All three are canonical in `Poetic-Poems/poetic`
  and held here as byte-identical copies
  (`.github/workflows/td-tooling-drift.yml`).
- CI runs on every PR (build/lint/test workflows plus CodeQL and
  commit-format checks). A PR is not finished until its checks pass and
  `gh pr view --json mergeable,mergeStateStatus` reports it mergeable.
- `CHANGELOG.md` gets an entry for notable changes; other docs are as-built
  (no historical phrasing).

## Configuration

One `config.json` at the root of `agent-ops`, holding every tunable, and one
`config.schema.json` beside it stating that file's shape in a form a machine
can check (requirement 1b). The two are different documents for different
readers: this table and the README's are the prose — what a key is *for*, and
what choosing it wrong costs — and the schema is the enforceable part, which
is why `scripts/doctor.sh` reads the schema rather than either table. The
values below are the confirmed defaults; the README must document each key,
and the schema must carry every one of them.

<!-- config-table:start id=main -->
| Key | Value | Notes |
|---|---|---|
| `repos` | `["Poetic-Poems/poetic", "Poetic-Poems/poetic-fiddle"]` | Work-source lists per repo as in the table above (`security`, `issues:urgent`, `review-feedback`, `merge-conflicts`, `abandoned-drafts`, `failed-runs`, `issues:high`, `tech-debt`, `issues:medium`, `implementation-plan`, `project-review`, `issues:low`, `code-quality`, `register-hygiene`); structure the config so a repo or source can be added without code changes. The `issues:<band>` tokens are the one source that appears more than once — the same `issues` source at four ranks...[continued below](#extended-notes-repos) |
| `state_dir` | `~/.local/state/poetic-agents` | Lock, shared log, per-cycle stage transcripts. |
| `workspace_root` | `~/.cache/poetic-agents/workspaces` | Ephemeral clones live and die here, including the state repository's mirror. |
| `state_repo` | `Poetic-Poems/agent-ops-state` | The private repository through which `state_dir` replicates between nodes (requirement 2.5). Its `main` carries the small shared surface: the claim registry (requirement 17a) and the fleet flags `fleet/disabled.json` and `fleet/limit.json` (requirements 2.3a and 2.1). Unset means a single-node operation: every mode of `scripts/state-sync.sh` becomes a no-op, and the fleet-flag reads and writes quietly do nothing. |
| `cycles_retained` | `200` | Cycle directories kept in the replicated mirror — about eight days of hourly cycles. Bounds a repository that is force-pushed after every cycle. The node's own `state_dir` is bounded by `state_local_cycles_retained` instead. |
| `state_local_cycles_retained` | `1000` | Cycle and review directories the node's *own* `state_dir` keeps — about six weeks of hourly cycles; the same push that replicates prunes to it (requirement 2.5). Deliberately far above `cycles_retained`, so the local machine is always the longer record, with a floor of one protecting the cycle being recorded. `STATE_SYNC_LOCAL_RETAINED` overrides it for tests. |
| `state_local_streams_retained` | `50` | Cycle and review directories whose stage event streams (`<stage>.stream.jsonl`, requirement 4d) are kept; the push that replicates prunes to it (requirement 2.5). Far below `state_local_cycles_retained` because a stream is a different order of size from the record holding it — a cycle directory without them is kilobytes, one Reviewer stream megabytes — so streams go early and their records stay. Streams never reach the state repository. `STATE_SYNC_STREAMS_RETAINED` overrides it for tests. |
| `log_retained_bytes` | `2000000` | Size at which `scripts/rotate-logs.sh` rotates `dashboard.log`, `state-sync.log`, `cron.log` and `review-cron.log` (requirement 2.6). `log.jsonl` and `review-log.jsonl` are never rotated regardless of size. `ROTATE_LOGS_RETAINED_BYTES` overrides it for tests. |
| `log_generations` | `3` | Rotated generations of each log kept beside the live file (`<name>.1` … `<name>.<log_generations>`), floored at one. `ROTATE_LOGS_GENERATIONS` overrides it for tests. |
| `coordinator_model` | `claude-haiku-4-5-20251001` | Selection is cheap triage. |
| `implementor_model_default` | `claude-sonnet-5` | Any change that affects runtime behaviour. |
| `implementor_model_trivial` | `claude-haiku-4-5-20251001` | Docs-, comment-, or register-only items. The Co-Ordinator classifies each item and records its reasoning in the work order. |
| `reviewer_model_default` | `claude-sonnet-5` | Reviews of `low`- and `medium`-complexity work (requirement 8a). |
| `reviewer_model_complex` | `claude-opus-5` | Reviews of `high`-complexity work (requirement 8a). Empty falls back to `reviewer_model_default`, which switches the escalation off. |
| `enabler_model` | `claude-opus-5` | The Enabler (requirement 35). The highest-tier model this system runs, affordable only because the eligibility rule of 35a engages it rarely and the claims of 35c stop it being engaged twice. Empty disables the stage. |
| `enabler_assignee` | `warwickallen` | GitHub login assigned to every escalation issue the Enabler raises (requirement 36a). Required whenever `enabler_model` is set: the Script exits with an error at startup rather than run with it unset, since an unassigned escalation would not be excluded by requirement 16.4 and could be selected as work by the pipeline itself. |
| `enabler_after_coordinator_cycles` | `3` | How many distinct cycles that ran a Co-Ordinator to completion must follow a block before the item becomes Enabler-eligible (requirement 35a). Counted in cycles rather than hours because a fleet stood down on a usage limit or a switch has not "had a chance" at anything. |
| `refinement_after_coordinator_cycles` | *(`enabler_after_coordinator_cycles`)* | The same threshold, applied instead of `enabler_after_coordinator_cycles` when the block's `kind` is `needs-refinement` (requirement 35a). Unset, it inherits `enabler_after_coordinator_cycles`'s value, which is what keeps the two classes aging identically until fleet behaviour justifies pulling them apart. |
| `enabler_recheck_hours` | `72` | How long after an examination the Enabler may examine the same item again (requirement 35a). Requirement 18a catches most of the failure mode `TECH-DEBT.md` TD26072101 recorded — a GitHub issue gaining evidence after it was blocked — same-cycle, off the issue's own `updated_at`; this bound is the lever for everything that leaves no such signal: every non-issue blocked source, and a blocker that clears without a comment landing on the issue. `0` disables re-examination. |
| `enabler_escalation_label` | `enabler-escalation` | Applied to every issue the Enabler raises, for the human's filter and for the duplicate guard of requirement 36a. It must not be `blocked`: that label is an exclusion criterion for the `issues` source (requirement 16.4) and would double-count with the assignment. |
| `needs_refinement_label` | `needs-refinement` | The label the Script projects onto an issue-type item while its refinement block is open (requirement 34e), and removes when the block clears. Also the label a human applies by hand to flag an item themselves, which the Script scans every repo's issues for and records as the same kind of block (requirement 34g) — removing it while that block is open clears it the same way. Empty disables both directions: the log is the record, so the mechanism is unaffected and the item still...[continued below](#extended-notes-needs_refinement_label) |
| `refinement_max_per_engagement` | `3` | How many refinement-class items one Enabler engagement takes on (requirement 35d); ordinary blocked items are uncapped and are never displaced by them. The cap exists because the backlog of items silently skipped before requirement 16a existed is unbounded, and an engagement spent entirely on old vagueness would delay the pull request nobody can see. `0` removes the class from engagements entirely — blocks are still recorded, and the items wait. |
| `unvoid_label` | `unvoided` | The label a human applies on GitHub to ask for a void to be reopened (requirement 34f). No stage here ever applies it, so requirement 34c's "only a human may clear a void" is unchanged; what it adds is a way to say so from the issue itself. It must not be `blocked`, for the reason given against `enabler_escalation_label`. |
| `prompt_overrides` | `{}` | Per-installation prompt extension/replacement (requirement 4a): an object keyed `coordinator`/`implementor`/`reviewer`/`enabler`, each holding `extend` (an array of file paths, appended in order) and/or `replace` (a file path substituted for that stage's shipped `prompts/<stage>.md`). A relative path resolves against `state_dir`. Empty or a stage absent from it changes nothing for that stage. |
| `pr_label` | `autonomous-agent` | Applied to every PR this system raises. |
| `branch_prefix` | `agent/` | Branch name `agent/<item-slug>`, e.g. `agent/td26051201-fix-xyz`. |
| `max_open_agent_prs` | `8` | Back-pressure: total open PRs (draft or ready) carrying `pr_label`, across all repos, plus live claim-registry entries (requirement 2.2). |
| `candidates_max` | `3` | How many ranked candidates the Co-Ordinator returns; the Script claims down the list (requirement 17a), so alternates turn a lost race into the next-best item instead of a wasted cycle. |
| `claim_ttl_hours` | `6` | Age beyond which `lib/claim.sh gc` sweeps a claim-registry entry — far beyond a whole cycle (120 min Implementor + 60 min Reviewer), so only a dead node's claim ever expires. The branch itself is deleted only if untouched and PR-less. |
| `abandoned_draft_after_hours` | 4 h | How long a draft PR this system raised may sit without real activity (requirement 3e's clock, not GitHub's raw `updatedAt`) before it counts as abandoned and finishing it becomes selectable work (`abandoned-drafts` source, requirement 3e). Comfortably beyond a whole cycle, so a draft merely being worked never qualifies; short enough that a genuinely stalled draft is picked up the same day. Raised 3 h → 4 h alongside the interim timeout raises of #203, which took a worst-case...[continued below](#extended-notes-abandoned_draft_after_hours) |
| `human_nudge_idle_hours` | 24 h | Hours an approved, mergeable, CI-green pull request this system raised may sit idle before `scripts/sweep-human-visibility.sh` posts a one-time nudge comment naming `enabler_assignee` (requirement 38c). `0` disables the nudge only — the sweep's self-healing review request (requirement 38a) is unconditional. poetic-fiddle #170 sat approved and green for 6.8 days with nothing asking anyone to look; this is the backstop for whatever the live review request itself does not catch. |
| `crash_loop_after` | `4` | Consecutive same-detail Co-Ordinator failures, fleet-wide with no intervening success, before the Script escalates the crash loop as an issue (requirement 2.7). At four nodes an hourly deterministic failure crosses this within about an hour. `0` (or absent) disables the check. |
| `crash_loop_repo` | `Poetic-Poems/agent-ops` | Where requirement 2.7's escalation issue is filed — the pipeline's own repository, because a Co-Ordinator that cannot run belongs to no target repo's backlog. Empty disables the check. |
| `timeout_coordinator` | *(unset)* | An override for the wall-clock backstop of requirement 4e, taking precedence over the derivation of requirement 4f. Absent is the normal case and the intended one: a configured value wins permanently, so setting it turns the self-tuning off for that actor. |
| `timeout_implementor` | *(unset)* | As `timeout_coordinator`, for the Implementor. The interim raise to 120 this key carried (#203, #209) has gone with the fixed cap it belonged to: the shipped prior is 150 and the derivation moves from there. |
| `timeout_reviewer` | *(unset)* | As `timeout_coordinator`, for the Reviewer. This is the key #203 was opened about: it was raised 30 → 45 → 60 in two days, and 45 lasted six hours before a complex-model review of a 16-file diff consumed all of it. Complex-model reviews are killed roughly six times as often as default-model ones, so a single fixed number spans two quite different populations — which is why the derivation keys on the model. |
| `timeout_enabler` | *(unset)* | As `timeout_coordinator`, for the Enabler — which, spanning repositories, has a single `(enabler, *, model)` cell. |
| `inactivity_coordinator` | *(unset)* | An override for the watchdog threshold of requirement 4e, taking precedence over the derivation of requirement 4f. Absent is the normal case; `0` disables the watchdog for that actor and leaves the backstop as the only cap. |
| `inactivity_implementor` | *(unset)* | An override for the watchdog threshold of requirement 4e, taking precedence over the derivation of requirement 4f. Absent is the normal case; `0` disables the watchdog for that actor and leaves the backstop as the only cap. |
| `inactivity_reviewer` | *(unset)* | An override for the watchdog threshold of requirement 4e, taking precedence over the derivation of requirement 4f. Absent is the normal case; `0` disables the watchdog for that actor and leaves the backstop as the only cap. |
| `inactivity_enabler` | *(unset)* | An override for the watchdog threshold of requirement 4e, taking precedence over the derivation of requirement 4f. Absent is the normal case; `0` disables the watchdog for that actor and leaves the backstop as the only cap. |
| `lock_stale_after` | *(unset)* | A floor under the derived value of requirement 4f, not the value itself: the threshold is the sum, over the four actors, of the widest backstop each could draw this cycle, plus slack. Deriving it is the point — an assertion checked against fixed caps had to be re-derived by hand every time any of them moved, three times in two days. Erring long is close to free: a dead holder is taken over on its pid rather than its age, so this bounds only how long a live but hung cycle may hold on. |
| `stage_budget` | *(unset)* | Tuning for the derivation of requirement 4f: `gap_multiplier` and `shrinkage_runs` shape the watchdog estimate, `increase_factor`, `decrease_after_runs`, `decrease_step_min`, `kill_rate_slo` and `ceiling_multiple` shape the backstop controller, and `window_days`/`window_runs` bound what either looks at. Defaults live in `lib/stage-budget.sh`, not here, on requirement 4e's reasoning: a value an installation must set is a value it can set wrongly. |
| `limit_cooldown_default` | 3 h | Stand-down period after an ordinary/transient usage-limit error whose reset time cannot be parsed. A weekly/monthly match with no parseable reset time uses the longer `LIMIT_LONG_COOLDOWN_HOURS` fallback in `lib/limit-detect.sh` instead (see requirement 10) — not this key. |
| `disable_default_ttl` | 4 h | How long `--disable` lasts when neither `--for` nor `--until` says (requirement 2.3). Long enough to cover an editing session, short enough that a forgotten switch costs a few cycles rather than every future one. |
| `none_selected_recheck_hours` | 24 h | The no-op short-circuit's safety valve (requirement 3b): the Co-Ordinator is engaged regardless once the last `none-selected` is this old, even if nothing changed. Bounds how long a gap in fingerprint coverage can stall the pipeline. `0` disables the valve — don't. |
| `image_behind_grace_hours` | 3 h | The dashboard badge's (and `scripts/check-node-image.sh`'s) tolerance for a node behind the registry's newest image (`lib/image-drift.sh`, requirement 2.5, #155) before it turns amber / fails: a roll defers while a cycle is in flight, so being behind an image published more recently than this is the ordinary mid-roll state, not a fault. |
| `dashboard_refresh_seconds` | `5` | How often an open dashboard tab reloads to pick up freshly-written data (`docs/DASHBOARD-SPEC.md`). Match it to the heartbeat cadence: a shorter interval re-reads a file nothing has rewritten, a longer one shows a cycle that has already moved on. |
| `schedule.cycle_hours` | `*` | The hour field of the implementation cycle's crontab line, rendered by `deploy/docker/render-crontab.sh`; `*` is every hour. |
| `schedule.excluded_minutes` | `[0]` | Minutes `CYCLE_MINUTE` (env or the per-node hash) may never land on, rendered from `deploy/docker/crontab.tmpl`. Poetic's own value excludes `0` because its hourly sync workflow owns the top of the hour; a deployment with no such conflict ships `[]`. Excluding every minute of the hour is a misconfiguration the renderer refuses rather than spinning on. |
| `schedule.excluded_minutes_reason` | `"poetic's hourly sync workflow owns the top of the hour"` | Free text recording *why* `excluded_minutes` excludes what it does; read by nothing, kept for the next reader. |
| `schedule.review_hour` | `3` | The hour the review tick fires. |
| `schedule.review_offset_minutes` | `29` | Minutes past `CYCLE_MINUTE` (mod 60) the review tick's minute is set to, keeping one node's two heavy pipelines apart within the hour. |
| `schedule.heartbeat_minutes` | `5` | Interval, in minutes, of the dashboard heartbeat cron line (`publish-dashboard-launcher.sh`). |
| `schedule.state_sync_push_minutes` | `5` | Interval, in minutes, of `state-sync.sh push` (requirement 2.5). |
| `schedule.state_sync_fetch_minutes` | `7` | Interval, in minutes, of `state-sync.sh fetch` (requirement 2.5). |
| `schedule.log_rotation_minute` | `19` | The minute past every hour `rotate-logs.sh` runs (requirement 2.6). |
<!-- config-table:end -->

Model IDs are pinned in config (one place to update); do not use floating
aliases in the launch commands.

Every `*_model` key above (and `review.model` in `docs/REVIEW-PIPELINE-SPEC.md`)
accepts a bare id (`claude-sonnet-5`) or a provider-qualified one
(`anthropic/claude-sonnet-5`), resolved per requirement 1a. Anthropic is the
only executable provider (D12, `docs/ROADMAP.md`), so the two forms are the
same value; no other qualifier is accepted.

<!-- config-table:notes id=main -->

### Extended notes: `repos`

Work-source lists per repo as in the table above (`security`, `issues:urgent`, `review-feedback`, `merge-conflicts`, `abandoned-drafts`, `failed-runs`, `issues:high`, `tech-debt`, `issues:medium`, `implementation-plan`, `project-review`, `issues:low`, `code-quality`, `register-hygiene`); structure the config so a repo or source can be added without code changes.

The `issues:<band>` tokens are the one source that appears more than once — the same `issues` source at four ranks (requirement 15e). A repo that lists none of them has the issues source off; one that lists a subset sees only issues in those bands.

A repo entry may also carry `implementation_plan_path` — the path, relative to that repo's root, of its plan document; required whenever `sources` lists `implementation-plan` (requirement 3k), since that source has no path of its own outside this config. poetic-fiddle's is `docs/IMPLEMENTATION-PLAN.md`.

A repo entry may also carry `nice` — an optional integer from `-19` to `19` (absent means `0`), after Linux `nice`: each repo's default-branch staleness age is multiplied by `1.25^(-nice)` (each step of `nice` is a 1.25x change in attention), so a negative value buys the repo earlier attention and a positive one later. It biases the walk but never starves a repo — the global tiers still outrank the walk, and a repo that alone has qualifying work is selected regardless of its `nice`. The Script refuses to start a cycle if `nice` is not an integer in that range.

### Extended notes: `needs_refinement_label`

The label the Script projects onto an issue-type item while its refinement block is open (requirement 34e), and removes when the block clears.

Also the label a human applies by hand to flag an item themselves, which the Script scans every repo's issues for and records as the same kind of block (requirement 34g) — removing it while that block is open clears it the same way.

Empty disables both directions: the log is the record, so the mechanism is unaffected and the item still reaches the Enabler, but there is nothing to scan for and a human's label does nothing.

It must not be `blocked` — that label is an exclusion criterion for the `issues` source (requirement 16.4), so projecting it would make the item unselectable even after the refinement landed, the same trap noted against `enabler_escalation_label`.

### Extended notes: `abandoned_draft_after_hours`

How long a draft PR this system raised may sit without real activity (requirement 3e's clock, not GitHub's raw `updatedAt`) before it counts as abandoned and finishing it becomes selectable work (`abandoned-drafts` source, requirement 3e). Comfortably beyond a whole cycle, so a draft merely being worked never qualifies; short enough that a genuinely stalled draft is picked up the same day.

Raised 3 h → 4 h alongside the interim timeout raises of #203, which took a worst-case Implementor-plus-Reviewer cycle to 180 minutes and would otherwise have left this threshold no margin at all.

<!-- config-table:notes-end -->

## The Human Gate

The only branch this system protects is each repository's default branch.
No agent may push to it, or approve or merge a pull request targeting it —
GitHub's branch protection enforces this anyway. A human does both, on every
PR this system raises.

Every other branch **created by this system** (i.e. under `branch_prefix`)
is entirely at the agents' disposal: the Reviewer may amend, add to, rebase,
or force-push such a branch as it judges best. Agents must not rewrite
branches outside `branch_prefix` — those belong to humans, and the target
repos' own rule (force-pushing requires explicit instruction) applies.

The Reviewer's purpose is to spend cheap model time so that the Human
Reviewer's time is spent on work that is already close to mergeable. The
human gate is the only point at which a human is required; everything else
runs unattended.

## Requirements

### The Script (`agent-cycle.sh`)

1. **Lock.** On start, acquire a lock file in `state_dir` recording PID,
   start time, and the writer's hostname (`host` — on a containerised node
   the container, which is the PID namespace the recorded PID is meaningful
   in; the watchtower pre-update hook reads it, see the node stack section).
   A pid is only meaningful in the PID namespace that minted it, so a lock
   whose recorded `host` differs from this run's own is judged by host, not
   pid: it was written by a container that is gone by construction, taken
   over immediately — no liveness check, no process-group kill — logging the
   same `warning`. Only a lock whose `host` matches (or carries none, from
   before this stamp existed) is judged by liveness: if held by a live
   process younger than `lock_stale_after`, log `cycle-skipped` and exit 0;
   if the holder is dead or older than `lock_stale_after`, end its whole
   process group if still alive — TERM first, then a polled grace of up to
   20 seconds for the process to exit, then KILL — log a `warning` (a stale
   cycle indicates a fault — it should not occur in normal operation), take
   the lock, and continue. The grace exists for requirement 9c: TERM is what
   invites the doomed cycle's own signal handler to write its
   `attempt-failed`, release its claim and log its `cycle-end`, and it is
   sized to that handler's worst case (one process-group kill, one log
   append, one 8-second-bounded claim release). Polled rather than slept, so
   a cycle that records and exits in one second costs one second.
1a. **Model id resolution (D12 groundwork).** Every model key read from
   config — `coordinator_model`, `implementor_model_default`,
   `implementor_model_trivial`, `reviewer_model_default`,
   `reviewer_model_complex`, `enabler_model` — is resolved immediately after
   being read, before the lock and before any stage may launch: a bare id
   (`claude-sonnet-5`) means `anthropic/claude-sonnet-5`; an
   `anthropic/`-qualified id has the qualifier stripped to the same bare id;
   a qualifier naming any other provider is a fail-fast config error naming
   the offending key, not a value ever passed to `claude --model`. An empty
   value (the "disable this stage" convention `reviewer_model_complex` and
   `enabler_model` both use) passes through unresolved. `review-cycle.sh`
   applies the same resolution to `review.model`
   (`docs/REVIEW-PIPELINE-SPEC.md`). Both scripts share one implementation,
   `lib/model-id.sh`'s `resolve_model_id`, so the two pipelines can never
   drift on what counts as a supported provider.
1b. **The configuration has a machine-readable schema, and it is the startup
   gate both pipelines run on.** `config.schema.json` states the shape of
   `config.json` — every key an installation may set, its type, its
   constraints, and the value the code falls back to when it is absent. It
   covers both pipelines' keys, including the `review` object of
   `docs/REVIEW-PIPELINE-SPEC.md`, because there is one configuration file
   and a schema that described half of it would licence the other half to
   drift. Every object in it is closed (`additionalProperties: false`), which
   is the point: an unread key is a default nobody chose, so a misspelling is
   otherwise indistinguishable from a deliberate omission for as many cycles
   as it takes a human to notice. `lib/config-schema.sh` validates a config
   against it, implementing the subset of JSON Schema the file uses and no
   more; the schema may use only keywords that library implements, which
   `test/config-schema.test.sh` asserts by reading the keywords back out of
   the schema — a validator that silently ignores a keyword is worse than no
   validator, because it reports the configuration sound. Both
   `agent-cycle.sh` and `review-cycle.sh` call it at startup, immediately
   after `CONFIG_FILE` is known and before any individual key is read from it
   — the same fail-fast position requirement 1a's model-id resolution
   occupies, and well before the lock. A validation failure is fatal and
   names every offending path at once, the way the retired `nice` guard
   already named every offending slug at once: one error per run turns a
   five-key typo into one cycle to fix, not five. `scripts/doctor.sh`
   (component 14) is what an operator runs ahead of time, against the same
   library function, so its verdict and the Script's own refusal can never
   disagree. The schema is also the single source for the three prose
   configuration tables — this document's, `docs/REVIEW-PIPELINE-SPEC.md`'s
   and the README's — each leaf key's `x-docs` fields carrying the prose,
   `scripts/render-config-table.sh` (component 16) rendering it into the
   documents' marked regions and gating it in CI, so a key can no longer be
   added to the schema and forgotten in a prose copy the way `unvoid_label`
   and `state_local_cycles_retained` both once were.

   The schema is likewise the single statement of the *values* a reader falls
   back to, and not merely a description of them. `lib/config-schema.sh`'s
   `config_defaults` merges a config with every `default` the schema declares
   — recursively, treating an explicit `null` exactly as absent (the two cases
   jq's own `//` treats alike), filling each item of an array such as `repos`
   on its own, and synthesising an absent object whole from its leaves' own
   defaults so `schedule` may be omitted entirely — and every reader of
   `config.json` reads that merge rather than a `// literal` of its own:
   `agent-cycle.sh`, `review-cycle.sh`, `scripts/doctor.sh`, `lib/claim.sh`,
   `lib/labels.sh`, `scripts/state-sync.sh`, `scripts/rotate-logs.sh`,
   `scripts/sweep-orphan-branches.sh`, `scripts/publish-dashboard.sh` and
   `deploy/docker/render-crontab.sh`. A default therefore exists in one place,
   and each of those scripts requires `config.schema.json` beside
   `config.json` at runtime. The merge performs no validation of its own — a
   config that fails the gate above still merges, defaults and all — which is
   what lets `doctor.sh` go on diagnosing a config the Script would refuse.
   Three kinds of fallback are deliberately not schema defaults and stay in
   code: one that holds *between* two keys, of which
   `refinement_after_coordinator_cycles` inheriting
   `enabler_after_coordinator_cycles` (requirement 34e) is the case in point;
   readers that must depend on nothing but bash, `jq` and `config.json` by
   design, so that what they read cannot drift from what is actually
   deployed — `deploy/docker/watchtower-pre-update.sh`, reading three keys
   (`state_dir`, `lock_stale_after`, `review.lock_stale_after`) that carry no
   schema `default` to take, and `scripts/check-node-image.sh`'s in-container
   grace read, which runs inside whatever image the node is currently running
   and so must stay correct against an image that predates `config_defaults`
   entirely — its `image_behind_grace_hours` key does carry a schema
   `default`, but the read stays a literal `// 3` on principle rather than on
   necessity; and the shipped priors of the two self-tuning stage caps
   (requirement 4f), which live in `lib/stage-budget.sh`'s
   `STAGE_BUDGET_PRIORS`. The last is the one case where a `default` here would
   be actively wrong rather than merely redundant: the `timeout_*`,
   `inactivity_*` and `review.timeout_review` / `review.inactivity_review` keys
   are *overrides*, and a reader distinguishes "configured" from "absent" only
   by the key's absence. A `default` on `$defs/inactivityMinutes` or
   `$defs/timeoutMinutes` would be merged in by `config_defaults`, read as an
   explicit override, and win permanently — pinning the cap at the injected
   value and leaving the derivation unreachable. Both `$defs` therefore carry
   none, and the keys' documented value stays *(unset)*.

   The schema being a gate retires the two startup guards it wholly
   subsumes: `nice`'s range (requirement 3) and `prompt_overrides`' shape
   (requirement 4a) are both fully expressible as `type`/`minimum`/
   `maximum`/`additionalProperties` on a single object, so neither has a
   hand-written check left in `agent-cycle.sh` or
   `lib/prompt-overrides.sh`. Two guards stay in code rather than moving into
   the schema, because each holds *between* two keys, which
   `additionalProperties`/`required`/etc. on one object cannot state: the
   Enabler's assignee (requirement 35) and the implementation-plan path
   (requirement 3k). Both are shared, not duplicated, between
   `agent-cycle.sh` and `scripts/doctor.sh` — `lib/config-schema.sh`'s
   `config_enabler_assignee_ok` and `config_missing_plan_path_repos` are the
   one implementation each script calls, so the Script's refusal and
   `doctor.sh`'s `fail` can never drift on what counts as a fault.
2. **Stand-down checks.** Each check logs its reason and exits cleanly:
   1. *Usage-limit cooldown*: the same signal arrives on two carriers, and
      the **later** `resume_at` wins. The log union's most recent `limit-hit`
      is as fresh as the last state-sync fetch; `fleet/limit.json` on the
      state repository's main is read live, which is what lets a limit one
      node hit a minute ago stop this cycle now rather than a fetch interval
      from now. If the winning `resume_at` is still in the future, stand
      down. The flag is written by whichever node hits a limit (requirement
      10's `limit_decide` supplies `resume_at`/`class`/`reset_known`, plus
      the node's name and a timestamp), **extend-only**: a writer never
      shortens an existing `resume_at`, so concurrent hits converge on the
      latest resume whatever order their contents-API writes land in. The
      write is best-effort — on failure the node logs a `warning` and relies
      on the union to carry its `limit-hit` to the fleet.

      Both carriers can be retired early, two ways — automatically by the
      probe of 1b when `reset_known` is false, or by hand with
      `--clear-limit` (requirement 12) — and both retirements are the same
      write: delete `fleet/limit.json` and log a `limit-cleared` event, which
      the union's reduction — most-recent-wins over `limit-hit` **and**
      `limit-cleared`, in `lib/limit-detect.sh` so all four readers share it
      — treats as superseding every earlier hit. Deleting rather than
      shortening the flag is what keeps extend-only intact for the
      concurrent-hit case it exists for.

      A stand-down must have an exit that does not depend on a cycle running,
      because this check runs before any stage launches: while it holds, no
      cycle can reach a success, so nothing inside the pipeline can ever
      clear it. Without `--clear-limit` the only exit was `resume_at` passing
      — and when `reset_known` is false that is an invented time, so a
      stand-down could outlive its limit by up to `LIMIT_LONG_COOLDOWN_HOURS`
      with no way to say so. It did: a spend cap lifted on 2026-07-26 left the
      fleet down for a further 22 hours — and again on 2026-07-28, when a
      spend-cap message that actually recorded a 5-hour session window
      meeting the exhausted cap stood the fleet down for 24 hours over a
      limit that cleared within one. Requirement 1b is the automatic exit
      those two incidents argue for; `--clear-limit` remains the manual
      override.

      The logged reason states whether `resume_at` is a stated reset or an
      estimate, and `--status` reports the stand-down alongside the switch.
      Both answer "why is nothing happening?", and a status that knew only
      about the switch is how a stale cooldown went a day unexplained.
   1b. *An estimated stand-down probes its own exit.* When the governing
      record's `reset_known` is false, `resume_at` is this system's invented
      time and carries no information about the limit — so before standing
      down, the Script spends one minimal headless invocation of
      `implementor_model_trivial` (a fixed one-line prompt, 180 s timeout,
      transcript kept as `limit-probe.out` in the cycle record) and classifies
      it with `limit_probe_verdict` (`lib/limit-detect.sh`, regression-tested
      against canned transcripts): the limit phrase anywhere in the transcript
      is `limited`; otherwise a well-formed envelope with `is_error: false`
      and a non-empty `result` is `clear`; anything else — a timeout, a
      network failure, an empty file — is `inconclusive`. On `clear` it
      retires both carriers exactly as `--clear-limit` would (the
      `limit-cleared` event names `auto-probe@<node>` as `by`) and the cycle
      proceeds; on `limited` it records the re-observed hit through
      requirement 10 — whose parse also upgrades `reset_known` to true if the
      probe's message finally states a reset, stopping further probes until a
      time that is real — and stands down; on `inconclusive` it changes
      nothing and stands down, with the verdict appended to the logged
      reason either way.

      The economics run the right way round on both sides: a limited account
      answers the probe with the limit message at no token cost, and an
      unlimited one answers once for a fraction of a cent — the first `clear`
      verdict retires the stand-down fleet-wide, so the gate stops firing.
      A *stated* reset is never probed (the message named the time; asking
      earlier is the one spend that buys nothing), and `--dry-run` never
      probes (a cycle that promises to change nothing must not write
      `limit-cleared`, and a verdict it would have to ignore is pure cost).
   1a. *Claim GC*: run `lib/claim.sh gc` (requirement 17a) — best-effort,
      skipped on `--dry-run` — so registry entries a dead node left behind
      are swept before back-pressure counts them. Every node runs it; no
      coordination is needed, because a registry delete is sha-guarded and a
      claim branch is deleted only if unmoved and PR-less, so the worst race
      outcome is a no-op.
   2. *Back-pressure*: if the number of open PRs labelled `pr_label` across
      all configured repos (drafts included), **plus the live claim-registry
      entries for those repos** (requirement 17a — work a node has claimed
      but not yet surfaced as a PR; each entry is dropped the moment its PR
      exists), is ≥ `max_open_agent_prs`, stand down. This is the primary
      throttle on both spend and on the human gate silting up. The count is
      approximate by design: N nodes can pass it simultaneously, so the
      stated bound is `max_open_agent_prs + (nodes − 1)`, transient.

      The logged reason — of the stand-down here and of the restriction
      warning in 2.2a — states the count's composition:
      `(N ready + N draft + N unraised claim(s))`. A ready PR is the human's
      queue; a draft is work in flight (the Implementor's own claim marker,
      requirement 23); an unraised claim is a registry entry whose PR does
      not yet exist. Whether the cap stood the fleet down because the queue
      was genuinely full, or fired early on in-flight work, is exactly what
      a cap-tuning decision needs — and it must be readable from the log
      line alone, because the PRs behind a historical count are merged or
      closed by the time anyone asks, leaving cycle-record archaeology as
      the only other answer.
2.2a. **Back-pressure throttles starting work, not finishing it.** Compute the
   count in 2.2 but **defer the stand-down** until the sources are gathered
   (requirements 3c, 3g and 3e). If back-pressure has tripped *and* any
   `review_feedback`, `merge_conflicts` or `abandoned_drafts` candidate exists, do
   not stand down: restrict every repo's `sources` to
   `["review-feedback", "merge-conflicts", "abandoned-drafts"]` and continue. Only
   stand down when the count is over and nothing is waiting to be finished. All
   three are *finishing* sources — they complete an already-open PR rather than
   opening a new one — and two are doubly apt here, because they already hold
   back-pressure slots the cap counts: an abandoned draft occupies a slot nothing
   will clear until the draft is finished, and a conflicted PR occupies one the
   human cannot merge to free until it is rebased.

   Without this the pipeline deadlocks exactly when it is most stuck.
   `max_open_agent_prs` PRs all sitting on "changes requested" is a state the
   system can only escape by answering them — and the plain check stands the
   cycle down before the Co-Ordinator ever runs, so the one source that could
   clear them is never reached. The pipeline dies silently, and the fix
   (merge or close something by hand) is invisible unless you already know.

   The restriction preserves back-pressure's stated purpose exactly: the system
   still cannot open a *new* PR while the gate is full; it can only finish what
   is already in it, which is the one activity that *un*-silts the gate.
   Implement it by narrowing the `sources` lists rather than by adding a mode
   flag: the Co-Ordinator is already told the runtime input's `sources` are
   authoritative over its own table (requirement 15), so a source it cannot see
   is a source it cannot select — no new prompt concept, and nothing for it to
   reason around. The pre-fetched `issues` array (requirement 3j) is emptied
   along with the narrowing — it is the one array that carries whole threads,
   and paying the Co-Ordinator to read candidates it cannot pick is the exact
   spend this gate exists to stop; the other non-finishing arrays are compact
   enough that stripping them would buy nothing.
2.3. **The switch.** A file, `state_dir/disabled.json`, whose presence stops
   cycles starting. Checked *before* the lock and before any `gh` call — a
   disabled pipeline should cost nothing — and honoured by both this Script and
   `review-cycle.sh` (`docs/REVIEW-PIPELINE-SPEC.md`, R2a) through one shared
   implementation (requirement 34a), with `agent-cycle.sh` the only writer.
   Managed by three flags that manage the switch and run no cycle:
   `--disable [<reason>] [--for <90m|4h|2d|forever>] [--until <timestamp>]`,
   `--enable`, `--status`. `--until` takes a GNU `date`-compatible absolute
   timestamp, an alternative to `--for`'s relative duration; with both given,
   the later of the two deadlines wins and a warning names which. Transitions
   are logged (`disabled`, `enabled`).

   **Why it exists.** Both cron pipelines execute code out of the agent-ops
   working tree. An agent editing `agent-cycle.sh`, `lib/` or `prompts/` is
   editing the files the next tick will source; a cycle firing mid-edit runs
   half of one revision and half of another, and the resulting failure gets
   attributed to whatever the agent happened to be writing. That is also why
   the switch is shared rather than per-pipeline: the weekly review runs out of
   the same tree and sources the same `lib/`, so a switch that stood down only
   the implementation pipeline would leave the hazard in place.

   Four details decide whether this helps or becomes its own outage:
   - **A disable expires** after `disable_default_ttl` unless it explicitly
     says `forever`. The switch's whole risk is that it is a deliberate,
     silent, total stop: an agent that sets it and then dies — killed, timed
     out, context exhausted, or simply finished and forgetful — has stopped
     every future cycle, and nothing will alert, because "no PRs" is what a
     working pipeline looks like on a quiet week. A TTL turns "forgot to
     re-enable" into a few lost cycles. This is the stale-lock rule of
     requirement 1 applied to the same failure.
   - **Everything ambiguous resolves toward disabled.** An unreadable record,
     or one whose `expires_at` won't parse, keeps the pipeline down. The file
     exists because something meant to stop the pipeline; recovering "enabled"
     from a truncated write runs the cycle the switch was set to prevent.
   - **A reason is required, and an unparseable `--for` or `--until` is an
     error.** The next person to wonder why nothing is happening is entitled
     to a reason, and a typo'd duration or timestamp — or a `--until` that
     names an instant already past — must not be guessed in either direction
     — one resumes the pipeline mid-edit, the other never resumes it.
   - **The switch stops the next cycle, not the one already running.** Say so
     when it is set while a lock is held, in `--status` and in `--disable`'s own
     output. An agent that disables the pipeline, assumes the coast is clear and
     starts editing has gained nothing and doesn't know it.

   Deliberately *not* bypassed by `--once` or `--dry-run`: "these files are
   being edited, do not run them" is no less true when a human runs them.
2.3a. **The fleet switch.** The same switch, one level up: `fleet/disabled.json`
   on the state repository's main, holding the same record shape and read
   through the same evaluation. With several nodes active, "stop the
   pipelines" has to mean all of them, so `--disable` writes both levels
   (local first — it always works — then the fleet, with a loud warning
   naming the degraded state when the fleet write fails) and `--enable`
   clears both (and must **never** report the fleet flag cleared when it is
   not: an operator who believes they resumed the operation while every node
   still stands down is the worst lie this switch can tell). Both pipelines
   check it at cycle start, after the local switch and still before the
   lock; it costs one contents-API read.

   Failure directions, deliberately: a 404 is *clear*, definitively; an
   unreachable state repo falls back to the copy cached at the last
   successful fetch (`state_dir/fleet-cache/`), and to enabled when there is
   none — safe to fail open because a node that charges ahead blind meets
   per-item claims that fail closed (requirement 17a); a flag that exists
   but does not parse is *disabled*, exactly as for the local record. An
   expired fleet disable is cleared by whichever cycle sees it first — the
   delete is sha-guarded and idempotent, so a lost race means a peer got
   there, and there is no singleton chore (requirement 2.5). The weekly
   review honours the fleet switch but never sets or clears it, mirroring
   its relationship to the local one (`docs/REVIEW-PIPELINE-SPEC.md`, R2a).
2.4. **The role guard.** The environment variable `AGENT_OPS_ROLE` names the
   one node that runs unattended cycles. Compared case-insensitively and
   ignoring surrounding whitespace against the single value `active`;
   **anything else — unset, empty, misspelt, or a word from some other
   vocabulary — is a standby**, and a standby exits 0 after writing one line to
   stdout (which cron redirects into `cron.log`) naming the role it saw.

   Checked *before the configuration is read*, and therefore before the lock,
   the log and the cycle directory: a standby tick must leave no trace in
   `state_dir` at all. That is stricter than the switch, which logs its
   stand-down, and deliberately so — a standby's `state_dir` holds no work of
   its own, so an hourly event written there is noise in a stream that is
   otherwise a record of cycles, and an hourly empty cycle directory is
   indistinguishable from a cycle that died before it logged anything.

   Bypassed by `--dry-run` and `--once`, which are a human asking for a cycle
   rather than an unattended one, and by `--disable`/`--enable`/`--status`,
   which manage shared state and must answer on every node. Not bypassed by
   `--repo`, which narrows an otherwise ordinary cycle. The switch is checked
   *after* the guard, so a standby node neither logs nor clears it: the record
   belongs to the active node, and expiry is its business to notice.

   **Why fail-closed.** The pipelines run on several machines (the laptop
   and any number of cloud nodes), and any number of them may be active at
   once — per-item claims (requirement 17a) keep concurrent actives off the
   same work, so the role no longer elects "the" worker; it decides whether
   *this* machine spends unattended at all. The two mistakes are still not
   symmetric: a node wrongly standby costs skipped cycles, visible on the
   dashboard within the hour and fixed by one variable; a node wrongly
   active spends money nobody chose to spend. So the guard resolves every
   ambiguity toward standby, exactly as requirement 2.3 resolves every
   ambiguity toward disabled. The guard is a local, zero-cost check: spend
   is opted into per machine, deliberately, never inherited from a typo.

   Implemented in `lib/role.sh`, shared with `review-cycle.sh`
   (`docs/REVIEW-PIPELINE-SPEC.md`, R2b) so "active" has one definition.
2.5. **The fleet's shared memory.** The pipelines' memory — `state_dir` — is
   published between nodes through the private repository named by
   `state_repo`, by `scripts/state-sync.sh`, one branch per node. Every mode
   of that script is a silent no-op when `state_repo` is unset, so a
   single-node operation behaves exactly as it did before the fleet existed.

   **What replicates.** Everything under `state_dir` except the live locks
   (`lock.json`, `review-lock.json`), the dashboard's own machinery
   (`dashboard/`, `dashboard.log`, `dashboard-server.log`,
   `.dashboard-github.json`, `.image-drift-cache.json`), `state-sync.log`,
   and the stage event streams (`*.stream.jsonl`, requirement 4d).
   The exclusions are not tidiness: a copied `lock.json` is a lock no process
   holds — peers read logs, never locks; the
   dashboard is generated from the state beside it, so copying it would be
   copying a derivative of what is already being copied; a copied
   `.image-drift-cache.json` would answer for a registry query nobody on the
   peer ran. The streams are excluded on size as much as on relevance: what
   a peer reads of a stage is its result envelope, which replicates as
   `<stage>.out` exactly as before, while the stream beside it is every
   message and every tool result — kilobytes against megabytes — and the
   branch is a single rolling commit holding `cycles_retained` of them. The
   exclusion covers both transfers, the general one and the cycle
   directories' own filter, and deletes any stream a node published before
   the rule existed. `log.jsonl`,
   `review-log.jsonl`, `cycles/`, `reviews/`, `disabled.json` and the cron logs
   do replicate — they are what makes a spare node warm rather than merely
   installed. Git stores no empty directories, so a cycle that stood down
   before its first stage replicates as its `log.jsonl` entry alone.

   **Push.** Every node — active or standby — mirrors its `state_dir` into
   its **own branch**, `nodes/<NODE_NAME>`, every few minutes from the
   crontab and again from the cleanup that ends a cycle. No two nodes share
   a branch, so pushes cannot contend and nothing arbitrates them. Each push
   stamps `heartbeat.json` (`{node, role, ts, last_cycle, version, compose,
   image}`)
   into the branch root — on a standby, which has no cycles to publish, the
   heartbeat is the entire point, and it is what lets the fleet dashboard
   tell a quiet node from a dead one. `version` is `lib/version.sh`'s answer
   — what code the node is running, knowable to the fleet only because the
   node says so itself, since a peer publishes no container. `compose` is
   `lib/compose-drift.sh`'s, on the same reasoning one layer down: whether
   the node's own `compose.yaml` still matches the copy its image shipped
   (see "The node stack"), a question only that node can ask because the
   file lives on its host and only its own containers mount it (#131).
   `image` is `lib/image-drift.sh`'s: whether the node's own commit is the
   one `ghcr.io/poetic-poems/agent-ops:latest` currently names, read
   anonymously over the registry's own API rather than GitHub's (which would
   need the `read:packages` scope this pipeline does not hold) — the gap
   `version` alone cannot close, since comparing nodes only with each other
   cannot tell a fleet uniformly stale from a healthy one (#155). Unlike
   `version` and `compose`, a real network round trip sits behind it, so
   `scripts/publish-dashboard.sh`'s own 5-second tick cannot pay for it on
   every run: `.image-drift-cache.json`, named identically by both callers,
   holds the last answer for `IMAGE_DRIFT_TTL` seconds (240 by default) so
   whichever of the two next crosses that age pays the one query and the
   other reads its answer off disk.
   Each branch is a single rolling commit — `commit
   --amend` plus a force-push — because the state files carry their own
   history (`log.jsonl` is append-only, every cycle keeps its own directory)
   and a commit per push would be a second, redundant history whose only
   lasting effect is a repository that grows without bound. A mid-cycle push
   is fine: consumers read logs rather than adopting state, and the
   dashboard tolerates a torn transcript for one tick. The branch keeps the
   newest `cycles_retained` cycle directories. The node's own history is
   bounded separately, by the same push and before any mirroring: local
   `cycles/` and `reviews/` are pruned to the newest
   `state_local_cycles_retained` each — a deliberately longer record than
   the branch's, so everything the branch wants is always still on disk and
   the machine remains the fuller history of the two, with a floor of one so
   the cycle being recorded is always kept. The stage streams inside those
   directories are bounded separately again, and far more tightly: the same
   push deletes every `*.stream.jsonl` outside the newest
   `state_local_streams_retained` directories, leaving the directories
   themselves — and everything else in them — untouched. Two retentions
   rather than one because the two are different orders of size: keeping six
   weeks of cycle *records* costs megabytes, and keeping six weeks of the
   streams inside them would cost tens of gigabytes. A mirror-level `flock`
   serialises the cron push against the end-of-cycle push.

   **Fetch.** Every node materialises every *other* node's branch, whole,
   under the peers directory (`lib/fleet.sh`, `<workspace_root>/
   .agent-ops-peers/<node>/`), on its own schedule: `git archive` into a
   temporary directory swapped atomically into place, so a union reader
   never sees half a peer. A branch that has been deleted is a node that has
   left the fleet — its peer copy is pruned on the next fetch. Nothing is
   ever written into a node's own `state_dir` from outside.

   **The union.** What the fleet shares is memory, not authority: the
   blocked and void extractions (requirements 34/34c), the no-op fingerprint
   (3b) and the usage-limit cooldown (2.1) all read `fleet_logs` — this
   node's own log concatenated with every peer's, sorted into time order —
   so a lesson any node learned stands the whole fleet down, or spares it a
   re-check, within one fetch interval. The union is advisory speed; the
   claims of requirement 17a are the lock underneath it. Cross-node work
   arbitration has no other mechanism: there is no lease and no leader, and
   `claims/` on the state repository's `main` branch — which per-node
   branches never touch — is owned exclusively by `lib/claim.sh`.
2.6. **Log rotation.** Requirement 2.5 bounds the *records* in `state_dir` —
   `cycles/` and `reviews/` are pruned on every push — but its logs are
   appended to forever otherwise. `scripts/rotate-logs.sh`, on its own
   crontab line independent of the pipelines, bounds four of them:
   `dashboard.log`, `state-sync.log`, `cron.log` and `review-cron.log`. Each
   is renamed to `<name>.1` (an existing `.1` first shifts to `.2`, and so
   on) once it reaches `log_retained_bytes`, keeping the newest
   `log_generations` generations; a fresh, empty file replaces it
   immediately, so nothing is ever left missing. A plain rename is enough —
   every writer here reopens the file by name on each append (`>>"$log"` per
   cron invocation), so no process holds a descriptor across the rotation
   and `copytruncate` is not needed. `log.jsonl` and `review-log.jsonl` are
   never rotated: the union readers (blocked/void extraction, the no-op
   fingerprint, the usage-limit cooldown) scan them whole, and dropping
   their head would silently change what the Co-Ordinator believes has been
   tried. Because `cron.log` is published to the node's state branch
   (requirement 2.5) and its tail is rendered on the dashboard (the
   `DASHBOARD-SPEC.md` cron panel), `scripts/publish-dashboard.sh` reads
   `cron.log.1` too whenever the live file alone is shorter than the tail
   window, so a rotation never empties the panel.
2.7. **Crash-loop escalation.** A Co-Ordinator failure pins no repo/item
   (requirement 33's fields are set only after selection), so the entire
   blocked → Enabler → escalation ladder that covers item failures never
   sees it — and the cycle still ends 0, so the dashboard shows a healthy
   idle fleet. When such a failure is deterministic and ships in the image,
   every node fails identically every hour and the record diverges
   completely from reality: the 2026-08-01 argv-cap outage ran ~15 hours ×
   4 nodes before a human noticed, and nothing in the system would ever
   have said so. So the Script reads the one signal that class does leave.
   After the requirement-2.5 union snapshot and before the stand-down
   checks (a fleet that is also standing down must still raise the alarm),
   `lib/crash-loop.sh`'s `crash_loop_verdict` scans the union for
   `crash_loop_after` or more **consecutive** Co-Ordinator `attempt-failed`
   events carrying **one identical detail**, with no Co-Ordinator success
   (`stage-end`, stage `coordinator`, exit 0) anywhere in the fleet in
   between. Identical detail is what separates the deterministic class from
   transient noise; any success resets the count. On a verdict, and unless
   `crash_loop_escalated_since` finds a `crash-loop-escalated` event with
   the same detail at or after the run's own first failure (so the same
   loop is never escalated twice, while a fresh loop with an old detail
   escalates anew), the Script files an issue on `crash_loop_repo` through
   the Enabler's own `create_escalation_issue` — same open-issue dedup
   (item ref `crash-loop:coordinator`), same label, same load-bearing
   assignee that keeps the pipeline from selecting its own SOS as work —
   and logs `crash-loop-escalated` with the verdict's fields and the
   issue's number and URL. If the issue cannot be filed the Script logs a
   `warning` and leaves no `crash-loop-escalated` event, so the next cycle
   retries. The cycle then proceeds normally either way: detection must
   never suppress the recovery attempt that might end the loop.
   `crash_loop_after` 0 (or absent), or an empty `crash_loop_repo` or
   `enabler_assignee`, disables the check; `--dry-run` never files.
3. **Repo ordering.** For each configured repo, fetch the timestamp of the
   most recent commit on its default branch via `gh api`. A repo entry may
   also carry `nice`, an optional integer from `-19` to `19` (absent means
   `0`), read from that repo's `config.json` entry. Compute each repo's
   effective age as `(now − timestamp) × 1.25^(-nice)` and sort
   most-overdue-first by that effective age: `lib/repo-order.sh`'s
   `repo_order_by_effective_age`, sourced and applied by the Script. The
   prompt's part is descriptive only: `prompts/coordinator.md` presents the
   order as Script-computed — staleness weighted by each repo's configured
   attention bias — and instructs the Co-Ordinator to honour it as given;
   the `nice` values themselves never reach the model. With every repo's
   `nice` absent or `0`, effective age is plain age and the walk is a
   least-recently-updated-first sort — same order, same ties. Equal effective ages break by slug, deterministically. A missing or
   unparseable timestamp reads as epoch 0 — the oldest possible commit — so
   that repo stays maximally overdue at neutral `nice`, because a repo the
   Script cannot date is not one a `nice` value should be able to defer. The
   most-overdue repo gets first look, and this ordering takes precedence
   over the per-repo source priorities — but it does not outrank the global
   cross-repo tiers: security (15a), review-feedback (15b), abandoned-drafts
   (15c), merge-conflicts (15d) and urgent issues (15e) all still override
   the walk regardless of repo order. A `nice` value biases the walk; it
   never starves a repo, and a repo that alone has selectable work is chosen
   whatever its `nice`. The Script refuses to start a cycle if any
   configured repo's `nice` is not an integer in `-19`..`19`, failing fast
   and naming every offending slug, the same guard as
   `implementation_plan_path` (requirement 3k).
3a. **Findings pre-fetch (cost control).** For each configured repo whose
   `sources` include `security` or `code-quality`, run
   `scripts/gather-findings.sh <repo-slug>` — a deterministic script that uses
   `gh api` to pull the repo's open Dependabot alerts and open code-scanning
   alerts, normalises each into a compact finding (`source` of `security` or
   `code-quality`, a `security` boolean, `severity`, a stable `ref`, `title`,
   `url`, and location/package), and prints them as a JSON array. It must
   degrade to `[]` (and exit 0) when a repo has the feature disabled or the
   token lacks access, so a missing feature never fails the cycle. Attach each
   repo's array to that repo's entry in the Co-Ordinator's runtime input as
   `findings`. Doing this in the Script — not in the Co-Ordinator — spends no
   model tokens on paginating and digesting those verbose APIs.
3c. **Review-feedback pre-fetch (requirement 3c).** For each configured repo
   whose `sources` include `review-feedback`, run
   `scripts/gather-review-feedback.sh <slug> <pr_label> <branch_prefix>` and
   attach the array to that repo's entry as `review_feedback`. It prints the
   PRs *waiting on us to answer a human's review*: open, non-draft, carrying
   `pr_label`, head branch under `branch_prefix`, `reviewDecision` of
   `CHANGES_REQUESTED`, and — the load-bearing clause — **no GitHub
   review-thread event has answered the blocking review**: no marked reply
   (a review or general PR comment carrying `lib/pipeline-marker.sh`'s
   invisible marker) and no `review_requested` timeline event, either dated
   after the blocking review was submitted. Each entry carries every review
   body and inline comment in the round, verbatim.

   - **The turn rule is the whole feature.** This system raises PRs as the
     account it runs as, and GitHub forbids approving or dismissing a review on
     your own PR. So the agent *cannot* clear `CHANGES_REQUESTED`; it stays set
     after the fix is pushed, and nothing about the PR's own state ever says
     "answered". Deriving whose turn it is from review-thread events is the
     only thing that does. Without it every PR the agent fixed would stay a
     candidate forever — selected, re-fixed, re-selected, hourly, each cycle
     looking like a productive one and each paying a Sonnet run to redo work
     already pushed. Same shape as requirement 15's "a later green run
     supersedes".
   - **Events, not commit timestamps.** This used to compare the blocking
     review's `submitted_at` against the head commit's `committedDate`. A
     conflict-resolution force-push re-stamps every commit's date to push
     time, which silently satisfied that comparison on PR #205 while the
     human's `CHANGES_REQUESTED` sat unanswered — the branch had a fresh
     commit date from a rebase that never touched a single finding in the
     review. A marked reply and a `review_requested` timeline event are both
     stamped by GitHub itself at the moment they happen, so neither can be
     produced by a rebase; a round is answered only once one of them actually
     occurs after the blocking review.
   - **The blocking review shares `_handoff_blocking_reviewers`'
     standing-position rule but deliberately not its bot filter**
     (requirement 34a): each reviewer's own most recent
     APPROVED-or-CHANGES_REQUESTED review, filtered to CHANGES_REQUESTED,
     latest across reviewers. A COMMENTED review never changes a reviewer's
     standing position, so a human who requested changes and later left a
     comment is still blocking. Bots count here and not in re-request:
     `reviewDecision` — the selection filter — counts bots, and the marked
     reply is the only event that can answer a bot's round, since the
     pipeline can neither dismiss a review on its own PR nor (by design)
     re-request a bot. Bot findings are addressed; bots are never pinged.
     Stating the difference here, in both places, is requirement 34a's
     point — an asserted-but-false equivalence is exactly the confident
     wrong answer it exists to prevent.
   - **Gather every review in the round, not just the blocking one.** The
     substance and the formal signal routinely live in different reviews by
     different accounts, precisely *because* an author cannot request changes on
     their own PR. Observed here: the agent's account left a 6.5 KB `COMMENTED`
     review with every actual finding, and the human's second account posted the
     `CHANGES_REQUESTED` whose body reads, in full, "Refer to <link>". Gather
     only the blocker and the Implementor receives the words "Refer to". The
     round's start is the most recent answer event *before* the blocking
     review (or the PR's beginning, if none), so a COMMENTED review submitted
     moments before the blocking one is still included.
   - **The ref is `pr-<n>-review-<review-id>`, not `pr-<n>`.** A blocked item
     (requirement 34) stays blocked until cleared, so a bare `pr-57` the
     Implementor once failed on would still be blocked when the human posted
     fresh guidance, and that guidance would land on a dead item. Per-round refs
     expire by irrelevance, like the review-dated `review-<date>-R-NN` refs.
   - **Only branches under `branch_prefix`.** The Human Gate reserves every
     other branch for humans; "they asked for changes" is not licence to push to
     a colleague's PR.
   - Fails safe to `[]` (exit 0). But show `gh`'s stderr: a rejected `--json`
     field name (`headRefOid` does not exist in every `gh`) otherwise degrades
     to an empty array indistinguishable from "nothing is under review", and the
     source silently never fires. That cost a debugging round when this was
     built.
3e. **Abandoned-drafts pre-fetch.** For each configured repo whose `sources`
   include `abandoned-drafts`, run `scripts/gather-abandoned-drafts.sh <slug>
   <pr_label> <branch_prefix> <abandoned_draft_after_hours>` and attach the array
   to that repo's entry as `abandoned_drafts`. It prints the draft PRs *this
   system raised and then abandoned*: open, **draft**, carrying `pr_label`, head
   branch under `branch_prefix` (or `td/`), and whose last **real** activity
   (below) is older than `now − abandoned_draft_after_hours`. Each entry carries
   the round's ref, the PR number and URL, the existing branch, the head SHA,
   that last-real-activity timestamp (as `updated_at`), and the draft PR's own
   body verbatim (the original plan).

   - **A draft is the claim; a stale draft is an abandoned claim.** Requirement 23
     has the Implementor open a draft PR the moment it starts, as the visible
     claim. A draft that has sat untouched past the threshold is therefore a claim
     whose owner never returned — a stage that timed out, hit a usage limit, or
     died. A genuine push, review or comment resets the clock, so a draft that is
     merely being worked (or that a peer node has picked up) never qualifies; the
     threshold sits comfortably beyond a whole cycle for exactly this reason.
   - **Last real activity, not GitHub's raw `updatedAt`** (TD26072605). `updatedAt`
     advances on *anything* — a push, a comment, a label or a title edit —
     including this system's own housekeeping, and when this system touches a PR
     that usually means the opposite of "somebody is on it". So this source
     computes its own measure instead: the latest of the head commit's
     `committedDate`, every review's `submittedAt` and every comment's
     `createdAt`, **excepting** any review or comment carrying the invisible
     marker `lib/pipeline-marker.sh` defines — the body is what is tested, not
     which collection the write landed in, because `gh pr comment` and `gh pr
     review --comment` file the same words under different ones and the Reviewer
     may use either. Two writes are therefore never evidence of
     activity: a **label edit** is discounted unconditionally (the label set is
     this system's own bookkeeping, never a sign of work in progress), and a
     **comment this system posted itself** — stamped by `agent-cycle.sh`'s own
     stage-failure comments and by the Implementor's, Enabler's and Reviewer's
     comment instructions (`prompts/implementor.md`, `prompts/enabler.md`,
     `prompts/reviewer.md`) — is discounted because it carries the marker. A
     human's comment (or a peer node commenting
     on a human's behalf) carries no marker and always counts; filtering by
     author cannot make this distinction, because every pipeline write happens
     under the same GitHub account a human also comments as. A marked comment
     resets the clock **not at all**, never partially — the Enabler's own verdict
     already reaches selection as an `unblocked`/`still-blocked` event
     (requirement 18), so a partial reset would add nothing.
   - **A nested collection at `gh`'s cap is missing evidence, not evidence.**
     `gh pr list` does not paginate the collections this computation reads —
     `commits`, `reviews` and `comments` each arrive capped at 100 items, with
     `comments` oldest-first — so at the cap the newest activity may be absent,
     and at the commits cap `commits[-1]` is not the head. A PR with any
     collection at the cap is excluded this cycle, loudly on stderr: the same
     uncomputable-activity treatment as the missing-commit case below, chosen
     over paginating per candidate because the failure it guards against is the
     dangerous direction (a live human conversation past the cap misread as
     silence) while the cost is the safe one — a stalled draft that has somehow
     accumulated 100 of anything waits for a human, and on this system's own
     drafts such a PR is an anomaly worth a human's eye anyway.
   - **Ready PRs are not ours to touch here.** A non-draft PR is finished work
     waiting on the human; answering it is `review-feedback`'s job, and
     force-pushing it would violate the Human Gate. Only drafts qualify.
   - **The ref is scoped to the head SHA** — `pr-<n>-abandoned-<head-sha>`, not
     `pr-<n>-abandoned` — so a block recorded against one abandoned state does not
     swallow a later, possibly-finishable state after fresh commits land, while a
     draft re-abandoned at the same head keeps the same ref and stays blocked.
     Same reasoning as requirement 3c's per-round refs.
   - **Its candidacy turns on the clock**, uniquely among the sources, and that is
     the deciding reason it is pre-fetched rather than left to the Co-Ordinator:
     the staleness transition moves no commit, issue, alert or even a PR's real
     activity, so only an array computed against the clock here makes it visible
     to the no-op fingerprint (requirement 3b). As with requirement 3c the rule
     must exist for the fingerprint anyway, so it gets one definition
     (requirement 34a).
   - Fails safe to `[]` (exit 0), with the same stderr discipline as requirement
     3c. A PR whose real activity cannot be computed (no commit — should never
     happen — or a collection at the cap, above) is excluded rather than treated
     as maximally stale: the dangerous direction is stealing live work, not
     leaving a stalled draft one more cycle. `shellcheck`-clean.
3g. **Merge-conflicts pre-fetch.** For each configured repo whose `sources`
   include `merge-conflicts`, run `scripts/gather-merge-conflicts.sh <slug>
   <pr_label> <branch_prefix>` and attach the array to that repo's entry as
   `merge_conflicts`. It prints the PRs *this system raised that are otherwise
   ready but conflict with their base*: open, **non-draft**, carrying `pr_label`,
   head branch under `branch_prefix` (or `td/`), and with `mergeable` exactly
   `CONFLICTING`. Each entry carries a head-SHA-scoped ref, the PR number and URL,
   the existing branch, its `base`, the head SHA, the `updatedAt`, and the PR's
   own body verbatim.

   - **Only *ready* PRs, and only *definite* conflicts.** A draft's conflict is
     abandoned-drafts' to resolve (as part of finishing the draft); this source is
     for PRs otherwise ready for review or merge, where the conflict is the sole
     blocker. And `mergeable` must be `CONFLICTING`, never `UNKNOWN`: GitHub
     computes mergeability asynchronously, so a PR whose base just moved reports
     `UNKNOWN` for a beat. Treating that as a conflict would send the Implementor
     to rebase a PR that may not conflict; skipping it means the PR is simply
     reconsidered next cycle, once GitHub has settled the answer.
   - **The ref is scoped to the head SHA** — `pr-<n>-conflict-<head-sha>`, not
     `pr-<n>-conflict` — so a block recorded against one conflicted state does not
     swallow a later, possibly-resolvable one after fresh commits land, while a
     resolution (which moves the head) retires the ref and a conflict re-detected
     at the same head keeps it. Same reasoning as requirements 3c and 3e.
   - **Its candidacy turns on the base moving**, an event no signal on the PR
     itself carries, which is the deciding reason it is pre-fetched rather than
     left to the Co-Ordinator: the base advance moves the repo head SHA one cycle,
     but mergeability resolves to `CONFLICTING` a later cycle with the repo head
     SHA unchanged since — so only an array computed here makes the transition
     visible to the no-op fingerprint (requirement 3b). As with requirements 3c
     and 3e the rule must exist for the fingerprint anyway, so it gets one
     definition (requirement 34a).
   - Fails safe to `[]` (exit 0), with the same stderr discipline as requirement
     3c. `shellcheck`-clean.
3i. **Register-hygiene pre-fetch.** For each configured repo whose `sources`
   include `register-hygiene`, run `scripts/gather-register-hygiene.sh <slug>
   <default_branch>` and attach the array to that repo's entry as
   `register_hygiene`. One root-tree listing read
   (`gh api repos/<slug>/git/trees/<default_branch>`) gives both the
   `tech-debt` tree SHA and the policy blob SHA (`TECH-DEBT.md`). No
   `tech-debt` tree means `[]`, silently — no register, or an empty one, and
   either way there is nothing this source could repair; an empty register's
   scope declaration is validated by that repo's own CI, not by this one.
   Otherwise it reads the whole register in one call via the tarball endpoint
   (`gh api repos/<slug>/tarball/<default_branch>`), extracts `tech-debt/`,
   and runs `scripts/td-check.pl` over the extracted directory, printing at
   most one candidate carrying a ref derived from the register's identity,
   the register's URL on the default branch (`…/tree/<branch>/tech-debt`),
   the `tech-debt/` tree SHA as `blob_sha`, the problem lines as an array,
   and the checker's whole output verbatim as `body`.

   - **The candidate rule is the checker's exit status**, and deliberately
     nothing more: `td-check.pl` exits 1 when the register reports any of BAD
     NAME, BAD FRONTMATTER, MISSING FIELD, BAD FIELD, BAD STATUS, BAD SCOPE,
     NO SCOPE, ID MISMATCH, DATE MISMATCH, STALE FIELD or DUPLICATE ID. There
     is no severity ordering and no partial candidacy — the register is
     either consistent or it is not, and either way the repair is one pull
     request. At most one candidate per repo, because a repo has one
     register.
   - **The same script is the CI guard and the acceptance test.** Each
     consumer repo runs argless `perl scripts/td-check.pl` on every pull
     request (`.github/workflows/tech-debt-register.yml`); a file argument
     now dies rather than checking anything. This pre-fetch runs it to decide
     candidacy, and the Implementor re-runs it until it exits 0. One
     definition, three consumers (requirement 34a); a model re-deriving the
     rule would be a fourth opinion about what a consistent register looks
     like, and the one that disagreed would be the one nobody noticed.
     `td-check.pl` is canonical in `Poetic-Poems/poetic` and held here as a
     byte-identical copy, guarded by `td-tooling-drift.yml`.
   - **The ref is scoped to the register's identity** — the first 12 hex
     characters of a sha256 digest of `<tech-debt-tree-sha>:<policy-blob-sha>`,
     digesting both the `tech-debt/` tree and the scope-declaring
     `TECH-DEBT.md` blob so a repair to either retires the ref — not a bare
     `register-hygiene` — so a block recorded against one state of the
     register does not swallow a later, possibly-repairable one, while a
     repair retires the ref and drift re-detected against an unchanged
     register keeps it. Commits that touch anything else in the repo leave
     the identity, and so the item, alone. Same expiry-by-irrelevance
     reasoning as requirements 3c, 3e and 3g.
   - **Unlike requirements 3e and 3g, its candidacy needs no rescuing by the
     fingerprint**, and the spec says so rather than leaving a reader to assume
     the usual argument applies: drift is a pure function of the register's
     content, so it can only appear on a commit to the default branch, which
     moves the `head_sha` requirement 3b already hashes. The array is fed to
     the fingerprint verbatim anyway — for uniformity, because a per-source
     exception is a thing to remember and "covered by something else" is how a
     source ends up covered by nothing, and because candidacy depends on the
     checker too, so an edit to `td-check.pl` can add or retire the item with no
     commit to the target repo at all.
   - Otherwise fails safe to `[]` (exit 0) with the same stderr discipline as
     requirement 3c: a 404 (no such repo or branch) is distinguished from a
     genuine failure by the API's own status, not by parsing `gh`'s wording,
     and only the failure prints to stderr. `shellcheck`-clean.
3j. **Issues pre-fetch.** For each configured repo whose `sources` include any
   `issues:<band>` entry (one source at four ranks — any band warrants the one
   fetch), run `scripts/gather-issues.sh <slug>` and attach the array to that
   repo's entry as `issues`. Each entry is one candidate issue, whole thread
   included: `source: "issues"`, the bare issue number as `ref` (and as
   `number`), `url`, `title`, the `Priority` band as `priority` (read exactly
   as the source-state digest reads it — same field, same four names, same
   `Medium` default — because a band the digest and the candidate set derived
   differently is the fingerprint failure requirement 3b exists to prevent),
   `labels`, `author`, `created_at`, `updated_at`, the `body` verbatim, and
   `comments` (author, timestamp, body — verbatim, oldest first).

   - **Why this source is pre-fetched at all.** It used to be the
     Co-Ordinator's own read, and that contract failed closed: cycle
     `20260727T145500Z-poetic-1-1431114` recorded the Co-Ordinator reasoning
     "no issue data provided in input; per the prompt, I do not re-query" — a
     rule that never existed — and skipping the entire issues walk while six
     selectable issues sat open. A source the model can silently decline to
     read is the model-side twin of the fingerprint gap requirement 3b warns
     about: no error, just tidy `none-selected` events over live work. The
     array makes the candidate set an input rather than an errand, the same
     move every drifted source before it got (3a, 3c, 3e, 3g, 3i).
   - **The deterministic half of requirement 16.4 is applied here**: assigned
     issues, issues labelled `blocked` (case-insensitive), issues naming an
     unresolved `Blocked-by:` reference (requirement 34j, checked live once
     each candidate's whole thread is in hand), and the pull requests the
     issues endpoint interleaves are dropped in the gatherer, so the
     Co-Ordinator never spends judgement on entries no rule would let it
     pick — the assignment drop also covers the Enabler's escalation issues,
     which are always assigned. The judgement half ("a question or discussion
     rather than actionable work", over the whole thread) stays the
     Co-Ordinator's. Items blocked in the shared log are **not** dropped:
     requirement 18a's mandatory re-check needs the thread and `updated_at`
     in front of the Co-Ordinator to decide whether fresh evidence unblocks.
   - **Degrades to `[]` (exit 0) on any API failure**, like requirement 3a
     and unlike the source-state digest: the array is *given to* the
     Co-Ordinator, so an empty array is a faithful record of the input it
     got, and the independently sampled issues digest still busts the
     fingerprint when a real issue moves during the degradation. Failures are
     loud on stderr (teed to `issues-<repo>.err` in the cycle record).
   - Both reads take one 100-item page, like every gatherer. The bound is
     stated in the script header rather than silently applied.
3k. **Implementation-plan path passthrough.** The `implementation-plan` source
   names no path of its own: for each configured repo whose `sources` include
   it, attach that repo's `implementation_plan_path` (from its `config.json`
   entry) to its runtime-input entry, so the Co-Ordinator knows where to read
   that repo's plan document without any path fixed in the prompt or in code —
   a repo with a differently named or located plan needs only its own
   `implementation_plan_path`, never a prompt change. A repo that lists the
   source without configuring the path is a startup misconfiguration: the
   Script exits with an error before any stage runs, the same guard as
   `enabler_assignee` (Configuration table). There is no gatherer script and no
   pre-fetch, as for `project-review`: the Co-Ordinator reads the file itself
   (`gh api repos/<slug>/contents/<path>`).
3h. **Refinement carry-forward.** The Co-Ordinator's runtime input carries a
   `refinements` map — repo → item → the latest `item-refined` payload
   (requirement 33), for items that are not void — built from the fleet's log
   union by `refinements_map` in `lib/cycle-state.sh`, alongside the `blocked`
   and `void` extracts and keyed the same way (requirement 34's repo+item rule:
   a refinement written for one repo's `TD26071805` is not a specification of
   the other's).

   It exists because a refinement has to land where a *future* Co-Ordinator will
   read it, and for most item types there is nowhere. An issue has a thread, and
   requirement 36b puts the refinement there as one authoritative comment that
   requirement 20 already pastes into the work order; a tech-debt record, a
   review recommendation, a plan task or a finding has no such surface, and no
   actor here may edit the register. So for those the specification lives in the
   log and this map is what returns it to selection. Without it the Enabler would
   write a refinement, the item would be unblocked, and the next work order would
   be composed as though nothing had been settled — paying for the refinement and
   discarding it.

   Void items are excluded: a refined specification of work that does not exist
   would arrive in the Co-Ordinator's input arguing, in the pipeline's own voice
   and in detail, for an item requirement 34c says must never be selected again.
3o. **Claim visibility (issue #175).** The Co-Ordinator's runtime input carries
   a `claimed` array — `{repo, item, age_hours}` — alongside `blocked`, `void`
   and `refinements`, gathered fresh by the Script for every repo it is about
   to walk, immediately before the Co-Ordinator launches. It is the union of
   two independent sources, deduped by repo+item:

   - every claim-registry entry younger than `claim_ttl_hours` for that repo
     (`lib/claim.sh claims`) — the only source for a *file* claim, since
     `review-feedback`, `merge-conflicts` and `abandoned-drafts` finish an
     existing PR and mint no branch; `age_hours` is the entry's exact age; and
   - every live `td/*`/`<branch_prefix>*` branch on the target repository
     itself (`lib/claim.sh branches`), which still catches a claim the
     registry missed — `state_repo` unset, or a best-effort registry write
     that failed — with `age_hours` reported as `null` when no registry entry
     backs it. This runs after the claim gc (2.1a) has already swept anything
     past the TTL that was left untouched, so a live branch found here is
     either still fresh or has real work pushed to it — either way it
     belongs in the list, and needs no separate TTL check of its own.

   Before this existed, exclusion 3's second half (a live claim branch is a
   claim, even before its draft PR appears) was a live check the Co-Ordinator
   itself had to perform — nominally `git ls-remote` per repo, in practice a
   step routinely skipped by the smaller model this stage runs on, and one that
   the three finishing sources' file claims (invisible as branches) could never
   have covered even performed perfectly. `claimed` replaces it: exclusion 16's
   second bullet is now a lookup against pre-fetched data, not a live query, and
   it is complete over both claim shapes. A candidate whose repo+item is not in
   `claimed` genuinely has no fresh claim on it — the array is not a hint to go
   verify, it is the answer.

   Item refs recovered from a branch name are the exact inverse of
   `claim_branch_for` (requirement 17a): `td/<ID>` strips to `<ID>`,
   `<branch_prefix><ref>` strips to `<ref>`. That recovery is exact in
   practice for every item type this system ever mints such a branch for — an
   issue number, an alert ref, a register-hygiene or project-review ref — none
   of which contain a character `claim_branch_for`'s sanitiser would have
   touched, so there is nothing lossy to recover from.
3b. **No-op short-circuit (cost control).** The Co-Ordinator costs the same to
   say "nothing to do" as it does to select work. On a quiet week that is 24
   identical answers a day, every one of them paid for. Before launching it,
   compute a **fingerprint** of every input its verdict depends on; if the most
   recent `none-selected` event carries the same fingerprint and is younger
   than `none_selected_recheck_hours`, log `stand-down` with the reason and the
   fingerprint, and exit without launching anything.

   The claim this makes is deliberately narrow, and stating it precisely is
   what keeps it safe: *every input is byte-identical to when it last declined,
   therefore its verdict would be the same*. It is **not** the claim "there is
   no work" — nobody but the Co-Ordinator can know that, and avoiding asking it
   is the entire point. The rule never has to be right about the repository,
   only about whether anything moved.

   - **The fingerprint must cover every input, or the pipeline silently
     stalls.** A source left out is a source that can gain work without waking
     the pipeline, and the symptom is nothing at all: no error, no failed
     stage, just tidy `stand-down` events and no PRs. Map each source to a
     signal and keep the map in the shared library: `head_sha` covers every
     file-backed source at once (tech-debt, implementation-plan,
     project-review, the code); the pre-fetched `findings` cover security and
     code-quality verbatim; the pre-fetched `review_feedback`, `merge_conflicts`
     and `abandoned_drafts` arrays cover those three finishing sources verbatim,
     and `register_hygiene` covers register-hygiene the same way (belt and
     braces there — `head_sha` already moves whenever the register does, but a
     source exempted from the map is one nobody re-checks when the map changes,
     and an edit to `td-check.pl` moves candidacy with no repo commit at all) —
     and the latter two matter especially, because each turns on a transition the
     open-PR digest does not carry: `abandoned_drafts` gains an entry the cycle a
     draft goes stale (the mere passage of time), and `merge_conflicts` the cycle a
     ready PR's `mergeable` resolves to `CONFLICTING` after its base moved. Hashing
     those arrays is the *only* thing that busts the fingerprint at those
     transitions, since the open-PR digest below moves for a new or updated PR but
     not for time passing or a base advancing elsewhere; the pre-fetched
     `issues` array of requirement 3j verbatim, *and* an issues digest
     (number, `updated_at`, labels,
     assignee, `Priority` — labels and assignee because requirement 16.4
     excludes on them, `Priority` because requirement 15e *ranks* on it and a
     re-prioritised issue is a different verdict from the same set of issues.
     `updated_at` is not a substitute for digesting the field itself: it is
     GitHub's to move or not on an issue-field edit, and a ranking signal whose
     only coverage is a timestamp somebody else owns is the "covered by
     something else" trap this list exists to close. The verbatim array is the
     only cover for an *edit* to an existing comment — which moves no digest
     field, while the Co-Ordinator reads the thread from the array — and the
     digest stays alongside because it is sampled independently, so a cycle
     whose issues fetch degraded to `[]` still gets its fingerprint busted by
     the digest when a real issue moves); a
     workflows digest for failed-runs; an open-PR digest, because a PR is a
     claim (16.3) and closing one creates a candidate while touching no commit,
     issue or alert; the `claimed` array of requirement 3o, projected to
     `repo|item` like `blocked`/`void` below, for the same class of gap
     `abandoned_drafts` and `merge_conflicts` close — a peer's claim, or that
     claim ageing past `claim_ttl_hours`, moves no commit, issue, alert, or
     (until its PR exists) the open-PR digest above; the `blocked`/`void`
     extracts projected to `repo|item`, so
     a human's hand-appended `unblocked` takes effect; the `refinements` map of
     requirement 3h projected to `repo|item|ts`, listed in its own right rather
     than left to the `unblocked` that always accompanies it, because "covered
     by something else" is how a source ends up covered by nothing; the Enabler's eligible
     set projected to `repo|item|reason` together with its config and prompt
     hash (requirement 35b); and — the three everyone
     forgets — the selection config, a hash of `prompts/coordinator.md`
     **and any `prompt_overrides.coordinator` files configured for it**
     (requirement 4a), and the rendered repo/work-sources table itself
     (requirement 4b), hashed verbatim because it is not the same claim as
     `repos[].sources`: back-pressure (requirement 2.2a) can narrow that array
     to a repo's finishing sources for one cycle while the table keeps
     showing that repo's full configured priority regardless, so only the
     table's own bytes cover a config edit to a non-finishing source landing
     during such a cycle.
     Without those, editing the selection rules — in the shipped
     prompt, in an installation's own extension, or in `config.json`'s
     `repos` array — does nothing until an unrelated commit lands, and you
     spend the afternoon debugging an edit that was correct.
   - **Digest what the verdict reads, not what merely changed.** Requirement 15
     makes a failed run a candidate when a workflow's *most recent run is a
     failure* — a fact about the conclusion. Digesting run ids instead makes
     every scheduled workflow bust the fingerprint on its own cadence.
     `poetic` schedules `sync-framework.yml` at `0 * * * *`: hourly, the same
     cadence as this pipeline. That one workflow reduced the entire
     short-circuit to a no-op that still paid for a Co-Ordinator every hour —
     installed, logged, green, and saving nothing. Digest conclusions, and drop
     runs still in flight (a run in progress is not yet a failure, and sampling
     one mid-flight registers two changes for a workflow that ends where it
     began).
   - **A sample that failed is not a sample.** The signals this rule needs
     beyond the Co-Ordinator's own runtime input are proxies for reads *it*
     performs, so they must be gathered by a deterministic script
     (`scripts/gather-source-state.sh`) that marks `ok: false` on any API
     error. An unfingerprintable cycle simply runs the Co-Ordinator. This is
     the one place the `[]`-on-failure convention of requirement 3a must not be
     copied: `gather-findings.sh` may degrade, because its output *is* the
     Co-Ordinator's input and a fingerprint recording "no findings" faithfully
     records what the model saw. A failing issues API degrading to `[]` would
     instead be a stable lie — it would match the next equally-failed sample
     and skip, and go on skipping for as long as the outage lasted.
   - **Fingerprint before the Co-Ordinator runs, and record that value.**
     Anything that changed while it was working is something it may not have
     seen, so it must be allowed to bust the next cycle's fingerprint. A
     fingerprint taken afterwards would absorb that change and skip on it.
   - **The forced recheck is the safety valve, not a nicety.**
     `none_selected_recheck_hours` bounds how long a gap in coverage — or a
     Co-Ordinator that would have decided differently on a second look — can
     hold the pipeline down. At 24 h an idle day costs one Co-Ordinator run
     instead of 24, and any stall is capped at a day. Setting it to `0` makes
     fingerprint coverage load-bearing forever.
   - `--dry-run` and `--once` bypass the skip (a human asking for a cycle wants
     an answer, not a cached verdict) but still *compute and record* the
     fingerprint, so a `--once` that finds nothing spares the next cron tick
     the same question.
4. **Co-Ordinator stage.** Launch the Co-Ordinator (headless, model
   `coordinator_model`, `--dangerously-skip-permissions`, stage timeout),
   passing it the ordered repo list (each entry carrying its work sources and
   its pre-fetched `findings`) and the blocked-item extract from the shared
   log. Capture its final message from the stage's own transcript
   (requirement 4d) and parse the work order from it.
4a. **Per-installation prompt overrides.** Every stage prompt this Script
   assembles — the Co-Ordinator's here, the Implementor's (requirement 7), the
   Reviewer's (requirement 8), and the Enabler's (requirement 35) — is built by
   `lib/prompt-overrides.sh`'s `stage_prompt_text`, not a bare
   `cat prompts/<stage>.md`, so a consumer can add or replace a stage's operating
   prompt from `config.json`'s `prompt_overrides` without forking `prompts/`
   (issue #79). For stage `<s>`, `prompt_overrides.<s>.extend` names zero or
   more files whose content is appended, in order, after the base prompt, each
   under a heading naming the entry's *configured* path — the string written
   in `config.json`, never the node-resolved location, so the assembled text
   is identical on every node serving the same config and content — and each
   wrapped in a fixed disclaimer that it may add guidance but does not exempt
   the installation from any numbered requirement in this document — the
   specs outrank every prompt, and an extension is not an exception to that.
   `prompt_overrides.<s>.replace` names one file substituted for
   `prompts/<s>.md` as the base, before any `extend` fragments are appended;
   it is the sharper tool, since a replaced prompt stops receiving this
   product's updates to that stage entirely, and the README flags it as such.
   A relative path in either key resolves against `state_dir` — the one
   location this repository guarantees survives an image roll or a
   `git pull`, unlike `prompts/` itself, which is baked into the image and the
   working tree alike. `prompt_overrides` absent, or a stage missing from it,
   reproduces today's exact prompt bytes: `stage_prompt_text` degrades to
   `cat prompts/<s>.md` with nothing appended. An unreadable configured path
   (missing file, bad permissions) is tolerated the same way — dropped from
   the assembled prompt, not a cycle failure — but still moves
   `stage_prompt_sha` (below), so a broken path cannot silently reproduce the
   fingerprint of a working one. That tolerance covers configured overrides
   only: the base prompt is this product's own content, so an unreadable
   `prompts/<s>.md` that no readable `replace` has substituted fails the cycle
   rather than launching the stage on an empty prompt — a stage given a work
   order and no instructions would spend a model to no purpose.
   That tolerance is for *runtime* faults only.
   `config.json`'s `prompt_overrides` itself must be structurally valid to
   full depth — an object (possibly `{}`) keyed only by the four stage names,
   each stage an object holding only `extend` (an array of file-path strings)
   and/or `replace` (a file-path string); any other shape — an unknown stage
   key, a non-object stage value, an unknown key within a stage, a wrong
   type — is a fatal misconfiguration at startup, caught by the schema gate
   (requirement 1b), the same as a missing `implementation_plan_path`
   (requirement 3k). The two faults differ in kind: a configured file can
   legitimately be absent this cycle and its absence still moves the
   fingerprint, but a structural typo is a static authoring error that would
   otherwise be swallowed by the assembly functions' own tolerance and serve
   the unmodified shipped prompt every cycle — with, for a misspelled stage
   key, no fingerprint movement to betray it.

   The Co-Ordinator's and Enabler's assembled prompts also feed the no-op
   fingerprint (requirement 3b, 35b): `coordinator_prompt_sha` and
   `enabler_prompt_sha` are `stage_prompt_sha`'s content-addressed digest of
   the stage's assembled prompt: the base file's content hash, then each
   configured `extend` entry's content hash keyed by its configured path,
   with a configured-but-unreadable entry recorded explicitly under that
   same configured name — rather than a bare `sha256sum` of
   `prompts/<s>.md`. A changed, added, removed, or newly
   unreadable override therefore busts the fingerprint exactly as an edit to
   the shipped prompt does; without this, an installation's own extension
   could change the Co-Ordinator's or Enabler's behaviour while the
   short-circuit went on citing a `none-selected` verdict reached under the
   old text. No resolved filesystem path enters the digest: `none-selected`
   fingerprints are compared fleet-wide across the shared log (requirement
   3b), so two nodes serving identical prompt bytes from different install
   paths must compute the same fingerprint, and relocating an installation
   without changing a byte of served content must not bust the
   short-circuit. The digest is a pure function of the override
   configuration and the contributing files' bytes, never of the node's
   filesystem layout.
4b. **The repo/work-sources table is generated from `config.json`, not
   hand-maintained in the prompt (issue #78).** `prompts/coordinator.md`
   carries a `@@WORK_SOURCES_TABLE@@` marker where a table naming consumer
   repos and their `sources` used to be hand-written — the prompt file names
   no real repo anywhere, including its worked examples, which use generic
   placeholder slugs instead. `lib/coordinator-brief.sh`'s
   `coordinator_work_sources_table` renders one Markdown row per entry of
   `config.json`'s `repos` array, numbering that repo's configured `sources`
   in the order given — the plain configured list, never a cycle's
   back-pressure-restricted view (requirement 2.2a), so the table always
   states each repo's full configured priority, matching what "Target
   repositories" above documents for this installation. The Script (after
   requirement 4a's `stage_prompt_text` has assembled the base prompt and any
   configured overrides) replaces every occurrence of the marker with this
   table before appending the runtime input. Adding a repo or reordering a
   repo's `sources` in `config.json` therefore changes the Co-Ordinator's
   brief with no edit to `prompts/coordinator.md` — the config-only change
   the README already claimed for this, now actually true. The rendered
   table joins the no-op fingerprint (requirement 3b) as its own input,
   `coordinator_work_sources_table`, computed from the plain configured
   `repos` array before the fingerprint is taken: the runtime input's
   `repos[].sources` is *not* sufficient cover on its own, because
   back-pressure (requirement 2.2a) narrows that array to a repo's finishing
   sources for one cycle while the table — and the prompt the Co-Ordinator
   actually reads — keeps showing that repo's full configured priority
   regardless, so a config edit to a non-finishing source landing during
   such a cycle would otherwise change the assembled prompt without busting
   the fingerprint.
4c. **An assembled prompt reaches its stage on stdin, never in argv.** Every
   stage this Script launches — the Co-Ordinator here, the Implementor
   (requirement 7), the Reviewer (requirement 8) and the Enabler
   (requirement 35) — is invoked as `claude -p` with the prompt written to
   the process's standard input, not as a command-line argument. Linux caps a
   single argv entry at `MAX_ARG_STRLEN`, 32 pages — 131072 bytes — a
   compile-time constant that no `ulimit` raises and that `getconf ARG_MAX`,
   which reports the far larger limit on the *total*, does not describe. The
   Co-Ordinator's assembled prompt is already of that order: its base file
   alone passed 60 KB in July 2026 and the runtime input it carries grows
   with the fleet's repo and work-source count, so the margin is measured in
   paragraphs and every prompt edit spends some of it. Exceeding it fails at
   `execve`, before any model is reached: the stage exits 126 with
   `Argument list too long` on stderr, the cycle records `attempt-failed` and
   then ends *successfully* with nothing selected (requirement 9 makes a
   failed stage a failed attempt, not a failed cycle), and the node is
   indistinguishable on the dashboard from one with no work to do. It is the
   silent-stall shape the no-op fingerprint rules exist to prevent, arriving
   by a different door — and, because prompts ship in the image, it arrives
   fleet-wide on the same image roll. The delivery mechanism is a here-string
   rather than a pipe so the invocation stays a single process whose exit
   status is the stage's own; under `pipefail` a `printf | claude` would
   report printf's SIGPIPE as the stage's result whenever a stage exited
   without draining its input. `review-cycle.sh` launches its stages through
   the same function (requirement 4d), so the review pipeline's smaller
   prompt — the one that would sit broken longest before anyone noticed — is
   covered by construction rather than by a second copy kept in step by hand.
4d. **One stage launcher, and it streams.** Every headless `claude`
   invocation either pipeline makes — the four stages of this document, the
   usage-limit probe of requirement 1b, and the Reviewer-Agent of
   `docs/REVIEW-PIPELINE-SPEC.md` R5.3 — goes through `run_claude_stage` in
   `lib/stage-run.sh`: one implementation, sourced by both cycle scripts,
   rather than a copy in each. It launches the invocation in its own process
   group (`set -m`), so the stage timeout's kill reaches every descendant
   (requirement 9c), and it runs the invocation under
   `--output-format stream-json --verbose`. An optional resume-session-id
   argument passes `--resume` instead of starting a fresh conversation —
   requirement 9e's salvage is the one caller that ever supplies it, and every
   other caller's invocation is unaffected. Each invocation therefore leaves
   three files beside each other:
   `<stage>.stream.jsonl` — every event the run emitted, one JSON object per
   line, flushed as the run proceeds; `<stage>.out` — that stream's final
   `result` event and nothing else; and `<stage>.out.stderr` — the
   invocation's diagnostics, kept in a separate file so stray output can
   never break the parse of the envelope.
   The streaming form is chosen for *when* its output arrives, not for its
   shape: `--output-format json` writes one object at the very end, so a
   stage killed at its cap leaves an empty file and nothing whatever is known
   about how far it had got, while a stream is a record of the run that
   survives the kill and is readable while the run is still going. What lands
   in `<stage>.out` is byte-for-byte the envelope the non-streaming form
   produced, so every reader of a stage transcript — the result parsers, the
   per-stage metering record (requirement 33a), limit detection (requirement
   2.1), the dashboard's own rendering — reads exactly what it read before. A
   stage that was killed, or that died before emitting a `result` event,
   leaves `<stage>.out` empty, which is the same degradation those readers
   already handle for a stage that never ran.
   The streams are **local-only**: they are excluded from the state
   replication in both directions and pruned to `state_local_streams_retained`
   directories (requirement 2.5). A `.out` is one JSON object; a stream is
   every message and every tool result, and the mirror holds `cycles_retained`
   cycles per node in git history, so replicating them would trade a bounded
   repository for an unbounded one.
4e. **Two caps on a stage, and they answer different questions.** Every stage
   is bounded by a **backstop** — the `timeout_<actor>` wall-clock cap, which
   `run_claude_stage` enforces by killing the process group — and by a
   **liveness watchdog**: `inactivity_<actor>` minutes during which the stage
   produced no output whatsoever. Whichever fires first kills the stage, by
   the same sequence (TERM to the process group, a five-second grace, then
   KILL) and with the same exit status, 124.
   The watchdog reads the stage's own event stream (requirement 4d): inside
   the poll loop that already runs every two seconds, it compares the file's
   size against the largest size seen. Liveness is **monotonic growth of that
   file** — not a beat count, not a timestamp inside the events, and nothing
   the stage cooperates in. There is therefore no cadence for a loaded node to
   miss: contention stretches every gap proportionally, and a threshold with
   several times the observed headroom absorbs that with no load-relative
   correction. A stage emits nothing for this and can fake nothing.
   The two caps exist because a single wall-clock number conflates "this is
   taking a long time" with "this has stopped", and the record says the
   pipeline only ever killed the first. Across 456 stage runs there is not one
   instance of a genuinely hung actor: every killed run was emitting steadily
   when the wall reached it, at a tempo indistinguishable from runs that
   succeeded. Nor is such a kill merely a delay — a killed Reviewer records no
   verdict, so the pull request reaches the human with no pipeline review at
   all and nothing in the merge record says the gate never ran.
   A third thing stops a stage, and it is not a cap at all: **the account
   saying no**. The stream carries the runner's own `rate_limit_event`, and a
   `rate_limit_info.status` of `rejected` means nothing the stage does from
   here can succeed. It is stopped on the spot. Limit detection (requirement
   10) has always run on the transcript *after* a stage ended, so a stage that
   hit a limit early went on holding the node for the rest of its cap while
   every call it made was refused.
   Only `rejected` stops a stage. The runner's vocabulary for that field is
   `allowed`, `allowed_warning` and `rejected`; `allowed_warning` means "you
   are close", which a stage must be allowed to run through, and any value not
   recognised is likewise left alone to fall through to the phrase matcher
   that has always handled this. The asymmetry is deliberate and is §3.2's:
   failing to abort early costs the rest of a wall-clock cap, while aborting a
   healthy stage throws away everything it had done. The check is made only on
   an event of the runner's own — a top-level `rate_limit_event`, never a
   string inside a tool result, since an Implementor working on limit
   detection reads fixtures shaped exactly like one.
   The `rate_limit_info` that stopped the stage becomes the stand-down's
   evidence, and is better evidence than the prose path can produce: it states
   `resetsAt` as an epoch, so `reset_known` is `true` and the fleet is spared
   the usage probe requirement 1b spends on every cycle of an *estimated*
   stand-down. It is also the only source available on this path at all — a
   stage stopped at the refusal never writes a final message for the phrase
   matcher to read. `lib/limit-detect.sh`'s `limit_decide_structured` maps it
   to the same `resume_at`/`class`/`reset_known` triple the prose path
   produces, so the two cannot yield differently-shaped stand-downs, and
   declines rather than guessing when the record says nothing usable.
   **`kill_reason`** distinguishes all three on the `stage-end` /
   `review-stage-end` event: `inactivity`, `backstop` or `rate-limit`, and
   absent when the stage ended on its own. `exit_code: 124` cannot carry it,
   and they imply different corrections — a backstop kill argues the cap is
   too tight for work that was progressing, an inactivity kill argues the
   stage stopped, and a rate-limit stop argues nothing about the caps at all.
   The `attempt-failed` detail says which in words, for the Enabler and for
   whoever asks why the item is blocked.
   A watchdog kill also logs a **`warning`**. Its kill path had fired zero
   times in the whole recorded history when it was built, so the first firing
   is news either way: a wedged actor caught, or a threshold too tight for
   something a stage legitimately does — which would be this mechanism
   reintroducing, from the other side, the failure it exists to end. The rate
   is the thing to watch, and a rate nobody is told about is not watched.
   **Neither cap is a configured constant.** Both are derived per
   (actor, repository, model) by requirement 4f, from a shipped prior when
   there is no history to derive from — the watchdog's prior being ten
   minutes, roughly three and a half times the longest run-average gap ever
   recorded and far above anything a healthy stage has been seen to do. A key
   present in the configuration is an override and wins; `0` disables the
   watchdog for that actor and leaves the backstop as the only cap. Erring
   generous is deliberate, because the loss function is asymmetric: too
   generous costs the marginal minutes of a session that was going to fail
   anyway, bounded by the backstop above it, while too tight throws away
   everything the stage had done.
   **`scripts/doctor.sh` proves the signal exists on this node.** The watchdog
   is worthless if the runtime buffers stdout when the destination is not a
   tty: the file would stay empty until the run ended, and every healthy stage
   would be killed at its threshold. So the doctor makes one real invocation
   of the cheapest configured model and samples the stream *while it is still
   running* — a finished run looks identical either way — and fails loudly,
   naming the `inactivity_*` escape hatch, if the output arrived only at the
   end. It is the one check there that spends, for the reason requirement 1b's
   usage-limit probe spends: some questions can only be answered by asking.
4f. **Both caps are derived, per (actor, repository, model), from the
   pipeline's own record of itself.** Requirement 4e gives every stage a
   backstop and a watchdog; this decides what those two numbers are.
   `lib/stage-budget.sh` folds the fleet log union — the same stream the
   blocked extract, the void extract and the no-op fingerprint read — into one
   table per cycle. Nothing is stored: a derived value is a pure function of
   events every node already shares, so four nodes agree with nothing to
   replicate and no controller state to reconcile.
   **The cell is `(actor, repository, model)`.** Not the actor alone —
   reviewing this repository costs three to four times what reviewing the
   others does, because every diff is checked against a five-thousand-line
   specification, and that cost rises with every edit to it. Not
   `(actor, repository)` either: the strongest single predictor of how long a
   stage runs is the model it ran under, and a cell pooling two of them has a
   bimodal duration distribution that no single moment or quantile describes.
   Complex-model reviews here run about twice as long at every quantile as
   default-model ones and were killed roughly six times as often; a controller
   given their average holds a cap far too tight for one and needlessly loose
   for the other, and converges for neither. Node is deliberately *not* a
   dimension, though nodes differ in speed: it would cut the largest cell to
   about eleven runs and the interesting one to about five, and no estimator
   recovers a distribution's tail from five observations — while the tail is
   the entire quantity of interest. The Co-Ordinator and the Enabler are keyed
   `(actor, *, model)`: the first runs before selection and the second spans
   repositories, so neither has one.
   **The watchdog threshold is estimated; the backstop is controlled.** They
   are different quantities and deserve different instruments, and splitting
   them is also what removes any wait for data. The threshold's sample is
   inter-event gaps (requirement 33a), so a single long stage yields
   observations of the thing being measured and a new repository has a usable
   distribution within a few cycles. A run duration is one observation per
   stage per cycle, which is genuinely slow — so the backstop is not fitted at
   all.
   *The threshold* is `k x max(gap)` over the window, k defaulting to four,
   shrunk towards the pooled estimate and floored at the shipped prior. The
   maximum rather than a mean plus so many standard deviations is the
   load-bearing choice: a run killed for inactivity at threshold `T` records a
   maximum gap of `T`, so the next threshold computed from it is `k x T` and
   the estimator *widens* under censoring. A mean-plus-sigma rule takes the
   same censored observation in below its true value, pulls the estimate down,
   tightens the threshold and censors more — a spiral that, simulated over the
   real distributions, never converges and never recovers the tail. It also
   assumes nothing about the distribution, which matters because gaps are
   heavy-tailed. It never narrows below the prior whatever the data say, and
   never exceeds the backstop above it.
   *The backstop* is a multiplicative-increase, additive-decrease controller,
   folded over the cell's runs in time order. It is the mirror image of the
   congestion control the shape is borrowed from, and deliberately: there the
   danger is a window grown too large, so it backs off hard and recovers
   slowly; here the danger is a cap set too small — that is what destroys a
   stage — so the sharp move is upward and the cautious one downward. A
   backstop kill multiplies the cap, being the only unambiguous evidence it is
   too tight and precisely the censored observation that broke the estimator
   approach. A step down needs three things at once: a run of clean stages, an
   observed kill rate inside the objective, and a 95th percentile of
   *completed* runs still well clear of the reduced cap. A killed run
   contributes no duration at all — its recorded length is its cap, not its
   length. Floors and ceilings bound the fold: never below the prior, never
   below twice that percentile, never above a fixed multiple of the prior, and
   when floor and ceiling disagree the floor wins, because throughput is a
   preference and discarding a finished stage is not.
   **Cold start is hierarchical shrinkage, not a threshold.** A cell's
   estimate is `(n·own + n₀·prior) / (n + n₀)`, with the prior the pooled
   value one level up — the same actor and model across every repository,
   falling back to the same actor across every model, and the shipped prior at
   the root. There is no run count at which a cell switches on; it slides.
   That is what makes the model dimension affordable: a model used twice in a
   repository contributes almost nothing of its own and sits essentially at
   the pooled estimate, rather than producing the wild cell a hard split would
   give. An installation with no history at all runs on the shipped priors,
   which is the whole requirement — a customer must never be asked to choose a
   timeout, and must get sensible behaviour on cycle one.
   **Precedence, most specific first:** a `stage_timeouts` /
   `stage_inactivity` entry on the repository being worked; the plain
   `timeout_<actor>` / `inactivity_<actor>` key; the adaptive value for the
   cell; the shrunk pooled value for the actor; the shipped prior.
   Configuration outranks the derivation deliberately — an installation that
   has said what it wants is not to be argued with — and, just as
   deliberately, **the pipeline never writes to `config.json`**: a customer's
   configuration stays theirs, and a self-tuning value can never become
   pull-request churn in somebody else's repository. The corollary is that a
   configured cap pins itself permanently, which `scripts/doctor.sh` warns
   about, because a number set once and forgotten looks exactly like a system
   still adapting.
   **Every value is announced.** The `stage-start` /
   `review-stage-start` event carries `backstop_min`, `inactivity_min`,
   `source` (`config`, `cell`, `pooled` or `prior`) and `basis` (`own`,
   `shrunk` or `prior`), so a reader looking at a stage finds the numbers it
   was given and where each came from; `scripts/doctor.sh` reports the whole
   table; and the dashboard holds a live stage against the cap that stage was
   actually given rather than against a shared constant. A self-tuning number
   that cannot be traced is a mystery number.
   **`lock_stale_after` is derived, not asserted.** It was a constant checked
   against other constants, and that check had to be re-derived by hand every
   time any of them moved — three times in the two days before this was
   written, each raise forcing a knock-on recalculation somewhere else. The
   threshold is now the sum, over the four actors, of the widest backstop each
   could draw this cycle, plus slack; a configured `lock_stale_after` is a
   floor under it rather than the value. Erring long is close to free, because
   a dead holder is taken over on its pid rather than on its age, so this
   bounds only how long a live but hung cycle may hold on. The review
   pipeline derives its own the same way, doubling the widest Reviewer-Agent
   backstop because one lock can span two repositories reviewed back to back.
5. If the work order is `{"selected": false}`, log `none-selected` with the
   Co-Ordinator's reason **and the fingerprint computed in requirement 3b**
   (omitted entirely, not stored empty, when the cycle was unfingerprintable —
   the next cycle must find no fingerprint rather than an empty one it could
   match against an equally empty sample of its own), release the lock, and
   exit. This event is the only thing that makes the next cycle cheap.
6. **Workspace.** Create `workspace_root/<cycle-id>/` and clone the selected
   repo into it, fresh from GitHub. This applies the multi-agent
   ways-of-working rule shared by all Poetic repositories: every agent works
   in its own dedicated fresh clone taken from the tip of the default branch
   before commencing any changes. (A full clone — stages may rebase onto a
   `default_branch` that has moved and need the merge base.) Agents only
   ever run inside this
   workspace; the Script must refuse (assert) to launch a stage whose
   working directory is outside `workspace_root`. The user's own clones
   under `~/Code` are never touched.
6a. **The pipeline creates its own labels.** Before launching the Implementor,
   the Script ensures every label this system applies exists in the selected
   repository, creating only those that are absent: `pr_label`,
   `enabler_escalation_label`, `needs_refinement_label`, `unvoid_label`,
   `complexity:low|medium|high`, and `blocked` — the last being the human's own
   exclusion control (requirement 16.4), which a repository without the label
   does not offer them at all. `review-cycle.sh` does the same for
   `review.pr_label` in each repository it is about to review, and
   `create_escalation_issue` for `enabler_escalation_label` in the repository
   an escalation is filed in, which is often one no cycle otherwise touches.
   A label whose configured name is empty is switched off and is not created.

   Three properties are load-bearing. It **only ever creates**: an existing
   label keeps whatever colour and description it has, because operators
   recolour labels and a pipeline that reasserted its own idea of them every
   cycle would undo that work on a schedule. It is **never fatal**: a
   repository whose labels cannot be listed, or a token that may not create
   them, is reported and nothing more — the tolerances the callers already
   carry (`refinement_label_add`'s swallowed error, requirement 36a's retry
   without the label) stay exactly where they are, so this makes the common
   case work without becoming a new way to lose a cycle. And it is **per
   worked repository, not per configured repository**: a cycle works one repo,
   so the steady state is a single listing and no writes at all.

   Why it exists: every one of these labels was previously something a human
   had to create by hand in every target repository, and nothing said so when
   they had not — the projection simply did not happen and the item was
   handled anyway, so the signal the label exists to give was silently absent.
   That is a product bug rather than an installation's own problem (the
   customer-zero rule, `docs/ROADMAP.md`): a new installation must not need a
   checklist of `gh label create` commands, and a label a human deletes must
   come back on its own.
7. **Implementor stage.** Launch the Implementor in the clone (model from
   the work order, `--dangerously-skip-permissions`, stage timeout), passing
   the implementor prompt plus the work order, and this cycle's `cycle` id and
   `node` name — because any comment the Implementor leaves must carry
   requirement 9d's header and requirement 3e's marker, and a model cannot
   know either on its own.
8. **Reviewer stage.** If the Implementor reports `complete`, launch the
   Reviewer in the same workspace (model per requirement 8a, same flags,
   stage timeout), passing the reviewer prompt, the work order, the
   Implementor's summary (PR URL, branch, complexity), and this cycle's
   `cycle` id and `node` name — the same reason as the Implementor's above.
8a. **The Reviewer's model follows the item's complexity.** The Script
   resolves an effective complexity for the PR and launches the Reviewer with
   `reviewer_model_complex` when it is `high`, `reviewer_model_default`
   otherwise. Resolution takes the **highest** of two signals, either of which
   may be absent: the `complexity` field of the Implementor's summary
   (requirement 27) and the PR's `complexity:*` label (requirement 26a), read
   best-effort via `gh pr view --json labels` — an unreadable label simply
   contributes nothing. Taking the maximum is what makes the label's
   raise-never-lower rule hold at the decision point too: a PR once graded
   `high` is reviewed as `high` in every later finishing round, however small
   that round's own work was. When *neither* signal exists, the fallback is
   `low` for a work order the Co-Ordinator classified trivial (its `model` is
   `implementor_model_trivial`, requirement 19 — the classification already
   answers the question, so the trivial tier is never asked to self-grade)
   and `medium`, the default tier, otherwise. The Reviewer's `stage-start`
   event carries the resolved `complexity` and the chosen `model`
   (requirement 33), which is what lets the distribution of self-assessments
   be audited for drift.
9. **Failure handling.** If any stage times out, exits non-zero, or returns
   an unparseable summary: kill that stage's process group, log
   `attempt-failed` with enough detail for a future cycle to know the item
   is blocked and what would unblock it, and — if a draft PR was already
   opened — comment on it that the agent has abandoned it and why, leaving
   the PR and branch for the human to keep or discard.

   Naming that pull request is the Script's job, not the failed stage's, and
   it tries four things in order, each less dependent on the stage than the
   last: the `pr_url` of a parseable final message; a pull-request URL
   grepped from the stage's output; the `.git/agent-ops-pr-url` breadcrumb in
   the clone (requirement 23); and finally an open pull request whose head is
   the branch this cycle claimed (requirement 17a), asked of GitHub directly.
   **The last of those is the one that must exist**, because the first three
   are all things the Implementor had to remember to do, and a stage that
   emitted no parseable final message is exactly a stage that may have
   remembered none of them — whereas the branch was computed and pushed by
   the Script before the stage began. Each lookup coming up empty is an
   ordinary outcome, not an error: under `errexit` a non-zero from any of
   them kills the cycle before it logs the very failure this requirement is
   about (see Gotchas).

   The consequences of failing to name it are not confined to this
   requirement, which is why the fourth lookup is required rather than
   merely sensible: no stage-failure comment reaches the pull request
   (above), no `pr_url` travels on the `attempt-failed` event (requirement
   32a), and so the Enabler's one power to clear this kind of block by act
   rather than by verdict — `complete_handoff`, gated on that field
   (requirement 32b) — is unavailable for precisely the failure it exists to
   recover.
9a. **A reported verdict is not a failure.** A stage that runs to completion
   and ends with `{"status": "blocked", …}` or `{"status": "void", …}`
   (requirement 27) has not failed: it has spent a full model run
   establishing something worth keeping. Record it against the selected item,
   carrying the stage's own words verbatim, rather than routing it through
   requirement 9's path (which would file it as "exited 0", discarding what it
   found) or, worse, dropping it. This is what stops the pipeline buying the
   same discovery every cycle for as long as the item exists.
9b. **`blocked` and `void` are different states and must not share one.**
   This is the requirement most likely to be read as pedantry and collapsed
   into "an item that can't proceed". Do not.
   - **`blocked`** — the work is real, something is in the way *for now* (an
     unmerged dependency, a red check, a decision nobody has taken). Record
     `attempt-failed` with the stage's `reason` and `unblock_condition`. The
     Co-Ordinator is expected to re-check these and clear them (`unblocked`)
     when the impediment lifts.
   - **`void`** — there is no work: the premise is false, almost always
     because the item is already done on `default_branch`. Pass the stage's
     `reason` and `evidence` through requirement 34d's shared corroboration
     guard first; record `item-void` only if it passes, `attempt-failed`
     (outcome `void-refused`) if it does not. **No agent may ever clear a
     recorded void**; only a human, by appending `unvoided` to the log by
     hand.
   The failure mode if you merge them is specific, silent, and was found in
   production rather than in review. An already-done recommendation is filed
   as `blocked`. The next Co-Ordinator, obeying its standing instruction to
   clear blockers that have gone away, checks the item, finds the work is
   done, correctly concludes that nothing is in its way, and logs `unblocked`.
   The item returns to the pool, is selected, is rediscovered as already done,
   and is filed again — indefinitely. Every component behaves exactly as
   specified. The bug is that one channel carried two meanings, so the
   evidence that should have shut the item forever (*the work is done*) was
   the very evidence that reopened it. If a state can be cleared by the same
   fact that ought to make it permanent, it is the wrong state.
9c. **A signal is a failure with a record.** The Script traps `TERM`, `INT`
   and `HUP` from the moment its cleanup trap is armed. The kills that reach
   it are real and routine — a peer taking over a stale lock TERMs the whole
   process group (requirement 1), an operator stops a container, a `--once`
   run is interrupted at the terminal — and before this requirement any of
   them ended bash between one statement and the next: no `attempt-failed`,
   no claim release, no `cycle-end`, and the in-flight stage's own process
   group (detached from the Script's by design, so the timeout can kill it
   whole) left running a model for a cycle that was already dead. The
   handler, in an order that is itself the requirement:
   1. kills the in-flight stage's process group, if any, with KILL — the
      signaller's patience is unknown and may be two seconds, and a stage
      whose cycle is dead has nothing left to negotiate;
   2. logs `attempt-failed` against the selected repo+item where one exists
      (so requirement 34's blocked extract sees the death), with detail
      `<stage> terminated by SIG<name>` naming the stage that was in flight
      — or `cycle` when none was — and carrying `pr_url` when the
      requirement-23 breadcrumb identifies one (read before the clone is
      deleted, since the breadcrumb dies with it);
   3. releases the claim (`have-pr` when a PR is known, `no-pr` otherwise),
      time-bounded to 8 seconds — releasing now beats waiting out the gc's
      `claim_ttl_hours`, but not at the price of the exit record — and
   4. exits `128+n` through the ordinary `exit`, so the EXIT trap still
      writes `cycle-end` with a truthful code, releases the lock and pushes
      state, and `maybe_run_enabler`'s cycle_rc guard skips the Enabler
      without being asked.
   A stage that had already ended cleanly is never blamed: the stage
   pid/name pair is advertised only while a stage is in flight. A signal
   landing during cleanup itself must not re-enter the handler.
   `review-cycle.sh` carries the same discipline as R7a of its own spec.
9d. **Visible attribution.** Every pull-request or issue comment this system
   posts — from `agent-cycle.sh` directly, and from the Implementor, Reviewer
   and Enabler — opens with a leading bold line naming the Actor that wrote it
   and the node it ran on:

   ```
   **<Display>** · autonomous pipeline · node `<node>`
   ```

   then a blank line, then the comment's own prose. The Actor is whichever
   stage **wrote** the comment, not the one it is about — the Script's own
   stage-failure note carries `**Script**`, with the stage that failed named in
   the prose (`The Implementor stopped on this PR: …`), spelled from the same
   token→display map below, and no other preamble.
   This exists because requirement 3e's own text already states the reason no
   other signal can: every pipeline write lands under `warwickallen`, the same
   GitHub account a human also comments as, so the author field cannot tell a
   human's comment from the pipeline's, including which comments are a human's
   own. `lib/pipeline-marker.sh`'s `pipeline_comment_header ACTOR NODE` prints
   the line; `pipeline_actor_label TOKEN` is the token→display map, matching
   this document's and `docs/REVIEW-PIPELINE-SPEC.md`'s *Actors* sections and
   the vocabulary `dashboard/index.html`'s `ACTOR` map already uses, and it
   fails open on an unknown token — prints it raw — so an Actor added later
   degrades gracefully rather than vanishing from a comment. `agent-cycle.sh`
   and `review-cycle.sh` call it directly; a model cannot source shell, so
   `prompts/implementor.md`, `prompts/reviewer.md` and `prompts/enabler.md`
   each spell the header's literal form out and instruct their stage to open
   every comment with it, using the node name each receives at invocation
   verbatim (`## Node` for the Implementor and Reviewer; the runtime input's
   `node` for the Enabler, which already received it). Regression-tested by
   `test/comment-identity.test.sh`.
9e. **Salvage before discard.** Before requirement 9's failure path fires on
   an unparseable final message — the Co-Ordinator, Implementor and Reviewer
   stages here, and requirement 37's Enabler engagement — the Script makes
   one bounded resume attempt, provided the failed run actually left a
   session behind to resume: `run_claude_stage` again, `--resume`d onto the
   `session_id` the failed run's own envelope carried, prompted with nothing
   but "return the verdict JSON object, nothing else." A run that timed out
   or exited non-zero has no living session behind it and is never salvaged
   — only a process that exited 0 and still left `extract_json_result`
   nothing to parse gets the attempt (`stage_salvage_result`,
   `agent-cycle.sh`). The resume is capped at a fixed, conservative
   `stage_salvage_backstop_sec`/`stage_salvage_inactivity_sec` (5 minutes /
   90 seconds) rather than requirement 4f's adaptive per-(actor, repository,
   model) budget — a continuation with no tool calls needs none of that
   estimation, and a bound that could grow to a whole stage's own backstop is
   not a bound worth having.

   When the resume's own final message parses, its object is used exactly as
   if the original run had produced it — no failure is recorded here, no
   `attempt-failed`, no discard — and a `salvage` event with
   `outcome: "recovered"` is logged (requirement 33). When it does not
   (including when there was no session to resume at all), requirement 9's
   ordinary failure path runs unchanged, `salvage` events record
   `outcome: "attempted"` and `outcome: "failed"` for the attempt, and the
   resume's own use of `run_claude_stage` never leaks into the *original*
   run's kill-reason, gap or rate-limit bookkeeping — `stage_salvage_result`
   saves and restores them around its own call, because
   `detect_and_log_limit_hit` still reads them against the original `.out`
   file afterwards and must see what that run actually reported, not what
   the resume did.

   The fenced-block parse this backs up is itself widened alongside it: a
   verdict fenced without a `json` info string, or with a different one,
   parses on the straight fallback and never needs a salvage at all — only
   the fence's *presence*, not its tag, was ever what told a verdict apart
   from prose (issue #237).

   This exists because a model slipping the final-message contract is not
   evidence the work itself was wrong. On 2026-08-07, poetic-2's completed
   conflict resolution of PR #205 was correct, fenced without a `json` tag,
   and discarded anyway — erasing the pipeline's memory that the conflict
   was fixed and triggering a three-node duplicate-work cascade on the same
   PR. A background task left running past the final message ("I'll check
   back shortly") is the same shape from the runner's side: real work,
   wrapped wrong. A discard should cost a retry only when a stage genuinely
   produced nothing usable, not when the parser of the day could not yet see
   what it produced.
10. **Usage-limit detection.** Two sources, and the structured one is
    preferred wherever it exists. When a stage was stopped because its stream
    reported the account `rejected` (requirement 4e), the `limit-hit` is
    derived from that `rate_limit_info` by `limit_decide_structured`: it
    states `resetsAt` as an epoch, so the stand-down is a fact rather than an
    estimate, and it is the only source available on that path at all, since a
    stage stopped at the refusal writes no final message for a phrase matcher
    to read. Otherwise — and whenever any `claude` invocation's transcript
    matches the shared pattern in `lib/limit-detect.sh` (`LIMIT_PHRASE_REGEX`
    — the generic `hit your .* limit` stem plus the legacy `usage limit` /
    `rate limit` / `usage cap` / `quota exceeded` terms; sourced by both the
    Script and `scripts/publish-dashboard.sh` so the two can't drift apart) —
    it is parsed out of the prose. Either way the event is a `limit-hit`
    carrying the same three fields, because no reader downstream should have
    to know which source produced it: `resume_at`, `class`, and
    `reset_known`:
    - `resume_at` is parsed from an ISO-8601 timestamp in the message if
      present, else from a human-readable weekly reset clause (e.g. "resets
      Jul 17, 4am (Pacific/Auckland)" — the named zone is applied via `TZ`,
      not left in the string for `date -d`, and never combined with `date -u`
      in the same call, which would silently override the named zone), else
      a fallback: now + `limit_cooldown_default` for an ordinary/transient
      match, or now + a much longer cooldown (`LIMIT_LONG_COOLDOWN_HOURS`,
      ~1 day) when the phrasing says "weekly" or "monthly" and no reset time
      could be parsed at all — that fallback is too short for something that
      recurs on a multi-day cadence.
    - `class` is `weekly`, `monthly`, or `other`.
    - `reset_known` is true only when a reset time was actually stated in the
      message. False means `resume_at` is the fallback above — this system's
      own retry interval, carrying no information about the real reset — and
      everything reported to a human must say so rather than presenting it as
      a deadline.

    `reset_known` replaced a `needs_human` flag that claimed the spend-cap
    case "clears only when a human raises the cap". Every limit has two
    exits: the plan's rollover, which needs no one, and a cap increase, which
    needs a human and only if sooner is wanted. Calling the first exit
    nonexistent turned an unknown reset time into an apparent dead end.
    Readers accept the superseded field during a rollout, inverting its sense
    (`lib/limit-detect.sh`'s `limit_reset_known`), so a peer on the previous
    release is not misread as authoritative.

    There is no supported API for querying a subscription plan's remaining
    quota, so this fail-safe detection *is* the quota check, and
    back-pressure (2.2) is the primary spend control. `resume_at` is an upper
    bound to stand down *until*, never a promise the block lasts that long —
    but nothing inside a cycle can shorten it, because 2.1 stands the cycle
    down before any stage runs. Lifting it early is `--clear-limit`'s job and
    only `--clear-limit`'s.
11. **Cleanup.** Always: delete the cycle's workspace, engage the Enabler if
    this cycle should (requirement 35), write a `cycle-end` event, release the
    lock. Tee each stage's stdout/stderr to `state_dir/cycles/<cycle-id>/` for
    debugging.
12. **Flags.** `--dry-run` (run through step 5 then stop: prints the work
    order, launches no Implementor), `--once` (one verbose cycle in the
    foreground), `--repo <slug>` (restrict selection, for testing),
    `-h`/`--help` (print the usage text and exit), plus the
    switch's `--disable [<reason>] [--for <duration>] [--until <timestamp>]`,
    `--enable` and `--status` (requirement 2.3), which manage the switch and
    run no cycle.

    The usage text describes every flag the Script accepts, `--help`
    included: a flag the parser honours but the usage omits is one an
    operator can only find by reading the source.

    `--clear-limit [<reason>]` lifts a usage-limit stand-down (2.1) and runs
    no cycle either. It is deliberately not `--enable`: the switch and the
    stand-down are separate states with separate causes, and one command for
    both would let an operator clearing a spend cap silently re-enable a
    pipeline another agent had disabled to edit these files. It clears both
    carriers, reports what it lifted and what it could not, and warns loudly
    on a failed flag delete — a flag left set keeps every node down after the
    operator believes they have resumed. The reason is optional, unlike
    `--disable`'s: a stand-down being lifted is self-explanatory in a way one
    being imposed is not.
13. The Script must pass `shellcheck` and must set its own `PATH` explicitly
    (cron's environment is minimal), covering `claude`, `gh`, `git`, `jq`.
    When provisioning a host, prove that a cron-style invocation can resolve
    `claude` by running it from a minimal environment (for example with a
    sanitized `PATH` and `HOME`) before relying on scheduled runs.

### The Co-Ordinator (selection only)

14. Works read-only: `gh` reads (runs, PRs, file contents via
    `gh api`) — it does not clone, and writes nothing but its final message.
    For the `security` and `code-quality` sources it does **not** re-query the
    Dependabot/code-scanning APIs itself; it reads the pre-fetched `findings`
    array the Script attached to each repo (requirement 3a). The `issues`
    source likewise: its candidates are the pre-fetched `issues` array
    (requirement 3j), threads included, and an empty array is a repo with no
    issue candidates, never issue data withheld. The `failed-runs` source has
    no array and never did — it is queried live, and "not pre-fetched" means
    "go and look", not "skip". The remaining `gh` budget goes on the cheap
    claim/blocked checks below and on reading what an item references.
14a. **An issue is its whole thread, not just the opening post.** Whenever it
    evaluates or selects a GitHub issue, the Co-Ordinator reads the body *and
    every comment*. For `issues`-source candidates both arrive in the array
    entry (`body`, `comments` — verbatim); for an issue outside the array (one
    another item references, or a blocked issue the array's filter dropped),
    it fetches the thread — `gh issue view <n> --comments` (or `gh api
    repos/<slug>/issues/<n>/comments`); a bare `gh issue view <n>` or `gh api
    .../issues/<n>` returns only the body and silently drops the comments,
    where the parts that decide the work routinely live: added acceptance
    criteria, clarifications or corrections to the original ask, scope cuts, a
    "blocked"/"won't do" note, or a maintainer turning a discussion into an
    actionable task. A later comment that contradicts the body is the current
    instruction; the body alone is never taken as the whole ask.
15. Walks the repos in the order given. Within a repo, checks work sources
    in the configured priority order. For "failed Actions runs", a candidate
    exists only where the **most recent** run of a workflow on the default
    branch is a failure (a later green run supersedes older failures). The
    `security` source's candidates are the pre-fetched `findings` with
    `source: "security"` (Dependabot alerts and security-severity
    code-scanning alerts); the `code-quality` source's candidates are the
    `findings` with `source: "code-quality"`. The `project-review` source's
    candidates are the recommendations (`R-NN`) in the **most recent**
    `reviews/project-review-YYYY-MM-DD/` folder on the default branch: read
    that folder's `03-recommendations.md` and `04-improvement-prompts.md` via
    `gh api .../contents/...` (no pre-fetch — these are ordinary tracked files,
    like `TECH-DEBT.md`). A recommendation's stable ref is
    `review-<review-date>-R-NN`; the paired improvement prompt is the brief.
    The `issues` source's candidates are the pre-fetched `issues` array
    (requirement 3j), and it appears at four ranks rather than one, banded by
    each entry's `priority` — see requirement 15e. The `implementation-plan`
    source's candidates are the next unblocked task(s) in the repo's own plan
    document, read at the path in that repo's runtime-input
    `implementation_plan_path` (requirement 3k) — no pre-fetch, and no path
    named in the prompt.
15b. **Review feedback comes third, across all repos.** Like security and
    urgent issues, this outranks the plain repo-then-source walk: any selectable
    `review_feedback` candidate in any repo is taken before any work below it
    elsewhere. The
    human is this system's only consumer and its scarcest resource; when they
    have spent their time and asked for something specific, answering beats
    starting something new — and the work is already 90% done. The Co-Ordinator
    must **not** apply requirement 16's claim exclusion to this source: the open
    PR *is* the item, and excluding it makes every candidate permanently
    unselectable while looking entirely correct.
15d. **Merge conflicts come fourth, across all repos.** After security, urgent
    issues and review-feedback, and likewise outranking the plain
    repo-then-source walk: any
    selectable `merge_conflicts` candidate in any repo is taken before any fresh
    work in a more-overdue repo. The PR is otherwise ready — a human is waiting to
    land it — and until the conflict is resolved nothing else on it can proceed, so
    a rebase-and-resolve is finishing, not starting. As with review-feedback, the
    Co-Ordinator must **not** apply requirement 16's claim exclusion to this
    source — the open PR *is* the item, and the pre-fetch (requirement 3g) has
    already established it is ours and conflicting. The Implementor's job here is
    narrow: rebase onto the base and resolve the conflict, without completing or
    re-doing the underlying item (that is what merges the PR, and remains the
    human's call).
15c. **Abandoned drafts come fifth, across all repos.** After security, urgent
    issues, review-feedback and merge-conflicts, and likewise outranking the plain
    repo-then-source walk: any selectable `abandoned_drafts` candidate in any repo
    is taken before any fresh work in a more-overdue repo. A previous cycle already
    implemented most of the work behind that draft, so finishing beats starting;
    and every hour it sits stalled it holds a back-pressure slot that throttles new
    work fleet-wide. As with review-feedback, the Co-Ordinator must **not** apply
    requirement 16's claim exclusion to this source — the open draft PR *is* the
    item, and the pre-fetch (requirement 3e) has already established it is stale
    and ours, so treating it as a claim would make every candidate permanently
    unselectable.
15a. **Security is always prioritised.** Beyond `security` being first in the
    source order, any candidate that is security-related — a `security`
    finding, a GitHub issue labelled `security`/`vulnerability`, a
    tech-debt entry flagged as a security concern, or a `project-review`
    recommendation whose text flags a security concern — outranks every
    non-security candidate across all repos and sources. If any selectable
    security candidate exists anywhere, the Co-Ordinator selects one of those
    before any non-security item, with the most severe first
    (`critical` > `high` > `medium` > `low`). Repo ordering (requirement 3)
    breaks ties among security candidates of equal severity.
15e. **Issues rank by their `Priority` field.** An open issue's band is its
    organisation-level `Priority` issue field — `Urgent`, `High`, `Medium` or
    `Low` — and the band is the issue's rank in the walk, as
    `issues:urgent` / `issues:high` / `issues:medium` / `issues:low` in the
    repo's configured `sources`:

    - **`Urgent` is a global tier, second only to security.** Like
      review-feedback, merge-conflicts and abandoned-drafts, it outranks the
      plain repo-then-source walk: if any selectable urgent issue exists in any
      repo, it is taken before any non-security item anywhere — including ahead
      of the three finishing sources. Those tiers exist because finishing beats
      starting; `Urgent` is the one signal that outranks even that, because it
      is the human stating outright that this cannot wait, and a top band that
      still queued behind three other tiers would not mean what it says. It
      cannot starve the finishing sources either: back-pressure (requirement
      2.2a) narrows the cycle to exactly those three once
      `max_open_agent_prs` is reached, and that gate is applied to the runtime
      input before the Co-Ordinator sees it.
    - **`High` sits between failed-runs and tech-debt** in the per-repo walk.
      Below a red default branch, which is repo-wide breakage that blocks every
      other item's checks; above tech-debt, which is by construction work that
      was already judged deferrable.
    - **`Medium` sits between tech-debt and the implementation plan** — exactly
      where the unbanded `issues` source ranked before this requirement existed.
    - **`Low` sits between project-review and code-quality**: still a human's
      filed, deliberate request, so above the automated quality suggestions, but
      below the review recommendations a human approved without marking them
      least-pressing.

    **An issue with no `Priority` set is `Medium`.** The default is not
    "unranked" and never "lowest": an untriaged backlog must behave exactly as
    it did before banding existed, so that setting the field is what moves an
    issue and leaving it alone changes nothing.

    The band arrives on each pre-fetched entry as `priority`, derived by the
    Script (requirement 3j) from the REST issues endpoint, whose payload
    carries `issue_field_values`; the band is the `single_select_option.name`
    of the entry whose `issue_field_name` is `Priority`. `gh issue view
    --json` does not expose issue fields, which is why the REST listing is
    the one surface it can come from. Anything that is
    not one of the four names — absent, empty, unreadable by this token, or a
    value the organisation added later — is `Medium`, which keeps an
    unrecognised or invisible field a no-op rather than a re-ranking.

    Banding changes rank and nothing else. Within a band, candidates are
    evaluated oldest issue first, and every other rule that applies to an issue
    applies unchanged: requirement 14a's whole-thread read, requirement 16's
    exclusions, requirement 15a (a `security`-labelled issue is security work
    whatever its band, including a `Low` one), the bare issue number as the item
    ref, and `"source": "issues"` in the work order (requirement 21) —
    downstream consumers never see the band.
16. Excludes from candidacy any item that is:
    - recorded as blocked in the shared log (an `attempt-failed` event not
      followed by an `unblocked` event for that item) — for a GitHub issue,
      only once requirement 18a's mandatory re-check, where it applies, has
      found the recorded blocker still holds;
    - a tech-debt item whose status is `in-progress` (its item file's
      `status:` frontmatter);
    - already referenced by any open PR or draft (a claim, per the repos'
      claiming workflow), or its repo+item appears in the pre-fetched
      `claimed` array (requirement 3o) — a peer node's claim, by either shape,
      even one that has not yet surfaced as a draft PR; the Script's own
      atomic claim in requirement 17a is the hard gate, this exclusion merely
      avoids proposing work that will lose the race. Unlike the open-PR half,
      there is nothing to check live here: `claimed` is exhaustive over both a
      registry entry and a live `td/<ID>`/`agent/<item-ref>` branch, already
      age-filtered to `claim_ttl_hours`, so an entry present excludes and an
      entry absent (or aged out) does not — for
      a `security`/`code-quality` finding, that means
      an open PR whose branch or body already references the same alert
      (`ref`, alert URL, or the affected package/rule); for a `project-review`
      recommendation, an open PR whose branch or body references its ref
      (`review-<date>-R-NN`);
    - a `project-review` recommendation that is already **done** — a *merged*
      PR references its ref (`review-<date>-R-NN`) — or that is already owned
      by a higher-priority source: the review mirrors debt-shaped
      recommendations into the tech-debt register (or files them as issues)
      cross-referencing the `R-NN`, so a recommendation cross-referenced by a
      current tech-debt entry or open issue is left to that source and skipped
      here. (A single `gh` PR search per repo for the review date surfaces the
      open/merged/closed PRs referencing that review; match refs against it.)
      Note that a merged PR is a *floor*, not a proof: work that landed as a
      direct commit, or before the repo required PRs, leaves no PR to find and
      so reads as outstanding forever. The cross-reference is what covers that
      gap, which is why the review spec (`docs/REVIEW-PIPELINE-SPEC.md`, R12a)
      is required to write it and not merely expected to; requirement 9a is
      the backstop for when it is missing anyway — the item is then
      investigated once, and the finding remembered.
    - an issue that is assigned, labelled `blocked`, names an unresolved
      `Blocked-by:` dependency (requirement 34j), or is a question or
      discussion rather than actionable work — the first three are
      deterministic and already applied by the Script (requirement 3j drops
      them from the `issues` array before the Co-Ordinator sees it); the
      judgement half is the Co-Ordinator's, over the whole thread
      (requirement 14a), since a comment can block, close, re-scope, or
      answer an issue that its body alone would make look selectable;
    - a security finding whose only available fix is one a human must choose
      (e.g. a Dependabot alert with no non-breaking upgrade, needing a major
      version bump that changes the repo's public behaviour) — flag it, don't
      guess the upgrade;
    - dependent on a product or architecture decision that has not been
      made. (Example: poetic-fiddle's milestone M2 is gated on the §6.1
      packaging decision in its implementation plan — while that decision
      is open, M2 tasks do not meet the bar. Decisions belong to the human;
      never attempt to make one.)

    The last two exclusions, and requirement 17's "if in doubt, skip it", are
    reported rather than acted on silently — see requirement 16a.
16a. **Under-specified and decision-gated skips are reported, not silent.** The
    Co-Ordinator's final message carries an optional `needs_refinement` array,
    alongside `unblocked` and `voided`, whose entries are
    `{repo, item, source, reason, missing, evidence}`: `reason` is one line on
    why the item fails the selection bar, `missing` is what a selectable version
    would need (acceptance criteria, a scope bound, a named decision,
    reproduction steps), and `evidence` is what the Co-Ordinator actually read.

    An item qualifies only if it was **reached and evaluated in this cycle's own
    priority walk** and failed selection *solely* because it is too
    under-specified to rank against requirement 17's bar, or because it is gated
    on an unmade human decision (the last two exclusions of requirement 16).
    Items excluded for any other reason — claimed, already blocked, void,
    assigned, a question or discussion issue — are not reported: they are
    already handled, and reporting one would re-block an item whose clock is
    already running.

    Three limits keep it side-work. The Co-Ordinator must **not** sweep for
    under-specified items beyond the walk it was doing anyway (flags accumulate
    across cycles by themselves, and a sweep would spend a selection pass on
    something nobody asked for); it must not re-report an item already recorded
    as blocked — ordinarily requirement 16's first exclusion means it is never
    re-evaluated at all, and where requirement 18a's mandatory re-check does
    look at one again, that re-check is scoped to whether the recorded blocker
    still holds and is never grounds to re-report `needs_refinement`; requirement
    34e refuses the re-report regardless, if it happens anyway; and reporting
    never changes what the cycle selects. An empty array is the normal case.

    What this replaces is a silent skip, and the silence was the defect. An item
    nobody had specified was re-read and re-skipped by every cycle for as long as
    it existed: the pipeline paid to rediscover the same non-answer hourly, the
    item never became selectable by any route, and the one person who could have
    written the missing criteria was never told it existed. The pipeline looked
    healthy throughout, which is this system's signature failure mode
    (requirement 3b, requirement 34d) in its purest form — an item that starves
    while every component behaves exactly as specified.
17. From the remaining candidates, ranks the qualifying items best-first and
    returns up to `candidates_max` of them, each a stand-alone unit of work,
    clearly scoped, and adequately refined; the ranking preserves the
    priority walk, and the alternates exist because a peer node may win the
    claim on the first choice — not to lower the bar. Do not guess: if in
    doubt about an item, skip it — and report it under requirement 16a rather
    than skipping it silently. If nothing in the current category
    qualifies, fall through to the next category, then the next repo. Only
    after exhausting all repos does it return `{"selected": false}` with a
    one-line reason.
17b. **A refined item is selected on what the refinement says.** Where
    requirement 3h's `refinements` map names an item the Co-Ordinator is putting
    in a work order, an entry carrying a `spec` is pasted into the work order's
    `context` **verbatim** — it exists nowhere else, and the Implementor starts
    with nothing but the work order, so a summarised refinement is one that was
    written by an expensive model and read by nobody. An entry carrying a
    `comment_url` needs no special handling: the refinement is a comment on the
    item's own issue, which requirement 20 already pastes in full, and
    requirement 14a already makes the latest contradicting comment the current
    instruction.
17a. **The claim.** The Script — never the model — takes an atomic per-item
    claim before the Implementor starts, walking the ranked candidates in
    order and handing the first successful claim onward (`lib/claim.sh`).
    The primitive is create-only, so GitHub arbitrates every race:
    - *Branch claims* (every source except the three finishing ones —
      `review-feedback`, `merge-conflicts` and `abandoned-drafts`): a REST
      create-ref (`POST /git/refs`) on the target repository at the default
      branch's head. The claim branch **is** the
      working branch, derived deterministically so every node computes the same
      name for the same item: `td/<ID>` for tech-debt — the same lock the human
      claiming workflow in TECH-DEBT.md takes, so agents and humans contend
      safely — and `agent/<item-ref>` for everything else. A 422 (ref exists,
      even at the same SHA — which a plain `git push` of an identical ref would
      no-op) means a peer holds the item: log `claim-lost` and move to the
      next candidate.
    - *File claims* (`review-feedback`, `merge-conflicts` and `abandoned-drafts`,
      which finish an existing PR and have no new branch to create): a create-only
      contents-API PUT (no `sha`) of `claims/<repo>/<ref>.json` in the state
      repository. For `abandoned-drafts` the ref is scoped to the draft's head SHA
      (`pr-<n>-abandoned-<head-sha>`), and for `merge-conflicts` likewise to the
      PR's head SHA (`pr-<n>-conflict-<head-sha>`), so two nodes racing to finish
      or rebase the same PR contend on the same file and one wins.
    - Every won claim also writes a best-effort **registry entry** at
      `claims/<repo>/<key>.json` in the state repository — the lock is the
      ref or file above; the registry is what back-pressure counts (2.2)
      and what gc sweeps — recording the base SHA, node, cycle, item and
      timestamp.
    - *Release*: an open PR supersedes the claim — the registry entry is
      dropped the moment `pr-raised` is logged, and the branch lives on as
      the PR's head. Every path that ends the cycle without a PR (a void
      verdict, a blocked verdict with no PR, a failed workspace clone, a
      stage failure or timeout)
      releases fully; a claim branch is deleted **only** when it still
      points at the SHA the claim recorded and no open PR uses it — pushed
      work is never deleted. Entries older than `claim_ttl_hours` are swept
      by `lib/claim.sh gc` under the same only-if-untouched rule (a node
      that died mid-cycle must not hold its item forever); every cycle runs
      the sweep at start (2.1a), so a dead node's claims outlive it by at
      most the TTL plus one cycle interval.
    - Claims **fail closed** per candidate: any outcome other than a won
      claim (a lost race, or GitHub unreachable) moves to the next
      candidate. Each miss logs `claim-lost` with a `cause` — `held` for
      `lib/claim.sh`'s rc 3 (a peer genuinely holds the item: healthy
      contention, the work is being done, just not by this node) or
      `unreachable` for its rc 1 (GitHub could not be reached at all,
      fail-closed: no work is being done by anyone), any other rc verbatim.
      A cycle whose every candidate is lost stands down with reason "every
      candidate is already claimed elsewhere" — unless every miss was
      `unreachable`, in which case the reason instead names the outage
      ("GitHub could not be reached for any candidate — this is an outage,
      not contention"), so a GitHub or token outage does not read as a fleet
      politely yielding to itself. A node that cannot reach GitHub to claim
      could not have pushed the work either.
    - When `state_repo` is unset (a single-node operation), file claims are
      vacuously won and the registry is skipped; branch claims still work.
    - `--dry-run` claims nothing. `--once` claims exactly like an unattended
      cycle: a supervised run contends with the fleet on equal terms.
17b. **The orphan-branch sweep.** The gc's only-if-untouched rule (17a)
    leaves one state behind on purpose that is right for the work and wrong
    for the item: an Implementor that pushed commits and died before its
    draft PR existed leaves a moved ref with no PR — which nothing recovers
    (`gather-abandoned-drafts.sh` lists PRs, not branches), every later
    claim 422s against, and the Co-Ordinator's exclusion reads as "claimed,
    skip". The work is unreachable and the item permanently unselectable,
    with no event ever saying so. Its sibling is the unmoved ref whose
    best-effort registry write never landed, wedging the item with nothing
    to recover. So after the gc (2.1a), every cycle runs
    `scripts/sweep-orphan-branches.sh` over each configured repo's `td/*`
    and `<branch_prefix>*` refs. A ref is a provable orphan only when **all
    three** hold: no open PR uses it, no registry entry stands for it (only
    a clean 404 proves absence — any other failure skips the ref, fail
    closed), and its tip commit is older than `abandoned_draft_after_hours`
    — the same judgement that makes a draft abandoned. For each orphan the
    sweep restores a state the pipeline already handles: commits ahead of
    the default branch become a **draft PR** (labelled `pr_label`, so the
    abandoned-drafts machinery recovers the work exactly as it recovers any
    stalled draft; retried without the label, loudly, where the label is
    missing), and a ref with nothing ahead is **deleted** — it was only
    ever the claim, and the claim is dead. Actions are capped per run
    (three per repo per cycle, the overflow reported, never silent), logged
    as `orphan-branch-recovered` / `orphan-branch-released` events, and
    every node may sweep concurrently: GitHub rejects a second open PR for
    the same head and a second ref delete is a no-op, so the worst race
    outcome is a warning. Skipped on `--dry-run`. One priced residual: a
    live claim whose registry write failed and whose ref is untouched looks
    identical to the empty orphan, so its ref can be deleted mid-run — the
    Implementor's later push recreates it, and the cost is at worst a
    duplicate PR, priced against an item wedged forever.
17c. **The post-merge closing-keyword sweep.** Requirement 25a's CI check
    stops a *new* pull request from merging without a real closing keyword;
    this is the backstop for what already got through — a PR merged before
    that check existed, or one that merged some other way — and for the
    ordinary lag between a fix landing and the issue it was meant to close
    actually closing. After the orphan-branch sweep (17b), every cycle runs
    `scripts/sweep-closed-issues.sh` over each configured repo: for every
    merged, `pr_label`-labelled pull request naming an issue `N` GitHub
    still reports open, it closes that issue with a comment citing the merge
    as evidence (the PR number, its merge commit) instead of leaving the
    tombstone that keeps a finished item selectable forever (issue #240;
    PR #206's "Implements #198" left #198 open for three days after its own
    fix merged, selected and voided twice in the meantime). A merged PR
    names its issue by the `<!-- agent-ops:closes-issue item=N -->` marker
    (requirement 23b), or — when the marker is missing — by a head branch of
    exactly `agent/<N>`, the same Script-minted anchor requirement 25a's CI
    check reads, so one forgotten prompt instruction cannot blind the CI
    check and this sweep on the same PR.
    An issue GitHub reports `state_reason: "reopened"` is exempt: somebody
    reopened it after a close, and "still open" alone cannot tell that apart
    from "never closed". Without the exemption the sweep would re-close, on
    the hour and with a fresh comment each time, exactly the issue a human
    deliberately put back — the same answer requirement 34k's
    `void-object-closed` record gives on the other sweep, spelled here with
    no record of our own to keep, because the re-open is GitHub's record of
    it. The skip is reported as a warning, never silent.

    Bounded to the most recently updated merged pull requests per repo, and
    idempotent by construction — it only ever acts on an issue GitHub itself
    still reports open and not reopened, so re-running it costs nothing once
    the backlog is cleared. Actions are capped per run (three per repo per cycle, the
    overflow reported, never silent), logged as `issue-closed-post-merge`
    events, and every node may sweep concurrently: GitHub's own issue-close
    is idempotent, so the worst race outcome is two nodes both finding
    nothing left to do. Skipped on `--dry-run`.
18. When it skips a blocked item, it may cheaply verify whether the recorded
    blocker still holds; if the blocker is demonstrably gone, it reports
    that in its final message so the Script can append an `unblocked` event,
    and may then treat the item as a candidate this same cycle. Two limits,
    both load-bearing (requirements 9b, 34c):
    - This applies to *impediments only*. Discovering that the item's work is
      already **done** is never grounds to unblock it — that is a void, and
      unblocking it hands it back to the pool to be rediscovered every cycle.
      Say so explicitly in the prompt, with the reasoning: an agent told to
      "clear blockers that no longer apply" will otherwise conclude, correctly
      and disastrously, that an already-done item has no blocker.
    - It may **never** clear a void item, and is given no field with which to
      try. It may *create* one, in `voided`, for a candidate it can see
      conclusively is already done, which saves an entire Implementor run — with
      the `reason` and the `evidence` requirement 34c has always demanded, and
      subject to requirement 34d's guard, which records an unevidenced or
      refuted entry as blocked instead.
18a. **Fresh evidence on a blocked issue makes requirement 18's re-check
    mandatory, not discretionary.** For a blocked item that is a GitHub
    issue, before excluding it under requirement 16 the Co-Ordinator compares
    the issue's own `updated_at` against the later of two timestamps carried
    on its `blocked` entry: the `ts` of the `attempt-failed` event that
    blocked it, and its `recheck_clean_ts` if it has one — the newest
    `recheck-clean` event recorded for it (below), or absent if none exists.
    If `updated_at` is newer than that later timestamp, something was posted
    to the thread since the block was last confirmed current, so the
    Co-Ordinator must read the issue and every comment (requirement 14a's
    whole-thread rule) before honouring the marker, and judge against that
    fresh reading whether the recorded blocker still holds:
    - If it does not, report the item in `unblocked`, as the bare item id
      requirement 20 specifies. This is the same outcome and the same two
      limits as requirement 18 (impediments only; never clears a void); only
      the trigger changes, from "may check when convenient" to "must check
      when the thread has moved".
    - If it still holds, report the item in `recheck_clean` as
      `{item, repo}` (requirement 20) instead of leaving the re-check
      unrecorded — both fields off the `blocked` entry just re-checked. The
      Script logs this as a `recheck-clean` event (requirement 33) and folds
      the newest one per item into the `blocked` extract as
      `recheck_clean_ts`, which is what the next cycle's comparison above
      reads. Without this marker, a comment that fails to clear the block
      would look, to every later cycle, exactly like one that was never
      read: `updated_at` stays newer than the original `ts` forever, and
      every Co-Ordinator that runs re-reads the same stale thread and
      re-judges the same evidence until the block finally clears by some
      other route.

    When `updated_at` is no newer than the later of the two timestamps,
    nothing has changed since the more recent of the block or its last
    confirmed re-check, and the ordinary skip applies without a re-read.

    **`recheck_clean` must never be produced by re-emitting `attempt-failed`,
    and a re-check that still holds must never move the blocked entry's own
    `ts`.** Requirement 35a's Enabler clock is measured from the block's `ts`
    forward; a fresh `attempt-failed` — or any change to the existing one —
    would advance that clock exactly as a genuine re-block does, delaying the
    Enabler's own eventual escalation over a confirmation that changed
    nothing. `recheck_clean` is deliberately a separate marker that only this
    comparison reads, so confirming a block never resets anyone else's clock.

    This exists because the general case left a gap a periodic sweep alone
    cannot close at cycle speed: requirement 3b's fingerprint already digests
    each issue's `updated_at`, so a comment landing on an already-blocked
    issue busts the fingerprint and wakes a Co-Ordinator within the hour —
    but that Co-Ordinator would otherwise skip straight past the item on the
    stale marker without ever looking at what changed, exactly the failure
    the Enabler's own periodic re-check (requirement 35a) exists to bound to
    days rather than never. Reading the fresh comment the same cycle that
    woke for it is cheaper than either the silent stall or the Enabler's
    eventual sweep, and does not replace the Enabler: an item this check
    finds still blocked is exactly the item the Enabler goes on to re-examine
    on its own schedule. The `recheck_clean` marker exists so that reading it
    once is also the *last* time it gets read on a thread that has not moved
    again since — without it, the cost this requirement was meant to bound to
    "one re-read per genuine comment" would instead recur every cycle a
    Co-Ordinator runs, for as long as the block lasts.

    No other blocked source needs the same treatment, so this requirement
    binds to GitHub issues only and requirement 18's general, discretionary
    check still covers the rest. Tech-debt entries, security and code-quality
    findings, plan tasks and project-review recommendations have no per-item
    "new evidence arrived" signal at all: their content lives in a file or an
    alert record, not a thread a human can add to after the block. The
    PR-derived sources do have one, but they do not need this rule, because
    their refs are scoped to the round or the head SHA that produced them
    (`pr-<n>-review-<review-id>`, `pr-<n>-conflict-<head-sha>`,
    `pr-<n>-abandoned-<head-sha>` — requirement 20): a human reviewing again,
    or a commit landing on the branch, mints a fresh item id that no block
    covers, so evidence arriving there is never held behind a stale marker.
19. Chooses the Implementor's model: `implementor_model_trivial` only when
    the item can be completed without changing any file that affects runtime
    behaviour (docs, comments, register entries); otherwise
    `implementor_model_default`. Records the reasoning.
20. Emits its entire final message as one JSON object: `selected`,
    `unblocked`, `recheck_clean` (entries of `{item, repo}`, for requirement
    18a's mandatory re-check finding the blocker still holds — repo-scoped,
    unlike `unblocked`, because this marker suppresses a mandatory re-read
    where an over-broad `unblocked` merely re-admits a candidate, and the
    `blocked` entry being re-checked carries its `repo` in any case),
    `voided` (entries of `{item, repo, reason, evidence}`,
    requirement 34d), `needs_refinement` (entries of
    `{repo, item, source, reason, missing, evidence}`, requirement 16a), and a
    ranked `candidates` array of up to
    `candidates_max` work orders (the Script accepts the former
    single-selection shape — the work-order fields at the top level — for
    one release, treating it as a one-candidate list). Candidates carry no
    `branch`: the Script derives and injects the claim branch (requirement
    17a), except for the finishing sources `review-feedback`, `merge-conflicts`
    and `abandoned-drafts`, whose `branch` is the PR's existing branch carried from
    the entry. For a `failed-runs` entry,
    `item` is `failed-run-` plus the workflow file's basename without extension —
    deterministic, so every node derives the same claim key. `source` is one of
    `security`, `review-feedback`, `merge-conflicts`, `abandoned-drafts`,
    `failed-runs`, `tech-debt`, `issues`, `implementation-plan`, `project-review`,
    `code-quality` or `register-hygiene`
    — an issue is `issues` whichever band it was selected from
    (requirement 15e); the `issues:<band>` tokens exist only in `sources`, to
    place the source in the walk, and never in a work order. For a
    `review-feedback` entry, `item` is its `ref`, `branch` is the PR's
    **existing** branch, the order also carries `pr_url` and `pr_number`, and
    `context` must paste the entry's `body` **verbatim** — it is a human's
    specific, considered request and it is the entire brief. A model
    summarising a review before handing it to the model that must act on it is
    a lossy telephone game about what a person actually asked for. For a
    `merge-conflicts` entry, `item` is its `ref`, `branch` is the PR's
    **existing** branch, the order also carries `pr_url`, `pr_number` and the PR's
    `base`, and `context` must carry the PR's own `body` verbatim plus the existing
    branch, base and head SHA, telling the Implementor to rebase onto `base` and
    resolve the conflict — not to re-do or extend the work; `acceptance` is the PR
    mergeable again (no longer `CONFLICTING`) with CI green and the PR left in the
    ready state it was already in, the underlying item deliberately left for its
    own eventual merge. For an
    `abandoned-drafts` entry, `item` is its `ref`, `branch` is the draft PR's
    **existing** branch, the order also carries `pr_url` and `pr_number`, and
    `context` must carry the draft PR's own `body` verbatim (the original plan)
    plus the existing branch and head SHA, telling the Implementor to read the
    existing diff and *finish* the draft rather than restart it; `acceptance` is
    completion to the originating item's standard with the PR left a **draft** for
    the Reviewer to flip to ready. For a `register-hygiene` entry, `item` is its
    `ref`, there is no PR to carry (the Script derives the ordinary
    `agent/<ref>` claim branch), `model` is always `implementor_model_trivial` —
    register-only editing, no behaviour change — and `context` must paste the
    entry's `body`, the consistency check's whole output, **verbatim**: each
    line names an id, a problem class and a line number, and that is precisely
    what makes the repair mechanical. `acceptance` is argless
    `perl scripts/td-check.pl` exiting 0, with the repair discipline of
    requirement 25 followed. For a
    `security`/`code-quality`
    finding, `item` is the finding's stable `ref` (e.g. `dependabot-alert-42`,
    `code-scanning-alert-17`) and `context` must paste the finding verbatim
    (package/rule, severity, affected location, advisory summary, and the
    alert URL) so the Implementor can act without re-querying the API. For a
    `project-review` recommendation, `item` is its ref
    (`review-<review-date>-R-NN`) and `context` must paste the recommendation's
    improvement prompt (from `04-improvement-prompts.md`) verbatim, together
    with the review folder path and the `R-NN` detail; `acceptance` is the
    recommendation's *Intended end state*. For an `issues` entry, `item` is the
    issue number and `context` must paste the issue body **and every comment**
    verbatim (each attributed to its author, in order) — not the opening post
    alone. The Implementor starts with nothing but this work order, so a
    clarification or acceptance criterion left in a comment is lost unless the
    Co-Ordinator carries it across; where the comments changed the ask,
    `acceptance` is set from the current state of the thread, not the original
    body.

    ```json
    {
      "selected": true,
      "repo": "Poetic-Poems/poetic-fiddle",
      "default_branch": "main",
      "source": "tech-debt",
      "item": "TD26051201",
      "title": "one-line description",
      "branch": "agent/td26051201-short-slug",
      "model": "claude-sonnet-5",
      "model_reason": "code change with tests",
      "context": "everything the Implementor needs: the register entry, issue text, or finding verbatim, file paths, related conventions found while evaluating, why the item is unblocked and in scope",
      "acceptance": "what done looks like, concretely"
    }
    ```

### The Implementor

21. Operates as a single non-interactive `claude -p` invocation with no
    resumption: once it emits a final message with no further tool calls,
    the process exits for good — nothing wakes it later. It must wait for
    long-running commands (dependency installs, builds, test suites)
    synchronously, in the foreground or by polling within the same session,
    rather than ending its turn expecting an external notification when
    they finish. A command too slow to wait out within the stage timeout is
    grounds for `"status": "blocked"`, not an early, hopeful end of turn.
22. Runs inside the cycle's clone. First reads the repo's `CLAUDE.md` and
    obeys it throughout. Checks out the branch named in the work order —
    already created on origin by the Script as the item's claim (requirement
    17a) — and never creates, renames, or deletes a branch of its own.
23. **Makes the claim visible before implementing.** The branch is the
    lock, but humans read PRs, not refs: opens a draft PR immediately, labelled
    `pr_label`, with a Conventional-Commits title (it will become the squash
    commit on `main`) and a body giving the item reference and planned
    approach. Immediately records the PR's URL at `.git/agent-ops-pr-url` in
    the clone — `.git/` is never part of the tracked tree, so this can't
    leak into a commit — so the Script can still identify the PR even if
    this stage never reaches a parseable final message (requirement 9). That
    breadcrumb is a courtesy, not the guarantee: it is one more step in this
    stage's procedure, and requirement 9's fourth lookup is what covers the
    stage that performed none of them. For
    tech-debt items this follows the repo's claiming workflow exactly —
    flipping the record's `status:` frontmatter to `in-progress` as the
    first commit. For issues, it
    comments on the issue linking the draft PR; the work order's `context`
    already carries the issue body and its comments (requirement 20), but if
    the Implementor consults the issue directly it reads the whole thread
    (`gh issue view <n> --comments`), never a bare `gh issue view <n>` that
    hides the comments where corrected requirements usually live. For `security`/`code-quality`
    findings, the draft PR body names the alert (its `ref` and URL) so the
    claim is visible to any other cycle scanning open PRs. For a
    `project-review` recommendation, the draft PR body names the ref
    (`review-<date>-R-NN`) and links the review folder and recommendation, so
    the claim (and, once merged, the completion) is visible to any other cycle
    scanning PRs — there is no register entry and the review folder is not
    modified.
23b. **Stamps an issue-sourced draft PR with a machine-readable marker naming
    the issue it claims to close.** `<!-- agent-ops:closes-issue item=N -->`
    (`lib/pipeline-marker.sh`'s convention extended to this one new purpose:
    an invisible, greppable fact in the PR body), where `N` is the work
    order's `item`. This is what requirement 25a's deterministic check and
    requirement 17c's post-merge sweep both key on — neither reads prose, so
    "Implements #N" is invisible to both, which is exactly the shape of the
    defect requirement 25a exists to close (issue #240; PR #206 wrote
    "Implements #198" and #198 stayed open three days after its own fix
    merged).
23a. **Pushes at checkpoints, not only at the claim and at the end.** Once the
    draft PR exists, the Implementor commits and pushes again at each
    meaningful checkpoint — a passing test, a completed file, a finished
    logical unit — rather than holding every later change in the working tree
    until its final message. The clone is ephemeral and gone once the cycle
    ends, so a commit that never reached `origin` is lost with it; a pushed
    one survives on the claim branch regardless of how the stage ends. This is
    what lets an interrupted stage's successor — most often the
    `abandoned-drafts` recovery path (requirement 3e) — resume from the last
    checkpoint instead of from the claim commit alone, and it is also a
    "genuine push" in the sense requirement 3e's own activity clock already
    watches for.
24. Implements the item, then runs the same checks the repo's CI runs (as
    documented in that repo's `CLAUDE.md` and workflow files) and fixes
    anything they surface.
24a. **Checks the preview deployment its own pull request produced.** Where the
    target repository deploys from GitHub — poetic-fiddle, through Vercel's Git
    integration — every pull request head SHA gets its own preview deployment,
    and requirement 24's checks say nothing about it: the integration reports
    through GitHub's *deployments* API rather than as a check run, so
    `gh pr checks` is green over a preview that never built.
    `scripts/preview-deploy.sh` (component 13) is how a stage asks. A preview
    that failed to build, or that answers an error, is a defect in the pull
    request and is fixed like any other.

    **A preview the stage cannot reach is not a failure of the pull request.**
    Preview deployments sit behind Vercel Authentication, and an
    unauthenticated request for one is answered with a 302 to
    `vercel.com/login` — which, followed, is a **200** from the login page, so a
    check reading a status code alone certifies a wall as a healthy deployment.
    The script therefore judges where a response points rather than what it is
    numbered, and reports a protected preview as "could not check" (exit 2),
    naming the node configuration that would fix it. `VERCEL_AUTOMATION_BYPASS_SECRET`
    is a property of the node, not of the branch: a node without it runs every
    cycle exactly as it did before this check existed, and neither stage may
    report `blocked` for the want of it.

    Both stages reach the script through **`AGENT_OPS_ROOT`**, which
    `agent-cycle.sh` exports as its own directory and every stage inherits. A
    stage's working directory is its ephemeral clone, so a prompt naming a tool
    this repository ships has nothing to name it relative to. A hard-coded
    `/app` would be right for every node as deployed and wrong for every other
    way this repository is run — a maintainer's checkout, the test suite, any
    future node that is not a container — and a prompt cannot tell which it is
    in. It is the only variable the Script
    exports for the stages, and `test/preview-deploy.test.sh` asserts the export
    and both prompts' use of it against each other, so the path cannot drift
    between the three (requirement 34a).
25. Updates the originating record: the tech-debt record marked `resolved` —
    its `status:` frontmatter flipped (with `resolved:` and `ref:` filled in)
    and its body left in place, the file never deleted or renamed; issues
    linked with a real GitHub closing keyword (`Closes`/`Fixes`/`Resolves
    #N`) naming the same `N` as requirement 23b's marker; implementation-plan
    task marked done.
    For `security`/`code-quality` findings, no register flip applies — GitHub
    closes a Dependabot or code-scanning alert automatically once the fix
    lands on the default branch and is re-scanned — so the PR body names the
    alert it resolves (and its URL); the Implementor never dismisses an alert
    itself (dismissal is a human decision). For a `project-review`
    recommendation, there is likewise no register entry to flip and the
    review folder (a point-in-time record) is left untouched — the PR body
    names the ref
    (`review-<date>-R-NN`) so its eventual merge marks the recommendation done;
    a later review re-evaluates the code and simply omits anything now fixed.
    Adds a `CHANGELOG.md` entry when the change is notable by that repo's
    definition (a security fix usually is).

    For a `register-hygiene` item (requirement 3i) there is no originating
    record to close — the register *is* the item — but the repair has a
    discipline, and without it a tidy-up destroys information. The problem
    labels the work order carries are BAD NAME, BAD FRONTMATTER, MISSING
    FIELD, BAD FIELD, BAD STATUS, BAD SCOPE, NO SCOPE, ID MISMATCH, DATE
    MISMATCH, STALE FIELD or DUPLICATE ID — all `td-check.pl`'s own — and
    VOIDED STATUS, which is not (requirement 34l):
    - Most are one-line frontmatter corrections, made to match the facts —
      the pull request its `ref:` names, the filename, the `scope:` declared
      in `TECH-DEBT.md` — never the other way round. Where the facts are not
      recoverable from git history, the Implementor reports `blocked` naming
      the file and what could not be established.
    - A **STALE FIELD** (a resolution field set on an open item) is judged by
      following the `ref:` and confirming the fix has landed before the
      status itself is flipped to `resolved`, or the resolution fields
      cleared and the item left open.
    - A **VOIDED STATUS** (requirement 34l: the fleet's void log records the
      item done, the file still says `open`/`in-progress`) is judged by
      following the void's own evidence, carried in the work order's `body`,
      and confirming the change did land on the default branch — usually
      under some other item's pull request, which is why the row was never
      flipped. If it did, `status:` is flipped to `resolved` with `resolved:`
      and `ref:` filled from that evidence; if it did not, the row is left
      exactly as it is and the Implementor's `notes` say why.
    - An item file is **never deleted or renamed** once on the default
      branch — the directory is an append-only set and CI enforces it — and
      nothing is touched beyond what the work order's problem lines flag:
      item files are permanent records, not a place to re-word titles or
      tidy accepted frontmatter.

    The pull request is pure register housekeeping — the register and
    nothing else — and argless `perl scripts/td-check.pl` exits 0 before the
    item is complete, the same check the target repo's own CI will run on
    the PR. That checker is the whole acceptance only for its own labels: it
    reads each file against itself, its filename and the declared scope, so
    it exits 0 on a VOIDED STATUS row untouched. Where the work order carries
    one, the item is complete only once that row is flipped or the
    Implementor has said why the evidence did not hold up.
25a. **The closing keyword requirement 25 asks for is enforced by CI, not by
    trusting the prompt.** `.github/workflows/closing-keyword.yml` runs
    `scripts/check-closing-keyword.sh` against the PR body and head branch
    on every `pull_request` event, and two anchors decide what the body owes:

    - **The marker.** Every `<!-- agent-ops:closes-issue item=N -->` marker
      (requirement 23b) in the body fails the check, naming the missing
      number, unless the body also carries a real closing keyword for that
      same `N`.
    - **The branch.** A head branch of exactly `agent/<N>` — the name the
      Script itself mints for an issue-sourced work order
      (`claim_branch_for`) and for nothing else, since no other source
      yields a purely numeric item (`lib/work-gone.sh`) — requires both the
      marker for `N` and the closing keyword for `N` to be *present*. This
      anchor is the one no model writes: a marker-only check passes
      trivially on the PR whose Implementor forgot the marker, which is the
      same silent prompt-skip that motivated issue #240, whereas the branch
      name was fixed by the Script before the Implementor ever ran.

    A PR with no marker on any other branch — every non-issue source —
    passes; the check has nothing to say about a PR with nothing to close.
    This is what makes requirement 25's "Implements #198" failure (issue
    #240) structurally impossible to repeat unnoticed: the pull request
    itself goes red, in front of the human who reviews it, rather than
    depending on a model that has already been asked once and skipped it.
    The `closing-keyword` check must also be listed in the repository
    ruleset's required status checks — a repo setting, not a workflow file —
    so red blocks the merge rather than merely reporting, and pinned there
    to the GitHub Actions app (`integration_id` 15368), as every other
    required context is, so no other integration can satisfy the requirement
    by reporting a check of the same name. Acceptance check 8m is how that
    setting is verified, it being the one piece of requirement 25a no file
    in this repository carries.
26. Verifies the PR via `gh pr view --json mergeable,mergeStateStatus`
    (against GitHub's view, not inferred locally) and resolves any conflict
    with the current default branch. Leaves the PR as a **draft** — the
    Reviewer flips it to ready.
26a. **Grades the complexity of the work, ex post, and labels the PR with
    it.** After implementing, the Implementor grades the PR `low`, `medium`
    or `high` against a rubric anchored to observable features of the work,
    never to how difficult it felt — the PR that most needs a strong review
    is the one whose author misunderstood something and didn't notice, and
    that author will find it easy:
    - `low` — docs, comments, or register entries only; no behaviour
      change. A work order the Co-Ordinator classified trivial (requirement
      19) is `low` by definition, no deliberation required.
    - `medium` — a behaviour change confined to one area and well covered by
      existing or added tests.
    - `high` — the diff touches concurrency/locking, security, state
      replication, CI/workflow machinery, or shared library code; or the
      Implementor deviated from the work order; or the acceptance criteria
      cannot be verified mechanically.
    It applies the grade to the PR as a `complexity:<grade>` label — creating
    the label in the repo first when absent, best-effort — leaving the PR
    with exactly one `complexity:*` label. On a PR that already carries one
    (the finishing sources), it may **raise** the label but never lower it:
    the grade describes the PR's whole content, not the final round's effort,
    and rebasing a `high` PR is not `low` work. Labelling must not fail the
    stage — the summary's `complexity` field (requirement 27) is the
    authoritative carrier for this cycle's model choice (requirement 8a); the
    label is the durable mirror that survives for later finishing rounds and
    tells the Human Reviewer how carefully to read.
27. Ends with a single JSON object as its entire final message:
    `{"status": "complete", "pr_url": …, "branch": …, "complexity": "low" | "medium" | "high", "notes": …}`,
    `{"status": "blocked", "reason": …, "unblock_condition": …}`, or
    `{"status": "void", "reason": …, "evidence": …}`. The Implementor is the
    only component positioned to tell `blocked` from `void` (requirement 9b) —
    it is the one that actually reads the tree — so its prompt must draw the
    distinction explicitly and demand evidence for `void`. Do not leave it to
    infer that "already done" is a kind of blocker; it reads that way, and the
    two states behave in opposite ways downstream.

### The Reviewer

28. Operates under the same one-shot constraint as the Implementor
    (requirement 21): no resumption, no background notification. It waits
    for slow commands — installs, builds, `gh pr checks --watch` — in the
    foreground within the same session rather than ending its turn early.
29. Reviews the PR against the work order's item and acceptance notes, and
    against the target repo's own standards and conventions; re-runs the
    repo's checks, and re-runs requirement 24a's preview check rather than
    trusting the Implementor's — a preview deployment is per head SHA, and any
    fix this stage pushes mints a new one.
30. Where it finds a problem it can fix with confidence, it fixes it
    directly on the branch — committing, rebasing onto the current default
    branch, or force-pushing as it judges best (permitted only on
    `branch_prefix` branches, per "The Human Gate"). Where it cannot fix
    with confidence, it leaves a PR review comment describing the problem
    for the Human Reviewer. A `complexity:*` label (requirement 26a) plainly
    wrong for the diff counts as such a problem: having just read the whole
    diff, the Reviewer is better placed than the author, and corrects the
    label in either direction — the label endures for later finishing rounds
    (requirement 8a) and for the human.
30a. **Emits as it goes, not only at the end.** Requirement 23a's counterpart
    for the Reviewer, and it binds harder here: an Implementor that is killed
    at least leaves the branch it has been building, whereas a review exists
    only as commits and comments that have reached GitHub. Everything else is
    in an ephemeral clone and in a stage that may not finish. So each fix under
    requirement 30 is pushed when it is made rather than held for requirement
    31's confirmation push, and each finding is posted when it is formed rather
    than batched into a closing pass. Comments carry `lib/pipeline-marker.sh`'s
    invisible marker, so requirement 3e's activity clock already discounts them
    (TD26072605) and there is no cost to posting more of them. This is what
    lets an interrupted review's successor start from what has already been
    established rather than from the diff — and, where nothing supersedes them,
    lets the findings a killed stage did reach still travel to the human.

    The failure it closes is total, not partial. On agent-ops#205 a Reviewer ran
    for the whole of its 45-minute cap and was killed; it left no commit, no
    review and no comment, so 45 minutes of Opus review produced nothing that
    outlived the clone. A stage cannot be stopped from dying mid-review, but it
    can be stopped from dying with everything still inside it.
30b. **Reports completion, unconditionally.** Every run posts exactly one more
    comment beyond requirement 30a's findings: a completion comment stating the
    review has finished and what it concluded, posted whether or not
    requirement 30 found anything — a clean PR is otherwise indistinguishable
    from one no Reviewer has looked at yet, since every write lands under the
    same account a human also comments as (requirement 9d). It is a separate
    `gh pr comment` call, never folded into a findings comment and never filed
    as a review (`gh pr review --comment`), carrying the same header and marker
    as every other pipeline comment (requirements 9d, 3e) plus four facts: the
    outcome (handed to the human, or left in draft and why), the CI state, the
    fixes requirement 30 pushed (or none), and the number of concerns
    requirement 30a raised (or none, stated plainly when the PR was otherwise
    green). Requirement 32's `comments_left` still counts only requirement
    30a's findings comments — this one is never among them.

    On the `ready` path it is the last act, posted after requirement 31's
    hand-off and requirement 31b's re-request, so it can state the true final
    state; on the `blocked` path, which never reaches requirement 31, it is
    posted immediately before requirement 32's final JSON. A post that fails
    does not become a `blocked` outcome — a comment that could not be written
    is not a review that did not happen — the Reviewer carries on and reports
    its verdict as normal.
31. Confirms CI is passing (`gh pr checks`) and the PR is mergeable, then
    marks it ready for review (`gh pr ready`), and where a human's review is
    what blocks it, requests a fresh one from them (requirement 31b). It never
    approves and never merges.
31a. **The handoff is verified, not reported.** Requirement 31 is the pipeline's
    only irreversible outward act, and requirement 32 has the Reviewer *describe*
    it — two different things. Before recording `pr-ready` the Script asks GitHub
    whether the pull request is a draft (`gh pr view --json isDraft`), and:
    - not a draft — log `pr-ready` with `handoff: "reviewer"`. The ordinary path,
      one field on one PR;
    - still a draft — run `gh pr ready` itself, re-read the flag, and on success
      log a `warning` naming the PR and then `pr-ready` with `handoff: "script"`.
      The judgement is the expensive half and the Reviewer has made it; the flip
      is mechanism, and mechanism the Script can perform deterministically. It
      completes rather than fails, so a certified PR is never put in front of a
      human as a problem;
    - still a draft after that, or the flag unreadable — requirement 32a.

    Fail towards the state something else will look at: "could not ask" must
    never resolve to "not a draft", which is the defect itself with an API
    outage standing in for the Reviewer. One definition, in `lib/handoff.sh`,
    shared with requirement 32b (requirement 34a).

    The defect this exists to prevent shipped. A Reviewer returned
    `{"status": "ready", "ci": "passing"}` for a complete, green pull request,
    never ran `gh pr ready`, and the Script logged a successful handoff from the
    report alone. The PR stayed a draft: invisible to the human, who watches for
    review requests, and invisible to the log, which agreed with the Reviewer.
    Three hours later the abandoned-drafts source (requirement 3e) correctly
    re-detected a stalled draft, at a fresh head SHA and so under a fresh ref no
    block covers, and paid an Implementor and a Reviewer to finish finished
    work — which it would have gone on doing hourly, each round looking
    productive. No component could have noticed: the Reviewer believed it had
    handed off, the Script believed the Reviewer, and only GitHub disagreed.
31b. **The second half of the handoff: the re-request.** Requirement 31a's flip
    is the whole handoff exactly once per pull request. Every round after the
    first begins with a PR that is already ready — a review round the Implementor
    has just answered, above all — so `gh pr ready` is truthfully a no-op, and
    nothing is left that puts the pull request in front of the human. Their
    review request was consumed the moment they submitted the review that asked
    for the changes; the author cannot clear `CHANGES_REQUESTED` (requirement
    26b); and so the PR sits with changes requested, no review requested of
    anyone, and a completed handoff in the log.

    So on the `ready` path, after the draft flip, the Script asks GitHub the
    second question too: **does a human's review block this pull request, and
    has a fresh review been requested of them?** The blocking set is computed
    the way GitHub computes `reviewDecision` — the last APPROVED or
    CHANGES_REQUESTED review *per reviewer*, bots excluded — so a human who
    requested changes and later added a `COMMENTED` review is still blocking,
    and one who later approved is not. Then:
    - nobody blocking — nothing to do. The answer on every first-round pull
      request, at the cost of one API read, and the reason the check is
      unconditional rather than gated on `source == "review-feedback"`: the
      question is answerable from the pull request itself, and gating it on the
      Co-Ordinator's classification would make a mislabelled source an
      unnotified human;
    - blocking, and a re-review already pending from each — `already`. Whoever
      got there first (normally the Implementor, requirement 26b) did it;
    - blocking, none pending — `POST …/pulls/<n>/requested_reviewers` for the
      ones not yet asked, then **re-read the pending list**: as with
      `gh pr ready`, the call's exit status is not the answer. `pr-ready` then
      carries `review_requested` and the `reviewers` named;
    - it did not take, or GitHub could not be asked — a `warning` naming the PR
      and the reviewers, and `review_requested: "failed"` on the `pr-ready`
      event. **Not** an `attempt-failed`: the pull request is finished, green and
      visible, and only a notification is missing — the Implementor's own reply
      comment mentions the reviewer, which notifies them too. Recording a
      handback here would put a certified PR in front of the Enabler as a
      problem, which is what requirement 31a exists to avoid.

    **This does not clear the block, and must not appear to.** Re-requesting
    review leaves `reviewDecision` at `CHANGES_REQUESTED` and `mergeable_state`
    at `blocked` — verified against GitHub on poetic-fiddle #200, before and
    after — so "The Human Gate" holds unchanged: the PR still needs an approving
    review from a code owner that this system cannot give itself. All the
    re-request does is return the PR to the queue the human actually reads.

    The defect this exists to prevent shipped, and is why requirement 31a's
    lesson needed a second telling. poetic-fiddle #200 was reviewed at 10:18
    with one requested change, answered and pushed at 21:33, and replied to at
    21:44 with a comment saying so. Every actor did its job; the Implementor
    prompt has carried "then re-request review from the reviewer" since the
    review-feedback source existed, as best-effort prose that nothing verified.
    It was skipped, the log recorded a clean `pr-ready`, and the human found the
    pull request only by going to look for it. The report is not the deed — so
    the model may still do it, the Script asks GitHub whether it happened, and
    where it did not the Script does it. One definition, in `lib/handoff.sh`
    (requirement 34a).
32. Ends with a single JSON object:
    `{"status": "ready" | "blocked", "pr_url": …, "fixes_applied": […], "comments_left": n, "ci": "passing" | …}`,
    plus `reason` — one line naming what is wrong — on `blocked`, which becomes
    the block's own `detail` under requirement 32a. `needs-human` is accepted as
    a synonym for `blocked` for one release, on the precedent of requirement
    20's shape migration; the prompt emits `blocked`.
32a. **A Reviewer that cannot hand off hands back, not out.** Any ending other
    than a pull request the human can see — `blocked`, an unparseable status, or
    a `ready` whose handoff requirement 31a could not make true — is recorded as
    an `attempt-failed` against the item, carrying the `pr_url`. That is a
    blocked item by requirement 34 and Enabler-eligible by requirement 35a, so
    the Enabler re-examines it with the whole history in front of it and either
    clears it (requirement 32b) or escalates it to a human by issue
    (requirement 36).

    The promise this keeps: **a pull request that is not ready for review is the
    pipeline's problem until an Enabler says otherwise.** A human is never
    expected to discover work by noticing a draft. Recording the verdict as a
    bare `stage-end` — which is what it was — named no item, so it pinned no
    state, appeared in no blocked list, reached no Enabler, and left the PR to be
    swept up hours later by abandoned-drafts as though the Reviewer had never
    run.

    The Script leaves no comment of its own on the PR here. The Reviewer has
    already stated its concerns there in its own words (requirement 30) and that
    is the record the Enabler reads; a second comment would add nothing —
    marking it (requirement 3e) would keep it from resetting the staleness
    clock, but there is still nothing for it to say that the thread does not
    already contain. Where the Script does comment on a stage failure it says
    the item is recorded blocked and that the Enabler will re-examine it —
    never that the PR has been left for a human, which under this requirement
    is not true.
32b. **`complete_handoff`.** An Enabler `unblocked` verdict may carry
    `complete_handoff: true` on an item whose `pr_url` is set (requirement 35a),
    meaning: this block *is* an unfinished handoff — an open draft this system
    raised, checks green, work done, no unanswered concern — take it out of
    draft. The Enabler establishes it; the **Script** performs it, through
    requirement 31a's implementation, and logs `pr-ready` with
    `handoff: "enabler"`. The division is requirement 36's: the Script is the
    only writer of the pipeline's outward acts, which is why it and not the
    Enabler also files the escalation issue. A `complete_handoff` on an item with
    no `pr_url` is ignored — there is nothing to hand off.

    Requirement 31b runs on this path too, and it is not decoration here: an
    `already` is exactly what a stalled review round answers, because that PR was
    never a draft. Completing only the flip would clear the block, log a handoff,
    and leave the human as unasked as before. Both handoff paths run both halves,
    or the one that recovers a failure is the one that recovers it incompletely.

### Logging and state

33. The shared log is a single JSON Lines file, `state_dir/log.jsonl`,
    appended only by the Script (agents report via their final messages; the
    Script translates those into log events). The lock in requirement 1
    guarantees a single writer. Events: `cycle-start`, `cycle-skipped`,
    `stand-down`, `selection`, `claim-lost`, `none-selected`, `stage-start`,
    `stage-end`, `pr-raised`, `pr-ready`, `attempt-failed`, `unblocked`,
    `recheck-clean`, `item-void`, `unvoided`, `item-refined`,
    `enabler-examined`, `escalated`, `crash-loop-escalated`,
    `labels-ensured`, `limit-hit`, `limit-cleared`,
    `orphan-branch-recovered`, `orphan-branch-released`,
    `issue-closed-post-merge`, `void-object-closed`,
    `disabled`, `enabled`, `salvage`,
    `warning`, `cycle-end`. A `salvage` event (requirement 9e) carries the
    `stage` being rescued and an `outcome` — `attempted`, `recovered` or
    `failed` — plus `exit_code` when the resume itself did not exit 0. It is
    written for every resume the Script actually starts, success or not,
    since a run of failed salvages with no `recovered` among them is itself
    the evidence that a shape `extract_json_result` still cannot reach has
    recurred; a failed run with no session to resume at all writes no
    `salvage` event, because no attempt was made. A
    `stage-start` carries the two caps that stage
    was given and where each came from — `backstop_min`, `inactivity_min`,
    `source` and `basis` (requirement 4f) — because a self-tuning number that
    cannot be traced is a mystery number. A `stage-end` carries `kill_reason` —
    `inactivity`, `backstop` or `rate-limit` — when and only when requirement
    4e stopped the stage; its absence means the stage ended on its own,
    well or badly. `exit_code` is 124 for both kills and so cannot tell them
    apart, and they are different findings. A `labels-ensured` carries the `repo`, its `role`,
    and the labels `created` and `failed` (requirement 6a) — it is written
    only when there was something to report, so it appears on a repository's
    first cycle and then not again unless a label is deleted or the token
    cannot create one. A `claim-lost` names the repo, item and branch of
    the candidate the Script failed to claim, plus a `cause` — `held` when a
    peer node won it, `unreachable` when GitHub could not be reached, or the
    raw exit code otherwise (requirement 17a); `selection` carries the
    claimed `branch`. A `pr-ready` carries `handoff` — `reviewer`, `script` or
    `enabler` — naming who took the PR out of draft (requirements 31a, 32b);
    the event means the pull request is not a draft, not that somebody said so.
    Where a human's review blocked it, `pr-ready` also carries
    `review_requested` — `already`, `requested` or `failed` — and the
    `reviewers` it names (requirement 31b); all three are omitted where nobody
    was blocking, which is the ordinary first-round case.
    An `attempt-failed` carries `pr_url` when the failing stage was working on
    one (requirement 32a), and — for the refinement class of requirement 34e —
    `kind: "needs-refinement"`, the `unblock_condition` taken from the report's
    `missing`, its `evidence` and reporting `source`, plus
    `needs_refinement_label` when the Script managed to project the label. A
    `recheck-clean` (requirement 18a) carries the `item` and `repo` the
    Co-Ordinator named in `recheck_clean` — repo-scoped, unlike `unblocked`,
    because the two fail in opposite directions: an `unblocked` that
    over-matches across repos only makes an item a candidate again
    (requirement 34 calls that the safe direction), where a `recheck-clean`
    folded into an unrelated repo's identically-numbered item would raise
    requirement 18a's comparison threshold and so *suppress* a mandated
    re-read. The Script tolerates an entry that arrives as a bare id — the
    event is logged without `repo`, and the extract folds it into every
    same-numbered blocked item, leaning on requirement 18a having obliged the
    emitting Co-Ordinator to re-read all of them — but that is a degraded
    fallback, not the shape to emit. Unlike `unblocked` it clears nothing;
    the `blocked` extract instead folds the newest such event per item into
    that item's entry as `recheck_clean_ts`, for requirement 18a's own
    comparison to read on the next cycle. An
    `item-refined` carries `repo`, `item` and either the `spec` the Enabler
    wrote or the `comment_url` of the comment it posted (requirement 36b); the
    common `cycle` and `ts` are what requirement 3h reads it back by. A
    `stage-start`/`stage-end` pair's `stage` is
    `coordinator`, `implementor`, `reviewer` or `enabler`; the last is the one
    that may appear on a cycle which selected nothing, since it runs from the
    cleanup of requirement 11. An `enabler-examined` carries `repo`, `item`, the
    `blocked_ts` it was examined against, an `outcome`, and the Enabler's own
    `detail`; an `escalated` carries `repo`, `item`, `issue_number`, `issue_url`
    and `blocked_ts` (requirements 35a, 36a). An `unblocked` written by the
    Enabler also carries `repo`, `by: "enabler"` and a `reason`, which is what
    distinguishes it from the Co-Ordinator's cheap re-check of requirement 18 —
    the bare-id form remains valid and remains what a human appends by hand. An
    `unvoided` written from a label (requirement 34f) carries `repo`,
    `by: "label"`, the `request_url` that authorised it, `labelled_at`, and the
    `cleared_void_ts` it reopened; the bare hand-appended form remains valid.
    The Reviewer's `stage-start` additionally carries the resolved
    `complexity` and the `model` it selected (requirement 8a) — the record
    that lets the distribution of complexity self-assessments be audited for
    drift. Common fields: ISO-8601 `ts`, `cycle` id, `node`, `event`, and where
    applicable `repo`, `item`, `pr_url`, `model`, `detail`. The cycle id is
    `<UTC-timestamp>-<node>-<pid>` — the node's `NODE_NAME` (hostname when
    unset), sanitised for use in a directory name, with the pid always last
    because the dashboard matches the running cycle by its `-<pid>` suffix.
    A record appended **by hand** was produced by no cycle, and says so: its
    `cycle` is the sentinel `"manual"`, which is deliberately not of that shape.
    Readers that enumerate cycles must therefore admit only ids matching
    `^[0-9]{8}T[0-9]{6}Z-` and ignore the rest, or a sentinel becomes a
    phantom run (dashboard spec, "A record in the log is not the same thing as
    a cycle"). Readers that act on the record — the blocked and void sets, the
    limit stand-down — key on the event and the item and never look at `cycle`,
    so a hand-appended record carries exactly the weight its event does.
    `node` says which machine wrote the record, which is what lets several
    nodes' records be combined; records written before the field existed
    simply lack it, and every reader treats it as optional. A `none-selected` also carries
    the `fingerprint` of requirement 3b; `disabled`/`enabled` carry the switch
    record, so the log can explain both why cycles stopped and why they
    resumed — including when they resumed because a disable expired rather than
    because anyone chose to re-enable it. `selection`, and any `attempt-failed` or `item-void`
    raised once an item has been selected, must carry both `repo` and `item` —
    requirements 34 and 34c key on them, so an event that omits them cannot
    pin any state on the item it names, and the omission is invisible until you
    notice the same work being redone.
33a. **Metering.** Every `stage-end` event additionally carries the per-stage
    metering record: `model` (the model id passed to the invocation),
    `cost_usd`, `duration_ms`, `num_turns`, `is_error` (pulled from the
    stage's `result` envelope named in requirements 11 and 4d /
    `docs/DASHBOARD-SPEC.md`), and `tokens` — an object with `input`,
    `output`, `cache_creation` and `cache_read`, summed across every model the
    invocation's own tree used (top-level plus any subagents), matching how
    `cost_usd` already counts subagent spend. `lib/metering.sh`'s
    `metering_fields` derives this from the stage's own out-file, and is the
    one implementation both this Script and `review-cycle.sh` call for their
    `stage-end`/`review-stage-end` events — a stage whose out-file was never
    written, or whose envelope cannot be read, degrades every envelope-derived
    field to `null` (`model` stays, being the id it was given) rather than
    dropping the event or failing the cycle. That holds for any envelope, not
    only the unreadable ones: the record is merged into the event as it is
    logged, so a derivation that produced nothing would cost the event its own
    `stage` and `exit_code` — the fields requirement 33 above and requirement
    34 below key on — and the metering of a stage must never be able to do
    that.
    The record additionally carries `gaps` — `{n, p50, p95, p99, max}` in
    seconds, or `null` — the run's own **inter-event gap statistics**: how
    long the invocation went between one piece of output and the next. This is
    the one field not read from the envelope, because it cannot be: the
    envelope records that the run did things, never when. `lib/stage-run.sh`
    measures it by `stat`-ing the stage's event stream inside the poll loop
    that already runs every two seconds while a stage is in flight, so the
    unit of observation is bytes arriving rather than events parsed — the
    contract is "the runner streams progress to a file; liveness is monotonic
    growth of that file", which is a statement about running a stage rather
    than about one CLI's output format. The stage emits nothing for this,
    agrees no cadence, and can fake nothing. The first gap is the wait for the
    run's first byte and the last is the silence from the final output to the
    end of the stage — that one included deliberately, because a stage that
    fell quiet and was killed has its longest silence at the end, and a sample
    that dropped it would omit exactly the runs the measurement exists to
    describe.
    `docs/METERING-SCHEMA.md` is the field-by-field contract: types, units,
    the per-cycle aggregation rule, and what future change is additive versus
    breaking.
34. Blocked semantics: an item is blocked iff the most recent
    `attempt-failed` / `unblocked` event *for that item* is `attempt-failed`.
    An `attempt-failed` event must carry enough detail for a future
    Co-Ordinator to judge whether the blocker has since been removed.
    `unblocked` events may also be appended by hand by the human. Three
    details decide whether this rule works at all:
    - **Key on `repo` and `item` together.** An item id is only unique within
      its repo — every repo has a `dependabot-alert-1`, and registers that
      number by date collide across repos — so keying on the id alone lets one
      repo's block starve the other's identically-named work.
    - **An event carrying no `item` blocks nothing**, and must be dropped
      rather than grouped under an empty key: a stage that fails before
      anything is selected has no item to blame, and collapsing every such
      event together yields one "blocked" entry describing no item at all.
    - **An `unblocked` event naming no repo clears that item in every repo.**
      The Co-Ordinator reports unblocked as a bare id (requirement 18) and a
      human appending one by hand has no repo to hand either, so there is
      nothing to match on. Over-clearing is the safe direction: the item
      merely becomes a candidate again and re-blocks on its next attempt.
34a. Whatever computes requirement 34 must be the **only** definition of it.
    Anything else that reports blocked items — notably the monitoring
    dashboard (`docs/DASHBOARD-SPEC.md`) — shares that one
    implementation rather than reimplementing the rule. Two copies drift, and
    a dashboard that quietly disagrees with the Co-Ordinator about what is
    blocked is worse than no dashboard: it is where you would look to find
    this class of bug, and it would show you the wrong answer confidently.
34c. Void semantics: an item is void iff the most recent `item-void` /
    `unvoided` event *for that item* is `item-void`. The rule is requirement
    34's shape over a different pair of events, and all three of its details
    apply unchanged — key on `repo`+`item`, an event naming no item voids
    nothing, a clear naming no repo clears everywhere. Build it as one
    parameterised rule used twice, not two rules that happen to agree
    (requirement 34a).
    - An `item-void` event carries `reason` and `evidence` — the SHAs, paths,
      or commands proving there is no work. A void is terminal, so the record
      must let a human audit the verdict without redoing the investigation.
    - **Only a human may clear a void**, by appending `unvoided` by hand. Give
      the Co-Ordinator no way to emit one; the whole point is that it must not
      reason its way out of a void, and it can reason its way out of anything.
    - A void is keyed to a specific item id, which is what stops it becoming a
      permanent gag. When the review pipeline runs again it files its
      recommendations under fresh ids (`review-<new-date>-R-NN`) that no
      existing void covers, so a genuine regression returns as new work. Voids
      expire by irrelevance rather than by review, which is the only expiry an
      unattended system will actually perform.
    - The Co-Ordinator may *create* voids (requirement 18) for candidates it
      can see conclusively are already done, and should: that is one cheap read
      instead of a full Implementor run reaching the same answer. Creating is
      safe where clearing is not — a wrong unvoid costs a cycle every hour until
      someone notices — but it is not free, and requirement 34d is what makes it
      safe enough to keep.
34d. **Every `item-void` write, from every stage, is corroborated before it is
    made permanent.** `void_guard_reason` in `lib/void-guard.sh` is the one
    entry point the Co-Ordinator (requirement 18), the Enabler (requirement
    36a's `void` row) and the Implementor (requirement 9b) all call before
    logging `item-void`; none of the three may write it directly. Four tests,
    all on the Script's side of the boundary:
    - **Evidence must be present.** Requirement 34c's `evidence` field is
      required on every void, and `null`, `""`, whitespace, `{}` and `[]` are
      all absence. An entry without it is not a verdict, it is an opinion.
    - **A resolvable citation must resolve.** `evidence` shaped `{ref, path,
      expect: "present"|"absent", pattern}` names a specific claim about a
      specific file at a specific ref — "the fix is on `main`", "the register
      says resolved" — and the guard fetches `repos/<slug>/contents/<path>?ref=<ref>`
      and tests it: `expect: "absent"` holds iff GitHub answers `404 Not
      Found`, `expect: "present"` holds iff the fetch succeeds and, when
      `pattern` is given, the decoded content matches it. Only that one answer
      establishes absence: a fetch that fails any other way — rate limited,
      unauthenticated, no network, a `ref` GitHub cannot resolve — has
      established nothing, and reads as the unreadable pull request below
      does, not as the absence it was asked about. A citation that does not
      fit the shape at all is free text, and is accepted on the presence test
      alone, as it always was — the guard tests what it can test, not a shape
      every claim must take. A citation that does fit the shape but does not
      resolve — the fetch fails, the presence/absence/pattern does not hold,
      or the entry names no repo to resolve it against — is refused the same
      way an unrefuted PR diff is below.
    - **A cited PR or commit must actually be about this item.** Evidence
      naming "PR #N" or "pull request #N" is fetched live
      (`repos/<slug>/pulls/<n>`) and checked for the item id, as a whole word,
      in its body or its head branch — the same two places the gatherers read
      to associate a PR with an item in the first place. Evidence naming a
      commit ("commit `<sha>`" or "`<ref>@<sha>`") is checked two ways: the
      commit must be an ancestor of the repository's default branch
      (`repos/<slug>/compare/<sha>...<default_branch>`, `status` `identical`
      or `ahead`), and either its own message or a pull request GitHub
      associates with it (`repos/<slug>/commits/<sha>/pulls`) must name the
      item the same way a cited PR does. One item shape is decided by its id
      alone, with no fetch: a finishing-source item **is** a pull request —
      requirements 3e, 3g and 23 mint its id as `pr-<n>-abandoned-<head-sha>`,
      `pr-<n>-review-<review-id>` or `pr-<n>-conflict-<head-sha>` — so a
      citation of pull request `<n>` corroborates item `pr-<n>-…` by the id's
      own construction, while any other pull request is tested as usual.
      Nothing writes that synthetic id into the pull request's body or branch,
      so without this the test would refuse the one citation these items can
      honestly make, on exactly the sources the candidate test below
      corroborates best. Evidence citing neither a PR nor a commit is
      untouched by this test — the two tests above are what govern free prose.
      This is what a citation that merely *exists* was missing: the shipped
      defect that motivated it (below) cited a PR that was real, open, and
      entirely unrelated to the item being voided.
    - **This cycle's own candidates must not refute it (Co-Ordinator only).**
      Where the voided repo+item matches a gathered candidate carrying a
      `pr_number`, the guard reads that PR's changed files: a non-empty diff
      against its base means the change is by definition not on the base,
      whatever anyone asserts. The candidates tested are the ones the
      Co-Ordinator was given, so a void can never be refused over something it
      could not have seen. A PR the API will not answer for counts as
      uncorroborated, not as innocent. The Enabler and the Implementor gather
      no per-cycle candidate list, so they call the same guard with `repos:
      []`; this one test simply has nothing to run, and every other test above
      applies to them exactly as it does to the Co-Ordinator.

    A refused void is recorded `attempt-failed` — blocked, not void — plus a
    `warning` naming the refusal, with `stage` set to whichever of the three
    wrote it. Blocked is the clearable twin: the stage still skips the item so
    nothing churns, and requirement 35a makes it Enabler-eligible, so an actor
    that *can* read the tree adjudicates. If the item really is done, a later
    engagement voids it properly, with evidence that survives corroboration.
    The pipeline reaches the same answer; it may not reach it by assertion. A
    refusal from the Enabler's own `void` verdict is recorded with the outcome
    `void-refused` on its `enabler-examined` event (requirement 36a) — an
    ordinary examination, not `escalation-failed`'s exemption, since the
    engagement did reach a verdict; it was simply not corroborated.

    Not a prompt instruction, and the distinction matters: "be certain" is
    already in `prompts/coordinator.md` twice, and the Co-Ordinator that voided
    `TD26072114` with "PR #92 work is finished … all merged; TECH-DEBT.md Ledger
    marked resolved" was certain. On the default branch the workflow still had no
    timeout, the Ledger row still read `open`, and PR #92 was an open, conflicted
    draft. Because a void keys on the item it bypassed the per-head refs of
    requirements 3e and 3g that exist precisely so a changed state gets a fresh
    look, so the item was unreachable from both directions at once — void as a
    tech-debt candidate and void as the abandoned draft that would have finished
    it. Every following cycle reported `none-selected` citing the void, the no-op
    fingerprint (requirement 3b) then matched, and three nodes stood down hourly
    on a repository with outstanding work. That is the shape of the failure this
    guards: not a wrong answer, but a silent one.

    The citation test above closes a second, distinct shape of the same
    failure: a Co-Ordinator voided an issue citing "PR #232 implemented all
    five rewrites" — #232 was real and mergeable, but it was a different
    issue's PR; the actual fix had landed in a different pull request
    entirely. Every test that existed before the citation test passed, because
    none of them had ever asked whether the cited PR was *about the item being
    voided*. Reading more of the repository does not fix this by itself — the
    Enabler and the Implementor already read more than the Co-Ordinator does,
    and carried the same gap regardless — only checking the citation does,
    which is why the guard is shared rather than duplicated per stage.

34e. **Under-specification is a class of block, not a parallel state.** Each
    well-formed `needs_refinement` entry (requirement 16a) is recorded by the
    **Script** as an `attempt-failed` against that repo+item with
    `stage: "coordinator"` and `kind: "needs-refinement"`, the entry's `missing`
    promoted to `unblock_condition` and its `reason` and `evidence` carried on
    the event. Everything downstream then follows from requirement 34 with no
    new machinery: the item is excluded from selection (16.1), becomes eligible
    for the Enabler on the ordinary threshold (35a), is cleared by an
    `unblocked` from either the Enabler or the Co-Ordinator's own cheap
    re-check (18), and can be voided if it turns out to describe no work. A
    parallel state would have had to re-earn every one of those properties, and
    would have earned each of them slightly differently.

    The threshold delay is a feature here, not a cost of the reuse: it gives the
    human — or requirement 18's re-check, which can clear a refinement block
    whose `unblock_condition` has demonstrably been met, such as a patched
    version appearing for a skipped security finding — several cycles to settle
    the item before the expensive stage is bought.

    Two entries are refused, both on the Script's side of the boundary:
    - **A malformed entry** — missing `repo`, `item`, `reason`, `missing` or
      `evidence`, judged on requirement 34d's emptiness discipline — is logged
      as a `warning` and dropped. The fields are what the Enabler starts from,
      so an entry short of one starves the very stage the report exists to
      reach.
    - **A re-report of an item that is already blocked** is logged as a
      `warning` and dropped. Requirement 35a measures the Enabler threshold from
      the *latest* `attempt-failed`, so a Co-Ordinator that re-reported the same
      item every cycle would push that clock forward hourly and the item would
      never become eligible — the identical silent starvation this path exists
      to end, wearing an event trail that looks like progress.

    **The label is a projection, never the record.** Where (and only where) the
    item is a GitHub issue — the `issues` source, whose ref is a bare number —
    the Script applies `needs_refinement_label` to it as it records the block,
    records on the event which label it applied, and removes that label when the
    block is cleared or the item is voided. Nothing ever reads the label back.
    Work items here are heterogeneous — issues, tech-debt records, review
    recommendations, findings, plan tasks, per-round PR refs — and a label can
    reach exactly one of those sources, so a pipeline that read it would see a
    fraction of its own state and be confidently wrong about the rest. The label
    is recorded on the event rather than assumed from config because it is what
    a later cycle removes: a label the Script did not apply is one it must not
    claim to have removed. A repo where the label does not exist gets a
    `warning` and the block regardless — losing the projection costs a human's
    filter, losing the block would cost the item its escape path.

    On `--dry-run` the block is recorded like the other verdicts this path
    already logs, and **no label is applied or removed**: a label is an outward
    change to a repository, which requirement 12's run promises not to make.
    Since the event records only what was actually applied, nothing later tries
    to remove a label that was never there.
34f. **The human's escape hatch reaches the human.** Requirement 34c reserves
    clearing a void to a human and gives them one interface: a line appended by
    hand to `state_dir/log.jsonl`. That interface is unreachable in the
    deployment this system actually has — the nodes are containers and
    `state_dir` is a volume inside one, while the maintainer is in a browser
    looking at the pull request the void is about. An escape hatch nobody can
    reach does not constrain anything; it just makes the terminal state
    permanent in practice as well as in principle.

    So a void is also cleared by applying the `unvoid_label` (default
    `unvoided`) to any issue or pull request naming the item, in the item's
    repo. Per repo per cycle the Script reads the issues carrying that label —
    one call, since the issues endpoint returns pull requests too — resolves
    each to the item ids its branch, title and body name (an issue also being
    its own id), and clears the matching voids. This is not a relaxation of
    requirement 34c: **no stage ever applies this label**, so only a human can,
    exactly as before. What changes is where they have to be standing.

    Three properties, all load-bearing:
    - **Applied above the extract.** The `unvoided` events are written before
      `blocked_items`/`void_items` are read for the cycle, and appended to the
      union snapshot of requirement 2.5 — the exact lines just written, not a
      rebuilt snapshot, which would pull in whatever peers wrote meanwhile. A
      clearance landing after `void_json` was computed is a cycle late, and a
      cycle late here means the human watches nothing happen and concludes, for
      the second time, that the label does not work. It also needs no new
      fingerprint input (requirement 3b): `void_json` is already fingerprinted,
      and it shrinks the same cycle the label is read.
    - **The label is never removed.** Removing it would move the item's
      `updatedAt`, which is the clock `abandoned_draft_after_hours` is measured
      against (requirement 3e) — so tidying up after the human would push the
      very pull request they are unsticking another staleness window into the
      future.
    - **Which makes the rule, not the label, what stops it repeating.** A
      clearance is emitted only where the item is void *now* and the void was
      recorded *strictly before* the label was applied. The first test makes it
      idempotent with no label churn. The second stops a label left in place
      becoming a standing exemption that auto-clears every future void on that
      item from an instruction given months earlier about a different verdict —
      a failure with no symptom at all beyond an item that never stays void.

    The recorded `unvoided` carries `by: "label"`, the `request_url`,
    `labelled_at`, and the `cleared_void_ts` it reopened, so a later reader can
    see which verdict was reopened and on whose authority without going back to
    GitHub. The hand-appended line of requirement 34c remains valid and
    unchanged; this is a second door to the same room.

    The instinct it serves is the one the system already teaches: labelling a
    pull request `autonomous-agent` hands it to the pipeline, so a label is
    already how a human tells this system something from GitHub. Faced with a
    void, a maintainer applied a label called `unvoided` to the pull request and
    nothing read it — the item stayed void, the fleet stood down hourly, and the
    label sat there looking like the action had been taken.
34g. **A human's own hand-applied label is a report, not a state.** Requirement
    34e's projection is deliberately one-way for the block *it* creates: the
    label mirrors what the Co-Ordinator already reported, and nothing reads it
    back. That left the one person the mechanism serves unable to invoke it —
    a human reading an issue has no `needs_refinement` entry to hand a
    Co-Ordinator, and no `state_dir/log.jsonl` to append to from a browser, the
    same gap requirement 34f closes for a void. Applying
    `needs_refinement_label` by hand did nothing and looked exactly like it had
    worked.

    So, during source gathering, the Script scans each repo's issues — open and
    closed, one search per repo — for `needs_refinement_label` and resolves who
    last applied it and when from the issue's timeline. Read above the
    skip-list extracts, for the same reason as 34f: a reconciliation landing
    after `blocked_json` is computed is a cycle late, and a cycle late here
    reads to the human as the label not working, a second time.

    Two decisions follow, both against `blocked_items` as it stands at the
    point each is made:
    - **A currently-open issue carrying the label, with no block yet open for
      it under any kind or origin**, earns a coordinator-stage `attempt-failed`
      exactly like a Co-Ordinator's own `needs_refinement` report would:
      `kind: "needs-refinement"`, `detail` naming the label and who applied it,
      `source: "issues"`, the label itself as `needs_refinement_label` (so its
      lifecycle — removed when the block clears — is the one requirement 34e
      already describes), and `hand_flagged: true`, which marks this block as
      one this mechanism, not the Co-Ordinator, created. There is no
      `unblock_condition`: a human applying a label has said "this needs
      specifying", not what is missing, and a promoted field with nothing
      behind it would be worse than an absent one. A closed issue is excluded
      even if it still carries the label — a closed issue is not a candidate
      the `issues` source or requirement 35a's escalation test can reach
      either, so blocking it would buy an engagement over something already
      unselectable.
    - **A block this mechanism created (`hand_flagged: true`) whose issue no
      longer carries the label at all** — open or closed — maps to the
      existing hand-appended `unblocked` path (requirement 18): the Script
      logs `unblocked` with `by: "label-removed"`, and the item is selectable
      again next cycle. Scoped to `hand_flagged` blocks only, and only that
      scoping keeps 34e's one-way rule true for everything else: a block the
      Script itself projected the label onto is not marked `hand_flagged`, so a
      label missing from underneath one of those — by mistake, by the repo's
      own automation, by anything other than this mechanism — clears nothing.
      Reading the label back for every refinement block regardless of origin
      is the "second writer of refinement state" this design deferred rather
      than shipped as part of requirement 34e (`TECH-DEBT.md` TD26072602): it
      would let anything that touches the label reopen a block a model is
      still working from, on no authority at all. An issue that keeps the
      label but is closed is not a removal either, by the same closed-issue
      reasoning as above — the human closed the issue, they did not withdraw
      the flag.

    Eligibility asks nothing new of a hand-flagged block: requirement 35a
    already treats `kind` as informational rather than a second axis — "the
    kind marker changes nothing about the rule, and deliberately so" — so a
    hand-flagged block crosses the same `enabler_after_coordinator_cycles`
    threshold as any other refinement block, reported or hand-flagged alike.
    Carving out separate pacing for this one origin would be exactly the
    exception that design note declines to make, and the fleet has no evidence
    yet that a human's label needs different timing from a model's report;
    whether refinement blocks in general deserve their own threshold is the
    tuning question `TECH-DEBT.md` TD26072604 leaves open for later, not one
    this requirement answers on a guess.

    `--dry-run` still records both directions: neither writes to GitHub (the
    label is only ever read here, never applied or removed by this mechanism),
    so there is no outward change for requirement 12 to forbid.

34h. **Where the two states meet, void wins.** An item may carry both marks at
    once, and routinely does: `item-void` is a state of its own and clears no
    block, so a `void` verdict — the Enabler's ordinary way of retiring work
    that turned out to be already done (requirement 36a) — leaves the
    `attempt-failed` before it standing for as long as the log remembers it.
    Requirements 34 and 34c are the same rule over different events, but they
    are not symmetric in what they ask of whoever reads them, so any consumer
    that must reduce an item to *one* state resolves it to **void**: a void item
    is waiting for nothing, is never selected, and is never re-examined at the
    Enabler's prices, and reporting it as blocked overstates the backlog with
    work the pipeline has already closed the book on.

    That subtraction is a rule in its own right and so has exactly **one**
    implementation (requirement 34a): `open_blocked_items` in
    `lib/cycle-state.sh`, which composes the blocked and void extracts rather
    than re-deriving either, matches a void to a block on requirement 34's own
    terms — a void naming no repo covers the item in every repo, since either
    half of that pair may be hand-appended by a human with no repo to hand —
    and carries each entry through unchanged, `recheck_clean_ts` and all. Both
    consumers that owe a single answer use it: the Enabler's eligibility rule
    (requirement 35a, clauses 1 and 2) and the monitoring dashboard's Blocked
    items table (`docs/DASHBOARD-SPEC.md`).

    The Co-Ordinator's own input is **not** reduced. It is handed the blocked
    list and the void list side by side (requirement 18), and requirement 34c
    means it to see both: "skip this for now, and clear it when the impediment
    goes" and "never select this again, and never clear it" are different
    instructions, and an item that has become the second is one the Co-Ordinator
    must be told about under the state that binds it.

34i. **A block whose work is gone is cleared without asking anyone.** The
    common way a block ends is not that the impediment lifts — it is that
    somebody finishes the work: the issue is closed, the pull request merged,
    the register entry flipped to `resolved`. None of that emits an event, and
    both readers requirement 34 relies on are blind to it in the same place. The
    Co-Ordinator never revisits the item, because a finished item is offered by
    no source and so never reaches its candidates; the Enabler does, but only
    after `enabler_recheck_hours`, and it pays a full engagement to learn what
    one read of state the cycle already holds would have said. Until then the
    item is reported as blocked, and the count an operator reads at a glance
    says the pipeline is stuck on work that is done.

    So, in the same pre-extract window as requirements 34f and 34g, and against
    the *open* blocked set (34h — a void item needs no unblocking), the Script
    answers one question per item class and logs `unblocked` with
    `by: "work-gone"` and a `detail` naming the fact that decided it:

    - **an issue** (a bare number) — the number is not in that repo's open-issue
      digest (requirement 3b);
    - **a pull request** (`pr-<n>-abandoned-…`, `-conflict-…`, `-review-…`) —
      the number is not in that repo's open-PR digest;
    - **a register item** (`TD<date><nn>` or `TD-<scope>-<date><nn>`) — the
      item's own file on the default branch says `status: resolved` or
      `status: not-debt`, read by `scripts/gather-register-status.sh` for the
      blocked ids and no others, so a fleet with no blocked register items pays
      nothing and the read is bounded by the backlog rather than the register.
      It sits above the no-op skip of requirement 3b, like the rest of this
      window, so an item that stays *genuinely* blocked does cost a listing and
      a file read every cycle. Deciding whether to reconcile only after deciding
      whether to run is the cycle-late failure 34f and 34g are placed here to
      avoid, and two reads is a small price beside the Enabler engagements that
      item is already earning;
    - **a project-review recommendation** (`review-<date>-R-NN`) — a *merged*
      pull request on the default branch names that ref, read by
      `scripts/gather-review-status.sh` for the blocked refs and no others,
      against the repo's 100 most-recently-closed pull requests. This is the
      same test requirement 16 already applies when deciding whether to offer
      the recommendation as a candidate at all — the review folder is a
      point-in-time record no stage ever edits to say a recommendation is
      done (requirement 25), so the merged PR's own text naming the ref, put
      there by the Implementor that closed the recommendation out, is the one
      fact anywhere that answers "is this done?", and this reads it instead of
      asking a Co-Ordinator to notice it went stale;
    - **an implementation-plan task** (e.g. `W10-breach-handling`) — the
      task's own checkbox, in the repo's `implementation_plan_path` document
      on the default branch, is checked (`- [x]`), read by
      `scripts/gather-plan-status.sh` for the blocked ids and no others. This
      is certain only when exactly one task-list line in the document names
      the id as a whole word; two such lines, or none, decide nothing.

    Three properties make this safe enough to run unattended:

    - **Unknown is never gone.** A repo missing from the digest, a digest
      carrying `ok: false`, an id no register file claims by `id` or
      `legacy-id`, a review ref no merged pull request's title or body names, a
      plan id no task-list line names (or that two of them do), all decide
      nothing and leave the item blocked. The failure is a delayed clearance,
      which costs a cycle; the other direction clears a block out from under
      work that is still real, which costs a cycle an hour until someone
      notices.
    - **The findings sources are excluded, and that is not an oversight.**
      `gather-findings.sh` degrades to `[]` on an API error by design
      (requirement 3), because a Co-Ordinator that sees no findings declines and
      the two agree. Read as a clearing signal the same `[]` says "every alert
      is fixed", so one 403 would clear every alert block on the fleet. A
      register-hygiene item (`register-hygiene-<hash>`) is excluded for the
      plainer reason that it has no completion signal to read at all — the
      register *is* the item, and its file shape is what `register-hygiene`
      itself repairs. Both remain the Enabler's, exactly as before.
    - **It clears, it never voids.** The event is `unblocked`, which requirement
      34 calls the safe direction — a wrongly cleared item becomes a candidate
      again, is offered by no source, and nothing happens. A void is terminal
      (34c) and must be corroborated (34d), and neither is what a deterministic
      tidy-up has earned.

    The rule has one implementation, `work_gone_clearances` in
    `lib/work-gone.sh`, which is pure: it decides from the blocked set, the
    digests and the three side-channel status maps (register, review, plan) it
    is handed, and reads nothing itself.
34j. **A structured dependency is held, and released, by code — never by a
    model re-reading prose.** `Blocked-by: #195` (same repo) or
    `Blocked-by: owner/repo#195` (a repo this pipeline also walks), one or
    more comma- or whitespace-separated references on their own line in a
    GitHub issue's body or any comment in its thread, names a specific item
    whose live open/closed state — not a narrative account of it — decides
    the block. This exists because prose did not survive being re-judged: a
    note like "hold until #195 is merged" is only ever a description of a
    moment, and the moment it describes can pass without the note changing.
    Four issues (#196–#199) recorded exactly that — the initial re-check
    correctly cleared them within 43 minutes of #195 actually merging, and
    the same stale sentence then re-blocked more than one of them again,
    each false block costing a full Enabler engagement to undo, because the
    only reader of the note was a Co-Ordinator asked to re-examine it
    (requirement 18a) from nothing but the paragraph itself. A reference is
    immune to this by construction: nothing here ever trusts what a
    `Blocked-by:` line asserts happened, only what re-checking the number it
    names says *now* — so a stale line naming an already-closed item is
    inert, not wrong, and never needs to be edited out for the mechanism to
    stay correct (contrast the Enabler's own remedy below, which is about
    the next dependency, not this one).

    Two deterministic mechanisms apply it, both reusing data the cycle
    already holds and asking no model anything:

    - **Holding.** `scripts/gather-issues.sh` drops a candidate whose thread
      names a `Blocked-by:` reference that is not closed — checked live,
      per reference, the moment its whole thread is in hand — the same way
      it already drops an assigned or `blocked`-labelled issue (requirement
      3j). An item newly declaring a dependency therefore never reaches the
      Co-Ordinator and never earns an `attempt-failed`: the dependency holds
      it before the pipeline's own notion of "blocked" is ever written, at
      zero cost beyond the one `gh` read per reference the candidate would
      otherwise have spent a full evaluation on anyway.
    - **Releasing.** Against the *open* blocked set (34h), in the same
      pre-extract window as 34f, 34g and 34i, the Script reshapes this
      cycle's own freshly gathered `issues` candidates to a `repo → item →
      thread` map and clears any blocked issue found there whose thread
      still carries a `Blocked-by:` line: presence in that map, on its own,
      already proves gather-issues.sh's holding check found every reference
      resolved this same cycle, so the release asks no second question of
      GitHub — it reads the holding check's own verdict rather than
      re-deriving one. An item excluded from this cycle's candidates for
      *any* reason — a reference still open, an assignment, the `blocked`
      label, or simply a repo this cycle did not walk — is absent from the
      map and decides nothing, the same "unknown is never gone" rule
      requirement 34i's clearances observe. Logged `unblocked` with
      `by: "dependency-resolved"` and a `detail` naming the reference(s)
      that resolved.

    The rule has one implementation, `dependency_clearances` in
    `lib/dependency-gate.sh`, alongside the parser, `dependency_refs`, that
    both mechanisms share.

    This binds to GitHub issues only, for the same reason requirement 18a
    does: they are the one blocked-item shape with a thread the cycle
    already reads whole. It does not need requirement 3b's fingerprint
    extended to cover it: a same-repo reference's state is already part of
    that repo's `issues` digest (open issues) or claim signal (open PRs),
    and a cross-repo reference needs its own repo configured and walked
    for the same reason 34i's register/review/plan reads do — so the
    reference resolving always changes the `issues` array gather-issues.sh
    hands the Co-Ordinator (a previously excluded candidate now appears),
    which requirement 3b already fingerprints verbatim, waking the fleet
    within the hour without a dedicated projection.

    A model's part in this is deliberately narrow. Nothing here edits an
    issue's body — an agent rewriting a human's own text is a cost this
    convention does not need paid, since a stale reference is inert rather
    than misleading. The Enabler, examining a blocked or refinement-class
    item and recognising an unstructured dependency note it cannot itself
    act on, may post one comment naming the structured form the pipeline
    can read (requirement 36's existing "one concise comment" power,
    spending nothing new); the comment becomes part of the thread this
    convention already reads, so a human — or the Co-Ordinator, next time it
    is asked to select this item — can adopt it verbatim.
34k. **Act on void: close the GitHub object a void names.** A void
    (requirement 34c) already stops the item being selected again, but
    nothing before this touched the *object* it is about — an obsolete draft
    pull request or a superseded issue stayed open on GitHub, visible to
    every human and to every tool that reads the repository rather than this
    pipeline's own log, and kept being re-derived void by cycle after cycle
    with nothing ever said to it (issue #240; poetic-fiddle #190/#214 were
    re-derived void on 7+ separate cycles and never closed). Void tombstones
    are private state, and the world they describe was never corrected.

    So, in the same pre-extract window as 34f/34g/34i, against `void_json`
    (the full void set — an already-void item needs no unblocking, but it
    still names an object that may need closing), the Script asks
    `scripts/close-void-github-items.sh` to close it, for the two id shapes
    that name a GitHub object at all (the same shapes requirement 34i's own
    work-gone rule reads, from the one definition in `lib/work-gone.sh`):

    - **an issue** (a bare number) — closed, with a comment carrying the
      void's own `detail` (the reason) and `evidence`, iff GitHub still
      reports it open;
    - **a pull request** (`pr-<n>-abandoned-…`, `-conflict-…`, `-review-…`) —
      closed the same way, iff still open.

    Every other void shape — a tech-debt register id, a project-review ref,
    an implementation-plan task id — names something that is not a GitHub
    object to close, and requirement 34k does nothing with it; a register id
    is instead requirement 34l's concern, immediately below.

    **Only a corroborated void — today, that is all three writers.**
    `void_json` holds the unresolved `item-void` events of all three writers
    (Co-Ordinator, Enabler, Implementor), and requirement 34d's guard
    corroborates every one of them before it is logged (issue #243), so each
    is eligible here. Each candidate still carries its event's `stage`, and
    `close-void-github-items.sh` still gates on it — an uncorroborated
    `item-void` must never reach this point, but if one somehow did (a future
    writer that bypassed the guard, a malformed or stageless entry), the gate
    is what stops it closing a live issue on an unexamined claim. An
    ineligible void is left exactly as a register id is — unprocessed and
    unmarked, so nothing stops a later pass acting on it once it is
    corroborated. The one-shot rule immediately below is the second,
    independent bound — recovery rather than precondition — and a human's
    plain re-open wins permanently.

    **Acted on at most once, ever — deliberately not tied to the void
    clearing.** `void_object_closed_items` (`lib/cycle-state.sh`) is the set
    of `{repo, item}` pairs a `void-object-closed` event already names; the
    Script excludes them from every future pass, regardless of what happens
    to the object afterwards. This is not the same safety margin as 34d's
    corroboration — it exists because closing is an action with a visible,
    somewhat blunt side effect (a comment on someone's issue), and a human
    who simply reopens the object, without going through the sanctioned
    `unvoid_label` route (34f) that actually clears the void, must not have
    it closed on them again next cycle. `unvoid_label` remains the only way
    to make the *void* itself go away; this only ever runs once regardless.

    Bounded and idempotent: three actions per repo per cycle (the overflow
    reported, never silent, same as every other sweep here), and a `gh` read
    before every close means the worst outcome of two nodes racing is both
    finding nothing left to do. Skipped on `--dry-run`.
34l. **Register rows, voided.** A void naming a tech-debt register id
    (`lib/work-gone.sh`'s `WORK_GONE_REGISTER_RE`) names a file, not a
    GitHub object — 34k's own close has nothing to do with it. But the same
    defect it exists to close applies just as much here: the fleet's void
    log already knows the item is done, most often because the fix landed
    some way other than that item's own claim branch, and the register file
    still says `status: open`, advertising unfinished work forever
    (TD-PPpfid-26071901, voided in July, still `open` months later; issue
    #240).

    So, for every repo `work_gone_register_ids` names against `void_json`
    (the same shared function requirement 34i's clearance rule already
    calls, applied here to the void set instead of the blocked one), the
    Script re-derives that repo's register-hygiene candidate —
    `scripts/gather-register-hygiene.sh`, called a second time this cycle,
    now with the void items and their evidence — and replaces the entry
    requirement 3i's own pre-fetch loop already built for it in the
    Co-Ordinator's runtime input. The replacement only ever happens on a
    non-empty answer: this pass is a superset of the first by construction,
    so an empty result means the second read failed where the first
    succeeded, and overwriting on it would delete a candidate the cycle
    already holds on no evidence at all. The gatherer's own `VOIDED STATUS` problem
    class (a second, disjoint source of candidacy layered on top of
    `td-check.pl`'s internal-consistency rules, never fed back into the
    byte-identical upstream checker) is what makes this a candidate at all
    when `td-check.pl` alone would find the file fine. The repair travels
    through the ordinary register-hygiene Implementor flow (prompts/
    implementor.md's "Register hygiene" procedure) exactly as any other
    frontmatter drift — flipping `status:` to `resolved` with the void's own
    evidence as `ref:`, or clearing stray resolution fields, whichever the
    facts support — never a write this pipeline makes directly against a
    protected default branch.

    Re-fetching the register a second time per repo (rather than reordering
    the cycle so requirement 3i's own pass already had `void_json`) costs
    one extra tarball read, and only for a repo that actually has a void
    register item — everywhere else, nothing. The alternative was moving
    34f/34g/34i/34k's whole pre-extract window earlier than the ordering
    those requirements are already deliberate about.

### The Enabler

35. **Engagement.** At the end of a cycle — from the cleanup of requirement 11,
    after the workspace is deleted and before the `cycle-end` event, with the
    lock still held — the Script engages the Enabler over the eligible items of
    requirement 35a: a headless invocation (model `enabler_model`,
    `--dangerously-skip-permissions`, timeout `timeout_enabler`) logging
    `stage-start`/`stage-end` with `stage: "enabler"` like any other stage, and
    parsed from its final message like any other stage.

    **One call site.** Nine paths end a cycle; the cleanup is the one place all
    of them pass through, and calls at each exit point would be nine chances to
    forget one — including the exits that matter most here, where the cycle
    stood down without selecting anything. Inside the lock, so requirement 33's
    single-writer guarantee still holds while these events are written; before
    `cycle-end`, so they belong to the cycle that produced them and travel on
    the same end-of-cycle `state-sync push` (requirement 2.5).

    It engages only when **all** of the following hold, and any one of them
    failing is an ordinary, silent non-engagement:
    - this cycle acquired the lock;
    - the gatherers completed, so the eligible set was computed from inputs that
      exist. Every earlier exit — the role guard, either switch, the usage-limit
      cooldown, a lock held by a live cycle — therefore cannot engage it;
    - the cycle is not `--dry-run`. `--once` **does** engage: a supervised
      engagement is the only way to watch one, and it contends with the fleet on
      equal terms exactly as `--once` does for claims (requirement 17a);
    - the cycle's own exit code is 0. A cycle that ended badly is not the moment
      to spend the most expensive model in the system;
    - no usage limit was detected during this cycle (requirement 10), *and* a
      live read of `fleet/limit.json` (requirement 2.1) does not stand the fleet
      down right now — a limit a peer hit while this cycle was working is
      precisely the news that should stop this stage starting;
    - `enabler_model` is set and `prompts/enabler.md` exists;
    - at least one eligible item was claimed (requirement 35c).

    Every claimed item goes to **one** invocation. The reading is per item but
    the session overhead is not, and the set is small by construction.

    `enabler_assignee` is not one of these guards: unlike an empty
    `enabler_model`, an `enabler_model` set with no `enabler_assignee`
    configured is not a silent non-engagement. The Script validates it at
    config-read time, before the cycle does anything else, and exits with an
    error if the combination occurs — an unassigned escalation would not be
    excluded by requirement 16.4 and the pipeline could go on to select it as
    its own work, so the failure must be loud rather than a quiet skip.
35a. **Eligibility.** An item is eligible for the Enabler iff **all** of:
    1. it is **blocked** (requirement 34) — call that latest `attempt-failed`
       event *B*;
    2. it is **not void** (requirement 34c). An item with no work needs no
       unblocking, and an item recorded both ways must not be re-examined at
       this stage's prices;
    3. **no escalation issue for it is still open** — the `issue_number` of the
       latest `escalated` event for that repo+item is not among the repo's open
       issues in the source-state digest (requirement 3b). A repo missing from
       that digest could not be sampled, so whether its escalation is open is
       unknown, and unknown resolves to **ineligible**: a delayed engagement is
       cheap, a duplicate issue in the human's inbox is not;
    4. one of exactly three **reasons** applies, and that reason is recorded on
       the entry and passed to the model, because it decides where the model
       should look first:
       - **`threshold`** — no examination newer than *B*, and at least
         `enabler_after_coordinator_cycles` distinct cycles have logged a
         `stage-end` with `stage: "coordinator"` and `exit_code: 0` since *B* —
         or `refinement_after_coordinator_cycles`, for a block whose `kind` is
         `needs-refinement`. That event is the definition of "a cycle that ran
         a Co-Ordinator", and pinning it there is what makes the threshold mean
         "the pipeline has had several honest chances to clear this itself":
         every stand-down — switch, cooldown, no-op short-circuit,
         back-pressure — logs no coordinator `stage-end` and so ages nothing.
       - **`issue-closed`** — an escalation raised after *B* is no longer open,
         and no examination has followed it. This bypasses the threshold
         deliberately: the human acted, and requirement 36a promised them that
         closing the issue is what restarts the work.
       - **`recheck`** — the newest examination of the item is older than
         `enabler_recheck_hours` (`0` disables). For a GitHub issue,
         requirement 18a already catches new evidence posted into its own
         thread same-cycle, off the issue's `updated_at` — the failure
         `TECH-DEBT.md` TD26072101 records. This bound is what closes the
         gap for everything 18a does not reach: every non-issue blocked
         source, and a blocker on an issue that clears without a comment ever
         landing (nothing then moves `updated_at`).
    A re-block re-enters through `threshold`, because every clause above is
    measured from *B*: a fresh `attempt-failed` moves *B* forward, leaving the
    old examination behind it and restarting the count.

    An `enabler-examined` whose outcome is `escalation-failed` is **not** an
    examination for any of the above. That engagement reached a verdict it could
    not act on, so the item is exactly where it was, and counting the marker
    would retire the item on the strength of a failed `gh issue create`.

    A coordinator-stage refinement block (requirement 34e) is eligible on
    exactly these terms — the `kind` marker changes only which threshold the
    `threshold` reason compares against, never the set of reasons, the escalation
    check, or any other clause. Each entry additionally carries that `kind`, so
    the engagement knows which duty it is there to perform (requirement 36b),
    and `refined_before`: the latest `item-refined` event for the same
    repo+item, or `null`. That field is the thrash guard's input and the
    record of what the last engagement already specified, so a later one need
    not reconstruct it.

    Like requirements 34 and 34c, this rule has exactly **one** implementation
    (requirement 34a): `enabler_eligible_items` in `lib/cycle-state.sh`, whose
    clauses 1 and 2 above *are* requirement 34h's `open_blocked_items` rather
    than a second reduction of the same two extracts, always
    succeeds, and yields `[]` for a log it cannot read or a threshold it cannot
    parse — an unreadable setting is not a licence to spend.
35b. **The eligible set is part of the no-op fingerprint** (requirement 3b),
    projected to `repo|item|reason`, alongside the Enabler's config and a hash
    of `prompts/enabler.md` and any configured `prompt_overrides.enabler`
    files (requirement 4a). It is the third array whose candidacy turns on
    something no repo signal carries: an item becomes eligible once enough
    Co-Ordinator cycles have run since the block, which moves no commit,
    issue, alert or PR — so without it the escalation path would come due during
    a quiet week and wait for the forced recheck to be noticed. The `reason`
    rides in the projection because the transition that matters most keeps the
    same item in the set: a human closing the escalation issue turns the entry
    into a verification. A threshold crossing therefore wakes a quiet fleet, and
    that cycle runs the Co-Ordinator normally — which may clear the item far
    more cheaply — before the Enabler runs at all; the examined markers then
    empty the set and skipping resumes.

    One consequence is deliberate, not an oversight: because the eligible set
    turns on the *log*, editing `prompts/enabler.md` (or its configured
    overrides) busts the fingerprint but does not re-open items already
    examined. `enabler_recheck_hours` is the
    lever for "look at this one again"; a prompt edit is not.
35c. **One engagement per item, fleet-wide.** Before engaging, the Script takes
    a per-item file claim through `lib/claim.sh` under the pseudo-slug
    `enabler`, keyed `<repo>__<item>__<epoch of B>` (plus `__verify<issue>` for
    an `issue-closed` verification, which needs a key the earlier examination's
    claim does not already hold). The key is derived, never chosen by a model,
    so every node computes the same one and GitHub arbitrates; items whose claim
    is lost are simply left to the node that won.

    These claims are **never released**. The claim is a tombstone: it is what
    stops the same item being re-examined next cycle when the engagement
    produced no examined marker at all — a timeout, a garbage final message, an
    omitted item — and `lib/claim.sh gc` sweeping it at `claim_ttl_hours` is the
    only thing that permits a retry, which bounds a failed engagement's cost at
    one attempt per TTL. `lib/claim.sh expire` (requirement 37) shortens that
    floor for the one case the Script can actually tell apart from silence —
    an engagement it watched fail even after requirement 9e's salvage — without
    releasing the claim outright: it backdates the registry entry's `ts` so
    `gc` retires it on its very next sweep instead of waiting out the full TTL,
    which still bounds cost at "one attempt per sweep interval" rather than
    reopening the unbounded-retry failure this requirement exists to prevent.
    Two existing properties of `lib/claim.sh` make the
    pseudo-slug safe and are relied on here: `count` reads only the repo slugs
    `config.json` configures, so an Enabler claim can never inflate
    back-pressure (requirement 2.2) with work that raises no PR; and `gc` sweeps
    any directory it finds.
35d. **Refinement items are capped per engagement.** Before the claims of 35c,
    the eligible set is reduced to every ordinary blocked item plus at most
    `refinement_max_per_engagement` items of the refinement class, oldest block
    first — deterministically, so every node in the fleet reduces to the same set
    and they contend on the same claims rather than each engaging a different
    third of the backlog. Applied *before* claiming, because a claim taken and
    then not examined is a tombstone standing for `claim_ttl_hours` over an item
    nobody looked at.

    Ordinary blocked items are never displaced: they have no cap, and the
    refinement class cannot crowd them out. That asymmetry is the point. The
    backlog of items silently skipped before requirement 16a existed is
    unbounded and none of it is urgent, while the blocked items already in the
    queue include the pull request nobody can see (requirement 32a) — so an
    engagement that spent itself on old vagueness would make the pipeline slower
    at exactly the thing the Enabler exists for. Items over the cap are not lost:
    they are blocked, and they arrive at a later engagement.
36. **The Enabler's powers.** It may read anything through `gh` — issues, PRs,
    reviews, checks, runs, alerts, file contents — and reads an issue or PR as
    its **whole thread** (requirement 14a's rule, for the same reason and with
    more at stake: the material that decides these items is routinely a comment
    posted after the pipeline gave up). It may leave one concise decision or
    evidence comment on the item's issue or PR.

    It must **not**: write code, push, or create or delete a branch; create,
    close, reopen, label, assign or edit any issue or pull request — it composes
    the escalation issue and **the Script files it**, because the Script is the
    only writer of this system's records and an issue it did not create is one
    no later cycle can match against its own log; merge, approve, dismiss a
    review, or mark anything ready; touch a void item; or report `unblocked`
    because the work turned out to be already done — that is a `void`, and
    requirement 9b is the whole reason the two are different states.

    It runs under the one-shot constraint of requirement 21: no resumption, no
    background notification, slow commands waited out in the foreground.

    Its runtime input is the claimed eligible entries (each carrying `repo`,
    `item`, `reason`, `blocked_ts`, the blocking stage's own `stage`, `detail`
    and `unblock_condition`, the `pr_url` the blocking event named if it named
    one — under requirement 32a a pull request nobody could hand off is a blocked
    item like any other, and for a finishing source the item id names a register
    entry rather than the PR — the `kind` and `refined_before` of requirement
    35a, and the last `escalation` if there is one), plus
    `escalation_label`, `assignee`, and this cycle's `cycle` id and `node` — the
    last two because requirement 36a's issue footer carries them, and requirement
    3e's marker stamps the Enabler's own comments with the `cycle`, and a model
    cannot know its own cycle.

    Its entire final message is one JSON object:
    ```json
    {
      "examined": [
        {"repo": "…", "item": "…",
         "verdict": "unblocked" | "still-blocked" | "escalate" | "void",
         "reason": "…", "evidence": "…", "comments_posted": ["…"],
         "complete_handoff": false,
         "unblock_condition": "still-blocked only",
         "refined_spec": "refinement only, and only for a non-issue item",
         "issue": {"title": "…", "body": "…"}}
      ],
      "notes": "…"
    }
    ```
    with one entry per item it was given.
36a. **What the Script does with a verdict.** Per examined item, and only for
    items *this cycle claimed* — a verdict naming anything else is logged as a
    `warning` and ignored, since the model cannot introduce work and an item a
    peer holds is the peer's to answer:

    | Verdict | The Script does |
    |---|---|
    | `unblocked` | logs `unblocked` with `repo`, `by: "enabler"` and the reason; the item is selectable again next cycle. With `complete_handoff: true` and a `pr_url`, also completes the handoff through requirement 31a and logs `pr-ready` with `handoff: "enabler"` (requirement 32b), or a `warning` if the PR is still a draft. On a refinement item, also records `item-refined` and removes the projected label (requirement 36b) |
    | `void` | corroborated by requirement 34d's shared guard; on success logs `item-void` through requirement 33's shared field shape, carrying the model's reason and evidence, and removes the projected label of requirement 34e; on refusal logs `attempt-failed` and a `warning` instead, with outcome `void-refused` |
    | `still-blocked` | nothing beyond the examined event, which carries the refreshed `unblock_condition` |
    | `escalate` | files the issue (below) and logs `escalated`; on failure logs a `warning` and records the outcome `escalation-failed` |
    | any | logs `enabler-examined` with `repo`, `item`, `blocked_ts`, `outcome` and `detail` |

    The examined event is written for every verdict, including the ones that
    changed nothing: it is what stops the item being re-examined next cycle and
    what `enabler_recheck_hours` is measured from.

    **The issue contract.** Before filing, a duplicate guard: an open issue
    carrying `enabler_escalation_label` whose body already quotes the item's
    reference *is* the escalation and is reused. Otherwise `gh issue create` in
    the item's own repo with that label **and** `--assignee` set to
    `enabler_assignee`, retried once without the label so a repo where the
    label has not been created still gets its issue. The assignment is the
    load-bearing half: requirement 16.4
    excludes assigned issues from the `issues` source, so the pipeline can never
    select its own request for help as work. The label is for the human's filter
    and the guard above, and must not be `blocked` — that is a separate
    exclusion criterion and would blur two different meanings into one.

    **Closure is the whole protocol**, and the issue body says so: the human
    does the thing and closes the issue. Nothing else is required of them — no
    reply, no log edit, no re-run. The closure leaves the repo's open-issue
    digest, which busts the fingerprint (35b) and makes the item eligible again
    with reason `issue-closed`, and the next engagement verifies against reality
    rather than against the closure. That loop is the reason the ask must be
    executable without further investigation: an escalation a reader has to
    interpret has failed even where its verdict was right.
36b. **The refinement duty.** For an item carrying `kind: "needs-refinement"`
    (requirement 34e) the Enabler reads the item and its whole context and then:

    - **Specifies it**, where the work can be specified without deciding
      anything that belongs to a human — a missing acceptance criterion derivable
      from the code, a scope bound the repo's conventions already imply, a
      reproduction reconstructible from a failing run. The verdict is
      `unblocked`, and *where the refinement lands is decided by the item type*,
      because it has to land where a future Co-Ordinator will read it:
      - an **issue** item: **one** authoritative comment on the issue carrying
        the refined specification (goal, scope bounds, acceptance criteria,
        pointers to the relevant files and conventions), its URL returned in
        `comments_posted`. Requirements 14a and 20 already have the Co-Ordinator
        read the whole thread and paste it, so this needs no new carrier;
      - **any other item type**: the specification is returned in `refined_spec`
        as self-contained markdown, because there is no thread to write into and
        no actor here may edit the register. Requirement 3h is its carrier.
    - **Escalates**, where a human must decide, answer, or act first — through
      the unchanged protocol of requirement 36a, in a **separate** issue. Never
      the work item's own issue: that protocol ends with "close this issue when
      you are done", which on the item's own issue asks the human to close the
      work itself and removes it from the `issues` source. The ask is phrased so
      the human's answers land as comments on the escalation issue *before* they
      close it, since the closure is what returns the item to a later engagement
      and their comments are what let that engagement complete the refinement.
      Where the work item is itself an issue, the Enabler also posts one
      one-line comment on it linking to the escalation, so the context stays
      visible where the work lives.
    - **Leaves it blocked**, where the gating decision is recorded as
      deliberately parked — an open question with a decide-by gate in a roadmap
      or plan, or a thread saying the decision is intentionally deferred. The
      verdict is `still-blocked` with that as the `unblock_condition`. Escalating
      a decision the human has already chosen to defer asks them to re-make it,
      and spends the one resource this system exists to conserve.

    `void` and `still-blocked` keep their ordinary meanings and evidence bars.

    **The Script's side.** On an `unblocked` verdict for a refinement item it
    records `item-refined` (requirement 33) carrying the `refined_spec` and/or
    the first URL in `comments_posted`, alongside the ordinary unblock handling,
    and removes the projected label. A verdict carrying neither gets a `warning`:
    the block clears and the item returns to the pool exactly as under-specified
    as it was, which is the one outcome this path must not produce silently.

    **The thrash guard.** An item is refined at most once between human touches.
    Where `refined_before` is set, a second refinement is not the answer: two
    models disagreeing about whether a specification is adequate is a
    disagreement only a human can settle, and a third pass settles it only by
    coincidence. The prompt says so, and the Script enforces it — an `unblocked`
    verdict on a refinement item whose `refined_before` is set is **refused**,
    logged as a `warning`, and recorded with the outcome `refinement-refused`,
    leaving the item blocked. Mechanical for requirement 34d's reason: "do not
    do this" is already in the prompt, and the model that would do it anyway is
    one that has convinced itself.

    The single exception is the eligibility reason `issue-closed`, and it is
    what makes "per human touch" a rule the Script can check rather than a hope:
    that reason exists only because a human acted on an escalation about this
    very item (requirement 35a), so the refinement it authorises is the first
    since they did.
37. **Failure containment.** The Enabler must never change a cycle's outcome.
    A timeout, a non-zero exit, or an unparseable final message produces the
    stage's `stage-end`, a `warning`, and **no state events at all**: no
    verdict was reached, so nothing is recorded about any item, and gc is
    what allows the retry. The cycle's exit code is the one
    it had before the engagement, and every step of the engagement — each `gh`
    call, each parse — tolerates its own failure, because this code runs inside
    the exit trap where an unguarded non-zero status would cost the cycle its
    `cycle-end` event, its lock release and its state-sync push.

    An exit that leaves an unparseable final message gets requirement 9e's
    salvage attempt first — the engagement's own session, resumed once, asked
    for nothing but its verdicts — before this requirement's silence takes
    over; a timeout or non-zero exit has no session to resume and goes
    straight to it. Only once that also comes up empty does the `warning` name
    every item that was in this engagement (`items: [{repo, item}, …]`), so a
    human reading the log can see what was lost without cross-referencing the
    claim registry, and each of those items' 35c tombstone is backdated with
    `lib/claim.sh expire` rather than left to age out at the full
    `claim_ttl_hours` — `gc` (requirement 2.1a, every cycle) retires it on its
    very next sweep instead. This is deliberately not a release: 35c's own
    design-decision note already explains why releasing a failed engagement's
    claim outright would let the very next cycle re-engage the same
    still-unchanged items at Opus prices for nothing, and `expire` keeps that
    bound while shortening the tombstone's floor from `claim_ttl_hours` to
    about one cycle interval.

    A usage-limit phrase in the transcript still goes down requirement 10's
    ordinary path (`limit-hit`, `fleet/limit.json`), because a limit belongs to
    the whole fleet and not to this stage. A claimed item the model never
    mentions, and a verdict the Script does not recognise, are `warning`s: the
    item stays blocked and the log is the only place a stage that routinely
    omits items would ever become visible.

38. **Human-visibility.** Work genuinely waiting on the human must be visible
    to the human — on `github.com/pulls/review-requested` for a pull request,
    on Assigned-to-me for an issue — not merely recorded in the pipeline's own
    log. A 2026-08-07 pipeline-flow review found neither guarantee held: no
    currently-open pull request carried a live review request (every prior
    request had been consumed by a submitted review), and the one genuine
    human-decision block in this repository (#203) was unassigned, so it never
    appeared on Assigned-to-me either.

38a. **A ready pull request's live review request is kept, not only made
    once.** `lib/handoff.sh`'s `ensure_human_reviewer(pr_url, assignee)`
    covers the case `confirm_review_requested` (requirement 31b) does not:
    nobody's `CHANGES_REQUESTED` is blocking the pull request, so there is no
    blocking reviewer to re-request from, and yet the human may still not have
    been *asked* — a first review nobody has given, or an approval nobody has
    acted on since (poetic-fiddle #170: approved, green, and idle 6.8 days,
    because CODEOWNERS' request is consumed the moment the review is
    submitted and nothing asks again). Requesting review from someone who has
    already approved withdraws nothing they said; it only puts the pull
    request back in the one queue a human actually watches.

    The target is whoever has ever reviewed the pull request, in any state
    (`_handoff_known_reviewers`), before it is ever `assignee`
    (`enabler_assignee`). That order is load-bearing, not stylistic: this
    system's own pull requests are authored under the same account
    `enabler_assignee` routinely names — issue assignment has no such
    conflict, pull-request review does — and GitHub refuses a review request
    aimed at a pull request's own author with a 422. CODEOWNERS already solved
    that once, automatically, the moment the pull request went ready; reading
    who it already picked is both correct and one API call. `assignee` is the
    fallback for a pull request CODEOWNERS never touched at all.

    The author is struck off the candidates whichever list proposed them,
    before anything is asked, and a request left with no candidate is a `skip`
    rather than an attempt: a 422 is not a transient failure worth a `warning`
    every cycle, it is a fact about the configuration that will not change
    tomorrow, and one invalid login fails the whole POST rather than its own
    entry — so an unfiltered author would take the real reviewer down with it.
    The filter applies to the reviews list too, not only to `assignee`:
    GitHub closes `APPROVE` and `REQUEST_CHANGES` to a pull request's author
    but leaves `COMMENT` open to them, and a Reviewer's own findings may be
    filed that way — `prompts/reviewer.md` offers `gh pr review --comment` for
    them — under the account that raised the pull request.

    Called from both places `confirm_review_requested` already is — the
    Reviewer's own handoff and the Enabler's `complete_handoff` — whenever
    that call answers `none`, and from the periodic sweep of requirement 38c
    below, so the guarantee holds whether or not any stage touches the pull
    request in a given cycle. A `failed` result is a `warning` on the
    `pr-ready` event, on the same terms requirement 31b's own re-request
    failure is: the pull request is finished and visible, only a notification
    is missing.

38b. **A Co-Ordinator-recorded block gated on a human decision is assigned,
    not only labelled.** Requirement 34e projects the `needs-refinement` label
    onto the issue behind a `needs_refinement` report, but a label matches
    nothing on Assigned-to-me — agent-ops#203 was exactly this shape (labelled
    correctly, invisible regardless) until fixed by hand. `lib/refinement.sh`'s
    `refinement_assignee_add`/`refinement_assignee_remove` mirror the label's
    lifecycle: `log_needs_refinement_items` assigns `enabler_assignee`
    to the issue alongside the label, recording it as
    `needs_refinement_assignee` on the block's `attempt-failed` event (mirrored
    by `refinement_block_fields`'s third argument) so `release_refinement_label`
    can take the assignment off again — via `refinement_assignee_targets`, read
    from the block record exactly as `refinement_label_targets` is — the moment
    the block clears, by the same three paths that already release the label.
    Best-effort, like the label: a failed assignment is a `warning`, and the
    block is recorded regardless.

    The mirror stops one step short of the label's, on purpose. The
    assignment goes on through `refinement_assignee_project`, which reads the
    issue's assignees before writing: an assignment already there — the
    human's own, made for their own reasons before the block existed — is
    left exactly as found and recorded as nothing, because `gh issue edit
    --add-assignee` succeeds as a no-op on an assigned issue, and an
    assignment recorded off the back of that no-op would be *removed* when
    the block cleared — a false removal from the very list this requirement
    exists to keep accurate, silently and by the pipeline's hand. The label
    keeps its unconditional lifecycle and the asymmetry is deliberate:
    `needs-refinement` is this system's own vocabulary, convergent with block
    state by design (a hand-applied instance is itself read back as a report,
    requirement 34g), where an assignment is a general-purpose signal the
    projection only borrows. An unreadable assignee list assigns best-effort
    but records nothing, with a `warning` saying so — over-holding an
    assignment is cosmetic; removing one that may have pre-existed is the
    defect the read exists to prevent.

38c. **An idle, approved pull request is nudged, not left silent.** For every
    open, non-draft, `pr_label`-carrying pull request in every configured
    repository — fleet-wide, like the sweeps of requirements 17b and 34i,
    regardless of `--repo` — `scripts/sweep-human-visibility.sh` runs once per
    cycle and, per pull request:

    - where nothing is `CHANGES_REQUESTED`-blocking it, ensures
      `ensure_human_reviewer` (requirement 38a, kept continuously rather than
      only at the moment of handoff);
    - where the pull request is `APPROVED`, `MERGEABLE`, every check
      genuinely green (an empty `statusCheckRollup` is excluded explicitly —
      that is CI not having run, not CI having passed), and has been since
      before `human_nudge_idle_hours` ago, posts one nudge comment naming
      `enabler_assignee` — unless one is already there, which a
      `<!-- agent-ops:human-nudge -->` marker comment makes idempotent rather
      than merely time-windowed. `human_nudge_idle_hours` of `0` disables the
      nudge only; the review-request self-heal above is unconditional.

    This *is* the periodic, deterministic audit of requirement 38's own
    guarantee, made self-healing rather than merely reported: a violation this
    script can fix, it fixes in the same pass, so there is never a gap between
    detection and correction for a human to fall through. What it cannot fix —
    a listing or a read that fails — is a `warning`, never a silent skip.
    Skipped on `--dry-run`, like every sweep that writes.

    A pull request something is still `CHANGES_REQUESTED`-blocking is left
    entirely alone — the sweep never calls `confirm_review_requested`
    (requirement 31b), and the omission is deliberate. That function's
    contract assumes the judgement "these changes answer the review", which
    only the Reviewer's `ready` verdict supplies (requirement 31b's one call
    site), and the sweep has none to offer: re-requesting without it inverts
    the queue — the human is asked to re-look at a pull request whose next
    actor is the pipeline — and, because requirement 3c's candidate rule
    reads a review-requested timeline event as the round having been
    *answered* (`scripts/gather-review-feedback.sh`, the
    events-not-timestamps fix), it would also drop the pull request out of
    the Implementor's own review-feedback selection while the human's
    `CHANGES_REQUESTED` sat unanswered — PR #205's silent-starvation failure
    reintroduced hourly and fleet-wide. The case this leaves unhealed (a
    `ready`-verdict re-request lost to a crash between the push and the
    request) is recorded as deferred work in
    `tech-debt/TD-PPagop-26080804.md`: healing it correctly needs
    requirement 3c's answered-from-events predicate shared out of its
    script, so the sweep can tell an answered round from an unanswered one.

    The Script logs what the sweep did under the sweep's own event names —
    `human-review-requested` and `human-nudged`, each
    carrying the `repo` swept and the `pr_url` acted on — exactly as
    requirement 17b's sweep logs `orphan-branch-recovered` /
    `orphan-branch-released`, and deliberately not as `pr-ready`. A sweep
    action is not a handoff: the Publisher's outcome ladder
    (`docs/DASHBOARD-SPEC.md`) reads a `pr-ready` anywhere in a cycle as "this
    cycle got a pull request to ready" and ranks it above every other reading,
    so a `pr-ready` logged for a re-request on some other repository's
    long-since-ready pull request would rewrite the recorded outcome of a cycle
    that stood down or selected nothing.

38d. **Scope note.** Requirement 38 does not extend the same guarantee to
    every conceivable class of human-blocked work — an `escalate` verdict
    (requirement 36a) was already assigned and labelled before this
    requirement existed, and remains the canonical path for a decision only a
    human can make. What requirements 38a–38c add is continuity (the guarantee
    holds between the moments a model-driven stage would otherwise renew it)
    and one further origin (a Co-Ordinator's own `needs_refinement` report)
    that previously reached only a label. Nor does a violation the sweep cannot
    itself heal become selectable work: it is a `warning` and no more, which is
    the gap `tech-debt/TD-PPagop-26080801.md` records.

## Components

What exists, and the requirements each part answers to:

1. `config.json` with the values above.
2. `agent-cycle.sh` implementing requirements 1–13 (including the findings
   pre-fetch, requirement 3a; the switches, requirements 2.3 and 2.3a; the
   role guard, requirement 2.4; the no-op short-circuit, requirement 3b; and
   the implementation-plan path passthrough and its startup validation,
   requirement 3k) and the Enabler's engagement, requirements 35–37:
   `maybe_run_enabler` (the single call site in the cleanup, every guard, and
   the per-verdict actions), `enabler_claim_key` and `create_escalation_issue`.
3. `scripts/gather-findings.sh` implementing requirement 3a: given a repo
   slug, prints a normalised JSON array of the repo's open Dependabot and
   code-scanning alerts, degrading to `[]` (exit 0) when a feature is
   disabled or inaccessible. Must pass `shellcheck`.
3c. `scripts/gather-review-feedback.sh` implementing requirement 3c: given a
   repo slug, PR label and branch prefix, prints the JSON array of PRs awaiting
   our reply to a human's review, each carrying every review body and inline
   comment in the round verbatim. Fails safe to `[]` (exit 0). Must pass
   `shellcheck`.
3f. `scripts/gather-abandoned-drafts.sh` implementing requirement 3e: given a
   repo slug, PR label, branch prefix and staleness threshold, prints the JSON
   array of this system's own abandoned draft PRs (open, draft, ours, whose last
   real activity — commits, and the reviews and comments not carrying
   `lib/pipeline-marker.sh`'s marker — is untouched past the threshold), each
   carrying the draft PR's body verbatim and a head-SHA-scoped ref. A PR any of
   whose nested collections `gh pr list` returned at its 100-item cap is
   excluded for the cycle rather than judged on possibly-incomplete activity
   (requirement 3e). Its
   candidate rule is regression-tested in `test/abandoned-drafts.test.sh`. Fails
   safe to `[]` (exit 0). Must pass `shellcheck`. Sources
   `lib/pipeline-marker.sh`, which implements the write side of the same
   requirement and, together with it, requirement 9d's visible attribution:
   `PIPELINE_COMMENT_MARKER_PREFIX`, the fixed substring this script matches
   on; `pipeline_comment_marker CYCLE_ID ACTOR`, which every pipeline-authored
   PR or issue comment is stamped with; `pipeline_actor_label TOKEN`, the Actor
   token→display map, failing open on an unknown token; and
   `pipeline_comment_header ACTOR NODE`, the leading visible line every such
   comment opens with. `agent-cycle.sh`'s and `review-cycle.sh`'s own comments
   call these directly; the Implementor's, Enabler's and Reviewer's comment
   instructions (`prompts/implementor.md`, `prompts/enabler.md`,
   `prompts/reviewer.md`) spell both the header and the marker out literally,
   via the cycle id and node name each receives at invocation. One definition
   (requirement 34a): the reader and every writer that is a shell source this
   file, and the three prompts — which a model reads, so they must spell both
   forms out — are asserted against `PIPELINE_COMMENT_MARKER_PREFIX` by
   `test/abandoned-drafts.test.sh` and against the header's literal form by
   `test/comment-identity.test.sh`, so neither can drift between any of them.
3g. `scripts/gather-merge-conflicts.sh` implementing requirement 3g: given a
   repo slug, PR label and branch prefix, prints the JSON array of this system's
   own ready-but-conflicted PRs (open, non-draft, ours, `mergeable` definitively
   `CONFLICTING`), each carrying the PR's body verbatim, its base, and a
   head-SHA-scoped ref. Fails safe to `[]` (exit 0). Must pass `shellcheck`.
3i. `scripts/gather-register-hygiene.sh` implementing requirement 3i: given a
   repo slug, default branch and (requirement 34l) an optional JSON array of
   this repo's void register-shaped candidates, prints a JSON array holding
   at most one candidate — the repo's per-item tech-debt register, when
   `scripts/td-check.pl` says it disagrees with itself, or when a named void
   candidate's file still carries `status: open`/`in-progress` (the
   `VOIDED STATUS` problem class, this script's own, layered on top of and
   never fed back into `td-check.pl`) — carrying a ref scoped to the
   register's identity (a digest of the `tech-debt/` tree SHA and the policy
   blob SHA), the register's URL, the `tech-debt/` tree SHA as the blob SHA,
   the problem lines (both classes combined), and a body holding the
   checker's output verbatim plus a section naming each `VOIDED STATUS`
   item's void evidence. A repo with no `tech-debt` tree prints `[]`
   silently; an API failure prints `[]` with `gh`'s diagnosis on stderr.
   Fails safe to `[]` (exit 0).
   Its candidate rule is regression-tested in `test/register-hygiene.test.sh`;
   must pass `shellcheck`. `scripts/td-check.pl` is a byte-identical copy of
   the canonical script in `Poetic-Poems/poetic`, held here (as this
   repository does not framework-sync) and guarded by
   `.github/workflows/td-tooling-drift.yml`.
   `.github/workflows/tech-debt-register.yml` runs the check (argless) on this
   repository's own register on every pull request, the deterministic layer
   that keeps this source's volume near zero.
3j. `scripts/gather-issues.sh` implementing requirement 3j: given a repo slug,
   prints the JSON array of the repo's candidate issues — open, unassigned,
   not labelled `blocked`, naming no unresolved `Blocked-by:` reference
   (requirement 34j, each reference's state checked live once the
   candidate's whole thread is in hand), pull requests dropped — each
   carrying the bare issue number as its ref, the `Priority` band (default
   `Medium`, read as the source-state digest reads it), and the whole thread
   verbatim (`body` plus `comments`). Fails safe to `[]` (exit 0) with
   failures loud on stderr. Its filter and shape are regression-tested in
   `test/issues-prefetch.test.sh` and `test/dependency-gate.test.sh`; must
   pass `shellcheck`.
3q. `lib/dependency-gate.sh` implementing requirement 34j: `dependency_refs`,
   which parses every `Blocked-by:` reference out of a body of text into a
   normalized JSON array (same-repo references as a bare number, cross-repo
   as `owner/repo#N`), and `dependency_clearances`, which given the open
   blocked set and this cycle's own reshaped `issues` candidates prints the
   blocked issues whose dependencies are proven resolved by their presence
   there — pure, reading nothing itself. Both are shared by
   `scripts/gather-issues.sh` (the holding half) and `agent-cycle.sh` (the
   releasing half, in the same pre-extract window as requirement 34i).
   Unit-tested (`test/dependency-gate.test.sh`); must pass `shellcheck`.
3k. `scripts/gather-register-status.sh` implementing requirement 34i's register
   half: given a repo slug, default branch and item ids, prints a JSON object
   mapping each id to the `status` its own item file declares on that branch.
   An id resolves only when exactly one file claims it by `id` or `legacy-id`
   — the filename is a shortlist, never the answer — and everything short of
   that certainty is absent from the output, which the caller reads as "not
   known to be gone". A repo with no `tech-debt` tree prints `{}` silently; an
   API failure prints `{}` with `gh`'s diagnosis on stderr. Called once per
   repo that has blocked register items and not at all otherwise, so it is
   bounded by the backlog rather than by the register. Fails safe to `{}` (exit
   0); regression-tested in `test/work-gone.test.sh`; must pass `shellcheck`.
3o. `scripts/gather-review-status.sh` implementing requirement 34i's
   project-review half: given a repo slug, default branch and recommendation
   refs, prints a JSON object mapping each ref a merged pull request's title
   or body names to `"merged"`, searched over the repo's 100
   most-recently-closed pull requests targeting that branch. Called once per
   repo that has blocked project-review items and not at all otherwise. Fails
   safe to `{}` (exit 0); regression-tested in `test/work-gone.test.sh`; must
   pass `shellcheck`.
3p. `scripts/gather-plan-status.sh` implementing requirement 34i's
   implementation-plan half: given a repo slug, default branch,
   `implementation_plan_path` and task ids, prints a JSON object mapping each
   id to `"done"` or `"open"`, read off that task's own checkbox
   (`- [ ]`/`- [x]`) in the document. An id resolves only when exactly one
   task-list line names it as a whole word; two such lines, or none, are
   absent from the output. Called once per repo that has blocked plan-task
   items and an `implementation_plan_path` configured, and not at all
   otherwise. Fails safe to `{}` (exit 0); regression-tested in
   `test/work-gone.test.sh`; must pass `shellcheck`.
3b. `scripts/gather-source-state.sh` implementing requirement 3b's sampling:
   given a repo slug and default branch, prints one JSON object holding that
   repo's head SHA and its issues, workflows and open-PR digests, with `ok:
   false` if any of it could not be fetched cleanly. The issues digest carries
   each issue's `Priority` band (requirement 15e), resolved the same way the
   Co-Ordinator resolves it — unset or unrecognised reads as `Medium` — so a
   re-prioritised issue busts the fingerprint and a missing field does not.
   Never exits non-zero — a
   cost-control feature must not become a reliability risk — but must not
   pretend a failed call is an empty result either (see requirement 3b). Must
   pass `shellcheck`.
3d. `scripts/state-sync.sh` implementing requirement 2.5: `push` and `fetch`.
   Called by both pipelines (the push from the cleanup that ends a cycle) and
   by the container crontab (the every-few-minutes push and the fetch).
   Every mode is a no-op when `state_repo` is unset. Needs `rsync`, `git`
   (and `tar` for the fetch), and degrades to a warning and exit 0 when one
   is missing, because a node that cannot replicate is still a node that can
   run. Unit-tested against a local bare repository
   (`test/state-sync.test.sh`); must pass `shellcheck`.
3i. `scripts/rotate-logs.sh` implementing requirement 2.6: rotates
   `dashboard.log`, `state-sync.log`, `cron.log` and `review-cron.log` by
   size, leaving `log.jsonl` and `review-log.jsonl` untouched. Called by its
   own container crontab line, independent of both pipelines. Unit-tested
   against a synthesised `state_dir` (`test/rotate-logs.test.sh`); must pass
   `shellcheck`.
3e. `lib/claim.sh` implementing requirement 17a: `claim` (kinds `branch` and
   `file`), `release`, `count` and `gc`, exit codes 0 won/done, 3 lost, 1
   error; requirement 3o's `claims` and `branches` — read-only listings
   that always print a JSON array (empty on any read failure) and exit 0,
   since a claim-visibility gather must never fail a cycle over one listing
   coming up short; and requirement 37's `expire <target-slug> <key>` —
   backdates a registry entry's `ts` to a fixed date long past any realistic
   `claim_ttl_hours`, carrying every other field over unchanged, so `gc`
   retires it on its very next sweep rather than releasing it. A silent
   no-op when the entry cannot be read or `state_repo` is unset, on the same
   reasoning as the read-only listings — an annotation is advisory, like the
   registry it targets. Called by `agent-cycle.sh` (the claim loop after
   selection, the release hooks on every no-PR ending, the `count` inside
   back-pressure, `claims`/`branches` once per repo ahead of the
   Co-Ordinator, and `expire` from `maybe_run_enabler`'s discard path).
   `CLAIM_GH` substitutes a stub for tests, following
   `STATE_SYNC_GH`. Unit-tested with concurrent-claim races against a
   filesystem-CAS stub (`test/claim.test.sh`); must pass `shellcheck`.
3h. `lib/refinement.sh` implementing the refinement class: requirement 16a's
   well-formedness bar for a `needs_refinement` entry, requirement 34e's block
   fields and label projection and requirement 38b's assignment projection
   beside it (`REFINEMENT_GH` substitutes a stub for tests,
   following `CLAIM_GH`), requirement 35d's per-engagement cap, and requirement
   36b's `item-refined` payload and thrash guard. Sourced after
   `lib/void-guard.sh`, whose `entry_field_text` it shares rather than keeping a
   second opinion about what counts as a filled-in field (requirement 34a).
   Unit-tested (`test/needs-refinement.test.sh`); must pass `shellcheck`.
3m. `lib/work-gone.sh` implementing requirement 34i's decision:
   `work_gone_clearances`, which given the open blocked set, the cycle's
   source-state digests and the register, review and plan status maps prints
   one entry per block whose work no longer exists, and
   `work_gone_register_ids`, `work_gone_review_refs` and `work_gone_plan_ids`,
   which each name the blocked ids shaped like their class so the matching read
   above is asked for those and no others. Pure — it reads nothing itself — and
   every unknown resolves to no clearance. Unit-tested (`test/work-gone.test.sh`);
   must pass `shellcheck`.
3n. `scripts/sweep-orphan-branches.sh` implementing requirement 17b's sweep:
   given a repo slug, examines every `td/*` and `<branch_prefix>*` ref and
   prints one JSON action object per orphan handled (`recovered`, `released`,
   `deferred`, `warning`) for the Script to log. Fail-closed on every
   unanswered question; `SWEEP_GH` stubs `gh` and `AGENT_OPS_CONFIG`
   overrides the config for tests. Unit-tested
   (`test/sweep-orphan-branches.test.sh`); must pass `shellcheck`.
3r. `scripts/sweep-human-visibility.sh` implementing requirement 38c's sweep:
   given a repo slug (and, for the nudge comment's header and marker, a cycle
   id and a node name), examines every open, non-draft, `pr_label`-carrying
   pull request and prints one JSON action object per pull request it acted on
   (`human-review-requested`, `nudged`, `warning`) for the
   Script to log under those same names. Fail-safe on every unanswered
   question — a read it cannot make is a `warning`, never an assumed clean
   answer; `SWEEP_GH` stubs `gh` (and is passed through as `HANDOFF_GH`, since
   the sweep's decisions are `lib/handoff.sh`'s) and `AGENT_OPS_CONFIG`
   overrides the config for tests. Unit-tested
   (`test/sweep-human-visibility.test.sh`); must pass `shellcheck`.
3a. The shared library (`lib/cycle-state.sh`, `lib/limit-detect.sh`,
   `lib/toggle.sh`, `lib/noop-skip.sh`, `lib/role.sh`, `lib/void-guard.sh`,
   `lib/refinement.sh`, `lib/work-gone.sh`, `lib/model-id.sh`,
   `lib/crash-loop.sh` (requirement 2.7's `crash_loop_verdict` and
   `crash_loop_escalated_since`, both pure readers of the union stream),
   `lib/handoff.sh` (requirement 31a's `confirm_pr_ready`, shared with
   requirement 32b; requirement 31b's `confirm_review_requested`, the same
   promise for the round after the first; requirement 38a's
   `ensure_human_reviewer`, the same promise again where nobody's review is
   blocking at all; and requirement 9's
   `pr_url_for_branch`, which names the pull request on a claimed branch when
   the stage that opened it named nothing; `HANDOFF_GH` substitutes a stub for
   tests),
   `lib/stage-run.sh` (requirement 4d's `run_claude_stage`, the one stage
   launcher both pipelines call, with `stage_stream_file` and
   `stage_result_line` naming and reading the stream it writes, and
   `stage_gap_stats` summarising the inter-event gaps it measures from that
   stream for requirement 33a, and `stage_rejected_rate_limit` reading the
   refusal that stops a stage on the spot),
   `lib/stage-budget.sh` (requirement 4f's derivation:
   `stage_budget_observations` over the log union, `stage_budget_table`
   holding the estimator, the controller and the shrinkage,
   `stage_budget_resolve` applying the precedence, and
   `stage_budget_lock_seconds` deriving the lock; sourced by both cycle
   scripts, by `scripts/doctor.sh` and by the dashboard publisher, all four of
   which must agree about what a stage is allowed) and
   `lib/metering.sh`) holding every
   rule that more than one component computes — at minimum requirement 34's blocked
   semantics, requirement 35a's eligibility rule (the Script engages on it, the
   dashboard reports what came of it), requirement 3h's refinement
   carry-forward, requirement 33's `attempt-failed` field shape, requirement
   33a's per-stage metering record (`lib/metering.sh`'s `metering_fields`,
   sourced by `agent-cycle.sh` and `review-cycle.sh` so a stage in either
   pipeline emits the same shape; `docs/METERING-SCHEMA.md` is the contract;
   unit-tested in `test/metering.test.sh`), the usage-limit
   phrase pattern of requirement 10, the switch of requirement 2.3 and the
   fleet flags of requirements 2.3a and 2.1 (`lib/toggle.sh`'s `fleet_*`
   functions; `TOGGLE_GH` substitutes a stub for tests, following
   `CLAIM_GH`), the role guard of requirement 2.4 (read
   by both pipelines), the fingerprint rule of requirement 3b and the
   provider-qualified model id resolution of requirement 1a
   (`lib/model-id.sh`'s `resolve_model_id`) — sourced by `agent-cycle.sh`,
   `review-cycle.sh` and the dashboard's publisher rather than copied into
   any of them. Unit-tested directly (`test/*.test.sh`, plain bash assertions, no
   framework) and `shellcheck`-clean. These rules are the system's memory of
   what it has already tried; a second copy of one is a bug with a delay
   fuse, and both copies read correctly right up until they disagree.
3l. `lib/repo-order.sh` implementing requirement 3's two pure functions:
   `repo_order_by_effective_age`, given the cycle's now-epoch and the repos
   array, reorders the Script's timestamp lines most-overdue-first by
   nice-weighted effective age, ordering identically to a plain
   least-recently-updated-first sort when every repo's `nice` is `0` or
   absent; and `repo_nice_selection_config`, the fingerprint producer's
   half, which distils the same repos array into the `selection_config`
   contribution — `{repo_nice: …}` carrying the non-zero entries only,
   floor-normalised, or `{}` when there are none, so a neutral config adds
   no key at all (the canon hashes `selection_config` wholesale, and an
   empty map is not the same bytes as an omitted key). Sourced by
   `agent-cycle.sh` only. Unit-tested (`test/repo-order.test.sh`); must
   pass `shellcheck`.
4. `prompts/coordinator.md`, `prompts/implementor.md`, `prompts/reviewer.md`
   and `prompts/enabler.md` implementing requirements 14–20, 21–27, 28–32 and
   36/36b respectively. Each prompt must embed the relevant shared-repo conventions
   from this document so a stage never depends on context it wasn't given. The
   Enabler's additionally carries the escalation issue's template, since the
   quality of that issue is the whole of requirement 36a's ask of a human.
4a. `lib/prompt-overrides.sh` implementing requirement 4a: `stage_prompt_text`
   (the assembled prompt for a stage, honouring `config.json`'s
   `prompt_overrides.<stage>.extend`/`.replace`) and `stage_prompt_sha` (the
   same assembly's contribution to the no-op fingerprint, requirements 3b and
   35b). Sourced by `agent-cycle.sh` only — `review-cycle.sh` runs its own
   `prompts/project-reviewer.md` outside this mechanism. Byte-identical to
   `cat prompts/<stage>.md` with nothing configured; unit-tested
   (`test/prompt-overrides.test.sh`) for that no-op case, for `extend`
   ordering and its disclaimer wrapper, for `replace` (including falling back
   to the shipped prompt when the configured file is unreadable), and for
   every one of those changing `stage_prompt_sha`; must pass `shellcheck`.
4b. `lib/coordinator-brief.sh` implementing requirement 4b:
   `coordinator_work_sources_table`, given `config.json`'s `repos` array,
   renders the Markdown table naming each repo and its numbered `sources`
   that `agent-cycle.sh` substitutes into the Co-Ordinator's assembled
   prompt in place of its `@@WORK_SOURCES_TABLE@@` marker. Sourced by
   `agent-cycle.sh` only. Unit-tested (`test/coordinator-brief.test.sh`) for
   the row-per-repo shape, in-order numbering, an input reordered from
   `config.json`'s own order, and the empty-array edge case; must pass
   `shellcheck`.
5. `README.md`: what the system does, every config key, install steps
   (below), how to operate it (`--dry-run`, `--once`, reading the log and
   stage transcripts), and how to uninstall. It presents the container as the
   way a node runs and points at the runbook for the detail; the host install
   and the WSL SysV dashboard service remain documented as the laptop's legacy
   path, which must keep working until it is cut over.
6. The crontab line, e.g.
   `0 * * * * $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh >> $HOME/.local/state/poetic-agents/cron.log 2>&1`,
   with `AGENT_OPS_ROLE=active` set in the crontab's environment on the node
   that is to run the cycles (requirement 2.4).
7. `deploy/docker/` — the node image and the node stack (see "The node image"
   and "The node stack" above): `Dockerfile`, `entrypoint.sh`, `crontab` and the
   minimal `claude-settings.json` seed; `compose.yaml`, `ts-serve.json`,
   `watchtower-pre-update.sh` (the hook that makes a roll wait for a running
   cycle) and `.env.example`; and the node runbook `deploy/docker/README.md` with the
   unattended `cloud-init.yaml` that performs its first three steps. The
   runbook is the operator-facing counterpart to those two sections: bring-up,
   everyday commands, updating, changing a node's role, the failover drill and
   a symptom-to-cause table. The container crontab is the schedule component 6 describes,
   expressed for a node; both exist because the laptop still runs the host-cron
   path.
8. `deploy/agent-ops-dashboard.init` and `deploy/tailscaled.init` — the legacy
   WSL SysV path for the laptop, superseded on a containerised node.
9. `.github/workflows/build-image.yml` — the build-and-publish path for
   component 7's image: build, verify the toolchain, validate the crontab, run
   the `test/` suite inside the image, and check the role guard; then publish
   to GHCR on `main` only. It carries `packages: write` and authenticates as
   the workflow's own `GITHUB_TOKEN`, so nothing about publishing depends on a
   human's credentials. Its `changes` job decides whether there is an image
   worth building at all, through `scripts/is-docs-only.sh` — the allowlist of
   paths the image is not the delivery path for (requirement 1b-i). The rule lives in
   the script rather than in the workflow for the reason component 10 gives
   about its own file set, and because a rule that decides what reaches a node
   is worth unit-testing.
10. `scripts/lint-shell.sh` and `.github/workflows/shellcheck.yml` — the
    shell linter and the job that enforces it (acceptance check 1g). The file
    set and the invocation live in the script, so a developer's run and CI's
    are the same run; the workflow's job is to install a **pinned** shellcheck
    (version and tarball checksum, both in the workflow) and call it. The pin
    is the point: the runner image's own version moves without notice, and a
    linter that gains a check overnight fails pull requests that changed
    nothing. Component 9 runs the test suite, which only ever reads the scripts
    it calls; this reads all of them. `deploy/docker/Dockerfile` (component 7)
    installs the same pinned release — the amd64 checksum byte-identical to
    this workflow's — so an Implementor working inside the node image can run
    `scripts/lint-shell.sh` itself before pushing, rather than pushing blind
    and finding out from this workflow (requirement 1b).
11. `scripts/watch-node.sh` — a read-only wrapper around
    `docker compose exec -T scheduler tail` for watching a node's `cron.log`
    or cycle log (`log.jsonl`, requirement 33) from outside, in place of the
    docker-exec incantation. Resolves the stack directory from `STACK_DIR` or
    the working directory, and refuses to run against one with no
    `compose.yaml`. Fetched alongside `compose.yaml` during bring-up
    (component 7, including `cloud-init.yaml`) so every node carries it from
    the start. Unit-tested against a stubbed `docker` on `PATH`
    (`test/watch-node.test.sh`); must pass `shellcheck`.
12. `scripts/check-node-compose.sh` — the host-side half of the compose-drift
    answer (see "The node stack"; the in-container half is
    `lib/compose-drift.sh`). Run on a node's host from the stack directory
    (or `STACK_DIR`; a host running two stacks, once per directory), it
    verifies what no container can: the stack's `compose.yaml` against the
    copy inside the *running* image, the mount that arms the in-container
    check, the watchtower pre-update hook label on every running agent-ops
    container, and watchtower's actual environment — lifecycle hooks
    enabled, schedule and interval not both set — plus an advisory count of
    lifecycle mentions in watchtower's log. Read-only throughout
    (`docker compose exec/ps`, `docker inspect/logs`, `diff`), so it is safe
    to allow-list like `watch-node.sh`. Exit 0 all checks passed, 1 at least
    one failed, 2 unable to check — and unable is never reported as clean.
    Fetched at bring-up beside `compose.yaml` (component 7, including
    `cloud-init.yaml`). Unit-tested against a stubbed `docker` on `PATH`
    (`test/check-node-compose.test.sh`); must pass `shellcheck`.
12a. `scripts/check-node-image.sh` — asks whether this node is running the
    newest image the repository has published (see "The node stack"; the
    library is `lib/image-drift.sh`). Rather than a second, host-side
    registry client, it runs the check inside the scheduler container over
    its stdin (`docker compose exec -T scheduler bash <<INNER`, following
    #154's stdin-not-argv fix at a smaller scale) — the container carries
    the toolchain and the node's own `build-info.json`, neither of which the
    host is assumed to have. An empty cache path is passed, so the answer is
    always this instant's, never `scripts/state-sync.sh` or
    `scripts/publish-dashboard.sh`'s last cached one. Exit 0 current, or
    behind by less than `config.json`'s `image_behind_grace_hours`
    (read from inside the container, the same value the dashboard badge
    uses), 1 behind past it, 2 unable to check — a registry the container
    could not reach, or no `compose.yaml` in the stack directory. Fetched at
    bring-up beside `compose.yaml` (component 7). Unit-tested against a
    stubbed `docker` on `PATH` (`test/check-node-image.test.sh`); must pass
    `shellcheck`.
13. `scripts/preview-deploy.sh` implementing requirement 24a: given a
    repository and a pull request — or, with no arguments at all, the pull
    request for the branch checked out in the working directory, which is how a
    stage runs it from its own clone — it resolves the Preview deployment
    GitHub recorded for that head SHA, reports whether it built, and fetches the
    deployed page past Vercel Authentication with
    `VERCEL_AUTOMATION_BYPASS_SECRET`. `--wait` polls while a deployment is
    still building; `--path` requests a route other than `/`. Exit 0 deployed
    and answering, 1 the deployment failed or the page does not answer, 2 could
    not check — which is what a protected, absent or still-building preview
    gets, so a login page is never reported as a healthy deployment.
    `VERCEL_TOKEN`, when set, adds the tail of the build log to a failure;
    without it a failure names the deployment's inspector URL instead. Its
    verdicts are regression-tested against a stubbed `gh` and `curl`
    (`test/preview-deploy.test.sh`); must pass `shellcheck`.
14. `config.schema.json`, `lib/config-schema.sh` and `scripts/doctor.sh`
    implementing requirement 1b. The schema states the shape of `config.json`;
    the library validates a config against it (the JSON Schema subset the
    schema uses: `type`, `enum`, `const`, `minimum`, `maximum`,
    `exclusiveMinimum`, `exclusiveMaximum`, `minLength`, `pattern`,
    `minItems`, `uniqueItems`, `properties`, `required`,
    `additionalProperties: false`, `items`, and local `$ref`s into `$defs`),
    returning 0 valid, 1 invalid with one message per offending path, and 2
    when a file is missing or will not parse — a config that is not there is
    not the same finding as one that is wrong. `agent-cycle.sh` and
    `review-cycle.sh` call this same function as their startup gate, so it is
    the one implementation both the Script's refusal and `doctor.sh`'s
    `fail` read from. The library also holds `config_defaults`, requirement
    1b's merge of a config with the schema's `default`s, which is where every
    reader of `config.json` takes its fallback values; and
    `config_enabler_assignee_ok` and
    `config_missing_plan_path_repos`, the two cross-key rules the schema
    itself cannot state — each holds *between* two keys — shared the same
    way, so `agent-cycle.sh`'s startup refusal and `doctor.sh`'s `fail` can
    never drift on either. `doctor.sh` is the operator's command: it runs the
    schema check, then those two cross-key rules, then the combinations that
    work but would silently surprise an operator later (a `warn`, not a
    `fail`: the stage timeouts outrunning `lock_stale_after`, `review.pr_label`
    colliding with `pr_label`, and the rest), then the model ids through
    `resolve_model_id`, the shipped and overridden prompts, the toolchain,
    the state and workspace directories, the rendered crontab and the
    `nice` reordering report (both below, and both offline-safe), and —
    unless `--offline` — the GitHub write access and Claude credentials the
    stages need, on top of the read access above, which is where a token's
    missing scope stops looking like a repository with no work in it.
    Write access is one `gh api repos/<slug> --jq` call per configured
    repository, folded into the same per-repository pass as the read/label
    check: `.permissions.push == true` is `ok`, `== false` is `fail` (a cycle
    would claim that repository's work and lose it at push), and an absent
    `.permissions` — present only on an authenticated request, so its
    absence is a fact about the request rather than the token — is `skip`,
    never `fail`; `.archived: true` is `fail` regardless of `.permissions`,
    since no token can push to an archived repository. Claude credentials are
    `claude auth status --json`, treated as a probe that can answer only
    sometimes: `loggedIn: true` is `ok`, `loggedIn: false` is `fail` —
    distinguished from a parse failure, since `false` is a legitimate answer
    — and anything that does not exit 0 with that shape — an older CLI with
    no `auth` subcommand included — is `skip`, since a probe that cannot
    answer is never evidence of a fault. The rendered crontab is
    `deploy/docker/render-crontab.sh` run for real, into a `mktemp -d` this
    check removes afterwards, against the config under check: a non-zero
    exit is `fail`, a missing template is `skip`, and success is `ok`
    reporting the cycle, review and heartbeat minutes it rendered and the
    node name it rendered them for — the second declared exception to
    read-only, alongside the state and workspace directories. The `nice`
    reordering report is one `ok` line per configured repository whose
    `nice` is non-zero, naming the value and the multiplier
    `lib/repo-order.sh`'s `1.25^(-nice)` applies to its effective age;
    nothing prints when every repository sits at 0, since this is a report
    of what the config already asks for rather than a check with a right
    answer. Every verdict is `ok`, `warn`, `fail` or `skip`; exit 0 clean, 1
    at least one failure, 2 arguments or a config it could not read.
    Read-only but for the two exceptions above — the configured directories
    it creates to prove they can be, and the crontab it renders into a
    `mktemp -d` it removes — and every GitHub call a GET, so it is safe
    against a live node mid-cycle. Its per-repository label check reads
    `lib/labels.sh`'s catalogue rather than a
    list of its own, so it can never report a different set from the one the
    cycle maintains. `test/config-schema.test.sh` covers the configuration
    half against `--offline`; `test/doctor.test.sh` covers the four checks
    above — write access, Claude credentials, the rendered crontab and the
    `nice` report — against a stubbed `gh` and `claude` on `PATH`, the seam
    `doctor.sh` leaves for both since it carries no override variable for
    either (unlike `lib/labels.sh`'s `LABELS_GH`), run without `--offline` so
    the network-gated checks are actually exercised while nothing on `PATH`
    ever reaches a real network. Must pass `shellcheck`.
15. `lib/labels.sh` implementing requirement 6a: `labels_catalogue` (what a
    repository in a given role — `target`, `review`, `escalation` — needs, as
    `name`/`colour`/`description`, with the names taken from the config as
    `config_defaults` merges it — so a label name absent from `config.json`
    is the schema's own default rather than a literal repeated here — and an
    empty name yielding nothing) and `labels_ensure` (create what is absent in
    one repository, reporting `created` or `failed` per label and nothing at
    all for those already there, so the steady state is silent). `LABELS_GH`
    overrides the `gh` binary for tests. Sourced by `agent-cycle.sh`,
    `review-cycle.sh` and `scripts/doctor.sh`; regression-tested against a
    stubbed `gh` that records every invocation
    (`test/labels.test.sh`); must pass `shellcheck`.
16. `scripts/render-config-table.sh` implementing requirement 1b's generated-
    table property: renders the Markdown table body rows of the three prose
    configuration tables (this document's, `docs/REVIEW-PIPELINE-SPEC.md`'s,
    and the two in `README.md`) from `config.schema.json`'s leaf keys, in the
    schema's own property order — `schedule` and `review` flatten one level
    into dotted keys (`schedule.review_hour`, `review.model`) in the parent's
    position; every other object- or array-valued key (`repos`,
    `prompt_overrides`) renders as a single row. Each key's value cell is,
    in order, its `x-docs.value` verbatim — one string for both documents,
    or an object keyed `readme`/`spec` for the keys whose two tables say
    different things there, the spec's `Value` column carrying the unit
    (`4 h`, `15 min`) the README's `Default` column leaves to the key's name
    — else its schema `default`, a non-empty string bare in backticks and
    anything else as compact JSON in backticks, else `*(required)*`; its
    notes cell is
    `x-docs.readme` for the README's two tables and `x-docs.spec` for the two
    specs' — a string, or an array of blocks (a string is a paragraph,
    `{"list": [...]}` an unordered list, `{"code": ..., "lang": ...}` a
    fenced example, `lang` optional) — falling back to `description` when the
    key carries no `x-docs` for that audience. A cell holds one line, so every
    block flattens into it: a paragraph verbatim, a list's items joined `, `,
    code's newlines turned to spaces and wrapped in one backtick span, each
    block joined to the next by a single space — the same join a plain array
    of paragraph strings always got, and what a single string (a one-block
    array) already renders as unchanged.
    Rewrites four marked regions (`<!-- config-table:start id=main -->` /
    `id=review` … `<!-- config-table:end -->`) in place with no arguments.
    Each region's first two lines, immediately after the start marker, are a
    header row and a `|---|---|---|` delimiter row, carried verbatim rather
    than generated — passed through untouched on every rewrite, which is
    what lets the README say `Default` where the specs say `Value` without
    this script knowing either; the generated rows follow directly beneath
    them, with no line in between. Both modes refuse a region whose first two
    lines are not a header row and a delimiter row, since a bare marker
    comment between the delimiter row and the first data row has no pipe in
    it, so it does not look like a table row and GitHub's Markdown parser
    ends the table right there — the row still looks right in a diff while
    the rendered page shows an empty table body followed by literal piped
    text.
    Each region's Notes cell is additionally capped at 500 characters
    (`NOTES_CAP`): a cell at or under the cap renders the note verbatim, `|`
    escaped, as before; a longer one renders a prefix — at most 480
    characters, tokenised into Markdown atoms (a code span, a link, an
    emphasis run, a whitespace run or a plain word, matched in that order so
    a code span is claimed before its contents are mistaken for a link's or
    an emphasis run's own syntax; a double-backtick-delimited code span is
    tried before a single-backtick one, mirroring CommonMark's own
    preference for the longest matching delimiter run, so a span whose
    content itself contains a literal backtick (`` ``…`…`` ``) is claimed
    whole rather than having its opening `` `` `` read as an empty
    single-backtick span) and cut at the last atom boundary that fits, so a
    cut never lands inside one of those constructs — followed by
    `...[continued below](#extended-notes-<slug>)`. The note's full text is
    repeated, unescaped, under a generated `Extended notes: `<key>`` heading
    in that document's own `config-table:notes id=<region>` … `notes-end`
    region, one per `config-table:start` region and required even where
    nothing in it currently overflows; a region with nothing to say renders
    empty. Unlike the cell, this subsection is ordinary document prose, so
    each block renders as real block Markdown instead of flattening — a
    paragraph string on its own, blank-line-separated from its neighbours; a
    list as real `- ` items; code as a real fenced ```` ``` ```` block — one
    blank line between each pair of blocks.
    The heading's level is derived, not hard-coded — the nearest ATX
    heading strictly above the notes-start marker, plus one, clamped at 6 —
    and its own placement, unlike the table region's, is up to whoever wrote
    the surrounding prose: the script rewrites whatever sits between the
    markers and never moves them. The anchor is GitHub's own heading slug
    (lower-cased, stripped to `[a-z0-9_-]` and space, spaces to `-`); two
    headings in one document slugging the same, or a notes marker with no
    heading above it, are both hard failures rather than silently
    mis-rendered output.
    `--check` renders each region — table and notes alike — to a temporary
    file instead and exits non-zero, naming the file, the region and the
    first differing key, the moment any region is stale — what
    `.github/workflows/config-table.yml` runs on every pull request,
    modelled on `.github/workflows/tech-debt-register.yml`.
    Regression-tested end to end, against the shipped script copied into a
    scratch fixture repository rather than a reimplementation of its logic,
    in `test/render-config-table.test.sh`; must pass `shellcheck`.
17. `scripts/check-closing-keyword.sh` and `.github/workflows/closing-keyword.yml`
    implementing requirement 25a: given a pull request body, extracts every
    `<!-- agent-ops:closes-issue item=N -->` marker (requirement 23b) and
    exits non-zero, naming the missing number, for any that has no matching
    GitHub closing keyword (`close(s|d)`, `fix(es|ed)`, `resolve(s|d)`,
    case-insensitive, a word of its own, immediately followed by `#N`) in the
    same body — "unclosed #N" and "discloses #N" contain a keyword and close
    nothing, exactly as they do to GitHub's own parser. A body
    with no marker passes trivially. The workflow runs on every
    `pull_request` event, passing the body through `env:` rather than
    interpolating it into the step directly, so an attacker-controlled title
    or body from a fork PR cannot inject shell. Unit-tested
    (`test/check-closing-keyword.test.sh`); must pass `shellcheck`.
18. `scripts/sweep-closed-issues.sh` implementing requirement 17c's sweep:
    given a repo slug, a node name and a cycle id, lists that repo's merged
    `pr_label`-labelled pull requests (bounded to the most recently updated),
    and for each carrying an `agent-ops:closes-issue` marker whose named
    issue is still open and not `state_reason: "reopened"`, closes it with a
    `pipeline_comment_header`/
    `pipeline_comment_marker`-wrapped comment citing the merge as evidence,
    printing one JSON action per outcome (`closed`, `deferred`, `warning`)
    for the Script to log. Capped at three actions per repo per call, the
    overflow reported rather than silent. `SWEEP_GH` stubs `gh` for tests.
    Unit-tested (`test/sweep-closed-issues.test.sh`); must pass `shellcheck`.
19. `scripts/close-void-github-items.sh` implementing requirement 34k: given
    a repo slug, a node name, a cycle id and (on stdin) that repo's void
    candidates already filtered to the id shapes `lib/work-gone.sh` defines
    (a bare issue number, `pr-<n>-…`) and to what
    `void_object_closed_items` has not already processed, closes each still-
    open object with a comment carrying the void's `detail`/`evidence`,
    printing one JSON action per outcome (`closed` — `closed_by: "sweep"` or
    `"already"` — `deferred`, `warning`) for the Script to log as
    `void-object-closed`. Any other id shape is left untouched. Capped at
    three actions per call, the overflow reported rather than silent.
    `SWEEP_GH` stubs `gh` for tests. Unit-tested
    (`test/close-void-github-items.test.sh`); must pass `shellcheck`.

## Acceptance checks

Every change to the system must leave all of these passing; before opening a
pull request, run the ones the change touches and any it could regress.

1. `shellcheck agent-cycle.sh scripts/*.sh lib/*.sh` is clean.
1a. **The role guard holds in both directions.** `test/role.test.sh` passes:
   every value that is not `active` stands the node down with a cron-log line,
   exit 0 and nothing written under `state_dir`; `--dry-run`, `--once` and the
   switch commands run regardless of the role.
1b. **The image builds and carries the whole toolchain, on both
   architectures.** `docker build -f deploy/docker/Dockerfile -t agent-ops .`
   succeeds, and inside it, as user `agent`: `bash`, `git`, `jq`, `curl`,
   `python3`, `perl`, `flock`, `sha256sum`, `rsync`, `node`, `claude`, `gh`
   (≥ 2.60), `supercronic` and `shellcheck` all resolve; `shellcheck
   --version` prints `0.10.0`, the same version
   `.github/workflows/shellcheck.yml` pins; `supercronic -test
   /app/deploy/docker/crontab` reports the crontab valid; the `test/` suite
   passes inside the container; and `/app/agent-cycle.sh` with no role set
   exits 0 through the requirement 2.4 guard. `.github/workflows/build-image.yml`
   runs every one of these against both the `linux/amd64` and the `linux/arm64`
   build on every pull request that touches the image — each architecture in
   its own job, natively on a runner of that same architecture
   (`ubuntu-latest` and `ubuntu-24.04-arm`), with no emulation anywhere in the
   tested path — so a change that breaks either architecture's image cannot be
   merged, and it is the only place the `test/` suite runs in CI. On `main` the
   workflow publishes both architectures as one manifest list per tag.
1b-i. **A documentation-only change builds nothing, and everything else
   builds.** `test/is-docs-only.test.sh` passes: `scripts/is-docs-only.sh`
   calls a change documentation-only when every path in it is under `docs/`
   or `tech-debt/`, or is `README.md`, `CLAUDE.md`, `TECH-DEBT.md`, `LICENCE`
   or `deploy/docker/README.md`, and calls it code otherwise — `prompts/*.md`
   included, since those are Markdown documents *and* the operating
   instructions of requirement 1a's stages, so classifying by file extension
   would let a change to a node's behaviour skip the build that deploys it. An
   empty path list, or none, is code. The test the allowlist encodes is "the
   image is not the delivery path for this file", which is weaker than "nothing
   reads it" and has to be: a cycle working on this repository reads its own
   `CLAUDE.md` and its tech-debt register, but from the `gh repo clone` in
   `workspace_root`, and `scripts/gather-register-hygiene.sh` reads the
   register — `TECH-DEBT.md` or `tech-debt/`, whichever this repository
   uses — directly from the API (requirement 3i) — both current the moment a
   pull request merges, with no image involved. The copy at /app
   is what nothing reads, because every stage's working directory is under
   `workspace_root` or `state_dir` (requirement 6's assertion pins the first),
   so /app is never a working directory nor an ancestor of one and its
   `CLAUDE.md` is never loaded as project memory. `.github/workflows/build-image.yml`'s
   `changes` job runs it over the change's own diff (three-dot, so a pull
   request is judged on what its branch did and not on what `main` did
   meanwhile) and, when the answer is yes, skips every *step* of the `build`
   jobs and the whole of `publish`; a checked-out state it cannot diff builds.
   The skip is neither a `paths-ignore:` filter nor a job-level `if:` on
   `build`, because each of those leaves a required check that never reports
   and a pull request that can never merge: a filtered-out workflow reports
   nothing at all, and a skipped *matrix* job never expands its matrix, so it
   reports one check run named for the uninterpolated
   `Build and test (${{ matrix.platform }})` while the two names the ruleset
   requires go unreported. Skipping the steps instead leaves both legs running
   and reporting success on every pull request, at the cost of a runner that
   starts and does nothing. Every job here therefore reports on every pull
   request, and `Work out what changed` joins the other three as a required
   check. Only an explicit "yes" skips: a `changes` job that fails rather than
   answers leaves the steps' condition unsatisfied-by-emptiness and they run,
   since a skipped job reading as success would otherwise carry a dead runner
   through to `publish` and leave a merge to `main` with no image at all.
   `publish` states that condition itself rather than inheriting it through
   `needs`, its `build` jobs now being successful on a documentation-only
   change rather than skipped. A documentation-only merge to `main` publishes
   no image, and no tag carries that commit's SHA.
1c. **The stack comes up from nothing and is idempotent.** With a `.env` copied
   from `.env.example` and `COMPOSE_PROFILES=local`, `docker compose up -d` in
   `deploy/docker/` starts `scheduler` and `dashboard-local` on fresh volumes;
   `curl http://127.0.0.1:$DASHBOARD_PORT/` and `/data.js` return 200; the
   scheduler's log shows supercronic reading the crontab and the 5-minute
   heartbeat firing; `agent-cycle.sh` and `review-cycle.sh` stand the node down
   through the requirement 2.4 guard with `ROLE=standby`; and a second
   `up -d` reports every container `Running` without recreating one.
   `docker compose --profile tailnet config` is valid. And the `local`
   profile's exposure is the host's loopback and nothing more:
   `docker compose --profile local config` shows `dashboard-local` publishing
   with host IP `127.0.0.1` and no `network_mode`, so the same curl from
   another machine on the host's network is refused. Check 1c-ii is the same
   property guarded on every commit, where this one needs a node.
1c-i. **A roll waits for a cycle.** `test/watchtower-pre-update.test.sh`
   passes: `deploy/docker/watchtower-pre-update.sh` exits 75 while, inside
   that pipeline's `lock_stale_after`, either `lock.json` or
   `review-lock.json` names a live process in the hook's own container — or
   *any* process in another container: the suite models one lock read under
   the writer's hostname and a neighbour's, deferring in both while the
   writer's process lives, and deferring for the neighbour regardless of the
   pid, which it has no way to check. It exits 0 when the locks are free,
   stale, unreadable, or dead by the writer's own reading, and exits 0
   rather than blocking when it cannot read `config.json` at all. Both cycle
   scripts stamp `host` into the locks they write; the suite pins that too.
   `docker compose config` shows every service on the
   agent-ops image carrying
   `com.centurylinklabs.watchtower.lifecycle.pre-update` pointing at that
   script, and `watchtower` carrying `WATCHTOWER_LIFECYCLE_HOOKS=true`.
   On a live node: `docker compose exec scheduler
   /app/deploy/docker/watchtower-pre-update.sh` echoes its finding and exits
   0 when idle, 75 during a cycle.
1c-ii. **The dashboard is published to the host's loopback and to no network.**
   `test/dashboard-exposure.test.sh` passes: in `deploy/docker/compose.yaml`
   every port `dashboard-local` publishes is scoped to `127.0.0.1`, the mapping
   is `127.0.0.1:${DASHBOARD_PORT:-8787}:8787` so `DASHBOARD_PORT` moves only
   the host side, and it carries no `network_mode`; its server is told to bind
   `0.0.0.0` on that same container port, without which the published mapping
   would reach nothing; the `tailnet` `dashboard` is in the sidecar's namespace
   (`network_mode: service:tailscale`), publishes no port and is given no bind
   address, so it keeps loopback where Serve proxies to it; and no other
   service publishes a port at all. `scripts/serve-dashboard.sh` invoked with
   no bind address resolves to `127.0.0.1`, and to `0.0.0.0` when given it.
   The socket-level half of the property — that a request from another machine
   is refused — is check 1c, which needs the stack up; this check runs in the
   image, where there is no Docker.
1c-iii. **A node can tell when its compose.yaml has fallen behind.**
   `test/compose-drift.test.sh` passes: identical copies read `in-sync` and
   so do copies differing only in comments and blank lines; a material
   difference reads `drifted` with a positive `diff_lines`; a missing mount
   reads `unmounted` inside a container and `null` outside one; an image
   carrying no copy of its own reads `null`, never a guess; no path returns
   non-zero (the verdict is computed inside a heartbeat push running under
   `set -e`); and `deploy/docker/compose.yaml` mounts itself read-only at
   `/host/compose.yaml`, the path the library reads — the line through which
   the check is armed. The file-level assertions of 1c-i pin the
   repository's copy and prove nothing about any node's; this check is what
   covers the gap they leave.
1c-iv. **A node can tell when it has fallen behind the newest published
   image.** `test/image-drift.test.sh` passes: a checkout (not a CI-stamped
   image) reads `null`; a matching commit reads `current`; a differing one
   reads `behind`, carrying the registry's commit and the image's creation
   label; a token, manifest or config-blob fetch that fails, or an image
   carrying no revision label, reads `unverified` with a reason, never a
   guessed verdict; the multi-platform index this repository actually
   publishes is walked one level to reach the labels, into a per-platform
   image and never into one of the attestation manifests buildx writes
   beside them (whose config blob carries none of these labels, so reading
   one would report the whole fleet `unverified` while the registry was
   answering perfectly well); a second call inside
   `IMAGE_DRIFT_TTL` costs no network call, while an empty cache-file path
   always re-fetches; no path returns non-zero; and
   `.github/workflows/build-image.yml`'s publish step stamps both the
   revision and creation labels the check reads. `test/check-node-image.test.sh`
   passes against a stubbed `docker`: current, and behind within the
   configured grace, both exit 0; behind past the grace exits 1, naming the
   registry commit and the grace exceeded; a registry the container could
   not reach exits 2; a node not running a CI-stamped image at all is not a
   failure; and no `compose.yaml` in the stack directory, or a scheduler
   that cannot be exec'd into, is exit 2, never a clean pass.
1d. **State replicates per node, and comes back as peers.**
   `test/state-sync.test.sh`
   passes: a push carries the logs, cycles, reviews and switch but not the
   locks or the dashboard, onto the node's own `nodes/<NODE_NAME>` branch
   with a heartbeat naming the node, its role, its newest cycle, its version,
   its compose-drift verdict (asserted end to end: a node whose fixture
   copies differ publishes `drifted` with the differing-line count) and an
   image-drift slot (what the verdict itself says is 1c-iv's own coverage;
   this asserts only that state-sync.sh asks for one, and that its cache file
   does not replicate); a second
   push amends rather than accumulating history; a standby pushes its own
   branch and never a peer's; the branch keeps
   `cycles_retained` cycles while the node's own `cycles/` and `reviews/` are
   pruned to the newest `state_local_cycles_retained` by the same push,
   newest always kept; a fetch materialises a peer whole
   under the peers directory, leaves the node's own `state_dir` alone, never
   includes the node itself, and prunes a peer whose branch is gone; the
   union read (`lib/fleet.sh`) carries both nodes' events in time order; and
   pipeline events written through `log_event` carry the node's name.
1e. **The fleet flags reach every node.** `test/toggle.test.sh` passes,
   including its fleet section against the contents-API stub (`TOGGLE_GH`):
   a flag one node writes reads as disabled on another; an unreachable
   state repo falls back to the cached copy, and to enabled with none; a
   404 is clear and clears the cache; a garbage flag is disabled; the limit
   flag only ever extends; a delete never reports cleared for a flag still
   set; and — end to end, offline — `--disable` on node A publishes
   `fleet/disabled.json` and both real pipelines on node B stand down
   naming the fleet switch, `--enable` on A genuinely removes the flag, and
   a `fleet/limit.json` published by A stands B down until its `resume_at`.
1f. **A provider-qualified model id resolves; an unsupported one fails fast
   (requirement 1a).** `test/model-id.test.sh` passes: a bare id and its
   `anthropic/`-qualified form resolve to the same value; an empty value (the
   "disable this stage" convention) passes through unresolved; a qualifier
   naming any other provider fails, printing nothing and naming the offending
   key and provider on stderr; and an assignment of the rejected form under
   `set -euo pipefail` — the exact context every `cfg` read in `agent-cycle.sh`
   and `review-cycle.sh` uses — aborts the script rather than silently
   continuing with the qualified string.
1g. **Every shell script in the repository is shellcheck-clean.**
   `./scripts/lint-shell.sh` exits 0. It discovers the file set — every tracked
   `*.sh`, plus every tracked file whose first line is a sh or bash shebang, so
   the init scripts and git hooks are included and a script added tomorrow is
   covered without anyone adding it to a list — and checks them in one
   invocation with `-x`, which is what lets `source` resolve between the
   pipelines and `lib/` instead of raising SC1091 on each of them. Clean means
   nothing reported at all, info findings included; a false positive is
   silenced by a `# shellcheck disable=` in the file that carries it, with a
   comment saying why, never by an exclusion in the runner.
   `.github/workflows/shellcheck.yml` runs the same script on every pull
   request against a pinned shellcheck (component 10).
1h. **A log past `log_retained_bytes` rotates, keeps `log_generations`, and
   never touches `log.jsonl`.** `test/rotate-logs.test.sh` passes: a log under
   the threshold is left alone; one over it is renamed to `.1` and a fresh
   empty file takes its place; a second rotation shifts `.1` to `.2` rather
   than overwriting it, and a generation beyond `log_generations` is dropped;
   `log.jsonl` and `review-log.jsonl` grow past the threshold untouched; and
   `once-pr4-verify.log` is removed if present. `test/publish-dashboard.test.sh`
   passes its cron-panel case: with `cron.log` short and `cron.log.1` present,
   the panel's tail draws from both, newest last.
1i. **Per-installation prompt overrides extend or replace a stage's prompt,
   and the fingerprint tracks them (requirement 4a).**
   `test/prompt-overrides.test.sh` passes: with no `prompt_overrides`
   configured (or a stage absent from it), `stage_prompt_text` is
   byte-identical to `cat prompts/<stage>.md`; a configured `extend` list is
   appended in order, each fragment wrapped in the "specs outrank every
   prompt" disclaimer; a configured
   `replace` substitutes the base prompt entirely, with any `extend` still
   appended after it, and falls back to the shipped prompt when the
   configured file is unreadable; an override for a different stage has no
   effect; an unreadable base prompt that no `replace` covers makes
   `stage_prompt_text` fail rather than return empty; and `stage_prompt_sha`
   changes for every one of those cases,
   including a configured `extend` file that does not exist. The digest is
   content-addressed: relocating the whole installation (prompts, state
   directory, `$HOME`) with identical config and content computes the
   identical fingerprint, and a `replace` file whose content equals the
   shipped prompt's computes the no-override fingerprint, because it serves
   the same bytes. `prompt_overrides`'s own structural shape — a non-object,
   an unknown stage key, a non-object stage value, an unknown key within a
   stage, a non-array `extend`, a non-string `extend` entry or `replace` — is
   config.schema.json's concern rather than this library's (requirement 1b);
   test/config-schema.test.sh asserts one rejection per class, naming the
   offending path.
1j. **The Co-Ordinator's repo/work-sources table is config-driven, and names
   no consumer repo in `prompts/coordinator.md` (requirement 4b).**
   `test/coordinator-brief.test.sh` passes: `coordinator_work_sources_table`
   renders one Markdown row per repo, each `sources` entry numbered in the
   order given, in the order the repos array itself gives; reordering a
   repo's `sources` reorders its row's numbering; an empty `repos` array
   renders only the header and separator. `prompts/coordinator.md` itself
   contains no real consumer repo slug, including in its worked JSON
   examples, which use generic placeholder slugs instead.
   `test/noop-skip.test.sh` passes: a change to the rendered table busts the
   no-op fingerprint, and an input predating the `coordinator_work_sources_
   table` key canonicalises the same as one carrying it empty.
1k. **A stage prompt reaches `claude` on stdin, at a size argv could not
   carry (requirement 4c).** `test/stage-prompt-delivery.test.sh` passes: for
   `run_claude_stage` as sourced from `lib/stage-run.sh` — the one copy both
   pipelines call, which the file asserts by finding the function in neither
   cycle script — a 200000-byte prompt, comfortably past `MAX_ARG_STRLEN`,
   exits 0, arrives on the stub's stdin whole, appears
   nowhere in its argv, and leaves the JSON envelope in `out_file` where the
   caller's parser looks for it; an ordinary short prompt is delivered byte
   for byte. The oversize prompt is sized to the kernel's constant rather
   than to the prompt of the day, so the check keeps its meaning if a prompt
   is ever trimmed; the file first confirms the cap exists on the kernel it
   is running on, and says so and skips rather than passing vacuously if it
   does not.
1k1. **A stage streams as it runs, and leaves the envelope its readers
   expect (requirement 4d).** `test/stage-stream.test.sh` passes, against a
   `claude` stub that emits stream-json a line at a time with a pause
   between lines: the invocation is made with `--output-format stream-json
   --verbose`; `<stage>.stream.jsonl` grows *while the stage is still
   running*, which is the property the non-streaming form could not provide
   and the one every later use of the stream rests on; every emitted event
   survives in it; `<stage>.out` holds exactly the final `result` event, one
   line, and `metering_fields` derives from it the same record it derives
   from a bare `--output-format json` envelope carrying the same numbers; a
   stream whose last line is torn — the shape a killed stage leaves — still
   yields the earlier `result` event if it has one, and yields an empty
   `.out`, not a corrupt one, if it does not; and a stage that emitted no
   `result` event at all leaves `.out` existing and empty, which is what its
   readers already treat as "no envelope". `test/state-sync.test.sh` passes:
   a `*.stream.jsonl` written into a cycle directory reaches neither the
   mirror nor the pushed branch while the `.out` beside it reaches both, one
   already in the mirror from before the exclusion is deleted from it, and
   `state_local_streams_retained` removes the streams of older cycle and
   review directories while leaving those directories and every other file
   in them in place.
1k2. **A stage's inter-event gaps are measured while it runs (requirement
   33a).** `test/stage-gaps.test.sh` passes: `stage_gap_stats` summarises a
   known sample at the nearest rank — checked at the ranks where definitions
   differ, not only in the middle — leaves one long silence among short ones
   visible as `max` without moving `p50`, skips an unreadable observation
   rather than failing the record, and reports `null` only for a sample with
   nothing readable in it. Against a stub emitting with controlled pauses:
   an eight-second silence is measured rather than averaged away, gaps are
   counted per observed growth of the stream, the silence after the final
   event is counted even though no event closed it, a stage that emitted
   nothing at all still reports the one gap that was all of it, and the
   stage's own envelope and exit status are unaffected by being measured.
   Timing assertions bound from below, never exactly: a loaded machine makes
   a silence look longer, never shorter. `test/metering.test.sh` passes:
   `gaps` is carried through as given, is `null` when the caller supplies
   none, and degrades to `null` — rather than failing the whole record —
   when the caller supplies something unparseable.
1k3. **A stage that stops producing is stopped, and the two kills are told
   apart (requirement 4e).** `test/stage-watchdog.test.sh` passes, against a
   `claude` stub whose output it controls: a stage that goes quiet for longer
   than its inactivity threshold is killed, returns 124, and reports
   `stage_kill_reason` `inactivity`; a stage that keeps emitting through a
   span several times that threshold is *not* killed, which is the assertion
   that matters most, since the whole failure being replaced was killing
   stages that were working; a stage that emits nothing but outlives its
   backstop reports `backstop`, not `inactivity`; a threshold of `0` disables
   the watchdog, leaving a silent stage to run to its backstop; a stage that
   ends on its own reports no kill reason at all; the killed process group is
   dead rather than orphaned; and the stream written before the kill survives
   it, which is what makes the forensics of requirement 4d worth having. The
   `warning` body is produced for an inactivity kill and for nothing else.
   The same file covers requirement 4e's third stop: a stream reporting the
   account `rejected` stops the stage at once, attributes it to `rate-limit`
   rather than to either cap, and carries the runner's own record — reset time
   included — out for the stand-down; an `allowed_warning` does *not* stop it,
   nor does the same status string appearing inside a tool result, which is
   what an Implementor working on limit detection would be reading.
   `test/limit-detect.test.sh` passes: `limit_decide_structured` returns the
   stated reset as a known one, maps a seven-day limit to the weekly class and
   a five-hour one to `other`, falls back exactly as the prose path does when
   no reset is stated, and declines rather than guessing on an empty,
   unparseable or non-object record.
   `test/doctor.test.sh` passes: `--offline` reports the stream-flushing
   probe skipped rather than running it, so the suite never spends.
1k4. **Both stage caps derive themselves, and in the safe direction
   (requirement 4f).** `test/stage-budget.test.sh` passes against fixture
   logs with absolute dates: a stage is keyed to the repository its cycle
   selected and to the model it ran, two repositories are two cells, and the
   Co-Ordinator has no repository axis; an unseen cell answers from the
   shipped prior, as does an empty table, so a first cycle needs no
   configuration; one backstop kill multiplies the cap and repeated kills are
   bounded by the ceiling, while three clean runs move it not at all; a killed
   run is counted as a run and contributes no duration, so the percentile is
   over completed runs only; a long silence widens the watchdog threshold and
   consistently short ones never narrow it below the prior, and it never
   exceeds the backstop; one run leaves a cell marked `shrunk` and carries
   only a fraction of its own estimate; configuration outranks the derivation
   and says so on the event; the derived lock clears the summed worst-case
   backstops plus slack, treats a configured value as a floor, and still
   derives from the priors alone against an empty table; and a malformed log,
   a `stage-end` predating `kill_reason`, one predating the gap statistics and
   a malformed `stage_budget` object each yield a usable answer rather than
   none. `test/stage-overrun.test.sh` passes: the dashboard holds a live stage
   against the cap announced on its own `stage-start`, falling back to the
   fleet-wide widest for that actor and then to the shipped prior, and makes
   no claim at all about a stage none of those names.
   `test/config-schema.test.sh` passes: `scripts/doctor.sh` reports the
   derived lock rather than checking a configured one, and warns that a
   configured cap pins itself.
1l. **Repos are walked most-overdue-first by nice-weighted effective age,
   and it never starves a repo (requirement 3).** `test/repo-order.test.sh`
   passes: `repo_order_by_effective_age` returns an order byte-identical to
   a plain least-recently-updated-first `sort` of the same lines when every
   repo's `nice` is `0` or absent; scaling by `1.25^(-nice)` moves a
   negative-`nice` repo earlier and a positive-`nice` repo later, checked in
   both directions; a missing or unparseable timestamp reads as epoch 0 and
   stays maximally overdue at neutral `nice`; two repos with equal effective
   ages break by slug; the output is always a permutation of the input
   lines, never a subset or a reordering that drops or duplicates one; and
   `repo_nice_selection_config` returns `{}` — no key — for a config with
   no non-zero `nice` (absent, `null`, `0` and `-0` alike) and exactly the
   non-zero entries, floor-normalised, otherwise. `test/noop-skip.test.sh`
   passes: a `repo_nice` entry in `selection_config` changes the no-op
   fingerprint; and an input carrying an empty `repo_nice` map does *not*
   canonicalise the same as one omitting the key entirely — omission is the
   neutral form the producer emits for the shipped config (no `nice` keys
   anywhere), so it must drop the key rather than emit `{}`. Separately: a
   `nice` outside `-19`..`19`, or non-integer, makes `agent-cycle.sh` refuse
   to start, naming every offending repo's slug.
2. `--dry-run` completes against the real repos: stand-down checks pass,
   ordering is computed, the findings pre-fetch runs, the Co-Ordinator selects
   an item or declines with a reason, the work order is printed, nothing
   further launches, and the log records the cycle.
2a. `scripts/gather-findings.sh Poetic-Poems/poetic` prints a valid JSON
   array (possibly empty), and prints `[]` and exits 0 for a repo with the
   features disabled — never a non-zero exit that would abort the cycle.
2b. `scripts/gather-abandoned-drafts.sh Poetic-Poems/does-not-exist autonomous-agent agent/ 3`
   prints `[]` and exits 0 — a missing repo, a disabled feature, an API error, or
   an unparseable threshold never aborts the cycle. Its candidate rule is
   regression-tested in `test/abandoned-drafts.test.sh`.
2c. `scripts/gather-merge-conflicts.sh Poetic-Poems/does-not-exist autonomous-agent agent/`
   prints `[]` and exits 0 — a missing repo, a disabled feature, or an API error
   never aborts the cycle. Its candidate rule is regression-tested in
   `test/merge-conflicts.test.sh`.
2e. `scripts/gather-register-hygiene.sh Poetic-Poems/does-not-exist main` prints
   `[]` and exits 0, silently — a repo (or a repo with no register, or an
   as-yet-empty one) is a normal `[]`, not an error. Against each configured
   repo it prints `[]` while that repo's register is consistent.
   `test/register-hygiene.test.sh` passes against the per-item fixtures
   `test/fixtures/tech-debt-items-consistent/` and
   `test/fixtures/tech-debt-items-drifted/`, driven by a stubbed root-tree
   listing (naming the `tech-debt` tree and the `TECH-DEBT.md` policy blob)
   and a stubbed tarball endpoint: a consistent register yields `[]`; a
   drifted one yields exactly one candidate whose `ref` digests *both* the
   `tech-debt` tree SHA and the policy blob SHA together (so a repair to
   either retires it) and whose `blob_sha` carries the tree SHA. The
   candidate's `problems` array holds one entry per problem line and its
   `body` is the checker's output verbatim; a tree naming no `tech-debt` tree
   yields `[]` with nothing on stderr; and an API error at any step yields
   `[]` *with* stderr, since the difference between "no register" and "no
   answer" is the whole of what a silent `[]` costs you at 3 a.m.
2d. **Issue priority is read, defaulted and fingerprinted.**
   `test/issue-priority.test.sh` passes: against a stubbed issues endpoint,
   `scripts/gather-source-state.sh` bands each issue by its `Priority` issue
   field; an issue with no `issue_field_values`, with values but no `Priority`
   entry, or with a `Priority` the organisation added later reads as `Medium`;
   pull requests are still dropped from the digest; and the no-op fingerprint
   (`lib/noop-skip.sh`) differs between two samples that are identical except
   for one issue's band, so re-prioritising an issue always buys a Co-Ordinator
   run. Against the real API,
   `scripts/gather-source-state.sh Poetic-Poems/poetic-fiddle main` prints
   `ok: true` with a `p` on every issue.
2e. **Issues arrive pre-fetched, filtered, whole-thread and fingerprinted.**
   `test/issues-prefetch.test.sh` passes: against a stubbed issues endpoint,
   `scripts/gather-issues.sh` drops an assigned issue, a `Blocked`-labelled
   issue (whatever the case), and a pull request, while a clean issue arrives
   with `source: "issues"`, its number as `ref`, its `Priority` band (default
   `Medium`), its body, and its comments verbatim; a failing API degrades to
   `[]` (exit 0) with the failure on stderr; and the no-op fingerprint
   (`lib/noop-skip.sh`) differs between two inputs identical except for the
   text of one issue comment — the one transition only the verbatim array
   carries. Against the real API, `scripts/gather-issues.sh
   Poetic-Poems/poetic-fiddle` prints an array whose entries all carry
   `comments` and a four-name `priority`.
2f. **A preview nobody can reach is never reported as a healthy one
   (requirement 24a).** `test/preview-deploy.test.sh` passes: against a stubbed
   `gh` and a stubbed Vercel that answers the login flow to any request not
   carrying the project's bypass secret, a built and reachable preview is exit
   0; a preview behind Vercel Authentication is exit 2 naming
   `VERCEL_AUTOMATION_BYPASS_SECRET`, with a different diagnosis for a secret
   that is unset and one that is rejected, since the two have different fixes;
   a failed build is exit 1 naming the inspector, and carries the tail of the
   build log when `VERCEL_TOKEN` is set; a preview that built and then serves a
   500 is exit 1 and is distinguished in words from a build failure; an
   application's own redirect is followed rather than mistaken for the login
   flow; no deployment at all, a SHA deployed only to Production, and a
   deployment still building are each exit 2; and `--wait` re-asks rather than
   answering from its first look. With no `--repo` and no `--pr` it resolves
   the checked-out branch's own pull request without combining `--repo` with
   an unidentified pull request — a shape the real `gh` CLI refuses, since
   `--repo` overrides the ambient-repository inference `gh pr view` otherwise
   uses to find the current branch's PR — and an explicit `--repo` with no
   `--pr` resolves the number first through `gh pr list --head <branch>`
   rather than combining the two; that refusal is pinned directly against the
   installed `gh` binary, not assumed by the stub. Against the real API and a
   real protected preview, `scripts/preview-deploy.sh --repo
   Poetic-Poems/poetic-fiddle --pr <n>` from a shell with no bypass secret set
   reports that the deployment built and that the page could not be checked.
2g. **Every pipeline comment is visibly attributed (requirement 9d).**
   `test/comment-identity.test.sh` passes: `pipeline_actor_label` returns the
   right display name for each of `script`, `coordinator`, `implementor`,
   `reviewer`, `enabler`, `review-script` and `project-reviewer`, and fails
   open — prints the token itself — for one it does not recognise;
   `pipeline_comment_header` renders `**<Display>** · autonomous pipeline ·
   node \`<node>\`` for a known and an unknown actor alike;
   `pipeline_comment_marker` carries both the cycle id and the actor token,
   still prefixed with `PIPELINE_COMMENT_MARKER_PREFIX`; and each of
   `prompts/implementor.md`, `prompts/enabler.md` and `prompts/reviewer.md`
   contains the literal header form `pipeline_comment_header` produces for its
   own actor token. `prompts/reviewer.md` also contains the literal
   instruction to post an unconditional completion comment (requirement 30b),
   pinned by a distinctive phrase from that instruction.
   `test/abandoned-drafts.test.sh` separately proves an
   older, actor-less marker and a newer, actor-carrying one both still exclude
   a comment from the activity clock, and that all three prompts (now
   including `prompts/implementor.md`) still carry
   `PIPELINE_COMMENT_MARKER_PREFIX`.
3. A second invocation while one holds the lock exits without acting.
4. A simulated stale lock (fake lock file, old timestamp, dead PID) is taken
   over with a logged warning. A simulated foreign lock (fake lock file
   naming a different `host`, fresh timestamp, a pid that is alive here
   because it collides with an unrelated local process) is taken over
   immediately with a logged warning, and that local process is left
   running.
4a. **A signal leaves a record, a released claim, and no orphaned model
   (requirement 9c).** `test/signal-exit.test.sh` passes: with the signal
   machinery lifted from `agent-cycle.sh` (and from `review-cycle.sh`), a
   TERM delivered mid-stage kills the stub stage's own process group, logs
   an `attempt-failed` whose detail is `<stage> terminated by SIGTERM`,
   releases the claim — `have-pr` when a breadcrumb names a PR, `no-pr`
   otherwise — and exits 143 through the EXIT trap; a stage that had
   already ended cleanly is not blamed (the event says `cycle`); and the
   requirement-1 takeover grace TERMs a live stale holder, proceeds as soon
   as the holder exits rather than sleeping out the full grace, and still
   takes the lock over.
5. An injected `limit-hit` event with a future `resume_at` and
   `reset_known: true` causes a stand-down with no probe launched; an expired
   one does not stand down. With `reset_known: false`, the cycle launches
   exactly one probe: a stubbed `claude` answering a clean envelope yields a
   `limit-cleared` event (`by: auto-probe@<node>`) and the cycle proceeds; a
   stub answering the limit phrase logs a fresh `limit-hit` and a stand-down
   whose reason ends `(probe: still limited)`; a stub that exits non-zero
   with no output changes no limit state and the reason ends
   `(probe: inconclusive)`. `--dry-run` with the same injected event launches
   no probe.
5a. **A fleet-wide Co-Ordinator crash loop is detected once and escalated
   once (requirement 2.7).** `test/crash-loop.test.sh` passes: for
   `crash_loop_verdict`, a stream of threshold-many consecutive same-detail
   Co-Ordinator failures yields a verdict carrying the count, the window and
   every failing node; one fewer yields nothing; a Co-Ordinator success
   anywhere in the run resets the count (including the `stage-end 0` that
   precedes an `unparseable final message` failure, which counts as one, not
   threshold-plus); a detail change restarts the count at one; item-stage
   failures and other nodes' noise never contribute; a threshold of 0 is the
   off switch. For `crash_loop_escalated_since`, an escalation event for the
   same detail after the run's first failure suppresses re-escalation, while
   an older one — a closed issue from a past loop — does not, and a
   different detail never matches.
   back-pressure, and the logged reason states the count's composition
   (`N ready + N draft + N unraised claim(s)`).
6a. **The switch stops both pipelines and lets go by itself.**
   `--disable 'testing'` then a plain invocation of *both* `agent-cycle.sh` and
   `review-cycle.sh`: each logs a stand-down carrying the reason, exits 0, and
   launches no `claude`. `--enable` restores both. Then plant a record whose
   `expires_at` is already past and run a cycle: it must clear the switch, log
   `enabled` saying the disable expired, and proceed — the assertion that an
   agent which sets the switch and dies costs a few cycles rather than every
   future one. Assert the ambiguous cases resolve toward *disabled*: a
   truncated record, and one whose `expires_at` is gibberish, both keep the
   pipeline down.
6c. **A review round is answered exactly once.** With a PR carrying an
   unanswered `CHANGES_REQUESTED`, a cycle must select it (`source:
   "review-feedback"`, `item` the round's ref, `branch` the PR's existing
   branch) and the Implementor must push to that branch without opening
   anything. Then the check that matters: run another cycle and assert the PR
   is **no longer a candidate**, while `gh pr view --json reviewDecision` still
   reports `CHANGES_REQUESTED`. Those two facts are true simultaneously, and
   that is the point — the agent cannot clear a review on its own PR, so
   nothing about the PR's state ever says "answered", and only the turn rule
   (a marked reply or a re-requested review since the blocking review, never a
   commit's date — see the design note on why) distinguishes "our move" from
   "theirs". Get it wrong and the PR is re-fixed hourly forever while every
   cycle looks productive. Assert the reopen too: a *new* review after the
   agent's push makes it a candidate again under a *new* ref, or a round that
   once went `blocked` will swallow the human's next attempt to unstick it.
6d. **Back-pressure cannot deadlock the pipeline (requirement 2.2a).** Set
   `max_open_agent_prs` to 0 with a *finishing* candidate present — a
   review-feedback round, a merge-conflicted PR *or* an abandoned draft: the cycle
   must **not** stand down, and must reach the Co-Ordinator with every repo's
   `sources` narrowed to
   `["review-feedback", "merge-conflicts", "abandoned-drafts"]`. With none present
   it must stand down as before. This is the check that a system whose PRs have all
   been sent back for changes — or all stalled as abandoned drafts or wedged on
   conflicts, the very slots the cap is counting — can still dig itself out;
   without it, the state the pipeline is least able to escape is the one it is
   guaranteed to reach.
6e. **An abandoned draft is finished, not restarted (requirements 3e, 15c).**
   With an open *draft* PR carrying `pr_label` on a `branch_prefix` (or `td/`)
   branch whose `updatedAt` is older than `abandoned_draft_after_hours`, a cycle
   must select it (`source: "abandoned-drafts"`, `item` the head-SHA-scoped ref,
   `branch` the PR's existing branch), and the Implementor must check out that
   branch and push to it without opening a new PR or branch. Assert the freshness
   gate: the same PR with a recent `updatedAt` is **not** a candidate — a draft
   merely being worked, or one a peer node just touched, must never be stolen.
   Assert a *ready* PR of ours is never an abandoned-drafts candidate (that is
   review-feedback's job). And assert the claim uses a file claim, not a
   create-ref against the already-existing branch (requirement 17a), or every
   attempt would 422 and no abandoned draft could ever be picked up.
6f. **A conflicted PR is rebased, not restarted (requirements 3g, 15d).** With an
   open *non-draft* PR carrying `pr_label` on a `branch_prefix` (or `td/`) branch
   whose `mergeable` is `CONFLICTING`, a cycle must select it (`source:
   "merge-conflicts"`, `item` the head-SHA-scoped ref, `branch` the PR's existing
   branch), and the Implementor must check out that branch, rebase onto the base
   and push without opening a new PR or branch. Assert the guards: a PR whose
   `mergeable` is `UNKNOWN` is **not** a candidate — mergeability is computed
   asynchronously and guessing would rebase a PR that may not conflict; a *draft*
   conflicted PR is not a candidate here (that is abandoned-drafts' job once it
   goes stale); and a *mergeable* PR is never a candidate. And assert the claim
   uses a file claim, not a create-ref against the already-existing branch
   (requirement 17a), or every attempt would 422 and no conflicted PR could be
   picked up.
6g. **The review runs at the tier the work graded itself (requirements 26a,
   8a).** `test/cycle-state.test.sh`'s reviewer-complexity section passes: the
   resolution takes the highest valid grade among the summary's `complexity`
   and the PR's `complexity:*` label values (a label `high` outranks a summary
   `medium`, and vice versa); an unknown grade contributes nothing rather than
   failing; and with no valid grade at all it falls back to `low` for a
   trivial-classified work order and `medium` otherwise. Driving a cycle
   end-to-end: the Implementor's PR carries exactly one `complexity:*` label,
   its summary carries `complexity`, and the reviewer's `stage-start` event
   records the resolved `complexity` and a `model` equal to
   `reviewer_model_complex` when and only when the grade is `high`.
6b. **The no-op short-circuit skips only what it can prove, and stops skipping
   when anything moves.** Drive a cycle that ends `none-selected`, confirm the
   event carries a fingerprint, then run a second cycle: it must stand down
   *without launching the Co-Ordinator* — that saving is the entire feature, so
   time both and see it. Then the half that actually matters, and the half
   it is tempting to skip because the happy path passed: assert
   per-source that the fingerprint *changes* when a commit lands, an issue is
   relabelled or assigned, a workflow's conclusion flips, a claiming PR closes,
   a draft PR of ours crosses the `abandoned_draft_after_hours` staleness
   threshold (assert this one especially — it is the sole transition that moves
   no other signal, so the `abandoned_drafts` array is the only thing that can
   carry it), a ready PR of ours turns `CONFLICTING` after its base moved (assert
   this one too — like the staleness transition it moves no other fingerprinted
   signal once the base advance is a cycle past, so the `merge_conflicts` array is
   the only thing that can carry it), an item is unblocked or unvoided, a source is
   added to `config.json`, or `prompts/coordinator.md` is edited. Each of those is a
   source of work, and
   any one of them missing from the fingerprint is an unbounded silent stall
   that no other check in this document would catch. Assert too that a
   scheduled workflow rerunning green does *not* change it (see requirement 3b
   — this is where the feature quietly dies), and that a repo whose state could
   not be sampled makes the cycle unfingerprintable rather than skippable.
7. **A blocked verdict round-trips.** Append an `attempt-failed` for a
   selected item, then run a cycle: the Co-Ordinator's input must list that
   item as blocked, with its detail. This is the one check that catches the
   writer and the reader disagreeing about the event key (requirements 33/34)
   — nothing else in the system will tell you they disagree, because both
   halves look correct in isolation and the only symptom is work being
   silently redone.
7a. **The mandatory re-check round-trips too (requirement 18a).**
   `test/cycle-state.test.sh`'s requirement-18a section passes, proving both
   halves the requirement adds on top of check 7's general case. The
   comparison itself — a blocked GitHub issue's `updated_at` against the
   *later* of the block's `ts` and its `recheck_clean_ts` — is the
   Co-Ordinator's own judgement (prompts/coordinator.md, "A blocked issue
   with fresh evidence must be re-read"), not shell code, so the test mirrors
   that documented rule to check the real data `blocked_items` computes:
   with only an `attempt-failed` on record, an issue `updated_at` after the
   block's `ts` reads as due a mandatory re-read and one no later than `ts`
   does not (half 1, "forces the whole-thread re-read"); appending a
   `recheck-clean` folds `recheck_clean_ts` in, and the same, unchanged
   `updated_at` that just read as due now reads as not — a thread that said
   nothing new is not paid for twice (half 2, "stops the next cycle repeating
   it"); moving `updated_at` again past the `recheck_clean_ts` flips it back
   to due, so the marker's suppression lasts only as long as the thread
   stays quiet. Together with check 7, this is the writer
   (`recheck-clean`, requirement 33) and the reader (`blocked_items`'s fold)
   agreeing on both timestamps a blocked GitHub issue carries, the same way
   check 7 catches them agreeing on one.
7b. **An orphaned claim branch is put back in front of the pipeline
   (requirement 17b).** `test/sweep-orphan-branches.test.sh` passes: with a
   stubbed `gh`, a stale moved ref with no PR and no registry entry yields a
   draft PR carrying `pr_label` and a `recovered` action; a stale unmoved
   ref in the same state yields a ref delete and a `released` action; a ref
   with an open PR, a ref with a live registry entry, and a ref younger
   than `abandoned_draft_after_hours` are each left untouched; a registry
   read that fails with anything but 404 leaves the ref alone and says so
   (`warning`, fail closed); a missing label falls back to an unlabelled PR
   loudly; and a backlog past the per-run cap acts on the cap's worth and
   reports the remainder (`deferred`) rather than flooding or staying
   silent.
7c. **Claim visibility is deterministic, both shapes and both directions
   (requirement 3o, issue #175).** `test/claim.test.sh`'s `claims`/`branches`
   section passes: a fresh branch claim's registry entry appears in `claims`'
   output tagged `kind: "branch"` with its item; an entry older than
   `claim_ttl_hours` does not (the staleness escape survives); and `branches`
   lists a live `td/*` ref regardless of its age, including one whose
   registry entry has already aged out — proving the two sources are
   independent, not one gated on the other. `test/noop-skip.test.sh` covers
   the fingerprint half: a fresh entry added to `claimed` changes the
   fingerprint, and an empty `claimed` array canonicalises identically to an
   absent key, so a claim ageing back out of the array changes it too — the
   same silent-stall shape `abandoned_drafts` and `merge_conflicts` close for
   their own transitions.
8. **A no-op Implementor is recorded.** Drive one cycle in which the
   Implementor reports `blocked` without opening a PR: the cycle must exit 0
   having logged an `attempt-failed` carrying that item and the stage's own
   reason — not die part-way, and not log nothing. Under `errexit` this is
   where a helper returning "not found" as a non-zero status silently kills
   the run (requirement 9).
8e. **A stage that leaves a bare fence or a resumable session is recovered,
   not discarded (requirement 9e).** `test/extract-json-result.test.sh`
   passes: a verdict fenced ``` … ``` with no `json` info string, or with a
   different one, parses on the fenced-block fallback exactly as a
   `json`-tagged fence always did, both bash copies and the dashboard's jq
   port agreeing. `test/stage-salvage.test.sh` passes, against a `claude`
   stub that answers differently depending on whether `--resume` is present
   in its argv: `stage_salvage_result` given an `.out` file whose
   `session_id` is set and whose `result` does not parse resumes that session
   and returns the resume's own parsed verdict when the resume's final
   message does parse, logging `salvage` with `outcome: "recovered"`; returns
   nothing and logs `outcome: "failed"` when the resume's message still does
   not parse; and — given an `.out` file with no `session_id` at all —
   attempts no resume, calls `claude` not once, and logs no `salvage` event,
   since there was nothing to spend a resume on.
8a. **A void survives an agent trying to clear it.** Append an `item-void` for
   an item, then an `unblocked` for the same item, then run a cycle: the item
   must still be void and absent from the Co-Ordinator's candidates. This is
   the check that would have caught requirement 9b being collapsed into one
   state, and it fails loudly on a system that looks entirely healthy — the
   log fills with confident, correct-looking events and the same item is
   worked forever. Assert the negative too: `unvoided` *does* clear it, or you
   have built a state no human can escape.
8c. **A void must be earned (requirement 34d).** `test/void-guard.test.sh`
   passes: an entry with no `evidence` — and `null`, `""`, whitespace, `{}` and
   `[]` all count as none — is refused before any API call; an entry whose
   `evidence` is shaped `{ref, path, expect, pattern}` is fetched and tested —
   refused when the fetch fails, or the presence/absence or pattern does not
   hold, or the entry names no repo to resolve against — while a citation that
   does not fit that shape is accepted on the presence test alone. Assert that
   an `absent` claim rests on `404 Not Found` and on nothing else: stub a rate
   limit and an unresolvable `ref`, both of which fail the fetch exactly as a
   real absence does, and both must be refused. That is the difference between
   a checked citation and a fetch nobody looked at the answer of. An entry
   whose repo+item matches a gathered candidate whose PR still changes files is
   refused naming that PR; a PR the API will not answer for is refused as
   uncorroborated; and an evidenced entry with an empty PR diff, or with no PR
   to check at all, is allowed. Assert the citation test directly: an entry
   citing a real, fetchable PR whose body and branch name neither one mentions
   the voided item is refused as a fabricated citation; the identical entry
   citing the pull request that genuinely implements the item is allowed; and
   the same shape holds for a cited commit — refused when it is not an
   ancestor of the default branch, or when it is but neither its message nor
   any pull request associated with it names the item, and allowed when one of
   those does. Assert the finishing sources are not caught by it: an item
   `pr-<n>-abandoned-…`, `pr-<n>-review-…` or `pr-<n>-conflict-…` citing pull
   request `<n>` is allowed on the id alone, while the same item citing a
   different pull request is refused. Assert it runs with `repos: []` exactly
   as the Enabler's and the Implementor's calls do. Then drive it end to end: a
   Co-Ordinator returning a `voided` entry the guard refuses must produce an
   `attempt-failed` for that item and **no** `item-void`, and the next cycle
   must list the item as blocked rather than void. The negative matters as
   much — assert a well-formed void is still recorded, or the guard has
   quietly abolished a feature requirement 18 depends on to avoid full
   Implementor runs.
8d. **A `pr-ready` event means the pull request is not a draft (requirement
   31a).** `test/handoff.test.sh` passes: a non-draft PR reports `already`
   without calling `gh pr ready`; a draft is flipped and reports `flipped`; a
   flip that exits 0 and changes nothing reports `failed`; and a PR whose state
   cannot be read reports `failed` rather than being assumed handed off. Then
   drive a cycle whose Reviewer answers `{"status": "ready"}` on a PR it left as
   a draft: the cycle must log a `warning`, take the PR out of draft itself, and
   log `pr-ready` with `handoff: "script"`. Assert against GitHub, not against
   the log — the whole defect was a log that agreed with a Reviewer nobody had
   checked.
8d-i. **A handed-off pull request is in somebody's review queue (requirement
   31b).** `test/handoff.test.sh` passes for `confirm_review_requested`: a PR
   nobody is blocking reports `none` and asks for nothing; a blocking reviewer
   with no request pending is re-requested and reported `requested`; one already
   pending reports `already` without posting again; a reviewer whose
   changes-requested is followed by a `COMMENTED` review is still asked, and one
   whose is followed by an `APPROVED` is not; a bot is never asked; a POST that
   exits 0 and changes nothing reports `failed`; and an API that will not answer
   reports `failed` rather than an assumed `none`. Then drive a cycle on a
   `review-feedback` item end to end: the `pr-ready` event must carry
   `review_requested` and the reviewer's login, and GitHub — not the log — must
   show the review pending. Assert the negative too, because it is the whole
   point of the requirement's bound: `reviewDecision` must still read
   `CHANGES_REQUESTED` and the PR must still be un-mergeable afterwards. A
   re-request that cleared the block would have moved the human gate, not
   rung it.
8e. **A pull request nobody could hand off reaches the Enabler, not the human
   (requirement 32a).** Drive a cycle whose Reviewer answers `blocked` (and again
   with the legacy `needs-human`): the cycle must log an `attempt-failed` for the
   item carrying the PR's `pr_url`, so that the next cycle lists it blocked and,
   after `enabler_after_coordinator_cycles`, eligible — with the `pr_url` present
   in the Enabler's runtime input. Assert the PR is *not* commented on with
   anything telling a human it is theirs, and that a bare `stage-end` is no
   longer the only record: that shape named no item, pinned no state, and is what
   let a finished draft sit unseen. Then assert requirement 32b's other end: an
   Enabler `unblocked` verdict carrying `complete_handoff: true` takes the PR out
   of draft and logs `pr-ready` with `handoff: "enabler"`, while the same verdict
   on an item with no `pr_url` is ignored without error.
8e-i. **A stage that says nothing still names its pull request (requirement
   9).** `test/handoff.test.sh` passes its `pr_url_for_branch` assertions: an
   open PR on the claimed branch is found and its URL returned; a branch with
   no open PR yields nothing; an unreachable API yields nothing rather than a
   non-zero return, which under `errexit` would kill the cycle ahead of the
   failure it is describing; and an empty repo or branch asks GitHub nothing at
   all. Then drive an Implementor that exits 0 having pushed a draft PR,
   written no `.git/agent-ops-pr-url` breadcrumb, printed no URL and ended with
   prose instead of a JSON object: the `attempt-failed` must still carry that
   PR's `pr_url`, the PR must still receive the stage-failure comment, and the
   claim must be released as `have-pr` rather than `no-pr`. Assert the URL came
   from the branch and not from the stage — that is the whole point, and a test
   whose Implementor helpfully left a breadcrumb passes without exercising
   anything.
8f. **A human can reopen a void from where they actually are (requirement
   34f).** `test/unvoid-label.test.sh` passes: a request clears a void recorded
   before the label; a void recorded after it, or at the same instant, stands; a
   second cycle over the same label clears nothing; and a request cannot reach
   another repo's identically-named item, while a void carrying no repo is
   clearable from any. Then drive it end to end: apply the label to a pull
   request naming a voided item and run a cycle — the item must be absent from
   the Co-Ordinator's `void` list *in that same cycle*, not the next, and the
   label must still be on the pull request afterwards. Assert the negatives,
   which are the whole risk: run two further cycles and confirm no second
   `unvoided` event is written, then record a fresh void on the same item and
   confirm the still-present label does not clear it. A label that keeps
   clearing is a permanent exemption, and its only symptom is an item that never
   stays void.
8b. **The two states are visible apart, and so is "waiting on you".** A human
   looking at the monitor can tell "waiting on something" from "there is nothing
   to do here" without reading the log. If both render as one list, the operator
   cannot tell an item needing their help from one needing nothing, which is how
   a stuck pipeline and a healthy one come to look identical. Within the blocked
   list, an item with an open escalation (requirement 36a) is distinguishable
   from one the pipeline is still working on itself — the dashboard's blocked
   table carries the issue link, or the Enabler's last verdict where there is no
   open issue (`docs/DASHBOARD-SPEC.md`). Otherwise the one row on the page that
   is addressed *to the reader* looks exactly like the rows that are not.
8g. **An item in both states reads as void, everywhere (requirement 34h).**
   `test/cycle-state.test.sh` passes: `open_blocked_items` drops a blocked item
   that a later `item-void` covers, keeps one whose void was itself cleared by
   an `unvoided`, honours a repo-less void across every repo, and returns the
   entry otherwise untouched — while `blocked_items` beside it still reports the
   raw requirement 34 set, since the Co-Ordinator is owed both. Then assert it
   through the Publisher: `test/publish-dashboard.test.sh` passes with a log
   carrying a blocked-and-void item, which must appear in `data.js`'s `void[]`
   and **not** in its `blocked[]`. Assert the double negative too — an ordinary
   block beside it is still listed — because a subtraction that over-reaches
   empties the one panel that says the pipeline is stuck, and an empty panel and
   a healthy pipeline look identical.
8h. **A block outlives its impediment, never its work (requirement 34i).**
   `test/work-gone.test.sh` passes, and every assertion in it is made in both
   directions, because the two ways this can be wrong are not alike. Too eager
   clears a block out from under real work and costs a full cycle an hour until
   somebody notices: so a closed issue, a merged pull request, a `resolved` or
   `not-debt` register item, a project-review recommendation named by a merged
   pull request, and an implementation-plan task checked off in its document
   each clear their block, while an **open** issue, an **open** pull request, an
   **open** register item, a recommendation no merged pull request names, and an
   **unchecked** (or ambiguous) plan task each do not, and every unreadable
   shape — a repo missing from the digest, a digest carrying `ok: false`, an id
   no item file claims by `id` or `legacy-id`, an id two of them claim, a
   register/review/plan read that failed — clears nothing at all. Too shy is
   the silent failure this requirement exists to end: so assert the legacy id
   (`TD26072401`) resolving through the renamed file that carries it, and assert
   that the classes still left to the Enabler stay blocked — above all a
   `dependabot-alert-N`, whose source degrades to `[]` on an API error and would
   otherwise read as "every alert is fixed", and a `register-hygiene-<hash>`
   item, which has no completion signal at all. `scripts/gather-register-status.sh`,
   `scripts/gather-review-status.sh` and `scripts/gather-plan-status.sh` each run
   for real against a stubbed `gh` in that file, so what is asserted is the
   shipped scripts rather than a copy of their logic.
8i. **A structured dependency is held and released without a model ever
   re-reading it (requirement 34j).** `test/dependency-gate.test.sh` passes:
   `dependency_refs` parses a same-repo `#195`, a cross-repo
   `owner/repo#42`, several references on one comma-separated line, and
   references spread across the body and more than one comment, is
   case-insensitive on the keyword, tolerates a leading list marker, ignores
   a bare number with no `#`, and returns `[]` for text with no `Blocked-by:`
   line at all; `dependency_clearances` clears a blocked issue present in the
   reshaped `issues` map with a `Blocked-by:` line still in its thread, and
   clears nothing for a blocked issue absent from that map, present but with
   no `Blocked-by:` line, or of a shape other than a bare issue number. Then
   the #196–#199-shaped scenario, end to end against a stubbed `gh`: an issue
   whose body reads `Blocked-by: #195` while #195 is open is absent from
   `scripts/gather-issues.sh`'s candidates; the same issue, already recorded
   `attempt-failed`, stays in the open blocked set that cycle. Flip #195 to
   closed and run both again — the issue reappears in `gather-issues.sh`'s
   candidates *and* `dependency_clearances` produces its release — asserting
   both halves clear within the one cycle the dependency resolved in, and
   that neither ever spent an Enabler engagement or a Co-Ordinator judgement
   doing it.
8j. **A corroborated void closes the GitHub object it names, exactly once
   (requirement 34k).** `test/close-void-github-items.test.sh` passes against
   a stubbed `gh`: an open issue or an open, obsolete pull request named by a
   void from any of the three writers — Co-Ordinator, Enabler, Implementor,
   all corroborated by requirement 34d (issue #243) — is closed with a
   comment carrying the void's own evidence; a void carrying no `stage` at
   all is left entirely alone with no API call made, the fail-closed default
   for an entry no writer this script recognises corroborated; an object
   already closed is reported (`closed_by: "already"`) rather than touched
   again; a shape naming no GitHub object (a register id) is left entirely
   alone; a void carrying no reason still reaches the comment with its
   evidence intact; and the per-call action cap defers rather than floods.
   `test/cycle-state.test.sh`'s `void_object_closed_items` section passes:
   once a `void-object-closed` event exists for an item, it is excluded from
   every later pass — asserted by driving the same item through the extract
   twice and confirming the second call still yields the recorded set, the
   fact that stops the sweep re-closing an object a human has since reopened
   by hand rather than through `unvoid_label`.
8k. **A void'd register row becomes a candidate even when `td-check.pl` finds
   nothing wrong (requirement 34l).** `test/register-hygiene.test.sh`'s void
   section passes against the shipped `scripts/gather-register-hygiene.sh`
   and a real `td-check.pl` run: a consistent register stays `[]` until a
   void names one of its `open` items, at which point exactly one candidate
   appears carrying a `VOIDED STATUS` problem line quoting the void's own
   reason; a void naming an item already `resolved` adds nothing; a void
   naming a file that does not exist adds nothing; and a genuinely drifted
   register's own `td-check.pl` problems and a `VOIDED STATUS` problem
   coexist in the same one candidate rather than competing.
8l. **A closing keyword is enforced, not requested (requirements 23b, 25a,
   17c).** `test/check-closing-keyword.test.sh` passes: a PR body with no
   `agent-ops:closes-issue` marker and no `agent/<N>` head branch always
   passes; a marker with no matching closing keyword for the same number
   fails, naming it; an `agent/<N>` head branch with no marker for `N` fails
   naming the marker, and with no keyword for `N` fails naming the number —
   presence is demanded by the branch anchor, not requested of the prompt —
   while a non-numeric agent branch (`agent/td…`, `agent/register-hygiene-…`)
   and a `td/` branch demand nothing; a keyword for the *wrong* number does
   not satisfy a marker (`Closes #199` does not satisfy `item=198`); every
   recognised keyword form (`Closes`/`Fixes`/`Resolves`, past tense, a colon,
   case-insensitive, Markdown emphasis around it) passes; a word merely
   ending in a keyword ("unclosed #198", "discloses #77") does not; and
   multiple markers on one body are checked independently — one satisfied
   marker never excuses another. `test/sweep-closed-issues.test.sh` passes against a stubbed
   `gh`: a merged, marker-carrying pull request whose issue is still open is
   closed with the merge cited as evidence; a merged, markerless pull
   request whose head branch is `agent/<N>` closes issue `N` the same way,
   the branch cited as the anchor instead of the marker; an issue GitHub
   already closed (or a PR with neither marker nor numeric agent branch) is
   left untouched, with no extra API call made for the unnamed case; an
   issue GitHub reports `state_reason: "reopened"` is left alone and the
   skip reported, so a human's re-open is never undone on the hour; and the
   per-call action cap defers rather than floods.
8m. **The closing-keyword check blocks, not just reports (requirement
   25a).** The one piece of requirement 25a that no file in this repository
   carries is the repo setting that makes a red check a blocked merge, so
   it is verified against GitHub directly rather than by any test here:

   ```
   gh api repos/Poetic-Poems/agent-ops/rulesets/18857310 \
     --jq '.rules[] | select(.type == "required_status_checks")
           | .parameters.required_status_checks[]
           | select(.context == "closing-keyword")'
   ```

   prints `{"context": "closing-keyword", "integration_id": 15368}` — the
   context required by the active `default` ruleset targeting the default
   branch, pinned to the GitHub Actions app. An entry missing entirely means
   the check reports without blocking, which is the exact gap PR #256's
   review caught by hand; an entry without the `integration_id` pin can be
   satisfied by any GitHub App reporting a check of that name. Nothing in
   this repository changes when the ruleset does, so this check is manual
   until a deterministic reader exists (TD-PPagop-26080802 proposes a
   warn-level `doctor.sh` check).
9. A cron-style invocation from a minimal environment can resolve `claude`
   and run `claude -V` (or a tiny `claude -p` smoke test) successfully.
10. One supervised full cycle (`--once`) against whichever repo the ordering
    picks: it produces a labelled, mergeable, ready-for-review PR with the
    originating register updated and a complete log trail. Report the PR URL
    to the human rather than merging anything.
11. **The eligibility rule round-trips through the real extract
    (requirement 35a).** `test/enabler-eligibility.test.sh` passes: an
    `attempt-failed` plus `enabler_after_coordinator_cycles` synthetic
    coordinator `stage-end`s (`exit_code: 0`) makes the item eligible with reason
    `threshold`, one fewer does not, and a `stage-end` that timed out or belongs
    to another stage does not count at all — that last assertion is the one that
    catches a rule keyed on an event nobody emits, which would engage nothing,
    forever, while reading correctly. An examined item is not re-examined; an
    `item-void` for the same item excludes it; a re-block re-enters via
    `threshold`; and every boundary is asserted on both sides of itself, because
    too permissive spends Opus in a loop and too strict never escalates at all,
    and both look like a quiet pipeline.
11a. **The fingerprint wakes a quiet fleet at the threshold, and lets it go
    quiet again (requirement 35b).** In `test/noop-skip.test.sh`, per the same
    discipline as the abandoned-drafts trap: an item entering the eligible set
    changes the fingerprint, its `reason` flipping to `issue-closed` changes it,
    the set emptying after an engagement changes it, and an input recorded before
    the Enabler's keys existed canonicalises exactly as one carrying them empty.
    Without the first three, the escalation path comes due on a quiet week and
    nothing runs until the forced recheck; without the fourth, adding the feature
    would appear to change every replayed cycle.
11b. **An open escalation is invisible to the Co-Ordinator and to the Enabler.**
    Assign an issue and confirm requirement 16.4 excludes it from candidacy, and
    that the same issue's number in the repo's open-issue digest makes its item
    Enabler-ineligible. Then the half that closes the loop: with the issue gone
    from the digest, the item is eligible with reason `issue-closed`, and after
    the verification's examined event it is not eligible again. This is the check
    that the protocol the issue promises its reader — close it and the work
    resumes — is the protocol the code implements.
11d. **An under-specified item is reported, blocked, refined and carried
    forward (requirements 16a, 34e, 35d, 36b, 3h).**
    `test/needs-refinement.test.sh` passes: a well-formed report becomes a
    coordinator-stage `attempt-failed` marked `kind: "needs-refinement"` whose
    `unblock_condition` is the report's `missing`, while an entry short of any
    required field is dropped; the label is projected onto an issue-type item
    and not onto a tech-debt one, and is found for removal when the block clears
    and when the item is voided; such a block is Enabler-eligible on the
    ordinary `enabler_after_coordinator_cycles` threshold and its entry carries
    `kind` and `refined_before`; the per-engagement cap keeps ordinary items and
    drops refinement items beyond it, `0` removing the class entirely; an
    `unblocked` verdict's `refined_spec` becomes an `item-refined` event that
    reaches the next cycle's `refinements` map, and a void item's does not; and
    a second refinement of an already-refined item is refused unless a human has
    just closed an escalation about it. Both directions matter here for the same
    reason as requirement 35a's rule: too eager and two models re-specify each
    other's work forever, too shy and the item starves exactly as it did before
    any of this existed.
11e. **A human's own label is read back, and only where this mechanism put it
    (requirement 34g).** `test/needs-refinement.test.sh` passes:
    `refinement_hand_flag_new` turns a labelled, open issue with no existing
    block — of any kind — into a fresh entry, and reports nothing for one
    already blocked (no duplicate for the same label on the same item) or for
    a labelled issue that is closed; `refinement_hand_flag_fields` marks what
    it builds `hand_flagged: true` with no `unblock_condition`;
    `refinement_hand_flag_cleared` maps a `hand_flagged` block whose issue has
    lost the label — open or closed — to an `unblocked` candidate, but leaves
    alone both a block still carrying the label and a block that is not marked
    `hand_flagged` (the Script's own projection from a Co-Ordinator's report),
    even when that one's label is also missing — proving the one-way rule
    requirement 34e states for that population still holds.
11c. **A broken Enabler cannot break a cycle (requirement 37).** With a stubbed
    stage that times out, exits non-zero, or (after requirement 9e's salvage
    resume also fails to parse) returns prose instead of JSON: the
    cycle still exits 0, logs `stage-end` and one `warning`, writes **no**
    `unblocked`, `item-void`, `escalated` or `enabler-examined` event. The
    `warning` names every item the discarded engagement was given
    (`items: [{repo, item}, …]`), and each of those items' 35c tombstone is
    `expire`d rather than released — `test/claim.test.sh` passes: an expired
    entry's registry file still exists with its `ts` backdated and every
    other field unchanged, and a `gc` run immediately afterward retires it.
    Assert the ordering too — the engagement's events precede
    `cycle-end` — and that a limit phrase in that transcript produces an ordinary
    `limit-hit` rather than being swallowed with the rest of the failure.
33a. **The per-stage metering record matches `docs/METERING-SCHEMA.md`
    (requirement 33a).** `test/metering.test.sh` passes: `lib/metering.sh`'s
    `metering_fields` derives `model`, `cost_usd`, `duration_ms`, `num_turns`,
    `is_error` and `tokens{input,output,cache_creation,cache_read}` from a
    single-model envelope and from a multi-model (subagent) envelope, summing
    `tokens` across every `modelUsage` entry in the latter; a genuinely zero or
    `false` value survives rather than collapsing to `null`; a missing, empty
    or unparseable out-file degrades the envelope-derived fields to `null`
    while `model` keeps the id it was passed; and an envelope whose
    `modelUsage` entries are unreadable still yields one valid object, so no
    envelope can cost a `stage-end` event its `stage` and `exit_code`. Both
    `agent-cycle.sh` and `review-cycle.sh` source
    `lib/metering.sh` and merge its output into every `stage-end` /
    `review-stage-end` event they log, so this one function's correctness is
    what "both pipelines emit conforming records" reduces to.
1c. **The configuration matches its schema, and the schema is an enforced
    startup gate, not merely a checkable one (requirement 1b).**
    `test/config-schema.test.sh` passes: this repository's own `config.json`
    validates, so a key added to the config without a schema entry fails
    immediately; every keyword the schema uses is one `lib/config-schema.sh`
    implements, asserted by reading the keywords back out of the schema
    rather than from a list maintained beside it; each keyword class is
    exercised with a value that must be rejected, naming the path that is
    wrong; and `scripts/doctor.sh` reproduces the two surviving cross-key
    guards (the Enabler's assignee, the implementation-plan path) as a
    `fail`, its silent-breach combinations as a `warn`, and a config that
    will not parse as exit 2 with nothing downstream attempted. Beyond the
    library level, `agent-cycle.sh` and `review-cycle.sh` themselves are
    driven end to end against a schema-violating config — with `claude` and
    `gh` stubbed so reaching either would itself mean the gate had failed —
    and asserted to exit non-zero naming `config.schema.json`, before either
    stub is ever reached; the retired `nice` and `prompt_overrides` guards'
    own wording is asserted gone in favour of the schema's, and the
    surviving Enabler-assignee guard is asserted to still fire on a config
    the schema itself accepts. Every case is a mutation of the shipped
    configuration, run against the shipped scripts, so what is asserted is
    the product rather than a restatement of it. `--offline` throughout: no
    assertion here needs the network.
1d. **The prose configuration tables are generated from the schema, and
    regenerating them is gated (requirement 1b, component 16).**
    `scripts/render-config-table.sh` with no arguments run against this
    repository's own `config.schema.json`, `README.md`,
    `docs/IMPLEMENTATION-PIPELINE-SPEC.md` and `docs/REVIEW-PIPELINE-SPEC.md`
    leaves every file byte-identical to what is committed — regenerating a
    clean tree is a no-op — and `--check` exits 0 against it; `git diff`
    confirms nothing moved. `test/render-config-table.test.sh` passes: a key
    present in a fixture schema and absent from a region is added, a
    hand-edited row is restored, `--check` exits non-zero naming the file,
    the region and the first differing key on a stale region and zero on a
    fresh one, a `|` inside prose survives escaped, four distinct
    `x-docs.value` rows render verbatim, an `x-docs.value` keyed per
    audience gives each document its own value cell and falls through to the
    schema `default` for an audience it does not name, a key carrying no
    `x-docs` for an audience falls back to `description`, and a region whose
    first two lines are not a header row and a delimiter row is refused
    rather than rendered. A note over 500 characters is truncated at a word
    boundary — never inside a code span (single- or double-backtick
    delimited, the latter's content free to carry a literal backtick) or a
    link, each covered by its own fixture note — with its full text
    reproduced in the matching Extended notes subsection, including for a
    dotted (`schedule.*`-style) key; a document with two Extended notes
    headings that would slug the same is refused, and so is a document
    missing either half of a `config-table:notes` marker pair. A note that
    is an array of blocks (#220) — two paragraph strings; a paragraph, a
    `list` block and a paragraph; a paragraph, a `code` block and a
    paragraph, each over the
    cap — flattens to one space-joined table-cell line (the list's items
    comma-joined, the code's newlines turned to spaces and backtick-wrapped)
    and, separately, renders as real block Markdown in the Extended notes
    subsection: a blank line between paragraphs, real `- ` list items, a
    real fenced code block, each still blank-line-separated from its
    neighbours; a `list`-only or `code`-only note under the cap degrades the
    same way in its cell with no Extended notes subsection generated at all.
    `.github/workflows/config-table.yml`
    runs `--check` on every pull request, so a schema edit landing without a
    matching doc regeneration (or the reverse) fails CI rather than drifting
    the way `unvoid_label` and `state_local_cycles_retained` both did before
    this requirement existed.
1m. **`doctor.sh` checks write access, Claude credentials, the rendered
    crontab and `nice` reordering, and `--offline` still runs the two that
    need no network (requirement 1b, component 14).** `test/doctor.test.sh`
    passes, against a stubbed `gh` and `claude` on `PATH` — the seam
    `doctor.sh` leaves for both, carrying no override variable for either —
    run without `--offline` so these checks are actually exercised, with
    nothing on `PATH` able to reach a real network regardless: a
    `.permissions.push` of `true` is `ok`, `false` is `fail`, and an absent
    field is `skip`; `.archived: true` is `fail` even when `.permissions.push`
    is `true`; `claude auth status --json` reporting `loggedIn: true` is `ok`,
    `loggedIn: false` is `fail` — distinguished from a parse failure, since
    `false` is a legitimate answer rather than evidence the JSON could not be
    read — and a `claude` with no `auth` subcommand is `skip`; the real
    `deploy/docker/render-crontab.sh` run against a config whose
    `schedule.excluded_minutes` rules out every minute is `fail`, the same
    renderer run against a trimmed copy of the repository missing
    `crontab.tmpl` is `skip`, and a clean render is `ok` naming the node and
    the cycle, review and heartbeat minutes the config asked for, and whether
    the cycle minute came from an explicit, allowed `CYCLE_MINUTE` or was
    hashed from the node's name; a second `ok` line names the background
    timer minutes (`state_sync_push_minutes`, `state_sync_fetch_minutes`,
    `log_rotation_minute`) the config asked for; a repository with a
    non-zero `nice` gets its own line naming the value and
    the multiplier, and one with every repository at `nice` 0 prints no line
    at all; and `--offline` still renders the crontab and reports `nice`
    reordering while reporting write access and Claude credentials as
    `skip`. Must pass `shellcheck`.
6h. **The pipeline creates the labels it applies, and touches no others
    (requirement 6a).** `test/labels.test.sh` passes against a stubbed `gh`
    that records every invocation and refuses a duplicate the way GitHub
    does: an empty repository receives every label of its role and each is
    reported created; a second pass over the same repository reports nothing;
    a partly-labelled one receives only what it lacks; a name differing only
    in case counts as present, since GitHub's uniqueness is case-insensitive;
    a label switched off by an empty configured name is not created; a
    renamed label is created under the configured name. The two safety
    properties are asserted from the request log rather than from the return
    value — **no `PATCH`, `PUT` or `DELETE` is ever issued**, and the only
    requests made at all are listings and creates — and the failure paths
    are asserted not to escalate: one refused create still creates the rest
    and returns 0, an unlistable repository returns 1 having created nothing
    and claimed no failures it did not observe, and a guarded call survives a
    total failure under `set -e`.

38. **Human-visibility (requirements 38a–38c).** `test/handoff.test.sh` passes:
    `ensure_human_reviewer` re-requests review from whoever has ever reviewed
    the pull request (any state) in preference to `assignee`; falls back to
    `assignee` only when nobody ever has; strikes the pull request's own author
    off both lists before asking, so an author's `COMMENT` review on their own
    pull request neither becomes a request target nor 422s the request for the
    human beside them, and an author-only reviews list is a `skip`; `skip`s
    while something is genuinely `CHANGES_REQUESTED`-blocking, and while the
    pull request is a draft; and an unreadable reviews list or pending list is
    `failed`, never an assumed `skip`. `test/needs-refinement.test.sh` passes:
    `refinement_block_fields`'s third argument records `needs_refinement_assignee`
    independent of the label argument; `refinement_assignee_add`/`_remove` each
    make one `gh issue edit --add-assignee`/`--remove-assignee` call and fail
    when the assignee is not a collaborator, the same way the label functions
    fail when the label does not exist; `refinement_assignee_project` reads
    the issue's assignees before writing — a pre-existing assignment is
    `present` (untouched, unrecorded), an absent one is added and `added`,
    an unreadable list is applied best-effort but `unrecorded`, and a
    non-collaborator is `failed`; and `refinement_assignee_targets`
    finds exactly the assigned issue, scoped by repo the same way
    `refinement_label_targets` is, surviving a void the same way. `test/sweep-human-visibility.test.sh`
    passes against a stubbed `gh`: a pull request with nothing blocking it and
    no known reviewer yet is both re-requested (from the approver) and, when
    also approved, mergeable, green and idle past `human_nudge_idle_hours`,
    nudged in the same pass; a `CHANGES_REQUESTED`-blocked pull request has
    no review request made for it and is never nudged — the sweep never
    calls `confirm_review_requested` (requirement 38c's design note), and
    the nudge's own `reviewDecision == APPROVED` gate holds it off; a pull
    request nudged once already is not nudged
    again even when still idle; an unmergeable, not-yet-green, or not-yet-idle
    approved pull request is never nudged, and neither is one with an empty
    check rollup; `human_nudge_idle_hours: 0` disables the nudge while leaving
    the review-request self-heal unconditional; and a listing, a view, or a
    reviews read that fails is a `warning`, never silence. Confirm the nudge
    comment carries the visible attribution header and both markers
    (`agent-ops:pipeline-comment` and `agent-ops:human-nudge`).

## Host provisioning (human steps)

All of this is in place on the current host; it is needed again only when
standing the system up on a new machine.

1. Install the standalone CLI: `curl -fsSL https://claude.ai/install.sh | bash`
   (or `npm install -g @anthropic-ai/claude-code`). Verify headless auth
   works: `claude -p "Reply with OK" --model claude-haiku-4-5-20251001`.
   Then prove that cron can invoke Claude by running it in a minimal
   environment with the same PATH shape cron will use, e.g.
   `env -i HOME="$HOME" PATH="$HOME/.local/bin:$HOME/.claude/local:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /bin/bash -lc 'command -v claude && claude -V'`.
   If `command -v claude` fails, create a launcher in `~/.local/bin` or add
   the correct PATH to the crontab before continuing.
2. Enable cron in WSL: add to `/etc/wsl.conf`
   `[boot]` / `command = "service cron start"` (requires sudo), then restart
   WSL (`wsl --shutdown` from Windows). Alternative if preferred: a Windows
   Task Scheduler job running
   `wsl.exe -u wallen -e $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh` hourly.
   Either way, cycles only run while the machine is awake — a missed cycle
   simply waits for the next tick, which is harmless.
3. Create the label in both repos:
   `gh api -X POST repos/Poetic-Poems/<repo>/labels -f name='autonomous-agent' -f color='ededed' -f description='PR raised by the autonomous agent system'`.
   If your `gh` version already supports `gh label create`, that form also works; the API form above is the most compatible fallback.
3c. Create the Enabler's escalation label in both repos, the same way:
   `gh api -X POST repos/Poetic-Poems/<repo>/labels -f name='enabler-escalation' -f color='b60205' -f description='The autonomous pipeline is blocked and needs a human to act'`
   (`enabler_escalation_label`, requirement 36a). Without it an escalation is
   still raised — the create is retried unlabelled — but it arrives with only
   the assignment to distinguish it, so the human's filter and the duplicate
   guard both lose their handle.
3d. Create the refinement label in both repos, the same way:
   `gh api -X POST repos/Poetic-Poems/<repo>/labels -f name='needs-refinement' -f color='fbca04' -f description='The autonomous pipeline cannot tell what done would mean for this item'`
   (`needs_refinement_label`, requirement 34e). Without it the block is still
   recorded and the item still reaches the Enabler — the projection is a
   courtesy to whoever is browsing the issue list, not the record — but the
   Script logs a warning each time it cannot apply it.
3a. Enable the security work sources on both repos so the alerts the
   `security`/`code-quality` sources read actually exist: turn on the
   Dependabot alerts and code-scanning (CodeQL) features (Settings → Code
   security, or the equivalent org policy — free for public repos; requires
   GitHub Advanced Security for private ones). The `gh` token must be able to
   read `repos/<slug>/dependabot/alerts` and
   `repos/<slug>/code-scanning/alerts` (the `security_events` scope, or
   `repo` on a classic token). If a feature stays off, `gather-findings.sh`
   simply returns no findings for it and the rest of the pipeline is
   unaffected.
4. Create `Poetic-Poems/agent-ops` and clone it to
   `~/Code/Poetic-Poems/agent-ops`.
5. After the acceptance checks pass, install the crontab line.

## Cost profile

A worst-case cycle is one small Haiku selection pass, one Sonnet
implementation (the dominant cost), and one review — Sonnet by default, Opus
only when the work graded itself `complexity:high` (requirement 8a), which the
rubric of requirement 26a confines to the minority of PRs whose contents
warrant it; the reviewer `stage-start` events carry the grade, so a creep
toward `high` that would erode this bound is auditable in the log. Stand-down
cycles cost nothing but a few `gh` calls — except under an *estimated*
usage-limit stand-down, where each hourly cycle also spends the 2.1b probe.
That spend is self-limiting from both ends: while the limit is real the
probe's answer is the limit message, which serves no tokens and costs
nothing, and the first answered probe (a fraction of a cent of
`implementor_model_trivial`) retires the stand-down fleet-wide, so at most
one probe per stand-down is ever paid for. Because back-pressure caps open agent PRs
at `max_open_agent_prs`, sustained spend is bounded by the rate at which the
human merges — the system cannot run ahead of its only consumer.

The floor matters as much as the ceiling, because it is paid on every quiet
day and nothing about it looks like waste. Before requirement 3b, an idle
repository still bought 24 full Co-Ordinator passes a day, each one reading
both repos and concluding, correctly and expensively, that there was nothing to
do (measured: ~2m35s of Haiku per pass against these repos). The no-op
short-circuit replaces those with a handful of `gh` calls and a hash, leaving
one forced pass a day (`none_selected_recheck_hours`) as the safety valve —
roughly a 96% cut in the idle floor, and no change at all to a busy day, where
every cycle has something to fingerprint that moved.

The Enabler is the one stage that spends a top-tier model, so what bounds it is
worth stating as a number rather than a hope. Nothing is engaged until an item
has survived `enabler_after_coordinator_cycles` selection passes; a claim that is
never released (requirement 35c) means at most one engagement per item per
`claim_ttl_hours` even when everything fails; and an examined item is not looked
at again for `enabler_recheck_hours`. So the ceiling for an item that is
permanently stuck is **one Opus pass every 72 hours**, and every item eligible at
the same moment shares a single pass. In the steady state the cost is therefore
near zero — a fleet with nothing blocked engages nothing at all — and it rises
only when the pipeline is genuinely stuck, which is the one situation in which
paying for a careful answer is obviously worth it. The comparison that matters is
not against an idle cycle but against the alternative: an item needing a human
sat blocked indefinitely, and every cycle in between spent a Co-Ordinator pass
re-reading and re-skipping it.

## Design decisions

Recorded so a future reader knows they were deliberate, not accidental.
History and superseded approaches belong here (and in Gotchas), never in the
requirements above, which state only what is.

- **The Script orchestrates every launch; the Co-Ordinator only selects.**
  Per-stage timeouts, clean kills, and restartability come free from the
  process model, and the cheap Co-Ordinator session is not held open while
  an implementation runs for an hour.
- **Agents work in ephemeral clones**, never in the user's working copies
  under `~/Code`, which the user may be editing at any moment. This is the
  multi-agent ways-of-working rule shared by all Poetic repositories: every
  agent — autonomous or interactive — makes its own dedicated clone from the
  default branch before commencing any changes, and never assumes the default
  branch still matches what it cloned when it opens the pull request.
- **Draft-PR claiming is fused with the review flow**: the Implementor's
  draft PR is simultaneously the repos' standard claim marker and the
  Reviewer's input; the Reviewer flipping it to ready is the hand-off to the
  human gate.
- **An abandoned draft PR is itself a work source.** Draft-PR claiming (above)
  has a failure mode: a stage that dies mid-implementation leaves its draft PR
  behind as a claim nobody will ever finish, silting a back-pressure slot until a
  human notices. Rather than rely on that, the `abandoned-drafts` source
  (requirement 3e) treats a draft this system raised, still open and untouched for
  `abandoned_draft_after_hours`, as selectable work — the pipeline finishes its own
  stalled drafts. It ranks fifth, after security, urgent issues, review-feedback
  and merge-conflicts, and ahead of
  all fresh work (requirement 15c): finishing beats starting, and it turns a slot
  silted with a dead draft into a PR a human can merge; under back-pressure it is
  one of the three
  finishing sources the cycle narrows to (requirement 2.2a). Four choices make it
  safe: the draft/label/branch filter keeps it to *our* stalled work (never a
  human's PR, never a ready one); the ref is scoped to the head SHA, so a
  re-abandoned draft that has since gained commits is a new item rather than one
  stuck behind an old block; the clock is last **real** activity rather than
  GitHub's raw `updatedAt`, so the pipeline's own label edits and marked comments
  (`lib/pipeline-marker.sh`) cannot make a genuinely stalled draft look worked
  (TD26072605 — see the Gotchas table); and, because its candidacy uniquely turns
  on the clock, the candidate array is fed to the no-op fingerprint verbatim so
  the staleness transition — which moves no other signal — still wakes the
  pipeline (requirement 3b).
- **A merge conflict on an otherwise-ready PR is itself a work source.** A PR this
  system raised can go green, be reviewed, even be approved, and then conflict when
  the base advances underneath it — leaving a finished PR a human cannot merge and
  a back-pressure slot nothing will clear. The `merge-conflicts` source
  (requirement 3g) treats such a PR — open, non-draft, ours, `mergeable`
  definitively `CONFLICTING` — as selectable work: the pipeline rebases and
  resolves its own conflicts. It ranks fourth, after security, urgent issues and
  review-feedback,
  and ahead of all fresh work (requirement 15d): a human is waiting to land it and
  nothing else on it can proceed first; under back-pressure it is one of the three
  finishing sources the cycle narrows to (requirement 2.2a). It deliberately does
  *not* complete the underlying item — that is the eventual merge's job — so it
  touches only what the rebase requires. Two choices make it safe: `mergeable` must
  be `CONFLICTING`, never the asynchronously-computed `UNKNOWN`, so it never
  rebases a PR that may not conflict; and, because its candidacy turns on the base
  moving — which no signal on the PR itself carries — the candidate array is fed to
  the no-op fingerprint verbatim so the conflict appearing still wakes the pipeline
  (requirement 3b), the same fix abandoned-drafts needs for its clock-based
  candidacy.
- **A register that lies about itself is repaired by the pipeline, and prevented
  by CI — two layers, because one was demonstrably not enough.** The register
  now keeps one convention throughout: a `tech-debt/<id>.md` file per record,
  resolving meaning a frontmatter flip with the body kept in place. It did not
  start that way. Every repo here used to keep its deferred work in a legacy
  single `TECH-DEBT.md` — live bodies under `## Current Items`, a permanent
  Ledger row for every id ever allocated, resolving meaning removing the body
  and keeping the row. In July 2026, in that format, twelve items across the
  three repos were found flipped to `resolved` with their bodies still in
  place — `## Current Items` advertising a dozen pieces of work already done,
  to humans and to this pipeline alike. `prompts/implementor.md` had
  prescribed the removal since it was written; the drift accumulated anyway,
  because resolutions also arrive from humans and from interactive sessions
  that no prompt governs. The per-item format retires that particular
  failure — resolution is a frontmatter flip, with no second edit to
  forget — but keeps its own smaller surface: a copy-pasted id, a wrong
  scope, a status typo. So the rule is enforced where it can be *checked*
  rather than only where it is instructed: each consumer repo runs
  `scripts/td-check.pl` on its own register in CI, so the pull request that
  creates drift fails its own checks; and the `register-hygiene` source
  (requirement 3i) detects and repairs whatever lands anyway — a register
  that predates the guard, a direct push, a merge that reintroduces it. The
  first layer is what makes the second cheap: with the guards in place the
  source's volume trends to zero, and an empty array costs one or two API
  calls.

  Three choices carry the design. It is **last in every repo's list**, because a
  deterministic cosmetic repair must never outrank substantive work, and a
  source that cannot be starved (its volume is bounded by CI) loses nothing by
  waiting. It is worked by the **ordinary Implementor, not a new actor role**:
  the repair is an edit to the register against a machine-checkable acceptance
  test, which is precisely what that role already does, and a role exists to
  carry a different *kind* of judgement, not a different kind of file. And the
  ref is scoped to the register's **identity** — a digest of both the
  `tech-debt/` tree SHA and the policy blob SHA, so a repair to either object
  retires it — so an item retires itself the moment the register changes and
  unrelated commits never fork a new one — the same expiry-by-irrelevance the
  PR-derived sources get from their head SHAs.
- **An issue's `Priority` is a rank, not a label — so the source is banded, not
  sorted.** Issues were a single rank in the walk, which meant the only way a
  human could say "this one first" was to file it as something else. GitHub's
  native `Priority` issue field already says it; requirement 15e simply makes
  the walk obey. The banding is expressed as four `issues:<band>` tokens in the
  repo's `sources` rather than as a sort *within* the issues source, because the
  ranking question is not "which issue first" but "an issue against a tech-debt
  item, a red `main`, a review recommendation" — a question a within-source sort
  cannot answer, and one the ordered `sources` list already answers for every
  other source. Keeping the ordering in config also keeps re-ranking a
  config-only change, which is what that list is for.

  Three placement choices carry the design. `Urgent` outranks even the finishing
  sources because a top band that still queued behind three tiers would not mean
  what it says, and back-pressure (requirement 2.2a) already guarantees it cannot
  starve them — once the open-PR ceiling is hit the cycle sees *only* the
  finishing sources. `Medium` is the unset default *and* sits exactly where the
  unbanded source used to, so an untriaged backlog is unmoved by this change and
  triage is the only thing that reorders anything: a default of "lowest" would
  have silently demoted every existing issue the day this landed, which is a
  re-prioritisation nobody asked for dressed as a default. And the band is
  dropped at the work order (requirement 21) because it is a statement about
  when work is picked up, not about what the work is — carrying it downstream
  would invite an Implementor or Reviewer to treat `Low` as licence to do less.
- **The Reviewer's model follows the Implementor's ex-post complexity
  self-assessment** (requirements 26a and 8a), not the Co-Ordinator's ex-ante
  classification. Complexity routinely reveals itself only during
  implementation — an item that read as a register edit turns out to touch
  the locking logic — so the agent that has just done the work grades it, and
  the grade picks the reviewer tier: `reviewer_model_complex` for `high`,
  `reviewer_model_default` otherwise. The known hazard is self-blindness: the
  PR most needing a strong review is the one whose author misunderstood
  something and didn't notice, and that author will grade it easy. Three
  choices contain it: the rubric is anchored to observable features of the
  diff (which subsystems it touched, whether the work deviated from the
  order) rather than felt difficulty; the grade rides the PR as a
  raise-never-lower label, so a PR once graded `high` is reviewed as `high`
  in every later finishing round however small that round's own work — with
  the Reviewer, the one agent that has read the whole diff without having
  written it, the only stage permitted to correct the label in either
  direction (requirement 30); and the resolved grade is logged on the
  reviewer's `stage-start`, so a drift toward `medium`-everything, or a creep
  toward `high` that erodes the cost bound, is visible in the log rather
  than discovered in the human's review queue. The label doubles as a signal
  to the Human Reviewer of how carefully to read. A self-escalating Reviewer
  (the default-tier Reviewer requesting an Opus re-run when out of its depth)
  was considered and deferred: it judges from the reviewer's seat, which is
  the most relevant one, but pays for two reviews on exactly the PRs that
  are already expensive, and it adds a stage outcome to the state machine.
  It remains open as a future *addition* to the labelling scheme, warranted
  only if the log shows the Implementor's grading under-firing.
- **Back-pressure on open agent PRs replaces a quota-balance check** as the
  primary throttle, because no supported API exposes a subscription plan's
  remaining quota; usage-limit errors are handled fail-safe via detection
  and cooldown (requirement 10).
- **The 6-hour stale rule became a 3-hour lock plus per-stage timeouts** —
  finer-grained, and a wedged stage can no longer consume six hours of
  quota.
- **Work-source categories are mapped to what actually exists** in the two
  repos (security findings, failed runs, tech-debt registers, GitHub issues,
  fiddle's implementation plan, project-review recommendations, and
  code-quality findings). User stories and road maps were dropped — neither
  repo has them; the config structure accepts new sources when they appear.
- **The weekly project review feeds the pipeline as a work source.** The
  review pipeline (`docs/REVIEW-PIPELINE-SPEC.md`) lands, in each repo, both an
  updated tech-debt register — the primary, status-tracked channel (picked up
  by the `tech-debt` source) — and a `reviews/project-review-*/` folder of
  prioritised
  recommendations with ready-to-run improvement prompts. The
  `project-review` source consumes the latter so that recommendations *not*
  also filed as tech-debt or an issue are still actioned rather than left to
  rot in a folder. It sits just above `code-quality` (a human-approved
  recommendation beats an automated one) and below the curated channels, and
  dedups against them via the `R-NN` cross-reference the review writes into
  each mirrored tech-debt entry (required of the review by R12a of
  `docs/REVIEW-PIPELINE-SPEC.md` — for a long time this bullet merely *assumed*
  it, which is why the dedup silently didn't work; see Gotchas). Because the recommendations file is
  regenerated each week (its `R-NN` IDs are per-review, so a ref is
  review-dated), an un-actioned recommendation is simply re-offered under a new
  ref by the next review; persistent items live in the tech-debt register,
  which has stable IDs — so the regeneration doesn't strand work. Done-ness is tracked by
  the PR referencing the ref (open = claimed, merged = done), the same
  PR-as-source-of-truth pattern the findings sources use, so the review folder
  stays an immutable point-in-time record.
- **Security findings are a first-class, always-first work source.** GitHub's
  own Dependabot and code-scanning alerts are treated as work items, and any
  security-related candidate outranks all non-security work (requirement 15a),
  even a red `main` — a known, exploitable vulnerability is the highest-stakes
  thing the pipeline can be pointed at. Non-security code-scanning findings
  become the `code-quality` source, ranked below every curated source: real, but
  more speculative and higher-volume than curated tech-debt or filed issues, so
  they never crowd out deliberate work.
- **Findings are pre-fetched by the Script, not the model** (requirement 3a,
  `scripts/gather-findings.sh`). The Dependabot and code-scanning APIs are
  paginated and verbose; digesting them in the cheap Co-Ordinator session
  would burn tokens on plumbing. A deterministic bash+`gh`+`jq` script
  normalises them into compact findings the Co-Ordinator reads directly — the
  same pattern already used to feed it the ordered repo list and blocked
  extract. It fails safe to `[]` so a repo without the feature (or without
  token scope) costs nothing and breaks nothing.
- **Claim visibility is pre-fetched by the Script, not left to a per-candidate
  live check by the model** (requirement 3o, issue #175). Exclusion 3 used to
  ask the Co-Ordinator to discover a peer's claim itself — nominally one
  `git ls-remote` per repo, but a check the fleet's smaller Co-Ordinator model
  routinely skipped, and one the three finishing sources' file claims could
  never have shown up in even performed faithfully, since they mint no
  branch. The log's cost was concrete: item `78` logged nineteen `claim-lost`
  events across four nodes in one day, item `155` seven in one — each a paid
  Co-Ordinator run whose selection was doomed before it started, and often a
  stand-down where other work existed. The fix is the same pattern as
  findings, above: a deterministic bash+`gh`+`jq` gather (`lib/claim.sh
  claims`/`branches`) replaces a live judgement call with a lookup against
  pre-fetched data, complete over both claim shapes and immune to model size.
- **Tech-debt handling uses the repos' own claiming workflow directly**
  (both repos today keep identical per-item `tech-debt/` machinery and a
  `/td` skill, but the Implementor follows the documented workflow rather
  than dispatching through the skill, which exists to launch agents — the
  Implementor already is one).
- **The Co-Ordinator falls through** to the next category or repo when
  candidates fail the suitability bar, instead of giving up after the first
  category that yielded any candidate.
- **Branch names drop the repo slug** (`agent/<item-slug>`): a branch is
  already scoped to its repository.
- **Review feedback is a work source, and the human's turn is derived from
  review-thread events** (requirement 3c). Before it, an agent PR that
  received "changes requested" was a dead end: the open PR claimed its own
  item (requirement 16.3), no source read `reviewDecision`, and only a human
  could break the deadlock — by fixing it themselves or closing the PR and
  losing the work. The system could raise PRs but never answer the one person
  it raises them for.

  The mechanism turns on a constraint that looks like an obstacle and is
  actually the design: GitHub will not let a PR's author approve or dismiss a
  review on it, and this system is the author. So the agent *cannot* clear
  `CHANGES_REQUESTED` — which both preserves the human gate for free (there is
  no route by which an agent marks its own work accepted) and means the PR's
  own state can never tell us the feedback was answered. Whose turn it is has
  to be derived, and the derivation is events GitHub itself stamps when they
  happen — a marked reply or a `review_requested` timeline event — never a
  commit's date: an early version compared the blocking review against the
  head commit's `committedDate`, and a conflict-resolution force-push
  re-stamps that date to push time with no review of its own having occurred,
  which silently satisfied the comparison on PR #205 (agent-ops#239). That
  single clause is the difference between a source that converges and one
  that re-fixes the same PR every hour forever while looking productive.
- **The switch is one shared, expiring file** (requirement 2.3). Shared because
  the hazard is an agent editing the agent-ops tree, and *both* pipelines run
  out of that tree and source the same `lib/` — a per-pipeline switch would let
  the weekly review fire into a half-written `lib/limit-detect.sh`. Expiring
  because the switch is the only thing in this system whose deliberate purpose
  is a total, silent stop, which makes a forgotten one indistinguishable from a
  quiet week; `disable_default_ttl` bounds that at a few cycles, and `forever`
  remains available for a maintenance window someone actually means. In
  `state_dir` rather than the repo, because the repo is the thing being edited:
  a tracked switch would arrive and depart with branch checkouts and could be
  committed by accident. `agent-cycle.sh` is the only writer, so there is one
  record and one implementation to keep honest.
- **The no-op short-circuit fingerprints the Co-Ordinator's inputs rather than
  its answer** (requirement 3b). The alternative framings are all worse: caching
  the verdict for N hours is arbitrary and stale; asking a cheaper model whether
  anything changed reintroduces the token cost being avoided; and letting the
  Co-Ordinator decide when to skip asks the component being skipped to opt out.
  Hashing the inputs makes the skip a deterministic claim about bytes, which is
  a claim bash can make correctly and a test can pin — and it composes with the
  existing pre-fetch design, since the two most expensive inputs (`findings`,
  the blocked/void extracts) were already computed in the Script. It also fails
  in the right direction by construction: anything unexpected — a changed
  digest shape, a failed sample, a log the rule can't read — produces "no
  match", which costs one Co-Ordinator run. The rule can only be wrong by being
  *incomplete*, which is why requirement 3b's map of source-to-signal is
  normative and `none_selected_recheck_hours` caps the damage at a day.

- **The Enabler runs from the exit trap, not from nine call sites.** A model
  stage inside a cleanup handler is unusual enough to look like a mistake, so:
  the cycle has nine endings, and the escalation path matters most on the ones
  that selected nothing — a stand-down on back-pressure, a no-op skip, a lost
  claim. Calling it at each of those is nine places to keep in step and one to
  forget, and the one forgotten would be silent. The trap is the single place
  every ending already passes through; it still holds the lock, which is what
  keeps requirement 33's single-writer guarantee true for the events the
  engagement writes; and it already runs multi-minute work (the state-sync push,
  the dashboard publish), so the shape is not new. What the trap does demand is
  the discipline of requirement 37: an unguarded non-zero status inside it would
  abandon the rest of the cleanup, so every step tolerates its own failure and
  the call itself is `|| true`. That is a smaller, more testable obligation than
  nine call sites that must each stay correct.
- **The Enabler's claims are tombstones, not locks it releases.** Every other
  claim in this system is released when the work ends (requirement 17a); these
  are deliberately never released, and `lib/claim.sh gc` is what retires them.
  The reason is that the failure this bounds is *not* two nodes racing — that
  much a released lock would handle — but an engagement that produces no record
  at all: a timeout, a garbage final message, an item the model silently omitted.
  Release the claim and the next cycle re-engages the same item immediately, and
  goes on doing so hourly at Opus prices with nothing to show for it, since the
  eligible set is unchanged. Keeping the claim converts every such failure into
  "retried once per `claim_ttl_hours`", which is a bounded cost written in a
  config file rather than an unbounded one discovered in a bill. The key carries
  the block's timestamp, so a genuinely re-blocked item is a new key and is not
  gagged by the tombstone of the old one. `lib/claim.sh expire` (requirement 37)
  narrows that bound without abandoning it: it fires only for the one case the
  Script can actually distinguish from silence — an engagement it watched fail
  even after requirement 9e's salvage resume — and backdates the tombstone's
  `ts` rather than deleting it, so `gc`'s very next sweep retires it instead of
  the full TTL. A genuinely wedged item still costs at most one attempt per gc
  interval, which is the same shape as before this existed, just a shorter one.
- **The Script files every issue; the model only writes the words.** The
  Enabler could perfectly well run `gh issue create` itself, and it must not.
  Two reasons, both structural. The log is appended by the Script alone
  (requirement 33), and an escalation is a state change with a matching event —
  an issue created by the model is one whose number no `escalated` event records,
  so no later cycle can tell whether the ask is still open, and the closure loop
  of requirement 36a silently never fires. And the write powers a model needs to
  file an issue are the same ones it would need to close, label, or assign one;
  withholding them costs nothing here, because composing the issue is the part
  that actually needs judgement, and it keeps "no agent decides that this work is
  accepted" true by construction rather than by instruction. The same split as
  the rest of the pipeline: models report, the Script records.
- **An item nobody has specified is blocked by that fact** (requirements 16a,
  34e, 36b). The Co-Ordinator used to skip an under-specified or decision-gated
  item in silence, which meant every later cycle re-read and re-skipped it, no
  route ever made it selectable, and the human who could have written the
  missing criteria was never told it existed. Modelling that as a *class of
  block* rather than a new state was the whole design: selection exclusion,
  the Enabler threshold, the per-item claim, the escalation protocol and its
  duplicate guard, the issue-closed recheck and the human's hand-appended
  `unblocked` all key on `attempt-failed`/`unblocked` and needed no notion of
  why the item stopped. A parallel "unrefined" state would have re-earned each
  of those properties, slightly differently, and the differences would have been
  discovered one at a time.

  Three consequences follow that are easy to mistake for oversights. The label
  is a **projection** — applied to an issue-type item, removed with the block,
  never read back — because a label can only reach the `issues` source and the
  work items here are heterogeneous; a pipeline reading it would see a fraction
  of its own state. The refinement itself lands **where a future Co-Ordinator
  already reads**: an issue's thread for an issue, and requirement 3h's log-borne
  map for everything else, rather than a new write power over registers nobody
  else may edit. And an item is refined **once between human touches**, because
  a cheap model re-flagging an expensive model's specification is two models
  disagreeing, which a third pass settles only by luck; the escalation is not a
  fallback there, it is the correct answer.

The choices above (platform, models, permissions, system location) were
confirmed by the repo owner on 2026-07-13; no open questions remain.

## Gotchas

Failure modes this system actually shipped with, kept because each one is
cheap to reintroduce and expensive to notice. They share a shape: **the
pipeline stays green while quietly doing nothing**. Nothing crashes, no alert
fires, PRs keep appearing from the other work sources — and the only evidence
is money spent on work that was already done. Budget for the fact that an
autonomous system's characteristic failure is not an error; it is a silent,
confident, recurring no-op.

| Trap | What it looks like when it bites | Build it this way instead |
|---|---|---|
| A helper returns non-zero for a legitimately empty result, and the script runs under `set -e` | `[[ -z "$x" ]] && x="$(helper)"` takes the helper's exit status, so the *whole cycle* dies at that line. Here it died two lines before logging the failure it had just detected — nine cycles left nothing behind but a `selection` event and `exit 1`. | A lookup that finds nothing is a normal outcome: return 0 and print nothing. Reserve non-zero for real errors. Assert it at the real call-site shape under `set -e`, not on the function alone — the function looked fine; the *interaction* was the bug. |
| The writer of an event and the reader of it disagree about the key | `attempt-failed` recorded no `repo`/`item`; the blocked extract grouped by exactly those. Every event collapsed into one anonymous group, so **no failed attempt ever blocked anything** — for months, undetected, because each half reads correctly on its own. | Round-trip the contract in a test: write the event, read it back through the real extract, assert the item is blocked. Any log the system reads back is a contract with itself. |
| A model's clean "I can't/needn't do this" is treated as a crash | A `{"status":"blocked"}` report went down the failure path and was filed as `"implementor exited 0"`, throwing away the reason and unblock condition — the entire product of a full model run. So the next cycle bought the same discovery. | A verdict is a result. Persist it with the model's own words (requirement 9a), and note *which* verdict it is (requirement 9b). The log is the system's only memory: a finding you don't write down, you pay for again, on a schedule, forever. |
| Done-ness inferred from one channel | "Done" meant *a merged PR references it*. Work that landed as a direct commit — or before the repo required PRs — has no PR, so it reads as outstanding forever, and the item is re-selected every cycle for as long as it exists. | Don't let one provenance channel be the only proof. Cross-reference the curated register (R12a), and let the agent that actually looks at the repo settle it once (requirement 9a). Prefer evidence from the tree over evidence from process metadata. |
| A rule with two implementations | The dashboard and the Script each computed "blocked". They disagreed, and the dashboard — the very place you would look to spot this bug — showed the wrong answer confidently. | One definition, shared (requirement 34a). If a second consumer needs it, it sources the first, and the shared unit is where the test lives. |
| Identifiers assumed globally unique | `dependabot-alert-1` exists in *every* repo; date-numbered registers collide across repos too. Keying on the id alone makes one repo's block starve another repo's unrelated work. | Key on the scope plus the id (requirement 34). Ask what an id is unique *within* before using it as a key. |
| A contract asserted in one document and required by none | This spec's design notes state the review "writes the `R-NN` cross-reference into each mirrored tech-debt entry" — and `docs/REVIEW-PIPELINE-SPEC.md` never asked for it. Both documents were internally consistent; the system between them was not, and the dedup it justified never worked. | When one component's design depends on another's behaviour, make it a numbered requirement *in the document that builds that component*, and cite it from both sides. Prose describing what another component "does" is a wish, not an interface. |
| A state that can never say "done", read as if it could | `reviewDecision` stays `CHANGES_REQUESTED` after the agent pushes its fix — GitHub won't let a PR's author dismiss a review on their own PR, and the agent *is* the author. So "is there unanswered feedback?" answered from the PR's own state is always yes, forever. The PR is selected, fixed, re-selected, re-fixed, hourly, at Sonnet prices, and every cycle looks like a productive one. | Ask "what would ever change this value?" before keying on it. Where the answer is "nothing we can do", the state cannot be the signal — derive whose turn it is instead (requirement 3c: an answer event — a marked reply or a re-requested review — after the blocking review, the same shape as "a later green run supersedes"). A field that can only ever hold one value is not a condition, it is a constant. |
| A proxy signal that an unrelated action can forge | "Whose turn is it" was derived by comparing the blocking review's timestamp against the head commit's `committedDate` — a real fix that came in stayed the answer. But a conflict-resolution force-push re-stamps *every* commit's date to push time, with no review of its own having happened, so rebasing a PR to resolve a merge conflict silently read as "answered" and PR #205's unresolved `CHANGES_REQUESTED` dropped out of every selection query for hours (agent-ops#239) — the same family `lib/handoff.sh` had already fixed twice under different names. | Before trusting a timestamp as evidence an actor did X, ask what *else* moves that timestamp. Where anything unrelated can, key on an event the platform stamps only when X itself happens (a review-requested event, a marked reply) rather than a field that merely correlates with it. |
| The formal signal and the substance in different places | The blocking `CHANGES_REQUESTED` review's body read, in full: "Refer to https://…#pullrequestreview-4718691960". All 6.5 KB of actual findings were in a *separate* `COMMENTED` review, by a *different account* — because the agent's own account raised the PR and therefore cannot request changes on it. A gatherer that read only the blocking review would have handed the Implementor the words "Refer to" and called the brief complete. | Gather the whole round, whoever wrote it, and pass it verbatim. When a platform rule (an author cannot review their own PR) forces a workflow to split across accounts, the split is structural and permanent — design for it rather than discovering it in the one review that mattered. |
| A change-detection digest that tracks churn instead of meaning | The no-op short-circuit (requirement 3b) digested the *run id* of each workflow's latest run. `poetic` schedules `sync-framework.yml` at `0 * * * *` — hourly, the same cadence as the pipeline — so that one workflow busted the fingerprint on every single cycle. The feature was installed, tested, logged, green, and saved nothing; the only symptom was the bill it was built to reduce, unchanged. Found by reading the repo's actual cron lines, not by any test. | Digest the *fact the consumer reads*, not the record it lives in. Requirement 15 asks "is this workflow's latest run a failure" — that is the conclusion, not the id. Before digesting a field, ask what changes it and on what cadence; anything that moves on a timer moves faster than the thing you are trying to detect. Then assert the negative (a green rerun changes nothing), because every positive test still passes on the broken version. |
| A cost-control feature that makes cost the *only* thing it protects | Skipping a stage to save money is a decision to do nothing, and doing nothing is what a healthy idle pipeline also looks like. Get the skip condition subtly wrong — a source outside the fingerprint, a failed API call digested as "empty" — and the pipeline stops picking up work while reporting perfect health, forever, because nothing that stands down ever fails. | Make the skip's claim narrow enough to be provable ("nothing changed"), never broad enough to be wrong ("there is no work"). Mark unusable samples rather than degrading them to empty. Cap the whole mechanism with a time-based valve (`none_selected_recheck_hours`) so a gap in coverage is a bounded delay rather than an outage, and pay the occasional wasted run for it — the run you skipped wrongly costs more than the one you ran needlessly. |
| A switch with no way back on | An agent disables the pipeline to edit safely, then dies mid-session — killed, timed out, or just finished and forgetful. The switch stays set. No cycle runs again. Nothing alerts, because "no PRs this week" is exactly what a quiet week looks like, and the operator finds out days later. | Give any deliberate stop an expiry (requirement 2.3), and make indefinite something a human explicitly asks for. Same shape as the stale-lock rule (requirement 1): every mechanism that halts this system needs an answer to "what if whoever set it never comes back?" |
| One state carrying two meanings, where an agent can reason its way out of it | "Blocked" meant both *something is in the way* and *there is nothing to do*. The Co-Ordinator is told to clear blockers that have lifted; it checked an already-done item, correctly found nothing in its way, and logged `unblocked` — returning it to the pool to be rediscovered forever. Every component obeyed its spec exactly. The fix for the previous row *created* this one, and it took a live cycle to see. | Split the states (requirement 9b): `blocked` is clearable by an agent, `void` only by a human. Test that the clear for one cannot fire on the other. **The tell:** if the same fact that ought to make a state permanent is also grounds for clearing it, the state is wrong. Ask of every agent-clearable state: what would the agent have to believe to clear this, and is that belief the reason it exists? |
| A staleness clock reset by the system's own housekeeping | `abandoned-drafts` (requirement 3e) measured a draft's staleness from `updatedAt`, which moves for anything at all. On poetic#92 a label edit deferred detection by a full `abandoned_draft_after_hours`, and — the sharper case — the Enabler's own comment correctly diagnosing the stall reset the clock in the same breath it cleared the block, deferring the very recovery it had just enabled. Filtering by comment author could not fix it: every pipeline write happens under the same GitHub account a human also comments as. | Ask "would *this system itself* ever produce this signal, and does that mean what a human producing it would mean?" before trusting a timestamp as "somebody is on it" (TD26072605). Where the answer differs, stamp what you write (`lib/pipeline-marker.sh`'s invisible marker) so the reader can tell its own hand from a human's, and discount your own bookkeeping (label edits) unconditionally. Same shape as "a change-detection digest that tracks churn instead of meaning" above, but the churn here is the system talking to itself. |
| An operating-system limit the input grows into, one edit at a time | The assembled prompt went to the stage as `claude -p "$prompt"`. Linux caps one argv entry at 131072 bytes; `prompts/coordinator.md` grew from 37850 bytes to 62603 over seven days of ordinary requirement work, and on 2026-08-01 the assembled Co-Ordinator prompt reached 131441 — 369 bytes over. `execve` failed, the stage exited 126 with `Argument list too long`, the cycle logged `attempt-failed` and then `cycle-end exit_code 0`. Every node in the fleet went quiet within the hour and the dashboard showed four healthy idle nodes; the prompt ships in the image, so one roll broke all of them at once, and the node that had not rolled for four days broke the moment its operator ran `docker compose up -d`. | Never put unbounded content in argv. Prompts, diffs, issue bodies, JSON briefs — all of it goes on stdin, where no such cap exists. The general rule: when an input grows monotonically with the product's own development, find the ceiling *before* shipping it, because the failure lands not on the commit that caused it but on whichever later one crosses the line — and here that is a documentation-shaped commit, reviewed by people thinking about wording. Ask of any limit you are within: what consumes the remaining margin, and who would notice it being consumed? |
| A health check that only compares peers, never ground truth | Diagnosing the outage above meant reaching into a container's stderr, because the dashboard's only "is this node current" signal (`version`, the node's own build) compared nodes against *each other*. All four nodes had adopted the same broken image, so all four agreed, and agreement rendered as four healthy green cards — the same shape a genuinely healthy, fully-rolled fleet produces. The comparison could not distinguish "up to date" from "uniformly broken" because both are "everyone agrees." | Peer agreement proves consistency, not correctness — it cannot catch the whole group being wrong the same way at once. Compare against a reference outside the set being checked (the registry's own published commit, not another node's opinion of it — `lib/image-drift.sh`, #155), the same reasoning `origin/main` serves for `compose.yaml` drift (#131). Ask of any "do these agree" check: what happens when every one of them is wrong in the same way? |
