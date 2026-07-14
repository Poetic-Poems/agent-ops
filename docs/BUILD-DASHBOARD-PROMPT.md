# Monitoring dashboard — build & maintenance spec

Companion to `docs/BUILD-PROMPT.md` (the pipeline spec). This document
describes the local monitoring dashboard **as built**: what it is, the state
it reads, how it is assembled, and the decisions behind it. Use it to
understand, modify, or regenerate the dashboard. Where it says "requirement
N", it means requirement N of `docs/BUILD-PROMPT.md`.

## What it is

A single-page dashboard for watching and debugging the autonomous agent
pipeline: current status, usage-limit stand-downs, open agent PRs and their
CI, recent cycles with per-stage cost/duration/model, failures and blocked
items, the work sources the Co-Ordinator sees, spend by day and by model, the
raw log, and each stage's transcript inline.

Three properties are deliberate and non-negotiable:

- **Local and private.** Nothing is published anywhere. The site is generated
  onto local disk and opened in a browser. There is no server and no open
  port (an optional loopback-only server exists purely as a `file://`
  fallback), and no GitHub Pages. The pipeline's operational telemetry —
  costs, cadence, failure detail, agent reasoning — never leaves the machine.
- **Free to run.** The generator is `bash` + `jq` + `gh` on the existing cron
  cadence; the page is a static file; there are **no model calls anywhere**.
- **A reader, never a participant.** It only reads the pipeline's state and
  GitHub. It never writes into the state tree, never touches the lock, and
  cannot slow or disturb a running cycle. It redacts home paths and
  token-shaped strings so a screenshot is safe to share.

## Architecture

```
pipeline state (this machine)            GitHub (public repos, via gh)
  ~/.local/state/poetic-agents/            open agent PRs + checks,
    log.jsonl, cycles/<id>/*.out,          failed runs, issues, tech-debt
    lock.json, cron.log
        │                                        │
        └────────────┬───────────────────────────┘
                     ▼
        scripts/publish-dashboard.sh   (the Publisher)
          → <state_dir>/dashboard/data.js   (redacted JSON, generated)
          → <state_dir>/dashboard/index.html (copied from repo)
                     │
                     ▼
        open index.html in a browser  (file://, no server)

Refresh triggers:  end-of-cycle hook in agent-cycle.sh  +  */5 cron heartbeat
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
  semantics (most recent `attempt-failed`/`unblocked` per `repo`+`item`).
- **`cycles/<cycle-id>/<stage>.out`** — the `claude --output-format json`
  envelope (requirement 11). Fields used: `result` (final message → parsed
  into the work order / status object via the same straight-parse-else-last-
  fenced-```json``` block that `agent-cycle.sh` uses), `total_cost_usd`,
  `duration_ms`, `num_turns`, `is_error`, `terminal_reason`/`stop_reason`,
  `modelUsage` (→ model id). `<stage>.out.stderr` is shown for debugging.
  Missing/partial files degrade to a null stage — never a crash.
- **`lock.json`** — `{pid, started_at}`. A live pid (`kill -0`) means a cycle
  is running now.
- **`cron.log`** — tail shown, for "cron fired but nothing happened".
- **GitHub, via `gh`** (best-effort; the machine is authenticated and the
  repos are public): open PRs carrying `pr_label` with `statusCheckRollup`,
  `mergeable`, `mergeStateStatus`, draft/ready; most-recent-per-workflow
  failing runs on the default branch; open issues; the `TECH-DEBT.md` ledger
  rows. If `gh` fails, the GitHub panels mark themselves stale and the rest
  still renders.

**Usage-limit detection.** The pipeline's own detector only recognises
ISO-timestamp resets, so weekly-limit messages ("resets Jul 17, 4am …") slip
past it and are never logged as `limit-hit`. The Publisher therefore also
scans recent transcripts for limit phrasing and surfaces it directly, so the
dashboard shows a stand-down the log itself missed.

## The Publisher (`scripts/publish-dashboard.sh`)

Reads the state above, assembles one JSON object, redacts it, and writes it
as `window.DASHBOARD_DATA = {…}` to `data.js` (atomically: temp file + `mv`).
It is `set -uo pipefail` (not `-e`) because most reads are best-effort, and
ends `exit 0`. It sets its own `PATH` for cron and is `shellcheck`-clean.
`--no-github` skips the live GitHub fetch for a faster, offline run.

Redaction is unconditional: `/home/<user>` and `/Users/<user>` → `~`, and
`ghp_/gho_/github_pat_/sk-…/Bearer …` token shapes → `[REDACTED-TOKEN]`,
applied to the whole serialised payload before writing.

The `DASHBOARD_DATA` shape (the contract the page renders):

```
{ generated_at, max_open_agent_prs,
  config:  { models, timeouts, pr_label, branch_prefix, repos, … },
  status:  { running, lock:{pid,started_at,alive}, last_cycle, limit:{active,note} },
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
  github:  { ok, error, fetched_at, prs[], inputs:{<slug>:{issues,failed_runs,tech_debt}} },
  log_tail:  [ … ],                    // recent events, newest first
  cron_tail: [ "line", … ] }
```

## The Site (`dashboard/index.html`)

One self-contained file: inline CSS + vanilla JS, no framework, no build step,
no external network requests (works fully offline). Renders from
`window.DASHBOARD_DATA`; every panel handles missing data gracefully.
Theme-aware (light/dark via `prefers-color-scheme`); wide tables scroll
inside their own container. Auto-refreshes every 60s via `location.reload()`
(which re-reads the freshly generated `data.js`); the header shows how stale
the data is and warns if the heartbeat looks stopped.

Panels: status header + usage-limit / failing-checks / gh-down banners;
metric cards (spend today/total, failures, reached-ready, back-pressure gauge
vs `max_open_agent_prs`); open PRs; recent cycles (click a row for per-stage
detail with the parsed status, full transcript, and stderr); failures &
blocked items; work sources per repo; spend-by-day and spend-by-model bars;
recent log; `cron.log` tail.

## Integration

- **End-of-cycle hook** — `agent-cycle.sh`'s cleanup runs the Publisher as
  `timeout 120 … >/dev/null 2>&1 || true`: failure-isolated and time-bounded,
  so it can never change the cycle's outcome, exit code, or timing. It is the
  only change to `agent-cycle.sh`. (Never edit `agent-cycle.sh` while a cycle
  is running — editing a running bash script shifts byte offsets and corrupts
  the live process; wait for the lock to clear first.)
- **Heartbeat** — an optional `*/5 * * * *` crontab entry running the
  Publisher keeps in-flight state, the lock, and live GitHub current between
  hourly cycles.

## Deliverables (as built)

- `scripts/publish-dashboard.sh` — the Publisher.
- `dashboard/index.html` — the page (committed source; copied beside the
  generated `data.js` at publish time).
- `scripts/open-dashboard.sh` — regenerate + open in the browser.
- `scripts/serve-dashboard.sh` — optional loopback-only server (`file://`
  fallback).
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
- **The page fetches nothing external.** All GitHub reads happen in the
  Publisher via `gh`; the page reads only its local `data.js`. Offline-capable,
  dependency-free, no CORS or rate-limit concerns.
- **Redaction is unconditional** even though the data is local, so a
  screenshot or copied file is safe and a future private repo can't leak.
- **Limit detection is independent of the log**, because the pipeline's logger
  misses weekly-limit phrasing — the dashboard reads the transcripts directly.
