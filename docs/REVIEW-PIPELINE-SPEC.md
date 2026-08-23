# Repository-Review Pipeline — as-built specification

## About this document

This is the as-built requirements specification for the repository-review
pipeline — named for what each run does: one repository, on its own, with
its own clone, branch, report set and pull request. It is a companion to
`docs/IMPLEMENTATION-PIPELINE-SPEC.md` (the implementation pipeline)
and `docs/DASHBOARD-SPEC.md` (the monitoring dashboard), and like them it
describes the system as it exists — any change to this pipeline lands
together with the edit that keeps this document accurate (see `CLAUDE.md`,
"As-built specifications").

**Where this document is silent, follow `docs/IMPLEMENTATION-PIPELINE-SPEC.md`.** The two
pipelines deliberately share their machinery — the lock discipline, the
minimal-`PATH` bootstrap for cron, usage-limit detection (`lib/limit-detect.sh`),
the JSON-Lines log format and `log_event` helper, the ephemeral-clone rule,
the stage launcher with its per-stage timeout, process-group kill and event
stream (`lib/stage-run.sh`'s `run_claude_stage`), and the
"straight-parse-else-last-fenced-```json```-block" result parser. This
pipeline **reuses** those, and must not reinvent them. References of the form
"requirement N" mean requirement N of `docs/IMPLEMENTATION-PIPELINE-SPEC.md`. The target
repositories' `CLAUDE.md` files remain binding on any agent working inside
them.

## What it is

A second, independent pipeline that runs alongside the implementation
pipeline, on its own configured cadence
(`project_review.defaults.min_days_between_reviews`). For each run it takes
one target repository and produces a full project review — via the vendored
`project-review` skill — against a fresh ephemeral clone, and leaves **one**
mergeable pull request carrying the review reports and an updated tech-debt
register. A human merges it. The review's new tech-debt entries and
improvement prompts then feed the implementation pipeline (and/or the
`project-remediation` skill). The only human involvement is merging the
review pull request.

```
cron (project_review.defaults.min_days_between_reviews; a daily tick with a
       skip-guard is recommended — see R4)
  └─ review-cycle.sh                  ← the Review Script: lock, stand-down, per-repo skip-guard
       └─ for each target repo, sequentially:
            ├─ ephemeral clone            ← fresh from GitHub, under workspace_root
            ├─ inject the vendored skill  ← into the clone, git-excluded (never committed)
            └─ Reviewer-Agent (Sonnet)    ← runs the skill, raises ONE review PR (ready)
                  └─ Human                ← reviews and merges (the only gate)
                        └─ feeds → implementation pipeline / project-remediation
```

## Relationship to the existing pipelines

- **Separate everything that must be separate:** its own Script
  (`review-cycle.sh`), its own cron entry, its own lock (`review-lock.json`),
  its own PR label (`project-review`). **Shared where sharing is correct:**
  `config.json`, `state_dir`, `workspace_root`, `lib/limit-detect.sh`,
  `lib/git-identity.sh`, the ephemeral-clone discipline, the `PATH`
  bootstrap, and the result parser.
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

## Actors

1. The **Review Cronjob** — the crontab entry that fires the Review Script.
2. The **Review Script** (`review-cycle.sh`) — a bash script that orchestrates
   one run across the target repositories, on its own configured cadence
   (`project_review.defaults.min_days_between_reviews`). It launches the
   Reviewer-Agent; agents never launch the Script.
3. The **Reviewer-Agent** — a headless Claude Code invocation that runs the
   `project-review` skill against one ephemeral clone and raises one review
   pull request. One invocation per repository. It writes no comments today, so
   it stamps none of `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s requirement 9d
   headers itself; `dashboard/index.html`'s `ACTOR` map and
   `lib/pipeline-marker.sh`'s `pipeline_actor_label` both carry an entry for it
   anyway, under the token `project-reviewer` and the display name **Project
   Reviewer** — the name this document's own Actor entry differs from, kept
   here as *Reviewer-Agent* since that is what the rest of this document calls
   it throughout.
4. The **Human Reviewer** — merges the review pull request through the ordinary
   GitHub process, and decides how to action its recommendations. Not launched
   by any part of this system.

## Environment

Identical to `docs/IMPLEMENTATION-PIPELINE-SPEC.md` ("Environment" and "Target
repositories"); not repeated here. The two target repositories are the same
`Poetic-Poems/poetic` and `Poetic-Poems/poetic-fiddle`, and their shared
conventions (protected `main`, squash-merge so the PR title becomes the commit,
Conventional Commits, the per-item tech-debt register (`tech-debt/`, with
`scripts/reserve-tech-debt-id.pl` allocating new IDs) bind the Reviewer-Agent
exactly as they bind the Implementer.

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

One `project_review` object in the existing `config.json` (one config file —
never a second one) holds every tunable for this pipeline, in two parts
(requirement 342): `defaults` — every tunable set once, installation-wide —
and `repos` — the repositories to review, each a `{"slug": "owner/name"}`
entry that may additionally carry any of `defaults`' own keys to override it
for that repository alone. The resolution rule is uniform: for repository *r*
and key *k*, the effective value is `repos[i][k]` when that key is present and
non-null on *r*'s own entry, and `defaults[k]` otherwise; an entry carrying
only `slug` inherits every default. `lock_stale_after` sits outside `defaults`
— it bounds the shared review lock, which covers whichever repositories a run
touches, not any one repository, so it has no per-repo override. The values
below are the confirmed defaults; the README documents each key, and
`config.schema.json` carries them alongside the implementation pipeline's
(`docs/IMPLEMENTATION-PIPELINE-SPEC.md` requirement 1b) — one file, one
schema, so `scripts/doctor.sh` checks both pipelines' configuration in one
pass and neither half can drift while the other is checked. The object as a
whole is optional there: an installation that does not run reviews simply
leaves it out. `review-cycle.sh` therefore tests for the block against
`config.json` itself rather than against the merge `config_defaults` returns
(`docs/IMPLEMENTATION-PIPELINE-SPEC.md` requirement 1b): that merge
synthesises a `project_review` object from the defaults of the leaves under
it, so it can never report the block absent, and this one check must read
absence as absence. Every key *within* the block is read from the merge as
everywhere else.

The body rows of the table below are generated from that schema — each key's
`x-docs.spec` prose and `x-docs.value` cell — by
`scripts/render-config-table.sh` (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`
component 16), between the `config-table` markers, and CI fails a pull
request that leaves them stale. Edit the schema, not the rows. A Notes cell
over 500 characters is capped, with its full text deferred to this document's
`config-table:notes id=review` region below the table; `not_before`'s note is
the one long enough for that today.

