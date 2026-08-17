# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Priority triage (D18 WI-11, requirement 39g; agent-ops#414): the Refiner now
  bands every open issue whose `Priority` field is unset, so the owner never
  has to set it by hand. `gather-issues.sh` emits a new `priority_set`
  boolean alongside `priority`, an unbanded-but-already-refined issue is
  offered to the Refiner solely for its band (`triage_only: true`) — and a
  `needs-refinement` decline of such an item is refused rather than recorded,
  so banding an already-refined issue can never block it — and
  `lib/issue-priority.sh` enforces a one-way ratchet: a band is written only
  when the issue currently has none, or the Refiner's verdict strictly
  outranks the current one, re-read live immediately before writing.
  `scripts/doctor.sh` warns when a configured repository's `Priority` field
  cannot be resolved.
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

### Fixed

- `merge_budget_oldest_waiting`'s `waiting_backlog` (the pull request a
  `merge-budget-hold` event names as the one waiting longest) now sorts
  GitHub's own listing oldest-first before paging, so a repository with more
  than `GITHUB_PR_LIST_LIMIT` open, labelled pull requests names the true
  oldest rather than the oldest of whatever page happened to come back. Its
  search now also excludes drafts server-side (`draft:false`), so a
  repository whose oldest page is entirely drafts still names its true
  oldest non-draft instead of reporting no backlog at all.
- The per-process fleet-flag memo (issue #502) is now keyed by mode as well
  as by flag and `state_dir`, so a default-mode `clear` answer can never be
  served to a later `probe-404` read of the same flag, and reads it into a
  variable rather than testing-then-reading the memo file, so a file that
  vanishes or is empty mid-write falls through to a live fetch instead of
  being served as an (incorrectly) confirmed answer. `run_approver_stage`'s
  own read of the merge-autonomy kill switch now always bypasses the memo,
  so an operator's mid-cycle kill stops the stage at its own boundary rather
  than waiting for the next cycle's process to notice.
- `approver_escalate`'s "could not settle, and the escalation issue could not
  be filed" warning event now carries `pr_url` and a `detail` naming it — a
  pre-existing bug (a bash string interpolation, not the intended jq `--arg`)
  silently emptied both fields under `set -u`.
- The dashboard's switch banner for a node stood down with
  `agent-cycle.sh --this-node --disable` (issue #514) now reads "This node is
  disabled" rather than "Pipeline disabled" — the old wording read as a
  fleet-wide stand-down even though only the one node had stopped. Its
  re-enable advice now names `--enable --this-node` for a genuine node-scoped
  disable, rather than the bare `--enable` it shared with the fleet-wide
  banner and the orphaned-mirror case (agent-cycle.sh's own `--status` report
  and the fleet-strip badge already drew this distinction; the banner did
  not) — the bare command clears the fleet switch, not this node's own
  record, and would have left the node down after an operator followed it.
- The Priority triage ratchet (requirement 39g) no longer overwrites a band
  outside the four names it ranks (issue #509). `issue_priority_current` used
  to parse only `Urgent`/`High`/`Medium`/`Low`, so an organisation-added
  fifth option read back as no band at all and the ratchet's skip guard never
  fired; it now reads the raw option name, and `issue_priority_apply` skips
  such a band (`skipped-unrankable`, logged like any other ordinary skip)
  instead of silently replacing it. `gather-issues.sh`'s `priority_set` is
  now true whenever any option is set on the field, not only one of the four
  recognised names, so a fifth-band issue is no longer offered to the
  Refiner's triage duty as if nobody had triaged it.
- A repository whose `Priority` field this token cannot resolve at all no
  longer re-engages the Refiner forever for band-only (`triage_only`)
  candidates it can never actually band (issue #511). A pre-flight
  (`refiner_filter_unbandable_triage`, `agent-cycle.sh`) now resolves each
  contributing repository's field once per cycle before any candidate is
  claimed, drops that repository's `triage_only` candidates when the field
  cannot be resolved — every other candidate, from that repository or any
  other, is unaffected — and logs one `warning` per affected repository
  naming it and how many candidates were dropped. Previously such a
  repository's `triage_only` candidates re-entered the candidate set every
  cycle with no possible progress, and `refiner_engagement_set`'s
  alphabetical cap meant an early-sorting repository in this state could
  fill the entire engagement set, starving refinement everywhere else.

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
- Every fleet flag (the fleet switch, the usage-limit flag, the merge-autonomy
  kill switch and a repository's merge-budget freeze) is now read from GitHub
  at most once per flag per process, rather than once per reader: a cycle that
  resolves `merge_autonomy_effective_level` for each repository spends one
  contents-API read on the kill switch instead of one per repository. A flag
  set or cleared elsewhere is therefore picked up by the next cycle rather
  than part-way through the running one; a flag this process itself writes or
  deletes is picked up immediately.
- **Breaking:** `config.json`'s `review` block is renamed `project_review` and
  restructured: every tunable now lives under `project_review.defaults`
  (installation-wide) and may be overridden per repository on
  `project_review.repos[]` — each entry `{"slug": "owner/name", ...}` — rather
  than the old flat, installation-wide-only block. An installation with its
  own `config.json` outside this fleet must migrate its `review` block to the
  new shape before upgrading; see `docs/REVIEW-PIPELINE-SPEC.md`'s
  Configuration section for the resolution rule and an example.
