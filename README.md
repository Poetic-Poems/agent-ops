# Poetic Autonomous Implementation Agent System

A self-hosted, unattended pipeline that automatically selects, implements, and reviews pending work from the [poetic](https://github.com/Poetic-Poems/poetic) and [poetic-fiddle](https://github.com/Poetic-Poems/poetic-fiddle) repositories — and from [agent-ops](https://github.com/Poetic-Poems/agent-ops) itself, the pipeline's own home, so it works down its own backlog and roadmap — raising mergeable pull requests for human review and approval at the default `merge_autonomy` level (`human`), with an opt-in trust ladder ([The Landing Gate](docs/IMPLEMENTATION-PIPELINE-SPEC.md#the-landing-gate)) an installation may deliberately climb.

## What it does

Once an hour:

1. **Co-Ordinator** (Haiku) selects at most one well-scoped item of work (security findings, review feedback, merge conflicts on otherwise-ready PRs of ours, abandoned draft PRs of ours, failed CI runs, tech-debt, issues, fiddle's implementation plan, project-review recommendations, or code-quality findings). Security work — open Dependabot alerts and security code-scanning alerts — is always prioritised ahead of everything else; an issue you have marked `Urgent` comes second; answering your review feedback comes third, rebasing a ready PR of ours that has hit a merge conflict comes fourth, and finishing a draft PR this system started and then abandoned comes fifth. Issues rank by their **`Priority`** field — `Urgent`, `High`, `Medium` (also the default when the field is unset) and `Low` each sit at a different point in the order — so triaging an issue is how you move it up or down the queue.
2. **Implementer** (Sonnet/Haiku) clones the repo, implements the item on a feature branch, and opens a draft pull request — or, for review feedback, pushes to the existing branch of the PR you commented on.
3. **Reviewer** (Sonnet, or Opus when the Implementer graded the work `complexity:high`) checks and corrects the implementation, then marks the PR ready for review.
4. **The Landing Gate** reviews and merges the pull request. At the default
   `merge_autonomy` (`human`) a human does both; an opt-in trust ladder (see
   [The Landing Gate](docs/IMPLEMENTATION-PIPELINE-SPEC.md#the-landing-gate))
   can add an **Approver** App review and, at its top two rungs, have the
   Script itself land an eligible pull request — a human's own role then
   narrows to whatever the classifier didn't cover, and a human
   `CHANGES_REQUESTED` blocks landing at every level regardless.

And, at the end of a cycle, rarely: the **Enabler** (Opus) re-examines an item
that has been blocked for several cycles, unblocks it if it can and raises an
issue assigned to you if only you can — see
[Blocked items and the Enabler](#blocked-items-and-the-enabler). It also writes
the specification for an item too vague to select, which is otherwise skipped
in silence forever — see
[Items nobody has specified](#items-nobody-has-specified).

At the same end of the same cycle, and not rarely at all: the **Refiner**
(Haiku) writes that specification for an item nobody has scoped *before* it has
to be blocked and wait for the Enabler at all — see
[Refined items and the Refiner](#refined-items-and-the-refiner).

If no suitable item exists, or if back-pressure shows open agent PRs, the cycle stands down — cheaply, without waking the Co-Ordinator, when nothing has changed since it last found nothing to do (see [Skipping no-op cycles](#skipping-no-op-cycles)).

## Responding to your review comments

Request changes on an agent PR and the next cycle picks it up: it reads your
review, pushes a fix to the same branch, replies point by point saying what it
changed and what it didn't and why, and re-requests your review. It never opens
a second PR for this, and it never re-does the original work — it amends what's
there.

This sits second in priority, above everything but security: you're the only
consumer this system has, so answering you beats starting something new.

Four things to know:

- **You'll get the PR back in your review queue.** The re-request is the whole
  handoff on a second round — the PR never went back to draft, so nothing else
  would put it in front of you, and your original review request stopped being
  pending the moment you submitted the review. The pipeline asks GitHub whether
  the re-request actually happened and makes it happen if it didn't, the same
  way it verifies the draft flip on a first round; neither is left to a model's
  good intentions. This is what poetic-fiddle #200 was missing: reviewed,
  answered, pushed, replied to — and then sitting in nobody's queue.
- **The agent can't clear your `CHANGES_REQUESTED`, ever.** GitHub won't let a
  PR's author dismiss a review on their own PR, and the agent raises PRs as
  you (`warwickallen`). So the PR stays `BLOCKED` and un-mergeable until *you*
  re-review — re-requesting your review doesn't change that, and isn't meant
  to; it rings the bell without moving the gate. That's not a bug to route
  around — it's the structural human **veto**, enforced by GitHub rather than
  by good intentions, and it survives every `merge_autonomy` level: the
  pipeline never dismisses a human review, so your `CHANGES_REQUESTED` blocks
  landing even in a repository the Script is otherwise trusted to merge in.
- **Every comment the pipeline posts says so, up top.** Because it writes as
  you, the author field can't tell your own comments from the pipeline's — so
  every comment it posts opens with a bold label naming which stage wrote it
  and which node ran it, e.g. `**Implementer** · autonomous pipeline · node
  \`poetic-2\``. A comment with no such label is one you, or another human,
  wrote.
- **It answers each round exactly once.** Whose turn it is comes from comparing
  your latest review against the branch's head commit: review newer means the
  agent owes you a reply; commit newer means it has replied and is waiting on
  you. Request changes again and it comes straight back.
- **Put the substance where it'll be read.** Every review body and inline
  comment in the round is passed to the agent verbatim, whichever account wrote
  it — so a detailed `COMMENTED` review from one account plus a bare
  `CHANGES_REQUESTED` from another works fine. Say which findings block a merge
  and which don't; the agent honours that split.

Only PRs the system is managing are eligible (labelled `autonomous-agent`, on an
`agent/` or `td/` branch — see [Handing a pull request to the
pipeline](#handing-a-pull-request-to-the-pipeline)). Your own branches are never
touched.

Back-pressure doesn't block this: if every agent PR is sitting on "changes
requested", the cycle restricts itself to review feedback rather than standing
down, so it can always dig itself out. It still can't open a new PR while the
gate is full.

## Staying in front of you

The re-request above covers the round *after* the first — but a first-round PR
and an already-approved one can go quiet too, and neither is a `CHANGES_REQUESTED`
the pipeline knows to answer:

- **Every ready PR keeps a live review request, not just the one CODEOWNERS made
  at the start.** Once your review is submitted — approving or not — that
  request is consumed, and nothing else asks you again. Every cycle, whether or
  not it touches that PR through any other stage, checks and re-asks whoever
  already reviewed it (preferring them over a fixed name, since the pipeline's
  own PRs are authored as `warwickallen` and GitHub refuses a review request
  aimed at a PR's own author). This is what poetic-fiddle #170 was missing:
  approved, green, and sitting for 6.8 days because nothing ever asked again.
- **An approved, mergeable, green PR idle for `human_nudge_idle_hours` (default
  24) gets one nudge comment**, `@`-mentioning you, once — not repeated, and not
  instead of the live review request above, which keeps working regardless.
  Never fires on a PR you've already enqueued in a GitHub merge queue, where one
  is enabled — that reads the same as one nobody has acted on yet, so this
  checks for the difference rather than telling you to click a button you
  already clicked. If the queue itself dequeues a PR after a checks failure —
  a state GitHub otherwise gives you no way to notice — you get a one-time
  notice comment instead, immediately, not held for the idle threshold above.
- **A GitHub issue the pipeline reports as needing your decision is labelled
  `blocked` and `blocked:needs-refinement`**, not just the ordinary
  `needs-refinement` label — the same pattern that already resolves an Enabler
  escalation in 1–2 hours, extended to the Co-Ordinator's own `needs_refinement`
  reports so a genuinely human-blocked issue never sits invisible the way #203
  briefly did. Assignment stays reserved for an actual Enabler escalation — a
  separate issue you personally need to act on and close — so Assigned-to-me
  never fills up with the pipeline's own bookkeeping.

## Issue priority

An open issue's place in the queue is its **`Priority`** field — GitHub's own
issue field (`Urgent` / `High` / `Medium` / `Low`), set from the issue page's
sidebar, not a label. Setting it is how you move an issue up or down against
every *other* kind of work the pipeline could pick instead:

| Priority | Where the issue is picked up |
|---|---|
| `Urgent` | **Second overall, across both repos** — ahead of everything except security work, including ahead of your review feedback and of finishing a stalled PR. |
| `High` | After a red default branch, but ahead of `TECH-DEBT.md`. |
| `Medium` | After `TECH-DEBT.md`, ahead of the implementation plan and the repository review's recommendations. |
| `Low` | After the review recommendations, ahead of only the automated code-quality findings. |

**An issue with no `Priority` set counts as `Medium`**, which is exactly where
all issues ranked before this existed — so an untriaged backlog behaves as it
always has, and nothing is quietly demoted for want of triage.

Three things the field does *not* do. It doesn't change how the work is done:
an issue's band decides when it is picked up, and a `Low` issue is implemented
and reviewed to the same standard as any other. It doesn't override the
exclusions — an issue that is assigned (see [Reserving an issue for
yourself](#reserving-an-issue-for-yourself)), labelled `blocked`, or is really a
question stays out of the pipeline at every priority, `Urgent` included. And it
doesn't outrank security: an issue labelled `security` or `vulnerability` is
security work first, whatever its `Priority`.

**No band keeps an issue out of the pipeline**, `Low` included: a band decides
*when* an issue is reached, never *whether*. To reserve one, assign it — see
below.

Re-prioritising an issue is picked up on the next cycle: the band is part of
what the no-op check watches (see [Skipping no-op cycles](#skipping-no-op-cycles)),
so a re-triage always wakes the Co-Ordinator rather than being absorbed by a
"nothing changed" skip.

## Reserving an issue for yourself

**Assign an issue and the pipeline will not touch it.** Assignment is the
reservation switch, and it is a hard one: `scripts/gather-issues.sh` drops every
issue that has an assignee before the Co-Ordinator is handed the candidate list,
so a reserved issue is never ranked, never skipped, never reasoned about — it
simply isn't there to consider. Unassign it and the next cycle has it back.

Reach for this when an issue is work you mean to do yourself, in an interactive
session, or that you want to think about before anything starts implementing it.
It is the counterpart of [Handing a pull request to the
pipeline](#handing-a-pull-request-to-the-pipeline): one hands work over, the
other keeps it.

```bash
gh issue edit <n> -R Poetic-Poems/<repo> --add-assignee @me      # reserve
gh issue edit <n> -R Poetic-Poems/<repo> --remove-assignee @me   # release
```

Three things to know:

- **`Priority: Low` is not a reservation.** `issues:low` is a source in every
  repo's walk, so a cycle with nothing above it to do will reach a `Low` issue
  and select it. Use the band to say how urgent the work is; use assignment to
  say who is doing it.
- **The `blocked` label does the same job, but says something else.** It is the
  same deterministic drop, applied in the same place, and it is the right switch
  when real work is genuinely waiting on something outside itself. An issue you
  have simply claimed is not blocked, and labelling it so tells the next person
  reading the queue the wrong thing.
- **It's the guarantee the Enabler already leans on.** Every escalation issue the
  Enabler raises is assigned to `enabler_assignee`, precisely so the pipeline
  cannot pick up its own request for help — the Script refuses to start a cycle
  when `enabler_model` is set and that assignee is not, rather than raise one
  unassigned. Reserving your own issues rests on the same mechanism.

Assignment hides nothing: the issue stays open, keeps its band, and still appears
in the dashboard's open-issues panel, which lists what is open rather than what
is selectable. Releasing one is picked up on the next cycle — the assignee is
part of the fingerprint the no-op check watches, alongside labels and `Priority`
(see [Skipping no-op cycles](#skipping-no-op-cycles)) — so unassigning always
wakes the Co-Ordinator rather than being absorbed by a "nothing changed" skip.

## Cross-item dependencies

**`Blocked-by: #195`, on its own line in an issue's body or any comment on
it, holds that issue back until #195 closes.** For a dependency in the other
repo this pipeline also works, name it in full: `Blocked-by: owner/repo#42`.
Several references can share one line, comma- or space-separated
(`Blocked-by: #1, #2`), and the line can carry a leading `-` if you're
itemising it in a list.

This is the structured alternative to writing "blocked until #195 is
merged" in prose. Prose has to be re-read and re-judged by a model every time
the pipeline reconsiders the issue, and a note describing a moment in time
does not update itself once that moment has passed — four issues in this
project's own history were repeatedly, wrongly re-blocked from a stale prose
note like that, well after the dependency it named had actually merged, each
false block costing a full Enabler engagement to clear. `Blocked-by:` does
not have that failure mode: nothing here ever trusts what the line says
happened, only what re-checking `#195`'s own state says right now, so a line
left in place after `#195` closes is inert rather than wrong — there's
nothing to remember to clean up.

Both directions are code, not a model's judgement, and cost nothing beyond
one `gh` read per reference:

- **Holding.** An issue naming an unresolved `Blocked-by:` reference never
  reaches the Co-Ordinator's candidates at all — the same deterministic drop
  as an assigned or `blocked`-labelled issue (see [Reserving an issue for
  yourself](#reserving-an-issue-for-yourself)).
- **Releasing.** An issue the pipeline has already recorded blocked — for
  this reason or any other — clears automatically, logged `by:
  "dependency-resolved"`, the moment every `Blocked-by:` reference it still
  names is closed. You do not have to touch the issue for this to happen;
  closing (or merging) the referenced item is enough.

You do not have to write the line yourself: if the pipeline's own agents
recognise an item is waiting on another specific, numbered one, they use this
form too, in a comment, so the mechanism above applies to it as well.

## Handing a pull request to the pipeline

The `autonomous-agent` label is what marks a pull request as the pipeline's to
manage. The system adds it to every PR it raises — but you can add it to an open
PR yourself to hand that PR over, and the next cycle will treat it as an available
work item. For example:

- a **ready PR that has hit a merge conflict** is rebased onto `main` and its
  conflict resolved (the `merge-conflicts` source);
- a **draft the system started and then left stalled** is finished
  (`abandoned-drafts`);
- a PR you have **requested changes on** is answered (`review-feedback`).

This is the switch to reach for when a PR the system *didn't* raise — most often
one you created through `/td` — has drifted into conflict, or whenever you want
the fleet to carry an existing PR the rest of the way.

Two things to know:

- **It only applies to `agent/` and `td/` branches** — the ones the system is
  allowed to push to. `/td` raises its PRs on `td/<id>` and the implementation
  cycle on `agent/<item>`, so both qualify; labelling a PR on any other branch (e.g.
  `feature/…`) does nothing, because the landing gate reserves those and the
  gatherers skip them even when labelled.
- **Labelling grants write access.** A labelled PR is one the fleet may push to —
  including a `--force-with-lease` rebase to clear a conflict — and it counts
  toward the open-PR back-pressure cap. Remove the label to take the PR back.

## Merge autonomy

Every pull request this pipeline raises goes through the same review and
merge machinery; what varies is *who* performs the approve and the merge.
That's `merge_autonomy`, a four-level trust ladder — see [The Landing
Gate](docs/IMPLEMENTATION-PIPELINE-SPEC.md#the-landing-gate) for the full
requirements this section summarises:

| Level | Who approves | Who lands | Your residual act |
|---|---|---|---|
| `human` — **the product default** | You | You | Everything — the pipeline never approves or merges anything |
| `agent-approves` | The Approver App | You | The merge (or enqueue) click |
| `agent-merges-routine` | The Approver App | The Script — for a pull request graded within `merge_autonomy_routine_complexity` (`low`/`medium` by default) from a source in `merge_autonomy_routine_sources`, touching no protected path | The click for anything the classifier doesn't cover |
| `agent-merges-all` | The Approver App | The Script — the same classifier as `agent-merges-routine`; nothing lands here that wouldn't already land there | The click for anything the classifier doesn't cover, same as `agent-merges-routine` |

The top two rungs are configured and validated separately even though they
land the same pull requests today: `agent-merges-all` is where a protected
path (the pipeline's own gate code, its prompts, its CI) becomes eligible to
land with no human click at all, once that class carries its own stronger
review tier and a cool-off between approval and landing — controls not yet
built, so a protected-path change needs your click at either level for now.

**The invariants, at every level:**

- **Nothing lands that you have not opted into.** A fresh install ships
  `merge_autonomy: human`, and it stays there — fleet-wide, and for every
  repository — until you deliberately raise it, per repository or across the
  whole installation.
- **You retain ultimate control.** No model ever holds approve or merge
  rights — not the Implementer, not the Reviewer, not even the Approver's own
  prompt, which only judges and never fixes. Only the Script does, under a
  non-author identity, and only once every deterministic gate and an
  independent Approver verdict have passed. A `CHANGES_REQUESTED` review from
  your own account blocks landing at every level, unconditionally: the
  pipeline never dismisses a human review, so raising the level narrows what
  still needs your merge click, never what needs your veto.

**Identity.** Every level above `human` needs a non-author GitHub App to hold
approve rights — the pipeline authors every pull request as its own
configured owner, and GitHub refuses to let a pull request's author approve
it, so no level of agent approval is possible without a second identity. This
App (**"Pullwright Approver"**) needs `pull_requests: write` and
`contents: write`; its installation token — minted and cached for its
~1-hour lifetime by `lib/approver-token.sh` — is what the Script signs its
reviews and merges with, never the owner credential the pipeline authors
with. Set the App's
id as `approver_app_id`, and its three cost tiers as
`approver_model_default`/`_complex`/`_critical`; leaving `approver_model_default`
empty switches the whole Approver stage off regardless of `merge_autonomy`,
and leaving either of the other two empty falls that tier back to the one
below it.

**What each level needs at the forge**, beyond `config.json`:

- **`agent-approves` and above** — install the App on the repository, with
  `approver_app_id` and `approver_model_default` both set in `config.json`
  ([`scripts/doctor.sh`](#checking-an-installation) fails the installation
  otherwise); set the three `PULLWRIGHT_APPROVER_*` environment variables the
  token wrapper reads (the App's id, its installation id, and the path to
  its private key), which `doctor.sh` cross-checks against `approver_app_id`
  itself; and turn the default branch ruleset's code-owner review
  requirement *off* — an App cannot satisfy it, and `doctor.sh` fails the
  installation if a ruleset still demands it at `agent-merges-routine` or
  above (it is only ever a recommendation, not a hard requirement, below
  that). A `pull_request` rule requiring at least one approving review is
  recommended so `reviewDecision` reflects the App's review normally, though
  nothing here fails on `0`.
- **`agent-merges-routine` and `agent-merges-all`**, in addition — if the
  repository has no active merge queue on its default branch, both
  `allow_auto_merge` and `allow_squash_merge` must be enabled, and
  `doctor.sh` fails the installation if either is off: the Script's no-queue
  landing fallback (`gh pr merge --auto --squash`) is refused outright
  otherwise. Where a merge queue does exist, landing is enqueueing, and the
  queue's own checks are one more gate a pull request must clear first.

**The kill switch is a permanent operational control, not rollout
scaffolding.** Independent of `merge_autonomy` itself,
`agent-cycle.sh --kill-merge-autonomy "<reason>"` forces every repository's
*effective* level to `human` immediately and fleet-wide, without touching
`config.json` — cycles keep running exactly as they otherwise would, but no
Approver review and no automatic landing happens anywhere until
`agent-cycle.sh --restore-merge-autonomy` clears it. `--status` reports
whether it's set. Reach for it exactly as you would `--disable` (see
[Pausing the pipelines](#pausing-the-pipelines)), when what you want stood
down is the landing gate itself rather than the whole pipeline.

## Configuration

Edit `config.json` before first run, then check it with
[`scripts/doctor.sh`](#checking-an-installation) — every key below is
described in `config.schema.json` too, and the doctor validates your file
against it. The schema is the enforceable statement of this table: it knows
each key's type, its range, and whether it may be left out, and it rejects a
key it has never heard of, so a misspelling is caught the moment you check
rather than silently running on a default you did not choose. Both
`agent-cycle.sh` and `review-cycle.sh` validate against the same schema at
startup and refuse to run at all on a config that fails it, so `doctor.sh` is
how you catch a misconfiguration before it costs you a cycle, not the only
thing standing between you and one.

Every key below is set the same way — as a key of the JSON object in
`config.json`, and `repos`' per-repo keys (`nice`,
`implementation_plan_path`, `stage_timeouts`, `stage_inactivity`) on the
repo's own entry inside that array. Editing that file is the whole of it:
there is no command that sets a key, and the pipeline never writes to
`config.json` itself — not even the values that tune themselves — so a value
stays exactly what you left it. On a fleet already running, the edit is a
change to a file the container reads, and reaches the nodes like any other:
merge it, and each node restarts into the new image between cycles, per
[Making a change when every instance is a
container](#making-a-change-when-every-instance-is-a-container).

Keys:

<!-- config-table:start id=main — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not these rows -->
| Key | Default | Notes |
|---|---|---|
| `repos` | see `config.json` | Array of `{"slug": "...", "sources": [...]}`. `sources` is that repo's work sources in priority order (`security`, `issues:urgent`, `review-feedback`, `merge-conflicts`, `dequeued`, `human-visibility`, `abandoned-drafts`, `failed-runs`, `issues:high`, `tech-debt`, `issues:medium`, `implementation-plan`, `project-review`, `issues:low`, `code-quality`, `register-hygiene`). `security` (open Dependabot + security code-scanning alerts) is always first, and any security-related...[continued below](#extended-notes-repos) |
| `state_dir` | `~/.local/state/poetic-agents` | Lock, shared log, stage transcripts. |
| `workspace_root` | `~/.cache/poetic-agents/workspaces` | Ephemeral clones. Each cycle gets its own subdirectory, and the state repository keeps its mirror here. |
| `state_repo` | `Poetic-Poems/agent-ops-state` | Private repository through which `state_dir` replicates between nodes. See [Keeping every node warm](#keeping-every-node-warm). Leave it out and nothing syncs — a single-node install behaves exactly as before. |
| `cycles_retained` | *(unset)* | Cycle directories kept in the replicated copy — bounds disk use, derived from `schedule.cycle_interval_minutes` to hold ~8.3 days of history regardless of cadence (requirement 1d); a configured value floors it, never caps it. Your own `state_dir` is not pruned. |
| `state_local_cycles_retained` | *(unset)* | Cycle and review directories the node's own `state_dir` keeps; the same push that replicates prunes to it. Deliberately far above `cycles_retained`, so the local machine is always the longer record. A span of history, not a literal count (requirement 1d): absent, it is derived from `schedule.cycle_interval_minutes` to hold the same ~41.7 days 1000 cycles was sized for at the historical hourly cadence; a configured value is a floor under that derivation, never a ceiling. |
| `state_local_streams_retained` | *(unset)* | Cycle and review directories whose derived files are kept — the stage event streams (`<stage>.stream.jsonl`) and the fleet-log snapshot (`.fleet-log.jsonl`). Both are large and local-only — never replicated — so they are bounded well below `state_local_cycles_retained`; the records themselves are untouched. Derived from `schedule.cycle_interval_minutes` to hold ~2.1 days regardless of cadence (requirement 1d); a configured value floors it, never caps it. |
| `log_retained_bytes` | `2000000` | Size at which `scripts/rotate-logs.sh` rotates `dashboard.log`, `state-sync.log`, `doctor.log`, `revert-rate.log`, `cron.log` and `review-cron.log`. `log.jsonl`, `review-log.jsonl` and `revert-rate.jsonl` are never rotated. |
| `log_generations` | `3` | Rotated generations kept beside each live log (`<name>.1` … `<name>.<log_generations>`). |
| `coordinator_model` | `claude-haiku-4-5-20251001` | Selection is cheap triage. |
| `implementer_model_default` | `claude-sonnet-5` | For code changes. |
| `implementer_model_trivial` | `claude-haiku-4-5-20251001` | For docs, comments, register entries only. |
| `reviewer_model_default` | `claude-sonnet-5` | Quality gate before the landing gate, for work the Implementer graded `complexity:low` or `complexity:medium`. |
| `reviewer_model_complex` | `claude-opus-5` | The same gate for work graded `complexity:high` — the Implementer grades each PR ex post and labels it; the higher of that grade and the PR's existing label picks the tier. Leave it empty to review everything on `reviewer_model_default`. |
| `approver_model_default` | `claude-sonnet-5` | The Approver's model for work graded `complexity:medium`, active once `merge_autonomy` (see below) is above `human`. Leave it empty to switch the whole stage off — no App review is ever posted, at any level. |
| `approver_model_complex` | `claude-opus-5` | The same gate for work graded `complexity:high`, refuse-by-default. Leave it empty to run every Approver engagement on `approver_model_default`. |
| `approver_model_critical` | `claude-fable-5` | The Approver's model for adjudicating a pull request the Approver has refused twice in a row — the rarest and most expensive tier, re-entered every round while that two-refusal streak holds, until an approval resets it; the escalation issue a refusal raises stays deduplicated to one per pull request rather than one per round. Leave it empty to fall back to `approver_model_complex`. |
| `approver_restale_escalate_after_hours` | `24` | Hours a pull request may sit with a stale Approver `CHANGES_REQUESTED` — its `commit_id` no longer matching the head, but with no commit authored since (a rebase-only push, never a fix) — before the restale sweep escalates it to `enabler_assignee` instead of retrying forever. |
| `enabler_model` | `claude-opus-5` | The Enabler: re-examines long-blocked items and escalates the ones needing you. The most expensive model here, engaged rarely — see [Blocked items and the Enabler](#blocked-items-and-the-enabler). Leave it empty to switch the stage off. |
| `enabler_model_critical` | `claude-fable-5` | The Enabler's model for its narrower bounded pass — the `adjudicate-first`/`decide-tactical` adjudication or decide pass over one item alone, see [Blocked items and the Enabler](#blocked-items-and-the-enabler). Leave it empty to run that pass on `enabler_model` itself. |
| `enabler_assignee` | `warwickallen` | GitHub login every Enabler escalation is assigned to. Required whenever `enabler_model` is set — the Script refuses to start a cycle rather than raise an unassigned escalation, since the assignment is what excludes the issue from the pipeline's own `issues` source (see [Issue priority](#issue-priority) and requirement 16.4 in the spec). |
| `enabler_after_coordinator_cycles` | `3` | How many cycles that actually ran a Co-Ordinator must pass, after an item is blocked, before the Enabler looks at it. Counting cycles rather than hours means a fleet that spent the night stood down on a usage limit has not "waited". |
| `refinement_after_coordinator_cycles` | *(same as `enabler_after_coordinator_cycles`)* | The same wait, but for an item the pipeline recorded as too under-specified to work on (an issue picks up the `needs-refinement` label) rather than one blocked by something in the world. Left unset it waits exactly as long as any other block; set it separately once fleet behaviour tells you refinement items should age faster or slower. |
| `enabler_recheck_hours` | `72` | Hours before the Enabler re-examines an item it has already examined. This is the bound on how long new evidence — a diagnosis posted into the very thread whose absence blocked the item — can sit unread. `0` switches re-examination off. |
| `enabler_escalation_label` | `enabler-escalation` | Label applied to every issue the Enabler raises, for your filters and for its own duplicate check. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up; without it the issue is still raised, just unlabelled. |
| `escalation_autonomy` | `decide-tactical` | The D18 escalation-autonomy ladder, three rungs, each including the one below it (with one exception, below): `always-escalate` (today's behaviour — every Enabler escalation goes straight to a human), `adjudicate-first` (one bounded Enabler adjudication pass runs first, but only over a refinement disagreement; it either confirms the earlier refinement or escalates anyway), or `decide-tactical` (one bounded Enabler decide pass runs first over *any* escalation — an ordinary...[continued below](#extended-notes-escalation_autonomy) |
| `escalation_adjudication_max_passes` | `3` | How many `decide-tactical` passes one item may spend in total, whatever their reason — see [Blocked items and the Enabler](#blocked-items-and-the-enabler). A fresh reason still gets its own pass under this cap, and closing an escalation about the item grants one further pass regardless of it; only a run of unrelated tactical questions on the same item is what this bounds. |
| `needs_refinement_label` | `needs-refinement` | Label put on an **issue** while the pipeline has it recorded as too under-specified to work on, and taken off again when that clears — see [Items nobody has specified](#items-nobody-has-specified). You can also apply it yourself to flag one directly; the pipeline reads that back the same way. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up...[continued below](#extended-notes-needs_refinement_label) |
| `refinement_max_per_engagement` | `3` | How many under-specified items one Enabler engagement will take on. Ordinary blocked items are never displaced by them, and items over the cap simply wait for a later engagement. `0` switches the refinement work off while still recording it. |
| `refiner_model` | `claude-sonnet-5` | The Refiner: writes a specification for an item nobody has scoped yet and marks it `refined`, before it would otherwise have to be blocked and wait for the Enabler — see [Refined items and the Refiner](#refined-items-and-the-refiner). Engaged every cycle there is unrefined work to do, so how often it runs and how good it has to be pull against each other: what it writes is the brief an Implementer works from. Leave it empty to switch the stage off. |
| `refined_label` | `refined` | Label put on an **issue** once the Refiner has written it a specification — see [Refined items and the Refiner](#refined-items-and-the-refiner). Purely informational: nothing reads it back, so removing it by hand does nothing. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up. Leave it empty to switch the labelling off; the item is still recorded...[continued below](#extended-notes-refined_label) |
| `refiner_max_per_engagement` | `5` | How many unrefined items one Refiner engagement will write specifications for. Items over the cap simply wait for a later engagement. `0` switches proactive refinement off. |
| `refinement_policy` | `{"issues": "required", "tech-debt": "required"}` | Per source: `required` (never select unrefined), `preferred` (rank refined items first, but an unrefined one may still be picked), or `exempt` (no refinement dimension — the default for every source not listed). Shipped default: `issues` and `tech-debt` both `preferred` — the two sources whose items can otherwise carry a specification the Co-Ordinator composed itself rather than one already written elsewhere (a merge conflict, a review comment, a security finding). See...[continued below](#extended-notes-refinement_policy) |
| `unvoid_label` | `unvoided` | The label you apply on GitHub to ask for a voided item to be reopened — see [Blocked and void items](#blocked-and-void-items). No stage ever applies it, so "only a human may clear a void" still holds; this is just a way to say so from the issue itself. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours`; `scripts/doctor.sh` warns while a repo has not got it yet. Do not set it to...[continued below](#extended-notes-unvoid_label) |
| `labels_ensure_interval_hours` | `24` | How often, in hours, the pipeline re-lists a repository's labels to create any that are missing (installation step 4, below). Every repository the cycle gathers data for gets this, not only the one it works, so a label you delete comes back within this interval rather than only the next time that repository happens to be selected. `0` re-lists on every cycle. |
| `label_prefix` | `pw::` | Namespace prefix for labels the pipeline fully owns, colour, description and existence kept in sync with configuration rather than only ever created once — see `lib/labels.sh`'s `labels_reconcile`. Every other label keeps today's create-only behaviour, so an operator's own colour/description choice is never undone. Leave it empty to disable reconciliation and deletion entirely. |
| `void_retire_after_days` | `30` days | Days a voided item sits fully actioned — its issue or pull request closed, or its tech-debt register row flipped to `resolved`/`not-debt` — before the pipeline stops carrying it in the void extract. This does not touch whether the item is void (still forever, still only a human's `unvoided` label undoes it, see [Blocked and void items](#blocked-and-void-items)); it only stops an old, settled verdict from being handed to the Co-Ordinator and the dashboard's data forever. `0` disables retirement. |
| `prompt_overrides` | `{}` | Add house rules to a stage's operating prompt, or replace it outright, without forking `prompts/`. The Approver's prompt takes no override — it is the trust gate the merge-autonomy ladder rests on. See [Prompt overrides](#prompt-overrides). |
| `pr_label` | `autonomous-agent` | Applied to every PR this system raises. Do not name it `obsolete`, which is reserved for a human to mark one of these PRs as unwanted. Threaded through every work order's own `pr_label` field, which the Implementer labels its pull request with. |
| `branch_prefix` | `agent/` | Branch naming: `agent/<item-slug>`. |
| `tech_debt_branch_prefix` | `td/` | Deprecated: legacy recognition only, for a pre-migration human tech-debt-claim branch or a `td/<ID>` branch minted before D15's revision. A fresh tech-debt selection now claims `branch_prefix` like any other item. Leave it empty for a repository that never followed the `TECH-DEBT.md` convention — the affected scripts then match only `branch_prefix`. |
| `max_open_agent_prs` | `8` | Back-pressure limit: draft PRs, changes-requested PRs and claims across both repos — not PRs only waiting on approval or merge. |
| `candidates_max` | `3` | How many ranked candidates the Co-Ordinator returns; the Script claims down the list, so a lost race costs the next-best item rather than the cycle. |
| `coordinator_prompt_max_bytes` | `500000` | The largest assembled prompt the Script will hand the Co-Ordinator. What a context window rejects is the whole prompt, not the runtime input alone, so the Script measures the rendered base prompt, subtracts it, and trims the two bands that carry a whole document each — an issue's entire thread and a tech-debt issue's entire thread — into what is left. Prose is shed and candidacy is not: every entry stays selectable, and every cut carries a marker naming how many bytes went...[continued below](#extended-notes-coordinator_prompt_max_bytes) |
| `max_chained_cycles` | `3` | The most cycles that may run back-to-back in one lineage — the cron-fired original plus its immediate continuations, instead of each waiting for the next cron firing. A productive cycle chains to this cap regardless of remaining work (the remaining-sources gate counts enabled source categories, which back-pressure never empties) — up to `max_chained_cycles − 1` further full Co-Ordinator passes, the accepted price of the drain rate. `1` disables chaining. |
| `claim_ttl_hours` | *(unset)* | Hours before a dead node's claim-registry entry is swept (`lib/claim.sh gc`) — derived from `schedule.cycle_interval_minutes` to stay 6 firings wide at whatever cadence is configured, floored at a cycle's own worst-case runtime so a fast cadence cannot derive it below that (requirement 1d); a configured value floors it, never caps it. |
| `abandoned_draft_after_hours` | *(unset)* | Hours a draft PR this system raised may sit untouched before it counts as abandoned and finishing it becomes selectable work (the `abandoned-drafts` source) — derived from `schedule.cycle_interval_minutes` to stay 4 firings wide at whatever cadence is configured, floored at a cycle's own worst-case runtime so a fast cadence cannot derive it below that (requirement 1d); a configured value floors it, never caps it. Also the staleness threshold `scripts/sweep-orphan-branches.sh` uses. |
| `human_nudge_idle_hours` | `24` | Hours an approved, green pull request may sit idle — nothing left for the pipeline to do, only a merge click nobody was asked for — before `scripts/sweep-human-visibility.sh` posts one nudge comment naming `enabler_assignee`. `0` disables the nudge; the sweep still keeps a live review request on every such PR regardless (see [Configuration](#configuration) → `enabler_assignee`). |
| `merge_queue_dequeue_notice_max_age_hours` | `24` | Hours a merge-queue-dequeue notice comment (`scripts/sweep-human-visibility.sh`, requirement 38f) may still fire for after the removal event's own time — bounds the notice to genuinely new information rather than an event a sweep is only now seeing for the first time. `0` disables the notice entirely, at the cost of losing the only human signal this pipeline raises for a merge-group failure. |
| `merge_autonomy` | `human` | The D18 merge-autonomy trust ladder: `human` (today's behaviour — a human approves and merges), `agent-approves` (the Approver App reviews; a human still merges), `agent-merges-routine`/`agent-merges-all` (the Script itself lands an eligible pull request — see `merge_autonomy_routine_sources` — and a human's residual act narrows to whatever the classifier refused). A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Every...[continued below](#extended-notes-merge_autonomy) |
| `merge_budget_per_day` | `8` | D18's spend governor: a rolling-24-hour cap on pull requests this pipeline may land in one repository, counted from GitHub's own merged-PR record. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). `0` means unlimited. Reaching the cap approves a pull request but does not merge it — the backlog queues visibly; landing more than the cap is a counting anomaly that freezes the repository to `agent-approves` and escalates to a human. |
| `merge_autonomy_routine_sources` | `["register-hygiene", "tech-debt"]` | D18 WI-7: which work sources may be armed automatically at `agent-merges-routine` and above — a pull request also needs a `complexity:*` grade in `merge_autonomy_routine_complexity`, and — below `agent-merges-all` — to touch no protected path; at `agent-merges-all` a protected-path hit is deferred to the critical-tier and `landing_cool_off_hours` controls rather than refused. A `repos[]` entry may override this per repository — see...[continued below](#extended-notes-merge_autonomy_routine_sources) |
| `merge_autonomy_protected_paths` | `[".github/*", "deploy/*", "prompts/*", "lib/*", "config.schema.json", "config.json", "agent-cycle.sh", "review-cycle.sh", "CODEOWNERS"]` | D18 Stage 3: the whole-path prefixes a routine-tier landing must touch none of — below `agent-merges-all` a hit refuses outright; at `agent-merges-all` it is deferred to the critical-tier and `landing_cool_off_hours` controls instead. An entry ending `/*` matches a whole-path prefix; any other entry matches an exact path. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Defaults to agent-ops's own gate paths, which...[continued below](#extended-notes-merge_autonomy_protected_paths) |
| `merge_autonomy_routine_complexity` | `["low", "medium"]` | D18 Stage 3: which `complexity:*` grades may be armed automatically at `agent-merges-routine` and above — a pull request also needs a `source` in `merge_autonomy_routine_sources`, and — below `agent-merges-all` — to touch no protected path. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Widening past the default to include `high` is a bigger step than it looks: requirement 26a already forces `high` onto the riskiest...[continued below](#extended-notes-merge_autonomy_routine_complexity) |
| `landing_cool_off_hours` | `24` | D18 WI-12 (Stage 4): the wait, in hours, between the Approver's own approval of a protected-path pull request and the arming step landing it — only at `agent-merges-all`, and only alongside the critical-tier control. Measured from the standing review's own timestamp, re-read fresh every cycle; a fresh push restarts it, since the standing review's own commit no longer matches the pull request's current head. A `repos[]` entry may override this per repository — see...[continued below](#extended-notes-landing_cool_off_hours) |
| `approver_app_id` | *(unset)* | The Pullwright Approver GitHub App's id. Every `merge_autonomy` level above `human` needs it set, and `scripts/doctor.sh` fails the config otherwise. `doctor.sh` also cross-checks it against the node's `PULLWRIGHT_APPROVER_APP_ID` environment, so the id the token wrapper mints against can never silently differ from the one recorded here. One id for the whole App identity: which of that App's installations mints a given repository's token is resolved separately, per repository...[continued below](#extended-notes-approver_app_id) |
| `crash_loop_after` | `4` | Consecutive fleet-wide failures, with no intervening recovery, before the Script files a crash-loop escalation issue — either same-detail Co-Ordinator failures, or same-exit-code cycles that died before any stage started. Neither class blames a repo or an item, so without this nothing ever surfaces a deterministic fleet-wide failure — the dashboard shows a healthy idle fleet. `0` (or absent) disables both checks. |
| `crash_loop_repo` | `Poetic-Poems/agent-ops` | Where the crash-loop escalation issues are filed — the pipeline's own repository. Deduplicated like an Enabler escalation and assigned to `enabler_assignee`, so the pipeline never selects its own SOS as work. Empty disables both checks. |
| `escalation_webhook_url` | *(unset)* | A webhook URL, POSTed to as a fallback whenever the pipeline cannot file an escalation issue on GitHub — most often a dead `GH_TOKEN`, which also blocks the filing call itself. Carries the same `reason`/`detail` the issue would have. Empty (the default) disables it: nothing is attempted, and a node with no webhook configured behaves exactly as before. Setting it takes a second edit each node: the webhook's host must also be named in that node's `EGRESS_EXTRA_ALLOW`, or the...[continued below](#extended-notes-escalation_webhook_url) |
| `timeout_coordinator` | *(unset)* | Minutes, and an override. Leave it out — the backstop tunes itself, and a key set here outranks the derivation for as long as it is there. A repo entry's own `stage_timeouts` outranks this key in turn, for that repo alone — see [`repos`](#extended-notes-repos). |
| `timeout_implementer` | *(unset)* | Minutes, and an override. As above. |
| `timeout_reviewer` | *(unset)* | Minutes, and an override. As above. |
| `timeout_enabler` | *(unset)* | Minutes, and an override. As above. |
| `timeout_refiner` | *(unset)* | Minutes, and an override. As above. |
| `timeout_approver` | *(unset)* | Minutes, and an override. As above. |
| `inactivity_coordinator` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. A repo entry's own `stage_inactivity` outranks this key in turn, for that repo alone — see [`repos`](#extended-notes-repos). |
| `inactivity_implementer` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `inactivity_reviewer` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `inactivity_enabler` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `inactivity_refiner` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `inactivity_approver` | *(unset)* | Minutes of total silence before the stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `lock_stale_after` | *(unset)* | Hours, and a floor rather than the value. The threshold is derived from the stage backstops plus slack, so it moves with them; set this only to insist on something longer. |
| `stage_budget` | *(unset)* | Tuning for how the stage budgets derive themselves. Every key has a default in the code and none of them is a timeout; you almost certainly want none of it. |
| `limit_cooldown_default` | `3` | Hours. Stand-down after a usage-limit error. |
| `limit_escalate_after_hours` | `24` | Hours. How long an automatic usage-limit stand-down may run before an escalation issue is filed; `0` turns it off. A manual stand-down never escalates. |
| `github_min_core_budget` | `300` | GitHub REST points a cycle must have left before it starts. `0` turns the check off for this resource. |
| `github_min_graphql_budget` | `100` | GitHub GraphQL points a cycle must have left before it starts. `0` turns the check off for this resource. |
| `github_retry_max_wait_seconds` | `60` | Seconds. How long a single `gh` call may wait out a rate-limit refusal before failing; a process may spend twice this in total. `0` turns retrying off. |
| `min_free_workspace_bytes` | `2147483648` | Bytes. Free space `workspace_root` must have before a cycle starts one; below it the cycle stands down before cloning. `scripts/doctor.sh` warns on the same floor. `0` turns the check off. |
| `disable_default_ttl` | *(unset)* | Hours. How long `--disable` lasts when neither `--for` nor `--until` says, derived from `schedule.cycle_interval_minutes` to stay 4 firings wide at whatever cadence is configured (requirement 1d); a configured value floors it, never caps it. See [Pausing the pipelines](#pausing-the-pipelines). |
| `none_selected_recheck_hours` | *(unset)* | Hours. The Co-Ordinator is engaged at least this often even when nothing has changed — derived from `schedule.cycle_interval_minutes` to stay 24 firings wide at whatever cadence is configured (requirement 1d); a configured non-zero value floors it, never caps it. See [Skipping no-op cycles](#skipping-no-op-cycles). `0` disables that safety net entirely — not recommended — and is never raised by the derivation. |
| `image_behind_grace_hours` | `3` | Hours a node may sit behind the newest published image before the dashboard's **image behind** badge turns amber and `scripts/check-node-image.sh` exits non-zero. A roll defers while a cycle is in flight, so being behind an image published more recently than this is the ordinary mid-roll state. See [Is this node on the newest image](deploy/docker/README.md#is-this-node-on-the-newest-image). |
| `updater_stuck_after_minutes` | `20` | Minutes a container may still be the one that was told to roll before the dashboard's **updater stuck** badge turns amber (`deploy/docker/watchtower-pre-update.sh`, `lib/updater-health.sh`). Comfortably beyond one watchtower poll (`WATCHTOWER_POLL_INTERVAL`, 300s) plus an image pull, so an ordinary roll never trips it. |
| `dashboard_refresh_seconds` | `5` | Seconds. How often an open dashboard tab reloads to pick up freshly-written data, matching the [heartbeat](#keep-it-fresh) cadence. Untick the page's *auto-refresh* box to pause it while reading. |
| `schedule.cycle_hours` | `*` | The hour field of the containerised node's implementation-cycle crontab line (`deploy/docker/render-crontab.sh`); `*` means every hour. |
| `schedule.cycle_interval_minutes` | `15` | Minutes between implementation-cycle firings within an allowed hour (the no-op short-circuit keeps an idle firing cheap); `60` fires once per hour, as every release before this key existed. |
| `schedule.excluded_minutes` | `[0]` | Minutes the per-node `CYCLE_MINUTE` (env or hash) may never land on. This repo's own config excludes `0` because poetic's hourly sync workflow owns the top of the hour; a fresh install with no such conflict should ship `[]`. |
| `schedule.excluded_minutes_reason` | see `config.json` | Free-text note on *why* `excluded_minutes` excludes what it does — documentation only, read by nobody. |
| `schedule.review_hour` | `3` | The hour the containerised node's review tick fires. |
| `schedule.review_offset_minutes` | `29` | Minutes past `CYCLE_MINUTE` (mod 60) the review tick's minute is set to, so the node's two heavy pipelines land apart within the hour. |
| `schedule.heartbeat_minutes` | `5` | Interval, in minutes, of the containerised node's dashboard-heartbeat cron line. |
| `schedule.state_sync_push_minutes` | `5` | Interval, in minutes, of the containerised node's `state-sync.sh push` line. |
| `schedule.state_sync_fetch_minutes` | `7` | Interval, in minutes, of the containerised node's `state-sync.sh fetch` line. |
| `schedule.log_rotation_minute` | `19` | The minute past every hour the containerised node's `rotate-logs.sh` line runs. |
| `schedule.doctor_offset_minutes` | `44` | Minutes past `CYCLE_MINUTE` (mod 60) the hourly unattended `doctor.sh` pass's minute is set to (agent-ops#543), on the same per-node jitter `review_offset_minutes` uses. |
| `schedule.revert_rate_hour` | `2` | The hour the containerised node's daily revert-rate publishing tick (`scripts/publish-revert-rate.sh`, agent-ops#579) fires. |
| `schedule.revert_rate_offset_minutes` | `51` | Minutes past `CYCLE_MINUTE` (mod 60) the daily revert-rate publishing tick's minute is set to (agent-ops#579), on the same per-node jitter `doctor_offset_minutes` uses. |
| `revert_rate_baseline` | `{"source": "docs/reviews/2026-08-15-merge-autonomy-baseline.md", "generated": "2026-08-15", "repos": [{"slug": "Poetic-Poems/poetic", "count": 84, "reverts": 0, "follow_up_fixes": 31}, {"slug": "Poetic-Poems/poetic-fiddle", "count": 119, "reverts": 0, "follow_up_fixes": 44}, {"slug": "Poetic-Poems/agent-ops", "count": 120, "reverts": 0, "follow_up_fixes": 106}]}` | The D18 Stage 0 merge-autonomy baseline, copied once from `docs/reviews/2026-08-15-merge-autonomy-baseline.md` rather than re-derived — `scripts/publish-revert-rate.sh` compares every window's rate against it. A fresh install ships no baseline until Stage 0 records one. |
<!-- config-table:end -->

Every `*_model` key above, plus `project_review.defaults.model` (or a repo's
own override) below, also accepts a
provider-qualified id — `anthropic/claude-sonnet-5` alongside the bare
`claude-sonnet-5` — with identical behaviour; the qualifier is optional
because Anthropic is the only executable provider today. A qualifier naming
any other provider is rejected at cycle start with an error naming the key,
not passed to the `claude` CLI. No existing config needs to change.

The `project_review` object configures the separate repository-review pipeline — see [Repository review](#repository-review).

<!-- config-table:notes id=main — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not this section -->

### Extended notes: `repos`

Array of `{"slug": "...", "sources": [...]}`. `sources` is that repo's work sources in priority order (`security`, `issues:urgent`, `review-feedback`, `merge-conflicts`, `dequeued`, `human-visibility`, `abandoned-drafts`, `failed-runs`, `issues:high`, `tech-debt`, `issues:medium`, `implementation-plan`, `project-review`, `issues:low`, `code-quality`, `register-hygiene`).

- `security` (open Dependabot + security code-scanning alerts) is always first, and any security-related item is prioritised ahead of all non-security work.
- `issues:urgent` comes second and likewise outranks the repo walk, because an issue you have marked `Urgent` is the strongest thing you can say short of a security alert.
- `review-feedback` (agent PRs where you asked for changes we haven't answered yet) comes third and also outranks the repo walk — finishing beats starting, and a stuck PR otherwise occupies a back-pressure slot forever.
- `merge-conflicts` (agent PRs otherwise ready for review or merge but conflicting with their base) comes fourth for the same reason — a rebase-and-resolve unblocks a PR you are waiting to land, and nothing else on it can proceed until it merges cleanly.
- `dequeued` (agent PRs GitHub's merge queue removed over a merge-group checks failure without merging) comes fifth, alongside `merge-conflicts`: a real defect in the pull request itself, of the same "finishing beats starting" kind, just surfaced by the queue's speculative merge rather than by git.
- `human-visibility` (an agent PR the sweep could not confirm a human was actually asked to review, or nudge, after `human_nudge_idle_hours` idle) comes sixth, ranked with the sources around it rather than beside `register-hygiene`: finished work invisible to the human whose merge everything waits on is the same "finishing beats starting" gap, not a cosmetic repair.
- `abandoned-drafts` (draft PRs this system raised and then left untouched past `abandoned_draft_after_hours`) comes seventh for the same reason — finishing a stalled draft of ours turns a slot silted with a dead draft into a PR you can merge.
- `project-review` (the latest repository review's recommendations that aren't already tech-debt or issues) sits just above `issues:low` and `code-quality` (non-security code-scanning findings).
- `register-hygiene` (the repo's tech-debt register failing its own consistency check — an item file whose frontmatter disagrees with its filename, its declared scope, or itself) is last, because a deterministic cosmetic repair must never outrank real work, and each repo's `tech-debt-register` CI check keeps its volume near zero anyway.

The four `issues:<band>` tokens are the *same* source at four ranks, banded by each issue's `Priority` field — see "Issue priority" below; list a subset to have the pipeline see only those bands, or none to turn issues off for that repo. Adding a repo or source is a config-only change.

At runtime, repos are ordered most-overdue first — each repo's default-branch staleness age scaled by `1.25^(-nice)` — ahead of this list order; with no `nice` set anywhere that is least-recently-updated first, exactly as before.

A repo entry that lists `implementation-plan` must also carry `implementation_plan_path` — the path, relative to that repo's root, of its plan document (poetic-fiddle's is `docs/IMPLEMENTATION-PLAN.md`); the Co-Ordinator reads whatever this says, so a repo with a differently named or located plan needs no prompt change, only its own path. The Script refuses to start a cycle if a repo lists the source without it — a repo that doesn't list `implementation-plan` needs no such key.

A repo entry may also carry `nice` — an optional integer from `-19` to `19` (absent means `0`), after Linux `nice`: each repo's default-branch staleness age is multiplied by `1.25^(-nice)` (each step of `nice` is a 1.25x change in attention), so a negative value buys the repo earlier attention and a positive one later. It biases the walk but never starves a repo — the global tiers still outrank the walk, and a repo that alone has qualifying work is selected regardless of its `nice`. The Script refuses to start a cycle if `nice` is not an integer in that range.

A non-zero `nice` shows as a badge against that repo in the dashboard's work-sources panel, naming the value and the weighting it buys; a repo at `0` or with no key shows nothing there, so a fleet that has set none sees the panel unchanged.

A repo entry may also carry `stage_timeouts` and `stage_inactivity` — the per-repo form of the `timeout_<actor>` and `inactivity_<actor>` keys below, each an object in minutes keyed `coordinator`, `implementer`, `reviewer`, `approver` and `enabler`, any subset of them. The Refiner spans repos, so it has no per-repo form and takes `timeout_refiner` / `inactivity_refiner` only. A repo's entry is the most specific level of the precedence — this entry, then the fleet-wide key, then the derived value — so set one only to insist on a number for one repo; omit them and both the backstop and the watchdog tune themselves. `scripts/doctor.sh`'s pinned-cap warning covers every level, naming the repo for a per-repo override.

A repo entry may also carry `merge_autonomy` — the per-repo override of the top-level key of the same name, on the same precedence: this entry wins when present, the top-level key otherwise. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `merge_budget_per_day` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `merge_autonomy_routine_sources` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `merge_autonomy_protected_paths` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default (today's nine agent-ops paths) — a repository whose own gate code lives elsewhere should name its own list rather than inherit agent-ops's.

A repo entry may also carry `merge_autonomy_routine_complexity` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `landing_cool_off_hours` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

A repo entry may also carry `escalation_autonomy` — the per-repo override of the top-level key of the same name, on the same precedence. Omit it and the repository follows the fleet-wide default.

Every optional key goes on the repo's own entry, beside `slug` and `sources`:

```json
"repos": [
  {
    "slug": "Poetic-Poems/poetic",
    "sources": ["security", "issues:urgent", "tech-debt", "issues:low"]
  },
  {
    "slug": "Poetic-Poems/poetic-fiddle",
    "sources": ["security", "issues:urgent", "implementation-plan", "issues:low"],
    "implementation_plan_path": "docs/IMPLEMENTATION-PLAN.md",
    "nice": -5,
    "stage_timeouts": { "implementer": 90 },
    "stage_inactivity": { "implementer": 20 }
  }
]
```

Each of them is set by editing `config.json`, like every other key here — see [Configuration](#configuration) for how that edit reaches a fleet already running.

### Extended notes: `escalation_autonomy`

The D18 escalation-autonomy ladder, three rungs, each including the one below it (with one exception, below): `always-escalate` (today's behaviour — every Enabler escalation goes straight to a human), `adjudicate-first` (one bounded Enabler adjudication pass runs first, but only over a refinement disagreement; it either confirms the earlier refinement or escalates anyway), or `decide-tactical` (one bounded Enabler decide pass runs first over *any* escalation — an ordinary blocked item as much as a refinement disagreement — and either settles it, decides a tactical trade-off on the pipeline's own authority, or escalates anyway; an owner-only decision always escalates, at every rung). A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos).

The same setting also governs a second, independent case: a Reviewer's own open question about a pull request's work order or scope (D18, agent-ops#668). That path runs its own bounded pass only at `adjudicate-first` exactly — `decide-tactical` behaves the same as `adjudicate-first` there, not a further widening — so you cannot enable one Enabler-side rung without also getting the open-question path at its `adjudicate-first` behaviour.

### Extended notes: `needs_refinement_label`

Label put on an **issue** while the pipeline has it recorded as too under-specified to work on, and taken off again when that clears — see [Items nobody has specified](#items-nobody-has-specified). You can also apply it yourself to flag one directly; the pipeline reads that back the same way.

The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up; without it the item is still recorded and still reaches the Enabler, you just do not see it in the issue list, and a label you apply yourself does nothing.

Leave it empty to switch the labelling off in both directions.

Do not set it to `blocked`, which is a label that excludes an issue from the pipeline's work source, nor to `obsolete`, which is reserved for a human to mark one of the pipeline's own draft pull requests as unwanted.

### Extended notes: `refined_label`

Label put on an **issue** once the Refiner has written it a specification — see [Refined items and the Refiner](#refined-items-and-the-refiner). Purely informational: nothing reads it back, so removing it by hand does nothing.

The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours` — so there is nothing to set up.

Leave it empty to switch the labelling off; the item is still recorded as refined and the Co-Ordinator still reads that record.

Do not set it to `blocked`, which is a label that excludes an issue from the pipeline's work source, nor to `obsolete`, which is reserved for a human to mark one of the pipeline's own draft pull requests as unwanted.

### Extended notes: `refinement_policy`

Per source: `required` (never select unrefined), `preferred` (rank refined items first, but an unrefined one may still be picked), or `exempt` (no refinement dimension — the default for every source not listed). Shipped default: `issues` and `tech-debt` both `preferred` — the two sources whose items can otherwise carry a specification the Co-Ordinator composed itself rather than one already written elsewhere (a merge conflict, a review comment, a security finding). See [Refined items and the Refiner](#refined-items-and-the-refiner). Every source the Refiner's own candidate gathering reads — `issues`, `security`, `code-quality`, `review-feedback`, `abandoned-drafts`, `merge-conflicts`, `dequeued`, `register-hygiene`, `tech-debt`, `project-review` and `implementation-plan` — reaches an engagement; the latter two are read only for a repo whose `sources` lists them and whose policy for them is not itself `exempt`. A `required` source with `refiner_model` empty is refused at startup (requirement 1c).

### Extended notes: `unvoid_label`

The label you apply on GitHub to ask for a voided item to be reopened — see [Blocked and void items](#blocked-and-void-items). No stage ever applies it, so "only a human may clear a void" still holds; this is just a way to say so from the issue itself. The pipeline creates it in every repository it gathers data for, not only the one it happens to work, at most once per `labels_ensure_interval_hours`; `scripts/doctor.sh` warns while a repo has not got it yet. Do not set it to `blocked` or `obsolete`.

### Extended notes: `coordinator_prompt_max_bytes`

The largest assembled prompt the Script will hand the Co-Ordinator. What a context window rejects is the whole prompt, not the runtime input alone, so the Script measures the rendered base prompt, subtracts it, and trims the two bands that carry a whole document each — an issue's entire thread and a tech-debt issue's entire thread — into what is left. Prose is shed and candidacy is not: every entry stays selectable, and every cut carries a marker naming how many bytes went and the URL to read it whole. Raise it for a Co-Ordinator model with a larger context window; `0` disables the bound, which is how every release before this key behaved.

### Extended notes: `merge_autonomy`

The D18 merge-autonomy trust ladder: `human` (today's behaviour — a human approves and merges), `agent-approves` (the Approver App reviews; a human still merges), `agent-merges-routine`/`agent-merges-all` (the Script itself lands an eligible pull request — see `merge_autonomy_routine_sources` — and a human's residual act narrows to whatever the classifier refused). A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Every level above `human` needs `approver_app_id` and `approver_model_default` set, and a human `CHANGES_REQUESTED` blocks landing regardless of level.

### Extended notes: `merge_autonomy_routine_sources`

D18 WI-7: which work sources may be armed automatically at `agent-merges-routine` and above — a pull request also needs a `complexity:*` grade in `merge_autonomy_routine_complexity`, and — below `agent-merges-all` — to touch no protected path; at `agent-merges-all` a protected-path hit is deferred to the critical-tier and `landing_cool_off_hours` controls rather than refused. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Takes `landingSourceToken`s, not the `sourceToken`s `repos[].sources` takes: issue work is the plain `issues` here, never `issues:<band>`, because banding is spent at gathering time and a finished work order carries the bare word.

### Extended notes: `merge_autonomy_protected_paths`

D18 Stage 3: the whole-path prefixes a routine-tier landing must touch none of — below `agent-merges-all` a hit refuses outright; at `agent-merges-all` it is deferred to the critical-tier and `landing_cool_off_hours` controls instead. An entry ending `/*` matches a whole-path prefix; any other entry matches an exact path. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Defaults to agent-ops's own gate paths, which govern nothing outside agent-ops itself.

### Extended notes: `merge_autonomy_routine_complexity`

D18 Stage 3: which `complexity:*` grades may be armed automatically at `agent-merges-routine` and above — a pull request also needs a `source` in `merge_autonomy_routine_sources`, and — below `agent-merges-all` — to touch no protected path. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). Widening past the default to include `high` is a bigger step than it looks: requirement 26a already forces `high` onto the riskiest class of diff (concurrency/locking, security, CI/workflow machinery, shared library code), so admitting it here routes exactly that class through automatic landing, with the protected-path list as the remaining belt-and-braces control.

### Extended notes: `landing_cool_off_hours`

D18 WI-12 (Stage 4): the wait, in hours, between the Approver's own approval of a protected-path pull request and the arming step landing it — only at `agent-merges-all`, and only alongside the critical-tier control. Measured from the standing review's own timestamp, re-read fresh every cycle; a fresh push restarts it, since the standing review's own commit no longer matches the pull request's current head. A `repos[]` entry may override this per repository — see [Extended notes: `repos`](#extended-notes-repos). `0` disables the wait.

### Extended notes: `approver_app_id`

The Pullwright Approver GitHub App's id. Every `merge_autonomy` level above `human` needs it set, and `scripts/doctor.sh` fails the config otherwise. `doctor.sh` also cross-checks it against the node's `PULLWRIGHT_APPROVER_APP_ID` environment, so the id the token wrapper mints against can never silently differ from the one recorded here. One id for the whole App identity: which of that App's installations mints a given repository's token is resolved separately, per repository owner, from the `PULLWRIGHT_APPROVER_INSTALLATION_IDS`/`PULLWRIGHT_APPROVER_INSTALLATION_ID` environment (agent-ops#913) — never from this key.

### Extended notes: `escalation_webhook_url`

A webhook URL, POSTed to as a fallback whenever the pipeline cannot file an escalation issue on GitHub — most often a dead `GH_TOKEN`, which also blocks the filing call itself. Carries the same `reason`/`detail` the issue would have. Empty (the default) disables it: nothing is attempted, and a node with no webhook configured behaves exactly as before. Setting it takes a second edit each node: the webhook's host must also be named in that node's `EGRESS_EXTRA_ALLOW`, or the egress fence answers every POST with a `403` and the node is as silent as it was before the webhook existed.

<!-- config-table:notes-end -->

### Prompt overrides

`prompts/*.md` are this product's own content — they ship with every image
and every `git pull`. Editing one directly is a fork: it stops receiving this
repository's future updates to that stage. `prompt_overrides` in
`config.json` lets you add to, or replace, any stage's prompt from files that
live outside `prompts/`, so an installation's house rules survive an update
instead of needing to be re-applied after every one.

```json
"prompt_overrides": {
  "coordinator": {
    "extend": ["prompt-overrides/coordinator-house-rules.md"]
  },
  "implementer": {
    "extend": ["prompt-overrides/implementer-house-rules.md"]
  }
}
```

Keys are stage names — `coordinator`, `implementer`, `reviewer`, `enabler`,
`refiner` — each holding:

- **`extend`** — an array of file paths, appended to the stage's prompt in
  the order listed, after everything `prompts/<stage>.md` already says. This
  is the mode to reach for: it adds guidance without touching a single byte
  of the shipped prompt, so it can never fall out of sync with an update to
  it. Each fragment is wrapped with a fixed reminder that this repository's
  specs (`docs/*-SPEC.md`) outrank every prompt — an extension may add
  guidance, it cannot exempt your installation from a numbered requirement.
- **`replace`** — a single file path substituted for `prompts/<stage>.md`
  itself, before any `extend` fragments are appended. **Use this rarely, and
  know what it costs**: a replaced prompt stops receiving this product's
  updates to that stage's behaviour entirely — every future fix or new
  capability that ships in `prompts/<stage>.md` passes your installation by
  until you re-merge it by hand. `extend` covers nearly everything a house
  rule needs; reach for `replace` only when a stage's approach itself, not
  just its guidance, needs to differ.

There is deliberately no `approver` key. The Approver's adversarial prompt
is the gate the merge-autonomy trust ladder rests on: letting an
installation extend or replace it would soften the one check every
autonomous landing depends on, so its prompt is this product's own content
at every trust level.

A relative path in either key resolves against `state_dir` (the default
`~/.local/state/poetic-agents`), not the agent-ops working tree — the one
location this repository guarantees survives an image roll on a container
node and a `git pull` on the host, so your override content is never at risk
of being overwritten by an update the way a change committed to `prompts/`
would be. An absolute path, or one starting `~/`, is honoured as given. A
path that does not resolve to a readable file is treated as if it were
absent — a typo in a *path* does not fail a cycle. A typo in the
*structure* does, at startup: an unknown stage key, a string where
`extend`'s array is meant, or a misspelled `extend`/`replace` would each be
silently ignored if tolerated — you would get today's exact shipped prompt
with no indication why — so `agent-cycle.sh` refuses to start until
`prompt_overrides` is an object keyed only by the five stage names, each
holding only `extend` (an array of strings) and/or `replace` (a string).
For the `coordinator` and `enabler`
stages, that is still visible: a configured file going missing (or a new one
appearing, or an existing one changing) moves the hash the no-op
short-circuit tracks (see [Skipping no-op cycles](#skipping-no-op-cycles)),
so a broken path shows up as an unexplained Co-Ordinator or Enabler run
rather than being silently swallowed. `implementer` and `reviewer` overrides
need no such tracking — those stages only ever run once an item is already
selected, so nothing about them feeds the "is there anything new to do at
all" decision.

Leaving `prompt_overrides` out of `config.json` entirely — or a stage out of
it — reproduces today's exact prompt, byte for byte; nothing here changes
behaviour until you configure it. There is no per-repo scoping yet: an
override applies to every repo the stage runs against, because the
Co-Ordinator selects across every configured repo in one invocation per
cycle rather than one per repo.

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
curl -fsSLO "https://raw.githubusercontent.com/Poetic-Poems/agent-ops/main/scripts/watch-node.sh"
chmod +x watch-node.sh
$EDITOR .env          # name the node, set its role, paste its tokens
docker compose up -d
docker compose exec scheduler claude   # authenticate this node, once
```

The node holds those four files and no clone. On a fresh cloud VM,
[`deploy/docker/cloud-init.yaml`](deploy/docker/cloud-init.yaml) does all of
that unattended except the Claude login. `watch-node.sh` is how you follow its
pipeline output afterwards — see [Watching a node's
events](#watching-a-nodes-events).

Each image tag is a manifest list covering `linux/amd64` and `linux/arm64`, so
`docker compose up -d` pulls the right one on an x86-64 or an arm64 host —
including the cheaper arm instance classes — with nothing to choose.

`COMPOSE_PROFILES` in that `.env` decides what the node runs:

| Profile | What it adds |
|---|---|
| `tailnet` | Tailscale sidecar + the dashboard, served to your tailnet over HTTPS at `https://<node>.<tailnet>` — never to the public internet |
| `local` | the dashboard on the machine's own loopback instead (`http://127.0.0.1:8787`), for a node with no tailnet or no authkey |
| `auto-update` | watchtower, which pulls new images and restarts into them |

The scheduler is in no profile: it runs on every node, whatever else does.

Five things are worth knowing:

- **`/app` is the deployment.** The image is built from this repository, so a
  node updates by pulling a new image — never by pulling a branch inside a
  running container. Every merge to `main` that touches anything the container
  reads builds one and publishes it to
  `ghcr.io/poetic-poems/agent-ops` as `latest` (what watchtower follows) and as
  the commit SHA. To pin a node to a known-good build, or to roll one back, set
  `AGENT_OPS_IMAGE=ghcr.io/poetic-poems/agent-ops:<sha>` in its `.env` — a
  documentation-only merge publishes nothing, so pin to a commit that built an
  image (the package's tag list is the record).
- **`~/.claude` and `state_dir` must be volumes.** Claude's OAuth credentials
  refresh and write back, and `state_dir` is the pipelines' memory. The
  entrypoint seeds `settings.json` only when it is absent, and refuses to start
  if `state_dir` is not writable by the container user (uid 1000 by default;
  rebuild with `--build-arg PUID=…` to match a host directory).
- **Authenticate once per node**: `docker compose exec scheduler claude` and
  complete the login. Until then every cycle fails at its first stage; the
  entrypoint warns about it on each start. This is the one interactive step in
  an otherwise non-interactive bring-up (D4) — every other credential,
  including GitHub's, arrives as a plain `.env` value read at container start,
  never by `exec`-ing into a running one. GitHub's own identity can be
  upgraded the same way, entirely optionally: the forge authoring App (D18
  decision 1, `.env.example`'s "Forge authoring App" section) mints
  short-lived tokens in place of the `GH_TOKEN` PAT once an owner provisions
  it; unset, a node just keeps authenticating with `GH_TOKEN`, exactly as
  before this existed.
- **The dashboard is never reachable from a network.** The `tailnet` profile
  puts the server in the Tailscale sidecar's network namespace, so Serve can
  proxy to its loopback and nothing else can; the `local` profile publishes it
  to the host's loopback alone (`127.0.0.1:${DASHBOARD_PORT:-8787}:8787`). If
  the host already has something on 8787, set `DASHBOARD_PORT` in `.env` — it
  moves the host side of that mapping.
- **Set the Vercel variables if you want the stages to check preview
  deployments.** poetic-fiddle deploys every pull request to Vercel, and that
  deployment reports through GitHub's deployments API rather than as a check
  run — so a pull request can be entirely green over a preview that never
  built. `scripts/preview-deploy.sh` is what the Implementer and Reviewer run
  to find out, and it needs `VERCEL_AUTOMATION_BYPASS_SECRET` in the node's
  `.env` (Vercel → the project → Settings → Deployment Protection → Protection
  Bypass for Automation), because preview deployments sit behind Vercel
  Authentication and answer a login page to anything without it.
  `VERCEL_TOKEN` is optional on top and buys the build log when a deployment
  failed. Leave both empty and nothing changes: the stages report that the
  preview could not be checked, which is never a reason to block an item.

Set `ROLE=active` in the `.env` of every node meant to spend — any number may
be, since per-item claims keep them off each other's work (see
[Which node runs the cycles](#which-node-runs-the-cycles)); the rest stay
`standby`. Then read
[deploy/docker/README.md](deploy/docker/README.md) for everything after that.

### The egress fence

The scheduler — the container that runs `claude` over text anyone on GitHub
can author, with live credentials in its environment — reaches the internet
only through the `egress-proxy` service's domain allowlist
(`deploy/docker/egress-allowlist.txt`; roadmap decision D24). The fence is
topology, not convention: the scheduler sits on an internal-only Docker
network with no gateway, and the proxy is the one way out, permitting only
HTTPS to the domains the pipelines actually use — GitHub, the Anthropic API,
Vercel previews, the npm registry and its build-time font fetches, and the
image registry. Everything else is refused, including all of Claude Code's
optional traffic (updates, telemetry, error reporting), which the
scheduler's environment turns off at the source.

**Rolling it onto an existing node** — the fence is compose-level, so no
image roll delivers it (the node's own heartbeat reports the compose drift
until you act):

```sh
cd ~/agent-ops   # wherever this node keeps compose.yaml and .env
base=https://raw.githubusercontent.com/Poetic-Poems/agent-ops/main/deploy/docker
curl -fsSLO "$base/compose.yaml"
docker compose pull && docker compose up -d
docker compose exec scheduler /app/scripts/doctor.sh --offline || true
docker compose exec scheduler /app/scripts/doctor.sh   # Egress section: three [ ok ] lines
```

Mind the timing: `up -d` recreates the scheduler, so run it between cycles
or accept losing the one in flight (the watchtower pre-update hook does not
guard a manual `up -d`).

**A node needing an extra domain** — a Vercel project serving previews from
a custom domain is the expected case — names it in its `.env`:

```sh
EGRESS_EXTRA_ALLOW=preview.example.com
```

comma- or whitespace-separated, then `docker compose up -d egress-proxy`.
Fleet-wide additions belong in `deploy/docker/egress-allowlist.txt` instead,
where each entry states the code that needs it and
`test/egress-fence.test.sh` pins the set.

**If everything times out after enabling the fence**, check `DOCKER_MTU`
before blaming the allowlist: an MTU black hole through the proxy looks
exactly like a refused domain (compose.yaml's own MTU note tells you how to
set it). `scripts/doctor.sh`'s Egress section tells the three failure shapes
apart — proxy path broken, allowlist not enforcing, or direct egress still
open because this node's compose.yaml predates the fence.

There is deliberately no off-switch variable: unfencing a node is an edit to
its compose.yaml, made knowingly or not at all.

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

   *Alternative (Windows Task Scheduler):* Create a task running `wsl.exe -u wallen -e $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh` on the node's configured cadence (`schedule.cycle_interval_minutes`).

4. **Labels: nothing to do.** The pipeline creates the labels it uses — the PR
   label, the Enabler's escalation label, `needs-refinement`, `refined`,
   `unvoided`, the `complexity:*` grades, `blocked`, `blocked:needs-refinement`,
   `obsolete` and `pw::type:tech-debt` — in every repository it gathers data
   for, not only the one it happens to work, at most once per
   `labels_ensure_interval_hours` (default 24h), and puts back any you later
   delete within that interval. It only ever *creates*: a label you have
   recoloured or re-described keeps your version.

   All the token needs is permission to create them. If one is still missing
   after `labels_ensure_interval_hours` has passed since a cycle last gathered
   that repository, that permission is what to check — `./scripts/doctor.sh`
   names each absent label and says so.

5. **Enable the security work sources on both repos.** The `security` and `code-quality` sources read GitHub's own Dependabot alerts and code-scanning (CodeQL) alerts, so those features must be turned on for the alerts to exist:
   - In each repo's **Settings → Code security**, enable **Dependabot alerts** and **Code scanning** (a default CodeQL setup is fine). Free for public repos; private repos need GitHub Advanced Security.
   - The `gh` token must be able to read the alerts — the `security_events` scope (or `repo` on a classic token). Verify:
     ```bash
     ./scripts/gather-findings.sh Poetic-Poems/poetic
     ```
     You should get a JSON array of findings (or `[]` if there are none). If a feature is off, the script returns `[]` (exit 0) and the pipeline keeps working — you just won't get findings from that source; a real failure (the token can't read the alerts, a rate limit, an outage) instead exits 1, which the dashboard's work-sources panel shows as "couldn't read" rather than a false zero.

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

## Checking an installation

```bash
./scripts/doctor.sh
```

Checks the whole installation in one pass and says what is wrong before a
cycle finds out the expensive way: your `config.json` against
`config.schema.json`, the rules that hold *between* config keys, the model
ids, the shipped and overridden prompts, the toolchain, the directories the
pipelines write to, the rendered crontab, the GitHub access your token
actually has — including whether it can *push*, not just read — and whether
`claude` is logged in.

Four verdicts:

- **`ok`** — checked and sound.
- **`warn`** — it will run, but something here will surprise you later: a
  label that does not exist in a repo (so the pipeline acts and you never see
  the label), a prompt override pointing at a file that is not there (so that
  stage quietly runs on the shipped prompt), a `timeout_*` or `inactivity_*`
  key set once and forgotten, which pins that cap and turns off its
  self-tuning for good.
- **`fail`** — the pipeline will not run, or will run on something other than
  what you configured. Exit status 1. This is what a repository your token
  can read but not push to gets, and what an archived repository gets
  regardless of permissions — both cost a cycle its work at the push, after
  it has already claimed and implemented the item.
- **`skip`** — the check needed something it could not reach, and is neither
  passed nor failed. `claude auth status` not answering with the expected
  shape — an older CLI with no `auth` subcommand, say — is a `skip`, not a
  `fail`: a probe that cannot answer is not evidence of a fault.

It also renders a trial crontab — `deploy/docker/render-crontab.sh` into a
`mktemp -d` it removes afterwards — against the config being checked, so a
broken template or an impossible `schedule` (every minute of the hour
excluded, say) shows up here rather than on the node's own cron. A clean
render reports the cycle, review, heartbeat and background-timer
(`state_sync_push_minutes`, `state_sync_fetch_minutes`, `log_rotation_minute`)
minutes the config asks for, and says whether the cycle minute came from an
explicit, allowed `CYCLE_MINUTE` or was hashed from the node's name — worth
reading closely on a laptop checking `--config PATH` for a node it is not
running on, since the hash is taken from *this* host's name, not the target
node's. It also lists any repository whose `nice` biases the walk away from
0, naming the multiplier that applies to its effective age.

```bash
./scripts/doctor.sh --offline          # config, toolchain and crontab only, no network
./scripts/doctor.sh --unattended       # full GitHub section, no model spend — what the hourly cron line runs
./scripts/doctor.sh --quiet            # warnings and failures only
./scripts/doctor.sh --config /tmp/new.json   # a config you have not deployed yet
```

Run it after editing `config.json`, on a new node before its first cycle, and
whenever a cycle does something the configuration does not explain. It is
read-only bar three things it declares: the state and workspace directories
your config names, which it creates in order to prove it can; the trial
crontab above, rendered into a `mktemp -d` it removes when done; and, under
`--unattended` only, `state_dir/.doctor-status.json`. Every GitHub
call it makes is a read (a GET, even the one that asks about *write*
access) — so it is safe to run against a live node, including mid-cycle.

A node also runs `--unattended` itself, unprompted, once an hour
(`deploy/docker/crontab.tmpl`) — the same checks above, minus the two that
spend (Claude credentials, the stream-flushing probe), so a configuration gap
that only shows up against a live repository (a `Priority` field missing a
band, say) does not go unseen between one operator-invoked pass and the
next. Its result reaches the **Doctor** section of the dashboard (see
Monitoring below), not your terminal.

That hourly pass also reads how many days remain on this node's fine-grained
PAT — GitHub states its expiry on every authenticated response — and records
it for the dashboard, amber under 7 days; a node whose own token falls under
that threshold escalates once (an issue at the pipeline's configured
destination), the same route a crash loop or a dead credential already
escalates through, so a token's own expiry date is never again a fleet-wide
outage nobody saw coming (agent-ops#691, agent-ops#694).

Inside a container node, run it there rather than on the host, since that is
where the toolchain and the credentials are:

```bash
docker compose exec scheduler /app/scripts/doctor.sh
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
Launches implementer and reviewer in the foreground. Leaves the PR and workspace for inspection.

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
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling out PR #NN"  # expires after disable_default_ttl
docker compose exec scheduler /app/agent-cycle.sh --disable "big refactor" --for 8h  # or 90m, 2d, or `forever`
docker compose exec scheduler /app/agent-cycle.sh --disable "code freeze" --until "2026-08-10 18:00"  # or any GNU date -d string
docker compose exec scheduler /app/agent-cycle.sh --status   # what's set, and is anything running?
docker compose exec scheduler /app/agent-cycle.sh --enable   # resume
```

(From a shell on the node — `docker compose exec scheduler bash` — the bare
`./agent-cycle.sh …` form works, since `/app` is the working directory.)

The switch is one file (`$state_dir/disabled.json`) shared by **both**
`agent-cycle.sh` and `review-cycle.sh` — they run out of the same tree, so
stopping one and not the other stops nothing much. `agent-cycle.sh` is the only
way to set it; `review-cycle.sh` only obeys it. And, by default, it reaches
the whole fleet: `--disable` also publishes `fleet/disabled.json` to the state
repository (warning loudly if it cannot), every node checks that flag at
cycle start, and `--enable` clears both levels — so one command from any
node stands the entire operation down, or up. Add `--this-node` to either to
keep the effect on the node you typed it on — see [Taking one node out while
the rest keep working](#taking-one-node-out-while-the-rest-keep-working).

Three things worth knowing:

- **Disabling stops the *next* cycle, not one already running.** `--status`
  tells you whether a cycle is in flight, and `--disable` warns you if there
  is. Wait for it to finish before recreating a container by hand — a manual
  `up -d` (or `restart`, or `down`) kills a cycle mid-flight. A watchtower
  roll no longer does: its pre-update hook reads the same locks `--status`
  reads and defers the roll until they are free.
- **A disable expires by default.** The point is not tidiness: an agent that
  disables the pipeline and then dies would otherwise stop every future cycle
  silently — "no PRs" looks exactly like a quiet week. The TTL turns a
  forgotten switch into a few lost cycles. Use `--for forever` when you mean
  it, and `--enable` when you're done. `--until <timestamp>` is an absolute
  alternative to `--for`'s relative duration — give both and the later
  deadline wins, with a warning saying which.
- **A reason is required**, because the next person wondering why nothing has
  happened is entitled to one. It shows up in `--status`, in the log, and on
  the dashboard banner.

### Lifting a usage-limit stand-down

The switch is not the only thing that stops cycles. Hitting the account's
usage limit stands the whole fleet down until `resume_at` (requirement 2.1),
and `--enable` does not touch that — they are separate states with separate
causes. `--status` reports both:

```bash
docker compose exec scheduler /app/agent-cycle.sh --status
# switch:   ENABLED — cycles will run
# record:   /home/agent/.local/state/poetic-agents/disabled.json
# cycle:    idle
# review:   idle
# limit:    STANDING DOWN — with no stated reset; each cycle probes whether it has lifted — …
```

When the message states a reset time, `resume_at` is that time and waiting is
the whole answer. When it does not — the monthly spend-cap message is the
common case — `resume_at` is this system's own guess, only an upper bound:
each cycle probes the API with one minimal request (requirement 2.1b) and
retires the stand-down by itself the moment the account answers, so a limit
that was really an exhausted 5-hour session window clears within one cycle
interval of its rollover, not a day later. Such a limit still has two exits,
and you choose:

- **wait**, and let the probe notice the rollover on its own; or
- **raise the cap** at `claude.ai/settings/usage`, then tell the fleet
  without waiting for the next cycle's probe:

```bash
docker compose exec scheduler /app/agent-cycle.sh --clear-limit "cap raised"
```

That clears both carriers of the stand-down — `fleet/limit.json` in the state
repository, and the log union, via a `limit-cleared` event that supersedes the
earlier `limit-hit`. Peers pick it up at their next state-sync fetch. Run it
only once the limit is actually gone: if it is not, the next cycle simply
re-hits it and publishes a fresh stand-down.

Before the probe existed, `resume_at` passing was the only automatic exit, on
a clock the system had invented — so a cap raised in the morning still left
the fleet down until the next day. The probe asks the account itself, every
cycle; `--clear-limit` remains for when you have just raised the cap and want the
fleet back now rather than at the next cycle. The probe's verdict is in the
stand-down reason (`probe: still limited` / `probe: inconclusive`), and its
transcript is kept as `limit-probe.out` in the cycle record. To ask the
account yourself, the probe is just:

```bash
docker compose exec scheduler claude -p 'say ok'
```

## Which node runs the cycles

The pipelines run on any number of machines — a laptop, a cloud VM, several —
and **any number of them may cycle at once**: per-item claims (requirement
17a) keep concurrent actives off each other's work, and per-node minute
offsets (D5) keep them from even firing together. The environment variable
`AGENT_OPS_ROLE` says whether *this* machine spends unattended:

```bash
AGENT_OPS_ROLE=active     # this machine runs the implementation cycle and the daily review tick
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
- `--disable`, `--enable`, `--clear-limit` and `--status` — the switch and the
  usage-limit stand-down are shared state, and must be readable and settable
  from wherever you happen to be.
- The dashboard, which is worth serving on every node.

## Keeping every node warm

A node that knows only its own history would re-try what a peer has already
tried and re-learn every no-op the hard way. So every node publishes its
memory, and every node follows everyone else's.

`scripts/state-sync.sh` works through the private repository named by
`state_repo`, one branch per node, in two modes — both on every node:

| Mode | When | What |
|---|---|---|
| `push` | every five minutes, and at the end of every cycle | publishes `state_dir` as this node's own `nodes/<NODE_NAME>` branch, stamped with a heartbeat (`{node, role, ts, last_cycle, version, compose, image, switch, mirror}`) |
| `fetch` | every seven minutes | materialises every peer's branch under the peers directory, whole, and prunes a peer whose branch is gone |

Before either mode touches its local mirror of the state repository, it
checks that mirror's object store (`git fsck --connectivity-only`) rather
than trusting a `.git/` directory that merely still exists: a host whose
disk has quietly corrupted a loose object gets that checkout discarded and
rebuilt from source on the spot, and the rebuild is recorded in the
heartbeat's `mirror` field so a repeat is visible rather than silent
self-healing.

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
work — about 2½ minutes of Haiku, reading both repos. Firing every
`schedule.cycle_interval_minutes` (15 by default; see [Configuration](#configuration)) instead
of once an hour is only affordable because of this check: without it, a quiet
week would be a Co-Ordinator call roughly every 15 minutes, all of them paid
for, purely to hear "nothing changed" again.

So before launching it, the Script fingerprints everything the Co-Ordinator's
verdict depends on: each repo's head commit, its pre-fetched findings, its open
issues (with labels, assignees and `Priority`), the conclusion of each workflow's latest
run, its open PRs (a PR is a claim), the blocked and void lists, the selection
config, and a hash of `prompts/coordinator.md` and any `prompt_overrides.coordinator`
files you've configured (see [Prompt overrides](#prompt-overrides)). If that fingerprint matches the
one recorded against the last `none-selected`, nothing the Co-Ordinator reads
has moved, so its answer cannot have changed — the cycle stands down for the
price of a few `gh` calls.

The claim is only ever "nothing changed", never "there is no work". If anything
at all is different — including a repo the Script couldn't read cleanly — the
Co-Ordinator runs. And `none_selected_recheck_hours` forces it to run anyway
once that long regardless, so if some future work source is ever missed by
the fingerprint, the cost is a bounded delay rather than a pipeline that has
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
  gone, so usually you need do nothing. A block also clears the moment the
  *work* goes: each cycle, an item whose issue has been closed, whose pull
  request has been merged, whose tech-debt entry now reads `resolved` or
  `not-debt`, whose project-review recommendation is named by a merged pull
  request, or whose implementation-plan task is checked off in the plan
  document, is unblocked deterministically, logged `by: "work-gone"` with the
  fact that decided it. So finishing something by hand is enough to take it off
  the list — you never have to tell the pipeline you did. A block declared with
  a structured [`Blocked-by:`](#cross-item-dependencies) reference clears the
  same way, logged `by: "dependency-resolved"`, the moment every item it names
  is closed.
- **Void** — there is no work: the item is already done, or its premise was
  false. No agent can ever clear this, by design — the only evidence that would
  ever turn up ("it's already done") is the reason it is void, so an agent
  allowed to clear it would free the item to be rediscovered every cycle.

Because a void is permanent, one has to be earned. Every void carries the
evidence behind it, and a Co-Ordinator's void — the only kind made without
opening the repository — is checked before it is recorded: an unevidenced
verdict, or one the cycle's own candidates contradict (the pull request it calls
finished still has a diff), is recorded **blocked** instead and handed to the
Enabler, which can read the repository and settle it properly. You will see the
refusal as a `warning` on the dashboard.

Both are listed on the dashboard. The void list only ever grows, so it is shown
short: the ten newest rows, each three lines tall, with **See more** at the foot
of the table for the older ones and any row opening to its full reason when you
click it. The heading counts every void item however few rows are showing.

The dashboard's own list — and the item's void mark itself — never shrink; what
does is the copy the pipeline hands the Co-Ordinator each cycle. Once a void is
both settled — its issue or pull request closed, or its tech-debt row read
`resolved`/`not-debt` — and `void_retire_after_days` old (30 by default), it
drops out of that copy: there is nothing left for the pipeline to keep
repeating to itself about an item everyone has already finished with. `0`
switches this off. A retirement is recorded in the pipeline's own log, so a
settled verdict is never re-checked against GitHub — and once an item has
retired, reopening its closed issue or pull request is enough by itself to
put it back in front of the pipeline as a fresh, ordinary candidate; the
`unvoided` label below is the route that works while the void is still being
carried.

To reopen a void item — you believe the work has genuinely regressed, or the
verdict was wrong — **label any issue or pull request that names the item with
`unvoided`**, in that item's repo:

```bash
gh pr edit 92 -R Poetic-Poems/poetic --add-label unvoided
```

The next cycle reads the label, works out which items that issue or PR names
(from its branch, title and body — and for an issue, its own number), and
reopens any of them that are void. The item is back in the Co-Ordinator's pool
in that same cycle. Only you can do this: no stage in the pipeline ever applies
this label, which is what keeps "only a human may clear a void" true.

**Leave the label where it is** once it has worked. Nothing removes it, and
nothing needs to: the rule is self-limiting rather than one-shot, so a label
left behind costs nothing. It cannot fire twice: a label only reopens voids
recorded *before* you applied it, so an old label can never quietly clear a
fresh verdict.

If you are on a node, appending the event by hand still works, while no cycle is
running:

```bash
printf '%s\n' "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ts: $ts, cycle: "manual", event: "unvoided", item: "review-2026-07-11-R-02"}')" \
  >> ~/.local/state/poetic-agents/log.jsonl
```

Omit `repo` to reopen the item in every repo, or add it to scope the change to
one. Either way the item becomes a candidate again; if there is still no work,
the Implementer will simply void it again — with evidence this time.

**Keep `cycle: "manual"` exactly as it is** here and in any other event you
append by hand — an `unblocked`, a `limit-hit`. It is not a placeholder for a
missing id; it is the marker that says no cycle produced this record, and the
dashboard reads it as one. Give the event a timestamped id of the real shape
instead and it becomes indistinguishable from a run: the Recent cycles table
grows a row for a cycle that never started, wearing whatever badge an empty
event stream earns. `manual` keeps the record in the log tail, where it
belongs, and out of the cycle list.

### Closing an obsolete draft pull request

A draft pull request the pipeline itself raised — an abandoned draft, or one
still carrying your own unactioned review feedback — can simply stop being
wanted. If it still changes files against its base, the pipeline cannot close
it on its own say-so: `void_finishing_pr_reason` (`lib/void-guard.sh`) accepts
an open pull request as void only when its diff against the base is empty, or
when you have said the draft is unwanted yourself (below), because "this
draft is no longer wanted" is a judgement no API call can corroborate on its
own, and closing a live branch on an unexamined one has destroyed real work
before. Absent either signal, an open, still-diff-carrying draft is escalated
to you instead of closed.

To tell the pipeline it really is unwanted, **label the pull request
`obsolete`**, in that item's repo:

```bash
gh pr edit 205 -R Poetic-Poems/poetic --add-label obsolete
```

The pipeline creates the label in every repository it gathers data for, not
only the one it happens to work, at most once per `labels_ensure_interval_hours`
(default 24h), so there is nothing to set up; `scripts/doctor.sh` warns while a
repo has not got it yet.
The next time the pipeline records this item as void — typically the Enabler,
re-examining the escalation this draft raised — the label corroborates the
void despite the diff, and the pull request is closed with a comment naming
the label as why. **Only you can apply this label: no stage in the pipeline
ever applies it itself**, exactly like `unvoided` above — a stage that could
apply it would be corroborating its own judgement, which is what the guard
exists to stop.

**A machine-checkable alternative exists too**, but only once a repository has
climbed to `merge_autonomy` level `agent-merges-all` (issue #413, WI-10;
`docs/reviews/2026-08-14-autonomy-investigation.md` §5.5): a two-touch
confirmation across two *independent* Enabler engagements, at least 24 hours
apart, each citing structured `{ref, path, expect, pattern}` evidence that
resolves live against the repository — the same evidentiary bar a `void`
itself needs, applied twice rather than once. The first Enabler to judge a
draft unwanted records a `draft-obsolete-flagged` event rather than voiding it
outright; a second, later engagement's own void of the same item then
corroborates against that flag exactly as it would against your label. This
is not a second way for the pipeline to label anything — it never writes
`obsolete`, and one engagement flagging a draft can never also be the void
that closes it — it is a second, independent Enabler pass standing in for
your label at the trust level where the installation has decided that is
enough. Below `agent-merges-all`, or for any pull request nobody has flagged,
the label remains the only way to tell the pipeline a draft is unwanted.

### Blocked items and the Enabler

Some blocked items the pipeline cannot ever clear by itself: the deploy check
needs a secret only you can set, a production bug needs logs only you can see, a
milestone waits on a decision that is yours to make. Left alone those items sit
blocked indefinitely, and nothing tells you they are there.

This is also where a pull request goes when a stage could not finish it — a
Reviewer that could not certify it, a handoff that did not take. **A pull
request that is not ready for review is the pipeline's problem, not yours**, and
you will hear about it only as an escalation issue. You are never expected to
find work by noticing a draft.

So once an item has been blocked for a few cycles, the **Enabler** — one Opus
pass, engaged rarely — reads it properly: the item, the whole thread, the
failing run. It then does one of four things:

- **unblocks it**, if whatever was in the way has demonstrably gone (the
  dependency merged, the check went green) — the item is selectable again next
  cycle. Where the block *was* a pull request that never left draft, and its
  checks are green and its work done, the unblock also takes it out of draft, so
  it arrives in your review queue instead of sitting where nobody would look;
- **voids it**, if it turns out there was no work to do after all (it is already
  done on `main`);
- **leaves it blocked**, with a fresher account of what would unstick it;
- **raises a GitHub issue for you** — in the item's own repo, **assigned to you**
  and labelled `enabler-escalation` — when only a human can move it.

One case of that last bullet gets its own setting: an item the Enabler already
specified once, re-flagged as still under-specified — two engagements
disagreeing about whether the earlier specification is adequate. With
`escalation_autonomy` (see [Configuration](#configuration)) left at its
default, `always-escalate`, that still raises an issue for you, exactly as
above. Set it to `adjudicate-first` and the Enabler instead runs one further,
narrower pass first — reading only the earlier specification and the
disagreement — and either confirms the item is already specified (no issue
raised; it just becomes selectable again) or escalates to you anyway when it
genuinely cannot tell.

That pass runs **once per item**. If the same item comes back disagreed-about
a second time, it is raised for you as it always would have been, without a
second pass — so the setting can save you an issue, but it cannot quietly keep
an item circulating between two models forever. Acting on an escalation about
the item (closing the issue it raised) gives it a fresh pass, on the same
terms every other "one per human touch" rule here uses.

Set `escalation_autonomy` to `decide-tactical` instead and the Enabler's
narrower pass widens to *every* escalation, not only a re-flagged
specification — an ordinary blocked item as much as a refinement disagreement.
It reaches one of three answers: **settle** it (the same "nothing needs
deciding" outcome `adjudicate-first` already reaches, now available to any
item), **decide** it — a genuine tactical trade-off among options the item's
own record already names, which the pipeline may answer on its own authority
and does, posting the decision as a comment where the item is a GitHub issue —
or **escalate** it to you regardless, when the question turns out to need
something only you can supply. An owner-only decision — spending money,
touching a credential or a permission, a product or roadmap call, anything
this system's own spec reserves to you by name — always escalates, at every
setting; `decide-tactical` only ever widens which *tactical* questions the
pipeline may answer for itself, never that boundary. Bounded per distinct
reason rather than once per item: a fresh question about an item that was
already decided over something else still gets its own pass, up to
`escalation_adjudication_max_passes` passes for that item in total (see
[Configuration](#configuration)) — and closing an escalation about it grants
one further pass beyond that cap, each time you do. The same question a
second time still comes to you, on the same terms `adjudicate-first`'s own
bound already uses.

**Closing that issue is the whole protocol.** Do the thing it asks, close it, and
say nothing: the next cycle notices the closure, the Enabler re-checks the item
against reality, and the work resumes (or the issue's thread gets a note saying
what is still missing). There is nothing else to update, no log to edit, and no
reply expected. The issue itself says all of this, in case you meet one before
you meet this page.

Two details worth knowing:

- The issues are assigned on purpose, and not only so you see them: an assigned
  issue is excluded from the pipeline's own `issues` work source, so the system
  can never pick up its own request for help as work to do.
- Every escalation is visible on the dashboard, in the blocked table's
  *Escalated* column — a link where the pipeline is waiting on you, and the
  Enabler's last verdict where it is not.

`--dry-run` never engages the Enabler: a cycle that promises to change nothing
must not raise an issue. `--once` does engage it, which is how you watch one
happen:

```bash
# What the Enabler has been doing, and what it asked for
jq -r 'select(.event == "enabler-examined" or .event == "escalated")
       | "\(.ts)  \(.event)  \(.item)  \(.outcome // .issue_url // "")"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -10
```

### Refined items and the Refiner

Most items never need the Enabler at all. Before an under-specified item would
ever have to be blocked and wait several cycles, the **Refiner** — a cheap
model, engaged every cycle there is unrefined work — looks at every new
candidate whose source usually needs one (`issues` by default; see
`refinement_policy` below) and writes a specification for it: the goal, what
is in and out of scope, concrete acceptance criteria. For an issue that lands
as one comment, and the issue picks up the `refined` label; for anything else
it travels the same way an Enabler-written specification does — in the log,
pasted into the work order when the item is selected.

Where the Refiner cannot write one without deciding something that is yours —
a credential, a product choice, information that exists only in your head —
it declines instead, and the item follows the same path "Items nobody has
specified" describes below.

`refinement_policy` decides, per work source, whether an unrefined item may be
selected at all: `required` (never — it waits for the Refiner), `preferred`
(a refined item is ranked ahead of an equivalent unrefined one, but an
unrefined item may still be picked) or `exempt` (the source already carries
its own specification — a merge conflict, a review comment — and this does not
apply, the default for every source not named). Only `issues` and the sources
the Script already fetches in full — findings, review feedback, merge
conflicts, abandoned drafts, register hygiene — are ones the Refiner can
actually reach; setting a stricter policy for `tech-debt`, a plan task or a
review recommendation still shapes ranking, but nothing writes those a
specification yet.

```bash
# What the Refiner has written lately
jq -r 'select(.event == "item-refined" and .by == "refiner")
       | "\(.ts)  \(.repo)  \(.item)  \(.comment_url // "spec recorded in the log")"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -10
```

`--dry-run` never engages the Refiner, for the same reason it never engages
the Enabler. `refiner_model` empty switches the stage off entirely — every
item then waits for the ordinary blocked/Enabler path below.

### Items nobody has specified

There is a third reason the pipeline skips an item, and it used to be invisible:
nobody ever wrote down what the work is. "Tidy up the sync script" names no end
state; an issue that is really a question has no acceptance criteria; a
milestone task waits on a decision that is yours. The Co-Ordinator cannot rank
any of those, so it skipped them — and every cycle after it skipped them too,
forever, without recording anything. Nothing looked wrong. The work simply
never happened, and you were never told it was waiting on you.

Now the Co-Ordinator reports such an item — or the Refiner declines one it was
given, or an Implementer gets partway into one and finds the brief itself
insufficient — and the Script records it as blocked with what is missing.
Nothing else changes about that cycle. If the item is a GitHub issue it also
picks up three labels — `needs-refinement`, `blocked` and
`blocked:needs-refinement` — so you can see the same thing the pipeline can
from a filtered issue list, and the item drops off the pipeline's own
candidate list the same way any other `blocked` issue does. If the item had
already been marked `refined`, that label comes off too: the specification it
named did not hold up.

```bash
gh issue list -R Poetic-Poems/poetic --label needs-refinement
gh issue list -R Poetic-Poems/poetic --label blocked:needs-refinement
```

After the usual few cycles — during which you, or the pipeline's own re-check,
may well settle it first — the Enabler picks it up and does one of three things:

- **specifies it**, where that can be done without deciding anything that is
  yours to decide: one comment on the issue carrying the goal, scope, acceptance
  criteria and relevant files, or, for a tech-debt entry or a review
  recommendation, a specification carried in the log and pasted into the next
  work order. The item is unblocked and the label comes off;
- **asks you**, through the ordinary escalation issue — a separate one, never
  the work item's own issue, and cross-linked from it where the item is an
  issue. Answer in comments on the escalation and then close it: the same
  protocol as any other escalation, and your answers are what let the next
  engagement finish the job;
- **leaves it**, where you have already parked the decision deliberately (an
  open question with a decide-by date in a plan or roadmap). It will not ask you
  to re-make a decision you have made.

An item is specified **once** between times you touch it. If the Co-Ordinator
flags an item the Enabler has already specified, that is two models disagreeing
about whether the specification is good enough, and you get an escalation rather
than a second rewrite.

```bash
# What the pipeline has specified for itself lately
jq -r 'select(.event == "item-refined")
       | "\(.ts)  \(.repo)  \(.item)  \(.comment_url // "spec recorded in the log")"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -10
```

**You can flag an item yourself**, rather than waiting for the Co-Ordinator to
notice it. Apply `needs-refinement` to the issue directly:

```bash
gh issue edit 52 -R Poetic-Poems/poetic --add-label needs-refinement
```

The next cycle scans every repo's issues for the label, and — provided the
issue is still open and nothing already blocks it — records the same kind of
block a Co-Ordinator's own report would, naming you as the one who applied it.
From there it follows the ordinary path above: a few cycles' grace, then the
Enabler. **Take the label off while the block is still open** and that clears
it the same way closing an Enabler escalation does — the item is selectable
again next cycle, no need to touch the log yourself. This only works for a
block you created this way: taking the label off an item the pipeline blocked
on its own report does nothing, by design — that block's label is a one-way
projection of state the log already holds, not a second way to change it.

### See stage transcripts
```bash
ls -la ~/.local/state/poetic-agents/cycles/
```
Each cycle gets a directory (`<cycle-id>/`) with three files per stage that
ran: `<stage>.out` (the run's final JSON envelope — this is what gets
parsed), `<stage>.out.stderr` (diagnostics), and `<stage>.stream.jsonl`
(every event the run emitted, one JSON object per line, written as it
happened). The stream is the one to read when a stage did not finish: the
envelope is written only at the very end, so a stage killed at its timeout
leaves an empty `.out` and a stream showing exactly how far it had got.
Streams stay on the node that produced them — they are never replicated to
the state repository — and are pruned to the newest
`state_local_streams_retained` cycles, well ahead of the cycle directories
themselves. When a cycle
pre-fetches findings, that directory also holds `findings-<owner>_<repo>.json`
(the normalised Dependabot + code-scanning alerts the Co-Ordinator was given).

### Why a stage was stopped
A stage has two caps, and they mean different things:

- **the backstop** — the stage ran for that long, whatever it was doing.
- **the liveness watchdog** — the stage produced no output *at all* for that
  long, and was treated as wedged. `0` turns it off and leaves the backstop as
  the only cap.

**Neither is a number you set.** Both are worked out per
(actor, repository, model) from the pipeline's own history, once per cycle,
and announced on the stage's `stage-start` event with where each came from.
A repository nobody has run before gets a shipped prior, so nothing has to be
chosen for it. `scripts/doctor.sh` prints the current table under **Stage
budgets**.

The `timeout_<actor>` and `inactivity_<actor>` keys are overrides, and they
win permanently — set one and that cap stops adapting, which is why doctor
warns about it. `lock_stale_after` is a floor under a threshold derived from
the backstops in force, not a value to keep in step with them by hand.

A third thing stops a stage and is not a cap at all: the account saying no.
When the stream reports a usage limit, the stage is stopped there and then,
rather than holding the node for the rest of its cap while every call it makes
is refused.

All three exit `124`, so the `stage-end` event carries `kill_reason` —
`backstop`, `inactivity` or `rate-limit` — to say which, and a watchdog kill
also logs a `warning` you will see on the dashboard. They want different
responses: a backstop kill on a stage that was still emitting says the cap is
too tight; a watchdog kill says the stage stopped, so read
`<stage>.stream.jsonl` to see what it was doing last; a rate-limit stop says
nothing about the caps, and the stand-down it writes carries the real reset
time the account gave rather than this system's estimate of one.

`scripts/doctor.sh` checks that the stream really flushes as it runs on this
node, because a runtime that buffered it would leave the watchdog with no
signal and kill every healthy stage. That check makes one call to the cheapest
configured model; `--offline` skips it.

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
`"source":"code-quality"`), most severe first. It always prints valid JSON,
and exits 0 when a repo simply has the features off; a real failure to read
them (a rate limit, an outage) is different and exits 1, so the dashboard can
tell the two apart rather than showing a repo with nothing to report.

## Repository review

A second, independent pipeline — the **repository-review** pipeline, named
because each run takes one target repo, on its own, with its own clone,
branch, report set and pull request — runs a full **project review** of that
repo on a configured cadence
(`project_review.defaults.min_days_between_reviews`) and opens a pull
request with the results — a set of Markdown reports (summary, findings,
prioritised recommendations, ready-to-use improvement prompts). Debt the
review surfaces is filed straight to GitHub as `pw::type:tech-debt`-labelled
issues while the run is under way, listed under the pull request's `Defers:`
section rather than committed alongside it, so the implementation pipeline's
Co-Ordinator can pick those issues up through its own `issues` source without
waiting for the review PR to land; merging that PR then lands the improvement
prompts, which you can hand to the `project-remediation` skill.

It reuses the implementation pipeline's machinery (ephemeral clones, the
shared usage-limit stand-down, the same lock/timeout discipline) but has its
own Script (`review-cycle.sh`), lock, PR label, and cron entry. It **defers
to** a running implementation cycle and shares the one usage-limit signal, so
the two never spend quota at the same moment. The `project-review` skill it
runs is vendored at `.claude/skills/project-review/` and staged into each
ephemeral clone at run time (never committed to the repo under review).

### Configuration (`project_review` block in `config.json`)

<!-- config-table:start id=review — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not these rows -->
| Key | Default | Notes |
|---|---|---|
| `project_review.lock_stale_after` | *(unset)* | Hours, and a floor. Derived from the review backstop, multiplied by how many repositories are configured for review (floored at one), since they can all be reviewed back to back inside one lock. |
| `project_review.defaults.model` | `claude-sonnet-5` | The lead model driving the review skill (which delegates to lower-cost subagents itself). Accepts the provider-qualified form (`anthropic/claude-sonnet-5`) as well as the bare id — see [Configuration](#configuration). |
| `project_review.defaults.pr_label` | `project-review` | Applied to every review PR. Distinct from `autonomous-agent`, so review PRs never count against `max_open_agent_prs`. Do not name it `obsolete`. |
| `project_review.defaults.branch_prefix` | `review/` | Branch name `review/<date>`. |
| `project_review.defaults.timeout_review` | *(unset)* | Minutes, and an override. Leave it out — the backstop tunes itself. |
| `project_review.defaults.inactivity_review` | *(unset)* | Minutes of total silence before the review stage is treated as wedged, and an override. Omit it — the threshold is derived; `0` disables the watchdog. |
| `project_review.defaults.min_days_between_reviews` | `6` | Skip a repo reviewed within this many days. This is what makes a daily cron tick behave as "about once a week" and stay robust to a sleeping machine. |
| `project_review.defaults.not_before` | *(unset)* | Optional. Hold reviews until this timestamp — e.g. `2026-07-30T16:00:00Z` — while the implementation pipeline carries on. Use this rather than `agent-cycle.sh --disable`, which is shared and would stop the cycles too, and rather than raising `min_days_between_reviews`, which has to be lowered again afterwards. It expires by itself; leaving the key in place once the date has passed does nothing. An unparseable value stands reviews down rather than running through it. As...[continued below](#extended-notes-project_reviewdefaultsnot_before) |
| `project_review.defaults.report_directory` | *(unset)* | Optional. Where the review pipeline writes its report set (`README.md`, `01-summary.md`, ...) and reads past ones from — a GNU `date` format string, resolved with `date -u +"<format>"` relative to the repo root, e.g. `docs/reviews/project-review-%Y-%m-%d`. Absent everywhere, `reviews/project-review-%Y-%m-%d` is used, unchanged. Use only date-level specifiers (`%Y`, `%y`, `%m`, `%d`, `%j`) and literal text: a format carrying `%H`, `%M` or `%S` writes a directory that...[continued below](#extended-notes-project_reviewdefaultsreport_directory) |
| `project_review.repos` | `[{"slug": "Poetic-Poems/poetic"}, {"slug": "Poetic-Poems/poetic-fiddle"}]` | Repositories to review. Each entry is `{"slug": "owner/name"}`, plus any of `defaults`' own keys to override it for that repository alone. |
<!-- config-table:end -->

<!-- config-table:notes id=review — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not this section -->

#### Extended notes: `project_review.defaults.not_before`

Optional. Hold reviews until this timestamp — e.g. `2026-07-30T16:00:00Z` — while the implementation pipeline carries on. Use this rather than `agent-cycle.sh --disable`, which is shared and would stop the cycles too, and rather than raising `min_days_between_reviews`, which has to be lowered again afterwards. It expires by itself; leaving the key in place once the date has passed does nothing. An unparseable value stands reviews down rather than running through it. As `defaults.not_before` it holds every configured repository off before the pipeline even takes its lock; a repository's own `not_before` override additionally holds that repository off for longer (or shorter) than the installation-wide value, checked per repository once the cycle is under way.

#### Extended notes: `project_review.defaults.report_directory`

Optional. Where the review pipeline writes its report set (`README.md`, `01-summary.md`, ...) and reads past ones from — a GNU `date` format string, resolved with `date -u +"<format>"` relative to the repo root, e.g. `docs/reviews/project-review-%Y-%m-%d`. Absent everywhere, `reviews/project-review-%Y-%m-%d` is used, unchanged. Use only date-level specifiers (`%Y`, `%y`, `%m`, `%d`, `%j`) and literal text: a format carrying `%H`, `%M` or `%S` writes a directory that discovery, which probes a day at a time, can never find again — so every past review reads as missing.

<!-- config-table:notes-end -->

### Install

Create the review PR label in both repos (once):
```bash
gh api -X POST repos/Poetic-Poems/poetic/labels \
  -f name='project-review' -f color='5319e7' \
  -f description='Raised by the project-review pipeline'
# ...and the same for Poetic-Poems/poetic-fiddle
```

Add the cron entry. **Recommended** — a daily tick guarded by
`min_days_between_reviews`, robust to a machine that sleeps through a strict
weekly tick:
```bash
(crontab -l 2>/dev/null || true; echo "30 3 * * * $HOME/Code/Poetic-Poems/agent-ops/review-cycle.sh >> $HOME/.local/state/poetic-agents/review-cron.log 2>&1") | crontab -
```
This needs the same `AGENT_OPS_ROLE=active` line in the crontab as the
implementation cycle ("Which node runs the cycles"); one line covers both
pipelines.
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
The shared `limit-hit` signal is written to the implementation pipeline's
`log.jsonl`, so a usage limit hit during a review also stands the
implementation pipeline down.

See `docs/REVIEW-PIPELINE-SPEC.md` for the full specification.

## Monitoring

### Dashboard

A local, single-page dashboard shows everything at a glance: whether a cycle
is running, whether the pipelines are disabled and why, usage-limit
stand-downs, open agent PRs and their CI status,
recent cycles with per-stage cost/duration/model (substantive cycles only —
the no-op ticks the `*/15` cadence mostly produces are summarised in one
count beneath the table instead of holding rows), failures, blocked and void
items, the work sources the Co-Ordinator sees, the hourly unattended
`doctor.sh` pass's own warnings and failures (a **Doctor** section, with a
page-top banner when it has something to say), a per-stage health verdict for
each node (a **Stage health** section — `coordinator failing (11
consecutive, last success 8h ago)` and the like — with a page-top banner and
a fleet-strip badge naming which stage: the reading a plain `cycle:
RUNNING`/idle state cannot give, since that state stays green while a
stage's own attempts keep failing and the cycle process itself keeps
completing), how often the Script rejects a Co-Ordinator verdict — by day
and by the model that produced it, with what
the fleet spent recovering, so it is visible whether the cheap Co-Ordinator
model is paying for itself — estimated token cost by day, by
model and by actor, and the raw log — with each stage's transcript viewable
inline.

Two things are worth knowing about before you first open it. Each node's card
names **the version that node is running** — the last pull request contained in
its image, plus the commit it was built from, and a `behind` marker while the
fleet holds a newer build. (A roll waits for the cycle it would otherwise
interrupt, so nodes sitting on different images for a while is normal; a node
that stays behind is a watchtower that has stopped.) And **every pull-request
number on the page** — there, in the open-PR table, and against each cycle —
shows that PR's record: title, author, state, when it merged, the merge
commit, its labels, and the cycle that raised it. Hover to peek at it; click or
tap to open it and leave it open (a click goes to the card rather than to
GitHub — the card carries its own *View on GitHub* link, and ctrl/cmd-click
still opens the PR in a new tab).

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
To also keep it current between cycles — reflecting in-flight runs, the
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

### Watching a node's events

The dashboard renders cycle *state*; watching events as they happen — a cycle
starting, what the Co-Ordinator selected, a PR going up, a stand-down — means
following the node's log directly. `scripts/watch-node.sh` is the one command
for that, in place of remembering the `docker compose exec -T scheduler
tail ...` incantation:

```bash
./watch-node.sh events -f   # cycle log (log.jsonl): starts, selections, PRs, stand-downs
./watch-node.sh cron -f     # cron log (cron.log): one line per tick, including standby ones
```

Drop `-f` for the last 50 lines instead of following. Run it from the node's
stack directory — where its `compose.yaml` and `.env` live, and where it is
fetched to during [Bring up a node](#as-a-container) — or set `STACK_DIR` to
point at a stack directory elsewhere. It wraps `docker compose exec -T
scheduler tail` and nothing more, so it is the one path worth allow-listing
for an interactive agent: one script instead of ad-hoc docker-exec commands
that a permission classifier may deny. See
[deploy/docker/README.md](deploy/docker/README.md#follow-a-nodes-events) for
more.

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
If `--once` then picks up work that scheduled cycles were skipping, the
fingerprint is missing a signal — a bug worth filing, in
`scripts/gather-source-state.sh`.

**Stale lock warning:**
If a cycle was killed or hung and left a lock older than 3 hours, the next cycle will kill it and log a `warning` event. Inspect the old cycle's transcript to see what went wrong.

**PR won't merge (mergeable=false):**
The Reviewer should have caught this, or it arose after the PR was ready (another PR merged to `main` first). Use `gh pr view --json mergeStateStatus` to see why. The branch and PR remain open for manual intervention.

**Usage limit hit:**
The system logs a `limit-hit` event with the reset time if parseable. It then stands down until that time or `limit_cooldown_default`, whichever is later. Check the log for the event.

## Removing a node for good

[Taking one node out](#taking-one-node-out-while-the-rest-keep-working) puts a
node aside and leaves it able to come back. Decommissioning is the other
thing: the machine is going away, or its disk is wanted for something else,
and nothing of the node should remain — not its containers, not its volumes,
not its branch in the fleet's memory, not its credentials.

No other node depends on this one. Work is arbitrated per item, not per node
(see [Keeping every node warm](#keeping-every-node-warm)), so the fleet
experiences a departure as one fewer heartbeat and nothing else. The order
below exists only so that the node leaves nothing behind for a peer to trip
over: a claim it will never release, a branch nobody prunes, a token nobody
revokes.

Run every `docker compose` command from the departing node's stack directory —
the one holding its `compose.yaml` and `.env` (`~/poetic-node-1`, or whatever
it was called at bring-up), not from a checkout of this repo.

### 1. Check the fleet can spare it

```bash
docker compose exec scheduler /app/agent-cycle.sh --status
```

If this node is `active`, confirm that at least one other node is too before
it goes. Several may be active at once and the fleet elects no replacement, so
removing the last active node leaves an operation that heartbeats, syncs, and
does no work at all — with nothing anywhere announcing it. The dashboard's
fleet strip names each node's role. It is also the surviving actives that run
the claim GC at the end of each cycle, so a fleet with none of them stops
sweeping stale claims as well as stops working.

### 2. Let any cycle in flight finish

`--status` above reads `cycle: idle` and `review: idle`, or names what is
running. Stopping or recreating a container kills a running cycle's whole
process group, which leaves an orphaned clone under `workspace_root`, a lock
to be taken over as stale, and a claim that stands until the GC sweeps it
(`claim_ttl_hours`, derived from `schedule.cycle_interval_minutes` — see
[Configuration](#configuration)). So wait — or stop this node alone from
starting another one while you do:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable 'decommissioning' --this-node --for 2h
docker compose exec scheduler /app/agent-cycle.sh --status   # until both read idle
```

`--this-node` is the node-scoped form (see [Taking one node out while the
rest keep working](#taking-one-node-out-while-the-rest-keep-working)): it
never touches the fleet-wide switch, so the rest of the fleet keeps working
while this one drains, and there is nothing to remember to `--enable` from a
surviving node once this one is gone — the record is destroyed along with the
node. Reach for plain `--disable` (no `--this-node`) instead only if you
actually want the whole fleet paused for the duration; that one *is*
fleet-wide, so `--enable` from a *surviving* node once this one is gone, or
every other node stays down until the disable expires. On a standby node
either disable is unnecessary — a standby starts no cycles.

### 3. Take off it anything you want to keep

Everything the node has published already lives in the state repository, and
step 5 deletes it from there. Two things are worth a moment first:

- **Its history** — `log.jsonl`, its cycle records, its stage transcripts.
  Keep a copy by cloning the branch before you delete it:
  ```bash
  git clone --branch nodes/<NODE_NAME> --single-branch \
    https://github.com/Poetic-Poems/agent-ops-state.git ~/node-<NODE_NAME>-archive
  ```
- **What only it knows.** The union readers learn blocked items, void
  verdicts, and no-op fingerprints from every node's log. Deleting this node's
  branch forgets whatever it alone recorded, so an item it blocked may be
  tried once more by a peer. That is a re-tried cycle, not a fault — but it is
  the reason to do this deliberately rather than by letting a branch rot.

The `claude-config` volume is not worth preserving: the OAuth credentials in
it are per node, and a replacement node logs in once (`deploy/docker/README.md`
step 4).

### 4. Destroy the stack, its volumes, and its tailnet identity

If the node ran the `tailnet` profile, log it out while the sidecar still
exists, then delete the machine in the Tailscale admin console — otherwise it
lingers there as an offline device still holding its name, which the next node
called the same thing will not be given:

```bash
docker compose exec tailscale tailscale logout
```

Then take the whole stack down, volumes included:

```bash
docker compose down -v --remove-orphans
```

The `-v` is the entire point of this step. Without it, `state`,
`claude-config`, `workspaces` and `tailscale-state` survive as project volumes
belonging to a node that no longer exists — and they are where the disk went
(`docker volume ls`, `docker system df`).

**On a host running two stacks**, check which one holds watchtower before
choosing which to remove. The `auto-update` profile is typically enabled on
one node only, and that single watchtower updates every labelled container on
the host, whichever compose project it belongs to. Removing the stack that
runs it silently stops the survivor auto-updating; the survivor then drifts
off the fleet's image digest with no symptom but staleness. Add `auto-update`
to the surviving node's `COMPOSE_PROFILES` and `docker compose up -d` there —
while it is idle, per the caution in [Taking one node
out](#taking-one-node-out-while-the-rest-keep-working) — if the departing node
was the one running it.

### 5. Remove it from the fleet's memory

A node leaves the fleet by having its state branch deleted. That is the only
signal there is, and it must come *after* step 4: a node still running would
push the branch back within five minutes.

```bash
gh api -X DELETE repos/Poetic-Poems/agent-ops-state/git/refs/heads/nodes/<NODE_NAME>
```

(`Poetic-Poems/agent-ops-state` is `state_repo` in `config.json`.) Every
peer's next `state-sync.sh fetch` — seven minutes at most — prunes the
matching peer directory, and the node's card leaves every dashboard with it.
Leave the branch in place and you get the opposite of a clean departure: a
permanent card whose heartbeat only ever gets older, on every node's fleet
strip, for ever.

### 6. Revoke its credentials, then delete its directory

The node's `.env` holds a GitHub PAT — one per node, precisely so that one
node can be revoked without disturbing another. Revoke it at
`github.com/settings/tokens` rather than merely deleting the file: the file is
a copy, not the credential. Revoke the node's Tailscale auth key too, if it
was given a dedicated one. Then the directory itself:

```bash
rm -rf ~/poetic-node-1   # compose.yaml, .env, ts-serve.json, watch-node.sh, any .bak files
```

### 7. Reclaim the disk

The volumes are the dependable half, and `down -v` has already returned them:
they are ordinary directories, so they cost what they appeared to cost. The
images are where the arithmetic misleads, and it misleads *upwards*.

**Read `UNIQUE SIZE`, never `SIZE`.** The size Docker prints in `docker images`
— and the `RECLAIMABLE` column of plain `docker system df` — includes every
layer an image shares with other images, so adding those figures up counts the
same bytes several times over. Deleting an image returns only what no other
image still references. `-v` is the view that separates them:

```bash
docker system df -v    # REPOSITORY … SIZE  SHARED SIZE  UNIQUE SIZE  CONTAINERS
```

On an auto-updating node the gap between the two columns is the whole story.
Every watchtower roll leaves its predecessor dangling, and a predecessor of
the *same* image shares nearly all its layers with the `:latest` that replaced
it. Half a dozen of them read as several GB in `docker images` and give back a
megabyte or two:

```bash
docker image prune     # dangling images only — always safe, and often ~nothing
```

So don't plan around it. Delete the node's images by name once no container
wants them, and check the unique column first to know what you are getting:

```bash
docker image rm ghcr.io/poetic-poems/agent-ops:latest \
                containrrr/watchtower:latest \
                tailscale/tailscale:latest
```

Docker refuses to remove an image a container still uses, so this is safe to
attempt with a second node still running: it removes what it can and declines
the rest. Resist `docker image prune -a` unless this host runs nothing but
agent-ops — it removes every image no *running* container references, which on
a development laptop means the images behind every stopped stack on it, each
one a re-pull away from being needed again.

**On WSL2, none of this reaches Windows on its own.** The distro's `ext4.vhdx`
grows to its high-water mark and never shrinks, so space freed inside it is
free to Linux and still spoken for on the host's disk — `df -h /` will report
plenty free while Windows reports none. Hand it back from PowerShell:

```powershell
wsl --shutdown
Optimize-VHD -Path <BasePath>\ext4.vhdx -Mode Full   # Hyper-V module; or diskpart's `compact vdisk`
```

(`<BasePath>` is the distro's value of that name under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`.)

### Did it work?

From a surviving node, one fetch interval later:

```bash
docker compose exec scheduler ls /home/agent/.cache/poetic-agents/workspaces/.agent-ops-peers
```

The departed node should not be listed, and its card should be gone from the
dashboard's fleet strip. On the host it left, `docker ps -a` names none of its
containers and `docker volume ls` none of its volumes. If this was the last
node, the operation is now off — there is nothing left running anywhere, and
the state repository holds no `nodes/` branches.

## Uninstall

This is the legacy host install (see [On the host (legacy,
decommissioned)](#on-the-host-legacy-decommissioned)) — cron entries, state
directories, and services on the machine itself. To remove a *container* node,
follow [Removing a node for good](#removing-a-node-for-good) instead.

1. **Remove the crontab lines** (the cycle, the repository review, and, if added, the dashboard heartbeat):
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

To modify this system (add a new work source, change the selection logic, etc.), start from `docs/IMPLEMENTATION-PIPELINE-SPEC.md` — the as-built requirements specification for the pipeline, with numbered requirements and acceptance checks. The specs are maintained as-built: a change to a component lands in the same pull request as the spec edit that keeps its document accurate (see `CLAUDE.md`, "As-built specifications"). `prompts/coordinator.md`, `prompts/implementer.md`, and `prompts/reviewer.md` are the operating prompts actually fed to each stage's headless `claude -p` invocation — update the spec first, then bring the affected operating prompt(s) in line with it.

`docs/DASHBOARD-SPEC.md` is the companion specification for the monitoring dashboard (`scripts/publish-dashboard.sh` and `dashboard/index.html`).

`docs/REVIEW-PIPELINE-SPEC.md` is the companion specification for the repository-review pipeline (`review-cycle.sh` and `prompts/project-reviewer.md`).

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

Because rollout is where the care has moved to: every merge to `main` that
touches anything the container reads builds and publishes a new image, and
every node on the `auto-update` profile restarts into it within watchtower's
poll interval (about five minutes). The
roll waits for a cycle rather than killing one — watchtower's pre-update hook
(`deploy/docker/watchtower-pre-update.sh`) exits 75 while either pipeline's
lock is held, so the update slides to the next poll and keeps sliding until
the node is idle. What that does *not* buy you is any say over *which* image a
node lands on, or over the order several nodes land in. So for a change that
touches cycle state, claims, or the state-sync format, stand the fleet down
first, merge, watch the roll, then resume — the switch works from any node:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling out PR #NN"
# merge; watchtower rolls every auto-update node onto the new image
docker compose exec scheduler /app/agent-cycle.sh --enable
```

### Running the tests

The unit tests are plain bash, no framework; each is self-contained and exits
non-zero on the first failed assertion. Run the suite the way CI runs it:

```bash
./scripts/run-tests.sh                      # every test/*.test.sh
./scripts/run-tests.sh cycle-state doctor   # only those whose name matches
./scripts/run-tests.sh --list                # just the selected names, one per line
```

`--list` needs no Docker and starts no container — it applies the same filter
to the host's own `test/*.test.sh` and prints the matching basenames, so a
caller bound by a hard per-invocation ceiling (the Reviewer stage's own
Bash-tool wall; see `prompts/reviewer.md`) can list the suite once, split it
into groups that each finish comfortably inside that ceiling, and run
`./scripts/run-tests.sh <group's names...>` once per group instead of one
unbounded call over the whole thing.

That copies the working tree into a throwaway container built from the image
and runs the suite there. It takes a few minutes, and it is worth them: the
tests will *start* anywhere and only *pass* in the environment CI uses, and
both ways of getting that wrong produce failures on an untouched `main` that
read as a broken branch rather than a broken invocation.

- **Straight out of the checkout** — which is what this section used to
  recommend — the host's `jq` is whatever the host has. `jq` 1.6 and 1.7
  disagree about enough for roughly nine of these files to fail, and not one of
  those failures mentions `jq`.

- **Through `docker exec` into a running node** — the obvious fix for the
  first, and its own trap: that container's `/app` is whatever commit it was
  last built from, not the working tree in front of you, so a fix made here is
  invisible to a suite run there. `docker run` copies the current working tree
  in fresh; `docker exec` never does. `docker run`, never `docker exec`.

`AGENT_OPS_TEST_IMAGE` picks the image, for testing against a locally built one
rather than `ghcr.io`'s latest:

```bash
docker build -f deploy/docker/Dockerfile -t agent-ops:dev .
AGENT_OPS_TEST_IMAGE=agent-ops:dev ./scripts/run-tests.sh
```

CI runs the same suite *inside* the freshly built image on every push that
could change it — along with toolchain, crontab and role-guard checks (see
`.github/workflows/build-image.yml`) — so an image that reaches `ghcr.io`
has already passed everything above. A change confined to documentation
(`docs/`, `tech-debt/`, `README.md`, `CLAUDE.md`, `TECH-DEBT.md`, `LICENCE`,
`deploy/docker/README.md`) builds no image and so runs none of this; anything
else does, `prompts/*.md` emphatically included, since those are what the
pipeline feeds to `claude`. `scripts/is-docs-only.sh` holds the line, and
running it by hand answers "will my branch build an image?":

```bash
git diff --no-renames --name-only main...HEAD | ./scripts/is-docs-only.sh
```

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
jq -n '{ts: now | todate, cycle: "manual", event: "limit-hit", resume_at: (now + 7200 | todate), detail: "test injection"}' >> ~/.local/state/poetic-agents/log.jsonl
```

### Taking one node out while the rest keep working

Yes — role and lifecycle are per-node, and so is `--disable --this-node`, the
graceful way to stand one node down: no container recreate, no role flip, the
rest of the fleet keeps working throughout.

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "editing lib/" --this-node --for 2h
# ... work on that node ...
docker compose exec scheduler /app/agent-cycle.sh --enable --this-node
```

`--this-node` writes only that node's own `$state_dir/disabled.json` and
never touches `fleet/disabled.json` — plain `--disable` (no `--this-node`)
is the one that stops the *fleet*, publishing the flag every node obeys, and
is the wrong tool for taking a single node aside. `--enable --this-node`
clears only the local record and leaves a fleet-wide disable, or a peer's own
`--this-node` one, untouched. It expires on the same terms as the fleet
switch (`disable_default_ttl` unless `--for`/`--until` says otherwise), so a
forgotten `--enable --this-node` costs a few lost cycles on that node, not a
silent permanent stand-down. `--status` on the node reports it, and its
dashboard card carries the same badge a fleet disable shows, beside its role
badge — so the stand-down is visible without a shell on the box.

A plain `--disable` writes a local record too, on the node you typed it on:
that write is what stands *that* node down while the fleet flag is still being
published, and what keeps it down if the state repository turns out to be
unreachable. It is tagged `scope: "fleet"` to mark it a mirror of the fleet
switch rather than a stand-down of that node's own — so neither `--status` nor
the dashboard reports the node you happened to type the command on as
separately disabled, and `--enable --this-node` refuses to clear it (plain
`--enable` is what undoes a fleet-wide disable, and clears both levels). One
case is worth knowing about: run `--enable` on a *different* node and it
clears the flag but cannot reach the first node's file, leaving that one node
standing down alone. `--status` there and its dashboard card both say so in
those words, and `--enable` on that node clears it.

That covers most "I need this one node to stop for a while" cases. For
anything it doesn't:

- **Stop it spending indefinitely, with no switch and no expiry**: set
  `ROLE=standby` in its `.env`, then `docker compose up -d`. It keeps its
  heartbeat and keeps following the fleet's memory, so promoting it back is
  the same one variable.
- **Stop it entirely**: `docker compose stop scheduler`, or
  `docker compose down` (which keeps the volumes). The rest of the fleet
  carries on; per-item claims mean no other node was depending on this one.
- **Hold it on a known image** while the rest follow `latest`: pin
  `AGENT_OPS_IMAGE=ghcr.io/poetic-poems/agent-ops:<sha>` in its `.env`.

All three, and a `--this-node` disable once its expiry passes or
`--enable --this-node` runs, leave the node able to come back, which is what
makes them the wrong answer when the machine is going away or its disk is
wanted: see [Removing a node for good](#removing-a-node-for-good) for the
departure that also releases the volumes, the state branch, and the
credentials.

One caution before any *manual* `docker compose up -d` on a live node: after
a watchtower roll, compose's recorded config-hash no longer matches, so
`up -d` recreates the scheduler even when nothing in the compose file
changed — killing a running cycle. The pre-update hook cannot save you here:
it is watchtower that consults it, and a hand-typed `up -d` asks nobody. Run
`--status` first and let a cycle in flight finish.

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

  It also holds Claude Code's global config file. That file defaults to
  `~/.claude.json` — beside the config directory, not inside it — which put it
  in the container's writable layer, where every image roll took it: each new
  container printed "Claude configuration file not found" on stderr and built
  a fresh one. The image sets `CLAUDE_CONFIG_DIR` to this volume's mount point
  so the file lands inside it instead. Nothing else moved, and no node needs
  to do anything: the change arrives with the next watchtower roll.
- **The `state` and `workspaces` volumes** — the pipelines' memory and any
  in-progress clone.