```json
"project_review": {
  "defaults": {
    "model": "claude-sonnet-5",
    "pr_label": "project-review",
    "branch_prefix": "review/",
    "min_days_between_reviews": 6,
    "not_before": "2026-07-30T16:00:00Z"
  },
  "repos": [
    { "slug": "Poetic-Poems/poetic" },
    { "slug": "Poetic-Poems/poetic-fiddle" }
  ]
}
```

<!-- config-table:start id=review — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not these rows -->
| Key | Value | Notes |
|---|---|---|
| `project_review.lock_stale_after` | *(unset)* | A floor under the derived value, on the same terms as the implementation pipeline's `lock_stale_after` (requirement 4f). The derivation multiplies the widest Reviewer-Agent backstop by the number of repositories configured for review (floored at one, so a single-repository installation is unaffected), because one lock can span all of them reviewed back to back, and adds the same slack. |
| `project_review.defaults.model` | `claude-sonnet-5` | The Reviewer-Agent's model — the lead that drives the skill. The skill itself delegates well-scoped sub-tasks to lower-cost subagents, so this is the only model to pin here. A deeper review can be dialled up to a higher-capability model without other changes. |
| `project_review.defaults.pr_label` | `project-review` | Applied to every review PR. **Distinct** from the implementation pipeline's `autonomous-agent`, so review PRs never count against `max_open_agent_prs` and are trivially filterable. It must not be `obsolete`, for the reason given against the implementation `pr_label`. |
| `project_review.defaults.branch_prefix` | `review/` | Branch name `review/<date>`, e.g. `review/2026-07-20`. A branch is already scoped to its repository, so no slug is needed. |
| `project_review.defaults.timeout_review` | *(unset)* | An override for the Reviewer-Agent's backstop, on the same terms as `timeout_coordinator` and through the same derivation (requirement 4f). Absent is the normal case. |
| `project_review.defaults.inactivity_review` | *(unset)* | An override for the watchdog threshold of requirement 4e, taking precedence over the derivation of requirement 4f. Absent is the normal case; `0` disables the watchdog and leaves the backstop as the only cap. |
| `project_review.defaults.min_days_between_reviews` | `6` | The skip-guard threshold (R4). A repo reviewed within this many days is skipped. Six (not seven) leaves a day of slack, so a review that lands late one week is not pushed a full extra week the next. |
| `project_review.defaults.not_before` | *(unset)* | Optional. A timestamp before which no review may start (R3.3). Absent or empty means no stand-down; a value `date -d` cannot read stands the pipeline down rather than running through it. Expires by itself, which is why it exists rather than raising `min_days_between_reviews`: a threshold has to be put back by hand, and a cadence left quietly throttled is not noticed for weeks. As `defaults.not_before` it gates the whole cycle before the lock, exactly as a single...[continued below](#extended-notes-project_reviewdefaultsnot_before) |
| `project_review.repos` | `[{"slug": "Poetic-Poems/poetic"}, {"slug": "Poetic-Poems/poetic-fiddle"}]` | The repositories to review. Each entry's `slug` is required; every other key overrides the same-named key in `defaults` for that repository alone (requirement 342), and an entry carrying only `slug` inherits every default. A review has no per-repo work-source structure beyond these overrides. Adding a repo is a config-only change. |
<!-- config-table:end -->

Model IDs are pinned in config (one place to update); do not use floating
aliases in the launch command.

`project_review.defaults.model` (or a repository's own override in
`project_review.repos`, requirement 342) accepts a bare id
(`claude-sonnet-5`) or a provider-qualified one (`anthropic/claude-sonnet-5`),
resolved by the same `resolve_model_id` (`lib/model-id.sh`) the implementation
pipeline uses — see
`docs/IMPLEMENTATION-PIPELINE-SPEC.md` requirement 1a. Anthropic is the only
executable provider (D12, `docs/ROADMAP.md`); a qualifier naming any other
provider is a fail-fast config error at cycle start, not a value passed to
`claude --model`.

<!-- config-table:notes id=review — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not this section -->

### Extended notes: `project_review.defaults.not_before`

Optional. A timestamp before which no review may start (R3.3). Absent or empty means no stand-down; a value `date -d` cannot read stands the pipeline down rather than running through it. Expires by itself, which is why it exists rather than raising `min_days_between_reviews`: a threshold has to be put back by hand, and a cadence left quietly throttled is not noticed for weeks. As `defaults.not_before` it gates the whole cycle before the lock, exactly as a single installation-wide value always has; a repository's own override on `repos[]` is resolved separately, per repository, once the cycle is under way (requirement 3.3).

<!-- config-table:notes-end -->

## The Landing Gate and the loop it closes

The review pipeline raises **one pull request per repository, ready for
review** (not draft — the review *is* the deliverable, and there is no second
review stage to flip it). The PR is labelled with the repository's own
resolved `project_review` pr_label (its override, or
`project_review.defaults.pr_label`, requirement 342), titled in
Conventional Commits form (e.g. `docs(review): repository review 2026-07-20`),
and its body summarises the verdict and links the review index. A human
approves and merges it, at every `merge_autonomy` level: `review-cycle.sh`
engages no Approver stage, so the implementation pipeline's trust ladder
(`docs/IMPLEMENTATION-PIPELINE-SPEC.md` §The Landing Gate) does not yet
reach review pull requests, however the installation has configured it.
Review PRs join that ladder when an Approver is wired into this pipeline —
work no item covers yet, named here so the gap is a stated one rather than
a silent one.

The point of the pipeline is the *loop*, not the report. When a review PR
merges, its updated tech-debt register and its `04-improvement-prompts.md`
land on `main`, where:

- the **implementation pipeline's** Co-Ordinator picks up the new
  tech-debt items on its next cycle (its `tech-debt` work source reads
  exactly that register); and/or
- the human runs the **`project-remediation`** skill (the review's
  counterpart) to work down the recommendations deliberately.

So the review is the *front* of a loop that ends in merged improvements,
each landed through whatever gate its repository's `merge_autonomy` level
sets — the human's own, at the default — never a dead-end document.

## Requirements

### The Review Script (`review-cycle.sh`)

R1. **Bootstrap.** Reuse the `PATH` bootstrap and binary checks of
   `agent-cycle.sh` verbatim (claude, gh, git, jq must resolve under cron's
   minimal environment). Source `lib/limit-detect.sh`. The script must pass
   `shellcheck`.

R1a. **Model id resolution (D12 groundwork).** Every configured repository's
   own resolved model (`project_review.defaults.model`, or its own override in
   `project_review.repos`, requirement 342) is resolved through
   `lib/model-id.sh`'s `resolve_model_id` immediately after `project_review`'s
   settings are read and resolved, before the lock — the same helper and the
   same rule `agent-cycle.sh` applies to its own model keys
   (`docs/IMPLEMENTATION-PIPELINE-SPEC.md` requirement 1a): a bare id means
   `anthropic/`, an `anthropic/`-qualified id has the qualifier stripped, and
   any other qualifier is a fail-fast config error naming the precise key the
   value came from — `project_review.repos[i].model` for a repository's own
   override, `project_review.defaults.model` when it does not have one — never
   the generic `project_review.model`, so the error points at the exact key to
   fix (`lib/config-schema.sh`'s `config_project_review_repos` resolves each
   repository's `model_key` alongside its `model` for this). Every configured
   repository's model is validated in this one sweep, before any repository is
   worked, so a bad model on one repository is never discovered only after
   others have already been reviewed.

R1b. **Duplicate-slug refusal.** Requirement 342's resolution rule assumes
   exactly one `project_review.repos` entry per repository; two entries naming
   the same `slug` leave no way to say which one's overrides apply. Checked
   immediately after `project_review_repos_json` is resolved, before the model
   sweep above: `lib/config-schema.sh`'s `config_duplicate_project_review_slugs`
   — a third cross-key rule the schema itself cannot state, alongside
   `agent-cycle.sh`'s own two (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`
   requirement 1b) — names every slug appearing more than once, and the Script
   refuses to start naming them, exactly as `scripts/doctor.sh`'s own `fail`
   does against the same function, so the two can never drift on what counts
   as a fault. An empty `project_review.repos` has nothing to duplicate and is
   not a fault.

R2. **Lock.** Acquire `review-lock.json` in `state_dir` recording PID, start
   time, and the writer's hostname (`host`, as the implementation pipeline's
   requirement 1 records it; its own lock, *not* the implementation
   `lock.json`). Apply the same held/stale/dead logic as requirement 1, using
   `project_review.lock_stale_after`: skip cleanly if a live review is younger
   than the threshold; take over a stale or dead lock — TERM, a polled grace of
   up to 20 seconds so the holder's own signal handler (R7a) can write its
   record and release its claim, then KILL — logging a `warning`. Installation-
   wide only, not per repository — the lock covers whichever repositories a
   run touches, so its derivation takes the widest `timeout_review` /
   `inactivity_review` configured across all of them (defaults or any repo's
   own override), not any one repository's own. The lock has a second reader
   on a containerised node:
   `deploy/docker/watchtower-pre-update.sh` consults it, on the same
   `project_review.lock_stale_after` bound, to defer an image roll that would
   otherwise kill a review mid-flight — judging liveness only when the lock's
   `host` is its own container, and honouring a lock written elsewhere until
   released or stale, since a pid means nothing outside the PID namespace
   that minted it (see the node stack section of
   `docs/IMPLEMENTATION-PIPELINE-SPEC.md`). A review is protected exactly as
   long as it would keep the lock against another review.

