# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- The deterministic eligibility classifier and the arming/enqueue step (D18
  WI-7, requirement 8d; agent-ops#410): at `merge_autonomy: agent-merges-routine`
  or `agent-merges-all`, once the Approver's own engagement reaches an
  explicit, non-adjudicating approval, `run_landing_stage` re-reads every
  gate fresh — the effective level, `complexity:low`/`medium`, the work
  order's `source` against the new `merge_autonomy_routine_sources` config
  key, no protected path touched (`.github/`, `deploy/`, `prompts/`, `lib/`,
  `config.schema.json`, `CODEOWNERS`), the required checks and security-alert
  delta, no standing human `CHANGES_REQUESTED`, the merge budget, and the
  merge queue — and lands the pull request itself: `enqueuePullRequest`
  where the base branch has an active merge queue, `gh pr merge --auto
  --squash` where it does not, both under the Approver App's own minted
  token. Any unreadable gate refuses arming (`landing-refused`), never a
  pass. Ships dormant — `merge_autonomy` is `human` fleet-wide by default,
  so nothing arms until an installation explicitly raises a repository's
  level (D16, §6). D17's rule that the product never enqueues a pull request
  is repealed at those two levels, and requirement 38f, requirement 3g's
  `dequeued` paragraph and three operating prompts now say so; nothing in
  this pipeline re-queues a *dequeued* pull request at any level, since the
  arming step arms only on the round the Approver approves
  (tech-debt/TD-PPagop-26081701.md).
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
  human queue for it to be parked in at that level. Enforced at the arming
  step (D18 WI-7, above).

### Fixed

- `scripts/doctor.sh` now checks that a repository configured at
  `merge_autonomy: agent-merges-routine` or above can actually land a pull
  request the way `landing_arm` would (agent-ops#532): where its default
  branch carries no merge queue, the arming step falls back to `gh pr merge
  --auto --squash`, a call that needs both the repository's own
  `allow_auto_merge` and its `allow_squash_merge` and which GitHub refuses
  outright when either is off — settings nothing in `merge_autonomy`'s own
  validation looked at, so the combination passed every gate, reached the one
  write, and failed it on every otherwise-eligible pull request indefinitely.
  The check `fail`s that pairing naming which of the two is off and both
  fixes (enable it, or adopt a merge queue), is `ok` for an active queue
  regardless of either setting, `skip`s whatever it cannot read — including a
  `repos/{slug}` that returns neither key, the pair GitHub withholds from a
  token without admin visibility of the repository's merge settings — and
  stays silent below the routine tier. A setting read as a definite `false`
  outranks an unreported sibling, so an unreadable one never masks a setting
  doctor did read as off. `--offline` skips it with the rest of the GitHub
  section.
- `landing_arm` (`lib/landing.sh`) now returns a distinguishable exit status
  for each of its own failure points rather than a bare non-zero, and
  `run_landing_stage` folds `_landing_arm_failure_reason`'s text into its
  `landing-refused` reason — so the log names which step failed (the pull
  request read, the merge-queue read, the enqueue mutation, its partial-write
  case, or the fallback merge) instead of one generic "could not enqueue or
  auto-merge" shared by all of them.
- `merge_budget_oldest_waiting`'s `waiting_backlog` (the pull request a
  `merge-budget-hold` event names as the one waiting longest) now sorts
  GitHub's own listing oldest-first before paging, so a repository with more
  than `GITHUB_PR_LIST_LIMIT` open, labelled pull requests names the true
  oldest rather than the oldest of whatever page happened to come back. Its
  search now also excludes drafts server-side (`draft:false`), so a
  repository whose oldest page is entirely drafts still names its true
  oldest non-draft instead of reporting no backlog at all.
- `lib/issue-priority.sh`'s field-resolution cache directory (issue #510) is
  now removed by the process that created it, rather than left behind once
  per sourcing process — a directory per cycle in a long-lived node
  container, and one per `scripts/doctor.sh` run, which had no exit trap at
  all. `issue_priority_cache_cleanup` is idempotent and removes only a
  directory the library itself created, never a caller-supplied
  `ISSUE_PRIORITY_CACHE_DIR`; `agent-cycle.sh` calls it from its `cleanup()`
  EXIT trap, after the Refiner that is the cache's main consumer, and
  `doctor.sh` from a new EXIT trap of its own.
