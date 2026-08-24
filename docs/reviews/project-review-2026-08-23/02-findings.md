# Findings

39 findings across all 13 checklist dimensions, from a first `project-review` run against this repository. Every dimension applies to some degree; none was judged wholly inapplicable, though UX and DATA are proportionately light for a single-operator internal tool with a low personal-data footprint.

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 2 |
| Medium | 16 |
| Low | 20 |

## Architecture and design (ARCH)

**Strengths:** the layering is genuinely disciplined for a 42-day-old, single-author codebase: shared mechanics that must not diverge between the two pipelines are pulled into `lib/` and cited from both call sites (`lib/stage-run.sh`, `lib/cycle-state.sh`), each with a header comment naming the incident that made the sharing non-negotiable. The cross-tool seam most likely to drift — the final-message parser that `agent-cycle.sh`, `review-cycle.sh`, and `scripts/publish-dashboard.sh`'s jq port must agree on — is defended mechanically: `test/extract-json-result.test.sh` lifts all three implementations out of their source files and runs a shared case table through each. Configuration/secrets handling cleanly separates image-baked defaults from volume-persisted credentials and run-time env, and `docs/ROADMAP.md`'s own decisions already name the architectural erosion this review would otherwise flag as new, each with a tracked exit condition.

### F-ARCH-01 — `agent-cycle.sh` is a 9,920-line single-file pipeline holding 95 top-level functions · **Medium**

**Evidence:** `agent-cycle.sh` is 9,920 lines and defines 95 functions directly, on top of sourcing 43 `lib/*.sh` files. Candidate-gathering/filtering logic conceptually similar to what already lives in dedicated `lib/` files sits inline instead — e.g. `gather_merge_conflicts()` (line 2437), `gather_tech_debt()` (2727), `coordinator_eligible_items()` (1852), `exclude_blocked_or_void_items()` (1468) — alongside stage-orchestration, logging, and status-reporting code, all in one file.

**Impact:** at this size, the file is past what a single read-through can hold in working memory, which matters because this repo's own review discipline depends on a reader correlating a spec requirement number with the code that implements it. It also runs against `docs/ROADMAP.md`'s D6/D8 (strangler rewrite, eventual repo split) — the harder a monolithic entry point is to carve up, the more that migration costs when it starts.

**Direction:** when the D8 split is undertaken, use it as the forcing function to move the `gather_*`/`exclude_*`/`coordinator_*` families into `lib/` alongside their siblings. Addressed by R-02.

### F-ARCH-02 — A handful of functions inside `agent-cycle.sh` concentrate very large branching complexity, unlike the rest of the codebase · **Medium**

**Evidence:** `maybe_run_enabler()` (agent-cycle.sh:5326) is 645 lines with ~30 local variables; `coordinator_corroborate_retry_or_fallback()` (3437) is 328 lines, `run_approver_stage()` (3972) is 319, `maybe_run_refiner()` (6066) is 292, `_landing_stage_attempt()` (4471) is 283. By contrast, `lib/handoff.sh` decomposes comparable domain complexity into 17 functions averaging ~65 lines.

**Impact:** these five functions are where a future change to Enabler/Refiner/Approver/landing behaviour is most likely to land, and are the hardest to reason about locally — a genuine outlier against the rest of the codebase's own demonstrated decomposition style.

**Direction:** next time one of these five functions is touched for a behaviour change, split its guard/claim/per-verdict sections into named helpers the way `lib/handoff.sh` already does. Addressed by R-02.

### F-ARCH-03 — Small utility functions are duplicated between `agent-cycle.sh` and `review-cycle.sh` without the promotion-to-`lib/`-and-pin-with-a-test treatment applied to comparable duplication elsewhere · **Low**

**Evidence:** `expand_home()` is byte-identical in `agent-cycle.sh:343` and `review-cycle.sh:119`; `cfg()`/`cfg_json()` and `log_event()` differ only in a config variable or field name they close over. None has a shared `lib/` implementation or a pinning test, unlike `run_claude_stage` (extracted to `lib/stage-run.sh`) and `extract_json_result` (kept separate deliberately, but mechanically pinned to agree).

**Impact:** low risk in practice — these are 4–13 line functions unlikely to accumulate subtle divergence — but an inconsistent application of a principle the codebase otherwise treats as important.

**Direction:** move the shared shape into `lib/`, or note in one copy that the duplication is deliberate. Addressed by R-06.

## Code quality and maintainability (CODE)

