#!/usr/bin/env bash
#
# gather-register-hygiene.sh — pre-fetch a repo's tech-debt register when it
# has fallen out of internal consistency (requirement 3i): an item file whose
# frontmatter disagrees with its filename, its repository's declared scope,
# or itself.
#
# Given a repo slug, print a JSON array holding at most one candidate: the
# repo's register, if `scripts/td-check.pl` says it disagrees with itself.
#
# Usage: gather-register-hygiene.sh <owner/repo> [default-branch] [void-json]
#
# `void-json` (default `[]`) is this repo's slice of the fleet's void set,
# already filtered to ids shaped like a tech-debt register id
# (`lib/work-gone.sh`'s own `WORK_GONE_REGISTER_RE`, the one definition —
# requirement 34a):
#   [{"item": "TD-PPpfid-26071901", "detail": "…", "evidence": "…"}]
#
#
# Candidate shape:
#   {
#     "source": "register-hygiene",
#     "ref": "register-hygiene-413128de0d60",   // scoped to THIS register state
#     "url": "https://github.com/…/tree/main/tech-debt",
#     "blob_sha": "413128de0d60d9502bf469348bc70fbbacccf569",
#     "problems": ["STALE FIELD    TD-PPpoet-26072424.md (resolved: …)"],
#     "body": "…the whole of td-check.pl's output, verbatim…"
#   }
# `blob_sha` carries the register's identity object: the `tech-debt/` tree
# SHA.
#
# ## What the register promises, and how it breaks
#
# Every repo here keeps its deferred work in a per-item tech-debt register:
# one file per item under `tech-debt/`, frontmatter carrying the record's
# state (id, status, dates, ref), with the root `TECH-DEBT.md` holding only
# policy and the repository's declared scope. The checkable promises are per
# file: the id matches the filename and the declared scope, the status is
# recognised, and the resolution fields agree with it.
# `scripts/td-check.pl` is those promises written down.
#
# Resolution is a frontmatter flip with no second edit to forget, so the
# drift surface is small — a copy-pasted id, a wrong scope, a status typo —
# but resolutions also arrive from humans and from interactive sessions that
# no prompt governs, so it is watched all the same. Hence two layers, and
# this script is the second of them:
#   1. Each consumer repo runs `td-check.pl` on its own register in CI
#      (`.github/workflows/tech-debt-register.yml`), so the pull request that
#      *creates* drift fails its own checks and never lands.
#   2. This source detects and repairs whatever lands anyway — a direct push,
#      or a merge that reintroduces an inconsistency.
# The first layer is what makes this one cheap: with the guards in place the
# volume trends to zero, and an empty array costs two API reads.
#
# ## Why the Script fetches this and not the Co-Ordinator
#
# The same three reasons as gather-review-feedback.sh (requirement 3c) and
# gather-merge-conflicts.sh (requirement 3g):
#   1. Cost: the answer is one register read and one Perl run. Asking a model
#      to cross-check a register against its own rules — for three repos,
#      every cycle, almost always to conclude "consistent" — is paying model
#      tokens for `diff`.
#   2. Determinism, which matters more here than for any other source: the
#      candidate rule *is* `td-check.pl`'s exit status, and that same script is
#      what the consumer repos' CI runs and what the Implementor re-runs until
#      it passes. One definition, three consumers (requirement 34a). A model
#      re-deriving the rule would be a fourth opinion about what a consistent
#      register looks like, and the one that disagreed would be the one nobody
#      noticed.
#   3. The checker's output is the Implementor's brief and must reach it
#      verbatim — every problem line names an item file and what disagrees,
#      which is the whole of what makes the repair mechanical.
#
# ## The candidate rule
#
# The register is a candidate iff `td-check.pl` exits 1 against it — that is,
# iff it reports at least one of BAD NAME, BAD FRONTMATTER, MISSING FIELD,
# BAD FIELD, BAD STATUS, BAD SCOPE, NO SCOPE, ID MISMATCH, DATE MISMATCH,
# STALE FIELD or DUPLICATE ID. There is no severity ordering and no partial
# candidacy: the register is either consistent or it is not, and the repair
# is one pull request either way. At most one candidate per repo, for the
# same reason — there is only one register.
#
# ## VOIDED STATUS: a second, disjoint source of candidacy (issue #240)
#
# `td-check.pl`'s rules are all internal — they ask whether a register file
# agrees with itself, its filename and its repository's declared scope.
# There is a second way a register row can be wrong that none of them can
# see: the fleet's own void log (requirement 34c) already knows the item is
# done — voided with evidence, most often because the fix landed some way
# other than that item's own claim branch — and the register file still says
# `status: open`. `td-check.pl` finds nothing wrong with that file in
# isolation, so it never would, and the row sits there advertising
# unfinished work forever (TD-PPpfid-26071901, voided in July, still `open`
# months later).
#
# So, given `void-json`, this checks each named id's own file (already
# in hand, from the same tarball) for its on-disk `status:`, and where it is
# still `open` or `in-progress`, appends a `VOIDED STATUS` problem line —
# this script's own label, not one of `td-check.pl`'s, and never fed back
# into it: the byte-identical upstream copy (`TECH-DEBT-REGISTER.md` in
# Poetic-Poems/poetic) stays exactly what it is, a checker of internal
# consistency, and this stays the second, cross-referencing layer the
# register-hygiene *source* — not the checker — has always been free to add.
# A register with no `td-check.pl` problems but one `VOIDED STATUS` still
# becomes a candidate; the pull request that repairs it flips that one item's
# `status:` to `resolved` (or clears stray resolution fields, whichever the
# void's own evidence supports), exactly like any other register-hygiene
# repair.
#
# A repo with no `tech-debt/` directory contributes `[]`, and that is a
# normal answer, not an error: not every repo this fleet touches keeps a
# register, and one that keeps an as-yet-empty register (a scope-declaring
# TECH-DEBT.md with no items filed) has nothing this source could repair —
# its scope declaration is validated by its own CI.
#
# ## Why the ref is scoped to the register's identity
#
# `register-hygiene-<12 hex>`, not a bare `register-hygiene`. An item recorded
# blocked (requirement 34) stays blocked until something clears it, so a bare
# ref that an Implementor once failed to repair would still be blocked after
# the register had moved on — and the new state, which might be trivially
# repairable, would never be looked at again. Scoping the ref to the register's
# content means each distinct *state* is its own item that no older block
# covers; a repair changes the state and so retires the ref; drift re-detected
# against an unchanged register keeps the same ref and stays correctly blocked;
# and a commit that touches anything else in the repo leaves the item exactly
# as it was. Same expiry-by-irrelevance reasoning as merge-conflicts' and
# abandoned-drafts' per-head refs.
#
# The register's state is two git objects — the `tech-debt/` tree *and* the
# policy file that declares the scope (a NO SCOPE/BAD SCOPE repair edits only
# the latter) — so the ref is the first 12 of a sha256 over both SHAs, and a
# repair to either half retires it.
#
# ## Why this array needs no fingerprint argument of its own — and is
# ## fingerprinted verbatim regardless
#
# The other pre-fetched arrays exist partly because their candidacy turns on
# something no repo signal carries: a draft going stale is the passage of time,
# and a ready PR turning CONFLICTING is GitHub recomputing mergeability a cycle
# after some *other* PR merged. Neither moves anything else the no-op
# fingerprint (requirement 3b) hashes.
#
# This source has no such problem. Drift is a pure function of the register's
# content, so it can only appear on a commit to the default branch, and a
# commit moves the repo's `head_sha` — which the fingerprint already covers.
# There is no transition here that the existing signals would sleep through.
#
# The array is still fed to the fingerprint verbatim, alongside the other
# three, for two reasons. First, uniformity: a per-source exception in the
# fingerprint is a thing to remember, and "this one is covered by something
# else" is exactly how a source ends up covered by nothing (see
# lib/noop-skip.sh). Second, and concretely, candidacy depends on the *checker*
# as well as the register — editing `scripts/td-check.pl` here can add or
# remove problems with no commit to the target repo at all, and only this
# array carries that.
#
# Fails safe: always prints a valid JSON array and exits 0. A consistent
# register contributes `[]`; a repo with no register contributes `[]` silently
# (normal); an API that will not answer contributes `[]` too, but with `gh`'s
# own diagnosis left on stderr rather than swallowed — an unexplained `[]` on
# error is the trap in the Gotchas table that cost the sibling gatherers a
# debugging round, and the distinction between "no register" and "no answer"
# is precisely what was missing that day.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

