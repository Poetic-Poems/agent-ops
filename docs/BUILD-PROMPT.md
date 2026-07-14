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
| poetic (framework) | `Poetic-Poems/poetic` | 1. **security findings** · 2. failed Actions runs on `main` · 3. `TECH-DEBT.md` · 4. open GitHub issues · 5. code-quality findings |
| poetic-fiddle (web app) | `Poetic-Poems/poetic-fiddle` | 1. **security findings** · 2. failed Actions runs on `main` · 3. `TECH-DEBT.md` · 4. open GitHub issues · 5. `docs/IMPLEMENTATION-PLAN.md` (next milestone task) · 6. code-quality findings |

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
  findings) plus any other code-quality findings GitHub surfaces. This is the
  lowest-priority source: automated quality suggestions are more speculative
  and higher-volume than curated tech-debt or filed issues, so they are
  picked up only when nothing more deliberate is waiting.

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
| `repos` | `["Poetic-Poems/poetic", "Poetic-Poems/poetic-fiddle"]` | Work-source lists per repo as in the table above (`security`, `failed-runs`, `tech-debt`, `issues`, `implementation-plan`, `code-quality`); structure the config so a repo or source can be added without code changes. |
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
| `limit_cooldown_default` | 3 h | Stand-down period after an ordinary/transient usage-limit error whose reset time cannot be parsed. A weekly/monthly match with no parseable reset time uses the longer `LIMIT_LONG_COOLDOWN_HOURS` fallback in `lib/limit-detect.sh` instead (see requirement 10) — not this key. |

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
4. **Co-Ordinator stage.** Launch the Co-Ordinator (headless, model
   `coordinator_model`, `--dangerously-skip-permissions`, stage timeout),
   passing it the ordered repo list (each entry carrying its work sources and
   its pre-fetched `findings`) and the blocked-item extract from the shared
   log. Capture its final message with Claude Code's JSON output format and
   parse the work order from it.
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
   the PR and branch for the human to keep or discard. Because a stranded
   Implementor may never emit a parseable final message (and so never
   report its own `pr_url`), the Script also checks the clone for the
   `.git/agent-ops-pr-url` breadcrumb (requirement 23) before concluding no
   PR was ever opened.