**Strengths:** style is unusually disciplined for a 26,600-line, single-author-directed codebase: `[[ ]]` used exclusively, private helpers consistently underscore-prefixed and module-scoped, and all `# shellcheck disable=` suppressions carry inline reasons. `scripts/lint-shell.sh` is a genuine single source of truth for the CI gate — run directly in this review, it completed cleanly across all 248 tracked scripts, corroborating both this dimension's reading-based assessment and the CI dimension's own finding. Zero `TODO`/`FIXME`/`HACK` markers (re-verified) confirms debt is tracked in the register instead of left in comments.

### F-CODE-01 — `agent-cycle.sh`'s main flow is ~3,400 lines of undecomposed top-level script · **High**

**Evidence:** the two largest contiguous *non-function* regions of `agent-cycle.sh` are lines 6484–9360 (2,876 lines) and 9372–9920 (548 lines) — code running directly at the top level, containing dozens of nested `if`/`case` blocks (82 top-level openers in the first region alone). Small functions like `ensure_labels_for()` (defined inline at 9361) sit stranded inside this flow. `review-cycle.sh` (same author, same repo) decomposes fully into 19 named functions with no comparable block.

**Impact:** this is the pipeline's actual cycle body — claim acquisition, all five stage dispatches, cleanup — the highest-stakes, most-frequently-touched code in the repo, and the one part of `agent-cycle.sh` that cannot be unit-tested in isolation the way `lib/*.sh` functions are.

**Direction:** extract the main flow's major phases into named functions the way `review-cycle.sh` already does. Addressed by R-02.

### F-CODE-02 — `san()` (the claim-path sanitizer) is copy-pasted, not shared, between `lib/claim.sh` and `scripts/sweep-orphan-branches.sh` · **Medium**

**Evidence:** `lib/claim.sh:118` and `scripts/sweep-orphan-branches.sh:122` define the identical `san()` function verbatim. The latter sources other `lib/*.sh` files but not `lib/claim.sh`, and both build the same claim-registry path shape independently.

**Impact:** exactly the "rule with two implementations" failure shape this repo's own spec gotcha table warns about elsewhere. If `san()` ever changes in `lib/claim.sh`, `sweep-orphan-branches.sh` silently keeps the old encoding, its claim lookups start missing real claims, and it can delete a branch a peer node still owns.

**Direction:** source `lib/claim.sh` from `sweep-orphan-branches.sh` and delete the local copy. Addressed by R-06.

### F-CODE-03 — `set -e` is present in a minority of standalone `scripts/*.sh` files, with no documented rule for when to use it · **Low**

**Evidence:** of 47 `scripts/*.sh` files, 42 use `set -uo pipefail` and 5 use `set -euo pipefail`, and the split does not line up cleanly with read-only vs. mutating scripts. `docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s own gotcha table shows the project is aware `-e` is a hazard, but nothing documents when a new script should pick it.

**Impact:** low — organic drift, not a live bug — but the next standalone script has no signal for which convention to follow.

**Direction:** standardise on one default with the other as a commented opt-in, or document the rule in `scripts/lint-shell.sh`'s header. Addressed by R-15.

### F-CODE-04 — Several stage-orchestration functions in `agent-cycle.sh` carry very large local-variable surfaces · **Low**

**Evidence:** the largest named functions (`maybe_run_enabler`, `coordinator_corroborate_retry_or_fallback`, `run_approver_stage`, `maybe_run_refiner`, `_landing_stage_attempt`) are guard-clause-heavy but flat-scoped — `maybe_run_enabler` alone declares ~24 locals covering every one of its verdict branches. (Same functions as F-ARCH-02.)

**Impact:** a change to one code path is reasoned about against the same variable namespace as every other path in the function, raising the chance of an accidental shadow/reuse.

**Direction:** split guard-clause-partitioned phases into their own functions with narrower locals, at the next edit. Addressed by R-02.

## Security (SEC)

**Strengths:** the quoting/command-construction discipline is strong for a ~26,600-line Bash codebase — a targeted search for `eval`, unquoted interpolation, and injection-shaped patterns found nothing exploitable outside the finding below; `scripts/lint-shell.sh` runs shellcheck with zero blanket exclusions. The D18 trust ladder (`lib/landing.sh`, `lib/approver-token.sh`) is unusually rigorous about not trusting the pipeline's own good behaviour: it reconciles live GitHub branch-protection state and the Approver App's actual granted permissions before allowing autonomy above `human`, leaning on GitHub's own refusal of self-approval as the load-bearing control. The Docker supply chain pins/checksum-verifies binaries not from a signed apt repo, and `scripts/publish-dashboard.sh`'s `redact()` defensively strips token shapes and home-directory paths from the published dashboard payload.

### F-SEC-01 — Every pipeline stage runs with full tool access and a live write-scoped GitHub token while reading verbatim, untrusted text from public repositories · **Critical**

**Evidence:** `lib/stage-run.sh:207` launches every stage (Co-Ordinator, Implementer, Reviewer, Enabler, Refiner, Approver) with `claude_args=(-p --model "$model" --dangerously-skip-permissions --output-format stream-json --verbose)` — unrestricted bash/file/network tool access; no `--allowedTools`/`--disallowedTools`/permission-mode restriction exists anywhere. `deploy/docker/entrypoint.sh:77-87` puts a write-scoped `GH_TOKEN` (read/write on contents, pull requests, issues) into the container's process environment for its whole lifetime, readable by any subprocess including every `claude` child. The Coordinator's work-order JSON embeds untrusted content **verbatim**: `prompts/coordinator.md:58,343` — issue bodies and every comment, verbatim, into the Implementer's own prompt. No prompt in `prompts/*.md` frames this content as untrusted data (verified: no matches for "untrusted"/"prompt injection"/equivalent). All three acted-on repositories are confirmed **public** (`gh repo view` → `isPrivate: false` × 3), so any unauthenticated GitHub user can open an issue/comment/PR whose body becomes this verbatim input. No network egress allowlist exists anywhere in the deployment.

**Impact:** an anonymous internet actor can open an issue or PR comment on any of the three public repos with adversarial instructions (e.g. exfiltrate `$GH_TOKEN`, read local credentials). That text reaches a stage with full bash access, a live write-scoped token, and no technical barrier — only the prompt's English-language instructions stand in the way (`prompts/approver.md:87` itself acknowledges "nothing stops you mechanically"). Not bounded by the project's current single-user scale under this review's severity-weighting rule: the entry vector is any public GitHub account; the blast radius is full-repo compromise. GitHub's self-approval refusal and branch-protection reconciliation bound *merge*/*approve* specifically but do nothing to prevent token exfiltration or destructive `gh api` calls during, e.g., the Implementer stage.

