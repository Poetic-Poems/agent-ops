# Tech Debt

A minimal register in the shape every Poetic repository keeps: live item bodies
under `## Current Items`, and a permanent row under `## Ledger` for every ID ever
allocated. TD26071501 is resolved, so its row remains and its body is gone —
which is exactly the state `scripts/td-check.pl` must call consistent.

## Current Items

### TD26071502 A live item

Its Ledger row says `open`, so its body belongs here.

### TD26071503 Another live item

Its Ledger row says `in-progress`, which is also live.

## Ledger

| ID | Title | Status | Resolved | Ref |
|---|---|---|---|---|
| TD26071501 | A resolved item | resolved | 2026-07-15 | #101 |
| TD26071502 | A live item | open | | |
| TD26071503 | Another live item | in-progress | | |
| TD26071504 | Something that was never debt | not-debt | 2026-07-16 | #102 |
