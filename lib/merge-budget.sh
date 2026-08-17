#!/usr/bin/env bash
#
# lib/merge-budget.sh — the `merge_budget_per_day` spend governor (D18,
# docs/reviews/2026-08-14-autonomy-investigation.md §5.4, WI-6 of umbrella
# #402).
#
# A rolling-24-hour cap on how many pull requests this pipeline may *land*
# in one repository, deterministically countable from GitHub's own merged-PR
# record — never a private counter this process keeps, which a restart or a
# second node would simply not share. `merge_budget_decide` is the pure
# read-side answer — `arm` (under cap), `hold` (cap reached — the budget
# approves the pull request but does not arm its landing; the backlog queues
# visibly rather than merging past the cap) or `refuse` (the count could not
# be established, which fails closed exactly like an unreadable kill switch:
# an ungoverned merge is worse than a merge deferred a cycle). `0` means
# unlimited and skips the count entirely — the off switch, on the same terms
# `stage_inactivity`'s per-actor `0` already uses.
#
# The counting anomaly this item also covers — more pull requests landed in
# the window than the cap ever permitted, which a correct governor should
# never observe — freezes the repository to `agent-approves` (one rung down
# from wherever it was, never all the way to `human`: the Approver App still
# reviews, only automatic landing stops) and escalates to a human, because a
# governor that is wrong about its own count is a fact worth a human's
# attention regardless of which direction it was wrong in.
#
# ## Where this is called from
#
# `run_landing_stage` (D18 WI-7, requirement 8d, `agent-cycle.sh`) is the one
# behaviour-affecting caller of `merge_budget_decide` and
# `merge_budget_apply_decision` — one of the gates the arming step re-reads
# fresh, immediately before it would otherwise land a pull request itself.
# `merge_autonomy_effective_level` is the other caller in this codebase — it
# calls `merge_budget_freeze_state` below regardless of whether the arming
# step ever runs, because a per-repo freeze is a fact about what level a
# repository is governed at independent of anything landing on the strength
# of that level, exactly the same reasoning that already applies to the
# fleet-wide kill switch. Both callers exist because `merge_autonomy` above
# `agent-approves` is still an explicit per-installation opt-in (product
# default `human` fleet-wide) — this file has been regression-tested
# (test/merge-budget.test.sh) since WI-6 landed, and is live wherever an
# operator has actually raised the level.
#
# ## Freeze record shape and the fail-open reading of its own reachability
#
# The freeze is a fleet flag, `fleet/merge-budget-freeze-<slug>.json` (slug
# slashes replaced with `-` — flag names are not paths), reusing
# `lib/toggle.sh`'s generic CAS-guarded contents-API machinery exactly as
# `lib/merge-autonomy.sh`'s kill switch does, under its own per-repo name.
# Unlike the kill switch (TD-PPagop-26081507), this flag's own reachability
# reads *open* (not frozen) on an unreachable state repo with no cached copy
# — deliberately the ordinary fleet-flag direction, not the kill switch's
# inverted one. The kill switch fails closed because an operator who pulled
# that lever needs it to hold even from a node that cannot currently confirm
# it; a freeze exists only because `merge_budget_decide` itself just observed
# a live counting anomaly on a reachable GitHub, so a node that cannot reach
# the *state* repo a moment later has no anomaly of its own to act on, and
# `scripts/doctor.sh` reports the freeze's state as it would any other flag.
#
# Sourced by `agent-cycle.sh` after `lib/toggle.sh` and `lib/github-limit.sh`
# (for `fleet_flag_*`, `GITHUB_PR_LIST_LIMIT` and `github_pr_list_truncated`)
# and by `scripts/doctor.sh` after `lib/toggle.sh` alone — doctor only ever
# calls the pure `merge_budget_effective_cap`, never the network-reading
# functions, so it has no need of `lib/github-limit.sh`. Both source it
# before `lib/merge-autonomy.sh`, which calls `merge_budget_freeze_state` —
# see that file's own shellcheck source note — though bash resolves that
# call at run time, not at source time, so the textual order does not
# actually matter; it is kept for readability alone.