**Direction:** frame externally-sourced GitHub content as untrusted data in the prompts; scope `claude`'s tool access away from `--dangerously-skip-permissions` at least for read-heavy/adversarial stages; add a network egress allowlist. Addressed by R-01.

### F-SEC-02 — `dashboard/index.html`'s `esc()` helper does not escape anything; two live `innerHTML` sites rely on it · **Medium**

**Evidence:** `dashboard/index.html:307` — `function esc(s) { return String(s == null ? "" : s); }` — no HTML-entity escaping despite the name. Most call sites are safe via `document.createTextNode`, but two flow into `innerHTML` via the `html:` attribute: `kv()` (line 1782) and a count-summary string (line 2063). Today both only carry pipeline-internal values — no live XSS found.

**Impact:** a broken abstraction that invites regression: a developer trusting `esc()`'s name could later route genuinely untrusted content through `kv()` and introduce stored XSS on a page exposed to everyone on the operator's Tailscale network.

**Direction:** rename `esc()` to reflect reality or make it a real escaper; audit both `html:` sites. Addressed by R-04.

### F-SEC-03 — No `SECURITY.md` or documented vulnerability-disclosure route · **Low**

**Evidence:** no `SECURITY.md` anywhere in the repo, none referenced from `README.md`/`CODEOWNERS`.

**Impact:** a researcher independently finding F-SEC-01 has no private channel and might default to a public issue on one of the very repos the pipeline autonomously actions.

**Direction:** add a short `SECURITY.md` naming a private contact. Addressed by R-14.

### F-SEC-04 — The `claude-code` npm package installs unpinned (`@latest`) at image build time · **Low**

**Evidence:** `deploy/docker/Dockerfile` (`ARG CLAUDE_CODE_VERSION=latest`), unlike the pinned/checksummed `supercronic`/`shellcheck` a few lines below. (Same fact as F-DEPS-02, from the dependency-management angle.)

**Impact:** every CI rebuild pulls the newest release of the dependency with the deepest reach (same access as F-SEC-01); a bad release reaches every subsequently-built node with no local pin to fall back to.

**Direction:** pin to a major/minor version. Addressed by R-07.

## Testing and quality assurance (TEST)

