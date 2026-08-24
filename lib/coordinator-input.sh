#!/usr/bin/env bash
#
# lib/coordinator-input.sh — fit the Co-Ordinator's runtime input inside its
# model's context window (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 4i,
# agent-ops#641).
#
# Requirement 4g moved every fleet-state aggregate off argv because
# `MAX_ARG_STRLEN` had taken the fleet down; its own spec text records that
# doing so "raised the ceiling; it did not stop the set from still climbing
# toward whatever ceiling came next". This module is what happens when the
# next ceiling arrives. On 2026-08-21 the Co-Ordinator's assembled prompt
# reached ~226580 tokens against its model's 200000-token window and every
# node failed identically, four cycles running, `coordinator exited 1` with an
# empty `coordinator.out.stderr` — the API refusal is in `coordinator.out`,
# not on stderr, so the fleet's own escalation pointed at an empty file
# (agent-ops#641). Nothing had gone wrong: the input had simply grown, one
# issue comment at a time, from 212999 tokens to 226580 over four cycles, past
# a limit no code in this repository had ever measured itself against.
#
# ## What is bounded, and what is not
#
# The bound is on the *assembled prompt*, because that is the thing the window
# rejects — not on the runtime input alone. The base prompt is over 100 KB of
# its own and grows with every requirement written into it, so budgeting only
# the input would let prompt growth silently eat the input's headroom and
# arrive back here. `agent-cycle.sh` therefore measures the rendered base
# prompt, subtracts it (and the rest of the input document that is not
# sheddable), and hands what is left to this module as the allowance.
#
# What this module sheds is prose from the two bands that carry a whole
# document each — `issues` (an issue's entire thread) and `tech_debt` (an
# entire register file). That pairing is not new here: requirement 2.2a's
# back-pressure block already singles out exactly those two, for exactly the
# same reason, when it empties them on a restricted cycle. Every other band is
# left alone, and deliberately: `review-feedback`, `merge-conflicts`,
# `dequeued`, `abandoned-drafts`, `register-hygiene` and `human-visibility` all
# carry bodies `prompts/coordinator.md` requires pasted *verbatim* into the
# work order, they are bounded by the number of open pull requests rather than
# by history, and together they were 34 KB of the 354 KB that overflowed.
#
# ## Prose is shed; candidacy is not
#
# Every rung below removes text and leaves the entry a candidate, with its
# `ref`, `number`, `url`, `title`, `priority`, `labels` and `updated_at`
# untouched — an item the Co-Ordinator can still see, still rank and still
# select. What it cannot do is paste an elided body verbatim into the work
# order, so every cut leaves a marker naming how many bytes went and where the
# whole of it lives, and `prompts/coordinator.md` obliges a live read of that
# URL before selecting a marked entry. The cost is therefore one fetch for the
# one item actually selected, not a thread's worth of tokens for every item
# considered.
#
# The last rung is the exception, and is last for that reason: with the
# tightest per-entry caps applied there is nothing left to shed but entries
# themselves, and an entry dropped here is one the Co-Ordinator never sees.
# Dropping is by a stated order (least important last-kept), the count is
# recorded on the repo entry the Co-Ordinator reads and in the union log, and
# `agent-cycle.sh` applies the whole fit *before* `coordinator_eligible_items`
# — so requirement 3x's corroboration measures the set actually offered and a
# dropped entry can never read as an unaccounted-for decline.
#
# ## Why a ladder rather than a computed cut
#
# A per-entry allowance divided out of the budget punishes small entries for
# their neighbours' size and needs a second pass to redistribute the slack. The
# ladder instead states six shapes of input, generous first, and walks only as
# far as the budget requires: an ordinary cycle stops at the first rung having
# trimmed nothing at all, and each rung a cycle does reach is a sentence a
# human can read off the log ("newest 3 comments, 1500 bytes each"). Every rung
# is re-measured against the real assembled document rather than predicted, so
# the ladder converges whatever the input's shape.
#
# Sourced by agent-cycle.sh.

