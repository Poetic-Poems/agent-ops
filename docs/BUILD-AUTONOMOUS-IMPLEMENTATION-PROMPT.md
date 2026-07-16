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
| poetic (framework) | `Poetic-Poems/poetic` | 1. **security findings** · 2. failed Actions runs on `main` · 3. `TECH-DEBT.md` · 4. open GitHub issues · 5. project-review recommendations · 6. code-quality findings |
| poetic-fiddle (web app) | `Poetic-Poems/poetic-fiddle` | 1. **security findings** · 2. failed Actions runs on `main` · 3. `TECH-DEBT.md` · 4. open GitHub issues · 5. `docs/IMPLEMENTATION-PLAN.md` (next milestone task) · 6. project-review recommendations · 7. code-quality findings |

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

The `project-review` source draws on the weekly project-review pipeline's own
output (see `docs/BUILD-REVIEW-PROMPT.md`), which lands in each repo via a
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
  **below tech-debt and issues** deliberately: the review already mirrors its
  debt-shaped recommendations into `TECH-DEBT.md` (cross-referencing the
  `R-NN`), and those curated, status-tracked entries are the primary channel —
  the `project-review` source exists to pick up the review's remaining
  recommendations (typically smaller improvements) that were *not* also filed
  as tech-debt or an issue, so nothing the review surfaced is silently dropped.
  It ranks above `code-quality` because a human-approved review recommendation
  is more deliberate than an automated quality suggestion. A recommendation
  whose text flags a **security concern** is security-related and so is caught
  by "security is always prioritised" like any other security candidate.

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
| `repos` | `["Poetic-Poems/poetic", "Poetic-Poems/poetic-fiddle"]` | Work-source lists per repo as in the table above (`security`, `failed-runs`, `tech-debt`, `issues`, `implementation-plan`, `project-review`, `code-quality`); structure the config so a repo or source can be added without code changes. |
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
   PR was ever opened. That breadcrumb lookup finding nothing is the *normal*
   case — no PR was opened — so it must not be an error: under `errexit` a
   non-zero there kills the cycle before it logs the very failure this
   requirement is about (see Gotchas).
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
     because the item is already done on `default_branch`. Record `item-void`
     with the stage's `reason` and `evidence`. **No agent may ever clear it**;
     only a human, by appending `unvoided` to the log by hand.
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
    `findings` with `source: "code-quality"`. The `project-review` source's
    candidates are the recommendations (`R-NN`) in the **most recent**
    `reviews/project-review-YYYY-MM-DD/` folder on the default branch: read
    that folder's `03-recommendations.md` and `04-improvement-prompts.md` via
    `gh api .../contents/...` (no pre-fetch — these are ordinary tracked files,
    like `TECH-DEBT.md`). A recommendation's stable ref is
    `review-<review-date>-R-NN`; the paired improvement prompt is the brief.
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
16. Excludes from candidacy any item that is:
    - recorded as blocked in the shared log (an `attempt-failed` event not
      followed by an `unblocked` event for that item);
    - a tech-debt item whose Ledger row is `in-progress`;
    - already referenced by any open PR or draft (a claim, per the repos'
      claiming workflow) — for a `security`/`code-quality` finding, that means
      an open PR whose branch or body already references the same alert
      (`ref`, alert URL, or the affected package/rule); for a `project-review`
      recommendation, an open PR whose branch or body references its ref
      (`review-<date>-R-NN`);
    - a `project-review` recommendation that is already **done** — a *merged*
      PR references its ref (`review-<date>-R-NN`) — or that is already owned
      by a higher-priority source: the review mirrors debt-shaped
      recommendations into `TECH-DEBT.md` (or files them as issues)
      cross-referencing the `R-NN`, so a recommendation cross-referenced by a
      current tech-debt entry or open issue is left to that source and skipped
      here. (A single `gh` PR search per repo for the review date surfaces the
      open/merged/closed PRs referencing that review; match refs against it.)
      Note that a merged PR is a *floor*, not a proof: work that landed as a
      direct commit, or before the repo required PRs, leaves no PR to find and
      so reads as outstanding forever. The cross-reference is what covers that
      gap, which is why the review spec (`docs/BUILD-REVIEW-PROMPT.md`, R12a)
      is required to write it and not merely expected to; requirement 9a is
      the backstop for when it is missing anyway — the item is then
      investigated once, and the finding remembered.
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
    and may then treat the item as a candidate this same cycle. Two limits,
    both load-bearing (requirements 9b, 34c):
    - This applies to *impediments only*. Discovering that the item's work is
      already **done** is never grounds to unblock it — that is a void, and
      unblocking it hands it back to the pool to be rediscovered every cycle.
      Say so explicitly in the prompt, with the reasoning: an agent told to
      "clear blockers that no longer apply" will otherwise conclude, correctly
      and disastrously, that an already-done item has no blocker.
    - It may **never** clear a void item, and is given no field with which to
      try. It may *create* one for a candidate it can see conclusively is
      already done, which saves an entire Implementor run.
