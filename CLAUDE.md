# agent-ops

Operations tooling for the Poetic autonomous agent pipelines: the hourly
implementation cycle (`agent-cycle.sh`), the weekly project-review cycle
(`review-cycle.sh`), and the local dashboard (`dashboard/`). `README.md`
explains what the pipelines do and how to configure, install, pause, and
monitor them; `docs/*-SPEC.md` are the as-built requirement specifications
for each component; `prompts/` holds the runtime prompts the pipelines pass
to their agents.

## As-built specifications

Each component has an as-built requirements specification in `docs/`:

- `docs/IMPLEMENTATION-PIPELINE-SPEC.md` — the hourly implementation
  pipeline (`agent-cycle.sh`, `lib/`, `scripts/`, and the five stage
  prompts).
- `docs/REVIEW-PIPELINE-SPEC.md` — the weekly project-review pipeline
  (`review-cycle.sh`, `prompts/project-reviewer.md`, the vendored skill).
- `docs/DASHBOARD-SPEC.md` — the monitoring dashboard
  (`scripts/publish-dashboard.sh`, `dashboard/index.html`).

These are requirement documents, and they are **as-built**: at all times they
describe the system that actually exists. Any change that alters what a
component does, requires, or produces must land in the same pull request as
the spec edit that keeps its document accurate — update the affected numbered
requirement (and any acceptance check anchored to it), or add one for new
behaviour. Requirements state only what is, never what used to be or what is
planned; history and rationale belong in the specs' design-decision and
gotcha sections. If you find a spec and the code disagreeing, that is a bug:
fix whichever is wrong rather than working around the mismatch.

The specs outrank the operating prompts: `prompts/*.md` implement the specs'
requirements, so bring the spec in line first, then the affected prompt(s).

## Generated regions

`README.md`'s two configuration tables and each as-built spec's own
(`docs/IMPLEMENTATION-PIPELINE-SPEC.md`'s, `docs/REVIEW-PIPELINE-SPEC.md`'s)
are rendered from `config.schema.json` by `scripts/render-config-table.sh` —
four `<!-- config-table:start id=... -->` … `<!-- config-table:end -->`
regions in total, each paired with a `<!-- config-table:notes id=... -->` …
`<!-- config-table:notes-end -->` region below the table for notes too long
to fit a cell. Never hand-edit a row inside either region: edit the owning
key's `description`, `x-docs.readme`/`x-docs.spec` or `x-docs.value` in the
schema instead, then run `scripts/render-config-table.sh` (no arguments) to
regenerate every region and `scripts/render-config-table.sh --check` before
you push — `.github/workflows/config-table.yml` runs the same check on every
pull request, and a hand-edit fails it even when the wording was right,
because only the schema copy survives a regeneration. Each region's start
marker carries this same contract inline, so it reads even to someone who
reaches the row directly and never opened this file.

## Branch workflow

Every change goes through a pull request; the repo owner reviews and
squash-merges, and the branch is deleted after merge. Write PR titles in
Conventional Commits format (e.g. `docs: clarify workspace rule`).

All Poetic repositories, this one included, operate in a multi-agent
environment: autonomous and interactive agents, and the maintainer, may push
branches, merge pull requests, and move `main` at any time. Before commencing
any changes, make your own dedicated fresh clone of `origin/main` and work
in that — never in a checkout shared with anyone else, such as the user's
working copy (which may be edited at any moment) or a clone another agent is
already using:

```bash
git clone https://github.com/Poetic-Poems/agent-ops.git <scratch-dir>/agent-ops
```

A full clone is the default: at this repo's size it costs nothing, and
rebasing onto a moved `main` and inspecting history just work. If clone speed
ever becomes a concern, prefer a blobless clone (`--filter=blob:none`), which
keeps the full commit history; a shallow clone (`--depth 1`) has no merge
base, so it must be deepened (`git fetch --unshallow`) before it can rebase.
Commit, push the feature branch, and open the pull request from that clone;
delete the clone once the work has landed.

When you open (or update) a pull request, do not assume `origin/main` is
still in the state it was when you cloned — another change may have merged
meanwhile. Confirm the PR is actually mergeable via `gh`
(e.g. `gh pr view <n> --json mergeable,mergeStateStatus`); if it conflicts,
rebase onto the current `main` and push the fix.

The pipelines this repo hosts already follow the dedicated-clone rule by
construction: every cycle clones its target repo fresh from GitHub into
`workspace_root` and deletes the clone afterwards, and the user's own
checkouts under `~/Code` are never touched.

## Tech debt

When you defer work, take a shortcut, or notice a known gap, record it in
the tech-debt register — do not leave it only in a commit message or in
chat. This repository's register is per-item: one `tech-debt/<id>.md` file
per record (YAML frontmatter plus a Markdown body), IDs scoped `PPagop`,
with `TECH-DEBT.md` at the repo root holding only the policy — the filing
and claiming workflows and the declared scope.
`docs/TECH-DEBT-REGISTER.md` in `Poetic-Poems/poetic` specifies the format
and the scope-code registry.

Resolving an item is a frontmatter-only edit — `status: resolved`, plus
`resolved:` and `ref:` — with the body left in place; item files are never
deleted or renamed (CI enforces both). `perl scripts/td-check.pl`
(argless — it detects the register's format) checks the register and is
what `.github/workflows/tech-debt-register.yml` runs on every pull
request, so run it before you push. The register scripts are
byte-identical copies of the canonical ones in `Poetic-Poems/poetic`
(see `.github/workflows/td-tooling-drift.yml`) — fix them upstream, never
here.
