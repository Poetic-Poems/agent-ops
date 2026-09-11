# Pipeline Monitor — as-built specification

## About this document

This is the as-built requirements specification for the **Pipeline Monitor**:
a third pipeline, sibling to the implementation pipeline
(`docs/IMPLEMENTATION-PIPELINE-SPEC.md`) and the repository-review pipeline
(`docs/REVIEW-PIPELINE-SPEC.md`), whose subject is not a repository but the
pipelines themselves. Like them it describes the system as it exists — any
change to this pipeline lands together with the edit that keeps this document
accurate (see `CLAUDE.md`, "As-built specifications").

**Where this document is silent, follow
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`.** The three pipelines deliberately
share their machinery — the lock discipline, the minimal-`PATH` bootstrap for
cron, the switch (`lib/toggle.sh`), the role guard (`lib/role.sh`),
usage-limit detection (`lib/limit-detect.sh`), the JSON-Lines log format and
`log_event` helper (`lib/log-event.sh`), the stage launcher with its two caps
and event stream (`lib/stage-run.sh`), the metering record
(`lib/metering.sh`), the stage-budget derivation (`lib/stage-budget.sh`) and
the "straight-parse-else-last-fenced-```json```-block" result parser. This
pipeline **reuses** those and must not reinvent them. References of the form
"requirement N" mean requirement N of
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`; references of the form "R-n" mean
requirement R-n of `docs/REVIEW-PIPELINE-SPEC.md`. This document's own
requirements are numbered `Mn`.

## What it is

A scheduled reading of the pipeline's own state, by a model, with the
discipline that makes a reading actionable: one dated report, and at most
`monitor_max_filings_per_run` filings, each carrying a stable finding key and
a provenance line, each deduplicated against what previous runs already
filed.

```
cron (hourly; the run is due at schedule.monitor_hour, or within the hour
       after any pager-fired event — M4)
  └─ monitor-cycle.sh          ← the Monitor Script: lock, stand-downs, the due gate,
       │                          the fleet slot claim, the digest, the filings
       ├─ lib/monitor-digest.sh   ← the deterministic digest: 24 h of the union log
       │                            by event class, the pager's transitions and open
       │                            pages, every node's heartbeat verdicts and
       │                            host-facts record, the throughput fold, the forge's
       │                            own last 24 h, the specs' gotcha sections
       ├─ Pipeline Monitor (Sonnet) ← reads the digest; returns a report and findings;
       │                              writes nothing anywhere
       └─ the Script files            ← ≤ monitor_max_filings_per_run, search-first,
                                         provenance-stamped, by class
```

### Why it exists

