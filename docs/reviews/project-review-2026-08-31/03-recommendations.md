# Recommendations

Ordered by severity first (Medium before Low — there are no Critical or High findings this
round), then by effort within a severity band (quick wins before long campaigns). For each
recommendation, the **Tracked as** line says whether it maps onto a GitHub issue this review
filed fresh, or one that already existed from the 2026-08-23 review (in which case that issue,
not a new one, is the durable record — see `docs/reviews/project-review-2026-08-31/README.md`
for the tech-debt summary).

| ID | Recommendation | Severity | Effort | Addresses | Tracked as |
|---|---|---|---|---|---|
| R-01 | Decompose `agent-cycle.sh`'s main flow and the largest relocated `lib/` stage functions | Medium | Large | F-ARCH-01, F-CODE-01 | agent-ops#964 (existing) |
| R-02 | Eliminate duplicated small utility functions across entry points and scripts | Medium | Small | F-ARCH-02, F-CODE-02 | agent-ops#964, #967 (existing) |
| R-03 | Fix the dashboard's misleadingly-named `esc()` helper | Medium | Small | F-SEC-01 | agent-ops#965 (existing) |
| R-04 | Make the config-table check an actual required merge gate | Medium | Small | F-CI-01 | agent-ops#1144 (new) |
| R-05 | Add an update mechanism and pin floating references in agent-ops's own supply chain | Medium | Medium | F-DEPS-01, F-DEPS-02, F-TOOL-03 | agent-ops#1145 (new) |
| R-06 | Make the dashboard's clickable rows/cards keyboard-operable | Medium | Small | F-UX-01 | agent-ops#970 (existing) |
| R-07 | Refresh the vendored project-review skill's provenance stamp and add a drift-check | Medium | Small | F-DOC-01 | agent-ops#1146 (new) |
| R-08 | Fill the security/privacy/ops documentation gaps | Low | Small | F-SEC-02, F-GOV-01, F-DATA-01, F-OPS-02 | agent-ops#973, #975 (existing) + #1149 (new) |
| R-09 | Add `openssl` to `doctor.sh`'s toolchain check | Low | Small | F-DEPS-03 | agent-ops#1147 (new) |
| R-10 | Close small test-coverage gaps | Low | Small | F-TEST-01, F-TEST-03 | agent-ops#1148 (new) |
| R-11 | Developer-experience polish (`.editorconfig`, scripts/lib discoverability) | Low | Small | F-TOOL-01, F-TOOL-02 | agent-ops#974 (existing) |
| R-12 | Add navigation to the 22,586-line implementation-pipeline spec | Low | Medium | F-DOC-02 | agent-ops#971 (existing) |
| R-13 | Evaluate a bash-aware SAST tool as a supplementary security gate | Low | Medium | F-SEC-03, F-CI-03 | agent-ops#976 (existing) |

## R-01 — Decompose `agent-cycle.sh`'s main flow and the largest relocated `lib/` stage functions

**Severity:** Medium · **Effort:** Large · **Addresses:** F-ARCH-01, F-CODE-01

**Current state:** the #771 refactor (8 days before this review) successfully moved most of
`agent-cycle.sh`'s logic into `lib/*.sh`, but left two things undecomposed: ~1,950 lines of
top-level cycle flow (claim → five stage dispatches → cleanup) in `agent-cycle.sh` itself, and
five large stage-orchestration functions now living in their own `lib/` files
(`lib/enabler.sh`'s `maybe_run_enabler`, `lib/approver.sh`'s `run_approver_stage`,
`lib/landing.sh`'s `_landing_stage_attempt`, `lib/refinement.sh`'s `maybe_run_refiner`) that
grew rather than shrank during the same window.

**Intended end state:** `agent-cycle.sh`'s main flow is a short, readable sequence of named
function calls (claim, per-stage dispatch, cleanup), the way `review-cycle.sh`'s
`review_one()` already models within this same repository. Each of the four named `lib/`
functions is split into named helpers for its guard clauses, claim logic, and per-verdict
branches, the way `lib/handoff.sh`'s existing 17-function decomposition already demonstrates.
No behaviour change; every existing test in `test/*.test.sh` still passes unmodified (tests are
written against externally-observable behaviour, not internal function names, so this should be
achievable without touching test files).