R3. **Stand-down checks.** Each logs its reason and exits 0:
   1. *Usage-limit cooldown* — identical to requirement 2.1: the log
      union's most recent `limit-hit` and the live `fleet/limit.json` flag
      are both read, and the **later** `resume_at` wins; if it is still in
      the future, stand down. When *this* pipeline hits a limit it writes
      the same two carriers the implementation cycle does — the `limit-hit`
      event to the shared `log.jsonl`, and the fleet flag, extend-only,
      best-effort (a `warning` is logged when the flag write fails and the
      union carries the signal instead).
   2. *Implementation pipeline busy* — if `lock.json` is held by a live
      process, stand down and wait for the next tick (defer to it, per
      "Relationship to the existing pipelines").
   3. *A dated stand-down, tier one* — if `project_review.defaults.not_before`
      is set and now is before it, stand down the whole cycle, logging the
      timestamp on the event so an operator can tell this apart from a
      switch. Checked before the lock, like R2a, so a review that must not
      start never takes a lock a roll would then defer for. This is the
      installation-wide value only: a repository's own `not_before` override
      (requirement 342) is resolved separately, per repository, into R4's
      skip-guard below, once the cycle is under way — an override can hold
      one repository off *longer* than this value, but cannot escape it
      while it is in force. This exists because R2a's switch is deliberately
      **shared** with the implementation pipeline: holding the review pipeline
      off until a date while cycles carry on is a thing the switch cannot
      say. A value `date -d` cannot parse stands the pipeline down rather
      than running through it — the operator evidently meant to hold
      reviews off, and guessing otherwise spends whatever they were
      protecting. Absent or empty is not a stand-down. Preferred over
      raising `min_days_between_reviews` because it expires by itself: a
      threshold has to be put back by hand, and one left raised throttles
      every repo indefinitely without anyone noticing.
   4. *A dated stand-down, tier two* — checked immediately after tier one,
      also before the lock: even where `project_review.defaults.not_before`
      itself does not trip tier one — absent, or already past — the whole
      cycle still stands down when *every* configured repository's own
      resolved `not_before` (its override, or the inherited default,
      already resolved into `project_review_repos_json`) is future or
      unparseable. This is the case tier one alone misses: a
      `project_review.defaults.not_before` left unset while every
      repository overrides its own, which tier one — reading only the
      installation-wide key — would let straight through to the lock, for a
      cycle certain to have R4's skip-guard skip every repository anyway.
      Vacuously false, not true, on an empty `project_review.repos`: nothing
      configured means nothing this tier could ever hold back, not that
      everything is held.

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
   `lib/limit-detect.sh` would have left the review pipeline free to fire into
   a half-written file.

   This pipeline **honours the switch but never sets it**: `agent-cycle.sh
   --disable/--enable/--status` is the single entry point, so there is one
   writer and one record. Reject those flags here with a pointer rather than
   implementing a second way to write the same file. Leave an *expired* switch
   for `agent-cycle.sh` to clear and log, too: this pipeline runs on its own
   configured cadence (`project_review.defaults.min_days_between_reviews`), so
   letting it clear one would mean the `enabled` event explaining why cycles
   resumed could land days after they did.

   The **fleet switch** (`fleet/disabled.json`; implementation spec 2.3a) is
   honoured on exactly the same terms, checked right after the local one:
   stand down while it is set, never write it, never clear it — not even
   expired, for the same days-late-`enabled` reason.