# shellcheck source=lib/toggle.sh
# shellcheck source=lib/github-limit.sh
# (Sourced by every caller of this file already — see the header above.)

MERGE_BUDGET_FREEZE_FLAG_PREFIX="merge-budget-freeze-"

# _merge_budget_freeze_flag_name SLUG
# The fleet-flag NAME (not path) for SLUG's freeze — `fleet_flag_path`
# renders it under `fleet/`. Slashes are replaced, not escaped: a flag NAME
# is one path segment, never a directory of its own.
_merge_budget_freeze_flag_name() {
  printf '%s%s' "$MERGE_BUDGET_FREEZE_FLAG_PREFIX" "${1//\//-}"
}

# merge_budget_effective_cap CONFIG_JSON SLUG
# The cap for SLUG: its own `repos[]` override when present, else the
# top-level `merge_budget_per_day` key, else 8 — the same precedence
# `merge_autonomy_configured_level` and `stage_timeouts` use. `0` at either
# level means unlimited, and is returned as-is, never treated as "unset".
merge_budget_effective_cap() {
  local config_json="$1" slug="$2" repo_cap top_cap
  repo_cap="$(jq -r --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .merge_budget_per_day // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ "$repo_cap" =~ ^[0-9]+$ ]]; then
    printf '%s' "$repo_cap"
    return 0
  fi
  top_cap="$(jq -r '.merge_budget_per_day // empty' <<<"$config_json" 2>/dev/null)"
  [[ "$top_cap" =~ ^[0-9]+$ ]] || top_cap=8
  printf '%s' "$top_cap"
}