# The ladder: `comments_kept:comment_bytes:body_bytes`, generous first. The
# first rung trims only pathological outliers — a 20 KB body or a 12 KB
# comment is already past what any reader needs to rank an item — and the last
# leaves a title, the identity fields and an opening paragraph. The steps
# between are deliberately close together: a coarse ladder overshoots, and an
# input a few kilobytes over the allowance should lose a few kilobytes of
# prose, not half the thread it happened to sit above. Byte caps, not
# character caps, because bytes are what the window is spent in: JSON-escaped
# Markdown runs about 2.35 bytes per token, roughly half the ~4 of the prose it
# encodes, because every newline and quote in it becomes an escape.
COORDINATOR_INPUT_TIERS=(
  "20:12000:20000"
  "10:6000:12000"
  "6:3000:8000"
  "4:2000:6000"
  "3:1500:4000"
  "2:1200:3000"
  "1:800:2000"
  "0:0:1000"
)

# Decision (agent-ops#683): the bottom rung above stays a trim, not a drop.
# Reaching it used to mean every candidate's body was cut to a title-level
# fragment, comments emptied outright, and the Co-Ordinator — correctly
# following its own prompt's "if you cannot tell what done would mean, report
# needs_refinement" — dutifully reported exactly that for its whole visible
# backlog, which requirement 3x's completeness bar then compelled the Script
# to record as blocks (nine items in 68 seconds, 2026-08-21). That made
# "drop entries here instead of trimming them" a real candidate fix: an entry
# this small could not be judged either way, so keeping it costs a candidate
# slot for something the Co-Ordinator cannot use.
#
# `coordinator_fit_trim_refusal_reason` above removes that harm at its
# source: a trimmed entry can no longer force a block, so all a bottom-rung
# entry still buys the Co-Ordinator is its identity fields (`ref`, `title`,
# `priority`, `labels`, `updated_at`) — enough to rank it, and enough to
# select and live-read it should its title alone look worth the fetch.
# Dropping it instead would remove that option for no remaining harm left to
# trade it against, so the ladder is unchanged: eight rungs, generous first,
# `0:0:1000` last.

# The per-band, per-repo entry caps the last rung walks once the tightest tier
# above still does not fit — halving, so a wildly oversized input converges in
# a handful of measurements rather than one per entry.
COORDINATOR_INPUT_ENTRY_CAPS=(64 32 16 8 4 2 1)

# The jq program every rung runs. Bound as a shell variable rather than
# repeated at three call sites so the ladder and the entry caps cannot drift
# apart in what they do to an entry.
#
# Measurement is `utf8bytelength` and slicing is by codepoint, which are the
# same unit only for ASCII. The mismatch is deliberate and safe in the one
# direction that matters: a codepoint slice can leave slightly more than the
# byte cap asked for, never a mangled character, and the caller re-measures the
# whole document after every rung — so an input dense in multi-byte text
# simply lands one rung further down the ladder rather than escaping the bound.
read -r -d '' COORDINATOR_INPUT_FIT_JQ <<'JQ' || true
def clip($n; $url):
  . as $s
  | ($s | utf8bytelength) as $total
  | if $total <= $n then $s
    elif $n <= 0 then
      "…[Script: elided all \($total) bytes to fit the context window — read it whole at \($url)]"
    else
      ($s[0:$n]) as $head
      | $head
        + "\n\n…[Script: elided \($total - ($head | utf8bytelength)) of \($total) bytes to fit the context window — read it whole at \($url)]"
    end;

