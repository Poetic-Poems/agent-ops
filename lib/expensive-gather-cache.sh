#!/usr/bin/env bash
#
# lib/expensive-gather-cache.sh — per-node cache that lets
# `gather_ordered_repos` (lib/candidate-gather.sh) run each cycle's expensive
# per-repository reads — issue threads with comments, the tech-debt register,
# PR review reads, merge-conflict/dequeued/register-hygiene walks — for one
# configured repository only, instead of every one of them (requirement 48,
# agent-ops#1086).
#
# Before this, every cycle re-read every configured repository's whole
# candidate set regardless of which one it went on to select, so the fleet's
# GitHub read volume scaled with (repositories × nodes × cycles) for
# information that is identical across a node's own cycles until something
# in that repository actually changes. `expensive_gather_pick_repo` below
# turns that into one full read per node per cycle: whichever configured
# repository this node has gone longest without expensively reading gets
# read fresh this cycle, and every other one reuses the snapshot this same
# node captured the last time its own turn came around.
#
# ## Per-node, not fleet-wide
#
# The cache lives under this node's own `state_dir`, exactly like
# `lib/labels.sh`'s ensure-stamp — it is not synced fleet-wide the way the
# union log is: `scripts/state-sync.sh`'s `EXCLUDES` excludes
# `state_dir/expensive-gather/` from general replication, on the same
# checkout-fresh-mtime reasoning as `labels-ensured/` — a cache restored from
# the fleet state branch would make every repository look freshly read.
# A fleet-shared cache (the node that gathers first in an
# interval writing a snapshot every node reuses) is a real further
# reduction — issue #1086's own "Option 2" — but it is a state-store
# contract, deliberately left for whenever D21/Phase 2 settles what that
# store's interface is, rather than retrofitted ahead of it. Each node
# therefore still visits every configured repository's cache once per
# `repositories` cycles, on its own schedule, independent of its peers'.
#
# ## Oldest-cache-wins, not commit-staleness
#
# Picking is keyed on *when this node last expensively read a repository*,
# not on `lib/repo-order.sh`'s own effective-age ordering (last commit to the
# default branch, weighted by `nice`). The two answer different questions:
# repo-order says which repository is most overdue to be *worked*, and is a
# pure function of GitHub state the whole fleet computes identically — every
# node would pick the same repository to expensively read every cycle, and
# every other configured repository would starve of a fresh read for as long
# as nothing landed on its default branch, which can be indefinitely for a
# repository this pipeline has never yet gathered enough to select work in.
# Keying on this node's own last-read time instead guarantees every
# configured repository eventually gets its turn on this node, regardless of
# commit activity: reading it resets its own clock, so cache age rotates
# through every configured repository the same way `labels_ensure_stamped`'s
# per-repo, per-role stamps do.
#
# ## What is cached, and what is re-applied every cycle regardless
#
# The cache holds each pre-fetched band's *raw* gather — before claim
# exclusion, before `sources` gating, before `emit_first_seen` — so the
# caller can re-apply this cycle's own fresh claims and fresh `sources`
# config to a cached read exactly as it does to a fresh one; only the
# underlying GitHub read itself is skipped for a repository not picked this
# cycle. A claim landed by a peer since a repository's last expensive read
# therefore still excludes a cached candidate this cycle, and a `sources`
# edit still gates a cached band, even though neither required a fresh `gh`
# call to take effect.
#
# Sourced by agent-cycle.sh, ahead of lib/candidate-gather.sh, which is the
# only caller.

# _expensive_gather_cache_dir STATE_DIR
_expensive_gather_cache_dir() {
  printf '%s/expensive-gather' "$1"
}

# _expensive_gather_cache_path STATE_DIR SLUG
_expensive_gather_cache_path() {
  local state_dir="$1" slug="$2" safe="${2//\//_}"
  printf '%s/%s.json' "$(_expensive_gather_cache_dir "$state_dir")" "$safe"
}

# expensive_gather_pick_repo STATE_DIR REPOS_JSON
# Print the slug, among REPOS_JSON's `.[].slug` entries, whose cache file is
# oldest — a repository never yet cached sorts as epoch 0, so it is always
# picked ahead of one this node has already read at least once. Ties (every
# configured repository uncached, most often the fleet's first-ever cycle)
# break on slug, ascending, for a deterministic answer rather than one that
# depends on `jq`'s own array order.
#
# REPOS_JSON with no entries prints nothing; the caller must treat that as
# "nothing to pick" rather than call this with an empty set.
expensive_gather_pick_repo() {
  local state_dir="$1" repos_json="$2" slug path mtime
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    path="$(_expensive_gather_cache_path "$state_dir" "$slug")"
    mtime=0
    if [[ -f "$path" ]]; then
      mtime="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
      [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    fi
    printf '%012d\t%s\n' "$mtime" "$slug"
  done < <(jq -r '.[]?.slug // empty' <<<"$repos_json" 2>/dev/null) \
    | sort \
    | head -n1 \
    | cut -f2-
}

# expensive_gather_cache_load STATE_DIR SLUG
# Print the cached raw-gather object for SLUG, or nothing when there is none
# yet or it cannot be parsed — the same "unknown, never fabricated" direction
# every other cache/liveness read in this Script takes.
expensive_gather_cache_load() {
  local state_dir="$1" slug="$2" path
  path="$(_expensive_gather_cache_path "$state_dir" "$slug")"
  [[ -f "$path" ]] || return 0
  jq -c 'select(type == "object")' "$path" 2>/dev/null || true
}

# expensive_gather_cache_save STATE_DIR SLUG JSON
# Persist JSON (an object) as SLUG's cache, atomically (write-then-rename,
# the same pattern `labels_ensure_stamped`'s stamp file uses) so a cycle
# killed mid-write never leaves a half-written cache another cycle would try
# to parse. The file's own mtime is what `expensive_gather_pick_repo` reads
# back as this repository's last-read time — no separate stamp file. Best
# effort: a write failure (a read-only state_dir, a full disk) is reported by
# a non-zero return and never raised to the caller's own cycle, the same
# advisory contract `labels_ensure_stamped` already keeps.
expensive_gather_cache_save() {
  local state_dir="$1" slug="$2" json="$3" dir path tmp
  dir="$(_expensive_gather_cache_dir "$state_dir")"
  path="$(_expensive_gather_cache_path "$state_dir" "$slug")"
  tmp="$path.tmp.$$"
  mkdir -p "$dir" 2>/dev/null \
    && printf '%s' "$json" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$path" 2>/dev/null
}
