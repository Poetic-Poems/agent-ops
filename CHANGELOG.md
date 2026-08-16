# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Every `item-void` a Co-Ordinator, Enabler or Implementor
  writes must now cite evidence in one of two checkable forms — a structured
  `{ref, path, expect, pattern}` shape, or a PR/commit citation naming the
  item — or, for a finishing-source item, corroborate directly against its
  own pull request's live state; prose citing neither is refused rather than
  accepted on being merely non-empty (issue #413, WI-10). Also adds a
  machine-checkable alternative to the human `obsolete` label: at
  `merge_autonomy_effective_level` `agent-merges-all`, an Enabler's
  `flag_obsolete` verdict on a stalled draft can be corroborated by a later,
  independent Enabler engagement's own void, at least 24 hours apart, both
  citing structured evidence. `unvoided` is untouched and gains no machine
  path.
- **Breaking:** `config.json`'s `review` block is renamed `project_review` and
  restructured: every tunable now lives under `project_review.defaults`
  (installation-wide) and may be overridden per repository on
  `project_review.repos[]` — each entry `{"slug": "owner/name", ...}` — rather
  than the old flat, installation-wide-only block. An installation with its
  own `config.json` outside this fleet must migrate its `review` block to the
  new shape before upgrading; see `docs/REVIEW-PIPELINE-SPEC.md`'s
  Configuration section for the resolution rule and an example.
