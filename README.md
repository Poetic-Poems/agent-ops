# Poetic Autonomous Implementation Agent System

A self-hosted, unattended pipeline that automatically selects, implements, and reviews pending work from the [poetic](https://github.com/Poetic-Poems/poetic) and [poetic-fiddle](https://github.com/Poetic-Poems/poetic-fiddle) repositories, raising mergeable pull requests for human review and approval.

## What it does

Once an hour:

1. **Co-Ordinator** (Haiku) selects at most one well-scoped item of work (security findings, review feedback, failed CI runs, tech-debt, issues, fiddle's implementation plan, project-review recommendations, or code-quality findings). Security work — open Dependabot alerts and security code-scanning alerts — is always prioritised ahead of everything else, and answering your review feedback comes second.
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
| `repos` | see `config.json` | Array of `{"slug": "...", "sources": [...]}`. `sources` is that repo's work sources in priority order (`security`, `review-feedback`, `failed-runs`, `tech-debt`, `issues`, `implementation-plan`, `project-review`, `code-quality`). `security` (open Dependabot + security code-scanning alerts) is always first, and any security-related item is prioritised ahead of all non-security work; `review-feedback` (agent PRs where you asked for changes we haven't answered yet) comes second and likewise outranks the repo walk — finishing beats starting, and a stuck PR otherwise occupies a back-pressure slot forever; `project-review` (the latest weekly review's recommendations that aren't already tech-debt or issues) sits just above `code-quality` (non-security code-scanning findings), which is last. Adding a repo or source is a config-only change. At runtime, repos are ordered by least-recently-updated default branch first, ahead of this list order. |
| `state_dir` | `~/.local/state/poetic-agents` | Lock, shared log, stage transcripts. |
| `workspace_root` | `~/.cache/poetic-agents/workspaces` | Ephemeral clones. Each cycle gets its own subdirectory. |
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

There are two ways to run a node. The **container image** (`deploy/docker/`)
carries the whole toolchain and needs nothing installed on the host but Docker;
it is how a cloud VM runs, and how the laptop will run once the migration is
complete. The **host install** below is the laptop's current path: the scripts
run straight out of a checkout, driven by the user crontab.

### As a container

```bash
docker build -f deploy/docker/Dockerfile -t agent-ops .

# the scheduler: the same three cron entries the laptop crontab has
docker run -d --name agent-ops-scheduler \
  -e AGENT_OPS_ROLE=standby -e NODE_NAME=my-node -e GH_TOKEN=… \
  -v agent-ops-state:/home/agent/.local/state/poetic-agents \
  -v agent-ops-claude:/home/agent/.claude \
  agent-ops supercronic /app/deploy/docker/crontab
```

Three things are worth knowing before the compose stack lands:

- **`/app` is the deployment.** The image is built from this repository, so a
  node updates by pulling a new image — never by pulling a branch inside a
  running container.
- **`~/.claude` and `state_dir` must be volumes.** Claude's OAuth credentials
  refresh and write back, and `state_dir` is the pipelines' memory. The
  entrypoint seeds `settings.json` only when it is absent, and refuses to start
  if `state_dir` is not writable by the container user (uid 1000 by default;
  rebuild with `--build-arg PUID=…` to match a host directory).
- **Authenticate once per node**: `docker exec -it agent-ops-scheduler claude`
  and complete the login. Until then every cycle fails at its first stage; the
  entrypoint warns about it on each start.

Set `AGENT_OPS_ROLE=active` on exactly one node (see
[Which node runs the cycles](#which-node-runs-the-cycles)).

### On the host

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

Both cron pipelines run the code in *this* working tree. Editing
`agent-cycle.sh`, `lib/`, or `prompts/` while a cycle is about to start means
the next tick sources half of one revision and half of another — so before
working on this repo, turn the pipelines off:

```bash
./agent-cycle.sh --disable "editing lib/cycle-state.sh"   # expires after disable_default_ttl (4 h)
./agent-cycle.sh --disable "big refactor" --for 8h        # or 90m, 2d, or `forever`
./agent-cycle.sh --status                                 # what's set, and is anything running?
./agent-cycle.sh --enable                                 # resume
```

The switch is one file (`$state_dir/disabled.json`) shared by **both**
`agent-cycle.sh` and `review-cycle.sh` — they run out of the same tree, so
stopping one and not the other stops nothing much. `agent-cycle.sh` is the only
way to set it; `review-cycle.sh` only obeys it.

Three things worth knowing:

- **Disabling stops the *next* cycle, not one already running.** `--status`
  tells you whether a cycle is in flight, and `--disable` warns you if there
  is. Wait for it to finish before editing files it is reading.
- **A disable expires by default.** The point is not tidiness: an agent that
  disables the pipeline and then dies would otherwise stop every future cycle
  silently — "no PRs" looks exactly like a quiet week. The TTL turns a
  forgotten switch into a few lost cycles. Use `--for forever` when you mean
  it, and `--enable` when you're done.
- **A reason is required**, because the next person wondering why nothing has
  happened is entitled to one. It shows up in `--status`, in the log, and on
  the dashboard banner.

## Which node runs the cycles

The pipelines are meant to be installable on more than one machine — a laptop,
a cloud VM, several — but exactly **one** of them may actually run unattended
cycles. Two machines cycling on the same repositories would open competing pull
requests for the same item and pay twice to do it. The environment variable
`AGENT_OPS_ROLE` names the one that does:

```bash
AGENT_OPS_ROLE=active     # this machine runs the hourly cycle and the daily review tick
AGENT_OPS_ROLE=standby    # ...anything else does not
```

Set it in the crontab (a bare `AGENT_OPS_ROLE=active` line above the schedule
lines) or in the environment of whatever runs the scripts. Only the exact value
`active` counts — case and surrounding whitespace are ignored, but **unset,
empty or misspelt all mean standby**. That is deliberate: a machine wrongly
standby costs one skipped cycle, while a second machine wrongly active costs
money and leaves duplicate pull requests for someone to clean up.

A standby tick writes one line to the cron log and exits; it creates no cycle,
logs no event, and spends nothing. Failing over is a matter of setting `active`
on the new machine and clearing it on the old.

What the role does *not* stop:

- `--dry-run` and `--once` — a human asking for a cycle is not an unattended
  one, and both run on any machine.
- `--disable`, `--enable` and `--status` — the switch is shared state and must
  be readable and settable from wherever you happen to be.
- The dashboard, which is worth serving on every node.

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

### Run as a service

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

Prerequisite: the loopback server must be running — install it as a boot
service first (see [Run as a service](#run-as-a-service)).

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

To run the unit tests (plain bash, no framework; each is self-contained and
exits non-zero on the first failed assertion):
```bash
for t in test/*.test.sh; do "$t" || break; done
```

Before editing anything in this repo, stop the pipelines — they run the files
you are editing (see [Pausing the pipelines](#pausing-the-pipelines)):
```bash
./agent-cycle.sh --disable "working on agent-ops" && ./agent-cycle.sh --status
# ... work ...
./agent-cycle.sh --enable
```

To test a full cycle without cron:
```bash
./agent-cycle.sh --once --repo poetic-fiddle 2>&1 | tee test-cycle.log
```

To mock a usage-limit event for testing the cooldown:
```bash
jq -n '{ts: now | todate, cycle: "test", event: "limit-hit", resume_at: (now + 7200 | todate), detail: "test injection"}' >> ~/.local/state/poetic-agents/log.jsonl
```
