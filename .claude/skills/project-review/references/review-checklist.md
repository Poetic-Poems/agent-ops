# Review checklist, by dimension

Work through every dimension below. The bullet points are prompts for investigation, not a form to fill in: pursue whatever the project's own evidence makes important, and skip lines that plainly do not apply — but if a whole *dimension* is inapplicable, record that judgement explicitly in the findings document rather than leaving the reader to wonder whether it was forgotten.

Each dimension has a short code, used in finding IDs (`F-<CODE>-<NN>`).

## ARCH — Architecture and design

- Is there a discernible architecture (layers, modules, services), and is it followed consistently, or has it eroded?
- Are boundaries and responsibilities clear? Look for god objects, cyclic dependencies, business logic in presentation layers, duplicated subsystems.
- Is the architecture proportionate to the problem — neither an under-engineered tangle nor speculative complexity (needless microservices, premature abstraction)?
- How are configuration, secrets, and environment differences handled architecturally?
- Are there architectural decision records (ADRs) or design documents, and do they match reality?
- How hard would the most plausible next requirements be to accommodate?
- **Cross-tool seam consistency.** Where two or more components communicate through a shared file format, on-disk artefact, or wire protocol rather than a shared function call (a writer script and a reader script, a producer and consumer CLI, a client and server), read *both* sides rather than inferring one from the other's docstring or tests, and check that they actually agree on the shape. Then check whether any test exercises the seam end-to-end (round-trips real data through the format/protocol) or whether each side is only tested in isolation against its own assumptions — the latter lets the two drift apart with a fully green suite.

## CODE — Code quality and maintainability

- Consistency: naming, style, idioms, formatting. Is a formatter/linter enforced, or does style drift by author?
- Complexity hot-spots: very long files or functions, deep nesting, high fan-in/fan-out. Identify the worst offenders by name.
- Duplication: copy-pasted logic that has already begun to diverge is a specific, reportable hazard.
- Error handling: swallowed exceptions, bare catches, inconsistent error types, missing handling on I/O boundaries.
- Dead code, commented-out code, TODO/FIXME/HACK markers (count them; read a sample — they are self-reported tech debt).
- Type discipline where the language offers it (type hints, strictness flags, `any`-escape-hatches).

## SEC — Security

- Secrets in the repository: search for API keys, passwords, tokens, private keys — in code, config, examples, and (where feasible) git history. A found secret is automatically `Critical`.
- Input handling: injection risks (SQL, command, path traversal, template), deserialisation of untrusted data, file-upload handling.
- Authentication and authorisation: how are identities established, sessions handled, permissions checked? Look for missing checks on individual endpoints.
- Cryptography: home-rolled crypto, weak algorithms, hard-coded IVs/salts, misuse of randomness.
- Web concerns where applicable: XSS, CSRF, CORS configuration, security headers, cookie flags.
- Dependency vulnerabilities: run the ecosystem's audit tool where possible (`npm audit`, `pip-audit`, `cargo audit`, `bundler-audit`, `govulncheck`, OWASP dependency-check).
- Is there a `SECURITY.md` / disclosure route? Are security-relevant defaults safe?

## TEST — Testing and quality assurance

- What kinds of tests exist (unit, integration, end-to-end, property, snapshot), and in what proportion?
- Coverage — measured if tooling allows, estimated by inspection otherwise. More important than the number: are the *riskiest* paths tested (money, auth, data mutation, concurrency)?
- Test quality: do tests assert behaviour or implementation detail? Are there flaky patterns (sleeps, real network calls, order dependence)?
- Do the tests actually run, and do they pass? A failing or unrunnable suite is itself a high-severity finding.
- Is there a sensible local test workflow (fast subset, watch mode) and a CI gate?

## DEPS — Dependencies and supply chain

- How many direct dependencies, and are they justified? Flag trivial dependencies and abandoned ones (no release in years, archived repos).
- Are versions pinned or locked (lockfiles committed)? Is there a reproducible build?
- Outdatedness: how far behind are the major dependencies? Any deprecated or end-of-life runtimes?
- Licence compatibility of dependencies with the project's own licence.
- Update mechanism: Dependabot/Renovate or nothing?

## TOOL — Tooling and developer experience

- Can a newcomer go from clone to running project by following written instructions? Actually attempt or trace this path.
- Build system health: speed, reliability, clarity of tasks (`make`, npm scripts, task runners).
- Editor/IDE support: formatter and linter configs committed, editorconfig, devcontainer or environment files.
- Local development affordances: seed data, docker-compose, mock services, hot reload.

## CI — CI/CD and release engineering

