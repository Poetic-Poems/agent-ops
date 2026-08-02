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
  semantics (most recent `attempt-failed`/`unblocked` per `repo`+`item`); void
  items use requirement 34c's (most recent `item-void`/`unvoided`). Both come
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
  entry ({node, role, heartbeat, last cycle, version, compose, image}; older than 30
  minutes → `stale: true` — three missed pushes, not clock jitter); its
  `cycles/<id>/`
  and `reviews/<id>/` transcripts
  render peer cycles with exactly the fidelity of local ones, and its `.out`
  envelopes join the fleet-wide cost roll-ups (every node spends one Claude
  account, so per-node spend would be the misleading number). The merged cycle
  detail list is capped at `MAX_CYCLES` *fleet-wide*, newest first across all
  nodes — that cap is what holds `data.js` near its single-node size however
  many nodes report. An id that exists on disk always renders from the owning
  node's directory (the D-before-E source ranking in the Publisher); an id
  known only from events renders from its events alone.

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
  lock over) is flagged as possibly dead. A second, far earlier bound catches
  the case that actually happens. Every stage is capped by its own `timeout_*`,
  which `run_claude_stage` enforces by killing the process group and logging
  `stage-end` after — so a live stage older than its cap is not a slow stage but
  one whose process is already gone, and the page says so in minutes where
  `lock_stale_after` takes hours. A Co-Ordinator is capped at 15 minutes against
  that rule's 4, which is the whole of the gap: a node rolled mid-cycle read as
  "coordinator choosing work" for most of the way to its next cycle. Both bounds
  are measured to the node's own heartbeat rather than to the reader's clock —
  what is known is what that node had published, and both timestamps are stamped
  by its clock, so the difference carries no skew between machines.
  `live.stage_since` is what makes this answerable, and `timeout_coordinator` /
  `_implementor` / `_reviewer` / `_enabler` reach the page in `config` for it. A
  stage with no configured timeout (the review pipeline's) is one the rule makes
  no claim about.
- **`fleet-cache/{disabled,limit}.json`** — the fleet flags' cached copies
  (requirement 2.3a), maintained by `lib/toggle.sh` and refreshed by this
  Publisher's own GitHub tick. Read as plain files, so a `--no-github` tick and
  a standby node surface them with no API call. Surfaced as `fleet.flags` and
  rendered as banners: the fleet switch (suppressed when the local switch
  banner already covers it — the setting node writes both levels), and the
  fleet-wide usage-limit stand-down (shown when the local log union has not
  caught up — a standby with no state yet, or a hit seconds old elsewhere).
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
  who set it, and its expiry (or that it has none and needs `--enable`), since
  those are precisely the questions an operator has next.
- **`cycles/<cycle-id>/<stage>.out`** — the `claude --output-format json`
  envelope (requirement 11). Fields used: `result` (final message → parsed
  into the work order / status object via the same straight-parse-else-last-
  fenced-```json``` block that `agent-cycle.sh` uses), `total_cost_usd`,
  `duration_ms`, `num_turns`, `is_error`, `terminal_reason`/`stop_reason`,
  `modelUsage` (→ model id). `<stage>.out.stderr` is shown for debugging.
  `docs/METERING-SCHEMA.md` is the formal contract for these fields — types,
  units, and what change to them is additive versus breaking — reused
  unchanged by the per-stage record `lib/metering.sh` writes to `log.jsonl`
  (requirement 33a); this reader and that one derive the same figures
  independently from the same envelope and are expected to agree.

  The **actor** that spent it is the transcript's own filename, and needs no
  new field: `cycles/<id>/{coordinator,implementor,reviewer,enabler}.out` name
  themselves, and `reviews/<id>/reviewer-<repo>.out` is normalised to
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
  draft/ready; most-recent-per-workflow
  failing runs on the default branch; open issues, each with the `Priority`
  band the Co-Ordinator ranks it by (read from the REST issues listing's
  `issue_field_values`, since `gh issue list --json` cannot see issue fields,
  and defaulted to `Medium` exactly as the pipeline defaults it — see the
  implementation-pipeline spec, requirement 15e); the tech-debt register's
  unresolved items — one listing read of `contents/tech-debt` for the roster
  and each item's blob SHA, then that item's own `title` and `status` out of
  its frontmatter, capped at 40 (`{id, title, status, url}`; an ID names no
  work, and a mature register is mostly resolved items the Co-Ordinator will
  never pick up, so those are dropped here — a repo with no register just 404s
  to an empty list); and one record per pull request the page
  refers to (`github.pr_index`, keyed `<owner>/<repo>#<number>`) — the open
  ones from the query above, the rest by `gh pr view`, cached permanently
  once terminal (see the Publisher). If `gh` fails, the GitHub panels mark
  themselves stale and the rest still renders. On a `--no-github` refresh the
  fetch is skipped entirely and the last successful result is carried forward
  (see the Publisher below), so only a fetch that was *attempted and failed*
  ever shows as unavailable.

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
cycle's day derived from `input_filename`; a torn mid-write envelope costs at
most the rest of its batch for one tick), the detail window (the `MAX_CYCLES`
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
             limit:{active,note}, switch:{…} },
  counts:  { cycles_shown, failures_shown, prs_reached_ready,   // fleet-wide
             spend_today_usd, spend_total_usd,
             by_day[], by_model[], by_actor[] },   // both pipelines' actors
  cycles:  [ { id, node, started_at, ended_at, outcome, repo, item, source, title,
               pr_url, reason, fail_detail, warning, total_cost_usd, limit_hit,
               stages:{ coordinator|implementor|reviewer:
                        { ran, cost_usd, duration_ms, num_turns, is_error,
                          terminal_reason, model, status, result, stderr,
                          limit_hit, limit_text } },
               events[] } ],           // most recent 40 FLEET-WIDE, newest first
                                       //   ids of the cycle shape only — a
                                       //   hand-appended record is not a cycle
  blocked: [ { repo, item, ts, detail, stage,           // from the log union
               kind,                                    // "" ordinarily, "needs-refinement" for a
                                                         //   refinement block (implementation spec 34e)
               escalation_issue, escalation_url,        // an open ask of the human
               enabler_outcome, enabler_ts } ],         //   … or the last verdict
  void:    [ { repo, item, ts, detail, stage, evidence } ],
  github:  { ok, error, fetched_at, stale, prs[], claims[],
             inputs:{<slug>:{issues, failed_runs, findings,
                             tech_debt:[{id,title,status,url}]}},  // unresolved
                                       //   items only; title/status empty
                                       //   until the item file has been read
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
                         live: { cycle, since, running, ended_at,
                                 stage, repo, item, source, title } } ],
                                            // what THAT node is doing; null
                                            //   until it has run a cycle
             flags:  { disabled, limit },               // cached fleet flags (2.3a)
             claims: [ { repo, key, kind, node, cycle, item, source, ts, sha } ] },
  log_tail:  [ … ],                    // recent events, newest first, fleet-wide
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
open transcript panels and scroll position survive the re-render; the header's
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
or whose state has gone stale) + disabled / fleet-switch / usage-limit
/ fleet-limit / failing-checks / gh-down / stale-peer banners (the switch
first: when it is set, every other quiet signal on the page
is a consequence of it rather than news, and an operator reading them in the
other order goes looking for a fault that isn't there);
**the fleet strip** — one card per node carrying that node's own live state
(name, role, running/idle, the stage, repo, work source and item in flight and
since when — or, when idle, when its last cycle ended and how it went — the
**version it is running** as `image #<pr> <short-sha> · built <age>` with the
pull request carrying its record card, a grey `behind` marker when the fleet
holds a newer build and an amber `modified` one on a checkout with uncommitted
work, and how
fresh that answer is: read live for our own row, "as of its last push" for a
peer); stale peers bordered red and reported as state unknown; click a card to
filter the cycle list to that node, click again to clear — the filter survives
refreshes like every other UI state; **live claims** — the registry rows, i.e.
work no other node will pick up. Both, plus the cycles table's Node column,
appear only once the fleet has more than one node (or a claim exists): a
single-node page renders exactly as it always did.

The strip is rebuilt on every refresh tick alongside the header, not only when
the body re-renders, because its cards carry running clocks ("since 18m ago")
and the body deliberately sits still while the data is unchanged.
Then metric cards (spend today/total — fleet-wide, one shared account —
failures, reached-ready, back-pressure gauge
vs `max_open_agent_prs`); open PRs; recent cycles (outcome and work source at
a glance — a cycle that has not logged `cycle-end` shows the state it is in
rather than an outcome it has not reached: **in progress** while a node claims
it as its live cycle (greyed when that node's own report has gone stale,
amber and questioned once it is running past `lock_stale_after`), **no clean
end** when no node is running it, and **not ended** when the data carries no
node state to ask; click a row for per-stage detail with
the parsed status, full transcript, and stderr); failures,
blocked and void items; work sources per repo (including the security and
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
the cost charts — by-day on the left, by-model and by-actor stacked beside it,
since the first runs to sixty rows and the other two to five; recent log;
`cron.log` tail.

The **recent log** is the newest 80 events, one row each: time, the event as a
badge, **Node / Repo / Actor**, and the event's own detail. Those three are
different kinds of answer to "where did this happen" — which machine ran it,
which repository it was aimed at, which agent was acting — so they are three
fixed slots read positionally, each carrying a dash when the event does not
answer it: the middle token is the repository whether or not the other two are
known. The actor is derived rather than logged, because no event carries an
`actor` field and each pipeline already records it somewhere else: the
implementation pipeline's `stage`; `handoff` on `pr-ready`, naming which actor
took the pull request out of draft; `by` on `unblocked` (and on that event
only — `by` elsewhere names a *person*, who set the switch or cleared a
stand-down); the Enabler's own `escalated`, `enabler-examined` and
`item-refined`, which carry none of them. A review-pipeline event is the
Project Reviewer's, which is a different actor from the cycle Reviewer even
where the review pipeline writes `stage: "reviewer"` — the same distinction
the Publisher's cost scan draws from the transcript path, drawn the same way
so the two halves of the page cannot disagree about who did what. Steps with
no agent in them name none: the clone (`stage: "workspace"`) and a handoff the
Script completed itself (`handoff: "script"`), as do the cycle-level events
(`cycle-start`, `selection`, `cycle-end`, and the review pipeline's
lifecycle), which are the Script's records of a cycle's progress rather than
any agent's work. Like the source tags and the by-actor chart, this fails
open: a token the page has never heard of renders as itself, so an actor added
upstream shows up unlabelled rather than vanishing into a dash.

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
  matches the per-file semantics (day cut-off, torn-file tolerance) and the
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
  log tail. And with `cron.log` short and a `cron.log.1` beside it —
  `scripts/rotate-logs.sh` having just rotated — the cron panel's tail draws
  from both, oldest first, rather than going blank for the tick after a
  rotation.
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
  removed by the hide filter; the log tail's Node / Repo / Actor cell
  answers all three slots positionally — an actor read from `stage`, from `by`
  and from `handoff`, the review pipeline's named as the Project Reviewer, the
  clone step and the cycle-level events naming none, and a missing node
  keeping its slot rather than letting the repository slide into it. The
  per-repo `nice` badge is asserted from two fixtures, because both of its
  silences are load-bearing and neither is visible on the page that has them:
  a repo at `-5` carries a blue badge naming `×3.05` and earlier attention, one
  at `3` a grey badge naming `×0.51` and later, both disclaiming starvation,
  under a note naming the Script rather than the Co-Ordinator; a repo with no
  key beside them carries nothing; and a config whose repos are all `0` or
  keyless renders no badge and no note anywhere on the page. And a
  node behind an image published longer ago than `image_behind_grace_hours`
  carries an **image behind** badge naming the registry commit, while one
  whose registry check failed carries **image unverified** instead (#155).
  Out of scope by the same tree-building limit:
  the pull-request hover card's pointer/focus behaviour, covered only by the
  manual and headless checks below.
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
  `docs/IMPLEMENTATION-PIPELINE-SPEC.md`); only the projection for
  display is local. The dashboard originally had its own near-copy of the
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
  it has to be named for what it measures.
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
- **Blocked and void are shown as separate lists**, never merged into
  "items not being worked". They ask opposite things of the person reading:
  a blocked item may need them to clear its path; a void item needs nothing
  unless the verdict itself is wrong, and reopening one is a deliberate act
  only they can perform (appending `unvoided` to the log by hand — say so on
  the page, since it is the only escape hatch and it exists nowhere in the
  UI). Collapsing them costs the operator the one distinction the pipeline
  cannot make for itself.

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
  with no item is a cycle still choosing; one naming an item under `implementor`
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
  practice. A stage still live past its own `timeout_*` has outlived the timer
  that would have killed it, so the cycle is over whatever the log says; a
  Co-Ordinator is bounded at 15 minutes where `lock_stale_after` is 4 hours,
  and a node rolled mid-cycle sat in that gap reading "coordinator choosing
  work". Judged against the node's own heartbeat, never the reader's clock, so
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