# merge_budget_window_status SLUG PR_LABEL MERGED_LOGIN [NOW_ISO]
# STATUS<TAB>COUNT (the same compound-return idiom
# `fleet_flag_fetch_status` uses) — the rolling-24-hour count of SLUG's
# merged pull requests carrying PR_LABEL and merged by MERGED_LOGIN (the
# Approver App identity's own login, `approver_token_identity_login` —
# passed in rather than looked up here, so this file stays independent of
# `lib/approver-token.sh` and trivially testable with a plain string).
# STATUS is `ok` (COUNT is a non-negative integer), `unreadable` (the
# listing failed or did not parse) or `truncated` (the listing came back at
# `GITHUB_PR_LIST_LIMIT`, so a real count above the cap could be hiding
# behind an undercount below it — the dangerous direction for a governor,
# so this counts as unreadable, not as a floor to trust). NOW_ISO defaults
# to the current time and exists only so a test can pin the window without
# waiting for one.
#
# The listing is scoped to the window by GitHub's own `merged:>=<cutoff>`
# search qualifier, not merely filtered to it afterwards, and that is a
# correctness requirement rather than a saving. `gh pr list` returns the
# most recently *created* pull requests, so an unscoped `--state merged`
# listing enumerates the whole lifetime history of the label: every
# repository this fleet governs passes `GITHUB_PR_LIST_LIMIT` merged
# labelled pull requests within weeks and never comes back under it, at
# which point the listing is truncated on every single call and this
# function can only ever answer `truncated` — `arm`, `hold` and the anomaly
# freeze all become permanently unreachable. Scoped, the page cap bounds the
# *window* instead, so reaching it means 60-odd pull requests genuinely
# landed in 24 hours, which is a real anomaly and rightly refuses.
#
# The qualifier only has to be a *superset* of the window: the `jq` filter
# below still decides the count on an exact `mergedAt >= cutoff` comparison,
# so nothing depends on GitHub honouring the time component (it does; it
# would remain correct if it rounded the qualifier to whole days). What it
# does depend on is the search index, which is eventually consistent — a
# merge from the last few seconds may not appear yet, undercounting by one.
# That is the dangerous direction, and it is accepted deliberately: an
# undercount of one on a 24-hour window is strictly better than a count that
# is never established at all, and the cycle's own 15-minute tick keeps the
# exposure to a merge landing inside the same tick that reads it.
merge_budget_window_status() {
  local slug="$1" pr_label="$2" merged_login="$3" now_iso="${4:-}"
  [[ -n "$now_iso" ]] || now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local cutoff
  cutoff="$(date -u -d "$now_iso - 24 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || {
    printf 'unreadable\t'
    return 0
  }
  local raw total
  raw="$(gh pr list -R "$slug" --state merged --label "$pr_label" \
    --search "merged:>=$cutoff" \
    --limit "$GITHUB_PR_LIST_LIMIT" --json number,mergedAt,mergedBy,labels 2>/dev/null)" || {
    printf 'unreadable\t'
    return 0
  }
  [[ -n "$raw" ]] || raw='[]'
  total="$(jq 'length' <<<"$raw" 2>/dev/null)" || {
    printf 'unreadable\t'
    return 0
  }
  if github_pr_list_truncated "$total"; then
    printf 'truncated\t'
    return 0
  fi
  local count
  count="$(jq -r --arg login "$merged_login" --arg cutoff "$cutoff" --arg label "$pr_label" '
    [.[] | select((.mergedAt // "") >= $cutoff)
         | select((.mergedBy.login // "") == $login)
         | select(((.labels // []) | map(.name)) | index($label) != null)]
    | length' <<<"$raw" 2>/dev/null)" || {
    printf 'unreadable\t'
    return 0
  }
  [[ "$count" =~ ^[0-9]+$ ]] || {
    printf 'unreadable\t'
    return 0
  }
  printf 'ok\t%s' "$count"
}

# merge_budget_oldest_waiting SLUG PR_LABEL
# The oldest currently open, non-draft, PR_LABEL-carrying pull request for
# SLUG — `{number, url, created_at}`, or `null` on an empty or unreadable
# listing (best-effort: a `hold` decision is correct with or without this,
# so a failure here never turns a `hold` into a `refuse`). This is the
# backlog a `hold` decision names, not an arming-eligibility filter — the
# work item that arms landing may apply a tighter one of its own on top.
#
# `--search "sort:created-asc draft:false"` (PR #499 review follow-up; the
# `draft:false` qualifier added by issue #513, PR #506 review follow-up) asks
# GitHub to order the listing itself and drop drafts from it, so `first`
# after `sort_by` names the true oldest *non-draft* regardless of the
# `--limit` page cap: unscoped, `gh pr list` returns the newest-created page,
# and past `GITHUB_PR_LIST_LIMIT` open labelled pull requests the local
# `sort_by(.createdAt) | first` above would silently name the oldest of that
# newest page — not the oldest waiting, the one thing this function exists to
# name — with nothing to say it had missed the real one. `draft:false` closes
# a second way the same page cap could miss it: without it, a page whose
# `GITHUB_PR_LIST_LIMIT` oldest entries are all drafts leaves nothing for the
# local `select(.isDraft | not)` filter below to find, and this reports
# `null` — no backlog at all — even though an older non-draft is waiting just
# past the page. The local filter stays regardless, belt-and-braces against
# the search index's own eventual consistency; a pull request too fresh to
# appear yet is never the oldest either way.
merge_budget_oldest_waiting() {
  local slug="$1" pr_label="$2" raw
  raw="$(gh pr list -R "$slug" --state open --label "$pr_label" \
    --search "sort:created-asc draft:false" \
    --limit "$GITHUB_PR_LIST_LIMIT" --json number,url,createdAt,isDraft 2>/dev/null)" || raw=''
  [[ -n "$raw" ]] || raw='[]'
  jq -c '[.[] | select(.isDraft | not)] | sort_by(.createdAt) | first
    | if . == null then null else {number, url, created_at: .createdAt} end' \
    <<<"$raw" 2>/dev/null || printf 'null'
}

# merge_budget_decide CONFIG_JSON SLUG PR_LABEL MERGED_LOGIN [NOW_ISO]
# One JSON object — `{decision, cap, count, anomaly, waiting_backlog}` —
# combining `merge_budget_effective_cap` and `merge_budget_window_status`:
#
#   - `cap` 0 → `{"decision":"arm","cap":0,"count":null,"anomaly":false,
#     "waiting_backlog":null}`, with no count attempted at all — unlimited
#     means unlimited, not "count anyway and never trip".
#   - the window unreadable or truncated → `{"decision":"refuse", "cap":
#     <cap>, "count":null, "anomaly":false, "waiting_backlog":null}` — an
#     uncountable spend must never read as clearance to land.
#   - `count < cap` → `arm`.
#   - `count >= cap` → `hold`, with `waiting_backlog` filled from
#     `merge_budget_oldest_waiting`. Not `arm`: a full budget approves a
#     pull request's *content* through the ordinary review path, never its
#     landing.
#   - `count > cap` → `hold` as above, plus `anomaly: true` — a fact this
#     function only reports; `merge_budget_apply_decision` is what acts on
#     it (freeze and escalate).
#
# Pure but for its two reads (the window count, the backlog listing): no log
# events, no freeze writes. `merge_budget_apply_decision` below is the
# caller that turns this into log events and (on an anomaly) a freeze and an
# escalation issue — kept separate so this function stays trivially callable
# from a test with no `log_event`/`gh issue create` to stub.
merge_budget_decide() {
  local config_json="$1" slug="$2" pr_label="$3" merged_login="$4" now_iso="${5:-}"
  local cap
  cap="$(merge_budget_effective_cap "$config_json" "$slug")"
  if [[ "$cap" == "0" ]]; then
    printf '{"decision":"arm","cap":0,"count":null,"anomaly":false,"waiting_backlog":null}'
    return 0
  fi
  local combined status count
  combined="$(merge_budget_window_status "$slug" "$pr_label" "$merged_login" "$now_iso")"
  status="${combined%%$'\t'*}"
  count="${combined#*$'\t'}"
  if [[ "$status" != "ok" ]]; then
    jq -nc --argjson cap "$cap" \
      '{decision:"refuse", cap:$cap, count:null, anomaly:false, waiting_backlog:null}'
    return 0
  fi
  if (( count < cap )); then
    jq -nc --argjson cap "$cap" --argjson count "$count" \
      '{decision:"arm", cap:$cap, count:$count, anomaly:false, waiting_backlog:null}'
    return 0
  fi
  local anomaly=false backlog
  (( count > cap )) && anomaly=true
  backlog="$(merge_budget_oldest_waiting "$slug" "$pr_label")"
  [[ -n "$backlog" ]] || backlog='null'
  jq -nc --argjson cap "$cap" --argjson count "$count" --argjson an "$anomaly" \
    --argjson bl "$backlog" \
    '{decision:"hold", cap:$cap, count:$count, anomaly:$an, waiting_backlog:$bl}'
}

# merge_budget_freeze_state STATE_REPO STATE_DIR SLUG [FRESH]
# The per-repo freeze, in `toggle_state`'s own vocabulary — `{"state":
# "enabled"}` (not frozen) or `{"state":"disabled","record":{...}}` (frozen).
# RAW-only, exactly as `fleet_disabled_state` uses for every other ordinary
# fleet flag: an unreachable state repo with no cache and a genuinely clear
# flag both read as "not frozen" here — see the header for why this, unlike
# the kill switch, does not need TD-PPagop-26081507's fail-closed inversion.
#
# FRESH (issue #513) skips this process's memo for the one call — the same
# escape `fleet_flag_fetch_status`'s own FRESH argument provides, for the same
# reason: a caller taking an outward action under the answer must see a freeze
# another process set at the moment it decides, rather than replaying the
# answer this cycle's first read memoised. D18 WI-7's arming step is that
# site, and `merge_autonomy_effective_level` passes its own FRESH through to
# here, so that function's promise — the kill switch *and* a WI-6 budget
# freeze both bind at the moment of decision — holds for the freeze too.
#
# A fresh read calls `fleet_flag_fetch_status` directly, because
# `fleet_flag_fetch` deliberately forwards neither MODE nor FRESH (that is
# what keeps its contract byte-identical for its three original callers).
# MODE is passed empty, so this flag's fail-open direction is untouched: only
# the memo is bypassed, never the `clear`-vs-`unreachable` resolution, and an
# empty RAW still reads as "not frozen" whichever path produced it.
merge_budget_freeze_state() {
  local raw fresh="${4:-}" combined
  if [[ -n "$fresh" ]]; then
    combined="$(fleet_flag_fetch_status "$1" "$2" "$(_merge_budget_freeze_flag_name "$3")" "" "$fresh")"
    raw="${combined#*$'\t'}"
  else
    raw="$(fleet_flag_fetch "$1" "$2" "$(_merge_budget_freeze_flag_name "$3")")"
  fi
  if [[ -z "$raw" ]]; then
    printf '{"state":"enabled"}'
    return 0
  fi
  _toggle_eval "$raw" present
}

# merge_budget_freeze_set STATE_REPO SLUG CAP COUNT [ACTOR]
# Freeze SLUG to `agent-approves` and print the `fleet_flag_write_outcome`
# word (ok/failed/unconfigured). `kind: "anomaly"` — never `manual`, the same
# distinction the kill switch's own record draws — so a human reading the
# record (or `scripts/doctor.sh`) can tell this was the governor's own
# detection, not an operator's hand.
merge_budget_freeze_set() {
  local state_repo="$1" slug="$2" cap="$3" count="$4" actor="${5:-}" body
  [[ -n "$actor" ]] || actor="$(toggle_actor)"
  body="$(jq -nc --arg at "$(_toggle_iso)" --arg by "merge-budget governor" \
    --arg r "counting anomaly: $count pull request(s) landed against a cap of $cap in the rolling 24h window — more than a correct count should ever permit" \
    --arg actor "$actor" --argjson cap "$cap" --argjson count "$count" \
    '{disabled_at: $at, expires_at: null, by: $by, reason: $r, actor: $actor,
      kind: "anomaly", cap: $cap, count: $count}')"
  fleet_flag_write_outcome "$state_repo" "$(_merge_budget_freeze_flag_name "$slug")" "$body" \
    "fleet: $slug merge-budget freeze set — counting anomaly ($count > $cap)"
}

# merge_budget_freeze_clear STATE_REPO STATE_DIR SLUG
# Clear SLUG's freeze and print the `fleet_flag_delete_outcome` word. Only a
# human clears an anomaly freeze — nothing here calls this automatically,
# the same way nothing automatically clears the kill switch.
merge_budget_freeze_clear() {
  fleet_flag_delete_outcome "$1" "$2" "$(_merge_budget_freeze_flag_name "$3")"
}

# merge_budget_apply_decision DECISION_JSON SLUG STATE_REPO ESCALATION_LABEL ASSIGNEE
# The write side of a `merge_budget_decide` result — logs the `hold` and
# `refuse` outcomes, and on an anomaly (`.anomaly == true`) freezes SLUG and
# files an escalation issue against SLUG itself (never `crash_loop_repo`:
# unlike a crash loop or a usage-limit freeze, this anomaly is a fact about
# one repository, not the fleet, so it belongs in that repository's own
# backlog — the same reasoning `approver_escalate` already applies). Calls
# `log_event` directly rather than returning something for a caller to log,
# on the same "assume the caller has already sourced it" terms this file
# assumes for `fleet_flag_*` — `log_event` is defined by `agent-cycle.sh`
# itself, the one process that ever calls this function for real.
#
# Deduplicated the same way `create_escalation_issue` dedups every other
# escalation (an open issue in SLUG already naming this item ref) — but this
# file cannot call that function directly (it lives in agent-cycle.sh, not a
# sourced library), so the same dedup is inlined here rather than skipped:
# an escalation a human has not yet closed must not be re-filed every time
# the arming step reconsiders this repository.
merge_budget_apply_decision() {
  local decision_json="$1" slug="$2" state_repo="$3" escalation_label="$4" assignee="$5"
  local decision cap count anomaly backlog
  decision="$(jq -r '.decision' <<<"$decision_json")"
  cap="$(jq -r '.cap' <<<"$decision_json")"
  count="$(jq -r '.count' <<<"$decision_json")"
  anomaly="$(jq -r '.anomaly' <<<"$decision_json")"
  backlog="$(jq -c '.waiting_backlog' <<<"$decision_json")"

  case "$decision" in
    refuse)
      log_event "warning" "$(jq -nc --arg s "$slug" \
        --arg d "merge-budget: could not establish $slug's landed-PR count this window — refusing to arm rather than land ungoverned" \
        '{detail: $d, repo: $s}')"
      return 0
      ;;
    hold)
      log_event "merge-budget-hold" "$(jq -nc --arg s "$slug" --argjson cap "$cap" \
        --argjson count "$count" --argjson bl "$backlog" \
        '{repo: $s, cap: $cap, count: $count, waiting_backlog: $bl}')"
      ;;
    *)
      return 0
      ;;
  esac

  [[ "$anomaly" == "true" ]] || return 0

  local item_ref="merge-budget-freeze-${slug//\//-}"
  local existing
  existing="$(gh issue list -R "$slug" --label "$escalation_label" --state open --search "$item_ref" \
                --json number,url,body 2>/dev/null \
              | jq -r --arg it "$item_ref" \
                  'map(select(((.body // "") | contains($it)))) | first
                   | if . == null then empty else "\(.number)\t\(.url)" end' 2>/dev/null || true)"

  local outcome
  outcome="$(merge_budget_freeze_set "$state_repo" "$slug" "$cap" "$count")"
  log_event "merge-budget-frozen" "$(jq -nc --arg s "$slug" --argjson cap "$cap" \
    --argjson count "$count" --arg o "$outcome" \
    '{repo: $s, cap: $cap, count: $count, fleet_flag: $o}')"

  if [[ -n "$existing" ]]; then
    return 0
  fi

  local body_file
  body_file="$(mktemp)"
  {
    printf '## What the fleet log shows\n\n'
    # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
    printf -- '- **%s pull requests landed** in %s'"'"'s rolling 24h window, against a `merge_budget_per_day` cap of **%s**.\n' \
      "$count" "$slug" "$cap"
    # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
    printf -- '- This should be impossible: the governor holds at the cap, never past it. %s is frozen to `agent-approves` until a human clears it.\n\n' "$slug"
    cat <<MERGE_BUDGET_ESC_BODY
## What the fleet needs from you

Find out how more pull requests landed than the cap ever permitted — a
second node racing the same decision, a manual merge outside this pipeline,
or a bug in the count itself — then clear the freeze
(\`merge_budget_freeze_clear\`) once you are satisfied it will not recur.

---
Item: \`$item_ref\`
Filed automatically by the merge-budget governor (D18 WI-6).
MERGE_BUDGET_ESC_BODY
  } > "$body_file"

  local raw url number
  raw="$(gh issue create -R "$slug" \
           --title "merge-budget: counting anomaly ($count landed > $cap cap)" \
           --body-file "$body_file" --assignee "$assignee" --label "$escalation_label" \
           2>/dev/null || true)"
  rm -f "$body_file"
  url="$(grep -oE 'https://github\.com/[A-Za-z0-9_./-]+/issues/[0-9]+' <<<"$raw" | tail -n1 || true)"
  if [[ -z "$url" ]]; then
    log_event "warning" "$(jq -nc --arg s "$slug" \
      --arg d "merge-budget: $slug frozen over a counting anomaly, but the escalation issue could not be filed — will retry next cycle" \
      '{detail: $d, repo: $s}')"
    return 0
  fi
  number="${url##*/}"
  log_event "merge-budget-freeze-escalated" "$(jq -nc --arg s "$slug" --argjson n "$number" \
    --arg u "$url" --argjson cap "$cap" --argjson count "$count" \
    '{repo: $s, issue_number: $n, issue_url: $u, cap: $cap, count: $count}')"
}