R2b. **The role guard.** Before the switch, the config and the lock, stand the
   run down unless `AGENT_OPS_ROLE` is `active` — the implementation pipeline's
   requirement 2.4, through the same shared `lib/role.sh`, so "active" has one
   definition and a node cannot be standby for one pipeline and active for the
   other. Unset, empty or any other value is a standby: it writes one line to
   stdout (which cron redirects into `review-cron.log`) and exits 0, leaving
   nothing in `state_dir` — not even a `review-start` event. `--dry-run` and
   `--once` bypass it, as they do there.

   The ordering matters and is deliberate: the guard comes first because a
   standby node has no business reading, logging or clearing state that belongs
   to the active one.

R2c. **The fleet's memory and state publication.** After the lock and before
   any work, snapshot the fleet's shared event stream — this node's
   `log.jsonl` unioned with every peer's, via `lib/fleet.sh`
   (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`, requirement 2.5) — so the
   usage-limit checks below see a limit *any* node hit; the union is
   re-snapshotted between repos. There is no lease: per-item claims
   (requirement 17a of the implementation spec) arbitrate work.

   Before the lock, reap `workspace_root` on the terms of the implementation
   spec's requirement 6b: this pipeline clones into the same directory and
   loses its clones to a kill in exactly the same way. Its window is its own
   — the review lock is derived from the Reviewer's budget times the
   repository count, so it is wider than a cycle's — and both are floored at
   24 hours, which is why whichever pipeline runs first cannot reap a
   workspace the other is still working in. A `workspaces-reaped` event is
   written only when something was reclaimed. At the
   end of the run — from the cleanup that releases the lock, once the review
   is fully recorded — publish this node's `state_dir` to its own
   `nodes/<NODE_NAME>` branch with `scripts/state-sync.sh push`,
   unconditionally: no other node's push can collide with it.

   The review needs this for the same reason the implementation cycle does: it
   spends, and two nodes reviewing the same repositories would open competing
   review pull requests. R4's skip-guard would not save them — two nodes
   starting within the same minute both see no open review PR. The
   review-branch claim (R5.0) is what closes that window: the second node
   loses the create-ref and skips the repo before cloning anything.

R4. **Per-repo skip-guard (idempotency; this is how "once a week" is
   enforced).** For each configured repo, skip it *this run* when **any** of:
   - its own resolved `not_before` (its override, or
     `project_review.defaults.not_before`, requirement 342) is set and now is
     before it — the same rule R3's cycle-wide check applies, checked again
     here per repository so a repository's own override can hold it off
     *longer* than the installation-wide value; **or**
   - an open pull request labelled with its own resolved `project_review`
     pr_label already exists for it (a review is in-flight or awaiting
     merge); **or**
   - its default branch already contains a `reviews/project-review-YYYY-MM-DD/`
     folder dated within the last `min_days_between_reviews` days (its own
     resolved value) (read best-effort via `gh`, e.g. the contents of
     `reviews/` on the default branch).

   Log `review-skipped` with the reason. This guard is what makes a **daily**
   cron tick safe and preferable to a strict weekly one: the Script only
   actually reviews a repo when at least `min_days_between_reviews` days have
   passed, so a tick missed because the machine was asleep simply catches up on
   the next day instead of losing a whole week (compare requirement note that
   "a missed cycle simply waits for the next tick").

R5. **Per non-skipped repo** (processed **sequentially**, so a failure of one
   never blocks the other and only one heavy `claude` runs at a time):
   0. *Claim the review branch* (R5c; implementation spec requirement 17a).
      `review/<review_date>` is a date-only name: every active node computes
      the same one on the same day, and without a lock the loser discovers
      the collision only after spending a full model review — at push time.
      Before anything expensive, claim the branch through `lib/claim.sh`
      (`claim branch <slug> review/<date> <default_branch>`): one create-ref,
      which GitHub 422s for the second caller even at the same SHA, plus the
      registry entry that back-pressure, the dashboard and gc read
      (`CLAIM_SOURCE=project-review`). A lost claim logs `review-skipped`
      ("already claimed by another node"); a claim *error* also skips the
      repo, fail closed — a node that cannot reach GitHub to claim could not
      have pushed a review either. Releases mirror the implementation
      pipeline's hooks: a failed clone or failed reviewer releases fully
      (`release branch` — the ref is deleted only if it is unmoved **and**
      no open PR uses it, so a review the model pushed before dying
      survives, as does an abandoned-but-open PR); a raised PR releases the
      registry entry only (`release file` — the PR supersedes the claim and
      the branch is its head). `--dry-run` exits before any claim.
   0a. *Git identity.* Immediately after the claim succeeds — the first point
      in this repo's run that could actually commit — require
      `GIT_USER_NAME`/`GIT_USER_EMAIL` via the shared `lib/git-identity.sh`
      (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`, "The node image"): both are
      required, with no default, and their absence exits non-zero with an
      actionable message rather than falling back to any identity. The claim's
      own lost/error skips, and every stand-down before it, commit nothing and
      are never gated on this.
   0b. *Labels.* At the same point, and for the same reason it is that point —
      this repo is now certainly going to be worked — ensure its own resolved
      `project_review` pr_label exists in it, creating it only if absent, via
      `labels_ensure_role` (`lib/labels.sh`), unconditionally and unstamped:
      the same shape `docs/IMPLEMENTATION-PIPELINE-SPEC.md` requirement 6a
      uses for its own selected repository, immediately before the stage that
      needs the label to exist, rather than the rate-limited
      `labels_ensure_stamped` requirement 6a's per-gathered-repository ensure
      uses. A repository is selected for review at most once per
      `min_days_between_reviews` days (R4), longer in every shipped
      configuration than `labels_ensure_interval_hours` (default 24h), so a
      stamp here would always have gone stale between one review of a
      repository and the next — costing the same listing a stamp would have
      saved, while leaving open the gap a shorter `min_days_between_reviews`
      or a longer `labels_ensure_interval_hours` would create: a `pr_label`
      deleted after a stamp was written going unnoticed until `gh pr create
      --label` fails the create outright, discarding a review that cost up to
      `timeout_review` minutes. Never fatal: a repository whose labels cannot
      be listed, or a token that may not create them, logs `labels-ensured`
      with what failed and the review proceeds.
   1. *Workspace.* Create `workspace_root/<review-id>-<repo-slug-safe>/` and
      clone the repo fresh from GitHub — the multi-agent ways-of-working rule
      shared by all Poetic repositories: every agent works in its own
      dedicated fresh clone taken from the tip of the default branch before
      commencing any changes. (A full clone — the review examines git
      history.) The clone goes through `lib/repo-clone.sh`'s `clone_repo`, the
      same function the implementation pipeline's requirement 6 uses: `git
      clone`, because `gh repo clone` resolves the repository through a
      GraphQL query that is billed against the API budget, and git's own
      transport is not rate-limited. `gh auth setup-git` in
      `deploy/docker/entrypoint.sh` authenticates the HTTPS remote, and
      `CLONE_GIT` substitutes a stub for tests, and anything already at the
      target path is discarded rather than inspected (requirement 6). Assert
      the working
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
   3. *Reviewer-Agent stage.* Launch the Reviewer-Agent headless (this
      repository's own resolved model, `--dangerously-skip-permissions`,
      timeout from its own resolved `timeout_review`), with the clone as the working
      directory, passing `prompts/project-reviewer.md`. Use `run_claude_stage`
      (R7b) so a timeout kills the whole process group, the invocation
      streams its events to `<stage>.stream.jsonl` as it runs, and its final
      `result` envelope lands in `<stage>.out` for the parse below. The
      prompt reaches the stage
      on stdin, never as a command-line argument, for the reason
      `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s requirement 4c gives: a single
      argv entry is capped at 131072 bytes, and a prompt is the one input here
      that grows without bound. This pipeline's prompt has room to spare today,
      which is precisely why the launcher is shared rather than copied — the
      smaller prompt is the one that would sit broken longest before anyone
      noticed.
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
      leaving the PR and branch for the human. That comment opens with
      `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s requirement 9d header,
      `**Review Script** · autonomous pipeline · node \`<node>\``, and carries
      that same requirement's invisible marker, stamped `actor=review-script`
      — harmless here, since `gather-abandoned-drafts.sh` never sees a review
      PR's `project-review` label or `review/` branch prefix, but it keeps the
      write side of the marker to the one definition in
      `lib/pipeline-marker.sh` that requirement's component describes.