# One entry, trimmed to this rung. `body` and comment bodies are the only
# fields touched; identity, priority and timestamps are what selection runs on
# and are never shed.
def fit_entry($cb; $bb; $keep):
  . as $e
  | (($e.url // "") | tostring) as $u
  | ($e.comments // null) as $cs
  | $e
    + (if ($e.body | type) == "string" then {body: ($e.body | clip($bb; $u))} else {} end)
    + (if ($cs | type) == "array" then
         (if ($cs | length) > $keep
          then {comments_elided: (($cs | length) - $keep)}
          else {} end)
         + {comments:
              ((if $keep <= 0 then [] else $cs[-$keep:] end)
               | map(. + (if (.body | type) == "string"
                          then {body: (.body | clip($cb; $u))}
                          else {} end)))}
       else {} end);

# The order the last rung keeps entries in — most worth the Co-Ordinator's
# attention first, so a cap takes from the bottom. Issues rank by the same
# four Priority bands requirement 15e ranks on, then by the freshest thread;
# tech-debt has no band, so the oldest item — the one that has waited longest —
# is kept first.
def issue_rank: {Urgent: 4, High: 3, Medium: 2, Low: 1}[(.priority // "Medium") | tostring] // 2;
# Ascending on [band, thread freshness] and then reversed, which is one total
# order rather than two sorts relying on jq's tie-breaking: highest band first,
# and freshest thread first within a band.
def keep_order_issues: sort_by([issue_rank, ((.updated_at // "") | tostring)]) | reverse;
def keep_order_tech_debt: sort_by((.filed // "") | tostring);

# Reordering and capping are one step, applied only when there is a cap to
# apply: with no entries to drop the order the gatherer produced is the order
# the Co-Ordinator receives, so a trimmed cycle differs from an untrimmed one
# in prose alone and in nothing else.
def cap($max; keep_order): if $max == null then . else keep_order | .[0:$max] end;

# A band is rewritten only where the repo entry actually carried it. Adding
# `"issues": []` to an entry that never had the key would be a shape this
# module invented — harmless to every reader downstream, which all spell it
# `.issues // []`, and still the wrong thing to do to an input whose only
# difference from the untrimmed one should be prose the fit removed.
[ .[]
  | . as $repo
  | (.issues // []) as $iss
  | (.tech_debt // []) as $td
  | $repo
    + (if ($repo | has("issues")) then
         {issues: ($iss | cap($emax; keep_order_issues) | map(fit_entry($cb; $bb; $keep)))}
         + (if $emax != null and ($iss | length) > $emax
            then {issues_elided: (($iss | length) - $emax)} else {} end)
       else {} end)
    + (if ($repo | has("tech_debt")) then
         {tech_debt: ($td | cap($emax; keep_order_tech_debt) | map(fit_entry($cb; $bb; $keep)))}
         + (if $emax != null and ($td | length) > $emax
            then {tech_debt_elided: (($td | length) - $emax)} else {} end)
       else {} end) ]
JQ

# coordinator_apply_rung KEEP COMMENT_BYTES BODY_BYTES ENTRY_MAX
# Repos JSON on stdin, the trimmed array on stdout. ENTRY_MAX empty means no
# entry cap. Every value is a number this file or a validated config key
# produced, so these four stay in argv; the repo array — unbounded with the
# fleet's history — arrives on stdin (requirement 4g).
coordinator_apply_rung() {  # <keep> <comment-bytes> <body-bytes> [entry-max]
  local keep="$1" cb="$2" bb="$3" emax="${4:-}"
  [[ -n "$emax" ]] || emax="null"
  jq -c --argjson keep "$keep" --argjson cb "$cb" --argjson bb "$bb" \
    --argjson emax "$emax" "$COORDINATOR_INPUT_FIT_JQ"
}

# coordinator_fit_bands BUDGET_BYTES
# The repo array on stdin; one JSON object on stdout:
#
#   {"repos": [...], "fit": {"applied": bool, "fits": bool, "rung": n,
#                            "comments_kept": n, "comment_bytes": n,
#                            "body_bytes": n, "entries_max": n|null,
#                            "bytes_before": n, "bytes_after": n,
#                            "entries_dropped": n, "budget": n}}
#
# `applied` is false, and `repos` is the input verbatim, when the array already
# fits — the ordinary cycle, which pays one measurement and nothing else.
# `fits` is false only when even the last rung's tightest entry cap leaves the
# array over budget, which the caller reports as a warning: at that point the
# identity fields alone have outgrown the window and no amount of shedding
# prose will help.
#
# A budget of 0 or less, or a stdin document that is not an array, is answered
# with the input unchanged and `applied: false` — a malformed budget must not
# be able to strip every candidate out of a cycle, which is the one failure
# here worse than the overflow this module exists to prevent.
#
# BUDGET_BYTES is measured in the units the prompt is actually spent in: the
# array *pretty-printed*, because `agent-cycle.sh` renders the runtime input
# with `jq .` and it is those bytes the window charges for. The caller's own
# arithmetic (requirement 4i) subtracts the base prompt and the rest of the
# document from the configured maximum before calling.
coordinator_fit_bands() {  # <budget-bytes>  (repos JSON on stdin)
  local budget="${1:-0}" repos out="" size before rung=0 tier keep cb bb emax entries_before
  repos="$(cat)"
  jq -e 'type == "array"' <<<"$repos" >/dev/null 2>&1 || repos='[]'
  [[ "$budget" =~ ^[0-9]+$ ]] || budget=0

  before="$(coordinator_rendered_bytes <<<"$repos")"
  if (( budget <= 0 || before <= budget )); then
    coordinator_fit_emit "$(jq -nc --argjson s "$before" --argjson b "$budget" \
      '{applied: false, fits: true, rung: 0, bytes_before: $s, bytes_after: $s,
        entries_dropped: 0, budget: $b}')" <<<"$repos"
    return 0
  fi

  entries_before="$(jq '[.[] | ((.issues // []) | length) + ((.tech_debt // []) | length)] | add // 0' <<<"$repos")"

  # The prose ladder. Walked in order and stopped at the first rung that fits,
  # so an input a little over budget is trimmed a little.
  for tier in "${COORDINATOR_INPUT_TIERS[@]}"; do
    rung=$(( rung + 1 ))
    IFS=: read -r keep cb bb <<<"$tier"
    out="$(coordinator_apply_rung "$keep" "$cb" "$bb" <<<"$repos" 2>/dev/null)" || continue
    size="$(coordinator_rendered_bytes <<<"$out")"
    if (( size <= budget )); then
      coordinator_fit_report "$rung" "$keep" "$cb" "$bb" "null" "$size" "$before" \
        "$budget" "$entries_before" true <<<"$out"
      return 0
    fi
  done

  # Every rung of prose is gone and the array is still over. Only entries are
  # left to shed, at the tightest tier's caps.
  IFS=: read -r keep cb bb <<<"${COORDINATOR_INPUT_TIERS[${#COORDINATOR_INPUT_TIERS[@]}-1]}"
  for emax in "${COORDINATOR_INPUT_ENTRY_CAPS[@]}"; do
    rung=$(( rung + 1 ))
    out="$(coordinator_apply_rung "$keep" "$cb" "$bb" "$emax" <<<"$repos" 2>/dev/null)" || continue
    size="$(coordinator_rendered_bytes <<<"$out")"
    if (( size <= budget )); then
      coordinator_fit_report "$rung" "$keep" "$cb" "$bb" "$emax" "$size" "$before" \
        "$budget" "$entries_before" true <<<"$out"
      return 0
    fi
  done

  # One entry per band per repo and still over budget. Hand back the smallest
  # array the ladder can build and say it does not fit: a Co-Ordinator that
  # fails on the window is bad, and one silently given nothing is worse.
  #
  # `out` empty means every rung's own jq failed, which is not a shape any
  # caller should have to reason about: answer with the input unchanged, the
  # same fail-open direction every guard in agent-cycle.sh takes.
  [[ -n "$out" ]] || { out="$repos"; size="$before"; }
  coordinator_fit_report "$rung" "$keep" "$cb" "$bb" \
    "${COORDINATOR_INPUT_ENTRY_CAPS[${#COORDINATOR_INPUT_ENTRY_CAPS[@]}-1]}" \
    "$size" "$before" "$budget" "$entries_before" false <<<"$out"
}

# The size of one repo array as the assembled prompt will carry it — `jq .`,
# the same rendering "--- 4. Co-Ordinator stage ---" performs, never the
# compact form. The two differ by only a few percent on this data (the bulk is
# long string values, not structure), but the bound is worth nothing if it is
# measured in units the window does not charge in.
coordinator_rendered_bytes() {  # (JSON on stdin)
  local n
  n="$(jq . 2>/dev/null | wc -c)" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# The reporting half of the above, factored out so the three exits cannot
# disagree about the shape they print. The repo array arrives on stdin, never
# in argv (requirement 4g): it is the same unbounded fleet-state aggregate the
# rest of this Script has already been swept for, and putting it back into an
# `--argjson` here would reintroduce exactly the `MAX_ARG_STRLEN` death that
# requirement 4g exists to prevent — as the first draft of this function did,
# and as `test/coordinator-input.test.sh` now pins.
coordinator_fit_emit() {  # <fit-json>  (repos JSON on stdin)
  jq -c --argjson fit "${1:-{\}}" '{repos: ., fit: $fit}'
}

coordinator_fit_report() {  # <rung> <keep> <cb> <bb> <emax> <size> <before> <budget> <entries-before> <fits>  (repos on stdin)
  local rung="$1" keep="$2" cb="$3" bb="$4" emax="$5" size="$6" before="$7" \
        budget="$8" entries_before="$9" fits="${10}" repos entries_after dropped
  repos="$(cat)"
  entries_after="$(jq '[.[] | ((.issues // []) | length) + ((.tech_debt // []) | length)] | add // 0' <<<"$repos" 2>/dev/null || echo 0)"
  [[ "$entries_after" =~ ^[0-9]+$ ]] || entries_after=0
  [[ "$entries_before" =~ ^[0-9]+$ ]] || entries_before=0
  dropped=$(( entries_before - entries_after ))
  (( dropped >= 0 )) || dropped=0
  coordinator_fit_emit "$(jq -nc --argjson rung "$rung" --argjson keep "$keep" \
    --argjson cb "$cb" --argjson bb "$bb" --argjson emax "$emax" \
    --argjson size "$size" --argjson before "$before" --argjson budget "$budget" \
    --argjson dropped "$dropped" --argjson eb "$entries_before" --argjson fits "$fits" \
    '{applied: true, fits: $fits, rung: $rung, comments_kept: $keep,
      comment_bytes: $cb, body_bytes: $bb, entries_max: $emax,
      bytes_before: $before, bytes_after: $size, budget: $budget,
      entries_dropped: $dropped, entries_before: $eb}')" <<<"$repos"
}

# coordinator_fit_detail FIT_JSON
# The one-line human sentence the union log and any escalation carry. Written
# here rather than at the call site because it is the only place that knows
# what a rung means, and a reader of the log should never have to open this
# file to find out what "rung 4" trimmed.
coordinator_fit_detail() {  # <fit-json>
  jq -r '
    if (.applied | not) then empty
    else
      "the Co-Ordinator'"'"'s issues and tech-debt bands were trimmed to fit its model'"'"'s context window: "
      + "\(.bytes_after) bytes against a \(.budget)-byte allowance (rung \(.rung) — "
      + "newest \(.comments_kept) comment(s) at \(.comment_bytes) bytes each, bodies at \(.body_bytes) bytes"
      + (if (.entries_max // null) == null then "" else ", at most \(.entries_max) entries per band per repo" end)
      + ")"
      + (if (.entries_dropped // 0) > 0
         then ", and \(.entries_dropped) of \(.entries_before) entries were dropped outright"
         else "" end)
      + (if .fits then "" else " — and it still does not fit, so this cycle'"'"'s Co-Ordinator will be refused by the API" end)
    end' <<<"${1:-{\}}" 2>/dev/null || true
}

# coordinator_fit_trimmed_items
# Which candidates in the `issues`/`tech_debt` bands actually had their body
# or comments shed by the fit ladder this cycle — `{repo, item, source}` per
# entry, the same shape `coordinator_eligible_items` (agent-cycle.sh) already
# uses for its own denominator. Only entries `fit_entry` actually touched: the
# ladder applies one set of caps to the whole document, but whether a given
# entry exceeded them is per-entry, and a small entry no rung ever needed to
# shrink is not "trimmed" just because its neighbours were.
#
# This is the exemption set behind requirement 34e's fourth refusal and
# requirement 3x's matching completeness exception (agent-ops#683): on
# 2026-08-21 a context-tight cycle's fit reached its bottom rung, every
# candidate's body was cut to a title-level fragment, and the Co-Ordinator —
# correctly following "if you cannot tell what done would mean, report
# needs_refinement" — reported exactly that for its whole visible backlog,
# which requirement 3x's own completeness bar then obliged the Script to
# record as blocks. Neither rule was wrong; the fix is a Script-side refusal
# to write the block, and a matching carve-out so declining to write it does
# not itself read as an unaccounted verdict.
#
# Detected the same way a human reading the rendered prompt would: the
# elision marker `fit_entry`'s own `clip` leaves in a clipped body, or the
# `comments_elided` key it adds when the comment list itself was cut. Never
# re-measured against the byte caps here — that arithmetic already ran once,
# inside the ladder, and re-deriving it from an entry's current byte length
# would drift the moment either side changed independently. The literal
# `[Script: elided` prefix is deliberately not prose any real issue or
# register body would ever produce, the same reasoning `coordinator_fit_detail`
# above and TD-PPagop-26081407 both rely on for their own sentinels.
#
# Read the *fitted* repos array on stdin — `coordinator_fit_bands`'s own
# `repos` output, whichever rung it stopped at — never the array handed to
# it: an untrimmed document carries none of the markers this looks for, so
# feeding it the pre-fit array would answer "nothing trimmed" correctly, but
# only by accident.
coordinator_fit_trimmed_items() {  # (fitted repos JSON on stdin)
  jq -c '
    def trimmed:
      (((.body // "") | type) == "string" and ((.body // "") | contains("[Script: elided")))
      or has("comments_elided");
    [ .[] | . as $repo | (.slug // "") as $r
      | ( ($repo.issues // [])[] | select(trimmed)
          | {repo: $r, item: ((.ref // "") | tostring), source: "issues"} ),
        ( ($repo.tech_debt // [])[] | select(trimmed)
          | {repo: $r, item: ((.ref // "") | tostring), source: "tech-debt"} )
    ] | map(select(.item != ""))
  ' 2>/dev/null || printf '[]'
}

# coordinator_fit_trim_refusal_reason ENTRY_JSON TRIMMED_JSON RUNG
# Decide whether a needs_refinement-shaped ENTRY (`{repo, item, source,
# reason, missing, evidence}`, from any reporting stage) names an item this
# cycle's fit ladder actually trimmed (requirement 4i, `coordinator_fit_trimmed_items`
# above) — requirement 34e's fourth refusal, agent-ops#683.
#
# Prints nothing and returns 0 when ENTRY may be recorded ordinarily. Prints a
# one-line reason and returns 1 when it must be refused instead — the same
# calling convention `dependency_refusal_reason` (lib/dependency-gate.sh) uses,
# so a caller can chain both bars the same way.
#
# Matched on repo+item alone, not source: TRIMMED_JSON only ever carries the
# two bands the ladder can touch (`issues`, `tech-debt`), whose ref shapes
# never collide (a bare issue number against a `TD…`-prefixed register id), so
# the extra key buys nothing an entry that omitted or mis-stated its own
# `source` would still need.
#
# Deliberately unconditional on what ENTRY's own `reason`/`missing`/`evidence`
# say, and on whether the reporting stage actually fetched the item live
# before writing them: the Script has no way to tell a report grounded in a
# live read from one grounded in the elided extract it was handed, and the
# harm of the rare false refusal is far smaller than the harm of asking the
# question at all on a cycle whose whole backlog was trimmed this far.
coordinator_fit_trim_refusal_reason() {  # <entry-json> <trimmed-json> <rung>
  local entry="$1" trimmed="${2:-[]}" rung="${3:-0}" repo item
  repo="$(jq -r '.repo // ""' <<<"$entry" 2>/dev/null || true)"
  item="$(jq -r '(.item // "") | tostring' <<<"$entry" 2>/dev/null || true)"
  [[ -n "$repo" && -n "$item" ]] || return 0
  jq -e --arg r "$repo" --arg i "$item" \
    'any(.[]?; (.repo // "") == $r and ((.item // "") | tostring) == $i)' \
    <<<"$trimmed" >/dev/null 2>&1 || return 0
  printf 'names an entry the fit ladder trimmed this cycle (rung %s) — the report may be right, but the Script cannot tell it apart from one read off the elided extract, so it is refused and the item stays exactly as eligible as it was' \
    "$rung"
  return 1
}
