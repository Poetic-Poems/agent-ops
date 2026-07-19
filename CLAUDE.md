# agent-ops

Operations tooling for the Poetic autonomous agent pipelines: the hourly
implementation cycle (`agent-cycle.sh`), the weekly project-review cycle
(`review-cycle.sh`), and the local dashboard (`dashboard/`). `README.md`
explains what the pipelines do and how to configure, install, pause, and
monitor them; `docs/BUILD-*.md` are the prompts used to (re)build each
component; `prompts/` holds the runtime prompts the pipelines pass to their
agents.

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
`TECH-DEBT.md` at the repo root — do not leave it only in a commit message or
in chat. Follow the format and workflow described at the top of
`TECH-DEBT.md`, and delete an entry when it is resolved.