R6. **Usage-limit detection.** After every `claude` invocation, run the shared
   detector (`lib/limit-detect.sh`). On a match, write a `limit-hit` event to
   the *shared* `log.jsonl` with the requirement-10 shape (`resume_at`,
   `class`, `reset_known`) and stop launching further repositories this run.
   This is a single-line, atomic `O_APPEND` write; it is safe even if the
   implementation pipeline (holding its own lock) appends concurrently, and it
   is the one signal both pipelines and the dashboard key their stand-down off.
   Both of this pipeline's stand-down checks read that signal through the same
   shared reduction, so `agent-cycle.sh --clear-limit` lifts the review cycle
   too — one account, one limit, one way to clear it.

R7. **Cleanup (always, via a trap).** Delete each cycle's clone, write a
   `review-end` event, release the review lock, and tee each stage's
   stdout/stderr to `state_dir/reviews/<review-id>/` for debugging. Optionally
   refresh the dashboard the same way `agent-cycle.sh` does (isolated and
   time-bounded, so it can never affect the run's outcome).

R7a. **A signal is a failure with a record.** The Script traps `TERM`, `INT`
   and `HUP` from the moment its cleanup trap is armed, with the same
   handler discipline — and for the same reasons, set out at length there —
   as the implementation pipeline's requirement 9c: kill the in-flight
   stage's own process group (which no signal to the Script's group ever
   reaches), log `review-attempt-failed` naming the repo under review and
   the stage in flight with detail `<stage> terminated by SIG<name>`,
   release the review claim time-bounded (`no-pr` is safe even when the
   model had already raised its PR — lib/claim.sh keeps a ref that has
   moved or that an open PR uses), and exit `128+n` through `exit`, so R7's
   trap still writes `review-end` with a truthful code and releases the
   lock. A signal landing during cleanup itself must not re-enter the
   handler. Covered by the same `test/signal-exit.test.sh` as the
   implementation pipeline's acceptance check 4a.

R7b. **One stage launcher, shared.** `run_claude_stage` is sourced from
   `lib/stage-run.sh`, the implementation pipeline's requirement 4d — it is
   not a copy of it. The two scripts each held their own until the streaming
   change of #203 had to be made twice; both specs already said the copies
   must not diverge, and a shared file is the only form of that promise a
   reviewer does not have to check by eye. Everything requirement 4d states
   holds here unchanged: the process group, the wall-clock cap, the
   `<stage>.stream.jsonl` written as the run proceeds, and the final `result`
   event truncated into `<stage>.out` for R5.3's parse. The streams are
   local-only here too — `reviews/` replicates without them, and
   `state_local_streams_retained` bounds what stays on the node.
   Requirement 4e's liveness watchdog comes with it: this repository's own
   resolved `inactivity_review` minutes of total silence stops the
   Reviewer-Agent, its own resolved `timeout_review`
   remains the backstop above it, and `review-stage-end` carries the
   `kill_reason` that tells the two apart. Absent, the shipped prior applies;
   `0` disables the watchdog and leaves the backstop as the only cap. This
   pipeline's stage is the long one — a whole project review — which is
   precisely why the distinction matters here: a review that is merely slow
   must not be killed, and one that has stopped should not hold a node for two
   hours. The same requirement's third stop applies too: a stream reporting
   the account refused stops the Reviewer-Agent at once, and
   `detect_and_log_limit_hit` derives the stand-down from the runner's own
   record rather than from prose the stopped stage never wrote.
   Both caps are *derived* rather than configured, by requirement 4f and
   through the same `lib/stage-budget.sh` the implementation pipeline uses:
   the Reviewer-Agent is the cell `(project-reviewer, <repo>, <model>)`, and
   a repository's own resolved `timeout_review` / `inactivity_review` (its
   override, or `project_review.defaults`') are overrides that win when
   present. `review-stage-start` announces what this run was given and where
   each number came from. `project_review.lock_stale_after` becomes a floor
   under a derived threshold, which takes the *widest* `timeout_review` /
   `inactivity_review` configured across every repository this run might
   touch — not any one repository's own — and multiplies it by the number of
   repositories configured for review (floored at one, so a single-repository
   installation is unaffected), because one lock can span all of them
   reviewed back to back.

