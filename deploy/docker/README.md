# Running a node

A node is one Docker Compose project. Every node runs the same `compose.yaml`
and the same image; the only thing that differs between two of them is `.env` —
its name, its role, and its tokens. That is the point: a node is not
configured, it is instantiated.

This is the runbook. For what the pipelines actually *do*, see the [main
README](../../README.md) and `docs/*-SPEC.md`.

---

## Bring up a node

### What you need first

- A machine with Docker (any Linux with a kernel from this decade; a 2-core VM
  with 20 GB of disk is comfortable — the workspaces volume holds full clones).
- A **GitHub token** for this node: read and write on `Poetic-Poems/poetic`,
  `Poetic-Poems/poetic-fiddle`, `Poetic-Poems/agent-ops` (a target repo of its
  own pipeline since the roadmap's dogfood rule) and
  `Poetic-Poems/agent-ops-state` (contents, pull requests, issues, workflows,
  actions) plus read on security alerts. Workflows and actions are separate
  permissions on a fine-grained token and both are needed: workflows write is
  what lets a cycle's PR touch `.github/workflows/`; actions write is what
  lets an agent dispatch, rerun or cancel a workflow run. A call refused with
  `HTTP 403: Resource not accessible by personal access token` names the
  permission it wanted in its `x-accepted-github-permissions` response header
  — read that rather than guessing. One token per node, so a single node can
  be revoked without disturbing the others.
- A **git identity** — a name and an email — for the commits this node's
  cycles make. There is no default; an active node's cycles refuse to run
  without both.
- A **Tailscale pre-auth key** from the tailnet's admin console, unless this
  node will run the `local` profile.
- If this node's fleet raises `merge_autonomy` above `human`, the
  **Pullwright Approver App**'s identity (D18 §5.3) — see the `.env.example`
  section it lives in for the three variables it needs, and
  `PULLWRIGHT_APPROVER_INSTALLATION_IDS` in that same section if the fleet's
  `repos[]` spans more than one GitHub owner (agent-ops#913).
- **Model credentials**, either of (see step 4):
  - An **Anthropic API key** — the primary, first-class path (D4). Set
    `ANTHROPIC_API_KEY` in `.env`; no interactive step, and any number of
    nodes can share the same key.
  - Or a **Claude subscription**, authenticated by an interactive login this
    node performs once. This path is a supported self-hosted configuration,
    not the primary one, and it comes with two constraints: the login is
    interactive per node (no way to script it, so it does not scale past a
    handful of nodes), and the subscription's terms limit it to your own
    use, not a service you operate for others.

### 1. Install Docker

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"   # then log out and back in
```

Already present on the laptop.

### 2. Fetch the stack and write the node's `.env`

The node holds four files and no clone: the image is the deployment.

```bash
mkdir -p ~/poetic-node && cd ~/poetic-node
base=https://raw.githubusercontent.com/Poetic-Poems/agent-ops/main/deploy/docker
curl -fsSLO "$base/compose.yaml"
curl -fsSLO "$base/ts-serve.json"
curl -fsSL  "$base/.env.example" -o .env
scripts=https://raw.githubusercontent.com/Poetic-Poems/agent-ops/main/scripts
curl -fsSLO "$scripts/watch-node.sh"
curl -fsSLO "$scripts/check-node-compose.sh"
curl -fsSLO "$scripts/check-node-image.sh"
chmod +x watch-node.sh check-node-compose.sh check-node-image.sh
$EDITOR .env
```

`watch-node.sh` is the one command for following this node's pipeline output
once it is up (see [Follow a node's events](#follow-a-nodes-events) below);
`check-node-compose.sh` audits this node's `compose.yaml` — and the
containers created from it — against the running image (see [Keeping the
compose file current](#keeping-the-compose-file-current)); `check-node-image.sh`
asks whether this node is running the newest image the repository has
published (see [Is this node on the newest
image](#is-this-node-on-the-newest-image) below). All three are fetched now
so they sit beside `compose.yaml` from the start.

At minimum set `NODE_NAME`, `GH_TOKEN`, `GIT_USER_NAME`, `GIT_USER_EMAIL` and —
for the `tailnet` profile — `TS_AUTHKEY`. Leave `ROLE=standby` unless this node
is meant to be the one that spends; see [Which node runs the
cycles](../../README.md#which-node-runs-the-cycles).

Every credential above arrives here, as a plain `.env` value — none of them
need an interactive step inside the running container. The forge authoring
App (D18 decision 1, the `.env.example` section right after the Pullwright
Approver App's own) is the same shape, entirely optional, and upgrades this
node from the `GH_TOKEN` PAT above to short-lived App-minted tokens once an
owner has provisioned it; leaving it unset costs nothing; the node keeps
authenticating with `GH_TOKEN` exactly as it always has.

`.env` holds this node's secrets. It is git-ignored, and if a token ever lands
in a commit the answer is to rotate it, not to rewrite history.

`.env` must be `chmod 600` — the same protection the Approver App's private
key already gets (see `PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH` in
`.env.example`). A world- or group-readable `.env` hands every live token in
it — `GH_TOKEN`, `VERCEL_TOKEN`, anything else set there — to any other
account on the host. `check-node-compose.sh` (step 2) flags a `.env` that is
not `0600`. Rotate a token by editing `.env` in place, or by swapping in a
`0600` temporary file; never leave a dated copy (`.env.bak-*`, `*.env.old`)
beside the live file — `check-node-compose.sh` flags those too, and each one
carries whatever tokens were live when it was made, undead until someone
finds and deletes it.

### 3. Start it

```bash
docker compose up -d
```

If the host's own egress MTU is below 1500 — behind WireGuard or Tailscale, on
some cloud instances, and in WSL — set `DOCKER_MTU` in `.env` to match it
before you start. Docker gives its bridge 1500 regardless of the host, and the
mismatch is a black hole: DNS and plain HTTP work inside the container while
every TLS connection hangs and resets, which looks exactly like a bad token.

```bash
ip route get 1.1.1.1        # names the egress interface
ip link show <interface>    # gives its mtu
```

`COMPOSE_PROFILES` in `.env` decides what that brings up — `tailnet` for the
dashboard over your tailnet, `local` for the dashboard on this machine's own
loopback, `auto-update` for watchtower. The scheduler starts regardless: it is
in no profile, because a node that runs no cycles and no heartbeat is not a
node.

### 4. Give this node model credentials

**API key (primary, D4):** set `ANTHROPIC_API_KEY` in `.env` (step 2) and
`docker compose up -d` to pick it up. Nothing further to do — `claude` reads
it from the environment on every invocation, so there is no per-node login
and no `claude-config` volume to protect.

**Subscription OAuth (alternative — interactive per node, own use only):**
the sole exception to this stack's non-interactive bring-up (D4) — every
other credential, including the API key above and the forge authoring App
in step 2, arrives as a secret or environment value at container start,
never by `exec`-ing into a running one. Leave `ANTHROPIC_API_KEY` unset in
`.env` and instead log in once:

```bash
docker compose exec scheduler claude
```

Complete the login. The credentials land in the `claude-config` volume, which
outlives every container this node will ever run — this is the one thing here
that cannot be rebuilt from the image, and the entrypoint warns on every start
until it exists.

Either way, verify:

```bash
docker compose exec scheduler claude -p 'say ok' --model claude-haiku-4-5-20251001
```

Or ask the node itself, which reports which of the two paths it is on:

```bash
docker compose exec scheduler /app/scripts/doctor.sh
```

### Did it work?

```bash
docker compose ps                      # scheduler up; dashboard up if in profile
docker compose logs scheduler | tail   # supercronic read the crontab
docker compose exec scheduler /app/agent-cycle.sh --status
```

Within five minutes the dashboard heartbeat should have published a page:

- `tailnet` profile → `https://<NODE_NAME>.<your-tailnet>.ts.net`
- `local` profile → `http://127.0.0.1:8787` on that machine

Within seven minutes a standby node should have pulled the fleet's state:

```bash
docker compose exec scheduler ls /home/agent/.local/state/poetic-agents/cycles | wc -l
```

---

## Operating a node

### Everyday commands

| Want | Command |
|---|---|
| Follow the pipelines | `docker compose logs -f scheduler` |
| Is anything running? | `docker compose exec scheduler /app/agent-cycle.sh --status` |
| Stop cycles fleet-wide | `docker compose exec scheduler /app/agent-cycle.sh --disable 'reason'` |
| Stop cycles on this node alone | `docker compose exec scheduler /app/agent-cycle.sh --disable 'reason' --this-node` |
| Resume | `docker compose exec scheduler /app/agent-cycle.sh --enable` |
| Resume this node alone | `docker compose exec scheduler /app/agent-cycle.sh --enable --this-node` |
| A supervised cycle | `docker compose exec scheduler /app/agent-cycle.sh --once` |
| A shell on the node | `docker compose exec scheduler bash` |
| Cycle events (starts, selections, PRs, stand-downs) | `./watch-node.sh events -f` |
| The cron log | `./watch-node.sh cron -f` |

### Follow a node's events

`watch-node.sh` (fetched alongside `compose.yaml` in [Bring up a
node](#2-fetch-the-stack-and-write-the-nodes-env) above) is the one command
for watching a node from outside, in place of remembering the
`docker compose exec -T scheduler tail ...` incantation:

```bash
./watch-node.sh events -f   # cycle log (log.jsonl): starts, selections, PRs, stand-downs
./watch-node.sh cron -f     # cron log (cron.log): one line per tick, including standby ones
```

Drop `-f` for the last 50 lines instead of following. Run it from the node's
stack directory — where it resolves `compose.yaml` from by default — or set
`STACK_DIR` to point at a stack directory elsewhere. It is read-only (`tail`
over `docker compose exec`), so it is the one path worth allow-listing for an
interactive agent, instead of ad-hoc docker-exec commands that a permission
classifier may deny.

The switch (`--disable`) stops **every** node: as well as the local record it
publishes `fleet/disabled.json` to the state repository's main, which each
node reads live at cycle start (and falls back to a cached copy of when
GitHub is unreachable). `--enable` clears both, and says so — if the fleet
flag could not be cleared it warns loudly, because every node is still
standing down at that point. The role decides whether *this* node spends;
the switch decides whether *any* node does. A usage-limit hit travels the
same way (`fleet/limit.json`), so the first node to hit the shared Claude
limit stands the whole fleet down within a cycle tick.

Add `--this-node` to either command to keep the effect local: `--disable
'reason' --this-node` writes only this node's own record and never touches
`fleet/disabled.json`, so the rest of the fleet keeps working; `--enable
--this-node` clears only that local record and leaves a fleet-wide disable
(or a peer's own node-scoped one) untouched. It is the graceful way to stand
one node down for maintenance — no container recreate, no role flip.

### Updating

Nothing to do. CI builds an image from every merge to `main` that touches
anything the container reads, and publishes it as
`ghcr.io/poetic-poems/agent-ops:latest`; watchtower (profile `auto-update`)
notices and restarts the services into it. There is no `git pull` anywhere in
this design. A merge that only changes documentation publishes nothing and
rolls nothing — the running image is already the code that merge describes.

A roll waits for a cycle rather than killing one. Recreating a container kills
the process group its cycle runs in, so watchtower asks first: with
`WATCHTOWER_LIFECYCLE_HOOKS` on, it runs
`deploy/docker/watchtower-pre-update.sh` inside each agent-ops container before
touching it, and that script exits 75 (`EX_TEMPFAIL`) — watchtower's "cancel
this one" — while either pipeline's lock is held. Held is judged by whoever is
asked: the container that wrote the lock checks its process is alive, while
any other container — the dashboard shares the scheduler's state volume, so it
reads the scheduler's locks — honours it without a check, because a pid means
nothing outside the PID namespace that minted it (#130). The roll lands on the
next poll instead, five minutes later, and keeps landing there until the node
is idle. A cycle can only push it back by so far: the hook respects a lock
exactly as long as a cycle would, so a lock past `lock_stale_after` stops
deferring anything, whoever wrote it.

You can watch it happen:

```bash
docker compose logs watchtower | grep -A2 'Command output'
```

`no cycle in flight` means the roll went ahead; `deferring this update` names
the pipeline and the pid it waited for. A deferral is counted as a *failed*
container in watchtower's session summary — that is watchtower's own wording
for "did not update", not a fault — so on a healthy node `Failed=1` recurring
every poll is what a working deferral looks like; do not build alerting on it.
On a host running two nodes off one image, a deferral may also log a
name-conflict `ERROR` (`Creating <container> … name is already in use`): the
other node's roll asks watchtower to recreate everything on the shared image,
and the deferred container survives because it was never stopped, so the
create fails on its own name. Same signature, same meaning — the deferral
held.

**A node provisioned before this existed is not protected until its stack is
re-created.** The labels that carry the hook are read off the *running*
container, and a node holds its own copy of `compose.yaml`, so a new image
alone cannot deliver them. Once per node, at a moment of your choosing:

```bash
docker compose exec scheduler /app/agent-cycle.sh --status   # wait for idle
curl -fsSLO https://raw.githubusercontent.com/Poetic-Poems/agent-ops/main/deploy/docker/compose.yaml
docker compose up -d
docker compose exec scheduler /app/deploy/docker/watchtower-pre-update.sh   # 0 idle, 75 busy
```

That `up -d` is itself a recreate, which is why `--status` comes first: this is
the last roll on that node that has to be timed by hand.

To update by hand, or on a node without watchtower:

```bash
docker compose exec scheduler /app/agent-cycle.sh --status   # wait if a cycle is running
docker compose pull && docker compose up -d
```

The `--status` line is not optional here. The hook guards watchtower, which is
the case that arrives unannounced; a manual `up -d` bypasses it entirely and
kills a running cycle exactly as an unguarded roll used to.

To pin a node to a known-good build, or to roll one back, set the image to a
commit SHA tag in `.env` and re-run `up -d`:

```
AGENT_OPS_IMAGE=ghcr.io/poetic-poems/agent-ops:<sha>
```

### Keeping the compose file current

Watchtower delivers new *images*; nothing delivers a new `compose.yaml`.
Labels, service environment and mounts are read off the file at `up -d` time
and never afterwards, so **merging a change to `deploy/docker/compose.yaml`
deploys nothing** — a merged compose fix sits inert on every node until a
human performs, on each node, at a moment when it is idle:

```bash
docker compose exec scheduler /app/agent-cycle.sh --status   # wait for idle
curl -fsSLO https://raw.githubusercontent.com/Poetic-Poems/agent-ops/main/deploy/docker/compose.yaml
docker compose up -d
```

(The `--status` line is not optional: a manual `up -d` bypasses the
pre-update hook and kills a running cycle.) On a host running two stacks,
repeat from each stack directory — the two files are kept byte-identical, so
`cp` the fetched file over the second stack's copy and `up -d` from there.

You do not have to remember any of this unprompted. A pull request that
touches `compose.yaml` gets a CI comment saying the merge is not the
deployment; and each node checks its own copy from inside — `compose.yaml`
mounts itself read-only at `/host/compose.yaml`, `lib/compose-drift.sh`
diffs that against the copy baked into the running image (comments aside),
and the verdict travels in the node's heartbeat, so every dashboard's fleet
strip flags the node until the ritual above is done:

- **compose drifted** — the node's file differs materially from the copy its
  image shipped;
- **compose unverified** — the file is not mounted into the containers at
  all, which means it predates the drift check and is behind regardless.

To audit a node from its host — the running containers included, which the
in-container check cannot see — run `check-node-compose.sh` (fetched at
bring-up) from the stack directory:

```bash
./check-node-compose.sh
```

It diffs the file against the running image's copy, confirms the pre-update
hook label on every agent-ops container and lifecycle hooks in watchtower's
actual environment, and exits non-zero if anything has drifted — those checks
cover exactly the properties whose silent loss cost the cycles behind
issue #131. It also flags, host-side and without needing the stack to be up,
a `.env` that is not `0600` and any `.env.bak*`/`*.env.old` backup left
beside it (see above).

### Is this node on the newest image

`compose.yaml` is one half of "is this node current" — the other is the
image itself, which watchtower is meant to keep rolling forward on its own.
When it does, "behind" is a normal transient: a roll defers while a cycle is
in flight (the pre-update hook above), so a node reading a commit or two
behind `main` for a while is the mechanism working as designed, not a fault.
What has no other answer on this page is a node whose roll has *stopped* —
a wedged hook, a registry token that quietly expired — which looks
identical to a healthy mid-roll for as long as nobody checks (issue #155).

Every dashboard's fleet strip carries the answer, from each node's own
comparison against `ghcr.io/poetic-poems/agent-ops:latest` (`lib/image-drift.sh`,
via the heartbeat):

- **image behind** (grey) — the registry's newest image is younger than
  `image_behind_grace_hours` (`config.json`; a few hours by default) — the
  ordinary mid-roll state, nothing to do;
- **image behind** (amber) — older than that, and this node still has not
  adopted it;
- **image unverified** — the registry could not be reached, or (only right
  after this check itself first rolls out) the node's heartbeat predates it.

To ask directly from a node's host, run `check-node-image.sh` (fetched at
bring-up) from the stack directory:

```bash
./check-node-image.sh
```

It runs the same check inside the scheduler container — a live registry
query, not a cached answer — and exits non-zero only once the node has been
behind for longer than the grace period; use `docker compose logs
watchtower` to see whether it is still polling at all.

### Changing a node's role

Edit `ROLE` in `.env`, then:

```bash
docker compose up -d
```

Compose recreates the scheduler with the new environment. Nothing else needs
restarting, and the state volumes are untouched.

### Changing who spends

Any number of nodes may be `active` at once — per-item claims keep them off
each other's work — so promoting or demoting a node is one variable and one
`up -d`, in any order:

1. Set `ROLE=active` (or `standby`) in the node's `.env`.
2. `docker compose up -d`.
3. Watch the next cycle tick: an active node runs a cycle; a standby logs
   `skipped — this node is standby`. Either way its heartbeat keeps
   publishing.

To confirm a node is following the fleet's memory rather than only its own:

```bash
docker compose exec scheduler ls /home/agent/.cache/poetic-agents/workspaces/.agent-ops-peers
docker compose exec scheduler tail -n 3 /home/agent/.cache/poetic-agents/workspaces/.agent-ops-peers/*/log.jsonl
```

Those should name the *other* nodes and show their recent events. That is the
whole purpose of the fetch: a lesson any node learned spares the rest.

### Changing when a node's cycles run

A node's implementation cycle fires every `schedule.cycle_interval_minutes`
(15 by default) within an allowed hour, starting from the node's own minute:
`CYCLE_MINUTE` in `.env` when it is set, otherwise a stable hash of
`NODE_NAME`. An idle firing stays cheap — `lib/noop-skip.sh` short-circuits
before the Co-Ordinator runs when nothing a fingerprint covers has changed —
so this is not four times the spend, only four times the chances to notice
work sooner. The crontab is rendered at every container start —
`entrypoint.sh` runs `render-crontab.sh`, which fills `crontab.tmpl` from
`config.json`'s `schedule` block and this one variable — so the minute belongs
to the node's `.env`, not to the image, and moving it is the same two steps as
changing a role:

1. Set `CYCLE_MINUTE=<1-59>` in the node's `.env`.
2. `docker compose up -d`, in an idle window — `docker compose exec scheduler
   /app/agent-cycle.sh --status` first, because recreating the scheduler kills
   a cycle in flight, and this `up -d` bypasses the pre-update hook exactly as
   a compose refresh does.

Time it so that the *old* minute has passed and the *new* one has not yet come
round, and the change costs nothing at all. Then read back what the node
actually rendered, which is the only answer that counts:

```bash
docker compose exec scheduler grep -E 'agent-cycle|review-cycle' /app/deploy/docker/crontab
docker compose logs scheduler | grep render-crontab   # node <name>: cycle at minute(s) N,N+15,… …
```

Two things decide what minute you may ask for:

- **`config.json`'s `schedule.excluded_minutes` outranks `.env`.** This repo
  excludes minute `0`, because poetic's hourly sync workflow owns the top of
  the hour. `CYCLE_MINUTE=0` — or anything that is not a number in `0-59` — is
  refused with a `WARNING` in the scheduler's log and the node falls back to
  its hash default. The container starts either way, so a typo shows up only
  in that log or in the rendered crontab above: read one of them.
- **The review tick follows the cycle.** It is rendered at
  `schedule.review_offset_minutes` (29) past `CYCLE_MINUTE`, mod 60, at
  `schedule.review_hour` (03:00) — so moving a cycle moves that node's daily
  review with it, and the two stay a half hour apart within the node. Nothing
  else in the crontab moves: the heartbeat, both state-sync directions and the
  log rotation are fleet-wide values from `config.json`, identical on every
  node.

Both of those, and the schedule keys generally, are tabulated in the [main
README](../../README.md#configuration). They live in the image, so changing
one is a pull request and an image roll, not an `.env` edit — which is the
reason `CYCLE_MINUTE` exists as a per-node override at all.

### Spreading the fleet across the hour

The hash default is deliberately arbitrary, because any spread beats none:
every active node spends the same Claude account and pushes to the same repos,
so nodes that fire together collide on quota and on refs for no gain.
Arbitrary is not the same as even, though, and once nodes share hosts it is
worth dealing the minutes out by hand:

- Put `60 / N` minutes between consecutive cycles — with four nodes, one every
  quarter hour.
- Then walk that ring **alternating hosts**, so the nodes sharing a machine end
  up as far apart as the ring allows. Two nodes on one host at `:06` and `:36`
  leave it a clear half hour between cycle starts; the same two at `:06` and
  `:21` leave it fifteen minutes and then forty-five idle.
- Finally, nudge the whole ring off the five-minute marks. The heartbeat and
  `state-sync push` lines both run `*/5`, so a cycle starting at `:05` starts
  on top of two of its own node's other jobs; one minute later it does not.
  They are light and the mirror lock arbitrates when they do coincide, so this
  is a refinement rather than a fix — but it is free. Minute `:19` is the log
  rotation, and minute `0` is excluded outright.

The four-node, two-host fleet this repo runs is therefore:

| Minute | Host | Node | `.env` |
| - | - | - | - |
| `:06` | WSL laptop | `ockham-container` | `~/poetic-node-1/.env` |
| `:21` | Hetzner VM | `poetic-2` | `/opt/poetic-node-2/.env` |
| `:36` | WSL laptop | `ockham-2` | `~/poetic-node-2/.env` |
| `:51` | Hetzner VM | `poetic-1` | `/opt/poetic-node/.env` |

What the spacing buys is a lower *peak*, not less total work: each start burst
— a fresh clone, a `claude` process, the first stage's tokens — lands on a host
that is otherwise quiet. It does not stop cycles overlapping, and is not meant
to. A cycle can and does run past the hour, so a host with two nodes can have
two running at once whatever their minutes; what bounds it is the per-node
lock, which keeps any one node to a single cycle and lets the tick it would
have collided with pass by.

One overlap the spacing cannot remove, worth knowing rather than chasing:
`review_offset_minutes` is fleet-wide, so on a host whose two nodes sit exactly
30 minutes apart, one node's review tick lands one minute before the other
node's cycle (`03:05` and `03:06` here, `03:35` and `03:36` again). It is
cheap on almost every day, because a review exits early unless
`project_review.defaults.min_days_between_reviews` (or a repo's own override)
has passed for the repo it would review. The
fleet-wide fix, if it ever stops being cheap, is `review_offset_minutes: 15` in
`config.json`, which on this four-node ring interleaves reviews exactly between
cycles on both hosts — at the cost of halving the gap between a node's own two
pipelines. Note also that an offset of 29 lands the reviews *on* the
five-minute marks the cycles were nudged off (29 past `:06` is `:35`). That is
the same light contention, once a day, on a tick that most days does nothing —
worth knowing, not worth solving.

### Taking a node out of service

```bash
docker compose down            # keeps the volumes — the node can come back
docker compose down -v         # discards them, including the Claude login
```

`down -v` on the active node loses nothing the fleet needs — its state was
published at the end of its last cycle — but it does mean a fresh Claude login
when it returns.

### A second node on one host

Two stacks share a machine happily — it is how a second active node is soaked
before any VM exists. The one rule: a different `COMPOSE_PROJECT_NAME`, or the
two stacks silently share volumes and fight over one identity.

```bash
mkdir ~/poetic-node-2 && cd ~/poetic-node-2
# compose.yaml + .env as in "Bring up a node", then in .env:
#   COMPOSE_PROJECT_NAME=agent-ops-2   # distinct volumes — non-negotiable
#   NODE_NAME=<host>-2                 # its own name, its own state branch
#   GH_TOKEN=<its own PAT>             # one token per node, so one node can be revoked
#   DASHBOARD_PORT=8789                # the first node has 8787
#   ROLE=standby                       # promote only after the checks below
docker compose up -d
docker compose exec scheduler claude   # OAuth path only — skip if ANTHROPIC_API_KEY is set in .env
```

Before setting `ROLE=active` on the newcomer: `docker compose images` in
**both** directories — the two nodes must run the same image digest (a claim
scheme only arbitrates between nodes that share it); then watch the fleet
strip on either dashboard until the new node's heartbeat shows. `CYCLE_MINUTE`
can stay unset to begin with — the hash default already lands the two nodes on
different minutes — but two nodes on one host is exactly the case where the
arbitrary default is worth replacing with a chosen one: see [Spreading the
fleet across the hour](#spreading-the-fleet-across-the-hour).

---

## When it misbehaves

| Symptom | Cause | Fix |
|---|---|---|
| A service restart-loops with `... is not writable by agent` | A volume created by an older image, or bind-mounted from another uid | `docker compose down -v` if losing it is acceptable, or rebuild with `--build-arg PUID=<owner>` |
| A fresh node's first `up` aborts with `mkdir … /cycles: file exists` | Two services seeding the same new `state` volume at once — the current `compose.yaml` prevents this by starting the dashboard after the scheduler, so you only see it on a compose file fetched before that fix | `docker compose down -v`, then `docker compose up -d scheduler` before `docker compose up -d` |
| Every cycle fails at its first stage | Claude was never authenticated on this node | Step 4 above |
| `WARNING: GH_TOKEN is unset` | No token in `.env` | Add it; this node can otherwise neither read nor push anything |
| `agent-cycle: ERROR: GIT_USER_NAME and/or GIT_USER_EMAIL is unset` in the cron log | No git identity in `.env` — checked by the cycle itself, not the container, so this only appears once an active node's next tick tries to do real work | Add both to `.env` and `docker compose up -d` to pick them up; the next tick will use them |
| `cannot clone …agent-ops-state` | The token cannot read the private state repo | Widen the token's repository access |
| `gh auth status` says the token is invalid, but the same token works on the host; `git clone` resets; `claude` hangs | The bridge MTU exceeds the host's egress MTU — full-sized packets vanish, so every TLS handshake fails while DNS and plain HTTP still work | Set `DOCKER_MTU` in `.env` to the host's egress MTU and `docker compose up -d` |
| The cycle line only ever says `skipped — this node is standby` | Working as intended on a standby | Set `ROLE=active` on any node that should spend — several may be |
| A cycle logs `claim-lost` and moves on | A peer node won that item's claim | Working as intended — the next candidate (or the next cycle) picks different work |
| A cycle died mid-run around an image update | Something recreated the scheduler while a cycle was running, and that kills the whole process group. watchtower no longer does this — the pre-update hook defers its roll — so the culprit is a manual `docker compose up -d`, `restart`, or `down`, none of which consult the hook | Nothing to repair: the lock is taken over as stale next hour and the claim GC releases anything it held, though an orphaned clone under `workspace_root` and any branch already pushed are left behind. Run `--status` and wait for a running cycle to finish before any manual recreate |
| A node has stopped taking new images, and `docker compose logs watchtower` shows `deferring this update` every poll | The pre-update hook is doing its job — a cycle really is in flight — or a lock is being held by a live process that is itself wedged. If the message says `written by container`, the deferring container is honouring a lock it cannot liveness-check (the dashboard reading the scheduler's, or a lock left by a crashed cycle): that clears when the writer releases it, the next cycle takes it over (within the hour), or it goes stale | None of these needs a fix: the hook stops honouring a lock once it passes `lock_stale_after` (4h for a cycle, 6h for a review), so the roll lands by then at the latest. To roll now, `--disable 'reason'`, wait for `--status` to read idle, `docker compose pull && up -d`, then `--enable` |
| `watchtower` exits at start with `Only schedule or interval can be defined, not both` | `.env` sets `WATCHTOWER_SCHEDULE` without clearing `WATCHTOWER_POLL_INTERVAL` | They are mutually exclusive. Either drop the schedule, or add a bare `WATCHTOWER_POLL_INTERVAL=` line beneath it — an empty value does not count as set |
| The dashboard URL times out | The page is only ever reachable on the host's loopback: over the tailnet on the `tailnet` profile, at `http://127.0.0.1:$DASHBOARD_PORT` on the `local` one. From another machine, neither answers by design | Browse it from the host itself, or use the `tailnet` profile and browse the node's tailnet name |
| `Bind for 127.0.0.1:8787 failed: port is already allocated` on the `local` profile | Something already holds that port on the host — a second node's stack, or on the laptop the legacy SysV dashboard | Set `DASHBOARD_PORT` in `.env` |
| Nothing happens on any node | The shared switch is set | `--status` to see the reason, `--enable` to clear it |
| A node's card shows `compose drifted` or `compose unverified` | Its `compose.yaml` has fallen behind the repository — a merged compose change was never applied there (`drifted`), or the file is too old even to carry the mount the check reads (`unverified`) | The ritual in [Keeping the compose file current](#keeping-the-compose-file-current): wait for idle, re-fetch `compose.yaml`, `docker compose up -d`; `./check-node-compose.sh` to verify, containers included |
| A node's card shows an amber `image behind` | The registry's newest image has existed longer than `image_behind_grace_hours` and this node still has not adopted it — a normal deferral has outlived the grace period this page gives it | See [Is this node on the newest image](#is-this-node-on-the-newest-image): `docker compose logs watchtower` for whether it is still polling, `./check-node-image.sh` to re-check directly |
| A node's card shows `image unverified` | The registry could not be reached from inside the node, or (only right after this check first rolls out) its heartbeat predates it | Usually resolves on its own within a few heartbeats; `./check-node-image.sh` names the reason if it does not |
| A container disappears and comes back, and `docker inspect --format '{{.State.ExitCode}}'` says **137** | The OOM killer took it: the service outgrew the `mem_limit` `compose.yaml` gives it. The ceilings carry roughly 5x headroom over measured usage, so this means either genuine growth in what a stage reads or a leak worth finding | Raise that service's `AGENT_OPS_*_MEMORY` in `.env` and `docker compose up -d`. Do not remove the limit — an unbounded container on a small host takes the *host* down instead, which is the failure the ceiling exists to convert into this one. `docker stats` shows current usage against the ceiling in force |
| `watchtower` crash-loops (`Restarting`) with `client version 1.25 is too old. Minimum supported API version is 1.40` | The unmaintained `containrrr/watchtower` image defaults to an ancient Docker API version that a modern daemon (Docker 25+, e.g. a fresh Ubuntu 26.04 host) rejects — so the node stops auto-updating and drifts off the fleet digest | `compose.yaml` now pins `DOCKER_API_VERSION` (default `1.40`) for watchtower; a node provisioned before that needs its `compose.yaml` re-fetched, then `docker compose up -d watchtower`. Override the version in `.env` only if a daemon needs a different one |

---

## Unattended bring-up

`cloud-init.yaml` in this directory performs steps 1–3 on a fresh Ubuntu VM.
Fill in the two secrets before you paste it as user-data; step 4 (the Claude
login) is interactive and has to happen afterwards over SSH.