- Does CI exist, and what does it gate: lint, type-check, tests, builds, security scans?
- Is CI green, fast enough to be tolerated, and required before merge?
- Release process: versioning scheme, changelog discipline, tags/releases, automated or manual publishing.
- Deployment (where applicable): reproducibility, rollback story, environment parity.

## PERF — Performance and scalability

- Algorithmic red flags in hot paths: N+1 queries, quadratic loops over unbounded data, synchronous I/O in request handlers.
- Resource handling: connection pooling, unclosed resources, unbounded caches or queues, memory growth patterns.
- Are there benchmarks, load tests, or performance budgets? Are there known limits documented?
- Judge proportionately: micro-optimisation matters little in a CLI tool run monthly; it matters greatly in a hot service.

## UX — Usability and accessibility

- For user interfaces: keyboard navigability, semantic HTML/ARIA, colour-contrast, focus management, form labelling and error messaging. Run an automated accessibility checker (e.g., axe) where feasible — and note that automated checks catch only a minority of issues.
- For CLIs: `--help` quality, sensible defaults, exit codes, error messages that say what to do next.
- For APIs and libraries: consistency of naming and shape, quality of error responses, discoverability, examples that actually run.
- Internationalisation and localisation, where the audience warrants it.
- If the project has no human-facing surface at all, record the dimension as inapplicable and say why.

## DOC — Documentation

- README: does it say what the project is, who it is for, how to install, how to use, and where to get help — accurately?
- Reference documentation: API docs, configuration reference, generated docs. Are they current or drifted?
- Onboarding and contribution docs: CONTRIBUTING, architecture overviews, runbooks.
- Inline documentation: docstrings/comments where the code is genuinely non-obvious (and not where it is).
- Test the documentation against reality: pick two or three documented procedures and check they still work or still match the code.

## GOV — Governance and project health

- Licence: present, OSI-recognised (if open source), consistent with dependency licences and any stated intent.
- Contribution process: CONTRIBUTING file, code of conduct, PR/issue templates, review requirements (CODEOWNERS, branch protection where visible).
- Issue and PR hygiene (for hosted projects): triage responsiveness, stale-issue accumulation, unreviewed merges.
- Bus factor: is knowledge and commit history concentrated in one person? Is there a maintainer succession or backup story?
- Roadmap or direction: is there any statement of where the project is going?

## OPS — Observability and operations

- Logging: structured or ad hoc, levelled sensibly, free of secrets and personal data.
- Metrics and tracing where the project is a service; health checks; alerting hooks.
- Runbooks and incident documentation; documented backup and restore for stateful systems.
- Graceful degradation and timeout/retry policy on outbound calls.

## DATA — Data handling and privacy

- What personal or sensitive data does the project touch? Is that inventory documented anywhere?
- Storage and transmission protections: encryption at rest/in transit, retention and deletion pathways.
- Regulatory exposure proportionate to the domain (e.g., GDPR-style subject rights, payment-card rules, health data).
- Data in the repository itself: fixtures, dumps, or logs containing real personal data are findings in their own right.

---

## Recording findings

Record each finding, as you go, in this shape (the templates reference gives the final document formatting):

- **ID**: `F-<CODE>-<NN>`
- **Severity**: Critical / High / Medium / Low
- **Evidence**: file paths with line references, command output, or config excerpts — enough for the reader to verify it independently
- **Impact**: why it matters for *this* project
- Optionally a one-line suggested direction (the full remedy belongs in the recommendations document)

Strengths are recorded too — briefly, per dimension — because they tell the reader what to preserve and they keep the review honest.

### Weighing a dangerous defect in a trivial project

Most severities are moderated by the project's maturity and purpose: a missing test suite or an absent continuous-integration gate is a graver matter in a production service than in a weekend prototype, and it is right to rate such findings proportionately. There is, however, an important class of exception, and it must be handled deliberately rather than swept along by the general proportionality principle.

Some defects are dangerous in absolute terms — their harm does not depend on the project's scale or its production status. A committed live credential can be exploited whether it sits in a toy application or a payment gateway; an exposed secret, an injection flaw reachable by an attacker, the leakage of real personal data, and remote code execution are all of this kind. Rate these on the harm they enable, not on the apparent triviality of the project that contains them. A live secret key in a throwaway prototype is still `Critical`, because the danger belongs to the key and the account behind it, not to the prototype.

The distinguishing test is this: ask whether the finding's worst outcome is bounded by the project's importance. If it is — an untested module can only break the modest thing it is part of — moderate the severity by the project's maturity. If it is not — the harm escapes the project's own boundaries, reaching real money, real credentials, real people, or systems beyond the repository — do not discount it, however small or unfinished the project appears. When a finding is rated more severely than the project's maturity alone would suggest, say so in its impact line (for example, noting that the exposure follows the credential rather than the prototype), so the reader understands why the usual proportionality has been set aside.
