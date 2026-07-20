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
void items, the work sources the Co-Ordinator sees, spend by day and by
model, the raw log, and each stage's transcript inline.

Three properties are deliberate and non-negotiable:

- **Local and private.** Nothing is published anywhere. The site is generated
  onto local disk and opened in a browser. There is no server and no open
  port (an optional loopback-only server exists purely as a `file://`
  fallback), and no GitHub Pages. The pipeline's operational telemetry —
  costs, cadence, failure detail, agent reasoning — never leaves the machine
  except, when the optional tailnet access documented in the README is
  installed, to the owner's own signed-in devices: `tailscale serve` proxies
  the unchanged loopback server over the owner's private tailnet, and
  nothing ever gets a public URL.
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

All paths derive from `config.json` (tilde-expanded `state_dir`), read the
same way `agent-cycle.sh` reads them.

- **`log.jsonl`** — the event stream (requirement 33). Parsed line-by-line
  with `fromjson? // empty` so a half-written trailing line (the Script may be
  appending) never aborts the parse. Blocked items use requirement 34's
  semantics (most recent `attempt-failed`/`unblocked` per `repo`+`item`); void
  items use requirement 34c's (most recent `item-void`/`unvoided`). Both come
  from the shared library, never from a local copy of the rule.
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

  `total_cost_usd` is a **local estimate computed from token counts**, priced
  as though the tokens had been billed per-token through the API. Under the
  subscription auth this pipeline runs on, it is not an amount charged and not
  a draw against any plan limit — it measures work done, not money spent. The
  envelope carries no quota, rate-limit, or credits-remaining field of any
  kind; do not expect one to appear here. See the design decision on plan
  limits below before building anything that treats these dollars as budget.
  Missing/partial files degrade to a null stage — never a crash.
- **`lock.json`** — `{pid, started_at}`. A live pid (`kill -0`) means a cycle
  is running now. The cycle id is `<started>-<pid>` and the lock carries that
  same pid, so the running cycle's own events are exactly those whose id ends in
  `-<pid>`. From them the Publisher derives `status.current` — what the live
  cycle is working on right now: the running stage (the last `stage-start` with
  no matching `stage-end`) and the item the Co-Ordinator selected
  (`repo`/`item`/`source`/`title`). It is `null` when idle, and its fields fill
  in as the cycle progresses — `repo`/`item`/`title` appear only once selection
  has happened, since the Co-Ordinator stage runs before it has chosen anything.
- **`cron.log`** — tail shown, for "cron fired but nothing happened".
- **GitHub, via `gh`** (best-effort; the machine is authenticated and the
  repos are public): open PRs carrying `pr_label` with `statusCheckRollup`,
  `mergeable`, `mergeStateStatus`, draft/ready; most-recent-per-workflow
  failing runs on the default branch; open issues; the `TECH-DEBT.md` ledger
  rows. If `gh` fails, the GitHub panels mark themselves stale and the rest
  still renders. On a `--no-github` refresh the fetch is skipped entirely and
  the last successful result is carried forward (see the Publisher below), so
  only a fetch that was *attempted and failed* ever shows as unavailable.

**Usage-limit detection.** The pipeline's own detector and the Publisher share
one phrase pattern and reset-time parser (`lib/limit-detect.sh`), so a
weekly-limit message ("resets Jul 17, 4am …") or a monthly spend-cap message
now gets logged as `limit-hit` by the Script itself, not just spotted by the
dashboard. The Publisher still also scans recent transcripts for limit
phrasing directly, as a backstop for any cycle where a `limit-hit` never made
it into the log for some other reason (a crash before `log_event` ran, or a
cycle from before this detector existed) — so the dashboard can still show a
stand-down the log itself missed.

## The Publisher (`scripts/publish-dashboard.sh`)

Reads the state above, assembles one JSON object, redacts it, and writes it
as `window.DASHBOARD_DATA = {…}` to `data.js` (atomically: temp file + `mv`).
It is `set -uo pipefail` (not `-e`) because most reads are best-effort, and
ends `exit 0`. It sets its own `PATH` for cron and is `shellcheck`-clean.
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
  config:  { models, timeouts, pr_label, branch_prefix, repos, … },
  status:  { running, lock:{pid,started_at,alive},
             current:{stage,repo,item,source,title}, last_cycle, limit:{active,note} },
  counts:  { cycles_shown, failures_shown, prs_reached_ready,
             spend_today_usd, spend_total_usd, by_day[], by_model[] },
  cycles:  [ { id, started_at, ended_at, outcome, repo, item, source, title,
               pr_url, reason, fail_detail, warning, total_cost_usd, limit_hit,
               stages:{ coordinator|implementor|reviewer:
                        { ran, cost_usd, duration_ms, num_turns, is_error,
                          terminal_reason, model, status, result, stderr,
                          limit_hit, limit_text } },
               events[] } ],           // most recent 40, newest first
  blocked: [ { repo, item, ts, detail, stage } ],
  void:    [ { repo, item, ts, detail, stage, evidence } ],
  github:  { ok, error, fetched_at, stale, prs[], inputs:{<slug>:{issues,failed_runs,tech_debt}} },
  log_tail:  [ … ],                    // recent events, newest first
  cron_tail: [ "line", … ] }
