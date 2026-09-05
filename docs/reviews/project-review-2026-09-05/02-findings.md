# Findings

34 findings across all 13 checklist dimensions. This review re-verified every finding from the
2026-08-31 review against the current revision (`916a951`, 13 substantive commits after
`857bc1d7`), refreshed evidence where line numbers or details drifted, and added new findings
from a deeper pass and from the commits themselves — including one real production incident
(F-TEST-03) that occurred and was fixed entirely within the reviewed window.

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 11 |
| Low | 23 |

## Architecture and design (ARCH)

**Strengths:** the #771 `lib/` split (verified by the 2026-08-31 review) has held: `agent-cycle.sh` is 3,408 lines (was 3,341), `lib/` now holds 73 files (was 72). The 13 commits since `857bc1d7` show the discipline is being actively applied, not just inherited: `b655e5a` (move hot REST reads to GraphQL) *removed* a duplicate read path, and new `lib/memory.sh` (added in `83c48c4`) is deliberately modelled on the existing `lib/disk-space.sh` shape. A cross-tool seam introduced by `a245a39` ("change the nice function") is implemented independently in `lib/repo-order.sh` (jq) and `dashboard/index.html`'s `niceWeight()` (JS), and both were updated together correctly in the same commit alongside `config.schema.json`, two specs, and `test/repo-order.test.sh`.

### F-ARCH-01 — `agent-cycle.sh`'s cycle body remains ~2,000 lines of undecomposed top-level flow, and recent commits keep growing it in place · **Medium**

