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
`.github/workflows/tech-debt-register.yml`, alongside three guards: no file
in `tech-debt/` may ever be deleted or renamed once on `main` (the
append-only Ledger guarantee — IDs are never reused), an open item's body is
append-only — existing text may not change while `status:` stays `open`, new
text may be appended, and rewriting existing text requires the status to
move (see "Resolution and history" below — a rewrite of existing text on an
item that stays `open` is either a stale writer silently overwriting an
already-merged record or a policy breach, and either way CI should catch it
rather than let a permanent record change quietly), and no old-format
`### TD` item sections may reappear in this file.

## Filing an item

1. Reserve the ID with `scripts/reserve-tech-debt-id.pl`. It fetches
   `origin/main` itself and pushes a `td/<id>` branch from it — the same
   race-safe lock "Claiming an item" below uses — retrying with the next
   `NN` itself whenever a push is rejected, so unlike a plain scan there is
   nothing left to check for a collision by hand. It prints the reserved
   `id` on success.
2. `git fetch origin td/<id>` and check out that branch. Create
   `tech-debt/<id>.md` on it with frontmatter `id`, `title`,
   `status: open`, `filed` (today, matching the ID's date), an optional
   `review:` provenance line (`<review-folder> R-NN`), and a body
   describing what, why it matters, where, and a suggested fix. Commit and
   push, then open a pull request — this is the same `td/<id>` branch
   "Claiming an item" would later reuse to work the item once merged,
   deleted, and re-created; abandoning the filing (closing the PR without
   merging and deleting the branch) simply releases the reservation, the
   same way abandoning a claim does. That is true for this direct workflow,
   where the record commit lands on `td/<id>` itself; a filing with no
   branch of its own to commit on instead follows "Filing alongside other
   work" below, where the same abandonment releases two branches, not one.
   (`legacy-id:` appears only on items migrated from the old single-file
   register; segments of either ID resolve via
   `scripts/get-tech-debt-record.pl`.)
3. If the item is referenced elsewhere (code comments, docs), note those
   references in the body so whoever resolves it removes them too.

## Filing alongside other work

A stage already committing to its own branch — an Implementer or Reviewer
mid-pull-request, or a repository review batching several findings —
sometimes notices debt it has no reason to stop and fix. Filing it should not
cost a second round trip: reserve the ID as above, but skip "Filing an item"
step 2's `td/<id>` checkout, and add `tech-debt/<id>.md` straight onto the
branch already in hand, riding along in the pull request that branch already
carries (or is about to).

1. Before reserving, search the register for an existing record about the
   same gap: `scripts/find-similar-tech-debt.sh "<working title>"` prints any
   `open`/`in-progress` record whose title is a close match, and exits
   non-zero if it found one. A hit means the gap is already tracked — cite
   the existing id instead of filing a second record for it.
2. Reserve the ID with `scripts/reserve-tech-debt-id.pl`, exactly as "Filing
   an item" step 1 describes — it still pushes `td/<id>` as a reservation
   lock, but in *this* workflow that lock is the branch's only purpose:
   unlike "Filing an item" step 2 and "Claiming an item" step 3, which both
   commit on it, nothing here is ever checked out or committed to it.
3. Add `tech-debt/<id>.md` on the current branch, with the same frontmatter
   "Filing an item" step 2 describes, plus a line in the body naming where it
   was noticed — the pull request or review that surfaced it, e.g. "Noticed
   while working PR #618" — so a later reader has the same provenance a
   `review:` line gives a review-sourced item. Commit it alongside whatever
   else that branch already carries, and push.
4. The `td/<id>` branch releases itself once `tech-debt/<id>.md` reaches
   `main` via any pull request: `.github/workflows/release-td-branch.yml`
   deletes it the moment it sees a new record land, whichever branch actually
   carried the filing commit. If that workflow cannot run — its own delete
   call failed, or the record was filed some other way it does not recognise
   — delete the branch by hand instead: `git push origin --delete td/<id>`,
   the fallback "Claiming an item" has always needed for an abandoned claim.
5. A stage with no branch of its own to ride on — the Approver, the Enabler,
   neither of which ever writes code or pushes — cannot add
   `tech-debt/<id>.md` to "the current branch" as step 3 above describes,
   since it has none. `lib/tech-debt-file.sh`'s `techdebt_file_debt` follows
   this same reservation-and-record shape on their behalf, except the record
   commit lands on a `td-record/<id>` branch minted for it alone, carried by
   a small pull request of its own (labelled `pr_label`) rather than riding
   on anyone else's. Abandoning *that* filing — a human closing the
   `td-record/<id>` pull request without merging it, because the record is a
   duplicate, unwanted, or superseded — releases two branches, not one:
   `td-record/<id>`, carrying the record commit, and `td/<id>`, the
   reservation behind it. `scripts/sweep-orphan-branches.sh` clears both
   unattended once that pull request is closed — for `td/<id>`, only once it
   has confirmed `<id>`'s record never reached `main` some other way — so
   nothing needs to be done by hand; where the sweep cannot run, delete both
   directly instead: `git push origin --delete td-record/<id> td/<id>`.

This is the same reservation lock "Claiming an item" and "Filing an item"
both use; only where the filing commit lands changes.

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