slug="${1:-}"
default_branch="${2:-main}"
void_json="${3:-[]}"
if [[ -z "$slug" ]]; then
  echo "usage: gather-register-hygiene.sh <owner/repo> [default-branch] [void-json]" >&2
  exit 64
fi
jq -e 'type == "array"' <<<"$void_json" >/dev/null 2>&1 || void_json='[]'

work="$(mktemp -d)" || { printf '[]'; exit 0; }
trap 'rm -rf "$work"' EXIT

# One listing read answers both "is there a register?" and "what identity?":
# the root tree names `tech-debt` (a tree) and `TECH-DEBT.md` (the policy
# blob), each with the SHA the ref is derived from.
tree_json="$(gh api "repos/$slug/git/trees/$default_branch" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  # A 404 is the ordinary "this repo (or branch) is gone", reported by the API
  # body, not by guessing at gh's wording. Anything else — auth, rate limit,
  # network — is a failure, and its diagnosis goes to stderr where
  # agent-cycle.sh captures it per cycle. Both answers are `[]`; only one of
  # them is silent.
  if [[ "$(jq -r '.status // ""' <<<"$tree_json" 2>/dev/null)" != "404" ]]; then
    cat "$work/gh.err" >&2
  fi
  printf '[]'
  exit 0
fi

dir_sha="$(jq -r '[.tree[] | select(.path == "tech-debt" and .type == "tree") | .sha] | first // ""' <<<"$tree_json" 2>/dev/null || true)"
policy_sha="$(jq -r '[.tree[] | select(.path == "TECH-DEBT.md" and .type == "blob") | .sha] | first // ""' <<<"$tree_json" 2>/dev/null || true)"

