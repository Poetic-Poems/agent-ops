# Recommendations

Ordered by severity first (Medium before Low — there are no Critical or High findings this
round), then by effort within a severity band (quick wins before long campaigns). All 13
recommendations from the 2026-08-31 review remain open and are reconfirmed here with refreshed
evidence and renumbered for this review; four new recommendations (R-05, R-13, R-14, R-16) cover
findings surfaced only in this pass, each backed by a freshly filed issue. The **Tracked as**
line says whether it maps onto a GitHub issue already open from a prior review, a tech-debt
register item, or one this review filed fresh.

| ID | Recommendation | Severity | Effort | Addresses | Tracked as |
|---|---|---|---|---|---|
| R-01 | Fix the dashboard's misleadingly-named `esc()` helper | Medium | Small | F-SEC-01 | agent-ops#965 (existing) |
| R-02 | Make the config-table check an actual required merge gate | Medium | Small | F-CI-01 | agent-ops#1144 (existing) |
| R-03 | Make the dashboard's clickable rows/cards keyboard-operable | Medium | Small | F-UX-01 | agent-ops#970 (existing) |
| R-04 | Refresh the vendored project-review skill's provenance stamp and add a drift-check | Medium | Small | F-DOC-01 | agent-ops#1146 (existing) |
| R-05 | Fix `publish-dashboard.sh`'s single-page issues fetch (Priority display silently truncated) | Medium | Small | F-TEST-04 | agent-ops#1171 (new) |
| R-06 | Eliminate duplicated small utility functions and the copy-pasted `san()` | Medium | Small | F-ARCH-02, F-CODE-02 | agent-ops#964, #967 (existing); tech-debt/TD-PPagop-26082411.md (existing) |
| R-07 | Add an update mechanism and pin floating references in agent-ops's own supply chain | Medium | Medium | F-DEPS-01, F-DEPS-02, F-TOOL-03 | agent-ops#1145 (existing) |
| R-08 | Decompose `agent-cycle.sh`'s main flow and the largest `lib/` stage functions | Medium | Large | F-ARCH-01, F-CODE-01 | agent-ops#964 (existing) |
| R-09 | Fill the security/privacy/ops documentation gaps | Low | Small | F-SEC-02, F-GOV-01, F-DATA-01, F-OPS-02 | agent-ops#973, #975, #1149 (existing) |
| R-10 | Add `openssl` to `doctor.sh`'s toolchain check | Low | Small | F-DEPS-03 | agent-ops#1147 (existing) |
| R-11 | Close small test-coverage gaps | Low | Small | F-TEST-01, F-TEST-02 | agent-ops#1148 (existing) |
| R-12 | Developer-experience polish (`.editorconfig`, scripts index, CLI `--help` coverage) | Low | Small | F-TOOL-01, F-TOOL-02, F-UX-02 | agent-ops#974 (existing) |
| R-13 | Harden `lib/claim.sh`'s `san()` against a bare `..` path segment | Low | Small | F-SEC-04 | agent-ops#1172 (new) |
| R-14 | Decompose the dashboard's 462-line `renderBody()` | Low | Small | F-CODE-04 | agent-ops#1173 (new) |
| R-15 | Surface the memory-cgroup "unbounded" verdict to the dashboard/heartbeat | Low | Small | F-OPS-01 | tech-debt/TD-PPagop-26090401.md (existing) |
| R-16 | Correct fixture identity hygiene / future review verification-note wording | Low | Small | F-DATA-02 | agent-ops#1174 (new) |
| R-17 | Add navigation to the 22,998-line implementation-pipeline spec | Low | Medium | F-DOC-02 | agent-ops#971 (existing) |
| R-18 | Evaluate a bash-aware SAST tool as a supplementary security gate | Low | Medium | F-SEC-03, F-CI-03 | agent-ops#976 (existing) |

