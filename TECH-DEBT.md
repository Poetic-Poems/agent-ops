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
| TD26071401 | Usage-limit detector misses weekly & spend-limit phrasing; no graceful stand-down | in-progress | | |

## TD26071401 Usage-limit detector misses weekly & spend-limit phrasing; no graceful stand-down

**What.** `detect_and_log_limit_hit()` in `agent-cycle.sh` only treats a stage
as usage-limited when its output matches `usage limit|rate limit|usage cap|quota
exceeded`. Claude's real limit messages match none of these. Two distinct
variants appear in the transcripts, and they need **different** handling:

- **Weekly / rolling usage limit** — *"You've hit your weekly limit · resets Jul
  17, 4am (Pacific/Auckland)"*. Carries an explicit, parseable **reset time**:
  the pipeline should stand down until exactly then.
- **Monthly spend cap** — *"You've hit your monthly spend limit · raise it at
  claude.ai/settings/usage"*. Carries **no reset time** and clears only when a
  human raises the cap (or the billing month rolls over); auto-retry cannot fix
  it, so this one really wants a distinct "needs-human" signal.

Both share the stem *"You've hit your … limit"*, so a single case-insensitive
`hit your .* limit` matcher catches every observed variant — but the
reset-time extraction has to branch on which class it is.

**Why it matters.** With no match, no `limit-hit` event is logged, so the
stand-down / cooldown path (`agent-cycle.sh` §2.1, the check on the last
`limit-hit` `resume_at`) never arms. The pipeline keeps launching the
Co-Ordinator every cron tick, failing with exit 1, logging `attempt-failed`,
and repeating — one wasted (small but non-zero) invocation per hour for the
whole outage, with no recorded resume time to report. It is a
graceful-degradation / observability gap, **not** a recovery blocker: the
pipeline resumes on its own once the caps clear.

**Observed 2026-07-14** (evidence in `~/.local/state/poetic-agents/cycles/`).
Two back-to-back episodes, 21 cron cycles wasted, none logged as `limit-hit`:

| Episode | Cycles (UTC) | Message | Reset time in message? |
|---|---|---|---|
| Weekly usage limit | 2026-07-13 11:00 → 18:30 (8) | *…weekly limit · resets Jul 17…* | yes |
| Monthly spend cap | 2026-07-13 19:30 → 2026-07-14 07:30 (13) | *…monthly spend limit · raise it…* | no |

The pipeline then recovered by itself at 08:30 UTC and went on to raise a real
PR (`poetic-fiddle#20`). Note the reset in the weekly message (*Jul 17*) never
actually blocked past 08:30 — treat a parsed `resume_at` as an upper bound to
stand down *until*, not a promise the block lasts that long.

**Where.** `agent-cycle.sh`, `detect_and_log_limit_hit()` (the `grep -qihE`
pattern near the top of the file), and its `resume_at` parser (which only
recognises ISO-8601 timestamps, so even the weekly message's human-readable
reset falls through to the default). The dashboard carries a broader, separately
maintained pattern in `publish-dashboard.sh` (`limit_phrase_in()` /
`limit_reset_text()`); the two detectors have drifted, which is why the
dashboard surfaced a limit while `log.jsonl` recorded none.

**Suggested fix.**
- Broaden the `agent-cycle.sh` detector to the generic case-insensitive
  `hit your .* limit` (keeping the existing terms). Factor the pattern into one
  place shared with `publish-dashboard.sh` — e.g. a small sourced
  `lib/limit-detect.sh` — so the two can't drift again.
- Branch on message class. When a reset time is present, parse *"resets <Month>
  <day>, <time> (<tz>)"* into a concrete UTC `resume_at`, minding the **named
  timezone** — a naïve `date -d` on the whole string fails on the parenthesised
  zone; strip it and set `TZ`, e.g.
  `TZ='Pacific/Auckland' date -d 'Jul 17 04:00' -u +%Y-%m-%dT%H:%M:%SZ`. When no
  reset time is present (spend cap), still record a `limit-hit` so a cooldown
  arms, and consider flagging it distinctly as needing human action.
- Make the fallback cooldown limit-aware: `limit_cooldown_default` = 3 h is far
  too short for a weekly or monthly limit (≈8 failed retries/day for days). If
  the phrasing says "weekly"/"monthly" and no `resume_at` was parsed, back off
  much longer (e.g. to the next day) rather than 3 h.
- Add fixtures with both exact strings above to a detector test so this can't
  silently regress.
