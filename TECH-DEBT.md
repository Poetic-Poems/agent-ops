# Tech debt

Deferred work and known gaps in agent-ops. Record an entry here whenever you
defer something, rather than leaving it only in a commit message or in chat.
Keep entries short and dated. Live items live under the "Current Items" heading
as `### <id> <title>` sections. Once an issue has been resolved, remove its
`### <id> <title>` section from Current Items below — but never remove its row
from the Ledger table at the bottom of this file; see "Ledger" below.

Format:
```
### <id> <short title>

A description of what, why it matters, where, and a suggested fix.
```
Where `<id>` is a literal "TD" then the date followed by a zero-padded
sequential number (starting at 1 for the first entry of a day). I.e.:
**TD*YYMMDDNN***. `NN` is one more than the highest `NN` already used for that
date **in the Ledger table**, not just what's currently visible above it — a
resolved entry's body is removed, but its Ledger row stays forever, so the
Ledger (not memory or scrollback) is the source of truth for the next free ID.

## Current Items

The open and in-progress items, each as a `### <id> <title>` section. This
heading is permanent: when there are no current items it stays here (empty), so
it is always obvious where a new item's body belongs.

<!-- Add new items directly below, as `### <id> <title>` sections. -->

## Ledger

Every tech-debt ID ever allocated — open, in-progress, resolved, or not-debt —
is listed here forever, in ID order. This is what makes numbering unambiguous:
the next free ID for a given date is one more than the highest `NN` seen below
for that date, regardless of whether the corresponding entry still has a body
above.

| ID | Title | Status | Resolved | Ref |
|----|-------|--------|----------|-----|
| TD26071401 | Usage-limit detector misses weekly & spend-limit phrasing; no graceful stand-down | resolved | 2026-07-14 | #11 |
