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
  `Poetic-Poems/agent-ops-state` (contents, pull requests, issues) plus read on
  security alerts. One token per node, so a single node can be revoked without
  disturbing the others.
- A **git identity** — a name and an email — for the commits this node's
  cycles make. There is no default; an active node's cycles refuse to run
  without both.
- A **Tailscale pre-auth key** from the tailnet's admin console, unless this
  node will run the `local` profile.
- Somewhere to log in to Claude interactively, once, after step 3.

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
curl -fsSLO "https://raw.githubusercontent.com/Poetic-Poems/agent-ops/main/scripts/watch-node.sh"
chmod +x watch-node.sh
$EDITOR .env
```

`watch-node.sh` is the one command for following this node's pipeline output
once it is up (see [Follow a node's events](#follow-a-nodes-events) below),
fetched now so it sits beside `compose.yaml` from the start.

At minimum set `NODE_NAME`, `GH_TOKEN`, `GIT_USER_NAME`, `GIT_USER_EMAIL` and —
for the `tailnet` profile — `TS_AUTHKEY`. Leave `ROLE=standby` unless this node
is meant to be the one that spends; see [Which node runs the
cycles](../../README.md#which-node-runs-the-cycles).

`.env` holds this node's secrets. It is git-ignored, and if a token ever lands
in a commit the answer is to rotate it, not to rewrite history.

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

### 4. Authenticate Claude, once

```bash
docker compose exec scheduler claude
```

Complete the login. The credentials land in the `claude-config` volume, which
outlives every container this node will ever run — this is the one thing here
that cannot be rebuilt from the image, and the entrypoint warns on every start
until it exists.

Verify:

```bash
docker compose exec scheduler claude -p 'say ok' --model claude-haiku-4-5-20251001
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
| Resume | `docker compose exec scheduler /app/agent-cycle.sh --enable` |
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
this one" — while either pipeline's lock is held by a live process. The roll
lands on the next poll instead, five minutes later, and keeps landing there
until the node is idle. A cycle can only push it back by so far: the hook
respects a lock exactly as long as a cycle would, so a lock past
`lock_stale_after` stops deferring anything.

You can watch it happen:

```bash
docker compose logs watchtower | grep -A2 'Command output'
```

`no cycle in flight` means the roll went ahead; `deferring this update` names
the pipeline and the pid it waited for. A deferral is counted as a *failed*
container in watchtower's session summary — that is watchtower's own wording
for "did not update", not a fault.

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
3. Watch the next hourly tick: an active node runs a cycle; a standby logs
   `skipped — this node is standby`. Either way its heartbeat keeps
   publishing.

To confirm a node is following the fleet's memory rather than only its own:

```bash
docker compose exec scheduler ls /home/agent/.cache/poetic-agents/workspaces/.agent-ops-peers
docker compose exec scheduler tail -n 3 /home/agent/.cache/poetic-agents/workspaces/.agent-ops-peers/*/log.jsonl
```

Those should name the *other* nodes and show their recent events. That is the
whole purpose of the fetch: a lesson any node learned spares the rest.

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
docker compose exec scheduler claude   # authenticate once, then exit
```

Before setting `ROLE=active` on the newcomer: `docker compose images` in
**both** directories — the two nodes must run the same image digest (a claim
scheme only arbitrates between nodes that share it); then watch the fleet
strip on either dashboard until the new node's heartbeat shows. `CYCLE_MINUTE`
can stay unset — the hash default already lands the two nodes on different
minutes.

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
| The hourly line only ever says `skipped — this node is standby` | Working as intended on a standby | Set `ROLE=active` on any node that should spend — several may be |
| A cycle logs `claim-lost` and moves on | A peer node won that item's claim | Working as intended — the next candidate (or the next cycle) picks different work |
| A cycle died mid-run around an image update | Something recreated the scheduler while a cycle was running, and that kills the whole process group. watchtower no longer does this — the pre-update hook defers its roll — so the culprit is a manual `docker compose up -d`, `restart`, or `down`, none of which consult the hook | Nothing to repair: the lock is taken over as stale next hour and the claim GC releases anything it held, though an orphaned clone under `workspace_root` and any branch already pushed are left behind. Run `--status` and wait for a running cycle to finish before any manual recreate |
| A node has stopped taking new images, and `docker compose logs watchtower` shows `deferring this update` every poll | The pre-update hook is doing its job — a cycle really is in flight — or a lock is being held by a live process that is itself wedged | Neither needs a fix: the hook stops honouring a lock once it passes `lock_stale_after` (4h for a cycle, 6h for a review), so the roll lands by then at the latest. To roll now, `--disable 'reason'`, wait for `--status` to read idle, `docker compose pull && up -d`, then `--enable` |
| `watchtower` exits at start with `Only schedule or interval can be defined, not both` | `.env` sets `WATCHTOWER_SCHEDULE` without clearing `WATCHTOWER_POLL_INTERVAL` | They are mutually exclusive. Either drop the schedule, or add a bare `WATCHTOWER_POLL_INTERVAL=` line beneath it — an empty value does not count as set |
| The dashboard URL times out | The page is only ever reachable on the host's loopback: over the tailnet on the `tailnet` profile, at `http://127.0.0.1:$DASHBOARD_PORT` on the `local` one. From another machine, neither answers by design | Browse it from the host itself, or use the `tailnet` profile and browse the node's tailnet name |
| `Bind for 127.0.0.1:8787 failed: port is already allocated` on the `local` profile | Something already holds that port on the host — a second node's stack, or on the laptop the legacy SysV dashboard | Set `DASHBOARD_PORT` in `.env` |
| Nothing happens on any node | The shared switch is set | `--status` to see the reason, `--enable` to clear it |
| `watchtower` crash-loops (`Restarting`) with `client version 1.25 is too old. Minimum supported API version is 1.40` | The unmaintained `containrrr/watchtower` image defaults to an ancient Docker API version that a modern daemon (Docker 25+, e.g. a fresh Ubuntu 26.04 host) rejects — so the node stops auto-updating and drifts off the fleet digest | `compose.yaml` now pins `DOCKER_API_VERSION` (default `1.40`) for watchtower; a node provisioned before that needs its `compose.yaml` re-fetched, then `docker compose up -d watchtower`. Override the version in `.env` only if a daemon needs a different one |

---

## Unattended bring-up

`cloud-init.yaml` in this directory performs steps 1–3 on a fresh Ubuntu VM.
Fill in the two secrets before you paste it as user-data; step 4 (the Claude
login) is interactive and has to happen afterwards over SSH.