- `lib/issue-priority.sh`'s cache-directory ownership (issue #541, a
  follow-up to #510) is now a property of the directory rather than of the
  most recent source: a process that sources the library twice used to see,
  on the second source, `ISSUE_PRIORITY_CACHE_DIR` already set to the
  directory the first source created and read it as caller-supplied, so
  `issue_priority_cache_cleanup` declined to remove the very directory the
  library made. `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATH` now records the path
  the library created for itself, so a re-source with that same path still
  marks it owned.
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
- `gather-issues.sh`'s `priority_set` (issue #527, a follow-up to #509/#522)
  no longer reads `true` for a `Priority` field value that carries no
  `single_select_option` at all — GitHub's field-value union also includes
  text and date shapes, which an admin retyping the field can produce, and
  the raw option name it contributed was `null` rather than nothing. Such an
  issue read as triaged and never reached the Refiner's triage duty again;
  it now agrees with `issue_priority_current`'s own verdict and reads
  `priority_set: false`, same as an unset field.
- The dashboard's `by_model` chart and `cost_rows[]` (issue #536) no longer
  credit a transcript's whole `total_cost_usd` to whichever model
  `(.modelUsage | keys)[0]` named — jq's `keys` sorts, so a transcript that
  spent on more than one model (routine, since a subagent call inside a
  stage often reaches for a cheaper one) always credited its entire cost to
  the alphabetically-first model touched, systematically Haiku ahead of Opus
  and Sonnet. Measured on poetic-node-1 on 2026-08-17, this credited Haiku
  98.7% of the fleet's spend against its true 12.4% share, and Opus did not
  appear at all. `scripts/publish-dashboard.sh`'s cost scan now reads each
  `modelUsage` entry's own `costUSD` and sums them independently per model,
  reproducing `total_cost_usd` to the cent; `by_day` and `by_actor` are
  unaffected, still counting one row per transcript. `cost_rows[]` — which
  the model/actor charts' own time-frame selector (issue #334) re-aggregates
  client-side — now carries one row per (transcript × model) rather than one
  per transcript, and without a way to tell those rows back apart the
  windowed `by_actor` figure would have double-counted any transcript that
  spent on two models; `cost_rows[]` rows now also carry the transcript's own
  `cycle` id so the client can dedupe on it and count transcripts, not rows.
- The own-label read-back (requirement 39f) no longer misattributes its own
  `needs-refinement` label writes to a human when the reading node's clock
  runs behind GitHub's, or when a peer node's `own-label-action` record has
  not yet reached this node's union log (issue #526). `lib/label-marker.sh`'s
  comparison now matches any recorded `add` within a skew tolerance of
  GitHub's own `labelled_at`, in either direction, rather than requiring
  ours to be no later — which the RC4-style recurrence measured failing in
  the trailing-clock direction — and now scans every recorded `add`, not
  only the latest action, so an add that matches followed by a `remove` that
  silently failed is still recognised as ours. A label applied within a
  30-minute grace period with no own record yet is deferred rather than
  read as a human's, since the record may simply not have propagated over
  the fleet's periodic state-sync — neither reported as a hand-flag nor
  offered up for a stale-removal retry until the grace period passes.
- `issue_priority_apply` (issue #534, a narrower follow-up to #511/#528) no
  longer fails a band write outright when a repository's `Priority` field
  resolves but is missing one or more of the four band options — previously
  indistinguishable from a field that cannot be resolved at all
  (`field-unresolvable`), which left the Refiner re-offered the same
  unwritable band, and re-spent, on the same `triage_only` issue forever.
  It now falls back to the nearest band the field actually has an option
  for — preferring the next lower band, tying upward only when no lower
  option exists at all — applies the ratchet against that band instead, and
  names the band actually requested in a new `requested` field wherever it
  differs. A field with none of the four names writable at all is reported
  as a new, distinct reason, `band-option-missing`, rather than reusing
  `field-unresolvable` for a different failure.

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
