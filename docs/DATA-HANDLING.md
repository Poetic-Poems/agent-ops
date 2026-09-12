# Data handling

This document describes what data the agent-ops pipeline reads, stores, and retains.

## What the pipeline reads

The pipeline reads only public GitHub data for the configured repositories:

- **GitHub usernames** — issue/PR/comment/review authors
- **Issue and pull-request text** — bodies, comments, review text
- **Repository metadata** — branch names, tag names, collaborator access levels
- **Workflow and check information** — CI run results and logs, commit statuses

All of this data is already public on GitHub for public repositories. The pipeline
makes no attempts to read or use private repository data.

## What the pipeline stores and where

The pipeline stores operational telemetry under the configured `state_dir` directory
and its optional replicated mirror (configured separately). This telemetry includes:

- **Cycle logs** — per-cycle JSON event streams (one event per line) recording
  selections, stage handoffs, work item completions, and outcomes
- **Dashboard data** — aggregated metrics for the monitoring dashboard: cost by
  model, cost by actor, cost by day, stage durations, failure counts
- **Cycle transcripts** — per-stage text output and error logs for debugging

None of this data is published outside the installation. The pipeline runs entirely
locally, with no external service calls except to GitHub via the `gh` CLI. The only
exception is optional Tailscale integration: if `tailscale serve` is enabled, the
dashboard (and its underlying data files) are made available over the owner's
private tailnet to their own signed-in devices; nothing reaches a public or
third-party URL.

## Data retention

Data retention is governed by three configuration keys in `config.json`, documented
in [README.md](../README.md) in the Configuration section:

- **`cycles_retained`** — the number of recent complete cycles to retain in full
  (their logs and transcripts). Older cycles' logs are deleted. This does not affect
  cycle metadata (counts, costs, outcomes) used by the dashboard.

- **`state_local_cycles_retained`** — the number of recent cycles to retain in the
  optional replicated state copy (in addition to the primary state directory). When
  the replication mirror reaches this count, the oldest cycle's data is deleted from
  it, matching the age of data in the primary directory.

- **`log_retained_bytes`** — the maximum size (in bytes) of the pipeline's own
  consolidated event log (`log.jsonl`). When the log exceeds this size, the oldest
  entries are removed to stay within the limit.

Refer to the Configuration section of [README.md](../README.md) for the default
values and detailed explanations of each setting.

## Privacy and security considerations

- **Minimal scope.** The pipeline reads only the data it needs to select and track
  work. It does not fetch the whole repository tree or scan history beyond what
  the work selection process requires.
- **Local retention.** All data stays on disk locally; no telemetry or usage
  information is sent anywhere by default. The dashboard and logs are never
  uploaded or shared unless deliberately pushed to an external service by the
  operator (e.g., via `git` or a manual copy).
- **Redaction for screenshots.** The dashboard includes redaction logic to obscure
  home paths and token-shaped strings when saving a screenshot, so operational
  data can be safely shared for debugging without leaking credentials.

## Onboarding a new installation

Before deploying this pipeline to an installation that is not Poetic-Poems:

1. Review this document and the Configuration section in [README.md](../README.md)
   to understand what data will be retained and for how long.
2. Adjust `cycles_retained`, `state_local_cycles_retained`, and `log_retained_bytes`
   in `config.json` to match your retention and privacy requirements.
3. Ensure the machine running the pipeline has adequate disk space for the maximum
   configured retention period (see `log_retained_bytes` in particular).
4. If using a replication mirror, ensure the mirror location is on a trusted device
   with the same security properties as the primary state directory.
