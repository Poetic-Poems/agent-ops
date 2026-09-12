## What does this change do, and why?

## Checklist

- [ ] The PR title follows [Conventional Commits](https://www.conventionalcommits.org/)
      (`<type>[(scope)][!]: <description>`) — squash-merge uses it as the
      commit message on `main`, and CI checks both the title and every
      commit on the branch.
- [ ] If this changes pipeline behaviour, the matching as-built spec under
      `docs/` is updated in this same PR (see `CLAUDE.md`, "As-built
      specifications").
- [ ] Any deferred work or known shortcut is filed as a `pw::type:tech-debt`
      issue and referenced with a `Defers: #n` line, per `TECH-DEBT.md`.
