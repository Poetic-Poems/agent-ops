# Poetic Autonomous Implementation Agent System

A self-hosted, unattended pipeline that automatically selects, implements, and reviews pending work from the [poetic](https://github.com/Poetic-Poems/poetic) and [poetic-fiddle](https://github.com/Poetic-Poems/poetic-fiddle) repositories — and from [agent-ops](https://github.com/Poetic-Poems/agent-ops) itself, the pipeline's own home, so it works down its own backlog and roadmap — raising mergeable pull requests for human review and approval.

## What it does

Once an hour:

1. **Co-Ordinator** (Haiku) selects at most one well-scoped item of work (security findings, review feedback, merge conflicts on otherwise-ready PRs of ours, abandoned draft PRs of ours, failed CI runs, tech-debt, issues, fiddle's implementation plan, project-review recommendations, or code-quality findings). Security work — open Dependabot alerts and security code-scanning alerts — is always prioritised ahead of everything else; an issue you have marked `Urgent` comes second; answering your review feedback comes third, rebasing a ready PR of ours that has hit a merge conflict comes fourth, and finishing a draft PR this system started and then abandoned comes fifth. Issues rank by their **`Priority`** field — `Urgent`, `High`, `Medium` (also the default when the field is unset) and `Low` each sit at a different point in the order — so triaging an issue is how you move it up or down the queue.
2. **Implementor** (Sonnet/Haiku) clones the repo, implements the item on a feature branch, and opens a draft pull request — or, for review feedback, pushes to the existing branch of the PR you commented on.
3. **Reviewer** (Sonnet, or Opus when the Implementor graded the work `complexity:high`) checks and corrects the implementation, then marks the PR ready for review.
4. **Human** reviews and merges via the normal GitHub process (the only gate).

And, at the end of a cycle, rarely: the **Enabler** (Opus) re-examines an item
that has been blocked for several cycles, unblocks it if it can and raises an
issue assigned to you if only you can — see
[Blocked items and the Enabler](#blocked-items-and-the-enabler). It also writes
the specification for an item too vague to select, which is otherwise skipped
in silence forever — see
[Items nobody has specified](#items-nobody-has-specified).

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

Only PRs the system is managing are eligible (labelled `autonomous-agent`, on an
`agent/` or `td/` branch — see [Handing a pull request to the
pipeline](#handing-a-pull-request-to-the-pipeline)). Your own branches are never
touched.

Back-pressure doesn't block this: if every agent PR is sitting on "changes
requested", the cycle restricts itself to review feedback rather than standing
down, so it can always dig itself out. It still can't open a new PR while the
gate is full.

## Issue priority

An open issue's place in the queue is its **`Priority`** field — GitHub's own
issue field (`Urgent` / `High` / `Medium` / `Low`), set from the issue page's
sidebar, not a label. Setting it is how you move an issue up or down against
every *other* kind of work the pipeline could pick instead:

| Priority | Where the issue is picked up |
|---|---|
| `Urgent` | **Second overall, across both repos** — ahead of everything except security work, including ahead of your review feedback and of finishing a stalled PR. |
| `High` | After a red default branch, but ahead of `TECH-DEBT.md`. |
| `Medium` | After `TECH-DEBT.md`, ahead of the implementation plan and the weekly review's recommendations. |
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
  allowed to push to. `/td` raises its PRs on `td/<id>` and the hourly cycle on
  `agent/<item>`, so both qualify; labelling a PR on any other branch (e.g.
  `feature/…`) does nothing, because the human gate reserves those and the
  gatherers skip them even when labelled.
- **Labelling grants write access.** A labelled PR is one the fleet may push to —
  including a `--force-with-lease` rebase to clear a conflict — and it counts
  toward the open-PR back-pressure cap. Remove the label to take the PR back.

## Configuration

Edit `config.json` before first run. Keys:

| Key | Default | Notes |
|---|---|---|
| `repos` | see `config.json` | Array of `{"slug": "...", "sources": [...]}`. `sources` is that repo's work sources in priority order (`security`, `issues:urgent`, `review-feedback`, `merge-conflicts`, `abandoned-drafts`, `failed-runs`, `issues:high`, `tech-debt`, `issues:medium`, `implementation-plan`, `project-review`, `issues:low`, `code-quality`, `register-hygiene`). `security` (open Dependabot + security code-scanning alerts) is always first, and any security-related item is prioritised ahead of all non-security work; `issues:urgent` comes second and likewise outranks the repo walk, because an issue you have marked `Urgent` is the strongest thing you can say short of a security alert; `review-feedback` (agent PRs where you asked for changes we haven't answered yet) comes third and also outranks the repo walk — finishing beats starting, and a stuck PR otherwise occupies a back-pressure slot forever; `merge-conflicts` (agent PRs otherwise ready for review or merge but conflicting with their base) comes fourth for the same reason — a rebase-and-resolve unblocks a PR you are waiting to land, and nothing else on it can proceed until it merges cleanly; `abandoned-drafts` (draft PRs this system raised and then left untouched past `abandoned_draft_after_hours`) comes fifth for the same reason — finishing a stalled draft of ours turns a slot silted with a dead draft into a PR you can merge; `project-review` (the latest weekly review's recommendations that aren't already tech-debt or issues) sits just above `issues:low` and `code-quality` (non-security code-scanning findings); `register-hygiene` (the repo's tech-debt register failing its own consistency check — an item file whose frontmatter disagrees with its filename, its declared scope, or itself) is last, because a deterministic cosmetic repair must never outrank real work, and each repo's `tech-debt-register` CI check keeps its volume near zero anyway. The four `issues:<band>` tokens are the *same* source at four ranks, banded by each issue's `Priority` field — see "Issue priority" below; list a subset to have the pipeline see only those bands, or none to turn issues off for that repo. Adding a repo or source is a config-only change. At runtime, repos are ordered by least-recently-updated default branch first, ahead of this list order. A repo entry that lists `implementation-plan` must also carry `implementation_plan_path` — the path, relative to that repo's root, of its plan document (poetic-fiddle's is `docs/IMPLEMENTATION-PLAN.md`); the Co-Ordinator reads whatever this says, so a repo with a differently named or located plan needs no prompt change, only its own path. The Script refuses to start a cycle if a repo lists the source without it — a repo that doesn't list `implementation-plan` needs no such key. |
| `state_dir` | `~/.local/state/poetic-agents` | Lock, shared log, stage transcripts. |
| `workspace_root` | `~/.cache/poetic-agents/workspaces` | Ephemeral clones. Each cycle gets its own subdirectory, and the state repository keeps its mirror here. |
| `state_repo` | `Poetic-Poems/agent-ops-state` | Private repository through which `state_dir` replicates between nodes. See [Keeping every node warm](#keeping-every-node-warm). Leave it out and nothing syncs — a single-node install behaves exactly as before. |
| `candidates_max` | 3 | How many ranked candidates the Co-Ordinator returns; the Script claims down the list, so a lost race costs the next-best item rather than the cycle. |
| `claim_ttl_hours` | 6 | Hours before a dead node's claim-registry entry is swept (`lib/claim.sh gc`); far beyond one full cycle. |
| `abandoned_draft_after_hours` | 3 | Hours a draft PR this system raised may sit untouched before it counts as abandoned and finishing it becomes selectable work (the `abandoned-drafts` source). Beyond one full cycle, so a draft still being worked never qualifies. |
| `cycles_retained` | 200 | Cycle directories kept in the replicated copy (~8 days of hourly cycles). Your own `state_dir` is not pruned. |
| `log_retained_bytes` | 2000000 | Size at which `scripts/rotate-logs.sh` rotates `dashboard.log`, `state-sync.log`, `cron.log` and `review-cron.log`. `log.jsonl` and `review-log.jsonl` are never rotated. |
| `log_generations` | 3 | Rotated generations kept beside each live log (`<name>.1` … `<name>.<log_generations>`). |
| `coordinator_model` | `claude-haiku-4-5-20251001` | Selection is cheap triage. |
| `implementor_model_default` | `claude-sonnet-5` | For code changes. |
| `implementor_model_trivial` | `claude-haiku-4-5-20251001` | For docs, comments, register entries only. |
| `reviewer_model_default` | `claude-sonnet-5` | Quality gate before human review, for work the Implementor graded `complexity:low` or `complexity:medium`. |
| `reviewer_model_complex` | `claude-opus-5` | The same gate for work graded `complexity:high` — the Implementor grades each PR ex post and labels it; the higher of that grade and the PR's existing label picks the tier. Leave it empty to review everything on `reviewer_model_default`. |
| `enabler_model` | `claude-opus-5` | The Enabler: re-examines long-blocked items and escalates the ones needing you. The most expensive model here, engaged rarely — see [Blocked items and the Enabler](#blocked-items-and-the-enabler). Leave it empty to switch the stage off. |
| `enabler_assignee` | `warwickallen` | GitHub login every Enabler escalation is assigned to. Required whenever `enabler_model` is set — the Script refuses to start a cycle rather than raise an unassigned escalation, since the assignment is what excludes the issue from the pipeline's own `issues` source (see [Issue priority](#issue-priority) and requirement 16.4 in the spec). |
| `enabler_after_coordinator_cycles` | 3 | How many cycles that actually ran a Co-Ordinator must pass, after an item is blocked, before the Enabler looks at it. Counting cycles rather than hours means a fleet that spent the night stood down on a usage limit has not "waited". |
| `refinement_after_coordinator_cycles` | *(same as `enabler_after_coordinator_cycles`)* | The same wait, but for an item the pipeline recorded as too under-specified to work on (an issue picks up the `needs-refinement` label) rather than one blocked by something in the world. Left unset it waits exactly as long as any other block; set it separately once fleet behaviour tells you refinement items should age faster or slower. |
| `enabler_recheck_hours` | 72 | Hours before the Enabler re-examines an item it has already examined. This is the bound on how long new evidence — a diagnosis posted into the very thread whose absence blocked the item — can sit unread. `0` switches re-examination off. |
| `enabler_escalation_label` | `enabler-escalation` | Label applied to every issue the Enabler raises, for your filters and for its own duplicate check. Create it in each target repo (`gh label create enabler-escalation -R Poetic-Poems/<repo>`); without it the issue is still raised, just unlabelled. |
| `needs_refinement_label` | `needs-refinement` | Label put on an **issue** while the pipeline has it recorded as too under-specified to work on, and taken off again when that clears — see [Items nobody has specified](#items-nobody-has-specified). You can also apply it yourself to flag one directly; the pipeline reads that back the same way. Create it in each target repo (`gh label create needs-refinement -R Poetic-Poems/<repo>`); without it the item is still recorded and still reaches the Enabler, you just do not see it in the issue list — and a label you apply yourself does nothing. Leave it empty to switch the labelling off in both directions. Do not set it to `blocked`, which is a label that excludes an issue from the pipeline's work source. |
| `refinement_max_per_engagement` | 3 | How many under-specified items one Enabler engagement will take on. Ordinary blocked items are never displaced by them, and items over the cap simply wait for a later engagement. `0` switches the refinement work off while still recording it. |
| `prompt_overrides` | `{}` | Add house rules to a stage's operating prompt, or replace it outright, without forking `prompts/`. See [Prompt overrides](#prompt-overrides). |
| `pr_label` | `autonomous-agent` | Applied to every PR this system raises. |
| `branch_prefix` | `agent/` | Branch naming: `agent/<item-slug>`. |
| `max_open_agent_prs` | `8` | Back-pressure limit: total open agent PRs (draft or ready) across both repos. |
| `timeout_coordinator` | 15 | Minutes. |
| `timeout_implementor` | 90 | Minutes. |
| `timeout_reviewer` | 30 | Minutes. |
| `timeout_enabler` | 30 | Minutes. |
| `lock_stale_after` | 4 | Hours. Stale lock is killed and warning is logged. Comfortably beyond the sum of the stage timeouts (15 + 90 + 30 + 30 minutes). |
| `limit_cooldown_default` | 3 | Hours. Stand-down after a usage-limit error. |
| `disable_default_ttl` | 4 | Hours. How long `--disable` lasts when `--for` doesn't say. See [Pausing the pipelines](#pausing-the-pipelines). |
| `none_selected_recheck_hours` | 24 | Hours. The Co-Ordinator is engaged at least this often even when nothing has changed. See [Skipping no-op cycles](#skipping-no-op-cycles). `0` disables that safety net entirely — not recommended. |
| `dashboard_refresh_seconds` | 5 | Seconds. How often an open dashboard tab reloads to pick up freshly-written data, matching the [heartbeat](#keep-it-fresh) cadence. Untick the page's *auto-refresh* box to pause it while reading. |
| `schedule.cycle_hours` | `*` | The hour field of the containerised node's implementation-cycle crontab line (`deploy/docker/render-crontab.sh`); `*` means every hour. |
| `schedule.excluded_minutes` | `[0]` | Minutes the per-node `CYCLE_MINUTE` (env or hash) may never land on. This repo's own config excludes `0` because poetic's hourly sync workflow owns the top of the hour; a fresh install with no such conflict should ship `[]`. |
| `schedule.excluded_minutes_reason` | see `config.json` | Free-text note on *why* `excluded_minutes` excludes what it does — documentation only, read by nobody. |
| `schedule.review_hour` | `3` | The hour the containerised node's review tick fires. |
| `schedule.review_offset_minutes` | `29` | Minutes past `CYCLE_MINUTE` (mod 60) the review tick's minute is set to, so the node's two heavy pipelines land apart within the hour. |
| `schedule.heartbeat_minutes` | `5` | Interval, in minutes, of the containerised node's dashboard-heartbeat cron line. |
| `schedule.state_sync_push_minutes` | `5` | Interval, in minutes, of the containerised node's `state-sync.sh push` line. |
| `schedule.state_sync_fetch_minutes` | `7` | Interval, in minutes, of the containerised node's `state-sync.sh fetch` line. |
| `schedule.log_rotation_minute` | `19` | The minute past every hour the containerised node's `rotate-logs.sh` line runs. |

Every `*_model` key above, plus `review.model` below, also accepts a
provider-qualified id — `anthropic/claude-sonnet-5` alongside the bare
`claude-sonnet-5` — with identical behaviour; the qualifier is optional
because Anthropic is the only executable provider today. A qualifier naming
any other provider is rejected at cycle start with an error naming the key,
not passed to the `claude` CLI. No existing config needs to change.

The `review` object configures the separate weekly project-review pipeline — see [Weekly project review](#weekly-project-review).

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
  "implementor": {
    "extend": ["prompt-overrides/implementor-house-rules.md"]
  }
}
```

Keys are stage names — `coordinator`, `implementor`, `reviewer`, `enabler`
— each holding:

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
`prompt_overrides` is an object keyed only by the four stage names, each
holding only `extend` (an array of strings) and/or `replace` (a string).
For the `coordinator` and `enabler`
stages, that is still visible: a configured file going missing (or a new one
appearing, or an existing one changing) moves the hash the no-op
short-circuit tracks (see [Skipping no-op cycles](#skipping-no-op-cycles)),
so a broken path shows up as an unexplained Co-Ordinator or Enabler run
rather than being silently swallowed. `implementor` and `reviewer` overrides
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

Four things are worth knowing:

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
  entrypoint warns about it on each start.
- **The dashboard is never reachable from a network.** The `tailnet` profile
  puts the server in the Tailscale sidecar's network namespace, so Serve can
  proxy to its loopback and nothing else can; the `local` profile publishes it
  to the host's loopback alone (`127.0.0.1:${DASHBOARD_PORT:-8787}:8787`). If
  the host already has something on 8787, set `DASHBOARD_PORT` in `.env` — it
  moves the host side of that mapping.

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
  is. Wait for it to finish before recreating a container by hand — a manual
  `up -d` (or `restart`, or `down`) kills a cycle mid-flight. A watchtower
  roll no longer does: its pre-update hook reads the same locks `--status`
  reads and defers the roll until they are free.
- **A disable expires by default.** The point is not tidiness: an agent that
  disables the pipeline and then dies would otherwise stop every future cycle
  silently — "no PRs" looks exactly like a quiet week. The TTL turns a
  forgotten switch into a few lost cycles. Use `--for forever` when you mean
  it, and `--enable` when you're done.
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
# limit:    STANDING DOWN — with no stated reset; each hourly cycle probes whether it has lifted — …
```

When the message states a reset time, `resume_at` is that time and waiting is
the whole answer. When it does not — the monthly spend-cap message is the
common case — `resume_at` is this system's own guess, only an upper bound:
each hourly cycle probes the API with one minimal request (requirement 2.1b)
and retires the stand-down by itself the moment the account answers, so a
limit that was really an exhausted 5-hour session window clears within the
hour of its rollover, not a day later. Such a limit still has two exits, and
you choose:

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
the fleet down until the next day. The probe asks the account itself, hourly;
`--clear-limit` remains for when you have just raised the cap and want the
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
| `push` | every five minutes, and at the end of every cycle | publishes `state_dir` as this node's own `nodes/<NODE_NAME>` branch, stamped with a heartbeat (`{node, role, ts, last_cycle, version}`) |
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
issues (with labels, assignees and `Priority`), the conclusion of each workflow's latest
run, its open PRs (a PR is a claim), the blocked and void lists, the selection
config, and a hash of `prompts/coordinator.md` and any `prompt_overrides.coordinator`
files you've configured (see [Prompt overrides](#prompt-overrides)). If that fingerprint matches the
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

Because a void is permanent, one has to be earned. Every void carries the
evidence behind it, and a Co-Ordinator's void — the only kind made without
opening the repository — is checked before it is recorded: an unevidenced
verdict, or one the cycle's own candidates contradict (the pull request it calls
finished still has a diff), is recorded **blocked** instead and handed to the
Enabler, which can read the repository and settle it properly. You will see the
refusal as a `warning` on the dashboard.

Both are listed on the dashboard. To reopen a void item — you believe the work
has genuinely regressed, or the verdict was wrong — **label any issue or pull
request that names the item with `unvoided`**, in that item's repo:

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
the Implementor will simply void it again — with evidence this time.

**Keep `cycle: "manual"` exactly as it is** here and in any other event you
append by hand — an `unblocked`, a `limit-hit`. It is not a placeholder for a
missing id; it is the marker that says no cycle produced this record, and the
dashboard reads it as one. Give the event a timestamped id of the real shape
instead and it becomes indistinguishable from a run: the Recent cycles table
grows a row for a cycle that never started, wearing whatever badge an empty
event stream earns. `manual` keeps the record in the log tail, where it
belongs, and out of the cycle list.

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

### Items nobody has specified

There is a third reason the pipeline skips an item, and it used to be invisible:
nobody ever wrote down what the work is. "Tidy up the sync script" names no end
state; an issue that is really a question has no acceptance criteria; a
milestone task waits on a decision that is yours. The Co-Ordinator cannot rank
any of those, so it skipped them — and every cycle after it skipped them too,
forever, without recording anything. Nothing looked wrong. The work simply
never happened, and you were never told it was waiting on you.

Now the Co-Ordinator reports such an item, and the Script records it as blocked
with what is missing. Nothing else changes about that cycle. If the item is a
GitHub issue it also picks up the `needs-refinement` label, so you can see the
same thing the pipeline can:

```bash
gh issue list -R Poetic-Poems/poetic --label needs-refinement
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
improvement prompts) plus an updated tech-debt register. Merging that PR
feeds the hourly pipeline above: its Co-Ordinator picks up the new tech-debt
items, and you can hand the improvement prompts to the `project-remediation`
skill.

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
| `review.model` | `claude-sonnet-5` | The lead model driving the review skill (which delegates to lower-cost subagents itself). Accepts the provider-qualified form (`anthropic/claude-sonnet-5`) as well as the bare id — see [Configuration](#configuration). |
| `review.pr_label` | `project-review` | Applied to every review PR. Distinct from `autonomous-agent`, so review PRs never count against `max_open_agent_prs`. |
| `review.branch_prefix` | `review/` | Branch name `review/<date>`. |
| `review.timeout_review` | `120` | Minutes. Per-repo wall-clock timeout. |
| `review.lock_stale_after` | `6` | Hours. Larger than the hourly pipeline's 3 h — a full review is long. |
| `review.min_days_between_reviews` | `6` | Skip a repo reviewed within this many days. This is what makes a daily cron tick behave as "about once a week" and stay robust to a sleeping machine. |
| `review.not_before` | *(unset)* | Optional. Hold **all** reviews until this timestamp — e.g. `2026-07-30T16:00:00Z` — while the hourly pipeline carries on. Use this rather than `agent-cycle.sh --disable`, which is shared and would stop the cycles too, and rather than raising `min_days_between_reviews`, which has to be lowered again afterwards. It expires by itself; leaving the key in place once the date has passed does nothing. An unparseable value stands reviews down rather than running through it. |

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

## Monitoring

### Dashboard

A local, single-page dashboard shows everything at a glance: whether a cycle
is running, whether the pipelines are disabled and why, usage-limit
stand-downs, open agent PRs and their CI status,
recent cycles with per-stage cost/duration/model, failures, blocked and void
items, the work sources the Co-Ordinator sees, estimated token cost by day, by
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

The unit tests are plain bash, no framework; each is self-contained and
exits non-zero on the first failed assertion. They run straight out of the
checkout — no node, no Docker, no installation:

```bash
for t in test/*.test.sh; do "$t" || break; done
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
