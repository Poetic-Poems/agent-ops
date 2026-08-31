# Findings

29 findings were raised (plus two explicit verification notes recorded for transparency but
not counted as findings — no live secrets, no real personal data in fixtures). None are
Critical or High: this is a mature, actively-maintained, heavily-tested project, and it shows.

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 9 |
| Low | 20 |

## Architecture and design (ARCH)

**Strengths:** the single biggest architectural event since the prior review (8 days ago) is real and verified: commit `aaa32f4` (PR #771/#773, "refactor(agent-cycle): split into lib/ modules") carried out almost exactly the direction the prior review's F-ARCH-01/F-CODE-01 asked for — `agent-cycle.sh` fell from 9,920 lines to 3,341, `lib/` grew from 43 to 72 files, and the specific gather/exclude/coordinator families the prior review named by name now live in `lib/candidate-select.sh` and `lib/candidate-gather.sh` rather than inline. `docs/IMPLEMENTATION-PIPELINE-SPEC.md` was updated in the same effort (37 citations of `#771`) and matches the code exactly, including a sophisticated gotcha explaining why `scripts/lint-shell.sh` must measure the *sourced-union* line count rather than a file's own `wc -l` — verified against the script's actual constants. Two cross-tool seams were checked end-to-end and both hold: `scripts/publish-dashboard.sh`'s `data_json` and `dashboard/index.html`'s `DASHBOARD_DATA` agree on all 17 top-level keys, with `test/dashboard-render.test.sh` feeding real fixtures through the page's own unmodified JS. The newer `lib/expensive-gather-cache.sh`/`lib/candidate-gather.sh` seam is unusually well-reasoned about edge cases and has a dedicated test file. `lib/config-schema.sh` is a good example of proportionate engineering: a deliberately partial hand-rolled JSON-Schema validator, justified by the absence of any validator dependency beyond jq/git/perl/python3.

### F-ARCH-01 — `agent-cycle.sh`'s cycle body is still ~2,000 lines of undecomposed top-level flow, though reduced from ~3,400 · **Medium**

**Evidence:** `acquire_lock()` (the last function definition before the main flow) ends at `agent-cycle.sh:1377`; the file runs to line 3341 — roughly 1,950 lines of claim acquisition, all five stage dispatches, and cleanup execute at the top level with no enclosing function. `review-cycle.sh`, same author, same repo, keeps the equivalent flow to a 26-line loop (`review-cycle.sh:873–899`) calling a single `review_one()` function.

**Impact:** this remains the pipeline's highest-stakes, most-frequently-touched code, and the one part of `agent-cycle.sh` that cannot be unit-tested in isolation the way every `lib/*.sh` function now can.

**Direction:** extract the flow's major phases (claim, per-stage dispatch, cleanup) into named functions the way `review_one()` already models. Addressed by R-01.

### F-ARCH-02 — Small utility functions are still duplicated verbatim between `agent-cycle.sh` and `review-cycle.sh`, unchanged since the prior review · **Low**

**Evidence:** `expand_home()` is byte-identical at `agent-cycle.sh:405` and `review-cycle.sh:128`. `cfg()`/`cfg_json()` are identical one-liners at `agent-cycle.sh:430-431` and `review-cycle.sh:163-164`. `log_event()` is structurally identical at `agent-cycle.sh:844-856` and `review-cycle.sh:257-266`. This is the same duplication the prior review's F-ARCH-03 named, still present 8 days later.

**Impact:** low risk (4–13 line functions), but the one place the codebase's own "promote a shared rule to `lib/` and pin it" discipline — otherwise applied consistently — has not been applied.

**Direction:** move the three functions into a small `lib/` file. Addressed by R-02 (already tracked, see agent-ops#964).

## Code quality and maintainability (CODE)

**Strengths:** style discipline held up under a fresh, targeted search: zero genuine `TODO`/`FIXME`/`HACK`/`XXX` markers across `lib/`, `scripts/`, and both entry points (the 9 raw hits are all `mktemp` templates, a false-positive pattern). Header-comment density and quality remain very high in every file sampled — design decisions are tied to specific incidents and requirement numbers rather than left as bare assertions. `set -euo pipefail`/`local` discipline is consistent within each file. One prior finding (`set -e` convention drift, now 5/54 vs. the prior 5/47) is already tracked as open GitHub issue #974, and `agent-cycle.sh` has since gained the `--help`/`usage()` handling that record also asked for, though `review-cycle.sh`, `scripts/serve-dashboard.sh`, and `scripts/open-dashboard.sh` still lack it — partial progress on a tracked item, not a new gap.

### F-CODE-01 — The stage-orchestration functions the #771 split relocated into `lib/` grew larger rather than being decomposed further · **Medium**

**Evidence:** comparing to the prior review's own line counts: `maybe_run_enabler` 645→856 lines (`lib/enabler.sh:586`, 59% of its own 1442-line module), `run_approver_stage` 319→418 (`lib/approver.sh:518`), `_landing_stage_attempt` 283→360 (`lib/landing.sh:1248`), `maybe_run_refiner` 292→318 (`lib/refinement.sh:1172`). `maybe_run_enabler` alone declares 39 `local` variables across its guard clauses. By contrast, `lib/handoff.sh`'s largest function is 115 lines.

**Impact:** these five functions are exactly where the next Enabler/Refiner/Approver/landing behaviour change will land; moving them to their own files did not reduce their in-function branching complexity, and it grew during the same window the split happened.

**Direction:** next time one of these five is touched for a behaviour change, split its guard/claim/per-verdict sections into named helpers, as `lib/handoff.sh` already demonstrates. Addressed by R-01 (already tracked, see agent-ops#964).

### F-CODE-02 — `san()` (the claim-path sanitiser) remains copy-pasted, not shared, between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` · **Medium**

**Evidence:** `lib/claim.sh:119` and `scripts/sweep-orphan-branches.sh:147` both define `san() { local s="$1"; printf '%s' "${s//\//__}"; }` verbatim. `sweep-orphan-branches.sh` sources three other `lib/` files but not `lib/claim.sh`. This is the prior review's F-CODE-02, unaddressed 8 days later, and it currently has no dedicated tech-debt record (though agent-ops#967 covers the same class of duplication for other utilities).

**Impact:** a future change to `san()`'s encoding in `lib/claim.sh` would silently leave `sweep-orphan-branches.sh`'s claim-path lookups on the old encoding; a sweep matching claim paths incorrectly can delete a branch a peer node still holds.

**Direction:** source `lib/claim.sh` from `scripts/sweep-orphan-branches.sh` and delete the local copy. Addressed by R-02 (already tracked, see agent-ops#967).

### F-CODE-03 — `scripts/publish-dashboard.sh` (3,242 lines) and `scripts/doctor.sh` (1,842 lines) are almost entirely top-level flow with very few named functions · **Low**

**Evidence:** `publish-dashboard.sh` defines only 8 functions (largest 67 lines); `doctor.sh` defines only 3 (largest 30 lines). Neither went through anything like the #771 treatment.

**Impact:** lower urgency than F-CODE-01 since both are standalone operator scripts rather than the hourly-cycle hot path, and both carry substantial dedicated test coverage that already exercises this code directly.

**Direction:** no urgent action; worth the same phase-extraction treatment if either file's growth or change frequency rises. No dedicated recommendation (see worknotes/consolidated.md).

## Security (SEC)

**Strengths:** Token handling throughout `lib/github-app-token.sh`, `lib/approver-token.sh`, `lib/author-token.sh` and `lib/forge-auth.sh` is unusually disciplined for a bash codebase: JWTs and minted tokens travel to `curl` via `--config -` (stdin) rather than argv, the tmpfs-only token cache checks filesystem type and ownership before trusting a cache hit, and the Approver/Author App identities are architecturally separated so no single credential can both author and self-approve a pull request, with fail-closed kill switches. The egress fence (`deploy/docker/egress-allowlist.txt`, enforced via a Docker-internal network with no other route out) is a genuine defense-in-depth control, and every one of the 9 operating prompts carries an identical "Untrusted external content" block instructing agents to treat GitHub-sourced text as data, never instructions. `lib/gh-shim.sh` hashes `GH_TOKEN` rather than ever writing it to a cache key or log line.

### F-SEC-01 — Dashboard's `esc()` helper does not escape HTML and one call site feeds it into `innerHTML` · **Medium**

**Evidence:** `dashboard/index.html:307` defines `function esc(s) { return String(s == null ? "" : s); }` — despite its name, this is a plain string cast, no HTML entity-encoding. `dashboard/index.html:279` implements the `html:` attribute path as `e.innerHTML = attrs[k]`. `dashboard/index.html:2051`'s `kv()` is the one place `esc()`'s output reaches that path, fed `g.model`/`g.terminal_reason` (internal pipeline metadata, not GitHub-sourced text today). Every other `esc()` call site passes its result as a DOM child, which is correctly text-escaped regardless of `esc()`'s no-op behaviour.

**Impact:** not exploitable with attacker-controlled content today, and the dashboard binds to loopback/tailnet only — bounded blast radius. But the name is actively misleading: a future author rendering GitHub-sourced text through the `html:` path believing `esc()` sanitises it would introduce a real stored-XSS-style bug. A latent trap, not a live hole.

**Direction:** rename `esc()` to reflect what it does, or make it actually HTML-escape and audit the two `html:` call sites. Addressed by R-03 (already tracked, see agent-ops#965).

### F-SEC-02 — No `SECURITY.md` or documented vulnerability-disclosure route · **Low**

**Evidence:** no `SECURITY.md` anywhere in the repository; no disclosure email/process mentioned in `README.md`.

**Impact:** bounded — single-maintainer, MIT-licensed tooling repo — but the project wields autonomous merge authority over production repositories, so a third party spotting a flaw has no stated channel to report it.

**Direction:** add a short `SECURITY.md` naming a contact/route. Addressed by R-08 (already tracked, see agent-ops#973).

### F-SEC-03 — CodeQL scans only the GitHub Actions YAML, not the 304 shell scripts that are the actual attack surface · **Low**

**Evidence:** `.github/workflows/codeql.yml`'s own comment: "agent-ops is Shell/Perl/HTML, none of which CodeQL supports... there is no `javascript-typescript` (or other language) matrix entry here." The single `matrix.language` entry is `actions`.

**Impact:** an accurate, self-aware, tooling-limited gap rather than an oversight — but the code holding credential-handling and merge-authority logic has no automated security-scanning gate at all.

**Direction:** already documented as an accepted gap; consider a bash-aware SAST tool if one becomes practical. Addressed by R-13 (already tracked, see agent-ops#976).

*Verification note (not a finding): no live secrets found anywhere in the working tree or full git history — checked with pattern searches for GitHub tokens, AWS keys, private-key blocks, and `git log -S` over common secret markers. All hits were synthetic test fixtures.*

## Testing and quality assurance (TEST)

**Strengths:** the suite is unusually large and disciplined for a shell-scripted project: 171 files, ~67k lines, ~8,400 `assert_*` calls, all hand-rolled bash by deliberate documented choice. Of 18 test files run directly on the host across security/auth, merge/landing, dashboard, and tech-debt areas, all 18 passed. Tests are overwhelmingly regression tests tied to real production incidents cited by issue/PR number, and nearly every recent commit touches `test/` alongside the code change. Security-sensitive auth paths are tested with a real OpenSSL-signed JWT rather than a faked one. No test performs a real network call; only 10/171 files use `sleep` at all, always to drive a backgrounded stub/lock-contention scenario.

### F-TEST-01 — `lib/git-identity.sh` has no test coverage anywhere in the suite · **Low**

**Evidence:** no `test/*.test.sh` file references `git_identity`/`git-identity`. The 29-line file is the sole guard stopping an unattended cycle from committing under no identity or the wrong one (its header cites issue #76).

**Impact:** a regression here would only surface as a wrongly-attributed commit in production, not as a red CI check.

**Direction:** add `test/git-identity.test.sh`. Addressed by R-10.

### F-TEST-02 — Some individual test files are slow standalone (host-measured), with no faster-than-whole-file local option · **Low**

**Evidence:** `time bash test/config-schema.test.sh` → 1m48s (CPU-bound). `test/publish-dashboard.test.sh` (3,066 lines) ran 5+ minutes, deliberately driving real timed scenarios rather than faking the clock.

**Impact:** several minutes per local run for a developer iterating on one of these files. Docker was unavailable in the reviewing environment, so the containerized CI-equivalent suite (which may well be much faster) was never actually measured — these are host numbers, not a verified CI regression.

**Direction:** none required if CI's real wall-clock time is short; otherwise consider splitting the largest files. No dedicated recommendation (see worknotes/consolidated.md).

### F-TEST-03 — No coverage tooling; naive filename cross-reference is misleading · **Low**

**Evidence:** cross-referencing `lib/*.sh`/`scripts/*.sh` basenames against `test/*.test.sh` names naively flags ~19 lib files and ~14 script files as "untested"; deeper search shows most are in fact exercised, since tests are named by scenario/requirement, not by source file. No coverage tool (`kcov`, `bashcov`) is used anywhere.

**Impact:** neither this review nor the maintainer has a quantitative answer to how much of the riskiest paths (claim/merge concurrency, auth) is actually exercised.

**Direction:** low priority given bash coverage tooling is awkward; `kcov` can attach to bash if wanted. Addressed by R-10.

## Dependencies and supply chain (DEPS)

**Strengths:** the dependency surface is small and every OS-level tool is installed with an explanation of why. The one binary not sourced from a signed registry (`supercronic`) and CI-critical `shellcheck` are both pinned to a release tag *and* verified against a published checksum per architecture — genuine supply-chain diligence for a package-manifest-less project. `npm audit`-style scanning is inapplicable (no manifest to scan); the closest equivalent, CodeQL, is present (though narrowly scoped — see F-SEC-03).

### F-DEPS-01 — No update mechanism for agent-ops's own pinned dependencies · **Medium**

**Evidence:** no `.github/dependabot.yml`/Renovate config exists. `lib/dependabot-bump.sh`/`scripts/nudge-dependabot-rebase.sh` only handle Dependabot PRs in the *target* repos the pipeline operates on, not agent-ops's own dependencies. Every version pin here is a hand-maintained literal with no bot proposing bumps.

**Impact:** the shellcheck/supercronic checksums will silently start *failing* the build (not warn) the day someone forgets to bump both together; GitHub Actions could drift months out of date with no reminder.

**Direction:** add `.github/dependabot.yml` with at least a `github-actions` ecosystem entry. Addressed by R-05 (new: agent-ops#1145).

### F-DEPS-02 — Two Compose sidecar images float on `:latest` with no pin · **Medium**

**Evidence:** `deploy/docker/compose.yaml:637` (`tailscale/tailscale:latest`) and `:804` (`containrrr/watchtower:latest`) are unpinned, unlike every other version-sensitive dependency in the repo. The file's own comment already notes watchtower is "effectively unmaintained."

**Impact:** `docker compose pull` on two different nodes, or the same node weeks apart, can silently fetch different binaries — undermining the "every node runs the same image" guarantee the README states as the point of the container design.

**Direction:** pin both to a specific tag or digest. Addressed by R-05 (new: agent-ops#1145).

### F-DEPS-03 — `scripts/doctor.sh` Toolchain check omits `openssl` · **Low**

**Evidence:** `doctor.sh`'s Toolchain section checks 11 tools individually but never `openssl`, despite `lib/approver-token.sh` (agent-ops#407) hard-depending on it for RS256 JWT signing, called at 4 call sites.

**Impact:** a node missing `openssl` gets no doctor warning and discovers the gap only when an Approver App mint attempt fails mid-cycle — the exact class of failure doctor.sh exists to prevent.

**Direction:** add `openssl` to the Toolchain loop, gated on `merge_autonomy` level. Addressed by R-09 (new: agent-ops#1147).

## Tooling and developer experience (TOOL)

**Strengths:** the container onboarding path is accurate and traceable end to end — the documented bring-up files match what actually exists, and documented CLI flags were verified against the actual `getopts` parse and matched exactly. `scripts/doctor.sh` is an unusually thorough preflight tool. `scripts/run-tests.sh` gives a reproducible, credential-free way to run the whole suite inside a throwaway container built from the actual image, explicitly designed to avoid both host-`jq`-drift and stale-`docker exec` traps.

### F-TOOL-01 — No `.editorconfig` and no `.shellcheckrc` · **Low**

**Evidence:** neither file exists anywhere. Shellcheck is invoked with no shared config; suppressions live inline per file.

**Impact:** minor for a single-maintainer project; the 2-space-indent convention exists only as convention, not machine-readable config.

**Direction:** optional low-cost addition. Addressed by R-11 (already tracked, see agent-ops#974).

### F-TOOL-02 — No task-runner/Makefile; discoverability rests entirely on reading script headers · **Low**

**Evidence:** no `Makefile` exists; the 58 `scripts/` and 89 `lib/` files are discoverable only by directory listing plus reading each header — no scripts index, no consistent `--help` flag across every script.

**Impact:** reasonable trade for a solo maintainer given the header-comment convention already carries real information, but there's no single entry point surfacing the full command surface at a glance.

**Direction:** a generated scripts index, in keeping with the repo's existing generated-region pattern, would be cheap if this becomes painful. Addressed by R-11 (already tracked, see agent-ops#974).

### F-TOOL-03 — GitHub Actions pinned to version tags, not commit SHAs · **Low**

**Evidence:** every `uses:` line across `.github/workflows/*.yml` references a mutable version tag, in contrast to the deliberate SHA/checksum verification the same repo applies to `supercronic`/`shellcheck`.

**Impact:** a compromised or force-pushed tag on any of these actions would run with `contents: write`/`packages: write` on `main` pushes with no warning.

**Direction:** pin `actions/checkout`, `docker/build-push-action`, `docker/login-action` to SHAs (Dependabot, once added, can propose the bumps). Addressed by R-05 (new: agent-ops#1145).

*Note (not a finding): live-credential dependence for anything beyond the unit-test suite is inherent to this project's domain (real GitHub/Claude interaction), not a tooling deficiency.*

## CI/CD and release engineering (CI)

**Strengths:** CI is real, broad, and verifiably required — confirmed directly via the repository's branch-protection ruleset API (`gh api repos/Poetic-Poems/agent-ops/rulesets/18857310`), not inferred: 9 required status checks, a merge queue, a required PR review with `dismiss_stale_reviews_on_push`, native GitHub `code_scanning`/`code_quality` gates, `bypass_actors: []`. Every workflow carries an unusually thorough rationale comment citing the specific past incident it exists to stop. `build-image.yml` builds and tests both `linux/amd64` and `linux/arm64` on native runners and runs the *full* test suite inside the freshly built container before ever publishing. `scripts/lint-shell.sh` was run for real (308 scripts, pinned shellcheck 0.10.0): exit 0, clean. Versioning is a considered continuous-deployment scheme with a documented rollback path, and `CHANGELOG.md`'s `[Unreleased]` section was spot-checked against `git log` and matched exactly.

### F-CI-01 — The config-table check is not actually a required merge gate, despite being documented as one · **Medium**

**Evidence:** the ruleset's required-check list (above) does not include `config-table`, though `CLAUDE.md` describes it in gate language and the workflow exists to catch generated-doc drift from `config.schema.json`.

**Impact:** the exact drift class this check exists to catch is only visibly flagged on a PR, not structurally prevented from merging.

**Direction:** add `config-table` to the ruleset's required checks, or soften the documentation. Addressed by R-04 (new: agent-ops#1144).

### F-CI-02 — One unpinned dependency in an otherwise fully-pinned image build · **Low**

**Evidence:** `deploy/docker/Dockerfile:46`: `ARG CLAUDE_CODE_VERSION=latest`, with an adjacent comment explaining this is deliberate.

**Impact:** the same commit SHA rebuilt on two different days can ship two different `claude` CLI versions — a conscious, documented trade-off.

**Direction:** none needed unless a future release actually breaks a cycle, per the comment's own stated policy. No dedicated recommendation (see worknotes/consolidated.md).

### F-CI-03 — CodeQL's security-scanning coverage is limited to 11 workflow YAML files, not the ~122k-line codebase · **Low**

**Evidence:** same underlying gap as F-SEC-03 — CodeQL has no Shell/Perl support, so its one matrix entry only analyses the workflow YAML.

**Impact:** an accurate, self-aware limitation; the codebase's real attack surface has no SAST coverage beyond shellcheck.

**Direction:** see F-SEC-03. Addressed by R-13 (already tracked, see agent-ops#976).

## Performance and scalability (PERF)

**Strengths:** the `gh` transport shim (`lib/gh-shim.sh`) is a genuinely sophisticated rate-limit mitigation layer — conditional ETag reads, last-known-good serving, per-identity budget tracking — installed on `PATH` so it catches every `gh` call including ones a `claude -p` subprocess issues directly. `lib/expensive-gather-cache.sh` bounds what had been `repositories × nodes × cycles` GitHub read volume to one fresh read per node per cycle. A previously-real O(n²)-shaped hot path (event-log readers slurping and regex-splitting the whole log) has already been fixed in the checked-out code.

### F-PERF-01 — `log.jsonl`/union-log parsing is fast now, but the underlying growth is still unbounded by design · **Low**

**Evidence:** `lib/stage-health.sh:33-40` documents a real measured fix (~83s → ~0.07s on a 2.3 MB log); verified every named call site now uses the fast spelling. `scripts/rotate-logs.sh` deliberately never rotates `log.jsonl` ("the fleet's memory").

**Impact:** the constant-factor fix is real; the underlying shape (several readers scan the whole never-shrinking union log every cycle) will grow linearly forever with no cap, unlike every other log this pipeline rotates.

**Direction:** no action needed now; worth a periodic size check with an archival plan queued before it's visible in cycle latency. No dedicated recommendation (see worknotes/consolidated.md).

### F-PERF-02 — `gh api --paginate`/`--slurp` bypasses the shim's conditional-read saving · **Low**

**Evidence:** `lib/gh-shim.sh:79-108` documents this as a known, deliberate scope limit (agent-ops#1114).

**Impact:** limited — self-documented tech debt with a clear rationale, not an oversight.

**Direction:** already tracked; no new action needed. No dedicated recommendation (see worknotes/consolidated.md).

## Usability and accessibility (UX)

**Strengths:** the operator-facing CLI surface is unusually well documented — `agent-cycle.sh`'s `usage()` enumerates every flag with a rationale, and documented flags were verified against the actual `getopts` parse and matched exactly. `scripts/doctor.sh`'s four documented modes all exist verbatim, with a meaningful exit code on failure. The dashboard uses semantic HTML5, respects `prefers-color-scheme` for a real dark theme, and its one form control is properly `<label>`-wrapped.

### F-UX-01 — Dashboard's clickable rows/cards are mouse-only, and the gap isn't acknowledged anywhere · **Medium**

**Evidence:** `dashboard/index.html` builds interactive UI on non-interactive elements (`.card.clickable`, `tr.clickable`) with only a `click` listener — no `tabindex` anywhere in the 3,516-line file, and only one unrelated `keydown` hit. By contrast, the PR-reference anchors in the same file *do* get real keyboard support (`aria-describedby`, documented Enter-to-navigate behaviour), and `docs/DASHBOARD-SPEC.md` never mentions keyboard behaviour for the clickable cards/rows — not a documented, deliberate limitation.

**Impact:** the dashboard is the one human-facing UI in this repo; a keyboard-only pass cannot expand a cycle's detail row or filter tables by node — both central interactions — while the visually similar PR hover-cards work correctly by keyboard nearby in the same file.

**Direction:** give `.card.clickable`/`tr.clickable` `tabindex="0"`, `role="button"`, and a `keydown` handler, or promote them to real `<button>` elements. Addressed by R-06 (already tracked, see agent-ops#970).

*Scope limitation: no automated accessibility checker (axe, Lighthouse) was available in this environment; this dimension is assessed from static markup/JS reading only. A manual contrast calculation for the muted-text token (≈4.9:1) clears WCAG AA but was not tool-verified.*

## Documentation (DOC)

**Strengths:** README claims were spot-checked and held up in every case tried — CLI flags, `doctor.sh` flags, and the config-table generated regions (`scripts/render-config-table.sh --check` reports all four regions match `config.schema.json` cleanly, so `CLAUDE.md`'s warning against hand-editing them is not currently being violated). `CHANGELOG.md`'s `[Unreleased]` section names the two most recent merged PRs accurately. `docs/ROADMAP.md` was edited three times in the two days before HEAD — demonstrably current.

### F-DOC-01 — REVIEW-PIPELINE-SPEC.md's vendored-skill provenance stamp is stale, and the audit's own recommended follow-up was never filed · **Medium**

**Evidence:** `docs/REVIEW-PIPELINE-SPEC.md:118-121` states an upstream commit and vendor date for `.claude/skills/project-review/` that predates two content-changing edits to that skill (commits `86bfbea`/#144 and `5daa821`/#919), neither of which touched the provenance line. `docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md` item #15 already flagged the missing drift-check; no tech-debt record existed for it before this review.

**Impact:** per `CLAUDE.md`'s own rule that a spec/code disagreement is a bug, this is exactly that class of drift, sitting in the spec's as-built section.

**Direction:** update the provenance line; file the drift-check the audit already recommended. Addressed by R-07 (new: agent-ops#1146).

### F-DOC-02 — The 22,586-line implementation spec has almost no internal navigation, which undercuts its own bus-factor value · **Low**

**Evidence:** the spec is 1.67 MB / 22,586 lines with only 50 Markdown headings total; its `## Requirements` section (~13,100 lines) has just 9 `###` sub-headings, one per actor, each spanning thousands of lines with no per-requirement heading.

**Impact:** the content is accurate and rigorously cross-referenced — not a correctness problem — but a document this size with no table of contents is a real obstacle to the bus-factor role `CLAUDE.md` frames these specs as serving.

**Direction:** add sub-headings per requirement (or group), or a generated table of contents. Addressed by R-12 (already tracked, see agent-ops#971).

## Governance and project health (GOV)

**Strengths:** licence is a clean, unmodified MIT text with a correct copyright line; `CODEOWNERS` is unambiguous. The tech-debt register is unusually healthy for its scale: `perl scripts/td-check.pl` reports 203 items (consistent), no stale backlog (oldest open item filed ~9 days before this review). Bus factor is real (one human author) but unusually well mitigated by the density of as-built specs, an actively current roadmap, and the tech-debt register together.

### F-GOV-01 — No SECURITY.md or in-place-compromise runbook, despite the system holding live GitHub write and Anthropic API credentials · **Low**

**Evidence:** no `SECURITY.md`/`CONTRIBUTING.md`/`CODE_OF_CONDUCT.md`/issue-PR templates exist. README documents credential rotation only on the *decommission* path, with no procedure for rotating in place while keeping a node running.

**Impact:** this is an unattended system authenticating as a bot with real push/merge rights across production repos and a live Anthropic API key; an incident-response runbook is relevant to the maintainer's own operations even absent external contributors.

**Direction:** add a short compromise/incident-response note. Addressed by R-08 (already tracked, see agent-ops#973).

## Observability and operations (OPS)

**Strengths:** an unusually mature ops posture for a single-maintainer batch pipeline. Logging is uniform structured NDJSON with a hard schema contract. The health/liveness stack is real, not cosmetic: `lib/crash-loop.sh`, `lib/stage-health.sh`, and `lib/updater-health.sh` each trace to a specific real incident (2026-08-21, 2026-08-14) and detect genuinely subtle failure shapes. Timeout/retry policy on outbound calls is bounded and sane throughout — no silent infinite retries anywhere sampled. Workspace cleanup is layered (EXIT-trap plus an independent mtime-based reaper backstop, traced to a real 4.2 GB disk-fill incident). `scripts/github-budget-report.sh` and the dashboard give genuine GitHub-quota observability, cross-checked against `docs/DASHBOARD-SPEC.md` with no drift found.

### F-OPS-01 — Tech-debt register (and its migrated GitHub issue) reported a real perf bug as still open, after the fix had already landed · **Low — resolved during this review**

**Evidence:** `tech-debt/TD-PPagop-26082503.md` listed four call sites still on a slow `jq` spelling; all four, as checked out for this review, already use the fast spelling (fixed by commit `21ec741`/#792). The linked GitHub issue (agent-ops#982) was still open too.

**Impact:** low direct operational risk (the perf problem is fixed), but the register and its linked issue were giving false signal.

**Direction:** **Action taken directly during this review**: `tech-debt/TD-PPagop-26082503.md`'s frontmatter was flipped to `status: resolved`, `resolved: 2026-08-25`, `ref: #792`, per this review's own book-keeping mandate to update an already-resolved register item in place. `perl scripts/td-check.pl` confirms the register remains consistent. No recommendation/improvement-prompt needed.

### F-OPS-02 — No dedicated runbook/incident doc separate from inline design-decision comments · **Low**

**Evidence:** incident knowledge lives entirely in source-file header comments rather than a consolidated runbook; the dashboard's own badges don't link to the relevant explanation.

**Impact:** minor for the current single-maintainer audience, but not discoverable from the dashboard's own alerts.

**Direction:** a short badge-to-explanation cross-reference. Addressed by R-08 (new: agent-ops#1149).

## Data handling and privacy (DATA)

**Strengths:** the privacy model is explicit and consistently enforced: the dashboard is confirmed loopback/tailnet-only with no public URL ever minted; state retention is bounded by explicit config keys rather than growing unbounded; no credential or token value is ever written to a log line or the dashboard (verified — no `set -x` tracing found anywhere).

### F-DATA-01 — No explicit personal-data inventory, though exposure is low given the domain · **Low**

**Evidence:** no document enumerates what personal data the system touches (GitHub usernames, issue/PR authorship, commit identity).

**Impact:** bounded — the personal data is drawn from already-public GitHub repositories, mirrored only into private storage for operational purposes, a low-regulatory-exposure domain — but worth stating explicitly rather than leaving implicit.

**Direction:** a short data-inventory paragraph. Addressed by R-08 (already tracked, see agent-ops#975).

*Verification note (not a finding): `test/fixtures/` was sampled and uses obviously synthetic identifiers; no real personal data or dumps found embedded as fixtures.*