Not covered by a numbered recommendation this round (Low severity, no action needed per the
finding's own direction): F-PERF-01 (log.jsonl growth — no ceiling yet visible in cycle latency),
F-PERF-02 (already tracked as agent-ops#1114), F-CI-02 (`CLAUDE_CODE_VERSION=latest`, a
deliberate documented trade-off), F-TEST-03 (the pagination bug that caused the 2026-09-04
incident — already fixed in the reviewed revision, historical record only).

## R-01 — Fix the dashboard's misleadingly-named `esc()` helper

**Severity:** Medium · **Effort:** Small · **Addresses:** F-SEC-01

**Current state:** `dashboard/index.html:307`'s `esc()` performs no HTML escaping despite its
name; the two call sites that feed its output into `innerHTML` (`kv()` at line 2051, and line
2333) are currently safe only because the fields they're given today are internal pipeline
metadata or numeric counts, not GitHub-sourced text.

**Intended end state:** either `esc()` is renamed to something that does not imply HTML-safety
(e.g. `str()`), with its two `html:`-path call sites audited to confirm they still only receive
trusted internal data, or `esc()` is made to actually HTML-entity-escape and the `html:`
attribute path is simplified to use it directly.

**Approach:** the rename is the smaller, safer fix and should be preferred unless a concrete plan
exists to route GitHub-sourced text through the `html:` path in future. Either way, grep the
whole file for `html:` afterward to confirm no other latent unescaped path was missed.

## R-02 — Make the config-table check an actual required merge gate

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-01

**Current state:** `.github/workflows/config-table.yml` runs on every PR but has no
`merge_group:` trigger and is absent from the branch-protection ruleset's required checks. The
owner has since decided (agent-ops#1144, 2026-09-04) to gate it, in two steps: add the
`merge_group:` trigger first, then add the check to the ruleset by hand. Step one has not
landed.

**Intended end state:** `config-table.yml` reports inside the merge queue (has a `merge_group:`
trigger, modelled on `tech-debt-register.yml`'s existing example) and is added to the ruleset's
required status checks.

**Approach:** the code change (step one) is a small, mechanical addition; the ruleset change
(step two) is a repository-settings change the owner performs by hand per requirement 36a — verify
with `gh api repos/Poetic-Poems/agent-ops/rulesets/18857310` before and after to confirm the
`required_status_checks` list actually changed.

## R-03 — Make the dashboard's clickable rows/cards keyboard-operable

**Severity:** Medium · **Effort:** Small · **Addresses:** F-UX-01

**Current state:** `.card.clickable` (node-filter cards) and `tr.clickable` (cycle/detail
expansion rows) in `dashboard/index.html` respond only to `click`; no `tabindex`, `role`, or
`keydown` handler exists anywhere on them, unlike the PR-reference anchors in the same file which
already have correct keyboard support.

**Intended end state:** both element classes are reachable and operable by keyboard alone —
`tabindex="0"`, `role="button"`, and a `keydown` handler treating Enter/Space as click (or
promoted to real `<button>` elements).

**Approach:** small, self-contained front-end change; verify by tabbing through the dashboard
with a keyboard only and confirming both the node-card filter and a cycle row's detail expansion
work without a mouse. `test/dashboard-render.test.sh`'s harness can be extended to assert the new
attributes are present if desired.

## R-04 — Refresh the vendored project-review skill's provenance stamp and add a drift-check

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DOC-01

**Current state:** `docs/REVIEW-PIPELINE-SPEC.md`'s stated upstream vendor date (2026-07-19)
predates a real content-syncing edit that landed directly against the skill (`86bfbea`,
2026-08-01) — the gap has grown from ~2 weeks to ~5 weeks since the last review measured it, and
no drift-check exists for it, unlike `td-tooling-drift.yml` which does this for the sibling
tech-debt tooling.

**Intended end state:** the provenance line accurately reflects the skill's actual current
source; some mechanism — even a manual checklist item, ideally an automated check — exists to
catch this drift going forward.

**Approach:** the provenance-line fix is a one-line spec edit. The drift-check is the larger
piece — model it on `td-tooling-drift.yml`'s approach if a canonical source is reachable in CI;
otherwise a lighter-weight "last-updated" comment discipline may be more practical.

## R-05 — Fix `publish-dashboard.sh`'s single-page issues fetch (Priority display silently truncated)

**Severity:** Medium · **Effort:** Small · **Addresses:** F-TEST-04

**Current state:** `scripts/publish-dashboard.sh:2136` fetches open issues with `per_page=30` and
no `--paginate`, for a `Priority`-field display the surrounding comment itself calls load-bearing.
agent-ops has 170 open issues today, so roughly 140 of them silently show no Priority band. This
is the identical shape to the bug commit `916a951` fixed same-day in `gather-source-state.sh`
(F-TEST-03), which caused a real fleet-wide stand-down on 2026-09-04.

**Intended end state:** the dashboard's Priority display covers every open issue regardless of
count, or the 30-row cap is explicitly documented as an accepted trade-off; a test fixture
exercises more than one page and asserts at least one Priority-field value.

**Approach:** apply the same `--paginate`/`api_json_paged`-style fix already proven in
`scripts/gather-source-state.sh` — this is the smaller, safer choice given the sibling bug's
real-world blast radius; run after confirming `test/publish-dashboard.test.sh`'s existing
assertions still pass.

## R-06 — Eliminate duplicated small utility functions and the copy-pasted `san()`

**Severity:** Medium · **Effort:** Small · **Addresses:** F-ARCH-02, F-CODE-02

**Current state:** `expand_home()`, `cfg()`/`cfg_json()`, and `log_event()` are duplicated
byte-for-byte (or near enough) between `agent-cycle.sh` and `review-cycle.sh`. `san()` (the
claim-path sanitiser) is duplicated between `lib/claim.sh` and
`scripts/sweep-orphan-branches.sh`, which does not source `lib/claim.sh` even though it already
sources three other `lib/` files.

**Intended end state:** each of these functions has exactly one definition, in `lib/`, sourced by
every caller. `scripts/sweep-orphan-branches.sh` sources `lib/claim.sh` instead of redefining
`san()`.

**Approach:** small, mechanical, low-risk. Verify with a byte-diff of the old duplicate pairs
against the new shared definition before deleting either copy, and run the affected test files
(`test/claim.test.sh`, `test/sweep-orphan-branches.test.sh`, and any `agent-cycle`/`review-cycle`
wiring tests) after.

## R-07 — Add an update mechanism and pin floating references in agent-ops's own supply chain

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-DEPS-01, F-DEPS-02, F-TOOL-03

**Current state:** no `.github/dependabot.yml`/Renovate config exists for agent-ops's own
dependencies. Two Compose sidecar images (`tailscale/tailscale:latest`,
`containrrr/watchtower:latest`) float unpinned. GitHub Actions are pinned to mutable version
tags, not commit SHAs.

**Intended end state:** a `.github/dependabot.yml` exists with at least a `github-actions`
ecosystem entry; both Compose sidecar images are pinned to a specific tag or digest; the
highest-privilege Actions (`actions/checkout`, `docker/build-push-action`, `docker/login-action`)
are pinned to commit SHAs.

**Approach:** these three are independently shippable but share one PR naturally. Confirm
`docker compose config` still resolves cleanly after pinning the sidecars, and that
`build-image.yml` still passes after the Action SHA pins.

## R-08 — Decompose `agent-cycle.sh`'s main flow and the largest `lib/` stage functions

**Severity:** Medium · **Effort:** Large · **Addresses:** F-ARCH-01, F-CODE-01

**Current state:** `agent-cycle.sh`'s top-level cycle flow remains ~2,000 undecomposed lines; six
stage-orchestration functions across `lib/enabler.sh`, `lib/approver.sh`, `lib/landing.sh`,
`lib/refinement.sh`, `lib/standdown.sh`, and `lib/candidate-gather.sh` remain 319-857 lines each.
Two feature commits landed the day before this review (`af52c53`, `83c48c4`) both added new logic
directly into these undecomposed regions rather than as separated helpers.

**Intended end state:** `agent-cycle.sh`'s main flow is a short, readable sequence of named
function calls, the way `review-cycle.sh`'s `review_one()` already models. Each of the six named
`lib/` functions is split into named helpers for its guard clauses, claim logic, and per-verdict
branches, the way `lib/handoff.sh`'s existing decomposition already demonstrates. No behaviour
change; every existing test in `test/*.test.sh` still passes unmodified.

**Approach:** do this incrementally, one file at a time, starting with whichever function is next
touched for an unrelated behaviour change, rather than as one large mechanical pass — the
codebase's own established pattern (the #771 split, `lib/handoff.sh`'s decomposition) is exactly
this kind of surgical extraction, not a rewrite.

## R-09 — Fill the security/privacy/ops documentation gaps

**Severity:** Low · **Effort:** Small · **Addresses:** F-SEC-02, F-GOV-01, F-DATA-01, F-OPS-02

**Current state:** no `SECURITY.md` (disclosure route), no personal-data inventory, no
dashboard-badge-to-runbook cross-reference, and no note that a licence change to FSL-1.1-ALv2 is
already decided (`docs/ROADMAP.md` D5) but not yet applied to the still-MIT `LICENCE` file exist.

**Intended end state:** a short `SECURITY.md` naming a disclosure contact; a short
data-inventory paragraph (what personal data, from where, how long it's kept, covering
`log.jsonl`'s deliberate no-rotation policy); a brief cross-reference from dashboard badges (or a
new `docs/RUNBOOK.md`) to the relevant header/spec explanation; and a note near `LICENCE` or in
README that the FSL-1.1-ALv2 relicense is planned.

**Approach:** all are short, additive documentation changes with no code risk; one PR touching
`SECURITY.md` (new), README/`docs/DATA-HANDLING.md`, and `docs/DASHBOARD-SPEC.md` covers most of
this ground economically, though splitting by file is equally reasonable.

## R-10 — Add `openssl` to `doctor.sh`'s toolchain check

**Severity:** Low · **Effort:** Small · **Addresses:** F-DEPS-03

**Current state:** `scripts/doctor.sh`'s Toolchain section checks several tools individually but
omits `openssl`, despite `lib/approver-token.sh` hard-depending on it for RS256 JWT signing.

**Intended end state:** `doctor.sh` warns (or fails, depending on `merge_autonomy` level) when
`openssl` is missing, the same way it already does for `gh`/`claude`/`shellcheck`.

**Approach:** a small, mechanical addition to the existing Toolchain loop, gated on whether any
configured `merge_autonomy` source is above `human`.

## R-11 — Close small test-coverage gaps

**Severity:** Low · **Effort:** Small · **Addresses:** F-TEST-01, F-TEST-02

**Current state:** `lib/git-identity.sh` has zero test coverage; no coverage-measurement tool
exists in the repo.

**Intended end state:** `test/git-identity.test.sh` exists, asserting the missing-env-var
failure path and the two `git config --global` calls `require_git_identity` makes. The coverage-
tooling gap is recorded as accepted rather than acted on, unless a maintainer decides otherwise.

**Approach:** small, self-contained, low-risk; follow the existing test file conventions.

## R-12 — Developer-experience polish (`.editorconfig`, scripts/lib discoverability, CLI `--help` coverage)

**Severity:** Low · **Effort:** Small · **Addresses:** F-TOOL-01, F-TOOL-02, F-UX-02

**Current state:** no `.editorconfig`/`.shellcheckrc` exists; no scripts index exists across the
132 files in `lib/`+`scripts/`; `review-cycle.sh`, `scripts/serve-dashboard.sh`,
`scripts/open-dashboard.sh`, and `scripts/publish-dashboard.sh` have no `usage()`/`-h`/`--help`
handling, unlike `agent-cycle.sh` and `scripts/doctor.sh`.

**Intended end state:** a minimal `.editorconfig` exists; a generated scripts index optionally
exists; the four named entry points gain the same `usage()`/`-h`/`--help` pattern already proven
in `agent-cycle.sh`/`doctor.sh`.

**Approach:** low priority, low risk; the `--help` extension is the most user-visible piece and
can be done as a single small pass across the four scripts, following the existing pattern
exactly.

## R-13 — Harden `lib/claim.sh`'s `san()` against a bare `..` path segment

**Severity:** Low · **Effort:** Small · **Addresses:** F-SEC-04

**Current state:** `san()` strips `/` but does not reject `.`/`..` segments; no current caller
exploits this (every path traced is safe today, either by upstream character restriction or by
the `.json`-suffix format string), but the safety property is not stated or enforced by `san()`
itself.

**Intended end state:** `san()` (or `registry_path()`) explicitly rejects or collapses `.`/`..`
segments; a regression test asserts `registry_path` never emits a path outside `claims/` for any
input.

**Approach:** small, mechanical, low-risk defence-in-depth; verify no existing caller's legitimate
keys are affected by re-running `test/claim.test.sh` and the enabler/refiner claim tests.

## R-14 — Decompose the dashboard's 462-line `renderBody()`

**Severity:** Low · **Effort:** Small · **Addresses:** F-CODE-04

**Current state:** `dashboard/index.html:2902-3364`'s `renderBody()` sequentially assembles every
banner and panel in one function body, more than 3x the size of the next-largest function in the
file.

**Intended end state:** each banner group is extracted into its own named function (e.g.
`renderBanners()`), mirroring the existing `*Panel` function convention already used for the
panels it calls.

**Approach:** mechanical extraction with no behaviour change; verify with
`test/dashboard-render.test.sh`'s existing assertions, which should pass unmodified since they
test rendered output, not internal function structure.

## R-15 — Surface the memory-cgroup "unbounded" verdict to the dashboard/heartbeat

**Severity:** Low · **Effort:** Small · **Addresses:** F-OPS-01

**Current state:** `lib/memory.sh`'s `memory_cgroup_verdict` is surfaced only in
`scripts/doctor.sh`'s Memory section, run by hand; no `log_event` call or dashboard string
exists for it. `tech-debt/TD-PPagop-26090401.md` already names this gap and its own chosen
remedy.

**Intended end state:** the cgroup verdict is logged as an event and surfaced as a dashboard
badge, so a `memory.high` setting reverted by a container recreation is visible without running
`doctor.sh` by hand.

**Approach:** follow the tech-debt item's own stated direction; model the new badge on the
existing `cause: "memory-low"` stand-down badge already in `dashboard/index.html`/
`lib/standdown.sh`.

## R-16 — Correct fixture identity hygiene / future review verification-note wording

**Severity:** Low · **Effort:** Small · **Addresses:** F-DATA-02

**Current state:** at least 19 test files and one dashboard-data fixture use the maintainer's
real, already-public GitHub identities (`warwickallen`/`Warwick-Allen`) rather than synthetic
placeholders, because several tests need to distinguish "the agent's own account" from "the
human's second account."

**Intended end state:** no risk-driven action is required (self-referential, already public);
either an optional swap to an explicit synthetic placeholder identity for hygiene, or — more
cheaply — future review verification notes phrased as "no *third-party* personal data" rather
than "no real personal data."

**Approach:** lowest priority in this list; a documentation/wording fix is sufficient on its own,
with the fixture swap as an optional follow-up.

## R-17 — Add navigation to the 22,998-line implementation-pipeline spec

**Severity:** Low · **Effort:** Medium · **Addresses:** F-DOC-02

**Current state:** `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s `## Requirements` section (~13,400
lines) has only 9 sub-headings total, one per actor, with individual numbered requirements inside
as bold prose rather than headings.

**Intended end state:** either a sub-heading per numbered requirement (or per requirement-letter
group), or a generated table of contents, so GitHub's own heading-outline UI becomes useful at
this document's actual size.

**Approach:** mechanical but large in surface area given the document's length. A scripted
transform (matching the existing numbered-requirement convention) is likely far cheaper than a
manual pass; verify the result doesn't change any requirement's actual text, only its markup.

## R-18 — Evaluate a bash-aware SAST tool as a supplementary security gate

**Severity:** Low · **Effort:** Medium · **Addresses:** F-SEC-03, F-CI-03

**Current state:** CodeQL has no Shell/Perl support, so it scans only the 11 workflow YAML files;
the ~310 shell scripts and 5 Perl scripts that are the codebase's real attack surface have no
automated security-scanning gate beyond `shellcheck`.

**Intended end state:** either a documented decision that this gap is accepted as a tooling
limitation, or a supplementary CI job running a bash-aware SAST tool alongside the existing
`shellcheck.yml` job.

**Approach:** this is an evaluation task before it's an implementation task — survey what's
actually available and mature for bash/Perl SAST, weigh false-positive rate against the value
added, and only add a new required CI job if the signal-to-noise ratio looks favourable. Low
urgency.
