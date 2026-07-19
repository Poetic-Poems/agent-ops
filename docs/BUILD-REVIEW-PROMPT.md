# Weekly Project-Review Pipeline — build prompt

## How to use this document

Give this document, whole, to a Claude Code session (Sonnet 5 or better)
started in the existing `Poetic-Poems/agent-ops` repository, with the
instruction "build the weekly project-review pipeline this document
describes". It is a companion to `docs/BUILD-AUTONOMOUS-IMPLEMENTATION-PROMPT.md` (the hourly
implementation pipeline) and `docs/BUILD-DASHBOARD-PROMPT.md` (the monitoring
dashboard).

**Where this document is silent, follow `docs/BUILD-AUTONOMOUS-IMPLEMENTATION-PROMPT.md`.** The two
pipelines deliberately share their machinery — the lock discipline, the
minimal-`PATH` bootstrap for cron, usage-limit detection (`lib/limit-detect.sh`),
the JSON-Lines log format and `log_event` helper, the ephemeral-clone rule,
the per-stage timeout with process-group kill (`run_claude_stage`), and the
"straight-parse-else-last-fenced-```json```-block" result parser. This
pipeline **reuses** those, and must not reinvent them. References of the form
"requirement N" mean requirement N of `docs/BUILD-AUTONOMOUS-IMPLEMENTATION-PROMPT.md`. The target
repositories' `CLAUDE.md` files remain binding on any agent working inside
them.

## What to build

A second, independent pipeline that runs alongside the hourly implementation
pipeline. Once a week, for each target repository, it produces a full project
review — via the vendored `project-review` skill — against a fresh ephemeral
clone, and leaves **one** mergeable pull request carrying the review reports
and an updated `TECH-DEBT.md`. A human merges it. The review's new tech-debt
entries and improvement prompts then feed the hourly implementation pipeline
(and/or the `project-remediation` skill). The only human involvement is
merging the review pull request.

```
cron (weekly; a daily tick with a skip-guard is recommended — see R4)
  └─ review-cycle.sh                  ← the Review Script: lock, stand-down, per-repo skip-guard
       └─ for each target repo, sequentially:
            ├─ ephemeral clone            ← fresh from GitHub, under workspace_root
            ├─ inject the vendored skill  ← into the clone, git-excluded (never committed)
            └─ Reviewer-Agent (Sonnet)    ← runs the skill, raises ONE review PR (ready)
                  └─ Human                ← reviews and merges (the only gate)
                        └─ feeds → hourly implementation pipeline / project-remediation
```

## Relationship to the existing pipelines

- **Separate everything that must be separate:** its own Script
  (`review-cycle.sh`), its own cron entry, its own lock (`review-lock.json`),
  its own PR label (`project-review`). **Shared where sharing is correct:**
  `config.json`, `state_dir`, `workspace_root`, `lib/limit-detect.sh`, the
  ephemeral-clone discipline, the `PATH` bootstrap, and the result parser.
- **The review pipeline defers to the implementation pipeline.** If the
  implementation lock (`lock.json`) is held by a live process, the Review
  Script stands down and waits for the next tick — two heavy `claude` runs
  should not overlap, because they draw on the same subscription quota. This
  requires **no change to `agent-cycle.sh`**; the deference is entirely on the
  review side.
- **One shared quota signal.** A `limit-hit` event (requirement 10) is written
  to the *shared* `log.jsonl` with the *same* shape, so a usage-limit hit in
  either pipeline stands **both** down, and the dashboard shows it. All other
  review events go to the review pipeline's own stream (R16), so the
  dashboard's existing `log.jsonl` parser is unaffected.

## Entities

1. The **Review Cronjob** — the crontab entry that fires the Review Script.
2. The **Review Script** (`review-cycle.sh`) — a bash script that orchestrates
   one weekly run across the target repositories. It launches the
   Reviewer-Agent; agents never launch the Script.
3. The **Reviewer-Agent** — a headless Claude Code invocation that runs the
   `project-review` skill against one ephemeral clone and raises one review
   pull request. One invocation per repository.