19. Chooses the Implementor's model: `implementor_model_trivial` only when
    the item can be completed without changing any file that affects runtime
    behaviour (docs, comments, register entries); otherwise
    `implementor_model_default`. Records the reasoning.
20. Emits a work order as its entire final message. `source` is one of
    `security`, `failed-runs`, `tech-debt`, `issues`, `implementation-plan`,
    `project-review`, or `code-quality`. For a `security`/`code-quality`
    finding, `item` is the finding's stable `ref` (e.g. `dependabot-alert-42`,
    `code-scanning-alert-17`) and `context` must paste the finding verbatim
    (package/rule, severity, affected location, advisory summary, and the
    alert URL) so the Implementor can act without re-querying the API. For a
    `project-review` recommendation, `item` is its ref
    (`review-<review-date>-R-NN`) and `context` must paste the recommendation's
    improvement prompt (from `04-improvement-prompts.md`) verbatim, together
    with the review folder path and the `R-NN` detail; `acceptance` is the
    recommendation's *Intended end state*.

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
    claim is visible to any other cycle scanning open PRs. For a
    `project-review` recommendation, the draft PR body names the ref
    (`review-<date>-R-NN`) and links the review folder and recommendation, so
    the claim (and, once merged, the completion) is visible to any other cycle
    scanning PRs — there is no ledger and the review folder is not modified.
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
    itself (dismissal is a human decision). For a `project-review`
    recommendation, there is likewise no ledger to flip and the review folder
    (a point-in-time record) is left untouched — the PR body names the ref
    (`review-<date>-R-NN`) so its eventual merge marks the recommendation done;
    a later review re-evaluates the code and simply omits anything now fixed.
    Adds a `CHANGELOG.md` entry when the change is notable by that repo's
    definition (a security fix usually is).
26. Verifies the PR via `gh pr view --json mergeable,mergeStateStatus`
    (against GitHub's view, not inferred locally) and resolves any conflict
    with the current default branch. Leaves the PR as a **draft** — the
    Reviewer flips it to ready.
27. Ends with a single JSON object as its entire final message:
    `{"status": "complete", "pr_url": …, "branch": …, "notes": …}`,
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
    `pr-raised`, `pr-ready`, `attempt-failed`, `unblocked`, `item-void`,
    `unvoided`, `limit-hit`, `warning`, `cycle-end`. Common fields: ISO-8601
    `ts`, `cycle` id, `event`, and where applicable `repo`, `item`, `pr_url`,
    `model`, `detail`. `selection`, and any `attempt-failed` or `item-void`
    raised once an item has been selected, must carry both `repo` and `item` —
    requirements 34 and 34c key on them, so an event that omits them cannot
    pin any state on the item it names, and the omission is invisible until you
    notice the same work being redone.
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
    dashboard (`docs/BUILD-DASHBOARD-PROMPT.md`) — shares that one
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
      safe where clearing is not — a wrong void costs a human one line in a
      log, a wrong unvoid costs a cycle every hour until someone notices.

## Deliverables

1. `config.json` with the values above.
2. `agent-cycle.sh` implementing requirements 1–13 (including the findings
   pre-fetch, requirement 3a).
3. `scripts/gather-findings.sh` implementing requirement 3a: given a repo
   slug, prints a normalised JSON array of the repo's open Dependabot and
   code-scanning alerts, degrading to `[]` (exit 0) when a feature is
   disabled or inaccessible. Must pass `shellcheck`.
3a. A shared library (as built, `lib/cycle-state.sh` and `lib/limit-detect.sh`)
   holding every rule that more than one component computes — at minimum
   requirement 34's blocked semantics, requirement 33's `attempt-failed` field
   shape, and the usage-limit phrase pattern of requirement 10 — sourced by
   both `agent-cycle.sh` and the dashboard's publisher rather than copied into
   either. Unit-tested directly (`test/*.test.sh`, plain bash assertions, no
   framework) and `shellcheck`-clean. These rules are the system's memory of
   what it has already tried; a second copy of one is a bug with a delay
   fuse, and both copies read correctly right up until they disagree.
4. `prompts/coordinator.md`, `prompts/implementor.md`, `prompts/reviewer.md`
   implementing requirements 14–20, 21–27, and 28–32 respectively. Each
   prompt must embed the relevant shared-repo conventions from this document
   so a stage never depends on context it wasn't given.
5. `README.md`: what the system does, every config key, install steps
   (below), how to operate it (`--dry-run`, `--once`, reading the log and
   stage transcripts), and how to uninstall.
6. The crontab line, e.g.
   `0 * * * * $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh >> $HOME/.local/state/poetic-agents/cron.log 2>&1`.

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
7. **A blocked verdict round-trips.** Append an `attempt-failed` for a
   selected item, then run a cycle: the Co-Ordinator's input must list that
   item as blocked, with its detail. This is the one check that catches the
   writer and the reader disagreeing about the event key (requirements 33/34)
   — nothing else in the system will tell you they disagree, because both
   halves look correct in isolation and the only symptom is work being
   silently redone.
8. **A no-op Implementor is recorded.** Drive one cycle in which the
   Implementor reports `blocked` without opening a PR: the cycle must exit 0
   having logged an `attempt-failed` carrying that item and the stage's own
   reason — not die part-way, and not log nothing. Under `errexit` this is
   where a helper returning "not found" as a non-zero status silently kills
   the run (requirement 9).
8a. **A void survives an agent trying to clear it.** Append an `item-void` for
   an item, then an `unblocked` for the same item, then run a cycle: the item
   must still be void and absent from the Co-Ordinator's candidates. This is
   the check that would have caught requirement 9b being collapsed into one
   state, and it fails loudly on a system that looks entirely healthy — the
   log fills with confident, correct-looking events and the same item is
   worked forever. Assert the negative too: `unvoided` *does* clear it, or you
   have built a state no human can escape.
8b. **The two states are visible apart.** A human looking at the monitor can
   tell "waiting on something" from "there is nothing to do here" without
   reading the log. If both render as one list, the operator cannot tell an
   item needing their help from one needing nothing, which is how a stuck
   pipeline and a healthy one come to look identical.
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
   `wsl.exe -u wallen -e $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh` hourly.
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
4. Create `Poetic-Poems/agent-ops`, clone it to `~/Code/Poetic-Poems/agent-ops`, and run
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
  fiddle's implementation plan, project-review recommendations, and
  code-quality findings). User stories and road maps were dropped — neither
  repo has them; the config structure accepts new sources when they appear.
