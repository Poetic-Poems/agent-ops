# Monitoring Dashboard — as-built specification

Companion to `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (the pipeline spec). This document
describes the local monitoring dashboard **as built**: what it is, the state
it reads, how it is assembled, and the decisions behind it. Use it to
understand, modify, or regenerate the dashboard — and keep it accurate: any
change to the dashboard lands together with the edit that keeps this
document describing what actually exists (see `CLAUDE.md`, "As-built
specifications"). Where it says "requirement N", it means requirement N of
`docs/IMPLEMENTATION-PIPELINE-SPEC.md`.

## What it is

A single-page dashboard for watching and debugging the autonomous agent
pipeline: current status, usage-limit stand-downs, open agent PRs and their
CI, recent cycles with per-stage cost/duration/model, failures, blocked and
void items, the work sources the Co-Ordinator sees, spend by day, by model and
by actor, which version each node is running, the raw log, and each stage's
transcript inline.

Three properties are deliberate and non-negotiable:

- **Local and private.** Nothing is published anywhere. The site is generated
  onto local disk and opened in a browser. There is no server and nothing
  listening on a network address (an optional loopback-only server exists
  purely as a `file://` fallback), and no GitHub Pages. The pipeline's
  operational telemetry — costs, cadence, failure detail, agent reasoning —
  never leaves the machine except, when the optional tailnet access documented
  in the README is installed, to the owner's own signed-in devices:
  `tailscale serve` proxies the unchanged loopback server over the owner's
  private tailnet, and nothing ever gets a public URL.
- **Free to run.** The generator is `bash` + `jq` + `gh` on the existing cron
  cadence; the page is a static file; there are **no model calls anywhere**.
- **A reader, never a participant.** It only reads the pipeline's state and
  GitHub. It never writes into the state tree, never touches the lock, and
  cannot slow or disturb a running cycle. It redacts home paths and
  token-shaped strings so a screenshot is safe to share.

## Architecture

```
pipeline state (this machine)            GitHub (public repos, via gh)
  ~/.local/state/poetic-agents/            open agent PRs + checks, failed runs,
    log.jsonl, cycles/<id>/*.out,          issues, tech-debt, and security /
    lock.json, cron.log                    code-quality findings (via
                                           scripts/gather-findings.sh)
        │                                        │
        └────────────┬───────────────────────────┘
                     ▼
        scripts/publish-dashboard.sh   (the Publisher)
          → <state_dir>/dashboard/data.js   (redacted JSON, generated)
          → <state_dir>/dashboard/index.html (copied from repo)
                     │
                     ▼
        open index.html in a browser  (file://, no server)

Refresh triggers:  end-of-cycle hook in agent-cycle.sh
                +  */5 cron → publish-dashboard-launcher.sh (sub-minute ticks)
```

The page (`dashboard/index.html`, the source of truth, committed) loads its
sibling `data.js` with a plain `<script src>` tag — which works from a
`file://` URL with no server. The Publisher rewrites `data.js` and copies the
page next to it each run. Opening the page needs nothing else.

## State it reads (verified 2026-07-14)

All paths derive from `config.json` (tilde-expanded `state_dir` and
`workspace_root`), read the same way `agent-cycle.sh` reads them.

- **`log.jsonl` — the FLEET's, not just ours** (requirements 33 and 2.5): this
  node's log unioned with every peer's fetched copy, via the same
  `lib/fleet.sh` read the pipelines use. Parsed line-by-line
  with `fromjson? // empty` so a half-written trailing line (the Script may be
  appending) never aborts the parse. Blocked items use requirement 34's
  semantics (most recent `attempt-failed`/`unblocked` per `repo`+`item`) *less*
  the void set, which is requirement 34h's `open_blocked_items`; void items use
  requirement 34c's (most recent `item-void`/`unvoided`). Both come
  from the shared library, never from a local copy of the rule. With no peers
  the union reduces exactly to the old local read. Each blocked row is joined
  against the `escalated` and `enabler-examined` events *later than that block*
  (implementation spec 35, 36a), which is what gives the row its escalation link
  and the Enabler's last verdict; a mark older than the block belongs to an
  earlier one and is ignored.

  **Not every record in it came from a cycle.** A human may append one by hand
  — an `unvoided` to reopen an item, an `unblocked`, a `limit-hit` — and those
  carry the `cycle: "manual"` sentinel of implementation spec 33. The Publisher
  therefore admits to the cycle list only ids of the pipelines' own shape
  (`^[0-9]{8}T[0-9]{6}Z-`); every other id is a record about the pipeline
  rather than a run of it, and belongs in the log tail alone. The readers that
  act on those records — the limit stand-down, the blocked and void sets — key
  on the event and the item, never on the cycle, so none of them notices the
  distinction.