4. The **Human Reviewer** — merges the review pull request through the ordinary
   GitHub process, and decides how to action its recommendations. Not launched
   by any part of this system.

## Environment facts

Identical to `docs/BUILD-AUTONOMOUS-IMPLEMENTATION-PROMPT.md` ("Environment facts" and "Target
repositories"); not repeated here. The two target repositories are the same
`Poetic-Poems/poetic` and `Poetic-Poems/poetic-fiddle`, and their shared
conventions (protected `main`, squash-merge so the PR title becomes the commit,
Conventional Commits, the `TECH-DEBT.md` Ledger with `scripts/next-tech-debt-id.pl`)
bind the Reviewer-Agent exactly as they bind the Implementor.

One repository-specific fact worth noting: `poetic` already stores prior
reviews under `reviews/project-review-YYYY-MM-DD/`; `poetic-fiddle` does not
yet have a `reviews/` folder, and the skill will create one on its first run.

## The `project-review` skill (vendored)

The skill is **vendored** into this repository at
`.claude/skills/project-review/` — a pinned copy of the upstream skill at
`~/Code/claude-skills/skills/project-review` (upstream commit `2c8e18c`,
vendored 2026-07-19). Only the runtime surface is vendored: `SKILL.md` and
`references/` (the four reference documents the skill reads); the upstream
`evals/` directory is dev-only and is intentionally omitted.

Two decisions are deliberate:

- **Vendored, not relied on ambient.** The machine's globally-available
  `project-review` skill is a *symlink* into the authoring repo
  (`~/.claude/skills/project-review` → `~/Code/claude-skills/...`) — machine
  state outside this repository's version control. Vendoring a pinned copy
  makes the pipeline reproducible from `agent-ops` alone and immune to the
  authoring repo moving or changing under it. Re-sync the copy deliberately
  when you want a newer skill; treat upstream as the source and this copy as a
  pinned deployment, exactly as `poetic` vendors framework files into consumer
  repos.
- **In the orchestrator, not the product repos.** The review runs in an
  *ephemeral clone* of each product repo (the pipeline never touches the
  working copies under `~/Code`, and `main` is protected). So the skill must
  live with the orchestrator and be **staged into the clone at runtime**
  (R5b). Keeping it here — rather than committing it into `poetic` and
  `poetic-fiddle` — keeps the product repos clean, keeps the skill out of its
  own review's scope, and avoids opening a pull request into two protected
  product repositories merely to enable this pipeline.

## Configuration

Add one `review` object to the existing `config.json` (do not create a second
config file). The values below are the confirmed defaults; document each key in
the README.

```json
"review": {
  "repos": ["Poetic-Poems/poetic", "Poetic-Poems/poetic-fiddle"],
  "model": "claude-sonnet-5",
  "pr_label": "project-review",
  "branch_prefix": "review/",
  "timeout_review": 120,
  "lock_stale_after": 6,
  "min_days_between_reviews": 6
}
```

| Key | Value | Notes |
|---|---|---|
| `review.repos` | `["Poetic-Poems/poetic", "Poetic-Poems/poetic-fiddle"]` | The repositories to review. A plain list of slugs — a review has no per-repo work-source structure. Adding a repo is a config-only change. |
| `review.model` | `claude-sonnet-5` | The Reviewer-Agent's model — the lead that drives the skill. The skill itself delegates well-scoped sub-tasks to lower-cost subagents, so this is the only model to pin here. A deeper review can be dialled up to a higher-capability model without other changes. |
| `review.pr_label` | `project-review` | Applied to every review PR. **Distinct** from the implementation pipeline's `autonomous-agent`, so review PRs never count against `max_open_agent_prs` and are trivially filterable. |
| `review.branch_prefix` | `review/` | Branch name `review/<date>`, e.g. `review/2026-07-20`. A branch is already scoped to its repository, so no slug is needed. |
| `review.timeout_review` | `120` | Minutes. Per-repo wall-clock timeout for the Reviewer-Agent, enforced by the Script. A full review is long; this is generous. |
| `review.lock_stale_after` | `6` | Hours. Larger than the implementation pipeline's 3 h, because two full reviews back-to-back can exceed it. |
| `review.min_days_between_reviews` | `6` | The skip-guard threshold (R4). A repo reviewed within this many days is skipped. Six (not seven) leaves a day of slack, so a review that lands late one week is not pushed a full extra week the next. |

Model IDs are pinned in config (one place to update); do not use floating
aliases in the launch command.

## The Human Gate and the loop it closes

The review pipeline raises **one pull request per repository, ready for
review** (not draft — the review *is* the deliverable, and there is no second
review stage to flip it). The PR is labelled `review.pr_label`, titled in
Conventional Commits form (e.g. `docs(review): weekly project review 2026-07-20`),
and its body summarises the verdict and links the review index. A human merges
it — the single point at which a human is required.

The point of the pipeline is the *loop*, not the report. When a review PR
merges, its updated `TECH-DEBT.md` and its `04-improvement-prompts.md` land on
`main`, where:

- the **hourly implementation pipeline's** Co-Ordinator picks up the new
  tech-debt items on its next cycle (its `tech-debt` work source reads exactly
  that Ledger); and/or
- the human runs the **`project-remediation`** skill (the review's
  counterpart) to work down the recommendations deliberately.

So the review is the *front* of a loop that ends in merged, human-approved
improvements — never a dead-end document.

## Requirements

### The Review Script (`review-cycle.sh`)

R1. **Bootstrap.** Reuse the `PATH` bootstrap and binary checks of
   `agent-cycle.sh` verbatim (claude, gh, git, jq must resolve under cron's
   minimal environment). Source `lib/limit-detect.sh`. The script must pass
   `shellcheck`.

R2. **Lock.** Acquire `review-lock.json` in `state_dir` recording PID and
   start time (its own lock, *not* the implementation `lock.json`). Apply the
   same held/stale/dead logic as requirement 1, using
   `review.lock_stale_after`: skip cleanly if a live review is younger than the
   threshold; take over a stale or dead lock, killing its process group and
   logging a `warning`.

R3. **Stand-down checks.** Each logs its reason and exits 0:
   1. *Usage-limit cooldown* — read the shared `log.jsonl`'s most recent
      `limit-hit` event; if its `resume_at` is still in the future, stand down
      (identical to requirement 2.1).
   2. *Implementation pipeline busy* — if `lock.json` is held by a live
      process, stand down and wait for the next tick (defer to it, per
      "Relationship to the existing pipelines").

R2a. **The switch.** Before the lock, read the shared switch
   (`state_dir/disabled.json`) through `lib/toggle.sh` and stand down while it
   is set, logging `review-stand-down` with the reason it carries — the same
   check `agent-cycle.sh` makes, through the same code, so the two pipelines
   cannot disagree about whether they are meant to be running (requirement
   34a).

   The switch is **shared, not per-pipeline**, and this pipeline is the reason
   that matters rather than an afterthought. It exists because an agent editing
   the agent-ops working tree is editing files the next cron tick will source —
   and this script runs out of that same tree and sources that same `lib/`. An
   agent that stood down only the implementation pipeline before editing
   `lib/limit-detect.sh` would have left the weekly review free to fire into a
   half-written file.

   This pipeline **honours the switch but never sets it**: `agent-cycle.sh
   --disable/--enable/--status` is the single entry point, so there is one
   writer and one record. Reject those flags here with a pointer rather than
   implementing a second way to write the same file. Leave an *expired* switch
   for `agent-cycle.sh` to clear and log, too: this pipeline runs weekly, so
   letting it clear one would mean the `enabled` event explaining why cycles
   resumed could land days after they did.

R4. **Per-repo skip-guard (idempotency; this is how "once a week" is
   enforced).** For each configured repo, skip it *this run* when **either**:
   - an open pull request labelled `review.pr_label` already exists for it (a
     review is in-flight or awaiting merge); **or**
   - its default branch already contains a `reviews/project-review-YYYY-MM-DD/`
     folder dated within the last `review.min_days_between_reviews` days
     (read best-effort via `gh`, e.g. the contents of `reviews/` on the
     default branch).

   Log `review-skipped` with the reason. This guard is what makes a **daily**
   cron tick safe and preferable to a strict weekly one: the Script only
   actually reviews a repo when at least `min_days_between_reviews` days have
   passed, so a tick missed because the machine was asleep simply catches up on
   the next day instead of losing a whole week (compare requirement note that
   "a missed cycle simply waits for the next tick").

R5. **Per non-skipped repo** (processed **sequentially**, so a failure of one
   never blocks the other and only one heavy `claude` runs at a time):
   1. *Workspace.* Create `workspace_root/<review-id>-<repo-slug-safe>/` and
      clone the repo fresh from GitHub — the multi-agent ways-of-working rule
      shared by all Poetic repositories: every agent works in its own
      dedicated fresh clone taken from the tip of the default branch before
      commencing any changes. (A full clone — the review examines git
      history.) Assert the working
      directory is under `workspace_root` before launching any stage
      (requirement 6). The user's own clones under `~/Code` are never touched.
   2. *Inject the skill.* Copy this repository's
      `.claude/skills/project-review/` into
      `<clone>/.claude/skills/project-review/`, then append
      `/.claude/skills/project-review/` to `<clone>/.git/info/exclude` so the
      injected tooling can never be staged or committed by the review agent.
      (`.git/info/exclude` is per-clone and never part of the tree, so this
      leaves no trace in the PR. The clone already has its own `.claude/`; the
      injection sits alongside its existing skills.)
   3. *Reviewer-Agent stage.* Launch the Reviewer-Agent headless (model
      `review.model`, `--dangerously-skip-permissions`, `--output-format json`,
      timeout `review.timeout_review`), with the clone as the working
      directory, passing `prompts/project-reviewer.md`. Reuse `run_claude_stage`
      so a timeout kills the whole process group.
   4. *Parse.* Extract the work summary from the final message with the same
      parser `agent-cycle.sh` uses. Recover the PR URL from the parsed
      `pr_url`, else by grepping the transcript, else from a
      `.git/agent-ops-review-pr-url` breadcrumb the agent writes the moment it
      opens the PR (the analogue of requirements 9 and 23), so a stranded
      attempt is still traceable.
   5. *Outcome.* On success (`status: "complete"` and a PR URL), log
      `review-pr-raised`. On any failure (timeout, non-zero exit, unparseable
      final message, or `status` other than `complete`): log
      `review-attempt-failed` with enough detail to diagnose, and — if a PR was
      already opened — comment on it that the agent abandoned it and why,
      leaving the PR and branch for the human.

R6. **Usage-limit detection.** After every `claude` invocation, run the shared
   detector (`lib/limit-detect.sh`). On a match, write a `limit-hit` event to
   the *shared* `log.jsonl` with the requirement-10 shape (`resume_at`,
   `class`, `needs_human`) and stop launching further repositories this run.
   This is a single-line, atomic `O_APPEND` write; it is safe even if the
   implementation pipeline (holding its own lock) appends concurrently, and it
   is the one signal both pipelines and the dashboard key their stand-down off.

R7. **Cleanup (always, via a trap).** Delete each cycle's clone, write a
   `review-end` event, release the review lock, and tee each stage's
   stdout/stderr to `state_dir/reviews/<review-id>/` for debugging. Optionally
   refresh the dashboard the same way `agent-cycle.sh` does (isolated and
   time-bounded, so it can never affect the run's outcome).

R8. **Flags.** `--dry-run` (evaluate the stand-down and skip-guard checks,
   print which repos *would* be reviewed, launch no agent), `--once` (one
   verbose run in the foreground), `--repo <slug>` (restrict to one repo, for
   testing). `--disable`, `--enable`, `--status` and `--for` are recognised
   only to reject them with a pointer to `agent-cycle.sh` (R2a) — an unknown-
   argument error would read as "this pipeline ignores the switch", which is
   the opposite of true.

### The Reviewer-Agent (`prompts/project-reviewer.md`)

R9. **One-shot constraint** (requirement 21). A single non-interactive
   `claude -p` invocation with no resumption: once it emits a final message
   with no further tool calls, it exits for good. It must wait synchronously
   for long-running commands (installs, builds, the project's own test suite)
   rather than ending its turn expecting a later notification. A command too
   slow to finish within `review.timeout_review` is grounds for
   `"status": "blocked"`, not a hopeful early end of turn.

R10. **Obey the repo.** Runs inside the clone. First reads the repo's
   `CLAUDE.md` and obeys it throughout (branch workflow, commit format,
   tech-debt Ledger, documentation-as-built rules, the `npm run check`
   whitespace gate, etc.).

R11. **Run the skill end-to-end.** Invoke the vendored `project-review` skill
   and follow it to completion: produce the `reviews/project-review-YYYY-MM-DD/`
   report set (index, summary, findings, recommendations, improvement prompts)
   and update `TECH-DEBT.md` **in place**. The injected skill under
   `.claude/skills/project-review/` is *tooling staged for this run*, **not**
   part of the repository under review: exclude it from the review's scope and
   findings, and never `git add` it (R5b also git-excludes it as a backstop).
   Complete the skill's own resumability book-keeping (delete `worknotes/` and
   `review-state.json`) so only the finished reports remain.

R12. **Tech-debt conventions.** When the review adds tech-debt items, follow
   the repo's Ledger workflow exactly — allocate IDs with
   `scripts/next-tech-debt-id.pl`, add each item's body under the
   `## Current Items` heading as a `### <id> <title>` section, add Ledger rows,
   and preserve the existing format — rather than inventing a competing
   structure. The skill updates the file in place; this requirement pins it to
   *this* repo's conventions.

R12a. **Cross-reference every mirrored recommendation.** Where a tech-debt
   item the review files — or a GitHub issue it opens — covers the whole of a
   recommendation's *Intended end state*, record that recommendation's `R-NN`
   against the item, somewhere a reader and a `grep` will find it from the
   register itself (the row, or a provenance table in the same file). Do it
   when the item is filed, not when it is resolved.

   This is not book-keeping. A recommendation and its mirrored register entry
   are two channels onto one piece of work, and the hourly implementation
   pipeline's Co-Ordinator can tell only by finding this cross-reference
   (`docs/BUILD-AUTONOMOUS-IMPLEMENTATION-PROMPT.md`, requirement 16). Absent
   it, that Co-Ordinator has one remaining test for whether a recommendation
   is done — a merged PR referencing it — which work that landed as a direct
   commit can never satisfy. The recommendation then reads as outstanding
   forever and is re-selected and re-investigated every cycle at full model
   cost. This is not hypothetical: it is exactly what `R-01` of
   `poetic`'s 2026-07-11 review did, nine times in two days, for a licence
   that had been committed before the review was even written.

   Record the mapping **only** where the item genuinely covers the
   recommendation's whole end state. A recommendation broader than the item
   mirroring it keeps its remainder in the review channel, where it stays
   visible; claiming it here would silently retire work nobody has done.

R13. **Raise one pull request.** Create the branch `review/<date>` from the
   default branch; commit the review folder and the updated `TECH-DEBT.md`;
   open **one** pull request, **ready for review** (not draft), labelled
   `review.pr_label`, with a Conventional-Commits title
   (`docs(review): weekly project review <date>` — it becomes the squash commit
   on `main`) and a body that summarises the verdict and links the review
   index. Record the PR URL to `.git/agent-ops-review-pr-url` immediately on
   opening it (the breadcrumb R5d relies on).

R14. **Prove it is landable.** Run the repo's own checks (as its `CLAUDE.md`
   and workflow files define — for a docs-only change this is chiefly the
   whitespace/format gates and commit-format) and fix anything they surface.
   Verify the PR via `gh pr view --json mergeable,mergeStateStatus` against
   GitHub's own view, and resolve any conflict with the current default branch.

R15. **Final message.** End with a single JSON object as the entire final
   message: `{"status": "complete", "pr_url": …, "branch": …, "repo": …, "notes": …}`
   or `{"status": "blocked", "reason": …}`.

### Logging and state

R16. **Streams.** Review *operational* events go to the review pipeline's own
   `state_dir/review-log.jsonl` (its own stream, so the dashboard's existing
   `log.jsonl` parser is untouched and the two pipelines stay separable). Reuse
   the `log_event` shape (requirement 33). Events: `review-start`,
   `review-skipped`, `review-stand-down`, `review-stage-start`,
   `review-stage-end`, `review-pr-raised`, `review-attempt-failed`,
   `review-end`, and `warning`. Common fields: ISO-8601 `ts`, a `review` id, an
   `event`, and where applicable `repo`, `pr_url`, `model`, `detail`. The one
   exception is the shared `limit-hit` event, which is written to `log.jsonl`
   (R6), because usage-limit stand-down is shared across both pipelines.

R17. The `review-log.jsonl` and the `state_dir/reviews/<review-id>/`
   transcripts are the durable record. Surfacing them in the monitoring
   dashboard is a worthwhile follow-on but is **out of scope** for this
   document (the dashboard has its own spec, `docs/BUILD-DASHBOARD-PROMPT.md`);
   note it there if you extend it.

## Deliverables

1. `review-cycle.sh` implementing R1–R8 and R16. `shellcheck`-clean; sets its
   own `PATH`.
2. `prompts/project-reviewer.md` implementing R9–R15. It must embed the
   relevant shared-repo conventions (as the other operating prompts do) so the
   stage never depends on context it was not given.
3. `.claude/skills/project-review/` — the vendored skill (already present;
   keep it pinned, and re-sync from upstream deliberately).
4. `config.json` — the added `review` block.
5. `README.md` — a "Weekly project review" section: what it does and why (the
   loop it closes), every `review.*` config key, how to install the cron entry,
   how to operate it (`--dry-run`, `--once`, `--repo`, reading
   `review-log.jsonl` and the transcripts), how the outputs feed the
   implementation pipeline / `project-remediation`, and how to uninstall.
6. The crontab line(s) (see Prerequisites).

## Acceptance checks (run all before finishing)

1. `shellcheck review-cycle.sh` is clean.
2. `--dry-run` completes against the real repos: the stand-down and skip-guard
   checks are evaluated, the Script prints which repos it *would* review,
   nothing further launches, and `review-log.jsonl` records the run.
3. A second invocation while the review lock is held exits without acting; and
   while the implementation `lock.json` is held by a live process, the Review
   Script stands down.
4. Skip-guard: with a `reviews/project-review-<today>/` folder present on a
   repo's default branch (or an open `project-review`-labelled PR for it), that
   repo is skipped, and the `min_days_between_reviews` boundary is respected.
4a. **The switch stands this pipeline down too (R2a).** With
   `agent-cycle.sh --disable 'testing'` set, a plain `review-cycle.sh` logs a
   `review-stand-down` carrying the reason, exits 0, and launches no `claude`;
   `--enable` restores it. Check this against the *review* script specifically
   and not by inference from `agent-cycle.sh` passing — a shared switch that
   only one pipeline reads is the whole failure mode R2a exists to prevent, and
   it looks identical to a working one until the week a review fires into a
   half-edited `lib/`.
5. **Injected-skill isolation:** after a real `--once --repo poetic` run, the
   review PR's diff contains the new `reviews/...` folder and the `TECH-DEBT.md`
   change but **not** `.claude/skills/project-review/` — confirm the injected
   skill is git-excluded and absent from the PR.
6. Usage-limit: an injected future `limit-hit` on `log.jsonl` stands the review
   down; and a simulated limit phrase in a transcript causes a `limit-hit` to
   be written to `log.jsonl`.
7. One supervised full run (`--once`): for each non-skipped repo it produces a
   labelled, ready, mergeable review PR, with `TECH-DEBT.md` updated per that
   repo's Ledger conventions and a clean `review-log.jsonl` trail. Report the PR
   URL(s) to the human; merge nothing.
8. **Cross-references land (R12a):** in that run's `TECH-DEBT.md` diff, every
   item mirroring a recommendation names its `R-NN`, and `grep -c 'R-[0-9]'`
   on the file is non-zero whenever the review mirrored anything. Check this
   explicitly: it is invisible in the review's own output — the reports look
   complete either way — and only shows up weeks later as the implementation
   pipeline paying to re-investigate recommendations that are already done.

## Prerequisites (human steps, before first run)

1. Create the review label in both repos:
   `gh api -X POST repos/Poetic-Poems/<repo>/labels -f name='project-review' -f color='5319e7' -f description='PR raised by the weekly project-review pipeline'`
   (for `poetic` and `poetic-fiddle`).
2. Install the cron entry. **Recommended — a daily tick guarded by
   `min_days_between_reviews`**, which is robust to a machine that sleeps:
   ```
   30 3 * * * $HOME/Code/Poetic-Poems/agent-ops/review-cycle.sh >> $HOME/.local/state/poetic-agents/review-cron.log 2>&1
   ```
   The skip-guard (R4) ensures this actually reviews each repo only about once a
   week. *Strict weekly alternative* (simpler, but a missed Monday tick skips
   the whole week): `30 3 * * 1 …` (Mondays 03:30). Schedule it at a different
   minute from the hourly implementation cycle to avoid both firing at once
   (the review defers to a running cycle anyway, per R3).
3. The shared prerequisites of `docs/BUILD-AUTONOMOUS-IMPLEMENTATION-PROMPT.md` (the standalone `claude`
   CLI, cron enabled under WSL, `gh` authenticated with push access) are
   already satisfied by the implementation pipeline; nothing further is needed.

## Cost profile

One deep review per repo per week: a Sonnet lead driving the skill, which
itself delegates to lower-cost subagents. Bounded by `review.timeout_review`.
The skip-guard caps it at one review per repo per `min_days_between_reviews`, so
a daily cron tick does not multiply cost. Deferring to the implementation lock
keeps the two pipelines from doubling up on quota at the same moment. The Script
itself makes no model calls.

## Design decisions

Recorded so a future reader knows they were deliberate.

- **A separate pipeline, not a new stage of `agent-cycle.sh`.** A review is
  weekly, long, and whole-repo; the implementation cycle is hourly, short, and
  single-item. Bolting the review onto the cycle would either starve the cycle
  (a review holding the shared lock for hours) or complicate its per-stage
  timeouts. A sibling Script with its own lock, label, and cron keeps each
  simple — while a single shared `limit-hit` signal and a one-way deference
  (review yields to a running cycle) keep them from fighting over quota.
- **The skill is vendored into the orchestrator and injected into the clone**,
  not committed into the product repos. Reproducible (pinned, in this repo's
  version control, not the machine's symlinked global skill), keeps the product
  repos clean, keeps the review out of its own scope, and needs no pull request
  into two protected product repositories to switch the pipeline on.
- **The review PR is raised ready, not draft.** The review is the deliverable;
  there is no correctness pass to add (unlike the Implementor→Reviewer
  hand-off), so a second agent stage would only add cost. The human gate is the
  merge.
- **"Once a week" is implemented as a daily tick plus a skip-guard**, because a
  strict weekly cron on a machine that sleeps can miss its one tick and lose a
  whole week. The guard also makes re-runs idempotent.
- **The outputs feed the existing pipelines by design.** The review updates the
  same `TECH-DEBT.md` the hourly Co-Ordinator already reads and writes the
  improvement prompts the `project-remediation` skill consumes — so the review
  is the front of an existing loop, not a parallel dead-end.
- **`min_days_between_reviews` is 6, not 7**, so a review that lands a day late
  one week is not deferred a full extra week the next.

No open questions remain; the shared platform, models, permissions, and system
location were confirmed with the repo owner for the implementation pipeline and
carry over unchanged.
