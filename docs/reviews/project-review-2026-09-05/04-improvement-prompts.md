# Improvement prompts

One prompt per recommendation, in priority order (severity first, then quick wins before long
campaigns at equal severity — the same order as `03-recommendations.md`). Each prompt is
self-contained and may be pasted into a fresh AI agent session with no other context. None of
these prompts depends on another having been completed first; they touch disjoint files except
where a prompt's own text says otherwise.

## Prompt for R-01 — Fix the dashboard's misleadingly-named `esc()` helper

**Bundles:** R-01 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops (a self-hosted autonomous coding-agent pipeline; the affected
file is dashboard/index.html, a single-file vanilla JS/HTML monitoring dashboard).

Problem: dashboard/index.html:307 defines `function esc(s) { return String(s == null ? "" : s); }`
— a plain string cast with no HTML entity-encoding, despite its name. Two call sites feed its
output into the `html:` attribute path, which sets `innerHTML` directly (dashboard/index.html:279,
`e.innerHTML = attrs[k]`): `kv()` at line 2051 (fed `g.model`/`g.terminal_reason`, internal
pipeline metadata) and a second site at line 2333 (fed only fixed literal strings and numeric
counts from `countText()` at line 2295). Neither site currently receives GitHub-sourced text, so
this is not exploitable today — but the name actively invites a future author to route
GitHub-sourced text (an issue title, a PR body excerpt) through the `html:` path trusting `esc()`
to sanitise it, which would introduce a real stored-XSS-style bug in a dashboard that renders
GitHub content extensively elsewhere via safe `text:`/child-node paths.

Goal (acceptance criteria — pick ONE of these two end states):
(a) Rename `esc()` to a name that does not imply HTML-safety (e.g. `str()`), update all call
    sites to the new name, and add a one-line comment at both `html:`-path call sites (lines 2051
    and 2333) confirming they only ever receive trusted internal/numeric data — so a future
    reader auditing the `html:` path sees the invariant stated, not just implied; OR
(b) Make `esc()` actually HTML-entity-escape its input (`&`, `<`, `>`, `"`, `'`), and simplify the
    `html:` attribute path's two call sites to rely on it directly instead of manual string
    concatenation.
Prefer (a) unless you find a concrete near-term plan to route GitHub-sourced text through the
`html:` path — it is the smaller, safer change.

Constraints: no behaviour change to rendered dashboard output. Do not touch any other function in
dashboard/index.html. Preserve the file's existing code style (no build step, no external JS
dependencies — this file is deployed as-is).

Verification: after your change, `grep -n "html:" dashboard/index.html` and manually confirm every
match's data source is either a fixed literal, a numeric value, or (if you chose end state (b))
now correctly escaped. Run `test/dashboard-render.test.sh` (uses
`test/dashboard-render-harness.js`, a Node-based DOM harness — run with `node`) and confirm it
still passes; it does not currently assert on `esc()`'s behaviour, so passing means you haven't
broken rendering, not that you've covered the new behaviour — consider adding an assertion if you
chose end state (b).

Cost policy: work cost-consciously. Where your environment supports subagents, delegate
well-specified, self-contained subtasks to subagents running the lowest-cost model tier that has
a high probability of completing the subtask correctly at the first attempt. This whole task is
small and mechanical enough to suit a low-cost-to-mid-cost tier throughout; no high-capability
tier is needed. Verify all delegated work before integrating it.

Deliverable: a single commit/PR with a summary of which end state you chose and why, plus
confirmation the verification commands above were run and passed.
```

## Prompt for R-02 — Make the config-table check an actual required merge gate

**Bundles:** R-02 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. `.github/workflows/config-table.yml` runs
`scripts/render-config-table.sh --check` on every pull request but has no `merge_group:` trigger,
and is absent from the repository's branch-protection ruleset's required status checks — so a PR
can merge while it is red. The repository owner has already decided (see the comment trail on
GitHub issue agent-ops#1144, dated 2026-09-04) to make it a required gate, via a two-step
sequence: (1) an agent adds a `merge_group:` trigger to config-table.yml so it reports its result
inside GitHub's merge queue — without this, adding it to required checks would stall every queued
PR for the check-response timeout, since a check with no `merge_group:` trigger never fires
inside the queue; (2) only after step 1 has merged, the human owner manually adds `config-table`
to the ruleset's required checks via the GitHub UI or `gh api` (this step is owner-only per this
repository's own requirement 36a — do not attempt it yourself).

Goal (acceptance criteria): implement step (1) only. `.github/workflows/config-table.yml` gains a
`merge_group:` trigger, following the same pattern `.github/workflows/tech-debt-register.yml`
already uses (that workflow is both required and `merge_group:`-triggered today — read it as your
reference model). The workflow must still run correctly on `pull_request:` and `push:` triggers
exactly as before; you are only adding a new trigger type, not changing what the job does.

Constraints: do not touch the branch-protection ruleset yourself (step 2 is owner-only). Do not
change what `config-table.yml`'s job actually checks or does — only its `on:` trigger
configuration.

Verification: after your change, confirm the workflow's YAML is valid (`gh workflow view
config-table.yml` or a YAML linter if available). Compare your new `on:` block against
`.github/workflows/tech-debt-register.yml`'s to confirm the same trigger shape. You cannot fully
test `merge_group:` behaviour without an actual queued PR, so state this limitation in your PR
description and note that end-to-end confirmation happens naturally the next time a PR queues.

Cost policy: work cost-consciously. This is a small, mechanical, single-file change well suited to
a low-cost-to-mid-cost model tier; delegate only if your environment supports subagents and the
subtask is this well-specified. No high-capability tier is needed.

Deliverable: a single commit/PR adding the `merge_group:` trigger, with a note in the PR body that
step (2) — adding `config-table` to the ruleset's required checks — is a manual follow-up for the
repository owner, referencing agent-ops#1144.
```

## Prompt for R-03 — Make the dashboard's clickable rows/cards keyboard-operable

**Bundles:** R-03 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. dashboard/index.html is a single-file vanilla JS/HTML
monitoring dashboard. Two element classes respond only to mouse `click` events: `.card.clickable`
(node-filter cards) and `tr.clickable` (cycle/detail expansion rows) — neither has a `tabindex`,
`role`, or `keydown` handler anywhere in the file (confirmed: `grep -n "tabindex"
dashboard/index.html` currently returns nothing). This is inconsistent with the dashboard's own
PR-reference hover-card code elsewhere in the same file, which already implements correct keyboard
support (`aria-describedby`, a documented Enter-to-navigate keydown path) — use that existing code
as your reference model for the idiom this codebase already uses.

