# Scheduled Autonomous Implementation Agent System — build prompt

## How to use this document

Give this document, whole, to a Claude Code session (Sonnet 5 or better)
started in an empty repository that will become `Poetic-Poems/agent-ops`,
with the instruction "build the system this document describes". Everything
the builder needs is here. Where this document is silent, follow the
conventions of the two target repositories (their `CLAUDE.md` files are
binding on any agent working inside them).

## What to build

A pipeline that, once an hour, picks **at most one** well-scoped item of
pending work from one of two GitHub repositories, implements it on a feature
branch in an ephemeral clone, reviews and corrects the result, and leaves a
mergeable pull request for a human to approve. It runs unattended on this
machine (WSL2 Ubuntu). The only human involvement is final pull-request
review and merge.

```
cron (hourly)
  └─ agent-cycle.sh                 ← the Script: lock, stand-down checks, repo ordering
       ├─ Co-Ordinator (Haiku)      ← selects ≤ 1 item, emits a work order; nothing else
       ├─ Implementor (Sonnet/Haiku)← ephemeral clone, feature branch, draft PR
       └─ Reviewer (Sonnet)         ← corrects the branch, flips the PR to ready
             └─ Human               ← reviews and merges (the only gate)
```

## Entities

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

## Environment facts (verified 2026-07-13)

- WSL2 Ubuntu; `bash`; `git`; `jq` assumed available (verify, install if not).
- `gh` is installed and authenticated as `warwickallen`, with push access to
  both target repositories.
- The standalone `claude` CLI is **not installed** (Claude Code currently
  runs only via the VS Code extension) — see "Prerequisites (human steps)".
- `cron` is **not running** and there is no crontab — see "Prerequisites".
- Headless `claude -p` invocations authenticate with the user's existing
  Claude subscription login; `gh` uses its existing token. No new keys.

### Target repositories

| Repo | GitHub | Work sources, in priority order |
|---|---|---|
| poetic (framework) | `Poetic-Poems/poetic` | 1. failed Actions runs on `main` · 2. `TECH-DEBT.md` · 3. open GitHub issues |
| poetic-fiddle (web app) | `Poetic-Poems/poetic-fiddle` | 1. failed Actions runs on `main` · 2. `TECH-DEBT.md` · 3. open GitHub issues · 4. `docs/IMPLEMENTATION-PLAN.md` (next milestone task) |

Conventions shared by both repos (agents must honour all of these):

- `main` is protected: no direct pushes by anyone or anything; every change
  lands via a pull request, squash-merged, so **the PR title becomes the
  commit on `main` and must be in Conventional Commits format**.
- `TECH-DEBT.md` holds deferred work, with a permanent Ledger table and a
  "Claiming an item" workflow: flip the Ledger row to `in-progress` and open
  a **draft** pull request immediately, so the claim is visible; flip to
  `resolved` and mark the PR ready when done. `scripts/get-tech-debt-record.pl`
  resolves an ID to its record; `scripts/next-tech-debt-id.pl` allocates IDs.
- CI runs on every PR (build/lint/test workflows plus CodeQL and
  commit-format checks). A PR is not finished until its checks pass and
  `gh pr view --json mergeable,mergeStateStatus` reports it mergeable.
- `CHANGELOG.md` gets an entry for notable changes; other docs are as-built
  (no historical phrasing).

## Configuration

One `config.json` at the root of `agent-ops`, holding every tunable. The
values below are the confirmed defaults; the README must document each key.

| Key | Value | Notes |
|---|---|---|
| `repos` | `["Poetic-Poems/poetic", "Poetic-Poems/poetic-fiddle"]` | Work-source lists per repo as in the table above; structure the config so a repo or source can be added without code changes. |
| `state_dir` | `~/.local/state/poetic-agents` | Lock, shared log, per-cycle stage transcripts. |
| `workspace_root` | `~/.cache/poetic-agents/workspaces` | Ephemeral clones live and die here. |
| `coordinator_model` | `claude-haiku-4-5-20251001` | Selection is cheap triage. |
| `implementor_model_default` | `claude-sonnet-5` | Any change that affects runtime behaviour. |
| `implementor_model_trivial` | `claude-haiku-4-5-20251001` | Docs-, comment-, or register-only items. The Co-Ordinator classifies each item and records its reasoning in the work order. |
| `reviewer_model` | `claude-sonnet-5` | |
| `pr_label` | `autonomous-agent` | Applied to every PR this system raises. |
| `branch_prefix` | `agent/` | Branch name `agent/<item-slug>`, e.g. `agent/td26051201-fix-xyz`. |
| `max_open_agent_prs` | `3` | Back-pressure: total open PRs (draft or ready) carrying `pr_label`, across all repos. |
| `timeout_coordinator` | 15 min | Per-stage wall-clock timeouts, enforced by the Script. |
| `timeout_implementor` | 90 min | |
| `timeout_reviewer` | 30 min | |
| `lock_stale_after` | 3 h | Greater than the sum of the stage timeouts plus slack. |
| `limit_cooldown_default` | 3 h | Stand-down period after a usage-limit error whose reset time cannot be parsed. |