**Strengths:** for a project of this size, `test/` (140 files, ~52,017 lines) is an unusually thorough and well-engineered Bash test suite. The riskiest code paths — merge landing, merge autonomy/kill-switch, the Approver adjudication path, and the tech-debt claim/reservation locks — all carry proportionately deep coverage. Concurrency is tested for real rather than simulated: `test/claim.test.sh` races two literal background processes against a stub `gh` with true create-only semantics; `test/reserve-tech-debt-id.test.sh` does the same against a real bare git remote with 6 concurrent clones. "Wiring" tests extract the actual block under test verbatim out of `agent-cycle.sh` with `awk`, failing loudly if it has moved rather than silently testing a stale copy. Every sampled file ran clean directly on this host and asserts behaviour rather than implementation detail.

### F-TEST-01 — CI's test-suite step carries no timeout, unlike the local runner it mirrors · **Medium**

**Evidence:** `scripts/run-tests.sh` wraps every test in `timeout 600 bash "$t"`; `.github/workflows/build-image.yml`'s test-suite step runs the identical loop with no `timeout` at all, and no job sets `timeout-minutes`, so a hang is bounded only by GitHub Actions' default 6-hour job timeout. The suite includes tests exercising real signal/process-group handling with background `sleep` stand-ins — exactly what a watchdog-kill regression would turn into a genuine hang.

**Impact:** the one environment that actually gates a merge has the weakest hang protection; a regression could sit as a spinning, unexplained CI step for hours before anyone realises it isn't merely slow.

**Direction:** add `timeout-minutes:` to the build job. Addressed by R-08.

### F-TEST-02 — `publish-dashboard.sh` has no `--now` seam, so windowed-digest tests are coupled to the real clock, and this already caused a real merge-queue incident · **High**

**Evidence:** `scripts/publish-dashboard.sh` reads `now_iso` from the real clock with no override; every windowed reader derives from it. Siblings `publish-revert-rate.sh` and `autonomy-stage-report.sh` both take `--now` and their tests use fixed calendar dates; `publish-dashboard.sh` is the odd one out. Open tech debt `TD-PPagop-26082316` documents the consequence: PR #685's checks were green with fixed timestamps, over 24h later the merge queue re-ran the suite against a later clock, the fixture fell out of its rolling window, three assertions failed, and the PR was dequeued after a human had already approved the merge.

**Impact:** the one class of test-suite flakiness this review found direct production evidence of — green everywhere visible, then a delayed-action failure inside the merge queue after human sign-off.

**Direction:** give `publish-dashboard.sh` a `--now <iso8601>` option mirroring its sibling's. Already filed as `TD-PPagop-26082316` (open). Addressed by R-03.

### F-TEST-03 — Nine of 140 test files are severe runtime outliers, consuming the overwhelming majority of the suite's wall-clock time · **Medium**

