# Contributing

This repository is worked by both a human maintainer and an autonomous
agent fleet, and both follow the same conventions. `CLAUDE.md` is the
canonical, detailed reference — written for an operating AI agent, but
every rule in it applies equally to a human contributor. This document is
a short human-facing pointer into it, not a replacement for it.

- **Every change lands via a pull request** that the repo owner reviews
  and squash-merges; there are no direct pushes to `main`.
- **PR titles follow [Conventional
  Commits](https://www.conventionalcommits.org/)** —
  `<type>[(scope)][!]: <description>`, with `type` one of `build`, `chore`,
  `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`
  (see `.githooks/check-commit-format.sh`). The squash-merge uses the PR
  title as the commit message on `main`, and CI enforces this format on
  both the PR title and every individual commit on the branch.
- **A change to pipeline behaviour must update the matching as-built spec
  under `docs/` in the same pull request** — see `CLAUDE.md`'s "As-built
  specifications" section for which spec covers which component.
- **Tech debt is filed as a GitHub issue** labelled `pw::type:tech-debt`,
  never left only in a commit message or chat — see `TECH-DEBT.md` for the
  filing and resolution workflow.

For everything else — branch conventions and generated regions — see
`CLAUDE.md`; the merge-queue behaviour the autonomous fleet operates under
is in `README.md`'s "Merge autonomy" section, and its long-running-command
rules are in the pipeline specs under `docs/` and the stage prompts under
`prompts/`.