Model IDs are pinned in config (one place to update); do not use floating
aliases in the launch commands.

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

1. **Lock.** On start, acquire a lock file in `state_dir` recording PID and
   start time. If the lock is held by a live process younger than
   `lock_stale_after`, log `cycle-skipped` and exit 0. If the holder is dead
   or older than `lock_stale_after`, kill its whole process group if still
   alive, log a `warning` (a stale cycle indicates a fault — it should not
   occur in normal operation), take the lock, and continue.
2. **Stand-down checks.** Each check logs its reason and exits cleanly:
   1. *Usage-limit cooldown*: if the shared log's most recent `limit-hit`
      event has a `resume_at` still in the future, stand down.
   2. *Back-pressure*: if the number of open PRs labelled `pr_label` across
      all configured repos (drafts included) is ≥ `max_open_agent_prs`,
      stand down. This is the primary throttle on both spend and on the
      human gate silting up.
3. **Repo ordering.** For each configured repo, fetch the timestamp of the
   most recent commit on its default branch via `gh api`; sort least recent
   first. The most-overdue repo gets first look, and this ordering takes
   precedence over the per-repo source priorities.
4. **Co-Ordinator stage.** Launch the Co-Ordinator (headless, model
   `coordinator_model`, `--dangerously-skip-permissions`, stage timeout),
   passing it the ordered repo list, the per-repo work sources, and the
   blocked-item extract from the shared log. Capture its final message with
   Claude Code's JSON output format and parse the work order from it.
5. If the work order is `{"selected": false}`, log `none-selected` with the
   Co-Ordinator's reason, release the lock, and exit.
6. **Workspace.** Create `workspace_root/<cycle-id>/` and clone the selected
   repo into it, fresh from GitHub. Agents only ever run inside this
   workspace; the Script must refuse (assert) to launch a stage whose
   working directory is outside `workspace_root`. The user's own clones
   under `~/Code` are never touched.
7. **Implementor stage.** Launch the Implementor in the clone (model from
   the work order, `--dangerously-skip-permissions`, stage timeout), passing
   the implementor prompt plus the work order.
8. **Reviewer stage.** If the Implementor reports `complete`, launch the
   Reviewer in the same workspace (model `reviewer_model`, same flags,
   stage timeout), passing the reviewer prompt, the work order, and the
   Implementor's summary (PR URL, branch).
9. **Failure handling.** If any stage times out, exits non-zero, or returns
   an unparseable summary: kill that stage's process group, log
   `attempt-failed` with enough detail for a future cycle to know the item
   is blocked and what would unblock it, and — if a draft PR was already
   opened — comment on it that the agent has abandoned it and why, leaving
   the PR and branch for the human to keep or discard.
10. **Usage-limit detection.** Whenever any `claude` invocation fails with
    output matching a usage-limit pattern (e.g. `limit`, `rate limit`,
    `usage`), write a `limit-hit` event whose `resume_at` is parsed from the
    error message where possible, else now + `limit_cooldown_default`.
    There is no supported API for querying a subscription plan's remaining
    quota, so this fail-safe detection *is* the quota check, and
    back-pressure (2.2) is the primary spend control.
11. **Cleanup.** Always: delete the cycle's workspace, write a `cycle-end`
    event, release the lock. Tee each stage's stdout/stderr to
    `state_dir/cycles/<cycle-id>/` for debugging.
12. **Flags.** `--dry-run` (run through step 5 then stop: prints the work
    order, launches no Implementor), `--once` (one verbose cycle in the
    foreground), `--repo <slug>` (restrict selection, for testing).
