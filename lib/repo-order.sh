#!/usr/bin/env bash
#
# lib/repo-order.sh — effective-age ordering for the Co-Ordinator's repo walk
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 3, acceptance check 1l).
#
# Requirement 3 sorts agent-cycle.sh's per-repo `ISO_ts \t slug \t
# default_branch` lines least-recently-updated first, so the most-overdue
# repo gets first look. `nice` (config.json's optional per-repo
# `repos[].nice`, default 0, range -19..19, negative meaning "give this repo
# more attention" — modelled on Linux's `nice`) turns that plain age
# comparison into a weighted one:
#
#   effective_age = (now − epoch(ts)) × 2^(−nice/3)
#
# A repo at nice 0 sorts exactly as before; a negative nice inflates its age
# so it looks more overdue than the clock alone says; a positive nice shrinks
# it. This module carries the feature's pure functions — the weighted
# ordering, and the `selection_config` contribution the no-op fingerprint
# relies on — extracted so both can be exercised without a `gh` stub or a
# real clock; agent-cycle.sh's walk consumes the former in place of the
# plain `sort` it once used.
#
# Load-bearing properties, because every one of them is a way this could go
# quietly wrong rather than loudly:
#
#   - **Floats are sort keys only, never printed.** The input timestamps
#     pass through byte-identical via `@tsv`; effective_age exists solely
#     inside jq's `sort_by` and is never formatted or emitted. There is no
#     float-formatting, no `LC_NUMERIC`, no `sort -g` hazard anywhere in this
#     path.
#   - **Nice absent or 0 everywhere reproduces the old order exactly.**
#     `2^(0/3)` is exactly `1.0` in IEEE doubles, so effective_age reduces to
#     `now − epoch(ts)` — exact integer arithmetic in doubles for gh's
#     Z-normalised UTC timestamps — and `sort_by([-.eff, .slug])` orders
#     identically to the old ascending-ISO `sort` over whole lines. The
#     tie-break on equal timestamps is slug-ascending, which matches the old
#     whole-line sort under `LC_ALL=C` and is now locale-independent (jq
#     compares codepoint-wise) — a determinism improvement in exotic
#     locales, not a behaviour change in the one this repo actually runs in.
#   - **Unparseable or empty timestamps degrade to epoch 0**
#     (`fromdateiso8601? // 0`), the same floor the gh-failure sentinel
#     `"1970-01-01T00:00:00Z"` already sits on — maximally overdue at neutral
#     nice. This is a documented degenerate corner, not an oversight: at nice
#     19 (factor 1/69.4) an epoch-0 sentinel's effective age is
#     `now / 69.4`, roughly a ten-month age-equivalent against a 2026 `now`,
#     so it can fall behind an even-staler neutral repo. Epoch 0 is an
#     API-failure artefact, not a real repo state, so trading away its
#     always-first guarantee at extreme positive nice is acceptable.
#   - **Weighted ages can cross with no input change.** Two repos' effective
#     ages grow linearly at different rates once their nice values differ, so
#     an order that has held across several skip streaks can flip on a later
#     cycle with nothing in the repo, the config or the walk itself having
#     changed — just the clock. This is sound rather than alarming: order
#     only arbitrates among candidates that already qualify for selection —
#     a none-selected verdict means nothing qualified anywhere, in any repo,
#     at any nice, and an order flip among candidates that all still fail to
#     qualify cannot change that verdict.
#   - **A slug absent from REPOS_JSON gets nice 0.** `$nice[.slug] // 0`
#     covers both a repo config.json never mentions in the `nice` sense and a
#     `nice` key simply left off one entry.
#   - **The fingerprint contribution omits, never empties.**
#     `repo_nice_selection_config` returns `{}` — no `repo_nice` key — for a
#     config with no non-zero `nice`. The no-op canon (lib/noop-skip.sh)
#     hashes `selection_config` wholesale, so an empty map would be
#     different bytes from an omitted key, and emitting `{}` unconditionally
#     would bust every running fleet's none-selected fingerprint once, the
#     day it shipped, for a config whose behaviour had not changed. Values
#     are floor-normalised because the startup guard deliberately admits an
#     integer-valued float spelling (`5.0` passes `floor == self`), and a
#     newer jq preserves number literals — without the floor, `5.0` and `5`
#     in config would fingerprint differently for identical behaviour, and a
#     jq upgrade could move fingerprints on its own.
#
# Sourced by agent-cycle.sh only.

# repo_order_by_effective_age NOW_EPOCH REPOS_JSON
#   stdin:  "ISO_ts \t slug \t default_branch" lines (agent-cycle.sh's
#           .repo_ts, one repo per line, any order)
#   stdout: the same lines, reordered most-overdue-first by
#           effective_age = (NOW_EPOCH − epoch(ISO_ts)) × 2^(−nice/3)
repo_order_by_effective_age() {
  local now="$1" repos_json="$2"
  # shellcheck disable=SC2016  # jq's $ vars ($now/$repos/$nice), not the shell's.
  jq -rRs --argjson now "$now" --argjson repos "$repos_json" '
    ([$repos[] | {key: .slug, value: (.nice // 0)}] | from_entries) as $nice
    | split("\n") | map(select(length > 0) | split("\t"))
    | map({ts: .[0], slug: (.[1] // ""), db: (.[2] // "")})
    | map(. + {eff: (($now - ((.ts | fromdateiso8601?) // 0))
                     * pow(2; -($nice[.slug] // 0)/3))})
    | sort_by([-.eff, .slug])
    | .[] | [.ts, .slug, .db] | @tsv
  '
}

# repo_nice_selection_config REPOS_JSON
#   stdout: the object the Script folds into the fingerprint's
#           `selection_config` — `{repo_nice: {slug: nice, …}}` carrying the
#           non-zero entries only, floor-normalised, or `{}` when no repo
#           carries one, so a neutral config adds no key at all and
#           fingerprints byte-identical to how it did before this feature
#           shipped.
repo_nice_selection_config() {
  local repos_json="$1"
  jq -c '
    [ .[] | select((.nice // 0) != 0) | {key: .slug, value: (.nice | floor)} ]
    | from_entries
    | if length == 0 then {} else {repo_nice: .} end
  ' <<<"$repos_json"
}