# No item directory means nothing this source could repair — a repo with no
# register at all, or one whose register is still empty. Both are normal,
# silent [].
if [[ -z "$dir_sha" ]]; then
  printf '[]'
  exit 0
fi

# The whole register arrives in one read via the tarball endpoint — cheaper
# and simpler than a blob fetch per item, and the extraction root carries
# both halves the checker needs: `tech-debt/` and the policy file beside it
# that declares the repository's scope.
if ! gh api "repos/$slug/tarball/$default_branch" > "$work/register.tar.gz" 2>"$work/gh.err"; then
  cat "$work/gh.err" >&2
  printf '[]'
  exit 0
fi
if ! tar -xzf "$work/register.tar.gz" -C "$work" 2>/dev/null; then
  echo "gather-register-hygiene: $slug: could not extract the tarball" >&2
  printf '[]'
  exit 0
fi
root=""
for d in "$work"/*/; do
  [[ -d "$d" ]] && root="${d%/}" && break
done
if [[ -z "$root" || ! -d "$root/tech-debt" ]]; then
  echo "gather-register-hygiene: $slug: tarball held no tech-debt/ directory" >&2
  printf '[]'
  exit 0
fi

# Checked from the extraction root, so the output names `tech-debt/…` — the
# paths a human or an Implementor would type.
out="$(cd "$root" && perl "$SCRIPT_DIR/td-check.pl" tech-debt 2>&1)"
check_rc=$?
ref="register-hygiene-$(printf '%s:%s' "$dir_sha" "$policy_sha" | sha256sum | cut -c1-12)"
url="https://github.com/$slug/tree/$default_branch/tech-debt"

# Anything above 1 is td-check.pl failing to run at all (usage, I/O), which
# is our problem and not the register's: say so and contribute nothing at
# all — the void cross-reference below is skipped too, deliberately: a
# checker that never checked is not a trustworthy base to layer a second
# problem class on.
if (( check_rc > 1 )); then
  printf '%s\n' "$out" >&2
  printf '[]'
  exit 0
fi

# The problem lines, split out of the report so the Co-Ordinator can price the
# item without parsing prose, while `body` keeps the report whole for the
# Implementor. The labels are td-check.pl's own; keep the two in step.
# check_rc == 0 (a consistent register, per td-check.pl) leaves this empty —
# the ordinary answer this source expects to give almost every cycle — and
# nothing here forces `out` non-empty for it either, unlike the guard above.
problems="$(grep -E '^[[:space:]]+(BAD NAME|BAD FRONTMATTER|MISSING FIELD|BAD FIELD|BAD STATUS|BAD SCOPE|NO SCOPE|ID MISMATCH|DATE MISMATCH|STALE FIELD|DUPLICATE ID)' <<<"$out" \
            | jq -Rn '[inputs | sub("^ +"; "")]' 2>/dev/null || true)"
[[ -n "$problems" ]] || problems='[]'

# VOIDED STATUS (issue #240, requirement 34k) — the second, disjoint source
# of candidacy the header describes: an item the fleet's void log already
# knows is done, whose file on disk still says otherwise. Read straight from
# the tarball already extracted, so this costs no extra API call.
void_problems='[]'
while IFS=$'\t' read -r v_item v_detail; do
  [[ -n "$v_item" ]] || continue
  v_file="$root/tech-debt/$v_item.md"
  [[ -f "$v_file" ]] || continue
  v_status="$(awk '
    /^---[[:space:]]*$/ { c++; next }
    c == 1 && /^status:[ \t]*/ { sub(/^status:[ \t]*/, ""); print; exit }
    c >= 2 { exit }
  ' "$v_file" 2>/dev/null || true)"
  [[ "$v_status" == "open" || "$v_status" == "in-progress" ]] || continue
  void_problems="$(jq -c --arg l "VOIDED STATUS  tech-debt/$v_item.md (status: $v_status; void: $v_detail)" \
    '. + [$l]' <<<"$void_problems" 2>/dev/null || printf '%s' "$void_problems")"
done < <(jq -r '.[] | select((.item // "") != "") | [.item, (.detail // "no reason given")] | @tsv' \
         <<<"$void_json" 2>/dev/null || true)

problems="$(jq -c -n --argjson a "$problems" --argjson b "$void_problems" '$a + $b')"
if [[ "$(jq 'length' <<<"$problems" 2>/dev/null || echo 0)" == "0" ]]; then
  printf '[]'
  exit 0
fi
body="$out$(jq -r 'if length == 0 then "" else
  "\n\nVOIDED STATUS (requirement 34k, not td-check.pl'"'"'s own): the fleet'"'"'s void log records the following items as already done, but their register status has not been flipped:\n" + (map("  " + .) | join("\n"))
  end' <<<"$void_problems" 2>/dev/null || true)"

jq -nc \
  --arg ref "$ref" \
  --arg url "$url" \
  --arg blob_sha "$dir_sha" \
  --argjson problems "$problems" \
  --arg body "$body" \
  '[{source: "register-hygiene",
     ref: $ref,
     url: $url,
     blob_sha: $blob_sha,
     problems: $problems,
     body: $body}]'
