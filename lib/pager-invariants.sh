#!/usr/bin/env bash
#
# lib/pager-invariants.sh — the built-in invariants lib/pager.sh's framework
# ships with. Issue #1278 shipped the first two, chosen to exercise every
# branch of the framework itself:
#
#   verdict-unanimous    a pipeline-act invariant, pure over fleet_nodes_json
#                        alone (stage_health/updater/doctor already travel in
#                        every heartbeat — doctor's own verdict was folded in
#                        by this same change, scripts/state-sync.sh).
#   page-outlived-item   a pipeline-act invariant that reads GitHub directly
#                        (via PAGER_EVAL_REPO/PAGER_EVAL_ESCALATION_LABEL,
#                        lib/pager.sh's own documented exception to "pure
#                        over replicated facts") — an escalation issue's own
#                        terminal state is not a fact any heartbeat or union
#                        log carries.
#
# Issue #1282 (part 3c of #1126's findings) adds five more — fleet liveness
# from a *peer's* vantage, the class where every signal a node emitted was
# one it also consumed, so only another node evaluating it can catch the
# gap. All five are owner-only: none has an automatic fix a pipeline could
# perform on its own behalf, unlike verdict-unanimous's tech-debt filing.
#
#   firing-missed          an active node whose newest `cycle-start` *or
#                          `cycle-skipped`* (the implementation union log —
#                          either one proves the scheduler fired) is older
#                          than 2× `schedule.cycle_interval_minutes` while
#                          its heartbeat is fresh and it holds no lock —
#                          caught purely from the union log, since
#                          `lock.json` is never published (scripts/state-
#                          sync.sh excludes it) and
#                          `schedule.cycle_interval_minutes` is fleet-wide
#                          config, identical on every node that reads it,
#                          including the evaluating node itself.
#   node-stale             a node's publication age past 2×
#                          `node_stale_after_minutes` — files only after
#                          `pager_stale_file_after_minutes` (default 180),
#                          a per-key override of the framework's own
#                          `pager_min_firing_minutes` hysteresis
#                          (lib/pager.sh's `PAGER_MIN_FIRING_MINUTES_
#                          OVERRIDE`), because a node gone dark deserves a
#                          faster page than paperwork.
#   updater-stuck          `updater.status == "stuck"` for over 2×
#                          `updater_stuck_after_minutes` on any active node
#                          — `.updater.seconds` already carries the
#                          streak's own elapsed time (lib/updater-health.sh),
#                          so no new bookkeeping is needed to test it.
#   review-pipeline-failing  `review-log.jsonl`'s streak of failed review
#                          *runs*, per node, at or above 3 (the same
#                          threshold lib/stage-health.sh's own
#                          `stage_health_verdicts` uses, not schema-backed
#                          for the identical reason that file states: this
#                          class has not yet seen a real incident to tune
#                          it against) with no completed review between —
#                          a run, not an event, because `review-end` is
#                          written on every run whatever happened (see the
#                          function's own header). The interim reader: #996
#                          stays the proper fix, a verdict folded directly
#                          into the heartbeat the way `stage_health`/
#                          `updater`/`doctor` already are.
#   dashboard-unreadable   a node's `data.js` took longer than
#                          `pager_dashboard_fetch_seconds` to fetch, or
#                          failed to parse, from a *viewer's* vantage — a
#                          fact no node can observe about itself. Reads a
#                          `dashboard_fetch: {seconds, parsed}` field this
#                          issue defines as the contract #1283's own
#                          viewer-vantage probe is expected to fold into
#                          `fleet_nodes_json` the same way `doctor` was
#                          folded in for verdict-unanimous (#1278); until
#                          #1283 lands and populates it, every row's
#                          `dashboard_fetch` is absent and this invariant
#                          never fires — never a false negative from a
#                          producer that does not exist yet, on the same
#                          null-until-populated convention `doctor`/
#                          `updater`/`stage_health` already use for a peer
#                          row built from a heartbeat that predates the
#                          check.
#
# firing-missed, node-stale, updater-stuck and dashboard-unreadable read
# fleet_nodes_json/the union log exactly as verdict-unanimous does, plus one
# more documented exception each — a threshold `pager_evaluate` cannot derive
# from either argument (PAGER_EVAL_CYCLE_INTERVAL_MINUTES and its siblings,
# lib/pager.sh's own header) — on the identical "plain variable, not a third
# EVAL_FN argument" pattern PAGER_EVAL_REPO already established.
# review-pipeline-failing needs a second union log review-log.jsonl is
# fleet-replicated too (scripts/state-sync.sh does not exclude it), so its
# own union travels the same way, via PAGER_EVAL_REVIEW_UNION_LOG_FILE.
#
# Sourced after lib/pager.sh; registration itself is a separate call
# (`pager_register_builtin_invariants`), not top-level code, so a test can
# source this file and register only what it means to exercise.