- **The weekly project review feeds the pipeline as a work source.** The
  review pipeline (`docs/BUILD-REVIEW-PROMPT.md`) lands, in each repo, both an
  updated `TECH-DEBT.md` (the primary, status-tracked channel — picked up by
  the `tech-debt` source) and a `reviews/project-review-*/` folder of
  prioritised recommendations with ready-to-run improvement prompts. The
  `project-review` source consumes the latter so that recommendations *not*
  also filed as tech-debt or an issue are still actioned rather than left to
  rot in a folder. It sits just above `code-quality` (a human-approved
  recommendation beats an automated one) and below the curated channels, and
  dedups against them via the `R-NN` cross-reference the review writes into
  each mirrored tech-debt entry (required of the review by R12a of
  `docs/BUILD-REVIEW-PROMPT.md` — for a long time this bullet merely *assumed*
  it, which is why the dedup silently didn't work; see Gotchas). Because the recommendations file is
  regenerated each week (its `R-NN` IDs are per-review, so a ref is
  review-dated), an un-actioned recommendation is simply re-offered under a new
  ref by the next review; persistent items live in `TECH-DEBT.md`, which has
  stable IDs — so the regeneration doesn't strand work. Done-ness is tracked by
  the PR referencing the ref (open = claimed, merged = done), the same
  PR-as-source-of-truth pattern the findings sources use, so the review folder
  stays an immutable point-in-time record.
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
| A contract asserted in one document and required by none | This spec's design notes state the review "writes the `R-NN` cross-reference into each mirrored tech-debt entry" — and `docs/BUILD-REVIEW-PROMPT.md` never asked for it. Both documents were internally consistent; the system between them was not, and the dedup it justified never worked. | When one component's design depends on another's behaviour, make it a numbered requirement *in the document that builds that component*, and cite it from both sides. Prose describing what another component "does" is a wish, not an interface. |
| One state carrying two meanings, where an agent can reason its way out of it | "Blocked" meant both *something is in the way* and *there is nothing to do*. The Co-Ordinator is told to clear blockers that have lifted; it checked an already-done item, correctly found nothing in its way, and logged `unblocked` — returning it to the pool to be rediscovered forever. Every component obeyed its spec exactly. The fix for the previous row *created* this one, and it took a live cycle to see. | Split the states (requirement 9b): `blocked` is clearable by an agent, `void` only by a human. Test that the clear for one cannot fire on the other. **The tell:** if the same fact that ought to make a state permanent is also grounds for clearing it, the state is wrong. Ask of every agent-clearable state: what would the agent have to believe to clear this, and is that belief the reason it exists? |