13. The Script must pass `shellcheck` and must set its own `PATH` explicitly
    (cron's environment is minimal), covering `claude`, `gh`, `git`, `jq`.

### The Co-Ordinator (selection only)

14. Works read-only: `gh` reads (runs, issues, PRs, file contents via
    `gh api`) — it does not clone, and writes nothing but its final message.
15. Walks the repos in the order given. Within a repo, checks work sources
    in the configured priority order. For "failed Actions runs", a candidate
    exists only where the **most recent** run of a workflow on the default
    branch is a failure (a later green run supersedes older failures).
16. Excludes from candidacy any item that is:
    - recorded as blocked in the shared log (an `attempt-failed` event not
      followed by an `unblocked` event for that item);
    - a tech-debt item whose Ledger row is `in-progress`;
    - already referenced by any open PR or draft (a claim, per the repos'
      claiming workflow);
    - an issue that is assigned, labelled `blocked`, or is a question or
      discussion rather than actionable work;
    - dependent on a product or architecture decision that has not been
      made. (Example: poetic-fiddle's milestone M2 is gated on the §6.1
      packaging decision in its implementation plan — while that decision
      is open, M2 tasks do not meet the bar. Decisions belong to the human;
      never attempt to make one.)
17. From the remaining candidates, selects the first that is a stand-alone
    unit of work, clearly scoped, and adequately refined. Do not guess: if
    in doubt about an item, skip it. If nothing in the current category
    qualifies, fall through to the next category, then the next repo. Only
    after exhausting all repos does it return `{"selected": false}` with a
    one-line reason.
18. When it skips a blocked item, it may cheaply verify whether the recorded
    blocker still holds; if the blocker is demonstrably gone, it reports
    that in its final message so the Script can append an `unblocked` event,
    and may then treat the item as a candidate this same cycle.
19. Chooses the Implementor's model: `implementor_model_trivial` only when
    the item can be completed without changing any file that affects runtime
    behaviour (docs, comments, register entries); otherwise
    `implementor_model_default`. Records the reasoning.
20. Emits a work order as its entire final message:

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
      "context": "everything the Implementor needs: the register entry or issue text verbatim, file paths, related conventions found while evaluating, why the item is unblocked and in scope",
      "acceptance": "what done looks like, concretely"
    }
    ```

### The Implementor

21. Runs inside the cycle's clone. First reads the repo's `CLAUDE.md` and
    obeys it throughout. Creates the branch named in the work order from the
    default branch.
22. **Claims before implementing.** Opens a draft PR immediately, labelled
    `pr_label`, with a Conventional-Commits title (it will become the squash
    commit on `main`) and a body giving the item reference and planned
    approach. For tech-debt items this follows the repo's claiming workflow
    exactly (Ledger flip to `in-progress` as the first commit). For issues,
    it comments on the issue linking the draft PR.
23. Implements the item, then runs the same checks the repo's CI runs (as
    documented in that repo's `CLAUDE.md` and workflow files) and fixes
    anything they surface.
24. Updates the originating record: tech-debt entry removed and Ledger row
    flipped to `resolved` per the register's rules; issues linked with a
    closing keyword in the PR body; implementation-plan task marked done.
    Adds a `CHANGELOG.md` entry when the change is notable by that repo's
    definition.
25. Verifies the PR via `gh pr view --json mergeable,mergeStateStatus`
    (against GitHub's view, not inferred locally) and resolves any conflict
    with the current default branch. Leaves the PR as a **draft** — the
    Reviewer flips it to ready.
26. Ends with a single JSON object as its entire final message:
    `{"status": "complete", "pr_url": …, "branch": …, "notes": …}` or
    `{"status": "blocked", "reason": …, "unblock_condition": …}`.

### The Reviewer

27. Reviews the PR against the work order's item and acceptance notes, and
    against the target repo's own standards and conventions; re-runs the
    repo's checks.
28. Where it finds a problem it can fix with confidence, it fixes it
    directly on the branch — committing, rebasing onto the current default
    branch, or force-pushing as it judges best (permitted only on
    `branch_prefix` branches, per "The Human Gate"). Where it cannot fix
    with confidence, it leaves a PR review comment describing the problem
    for the Human Reviewer.
29. Confirms CI is passing (`gh pr checks`) and the PR is mergeable, then
    marks it ready for review (`gh pr ready`). It never approves and never
    merges.
30. Ends with a single JSON object:
    `{"status": "ready" | "needs-human", "pr_url": …, "fixes_applied": […], "comments_left": n, "ci": "passing" | …}`.

### Logging and state

31. The shared log is a single JSON Lines file, `state_dir/log.jsonl`,
    appended only by the Script (agents report via their final messages; the
    Script translates those into log events). The lock in requirement 1
    guarantees a single writer. Events: `cycle-start`, `cycle-skipped`,
    `stand-down`, `selection`, `none-selected`, `stage-start`, `stage-end`,
    `pr-raised`, `pr-ready`, `attempt-failed`, `unblocked`, `limit-hit`,
    `warning`, `cycle-end`. Common fields: ISO-8601 `ts`, `cycle` id,
    `event`, and where applicable `repo`, `item`, `pr_url`, `model`,
    `detail`.
32. Blocked semantics: an item is blocked iff its most recent
    `attempt-failed` / `unblocked` event is `attempt-failed`. An
    `attempt-failed` event must carry enough detail for a future
    Co-Ordinator to judge whether the blocker has since been removed.
    `unblocked` events may also be appended by hand by the human.

## Deliverables

1. `config.json` with the values above.
2. `agent-cycle.sh` implementing requirements 1–13.
3. `prompts/coordinator.md`, `prompts/implementor.md`, `prompts/reviewer.md`
   implementing requirements 14–20, 21–26, and 27–30 respectively. Each
   prompt must embed the relevant shared-repo conventions from this document
   so a stage never depends on context it wasn't given.
4. `README.md`: what the system does, every config key, install steps
   (below), how to operate it (`--dry-run`, `--once`, reading the log and
   stage transcripts), and how to uninstall.
5. The crontab line, e.g.
   `0 * * * * $HOME/Code/agent-ops/agent-cycle.sh >> $HOME/.local/state/poetic-agents/cron.log 2>&1`.

## Acceptance checks (the builder must run all of these before finishing)

1. `shellcheck agent-cycle.sh` is clean.
2. `--dry-run` completes against the real repos: stand-down checks pass,
   ordering is computed, the Co-Ordinator selects an item or declines with a
   reason, the work order is printed, nothing further launches, and the log
   records the cycle.
3. A second invocation while one holds the lock exits without acting.
4. A simulated stale lock (fake lock file, old timestamp, dead PID) is taken
   over with a logged warning.
5. An injected `limit-hit` event with a future `resume_at` causes a
   stand-down; an expired one does not.
6. With `max_open_agent_prs` temporarily set to 0, the Script stands down on
   back-pressure.
7. One supervised full cycle (`--once`) against whichever repo the ordering
   picks: it produces a labelled, mergeable, ready-for-review PR with the
   originating register updated and a complete log trail. Report the PR URL
   to the human rather than merging anything.

## Prerequisites (human steps, before first run)

1. Install the standalone CLI: `curl -fsSL https://claude.ai/install.sh | bash`
   (or `npm install -g @anthropic-ai/claude-code`). Verify headless auth
   works: `claude -p "Reply with OK" --model claude-haiku-4-5-20251001`.