**Evidence:** `acquire_lock()` now ends at `agent-cycle.sh:1404` (was 1377); file runs to 3408 (was 3341) — still ~2,000 undecomposed lines. Fresh evidence the pattern is still reinforced: `af52c53` (#1134, 2026-09-04) added ~35 lines of crash-loop-retirement flow directly into this region (`agent-cycle.sh:1536-1584`), and `83c48c4` (2026-09-04, one day before this review) added a `min_free_memory_bytes` guard clause the same way (`agent-cycle.sh:765-773`).

**Impact:** the highest-stakes, most-frequently-touched code, and the only part of `agent-cycle.sh` untestable in isolation. Two feature commits in six days added to the undecomposed region rather than shrinking it.

**Direction:** extract claim/dispatch/cleanup phases into named functions, as `review-cycle.sh`'s `review_one()` already models. Addressed by R-08.

### F-ARCH-02 — Small utility functions still duplicated verbatim between `agent-cycle.sh` and `review-cycle.sh` · **Low**

**Evidence:** `expand_home()` identical at `agent-cycle.sh:407` / `review-cycle.sh:128`; `cfg()`/`cfg_json()` identical one-liners at `agent-cycle.sh:432-433` / `review-cycle.sh:163-164`; `log_event()` structurally identical at `agent-cycle.sh:865-877` / `review-cycle.sh:258-266`.

**Impact:** low risk given size, but the one place the codebase's own "promote to `lib/`" discipline is unapplied to its own entry points.

**Direction:** move into a small `lib/` file. Addressed by R-06.

## Code quality and maintainability (CODE)

**Strengths:** zero genuine `TODO`/`FIXME`/`HACK`/`XXX` markers across `lib/`, `scripts/`, `dashboard/index.html`, and both entry points. `shellcheck -x agent-cycle.sh` is clean. `b655e5a`'s GraphQL migration *reduced* duplication (issue/PR listing logic consolidated into new `lib/issue-prefetch.sh`). Comment/header density and quality remain very high in every file sampled.

### F-CODE-01 — Stage-orchestration functions remain large, and the same undecomposed-god-function pattern is broader than previously documented · **Medium**

**Evidence:** the four functions the 2026-08-31 review measured are essentially unchanged: `maybe_run_enabler` 857 lines (`lib/enabler.sh:785-1641`), `run_approver_stage` 419 (`lib/approver.sh:518-936`), `_landing_stage_attempt` 361 (`lib/landing.sh:1248-1608`), `maybe_run_refiner` 319 (`lib/refinement.sh:1172-1490`). Fresh sampling found two more of the same class: `run_standdown_checks` (856 of `lib/standdown.sh`'s 877 lines) and `compute_skip_lists` (848 of `lib/candidate-gather.sh`'s 1463 lines). `83c48c4` (2026-09-04, one day before this review) added the new memory-standdown guard clause directly into `run_standdown_checks()`'s existing undecomposed body rather than as a separate helper.

**Impact:** these functions are exactly where the next stage-behaviour change lands; splitting into files (#771) did not reduce in-function branching complexity, and new feature work keeps extending the pattern.

**Direction:** next touch to any of these six functions should split guard/claim/per-branch sections into named helpers, as `lib/handoff.sh` (largest function 116 lines) already demonstrates. Addressed by R-08.

### F-CODE-02 — `san()` (claim-path sanitiser) remains copy-pasted between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` · **Medium**

**Evidence:** `lib/claim.sh:119` and `scripts/sweep-orphan-branches.sh:147` both define `san()` verbatim. `sweep-orphan-branches.sh` sources three other `lib/` files but not `lib/claim.sh`.

**Impact:** a future change to `san()`'s encoding in `lib/claim.sh` silently leaves `sweep-orphan-branches.sh` on stale encoding; a sweep matching claim paths incorrectly can delete a branch a peer node still holds.

**Direction:** source `lib/claim.sh` from `scripts/sweep-orphan-branches.sh`, delete the local copy. Addressed by R-06.

### F-CODE-03 — `scripts/publish-dashboard.sh` and `scripts/doctor.sh` remain almost entirely top-level flow · **Low**

**Evidence:** `publish-dashboard.sh` is unchanged at 3,242 lines; `doctor.sh` grew 1,842→1,879 lines via `83c48c4`'s new Memory section, added as more top-level flow. Each defines only 17 and 9 functions respectively, most trivial one-line accessors.

**Impact:** lower urgency than F-CODE-01 since both are standalone operator scripts with dedicated test coverage, not the hourly hot path.

**Direction:** no urgent action; same phase-extraction treatment if change frequency rises.

### F-CODE-04 — `dashboard/index.html`'s `renderBody()` is a 462-line undecomposed function, by far the largest in the file · **Low**

**Evidence:** `dashboard/index.html:2902-3364` (approx.), `renderBody()` sequentially assembles every banner and panel — more than 3x the size of the next-largest function in the file (`landingsPanel`, 144 lines).

**Impact:** single-maintainer project, but this is the function every new banner/panel change touches; its size makes local reasoning about banner-ordering interactions harder than it needs to be.

**Direction:** extract each banner group into its own named function, mirroring the existing `*Panel` convention. Addressed by R-14.

## Security (SEC)

**Strengths:** credential handling in `lib/github-app-token.sh` (377 lines, read in full) remains unusually disciplined: JWTs and minted installation tokens travel to `curl` exclusively via `--config -` (stdin), never argv; the tmpfs-only token cache checks filesystem type and ownership before trusting a cache hit. `shellcheck -S warning` against the six token/auth `lib/` files is clean. A fresh repo-wide grep and full-history `git log --all -S<pattern>` search for live-secret shapes turns up hits only inside `test/*.test.sh` redaction-test fixtures (all synthetic) — no live credential anywhere. All 10 `prompts/*.md` files carry the identical "Untrusted external content" block.

### F-SEC-01 — Dashboard's `esc()` helper does not escape HTML and two call sites feed it into `innerHTML` · **Medium**

**Evidence:** `dashboard/index.html:307` still defines `function esc(s) { return String(s == null ? "" : s); }` — a plain string cast, no HTML entity-encoding. Two call sites route into the `innerHTML`-backed `html:` attribute path (lines 2051, 2333) but both are fed only internal pipeline metadata or numeric counts today — no GitHub-sourced text reaches either site.

**Impact:** not exploitable with attacker-controlled content today. The name remains actively misleading: a future author routing GitHub-sourced text through the `html:` path, trusting `esc()` to sanitise it, would introduce a real stored-XSS-style bug.

**Direction:** rename `esc()` to reflect what it does (e.g. `str()`), or make it actually HTML-escape and audit both `html:` call sites. Addressed by R-01.

### F-SEC-02 — No `SECURITY.md` or documented vulnerability-disclosure route · **Low**

**Evidence:** no `SECURITY.md` exists anywhere in the repository; `README.md` contains no disclosure contact or process.

**Impact:** the project wields autonomous merge authority over production repositories and holds live GitHub App and Anthropic API credentials, so a third party spotting a flaw has no stated channel to report it.

**Direction:** add a short `SECURITY.md` naming a contact/route. Addressed by R-09.

### F-SEC-03 — CodeQL scans only the GitHub Actions YAML, not the ~310 shell/Perl scripts that are the actual attack surface · **Low**

**Evidence:** `.github/workflows/codeql.yml`'s own comment states CodeQL has no Shell/Perl support; the single `matrix.language` entry is `actions`.

**Impact:** an accurate, self-aware, tooling-limited gap — but the code holding credential-handling and autonomous-merge logic has no automated SAST coverage beyond `shellcheck` (a correctness linter, not a security scanner).

**Direction:** evaluate a bash-aware SAST tool if one becomes practical. Addressed by R-18.

### F-SEC-04 — `lib/claim.sh`'s path safety relies entirely on stripping `/`, with no explicit defence against a `..`-only segment · **Low**

**Evidence:** `lib/claim.sh:119`'s `san()` replaces every `/` with `__` but does not otherwise validate its input — a bare `..` comes back unchanged. Traced every current caller: `agent-cycle.sh:2452`'s claim key reaches `claim.sh` with no character restriction of its own, while the enabler/refiner paths do restrict their own keys upstream. In every traced path the `.json` suffix appended immediately after the key means a bare `..` becomes the filename `...json`, not a traversal — not currently exploitable.

**Impact:** the safety property is an accident of caller discipline, not a guarantee `san()` itself makes; a future caller or a `registry_path()` format-string change could reintroduce a real traversal with no test guarding the property.

**Direction:** make `san()` (or `registry_path()`) explicitly reject/collapse `.`/`..` segments; add a regression test. Addressed by R-13.

## Testing and quality assurance (TEST)

**Scope note:** `docker` is unavailable in this reviewing sandbox, so `scripts/run-tests.sh` (which runs the suite inside a container by design, to pin `jq` version behaviour) could not be executed here. This is a read-based review, corroborated by a direct (non-Docker) `shellcheck` run and by tracing real production incidents in the commits since 857bc1d7. No claim is made about having run the suite and seen it pass or fail.

**Strengths:** the suite grew from 171 to 176 files since 857bc1d7 and remains unusually disciplined: still overwhelmingly regression tests tied to real incidents cited by issue/PR number. `build-image.yml` genuinely runs the entire suite inside the freshly built container on both `linux/amd64` and `linux/arm64` before publishing. Riskiest `lib/` files (`claim.sh`, `landing.sh`, `merge-queue.sh`, `merge-autonomy.sh`, the token/auth files) all have substantial coverage.

### F-TEST-01 — `lib/git-identity.sh` has no test coverage anywhere in the suite · **Low**

**Evidence:** it is the only `lib/` file with zero direct-name hits across `test/*.test.sh`. The 29-line file is the sole guard stopping an unattended cycle from committing under no identity or the wrong one.

**Impact:** a regression here would only surface as a wrongly-attributed commit in production, not as a red CI check.

**Direction:** add `test/git-identity.test.sh` asserting the missing-env-var exit-1 path and the two `git config --global` calls. Addressed by R-11.

### F-TEST-02 — No coverage tooling; naive filename cross-reference is misleading · **Low**

**Evidence:** no `kcov`/`bashcov` reference anywhere in the repo. A naive basename cross-reference still flags files as "untested" that a scenario-name search shows are in fact covered.

**Impact:** no quantitative answer to how much of the riskiest paths is actually exercised.

**Direction:** low priority given bash coverage tooling is awkward. Addressed by R-11.

### F-TEST-03 — A test-double pagination gap in `gather-source-state.sh` caused two real production incidents on 2026-09-04, fixed same-day in the reviewed revision · **Medium** (historical; resolved in HEAD)

**Evidence:** `scripts/gather-source-state.sh` fetched a single, unpaginated page of open issues/PRs; requirement 34i's work-gone sweep reads an item's *absence* from these digests as "the work is closed." Once agent-ops passed 100 open issues (it is at 170 today), every issue past the first page read as closed — this fired twice on 2026-09-04, falsely clearing real blocks and triggering a fleet-wide stand-down. The test stub had not modelled GitHub's real per-page semantics, so an existing "all issues survive" assertion passed against code that in production only ever saw the first page. Both the production fix (`api_json_paged`, `gh api --paginate`) and a corrected stub landed together in commit `916a951` (PR #1165) — the tip commit of this review's revision.

**Impact:** the clearest evidence in this review that a green suite can hide drift between a test double and the real system it stands in for. Blast radius was real: a multi-hour, fleet-wide autonomous-pipeline stand-down.

**Direction:** already fixed in HEAD; no further action on this instance. See F-TEST-04 for a sibling gap the same pattern surfaced.

### F-TEST-04 — `scripts/publish-dashboard.sh`'s own issues fetch has the identical untested pagination gap, live today on agent-ops's own 170 open issues · **Medium**

**Evidence:** `scripts/publish-dashboard.sh:2136` fetches `per_page=30` with no `--paginate`, for a `Priority`-field display the code's own comment calls load-bearing. agent-ops has 170 open issues today, so the dashboard silently omits Priority data for roughly 140 of them. `test/publish-dashboard.test.sh` has zero assertions on this parsing logic.

**Impact:** display-only (unlike F-TEST-03, it doesn't feed an automated decision), but the same anti-pattern in a sibling file, already proven capable of silent truncation in this exact codebase.

**Direction:** apply the same paginate-style fix, or document the cap as an accepted trade-off; add a multi-page fixture. Addressed by R-05.

## Dependencies and supply chain (DEPS)

**Strengths:** the dependency surface stays genuinely small and justified for a package-manifest-less, almost-entirely-Bash project — there is no npm/pip/gem/cargo ecosystem to lock, and `npm audit`-style scanning is genuinely inapplicable rather than skipped. `supercronic` and `shellcheck` remain pinned to an exact release tag *and* verified against a published checksum per architecture at build time.

### F-DEPS-01 — No update mechanism for agent-ops's own pinned dependencies · **Medium**

**Evidence:** `.github/dependabot.yml` still does not exist. Every version pin in `deploy/docker/Dockerfile` and `.github/workflows/*.yml` remains a hand-maintained literal.

**Impact:** the shellcheck/supercronic checksum pins will start *failing* the image build the day someone bumps one version literal without the matching checksum; GitHub Actions can drift indefinitely with no automated reminder.

**Direction:** add `.github/dependabot.yml` with at least a `github-actions` ecosystem entry. Addressed by R-07.

### F-DEPS-02 — Two Compose sidecar images float on `:latest` with no pin · **Medium**

**Evidence:** `deploy/docker/compose.yaml:406,573` (`tailscale/tailscale:latest`, `containrrr/watchtower:latest`) remain unpinned; the file's own comment calls watchtower "effectively unmaintained."

**Impact:** `docker compose pull` on two different nodes can silently fetch different sidecar binaries — undermining the "every node runs the same image" guarantee `README.md` states as the point of the container design.

**Direction:** pin both to a specific tag or digest. Addressed by R-07.

### F-DEPS-03 — `scripts/doctor.sh` Toolchain check omits `openssl` · **Low**

**Evidence:** `scripts/doctor.sh:706`'s toolchain loop omits `openssl`, despite `lib/approver-token.sh` hard-depending on it for RS256 JWT signing.

**Impact:** a node missing `openssl` gets no doctor warning and discovers the gap only when an Approver App token-mint attempt fails mid-cycle.

**Direction:** add `openssl` to the Toolchain loop, gated on `merge_autonomy` level. Addressed by R-10.

## Tooling and developer experience (TOOL)

**Strengths:** the container onboarding path is still accurate end to end — every file `README.md`'s "As a container" section cites exists exactly where cited. `scripts/doctor.sh` remains an unusually thorough preflight tool. One correction to the standing tech-debt record: `agent-cycle.sh` has carried a working `-h`/`--help` since its very first commit, contrary to `tech-debt/TD-PPagop-26082418.md`'s claim that it's one of four entry points missing one — only `review-cycle.sh`, `scripts/serve-dashboard.sh`, and `scripts/open-dashboard.sh` actually lack it.

### F-TOOL-01 — No `.editorconfig` and no `.shellcheckrc` · **Low**

**Evidence:** neither file exists anywhere in the tree.

**Impact:** minor for a single-maintainer project; the 2-space-indent convention exists only as convention.

**Direction:** optional low-cost addition. Addressed by R-12.

### F-TOOL-02 — No task-runner/Makefile; discoverability rests entirely on reading script headers · **Low**

**Evidence:** no `Makefile` exists anywhere; `lib/` (73 files) and `scripts/` (59 files) carry no index.

**Impact:** reasonable trade-off for a solo maintainer; no single entry point surfaces the full command surface at a glance.

**Direction:** a generated scripts index would be cheap if this becomes painful. Addressed by R-12.

### F-TOOL-03 — GitHub Actions pinned to version tags, not commit SHAs · **Low**

**Evidence:** every `uses:` line across all 11 workflow files references a mutable version tag, in contrast to the SHA/checksum verification the repo applies to `supercronic`/`shellcheck`.

**Impact:** a compromised or force-pushed tag on any of these actions would run with `contents: write`/`packages: write` on `main` pushes with no warning.

**Direction:** pin the highest-privilege actions to SHAs. Addressed by R-07.

## CI/CD and release engineering (CI)

**Strengths:** no file under `.github/workflows/` changed at all in the 13 commits since 857bc1d7. The branch-protection ruleset still requires the same 9 status-check contexts, runs a merge queue, and has `bypass_actors: []`. `scripts/lint-shell.sh` (the repo's own memory-guarded shellcheck wrapper) ran clean — 0 files skipped, corroborating that CI's shellcheck gate is current.

### F-CI-01 — The config-table check is still not an actual required merge gate, despite an owner decision to gate it · **Medium**

**Evidence:** `.github/workflows/config-table.yml` still has no `merge_group:` trigger; the ruleset's required-check list still excludes `config-table`. Per agent-ops#1144's comment trail, the owner has since *decided* to gate it (2026-09-04): a `merge_group:` trigger must land first, then the owner adds it to the ruleset by hand. Step one has not landed.

**Impact:** the exact drift class this check exists to catch is still only visibly flagged on a PR, not structurally prevented from merging.

**Direction:** add `merge_group:` to `config-table.yml`, following `tech-debt-register.yml`'s existing model; then the owner adds the required check. Addressed by R-02.

### F-CI-02 — One unpinned dependency in an otherwise fully-pinned image build · **Low**

**Evidence:** `deploy/docker/Dockerfile:46`: `ARG CLAUDE_CODE_VERSION=latest`, with an adjacent comment explaining the choice is deliberate.

**Impact:** the same commit SHA rebuilt on two different days can ship two different `claude` CLI versions — a conscious, documented trade-off.

**Direction:** none needed unless a future release actually breaks a cycle.

### F-CI-03 — CodeQL's security-scanning coverage is still limited to the `actions` language · **Low**

**Evidence:** matrix still has exactly one entry, `language: actions`.

**Impact:** an accurate, self-aware limitation; no Shell/Perl SAST coverage beyond shellcheck.

**Direction:** see agent-ops#976's own suggested direction. Addressed by R-18.

## Performance and scalability (PERF)

**Strengths:** this is an hourly-cron pipeline against the GitHub API, not a hot service, but the budget/rate-limit machinery is disproportionately mature for that profile. `lib/github-limit.sh` separates primary (stand-down) from secondary (wait-and-retry) rate-limit handling. Commit `b655e5a` moved four hot REST read-sets onto GraphQL; commit `bb29571` staggers the expensive-gather rotation across nodes. Commit `916a951`, the newest on `main`, fixed a real GitHub-pagination correctness bug (see F-TEST-03); a codebase-wide sweep found no other instance of the same bug class in a read-for-absence context.

### F-PERF-01 — `log.jsonl`'s union log is fast to read again, but its growth is still unbounded by design · **Low**

**Evidence:** `lib/stage-health.sh` documents a measured ~83s→~0.07s fix; `scripts/rotate-logs.sh` still deliberately never rotates `log.jsonl`, `review-log.jsonl`, or `revert-rate.jsonl`.

**Impact:** the constant-factor regression stays fixed, but growth is linear in fleet lifetime with no ceiling, unlike every other log this pipeline actively rotates.

**Direction:** no action needed now; queue a periodic size check with an archival plan before growth becomes visible again. Not covered by a dedicated recommendation this round.

### F-PERF-02 — `gh api --paginate`/`--slurp` calls still bypass the shim's conditional-read saving · **Low**

**Evidence:** `lib/gh-shim.sh` documents this as a known, deliberate scope limit (agent-ops#1114). `916a951`'s new `api_json_paged` is itself a fresh example inside the gap.

**Impact:** self-documented tech debt with a clear rationale; this cycle's bugfix marginally widened it in practice.

**Direction:** already tracked (agent-ops#1114); no new action needed. Not covered by a dedicated recommendation this round.

## Usability and accessibility (UX)

**Strengths:** the operator-facing CLI surface remains well documented where it exists — `agent-cycle.sh`'s `usage()` matches its actual `getopts` parse; `scripts/doctor.sh` likewise. The dashboard's PR-reference hover-cards keep correct keyboard support. The one dashboard change in this window (`a245a39`) is a clean example of a UI text change landing correctly across code, copy, spec, and fixtures together.

### F-UX-01 — Dashboard's clickable rows/cards are still mouse-only · **Medium**

**Evidence:** `dashboard/index.html` (now 3,516 lines) still has no `tabindex` attribute anywhere; the only `keydown` listener is unrelated to `.card.clickable`/`tr.clickable`.

**Impact:** a keyboard-only operator still cannot expand a cycle's detail row or filter by node card, the dashboard's two central interactions, while the PR-hover-card code a few hundred lines away does this correctly.

**Direction:** give the clickable elements `tabindex="0"`, `role="button"`, and a `keydown` handler, or promote them to real `<button>` elements. Addressed by R-03.

### F-UX-02 — `--help`/`usage()` coverage is inconsistent across the operator CLI surface · **Low**

**Evidence:** `review-cycle.sh`, `scripts/serve-dashboard.sh`, `scripts/open-dashboard.sh`, and `scripts/publish-dashboard.sh` have no `usage()`/`-h`/`--help` handling, while `agent-cycle.sh` and `scripts/doctor.sh` both have one.

**Impact:** low — solo-operator toolset with prose documentation in headers — but inconsistent with the sibling entry point that does answer `--help`.

**Direction:** extend the proven `usage()` pattern to the remaining four entry points. Addressed by R-12.

*Scope limitation: no automated accessibility checker (axe, Lighthouse) was available in this environment; F-UX-01 is assessed from static markup/JS reading only.*

## Documentation (DOC)

**Strengths:** the as-built-spec discipline `CLAUDE.md` mandates is demonstrably being followed, not just claimed. Two spot checks: `a245a39`'s `nice`-formula change landed consistently across code, dashboard copy, spec, and fixtures in one commit; `bf3d8d8` is documented at seven separate points across `docs/IMPLEMENTATION-PIPELINE-SPEC.md`. README's own navigation is adequate for its size.

### F-DOC-01 — `REVIEW-PIPELINE-SPEC.md`'s vendored-skill provenance stamp is still stale · **Medium**

**Evidence:** the spec still states a vendor date of 2026-07-19, but commit `86bfbea` (2026-08-01) synced real content changes into the skill without touching the provenance line — the staleness window has grown from ~2 weeks to ~5 weeks since the prior review.

**Impact:** per `CLAUDE.md`'s own rule that a spec/code disagreement is a bug, this gap is widening, not narrowing.

**Direction:** update the provenance line; add a lightweight drift-check modelled on `td-tooling-drift.yml`. Addressed by R-04.

### F-DOC-02 — The implementation-pipeline spec still has almost no internal navigation · **Low**

**Evidence:** the spec has grown to 22,998 lines with only 51 headings total; the `## Requirements` section (~13,400 lines) has exactly 9 sub-headings, one per actor.

**Impact:** content accuracy is not in question, but a document this size with no per-requirement navigation is a real obstacle to the bus-factor role these specs are assigned.

**Direction:** add sub-headings per requirement, or a generated table of contents. Addressed by R-17.

## Governance and project health (GOV)

**Strengths:** the `LICENCE` file is a clean, unmodified MIT text. Branch protection remains real and verifiable — one active ruleset, `enforcement: active`. The tech-debt register remains healthy (204 items, 95 open, 108 resolved, 1 not-debt, "consistent" per `td-check.pl`). Bus factor is a single human but unusually well mitigated by the density of as-built specs and an actively-maintained roadmap. *Verification note:* CODEOWNERS' two entries (`@warwickallen`, `@Warwick-Allen`) are two genuinely distinct GitHub accounts, deliberately separated so CODEOWNERS can auto-request review from an account that isn't the PR's own author — working as designed, not a gap.

### F-GOV-01 — No `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, or issue/PR templates · **Low**

**Evidence:** none exist anywhere in the repository. Fresh this window: `docs/ROADMAP.md`'s decision D5 was updated (`aba53a26`, 2026-08-28) to a firm decision — Functional Source License (FSL-1.1-ALv2), with a competing-use restriction and a two-year Apache-2.0 conversion clock — yet the actual `LICENCE` file is still plain MIT with no note that a change is planned.

**Impact:** the disclosure-route gap remains the sharpest edge; the licence angle has sharpened since the prior review — a made decision the public repository gives no outward sign of.

**Direction:** add a short `SECURITY.md`; add a brief note that a licence change to FSL-1.1-ALv2 is planned. Addressed by R-09.

## Observability and operations (OPS)

**Strengths:** ops maturity deepened this window. `83c48c4` adds `lib/memory.sh`, a free-host-memory stand-down gate built from real measurement and traced to a real incident lineage (a WSL2 host repeatedly freezing, #604). `af52c53` hardens `crash_loop_escalate` to re-verify before filing and retire broken loops. `e976842` is the project catching its own operational-reporting bug (`github-budget-report.sh`'s null-figure column shift) and fixing it same-day with a regression test.

### F-OPS-01 — The memory-cgroup "unbounded" verdict is detected but does not travel anywhere an operator would routinely see it · **Low**

**Evidence:** `lib/memory.sh`'s `memory_cgroup_verdict` reports `unbounded` for a state measured to hold 2465 MiB combined between two schedulers while idle. The verdict is surfaced only in `scripts/doctor.sh`'s Memory section, run by hand — no `log_event` call, no dashboard string. Already self-filed as `tech-debt/TD-PPagop-26090401.md`, whose own chosen remedy ("make the verdict travel") is not yet implemented.

**Impact:** the acute failure mode is caught by the stand-down gate added in the same commit, so this is secondary — but a roll silently reverts the manual `memory.high` fix with nothing to notice it.

**Direction:** implement the register item's own chosen remedy — log the cgroup verdict and surface it as a dashboard badge. Addressed by R-15.

### F-OPS-02 — No dedicated runbook/incident doc separate from inline header comments · **Low**

**Evidence:** incident and design knowledge continues to live entirely in source-file header comments — `lib/memory.sh`'s own header is a fresh, genuinely valuable example, undiscoverable except by opening that one file.

**Impact:** minor for the current single-maintainer audience, but every dimension's evidence this window keeps landing as another well-written header rather than an entry a reader would look first.

**Direction:** a short badge-to-explanation cross-reference, or a single `docs/RUNBOOK.md` index. Addressed by R-09.

## Data handling and privacy (DATA)

**Strengths:** the privacy model is explicit and consistently enforced: `scripts/serve-dashboard.sh` binds `127.0.0.1` by default; commit identity is sourced from operator-supplied environment variables and fails closed if unset; no credential or token value is ever written to a log line or the dashboard.

### F-DATA-01 — No explicit personal-data inventory, and the one log this pipeline deliberately never rotates carries the personal data it touches · **Low**

**Evidence:** no document enumerates what personal data the system touches. `log_event()` writes structured NDJSON regularly carrying GitHub logins as field values. `config.schema.json` documents that `log.jsonl`, `review-log.jsonl`, and `revert-rate.jsonl` are never rotated "regardless of size."

**Impact:** the personal data is GitHub usernames drawn from already-public activity, a low-regulatory-exposure domain — but "no inventory + one log with no retention ceiling" is worth stating explicitly as a pair.

**Direction:** a short data-inventory paragraph covering both the rotated logs and `log.jsonl`'s no-rotation policy. Addressed by R-09.

### F-DATA-02 — Test fixtures use the maintainer's own real GitHub usernames, not synthetic placeholders, contrary to the prior review's verification note · **Low**

**Evidence:** at least 19 test files and one dashboard-data fixture use `"warwick"`/`"warwickallen"`/`"Warwick-Allen"` as real login/actor/assignee values — the maintainer's actual, already-public GitHub identities, deliberately reused because several tests need to distinguish "the agent's own account" from "the human's second account."

**Impact:** very low in practice (self-referential, already public) — but it is real personal data in committed fixtures, and corrects a prior review's verification note that called the fixtures "obviously synthetic."

**Direction:** no action needed for risk reasons; optionally swap to an explicit placeholder, or correct future reviews' wording to "no third-party personal data." Addressed by R-16.
