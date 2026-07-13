# Poetic Autonomous Implementation Agent System

A self-hosted, unattended pipeline that automatically selects, implements, and reviews pending work from the [poetic](https://github.com/Poetic-Poems/poetic) and [poetic-fiddle](https://github.com/Poetic-Poems/poetic-fiddle) repositories, raising mergeable pull requests for human review and approval.

## What it does

Once an hour:

1. **Co-Ordinator** (Haiku) selects at most one well-scoped item of work (failed CI runs, tech-debt, issues, or fiddle's implementation plan).
2. **Implementor** (Sonnet/Haiku) clones the repo, implements the item on a feature branch, and opens a draft pull request.
3. **Reviewer** (Sonnet) checks and corrects the implementation, then marks the PR ready for review.
4. **Human** reviews and merges via the normal GitHub process (the only gate).

If no suitable item exists, or if back-pressure shows open agent PRs, the cycle stands down.

## Configuration

Edit `config.json` before first run. Keys:

| Key | Default | Notes |
|---|---|---|
| `repos` | see `config.json` | Array of `{"slug": "...", "sources": [...]}`. `sources` is that repo's work sources in priority order (`failed-runs`, `tech-debt`, `issues`, `implementation-plan`). Adding a repo or source is a config-only change. At runtime, repos are ordered by least-recently-updated default branch first, ahead of this list order. |
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

## Installation

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
   Test: `claude -p "Reply with OK" --model claude-haiku-4-5-20251001`

3. **Enable cron (WSL):**
   Edit `/etc/wsl.conf` (requires `sudo`):
   ```ini
   [boot]
   command = "service cron start"
   ```
   Then restart WSL: `wsl --shutdown` (from Windows).

   *Alternative (Windows Task Scheduler):* Create a task running `wsl.exe -u wallen -e $HOME/Code/agent-ops/agent-cycle.sh` hourly.

4. **Create the PR label in both repos:**
   ```bash
   gh label create autonomous-agent \
     -R Poetic-Poems/poetic \
     --description "PR raised by the autonomous agent system"
   
   gh label create autonomous-agent \
     -R Poetic-Poems/poetic-fiddle \
     --description "PR raised by the autonomous agent system"
   ```

5. **Review and edit `config.json`** as needed.

6. **Install the crontab:**
   ```bash
   (crontab -l 2>/dev/null || true; echo "0 * * * * $HOME/Code/agent-ops/agent-cycle.sh >> $HOME/.local/state/poetic-agents/cron.log 2>&1") | crontab -
   ```

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

### See the log
```bash
tail -f ~/.local/state/poetic-agents/log.jsonl
```
One event per line (JSON). See `docs/BUILD-PROMPT.md` (requirement 31) for event types and fields.

### See stage transcripts
```bash
ls -la ~/.local/state/poetic-agents/cycles/
```
Each cycle gets a directory (`<cycle-id>/`) with one `<stage>.out` (the
`claude --output-format json` envelope on stdout — this is what gets parsed)
and one `<stage>.out.stderr` (diagnostics) per stage that ran.

## Troubleshooting

**Cron not running:**
```bash
sudo service cron status
sudo service cron start
```

**No cycles firing:**
Check the cron log:
```bash
tail -50 ~/.local/state/poetic-agents/cron.log
```

**Stale lock warning:**
If a cycle was killed or hung and left a lock older than 3 hours, the next cycle will kill it and log a `warning` event. Inspect the old cycle's transcript to see what went wrong.

**PR won't merge (mergeable=false):**
The Reviewer should have caught this, or it arose after the PR was ready (another PR merged to `main` first). Use `gh pr view --json mergeStateStatus` to see why. The branch and PR remain open for manual intervention.

**Usage limit hit:**
The system logs a `limit-hit` event with the reset time if parseable. It then stands down until that time or `limit_cooldown_default`, whichever is later. Check the log for the event.

## Uninstall

1. **Remove the crontab line:**
   ```bash
   crontab -l | grep -v 'agent-ops/agent-cycle.sh' | crontab -
   ```
   (Or edit the Windows Task Scheduler job / `wsl.conf` change if you used
   that alternative instead.)
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
   (`gh label delete autonomous-agent -R Poetic-Poems/poetic`, likewise for
   `poetic-fiddle`) and uninstall the standalone `claude` CLI if nothing
   else on the machine uses it.

## For builders: the build prompt

To modify this system (add a new work source, change the selection logic, etc.), see `docs/BUILD-PROMPT.md`. It is a complete specification for the system and includes numbered requirements and acceptance checks. `prompts/coordinator.md`, `prompts/implementor.md`, and `prompts/reviewer.md` are the operating prompts actually fed to each stage's headless `claude -p` invocation — update the build prompt first, then bring the affected operating prompt(s) in line with it.

## Branch workflow

This repo follows the same conventions as its target repos:
- `main` is protected; no direct commits. All changes go through pull requests.
- PR titles must be in [Conventional Commits](https://www.conventionalcommits.org/) format (`<type>[(scope)]: <description>`).
- Both repo's CLAUDE.md files bind all work done inside them.

## Development

To test a full cycle without cron:
```bash
./agent-cycle.sh --once --repo poetic-fiddle 2>&1 | tee test-cycle.log
```

To mock a usage-limit event for testing the cooldown:
```bash
jq -n '{ts: now | todate, cycle: "test", event: "limit-hit", resume_at: (now + 7200 | todate), detail: "test injection"}' >> ~/.local/state/poetic-agents/log.jsonl
```
