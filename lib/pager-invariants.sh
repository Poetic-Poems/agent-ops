#!/usr/bin/env bash
#
# lib/pager-invariants.sh — the two invariants issue #1278 ships the pager
# framework (lib/pager.sh) with, chosen to exercise every branch of it:
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

# pager_register_builtin_invariants — register the two invariants above with
# lib/pager.sh's own registry. Not top-level code (see this file's header).
pager_register_builtin_invariants() {
  pager_register verdict-unanimous pager_eval_verdict_unanimous \
    pipeline-act pager_remedy_verdict_unanimous
  pager_register page-outlived-item pager_eval_page_outlived_item \
    pipeline-act pager_remedy_page_outlived_item
}