- **`<workspace_root>/.agent-ops-peers/<node>/`** — each fetched peer's state
  tree (implementation spec 2.5): its `heartbeat.json` becomes a `fleet.nodes[]`
  entry ({node, role, heartbeat, last cycle, version, compose, image, switch};
  older than 30 minutes → `stale: true` — three missed pushes, not clock
  jitter); its `cycles/<id>/`
  and `reviews/<id>/` transcripts
  render peer cycles with exactly the fidelity of local ones, and its `.out`
  envelopes join the fleet-wide cost roll-ups (every node spends one Claude
  account, so per-node spend would be the misleading number). The merged cycle
  detail list is capped at `MAX_CYCLES` *fleet-wide*, newest first across all
  nodes — that cap is what holds `data.js` near its single-node size however
  many nodes report. An id that exists on disk always renders from the owning
  node's directory (the D-before-E source ranking in the Publisher); an id
  known only from events renders from its events alone.

  **A no-op tick holds none of those slots** (issue #271). The `*/15` cadence
  makes most firings no-ops — the stand-down short-circuit (`cycle-start` →
  `stand-down` → `cycle-end`) and the lock-held skip (`cycle-start` →
  `cycle-skipped` → `cycle-end`) — and at a slot each they shrank the window
  from half a day of history to a couple of hours of mostly nothing. The
  Publisher classifies them ahead of the cap, by exactly those event shapes,
  and surfaces them as the single O(1) `noop_ticks` aggregate — total, split
  by the outcome value the ladder would have given the row (`stand-down` /
  `skipped`), and the newest timestamp — never as rows or a second list,
  because the cap is what protects `data.js`'s size and the aggregate must
  not grow with what it counts. A cycle that logged anything beyond those
  shapes keeps its row: a raced stand-down (`claim-lost`, 17d's badge), a
  pre-claimed one (`claim-skipped` — a selection defect, implementation spec
  17a), a hand-appended `unvoided` sharing its id, or a kill that cost it its
  `cycle-end` all carry information a count would bury.

  Its **`log.jsonl` is also what says whether that peer is working, and on
  what** — `fleet.nodes[].live`. A peer publishes no lock (state-sync excludes
  it: a copied lock is a lock no process holds), so the answer is derived from
  the peer's own most recent cycle in the union stream, which requirement 33's
  `node` stamp makes separable: running until that cycle logs `cycle-end`, the
  live stage being the last `stage-start` with no matching `stage-end`, and the
  work whatever its `selection` event named. That derivation cannot see a node
  killed mid-cycle — a `cycle-start` with no end looks the same as one still in
  flight — so the page bounds the claim rather than the Publisher overstating
  it: a stale heartbeat renders as "state unknown", and a cycle running past
  `lock_stale_after` (the pipeline's own bound, past which it would take such a
  lock over — a derived figure since requirement 4f, which the Publisher
  computes and passes under that name) is flagged as possibly dead. A second,
  far earlier bound catches the case that actually happens. Every stage is
  capped by its own backstop, which `run_claude_stage` enforces by killing the
  process group and logging
  `stage-end` after — so a live stage older than its cap is not a slow stage but
  one whose process is already gone, and the page says so in minutes where
  `lock_stale_after` takes hours. A Co-Ordinator capped at twenty minutes
  against that rule's several hours is the whole of the gap: a node rolled
  mid-cycle read as
  "coordinator choosing work" for most of the way to its next cycle. Both bounds
  are measured to the node's own heartbeat rather than to the reader's clock —
  what is known is what that node had published, and both timestamps are stamped
  by its clock, so the difference carries no skew between machines.
  `live.stage_since` is what makes this answerable, and `live.stage_backstop_min`
  — the cap that stage was actually given, announced on its own `stage-start`
  and carried through unchanged — is what it is held against. Every stage now
  has its own, so a shared configuration key could only ever approximate it;
  `config.stage_backstops`, the fleet-wide widest per actor, is the fallback for
  a row whose event predates the announcement, and a shipped prior the fallback
  after that. A stage none of those names (the review pipeline's) is one the
  rule makes no claim about.
- **`fleet-cache/{disabled,limit}.json`** — the fleet flags' cached copies
  (requirement 2.3a), maintained by `lib/toggle.sh` and refreshed by this
  Publisher's own GitHub tick. Read as plain files, so a `--no-github` tick and
  a standby node surface them with no API call. Surfaced as `fleet.flags` and
  rendered as banners: the fleet switch (suppressed when the local switch
  banner already covers it — the setting node writes both levels), and the
  fleet-wide usage-limit stand-down (shown when the local log union has not
  caught up — a standby with no state yet, or a hit seconds old elsewhere).
  Both banners name the flag's `actor` (falling back to the older `by` /
  `node` fields on records that predate it) and its `kind` (requirement 2,
  #244) — whose decision the stand-down is, and whether it was a decision at
  all: a `manual` limit record renders in the operator's voice ("set by …
  (manual)", never probed, `--clear-limit` lifts it early) rather than the
  detector's estimated-retry phrasing.
- **`fleet-cache/merge-autonomy-kill.json`** — the D18 merge-autonomy kill
  switch's own cached copy (D18 issue #576, `lib/merge-autonomy.sh`'s
  `MERGE_AUTONOMY_KILL_FLAG`). Narrower than the `disabled`/`limit` flags
  above and read differently from them for it: those two fail *open* on an
  unreadable record, so their raw cached bytes (`null` when clear) are the
  whole story; the kill switch fails *closed* (an unreachable state repo with
  no cache reads as engaged, `lib/merge-autonomy.sh`'s own header), a
  distinction only `merge_autonomy_kill_state` draws. This Publisher never
  calls that function outside its own GitHub tick — it always attempts a live
  fetch the first time a process asks it, which a `--no-github` tick or a
  standby node must not pay for — so the `--no-github`/local-only value runs
  the raw cache through `_toggle_eval` instead (the pure half of the same
  machinery, no network), defaulting to `{"state":"enabled"}` when no cache
  exists at all: a display default for "nothing confirms a kill", never the
  live gate's own fail-closed reasoning, which only applies once a fetch has
  actually found the repo unreachable. The live GitHub tick calls
  `merge_autonomy_kill_state` for real and overwrites this value with its
  accurate answer, fail-closed synthesis included. Surfaced as
  `fleet.flags.merge_autonomy_kill` — `{state, record?}`, `lib/toggle.sh`'s
  own vocabulary — and rendered as its own banner, deliberately not folded
  into the fleet-switch banner above: cycles keep running while the kill
  switch is engaged, only landing collapses to `human` fleet-wide, so "every
  node stands down" would misreport it. A `record.kind` of `"fail-closed"`
  (the marker `merge_autonomy_kill_state` writes and nothing else does) omits
  the `--restore-merge-autonomy` advice a genuine `manual` kill's banner
  carries, since no command fixes a state-repo outage. `scripts/doctor.sh`
  reads the same function directly (its own "the merge-autonomy kill switch
  is …" line) — this is the same position, on the dashboard instead of a
  one-shot pass.
- **`disabled.json`** — the switch (requirement 2.3), read through
  `lib/toggle.sh`: the same code the pipelines gate on, so the dashboard cannot
  disagree with them about whether cycles are meant to be running (requirement
  34a). Surfaced as `status.switch` and rendered as the *first* banner, ahead
  of the usage-limit one.

  This panel earns its place by being the one thing a disabled pipeline looks
  like. Everything else on the page renders a disabled pipeline exactly as it
  renders a quiet one: no cycles, no PRs, no failures, no errors. Without the
  banner, a switch someone set on Tuesday is indistinguishable from a week with
  nothing to do — which is how it goes unnoticed until Friday. Show the reason,
  who set it (`actor`, falling back to `by`), its kind, and its expiry (or that
  it has none and needs `--enable`), since those are precisely the questions an
  operator has next.

  The same read (`toggle_switch_summary`, `lib/toggle.sh`) also feeds the
  node card's own **disabled** badge (implementation spec 2.3, `--this-node`
  — the graceful, single-node form): a node stood down that way sets no flag
  file anything else on this page reads, so without a badge on its own card it
  looks exactly like an idle one. This node's copy is read live, the same as
  its role and lock; a peer's arrives in its heartbeat as `switch`, on the
  same absent-means-unknown rule every other peer-only field on the card
  follows — a peer whose heartbeat predates the field, like one whose image
  or compose verdict does, renders no badge rather than a false "enabled".

  **A record's `scope` decides which of those two things it is** (implementation
  spec 2.3). A fleet-wide `--disable` also writes a local record on the node
  that issued it, tagged `scope: "fleet"` — a *mirror* of the fleet switch, not
  a stand-down of that node's own. While `fleet.flags.disabled` is set the page
  suppresses both the local banner and that node's badge in favour of the fleet
  banner, because one decision must not render as two problems, and an amber
  **disabled** badge on exactly one node of a uniformly-down fleet reads as a
  fault peculiar to that node. When the fleet flag is *clear* and a mirror
  survives, the opposite applies and both render, saying so: that node alone is
  standing down under a fleet decision lifted elsewhere — `--enable` on a peer
  clears the flag but cannot reach this node's file — and nothing else on the
  page would account for it.
- **`cycles/<cycle-id>/<stage>.out`** — the stage's `result` envelope: the
  final line of the event stream `claude --output-format stream-json` wrote,
  truncated into this file by `run_claude_stage` and identical to what
  `--output-format json` used to leave here (requirements 11 and 4d). The
  stream itself, `<stage>.stream.jsonl`, is local to the node that ran it and
  never replicates, so this Publisher never sees one on a peer and reads none
  on its own node either. Fields used: `result` (final message → parsed
  into the work order / status object via the same algorithm `agent-cycle.sh`
  uses — straight parse, else the last fenced ``` block regardless of its
  info string (a bare fence or one tagged anything other than `json` is not
  ambiguous — only the fence's presence is, issue #237), else the
  earliest brace-opening line whose suffix parses as one JSON value;
  `test/extract-json-result.test.sh` holds the ports to it), `total_cost_usd`,
  `duration_ms`, `num_turns`, `is_error`, `terminal_reason`/`stop_reason`,
  `modelUsage` (→ model id). `<stage>.out.stderr` is shown for debugging.
  `docs/METERING-SCHEMA.md` is the formal contract for these fields — types,
  units, and what change to them is additive versus breaking — reused
  unchanged by the per-stage record `lib/metering.sh` writes to `log.jsonl`
  (requirement 33a); this reader and that one derive the same figures
  independently from the same envelope and are expected to agree.

  The **actor** that spent it is the transcript's own filename, and needs no
  new field: `cycles/<id>/{coordinator,implementer,reviewer,enabler,refiner}.out`
  name themselves, and `reviews/<id>/reviewer-<repo>.out` is normalised to
  `project-reviewer` from the directory two levels up — it belongs to the
  weekly pipeline, not to the cycle Reviewer. Any other stem passes through
  verbatim, on the same fail-open rule as the source labels below.
- **`reviews/<review-id>/reviewer-<repo>.out`** — the weekly project-review
  pipeline's envelopes, read by the cost scan on exactly the same terms as a
  cycle's. It is one Claude account paying for both pipelines, so a roll-up
  that skipped this directory was not a per-pipeline figure but a wrong total —
  and it skipped the single most expensive actor per run, which is also the one
  an operator is most likely to be weighing up.

  `total_cost_usd` is a **local estimate computed from token counts**, priced
  as though the tokens had been billed per-token through the API. Under the
  subscription auth this pipeline runs on, it is not an amount charged and not
  a draw against any plan limit — it measures work done, not money spent. The
  envelope carries no quota, rate-limit, or credits-remaining field of any
  kind; do not expect one to appear here. See the design decision on plan
  limits below before building anything that treats these dollars as budget.
  Missing/partial files degrade to a null stage — never a crash.
- **`lock.json`** — `{pid, started_at, host}`. A live pid means a cycle is
  running now — but `kill -0` only answers that question inside the PID
  namespace that minted the pid, and the dashboard shares the scheduler's
  state volume without ever sharing its PID namespace (they are separate
  containers, `deploy/docker/compose.yaml`). So the Publisher reads `host`
  (the container that wrote the lock) first: only when it matches this
  container's own `$HOSTNAME`, or is absent (a lock predating the `host`
  stamp), does it trust `kill -0`. Any other lock is unanswerable from here —
  a pid that happens to match a live process in the dashboard's own namespace
  proves nothing about the scheduler's, and the reverse — so it reads as not
  alive, exactly as if there were no lock at all; `fleet.nodes[].live` for
  this node then falls back to the same log-derived state a peer's row uses.
  This is the same namespace confusion #130 fixed in the watchtower
  pre-update hook and TD-PPagop-26072901 fixed in both cycle scripts'
  `acquire_lock`. The cycle id is `<started>-<node>-<pid>` (older records
  `<started>-<pid>`) and the lock carries that same pid — last in either
  shape —
  so the running cycle's own events are exactly those whose id ends in
  `-<pid>`. From them the Publisher derives `status.current` — what the live
  cycle is working on right now: the running stage (the last `stage-start` with
  no matching `stage-end`) and the item the Co-Ordinator selected
  (`repo`/`item`/`source`/`title`). It is `null` when idle, and its fields fill
  in as the cycle progresses — `repo`/`item`/`title` appear only once selection
  has happened, since the Co-Ordinator stage runs before it has chosen anything.

  This is also **our own** `fleet.nodes[].live`, rather than the log derivation
  the peers get: a live pid is not an inference, and the derivation is wrong in
  one real case anyway — a tick that starts, finds the lock held and ends is the
  newest `cycle-start` on this node while the cycle actually holding the lock is
  still running. With no live lock our row falls back to the peers' derivation
  and is marked not running; a `cycle-start` with no `cycle-end` behind a dead
  lock is a cycle that was killed, and the page says so rather than rounding it
  to "idle".
- **`cron.log`** — tail shown, for "cron fired but nothing happened".
  `scripts/rotate-logs.sh` (agent-ops `IMPLEMENTATION-PIPELINE-SPEC.md`
  requirement 2.6) renames it to `cron.log.1` once it grows past
  `log_retained_bytes`, so the tail is read from `cron.log.1` followed by
  `cron.log` — never the live file alone — and a rotation never empties the
  panel.
- **`build-info.json` (in the image) or git `HEAD`** — what code this node is
  running, read through `lib/version.sh` and reported as `fleet.nodes[].version`
  ({pr, commit, short, built_at, repo, source, dirty}). `.dockerignore` keeps
  `.git` out of the image — the image is a deployment of this repository, not a
  copy of a working tree — so CI stamps the answer in at build time
  (`.github/workflows/build-image.yml`, `deploy/docker/Dockerfile`), and this
  reader falls back to git for a checkout, and to `null` for neither. The
  **pull request** is the useful half: a SHA names the bytes, `#89` names the
  change, and the page renders it through the same record card as every other
  number. Our own is read directly; a peer's arrives in its heartbeat, because
  a peer publishes no container. See the design decision on version skew below.
- **GitHub, via `gh`** (best-effort; the machine is authenticated and the
  repos are public): open PRs carrying `pr_label` with `statusCheckRollup`,
  `mergeable`, `mergeStateStatus`, `reviewDecision`, author, labels,
  draft/ready, and merge-queue state (`queued`/`dequeued`, D17 — see the
  Publisher below); most-recent-per-workflow
  failing runs on the default branch; open issues, each with the `Priority`
  band the Co-Ordinator ranks it by (read from the REST issues listing's
  `issue_field_values`, since `gh issue list --json` cannot see issue fields,
  and defaulted to `Medium` exactly as the pipeline defaults it — see the
  implementation-pipeline spec, requirement 15e); security and code-quality
  findings, via `scripts/gather-findings.sh`; the tech-debt register's
  unresolved items — one listing read of `contents/tech-debt` for the roster
  and each item's blob SHA, then that item's own `title` and `status` out of
  its frontmatter, capped at 40 (`{id, title, status, url}`; an ID names no
  work, and a mature register is mostly resolved items the Co-Ordinator will
  never pick up, so those are dropped here); and one record per pull request
  the page refers to (`github.pr_index`, keyed `<owner>/<repo>#<number>`) — the
  open ones from the query above, the rest by `gh pr view`, cached permanently
  once terminal (see the Publisher).

  Four of the five sources above (issues, failing runs, the tech-debt
  listing, findings) are read per repo as one of two states, `answered` or
  `failed`, carried in `github.inputs[<slug>].state` — the tech-debt listing
  alone can also read a third, `answered_404`, for a repo with no register
  (below) — rather than the call's raw output being trusted at face value;
  `pr list` keeps its own long-standing pass/fail signal folded straight into
  `github.ok`/`github.error` instead, since no per-repo PR count is ever
  rendered for a `failed` marker to replace. The reason for the other four is
  that they used to conflate "nothing to report" with "the call did not
  answer": `gh_json` (the Publisher's plain reader) discards stderr, so a call
  that timed out, rate-limited or 500'd printed nothing, and nothing is
  exactly what a legitimately empty result also prints. A repo's tech-debt
  ledger can be genuinely empty since the resolved-items drop (PR #163), so
  "no unresolved debt" and "the listing call failed" had become
  indistinguishable on the page — observed directly during that PR's own
  testing, where a repo's ledger read empty on one tick and thirteen items
  the next with nothing in the register having changed (TD-PPagop-26080201).
  `gh_call` (the Publisher's stderr- and exit-status-preserving reader,
  alongside `gh_json`) and `gather-findings.sh`'s own exit code are what make
  the distinction: for the tech-debt listing, `answered_404` is reserved for
  a legitimately empty case the API itself says so about — a repo with no
  `tech-debt/` directory returns 404, the same way
  `gather-register-hygiene.sh` already told that apart from a real failure —
  and anything else non-2xx is `failed`. `gather-findings.sh` draws the same
  line without a state of its own to carry it: a repo with neither alert type
  enabled (403 or 404, provided a 403's own message does not name a rate
  limit) still exits 0 and reads `answered`, exactly as a repo with both
  features on and nothing open does; only a real failure — a timeout, rate
  limit or outage — exits 1 and reads `failed`. A `failed` source renders a
  "couldn't read" marker in place of its count, never a bare zero (see the
  Site, below); an `answered_404` source renders as an ordinary, honest zero.
  `github.ok`/`github.error` reflect a `failed` state from *any* of the five
  sources, not only `pr list`'s (historically the only one that raised the
  "GitHub unavailable" banner). If `gh` fails, the GitHub panels mark
  themselves stale and the rest still renders. On a `--no-github` refresh the
  fetch is skipped entirely and the last successful result is carried
  forward (see the Publisher below), so only a fetch that was *attempted and
  failed* ever shows as unavailable.

**Usage-limit detection.** The pipeline's own detector and the Publisher share
one phrase pattern and reset-time parser (`lib/limit-detect.sh`), so a
weekly-limit message ("resets Jul 17, 4am …") or a monthly spend-cap message
now gets logged as `limit-hit` by the Script itself, not just spotted by the
dashboard. The Publisher still also scans recent transcripts for limit
phrasing directly, as a backstop for any cycle where a `limit-hit` never made
it into the log for some other reason (a crash before `log_event` ran, or a
cycle from before this detector existed) — so the dashboard can still show a
stand-down the log itself missed.

The banner is built from the same reduction the pipelines gate on
(`limit_union_record`), so a `limit-cleared` event retires the banner at the
moment it retires the stand-down; a dashboard still reporting a limit the
pipelines have lifted would be exactly the disagreement requirement 34a
exists to prevent. Its wording comes from `limit_describe`, which states
whether `resume_at` is a reset the provider gave or an interval this system
chose. An estimate presented as a deadline gets waited out instead of
questioned — which is how a lifted spend cap kept the fleet down for a
further 22 hours on 2026-07-26 — so an unstated reset is labelled as such and
names both ways out: the plan's rollover, which needs nobody, and raising the
cap then running `agent-cycle.sh --clear-limit`, which needs a human and only
if sooner is wanted. Flags written by a node on the previous release carry
`needs_human` instead of `reset_known`; the banner inverts it rather than
treating its absence as "reset known".

## The Publisher (`scripts/publish-dashboard.sh`)

Reads the state above, assembles one JSON object, redacts it, and writes it
as `window.DASHBOARD_DATA = {…}` to `data.js` (atomically: temp file + `mv`).
It is `set -uo pipefail` (not `-e`) because most reads are best-effort, and
ends `exit 0`. It sets its own `PATH` for cron and is `shellcheck`-clean.
It stays inside the heartbeat's 5-second budget as history accumulates: the
transcript cost scan reads envelopes in batches (one `jq` per 25 files, the
cycle's day and instant both derived from `input_filename` — the cycle/review
id's own `YYYYMMDDTHHMMSSZ-…` prefix reformatted to a plain ISO 8601 `ts`,
`null` for a directory name that doesn't match it rather than a guessed one;
a torn mid-write envelope costs at most the rest of its batch for one tick),
the detail window (the `MAX_CYCLES`
cycles shown with transcripts) is assembled in a single `jq` program over
every stage file the window touches — handed in via `--rawfile`, so jq opens
each one itself rather than a fork per cycle re-reading and re-parsing it —
plus the fleet-wide event union slurped once, and every potentially large
intermediate reaches `jq` as a file, never argv (a single argument caps at
128 KB, which transcript-bearing JSON exceeds).

`data.js`'s size is dominated by capped transcripts, not by the small
per-item records like `blocked[]`: one cycle at both caps (`TRANSCRIPT_CAP`
of `result` and of `stderr`, on all three stages) measures 245,676 bytes on
its own — `(40000 + 40000) * 3` bytes of capped text plus ~5.7 KB of envelope
and structure — so the `MAX_CYCLES`-cycle window bounds near `40 *
245,676 ≈ 9.4 MB` in the pathological case of every shown cycle maxing out
both caps on every stage (measured directly, not derived from the constants
alone). Against that, `blocked[]`'s `kind` field (added for TD26072603) costs
9 bytes a row when empty (`"kind":""`) and 25 when it is `needs-refinement`
(`"kind":"needs-refinement"`) — measured by publishing a 20-row synthetic
`blocked[]` before and after the field was added (14,910 bytes total, +340
bytes for the field across the 20 rows, half of them `needs-refinement`) — so
even a blocked list two orders of magnitude longer than any fleet has run
stays a rounding error against the transcript budget above. No cap on
`blocked[]`'s length exists or is warranted by this change.
`--no-github` skips the live GitHub fetch for a faster, offline run. Rather
than blanking the GitHub panels, it reuses the last real fetch — cached at
`<state_dir>/.dashboard-github.json` and re-marked `stale` — so the PR list,
work sources and ok/error state all persist, and no false "GitHub unavailable"
banner fires. That is what lets the sub-minute heartbeat refresh local state
every few seconds while hitting the GitHub API only once per window.

Redaction is unconditional: `/home/<user>` and `/Users/<user>` → `~`, and
`ghp_/gho_/github_pat_/sk-…/Bearer …` token shapes → `[REDACTED-TOKEN]`,
applied to the whole serialised payload before writing.

The `DASHBOARD_DATA` shape (the contract the page renders):

```
{ generated_at, max_open_agent_prs,
  node,                                // which node's Publisher wrote this page
  config:  { models, timeouts, pr_label, branch_prefix, repos, … },
  status:  { running, lock:{pid,started_at,alive},          // THIS node's lock
             current:{stage,repo,item,source,title},
             last_cycle:{id,node,ended_at,outcome,repo,item,title},  // the FLEET's newest FINISHED
             limit:{active,note}, switch:{…},
             doctor:{timestamp,verdict,fails[],warns[],skips} | null },
                                    //   THIS node's most recent hourly
                                    //   `doctor.sh --unattended` pass
                                    //   (agent-ops#543), read from
                                    //   state_dir/.doctor-status.json —
                                    //   null until the first hourly pass
                                    //   has run
  counts:  { cycles_shown, failures_shown, prs_reached_ready,   // fleet-wide
             spend_today_usd, spend_total_usd,
             by_day[], by_model[], by_actor[],   // both pipelines' actors;
                                    //   by_model[].n counts transcripts that
                                    //   touched that model, not transcripts
                                    //   attributed to it — a transcript
                                    //   spending on two models counts under
                                    //   both (issue #536); by_day/by_actor
                                    //   count transcripts, unaffected
             recent_costs[],       // {ts, cost} per row, last 3 days, for the
                                    //   spend-today card's GMT/local/24h toggle
             cost_rows[],           // {day, model, actor, usd, cycle,
                                     //  repo, item, source, outcome,
                                     //  attributed} per row, one per
                                     //   (transcript × model)
                                     //   touched — each carries that model's
                                     //   own costUSD, not the transcript's
                                     //   whole total_cost_usd (issue #536) —
                                     //   over the whole COST_SCAN_DAYS
                                     //   window, unsummed — backs the
                                     //   model/actor charts' own time-frame
                                     //   selector (issue #334). `cycle` is
                                     //   the transcript's own id, shared by
                                     //   every row it split into — the
                                     //   selector's client-side re-aggregation
                                     //   dedupes on it so a transcript that
                                     //   touched two models still counts once
                                     //   under `by_actor`'s windowed `n`,
                                     //   never twice (issue #536).
                                     //   repo/item/source/outcome (issue
                                     //   #593, D21) are joined onto `cycle`
                                     //   from the same fleet-wide event
                                     //   union `cycles[]` renders from —
                                     //   bounded by log_retained_bytes, not
                                     //   by cycles[]'s own MAX_CYCLES cap —
                                     //   and populated only when
                                     //   `attributed` is true: a
                                     //   coordinator/implementer/reviewer
                                     //   row whose own cycle has events in
                                     //   that union. Every other row —
                                     //   enabler/refiner/limit-probe (which
                                     //   share their triggering cycle's id
                                     //   but spent on a different item),
                                     //   project-reviewer (whose cycle id
                                     //   never reaches log.jsonl), or a
                                     //   coordinator/implementer/reviewer
                                     //   row whose cycle has rotated out of
                                     //   the union — carries all four as
                                     //   null and `attributed:false`, never
                                     //   dropping the row itself. See
                                     //   docs/METERING-SCHEMA.md for the
                                     //   field-by-field contract
             coordinator_verdicts: {   // how often the Script rejects a
               window_from, window_to, //   Co-Ordinator verdict, and what
               runs, retries,          //   the fleet spent recovering
               selections, fallbacks,  //   (implementation spec 3t/3v/3w)
               none_selected, corroborated, rejected, rate,
               by_day:   [ {day, model, runs, retries, selections, fallbacks,
                            none_selected, corroborated, rejected, rate} ],
               by_model: [ {model, runs, retries, selections, fallbacks,
                            none_selected, corroborated, rejected, rate} ],
               by_band:  [ {band, rejected, unaccounted} ],
                                       // counts, not a rate (issue #345):
                                       //   rejected verdicts naming this band,
                                       //   and the item count behind that;
                                       //   "unknown" for a rejection logged
                                       //   before spec 3x's `bands` existed
               last_rejection: { ts, node, cycle, attempt, model, reason,
                                 detail, eligible_total, unaccounted_total,
                                 bands,  // {source: count}, spec 3x; null pre-3x
                                 unaccounted:[{repo,item,source}],
                                 outcome } },  // what became of that cycle
             stage_models: {        // which model the Implementer/Reviewer
               window_from, window_to,  //   stages were each *asked* to run
               by_stage: [ {stage, model, n} ],   // (issue #529); the dashboard's
                                      //   two "model used" pies. `model` is
                                      //   `lib/metering.sh`'s own field — what
                                      //   the invocation was asked for, never
                                      //   re-derived from `cost_rows`/`modelUsage`,
                                      //   which are spend attribution and would
                                      //   report a stage's subagent models
                                      //   instead of its own (the #536 failure
                                      //   this issue was asked not to repeat).
                                      //   One stage-end is one unit, including a
                                      //   failed run (`exit_code != 0`) or a
                                      //   retry; no readable `model` lands under
                                      //   "unknown" rather than being dropped,
                                      //   matching `by_model` above. `by_stage`
                                      //   is the whole retained window's totals,
                                      //   for the page's "Lifetime" default
               rows: [ {day, stage, model, n} ] } },  // day-summed, so the page can
                                      //   re-aggregate over its shared cost-chart
                                      //   time-frame selector, exactly as
                                      //   `cost_rows` does for the bar charts —
                                      //   `window_from`/`window_to` are the span
                                      //   of the *whole* retained log (not just
                                      //   these two stages' own events), since
                                      //   `log.jsonl` is rotated at
                                      //   `log_retained_bytes` independently of
                                      //   `COST_SCAN_DAYS`, so these pies can
                                      //   span less history than the cost charts
                                      //   beside them
  cycles:  [ { id, node, started_at, ended_at, outcome, repo, item, source, title,
               pr_url, reason, fail_detail, warning, total_cost_usd, limit_hit,
               raced, race_losses,          // true/count iff the cycle lost a claim
                                             //   to a peer's contention (implementation
                                             //   spec 17a) before its outcome; present
                                             //   whether or not it recovered
               standdown_cause,             // "raced" | "unreachable" | "pre-claimed"
                                             //   | null — only on an outcome of
                                             //   "stand-down"
               stages:{ coordinator|implementer|reviewer:
                        { ran, cost_usd, duration_ms, num_turns, is_error,
                          terminal_reason, model, status, result, stderr,
                          limit_hit, limit_text } },
               events[] } ],           // most recent 40 FLEET-WIDE, newest first
                                       //   ids of the cycle shape only — a
                                       //   hand-appended record is not a cycle
                                       //   — and substantive only: no-op
                                       //   ticks aggregate below instead (#271)
  noop_ticks: { total, standdown, skipped,   // no-op ticks held out of cycles[],
                last_ts },                   //   counted by kind + the newest
                                             //   timestamp — O(1) however many
  blocked: [ { repo, item, ts, detail, stage,           // from the log union,
                                                        //   blocked and not void
               kind,                                    // "" ordinarily, "needs-refinement" for a
                                                         //   refinement block (implementation spec 34e)
               escalation_issue, escalation_url,        // an open ask of the human
               enabler_outcome, enabler_ts } ],         //   … or the last verdict
  void:    [ { repo, item, ts, detail, stage, evidence } ],
  github:  { ok, error, fetched_at, stale,
             prs: [ { …, queued, dequeued } ],  // merge-queue state (D17); see
                                                 //   "Merge-queue awareness" below
             claims[],
             inputs:{<slug>:{issues, failed_runs, findings,
                             tech_debt:[{id,title,status,url}],  // unresolved
                                       //   items only; title/status empty
                                       //   until the item file has been read
                             state:{issues, failed_runs, tech_debt, findings}}},
                                       // "answered" | "answered_404" | "failed"
                                       //   per source, per repo — "answered_404"
                                       //   only ever on tech_debt (a repo with
                                       //   no register)
             pr_index: { "<owner>/<repo>#<n>":                  // one per
                         { repo, number, title, url, state,     //   number the
                           is_draft, author, labels[], base,    //   page shows
                           created_at, merged_at, closed_at,
                           merge_commit, review_decision,
                           mergeable, checks, cached_at } } },
  fleet:   { nodes:  [ { node, role, heartbeat_ts, heartbeat_age_s,
                         last_cycle, self, stale,       // self first
                         version: { pr, commit, short, built_at,
                                    repo, source, dirty },  // null if unknown
                         compose: { status, diff_lines },   // the node's own
                                            //   compose.yaml against its
                                            //   image's copy (#131); null if
                                            //   unreported
                         image: { status, registry_commit,  // the node's own
                                  registry_created_at },     //   commit against
                                            //   the registry's newest
                                            //   published one (#155); null if
                                            //   unreported
                         switch: { disabled, reason, by,    // the node's OWN
                                    actor, kind, scope,      //   disable record
                                    since, expires_at },     //   (#379); `scope`
                                            //   is "node" for a real
                                            //   `--disable --this-node` and
                                            //   "fleet" for the local mirror a
                                            //   fleet-wide --disable leaves on
                                            //   the node that issued it (2.3);
                                            //   never the fleet flag itself;
                                            //   null if unreported
                         live: { cycle, since, running, ended_at,
                                 stage, repo, item, source, title } } ],
                                            // what THAT node is doing; null
                                            //   until it has run a cycle
             flags:  { disabled, limit,                 // cached fleet flags (2.3a)
                       merge_autonomy_kill: { state, record? } },
                                            // D18 issue #576; {state:"enabled"}
                                            //   when clear
             claims: [ { repo, key, kind, node, cycle, item, source, ts, sha } ] },
  log_tail:  [ … ],                    // recent events, newest first, fleet-wide
                                       //   minus review-gate-checks-read: pure
                                       //   machine bookkeeping (implementation
                                       //   spec 31c), one per ready-gate
                                       //   evaluation with nothing an operator
                                       //   can act on, which would otherwise
                                       //   displace rows that have something
                                       //   to say — and minus first-seen for
                                       //   the same reason (spec 33), one per
                                       //   item a gather first reports, read
                                       //   only by scripts/pickup-metrics.sh
  cron_tail: [ "line", … ] }
```

`github.pr_index` is the record behind every `#number` the page renders — the
open-PR table, the cycle that raised one, the version a node is running. Its
references are gathered from the page itself (each shown cycle's `pr_url`, each
node's reported version), so it holds exactly what is on screen and cannot grow
past it. Entries for open pull requests come free with the label query above;
the rest cost one `gh pr view` each, and a **merged or closed pull request is
never re-read** — its record cannot change, so `<state_dir>/.dashboard-prs.json`
caches it permanently and a warm index costs nothing per tick. Only entries
still open are refreshed, and only hourly. A cold index is filled at most eight
references per tick: forty `gh pr view` calls at up to `GH_TIMEOUT` each would
not fit in the heartbeat's window, and nothing waits on it — an unindexed
number renders as the plain link it has always been.

**Merge-queue awareness** (D17, agent-ops#374/#375): each open pull request in
`github.prs[]` carries `queued` (`true`/`false`/`null` — `null` only when the
probe below has never once answered for it) and `dequeued` (`true` while it is
a state a human should look at). `queued` is `lib/merge-queue.sh`'s
`merge_queue_probe` read directly — the same probe
`scripts/sweep-human-visibility.sh` (requirement 38f) already uses, shared
rather than reimplemented — for every open, **non-draft** pull request the
label query returns; GitHub will not enqueue a draft, so one is never worth
the call, and this needs no miss budget of its own the way `pr_index` and the
tech-debt roster do, because the set probed is exactly this tick's open agent
pull requests, already bounded by `max_open_agent_prs`. `dequeued` is *not*
the probe's own `dequeued_at`/`dequeue_reason` (the last removal event on the
pull request's timeline, regardless of age or of a later re-queue —
agent-ops#394's still-open finding against that reading): it is a small state
machine the Publisher keeps itself, `{queued, warn}` per pull request in
`<state_dir>/.dashboard-queue.json`, rewritten wholesale each GitHub tick from
that tick's own open pull requests (so a merged or closed one simply has no
entry next tick, rather than being pruned by rule). `warn` sets the tick
`queued` is observed to flip from `true` to `false`, stays set on every later
tick that still reads not-queued — a maintainer glancing at the page between
heartbeats must still see it — and clears the moment either `queued` reads
`true` again or the pull request drops out of the open list. A probe that
cannot answer (`merge_queue_probe` failing, same as any other best-effort
GitHub read) carries the last known answer forward unchanged, both the badge
shown this tick and what is written back to the cache, rather than ever
guessing `false` — the one direction that could silently clear a live warning
or falsely raise one — and does not itself trip `github.ok`, the same
treatment `sweep-human-visibility.sh` gives the identical probe. A repository
with no merge queue enabled needs no detection of its own: `isInMergeQueue` is
always `false` and no `RemovedFromMergeQueueEvent` ever fires there, so
`queued`/`dequeued` are always `false` and the open-PR table renders exactly
as it did before this feature existed. The open-PR table (below) shows
`queued` as a **queued** badge distinct from ready/draft/conflicting — "landing
hands-off" — and `dequeued` as an amber warning badge beside the pull
request's ordinary state badge; the same `dequeued` also raises a page-wide
amber banner (`⚠ N open agent PR(s) removed from the merge queue without
merging.`) beside the failing-checks one, so it is visible without opening the
table.

`github.inputs[<slug>].tech_debt` is that repo's register as work: one row per
**unresolved** item, carrying the item's own `title` and `status` and a link to
the file, because an ID on its own names nothing and most of a mature register
is items already resolved. The roster listing hands back each item's blob SHA
free, so the metadata behind it is read once and cached by SHA in
`<state_dir>/.dashboard-td.json` — the same never-stale-by-construction
argument as the claim cache below, and an item file is written once and touched
again only when its status flips, so a warm register costs no call at all.
A cold one is filled at most four items **per repo** per tick, so that every
register fills at once rather than the first repo in the config consuming the
whole budget; an item not yet read has no status, is kept (it is not yet known
*not* to be work), and renders as the bare ID the panel used to show. Entries
are dropped a month after the last register that named them, which bounds a
file that would otherwise collect a SHA per status flip for ever.

`fleet.claims` is the live claim registry (implementation spec 17a), read on
the GitHub tick and carried between ticks by the same cache as `github` (it
rides in `github.claims`; `fleet.claims` is the surfaced view). One recursive
`git/trees` call enumerates the registry — path and blob SHA per claim — and
each body is then read by SHA from `git/blobs` unless
`<state_dir>/.dashboard-claims.json` already holds it. Since a blob's SHA is a
hash of its bytes, a cache hit cannot be stale, so a fleet whose claims are
not moving costs one API call a tick however many claims it holds. (It was a
`contents/` walk: one call for the claims directory, one per repository under
it and one per claim.) Every node renders the same fleet, so any node's URL
answers "what is the operation doing" — `node` (header: "· <name>") is what
tells two otherwise identical tabs apart.

## The Site (`dashboard/index.html`)

One self-contained file: inline CSS + vanilla JS, no framework, no build step,
no external network requests (works fully offline). Renders from
`window.DASHBOARD_DATA`; every panel handles missing data gracefully.
Theme-aware (light/dark via `prefers-color-scheme`); wide tables scroll
inside their own container. Refreshes in place rather than reloading: on a
configurable interval (`config.json`'s `dashboard_refresh_seconds`, default
5s) it re-fetches `data.js` by injecting a cache-busted `<script>` — not
`fetch()`, so it keeps working from a `file://` URL with no server or CORS —
and re-renders the body **only when the data actually changed** (a signature
compare that ignores the always-moving `generated_at`). Expanded cycle rows,
opened void rows and a void list showing past its cap, open transcript panels
and scroll position survive the re-render — both the page's own scroll
position and, independently, the position scrolled to within any transcript
box (a stage's status/result/stderr, or the cron.log tail): each such box
carries a stable key across rebuilds so a reader mid-scroll through a long
transcript is not dropped back to its top by the next refresh; the header's
staleness clock ticks every interval and warns if the heartbeat looks stopped.

The header carries **two** clocks, because the page has two ages: `data <age>`
from `generated_at`, which moves every few seconds, and `· GitHub <age>` from
`github.fetched_at`, which moves once per heartbeat window. Everything sourced
from GitHub — PRs, checks, issues, work sources, claims — is as old as the
second clock however recent the first is, and the design that makes that so
(a `--no-github` tick carrying the last fetch forward rather than blanking the
panels) is exactly what would otherwise hide a stalled fetch: half-hour-old PR
data renders identically to fresh. Past 12 minutes the GitHub clock turns
amber and a banner names the fetch time. That banner is distinct from the
`ok === false` one: this is a fetch that stopped happening, that one is a
fetch that ran and failed.

Panels: status header ("· <node>" naming the page's own node, then the live
state — on a single-node page that node's own running/idle plus the stage,
repo, work source and item it is working on; on a fleet page a **summary**:
how many of how many nodes are running, who and in which repo while that is
still a glance (three or fewer), and badges counting any nodes that look dead
or whose state has gone stale) + a static **documentation nav** (`Docs:`
followed by six links — README, the three pipeline specs, the metering
schema, the roadmap — each opening the file at `blob/main/<path>` on GitHub
in a new tab; no data behind it, so it renders identically on every load) +
disabled / fleet-switch / merge-autonomy-kill-switch / usage-limit
/ fleet-limit / failing-checks / dequeued-pr / gh-down / stale-peer /
doctor-fail / doctor-warn banners
(the switch first: when it is set, every other quiet signal on the page
is a consequence of it rather than news, and an operator reading them in the
other order goes looking for a fault that isn't there);
**the fleet strip** — one card per node carrying that node's own live state
(name, role — with a **disabled** badge beside it when that node carries its
own node-scoped disable (#379), naming the reason and expiry — running/idle,
the stage, repo, work source and item in flight and
since when — or, when idle, when its last cycle ended and how it went — the
**version it is running** as `image #<pr> <short-sha> · built <age>` with the
pull request carrying its record card, a grey `behind` marker when the fleet
holds a newer build and an amber `modified` one on a checkout with uncommitted
work, and how
fresh that answer is: read live for our own row, "as of its last push" for a
peer); stale peers bordered red and reported as state unknown; click a card to
filter the cycle list and the recent log to that node, click again to clear —
the filter survives refreshes like every other UI state; **live claims** — the
registry rows, i.e. work no other node will pick up. Both, plus the cycles
table's Node column,
appear only once the fleet has more than one node (or a claim exists): a
single-node page renders exactly as it always did.

The strip is rebuilt on every refresh tick alongside the header, not only when
the body re-renders, because its cards carry running clocks ("since 18m ago")
and the body deliberately sits still while the data is unchanged.
Then metric cards (spend today/total — fleet-wide, one shared account —
failures, reached-ready, back-pressure gauge vs `max_open_agent_prs`. The
gauge's own figure is the same four-part sum `agent-cycle.sh` trips its cap
on (requirement 2.2) — draft PRs, ready PRs still `CHANGES_REQUESTED`, and
live claims — rather
than a figure the page derives from the open-PR listing alone: a live claim
is work already in flight whose PR does not exist yet, so it cannot appear
there. Which registry rows those are is `claim.sh count`'s rule, transcribed
rather than re-derived — a card reporting a different figure from the gate it
depicts is worse than no card — and it excludes two kinds of row. Rows under a
**pseudo-slug** (`enabler`, `refiner`) are the Enabler's and Refiner's
engagement tombstones: never released, retired only by `claim.sh gc`, and
never seen by the cycle, which asks `claim.sh count` for one configured repo
at a time. The page reads the whole registry in one tree call, so it must
re-impose that scope itself or the gauge climbs with every item the Enabler
examines and pins red against an open gate. Rows **naming a pull request
already in the sum** are that PR a second time: the `pr-<n>` exclusion entry
always, and a `pr-<n>-<kind>-<scope>` item ref when its PR is among the drafts
or changes-requested PRs counted above — but not when that PR sits in the
human's queue (conflicted, dequeued), where the claim is the only record the
work is in flight. The card's `title` tooltip spells out the same split the cycle logs,
e.g. "1 changes-requested + 0 draft + 1 unraised claim(s) — plus 13 waiting
on human (14 raw)", with a line underneath naming the raw open-PR total and,
when it differs, how many of those are sitting only in a human's queue
(approved, or awaiting a review nothing is
`CHANGES_REQUESTED`-blocking): a full human queue reads as "waiting on
human", not as the pipeline sitting idle). The spend-today card's own word
"today" is a button:
clicking it cycles the card's label and figure through **today (GMT)** (the
Publisher's own `spend_today_usd`), **today (local)** and **last 24h** (both
computed here, from `counts.recent_costs`, against the reader's own clock and
zone — the one thing about "today" the Publisher itself cannot know). The
choice is written to `localStorage` (`dashboard.spendMode`) as it is made and
read back on every load, so it survives a real reload and not just the
in-place refresh the rest of this section describes — the first state on this
page to do so — and an unset or unrecognised stored value reads as the GMT
default rather than an error; open PRs (a **queued** badge in place of ready for
one currently in a merge queue, and an amber **dequeued** badge beside a pull
request's state badge for one a queue removed without merging — see
"Merge-queue awareness" above); recent cycles (outcome and work source at
a glance — a cycle that has not logged `cycle-end` shows the state it is in
rather than an outcome it has not reached: **in progress** while a node claims
it as its live cycle (greyed when that node's own report has gone stale,
amber and questioned once it is running past `lock_stale_after`), **no clean
end** when no node is running it, and **not ended** when the data carries no
node state to ask; click a row for per-stage detail with
the parsed status, full transcript, and stderr; beneath the table, one muted
summary line for `noop_ticks` — the count held out of the list, split stood
down / lock-held skips, with how fresh the newest is — shown only when there
are any and only while the list is unfiltered, since the aggregate is
fleet-wide and must not sit under a single node's rows; a window that is
*all* no-ops reads "No substantive cycles in the fleet window." over that
line, keeping "No cycles recorded yet." for a page with genuinely nothing);
failures,
blocked and void items (the void list newest first — it arrives grouped by
repo and item, which no reader wants — and **capped twice**: the ten newest
rows, each three lines tall, with the rest behind a `See more — N older items`
control at the foot of the table and any row opening to its full text when
clicked, both choices surviving a refresh. The heading counts every void item,
not the rows shown); work sources per repo (including the security and
code-quality findings, shown first, that the Co-Ordinator prioritises, and the
open issues, listed in `Priority` band order with the band on each, which is
the order the Co-Ordinator reaches them in);
each repo whose `config.json` entry carries a non-zero `nice` (pipeline spec,
requirement 3) also carries a **badge** naming that value, blue below zero and
grey above, with the weighting it buys — `1.25^(-nice)`, the multiple by which
the Script inflates that repo's staleness age when it orders the repo walk —
and the disclaimer that it biases the walk without starving anything. A note
above the panel says the **Script** is what acts on a `nice`, because the panel
is headed with what the *Co-Ordinator* sees and a `nice` is the one ordering
input it is never given; without that line the badge would assert, on the
page's only per-repo surface, exactly the thing requirement 3 is careful not to
do. A repo at `0` or with no key carries neither badge nor note, so a fleet
that has set no `nice` anywhere renders the panel it rendered before the
feature existed. The values reach the page unaided — `config.repos` already
ships wholesale — so this is rendering only: the Publisher is unchanged;
**Co-Ordinator verdict quality** (immediately below the work sources, and
deliberately: that panel is what the Co-Ordinator was handed, this one is how
often its answer about it survived the Script checking that answer);
the cost charts — by-day, by-model, by-actor, the two cost notes, then the two
"model used" pies (Implementer and Reviewer, issue #529) and their own note —
flowed through a CSS multi-column layout in that reading order, letting the
browser balance the split by height rather than pinning by-day to a column of
its own, since it runs to sixty rows against five each for by-model/by-actor,
with a **time-frame selector** (issue #334) above the grid — one `<select>`,
labelled as covering the model, actor and model-used charts, offering 1/7/30/90
days and the unlabelled lifetime default — that re-aggregates `counts.cost_rows`
client-side on change rather than re-fetching, so all the windowed charts
redraw from the same choice with no round trip; recent log; `cron.log` tail. An
option is disabled whenever its span exceeds how far back `cost_rows` actually
reaches — capped both by the Publisher's own `COST_SCAN_DAYS` truncation and,
on a younger fleet, by how long the pipeline has been running — since selecting
it would otherwise silently show the same figures as a narrower window (or as
Lifetime) without saying so; the Lifetime option itself is never disabled. A
persisted choice the control has since disabled this way (grown stale as
`cost_rows` moved) renders, and aggregates, as Lifetime instead — keeping the
selected `<option>` and the chart it drives in agreement — and reverts to the
persisted choice on its own once the window it names is available again.

The two **model-used pies** re-aggregate `counts.stage_models.rows` off the
same selector rather than `cost_rows` — a different Publisher aggregate, since
`stage_models` counts stage-end runs by the model they were *asked* to run,
never spend attribution — and render as a `<div>` with a CSS `conic-gradient`
background plus a text legend rather than SVG, since `el()` never calls
`createElementNS`. A model this page has not seen falls open to a grey slice
rather than dropping it, the same as every other vocabulary table here (`ACTOR`,
`VERDICT_OUTCOME`). Because `stage_models` reads `log.jsonl` directly rather
than retained transcripts, its window can be shorter than `cost_rows`' — a
muted caption under the pies states the aggregate's own `window_from`/
`window_to` rather than letting a reader assume it matches the selector's
label, and states that a failed run or a retry each count as their own slice.
A stage with nothing in the selected window renders the same `.empty` panel
every other chart on this page uses for "no data here", never a blank or a
zero-slice pie.

The **Autonomous landings** panel (D18 WI-8, agent-ops#411) is the
asynchronous audit that D18 accepts unattended merging in exchange for. Risk 6
of `docs/reviews/2026-08-14-autonomy-investigation.md` — "overnight merges with
nobody watching" — is accepted deliberately, and this panel is the named
condition: the queue re-tests, `failed-runs` turns post-merge breakage back
into selectable work, and once a day a human sees everything the Script landed
without them. It is permanent rather than rollout scaffolding, because at
`agent-merges-all` it is the only routine account of what merged.

It renders `landings`, which the Publisher assembles from the fleet-wide event
union (never a private counter, so a landing armed on any node appears on every
node's page): one row per `landing-armed` inside the window — default 24 h,
overridable for tests by `LANDING_DIGEST_WINDOW_HOURS` — carrying when, the
repository, the pull request, its title and state where GitHub was read this
tick, the work source, the complexity it was armed at, the `enqueued`/
`auto-merge` method `landing_arm` actually used, and the node that armed it.

Each row is joined to the **`approver-verdict` that authorised it**: the newest
verdict for that `pr_url` at or before the arm, never a later re-review. That
qualifier is the whole correctness of the join — an Approver may review the
same pull request across several cycles (a refuse streak, then an approval, and
possibly another refusal afterwards on a later push), and only the verdict the
arming stage could actually have seen explains the landing. A landing whose
verdict cannot be located still renders, with `unknown` in the tier and verdict
cells: an unexplained landing is the single most important row this panel can
carry, so it is never the one dropped for want of a join.

Three things it will not hide, each a way a digest could mislead by omission:

- **Refusals**, counted and grouped by reason class over the same window. Two
  landings beside forty refusals is a classifier holding the line; two beside
  none may be a gate that is not running at all. A panel showing only successes
  could not tell those apart, and the second is the one worth waking for. The
  class is the `reason` text before its first `:` (`byReason`,
  `dashboard/index.html`) — `landing_autonomy_refusal_reason`
  (`lib/landing.sh`, D18 issue #576) is what prefixes a `kill-switch:` tag onto
  a refusal only when a second, independent read of the fleet-wide kill
  switch confirms it is the actual cause of the effective level not
  qualifying, so an engaged switch groups on its own rather than folding into
  (or being indistinguishable from) the full-sentence group a level simply
  never raised forms.
- **The merge budget** (D18 issue #574), per repository: `merge_budget_per_day`'s
  effective cap against consumption, its status (`ok`/`held`/`frozen`), and,
  when held or frozen, the oldest waiting pull request and its age. An
  unlimited repository (`0`) reads as `∞`, never as a cap of zero. Consumption
  is sourced from the same rolling-24h count `lib/merge-budget.sh` itself
  reads, never a private one recomputed here: `landing-armed`,
  `merge-budget-hold` and `merge-budget-frozen` each carry the `cap`/`count`
  `merge_budget_decide` read at that decision, so the single latest of the
  three for a repository — across the whole retained log, not only this
  digest's own window, the same reasoning the verdict join below already uses
  — is that repository's state **as of that last gate-5 decision, not a live
  read**, and of unbounded age: a repository whose backlog is empty, or whose
  candidates all fail eligibility before reaching gate 5, keeps whatever event
  last fired indefinitely — what the row then *reports* from that event is
  bounded by the ageing rule below, but the event itself is never discarded. This is what keeps the freeze's own reason and the
  oldest waiting pull request visible without a live read of the freeze flag
  or `merge_budget_oldest_waiting`: both ride the
  `merge-budget-frozen`/`merge-budget-hold` event that already fires the
  moment `lib/merge-budget.sh` establishes them, rather than a second network
  call this dashboard tick has no business making. A repository this tick has
  never seen a budget decision for falls back to `config.json`'s configured
  cap, reported `ok` with nothing yet consumed — a real absence of data, not a
  claim that nothing has landed. A repository that *has* a recorded decision
  keeps that decision's own `cap` — never re-read from `config.json` — until
  its next gate-5 decision refreshes it, even if an operator edits
  `merge_budget_per_day` for that repository in the meantime: the recorded
  `cap` and `count` are read together, as the coherent pair
  `merge_budget_decide` actually reasoned from, and a superseding-cap edit
  becomes visible only once a fresh decision carries the new value alongside
  a fresh count measured against it. The `cap` outlives that pair: once the
  count beside it ages out of this digest's window (below), the recorded `cap`
  is the one field of a superseded decision the row still carries, so a
  repository whose configured cap has moved since its last gate-5 decision
  keeps reading against the old one until the next decision lands.

  `consumed` for an `ok` row is the count `merge_budget_decide` read *before*
  granting the arm that logged it — the landing the arm itself produced is
  never in it, so a repository that just spent its last permitted landing this
  window reads, for example, 7/8, not 8/8. An unlimited repository never has a
  `count` to read at all: `merge_budget_decide` short-circuits a zero cap
  before counting, so its row instead counts this digest's own `landing-armed`
  events inside the window — the same plain count the `armed`/`refused` rows
  above already give, and what this panel counted before the per-repository
  `budget` block existed. An `ok` row is aged back to unmeasured the same way
  a held row is: once its own event falls outside this digest's window, the
  count it carries has already rolled off the governor's own rolling-24h
  clock, so `consumed` resets to `0` rather than presenting a count that is no
  longer live as though it still were. A held row is aged back to `ok` on the
  identical rule, because a hold is a rolling-24h fact too, and one nothing
  has refreshed for a full window has already rolled off the governor's own
  clock; its `consumed` resets to unmeasured with it — an aged hold's `status`
  and `consumed` read exactly like a repository gate 5 has never reached,
  rather than carrying its stale count forward under a status now claiming to
  be healthy. A frozen row is never aged back this way, because a freeze
  stands until a human clears the fleet flag, not until time passes. Every held or frozen row carries the
  source event's own timestamp so the page can render its age (`held · as of
  2d ago`) rather than presenting a stale decision as current; an `ok` row
  never carries `as_of`, aged back or not, since once its count resets to
  unmeasured its `status`, `consumed` and `as_of` read as a repository gate 5
  has never reached does, which likewise has no age to show. `cap` is the one
  field that still separates the two, and only where the configured cap has
  moved since that aged decision — the persistence rule above.

  A held or frozen repository never renders folded into the plain
  `consumed/cap` text an `ok` repository gets, and never folded into the
  refusals count above either — a budget hold is not an eligibility refusal,
  even though both mean a pull request did not land that cycle. Each earns its
  own row, badged `held` or `frozen`; a `frozen` row also states why, in the
  same words `merge_budget_apply_decision` logged at the moment it froze the
  repository.
- **Its own failure.** A payload the Publisher could not assemble sets `armed`
  to `null` and renders as "could not be assembled this tick", explicitly
  distinguished from a quiet night. An empty array is a real and reportable
  nothing; `null` is an outage, and the two must never render alike.

Each `armed` row also carries the classifier-escape audit's own verdict
(requirement 8e, agent-ops#572) — `audit`, one of `"clean"`, `"escape"`,
`"unverifiable"` or `null` (not yet audited), joined by `pr_url` against the
newest `classifier-escape`/`landing-audit` event for that pull request — and
`audit_reason`, rendered as a badge on the row (green/red/amber respectively)
so a human reading one landing sees, without leaving the row, whether the
Approver's own decision was independently re-checked and what it found.
`null` reads "pending", never folded into a false "clean": a landing this
audit has not reached yet is not the same fact as one it checked and cleared.

Beside the digest, `counts.escape_audits` (requirement 8e) is the audit's own
all-time scoreboard — `checked`/`clean`/`escapes`/`unverifiable`, plus
`escape_list`/`unverifiable_list` naming each one — folded from the same
`classifier-escape`/`landing-audit` events, fleet-wide, but **never windowed**
like the digest above it: an escape is a permanent fact about one merged pull
request, and letting it age out of a 24 h window would recreate the exact
"row nobody reads" the audit exists to prevent. A payload the Publisher could
not assemble sets every field to `null`, the same "outage, not a quiet night"
distinction `armed` above makes.

The **Doctor** panel (agent-ops#543) renders `status.doctor`: the most recent
hourly `scripts/doctor.sh --unattended` pass on *this* node, read from
`state_dir/.doctor-status.json` rather than recomputed — its GitHub section is
too expensive to repeat on the dashboard's own 5-minute heartbeat, so a
separate hourly `crontab.tmpl` line runs it and this Publisher just reads the
result. One row per `fail`/`warn` line the pass printed, each carrying a
level badge (`fail` red, `warn` amber) and the message verbatim, plus when the
pass last ran; a clean pass says so instead of rendering an empty table, and
no pass having run yet (a node whose image predates the flag, or one still on
its first hour) says that too, rather than either looking identical to a
clean pass. A `fail` or `warn` also raises its own page-top banner (naming the
count and pointing at this section), the same way failing PR checks do —
because, like those, a `warn` this pass leaves unclaimed the same way a
misconfigured `Priority` field did before this existed is otherwise invisible
between one operator-invoked `doctor.sh` and the next. Local to this node
only: unlike the compose/image/switch verdicts the fleet heartbeat carries,
nothing here replicates a peer's `status.doctor` to this page — a repository's
configuration and this node's own GitHub access are this node's alone to
report.

The **Co-Ordinator verdict quality** panel renders
`counts.coordinator_verdicts` (issue #319). Implementation spec 3t
corroborates a `selected: false` verdict against the Script's own eligible
tech-debt set and rejects one that cannot account for the band; spec 3v then
retries it once and, failing that, picks mechanically. Both act one cycle at a
time, and per cycle they can only say whether it happened. The operator
question they leave behind — is `coordinator_model` the wrong model for this
job — is a **rate**, so the panel leads with one: the rejected count, the
corroborated count it is over, and the percentage, with a red badge at or above
half and amber below.

The unit is the **verdict, not the cycle**, because spec 3v lets one cycle
produce two and a retry rejected in turn is a second wrong answer rather than
the same one restated. What the fleet spent on those rejections is a second
line — retry engagements, and items the Script had to pick itself — because
that cost is real and is invisible in the rate above it.

Beneath, one row per UTC day **per Co-Ordinator model**, newest day first and
models in a stable order within a day, so an installation that changes
`coordinator_model` on one node gets two separately attributable rates rather
than one blended figure. Beneath that, the newest rejection itself — which
attempt it was, the verdict's own stated reason, the Script's machine detail,
the unaccounted item refs (capped at twenty with the full count stated beside
them), and **what became of that cycle**: recovered by the retry, recovered by
the Script's own pick, accepted on retry with nothing selected, or stood down.
A rate with no instance is not actionable; an instance that does not say
whether the fleet recovered is half the story spec 3v now has to tell.

A third breakdown, alongside `by_day` and `by_model`, answers the question the
rate alone cannot: **which band** the fleet is getting wrong, and whether it
is the same one every time — a rejection rate concentrated in `issues` is a
different failure, and a different fix, from one concentrated in
`merge-conflicts` (issue #345). It reports **counts, not a rate**: `rejected`
(how many rejected verdicts named the band at all) and `unaccounted` (the item
count behind that, summed across those verdicts). There is deliberately no
per-band rate — a verdict rejected over `issues` was not "a verdict about
issues", it was a verdict about everything the Script handed over that cycle,
so a per-band figure has no sound denominator to divide by; the single
per-verdict rate above stays the only rate the panel states. Rows are ranked
most-rejected first and capped like the day/model table (`VERDICT_ROWS_MAX`),
with the overflow stated rather than silent. A rejected verdict logged before
spec 3x's `bands` object existed carries no band breakdown at all; it lands
under an explicit `unknown` row rather than vanishing from the tally or being
guessed into a real band, its `unaccounted` taken from the event's own
`unaccounted_total` where it carries one, else from its cycle's sibling
`warning` — the same fallback the newest-rejection panel uses — since a
pre-3v `none-selected` carries no figure at all.

Its three empty states mean three different things and are rendered as three
different things: **no Co-Ordinator runs in the retained log** (missing data
— a log too short or too new), **no rate yet** (verdicts, but none over a
non-empty eligible set, so there was nothing to corroborate), and **no
rejected verdicts in this window** in green (the healthy answer, which must
not read as silence). A `data.js` written before the Publisher recorded any
of this says so outright rather than rendering a clean-looking zero it has no
data for.

The window is the **retained log union and nothing more**, and the panel says
so under its own figures: `log.jsonl` is rotated at `log_retained_bytes` and
`fleet_logs` reads only the live generation, so the aggregate is honestly "over
the log we still have", carrying `window_from`/`window_to` rather than leaving
the page to imply a history it cannot see. Persisting counters across publishes
was the alternative and was not taken: four nodes publish the same union
independently, and a double-counted rejection is a worse answer than an
honestly bounded one.

Verdicts are read from spec 3v's `corroboration` events where a cycle has
them and from its `none-selected` where it does not — never both for one
cycle, or a rejection that reached the fallback path with nothing to pick
would be counted twice. Attribution comes from the event
(`coordinator_model`, implementation spec 3w), falling back to the model that
cycle recorded on its coordinator `stage-end` — the same invocation id, so the
two cannot disagree — which is what lets the panel populate from history
already on disk rather than only from cycles run after it shipped. `selection`
carries a `model` of its own and it is deliberately never read here: that is
the *Implementer* model chosen for the item, and reading it would attribute a
Co-Ordinator verdict to whichever model was about to do the work.

The **recent log** is the newest 80 events, one row each: time, the event as a
badge, **Node**, **Repo**, **Actor**, and the event's own detail. A
`disabled`/`enabled` event's badge additionally names its `scope` (issue
#426, implementation spec requirement 33) — `disabled · node` or
`disabled · fleet`, `enabled · node` or `enabled · fleet` — since the bare
event name cannot say whether a stop or a resume was one node's own or the
whole fleet's, and that is the first thing a reader scanning the tail asks.
A fleet-scoped one whose `fleet_flag` reads `"failed"` additionally appends
`fleet flag: failed` to the Detail cell: a local switch that changed while
the fleet flag did not follow it is exactly the case an operator must not
mistake for a clean transition. The Node, Repo and Actor columns are different
kinds of answer to "where did this happen" — which machine ran it, which
repository it was aimed at, which agent was acting — so each gets its own cell,
read positionally, carrying a dash when the event does not answer it: the Repo
cell is the repository whether or not the other two are known. The Node column
renders regardless of fleet size, unlike the
cycles table's own Node column — this one has always carried the node, single
node included, so nothing about it changes when the fleet has one node. It is
also, together with the cycles table, subject to the fleet strip's node
filter: clicking a node card restricts the recent log to that node's events
too, filtered before the 80-row cap so a node whose events have aged out of
the fleet-wide newest 80 still shows its own newest ones, with the section
heading and empty state following the cycles table's own wording ("Recent log
events — `<node>` only (click its card to clear)" and "No log events from
`<node>`."). The actor is derived rather than logged, because no event carries an
`actor` field and each pipeline already records it somewhere else: the
implementation pipeline's `stage`; `handoff` on `pr-ready`, naming which actor
took the pull request out of draft; `by` on `unblocked` and on `item-refined`
(and on those two events only — `by` elsewhere names a *person*, who set the
switch or cleared a stand-down); the Enabler's own `escalated`,
`enabler-examined`, `enabler-adjudication` (implementation spec requirement
36b's `adjudicate-first` pass) and `item-refined`, and the Refiner's
`refiner-examined`, which carry none of the first three. `item-refined` is the one event with two
writers — the Enabler's refinement pass and the Refiner — and only the
Refiner's carries `by`, so one without it is the Enabler's. A review-pipeline
event is the Project Reviewer's, which is a different actor from the cycle
Reviewer even where the review pipeline writes `stage: "reviewer"` — the same
distinction the Publisher's cost scan draws from the transcript path, drawn the
same way so the two halves of the page cannot disagree about who did what.
Steps with no agent in them name none: the clone (`stage: "workspace"`) and a
handoff the Script completed itself (`handoff: "script"`), as do the
cycle-level events (`cycle-start`, `selection`, `cycle-end`, and the review
pipeline's lifecycle), which are the Script's records of a cycle's progress
rather than any agent's work. Like the source tags and the by-actor chart, this
fails open: a token the page has never heard of renders as itself, so an actor
added upstream shows up unlabelled rather than vanishing into a dash.

Every pull-request number anywhere on the page is rendered by one widget,
which makes it a link with a **record card** carrying that PR's entry from
`github.pr_index`: repo and number, state, title, author, when it was opened
and merged or closed, the abbreviated merge commit (itself a link), its labels,
and — while it is still open — checks, review decision and mergeability. It
also names **the cycle that raised it**, joined client-side from the cycle
list, so the two halves of the page connect without the pipeline logging
anything new. A number with no entry yet says so rather than rendering an empty
card.

The card opens two ways, and they do not cross:

- a **peek** follows the pointer — hover on to open, hover off to close, with
  the pointer free to cross onto the card itself (it holds links of its own).
  Keyboard focus opens a peek the same way, and blur closes it; `Escape`
  closes either kind.
- a **pin** is an explicit act — a click or a tap — and only another explicit
  act closes it: the same number again, a click or tap anywhere off the card,
  the card's own close button (shown on pinned cards only), or `Escape`.
  Hovering off a pinned card leaves it open, and hovering another number does
  not move it; clicking another number does.

**A plain click opens the card rather than following the link**, because on a
touch device the tap that opens the card was also the tap that left the page,
which made the card unreadable exactly where the record is least visible
otherwise. The link is preserved for every input that asks for it: modifier and
middle clicks open the PR in a new tab, keyboard activation (`Enter`)
navigates as it always did — focus alone already shows the card — the `href` is
untouched so "copy link address" and the status bar still work, and the card
carries a *View on GitHub ↗* link of its own.

An open card is carried across the body's rebuild like the expanded rows and
open transcripts are, peeked or pinned as it was — matched to the exact
occurrence it was opened on, so it cannot reappear against one of the same
number's twins elsewhere on the page.

## Integration

- **End-of-cycle hook** — `agent-cycle.sh`'s cleanup runs the Publisher as
  `timeout 120 … >/dev/null 2>&1 || true`: failure-isolated and time-bounded,
  so it can never change the cycle's outcome, exit code, or timing. It is the
  only change to `agent-cycle.sh`. (Never edit `agent-cycle.sh` while a cycle
  is running — editing a running bash script shifts byte offsets and corrupts
  the live process. Use `agent-cycle.sh --disable '<why>'` before editing and
  `--enable` after: that is what the switch of requirement 2.3 is for, and it
  also stops the *next* hourly tick from starting mid-edit, which waiting for
  the lock to clear does not. `--status` reports both the switch and whether a
  cycle is still running, because disabling stops the next cycle, not the one
  already in flight.)
- **Heartbeat** — an optional `*/5 * * * *` crontab entry keeps in-flight
  state, the lock, and GitHub current between hourly cycles. cron can't fire
  more than once a minute, so the entry runs `publish-dashboard-launcher.sh`
  rather than the Publisher directly: the launcher self-loops on 5-second
  boundaries for ~295s (leaving a ~5s gap so consecutive cron runs don't
  overlap), republishing local state — lock, running cycle, cost, log — on
  every tick. A full GitHub-hitting publish runs only when the last fetch has
  aged past `LAUNCHER_GITHUB_MAX_AGE` (285s, so that the gap between fetches
  including the fetch's own ~20s comes to about five minutes); the cheaper
  `--no-github` publish runs in between and carries the last fetch forward, so
  the page stays near-live without hammering the GitHub API. The gate is the
  **age of `<state_dir>/.dashboard-github.json`**, which the Publisher stamps
  on every fetch it attempts — succeeded or failed — and which the launcher
  stamps itself if a publish dies before getting that far. Age, rather than a
  position in the window, is what makes the cadence self-healing: a missed
  cron window, a publish that overran its tick budget and a GitHub outage all
  reduce to "the next tick is the one that fetches", and none of them can turn
  into a retry storm. (It was a wall-clock test, `EPOCHSECONDS % 300 < 5`,
  until it was found never to fire: ticks always land on a multiple of 5, so
  the test meant `% 300 == 0`, and a window opened by a `*/5` entry starts on
  a 300s boundary and runs from offset +5 to +285. The GitHub panels refreshed
  only when cron's sub-second jitter happened to put the first tick on the
  boundary — half-hourly or worse, and invisibly, because a carried-forward
  fetch renders exactly like a fresh one. Hence both the age gate and the
  freshness reporting under **The Site**.) `flock` guards against a slow
  publish stacking up under the next tick. No tick starts inside the window's
  final ten seconds, so the launcher does not overrun into the next cron fire,
  and a healthy window ends `exit 0` — its exit status is explicit, not
  whatever the final tick's lock bookkeeping happened to return
  (`LAUNCHER_WINDOW` shortens the window, and `LAUNCHER_PUBLISH_CMD` swaps in
  a stub Publisher, for the test suite only). Each window also opens by
  repairing its own log: a container killed mid-append leaves the
  file's size recorded with the last writes' data blocks missing, and they read
  back as NULs. The lost lines are lost, but one NUL makes the whole file
  binary, and grep then stops printing matches for every intact line around it
  — GNU grep says "binary file matches", ugrep says nothing at all and exits 1.
  The launcher strips them and appends a line recording how many bytes went, so
  the loss stays on the record instead of being closed over silently.

## Components (as built)

- `scripts/publish-dashboard.sh` — the Publisher. `DASHBOARD_GH_CMD` names the
  `gh` it calls, and is exported so `scripts/gather-findings.sh` resolves the
  same one; it exists for the test suite, which must reach no network and
  cannot shadow a binary by PATH (the Publisher hardens PATH for cron, and its
  `gh` runs under `timeout`, which no exported shell function is visible to).
  Unset in production, where it is exactly `gh`.
- `lib/version.sh` — what code this node is running: the image's CI stamp
  (`build-info.json`) if there is one, else git `HEAD`, else nothing. Shared
  with `scripts/state-sync.sh`, which publishes the answer in every heartbeat.
- `lib/image-drift.sh` — whether that code is the registry's newest published
  commit (#155): `image_drift_status` reads `ghcr.io/poetic-poems/agent-ops
  :latest`'s `org.opencontainers.image.revision`/`.created` labels anonymously
  over the OCI Distribution API and compares against `lib/version.sh`'s
  answer. Backed by a cache file (`<state_dir>/.image-drift-cache.json`,
  `IMAGE_DRIFT_TTL` seconds, 240 default) that this script and
  `scripts/state-sync.sh` name identically, since unlike `lib/version.sh` and
  `lib/compose-drift.sh` a real network round trip sits behind it — one this
  Publisher's 5-second tick cannot pay on every run. `IMAGE_DRIFT_CURL_CMD`
  is the test seam, following `DASHBOARD_GH_CMD`.
- `scripts/doctor.sh --unattended` (agent-ops#543, `docs/IMPLEMENTATION-PIPELINE-SPEC.md`
  requirement 2.6a) — not read live by this Publisher, unlike
  `lib/compose-drift.sh`/`lib/image-drift.sh` above: its GitHub section costs
  several calls per configured repository, too much for a 5-minute
  heartbeat, so it runs on its own hourly `crontab.tmpl` line instead and
  writes `<state_dir>/.doctor-status.json`
  (`{timestamp, verdict, fails[], warns[], skips}`). This Publisher reads
  that file verbatim into `status.doctor`; `null` until the first hourly
  pass has run. Local to this node only — nothing replicates it to peers.
- `scripts/publish-dashboard-launcher.sh` — the sub-minute heartbeat driver
  (cron runs it every 5 min; it self-loops on 5-second boundaries).
- `dashboard/index.html` — the page (committed source; copied beside the
  generated `data.js` at publish time).
- `scripts/open-dashboard.sh` — regenerate + open in the browser.
- `scripts/serve-dashboard.sh` — optional loopback-only server (`file://`
  fallback). It writes no log of its own: whatever supervises it captures its
  output — a container runtime keeps it in the service's logs, and on the
  legacy WSL path the init script redirects it (below). **The page must answer
  on the host's loopback and on no network** — that is the requirement, and it
  is a requirement rather than an accident. Where the server runs on the host,
  loopback is where it binds, which is the default and what a bare invocation
  gets. The bind address is nonetheless a setting (`serve-dashboard.sh [port]
  [bind-address]`), because inside a container the literal bind and the
  guarantee come apart: a server on the container's own loopback is reachable
  from nothing at all, so each profile in `deploy/docker/compose.yaml` has to
  arrange the host's loopback its own way. The `tailnet` profile puts the server
  in the Tailscale sidecar's network namespace, unchanged on `127.0.0.1`, so
  Serve can proxy to its loopback (`ts-serve.json`, no Funnel). The `local`
  profile binds `0.0.0.0` inside the container and publishes
  `127.0.0.1:${DASHBOARD_PORT:-8787}:8787`, so the only route in is the host's
  loopback — the container's own addresses being on Docker's private bridge,
  which no one is on. Both land in the same place; neither widens what can
  reach the page. `deploy/agent-ops-dashboard.init` (the legacy WSL SysV path)
  sends the server's output to `<state_dir>/dashboard-server.log`, so every
  artefact the dashboard produces lands under `state_dir` and nothing is
  written beside the checkout. All of its settings (`RUNAS`, `RUNHOME`, `APPDIR`, `PORT`,
  `PIDFILE`, `LOGFILE`) are defaults overridable from
  `/etc/default/agent-ops-dashboard`, so the script carries no host-specific
  path that must be edited in place.
- The version stamp: `ARG`s and the `build-info.json` write at the foot of
  `deploy/docker/Dockerfile`, and the "Work out the version stamp" step of
  `.github/workflows/build-image.yml` that supplies them (with a check that the
  built image reads its own stamp back — the failure mode is otherwise silent).
- The cleanup hook in `agent-cycle.sh`; `.gitignore` and `.dockerignore`
  entries for `dashboard/data.js` and `build-info.json`; the README
  "Monitoring" section's "Dashboard" subsection.

## Verifying a change

- `./scripts/lint-shell.sh` clean — shellcheck over every shell script in the
  repository, not just this component's. `.github/workflows/shellcheck.yml`
  runs the same script on every pull request, so this is a gate rather than a
  good intention: it used to be neither, and four findings accumulated here
  unnoticed (pipeline spec, acceptance check 1g).
- `test/dashboard-exposure.test.sh` passes: the page is reachable on the host's
  loopback and on no network, in each of the ways the two compose profiles
  arrange that. `dashboard-local` publishes every port scoped to `127.0.0.1`
  (`DASHBOARD_PORT` moving the host side alone) and carries no `network_mode`,
  while its server binds `0.0.0.0` on the container port the mapping names —
  the two halves fail in opposite directions, one to a page on every interface
  and one to a page that answers nothing. The `tailnet` `dashboard` publishes
  no port, keeps the sidecar's namespace and takes the default bind, so Serve
  reaches it and nothing else does. No other service publishes a port, and a
  bare `serve-dashboard.sh` still resolves to `127.0.0.1`.
- `test/version.test.sh` passes: a stamped image reports its build, an empty
  stamp (what a local `docker build` produces) falls through to git, a checkout
  reports `HEAD` and flags uncommitted work, neither source reports `null`
  rather than a half-filled guess, and the `(#N)` parser takes a squash-merge
  marker without taking a mid-subject issue reference for one. And none of the
  states that make a read fail — a repository with no commits, a clone with no
  `origin`, a stamp truncated mid-write — aborts a `set -e` caller, because
  `scripts/state-sync.sh` is one and a node that stops pushing is a node the
  fleet loses sight of.
- `test/publish-dashboard.test.sh` passes: the launcher exits 0 on a healthy
  (shortened) window and while another publish holds the lock; a cold window
  fetches from GitHub exactly once, a window following a fresh fetch not at
  all, and an aged stamp is refetched on the next tick; the batched cost scan
  matches the per-file semantics (day cut-off, torn-file tolerance, each row's
  own instant carried through as `ts` — `null` for a directory name that
  doesn't parse as one, which still counts toward the totals but drops out of
  `recent_costs` rather than guessing) and the
  whole publish stays within its process budget on a long history; a stage
  whose envelope parses but whose `result` is empty or whitespace-only still
  renders its cycle, with that stage's status `null`, while a stage whose
  envelope itself does not parse (a torn, mid-write file) still drops the
  whole cycle, exactly as before (TD26072802); and every
  node in a synthetic fleet answers for **itself** — a peer mid-cycle reports
  its own running stage, repo, source and item from its published log, a peer
  whose cycle ended reports idle and when, a node that has never run reports
  `live: null`, and our own row comes from the lock rather than the newest
  `cycle-start` (a tick that started, found the lock held and ended must not
  masquerade as what this node is doing). With the fleet's newest cycle
  unfinished, `status.last_cycle` skips past it to the newest that logged
  `cycle-end`, so the field the headers date it by is never null.
  The cost scan attributes each
  transcript to the actor that wrote it, names a review's as the Project
  Reviewer rather than a second cycle Reviewer, and leaves the actors summing
  to the total. Each node's version comes from its own heartbeat, and a peer
  publishing none reads as unknown rather than inheriting ours; the
  compose-drift and image-drift verdicts ride the same rule — a peer's from
  its heartbeat, a peer publishing none as null, never locally computed, and
  our own row answering for itself. And the
  pull-request index — driven through `DASHBOARD_GH_CMD`, so a GitHub tick
  costs no API call — resolves every reference the page holds including the
  version a node runs (which no open-PR query names), reads each pull request
  at most once, re-reads none of them on the following tick, carries forward
  across a `--no-github` tick, and bounds a cold fill to a few references
  rather than one burst. Two hand-appended `cycle: "manual"` records a
  fortnight apart raise no row in Recent cycles, take none of the `MAX_CYCLES`
  budget, and leave the real cycle at the top — while both events stay in the
  log tail. With more no-op ticks in the log than `MAX_CYCLES` — newer than
  the real work, as the `*/15` cadence produces — no stand-down or lock-held
  skip shape raises a row, the substantive cycles still fill the detail list,
  and `noop_ticks` counts every one of them, split by kind, carrying the
  newest tick's timestamp; a stand-down that also logged a `claim-lost`
  (issue #245's raced shape) keeps its row and stays out of the count, and so
  does one whose `cycle-end` never came. And with `cron.log` short and a
  `cron.log.1` beside it —
  `scripts/rotate-logs.sh` having just rotated — the cron panel's tail draws
  from both, oldest first, rather than going blank for the tick after a
  rotation. A cycle that lost a claim to a peer's contention (`claim-lost`,
  cause `held`) before a `selection` that names `race_losses` is marked
  `raced: true` carrying that same count, whichever `outcome` it then reached;
  one that lost every candidate carries `standdown_cause` — `"raced"` for
  contention, `"unreachable"` when every loss was a GitHub outage instead,
  `"pre-claimed"` when nothing was ever attempted because the cycle's own
  gather had already seen every candidate claimed (implementation spec 17a's
  `claim-skipped`) — and only a cycle with a `held` loss is marked `raced` at
  all: a GitHub outage names no peer to contend with, and a pre-claimed
  skip was never contention in the first place, so neither shape may wear
  contention's badge (implementation spec 17a, issue #245).
  An item that is blocked *and* void reaches `void[]` and not
  `blocked[]` (implementation spec 34h, acceptance check 8g), while an ordinary
  block beside it is still listed — a subtraction that over-reached would empty
  the panel that says the pipeline is stuck, which looks exactly like a pipeline
  that is not. Each of the five GitHub sources (TD-PPagop-26080201) is
  exercised both ways against a stubbed `gh`: healthy, each of the four
  state-carrying sources reads `answered` and a repo with no tech-debt
  register reads `answered_404`, never `failed`, while a healthy `pr list`
  leaves `github.ok` true; with one source's call failing (a rate limit, not
  the register's 404), that source alone reads `failed` (or, for `pr list`,
  is named in `github.error` directly), `github.ok` turns false — while an
  unrelated repo's own legitimate 404 still reads `answered_404` in the same
  tick, proving the two are told apart from each other and not just from the
  healthy case.
  The verdict-quality aggregate (issue #319) counts **both** terms of the
  rate and tells five shapes apart in one synthetic log: a verdict rejected
  then recovered by the retry that followed it, an accepted one over a
  non-empty eligible set (denominator only), one written before implementation
  spec 3v recorded `corroboration` events, an empty eligible set (neither
  term), and a verdict rejected twice that the Script then had to pick for.
  A cycle counts its verdict **once** — spec 3v writes both a `corroboration`
  and a `none-selected` for the same answer, and counting both would inflate
  every denominator by exactly the cycles that stood down cleanly. Two models
  in the same window carry separate rates and separate fallback counts; a
  `selection` is attributed to the Co-Ordinator model and never to the
  Implementer `model` the event itself carries; the newest rejection names its
  attempt, its own `unaccounted` refs and count, and what became of the cycle
  it happened on; and a log holding no Co-Ordinator record at all still ships
  the aggregate zeroed with a `null` rate, since the page can only distinguish
  a clean window from missing data if an empty window is still an object.
  The per-band tally (issue #345) sums `rejected` and `unaccounted` per band
  from a mix of shapes in the same synthetic log: one rejection naming two
  bands at once (counted in both), a second rejection naming one of the same
  bands again (summed, not overwritten), and a rejection logged with no
  `bands` at all, which lands under `unknown` rather than being dropped or
  folded into a real band, its `unaccounted` read from the sibling `warning`
  of its cycle since the legacy event carries no figure of its own.
  `counts.stage_models` (issue #529) is asserted from a synthetic log of six
  `stage-end` events: an Implementer run, a second that failed
  (`exit_code != 0`), that same cycle's retry, a Reviewer run with no `model`
  field, a second Reviewer run that has one, and a Co-Ordinator run — the
  failed run and its retry both count (one unit per stage-end, regardless of
  outcome), the model-less Reviewer event lands under `by_stage`'s "unknown"
  rather than being dropped, the Co-Ordinator's own stage-end contributes to
  neither stage, and a seventh event outside `COST_SCAN_DAYS` is excluded from
  both `by_stage` and `rows` while still being the log's oldest event and
  therefore setting `window_from` — proving that field spans the *whole*
  retained log, not just these two stages' own events. `rows` carries the same
  day-summed `{day, stage, model, n}` shape the page re-aggregates client-side.
  A log with no Implementer or Reviewer `stage-end` at all still ships the
  aggregate as a real, zeroed object (empty `by_stage`/`rows`) rather than
  omitting the key, the same "empty window, not missing data" contract
  `coordinator_verdicts` keeps.

- `test/dashboard-render.test.sh` passes its plain-`grep` check, run without
  `node` and independent of the harness below, that the header's documentation
  nav carries all six `blob/main/<path>` links (README, the three pipeline
  specs, the metering schema, the roadmap) verbatim in `dashboard/index.html`.
- `test/dashboard-render.test.sh` passes: `dashboard/index.html`'s own inline
  script, run unmodified under `node` against checked-in `DASHBOARD_DATA`
  fixtures and a DOM stub that only builds trees (`createElement`/
  `createTextNode`/`appendChild`, plus a serialiser — no layout, styling or
  event dispatch), renders the cells the fixtures name. This is what catches a
  page that renders the *wrong* thing rather than merely throwing: a cycle
  live in the Co-Ordinator stage with nothing selected yet reads "In
  progress", never the finished-cycle "Ended"; a cycle with no `cycle-end` and
  no node claiming it reads "No clean end" with fleet data and "Not ended"
  without any; a `needs-refinement` blocked row carries its badge and is
  removed by the hide filter; and the log tail's Node, Repo and Actor columns
  answer all three positionally — an actor read from `stage`, from `by`
  and from `handoff`, the review pipeline's named as the Project Reviewer, the
  clone step and the cycle-level events naming none, and a missing node
  keeping its own cell rather than letting the repository slide into it. A
  `disabled`/`enabled` event's badge is asserted to carry its `scope` (issue
  #426) — `disabled · node`, `enabled · fleet` — and a fleet-scoped one whose
  `fleet_flag` is `"failed"` to append `fleet flag: failed` to its Detail cell.
  A cycle fixture carrying `raced: true` renders the `↻ raced` badge beside its
  outcome badge, and no other cycle in that fixture renders it — the marker
  answers "how did this cycle get its outcome", not a second outcome of its
  own (issue #245); it also renders the "recovered race ×N" badge naming the
  count, while a separate fixture of a cycle that lost *every* candidate
  (`raced: true`, `standdown_cause: "raced"`, outcome `stand-down`) carries
  the `↻ raced` marker and never that one, having recovered nothing; and a
  third, of a cycle that skipped every candidate as pre-claimed
  (`raced: false`, `standdown_cause: "pre-claimed"`), renders as an ordinary
  stood-down row wearing neither race badge — a selection defect contends
  with nobody. A
  fixture whose `noop_ticks` counts more filtered ticks than the forty slots
  hold (issue #271) renders its substantive cycles as ordinary rows plus the
  one summary line — the total, the stood-down/lock-held-skip split and the
  newest tick's age — while a fixture with a zero aggregate (and one with no
  `noop_ticks` key at all, a `data.js` from before the field existed) renders
  no such line. The
  per-repo `nice` badge is asserted from two fixtures, because both of its
  silences are load-bearing and neither is visible on the page that has them:
  a repo at `-5` carries a blue badge naming `×3.05` and earlier attention, one
  at `3` a grey badge naming `×0.51` and later, both disclaiming starvation,
  under a note naming the Script rather than the Co-Ordinator; a repo with no
  key beside them carries nothing; and a config whose repos are all `0` or
  keyless renders no badge and no note anywhere on the page. A node behind an
  image published longer ago than `image_behind_grace_hours` carries an
  **image behind** badge naming the registry commit, while one whose registry
  check failed carries **image unverified** instead (#155). A node carrying a
  node-scoped disable (`switch.disabled`) shows a **disabled** badge beside
  its role badge, naming the reason and the expiry, while its own enabled
  self carries no such badge (#379). Two further fixtures separate that from
  the local record a fleet-wide `--disable` leaves on the node that issued it
  (`switch.scope: "fleet"`, implementation spec 2.3): with the fleet flag set,
  the page raises the fleet banner alone — no second banner for the mirror and
  no **disabled** badge on the issuing node, while a peer's genuine
  `--this-node` disable beside it still badges; with the flag cleared, the
  surviving mirror raises this node's own banner and badge, both naming it as
  a leftover of a fleet-wide disable since cleared rather than as a
  node-scoped decision. The merge-autonomy kill switch (D18 issue #576,
  `fleet.flags.merge_autonomy_kill`) is asserted from three further fixtures:
  a `state: "disabled"`, `record.kind: "manual"` one raises its own banner
  naming the reason, who set it and the `--restore-merge-autonomy` command
  that clears it, while never claiming every node stands down (the fleet
  switch's own wording) or badging any node disabled; a `record.kind:
  "fail-closed"` one still raises the banner but explains the state repo
  could not be confirmed clear rather than naming an operator, and omits the
  clear command a cause no command fixes has no business offering; and a
  fixture carrying no `merge_autonomy_kill` flag at all — every `data.js`
  from before this field existed — raises no such banner. A cycle whose
  `selection` carried `race_losses` (implementation spec 17d, #248) shows a
  blue **recovered race ×N** badge beside its title in the cycle history —
  informational, not a warning, since losing a claim race and then winning a
  later one is the claims (17a) working as designed — while a cycle with no
  `race_losses` at all shows none. A source marked
  `failed` in `github.inputs[<slug>].state` (TD-PPagop-26080201) renders a
  "couldn't read" marker in place of its count, a source marked
  `answered_404` (a repo with no tech-debt register) still renders an
  ordinary zero, and a fixture carrying no `state` field at all — every
  repo's data from before this field existed — renders exactly as it always
  did. The spend-today card's persisted GMT/local/24h choice (#186) is
  asserted by seeding the harness's `localStorage` stub rather than
  simulating the click: with no stored choice the card reads "today (GMT)"
  against `spend_today_usd`, and a stored `24h` relabels it "last 24h" and
  sums only the `recent_costs` rows within a rolling 24 hours; a stored
  `local` is asserted for its label only, since which rows fall on the
  reader's own calendar date depends on the moment the suite runs. The void
  list's two caps are asserted from a twelve-row fixture whose
  two oldest rows sit *first* in the data, because the cap is only meaningful
  once the list is sorted: the heading counts twelve, the ten newest render
  (the tenth-newest last), neither old row appears until asked for, the
  see-more control names how many are held back, and every row carries both
  the height cap and the class that makes it open. A fixture inside the cap
  renders no control at all.
  The Co-Ordinator verdict-quality card (issue #319) is asserted in both its
  populated and its zero state, because they are the two readings an operator
  acts on and only one of them was ever going to be exercised by accident: a
  fixture carrying rejections renders the rate *and* both terms of it, a red
  badge at three-quarters, the recovery line naming the retries and the picks
  the Script had to make itself, a row per day per model with the second model
  attributed apart from the first, a day with nothing to corroborate showing
  no rate rather than a zero one, and the newest rejection beneath — its
  attempt, reason, machine detail, unaccounted refs, the stated count of the
  ones the cap held back, and what became of the cycle it happened on. A second fixture with verdicts but no rejections renders
  the green "no rejected verdicts in this window" against its own denominator
  and no contradiction block at all, while a `data.js` from before the
  aggregate existed says so outright rather than rendering that same clean
  zero for data it does not have.
  The cost section's blocks (issue #330) render inside one `.costgrid`
  container in reading order — by-day, by-model, by-actor, both cost notes,
  then (issue #529) the two model-used pies — at the same depth as the charts
  rather than as paragraphs beside the section. Document order is what is
  asserted because it is what the layout rests on: a multi-column flow fills
  each column top-to-bottom in document order, so the order of the appends
  *is* the order a reader sees, whichever column each block lands in.
  Out of scope by the same tree-building limit:
  the pull-request hover card's pointer/focus behaviour, and which column the
  browser balances each cost block into — that is layout, and layout is what
  this stub does not do; it is covered by the manual check below.
  The model-used pies themselves (issue #529) are asserted from
  `stage-models.json`, which carries Implementer rows at day 0 (sonnet, opus)
  and day 3 (sonnet), and Reviewer rows at day 3 (sonnet) and day 40 (a
  model-less event): the default (Lifetime) render sums the Publisher's own
  `by_stage` totals straight through, including the day-40 row folded into
  "unknown" rather than dropped, with each slice's full model id in `title=`,
  its `shortModel()` label, and its percentage and count in the legend; a
  1-day window re-aggregates the Implementer pie to that day alone (50/50) and
  renders the Reviewer panel as `.empty` — its only row that day was never
  logged — rather than a blank or a zero-slice pie; a 7-day window restores the
  Implementer pie's lifetime ratio and gives Reviewer its one (day-3) model at
  100%, still excluding the day-40 "unknown" row; and the caption states both
  the aggregate's own retained-log window and that a failed run or a retry each
  count as their own slice. A `finished.json`-shaped fixture predating
  `counts.stage_models` entirely still renders both pie headings — reading `[]`
  off the absent aggregate, same as any other pre-#529 payload — with no third
  costnote, since that caption only exists once the Publisher actually ships
  the aggregate.
- The back-pressure card agrees with the gate it depicts, in both directions,
  from two fixtures of its own. `backpressure-claims.json` (issue #427) holds
  a changes-requested PR, a draft, an approved PR waiting on a human, one
  unraised item claim and one `pr-<n>` exclusion entry: the gauge reads 3 of
  3 and trips red, counting the claim the open-PR listing cannot show it and
  not the exclusion entry, whose PR is in that listing already.
  `backpressure-claim-scope.json` (the over-correction in PR #434) holds seven
  registry rows against two PRs: the gauge reads 4 of 8 and does not trip,
  having dropped the `enabler` and `refiner` pseudo-slug tombstones, the
  `pr-<n>` entry, and the item claim on the draft already counted — while
  keeping the item claim on the *approved* PR, which sits in the human's queue
  outside the sum and so is the only record of that work in flight. Both
  assert the `title` tooltip verbatim, because it is the composition
  `agent-cycle.sh` logs and the two are meant to be readable against each
  other. The live-claims panel below is asserted to still show the
  pseudo-slug rows in full: the gauge's narrowing is a statement about the
  cap, not about what an operator hunting a stuck item may see.
- On a node that has been up for at least ten minutes,
  `grep 'github: refreshing' <state_dir>/dashboard.log | tail -3` shows one
  line roughly every five minutes, and `github.fetched_at` in `data.js` is
  within about five minutes of `generated_at`. Those two facts are the whole
  of "the PR panels are live"; nothing else on the page distinguishes a
  refresh that is happening from one that is not. (If that `grep` comes back
  empty or says "binary file matches", check for a hole before concluding the
  heartbeat is dead — `tr -d '\0' < dashboard.log | wc -c` against the file's
  size. The launcher repairs one at the top of each window, so this should
  only ever be true of a log written by a node that has not yet rolled.)
- `scripts/publish-dashboard.sh` against the real `state_dir` produces valid
  JSON (`data.js` minus the wrapper passes `jq empty`), and `grep` finds no
  `/home/…` path or token in the output.
- Open the page and confirm the panels populate: a failed cycle appears under
  Failures, and its transcript + stderr open inline. On a fleet, each node's
  card names what that node is doing and the header counts how many are working;
  on a single node the header carries the detail itself and there is no strip.
- On that same page, the cost section reads down the left column and on down
  the right, with no column running conspicuously past the other and the cost
  notes last (issue #330). This one is checked by eye in a browser, in both
  colour schemes and on either side of the 760px breakpoint, because the split
  is decided by the browser from the rendered heights: nothing that runs
  without layout can see it, and the DOM-stub harness above deliberately
  asserts only the document order the split is taken over.
- With a `blocked` row whose `kind` is `needs-refinement` in `data.js`, the
  Blocked items table shows a **refinement** badge next to that row's item id,
  the heading names how many refinement blocks there are, and its "hide N
  refinement blocks" checkbox — shown only when at least one exists — removes
  those rows from the table (and the heading's count) when checked, restoring
  them when unchecked. An ordinary blocked row (`kind` unset or `""`) carries
  no badge and is unaffected by the filter. `test/dashboard-render.test.sh`
  asserts the badge, the count and the checkbox's label from a fixture; the
  checkbox's own click behaviour is outside its tree-building DOM stub, so
  stays a manual check here.
- With more than ten `void` rows in `data.js`, the Void items table shows the
  ten newest, `See more — N older items` at its foot reveals the rest and turns
  into `See fewer`, and a row whose reason runs past three lines is clipped with
  an ellipsis and opens to the whole of it when clicked (clicking again closes
  it). Leave a row open and use the control: the re-render that follows must
  keep both that row open and the list expanded — the same survives-a-rebuild
  rule the cycle rows and open transcripts follow. Like the refinement filter,
  the assertions cover what renders and the clicking is manual here.
- While a cycle is in flight, its row in Recent cycles reads **in progress**
  from the moment it starts — including during the Co-Ordinator stage, before
  any `selection` is logged, which is the whole window in which the log-derived
  ladder has nothing to say — and no finished row's badge changes. Check the
  first minute of a cycle specifically: that is where reading the ladder alone
  produces "Ended". `test/dashboard-render.test.sh` asserts this from a fixture
  in that exact window; this manual check is for confirming it against a real
  running pipeline too.
- A pull-request number behaves the same way under a pointer, a finger and a
  keyboard. Hover one and the card opens; move off and it closes. Click it and
  the card opens **and stays**, the page does not go to GitHub, moving the
  pointer away does not close it, and hovering another number does not move it;
  click the same number again, click off the card, use its close button or
  press `Escape` and it closes — while a click *inside* the card does not.
  Ctrl/cmd-click still opens the PR in a new tab, and `Enter` on a focused
  number still navigates. On a phone (or a touch-emulating browser) a tap opens
  the card rather than GitHub, the card fits the viewport, and its close button
  and *View on GitHub ↗* link are both reachable. Leave a card open across a
  refresh or two: it is still there, and still pinned if it was pinned — a
  rebuild destroys the focused anchor, so this is where a stray `focusout` can
  close the card the reanchor just reopened.
- The page has zero console/page errors (it renders headlessly under a browser
  with no thrown errors).

## Design decisions

- **Single generated data file + committed page**, rather than a server or a
  build: the cheapest thing that works, openable as a `file://` with nothing
  running, and trivial to regenerate.
- **Local/private, no GitHub Pages or Action.** An earlier draft proposed a
  scheduled Action publishing to a companion repo; it was dropped as needless
  cost and exposure. The machine is authenticated and the repos are public, so
  the local Publisher fetches all GitHub data itself; a localhost page can't be
  viewed while the machine sleeps anyway, which was the Action's only draw.
- **Remote access is tailnet-scoped, never public.** The README's "View it
  away from home" section layers `tailscale serve` in front of the untouched
  loopback server (`deploy/tailscaled.init` runs the daemon on this
  systemd-less WSL distro): the server still binds `127.0.0.1`, Tailscale
  authenticates each viewing device against the owner's own tailnet, and
  traffic is end-to-end WireGuard. This loses nothing while the machine
  sleeps — the pipeline only produces telemetry while awake. Public exposure
  (`tailscale funnel`, Pages, shareable tunnel URLs) stays rejected for the
  reasons above.
- **The page fetches nothing external.** All GitHub reads happen in the
  Publisher via `gh`; the page reads only its local `data.js`. Offline-capable,
  dependency-free, no CORS or rate-limit concerns.
- **Redaction is unconditional** even though the data is local, so a
  screenshot or copied file is safe and a future private repo can't leak.
- **Limit detection is independent of the log**, because the pipeline's logger
  misses weekly-limit phrasing — the dashboard reads the transcripts directly.
- **A skipped GitHub fetch is not a failed one.** Once the heartbeat runs every
  few seconds, most ticks publish with `--no-github` to spare the API, and a
  full fetch happens only once per window. If a `--no-github` tick simply wrote
  `github.ok = false` with empty `prs`/`inputs`, the dashboard would blank the
  PR list and work sources — and raise the "GitHub unavailable" banner — 59
  ticks out of 60, turning a deliberate skip into a standing false alarm. So a
  skip carries the **last real fetch forward** (cached beside the state, marked
  `stale`) and never touches `ok`. `ok` therefore means one thing only: the
  most recent *attempted* fetch and whether it succeeded. `ok === false` — the
  banner's trigger — now fires only for a fetch that ran and failed; a skip is
  `ok` unchanged, and a never-yet-fetched page is `ok: null`, neither of which
  is an alarm. The staleness is not hidden: `stale`/`fetched_at` say how old the
  GitHub half is, distinct from the whole page's `generated_at`.
- **Carrying a fetch forward silently is what let a broken cadence hide, so
  the two ages are now both on the page.** The decision above is right, and it
  has a cost: a fetch that is never taken is indistinguishable, on screen,
  from one taken a moment ago. When the launcher's gate turned out never to
  fire under cron (see **Heartbeat**), the page went on reporting "data 3s
  ago" over PR data half an hour old, and every panel rendered perfectly. Two
  things follow, and both are load-bearing rather than decorative. The header
  shows `data <age> · GitHub <age>`, and past 12 minutes the second turns
  amber and raises its own banner — a reader can now see which half of the
  page is old. And the cadence has a test (`test/publish-dashboard.test.sh`,
  driven through `LAUNCHER_PUBLISH_CMD` so it costs no API call) asserting
  that a cold window fetches exactly once, a warm one not at all, and an aged
  stamp is refetched on the next tick. A behaviour whose failure mode is
  *looking healthy* cannot be left to a careful reading of the script.
- **The GitHub tick's gate is a duration, not a point in the schedule.** The
  rule "fetch when the last fetch is older than N" holds whenever the tick
  runs; the rule "fetch on the tick that lands at second zero" holds only if
  such a tick exists, which is a property of cron's alignment, the loop's
  bounds and how long a publish took — three things that are decided
  elsewhere and that no test here was watching. The first rule also degrades
  the way this page wants: on a missed window it fetches late rather than not
  at all, and on a GitHub outage it retries at the cadence rather than at the
  tick rate, because the stamp records the *attempt*.
- **The blocked and void lists are not computed here.** `blocked[]` and
  `void[]` come from the same shared implementation the Script feeds its
  Co-Ordinator (`lib/cycle-state.sh`, per requirement 34a of
  `docs/IMPLEMENTATION-PIPELINE-SPEC.md`) — `open_blocked_items` and
  `void_items`; only the projection for display is local. The dashboard originally had its own near-copy of the
  rule, and the two silently disagreed — which matters more here than
  anywhere else, because this page is where someone looks to find out why the
  pipeline is repeating itself. A monitor that reimplements the thing it
  monitors will agree with it right up until the moment that would have been
  useful. Anything else the page reports that the pipeline also computes
  belongs under the same rule: share the definition, don't mirror it.
- **A cycle's source is a column, not a detail.** Which source the
  Co-Ordinator drew an item from is not a fact about that one cycle so much as
  a fact about the pipeline: read down the column and you see the mix it is
  actually working — all security this week, or nothing but tech-debt for two
  days. That reading only exists if every row shows it at once, which a
  per-row expand forecloses. The detail row still repeats it verbatim
  alongside the rest of the record; the duplication is deliberate.
- **An outcome is something a cycle has to finish to have.** The Publisher
  classifies a cycle by reading its events against a ladder — `pr-ready`, then
  `pr-raised`, `attempt-failed`, `none-selected`, `stand-down`,
  `cycle-skipped`, `selection` — and that ladder answers the question "how did
  this go?" for a cycle that is over. Asked of one still working it answers
  anyway, in the past tense, and its floor is the worst available reading: a
  cycle whose Co-Ordinator is still choosing has logged nothing on the ladder
  at all, so a job three minutes old rendered as **Ended** for the whole
  length of its first stage. So the column now consults `ended_at` first — the
  `cycle-end` timestamp, which is the only thing in the record that says the
  cycle is over — and reports a state until there is an outcome to report.
  Which state needs one fact the log cannot supply: a `cycle-start` with no
  end looks identical whether the cycle is running or the node died holding
  it, so the row asks the fleet whether any node claims that cycle as its live
  one, exactly as the node cards do, and says **no clean end** when none does.
  That last one is an accusation, so it is withheld where the data cannot
  support it: `data.js` written before the fleet strip existed carries no node
  list at all — which is what a page reloaded from an updated checkout reads
  until the Publisher next runs — and there the row says only **not ended**.
  Nothing is lost by dropping the mid-flight rungs: how far a running cycle
  has got is what the Item, Stages and PR cells beside it already show, and
  they show it without asserting that it stopped there.

  `status.last_cycle` is the same mistake one field over, and is fixed the same
  way: it means "the last cycle the fleet ran, and how it went", both readers
  take a finished cycle for granted — the headers date it by `ended_at`, the
  node cards badge it by `outcome` — and it was nonetheless filled with the
  newest cycle-start, finished or not. So an unfinished newest cycle dated the
  fleet's last activity with a null, which `fmtAgo` renders as an em-dash:
  "last cycle — ago". It now selects the newest cycle carrying an `ended_at`,
  and is null when none has, which the headers already render as no last-cycle
  clause at all. The general rule both cases are instances of: **a field whose
  readers assume a finished cycle must select for one**, because every cycle
  list on this page is newest-first and the newest is exactly the one most
  likely to still be running.
- **A record in the log is not the same thing as a cycle, and the cycle list
  now says so.** The Publisher built one row per distinct `cycle` value in the
  log union, which quietly assumed every record came from a run. Some do not:
  the pipelines' own documented escape hatch for a stuck item is a hand-written
  `unvoided` (README, "Unsticking an item"), and it carries the
  `cycle: "manual"` sentinel. Every such record, from every node, for all time,
  therefore collapsed into a single phantom row — and each of the row's cells
  then failed in the direction that looks most like a real problem. With no
  `cycle-start` the Started column falls back to the first event's timestamp,
  so the row was dated to the earliest hand-edit anyone had ever made and
  froze there; with no `cycle-end` and no node claiming it, the Outcome column
  reached for the accusation above and read **no clean end**, permanently, of
  something that was never running; with no `cycles/manual` directory the
  Stages cell showed three empty stages, as though the work had been abandoned
  before it began. And because the fleet ordering is a reverse *lexical* sort
  of the id — the one sort that interleaves every node's history correctly,
  since a real id begins with its UTC timestamp — `manual` outranked every
  digit and pinned itself above every genuine cycle, holding one of the
  `MAX_CYCLES` slots for good.
  The fix is to filter on the id's shape where the list is built, rather than
  to special-case the string `manual` or to re-sort by `started_at`: the sort
  is not what is wrong, and a filter on the shape covers the next sentinel
  anyone invents as well as this one. Doing it in the Publisher rather than the
  page keeps the events themselves in the log tail, which is where a record
  about the pipeline belongs, and leaves untouched every reader that acts on
  them — the limit stand-down, the blocked and void sets — because each keys on
  the event and the item, never on the cycle.
- **A no-op tick is counted, not listed (issue #271).** `MAX_CYCLES = 40` was
  sized for an hourly cadence; the `*/15` change (#268) quadrupled the tick
  rate without touching it, and most of the new ticks are no-ops — a
  stand-down short-circuit or a lock-held skip, three events and no stage.
  Filling the fleet's forty detail slots with those cut the window from
  roughly half a day of history to two-to-four hours, most of it rows
  carrying nothing. The two candidate fixes were to raise `MAX_CYCLES`,
  which grows `data.js` — the very thing the fleet-wide cap protects — or to
  stop no-op ticks consuming slots; the second was chosen, with the filtered
  ticks surfaced as the `noop_ticks` aggregate rather than dropped, so the
  cadence itself stays visible (a fleet whose ticks stop aggregating has a
  scheduler problem this line would otherwise hide). The aggregate is O(1)
  by construction — three counts and one timestamp, never a second list —
  and the filter matches the exact three-event shapes rather than every
  `stand-down`/`skipped` outcome, so a stand-down that carries more than
  the shape (a raced one, #245) keeps its detail row and its badges. What
  this costs: a *fresh* stand-down no longer has a row of its own, and its
  reason text is a log-tail read rather than a click — the aggregate's
  newest-tick timestamp and the standing banners (switch, usage-limit) are
  what keep that reading a glance.
  Losing a claim to a peer's healthy contention and then claiming the next
  candidate is not a different outcome from an ordinary first-try
  selection — the cycle still did whatever `outcome` already says, PR raised
  or otherwise — so `raced` is not folded into the outcome ladder as a new
  rung. It is a fact about *how* the cycle got there, rendered as its own
  small badge beside the outcome badge (`↻ raced`, titled with the loss count
  and whether the race was recovered or the cycle stood down over it), the
  same layering the in-flight badge below already uses for "still working"
  beside a floor reading it does not want to overwrite. A `standdown_cause`
  of `"raced"` on a stood-down cycle gets the identical badge, for the same
  reason "Stood down" alone does not say whether the fleet's own contention or
  a GitHub outage caused it — reading the reason text is not a substitute a
  glance at the column can make. A `standdown_cause` of `"pre-claimed"`
  deliberately gets no badge: no peer raced this cycle for anything — its
  Co-Ordinator proposed work the gather had already seen claimed — and the
  row's reason text names that defect; its `claim-skipped` events are also
  what keep the row out of the `noop_ticks` aggregate, so the shape stays
  visible in the history rather than being counted away. Blue, like the "recovered race ×N" badge
  beside the item and for implementation spec 17d's reason: contention is the
  fleet working, and amber on this page is reserved for what wants acting on.
  The two badges do not say the same thing twice, either: `race_losses` is a
  count of this cycle's own `claim-lost` events, so a cycle that lost every
  candidate carries one without ever having claimed anything, and "recovered
  race" is withheld from it — an outcome of `stand-down` is exactly the case
  the word "recovered" would be false of.
- **Distinct classes of data are distinguished by shape, not colour alone.**
  Source tags are outlined and square; outcome badges are filled pills. Both
  are colour-coded, and the two sit side by side, so without the shape
  difference "Failed" and `security` would read as the same kind of label in
  the same red. Colour then carries identity *within* a class, shape carries
  the class itself — which is also the only reason eight source colours are
  legible at all: eight hues is past what hue alone reliably separates,
  especially for a colour-blind reader. Any future class of badge on this page
  should take a third shape rather than a ninth hue. The in-flight badge takes
  the rule the same way: it stays a filled pill, because it sits in the outcome
  column and belongs to that class, and carries the page's existing live/idle
  dot inside it — the same mark the header and the node cards use for the same
  meaning — so "still working" is legible without colour and without inventing
  a shape for a thing that is not a new class of data.
- **The source label/colour map is display-only, and fails open.** The
  vocabulary itself belongs to the Co-Ordinator (`prompts/coordinator.md`'s
  `sources` list) — the page cannot share that definition the way it shares
  the blocked/void rule above, because `data.js` carries only whatever token
  the pipeline already emitted. So the map styles tokens; it never decides
  them. An unrecognised source renders in grey with its raw token, never
  dropped and never silently blank: a source added upstream then shows up
  unstyled, which is a prompt to add a colour, rather than invisibly missing
  from the mix — the one thing the column exists to show.
- **A `nice` badge has to name the Script, because the panel it sits in names
  the Co-Ordinator.** The page's one per-repo surface is headed "Work sources
  (what the Co-Ordinator sees)", and a `nice` is the one ordering input the
  Co-Ordinator is deliberately never given: the Script computes the walk order
  and hands over the finished list, and the values themselves never reach the
  model (pipeline spec, requirement 3). A badge dropped in unqualified would
  therefore make the page assert the opposite of the design, on the surface an
  operator reads precisely when asking why a repo keeps coming up first — and
  the next place that reading sends them is the Co-Ordinator's prompt, where
  there is nothing to find. Hence the note above the panel rather than the
  tooltip alone: a tooltip is invisible to a glance, absent under a finger, and
  this is the half of the answer that decides where someone looks next.
- **A neutral `nice` renders nothing, not a zero.** A repo at `0` and a repo
  with no `nice` key are the same repo, and a fleet that has set none is the
  ordinary case, so neither draws a badge and the note stays off the page
  entirely — a config with no `nice` anywhere renders byte-for-byte the page it
  rendered before the feature existed. This is the same omit-never-empty
  contract `lib/repo-order.sh` keeps for the no-op fingerprint, kept here for
  the matching reason: a neutral config should be indistinguishable from one
  predating the feature, on the page as in the hash. A `nice 0` badge would
  also be the wrong kind of information — three repos each wearing one says
  the weighting is a thing being *used*, when what it means is that nobody has
  touched it.
- **Plan limits are not on this page, because they are not obtainable
  (checked 2026-07-17).** The obvious feature request — show used vs remaining
  credits for the current session and the weekly limit, in the header — was
  investigated and dropped as not buildable, and this note exists so it is
  investigated once rather than every time someone notices the gap. For an
  individual Pro/Max subscriber there is no supported source: no `claude usage`
  subcommand exists; `--output-format json` carries no quota field (see "State
  it reads"); `/usage` is interactive-only; and the Admin/Usage API is
  documented as *"unavailable for individual accounts"* — it needs an
  organisation on Console API billing. The numbers do appear to be cached in
  `~/.claude/.credentials.json`, and that is the temptation to resist: it is
  undocumented internal structure inside a secrets file, so it can change shape
  without notice, and Claude Code itself serves those bars from a cache up to
  an hour stale. A stale limit bar is worse than no limit bar, because it is
  the one number an operator would act on — and it would sit next to a
  freshness clock implying it was current. If a supported read ever ships, the
  header centre is where it goes.
- **Cost is labelled as an estimate, not as spend.** The cards and charts say
  "Est. token cost" rather than "Spend", with a note saying what the figure is.
  They previously said "Spend today", which on subscription auth quietly
  asserts two false things: that the money was charged, and that the dashboard
  is tracking a budget. Someone reading a spend figure next to a pipeline that
  can hit a usage limit will reasonably join those two facts up, and conclude
  the dollars are what runs out. They are not related: the limit is denominated
  in tokens and time, and no arithmetic on this page converts one into the
  other. The figure is worth showing — it is a good proxy for how hard the
  pipeline is working, and it is the only per-cycle cost signal there is — but
  it has to be named for what it measures. A second `p.costnote` underneath
  states the currency (USD) outright (issue #438): every dollar figure on the
  page — cards, charts, the estimate note above it — is the same fixed
  currency regardless of the Claude account's own billing region, and that
  isn't obvious from a bare `$` sign to a reader whose local currency also
  uses one.
- **Cost is cut by actor as well as by model and by day, because the actor is
  the only one of the three anybody chooses.** The day is a fact about when the
  cron fired; the model is nearly a restatement of the actor, since
  `config.json` pins one model per role. What an operator can actually decide is
  which agent does what — whether the Reviewer needs Opus on complex work,
  whether the Enabler is earning its cycles, what a weekly project review really
  costs against an hour of implementation. None of that is legible from the
  other two charts, and all of it was already on disk: the actor is the
  transcript's own filename, so this cut needed no new field, no new log event
  and no extra API call.
- **The cost charts balance into columns instead of a fixed grid (issue
  #330).** A `.two`/`.stack` split — by-day alone on the left, by-model and
  by-actor stacked on the right — left a gap under the right column on any
  day that by-day's sixty rows ran noticeably longer than the other two
  combined, because the split was pinned at build time to a guess about
  relative height rather than measured against it. `column-count: 2` with
  `break-inside: avoid` on each block instead lets the browser's own balance
  algorithm decide the split from the rendered heights on every load: the
  blocks — day, model, actor, both cost notes, then the two model-used pies
  (issue #529) and their own note — stay in that reading order and simply
  land wherever the shorter side is, no JS layout code and no new data
  needed.

  What this buys is a split that is right for the data in front of it rather
  than for the data the layout was written against, plus the note's own
  height reclaimed from a gap it used to sit below. It does not flatten the
  section: while by-day holds sixty rows and the other blocks hold five rows
  or fewer each, no arrangement of them fills a column that one of them sets
  the height of, so the right column still ends well short of the left.
  Closing that would mean letting by-day itself break across both columns,
  which buys the space at the price of a chart whose heading stands over half
  of it.
- **"Today" defaulted to GMT with no way to say so, until #186.** The card's
  figure was always `spend_today_usd`, computed against `date -u`, and nothing
  on the page told a reader in another zone that "today" wasn't theirs. Fixing
  that needed two things the Publisher alone can't decide: which reading the
  reader wants, and which calendar day a given cost fell on *for them*. Neither
  is knowable server-side — a dashboard has no fixed reader, let alone a fixed
  zone — so `recent_costs` ships raw `{ts, cost}` rows (three days back, ample
  padding either side of any real zone or of a `last 24h` window) and the
  arithmetic for "local" and "24h" runs client-side, against `new Date()`. The
  chosen mode is `localStorage`, not a query param or a server-side setting: a
  dashboard has no accounts and no URL a reader necessarily bookmarks, and a
  choice that reset on every visit would answer #186 no better than not asking
  at all. `spend_today_usd` itself is untouched — GMT stays the default and the
  cheap path when a reader never touches the toggle.

  Adding it exposed that the roll-ups were **not totals**. The scan read
  `cycles/` and not `reviews/`, so the weekly Project Reviewer — the most
  expensive actor per run — contributed nothing to spend-today, spend-total,
  by-day or by-model. That is a worse fault than a missing chart: the numbers
  were not per-pipeline, they were simply short, and nothing on the page said
  so. Both directories are now scanned. The figures step up on review weeks;
  they were wrong before, not inflated now.
- **A pull-request number is rendered by one widget everywhere, and it carries
  its record.** `#89` on its own says almost nothing, and the click that would
  explain it costs a context switch — enough friction that nobody spends it
  while scanning, which is what this page is for. So every number on the page
  goes through one renderer that attaches a record card: repo, title, state,
  author, opened/merged times, the merge commit, labels, and — while it is open
  — checks, review decision and mergeability. It is deliberately generic rather
  than special-cased per panel, and the newest use is the one that proves the
  point: on a fleet card the number *is* the version statement, so the record
  behind it is the whole of what makes the card readable.

  Two things keep it honest. The card names **the cycle that raised the PR**,
  joined client-side out of the cycle list rather than recorded anywhere — the
  pipeline already logs `pr_url` per cycle, so the join cannot fall out of step
  with the table three panels down, and it costs nothing. And a number with no
  entry yet says exactly that, rather than rendering an empty card: an index
  miss is the ordinary state of a PR raised since the last fetch, not an error.

  **The card is a peek on hover and a pin on click, and a click does not follow
  the link.** Hover was the whole interaction to begin with, and on a phone
  there is no hover: the tap that opened the card was the same tap that left
  for GitHub, so the card flashed and the page was gone. That is the reader who
  needs it most — a phone is where the dashboard gets checked away from a desk,
  and where opening GitHub to answer "did that land?" costs the most. So a
  plain click now opens the card and pins it, and the *View on GitHub ↗* link
  the card already carried is the way through.

  The two modes are kept strictly apart, because mixing them is what makes this
  pattern annoying elsewhere: a card opened by hovering closes by unhovering,
  and a card opened by clicking closes only by clicking — off it, on the number
  again, on its close button, or `Escape`. A pinned card therefore neither
  evaporates when the pointer drifts nor chases the pointer onto the next
  number along, which matters because reading one is a deliberate stop. The
  close button exists for the pinned case alone: dismissing by "tap the blank
  page behind it" is not an affordance anyone can see, and the number that
  opened the card is under the reader's own thumb.

  Navigation is not lost, only unbound from the plain click. Modifier and
  middle clicks still open the PR, the `href` stays on the anchor so the status
  bar and "copy link address" tell the truth, and `Enter` still navigates —
  keyboard focus already opens a peek without spending the activation, and the
  card is not in the tab order behind the link, so pinning it from the keyboard
  would strand a reader in front of links they could not reach.

  The index is affordable because a **merged or closed pull request is
  immutable** — cached permanently by ref, so a warm tick spends nothing however
  many numbers are on screen — and because the cold fill is bounded to a few
  references a tick, since forty `gh pr view` calls at `GH_TIMEOUT` each would
  not fit in the heartbeat's window. Its reference set is gathered from the page
  itself, which is also what stops the cache growing: it holds what is on
  screen, and needs no expiry rule of its own.
- **A node's version is a pull-request number, and the image has to be told
  it.** "Which version is this container running?" had no answer anywhere. A
  fleet is *routinely* mid-update — `watchtower-pre-update.sh` defers a roll
  while a cycle is in flight — so nodes differing is normal, and the question
  that matters ("has the fix reached the node that needed it?") could only be
  answered by exec'ing into containers. The answer is now on the card.

  It is a pull-request number rather than a SHA because a SHA names the bytes
  and a pull request names the change: `#89` has a title, a diff, a review and a
  merge time behind it, and the widget above puts all of that one hover or one
  click away.
  The commit is shown too, abbreviated and linked, for anyone reconciling
  against `docker image inspect`. And the image cannot work either out for
  itself — `.dockerignore` keeps `.git` out, correctly, because the image is a
  deployment and not a working tree — so CI stamps `build-info.json` at build
  time and `lib/version.sh` falls back to git for a checkout. A peer's version
  travels in its heartbeat, since a peer publishes no container; a peer that
  publishes none reads as *unknown* rather than inheriting ours, on the same
  rule as every other derived peer fact.

  The `behind` marker is grey, not amber. Being behind is the expected state
  during a roll, and colouring an ordinary condition as a warning teaches an
  operator to ignore the colour. What it is there to catch is a node that stays
  behind — a watchtower that has stopped rolling — which shows up as the marker
  failing to clear, and which nothing else on this page would reveal.

  Beneath the version sits the node's *deployment file*, which the image
  cannot answer for: a node holds its own `compose.yaml`, no roll can update
  it, and a merged compose change sat inert on every node twice before
  anything said so (#131). The card renders the heartbeat's compose-drift
  verdict (implementation spec 2.5, `lib/compose-drift.sh`) as a badge —
  **compose drifted** when the node's copy differs materially from the copy
  its image shipped, **compose unverified** when the file is not mounted into
  the containers at all, which itself means the file predates the check and
  is behind. Both are amber where `behind` is grey, deliberately: `behind`
  resolves itself on the next idle poll, while a drifted compose resolves
  only when a human re-fetches the file and runs `up -d` on that host, and
  an amber that never clears by itself is exactly the alarm that was
  missing. `in-sync` renders nothing, and so does an absent verdict — a peer
  on an image from before the check, or an install that is no container —
  because for an image the roll already on its way will start answering, and
  a node whose rolls have stopped is the version line's `behind` failing to
  clear, already caught above.
- **The `behind` version marker cannot tell a uniformly stale fleet from a
  healthy one, so a second badge compares against the registry instead
  (#155).** `behind` (above) compares nodes with each other —
  `fleetNewestVersion()` — which is exactly what reads as agreement when
  every node adopts the same broken image at once, as happened across
  #149/#154: four nodes, four identical commits, four green cards. The image
  badge (`lib/image-drift.sh`, via the heartbeat) instead compares each
  node's own commit against `ghcr.io/poetic-poems/agent-ops:latest`'s own
  `org.opencontainers.image.revision` label — read anonymously over the
  registry's API, never `origin/main`, since a documentation-only merge
  publishes no image at all and would otherwise read as false staleness (see
  "The node stack" in the implementation-pipeline spec).

  **image behind** is grey while the registry's newest image is younger than
  `image_behind_grace_hours` (`config.json`, surfaced in `config`) — the same
  colour and the same reasoning as the version line's own `behind`, since the
  same explanation applies. Past the grace it turns amber, `compose`'s
  colour: by then the ordinary deferred-roll explanation has had time to
  resolve itself, and a node still behind may have a watchtower that has
  stopped rolling altogether. **image unverified** is its own grey badge
  rather than silence — unlike compose's absent-verdict case, nothing else
  on the page would otherwise say the registry check was even attempted,
  whether because it failed outright or (routinely, right after this code
  first rolls out) a peer's heartbeat predates it. `current` renders
  nothing, the same rule every other in-sync verdict on this page follows.

  The registry query is a real network round trip, unlike every other field
  on this card, so it is not repeated on the dashboard's 5-second tick:
  `<state_dir>/.image-drift-cache.json` (excluded from state-sync
  replication, like the other local caches) holds the last answer, and
  `scripts/state-sync.sh`'s own heartbeat push shares the same file, so
  whichever of the two next crosses `IMAGE_DRIFT_TTL` pays the one query.
- **A node-scoped disable (implementation spec 2.3, `--disable --this-node`,
  issue #379) gets its own badge beside the role badge**, not just the
  page-top switch banner. The banner (above) is keyed to *this* node's own
  switch, so it already covers a node-scoped disable on the node whose page
  you are reading — but the fleet strip shows every node, and a peer's own
  node-scoped disable sets no fleet flag and appears in no banner at all.
  Without a per-card badge, a peer stood down that way is indistinguishable
  from an idle one, on the same page that goes to some trouble to say so for
  a fleet-wide disable. Amber, **disabled**, titled with the reason, who set
  it and its expiry — the same three facts the switch banner leads with, read
  through the same `toggle_switch_summary` (`lib/toggle.sh`) so the two
  cannot disagree (requirement 34a). Renders nothing when the node is
  enabled, and nothing when the field is absent (a peer's heartbeat from
  before this check existed) — the same absent-means-unknown rule the
  compose and image badges already follow, never a false "enabled" for a
  peer this node cannot actually answer for.

  It also renders nothing for a record tagged `scope: "fleet"` while the fleet
  flag is set: that record is the mirror a fleet-wide `--disable` leaves on the
  node that issued it, and badging it would single that node out of a fleet
  that is uniformly down. A mirror whose fleet flag has since been cleared is
  the exception and the reason the tag is worth carrying — it badges amber and
  says what it is, since that node is genuinely down alone and no banner on the
  page explains why. A record with no `scope` reads as `"node"`, matching
  `lib/toggle.sh`.
- **Blocked and void are shown as separate lists**, never merged into
  "items not being worked". They ask opposite things of the person reading:
  a blocked item may need them to clear its path; a void item needs nothing
  unless the verdict itself is wrong, and reopening one is a deliberate act
  only they can perform (appending `unvoided` to the log by hand — say so on
  the page, since it is the only escape hatch and it exists nowhere in the
  UI). Collapsing them costs the operator the one distinction the pipeline
  cannot make for itself.

  Separate lists means *separate*: an item holding both marks is void
  (implementation spec 34h) and belongs to the void list alone, which is why
  `blocked[]` is `open_blocked_items` and not `blocked_items`. It is not a
  corner case. `item-void` clears no block, so every `void` verdict the Enabler
  reaches — its ordinary way of retiring work that turned out to be already
  done — leaves the `attempt-failed` before it standing, and the page listed the
  item in both tables from then on. On the fleet that found this, fifteen of the
  sixteen rows under "Blocked items" were items the pipeline had already
  finished with, the oldest of them a fortnight dead, and the panel that exists
  to say *the pipeline is stuck on these* was reporting a backlog that had been
  cleared. The heading's count is the part that misleads fastest: it is read at
  a glance, by someone deciding whether to intervene at all.

  **The void list is capped and the blocked list is not**, for the same reason
  they are separate. Void is the page's one unbounded list of work nobody need
  act on: rows only accumulate — a hand-appended `unvoided` is the sole way one
  leaves — while the panels that do want an answer sit below it, so left whole
  it eventually pushes failed cycles and the work sources off the screen with a
  list whose entire message is "nothing to do here". Blocked is the opposite
  and is never capped: hiding a row there hides work. So void shows its ten
  newest rows, each clipped to three lines, and both caps open where they are —
  a `See more` at the foot of the table, any row expanding to its full text on
  a click — because the Enabler's reason *is* the row, and a truncation that
  could not be undone would leave the one question a void item ever raises
  ("is this verdict right?") unanswerable on the page. The heading keeps
  counting every void item rather than the rows shown, so the number read at a
  glance stays the fleet's.

  Ordering is part of that cap, not a nicety beside it: `void_items` groups by
  repo and item, so a cap over the list as it arrives keeps whichever ids sort
  first, which answers no question anyone has. The page sorts newest-first
  before slicing, making the kept rows the ten most recent verdicts — the ones
  a mistaken void is most likely to be among, and the only ones whose `Since`
  column then reads in order.

  The blocked list then makes one further distinction *within* itself, in its
  `Escalated` column: an item waiting on a human through an open issue, versus
  one still the pipeline's own to clear. That column is a link when the Enabler
  has raised an escalation (implementation spec 36a) and the Enabler's last
  verdict otherwise, because those are two quite different messages to the
  reader — "nothing will happen here until you act" and "the pipeline looked at
  this properly and is still working on it". Before it, both rendered as an
  identical row of prose, and the one item on the page that had been *addressed
  to the operator* looked exactly like the four that had not. The link is
  deliberately the escalation issue rather than a copy of its text: the issue is
  where the ask is maintained, and closing it is the whole protocol.

  A blocked row also carries `kind` (implementation spec 34e), and a row whose
  `kind` is `needs-refinement` gets a **refinement** badge and counts toward a
  "hide N refinement blocks" filter beside the panel's heading (TD26072603). An
  ordinary block is waiting on the world — a merge, a fix, an answer already
  asked for — and the Co-Ordinator is expected to clear it once that changes. A
  refinement block is waiting on the pipeline's own Enabler and, past one
  refinement, on a human: reading "blocked: 9" with no way to tell the two
  populations apart understates how much of the backlog is a specification gap
  rather than a stalled merge. The filter defaults to showing both — hiding is
  an explicit, per-session choice, never the page's default view — because the
  count in the heading is itself information ("that many things need
  attention"), and defaulting to hidden would bury exactly the population this
  change exists to surface.
- **The live indicator says what, not just that.** The header's running dot
  once reported only that a cycle was in flight and since when; the item it was
  working on lived several panels down, in the cycles table. But "what is the
  pipeline doing right now?" is the exact question a glance at the header is
  for, and making the operator scroll to answer it defeats the point of having a
  live indicator at all. So the running state now carries `status.current` — the
  live stage and the selected work — rendered inline beside the dot, reusing the
  same source-tag vocabulary as the cycles column so the two read as one thing.
  It is *derived, not newly logged*: the id/pid tie between the lock and the
  running cycle's events is enough to reconstruct it from state already on disk,
  so the reader gains the answer without the pipeline emitting anything new or
  the Publisher making an extra call. The fields appear in the order the cycle
  learns them — stage first, then repo/item/title once the Co-Ordinator selects
  — which doubles as a coarse progress read: a header stuck on `coordinator`
  with no item is a cycle still choosing; one naming an item under `implementer`
  is a cycle at work.
- **With a fleet, "what is it doing" has one answer per node, so it is asked per
  node.** The readout above was designed when a node and the pipeline were the
  same thing, and it sat in the header because there was one of it. Once several
  containers run at once, a single header readout has to pick one node's work to
  stand for every node's — and whichever it picks, the reading a glance takes
  from it ("the pipeline is on TD26071401") is false. So the live state moved
  down to the fleet strip, one full readout per card, beside the identity and
  freshness that say whose it is; the header keeps the shape of the question it
  can still answer for the whole fleet — *how much of it is working* — and drops
  the part it cannot. A single-node page is unchanged, header detail included:
  with one node there is nothing to summarise, and the fleet strip does not
  render at all.

  Three things follow from a peer's state being *derived from its published log*
  rather than observed. Its card is dated ("as of its last push, 2m ago") rather
  than presented as now. A peer whose heartbeat has gone stale reports **state
  unknown** instead of last half-hour's news dressed as current — the one
  reading that would be actively misleading. And a cycle still "running" past
  `lock_stale_after` is flagged as possibly dead, because a node killed
  mid-cycle leaves precisely the trace of one still working: a `cycle-start`
  with no end, for ever. Our own row is exempt from all three — the lock is a
  live pid, not an inference — but it gets the mirror-image case: a dead lock
  over an unfinished cycle is reported as **no clean end**, which is what a
  stopped container leaves behind and which "idle" would quietly
  absorb.

  A fourth reaches the same verdict far sooner, and is the one that fires in
  practice. A stage still live past its own backstop has outlived the timer
  that would have killed it, so the cycle is over whatever the log says; a
  Co-Ordinator is bounded in tens of minutes where `lock_stale_after` is
  several hours, and a node rolled mid-cycle sat in that gap reading
  "coordinator choosing work". The cap it is held against is the one that
  stage was given, announced on its own `stage-start` (requirement 4f), so the
  rule follows a backstop that moves without needing to be told. Judged against the node's own heartbeat, never the reader's clock, so
  the verdict is about what that node published and not about how long ago it
  published it. Our own row is **not** exempt from this one, unlike the three
  above: a live pid proves the cycle script is alive, not that the stage it
  last logged still is — and were that script alive, its own timer would have
  ended the stage.
- **The page refreshes its data in place, not by reloading.** The heartbeat
  once published every 5 minutes and the page reloaded itself every 60s with
  `location.reload()`. When the heartbeat moved to ~5s
  (`publish-dashboard-launcher.sh`), a full reload every few seconds was
  unusable: it collapsed every expanded cycle row, closed open transcripts,
  flashed the screen and snapped scroll to the top. So the one-shot render was
  made re-runnable and the refresh now re-fetches `data.js` and re-renders in
  place. Two properties keep that cheap and non-disruptive. It re-renders
  **only when the data actually changed** — comparing a signature that omits
  `generated_at` (which moves every publish) — so an idle pipeline's open tabs
  sit perfectly still. And the fetch is an **injected cache-busted `<script>`,
  not `fetch()`**, so the page keeps loading from a `file://` URL with no
  server and no CORS — the same reason the initial load uses a plain
  `<script src>`. Expanded rows, open `<details>` and scroll position are
  carried across the re-render in two small keyed maps. One deliberate
  consequence of only-on-change: the relative "3m ago" cells stop advancing
  while the pipeline is idle and catch up the moment new data lands — the
  header's own staleness clock keeps ticking, so freshness is never in doubt.
- **The dequeued warning is the Publisher's own memory, not GitHub's timeline**
  (agent-ops#375, D17). The obvious first design reads `merge_queue_probe`'s
  `dequeued_at`/`dequeue_reason` straight through — the same fields
  `scripts/sweep-human-visibility.sh` already posts a notice from — but that
  field answers "when did this pull request last leave the queue", not "does
  it need a human's attention right now", and the two come apart exactly the
  way agent-ops#394 found against the sweep's own use of it: the timeline
  read fires on a removal from arbitrarily long ago, even after a later
  re-queue, because nothing in it says "and nothing has changed since". A
  dashboard badge that could relight itself off ancient history is worse than
  none, so instead the Publisher keeps its own `{queued, warn}` per pull
  request across ticks (`<state_dir>/.dashboard-queue.json`) and derives
  `dequeued` from the transition it itself observes — `warn` sets the tick
  `queued` flips `true` → `false`, holds while it keeps reading `false`, and
  clears the moment `queued` reads `true` again. That is strictly a
  comparison this Publisher can make about *this* pull request's *current*
  state, never a re-reading of a GitHub event that predates the question.
