# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `merge_budget_per_day` (D18 §5.4, requirement 2.3c): a rolling-24-hour cap,
  per repository, on pull requests this pipeline may land, with a `repos[]`
  override on the same precedence `merge_autonomy` uses. Default `8`, `0`
  unlimited. Landing more than the cap in a window — a counting anomaly a
  correct governor should never observe — freezes the repository's
  `merge_autonomy_effective_level` at `agent-approves` and escalates to that
  repository. `max_open_agent_prs`'s back-pressure exclusion is now level-
  aware: at `agent-merges-routine` and above, a ready pull request counts
  toward the cap even when it is not `CHANGES_REQUESTED`, since there is no
  human queue for it to be parked in at that level. This delivers the
  mechanism and its doctrine only — nothing yet calls it from a behaviour-
  affecting path, since no requirement arms an automatic landing today.

### Changed

- **Breaking:** `config.json`'s `review` block is renamed `project_review` and
  restructured: every tunable now lives under `project_review.defaults`
  (installation-wide) and may be overridden per repository on
  `project_review.repos[]` — each entry `{"slug": "owner/name", ...}` — rather
  than the old flat, installation-wide-only block. An installation with its
  own `config.json` outside this fleet must migrate its `review` block to the
  new shape before upgrading; see `docs/REVIEW-PIPELINE-SPEC.md`'s
  Configuration section for the resolution rule and an example.