**Evidence:** a full run of all 140 files directly on this host (no Docker; Ubuntu 24.04 + jq 1.7, matching the image's own base) completed 131 fast passes plus 9 outliers, each reproduced standalone and confirmed as a genuine pass (no correctness bug, just severe slowness): `doctor.test.sh` 6m23s, `toggle.test.sh` 5m41s, `review-not-before.test.sh` 4m49s, `publish-dashboard.test.sh` 4m25s, `review-claim.test.sh` 3m19s, `config-schema.test.sh` 3m02s, `role.test.sh` 2m54s, `state-sync.test.sh` 1m57s, `coordinator-input-wiring.test.sh` 1m22s — together ~34 minutes, against ~13 more minutes for the other 131 files combined. Estimated full-suite wall-clock: ~45–50 minutes. Several outliers directly invoke the real, unmodified `agent-cycle.sh`/`review-cycle.sh` as subprocesses rather than sourcing just the library function under test.

**Impact:** README.md states the suite "takes a few minutes"; on comparable hardware it takes closer to three-quarters of an hour, with 6.4% of files responsible for ~70% of that time. This undercuts the fast-filter workflow `scripts/run-tests.sh <filter>` is meant to provide, and a contributor unaware of the split could reasonably assume something is hung.

**Direction:** no correctness issue — update README.md's "a few minutes" framing to be accurate, and consider consolidating the outliers' repeated real-subprocess invocations into fewer calls. Addressed by R-08.

### F-TEST-04 — Deliberate fixture isolation can silently delete the one test covering the interaction it isolated away · **Low**

**Evidence:** open tech debt `TD-PPagop-26082302` records that clearing ambient `PULLWRIGHT_APPROVER_APP_ID`/etc. in `test/config-schema.test.sh`'s fixture helper (to stop leakage into unrelated fixtures) had the side effect of making `doctor.sh`'s reconciliation between that variable and `approver_app_id` invisible to the whole suite.

**Impact:** small and already tracked, but worth naming as a pattern: the suite leans on blanket-clearing for fixture independence — the right default — but nothing catches the moment a clearing step deletes the last coverage of the rule it clears away.

**Direction:** land the fix `TD-PPagop-26082302` already proposes. Addressed by R-08.

## Dependencies and supply chain (DEPS)

**Strengths:** every binary runtime component (`supercronic`, `shellcheck`, `gh`, Node.js) is pinned to a specific version with cryptographic checksum verification or retrieved from a GPG-verified repository. The Dockerfile serves as an effective lockfile substitute in a project with no package manager, and the entire system deploys as an immutable container image built on every merge rather than by pulling a branch onto a live node. Ubuntu 24.04 LTS is a current base.

### F-DEPS-01 — OS packages installed without version pins · **Medium**

**Evidence:** `deploy/docker/Dockerfile` installs base packages (`jq`, `curl`, `python3`, `perl`, `git`, etc.) via unpinned `apt-get install -y`, in contrast to the deliberate version+checksum pinning used a few lines away for `supercronic`/`shellcheck`.

**Impact:** two builds of the same commit, days apart, can produce different images if Ubuntu ships security updates in between — undermining the reproducibility the image-as-artefact deployment model relies on.

**Direction:** pin the base image to a digest, or document the OS-package layer as intentionally floating. Addressed by R-07.

### F-DEPS-02 — The `claude` CLI installs at `latest`, unpinned · **Medium**

**Evidence:** see F-SEC-04 (same fact, dependency-management angle).

**Impact:** see F-SEC-04.

**Direction:** pin to a major/minor version. Addressed by R-07.

### F-DEPS-03 — No Dependabot config for agent-ops' own dependencies · **Low** (informational, not a gap)

**Evidence:** no `.github/dependabot.yml`; `lib/dependabot-bump.sh` handles Dependabot PRs for the *target* repositories the pipeline maintains, not agent-ops itself.

**Impact:** none — agent-ops has no package-manager dependencies for Dependabot to track.

**Direction:** no action needed; noted so the absence reads as deliberate.

## Tooling and developer experience (TOOL)

**Strengths:** self-documenting scripts are the norm — most entry points carry substantial header comments explaining purpose, design decisions, and exit codes. `scripts/doctor.sh` is a genuinely mature diagnostic tool, validating config, toolchain, GitHub access, and Claude credentials, and publishing status JSON the dashboard consumes. Setup is documented end to end, and container-native deployment removes an entire class of "works on my machine" drift.

### F-TOOL-01 — `--help` is inconsistent across entry points · **Low**

**Evidence:** `scripts/doctor.sh`, `scripts/preview-deploy.sh`, and `scripts/lint-shell.sh` have explicit `usage()` functions; the two main cycle entry points, `agent-cycle.sh` and `review-cycle.sh`, do not.

**Impact:** minor discoverability gap.

**Direction:** add the same convention to both entry points. Addressed by R-15.

### F-TOOL-02 — No single unified task runner (Makefile or equivalent) · **Low**

**Evidence:** no `Makefile`; common tasks are each a separate documented script.

**Impact:** minor — a newcomer must read README.md or list `scripts/` to discover the right entry point.

**Direction:** optional thin `Makefile` wrapping existing scripts. Addressed by R-15.

### F-TOOL-03 — No `.editorconfig` · **Low**

**Evidence:** none exists, despite shellcheck being CI-enforced for correctness (not formatting).

**Impact:** editors have no machine-readable formatting hint for the ~250 shell scripts.

**Direction:** add a minimal `.editorconfig`. Addressed by R-15.

### F-TOOL-04 — Local development has no offline/mocked path · **Medium**

**Evidence:** running the pipeline locally requires Docker, a live GitHub token, a configured git identity, Tailscale, and Claude credentials; the test suite intentionally runs inside the project's own built image rather than against a mock; no mocked GitHub API fixtures exist for exercising pipeline logic without live credentials.

**Impact:** proportionate today for a single-operator tool, but friction for any future contributor iterating on pipeline logic without full production-shaped infrastructure.

**Direction:** not urgent given the current audience; worth revisiting as the roadmap's productisation brings in contributors. Addressed by R-13.

## CI/CD and release engineering (CI)

**Strengths:** ten distinct GitHub Actions workflows each serve a specific, well-documented purpose. `build-image.yml` uses architecture-native runners for both `arm64` and `amd64`; documentation-only changes bypass the expensive image build. Every PR-triggered workflow uses `pull_request`, never `pull_request_target`, so a fork PR never runs with write-scoped secrets. Branch-protection assumptions are checked at runtime by `scripts/doctor.sh` rather than trusted blindly. Dev/prod environment parity is structural: the same image serves every node role.

### F-CI-01 — No semantic versioning or release tags · **Low**

**Evidence:** images are tagged `:latest` and `:<commit-sha>` only; no git tags or `vX.Y.Z` scheme; `CHANGELOG.md` uses only an "Unreleased" section.

**Impact:** proportionate for an internal ops tool where the commit SHA is a perfectly good version identity — but no human-readable version string exists.

**Direction:** low priority; worth adopting only if productisation reaches external customers. No recommendation filed.

### F-CI-02 — CodeQL coverage is limited to workflow YAML, not the Shell/Perl codebase · **Low**

**Evidence:** `.github/workflows/codeql.yml` explicitly scans only the `actions` language, noting CodeQL has no Shell/Perl support; the ~27,000 lines of `lib/`, `scripts/`, and the two entry points have no SAST coverage beyond shellcheck's style/correctness checks.

**Impact:** a security-relevant shell pattern would not be caught by any automated scanner — a genuine tooling gap in the shell/Perl ecosystem, not an oversight.

**Direction:** consider a shell/Perl-aware SAST tool (e.g. Semgrep). Addressed by R-17.

## Performance and scalability (PERF)

**Strengths:** this project has an unusually well-corroborated discipline around the antipattern this review looked hardest for — serial subprocess forking and unbounded-argv delivery to `jq`. The trail from `TD-PPagop-26072201` through five further resolved items is a genuine grep-and-resweep habit, every converted site carrying its own regression test. No remaining unconverted instance of that pattern was found in `scripts/publish-dashboard.sh`, `scripts/gather-*.sh`, or `lib/fleet.sh`.

### F-PERF-01 — `publish-revert-rate.sh`'s cumulative pass re-mines every merged PR since baseline, from scratch, daily, forever · **Medium**

**Evidence:** `scripts/publish-revert-rate.sh`'s `cumulative` window binds `--since` to a fixed 2026-08-15 baseline, unlike its `rolling`/`recent` windows which use a constant-size offset from "now" — its mined population grows every day. Already tracked as open tech debt `TD-PPagop-26082204`.

**Impact:** silent, unbounded growth against the shared GitHub API rate-limit budget.

**Direction:** already scoped in TD-PPagop-26082204. Addressed by R-10.

### F-PERF-02 — D14's per-container resource budgets are aspirational, not enforced · **Low**

**Evidence:** `docs/ROADMAP.md`'s own D14 checklist is unchecked for this item; `deploy/docker/compose.yaml` has no `mem_limit`/`cpus`/`deploy.resources` block.

**Impact:** low urgency for a single-operator installation on its own hardware.

**Direction:** none needed beyond the roadmap's own plan. No recommendation filed.

### F-PERF-03 — `log.jsonl`, `review-log.jsonl`, `revert-rate.jsonl` are deliberately never rotated, with no compaction plan yet · **Low**

**Evidence:** `scripts/rotate-logs.sh` explicitly excludes these three; `docs/ROADMAP.md` D21's checklist already names bounded retention for them as future work.

**Impact:** low risk today given current fleet size/frequency.

**Direction:** none needed near-term; D21 already plans this. No recommendation filed.

## Usability and accessibility (UX)

**Method caveat:** no browser or axe-core tooling is available in this environment; the assessment is from reading markup/CSS/JS only, cross-checked against `docs/DASHBOARD-SPEC.md`.

**Strengths:** the dashboard shows unusually deliberate accessibility craft for a solo-operator tool — one shared `tableOf()` helper is the sole place tables are built, so every table gets real semantic markup; the PR-reference card uses `role="note"` + `aria-describedby` with full keyboard support; CSS comments record deliberate non-colour affordances; the page respects `prefers-color-scheme`. Hand-computed contrast for sampled colour pairs clears WCAG AA. `scripts/doctor.sh` is a model CLI with a documented three-verdict exit-code contract.

### F-UX-01 — Clickable table rows and fleet cards have no keyboard equivalent · **Medium**

**Evidence:** three interactive click targets (cycle-detail rows, void-item rows, fleet-node cards) are plain elements styled only with `cursor:pointer` — none sets `tabindex`, `role="button"`, or a `keydown` handler. By contrast, the PR-reference-card widget is built on native `<a>` anchors and inherits focus/Enter-activation, and its keyboard support is explicitly documented in the spec; the other three widgets are described only in terms of clicking.

**Impact:** this is the project's one real interactive UI. A keyboard-only user cannot expand any cycle's stage detail, cannot read a truncated void item's full text, and cannot filter the fleet/log to one node.

**Direction:** give `.clickable` rows/cards `tabindex="0"`, `role="button"`, and a `keydown` handler, mirroring the PR-reference card's pattern. Addressed by R-11.

### F-UX-02 — Cost-window `<select>`'s label has no programmatic association · **Low**

**Evidence:** `costWindowControl()` builds a `<label>` as a plain sibling of the `<select>`, not wrapping it, with no `for`/`id` pair — unlike the auto-refresh checkbox elsewhere in the same file, correctly nested.

**Impact:** minor; a screen reader querying the `<select>` directly hears an unlabelled combobox.

**Direction:** wrap the select in the label, or add a matching `for`/`id`. Addressed by R-16.

### F-UX-03 — Two operator scripts have no `--help`, unlike the rest of `scripts/` · **Low**

**Evidence:** `scripts/serve-dashboard.sh` and `scripts/open-dashboard.sh` handle no `-h`/`--help`, unlike sampled peers (`doctor.sh`, `watch-node.sh`, `run-tests.sh`, `state-sync.sh`).

**Impact:** low — both still fail with clear stderr messages and correct exit codes when misused.

**Direction:** add a one-line `-h`/`--help` case to both. Addressed by R-15.

## Documentation (DOC)

**Strengths:** the config-table generation discipline and the review-pipeline spec both passed direct, evidence-based verification with no drift found. Inline commentary throughout sampled `lib/` files is proportionate, tied to real incidents, and readable as institutional memory. `CHANGELOG.md` is actively maintained.

### F-DOC-01 — README.md and the 17,320-line implementation spec have no table of contents · **Medium**

**Evidence:** README.md has 89 headings across 2,381 lines and already relies on internal jump-navigation, yet no document under `docs/` or the README has a ToC. `docs/IMPLEMENTATION-PIPELINE-SPEC.md` alone is 17,320 lines. README.md also carries a large, explicitly-labelled dead section ("legacy, decommissioned", ~75 lines) that adds scroll cost.

**Impact:** a reader has no way to see a document's shape without scrolling or grepping.

**Direction:** add a generated or hand-maintained ToC, in the spirit of `scripts/render-config-table.sh`. Addressed by R-12.

**Verification note (not a defect):** `scripts/render-config-table.sh --check` passed clean; two sampled config keys matched the schema exactly; three `REVIEW-PIPELINE-SPEC.md` requirements matched `review-cycle.sh`/`prompts/project-reviewer.md` verbatim. Recorded because CLAUDE.md's "as-built, kept in sync" discipline held up under direct verification.

**CONTRIBUTING.md — absent, and genuinely inapplicable:** the repo has one human operator and sole `CODEOWNERS` entry; `CLAUDE.md` already documents the PR/branch convention for the benefit of the autonomous agents that are this repo's actual "contributors." Worth adding once the roadmap's productisation reaches external contributors, not before.

## Governance and project health (GOV)

**Strengths:** governance is unusually mature for a system at this stage. `CLAUDE.md` documents branch workflow and tech-debt process with precision; four as-built specs serve as both requirement authority and a de facto succession document; the tech-debt register is CI-validated and internally consistent; zero TODO/FIXME/HACK code markers; `docs/ROADMAP.md` records 23 dated, numbered product decisions that read as genuinely current.

### F-GOV-01 — Current MIT licence does not match the roadmap's stated future licensing intent · **Low**

**Evidence:** `LICENCE` (MIT) vs. `docs/ROADMAP.md` decision D5: "Source-available (BSL/FSL-family) … the exact licence is an open question with a Phase 1 decide-by gate."

**Impact:** not a current defect, but a forward-looking gap — nothing signals to a reader that the licence is expected to change.

**Direction:** note the pending licence decision in README.md or the roadmap's summary. Addressed by R-14.

### F-GOV-02 — No CONTRIBUTING.md · **Low**

**Evidence:** none exists; `CLAUDE.md` is written for an operating AI agent, not a human contributor.

**Impact:** currently inapplicable in practice, but no contributor-facing document is waiting for the roadmap's planned external contributors.

**Direction:** low priority until productisation brings a second contributor. Addressed by R-14.

### F-GOV-03 — No issue/PR templates · **Low**

**Evidence:** no `.github/ISSUE_TEMPLATE/` or `.github/PULL_REQUEST_TEMPLATE.md`.

**Impact:** the `Priority` field central to work ordering has nothing on the issue-creation path prompting a filer to set it, though it defaults safely to `Medium`.

**Direction:** add templates once contributors beyond the operator exist. Addressed by R-14.

**Bus factor and succession, by design rather than by neglect (not a numbered finding):** 443 of 451 commits share one author email, across two author-name spellings confirmed to be the same identity (not two accounts, so `CODEOWNERS`' two entries are not a duplicate-approval hazard). This is the project's deliberate operating model, not an ordinary solo-maintainer risk pattern — and the succession question this review actually asked (could a second operator pick this up?) has a favourable answer given the documentation depth already in place.

## Observability and operations (OPS)

**Strengths:** retry/degradation handling for the pipeline's two external dependencies (GitHub, Claude) is genuinely well-designed: `lib/github-limit.sh` distinguishes primary vs. secondary rate limits and shadows `gh` fleet-wide; `lib/limit-detect.sh` centralises Claude's own limit detection, explicitly citing a prior drift bug as the reason. `lib/crash-loop.sh` is a strong fleet-wide health signal, built specifically because a real historical outage looked like a healthy idle fleet until it existed. `scripts/doctor.sh` is a real, separate health check, not just the dashboard. Logging is structured JSONL via one shared, tested function. All three findings below are already self-identified as open tech debt within 24–48 hours of the review date.

### F-OPS-01 — `issue_priority_apply` discards the GraphQL error, so a failed Priority write cannot be diagnosed from the logs · **Medium**

**Evidence:** `lib/issue-priority.sh`'s `issue_priority_apply` sends its mutation with its error output discarded, collapsing any failure to a bare `mutation-failed` reason. Open tech debt `TD-PPagop-26082322` documents a real incident: a one-token schema mismatch made every Priority write fail identically, and one node accumulated 14 identical unhelpful warnings over three days before anyone read the actual GraphQL error.

**Impact:** directly demonstrated — a precise, actionable error message was discarded while a real defect ran fleet-wide undetected.

**Direction:** already scoped — capture the mutation's stderr into the result. Addressed by R-09.

### F-OPS-02 — `github_auth_probe` classifies a missing `GH_TOKEN` as "unreachable," so an unset token still buys full Co-Ordinator cycles indefinitely · **Medium**

**Evidence:** `github_auth_probe` only classifies a credential fault on an explicit 401 match; an unset token fails with a message matching neither pattern, so it reports `unreachable` rather than `unauthorized`. Open tech debt `TD-PPagop-26082306` documents that a full Co-Ordinator engagement then runs every cycle whose every claim fails.

**Impact:** a token dropped from the environment silently keeps spending model tokens every cycle forever, with no stand-down.

**Direction:** already scoped — extend the probe's classification. Addressed by R-09.

### F-OPS-03 — Requirement 17f's traceability verdict is unobservable in both failure directions · **Medium**

**Evidence:** `refinement_traceability_fault` tests for verbatim containment of refinement text. Open tech debt `TD-PPagop-26082307` documents two silent failure modes: ordinary paste drift defeats the containment test with no warning or dashboard signal, and the comment re-fetch swallows its own failure, disarming the whole check while it still reads as passing.

**Impact:** demonstrated — a stalled issue was invisible until a human went looking by hand through raw cycle logs.

**Direction:** already scoped — tolerate paste drift in the comparison, surface a warning on fetch degradation. Addressed by R-09.

## Data handling and privacy (DATA)

**Strengths:** the data actually stored is limited to GitHub logins, titles, and timestamps already public via the GitHub API. `scripts/publish-dashboard.sh`'s `redact()` is a genuine, if narrow, defence-in-depth layer against token leakage into the one artefact that leaves the node's private network. `test/fixtures/` contains no real personal data or plausible real credentials.

### F-DATA-01 — State-repo sync carries full raw logs/transcripts to a second GitHub repository with no redaction pass · **Medium**

**Evidence:** `scripts/state-sync.sh`'s push path pushes `log.jsonl`, `review-log.jsonl`, `cycles/`, `reviews/`, and cron logs — full per-stage transcripts — to a private state repo, with no call to anything resembling `redact()`.

**Impact:** unlike the dashboard path, nothing backstops a token or secret that ends up in a stage's stdout/stderr before it is committed, unredacted, to a second repository and retained indefinitely.

**Direction:** apply the same (or an equivalent) redaction pass to `state-sync.sh`'s push. Addressed by R-05.

### F-DATA-02 — No documented inventory of the personal/sensitive data this project touches · **Low**

**Evidence:** no file catalogues what GitHub usernames, PR/issue content, or token material the pipeline touches, stores, or retains.

**Impact:** low today given the single-operator audience and already-public data touched; will matter more once the roadmap's multi-tenant generalisation proceeds.

**Direction:** a short data-inventory section ahead of onboarding any non-Poetic-Poems installation. Addressed by R-16.