2. Enable cron in WSL: add to `/etc/wsl.conf`
   `[boot]` / `command = "service cron start"` (requires sudo), then restart
   WSL (`wsl --shutdown` from Windows). Alternative if preferred: a Windows
   Task Scheduler job running
   `wsl.exe -u wallen -e $HOME/Code/agent-ops/agent-cycle.sh` hourly.
   Either way, cycles only run while the machine is awake — a missed cycle
   simply waits for the next tick, which is harmless.
3. Create the label in both repos:
   `gh label create autonomous-agent -R Poetic-Poems/<repo> --description "PR raised by the autonomous agent system"`.
4. Create `Poetic-Poems/agent-ops`, clone it to `~/Code/agent-ops`, and run
   the builder session there with this document.
5. After the acceptance checks pass, install the crontab line.

## Cost profile

A worst-case cycle is one small Haiku selection pass, one Sonnet
implementation (the dominant cost), and one Sonnet review. Stand-down cycles
cost nothing but a few `gh` calls. Because back-pressure caps open agent PRs
at `max_open_agent_prs`, sustained spend is bounded by the rate at which the
human merges — the system cannot run ahead of its only consumer.

## Design decisions in this revision

Recorded so a future reader knows they were deliberate, not accidental.

- **The Script orchestrates every launch; the Co-Ordinator only selects.**
  Per-stage timeouts, clean kills, and restartability come free from the
  process model, and the cheap Co-Ordinator session is not held open while
  an implementation runs for an hour.
- **Agents work in ephemeral clones**, never in the user's working copies
  under `~/Code`, which the user may be editing at any moment.
- **Draft-PR claiming is fused with the review flow**: the Implementor's
  draft PR is simultaneously the repos' standard claim marker and the
  Reviewer's input; the Reviewer flipping it to ready is the hand-off to the
  human gate.
- **Back-pressure on open agent PRs replaces a quota-balance check** as the
  primary throttle, because no supported API exposes a subscription plan's
  remaining quota; usage-limit errors are handled fail-safe via detection
  and cooldown (requirement 10).
- **The 6-hour stale rule became a 3-hour lock plus per-stage timeouts** —
  finer-grained, and a wedged stage can no longer consume six hours of
  quota.
- **Work-source categories are mapped to what actually exists** in the two
  repos (failed runs, tech-debt registers, GitHub issues, and fiddle's
  implementation plan). User stories and road maps were dropped — neither
  repo has them; the config structure accepts new sources when they appear.
- **Tech-debt handling uses the repos' own claiming workflow directly**
  (both repos have identical `TECH-DEBT.md` machinery and a `/td` skill;
  the Implementor follows the documented workflow rather than dispatching
  through the skill, which exists to launch agents — the Implementor
  already is one).
- **The Co-Ordinator falls through** to the next category or repo when
  candidates fail the suitability bar, instead of giving up after the first
  category that yielded any candidate.
- **Branch names drop the repo slug** (`agent/<item-slug>`): a branch is
  already scoped to its repository.

No open questions remain. The choices above (platform, models, permissions,
system location) were confirmed by the repo owner on 2026-07-13.