Goal (acceptance criteria): every element with class `.card.clickable` or `tr.clickable` becomes
reachable and operable by keyboard alone: add `tabindex="0"`, `role="button"`, and a `keydown`
event handler that treats both Enter and Space as equivalent to a `click` (calling
`event.preventDefault()` for Space so the page doesn't scroll). Alternatively, if it's cleaner
given the surrounding code, promote these elements to real `<button>` elements instead — either
approach is acceptable as long as the end result is keyboard-operable.

Constraints: no change to mouse-click behaviour or visual appearance. Do not touch the PR
hover-card code (it already works correctly) beyond reading it as a reference. Preserve the file's
no-build-step, no-external-dependency constraint.

Verification: tab through the rendered dashboard using only a keyboard (no mouse) and confirm you
can reach and activate both a node-filter card and a cycle row's detail expansion using Tab plus
Enter or Space. `test/dashboard-render.test.sh` (via `test/dashboard-render-harness.js`, a
Node-based DOM harness) should still pass; consider extending it to assert the new `tabindex`/
`role` attributes are present on both element classes, following that test file's existing
assertion style.

Cost policy: work cost-consciously. This is a small, self-contained front-end change suited to a
low-cost-to-mid-cost tier; delegate the test-extension subtask separately if using subagents, since
it's a distinct, well-specified piece of work. No high-capability tier is needed.

Deliverable: a single commit/PR with a before/after description of the keyboard interaction, and
confirmation of manual keyboard-only testing.
```

## Prompt for R-04 — Refresh the vendored project-review skill's provenance stamp and add a drift-check

**Bundles:** R-04 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. `docs/REVIEW-PIPELINE-SPEC.md` (around lines 118-121) states
the vendored `.claude/skills/project-review/` skill's provenance as "a pinned copy of the upstream
skill at ~/Code/claude-skills/skills/project-review (upstream commit 2c8e18c, vendored
2026-07-19)". This is stale: commit 86bfbea (2026-08-01, PR #144) synced real content changes
(SKILL.md, references/output-templates.md) from the actual upstream source into the vendored copy,
but did not update this provenance line — it is now roughly 5 weeks out of date. This repository's
own CLAUDE.md states that a spec/code disagreement is a bug to be fixed, not worked around, so
this line being wrong is exactly that class of problem. No automated check catches this kind of
drift for this skill, unlike `.github/workflows/td-tooling-drift.yml`, which does the equivalent
job for a different vendored-tooling pair (compares the canonical copies in Poetic-Poems/poetic
against this repo's copies) — read that workflow as your reference model.

Goal (acceptance criteria):
1. Update the provenance line in docs/REVIEW-PIPELINE-SPEC.md to state the skill's actual current
   upstream commit and vendor/sync date. Determine the correct values by checking what commit hash
   the upstream source (warwickallen/claude-skills, per commit 86bfbea's message) was synced from,
   and using 86bfbea's own date as the "last synced" date (unless you find a more recent sync
   commit — check `git log -- .claude/skills/project-review/` for anything after 86bfbea first).
2. Add some mechanism, even a lightweight one, that would have caught this specific drift going
   forward. Model it on td-tooling-drift.yml's approach if the canonical upstream source is
   reachable from CI; if it is not (e.g. requires credentials this repo's CI doesn't have), a
   documented manual checklist step or a comment-based "last verified" marker with a low-cost CI
   check for staleness (e.g. failing if the marker date is more than N weeks old) is an acceptable,
   lighter-weight alternative — use your judgement on which is actually achievable here, and state
   which you chose and why in your PR description.

Constraints: do not modify the vendored skill files themselves
(.claude/skills/project-review/**) — only the spec's provenance text and any new drift-check
tooling.

Verification: if you add a CI workflow, confirm its YAML is valid and that it would have failed
against the state before your provenance-line fix (i.e. it actually detects the class of drift
this finding describes). If you add a manual checklist item instead, confirm it's placed somewhere
a human doing a similar sync would actually see it (e.g. alongside the existing sync procedure, if
one is documented).

Cost policy: work cost-consciously. The provenance-line fix is small and mechanical (low-cost
tier); designing the drift-check is more ambiguous and benefits from a mid-cost-to-high-capability
tier's judgement about what's actually achievable in this CI environment. Verify all delegated work
before integrating it.

Deliverable: a single commit/PR with both changes, and a clear statement of which drift-check
approach you chose and why.
```

## Prompt for R-05 — Fix `publish-dashboard.sh`'s single-page issues fetch (Priority display silently truncated)

**Bundles:** R-05 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. `scripts/publish-dashboard.sh:2136` fetches open issues via
`gh_call api "repos/$slug/issues?state=open&per_page=30"` — a single, unpaginated page — to parse
each issue's `Priority` custom field for the dashboard's issue panel. The surrounding comment
(around lines 2128-2135) states this exists because the Co-Ordinator's own ranking depends on the
`Priority` field, and explicitly warns that showing a wrong band would be "worse than no band at
all" — i.e. the code's own comment treats accuracy here as load-bearing. This repository already
has more than 30 open issues (agent-ops has 170 as of this writing — confirm the current count
with `gh api "search/issues?q=repo:Poetic-Poems/agent-ops+is:issue+is:open" --jq '.total_count'`
if you want fresh evidence), so today the dashboard silently shows no Priority band for roughly
140 of them.

This is the identical shape to a real bug fixed in this same repository in commit 916a951 (PR
#1165): `scripts/gather-source-state.sh` had the same single-page pattern for an open-issue
listing whose *absence* past the page boundary was misread as "closed," which caused two real
fleet-wide autonomous-pipeline stand-downs on 2026-09-04. That fix introduced a helper
`api_json_paged` (search for it in scripts/gather-source-state.sh) that walks every page via
`gh api --paginate`, checking non-empty output before joining pages so an empty digest from a
partial failure can't be silently mistaken for "no results." Read that function and its usage
before starting — it's your direct model for this fix, though this call site's failure mode is
display-only truncation rather than the read-for-absence pattern the original bug had.

Goal (acceptance criteria): `scripts/publish-dashboard.sh`'s issues fetch retrieves and correctly
parses the `Priority` field for every open issue in a repository, regardless of how many are open
— either by adopting the same `--paginate`-based approach as `api_json_paged`, or by explicitly
documenting the current 30-row cap as an accepted, deliberate trade-off in a code comment (choose
the paginated fix unless you find a concrete reason the cap must stay, e.g. a rate-limit budget
concern specific to this call site — check `lib/github-limit.sh`'s documented page-cap philosophy
if you're unsure).

Constraints: do not change the `Priority`-parsing `jq` logic's actual field-selection semantics —
only how many pages of issues it's applied to. Do not touch `scripts/gather-source-state.sh` (it's
already fixed) except to read it as a reference. Preserve `scripts/publish-dashboard.sh`'s existing
error-handling conventions for failed API calls (check how the surrounding code handles
`gh_call`'s failure return today and match that style).

Verification: add a test fixture to `test/publish-dashboard.test.sh` that exercises more than one
page of open issues (mirror how `test/gather-source-state.test.sh` was updated in commit 916a951
to emulate GitHub's real per-page pagination semantics), and at least one assertion on a
`Priority`-field value that would only be visible with your fix (i.e. an issue on what would have
been page 2 or later under the old 30-row cap). Confirm the existing test at line ~1849 (the
answered/failed state marker check) still passes.

Cost policy: work cost-consciously. Delegate the test-fixture-writing subtask to a low-cost tier
once you've decided the fix approach, since "write a fixture mirroring an existing pattern" is
well-specified mechanical work — but do the fix-approach decision and the actual code change at a
mid-cost tier, since judging what's safe to change here benefits from reading the sibling bug's
full context first. Verify all delegated work before integrating it.

Deliverable: a single commit/PR with the fix, the new test fixture and assertion, and a summary
that explicitly cross-references commit 916a951 as the sibling fix this one mirrors.
```

## Prompt for R-06 — Eliminate duplicated small utility functions and the copy-pasted `san()`

**Bundles:** R-06 only (F-ARCH-02 and F-CODE-02 share a positive reason: both are "promote an
existing duplicated function to lib/, delete the copies" — one PR, or two small ones, either
works) · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops, an almost-entirely-Bash pipeline. Two independent instances
of the same anti-pattern exist, and this repository's own established convention (a `lib/` split
performed via PR #771) is the fix for both:

1. `expand_home()`, `cfg()`/`cfg_json()`, and `log_event()` are each defined nearly identically in
   both agent-cycle.sh (around lines 407, 432-433, 865-877) and review-cycle.sh (around lines 128,
   163-164, 258-266) — read both copies of each before touching anything, since `log_event()`'s
   two copies differ slightly (one says "cycle", the other "review" in a field name) and your
   consolidated version must preserve that per-caller distinction via a parameter, not silently
   drop it.
2. `san()` (the claim-path sanitiser, `san() { local s="$1"; printf '%s' "${s//\//__}"; }`) is
   defined identically in lib/claim.sh (line 119) and scripts/sweep-orphan-branches.sh (line 147).
   `scripts/sweep-orphan-branches.sh` already sources three other lib/ files but not lib/claim.sh —
   check why (there may be no reason; it may simply have been overlooked when claim.sh was
   created) before assuming it's safe to add that source line.

Goal (acceptance criteria): each of `expand_home()`, `cfg()`, `cfg_json()`, `log_event()`, and
`san()` has exactly one definition, living in `lib/`, sourced by every caller that needs it.
`log_event()`'s consolidated version accepts whatever distinguishes the cycle/review field as a
parameter rather than hard-coding either value. `scripts/sweep-orphan-branches.sh` sources
`lib/claim.sh` instead of redefining `san()`.

Constraints: no behavioural change to any caller — every existing test must pass unmodified. Do
not invent a new shared lib/ file if an existing one is a natural fit (e.g. `log_event()` might
belong in a small new `lib/logging.sh`, or check whether an existing file is a better home) —
use your judgement, but keep the new file's scope tight (these five functions and nothing else,
unless you find a sixth duplicate of the same kind while you're in there).

Verification: before deleting either copy of any function, byte-diff the two existing definitions
(`diff <(sed -n '...' agent-cycle.sh) <(sed -n '...' review-cycle.sh)` or equivalent) to confirm
you understand every difference, however small. After consolidating, run
`test/claim.test.sh`, `test/sweep-orphan-branches.test.sh`, and any test files that exercise
agent-cycle.sh's or review-cycle.sh's logging/config-reading wiring (grep test/*.test.sh for
`log_event` or `expand_home` to find them) — via `./scripts/run-tests.sh <name>` if Docker is
available in your environment, otherwise read them carefully to confirm they'd still pass given
your change.

Cost policy: work cost-consciously. This is small, mechanical, low-risk work well suited to a
low-cost-to-mid-cost tier throughout. If using subagents, the two duplicated-function cleanups
(entry-point utilities vs. `san()`) are independent enough to delegate separately, but verify both
against the full test list above before integrating.

Deliverable: a single commit/PR (or two, one per cleanup, if that's cleaner) with the byte-diff
comparison noted in the PR description as evidence no behaviour was lost.
```

## Prompt for R-07 — Add an update mechanism and pin floating references in agent-ops's own supply chain

**Bundles:** R-07 (F-DEPS-01, F-DEPS-02, F-TOOL-03 share a positive reason: all three are "pin or
add an update mechanism for agent-ops's own infrastructure dependencies," naturally landing as one
coherent PR, though three small PRs are equally acceptable) · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. Three independent gaps exist in how this repository manages
its own infrastructure dependencies (distinct from the Dependabot-handling logic this pipeline
runs against *target* repos — do not confuse the two):

1. No `.github/dependabot.yml` exists for agent-ops's own GitHub Actions, base Docker image, or
   pinned binary versions.
2. `deploy/docker/compose.yaml` has two sidecar container images floating on the `:latest` tag
   with no pin: `tailscale/tailscale:latest` and `containrrr/watchtower:latest` (search for
   `image:` to find current line numbers — they may have shifted since this prompt was written).
3. Every `uses:` line across all `.github/workflows/*.yml` files (11 files) references a mutable
   version tag (e.g. `actions/checkout@v7`) rather than a commit SHA, unlike `supercronic` and
   `shellcheck` in `deploy/docker/Dockerfile`, which are pinned to an exact release tag *and*
   verified against a published checksum at build time — read that Dockerfile section as this
   repository's own precedent for what "properly pinned" looks like here.

Goal (acceptance criteria):
1. Add `.github/dependabot.yml` with at least a `github-actions` ecosystem entry (weekly or
   monthly interval, your choice) proposing action-version bumps for this repository itself.
2. Pin both Compose sidecar images to a specific tag or digest (prefer a digest if you can
   confirm one publishes reliably for each image; a specific version tag is an acceptable
   fallback).
3. Pin the highest-privilege Actions used in `.github/workflows/build-image.yml`'s `publish` job
   specifically (this job has `contents: write`/`packages: write` and pushes to a registry) —
   `actions/checkout`, `docker/build-push-action`, `docker/login-action` — to commit SHAs, with a
   trailing comment noting which version tag each SHA corresponds to (GitHub's own convention for
   SHA-pinned actions). Leave lower-privilege workflows' Actions on version tags unless you have
   time to do all 11 files; the publish job is the priority.

Constraints: do not change what any workflow or the Compose file actually does — only version
references. For the Dependabot config, do not add ecosystems beyond `github-actions` unless you
find another manifest-managed dependency in this repository (there should not be one — this is
almost entirely Bash with no package manifest).

Verification: after pinning the sidecars, run `docker compose config` (or `docker compose -f
deploy/docker/compose.yaml config` from the right directory) and confirm it still resolves
cleanly with no syntax errors. After pinning Actions to SHAs, confirm the SHA you chose actually
corresponds to the version tag you're replacing (check the action's repository's own tags/releases
page, or use `gh api repos/<owner>/<action-repo>/commits/<tag>` to resolve a tag to its SHA). If
you can trigger `build-image.yml` in a test context, confirm it still passes; if not, state in your
PR that this needs verification on the next real build.

Cost policy: work cost-consciously. All three of these are mechanical, well-specified changes
suited to a low-cost-to-mid-cost tier; resolving a tag to its correct commit SHA is the one step
worth double-checking carefully regardless of tier, since pinning to the *wrong* SHA would be
worse than not pinning at all. Verify all delegated work before integrating it.

Deliverable: one commit/PR (or three small ones) covering all three fixes, with the SHA-to-tag
correspondence for each pinned Action noted explicitly in the PR description for reviewer
verification.
```

## Prompt for R-08 — Decompose `agent-cycle.sh`'s main flow and the largest `lib/` stage functions

**Bundles:** R-08 (F-ARCH-01 and F-CODE-01 are the same underlying problem — an undecomposed hot
path — addressed by the same incremental approach) · **Run after:** no prerequisites, but read
this prompt's "Approach" section carefully before starting: this is explicitly NOT a one-PR task.

```text
Repository: Poetic-Poems/agent-ops, an hourly-cron autonomous coding-agent pipeline.
`agent-cycle.sh` (3,408 lines) is the pipeline's main entry point; its top-level cycle flow
(claim → five stage dispatches → cleanup) remains roughly 2,000 lines of undecomposed top-level
script — the only part of this file untestable in isolation, since `test/*.test.sh` exercises
externally-observable behaviour, not internal structure, and there is no internal structure here
to unit-test against. Separately, six stage-orchestration functions living in their own `lib/`
files have grown to 319-857 lines each without internal decomposition: `lib/enabler.sh`'s
`maybe_run_enabler` (857 lines), `lib/approver.sh`'s `run_approver_stage` (419), `lib/landing.sh`'s
`_landing_stage_attempt` (361), `lib/refinement.sh`'s `maybe_run_refiner` (319),
`lib/standdown.sh`'s `run_standdown_checks` (856 of the file's 877 lines), and
`lib/candidate-gather.sh`'s `compute_skip_lists` (848 of 1,463 lines). Two feature commits
(af52c53, 83c48c4) landed the day before this review's revision and both added new logic directly
into these undecomposed regions rather than as separated helpers — direct evidence the pattern is
not self-correcting through ordinary development.

This repository already has two working examples of the target shape: `review-cycle.sh`'s
`review_one()` function models a short, readable sequence of named function calls for a cycle
flow; `lib/handoff.sh`'s existing decomposition (largest function only 116 lines) models splitting
a stage-orchestration function into guard-clause, claim-logic, and per-verdict-branch helpers.
Read both before starting — they are your reference models for the target shape, not this
prompt's prose description of one.

Goal (acceptance criteria): `agent-cycle.sh`'s main flow becomes a short, readable sequence of
named function calls for claim, per-stage dispatch, and cleanup — the same shape as
`review-cycle.sh`'s `review_one()`. Each of the six named `lib/` functions above is split into
named helpers for its guard clauses, claim logic, and per-verdict branches — the same shape as
`lib/handoff.sh`'s decomposition. No behaviour change whatsoever: every existing test in
`test/*.test.sh` passes completely unmodified (they test externally-observable behaviour, so a
pure refactor should not require touching any test file — if you find yourself needing to change a
test, stop and reconsider whether your refactor actually preserved behaviour).

Constraints: this is explicitly NOT a one-PR, one-pass task — the codebase's own established
pattern (the earlier #771 split, `lib/handoff.sh`'s decomposition) is surgical, incremental
extraction, one file at a time, not a rewrite. Do ONE of the six named functions (or one coherent
chunk of `agent-cycle.sh`'s main flow) per PR. If you can only complete one in this session,
choose `agent-cycle.sh`'s own main flow first — it's the one part of the hot path that currently
cannot be unit-tested in isolation at all, so it has the highest value per unit of effort. Do not
attempt all six lib/ functions plus agent-cycle.sh in a single PR; reviewing a diff that large
defeats the purpose of doing this incrementally.

Verification: after each individual extraction, run the full test suite (`./scripts/run-tests.sh`
if Docker is available in your environment; otherwise, carefully trace through each test file that
exercises the function you changed to confirm its assertions still hold against your refactored
code) and confirm zero failures and zero test-file modifications. Diff the extracted function's
combined behaviour against its pre-refactor form by reading both side by side — a mechanical
"cut here, paste there" extraction should be self-evidently behaviour-preserving; if you find
yourself changing logic (not just moving it), stop and reconsider.

Cost policy: work cost-consciously, but treat this specific task as an exception to aggressive
delegation — this is exactly the kind of cross-cutting, high-stakes refactor of the pipeline's own
hot path that this repository's own cost-policy convention reserves for a high-capability tier,
not a low-cost one. A failed or subtly-behavior-changing attempt at this task, redone, costs far
more than doing it carefully once. If you delegate sub-pieces to cheaper tiers, keep the actual
decomposition decisions (what to extract, where the boundaries are) at a high-capability tier and
have it review any delegated mechanical extraction before integrating.

Deliverable: one PR per extracted function/flow-segment (expect this recommendation to span
several PRs across several sessions), each with a summary naming which function was decomposed,
into what named helpers, and confirmation the full test suite passed unmodified.
```

## Prompt for R-09 — Fill the security/privacy/ops documentation gaps

**Bundles:** R-09 (F-SEC-02, F-GOV-01, F-DATA-01, F-OPS-02 share a positive reason: all four are
"write one short missing document," a natural single PR, though splitting by file is equally
reasonable) · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops, a self-hosted autonomous coding-agent pipeline holding live
GitHub App and Anthropic API credentials with autonomous merge authority over production
repositories. Four short documentation gaps exist:

1. No SECURITY.md exists anywhere in the repository — no disclosure contact or vulnerability
   report process is stated anywhere.
2. No document inventories what personal data the pipeline touches. `log_event()`
   (agent-cycle.sh, search for its definition) writes structured NDJSON that regularly carries
   GitHub logins as field values, and `config.schema.json` documents that `log.jsonl`,
   `review-log.jsonl`, and `revert-rate.jsonl` are deliberately never rotated by
   `scripts/rotate-logs.sh`, regardless of size — this deliberate no-rotation policy is the
   specific reason the missing inventory matters (personal data accumulates with no retention
   ceiling in at least one log).
3. Dashboard badges showing a stand-down `cause` (e.g. `memory-low`, per `lib/standdown.sh`) have
   no cross-reference to the header comment or spec section explaining what that cause means and
   what an operator should do about it.
4. `docs/ROADMAP.md`'s decision D5 (search for "D5" in that file) records a firm, already-made
   decision to relicense this currently-MIT-licensed repository under the Functional Source
   License (FSL-1.1-ALv2), including a competing-use restriction and a two-year Apache-2.0
   conversion clock — but the actual LICENCE file at the repository root is still plain,
   unconditional MIT with no note anywhere that this change is planned.

Goal (acceptance criteria):
1. Add a short SECURITY.md at the repository root naming a disclosure contact/route (use the
   repository owner's existing public contact method — check README.md or the GitHub profile for
   an appropriate one) and briefly covering in-place credential rotation for a running node
   (distinct from any existing full-decommission runbook, if one exists — check deploy/docker/ for
   one first).
2. Add a short data-inventory paragraph — either in README.md or a new docs/DATA-HANDLING.md —
   stating what personal data is touched (GitHub usernames/logins, primarily), its source (GitHub
   API responses), and its retention (most logs rotated per config, but explicitly noting
   log.jsonl/review-log.jsonl/revert-rate.jsonl are never rotated).
3. Add a brief "what this dashboard badge means, and what to do" cross-reference, linked from
   docs/DASHBOARD-SPEC.md or from the dashboard's own badge rendering code as an inline comment
   pointing to the relevant spec section or lib/ file's header comment.
4. Add a one-sentence note near the LICENCE file or in README.md stating that a licence change to
   FSL-1.1-ALv2 is planned per docs/ROADMAP.md's decision D5, so a consumer of today's MIT-licensed
   code isn't surprised later.

Constraints: all four are short, additive documentation changes — no code behaviour changes at
all. Do not invent policy that isn't already decided elsewhere in the repository (e.g. don't
invent a data-retention policy the maintainer hasn't stated — describe what the code actually
does today, which is "everything except three named logs rotates per config; those three never
rotate").

Verification: read each new/edited document back and confirm it accurately describes current
behaviour by cross-checking against the actual code/config it describes (e.g. confirm your
data-inventory paragraph's rotation claim against config.schema.json's actual `rotate-logs`
documentation, not just this prompt's summary of it).

Cost policy: work cost-consciously. All four of these are short, low-risk documentation tasks
well suited to a low-cost-to-mid-cost tier. If using subagents, each of the four items is
independent enough to delegate separately; verify each against the code/config it describes before
integrating.

Deliverable: one commit/PR (or up to four small ones) with SECURITY.md (new), the data-inventory
addition, the dashboard-badge cross-reference, and the licence-change note.
```

## Prompt for R-10 — Add `openssl` to `doctor.sh`'s toolchain check

**Bundles:** R-10 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. `scripts/doctor.sh` is this project's preflight/health-check
tool; its Toolchain section (search for a loop iterating over tool names like `bash jq git curl
perl python3 rsync flock timeout`) checks that each required external tool is present on the host,
but omits `openssl` — despite `lib/approver-token.sh` hard-depending on `openssl` for RS256 JWT
signing at multiple call sites (search that file for `openssl` to see the actual usage). A node
missing `openssl` currently gets no doctor warning and only discovers the gap when an Approver App
token-mint attempt fails mid-cycle in production — exactly the failure class `doctor.sh` exists to
catch pre-emptively.

Goal (acceptance criteria): `scripts/doctor.sh`'s Toolchain check includes `openssl` in its list of
checked tools, warning (or failing, matching the existing severity convention this loop already
uses for other tools) when it's missing. Gate this check on whether any configured
`merge_autonomy` source is above `human` — mirror how the existing Approver-credential check in
this same script is already gated (search for how that check reads the configured autonomy level
before running).

Constraints: match the existing loop's exact style and severity convention (warn vs. fail) rather
than inventing a new pattern for this one tool.

Verification: run `scripts/doctor.sh` (or trace through it manually if it requires credentials you
don't have) and confirm the new `openssl` check appears in its Toolchain output, correctly gated.
If `test/doctor.test.sh` exists (it does, per this repository's test suite), check whether it
already has fixtures for the Toolchain section and extend one to cover the new check if a natural
extension point exists.

Cost policy: work cost-consciously. This is a small, mechanical, single-line-of-reasoning addition
well suited to a low-cost tier throughout.

Deliverable: a single commit/PR adding the check, with confirmation it was tested (either by
running doctor.sh directly or via an extended test fixture).
```

## Prompt for R-11 — Close small test-coverage gaps

**Bundles:** R-11 (F-TEST-01, F-TEST-02 — the coverage-tooling gap is recorded as accepted, not
acted on, so this prompt's only actionable piece is the new test file) · **Run after:** no
prerequisites

```text
Repository: Poetic-Poems/agent-ops. `lib/git-identity.sh` (29 lines) is the sole guard stopping an
unattended pipeline cycle from committing under no git identity or the wrong one (its header
comment cites the original incident, issue #76, for context). It has zero test coverage anywhere
in `test/*.test.sh` — confirmed by `grep -rl "git_identity\|git-identity" test/*.test.sh`
returning nothing, and it is the only file in `lib/` with this property (every other
apparently-untested file turns out to be covered under a scenario name once you search test
content, not just filenames).

Goal (acceptance criteria): a new `test/git-identity.test.sh` exists, asserting: (1) the function
this file exports (read the file to find its actual name and signature) exits non-zero when
`GIT_USER_NAME` or `GIT_USER_EMAIL` is unset; (2) when both are set, it makes exactly the two
`git config --global` calls the file's logic performs (confirm by reading the file — do not guess
which two calls).

Constraints: follow this repository's existing test file conventions exactly — no test framework
is used anywhere in `test/`, only shell `assert_*`-style helpers (open two or three existing
`test/*.test.sh` files, e.g. `test/claim.test.sh`, to see the house style before writing yours).
Do not introduce a new testing framework or pattern.

Verification: run your new test file the same way other test files in this suite are run
(`./scripts/run-tests.sh git-identity` if Docker is available in your environment; otherwise trace
through it by hand against `lib/git-identity.sh`'s actual logic to confirm each assertion is
correct). Confirm it fails if you temporarily comment out the file's exit-1 guard (a quick
sanity check that your test would actually catch a regression), then restore the guard.

The coverage-tooling gap (no `kcov`/`bashcov` or equivalent exists in this repo) is intentionally
NOT part of this task's scope — it's recorded as an accepted trade-off (bash coverage tooling is
awkward) unless a maintainer decides otherwise; do not add coverage tooling as part of this prompt.

Cost policy: work cost-consciously. This is small, self-contained, low-risk work suited to a
low-cost tier throughout.

Deliverable: a single commit/PR adding `test/git-identity.test.sh`, with confirmation it runs and
passes, and that it fails when the guard it tests is deliberately broken.
```

## Prompt for R-12 — Developer-experience polish (`.editorconfig`, scripts/lib discoverability, CLI `--help` coverage)

**Bundles:** R-12 (F-TOOL-01, F-TOOL-02, F-UX-02 — three independent low-cost polish items,
bundled because they're all "small standalone DX improvement," splitting into separate PRs is
equally fine) · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops, an almost-entirely-Bash pipeline (132 files across lib/ and
scripts/) with two entry points (agent-cycle.sh, review-cycle.sh). Three independent, low-cost
developer-experience gaps exist:

1. No `.editorconfig` or `.shellcheckrc` exists anywhere in the repository — the 2-space-indent
   convention visible throughout the codebase exists only as unwritten convention.
2. No task-runner/Makefile and no scripts index exist — discoverability across the 132 files in
   lib/ and scripts/ rests entirely on reading each file's own header comment.
3. `agent-cycle.sh` and `scripts/doctor.sh` both have a working `usage()` function and `-h`/
   `--help` handling, but `review-cycle.sh`, `scripts/serve-dashboard.sh`,
   `scripts/open-dashboard.sh`, and `scripts/publish-dashboard.sh` do not (confirm with `grep -n
   "^usage()\|--help\|\"-h\""` against each — a script with no match has no help handling).

Goal (acceptance criteria):
1. Add a minimal `.editorconfig` at the repository root: 2-space indent, LF line endings, trim
   trailing whitespace, for at least `*.sh` and `*.pl` (match whatever the codebase's actual
   observed convention is — spot-check a few files if unsure).
2. Optionally, add a generated scripts index — one line per script extracted from each file's
   header comment — following this repository's existing generated-region pattern (see how
   `scripts/render-config-table.sh` generates README/spec tables, with `<!-- config-table:start
   -->`-style markers, as your model if you attempt this; this piece is lower priority than items
   1 and 3, do it only if time allows).
3. Extend the same `usage()`/`-h`/`--help` pattern already proven in `agent-cycle.sh` and
   `scripts/doctor.sh` to the four scripts named above. Read both existing implementations first
   to match their style and level of detail exactly — each new `usage()` should document that
   script's actual flags with the same rationale-per-flag approach the existing ones use, not a
   bare flag list.

Constraints: no behaviour change to any script beyond adding the help-text branch (which must exit
0 and print to stdout, matching the existing two scripts' convention — check this explicitly, don't
assume). Do not invent a build system beyond what's asked for.

Verification: run each of the four scripts with `--help` and `-h` and confirm each prints usage
text and exits 0, matching the pattern of `agent-cycle.sh --help`. If any of these scripts has an
existing test file, confirm it still passes after your change (grep test/*.test.sh for each
script's basename to find relevant tests).

Cost policy: work cost-consciously. All three items are small, mechanical, well-specified DX
polish suited to a low-cost tier throughout; the `--help` extension (item 3) is the most
user-visible and worth prioritizing if you can't complete all three.

Deliverable: one commit/PR (or up to three small ones) covering the `.editorconfig` addition, the
optional scripts index, and the four scripts' new `--help` handling.
```

## Prompt for R-13 — Harden `lib/claim.sh`'s `san()` against a bare `..` path segment

**Bundles:** R-13 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. `lib/claim.sh:119`'s `san()` function
(`san() { local s="$1"; printf '%s' "${s//\//__}"; }`) replaces every `/` in its input with `__`
but does not otherwise validate the input — a bare `..` passed through `san()` comes back
unchanged as `..`. `registry_path()` (lines 121-123 of the same file) builds
`claims/<san($1)>/<san($2)>.json` from sanitised inputs. Tracing every current caller: the claim
key read in agent-cycle.sh (search for where it reads `.item` from a candidate JSON object and
passes it to a claim function) reaches `claim.sh` with no character restriction of its own, while
the enabler and refiner code paths (lib/enabler.sh, lib/refinement.sh — search each for where they
call into claim.sh) do restrict their own keys to `[A-Za-z0-9._-]` before calling in, which
incidentally also blocks `/`. In every path traced, the `.json` suffix is appended immediately
after the sanitised key with no intervening path separator, so a bare `..` value currently becomes
the filename `...json`, not the directory entry `..` — this is not exploitable via any live call
path today. But this safety property is an accident of the format string and of callers'
upstream character restrictions, not something `san()` or `registry_path()` itself guarantees or
even documents — a future caller passing an unrestricted key, or a future refactor of
`registry_path()`'s format string (e.g. inserting a `/` between key and suffix), could reintroduce
a real path-traversal bug with no test currently guarding against it.

Goal (acceptance criteria): `san()` (or `registry_path()` — your choice of where to enforce it,
whichever is cleaner given the surrounding code) explicitly rejects or collapses `.`/`..` path
segments, not merely strips `/` characters. Add a regression test asserting that `registry_path`
never emits a path outside the `claims/` directory for any input, including adversarial inputs
like `..`, `../..`, `foo/../..`, etc.

Constraints: this is a defence-in-depth hardening, not a bug fix for a live exploit — do not change
behaviour for any legitimate key currently in use (alphanumeric-plus-limited-punctuation claim
keys). Confirm your change doesn't reject any key pattern the enabler/refiner code paths or
agent-cycle.sh's own claim keys currently use.

Verification: run `test/claim.test.sh` (and any enabler/refiner tests that exercise claiming — grep
test/*.test.sh for calls into claim.sh's functions) and confirm all pass unmodified after your
change, then add your new adversarial-input regression test and confirm it fails against the
pre-fix code (temporarily revert your fix to check, then reapply it) and passes against the fixed
code.

Cost policy: work cost-consciously. This is small, mechanical, low-risk defence-in-depth work
suited to a low-cost-to-mid-cost tier.

Deliverable: a single commit/PR with the hardening fix and the new regression test, with
confirmation the test fails against the pre-fix code and passes against the fix.
```

## Prompt for R-14 — Decompose the dashboard's 462-line `renderBody()`

**Bundles:** R-14 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. `dashboard/index.html` is a single-file vanilla JS/HTML
monitoring dashboard. Its `renderBody()` function (around lines 2902-3364, confirm the exact range
by searching for `function renderBody`) sequentially assembles every banner (switch/fleet-disable
banners, merge-autonomy banner) and every panel in one 462-line function body — more than 3x the
size of the next-largest function in the file (`landingsPanel`, 144 lines). It is well-commented
throughout (each banner's precedence rule is explained inline) but entirely undecomposed; it is the
one function every new banner or panel addition touches.

Goal (acceptance criteria): extract each logical banner group into its own named function (e.g.
`renderBanners()` for the banner-assembly portion, or more granular per-banner functions if that
reads more naturally given the existing code), mirroring the existing `*Panel` function convention
already used elsewhere in this same file for the panels `renderBody()` calls (e.g. `landingsPanel`
— use it as your naming/structure model). `renderBody()` itself should become a short sequence of
calls to these new functions plus whatever top-level assembly logic doesn't naturally belong in any
one banner/panel group.

Constraints: this must be a pure structural refactor with zero change to rendered output — every
inline comment explaining a banner's precedence rule must be preserved (move it with the code it
explains, don't delete it). Do not change any banner's actual precedence logic or any panel's
actual content while doing this — if you notice something that looks like a bug while refactoring,
note it separately rather than fixing it as part of this task.

Verification: run `test/dashboard-render.test.sh` (via its `test/dashboard-render-harness.js`
Node-based DOM harness — run with `node`) before and after your change and confirm byte-for-byte
identical assertions pass both times, since this test suite checks rendered output, not internal
function structure — an unchanged pass result is your primary evidence that you haven't altered
behaviour.

Cost policy: work cost-consciously. This is small, mechanical extraction work suited to a
low-cost-to-mid-cost tier.

Deliverable: a single commit/PR with the extraction, confirming `test/dashboard-render.test.sh`
passes identically before and after.
```

## Prompt for R-15 — Surface the memory-cgroup "unbounded" verdict to the dashboard/heartbeat

**Bundles:** R-15 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. `lib/memory.sh`'s `memory_cgroup_verdict` function reports
`unbounded` when a node's container cgroup has a real `memory.max` but no `memory.high` set — a
state measured on one real node (2026-09-04) to hold roughly 2465 MiB combined between two
schedulers while idle, cut to 1476 MiB peak with no behavioural harm once `memory.high` was set.
Today this verdict is surfaced only in `scripts/doctor.sh`'s Memory section, run by hand — there is
no `log_event` call recording it and no string anywhere in `dashboard/index.html` referencing
`unbounded`/`memory.high`/`memory-cgroup`. Docker exposes no way to set `memory.high` from inside
the container, so the only available fix on an affected node is a host-level `sudo tee` into the
cgroup's control file — which is silently reset on every container recreation (a
`docker compose up -d`, a Watchtower roll, or a host reboot), meaning a node that rolls its image
regularly spends most of its life back in the `unbounded` state with nothing to notice. This gap
is already recorded in this repository's own tech-debt register as `tech-debt/TD-PPagop-26090401.md`
— read that file's full body before starting, since it already states the chosen remedy (option 3
in its own text: "make the verdict travel — into the heartbeat and onto the dashboard").

Goal (acceptance criteria): implement the register item's own chosen remedy. `memory_cgroup_verdict`
(or its caller) logs an event via this repository's existing `log_event()` mechanism when the
verdict is `unbounded`, and the dashboard surfaces this as a badge, following the existing pattern
`lib/standdown.sh`'s `cause: "memory-low"` stand-down badge already uses in
`dashboard/index.html` (search for where that badge is rendered as your structural model for the
new one — same event-to-badge pipeline, different underlying signal).

Constraints: this is an additive observability feature — no change to `memory_cgroup_verdict`'s
actual detection logic, only to what happens with its result. Follow this repository's existing
NDJSON event-schema conventions exactly (read a few other `log_event` call sites in lib/ to see the
expected field shape before adding a new one).

Verification: trigger the `unbounded` code path (either on a real node with the right cgroup state,
or by mocking `memory_cgroup_verdict`'s inputs in a test) and confirm the new log event is written
with the expected shape, and that dashboard/index.html correctly renders a badge from it. If
`test/publish-dashboard.test.sh` or a memory-specific test file has fixtures for related events,
extend one to cover this new event type.

Cost policy: work cost-consciously. This is small, well-specified observability plumbing suited to
a low-cost-to-mid-cost tier, following two closely analogous existing patterns in this same
codebase.

Deliverable: a single commit/PR implementing the logging and dashboard badge, with confirmation
via a triggered test case, and update `tech-debt/TD-PPagop-26090401.md`'s frontmatter to
`status: resolved` (plus `resolved:` date and a `ref:` pointing at your PR) once this lands —
per this repository's tech-debt register convention, a frontmatter-only edit; do not alter the
item's body.
```

## Prompt for R-16 — Correct fixture identity hygiene / future review verification-note wording

**Bundles:** R-16 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. At least 19 files under `test/*.test.sh`, plus
`test/fixtures/dashboard-data/merge-autonomy-kill.json` (around lines 45-46), use the repository
maintainer's real GitHub usernames (`warwick`, `warwickallen`, `Warwick-Allen` — matching
CODEOWNERS' `* @warwickallen` / `* @Warwick-Allen`) as fixture `login`/`actor`/`assignee`/`by`
values, rather than synthetic placeholders like `alice`/`testuser`. This is deliberate: several
tests (e.g. `test/review-feedback.test.sh` around lines 109-113) specifically need two distinct
identities to model "the agent's own account" vs. "the human review account," and reusing the
maintainer's own two real, already-public accounts is how that distinction was originally
expressed in these fixtures.

Goal (acceptance criteria — this is optional hygiene, not a risk fix; no third party's personal
data is involved and the maintainer's identity is already public via every commit and CODEOWNERS):
where a test's logic does not specifically depend on there being two distinct real-looking
identities (i.e. anywhere a single synthetic placeholder like `testuser` would work exactly as
well), swap the maintainer's real username for a synthetic one. Where a test genuinely needs to
model "the agent's own identity" vs. "a second, human reviewer identity" as two distinct values
(as in `test/review-feedback.test.sh`), you may leave those specific fixtures alone or replace both
values with a clearly-synthetic pair (e.g. `agent-bot` / `human-reviewer`) — your choice, since
either fully addresses the underlying finding.

Constraints: do not change any test's actual logic or assertions — only the identity *values* used
in fixtures, and only where doing so doesn't remove the semantic distinction some tests rely on.
Grep each file you touch for every occurrence of the value you're changing before editing, since
the same fixture value may be asserted against elsewhere in the same file.

Verification: after each edit, run the affected test file (`./scripts/run-tests.sh <name>` if
Docker is available; otherwise re-read the test's assertions against your new fixture values by
hand) and confirm it still passes with identical logical meaning, just a different literal string.

Cost policy: work cost-consciously. This is small, mechanical, low-risk find-and-replace work
across a bounded set of files, well suited to a low-cost tier throughout — verify each file's tests
still pass after your edit before moving to the next.

Deliverable: a single commit/PR listing which files you changed and which (if any) you deliberately
left alone because the real-identity distinction was load-bearing there, with confirmation each
touched test file's suite still passes.
```

## Prompt for R-17 — Add navigation to the 22,998-line implementation-pipeline spec

**Bundles:** R-17 only · **Run after:** no prerequisites

```text
Repository: Poetic-Poems/agent-ops. `docs/IMPLEMENTATION-PIPELINE-SPEC.md` is a 22,998-line
as-built requirements specification with only 51 Markdown headings total; its `## Requirements`
section (roughly 13,400 lines) has exactly 9 `###` sub-headings — one per actor (The Script, Every
stage, The Co-Ordinator, The Implementer, The Reviewer, Logging and state, The Enabler, The
Refiner, The Approver) — each spanning hundreds to thousands of lines, with individual numbered
requirements formatted as bold prose (e.g. "**Requirement 15e.**") rather than as their own
headings. GitHub's own heading-outline UI (the small icon that shows a document's table of
contents) is effectively useless at this document's size given only 51 total headings.

Goal (acceptance criteria — pick whichever is cheaper to implement correctly given what you find,
both are acceptable): (a) add a Markdown sub-heading per numbered requirement (or per tight
requirement-letter group, e.g. all of "15a" through "15h" under one heading if they're a natural
cluster) throughout the `## Requirements` section, using a heading level below the existing 9
actor-level `###` headings; or (b) leave the body text alone and instead add a generated table of
contents near the top of the document, listing every existing heading (including the new
per-requirement ones if you did (a), or just the current 51 if you're doing (b) alone).

Constraints: this must not change any requirement's actual text — only its markup (wrapping
existing bold-prose requirement markers in a heading syntax, or adding a new TOC section). Do not
renumber or reword any requirement. If you write a script to do this transformation mechanically
(strongly recommended given the document's length — a manual pass across 13,400 lines is
error-prone and slow), verify its output extremely carefully against the original before
committing, since a scripted transform that subtly mis-parses the existing "**Requirement NNx.**"
convention could silently corrupt requirement text.

Verification: after your change, diff the document's requirement text (with your added headings
stripped back out, or by comparing word-for-word) against the pre-change version to confirm zero
prose was altered — only markup was added. Confirm the resulting document's heading outline (via
GitHub's UI, or a local Markdown heading-extraction tool) is now actually useful for navigating to
a specific requirement.

Cost policy: work cost-consciously. Writing and carefully verifying a mechanical transform script
is more valuable here than manual editing given the document's size, but the verification step (confirming zero
prose was altered) deserves a mid-cost-to-high-capability tier's attention even if a low-cost tier
writes the initial transform script, since an error here would corrupt a load-bearing specification
document silently.

Deliverable: a single commit/PR with the added headings and/or TOC, plus explicit confirmation (a
diff or word-count comparison) that no requirement's actual text changed.
```

## Prompt for R-18 — Evaluate a bash-aware SAST tool as a supplementary security gate

**Bundles:** R-18 (F-SEC-03, F-CI-03 — same underlying gap, evaluated together) · **Run after:** no
prerequisites

```text
Repository: Poetic-Poems/agent-ops, an almost-entirely-Bash (310 scripts) and Perl (5 scripts)
pipeline with real, credentialed autonomous-merge authority. `.github/workflows/codeql.yml`'s own
comment states plainly that CodeQL has no Shell/Perl support, so its single `matrix.language` entry
is `actions` — it scans only the 11 GitHub Actions workflow YAML files, not the actual Bash/Perl
attack surface (credential handling, claim/merge-concurrency logic, autonomous-merge decisions).
The only automated check on that surface today is `shellcheck` via `.github/workflows/shellcheck.yml`
— a correctness linter, not a security scanner.

Goal (acceptance criteria — this is explicitly an evaluation task, not an implementation
mandate): research what bash-aware and/or Perl-aware SAST tools are currently mature and
practically usable in a GitHub Actions CI context (candidates worth investigating include
`shellharden`, a targeted `semgrep` ruleset for bash, and any Perl-specific static analysis tools
— your research should confirm or update this list, not treat it as exhaustive). For each
candidate, assess: false-positive rate on a sample of this repository's actual code, incremental
security-relevant signal beyond what `shellcheck`'s existing checks already catch, and CI cost
(runtime, whether it needs network access or credentials this repo's CI doesn't already have).
Produce a short written recommendation: either (a) a documented decision that this gap is
accepted as a tooling-maturity limitation for now (if nothing evaluated clears a reasonable
bar), stated in a form the next reviewer can find (e.g. an update to
`.github/workflows/codeql.yml`'s own comment, or a note in `docs/REVIEW-PIPELINE-SPEC.md` or
similar), or (b) a new supplementary CI workflow running your recommended tool alongside the
existing `shellcheck.yml` job, if you find one whose signal-to-noise ratio looks genuinely
favourable when run against a sample of this actual codebase.

Constraints: do not add a new required CI gate speculatively — only add one if your own evaluation
against this codebase's actual code shows favourable signal. If you do add a new workflow, it
should start as non-required (informational) until its false-positive rate is proven over time,
unless you have strong evidence it's already low-noise here.

Verification: whichever path you choose, show your work — the false-positive-rate sample you
tested against, and the specific reasoning for accept-as-limitation vs. add-a-gate. If you add a
new workflow, confirm its YAML is valid and that it runs successfully (even if it reports findings)
against this repository's current code.

Cost policy: work cost-consciously. The research/evaluation phase benefits from a mid-cost-to-
high-capability tier's judgement (weighing false-positive rate against real security value is not
a mechanical task); implementing a chosen tool's CI workflow, if you get that far, is more
mechanical and can drop to a lower-cost tier once the evaluation's conclusion is clear. Low urgency
overall — this is explicitly a "nice to have if a good tool exists" recommendation, not a must-do.

Deliverable: a written evaluation summary (as a PR description, a docs update, or both), plus — only
if warranted by your own findings — a new CI workflow file.
```