# pager_eval_verdict_unanimous FLEET_NODES_JSON UNION_LOG_FILE
# Fires when every *active* node (`.stale | not`; fewer than two active nodes
# can never be "unanimous" about anything) reports the identical failing
# verdict at once — the #1071 signature: all four nodes read `updater stuck`
# because the *reader's* rule was wrong, not because every node had
# independently failed the same way at the same instant. Checks, in order,
# the first hit wins: a stage_health stage failing on every active node, the
# updater stuck on every active node, the doctor verdict `fail` on every
# active node.
pager_eval_verdict_unanimous() {
  local fleet_nodes_json="$1"
  jq -c -n --argjson nodes "$fleet_nodes_json" '
    ($nodes | map(select(.stale | not))) as $active
    | if ($active | length) < 2 then {firing: false}
      else
        ( [$active[] | (.stage_health.stages // {}) | keys[]] | unique ) as $stages
        | ( [ $stages[] as $s
              | ($active | map(.stage_health.stages[$s].verdict? // null)) as $verdicts
              | select(($verdicts | length) == ($active | length))
              | select(all($verdicts[]; . == "failing"))
              | {kind: "stage_health[\($s)]", nodes: [$active[].node]}
            ] | first) as $stage_hit
        | ( if ($active | all(.updater.status? == "stuck"))
            then {kind: "updater.status=stuck", nodes: [$active[].node]} else null end ) as $updater_hit
        | ( if ($active | all(.doctor.verdict? == "fail"))
            then {kind: "doctor.verdict=fail", nodes: [$active[].node]} else null end ) as $doctor_hit
        | ($stage_hit // $updater_hit // $doctor_hit) as $hit
        | if $hit == null then {firing: false}
          else {firing: true,
                evidence: "\($hit.kind) on every active node (\($hit.nodes | join(", "))) — the #1071 signature: a uniform fleet-wide failure is almost always the reader being wrong, not every node failing alike at once"}
          end
      end
  ' 2>/dev/null || printf '{"firing":false}'
}

# pager_remedy_verdict_unanimous KEY EVIDENCE
# Pipeline act: files a `pw::type:tech-debt` issue against the reader — this
# pipeline's own repository, since the code that computed the uniform verdict
# (lib/stage-health.sh, lib/updater-health.sh, scripts/doctor.sh) lives here,
# never in a target repo. Reads PAGER_REMEDY_REPO, set by lib/pager.sh's own
# pager_file immediately before calling this.
pager_remedy_verdict_unanimous() {
  local key="$1" evidence="$2" repo="${PAGER_REMEDY_REPO:-}"
  [[ -n "$repo" ]] || { printf 'no pager_repo configured — could not file the tech-debt issue'; return 1; }
  local item="pager-reader:$key" body_file created number
  body_file="$(mktemp)"
  {
    printf 'A fleet-wide invariant fired: every active node reported the same failing verdict at once.\n\n'
    printf '%s\n\n' "$evidence"
    printf 'This is the #1071 signature — a uniform failure across the whole fleet is almost always the *reader* (a bad rule, a bad threshold) rather than every node independently failing the same way at the same instant. Find and fix the rule the evidence above names.\n\n'
    printf -- '---\nFiled automatically by lib/pager.sh (issue #1278).\nref: %s\n' "$item"
  } > "$body_file"
  # No ENSURE_ROLE (lib/pager.sh's 7th parameter): `pw::type:tech-debt` lives
  # in the `target` catalogue, and ensuring that whole role here would mint a
  # dozen unrelated pipeline labels (`refined`, `complexity:*`, `blocked`, …)
  # in a repository that is only ever the *reader's* — often, but not
  # necessarily, also a target repo. The retry-without-label path is the
  # safety net instead: unlike `pw::pager`, nothing later finds this issue by
  # its label — the tech-debt register is the human's own filter, and this
  # function's dedup narrows on the body's `ref:` line regardless.
  if created="$(_pager_create_issue "$repo" "$item" "pw::type:tech-debt" \
        "Pager: verdict-unanimous fired ($evidence)" "$body_file" "")" && [[ -n "$created" ]]; then
    number="${created%%$'\t'*}"
    rm -f "$body_file"
    printf 'filed %s#%s (pw::type:tech-debt)' "$repo" "$number"
    return 0
  fi
  rm -f "$body_file"
  return 1
}

# _pager_open_page_issues -> number\turl\tbody(TSV, newlines squashed to spaces)
# per open issue carrying PAGER_EVAL_ESCALATION_LABEL or pw::pager in
# PAGER_EVAL_REPO. Shared by the eval and remedy functions below so both walk
# the identical listing rather than risking two reads disagreeing.
#
# One listing per label, merged and deduped on the issue number, because the
# relation wanted here is a union and `gh issue list`'s own is an
# intersection: `--label "a,b"` splits on the comma and filters for issues
# carrying *every* name given. No page ever carries both of these labels — an
# Enabler escalation is not a pager page and vice versa — so a single
# comma-joined listing is empty in every real case, which would leave this
# invariant permanently `firing: false`.
#
# `--limit 200` rather than `gh`'s undeclared default of 30, on
# lib/tech-debt-file.sh's own TECHDEBT_DEDUP_LIST_LIMIT reasoning: a
# truncated listing is indistinguishable from a complete one, and the
# listing is newest-first, so the page most likely to have outlived its item
# is exactly the oldest one the cap would hide.
_pager_open_page_issues() {
  local repo="${PAGER_EVAL_REPO:-}" label="${PAGER_EVAL_ESCALATION_LABEL:-enabler-escalation}" gh l
  [[ -n "$repo" ]] || return 0
  gh="${PAGER_GH:-gh}"
  { for l in "$label" "pw::pager"; do
      [[ -n "$l" ]] || continue
      "$gh" issue list -R "$repo" --label "$l" --state open --limit 200 \
        --json number,url,body 2>/dev/null
    done
  } | jq -sr 'add // [] | unique_by(.number) | .[]
              | [.number, .url, (.body // "" | gsub("\n"; " "))] | @tsv' 2>/dev/null
}

# _pager_outlived_ref BODY -> "kind\treference" (kind: pr|issue) for the
# first PR or issue URL BODY names, or nothing. A page's body always carries
# one — every escalation this codebase files links the item it is about.
_pager_outlived_ref() {
  local body="$1" ref
  ref="$(grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' <<<"$body" | head -n1)"
  if [[ -n "$ref" ]]; then printf 'pr\t%s' "$ref"; return 0; fi
  ref="$(grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+' <<<"$body" | head -n1)"
  [[ -n "$ref" ]] && printf 'issue\t%s' "$ref"
  return 0
}

# pager_eval_page_outlived_item FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any open enabler-escalation/pw::pager page's own item — the PR
# or issue its body links — has already gone terminal (merged, closed).
# Deliberately not a pure union-log reader: an issue's live GitHub state is
# the fact in question, so this reads PAGER_EVAL_REPO/PAGER_EVAL_ESCALATION_
# LABEL/PAGER_GH directly (lib/pager.sh's documented exception).
pager_eval_page_outlived_item() {
  local n _url body kind ref state outlived=()
  while IFS=$'\t' read -r n _url body; do
    [[ -n "$n" ]] || continue
    IFS=$'\t' read -r kind ref <<<"$(_pager_outlived_ref "$body")"
    [[ -n "$ref" ]] || continue
    if [[ "$kind" == "pr" ]]; then
      state="$("${PAGER_GH:-gh}" pr view "$ref" --json state --jq '.state' 2>/dev/null)"
      [[ "$state" == "MERGED" || "$state" == "CLOSED" ]] && outlived+=("#$n")
    else
      state="$("${PAGER_GH:-gh}" issue view "$ref" --json state --jq '.state' 2>/dev/null)"
      [[ "$state" == "CLOSED" ]] && outlived+=("#$n")
    fi
  done < <(_pager_open_page_issues)
  if (( ${#outlived[@]} > 0 )); then
    local joined
    joined="$(IFS=', '; printf '%s' "${outlived[*]}")"
    jq -c -n --arg ev "${#outlived[@]} page(s) whose own item already concluded: $joined" \
      '{firing: true, evidence: $ev}'
  else
    printf '{"firing":false}'
  fi
}

# pager_remedy_page_outlived_item KEY EVIDENCE
# Pipeline act: close every outlived page found — the generalisation of
# #1215's approver_escalation_retire from the adjudication page to every
# page this framework or the Enabler files. Re-walks the listing (one more
# `gh issue list`) rather than parsing EVIDENCE's own prose, so a wording
# change to the evidence string can never desync the two.
pager_remedy_page_outlived_item() {
  local n _url body kind ref state closed=0 comment gh
  gh="${PAGER_GH:-gh}"
  while IFS=$'\t' read -r n _url body; do
    [[ -n "$n" ]] || continue
    IFS=$'\t' read -r kind ref <<<"$(_pager_outlived_ref "$body")"
    [[ -n "$ref" ]] || continue
    if [[ "$kind" == "pr" ]]; then
      state="$("$gh" pr view "$ref" --json state --jq '.state' 2>/dev/null)"
      [[ "$state" == "MERGED" || "$state" == "CLOSED" ]] || continue
    else
      state="$("$gh" issue view "$ref" --json state --jq '.state' 2>/dev/null)"
      [[ "$state" == "CLOSED" ]] || continue
    fi
    comment="This page's own item ($ref) is $state. Retiring — the item this page was raised for has already concluded.

---
Retired automatically by lib/pager.sh (issue #1278)."
    "$gh" issue close "$n" -R "${PAGER_EVAL_REPO:-}" --comment "$comment" >/dev/null 2>&1 \
      && closed=$(( closed + 1 ))
  done < <(_pager_open_page_issues)
  printf 'closed %d outlived page(s)' "$closed"
  return 0
}

# --- agent-ops#1282: fleet liveness from a peer's vantage --------------------

# pager_eval_firing_missed FLEET_NODES_JSON UNION_LOG_FILE
# Fires when an *active* node's (`.stale | not`) newest evidence of its
# scheduler firing — a `cycle-start` or a `cycle-skipped` (agent-cycle.sh's
# own `acquire_lock` logs `cycle-skipped` only when it found the lock held
# by another live pid, which is proof the scheduler ticked on schedule and
# deferred correctly, not proof of anything missing) — is older than 2×
# PAGER_EVAL_CYCLE_INTERVAL_MINUTES while it holds no lock — the signature
# of supercronic dropping a firing outright (agent-ops#1287 records the gap
# from the inside: no `cycle-start`, no `cycle-skipped`, nothing in
# `log.jsonl` at all) as distinct from a cycle that is simply still running,
# or a long cycle whose scheduler keeps ticking (and skipping) around it.
# `lock.json` itself is never published (scripts/state-sync.sh excludes
# it), so "holds no lock" is derived purely from the union log: a node's own
# newest cycle-start/cycle-end/cycle-skipped event — whichever the union
# log's own timestamps put last — being a `cycle-start` means that cycle has
# not yet ended, i.e. the lock is (or very recently was) held, so a long
# *legitimate* cycle is never mistaken for a missed firing. Staleness itself
# is measured from the newer of the node's last `cycle-start` and last
# `cycle-skipped` — not from `cycle-start` alone — so a cycle that outlasts
# 2× the interval while its scheduler keeps ticking (and correctly skipping,
# because the earlier cycle still holds the lock) never crosses the age
# threshold either; only silence on both counts does. Evidence embeds each
# firing node's age and its own recent cycle-duration histogram (up to the
# last 5 completed cycles, matched by the `cycle` id every cycle-start/
# cycle-end pair shares) — "file, with the node's cycle-duration histogram"
# (#1282's own acceptance).
pager_eval_firing_missed() {
  local fleet_nodes_json="$1" union_log_file="$2"
  local interval_min="${PAGER_EVAL_CYCLE_INTERVAL_MINUTES:-}"
  [[ "$interval_min" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  [[ -f "$union_log_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson nodes "$fleet_nodes_json" --argjson interval "$interval_min" \
    --argjson now "$(date -u +%s)" '
    ($nodes | map(select(.stale | not)) | map(.node)) as $active
    | [ inputs | select(length > 0) | (fromjson? // empty)
        | select(.event == "cycle-start" or .event == "cycle-end" or .event == "cycle-skipped")
        | select((.node // "") as $n | $active | index($n) != null) ] as $events
    | ( [ $active[] as $n
          | ($events | map(select(.node == $n)) | sort_by(.ts)) as $node_events
          | ($node_events | map(select(.event == "cycle-start"))) as $starts
          | if ($starts | length) == 0 then empty
            else
              ($node_events | last) as $last_event
              | ($node_events | map(select(.event == "cycle-start" or .event == "cycle-skipped"))
                 | last) as $last_activity
              | ($last_activity.ts | fromdateiso8601) as $start_epoch
              | (($now - $start_epoch) / 60) as $age_min
              | ($last_event.event == "cycle-start") as $lock_held
              | if ($lock_held | not) and ($age_min > (2 * $interval)) then
                  ( ($node_events | group_by(.cycle)
                     | map(select((map(.event) | index("cycle-start"))
                                  and (map(.event) | index("cycle-end"))))
                     | map({s: (map(select(.event == "cycle-start")) | .[0].ts),
                            e: (map(select(.event == "cycle-end")) | .[0].ts)})
                     | map((((.e | fromdateiso8601) - (.s | fromdateiso8601)) / 60) | floor)
                     | .[-5:]) as $durations
                  | {node: $n, age_min: ($age_min | floor), durations: $durations} )
                else empty end
            end
        ] ) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("newest cycle-start or cycle-skipped older than 2× schedule.cycle_interval_minutes ("
              + ($interval | tostring) + "m) while the heartbeat is fresh and no lock is held, on "
              + (($hits | map("\(.node) (\(.age_min)m since last cycle-start/cycle-skipped; recent cycle "
                  + "durations in minutes: "
                  + (if (.durations | length) == 0 then "none recorded"
                     else (.durations | map(tostring) | join(", ")) end) + ")")) | join("; ")))}
      end
  ' < "$union_log_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_node_stale FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any node's `heartbeat_age_s` (lib/fleet.sh's
# `fleet_publication_status`, already carried by every row, self included —
# requirement 2.5) exceeds 2× PAGER_EVAL_NODE_STALE_AFTER_MINUTES: past the
# dashboard's own `.stale` badge (1×) and into "the 2026-08-08 both-laptop-
# nodes signature", four days nobody was looking at a page nobody had.
# Files only after `pager_stale_file_after_minutes`
# (`pager_register_builtin_invariants`'s own registration below), a per-key
# override of the framework's ordinary `pager_min_firing_minutes` hysteresis.
pager_eval_node_stale() {
  local fleet_nodes_json="$1" _union_log_file="$2"
  local threshold_min="${PAGER_EVAL_NODE_STALE_AFTER_MINUTES:-}"
  [[ "$threshold_min" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  jq -c -n --argjson nodes "$fleet_nodes_json" --argjson threshold_min "$threshold_min" '
    (2 * $threshold_min * 60) as $threshold_s
    | ($nodes | map(select((.heartbeat_age_s // 0) > $threshold_s))) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("publication age past 2× node_stale_after_minutes on "
              + (($hits | map("\(.node) (\((( .heartbeat_age_s // 0) / 60) | floor)m)"))
                 | join(", ")))}
      end
  ' 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_updater_stuck FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any *active* node's `.updater.status == "stuck"` for more than
# 2× PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES. `.updater.seconds`
# (lib/updater-health.sh's `updater_status`) already carries the streak's
# own elapsed time, recomputed fresh on every heartbeat write, so this reads
# it directly rather than re-deriving an age from the union log the way
# firing-missed has to for a fact (a lock) that is never published at all.
pager_eval_updater_stuck() {
  local fleet_nodes_json="$1" _union_log_file="$2"
  local threshold_min="${PAGER_EVAL_UPDATER_STUCK_AFTER_MINUTES:-}"
  [[ "$threshold_min" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  jq -c -n --argjson nodes "$fleet_nodes_json" --argjson threshold_min "$threshold_min" '
    (2 * $threshold_min * 60) as $threshold_s
    | ($nodes | map(select(.stale | not))
       | map(select((.updater.status? == "stuck")
                    and ((.updater.seconds? // 0) > $threshold_s)))) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("updater.status=stuck for over 2× updater_stuck_after_minutes on "
              + (($hits | map("\(.node) (\((( .updater.seconds // 0) / 60) | floor)m)"))
                 | join(", ")))}
      end
  ' 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_review_pipeline_failing FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any node's streak of failed review *runs* (review-log.jsonl,
# fleet-replicated like log.jsonl — scripts/state-sync.sh does not exclude
# it) reaches 3 with no successful run between. 3 mirrors
# lib/stage-health.sh's own un-schema-backed `THRESHOLD` default for the
# identical reason that file states: this class has not yet seen a real
# incident to tune the number against. The interim reader — #996 stays the
# proper fix, a verdict folded directly into the heartbeat. Reads
# PAGER_EVAL_REVIEW_UNION_LOG_FILE (lib/pager.sh's own documented exception
# — see this file's header) rather than either of its own two arguments,
# since review-log.jsonl's union is not the implementation union log.
#
# A *run*, grouped by the `review` id review-cycle.sh's own `log_event`
# stamps on every line it writes, not a bare event: `review-end` is written
# by that script's `cleanup()` EXIT trap on every run whatever happened, and
# both ordinary `review-attempt-failed` sites (a clone that would not clone,
# a Reviewer stage that exited non-zero, timed out or returned no usable
# completion) `return 0`, so the run itself still exits 0. Reducing over raw
# events and resetting on `review-end`'s own `exit_code == 0` therefore
# resets the streak on the very run that just failed, and the streak can
# never reach 3 at one repository per run — inert for exactly the case #996
# describes and this invariant exists to read. So, per run:
#
#   any `review-attempt-failed`               the run failed          streak + 1
#   none, and a `review-stage-end`            a review completed      streak → 0
#   neither (stand-down, skip, nothing due)   carries no information  unchanged
#
# The third line is the whole point of grouping: a run that stood down or
# had no repository due says nothing about whether the pipeline works, so it
# must neither raise the alarm nor silence one — which is the very
# indistinguishability #996 names, refused here rather than resolved (only
# a verdict in the heartbeat can resolve it).
pager_eval_review_pipeline_failing() {
  local _fleet_nodes_json="$1" _union_log_file="$2"
  local review_union_file="${PAGER_EVAL_REVIEW_UNION_LOG_FILE:-}"
  local threshold=3
  [[ -n "$review_union_file" && -f "$review_union_file" ]] || { printf '{"firing":false}'; return 0; }
  jq -c -R -n --argjson threshold "$threshold" '
    [ inputs | select(length > 0) | (fromjson? // empty)
      | select(.event == "review-attempt-failed" or .event == "review-stage-end") ] as $events
    | ([ $events[] | .node // "unknown" ] | unique) as $nodes
    | ( [ $nodes[] as $n
          | ($events | map(select((.node // "unknown") == $n))) as $node_events
          | ( $node_events | group_by(.review // "")
              | map({ts: (map(.ts) | min),
                     failed: ((map(.event) | index("review-attempt-failed")) != null)})
              | sort_by(.ts) ) as $runs
          | (reduce $runs[] as $r (0; if $r.failed then . + 1 else 0 end)) as $streak
          | select($streak >= $threshold)
          | {node: $n, streak: $streak} ] ) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("failed review runs at/above " + ($threshold | tostring)
              + " consecutively, with no completed review between (the interim reader pending #996), on "
              + (($hits | map("\(.node) (\(.streak) runs)")) | join(", ")))}
      end
  ' < "$review_union_file" 2>/dev/null || printf '{"firing":false}'
}

# pager_eval_dashboard_unreadable FLEET_NODES_JSON UNION_LOG_FILE
# Fires when any row's `dashboard_fetch` object — `{seconds, parsed}`, the
# contract #1283's own viewer-vantage probe is expected to fold into
# `fleet_nodes_json` (this file's own header) — names a fetch slower than
# PAGER_EVAL_DASHBOARD_FETCH_SECONDS or one that failed to parse. A row with
# no `dashboard_fetch` at all (every row, until #1283 lands) never
# contributes a hit, on the same null-until-populated convention `doctor`/
# `updater`/`stage_health` already use.
pager_eval_dashboard_unreadable() {
  local fleet_nodes_json="$1" _union_log_file="$2"
  local threshold_s="${PAGER_EVAL_DASHBOARD_FETCH_SECONDS:-}"
  [[ "$threshold_s" =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf '{"firing":false}'; return 0; }
  jq -c -n --argjson nodes "$fleet_nodes_json" --argjson threshold_s "$threshold_s" '
    ($nodes | map(select(.dashboard_fetch != null))
     | map(select((.dashboard_fetch.parsed? == false)
                  or ((.dashboard_fetch.seconds? // 0) > $threshold_s)))) as $hits
    | if ($hits | length) == 0 then {firing: false}
      else {firing: true, nodes: ($hits | map(.node)),
            evidence: ("data.js unreadable from a viewer'"'"'s vantage (#1283) on "
              + (($hits | map(
                   if (.dashboard_fetch.parsed? == false) then "\(.node) (failed to parse)"
                   else "\(.node) (\(.dashboard_fetch.seconds)s fetch)" end))
                 | join(", ")))}
      end
  ' 2>/dev/null || printf '{"firing":false}'
}

# pager_register_builtin_invariants [STALE_FILE_AFTER_MINUTES]
# Register every built-in invariant above with lib/pager.sh's own registry.
# Not top-level code (see this file's header). STALE_FILE_AFTER_MINUTES —
# `pager_stale_file_after_minutes` (config.schema.json), default 180 when
# omitted — is node-stale's own per-key override of the framework's ordinary
# `pager_min_firing_minutes` hysteresis (lib/pager.sh's `pager_register`,
# fifth argument): the fact behind node-stale is itself already slow-forming
# (a publication age past 2× node_stale_after_minutes), so filing waits far
# longer than the framework's own blip-sized default before opening a
# tracking issue.
pager_register_builtin_invariants() {
  local stale_file_after_minutes="${1:-180}"
  pager_register verdict-unanimous pager_eval_verdict_unanimous \
    pipeline-act pager_remedy_verdict_unanimous
  pager_register page-outlived-item pager_eval_page_outlived_item \
    pipeline-act pager_remedy_page_outlived_item
  pager_register firing-missed pager_eval_firing_missed owner-only \
    "A node's scheduler appears to have dropped a firing outright (the union log carries neither a cycle-start nor a cycle-skipped recent enough, and this node's newest cycle event is not an unmatched cycle-start) rather than merely still running a long cycle — a cycle-skipped would itself have proved the scheduler ticked and deferred to a held lock. Check the node's own cron/supercronic logs and crontab directly — on Kubernetes, check for a concurrencyPolicy: Forbid skip. The evidence above carries this node's own recent cycle-duration histogram."
  pager_register node-stale pager_eval_node_stale owner-only \
    "This node has not confirmed a publication into the shared state for over twice node_stale_after_minutes. Confirm directly whether the node (container/host) is still running, and check its own state-sync push logs. Once agent-ops#1279's notification channel lands, this class of page reaches it automatically (notify_events' own default includes \"pager\") — today it is filed only." \
    "$stale_file_after_minutes"
  pager_register updater-stuck pager_eval_updater_stuck owner-only \
    "A container this node's own updater told to roll has been \"stuck\" for over twice updater_stuck_after_minutes. Check watchtower / the deploy pipeline on this node directly — this may be agent-ops#603's container-name collision, or, on Kubernetes, an ImagePullBackOff or a rollout stuck past progressDeadlineSeconds."
  pager_register review-pipeline-failing pager_eval_review_pipeline_failing owner-only \
    "The repository-review pipeline (review-cycle.sh) has failed its last several attempts on this node with no successful review-end between. This is the interim reader pending agent-ops#996, which folds a review-pipeline verdict directly into the heartbeat; for now, check review-log.jsonl and the Reviewer stage's own logs on this node directly."
  pager_register dashboard-unreadable pager_eval_dashboard_unreadable owner-only \
    "A viewer fetching this node's data.js (agent-ops#1283's own probe) found it slower than pager_dashboard_fetch_seconds or unparseable — a fact this node cannot observe about itself. Check network/tailnet conditions to this node and the size of its data.js directly."
}
