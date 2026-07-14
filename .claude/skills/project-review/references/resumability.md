# Resumability

A full project review is a large piece of work, and it may be interrupted before completion — the user may run out of credit, the network may drop, the machine may lose power. The review must therefore never hold significant work only in memory: progress is checkpointed to disk continuously, and a fresh session can pick the review up from the last checkpoint, automatically, with at most one dimension's work lost.

## The state file and working notes

Everything needed to resume lives inside the review output folder, a dated subdirectory of `reviews/`:

```
reviews/
└── project-review-YYYY-MM-DD/
    ├── review-state.json      # progress ledger (schema below)
    └── worknotes/             # raw material, written incrementally
        ├── project-map.md     # Step 1 output: inventory, structure, purpose, size
        ├── findings-<CODE>.md # one per dimension, written the moment the dimension is done
        └── consolidated.md    # Step 3 output: rated findings and the recommendation list
```

`review-state.json` schema (write it atomically — write to a temporary file and rename — so a power cut cannot leave it half-written):

```json
{
  "skill": "project-review",
  "status": "in-progress",
  "project_root": "<absolute path>",
  "revision": "<commit hash, version, or 'uploaded archive'>",
  "tech_debt_file": "<path to the existing register, or null>",
  "started": "<ISO 8601>",
  "updated": "<ISO 8601 — refresh at every checkpoint>",
  "sampling": "<one line: 'exhaustive' or the sampling strategy>",
  "steps": {
    "orient": "complete",
    "reconnaissance": "complete",
    "dimensions": {
      "ARCH": "complete", "CODE": "complete", "SEC": "in-progress",
      "TEST": "pending", "DEPS": "pending", "TOOL": "pending",
      "CI": "pending", "PERF": "pending", "UX": "pending",
      "DOC": "pending", "GOV": "pending", "OPS": "pending", "DATA": "pending"
    },
    "consolidation": "pending",
    "documents": {
      "01-summary.md": "pending", "02-findings.md": "pending",
      "03-recommendations.md": "pending", "04-improvement-prompts.md": "pending",
      "README.md": "pending"
    },
    "tech_debt_update": "pending"
  }
}
```

## Checkpoint discipline

Checkpoint at every one of these moments, by writing the relevant worknotes file *first* and then updating `review-state.json`:

1. End of Step 0 — create the folder, write the initial state file.
2. End of Step 1 — write `worknotes/project-map.md`; mark `reconnaissance` complete.
3. End of *each dimension* in Step 2 — write `worknotes/findings-<CODE>.md`; mark that dimension complete. Do not batch several dimensions into one write: the whole point is that an interruption loses at most the dimension in progress.
4. End of Step 3 — write `worknotes/consolidated.md`; mark `consolidation` complete.
5. After *each* output document in Steps 4–5, and after the tech-debt update, mark it complete. Write `README.md` (the index) last, since it summarises the others.
6. Completion — delete `worknotes/` and `review-state.json`. The finished documents are the record; the presence of a state file is, by design, the unambiguous signal of an interrupted review.

## Resuming

At the very start of Step 0, before anything else, look for `reviews/project-review-*/review-state.json` under the project root (and, in the Claude.ai chat, among the uploads — the user may have uploaded a partial review folder alongside the project). If one is found with a status other than `complete`:

1. Read the state file and every existing worknotes file. Together with the review documents already written, these restore the session's knowledge; do not redo completed steps.
2. Verify the revision. If the project's current revision matches the state file, resume **automatically**: tell the user, in one sentence, that an interrupted review from `<started>` is being resumed at `<first pending item>`, and carry on. Do not ask permission — automatic resumption is the designed behaviour.
3. If the revision has *changed* since the interruption, the saved findings may be stale; this is the one case where the user decides. Briefly offer: resume anyway (fast, possibly stale), or start afresh. If the user explicitly asked for a fresh review, honour that without asking.
4. Resume into the *existing* folder even if its date is no longer today's; note the resumption date in the index's date line (e.g., "Started 2026-07-01, completed 2026-07-07.").

## Environment caveat for the Claude.ai chat

The chat container's filesystem does not persist between sessions. Within a session the checkpoint discipline still applies (interruptions within a session are recoverable), but across sessions resumption depends on the user: present the partial review folder to the user if an interruption is foreseeable (for example, when they say they are running low on credit), and tell them that uploading that folder with the project next time will let the review resume where it left off. In Claude Code and Cowork the state simply persists on disk and resumption is fully automatic.
