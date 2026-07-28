# Tech Debt

The same register with one instance of each drift the check names, so a change
that stops reporting any of them fails loudly rather than quietly narrowing what
the `register-hygiene` source can see.

## Current Items

### TD26071501 A resolved item

STALE BODY: the Ledger row says `resolved` but the body was never removed — the
drift that motivated this whole feature, and the one that makes `## Current
Items` advertise work that is already done.

### TD26071502 A live item

Consistent: an `open` row with exactly one body.

### TD26071599 An orphan

NO LEDGER ROW: a body whose ID appears nowhere in the Ledger.

## Ledger

| ID | Title | Status | Resolved | Ref |
|---|---|---|---|---|
| TD26071501 | A resolved item | resolved | 2026-07-15 | #101 |
| TD26071502 | A live item | open | | |
| TD26071503 | Another live item | open | | |
