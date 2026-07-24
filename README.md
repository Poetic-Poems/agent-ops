# Poetic Autonomous Implementation Agent System

A self-hosted, unattended pipeline that automatically selects, implements, and reviews pending work from the [poetic](https://github.com/Poetic-Poems/poetic) and [poetic-fiddle](https://github.com/Poetic-Poems/poetic-fiddle) repositories, raising mergeable pull requests for human review and approval.

## What it does

Once an hour:

1. **Co-Ordinator** (Haiku) selects at most one well-scoped item of work (security findings, review feedback, merge conflicts on otherwise-ready PRs of ours, abandoned draft PRs of ours, failed CI runs, tech-debt, issues, fiddle's implementation plan, project-review recommendations, or code-quality findings). Security work — open Dependabot alerts and security code-scanning alerts — is always prioritised ahead of everything else, answering your review feedback comes second, rebasing a ready PR of ours that has hit a merge conflict comes third, and finishing a draft PR this system started and then abandoned comes fourth.
2. **Implementor** (Sonnet/Haiku) clones the repo, implements the item on a feature branch, and opens a draft pull request — or, for review feedback, pushes to the existing branch of the PR you commented on.
3. **Reviewer** (Sonnet) checks and corrects the implementation, then marks the PR ready for review.
4. **Human** reviews and merges via the normal GitHub process (the only gate).

If no suitable item exists, or if back-pressure shows open agent PRs, the cycle stands down — cheaply, without waking the Co-Ordinator, when nothing has changed since it last found nothing to do (see [Skipping no-op cycles](#skipping-no-op-cycles)).

## Responding to your review comments

Request changes on an agent PR and the next cycle picks it up: it reads your
review, pushes a fix to the same branch, replies point by point saying what it
changed and what it didn't and why, and re-requests your review. It never opens
a second PR for this, and it never re-does the original work — it amends what's
there.

This sits second in priority, above everything but security: you're the only
consumer this system has, so answering you beats starting something new.

Three things to know:

- **The agent can't clear your `CHANGES_REQUESTED`, ever.** GitHub won't let a
  PR's author dismiss a review on their own PR, and the agent raises PRs as
  you (`warwickallen`). So the PR stays `BLOCKED` and un-mergeable until *you*
  re-review. That's not a bug to route around — it's the human gate, enforced
  by GitHub rather than by good intentions.
- **It answers each round exactly once.** Whose turn it is comes from comparing
  your latest review against the branch's head commit: review newer means the
  agent owes you a reply; commit newer means it has replied and is waiting on
  you. Request changes again and it comes straight back.
- **Put the substance where it'll be read.** Every review body and inline
  comment in the round is passed to the agent verbatim, whichever account wrote
  it — so a detailed `COMMENTED` review from one account plus a bare
  `CHANGES_REQUESTED` from another works fine. Say which findings block a merge
  and which don't; the agent honours that split.

Only PRs this system raised are eligible (labelled `autonomous-agent`, on an
`agent/` branch). Your own branches are never touched.

Back-pressure doesn't block this: if every agent PR is sitting on "changes
requested", the cycle restricts itself to review feedback rather than standing
down, so it can always dig itself out. It still can't open a new PR while the
gate is full.

## Configuration

Edit `config.json` before first run. Keys:

| Key | Default | Notes |
|---|---|---|
| `repos` | see `config.json` | Array of `{"slug": "...", "sources": [...]}`. `sources` is that repo's work sources in priority order (`security`, `review-feedback`, `merge-conflicts`, `abandoned-drafts`, `failed-runs`, `tech-debt`, `issues`, `implementation-plan`, `project-review`, `code-quality`). `security` (open Dependabot + security code-scanning alerts) is always first, and any security-related item is prioritised ahead of all non-security work; `review-feedback` (agent PRs where you asked for changes we haven't answered yet) comes second and likewise outranks the repo walk — finishing beats starting, and a stuck PR otherwise occupies a back-pressure slot forever; `merge-conflicts` (agent PRs otherwise ready for review or merge but conflicting with their base) comes third for the same reason — a rebase-and-resolve unblocks a PR you are waiting to land, and nothing else on it can proceed until it merges cleanly; `abandoned-drafts` (draft PRs this system raised and then left untouched past `abandoned_draft_after_hours`) comes fourth for the same reason — finishing a stalled draft of ours turns a slot silted with a dead draft into a PR you can merge; `project-review` (the latest weekly review's recommendations that aren't already tech-debt or issues) sits just above `code-quality` (non-security code-scanning findings), which is last. Adding a repo or source is a config-only change. At runtime, repos are ordered by least-recently-updated default branch first, ahead of this list order. |
| `state_dir` | `~/.local/state/poetic-agents` | Lock, shared log, stage transcripts. |
| `workspace_root` | `~/.cache/poetic-agents/workspaces` | Ephemeral clones. Each cycle gets its own subdirectory, and the state repository keeps its mirror here. |
| `state_repo` | `Poetic-Poems/agent-ops-state` | Private repository through which `state_dir` replicates between nodes. See [Keeping every node warm](#keeping-every-node-warm). Leave it out and nothing syncs — a single-node install behaves exactly as before. |
| `candidates_max` | 3 | How many ranked candidates the Co-Ordinator returns; the Script claims down the list, so a lost race costs the next-best item rather than the cycle. |
| `claim_ttl_hours` | 6 | Hours before a dead node's claim-registry entry is swept (`lib/claim.sh gc`); far beyond one full cycle. |
| `abandoned_draft_after_hours` | 3 | Hours a draft PR this system raised may sit untouched before it counts as abandoned and finishing it becomes selectable work (the `abandoned-drafts` source). Beyond one full cycle, so a draft still being worked never qualifies. |
| `cycles_retained` | 200 | Cycle directories kept in the replicated copy (~8 days of hourly cycles). Your own `state_dir` is not pruned. |
| `coordinator_model` | `claude-haiku-4-5-20251001` | Selection is cheap triage. |
| `implementor_model_default` | `claude-sonnet-5` | For code changes. |
| `implementor_model_trivial` | `claude-haiku-4-5-20251001` | For docs, comments, register entries only. |
| `reviewer_model` | `claude-sonnet-5` | Quality gate before human review. |
| `pr_label` | `autonomous-agent` | Applied to every PR this system raises. |
| `branch_prefix` | `agent/` | Branch naming: `agent/<item-slug>`. |
| `max_open_agent_prs` | `3` | Back-pressure limit: total open agent PRs (draft or ready) across both repos. |
| `timeout_coordinator` | 15 | Minutes. |
| `timeout_implementor` | 90 | Minutes. |
| `timeout_reviewer` | 30 | Minutes. |
| `lock_stale_after` | 3 | Hours. Stale lock is killed and warning is logged. |
| `limit_cooldown_default` | 3 | Hours. Stand-down after a usage-limit error. |
| `disable_default_ttl` | 4 | Hours. How long `--disable` lasts when `--for` doesn't say. See [Pausing the pipelines](#pausing-the-pipelines). |
| `none_selected_recheck_hours` | 24 | Hours. The Co-Ordinator is engaged at least this often even when nothing has changed. See [Skipping no-op cycles](#skipping-no-op-cycles). `0` disables that safety net entirely — not recommended. |
| `dashboard_refresh_seconds` | 5 | Seconds. How often an open dashboard tab reloads to pick up freshly-written data, matching the [heartbeat](#keep-it-fresh) cadence. Untick the page's *auto-refresh* box to pause it while reading. |

The `review` object configures the separate weekly project-review pipeline — see [Weekly project review](#weekly-project-review).

## Installation

**Run a node as a container.** The image (`deploy/docker/`) carries the whole
toolchain and needs nothing on the host but Docker, and it is the deployment
artefact: `/app` inside it *is* agent-ops, so a node updates by pulling a new
image rather than by pulling a branch. The full runbook — bring-up, operations,
the failover drill, troubleshooting — is **[deploy/docker/README.md](deploy/docker/README.md)**.

The **host install** further below is the laptop's old path, in which the
scripts ran straight out of a checkout under the user crontab and a SysV init
script. That cut-over is done — the laptop now runs as a container node like
every other — so those sections are retained only as a record of the retired
deployment; nothing runs that way any more.

### As a container

A node is one Compose project. Every node runs the same file and the same
image; the only thing that differs between two nodes is its `.env`.

```bash
mkdir -p ~/poetic-node && cd ~/poetic-node
base=https://raw.githubusercontent.com/Poetic-Poems/agent-ops/main/deploy/docker
curl -fsSLO "$base/compose.yaml"
curl -fsSLO "$base/ts-serve.json"
curl -fsSL  "$base/.env.example" -o .env
$EDITOR .env          # name the node, set its role, paste its tokens
docker compose up -d
docker compose exec scheduler claude   # authenticate this node, once
```

The node holds those three files and no clone. On a fresh cloud VM,
[`deploy/docker/cloud-init.yaml`](deploy/docker/cloud-init.yaml) does all of
that unattended except the Claude login.

`COMPOSE_PROFILES` in that `.env` decides what the node runs:

| Profile | What it adds |
|---|---|
| `tailnet` | Tailscale sidecar + the dashboard, served to your tailnet over HTTPS at `https://<node>.<tailnet>` — never to the public internet |
| `local` | the dashboard on the machine's own loopback instead (`http://127.0.0.1:8787`), for a node with no tailnet or no authkey |
| `auto-update` | watchtower, which pulls new images and restarts into them |

The scheduler is in no profile: it runs on every node, whatever else does.

Four things are worth knowing:

- **`/app` is the deployment.** The image is built from this repository, so a
  node updates by pulling a new image — never by pulling a branch inside a
  running container. Every merge to `main` builds one and publishes it to
  `ghcr.io/poetic-poems/agent-ops` as `latest` (what watchtower follows) and as
  the commit SHA. To pin a node to a known-good build, or to roll one back, set
  `AGENT_OPS_IMAGE=ghcr.io/poetic-poems/agent-ops:<sha>` in its `.env`.
- **`~/.claude` and `state_dir` must be volumes.** Claude's OAuth credentials
  refresh and write back, and `state_dir` is the pipelines' memory. The
  entrypoint seeds `settings.json` only when it is absent, and refuses to start
  if `state_dir` is not writable by the container user (uid 1000 by default;
  rebuild with `--build-arg PUID=…` to match a host directory).
- **Authenticate once per node**: `docker compose exec scheduler claude` and
  complete the login. Until then every cycle fails at its first stage; the
  entrypoint warns about it on each start.
- **The dashboard is never published by a port.** Its server binds `127.0.0.1`
  by design, so `ports:` would reach nothing. The `tailnet` profile shares the
  Tailscale sidecar's network namespace instead; the `local` profile shares the
  host's. If the host already has something on 8787, set `DASHBOARD_PORT` in
  `.env`.

Set `ROLE=active` in the `.env` of every node meant to spend — any number may
be, since per-item claims keep them off each other's work (see
[Which node runs the cycles](#which-node-runs-the-cycles)); the rest stay
`standby`. Then read
[deploy/docker/README.md](deploy/docker/README.md) for everything after that.

### On the host (legacy, decommissioned)

How the laptop ran before the cut-over — straight out of a checkout, under the
user crontab and a SysV init script. **No node runs this way now**; the steps
are kept as a record of the retired path, not as an install route. A new node
is a container: Docker and the `.env` above are the whole of it.

1. **Create the repo:**
   ```bash
   gh repo create Poetic-Poems/agent-ops --public --description "Autonomous agent pipeline for poetic and poetic-fiddle"
   ```

2. **Install the standalone Claude CLI:**
   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   # or
   npm install -g @anthropic-ai/claude-code
   ```
   Test headless auth directly:
   ```bash
   claude -p "Reply with OK" --model claude-haiku-4-5-20251001
   ```
   Also verify that the same environment cron will use can find Claude. A minimal cron-style sanity check is:
   ```bash
   env -i HOME="$HOME" PATH="$HOME/.local/bin:$HOME/.claude/local:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /bin/bash -lc 'command -v claude && claude -V'
   ```
   If that fails, add a launcher such as `~/.local/bin/claude` or update the crontab PATH before continuing.

3. **Enable cron (WSL):**
   Edit `/etc/wsl.conf` (requires `sudo`):
   ```ini
   [boot]
   command = "service cron start"
   ```
   Then restart WSL: `wsl --shutdown` (from Windows).

   *Alternative (Windows Task Scheduler):* Create a task running `wsl.exe -u wallen -e $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh` hourly.

4. **Create the PR label in both repos:**
   ```bash
   gh api -X POST repos/Poetic-Poems/poetic/labels \
     -f name='autonomous-agent' \
     -f color='ededed' \
     -f description='PR raised by the autonomous agent system'

   gh api -X POST repos/Poetic-Poems/poetic-fiddle/labels \
     -f name='autonomous-agent' \
     -f color='ededed' \
     -f description='PR raised by the autonomous agent system'
   ```
   If your `gh` version already supports `gh label create`, that form also works; the API form above is the most compatible fallback.

5. **Enable the security work sources on both repos.** The `security` and `code-quality` sources read GitHub's own Dependabot alerts and code-scanning (CodeQL) alerts, so those features must be turned on for the alerts to exist:
   - In each repo's **Settings → Code security**, enable **Dependabot alerts** and **Code scanning** (a default CodeQL setup is fine). Free for public repos; private repos need GitHub Advanced Security.
   - The `gh` token must be able to read the alerts — the `security_events` scope (or `repo` on a classic token). Verify:
     ```bash
     ./scripts/gather-findings.sh Poetic-Poems/poetic
     ```
     You should get a JSON array of findings (or `[]` if there are none). If a feature is off or the token can't read it, the script simply returns `[]` and the pipeline keeps working — you just won't get findings from that source.

6. **Review and edit the local `config.json` file in this repository** (the one at `~/Code/Poetic-Poems/agent-ops/config.json` if you cloned it there). This is the agent system's own configuration file, not the target repos' config files. The main things to check are the `repos` list (which repositories and work sources to scan), the `pr_label`/`branch_prefix` values, and the timeout/cooldown settings if you want to tune behaviour for your environment.

7. **Install the crontab:**
   ```bash
   (crontab -l 2>/dev/null || true; echo "AGENT_OPS_ROLE=active"; echo "0 * * * * $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh >> $HOME/.local/state/poetic-agents/cron.log 2>&1") | crontab -
   ```
   The `AGENT_OPS_ROLE=active` line is what marks this machine as the one that
   runs unattended cycles (see "Which node runs the cycles" below). Without it
   every tick stands down, which is the point: only one machine may spend.
   Verify it was installed successfully:
   ```bash
   crontab -l
   ```
   You should see a line containing `Poetic-Poems/agent-ops/agent-cycle.sh` in the output. Then confirm that cron's PATH can reach Claude:
   ```bash
   env -i HOME="$HOME" PATH="$HOME/.local/bin:$HOME/.claude/local:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /bin/bash -lc 'command -v claude && claude -V'
   ```
   If this still fails, fix the PATH in the crontab (or install a symlink in `~/.local/bin`) before relying on scheduled runs.

## Operation

### Dry run (no agents launched)
```bash
./agent-cycle.sh --dry-run
```
Completes stand-down checks, repo ordering, and coordinator selection, then exits. Prints the selected work order.

### One cycle (foreground, verbose)
```bash
./agent-cycle.sh --once
```
Launches implementor and reviewer in the foreground. Leaves the PR and workspace for inspection.

### Restrict to one repo (for testing)
```bash
./agent-cycle.sh --repo poetic
```

## Pausing the pipelines

Each node runs the pipelines from the image baked into it, not from a
checkout, so editing this repo no longer risks a running cycle (that hazard
belonged to the old host install; see [Development](#development)). What the
switch is for now is standing the fleet down deliberately — around a rollout
that would otherwise roll a node mid-cycle, or simply to stop spend. It does
so everywhere at once. On a container node you drive it through the scheduler:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling out PR #NN"  # expires after disable_default_ttl (4 h)
docker compose exec scheduler /app/agent-cycle.sh --disable "big refactor" --for 8h  # or 90m, 2d, or `forever`
docker compose exec scheduler /app/agent-cycle.sh --status   # what's set, and is anything running?
docker compose exec scheduler /app/agent-cycle.sh --enable   # resume
```

(From a shell on the node — `docker compose exec scheduler bash` — the bare
`./agent-cycle.sh …` form works, since `/app` is the working directory.)

The switch is one file (`$state_dir/disabled.json`) shared by **both**
`agent-cycle.sh` and `review-cycle.sh` — they run out of the same tree, so
stopping one and not the other stops nothing much. `agent-cycle.sh` is the only
way to set it; `review-cycle.sh` only obeys it. And it reaches the whole
fleet: `--disable` also publishes `fleet/disabled.json` to the state
repository (warning loudly if it cannot), every node checks that flag at
cycle start, and `--enable` clears both levels — so one command from any
node stands the entire operation down, or up.

Three things worth knowing:

- **Disabling stops the *next* cycle, not one already running.** `--status`
  tells you whether a cycle is in flight, and `--disable` warns you if there
  is. Wait for it to finish before rolling a new image onto the node — a
  watchtower roll or a manual `up -d` kills a cycle mid-flight (`TD26072301`).
- **A disable expires by default.** The point is not tidiness: an agent that
  disables the pipeline and then dies would otherwise stop every future cycle
  silently — "no PRs" looks exactly like a quiet week. The TTL turns a
  forgotten switch into a few lost cycles. Use `--for forever` when you mean
  it, and `--enable` when you're done.
- **A reason is required**, because the next person wondering why nothing has
  happened is entitled to one. It shows up in `--status`, in the log, and on
  the dashboard banner.

## Which node runs the cycles

The pipelines run on any number of machines — a laptop, a cloud VM, several —
and **any number of them may cycle at once**: per-item claims (requirement
17a) keep concurrent actives off each other's work, and per-node minute
offsets (D5) keep them from even firing together. The environment variable
`AGENT_OPS_ROLE` says whether *this* machine spends unattended:

```bash
AGENT_OPS_ROLE=active     # this machine runs the hourly cycle and the daily review tick
AGENT_OPS_ROLE=standby    # ...anything else does not
```

On a containerised node, set `ROLE=active` in `deploy/docker/.env` — the
scheduler service passes it through as `AGENT_OPS_ROLE`, and defaults it to
`standby` when it is missing. On the host, set it in the crontab (a bare
`AGENT_OPS_ROLE=active` line above the schedule lines) or in the environment of
whatever runs the scripts. Only the exact value
`active` counts — case and surrounding whitespace are ignored, but **unset,
empty or misspelt all mean standby**. That is deliberate: a machine wrongly
standby costs skipped cycles, while a machine wrongly active spends money
nobody chose to spend. Any number of machines may be `active` at once —
per-item claims keep them off each other's work — so the role does not elect
a leader; it says whether *this* machine spends unattended.

A standby tick writes one line to the cron log and exits; it creates no cycle,
logs no event, and spends nothing. A standby is not idle, though — it
publishes its heartbeat and follows every peer's memory (see [Keeping every
node warm](#keeping-every-node-warm)), so promoting it is one variable, not a
hand-off.

What the role does *not* stop:

- `--dry-run` and `--once` — a human asking for a cycle is not an unattended
  one, and both run on any machine.
- `--disable`, `--enable` and `--status` — the switch is shared state and must
  be readable and settable from wherever you happen to be.
- The dashboard, which is worth serving on every node.

## Keeping every node warm

A node that knows only its own history would re-try what a peer has already
tried and re-learn every no-op the hard way. So every node publishes its
memory, and every node follows everyone else's.

`scripts/state-sync.sh` works through the private repository named by
`state_repo`, one branch per node, in two modes — both on every node:

| Mode | When | What |
|---|---|---|
| `push` | every five minutes, and at the end of every cycle | publishes `state_dir` as this node's own `nodes/<NODE_NAME>` branch, stamped with a heartbeat (`{node, role, ts, last_cycle}`) |
| `fetch` | every seven minutes | materialises every peer's branch under the peers directory, whole, and prunes a peer whose branch is gone |

What travels is the memory: `log.jsonl`, `review-log.jsonl`, `cycles/`,
`reviews/`, the switch, the cron logs. What stays behind is anything local or
derived — the live locks (peers read logs, never locks), the generated
dashboard, and each node's own sync log. Each branch keeps the newest
`cycles_retained` cycles and is a single amended commit, so the repository
does not grow; your own `state_dir` keeps the longer record, pruned to
`state_local_cycles_retained` by the same push. No two nodes share a branch,
so pushes cannot collide and nothing arbitrates them.

The pipelines read the **union** of all those logs — a blocked item, a void
verdict, a no-op fingerprint or a usage-limit hit learned by any node stands
the rest of the fleet down (or spares it a re-check) within one fetch
interval. The union is advisory speed; the per-item claims are the lock
underneath. Cross-node work arbitration has no other mechanism — there is no
lease and no leader.

Every node needs a `GH_TOKEN` that can read and write the state repository.
Leave `state_repo` out of `config.json` and none of this happens at all.

## Skipping no-op cycles

The Co-Ordinator costs the same to say "nothing to do" as it does to select
work — about 2½ minutes of Haiku, reading both repos. On a quiet week that was
24 identical answers a day, all of them paid for.

So before launching it, the Script fingerprints everything the Co-Ordinator's
verdict depends on: each repo's head commit, its pre-fetched findings, its open
issues (with labels and assignees), the conclusion of each workflow's latest
run, its open PRs (a PR is a claim), the blocked and void lists, the selection
config, and a hash of `prompts/coordinator.md`. If that fingerprint matches the
one recorded against the last `none-selected`, nothing the Co-Ordinator reads
has moved, so its answer cannot have changed — the cycle stands down for the
price of a few `gh` calls.

The claim is only ever "nothing changed", never "there is no work". If anything
at all is different — including a repo the Script couldn't read cleanly — the
Co-Ordinator runs. And `none_selected_recheck_hours` (24 h) forces it to run
anyway once a day regardless, so if some future work source is ever missed by
the fingerprint, the cost is a day's delay rather than a pipeline that has
quietly stopped picking up work forever.

`--dry-run` and `--once` always ask the Co-Ordinator: a human asking for a
cycle wants an answer, not a cached verdict.

```bash
# Why did a cycle stand down?
jq -r 'select(.event == "stand-down") | "\(.ts)  \(.reason)"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -5
```

### See the log
```bash
tail -f ~/.local/state/poetic-agents/log.jsonl
```
One event per line (JSON). See `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (requirement 33) for event types and fields.

### Blocked and void items
Two different reasons the pipeline will skip an item, with two different
remedies:

- **Blocked** — real work, something is in the way. The Co-Ordinator re-checks
  these itself and clears them (an `unblocked` event) once the impediment has
  gone, so usually you need do nothing.
- **Void** — there is no work: the item is already done, or its premise was
  false. No agent can ever clear this, by design — the only evidence that would
  ever turn up ("it's already done") is the reason it is void, so an agent
  allowed to clear it would free the item to be rediscovered every cycle.

Both are listed on the dashboard. To reopen a void item — you believe the work
has genuinely regressed, or the verdict was wrong — append an `unvoided` event
by hand while no cycle is running:

```bash
printf '%s\n' "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ts: $ts, cycle: "manual", event: "unvoided", item: "review-2026-07-11-R-02"}')" \
  >> ~/.local/state/poetic-agents/log.jsonl
```

Omit `repo` to reopen the item in every repo, or add it to scope the change to
one. The item becomes a candidate again on the next cycle; if there is still no
work, the Implementor will simply void it again.

### See stage transcripts
```bash
ls -la ~/.local/state/poetic-agents/cycles/
```
Each cycle gets a directory (`<cycle-id>/`) with one `<stage>.out` (the
`claude --output-format json` envelope on stdout — this is what gets parsed)
and one `<stage>.out.stderr` (diagnostics) per stage that ran. When a cycle
pre-fetches findings, that directory also holds `findings-<owner>_<repo>.json`
(the normalised Dependabot + code-scanning alerts the Co-Ordinator was given).

### See the security & code-quality findings
The Co-Ordinator's security and code-quality candidates come from a
deterministic pre-fetch, not the model, to save credits — the Script runs
`scripts/gather-findings.sh` once per repo and injects the result. Run it
yourself to see exactly what the agents see:
```bash
./scripts/gather-findings.sh Poetic-Poems/poetic
```
It prints a JSON array of the repo's open Dependabot alerts and code-scanning
alerts (security-severity ones tagged `"source":"security"`, the rest
`"source":"code-quality"`), most severe first. It always prints valid JSON and
exits 0, returning `[]` when a repo has the features off or the token can't
read them.

## Weekly project review

A second, independent pipeline runs a full **project review** of each target
repo about once a week and opens a pull request with the results — a set of
Markdown reports (summary, findings, prioritised recommendations, ready-to-use
improvement prompts) plus an updated `TECH-DEBT.md`. Merging that PR feeds the
hourly pipeline above: its Co-Ordinator picks up the new tech-debt items, and
you can hand the improvement prompts to the `project-remediation` skill.

It reuses the hourly pipeline's machinery (ephemeral clones, the shared
usage-limit stand-down, the same lock/timeout discipline) but has its own
Script (`review-cycle.sh`), lock, PR label, and cron entry. It **defers to** a
running hourly cycle and shares the one usage-limit signal, so the two never
spend quota at the same moment. The `project-review` skill it runs is vendored
at `.claude/skills/project-review/` and staged into each ephemeral clone at run
time (never committed to the repo under review).

### Configuration (`review` block in `config.json`)

| Key | Default | Notes |
|---|---|---|
| `review.repos` | `["Poetic-Poems/poetic", "Poetic-Poems/poetic-fiddle"]` | Repositories to review. A plain list of slugs. |
| `review.model` | `claude-sonnet-5` | The lead model driving the review skill (which delegates to lower-cost subagents itself). |
| `review.pr_label` | `project-review` | Applied to every review PR. Distinct from `autonomous-agent`, so review PRs never count against `max_open_agent_prs`. |
| `review.branch_prefix` | `review/` | Branch name `review/<date>`. |
| `review.timeout_review` | `120` | Minutes. Per-repo wall-clock timeout. |
| `review.lock_stale_after` | `6` | Hours. Larger than the hourly pipeline's 3 h — a full review is long. |
| `review.min_days_between_reviews` | `6` | Skip a repo reviewed within this many days. This is what makes a daily cron tick behave as "about once a week" and stay robust to a sleeping machine. |

### Install

Create the review PR label in both repos (once):
```bash
gh api -X POST repos/Poetic-Poems/poetic/labels \
  -f name='project-review' -f color='5319e7' \
  -f description='PR raised by the weekly project-review pipeline'
# ...and the same for Poetic-Poems/poetic-fiddle
```

Add the cron entry. **Recommended** — a daily tick guarded by
`min_days_between_reviews`, robust to a machine that sleeps through a strict
weekly tick:
```bash
(crontab -l 2>/dev/null || true; echo "30 3 * * * $HOME/Code/Poetic-Poems/agent-ops/review-cycle.sh >> $HOME/.local/state/poetic-agents/review-cron.log 2>&1") | crontab -
```
This needs the same `AGENT_OPS_ROLE=active` line in the crontab as the hourly
cycle ("Which node runs the cycles"); one line covers both pipelines.
The skip-guard ensures this actually reviews each repo only about once a week.
For a strict weekly tick instead, use `30 3 * * 1` (Mondays 03:30) — simpler,
but a missed Monday tick skips the whole week.

### Operate

```bash
./review-cycle.sh --dry-run        # show which repos would be reviewed; launch nothing
./review-cycle.sh --once           # one run in the foreground, verbose
./review-cycle.sh --repo poetic    # restrict to one repo
tail -f ~/.local/state/poetic-agents/review-log.jsonl   # this pipeline's own event stream
```
Stage transcripts land in `~/.local/state/poetic-agents/reviews/<review-id>/`.
The shared `limit-hit` signal is written to the hourly pipeline's `log.jsonl`,
so a usage limit hit during a review also stands the hourly pipeline down.

See `docs/REVIEW-PIPELINE-SPEC.md` for the full specification.

## Monitoring dashboard

A local, single-page dashboard shows everything at a glance: whether a cycle
is running, whether the pipelines are disabled and why, usage-limit
stand-downs, open agent PRs and their CI status,
recent cycles with per-stage cost/duration/model, failures, blocked and void
items, the work sources the Co-Ordinator sees, spend by day and by model, and
the raw log — with each stage's transcript viewable inline.

It is **local and private**: nothing is published to the internet, there is no
server and no open port, and it costs nothing to run (it makes no model
calls). `scripts/publish-dashboard.sh` reads the pipeline's state plus live
GitHub data and regenerates a self-contained page under
`~/.local/state/poetic-agents/dashboard/`. Home paths and any token-shaped
strings are redacted, so a screenshot is safe to share.

### View it
```bash
./scripts/open-dashboard.sh
```
This regenerates the dashboard and opens it in your browser (via `wslview` /
`explorer.exe` on WSL). Or open `~/.local/state/poetic-agents/dashboard/index.html`
directly. The page auto-refreshes every `dashboard_refresh_seconds` (5s by
default) and shows how stale its data is; untick *auto-refresh* to pause it.

If your browser refuses to load the data over a `file://` URL, serve it
locally instead (loopback only):
```bash
./scripts/serve-dashboard.sh        # then open http://127.0.0.1:8787
```

### Keep it fresh
The dashboard refreshes at the end of every cycle (a hook in `agent-cycle.sh`).
To also keep it current between hourly cycles — reflecting in-flight runs, the
lock, and live GitHub status — add a heartbeat to your crontab:
```bash
(crontab -l 2>/dev/null || true; echo "*/5 * * * * $HOME/Code/Poetic-Poems/Poetic-Poems/agent-ops/scripts/publish-dashboard.sh >> $HOME/.local/state/poetic-agents/dashboard.log 2>&1") | crontab -
```

The dashboard is a **reader**: it only ever reads the pipeline's state and
GitHub, never writes into the state tree, never touches the lock, and cannot
disturb a running cycle. See `docs/DASHBOARD-SPEC.md` for its design.

### Run as a service (legacy WSL path, decommissioned)

On a containerised node the dashboard is already a service — the `dashboard`
service in `deploy/docker/compose.yaml`, restarted by Docker and reached over
the tailnet through the sidecar. Everything from here to the end of this section
is the laptop's old SysV path, retired at the cut-over and kept only as a record
of it — the laptop now serves its dashboard from the container like every other
node.

To have the loopback server start automatically when WSL starts — so
`http://127.0.0.1:8787` is always up without a foreground terminal — install
it as a SysV init script hooked into WSL's own `[boot] command`, exactly the
way `cron` and the ArtistOS Telegram bridge already are. This distro's WSL
instance does not run systemd as its init, so the service is started by WSL's
minimal built-in init, which runs the `[boot] command` from `/etc/wsl.conf`
once, as root, at startup. The server still binds `127.0.0.1` only — it opens
a loopback port, never a network one.

1. **Install the init script** — [`deploy/agent-ops-dashboard.init`](deploy/agent-ops-dashboard.init)
   drops to the `wallen` user (never root) via `start-stop-daemon --chuid`
   and serves `scripts/serve-dashboard.sh` on port 8787:

   ```sh
   sudo install -m 755 deploy/agent-ops-dashboard.init /etc/init.d/agent-ops-dashboard
   ```

   Its `RUNAS`, `RUNHOME`, `APPDIR`, `PORT`, `PIDFILE` and `LOGFILE` settings
   are defaults; a host that differs (another user, another checkout path)
   overrides them in `/etc/default/agent-ops-dashboard` rather than editing
   the installed script.

2. **Start it at WSL boot** — add it to `/etc/wsl.conf`'s existing boot
   command, alongside cron:

   ```ini
   [boot]
   command = service cron start; service artistos-telegram-bridge start; service docker start; service agent-ops-dashboard start
   ```

   This takes effect on the next WSL restart (`wsl --shutdown` from Windows,
   then reopen). To start it immediately without restarting:

   ```sh
   sudo service agent-ops-dashboard start
   ```

3. **Check it** — output goes to `dashboard-server.log` inside `state_dir`,
   with the rest of the pipeline's state:

   ```sh
   sudo service agent-ops-dashboard status
   tail -f ~/.local/state/poetic-agents/dashboard-server.log
   ```

   (An installation that predates this and still logs beside the checkout
   just has a stale `~/Code/Poetic-Poems/dashboard-server.log` left over;
   reinstall the init script and delete it.)

Common operations: `sudo service agent-ops-dashboard restart|stop`. Only run
one instance against port 8787 at a time — a second `python -m http.server`
on the same port dies with `Address already in use`, so stop any foreground
`serve-dashboard.sh` before starting the service (or vice versa).

### View it away from home (Tailscale)

The dashboard's privacy comes from never being published, and the only
supported remote-access path keeps it that way: a **tailnet** — your own
private WireGuard mesh, via [Tailscale](https://tailscale.com). The server
keeps binding `127.0.0.1` only; `tailscale serve` proxies HTTPS to it for
devices signed into *your* Tailscale account, and nothing ever gets a public
URL. (Never use `tailscale funnel`, which is the public-internet variant —
that would publish the pipeline's telemetry to anyone with the link.)

A containerised node has this already: the `tailnet` profile runs Tailscale as
a sidecar and the dashboard inside its network namespace, which is the same
arrangement — loopback server, Serve in front, no Funnel — assembled by
`docker compose up -d` instead of by hand. The steps below were the laptop's
manual equivalent before the cut-over, kept for reference; a node set up today
gets all of this from the `tailnet` profile.

Prerequisite: the loopback server must be running — install it as a boot
service first (see [Run as a service](#run-as-a-service-legacy-wsl-path-decommissioned)).

1. **Install Tailscale in WSL** and check the daemon binary landed:

   ```sh
   curl -fsSL https://tailscale.com/install.sh | sh
   command -v tailscaled
   ```

   (The package ships only a systemd unit, which this WSL distro's init
   ignores — hence the init script in the next step.)

2. **Install the init script** — [`deploy/tailscaled.init`](deploy/tailscaled.init)
   runs `tailscaled` at boot. Root this time, deliberately: it needs
   `/dev/net/tun` and `/var/lib/tailscale`; the dashboard server itself
   stays unprivileged and loopback-only.

   ```sh
   sudo install -m 755 deploy/tailscaled.init /etc/init.d/tailscaled
   sudo service tailscaled start
   ```

   Then add `service tailscaled start` to `/etc/wsl.conf`'s `[boot]`
   command, alongside cron and the dashboard service:

   ```ini
   [boot]
   command = service cron start; service artistos-telegram-bridge start; service docker start; service agent-ops-dashboard start; service tailscaled start
   ```

3. **Join your tailnet** (one-time): run `sudo tailscale up`, open the
   printed URL in a browser, and sign in (creating the account on first
   use). In the [admin console](https://login.tailscale.com/admin/dns),
   enable **MagicDNS** and **HTTPS certificates** — `tailscale serve` needs
   both to mint the dashboard's certificate.

4. **Proxy the dashboard onto the tailnet** (one-time; the setting persists
   in tailscaled's state across restarts):

   ```sh
   sudo tailscale serve --bg 8787
   tailscale serve status    # shows the https://… URL it is served at
   ```

5. **On your phone or laptop**: install the Tailscale app, sign into the
   same account, and open the URL from `tailscale serve status`
   (`https://<machine>.<tailnet>.ts.net`). The page auto-refreshes there
   exactly as it does locally.

The machine (and WSL) must be awake for this — but that is already true of
the pipeline itself, so anything the dashboard would show you is only ever
produced while it is reachable. To stop sharing: `sudo tailscale serve
reset`; to leave the tailnet entirely: `sudo tailscale logout`.

## Troubleshooting

**Cron not running:**
```bash
sudo service cron status
sudo service cron start
```

**No cycles firing:**
Check the switch first — it's the one cause that leaves no trace of a problem,
because a disabled pipeline and a quiet week look identical:
```bash
./agent-cycle.sh --status
```
If it's disabled, `--enable` resumes it. Otherwise, check the cron log:
```bash
tail -50 ~/.local/state/poetic-agents/cron.log
```
A line reading `skipped — this node is standby` means this machine is not the
active one (see [Which node runs the cycles](#which-node-runs-the-cycles)):
either that is correct and another machine is doing the work, or the crontab is
missing its `AGENT_OPS_ROLE=active` line. A line naming an unrecognised role
(`AGENT_OPS_ROLE=activ is not a role`) is a typo standing the node down.

**Cycles firing but never reaching the Co-Ordinator:**
Expected on a quiet repo — see [Skipping no-op cycles](#skipping-no-op-cycles);
a `stand-down` whose reason begins `no-op short-circuit` is the system working.
It becomes a *fault* only if there is genuinely work waiting, which would mean
some source isn't covered by the fingerprint. The recheck valve
(`none_selected_recheck_hours`) breaks the loop within a day either way, and
`--once` forces the Co-Ordinator immediately:
```bash
./agent-cycle.sh --once    # bypasses the short-circuit
```
If `--once` then picks up work that hourly cycles were skipping, the
fingerprint is missing a signal — a bug worth filing, in
`scripts/gather-source-state.sh`.

**Stale lock warning:**
If a cycle was killed or hung and left a lock older than 3 hours, the next cycle will kill it and log a `warning` event. Inspect the old cycle's transcript to see what went wrong.

**PR won't merge (mergeable=false):**
The Reviewer should have caught this, or it arose after the PR was ready (another PR merged to `main` first). Use `gh pr view --json mergeStateStatus` to see why. The branch and PR remain open for manual intervention.

**Usage limit hit:**
The system logs a `limit-hit` event with the reset time if parseable. It then stands down until that time or `limit_cooldown_default`, whichever is later. Check the log for the event.

## Uninstall

1. **Remove the crontab lines** (the cycle, the weekly review, and, if added, the dashboard heartbeat):
   ```bash
   crontab -l | grep -v 'Poetic-Poems/agent-ops/agent-cycle.sh' | grep -v 'Poetic-Poems/agent-ops/review-cycle.sh' | grep -v 'Poetic-Poems/agent-ops/scripts/publish-dashboard.sh' | crontab -
   ```
   (Or edit the Windows Task Scheduler job / `wsl.conf` change if you used
   that alternative instead.) If you installed the dashboard boot service,
   also remove `service agent-ops-dashboard start` from `/etc/wsl.conf`'s
   `[boot] command`, then `sudo service agent-ops-dashboard stop` and
   `sudo rm /etc/init.d/agent-ops-dashboard`. If you set up tailnet access,
   likewise `sudo tailscale serve reset`, remove `service tailscaled start`
   from the `[boot] command`, `sudo service tailscaled stop`, and
   `sudo rm /etc/init.d/tailscaled` (then `sudo tailscale logout` and
   uninstall the package if nothing else uses Tailscale).
2. **Let any in-flight cycle finish**, or kill it: find the PID in
   `~/.local/state/poetic-agents/lock.json` and `kill` it — the next
   `crontab`-less state is safe either way since nothing else will start.
3. **Remove state and workspaces:**
   ```bash
   rm -rf ~/.local/state/poetic-agents ~/.cache/poetic-agents
   ```
   This deletes the log, lock, and stage transcripts. Any open PRs the
   system already raised are untouched — they're ordinary GitHub PRs on the
   target repos and are yours to merge, close, or hand-finish.
4. **Optional:** remove the `autonomous-agent` label from both repos
   (`gh api -X DELETE repos/Poetic-Poems/poetic/labels/autonomous-agent`, likewise for
   `poetic-fiddle`) and uninstall the standalone `claude` CLI if nothing
   else on the machine uses it.

## For maintainers: the as-built specifications

To modify this system (add a new work source, change the selection logic, etc.), start from `docs/IMPLEMENTATION-PIPELINE-SPEC.md` — the as-built requirements specification for the pipeline, with numbered requirements and acceptance checks. The specs are maintained as-built: a change to a component lands in the same pull request as the spec edit that keeps its document accurate (see `CLAUDE.md`, "As-built specifications"). `prompts/coordinator.md`, `prompts/implementor.md`, and `prompts/reviewer.md` are the operating prompts actually fed to each stage's headless `claude -p` invocation — update the spec first, then bring the affected operating prompt(s) in line with it.

`docs/DASHBOARD-SPEC.md` is the companion specification for the monitoring dashboard (`scripts/publish-dashboard.sh` and `dashboard/index.html`).

`docs/REVIEW-PIPELINE-SPEC.md` is the companion specification for the weekly project-review pipeline (`review-cycle.sh` and `prompts/project-reviewer.md`).

## Branch workflow

This repo follows the same conventions as its target repos:
- `main` is protected; no direct commits. All changes go through pull requests.
- PR titles must be in [Conventional Commits](https://www.conventionalcommits.org/) format (`<type>[(scope)]: <description>`).
- Both repo's CLAUDE.md files bind all work done inside them.

## Development

The image is the deployment, but it is never the workshop. Changes are made
in an ordinary git checkout, land on `main` through a pull request, and reach
the fleet as a freshly built image. Nothing is ever edited inside a running
container — there is no useful way to: `/app` is baked in at build time, and
the next image roll would discard the edit anyway.

### Making a change when every instance is a container

Work in a dedicated fresh clone on a feature branch and open a pull request —
the workflow in [Branch workflow](#branch-workflow) and `CLAUDE.md`. With the
legacy host install cut over, a checkout is purely a development artefact: no
cron entry and no pipeline runs out of it, so editing one cannot destabilise
a running cycle. The rule in [Pausing the
pipelines](#pausing-the-pipelines) — disable before editing — protected the
host install, where cron ran the very files being edited; on a fleet of
containers, editing is always safe and the switch is about *rollout*, not
editing.

Because rollout is where the care has moved to: every merge to `main` builds
and publishes a new image, and every node on the `auto-update` profile
restarts into it within watchtower's poll interval (about five minutes) —
killing any cycle that happens to be mid-flight (`TD26072301` in
`TECH-DEBT.md`; the stale-lock takeover and the claim GC tidy up behind it,
but an Implementor's half-finished work dies with the roll). For routine
changes that risk is accepted. For a change that touches cycle state, claims,
or the state-sync format, stand the fleet down first, merge, watch the roll,
then resume — the switch works from any node:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling out PR #NN"
# merge; watchtower rolls every auto-update node onto the new image
docker compose exec scheduler /app/agent-cycle.sh --enable
```

### Running the tests

The unit tests are plain bash, no framework; each is self-contained and
exits non-zero on the first failed assertion. They run straight out of the
checkout — no node, no Docker, no installation:

```bash
for t in test/*.test.sh; do "$t" || break; done
```

CI runs the same suite *inside* the freshly built image on every push —
along with toolchain, crontab and role-guard checks (see
`.github/workflows/build-image.yml`) — so an image that reaches `ghcr.io`
has already passed everything above.

### Trying a change on a real node before it merges

Build the image from the checkout and point a stack at it —
`AGENT_OPS_IMAGE` in `.env` exists for exactly this:

```bash
docker build -f deploy/docker/Dockerfile -t agent-ops .
# in the stack's .env:  AGENT_OPS_IMAGE=agent-ops
docker compose up -d
docker compose exec scheduler /app/agent-cycle.sh --dry-run
docker compose exec scheduler /app/agent-cycle.sh --once --repo poetic-fiddle
```

Do this on a scratch stack or a standby node, never the fleet's workhorse. A
second stack on the same host needs its own `COMPOSE_PROJECT_NAME`, node
name and token (see
[A second node on one host](deploy/docker/README.md#a-second-node-on-one-host));
`--dry-run` and `--once` run regardless of role, so the guinea-pig node can
stay `standby` throughout. To mock a usage-limit event for testing the
cooldown, from a shell on that node (`docker compose exec scheduler bash`):

```bash
jq -n '{ts: now | todate, cycle: "test", event: "limit-hit", resume_at: (now + 7200 | todate), detail: "test injection"}' >> ~/.local/state/poetic-agents/log.jsonl
```

### Taking one node out while the rest keep working

Yes — role and lifecycle are per-node; only the switch is not. `--disable`
stops the *fleet* (it publishes `fleet/disabled.json`, which every node
obeys), so it is the wrong tool for taking a single node aside. Per node:

- **Stop it spending**: set `ROLE=standby` in its `.env`, then
  `docker compose up -d`. It keeps its heartbeat and keeps following the
  fleet's memory, so promoting it back is the same one variable.
- **Stop it entirely**: `docker compose stop scheduler`, or
  `docker compose down` (which keeps the volumes). The rest of the fleet
  carries on; per-item claims mean no other node was depending on this one.
- **Hold it on a known image** while the rest follow `latest`: pin
  `AGENT_OPS_IMAGE=ghcr.io/poetic-poems/agent-ops:<sha>` in its `.env`.

One caution before any *manual* `docker compose up -d` on a live node: after
a watchtower roll, compose's recorded config-hash no longer matches, so
`up -d` recreates the scheduler even when nothing in the compose file
changed — killing a running cycle exactly as a roll does. Run `--status`
first and let a cycle in flight finish.

### How a change propagates — and what survives it

Containers are disposable and, in effect, immutable: an update *is* the
destruction of the old container and the creation of a new one from the new
image, whether watchtower performs it or a manual
`docker compose pull && docker compose up -d` does. That is not a cost to
work around but the design — nothing worth keeping lives in a container.
What carries across every roll:

- **The node's `.env`** — a file on the host, outside Docker entirely. The
  GitHub PAT (`GH_TOKEN`) is injected from it into each new container at
  start, so the recreated container uses the same token as the destroyed
  one; nothing is re-issued, and the token needs replacing only on its own
  expiry (or if leaked).
- **The `claude-config` volume** — Claude's OAuth credentials, which refresh
  themselves in place. The manual `docker compose exec scheduler claude`
  login is once per *node*, not per container: no re-authentication after an
  image update, a `stop`/`start`, or a role change. The only thing that
  costs a fresh login is destroying the volume itself
  (`docker compose down -v`).
- **The `state` and `workspaces` volumes** — the pipelines' memory and any
  in-progress clone.
