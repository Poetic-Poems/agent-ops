# Tech debt

Deferred work and known gaps in agent-ops. Record an entry here whenever you
defer something, rather than leaving it only in a commit message or in chat.
Keep entries short and dated. Once an issue has been resolved, remove its
`## <id> <title>` section below — but never remove its row from the Ledger
table at the bottom of this file; see "Ledger" below.

Format:
```
## <id> <short title>

A description of what, why it matters, where, and a suggested fix.
```
Where `<id>` is a literal "TD" then the date followed by a zero-padded
sequential number (starting at 1 for the first entry of a day). I.e.:
**TD*YYMMDDNN***. `NN` is one more than the highest `NN` already used for that
date **in the Ledger table**, not just what's currently visible above it — a
resolved entry's body is removed, but its Ledger row stays forever, so the
Ledger (not memory or scrollback) is the source of truth for the next free ID.

## Ledger

Every tech-debt ID ever allocated — open, in-progress, resolved, or not-debt —
is listed here forever, in ID order. This is what makes numbering unambiguous:
the next free ID for a given date is one more than the highest `NN` seen below
for that date, regardless of whether the corresponding entry still has a body
above.

| ID | Title | Status | Resolved | Ref |
|----|-------|--------|----------|-----|
| TD26071401 | Usage-limit detector misses spend-limit phrasing; no graceful stand-down | open | | |

## TD26071401 Usage-limit detector misses "spend limit" phrasing; no graceful stand-down

**What.** `detect_and_log_limit_hit()` in `agent-cycle.sh` only treats a stage
as usage-limited when its output matches `usage limit|rate limit|usage cap|quota
exceeded`. When Claude actually blocks on a spend cap it returns *"You've hit
your monthly spend limit · raise it at claude.ai/settings/usage"*, which matches
none of those phrases. So no `limit-hit` event is logged and the stand-down /
cooldown path (`agent-cycle.sh` §2.1, the check on the last `limit-hit`
`resume_at`) never arms.

**Why it matters.** Instead of standing down until the cap resets, the pipeline
keeps running the Co-Ordinator every cron tick, failing with exit 1, logging
`attempt-failed`, and repeating — one wasted (small but non-zero) Co-Ordinator
invocation per hour for the whole outage, and no recorded resume time to report.
Observed 2026-07-14: cycles 00:30–07:30 UTC all failed this way until the spend
cap lifted, at which point the pipeline recovered on its own at 08:30 UTC. So
this is a graceful-degradation / observability gap, **not** a recovery blocker —
the pipeline does resume automatically once the cap is gone.

**Where.** `agent-cycle.sh`, `detect_and_log_limit_hit()` (the `grep -qihE`
pattern near the top of the file). Note the dashboard already carries a broader,
separately-maintained pattern: `publish-dashboard.sh` `limit_phrase_in()` uses
`hit your (weekly |usage )?limit|usage limit|rate limit|quota exceeded|resets
[A-Z][a-z]+ [0-9]`. The two detectors have drifted, which is why the dashboard
still surfaced a limit banner while `log.jsonl` recorded none.

**Suggested fix.**
- Broaden the `agent-cycle.sh` detector to also match "spend limit" and the
  generic "hit your … limit" phrasing. Ideally factor the pattern into one place
  shared with `publish-dashboard.sh` so the two can't drift again.
- When a limit is detected but no explicit ISO `resume_at` timestamp is present
  in the output, keep the existing fallback to `limit_cooldown_default` hours so
  a cooldown is still recorded.
- Optionally, parse the human-readable "resets <Month> <day>, <time> (<tz>)"
  phrasing into a concrete `resume_at` so the recorded cooldown matches the real
  reset instead of the default.