```

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

Panels: status header (running/idle, and while a cycle runs the stage, repo,
work source and item it is working on) + disabled / usage-limit /
failing-checks / gh-down banners (the switch first: when it is set, every other quiet signal on the page
is a consequence of it rather than news, and an operator reading them in the
other order goes looking for a fault that isn't there);
metric cards (spend today/total, failures, reached-ready, back-pressure gauge
vs `max_open_agent_prs`); open PRs; recent cycles (outcome and work source at
a glance; click a row for per-stage detail with the parsed status, full
transcript, and stderr); failures,
blocked and void items; work sources per repo (including the security and
code-quality findings, shown first, that the Co-Ordinator prioritises);
spend-by-day and spend-by-model bars; recent log; `cron.log` tail.

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
  every tick. A full GitHub-hitting publish runs only once per window (at the
  top); the cheaper `--no-github` publish runs in between and carries the last
  fetch forward, so the page stays near-live without hammering the GitHub API.
  `flock` guards against a slow publish stacking up under the next tick.

## Components (as built)

- `scripts/publish-dashboard.sh` — the Publisher.
- `scripts/publish-dashboard-launcher.sh` — the sub-minute heartbeat driver
  (cron runs it every 5 min; it self-loops on 5-second boundaries).
- `dashboard/index.html` — the page (committed source; copied beside the
  generated `data.js` at publish time).
- `scripts/open-dashboard.sh` — regenerate + open in the browser.
- `scripts/serve-dashboard.sh` — optional loopback-only server (`file://`
  fallback). It writes no log of its own: whatever supervises it captures its
  output — a container runtime keeps it in the service's logs, and on the
  legacy WSL path the init script redirects it (below). Its `127.0.0.1` bind is
  a requirement, not an accident, and it constrains how a container may expose
  it: publishing a port to a container whose server binds loopback reaches
  nothing, so both container profiles in `deploy/docker/compose.yaml` arrange
  access around the bind rather than widening it — the `tailnet` profile puts
  the server in the Tailscale sidecar's network namespace so Serve can proxy to
  its loopback (`ts-serve.json`, no Funnel), and the `local` profile puts it in
  the host's namespace so the page answers on that host's loopback and nowhere
  else. `deploy/agent-ops-dashboard.init` (the legacy WSL SysV path) sends
  that output to `<state_dir>/dashboard-server.log`, so every artefact the
  dashboard produces lands under `state_dir` and nothing is written beside the
  checkout. All of its settings (`RUNAS`, `RUNHOME`, `APPDIR`, `PORT`,
  `PIDFILE`, `LOGFILE`) are defaults overridable from
  `/etc/default/agent-ops-dashboard`, so the script carries no host-specific
  path that must be edited in place.
- The cleanup hook in `agent-cycle.sh`; a `.gitignore` entry for
  `dashboard/data.js`; the README "Monitoring dashboard" section.

## Verifying a change

- `shellcheck scripts/*.sh agent-cycle.sh` clean.
- `scripts/publish-dashboard.sh` against the real `state_dir` produces valid
  JSON (`data.js` minus the wrapper passes `jq empty`), and `grep` finds no
  `/home/…` path or token in the output.
- Open the page and confirm the panels populate: a failed cycle appears under
  Failures, and its transcript + stderr open inline.
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
- **Distinct classes of data are distinguished by shape, not colour alone.**
  Source tags are outlined and square; outcome badges are filled pills. Both
  are colour-coded, and the two sit side by side, so without the shape
  difference "Failed" and `security` would read as the same kind of label in
  the same red. Colour then carries identity *within* a class, shape carries
  the class itself — which is also the only reason eight source colours are
  legible at all: eight hues is past what hue alone reliably separates,
  especially for a colour-blind reader. Any future class of badge on this page
  should take a third shape rather than a ninth hue.
- **The source label/colour map is display-only, and fails open.** The
  vocabulary itself belongs to the Co-Ordinator (`prompts/coordinator.md`'s
  `sources` list) — the page cannot share that definition the way it shares
  the blocked/void rule above, because `data.js` carries only whatever token
  the pipeline already emitted. So the map styles tokens; it never decides
  them. An unrecognised source renders in grey with its raw token, never
  dropped and never silently blank: a source added upstream then shows up
  unstyled, which is a prompt to add a colour, rather than invisibly missing
  from the mix — the one thing the column exists to show.
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
- **Blocked and void are shown as separate lists**, never merged into
  "items not being worked". They ask opposite things of the person reading:
  a blocked item may need them to clear its path; a void item needs nothing
  unless the verdict itself is wrong, and reopening one is a deliberate act
  only they can perform (appending `unvoided` to the log by hand — say so on
  the page, since it is the only escape hatch and it exists nowhere in the
  UI). Collapsing them costs the operator the one distinction the pipeline
  cannot make for itself.
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