**Approach:** do this incrementally, one file at a time, starting with whichever of the five
functions is next touched for an unrelated behaviour change (per the finding's own suggested
direction) rather than as one large mechanical pass — the codebase's own established pattern
(the #771 split, `lib/handoff.sh`'s decomposition) is exactly this kind of surgical extraction,
not a rewrite. `agent-cycle.sh`'s own flow is the highest-value target since it is the one part
of the hot path that still cannot be unit-tested in isolation.

## R-02 — Eliminate duplicated small utility functions across entry points and scripts

**Severity:** Medium · **Effort:** Small · **Addresses:** F-ARCH-02, F-CODE-02

**Current state:** `expand_home()`, `cfg()`/`cfg_json()`, and `log_event()` are duplicated
byte-for-byte (or near enough) between `agent-cycle.sh` and `review-cycle.sh`. `san()` (the
claim-path sanitiser) is duplicated between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh`,
which does not source `lib/claim.sh` even though it already sources three other `lib/` files.

**Intended end state:** each of these functions has exactly one definition, in `lib/`, sourced
by every caller. `scripts/sweep-orphan-branches.sh` sources `lib/claim.sh` instead of
redefining `san()`.

**Approach:** small, mechanical, low-risk — a good candidate for a single short PR. Verify with
a byte-diff of the old duplicate pairs against the new shared definition before deleting either
copy, and run the affected test files (`test/claim.test.sh`,
`test/sweep-orphan-branches.test.sh`, and any `agent-cycle`/`review-cycle` wiring tests) after.

## R-03 — Fix the dashboard's misleadingly-named `esc()` helper

**Severity:** Medium · **Effort:** Small · **Addresses:** F-SEC-01

**Current state:** `dashboard/index.html:307`'s `esc()` performs no HTML escaping despite its
name; the one call site that feeds its output into `innerHTML` (`kv()`, line 2051) is currently
safe only because the fields it's given today (`g.model`, `g.terminal_reason`) are internal
pipeline metadata, not GitHub-sourced text.

**Intended end state:** either `esc()` is renamed to something that does not imply
HTML-safety (e.g. `str()`), with its two `html:`-path call sites audited to confirm they still
only receive trusted internal data, or `esc()` is made to actually HTML-entity-escape and the
`html:` attribute path is simplified to use it directly.

**Approach:** the rename is the smaller, safer fix and should be preferred unless a concrete
plan exists to route GitHub-sourced text through the `html:` path in future (in which case,
making `esc()` genuinely escape is the more future-proof fix). Either way, grep the whole file
for `html:` afterward to confirm no other latent unescaped path was missed.

## R-04 — Make the config-table check an actual required merge gate

**Severity:** Medium · **Effort:** Small · **Addresses:** F-CI-01

**Current state:** `.github/workflows/config-table.yml` runs on every PR and reports a result,
but is absent from the repository's branch-protection ruleset's required status checks, so a PR
can merge while it is red.

**Intended end state:** either `config-table` is added to the ruleset's required checks (GitHub
UI or `gh api` `PATCH` on the ruleset), or `CLAUDE.md`'s description of it is corrected to say
it is advisory, not gating — whichever matches what the maintainer actually wants enforced.

**Approach:** this is a repository-settings change, not a code change — verify with
`gh api repos/Poetic-Poems/agent-ops/rulesets/18857310` before and after to confirm the
`required_status_checks` list actually changed.

## R-05 — Add an update mechanism and pin floating references in agent-ops's own supply chain

**Severity:** Medium · **Effort:** Medium · **Addresses:** F-DEPS-01, F-DEPS-02, F-TOOL-03

**Current state:** no `.github/dependabot.yml`/Renovate config exists for agent-ops's own
dependencies (distinct from the Dependabot-handling logic the pipeline runs *against* target
repos). Two Compose sidecar images (`tailscale/tailscale:latest`, `containrrr/watchtower:latest`)
float unpinned. GitHub Actions are pinned to mutable version tags, not commit SHAs.

**Intended end state:** a `.github/dependabot.yml` exists with at least a `github-actions`
ecosystem entry proposing action-version bumps; both Compose sidecar images are pinned to a
specific tag or digest; the highest-privilege Actions (`actions/checkout`,
`docker/build-push-action`, `docker/login-action`, used in `build-image.yml`'s `publish` job)
are pinned to commit SHAs.

**Approach:** these three are independently shippable but share one PR naturally since they're
all "pin/update agent-ops's own dependencies" — bundle only if that keeps the diff coherent;
otherwise three small PRs are equally fine. Confirm `docker compose config` still resolves
cleanly after pinning the sidecars, and that `build-image.yml` still passes after the Action SHA
pins.

## R-06 — Make the dashboard's clickable rows/cards keyboard-operable

**Severity:** Medium · **Effort:** Small · **Addresses:** F-UX-01

**Current state:** `.card.clickable` (node-filter cards) and `tr.clickable` (cycle/detail
expansion rows) in `dashboard/index.html` respond only to `click`; no `tabindex`, `role`, or
`keydown` handler exists anywhere on them, unlike the PR-reference anchors in the same file
which already have correct keyboard support.

**Intended end state:** both element classes are reachable and operable by keyboard alone —
`tabindex="0"`, `role="button"`, and a `keydown` handler treating Enter/Space as click (or
promoted to real `<button>` elements) — matching the standard already met by the PR-hover-card
code a few hundred lines away in the same file.

**Approach:** small, self-contained front-end change; verify by tabbing through the dashboard
with a keyboard only and confirming both the node-card filter and a cycle row's detail expansion
work without a mouse. `test/dashboard-render.test.sh`'s harness (`test/dashboard-render-harness.js`)
can be extended to assert the new attributes are present if desired.

## R-07 — Refresh the vendored project-review skill's provenance stamp and add a drift-check

**Severity:** Medium · **Effort:** Small · **Addresses:** F-DOC-01

**Current state:** `docs/REVIEW-PIPELINE-SPEC.md`'s stated upstream commit/vendor date for
`.claude/skills/project-review/` predates two edits that have since landed directly against
that skill (#144, #919), and no drift-check exists for it (unlike
`.github/workflows/td-tooling-drift.yml`, which does this for the sibling tech-debt tooling).

**Intended end state:** the provenance line accurately reflects the skill's actual current
source (or states plainly it is no longer a pure upstream mirror); some mechanism — even a
manual checklist item, ideally an automated check — exists to catch this drift going forward,
the way `td-tooling-drift.yml` does for its sibling.

**Approach:** the provenance-line fix is a one-line spec edit. The drift-check is the larger
piece — model it on `td-tooling-drift.yml`'s approach (comparing a canonical upstream copy
against the vendored one) if a canonical source is reachable in CI; otherwise a lighter-weight
"last-updated" comment discipline may be more practical than a hard CI gate.

## R-08 — Fill the security/privacy/ops documentation gaps

**Severity:** Low · **Effort:** Small · **Addresses:** F-SEC-02, F-GOV-01, F-DATA-01, F-OPS-02

**Current state:** no `SECURITY.md` (disclosure route or incident-response/credential-rotation
guidance), no personal-data inventory, and no dashboard-badge-to-runbook cross-reference exist.
Two of these four findings' underlying gaps are already tracked by agent-ops#973 (SECURITY.md/
governance docs) and #975 (data inventory, bundled with an unrelated `<label>` fix); the fourth
(dashboard-badge cross-reference) is newly filed as agent-ops#1149.

**Intended end state:** a short `SECURITY.md` naming a disclosure contact and covering in-place
credential rotation for a running node (distinct from the existing full-decommission runbook); a
short data-inventory paragraph (README.md or a new `docs/DATA-HANDLING.md`) stating what
personal data is touched, its source, and its retention; and a brief "what this dashboard badge
means, and what to do" cross-reference linked from `docs/DASHBOARD-SPEC.md` or the dashboard
itself.

**Approach:** all are short, additive documentation changes with no code risk; a single PR
touching `SECURITY.md` (new), README/`docs/DATA-HANDLING.md`, and `docs/DASHBOARD-SPEC.md`
covers all four findings' worth of ground economically. This bundle is a positive-reason bundle
in the sense that all four are "write a short missing document," not merely "both
documentation-ish" — but splitting by file is equally reasonable if preferred.

## R-09 — Add `openssl` to `doctor.sh`'s toolchain check

**Severity:** Low · **Effort:** Small · **Addresses:** F-DEPS-03

**Current state:** `scripts/doctor.sh`'s Toolchain section checks 11 tools individually but
omits `openssl`, despite `lib/approver-token.sh` hard-depending on it for RS256 JWT signing.

**Intended end state:** `doctor.sh` warns (or fails, depending on `merge_autonomy` level) when
`openssl` is missing, the same way it already does for `gh`/`claude`/`shellcheck`.

**Approach:** a small, mechanical addition to the existing Toolchain loop, gated on whether any
configured `merge_autonomy` source is above `human` (mirroring the existing Approver-credential
check's own gating).

## R-10 — Close small test-coverage gaps

**Severity:** Low · **Effort:** Small · **Addresses:** F-TEST-01, F-TEST-03

**Current state:** `lib/git-identity.sh` has zero test coverage; no coverage-measurement tool
exists in the repo, so "what's actually exercised" rests entirely on process discipline rather
than a measured floor.

**Intended end state:** `test/git-identity.test.sh` exists, asserting the missing-env-var
failure path and the two `git config --global` calls `require_git_identity` makes. The coverage-
tooling gap is recorded as accepted (bash coverage tooling is awkward) rather than acted on,
unless a maintainer decides otherwise.

**Approach:** small, self-contained, low-risk; follow the existing test file conventions (no
framework, `assert_*` helpers) used throughout `test/`.

## R-11 — Developer-experience polish (`.editorconfig`, scripts/lib discoverability)

**Severity:** Low · **Effort:** Small · **Addresses:** F-TOOL-01, F-TOOL-02

**Current state:** no `.editorconfig`/`.shellcheckrc` exists; no `Makefile` or scripts index
exists — the 147 files across `lib/`/`scripts/` are discoverable only by directory listing plus
reading each header. Already tracked as agent-ops#974 alongside a related `set -e`-convention
and `--help`-coverage gap.

**Intended end state:** a minimal `.editorconfig` (2-space indent, LF, trim trailing whitespace)
exists; optionally, a generated scripts index (one line per script, extracted from each header)
in keeping with the repo's existing generated-region pattern.

**Approach:** low priority, low risk; can be done alongside #974's other asks in one PR if that
issue is picked up as a whole.

## R-12 — Add navigation to the 22,586-line implementation-pipeline spec

**Severity:** Low · **Effort:** Medium · **Addresses:** F-DOC-02

**Current state:** `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s `## Requirements` section
(~13,100 lines) has only 9 sub-headings total, one per actor, with individual numbered
requirements inside as bold prose rather than headings.

**Intended end state:** either a sub-heading per numbered requirement (or per requirement-letter
group), or a generated table of contents, so GitHub's own heading-outline UI becomes useful at
this document's actual size.

**Approach:** mechanical but large in surface area given the document's length — a per-
requirement heading pass touches thousands of lines even though each individual edit is trivial
(wrap existing bold prose in a heading marker). A scripted transform (matching the existing
numbered-requirement convention) is likely far cheaper than a manual pass; verify the result
doesn't change any requirement's actual text, only its markup.

## R-13 — Evaluate a bash-aware SAST tool as a supplementary security gate

**Severity:** Low · **Effort:** Medium · **Addresses:** F-SEC-03, F-CI-03

**Current state:** CodeQL has no Shell/Perl support, so it scans only the 11 workflow YAML
files; the ~304 shell scripts and 5 Perl scripts that are the codebase's real attack surface
have no automated security-scanning gate beyond `shellcheck` (a correctness linter, not a
security scanner).

**Intended end state:** either a documented decision that this gap is accepted as a tooling
limitation (already effectively true today, per the workflow's own comment), or a supplementary
CI job running a bash-aware SAST tool (e.g. `shellharden`, or a targeted `semgrep` bash ruleset)
alongside the existing `shellcheck.yml` job.

**Approach:** this is an evaluation task before it's an implementation task — survey what's
actually available and mature for bash/Perl SAST, weigh false-positive rate against the value
added over `shellcheck`'s own security-relevant checks, and only add a new required CI job if
the signal-to-noise ratio looks favourable. Low urgency; treat as a "nice to have if a good tool
exists" rather than a must-do.