R8. **Flags.** `--dry-run` (evaluate the stand-down and skip-guard checks,
   print which repos *would* be reviewed, launch no agent), `--once` (one
   verbose run in the foreground), `--repo <slug>` (restrict to one repo, for
   testing). `--disable`, `--enable`, `--status`, `--for` and `--until` are
   recognised only to reject them with a pointer to `agent-cycle.sh` (R2a) —
   an unknown-argument error would read as "this pipeline ignores the
   switch", which is the opposite of true.

### The Reviewer-Agent (`prompts/project-reviewer.md`)

R9. **One-shot constraint** (requirement 21). A single non-interactive
   `claude -p` invocation with no resumption: once it emits a final message
   with no further tool calls, it exits for good. It must wait synchronously
   for long-running commands (installs, builds, the project's own test suite)
   rather than ending its turn expecting a later notification. A command too
   slow to finish within this repository's own resolved `timeout_review` is
   grounds for `"status": "blocked"`, not a hopeful early end of turn.

R10. **Obey the repo.** Runs inside the clone. First reads the repo's
   `CLAUDE.md` and obeys it throughout (branch workflow, commit format,
   tech-debt register conventions, documentation-as-built rules, the
   `npm run check` whitespace gate, etc.).

R11. **Run the skill end-to-end.** Invoke the vendored `project-review` skill
   and follow it to completion: produce the `reviews/project-review-YYYY-MM-DD/`
   report set (index, summary, findings, recommendations, improvement prompts)
   and update the tech-debt register **in place**. The injected skill under
   `.claude/skills/project-review/` is *tooling staged for this run*, **not**
   part of the repository under review: exclude it from the review's scope and
   findings, and never `git add` it (R5b also git-excludes it as a backstop).
   Complete the skill's own resumability book-keeping (delete `worknotes/` and
   `review-state.json`) so only the finished reports remain.

R12. **Tech-debt conventions.** The review's own filing does not fit the
   register's single-item shape — one `td/<id>` branch that is both the
   reservation and the filing branch — because R13 requires every item the
   review surfaces to land in **one** pull request rather than one per item.
   So reservation and filing are two separate steps: reserve one ID per item
   atomically with `scripts/reserve-tech-debt-id.pl` (the "Filing an item"
   workflow's reservation step, built on `scripts/next-tech-debt-id.pl`'s
   scan), but never check out or commit to the `td/<id>` branch it creates —
   that branch is the reservation, standing only as a lock against a
   concurrent filing minting the same ID. Instead add each record as a new
   `tech-debt/<id>.md` item file (frontmatter plus a Markdown body) on the
   review's own branch (R13), preserving the existing per-item conventions
   rather than inventing a competing structure. A reservation's `td/<id>`
   branch stands until R13's pull request merges; nothing deletes it
   automatically, so R13's pull request body is where that deletion is
   handed to the human who merges it. Mark items the review finds already
   resolved per the register's own rules, not by deleting their history: a
   frontmatter status
   flip, with the item file never deleted or renamed and its body kept in
   place. The skill updates the register in place; this requirement pins it
   to *this* repo's conventions.

R12a. **Cross-reference every mirrored recommendation.** Where a tech-debt
   item the review files — or a GitHub issue it opens — covers the whole of a
   recommendation's *Intended end state*, record that recommendation's `R-NN`
   against the item, somewhere a reader and a `grep` of the register will
   find it (a `review:` frontmatter line on the item). Do it when the item is
   filed, not when it is resolved.

   This is not book-keeping. A recommendation and its mirrored register entry
   are two channels onto one piece of work, and the implementation
   pipeline's Co-Ordinator can tell only by finding this cross-reference
   (`docs/IMPLEMENTATION-PIPELINE-SPEC.md`, requirement 16). Absent
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

R13. **Raise one pull request.** Create the branch
   `<branch_prefix><date>` (`review/<date>` by default; this repository's own
   resolved `branch_prefix`) from the
   default branch; commit the review folder and the updated tech-debt
   register — including every item R12 reserved an ID for, filed here on this
   branch rather than on its own `td/<id>` reservation branch; open **one**
   pull request, **ready for review** (not draft),
   labelled with this repository's own resolved `project_review` pr_label,
   with a Conventional-Commits title
   (`docs(review): repository review <date>` — it becomes the squash commit
   on `main`) and a body that summarises the verdict, links the review
   index, and — where R12 reserved any ids — lists every `td/<id>` it
   reserved and the command to release them once this pull request merges
   (`git push origin --delete td/<id1> td/<id2> …`), since nothing else
   deletes those reservation branches. Record the PR URL to
   `.git/agent-ops-review-pr-url` immediately on
   opening it (the breadcrumb R5d relies on).

