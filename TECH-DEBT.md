---
scope: PPagop
---

# Tech debt

Deferred work and known gaps in agent-ops, kept as a per-item
register: every record ever allocated lives as one file under `tech-debt/`,
named by its ID (`TD-PPagop-<YYMMDD><NN>.md`), with YAML frontmatter
carrying the record's state and a Markdown body describing it. The full
format, ID grammar and scope-code registry are specified in
[docs/TECH-DEBT-REGISTER.md in Poetic-Poems/poetic](https://github.com/Poetic-Poems/poetic/blob/main/docs/TECH-DEBT-REGISTER.md).

`perl scripts/td-check.pl` validates the
register and runs on every pull request via
`.github/workflows/tech-debt-register.yml`, alongside two guards: no file
in `tech-debt/` may ever be deleted or renamed once on `main` (the
append-only Ledger guarantee — IDs are never reused), and no old-format
`### TD` item sections may reappear in this file.

## Filing an item

1. Allocate the ID with `scripts/next-tech-debt-id.pl --ref origin/main`
   (after a `git fetch origin`). It cannot see IDs allocated on unmerged
   branches, so also skim open pull requests and `td/*` branches. If two
   filings do collide, git surfaces it as an add/add conflict on the
   filename; the later one renames to the next free NN before merging.
2. Create `tech-debt/<id>.md` with frontmatter `id`, `title`,
   `status: open`, `filed` (today, matching the ID's date), an optional
   `review:` provenance line (`<review-folder> R-NN`), and a body
   describing what, why it matters, where, and a suggested fix.
   (`legacy-id:` appears only on items migrated from the old single-file
   register; segments of either ID resolve via
   `scripts/get-tech-debt-record.pl`.)
3. If the item is referenced elsewhere (code comments, docs), note those
   references in the body so whoever resolves it removes them too.

## Claiming an item

This repository is worked by concurrent agents: a claim must be checked and
taken against the shared state, never against what a local checkout happens
to say. Before starting work on an open item:

1. `git fetch origin`, then confirm the item's `status:` is `open` (not
   `in-progress`) **as of `origin/main`** — e.g. via
   `perl scripts/get-tech-debt-record.pl --ref origin/main <id>`.
2. Confirm nobody holds a claim: `git ls-remote origin "refs/heads/td/<id>"`
   must print nothing, and skim open pull requests for the ID.
3. Create the claim branch, named exactly **`td/<id>`**, from `origin/main`;
   flip the item's `status:` to `in-progress`; commit and push. The branch
   name is the claim lock: git refuses the push if the branch already
   exists, so a rejected push means another agent won the race — abandon
   quietly; never force-push over it.
4. Open a **draft** pull request right away — before the fix is finished.
   The status-flip commit can be its first commit.
5. Do the work, pushing further commits to the same branch/PR.
6. Once verified, flip the item's frontmatter to `status: resolved` and
   fill `resolved:` (today's date) and `ref:` (the PR number), leaving the
   body in place, and mark the PR ready for review.

If a claim is abandoned, close the draft PR and delete the `td/<id>`
branch — that releases the lock. The in-progress flip only ever lived on
the branch, so the record on `main` still says `open` and nothing needs
reverting.

## Resolution and history

A resolved item's file is its permanent record: the body stays, and
`git log --follow tech-debt/<id>.md` is the item's audit trail. Never
delete or rename an item file, and never flip a resolved item back —
re-opening debt means filing a new item that references the old one. An
item that turns out not to be debt keeps its file too: `status: not-debt`,
with `ref:` pointing at where the content moved.

Aggregated views of the register (a Ledger-style table, a status tally)
are generated on demand, never committed.
