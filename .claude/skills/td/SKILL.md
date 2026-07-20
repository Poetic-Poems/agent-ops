---
name: td
description: >-
  Launch an agent to work on a single item from TECH-DEBT.md. Use when the user
  invokes /td <id-segment> — it resolves the tech-debt record whose ID ends
  with <id-segment> and hands it to a subagent to fix. Searches every repo
  attached to the session (workspace-aware), resolving against origin/main via
  scripts/get-tech-debt-record.pl; if the segment matches more than one record
  — including the same ID in two repos — matches none, or is missing/invalid,
  stop and ask rather than guessing.
---

# Work a tech-debt item (/td)

Parse `/td <id-segment>`. `<id-segment>` is the trailing part of a
`TECH-DEBT.md` record ID (e.g. `3`, `803`, `070803`, `TD26070803`). Resolve it
to **exactly one** record in **exactly one** repo, then hand that record to a
subagent to fix. Never assume which item is meant when the result is anything
other than a single clean match.

Record IDs are only unique within one repository: sister repos allocate from
the same date-based sequence, so the same ID can name different items in
different repos. A match is therefore a **(repo, ID) pair**, and ambiguity
across repos is still ambiguity.

## 1. Determine the candidate repos

- If the session's working directory is inside a git repo and no other repos
  are attached to the session, the candidate set is just that repo.
- Otherwise (a multi-repo workspace: the cwd is not inside a git repo, or the
  session has several working directories), the candidates are every session
  working directory that is a git repo, plus every immediate child directory
  of each working directory that is a git repo.

Keep only candidates that track tech debt (both `TECH-DEBT.md` and
`scripts/get-tech-debt-record.pl` exist), and de-duplicate by
`git remote get-url origin` — workspaces often hold more than one checkout of
the same repo; resolve each origin only once.

## 2. Resolve the segment to one record

In each candidate repo, fetch and run that repo's own resolver against the
shared state — never trust a possibly stale or wrongly-branched local
checkout:

```bash
git -C <repo> fetch -q origin main
(cd <repo> && perl scripts/get-tech-debt-record.pl --ref origin/main <id-segment>)
```

(If the fetch fails — e.g. offline — fall back to the working tree, without
`--ref`, and note that in the final report.)

The script prints each matching record as a YAML map (`id`, `title`, `body`,
`start_line_number`, `end_line_number`) and sets its exit code to
(matches − 1), so **exit 0 means exactly one match in that repo**. Collect
every match across all candidate repos as (repo, ID) pairs, then branch:

- **Exactly one (repo, ID) pair.** Proceed to step 3 with that record and its
  repo.
- **More than one pair** — several records in one repo, or matches in more
  than one repo (even for the same ID). Ambiguous — do NOT pick one. Stop and
  list every match as `<repo> — <id> — <title>`, and ask the user which one
  they mean. Do not launch an agent.
- **No matches in any repo.** Nothing matched `<id-segment>`. Stop, say so,
  and suggest the user check the IDs in each repo's `TECH-DEBT.md`. Do not
  launch an agent.
- **Invalid or missing segment** (the script died — stderr contains
  "Invalid ID segment" or "Please supply an ID segment"). Stop and ask the user
  for a valid segment: digits, optionally prefixed by `D` or `TD`. Do not launch
  an agent.

If `/td` is invoked with no argument at all, treat it as the missing-segment
case above and ask which item to work on.

## 3. Launch an agent to fix the resolved record

Once — and only once — a single (repo, record) is resolved, launch a
`general-purpose` agent to do the work; the agent should be appropriately
spec'd: not too costly yet capable enough to (mostly likely) do the task
correctly on its first attempt. Put the resolved repo (its `origin` URL) and
the record's `id`, `title`, and `body` verbatim into its prompt so it has the
full description and the suggested fix, and instruct it to:

1. Make its own dedicated fresh clone of the resolved repo's `origin/main`
   and work only in that clone — never in a checkout shared with the user or
   another agent. Then read that repo's `CLAUDE.md` first and follow its
   conventions (Conventional Commits, the CHANGELOG/as-built-docs policy, and
   the tech-debt policy).
2. Before doing anything else, follow `TECH-DEBT.md`'s "Claiming an item"
   workflow: confirm the record's Ledger row is `open` (not `in-progress`)
   **as of `origin/main`**, confirm no claim branch exists
   (`git ls-remote origin "refs/heads/td/<id>"` returns nothing), and skim
   open pull requests for its ID — if it looks already claimed, stop and
   report that instead of duplicating work. Otherwise create the claim branch,
   named exactly **`td/<id>`**, flip the record's Ledger row to `in-progress`,
   commit, and push. The branch name is the claim lock: **if the push is
   rejected because the branch already exists, another agent claimed the item
   in the race window — stop and report; never force-push.** Then open a
   **draft** pull request right away (the Ledger-flip commit can be the PR's
   first commit).
3. Implement the fix described in the record's `body`, pushing further
   commits to the same branch/PR.
4. Run the relevant checks for the area it touched (e.g. `npm test`,
   `npm run build`, `npm run check`, `npm run check:build`; on WSL/Linux via
   `./scripts/setup-linux.sh`).
5. On success, remove the resolved entry from `TECH-DEBT.md` — delete the whole
   `### <id> <title>` section under `## Current Items` (locate it by the
   `### <id>` heading rather than by the reported line numbers, which drift once
   editing starts) — and flip its
   Ledger row to `resolved`, filling in `Resolved` (today's date) and `Ref`
   (the PR number). If the record's body notes references to its ID
   elsewhere (e.g. in code comments), remove those too, per `CLAUDE.md`'s
   tech-debt policy.
6. Add an `[Unreleased]` `CHANGELOG.md` entry, but only if the resolved repo
   maintains a `CHANGELOG.md` in the first place — skip this step otherwise
   (agent-ops currently has no `CHANGELOG.md`, so skip it here).
7. Before marking the PR ready for review, update its description
   (`gh pr edit <n> --body ...`) to reflect the finished state: replace the
   "This draft PR claims the item..." line (it's no longer a draft) with a
   summary of what was actually implemented, and append the post-implementation
   information a reviewer needs — results of the checks run in step 4 (test/
   build/lint pass or fail), and anything else worth flagging (files touched
   outside the obvious scope, follow-ups left undone, tech-debt entries added).
   Keep the PR title as-is; only the body changes.
8. Push the final commits and mark the draft PR ready for review — per
   `CLAUDE.md`'s branch workflow, agents work autonomously up to the PR
   stage without pausing to ask first. If verification fails and the agent
   can't resolve it, close the draft PR and delete the `td/<id>` branch (this
   releases the claim — the in-progress flip only ever lived on the branch,
   so `main`'s Ledger still says `open`), and report what blocked it instead
   of leaving a stale claim in place.

The agent's final message comes back as the tool result and is not shown to the
user, so relay its outcome (what it changed, test results, the PR URL, and
anything it left for the user to decide).