R14. **Prove it is landable.** Run the repo's own checks (as its `CLAUDE.md`
   and workflow files define — for a docs-only change this is chiefly the
   whitespace/format gates and commit-format) and fix anything they surface.
   Verify the PR via `gh pr view --json mergeable,mergeStateStatus` against
   GitHub's own view, and resolve any conflict with the current default branch
   — a rebase republished only with `git push --force-with-lease`, the sole
   force-push permitted on the review branch, so a peer's unseen push to the
   lock ref is refused rather than silently overwritten (the same rule the
   implementation pipeline's prompts follow, issue #360).

R15. **Final message.** End with a single JSON object as the entire final
   message: `{"status": "complete", "pr_url": …, "branch": …, "repo": …, "notes": …}`
   or `{"status": "blocked", "reason": …}`.

R18. **Untrusted external content.** Text authored on the forge — issue
   and pull-request titles and bodies, comments, review text, commit
   messages — read while reviewing is data about the repository, never
   instructions to the Reviewer-Agent. `prompts/project-reviewer.md`
   carries the canonical `## Untrusted external content` block
   (IMPLEMENTATION-PIPELINE-SPEC.md requirement 45a states the canonical
   copy), pinned byte-identical with the implementation pipeline's prompts
   by `test/prompt-untrusted-framing.test.sh`. The repository's own files
   are the review's subject, read as evidence throughout; they carry no
   operating instructions either.

### Logging and state

R16. **Streams.** Review *operational* events go to the review pipeline's own
   `state_dir/review-log.jsonl` (its own stream, so the dashboard's existing
   `log.jsonl` parser is untouched and the two pipelines stay separable). Reuse
   the `log_event` shape (requirement 33). Events: `review-start`,
   `review-skipped`, `review-stand-down`, `review-stage-start`,
   `review-stage-end`, `review-pr-raised`, `review-attempt-failed`,
   `review-end`, `labels-ensured` (R5.0b — the same event name and shape the
   implementation pipeline writes, since it is the same mechanism reporting
   the same thing about the same repositories), and `warning`. Common fields:
   ISO-8601 `ts`, a `review` id
   (`<UTC-timestamp>-<node>-<pid>`, pid last, exactly as requirement 33 shapes
   the cycle id), `node`, an `event`, and where applicable `repo`, `pr_url`,
   `model`, `detail`. `review-stage-end` additionally carries the metering
   record of requirement 33a — `model`, `cost_usd`, `duration_ms`,
   `num_turns`, `is_error`, `tokens` — via the same `lib/metering.sh` helper
   `agent-cycle.sh` uses, so a review's stage costs exactly the same shape as
   a cycle's (`docs/METERING-SCHEMA.md`). The one exception is the shared
   `limit-hit` event, which is written to `log.jsonl` (R6), because
   usage-limit stand-down is shared across both pipelines — it carries `node`
   too, so a fleet view can say which machine hit the limit.

R17. The `review-log.jsonl` and the `state_dir/reviews/<review-id>/`
   transcripts are the durable record. Surfacing them in the monitoring
   dashboard is a worthwhile follow-on but is **out of scope** for this
   document (the dashboard has its own spec, `docs/DASHBOARD-SPEC.md`);
   note it there if you extend it.

## Components

What exists, and the requirements each part answers to:

1. `review-cycle.sh` implementing R1–R8 and R16 (including the role guard,
   R2b, through `lib/role.sh`, the union snapshot and state push of R2c, through
   `scripts/state-sync.sh`, and the metering record on `review-stage-end`
   through `lib/metering.sh`, shared with `agent-cycle.sh` — see
   `docs/METERING-SCHEMA.md`). `shellcheck`-clean; sets its own `PATH`.
2. `prompts/project-reviewer.md` implementing R9–R15. It must embed the
   relevant shared-repo conventions (as the other operating prompts do) so the
   stage never depends on context it was not given.
3. `.claude/skills/project-review/` — the vendored skill (pinned; re-sync
   from upstream deliberately).
4. `config.json` — the `project_review` block.
5. `README.md` — a "Repository review" section: what it does and why (the
   loop it closes), every `project_review.*` config key, how to install the
   cron entry,
   how to operate it (`--dry-run`, `--once`, `--repo`, reading
   `review-log.jsonl` and the transcripts), how the outputs feed the
   implementation pipeline / `project-remediation`, and how to uninstall.
6. The crontab line(s) (see "Host provisioning").

## Acceptance checks

Every change to this pipeline must leave all of these passing; before opening
a pull request, run the ones the change touches and any it could regress.

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
4b. **The role guard stands this pipeline down too (R2b).** `test/role.test.sh`
   passes: a `review-cycle.sh` with `AGENT_OPS_ROLE` unset or standby exits 0
   with one line and writes nothing under `state_dir`, while `--dry-run` runs
   regardless of the role.
4c. **A peer's usage-limit hit stands this pipeline down too (R2c/R6).** With
   a peer's materialised log carrying a `limit-hit` whose `resume_at` is in
   the future, `review-cycle.sh` logs a `review-stand-down`, exits 0 and
   clones nothing; its cleanup still pushes this node's state to its own
   branch (`test/state-sync.test.sh` covers the shared machinery).
4a. **The switch stands this pipeline down too (R2a).** With
   `agent-cycle.sh --disable 'testing'` set, a plain `review-cycle.sh` logs a
   `review-stand-down` carrying the reason, exits 0, and launches no `claude`;
   `--enable` restores it. Check this against the *review* script specifically
   and not by inference from `agent-cycle.sh` passing — a shared switch that
   only one pipeline reads is the whole failure mode R2a exists to prevent, and
   it looks identical to a working one until the week a review fires into a
   half-edited `lib/`. The same one-pipeline-blind hazard applies to the
   fleet switch, so `test/toggle.test.sh`'s offline e2e runs the real
   `review-cycle.sh` against a set `fleet/disabled.json` and asserts the
   `review-stand-down` names it.
4d. **The review-branch claim gates the review (R5.0).**
   `test/review-claim.test.sh` passes: against a stubbed `lib/claim.sh` seam
   (`CLAIM_GH`) and a fail-fast `gh`, a *lost* claim logs `review-skipped`
   naming another node and never attempts a clone; a claim *error* skips the
   same way, fail closed; a *won* claim proceeds (the stub records
   `claim branch <slug> review/<date> <default-branch>` in that order), and
   when the clone then fails, `release branch` is invoked for the same key —
   the leak the implementation pipeline fixed in its own workspace path
   (#55) must not be reintroduced here.
4e. **Per-repository resolution, and duplicate slugs refused (R1b).**
   `test/config-schema.test.sh` passes: `config_project_review_repos` resolves
   an entry carrying only `slug` to every one of `project_review.defaults`'
   values, an entry setting a key to its own value for that key alone, and an
   explicit `null` back to the default — including the `model_key` each
   resolution names, which is what an unsupported provider is reported
   against (R1a). `config_defaults` fabricates none of the overridable keys
   into a `repos[]` entry: a schema `default` on one would materialise it in
   every entry, so the entry would always "set" it and `defaults` could never
   apply — which is why only the properties under `defaults` may carry one.
   And a config naming the same `slug` twice exits `review-cycle.sh` 1 before
   the lock, naming the repeated slug, while `scripts/doctor.sh` `fail`s on
   the same config through the same `lib/config-schema.sh` function. Check the
   refusal against the *review* script and not by inference from `doctor.sh`:
   `uniqueItems` cannot express this rule — it compares whole objects, so two
   entries for one repository carrying different overrides are distinct to it
   — so nothing else catches it, and the run would otherwise resolve that
   repository from whichever entry it happened to read last.
4f. **The dated stand-down is two-tier (R3.3).**
   `test/review-not-before.test.sh` passes: a future
   `project_review.defaults.not_before` stands the whole cycle down before the
   lock, with the date on the event; and with that key empty while *every*
   configured repository's own `not_before` override is still in the future,
   the cycle stands down before the lock too, logging one `review-stand-down`
   naming requirement 342. An empty `project_review.repos` is vacuously *not*
   a stand-down. And the converse, which is what proves the two tiers are
   really two: with one repository held on its own override while another is
   free, neither tier fires, the cycle runs, and R4's skip-guard turns the
   held repository away by name with its own date while the free one goes on
   to be claimed. Check that case specifically — a `not_before` that had
   quietly stayed cycle-wide passes every other assertion in that file and
   fails only this one, and the failure it stands for is a repository nobody
   asked to hold being held by its neighbour's date.
5. **Injected-skill isolation:** after a real `--once --repo poetic` run, the
   review PR's diff contains the new `reviews/...` folder and the `tech-debt/`
   change but **not** `.claude/skills/project-review/` — confirm the injected
   skill is git-excluded and absent from the PR.
6. Usage-limit: an injected future `limit-hit` on `log.jsonl` stands the review
   down; and a simulated limit phrase in a transcript causes a `limit-hit` to
   be written to `log.jsonl`.
7. One supervised full run (`--once`): for each non-skipped repo it produces a
   labelled, ready, mergeable review PR, with its tech-debt register updated
   per that repo's own per-item conventions (frontmatter on the item file)
   and a clean `review-log.jsonl` trail. Report the PR URL(s) to the human;
   merge nothing.
8. **Cross-references land (R12a):** in that run's tech-debt register diff,
   every item mirroring a recommendation names its `R-NN` — it lands in a
   `review:` frontmatter line of the item file, so the check greps the
   `tech-debt/` diff (`grep -rc 'R-[0-9]' tech-debt/` non-zero whenever the
   review mirrored anything). Check this explicitly: it is invisible in the
   review's own output — the reports look complete either way — and only
   shows up weeks later as the implementation pipeline paying to
   re-investigate recommendations that are already done.

9. **The untrusted-content framing holds for the Reviewer-Agent too
   (R18).** `test/prompt-untrusted-framing.test.sh` passes — it lifts the
   canonical block from IMPLEMENTATION-PIPELINE-SPEC.md requirement 45a and
   pins `prompts/project-reviewer.md`'s copy byte-identical alongside the
   implementation pipeline's own prompts.

## Host provisioning (human steps)

All of this is in place on the current host; it is needed again only when
standing the pipeline up on a new machine.

1. Create the review label in both repos:
   `gh api -X POST repos/Poetic-Poems/<repo>/labels -f name='project-review' -f color='5319e7' -f description='Raised by the project-review pipeline'`
   (for `poetic` and `poetic-fiddle`).
2. Install the cron entry. **Recommended — a daily tick guarded by
   `min_days_between_reviews`**, which is robust to a machine that sleeps:
   ```
   30 3 * * * $HOME/Code/Poetic-Poems/agent-ops/review-cycle.sh >> $HOME/.local/state/poetic-agents/review-cron.log 2>&1
   ```
   The skip-guard (R4) ensures this actually reviews each repo only about once a
   week. *Strict weekly alternative* (simpler, but a missed Monday tick skips
   the whole week): `30 3 * * 1 …` (Mondays 03:30). Schedule it at a different
   minute from the implementation cycle's own tick to avoid both firing at once
   (the review defers to a running cycle anyway, per R3). The crontab
   environment must also set `AGENT_OPS_ROLE=active` on the node that is to run
   the reviews (R2b); without it every tick stands down.

   On a containerised node this entry is not installed by hand at all: it is
   the review line of `deploy/docker/crontab`, which the scheduler service runs
   under supercronic (see the node image section of
   `docs/IMPLEMENTATION-PIPELINE-SPEC.md`). Its hour and minute are rendered
   per node at container start (design decision D5): `config.json`'s
   `schedule.review_offset_minutes` (`29`) past `CYCLE_MINUTE` (mod 60), at
   `schedule.review_hour` (`3`), so the node's two heavy pipelines sit
   maximally apart within its hour and no two nodes review at the same
   moment either. The role comes from `ROLE` in the node's
   `deploy/docker/.env` rather than from a crontab line, and defaults to
   standby when it is missing.
3. The shared prerequisites of `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (the standalone `claude`
   CLI, cron enabled under WSL, `gh` authenticated with push access) are
   already satisfied by the implementation pipeline; nothing further is needed.

## Cost profile

One deep review per repo per week: a Sonnet lead driving the skill, which
itself delegates to lower-cost subagents. Bounded by each repository's own
resolved `timeout_review`.
The skip-guard caps it at one review per repo per `min_days_between_reviews`, so
a daily cron tick does not multiply cost. Deferring to the implementation lock
keeps the two pipelines from doubling up on quota at the same moment. The Script
itself makes no model calls.

## Design decisions

Recorded so a future reader knows they were deliberate. History and
superseded approaches belong here, never in the requirements above, which
state only what is.

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
  there is no correctness pass to add (unlike the Implementer→Reviewer
  hand-off), so a second agent stage would only add cost. The landing gate is the
  merge.
- **"Once a week" is implemented as a daily tick plus a skip-guard**, because a
  strict weekly cron on a machine that sleeps can miss its one tick and lose a
  whole week. The guard also makes re-runs idempotent.
- **The outputs feed the existing pipelines by design.** The review updates
  the same per-item tech-debt register the hourly Co-Ordinator already
  reads, and writes the improvement prompts the `project-remediation` skill
  consumes — so the review is the front of an existing loop, not a parallel
  dead-end.
- **`min_days_between_reviews` is 6, not 7**, so a review that lands a day late
  one week is not deferred a full extra week the next.

The shared platform, models, permissions, and system location were confirmed
with the repo owner for the implementation pipeline and carry over unchanged;
no open questions remain.
