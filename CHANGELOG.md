# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `scripts/run-tests.sh`: run the `test/` suite the way CI runs it — the
  working tree copied into a throwaway `docker run` container from the image,
  with nothing of the host or of any running node reaching it. The suite will
  *start* anywhere and only *pass* in the environment CI uses, and both ways of
  getting that wrong fail on an untouched `main` while naming something other
  than their own cause: from the checkout, the host's `jq` (1.6 and 1.7
  disagree about enough for roughly nine files to fail); through `docker exec`
  into a running node, that container's `PULLWRIGHT_APPROVER_APP_ID`, which
  `doctor.sh` reconciles against `approver_app_id` — so a fixture deleting the
  config key builds "an Approver the config does not declare" instead of "no
  Approver", and three assertions in `test/config-schema.test.sh` invert.
  `README.md`'s "Running the tests" recommended the first of those and now
  documents both.

- D18 Stage 4's protected-path compensating controls (agent-ops#415): a
  pull request touching a protected path (`.github/`, `deploy/`, `prompts/`,
  `lib/`, `config.schema.json`, `config.json`, `agent-cycle.sh`,
  `review-cycle.sh`, `CODEOWNERS`) now routes to the Approver's critical
  tier regardless of its complexity grade, including `complexity:low` (which
  otherwise short-circuits to a deterministic, model-free approval); the
  `approver-verdict` event's own `critical_reason` field
  (`protected-path`/`refuse-streak`) distinguishes the two causes a critical
  engagement can have. At `agent-merges-all`, a protected-path pull request
  is now eligible to land automatically — the one relaxation Stage 4 makes —
  but only once the approving engagement ran at that critical tier and a
  new `landing_cool_off_hours` config key (default 24, per-repo override,
  `0` disables) has elapsed since the standing review's own timestamp; a
  fresh push restarts the wait, since the standing review's own `commit_id`
  no longer matches the pull request's current head and nothing here
  dismisses a stale review on push. Both controls are
  re-read fresh at every arming attempt, including a landing-retry sweep
  re-arm outside the round that first approved the pull request. Below
  `agent-merges-all` a protected path stays ineligible exactly as before.