Issue #1126 audited this system's observability and found that half of what
was worth knowing needed a **hypothesis, not a threshold**. A threshold-shaped
fault — a node stopped publishing, a stage is failing, an updater is stuck —
already has a pager invariant watching for it (requirement 51,
`lib/pager-invariants.sh`). The other half does not: `budget: 1` on
`coordinator-input-fitted` meant a *negative* allowance (agent-ops#1128), and
nothing but a session reading the primary records with a question in mind was
ever going to notice. The Monitor is that session, scheduled, with the digest
such a session would build first.

The filing discipline is the other half of the design, and it is a
requirement rather than a nicety for a measured reason: ideas are not this
system's bottleneck. At the time this pipeline was specified the product
repository carried 184 open issues and thirteen untouched review
recommendations a week old. A monitor that filed everything it noticed would
buy a backlog nobody works and make the real findings harder to see, so the
budget (M12), the dedup (M13) and the provenance line (M11) bound it.

## Relationship to the existing pipelines

- **Separate everything that must be separate:** its own Script
  (`monitor-cycle.sh`), its own crontab line, its own lock
  (`monitor-lock.json`), its own stream (`monitor-log.jsonl`), its own
  actor token (`monitor`). **Shared where sharing is correct:**
  `config.json`, `state_dir`, `workspace_root`, the switch, the role guard,
  the `PATH` bootstrap, the `gh` transport shim that bootstrap resolves
  (requirement 2.0e — `monitor-cycle.sh` exports `PW_GH_STATE_DIR` once it
  resolves `state_dir`), the stage launcher, the stage-budget derivation and
  the result parser.
- **The Monitor defers to both its siblings** (M3.2). It is the one of the
  three that can always wait: its trigger is an hourly tick, so deferring
  costs an hour, where deferring a cycle costs the item that cycle had
  already claimed.
- **One shared quota signal.** A `limit-hit` event is written to the *shared*
  `log.jsonl` in the same shape (M3.1/M18), so a usage-limit hit in any
  pipeline stands all three down, and the dashboard shows it. Every other
  monitor event goes to this pipeline's own stream (M18).
- **It never runs as a stage of `agent-cycle.sh`**, never writes a label the
  Co-Ordinator keys on, and never edits `config.json` (M1).

## Actors

1. The **Monitor Cronjob** — the hourly crontab entry that fires the Monitor
   Script. Hourly rather than daily because the second half of the cadence —
   a run within the hour after a page fires — is a fact about the fleet's own
   log, and no crontab line can read one (M4).
2. The **Monitor Script** (`monitor-cycle.sh`) — a bash script that
   orchestrates one run: the stand-downs, the due gate, the fleet slot claim,
   the digest, the one stage, and every filing. It launches the Pipeline
   Monitor; agents never launch the Script.
3. The **Pipeline Monitor** — a headless Claude Code invocation
   (`prompts/monitor.md`, token `monitor`, display name **Pipeline Monitor**
   in `lib/pipeline-marker.sh`'s `pipeline_actor_label` and
   `dashboard/index.html`'s `ACTOR` map) that reads the digest and returns a
   report and its findings. It writes nothing: no issue, no comment, no
   label, no commit, no configuration.
4. The **Human Owner** — reads the report, and receives at most one
   escalation per run (M14b). Not launched by any part of this system.

## Environment

Identical to `docs/IMPLEMENTATION-PIPELINE-SPEC.md` ("Environment"), with one
narrowing that is a requirement rather than an accident: see M3.

## Configuration

Every key this pipeline reads is a top-level key of `config.json` and is
rendered into the `id=main` configuration tables of `README.md` and
`docs/IMPLEMENTATION-PIPELINE-SPEC.md` from `config.schema.json`, like every
other top-level key (`CLAUDE.md`, "Generated regions"). This document
deliberately carries no fourth generated region: the keys are
`monitor_model`, `monitor_max_input_bytes`, `monitor_max_filings_per_run`,
`monitor_tactical_keys`, `schedule.monitor_hour`,
`schedule.monitor_offset_minutes` and `prompt_overrides.monitor`, and adding
a fifth region to `scripts/render-config-table.sh` to restate seven rows a
reader can already find in one place would be a second copy to keep honest
for no gain.

Three keys this pipeline reads but does not own: `crash_loop_repo` and
`pager_repo` (where an escalation, a decision record or a page comment goes —
M14a), `enabler_assignee` (who an escalation is assigned to), and
`enabler_escalation_label` (what it is labelled). They are the installation's
existing answers to "where do escalations go and who gets them", and the
Monitor reuses them rather than adding a fourth.

## Requirements

### The Monitor Script (`monitor-cycle.sh`)

M1. **The boundary.** The Monitor never writes a label the Co-Ordinator keys
   on (requirement 16's work sources — `pw::type:tech-debt` is the one
   exception, and it is the exception on purpose: a mechanical finding is
   ordinary work for the fleet, filed exactly as the Reviewer, Implementer
   and Project Reviewer already file it). It never edits `config.json`. It
   never runs as a stage of `agent-cycle.sh`. It raises no pull request and
   pushes no branch.

M2. **Its own lock.** `state_dir/monitor-lock.json`, in the same shape and
   with the same takeover discipline as `lock.json` and `review-lock.json`:
   `{pid, started_at, host}`, a live pid inside the staleness window skips the
   tick, a foreign `host` is taken over immediately (a pid is meaningful only
   in the PID namespace that minted it — #130), and a stale local lock is
   taken over after `TERM`-then-`KILL` on its process group. The staleness
   window is derived, not configured: the Monitor stage's own resolved
   backstop (M9a) plus thirty minutes of filing headroom. The lock is excluded
   from state replication (`scripts/state-sync.sh`), exactly as its two
   siblings are.

M2a. **The switch.** `lib/toggle.sh`'s node switch and the fleet switch both
   stand this pipeline down, checked before the lock. It honours the switch
   and never sets or clears it: `agent-cycle.sh --disable` is the one way in,
   so there is one writer and one record. A `drain` stands it down exactly as
   a plain stop does — the Monitor opens no pull request, so it has nothing
   for a drain to finish.

M2b. **The role guard.** `lib/role.sh`'s `role_is_active`: only a node whose
   `AGENT_OPS_ROLE` is `active` runs an unattended monitor pass, and a standby
   tick leaves nothing behind but the cron-log line. Checked before the config
   is read; `--dry-run` and `--once` bypass it.

M3. **CronJob-shaped.** The Monitor uses no Docker socket, no `ssh`, no host
   path and no privileged mount. Everything it knows about a host it learns
   from that node's own host-facts record (`docs/HOST-FACTS-SCHEMA.md`),
   published by `scripts/collect-host-facts.sh` and carried fleet-wide by the
   ordinary state-sync push. This is not incidental: it is what makes a later
   move of this pipeline into a control plane (ROADMAP D6) a matter of moving
   one prompt and one digest builder, and it preserves the post-#603 property
   that the pipeline's runtime container holds neither the Docker socket nor
   the Kubernetes API.

M3.1. **The usage-limit cooldown.** Requirement 2.1's check, in full: the log
   union (as fresh as the last fetch) and `fleet/limit.json` (read live),
   later resume wins. A cooldown in force stands the run down before the
   digest is built.

M3.2. **Deference to a live sibling.** If either `lock.json` (the
   implementation pipeline) or `review-lock.json` (the review pipeline) is
   held by a **live** process, the Monitor stands down and waits for the next
   hourly tick. R3.2 states this rule for one lock; it is widened to two here
   because the reason R3.2 gives — two heavy `claude` runs must not overlap on
   one subscription quota — applies to the review cycle identically, and the
   review cycle is the longer-running of the two. This requires no change to
   either sibling; the deference is entirely on the Monitor's side.

M4. **Cadence: an hourly tick and a due gate.** The crontab line fires every
   hour, at `schedule.monitor_offset_minutes` past the node's own base minute
   (mod 60) — the same per-node jitter `schedule.doctor_offset_minutes` gives
   the unattended doctor pass. Each firing decides for itself whether the run
   is **due**, from two independent triggers, whichever holds first:

   - **`daily`** — this tick's UTC hour equals `schedule.monitor_hour` **and**
     no `monitor-report-written` event exists for today's UTC date anywhere in
     the fleet's union of `monitor-log.jsonl`. "Anywhere in the fleet" rather
     than "on this node" is what makes the daily run one run rather than one
     per active node.
   - **`pager`** — the newest `pager-fired` event in the union of `log.jsonl`
     is newer than the newest `monitor-report-written` event in the union of
     `monitor-log.jsonl`. This is "one run within the hour after any
     `pager-fired` event", as an hourly tick can express it, and it is
     self-limiting: writing the report advances the comparison past the event
     that triggered it, so one page buys one run.

   A tick that is neither logs `monitor-stand-down` with `cause: "not-due"`
   and exits 0. What such a tick costs is one union snapshot of `log.jsonl`
   and `monitor-log.jsonl`, the same stage-budget derivation over it that
   every implementation cycle already performs, the usage-limit fold, two
   `jq` folds for the gate itself, and a lock taken and released — and **no
   model call**, which is the cost that matters. `--once` and `--dry-run` are
   themselves a trigger (`requested`): an operator asking for a run now gets
   one.

M5. **One run per slot, fleet-wide.** Before the digest is built, the run
   claims its slot through `lib/claim.sh`: `claim file monitor <slot-key>`,
   where the slot key is the UTC date for a `daily` run and
   `<date>T<hour>` for a `pager`-triggered one. This is the pseudo-slug
   pattern `lib/pager.sh` uses for its own per-window evaluation and the
   Enabler for its per-item engagement (requirement 35c): the claims live
   under `claims/monitor/`, where no target repository's can collide with
   them. A lost claim (exit 3) or an unreachable forge (any other non-zero)
   logs `monitor-skipped` and exits 0 — fail closed, on `lib/claim.sh`'s own
   reasoning: a node that could not claim could not have filed the findings
   either. With `state_repo` unset the claim is vacuously won, which is
   correct — one node cannot race itself. `--dry-run` claims nothing.

### The digest (`lib/monitor-digest.sh`)

M6. **The model never reads a primary record.** The Script assembles a digest
   and the stage reads that. The digest's sections are:

   - **the last 24 h of the union log grouped by event class**, with a count,
     the contributing nodes, and up to three samples each. Samples are taken
     from the newest events in the class, since a fault still in force matters
     more than the first time it was seen — and the count already says how
     long it has been going on.
   - **every `pager-fired` and `pager-cleared`** transition in the window, and
     **every open `pw::pager` issue** in `pager_repo` with its body and its
     comments. The two are separate arrays, not one joined view: a page can be
     open with no transition in the window, and a transition can have no open
     page behind it, and it is the *open pages* the triage duty (M15) is owed
     to.
   - **every node's heartbeat verdicts** — per-stage health, updater, compose,
     image, mirror, doctor. A peer's row comes from its own `heartbeat.json`,
     never from anything this node derives on a peer's behalf; this node's own
     row is assembled from the files that heartbeat is folded from
     (`.stage-health.json`, `.doctor-status.json`), because a node keeps no
     copy of its own published heartbeat outside the state mirror.
   - **the host-facts record** for each node where one exists (`null` where
     no collector has run, which is itself worth seeing).
   - **the throughput fold**: selections per work source (the source-state
     count per band), stand-downs by cause, the day's verbatim
     `none-selected` reasons, the `coordinator-input-fitted` rung histogram
     and the `coordinator-input-fit-unassessable` count, pull requests marked
     ready, and claims lost to peers.
   - **the last 24 h of pull requests, issues and escalations** in
     `crash_loop_repo` (or `pager_repo` where that is the only one
     configured).
   - **the specs' `## Gotchas` sections** — the known-signature catalogue, so
     a symptom can be checked against a fault this system has already
     diagnosed once. The incident runbook (agent-ops#1149) does not exist; when
     it does it joins this list rather than replacing it, since the two answer
     different halves of "what does this signature mean".

M6a. **Deterministic.** Every function in `lib/monitor-digest.sh` is a pure
   reader: it takes paths and JSON on argv, reads no `config.json`, calls no
   `gh`, and writes nothing but the rendered file it is handed. Two runs over
   the same inputs produce the same digest — which the dedup of M13 depends
   on, since a digest that reshuffled its samples would produce a different
   reading of the same day. The one input that cannot come from a file — what
   the forge currently holds — is fetched by the Script and handed in as JSON,
   which is also what lets the whole builder be tested against a fixture
   directory with no network.

M6b. **Degrade, never fail.** Every reader returns its empty shape rather
   than a non-zero status: an unreadable union log, a fleet whose peers have
   not synced, a forge listing that failed. A monitor run with less to say is
   a monitor run; a monitor run that died because a peer directory was absent
   is a gap in exactly the observability this pipeline exists to provide.

M7. **Bounded by `monitor_max_input_bytes`, on a stated ladder.** The digest
   is rendered as Markdown and measured **in bytes** (not characters — this
   text carries plenty of multi-byte punctuation, and a character count would
   let a dense digest overshoot the bound by exactly the overhead the bound
   exists to keep out). Rungs, walked in order and stopped at the first that
   fits:

   | Rung | What it sheds |
   | --- | --- |
   | 0 | nothing |
   | 1 | one sample per event class instead of three |
   | 2 | the gotcha sections' headings and table rows only, not their prose |
   | 3 | the gotcha sections entirely |
   | 4 | every sample — counts and nodes only |
   | 5 | rung 4's text cut to the bound, with a marker saying so |

   Prose before counts, always: a count is the reading and a sample is only
   its illustration, so a bound that shed counts would leave the Monitor
   unable to say how big anything was. Rung 5 exists because nothing above it
   can be *guaranteed* to fit, and a run that silently sent an over-long
   prompt is the failure agent-ops#641 already paid for once. The rung reached
   and the final byte count ride on the `monitor-digest-built` and
   `monitor-stage-start` events and are stated at the foot of the report, so a
   reader can tell a thin report from a thin day. `monitor_max_input_bytes: 0`
   disables the bound and pins the rung at 0.

### The Monitor stage (`prompts/monitor.md`)

M9. **One stage, one model.** `monitor_model` (default `claude-sonnet-5`), its
   value validated by `resolve_model_id` before the stage is launched and by
   `scripts/doctor.sh`'s Models section on every unattended pass, so an
   unsupported provider is reported once an hour rather than once a day —
   the same tier the repository review runs, for the same reason: the input is
   a bounded digest rather than a repository, and the judgement asked of it is
   the one a human operator would make reading the same records. An empty
   `monitor_model` disables the pipeline outright, checked before the lock,
   the same way an empty `enabler_model` disables that stage.

M9a. **Its caps are derived.** The Monitor's backstop and inactivity
   watchdog come from `lib/stage-budget.sh`'s derivation
   (requirement 4f) under the actor key `monitor`, at repository `*` — it
   reads the fleet, not a repository, so keying it per repository would
   fragment its sample for no gain, exactly as for the Co-Ordinator and the
   Enabler. Its shipped prior is 45 minutes backstop / 10 minutes inactivity.
   The observations behind the derivation come from the union of `log.jsonl`
   **concatenated with the union of `monitor-log.jsonl`**, because this
   pipeline's own `stage-end` events live in the second stream; a derivation
   reading only the first would see no monitor run ever and hold the stage at
   its prior for ever.

M10. **What the stage is asked for.** `prompts/monitor.md` asks for three
   readings — what is broken now; what limited throughput in the last 24 h and
   which lever it points at; what is new — plus a triage verdict for every
   open page (M15), and a final JSON object carrying `status`,
   `report_markdown`, `findings[]` and `page_triage[]`. The prompt forbids
   every write: no `gh` write of any kind, no page closed, no configuration
   edited, no primary record read directly.

M10a. **The untrusted-content framing.** `prompts/monitor.md` carries the
   canonical `## Untrusted external content` block of requirement 45a,
   byte-identical and marker-delimited, pinned by
   `test/prompt-untrusted-framing.test.sh` alongside every other prompt that
   carries it. It is load-bearing here even though most of the digest is the
   pipeline's own record of itself: a pager issue's body, an escalation's
   title, a `none-selected` reason quoting an issue and a commit message in
   the forge section are all text anyone with a GitHub account can author.

M10b. **`prompt_overrides.monitor`.** The stage's prompt is assembled through
   `lib/prompt-overrides.sh` exactly as the implementation pipeline's stages
   are (requirement 4a), so an installation may extend or replace it without
   forking `prompts/`.

### Filing (the Script's own writes)

M11. **Every filing carries a provenance line and a finding key.** The
   provenance line is `Monitor: monitor/<date> M-<nn>` — R12a's pattern, so
   the Co-Ordinator can tell when the work behind a finding is done, and a
   human reading the issue can find the report that produced it. `<nn>`
   numbers **within the day**, not within the run: a pager-triggered second
   run continues from the highest number the day's report already carries, so
   one `M-<nn>` identifies one finding inside one day. A number is claimed only
   where one is about to be written into an issue body — never on every stated
   finding — so a citation and a filing are one-to-one and no `M-<nn>` names a
   row that no issue carries; a ledger row with no number renders `—` and is
   identified by its finding key, which is what the dedup and the next run both
   read anyway. The report's own ledger
   carries each finding's whole provenance line rather than a bare `M-<nn>`,
   because that string has two consumers — a reader grepping issue bodies for
   it, and the next run reading the day's highest number back — and one form
   written once is what keeps them from disagreeing. Every filing's body
   also carries `monitor-finding-key: <key>`, the machine-readable half that
   M13's dedup matches on. A finding whose key does not match
   `^[a-z0-9][a-z0-9-]{2,63}$`, or which carries no title, is refused and
   recorded as `refused` in the report rather than normalised — a run that
   quietly rewrote a key would file a second issue against the first run's
   finding.

M12. **A filing budget.** At most `monitor_max_filings_per_run` (default 3)
   GitHub items are created per run, counted across every class together. The
   Script walks `findings[]` in the order the stage returned them — that order
   is the stage's priority call — and everything past the cap is recorded as
   `deferred` in the report **with its key**, so the next run's dedup can tell
   it apart from a finding that was never stated.
   `monitor_max_filings_per_run: 0` files nothing and reports everything.

M13. **Search-first dedup.** Before the stage runs, the Script lists every
   open issue in every repository it may file into whose body carries a
   `monitor-finding-key:` marker, and hands the stage that list as
   `open_findings`. A finding whose key is already open files **nothing** and
   is recorded as `already-open` in the report, citing the open issue's number
   and URL. The listing is taken once per repository, not once per finding: a
   per-finding search would be one API call per idea on a shared rate-limit
   budget, for an answer one listing already holds. A finding filed earlier in
   the same run is added to the in-memory list, so two findings sharing a key
   inside one run dedup against each other too.

M14. **Filing by class**, mirroring `escalation_autonomy`'s own taxonomy:

M14a. **Mechanical** — a defect with a knowable fix. Filed as a
   `pw::type:tech-debt`-labelled issue in the repository the finding names, as
   the Reviewer, Implementer and Project Reviewer already file (D15 as
   revised), where the Co-Ordinator's `tech-debt` work band can select it as
   ordinary work. The repository must be one of `repos[].slug` or the
   escalation repository; a finding naming anything else is refused. A monitor
   that could open an issue in an arbitrary repository has the whole forge as
   its blast radius.

M14b. **Tactical** — a configuration lever, where the right value is a
   judgement rather than a defect. **Always** stated in the report, with the
   key, the evidence and the value proposed. It is *moved* only when the
   finding's `config_key` appears in `monitor_tactical_keys`, and then only
   through the decide-tactical seam: one `pw::decision` issue in the
   escalation repository, filed and immediately closed, which
   `scripts/sweep-decision-vetoes.sh` already sweeps for a human's reopen — the
   #937 veto window. `monitor_tactical_keys` is empty by default, so a fresh
   installation's Monitor proposes every lever and moves none. The
   `pw::decision` record states a decision; it changes no configuration, since
   `config.json` reaches a node only as a versioned change (ROADMAP D16).

M14c. **Strategic, or owner-only under requirement 36a** — a trade-off, a
   priority call, or a fact only a human holds. One `enabler_escalation_label`
   issue in the escalation repository, assigned to `enabler_assignee`, with
   the options written out. Assignment is the load-bearing half, exactly as
   for an ordinary Enabler escalation: it is what excludes the issue from the
   `issues` work source (requirement 16.4). **This is the only path from this
   pipeline to the owner.**

M14d. **Nowhere to file is not a failure.** An installation with neither
   `crash_loop_repo` nor `pager_repo` configured has nowhere to put an
   escalation or a decision record; such a finding is recorded as `proposed`
   in the report and nothing else happens. A filing that the forge refuses is
   recorded as `failed` and re-offered by the next run, since its key is still
   not open anywhere — `lib/pager.sh`'s own "the next window's evaluation
   tries again" behaviour.

### Pages triage

M15. **The Monitor is the consumer of pager pages.** For every open
   `pw::pager` issue in its digest the Monitor writes a triage verdict in the
   report, in one of the three classes above:

   - **mechanical** (a phantom — the invariant is firing on a fact that is not
     true, or true for a reason the invariant does not mean — or a defect with
     a knowable fix): the Script files the tech-debt issue under M14a and posts
     **one** comment on the page linking it, stamped with requirement 9d's
     visible header for the `monitor` actor and requirement 3e's invisible
     marker. The comment carries `monitor-finding-key: <key>`, and a later run
     that reads the page's own comments skips a page already carrying that
     key's comment — one comment per page per finding, ever.
   - **tactical**: proposed in the report, nothing posted.
   - **strategic**: left for the owner and said so in the report.

M15a. **The Monitor never closes a page.** The pager's lifecycle is
   event-sourced and transition-only (`lib/pager.sh`): a key's state is
   derived purely from the latest `pager-candidate` /
   `pager-candidate-cleared` / `pager-fired` / `pager-cleared` event in the
   union log, and the GitHub issue is a *mirror* of that log rather than the
   record itself. A close performed by anything else leaves the log still
   saying `fired`, so the key could never clear, never fire again, and never
   reach the dashboard's own state read. Closing is `pager_close`'s — reached
   when the fact behind the key clears — and `page-outlived-item`'s, the
   invariant that retires a page whose own linked pull request or issue has
   gone. The prompt states this rule to the stage as well as the spec stating
   it here, because a model asked to "deal with" a page will reach for the
   close button otherwise.

### The report

M16. **A dated report in the state store.** `state_dir/monitor/<date>/report.md`,
   carrying the stage's own three sections (what is broken now; what limited
   throughput and which lever; what is new) plus its pages section, and — added
   by the Script, not the stage — a filings ledger and a triage ledger. The
   ledger is what makes the report verifiable: one row per finding, naming its
   class, its key, its outcome (`filed`, `already-open`, `deferred`,
   `proposed`, `refused`, `failed`) with the reason, and the issue URL where
   there is one. The Script owns the heading levels — `# Monitor report —
   <date>` for the day, `## Run <id>` per run, `###` for everything inside one
   — which is why `prompts/monitor.md` asks the stage for `###` sections
   rather than `##`: a stage writing `##` would put its own readings beside
   the run heading instead of under it, and the Script's ledger would then
   read as part of the stage's last section. The report is **appended to** rather than overwritten: a
   pager-triggered second run the same day adds its own section under the
   day's heading, which is also why M11's finding numbers continue across the
   day. The file lives under `state_dir` and is carried fleet-wide by the
   ordinary state-sync push, with no dedicated sync code. Surfacing the report
   on the monitoring dashboard is out of scope here for the reason R17 gives
   for the review pipeline's own reports — the dashboard has its own as-built
   spec — and is recorded as deferred work at
   `tech-debt/TD-PPagop-26091101.md`.

M17. **A stage-health verdict, from day one.** The Monitor logs `stage-end`
   with `stage: "monitor"` and `attempt-failed` with the same field into its
   own stream, which are the exact event name and field `lib/stage-health.sh`
   already reads — so this pipeline needs no second reader. At the end of a
   run that actually engaged the stage, `stage_health_write_status` computes
   the verdict for `["monitor"]` over `monitor-log.jsonl` and **merges** it
   into `state_dir/.stage-health.json`, which `scripts/state-sync.sh` folds
   into the heartbeat and `scripts/publish-dashboard.sh` renders. The merge
   is what makes two writers of one file safe: each computes only its own
   stages and carries every other entry forward, so neither files the other's
   stages as `idle`. The dashboard's stage-health panel, its fleet-strip badge
   and its red banner all iterate the `stages` object rather than a fixed
   list, so the monitor row appears wherever the review pipeline's verdict
   would (`docs/DASHBOARD-SPEC.md`). This closes for this pipeline, at its
   first release, the gap agent-ops#996 records for the review pipeline.

### Logging and state

M18. **Streams.** Monitor *operational* events go to
   `state_dir/monitor-log.jsonl` — this pipeline's own stream, keyed by a
   `monitor` id (`<UTC-timestamp>-<node>-<pid>`, pid last, exactly as
   requirement 33 shapes the cycle id), so the dashboard's `log.jsonl` parser
   is untouched and the three pipelines stay separable. It reuses
   `lib/log-event.sh`'s envelope. Events: `monitor-start`,
   `monitor-stand-down`, `monitor-skipped`, `monitor-digest-built`,
   `monitor-stage-start`, `stage-end`, `attempt-failed`,
   `monitor-report-written`, `monitor-end`, `warning`, and — written by
   `lib/github-limit.sh`'s `github_budget_record` through this script's own
   `log_event`, as it does for every stage of the other two pipelines
   (requirement 2.0d) — `github-budget`. Common fields: an
   ISO-8601 `ts`, a `monitor` id, `node`, an `event`. `stage-end` carries
   `stage: "monitor"`, `exit_code`, an optional `kill_reason`, and the
   metering record of requirement 33a via `lib/metering.sh`
   (`docs/METERING-SCHEMA.md`). `monitor-report-written` carries `date`,
   `path`, `trigger`, `findings_stated`, `findings_filed`, the whole `ledger`
   and the whole `page_triage` — it is the durable record of what one run did,
   and it is what M4's own due gate reads.

   The one exception is the shared `limit-hit` event, written to `log.jsonl`
   (M3.1), because usage-limit stand-down is shared across all three
   pipelines.

M18a. **`monitor-log.jsonl` is never rotated.** It joins `log.jsonl`,
   `review-log.jsonl` and `revert-rate.jsonl` in `scripts/rotate-logs.sh`'s
   never-touched set, for the same reason: the fleet unions it to decide whose
   turn the daily run is and when the last report was written, and a rotated
   head would let every node think the day's run is still owed.
   `monitor-cron.log` — the crontab line's own text output — is rotated like
   `cron.log` and `review-cron.log`.

M19. **No `node-state` transition.** The Monitor writes none of requirement
   50's `node-state` events. `docs/FLOW-SCHEMA.md`'s fold reconstructs one
   timeline per node from two writers that already coordinate through the
   `impl_cycle_running` checks; a third writer contributing a few minutes a
   day would risk clobbering a live `producing` span for a smaller gain than
   the risk. This pipeline's own wall-clock is recoverable from its
   `monitor-stage-start`/`stage-end` pair. Recorded as deferred work at
   `tech-debt/TD-PPagop-26091102.md`.

## Components

1. `monitor-cycle.sh` implementing M1–M5, M9a, M11–M16 and M18.
   `shellcheck`-clean; sets its own `PATH`.
2. `lib/monitor-digest.sh` implementing M6, M6a, M6b and M7. Pure readers,
   unit-tested over fixture logs (`test/monitor-digest.test.sh`);
   `shellcheck`-clean.
3. `prompts/monitor.md` implementing M10, M10a and M15.
4. `lib/stage-health.sh`'s `STAGE_NAMES_JSON` parameter and merging writer,
   implementing M17.
5. `lib/stage-budget.sh`'s `monitor` prior, implementing M9a.
6. `lib/pipeline-marker.sh`'s `monitor` token and `dashboard/index.html`'s
   `ACTOR` entry, implementing requirement 9d for this actor.
7. `deploy/docker/crontab.tmpl` + `deploy/docker/render-crontab.sh`'s
   `@MONITOR_MINUTE@`, implementing M4's hourly line.
8. `config.schema.json`'s `monitor_*`, `schedule.monitor_*` and
   `prompt_overrides.monitor` keys, and the regenerated configuration tables.

## Acceptance checks

Every change to this pipeline must leave all of these passing; before opening
a pull request, run the ones the change touches and any it could regress.

The implementation pipeline's *Acceptance checks* preamble carries one rule
that applies here unchanged: **no check may expect a particular value from
`config.json`.** The shipped file is asserted to be valid; every fixture
supplies its own values.

1. `shellcheck monitor-cycle.sh` and `shellcheck lib/monitor-digest.sh` are
   clean (`./scripts/lint-shell.sh`).
2. **The digest is what it says it is (M6, M6a).**
   `test/monitor-digest.test.sh` passes: over a fixture union log, events are
   grouped by class with counts, contributing nodes and at most three of the
   *newest* samples; events outside the 24 h window are excluded; the pager
   section separates transitions from open pages; the node section reads a
   peer's verdicts from its `heartbeat.json` and this node's from
   `.stage-health.json`, and carries each node's host-facts record or `null`;
   the throughput fold counts selections per source, stand-downs per cause,
   `none-selected` reasons verbatim and the fit rung histogram; the gotcha
   reader lifts a `## Gotchas` section and contributes nothing for a file
   without one; and every reader returns its empty shape for a missing file
   rather than failing.
3. **The bound holds exactly (M7).** Same file: the rendered digest is never
   larger than `monitor_max_input_bytes`, measured in bytes, at every rung
   including the truncating one; the rung climbs monotonically as the bound
   tightens; and `0` disables the bound and reports rung 0.
4. **Four findings file three and defer the fourth by key (M12).**
   `test/monitor-cycle.test.sh` passes: with a stubbed `claude` returning four
   findings and a stubbed `gh`, exactly three issues are created, the fourth
   is recorded `deferred` in the report **with its finding key**, and each
   filed issue's body carries `Monitor: monitor/<date> M-<nn>` and
   `monitor-finding-key: <key>`.
5. **Dedup (M13).** Same file: a second run whose findings carry the same keys
   creates no issue at all, and the report cites the open issue's number for
   each.
6. **The tactical gate is closed by default (M14b).** Same file: a tactical
   finding with `monitor_tactical_keys` empty produces a proposal in the
   report and **no** `pw::decision` issue; with the key listed, it produces a
   `pw::decision` that is created and then closed.
7. **The stage-health verdict exists (M17).** Same file: after a run,
   `state_dir/.stage-health.json` carries a `monitor` entry, and an
   implementation-pipeline write of the same file does not remove it
   (`test/stage-health.test.sh` covers the merge in isolation).
8. **The untrusted framing is byte-identical (M10a).**
   `test/prompt-untrusted-framing.test.sh` passes with `prompts/monitor.md` in
   its list.
9. **The cadence gate (M4).** Same file: a tick at an hour that is not
   `schedule.monitor_hour`, with no `pager-fired` newer than the last report,
   stands down with `cause: "not-due"` and launches no `claude`; a
   `pager-fired` newer than the last report makes the same tick due.
10. **The role guard and the switch stand this pipeline down too (M2a/M2b).**
   Same file: `AGENT_OPS_ROLE` unset exits 0 with one line and writes nothing
   under `state_dir`; a set node switch logs `monitor-stand-down` and launches
   no `claude`.
11. **The config tables regenerate clean.** `scripts/render-config-table.sh
   --check` passes.

## Gotchas

| Signature | What it actually is |
| --- | --- |
| Every node writes the day's monitor report, and the same findings are filed three times | The slot claim (M5) is not reaching the state repository — `state_repo` unset, or `lib/claim.sh` failing. Check `claims/monitor/` in the state repository and the run's own `claim.log`. With `state_repo` genuinely unset this is expected single-node behaviour, not a fault. |
| `monitor-stand-down` with `cause: "not-due"` on every tick for days, including at `schedule.monitor_hour` | A `monitor-report-written` event with today's date already exists in the union — usually because a peer ran it, which is correct. If no peer did, the node's clock or `date -u` is wrong, or `monitor-log.jsonl` is not replicating (check `state-sync.sh` and this file's absence from `EXCLUDES`). |
| The report is thin and says little, on a day that plainly had faults | Check the run's `digest_rung` on `monitor-digest-built`. A rung of 3 or more means the gotcha sections were shed; rung 5 means the text was cut mid-section. Raise `monitor_max_input_bytes`, or find out why the day's event stream was large enough to force the ladder down. |
| A finding is restated in every report and never filed | Its key is already open somewhere (M13 is working as designed and the report says `already-open`), or the run's budget was spent before it was reached (`deferred`), or the class is `tactical` and its key is not in `monitor_tactical_keys` (`proposed` — also as designed). The ledger row names which. |
| A pager page is triaged `mechanical` every run and no comment appears | The linked finding was never filed (deferred, or its repository was refused), so there is nothing to link. The comment is posted only where the finding is actually open. |
| A page stays open long after the Monitor called it a phantom | Correct and deliberate (M15a). A page retires only through `pager_close` or `page-outlived-item`. If the fact really has cleared and the page has not, the bug is in the invariant's own evaluation, not here. |
| `.stage-health.json` shows `monitor` as `idle` on a node that runs it | The verdict is written only by a run that actually engaged the stage. A node whose every tick stands down (not due, standby, deferring to a sibling) never writes one, which reads as `idle` — "this stage has had no work" — and is true. |
| The Monitor's backstop never moves off 45 minutes | `lib/stage-budget.sh`'s derivation is being handed only `log.jsonl`. The monitor's own `stage-end` events live in `monitor-log.jsonl`, and M9a's concatenation is what puts them in front of the derivation. |

## Cost profile

One Sonnet invocation per run, over a digest bounded by
`monitor_max_input_bytes` (default 300 KB) — far short of the Co-Ordinator's
own bound, and with no repository clone at all. The daily slot is one run per
fleet per day; a `pager-fired` event buys at most one extra run per hour, and
in practice far fewer, since a page that fires and stays fired triggers
exactly one. A not-due tick costs no model call at all — a union snapshot, a
few `jq` folds, a lock taken and released, and an exit. The Script itself makes at most four forge listings per run
plus one per configured repository for the dedup.

## Design decisions

Recorded so a future reader knows they were deliberate. History and
superseded approaches belong here, never in the requirements above, which
state only what is.

- **A third pipeline, not an operator-side session.** The #1126 comment
  recommended the AI observer as something a human ran. Under the owner's
  2026-09-08 direction — autonomous, in-product, orchestrated-container
  compatible — a scheduled sibling is the only shape that satisfies all three,
  and it costs one script rather than a habit nobody keeps.
- **The Script files, not the stage.** The bounded count, the dedup, the
  provenance line and the veto window are guarantees, and a guarantee a prompt
  asks for politely is not one. This is the same division
  `lib/tech-debt-file.sh` already draws for the Approver and the Enabler, and
  for the same reason: a stage that must not write to GitHub is much easier to
  keep honest than a stage that must write to GitHub correctly.
- **An hourly line with a due gate, not two crontab lines.** The daily half
  could be a crontab line. The pager half could not: supercronic fires on a
  clock, and "within the hour after a `pager-fired` event" is a fact about the
  fleet's own log. One line and one gate keeps the whole cadence in one
  readable place; the price is a stand-down event on most ticks, which costs
  an exit and buys a log that says exactly why each tick did nothing.
- **A fleet slot claim rather than per-node runs.** Four active nodes would
  otherwise each spend a model on the same day's digest and reach four nearly
  identical readings. The dedup would keep the duplicates off GitHub, but only
  after the money was spent.
- **`monitor_tactical_keys` is empty by default.** The tactical path is real
  and wired, and it is config-gated closed until an owner has read a few
  reports and decided which levers to delegate. Shipping it open would be
  asking for trust the pipeline has not yet earned on this particular
  judgement; shipping it absent would leave the seam unbuilt and the first
  delegation a feature request.
- **The report is appended, not one file per run.** A day is the unit a reader
  thinks in, and `monitor/<date>` is the provenance line's own citation. A
  file per run would make `Monitor: monitor/<date> M-<nn>` ambiguous on any
  day with two runs, which is precisely the day worth reading.
- **The Monitor defers to the review pipeline as well as to the
  implementation cycle.** R3.2 names one lock because the review pipeline was
  the newcomer when it was written. The reason it gives is about quota, not
  about which pipeline is senior, and the Monitor is the cheapest of the three
  to postpone.