10. **Usage-limit detection.** Whenever any `claude` invocation's transcript
    matches the shared pattern in `lib/limit-detect.sh` (`LIMIT_PHRASE_REGEX`
    — the generic `hit your .* limit` stem plus the legacy `usage limit` /
    `rate limit` / `usage cap` / `quota exceeded` terms; sourced by both the
    Script and `scripts/publish-dashboard.sh` so the two can't drift apart),
    write a `limit-hit` event with `resume_at`, `class`, and `needs_human`:
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
    - `needs_human` is true only when no reset time was parseable AND the
      phrasing says weekly/monthly (the spend-cap case: it clears only when a
      human raises the cap, or the billing month rolls over — auto-retry
      cannot fix it). A parsed reset time always means `needs_human: false`,
      since the pipeline can resume unattended once `resume_at` passes.

    There is no supported API for querying a subscription plan's remaining
    quota, so this fail-safe detection *is* the quota check, and
    back-pressure (2.2) is the primary spend control. Treat a parsed
    `resume_at` as an upper bound to stand down *until*, not a promise the
    block lasts that long — a cycle that succeeds before then simply clears
    the stand-down on its own.
11. **Cleanup.** Always: delete the cycle's workspace, write a `cycle-end`
    event, release the lock. Tee each stage's stdout/stderr to
    `state_dir/cycles/<cycle-id>/` for debugging.
12. **Flags.** `--dry-run` (run through step 5 then stop: prints the work
    order, launches no Implementor), `--once` (one verbose cycle in the
    foreground), `--repo <slug>` (restrict selection, for testing).
13. The Script must pass `shellcheck` and must set its own `PATH` explicitly
    (cron's environment is minimal), covering `claude`, `gh`, `git`, `jq`.
    The builder must also prove that a cron-style invocation can resolve
    `claude` by running it from a minimal environment (for example with a
    sanitized `PATH` and `HOME`) before considering the setup complete.

### The Co-Ordinator (selection only)

14. Works read-only: `gh` reads (runs, issues, PRs, file contents via
    `gh api`) — it does not clone, and writes nothing but its final message.
    For the `security` and `code-quality` sources it does **not** re-query the
    Dependabot/code-scanning APIs itself; it reads the pre-fetched `findings`
    array the Script attached to each repo (requirement 3a), spending its
    `gh` budget only on the cheap claim/blocked checks below.
15. Walks the repos in the order given. Within a repo, checks work sources
    in the configured priority order. For "failed Actions runs", a candidate
    exists only where the **most recent** run of a workflow on the default
    branch is a failure (a later green run supersedes older failures). The
    `security` source's candidates are the pre-fetched `findings` with
    `source: "security"` (Dependabot alerts and security-severity
    code-scanning alerts); the `code-quality` source's candidates are the
    `findings` with `source: "code-quality"`.
15a. **Security is always prioritised.** Beyond `security` being first in the
    source order, any candidate that is security-related — a `security`
    finding, a GitHub issue labelled `security`/`vulnerability`, or a
    tech-debt entry flagged as a security concern — outranks every
    non-security candidate across all repos and sources. If any selectable
    security candidate exists anywhere, the Co-Ordinator selects one of those
    before any non-security item, with the most severe first
    (`critical` > `high` > `medium` > `low`). Repo ordering (requirement 3)
    breaks ties among security candidates of equal severity.
16. Excludes from candidacy any item that is:
    - recorded as blocked in the shared log (an `attempt-failed` event not
      followed by an `unblocked` event for that item);
    - a tech-debt item whose Ledger row is `in-progress`;
    - already referenced by any open PR or draft (a claim, per the repos'
      claiming workflow) — for a `security`/`code-quality` finding, that means
      an open PR whose branch or body already references the same alert
      (`ref`, alert URL, or the affected package/rule);
    - an issue that is assigned, labelled `blocked`, or is a question or
      discussion rather than actionable work;
    - a security finding whose only available fix is one a human must choose
      (e.g. a Dependabot alert with no non-breaking upgrade, needing a major
      version bump that changes the repo's public behaviour) — flag it, don't
      guess the upgrade;
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
20. Emits a work order as its entire final message. `source` is one of
    `security`, `failed-runs`, `tech-debt`, `issues`, `implementation-plan`,
    or `code-quality`. For a `security`/`code-quality` finding, `item` is the
    finding's stable `ref` (e.g. `dependabot-alert-42`,
    `code-scanning-alert-17`) and `context` must paste the finding verbatim
    (package/rule, severity, affected location, advisory summary, and the
    alert URL) so the Implementor can act without re-querying the API.

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
    obeys it throughout. Creates the branch named in the work order from the
    default branch.
23. **Claims before implementing.** Opens a draft PR immediately, labelled
    `pr_label`, with a Conventional-Commits title (it will become the squash
    commit on `main`) and a body giving the item reference and planned
    approach. Immediately records the PR's URL at `.git/agent-ops-pr-url` in
    the clone — `.git/` is never part of the tracked tree, so this can't
    leak into a commit — so the Script can still identify the PR even if
    this stage never reaches a parseable final message (requirement 9). For
    tech-debt items this follows the repo's claiming workflow exactly
    (Ledger flip to `in-progress` as the first commit). For issues, it
    comments on the issue linking the draft PR. For `security`/`code-quality`
    findings, the draft PR body names the alert (its `ref` and URL) so the
    claim is visible to any other cycle scanning open PRs.
24. Implements the item, then runs the same checks the repo's CI runs (as
    documented in that repo's `CLAUDE.md` and workflow files) and fixes
    anything they surface.
25. Updates the originating record: tech-debt entry removed and Ledger row
    flipped to `resolved` per the register's rules; issues linked with a
    closing keyword in the PR body; implementation-plan task marked done.
    For `security`/`code-quality` findings, no ledger flip applies — GitHub
    closes a Dependabot or code-scanning alert automatically once the fix
    lands on the default branch and is re-scanned — so the PR body names the
    alert it resolves (and its URL); the Implementor never dismisses an alert
    itself (dismissal is a human decision). Adds a `CHANGELOG.md` entry when
    the change is notable by that repo's definition (a security fix usually
    is).
26. Verifies the PR via `gh pr view --json mergeable,mergeStateStatus`
    (against GitHub's view, not inferred locally) and resolves any conflict
    with the current default branch. Leaves the PR as a **draft** — the
    Reviewer flips it to ready.
27. Ends with a single JSON object as its entire final message:
    `{"status": "complete", "pr_url": …, "branch": …, "notes": …}` or
    `{"status": "blocked", "reason": …, "unblock_condition": …}`.

### The Reviewer

28. Operates under the same one-shot constraint as the Implementor
    (requirement 21): no resumption, no background notification. It waits
    for slow commands — installs, builds, `gh pr checks --watch` — in the
    foreground within the same session rather than ending its turn early.
29. Reviews the PR against the work order's item and acceptance notes, and
    against the target repo's own standards and conventions; re-runs the
    repo's checks.
30. Where it finds a problem it can fix with confidence, it fixes it
    directly on the branch — committing, rebasing onto the current default
    branch, or force-pushing as it judges best (permitted only on
    `branch_prefix` branches, per "The Human Gate"). Where it cannot fix
    with confidence, it leaves a PR review comment describing the problem
    for the Human Reviewer.
31. Confirms CI is passing (`gh pr checks`) and the PR is mergeable, then
    marks it ready for review (`gh pr ready`). It never approves and never
    merges.
32. Ends with a single JSON object:
    `{"status": "ready" | "needs-human", "pr_url": …, "fixes_applied": […], "comments_left": n, "ci": "passing" | …}`.

### Logging and state

33. The shared log is a single JSON Lines file, `state_dir/log.jsonl`,
    appended only by the Script (agents report via their final messages; the
    Script translates those into log events). The lock in requirement 1
    guarantees a single writer. Events: `cycle-start`, `cycle-skipped`,
    `stand-down`, `selection`, `none-selected`, `stage-start`, `stage-end`,
    `pr-raised`, `pr-ready`, `attempt-failed`, `unblocked`, `limit-hit`,
    `warning`, `cycle-end`. Common fields: ISO-8601 `ts`, `cycle` id,
    `event`, and where applicable `repo`, `item`, `pr_url`, `model`,
    `detail`.
34. Blocked semantics: an item is blocked iff its most recent
    `attempt-failed` / `unblocked` event is `attempt-failed`. An
    `attempt-failed` event must carry enough detail for a future
    Co-Ordinator to judge whether the blocker has since been removed.
    `unblocked` events may also be appended by hand by the human.

## Deliverables

1. `config.json` with the values above.
2. `agent-cycle.sh` implementing requirements 1–13 (including the findings
   pre-fetch, requirement 3a).
3. `scripts/gather-findings.sh` implementing requirement 3a: given a repo
   slug, prints a normalised JSON array of the repo's open Dependabot and
   code-scanning alerts, degrading to `[]` (exit 0) when a feature is
   disabled or inaccessible. Must pass `shellcheck`.
4. `prompts/coordinator.md`, `prompts/implementor.md`, `prompts/reviewer.md`
   implementing requirements 14–20, 21–27, and 28–32 respectively. Each
   prompt must embed the relevant shared-repo conventions from this document
   so a stage never depends on context it wasn't given.
5. `README.md`: what the system does, every config key, install steps
   (below), how to operate it (`--dry-run`, `--once`, reading the log and
   stage transcripts), and how to uninstall.
6. The crontab line, e.g.
   `0 * * * * $HOME/Code/agent-ops/agent-cycle.sh >> $HOME/.local/state/poetic-agents/cron.log 2>&1`.

## Acceptance checks (the builder must run all of these before finishing)

1. `shellcheck agent-cycle.sh scripts/gather-findings.sh` is clean.
2. `--dry-run` completes against the real repos: stand-down checks pass,
   ordering is computed, the findings pre-fetch runs, the Co-Ordinator selects
   an item or declines with a reason, the work order is printed, nothing
   further launches, and the log records the cycle.
2a. `scripts/gather-findings.sh Poetic-Poems/poetic` prints a valid JSON
   array (possibly empty), and prints `[]` and exits 0 for a repo with the
   features disabled — never a non-zero exit that would abort the cycle.
3. A second invocation while one holds the lock exits without acting.
4. A simulated stale lock (fake lock file, old timestamp, dead PID) is taken
   over with a logged warning.
5. An injected `limit-hit` event with a future `resume_at` causes a
   stand-down; an expired one does not.
6. With `max_open_agent_prs` temporarily set to 0, the Script stands down on
   back-pressure.
9. A cron-style invocation from a minimal environment can resolve `claude`
   and run `claude -V` (or a tiny `claude -p` smoke test) successfully.
10. One supervised full cycle (`--once`) against whichever repo the ordering
    picks: it produces a labelled, mergeable, ready-for-review PR with the
    originating register updated and a complete log trail. Report the PR URL
    to the human rather than merging anything.

## Prerequisites (human steps, before first run)

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
   `wsl.exe -u wallen -e $HOME/Code/agent-ops/agent-cycle.sh` hourly.
   Either way, cycles only run while the machine is awake — a missed cycle
   simply waits for the next tick, which is harmless.
3. Create the label in both repos:
   `gh api -X POST repos/Poetic-Poems/<repo>/labels -f name='autonomous-agent' -f color='ededed' -f description='PR raised by the autonomous agent system'`.
   If your `gh` version already supports `gh label create`, that form also works; the API form above is the most compatible fallback.
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
  repos (security findings, failed runs, tech-debt registers, GitHub issues,
  fiddle's implementation plan, and code-quality findings). User stories and
  road maps were dropped — neither repo has them; the config structure
  accepts new sources when they appear.
- **Security findings are a first-class, always-first work source.** GitHub's
  own Dependabot and code-scanning alerts are treated as work items, and any
  security-related candidate outranks all non-security work (requirement 15a),
  even a red `main` — a known, exploitable vulnerability is the highest-stakes
  thing the pipeline can be pointed at. Non-security code-scanning findings
  become the lowest-priority `code-quality` source: real, but more speculative
  and higher-volume than curated tech-debt or filed issues, so they never
  crowd out deliberate work.
- **Findings are pre-fetched by the Script, not the model** (requirement 3a,
  `scripts/gather-findings.sh`). The Dependabot and code-scanning APIs are
  paginated and verbose; digesting them in the cheap Co-Ordinator session
  would burn tokens on plumbing. A deterministic bash+`gh`+`jq` script
  normalises them into compact findings the Co-Ordinator reads directly — the
  same pattern already used to feed it the ordered repo list and blocked
  extract. It fails safe to `[]` so a repo without the feature (or without
  token scope) costs nothing and breaks nothing.
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