- `scripts/autonomy-stage-report.sh` (D18, agent-ops#571): a read-only
  operator report answering "has this repository met its current D18
  rollout-stage exit criteria?" — its `merge_autonomy` level, the stage
  (agent-ops#402) that level corresponds to, that stage's exit criteria, the
  measured value of each, and a closing `met`/`not-met (criterion: …)`/
  `insufficient-evidence` verdict. Two criteria — classifier escapes and the
  Stage 1 Approver/human divergence — have no detector yet (agent-ops#572,
  #573) and are always reported `unavailable`, never a guessed `0`, so a
  promotion decision is never made to look ready on missing data.

- `coordinator_prompt_max_bytes` config key (agent-ops#641), and
  `lib/coordinator-input.sh` behind it: a bound on the assembled Co-Ordinator
  prompt, so it can no longer grow past its model's context window unnoticed.
  The Script measures the rendered base prompt, subtracts it and the rest of
  the runtime-input document, and trims the two bands that carry a whole
  document each — an issue's entire thread, a tech-debt item's entire file —
  into what is left, along an eight-rung ladder walked only as far as the
  allowance requires. Prose is shed and candidacy is not: every entry keeps
  its `ref`, `url`, `title`, `priority` and `updated_at`, so a trimmed item is
  ranked and selected exactly as an untrimmed one, and every cut ends in
  `…[Script: elided N of M bytes … read it whole at <url>]` — which
  `prompts/coordinator.md` now obliges the Co-Ordinator to follow before it
  may *select* that entry, so the fetch is paid once for the item picked
  rather than for every item considered. Dropping whole entries is the last
  rung only, keeps the highest-`Priority` and freshest first, and is counted
  on the repo entry and in the union log. Trimming logs
  `coordinator-input-fitted`; a prompt that still does not fit logs a
  `warning` before the API refuses it. `0` disables the bound, which is how
  every release before this key behaved.

- `escalation_autonomy` config key (D18, agent-ops#627): `always-escalate`
  (the default, today's behaviour byte-for-byte) or `adjudicate-first`, which
  runs one bounded Enabler adjudication pass — a fresh, narrower engagement
  over one item alone, at `enabler_model` — before the Script files an
  escalation issue for a refinement disagreement (requirement 36b's thrash
  guard: a `needs-refinement` block that was already refined once and has
  since been re-flagged). The pass either confirms the existing refinement
  (recorded exactly as an ordinary `unblocked` refinement, no issue ever
  filed) or escalates exactly as `always-escalate` already does, logged
  either way as an `enabler-adjudication` event carrying its verdict and
  evidence. Bounded, not a loop: one pass per item, per human touch — an item
  that has already had one escalates without a second, the one exemption
  being a human having acted on an escalation about it since. `scripts/doctor.sh` warns when `adjudicate-first` is configured
  with no `enabler_model` to run the pass with. Poetic's own `config.json`
  sets `adjudicate-first`.

- `scripts/doctor.sh` warns when a key documented as installed —
  `x-docs.value` differing from its own schema `default` — resolves, from the
  live `config.json`, to something else (agent-ops#567): `refiner_model`
  documented as `claude-haiku-4-5-20251001` while the key had never once been
  set in `config.json` (silently running the Refiner off) went undetected for
  eight days, and nothing before this compared what the configuration tables
  claimed against what the config actually had. A key whose `x-docs.value`
  equals its own `default` — describing the product's shipped behaviour, not
  an installation's choice — is never checked, and neither is one with no
  `x-docs.value` at all or one keyed `readme`/`spec`.

- Two dashboard pie charts, **Model used — Implementer** and **Model used —
  Reviewer** (issue #529): which model each stage was *asked* to run, not
  spend attribution — a single Implementer stage on Sonnet still emits Haiku
  `modelUsage` rows for the subagents its own invocation spawns, so a ratio
  built from `cost_rows` would have reported Haiku for most Implementer runs
  (the #536 failure this issue was asked not to repeat). Backed by a new
  `counts.stage_models` Publisher aggregate, read from `stage-end` events'
  own `model` field; every stage-end counts once, including a failed run or a
  retry, and one with no readable model lands under "unknown" rather than
  being dropped. Appended to the existing cost section, sharing its
  time-frame selector, with a muted caption naming the aggregate's own
  retained-log window — which can be shorter than the cost charts' — since
  `log.jsonl` is rotated independently of `COST_SCAN_DAYS`.

- `counts.cost_rows[]` entries now carry `repo`, `item`, `source`, `outcome`
  and `attributed` (issue #593, D21) — the money's spend total already said,
  which the item dimension left "what did we spend on work that never landed"
  unanswerable to ask. Joined by `cycle` against the same fleet-wide event
  union `cycles[]` renders from, not against `cycles[]` itself: the union is
  bounded by `log_retained_bytes`, independent of `cycles[]`'s own
  `MAX_CYCLES` cap, so the join reaches back over the whole `COST_SCAN_DAYS`
  span the cost roll-ups already cover. `attributed:true`, with the other
  four fields populated, only for a coordinator/implementer/reviewer row
  whose own cycle has events in that union; every other row —
  enabler/refiner/limit-probe (which share their triggering cycle's id but
  spent on a different item than the one that cycle selected),
  project-reviewer (whose review id never reaches `log.jsonl`), or a
  coordinator/implementer/reviewer row whose cycle has rotated out of the
  union — carries all four as `null` and `attributed:false`, never dropping
  the row itself.

- An hourly, unattended `scripts/doctor.sh --unattended` pass (agent-ops#543),
  on its own `deploy/docker/crontab.tmpl` line: the same Configuration and
  GitHub checks an operator runs by hand, run unprompted, so a configuration
  gap that only shows up against a live repository — a repository's
  `Priority` field missing one of `Urgent`/`High`/`Medium`/`Low`, above all —
  is no longer invisible on a node nobody happens to run the command on.
  Skips only the two checks that spend (the Claude-credentials check and the
  stream-flushing probe), each with its own reason, distinct from
  `--offline`'s; the GitHub section runs in full, since every call there is a
  GET. Its verdict — the summary, and every `warn`/`fail` line with a
  timestamp — reaches the dashboard as a new **Doctor** section and a
  page-top banner (red for a failure, amber for a warning), read from
  `state_dir/.doctor-status.json` rather than recomputed on the dashboard's
  own 5-minute heartbeat.

- The autonomous-landing digest (D18 WI-8, agent-ops#411): a new
  **Autonomous landings** dashboard section reporting, over a rolling 24 h
  window, every pull request the Script landed without a human — when, which
  repository and pull request, its title, the work source, the complexity it
  was armed at, the `enqueued`/`auto-merge` method used, the node that armed
  it, and the Approver tier and verdict that authorised it. This is the
  asynchronous audit D18 accepts unattended merging in exchange for (risk 6 of
  `docs/reviews/2026-08-14-autonomy-investigation.md`), and is permanent
  rather than rollout scaffolding: at `agent-merges-all` it is the only
  routine account of what merged.

  Built from the fleet-wide event union, so a landing armed on any node shows
  on every node's page. The verdict join takes the newest `approver-verdict`
  for that pull request *at or before* the arm, never a later re-review — an
  Approver may review the same pull request across several cycles, and only
  the verdict the arming stage could have seen explains the landing. A landing
  whose verdict cannot be located still renders, marked `unknown`, since an
  unexplained landing is the most important row the panel can carry.

  Alongside the landings it reports what would otherwise mislead by omission:
  refusals over the same window grouped by reason class (two landings beside
  forty refusals is a classifier holding the line; two beside none may be a
  gate that is not running), and each repository's `merge_budget_per_day` cap
  against what the window consumed, with an unlimited repository reading as
  `∞` rather than a cap of zero. A payload the Publisher could not assemble
  renders as "could not be assembled this tick", explicitly distinguished from
  a quiet night — an empty list is a reportable nothing, `null` is an outage,
  and the two must not look alike.

- The landing-retry sweep (requirement 8u, TD-PPagop-26081701): once per
  cycle, fleet-wide, for every repository at `merge_autonomy:
  agent-merges-routine` or `agent-merges-all`, re-enters the arming step's
  own six gates for every open pull request whose Approver review is
  genuinely standing `APPROVED` on GitHub right now — closing the gap the
  original arming step (D18 WI-7) left, where a refusal whose reason could
  change on its own (the merge budget resetting, the kill switch or a
  per-repo freeze lifting, a `merge_autonomy`/`merge_autonomy_routine_sources`
  config change, a transient unreadable, a required check going green) was
  never revisited and a human had to notice and merge by hand. Reuses
  `landing_eligible` rather than a second copy of it, so a protected-path
  hit, a `complexity:high` pull request, or a source outside the routine
  list is never armed here either. `landing-armed`/`landing-refused` events
  from the sweep carry `retry: true`. Neither the sweep nor this round's own
  arming step ever arms more of a repository's stranded pull requests,
  between them, than its remaining merge budget — `merge_budget_per_day`
  less what it has already landed in the rolling window: `merge_budget_decide`
  (`lib/merge-budget.sh`) discounts a running, cycle-scoped tally (shared by
  both call sites) from the live merged-PR count, since GitHub's own record
  only shows a pull request as merged once the merge has actually landed,
  never the moment either arms it — without the bound, every stranded
  candidate offered in the same cycle read the same not-yet-merged count and
  all of them armed regardless of the cap. Neither call site ever re-arms a
  pull request GitHub's merge queue has already removed once and nobody has
  re-queued since — a maintainer's own deliberate removal is never reversed,
  and a checks-failure removal is left for `scripts/gather-dequeued.sh`'s own
  `dequeued` source to diagnose and fix before a human re-queues, rather than
  blindly re-running the same failing merge group every cycle.

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

- The Approver's own backstop and watchdog overrides (TD-PPagop-26081601,
  agent-ops#473): `timeout_approver` and `inactivity_approver` fleet-wide, and
  `approver` under a `repos[]` entry's `stage_timeouts` / `stage_inactivity`,
  completing requirement 4f's precedence for the one implementation actor that
  had none. The Approver stage (D18 WI-5) shipped with its own
  `stage_budget_apply` call but no configuration to reach it, so an
  installation could not pin either cap for that stage while it could for
  every other. Omitting them stays the normal case — both caps still derive
  themselves. The derived `lock_stale_after` accordingly sums six actors
  rather than five, widening the default cycle lock by the Approver's 30 min
  prior, and `scripts/doctor.sh`'s pinned-cap warning now covers both new
  keys at every level of the precedence (TD-PPagop-26081802).

### Fixed

- The Co-Ordinator's `refinements` input is scoped to candidacy
  (agent-ops#643). `refinements` is a ledger that is never retired, and an
  entry for an item type with no thread to hold it carries the whole
  specification in markdown. By 2026-08-21 it had reached 237,339 bytes, 24
  `spec` payloads accounting for 219,175 of them, and the Co-Ordinator's
  prompt text plus the unsheddable half of its input came to 387,840 bytes
  against a 350,000-byte maximum *before any candidate was added* — so the
  allowance `coordinator_prompt_max_bytes` computes came out negative, the
  fit ladder was never walked, and the API refused the stage on every node of
  the fleet for eleven consecutive cycles with no work selected anywhere.
  `coordinator_refinements_view` now keeps a `spec` only for an item some
  band of the cycle actually offers, and keeps `ts`/`cycle`/`comment_url` for
  every item as before. `prompts/coordinator.md` gives a spec exactly one use
  — pasted verbatim into the work order of an item being selected — so a spec
  for a non-candidate was prose the model paid to read and could never act
  on. On the cycle that found the outage this took the band from 237,339
  bytes to 29,304, and the unsheddable overhead from 387,840 to 179,629.

- A Co-Ordinator allowance that comes out at or below zero now sheds as much
  as the ladder can rather than nothing at all (agent-ops#643). The branch
  added with `coordinator_prompt_max_bytes` warned and then fell past the fit
  entirely, sending the candidate bands whole — which is how a 350,052-byte
  `issues` extract went into a prompt that was already over the window
  without it. The allowance is now clamped to 1 before the ladder is walked:
  0 or less means "bound off" to `coordinator_fit_bands` and returns the
  array unchanged, while 1 fails every rung and lands in its final branch,
  which returns the smallest array the ladder can build with `fits: false`.
  The warning still says the prompt may be refused regardless; the cycle just
  no longer makes that more likely on its way out.


- The Co-Ordinator no longer takes the fleet down by outgrowing its model's
  context window (agent-ops#641). On 2026-08-21 the assembled prompt reached
  ~226580 tokens against a 200000-token window and the API refused four
  consecutive cycles on every node; nothing had broken, the `issues` band had
  simply grown one comment at a time past a limit nothing measured. See
  `coordinator_prompt_max_bytes` under Added for the bound.

- A stage the API refuses outright now says which refusal it was
  (agent-ops#641). The whole record of those four lost cycles was `coordinator
  exited 1`, and the crash-loop escalation sent its reader to
  `coordinator.out.stderr` — which an API refusal leaves empty, because the
  refusal is a `result` with `is_error: true` in `coordinator.out`. The
  `attempt-failed` detail is now "<stage> was refused by the API before it
  could run: <terminal reason>", with the API's own message beside it on the
  event as `api_message`; the two are kept apart deliberately, since the
  crash-loop ladder groups on the detail and the message carries a token count
  that moves every cycle. The escalation's hint names `coordinator.out` first.

- A cycle with `refiner_model` empty (no Refiner) no longer pays for the
  Refiner's `triage_only` pre-flight (agent-ops#567): candidate computation
  itself is unconditional, so a repository contributing a triage-only
  candidate still cost a `Priority`-field GraphQL read, and could still log a
  `refiner:` warning about candidates it dropped, for a stage that could never
  engage. The pre-flight now runs only when this installation has a Refiner —
  unchanged, including under `--dry-run`, for one that does.

- A Co-Ordinator `needs_refinement` report for an issue can no longer
  re-assert a `Blocked-by:` dependency the Script's own gate already resolved
  (agent-ops#566). Requirement 3j drops any issue naming an unresolved
  dependency before the Co-Ordinator ever sees it, but a stale sentence can
  still sit in an otherwise-selectable issue's thread after the reference it
  named has closed — one cycle read that sentence for five separate issues
  and reported each `needs_refinement`, even though the dependency gate had
  already cleared all five. `record_needs_refinement_block` now refuses, with
  a logged warning and no block, label, or assignment, any `source: "issues"`
  entry whose own `reason`/`missing`/`evidence` names — by issue number — a
  dependency this cycle's own gathered thread already proves resolved
  (`dependency_refusal_reason`, `lib/dependency-gate.sh`); a genuine
  under-specification or question/discussion decline on the same item is
  untouched. `prompts/coordinator.md` now states plainly, ahead of restating
  the mechanics, that this exclusion's dependency half is never the
  Co-Ordinator's to re-derive, and that `evidence` may never assert the live
  state of an item outside this cycle's own runtime input.
- `lib/issue-priority.sh`'s cache-dir ownership record could be talked into
  removing a directory it never created (agent-ops#552, follow-up to #548/#541).
  The record was trusted straight from the environment with no check that it
  came from this process, so an inherited `ISSUE_PRIORITY_CACHE_DIR_OWNED=1`
  let a child process treat a caller's own directory as its own and `rm -rf`
  it; a new `ISSUE_PRIORITY_CACHE_DIR_OWNER_PID`, stamped with the creating
  process's own `$$`, is now required to match before a record is trusted. A
  stale record also outlived the directory it named — a source following a
  cleanup could keep trusting a directory that no longer existed, leaving
  field-id caching dead for the rest of that process — fixed by checking the
  directory still exists independently of cleanup's own record-clearing (which
  does not reach a caller invoking it through a command substitution), and by
  keying `issue_priority_cache_cleanup` on the owned path itself rather than
  the current `ISSUE_PRIORITY_CACHE_DIR`, so a directory this file created is
  never abandoned when a caller later repoints `ISSUE_PRIORITY_CACHE_DIR`
  elsewhere.
- `merge_autonomy_routine_sources` can now name issue work at all
  (agent-ops#558). The key shared one `sourceToken` enum with
  `repos[].sources`, but the two are matched against different things: a
  `sources` token is compared against a *candidate*, while a routine-list
  token is compared against a finished work order's own `source`, which
  `scripts/gather-issues.sh` has by then collapsed from `issues:<band>` to
  the plain word `issues`. The shared enum therefore offered exactly the
  four spellings landing can never match and withheld the only one it can,
  so an installation widening its routine list to include issues got a
  config that validated and not one issue ever armed. agent-ops#519 caught
  the silence and added a doctor warn whose remedy — "list `issues` itself"
  — the same enum then rejected, leaving issue work with no writable
  spelling at all. The key now takes its own `landingSourceToken` enum
  (bare `issues`, no bands), a banded entry is a schema error rather than a
  silent never-match, and `scripts/doctor.sh` reads a bare `issues` in the
  routine list as gathered whenever the repository's own `sources` carry any
  `issues:<band>` — without which following its own advice would simply
  trade one warning for another. Banding remains a gathering-time rank that
  landing cannot see, now stated plainly in the schema rather than buried as
  a disclosed limitation: `issues` is all-or-nothing at the arming step, and
  an installation wanting only its low-band issues landed narrows what it
  gathers, not what it arms.
- `landing_eligible`'s routine-source membership test no longer inverts on
  jq 1.6 (agent-ops#558). `jq -e` exits 0 on *empty input* under jq 1.6 and
  4 under jq 1.7, and both `_landing_routine_sources`' array probes and the
  membership test itself fed possibly-empty strings to `jq -e`: on a 1.6
  host the routine list resolved empty instead of falling through to the
  shipped default, and the membership test then admitted every source the
  gate exists to refuse. The container image pins jq 1.7 (`ubuntu:24.04`),
  which is the only reason this was never a live fail-open on the fleet — an
  argument from a pinned dependency rather than from the gate's own code,
  which is the wrong thing to rest an arming decision on. All three call
  sites now test for emptiness explicitly before consulting `jq -e`. The
  three `test/landing.test.sh` assertions that failed on any jq 1.6 host —
  and passed in CI purely because CI runs inside the image — now pass
  everywhere.

- `scripts/doctor.sh` now also warns when a repository's effective
  `merge_autonomy_routine_sources` names a banded `issues:<band>` token
  (agent-ops#519): the existing "does this repository's own `sources` list
  gather it" check (agent-ops#512) passes cleanly, since the banded token
  typically is present there too, but every `issues:<band>` work order's own
  `source` collapses to the plain word `issues` before `landing_eligible`'s
  exact-string comparison ever runs (`lib/landing.sh`'s own header) — a
  known, disclosed limitation — so the entry could validate clean and still
  never match a work order. The new warn names the offending token and
  suggests listing `issues` itself.
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
- The Reviewer can no longer flip a draft pull request ready while a
  standing human comment goes unanswered (requirement 31c, agent-ops#533,
  PR #512): a human cannot leave a formal `REQUEST_CHANGES` review on this
  system's own pull requests, so a plain PR comment — often paired with
  converting the pull request back to draft — is the change-request signal
  here, and nothing previously refused a hand-off that silently dropped one.
  `lib/reconciliation-gate.sh`'s new gate reads every general PR comment
  posted since the pull request's most recent `ready_for_review` timeline
  event *as the round found it* — bounded by the cycle's own start time,
  since the Reviewer runs `gh pr ready` itself and an unbounded search would
  take that flip as the anchor and filter out every comment the round existed
  to answer — and refuses the flip, on the same terms as the existing
  closing-keyword gate, unless a pipeline comment since cites it with
  `<!-- agent-ops:reconciles comment=<id> -->`. A refusal names each
  unanswered comment by permalink, so the next round can act on it rather
  than re-deriving it. `prompts/reviewer.md`'s
  completion comment now carries that citation for every human comment it
  answers.
- The reconciliation gate above (requirement 31c, agent-ops#533) could refuse
  a pull request exactly once per unreconciled comment, never twice
  (agent-ops#539). A `dirty` verdict left the pull request exactly as the
  Reviewer's own step-7 `gh pr ready` had just left it — ready, not draft —
  so that flip survived the round it was refused in, and because GitHub keeps
  a `ready_for_review` event rather than deleting it when a later
  `convert_to_draft` supersedes it, that surviving flip became the very next
  round's reconciliation anchor: the standing comment the gate had just named
  fell before it and read as reconciled, permanently, one round after the
  refusal. `handoff_complete_review` (`lib/handoff.sh`) now calls
  `confirm_pr_draft` on every `dirty` reconciliation verdict — the same
  "confirm against GitHub, don't trust the call's own exit status" shape
  `confirm_pr_ready` already applies in the forward direction — converting
  the pull request back to draft on both the Reviewer's own handoff and the
  Enabler's `complete_handoff` recovery path, and `_reconciliation_gate_anchor`
  (`lib/reconciliation-gate.sh`) now skips any `ready_for_review` event that
  has a `convert_to_draft` event after it at or before the bound, so a
  reverted flip cannot win the anchor either. A revert that itself fails to
  take logs its own warning, distinct from the ordinary refusal, since the
  pull request is at that point not merely carrying an unanswered comment but
  still ready for a human to merge. `prompts/reviewer.md`'s own anchor
  instructions (step 6) now carry the same undone-event exclusion, since the
  Reviewer's live read of "most recent `ready_for_review` event" was open to
  the identical trap.
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
- `maybe_run_refiner`'s `mutation-failed` warning (issue #551, a follow-up to
  #538/#534) now names the band actually attempted, not the band the verdict
  asked for, when a fallback ran: previously the warning always named the
  verdict's own band even though the failed write targeted a different,
  fallback band, so an operator reading it could not tell which band the
  pipeline actually tried to set. It now also names the requested band
  alongside the attempted one whenever the failed result carries a
  `requested` field; a `mutation-failed` with no fallback, and the other
  three failure reasons (`field-unresolvable`, `band-option-missing`,
  `issue-unreadable`), keep their existing wording unchanged, since nothing
  was attempted on those paths.
- `refiner_filter_unbandable_triage`'s pre-flight (issue #542, the degenerate
  case between #511 and #534) now also drops a repository's `triage_only`
  candidates when its `Priority` field resolves cleanly but carries none of
  `Urgent`/`High`/`Medium`/`Low` at all — an organisation that renamed every
  option, e.g. to `P0`…`P3`. Previously such a repository passed the
  pre-flight (its field *does* resolve), paid the Refiner's spend every
  cycle, and then hit `issue_priority_apply`'s `band-option-missing` with
  nothing to fall back to, leaving every `triage_only` issue in that
  repository — not just those with one band missing — re-entering the
  candidate set forever: #511's starvation shape again, at #511's own blast
  radius. The new check reuses the field lookup the pre-flight already made
  (`issue_priority_options_any`, `lib/issue-priority.sh`), so it costs no
  additional GraphQL call, and logs a warning worded distinctly from the
  existing "Priority field unresolvable" one. A repository missing only
  *some* of the four names is unaffected — `issue_priority_apply`'s own
  per-issue fallback (#534, above) still bands it.

### Changed

- Every `item-void` a Co-Ordinator, Enabler or Implementer
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
