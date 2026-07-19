---
name: td
description: >-
  Launch an agent to work on a single item from TECH-DEBT.md. Use when the user
  invokes /td <id-segment> — it resolves the tech-debt record whose ID contains
  <id-segment> and hands it to a subagent to fix. Resolution goes through
  scripts/get-tech-debt-record.pl; if the segment matches more than one record,
  matches none, or is missing/invalid, stop and ask rather than guessing.
---

# Work a tech-debt item (/td)

Parse `/td <id-segment>`. `<id-segment>` is a fragment of a `TECH-DEBT.md`
record ID (e.g. `1`, `708`, `D26`, `TD26070803`). Resolve it to **exactly one**
record, then hand that record to a subagent to fix. Never assume which item is
meant when the result is anything other than a single clean match.

## 1. Resolve the segment to one record

Run the resolver (it locates `TECH-DEBT.md` from the git repo root, so the cwd
inside the repo does not matter):

```bash
perl scripts/get-tech-debt-record.pl <id-segment>
```

The script prints each matching record as a YAML map (`id`, `title`, `body`,
`start_line_number`, `end_line_number`) and sets its exit code to
(matches − 1), so **exit 0 means exactly one match**. Capture both stdout and
the exit status, then branch:

- **Exactly one record (exit 0).** Proceed to step 2 with that record.
- **More than one record** (non-zero exit, multiple `id:` lines on stdout).
  Ambiguous — do NOT pick one. Stop and list every matched record's `id` and
  `title`, and ask the user which one they mean. Do not launch an agent.
- **No records** (empty stdout, non-zero exit). Nothing matched
  `<id-segment>`. Stop, say so, and suggest the user check the IDs in
  `TECH-DEBT.md`. Do not launch an agent.
- **Invalid or missing segment** (the script died — stderr contains
  "Invalid ID segment" or "Please supply an ID segment"). Stop and ask the user
  for a valid segment: digits, optionally prefixed by `D` or `TD`. Do not launch
  an agent.

If `/td` is invoked with no argument at all, treat it as the missing-segment
case above and ask which item to work on.

## 2. Launch an agent to fix the resolved record

Once — and only once — a single record is resolved, launch a `general-purpose`
agent to do the work; the agent should be appropriately spec'd: not too costly
yet capable enough to (mostly likely) do the task correctly on its first
attempt. Put the resolved `id`, `title`, and `body` verbatim into its prompt so
it has the full description and the suggested fix, and instruct it to:

1. Read this repo's `CLAUDE.md` first and follow its conventions (Conventional
   Commits, the CHANGELOG/as-built-docs policy, and the tech-debt policy).
2. Before doing anything else, follow `TECH-DEBT.md`'s "Claiming an item"
   workflow: confirm the record's Ledger row is `open` (not `in-progress`)
   and skim open pull requests for its ID — if it looks already claimed,
   stop and report that instead of duplicating work. Otherwise flip its
   Ledger row to `in-progress`, commit, push a branch, and open a **draft**
   pull request right away (the Ledger-flip commit can be the PR's first
   commit).
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
6. Add a `[Unreleased]` `CHANGELOG.md` entry if the change is visible to poem
   authors or site publishers (skip it for routine/patch-level fixes, per that
   file's own header).
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
   can't resolve it, flip the Ledger row back to `open`, close the draft PR,
   and report what blocked it instead of leaving a stale claim in place.

The agent's final message comes back as the tool result and is not shown to the
user, so relay its outcome (what it changed, test results, the PR URL, and
anything it left for the user to decide).
